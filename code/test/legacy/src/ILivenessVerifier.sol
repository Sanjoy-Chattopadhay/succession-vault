// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ILivenessVerifier
/// @notice Interface for the DID-based Groth16 liveness verifier (5 public signals).
/// @dev Public signals: [isValid, didHash, expirationDate, revocationNonce, currentTimestamp]
///      This matches the liveness.circom circuit output used with iden3/Privado DID credentials.
interface ILivenessVerifier {
    function verifyProof(
        uint256[2] calldata pA,
        uint256[2][2] calldata pB,
        uint256[2] calldata pC,
        uint256[5] calldata pubSignals
    ) external view returns (bool);
}
