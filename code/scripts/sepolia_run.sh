#!/usr/bin/env bash
# Full live lifecycle on Ethereum Sepolia, captured step by step in evidence/logs/sepolia-*.log.
# Needs PRIVATE_KEY in .env (read by the Foundry scripts, never printed). Takes about an hour,
# mostly waiting for the demo timers (heartbeat 10 min, grace 5 min, claim window 30 min).
#
#   Git Bash:    bash scripts/sepolia_run.sh
#   PowerShell:  powershell -ExecutionPolicy Bypass -File scripts\sepolia_run.ps1
#
# Do not run it with the `bash` that PowerShell finds by default: that is WSL's Linux bash, which
# cannot see the Windows installs of forge, cast, node and python. The checks below stop early if so.
#
# Free public RPC servers throttle heavy use (e.g. a Cloudflare 403 page). The script therefore
# picks the first working server from RPC_LIST and, when a step fails with a throttling or network
# error BEFORE anything was sent, retries it on the next server. A step that may already have sent
# a transaction is never retried automatically.
#
# Every run deploys fresh contracts and archives the previous run's logs, so a re-run after a
# failure starts from a clean state. The run stops at the first step that really fails.
#
# Dry run on a local Anvil node (no key; unlocked dev account; the chain clock is advanced instead
# of waiting):
#   DRY_RUN=1 RPC=http://127.0.0.1:8545 CHAIN_ID=31337 \
#   EXTRA_FLAGS="--unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" bash scripts/sepolia_run.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export PATH="$PATH:$HOME/.foundry/bin"
export CHAIN_ID="${CHAIN_ID:-11155111}"
# An explicit RPC (e.g. a local node, or your own Alchemy/Infura URL) is used alone; otherwise the
# list of free Sepolia servers is tried in order.
RPC_LIST="${RPC:-${RPC_LIST:-https://ethereum-sepolia-rpc.publicnode.com https://sepolia.gateway.tenderly.co https://1rpc.io/sepolia}}"
RPC_URL=""
F="--rpc-url @RPC@ --broadcast --slow ${EXTRA_FLAGS:-}"
R="--rpc-url @RPC@ ${EXTRA_FLAGS:-}"
P="${DRY_RUN:+dryrun-}sepolia"
REAL_CRED=fixtures/private/liveness-2025-12-14.json
MIN_BALANCE_WEI=50000000000000000   # 0.05 ETH; the whole run uses about 12.6M gas
MAX_ATTEMPTS=5
STEPS=0
# A dry run must never pick up the real key from .env: an empty variable overrides the file.
[ -n "${DRY_RUN:-}" ] && export PRIVATE_KEY=""

# ------------------------------------------------------------------ helpers
stop() { echo; echo "STOPPED: $*" >&2; exit 1; }

