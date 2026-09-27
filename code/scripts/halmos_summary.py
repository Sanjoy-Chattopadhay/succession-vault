"""Summarise the per-check Halmos logs (scripts/halmos.sh) into reports/halmos.json."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOGS = ROOT / "evidence" / "logs"
ansi = re.compile(r"\x1b\[[0-9;]*m")
line = re.compile(r"\[(PASS|FAIL|TIMEOUT|ERROR)\]\s+(\w+)\(.*?\)\s+\((.*)\)")

version = (LOGS / "halmos-version.log").read_text(errors="replace").strip() if (LOGS / "halmos-version.log").exists() else ""
checks = {}
for log in sorted(LOGS.glob("halmos-check_*.log")):
    text = ansi.sub("", log.read_text(errors="replace"))
    m = None
    for m in line.finditer(text):
        pass
    wall = re.search(r"# wall seconds: (\d+)", text)
    if not m:
        checks[log.stem.removeprefix("halmos-")] = {"result": "NO RESULT", "wallSeconds": int(wall.group(1)) if wall else None}
        continue
    detail = dict(kv.split(": ", 1) for kv in m.group(3).split(", ") if ": " in kv)
    checks[m.group(2)] = {
        "result": m.group(1),
        "paths": int(detail["paths"]) if detail.get("paths", "").isdigit() else detail.get("paths"),
        "time": detail.get("time"),
        "wallSeconds": int(wall.group(1)) if wall else None,
        "negativeControl": m.group(2).startswith("check_NEG_"),
    }

props = {k: v for k, v in checks.items() if not v.get("negativeControl")}
neg = {k: v for k, v in checks.items() if v.get("negativeControl")}
out = {
    "tool": version,
    "generatedBy": "scripts/halmos.sh + scripts/halmos_summary.py",
    "checks": checks,
    "propertiesProved": sum(v["result"] == "PASS" for v in props.values()),
    "propertiesTotal": len(props),
    # A negative control must FAIL: Halmos has to find a counterexample to a false property.
    "negativeControlsRefuted": sum(v["result"] == "FAIL" for v in neg.values()),
    "negativeControlsTotal": len(neg),
}
(ROOT / "reports" / "halmos.json").write_text(json.dumps(out, indent=2))
for k, v in checks.items():
    print(f"{v['result']:9} {k}  ({v.get('paths')} paths, {v.get('time')})")
print(f"properties proved: {out['propertiesProved']}/{out['propertiesTotal']}; "
      f"negative controls refuted: {out['negativeControlsRefuted']}/{out['negativeControlsTotal']}")
