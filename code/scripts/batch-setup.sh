#!/usr/bin/env bash
# Groth16 setup for the aggregation circuits.
#
# Builds three families:
#   enroll                     one principal claiming an enrollment slot (once per principal)
#   agg_N{n}_m40_w1            aggregation of n proofs of life at the production merklization
#                              depth of 40, so the per-principal cost is directly comparable to
#                              the deployed single-principal circuit
#   agg_N1_m16_w{w}            one principal but w presence words, used to measure the on-chain
#                              cost of an epoch covering w * 248 enrolled principals
#
# Phase 1 is the Perpetual Powers of Tau (PSE, 80 contributions). Phase 2 is one local
# contribution plus a public beacon: enough for a prototype, not for deployment.
set -euo pipefail
cd "$(dirname "$0")/.."

CIRCOM="${CIRCOM:-circom}"
PTAU=zk/ptau/ppot_0080_18.ptau
BEACON=${BEACON:-0000000000000000000000000000000000000000000000000000000000000000}
SNARKJS="npx --no-install snarkjs"
OUT=zk/batch
ENROLL_LEVELS=16          # 65,536 enrollment slots

mkdir -p "$OUT" src/verifiers
[ -f "$PTAU" ] || { echo "missing $PTAU" >&2; exit 1; }

# setup <circuit-name> <path-to-.circom> <solidity-contract-name>
setup() {
  local name="$1" src="$2" contract="$3"
  echo "== $name: compile"
  "$CIRCOM" "$src" --r1cs --wasm --sym -l node_modules -o "$OUT" > /dev/null
  local constraints
  constraints=$($SNARKJS r1cs info "$OUT/$name.r1cs" 2>/dev/null | awk '/# of Constraints/ {print $NF}')
  echo "   constraints: $constraints"

  echo "== $name: phase 2"
  $SNARKJS groth16 setup "$OUT/$name.r1cs" "$PTAU" "$OUT/${name}_0000.zkey" > /dev/null
  $SNARKJS zkey contribute "$OUT/${name}_0000.zkey" "$OUT/${name}_0001.zkey" \
    --name="local contribution" -e="$(head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n')" > /dev/null
  $SNARKJS zkey beacon "$OUT/${name}_0001.zkey" "$OUT/$name.zkey" "$BEACON" 10 -n="final beacon" > /dev/null
  rm -f "$OUT/${name}_0000.zkey" "$OUT/${name}_0001.zkey"
  $SNARKJS zkey export verificationkey "$OUT/$name.zkey" "$OUT/${name}_vkey.json" > /dev/null

  $SNARKJS zkey export solidityverifier "$OUT/$name.zkey" "src/verifiers/$contract.sol" > /dev/null
  sed -i "s/contract Groth16Verifier/contract $contract/; s/pragma solidity >=0.7.0 <0.9.0;/pragma solidity ^0.8.24;/" \
    "src/verifiers/$contract.sol"
  echo "   -> $OUT/$name.zkey, src/verifiers/$contract.sol"
}

gen_main() {   # gen_main <file> <N> <mtLevels> <words>
  cat > "$1" <<EOF
pragma circom 2.1.9;
include "../../circuits/lib/batch.circom";
component main {public [enrollRoot, base, epochStart, epochEnd, presence]} =
    EpochAttestation($2, $3, $ENROLL_LEVELS, $4);
EOF
}

# ---- enrollment -------------------------------------------------------------------------------
setup enroll circuits/enroll.circom EnrollVerifier

# ---- aggregation at the production merklization depth -----------------------------------------
for n in ${N_SWEEP:-1 2 4 8}; do
  name="agg_N${n}_m40_w1"
  gen_main "$OUT/$name.circom" "$n" 40 1
  setup "$name" "$OUT/$name.circom" "AggVerifier_N${n}_m40_w1"
done

# ---- one shallow deep-batch point (needs a 16-level merklization) ------------------------------
for n in ${N_SWEEP16:-16}; do
  name="agg_N${n}_m16_w1"
  gen_main "$OUT/$name.circom" "$n" 16 1
  setup "$name" "$OUT/$name.circom" "AggVerifier_N${n}_m16_w1"
done

# ---- presence-word sweep: on-chain cost of an epoch covering w * 248 principals ----------------
for w in ${W_SWEEP:-1 2 4 8 16 32}; do
  name="agg_N1_m16_w${w}"
  [ -f "$OUT/$name.zkey" ] && { echo "== $name: exists, skipping"; continue; }
  gen_main "$OUT/$name.circom" 1 16 "$w"
  setup "$name" "$OUT/$name.circom" "AggVerifier_N1_m16_w${w}"
done

echo "done."
