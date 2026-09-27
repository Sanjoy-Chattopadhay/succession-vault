// Takes the README screenshots of the app with headless Chrome, against the demo vaults made by
// seed-demo.mjs. The page gets a read-only "watch" wallet: it reports the owner's address and
// forwards reads to the public RPC, holds no key and refuses to sign.
//   serve dist/ on http://localhost:5173 (e.g. python -m http.server 5173 -d dist), then
//   node tools/screenshots.mjs alive | claimable | claimed | sweep | all
// Output: <repo>/docs/screenshots/*.png when that folder exists, else tools/out/screenshots (or SHOTS_DIR).
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { launch } from "./cdp.mjs";
import { NETWORK } from "../src/core/chain.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DOCS = path.resolve(HERE, "..", "..", "docs");
const OUT = process.env.SHOTS_DIR ?? (fs.existsSync(DOCS) ? path.join(DOCS, "screenshots") : path.join(HERE, "out", "screenshots"));
const APP = process.env.APP_URL ?? "http://localhost:5173/";
const DATA = path.join(HERE, "out");
const load = (name) => JSON.parse(fs.readFileSync(path.join(DATA, name), "utf8"));
const alive = load("alive-record.json");
const claims = load("claims-record.json");
const heirFiles = (label) => fs.readdirSync(DATA).filter((f) => f.startsWith(`${label}-heir-`)).map((f) => load(f));
fs.mkdirSync(OUT, { recursive: true });

const phase = process.argv[2] ?? "all";
const DSF = 1.5;
const c = await launch({ port: 9334 });
const errors = [];
c.on((m) => {
  if (m.method === "Runtime.exceptionThrown") errors.push(m.params.exceptionDetails.exception?.description ?? m.params.exceptionDetails.text);
  if (m.method === "Runtime.consoleAPICalled" && m.params.type === "error") errors.push(m.params.args.map((a) => a.value ?? a.description).join(" "));
});

const shim = `(() => {
  const OWNER = ${JSON.stringify(alive.owner)}, RPC = ${JSON.stringify(NETWORK.rpc)};
  let n = 0;
  const rpc = async (method, params) => {
    const r = await fetch(RPC, { method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: ++n, method, params }) });
    const j = await r.json();
    if (j.error) throw Object.assign(new Error(j.error.message), j.error);
    return j.result;
  };
  window.ethereum = {
    request: async ({ method, params = [] }) => {
      if (method === "eth_requestAccounts" || method === "eth_accounts") return [OWNER];
      if (method === "eth_chainId") return "0xaa36a7";
      if (method === "net_version") return "11155111";
      if (method.startsWith("wallet_")) return null;
      if (/^(eth_send|eth_sign|personal_sign)/.test(method)) throw Object.assign(new Error("read-only watch wallet"), { code: 4001 });
      return rpc(method, params);
    },
    on() {}, removeListener() {},
  };
  for (const r of ${JSON.stringify([alive, claims])}) localStorage.setItem("sv:vault:" + r.vault.toLowerCase(), JSON.stringify(r));
})();`;
await c.send("Page.addScriptToEvaluateOnNewDocument", { source: shim });

async function viewport(width, height, { dark = false, mobile = false } = {}) {
  await c.send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: DSF, mobile });
  await c.send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: dark ? "dark" : "light" }] });
}
let visit = 0;
async function open(hash, ready) {
  await c.navigate(`${APP}?v=${++visit}${hash}`); // a fresh document every time (hash changes fire no load event)
  await c.sleep(600);
  if (ready) await c.waitFor(ready, 45000);
  await c.sleep(900);
}
const text = (s) => `document.body.innerText.includes(${JSON.stringify(s)})`;

/** Screenshot the viewport, or the box around `selector` (page coordinates, any scroll). */
async function shot(name, { selector, pad = 16, height } = {}) {
  let clip;
  if (selector) {
    clip = await c.evaluate(`(() => {
      const els = [...document.querySelectorAll(${JSON.stringify(selector)})];
      if (!els.length) return null;
      const r = els.map((e) => e.getBoundingClientRect());
      const x0 = Math.min(...r.map((b) => b.left)), y0 = Math.min(...r.map((b) => b.top));
      const x1 = Math.max(...r.map((b) => b.right)), y1 = Math.max(...r.map((b) => b.bottom));
      return { x: Math.max(0, x0 - ${pad}), y: Math.max(0, y0 + scrollY - ${pad}), width: x1 - x0 + 2 * ${pad}, height: y1 - y0 + 2 * ${pad}, scale: 1 };
    })()`);
    if (!clip) throw new Error(`no element for ${selector}`);
  } else {
    const [w, h] = await c.evaluate("[innerWidth, " + (height ? height : "innerHeight") + "]");
    clip = { x: 0, y: 0, width: w, height: h, scale: 1 };
  }
  const r = await c.send("Page.captureScreenshot", { format: "png", clip, captureBeyondViewport: true });
  fs.writeFileSync(path.join(OUT, `${name}.png`), Buffer.from(r.data, "base64"));
  console.log(`  ${name}.png  ${Math.round(clip.width)} x ${Math.round(clip.height)} css px`);
}
const setField = (sel, index, value) => `(() => {
  const el = document.querySelectorAll(${JSON.stringify(sel)})[${index}];
  el.value = ${JSON.stringify(value)};
  el.dispatchEvent(new Event(el.tagName === "SELECT" ? "change" : "input", { bubbles: true }));
})()`;

