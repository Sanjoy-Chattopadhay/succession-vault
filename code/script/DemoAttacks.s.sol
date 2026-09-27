// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EnvKey} from "./EnvKey.sol";
import {BequestVault} from "../src/BequestVault.sol";
import {BequestFactory} from "../src/BequestFactory.sol";
import {LivenessRegistry} from "../src/LivenessRegistry.sol";
import {Groth16Proof} from "../src/interfaces/ILivenessRegistry.sol";

/// @notice Attacks against the live deployment, built from the owner's real Billions credential and
///         from the aggregation run. Inputs: demo/attacks/vectors.json (node js/attacks.mjs) and
///         demo/agg.json (the main Sepolia run).
///
///   forge script script/DemoAttacks.s.sol --sig "createVault()" --rpc-url sepolia --broadcast
///   forge script script/DemoAttacks.s.sol --sig "attacks()"     --rpc-url sepolia   (nothing sent)
///
/// `createVault` makes a fresh, unsettled vault whose only binding is the owner's real Billions
/// identity, so the attacks reach the proof verifier instead of stopping at `VaultSettled`.
/// `attacks` runs every attack as a call against the live state and checks the exact revert reason;
/// it fails if any attack succeeds or is stopped for an unexpected reason.
contract DemoAttacks is EnvKey {
    uint256 internal mismatches;

    function _deployment(string memory key) internal view returns (address) {
        string memory json = vm.readFile(string.concat("deployments/", vm.toString(block.chainid), ".json"));
        return vm.parseJsonAddress(json, string.concat(".", key));
    }

    function _u2(string memory json, string memory path) internal pure returns (uint256[2] memory r) {
        uint256[] memory a = vm.parseJsonUintArray(json, path);
        r[0] = a[0];
        r[1] = a[1];
    }

    function _vaultProof(string memory json, string memory k) internal pure returns (BequestVault.Proof memory p) {
        p.a = _u2(json, string.concat(k, ".a"));
        p.b[0] = _u2(json, string.concat(k, ".b[0]"));
        p.b[1] = _u2(json, string.concat(k, ".b[1]"));
        p.c = _u2(json, string.concat(k, ".c"));
    }

    function _regProof(string memory json, string memory k) internal pure returns (Groth16Proof memory p) {
        p.a = _u2(json, string.concat(k, ".a"));
        p.b[0] = _u2(json, string.concat(k, ".b[0]"));
        p.b[1] = _u2(json, string.concat(k, ".b[1]"));
        p.c = _u2(json, string.concat(k, ".c"));
    }

    // ------------------------------------------------------------------ one transaction

    function createVault() external {
        string memory v = vm.readFile("demo/attacks/vectors.json");
        uint256 realBinding = vm.parseJsonUint(v, ".realBinding");
        uint256 pk = _envKey();
        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast();
        address owner = pk != 0 ? vm.addr(pk) : msg.sender;
        BequestVault.Config memory cfg = BequestVault.Config({
            heartbeatInterval: 10 minutes,
            lifeProofInterval: 60 minutes,
            gracePeriod: 5 minutes,
            claimWindow: 30 minutes,
            allocationRoot: keccak256(abi.encode("attack-vault", block.timestamp)),
            residuary: owner,
            livenessBinding: realBinding
        });
        address vault = BequestFactory(_deployment("factory")).createVault(cfg, cfg.allocationRoot);
        vm.stopBroadcast();
        vm.writeJson(vm.serializeAddress("attack", "vault", vault), "demo/attacks/state.json");
        console.log("attack vault:", vault);
    }

    // ------------------------------------------------------------------ attacks (nothing is sent)

    function _expect(string memory name, bool succeeded, bytes memory reason, bytes4 want, string memory wantName)
        internal
    {
        if (succeeded) {
            mismatches++;
            console.log("ATTACK SUCCEEDED (bug):", name);
        } else if (reason.length >= 4 && bytes4(reason) == want) {
            console.log("rejected as expected:", name, "->", wantName);
        } else {
            mismatches++;
            console.log("rejected for an UNEXPECTED reason:", name);
            console.logBytes(reason);
        }
    }

    function attacks() external {
        _vaultAttacks();
        _registryAttacks();
        console.log("mismatches:", mismatches);
        require(mismatches == 0, "an attack was not rejected as expected");
    }

    function _vaultAttacks() internal {
        string memory v = vm.readFile("demo/attacks/vectors.json");
        BequestVault vault =
            BequestVault(payable(vm.parseJsonAddress(vm.readFile("demo/attacks/state.json"), ".vault")));

        BequestVault.Proof memory real = _vaultProof(v, ".realProof");
        uint256 realBinding = vm.parseJsonUint(v, ".realBinding");
        uint256 testBinding = vm.parseJsonUint(v, ".testBinding");
        uint256 realTau = vm.parseJsonUint(v, ".realTau");
        // Fresh enough to pass the freshness check, so a rejection can only come from the proof.
        uint256 nowTs = block.timestamp > vault.lastLifeProof() ? block.timestamp : uint256(vault.lastLifeProof()) + 1;
        console.log("attack vault", address(vault), "lastLifeProof", uint256(vault.lastLifeProof()));
        bool ok;
        bytes memory reason;

        // A1. The real credential, honestly proven, but older than the vault: replay protection.
        (ok, reason) = address(vault).call(abi.encodeCall(BequestVault.proveLife, (real, realBinding, realTau)));
        _expect("A1 real credential replayed (issued before the vault)", ok, reason,
            BequestVault.StaleOrFutureProof.selector, "StaleOrFutureProof");

        // A2. The same valid proof with its public timestamp re-dated to now: the SNARK must fail.
        (ok, reason) = address(vault).call(abi.encodeCall(BequestVault.proveLife, (real, realBinding, nowTs)));
        _expect("A2 real proof re-dated to the current time", ok, reason,
            BequestVault.InvalidProof.selector, "InvalidProof");

        // A3. The same proof dated in the future, beyond the tolerated clock skew.
        (ok, reason) = address(vault).call(abi.encodeCall(BequestVault.proveLife, (real, realBinding, nowTs + 1 days)));
        _expect("A3 real proof future-dated by one day", ok, reason,
            BequestVault.StaleOrFutureProof.selector, "StaleOrFutureProof");

        // A4. The real proof presented under a binding this vault never registered.
        (ok, reason) = address(vault).call(abi.encodeCall(BequestVault.proveLife, (real, testBinding, nowTs)));
        _expect("A4 real proof under a foreign binding", ok, reason,
            BequestVault.UnknownBinding.selector, "UnknownBinding");

        // A5. Someone other than the owner tries to withdraw.
        (ok, reason) = address(vault).call(abi.encodeCall(BequestVault.withdraw, (0, address(0), 0, 0, address(0xBEEF))));
        _expect("A5 withdrawal by a non-owner", ok, reason, BequestVault.NotOwner.selector, "NotOwner");
    }

    function _registryAttacks() internal {
        _epochReplay();
        _epochForgedBit();
        _enrollForgedRoot();
        _epochByStranger();
        _epochTooShort();
    }

    function _aggregator() internal view returns (address) {
        return LivenessRegistry(_deployment("livenessRegistry")).AGGREGATOR();
    }

    function _epoch() internal view returns (Groth16Proof memory ep, uint64 start, uint64 end, uint256[] memory words) {
        string memory agg = vm.readFile("demo/agg.json");
        ep = _regProof(agg, ".epoch.calldata");
        start = uint64(vm.parseJsonUint(agg, ".epoch.start"));
        end = uint64(vm.parseJsonUint(agg, ".epoch.end"));
        words = vm.parseJsonUintArray(agg, ".epoch.words");
    }

    // B1. Replaying the recorded epoch: one credential must not certify two epochs. Sent as the
    //     aggregator, so that it is the replay rule, not the sender check, that rejects it.
    function _epochReplay() internal {
        (Groth16Proof memory ep, uint64 start, uint64 end, uint256[] memory words) = _epoch();
        vm.prank(_aggregator());
        (bool ok, bytes memory reason) = _deployment("livenessRegistry").call(
            abi.encodeCall(LivenessRegistry.submitEpoch, (ep, start, end, words))
        );
        _expect("B1 epoch replayed", ok, reason, LivenessRegistry.BadEpoch.selector, "BadEpoch");
    }

    // B2. A new epoch that marks an extra principal present, reusing the proof. Sent as the
    //     aggregator and long enough to pass the length rule, so that only the proof can reject it.
    function _epochForgedBit() internal {
        (Groth16Proof memory ep,,, uint256[] memory words) = _epoch();
        words[0] |= 2; // slot 1 never proved anything
        LivenessRegistry registry = LivenessRegistry(_deployment("livenessRegistry"));
        uint64 last = registry.epochAt(registry.epochCount() - 1).end;
        require(block.timestamp >= last + 1 + registry.MIN_EPOCH_LENGTH(), "B2 needs one minimum epoch since the last");
        vm.prank(registry.AGGREGATOR());
        (bool ok, bytes memory reason) = address(registry).call(
            abi.encodeCall(LivenessRegistry.submitEpoch, (ep, last + 1, uint64(block.timestamp), words))
        );
        _expect("B2 epoch claiming an unproven principal", ok, reason, LivenessRegistry.InvalidProof.selector,
            "InvalidProof");
    }

    // B3. Enrolling with a forged tree root, from an address that has no slot yet.
    function _enrollForgedRoot() internal {
        string memory agg = vm.readFile("demo/agg.json");
        Groth16Proof memory en = _regProof(agg, ".enroll.calldata");
        uint256 forgedRoot = vm.parseJsonUint(agg, ".enroll.newRoot") ^ 1;
        (bool ok, bytes memory reason) = _deployment("livenessRegistry").call(
            abi.encodeCall(LivenessRegistry.enroll, (en, forgedRoot, vm.parseJsonUint(agg, ".binding")))
        );
        _expect("B3 enrollment with a forged root", ok, reason, LivenessRegistry.InvalidProof.selector,
            "InvalidProof");
    }

    // B4. Anyone but the aggregator submitting an epoch: the first step of flooding the lookback
    //     with empty epochs (which need no credential) to hide a principal's recorded presence.
    function _epochByStranger() internal {
        (Groth16Proof memory ep,,, uint256[] memory words) = _epoch();
        LivenessRegistry registry = LivenessRegistry(_deployment("livenessRegistry"));
        uint64 last = registry.epochAt(registry.epochCount() - 1).end;
        vm.prank(address(0xBEEF));
        (bool ok, bytes memory reason) = address(registry).call(
            abi.encodeCall(LivenessRegistry.submitEpoch, (ep, last + 1, uint64(block.timestamp), words))
        );
        _expect("B4 epoch from a non-aggregator", ok, reason, LivenessRegistry.NotAggregator.selector, "NotAggregator");
    }

    // B5. The aggregator itself submitting an epoch shorter than the minimum length, the other half
    //     of a flood: with short epochs, a burst of them could outrun the vault's lookback.
    function _epochTooShort() internal {
        (Groth16Proof memory ep,,, uint256[] memory words) = _epoch();
        LivenessRegistry registry = LivenessRegistry(_deployment("livenessRegistry"));
        uint64 last = registry.epochAt(registry.epochCount() - 1).end;
        // Read everything first: vm.prank applies to the next external call, which must be the attack.
        uint64 minLength = registry.MIN_EPOCH_LENGTH();
        address aggregator = registry.AGGREGATOR();
        vm.prank(aggregator);
        (bool ok, bytes memory reason) = address(registry).call(
            abi.encodeCall(LivenessRegistry.submitEpoch, (ep, last + 1, last + minLength, words)) // one second short
        );
        _expect("B5 epoch shorter than the minimum", ok, reason, LivenessRegistry.BadEpoch.selector, "BadEpoch");
    }
}
