#!/usr/bin/env bash
# Deployment gas of every contract, from real receipts on a throwaway local Anvil chain.
# -> reports/deploy-gas.json  (contract name -> gasUsed)
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$PATH:$HOME/.foundry/bin"
PORT=8546
anvil --port $PORT --silent &
ANVIL=$!
trap 'kill $ANVIL 2>/dev/null || true' EXIT
until cast block-number --rpc-url http://127.0.0.1:$PORT >/dev/null 2>&1; do sleep 0.2; done
rm -rf broadcast/Deploy.s.sol/31337
env -u PRIVATE_KEY forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:$PORT \
  --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --broadcast --slow > /dev/null
python - <<'EOF'
import json, urllib.request
run = json.load(open("broadcast/Deploy.s.sol/31337/run-latest.json"))
def rpc(method, params):
    req = urllib.request.Request("http://127.0.0.1:8546", json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(), {"content-type": "application/json"})
    return json.load(urllib.request.urlopen(req))["result"]
by_nonce = {int(t["transaction"]["nonce"], 16): t["contractName"] for t in run["transactions"]}
out = {}
for rc in run["receipts"]:
    tx = rpc("eth_getTransactionByHash", [rc["transactionHash"]])
    out[by_nonce[int(tx["nonce"], 16)]] = int(rc["gasUsed"], 16)
json.dump(out, open("reports/deploy-gas.json", "w"), indent=2)
print(json.dumps(out, indent=2))
EOF
rm -rf broadcast/Deploy.s.sol/31337 deployments/31337.json
