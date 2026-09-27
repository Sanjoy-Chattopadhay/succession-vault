// Wills as Merkle trees of bequests (OpenZeppelin StandardMerkleTree, the vault's leaf encoding),
// and the "will package" files owners hand to heirs.
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";
import { KIND } from "./chain.js";
import { ageCommitment, randomSalt } from "./zk.js";

export const LEAF_TYPES = ["uint256", "address", "uint8", "address", "uint256", "uint16", "uint40", "uint8", "uint256"];
const ZERO = "0x0000000000000000000000000000000000000000";

/**
 * bequests: [{ heir, kind, token?, id?, shareBps?, notBefore?, minAge?, birthDate? }]
 * Non-age leaves carry a random blinding value, so the root does not reveal guessable wills.
 * Returns { root, leaves: [{ bequest, proof, secret? }] }; `secret` is the heir's age secret.
 */
export function buildWill(bequests) {
  const secrets = [];
  const values = bequests.map((b, index) => {
    let last;
    if (b.minAge > 0) {
      const salt = randomSalt();
      secrets[index] = { birthDate: Number(b.birthDate), salt: salt.toString() };
      last = ageCommitment(b.birthDate, salt);
    } else {
      last = randomSalt();
    }
    return [
      String(index), b.heir, b.kind, b.token ?? ZERO, String(b.id ?? 0), b.shareBps ?? 0,
      String(b.notBefore ?? 0), b.minAge ?? 0, last.toString(),
    ];
  });
  checkShares(values);
  const tree = StandardMerkleTree.of(values, LEAF_TYPES);
  return {
    root: tree.root,
    leaves: values.map((v, i) => ({ bequest: v, proof: tree.getProof(i), secret: secrets[i] })),
  };
}

function checkShares(values) {
  const pools = new Map();
  for (const v of values) {
    if (v[2] === KIND.ERC721) continue;
    const key = `${v[2]}:${v[3]}:${v[4]}`;
    pools.set(key, (pools.get(key) ?? 0) + Number(v[5]));
  }
  for (const [, bps] of pools) if (bps > 10_000) throw new Error("A pool is allocated beyond 100%.");
}

/** Leaf tuple -> the Bequest struct the contract takes. */
export const toStruct = (v) => ({
  index: v[0], heir: v[1], kind: Number(v[2]), token: v[3], id: v[4], shareBps: Number(v[5]),
  notBefore: v[6], minAge: Number(v[7]), ageCommitment: v[8],
});

/**
 * The file an owner gives to heirs: everything needed to claim, nothing about the owner's identity.
 * With `heir`, only that heir's bequests (and age secrets) are included, so heirs do not learn each
 * other's shares or birth dates.
 */
export function willPackage(vault, will, heir) {
  const mine = (l) => !heir || l.bequest[1].toLowerCase() === heir.toLowerCase();
  return {
    format: "succession-vault-will/1",
    network: "sepolia",
    vault,
    root: will.root,
    ...(heir ? { heir } : {}),
    bequests: will.leaves.filter(mine).map((l) => ({ bequest: l.bequest, proof: l.proof, ...(l.secret ? { ageSecret: l.secret } : {}) })),
  };
}

/** Distinct heirs of a will, in order of appearance. */
export const heirsOf = (will) => [...new Set(will.leaves.map((l) => l.bequest[1]))];

export function parseWillPackage(json) {
  const p = typeof json === "string" ? JSON.parse(json) : json;
  if (p.format !== "succession-vault-will/1" || !p.vault || !Array.isArray(p.bequests)) {
    throw new Error("This is not a will package from this app.");
  }
  return p;
}
