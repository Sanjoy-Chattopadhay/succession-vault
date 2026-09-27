// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LivenessVerifier} from "../src/verifiers/LivenessVerifier.sol";
import {AgeVerifier} from "../src/verifiers/AgeVerifier.sol";
import {LivenessPlonkVerifier} from "./proofsys/LivenessPlonkVerifier.sol";
import {AgePlonkVerifier} from "./proofsys/AgePlonkVerifier.sol";
import {AgeFflonkVerifier} from "./proofsys/AgeFflonkVerifier.sol";

/// @notice On-chain verification cost of Groth16, PLONK and FFLONK proofs for the same circuits.
///         Proofs come from `node js/bench-proof-systems.mjs` (test/fixtures/proofsys.json).
///         Run: WRITE_REPORTS=true forge test --match-contract ProofSystems --isolate -vv
///         Reported numbers are execution gas of the view call, as for the Groth16 verifier.
contract ProofSystems is Test {
    string internal json;
    string internal constant OUT = "proofsys";

    function setUp() public {
        json = vm.readFile("test/fixtures/proofsys.json");
    }

    function _pub(string memory key) internal view returns (uint256[2] memory p) {
        uint256[] memory a = vm.parseJsonUintArray(json, string.concat(".", key, ".pub"));
        p = [a[0], a[1]];
    }

    function _words(string memory key) internal view returns (uint256[24] memory w) {
        uint256[] memory a = vm.parseJsonUintArray(json, string.concat(".", key, ".proof[0]"));
        require(a.length == 24, "unexpected proof length");
        for (uint256 i; i < 24; i++) w[i] = a[i];
    }

    function _g16(string memory key)
        internal
        view
        returns (uint256[2] memory a, uint256[2][2] memory b, uint256[2] memory c)
    {
        string memory k = string.concat(".", key, ".proof");
        uint256[] memory x = vm.parseJsonUintArray(json, string.concat(k, "[0]"));
        a = [x[0], x[1]];
        x = vm.parseJsonUintArray(json, string.concat(k, "[1][0]"));
        b[0] = [x[0], x[1]];
        x = vm.parseJsonUintArray(json, string.concat(k, "[1][1]"));
        b[1] = [x[0], x[1]];
        x = vm.parseJsonUintArray(json, string.concat(k, "[2]"));
        c = [x[0], x[1]];
    }

    function _record(string memory name) internal returns (string memory out) {
        uint256 g = vm.lastCallGas().gasTotalUsed;
        emit log_named_uint(name, g);
        out = vm.serializeUint(OUT, name, g);
    }

    function test_VerificationGasPerProofSystem() public {
        (uint256[2] memory a, uint256[2][2] memory b, uint256[2] memory c) = _g16("groth16_liveness");
        LivenessVerifier g16l = new LivenessVerifier();
        assertTrue(g16l.verifyProof(a, b, c, _pub("groth16_liveness")));
        _record("groth16_liveness");

        (a, b, c) = _g16("groth16_age");
        AgeVerifier g16a = new AgeVerifier();
        assertTrue(g16a.verifyProof(a, b, c, _pub("groth16_age")));
        _record("groth16_age");

        LivenessPlonkVerifier pl = new LivenessPlonkVerifier();
        assertTrue(pl.verifyProof(_words("plonk_liveness"), _pub("plonk_liveness")));
        _record("plonk_liveness");

        AgePlonkVerifier pa = new AgePlonkVerifier();
        assertTrue(pa.verifyProof(_words("plonk_age"), _pub("plonk_age")));
        _record("plonk_age");

        AgeFflonkVerifier fa = new AgeFflonkVerifier();
        uint256[24] memory w = _words("fflonk_age");
        bytes32[24] memory fw;
        for (uint256 i; i < 24; i++) fw[i] = bytes32(w[i]);
        assertTrue(fa.verifyProof(fw, _pub("fflonk_age")));
        string memory out = _record("fflonk_age");

        if (vm.envOr("WRITE_REPORTS", false)) vm.writeJson(out, "reports/gas-proofsys.json");
    }
}
