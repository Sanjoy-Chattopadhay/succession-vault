pragma circom 2.1.9;
include "../../circuits/lib/batch.circom";
component main {public [enrollRoot, base, epochStart, epochEnd, presence]} =
    EpochAttestation(1, 16, 16, 4);
