#!/usr/bin/env bash
# Experiments that run after scripts/sepolia_run.sh, against the same live deployment.
#
#  1. Attacks built from the owner's REAL Billions credential and from the aggregation run:
#     edited credentials (off-chain), then re-dated / foreign-bound / future-dated proofs and forged
#     epochs and enrollments against the live contracts (calls only; one createVault transaction).
#  3. A j-of-m issuer threshold (2-of-3 over three test issuers): one issuer alone is rejected,
#     any two are accepted, so one compromised issuer cannot keep a dead owner's vault alive and
#     one unavailable issuer does not stop a living owner from proving life.
#  2. An always-on key holder (e.g. an AI agent entrusted with the owner key): the human proves life
#     once, the agent heartbeats about once a minute, and the vault must still become claimable at
#     tL + lifeProofInterval + gracePeriod.
#
#   Git Bash:    bash scripts/sepolia_extras.sh [attacks|agent|threshold|all]   (default: all)
#   PowerShell:  & "$env:ProgramFiles\Git\bin\bash.exe" scripts/sepolia_extras.sh
set -uo pipefail
MODE="${1:-all}"
SEPOLIA_RUN_LIB=1
source "$(dirname "${BASH_SOURCE[0]}")/sepolia_run.sh"
P="${DRY_RUN:+dryrun-}sepolia"

[ -f "deployments/$CHAIN_ID.json" ] || stop "no deployment for chain $CHAIN_ID; run scripts/sepolia_run.sh first."
[ -f demo/agg.json ] && [ -f demo/owner.json ] || stop "demo/agg.json or demo/owner.json missing; run scripts/sepolia_run.sh first."
pick_rpc || stop "no RPC server in RPC_LIST is reachable."
mkdir -p demo/attacks demo/agent

# ------------------------------------------------------------------ 1. attacks
if [ "$MODE" = attacks ] || [ "$MODE" = all ]; then
ev $P-20-attacks-offchain node js/attacks.mjs
ev $P-21-attack-vault forge script script/DemoAttacks.s.sol --sig "createVault()" $F
sleep 20   # the attacks re-date proofs to "now", which must be later than the vault's creation
ev $P-22-attacks-onchain forge script script/DemoAttacks.s.sol --sig "attacks()" $R
fi

# ------------------------------------------------------------------ 2. always-on key holder
if [ "$MODE" = agent ] || [ "$MODE" = all ]; then
ev $P-30-agent-vault forge script script/DemoAgent.s.sol --sig "create()" $F
sleep 20
# The credential must be strictly newer than the vault's creation time, even if no block has been
# mined since then, and no later than the chain's clock allows.
AGENT_VAULT=$(python -c "import json; print(json.load(open('demo/agent/state.json'))['vault'])")
TL0=$(rpc_read cast call "$AGENT_VAULT" "lastLifeProof()(uint40)")
need "the agent vault's creation time" "$TL0"
LIFE_NOW=$(chain_now)
[ "$LIFE_NOW" -le "$TL0" ] && LIFE_NOW=$(( TL0 + 1 ))
export LIFE_NOW
ev $P-31-agent-life-proof node js/demo.mjs life --test-issuer
cp demo/life-proof.json demo/agent/life-proof.json
ev $P-32-agent-human-proves-life forge script script/DemoAgent.s.sol --sig "proveLife()" $F

TL=$(rpc_read cast call "$(python -c "import json; print(json.load(open('demo/agent/state.json'))['vault'])")" "lastLifeProof()(uint40)")
need "the agent vault's lastLifeProof" "$TL"
END=$(( TL + 8 * 60 + 2 * 60 + 90 ))   # tL + lifeProofInterval + gracePeriod + margin
echo "human's last proof of life at $TL; the agent now heartbeats until chain time > $END"
i=0
while [ "$(chain_now)" -le "$END" ]; do
  i=$(( i + 1 ))
  ev "$P-33-agent-beat-$(printf %02d $i)" forge script script/DemoAgent.s.sol --sig "beat()" $F
  sleep 45
done
ev $P-34-agent-final-status forge script script/DemoAgent.s.sol --sig "status()" $R
node js/agent-report.mjs "$P"
fi
# ------------------------------------------------------------------ 3. issuer threshold
if [ "$MODE" = threshold ] || [ "$MODE" = all ]; then
mkdir -p demo/threshold
ev $P-40-threshold-setup node js/demo.mjs threshold-setup
ev $P-41-threshold-vault forge script script/DemoThreshold.s.sol --sig "create()" $F
sleep 20
THR_VAULT=$(python -c "import json; print(json.load(open('demo/threshold/state.json'))['vault'])")
T0V=$(rpc_read cast call "$THR_VAULT" "lastLifeProof()(uint40)")
need "the threshold vault's creation time" "$T0V"
LIFE_NOW=$(chain_now); [ "$LIFE_NOW" -le "$T0V" ] && LIFE_NOW=$(( T0V + 1 )); export LIFE_NOW
ev $P-42-threshold-proof-a node js/demo.mjs threshold-life --issuers A --tag a0
ev $P-43-threshold-prove-a forge script script/DemoThreshold.s.sol --sig "proveA()" $F
ev $P-44-threshold-configure forge script script/DemoThreshold.s.sol --sig "configure()" $F
TL=$(rpc_read cast call "$THR_VAULT" "lastLifeProof()(uint40)")
need "the threshold vault's lastLifeProof" "$TL"
wait_chain $(( TL + 60 ))
LIFE_NOW=$(chain_now); export LIFE_NOW
ev $P-45-threshold-proofs node js/demo.mjs threshold-life --issuers A --tag a1
ev $P-46-threshold-one-issuer-rejected forge script script/DemoThreshold.s.sol --sig "tryAlone()" $R
ev $P-47-threshold-proofs-ab node js/demo.mjs threshold-life --issuers A,B --tag ab
export TAG=ab; ev $P-48-threshold-two-issuers forge script script/DemoThreshold.s.sol --sig "multi()" $F
TL=$(rpc_read cast call "$THR_VAULT" "lastLifeProof()(uint40)")
need "the threshold vault's lastLifeProof" "$TL"
wait_chain $(( TL + 60 ))
LIFE_NOW=$(chain_now); export LIFE_NOW
# Issuer A is now unavailable: B and C still reach the threshold.
ev $P-49-threshold-proofs-bc node js/demo.mjs threshold-life --issuers B,C --tag bc
export TAG=bc; ev $P-50-threshold-outage-tolerated forge script script/DemoThreshold.s.sol --sig "multi()" $F
ev $P-51-threshold-status forge script script/DemoThreshold.s.sol --sig "status()" $R
fi

echo
echo "extras complete ($MODE)"
