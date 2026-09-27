// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {BequestVault} from "../src/BequestVault.sol";

/// @notice Bounded posthumous-key power, measured over several timer settings. The owner's last
///         genuine proof of life is at t*; afterwards a key holder heartbeats every Delta_h / 3
///         until twice the theoretical bound. For each setting we record the theoretical bound
///         t* + Delta_l + Delta_g, the first time the vault reads Claimable, the largest deadline
///         the key holder reached, and what a conventional (key-only) timer would show instead.
///         WRITE_REPORTS=true forge test --match-contract BoundSweep  ->  reports/bound-sweep.json
contract BoundSweep is BaseTest {
    struct Setting {
        uint32 hb;
        uint32 lp;
        uint32 grace;
        string name;
    }

    struct Result {
        uint256 beats;
        uint256 maxDeadline;
        uint256 firstClaimable;
        uint256 lastBeat;
    }

    function test_BoundSweep() public {
        Setting[5] memory s = [
            Setting(1 hours, 3 hours, 1 hours, "h1h_l3h_g1h"),
            Setting(1 days, 7 days, 1 days, "h1d_l7d_g1d"),
            Setting(7 days, 30 days, 7 days, "h7d_l30d_g7d"),
            Setting(30 days, 90 days, 30 days, "h30d_l90d_g30d"),
            Setting(30 days, 365 days, 90 days, "h30d_l365d_g90d")
        ];
        string memory all;
        for (uint256 k; k < s.length; ++k) {
            all = _record(s[k], _run(s[k], k));
        }
        if (vm.envOr("WRITE_REPORTS", false)) vm.writeJson(all, "reports/bound-sweep.json");
    }

    function _run(Setting memory s, uint256 k) internal returns (Result memory r) {
        (BequestVault.Proof memory p, uint256 bnd, uint256 tStar) = _lifeProof("p10");
        vm.warp(T0);
        address o = address(uint160(0xC0000 + k));
        BequestVault.Config memory cfg = _config(root, binding);
        cfg.heartbeatInterval = s.hb;
        cfg.lifeProofInterval = s.lp;
        cfg.gracePeriod = s.grace;
        vm.prank(o);
        BequestVault v = BequestVault(payable(factory.createVault(cfg, bytes32(0))));

        vm.warp(tStar + 1);
        v.proveLife(p, bnd, tStar); // the owner's last genuine liveness check
        uint256 step = s.hb / 3;
        for (uint256 t = tStar + step; t <= tStar + 2 * (s.lp + s.grace); t += step) {
            vm.warp(t);
            if (r.firstClaimable == 0 && v.status() == BequestVault.Status.Claimable) r.firstClaimable = t;
            vm.prank(o);
            v.heartbeat(); // accepted every time; only its effect is bounded
            r.beats++;
            r.lastBeat = t;
            if (v.deadline() > r.maxDeadline) r.maxDeadline = v.deadline();
        }
        // The exact boundary: not yet claimable at the bound, Claimable one second later.
        uint256 bound = tStar + s.lp + s.grace;
        vm.warp(bound);
        assertTrue(v.status() != BequestVault.Status.Claimable);
        vm.warp(bound + 1);
        assertEq(uint8(v.status()), uint8(BequestVault.Status.Claimable));
        assertLe(r.maxDeadline, tStar + s.lp);
        assertLe(r.firstClaimable, bound + step);
        r.maxDeadline -= tStar;
        r.firstClaimable -= tStar;
        r.lastBeat -= tStar;
    }

    function _record(Setting memory s, Result memory r) internal returns (string memory) {
        string memory row = s.name;
        vm.serializeUint(row, "heartbeatSec", s.hb);
        vm.serializeUint(row, "lifeProofSec", s.lp);
        vm.serializeUint(row, "graceSec", s.grace);
        vm.serializeUint(row, "theoreticalClaimableAfterSec", uint256(s.lp) + s.grace);
        vm.serializeBool(row, "notClaimableAtBound", true);
        vm.serializeBool(row, "claimableAtBoundPlus1s", true);
        vm.serializeUint(row, "maxDeadlineAfterTStarSec", r.maxDeadline);
        vm.serializeUint(row, "firstObservedClaimableAfterSec", r.firstClaimable);
        vm.serializeUint(row, "heartbeatsAccepted", r.beats);
        // A key-only timer would still be Alive: its deadline follows the last heartbeat.
        string memory rj = vm.serializeUint(row, "conventionalDeadlineAfterTStarSec", r.lastBeat + s.hb);
        return vm.serializeString("sweep", row, rj);
    }
}
