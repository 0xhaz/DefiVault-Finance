# Shariah Vault Revision Plan
**Generated:** 2026-10-21  
**Scope:** Phase 2 — three design defects + SC methodology re-screen + ShariahVault v2 migration path  
**Reference:** AGENTS.md task table (Tasks A → E)

---

## What Exists Today (Baseline)

The current ShariahVault ecosystem was built to the Phase 1 plan in `arc-studio-plans/SHARIAH_VAULT.md`. All named contracts are present and compile:

| Contract | File | Status |
|---|---|---|
| `AutonomousVault` | `contracts/AutonomousVault.sol` | Stable base — do not modify |
| `ShariahVault` | `contracts/ShariahVault.sol` | **Needs defect fixes (Tasks A, B, C)** |
| `ShariahScoreAggregator` | `contracts/ShariahScoreAggregator.sol` | Stable — enum positions frozen |
| `TreasuryModule` | `contracts/TreasuryModule.sol` | Stable |
| `ZakatModule` | `contracts/ZakatModule.sol` | **Needs rename/restructure (Task B)** |
| `RiskTieredExecutor` | `contracts/RiskTieredExecutor.sol` | Has SHARIAH_CONSERVATIVE + SHARIAH_DYNAMIC tiers |
| `CommodityMurabahaAdapter` | `contracts/adapters/CommodityMurabahaAdapter.sol` | Stable |
| `HalalLPAdapter` | `contracts/adapters/HalalLPAdapter.sol` | Stable |
| `RwaYieldAdapter` | `contracts/adapters/RwaYieldAdapter.sol` | **OUSG/BUIDL must be removed from Shariah strategy (Task A)** |

Tests: 145 passing. All must remain green (or be updated when a test encodes a behaviour being deliberately removed).

---

## Three Design Defects Being Fixed

### Defect 1 — OUSG/BUIDL in S5-H (Task A)
`RwaYieldAdapter` holds OUSG and BUIDL tokens. Under SC Malaysia Shariah methodology, these are US Treasury-backed tokens. US Treasuries are interest-bearing debt instruments — holding them for yield is equivalent to receiving riba. The asset is not halal for a Shariah vault, regardless of the intermediating token structure.

**Action:** Remove OUSG/BUIDL from the permitted-assets list. Flag `RWA_SUKUK` (bit 4) strategy as `REVIEW` pending a Shariah board ruling. The adapter code is preserved; its `shariahCertified` flag in `ShariahScoreAggregator` is set to `false` until a board pronouncement is recorded.

### Defect 2 — Non-atomic Gold Exchange in S2-H (Task C)
`HalalLPAdapter` + `scoreGoldSpread()` simulate a PAXG spread. Under classical fiqh (and SC methodology), gold must change hands simultaneously (yad bi yad) — a two-step LP deposit/withdraw is not the same as a bilateral spot exchange and introduces a gap that resembles nasi'a (deferred exchange). 

**Action:** Introduce a `GoldExchangeAdapter` (new contract) that wraps a single atomic Uniswap V3 `exactInputSingle` swap — one transaction, simultaneous exchange of USDC for PAXG at the pool spot price. The LP position-based `HalalLPAdapter` remains available for the USDC/ETH pair only (not PAXG). Flag gold LP as `REVIEW`.

### Defect 3 — Misleading "Zakat" Label in ZakatModule (Task B)
The current `ZakatModule.distributeZakat()` routes a 2.5% cut of Musharakah gross profit. This conflates two distinct Islamic finance concepts:
- **Zakat** — an obligatory pillar of Islam; a levy on *net wealth* held above nisab for a full lunar year. It is NOT a percentage of transaction profit.
- **Purification** — a voluntary deduction of the haram-tainted fraction of mixed-income profit (used when a screened stock still has minor impermissible revenue).

Calling a profit-deduction "Zakat" is both theologically inaccurate and potentially legally problematic (AGENTS.md Rule 6: no marketing words without board pronouncement).

**Action:** Rename the module to `CharityPurificationModule`. Keep the 2.5% default rate but rename it to `purificationBps`. Add a separate `charityBps` parameter (default 0, board-settable). The `distributeZakat()` function becomes `distributeForPurification(uint256 grossProfit) returns (uint256 purificationAmount, uint256 charityAmount, uint256 remaining)`. All UI copy is updated. A `SHARIAH_REVIEW.md` entry is created requesting a board determination on both rates.

---

## SC Malaysia Methodology Re-Screen (Task D)

Re-screen all 5 Shariah strategies plus each permitted asset against SC Malaysia's published Shariah screening criteria (2024 revision).

### Screening matrix

