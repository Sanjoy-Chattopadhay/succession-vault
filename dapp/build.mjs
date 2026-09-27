// Bundle the app into dist/ (a static site): node build.mjs
// esbuild is a dev dependency; npx uses the installed copy (or fetches that exact version).
import { execFileSync } from "node:child_process";
import fs from "node:fs";

fs.rmSync("dist", { recursive: true, force: true });
fs.mkdirSync("dist/circuits", { recursive: true });
// Real circuit file sizes for the download progress (servers may gzip and report compressed lengths).
const sizes = Object.fromEntries(fs.readdirSync("public/circuits").map((f) => [f, fs.statSync(`public/circuits/${f}`).size]));
fs.writeFileSync("src/circuit-sizes.json", JSON.stringify(sizes, null, 2) + "\n");
execFileSync("npx", [
  "--yes", "esbuild@0.24.0", "src/app.js", "--bundle", "--format=esm", "--platform=browser", "--target=es2022",
  "--minify", "--legal-comments=none", "--outfile=dist/app.js", "--inject:src/shims.js",
  "--define:global=globalThis", "--log-level=warning",
], { stdio: "inherit", shell: process.platform === "win32" });
fs.copyFileSync("index.html", "dist/index.html");
fs.copyFileSync("src/app.css", "dist/app.css");
fs.copyFileSync("public/snarkjs.min.js", "dist/snarkjs.min.js");
for (const f of fs.readdirSync("public/circuits")) fs.copyFileSync(`public/circuits/${f}`, `dist/circuits/${f}`);
fs.writeFileSync("dist/.nojekyll", "");
console.log("dist/ ready:", fs.statSync("dist/app.js").size, "bytes of app.js");
