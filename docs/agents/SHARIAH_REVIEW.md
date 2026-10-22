# SHARIAH_REVIEW.md

This file records every item that requires a Shariah board ruling before the corresponding
code or configuration goes live. No item listed here may be deployed or used in production
until a board pronouncement is recorded and the status updated to APPROVED or REJECTED.

Agent role boundary: you are an engineer, not a Shariah authority.
You implement flags and mechanisms. You never declare an adapter "halal" or "certified".

---

## Status key

| Status | Meaning |
|---|---|
| REVIEW | Pending board ruling — code may exist but feature is blocked |
| APPROVED | Board pronounced in favour — record pronouncement reference |
| REJECTED | Board ruled against — record basis |

---

## SR-001 — OUSG / BUIDL: US Treasury-backed RWA tokens

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-21 |
| Task | A |
| Affects | `RwaYieldAdapter`, `ShariahScoreAggregator` index 4, `ShariahVault.permittedAssets` |

**Issue.** OUSG (Ondo Finance) and BUIDL (BlackRock) are tokenised wrappers of US Treasury
bills. Their yield is interest income from a sovereign debt instrument. Under SC Malaysia
Shariah methodology (SC-SAC resolutions, 288th/296th meetings) this constitutes riba.
The `non_compliant_income_ratio` for these funds is effectively 1.0 — far above the 5% cap.
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

---

## SR-002 — Charity contribution rate (2.5%)

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-21 |
| Task | B |
| Affects | `CharityModule.charityBps` (default 250 = 2.5%) |

**Issue.** The 2.5% deduction from Musharakah profit is labelled "charitable contribution
(sadaqah)". This rate was chosen to mirror the nisab percentage used in Zakat calculations,
but it is not derived from any fiqh principle for sadaqah. The board must confirm:
(a) the rate is appropriate for a voluntary charitable contribution; and
(b) the deduction is from gross Musharakah profit (before the Musharakah split), not from
the depositor's share only.

---

## SR-003 — Charity wallet designation

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-21 |
| Task | B |
| Affects | `CharityModule.zakatWallet` / `charityWallet` |

**Issue.** The wallet that receives the charitable contribution must be a recognised charitable
organisation or waqf institution. The board must approve the recipient address and any future
changes (a 30-day timelock is enforced in code, but the timelock alone does not constitute
board approval of the recipient).

---

## SR-004 — Musharakah loss-sharing: manager share in loss periods

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-21 |
| Task | B |
| Affects | `ShariahVault.claimMusharakahProfit`, `TreasuryModule.calculateMusharakahSplit` |

**Issue.** Classical Musharakah requires losses to be borne pro-rata to capital contribution.
The current implementation does not auto-deduct from the manager share in a loss period —
`claimMusharakahProfit` is only callable by the manager/owner, who will only call it when
profit exists. The hurdle reset logic (`hurdlePrincipal = totalAssets()` after a profit claim)
means a recovery from an earlier loss is treated as fresh profit, potentially allowing the
manager to share in a recovery that the depositors bore entirely as a loss.

**Code finding.** The board must confirm: (a) whether the manager share is zero in any period
where `totalAssets() < hurdlePrincipal`; (b) whether the hurdle-reset-on-claim approach is
acceptable or whether a cumulative loss carry-forward is required.

---

## SR-005 — GoldExchangeAdapter: atomic swap satisfying yad bi yad

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-21 |
| Task | C |
| Affects | `GoldExchangeAdapter`, `ShariahVault.goldExchangeAdapter` |

**Issue.** AAOIFI SS 57 and classical fiqh require gold-for-currency exchanges to be
simultaneous (yad bi yad — hand to hand). The `GoldExchangeAdapter` executes a single
Uniswap V3 `exactInputSingle` call, completing USDC→PAXG in one transaction. The board
must confirm that:
(a) a single EVM transaction satisfies the simultaneity requirement;
(b) PAXG (PAX Gold, 1:1 physically allocated gold in Brinks vaults) is an acceptable
    gold instrument — specifically that the allocated-gold status is continuously verifiable
    and that the token is redeemable for allocated bars.

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
    same legal backing as mainnet PAXG — Paxos's cross-chain bridging terms apply.
(c) If PAXG is not available on Arc Testnet, an alternative allocated-gold token must be
    identified and board-approved before the strategy goes live.

---

## SR-007 — ETH_SPREAD: deferred currency exchange question

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-21 |
| Task | C |
| Affects | `server/shariah-strategies.ts` scoreEthSpread(), `ShariahScoreAggregator` index 0 |

