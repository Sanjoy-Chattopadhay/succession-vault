// Proving cost of the liveness circuit as a function of its Merkle depth, on a real credential:
//   node js/bench-depth.mjs <credential.json> <variants.json> [runs]
// variants.json: [{ "levels": 40, "wasm": "...", "zkey": "...", "vkey": "..." }, ...]
// Runs the variants interleaved so that clock drift affects all of them equally.
import fs from "node:fs";
import * as snarkjs from "snarkjs";
import { loadCredential, extractLivenessWitness } from "./lib/credential.mjs";
import { shutdown } from "./lib/zk.mjs";

const [credFile, variantsFile, runsArg] = process.argv.slice(2);
const RUNS = Number(runsArg ?? 10);
const variants = JSON.parse(fs.readFileSync(variantsFile, "utf8"));
const didSalt = BigInt(fs.readFileSync("fixtures/private/did-salt.txt", "utf8").trim());
const w = await extractLivenessWitness(loadCredential(credFile));
const input = (levels) => ({
  claim: w.slots.map(String), issuerAx: w.key.Ax.toString(), issuerAy: w.key.Ay.toString(),
  sigR8x: w.sig.R8x.toString(), sigR8y: w.sig.R8y.toString(), sigS: w.sig.S.toString(),
  livenessTimestamp: w.field.value.toString(), tsSiblings: w.field.siblings.slice(0, levels).map(String),
  didSalt: didSalt.toString(),
});
const mean = (xs) => +(xs.reduce((a, b) => a + b, 0) / xs.length).toFixed(1);
const sd = (xs) => { const m = mean(xs); return +Math.sqrt(xs.reduce((a, b) => a + (b - m) ** 2, 0) / (xs.length - 1)).toFixed(1); };

const res = variants.map((v) => ({ ...v, witness: [], prove: [], vkeyJson: JSON.parse(fs.readFileSync(v.vkey, "utf8")) }));
for (let i = -1; i < RUNS; i++) {
  for (const v of res) {
    const wtns = { type: "mem" };
    let t = performance.now();
    await snarkjs.wtns.calculate(input(v.levels), v.wasm, wtns);
    const tw = performance.now() - t;
    t = performance.now();
    const { proof, publicSignals } = await snarkjs.groth16.prove(v.zkey, wtns);
    const tp = performance.now() - t;
    if (!(await snarkjs.groth16.verify(v.vkeyJson, publicSignals, proof))) throw new Error(`levels ${v.levels}: proof invalid`);
    if (i >= 0) { v.witness.push(tw); v.prove.push(tp); }
  }
}
const out = [];
for (const v of res) {
  const info = await snarkjs.r1cs.info(v.r1cs);
  const row = {
    levels: v.levels, constraints: info.nConstraints, zkeyMB: +(fs.statSync(v.zkey).size / 2 ** 20).toFixed(1),
    witnessMs: { mean: mean(v.witness), sd: sd(v.witness) }, proveMs: { mean: mean(v.prove), sd: sd(v.prove) },
  };
  out.push(row);
  console.log(JSON.stringify(row));
}
fs.writeFileSync("reports/depth-ablation.json", JSON.stringify({ credentialDepth: w.field.depth, runs: RUNS, variants: out }, null, 2));
await shutdown();
process.exit(0);
