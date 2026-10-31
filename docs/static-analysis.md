# Static analysis: Slither triage

Run 2026-10-31 on branch `p3-static-analysis` (stacked on `n33a-vault-lp-fork`). Workplan item P-3.

## How it was run

```bash
uv tool install slither-analyzer          # Slither 0.11.6
slither . --filter-paths "contracts/test|contracts/test-helpers|contracts/script|node_modules|lib/" \
  --exclude-informational --exclude-optimization --json slither.json
```

Slither compiles with `forge build`, using `foundry.toml` (solc 0.8.28, `evm_version = "paris"`, optimizer 200 runs). It analysed 94 contracts with 76 detectors and reported 260 results (High, Medium and Low only).

"In scope" means the files in `docs/audit-handoff.md` section 2. Results in out-of-scope files (`ConventionalVault`, the conventional `ScoreAggregator`, conventional strategy adapters) are counted but not triaged.

Aderyn was not run (not installed). Running it is an open follow-up for P-3.

## Summary

| Impact | Detector | Total | In scope | Verdict |
|---|---|---|---|---|
| High | arbitrary-send-erc20 | 4 | 4 | **1 real finding (N-35)**, 3 false positives |
| High | reentrancy-balance | 3 | 3 | Accepted (trusted, immutable counterparties; see below) |
| High | uninitialized-state | 2 | 1 | False positive (mapping written with `push`) |
| High | weak-prng | 7 | 4 | False positive (modulo for ring buffers and tick rounding; no randomness) |
| Medium | divide-before-multiply | 5 | 3 | Accepted (sub-wei rounding that only lowers a minimum output) |
| Medium | incorrect-equality | 23 | 15 | False positive (intentional `== 0` checks) |
| Medium | reentrancy-no-eth | 15 | 10 | Accepted (guarded; see below) |
| Medium | uninitialized-local | 15 | 9 | False positive (locals deliberately start at zero) |
| Medium | unused-return | 19 | 14 | Accepted (intentional; see below) |
| Low | missing-zero-check | 41 | 18 | Partly actionable: P-5 for `HalalLPAdapter`; others are setters behind owner/board roles |
| Low | reentrancy-benign / reentrancy-events | 43 | 26 | Accepted (event ordering after trusted calls) |
| Low | timestamp | 83 | 73 | Accepted (timelocks, oracle staleness and TWAP windows use `block.timestamp` by design) |

## Real finding

### N-35: `returnCapital` pulls from any address with a vault allowance (Medium, open)

`ShariahVault.returnCapital(strategy, amount)` (owner or manager) calls `ShariahAccountingLogic.returnCapital`, which runs `safeTransferFrom(strategy, vault, amount)` without checking that `strategy` is a funded adapter. Depositors normally leave an allowance to the vault (often unlimited), so the owner or the manager can pull a depositor's wallet USDC into the vault. The pulled USDC becomes NAV for all shareholders; the victim gets nothing. This contradicts the trust model in `docs/audit-handoff.md` ("Owner multisig cannot withdraw user funds directly").

- Exposure: the owner multisig, and any manager. The production manager (`RiskTieredExecutor`) has no code path that calls `returnCapital`, so in practice this is the owner role.
- The base `AutonomousVault.returnCapital` has the same pattern (conventional vault, out of scope).
- Proof: `contracts/test/StaticAnalysisN35Test.t.sol` (V1 and V2, owner and manager), written as known-finding tests.
- Proposed fix: require the strategy to hold booked principal (`principalOf[strategy] != 0`) before pulling. A funded adapter can still return principal plus profit in one call.

## Accepted or false positive, with reasons

- **arbitrary-send-erc20 (3 false positives).**
  - `ZakatModule.distributeZakat` pulls only from the immutable `vault`, and only when `msg.sender == vault`.
  - `PurificationEscrow._executeWaterfall` pulls only from the immutable `vault`, and both public entry points revert unless `msg.sender == vault`.
  - `AutonomousVault.returnCapital` is the conventional base; the Shariah override routes to the library flagged above.
- **reentrancy-balance (3).** These are the balance-delta checks in `CctpSettlementLogic._receive` (around Circle's `MessageTransmitterV2.receiveMessage`) and in `HalalLPAdapter.deploy` / `_swap` (around the immutable swap router and position manager; both entry points are `nonReentrant`). The counterparties are fixed at deployment and part of the trust model. The deltas are the point of the checks (fee-on-transfer and shortfall detection).
- **reentrancy-no-eth (10).** `deployCapitalAndExecute` holds `_adapterExecutionLocked`; `exitSettle` and the claim paths hold `_profitDistributionLocked`; the adapters' `deploy` / `recall` are `nonReentrant`; the executor calls only the vault. Cross-chain paths call Circle's TokenMessengerV2 / MessageTransmitterV2.
- **unused-return (14).** Uniswap tuple fields are ignored on purpose. Ignored `deploy()` returns: the vault books the requested amount and marks value through `currentValue()`. `distributeCharity`'s return equals the escrow's own preview, which tests check against the real waterfall.
- **divide-before-multiply (3).** `_sqrtRatioAtTick` is the Uniswap TickMath algorithm. The two gold `deploy` minimum-output formulas lose at most one base unit before the bps multiply, which lowers the minimum by less than one unit and never raises it.
- **weak-prng / uninitialized-state.** `% 10` ring-buffer indices in `ShariahScoreAggregator`, and `%` for arithmetic-mean tick rounding in `HalalLPAdapter._twapPrice`. `scoreHistory` is a mapping filled with `push`.
- **missing-zero-check (18 in scope).** `HalalLPAdapter` constructor (`positionManager`, `vault`) is tracked as P-5. The rest are constructor or owner/board setters (treasury, charity, escrow, aggregator, gold adapters, zakat shim) where a zero address fails closed on first use. Worth a cleanup pass, but not a fund-safety issue.
- **timestamp (73 in scope).** Every timelock (30 days), oracle staleness window, TWAP window and emergency-exit window compares against `block.timestamp` by design. Minutes-scale validator drift is irrelevant at these durations.

## Follow-ups

1. Fix N-35 on its own branch and flip the known-finding tests to expect a revert.
2. P-5: zero-address checks in the `HalalLPAdapter` constructor.
3. Run Aderyn and add its results here.
4. Re-run Slither on the frozen audit commit and attach the JSON to the audit package.
