// Minimal Chrome DevTools Protocol client (Node 22+, no dependencies): starts a headless Chrome and
// drives its first tab. Used to export the draw.io figures and to take the app's screenshots.
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const CHROME = process.env.CHROME ?? [
  "C:/Program Files/Google/Chrome/Application/chrome.exe",
  "C:/Program Files (x86)/Google/Chrome/Application/chrome.exe",
  "/usr/bin/google-chrome",
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
].find((p) => fs.existsSync(p));

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export async function launch({ port = 9333 } = {}) {
  if (!CHROME) throw new Error("Chrome not found; set CHROME=<path to chrome>");
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), "cdp-profile-"));
  const proc = spawn(CHROME, [
    "--headless=new", `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, "--no-first-run",
    "--no-default-browser-check", "--hide-scrollbars", "--force-color-profile=srgb", "--font-render-hinting=none",
    "--disable-extensions", "about:blank",
  ], { stdio: "ignore" });

  let targets;
  for (let n = 0; n < 150 && !targets; n++) {
    try { targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json(); } catch { await sleep(100); }
  }
  if (!targets) { proc.kill(); throw new Error("Chrome did not open its debugging port"); }
  const target = targets.find((t) => t.type === "page");
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });

  let seq = 0;
  const pending = new Map();
  const listeners = new Set();
  ws.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)) {
      const { resolve, reject } = pending.get(m.id);
      pending.delete(m.id);
      if (m.error) reject(new Error(`${m.error.message} ${m.error.data ?? ""}`)); else resolve(m.result);
    } else if (m.method) for (const f of listeners) f(m);
  };
  const send = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++seq;
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ id, method, params }));
  });
  const once = (method, timeout = 30000) => new Promise((resolve, reject) => {
    const t = setTimeout(() => { listeners.delete(f); reject(new Error(`timeout waiting for ${method}`)); }, timeout);
    const f = (m) => { if (m.method === method) { clearTimeout(t); listeners.delete(f); resolve(m.params); } };
    listeners.add(f);
  });
  await send("Page.enable");
  await send("Runtime.enable");

  const evaluate = async (expression) => {
    const r = await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
    if (r.exceptionDetails) throw new Error(`page error: ${r.exceptionDetails.exception?.description ?? r.exceptionDetails.text}`);
    return r.result.value;
  };
  const waitFor = async (expression, timeout = 30000, every = 150) => {
    const t0 = Date.now();
    for (;;) {
      const v = await evaluate(expression).catch(() => undefined);
      if (v) return v;
      if (Date.now() - t0 > timeout) throw new Error(`timeout waiting for: ${expression}`);
      await sleep(every);
    }
  };
  const navigate = async (url) => {
    const loaded = once("Page.loadEventFired", 60000);
    await send("Page.navigate", { url });
    await loaded;
  };
  const close = async () => {
    try { ws.close(); } catch { /* already closed */ }
    proc.kill();
    await sleep(500);
    try { fs.rmSync(profile, { recursive: true, force: true }); } catch { /* Windows may still hold it */ }
  };
  return { send, evaluate, waitFor, navigate, close, sleep, on: (f) => listeners.add(f) };
}
