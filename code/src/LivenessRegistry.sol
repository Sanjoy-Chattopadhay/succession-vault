// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivenessRegistry, Groth16Proof} from "./interfaces/ILivenessRegistry.sol";

/// @title LivenessRegistry
/// @notice An append-only record of who proved they were alive, epoch by epoch, for a cohort of
///         enrolled principals. One Groth16 proof and one transaction cover the whole cohort, so
///         the on-chain cost of an epoch does not grow with the number of principals in it.
///
/// Why aggregate at all. A proof of life is an obligation that recurs forever: every principal
/// must produce one every interval, for the rest of their life. Any per-principal signal - an
/// ECDSA heartbeat, a passkey assertion, a single-principal SNARK - costs at least the 21,000 gas
/// of its own transaction, which puts a floor under how often a population can be asked to
/// certify. That floor is not a cost problem, it is a security parameter: the interval between
/// attestations is exactly the window in which a death can go unnoticed and a disbursement can be
/// collected by someone else. Aggregation removes the floor, and the budget that used to buy one
/// attestation a year buys hundreds.
///
/// What the aggregator can and cannot do. The batch circuit checks, for every principal marked
/// present, the issuer's signature over their LivenessCredential and the enrollment slot that
/// credential belongs to. Soundness therefore gives an unconditional guarantee in the direction
/// that matters: the aggregator cannot make a silent principal appear alive, whatever it does with
/// the witnesses it holds, and it cannot hide a recorded presence while that presence still keeps
/// a vault alive (see `submitEpoch`). It can only omit a principal who did attest. That
/// failure is visible (the principal's bit is zero in a public record), attributable to the epoch,
/// and recoverable: the principal falls back to the single-principal `proveLife` path on their own
/// vault, which needs no aggregator at all. Censorship costs a principal one transaction; it never
/// costs them their assets, because the vault's grace period outlasts the epoch.
///
/// Enrollment. A principal claims a free slot by proving that the enrollment tree's root moves
/// from "slot empty" to "slot holds my binding", leaving every other slot untouched. The registry
/// therefore never has to be trusted to maintain the tree honestly, and no one can install their
/// own binding in someone else's slot.
contract LivenessRegistry is ILivenessRegistry {
    /// @notice Presence bits packed per word; 31 bytes, the widest byte-aligned value that always
    ///         fits in the BN254 scalar field. Must equal BITS_PER_WORD in circuits/lib/batch.circom.
    uint256 public constant BITS_PER_WORD = 248;
    /// @notice Tolerated difference between the issuer's clock and block.timestamp.
    uint256 public constant MAX_CLOCK_SKEW = 15 minutes;

    struct Epoch {
        uint64 start; // inclusive lower bound on the liveness timestamps in this epoch
        uint64 end;   // inclusive upper bound
        uint64 at;    // block.timestamp when the epoch was recorded
    }

    /// @notice Verifier for circuits/enroll.circom (4 public signals).
    address public immutable ENROLL_VERIFIER;
    /// @notice Verifier for the cohort's EpochAttestation circuit (4 + WORDS public signals).
    address public immutable EPOCH_VERIFIER;
    /// @notice Presence words per epoch; sets the public-signal count of the epoch circuit.
    uint256 public immutable WORDS;
    /// @notice Enrollment slots this cohort accepts, i.e. the N of its EpochAttestation circuit.
    ///         Bits at or beyond CAPACITY are forced to zero inside the circuit, so a larger word
    ///         count never silently widens the cohort.
    uint256 public immutable CAPACITY;
    /// @notice Upper bound on how many past epochs a presence query may scan.
    uint256 public immutable override MAX_LOOKBACK;
    /// @notice The only address that may submit epochs (see `submitEpoch`).
    address public immutable AGGREGATOR;
    /// @notice Shortest epoch the registry accepts, `end - start` in seconds (see `submitEpoch`).
    uint64 public immutable override MIN_EPOCH_LENGTH;

    bytes4 private immutable _EPOCH_SELECTOR;

    /// @notice Root of the depth-16 Poseidon enrollment tree; leaf i is principal i's binding.
    uint256 public enrollRoot;
    /// @notice Next free enrollment slot.
    uint256 public nextSlot;

    mapping(uint256 slot => uint256 binding) public bindingAt;
    mapping(address principal => uint256 slot) private _slotOfPlusOne;

    Epoch[] private _epochs;
    /// @dev attendance[epochId][word] is the packed presence bitmap verified for that epoch.
    mapping(uint256 epochId => mapping(uint256 word => uint256)) private _attendance;

    event Enrolled(address indexed principal, uint256 indexed slot, uint256 binding, uint256 newRoot);
    event EpochRecorded(uint256 indexed epochId, uint64 start, uint64 end, uint256 words);

    error SlotTaken();
    error CohortFull();
    error InvalidProof();
    error BadEpoch();
    error BadWordCount();
    error LookbackTooLong();
    error NotAggregator();

    /// @param emptyRoot Root of an all-zero depth-16 Poseidon tree (computed off-chain once).
    /// @param aggregator The only epoch submitter; address(0) makes it the deployer.
    /// @param minEpochLength Shortest accepted epoch, `end - start`, in seconds.
    constructor(
        address enrollVerifier,
        address epochVerifier,
        uint256 words,
        uint256 capacity,
        uint256 maxLookback,
        uint256 emptyRoot,
        address aggregator,
        uint64 minEpochLength
    ) {
        ENROLL_VERIFIER = enrollVerifier;
        EPOCH_VERIFIER = epochVerifier;
        WORDS = words;
        CAPACITY = capacity;
        MAX_LOOKBACK = maxLookback;
        AGGREGATOR = aggregator == address(0) ? msg.sender : aggregator;
        MIN_EPOCH_LENGTH = minEpochLength;
        enrollRoot = emptyRoot;
        _EPOCH_SELECTOR = _verifySelector(4 + words);
    }

    // ------------------------------------------------------------------ enrollment

    /// @notice Claim the next free enrollment slot for `binding`, once per principal.
    /// @param newRoot The enrollment root after inserting `binding` at slot `nextSlot`.
    function enroll(Groth16Proof calldata p, uint256 newRoot, uint256 binding) external override returns (uint256 slot) {
        if (_slotOfPlusOne[msg.sender] != 0) revert SlotTaken();
        slot = nextSlot;
        if (slot >= CAPACITY) revert CohortFull();

        uint256[] memory pub = new uint256[](4);
        pub[0] = enrollRoot;
        pub[1] = newRoot;
        pub[2] = slot;
        pub[3] = binding;
        if (!_verify(ENROLL_VERIFIER, _verifySelector(4), p, pub)) revert InvalidProof();

        enrollRoot = newRoot;
        nextSlot = slot + 1;
        bindingAt[slot] = binding;
        _slotOfPlusOne[msg.sender] = slot + 1;
        emit Enrolled(msg.sender, slot, binding, newRoot);
    }

    // ------------------------------------------------------------------ epochs

    /// @notice Record one epoch of the cohort's attendance. Only AGGREGATOR may call it; the proof,
    ///         not the sender, is what makes each recorded bit trustworthy.
    /// @param words Packed presence bits; word w bit j is the principal at slot w * 248 + j.
    ///
    /// Epochs may not overlap and may not be back-dated past the previous epoch's end, so a single
    /// credential can satisfy at most one epoch. Without that rule an aggregator could replay one
    /// scan into every future epoch and the attestation interval would mean nothing.
    ///
    /// Why one submitter and a minimum length. An all-zero bitmap needs no credential at all (every
    /// per-slot check in the circuit is gated by its presence bit). If anyone could submit epochs of
    /// any length, anyone could push a burst of empty epochs past a vault's lookback and hide a
    /// presence that still keeps the vault alive, or pre-empt an interval so the aggregator cannot
    /// record it. One designated submitter keeps the aggregator's power where it belongs, to omit and
    /// never to forge; the minimum length bounds even the aggregator, because `lookback` epochs then
    /// span at least lookback * MIN_EPOCH_LENGTH, and a vault accepts only timers under which a
    /// presence that old can no longer keep it alive (BequestVault.REGISTRY_SPAN).
    function submitEpoch(Groth16Proof calldata p, uint64 start, uint64 end, uint256[] calldata words)
        external
        returns (uint256 epochId)
    {
        if (msg.sender != AGGREGATOR) revert NotAggregator();
        if (words.length != WORDS) revert BadWordCount();
        if (start > end || end - start < MIN_EPOCH_LENGTH || uint256(end) > block.timestamp + MAX_CLOCK_SKEW) {
            revert BadEpoch();
        }
        epochId = _epochs.length;
        if (epochId != 0 && start <= _epochs[epochId - 1].end) revert BadEpoch();

        uint256[] memory pub = new uint256[](4 + WORDS);
        pub[0] = enrollRoot;
        pub[1] = 0; // base: this deployment serves a single cohort starting at slot 0
        pub[2] = start;
        pub[3] = end;
        for (uint256 w; w < WORDS; ++w) {
            pub[4 + w] = words[w];
        }
        if (!_verify(EPOCH_VERIFIER, _EPOCH_SELECTOR, p, pub)) revert InvalidProof();

        _epochs.push(Epoch({start: start, end: end, at: uint64(block.timestamp)}));
        for (uint256 w; w < WORDS; ++w) {
            _attendance[epochId][w] = words[w];
        }
        emit EpochRecorded(epochId, start, end, WORDS);
    }

    // ------------------------------------------------------------------ queries

    /// @notice The binding a principal enrolled and the start of the most recent epoch, within
    ///         `lookback` epochs, in which they were recorded present.
    /// @return binding The principal's enrolled binding, or 0 if they never enrolled.
    /// @return since   Start of that epoch, or 0 if none of the scanned epochs recorded them.
    ///
    /// `since` is the epoch's lower bound rather than the credential's own timestamp: the epoch
    /// commits to the range, not to each principal's exact scan time, so crediting the lower bound
    /// is the conservative choice and never overstates how recently someone was seen.
    function presenceOf(address principal, uint256 lookback) external view override returns (uint256 binding, uint64 since) {
        if (lookback > MAX_LOOKBACK) revert LookbackTooLong();
        uint256 slotPlusOne = _slotOfPlusOne[principal];
        if (slotPlusOne == 0) return (0, 0);
        uint256 slot = slotPlusOne - 1;
        binding = bindingAt[slot];

        uint256 n = _epochs.length;
        uint256 word = slot / BITS_PER_WORD;
        uint256 bit = 1 << (slot % BITS_PER_WORD);
        uint256 stop = n > lookback ? n - lookback : 0;
        for (uint256 e = n; e > stop; --e) {
            if (_attendance[e - 1][word] & bit != 0) return (binding, _epochs[e - 1].start);
        }
        return (binding, 0);
    }

    function slotOf(address principal) external view override returns (bool enrolled, uint256 slot) {
        uint256 s = _slotOfPlusOne[principal];
        return (s != 0, s == 0 ? 0 : s - 1);
    }

    function epochCount() external view returns (uint256) {
        return _epochs.length;
    }

    function epochAt(uint256 epochId) external view returns (Epoch memory) {
        return _epochs[epochId];
    }

    function attendanceAt(uint256 epochId, uint256 word) external view returns (uint256) {
        return _attendance[epochId][word];
    }

    function isPresent(uint256 epochId, uint256 slot) external view returns (bool) {
        return _attendance[epochId][slot / BITS_PER_WORD] & (1 << (slot % BITS_PER_WORD)) != 0;
    }

    // ------------------------------------------------------------------ verifier plumbing

    /// @dev snarkjs emits one verifier per public-signal count, so the function selector depends on
    ///      the cohort width. Building the call by hand keeps a single registry implementation
    ///      usable with any of them.
    function _verify(address verifier, bytes4 selector, Groth16Proof calldata p, uint256[] memory pub)
        private
        view
        returns (bool)
    {
        bytes memory payload = abi.encodePacked(
            selector, p.a[0], p.a[1], p.b[0][0], p.b[0][1], p.b[1][0], p.b[1][1], p.c[0], p.c[1], pub
        );
        (bool ok, bytes memory ret) = verifier.staticcall(payload);
        return ok && ret.length == 32 && abi.decode(ret, (bool));
    }

    function _verifySelector(uint256 n) private pure returns (bytes4) {
        return bytes4(
            keccak256(
                abi.encodePacked(
                    "verifyProof(uint256[2],uint256[2][2],uint256[2],uint256[", _toString(n), "])"
                )
            )
        );
    }

    function _toString(uint256 v) private pure returns (string memory) {
        if (v == 0) return "0";
        uint256 digits;
        for (uint256 t = v; t != 0; t /= 10) ++digits;
        bytes memory b = new bytes(digits);
        for (uint256 i = digits; i != 0; --i) {
            b[i - 1] = bytes1(uint8(48 + v % 10));
            v /= 10;
        }
        return string(b);
    }
}
