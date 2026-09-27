// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EnvKey} from "./EnvKey.sol";
import {BequestVault} from "../src/BequestVault.sol";
import {BequestFactory} from "../src/BequestFactory.sol";
import {IGroth16Verifier} from "../src/interfaces/IGroth16Verifier.sol";
import {LivenessVerifier} from "../src/verifiers/LivenessVerifier.sol";
import {AgeVerifier} from "../src/verifiers/AgeVerifier.sol";
import {LivenessRegistry} from "../src/LivenessRegistry.sol";
import {ILivenessRegistry} from "../src/interfaces/ILivenessRegistry.sol";
import {TestUSD, HeirloomNFT, FamilyCollectibles} from "./DemoTokens.sol";

/// @notice Deploys the verifiers, the vault implementation, the factory and three demo tokens.
///         forge script script/Deploy.s.sol --rpc-url sepolia --broadcast --slow
///         The signing key is read from PRIVATE_KEY in .env (never passed on the command line);
///         without it, the usual --account / --private-key / --unlocked flags apply.
///         Env: MIN_PERIOD (seconds, default 60 for testnets), AUTH_WINDOW (default 1 day).
contract Deploy is EnvKey {
    struct Deployed {
        address liveness;
        address age;
        address registry;
        address impl;
        address factory;
        address t20;
        address t721;
        address t1155;
    }

    function run() external {
        uint256 pk = _envKey();
        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast();
        Deployed memory d = _deploy();
        vm.stopBroadcast();
        _write(d);
    }

    function _deploy() internal returns (Deployed memory d) {
        d.liveness = address(new LivenessVerifier());
        d.age = address(new AgeVerifier());
        d.registry = _deployRegistry();
        d.impl = address(
            new BequestVault(
                IGroth16Verifier(d.liveness),
                IGroth16Verifier(d.age),
                uint32(vm.envOr("MIN_PERIOD", uint256(60))),
                uint32(vm.envOr("AUTH_WINDOW", uint256(1 days))),
                ILivenessRegistry(d.registry),
                d.registry == address(0) ? 0 : uint32(vm.envOr("AGG_LOOKBACK", uint256(20)))
            )
        );
        d.factory = address(new BequestFactory(d.impl));
        d.t20 = address(new TestUSD());
        d.t721 = address(new HeirloomNFT());
        d.t1155 = address(new FamilyCollectibles());
    }

    /// @dev Aggregated liveness is deployed only when the cohort parameters are supplied; without
    ///      them the base system is deployed exactly as before.
    ///        AGG_EMPTY_ROOT  root of the empty depth-16 Poseidon enrollment tree
    ///        AGG_VERIFIER    built EpochAttestation verifier, e.g. AggVerifier_N8_m40_w1
    ///        AGG_WORDS       presence words per epoch; AGG_CAPACITY enrollment slots
    ///        AGG_MIN_EPOCH   shortest accepted epoch in seconds (default 5 min, for testnet timers)
    ///        AGG_LOOKBACK    epochs a vault scans (default 20); vault timers must satisfy
    ///                        lifeProof + grace + 15 min < AGG_LOOKBACK * AGG_MIN_EPOCH
    ///      The deploying account becomes the registry's aggregator.
    function _deployRegistry() internal returns (address) {
        uint256 emptyRoot = vm.envOr("AGG_EMPTY_ROOT", uint256(0));
        if (emptyRoot == 0) return address(0);
        string memory name = vm.envOr("AGG_VERIFIER", string("AggVerifier_N8_m40_w1"));
        return address(
            new LivenessRegistry(
                deployCode("src/verifiers/EnrollVerifier.sol:EnrollVerifier"),
                deployCode(string.concat("src/verifiers/", name, ".sol:", name)),
                vm.envOr("AGG_WORDS", uint256(1)),
                vm.envOr("AGG_CAPACITY", uint256(8)),
                64,
                emptyRoot,
                address(0), // the deployer
                uint64(vm.envOr("AGG_MIN_EPOCH", uint256(5 minutes)))
            )
        );
    }

    function _write(Deployed memory d) internal {
        string memory o = "deployment";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeUint(o, "minPeriod", vm.envOr("MIN_PERIOD", uint256(60)));
        vm.serializeUint(o, "authWindow", vm.envOr("AUTH_WINDOW", uint256(1 days)));
        vm.serializeAddress(o, "livenessVerifier", d.liveness);
        vm.serializeAddress(o, "ageVerifier", d.age);
        vm.serializeAddress(o, "livenessRegistry", d.registry);
        vm.serializeUint(o, "aggWords", vm.envOr("AGG_WORDS", uint256(1)));
        vm.serializeUint(o, "aggCapacity", vm.envOr("AGG_CAPACITY", uint256(8)));
        vm.serializeUint(o, "aggMinEpoch", vm.envOr("AGG_MIN_EPOCH", uint256(5 minutes)));
        vm.serializeUint(o, "aggLookback", vm.envOr("AGG_LOOKBACK", uint256(20)));
        vm.serializeAddress(o, "vaultImplementation", d.impl);
        vm.serializeAddress(o, "factory", d.factory);
        vm.serializeAddress(o, "demoERC20", d.t20);
        vm.serializeAddress(o, "demoERC721", d.t721);
        string memory json = vm.serializeAddress(o, "demoERC1155", d.t1155);
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.createDir("deployments", true);
        vm.writeJson(json, path);
        console.log("factory: ", d.factory);
        console.log("registry:", d.registry);
        console.log("written: ", path);
    }
}
