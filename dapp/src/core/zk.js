// Liveness credentials, bindings, age commitments and Groth16 inputs: the same statements the
// vault's verifiers check on-chain. Runs in the browser and in Node (tests).
import { Poseidon, PrivateKey } from "@iden3/js-crypto";
import { Merklizer } from "@iden3/js-jsonld-merklization";
import ctxCredentials from "../contexts/credentials-v1.json" with { type: "json" };
import ctxIden3 from "../contexts/iden3proofs.json" with { type: "json" };
import ctxLiveness from "../contexts/liveness.json" with { type: "json" };

export const MT_LEVELS = 40;
// Slot c0 of a LivenessCredential core claim (schema hash + flags); the circuit fixes it.
const LIVENESS_CLAIM_I0 = 0x2aad090f03bc9fcb197e0259ff687cbcacn;
const DAY = 86_400;
const CONTEXTS = {
  "https://www.w3.org/2018/credentials/v1": ctxCredentials,
  "https://schema.iden3.io/core/jsonld/iden3proofs.jsonld": ctxIden3,
  "ipfs://QmcomGJQwJDCg3RE6FjsFYCjjMSTWJXY3fUWeq43Mc5CCJ": ctxLiveness,
};
// Offline JSON-LD loader: merklization never touches the network.
const documentLoader = async (url) => {
  const document = CONTEXTS[url];
  if (!document) throw new Error(`unknown JSON-LD context ${url}`);
  return { contextUrl: null, document, documentUrl: url };
};

const rand = (n) => crypto.getRandomValues(new Uint8Array(n));
const toBig = (bytes) => BigInt("0x" + [...bytes].map((b) => b.toString(16).padStart(2, "0")).join(""));
const hexOf = (bytes) => [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
/** 250-bit random value: fits the BN254 scalar field. */
export const randomSalt = () => toBig(rand(32)) >> 6n;

/**
 * The public DEMO issuer. Its private key is published with this app, so anyone can mint its
 * "liveness" credentials: it stands in for a real issuer (e.g. a face-scan identity provider),
 * whose honesty is the system's trust assumption. Never rely on it for real assets.
 */
export async function demoIssuer() {
  const seed = new TextEncoder().encode("succession-vault-public-demo-issuer-v1");
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", seed));
  const prv = new PrivateKey(digest);
  const pub = prv.public();
  return { prv, Ax: pub.p[0], Ay: pub.p[1], did: "did:example:demo-liveness-issuer" };
}

/** A fresh holder identity: a 31-byte subject id (as in iden3) and the binding salt. */
export function newIdentity() {
  return { subjectId: toBig(rand(31)).toString(), didSalt: randomSalt().toString(), label: "demo-" + hexOf(rand(4)) };
}

/** beta = Poseidon(issuer Ax, issuer Ay, subject id, salt): registered in the vault. */
export function bindingOf(issuer, identity) {
  return Poseidon.hash([issuer.Ax, issuer.Ay, BigInt(identity.subjectId), BigInt(identity.didSalt)]);
}

/** Merklize a credential document and return the inclusion proof of its livenessTimestamp. */
async function timestampProof(doc) {
  const mz = await Merklizer.merklizeJSONLD(JSON.stringify(doc), { documentLoader });
  const root = (await mz.root()).bigInt();
  const path = await mz.resolveDocPath("credentialSubject.livenessTimestamp", { documentLoader });
  const { proof, value } = await mz.proof(path);
  if (!proof.existence) throw new Error("livenessTimestamp missing from the credential");
  const siblings = proof.allSiblings().map((h) => h.bigInt());
  if (siblings.length > MT_LEVELS) throw new Error("credential tree deeper than the circuit");
  while (siblings.length < MT_LEVELS) siblings.push(0n);
  return { root, value: await value.mtEntry(), siblings };
}

/**
 * The issuer's side of a liveness check: a W3C LivenessCredential (iden3 format) for `identity`
 * at time `ts`, with its signed core claim. In a real deployment this happens at the issuer, after
 * a presentation-attack-resistant face scan; the app only ever sees the signed result.
 */
export async function issueLivenessCredential(issuer, identity, ts) {
  const doc = {
    id: `urn:uuid:00000000-0000-4000-8000-${String(ts).padStart(12, "0")}`,
    "@context": Object.keys(CONTEXTS),
    type: ["VerifiableCredential", "LivenessCredential"],
    expirationDate: new Date((ts + 90 * DAY) * 1000).toISOString().replace(".000Z", "Z"),
    issuanceDate: new Date(ts * 1000).toISOString(),
    credentialSubject: { captureMethod: "activePhoto", id: `did:example:${identity.label}`, livenessTimestamp: ts, type: "LivenessCredential" },
    issuer: issuer.did,
    credentialSchema: { id: "ipfs://QmRXMVfuizWNaLEtiAyvGzNmanNDfQaPXHqdDTCuP2o7Xo", type: "JsonSchema2023" },
  };
  const field = await timestampProof(doc);
  const expiration = BigInt(ts + 90 * DAY);
  const slots = [LIVENESS_CLAIM_I0, BigInt(identity.subjectId), field.root, 0n, 1n | (expiration << 64n), 0n, 0n, 0n];
  const hash = Poseidon.hash([Poseidon.hash(slots.slice(0, 4)), Poseidon.hash(slots.slice(4, 8))]);
  const sig = issuer.prv.signPoseidon(hash);
  return { doc, slots, field, sig: { R8x: sig.R8[0], R8y: sig.R8[1], S: sig.S } };
}

/** Private and public inputs of the proof-of-life circuit (public outputs: binding, timestamp). */
export function livenessInput(issuer, identity, cred) {
  return {
    claim: cred.slots.map(String),
    issuerAx: issuer.Ax.toString(), issuerAy: issuer.Ay.toString(),
    sigR8x: cred.sig.R8x.toString(), sigR8y: cred.sig.R8y.toString(), sigS: cred.sig.S.toString(),
    livenessTimestamp: cred.field.value.toString(),
    tsSiblings: cred.field.siblings.map(String),
    didSalt: identity.didSalt,
  };
}

/** Poseidon(birthDate YYYYMMDD, salt): stored in an age-restricted will leaf. */
export const ageCommitment = (birthDate, salt) => Poseidon.hash([BigInt(birthDate), BigInt(salt)]);

/** Latest admissible birth date for someone who must be `minAge` on the given day (UTC). */
export function ageCutoff(unixSeconds, minAge) {
  const d = new Date(unixSeconds * 1000);
  return (d.getUTCFullYear() - minAge) * 10000 + (d.getUTCMonth() + 1) * 100 + d.getUTCDate();
}

/** snarkjs proof -> the (a, b, c) arguments of the Solidity verifier. */
export function toSolidity(proof) {
  return {
    a: [proof.pi_a[0], proof.pi_a[1]],
    b: [[proof.pi_b[0][1], proof.pi_b[0][0]], [proof.pi_b[1][1], proof.pi_b[1][0]]],
    c: [proof.pi_c[0], proof.pi_c[1]],
  };
}

/** Groth16 proof with snarkjs (passed in: the browser loads it as a script, Node imports it). */
export async function prove(snarkjs, input, wasm, zkey) {
  const t0 = performance.now();
  const { proof, publicSignals } = await snarkjs.groth16.fullProve(input, wasm, zkey);
  return { proof, publicSignals, calldata: toSolidity(proof), ms: Math.round(performance.now() - t0) };
}
