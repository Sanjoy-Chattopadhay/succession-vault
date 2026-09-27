pragma circom 2.1.9;

include "circomlib/circuits/poseidon.circom";
include "circomlib/circuits/eddsaposeidon.circom";
include "circomlib/circuits/smt/smtverifier.circom";

// Proof of life from an iden3 LivenessCredential issued by a Privado ID / Billions issuer
// (W3C credential with a BJJSignature2021 proof over an iden3 core claim).
//
// This is circuits/liveness.circom generalised with an `enabled` flag so that one instance can be
// switched off inside a batch. With enabled = 1 the constraints are exactly those of the
// single-principal circuit; with enabled = 0 nothing is asserted about the witness and `binding`
// and `timestamp` are unconstrained (the caller must not use them).
//
// Reusing circomlib's own `enabled` inputs keeps the disabled instance free of extra constraints:
// EdDSAPoseidonVerifier and SMTVerifier already multiply their assertions by `enabled`.
template ProofOfLifeEnabled(mtLevels) {
    // Slot i0 of every LivenessCredential core claim: schema hash (low 128 bits) and flags 0x2a
    // (subject ID in index slot i1, merklized root in index slot i2, expiration set, version 0).
    var LIVENESS_CLAIM_I0 = 0x2aad090f03bc9fcb197e0259ff687cbcac;
    // Merklization path key of credentialSubject.livenessTimestamp under the LivenessCredential
    // JSON-LD context (ipfs://QmcomGJQwJDCg3RE6FjsFYCjjMSTWJXY3fUWeq43Mc5CCJ).
    var LIVENESS_TS_PATH_KEY = 0xe86cac320c39ec559aa5b0e09fa069e02a5cc833f4a197c1f72bd48a6c19e8b;

    signal input enabled;                // 0 or 1; the caller must constrain it to be boolean
    signal input claim[8];               // core claim slots i0..i3, v0..v3
    signal input issuerAx;
    signal input issuerAy;
    signal input sigR8x;
    signal input sigR8y;
    signal input sigS;
    signal input livenessTimestamp;
    signal input tsSiblings[mtLevels];   // merklization proof of livenessTimestamp in claim[2]
    signal input didSalt;                // hides the DID inside the on-chain binding

    signal output binding;               // Poseidon(issuerAx, issuerAy, subjectId, didSalt)
    signal output timestamp;

    // 1. The claim is a LivenessCredential with the expected layout.
    //    Written as a conditional equality so that a disabled instance may carry a zero witness.
    enabled * (claim[0] - LIVENESS_CLAIM_I0) === 0;

    // 2. The issuer signed the claim: M = Poseidon(Poseidon(i0..i3), Poseidon(v0..v3)).
    component hIndex = Poseidon(4);
    component hValue = Poseidon(4);
    for (var i = 0; i < 4; i++) {
        hIndex.inputs[i] <== claim[i];
        hValue.inputs[i] <== claim[4 + i];
    }
    component hClaim = Poseidon(2);
    hClaim.inputs[0] <== hIndex.out;
    hClaim.inputs[1] <== hValue.out;

    component sig = EdDSAPoseidonVerifier();
    sig.enabled <== enabled;
    sig.Ax <== issuerAx;
    sig.Ay <== issuerAy;
    sig.S <== sigS;
    sig.R8x <== sigR8x;
    sig.R8y <== sigR8y;
    sig.M <== hClaim.out;

    // 3. livenessTimestamp is the value stored under its path key in the merklized root (slot i2).
    component smt = SMTVerifier(mtLevels);
    smt.enabled <== enabled;
    smt.fnc <== 0;                        // inclusion
    smt.root <== claim[2];
    for (var i = 0; i < mtLevels; i++) {
        smt.siblings[i] <== tsSiblings[i];
    }
    smt.oldKey <== 0;
    smt.oldValue <== 0;
    smt.isOld0 <== 0;
    smt.key <== LIVENESS_TS_PATH_KEY;
    smt.value <== livenessTimestamp;

    // 4. Bind issuer key and subject DID (slot i1) to the value registered in the vault.
    component hBinding = Poseidon(4);
    hBinding.inputs[0] <== issuerAx;
    hBinding.inputs[1] <== issuerAy;
    hBinding.inputs[2] <== claim[1];
    hBinding.inputs[3] <== didSalt;
    binding <== hBinding.out;

    timestamp <== livenessTimestamp;
}
