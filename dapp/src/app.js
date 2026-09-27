// Succession Vault: the browser app. Hash routes, one view at a time, no framework.
import { ethers } from "ethers";
import {
  NETWORK, ADDR, KIND, KIND_NAME, readProvider, readVault, vaultsOf, vaultAt, txLink, addrLink, ERC20_ABI, ERC721_ABI,
} from "./core/chain.js";
import * as A from "./core/actions.js";
import { newIdentity, demoIssuer, bindingOf, issueLivenessCredential, livenessInput, prove } from "./core/zk.js";
import { willPackage, heirsOf, parseWillPackage } from "./core/will.js";
import CIRCUIT_SIZES from "./circuit-sizes.json" with { type: "json" };

// ------------------------------------------------------------------ state and helpers

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];
const view = $("#view");
const reader = readProvider();
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const short = (a) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "");
const isAddr = (a) => ethers.utils.isAddress(String(a ?? "").trim());
const nowS = () => Math.floor(Date.now() / 1000);
const wallet = { provider: null, signer: null, account: null };
let timers = [];          // intervals owned by the current view
const clearTimers = () => { timers.forEach(clearInterval); timers = []; };

const ICON = {
  lock: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></svg>',
  heart: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20.8 4.6a5.5 5.5 0 0 0-7.8 0L12 5.7l-1-1.1a5.5 5.5 0 0 0-7.8 7.8L12 21l8.8-8.6a5.5 5.5 0 0 0 0-7.8z"/></svg>',
  shield: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/><path d="m9 12 2 2 4-4"/></svg>',
  users: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.9M16 3.1a4 4 0 0 1 0 7.8"/></svg>',
  eye: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/></svg>',
  clock: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><path d="M12 6v6l4 2"/></svg>',
  box: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 16V8a2 2 0 0 0-1-1.7l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.7l7 4a2 2 0 0 0 2 0l7-4a2 2 0 0 0 1-1.7z"/><path d="M3.3 7 12 12l8.7-5M12 22V12"/></svg>',
};

function fmtDur(s) {
  s = Math.max(0, Math.round(s));
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60), x = s % 60;
  if (d) return `${d}d ${h}h ${m}m`;
  if (h) return `${h}h ${String(m).padStart(2, "0")}m ${String(x).padStart(2, "0")}s`;
  return `${m}m ${String(x).padStart(2, "0")}s`;
}
const fmtTime = (t) => (t ? new Date(t * 1000).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "medium" }) : "—");
const fmtClock = (t) => new Date(t * 1000).toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
const mins = (s) => `${Math.round(s / 60)} min`;
const addrHtml = (a) => `<span class="nowrap"><a class="addr" href="${addrLink(a)}" target="_blank" rel="noopener">${short(a)}</a><button class="copy" data-copy="${a}" title="Copy address" aria-label="Copy address">⧉</button></span>`;

// Deterministic little artwork for a demo collectible id.
function nftArt(id) {
  const h = (Number(id) * 137.508) % 360;
  return `<svg class="nft-art" viewBox="0 0 34 34"><defs><linearGradient id="g${id}" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="hsl(${h},55%,55%)"/><stop offset="1" stop-color="hsl(${(h + 70) % 360},55%,38%)"/></linearGradient></defs><rect width="34" height="34" rx="8" fill="url(#g${id})"/><text x="17" y="22" text-anchor="middle" font-size="12" font-weight="800" fill="#fff" font-family="system-ui">#${esc(id)}</text></svg>`;
}

function toast(html, kind = "", ms = 6000) {
  const el = document.createElement("div");
  el.className = `toast ${kind}`;
  el.innerHTML = html;
  $("#toasts").appendChild(el);
  if (ms) setTimeout(() => el.remove(), ms);
  return el;
}
const errorToast = (e) => toast(`<b>Not done.</b> ${esc(e?.message ?? e)}`, "error", 9000);

/** Send a transaction with pending/success toasts. `make` returns a tx (or {tx}). */
async function runTx(label, make, btn) {
  if (btn) btn.disabled = true;
  let pending;
  try {
    const out = await make();
    const tx = out?.hash ? out : out.tx;
    pending = toast(`<b>${esc(label)}</b> sent. Waiting for Sepolia… <a href="${txLink(tx.hash)}" target="_blank" rel="noopener">view</a>`, "pending", 0);
    const rc = await tx.wait();
    pending.remove();
    toast(`<b>${esc(label)}</b> confirmed in block ${rc.blockNumber}. <a href="${txLink(tx.hash)}" target="_blank" rel="noopener">view</a>`);
    return { ...out, receipt: rc };
  } catch (e) {
    pending?.remove();
    errorToast(e);
    return null;
  } finally {
    if (btn) btn.disabled = false;
  }
}

function download(name, obj) {
  const blob = new Blob([JSON.stringify(obj, null, 2)], { type: "application/json" });
  const a = Object.assign(document.createElement("a"), { href: URL.createObjectURL(blob), download: name });
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 2000);
}

document.addEventListener("click", (e) => {
  const c = e.target.closest("[data-copy]");
  if (!c) return;
  navigator.clipboard?.writeText(c.dataset.copy).then(() => toast("Copied.", "", 1500));
});

// ------------------------------------------------------------------ local vault records

// The owner's liveness identity (subject id and binding salt) never leaves the browser except in
// the backup file the owner downloads. Without it, no proof of life can be made for the vault.
const KEY = (v) => `sv:vault:${v.toLowerCase()}`;
function saveRecord(rec) { try { localStorage.setItem(KEY(rec.vault), JSON.stringify(rec)); } catch { /* storage off */ } }
function loadRecord(v) { try { return JSON.parse(localStorage.getItem(KEY(v)) ?? "null"); } catch { return null; } }
function allRecords() {
  const out = [];
  try { for (let i = 0; i < localStorage.length; i++) { const k = localStorage.key(i); if (k.startsWith("sv:vault:")) out.push(JSON.parse(localStorage.getItem(k))); } } catch { /* storage off */ }
  return out;
}
const backupOf = (rec) => ({ format: "succession-vault-backup/1", network: "sepolia", ...rec, warning: "Keep this file private: it lets anyone holding it produce proofs of life for this vault with the demo issuer." });

// ------------------------------------------------------------------ wallet

async function ensureSepolia() {
  try {
    await window.ethereum.request({ method: "wallet_switchEthereumChain", params: [{ chainId: NETWORK.chainIdHex }] });
  } catch (e) {
    if (e.code !== 4902) throw e;
    await window.ethereum.request({
      method: "wallet_addEthereumChain",
      params: [{ chainId: NETWORK.chainIdHex, chainName: "Sepolia", rpcUrls: [NETWORK.rpc], nativeCurrency: { name: "Sepolia ETH", symbol: "ETH", decimals: 18 }, blockExplorerUrls: [NETWORK.explorer] }],
    });
  }
}

async function connect() {
  if (!window.ethereum) {
    toast('No browser wallet found. Install <a href="https://metamask.io" target="_blank" rel="noopener">MetaMask</a> (or any EIP-1193 wallet) and reload.', "error", 10000);
    throw new Error("No wallet");
  }
  const p = new ethers.providers.Web3Provider(window.ethereum, "any");
  await p.send("eth_requestAccounts", []);
  await ensureSepolia();
  wallet.provider = new ethers.providers.Web3Provider(window.ethereum, "any");
  wallet.signer = wallet.provider.getSigner();
  wallet.account = await wallet.signer.getAddress();
  renderWallet();
  return wallet.signer;
}

async function needSigner() {
  if (wallet.signer) {
    const { chainId } = await wallet.provider.getNetwork();
    if (chainId !== NETWORK.chainId) await ensureSepolia();
    return wallet.signer;
  }
  return connect();
}

function renderWallet() {
  const b = $("#connect");
  if (wallet.account) { b.textContent = short(wallet.account); b.classList.remove("btn-primary"); b.title = wallet.account; }
  else { b.textContent = "Connect wallet"; b.classList.add("btn-primary"); }
}

$("#connect").addEventListener("click", () => connect().then(route).catch((e) => e.message !== "No wallet" && errorToast(e)));
if (window.ethereum) {
  window.ethereum.on?.("accountsChanged", (accs) => { wallet.account = accs[0] ?? null; wallet.signer = accs[0] ? wallet.provider?.getSigner() : null; renderWallet(); route(); });
  window.ethereum.on?.("chainChanged", () => location.reload());
  // Reconnect silently if the site is already authorised.
  window.ethereum.request({ method: "eth_accounts" }).then((accs) => {
    if (!accs?.length) return;
    wallet.provider = new ethers.providers.Web3Provider(window.ethereum, "any");
    wallet.signer = wallet.provider.getSigner();
    wallet.account = ethers.utils.getAddress(accs[0]);
    renderWallet();
    route();
  }).catch(() => {});
}

