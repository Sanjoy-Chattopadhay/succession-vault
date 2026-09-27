// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BequestVault} from "../../src/BequestVault.sol";
import {BequestFactory} from "../../src/BequestFactory.sol";
import {LivenessRegistry} from "../../src/LivenessRegistry.sol";
import {IGroth16Verifier} from "../../src/interfaces/IGroth16Verifier.sol";
import {ILivenessRegistry, Groth16Proof} from "../../src/interfaces/ILivenessRegistry.sol";

/// @dev Halmos symbolic-VM cheatcodes (a16z/halmos-cheatcodes), declared inline.
interface SVM {
    function createUint(uint256 bitSize, string memory name) external pure returns (uint256);
    function createAddress(string memory name) external pure returns (address);
    function createCalldata(string memory contractName) external pure returns (bytes memory);
    function enableSymbolicStorage(address target) external;
}

/// @dev A verifier whose answer is an unconstrained symbolic boolean: the proofs below hold for
///      every verifier outcome, so they do not depend on Groth16 soundness. That part of the
///      argument (A2) stays a cryptographic reduction (Theorem 3(a)).
contract SymVerifier is IGroth16Verifier {
    bool public ok;

    function verifyProof(uint256[2] calldata, uint256[2][2] calldata, uint256[2] calldata, uint256[2] calldata)
        external
        view
        returns (bool)
    {
        return ok;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(ok);
    }
}

