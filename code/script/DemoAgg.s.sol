// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EnvKey} from "./EnvKey.sol";
import {BequestVault} from "../src/BequestVault.sol";
import {LivenessRegistry} from "../src/LivenessRegistry.sol";
import {Groth16Proof} from "../src/interfaces/ILivenessRegistry.sol";

/// @notice Aggregated liveness on a live network, one step per invocation. Inputs come from
///         `node js/demo.mjs agg`, which writes demo/agg.json.
///
///   forge script script/DemoAgg.s.sol --sig "enroll()" --rpc-url sepolia --broadcast
///   forge script script/DemoAgg.s.sol --sig "epoch()"  --rpc-url sepolia --broadcast
///   forge script script/DemoAgg.s.sol --sig "status()" --rpc-url sepolia          (read-only)
///
/// The point of the demo is what `status()` shows between the two broadcasts: the vault's deadline
/// moves forward because of a transaction that the vault's owner did not send, and that would have
/// covered every other member of the cohort at the same cost.
contract DemoAgg is EnvKey {
    function _deployment(string memory key) internal view returns (address) {
        string memory json = vm.readFile(string.concat("deployments/", vm.toString(block.chainid), ".json"));
        return vm.parseJsonAddress(json, string.concat(".", key));
    }

    function _registry() internal view returns (LivenessRegistry) {
        address r = _deployment("livenessRegistry");
        require(r != address(0), "no registry in this deployment: set AGG_EMPTY_ROOT before Deploy.s.sol");
        return LivenessRegistry(r);
    }

    function _vault() internal view returns (BequestVault) {
        return BequestVault(payable(vm.parseJsonAddress(vm.readFile("demo/state.json"), ".vault")));
    }

    function _start() internal returns (address sender) {
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

    function _proof(string memory json, string memory k) internal pure returns (Groth16Proof memory p) {
        p.a = _u2(json, string.concat(k, ".calldata.a"));
        p.b[0] = _u2(json, string.concat(k, ".calldata.b[0]"));
        p.b[1] = _u2(json, string.concat(k, ".calldata.b[1]"));
        p.c = _u2(json, string.concat(k, ".calldata.c"));
    }

    /// Claim enrollment slot 0 for the demo vault's binding.
    function enroll() external {
        string memory json = vm.readFile("demo/agg.json");
        BequestVault v = _vault();
        LivenessRegistry r = _registry();
        require(r.enrollRoot() == vm.parseJsonUint(json, ".emptyRoot"), "registry already has enrollments");

        _start();
        uint256 slot = v.enrollInRegistry(
            _proof(json, ".enroll"),
            vm.parseJsonUint(json, ".enroll.newRoot"),
            vm.parseJsonUint(json, ".binding")
        );
        vm.stopBroadcast();
        console.log("enrolled at slot", slot);
        console.log("enrollment root now", r.enrollRoot());
    }

    /// Submit one epoch for the whole cohort. Only the registry's aggregator (the deployer) may
    /// send this, and the epoch must last at least the registry's minimum length.
    function epoch() external {
        string memory json = vm.readFile("demo/agg.json");
        LivenessRegistry r = _registry();
        uint256[] memory words = vm.parseJsonUintArray(json, ".epoch.words");

        _start();
        uint256 id = r.submitEpoch(
            _proof(json, ".epoch"),
            uint64(vm.parseJsonUint(json, ".epoch.start")),
            uint64(vm.parseJsonUint(json, ".epoch.end")),
            words
        );
        vm.stopBroadcast();
        console.log("epoch", id, "recorded; cohort slots covered:", r.WORDS() * r.BITS_PER_WORD());
    }

    function status() external view {
        BequestVault v = _vault();
        LivenessRegistry r = _registry();
        (bool enrolled, uint256 slot) = r.slotOf(address(v));
        (uint256 binding, uint64 since) = r.presenceOf(address(v), v.REGISTRY_LOOKBACK());
        (bool proven, uint40 at) = v.presence();

        console.log("vault            ", address(v));
        console.log("registry         ", address(r));
        console.log("enrolled         ", enrolled);
        console.log("slot             ", slot);
        console.log("epochs recorded  ", r.epochCount());
        console.log("registry binding ", binding);
        console.log("present since    ", uint256(since));
        console.log("-- local lastLifeProof (this vault's own transactions) --");
        console.log("local tL         ", uint256(v.lastLifeProof()));
        console.log("-- from the registry, with no transaction by this vault --");
        console.log("registry tL      ", uint256(v.registryLifeProof()));
        console.log("-- the two combined, which is what the lifecycle uses --");
        console.log("effective tL     ", uint256(at));
        console.log("life proven      ", proven);
        console.log("block timestamp  ", block.timestamp);
        console.log("deadline         ", v.deadline());
        console.log("claimable at     ", v.claimableAt());
    }
}