| Strategy | SC criterion | Provisional result | Action |
|---|---|---|---|
| S1-H ETH/USDC Spread | Commodity arbitrage — price difference on spot exchange | **PASS** — spot commodity price difference, no riba |  No change |
| S2-H PAXG Gold Spread | Gold exchange — yad bi yad required | **CONDITIONAL** — LP structure fails yad bi yad; atomic swap passes | Replace LP with `GoldExchangeAdapter` (Task C) |
| S3-H Halal LP (USDC/ETH) | Musharakah in trading pool | **PASS** — fee income from real trading volume, not lending | No change |
| S4-H Commodity Murabaha | Bay al-murabaha | **PASS** — cost, markup, and deadline stored onchain before execution | No change |
| S5-H RWA/Sukuk (OUSG/BUIDL) | Asset screen: underlying is US Treasuries (interest-bearing) | **FAIL** — OUSG/BUIDL are riba-based instruments | Remove from Shariah tier; add `REVIEW` entry |

### Permitted-asset re-screen

| Asset | SC criterion | Result |
|---|---|---|
| USDC | Stablecoin, not interest-bearing by itself | PASS |
| ETH | Productive asset; staking yield from validation | PASS |
| PAXG | Physical gold 1:1 Brinks custody | PASS |
| OUSG | Tokenised US Treasuries | **FAIL — remove** |
| BUIDL | BlackRock USD Institutional Digital Liquidity Fund (US T-bills) | **FAIL — remove** |

---

## Task E — ShariahVault v2 and Migration

After Tasks A–D are complete and all `REVIEW` entries have board responses, a new `ShariahVaultV2` is deployed. V1 remains live so existing depositors can redeem at NAV (AGENTS.md Rule 4 — no forced migration).

### V2 changes vs V1

| Area | V1 | V2 |
|---|---|---|
| RWA strategy | OUSG/BUIDL via `RwaYieldAdapter` | Removed pending board ruling |
| Gold strategy | LP-based `HalalLPAdapter` | Replaced by `GoldExchangeAdapter` (atomic swap) |
| Charity module | `ZakatModule` | `CharityPurificationModule` |
| Migration | N/A | `migrateToV2(uint256 shares)` — user redeems from V1, receives USDC, re-deposits into V2 |
| Screening registry | Inline `screened` mapping | Points to a separate `ShariahAdapterRegistry` (owner = multisig with timelock) |

### V2 deployment sequence

1. Deploy `CharityPurificationModule` (replaces `ZakatModule`)
2. Deploy `GoldExchangeAdapter`
3. Deploy `ShariahVaultV2` — constructor points to V2 treasury and new module
4. Register V2-approved adapters in `ShariahAdapterRegistry`
5. Set `ShariahScoreAggregator.setCertified(RWA_SUKUK, false)` on V1 aggregator
6. Deploy new `ShariahScoreAggregator_V2` (4-strategy — no RWA_SUKUK slot; enum deprecates it to keep bit positions)
7. Announce migration window; keep V1 withdrawals open indefinitely

---

## Files to Create / Modify per Task

### Task A — Remove OUSG/BUIDL
| File | Change |
|---|---|
| `contracts/ShariahVault.sol` | Remove OUSG/BUIDL from constructor `permittedAssets` list |
| `contracts/ShariahScoreAggregator.sol` | `setCertified(RWA_SUKUK, false)` — in deploy script, not in contract code |
| `server/shariah-strategies.ts` | Annotate `RWA_SUKUK` scorer as `REVIEW_PENDING`; suppress from live execution |
| `docs/agents/SHARIAH_REVIEW.md` | Add entry: `RWA_SUKUK / OUSG / BUIDL — REVIEW — US Treasury underlying` |
| `contracts/test/...` | Update any test that asserts OUSG/BUIDL is a permitted asset |

### Task C — Atomic Gold Exchange
| File | Change |
|---|---|
| `contracts/adapters/GoldExchangeAdapter.sol` | **New** — single `exactInputSingle` Uniswap V3 swap; USDC→PAXG |
| `contracts/ShariahVault.sol` | Screen `GoldExchangeAdapter`; remove PAXG from LP adapter screening |
| `server/shariah-strategies.ts` | `scoreGoldSpread()` — replace simulated deviation with call to `GoldExchangeAdapter.getQuote()` |
| `docs/agents/SHARIAH_REVIEW.md` | Add entry: `GOLD_SPREAD / atomic swap — REVIEW — confirm yad bi yad satisfied` |
| `contracts/test/GoldExchangeAdapterTest.t.sol` | **New** — unit tests: quote, execute, atomicity, revert paths |

