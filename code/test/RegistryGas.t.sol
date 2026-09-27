// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {RegistryBase} from "./Registry.t.sol";
import {BequestVault} from "../src/BequestVault.sol";
import {LivenessRegistry} from "../src/LivenessRegistry.sol";
import {Groth16Proof} from "../src/interfaces/ILivenessRegistry.sol";

/// @notice What an epoch of aggregated liveness costs on-chain.
///         Run with `forge test --match-contract RegistryGas --isolate -vv`; with
///         WRITE_REPORTS=true the results land in reports/gas-aggregation.json.
///
/// Two families are measured. The `agg_N*_m40_w1` cohorts are complete end-to-end runs: n real
/// principals, n real credentials, one proof, one transaction. The `agg_N1_m16_w*` cohorts vary
/// only the presence-word count, which is what actually drives on-chain cost at population scale
/// (each word carries 248 principals and costs one public input plus one storage word), so they
/// give the cost of an epoch covering w * 248 principals without having to prove one.
contract RegistryGas is RegistryBase {
    string internal out = "aggregation";

    function test_EpochGas() public {
        string memory all = vm.readFile("test/fixtures/registry.json");
        string[] memory names = vm.parseJsonKeys(all, ".cohorts");

        string memory rows = "rows";
        string memory last;
        for (uint256 k; k < names.length; ++k) {
            last = vm.serializeString(rows, names[k], _measure(names[k]));
        }
        if (vm.envOr("WRITE_REPORTS", false)) {
            string memory doc = "doc";
            vm.serializeString(doc, "generatedBy", "forge test --match-contract RegistryGas --isolate");
            string memory json = vm.serializeString(doc, "cohorts", last);
            vm.writeJson(json, "reports/gas-aggregation.json");
        }
    }

    struct Result {
        uint256 enrollGas;
        uint256 epochGasCold;
        uint256 epochGasWarm;
        uint256 syncGas;
    }

    function _measure(string memory name) internal returns (string memory) {
        _setUpCohort(name);
        Result memory r = _run();
        return _serialize(name, r);
    }

    function _run() internal returns (Result memory r) {
        (BequestVault[] memory vs, address[] memory os) = _vaults();

        // --- enrollment: once per principal, ever
        for (uint256 i; i < n; ++i) {
            (Groth16Proof memory p, uint256 newRoot, uint256 binding) = _enrollment(i);
            vm.prank(os[i]);
            vs[i].enrollInRegistry(p, newRoot, binding);
            if (i == 0) r.enrollGas = vm.lastCallGas().gasTotalUsed;
        }

        r.epochGasCold = _submitAndMeasure("epoch");
        // A second epoch: the storage words are already non-zero, which is the steady state.
        r.epochGasWarm = _submitAndMeasure("partialEpoch");

        // --- what a vault pays to cache presence locally
        vs[0].syncFromRegistry();
        r.syncGas = vm.lastCallGas().gasTotalUsed;
    }

    function _submitAndMeasure(string memory which) internal returns (uint256) {
        (Groth16Proof memory p, uint64 start, uint64 end, uint256[] memory w) = _epoch(which);
        vm.warp(uint256(end) + 60);
        registry.submitEpoch(p, start, end, w);
        return vm.lastCallGas().gasTotalUsed;
    }

    function _serialize(string memory name, Result memory r) internal returns (string memory row) {
        uint256 capacity = uint256(words) * 248;
        string memory o = string.concat("cohort:", name);
        vm.serializeUint(o, "cohortSize", n);
        vm.serializeUint(o, "presenceWords", words);
        vm.serializeUint(o, "slotsCoveredByWords", capacity);
        vm.serializeUint(o, "publicSignals", 4 + words);
        vm.serializeUint(o, "enrollGas", r.enrollGas);
        vm.serializeUint(o, "epochGasCold", r.epochGasCold);
        vm.serializeUint(o, "epochGasWarm", r.epochGasWarm);
        vm.serializeUint(o, "syncFromRegistryGas", r.syncGas);
        vm.serializeUint(o, "epochGasPerProvenPrincipal", r.epochGasCold / n);
        row = vm.serializeUint(o, "epochGasPerCoveredSlot", r.epochGasWarm / capacity);

        emit log_named_uint(string.concat(name, " | epoch gas (cold)     "), r.epochGasCold);
        emit log_named_uint(string.concat(name, " | epoch gas (warm)     "), r.epochGasWarm);
        emit log_named_uint(string.concat(name, " | gas per covered slot "), r.epochGasWarm / capacity);
        emit log_named_uint(string.concat(name, " | enroll gas (once)    "), r.enrollGas);
    }

    /// What reading presence costs a vault, best and worst case. Best: the principal is in the latest
    /// epoch, one scan step. Worst: absent from every one of the LOOKBACK epochs, which a silent
    /// principal's vault pays when its heirs first claim. Empty epochs need no credential, so the
    /// verifier is mocked; the reads themselves are measured exactly.
    function test_PresenceReadCost() public {
        _setUpCohort("agg_N8_m40_w1");
        (BequestVault[] memory vs, address[] memory os) = _vaults();
        _enrollAll(vs, os);
        _submitAndMeasure("epoch"); // vault 0 present in the only epoch
        vs[0].registryLifeProof();
        uint256 best = vm.lastCallGas().gasTotalUsed;

        vm.mockCall(registry.EPOCH_VERIFIER(), bytes(""), abi.encode(true));
        uint256[] memory none = new uint256[](words);
        Groth16Proof memory p;
        uint64 last = registry.epochAt(0).end;
        for (uint256 k; k < LOOKBACK; ++k) {
            uint64 s = last + 1;
            uint64 e = s + MIN_EPOCH;
            vm.warp(e);
            registry.submitEpoch(p, s, e, none);
            last = e;
        }
        vs[0].registryLifeProof(); // scans all LOOKBACK epochs and finds nothing
        uint256 worst = vm.lastCallGas().gasTotalUsed;

        emit log_named_uint("presence read, principal in the latest epoch  ", best);
        emit log_named_uint("presence read, absent from all scanned epochs  ", worst);
        emit log_named_uint("epochs scanned in the worst case               ", LOOKBACK);
        if (vm.envOr("WRITE_REPORTS", false)) {
            string memory o = "presenceRead";
            vm.serializeString(o, "generatedBy", "forge test --match-contract RegistryGas --isolate");
            vm.serializeUint(o, "lookbackEpochs", LOOKBACK);
            vm.serializeUint(o, "bestCaseGas", best);
            vm.serializeUint(o, "worstCaseGas", worst);
            string memory json = vm.serializeUint(o, "gasPerScannedEpoch", (worst - best) / (LOOKBACK - 1));
            vm.writeJson(json, "reports/gas-presence-read.json");
        }
    }

    /// The baseline every per-principal scheme is stuck with: its own transaction. Measured, not
    /// assumed, so the comparison in the paper rests on the same harness as everything else.
    function test_PerPrincipalFloor() public {
        _setUpCohort("agg_N8_m40_w1");
        (BequestVault[] memory vs, address[] memory os) = _vaults();
        vm.prank(os[0]);
        vs[0].heartbeat();
        emit log_named_uint("heartbeat (key only, one transaction)", vm.lastCallGas().gasTotalUsed);
    }
}