/// @notice Machine-checked properties of the vault's state machine (run with `halmos`, see
///         scripts/halmos.sh). Every check starts from an ARBITRARY vault state (symbolic storage),
///         an arbitrary block time, an arbitrary sender and an arbitrary call to any vault function
///         with arbitrary arguments; it therefore proves an inductive invariant, not a trace.
///         Reachability assumptions are stated with each check (e.g. timestamps not in the future).
///         The registry path is disabled here (REGISTRY = 0); its own rules are checked below.
contract VaultSymbolic is Test {
    SVM internal constant svm = SVM(address(uint160(uint256(keccak256("svm cheat code")))));
    uint256 internal constant SKEW = 15 minutes;
    uint256 internal constant AUTH = 1 days;

    SymVerifier internal verifier;
    BequestVault internal vault;

    function setUp() public {
        verifier = new SymVerifier();
        BequestVault impl = new BequestVault(
            IGroth16Verifier(address(verifier)), IGroth16Verifier(address(verifier)), 1 hours, uint32(AUTH),
            ILivenessRegistry(address(0)), 0
        );
        BequestFactory factory = new BequestFactory(address(impl));
        BequestVault.Config memory cfg = BequestVault.Config({
            heartbeatInterval: 1 days, lifeProofInterval: 7 days, gracePeriod: 1 days, claimWindow: 30 days,
            allocationRoot: bytes32(uint256(1)), residuary: address(0xbeef), livenessBinding: 1
        });
        vm.prank(address(0xa11ce));
        vault = BequestVault(payable(factory.createVault(cfg, bytes32(0))));
    }

    struct S {
        address owner;
        uint256 tH;
        uint256 tL;
        bool settled;
        bool proven;
        address residuary;
        bytes32 root;
        uint256 hb;
        uint256 lp;
        uint256 grace;
        uint256 window;
        uint256 threshold;
        bool claimed;
        uint256 paid;
        uint256 balance;
    }

    function _snap(uint256 x, uint256 idx, bytes32 pool) internal view returns (S memory s) {
        s.owner = vault.owner();
        s.tH = vault.lastHeartbeat();
        s.tL = vault.lastLifeProof();
        s.settled = vault.settled();
        s.proven = vault.lifeProven();
        s.residuary = vault.residuary();
        s.root = vault.allocationRoot();
        s.hb = vault.heartbeatInterval();
        s.lp = vault.lifeProofInterval();
        s.grace = vault.gracePeriod();
        s.window = vault.claimWindow();
        s.threshold = vault.bindingThreshold(x);
        s.claimed = vault.isClaimed(idx);
        s.paid = vault.paidBps(pool);
        s.balance = address(vault).balance;
    }

    /// Arbitrary state and time, restricted to what is reachable: the vault was initialized (a
    /// clone is created and initialized in one transaction), no stored time lies in the future,
    /// and block time is below 2^40 - 15 min (the year 36,812), so that 40-bit timestamps cannot wrap.
    /// Slots 0-2 (owner, t_h, t_l, flags; residuary and timers; will root) were written during
    /// setUp, so they are overwritten with fresh symbols; all mappings are symbolic storage.
    function _arbitraryState() internal returns (uint256 t) {
        svm.enableSymbolicStorage(address(vault));
        svm.enableSymbolicStorage(address(verifier));
        vm.store(address(vault), bytes32(uint256(0)), bytes32(svm.createUint(256, "slot0")));
        vm.store(address(vault), bytes32(uint256(1)), bytes32(svm.createUint(256, "slot1")));
        vm.store(address(vault), bytes32(uint256(2)), bytes32(svm.createUint(256, "slot2")));
        vm.deal(address(vault), svm.createUint(96, "balance"));
        t = svm.createUint(40, "now");
        vm.assume(t + SKEW < 2 ** 40);
        vm.warp(t);
        vm.assume(vault.owner() != address(0));
        vm.assume(vault.lastHeartbeat() <= t);
        vm.assume(vault.lastLifeProof() <= t + SKEW);
    }

    function _anyCall() internal returns (bytes4 sel, address sender, bool ok) {
        bytes memory data = svm.createCalldata("BequestVault");
        sender = svm.createAddress("sender");
        vm.assume(sender != address(vault));
        if (data.length >= 4) sel = bytes4(data);
        vm.prank(sender);
        (ok,) = address(vault).call(data);
    }

    // ------------------------------------------------------------------ P1, P2: key-only heartbeats

    /// P1/P2. A heartbeat changes nothing but t_h: not t_l, the will, the bindings, the residuary
    /// or the timers, and afterwards the deadline is still at most t_l + Delta_l. Hence no number
    /// of heartbeats by a key holder moves the deadline past the last accepted proof of life.
    function check_P1_heartbeatCannotExtendLiveness(uint256 x) public {
        _arbitraryState();
        S memory a = _snap(x, 0, 0);
        vm.prank(a.owner);
        vault.heartbeat();
        S memory b = _snap(x, 0, 0);
        assertEq(b.tL, a.tL);
        assertEq(b.proven, a.proven);
        assertEq(b.root, a.root);
        assertEq(b.residuary, a.residuary);
        assertEq(b.threshold, a.threshold);
        assertEq(b.lp, a.lp);
        assertEq(b.hb, a.hb);
        assertLe(vault.deadline(), b.tL + b.lp);
    }

    // ------------------------------------------------------------------ P3: liveness time

    /// P3. For ANY call: the stored liveness time t_l never decreases, never lies in the future, and
    /// changes only through proveLife / proveLifeMulti with the verifier accepting.
    function check_P3_livenessTimeOnlyByAcceptedProof() public {
        uint256 t = _arbitraryState();
        S memory a = _snap(0, 0, 0);
        (bytes4 sel,, bool ok) = _anyCall();
        vm.assume(ok);
        S memory b = _snap(0, 0, 0);
        assertGe(b.tL, a.tL);
        assertGe(b.tH, a.tH);
        if (b.tL != a.tL) {
            assertTrue(sel == BequestVault.proveLife.selector || sel == BequestVault.proveLifeMulti.selector);
            assertTrue(verifier.ok());
            assertLe(b.tL, t + SKEW);
        }
    }

    // ------------------------------------------------------------------ P4: settlement is final

    /// P4. Once settled, a vault stays settled, and no call can change its liveness times, will,
    /// bindings, residuary or timers: a proof of life after the first claim cannot revive it.
    function check_P4_settlementIsFinal(uint256 x) public {
        _arbitraryState();
        vm.assume(vault.settled());
        S memory a = _snap(x, 0, 0);
        (,, bool ok) = _anyCall();
        vm.assume(ok);
        S memory b = _snap(x, 0, 0);
        assertTrue(b.settled);
        assertEq(b.tL, a.tL);
        assertEq(b.tH, a.tH);
        assertEq(b.root, a.root);
        assertEq(b.residuary, a.residuary);
        assertEq(b.threshold, a.threshold);
        assertEq(b.lp, a.lp);
        assertEq(b.grace, a.grace);
    }

    // ------------------------------------------------------------------ P5: no premature succession

    /// P5. An unsettled vault can become settled only after D + Delta_g, and a sweep succeeds only
    /// after D + Delta_g + Delta_c (D computed in the pre-state).
    function check_P5_noSettlementBeforeGrace() public {
        uint256 t = _arbitraryState();
        vm.assume(!vault.settled());
        uint256 claimableAt = vault.claimableAt();
        uint256 window = vault.claimWindow();
        (bytes4 sel,, bool ok) = _anyCall();
        vm.assume(ok);
        if (vault.settled()) assertGt(t, claimableAt);
        if (sel == BequestVault.sweep.selector) assertGt(t, claimableAt + window);
    }

    // ------------------------------------------------------------------ P6: owner actions

    /// P6. Before settlement, any change to the will, bindings, residuary or timers, and any ETH
    /// leaving the vault, requires the owner's key AND a proof of life at most AUTH_WINDOW old.
    function check_P6_ownerActionsNeedKeyAndFreshProof(uint256 x) public {
        uint256 t = _arbitraryState();
        vm.assume(!vault.settled());
        S memory a = _snap(x, 0, 0);
        (, address sender, bool ok) = _anyCall();
        vm.assume(ok);
        S memory b = _snap(x, 0, 0);
        bool changed = b.root != a.root || b.residuary != a.residuary || b.threshold != a.threshold || b.lp != a.lp
            || b.hb != a.hb || b.grace != a.grace || b.window != a.window || (!b.settled && b.balance < a.balance);
        if (changed) {
            assertEq(sender, a.owner);
            assertTrue(a.proven);
            assertLe(t, a.tL + AUTH);
        }
    }

    // ------------------------------------------------------------------ P7, P8: allocation integrity

    /// P7. A claimed bequest stays claimed (no call clears a bit), and claiming it again reverts.
    function check_P7_claimedBitsNeverCleared(uint256 idx) public {
        _arbitraryState();
        vm.assume(vault.isClaimed(idx));
        (,, bool ok) = _anyCall();
        vm.assume(ok);
        assertTrue(vault.isClaimed(idx));
    }

    function check_P7_doubleClaimReverts(BequestVault.Bequest calldata bq, bytes32[] calldata proof) public {
        _arbitraryState();
        vm.assume(vault.isClaimed(bq.index));
        vm.prank(svm.createAddress("sender"));
        (bool ok,) = address(vault).call(abi.encodeCall(BequestVault.claim, (bq, proof)));
        assertFalse(ok);
    }

    /// P8. No fungible pool is ever paid beyond 100% (10^4 basis points).
    function check_P8_poolsNeverOverPaid(bytes32 pool) public {
        _arbitraryState();
        vm.assume(vault.paidBps(pool) <= 10_000);
        (,, bool ok) = _anyCall();
        vm.assume(ok);
        assertLe(vault.paidBps(pool), 10_000);
    }

    // ------------------------------------------------------------------ P9: issuer thresholds

    /// P9a. A single-issuer proof of life is accepted only under a binding whose threshold is 1.
    function check_P9_singleProofNeedsThresholdOne(BequestVault.Proof calldata p, uint256 bnd, uint256 ts) public {
        _arbitraryState();
        uint256 thr = vault.bindingThreshold(bnd);
        vault.proveLife(p, bnd, ts);
        assertEq(thr, 1);
    }

    /// P9b. A multi-issuer proof of life is accepted only with distinct registered bindings, each
    /// with threshold at most their number, all strictly newer than t_l; t_l becomes their minimum.
    function check_P9_multiProofMeetsThreshold(
        BequestVault.Proof[] calldata ps,
        uint256[] calldata bs,
        uint256[] calldata ts
    ) public {
        _arbitraryState();
        uint256 before = vault.lastLifeProof();
        uint256[] memory thr = new uint256[](bs.length);
        for (uint256 i; i < bs.length; ++i) {
            thr[i] = vault.bindingThreshold(bs[i]);
        }
        vault.proveLifeMulti(ps, bs, ts);
        uint256 earliest = type(uint256).max;
        for (uint256 i; i < bs.length; ++i) {
            assertTrue(thr[i] >= 1 && thr[i] <= bs.length);
            if (i > 0) assertGt(bs[i], bs[i - 1]);
            assertGt(ts[i], before);
            if (ts[i] < earliest) earliest = ts[i];
        }
        assertEq(vault.lastLifeProof(), earliest);
    }
}

