// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title WillTypes
 * @notice Shared type definitions for the Decentralized Blockchain Will Inheritance System.
 *
 * TRUSTEE-LESS DESIGN:
 *   This system uses a time-based dead-man's switch instead of trustees.
 *   Owner liveness is verified via heartbeats (simple or DID-based ZKP).
 *   After heartbeat expiry, a multi-layered delay (confirmation + grace period)
 *   replaces trustee approval before heirs can claim inheritance.
 *
 * NON-STANDARD EXTENSIONS:
 *   - ERC721FractionalWrapper represents fractional NFT ownership via ERC-1155 shares.
 *     Wallets/marketplaces that only understand vanilla ERC-721 will NOT display
 *     fractional positions.  A dedicated UI or indexer is required.
 *   - The Will struct uses dynamic arrays (Heir[], Asset[]) which
 *     require view helpers in UnifiedWillManager to read individual elements.
 *
 * SUPPORTED TOKEN BEHAVIOURS:
 *   - Native ETH (via payable functions, NOT ERC-20)
 *   - Standard ERC-20 (USDC, DAI, USDT, etc.) — fee-on-transfer tokens are handled by
 *     measuring actual received amounts.
 *   - Standard ERC-721
 *   - ERC-1155 (both fungible amounts and single-item NFTs)
 *   - ERC-777 tokens are NOT supported due to callback-based reentrancy risks.
 *
 * TIME ASSUMPTIONS:
 *   block.timestamp is used throughout.  Miners may skew timestamps by ~15 s.
 *   For intervals >= 30 days this skew is negligible, but callers should be aware.
 */

// ────────────────────────────── Enums ──────────────────────────────

enum AssetType { ETH, ERC20, ERC721, ERC1155 }

/**
 * @notice Explicit will state machine (trustee-less).
 * Transitions are documented in ExecutionManager, HeartbeatManager, and WillManager.
 *
 * Created        -> owner calls createWill
 * Active         -> owner activates the will (assets + heirs locked)
 * OwnerInactive  -> heartbeat expired, anyone triggered detectInactivity()
 * GracePeriod    -> confirmation delay passed, extended waiting for owner recovery
 * PendingHeirProof -> grace period ended; heirs must submit ZKP age proofs
 * Disputed       -> someone posted a dispute bond
 * ReadyToExecute -> all proofs verified, ready to distribute
 * Executing      -> batch execution in progress
 * Executed       -> fully distributed
 * Cancelled      -> owner revoked before execution
 */
enum WillState {
    Created,          // 0
    Active,           // 1
    OwnerInactive,    // 2
    GracePeriod,      // 3  (replaces PendingTrustee)
    PendingHeirProof, // 4
    Disputed,         // 5
    ReadyToExecute,   // 6
    Executing,        // 7
    Executed,         // 8
    Cancelled         // 9
}

// ────────────────────────────── Structs ──────────────────────────────

struct Asset {
    AssetType assetType;
    address tokenContract;   // address(0) for native ETH
    uint256 tokenId;
    uint256 amount;
    address specificHeir;    // address(0) => divisible / percentage-based
}

struct Heir {
    address heirAddress;
    uint256 sharePercentage;     // basis points (0-10000)
    uint256 birthdateCommitment; // Poseidon hash for ZKP age proof
    uint8   minimumAge;
    bool    ageVerified;
    uint256 vestingPeriod;       // seconds after execution start
    uint256 vestingUnlock;       // computed: executionStartTime + vestingPeriod
}

/**
 * @notice DID registration for liveness tracking via iden3/Privado credentials.
 */
struct DIDRegistration {
    uint256 didHash;
    address ownerAddress;
    uint256 lastLivenessTimestamp;
    uint256 lastExpirationDate;
    bool    isRegistered;
}

struct Will {
    address owner;
    Asset[] assets;
    Heir[]  heirs;

    // --- State machine ---
    WillState state;
    uint256 lastHeartbeat;
    uint256 createdAt;
    uint256 executionStartTime;
    uint256 nextHeirToProcess;
    uint256 verifiedHeirsCount;

    // --- Configurable heartbeat ---
    uint256 heartbeatIntervalOverride;  // 0 => use global default

    // --- DID-based liveness ---
    uint256 ownerDidHash;               // owner's DID hash for liveness verification
    uint256 livenessExpirationDate;     // last known credential expiration

    // --- Grace period tracking (replaces trustee approval) ---
    uint256 inactivityDetectedAt;       // timestamp when OwnerInactive was triggered
    uint256 gracePeriodStartedAt;       // timestamp when GracePeriod was entered

    // --- Dispute tracking ---
    WillState preDisputeState;          // state to return to if dispute expires unresolved

    // --- Anti-stuck-funds ---
    address fallbackBeneficiary;        // address for unclaimed assets after deadline
    uint256 heirProofDeadline;          // deadline for heirs to submit age proofs
}

struct DisputeChallenge {
    address challenger;
    uint256 bond;
    uint256 deadline;
    string  reason;
    bool    resolved;
}

/**
 * @notice EIP-712 typed data for heir address rotation.
 * Allows an heir to update their receiving address without exposing PII on-chain.
 */
struct HeirRotationRequest {
    address owner;       // will owner
    uint256 willId;
    uint256 heirIndex;
    address oldAddress;
    address newAddress;
    uint256 nonce;
    uint256 deadline;    // signature expiry
}