// ------------------------------------------------------------------ circuits (downloaded once)

const CIRCUIT_FILES = { livenessWasm: "liveness.wasm", livenessZkey: "liveness.zkey", ageWasm: "age.wasm", ageZkey: "age.zkey" };
const circuitCache = {};
// Real file sizes, baked in at build time: servers may gzip and report compressed lengths.
const fileSize = (k) => CIRCUIT_SIZES[CIRCUIT_FILES[k]] ?? 0;
/** Fetch a circuit pair once; onProgress(bytesSoFar, totalBytes) over both files. */
async function circuits(which, onProgress = () => {}) {
  const keys = which === "age" ? ["ageWasm", "ageZkey"] : ["livenessWasm", "livenessZkey"];
  const total = keys.reduce((a, k) => a + fileSize(k), 0);
  let before = 0;
  for (const k of keys) {
    if (circuitCache[k]) { before += circuitCache[k].length; continue; }
    const res = await fetch(`circuits/${CIRCUIT_FILES[k]}`);
    if (!res.ok) throw new Error(`Could not load circuit file ${CIRCUIT_FILES[k]}`);
    const reader = res.body.getReader();
    const chunks = []; let got = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(value); got += value.length;
      onProgress(before + got, total);
    }
    const buf = new Uint8Array(got); let o = 0;
    for (const c of chunks) { buf.set(c, o); o += c.length; }
    circuitCache[k] = buf;
    before += got;
  }
  const out = {};
  for (const k of keys) out[k] = circuitCache[k].slice();
  return out;
}
const loadNote = (got, total) => (total ? `${Math.min(100, Math.round((got / total) * 100))}% of ${(total / 1e6).toFixed(0)} MB` : `${(got / 1e6).toFixed(1)} MB`);
const snark = () => {
  if (!window.snarkjs) throw new Error("The proving library did not load. Reload the page.");
  return window.snarkjs;
};

// ------------------------------------------------------------------ router

