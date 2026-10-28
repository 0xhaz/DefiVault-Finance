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

## SR-013 — Gold oracle stale-price fallback (PR1 implemented)

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-22 |
| Task | H (PR1) |
| Affects | `GoldAllocationAdapter.currentValue()`, `ShariahVault.maxDeposit/maxMint` |

**Issue.** When the Chainlink XAU/USD oracle is stale, `currentValue()` previously returned `totalDeployed` (cost basis). This overstates value when gold has fallen (unfair to redeemers), and understates when gold has risen (unfair to depositors).

**Implemented (PR1).** After every successful oracle read, `lastGoodPrice` is cached. When the oracle is not sane, `currentValue()` returns `min(lastGoodPrice, poolPrice if readable) × (1 - staleHaircutBps)`. Default haircut: 5%. Hard cap: 20%. Board-settable via 30-day timelock (`PARAM_STALE_HAIRCUT`). Cost basis is never used in valuation. `maxDeposit`/`maxMint` return 0 when oracle is insane — new deposits blocked; redemptions remain open.

**Board action required.** Default `staleHaircutBps = 500` (5%) is a reasonable engineering default. Board should confirm this is within approved parameters before live deploy.

---

## SR-014 — High-water mark and profit unlock (PR3 implemented)

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-22 |
| Task | H (PR3) |
| Affects | `TreasuryModule.calculateMusharakahSplitHWM`, `AutonomousVault.lockProfit`, `ShariahVault.claimMusharakahProfit` |

**Issue.** Two separate fairness risks: (a) after a vault loss, the manager could earn profit share on recovery before all depositors' losses are made whole (high-water mark); (b) a depositor could deposit just before a profit claim and redeem immediately after, extracting profit they did not earn (sandwich attack).

**Implemented (PR3.1 + PR3.2).** `TreasuryModule.calculateMusharakahSplitHWM(hwmDeficit)` zeroes `vaultShare` until recovery > `hwmDeficit`. `claimMusharakahProfit` updates `highWaterMark` and `hwmDeficit` before each claim. `AutonomousVault._currentLockedProfit()` linearly decays `lockedProfit` over `profitUnlockPeriod` (default 3 days, max 14 days); `totalAssets()` subtracts locked profit so a deposit-claim-redeem earns ~0. `claimMusharakahProfit` calls `_lockProfitInternal(depositorShare)` after each waterfall.

**Board action required.** Default `profitUnlockPeriod = 3 days`. Board to confirm this is acceptable. `calculateMusharakahSplitHWM` is a pure helper; existing `calculateMusharakahSplit` remains for backward compat.

---

## SR-015 — Cross-chain pending cap and shortfall accounting (PR3 implemented)

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-22 |
| Task | H (PR3) |
| Affects | `AutonomousVault.deployCrossChain`, `AutonomousVault.settleCrossChain` |

**Issue.** (a) No cap on how much vault capital could be in-flight cross-chain — a single deploy could send 100% of assets to a remote chain with no recovery guarantee. (b) `settleCrossChain` had no mechanism to handle bridge shortfalls (fees, slippage, loss); a returned amount less than sent would have been silently ignored.

**Implemented (PR3.3).** `maxPendingCrossChainBps` (default 2000 = 20%, max 5000) enforces a cap at deploy time, checked against pre-burn `totalAssets()`. `settleCrossChain(nonce, received)` signature updated with `received` param. Shortfall = `sent - received` is booked as an immediate NAV loss by decrementing `totalDeployed` by `sent` without adding back `received` (received tokens are already in vault balance from CCTP mint). `CrossChainSettled` event emits `(nonce, received, shortfall)`.

**Board action required.** Default cap 20% is a conservative engineering default. Board to confirm.

---

## SR-012 — Purification rate: global blended rate vs per-adapter taint ratio

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-22 |
| Task | G (G6) / H (PR2) |
| Affects | `PurificationEscrow.purificationBps`, `CharityModule`, profit waterfall |

