pragma circom 2.1.9;

include "circomlib/circuits/poseidon.circom";
include "circomlib/circuits/bitify.circom";
include "circomlib/circuits/comparators.circom";

// Age gate for an age-restricted bequest.
//
// The testator commits to the heir's birth date as commitment = Poseidon(birthDate, salt), with
// birthDate encoded as the integer YYYYMMDD. The heir proves birthDate <= cutoff, where the vault
// derives the admissible cutoff from block.timestamp and the bequest's minimum age
// (today's YYYYMMDD minus minAge * 10000), so the birth date is never revealed.
//
// Public signals (in snarkjs order): [commitment, cutoff]
template AgeGate() {
    signal input birthDate;   // private, YYYYMMDD
    signal input salt;        // private
    signal input commitment;  // public
    signal input cutoff;      // public, YYYYMMDD

    // Range checks keep the comparison below sound (no wrap-around in the field).
    component birthBits = Num2Bits(32);
    birthBits.in <== birthDate;
    component cutoffBits = Num2Bits(32);
    cutoffBits.in <== cutoff;

    component h = Poseidon(2);
    h.inputs[0] <== birthDate;
    h.inputs[1] <== salt;
    commitment === h.out;

    component le = LessEqThan(32);
    le.in[0] <== birthDate;
    le.in[1] <== cutoff;
    le.out === 1;
}

component main {public [commitment, cutoff]} = AgeGate();
