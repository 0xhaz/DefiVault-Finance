# SHARIAH_REVIEW.md

This file records every item that requires a Shariah board ruling before the corresponding
code or configuration goes live. No item listed here may be deployed or used in production
until a board pronouncement is recorded and the status updated to APPROVED or REJECTED.

Agent role boundary: you are an engineer, not a Shariah authority.
You implement flags and mechanisms. You never declare an adapter "halal" or "certified".

Entries are ordered by number. Every entry uses the same table header and ends with a
`Board decision / pronouncement hash:` line. Engineering-only items that need no ruling are
closed as SUPERSEDED.

---

## Status key

| Status | Meaning |
|---|---|
| REVIEW | Pending board ruling. Code may exist but the feature is blocked |
| APPROVED | Board pronounced in favour. Record the pronouncement reference |
| REJECTED | Board ruled against. Record the basis |
| SUPERSEDED | Replaced by a later design or fixed in code. Text kept for history; the line under the table names the replacement |

## Index

| SR | Topic | Status |
|---|---|---|
| SR-001 | OUSG / BUIDL: US Treasury-backed RWA tokens | REVIEW |
| SR-002 | Charity contribution rate (2.5%) | REVIEW |
| SR-003 | Charity wallet designation | REVIEW |
| SR-004 | Musharakah loss-sharing and HWM ordering | REVIEW |
| SR-005 | GoldExchangeAdapter: atomic swap (yad bi yad) | REVIEW |
| SR-006 | Live PAXG custody and allocation terms | REVIEW |
| SR-007 | ETH_SPREAD: deferred currency exchange question | REVIEW |
| SR-008 | XAUT (Tether Gold): certification and qabd hukmi | REVIEW |
| SR-009 | Holding PAXG and XAUT together; 30% gold cap | REVIEW |
| SR-010 | Oracle vs pool deviation guard | REVIEW |
| SR-011 | S3-H LP: USDC/XAUT pool consideration | REVIEW |
| SR-012 | Purification rate: blended vs per-adapter | REVIEW |
| SR-013 | Gold oracle stale-price fallback | REVIEW |
| SR-014 | High-water mark and profit unlock | REVIEW |
| SR-015 | Cross-chain pending cap and owner-supplied `received` | SUPERSEDED by SR-019 |
| SR-016 | S2-H stale-price valuation and deposit pause | REVIEW |
| SR-017 | Balance-snapshot settle | SUPERSEDED by SR-019 |
| SR-018 | Single-source board role via registry | REVIEW |
| SR-019 | Atomic cross-chain settle | REVIEW |
| SR-020 | Dust threshold for deposit pause | REVIEW |
| SR-021 | Registry required at construction | REVIEW |
| SR-022 | Invariant suite (8 invariants) | REVIEW |
| SR-023 | Gold cross-chain block was too broad | SUPERSEDED (engineering fix, Task N1) |
| SR-024 | Commodity Murabaha (S4-H) | REVIEW |
| SR-025 | USDC as the vault asset | REVIEW |
| SR-026 | Wakala fee alongside Musharakah profit share | REVIEW |
| SR-027 | ETH as a permitted asset; ETH_SPREAD | REVIEW |

---

## SR-001 — OUSG / BUIDL: US Treasury-backed RWA tokens

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-21 |
| Task | A |
| Affects | `RwaYieldAdapter`, `ShariahScoreAggregator` index 4, `ShariahVault.permittedAssets` |

**Issue.** OUSG (Ondo Finance) and BUIDL (BlackRock) are tokenised wrappers of US Treasury
bills. Their yield is interest income from a sovereign debt instrument. The engineering reading
is that this income is riba and that the `non_compliant_income_ratio` for these funds is
effectively 1.0, far above the 5% screening benchmark. The 5% benchmark comes from the SC
Malaysia Shariah Advisory Council (SC-SAC) 288th and 296th meetings. Cite those meetings as
the screening benchmark only: they did not rule on tokenised Treasuries, so the
classification of this yield is a question for the board, not a settled ruling.
Additionally, both funds have qualified-investor access restrictions and minimum investment
thresholds that make them unrealistic for this vault's depositor base.

**Code action taken (pending ruling).**
- `ShariahScoreAggregator._writeScore` reverts `StrategyDeprecated(4)` for index 4.
- `scoreRwaSukuk()` in `server/shariah-strategies.ts` returns `score: 0, disabled: true`.
- `shariahSim.ts` strategy list reduced from 5 to 4 entries; `CONSERVATIVE_STRATEGY_IDS` = `{1, 2}`.
- `RwaYieldAdapter.sol` carries a NatSpec warning: "Interest-bearing. Not for Shariah vaults."
- `SHARIAH_CONSERVATIVE` executor mask updated to `38` (0b100110: Gold Spread + LP + Gold Allocation; Task F).
- `SHARIAH_DYNAMIC` executor mask updated to `47` (0b101111: all 5 active strategies; Task F).
- Enum value 4 retained as `RESERVED_4` (position not changed per AGENTS.md Rule 3).

