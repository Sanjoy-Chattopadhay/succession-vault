// Creates demo vaults on Sepolia with the app's own actions (the same code the UI runs), for
// screenshots and manual testing:
//   alive   relaxed timers; funded with an NFT, demo dollars and ETH; proven alive
//   claims  one-minute timers, so it turns claimable two minutes after its proof of life
// Needs a funded Sepolia test key in PRIVATE_KEY (or PRIVATE_KEY=... in ../code/.env); the key is
// never printed. Writes vault backups and per-heir will packages to tools/out/ (git-ignored: a backup
// lets anyone prove life for its vault with the public demo issuer).
//   node tools/seed-demo.mjs create     both vaults
//   node tools/seed-demo.mjs claim      once "claims" is claimable: three of its four bequests
//   node tools/seed-demo.mjs sweep      after its claim window: ETH leftovers to the residuary
//   node tools/seed-demo.mjs heartbeat  keeps "alive" alive (key clock only)
//   node tools/seed-demo.mjs status
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import * as snarkjs from "snarkjs";
import { ethers } from "ethers";
import { ADDR, KIND, NETWORK, readVault, ERC20_ABI } from "../src/core/chain.js";
import * as A from "../src/core/actions.js";
import { newIdentity } from "../src/core/zk.js";
import { willPackage, heirsOf } from "../src/core/will.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const OUT = path.join(HERE, "out");
const CIRCUITS = path.join(HERE, "..", "public", "circuits");
const circuits = {
  livenessWasm: path.join(CIRCUITS, "liveness.wasm"), livenessZkey: path.join(CIRCUITS, "liveness.zkey"),
  ageWasm: path.join(CIRCUITS, "age.wasm"), ageZkey: path.join(CIRCUITS, "age.zkey"),
};

function privateKey() {
  if (process.env.PRIVATE_KEY) return process.env.PRIVATE_KEY.trim();
  const env = path.resolve(HERE, "..", "..", "code", ".env");
  const m = fs.existsSync(env) && fs.readFileSync(env, "utf8").match(/^\s*PRIVATE_KEY\s*=\s*"?([0-9a-fA-Fx]+)"?/m);
  if (!m) throw new Error("Set PRIVATE_KEY to a funded Sepolia test key.");
  return m[1];
}

const provider = new ethers.providers.StaticJsonRpcProvider(NETWORK.rpc, NETWORK.chainId);
const wallet = new ethers.Wallet(privateKey(), provider);
const minutes = (h, l, g, c) => ({ heartbeat: h * 60, lifeProof: l * 60, grace: g * 60, claimWindow: c * 60 });
const save = (name, obj) => fs.writeFileSync(path.join(OUT, name), JSON.stringify(obj, null, 2));
const load = (name) => JSON.parse(fs.readFileSync(path.join(OUT, name), "utf8"));
const step = async (label, promise) => {
  const out = await promise;
  const tx = out?.hash ? out : out.tx;
  const rc = await tx.wait();
  console.log(`  ${label.padEnd(34)} ${tx.hash}  gas ${rc.gasUsed}`);
  return { ...out, receipt: rc };
};

async function createDemo(label, timers, deposit) {
  console.log(`vault "${label}"`);
  const heirA = ethers.Wallet.createRandom().address;
  const heirB = ethers.Wallet.createRandom().address;
  const residuary = ethers.Wallet.createRandom().address;
  const { id: nftId } = await step("mint demo NFT", A.mintCollectible(wallet));
  const bequests = [
    { heir: heirA, kind: KIND.ERC721, token: ADDR.collectible, id: nftId },
    { heir: heirA, kind: KIND.ERC20, token: ADDR.dollar, shareBps: deposit.splitA },
    { heir: heirB, kind: KIND.ERC20, token: ADDR.dollar, shareBps: 10_000 - deposit.splitA, minAge: 18, birthDate: 20010405 },
    { heir: heirB, kind: KIND.ETH, shareBps: deposit.ethShare },
  ];
  const identity = newIdentity();
  const created = await step("create vault", A.createVault(wallet, { timers, residuary, bequests }, identity));
  const record = { vault: created.vault, owner: wallet.address, identity, will: created.will, timers, createdAt: Math.floor(Date.now() / 1000), tx: created.tx.hash };
  save(`${label}-record.json`, record);
  for (const h of heirsOf(created.will)) save(`${label}-heir-${h.slice(2, 8)}.json`, willPackage(created.vault, created.will, h));
  await step(`deposit NFT #${nftId}`, A.depositCollectible(wallet, created.vault, nftId));
  await step(`deposit ${deposit.dusd} DUSD`, A.depositDollars(wallet, created.vault, deposit.dusd));
  await step(`deposit ${deposit.eth} ETH`, A.depositEth(wallet, created.vault, deposit.eth));
  await step("heartbeat", A.heartbeat(wallet, created.vault));
  const pol = await step("proof of life (in-process Groth16)", A.proveLife(wallet, created.vault, identity, snarkjs, circuits));
  console.log(`  proving took ${pol.provingMs} ms; vault ${created.vault}`);
  return record;
}

const cmd = process.argv[2] ?? "status";
fs.mkdirSync(OUT, { recursive: true });
console.log(`wallet ${wallet.address}, balance ${ethers.utils.formatEther(await wallet.getBalance())} ETH`);

if (cmd === "create") {
  const dusd = new ethers.Contract(ADDR.dollar, ERC20_ABI, provider);
  if ((await dusd.balanceOf(wallet.address)).lt(ethers.utils.parseUnits("800", 6))) await step("demo dollar faucet", A.dollarFaucet(wallet));
  await createDemo("alive", minutes(20, 60, 15, 60), { dusd: 500, eth: "0.002", splitA: 6000, ethShare: 10_000 });
  await createDemo("claims", minutes(1, 2, 1, 5), { dusd: 300, eth: "0.001", splitA: 7000, ethShare: 5000 });
} else if (cmd === "claim") {
  const { vault, will } = load("claims-record.json");
  for (const h of heirsOf(will)) {
    const pkg = load(`claims-heir-${h.slice(2, 8)}.json`);
    for (const entry of pkg.bequests) {
      if (Number(entry.bequest[2]) === KIND.ETH) continue; // left for the sweep
      const r = await step(`claim bequest ${entry.bequest[0]}${entry.ageSecret ? " (age proof)" : ""}`, A.claim(wallet, vault, entry, snarkjs, circuits));
      if (r.provingMs) console.log(`  age proof took ${r.provingMs} ms`);
    }
  }
} else if (cmd === "heartbeat") {
  await step("heartbeat (alive)", A.heartbeat(wallet, load("alive-record.json").vault));
} else if (cmd === "sweep") {
  const { vault } = load("claims-record.json");
  await step("sweep ETH to the residuary", A.sweep(wallet, vault, { kind: KIND.ETH }));
}

for (const label of ["alive", "claims"]) {
  if (!fs.existsSync(path.join(OUT, `${label}-record.json`))) continue;
  const s = await readVault(load(`${label}-record.json`).vault, provider);
  const at = (t) => new Date(t * 1000).toLocaleTimeString();
  console.log(`${label.padEnd(7)} ${s.address} ${s.status.padEnd(9)} deadline ${at(s.deadline)}, claimable ${at(s.claimableAt)}, sweep ${at(s.sweepAt)}`);
}
if (globalThis.curve_bn128) await globalThis.curve_bn128.terminate();
process.exit(0);
