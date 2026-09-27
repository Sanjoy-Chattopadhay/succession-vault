// Off-chain half of the Sepolia demo (see MANUAL.md):
//   node js/demo.mjs prepare   [--credential <file> | --test-issuer]   build will + owner binding
//   node js/demo.mjs life      [--credential <file> | --test-issuer]   proof of life -> demo/life-proof.json
//   node js/demo.mjs ages                                              age proofs  -> demo/age-proofs.json
//   node js/demo.mjs agg                                               enrollment + epoch -> demo/agg.json
//   node js/demo.mjs report                                            gas of broadcast txs -> reports/sepolia.json
//   node js/demo.mjs threshold-setup                                   three test issuers -> demo/threshold/owner.json
//   node js/demo.mjs threshold-life --issuers A,B --tag ab             their proofs of life -> demo/threshold/life-ab.json
import fs from "node:fs";
import path from "node:path";
import { randomBytes } from "node:crypto";
import { crypto, loadCredential, extractLivenessWitness, claimSlots, issuerPublicKey } from "./lib/credential.mjs";
import { makeIssuer, subjectIdFor, issueLivenessCredential } from "./lib/test-issuer.mjs";
import { buildWill, ageCommitment, randomSalt, KIND } from "./lib/will.mjs";
import { PoseidonTree, epochInput, packPresence } from "./lib/registry.mjs";
import { prove, shutdown } from "./lib/zk.mjs";

const CHAIN_ID = process.env.CHAIN_ID ?? "11155111";
const DEMO = "demo";
const args = process.argv.slice(2);
const cmd = args[0];
const opt = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };
const flag = (name) => args.includes(name);
const readJson = (f) => JSON.parse(fs.readFileSync(f, "utf8"));
const writeJson = (f, o) => { fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, JSON.stringify(o, null, 2)); };
const randomAddress = () => "0x" + randomBytes(20).toString("hex");
const now = () => Math.floor(Date.now() / 1000);

async function ownerIdentity() {
  const file = opt("--credential");
  if (file) {
    const p = loadCredential(file).proof.find((x) => x.type === "BJJSignature2021");
    const key = issuerPublicKey(p.issuerData.authCoreClaim);
    return { mode: "credential", issuerAx: key.Ax, issuerAy: key.Ay, subjectId: claimSlots(p.coreClaim)[1] };
  }
  if (!flag("--test-issuer")) throw new Error("pass --credential <file> or --test-issuer");
  const iss = await makeIssuer("demo");
  return { mode: "test-issuer", issuerAx: iss.Ax, issuerAy: iss.Ay, subjectId: subjectIdFor("demo-owner") };
}

async function prepare() {
  const dep = readJson(`deployments/${CHAIN_ID}.json`);
  const id = await ownerIdentity();
  const didSalt = randomSalt();
  const { poseidon, F } = await crypto();
  const binding = F.toObject(poseidon([id.issuerAx, id.issuerAy, id.subjectId, didSalt]));
  const owner = {
    mode: id.mode, binding: binding.toString(), didSalt: didSalt.toString(),
    issuerAx: id.issuerAx.toString(), issuerAy: id.issuerAy.toString(), subjectId: id.subjectId.toString(),
  };
  // Optionally also bind the owner's real Billions DID (second issuer, registered after the first
  // proof of life), so a fresh face-scan credential can later be proven on the same vault.
  const extra = opt("--also-credential");
  if (extra) {
    const p = loadCredential(extra).proof.find((x) => x.type === "BJJSignature2021");
    const key = issuerPublicKey(p.issuerData.authCoreClaim);
    const salt = randomSalt();
    owner.realBinding = F.toObject(poseidon([key.Ax, key.Ay, claimSlots(p.coreClaim)[1], salt])).toString();
    owner.realDidSalt = salt.toString();
  }
  writeJson(`${DEMO}/owner.json`, owner);

  // Heirs need no keys for the demo: claims are relayed and paid to the addresses in the leaves.
  const heirs = { A: randomAddress(), B: randomAddress(), C: randomAddress(), D: randomAddress() };
  const adult = { birthDate: 20000101, salt: randomSalt() };  // C: 18+ today
  const minor = { birthDate: 20150601, salt: randomSalt() };  // D: under 18 until 2033
  const nftId = BigInt("0x" + randomBytes(6).toString("hex"));
  const bequests = [
    { heir: heirs.A, kind: KIND.ETH, shareBps: 5000 },
    { heir: heirs.B, kind: KIND.ETH, shareBps: 3000 },
    { heir: heirs.B, kind: KIND.ETH, shareBps: 2000, notBefore: now() + 25 * 60 },  // tranche
    { heir: heirs.A, kind: KIND.ERC20, token: dep.demoERC20, shareBps: 5000 },
    { heir: heirs.C, kind: KIND.ERC20, token: dep.demoERC20, shareBps: 3000, minAge: 18,
      ageCommitment: await ageCommitment(adult.birthDate, adult.salt) },
    { heir: heirs.D, kind: KIND.ERC20, token: dep.demoERC20, shareBps: 2000, minAge: 18,
      ageCommitment: await ageCommitment(minor.birthDate, minor.salt) },
    { heir: heirs.C, kind: KIND.ERC721, token: dep.demoERC721, id: nftId },
    { heir: heirs.A, kind: KIND.ERC1155, token: dep.demoERC1155, id: 7, shareBps: 10000 },
  ];
  const will = buildWill(bequests);
  writeJson(`${DEMO}/will.json`, {
    root: will.root, residuary: randomAddress(), nftId: nftId.toString(), count: bequests.length, heirs,
    leaves: will.leaves.map(({ bequest: v, proof }) => ({
      index: v[0], heir: v[1], kind: v[2], token: v[3], id: v[4], shareBps: v[5],
      notBefore: v[6], minAge: v[7], ageCommitment: v[8], proof,
    })),
  });
  // Birth dates and salts are the heirs' secrets; the testator hands them over off-chain.
  writeJson(`${DEMO}/heir-secrets.json`, {
    4: { birthDate: adult.birthDate, salt: adult.salt.toString() },
    5: { birthDate: minor.birthDate, salt: minor.salt.toString() },
  });
  console.log(`owner binding (${id.mode}):`, binding.toString());
  console.log("will root:", will.root, `(${bequests.length} bequests)`);
}

