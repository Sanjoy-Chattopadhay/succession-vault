#!/usr/bin/env bash
# Build the liveness circuit with a different Merkle depth, for the depth ablation
# (js/bench-depth.mjs). Prototype setup: one local phase-2 contribution, no beacon.
#   bash scripts/depth-variant.sh 16   ->  zk/variants/liveness16/
set -euo pipefail
cd "$(dirname "$0")/.."
L="${1:?levels}"
D="zk/variants/liveness$L"
mkdir -p "$D"
sed "s/component main = ProofOfLife(40);/component main = ProofOfLife($L);/" circuits/liveness.circom > "$D/liveness$L.circom"
"${CIRCOM:-circom}" "$D/liveness$L.circom" --r1cs --wasm -l node_modules -o "$D" | grep -E "constraints"
npx --no-install snarkjs groth16 setup "$D/liveness$L.r1cs" zk/ptau/ppot_0080_15.ptau "$D/tmp.zkey" > /dev/null
npx --no-install snarkjs zkey contribute "$D/tmp.zkey" "$D/liveness$L.zkey" --name="local" -e="$(head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n')" > /dev/null
rm -f "$D/tmp.zkey"
npx --no-install snarkjs zkey export verificationkey "$D/liveness$L.zkey" "$D/liveness${L}_vkey.json" > /dev/null
echo "-> $D"
