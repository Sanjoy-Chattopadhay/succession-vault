// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EnvKey} from "./EnvKey.sol";
import {BequestVault} from "../src/BequestVault.sol";
import {BequestFactory} from "../src/BequestFactory.sol";

/// @notice j-of-m issuer threshold on a live vault (2-of-3 over test issuers A, B, C).
///   create()     vault bound to issuer A (threshold 1)                         [broadcast]
///   proveA()     the owner's first proof of life, issuer A alone               [broadcast]
///   configure()  register B and C and raise all three to threshold 2           [broadcast]
///   tryAlone()   issuer A alone, i.e. one compromised issuer: must be rejected [simulation]
///   multi()      proveLifeMulti with the proofs in demo/threshold/life-<TAG>.json [broadcast]
///   status()                                                                   [read]
/// Inputs come from `node js/demo.mjs threshold-setup | threshold-life`.
contract DemoThreshold is EnvKey {
    uint32 internal constant HEARTBEAT = 10 minutes;
    uint32 internal constant LIFE_PROOF = 60 minutes;
    uint32 internal constant GRACE = 5 minutes;
    uint32 internal constant CLAIM_WINDOW = 10 minutes;

    function _vault() internal view returns (BequestVault) {
        return BequestVault(payable(vm.parseJsonAddress(vm.readFile("demo/threshold/state.json"), ".vault")));
    }

    function _binding(string memory name) internal view returns (uint256) {
        return vm.parseJsonUint(vm.readFile("demo/threshold/owner.json"), string.concat(".bindings.", name));
    }

    function _start() internal returns (address) {
        uint256 pk = _envKey();
        if (pk != 0) {
            vm.startBroadcast(pk);
            return vm.addr(pk);
        }
        vm.startBroadcast();
        return msg.sender;
    }

    function _u2(string memory json, string memory path) internal pure returns (uint256[2] memory r) {
        uint256[] memory a = vm.parseJsonUintArray(json, path);
        r[0] = a[0];
        r[1] = a[1];
    }

    function _load(string memory tag)
        internal
        view
        returns (BequestVault.Proof[] memory ps, uint256[] memory bs, uint256[] memory ts)
    {
        string memory json = vm.readFile(string.concat("demo/threshold/life-", tag, ".json"));
        uint256 n = vm.parseJsonUint(json, ".count");
        ps = new BequestVault.Proof[](n);
        bs = new uint256[](n);
        ts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            string memory k = string.concat(".proofs[", vm.toString(i), "]");
            ps[i].a = _u2(json, string.concat(k, ".calldata.a"));
            ps[i].b[0] = _u2(json, string.concat(k, ".calldata.b[0]"));
            ps[i].b[1] = _u2(json, string.concat(k, ".calldata.b[1]"));
            ps[i].c = _u2(json, string.concat(k, ".calldata.c"));
            bs[i] = vm.parseJsonUint(json, string.concat(k, ".binding"));
            ts[i] = vm.parseJsonUint(json, string.concat(k, ".livenessTimestamp"));
        }
    }

    function create() external {
        string memory dep = vm.readFile(string.concat("deployments/", vm.toString(block.chainid), ".json"));
        address owner = _start();
        BequestVault.Config memory cfg = BequestVault.Config({
            heartbeatInterval: HEARTBEAT,
            lifeProofInterval: LIFE_PROOF,
            gracePeriod: GRACE,
            claimWindow: CLAIM_WINDOW,
            allocationRoot: keccak256(abi.encode("threshold-vault", block.timestamp)),
            residuary: owner,
            livenessBinding: _binding("A")
        });
        address vault = BequestFactory(vm.parseJsonAddress(dep, ".factory")).createVault(cfg, cfg.allocationRoot);
        vm.stopBroadcast();
        vm.writeJson(vm.serializeAddress("threshold", "vault", vault), "demo/threshold/state.json");
        console.log("threshold vault:", vault);
    }

    function proveA() external {
        (BequestVault.Proof[] memory ps, uint256[] memory bs, uint256[] memory ts) = _load("a0");
        BequestVault v = _vault();
        _start();
        v.proveLife(ps[0], bs[0], ts[0]);
        vm.stopBroadcast();
        _print(v);
    }

    function configure() external {
        BequestVault v = _vault();
        _start();
        v.setBindingThreshold(_binding("B"), 2);
        v.setBindingThreshold(_binding("C"), 2);
        v.setBindingThreshold(_binding("A"), 2);
        vm.stopBroadcast();
        console.log("THRESHOLD_A", uint256(v.bindingThreshold(_binding("A"))));
        console.log("THRESHOLD_B", uint256(v.bindingThreshold(_binding("B"))));
        console.log("THRESHOLD_C", uint256(v.bindingThreshold(_binding("C"))));
        _print(v);
    }

    /// One issuer alone (e.g. compromised, or colluding with a posthumous key holder), through both
    /// entry points. Simulated against live state; nothing is broadcast.
    function tryAlone() external {
        (BequestVault.Proof[] memory ps, uint256[] memory bs, uint256[] memory ts) = _load("a1");
        BequestVault v = _vault();
        try v.proveLife(ps[0], bs[0], ts[0]) {
            console.log("ALONE_SINGLE accepted");
        } catch (bytes memory err) {
            console.log("ALONE_SINGLE rejected", bytes4(err) == BequestVault.ThresholdNotMet.selector ? "ThresholdNotMet" : "other");
        }
        try v.proveLifeMulti(ps, bs, ts) {
            console.log("ALONE_MULTI accepted");
        } catch (bytes memory err) {
            console.log("ALONE_MULTI rejected", bytes4(err) == BequestVault.ThresholdNotMet.selector ? "ThresholdNotMet" : "other");
        }
        _print(v);
    }

    function multi() external {
        (BequestVault.Proof[] memory ps, uint256[] memory bs, uint256[] memory ts) = _load(vm.envString("TAG"));
        BequestVault v = _vault();
        _start();
        v.proveLifeMulti(ps, bs, ts);
        vm.stopBroadcast();
        _print(v);
    }

    function status() external view {
        _print(_vault());
    }

    function _print(BequestVault v) internal view {
        string[4] memory names = ["Alive", "Grace", "Claimable", "Settled"];
        console.log("THR_STATUS", names[uint8(v.status())]);
        console.log("THR_NOW", block.timestamp);
        console.log("THR_TL", uint256(v.lastLifeProof()));
        console.log("THR_DEADLINE", v.deadline());
    }
}
