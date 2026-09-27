# Evidence

Raw outputs of every experiment, captured on the development machine (Intel Core i5-13450HX,
16 threads, 24 GB RAM, Windows 11, Node.js 22.14, Foundry 1.7.1, circom 2.1.9, snarkjs 0.7.5).

- `logs/*.log` is the complete terminal output, headed by the UTC time, host and exact command.
- `captures/*.png` are images rendered from those logs by `scripts/render_log.py`; they are not
  screen captures. Long logs are split into several images.
- `private/` holds runs on the authors' real Billions credentials. It is git-ignored and must not
  be published.

To regenerate any item, run `bash scripts/evidence.sh <name> <command>` with the command shown in the log header.

| # | Name | What it shows | Result file |
|---|---|---|---|
| 01 | forge-test | Full Foundry suite: unit, fuzz, invariant tests | — |
| 02 | gas-isolate | Transaction gas per operation and scaling with the number of heirs (`--isolate`) | `reports/gas-ops.json`, `reports/gas-scaling.json`, `reports/gas-verifiers.json` |
| 03 | proving-benchmark | Groth16 witness/proving/verification time, 20 runs, power throttling disabled | `reports/proving.json` |
| 06 | slither | Slither static analysis of the contracts (102 detectors) | `reports/slither.json` |
| 07 | circomspect | circomspect on both circuits (warning level); `07b` is the info level | — |
| 08 | circuit-negative-tests | 18 honest/manipulated witnesses against both circuits | `reports/circuit-tests.json` |
| 09 | comparison-vs-legacy | Lifecycle gas of Bequest vs the conventional prototype, n = 1..16 | `reports/comparison.json` |
| 10 | browser-proving-background | Groth16 proving in Chromium (in-app browser, background-throttled) | `reports/browser-proving-background.json` |
| 11 | proof-systems | Groth16 vs PLONK vs FFLONK: proving time, proof and key sizes | `reports/proof-systems.json` |
| 12 | proofsys-verify-gas | On-chain verification gas of each proof system | `reports/gas-proofsys.json` |
| 13 | deploy-gas | Deployment gas of every contract (local Anvil receipts) | `reports/deploy-gas.json` |
| 14+ | sepolia-* | Live Sepolia run, one log per step, with transaction hashes | `reports/sepolia.json` |
| 30 | proof-of-life-pipeline | Time of every device-side step of a proof of life on the two real Billions credentials, and the Merkle depth they use | `reports/pipeline.json` |
| 31 | merkle-depth-ablation | Liveness circuit with 40 vs 16 Merkle levels: constraints, key size, proving time | `reports/depth-ablation.json` |
| 32 | presence-probe-gas | Prototype passkey (WebAuthn + P256VERIFY, Osaka EVM) and optimistic proof-of-life transactions: gas and rejection tests | — |
| p04/p05 | private/* | Real Billions credentials: issuer signature, merklization root, proof | — |
