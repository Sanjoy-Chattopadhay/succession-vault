// Writes the circuit inputs used by web/prove.html (browser proving benchmark).
import fs from "node:fs";
import { extractLivenessWitness } from "./lib/credential.mjs";
import { makeIssuer, subjectIdFor, issueLivenessCredential } from "./lib/test-issuer.mjs";
import { ageCommitment } from "./lib/will.mjs";

const iss = await makeIssuer("web");
const cred = await issueLivenessCredential(iss, { subjectId: subjectIdFor("web-owner"), subjectDid: "did:iden3:privado:test:web", livenessTimestamp: 1_900_000_000 });
const w = await extractLivenessWitness(cred);
fs.writeFileSync("web/liveness-input.json", JSON.stringify({
  claim: w.slots.map(String), issuerAx: w.key.Ax.toString(), issuerAy: w.key.Ay.toString(),
  sigR8x: w.sig.R8x.toString(), sigR8y: w.sig.R8y.toString(), sigS: w.sig.S.toString(),
  livenessTimestamp: w.field.value.toString(), tsSiblings: w.field.siblings.map(String), didSalt: "777",
}));
const c = await ageCommitment(20000101, 4242n);
fs.writeFileSync("web/age-input.json", JSON.stringify({ birthDate: "20000101", salt: "4242", commitment: c.toString(), cutoff: "20080101" }));
console.log("wrote web/liveness-input.json, web/age-input.json");
process.exit(0);
