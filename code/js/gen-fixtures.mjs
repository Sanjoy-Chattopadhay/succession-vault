// Generates the JSON fixtures used by the Foundry tests (test/fixtures/*.json):
//   liveness.json  proofs of life from a local test issuer at fixed times, plus one from a second issuer
//   will.json      a will over ETH / ERC-20 / ERC-721 / ERC-1155 with time-locked and age-gated bequests
//   age.json       age-gate proofs for the age-restricted heirs
//   trees.json     wills of 1..1024 heirs (root + first leaf + proof) for gas-scaling measurements
import fs from "node:fs";
import { crypto, extractLivenessWitness } from "./lib/credential.mjs";
import { makeIssuer, subjectIdFor, issueLivenessCredential } from "./lib/test-issuer.mjs";
import { buildWill, ageCommitment, KIND } from "./lib/will.mjs";
import { prove, shutdown } from "./lib/zk.mjs";

const OUT = "test/fixtures";
const DAY = 86_400;
export const T0 = 1_900_000_000; // 2030-03-17T17:46:40Z, vault creation time in the tests

const ADDR = {
  alice: "0x1000000000000000000000000000000000000a11",
  bob: "0x1000000000000000000000000000000000000b0b",
  carol: "0x1000000000000000000000000000000000000ca1",
  dave: "0x1000000000000000000000000000000000000da7",
  erin: "0x1000000000000000000000000000000000000e21",
  residuary: "0x1000000000000000000000000000000000000f0d",
  token20: "0x2000000000000000000000000000000000000020",
  nft721: "0x2000000000000000000000000000000000000721",
  multi1155: "0x2000000000000000000000000000000000001155",
};

const sol = (r) => ({ a: r.calldata.a, b: r.calldata.b, c: r.calldata.c });
const utc = (y, m, d) => Date.UTC(y, m - 1, d) / 1000;
fs.mkdirSync(OUT, { recursive: true });
const { poseidon, F } = await crypto();

// ---------------------------------------------------------------- proofs of life
const issuer = await makeIssuer("A");
const otherIssuer = await makeIssuer("B");
const subjectId = subjectIdFor("owner");
const subjectDid = "did:iden3:privado:test:owner";
const didSalt = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdn;
const bindingOf = (iss) => F.toObject(poseidon([iss.Ax, iss.Ay, subjectId, didSalt])).toString();

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
  if (r.publicSignals[0] !== bindingOf(iss) || Number(r.publicSignals[1]) !== livenessTimestamp) {
    throw new Error("unexpected public signals");
  }
  return { ...sol(r), binding: r.publicSignals[0], ts: String(livenessTimestamp), provingMs: Math.round(r.ms) };
}

const liveness = {
  T0,
  binding: bindingOf(issuer),
  otherBinding: bindingOf(otherIssuer),
  p10: await lifeProof(issuer, T0 + 10 * DAY),
  p200: await lifeProof(issuer, T0 + 200 * DAY),
  p400: await lifeProof(issuer, T0 + 400 * DAY),
  other10: await lifeProof(otherIssuer, T0 + 10 * DAY),
};
fs.writeFileSync(`${OUT}/liveness.json`, JSON.stringify(liveness, null, 2));
console.log("liveness.json  proving ms:", [liveness.p10, liveness.p200, liveness.p400, liveness.other10].map((p) => p.provingMs));

// ---------------------------------------------------------------- will
const carolBirth = 20150601, erinBirth = 20200101;
const carolSalt = 0xca201n * 1_000_000_007n, erinSalt = 0xe214n * 998_244_353n;
const carolC = await ageCommitment(carolBirth, carolSalt);
const erinC = await ageCommitment(erinBirth, erinSalt);
const trancheAt = T0 + 3 * 365 * DAY;
const bequests = [
  { heir: ADDR.alice, kind: KIND.ETH, shareBps: 6000 },
  { heir: ADDR.bob, kind: KIND.ETH, shareBps: 2000 },
  { heir: ADDR.bob, kind: KIND.ETH, shareBps: 2000, notBefore: trancheAt },
  { heir: ADDR.alice, kind: KIND.ERC20, token: ADDR.token20, shareBps: 4000 },
  { heir: ADDR.bob, kind: KIND.ERC20, token: ADDR.token20, shareBps: 3000 },
  { heir: ADDR.carol, kind: KIND.ERC20, token: ADDR.token20, shareBps: 2000, minAge: 18, ageCommitment: carolC },
  { heir: ADDR.erin, kind: KIND.ERC20, token: ADDR.token20, shareBps: 1000, minAge: 18, ageCommitment: erinC },
  { heir: ADDR.dave, kind: KIND.ERC721, token: ADDR.nft721, id: 1 },
  { heir: ADDR.bob, kind: KIND.ERC1155, token: ADDR.multi1155, id: 7, shareBps: 10000 },
];
const will = buildWill(bequests, { blind: false });
const toLeafJson = ({ bequest: v, proof }) => ({
  index: v[0], heir: v[1], kind: v[2], token: v[3], id: v[4], shareBps: v[5],
  notBefore: v[6], minAge: v[7], ageCommitment: v[8], proof,
});
fs.writeFileSync(`${OUT}/will.json`, JSON.stringify({
  addresses: ADDR, trancheAt, root: will.root, leaves: will.leaves.map(toLeafJson),
}, null, 2));
console.log("will.json      root:", will.root, `(${bequests.length} bequests)`);

// ---------------------------------------------------------------- age proofs
async function ageProof(birthDate, salt, commitment, cutoff) {
  const r = await prove("age", {
    birthDate: String(birthDate), salt: salt.toString(), commitment: commitment.toString(), cutoff: String(cutoff),
  });
  return { ...sol(r), commitment: commitment.toString(), cutoff: String(cutoff), provingMs: Math.round(r.ms) };
}
const age = {
  carolEligibleAt: utc(2033, 6, 1),
  carol: await ageProof(carolBirth, carolSalt, carolC, carolBirth),     // tightest cutoff
  carolLoose: await ageProof(carolBirth, carolSalt, carolC, 20160101),  // valid proof, cutoff too late
};
let underage = "rejected by the circuit";
try { await ageProof(erinBirth, erinSalt, erinC, 20150601); underage = "ACCEPTED (bug!)"; } catch { /* expected */ }
fs.writeFileSync(`${OUT}/age.json`, JSON.stringify(age, null, 2));
console.log("age.json       proving ms:", age.carol.provingMs, "| proof for an underage heir:", underage);

// ---------------------------------------------------------------- trees for gas scaling
const sizes = [1, 2, 4, 8, 16, 32, 64, 128, 256, 1024];
const trees = {};
for (const n of sizes) {
  // Heirs are distinct across trees, so every measured claim pays for a fresh token holder.
  const bs = Array.from({ length: n }, (_, i) => ({
    heir: "0x3" + n.toString(16).padStart(4, "0") + i.toString(16).padStart(35, "0"),
    kind: KIND.ERC20, token: ADDR.token20, shareBps: Math.floor(10_000 / n),
  }));
  const w = buildWill(bs); // blinded leaves, as a real will would use
  trees[`n${n}`] = { n, root: w.root, leaf: toLeafJson(w.leaves[0]) };
}
fs.writeFileSync(`${OUT}/trees.json`, JSON.stringify(trees, null, 2));
console.log("trees.json     sizes:", sizes.join(", "));

await shutdown();
process.exit(0);