async function life() {
  const owner = readJson(`${DEMO}/owner.json`);
  let cred;
  if (opt("--credential")) cred = loadCredential(opt("--credential"));
  else if (flag("--test-issuer")) {
    // Stamp the credential with the chain's clock when the caller supplies it (LIFE_NOW): the vault
    // compares against block.timestamp, and a node that mined many blocks runs ahead of wall time.
    cred = await issueLivenessCredential(await makeIssuer("demo"), {
      subjectId: subjectIdFor("demo-owner"), subjectDid: "did:iden3:privado:test:demo-owner",
      livenessTimestamp: Number(process.env.LIFE_NOW || now()),
    });
  } else throw new Error("pass --credential <file> or --test-issuer");
  const w = await extractLivenessWitness(cred);
  const r = await prove("liveness", {
    claim: w.slots.map(String), issuerAx: w.key.Ax.toString(), issuerAy: w.key.Ay.toString(),
    sigR8x: w.sig.R8x.toString(), sigR8y: w.sig.R8y.toString(), sigS: w.sig.S.toString(),
    livenessTimestamp: w.field.value.toString(), tsSiblings: w.field.siblings.map(String),
    didSalt: opt("--credential") && owner.realDidSalt ? owner.realDidSalt : owner.didSalt,
  });
  if (r.publicSignals[0] !== owner.binding && r.publicSignals[0] !== owner.realBinding) {
    throw new Error("credential does not match a registered binding");
  }
  writeJson(`${DEMO}/life-proof.json`, {
    binding: r.publicSignals[0], livenessTimestamp: r.publicSignals[1], provingMs: Math.round(r.ms), calldata: r.calldata,
  });
  console.log("proof of life for", new Date(Number(r.publicSignals[1]) * 1000).toISOString(), `(${Math.round(r.ms)} ms)`);
}

async function ages() {
  const will = readJson(`${DEMO}/will.json`);
  const secrets = readJson(`${DEMO}/heir-secrets.json`);
  const today = new Date();
  const out = {};
  for (const [i, s] of Object.entries(secrets)) {
    const leaf = will.leaves[Number(i)];
    // Prove against today's admissible cutoff, not the birth date itself: the cutoff is a public
    // signal, and this way it reveals only "at least minAge on the claim date". The vault accepts
    // it as long as the transaction is mined on or after today (UTC).
    const d = today.getUTCFullYear() * 10000 + (today.getUTCMonth() + 1) * 100 + today.getUTCDate();
    const cutoff = d - Number(leaf.minAge) * 10000;
    if (s.birthDate > cutoff) { console.log(`bequest ${i}: heir not yet ${leaf.minAge}, no proof`); continue; }
    const r = await prove("age", { birthDate: String(s.birthDate), salt: s.salt, commitment: leaf.ageCommitment, cutoff: String(cutoff) });
    out[i] = { ...r.calldata, cutoff: String(cutoff), provingMs: Math.round(r.ms) };
    console.log(`bequest ${i}: age proof ok (${Math.round(r.ms)} ms)`);
  }
  writeJson(`${DEMO}/age-proofs.json`, out);
}

