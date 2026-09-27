// Where does the time of a proof of life go? Times every step the owner's device runs, on real
// LivenessCredentials issued by the production Billions issuer:
//   node js/bench-pipeline.mjs <credential.json>... [--runs N] [--salt-file F]
// Writes reports/pipeline.json. Prints no DID, salt or binding.
import fs from "node:fs";
import os from "node:os";
import * as snarkjs from "snarkjs";
import {
  loadCredential, claimSlots, issuerPublicKey, unpackSignature, verifyIssuerSignature, merklizedField, describeClaim, MT_LEVELS,
} from "./lib/credential.mjs";
import { shutdown } from "./lib/zk.mjs";

const args = process.argv.slice(2);
const opt = (name, def) => { const i = args.indexOf(name); return i < 0 ? def : args.splice(i, 2)[1]; };
const RUNS = Number(opt("--runs", 10));
const saltFile = opt("--salt-file", "fixtures/private/did-salt.txt");
const files = args;
if (files.length === 0) { console.error("usage: node js/bench-pipeline.mjs <credential.json>... [--runs N]"); process.exit(1); }
const didSalt = BigInt(fs.readFileSync(saltFile, "utf8").trim());

const B = "zk/build";
const wasm = `${B}/liveness_js/liveness.wasm`, zkey = `${B}/liveness.zkey`;
const vkey = JSON.parse(fs.readFileSync(`${B}/liveness_vkey.json`, "utf8"));
const stats = (xs) => {
  const m = xs.reduce((a, b) => a + b, 0) / xs.length;
  const sd = xs.length > 1 ? Math.sqrt(xs.reduce((a, b) => a + (b - m) ** 2, 0) / (xs.length - 1)) : 0;
  return { mean: +m.toFixed(1), sd: +sd.toFixed(1), min: +Math.min(...xs).toFixed(1), max: +Math.max(...xs).toFixed(1) };
};
const time = async (f) => { const t = performance.now(); const r = await f(); return [r, performance.now() - t]; };

const credentials = [];
for (const file of files) {
  const steps = { parse: [], issuerSignature: [], merklize: [], witness: [], prove: [], verify: [] };
  let depth, lastNonZero, bytes;
  for (let i = -1; i < RUNS; i++) { // one warm-up run
    const [cred, tParse] = await time(() => loadCredential(file));
    bytes = fs.statSync(file).size;
    const p = cred.proof.find((x) => x.type === "BJJSignature2021");
    const slots = claimSlots(p.coreClaim);
    const key = issuerPublicKey(p.issuerData.authCoreClaim);
    const [sigOk, tSig] = await time(() => verifyIssuerSignature(slots, p.signature, key));
    if (!sigOk) throw new Error("issuer signature invalid");
    const [field, tMerk] = await time(() => merklizedField(cred, "credentialSubject.livenessTimestamp"));
    if (field.root !== describeClaim(slots).merklizedRoot) throw new Error("merklized root mismatch");
    depth = field.depth;
    lastNonZero = field.siblings.findLastIndex((s) => s !== 0n);
    const sig = await unpackSignature(p.signature);
    const input = {
      claim: slots.map(String), issuerAx: key.Ax.toString(), issuerAy: key.Ay.toString(),
      sigR8x: sig.R8x.toString(), sigR8y: sig.R8y.toString(), sigS: sig.S.toString(),
      livenessTimestamp: field.value.toString(), tsSiblings: field.siblings.map(String), didSalt: didSalt.toString(),
    };
    const wtns = { type: "mem" };
    const [, tWit] = await time(() => snarkjs.wtns.calculate(input, wasm, wtns));
    const [{ proof, publicSignals }, tProve] = await time(() => snarkjs.groth16.prove(zkey, wtns));
    const [ok, tVer] = await time(() => snarkjs.groth16.verify(vkey, publicSignals, proof));
    if (!ok) throw new Error("proof does not verify");
    if (i >= 0) {
      steps.parse.push(tParse); steps.issuerSignature.push(tSig); steps.merklize.push(tMerk);
      steps.witness.push(tWit); steps.prove.push(tProve); steps.verify.push(tVer);
    }
  }
  const s = Object.fromEntries(Object.entries(steps).map(([k, v]) => [k, stats(v)]));
  const total = ["parse", "issuerSignature", "merklize", "witness", "prove"].reduce((a, k) => a + s[k].mean, 0);
  credentials.push({
    credential: file.split(/[\\/]/).pop(), credentialBytes: bytes,
    smtDepthUsed: depth, lastNonZeroSibling: lastNonZero, circuitLevels: MT_LEVELS,
    stepsMs: s, deviceTotalMs: +total.toFixed(1),
  });
  console.log(`${file}: depth ${depth} (last non-zero sibling at level ${lastNonZero}), total ${total.toFixed(0)} ms`);
  for (const [k, v] of Object.entries(s)) console.log(`  ${k.padEnd(16)} ${String(v.mean).padStart(8)} ms  (sd ${v.sd})`);
}

const result = {
  machine: { cpu: os.cpus()[0].model, cores: os.cpus().length, node: process.version, platform: `${os.type()} ${os.release()}` },
  runs: RUNS,
  note: "Steps run on the owner's device for one proof of life. JSON-LD contexts are served from a local cache (fixtures/contexts); a first run that downloads them adds network time.",
  credentials,
};
fs.mkdirSync("reports", { recursive: true });
fs.writeFileSync("reports/pipeline.json", JSON.stringify(result, null, 2));
await shutdown();
process.exit(0);
