#!/usr/bin/env bash
# Symbolic verification of the vault and registry properties in test/halmos/ with Halmos
# (pip install halmos). Each property runs on its own so that one slow check cannot hide the
# others; logs go to evidence/logs/halmos-<check>.log and a summary to reports/halmos.json.
#   bash scripts/halmos.sh            all checks
#   bash scripts/halmos.sh check_P1   only checks whose name matches
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export PATH="$PATH:$HOME/.foundry/bin"
FILTER="${1:-}"
LOOP="${HALMOS_LOOP:-2}"
# The pip package yices-solver ships yices-smt2; point Halmos at it instead of letting it download
# a solver. Override with HALMOS_SOLVER=<path to an SMT-LIB2 solver>.
SOLVER="${HALMOS_SOLVER:-$(python -c "import site,os; print(os.path.join(site.USER_BASE, 'Scripts', 'yices-smt2.exe'))" 2>/dev/null)}"
# Halmos splits the command on spaces, so use the 8.3 short form of the path on Windows.
command -v cygpath >/dev/null 2>&1 && SOLVER="$(cygpath -m -s "$SOLVER")"
mkdir -p evidence/logs
# contract:function[:array-lengths]. Symbolic calldata for "any call" uses arrays of length 1
# (e.g. proveLifeMulti with one proof, claimMany with one leaf); the checks that are about
# arrays use lengths 1 and 2.
CHECKS=(
  "VaultSymbolic:check_P1_heartbeatCannotExtendLiveness"
  "VaultSymbolic:check_P3_livenessTimeOnlyByAcceptedProof"
  "VaultSymbolic:check_P4_settlementIsFinal"
  "VaultSymbolic:check_P5_noSettlementBeforeGrace"
  "VaultSymbolic:check_P6_ownerActionsNeedKeyAndFreshProof"
  "VaultSymbolic:check_P7_claimedBitsNeverCleared"
  "VaultSymbolic:check_P7_doubleClaimReverts:1,2"
  "VaultSymbolic:check_P8_poolsNeverOverPaid"
  "VaultSymbolic:check_P9_singleProofNeedsThresholdOne"
  "VaultSymbolic:check_P9_multiProofMeetsThreshold:1,2"
  "RegistrySymbolic:check_R_epochsOnlyByAggregatorAndWellFormed"
  "SanityNegative:check_NEG_livenessNeverChanges"
  "SanityNegative:check_NEG_rootNeverChanges"
)
python -m halmos --version > evidence/logs/halmos-version.log 2>&1
for c in "${CHECKS[@]}"; do
  IFS=: read -r contract fn lens <<< "$c"
  lens="${lens:-1}"
  [ -n "$FILTER" ] && [[ "$fn" != *"$FILTER"* ]] && continue
  log="evidence/logs/halmos-$fn.log"
  start=$(date +%s)
  python -m halmos --contract "$contract" --function "$fn" --loop "$LOOP" --solver-timeout-assertion 0 \
    --default-array-lengths "$lens" --default-bytes-lengths 0 --solver-command "$SOLVER" > "$log" 2>&1
  echo "# options: --loop $LOOP --default-array-lengths $lens --default-bytes-lengths 0 --solver yices-smt2" >> "$log"
  echo "# wall seconds: $(( $(date +%s) - start ))" >> "$log"
  grep -E "^\S*\[(PASS|FAIL|TIMEOUT|ERROR)" "$log" | sed 's/\x1b\[[0-9;]*m//g' | tail -1
done
python scripts/halmos_summary.py
