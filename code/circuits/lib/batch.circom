pragma circom 2.1.9;

include "circomlib/circuits/bitify.circom";
include "circomlib/circuits/comparators.circom";
include "./liveness.circom";
include "./merkle.circom";

// Aggregated proof of life: one Groth16 proof attesting that every principal marked present in
// `presence` held an issuer-signed LivenessCredential whose timestamp falls inside the epoch.
//
// The statement is a conjunction of N independent proofs of life, so its soundness is exactly the
// soundness of the single-principal circuit: an aggregator can decline to include a principal, but
// it can never make a silent principal appear alive. That asymmetry is what the registry relies on.
//
//   enrollRoot   root of the registry's enrollment tree (leaf i = principal i's binding beta_i)
//   base         enrollment index of the first slot this batch covers; slot of i is base + i
//   epochStart   inclusive lower bound on every included liveness timestamp
//   epochEnd     inclusive upper bound on every included liveness timestamp
//   presence[]   packed presence bits, BITS_PER_WORD per word, bit j of word w = principal
//                w * BITS_PER_WORD + j. Bits at or beyond N are forced to zero, so the verifying
//                contract can store the words verbatim as the epoch's attendance record.
//
// Public signals (in snarkjs order): [enrollRoot, base, epochStart, epochEnd, presence[0..W-1]]
template EpochAttestation(N, mtLevels, enrollLevels, WORDS) {
    // 248 = 31 bytes: the largest byte-aligned width that always fits in the BN254 scalar field,
    // so a word can be moved between calldata and a field element without re-packing.
    var BITS_PER_WORD = 248;
    assert(WORDS * BITS_PER_WORD >= N);

    signal input enrollRoot;
    signal input base;
    signal input epochStart;
    signal input epochEnd;
    signal input presence[WORDS];

    signal input claim[N][8];
    signal input issuerAx[N];
    signal input issuerAy[N];
    signal input sigR8x[N];
    signal input sigR8y[N];
    signal input sigS[N];
    signal input livenessTimestamp[N];
    signal input tsSiblings[N][mtLevels];
    signal input didSalt[N];
    signal input enrollSiblings[N][enrollLevels];

    // ---------------------------------------------------------------- unpack the presence bitmap
    component word[WORDS];
    signal present[N];
    for (var w = 0; w < WORDS; w++) {
        word[w] = Num2Bits(BITS_PER_WORD);
        word[w].in <== presence[w];
        for (var j = 0; j < BITS_PER_WORD; j++) {
            var i = w * BITS_PER_WORD + j;
            if (i < N) {
                present[i] <== word[w].out[j];
            } else {
                // No principal occupies this position: the bit must be zero, otherwise the
                // contract would record an attestation that the circuit never checked.
                word[w].out[j] === 0;
            }
        }
    }

    // Epoch bounds are compared with 64-bit comparators, so they must be 64-bit values.
    component startBits = Num2Bits(64);
    startBits.in <== epochStart;
    component endBits = Num2Bits(64);
    endBits.in <== epochEnd;

    // ---------------------------------------------------------------- per-principal statements
    component pol[N];
    component enroll[N];
    component sameSlot[N];
    component tsBits[N];
    component notBefore[N];
    component notAfter[N];
    component inEpochLo[N];
    component inEpochHi[N];

    for (var i = 0; i < N; i++) {
        // (a) the credential is a LivenessCredential signed by the issuer, and its merklized
        //     livenessTimestamp is `livenessTimestamp[i]`.
        pol[i] = ProofOfLifeEnabled(mtLevels);
        pol[i].enabled <== present[i];
        for (var k = 0; k < 8; k++) { pol[i].claim[k] <== claim[i][k]; }
        pol[i].issuerAx <== issuerAx[i];
        pol[i].issuerAy <== issuerAy[i];
        pol[i].sigR8x <== sigR8x[i];
        pol[i].sigR8y <== sigR8y[i];
        pol[i].sigS <== sigS[i];
        pol[i].livenessTimestamp <== livenessTimestamp[i];
        for (var k = 0; k < mtLevels; k++) { pol[i].tsSiblings[k] <== tsSiblings[i][k]; }
        pol[i].didSalt <== didSalt[i];

        // (b) the binding derived from that credential is the one enrolled at slot base + i.
        //     Without this the aggregator could satisfy slot i with any other principal's
        //     credential, which would break bounded succession denial for the vault at slot i.
        enroll[i] = MerkleInclusion(enrollLevels);
        enroll[i].leaf <== pol[i].binding;
        enroll[i].index <== base + i;
        for (var k = 0; k < enrollLevels; k++) { enroll[i].siblings[k] <== enrollSiblings[i][k]; }

        sameSlot[i] = ForceEqualIfEnabled();
        sameSlot[i].enabled <== present[i];
        sameSlot[i].in[0] <== enroll[i].root;
        sameSlot[i].in[1] <== enrollRoot;

        // (c) the liveness timestamp lies inside the epoch. The contract separately checks that
        //     the epoch is recent and does not overlap an epoch already recorded, which is what
        //     stops an aggregator from replaying one credential into every future epoch.
        tsBits[i] = Num2Bits(64);
        tsBits[i].in <== livenessTimestamp[i];

        notBefore[i] = GreaterEqThan(64);
        notBefore[i].in[0] <== livenessTimestamp[i];
        notBefore[i].in[1] <== epochStart;
        inEpochLo[i] = ForceEqualIfEnabled();
        inEpochLo[i].enabled <== present[i];
        inEpochLo[i].in[0] <== notBefore[i].out;
        inEpochLo[i].in[1] <== 1;

        notAfter[i] = LessEqThan(64);
        notAfter[i].in[0] <== livenessTimestamp[i];
        notAfter[i].in[1] <== epochEnd;
        inEpochHi[i] = ForceEqualIfEnabled();
        inEpochHi[i].enabled <== present[i];
        inEpochHi[i].in[0] <== notAfter[i].out;
        inEpochHi[i].in[1] <== 1;
    }
}

// One principal claiming an empty enrollment slot: proves newRoot is oldRoot with slot `index`
// changed from empty to `binding`. Cheap (a few thousand constraints) and used once per principal.
//
// Public signals (in snarkjs order): [oldRoot, newRoot, index, binding]
template Enrollment(enrollLevels) {
    signal input oldRoot;
    signal input newRoot;
    signal input index;
    signal input binding;
    signal input siblings[enrollLevels];

    component ins = MerkleInsert(enrollLevels);
    ins.oldRoot <== oldRoot;
    ins.newRoot <== newRoot;
    ins.index <== index;
    ins.leaf <== binding;
    for (var i = 0; i < enrollLevels; i++) { ins.siblings[i] <== siblings[i]; }
}