/**
 * Aggregated liveness for the demo vault: an enrollment proof for slot 0 and one epoch in which
 * the demo owner is the only principal present. The cohort circuit carries N slots; the others
 * stay absent, which is exactly how a partially attended epoch looks in production.
 */
async function agg() {
  const owner = readJson(`${DEMO}/owner.json`);
  const circuit = process.env.AGG_VERIFIER?.replace(/^AggVerifier/, "agg") ?? "agg_N8_m40_w1";
  const [, n, mt, words] = circuit.match(/^agg_N(\d+)_m(\d+)_w(\d+)$/).map(Number);
  const binding = BigInt(owner.binding);

  const tree = await PoseidonTree.create();
  const ins = tree.insert(0, binding);
  const enrollProof = await prove("enroll", {
    oldRoot: ins.oldRoot.toString(),
    newRoot: ins.newRoot.toString(),
    index: "0",
    siblings: ins.siblings.map(String),
    binding: binding.toString(),
  }, "zk/batch");
  console.log(`enrollment proof for slot 0 (${Math.round(enrollProof.ms)} ms)`);

  // The epoch is placed on the chain's clock, not the host's: a node that has mined many blocks in
  // quick succession runs ahead of wall time, and the contract compares against block.timestamp.
  // AGG_AFTER carries the vault's current lastLifeProof so that the epoch strictly advances it;
  // otherwise the demo records a perfectly valid epoch that changes nothing visible.
  // The registry also rejects epochs shorter than its minimum length (AGG_MIN_EPOCH, as deployed).
  const minEpoch = Number(process.env.AGG_MIN_EPOCH ?? 5 * 60);
  const end = Number(process.env.AGG_NOW || now());
  const start = Math.max(end - Math.max(10 * 60, minEpoch), Number(process.env.AGG_AFTER ?? 0) + 1);
  if (end - start < minEpoch) {
    throw new Error(`epoch window of ${Math.max(0, end - start)} s is shorter than the registry's minimum of ${minEpoch} s: `
      + `wait until chain time > lastLifeProof + ${minEpoch}`);
  }
  const cred = await issueLivenessCredential(await makeIssuer("demo"), {
    subjectId: subjectIdFor("demo-owner"),
    subjectDid: "did:iden3:privado:test:demo-owner",
    livenessTimestamp: Math.max(start, end - 60),
  });
  const w = await extractLivenessWitness(cred);
  if (w.field.depth > mt) throw new Error(`credential depth ${w.field.depth} exceeds circuit depth ${mt}`);
  const members = [{
    present: true,
    enrollSiblings: tree.siblings(0),
    inputs: {
      claim: w.slots.map(String),
      issuerAx: w.key.Ax.toString(), issuerAy: w.key.Ay.toString(),
      sigR8x: w.sig.R8x.toString(), sigR8y: w.sig.R8y.toString(), sigS: w.sig.S.toString(),
      livenessTimestamp: w.field.value.toString(),
      tsSiblings: w.field.siblings.slice(0, mt).map(String),
      didSalt: owner.didSalt,
    },
  }];
  for (let i = 1; i < n; i++) members.push({ present: false, enrollSiblings: tree.siblings(i) });

  const epoch = await prove(circuit, epochInput({
    enrollRoot: tree.root, epochStart: start, epochEnd: end, words, members, mtLevels: mt,
  }), "zk/batch");
  console.log(`epoch proof, cohort of ${n}, 1 present (${Math.round(epoch.ms)} ms)`);

  writeJson(`${DEMO}/agg.json`, {
    circuit,
    emptyRoot: ins.oldRoot.toString(),
    enrollRoot: tree.root.toString(),
    binding: binding.toString(),
    enroll: { calldata: enrollProof.calldata, newRoot: ins.newRoot.toString(), slot: 0, provingMs: Math.round(enrollProof.ms) },
    epoch: {
      calldata: epoch.calldata,
      start: String(start), end: String(end),
      words: packPresence([0], words).map(String),
      provingMs: Math.round(epoch.ms),
    },
  });
  console.log("epoch window:", new Date(start * 1000).toISOString(), "->", new Date(end * 1000).toISOString());
}

/**
 * Gas of every broadcast transaction. Receipts are paired with the script's transactions by
 * (sender, nonce) read back from the chain, which stays correct even when the node assigned
 * hashes in a different order than the script sent the transactions.
 */