### Task B — Rename/Restructure Charity Module
| File | Change |
|---|---|
| `contracts/ZakatModule.sol` | Keep file as is; deprecate `ZAKAT_BPS`; add comment directing to new module |
| `contracts/CharityPurificationModule.sol` | **New** — replaces ZakatModule; `purificationBps`, `charityBps`, separate wallets, same 30-day timelock |
| `contracts/ShariahVault.sol` | Add constructor option to wire `CharityPurificationModule` instead of `ZakatModule` |
| `src/components/ZakatTracker.tsx` | Rename to `CharityPurificationTracker.tsx`; remove "Zakat" label from UI |
| `docs/agents/SHARIAH_REVIEW.md` | Add entry: `Purification rate 2.5% — REVIEW — board must set rate and confirm concept` |
| `contracts/test/CharityPurificationModuleTest.t.sol` | **New** — mirrors existing ZakatModuleTest but tests both purificationBps and charityBps |

### Task D — SC Re-Screen
| File | Change |
|---|---|
| `docs/agents/SHARIAH_REVIEW.md` | Add detailed per-strategy and per-asset screening entries |
| `server/shariah-strategies.ts` | Annotate each strategy with SC criterion reference |
| `contracts/ShariahScoreAggregator.sol` | No code change; `shariahCertified` flags updated via deploy/admin scripts |

### Task E — ShariahVault v2
| File | Change |
|---|---|
| `contracts/ShariahVaultV2.sol` | **New** — inherits AutonomousVault; wires CharityPurificationModule + GoldExchangeAdapter |
| `contracts/ShariahAdapterRegistry.sol` | **New** — separate screening registry; owner = 2-of-3 multisig with timelock |
| `contracts/script/DeployShariahV2.s.sol` | **New** — Foundry deploy script |
| `docs/agents/deployed-addresses.md` | Update after deploy |
| `AGENTS.md` | Update Phase 2 → Phase 3 status |

---

## SHARIAH_REVIEW.md Entries Required

The following items need a board ruling before they can be marked certified. Code must treat each as `NOT ALLOWED TO DEPLOY` until a written pronouncement exists.

| ID | Item | Status | Blocker |
|---|---|---|---|
| SR-001 | RWA_SUKUK / OUSG / BUIDL | REVIEW | US Treasury-backed instruments — underlying is interest-bearing debt |
| SR-002 | GOLD_SPREAD / LP-based gold exposure | REVIEW | LP deposit/withdraw cycle may not satisfy yad bi yad |
| SR-003 | GOLD_SPREAD / atomic swap | REVIEW | Confirm atomic Uniswap V3 swap satisfies yad bi yad under SC methodology |
| SR-004 | Purification rate 2.5% | REVIEW | Board must determine correct rate and confirm it is purification, not Zakat |
| SR-005 | Charity wallet designation | REVIEW | Board must designate an approved charity recipient |

---

## Task Execution Order

Work **one task per session**. Each task is a self-contained PR.

```
Session 1: Task A — Remove OUSG/BUIDL
Session 2: Task C — Atomic gold exchange (GoldExchangeAdapter)
Session 3: Task B — CharityPurificationModule (rename + restructure)
Session 4: Task D — SC re-screen annotation pass
Session 5: Task E — ShariahVaultV2 + migration
```

---

## Hard Constraints (from AGENTS.md)

1. Testnet only — never deploy to mainnet.
2. Do not touch ConventionalVault or its adapters.
3. Never reorder `ShariahStrategy` enum — deprecate at end.
4. No forced migration — V1 withdrawals stay open indefinitely.
5. Every Shariah decision is data (board-settable via timelock), never hard-coded.
6. No "certified", "halal", "sukuk", "Zakat" labels without a recorded board pronouncement.
7. One task per PR; PR description lists changed contracts, new tests, and new SHARIAH_REVIEW entries.

---

## Done-When Checklist (cumulative across all 5 tasks)

- [ ] Task A: OUSG/BUIDL removed from `permittedAssets` in ShariahVault constructor
- [ ] Task A: `shariahCertified[RWA_SUKUK]` is `false` in all deploy scripts
- [ ] Task A: SR-001 entry exists in `SHARIAH_REVIEW.md`
- [ ] Task C: `GoldExchangeAdapter` deployed and tested (atomic swap, not LP)
- [ ] Task C: Gold LP adapter removed from PAXG pair screening
- [ ] Task C: SR-002 and SR-003 entries exist in `SHARIAH_REVIEW.md`
- [ ] Task B: `CharityPurificationModule` deployed; no "Zakat" label in code or UI
- [ ] Task B: SR-004 and SR-005 entries exist in `SHARIAH_REVIEW.md`
- [ ] Task D: All 5 strategies annotated with SC criterion reference in `shariah-strategies.ts`
- [ ] Task E: `ShariahVaultV2` deploys; V1 deposits/withdrawals still function
- [ ] Task E: `migrateToV2()` opt-in function implemented and tested
- [ ] Task E: All 145 existing tests green (or updated with documented reason)
- [ ] All sessions: lint and typecheck pass with zero errors
