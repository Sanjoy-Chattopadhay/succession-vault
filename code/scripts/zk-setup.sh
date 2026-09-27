#!/usr/bin/env bash
# Circuit-specific Groth16 setup for the two circuits.
#
# Phase 1: Perpetual Powers of Tau (PSE, 80 contributions), truncated to 2^15.
# Phase 2: one local contribution plus a public beacon. This is enough for a prototype; a
#          production deployment must run phase 2 as a multi-party ceremony.
set -euo pipefail
cd "$(dirname "$0")/.."

CIRCOM="${CIRCOM:-circom}"
PTAU=zk/ptau/ppot_0080_15.ptau
PTAU_URL=https://pse-trusted-setup-ppot.s3.eu-central-1.amazonaws.com/pot28_0080/ppot_0080_15.ptau
BEACON=${BEACON:-0000000000000000000000000000000000000000000000000000000000000000}
SNARKJS="npx --no-install snarkjs"

mkdir -p zk/ptau zk/build src/verifiers
[ -f "$PTAU" ] || curl -sL -o "$PTAU" "$PTAU_URL"

for c in liveness age; do
  echo "== $c: compile"
  "$CIRCOM" circuits/$c.circom --r1cs --wasm --sym -l node_modules -o zk/build > /dev/null
  echo "== $c: phase 2"
  $SNARKJS groth16 setup zk/build/$c.r1cs "$PTAU" zk/build/${c}_0000.zkey > /dev/null
  $SNARKJS zkey contribute zk/build/${c}_0000.zkey zk/build/${c}_0001.zkey \
    --name="local contribution" -e="$(head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n')" > /dev/null
  $SNARKJS zkey beacon zk/build/${c}_0001.zkey zk/build/${c}.zkey "$BEACON" 10 -n="final beacon" > /dev/null
  rm -f zk/build/${c}_0000.zkey zk/build/${c}_0001.zkey
  $SNARKJS zkey export verificationkey zk/build/${c}.zkey zk/build/${c}_vkey.json > /dev/null

  name="$(tr '[:lower:]' '[:upper:]' <<< "${c:0:1}")${c:1}Verifier"   # LivenessVerifier / AgeVerifier
  $SNARKJS zkey export solidityverifier zk/build/${c}.zkey src/verifiers/$name.sol > /dev/null
  sed -i "s/contract Groth16Verifier/contract $name/; s/pragma solidity >=0.7.0 <0.9.0;/pragma solidity ^0.8.24;/" src/verifiers/$name.sol
  echo "   -> zk/build/${c}.zkey, src/verifiers/$name.sol"
done
