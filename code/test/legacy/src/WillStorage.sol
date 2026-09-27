// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./WillTypes.sol";
import "./ILivenessVerifier.sol";

/**
 * @title WillStorage
 * @notice Abstract base providing persistent storage layout and events for the
 *         Decentralized Blockchain Will Inheritance System.
 *
 * TRUSTEE-LESS DESIGN:
 *   All trustee-related storage (stakes, approvals, epochs) has been removed.
 *   Death confirmation is replaced by a time-based dead-man's switch with
 *   multi-layered delays (inactivity detection + grace period).
 */
abstract contract WillStorage {

    // ────────────── Core data ──────────────
    mapping(address => mapping(uint256 => Will)) internal wills;
    mapping(address => uint256) public willCount;
    mapping(uint256 => DisputeChallenge) public disputes;

    // ────────────── Verifier references (IMMUTABLE after deployment) ──────────────
    address public heirAgeVerifier;        // Groth16 verifier for age proofs (4 signals)
    ILivenessVerifier public livenessVerifier;  // Groth16 verifier for DID liveness proofs (5 signals)

    // ────────────── DID-based Liveness (merged from LivenessRegistry) ──────────────
    mapping(uint256 => DIDRegistration) public didRecords;    // didHash => registration
    mapping(uint256 => bool) public usedLivenessNonces;       // nonce replay prevention

    // ────────────── Pull-based claims (Checks-Effects-Interactions) ──────────────

    /// @notice pendingETH[beneficiary] = amount (native ETH)
    mapping(address => uint256) public pendingETH;

    /// @notice pendingERC20[beneficiary][token] = amount
    mapping(address => mapping(address => uint256)) public pendingERC20;

    /// @notice pendingERC1155[beneficiary][token][tokenId] = amount
    mapping(address => mapping(address => mapping(uint256 => uint256))) public pendingERC1155;

    /// @notice Ensures divisible-asset allocation happens exactly once per will
    mapping(address => mapping(uint256 => bool)) public divisibleAllocated;

    // ────────────── Heir address rotation (EIP-712) ──────────────

    /// @notice heirRotationNonce[willOwner][willId][heirIndex] -> nonce
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) public heirRotationNonce;

    bytes32 public constant HEIR_ROTATION_TYPEHASH = keccak256(
        "HeirRotation(address owner,uint256 willId,uint256 heirIndex,address oldAddress,address newAddress,uint256 nonce,uint256 deadline)"
    );

    // ────────────── Auto-push tracking ──────────────

    /// @notice pushAttempted[owner][willId][heirIndex] => bool
    mapping(address => mapping(uint256 => mapping(uint256 => bool))) public pushAttempted;

    /// @notice pushSucceeded[owner][willId][heirIndex] => bool
    mapping(address => mapping(uint256 => mapping(uint256 => bool))) public pushSucceeded;

    // ────────────── Constants ──────────────

    uint256 public constant DEFAULT_HEARTBEAT_INTERVAL = 30 days;
    uint256 public constant MAX_BATCH_SIZE = 10;

    // Decentralized death confirmation delays (replaces trustee approval)
    uint256 public constant INACTIVITY_CONFIRMATION_DELAY = 30 days;
    uint256 public constant GRACE_PERIOD_DURATION = 90 days;

    // Dispute mechanism
    uint256 public constant DISPUTE_PERIOD = 7 days;
    uint256 public constant DISPUTE_BOND = 0.1 ether;

    // Anti-stuck-funds
    uint256 public constant UNCLAIMED_ASSET_DEADLINE = 365 days;
    uint256 public constant HEIR_PROOF_DEADLINE = 180 days;

    // Auto-push gas limit (prevents griefing by malicious heir contracts)
    uint256 public constant AUTO_PUSH_GAS_LIMIT = 50000;

    uint256 internal disputeIdCounter;

    // ────────────── Events ──────────────

    // Will lifecycle
    event WillCreated(address indexed owner, uint256 indexed willId);
    event AssetAdded(address indexed owner, uint256 indexed willId, AssetType assetType);
    event HeirAdded(address indexed owner, uint256 indexed willId, address indexed heir);
    event WillStateChanged(address indexed owner, uint256 indexed willId, WillState newState);

    // Heartbeat & liveness
    event HeartbeatRecorded(address indexed owner, uint256 timestamp, bool withProof);
    event DIDRegistered(uint256 indexed didHash, address indexed owner);
    event DIDLivenessUpdated(uint256 indexed didHash, uint256 timestamp, uint256 expirationDate);

    // Decentralized death confirmation (replaces trustee approval)
    event InactivityDetected(address indexed owner, uint256 indexed willId, address indexed detector);
    event GracePeriodStarted(address indexed owner, uint256 indexed willId, address indexed initiator);
    event GracePeriodFinalized(address indexed owner, uint256 indexed willId, address indexed initiator);
    event OwnerRecovered(address indexed owner, uint256 indexed willId);

    // Heir verification & execution
    event HeirAgeVerified(address indexed heir, uint256 indexed willId);
    event InheritanceExecuted(address indexed heir, uint256 indexed willId, uint256 assetIndex);

    // Disputes
    event DisputeRaised(uint256 indexed disputeId, address indexed challenger, uint256 indexed willId);
    event DisputeResolved(uint256 indexed disputeId, address indexed resolver);

    // Pull-based claim events
    event ETHClaimed(address indexed beneficiary, uint256 amount);
    event ERC20Claimed(address indexed beneficiary, address indexed token, uint256 amount);
    event ERC1155Claimed(address indexed beneficiary, address indexed token, uint256 tokenId, uint256 amount);

    // Auto-push events
    event AutoPushAttempted(address indexed heir, uint256 indexed willId, bool success);
    event UnclaimedAssetsSwept(address indexed willOwner, uint256 indexed willId, address indexed beneficiary);

    // Heir rotation events
    event HeirAddressRotated(
        address indexed willOwner,
        uint256 indexed willId,
        uint256 heirIndex,
        address oldAddress,
        address newAddress
    );

    // Heartbeat recovery
    event DelegateSet(address indexed owner, address indexed delegate);
}
