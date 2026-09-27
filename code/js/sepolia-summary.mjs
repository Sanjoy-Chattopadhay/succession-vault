// Condenses the live Sepolia run and the live attacks into reports/sepolia-summary.json, comparing
// every operation whose on-chain state matches the benchmark with the benchmark's gas, and parsing
// the attack verdicts from the evidence logs.
//   node js/sepolia-summary.mjs
import fs from "node:fs";

const read = (f) => JSON.parse(fs.readFileSync(f, "utf8"));
const tx = read("reports/sepolia.json");
const ops = read("reports/gas-ops.json");
const agg = read("reports/gas-aggregation.json").cohorts.agg_N8_m40_w1;

const byFn = {};
for (const t of tx) (byFn[t.function] ||= []).push(t.gasUsed);

// Claims in the order the demo made them: bequests 0, 1, 3, 6, 7 in step 14, the age-gated
// bequest 4 through claimWithAgeProof, and the time-locked tranche 2 in step 15.
const [claimEthFirst, claimEth, claimErc20New, claimErc721, claimErc1155, claimTranche] = byFn.claim;
const comparable = {
  createVault: [byFn.createVault[0], ops.createVault],
  heartbeat: [byFn.heartbeat[0], ops.heartbeat],
  proveLife: [byFn.proveLife[0], ops.proveLife],
  enrollInRegistry: [byFn.enrollInRegistry[0], agg.enrollGas],
  submitEpoch: [byFn.submitEpoch[0], agg.epochGasCold],
  claimETH: [claimEth, ops.claimETH],
  claimERC20_firstOfPool: [claimErc20New, ops.claimERC20_firstOfPool],
  claimERC721: [claimErc721, ops.claimERC721],
  claimERC1155: [claimErc1155, ops.claimERC1155],
  claimWithAgeProof: [byFn.claimWithAgeProof[0], ops.claimWithAgeProof],
};
const rows = Object.fromEntries(Object.entries(comparable).map(([k, [live, bench]]) =>
  [k, { live, bench, deviationPct: +(((live - bench) / bench) * 100).toFixed(2) }]));
const maxDev = Math.max(...Object.values(rows).map((r) => Math.abs(r.deviationPct)));

// Operations that read presence from the registry pay for that read; the benchmark vault has none.
const registryRead = {
  firstClaim: { live: claimEthFirst, bench: ops.claimETH_first, extra: claimEthFirst - ops.claimETH_first },
  withdraw: { live: byFn.withdraw[0], bench: ops.withdrawETH, extra: byFn.withdraw[0] - ops.withdrawETH },
};

const verdicts = (file) => fs.readFileSync(file, "utf8").split("\n")
  .map((l) => l.match(/^\s*rejected as expected: (.+?) -> (\w+)\s*$/))
  .filter(Boolean).map((m) => ({ attack: m[1], rejectedWith: m[2] }));
const onchain = verdicts(`evidence/logs/${process.env.LOG_PREFIX ?? "sepolia"}-22-attacks-onchain.log`);
const onchainMismatch = /mismatches:\s*0/.test(fs.readFileSync(`evidence/logs/${process.env.LOG_PREFIX ?? "sepolia"}-22-attacks-onchain.log`, "utf8"));
const offchain = read("reports/attacks-offchain.json");

// j-of-m issuer threshold (scripts/sepolia_extras.sh part 3): one issuer alone must be rejected
// through both entry points; two of three issuers, and later a different two, are accepted.
const P = process.env.LOG_PREFIX ?? "sepolia";
const chainId = process.env.CHAIN_ID ?? "11155111";
let threshold = null;
const aloneLog = `evidence/logs/${P}-46-threshold-one-issuer-rejected.log`;
if (fs.existsSync(aloneLog)) {
  const t = fs.readFileSync(aloneLog, "utf8");
  const dir = `broadcast/DemoThreshold.s.sol/${chainId}`;
  const runs = fs.existsSync(dir)
    ? fs.readdirSync(dir).filter((f) => /^run-\d+\.json$/.test(f)).sort().map((f) => read(`${dir}/${f}`)) : [];
  const receiptsOf = (fn) => runs.filter((r) => (r.transactions ?? []).some((x) => (x.function ?? "").startsWith(fn)))
    .flatMap((r) => r.receipts ?? []).map((r) => ({ gasUsed: parseInt(r.gasUsed, 16), ok: r.status === "0x1", hash: r.transactionHash }));
  const multi = receiptsOf("proveLifeMulti");
  threshold = {
    aloneSingle: /ALONE_SINGLE rejected ThresholdNotMet/.test(t) ? "rejected (ThresholdNotMet)" : "NOT rejected as expected",
    aloneMulti: /ALONE_MULTI rejected ThresholdNotMet/.test(t) ? "rejected (ThresholdNotMet)" : "NOT rejected as expected",
    aloneRejected: (/ALONE_SINGLE rejected ThresholdNotMet/.test(t) ? 1 : 0) + (/ALONE_MULTI rejected ThresholdNotMet/.test(t) ? 1 : 0),
    multiAccepted: multi.filter((r) => r.ok).length,
    multiGas: multi.map((r) => r.gasUsed),
    multiTx: multi.map((r) => r.hash),
    setThresholdGas: receiptsOf("setBindingThreshold").map((r) => r.gasUsed),
  };
  fs.writeFileSync("reports/threshold-live.json", JSON.stringify({ generatedBy: "js/sepolia-summary.mjs", ...threshold }, null, 2));
}

const out = {
  generatedBy: "js/sepolia-summary.mjs",
  deployment: fs.existsSync(`deployments/${chainId}.json`) ? read(`deployments/${chainId}.json`) : null,
  threshold,
  lifecycle: {
    transactions: tx.length,
    reverted: tx.filter((t) => t.status !== "ok").length,
    totalGas: tx.reduce((s, t) => s + t.gasUsed, 0),
    comparable: rows,
    maxDeviationPct: maxDev,
    registryRead,
    notComparable: {
      claimTranche: { live: claimTranche, why: "last ETH claimant; the heir already held ETH from an earlier claim" },
      sweeps: { live: byFn.sweep, why: "ETH pool already fully claimed; token sweep paid out the minor's share" },
      setBinding: { live: byFn.setBinding[0], why: "no benchmark row; owner action in a registry-enabled vault" },
    },
  },
  attacks: {
    offchainEditsRejected: offchain.rejected,
    offchainEditsTotal: offchain.total,
    onchainRejected: onchain.length,
    onchainAllAsExpected: onchainMismatch,
    onchain,
  },
};
fs.writeFileSync("reports/sepolia-summary.json", JSON.stringify(out, null, 2));
console.log(JSON.stringify({ ...out.lifecycle, comparable: undefined }, null, 1));
console.table(rows);
console.log("attacks:", out.attacks.offchainEditsRejected + "/" + out.attacks.offchainEditsTotal, "off-chain,", out.attacks.onchainRejected, "on-chain, all as expected:", onchainMismatch);
