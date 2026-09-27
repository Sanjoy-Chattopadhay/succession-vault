// End-to-end check of the browser crypto pipeline in Node: demo issuer -> credential ->
// merklization -> Groth16 proof of life -> verification against the key behind the deployed
// verifier. Same for the age gate.   node test/zk.test.mjs
import * as snarkjs from "snarkjs";
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import {
  demoIssuer, newIdentity, bindingOf, issueLivenessCredential, livenessInput, prove,
  ageCommitment, ageCutoff, randomSalt,
} from "../src/core/zk.js";

const C = new URL("../public/circuits/", import.meta.url);
const file = (f) => fileURLToPath(new URL(f, C));
const vkey = (c) => JSON.parse(fs.readFileSync(file(`${c}_vkey.json`), "utf8"));

const issuer = await demoIssuer();
const id = newIdentity();
const beta = bindingOf(issuer, id);
const ts = Math.floor(Date.now() / 1000);
const cred = await issueLivenessCredential(issuer, id, ts);
const live = await prove(snarkjs, livenessInput(issuer, id, cred), file("liveness.wasm"), file("liveness.zkey"));
const okLive = await snarkjs.groth16.verify(vkey("liveness"), live.publicSignals, live.proof);
console.log("proof of life:", okLive ? "VERIFIES" : "FAILS", `(${live.ms} ms)`);
console.log("  public binding matches:", live.publicSignals[0] === beta.toString());
console.log("  public timestamp matches:", live.publicSignals[1] === String(ts));

// A tampered credential (different timestamp in the signed claim path) must not prove.
let tamperedRejected = false;
try {
  const bad = livenessInput(issuer, id, cred);
  bad.livenessTimestamp = String(ts + 3600);
  await prove(snarkjs, bad, file("liveness.wasm"), file("liveness.zkey"));
} catch { tamperedRejected = true; }
console.log("  tampered timestamp rejected by the circuit:", tamperedRejected);

const salt = randomSalt();
const birth = 20000101;
const c = ageCommitment(birth, salt);
const cutoff = ageCutoff(ts, 18);
const age = await prove(snarkjs, { birthDate: String(birth), salt: salt.toString(), commitment: c.toString(), cutoff: String(cutoff) },
  file("age.wasm"), file("age.zkey"));
const okAge = await snarkjs.groth16.verify(vkey("age"), age.publicSignals, age.proof);
console.log("age proof:", okAge ? "VERIFIES" : "FAILS", `(${age.ms} ms)`);
if (globalThis.curve_bn128) await globalThis.curve_bn128.terminate();
process.exit(okLive && okAge && tamperedRejected ? 0 : 1);
