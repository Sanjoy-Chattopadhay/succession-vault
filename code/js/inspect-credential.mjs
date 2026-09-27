// Usage: node js/inspect-credential.mjs <credential.json>
// Checks that a Privado ID / Billions LivenessCredential can be verified the way the circuit will:
// issuer EdDSA-Poseidon signature over the core claim, and the merklized livenessTimestamp.
import {
  loadCredential, claimSlots, describeClaim, issuerPublicKey,
  verifyIssuerSignature, merklizedField, claimHash,
} from "./lib/credential.mjs";

const file = process.argv[2];
if (!file) { console.error("usage: node js/inspect-credential.mjs <credential.json>"); process.exit(1); }
const cred = loadCredential(file);
const p = cred.proof.find((x) => x.type === "BJJSignature2021");
const slots = claimSlots(p.coreClaim);
const info = describeClaim(slots);
const key = issuerPublicKey(p.issuerData.authCoreClaim);
const hex = (x) => "0x" + x.toString(16);

console.log("credential       :", cred.id, `(${cred.type.join(", ")})`);
console.log("issuer           :", cred.issuer);
console.log("schema hash      :", hex(info.schemaHash));
console.log("flags            : subjectPos=%d expiration=%d updatable=%d merklized=%d version=%d",
  info.subjectPosition, info.expirationFlag, info.updatableFlag, info.merklizedPosition, info.version);
console.log("claim slot i0    :", hex(slots[0]));
console.log("subject id (i1)  :", hex(info.subjectId));
console.log("revocation nonce :", info.revocationNonce.toString(), "(credential says", cred.credentialStatus.revocationNonce + ")");
console.log("expiration       :", new Date(Number(info.expiration) * 1000).toISOString(), "(credential says", cred.expirationDate + ")");
console.log("issuer key Ax    :", hex(key.Ax));
console.log("issuer key Ay    :", hex(key.Ay));
console.log("claim hash       :", hex(await claimHash(slots)));

const ok = await verifyIssuerSignature(slots, p.signature, key);
console.log("\nissuer signature :", ok ? "VALID" : "INVALID");

const f = await merklizedField(cred, "credentialSubject.livenessTimestamp");
console.log("merklized root   :", hex(f.root), f.root === info.merklizedRoot ? "== claim slot i2 (MATCH)" : "!= claim slot i2 (MISMATCH)");
console.log("livenessTs key   :", hex(f.key));
console.log("livenessTs value :", f.value.toString(), "=", new Date(Number(f.value) * 1000).toISOString());
console.log("non-zero siblings:", f.siblings.filter((s) => s !== 0n).length, "of", f.siblings.length);
