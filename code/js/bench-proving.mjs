// Proving-time benchmark for both circuits: node js/bench-proving.mjs [runs]
// Writes reports/proving.json (machine, constraints, witness and prove times, proof size).
import fs from "node:fs";
import os from "node:os";
import * as snarkjs from "snarkjs";
import { extractLivenessWitness } from "./lib/credential.mjs";
import { makeIssuer, subjectIdFor, issueLivenessCredential } from "./lib/test-issuer.mjs";
import { ageCommitment } from "./lib/will.mjs";
import { shutdown } from "./lib/zk.mjs";

const RUNS = Number(process.argv[2] ?? 20);
const B = "zk/build";
const stats = (xs) => {
  const m = xs.reduce((a, b) => a + b, 0) / xs.length;
  const sd = Math.sqrt(xs.reduce((a, b) => a + (b - m) ** 2, 0) / (xs.length - 1));
  const s = [...xs].sort((a, b) => a - b);
  return { mean: +m.toFixed(1), sd: +sd.toFixed(1), median: +s[Math.floor(s.length / 2)].toFixed(1), min: +s[0].toFixed(1), max: +s.at(-1).toFixed(1) };
};

async function bench(circuit, inputs) {
  const wasm = `${B}/${circuit}_js/${circuit}.wasm`, zkey = `${B}/${circuit}.zkey`;
  const vkey = JSON.parse(fs.readFileSync(`${B}/${circuit}_vkey.json`, "utf8"));
  const info = await snarkjs.r1cs.info(`${B}/${circuit}.r1cs`);
  const witnessMs = [], proveMs = [], verifyMs = [];
  for (let i = -2; i < RUNS; i++) { // two warm-up runs
    const input = inputs(i);
    const wtns = { type: "mem" };
    let t = performance.now();
    await snarkjs.wtns.calculate(input, wasm, wtns);
    const w = performance.now() - t;
    t = performance.now();
    const { proof, publicSignals } = await snarkjs.groth16.prove(zkey, wtns);
    const p = performance.now() - t;
    t = performance.now();
    if (!(await snarkjs.groth16.verify(vkey, publicSignals, proof))) throw new Error("verify failed");
    const v = performance.now() - t;
    if (i >= 0) { witnessMs.push(w); proveMs.push(p); verifyMs.push(v); }
  }
  return { constraints: info.nConstraints, publicSignals: info.nOutputs + info.nPubInputs, witnessMs: stats(witnessMs), proveMs: stats(proveMs), verifyMs: stats(verifyMs) };
}

// Liveness inputs: fresh credentials from the local test issuer (same format as Billions).
const issuer = await makeIssuer("bench");
const subjectId = subjectIdFor("bench-owner");
const livenessInputs = [];
for (let i = 0; i < RUNS + 2; i++) {
  const cred = await issueLivenessCredential(issuer, { subjectId, subjectDid: "did:iden3:privado:test:bench", livenessTimestamp: 1_900_000_000 + i * 86_400 });
  const w = await extractLivenessWitness(cred);
  livenessInputs.push({
    claim: w.slots.map(String), issuerAx: w.key.Ax.toString(), issuerAy: w.key.Ay.toString(),
    sigR8x: w.sig.R8x.toString(), sigR8y: w.sig.R8y.toString(), sigS: w.sig.S.toString(),
    livenessTimestamp: w.field.value.toString(), tsSiblings: w.field.siblings.map(String), didSalt: String(1000 + i),
  });
}
const salt = 123456789n;
const c = await ageCommitment(20000101, salt);

const result = {
  machine: { cpu: os.cpus()[0].model, cores: os.cpus().length, memGB: Math.round(os.totalmem() / 2 ** 30), node: process.version, platform: `${os.type()} ${os.release()}` },
  runs: RUNS,
  proofBytes: 256, // Groth16 over BN254: 2 G1 + 1 G2 points, uncompressed as EVM calldata
  liveness: await bench("liveness", (i) => livenessInputs[i + 2]),
  age: await bench("age", () => ({ birthDate: "20000101", salt: salt.toString(), commitment: c.toString(), cutoff: "20000101" })),
};
fs.mkdirSync("reports", { recursive: true });
fs.writeFileSync("reports/proving.json", JSON.stringify(result, null, 2));
console.log(JSON.stringify(result, null, 2));
await shutdown();
process.exit(0);
