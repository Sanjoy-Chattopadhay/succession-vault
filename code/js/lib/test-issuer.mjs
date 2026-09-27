// A local attestation issuer that mints LivenessCredentials in exactly the format of the
// Privado ID / Billions issuer (same JSON-LD context, claim layout and BJJSignature2021 proof).
// Used for tests and benchmarks, where credentials with arbitrary liveness times are needed.
import { createHash } from "node:crypto";
import { crypto, merklizedField, leBytesToBigInt } from "./credential.mjs";

const LIVENESS_CLAIM_I0 = 0x2aad090f03bc9fcb197e0259ff687cbcacn;
// Slot i0 of an AuthBJJCredential claim (schema hash bytes as they appear in real credentials).
const AUTH_BJJ_SCHEMA_I0 = leBytesToBigInt(Buffer.from("cca3371a6cb1b715004407e325bd993c", "hex"));
const DAY = 86_400;

const toLe32 = (x) => {
  const b = Buffer.alloc(32);
  for (let i = 0; i < 32; i++) { b[i] = Number(x & 0xffn); x >>= 8n; }
  return b;
};
const slotsToHex = (slots) => Buffer.concat(slots.map(toLe32)).toString("hex");
const beBytesToBigInt = (buf) => BigInt("0x" + Buffer.from(buf).toString("hex"));

export async function makeIssuer(seed) {
  const { eddsa, F } = await crypto();
  const prv = createHash("sha256").update(`bequest-test-issuer:${seed}`).digest();
  const pub = eddsa.prv2pub(prv);
  return { prv, Ax: F.toObject(pub[0]), Ay: F.toObject(pub[1]), did: `did:iden3:privado:test:issuer-${seed}` };
}

/** Deterministic 31-byte iden3-style subject ID for a test identity. */
export function subjectIdFor(name) {
  return beBytesToBigInt(createHash("sha256").update(`bequest-test-subject:${name}`).digest().subarray(0, 31));
}

export async function issueLivenessCredential(issuer, { subjectId, subjectDid, livenessTimestamp, revocationNonce = 1n }) {
  const { poseidon, eddsa, F } = await crypto();
  const issued = new Date(livenessTimestamp * 1000);
  const expires = new Date((livenessTimestamp + 90 * DAY) * 1000);
  const doc = {
    id: `urn:uuid:00000000-0000-4000-8000-${String(livenessTimestamp).padStart(12, "0")}`,
    "@context": [
      "https://www.w3.org/2018/credentials/v1",
      "https://schema.iden3.io/core/jsonld/iden3proofs.jsonld",
      "ipfs://QmcomGJQwJDCg3RE6FjsFYCjjMSTWJXY3fUWeq43Mc5CCJ",
    ],
    type: ["VerifiableCredential", "LivenessCredential"],
    expirationDate: expires.toISOString().replace(".000Z", "Z"),
    issuanceDate: issued.toISOString(),
    credentialSubject: { captureMethod: "activePhoto", id: subjectDid, livenessTimestamp, type: "LivenessCredential" },
    issuer: issuer.did,
    credentialSchema: { id: "ipfs://QmRXMVfuizWNaLEtiAyvGzNmanNDfQaPXHqdDTCuP2o7Xo", type: "JsonSchema2023" },
  };
  const { root } = await merklizedField(doc, "credentialSubject.livenessTimestamp");
  const expiration = BigInt(livenessTimestamp + 90 * DAY);
  const slots = [LIVENESS_CLAIM_I0, subjectId, root, 0n, revocationNonce | (expiration << 64n), 0n, 0n, 0n];
  const hi = poseidon(slots.slice(0, 4));
  const hv = poseidon(slots.slice(4, 8));
  const sig = eddsa.signPoseidon(issuer.prv, poseidon([hi, hv]));
  const authSlots = [AUTH_BJJ_SCHEMA_I0, 0n, issuer.Ax, issuer.Ay, 0n, 0n, 0n, 0n];
  return {
    ...doc,
    proof: [{
      type: "BJJSignature2021",
      issuerData: { id: issuer.did, authCoreClaim: slotsToHex(authSlots) },
      coreClaim: slotsToHex(slots),
      signature: Buffer.from(eddsa.packSignature(sig)).toString("hex"),
    }],
  };
}
