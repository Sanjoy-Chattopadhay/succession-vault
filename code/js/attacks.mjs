// Attacks built from the owner's REAL production LivenessCredential (issued by Billions).
//
// Part 1, off-chain: the credential JSON is edited in the ways an attacker would want (re-dating
// it, moving it to another DID, extending its validity, changing its type, altering the signed
// claim, swapping the issuer key) and each edited version is fed to the prover. Every edit must
// make proof generation fail, because the circuit checks the issuer's signature over the claim and
// the merklized timestamp against the signed root. Any edit that still yields a proof is reported.
//
// Part 2, vectors for on-chain attacks: the honest proof for the unedited credential, which
// script/DemoAttacks.s.sol then misuses against the live vault (re-dating the public input,
// swapping the binding, future-dating).
//
//   node js/attacks.mjs            -> demo/attacks/vectors.json, reports/attacks-offchain.json
import fs from "node:fs";
import { loadCredential, extractLivenessWitness } from "./lib/credential.mjs";
import { makeIssuer } from "./lib/test-issuer.mjs";
import { prove, shutdown } from "./lib/zk.mjs";

const REAL = "fixtures/private/liveness-2025-12-14.json";
const OUT = "demo/attacks";
fs.mkdirSync(OUT, { recursive: true });
fs.mkdirSync("reports", { recursive: true });

const owner = JSON.parse(fs.readFileSync("demo/owner.json", "utf8"));
if (!owner.realDidSalt || !owner.realBinding) throw new Error("demo/owner.json has no real binding; run the main Sepolia script first");
const original = loadCredential(REAL);
const clone = () => JSON.parse(JSON.stringify(original));
const now = Math.floor(Date.now() / 1000);

async function proveCredential(cred) {
  const w = await extractLivenessWitness(cred);
  return prove("liveness", {
    claim: w.slots.map(String),
    issuerAx: w.key.Ax.toString(), issuerAy: w.key.Ay.toString(),
    sigR8x: w.sig.R8x.toString(), sigR8y: w.sig.R8y.toString(), sigS: w.sig.S.toString(),
    livenessTimestamp: w.field.value.toString(),
    tsSiblings: w.field.siblings.map(String),
    didSalt: owner.realDidSalt,
  });
}

// Edit one hex-encoded 32-byte slot of an iden3 claim (little-endian field element).
function editSlot(hex, slot, mutate) {
  const b = Buffer.from(hex, "hex");
  const s = b.subarray(32 * slot, 32 * slot + 32);
  mutate(s);
  return b.toString("hex");
}
const bjj = (c) => c.proof.find((p) => p.type === "BJJSignature2021");

// ------------------------------------------------------------------ honest proof (control)
const honest = await proveCredential(clone());
if (honest.publicSignals[0] !== owner.realBinding) throw new Error("honest proof does not match the registered real binding");
console.log(`honest real credential: proof generated (${Math.round(honest.ms)} ms), liveness time ${new Date(Number(honest.publicSignals[1]) * 1000).toISOString()}`);

// ------------------------------------------------------------------ part 1: edited credentials
const otherIssuer = await makeIssuer("attacker");
const edits = [
  ["re-dated: livenessTimestamp set to now", (c) => { c.credentialSubject.livenessTimestamp = now; }],
  ["re-dated by one second", (c) => { c.credentialSubject.livenessTimestamp += 1; }],
  ["moved to another DID (credentialSubject.id)", (c) => { c.credentialSubject.id = "did:iden3:billions:main:2VmAkXrihYAttackerDid000000000000000000000"; }],
  ["validity extended (expirationDate + 10 years)", (c) => { c.expirationDate = c.expirationDate.replace(/^(\d{4})/, (y) => String(Number(y) + 10)); }],
  ["type changed to another credential type", (c) => { c.type = c.type.map((t) => (t === "LivenessCredential" ? "KYCAgeCredential" : t)); c.credentialSubject.type = "KYCAgeCredential"; }],
  ["signed claim edited: subject slot (c1) of coreClaim", (c) => { const p = bjj(c); p.coreClaim = editSlot(p.coreClaim, 1, (s) => { s[0] ^= 1; }); }],
  ["signed claim edited: expiration slot (c4) of coreClaim", (c) => { const p = bjj(c); p.coreClaim = editSlot(p.coreClaim, 4, (s) => { s[12] ^= 1; }); }],
  ["signature altered (last byte)", (c) => { const p = bjj(c); const b = Buffer.from(p.signature, "hex"); b[b.length - 1] ^= 1; p.signature = b.toString("hex"); }],
  ["issuer key swapped in authCoreClaim", (c) => {
    const p = bjj(c);
    const le = (x) => { const b = Buffer.alloc(32); for (let i = 0; i < 32; i++) { b[i] = Number(x & 0xffn); x >>= 8n; } return b; };
    let a = editSlot(p.issuerData.authCoreClaim, 2, (s) => le(otherIssuer.Ax).copy(s));
    a = editSlot(a, 3, (s) => le(otherIssuer.Ay).copy(s));
    p.issuerData.authCoreClaim = a;
  }],
];

const results = [];
for (const [name, edit] of edits) {
  const c = clone();
  edit(c);
  let outcome, detail;
  try {
    const r = await proveCredential(c);
    outcome = "PROOF GENERATED";
    detail = `public signals ${r.publicSignals.join(", ")}`;
  } catch (e) {
    outcome = "rejected";
    const msg = String(e?.message ?? e);
    detail = /Assert Failed/i.test(msg) ? "circuit constraint violated during witness generation"
      : msg.split("\n")[0].slice(0, 140);
  }
  results.push({ edit: name, outcome, detail });
  console.log(`${outcome === "rejected" ? "REJECTED " : "ACCEPTED!"} ${name} -- ${detail}`);
}

const accepted = results.filter((r) => r.outcome !== "rejected");
fs.writeFileSync("reports/attacks-offchain.json", JSON.stringify({
  credential: "real Billions LivenessCredential, issued 2025-12-14",
  honestControl: { proofGenerated: true, provingMs: Math.round(honest.ms) },
  edits: results,
  rejected: results.length - accepted.length,
  total: results.length,
}, null, 2));

// ------------------------------------------------------------------ part 2: on-chain vectors
fs.writeFileSync(`${OUT}/vectors.json`, JSON.stringify({
  realBinding: owner.realBinding,
  testBinding: owner.binding,
  realTau: honest.publicSignals[1],
  realProof: honest.calldata,
}, null, 2));
console.log(`\n${results.length - accepted.length} of ${results.length} edits rejected; vectors -> ${OUT}/vectors.json`);

await shutdown();
process.exit(accepted.length === 0 ? 0 : 1);
