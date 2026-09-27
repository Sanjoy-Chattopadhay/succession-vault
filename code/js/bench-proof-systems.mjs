// Groth16 vs PLONK vs FFLONK on the same circuits (snarkjs 0.7.5).
//   node --max-old-space-size=14000 js/bench-proof-systems.mjs [runs]
// Writes reports/proof-systems.json and test/fixtures/proofsys.json (calldata for the gas test).
import fs from "node:fs";
import os from "node:os";
import * as snarkjs from "snarkjs";
import { shutdown } from "./lib/zk.mjs";

const RUNS = Number(process.argv[2] ?? 10);
const inputs = {
  liveness: JSON.parse(fs.readFileSync("web/liveness-input.json", "utf8")),
  age: JSON.parse(fs.readFileSync("web/age-input.json", "utf8")),
};
// The slow PLONK proof-of-life configuration runs last, after the calldata export of every
// system has been exercised on the small age circuit.
const configs = [
  { system: "groth16", circuit: "liveness", zkey: "zk/build/liveness.zkey", vkey: "zk/build/liveness_vkey.json", setup: "circuit-specific (MPC phase 2)" },
  { system: "groth16", circuit: "age", zkey: "zk/build/age.zkey", vkey: "zk/build/age_vkey.json", setup: "circuit-specific (MPC phase 2)" },
  { system: "plonk", circuit: "age", zkey: "zk/plonk/age_plonk.zkey", vkey: "zk/plonk/age_plonk_vkey.json", setup: "universal" },
  { system: "fflonk", circuit: "age", zkey: "zk/plonk/age_fflonk.zkey", vkey: "zk/plonk/age_fflonk_vkey.json", setup: "universal" },
  { system: "plonk", circuit: "liveness", zkey: "zk/plonk/liveness_plonk.zkey", vkey: "zk/plonk/liveness_plonk_vkey.json", setup: "universal" },
];
const stats = (xs) => {
  const m = xs.reduce((a, b) => a + b, 0) / xs.length;
  const sd = Math.sqrt(xs.reduce((a, b) => a + (b - m) ** 2, 0) / Math.max(1, xs.length - 1));
  return { mean: +m.toFixed(1), sd: +sd.toFixed(1), min: +Math.min(...xs).toFixed(1), max: +Math.max(...xs).toFixed(1) };
};

// snarkjs formats calldata differently per system: PLONK concatenates "[proof][pub]" without a
// comma and FFLONK prints unquoted hex (and takes (publicSignals, proof)). Normalize to JSON.
function parseCalldata(str) {
  const fixed = str.replace(/\]\s*\[/g, "],[").replace(/(?<!")0x[0-9a-fA-F]+/g, (m) => `"${m}"`);
  return JSON.parse(`[${fixed}]`);
}
const RUNS_OVERRIDE = { "plonk_liveness": Number(process.env.PLONK_LIVENESS_RUNS ?? 5) };
const saved = fs.existsSync("reports/proof-systems.json") ? JSON.parse(fs.readFileSync("reports/proof-systems.json", "utf8")) : { results: [] };
const results = saved.results.filter((r) => !process.argv.includes(`--redo=${r.system}_${r.circuit}`));
const fixtures = fs.existsSync("test/fixtures/proofsys.json") ? JSON.parse(fs.readFileSync("test/fixtures/proofsys.json", "utf8")) : {};
const machine = { cpu: os.cpus()[0].model, threads: os.cpus().length, memGB: Math.round(os.totalmem() / 2 ** 30), node: process.version };
for (const cfg of configs) {
  const key = `${cfg.system}_${cfg.circuit}`;
  if (results.some((r) => `${r.system}_${r.circuit}` === key)) { console.log(`${key}: already measured, skipping`); continue; }
  const runs = RUNS_OVERRIDE[key] ?? RUNS;
  const lib = snarkjs[cfg.system];
  const wasm = `zk/build/${cfg.circuit}_js/${cfg.circuit}.wasm`;
  const vkey = JSON.parse(fs.readFileSync(cfg.vkey, "utf8"));
  const prove = [], verify = [];
  let last;
  for (let i = -1; i < runs; i++) {
    let t = performance.now();
    last = await lib.fullProve(inputs[cfg.circuit], wasm, cfg.zkey);
    const p = performance.now() - t;
    t = performance.now();
    const ok = await lib.verify(vkey, last.publicSignals, last.proof);
    const v = performance.now() - t;
    if (!ok) throw new Error(`${cfg.system}/${cfg.circuit}: proof does not verify`);
    if (i >= 0) { prove.push(p); verify.push(v); }
  }
  const raw = cfg.system === "fflonk"
    ? await lib.exportSolidityCallData(last.publicSignals, last.proof)
    : await lib.exportSolidityCallData(last.proof, last.publicSignals);
  const calldata = parseCalldata(raw);
  const proofWords = calldata.slice(0, -1).flat(3).length;
  fixtures[`${cfg.system}_${cfg.circuit}`] = { proof: calldata.slice(0, -1), pub: calldata.at(-1) };
  const r = {
    system: cfg.system, circuit: cfg.circuit, setup: cfg.setup, runs,
    proveMs: stats(prove), verifyMs: stats(verify),
    proofBytes: proofWords * 32, provingKeyMB: +(fs.statSync(cfg.zkey).size / 2 ** 20).toFixed(1),
  };
  results.push(r);
  console.log(`${cfg.system.padEnd(8)} ${cfg.circuit.padEnd(9)} prove ${r.proveMs.mean} ± ${r.proveMs.sd} ms (${runs} runs) | verify ${r.verifyMs.mean} ms | proof ${r.proofBytes} B | pk ${r.provingKeyMB} MB`);
  // Save after every configuration so that a late failure cannot lose finished measurements.
  fs.writeFileSync("reports/proof-systems.json", JSON.stringify({ machine, results }, null, 2));
  fs.writeFileSync("test/fixtures/proofsys.json", JSON.stringify(fixtures, null, 2));
}
await shutdown();
process.exit(0);
