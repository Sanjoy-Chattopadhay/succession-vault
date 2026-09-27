// Summarises the always-on key-holder experiment (scripts/sepolia_extras.sh part 2):
// per heartbeat, the chain time, the vault's deadline and status, and the gas actually paid.
//   node js/agent-report.mjs [log-prefix]   -> reports/agent-heartbeats.json
import fs from "node:fs";
import path from "node:path";

const prefix = process.argv[2] ?? "sepolia";
const chainId = process.env.CHAIN_ID ?? "11155111";
const logs = "evidence/logs";

const field = (text, key) => {
  const m = text.match(new RegExp(`${key}\\s+(\\S+)`));
  return m ? m[1] : null;
};
const read = (name) => {
  const t = fs.readFileSync(path.join(logs, `${name}.log`), "utf8");
  return {
    status: field(t, "AGENT_STATUS"), now: Number(field(t, "AGENT_NOW")),
    tH: Number(field(t, "AGENT_TH")), tL: Number(field(t, "AGENT_TL")),
    deadline: Number(field(t, "AGENT_DEADLINE")), claimableAt: Number(field(t, "AGENT_CLAIMABLE_AT")),
  };
};

// Gas actually paid, from Foundry's broadcast receipts (one file per heartbeat run).
const dir = `broadcast/DemoAgent.s.sol/${chainId}`;
// Foundry names every timestamped run run-<ms>.json, so heartbeat runs are recognised by the
// function they called.
const receipts = fs.existsSync(dir)
  ? fs.readdirSync(dir).filter((f) => /^run-\d+\.json$/.test(f)).sort()
    .map((f) => JSON.parse(fs.readFileSync(path.join(dir, f), "utf8")))
    .filter((run) => (run.transactions ?? []).some((t) => (t.function ?? "").startsWith("heartbeat")))
    .flatMap((run) => run.receipts ?? [])
    .map((r) => ({ gasUsed: parseInt(r.gasUsed, 16), txStatus: r.status === "0x1" ? "ok" : "reverted", hash: r.transactionHash,
      block: parseInt(r.blockNumber, 16) }))
  : [];

const human = read(`${prefix}-32-agent-human-proves-life`);
const beats = fs.readdirSync(logs).filter((f) => f.startsWith(`${prefix}-33-agent-beat-`) && f.endsWith(".log")).sort()
  .map((f) => read(f.replace(/\.log$/, "")));
const final = read(`${prefix}-34-agent-final-status`);

const cap = human.tL + 8 * 60;
const expected = (now) => (now <= cap ? "Alive" : now <= cap + 120 ? "Grace" : "Claimable");
const frozen = beats.find((b) => b.deadline === cap);
const out = {
  generatedBy: "js/agent-report.mjs",
  timers: { heartbeatSec: 180, lifeProofSec: 480, graceSec: 120 },
  humanLastProofOfLife: human.tL,
  theoreticalCapOnDeadline: cap,
  theoreticalClaimableAt: cap + 120,
  heartbeats: beats.map((b, i) => ({ ...b, secondsAfterProof: b.now - human.tL, ...(receipts[i] ?? {}) })),
  final,
  maxDeadlineReached: Math.max(...beats.map((b) => b.deadline)),
  claimableWhileAgentActive: beats.some((b) => b.status === "Claimable") || final.status === "Claimable",
  // Every status read must match the theory: Alive up to tL + lifeProof, Grace up to + grace,
  // Claimable afterwards, however many heartbeats arrive.
  statusMatchesTheory: [...beats, final].every((b) => b.status === expected(b.now)),
  deadlineNeverExceedsCap: [...beats, final].every((b) => b.deadline <= cap),
  deadlineFrozenAfterSec: frozen ? frozen.now - human.tL : null,
  // The heartbeat that reaches the cap still moves the deadline; only the later ones cannot.
  heartbeatsAfterFreeze: frozen ? beats.filter((b) => b.now > frozen.now).length : 0,
  gasPerHeartbeat: [...new Set(receipts.map((r) => r.gasUsed))],
  allHeartbeatsSucceeded: receipts.length === beats.length && receipts.every((r) => r.txStatus === "ok"),
};
fs.writeFileSync("reports/agent-heartbeats.json", JSON.stringify(out, null, 2));
console.table(out.heartbeats.map((b) => ({ "+s": b.secondsAfterProof, status: b.status, deadline: b.deadline, gas: b.gasUsed })));
console.log(`human's proof at ${human.tL}; deadline cap tL+ΔL = ${cap}; max deadline reached ${out.maxDeadlineReached}; final status ${final.status}`);
