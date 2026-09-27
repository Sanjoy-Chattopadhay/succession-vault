# Legacy baseline

Conventional explicit-state-machine design used as the measured baseline in the evaluation
(per-heir storage, keeper-driven phase transitions, mandatory age proof per heir, batched push
execution). Sources are copied unchanged from the original implementation, with one exception:
`AssetManager.sol` imports `ReentrancyGuard` from `utils/` instead of `security/` (OpenZeppelin v5
moved the file; the contract is identical). Modules not exercised by the benchmark were omitted.

`zk/` holds that design's own age circuit artifacts (wasm, zkey, verification key), so the baseline
is measured with real Groth16 proofs rather than mock verifiers.
