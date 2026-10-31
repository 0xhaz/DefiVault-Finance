# Test coverage (audit scope)

Measured 2026-10-31 on branch `p4-coverage`. Workplan item P-4.

```bash
forge coverage --ir-minimum --allow-failure --no-match-path 'contracts/test/invariant/*' --report summary
```

Why these flags:
- **`--ir-minimum`:** coverage compiles without the optimizer, which hits stack-too-deep in this codebase. `--ir-minimum` is the documented workaround. Source mappings are approximate under via-IR, so a few lines that clearly execute (Wakala accrual calls, inline-assembly reads) show as uncovered.
- **`--allow-failure`:** about a dozen tests fail only under via-IR. Each one compares against `block.timestamp` after `skip()`/`vm.warp`, and via-IR caches the timestamp read. All of them pass in the normal build (`forge test`). Those tests do not count toward coverage, so the figures below are slightly understated.
- Invariant and fork suites are excluded. The fork suites need an RPC; the invariants are slow under coverage.

## In-scope files

| File | Lines | Statements | Branches | Functions |
|---|---|---|---|---|
| `ShariahVault.sol` (with its four linked libraries) | 95.8% | 96.6% | 96.4% | 96.1% |
| `ShariahVaultV2.sol` | 97.9% | 97.8% | 92.3% | 100% |
| `AutonomousVault.sol` | 96.2% | 95.7% | 81.6% | 94.9% |
| `TreasuryModule.sol` | 98.4% | 96.1% | 84.6% | 100% |
| `PurificationEscrow.sol` | 96.9% | 92.2% | 73.3% | 83.3% |
| `CharityModule.sol` | 100% | 93.4% | 68.8% | 100% |
| `ShariahAdapterRegistry.sol` | 100% | 90.3% | 64.7% | 100% |
| `RiskTieredExecutor.sol` | 96.9% | 96.6% | 71.4% | 91.7% |
| `ShariahScoreAggregator.sol` | 100% | 97.8% | 92.3% | 100% |
| `ZakatModule.sol` (deprecated shim) | 100% | 97.3% | 85.7% | 100% |
| `adapters/GoldAllocationAdapter.sol` | 92.5% | 90.2% | 72.1% | 93.9% |
| `adapters/GoldExchangeAdapter.sol` | 93.1% | 92.6% | 70.2% | 91.3% |
| `adapters/HalalLPAdapter.sol` | 97.5% | 96.3% | 82.4% | 96.8% |

`HalalLPAdapter` is additionally exercised against the real Uniswap V3 deployment on an Arc mainnet fork (`ForkHalalLPArcMainnet.t.sol`, `ForkVaultLPArcMainnet.t.sol`), which this table does not count.

## Gaps closed in this pass (`CoverageGapsP4Test.t.sol`)

- `ShariahScoreAggregator`: lines 63.5% to 100%, branches 46.2% to 92.3%. New tests cover:
  - the history ring buffer, before and after it wraps;
  - `getAllShariahScores`;
  - `setOracle` access control and oracle rotation;
  - score bounds (`> 100`), the reserved index 4, batch length mismatch;
  - stale and tied winners.
- `RiskTieredExecutor`: lines 92.2% to 96.9%, branches 65.7% to 71.4%. New tests cover the tier-mask rejection and `setStrategyMask`. One of them records the known limitation N-36.

## Remaining gaps worth a look before the freeze

- **Branch coverage of 65 to 73 percent** in `ShariahAdapterRegistry`, `CharityModule`, `PurificationEscrow` and both gold adapters. Most of these are revert branches of timelocked setters (wrong role, double proposal, cancel without proposal).
- **Dead library entry points:** `ShariahAccountingLogic.checkGoldMarker` and `checkGoldCap` (external wrappers) are never called by the vault. They add library bytecode and audit surface; consider removing them.
- `ShariahVault.name()` / `symbol()` are not asserted anywhere.
