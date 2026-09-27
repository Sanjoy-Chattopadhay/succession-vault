# Slither triage

Command: `slither . --filter-paths "lib/|node_modules/|test/|script/" --json reports/slither.json` (Slither with 102 detectors, run on the final code).
Raw output: `evidence/logs/06-slither.log` and `reports/slither.json`.

| Impact | Where | Detector | Count | Verdict |
|---|---|---|---|---|
| High | generated Groth16 verifiers | incorrect-return | 6 | **False positive.** The snarkjs verifier uses `return(0, 0x20)` in assembly helpers to exit early with `false` on invalid input. The unit tests confirm that invalid proofs are rejected (tampered signals, foreign binding, malformed point). |
| Medium | `BequestVault._civilFromDays` | divide-before-multiply | 3 | **Intended.** These truncating divisions *are* Hinnant's exact integer civil-from-days algorithm; the code is not losing precision. Covered by `test_AgeCutoff_KnownDates` and a 1,000-run fuzz test. |
| Low | `claimMany*`, `_claim`, `_balance`, `_transferOut` | calls-loop | 12 | **Accepted.** Batched claims call token contracts in a loop. A token that reverts only blocks that heir's own batch, and the heir can claim those bequests individually. |
| Low | lifecycle functions | timestamp | 8 | **Inherent.** The protocol is defined in time. Block-time skew (seconds) is negligible against the intervals (minutes on testnets, months in practice); `MAX_CLOCK_SKEW` bounds future-dated credentials. |
| Info | Bequest contracts | costly-loop, low-level-calls, missing-inheritance, naming-convention | 9 | Style or known pattern: an ETH transfer through `call`, the generated verifiers not inheriting the interface, and immutables in UPPER_CASE. |
| Info | generated verifiers | assembly, naming-convention, too-many-digits | 67 | Generated code. |

There are no High or Medium findings that need a code change in the Bequest contracts.