**Board question.** Can any tokenised RWA instrument qualify for this vault? If yes, what
screening criteria apply (underlying asset class, income source, access restrictions)?

**Board decision / pronouncement hash:** none recorded

---

## SR-002 — Charity contribution rate (2.5%)

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-21 |
| Task | B |
| Affects | `CharityModule.charityBps` (default 250 = 2.5%) |

**Issue.** The 2.5% deduction from Musharakah profit is labelled "charitable contribution
(sadaqah)". The number was chosen because 2.5% is the Zakat rate on zakatable wealth. The
nisab is a different thing: it is the minimum wealth threshold below which Zakat is not due.
The rate is not derived from any fiqh principle for voluntary sadaqah. The board must confirm:
(a) the rate is appropriate for a voluntary charitable contribution; and
(b) the deduction is from gross Musharakah profit (before the Musharakah split), not from
the depositor's share only.

**Board decision / pronouncement hash:** none recorded

---

## SR-003 — Charity wallet designation

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-21 |
| Task | B |
| Affects | `CharityModule.charityWallet` |

**Issue.** The wallet that receives the charitable contribution must be a recognised charitable
organisation or waqf institution. The board must approve the recipient address and any future
changes (a 30-day timelock is enforced in code, but the timelock alone does not constitute
board approval of the recipient).

**Naming.** `CharityModule` uses `charityWallet`. The deprecated v1 `ZakatModule` still exposes
`zakatWallet` because it is frozen for the live v1 vaults and renaming it would change a
deployed ABI. No new code or UI may use that name (AGENTS.md hard rule 6).

**Board decision / pronouncement hash:** none recorded

---

## SR-004 — Musharakah loss-sharing: manager share in loss periods and HWM ordering

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-21 (HWM clarification added in Task I) |
| Task | B, H (PR3.1), I |
| Affects | `ShariahVault.claimMusharakahProfit`, `TreasuryModule.calculateMusharakahSplit`, `TreasuryModule.calculateMusharakahSplitHWM` |

**Issue.** Classical Musharakah requires losses to be borne pro-rata to capital contribution.
The original implementation did not auto-deduct from the manager share in a loss period:
`claimMusharakahProfit` is only callable by the manager/owner, who will only call it when
profit exists, and the hurdle reset (`hurdlePrincipal = totalAssets()` after a claim) treated
a recovery from an earlier loss as fresh profit. The board must confirm:
(a) whether the manager share is zero in any period where `totalAssets() < hurdlePrincipal`;
(b) whether the hurdle-reset-on-claim approach is acceptable or whether a cumulative loss
carry-forward is required.

**Partial mitigation (PR3.1).** `calculateMusharakahSplitHWM` carries a cumulative loss
(`hwmDeficit`) forward. The split ordering is:

```
afterRecovery  = max(0, grossProfit − hwmDeficit)
surplus        = max(0, afterRecovery − hurdleAmount)
vaultShare     = surplus × musharakahShareBps / 10_000
depositorShare = grossProfit − vaultShare
```

- If `grossProfit < hwmDeficit`: `afterRecovery = 0`, `vaultShare = 0`. Depositors absorb the full gross as partial loss recovery.
- If `grossProfit > hwmDeficit` but `afterRecovery ≤ hurdle`: `surplus = 0`, `vaultShare = 0`.
- Only when `afterRecovery > hurdle` does the manager earn a share, and only on that surplus.

**Board confirmation required.** Whether the hurdle applies to the post-recovery excess
(current implementation) or to the full gross profit.

**Engineering note.** The waterfall in `PurificationEscrow` currently calls the non-HWM split.
Wiring `hwmDeficit` into it is tracked as N-07 in `docs/security-review.md`. Until that is
fixed, answer (a) above is "not enforced in the live path".

**Board decision / pronouncement hash:** none recorded

---

## SR-005 — GoldExchangeAdapter: atomic swap satisfying yad bi yad

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-21 |
| Task | C |
| Affects | `GoldExchangeAdapter`, `ShariahVault.goldSpreadAdapter` |

**Issue.** AAOIFI SS 57 and classical fiqh require gold-for-currency exchanges to be
simultaneous (yad bi yad, hand to hand). The `GoldExchangeAdapter` executes a single
Uniswap V3 `exactInputSingle` call, completing USDC→PAXG in one transaction. The board
must confirm that:
(a) a single EVM transaction satisfies the simultaneity requirement;
(b) PAXG (PAX Gold, 1:1 physically allocated gold in Brinks vaults) is an acceptable
    gold instrument, specifically that the allocated-gold status is continuously verifiable
    and that the token is redeemable for allocated bars.

**Code enforcement.** Gold strategies (S2-H GOLD_SPREAD, S6-H GOLD_ALLOCATION) can never be
routed cross-chain: `ShariahVault.deployCrossChainForStrategy` always reverts `NonAtomicGoldExchange`
for strategy index 1 or 5, and the Shariah executor reverts it when a gold winner reports a
non-zero destination domain (Task N1).

