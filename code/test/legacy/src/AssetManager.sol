// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "./HeartbeatManager.sol";

/**
 * @title AssetManager
 * @notice Manages asset deposits, allocation, auto-push transfers, pull-based claims,
 *         unclaimed asset sweeping, and stuck NFT rescue.
 *
 * SUPPORTED ASSETS:
 *   - Native ETH  (via payable addETHAsset)
 *   - ERC-20      (USDC, DAI, USDT, etc.)  -- fee-on-transfer guarded
 *   - ERC-721     (indivisible, direct assignment to a specific heir)
 *   - ERC-1155    (fungible amounts -> percentage; single items -> direct assignment)
 *   - ERC-1155 wrapper shares from ERC721FractionalWrapper
 *
 * NOT SUPPORTED:
 *   - ERC-777 (callback hooks create reentrancy risk; use ERC-20 wrappers instead)
 *
 * AUTO-PUSH MECHANISM:
 *   During execution, the system first attempts to push (transfer) assets directly
 *   to each heir. If the push fails (heir is a contract that rejects transfers),
 *   assets fall back to pull-based claims. After UNCLAIMED_ASSET_DEADLINE, unclaimed
 *   assets can be swept to the fallback beneficiary.
 *
 * SECURITY:
 *   - Checks-Effects-Interactions throughout
 *   - ReentrancyGuard on all claim and sweep functions
 *   - Fee-on-transfer tokens handled by measuring actual received amount
 *   - Deterministic dust/rounding: remainder goes to largest-share heir
 *   - Gas-limited auto-push prevents griefing by malicious heir contracts
 */
