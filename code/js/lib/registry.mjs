// Off-chain side of the aggregated liveness registry: the Poseidon enrollment tree and the
// witness builders for circuits/enroll.circom and circuits/lib/batch.circom.
import { crypto, extractLivenessWitness } from "./credential.mjs";
import { issueLivenessCredential, subjectIdFor } from "./test-issuer.mjs";

export const ENROLL_LEVELS = 16;      // must match circuits/enroll.circom and batch-setup.sh
export const BITS_PER_WORD = 248n;    // must match BITS_PER_WORD in circuits/lib/batch.circom

/** Fixed-depth binary Merkle tree over Poseidon(2); empty positions hold 0. */
export class PoseidonTree {
  static async create(levels = ENROLL_LEVELS) {
    const { poseidon, F } = await crypto();
    const h = (a, b) => F.toObject(poseidon([a, b]));
    // zeros[i] = root of an empty subtree of height i
    const zeros = [0n];
    for (let i = 0; i < levels; i++) zeros.push(h(zeros[i], zeros[i]));
    return new PoseidonTree(levels, h, zeros);
  }

  constructor(levels, h, zeros) {
    this.levels = levels;
    this.h = h;
    this.zeros = zeros;
    this.leaves = new Map(); // index -> leaf, sparse
  }

  /** Root of the all-zero tree; the value the registry is deployed with. */
  get emptyRoot() {
    return this.zeros[this.levels];
  }

  _node(level, index) {
    if (level === 0) return this.leaves.get(index) ?? 0n;
    const l = this._node(level - 1, 2 * index);
    const r = this._node(level - 1, 2 * index + 1);
    if (l === 0n && r === 0n) return this.zeros[level];
    return this.h(l, r);
  }

  get root() {
    return this._node(this.levels, 0);
  }

  /** Sibling hashes from the leaf upwards, as the circuit consumes them. */
  siblings(index) {
    const out = [];
    for (let level = 0; level < this.levels; level++) {
      const node = index >> level;
      out.push(this._node(level, node ^ 1));
    }
    return out;
  }

  /**
   * Insert `leaf` at `index` and return everything the enrollment circuit needs. The siblings are
   * the same before and after, which is exactly what makes "no other slot changed" checkable.
   */
  insert(index, leaf) {
    if ((this.leaves.get(index) ?? 0n) !== 0n) throw new Error(`slot ${index} already taken`);
    const oldRoot = this.root;
    const siblings = this.siblings(index);
    this.leaves.set(index, leaf);
    return { oldRoot, newRoot: this.root, index, binding: leaf, siblings };
  }
}

/** Pack presence bits into 248-bit words, the layout the circuit and the registry agree on. */
export function packPresence(presentIndices, words) {
  const out = new Array(words).fill(0n);
  for (const i of presentIndices) {
    const w = Math.floor(i / Number(BITS_PER_WORD));
    if (w >= words) throw new Error(`index ${i} outside ${words} presence words`);
    out[w] |= 1n << BigInt(i % Number(BITS_PER_WORD));
  }
  return out;
}

/** A synthetic cohort member: its own DID salt, hence its own binding. */
export async function makePrincipal(issuer, name) {
  const { poseidon, F } = await crypto();
  const subjectId = subjectIdFor(name);
  const didSalt = BigInt("0x" + Buffer.from(name.padEnd(30, "!")).toString("hex").slice(0, 60));
  const binding = F.toObject(poseidon([issuer.Ax, issuer.Ay, subjectId, didSalt]));
  return { name, subjectId, subjectDid: `did:iden3:privado:test:${name}`, didSalt, binding };
}

/** Per-principal inputs of ProofOfLifeEnabled, padded to `mtLevels` merklization siblings. */
export async function livenessInputs(issuer, principal, livenessTimestamp, mtLevels) {
  const cred = await issueLivenessCredential(issuer, {
    subjectId: principal.subjectId,
    subjectDid: principal.subjectDid,
    livenessTimestamp,
  });
  const w = await extractLivenessWitness(cred);
  if (w.field.depth > mtLevels) {
    throw new Error(`credential merklization depth ${w.field.depth} exceeds circuit depth ${mtLevels}`);
  }
  // extractLivenessWitness pads to 40; a shallower circuit takes the first mtLevels siblings,
  // which is sound because the trailing entries are zero for every credential we accept.
  const tsSiblings = w.field.siblings.slice(0, mtLevels).map(String);
  return {
    claim: w.slots.map(String),
    issuerAx: w.key.Ax.toString(),
    issuerAy: w.key.Ay.toString(),
    sigR8x: w.sig.R8x.toString(),
    sigR8y: w.sig.R8y.toString(),
    sigS: w.sig.S.toString(),
    livenessTimestamp: String(livenessTimestamp),
    tsSiblings,
    didSalt: principal.didSalt.toString(),
  };
}

/** All-zero inputs for a slot that is not attesting in this epoch. */
export function absentInputs(mtLevels) {
  return {
    claim: Array(8).fill("0"),
    issuerAx: "0", issuerAy: "0", sigR8x: "0", sigR8y: "0", sigS: "0",
    livenessTimestamp: "0",
    tsSiblings: Array(mtLevels).fill("0"),
    didSalt: "0",
  };
}

/**
 * Assemble the EpochAttestation witness.
 * @param members [{ inputs, enrollSiblings, present }] in slot order, length N
 */
export function epochInput({ enrollRoot, base = 0, epochStart, epochEnd, words, members, mtLevels }) {
  const present = members.flatMap((m, i) => (m.present ? [i] : []));
  const input = {
    enrollRoot: enrollRoot.toString(),
    base: String(base),
    epochStart: String(epochStart),
    epochEnd: String(epochEnd),
    presence: packPresence(present, words).map(String),
    claim: [], issuerAx: [], issuerAy: [], sigR8x: [], sigR8y: [], sigS: [],
    livenessTimestamp: [], tsSiblings: [], didSalt: [], enrollSiblings: [],
  };
  for (const m of members) {
    const v = m.present ? m.inputs : absentInputs(mtLevels);
    input.claim.push(v.claim);
    input.issuerAx.push(v.issuerAx);
    input.issuerAy.push(v.issuerAy);
    input.sigR8x.push(v.sigR8x);
    input.sigR8y.push(v.sigR8y);
    input.sigS.push(v.sigS);
    input.livenessTimestamp.push(v.livenessTimestamp);
    input.tsSiblings.push(v.tsSiblings);
    input.didSalt.push(v.didSalt);
    input.enrollSiblings.push(m.enrollSiblings.map(String));
  }
  return input;
}