**Board decision / pronouncement hash:** none recorded

---

## SR-006 — Live PAXG token custody and allocation terms

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-21 |
| Task | C |
| Affects | `GoldExchangeAdapter` (testnet uses `MockAllocatedGold`) |

**Issue.** On testnet, `MockAllocatedGold` (a plain ERC-20) is used as a stand-in.
Before any mainnet or production deployment:
(a) The board must review Paxos's custody agreement and bar-allocation documentation.
(b) The board must confirm that PAXG on the target chain (Arc, Arbitrum, etc.) has the
    same legal backing as mainnet PAXG; Paxos's cross-chain bridging terms apply.
(c) If PAXG is not available on Arc Testnet, an alternative allocated-gold token must be
    identified and board-approved before the strategy goes live.

**Board decision / pronouncement hash:** none recorded

---

## SR-007 — ETH_SPREAD: deferred currency exchange question

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-21 |
| Task | C |
| Affects | `server/shariah-strategies.ts` scoreEthSpread(), `ShariahScoreAggregator` index 0 |
| Related | SR-027 (ETH classification) |

**Issue.** The ETH_SPREAD strategy routes USDC from Arc to another chain (Arbitrum, Base, OP)
via CCTP, executes a swap on arrival, and bridges back. This is a multi-step cross-chain flow
with a temporal gap between USDC leaving the vault and ETH being received.

