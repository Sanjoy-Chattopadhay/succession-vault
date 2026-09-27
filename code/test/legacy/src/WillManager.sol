// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "./ExecutionManager.sol";

/**
 * @title UnifiedWillManager
 * @notice Main entry-point contract for the Decentralized Blockchain Will Inheritance System.
 *         Inherits ExecutionManager -> AssetManager -> HeartbeatManager -> WillStorage.
 *
 * TRUSTEE-LESS DECENTRALIZED DESIGN:
 *   - No trustees, no admin (Ownable/Pausable removed)
 *   - Verifier addresses are IMMUTABLE (set once at deployment, cannot be changed)
 *   - Death confirmation via time-based dead-man's switch:
 *       Heartbeat expires -> OwnerInactive -> GracePeriod -> PendingHeirProof
 *       (Total minimum: heartbeat_interval + 30 days + 90 days = ~150 days)
 *   - Owner can recover from OwnerInactive or GracePeriod at any time
 *   - DID-based ZKP liveness proofs (iden3/Privado) for stronger heartbeat verification
 *   - Automatic asset push during execution with pull-based fallback
 *   - Unclaimed asset sweep to fallback beneficiary after 365 days
 *   - Heir proof deadline prevents stuck PendingHeirProof state
 *
 * ONLY EXTERNAL DEPENDENCY: iden3/Privado DID credential system (for ZKP liveness proofs)
 *
 * NON-STANDARD EXTENSIONS:
 *   - ERC721FractionalWrapper represents fractional NFT ownership via ERC-1155 shares.
 *     Standard wallets/marketplaces will not natively display fractional positions.
 *
 * ERC-777 NOTE:
 *   ERC-777 tokens are NOT supported. Their callback hooks create reentrancy vectors.
 *   Wrap ERC-777 tokens into standard ERC-20 before depositing.
 */
