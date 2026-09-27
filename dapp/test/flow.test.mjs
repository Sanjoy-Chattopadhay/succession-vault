// Full app flow against a local Anvil chain with the same contracts, using the exact actions the UI
// calls: create a vault with an NFT, a DUSD pool, an age-gated bequest and ETH; heartbeat; prove
// life in zero knowledge; owner withdrawal; let the owner "die"; heirs claim; sweep.
//   anvil &   (then) node test/flow.test.mjs <deployments/31337.json> <collectible> <dollar>
import * as snarkjs from "snarkjs";
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import { ethers } from "ethers";
import { ADDR, readVault, KIND } from "../src/core/chain.js";
import * as A from "../src/core/actions.js";
import { newIdentity } from "../src/core/zk.js";
import { willPackage, heirsOf, parseWillPackage } from "../src/core/will.js";

const [depFile, collectible, dollar] = process.argv.slice(2);
const dep = JSON.parse(fs.readFileSync(depFile, "utf8"));
Object.assign(ADDR, { factory: dep.factory, implementation: dep.vaultImplementation, collectible, dollar });

const C = new URL("../public/circuits/", import.meta.url);
const f = (x) => fileURLToPath(new URL(x, C));
const circuits = { livenessWasm: f("liveness.wasm"), livenessZkey: f("liveness.zkey"), ageWasm: f("age.wasm"), ageZkey: f("age.zkey") };

const provider = new ethers.providers.JsonRpcProvider("http://127.0.0.1:8545");
const keys = [
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", // anvil #0: owner
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d", // anvil #1: relayer
];
const owner = new ethers.Wallet(keys[0], provider);
const relayer = new ethers.Wallet(keys[1], provider);
const heirA = ethers.Wallet.createRandom().address;
const heirB = ethers.Wallet.createRandom().address;
const residuary = ethers.Wallet.createRandom().address;
const warp = async (s) => { await provider.send("evm_increaseTime", [s]); await provider.send("evm_mine", []); };
let failures = 0;
const check = (name, ok) => { console.log(`${ok ? "PASS" : "FAIL"}  ${name}`); if (!ok) failures++; };

// --- assets and will
await (await A.dollarFaucet(owner)).wait();
const { id: nftId } = await A.mintCollectible(owner);
const identity = newIdentity();
const timers = { heartbeat: 5 * 60, lifeProof: 30 * 60, grace: 5 * 60, claimWindow: 15 * 60 };
const bequests = [
  { heir: heirA, kind: KIND.ERC721, token: collectible, id: nftId },
  { heir: heirA, kind: KIND.ERC20, token: dollar, shareBps: 6000 },
  { heir: heirB, kind: KIND.ERC20, token: dollar, shareBps: 4000, minAge: 18, birthDate: 19990505 },
  { heir: heirB, kind: KIND.ETH, shareBps: 10000 },
];
const { vault, will, tx } = await A.createVault(owner, { timers, residuary, bequests }, identity);
await tx.wait();
check("vault created at the predicted address", (await provider.getCode(vault)).length > 2);
await (await A.depositCollectible(owner, vault, nftId)).wait();
await (await A.depositDollars(owner, vault, 500)).wait();
await (await A.depositEth(owner, vault, 1)).wait();

let s = await readVault(vault, provider);
check("fresh vault is Alive, not yet proven", s.status === "Alive" && !s.proven);

// --- owner actions need a proof of life first
let err = "";
try { await A.withdraw(owner, vault, { kind: KIND.ETH, amount: 1, to: owner.address }); } catch (e) { err = e.message; }
check("withdrawal without a proof of life is refused (explained)", /proof of life/i.test(err));

await (await A.heartbeat(owner, vault)).wait();
const pol = await A.proveLife(relayer, vault, identity, snarkjs, circuits);   // anyone may relay
await pol.tx.wait();
s = await readVault(vault, provider);
check(`proof of life accepted from a relayer (proving ${pol.provingMs} ms)`, s.proven && s.tL === pol.livenessTime);
await (await A.withdraw(owner, vault, { kind: KIND.ETH, amount: ethers.utils.parseEther("0.25"), to: owner.address })).wait();
check("owner withdrawal with a fresh proof works", true);

// --- heirs cannot claim while the owner is alive
const pkgA = parseWillPackage(JSON.stringify(willPackage(vault, will, heirA)));
const pkgB = parseWillPackage(JSON.stringify(willPackage(vault, will, heirB)));
check("per-heir packages hold only that heir's bequests", pkgA.bequests.length === 2 && pkgB.bequests.length === 2 && heirsOf(will).length === 2);
check("heir A's package has no age secret of heir B", !JSON.stringify(pkgA).includes("ageSecret"));
err = "";
try { await A.claim(relayer, vault, pkgA.bequests[0], snarkjs, circuits); } catch (e) { err = e.message; }
check("claim while Alive is refused (explained)", /not claimable/i.test(err));

// --- a key holder keeps heartbeating after the owner's last proof: the deadline stays bounded
for (let i = 0; i < 6; i++) { await warp(4 * 60); await (await A.heartbeat(owner, vault)).wait(); }
s = await readVault(vault, provider);
check("heartbeats cannot push the deadline past t_l + proof-of-life interval", s.deadline <= s.tL + timers.lifeProof);
await warp(s.claimableAt - s.chainNow + 1);
s = await readVault(vault, provider);
check("vault becomes Claimable with no transaction", s.status === "Claimable");

// --- heirs claim (relayed); age-gated share with an in-browser age proof
await (await (await A.claim(relayer, vault, pkgA.bequests[0], snarkjs, circuits)).tx).wait();
const nftOwner = await new ethers.Contract(collectible, ["function ownerOf(uint256) view returns (address)"], provider).ownerOf(nftId);
check("NFT went whole to heir A", nftOwner === heirA);
await (await (await A.claim(relayer, vault, pkgA.bequests[1], snarkjs, circuits)).tx).wait();
const ageClaim = await A.claim(relayer, vault, pkgB.bequests[0], snarkjs, circuits);
await ageClaim.tx.wait();
check(`age-gated claim with a browser age proof (${ageClaim.provingMs} ms)`, true);
await (await (await A.claim(relayer, vault, pkgB.bequests[1], snarkjs, circuits)).tx).wait();
const bal = (a) => new ethers.Contract(dollar, ["function balanceOf(address) view returns (uint256)"], provider).balanceOf(a);
check("DUSD split 60/40 (300 / 200)", (await bal(heirA)).eq(300e6) && (await bal(heirB)).eq(200e6));
check("heir B received the remaining ETH (0.75)", (await provider.getBalance(heirB)).eq(ethers.utils.parseEther("0.75")));
err = "";
try { await A.claim(relayer, vault, pkgA.bequests[0], snarkjs, circuits); } catch (e) { err = e.message; }
check("double claim refused (explained)", /already claimed/i.test(err));
err = "";
try { await A.proveLife(relayer, vault, identity, snarkjs, circuits); } catch (e) { err = e.message; }
check("proof of life after the first claim is refused (settled)", /settled/i.test(err));

// --- sweep after the claim window
await warp(timers.claimWindow + 60);
await (await A.sweep(relayer, vault, { kind: KIND.ERC20, token: dollar })).wait();
check("sweep after the claim window succeeds", true);

console.log(failures ? `\n${failures} check(s) FAILED` : "\nall checks passed");
if (globalThis.curve_bn128) await globalThis.curve_bn128.terminate();
process.exit(failures ? 1 : 0);
