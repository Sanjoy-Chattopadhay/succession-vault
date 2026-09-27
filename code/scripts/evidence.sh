#!/usr/bin/env bash
# Run one command, keep its full output as evidence and render it as an image.
#   bash scripts/evidence.sh <name> <command...>
# -> evidence/logs/<name>.log and evidence/captures/<name>.png
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="$PATH:$HOME/.foundry/bin"
name="$1"; shift
mkdir -p evidence/logs evidence/captures evidence/private
log="evidence/logs/$name.log"
{
  echo "# $(date -u '+%Y-%m-%d %H:%M:%S UTC')  |  $(uname -n)  |  $(pwd)"
  echo "\$ $*"
  echo
  "$@" 2>&1
  rc=$?
  echo
  echo "# exit code: $rc"
} | grep -v -E "^\s*(warning\[|note:|help:)|^\s+(│|╭|╰|├)|forge-lint|casting to" > "$log"
python scripts/render_log.py "$log" "evidence/captures/$name.png" 70 >/dev/null
tail -n 25 "$log"
