// Negative tests for both circuits: every manipulated witness must be rejected during witness
// generation (a violated === constraint aborts the WASM witness calculator), and the honest
// witness must yield a proof that verifies. Writes reports/circuit-tests.json.
//   node js/test-circuits.mjs
import fs from "node:fs";
import * as snarkjs from "snarkjs";
import { extractLivenessWitness, crypto } from "./lib/credential.mjs";
import { makeIssuer, subjectIdFor, issueLivenessCredential } from "./lib/test-issuer.mjs";
import { ageCommitment } from "./lib/will.mjs";
import { shutdown } from "./lib/zk.mjs";

const B = "zk/build";
const P = 21888242871839275222246405745257275088548364400416034343698204186575808495617n; // BN254 r

async function witnessOk(circuit, input) {
  try {
    await snarkjs.wtns.calculate(input, `${B}/${circuit}_js/${circuit}.wasm`, { type: "mem" });
    return true;
  } catch {
    return false;
  }
}

async function proofVerifies(circuit, input) {
  const { proof, publicSignals } = await snarkjs.groth16.fullProve(input, `${B}/${circuit}_js/${circuit}.wasm`, `${B}/${circuit}.zkey`);
  const vkey = JSON.parse(fs.readFileSync(`${B}/${circuit}_vkey.json`, "utf8"));
  return snarkjs.groth16.verify(vkey, publicSignals, proof);
}

// ------------------------------------------------------------------ liveness inputs
const issuer = await makeIssuer("A");
const other = await makeIssuer("B");
const subjectId = subjectIdFor("owner");
const cred = await issueLivenessCredential(issuer, { subjectId, subjectDid: "did:iden3:privado:test:owner", livenessTimestamp: 1_900_000_000 });
const w = await extractLivenessWitness(cred);
const base = {
  claim: w.slots.map(String), issuerAx: w.key.Ax.toString(), issuerAy: w.key.Ay.toString(),
  sigR8x: w.sig.R8x.toString(), sigR8y: w.sig.R8y.toString(), sigS: w.sig.S.toString(),
  livenessTimestamp: w.field.value.toString(), tsSiblings: w.field.siblings.map(String), didSalt: "12345",
};
const mut = (f) => { const x = structuredClone(base); f(x); return x; };

// A second credential (other issuer) supplies a valid signature over a different claim.
const credB = await issueLivenessCredential(other, { subjectId, subjectDid: "did:iden3:privado:test:owner", livenessTimestamp: 1_900_000_000 });
const wB = await extractLivenessWitness(credB);

const liveness = [
  ["honest credential", base, true],
  ["signature scalar S + 1", mut((x) => { x.sigS = (BigInt(x.sigS) + 1n).toString(); }), false],
  ["signature from another issuer, same key", mut((x) => { x.sigR8x = wB.sig.R8x.toString(); x.sigR8y = wB.sig.R8y.toString(); x.sigS = wB.sig.S.toString(); }), false],
  ["foreign issuer key with original signature", mut((x) => { x.issuerAx = wB.key.Ax.toString(); x.issuerAy = wB.key.Ay.toString(); }), false],
  ["subject DID swapped (claim slot 1)", mut((x) => { x.claim[1] = subjectIdFor("victim").toString(); }), false],
  ["other credential type (claim slot 0)", mut((x) => { x.claim[0] = (BigInt(x.claim[0]) + 1n).toString(); }), false],
  ["expiration / nonce altered (claim slot 4)", mut((x) => { x.claim[4] = (BigInt(x.claim[4]) + 1n).toString(); }), false],
  ["liveness timestamp + 1 s", mut((x) => { x.livenessTimestamp = (BigInt(x.livenessTimestamp) + 1n).toString(); }), false],
  ["liveness timestamp moved 1 year ahead", mut((x) => { x.livenessTimestamp = (BigInt(x.livenessTimestamp) + 31_536_000n).toString(); }), false],
  ["Merkle path sibling altered", mut((x) => { const i = x.tsSiblings.findIndex((s) => s !== "0"); x.tsSiblings[i] = (BigInt(x.tsSiblings[i]) + 1n).toString(); }), false],
  ["Merkle root (claim slot 2) of another credential", mut((x) => { x.claim[2] = wB.slots[2].toString(); }), false],
];

// ------------------------------------------------------------------ age inputs
const salt = 987654321n;
const C = await ageCommitment(20080918, salt);
const age = (birthDate, s, commitment, cutoff) => ({ birthDate: String(birthDate), salt: s.toString(), commitment: commitment.toString(), cutoff: String(cutoff) });
const ageCases = [
  ["heir exactly of age (b = cutoff)", age(20080918, salt, C, 20080918), true],
  ["heir older than required", age(20080918, salt, C, 20260101), true],
  ["heir one day too young", age(20080918, salt, C, 20080917), false],
  ["wrong salt", age(20080918, salt + 1n, C, 20260101), false],
  ["claimed birth date differs from committed", age(19900101, salt, C, 20260101), false],
  ["cutoff wraps the field (p - 1)", age(20080918, salt, C, P - 1n), false],
  ["birth date wraps the field (p - 1)", age(P - 1n, salt, C, 20260101), false],
];

// ------------------------------------------------------------------ run
const rows = [];
for (const [circuit, cases] of [["liveness", liveness], ["age", ageCases]]) {
  for (const [name, input, expected] of cases) {
    const accepted = await witnessOk(circuit, input);
    let verified = null;
    if (accepted) verified = await proofVerifies(circuit, input);
    const pass = accepted === expected && (!expected || verified);
    rows.push({ circuit, case: name, expected: expected ? "accept" : "reject", observed: accepted ? (verified ? "accept (proof verifies)" : "witness ok, proof fails") : "reject", result: pass ? "PASS" : "FAIL" });
  }
}
console.table(rows);
const failed = rows.filter((r) => r.result === "FAIL").length;
console.log(`${rows.length - failed}/${rows.length} cases behave as expected`);
fs.mkdirSync("reports", { recursive: true });
fs.writeFileSync("reports/circuit-tests.json", JSON.stringify(rows, null, 2));
await shutdown();
process.exit(failed ? 1 : 0);
