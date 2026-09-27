// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./AssetManager.sol";

/**
 * @title ExecutionManager
 * @notice Handles heir age verification (ZKP), batched inheritance execution,
 *         disputes, heir proof deadlines, and heir address rotation.
 *
 * TRUSTEE-LESS DESIGN:
 *   All trustee slashing and timeout-override logic has been removed.
 *   Disputes now store preDisputeState for correct state restoration.
 *   Expired disputes (owner doesn't respond) return to pre-dispute state.
 *
 * STATE MACHINE TRANSITIONS (managed here + HeartbeatManager + WillManager):
 *   PendingHeirProof -> (all heirs verified) -> ReadyToExecute
 *   ReadyToExecute   -> (batch begins)       -> Executing
 *   Executing        -> (all heirs done)     -> Executed
 *   Any proof stage  -> (dispute bond)       -> Disputed
 *   Disputed         -> (owner resolves)     -> Active
 *   Disputed         -> (deadline expires)   -> preDisputeState
 *   PendingHeirProof -> (deadline expires)   -> GracePeriod (via resetExpiredHeirProof)
 */
abstract contract ExecutionManager is AssetManager {
    using ECDSA for bytes32;

    // ═══════════════════════════════════════════════════════════════════
    //                   EIP-712 DOMAIN (heir rotation)
    // ═══════════════════════════════════════════════════════════════════

    bytes32 private constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(
            EIP712_DOMAIN_TYPEHASH,
            keccak256("WillInheritanceSystem"),
            keccak256("2"),
            block.chainid,
            address(this)
        ));
    }

    // ═══════════════════════════════════════════════════════════════════
    //                    HEIR AGE VERIFICATION (ZKP)
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice An heir submits a Groth16 age proof.  Public signals: [willId, minimumAge, currentYear, commitment].
     * @dev    Uses O(1) verifiedHeirsCount instead of scanning the array.
     */
    function verifyHeirAge(
        address _owner,
        uint256 _willId,
        uint256 _heirIndex,
        uint256[2] calldata pA,
        uint256[2][2] calldata pB,
        uint256[2] calldata pC,
        uint256[4] calldata pubSignals
    ) external {
        Will storage will = wills[_owner][_willId];
        require(will.state == WillState.PendingHeirProof, "Wrong state");
        require(_heirIndex < will.heirs.length, "Invalid heir index");

        Heir storage heir = will.heirs[_heirIndex];
        require(heir.heirAddress == msg.sender, "Not the heir");
        require(!heir.ageVerified, "Already verified");
        require(pubSignals[3] == heir.birthdateCommitment, "Commitment mismatch");

        // Groth16 verification via staticcall
        (bool success, bytes memory data) = heirAgeVerifier.staticcall(
            abi.encodeWithSignature(
                "verifyProof(uint256[2],uint256[2][2],uint256[2],uint256[4])",
                pA, pB, pC, pubSignals
            )
        );
        require(success && abi.decode(data, (bool)), "Invalid age proof");

        // Effects
        heir.ageVerified = true;
        will.verifiedHeirsCount += 1;
        emit HeirAgeVerified(msg.sender, _willId);

        // Transition when all heirs verified
        if (will.verifiedHeirsCount == will.heirs.length) {
            will.state = WillState.ReadyToExecute;
            will.executionStartTime = block.timestamp;
            emit WillStateChanged(_owner, _willId, WillState.ReadyToExecute);
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    //                   BATCHED INHERITANCE EXECUTION
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Execute inheritance in batches of up to MAX_BATCH_SIZE heirs.
     * @dev    Uses auto-push allocation for divisible assets.
     *         Progress marker: will.nextHeirToProcess prevents gas griefing.
     */
    function executeInheritanceBatch(
        address _owner,
        uint256 _willId,
        uint256 _batchSize
    ) external nonReentrant {
        Will storage will = wills[_owner][_willId];
        require(
            will.state == WillState.ReadyToExecute || will.state == WillState.Executing,
            "Not ready"
        );
        require(_batchSize > 0 && _batchSize <= MAX_BATCH_SIZE, "Invalid batch size");

        // First batch: transition & allocate divisible assets with auto-push
        if (will.state == WillState.ReadyToExecute) {
            will.state = WillState.Executing;
            emit WillStateChanged(_owner, _willId, WillState.Executing);

            if (!divisibleAllocated[_owner][_willId]) {
                _allocateDivisibleAssetsToHeirsWithPush(_owner, _willId);
            }
        }

        uint256 processed  = 0;
        uint256 startIndex = will.nextHeirToProcess;

        for (uint256 i = startIndex; i < will.heirs.length && processed < _batchSize; i++) {
            Heir storage heir = will.heirs[i];

            // Vesting check
            if (heir.vestingPeriod > 0) {
                if (heir.vestingUnlock == 0) {
                    heir.vestingUnlock = will.executionStartTime + heir.vestingPeriod;
                }
                if (block.timestamp < heir.vestingUnlock) {
                    will.nextHeirToProcess = i + 1;
                    processed++;
                    continue;
                }
            }

            _transferAssetsToHeir(will, heir, _willId, i);
            processed++;
            will.nextHeirToProcess = i + 1;
        }

        // Completion check
        if (will.nextHeirToProcess >= will.heirs.length) {
            will.state = WillState.Executed;
            emit WillStateChanged(_owner, _willId, WillState.Executed);
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    //                       DISPUTE MECHANISM
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Anyone can dispute during OwnerInactive, GracePeriod, PendingHeirProof,
     *         or ReadyToExecute by posting a bond. Moves will to Disputed state.
     *         Stores preDisputeState so will returns to correct state if dispute expires.
     */
    function disputeExecution(
        address _owner,
        uint256 _willId,
        string calldata _reason
    ) external payable {
        Will storage will = wills[_owner][_willId];
        require(
            will.state == WillState.OwnerInactive   ||
            will.state == WillState.GracePeriod     ||
            will.state == WillState.PendingHeirProof ||
            will.state == WillState.ReadyToExecute,
            "Cannot dispute in current state"
        );
        require(msg.value >= DISPUTE_BOND, "Insufficient bond");

        will.preDisputeState = will.state;

        uint256 disputeId = disputeIdCounter++;
        disputes[disputeId] = DisputeChallenge({
            challenger: msg.sender,
            bond:       msg.value,
            deadline:   block.timestamp + DISPUTE_PERIOD,
            reason:     _reason,
            resolved:   false
        });

        will.state = WillState.Disputed;
        emit DisputeRaised(disputeId, msg.sender, _willId);
        emit WillStateChanged(_owner, _willId, WillState.Disputed);
    }

    /**
     * @notice Owner resolves a dispute by proving they are alive.
     *         Full reset: will goes back to Active, heartbeat refreshed,
     *         heir verifications cleared. Dispute bond goes to owner.
     */
    function resolveDisputeAsOwner(
        uint256 _willId,
        uint256 _disputeId
    ) external {
        Will storage will = wills[msg.sender][_willId];
        require(will.owner == msg.sender, "Not owner");
        require(will.state == WillState.Disputed, "Not disputed");

        DisputeChallenge storage dispute = disputes[_disputeId];
        require(!dispute.resolved, "Already resolved");
        require(block.timestamp <= dispute.deadline, "Dispute expired");

        dispute.resolved = true;

        // Full reset -- owner proved alive
        will.state = WillState.Active;
        will.lastHeartbeat = block.timestamp;
        will.verifiedHeirsCount = 0;
        will.inactivityDetectedAt = 0;
        will.gracePeriodStartedAt = 0;
        will.heirProofDeadline = 0;

        for (uint256 i = 0; i < will.heirs.length; i++) {
            will.heirs[i].ageVerified = false;
        }

        // Return bond to owner (challenger loses bond for false dispute)
        (bool ok,) = payable(msg.sender).call{value: dispute.bond}("");
        require(ok, "Bond return failed");

        emit DisputeResolved(_disputeId, msg.sender);
        emit WillStateChanged(msg.sender, _willId, WillState.Active);
    }

    /**
     * @notice If the dispute deadline passes and the owner did NOT prove alive,
     *         anyone can resolve the dispute. Will returns to pre-dispute state.
     *         Dispute bond is returned to the challenger.
     */
    function resolveExpiredDispute(
        address _owner,
        uint256 _willId,
        uint256 _disputeId
    ) external {
        Will storage will = wills[_owner][_willId];
        require(will.state == WillState.Disputed, "Not disputed");

        DisputeChallenge storage dispute = disputes[_disputeId];
        require(!dispute.resolved, "Already resolved");
        require(block.timestamp > dispute.deadline, "Deadline not passed");

        dispute.resolved = true;

        // Return to pre-dispute state (owner failed to prove alive)
        will.state = will.preDisputeState;

        // Return bond to challenger
        (bool ok,) = payable(dispute.challenger).call{value: dispute.bond}("");
        require(ok, "Bond return failed");

        emit DisputeResolved(_disputeId, dispute.challenger);
        emit WillStateChanged(_owner, _willId, will.preDisputeState);
    }

    // ═══════════════════════════════════════════════════════════════════
    //              HEIR PROOF DEADLINE (anti-stuck-funds)
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice If heirs fail to submit age proofs within HEIR_PROOF_DEADLINE,
     *         anyone can reset the will back to GracePeriod. This prevents
     *         the will from being stuck in PendingHeirProof indefinitely.
     *         Heirs must re-trigger finalizeGracePeriod to try again.
     */
    function resetExpiredHeirProof(address _owner, uint256 _willId) external {
        Will storage will = wills[_owner][_willId];
        require(will.state == WillState.PendingHeirProof, "Not in PendingHeirProof");
        require(block.timestamp > will.heirProofDeadline, "Deadline not passed");

        // Reset heir verification
        will.verifiedHeirsCount = 0;
        for (uint256 i = 0; i < will.heirs.length; i++) {
            will.heirs[i].ageVerified = false;
        }

        // Return to GracePeriod -- heirs can try again via finalizeGracePeriod
        will.state = WillState.GracePeriod;
        will.gracePeriodStartedAt = block.timestamp;

        emit WillStateChanged(_owner, _willId, WillState.GracePeriod);
    }

    // ═══════════════════════════════════════════════════════════════════
    //              HEIR ADDRESS ROTATION (EIP-712 signatures)
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @dev Build the EIP-712 digest for heir address rotation.
     *      Extracted to avoid stack-too-deep in rotateHeirAddress.
     */
    function _buildRotationDigest(
        address _owner,
        uint256 _willId,
        uint256 _heirIndex,
        address _oldAddress,
        address _newAddress,
        uint256 _nonce,
        uint256 _deadline
    ) private view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            HEIR_ROTATION_TYPEHASH,
            _owner,
            _willId,
            _heirIndex,
            _oldAddress,
            _newAddress,
            _nonce,
            _deadline
        ));
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    /**
     * @notice Allow an heir to update their receiving address before execution.
     *         The heir signs an EIP-712 message authorising the rotation; anyone can
     *         submit the transaction (meta-tx friendly).
     */
    function rotateHeirAddress(
        address _owner,
        uint256 _willId,
        uint256 _heirIndex,
        address _newAddress,
        uint256 _deadline,
        bytes calldata _signature
    ) external {
        require(block.timestamp <= _deadline, "Signature expired");
        require(_newAddress != address(0), "Invalid new address");

        Will storage will = wills[_owner][_willId];
        require(will.state != WillState.Executing && will.state != WillState.Executed, "Too late to rotate");
        require(_heirIndex < will.heirs.length, "Invalid heir index");

        Heir storage heir = will.heirs[_heirIndex];
        address oldAddress = heir.heirAddress;

        // Build EIP-712 digest & verify (extracted to reduce stack depth)
        uint256 nonce = heirRotationNonce[_owner][_willId][_heirIndex];
        bytes32 digest = _buildRotationDigest(
            _owner, _willId, _heirIndex, oldAddress, _newAddress, nonce, _deadline
        );
        require(ECDSA.recover(digest, _signature) == oldAddress, "Invalid signature");

        // Effects
        heirRotationNonce[_owner][_willId][_heirIndex] = nonce + 1;
        heir.heirAddress = _newAddress;

        // Update any direct asset assignments
        for (uint256 j = 0; j < will.assets.length; j++) {
            if (will.assets[j].specificHeir == oldAddress) {
                will.assets[j].specificHeir = _newAddress;
            }
        }

        emit HeirAddressRotated(_owner, _willId, _heirIndex, oldAddress, _newAddress);
    }
}
