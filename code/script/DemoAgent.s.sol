// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EnvKey} from "./EnvKey.sol";
import {BequestVault} from "../src/BequestVault.sol";
import {BequestFactory} from "../src/BequestFactory.sol";

/// @notice An always-on key holder -- e.g. an AI agent entrusted with the owner's key -- against a
///         live vault. The human proves life once; the agent then heartbeats relentlessly. The vault
///         must still become claimable at tL + lifeProofInterval + gracePeriod (Theorem 3).
///
///   forge script script/DemoAgent.s.sol --sig "create()"    --rpc-url sepolia --broadcast
///   forge script script/DemoAgent.s.sol --sig "proveLife()" --rpc-url sepolia --broadcast
///   forge script script/DemoAgent.s.sol --sig "beat()"      --rpc-url sepolia --broadcast
///   forge script script/DemoAgent.s.sol --sig "status()"    --rpc-url sepolia
contract DemoAgent is EnvKey {
    // Short timers so the whole experiment fits in about a quarter of an hour.
    uint32 internal constant HEARTBEAT = 3 minutes;
    uint32 internal constant LIFE_PROOF = 8 minutes;
    uint32 internal constant GRACE = 2 minutes;
    uint32 internal constant CLAIM_WINDOW = 5 minutes;

    function _vault() internal view returns (BequestVault) {
        return BequestVault(payable(vm.parseJsonAddress(vm.readFile("demo/agent/state.json"), ".vault")));
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

    function create() external {
        uint256 binding = vm.parseJsonUint(vm.readFile("demo/owner.json"), ".binding");
        string memory dep = vm.readFile(string.concat("deployments/", vm.toString(block.chainid), ".json"));
        address owner = _start();
        BequestVault.Config memory cfg = BequestVault.Config({
            heartbeatInterval: HEARTBEAT,
            lifeProofInterval: LIFE_PROOF,
            gracePeriod: GRACE,
            claimWindow: CLAIM_WINDOW,
            allocationRoot: keccak256(abi.encode("agent-vault", block.timestamp)),
            residuary: owner,
            livenessBinding: binding
        });
        address vault = BequestFactory(vm.parseJsonAddress(dep, ".factory")).createVault(cfg, cfg.allocationRoot);
        vm.stopBroadcast();
        vm.writeJson(vm.serializeAddress("agent", "vault", vault), "demo/agent/state.json");
        console.log("agent vault:", vault);
    }

    /// The human's last genuine liveness check (t*).
    function proveLife() external {
        BequestVault v = _vault();
        string memory json = vm.readFile("demo/agent/life-proof.json");
        BequestVault.Proof memory p;
        p.a = _u2(json, ".calldata.a");
        p.b[0] = _u2(json, ".calldata.b[0]");
        p.b[1] = _u2(json, ".calldata.b[1]");
        p.c = _u2(json, ".calldata.c");
        _start();
        v.proveLife(p, vm.parseJsonUint(json, ".binding"), vm.parseJsonUint(json, ".livenessTimestamp"));
        vm.stopBroadcast();
        _print(v);
    }

    /// One heartbeat by the agent, which holds the owner key.
    function beat() external {
        BequestVault v = _vault();
        _start();
        v.heartbeat();
        vm.stopBroadcast();
        _print(v);
    }

    function status() external view {
        _print(_vault());
    }

    function _print(BequestVault v) internal view {
        string[4] memory names = ["Alive", "Grace", "Claimable", "Settled"];
        console.log("AGENT_STATUS", names[uint8(v.status())]);
        console.log("AGENT_NOW", block.timestamp);
        console.log("AGENT_TH", uint256(v.lastHeartbeat()));
        console.log("AGENT_TL", uint256(v.lastLifeProof()));
        console.log("AGENT_DEADLINE", v.deadline());
        console.log("AGENT_CLAIMABLE_AT", v.claimableAt());
    }
}