If the board classifies ETH as a currency (thaman), this gap would constitute a deferred
currency-for-currency exchange (prohibited under riba al-nasi'a). If ETH is classified as
a commodity (sil'a), spot arbitrage is permissible.

**Recommendation.** Apply the same atomic-only rule used for GOLD_SPREAD (Task C) until the
board issues a ruling on ETH's classification. The code currently does NOT enforce this for
ETH_SPREAD: since Task N1 the cross-chain guard is per strategy and covers only the two gold
strategies. A guard equivalent to `NonAtomicGoldExchange` should be added for index 0 once a
ruling is obtained. ETH_SPREAD must not go live before SR-027 is resolved.

**Board decision / pronouncement hash:** none recorded

---

## SR-008 — XAUT (Tether Gold): Amanah Advisors certification and qabd hukmi

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-22 |
| Task | F |
| Affects | `GoldAllocationAdapter`, `ShariahVault.goldAllocationAdapter`, `ShariahScoreAggregator` index 5 |

**Issue.** XAUT (Tether Gold) represents 1 fine troy oz of gold allocated on the London Bullion Market and stored in third-party Swiss vaults. It is issued by Tether Limited, whereas PAXG is issued by Paxos.

Before `GoldAllocationAdapter` can be used in production:

(a) The board must review Tether Gold's latest custody terms, vault receipts, and any available Shariah certification. Amanah Advisors has reviewed gold-backed tokens; the board must confirm whether XAUT is covered by a current fatwa and whether the certification has expired.

(b) The yad bi yad requirement (AAOIFI SS 57): the adapter executes a single `exactInputSingle` Uniswap V3 call completing the USDC→XAUT exchange in one EVM transaction. The board must confirm this satisfies simultaneity. This is the same ruling question as SR-005 for PAXG, applied to XAUT.

(c) Qabd hukmi (constructive possession): the board must confirm that receiving XAUT tokens in the vault's account constitutes valid qabd hukmi of the underlying gold, even though the physical gold never transfers custody to the vault operator.

**Code action taken (pending ruling).**
- `strategyEnabled[5]` defaults to `false` in `ShariahScoreAggregator` (renamed from `shariahCertified` in G3).
- `GoldAllocationAdapter.protocolName()` references `SR-008`.
- Testnet uses `MockXAUT`. No live XAUT interaction until SR-008 is resolved.

**Board decision / pronouncement hash:** none recorded

---

## SR-009 — Holding PAXG and XAUT simultaneously; combined 30% gold cap

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-22 |
| Task | F |
| Affects | `ShariahVault.MAX_GOLD_BPS`, `goldSpreadAdapter`, `goldAllocationAdapter` |

**Issue.** The `ShariahVault` may simultaneously hold PAXG (via `GoldExchangeAdapter`) and XAUT (via `GoldAllocationAdapter`). The combined cap is `MAX_GOLD_BPS = 3000` (30%). The board must confirm:

(a) That holding both PAXG and XAUT simultaneously does not violate any prohibition on dual-gold-instrument exposure (both represent physically allocated gold but issued by different custodians).

(b) That the 30% combined cap is appropriate from a risk-management perspective and does not create impermissible concentration in a single asset class.

(c) That the combined-cap calculation (sum of `goldSpreadAdapter.currentValue()` + `goldAllocationAdapter.currentValue()`) correctly represents the true gold exposure at all times, including during oracle staleness periods. A stale adapter values its position at `lastGoodPrice × (1 − staleHaircutBps)` (default 5% haircut, cap 20%; see SR-013), never at cost basis. The board must confirm the haircut is conservative enough.

**Board decision / pronouncement hash:** none recorded

---

## SR-010 — Lower-of-two-prices deviation guard (oracle vs pool): fairness in pricing

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-22 |
| Task | F |
| Affects | `GoldAllocationAdapter._getPoolPrice`, `maxDeviationBps` |

**Issue.** `GoldAllocationAdapter` checks that the Uniswap V3 pool price is within `maxDeviationBps` (default 1%) of the Chainlink XAU/USD oracle price before executing a swap. This prevents execution at prices that deviate significantly from spot, but:

(a) The oracle (Chainlink) represents the global gold market price; the pool (USDC/XAUT on a DEX) may legitimately diverge from the oracle by up to 1% due to liquidity conditions. The board must confirm this tolerance is acceptable.

(b) If the pool price is 1% above oracle at the time of a USDC→XAUT buy, the vault pays more USDC than the oracle-implied fair price. The board must confirm this is not gharar (excessive uncertainty) or zulm (unfairness) to depositors.

(c) The `maxDeviationBps` parameter is subject to a 30-day timelock before it can be changed. The board must confirm the timelock length is appropriate for this type of operational parameter.

**Board decision / pronouncement hash:** none recorded

---

## SR-011 — S3-H Halal LP disclosure: USDC/XAUT pool consideration

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-22 |
| Task | F |
| Affects | `HalalLPAdapter`, `server/shariah-strategies.ts` scoreHalalLP(), `src/lib/shariahSim.ts` |

**Issue.** The current S3-H Halal LP strategy targets USDC/ETH Uniswap V3 pools on Arbitrum and Base. Task F introduces a USDC/XAUT pool (via `MockUniswapV3PoolXAUT` on testnet, or a real USDC/XAUT pool on production). The `HalalLPAdapter` does not currently route to USDC/XAUT pools, but future extension is possible.

The board must confirm, before any USDC/XAUT LP position is taken:

(a) Whether providing liquidity to a USDC/XAUT pool satisfies the Musharakah requirement for S3-H, i.e. that fee income from a gold-stablecoin pool is permissible and does not constitute riba or a deferred currency-for-currency exchange.

(b) If USDC/XAUT LP is permissible, whether it is subject to the combined 30% gold cap (SR-009) or is treated as fee income (USDC) only.

(c) The current code does NOT route any LP capital to USDC/XAUT pools. This ruling is required only before such a pool is added to the strategy's approved pool list.

**Board decision / pronouncement hash:** none recorded

---

## SR-012 — Purification rate: global blended rate vs per-adapter taint ratio

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-22 |
| Task | G (G6) / H (PR2) / I (I4, I5) |
| Affects | `PurificationEscrow.purificationBps`, `CharityModule`, profit waterfall |

**Governance fix (PR2).** `PurificationEscrow.setPurificationBps` (previously immediate, owner-only) was replaced with `proposePurificationRate` → `confirmPurificationRate` (30-day timelock, `onlyBoard`). This resolves the governance asymmetry with `charityBps`.

**Board membership (I4/I5, J3).** Board membership comes from `ShariahAdapterRegistry.isBoard()`, not from an owner-granted local mapping. `PurificationEscrow` requires a registry at construction (`RegistryRequired`), and the registry constructor does not make the deployer a board member by default (see SR-018). The local `boardRole` mapping and its owner-only grant/revoke functions are vestigial.

**Open architectural issue.** Task B's original spec called for a per-adapter `taintedRatioBps`: each adapter would report its own non-compliant income fraction, and the purification step would deduct only the tainted portion. The current implementation uses a single global `purificationBps` applied to all Musharakah profit regardless of source.

The board must confirm whether a single blended purification rate is acceptable, or whether the vault must track per-adapter taint and apply individualized rates:

(a) **If blended rate is acceptable:** The current implementation is sufficient. The board sets `purificationBps` to a conservative rate that covers any plausible taint from the strategy mix (e.g., 0–2% for swap-fee strategies, 0% for atomic gold swaps). The rate must be explicitly reviewed at every strategy configuration change.

(b) **If per-adapter rates are required:** `PurificationEscrow.executeWaterfall` must accept an array of `(adapterAddress, taintedRatioBps, grossProfit)` tuples. Each strategy adapter must implement a `reportedTaintRatio()` view function. This is a significant architecture change that would also require updates to `ShariahVault.claimMusharakahProfit`.

**Current code action (pending ruling):** Global `purificationBps` defaulting to 0. No USDC is routed to purification until the board sets a rate AND SR-002 is resolved. `CharityTracker.tsx` tracks charity (sadaqah) and purification as separate line items.

**Board decision / pronouncement hash:** none recorded

---

## SR-013 — Gold oracle stale-price fallback (PR1 implemented)

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-22 |
| Task | H (PR1) |
| Affects | `GoldAllocationAdapter.currentValue()`, `ShariahVault.maxDeposit/maxMint` |

**Issue.** When the Chainlink XAU/USD oracle is stale, `currentValue()` previously returned `totalDeployed` (cost basis). This overstates value when gold has fallen (unfair to redeemers), and understates when gold has risen (unfair to depositors).

**Implemented (PR1).** After every successful oracle read, `lastGoodPrice` is cached. When the oracle is not sane, `currentValue()` returns `lastGoodPrice × (1 - staleHaircutBps)`. The pool price is no longer used in valuation, because an instantaneous pool price can be manipulated and valuation sets the share price. A fresh oracle values the position at the oracle price only. The vault marks both gold adapters in `totalAssets()` in both directions, but unrealized gains are excluded from distributable profit. `maxDeposit`/`maxMint` materiality is tested against the adapter's funded principal. Default haircut: 5%. Hard cap: 20%. Board-settable via 30-day timelock (`PARAM_STALE_HAIRCUT`). Cost basis is never used in valuation. `maxDeposit`/`maxMint` return 0 when the oracle is insane and the funded principal is above the effective dust threshold (SR-020); redemptions remain open.

**Board action required.** Default `staleHaircutBps = 500` (5%) is a reasonable engineering default. Board should confirm this is within approved parameters before live deploy.

**Board decision / pronouncement hash:** none recorded

---

## SR-014 — High-water mark and profit unlock (PR3 implemented)

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-22 |
| Task | H (PR3) |
| Affects | `TreasuryModule.calculateMusharakahSplitHWM`, `AutonomousVault.lockProfit`, `ShariahVault.claimMusharakahProfit` |
| Related | SR-004 |

**Issue.** Two separate fairness risks: (a) after a vault loss, the manager could earn profit share on recovery before all depositors' losses are made whole (high-water mark); (b) a depositor could deposit just before a profit claim and redeem immediately after, extracting profit they did not earn (sandwich attack).

**Implemented (PR3.1 + PR3.2).** `TreasuryModule.calculateMusharakahSplitHWM(hwmDeficit)` zeroes `vaultShare` until recovery > `hwmDeficit`. `claimMusharakahProfit` updates `highWaterMark` and `hwmDeficit` before each claim. `AutonomousVault._currentLockedProfit()` linearly decays `lockedProfit` over `profitUnlockPeriod` (default 3 days, max 14 days); `totalAssets()` subtracts locked profit so a deposit-claim-redeem earns ~0. `claimMusharakahProfit` calls `_lockProfitInternal(depositorShare)` after each waterfall.

**Board action required.** Default `profitUnlockPeriod = 3 days`. Board to confirm this is acceptable. `calculateMusharakahSplitHWM` is a pure helper; existing `calculateMusharakahSplit` remains for backward compat.

**Board decision / pronouncement hash:** none recorded

---

## SR-015 — Cross-chain pending cap and owner-supplied `received` (PR3 implemented)

| Field | Value |
|---|---|
| Status | SUPERSEDED |
| Raised | 2026-10-22 |
| Task | H (PR3) |
| Affects | `AutonomousVault.deployCrossChain`, `AutonomousVault.settleCrossChain` |

> **Superseded by SR-019 (Task J1).** `settleCrossChain(nonce, received)` with an owner-supplied
> `received` no longer exists as a settle path. The 20% pending cap lives on and is now asked
> about under SR-019(c). Text below is kept for history.

**Issue.** (a) No cap on how much vault capital could be in-flight cross-chain: a single deploy could send 100% of assets to a remote chain with no recovery guarantee. (b) `settleCrossChain` had no mechanism to handle bridge shortfalls (fees, slippage, loss); a returned amount less than sent would have been silently ignored.

**Implemented (PR3.3).** `maxPendingCrossChainBps` (default 2000 = 20%, max 5000) enforces a cap at deploy time, checked against pre-burn `totalAssets()`. `settleCrossChain(nonce, received)` took a `received` param. Shortfall = `sent - received` was booked as an immediate NAV loss. `CrossChainSettled` emits `(nonce, received, shortfall)`.

**Board decision / pronouncement hash:** none recorded

---

## SR-016 — S2-H (PAXG) stale-price valuation and deposit pause (Task I, I2; K2; J2)

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-23 |
| Task | I (I2), J (J2), K (K2) |
| Affects | `GoldExchangeAdapter.currentValue()`, `GoldExchangeAdapter.isPriceSane()`, `ShariahVault.maxDeposit/maxMint` |

**Issue.** `GoldExchangeAdapter` (S2-H, PAXG) previously returned `totalDeployed` (cost basis) from `currentValue()`, overstating value when gold has fallen. Task I applied the same PR1 treatment as S6-H: `lastGoodPrice` is cached, stale `currentValue()` = `grossValue × (1 − staleHaircutBps)` (default 5%, cap 20%).

**Current staleness rule (K2).** S2-H uses the mandatory XAU/USD oracle (same feed family as S6-H); the constructor reverts `OracleRequired` without it. `isPriceSane()` is false when the oracle's `updatedAt` age exceeds `maxStalenessSecs` (default 1 day, max 7 days). The earlier last-swap-age fallback is removed.

**Deposit gate (J2).** `maxDeposit`/`maxMint` return 0 only when a gold adapter is stale AND holds more than `dustThreshold` of value (see SR-020). Either gold adapter can trigger the gate.

The board must confirm:

(a) That an oracle `updatedAt` limit of 1 day is appropriate for S2-H.

(b) Whether `staleHaircutBps = 500` (5%) is conservative enough for a DEX-traded asset.

(c) That the combined gate (S6-H stale OR S2-H stale, and above dust) is correct.

**Board decision / pronouncement hash:** none recorded

---

## SR-017 — Balance-snapshot settle (Task I, I1)

| Field | Value |
|---|---|
| Status | SUPERSEDED |
| Raised | 2026-10-23 |
| Task | I (I1) |
| Affects | `AutonomousVault.settleCrossChain`, `AutonomousVault.balanceBeforeDeploy` |

> **Superseded by SR-019 (Task J1).** The balance-snapshot guard was replaced by
> `settleCrossChainWithMessage`, which measures the balance delta atomically around
> `receiveMessage`. The snapshot guard was unreliable: redemptions and unrelated transfers
> between deploy and settle moved the vault balance, so the delta no longer reflected what
> CCTP delivered. Text below is kept for history.

**Issue.** Before Task I, `settleCrossChain(nonce, received)` trusted the manager-supplied `received` parameter. Over-reporting would inflate NAV; under-reporting would book a phantom loss.

**Implemented (I1, since replaced).** `deployCrossChain` snapshotted the vault's post-burn USDC balance in `balanceBeforeDeploy[nonce]`, and `settleCrossChain` reverted `ReceivedExceedsArrived(received, arrived)` if `received` exceeded the balance delta.

**Board decision / pronouncement hash:** none recorded

---

## SR-018 — Single-source board role: registry as authority for CharityModule and PurificationEscrow (Task I, I4/I5)

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-23 |
| Task | I (I4, I5) |
| Affects | `CharityModule.boardRegistry`, `PurificationEscrow.boardRegistry`, `ShariahAdapterRegistry.isBoard()`, `ShariahAdapterRegistry` constructor |

**Issue.** Before Task I, `CharityModule` (wallet/rate changes) and `PurificationEscrow` (purification rate) each maintained a local `boardRole` mapping. A board composition change in the registry did not propagate to these contracts, creating a window of divergence.

**Implemented (I4/I5).**
- `ShariahAdapterRegistry.isBoard(address)` view function added (returns `boardRole[account]`).
- `CharityModule` and `PurificationEscrow` constructors accept `boardRegistry` (immutable). `onlyBoard` checks `registry.isBoard(msg.sender)`.
- `ShariahAdapterRegistry` constructor accepts `(initialOwner, initialBoardMember)`. `initialOwner` does NOT automatically receive `boardRole`; only `initialBoardMember` does. On production: `initialBoardMember` must be the organisation's Safe multisig address.
- `DeployShariahV2.s.sol` reads `BOARD_MULTISIG` env var (falls back to deployer on testnet).

**Board action required.**
(a) Confirm the production `BOARD_MULTISIG` address to use as `initialBoardMember` in the registry constructor.
(b) Confirm that the deployer-as-owner-but-not-board separation is acceptable for testnet (documented risk: testnet board == deployer EOA).
(c) Confirm the asymmetric emergency power: owner can `emergencyRevokeBoardRole` (instant, no timelock); owner cannot grant board membership without the board itself proposing (30-day timelock).

**Board decision / pronouncement hash:** none recorded

---

## SR-019 — Atomic cross-chain settle: MessageTransmitter trust (Task J, J1)

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-23 |
| Task | J (J1), M |
| Affects | `AutonomousVault.settleCrossChainWithMessage`, `IMessageTransmitterV2`, `CctpMessageDecoder`, `maxPendingCrossChainBps` |
| Supersedes | SR-015, SR-017 |

**Change.** The old snapshot-based `settleCrossChain(nonce, received)` is replaced by `settleCrossChainWithMessage(nonce, message, attestation)` which calls `MessageTransmitter.receiveMessage` atomically, measures the USDC balance delta, and verifies it against the message-encoded amount. The old `settleCrossChain(nonce, 0)` remains as a write-off-only path (`onlyOwner`, `received` must be 0).

**Residual risks.**
(a) **Decoder layout (Task M, done in code).** The vault now uses the native Circle V2 layout: a 148-byte `MessageV2` header with a `bytes32` nonce and a `BurnMessageV2` body (`amount` at 68, `feeExecuted` at 164, 228 fixed bytes), and the 7-argument `depositForBurn`. Offsets follow Circle's published message format; Circle's own libraries are not imported. It has only run against mocks, so a fork test against the real Arc `MessageTransmitterV2` is still required. Return messages must name the vault as `destinationCaller`, and the sender must be a registered remote TokenMessenger.
(b) `setMessageTransmitter` is `onlyOwner` (instant). An owner key compromise enables substitution of a malicious transmitter that mints arbitrary USDC to the vault. Board to confirm this is acceptable for testnet (no production funds) and to plan a timelock for mainnet.
(c) The pending cap `maxPendingCrossChainBps` (default 2000 = 20%, max 5000) bounds in-flight capital. Board to confirm the 20% default (carried over from SR-015).

**Board action required.** Confirm the key-management risk in (b) and the cap in (c). The layout question in (a) is an engineering fix, not a board matter.

**Board decision / pronouncement hash:** none recorded

---

## SR-020 — Dust threshold for deposit pause: empty adapter does not block deposits (Task J, J2; N2)

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-23 (revised 2026-10-28, Task N2) |
| Task | J (J2), N (N2) |
| Affects | `ShariahVault._goldPriceInsane()`, `ShariahVault.dustThreshold`, `ShariahVault.proposeDustThreshold/confirmDustThreshold/cancelDustThreshold` |

**Change.** `maxDeposit`/`maxMint` block deposits only when a gold adapter is both stale AND holds more than `dustThreshold` USDC of value (default 1 USDC). An idle adapter with zero position never blocks deposits even if it is stale.

**Oracle (K2).** `GoldExchangeAdapter.isPriceSane()` checks the XAU/USD oracle's `updatedAt` age. The oracle is mandatory, not "when set". A 3-day idle S2-H with a fresh oracle stays sane.

**Governance fix (N2).** The first version let the owner set `dustThreshold` immediately, on the argument that it only loosens restrictions. That reasoning was wrong. Raising the threshold lets deposits continue while a stale gold position up to that size is valued at the haircut price, so new depositors can enter cheaply and dilute existing holders. Now:
- `setDustThreshold` is removed.
- A hard cap applies: `max(0.5% of totalAssets(), 1 USDC)`, checked at both proposal and confirmation.
- Changes use board-gated `proposeDustThreshold` → `confirmDustThreshold` with a 30-day timelock and `cancelDustThreshold`. On `ShariahVaultV2` the board is `ShariahAdapterRegistry.isBoard()`; the deployer is not board by default. On the v1 vault, which has no registry, the owner acts as board.

**Board action required.**
(a) Confirm the 1 USDC default and the 0.5% hard cap are acceptable.
(b) Confirm S2-H's oracle-based staleness check (same XAU/USD feed family as S6-H) is acceptable.

**Board decision / pronouncement hash:** none recorded

---

## SR-021 — Registry required: CharityModule and PurificationEscrow cannot deploy without a registry (Task J, J3)

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-23 |
| Task | J (J3) |
| Affects | `CharityModule` constructor, `PurificationEscrow` constructor |

**Change.** Both contracts now revert `RegistryRequired()` when constructed with `boardRegistry = address(0)`. The local-fallback path (where the owner could act as sole board member) is removed. All new Shariah deploys must wire the registry at construction time.

**Board action required.** Confirm that the removal of the `address(0)` fallback does not block any planned deployment path, and that the production registry multisig address will be available before `CharityModule` and `PurificationEscrow` are deployed.

**Board decision / pronouncement hash:** none recorded

---

## SR-022 — Invariant suite: eight protocol invariants machine-verified (Task J, J4; Task K PR2)

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-23 (updated Task K) |
| Task | J (J4), K (PR2) |
| Affects | `AutonomousVault`, `ShariahVault`, `TreasuryModule`, `PurificationEscrow` |

**Invariant tests** (`contracts/test/invariant/VaultInvariant.t.sol`, 256 runs × depth 50, 17 handler actions):
1. `invariant_redeemNeverReverts`: any holder may always redeem up to `maxRedeem()` without revert.
2. `invariant_totalAssetsAccounting`: `totalAssets()` equals idle balance + `totalDeployed` minus locked profit (within 2 USDC rounding).
3. `invariant_goldCapNotExceeded`: combined gold value ≤ `MAX_GOLD_BPS` of `totalAssets()` at all times.
4. `invariant_noDilutionFromOtherUsers`: no depositor's share value falls because another user deposited or redeemed (beyond 2 USDC rounding). Share value may still fall from oracle moves, cross-chain shortfalls or fees; this is deliberately NOT a monotonicity check.
5. `invariant_vaultShareZero_when_hwmDeficit`: manager earns zero vault share during any loss-recovery period.
6. `invariant_lockedProfitDecaysToZero`: locked profit reaches zero after `unlockedAt` passes.
7. `invariant_totalPendingCrossChain_consistent`: `totalPendingCrossChain` equals the sum of open `pendingCrossChain[nonce]`.
8. `invariant_crossChainCapNeverExceeded`: the pending cross-chain cap is never exceeded.

**Board action required.** Confirm the above invariants accurately capture the Shariah depositor-fairness requirements. In particular, confirm invariant 4 (no dilution from other users) reflects the board's understanding of how deposits and redemptions interact with NAV.

**Board decision / pronouncement hash:** none recorded

---

## SR-023 — Gold cross-chain block was too broad (engineering fix, Task N1)

| Field | Value |
|---|---|
| Status | SUPERSEDED |
| Raised | 2026-10-28 (fork verification of rehearsal step 5) |
| Task | N (N1) |
| Affects | `ShariahVault.deployCrossChainForStrategy`, `RiskTieredExecutor.executeWinner`, rehearsal step 5 |

**What was wrong.** The earlier design set a `goldCrossChainBlocked` flag whenever a gold position was open, and the flag blocked every cross-chain deploy. Task C only requires that the gold strategies (S2-H GOLD_SPREAD, S6-H GOLD_ALLOCATION) never route cross-chain. Moving USDC with CCTP is a same-currency transfer, not a gold exchange. Holding gold in one adapter does not turn an unrelated USDC transfer into a deferred gold sale. This was an engineering defect, not a question for the board.

**Fix (merged with Task N1).**
- The `goldCrossChainBlocked` flag, its setter and its event are removed. There is no kill switch.
- The guard is per strategy. `deployCrossChainForStrategy` reverts `NonAtomicGoldExchange` whenever the strategy is GOLD_SPREAD (index 1) or GOLD_ALLOCATION (index 5), because that entry point always moves USDC over CCTP (domain 0 is Ethereum, not "local"). The Shariah executor reverts it when a gold winner reports a non-zero destination domain, and executes locally when the domain is zero.
- With gold held in S2-H and S6-H, a USDC/ETH_SPREAD cross-chain deploy is no longer blocked by the gold guard.
- Rehearsal step 5 no longer needs the owner to unblock anything.

The atomic-gold requirement itself is unchanged and stays under SR-005. ETH_SPREAD's own settlement question stays under SR-007 and SR-027.

**Board decision / pronouncement hash:** not applicable (engineering fix, no ruling needed)

---

## SR-024 — Commodity Murabaha (S4-H): enabled on testnet without a ruling

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-28 |
| Task | N (N3) |
| Affects | `CommodityMurabahaAdapter`, `ShariahScoreAggregator` index 3 (MURABAHA) |

**Issue.** S4-H is enabled on testnet and has had no SR entry of its own. The adapter records trade terms (cost, markup, deadline) onchain, but a valid Murabaha needs real-world conditions that a contract cannot supply:
- a real, identified commodity;
- a real counterparty (the buyer who requests the purchase);
- the seller (the vault) owning the commodity, and taking possession of it, before it is resold at the disclosed markup;
- a contract sequence (promise, purchase, sale) that the board approves.

**Board question.** What commodity, counterparty and contract sequence are acceptable, and what evidence of ownership and possession must exist onchain before `executeMurabaha` and `settleMurabaha` may run? Until a ruling is recorded, S4-H must not be used with real funds.

**Board decision / pronouncement hash:** none recorded

---

## SR-025 — USDC as the vault asset

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-28 |
| Task | N (N3) |
| Affects | `ShariahVault` asset, `permittedAssets`, all Shariah strategies |

**Issue.** The vault's base asset is USDC. The issuer's reserves earn interest, and that interest accrues to Circle, not to USDC holders. The vault never receives that interest, but the board should decide whether holding an asset backed by interest-bearing reserves is acceptable as the base currency. USDT has been removed from the permitted list, so only USDC is affected.

**Board question.** Confirm that USDC is acceptable as the base currency, or specify an alternative or conditions.

**Board decision / pronouncement hash:** none recorded

---

## SR-026 — Wakala fee (0.5% of AUM) alongside Musharakah profit share

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-28 |
| Task | N (N3) |
| Affects | `TreasuryModule` (wakala accrual), `ShariahVault._accrueWakalaFee`, `claimMusharakahProfit` |

**Issue.** The Shariah vault charges two things: a Wakala (agency) fee of 0.5% of AUM per year, accrued per block, and a Musharakah profit share of 10% above a 4% hurdle. The two structures come from different contract types.

**Board questions.**
(a) May an agency fee and a profit share be combined under one mandate?
(b) The Wakala fee accrues even in loss periods. Confirm this is acceptable, or require it to be reduced or suspended when the vault is below its high-water mark.

**Board decision / pronouncement hash:** none recorded

---

## SR-027 — ETH as a permitted asset; ETH_SPREAD

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-28 |
| Task | N (N3) |
| Affects | `ShariahVault.permittedAssets` (ETH), `ShariahScoreAggregator` index 0 (ETH_SPREAD, S1-H) |
| Related | SR-007 |

**Issue.** ETH is on the permitted-asset list and S1-H trades the USDC/ETH spread across chains. Whether ETH is a currency (thaman) or a commodity (sil'a) decides whether ETH_SPREAD is a permitted spot arbitrage or a deferred currency exchange (see SR-007). The permitted-asset list also carries ETH, and its staking-yield rationale has not been reviewed.

**Board question.** Rule on ETH's classification before S1-H goes live, and confirm whether ETH may remain on the permitted-asset list.

**Board decision / pronouncement hash:** none recorded
