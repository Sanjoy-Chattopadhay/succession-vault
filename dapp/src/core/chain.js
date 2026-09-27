// Sepolia deployment, contract interfaces, reads that need no wallet, and error decoding.
import { ethers } from "ethers";

export const NETWORK = {
  chainId: 11155111,
  chainIdHex: "0xaa36a7",
  name: "Sepolia",
  rpc: "https://ethereum-sepolia-rpc.publicnode.com",
  explorer: "https://sepolia.etherscan.io",
};

export const ADDR = {
  factory: "0x03D47801F56f59BBec12D04d3157002538eb2BCa",
  implementation: "0x637e3C78C80C6E7FfBa3F00Fe32B43C9355EDfe2",
  registry: "0x010481ad036E1B4Ee0C8B12d0F46847bF23f484b",
  livenessVerifier: "0xEEAC7141D0f022d9634C9834B2BFD982175EA973",
  ageVerifier: "0x5b56b4DaEA313f53F7bf8a40fb27672C3E2ba616",
  collectible: "0xaC90BC097ee020F9f9a8323bb0E3F10DA13049C0",
  dollar: "0x12eEdD98d9AE04be230f1bF5f4930d4384f61321",
};
export const FACTORY_DEPLOY_BLOCK = 11782096;

export const KIND = { ETH: 0, ERC20: 1, ERC721: 2, ERC1155: 3 };
export const KIND_NAME = ["ETH", "ERC-20", "ERC-721", "ERC-1155"];
export const STATUS = ["Alive", "Grace", "Claimable", "Settled"];

const BEQUEST = "tuple(uint256 index, address heir, uint8 kind, address token, uint256 id, uint16 shareBps, uint40 notBefore, uint8 minAge, uint256 ageCommitment)";
const PROOF = "tuple(uint256[2] a, uint256[2][2] b, uint256[2] c)";

export const FACTORY_ABI = [
  "function createVault(tuple(uint32 heartbeatInterval, uint32 lifeProofInterval, uint32 gracePeriod, uint32 claimWindow, bytes32 allocationRoot, address residuary, uint256 livenessBinding) cfg, bytes32 salt) returns (address)",
  "function vaultAddress(address owner, bytes32 salt) view returns (address)",
  "event VaultCreated(address indexed owner, address indexed vault, bytes32 salt)",
];

export const VAULT_ABI = [
  "function owner() view returns (address)",
  "function lastHeartbeat() view returns (uint40)",
  "function lastLifeProof() view returns (uint40)",
  "function settled() view returns (bool)",
  "function lifeProven() view returns (bool)",
  "function residuary() view returns (address)",
  "function allocationRoot() view returns (bytes32)",
  "function heartbeatInterval() view returns (uint256)",
  "function lifeProofInterval() view returns (uint256)",
  "function gracePeriod() view returns (uint256)",
  "function claimWindow() view returns (uint256)",
  "function deadline() view returns (uint256)",
  "function claimableAt() view returns (uint256)",
  "function status() view returns (uint8)",
  "function isClaimed(uint256 index) view returns (bool)",
  "function bindingThreshold(uint256 binding) view returns (uint8)",
  "function presence() view returns (bool proven, uint40 at)",
  "function AUTH_WINDOW() view returns (uint32)",
  "function MIN_PERIOD() view returns (uint32)",
  "function REGISTRY_SPAN() view returns (uint256)",
  "function MAX_CLOCK_SKEW() view returns (uint256)",
  "function ageCutoff(uint256 timestamp, uint8 minAge) view returns (uint256)",
  "function heartbeat()",
  `function proveLife(${PROOF} p, uint256 binding, uint256 livenessTime)`,
  "function withdraw(uint8 kind, address token, uint256 id, uint256 amount, address to)",
  "function setAllocationRoot(bytes32 root)",
  "function setResiduary(address residuary)",
  `function claim(${BEQUEST} b, bytes32[] merkleProof)`,
  `function claimWithAgeProof(${BEQUEST} b, bytes32[] merkleProof, ${PROOF} p, uint256 cutoff)`,
  "function sweep(uint8 kind, address token, uint256 id)",
  "error AlreadyInitialized()", "error NotOwner()", "error VaultSettled()", "error ProofOfLifeRequired()",
  "error UnknownBinding()", "error StaleOrFutureProof()", "error InvalidProof()", "error NotClaimable()",
  "error TimeLocked()", "error InvalidBequest()", "error AlreadyClaimed()", "error InvalidShare()",
  "error AgeProofRequired()", "error AgeNotReached()", "error ClaimWindowOpen()", "error InvalidConfig()",
  "error TransferFailed()", "error ThresholdNotMet()",
];

