// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IGroth16Verifier} from "./interfaces/IGroth16Verifier.sol";
import {ILivenessRegistry, Groth16Proof} from "./interfaces/ILivenessRegistry.sol";

/// @title BequestVault
/// @notice Per-owner inheritance vault, deployed as an EIP-1167 clone by BequestFactory. The vault
///         address is also the deposit address: ETH and tokens are sent to it with plain transfers.
///
/// Liveness. The owner keeps the vault alive with two kinds of signals:
///   - key-only heartbeats (cheap, ECDSA), which may extend the deadline but never beyond
///     `lastLifeProof + lifeProofInterval`;
///   - proofs of life: a Groth16 proof that the owner's attestation issuer signed a biometric
///     LivenessCredential for the owner's DID at time `t` (see circuits/liveness.circom).
/// Every asset-moving or will-changing action additionally needs a proof of life no older than
/// AUTH_WINDOW. A stolen or posthumously found key can therefore move assets only within
/// AUTH_WINDOW of a genuine proof of life, and can keep the vault alive for at most one
/// lifeProofInterval after the owner's last one.
///
/// Lifecycle. The state is a pure function of block.timestamp and two stored times; no transaction
/// is needed to move between phases:
///   deadline    = min(lastHeartbeat + heartbeatInterval, lastLifeProof + lifeProofInterval)
///   Alive       while now <= deadline
///   Grace       while deadline < now <= deadline + gracePeriod
///   Claimable   afterwards; the first claim settles the vault irrevocably
///   Sweepable   after deadline + gracePeriod + claimWindow: the residue goes to the residuary
///
/// Allocations. Heirs, shares, time-locks and age restrictions are leaves of a Merkle tree whose
/// root is the only allocation data stored on-chain. Each heir claims independently with a Merkle
/// proof; fungible pools are split pro rata by basis points.
contract BequestVault is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    enum Status { Alive, Grace, Claimable, Settled }

    uint8 internal constant ETH = 0;
    uint8 internal constant ERC20 = 1;
    uint8 internal constant ERC721 = 2;
    uint8 internal constant ERC1155 = 3;
    uint256 internal constant BPS = 10_000;
    /// @dev Tolerated difference between the issuer's clock and block.timestamp.
    uint256 public constant MAX_CLOCK_SKEW = 15 minutes;

    struct Config {
        uint32 heartbeatInterval;
        uint32 lifeProofInterval;
        uint32 gracePeriod;
        uint32 claimWindow;
        bytes32 allocationRoot;
        address residuary;
        uint256 livenessBinding;
    }

    /// @notice One Merkle leaf of the will.
    /// @dev    Leaf = keccak256(bytes.concat(keccak256(abi.encode(bequest)))) (OpenZeppelin
    ///         StandardMerkleTree encoding).
    struct Bequest {
        uint256 index;        // position in the claimed-bitmap; unique per will
        address heir;         // recipient
        uint8 kind;           // ETH, ERC20, ERC721 or ERC1155
        address token;        // asset contract (zero for ETH)
        uint256 id;           // token id for ERC721 / ERC1155
        uint16 shareBps;      // share of the fungible pool (ignored for ERC721)
        uint40 notBefore;     // earliest claim time (time-lock / vesting tranche)
        uint8 minAge;         // 0 = no age restriction
        // Poseidon(birthDate YYYYMMDD, salt) when minAge > 0; otherwise a random blinding value
        // (ignored here) that keeps unclaimed leaves, and hence the root, hiding.
        uint256 ageCommitment;
    }

    struct Proof {
        uint256[2] a;
        uint256[2][2] b;
        uint256[2] c;
    }

    IGroth16Verifier public immutable LIVENESS_VERIFIER;
    IGroth16Verifier public immutable AGE_VERIFIER;
    /// @notice Lower bound for every timer; a deployment parameter (short on testnets).
    uint32 public immutable MIN_PERIOD;
    /// @notice Maximum age of the last proof of life for owner actions that move assets.
    uint32 public immutable AUTH_WINDOW;
    /// @notice Optional aggregated-liveness registry; address(0) disables the path entirely.
    ///
    /// A registry epoch carries the same statement as `proveLife`, proven by the same circuit for
    /// many principals at once, so presence recorded there counts exactly as much as a proof of
    /// life submitted here. What it buys is frequency: because an epoch costs the cohort one
    /// transaction rather than one each, the owner can be certified far more often for the same
    /// outlay, which is what shrinks the window in which a death goes unnoticed.
    ILivenessRegistry public immutable REGISTRY;
    /// @notice How many past epochs `deadline()` will scan. Bounds the cost of reading presence.
    uint32 public immutable REGISTRY_LOOKBACK;
    /// @notice The least time REGISTRY_LOOKBACK epochs can span: each lasts at least the registry's
    ///         MIN_EPOCH_LENGTH. Every vault's lifeProof + grace (plus clock skew) must fit inside
    ///         it, so no burst of epochs, however fast, can push a presence out of the lookback while
    ///         that presence could still keep the vault alive.
    uint256 public immutable REGISTRY_SPAN;

    // Storage is packed so that every hot path touches at most two slots.
    // slot 0: everything a heartbeat or proof of life reads and writes
    address public owner;
    uint40 public lastHeartbeat;
    uint40 public lastLifeProof;
    bool public settled;
    /// @notice Set by the first zero-knowledge proof of life; until then lastLifeProof is only the
    ///         creation time, which bounds heartbeats but does not authorize owner actions.
    bool public lifeProven;
    // slot 1: configuration; timers are kept in minutes (uint24 covers 31 years)
    address public residuary;
    uint24 internal _heartbeatMinutes;
    uint24 internal _lifeProofMinutes;
    uint24 internal _graceMinutes;
    uint24 internal _claimWindowMinutes;
    // slot 2
    bytes32 public allocationRoot;

    /// @notice Registered Poseidon(issuerAx, issuerAy, subjectDid, salt) bindings (one per issuer),
    ///         each with the number of distinct issuers that must attest together before a proof
    ///         under it counts: 0 = not registered, 1 = this issuer alone suffices (the default),
    ///         j > 1 = only a `proveLifeMulti` with at least j distinct registered bindings counts.
    ///         With every binding at 1, registering m issuers adds availability but any one of them
    ///         can extend the deadline; with all at j, up to j - 1 compromised issuers are tolerated.
    mapping(uint256 binding => uint8) public bindingThreshold;
    /// @notice Basis points already paid out of each fungible pool keccak256(kind, token, id).
    mapping(bytes32 pool => uint256) public paidBps;
    mapping(uint256 word => uint256) private _claimedBitmap;

    event Heartbeat();
    event LifeProven(uint256 livenessTime);
    event Claimed(uint256 indexed index, address indexed heir, uint8 kind, address token, uint256 id, uint256 amount);
    event Swept(uint8 kind, address indexed token, uint256 id, uint256 amount, address indexed residuary);
    event Withdrawn(uint8 kind, address indexed token, uint256 id, uint256 amount, address indexed to);
    event AllocationRootSet(bytes32 root);
    event BindingSet(uint256 binding, uint8 threshold);
    event ResiduarySet(address indexed residuary);
    event TimersSet(uint32 heartbeatInterval, uint32 lifeProofInterval, uint32 gracePeriod, uint32 claimWindow);

    error AlreadyInitialized();
    error NotOwner();
    error VaultSettled();
    error ProofOfLifeRequired();
    error UnknownBinding();
    error StaleOrFutureProof();
    error InvalidProof();
    error NotClaimable();
    error TimeLocked();
    error InvalidBequest();
    error AlreadyClaimed();
    error InvalidShare();
    error AgeProofRequired();
    error AgeNotReached();
    error ClaimWindowOpen();
    error InvalidConfig();
    error TransferFailed();
    error ThresholdNotMet();

    constructor(
        IGroth16Verifier livenessVerifier,
        IGroth16Verifier ageVerifier,
        uint32 minPeriod,
        uint32 authWindow,
        ILivenessRegistry registry,
        uint32 registryLookback
    ) {
        LIVENESS_VERIFIER = livenessVerifier;
        AGE_VERIFIER = ageVerifier;
        MIN_PERIOD = minPeriod;
        AUTH_WINDOW = authWindow;
        REGISTRY = registry;
        REGISTRY_LOOKBACK = registryLookback;
        uint256 span;
        if (address(registry) != address(0)) {
            if (registryLookback == 0 || registryLookback > registry.MAX_LOOKBACK()) revert InvalidConfig();
            span = uint256(registryLookback) * registry.MIN_EPOCH_LENGTH();
        }
        REGISTRY_SPAN = span;
        owner = address(0xdead); // the implementation itself can never be initialized
    }

    /// @notice Called once by the factory in the clone-creation transaction.
    function initialize(address owner_, Config calldata cfg) external {
        if (owner != address(0)) revert AlreadyInitialized();
        if (owner_ == address(0)) revert InvalidConfig();
        _setTimers(cfg.heartbeatInterval, cfg.lifeProofInterval, cfg.gracePeriod, cfg.claimWindow);
        _setResiduary(cfg.residuary);
        owner = owner_;
        // Creating the vault is itself evidence that the owner is alive.
        lastHeartbeat = uint40(block.timestamp);
        lastLifeProof = uint40(block.timestamp);
        if (cfg.allocationRoot != bytes32(0)) _setRoot(cfg.allocationRoot);
        if (cfg.livenessBinding != 0) _setBinding(cfg.livenessBinding, 1);
    }

    // ------------------------------------------------------------------ liveness

    /// @notice Key-only heartbeat. It cannot push the deadline past lastLifeProof +
    ///         lifeProofInterval: deadline() takes the minimum, so no extra check is needed here.
    function heartbeat() external {
        if (msg.sender != owner) revert NotOwner();
        if (settled) revert VaultSettled();
        lastHeartbeat = uint40(block.timestamp);
        emit Heartbeat();
    }

    /// @notice Record a zero-knowledge proof of life. Callable by anyone (e.g. a relayer): the
    ///         statement "the owner was alive at `livenessTime`" is true whoever submits it.
    /// @param binding      public signal 0 of the liveness circuit
    /// @param livenessTime public signal 1: the credential's livenessTimestamp
    function proveLife(Proof calldata p, uint256 binding, uint256 livenessTime) external {
        if (settled) revert VaultSettled();
        uint8 threshold = bindingThreshold[binding];
        if (threshold == 0) revert UnknownBinding();
        if (threshold != 1) revert ThresholdNotMet();
        // Monotonic: an old credential can never be replayed.
        if (livenessTime <= lastLifeProof || livenessTime > block.timestamp + MAX_CLOCK_SKEW) {
            revert StaleOrFutureProof();
        }
        if (!LIVENESS_VERIFIER.verifyProof(p.a, p.b, p.c, [binding, livenessTime])) revert InvalidProof();
        lastLifeProof = uint40(livenessTime);
        if (livenessTime > lastHeartbeat) lastHeartbeat = uint40(livenessTime);
        lifeProven = true;
        emit LifeProven(livenessTime);
    }

    /// @notice Proof of life from several issuers at once, for bindings that require a threshold.
    ///         Each proof is checked exactly as in `proveLife`; the bindings must be distinct
    ///         (strictly increasing) and each binding's threshold must not exceed their number.
    ///         The recorded liveness time is the earliest of the attested times, so the vault is
    ///         kept alive only as long as the least recent of the required issuers vouches for.
    function proveLifeMulti(Proof[] calldata ps, uint256[] calldata bindings, uint256[] calldata livenessTimes)
        external
    {
        if (settled) revert VaultSettled();
        uint256 n = ps.length;
        if (n == 0 || bindings.length != n || livenessTimes.length != n) revert InvalidConfig();
        uint256 last = lastLifeProof;
        uint256 earliest = type(uint256).max;
        for (uint256 i; i < n; ++i) {
            if (i > 0 && bindings[i] <= bindings[i - 1]) revert InvalidConfig();
            if (bindingThreshold[bindings[i]] > n) revert ThresholdNotMet();
            _checkLifeProof(ps[i], bindings[i], livenessTimes[i], last);
            if (livenessTimes[i] < earliest) earliest = livenessTimes[i];
        }
        lastLifeProof = uint40(earliest);
        if (earliest > lastHeartbeat) lastHeartbeat = uint40(earliest);
        lifeProven = true;
        emit LifeProven(earliest);
    }

    /// @dev Registered binding, fresh and not future-dated time, valid proof.
    function _checkLifeProof(Proof calldata p, uint256 binding, uint256 t, uint256 last) internal view {
        if (bindingThreshold[binding] == 0) revert UnknownBinding();
        if (t <= last || t > block.timestamp + MAX_CLOCK_SKEW) revert StaleOrFutureProof();
        if (!LIVENESS_VERIFIER.verifyProof(p.a, p.b, p.c, [binding, t])) revert InvalidProof();
    }

    /// @notice Whether `binding` is registered (with any threshold).
    function isBinding(uint256 binding) external view returns (bool) {
        return bindingThreshold[binding] != 0;
    }

    // ------------------------------------------------------------------ aggregated liveness

    /// @notice Claim this vault's enrollment slot in the registry, so that cohort epochs count as
    ///         proofs of life for it. The binding must already be registered here, which is what
    ///         ties the slot to an issuer and DID the owner chose.
    /// @dev    Deliberately not `onlyLiveOwner`: a new vault has no proof of life yet, and
    ///         enrolling neither moves assets nor changes the will.
    function enrollInRegistry(Groth16Proof calldata p, uint256 newRoot, uint256 binding)
        external
        returns (uint256 slot)
    {
        if (msg.sender != owner) revert NotOwner();
        if (settled) revert VaultSettled();
        // A registry epoch is one issuer's attestation, so only a binding that suffices alone can
        // enroll, and presence read back later counts only while the binding still does.
        if (address(REGISTRY) == address(0) || bindingThreshold[binding] != 1) revert UnknownBinding();
        slot = REGISTRY.enroll(p, newRoot, binding);
    }

    /// @notice Liveness time this vault can read out of the registry, or 0 if there is none.
    ///         Only a binding the owner registered here is accepted, so the registry cannot
    ///         substitute a different principal's attestation for the owner's.
    function registryLifeProof() public view returns (uint40) {
        ILivenessRegistry registry = REGISTRY;
        if (address(registry) == address(0)) return 0;
        (uint256 binding, uint64 since) = registry.presenceOf(address(this), REGISTRY_LOOKBACK);
        if (since == 0 || bindingThreshold[binding] != 1) return 0;
        if (uint256(since) > block.timestamp + MAX_CLOCK_SKEW) return 0;
        return uint40(since);
    }

    /// @notice The later of the locally recorded proof of life and the registry's, and whether any
    ///         real proof of life exists at all.
    function presence() public view returns (bool proven, uint40 at) {
        at = lastLifeProof;
        proven = lifeProven;
        uint40 fromRegistry = registryLifeProof();
        if (fromRegistry != 0) {
            proven = true;
            if (fromRegistry > at) at = fromRegistry;
        }
    }

    /// @notice Copy the registry's presence into local storage. Never required - `deadline()` and
    ///         owner actions already read the registry - but it makes later reads cheap and leaves
    ///         a local record that survives the registry's lookback window.
    function syncFromRegistry() external {
        if (settled) revert VaultSettled();
        uint40 fromRegistry = registryLifeProof();
        if (fromRegistry <= lastLifeProof) revert StaleOrFutureProof();
        lastLifeProof = fromRegistry;
        if (fromRegistry > lastHeartbeat) lastHeartbeat = fromRegistry;
        lifeProven = true;
        emit LifeProven(fromRegistry);
    }

    // ------------------------------------------------------------------ owner actions (key + recent proof of life)

    modifier onlyLiveOwner() {
        if (msg.sender != owner) revert NotOwner();
        if (settled) revert VaultSettled();
        (bool proven, uint40 at) = presence();
        if (!proven || block.timestamp > uint256(at) + AUTH_WINDOW) revert ProofOfLifeRequired();
        _;
    }

    function withdraw(uint8 kind, address token, uint256 id, uint256 amount, address to)
        external
        onlyLiveOwner
        nonReentrant
    {
        _transferOut(kind, token, id, amount, to);
        emit Withdrawn(kind, token, id, amount, to);
    }

    function setAllocationRoot(bytes32 root) external onlyLiveOwner {
        _setRoot(root);
    }

    function setBinding(uint256 binding, bool allowed) external onlyLiveOwner {
        _setBinding(binding, allowed ? 1 : 0);
    }

    /// @notice Register or update a binding with a threshold (0 removes it); see `bindingThreshold`.
    function setBindingThreshold(uint256 binding, uint8 threshold) external onlyLiveOwner {
        _setBinding(binding, threshold);
    }

    function setResiduary(address residuary_) external onlyLiveOwner {
        _setResiduary(residuary_);
    }

    function setTimers(uint32 heartbeat_, uint32 lifeProof_, uint32 grace_, uint32 claimWindow_)
        external
        onlyLiveOwner
    {
        _setTimers(heartbeat_, lifeProof_, grace_, claimWindow_);
    }

    // ------------------------------------------------------------------ succession

    function claim(Bequest calldata b, bytes32[] calldata merkleProof) external nonReentrant {
        if (b.minAge != 0) revert AgeProofRequired();
        _claim(b, merkleProof);
    }

    /// @param cutoff YYYYMMDD bound proven by the heir (birthDate <= cutoff); it must not exceed
    ///               the cutoff implied by today's date and the bequest's minimum age.
    function claimWithAgeProof(Bequest calldata b, bytes32[] calldata merkleProof, Proof calldata p, uint256 cutoff)
        external
        nonReentrant
    {
        if (b.minAge == 0) revert InvalidBequest();
        if (cutoff > ageCutoff(block.timestamp, b.minAge)) revert AgeNotReached();
        if (!AGE_VERIFIER.verifyProof(p.a, p.b, p.c, [b.ageCommitment, cutoff])) revert InvalidProof();
        _claim(b, merkleProof);
    }

    /// @notice Claim several bequests in one transaction, e.g. every bequest of one heir.
    function claimMany(Bequest[] calldata bs, bytes32[][] calldata merkleProofs) external nonReentrant {
        if (bs.length != merkleProofs.length) revert InvalidBequest();
        for (uint256 i; i < bs.length; ++i) {
            if (bs[i].minAge != 0) revert AgeProofRequired();
            _claim(bs[i], merkleProofs[i]);
        }
    }

    /// @notice Claim several age-restricted bequests that share one age commitment (one heir) with a
    ///         single age proof. `cutoff` must be admissible for every bequest's minimum age.
    function claimManyWithAgeProof(
        Bequest[] calldata bs,
        bytes32[][] calldata merkleProofs,
        Proof calldata p,
        uint256 cutoff
    ) external nonReentrant {
        if (bs.length == 0 || bs.length != merkleProofs.length) revert InvalidBequest();
        uint256 commitment = bs[0].ageCommitment;
        for (uint256 i; i < bs.length; ++i) {
            if (bs[i].minAge == 0 || bs[i].ageCommitment != commitment) revert InvalidBequest();
            if (cutoff > ageCutoff(block.timestamp, bs[i].minAge)) revert AgeNotReached();
        }
        if (!AGE_VERIFIER.verifyProof(p.a, p.b, p.c, [commitment, cutoff])) revert InvalidProof();
        for (uint256 i; i < bs.length; ++i) {
            _claim(bs[i], merkleProofs[i]);
        }
    }

    /// @notice After the claim window, anyone can move what is left of an asset to the residuary.
    function sweep(uint8 kind, address token, uint256 id) external nonReentrant {
        if (block.timestamp <= claimableAt() + claimWindow()) revert ClaimWindowOpen();
        if (!settled) settled = true;
        uint256 amount = kind == ERC721 ? 1 : _balance(kind, token, id);
        address to = residuary;
        _transferOut(kind, token, id, amount, to);
        emit Swept(kind, token, id, amount, to);
    }

    function _claim(Bequest calldata b, bytes32[] calldata merkleProof) internal {
        // The first claim freezes the will. Once settled, the timers can no longer change, so
        // later claims skip the deadline computation.
        if (!settled) {
            if (block.timestamp <= claimableAt()) revert NotClaimable();
            settled = true;
        }
        if (block.timestamp < b.notBefore) revert TimeLocked();

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(b))));
        if (!MerkleProof.verifyCalldata(merkleProof, allocationRoot, leaf)) revert InvalidBequest();

        uint256 wordIndex = b.index >> 8;
        uint256 bit = 1 << (b.index & 0xff);
        uint256 word = _claimedBitmap[wordIndex];
        if (word & bit != 0) revert AlreadyClaimed();
        _claimedBitmap[wordIndex] = word | bit;

        uint256 amount = 1;
        if (b.kind == ERC721) {
            IERC721(b.token).transferFrom(address(this), b.heir, b.id);
        } else {
            // Pro rata over what is still unpaid: amount = balance * share / (100% - paid).
            // Exact for fully allocated pools (the last heir receives the rounding dust) and
            // fair to assets that arrive after the first claim.
            bytes32 pool = keccak256(abi.encode(b.kind, b.token, b.id));
            uint256 paid = paidBps[pool];
            if (b.shareBps == 0 || paid + b.shareBps > BPS) revert InvalidShare();
            amount = _balance(b.kind, b.token, b.id) * b.shareBps / (BPS - paid);
            paidBps[pool] = paid + b.shareBps;
            _transferOut(b.kind, b.token, b.id, amount, b.heir);
        }
        emit Claimed(b.index, b.heir, b.kind, b.token, b.id, amount);
    }

    // ------------------------------------------------------------------ views

    function deadline() public view returns (uint256) {
        (, uint40 at) = presence();
        // A proof of life is also a heartbeat: `proveLife` stores tH = max(tH, tau), and presence
        // read from the registry has to mean the same thing, or a cohort member would still need
        // to send key heartbeats and the aggregation would buy them nothing.
        uint256 beat = lastHeartbeat;
        if (at > beat) beat = at;
        uint256 byHeartbeat = beat + heartbeatInterval();
        uint256 byLifeProof = uint256(at) + lifeProofInterval();
        return byHeartbeat < byLifeProof ? byHeartbeat : byLifeProof;
    }

    function claimableAt() public view returns (uint256) {
        return deadline() + gracePeriod();
    }

    function heartbeatInterval() public view returns (uint256) {
        return uint256(_heartbeatMinutes) * 1 minutes;
    }

    function lifeProofInterval() public view returns (uint256) {
        return uint256(_lifeProofMinutes) * 1 minutes;
    }

    function gracePeriod() public view returns (uint256) {
        return uint256(_graceMinutes) * 1 minutes;
    }

    function claimWindow() public view returns (uint256) {
        return uint256(_claimWindowMinutes) * 1 minutes;
    }

    function status() external view returns (Status) {
        if (settled) return Status.Settled;
        uint256 d = deadline();
        if (block.timestamp <= d) return Status.Alive;
        if (block.timestamp <= d + gracePeriod()) return Status.Grace;
        return Status.Claimable;
    }

    function isClaimed(uint256 index) external view returns (bool) {
        return _claimedBitmap[index >> 8] & (1 << (index & 0xff)) != 0;
    }

    /// @notice Latest admissible YYYYMMDD birth date for someone who must be `minAge` at `timestamp`.
    function ageCutoff(uint256 timestamp, uint8 minAge) public pure returns (uint256) {
        (uint256 y, uint256 m, uint256 d) = _civilFromDays(timestamp / 1 days);
        return (y - minAge) * 10_000 + m * 100 + d;
    }

    // ------------------------------------------------------------------ token plumbing

    receive() external payable {}

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 // ERC-165
            || interfaceId == 0x150b7a02 // ERC721Receiver
            || interfaceId == 0x4e2312e0; // ERC1155Receiver
    }

    function _balance(uint8 kind, address token, uint256 id) internal view returns (uint256) {
        if (kind == ETH) return address(this).balance;
        if (kind == ERC20) return IERC20(token).balanceOf(address(this));
        if (kind == ERC1155) return IERC1155(token).balanceOf(address(this), id);
        revert InvalidBequest();
    }

    function _transferOut(uint8 kind, address token, uint256 id, uint256 amount, address to) internal {
        if (kind == ETH) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else if (kind == ERC20) {
            IERC20(token).safeTransfer(to, amount);
        } else if (kind == ERC721) {
            IERC721(token).transferFrom(address(this), to, id);
        } else if (kind == ERC1155) {
            IERC1155(token).safeTransferFrom(address(this), to, id, amount, "");
        } else {
            revert InvalidBequest();
        }
    }

    // ------------------------------------------------------------------ internal setters

    /// @dev Timers are given in seconds and must be whole minutes of at least MIN_PERIOD. A vault
    ///      that reads a registry must also fit lifeProof + grace inside REGISTRY_SPAN: a presence
    ///      can then leave the lookback only once it could no longer keep the vault alive.
    function _setTimers(uint32 heartbeat_, uint32 lifeProof_, uint32 grace_, uint32 claimWindow_) internal {
        _heartbeatMinutes = _toMinutes(heartbeat_);
        _lifeProofMinutes = _toMinutes(lifeProof_);
        _graceMinutes = _toMinutes(grace_);
        _claimWindowMinutes = _toMinutes(claimWindow_);
        if (address(REGISTRY) != address(0) && uint256(lifeProof_) + grace_ + MAX_CLOCK_SKEW >= REGISTRY_SPAN) {
            revert InvalidConfig();
        }
        emit TimersSet(heartbeat_, lifeProof_, grace_, claimWindow_);
    }

    function _toMinutes(uint32 secs) internal view returns (uint24) {
        if (secs < MIN_PERIOD || secs % 1 minutes != 0 || secs / 1 minutes > type(uint24).max) revert InvalidConfig();
        return uint24(secs / 1 minutes);
    }

    function _setRoot(bytes32 root) internal {
        allocationRoot = root;
        emit AllocationRootSet(root);
    }

    function _setBinding(uint256 binding, uint8 threshold) internal {
        if (binding == 0) revert InvalidConfig();
        bindingThreshold[binding] = threshold;
        emit BindingSet(binding, threshold);
    }

    function _setResiduary(address residuary_) internal {
        if (residuary_ == address(0)) revert InvalidConfig();
        residuary = residuary_;
        emit ResiduarySet(residuary_);
    }

    /// @dev Days since 1970-01-01 -> proleptic Gregorian (y, m, d); H. Hinnant's civil_from_days.
    ///      The truncating divisions are the algorithm (exact integer arithmetic), not precision
    ///      loss; test_AgeCutoff_* and the calendar fuzz test check it.
    // slither-disable-start divide-before-multiply
    function _civilFromDays(uint256 z) internal pure returns (uint256 y, uint256 m, uint256 d) {
        z += 719_468;
        uint256 era = z / 146_097;
        uint256 doe = z - era * 146_097;
        uint256 yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        d = doy - (153 * mp + 2) / 5 + 1;
        m = mp < 10 ? mp + 3 : mp - 9;
        y = yoe + era * 400 + (m <= 2 ? 1 : 0);
    }
    // slither-disable-end divide-before-multiply
}
