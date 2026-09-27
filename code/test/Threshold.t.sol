// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {BequestVault} from "../src/BequestVault.sol";

/// j-of-m issuer thresholds: with every binding at threshold j, a proof of life needs j distinct
/// issuers, so up to j - 1 compromised issuers cannot keep a dead owner's vault alive, and up to
/// m - j unavailable issuers do not stop a living owner from proving life.
/// Fixtures: test/fixtures/threshold.json (node js/gen-threshold-fixtures.mjs).
contract ThresholdTest is BaseTest {
    string internal thrJson;
    uint256 internal bA;
    uint256 internal bB;
    uint256 internal bC;

    function setUp() public override {
        super.setUp();
        thrJson = vm.readFile("test/fixtures/threshold.json");
        bA = vm.parseJsonUint(thrJson, ".bindingA");
        bB = vm.parseJsonUint(thrJson, ".bindingB");
        bC = vm.parseJsonUint(thrJson, ".bindingC");
        assertEq(bA, binding);
        assertEq(bB, otherBinding);

        // The owner proves life with issuer A alone (threshold 1, the default) and then, within the
        // authorization window, moves the vault to 2-of-3 over issuers A, B and C.
        (,, uint256 ts) = _lifeProof("p10");
        vm.warp(ts + 1 hours);
        _proveLife("p10");
        vm.startPrank(owner);
        vault.setBindingThreshold(bA, 2);
        vault.setBindingThreshold(bB, 2);
        vault.setBindingThreshold(bC, 2);
        vm.stopPrank();
        vm.warp(T0 + 200 days + 1 hours);
    }

    function _thr(string memory key) internal view returns (BequestVault.Proof memory p, uint256 bnd, uint256 ts) {
        string memory k = string.concat(".", key);
        p = _proof(thrJson, k);
        bnd = vm.parseJsonUint(thrJson, string.concat(k, ".binding"));
        ts = vm.parseJsonUint(thrJson, string.concat(k, ".ts"));
    }

    /// Proofs sorted by binding, as proveLifeMulti requires.
    function _multi(string memory k1, string memory k2)
        internal
        view
        returns (BequestVault.Proof[] memory ps, uint256[] memory bs, uint256[] memory ts)
    {
        ps = new BequestVault.Proof[](2);
        bs = new uint256[](2);
        ts = new uint256[](2);
        (ps[0], bs[0], ts[0]) = _thr(k1);
        (ps[1], bs[1], ts[1]) = _thr(k2);
        if (bs[0] > bs[1]) {
            (ps[0], ps[1]) = (ps[1], ps[0]);
            (bs[0], bs[1]) = (bs[1], bs[0]);
            (ts[0], ts[1]) = (ts[1], ts[0]);
        }
    }

    function test_Threshold_Configured() public view {
        assertEq(vault.bindingThreshold(bA), 2);
        assertEq(vault.bindingThreshold(bC), 2);
        assertTrue(vault.isBinding(bC));
        assertFalse(vault.isBinding(12345));
    }

    /// One compromised issuer alone cannot extend the deadline, through either entry point.
    function test_Threshold_OneIssuerAloneRejected() public {
        (BequestVault.Proof memory p, uint256 bnd, uint256 ts) = _thr("a200");
        vm.expectRevert(BequestVault.ThresholdNotMet.selector);
        vault.proveLife(p, bnd, ts);

        BequestVault.Proof[] memory ps = new BequestVault.Proof[](1);
        uint256[] memory bs = new uint256[](1);
        uint256[] memory tss = new uint256[](1);
        (ps[0], bs[0], tss[0]) = (p, bnd, ts);
        vm.expectRevert(BequestVault.ThresholdNotMet.selector);
        vault.proveLifeMulti(ps, bs, tss);
    }

    function test_Threshold_TwoOfThreeAccepted() public {
        (BequestVault.Proof[] memory ps, uint256[] memory bs, uint256[] memory ts) = _multi("a200", "b200");
        vm.prank(relayer);
        vault.proveLifeMulti(ps, bs, ts);
        assertEq(vault.lastLifeProof(), T0 + 200 days);
        assertEq(vault.deadline(), T0 + 200 days + I);
    }

    /// Issuer A is unavailable: B and C still meet the threshold.
    function test_Threshold_OneIssuerOutageTolerated() public {
        (BequestVault.Proof[] memory ps, uint256[] memory bs, uint256[] memory ts) = _multi("b200", "c200");
        vault.proveLifeMulti(ps, bs, ts);
        assertEq(vault.lastLifeProof(), T0 + 200 days);
    }

    /// The recorded liveness time is the earliest attested time.
    function test_Threshold_RecordsEarliestTime() public {
        vm.warp(T0 + 201 days + 1 hours);
        (BequestVault.Proof[] memory ps, uint256[] memory bs, uint256[] memory ts) = _multi("a200", "c201");
        vault.proveLifeMulti(ps, bs, ts);
        assertEq(vault.lastLifeProof(), T0 + 200 days);
    }

    /// The same issuer twice does not count as two issuers.
    function test_Threshold_DuplicateIssuerRejected() public {
        (BequestVault.Proof memory p, uint256 bnd, uint256 ts) = _thr("a200");
        BequestVault.Proof[] memory ps = new BequestVault.Proof[](2);
        uint256[] memory bs = new uint256[](2);
        uint256[] memory tss = new uint256[](2);
        (ps[0], bs[0], tss[0]) = (p, bnd, ts);
        (ps[1], bs[1], tss[1]) = (p, bnd, ts);
        vm.expectRevert(BequestVault.InvalidConfig.selector);
        vault.proveLifeMulti(ps, bs, tss);
    }

    /// Each proof is checked: one forged proof sinks the batch, and old ones are stale.
    function test_Threshold_EveryProofChecked() public {
        (BequestVault.Proof[] memory ps, uint256[] memory bs, uint256[] memory ts) = _multi("a200", "b200");
        ps[1].a[0] ^= 1;
        vm.expectRevert();
        vault.proveLifeMulti(ps, bs, ts);

        (ps, bs, ts) = _multi("a200", "b200");
        vault.proveLifeMulti(ps, bs, ts);
        vm.expectRevert(BequestVault.StaleOrFutureProof.selector);
        vault.proveLifeMulti(ps, bs, ts);
    }

    function test_Threshold_RemovingAnIssuerNeedsTheThreshold() public {
        (BequestVault.Proof[] memory ps, uint256[] memory bs, uint256[] memory ts) = _multi("a200", "c200");
        vm.warp(T0 + 200 days + 2 hours);
        // Owner actions now need a 2-of-3 proof; without one C cannot be removed...
        vm.prank(owner);
        vm.expectRevert(BequestVault.ProofOfLifeRequired.selector);
        vault.setBindingThreshold(bC, 0);
        // ...but with one it can, after which C's proofs no longer count.
        vault.proveLifeMulti(ps, bs, ts);
        vm.prank(owner);
        vault.setBindingThreshold(bC, 0);
        vm.warp(T0 + 201 days + 1 hours);
        (ps, bs, ts) = _multi("b200", "c201");
        vm.expectRevert(BequestVault.UnknownBinding.selector); // C is no longer registered
        vault.proveLifeMulti(ps, bs, ts);
    }

    /// A posthumous key holder with one compromised issuer: heartbeats and that issuer's proofs
    /// together still cannot postpone succession past the last genuine 2-of-3 proof + B + G.
    function test_Threshold_KeyHolderPlusOneIssuerStillBounded() public {
        (BequestVault.Proof[] memory ps, uint256[] memory bs, uint256[] memory ts) = _multi("a200", "b200");
        vault.proveLifeMulti(ps, bs, ts);
        uint256 bound = T0 + 200 days + B + G;
        (BequestVault.Proof memory p, uint256 bnd, uint256 t) = _thr("c201");
        for (uint256 now_ = block.timestamp; now_ <= bound; now_ += 29 days) {
            vm.warp(now_);
            vm.prank(owner);
            vault.heartbeat();
            if (now_ > t) {
                vm.expectRevert(BequestVault.ThresholdNotMet.selector);
                vault.proveLife(p, bnd, t);
            }
        }
        vm.warp(bound + 1);
        assertEq(uint8(vault.status()), uint8(BequestVault.Status.Claimable));
    }
}
