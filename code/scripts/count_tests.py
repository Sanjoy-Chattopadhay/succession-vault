"""Run the Foundry suite once and record how many tests each suite has and whether all passed.
   python scripts/count_tests.py   ->   reports/forge-tests.json"""
import json
import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
forge = str(Path.home() / ".foundry" / "bin" / ("forge.exe" if os.name == "nt" else "forge"))
out = subprocess.run([forge, "test"], cwd=ROOT, capture_output=True, text=True, encoding="utf-8").stdout
suites = {}
for m in re.finditer(r"Ran (\d+) tests? for test/[^:]+:(\w+)", out):
    suites[m.group(2)] = int(m.group(1))
summary = re.search(r"(\d+) tests passed, (\d+) failed, (\d+) skipped \((\d+) total tests\)", out)
report = {
    "command": "forge test",
    "suites": suites,
    "passed": int(summary.group(1)),
    "failed": int(summary.group(2)),
    "total": int(summary.group(4)),
}
(ROOT / "reports" / "forge-tests.json").write_text(json.dumps(report, indent=2))
(ROOT / "evidence" / "logs" / "forge-tests.log").write_text(out, encoding="utf-8")
print(json.dumps(report, indent=2))
