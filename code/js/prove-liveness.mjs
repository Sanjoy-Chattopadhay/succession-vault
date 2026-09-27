// Usage: node js/prove-liveness.mjs <credential.json> <didSalt> [out.json]
//
// Builds a proof of life from a BJJ-signed LivenessCredential. Prints the binding the vault must
// register (Poseidon(issuerAx, issuerAy, subjectId, didSalt)) and the proof calldata.
import fs from "node:fs";
import { loadCredential, extractLivenessWitness, crypto } from "./lib/credential.mjs";
import { prove, shutdown } from "./lib/zk.mjs";

const [file, saltArg, out] = process.argv.slice(2);
if (!file || !saltArg) {
  console.error("usage: node js/prove-liveness.mjs <credential.json> <didSalt> [out.json]");
  process.exit(1);
}
const didSalt = BigInt(saltArg);
const cred = loadCredential(file);
const w = await extractLivenessWitness(cred);

const input = {
  claim: w.slots.map(String),
  issuerAx: w.key.Ax.toString(),
  issuerAy: w.key.Ay.toString(),
  sigR8x: w.sig.R8x.toString(),
  sigR8y: w.sig.R8y.toString(),
  sigS: w.sig.S.toString(),
  livenessTimestamp: w.field.value.toString(),
  tsSiblings: w.field.siblings.map(String),
  didSalt: didSalt.toString(),
};

const { poseidon, F } = await crypto();
const expectedBinding = F.toObject(poseidon([w.key.Ax, w.key.Ay, w.info.subjectId, didSalt]));
const r = await prove("liveness", input);
await shutdown();

const [binding, timestamp] = r.publicSignals;
if (BigInt(binding) !== expectedBinding) throw new Error("binding mismatch");
const result = {
  credential: cred.id,
  livenessTimestamp: Number(timestamp),
  livenessTime: new Date(Number(timestamp) * 1000).toISOString(),
  binding,
  provingMs: Math.round(r.ms),
  calldata: r.calldata,
};
if (out) fs.writeFileSync(out, JSON.stringify(result, null, 2));
console.log(JSON.stringify({ ...result, calldata: out ? `written to ${out}` : result.calldata }, null, 2));
process.exit(0);