async function report() {
  const rpc = opt("--rpc") ?? (CHAIN_ID === "31337" ? "http://127.0.0.1:8545" : "https://ethereum-sepolia-rpc.publicnode.com");
  const call = async (method, params) => {
    const res = await fetch(rpc, { method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
    return (await res.json()).result;
  };
  const rows = [];
  for (const script of ["Deploy.s.sol", "Demo.s.sol", "DemoAgg.s.sol"]) {
    const dir = `broadcast/${script}/${CHAIN_ID}`;
    if (!fs.existsSync(dir)) continue;
    const files = fs.readdirSync(dir).filter((f) => f.endsWith(".json") && !f.includes("latest")).sort();
    for (const f of files) {
      const run = readJson(path.join(dir, f));
      const byNonce = new Map(run.transactions.map((t) => [`${t.transaction.from.toLowerCase()}:${BigInt(t.transaction.nonce)}`, t]));
      for (const rc of run.receipts ?? []) {
        const tx = await call("eth_getTransactionByHash", [rc.transactionHash]);
        const t = byNonce.get(`${tx.from.toLowerCase()}:${BigInt(tx.nonce)}`);
        const label = t?.function ?? (t?.transactionType === "CREATE" ? `deploy ${t.contractName}` : "transfer ETH");
        rows.push({ script, function: label.split("(")[0], gasUsed: parseInt(rc.gasUsed, 16),
          status: rc.status === "0x1" ? "ok" : "reverted", block: parseInt(rc.blockNumber, 16), hash: rc.transactionHash });
      }
    }
  }
  rows.sort((a, b) => a.block - b.block);
  writeJson(`reports/${CHAIN_ID === "31337" ? "anvil" : "sepolia"}.json`, rows);
  console.table(rows.map(({ function: fn, gasUsed, status, hash }) => ({ function: fn, gasUsed, status, hash: hash.slice(0, 14) + "…" })));
}

/**
 * j-of-m issuer threshold experiment: one owner identity attested by three independent test
 * issuers (A, B, C). The owner registers all three with threshold 2 on a live vault.
 */
const THR = `${DEMO}/threshold`;
const THR_SUBJECT = "threshold-owner";
async function thresholdSetup() {
  const { poseidon, F } = await crypto();
  const didSalt = randomSalt();
  const subjectId = subjectIdFor(THR_SUBJECT);
  const issuers = {};
  for (const name of ["A", "B", "C"]) {
    const iss = await makeIssuer(`threshold-${name}`);
    issuers[name] = F.toObject(poseidon([iss.Ax, iss.Ay, subjectId, didSalt])).toString();
  }
  writeJson(`${THR}/owner.json`, { didSalt: didSalt.toString(), bindings: issuers });
  console.log("threshold bindings:", issuers);
}

async function thresholdLife() {
  const owner = readJson(`${THR}/owner.json`);
  const names = (opt("--issuers") ?? "A,B").split(",");
  const tag = opt("--tag") ?? names.join("").toLowerCase();
  const ts = Number(process.env.LIFE_NOW || now());
  const proofs = [];
  for (const name of names) {
    const iss = await makeIssuer(`threshold-${name}`);
    const cred = await issueLivenessCredential(iss, {
      subjectId: subjectIdFor(THR_SUBJECT), subjectDid: `did:iden3:privado:test:${THR_SUBJECT}`, livenessTimestamp: ts,
    });
    const w = await extractLivenessWitness(cred);
    const r = await prove("liveness", {
      claim: w.slots.map(String), issuerAx: w.key.Ax.toString(), issuerAy: w.key.Ay.toString(),
      sigR8x: w.sig.R8x.toString(), sigR8y: w.sig.R8y.toString(), sigS: w.sig.S.toString(),
      livenessTimestamp: w.field.value.toString(), tsSiblings: w.field.siblings.map(String), didSalt: owner.didSalt,
    });
    if (r.publicSignals[0] !== owner.bindings[name]) throw new Error(`issuer ${name}: unexpected binding`);
    proofs.push({ issuer: name, binding: r.publicSignals[0], livenessTimestamp: r.publicSignals[1], calldata: r.calldata,
      provingMs: Math.round(r.ms) });
  }
  // proveLifeMulti takes the bindings in strictly increasing order.
  proofs.sort((a, b) => (BigInt(a.binding) < BigInt(b.binding) ? -1 : 1));
  writeJson(`${THR}/life-${tag}.json`, { issuers: proofs.map((p) => p.issuer), count: proofs.length, proofs });
  console.log(`proofs of life from ${names.join(", ")} at ${new Date(ts * 1000).toISOString()} -> ${THR}/life-${tag}.json`);
}

try {
  if (cmd === "prepare") await prepare();
  else if (cmd === "threshold-setup") await thresholdSetup();
  else if (cmd === "threshold-life") await thresholdLife();
  else if (cmd === "life") await life();
  else if (cmd === "ages") await ages();
  else if (cmd === "agg") await agg();
  else if (cmd === "report") await report();
  else console.log("usage: node js/demo.mjs prepare|life|ages|agg|report [--credential <file> | --test-issuer]");
} finally {
  await shutdown();
}
process.exit(0);
