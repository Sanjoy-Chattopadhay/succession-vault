pragma circom 2.1.9;

include "./lib/batch.circom";

// Claiming one enrollment slot in the liveness registry. Enrollment is a once-per-principal
// action, so the cost of this proof is amortised over every epoch the principal ever attests in.
//
// Public signals (in snarkjs order): [oldRoot, newRoot, index, binding]
component main {public [oldRoot, newRoot, index, binding]} = Enrollment(16);