# Pick the first server in RPC_LIST, starting after the current one, that answers with the right
# chain id. Returns non-zero if none does.
pick_rpc() {
  local list=($RPC_LIST) n=${#RPC_LIST} i start=0 u cid
  n=${#list[@]}
  for i in "${!list[@]}"; do [ "${list[$i]}" = "$RPC_URL" ] && start=$(( i + 1 )); done
  for (( k = 0; k < n; k++ )); do
    u="${list[$(( (start + k) % n ))]}"
    cid=$(timeout 20 cast chain-id --rpc-url "$u" 2>/dev/null)
    [ "$cid" = "$CHAIN_ID" ] || continue
    # A throttled server may still answer eth_chainId while refusing the storage reads that forge
    # needs, so require a storage read to succeed too.
    timeout 20 cast storage 0x0000000000000000000000000000000000000000 0 --rpc-url "$u" >/dev/null 2>&1 || continue
    RPC_URL="$u"; echo "using RPC $u"; return 0
  done
  return 1
}

# A step failed because of the server (throttled, blocked, unreachable), not because of our code.
transient() {
  grep -qE "HTTP error (403|408|425|429|5[0-9][0-9])|Too Many Requests|rate.?limit|error sending request|timed out|operation timed out|connection (reset|refused|closed)|Just a moment|dns error|failed to get storage|failed to get account|EOF while parsing" "$1"
}

# Run one step, keep its evidence, and stop the run unless it ended as expected. Step 10 is the
# one step that must FAIL: the vault has to reject a stale credential. "@RPC@" in the arguments is
# replaced by the server in use, so a retry can move to another server.
ev() {
  local name="$1" log="evidence/logs/$1.log" code attempt=1 a
  shift
  while :; do
    local args=()
    for a in "$@"; do args+=("${a//@RPC@/$RPC_URL}"); done
    bash scripts/evidence.sh "$name" "${args[@]}" | tail -n 12
    code=$(grep -oE "# exit code: [0-9]+" "$log" 2>/dev/null | tail -1 | awk '{print $4}')
    case "$name" in *-10-stale-credential-rejected)
      # A real rejection is a contract revert; a server error here would prove nothing.
      if [ -n "$code" ] && [ "$code" != "0" ] && ! transient "$log"; then break; fi ;;
    *) [ "$code" = "0" ] && break ;;
    esac
    # Retry only if the server was at fault AND nothing can have been sent: Foundry prints the
    # gas estimate just before it starts broadcasting, so its absence means no transaction left.
    if [ "$attempt" -lt "$MAX_ATTEMPTS" ] && transient "$log" && ! grep -q "Estimated total gas used" "$log"; then
      attempt=$(( attempt + 1 ))
      mv "$log" "evidence/logs/$name.attempt$(( attempt - 1 )).log"
      echo "  server problem in $name (nothing was sent); retrying on another server, attempt $attempt of $MAX_ATTEMPTS"
      sleep 15
      pick_rpc || stop "no RPC server in RPC_LIST is reachable. Check your connection and re-run."
      continue
    fi
    break
  done
  STEPS=$(( STEPS + 1 ))
  case "$name" in
    *-10-stale-credential-rejected)
      [ -n "$code" ] && [ "$code" != "0" ] && ! transient "$log" \
        || stop "$name: the stale credential was NOT shown to be rejected (exit code '${code:-none}'). See $log" ;;
    *)
      if [ "$code" != "0" ] && transient "$log" && grep -q "Estimated total gas used" "$log"; then
        stop "$name hit a server error AFTER Foundry began sending, so a transaction may have gone out.
Not retrying automatically, to avoid sending anything twice. See $log
Re-running the whole script is safe: it starts fresh with new contracts."
      fi
      [ "$code" = "0" ] || stop "$name failed (exit code '${code:-none}'). See $log
Nothing after this step was run. Fix the cause and re-run the whole script; it starts fresh." ;;
  esac
}

# Read a value from the chain, moving to another server if the current one fails.
rpc_read() {
  local out tries=0
  while [ $tries -lt $MAX_ATTEMPTS ]; do
    out=$(timeout 30 "$@" --rpc-url "$RPC_URL" 2>/dev/null | awk '{print $1}')
    [ -n "$out" ] && { echo "$out"; return 0; }
    tries=$(( tries + 1 )); sleep 10; pick_rpc >/dev/null || true
  done
  return 1
}
need() { [ -n "$2" ] || stop "could not read $1 from the chain or the demo files."; }
chain_now() { timeout 30 cast block latest --field timestamp --rpc-url "$RPC_URL" 2>/dev/null || date +%s; }
vault() { python -c "import json; print(json.load(open('demo/state.json'))['vault'])"; }
wait_chain() {  # wait until the chain's latest block time exceeds $1
  if [ -n "${DRY_RUN:-}" ]; then
    cast rpc evm_setNextBlockTimestamp $(( $1 + 1 )) --rpc-url "$RPC_URL" >/dev/null
    cast rpc evm_mine --rpc-url "$RPC_URL" >/dev/null
    return
  fi
  echo "waiting until chain time > $1 (about $(( $1 - $(chain_now) )) s; this is expected, leave it running)"
  while [ "$(chain_now)" -le "$1" ]; do sleep 30; done
}

# Tests source this file with SEPOLIA_RUN_LIB=1 to get the helpers without running anything.
[ -n "${SEPOLIA_RUN_LIB:-}" ] && return 0

# ------------------------------------------------------------------ preflight (nothing is sent yet)
if grep -qi microsoft /proc/version 2>/dev/null; then
  stop "this is WSL's Linux bash, which cannot see the Windows installs of forge, cast, node and python.
From PowerShell run:   powershell -ExecutionPolicy Bypass -File scripts\\sepolia_run.ps1
or open Git Bash and run:   bash scripts/sepolia_run.sh"
fi
for t in forge cast node python timeout; do
  command -v "$t" >/dev/null 2>&1 || stop "'$t' is not on PATH. Run this from Git Bash, or from PowerShell with scripts\\sepolia_run.ps1."
