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

Aderyn 0.6.8 was run afterwards (2026-10-31, branch `p3b-aderyn`); see "Aderyn" below.

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

### N-35: `returnCapital` pulls from any address with a vault allowance (Medium, fixed)

`ShariahVault.returnCapital(strategy, amount)` (owner or manager) calls `ShariahAccountingLogic.returnCapital`, which runs `safeTransferFrom(strategy, vault, amount)` without checking that `strategy` is a funded adapter. Depositors normally leave an allowance to the vault (often unlimited), so the owner or the manager can pull a depositor's wallet USDC into the vault. The pulled USDC becomes NAV for all shareholders; the victim gets nothing. This contradicts the trust model in `docs/audit-handoff.md` ("Owner multisig cannot withdraw user funds directly").

- Exposure: the owner multisig, and any manager. The production manager (`RiskTieredExecutor`) has no code path that calls `returnCapital`, so in practice this is the owner role.
- The base `AutonomousVault.returnCapital` has the same pattern (conventional vault, out of scope).
- Proof: `contracts/test/StaticAnalysisN35Test.t.sol` (V1 and V2, owner and manager), written as known-finding tests.
- Fixed on branch `n35-returncapital-funded-only`: the library reverts `AdapterNotFunded(adapter)` unless the adapter holds booked principal. A funded adapter can still return principal plus profit in one call. The tests in `StaticAnalysisN35Test.t.sol` now assert the revert.

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

1. ~~Fix N-35~~ (done, `n35-returncapital-funded-only`).
2. ~~P-5: zero-address checks in the `HalalLPAdapter` constructor~~ (done, `p5-halal-lp-zero-checks`: `positionManager`, `swapRouter`, `vault`, `token0`, `token1`; `HalalLPAdapterP5Test.t.sol`).
3. ~~Run Aderyn and add its results here~~ (done, below).
4. Re-run Slither on the frozen audit commit and attach the JSON to the audit package.

## Aderyn

Run 2026-10-31 on branch `p3b-aderyn` (code identical to `p7-audit-handoff`), Aderyn 0.6.8 from npm (`@cyfrin/aderyn`), restricted to the 13 in-scope Solidity files (3,931 SLOC; scripts excluded):

```bash
aderyn . -i contracts/ShariahVault.sol,contracts/ShariahVaultV2.sol,contracts/AutonomousVault.sol,contracts/TreasuryModule.sol,\
contracts/PurificationEscrow.sol,contracts/CharityModule.sol,contracts/ShariahAdapterRegistry.sol,contracts/RiskTieredExecutor.sol,\
contracts/ShariahScoreAggregator.sol,contracts/ZakatModule.sol,contracts/adapters/GoldExchangeAdapter.sol,\
contracts/adapters/GoldAllocationAdapter.sol,contracts/adapters/HalalLPAdapter.sol -o aderyn-report.json
```

Result: 3 high-impact detectors and 18 low-impact detectors. **No new real finding.**

| Impact | Detector | Instances | Verdict |
|---|---|---|---|
| High | arbitrary-transfer-from | 1 | The N-35 line (`ShariahAccountingLogic.returnCapital`). Already fixed: it reverts `AdapterNotFunded` unless the adapter has booked principal, so `from` can only be a funded adapter |
| High | reentrancy-state-change | 26 | Accepted. Gold and LP adapter `deploy`/`recall`/`executeEmergencyExit` are `nonReentrant` and `onlyVault`/`onlyOwner`, and call only immutable routers, pools and oracles. Executor paths hold `_executionLocked`; `deployCapitalAndExecute` holds `_adapterExecutionLocked`. `GoldAllocationAdapter` lines 181 to 183 are constructor `decimals()` reads. `PurificationEscrow` line 291 reads `charityModule.charityBps()` (view) inside a board-only proposal. `AutonomousVault.recallCapital` (lines 340 to 342) is the conventional base; the Shariah vault overrides it |
| High | reused-contract-name | 4 | False positive for safety: duplicate local interface names (for example `IShariahRegistry`) declared in several files. Worth renaming for clarity in audit tooling; no behaviour impact |
| Low | centralization-risk | 88 | By design; see the trust model in `docs/audit-handoff.md` section 5 |
| Low | dead-code | 2 | `AutonomousVault._validateSettlementHeader` and `_consumeInbound` are unused internal functions (the compiler drops them; no bytecode cost). Cleanup candidate |
| Low | unused-error | 3 | `GoldExchangeAdapter.DeadlineExceeded`, `StalePrice`; `HalalLPAdapter.NoActivePosition`. Cleanup candidate |
| Low | state-variable-could-be-immutable | 4 | `RiskTieredExecutor.tierName`, `TreasuryModule.treasuryType` (strings cannot be immutable), `TreasuryModule.asset`, `isShariahTreasury` (could be immutable; gas only) |
| Low | state-change-without-event | 8 | Checked each one. The vault's `returnCapital`, `retireGoldPrincipal` and `writeOffAdapterPrincipal` emit from the library. **Missing events worth adding (Info, monitoring only):** owner `ShariahVault.setHurdlePrincipal`, owner `AutonomousVault.setProfitUnlockPeriod`, and board `ShariahAdapterRegistry.cancelProposal`. `PurificationEscrow.grantBoardRole`/`revokeBoardRole` are dead: the constructor requires a registry and `boardRegistry` is never reassigned, so `onlyBoard` always uses `registry.isBoard()` and the local `boardRole` mapping is never read. Removal candidate (it reads like an untimelocked board change) |
| Low | unchecked-return | 8 | Same set as Slither `unused-return` (intentional; see above) |
| Low | uninitialized-local-variable | 3 | Same as Slither `uninitialized-local` (locals start at zero on purpose) |
| Low | others | | `large-numeric-literal`, `literal-instead-of-constant`, `unspecific-solidity-pragma` (`^0.8.28`; the build pins 0.8.28), `non-reentrant-not-first`, `local-variable-shadowing` (`TreasuryModule` constructor arguments), `redundant-statement`, `costly-loop` and `require-revert-in-loop` (fixed 6-entry loops in the aggregator), `modifier-used-only-once`, `unused-public-function`, `state-no-address-check` (owner setters, overlaps Slither `missing-zero-check`): style or gas only |

The cleanup candidates (dead internal functions, the dead escrow `boardRole` path, unused errors, could-be-immutable variables, duplicate interface names, the three missing events) do not change fund behaviour. Adding events to the vault costs bytecode against the 259 B margin. They are left for a post-audit tidy-up so the audited code does not move.