**Governance fix (PR2).** `PurificationEscrow.setPurificationBps` (previously immediate, onlyOwner) replaced with `proposePurificationRate` → `confirmPurificationRate` pattern (30-day timelock, `onlyBoard`). `boardRole` mapping with `grantBoardRole`/`revokeBoardRole` by owner. Deployer is initial board member. This resolves the governance asymmetry with `charityBps`.

**Open architectural issue.** Task B's original spec called for a per-adapter `taintedRatioBps` — each adapter would report its own non-compliant income fraction, and the purification step would deduct only the tainted portion. The current implementation uses a single global `purificationBps` applied to all Musharakah profit regardless of source.

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

---

## SR-004 — Musharakah loss-sharing: HWM excess clarification (Task I)

*(Update to SR-004 above — additional finding from Task I code review.)*

**HWM excess split rule (confirmed in code).** `calculateMusharakahSplitHWM` computes:

```
afterRecovery = max(0, grossProfit − hwmDeficit)
surplus       = max(0, afterRecovery − hurdleAmount)
vaultShare    = surplus × musharakahShareBps / 10_000
depositorShare = grossProfit − vaultShare
```

The 4% hurdle is applied to `afterRecovery` (not the full gross), and the manager split runs only on `surplus = afterRecovery − hurdle`. This means:

- If `grossProfit < hwmDeficit`: `afterRecovery = 0`, `vaultShare = 0`. Depositors absorb the full gross as partial loss recovery.
- If `grossProfit > hwmDeficit` but `afterRecovery ≤ hurdle`: `surplus = 0`, `vaultShare = 0`. Hurdle is borne from the excess; no manager share.
- Only when `afterRecovery > hurdle` does the manager earn a share — and only on that final surplus.

**Board confirmation required.** The board must confirm this ordering is acceptable under Musharakah fiqh: specifically, whether the hurdle rate applies to the post-recovery excess (current implementation) or to the full gross profit. SR-004 original question (b) is partially answered by this implementation; the board must confirm it is correct.

---

## SR-016 — S2-H (PAXG) stale-price valuation and deposit pause (Task I, I2)

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-23 |
| Task | I (I2) |
| Affects | `GoldExchangeAdapter.currentValue()`, `GoldExchangeAdapter.isPriceSane()`, `ShariahVault.maxDeposit/maxMint` |

**Issue.** `GoldExchangeAdapter` (S2-H, PAXG) previously returned `totalDeployed` (cost basis) from `currentValue()`, overstating value when gold has fallen. Task I applies the same PR1 treatment as S6-H: `lastGoodPrice` cached at every swap execution; stale detection via `maxStalenessSecs` (default 1 day, max 7 days); stale `currentValue()` = `grossValue × (1 − staleHaircutBps)` (default 5%, cap 20%).

**Difference from S6-H (GoldAllocationAdapter).** S2-H has no external oracle — "staleness" is measured from the last executed atomic swap (deploy or recall), not from a Chainlink heartbeat. The board must confirm:

(a) Whether staleness-from-last-swap (default 1 day) is appropriate for S2-H, or whether a different threshold should apply to a pure DEX-price adapter.

(b) Whether `staleHaircutBps = 500` (5%) is conservative enough when the last PAXG/USDC price is known only from a DEX trade that may have been executed under atypical liquidity conditions.

(c) The `maxDeposit`/`maxMint` block now applies to BOTH gold adapters — S6-H oracle stale OR S2-H last-swap stale → deposits paused. The board must confirm this is the correct combined gate.

---

## SR-017 — settleCrossChain: caller-supplied `received` verification (Task I, I1)

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-23 |
| Task | I (I1) |
| Affects | `AutonomousVault.settleCrossChain`, `AutonomousVault.balanceBeforeDeploy` |

**Issue.** Before Task I, `settleCrossChain(nonce, received)` trusted the manager-supplied `received` parameter. Over-reporting would inflate NAV; under-reporting would book a phantom loss.

