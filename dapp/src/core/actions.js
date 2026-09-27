// High-level vault actions. The UI calls them with the wallet's signer; the tests with a local key.
// Every write is simulated first (callStatic), so a revert is explained before any gas is spent.
import { ethers } from "ethers";
import { ADDR, KIND, factory, vaultAt, explainError, ERC20_ABI, ERC721_ABI } from "./chain.js";
import { demoIssuer, bindingOf, issueLivenessCredential, livenessInput, prove, ageCutoff } from "./zk.js";
import { buildWill, toStruct } from "./will.js";

export class ActionError extends Error {}

async function send(contract, fn, args = [], overrides = {}) {
  try {
    await contract.callStatic[fn](...args, overrides);
  } catch (e) {
    throw new ActionError(explainError(e));
  }
  try {
    const tx = await contract[fn](...args, overrides);
    return tx;
  } catch (e) {
    throw new ActionError(explainError(e));
  }
}

/**
 * Create a vault whose will is `bequests`. Returns the vault address, the built will (with heirs'
 * age secrets) and the transaction. The address is known before creation, so assets can even be
 * sent ahead of time.
 */
export async function createVault(signer, { timers, residuary, bequests }, identity) {
  if (!bequests.length) throw new ActionError("Add at least one bequest.");
  const issuer = await demoIssuer();
  const will = buildWill(bequests);
  const salt = ethers.utils.hexlify(ethers.utils.randomBytes(32));
  const cfg = {
    heartbeatInterval: timers.heartbeat,
    lifeProofInterval: timers.lifeProof,
    gracePeriod: timers.grace,
    claimWindow: timers.claimWindow,
    allocationRoot: will.root,
    residuary,
    livenessBinding: bindingOf(issuer, identity).toString(),
  };
  const f = factory(signer);
  const owner = await signer.getAddress();
  const vault = await f.vaultAddress(owner, salt);
  const tx = await send(f, "createVault", [cfg, salt]);
  return { vault, will, salt, tx };
}

export const heartbeat = (signer, vault) => send(vaultAt(vault, signer), "heartbeat");

/**
 * Proof of life: the demo issuer performs the "liveness check" and signs a credential dated at the
 * chain's current time; the browser proves in zero knowledge that such a credential exists for the
 * vault's binding. Only (binding, time) and the proof reach the chain.
 */
export async function proveLife(signer, vault, identity, snarkjs, circuits, onStep = () => {}) {
  const v = vaultAt(vault, signer);
  const [block, tL] = await Promise.all([signer.provider.getBlock("latest"), v.lastLifeProof()]);
  const ts = Math.max(block.timestamp, Number(tL) + 1);
  onStep("issuer");
  const issuer = await demoIssuer();
  const cred = await issueLivenessCredential(issuer, identity, ts);
  onStep("prove");
  const p = await prove(snarkjs, livenessInput(issuer, identity, cred), circuits.livenessWasm, circuits.livenessZkey);
  onStep("send", p.ms);
  const [binding, time] = p.publicSignals;
  const tx = await send(v, "proveLife", [p.calldata, binding, time]);
  return { tx, provingMs: p.ms, livenessTime: Number(time) };
}

export const depositEth = (signer, vault, ether) =>
  signer.sendTransaction({ to: vault, value: ethers.utils.parseEther(String(ether)) }).catch((e) => { throw new ActionError(explainError(e)); });

export async function dollarFaucet(signer) {
  return send(new ethers.Contract(ADDR.dollar, ERC20_ABI, signer), "faucet");
}

export async function depositDollars(signer, vault, amount) {
  const t = new ethers.Contract(ADDR.dollar, ERC20_ABI, signer);
  return send(t, "transfer", [vault, ethers.utils.parseUnits(String(amount), 6)]);
}

/** Mint a demo collectible to the caller and return its id (from the Transfer event). */
export async function mintCollectible(signer) {
  const nft = new ethers.Contract(ADDR.collectible, ERC721_ABI, signer);
  const tx = await send(nft, "mint");
  const rc = await tx.wait();
  const ev = rc.events?.find((e) => e.event === "Transfer") ??
    rc.logs.map((l) => { try { return nft.interface.parseLog(l); } catch { return null; } }).find((x) => x?.name === "Transfer");
  return { tx, id: (ev.args?.tokenId ?? ev.args[2]).toString() };
}

export async function depositCollectible(signer, vault, id) {
  const nft = new ethers.Contract(ADDR.collectible, ERC721_ABI, signer);
  return send(nft, "safeTransferFrom", [await signer.getAddress(), vault, id]);
}

export const withdraw = (signer, vault, { kind, token, id, amount, to }) =>
  send(vaultAt(vault, signer), "withdraw", [kind, token ?? ethers.constants.AddressZero, id ?? 0, amount, to]);

/** Claim one bequest from a will package. Age-restricted leaves get an age proof in the browser. */
export async function claim(signer, vault, entry, snarkjs, circuits) {
  const v = vaultAt(vault, signer);
  const b = toStruct(entry.bequest);
  if (b.minAge === 0) return { tx: await send(v, "claim", [b, entry.proof]) };
  if (!entry.ageSecret) throw new ActionError("This bequest is age-restricted, but the package has no age secret.");
  const block = await signer.provider.getBlock("latest");
  const cutoff = ageCutoff(block.timestamp, b.minAge);
  if (entry.ageSecret.birthDate > cutoff) throw new ActionError(`The heir is not ${b.minAge} yet.`);
  const p = await prove(snarkjs, {
    birthDate: String(entry.ageSecret.birthDate), salt: entry.ageSecret.salt,
    commitment: b.ageCommitment, cutoff: String(cutoff),
  }, circuits.ageWasm, circuits.ageZkey);
  return { tx: await send(v, "claimWithAgeProof", [b, entry.proof, p.calldata, cutoff]), provingMs: p.ms };
}

export const sweep = (signer, vault, { kind, token, id }) =>
  send(vaultAt(vault, signer), "sweep", [kind, token ?? ethers.constants.AddressZero, id ?? 0]);

export { KIND };