abstract contract AssetManager is HeartbeatManager, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════
    //                     DIVISIBLE ASSETS (percentage-based)
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit native ETH into the will -- divisible by heir percentage.
     */
    function addETHAsset(uint256 _willId) external payable {
        require(msg.value > 0, "No ETH sent");
        Will storage will = wills[msg.sender][_willId];
        require(will.owner == msg.sender, "Not will owner");
        require(will.state == WillState.Created, "Will not in Created state");

        will.assets.push(Asset({
            assetType:    AssetType.ETH,
            tokenContract: address(0),
            tokenId:      0,
            amount:       msg.value,
            specificHeir: address(0)
        }));

        emit AssetAdded(msg.sender, _willId, AssetType.ETH);
    }

    /**
     * @notice Deposit ERC-20 tokens -- divisible by heir percentage.
     * @dev    Measures actual received amount to handle fee-on-transfer tokens.
     */
    function addERC20Asset(
        uint256 _willId,
        address _tokenContract,
        uint256 _amount
    ) external {
        require(_amount > 0, "Invalid amount");
        Will storage will = wills[msg.sender][_willId];
        require(will.owner == msg.sender, "Not will owner");
        require(will.state == WillState.Created, "Will not in Created state");

        IERC20 token = IERC20(_tokenContract);
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 actualReceived = token.balanceOf(address(this)) - balanceBefore;
        require(actualReceived > 0, "No tokens received");

        will.assets.push(Asset({
            assetType:    AssetType.ERC20,
            tokenContract: _tokenContract,
            tokenId:      0,
            amount:       actualReceived,
            specificHeir: address(0)
        }));

        emit AssetAdded(msg.sender, _willId, AssetType.ERC20);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                   INDIVISIBLE ASSETS (direct assignment)
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit an ERC-721 NFT -- must specify which heir receives it.
     */
    function addERC721Asset(
        uint256 _willId,
        address _tokenContract,
        uint256 _tokenId,
        address _specificHeir
    ) external {
        Will storage will = wills[msg.sender][_willId];
        require(will.owner == msg.sender, "Not will owner");
        require(will.state == WillState.Created, "Will not in Created state");
        require(_specificHeir != address(0), "Must specify heir for NFT");
        require(_isValidHeir(will, _specificHeir), "Not a registered heir");

        IERC721(_tokenContract).transferFrom(msg.sender, address(this), _tokenId);

        will.assets.push(Asset({
            assetType:    AssetType.ERC721,
            tokenContract: _tokenContract,
            tokenId:      _tokenId,
            amount:       1,
            specificHeir: _specificHeir
        }));

        emit AssetAdded(msg.sender, _willId, AssetType.ERC721);
    }

    // ═══════════════════════════════════════════════════════════════════
    //           HYBRID ASSETS (ERC-1155: divisible OR indivisible)
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit fungible ERC-1155 tokens (amount > 1) -- divisible by percentage.
     * @dev    Measures actual received amount to guard against fee-on-transfer behaviour.
     */
    function addERC1155AssetFungible(
        uint256 _willId,
        address _tokenContract,
        uint256 _tokenId,
        uint256 _amount
    ) public {
        require(_amount > 1, "Use addERC1155AssetNFT for single items");
        Will storage will = wills[msg.sender][_willId];
        require(will.owner == msg.sender, "Not will owner");
        require(will.state == WillState.Created, "Will not in Created state");

        uint256 balBefore = IERC1155(_tokenContract).balanceOf(address(this), _tokenId);
        IERC1155(_tokenContract).safeTransferFrom(
            msg.sender, address(this), _tokenId, _amount, ""
        );
        uint256 actualReceived = IERC1155(_tokenContract).balanceOf(address(this), _tokenId) - balBefore;
        require(actualReceived > 0, "No tokens received");

        will.assets.push(Asset({
            assetType:    AssetType.ERC1155,
            tokenContract: _tokenContract,
            tokenId:      _tokenId,
            amount:       actualReceived,
            specificHeir: address(0)
        }));

        emit AssetAdded(msg.sender, _willId, AssetType.ERC1155);
    }

    /**
     * @notice Deposit a non-fungible ERC-1155 token (amount == 1) -- must specify heir.
     */
    function addERC1155AssetNFT(
        uint256 _willId,
        address _tokenContract,
        uint256 _tokenId,
        address _specificHeir
    ) external {
        Will storage will = wills[msg.sender][_willId];
        require(will.owner == msg.sender, "Not will owner");
        require(will.state == WillState.Created, "Will not in Created state");
        require(_specificHeir != address(0), "Must specify heir for NFT");
        require(_isValidHeir(will, _specificHeir), "Not a registered heir");

        IERC1155(_tokenContract).safeTransferFrom(
            msg.sender, address(this), _tokenId, 1, ""
        );

        will.assets.push(Asset({
            assetType:    AssetType.ERC1155,
            tokenContract: _tokenContract,
            tokenId:      _tokenId,
            amount:       1,
            specificHeir: _specificHeir
        }));

        emit AssetAdded(msg.sender, _willId, AssetType.ERC1155);
    }

    // ═══════════════════════════════════════════════════════════════════
    //        ERC-721 SHARED ASSET (wrapper-issued ERC-1155 shares)
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit ERC-1155 shares from ERC721FractionalWrapper into the will.
     *         Treated as divisible ERC-1155.
     */
    function addERC721SharedAsset(
        uint256 _willId,
        address _wrapperContract,
        uint256 _wrapId,
        uint256 _amount
    ) external {
        require(_amount > 0, "Invalid amount");
        Will storage will = wills[msg.sender][_willId];
        require(will.owner == msg.sender, "Not will owner");
        require(will.state == WillState.Created, "Will not in Created state");

        IERC1155(_wrapperContract).safeTransferFrom(
            msg.sender, address(this), _wrapId, _amount, ""
        );

        will.assets.push(Asset({
            assetType:    AssetType.ERC1155,
            tokenContract: _wrapperContract,
            tokenId:      _wrapId,
            amount:       _amount,
            specificHeir: address(0)
        }));

        emit AssetAdded(msg.sender, _willId, AssetType.ERC1155);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                   INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════

    function _getHeirIndex(Will storage will, address _heirAddress) internal view returns (uint256) {
        for (uint256 i = 0; i < will.heirs.length; i++) {
            if (will.heirs[i].heirAddress == _heirAddress) return i;
        }
        revert("Heir not found");
    }

    // ═══════════════════════════════════════════════════════════════════
    //                   AUTO-PUSH TRANSFER HELPERS
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @dev Attempt to push ETH directly to an heir with gas limit.
     *      Returns false if the transfer fails (heir is a contract that rejects ETH).
     */
    function _autoPushETH(address heir, uint256 amount) internal returns (bool) {
        (bool success,) = payable(heir).call{value: amount, gas: AUTO_PUSH_GAS_LIMIT}("");
        return success;
    }

    /**
     * @dev Attempt to push ERC20 directly to an heir.
     */
    function _autoPushERC20(address heir, address token, uint256 amount) internal returns (bool) {
        try IERC20(token).transfer(heir, amount) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }

    /**
     * @dev Attempt to push ERC1155 directly to an heir.
     */
    function _autoPushERC1155(address heir, address token, uint256 tokenId, uint256 amount) internal returns (bool) {
        try IERC1155(token).safeTransferFrom(address(this), heir, tokenId, amount, "") {
            return true;
        } catch {
            return false;
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    //    ALLOCATE DIVISIBLE ASSETS WITH AUTO-PUSH (hybrid push/pull)
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Allocate all divisible assets among heirs with auto-push.
     *         Tries to push assets directly; falls back to pull-based claims if push fails.
     *         Dust (remainder) goes to the largest-share heir.
     * @dev    Called exactly once per will when transitioning to Executing state.
     */
    function _allocateDivisibleAssetsToHeirsWithPush(address owner, uint256 willId) internal {
        Will storage will = wills[owner][willId];
        require(!divisibleAllocated[owner][willId], "Already allocated");

        if (will.heirs.length == 0) {
            divisibleAllocated[owner][willId] = true;
            return;
        }

        // Pre-compute largest-share heir (ties: first encountered)
        uint256 largestIndex = 0;
        uint256 largestPct   = 0;
        for (uint256 h = 0; h < will.heirs.length; h++) {
            if (will.heirs[h].sharePercentage > largestPct) {
                largestPct   = will.heirs[h].sharePercentage;
                largestIndex = h;
            }
        }

        for (uint256 j = 0; j < will.assets.length; j++) {
            Asset storage asset = will.assets[j];

            // Skip indivisible (directly assigned) assets
            if (asset.specificHeir != address(0)) continue;

            if (asset.assetType == AssetType.ETH && asset.amount > 0) {
                _distributeETHWithPush(will, asset, largestIndex, owner, willId);
            }
            else if (asset.assetType == AssetType.ERC20 && asset.amount > 0) {
                _distributeERC20WithPush(will, asset, largestIndex, owner, willId);
            }
            else if (asset.assetType == AssetType.ERC1155 && asset.amount > 1) {
                _distributeERC1155WithPush(will, asset, largestIndex, owner, willId);
            }
        }

        divisibleAllocated[owner][willId] = true;
    }

    // ── Internal distribution helpers with auto-push ──

    function _distributeETHWithPush(
        Will storage will,
        Asset storage asset,
        uint256 largestIndex,
        address owner,
        uint256 willId
    ) private {
        uint256 total       = asset.amount;
        uint256 distributed = 0;

        for (uint256 h = 0; h < will.heirs.length; h++) {
            uint256 pct = will.heirs[h].sharePercentage;
            if (pct == 0) continue;
            uint256 share = (total * pct) / 10000;
            if (share == 0) continue;

            bool pushed = _autoPushETH(will.heirs[h].heirAddress, share);
            if (pushed) {
                pushSucceeded[owner][willId][h] = true;
                emit AutoPushAttempted(will.heirs[h].heirAddress, willId, true);
            } else {
                pendingETH[will.heirs[h].heirAddress] += share;
                emit AutoPushAttempted(will.heirs[h].heirAddress, willId, false);
            }
            pushAttempted[owner][willId][h] = true;
            distributed += share;
        }

        // Dust to largest heir
        if (total > distributed) {
            uint256 dust = total - distributed;
            bool pushed = _autoPushETH(will.heirs[largestIndex].heirAddress, dust);
            if (!pushed) {
                pendingETH[will.heirs[largestIndex].heirAddress] += dust;
            }
        }
        asset.amount = 0;
    }

    function _distributeERC20WithPush(
        Will storage will,
        Asset storage asset,
        uint256 largestIndex,
        address owner,
        uint256 willId
    ) private {
        uint256 total       = asset.amount;
        uint256 distributed = 0;

        for (uint256 h = 0; h < will.heirs.length; h++) {
            uint256 pct = will.heirs[h].sharePercentage;
            if (pct == 0) continue;
            uint256 share = (total * pct) / 10000;
            if (share == 0) continue;

            bool pushed = _autoPushERC20(will.heirs[h].heirAddress, asset.tokenContract, share);
            if (pushed) {
                pushSucceeded[owner][willId][h] = true;
                emit AutoPushAttempted(will.heirs[h].heirAddress, willId, true);
            } else {
                pendingERC20[will.heirs[h].heirAddress][asset.tokenContract] += share;
                emit AutoPushAttempted(will.heirs[h].heirAddress, willId, false);
            }
            pushAttempted[owner][willId][h] = true;
            distributed += share;
        }

        if (total > distributed) {
            uint256 dust = total - distributed;
            bool pushed = _autoPushERC20(will.heirs[largestIndex].heirAddress, asset.tokenContract, dust);
            if (!pushed) {
                pendingERC20[will.heirs[largestIndex].heirAddress][asset.tokenContract] += dust;
            }
        }
        asset.amount = 0;
    }

    function _distributeERC1155WithPush(
        Will storage will,
        Asset storage asset,
        uint256 largestIndex,
        address owner,
        uint256 willId
    ) private {
        uint256 total       = asset.amount;
        uint256 distributed = 0;

        for (uint256 h = 0; h < will.heirs.length; h++) {
            uint256 pct = will.heirs[h].sharePercentage;
            if (pct == 0) continue;
            uint256 share = (total * pct) / 10000;
            if (share == 0) continue;

            bool pushed = _autoPushERC1155(
                will.heirs[h].heirAddress, asset.tokenContract, asset.tokenId, share
            );
            if (pushed) {
                pushSucceeded[owner][willId][h] = true;
                emit AutoPushAttempted(will.heirs[h].heirAddress, willId, true);
            } else {
                pendingERC1155[will.heirs[h].heirAddress][asset.tokenContract][asset.tokenId] += share;
                emit AutoPushAttempted(will.heirs[h].heirAddress, willId, false);
            }
            pushAttempted[owner][willId][h] = true;
            distributed += share;
        }

        if (total > distributed) {
            uint256 dust = total - distributed;
            bool pushed = _autoPushERC1155(
                will.heirs[largestIndex].heirAddress, asset.tokenContract, asset.tokenId, dust
            );
            if (!pushed) {
                pendingERC1155[will.heirs[largestIndex].heirAddress][asset.tokenContract][asset.tokenId] += dust;
            }
        }
        asset.amount = 0;
    }

    // ═══════════════════════════════════════════════════════════════════
    //     TRANSFER INDIVISIBLE ASSETS (called per-heir during execution)
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Transfer indivisible assets to heir.
     *         Divisible assets have already been allocated via auto-push/pull.
     * @dev    Follows Checks-Effects-Interactions: marks asset consumed before external call.
     */
    function _transferAssetsToHeir(
        Will storage will,
        Heir storage heir,
        uint256 _willId,
        uint256 /*_heirIndex*/
    ) internal {
        for (uint256 j = 0; j < will.assets.length; j++) {
            Asset storage asset = will.assets[j];

            // ERC-721 assigned to this heir
            if (asset.assetType == AssetType.ERC721
                && asset.specificHeir == heir.heirAddress
                && asset.amount == 1
            ) {
                asset.amount = 0;
                asset.specificHeir = address(0);
                try IERC721(asset.tokenContract).safeTransferFrom(
                    address(this), heir.heirAddress, asset.tokenId
                ) {
                    emit InheritanceExecuted(heir.heirAddress, _willId, j);
                } catch {
                    // Transfer failed; restore amount so rescueStuckNFT can handle it
                    asset.amount = 1;
                    asset.specificHeir = heir.heirAddress;
                }
            }
            // ERC-1155 single-item assigned to this heir
            else if (asset.assetType == AssetType.ERC1155
                && asset.specificHeir == heir.heirAddress
                && asset.amount == 1
            ) {
                asset.amount = 0;
                asset.specificHeir = address(0);
                try IERC1155(asset.tokenContract).safeTransferFrom(
                    address(this), heir.heirAddress, asset.tokenId, 1, ""
                ) {
                    emit InheritanceExecuted(heir.heirAddress, _willId, j);
                } catch {
                    asset.amount = 1;
                    asset.specificHeir = heir.heirAddress;
                }
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    //                   CLAIM FUNCTIONS (pull-based fallback)
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Claim native ETH allocated to msg.sender (if auto-push failed).
     */
    function claimETH() external nonReentrant {
        uint256 amount = pendingETH[msg.sender];
        require(amount > 0, "No ETH claim");
        pendingETH[msg.sender] = 0;
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        require(ok, "ETH transfer failed");
        emit ETHClaimed(msg.sender, amount);
    }

    /**
     * @notice Claim ERC-20 tokens allocated to msg.sender.
     */
    function claimERC20(address token) external nonReentrant {
        uint256 amount = pendingERC20[msg.sender][token];
        require(amount > 0, "No ERC20 claim");
        pendingERC20[msg.sender][token] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit ERC20Claimed(msg.sender, token, amount);
    }

    /**
     * @notice Claim ERC-1155 tokens allocated to msg.sender.
     */
    function claimERC1155(address token, uint256 tokenId) external nonReentrant {
        uint256 amount = pendingERC1155[msg.sender][token][tokenId];
        require(amount > 0, "No ERC1155 claim");
        pendingERC1155[msg.sender][token][tokenId] = 0;
        IERC1155(token).safeTransferFrom(address(this), msg.sender, tokenId, amount, "");
        emit ERC1155Claimed(msg.sender, token, tokenId, amount);
    }

    // ═══════════════════════════════════════════════════════════════════
    //               RESCUE STUCK NFTs (indivisible assets)
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice If an indivisible NFT transfer fails during execution because the heir
     *         address rejects it, the designated heir can retry to a different receiver.
     */
    function rescueStuckNFT(
        address _owner,
        uint256 _willId,
        uint256 _assetIndex,
        address _receiver
    ) external nonReentrant {
        Will storage will = wills[_owner][_willId];
        require(
            will.state == WillState.Executing || will.state == WillState.Executed,
            "Invalid state"
        );

        Asset storage asset = will.assets[_assetIndex];
        require(asset.amount > 0, "Asset already transferred");
        require(asset.specificHeir == msg.sender, "Not designated heir");
        require(_receiver != address(0), "Invalid receiver");

        uint256 tokenId = asset.tokenId;
        address tokenContract = asset.tokenContract;
        AssetType aType = asset.assetType;

        // Effects before interaction
        asset.amount = 0;
        asset.specificHeir = address(0);

        // Interaction
        if (aType == AssetType.ERC721) {
            IERC721(tokenContract).safeTransferFrom(address(this), _receiver, tokenId);
        } else if (aType == AssetType.ERC1155) {
            IERC1155(tokenContract).safeTransferFrom(address(this), _receiver, tokenId, 1, "");
        }

        emit InheritanceExecuted(_receiver, _willId, _assetIndex);
    }

    // ═══════════════════════════════════════════════════════════════════
    //          SWEEP UNCLAIMED ASSETS (anti-stuck-funds)
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice After UNCLAIMED_ASSET_DEADLINE from execution, anyone can sweep
     *         unclaimed pull-based ETH assets to the will's fallback beneficiary.
     * @dev    Only sweeps ETH pending claims for heirs of this specific will.
     *         ERC20/ERC1155 sweeps can be done per-asset via sweepUnclaimedERC20/ERC1155.
     */
    function sweepUnclaimedETH(
        address _owner,
        uint256 _willId
    ) external nonReentrant {
        Will storage will = wills[_owner][_willId];
        require(will.state == WillState.Executed, "Will not executed");
        require(
            block.timestamp >= will.executionStartTime + UNCLAIMED_ASSET_DEADLINE,
            "Deadline not reached"
        );

        address fallback_ = will.fallbackBeneficiary;
        require(fallback_ != address(0), "No fallback beneficiary");

        for (uint256 h = 0; h < will.heirs.length; h++) {
            address heir = will.heirs[h].heirAddress;
            uint256 ethAmount = pendingETH[heir];
            if (ethAmount > 0) {
                pendingETH[heir] = 0;
                (bool ok,) = payable(fallback_).call{value: ethAmount}("");
                if (!ok) {
                    pendingETH[fallback_] += ethAmount;
                }
            }
        }

        emit UnclaimedAssetsSwept(_owner, _willId, fallback_);
    }

    /**
     * @notice Sweep unclaimed ERC20 for a specific token to fallback beneficiary.
     */
    function sweepUnclaimedERC20(
        address _owner,
        uint256 _willId,
        address _token
    ) external nonReentrant {
        Will storage will = wills[_owner][_willId];
        require(will.state == WillState.Executed, "Will not executed");
        require(
            block.timestamp >= will.executionStartTime + UNCLAIMED_ASSET_DEADLINE,
            "Deadline not reached"
        );

        address fallback_ = will.fallbackBeneficiary;
        require(fallback_ != address(0), "No fallback beneficiary");

        for (uint256 h = 0; h < will.heirs.length; h++) {
            address heir = will.heirs[h].heirAddress;
            uint256 amount = pendingERC20[heir][_token];
            if (amount > 0) {
                pendingERC20[heir][_token] = 0;
                IERC20(_token).safeTransfer(fallback_, amount);
            }
        }

        emit UnclaimedAssetsSwept(_owner, _willId, fallback_);
    }

    /**
     * @notice Sweep unclaimed ERC1155 for a specific token/id to fallback beneficiary.
     */
    function sweepUnclaimedERC1155(
        address _owner,
        uint256 _willId,
        address _token,
        uint256 _tokenId
    ) external nonReentrant {
        Will storage will = wills[_owner][_willId];
        require(will.state == WillState.Executed, "Will not executed");
        require(
            block.timestamp >= will.executionStartTime + UNCLAIMED_ASSET_DEADLINE,
            "Deadline not reached"
        );

        address fallback_ = will.fallbackBeneficiary;
        require(fallback_ != address(0), "No fallback beneficiary");

        for (uint256 h = 0; h < will.heirs.length; h++) {
            address heir = will.heirs[h].heirAddress;
            uint256 amount = pendingERC1155[heir][_token][_tokenId];
            if (amount > 0) {
                pendingERC1155[heir][_token][_tokenId] = 0;
                IERC1155(_token).safeTransferFrom(address(this), fallback_, _tokenId, amount, "");
            }
        }

        emit UnclaimedAssetsSwept(_owner, _willId, fallback_);
    }
}