**Implemented (I1).** `deployCrossChain` now snapshots the vault's post-burn USDC balance in `balanceBeforeDeploy[nonce]`. When `settleCrossChain` is called, it computes `arrived = currentBalance − snapshotBalance` and reverts `ReceivedExceedsArrived(received, arrived)` if `received > arrived`. CCTP mints inbound USDC to the vault before the operator calls `settleCrossChain`, so the balance delta is the on-chain verifiable arrival amount.

**Residual risk.** The snapshot is taken at deploy time. Any unrelated USDC arriving at the vault between deploy and settle (e.g. from a direct transfer) increases `arrived` and thus loosens the bound. This is acceptable: it makes the guard less tight, not less safe — legitimate settles always pass. The guard's purpose is to prevent the manager from reporting more than what the chain has actually received.

**Board action required.** Board to confirm this residual risk is understood and the one-way guard (can never over-report, may under-report bound on rare concurrent arrivals) is acceptable.

---

## SR-018 — Single-source board role: registry as authority for CharityModule and PurificationEscrow (Task I, I4/I5)

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-23 |
| Task | I (I4, I5) |
| Affects | `CharityModule.boardRegistry`, `PurificationEscrow.boardRegistry`, `ShariahAdapterRegistry.isBoard()`, `ShariahAdapterRegistry` constructor |

**Issue.** Before Task I, `CharityModule` (wallet/rate changes) and `PurificationEscrow` (purification rate) each maintained a local `boardRole` mapping. This meant a board composition change in the registry did NOT automatically propagate to these contracts — the operator had to separately update each contract's local mapping, creating a window of divergence.

**Implemented (I4/I5).**
- `ShariahAdapterRegistry.isBoard(address)` view function added (returns `boardRole[account]`).
- `CharityModule` and `PurificationEscrow` constructors now accept `boardRegistry` (immutable). When set, `onlyBoard`/`onlyBoardOrOwner` checks `registry.isBoard(msg.sender)` instead of local mapping.
- `ShariahAdapterRegistry` constructor now accepts `(initialOwner, initialBoardMember)`. `initialOwner` does NOT automatically receive `boardRole`; only `initialBoardMember` does. On production: `initialBoardMember` must be the organisation's Safe multisig address.
- `DeployShariahV2.s.sol` reads `BOARD_MULTISIG` env var (falls back to deployer on testnet).

**Board action required.**
(a) Confirm the production `BOARD_MULTISIG` address to use as `initialBoardMember` in the registry constructor.
(b) Confirm that the deployer-as-owner-but-not-board separation is acceptable for testnet (documented risk: testnet board == deployer EOA).
(c) Confirm the asymmetric emergency power: owner can `emergencyRevokeBoardRole` (instant, no timelock); owner cannot grant board membership without the board itself proposing (30-day timelock).

---

## SR-019 — Atomic cross-chain settle: MessageTransmitter trust (Task J, J1)

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-23 |
| Task | J (J1) |
| Affects | `AutonomousVault.settleCrossChainWithMessage`, `IMessageTransmitterV2`, `CctpMessageDecoder` |

**Change.** The old snapshot-based `settleCrossChain(nonce, received)` is replaced by `settleCrossChainWithMessage(nonce, message, attestation)` which calls `MessageTransmitter.receiveMessage` atomically, measures the USDC balance delta, and verifies it against the message-encoded amount. The old `settleCrossChain(nonce, 0)` remains as a write-off-only path (`onlyOwner`, `received` must be 0).

**Residual risks.**
(a) The `CctpMessageDecoder` library hard-codes CCTP V2 message offsets. If Circle changes the message format in a future protocol version, decoding silently produces wrong values. Board to confirm the production Circle deployment uses the same V2 layout.
(b) `setMessageTransmitter` is `onlyOwner` (instant). An owner key compromise enables substitution of a malicious transmitter that mints arbitrary USDC to the vault. Board to confirm this is acceptable for testnet (no production funds) and to plan a timelock for mainnet.

**Board action required.** Confirm the CCTP V2 message layout assumption and the `setMessageTransmitter` key-management risk.

---

