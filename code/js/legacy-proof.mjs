// Real Groth16 proof for the legacy baseline's age circuit (its own wasm/zkey), used by the
// baseline gas benchmark so that the legacy design is measured without mock verifiers.
import fs from "node:fs";
import * as snarkjs from "snarkjs";
import { toSolidity, shutdown } from "./lib/zk.mjs";

const D = "test/legacy/zk";
// Legacy commitment = birthYear + salt + willId; willId is 0 for each owner's first will.
const input = { birthYear: 2000, salt: 12345, willId: 0, minimumAge: 18, currentYear: 2034, commitment: 2000 + 12345 };
const { proof, publicSignals } = await snarkjs.groth16.fullProve(input, `${D}/ageVerification.wasm`, `${D}/circuit_final.zkey`);
const ok = await snarkjs.groth16.verify(JSON.parse(fs.readFileSync(`${D}/verification_key.json`, "utf8")), publicSignals, proof);
fs.writeFileSync(`${D}/proof.json`, JSON.stringify({ ...toSolidity(proof, publicSignals), commitment: String(input.commitment) }, null, 2));
console.log("legacy age proof verifies:", ok, "public signals:", publicSignals.join(", "));
await shutdown();
process.exit(ok ? 0 : 1);
