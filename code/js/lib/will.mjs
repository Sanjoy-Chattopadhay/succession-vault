// Building a will: bequest leaves, age commitments and the OpenZeppelin Merkle tree whose root is
// stored in the vault. Leaf encoding must match BequestVault.Bequest.
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";
import { randomBytes } from "node:crypto";
import { crypto } from "./credential.mjs";

export const KIND = { ETH: 0, ERC20: 1, ERC721: 2, ERC1155: 3 };
export const LEAF_TYPES = ["uint256", "address", "uint8", "address", "uint256", "uint16", "uint40", "uint8", "uint256"];
const ZERO = "0x0000000000000000000000000000000000000000";

/** 250-bit random salt (fits the BN254 scalar field). */
export const randomSalt = () => BigInt("0x" + randomBytes(32).toString("hex")) >> 6n;

/** Poseidon(birthDate YYYYMMDD, salt) — the commitment stored in an age-restricted leaf. */
export async function ageCommitment(birthDate, salt) {
  const { poseidon, F } = await crypto();
  return F.toObject(poseidon([BigInt(birthDate), salt]));
}

/**
 * bequests: [{ heir, kind, token?, id?, shareBps?, notBefore?, minAge?, ageCommitment? }]
 * Returns the tree, its root and, per bequest, the leaf tuple and Merkle proof.
 *
 * The last leaf field is the age commitment when minAge > 0. Otherwise the vault ignores it, and it
 * carries a random blinding value: without one, a leaf holds only guessable data (heir address,
 * share, token) and the root would not hide the will from someone guessing heirs and shares.
 * Pass `blind: false` for reproducible test fixtures.
 */
export function buildWill(bequests, { blind = true } = {}) {
  const values = bequests.map((b, index) => [
    index.toString(),
    b.heir,
    b.kind,
    b.token ?? ZERO,
    (b.id ?? 0).toString(),
    b.shareBps ?? 0,
    (b.notBefore ?? 0).toString(),
    b.minAge ?? 0,
    (b.ageCommitment ?? (blind && !b.minAge ? randomSalt() : 0n)).toString(),
  ]);
  checkShares(values);
  const tree = StandardMerkleTree.of(values, LEAF_TYPES);
  return {
    tree,
    root: tree.root,
    leaves: values.map((v, i) => ({ bequest: v, proof: tree.getProof(i) })),
  };
}

/** Fungible pools must not be allocated beyond 100%; the vault enforces this again on-chain. */
function checkShares(values) {
  const pools = new Map();
  for (const v of values) {
    if (v[2] === KIND.ERC721) continue;
    const key = `${v[2]}:${v[3]}:${v[4]}`;
    pools.set(key, (pools.get(key) ?? 0) + Number(v[5]));
  }
  for (const [pool, bps] of pools) {
    if (bps > 10_000) throw new Error(`pool ${pool} allocated ${bps} bps (> 10000)`);
  }
}