## SR-020 — Dust threshold for deposit pause: empty adapter does not block deposits (Task J, J2)

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-23 |
| Task | J (J2) |
| Affects | `ShariahVault._goldPriceInsane()`, `ShariahVault.dustThreshold`, `ShariahVault.setDustThreshold()` |

**Change.** `maxDeposit`/`maxMint` now block deposits only when an adapter is both stale AND holds more than `dustThreshold` USDC of value (default 1 USDC). An idle adapter with zero position never blocks deposits even if its last-swap timestamp is stale. `dustThreshold` is board-settable via `setDustThreshold()` (no timelock — owner-immediate).

**GoldExchangeAdapter oracle integration (J2).** `GoldExchangeAdapter.isPriceSane()` now checks the XAU/USD oracle's `updatedAt` age (when `goldOracle` is set) instead of last-swap age. A 3-day idle S2-H with a fresh oracle stays sane.

**Board action required.**
(a) Confirm the 1 USDC dust threshold is acceptable as the minimum position size that triggers deposit blocking.
(b) Confirm `setDustThreshold` may be owner-immediate (no timelock) — rationale: it only loosens deposit restrictions, never tightens them against depositors.
(c) Confirm S2-H's oracle-based staleness check (using the same XAU/USD feed as S6-H) is acceptable.

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

---

## SR-022 — Invariant suite: six protocol invariants now machine-verified (Task J, J4)

| Field | Value |
|---|---|
| Status | REVIEW |
| Raised | 2026-10-23 |
| Task | J (J4) |
| Affects | `AutonomousVault`, `ShariahVault`, `TreasuryModule`, `PurificationEscrow` |

**New invariant tests** (`contracts/test/invariant/VaultInvariant.t.sol`, 256 runs × depth 50):
1. `invariant_redeemNeverReverts` — any holder may always redeem up to `maxRedeem()` without revert.
2. `invariant_totalAssetsAccounting` — `totalAssets()` equals idle balance + `totalDeployed` minus locked profit (within 2 USDC rounding).
3. `invariant_goldCapNotExceeded` — combined gold value ≤ `MAX_GOLD_BPS` of `totalAssets()` at all times.
4. `invariant_sharePrice_monotone_across_users` — no depositor's pro-rata NAV increases because another user deposited or redeemed (beyond 2 USDC rounding).
5. `invariant_vaultShareZero_when_hwmDeficit` — manager earns zero vault share during any loss-recovery period.
6. `invariant_lockedProfitDecaysToZero` — locked profit reaches zero after `unlockedAt` passes.

**Board action required.** Confirm the above invariants accurately capture the Shariah depositor-fairness requirements. In particular, confirm invariant 4 (share-price monotonicity) reflects the board's understanding of how deposits and redemptions interact with NAV.


---

## SR-023 — goldCrossChainBlocked flag set on live deployment

**Status:** REVIEW  
**Raised by:** Fork verification of rehearsal step 5 (2026-10-28)  
**Severity:** LOW — operational, not a contract defect

The `AutonomousVault.goldCrossChainBlocked` flag is `true` on the live Arc Testnet deployment (`0xba094D5B01F4fd245EA345Be6B8ac833488c81B0`). This flag is set automatically by `_goldNonAtomicBlock()` when a cross-chain deploy would use a PAXG/gold position to source the USDC (non-atomic gold exchange risk). It prevents any cross-chain capital deployment until the owner calls `setGoldCrossChainBlocked(false)`.

**Board action required:**  
Confirm whether the board considers cross-chain deployment of USDC sourced from gold exchanges permissible. If yes, the owner may call `setGoldCrossChainBlocked(false)` before step 5 of the rehearsal. If no, the flag should remain set and CCTP cross-chain deployment should be limited to non-gold USDC positions only.

**Implication for mainnet:**  
On a mainnet deploy where gold adapters are active, `goldCrossChainBlocked` will be set whenever a gold position is open. The board must issue a ruling on whether cross-chain deployment is permitted while a gold position is held — otherwise step 5 (CCTP round trip) will be blocked in production.
