// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EnvKey} from "./EnvKey.sol";
import {BequestVault} from "../src/BequestVault.sol";
import {BequestFactory} from "../src/BequestFactory.sol";
import {TestUSD, HeirloomNFT, FamilyCollectibles} from "./DemoTokens.sol";

/// @notice End-to-end demo on a live network, one step per invocation:
///   forge script script/Demo.s.sol --sig "create()"    --rpc-url sepolia --account deployer --broadcast
///   ... --sig "heartbeat()" | "proveLife()" | "withdraw()" | "claimAll()" | "sweep()"
///   forge script script/Demo.s.sol --sig "status()" --rpc-url sepolia        (read-only)
/// Inputs are produced by `node js/demo.mjs ...` in demo/.
contract Demo is EnvKey {
    // Short timers so the whole lifecycle fits in about an hour of wall-clock time.
    uint32 internal constant HEARTBEAT = 10 minutes;
    uint32 internal constant LIFE_PROOF = 60 minutes;
    uint32 internal constant GRACE = 5 minutes;
    uint32 internal constant CLAIM_WINDOW = 30 minutes;

    function _deployment(string memory key) internal view returns (address) {
        string memory json = vm.readFile(string.concat("deployments/", vm.toString(block.chainid), ".json"));
        return vm.parseJsonAddress(json, string.concat(".", key));
    }

    /// Signs with PRIVATE_KEY from .env when present, otherwise with the CLI-selected sender.
    function _start() internal returns (address sender) {
        uint256 pk = _envKey();
        if (pk != 0) {
            vm.startBroadcast(pk);
            return vm.addr(pk);
        }
        vm.startBroadcast();
        return msg.sender;
    }

    function _vault() internal view returns (BequestVault) {
        return BequestVault(payable(vm.parseJsonAddress(vm.readFile("demo/state.json"), ".vault")));
    }

    function _u2(string memory json, string memory path) internal pure returns (uint256[2] memory r) {
        uint256[] memory a = vm.parseJsonUintArray(json, path);
        r[0] = a[0];
        r[1] = a[1];
    }

    function _proof(string memory json, string memory k) internal pure returns (BequestVault.Proof memory p) {
        p.a = _u2(json, string.concat(k, ".a"));
        p.b[0] = _u2(json, string.concat(k, ".b[0]"));
        p.b[1] = _u2(json, string.concat(k, ".b[1]"));
        p.c = _u2(json, string.concat(k, ".c"));
    }

    function _bequest(string memory json, uint256 i)
        internal
        pure
        returns (BequestVault.Bequest memory b, bytes32[] memory proof)
    {
        string memory k = string.concat(".leaves[", vm.toString(i), "]");
        b.index = vm.parseJsonUint(json, string.concat(k, ".index"));
        b.heir = vm.parseJsonAddress(json, string.concat(k, ".heir"));
        b.kind = uint8(vm.parseJsonUint(json, string.concat(k, ".kind")));
        b.token = vm.parseJsonAddress(json, string.concat(k, ".token"));
        b.id = vm.parseJsonUint(json, string.concat(k, ".id"));
        b.shareBps = uint16(vm.parseJsonUint(json, string.concat(k, ".shareBps")));
        b.notBefore = uint40(vm.parseJsonUint(json, string.concat(k, ".notBefore")));
        b.minAge = uint8(vm.parseJsonUint(json, string.concat(k, ".minAge")));
        b.ageCommitment = vm.parseJsonUint(json, string.concat(k, ".ageCommitment"));
        proof = vm.parseJsonBytes32Array(json, string.concat(k, ".proof"));
    }

    // ------------------------------------------------------------------ steps

    function create() external {
        string memory will = vm.readFile("demo/will.json");
        BequestVault.Config memory cfg = BequestVault.Config({
            heartbeatInterval: HEARTBEAT,
            lifeProofInterval: LIFE_PROOF,
            gracePeriod: GRACE,
            claimWindow: CLAIM_WINDOW,
            allocationRoot: vm.parseJsonBytes32(will, ".root"),
            residuary: vm.parseJsonAddress(will, ".residuary"),
            livenessBinding: vm.parseJsonUint(vm.readFile("demo/owner.json"), ".binding")
        });
        BequestFactory factory = BequestFactory(_deployment("factory"));
        bytes32 salt = cfg.allocationRoot; // one vault per will

        _start();
        address vault = factory.createVault(cfg, salt);
        (bool ok,) = vault.call{value: 0.002 ether}("");
        require(ok, "ETH deposit failed");
        TestUSD(_deployment("demoERC20")).mint(vault, 1_000_000e6); // 1,000,000 tUSD
        HeirloomNFT(_deployment("demoERC721")).mint(vault, vm.parseJsonUint(will, ".nftId"));
        FamilyCollectibles(_deployment("demoERC1155")).mint(vault, 7, 100);
        vm.stopBroadcast();

        vm.writeJson(vm.serializeAddress("state", "vault", vault), "demo/state.json");
        console.log("vault:", vault);
        _printStatus(BequestVault(payable(vault)));
    }

    function heartbeat() external {
        BequestVault v = _vault();
        _start();
        v.heartbeat();
        vm.stopBroadcast();
        _printStatus(v);
    }

    function proveLife() external {
        BequestVault v = _vault();
        string memory json = vm.readFile("demo/life-proof.json");
        BequestVault.Proof memory p = _proof(json, ".calldata");
        uint256 binding = vm.parseJsonUint(json, ".binding");
        uint256 ts = vm.parseJsonUint(json, ".livenessTimestamp");
        _start();
        v.proveLife(p, binding, ts);
        vm.stopBroadcast();
        _printStatus(v);
    }

    /// Registers the owner's real Billions DID as a second issuer binding (owner action).
    function addRealBinding() external {
        BequestVault v = _vault();
        uint256 real = vm.parseJsonUint(vm.readFile("demo/owner.json"), ".realBinding");
        _start();
        v.setBinding(real, true);
        vm.stopBroadcast();
        console.log("registered second binding (Billions issuer, owner DID)");
    }

    /// Owner withdrawal; needs a proof of life from the last AUTH_WINDOW.
    function withdraw() external {
        BequestVault v = _vault();
        address me = _start();
        v.withdraw(0, address(0), 0, 0.0005 ether, me);
        vm.stopBroadcast();
        console.log("withdrew 0.0005 ETH to", me);
    }

    /// Submits every bequest that is claimable now (anyone may relay; funds go to the heirs).
    function claimAll() external {
        BequestVault v = _vault();
        if (!v.settled() && block.timestamp <= v.claimableAt()) {
            console.log("not claimable yet; seconds to wait:", v.claimableAt() + 1 - block.timestamp);
            return;
        }
        string memory will = vm.readFile("demo/will.json");
        string memory ages = vm.exists("demo/age-proofs.json") ? vm.readFile("demo/age-proofs.json") : "{}";
        uint256 n = vm.parseJsonUint(will, ".count");
        _start();
        for (uint256 i; i < n; i++) {
            (BequestVault.Bequest memory b, bytes32[] memory proof) = _bequest(will, i);
            if (v.isClaimed(b.index)) continue;
            if (block.timestamp < b.notBefore) {
                console.log("bequest", i, "time-locked until", b.notBefore);
                continue;
            }
            if (b.minAge == 0) {
                v.claim(b, proof);
                console.log("claimed bequest", i);
                continue;
            }
            string memory k = string.concat(".", vm.toString(i));
            if (!vm.keyExistsJson(ages, k)) {
                console.log("bequest", i, "age-restricted and no proof (heir too young?)");
                continue;
            }
            uint256 cutoff = vm.parseJsonUint(ages, string.concat(k, ".cutoff"));
            v.claimWithAgeProof(b, proof, _proof(ages, k), cutoff);
            console.log("claimed age-restricted bequest", i);
        }
        vm.stopBroadcast();
    }

    function sweep() external {
        BequestVault v = _vault();
        string memory will = vm.readFile("demo/will.json");
        _start();
        v.sweep(0, address(0), 0);
        v.sweep(1, _deployment("demoERC20"), 0);
        vm.stopBroadcast();
        console.log("swept residue to", vm.parseJsonAddress(will, ".residuary"));
    }

    function status() external view {
        _printStatus(_vault());
    }

    function _printStatus(BequestVault v) internal view {
        string[4] memory names = ["Alive", "Grace", "Claimable", "Settled"];
        console.log("status:        ", names[uint8(v.status())]);
        console.log("now:           ", block.timestamp);
        console.log("deadline:      ", v.deadline());
        console.log("claimable at:  ", v.claimableAt());
        console.log("last heartbeat:", v.lastHeartbeat());
        console.log("last life proof:", v.lastLifeProof(), v.lifeProven() ? "(zk)" : "(creation)");
    }
}