/// @notice Registry rules that the vault's bounded-denial argument relies on (Lemma 1).
contract RegistrySymbolic is Test {
    SVM internal constant svm = SVM(address(uint160(uint256(keccak256("svm cheat code")))));
    address internal constant AGG = address(0xa66);
    uint64 internal constant L = 1 hours;

    SymVerifier internal verifier;
    LivenessRegistry internal registry;

    function setUp() public {
        verifier = new SymVerifier();
        registry = new LivenessRegistry(address(verifier), address(verifier), 1, 248, 64, 1, AGG, L);
    }

    /// R1. Only the designated aggregator can add an epoch; everyone else can at most enroll.
    /// R2. Every accepted epoch lasts at least L and starts after the previous one ended.
    function check_R_epochsOnlyByAggregatorAndWellFormed(uint64 start, uint64 end, uint256 w0) public {
        svm.enableSymbolicStorage(address(verifier));
        vm.warp(svm.createUint(40, "now"));
        // Two epochs from arbitrary senders: the first establishes a predecessor.
        address s1 = svm.createAddress("s1");
        uint256[] memory words = new uint256[](1);
        words[0] = w0;
        Groth16Proof memory p;
        vm.prank(s1);
        (bool ok1,) = address(registry).call(abi.encodeCall(LivenessRegistry.submitEpoch, (p, start, end, words)));
        if (ok1) {
            assertEq(s1, AGG);
            assertGe(end - start, L);
        }
        uint64 start2 = uint64(svm.createUint(64, "start2"));
        uint64 end2 = uint64(svm.createUint(64, "end2"));
        address s2 = svm.createAddress("s2");
        uint256 n = registry.epochCount();
        vm.prank(s2);
        (bool ok2,) = address(registry).call(abi.encodeCall(LivenessRegistry.submitEpoch, (p, start2, end2, words)));
        if (ok2) {
            assertEq(s2, AGG);
            assertGe(end2 - start2, L);
            if (n > 0) assertGt(start2, registry.epochAt(n - 1).end);
        }
    }
}