**Issue.** The ETH_SPREAD strategy routes USDC from Arc to another chain (Arbitrum, Base, OP)
via CCTP, executes a swap on arrival, and bridges back. This is a multi-step cross-chain flow
with a temporal gap between USDC leaving the vault and ETH being received.

If the board classifies ETH as a currency (thaman), this gap would constitute a deferred
currency-for-currency exchange (prohibited under riba al-nasi'a). If ETH is classified as
a commodity (sil'a), spot arbitrage is permissible.

**Recommendation.** Apply the same atomic-only rule used for GOLD_SPREAD (Task C) until the
board issues a ruling on ETH's classification. The code currently does NOT enforce this for
ETH_SPREAD. A guard equivalent to `NonAtomicGoldExchange` should be added once a ruling is
obtained.

---

## SR-008 — XAUT (Tether Gold): certificate of Amanah Advisors certification and qabd hukmi

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-22 |
| Task | F |
| Affects | `GoldAllocationAdapter`, `ShariahVault.goldAllocationAdapter`, `ShariahScoreAggregator` index 5 |

**Issue.** XAUT (Tether Gold) represents 1 fine troy oz of gold allocated on the London Bullion Market and stored in third-party Swiss vaults. Unlike PAXG (Paxos, directly allocated serial-numbered bars), XAUT is issued by Tether Limited with looser allocated-storage documentation.

Before `GoldAllocationAdapter` can be used in production:

(a) The board must review Tether Gold's latest custody terms, vault receipts, and any available Shariah certification. Amanah Advisors has reviewed gold-backed tokens; the board must confirm whether XAUT is covered by a current fatwa and whether the certification has expired.

(b) The yad bi yad requirement (AAOIFI SS 57): the adapter executes a single `exactInputSingle` Uniswap V3 call completing the USDC→XAUT exchange in one EVM transaction. The board must confirm this satisfies simultaneity — same ruling question as SR-005 for PAXG, applied to XAUT.

(c) Qabd hukmi (constructive possession): the board must confirm that receiving XAUT tokens in the vault's account constitutes valid qabd hukmi of the underlying gold, even though the physical gold never transfers custody to the vault operator.

**Code action taken (pending ruling).**
- `shariahCertified[5]` defaults to `false` in `ShariahScoreAggregator`.
- `GoldAllocationAdapter.protocolName()` references `SR-008`.
- Testnet uses `MockXAUT` — no live XAUT interaction until SR-008 is resolved.

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

(c) That the combined-cap calculation (sum of `goldSpreadAdapter.currentValue()` + `goldAllocationAdapter.currentValue()`) correctly represents the true gold exposure at all times, including during oracle staleness periods (the adapter falls back to `totalDeployed` when oracle is stale — the board must confirm this fallback is conservative enough).

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

---

## SR-G6 — Purification rate: global blended rate vs per-adapter taint ratio

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-22 |
| Task | G (G6) |
| Affects | `PurificationEscrow.purificationBps`, `CharityModule`, profit waterfall |

**Issue.** Task B's original spec called for a per-adapter `taintedRatioBps` — each adapter would report its own non-compliant income fraction, and the purification step would deduct only the tainted portion. The current implementation uses a single global `purificationBps` applied to all Musharakah profit regardless of source.

The board must confirm whether a single blended purification rate is acceptable, or whether the vault must track per-adapter taint and apply individualized rates. The implications are:

(a) **If blended rate is acceptable:** The current implementation is sufficient. The board sets `purificationBps` to a conservative rate that covers any plausible taint from the strategy mix (e.g., 0–2% for swap-fee strategies, 0% for atomic gold swaps). The rate must be explicitly reviewed at every strategy configuration change.

(b) **If per-adapter rates are required:** `PurificationEscrow.executeWaterfall` must accept an array of `(adapterAddress, taintedRatioBps, grossProfit)` tuples. Each strategy adapter must implement a `reportedTaintRatio()` view function. This is a significant architecture change that would also require updates to `ShariahVault.claimMusharakahProfit`.

**Current code action (pending ruling):** Global `purificationBps` defaulting to 0. No USDC is routed to purification until the board sets a rate AND SR-002 is resolved. `CharityTracker.tsx` tracks charity (sadaqah) and purification as separate line items.

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

(a) Whether providing liquidity to a USDC/XAUT pool satisfies the Musharakah requirement for S3-H — i.e., that fee income from a gold-stablecoin pool is permissible and does not constitute riba or a deferred currency-for-currency exchange.

(b) If USDC/XAUT LP is permissible, whether it is subject to the combined 30% gold cap (SR-009) or is treated as fee income (USDC) only.

(c) The current code does NOT route any LP capital to USDC/XAUT pools. This ruling is required only before such a pool is added to the strategy's approved pool list.
