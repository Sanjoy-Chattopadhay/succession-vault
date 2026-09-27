// Builds the fixtures for the aggregated-liveness tests and measures prover cost against cohort
// size (test/fixtures/registry.json, reports/aggregation.json).
//
// For each available circuit agg_N{n}_m{mt}_w{w} it enrolls a cohort of n synthetic principals,
// issues each of them a LivenessCredential inside one epoch, and produces a single proof covering
// the whole cohort. The fixtures let the Foundry suite replay the same proofs on-chain and measure
// what an epoch actually costs.
import fs from "node:fs";
import path from "node:path";
import { PoseidonTree, makePrincipal, livenessInputs, epochInput, packPresence } from "./lib/registry.mjs";
import { makeIssuer } from "./lib/test-issuer.mjs";
import { prove, shutdown } from "./lib/zk.mjs";

const BATCH = "zk/batch";
const OUT = "test/fixtures";
const REPORTS = "reports";
const DAY = 86_400;
const T0 = 1_900_000_000; // must match js/gen-fixtures.mjs

const sol = (r) => ({ a: r.calldata.a, b: r.calldata.b, c: r.calldata.c });
const mean = (xs) => xs.reduce((a, b) => a + b, 0) / xs.length;

/** Discover the circuits that scripts/batch-setup.sh actually built. */
function circuits() {
  return fs.readdirSync(BATCH)
    .filter((f) => /^agg_N\d+_m\d+_w\d+\.zkey$/.test(f))
    .map((f) => {
      const name = f.replace(/\.zkey$/, "");
      const [, n, mt, w] = name.match(/^agg_N(\d+)_m(\d+)_w(\d+)$/).map(Number);
      return { name, n, mt, w };
    })
    .sort((a, b) => a.w - b.w || a.n - b.n);
}

fs.mkdirSync(OUT, { recursive: true });
fs.mkdirSync(REPORTS, { recursive: true });

const issuer = await makeIssuer("A");
const emptyTree = await PoseidonTree.create();
const emptyRoot = emptyTree.emptyRoot;
console.log("enrollment tree: depth", emptyTree.levels, "empty root", emptyRoot.toString());

const available = circuits();
if (available.length === 0) throw new Error(`no aggregation circuits in ${BATCH}; run scripts/batch-setup.sh`);
console.log("circuits:", available.map((c) => c.name).join(", "));

const cohorts = {};
const measurements = [];

for (const c of available) {
  const label = `N=${c.n} mt=${c.mt} w=${c.w}`;
  const tree = await PoseidonTree.create();

  // ---- enrollment: every principal claims their own slot -------------------------------------
  const principals = [];
  const enrollments = [];
  for (let i = 0; i < c.n; i++) {
    const p = await makePrincipal(issuer, `${c.name}-p${i}`);
    const ins = tree.insert(i, p.binding);
    const r = await prove("enroll", {
      oldRoot: ins.oldRoot.toString(),
      newRoot: ins.newRoot.toString(),
      index: String(i),
      binding: p.binding.toString(),
      siblings: ins.siblings.map(String),
    }, BATCH);
    enrollments.push({
      ...sol(r),
      slot: i,
      binding: p.binding.toString(),
      oldRoot: ins.oldRoot.toString(),
      newRoot: ins.newRoot.toString(),
      provingMs: Math.round(r.ms),
    });
    principals.push(p);
  }
  const enrollRoot = tree.root;

  // ---- one epoch covering the whole cohort ---------------------------------------------------
  const epochStart = T0 + 10 * DAY;
  const epochEnd = epochStart + DAY;
  const members = [];
  for (let i = 0; i < c.n; i++) {
    members.push({
      present: true,
      inputs: await livenessInputs(issuer, principals[i], epochStart + 3600 * (i % 20), c.mt),
      enrollSiblings: tree.siblings(i),
    });
  }
  const input = epochInput({
    enrollRoot, epochStart, epochEnd, words: c.w, members, mtLevels: c.mt,
  });

  const runs = Number(process.env.RUNS ?? 3);
  const times = [];
  let r;
  for (let k = 0; k < runs; k++) {
    r = await prove(c.name, input, BATCH);
    times.push(r.ms);
  }
  const words = packPresence(members.map((_, i) => i), c.w);
  const expected = [enrollRoot, 0n, BigInt(epochStart), BigInt(epochEnd), ...words].map(String);
  if (JSON.stringify(r.publicSignals) !== JSON.stringify(expected)) {
    throw new Error(`${c.name}: public signals mismatch\n got ${r.publicSignals}\n want ${expected}`);
  }

  // A second epoch, with the last principal silent, exercises the absence path on-chain. Each
  // present principal needs a credential issued inside this epoch: the issuer's signature commits
  // to the merklized timestamp, so a credential cannot simply be re-dated.
  const gapStart = epochEnd + DAY;
  const gapEnd = gapStart + DAY;
  const silent = c.n - 1;
  const partialMembers = [];
  for (let i = 0; i < c.n; i++) {
    partialMembers.push(i === silent
      ? { present: false, enrollSiblings: tree.siblings(i) }
      : {
          present: true,
          inputs: await livenessInputs(issuer, principals[i], gapStart + 60 + i, c.mt),
          enrollSiblings: tree.siblings(i),
        });
  }
  const partial = await prove(c.name, epochInput({
    enrollRoot, epochStart: gapStart, epochEnd: gapEnd, words: c.w,
    members: partialMembers, mtLevels: c.mt,
  }), BATCH);

  cohorts[c.name] = {
    n: c.n, mt: c.mt, words: c.w,
    emptyRoot: emptyRoot.toString(),
    enrollRoot: enrollRoot.toString(),
    epoch: {
      ...sol(r), start: String(epochStart), end: String(epochEnd),
      words: words.map(String), provingMs: Math.round(mean(times)),
    },
    partialEpoch: {
      ...sol(partial), start: String(gapStart), end: String(gapEnd),
      words: packPresence(members.map((_, i) => i).filter((i) => i !== silent), c.w).map(String),
      silentSlot: silent,
    },
    enrollments,
    bindings: principals.map((p) => p.binding.toString()),
  };

  measurements.push({
    circuit: c.name, n: c.n, mtLevels: c.mt, words: c.w,
    provingMs: Math.round(mean(times)),
    provingMsPerPrincipal: Math.round(mean(times) / c.n),
    provingMsRuns: times.map(Math.round),
    enrollProvingMs: Math.round(mean(enrollments.map((e) => e.provingMs))),
    publicSignals: 4 + c.w,
  });
  console.log(`${label.padEnd(24)} proving ${Math.round(mean(times))} ms  (${Math.round(mean(times) / c.n)} ms/principal)`);
}

fs.writeFileSync(path.join(OUT, "registry.json"), JSON.stringify({ emptyRoot: emptyRoot.toString(), cohorts }, null, 2));
fs.writeFileSync(path.join(REPORTS, "aggregation.json"), JSON.stringify({
  generatedBy: "js/gen-batch-fixtures.mjs",
  enrollLevels: emptyTree.levels,
  bitsPerWord: 248,
  measurements,
}, null, 2));
console.log("\nwrote test/fixtures/registry.json and reports/aggregation.json");

await shutdown();
process.exit(0);