done
[ -f "$REAL_CRED" ] || stop "$REAL_CRED is missing (needed for the stale-credential step)."
pick_rpc || stop "none of these RPC servers answered for chain $CHAIN_ID: $RPC_LIST
Check your internet connection, or pass your own endpoint:  RPC=https://... bash scripts/sepolia_run.sh"

if [ -z "${DRY_RUN:-}" ]; then
  [ -f .env ] || stop "code/.env does not exist. Create it with one line:  PRIVATE_KEY=<your TEST wallet's private key>"
  # Notepad may add a byte-order mark or Windows line endings; either would break parsing of the
  # key, so remove them (the key itself is not changed or printed).
  sed -i '1s/^\xEF\xBB\xBF//; s/\r$//' .env
  grep -qE '^PRIVATE_KEY=(0x)?[0-9a-fA-F]{64}[[:space:]]*$' .env \
    || stop "code/.env must contain one line:  PRIVATE_KEY=<64 hexadecimal characters, with or without 0x>.
It is empty or in another format. (Its contents were not printed.)"
  WHO=""
  for try in 1 2 3; do
    WHO=$(forge script script/WhoAmI.s.sol --rpc-url "$RPC_URL" 2>&1)
    printf '%s\n' "$WHO" | grep -q 'balance (wei):' && break
    sleep 10; pick_rpc >/dev/null || true
  done
  CID=$(printf '%s\n' "$WHO" | grep -oE 'chain id: [0-9]+' | grep -oE '[0-9]+$')
  ADDR=$(printf '%s\n' "$WHO" | grep -oE 'address: +0x[0-9a-fA-F]{40}' | grep -oE '0x[0-9a-fA-F]{40}')
  BAL=$(printf '%s\n' "$WHO" | grep -oE 'balance \(wei\): [0-9]+' | grep -oE '[0-9]+$')
  [ -n "$BAL" ] || stop "could not read the wallet through $RPC_URL. Check your internet connection and try again."
  [ "$CID" = "$CHAIN_ID" ] || stop "$RPC_URL is chain $CID, expected $CHAIN_ID (Sepolia). Refusing to continue."
  echo "wallet $ADDR on chain $CID has $(node -e "console.log((Number(BigInt('$BAL'))/1e18).toFixed(4))") ETH"
  node -e "process.exit(BigInt('$BAL') >= BigInt('$MIN_BALANCE_WEI') ? 0 : 1)" \
    || stop "the wallet $ADDR needs at least 0.05 Sepolia ETH. Get some from a Sepolia faucet and re-run."
fi

