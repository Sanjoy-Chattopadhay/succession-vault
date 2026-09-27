"""Generate latex/numbers.tex from the experiment outputs in reports/, so that every number in the
paper that comes from a measurement is traceable to a result file.

Usage: python scripts/paper_numbers.py
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT.parent / "latex" / "numbers.tex"


def load(name):
    p = ROOT / "reports" / name
    return json.loads(p.read_text()) if p.exists() else None


def gas(x):
    return f"{int(x):,}"


def sec(ms):
    return f"{ms / 1000:.2f}\\,s" if ms >= 1000 else f"{ms:.0f}\\,ms"


macros = {}

ps = load("proof-systems.json")
if ps:
    by = {(r["system"], r["circuit"]): r for r in ps["results"]}

    def prove(k):
        r = by.get(k)
        if not r:
            return "n/a"
        m, s = r["proveMs"]["mean"], r["proveMs"]["sd"]
        if m >= 10_000:
            return f"${m / 1000:.1f}\\pm{s / 1000:.1f}$\\,s"
        num = f"{m:,.0f}".replace(",", "{,}")
        return f"${num}\\pm{s:.0f}$\\,ms"

    macros["PLGgs"] = prove(("groth16", "liveness"))
    macros["PLPLs"] = prove(("plonk", "liveness"))
    macros["AGGs"] = prove(("groth16", "age"))
    macros["AGPLs"] = prove(("plonk", "age"))
    macros["AGFFs"] = prove(("fflonk", "age"))
    if ("plonk", "liveness") in by and ("groth16", "liveness") in by:
        ratio = by[("plonk", "liveness")]["proveMs"]["mean"] / by[("groth16", "liveness")]["proveMs"]["mean"]
        macros["PLPLratio"] = f"{ratio:.0f}$\\times$"

vg = load("gas-proofsys.json")
if vg:
    macros["PLPLg"] = gas(vg["plonk_liveness"])
    macros["AGPLg"] = gas(vg["plonk_age"])
    macros["AGFFg"] = gas(vg["fflonk_age"])

sc = load("gas-scaling.json")
if sc:
    claims = [v["claimERC20_firstOfPool"] for v in sc.values() if v["heirs"] >= 2]
    macros["FCmin"], macros["FCmax"] = gas(min(claims)), gas(max(claims))

dep = load("deploy-gas.json")
if dep:
    macros["DEPimpl"] = gas(dep["BequestVault"])
    macros["DEPfac"] = gas(dep["BequestFactory"])

def k(x):
    return f"{x / 1000:.1f}k"


ops = load("gas-ops.json")
if ops:
    names = {
        "GasCreate": "createVault", "GasDepEth": "depositETH", "GasDepToken": "depositERC20_transfer",
        "GasHeartbeat": "heartbeat", "GasProveLife": "proveLife", "GasWithdraw": "withdrawETH",
        "GasSetRoot": "setAllocationRoot", "GasClaimEthFirst": "claimETH_first", "GasClaimEth": "claimETH",
        "GasClaimTokNew": "claimERC20_firstOfPool", "GasClaimTok": "claimERC20", "GasClaimNFT": "claimERC721",
        "GasClaimMulti": "claimERC1155", "GasClaimAge": "claimWithAgeProof", "GasSweepTok": "sweepERC20",
        "GasSweepEth": "sweepETH",
    }
    for m, key in names.items():
        macros[m] = gas(ops[key])
    for m in ("GasCreate", "GasHeartbeat", "GasProveLife"):
        macros[m + "K"] = k(ops[names[m]])
    macros["GasLifetimeTenYears"] = f"{(ops['createVault'] + 120 * ops['heartbeat'] + 10 * ops['proveLife']) / 1e6:.1f}M"

ver = load("gas-verifiers.json")
if ver:
    macros["GasVerify"] = gas(ver["verifyLivenessProof"])
    macros["GasVerifyK"] = k(ver["verifyLivenessProof"])

if dep:
    macros["DEPverifiers"] = gas(dep["LivenessVerifier"] + dep["AgeVerifier"])

if sc:
    rows = sorted((v["heirs"], v["claimERC20_firstOfPool"]) for v in sc.values() if v["heirs"] >= 2)
    import math
    slope = (rows[-1][1] - rows[0][1]) / (math.log2(rows[-1][0]) - math.log2(rows[0][0]))
    macros["ClaimPerDoubling"] = f"{slope:.0f}"

cmp_ = load("comparison.json")
if cmp_:
    rows = sorted(cmp_.values(), key=lambda r: r["heirs"])
    ra = [r["legacy"]["total"] / r["bequest"]["total"] for r in rows]
    rn = [r["legacy"]["total"] / r["bequestNoAgeGate"]["total"] for r in rows]
    macros["CmpRatioAge"] = f"{min(ra):.1f}--{max(ra):.1f}$\\times$"
    macros["CmpRatioNoAge"] = f"{min(rn):.1f}--{max(rn):.1f}$\\times$"
    a, b = rows[-2], rows[-1]
    dn = b["heirs"] - a["heirs"]
    macros["CmpMargNoAge"] = k((b["bequestNoAgeGate"]["total"] - a["bequestNoAgeGate"]["total"]) / dn)
    macros["CmpMargAge"] = k((b["bequest"]["total"] - a["bequest"]["total"]) / dn)
    macros["CmpMargLegacy"] = k((b["legacy"]["total"] - a["legacy"]["total"]) / dn)
    macros["CmpSetup"] = k(b["bequest"]["setup"])
    macros["CmpLegacyFixedTx"] = str(rows[0]["legacy"]["transactions"] - 2 * rows[0]["heirs"])
    macros["CmpTxBequest"] = str(b["bequest"]["transactions"])
    macros["CmpTxLegacy"] = str(b["legacy"]["transactions"])
    macros["CmpMaxN"] = str(b["heirs"])
    dat = ROOT.parent / "latex" / "data"
    dat.mkdir(exist_ok=True)
    with open(dat / "comparison.dat", "w") as f:
        f.write("n legacy bequest noage\n")
        for r in rows:
            f.write(f"{r['heirs']} {r['legacy']['total'] / 1e6:.6f} {r['bequest']['total'] / 1e6:.6f} {r['bequestNoAgeGate']['total'] / 1e6:.6f}\n")

# ---------------------------------------------------------------- aggregated proof of life
agg_gas = load("gas-aggregation.json")
agg_prove = load("aggregation.json")
if agg_gas:
    rows = agg_gas["cohorts"]
    # Cohorts that differ only in how many principals one proof covers (same presence width):
    # their epoch gas is what shows that on-chain cost does not depend on cohort size.
    same_width = sorted(
        ((v["cohortSize"], v["epochGasCold"]) for v in rows.values() if v["presenceWords"] == 1)
    )
    macros["AggEpochGas"] = gas(same_width[0][1])
    macros["AggEpochGasSpread"] = gas(max(g for _, g in same_width) - min(g for _, g in same_width))
    macros["AggCohortMax"] = str(max(n for n, _ in same_width))

    # Presence-width sweep: the cost of an epoch covering w * 248 enrolled principals.
    width = sorted(
        (v["slotsCoveredByWords"], v["epochGasWarm"], v["epochGasPerCoveredSlot"])
        for v in rows.values() if v["cohortSize"] == 1
    )
    macros["AggSlotsMax"] = f"{width[-1][0]:,}"
    macros["AggPerSlotMin"] = gas(width[-1][2])
    macros["AggPerSlotAtStart"] = gas(width[0][2])
    if len(width) >= 2:
        (n0, g0, _), (n1, g1, _) = width[-2], width[-1]
        macros["AggMarginal"] = f"{(g1 - g0) / (n1 - n0):.1f}"
    # Every cell of the width rows of the aggregation table (steady-state epoch gas, gas per
    # covered slot), so that no number in that table is typed by hand.
    names = {1: "One", 4: "Four", 16: "Sixteen", 32: "ThirtyTwo"}
    for key, v in rows.items():
        if "_m16_" in key and v["cohortSize"] == 1 and v["presenceWords"] in names:
            nm = names[v["presenceWords"]]
            macros[f"AggW{nm}Gas"] = gas(v["epochGasWarm"])
            macros[f"AggW{nm}Per"] = gas(v["epochGasPerCoveredSlot"])
    macros["AggEnroll"] = gas(next(iter(rows.values()))["enrollGas"])
    macros["AggSync"] = gas(next(iter(rows.values()))["syncFromRegistryGas"])

    dat = ROOT.parent / "latex" / "data"
    dat.mkdir(exist_ok=True)
    with open(dat / "aggregation.dat", "w") as f:
        f.write("slots epochgas pergas\n")
        for n, g, per in width:
            f.write(f"{n} {g} {per}\n")

    if ops:
        floor = ops["heartbeat"]
        solo = ops["proveLife"]
        per = width[-1][2]
        macros["AggFloor"] = gas(floor)
        macros["AggVsFloor"] = f"{floor / per:.0f}$\\times$"
        macros["AggVsSolo"] = f"{solo / per:.0f}$\\times$"
        # The duality that matters: one solo proof of life a year buys this many aggregated ones.
        per_year = solo / per
        macros["AggAttestPerYear"] = f"{per_year:,.0f}".replace(",", "{,}")
        hours = 365 * 24 / per_year
        macros["AggWindow"] = f"{hours:.1f}\\,hours" if hours >= 1 else f"{hours * 60:.0f}\\,minutes"
        # Cost-benefit table: a year of monthly attestations under each liveness signal.
        macros["CbHeartYear"] = gas(12 * floor)
        macros["CbProofYear"] = gas(12 * solo)
        macros["CbHybridYear"] = gas(11 * floor + solo)
        macros["CbAggYear"] = gas(12 * per)

# What reading presence costs a vault: best case (present in the latest epoch) and worst case
# (absent from all scanned epochs, which a silent principal's vault pays at its first claim).
read = load("gas-presence-read.json")
if read:
    macros["AggReadBest"] = gas(read["bestCaseGas"])
    macros["AggReadWorst"] = gas(read["worstCaseGas"])
    macros["AggReadPerEpoch"] = gas(read["gasPerScannedEpoch"])
    macros["AggReadLookback"] = str(read["lookbackEpochs"])

if agg_prove:
    ms = [m for m in agg_prove["measurements"] if m["words"] == 1 and m["mtLevels"] == 40]
    if ms:
        biggest = max(ms, key=lambda m: m["n"])
        macros["AggProveMsPerPrincipal"] = f"{biggest['provingMsPerPrincipal']:,}"
        macros["AggProveMsAtMax"] = sec(biggest["provingMs"])
        macros["AggProveNMax"] = str(biggest["n"])
    flat = [m for m in agg_prove["measurements"] if m["n"] == 1 and m["mtLevels"] == 16]
    for m in flat:
        nm = {1: "One", 4: "Four", 16: "Sixteen", 32: "ThirtyTwo"}.get(m["words"])
        if nm:
            macros[f"AggW{nm}Ms"] = str(m["provingMs"])
    if flat:
        lo, hi = min(m["provingMs"] for m in flat), max(m["provingMs"] for m in flat)
        macros["AggProveFlatLo"], macros["AggProveFlatHi"] = f"{lo}", f"{hi}"
        macros["AggWidthMaxSignals"] = str(max(m["publicSignals"] for m in flat))

# ---------------------------------------------------------------- merklization-depth ablation
dep_abl = load("depth-ablation.json")
if dep_abl:
    v = {x["levels"]: x for x in dep_abl["variants"]}
    macros["DepthUsed"] = str(dep_abl["credentialDepth"])
    macros["DepthFullMs"] = f"{v[40]['proveMs']['mean']:.0f}"
    macros["DepthShallowMs"] = f"{v[16]['proveMs']['mean']:.0f}"
    macros["DepthSaving"] = f"{(1 - v[16]['proveMs']['mean'] / v[40]['proveMs']['mean']) * 100:.0f}\\%"

# ---------------------------------------------------------------- alternative presence signals
# Standalone probe (experiments/presence-probe), measured with forge --isolate; see evidence 32.
probe_log = ROOT / "evidence" / "logs" / "32-presence-probe-gas.log"
if probe_log.exists():
    import re
    t = probe_log.read_text(encoding="utf-8", errors="ignore")
    pk = int(re.search(r"provePresence \(WebAuthn \+ P256VERIFY\): (\d+)", t).group(1))
    lazy = int(re.search(r"proveLifeLazy \(later\): (\d+)", t).group(1))
    macros["GasPasskey"] = gas(pk)
    macros["GasLazy"] = gas(lazy)
    macros["CbPasskeyYear"] = gas(12 * pk)
    macros["CbLazyYear"] = gas(12 * lazy)

# ---------------------------------------------------------------- always-on key holder (agent)
ag = load("agent-heartbeats.json")
if ag:
    checks = ("statusMatchesTheory", "deadlineNeverExceedsCap", "allHeartbeatsSucceeded")
    failed = [c for c in checks if not ag.get(c)]
    if failed:
        raise SystemExit(f"agent experiment checks failed: {failed}; not writing numbers")
    macros["AgentBeats"] = str(len(ag["heartbeats"]))
    macros["AgentGas"] = gas(ag["gasPerHeartbeat"][0])
    macros["AgentFrozen"] = str(ag["deadlineFrozenAfterSec"])
    macros["AgentAfterFreeze"] = str(ag["heartbeatsAfterFreeze"])

# ---------------------------------------------------------------- live Sepolia run and attacks
sep = load("sepolia-summary.json")
if sep:
    lc, at = sep["lifecycle"], sep["attacks"]
    macros["SepTx"] = str(lc["transactions"])
    macros["SepReverted"] = str(lc["reverted"])
    macros["SepMaxDev"] = f"{lc['maxDeviationPct']:.1f}\\%"
    macros["SepRegistryRead"] = f"{min(v['extra'] for v in lc['registryRead'].values()) / 1000:.1f}--{max(v['extra'] for v in lc['registryRead'].values()) / 1000:.1f}k"
    macros["SepWithdraw"] = gas(lc["registryRead"]["withdraw"]["live"])
    macros["SepFirstClaim"] = gas(lc["registryRead"]["firstClaim"]["live"])
    macros["SepEpoch"] = gas(lc["comparable"]["submitEpoch"]["live"])
    macros["SepProveLife"] = gas(lc["comparable"]["proveLife"]["live"])
    macros["AtkOffRejected"] = str(at["offchainEditsRejected"])
    macros["AtkOffTotal"] = str(at["offchainEditsTotal"])
    macros["AtkOnRejected"] = str(at["onchainRejected"])

# ---------------------------------------------------------------- j-of-m issuer threshold
thr = load("gas-threshold.json")
if thr:
    macros["GasProveLifeMultiTwo"] = gas(thr["proveLifeMulti_2"])
    macros["GasSetThreshold"] = gas(thr["setBindingThreshold_new"])
thr_live = load("threshold-live.json")
if thr_live:
    macros["ThrLiveAloneRejected"] = str(thr_live["aloneRejected"])
    macros["ThrLiveMultiGas"] = gas(thr_live["multiGas"][0]) if thr_live.get("multiGas") else "n/a"

# ---------------------------------------------------------------- bounded posthumous-key power
bs = load("bound-sweep.json")
if bs:
    def dur(sec):
        if sec % 86400 and sec >= 86400:
            return f"{sec / 86400:.1f}\\,d"
        for unit, n in (("d", 86400), ("h", 3600), ("min", 60)):
            if sec % n == 0:
                return f"{sec // n}\\,{unit}"
        return f"{sec}\\,s"
    rows = sorted(bs.values(), key=lambda r: r["lifeProofSec"])
    if not all(r["maxDeadlineAfterTStarSec"] <= r["lifeProofSec"] and r["notClaimableAtBound"]
               and r["claimableAtBoundPlus1s"] for r in rows):
        raise SystemExit("bound sweep: a setting exceeded the theoretical bound; not writing numbers")
    macros["BoundSettings"] = str(len(rows))
    macros["BoundBeatsTotal"] = str(sum(r["heartbeatsAccepted"] for r in rows))
    # Table rows as one macro (an \input inside a tabular breaks \bottomrule).
    macros["BoundRows"] = " ".join(
        f"{dur(r['heartbeatSec'])} & {dur(r['lifeProofSec'])} & {dur(r['graceSec'])} & "
        f"{r['heartbeatsAccepted']} & {dur(r['maxDeadlineAfterTStarSec'])} & "
        f"{dur(r['theoreticalClaimableAfterSec'])}\\,+\\,1\\,s & {dur(r['conventionalDeadlineAfterTStarSec'])}\\\\"
        for r in rows)

# ---------------------------------------------------------------- security for a fixed budget
if ops and agg_gas:
    budget = 12 * ops["heartbeat"]  # a year of monthly ECDSA heartbeats
    per = width[-1][2]
    macros["BudgetYearGas"] = gas(budget)
    months = 12 * ops["proveLife"] / budget
    macros["BudgetIntervalSolo"] = f"{months:.1f}\\,months"
    hours = 365 * 24 * per / budget
    macros["BudgetIntervalAgg"] = f"{hours:.1f}\\,hours" if hours >= 1 else f"{hours * 60:.0f}\\,minutes"

# ---------------------------------------------------------------- symbolic verification (Halmos)
hm = load("halmos.json")
if hm:
    if hm["propertiesProved"] != hm["propertiesTotal"] or hm["negativeControlsRefuted"] != hm["negativeControlsTotal"]:
        print("WARNING: not every Halmos property passed or not every negative control was refuted")
    macros["HalmosProved"] = str(hm["propertiesProved"])
    macros["HalmosTotal"] = str(hm["propertiesTotal"])
    macros["HalmosNeg"] = str(hm["negativeControlsRefuted"])
    macros["HalmosVersion"] = hm["tool"].split()[-1] if hm["tool"] else "n/a"

# ---------------------------------------------------------------- test suite
ft = load("forge-tests.json")
if ft:
    macros["TestsTotal"] = str(ft["total"])
    macros["TestsVault"] = str(ft["suites"].get("BequestVaultTest", 0))
    macros["TestsRegistry"] = str(ft["suites"].get("RegistryTest", 0))
    macros["TestsThreshold"] = str(ft["suites"].get("ThresholdTest", 0))
    macros["TestsInvariants"] = str(ft["suites"].get("InvariantTest", 0))

loc = sum(
    1
    for f in ["src/BequestVault.sol", "src/BequestFactory.sol", "src/LivenessRegistry.sol",
              "src/interfaces/IGroth16Verifier.sol", "src/interfaces/ILivenessRegistry.sol"]
    for line in (ROOT / f).read_text(encoding="utf-8").splitlines()
    if line.strip() and not line.strip().startswith("//")
)
macros["LOCSOL"] = str(loc)

lines = ["% Generated by code/scripts/paper_numbers.py from code/reports/*.json. Do not edit by hand."]
for k, v in sorted(macros.items()):
    lines.append(f"\\newcommand{{\\{k}}}{{{v}}}")
OUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(f"wrote {OUT} with {len(macros)} macros:")
for k, v in sorted(macros.items()):
    print(f"  {k:10} {v}")
