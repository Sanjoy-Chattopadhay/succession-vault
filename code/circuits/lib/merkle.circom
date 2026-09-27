pragma circom 2.1.9;

include "circomlib/circuits/poseidon.circom";
include "circomlib/circuits/bitify.circom";
include "circomlib/circuits/mux1.circom";

// Inclusion proof for a fixed-depth binary Merkle tree over Poseidon(2).
//
// The tree is indexed by leaf position: bit b of `index` selects, at level b, whether the running
// hash is the left (b = 0) or the right (b = 1) input. Empty positions hold 0, so a tree of
// capacity 2^levels can be filled incrementally and its root is well defined at every point.
template MerkleInclusion(levels) {
    signal input leaf;
    signal input index;
    signal input siblings[levels];
    signal output root;

    component idx = Num2Bits(levels);
    idx.in <== index;

    component h[levels];
    component mux[levels];
    signal cur[levels + 1];
    cur[0] <== leaf;

    for (var i = 0; i < levels; i++) {
        // mux.out[0] = left input, mux.out[1] = right input
        mux[i] = MultiMux1(2);
        mux[i].c[0][0] <== cur[i];
        mux[i].c[0][1] <== siblings[i];
        mux[i].c[1][0] <== siblings[i];
        mux[i].c[1][1] <== cur[i];
        mux[i].s <== idx.out[i];

        h[i] = Poseidon(2);
        h[i].inputs[0] <== mux[i].out[0];
        h[i].inputs[1] <== mux[i].out[1];
        cur[i + 1] <== h[i].out;
    }

    root <== cur[levels];
}

// Proof that `newRoot` is `oldRoot` with the leaf at `index` changed from 0 to `leaf`, every other
// leaf unchanged. Used once per principal, when they claim an enrollment slot in the registry.
//
// Replaying the same siblings for both roots is what forces "everything else unchanged": a single
// sibling vector can only be consistent with one pair (old leaf, new leaf) at that position.
template MerkleInsert(levels) {
    signal input oldRoot;
    signal input newRoot;
    signal input index;
    signal input leaf;
    signal input siblings[levels];

    component before = MerkleInclusion(levels);
    before.leaf <== 0;            // the slot must be empty before enrollment
    before.index <== index;
    for (var i = 0; i < levels; i++) { before.siblings[i] <== siblings[i]; }
    before.root === oldRoot;

    component after = MerkleInclusion(levels);
    after.leaf <== leaf;
    after.index <== index;
    for (var i = 0; i < levels; i++) { after.siblings[i] <== siblings[i]; }
    after.root === newRoot;
}