contract UnifiedWillManager is ExecutionManager {
    using SafeERC20 for IERC20;

    /**
     * @notice Deploy the will system with immutable verifier addresses.
     * @param _heirAgeVerifier   Address of the Groth16 age verifier (4 signals)
     * @param _livenessVerifier  Address of the Groth16 DID liveness verifier (5 signals)
     */
    constructor(
        address _heirAgeVerifier,
        address _livenessVerifier
    ) {
        require(_heirAgeVerifier != address(0), "Invalid age verifier");
        require(_livenessVerifier != address(0), "Invalid liveness verifier");

        // Set verifiers as IMMUTABLE -- cannot be changed after deployment
        heirAgeVerifier  = _heirAgeVerifier;
        livenessVerifier = ILivenessVerifier(_livenessVerifier);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                          WILL CREATION
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Create a new will in Created state.
     *         No trustees needed -- the system uses time-based dead-man's switch.
     * @param _ownerDidHash         SHA-256 hash of owner's DID (mod BN128 field). Pass 0 to skip DID.
     * @param _fallbackBeneficiary  Address for unclaimed assets after deadline (0 = defaults to owner)
     */
    function createWill(
        uint256 _ownerDidHash,
        address _fallbackBeneficiary
    ) external returns (uint256 willId) {
        willId = willCount[msg.sender]++;
        Will storage will = wills[msg.sender][willId];

        will.owner = msg.sender;
        will.state = WillState.Created;
        will.createdAt = block.timestamp;
        will.lastHeartbeat = block.timestamp;

        // Set fallback beneficiary (defaults to owner if not specified)
        if (_fallbackBeneficiary == address(0)) {
            will.fallbackBeneficiary = msg.sender;
        } else {
            will.fallbackBeneficiary = _fallbackBeneficiary;
        }

        // Register DID if provided
        if (_ownerDidHash != 0) {
            will.ownerDidHash = _ownerDidHash;
            if (!didRecords[_ownerDidHash].isRegistered) {
                didRecords[_ownerDidHash] = DIDRegistration({
                    didHash: _ownerDidHash,
                    ownerAddress: msg.sender,
                    lastLivenessTimestamp: 0,
                    lastExpirationDate: 0,
                    isRegistered: true
                });
                emit DIDRegistered(_ownerDidHash, msg.sender);
            } else {
                require(
                    didRecords[_ownerDidHash].ownerAddress == msg.sender,
                    "DID owned by another"
                );
            }
        }

        emit WillCreated(msg.sender, willId);
        return willId;
    }

    // ═══════════════════════════════════════════════════════════════════
    //                          HEIR MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════

    function addHeir(
        uint256 _willId,
        address _heirAddress,
        uint256 _sharePercentage,
        uint256 _birthdateCommitment,
        uint8   _minimumAge,
        uint256 _vestingPeriod
    ) external {
        Will storage will = wills[msg.sender][_willId];
        require(will.owner == msg.sender, "Not will owner");
        require(will.state == WillState.Created, "Will not in Created state");
        require(_heirAddress != address(0), "Invalid heir");
        require(_sharePercentage > 0 && _sharePercentage <= 10000, "Invalid share");

        will.heirs.push(Heir({
            heirAddress:         _heirAddress,
            sharePercentage:     _sharePercentage,
            birthdateCommitment: _birthdateCommitment,
            minimumAge:          _minimumAge,
            ageVerified:         false,
            vestingPeriod:       _vestingPeriod,
            vestingUnlock:       0
        }));

        emit HeirAdded(msg.sender, _willId, _heirAddress);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                       WILL ACTIVATION
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Activate the will. Locks heirs, assets. Starts heartbeat timer.
     *         No trustee staking check -- fully decentralized.
     */
    function activateWill(uint256 _willId) external {
        Will storage will = wills[msg.sender][_willId];
        require(will.owner == msg.sender, "Not will owner");
        require(will.state == WillState.Created, "Already activated");
        require(will.assets.length > 0, "No assets");
        require(will.heirs.length > 0, "No heirs");
        require(_validateHeirShares(will), "Shares must equal 100%");

        will.state = WillState.Active;
        will.lastHeartbeat = block.timestamp;
        emit WillStateChanged(msg.sender, _willId, WillState.Active);
    }

    function _validateHeirShares(Will storage will) private view returns (bool) {
        uint256 totalShares = 0;
        for (uint256 i = 0; i < will.heirs.length; i++) {
            totalShares += will.heirs[i].sharePercentage;
        }
        return totalShares == 10000;
    }

    // ═══════════════════════════════════════════════════════════════════
    //                     FALLBACK BENEFICIARY MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Owner can update the fallback beneficiary while will is in Created or Active state.
     */
    function setFallbackBeneficiary(uint256 _willId, address _beneficiary) external {
        Will storage will = wills[msg.sender][_willId];
        require(will.owner == msg.sender, "Not owner");
        require(
            will.state == WillState.Created || will.state == WillState.Active,
            "Cannot change after activation"
        );
        require(_beneficiary != address(0), "Invalid beneficiary");
        will.fallbackBeneficiary = _beneficiary;
    }

    // ═══════════════════════════════════════════════════════════════════
    //                       WILL CANCELLATION
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Owner cancels a will and reclaims all deposited assets.
     *         Works in Created, Active, OwnerInactive, or GracePeriod states.
     *         Cancelling from OwnerInactive/GracePeriod also proves the owner is alive.
     */
    function cancelWill(uint256 _willId) external nonReentrant {
        Will storage will = wills[msg.sender][_willId];
        require(will.owner == msg.sender, "Not owner");
        require(
            will.state == WillState.Created    ||
            will.state == WillState.Active     ||
            will.state == WillState.OwnerInactive ||
            will.state == WillState.GracePeriod,
            "Cannot cancel now"
        );

        // Effects: set state before interactions
        will.state = WillState.Cancelled;
        will.inactivityDetectedAt = 0;
        will.gracePeriodStartedAt = 0;
        emit WillStateChanged(msg.sender, _willId, WillState.Cancelled);

        // Interactions: return assets
        for (uint256 i = 0; i < will.assets.length; i++) {
            Asset storage asset = will.assets[i];
            if (asset.amount == 0) continue;

            uint256 amount = asset.amount;
            asset.amount = 0; // Effects before interaction

            if (asset.assetType == AssetType.ETH) {
                (bool ok,) = payable(msg.sender).call{value: amount}("");
                require(ok, "ETH return failed");
            } else if (asset.assetType == AssetType.ERC20) {
                IERC20(asset.tokenContract).safeTransfer(msg.sender, amount);
            } else if (asset.assetType == AssetType.ERC721) {
                IERC721(asset.tokenContract).safeTransferFrom(
                    address(this), msg.sender, asset.tokenId
                );
            } else if (asset.assetType == AssetType.ERC1155) {
                IERC1155(asset.tokenContract).safeTransferFrom(
                    address(this), msg.sender, asset.tokenId, amount, ""
                );
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    //                        VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Get basic overview of a will (trustee-less version).
     */
    function getWill(address _owner, uint256 _willId) external view returns (
        address owner,
        uint256 assetCount,
        uint256 heirCount,
        WillState state,
        uint256 lastHeartbeat,
        uint256 heartbeatInterval
    ) {
        Will storage will = wills[_owner][_willId];
        return (
            will.owner,
            will.assets.length,
            will.heirs.length,
            will.state,
            will.lastHeartbeat,
            _heartbeatInterval(will)
        );
    }

    /**
     * @notice Get extended will details (DID, grace period, fallback info).
     */
    function getWillDetails(address _owner, uint256 _willId) external view returns (
        uint256 ownerDidHash,
        uint256 inactivityDetectedAt,
        uint256 gracePeriodStartedAt,
        address fallbackBeneficiary,
        uint256 heirProofDeadline,
        uint256 verifiedHeirsCount
    ) {
        Will storage will = wills[_owner][_willId];
        return (
            will.ownerDidHash,
            will.inactivityDetectedAt,
            will.gracePeriodStartedAt,
            will.fallbackBeneficiary,
            will.heirProofDeadline,
            will.verifiedHeirsCount
        );
    }

    function getAsset(address _owner, uint256 _willId, uint256 _assetIndex)
        external view returns (Asset memory)
    {
        return wills[_owner][_willId].assets[_assetIndex];
    }

    function getHeir(address _owner, uint256 _willId, uint256 _heirIndex)
        external view returns (Heir memory)
    {
        return wills[_owner][_willId].heirs[_heirIndex];
    }

    /**
     * @notice Get DID registration details.
     */
    function getDIDRecord(uint256 _didHash) external view returns (
        address ownerAddress,
        uint256 lastLivenessTimestamp,
        uint256 lastExpirationDate,
        bool    isRegistered
    ) {
        DIDRegistration storage record = didRecords[_didHash];
        return (
            record.ownerAddress,
            record.lastLivenessTimestamp,
            record.lastExpirationDate,
            record.isRegistered
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    //                       TOKEN RECEIVERS
    // ═══════════════════════════════════════════════════════════════════

    function onERC1155Received(address, address, uint256, uint256, bytes memory)
        public pure returns (bytes4)
    {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] memory, uint256[] memory, bytes memory)
        public pure returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    function onERC721Received(address, address, uint256, bytes memory)
        public pure returns (bytes4)
    {
        return this.onERC721Received.selector;
    }

    /// @notice Accept native ETH deposits
    receive() external payable {}
}