const routes = {
  "": overview, create: createView, vaults: myVaults, vault: vaultView, claim: claimView, explore: exploreView,
};
function route() {
  clearTimers();
  const [name, arg] = location.hash.replace(/^#\/?/, "").split("/");
  const fn = routes[name] ?? overview;
  const tab = name === "vault" ? (loadRecord(arg ?? "") ? "vaults" : "explore") : (name || "overview");
  $$("#tabs a").forEach((a) => a.classList.toggle("active", a.dataset.route === tab));
  window.scrollTo(0, 0);
  Promise.resolve(fn(arg)).catch((e) => { view.innerHTML = `<div class="notice bad">${esc(e.message ?? e)}</div>`; });
}
window.addEventListener("hashchange", route);

// ------------------------------------------------------------------ overview

function overview() {
  view.innerHTML = `
  <section class="hero">
    <div>
      <div class="eyebrow">Self-custodial digital inheritance · Sepolia demo</div>
      <h1>Leave your NFTs and tokens to your heirs. No trustee, no key hand-over.</h1>
      <p class="lead">Your assets wait in a smart-contract vault with a will inside it. While you are alive, you keep them.
      When you stop proving that you are alive, your heirs claim what you left them, straight from the chain.</p>
      <p class="lead">The catch every "dead man's switch" has: whoever finds your key can keep pressing it forever.
      Here, a key alone cannot. Only a <b>private zero-knowledge proof of life</b> can keep the vault alive for long.</p>
      <div class="row" style="margin-top:18px">
        <a class="btn btn-primary btn-lg" href="#/create">Create a vault</a>
        <a class="btn btn-lg" href="#/claim">I am an heir</a>
      </div>
    </div>
    <div class="card">
      <h3>Two clocks, one deadline</h3>
      <p class="muted small">The vault stays alive until the earlier of two clocks runs out.</p>
      <div class="clocks">
        <div class="clock possession"><b>Key clock</b><div class="small">Any signature with the owner key (a <i>heartbeat</i>) resets it. Short.</div></div>
        <div class="clock presence"><b>Life clock</b><div class="small">Only a zero-knowledge proof of life resets it. A stolen key cannot.</div></div>
      </div>
      <div class="formula">deadline = min(t<sub>key</sub> + Δ<sub>key</sub>, t<sub>life</sub> + Δ<sub>life</sub>)</div>
      <p class="small muted" style="margin-top:10px">So a thief with your key buys at most Δ<sub>life</sub> after your last proof of life, never forever.</p>
    </div>
  </section>

  <section class="grid grid-3">
    <div class="card feature"><div class="ico ico-teal">${ICON.eye}</div><div><h3>Private</h3><p class="small muted">The chain sees a proof and a timestamp. Not your identity, not your face, not the credential. Heirs see only their own bequests.</p></div></div>
    <div class="card feature"><div class="ico ico-gold">${ICON.shield}</div><div><h3>Bounded key power</h3><p class="small muted">A lost or stolen key can move nothing without a fresh proof of life, and cannot postpone the heirs past the life clock.</p></div></div>
    <div class="card feature"><div class="ico ico-plum">${ICON.users}</div><div><h3>Rich wills</h3><p class="small muted">NFTs to one heir, token pools split by percentage, age-gated shares proved in zero knowledge, time locks, and a residuary heir.</p></div></div>
  </section>

  <section class="section card">
    <div class="card-head"><div><h2>Try a proof of life now</h2>
    <p class="muted small" style="margin:0">No wallet needed. Your browser gets a liveness credential from the demo issuer, proves in zero knowledge that it holds one,
    and verifies the proof with the same verification key as the on-chain verifier.</p></div>
    <button class="btn btn-primary" id="try">Run the proof</button></div>
    <div id="try-out"></div>
  </section>

  <section class="section grid grid-2">
    <div class="card">
      <h2>How it works</h2>
      <div class="steps" style="margin-top:14px">
        <div class="step"><div><b>Create a vault.</b> <span class="muted">Pick the timers, write the will (who gets what), and create it. The will is a Merkle root on-chain; the details stay with you.</span></div></div>
        <div class="step"><div><b>Fund it.</b> <span class="muted">Mint a demo NFT and get demo dollars from the faucet, then deposit them (and some Sepolia ETH).</span></div></div>
        <div class="step"><div><b>Stay alive.</b> <span class="muted">Send heartbeats, and prove life in your browser: a liveness credential becomes a Groth16 proof in a few seconds.</span></div></div>
        <div class="step"><div><b>Hand out the will packages.</b> <span class="muted">Each heir gets a small file with only their bequests.</span></div></div>
        <div class="step"><div><b>Heirs claim.</b> <span class="muted">Once the deadline and the grace period pass, heirs load their package and claim. Anyone may pay the gas.</span></div></div>
      </div>
    </div>
    <div class="card">
      <h2>Try it in ten minutes</h2>
      <p class="muted">You need a browser wallet (MetaMask) on Sepolia and a little Sepolia ETH for gas from any public faucet.
      The demo timers are minutes long, so you can watch a vault go from <span class="badge b-alive">Alive</span> to
      <span class="badge b-grace">Grace</span> to <span class="badge b-claimable">Claimable</span> in one sitting.</p>
      <div class="notice warn" style="margin:14px 0">
        <div><b>Demo issuer.</b> In a real deployment, a liveness credential comes from an identity provider after a
        face scan. Here, a <b>demo issuer whose key is public</b> signs it in your browser, so anyone can make "proofs of life".
        Use test assets only.</div>
      </div>
      <h3>Deployed contracts</h3>
      <dl class="kv small">
        <dt>Vault factory</dt><dd>${addrHtml(ADDR.factory)}</dd>
        <dt>Liveness verifier</dt><dd>${addrHtml(ADDR.livenessVerifier)}</dd>
        <dt>Age verifier</dt><dd>${addrHtml(ADDR.ageVerifier)}</dd>
        <dt>Liveness registry</dt><dd>${addrHtml(ADDR.registry)}</dd>
        <dt>Demo collectible (NFT)</dt><dd>${addrHtml(ADDR.collectible)}</dd>
        <dt>Demo dollar (DUSD)</dt><dd>${addrHtml(ADDR.dollar)}</dd>
      </dl>
    </div>
  </section>`;
  $("#try").addEventListener("click", (e) => tryProof(e.currentTarget));
}

async function tryProof(btn) {
  const out = $("#try-out");
  const steps = [["load", "Download the circuit and proving key (once)"], ["issue", "Demo issuer signs a liveness credential"], ["prove", "Groth16 proof in your browser"], ["verify", "Verify the proof in the browser"], ["chain", "Ask the Sepolia verifier contract (free read-only call)"]];
  const set = (cur, extra = "") => {
    const i = steps.findIndex(([k]) => k === cur);
    out.innerHTML = `<div class="progress">${steps.map(([k, t], j) => `<div class="pstep ${j < i ? "done" : j === i ? "active" : ""}"><span class="dot"></span>${t}${j === i && extra ? ` <span class="muted">${extra}</span>` : ""}</div>`).join("")}</div>`;
  };
  btn.disabled = true;
  try {
    set("load");
    const c = await circuits("liveness", (got, total) => set("load", loadNote(got, total)));
    set("issue");
    const issuer = await demoIssuer(), identity = newIdentity();
    const ts = nowS();
    const cred = await issueLivenessCredential(issuer, identity, ts);
    set("prove");
    const p = await prove(snark(), livenessInput(issuer, identity, cred), c.livenessWasm, c.livenessZkey);
    set("verify");
    const vkey = await (await fetch("circuits/liveness_vkey.json")).json();
    const ok = await snark().groth16.verify(vkey, p.publicSignals, p.proof);
    set("chain");
    const verifier = new ethers.Contract(ADDR.livenessVerifier, ["function verifyProof(uint[2] a, uint[2][2] b, uint[2] c, uint[2] pub) view returns (bool)"], reader);
    const onChain = await verifier.verifyProof(p.calldata.a, p.calldata.b, p.calldata.c, p.publicSignals).catch(() => null);
    const bindingOk = p.publicSignals[0] === bindingOf(issuer, identity).toString() && Number(p.publicSignals[1]) === ts;
    out.innerHTML = `<div class="notice ${ok && bindingOk ? "good" : "bad"}" style="margin-top:12px"><div>
      <b>${ok && bindingOk ? "The proof verifies." : "The proof did not verify."}</b> Proved in ${(p.ms / 1000).toFixed(1)} s.
      ${onChain === true ? `The <a href="${addrLink(ADDR.livenessVerifier)}" target="_blank" rel="noopener">Sepolia verifier contract</a> accepts it too.` : onChain === false ? "The Sepolia verifier contract rejected it." : "(The Sepolia verifier could not be reached just now.)"}
      <dl class="kv small" style="margin-top:8px"><dt>Public: binding</dt><dd class="mono">${p.publicSignals[0].slice(0, 24)}…</dd>
      <dt>Public: time of life</dt><dd>${fmtTime(Number(p.publicSignals[1]))}</dd>
      <dt>Kept private</dt><dd>the credential, the issuer's signature, the holder's identity and salt</dd></dl>
      <div class="small muted">This is all the chain would see. A vault accepts it if the binding is registered and the time is newer than its last proof.</div></div></div>`;
  } catch (e) {
    out.innerHTML = `<div class="notice bad" style="margin-top:12px">${esc(e.message ?? e)}</div>`;
  } finally { btn.disabled = false; }
}

// ------------------------------------------------------------------ create wizard

const PRESETS = [
  { id: "quick", name: "Quick demo", desc: "Watch the full life cycle in about 20 minutes.", t: { heartbeat: 5, lifeProof: 10, grace: 3, claimWindow: 10 } },
  { id: "relaxed", name: "Relaxed", desc: "More time between actions.", t: { heartbeat: 20, lifeProof: 60, grace: 15, claimWindow: 60 } },
  { id: "custom", name: "Custom", desc: "Your own timers (whole minutes).", t: null },
];
const MAX_LIFE_PLUS_GRACE = 84; // minutes: this deployment needs life + grace + 15 min < 100 min

const draft = {
  step: 0, preset: "quick", t: { ...PRESETS[0].t }, residuary: "", bequests: [],
};

function createView() {
  const steps = ["Timers", "Will", "Review"];
  view.innerHTML = `
    <h1>Create a vault</h1>
    <p class="muted">Three steps. Nothing is sent until the last one.</p>
    <div class="wizard-nav">${steps.map((s, i) => `<div class="wstep ${i === draft.step ? "on" : i < draft.step ? "done" : ""}"><b>${i < draft.step ? "✓" : i + 1}</b>${s}</div>`).join("")}</div>
    <div id="wiz"></div>`;
  [wizTimers, wizWill, wizReview][draft.step]();
}
const goStep = (n) => { draft.step = n; createView(); };

function wizTimers() {
  const w = $("#wiz");
  const t = draft.t;
  w.innerHTML = `
  <div class="grid grid-2">
    <div class="card">
      <h2>How long, and how fast?</h2>
      <div class="grid grid-3" style="margin:12px 0 18px">
        ${PRESETS.map((p) => `<button class="preset ${draft.preset === p.id ? "on" : ""}" data-preset="${p.id}"><b>${p.name}</b><div class="small muted">${p.desc}</div></button>`).join("")}
      </div>
      <div class="grid grid-2">
        ${timerField("heartbeat", "Key clock Δkey", "A heartbeat (any owner signature) must come this often.", t.heartbeat)}
        ${timerField("lifeProof", "Life clock Δlife", "A proof of life must come this often. Bounds what a stolen key can do.", t.lifeProof)}
        ${timerField("grace", "Grace period", "After the deadline, the owner can still come back.", t.grace)}
        ${timerField("claimWindow", "Claim window", "Heirs claim in this window; then leftovers go to the residuary heir.", t.claimWindow)}
      </div>
      <div id="t-err" class="err-text"></div>
    </div>
    <div class="card flat">
      <h3>What these mean</h3>
      <div id="t-explain"></div>
      <hr>
      <p class="small muted">This demo deployment limits Δlife + grace to ${MAX_LIFE_PLUS_GRACE} minutes and needs whole minutes of at least 1.
      A real deployment would use months: for example Δkey = 30 days, Δlife = 180 days, grace = 30 days.</p>
    </div>
  </div>
  <div class="row" style="margin-top:18px"><span class="spacer"></span><button class="btn btn-primary btn-lg" id="next">Next: the will →</button></div>`;
  const disable = draft.preset !== "custom";
  $$("input[data-timer]", w).forEach((i) => { i.disabled = disable; i.addEventListener("input", () => { draft.t[i.dataset.timer] = Number(i.value); explain(); }); });
  $$("[data-preset]", w).forEach((b) => b.addEventListener("click", () => {
    draft.preset = b.dataset.preset;
    const p = PRESETS.find((x) => x.id === draft.preset);
    if (p.t) draft.t = { ...p.t };
    wizTimers();
  }));
  const explain = () => {
    const { heartbeat: h, lifeProof: l, grace: g, claimWindow: c } = draft.t;
    $("#t-explain").innerHTML = `<ul class="small" style="padding-left:18px;margin:0">
      <li>Send a heartbeat every <b>${h} min</b> and a proof of life every <b>${l} min</b>.</li>
      <li>If you stop, the vault becomes <span class="badge b-grace">Grace</span> ${Math.min(h, l)} min after your last action at most, and
      <span class="badge b-claimable">Claimable</span> ${g} min later.</li>
      <li>Someone with only your key can delay heirs by at most <b>${l} min</b> after your last proof of life.</li>
      <li>Heirs have <b>${c} min</b> to claim; leftovers then go to the residuary heir.</li></ul>`;
    $("#t-err").textContent = timerError() ?? "";
  };
  explain();
  $("#next").addEventListener("click", () => { const e = timerError(); if (e) { $("#t-err").textContent = e; return; } goStep(1); });
}
const timerField = (k, label, hint, v) => `<div class="field"><label>${label}</label><div class="row" style="flex-wrap:nowrap"><input type="number" min="1" step="1" data-timer="${k}" value="${v}"><span class="muted small">min</span></div><div class="hint">${hint}</div></div>`;
function timerError() {
  const t = draft.t;
  for (const k of ["heartbeat", "lifeProof", "grace", "claimWindow"]) if (!Number.isInteger(t[k]) || t[k] < 1) return "Every timer must be a whole number of minutes, at least 1.";
  if (t.lifeProof + t.grace > MAX_LIFE_PLUS_GRACE) return `On this deployment, life clock + grace must be at most ${MAX_LIFE_PLUS_GRACE} minutes.`;
  return null;
}

const KIND_OPTIONS = [
  { v: "nft", label: "Demo NFT" }, { v: "dusd", label: "Demo dollars" },
  { v: "eth", label: "ETH" }, { v: "erc20", label: "Other ERC-20 token" }, { v: "erc721", label: "Other NFT (ERC-721)" },
];
const newBequest = (kind = "nft") => ({ heir: "", kind, token: "", id: "", share: 100, minAge: 0, birthDate: "", notBefore: "" });

function wizWill() {
  if (!draft.bequests.length) draft.bequests.push(newBequest("nft"));
  if (!draft.residuary && wallet.account) draft.residuary = wallet.account;
  const w = $("#wiz");
  w.innerHTML = `
  <div class="grid" style="grid-template-columns:minmax(0,1fr) 320px">
    <div class="card">
      <div class="card-head"><h2>Who gets what</h2><button class="btn btn-sm" id="add">+ Add bequest</button></div>
      <div id="beqs" class="grid"></div>
      <hr>
      <div class="field" style="max-width:520px"><label>Residuary heir</label><input id="resid" placeholder="0x…" value="${esc(draft.residuary)}">
      <div class="hint">Receives everything not claimed by the end of the claim window (unallocated shares, dust, forgotten bequests).</div></div>
      <div id="w-err" class="err-text"></div>
    </div>
    <div class="grid" style="align-content:start">
      <div class="card flat">
        <h3>Get demo assets</h3>
        <p class="small muted">Free test tokens on Sepolia. You deposit them after the vault is created.</p>
        <div class="grid">
          <button class="btn" id="mint">Mint a demo NFT</button>
          <button class="btn" id="faucet">Get 1,000 demo dollars</button>
        </div>
        <div id="mine" class="small" style="margin-top:12px"></div>
      </div>
      <div class="card flat"><h3>Pools</h3><div id="pools" class="small"></div></div>
    </div>
  </div>
  <div class="row" style="margin-top:18px"><button class="btn btn-lg" id="back">← Timers</button><span class="spacer"></span><button class="btn btn-primary btn-lg" id="next">Next: review →</button></div>`;
  if (innerWidth < 860) w.firstElementChild.style.gridTemplateColumns = "1fr";
  renderBequests();
  $("#add").addEventListener("click", () => { draft.bequests.push(newBequest(draft.bequests.some((b) => b.kind === "nft") ? "dusd" : "nft")); renderBequests(); });
  $("#resid").addEventListener("input", (e) => { draft.residuary = e.target.value.trim(); });
  $("#back").addEventListener("click", () => goStep(0));
  $("#next").addEventListener("click", () => { const e = willError(); $("#w-err").textContent = e ?? ""; if (!e) goStep(2); });
  $("#mint").addEventListener("click", async (e) => {
    const r = await runTx("Mint demo NFT", async () => A.mintCollectible(await needSigner()), e.target);
    if (r) {
      const empty = draft.bequests.find((b) => b.kind === "nft" && !b.id);
      if (empty) empty.id = r.id; else draft.bequests.push({ ...newBequest("nft"), id: r.id });
      renderBequests(); refreshMine();
      toast(`Minted demo NFT #${r.id}. It is in your wallet and in the will.`);
    }
  });
  $("#faucet").addEventListener("click", async (e) => { if (await runTx("Demo dollar faucet", async () => A.dollarFaucet(await needSigner()), e.target)) refreshMine(); });
  refreshMine();
}

async function refreshMine() {
  const el = $("#mine");
  if (!el || !wallet.account) { if (el) el.innerHTML = '<span class="muted">Connect a wallet to see your balances.</span>'; return; }
  const [eth, dusd, nfts] = await Promise.all([
    reader.getBalance(wallet.account),
    new ethers.Contract(ADDR.dollar, ERC20_ABI, reader).balanceOf(wallet.account),
    new ethers.Contract(ADDR.collectible, ERC721_ABI, reader).balanceOf(wallet.account),
  ]).catch(() => [null, null, null]);
  if (!eth) return;
  el.innerHTML = `<dl class="kv"><dt>Sepolia ETH</dt><dd>${Number(ethers.utils.formatEther(eth)).toFixed(4)}</dd>
    <dt>Demo dollars</dt><dd>${Number(ethers.utils.formatUnits(dusd, 6)).toLocaleString()}</dd><dt>Demo NFTs</dt><dd>${nfts}</dd></dl>`;
}

function renderBequests() {
  const box = $("#beqs");
  box.innerHTML = draft.bequests.map((b, i) => {
    const whole = b.kind === "nft" || b.kind === "erc721";
    return `<div class="card flat" style="padding:14px 16px" data-i="${i}">
      <div class="card-head" style="margin-bottom:8px"><b>Bequest ${i + 1}</b><button class="btn btn-ghost btn-sm" data-del="${i}" title="Remove">✕</button></div>
      <div class="grid" style="grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px">
        <div class="field" style="grid-column:span 2;margin:0"><label>Heir address</label><input data-f="heir" placeholder="0x…" value="${esc(b.heir)}"></div>
        <div class="field" style="margin:0"><label>Asset</label><select data-f="kind">${KIND_OPTIONS.map((k) => `<option value="${k.v}" ${k.v === b.kind ? "selected" : ""}>${k.label}</option>`).join("")}</select></div>
        ${b.kind === "erc20" || b.kind === "erc721" ? `<div class="field" style="margin:0"><label>Token contract</label><input data-f="token" placeholder="0x…" value="${esc(b.token)}"></div>` : ""}
        ${whole
          ? `<div class="field" style="margin:0"><label>Token id</label><input data-f="id" type="number" min="0" placeholder="${b.kind === "nft" ? "mint one →" : "id"}" value="${esc(b.id)}"></div>`
          : `<div class="field" style="margin:0"><label>Share of the pool (%)</label><input data-f="share" type="number" min="0.01" max="100" step="0.01" value="${esc(b.share)}"></div>`}
      </div>
      <details style="margin-top:10px" ${b.minAge || b.notBefore ? "open" : ""}><summary class="small muted" style="cursor:pointer">Conditions: age gate, time lock</summary>
        <div class="grid" style="grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px;margin-top:10px">
          <div class="field" style="margin:0"><label>Minimum age</label><input data-f="minAge" type="number" min="0" max="120" value="${esc(b.minAge)}"><div class="hint">0 = none. The heir proves it in zero knowledge.</div></div>
          ${b.minAge > 0 ? `<div class="field" style="margin:0"><label>Heir's birth date</label><input data-f="birthDate" type="date" value="${esc(b.birthDate)}"><div class="hint">Hidden in a commitment; only this heir's package holds it.</div></div>` : ""}
          <div class="field" style="margin:0"><label>Not before</label><input data-f="notBefore" type="datetime-local" value="${esc(b.notBefore)}"><div class="hint">Optional time lock.</div></div>
        </div>
      </details>
    </div>`;
  }).join("");
  $$("[data-f]", box).forEach((inp) => {
    const i = Number(inp.closest("[data-i]").dataset.i), f = inp.dataset.f;
    inp.addEventListener(inp.tagName === "SELECT" ? "change" : "input", () => {
      draft.bequests[i][f] = inp.type === "number" ? (inp.value === "" ? "" : Number(inp.value)) : inp.value;
      if (f === "kind" || (f === "minAge" && (inp.value === "0" || inp.value === "1" || !draft.bequests[i].birthDate))) renderBequests();
      else renderPools();
    });
  });
  $$("[data-del]", box).forEach((b) => b.addEventListener("click", () => { draft.bequests.splice(Number(b.dataset.del), 1); renderBequests(); }));
  renderPools();
}

const poolKey = (b) => b.kind === "dusd" ? "Demo dollars" : b.kind === "eth" ? "ETH" : b.kind === "erc20" ? `ERC-20 ${short(b.token) || "?"}` : null;
function renderPools() {
  const pools = new Map();
  for (const b of draft.bequests) { const k = poolKey(b); if (k) pools.set(k, (pools.get(k) ?? 0) + (Number(b.share) || 0)); }
  const el = $("#pools");
  if (!el) return;
  el.innerHTML = pools.size ? [...pools].map(([k, v]) => `<div style="margin-bottom:10px"><div class="row"><b>${esc(k)}</b><span class="spacer"></span>${v.toFixed(2)}%</div>
    <div class="alloc ${v > 100 ? "over" : ""}"><div style="width:${Math.min(v, 100)}%"></div></div>
    <div class="hint">${v > 100 ? "Over 100%." : v < 100 ? `${(100 - v).toFixed(2)}% goes to the residuary heir.` : "Fully allocated."}</div></div>`).join("")
    : '<span class="muted">NFTs go whole to one heir. Pools (tokens, ETH) are split by percentage of what the vault holds at the first claim.</span>';
}

function willError() {
  if (!draft.bequests.length) return "Add at least one bequest.";
  for (const [i, b] of draft.bequests.entries()) {
    const n = `Bequest ${i + 1}: `;
    if (!isAddr(b.heir)) return n + "enter a valid heir address.";
    if ((b.kind === "erc20" || b.kind === "erc721") && !isAddr(b.token)) return n + "enter the token contract address.";
    if ((b.kind === "nft" || b.kind === "erc721") && (b.id === "" || Number(b.id) < 0)) return n + "enter the NFT id (or mint a demo NFT).";
    if (b.kind !== "nft" && b.kind !== "erc721" && !(Number(b.share) > 0 && Number(b.share) <= 100)) return n + "the share must be between 0.01% and 100%.";
    if (b.minAge > 0 && !b.birthDate) return n + "an age gate needs the heir's birth date.";
    if (b.minAge > 255) return n + "minimum age too large.";
  }
  const pools = new Map();
  for (const b of draft.bequests) { const k = poolKey(b); if (k) pools.set(k, (pools.get(k) ?? 0) + Math.round(Number(b.share) * 100)); }
  for (const [k, v] of pools) if (v > 10000) return `The ${k} pool is allocated beyond 100%.`;
  if (!isAddr(draft.residuary)) return "Enter a valid residuary heir address.";
  return null;
}

/** Draft bequest -> the bequest format of core/will.js. */
function toBequest(b) {
  const out = { heir: ethers.utils.getAddress(b.heir.trim()) };
  if (b.kind === "nft") Object.assign(out, { kind: KIND.ERC721, token: ADDR.collectible, id: String(b.id) });
  else if (b.kind === "erc721") Object.assign(out, { kind: KIND.ERC721, token: ethers.utils.getAddress(b.token), id: String(b.id) });
  else if (b.kind === "dusd") Object.assign(out, { kind: KIND.ERC20, token: ADDR.dollar, shareBps: Math.round(b.share * 100) });
  else if (b.kind === "erc20") Object.assign(out, { kind: KIND.ERC20, token: ethers.utils.getAddress(b.token), shareBps: Math.round(b.share * 100) });
  else Object.assign(out, { kind: KIND.ETH, shareBps: Math.round(b.share * 100) });
  if (b.minAge > 0) Object.assign(out, { minAge: Number(b.minAge), birthDate: Number(b.birthDate.replaceAll("-", "")) });
  if (b.notBefore) out.notBefore = Math.floor(new Date(b.notBefore).getTime() / 1000);
  return out;
}

function describeLeaf(v) {
  const kind = Number(v[2]), token = v[3];
  let what;
  if (kind === KIND.ERC721) what = token.toLowerCase() === ADDR.collectible.toLowerCase() ? `<span class="nft">${nftArt(v[4])} Demo NFT #${esc(v[4])}</span>` : `NFT #${esc(v[4])} of ${short(token)}`;
  else if (kind === KIND.ETH) what = `${(v[5] / 100).toFixed(2)}% of the ETH`;
  else what = `${(v[5] / 100).toFixed(2)}% of ${token.toLowerCase() === ADDR.dollar.toLowerCase() ? "the demo dollars" : "token " + short(token)}`;
  const cond = [];
  if (Number(v[7]) > 0) cond.push(`<span class="chip">age ≥ ${v[7]}</span>`);
  if (Number(v[6]) > 0) cond.push(`<span class="chip">after ${fmtTime(Number(v[6]))}</span>`);
  return { what, cond: cond.join(" ") };
}

function wizReview() {
  const w = $("#wiz");
  const t = draft.t;
  w.innerHTML = `
  <div class="grid grid-2">
    <div class="card">
      <h2>Review</h2>
      <dl class="kv" style="margin:10px 0 16px">
        <dt>Key clock</dt><dd>${t.heartbeat} min</dd><dt>Life clock</dt><dd>${t.lifeProof} min</dd>
        <dt>Grace</dt><dd>${t.grace} min</dd><dt>Claim window</dt><dd>${t.claimWindow} min</dd>
        <dt>Residuary heir</dt><dd class="addr">${esc(draft.residuary)}</dd>
      </dl>
      <div class="table-wrap"><table><thead><tr><th>Heir</th><th>Receives</th><th></th></tr></thead><tbody>
      ${draft.bequests.map((b) => { const x = toBequest(b); const d = describeLeaf(["0", x.heir, x.kind, x.token ?? ethers.constants.AddressZero, x.id ?? "0", x.shareBps ?? 0, x.notBefore ?? 0, x.minAge ?? 0]); return `<tr><td class="addr">${short(x.heir)}</td><td>${d.what}</td><td>${d.cond}</td></tr>`; }).join("")}
      </tbody></table></div>
    </div>
    <div class="card">
      <h2>Create</h2>
      <p class="muted small">Your browser makes a fresh <b>liveness identity</b> for this vault and registers only its binding (a hash) on-chain.
      The identity is saved in this browser, and you will download a backup: <b>without it you cannot prove life for this vault</b> from another device.</p>
      <div class="notice info small" style="margin:12px 0">The will's details never go on-chain. Only its Merkle root does. After creation you download one package per heir.</div>
      <button class="btn btn-primary btn-lg" id="create" style="width:100%">Create vault on Sepolia</button>
      <div id="c-out" style="margin-top:14px"></div>
    </div>
  </div>
  <div class="row" style="margin-top:18px"><button class="btn btn-lg" id="back">← Will</button></div>`;
  $("#back").addEventListener("click", () => goStep(1));
  $("#create").addEventListener("click", async (e) => {
    const identity = newIdentity();
    const timersS = { heartbeat: t.heartbeat * 60, lifeProof: t.lifeProof * 60, grace: t.grace * 60, claimWindow: t.claimWindow * 60 };
    let created;
    const r = await runTx("Create vault", async () => {
      const signer = await needSigner();
      created = await A.createVault(signer, { timers: timersS, residuary: ethers.utils.getAddress(draft.residuary), bequests: draft.bequests.map(toBequest) }, identity);
      // Save before waiting: if the tab closes mid-wait, the identity survives.
      saveRecord({ vault: created.vault, owner: await signer.getAddress(), identity, will: created.will, timers: timersS, createdAt: nowS(), tx: created.tx.hash });
      return created;
    }, e.target);
    if (!r) return;
    const rec = loadRecord(created.vault);
    download(`vault-${created.vault.slice(2, 8)}-backup.json`, backupOf(rec));
    draft.step = 0; draft.bequests = []; draft.residuary = "";
    toast("Vault created. The backup file was downloaded: keep it private.", "", 9000);
    location.hash = `#/vault/${created.vault}`;
  });
}

// ------------------------------------------------------------------ my vaults

async function myVaults() {
  view.innerHTML = `<div class="card-head"><div><h1>My vaults</h1><p class="muted">Vaults created by your wallet, and vaults whose backup is in this browser.</p></div>
    <label class="btn" style="margin:0">Import backup<input type="file" id="imp" accept=".json,application/json" hidden></label></div>
    <div id="list" class="grid"><div class="card empty">Loading…</div></div>`;
  $("#imp").addEventListener("change", async (e) => {
    try {
      const rec = JSON.parse(await e.target.files[0].text());
      if (rec.format !== "succession-vault-backup/1" || !rec.vault || !rec.identity) throw new Error("This is not a vault backup from this app.");
      delete rec.format; delete rec.warning; delete rec.network;
      saveRecord(rec); toast("Backup imported."); myVaults();
    } catch (err) { errorToast(err); }
  });
  const local = allRecords();
  const set = new Map(local.map((r) => [r.vault.toLowerCase(), r.vault]));
  if (wallet.account) {
    try { for (const v of await vaultsOf(wallet.account, reader)) set.set(v.vault.toLowerCase(), v.vault); }
    catch { toast("Could not list your vaults from the chain right now; showing the ones saved in this browser.", "error"); }
  }
  const list = $("#list");
  if (!set.size) {
    list.innerHTML = `<div class="card empty">${ICON.box}<p>No vaults yet${wallet.account ? "" : " (or connect your wallet to find yours)"}.</p><a class="btn btn-primary" href="#/create">Create a vault</a></div>`;
    return;
  }
  list.innerHTML = [...set.values()].map((v) => `<a class="card" href="#/vault/${v}" data-v="${v}" style="color:inherit;text-decoration:none">
    <div class="row"><b class="addr">${v}</b><span class="spacer"></span><span class="badge b-neutral" data-status>…</span></div>
    <div class="small muted" data-line style="margin-top:6px">${loadRecord(v) ? "Identity saved in this browser" : '<span style="color:var(--wine)">No identity backup in this browser: import it to prove life</span>'}</div></a>`).join("");
  for (const el of $$("[data-v]", list)) {
    readVault(el.dataset.v, reader).then((s) => {
      const b = $("[data-status]", el);
      b.className = `badge ${statusClass(s.status)}`; b.textContent = s.status;
      const bits = [`${Number(ethers.utils.formatEther(s.balance)).toFixed(4)} ETH`];
      if (s.status === "Alive") bits.push(`deadline in ${fmtDur(s.deadline - s.chainNow)}`);
      $("[data-line]", el).insertAdjacentHTML("beforeend", " · " + bits.join(" · "));
    }).catch(() => {});
  }
}
const statusClass = (s) => ({ Alive: "b-alive", Grace: "b-grace", Claimable: "b-claimable", Settled: "b-settled" }[s] ?? "b-neutral");

// ------------------------------------------------------------------ vault dashboard

async function vaultView(address) {
  if (!isAddr(address)) { view.innerHTML = '<div class="notice bad">Not a vault address.</div>'; return; }
  address = ethers.utils.getAddress(address);
  view.innerHTML = `<div class="card empty">Reading the vault from Sepolia…</div>`;
  const code = await reader.getCode(address);
  if (code === "0x") { view.innerHTML = `<div class="notice bad">No contract at ${esc(address)} on Sepolia (yet). If you just created it, wait a few seconds and reload.</div>`; return; }
  let s = await readVault(address, reader);
  const rec = loadRecord(address);
  const isOwner = wallet.account && wallet.account.toLowerCase() === s.owner.toLowerCase();
  let offset = s.chainNow - nowS();   // chain clock vs local clock

  view.innerHTML = `
  <div class="card-head" style="margin-bottom:18px">
    <div><div class="eyebrow">Vault</div><h1 class="addr" style="font-size:1.35rem;word-break:break-all">${address}</h1>
    <div class="small muted">Owner ${addrHtml(s.owner)} · <a href="${addrLink(address)}" target="_blank" rel="noopener">Etherscan</a>${isOwner ? ' · <span class="chip">you own this vault</span>' : ""}</div></div>
  </div>
  <div class="card">
    <div class="status-hero">
      <span id="badge" class="badge"></span>
      <div><div class="countdown" id="count">—</div><div class="small muted" id="count-label"></div></div>
      <span class="spacer"></span>
      <div id="presence" class="small"></div>
    </div>
    <div class="timeline" style="margin-top:26px"><div class="tl-bar" id="tl"></div><div class="tl-ticks" id="ticks"></div><div class="small muted" id="legend"></div></div>
    <div class="grid grid-2" style="margin-top:6px">
      <div id="clocks"></div>
      <dl class="kv small" id="facts"></dl>
    </div>
  </div>
  <div class="grid grid-2 section" id="panels"></div>`;

  const draw = () => {
    const now = nowS() + offset;
    const status = s.settled ? "Settled" : now <= s.deadline ? "Alive" : now <= s.claimableAt ? "Grace" : "Claimable";
    const b = $("#badge"); b.className = `badge ${statusClass(status)}`; b.textContent = status;
    const [label, target] = status === "Alive" ? ["until the deadline (then grace)", s.deadline]
      : status === "Grace" ? ["of grace left: the owner can still come back", s.claimableAt]
      : now < s.sweepAt ? ["left in the claim window", s.sweepAt] : ["claim window over: leftovers can be swept", null];
    $("#count").textContent = target ? fmtDur(target - now) : "Ended";
    $("#count-label").textContent = label;
    // The bar spans the vault's current cycle; a "now" far past it is pinned to the right edge.
    const start = Math.min(Math.max(s.tH, s.presenceAt) || s.tH, now) - 60;
    const end = s.sweepAt + Math.max(120, (s.sweepAt - start) * 0.12);
    const pct = (t) => ((Math.min(Math.max(t, start), end) - start) / (end - start)) * 100;
    const segs = [["seg-alive", start, s.deadline, "Alive"], ["seg-grace", s.deadline, s.claimableAt, "Grace"], ["seg-claim", s.claimableAt, s.sweepAt, "Claims"], ["seg-sweep", s.sweepAt, end, "Sweep"]];
    $("#tl").innerHTML = segs.map(([c, a, z, n]) => `<div class="tl-seg ${c}" style="width:${pct(z) - pct(a)}%" title="${n}: ${fmtTime(a)} → ${fmtTime(z)}">${pct(z) - pct(a) > 11 ? n : ""}</div>`).join("")
      + `<div class="tl-now" style="left:calc(${pct(now)}% - 1.5px)"></div>`;
    let last = -100;
    $("#ticks").innerHTML = [[s.deadline, "deadline"], [s.claimableAt, "claims open"], [s.sweepAt, "sweep"]].map(([t, n]) => {
      const p = pct(t); if (p - last < 22) return ""; last = p;
      return `<span style="left:${Math.min(Math.max(p, 6), 94)}%">${n} ${fmtClock(t)}</span>`;
    }).join("");
    $("#legend").innerHTML = `Deadline ${fmtTime(s.deadline)} · claims open ${fmtTime(s.claimableAt)} · sweep from ${fmtTime(s.sweepAt)}`;
  };

  const drawStatic = () => {
    const keyDue = Math.max(s.tH, s.presenceAt) + s.heartbeat, lifeDue = s.presenceAt + s.lifeProof;
    const binding = keyDue <= lifeDue ? "key" : "life";
    $("#clocks").innerHTML = `<div class="clocks" style="margin-top:8px">
      <div class="clock possession"><b>Key clock</b> ${binding === "key" ? '<span class="chip">sets the deadline</span>' : ""}<div class="small">Last heartbeat ${fmtClock(Math.max(s.tH, s.presenceAt))} · due ${fmtClock(keyDue)} · every ${mins(s.heartbeat)}</div></div>
      <div class="clock presence"><b>Life clock</b> ${binding === "life" ? '<span class="chip">sets the deadline</span>' : ""}<div class="small">${s.proven ? `Last proof ${fmtClock(s.presenceAt)}` : "No proof of life yet"} · due ${fmtClock(lifeDue)} · every ${mins(s.lifeProof)}</div></div></div>`;
    $("#facts").innerHTML = `<dt>Balance</dt><dd>${Number(ethers.utils.formatEther(s.balance)).toFixed(5)} ETH</dd>
      <dt>Grace / claim window</dt><dd>${mins(s.grace)} / ${mins(s.claimWindow)}</dd>
      <dt>Residuary heir</dt><dd>${addrHtml(s.residuary)}</dd><dt>Will root</dt><dd class="mono">${s.root.slice(0, 18)}…</dd>`;
    const authUntil = s.presenceAt + 86400;
    $("#presence").innerHTML = s.settled ? "" : s.proven && nowS() + offset < authUntil
      ? `<span class="badge b-ok">Owner actions unlocked</span><div class="muted" style="margin-top:4px">until ${fmtTime(authUntil)}</div>`
      : `<span class="badge b-warn">Owner actions locked</span><div class="muted" style="margin-top:4px">need a proof of life from the last 24 h</div>`;
  };

  const refresh = async () => {
    try { s = await readVault(address, reader); offset = s.chainNow - nowS(); drawStatic(); draw(); renderPanels(); } catch { /* keep the last view */ }
  };

  const renderPanels = () => {
    const P = $("#panels");
    const parts = [];
    if (!s.settled && (isOwner || rec)) parts.push(ownerPanel());
    parts.push(holdingsPanel());
    if (rec?.will) parts.push(willPanel());
    if (!isOwner && !rec) parts.push(`<div class="card"><h2>Are you an heir?</h2><p class="muted">Load your will package on the claim page to see and claim your bequests.</p><a class="btn btn-primary" href="#/claim">Open heir claim</a></div>`);
    if (nowS() + offset > s.sweepAt) parts.push(sweepPanel());
    P.innerHTML = parts.join("");
    wirePanels();
  };

  const ownerPanel = () => `<div class="card">
    <h2>Stay alive</h2>
    <p class="small muted">A heartbeat resets the key clock. A proof of life resets both clocks and unlocks owner actions for 24 hours.</p>
    <div class="row" style="margin:12px 0">
      <button class="btn btn-gold" id="hb" ${isOwner ? "" : "disabled title='Connect the owner wallet'"}>${ICON.heart.replace("<svg", '<svg style="width:16px;height:16px;vertical-align:-3px"')} Heartbeat</button>
      <button class="btn btn-primary" id="pol" ${rec ? "" : "disabled title='Import this vault backup first'"}>${ICON.shield.replace("<svg", '<svg style="width:16px;height:16px;vertical-align:-3px"')} Prove life</button>
    </div>
    ${rec ? "" : '<div class="notice warn small">This browser has no liveness identity for this vault. Import the vault backup on "My vaults" to prove life.</div>'}
    <div id="pol-steps"></div>
    ${isOwner ? `<hr><h3>Deposit</h3>
    <div class="grid" style="grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:10px">
      <div class="row" style="flex-wrap:nowrap"><input id="d-eth" type="number" min="0" step="0.001" placeholder="ETH" value="0.001"><button class="btn btn-sm" id="b-eth">Deposit ETH</button></div>
      <div class="row" style="flex-wrap:nowrap"><input id="d-dusd" type="number" min="0" step="1" placeholder="DUSD" value="500"><button class="btn btn-sm" id="b-dusd">Deposit DUSD</button></div>
      <div class="row" style="flex-wrap:nowrap"><input id="d-nft" type="number" min="0" placeholder="NFT id" value="${esc(firstNftId() ?? "")}"><button class="btn btn-sm" id="b-nft">Deposit NFT</button></div>
    </div>
    <div class="row small" style="margin-top:8px"><button class="btn btn-ghost btn-sm" id="b-faucet">Get 1,000 DUSD</button><button class="btn btn-ghost btn-sm" id="b-mint">Mint a demo NFT</button></div>
    <hr><h3>Withdraw</h3>
    <p class="small muted">Needs a proof of life from the last 24 hours: a key alone cannot empty the vault.</p>
    <div class="grid" style="grid-template-columns:120px 1fr;gap:10px">
      <select id="w-kind" aria-label="Asset"><option value="eth">ETH</option><option value="dusd">DUSD</option><option value="nft">Demo NFT</option></select>
      <input id="w-amt" placeholder="Amount, or the NFT id" aria-label="Amount or NFT id">
      <input id="w-to" style="grid-column:1/-1" placeholder="Send to 0x…" aria-label="Recipient" value="${esc(wallet.account ?? "")}">
    </div>
    <div class="row" style="margin-top:10px"><button class="btn btn-sm" id="b-w">Withdraw</button></div>` : ""}
  </div>`;

  const firstNftId = () => rec?.will?.leaves.find((l) => Number(l.bequest[2]) === KIND.ERC721 && l.bequest[3].toLowerCase() === ADDR.collectible.toLowerCase())?.bequest[4];

  const holdingsPanel = () => `<div class="card"><h2>Holdings</h2><div id="hold" class="small muted">Reading balances…</div></div>`;

  const willPanel = () => `<div class="card">
    <div class="card-head"><h2>The will</h2><button class="btn btn-sm" id="bk">Download backup</button></div>
    <div class="table-wrap"><table><thead><tr><th>Heir</th><th>Receives</th><th>Status</th></tr></thead><tbody id="will-rows">
    ${rec.will.leaves.map((l) => { const d = describeLeaf(l.bequest); return `<tr><td>${addrHtml(l.bequest[1])}</td><td>${d.what} ${d.cond}</td><td data-claimed="${l.bequest[0]}"><span class="muted">…</span></td></tr>`; }).join("")}
    </tbody></table></div>
    <h3 style="margin-top:16px">Will packages for heirs</h3>
    <p class="small muted">Each heir's file holds only their own bequests and age secrets. Give it to them privately.</p>
    <div class="row">${heirsOf(rec.will).map((h) => `<button class="btn btn-sm" data-pkg="${h}">Package for ${short(h)}</button>`).join("")}</div>
  </div>`;

  const sweepPanel = () => `<div class="card"><h2>Sweep leftovers</h2><p class="small muted">The claim window is over. Anyone can send what is left to the residuary heir.</p>
    <div class="row"><button class="btn btn-plum" data-sweep="eth">Sweep ETH</button><button class="btn btn-plum" data-sweep="dusd">Sweep DUSD</button></div></div>`;

  const wirePanels = () => {
    const on = (id, fn) => { const el = $(id); if (el) el.addEventListener("click", (e) => fn(e.currentTarget)); };
    on("#hb", (btn) => runTx("Heartbeat", async () => A.heartbeat(await needSigner(), address), btn).then((r) => r && refresh()));
    on("#pol", (btn) => proveLifeFlow(btn));
    on("#b-eth", (btn) => runTx("Deposit ETH", async () => A.depositEth(await needSigner(), address, $("#d-eth").value), btn).then((r) => r && refresh()));
    on("#b-dusd", (btn) => runTx("Deposit DUSD", async () => A.depositDollars(await needSigner(), address, $("#d-dusd").value), btn).then((r) => r && refresh()));
    on("#b-nft", (btn) => runTx(`Deposit NFT #${$("#d-nft").value}`, async () => A.depositCollectible(await needSigner(), address, $("#d-nft").value), btn).then((r) => r && refresh()));
    on("#b-faucet", (btn) => runTx("Demo dollar faucet", async () => A.dollarFaucet(await needSigner()), btn));
    on("#b-mint", (btn) => runTx("Mint demo NFT", async () => A.mintCollectible(await needSigner()), btn).then((r) => { if (r) { $("#d-nft").value = r.id; toast(`Minted demo NFT #${r.id}. Deposit it, and add it to a will for it to be inherited.`); } }));
    on("#b-w", (btn) => {
      const kind = $("#w-kind").value, v = $("#w-amt").value.trim(), to = $("#w-to").value.trim();
      if (!isAddr(to)) return errorToast("Enter a valid recipient.");
      const args = kind === "eth" ? { kind: KIND.ETH, amount: ethers.utils.parseEther(v || "0"), to }
        : kind === "dusd" ? { kind: KIND.ERC20, token: ADDR.dollar, amount: ethers.utils.parseUnits(v || "0", 6), to }
        : { kind: KIND.ERC721, token: ADDR.collectible, id: v, amount: 1, to };
      runTx("Withdraw", async () => A.withdraw(await needSigner(), address, args), btn).then((r) => r && refresh());
    });
    on("#bk", () => download(`vault-${address.slice(2, 8)}-backup.json`, backupOf(rec)));
    $$("[data-pkg]").forEach((b) => b.addEventListener("click", () => download(`will-${address.slice(2, 8)}-heir-${b.dataset.pkg.slice(2, 8)}.json`, willPackage(address, rec.will, b.dataset.pkg))));
    $$("[data-sweep]").forEach((b) => b.addEventListener("click", () => runTx("Sweep", async () => A.sweep(await needSigner(), address, b.dataset.sweep === "eth" ? { kind: KIND.ETH } : { kind: KIND.ERC20, token: ADDR.dollar }), b).then((r) => r && refresh())));
    loadHoldings();
    if (rec?.will) {
      const v = vaultAt(address, reader);
      for (const td of $$("[data-claimed]")) v.isClaimed(td.dataset.claimed).then((c) => { td.innerHTML = c ? '<span class="badge b-ok">claimed</span>' : '<span class="badge b-neutral">waiting</span>'; }).catch(() => {});
    }
  };

  const loadHoldings = async () => {
    const el = $("#hold");
    try {
      const dusd = await new ethers.Contract(ADDR.dollar, ERC20_ABI, reader).balanceOf(address);
      const nftIds = new Set(rec?.will?.leaves.filter((l) => Number(l.bequest[2]) === KIND.ERC721 && l.bequest[3].toLowerCase() === ADDR.collectible.toLowerCase()).map((l) => l.bequest[4]) ?? []);
      const nft = new ethers.Contract(ADDR.collectible, ERC721_ABI, reader);
      const nftRows = await Promise.all([...nftIds].map(async (id) => ({ id, held: (await nft.ownerOf(id).catch(() => "")).toLowerCase() === address.toLowerCase() })));
      el.classList.remove("muted");
      el.innerHTML = `<table><tbody>
        <tr><td>Sepolia ETH</td><td style="text-align:right"><b>${Number(ethers.utils.formatEther(s.balance)).toFixed(5)}</b></td></tr>
        <tr><td>Demo dollars</td><td style="text-align:right"><b>${Number(ethers.utils.formatUnits(dusd, 6)).toLocaleString()}</b></td></tr>
        ${nftRows.map((r) => `<tr><td><span class="nft">${nftArt(r.id)} Demo NFT #${esc(r.id)}</span></td><td style="text-align:right">${r.held ? '<span class="badge b-ok">in vault</span>' : s.settled ? '<span class="badge b-neutral">paid out</span>' : '<span class="badge b-warn">not in vault</span>'}</td></tr>`).join("")}
      </tbody></table>${nftRows.some((r) => !r.held) && !s.settled ? '<p class="small muted" style="margin-top:8px">A bequeathed NFT that is not in the vault cannot be claimed. Deposit it.</p>' : ""}`;
    } catch { el.textContent = "Could not read balances right now."; }
  };

  async function proveLifeFlow(btn) {
    const box = $("#pol-steps");
    const steps = [["load", "Download the circuit and proving key (once)"], ["issuer", "Liveness check by the demo issuer (signs a credential)"], ["prove", "Zero-knowledge proof in your browser"], ["send", "Send the proof to the vault (any wallet can relay)"], ["done", "Confirmed on Sepolia"]];
    const set = (cur, extra = "") => {
      const i = steps.findIndex(([k]) => k === cur);
      box.innerHTML = `<div class="progress">${steps.map(([k, t], j) => `<div class="pstep ${j < i ? "done" : j === i ? "active" : ""}"><span class="dot"></span>${t}${j === i && extra ? ` <span class="muted">${extra}</span>` : ""}</div>`).join("")}</div>`;
    };
    btn.disabled = true;
    try {
      const signer = await needSigner();
      set("load");
      const c = await circuits("liveness", (got, total) => set("load", loadNote(got, total)));
      let ms = 0;
      const out = await A.proveLife(signer, address, rec.identity, snark(), c, (step, t) => { if (t) ms = t; set(step, step === "send" ? `(proof took ${(ms / 1000).toFixed(1)} s)` : ""); });
      set("send", `(proof took ${(out.provingMs / 1000).toFixed(1)} s) · waiting for the block…`);
      await out.tx.wait();
      set("done");
      box.querySelector(".pstep:last-child").classList.replace("active", "done");
      toast(`Proof of life confirmed. <a href="${txLink(out.tx.hash)}" target="_blank" rel="noopener">view</a>`);
      refresh();
    } catch (e) {
      box.innerHTML = "";
      errorToast(e);
    } finally { btn.disabled = false; }
  }

  drawStatic(); draw(); renderPanels();
  timers.push(setInterval(draw, 1000));
  timers.push(setInterval(refresh, 20000));
}

// ------------------------------------------------------------------ heir claim

let loadedPkg = null;
function claimView() {
  view.innerHTML = `
  <h1>Claim an inheritance</h1>
  <p class="muted">Load the will package the owner gave you. Claims open when the vault is <span class="badge b-claimable">Claimable</span>.
  Anyone can send the claim; the asset always goes to the heir named in the will.</p>
  <div class="grid grid-2" style="margin-top:16px">
    <div class="card">
      <h3>Your will package</h3>
      <label class="btn" style="display:inline-block;margin-bottom:10px">Choose file…<input type="file" id="pkg-file" accept=".json,application/json" hidden></label>
      <textarea id="pkg-text" placeholder='…or paste it here: {"format":"succession-vault-will/1", …}'></textarea>
      <div class="row" style="margin-top:10px"><button class="btn btn-primary" id="pkg-load">Load</button></div>
    </div>
    <div class="card flat"><h3>What happens</h3><ol class="small muted" style="padding-left:18px;margin:0">
      <li>The app checks your bequests against the vault's will root.</li>
      <li>For an age-restricted bequest, your browser proves "born on or before the cut-off date" without revealing the date.</li>
      <li>The vault pays you directly: NFTs whole, pools by percentage of what it held at the first claim.</li></ol></div>
  </div>
  <div id="claim-out" class="section"></div>`;
  $("#pkg-file").addEventListener("change", async (e) => { $("#pkg-text").value = await e.target.files[0].text(); loadPkg(); });
  $("#pkg-load").addEventListener("click", loadPkg);
  if (loadedPkg) { $("#pkg-text").value = JSON.stringify(loadedPkg, null, 2); loadPkg(); }
}

async function loadPkg() {
  const out = $("#claim-out");
  let pkg;
  try { pkg = parseWillPackage($("#pkg-text").value); } catch (e) { out.innerHTML = `<div class="notice bad">${esc(e.message)}</div>`; return; }
  loadedPkg = pkg;
  out.innerHTML = `<div class="card empty">Reading the vault…</div>`;
  let s;
  try { s = await readVault(pkg.vault, reader); } catch { out.innerHTML = `<div class="notice bad">Could not read vault ${esc(pkg.vault)} on Sepolia.</div>`; return; }
  if (s.root.toLowerCase() !== pkg.root.toLowerCase()) {
    out.innerHTML = `<div class="notice bad">This package is for an older version of the will: the vault's will root has changed. Ask the owner for a new package.</div>`; return;
  }
  const v = vaultAt(pkg.vault, reader);
  const claimed = await Promise.all(pkg.bequests.map((b) => v.isClaimed(b.bequest[0]).catch(() => false)));
  const now = s.chainNow;
  const open = s.status === "Claimable" || s.status === "Settled";
  out.innerHTML = `<div class="card">
    <div class="card-head"><div><h2>Vault <span class="addr">${short(pkg.vault)}</span></h2><div class="small muted">${open ? "Claims are open." : s.status === "Grace" ? `Grace period: claims open in ${fmtDur(s.claimableAt - now)}.` : `The owner is alive. Claims can open ${fmtTime(s.claimableAt)} at the earliest.`}</div></div>
    <div class="row"><span class="badge ${statusClass(s.status)}">${s.status}</span><a class="btn btn-sm" href="#/vault/${pkg.vault}">Timeline</a></div></div>
    <div class="table-wrap"><table><thead><tr><th>Heir</th><th>Bequest</th><th></th></tr></thead><tbody>
    ${pkg.bequests.map((e, i) => { const d = describeLeaf(e.bequest); const locked = Number(e.bequest[6]) > now;
      return `<tr><td>${addrHtml(e.bequest[1])}</td><td>${d.what} ${d.cond}</td><td style="text-align:right">${claimed[i] ? '<span class="badge b-ok">claimed</span>'
        : `<button class="btn btn-primary btn-sm" data-claim="${i}" ${open && !locked ? "" : "disabled"}>${Number(e.bequest[7]) > 0 ? "Prove age & claim" : "Claim"}</button>`}</td></tr>`; }).join("")}
    </tbody></table></div></div>`;
  $$("[data-claim]", out).forEach((b) => b.addEventListener("click", async () => {
    const entry = pkg.bequests[Number(b.dataset.claim)];
    const label = Number(entry.bequest[7]) > 0 ? "Age-proved claim" : "Claim";
    b.textContent = Number(entry.bequest[7]) > 0 ? "Proving age…" : "Sending…";
    const r = await runTx(label, async () => {
      const signer = await needSigner();
      const c = Number(entry.bequest[7]) > 0 ? await circuits("age") : {};
      return A.claim(signer, pkg.vault, entry, snark(), c);
    }, b);
    if (r) loadPkg(); else b.textContent = "Retry";
  }));
}

// ------------------------------------------------------------------ explore

function exploreView() {
  view.innerHTML = `
  <h1>Explore a vault</h1>
  <p class="muted">Anyone can read a vault's state: owner, clocks, deadline, and balance. The will's contents stay private.</p>
  <div class="card" style="max-width:720px;margin-top:16px">
    <label>Vault address</label>
    <div class="row" style="flex-wrap:nowrap"><input id="ex" placeholder="0x…"><button class="btn btn-primary" id="go">Open</button></div>
    <div id="ex-err" class="err-text"></div>
  </div>
  <div class="card section" style="max-width:720px"><h3>Recent vaults</h3><div id="recent" class="small muted">Loading the factory's recent vaults…</div></div>`;
  const go = () => { const a = $("#ex").value.trim(); if (!isAddr(a)) { $("#ex-err").textContent = "Enter a valid address."; return; } location.hash = `#/vault/${ethers.utils.getAddress(a)}`; };
  $("#go").addEventListener("click", go);
  $("#ex").addEventListener("keydown", (e) => e.key === "Enter" && go());
  (async () => {
    const f = new ethers.Contract(ADDR.factory, ["event VaultCreated(address indexed owner, address indexed vault, bytes32 salt)"], reader);
    const latest = await reader.getBlockNumber();
    const logs = await f.queryFilter(f.filters.VaultCreated(), Math.max(latest - 45000, 11782096), latest);
    const el = $("#recent");
    if (!el) return;
    el.classList.remove("muted");
    el.innerHTML = logs.length ? `<table><tbody>${logs.slice(-10).reverse().map((l) => `<tr><td><a class="addr" href="#/vault/${l.args.vault}">${l.args.vault}</a></td><td class="muted">owner ${short(l.args.owner)}</td></tr>`).join("")}</tbody></table>`
      : '<span class="muted">No vaults created in the last week. <a href="#/create">Create one</a>.</span>';
  })().catch(() => { const el = $("#recent"); if (el) el.textContent = "Could not load recent vaults right now."; });
}

route();
