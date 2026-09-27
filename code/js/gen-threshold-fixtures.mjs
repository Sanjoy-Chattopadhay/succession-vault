// Generates test/fixtures/threshold.json: proofs of life for the same owner from three test issuers
// (A and B as in liveness.json, plus C), used by the j-of-m issuer-threshold tests.
//   node js/gen-threshold-fixtures.mjs
import fs from "node:fs";
import { crypto, extractLivenessWitness } from "./lib/credential.mjs";
import { makeIssuer, subjectIdFor, issueLivenessCredential } from "./lib/test-issuer.mjs";
import { prove, shutdown } from "./lib/zk.mjs";

const DAY = 86_400;
const T0 = 1_900_000_000; // must match js/gen-fixtures.mjs and test/Base.t.sol
const subjectId = subjectIdFor("owner");
const subjectDid = "did:iden3:privado:test:owner";
const didSalt = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdn; // as in gen-fixtures
const { poseidon, F } = await crypto();

async function lifeProof(iss, livenessTimestamp) {
  const cred = await issueLivenessCredential(iss, { subjectId, subjectDid, livenessTimestamp });
  const w = await extractLivenessWitness(cred);
  const r = await prove("liveness", {
    claim: w.slots.map(String),
    issuerAx: w.key.Ax.toString(), issuerAy: w.key.Ay.toString(),
    sigR8x: w.sig.R8x.toString(), sigR8y: w.sig.R8y.toString(), sigS: w.sig.S.toString(),
    livenessTimestamp: w.field.value.toString(),
    tsSiblings: w.field.siblings.map(String),
    didSalt: didSalt.toString(),
  });
  const binding = F.toObject(poseidon([iss.Ax, iss.Ay, subjectId, didSalt])).toString();
  if (r.publicSignals[0] !== binding || Number(r.publicSignals[1]) !== livenessTimestamp) {
    throw new Error("unexpected public signals");
  }
  return { a: r.calldata.a, b: r.calldata.b, c: r.calldata.c, binding, ts: String(livenessTimestamp) };
}

const [A, B, C] = await Promise.all(["A", "B", "C"].map(makeIssuer));
const out = {
  a200: await lifeProof(A, T0 + 200 * DAY),
  b200: await lifeProof(B, T0 + 200 * DAY),
  c200: await lifeProof(C, T0 + 200 * DAY),
  c201: await lifeProof(C, T0 + 201 * DAY),
};
out.bindingA = out.a200.binding;
out.bindingB = out.b200.binding;
out.bindingC = out.c200.binding;
fs.writeFileSync("test/fixtures/threshold.json", JSON.stringify(out, null, 2));
console.log("threshold.json written");
await shutdown();
process.exit(0);