# ------------------------------------------------------------------ fresh start
# Archive the previous run on this chain: its logs, its broadcast records and its deployment. A
# re-run reuses nothing, so a half-finished earlier run (e.g. a registry slot already taken) cannot
# break this one, and the gas report covers this run only.
TS=$(date +%s)
ARCHIVE="evidence/previous-runs/$P-$TS"
if ls evidence/logs/$P-*.log >/dev/null 2>&1 || [ -f "deployments/$CHAIN_ID.json" ]; then
  mkdir -p "$ARCHIVE"
  mv evidence/logs/$P-*.log "$ARCHIVE"/ 2>/dev/null
  mv evidence/captures/$P-*.png "$ARCHIVE"/ 2>/dev/null
  [ -f "deployments/$CHAIN_ID.json" ] && mv "deployments/$CHAIN_ID.json" "$ARCHIVE/deployment.json"
  for d in broadcast/*/"$CHAIN_ID"; do
    [ -d "$d" ] && mkdir -p "$ARCHIVE/$(dirname "$d")" && mv "$d" "$ARCHIVE/$d"
  done
  echo "previous run archived in $ARCHIVE"
fi

# Aggregated liveness: the registry is deployed only when these are set. The empty enrollment root
# is derived from the circuit's tree depth, so it is computed rather than pasted.
export AGG_VERIFIER="${AGG_VERIFIER:-AggVerifier_N8_m40_w1}"
export AGG_WORDS="${AGG_WORDS:-1}"
export AGG_CAPACITY="${AGG_CAPACITY:-8}"
# Shortest epoch and vault lookback. Every vault's lifeProof + grace + 15 min must stay below
# AGG_LOOKBACK * AGG_MIN_EPOCH (100 min here; the demo vaults need at most 80).
export AGG_MIN_EPOCH="${AGG_MIN_EPOCH:-300}"
export AGG_LOOKBACK="${AGG_LOOKBACK:-20}"
export AGG_EMPTY_ROOT="${AGG_EMPTY_ROOT:-$(node -e "
import('./js/lib/registry.mjs').then(async (m) => {
  const t = await m.PoseidonTree.create();
  console.log(t.emptyRoot.toString());
  process.exit(0);
});")}"
[ -n "$AGG_EMPTY_ROOT" ] || stop "could not compute the empty enrollment root (node js/lib/registry.mjs)."

# ------------------------------------------------------------------ the lifecycle
[ -z "${DRY_RUN:-}" ] && ev $P-00-whoami forge script script/WhoAmI.s.sol $R
ev $P-01-deploy forge script script/Deploy.s.sol $F
ev $P-02-prepare node js/demo.mjs prepare --test-issuer --also-credential "$REAL_CRED"
ev $P-03-create forge script script/Demo.s.sol --sig "create()" $F
ev $P-04-heartbeat forge script script/Demo.s.sol --sig "heartbeat()" $F

# Aggregated proof of life, before the owner ever proves life themselves. The vault claims an
# enrollment slot once; an epoch is then submitted by the registry's aggregator. Compare
# 04c with 04e: the vault's presence moves forward on the strength of a transaction the vault did
# not send, and that same transaction would have covered the whole cohort at the same cost.
AGG_AFTER=$(rpc_read cast call "$(vault)" "lastLifeProof()(uint40)")
need "the vault's lastLifeProof" "$AGG_AFTER"
wait_chain $(( AGG_AFTER + AGG_MIN_EPOCH ))   # the epoch must be at least AGG_MIN_EPOCH long
AGG_NOW=$(chain_now)
export AGG_AFTER AGG_NOW
ev $P-04a-agg-prepare node js/demo.mjs agg
ev $P-04b-agg-enroll forge script script/DemoAgg.s.sol --sig "enroll()" $F
ev $P-04c-agg-status-before forge script script/DemoAgg.s.sol --sig "status()" $R
ev $P-04d-agg-epoch forge script script/DemoAgg.s.sol --sig "epoch()" $F
ev $P-04e-agg-status-after forge script script/DemoAgg.s.sol --sig "status()" $R

LIFE_NOW=$(chain_now)
export LIFE_NOW
ev $P-05-life-proof node js/demo.mjs life --test-issuer
ev $P-06-proveLife forge script script/Demo.s.sol --sig "proveLife()" $F
ev $P-07-withdraw forge script script/Demo.s.sol --sig "withdraw()" $F
ev $P-08-addRealBinding forge script script/Demo.s.sol --sig "addRealBinding()" $F

# The owner's real (December 2025) Billions credential proves fine, but the live vault must reject
# it as stale: simulated against Sepolia state only, nothing is broadcast.
cp demo/life-proof.json demo/life-proof.testissuer.json
ev $P-09-real-credential-proof node js/demo.mjs life --credential "$REAL_CRED"
ev $P-10-stale-credential-rejected forge script script/Demo.s.sol --sig "proveLife()" $R
cp demo/life-proof.testissuer.json demo/life-proof.json

CLAIMABLE=$(rpc_read cast call "$(vault)" "claimableAt()(uint256)")
need "the vault's claimableAt" "$CLAIMABLE"
ev $P-11-status-alive forge script script/Demo.s.sol --sig "status()" $R
wait_chain "$CLAIMABLE"   # no transaction is needed for the vault to become claimable
ev $P-12-status-claimable forge script script/Demo.s.sol --sig "status()" $R
ev $P-13-age-proofs node js/demo.mjs ages
ev $P-14-claimAll forge script script/Demo.s.sol --sig "claimAll()" $F

TRANCHE=$(python -c "import json; print(json.load(open('demo/will.json'))['leaves'][2]['notBefore'])")
need "the tranche time" "$TRANCHE"
wait_chain "$TRANCHE"
ev $P-15-claim-tranche forge script script/Demo.s.sol --sig "claimAll()" $F

wait_chain $(( CLAIMABLE + 30 * 60 ))
ev $P-16-sweep forge script script/Demo.s.sol --sig "sweep()" $F
ev $P-17-status-settled forge script script/Demo.s.sol --sig "status()" $R
ev $P-18-report node js/demo.mjs report --rpc @RPC@

echo
echo "Sepolia run complete: all $STEPS steps finished as expected (step 10 was correctly rejected)."
echo "Logs: evidence/logs/$P-*.log   Gas report: reports/$([ -n "${DRY_RUN:-}" ] && echo anvil || echo sepolia).json"
