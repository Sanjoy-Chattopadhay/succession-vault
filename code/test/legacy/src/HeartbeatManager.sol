// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./WillStorage.sol";

/**
 * @title HeartbeatManager
 * @notice Manages owner liveness proofs, heartbeat checks, DID-based ZKP liveness,
 *         and the decentralized death confirmation flow (inactivity -> grace period).
 *
 * TRUSTEE-LESS DESIGN:
 *   Instead of trustees confirming death, the system uses a time-based flow:
 *     1. Heartbeat expires -> anyone calls detectInactivity() -> OwnerInactive
 *     2. After INACTIVITY_CONFIRMATION_DELAY -> anyone calls startGracePeriod() -> GracePeriod
 *     3. After GRACE_PERIOD_DURATION -> heir calls finalizeGracePeriod() -> PendingHeirProof
 *   Owner can recover from OwnerInactive or GracePeriod at any time.
 *
 * DID LIVENESS (merged from LivenessRegistry):
 *   Owner can optionally register an iden3/Privado DID and submit 5-signal
 *   Groth16 liveness proofs as heartbeats for stronger identity verification.
 *
 * TIME ASSUMPTIONS:
 *   block.timestamp skew is <=15 s; for 30-day intervals this is negligible.
 */
abstract contract HeartbeatManager is WillStorage {

    /// @notice owner => delegate address allowed to record heartbeats
    mapping(address => address) public heartbeatDelegates;

    // ────────────── Heartbeat interval helper ──────────────

    function _heartbeatInterval(Will storage will) internal view returns (uint256) {
        if (will.heartbeatIntervalOverride > 0) {
            return will.heartbeatIntervalOverride;
        }
        return DEFAULT_HEARTBEAT_INTERVAL;
    }

    // ────────────── Delegate management ──────────────

    /**
     * @notice Owner pre-registers a delegate who can record heartbeats on their behalf
     *         (e.g., family member who can act if owner is hospitalised).
     */
    function setHeartbeatDelegate(address _delegate) external {
        heartbeatDelegates[msg.sender] = _delegate;
        emit DelegateSet(msg.sender, _delegate);
    }

    // ────────────── Configurable heartbeat interval ──────────────

    /**
     * @notice Owner can set a custom heartbeat interval for a specific will.
     * @param _willId   The will to configure
     * @param _interval New interval in seconds (minimum 7 days, maximum 365 days)
     */
    function setHeartbeatInterval(uint256 _willId, uint256 _interval) external {
        Will storage will = wills[msg.sender][_willId];
        require(will.owner == msg.sender, "Not owner");
        require(
            will.state == WillState.Created || will.state == WillState.Active,
            "Invalid state"
        );
        require(_interval >= 7 days && _interval <= 365 days, "Interval out of range");
        will.heartbeatIntervalOverride = _interval;
    }

    // ═══════════════════════════════════════════════════════════════════
    //                    DID REGISTRATION (iden3/Privado)
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Owner registers their DID hash for a specific will.
     *         Links the owner's iden3/Privado DID to the will for liveness proofs.
     * @param _willId  The will to configure
     * @param _didHash SHA-256 hash of the owner's DID string (mod BN128 field)
     */
    function registerDID(uint256 _willId, uint256 _didHash) external {
        Will storage will = wills[msg.sender][_willId];
        require(will.owner == msg.sender, "Not owner");
        require(
            will.state == WillState.Created || will.state == WillState.Active,
            "Invalid state"
        );
        require(_didHash != 0, "Invalid DID hash");
        require(
            didRecords[_didHash].ownerAddress == address(0) || didRecords[_didHash].ownerAddress == msg.sender,
            "DID owned by another"
        );

        will.ownerDidHash = _didHash;

        if (!didRecords[_didHash].isRegistered) {
            didRecords[_didHash] = DIDRegistration({
                didHash: _didHash,
                ownerAddress: msg.sender,
                lastLivenessTimestamp: 0,
                lastExpirationDate: 0,
                isRegistered: true
            });
        }

        emit DIDRegistered(_didHash, msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                    DID-BASED LIVENESS HEARTBEAT (ZKP)
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Record heartbeat by submitting a DID-based liveness ZKP (5-signal Groth16).
     * @dev Public signals: [isValid, didHash, expirationDate, revocationNonce, currentTimestamp]
     *      This provides stronger liveness proof than a simple heartbeat as it verifies
     *      the owner's DID credential from iden3/Privado.
     */
    function recordHeartbeatWithDIDProof(
        uint256 _willId,
        uint256[2] calldata pA,
        uint256[2][2] calldata pB,
        uint256[2] calldata pC,
        uint256[5] calldata pubSignals
    ) external {
        Will storage will = wills[msg.sender][_willId];
        require(will.owner == msg.sender, "Not owner");
        require(will.state == WillState.Active, "Not active");
        require(will.ownerDidHash != 0, "No DID registered");

        // Validate public signals
        require(pubSignals[0] == 1, "Proof indicates invalid");
        require(pubSignals[1] == will.ownerDidHash, "DID hash mismatch");
        require(pubSignals[2] > block.timestamp, "Credential expired");
        require(!usedLivenessNonces[pubSignals[3]], "Nonce already used");

        // Timestamp within 5-minute window
        require(
            pubSignals[4] >= block.timestamp - 300 && pubSignals[4] <= block.timestamp + 300,
            "Timestamp out of range (5min)"
        );

        // Verify Groth16 proof
        require(
            livenessVerifier.verifyProof(pA, pB, pC, pubSignals),
            "Invalid liveness proof"
        );

        // Effects
        usedLivenessNonces[pubSignals[3]] = true;
        will.lastHeartbeat = block.timestamp;
        will.livenessExpirationDate = pubSignals[2];

        // Update DID record
        didRecords[will.ownerDidHash].lastLivenessTimestamp = block.timestamp;
        didRecords[will.ownerDidHash].lastExpirationDate = pubSignals[2];

        emit HeartbeatRecorded(msg.sender, block.timestamp, true);
        emit DIDLivenessUpdated(will.ownerDidHash, block.timestamp, pubSignals[2]);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                    SIMPLE ON-CHAIN HEARTBEAT
    // ═══════════════════════════════════════════════════════════════════

    function recordHeartbeat(uint256 _willId) external {
        Will storage will = wills[msg.sender][_willId];
        require(will.owner == msg.sender, "Not owner");
        require(will.state == WillState.Active, "Not active");

        will.lastHeartbeat = block.timestamp;
        emit HeartbeatRecorded(msg.sender, block.timestamp, false);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                    DELEGATE HEARTBEAT
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice A pre-registered delegate can record a heartbeat on behalf of the will owner.
     *         This mitigates the "owner falls ill for 30 days" attack vector.
     */
    function recordHeartbeatByDelegate(address _owner, uint256 _willId) external {
        require(heartbeatDelegates[_owner] == msg.sender, "Not authorised delegate");
        Will storage will = wills[_owner][_willId];
        require(will.owner == _owner, "Invalid will");
        require(will.state == WillState.Active, "Not active");

        will.lastHeartbeat = block.timestamp;
        emit HeartbeatRecorded(_owner, block.timestamp, false);
    }

    // ═══════════════════════════════════════════════════════════════════
    //          DECENTRALIZED DEATH CONFIRMATION (replaces trustees)
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Anyone can call this to trigger OwnerInactive state when heartbeat has expired.
     *         This replaces the trustee's role in detecting owner inactivity.
     */
    function detectInactivity(address _owner, uint256 _willId) external {
        Will storage will = wills[_owner][_willId];
        require(will.state == WillState.Active, "Not active");
        require(isOwnerInactive(_owner, _willId), "Owner still active");

        will.state = WillState.OwnerInactive;
        will.inactivityDetectedAt = block.timestamp;

        emit InactivityDetected(_owner, _willId, msg.sender);
        emit WillStateChanged(_owner, _willId, WillState.OwnerInactive);
    }

    /**
     * @notice After INACTIVITY_CONFIRMATION_DELAY from inactivity detection,
     *         anyone can trigger the grace period. This gives additional time
     *         for the owner to prove they are alive.
     */
    function startGracePeriod(address _owner, uint256 _willId) external {
        Will storage will = wills[_owner][_willId];
        require(will.state == WillState.OwnerInactive, "Not in OwnerInactive state");
        require(
            block.timestamp >= will.inactivityDetectedAt + INACTIVITY_CONFIRMATION_DELAY,
            "Confirmation delay not elapsed"
        );

        will.state = WillState.GracePeriod;
        will.gracePeriodStartedAt = block.timestamp;

        emit GracePeriodStarted(_owner, _willId, msg.sender);
        emit WillStateChanged(_owner, _willId, WillState.GracePeriod);
    }

    /**
     * @notice After GRACE_PERIOD_DURATION, any registered heir can finalize the
     *         grace period and move to PendingHeirProof.
     */
    function finalizeGracePeriod(address _owner, uint256 _willId) external {
        Will storage will = wills[_owner][_willId];
        require(will.state == WillState.GracePeriod, "Not in GracePeriod state");
        require(
            block.timestamp >= will.gracePeriodStartedAt + GRACE_PERIOD_DURATION,
            "Grace period not elapsed"
        );
        require(_isValidHeir(will, msg.sender), "Not a registered heir");

        will.state = WillState.PendingHeirProof;
        will.heirProofDeadline = block.timestamp + HEIR_PROOF_DEADLINE;

        emit GracePeriodFinalized(_owner, _willId, msg.sender);
        emit WillStateChanged(_owner, _willId, WillState.PendingHeirProof);
    }

    // ═══════════════════════════════════════════════════════════════════
    //          OWNER RECOVERY (replaces recoverHeartbeat)
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Owner can recover the will from OwnerInactive OR GracePeriod states.
     *         In the trustee-less model, owner recovery is available through
     *         the entire grace period (not just OwnerInactive).
     */
    function recoverWill(uint256 _willId) external {
        Will storage will = wills[msg.sender][_willId];
        require(will.owner == msg.sender, "Not owner");
        require(
            will.state == WillState.OwnerInactive || will.state == WillState.GracePeriod,
            "Cannot recover from this state"
        );

        will.state = WillState.Active;
        will.lastHeartbeat = block.timestamp;
        will.inactivityDetectedAt = 0;
        will.gracePeriodStartedAt = 0;

        emit OwnerRecovered(msg.sender, _willId);
        emit WillStateChanged(msg.sender, _willId, WillState.Active);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                    INACTIVITY CHECK
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Returns true if the owner's heartbeat has expired.
     * @dev    Only meaningful when the will is Active or OwnerInactive.
     */
    function isOwnerInactive(address _owner, uint256 _willId) public view returns (bool) {
        Will storage will = wills[_owner][_willId];
        if (will.state != WillState.Active && will.state != WillState.OwnerInactive) {
            return false;
        }
        return block.timestamp > will.lastHeartbeat + _heartbeatInterval(will);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                    INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @dev Check if an address is a registered heir in the will.
     *      Defined here so finalizeGracePeriod can use it; also used by AssetManager.
     */
    function _isValidHeir(Will storage will, address _heirAddress) internal view returns (bool) {
        for (uint256 i = 0; i < will.heirs.length; i++) {
            if (will.heirs[i].heirAddress == _heirAddress) return true;
        }
        return false;
    }
}