export const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
  "function transfer(address to, uint256 amount) returns (bool)",
  "function faucet()",
];
export const ERC721_ABI = [
  "function ownerOf(uint256 id) view returns (address)",
  "function balanceOf(address) view returns (uint256)",
  "function nextId() view returns (uint256)",
  "function mint() returns (uint256)",
  "function safeTransferFrom(address from, address to, uint256 id)",
  "event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)",
];

/** Plain-language explanations of the vault's custom errors. */
export const ERROR_HELP = {
  NotOwner: "Only the vault owner can do this.",
  VaultSettled: "The vault is settled: succession has started and cannot be undone.",
  ProofOfLifeRequired: "This owner action needs a proof of life from the last 24 hours. Prove life first.",
  UnknownBinding: "The proof is for an identity or issuer this vault does not know.",
  StaleOrFutureProof: "The proof is not newer than the last one, or is dated in the future.",
  InvalidProof: "The zero-knowledge proof did not verify.",
  NotClaimable: "Not claimable yet: the owner is still alive or in the grace period.",
  TimeLocked: "This bequest is time-locked; it can be claimed later.",
  InvalidBequest: "This bequest is not part of the vault's will (wrong will package?).",
  AlreadyClaimed: "This bequest was already claimed.",
  InvalidShare: "Invalid share for this pool.",
  AgeProofRequired: "This bequest is age-restricted: claim it with an age proof.",
  AgeNotReached: "The heir is not old enough yet.",
  ClaimWindowOpen: "The claim window is still open; the sweep comes after it.",
  InvalidConfig: "Invalid settings (timers too short, or proof-of-life + grace too long for this deployment).",
  TransferFailed: "The transfer failed.",
  ThresholdNotMet: "This vault needs proofs from several issuers at once.",
};

export const readProvider = () => new ethers.providers.StaticJsonRpcProvider(NETWORK.rpc, NETWORK.chainId);
export const vaultAt = (address, runner) => new ethers.Contract(address, VAULT_ABI, runner);
export const factory = (runner) => new ethers.Contract(ADDR.factory, FACTORY_ABI, runner);

/** Human-readable reason for a failed call or transaction. */
export function explainError(err) {
  const iface = new ethers.utils.Interface(VAULT_ABI);
  const candidates = [err?.error?.data?.data, err?.error?.data, err?.data, err?.error?.error?.data, err?.data?.data];
  for (const data of candidates) {
    if (typeof data !== "string" || data.length < 10) continue;
    try {
      const e = iface.parseError(data);
      return ERROR_HELP[e.name] ?? e.name;
    } catch { /* not ours */ }
  }
  const msg = err?.reason || err?.error?.message || err?.message || String(err);
  if (/user rejected|ACTION_REJECTED/i.test(msg)) return "You rejected the transaction in your wallet.";
  if (/insufficient funds/i.test(msg)) return "Not enough Sepolia ETH for gas. Get some from a Sepolia faucet.";
  return msg.length > 220 ? msg.slice(0, 220) + "…" : msg;
}

/** Everything the dashboard shows about a vault, in one batch of reads. */
export async function readVault(address, provider = readProvider()) {
  const v = vaultAt(address, provider);
  const [owner, tH, tL, settled, proven, residuary, root, hb, lp, grace, win, deadline, claimableAt, status, block, presence, balance] =
    await Promise.all([
      v.owner(), v.lastHeartbeat(), v.lastLifeProof(), v.settled(), v.lifeProven(), v.residuary(), v.allocationRoot(),
      v.heartbeatInterval(), v.lifeProofInterval(), v.gracePeriod(), v.claimWindow(), v.deadline(), v.claimableAt(),
      v.status(), provider.getBlock("latest"), v.presence(), provider.getBalance(address),
    ]);
  const n = (x) => Number(x);
  return {
    address, owner, residuary, root, settled, proven,
    tH: n(tH), tL: n(tL), presenceAt: n(presence[1]),
    heartbeat: n(hb), lifeProof: n(lp), grace: n(grace), claimWindow: n(win),
    deadline: n(deadline), claimableAt: n(claimableAt), sweepAt: n(claimableAt) + n(win),
    status: STATUS[n(status)], chainNow: block.timestamp, balance,
  };
}

/** Vaults created by `owner` through the factory (from its events). */
export async function vaultsOf(owner, provider = readProvider()) {
  const f = factory(provider);
  const logs = await f.queryFilter(f.filters.VaultCreated(owner), FACTORY_DEPLOY_BLOCK, "latest");
  return logs.map((l) => ({ vault: l.args.vault, block: l.blockNumber, salt: l.args.salt }));
}

export const txLink = (hash) => `${NETWORK.explorer}/tx/${hash}`;
export const addrLink = (a) => `${NETWORK.explorer}/address/${a}`;
