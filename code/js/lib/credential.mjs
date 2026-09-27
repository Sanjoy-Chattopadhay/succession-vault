// Parsing and checking iden3 (Privado ID / Billions) W3C credentials signed with BJJSignature2021.
//
// An iden3 core claim is 8 field elements (index i0..i3, value v0..v3), each serialized as
// 32 little-endian bytes. The issuer signs Poseidon(Poseidon(i0..i3), Poseidon(v0..v3)) with an
// EdDSA-Poseidon key on Baby Jubjub; the key sits in slots i2/i3 of the issuer's auth claim.
import { buildPoseidon, buildEddsa } from "circomlibjs";
import { Merklizer, getDocumentLoader } from "@iden3/js-jsonld-merklization";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const MT_LEVELS = 40; // depth of the iden3 JSON-LD merklization tree
export const IPFS_GATEWAY = "https://gateway.pinata.cloud";

// JSON-LD contexts are served from fixtures/contexts so merklization is reproducible offline
// (public IPFS gateways rate-limit aggressively).
const CONTEXT_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), "../../fixtures/contexts");
const CACHED_CONTEXTS = {
  "https://www.w3.org/2018/credentials/v1": "credentials-v1.jsonld",
  "https://schema.iden3.io/core/jsonld/iden3proofs.jsonld": "iden3proofs.jsonld",
  "ipfs://QmcomGJQwJDCg3RE6FjsFYCjjMSTWJXY3fUWeq43Mc5CCJ": "QmcomGJQwJDCg3RE6FjsFYCjjMSTWJXY3fUWeq43Mc5CCJ.jsonld",
};
const remoteLoader = getDocumentLoader(undefined, IPFS_GATEWAY);
async function documentLoader(url, options) {
  const file = CACHED_CONTEXTS[url];
  if (!file) return remoteLoader(url, options);
  const document = JSON.parse(fs.readFileSync(path.join(CONTEXT_DIR, file), "utf8"));
  return { contextUrl: null, document, documentUrl: url };
}

let _poseidon, _eddsa;
export async function crypto() {
  if (!_poseidon) {
    _poseidon = await buildPoseidon();
    _eddsa = await buildEddsa();
  }
  return { poseidon: _poseidon, eddsa: _eddsa, F: _poseidon.F };
}

export function leBytesToBigInt(buf) {
  let x = 0n;
  for (let i = buf.length - 1; i >= 0; i--) x = (x << 8n) | BigInt(buf[i]);
  return x;
}

/** Split a hex-encoded core claim into its 8 slots (bigint). */
export function claimSlots(hex) {
  const b = Buffer.from(hex, "hex");
  if (b.length !== 256) throw new Error(`core claim must be 256 bytes, got ${b.length}`);
  return Array.from({ length: 8 }, (_, i) => leBytesToBigInt(b.subarray(32 * i, 32 * i + 32)));
}

/** Decode the fields packed into slot i0 and v0. */
export function describeClaim(slots) {
  const i0 = slots[0];
  const mask = (n) => (1n << BigInt(n)) - 1n;
  const flags = (i0 >> 128n) & mask(32);
  const v0 = slots[4];
  return {
    schemaHash: i0 & mask(128),
    subjectPosition: Number(flags & 7n), // 2 = subject ID in index slot i1
    expirationFlag: Number((flags >> 3n) & 1n),
    updatableFlag: Number((flags >> 4n) & 1n),
    merklizedPosition: Number((flags >> 5n) & 7n), // 1 = merklized root in index slot i2
    version: Number((i0 >> 160n) & mask(32)),
    subjectId: slots[1],
    merklizedRoot: slots[2],
    revocationNonce: v0 & mask(64),
    expiration: (v0 >> 64n) & mask(64),
  };
}

export async function claimHash(slots) {
  const { poseidon, F } = await crypto();
  const hi = poseidon(slots.slice(0, 4));
  const hv = poseidon(slots.slice(4, 8));
  return F.toObject(poseidon([hi, hv]));
}

/** Issuer Baby Jubjub public key from an AuthBJJCredential core claim (slots i2, i3). */
export function issuerPublicKey(authCoreClaimHex) {
  const s = claimSlots(authCoreClaimHex);
  return { Ax: s[2], Ay: s[3] };
}

/** Unpack a 64-byte compressed BJJ signature: R8 (compressed point) || S (LE scalar). */
export async function unpackSignature(sigHex) {
  const { eddsa, F } = await crypto();
  const sig = eddsa.unpackSignature(Buffer.from(sigHex, "hex"));
  return { R8x: F.toObject(sig.R8[0]), R8y: F.toObject(sig.R8[1]), S: sig.S, raw: sig };
}

export async function verifyIssuerSignature(slots, sigHex, key) {
  const { eddsa, F } = await crypto();
  const msg = F.e(await claimHash(slots));
  const { raw } = await unpackSignature(sigHex);
  return eddsa.verifyPoseidon(msg, raw, [F.e(key.Ax), F.e(key.Ay)]);
}

/**
 * Merklize the credential (without its proof section) the way the issuer did and return the
 * inclusion proof of a field, padded to MT_LEVELS siblings.
 */
export async function merklizedField(credential, fieldPath) {
  const doc = { ...credential };
  delete doc.proof;
  const mz = await Merklizer.merklizeJSONLD(JSON.stringify(doc), { documentLoader });
  const root = (await mz.root()).bigInt();
  const path = await mz.resolveDocPath(fieldPath, { documentLoader });
  const { proof, value } = await mz.proof(path);
  if (!proof.existence) throw new Error(`${fieldPath} not found in merklized credential`);
  const siblings = proof.allSiblings().map((h) => h.bigInt());
  const depth = siblings.length; // levels actually used by this leaf
  if (depth > MT_LEVELS) throw new Error("merkle proof deeper than circuit");
  while (siblings.length < MT_LEVELS) siblings.push(0n);
  return { root, key: await path.mtEntry(), value: await value.mtEntry(), siblings, depth };
}

export function loadCredential(file) {
  const j = JSON.parse(fs.readFileSync(file, "utf8"));
  return j.credential ?? j;
}

/** Everything the liveness circuit needs from a BJJ-signed LivenessCredential. */
export async function extractLivenessWitness(credential) {
  const p = credential.proof.find((x) => x.type === "BJJSignature2021");
  if (!p) throw new Error("credential has no BJJSignature2021 proof");
  const slots = claimSlots(p.coreClaim);
  const key = issuerPublicKey(p.issuerData.authCoreClaim);
  const sig = await unpackSignature(p.signature);
  const field = await merklizedField(credential, "credentialSubject.livenessTimestamp");
  return { slots, key, sig, field, info: describeClaim(slots) };
}