try {
  if (phase === "alive" || phase === "all") {
    console.log("phase: alive");
    await viewport(1280, 800);
    await open("#/", text("Two clocks, one deadline"));
    await shot("01-overview");
    await c.evaluate(`document.getElementById("try").scrollIntoView({ block: "center" }); document.getElementById("try").click()`);
    await c.waitFor(`/proof verifies|did not verify/.test(document.getElementById("try-out").innerText) && /Sepolia verifier contract (accepts|rejected)|could not be reached/.test(document.getElementById("try-out").innerText)`, 90000);
    await c.sleep(400);
    await shot("02-proof-of-life", { selector: "section.card" });

    await open("#/create", text("How long, and how fast?"));
    await shot("03-create-timers", { selector: "#view", pad: 8 });
    await c.evaluate(`document.getElementById("next").click()`);
    await c.waitFor(`!!document.getElementById("beqs")`);
    const [hA, hB] = [...new Set(alive.will.leaves.map((l) => l.bequest[1]))];
    await c.evaluate(setField("[data-f=heir]", 0, hA));
    await c.evaluate(setField("[data-f=id]", 0, "1"));
    await c.evaluate(`document.getElementById("add").click()`);
    await c.evaluate(setField("[data-f=heir]", 1, hA));
    await c.evaluate(setField("[data-f=share]", 0, "60"));
    await c.evaluate(`document.getElementById("add").click()`);
    await c.evaluate(setField("[data-f=heir]", 2, hB));
    await c.evaluate(setField("[data-f=share]", 1, "40"));
    await c.evaluate(`document.querySelectorAll("details")[2].open = true`);
    await c.evaluate(setField("[data-f=minAge]", 2, "18"));
    await c.sleep(200);
    await c.evaluate(setField("[data-f=birthDate]", 0, "2001-04-05"));
    await c.evaluate(`document.getElementById("add").click()`);
    await c.evaluate(setField("[data-f=heir]", 3, hB));
    await c.evaluate(setField("[data-f=kind]", 3, "eth"));
    await c.sleep(200);
    await c.evaluate(setField("[data-f=heir]", 3, hB));
    await c.evaluate(`document.querySelectorAll("details")[2].open = true`);
    await c.sleep(1500);
    await shot("04-create-will", { selector: "#wiz", pad: 8 });
    await c.evaluate(`document.getElementById("next").click()`);
    await c.waitFor(text("Create vault on Sepolia"));
    await shot("05-create-review", { selector: "#wiz", pad: 8 });

    await open(`#/vault/${alive.vault}`, `document.querySelector("#hold table") && document.querySelectorAll("[data-claimed] .badge").length > 0`);
    await shot("06-vault-alive");
    await shot("07-vault-panels", { selector: "#panels", pad: 8 });
    await open("#/vaults", `document.querySelectorAll("[data-status]").length && ![...document.querySelectorAll("[data-status]")].some((e) => e.textContent === "…")`);
    await shot("08-my-vaults", { selector: "#view", pad: 8 });
    await open("#/explore", `document.querySelector("#recent table")`);
    await shot("09-explore", { selector: "#view", pad: 8 });

    await viewport(390, 844, { mobile: true });
    await open(`#/vault/${alive.vault}`, `document.querySelector("#hold table")`);
    await shot("10-mobile");
    await viewport(1280, 800, { dark: true });
    await open(`#/vault/${alive.vault}`, `document.querySelector("#hold table")`);
    await shot("11-dark");
  }

  if (phase === "claimable" || phase === "claimed" || phase === "all") {
    console.log(`phase: ${phase}`);
    await viewport(1280, 800);
    const pkg = heirFiles("claims").find((p) => p.bequests.some((b) => Number(b.bequest[7]) > 0));
    await open("#/claim", text("Your will package"));
    await c.evaluate(`document.getElementById("pkg-text").value = ${JSON.stringify(JSON.stringify(pkg, null, 2))}; document.getElementById("pkg-load").click()`);
    await c.waitFor(`document.querySelector("#claim-out table")`, 45000);
    await c.sleep(800);
    await shot(phase === "claimable" ? "12-heir-claimable" : "13-heir-claimed", { selector: "#claim-out", pad: 8 });
    if (phase !== "claimable") {
      await open(`#/vault/${claims.vault}`, `document.querySelectorAll("[data-claimed] .badge").length > 0`);
      await shot("14-vault-settled");
      await shot("15-vault-settled-panels", { selector: "#panels", pad: 8 });
    }
  }
  if (phase === "sweep") {
    console.log("phase: sweep");
    await viewport(1280, 800);
    await open(`#/vault/${claims.vault}`, `document.querySelector("[data-sweep]") && document.querySelector("#hold table") && document.querySelectorAll("[data-claimed] .badge").length > 0`);
    await shot("16-sweep", { selector: "#panels", pad: 8 });
  }
} finally {
  await c.close();
  if (errors.length) console.log("page errors:\n  " + [...new Set(errors)].join("\n  "));
}
