// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Interface of the snarkjs-generated Groth16 verifiers (two public signals each).
interface IGroth16Verifier {
    function verifyProof(
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[2] calldata publicSignals
    ) external view returns (bool);
}
