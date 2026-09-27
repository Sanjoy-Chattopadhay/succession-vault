// Groth16 proving helpers (snarkjs) and Solidity calldata formatting.
import * as snarkjs from "snarkjs";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), "../..");

/** @param dir circuit artifact directory relative to the repository root */
export async function prove(circuit, input, dir = "zk/build") {
  const build = (f) => path.join(ROOT, dir, f);
  const t0 = performance.now();
  const { proof, publicSignals } = await snarkjs.groth16.fullProve(
    input, build(`${circuit}_js/${circuit}.wasm`), build(`${circuit}.zkey`));
  const ms = performance.now() - t0;
  const vkey = JSON.parse(fs.readFileSync(build(`${circuit}_vkey.json`), "utf8"));
  const ok = await snarkjs.groth16.verify(vkey, publicSignals, proof);
  if (!ok) throw new Error(`${circuit}: proof does not verify`);
  return { proof, publicSignals, ms, calldata: toSolidity(proof, publicSignals) };
}

/** snarkjs proof -> the (a, b, c, pub) arguments of the generated Solidity verifier. */
export function toSolidity(proof, publicSignals) {
  return {
    a: [proof.pi_a[0], proof.pi_a[1]],
    b: [[proof.pi_b[0][1], proof.pi_b[0][0]], [proof.pi_b[1][1], proof.pi_b[1][0]]],
    c: [proof.pi_c[0], proof.pi_c[1]],
    pub: publicSignals,
  };
}

/** snarkjs keeps worker threads alive; call when done. */
export async function shutdown() {
  if (globalThis.curve_bn128) await globalThis.curve_bn128.terminate();
}
