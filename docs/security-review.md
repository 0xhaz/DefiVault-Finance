# DeFiVault Finance — Security Review

**Date:** 2026-10-28 (initial review) · **Remediation update:** 2026-10-28  
**Scope:** All contracts in `contracts/` (Tasks A–L, including CharityModule `setEscrow` fix)  
**Target chain:** Arc Testnet / Arc Mainnet (chain ID 5042002 / 5042), USDC as native gas (18 dec gas, 6 dec ERC-20)  
**Methodology:** Rule-corpus scan (access control, CCTP, slippage, timelocks) + functional adversarial review (fund-locks, value extraction, NAV manipulation, ordering attacks). Re-reviewed after the fixes below.

> **This review is not a substitute for an independent professional audit before mainnet deployment.**

---

## Remediation Status

| ID | Severity | Title | Status |
|---|---|---|---|
| F-01 | Critical | Profit waterfall fee backing | **Fixed** |
| F-02 | High | CCTP settle not bound to the message | **Fixed (revised)** |
| F-03 | High | Zero min-outs on LP deploy/recall | **Fixed** |
| F-04 | High | CCTP outer message fields not validated | **Fixed** |
| F-05 | Medium | `setEscrow` re-settable | **Fixed** |
| F-06 | Medium | Testnet short timelock deployable on mainnet | **Fixed** |
| F-07 | Low | Zero address on messenger setters | **Fixed** |
| F-08 | Info | `setPool` had no timelock | **Fixed** |
| F-09 | Info | Arbitrum sequencer check | Not applicable (Arc target) |
| F-10 | Info | Thin XAUT/USDC pool liquidity | Accepted (oracle is the price source) |

**Test status after remediation:** 503 Foundry tests pass, including 8 of 8 invariants (256 runs, depth 50) and 86 new regression tests for the fixes.

---

## Fixed Findings

### F-01 — Critical: Profit waterfall fee accounting mismatch (fund-lock)

**Was:** `executeWaterfall` booked the manager's share in the treasury but left the tokens in the escrow, so later fee sweeps drew on depositor principal.  
**Fix:**
- `PurificationEscrow.executeWaterfall` now returns the manager's share (and any rounding dust) to the vault. The escrow ends every call with a zero balance, so pending fees are backed 1:1 at the vault.
- `ShariahVault` and `ConventionalVault` `sweepFeesToTreasury` revert `InsufficientFeeBalance` if the vault balance is below the amount.
- `ShariahVault.totalAssets()` already excluded pending fees. `ConventionalVault.totalAssets()` now does too, so redeeming shareholders cannot spend fee backing.
- `TreasuryModule`: the fee source (vault) can now settle its own `claimFees`, and an owner-approved `profitRecorder` (the escrow) can call `recordMusharakahProfit`. Before this, the escrow could not record profit in the vault's treasury and a vault-run sweep could not clear it.  
**Deployment action:** after `setPurificationEscrow`, the treasury owner must call `setProfitRecorder(escrow)`. The deploy and rehearsal scripts now do this.

### F-02 — High: CCTP settle bound to the wrong message (revised)

The first fix required the message header nonce to equal the outbound pending nonce. Re-review showed this is wrong for a real round trip: the return burn on the remote chain has its own nonce. The final design:
- The pending entry now records its destination domain. The return message's source domain must match it (`WrongSourceDomain`).
- Inbound messages are replay-protected by `(sourceDomain, headerNonce)` (`InboundAlreadyConsumed`). Consumption rolls back if the mint fails.
- `NonceMismatch` now only means the pending entry does not exist.

### F-03 — High: LP slippage protection

- `HalalLPAdapter` computes non-zero min amounts for mint and for liquidity removal.
- Minimums are priced from a pool TWAP, not `slot0`, so a same-transaction price move cannot lower them. Deploy and recall revert if spot deviates from the TWAP by more than `maxTwapDeviationTicks` (`SpotTwapDeviation`), or if the pool has no usable observations (`TwapUnavailable`).
- Settings, all changeable only through a 30-day propose/execute/cancel timelock:

| Setting | Default | Bound |
|---|---|---|
| `maxSlippageBps` | 100 | at most 500 |
| `twapWindow` | 1800 s | at least 300 s |
| `maxTwapDeviationTicks` | 100 | at most 500 |

- A second `deploy` now reverts `PositionAlreadyOpen`. Before, it overwrote the position NFT id and stranded the first position.

### F-04 — High: CCTP outer message validation

`settleCrossChainWithMessage` validates the header's destination domain (`WrongDestinationDomain`), destination caller, which must be `address(this)` or zero (`WrongDestinationCaller`), and recipient, which must be the configured TokenMessenger (`WrongMessageRecipient`). The local domain is read from the transmitter, with an owner-set fallback (`setLocalDomain`).

### F-05 — Medium
`CharityModule.setEscrow` is one-time (`EscrowAlreadySet`) and rejects the zero address.

### F-06 — Medium
`TestnetRegistryShortTimelock` reverts in its constructor and both testnet functions when `block.chainid == 5042`.

### F-07 — Low
`setTokenMessenger` and `setMessageTransmitter` revert `ZeroAddress` on zero input.

### F-08 — Informational
`GoldAllocationAdapter.setPool` now only proposes. `executePool` applies it after 30 days, and `cancelPool` withdraws it.

---

## Not Applicable / Accepted

- **F-09:** Only relevant on Arbitrum. Not applicable to Arc. Add the Chainlink sequencer uptime check before any L2 deployment.
- **F-10:** The XAUT/USDC Uniswap pool is an execution venue only. The Chainlink XAU/USD feed is the price source. Per-swap sizing relative to pool TVL remains an operator concern.

---

## Findings From Re-Review

The re-review of the fixed code surfaced issues in older code. None were introduced by the F-01 to F-08 fixes. Status as of the second audit round on the follow-up fixes:

| ID | Severity | Status | Issue |
|---|---|---|---|
| N-01 | Critical | **Fixed** | `claimMusharakahProfit` accepted any amount. It is now bounded by `realizedProfit()` (NAV above a principal checkpoint, `profitBase`). The checkpoint counts the locked depositor share, so distributed profit cannot be re-claimed when it unlocks, and withdrawals shrink it by shares burned over supply. `ShariahVault.lockProfit` is bounded the same way. |
| N-02 | Critical | **Fixed** | The executor called `adapter.deploy` itself and the `onlyVault` gold adapters rejected it. `deployCapitalAndExecute` funds and executes in one vault transaction and the Shariah executor tiers use it. Gold adapters now reject transfer-only funding (`UseAtomicDeploy`) so USDC cannot be stranded. |
| N-03 | Critical | **Fixed, fork-tested** | Verified on a fork of Arc Testnet against the real TokenMessengerV2, MessageTransmitterV2 and TokenMinterV2 (34 tests in `ForkCctpRealArc*.t.sol`, with a shim for Arc's native-coin precompiles on the fork). Not covered: live Circle attestations, the unfinalized-message path and hook data. The vault now uses the real CCTP V2 interface: 7-argument `depositForBurn` (no return value), the 148-byte `MessageV2` header with a `bytes32` nonce, and the `BurnMessageV2` body (amount at 68, `feeExecuted` at 164). Pending entries use vault-assigned position ids. Settlement checks source and destination domain, recipient, `destinationCaller == vault`, the registered remote TokenMessenger, mint recipient, replay, and the balance change against `amount − feeExecuted`. |
| N-04 | High | **Fixed** | Pool price math now reads the pool's token order and decimals and uses full-precision `mulDiv`. The constructor still takes one address as both pool and router, so a real deployment sets the real pool through the 30-day `proposePool` flow or needs a constructor change. |
| N-05 | High | **Fixed (mocks only)** | `HalalLPAdapter` now deploys two-sided: it swaps part of the USDC into the pair token through an immutable `swapRouter` (minimum output from the TWAP, never spot), mints with both tokens, swaps back on recall, and `currentValue()` is a TWAP mark-to-market that reverts when pricing is unavailable (the vault then blocks deposits and marks nothing for exits). 216 tests against mock routers and position managers; not tested against a real Uniswap pool or router, and no deploy script sets its router address. |
| N-06 | High | **Fixed for Shariah vaults** | `ShariahVault` tracks principal per adapter, retires it on `recallCapital` and `returnCapital` (all of it when the adapter reports zero value), and marks both gold adapters in `totalAssets()` in both directions. Unrealized gains are excluded from distributable profit. The base `AutonomousVault.recallCapital` and the conventional vault still retire proceeds, not principal, and keep the phantom-asset behavior; they are out of scope under the rule not to touch conventional vaults. |
| N-07 | High | **Fixed** | The waterfall now receives the high-water-mark deficit (`executeWaterfallHWM`), so the manager earns nothing during recovery. The remaining distortions (absolute HWM, deficit measured after the claim) were closed by N-21 (per-share high-water mark, deficit capped at the pre-claim checkpoint). |
| N-08 | High | **Fixed for Shariah vaults** | Cross-chain deploys now require a permitted asset and a recipient approved through a board-gated 30-day flow (`proposeRemoteRecipient` / `confirmRemoteRecipient`). `deployCrossChainForStrategy` takes a caller-supplied strategy index, so it is a guard for honest callers, not an authenticated identity. |
| N-09 | High | **Fixed (with limits)** | Both gold adapters now have a partial emergency exit: `proposeEmergencyExit(tokenAmount, minUsdcOut)` then `executeEmergencyExit()`, owner-only, gated by a default-disabled flag that needs the 30-day timelocked param change, with a hard floor of 20% of the cached-price value, a 1-hour delay, a 24-hour execution window and `cancelEmergencyExit()`. The one-call `emergencyExit` always reverts. After the sale the adapter calls `ShariahVault.retireGoldPrincipal` so the vault's `principalOf` and `totalDeployed` retire proportionally and unsold appreciation is not counted as realized profit. `GoldExchangeAdapter.setGoldOracle` is locked while emergency exits are enabled. Limits: the flag must be enabled 30 days before an outage, and a crash beyond 80% still blocks the exit. Earlier text: |
| N-09-prev | High | Superseded | A fresh oracle now sets the recall floor and the pool price never lowers it. During an oracle outage the floor is the last cached price less the stale haircut and a bounded, timelocked emergency slippage (default 10%, cap 25%). Still open: a decline beyond that bound blocks exits for the whole outage, and both adapters sell the whole position. A separately authorized emergency exit with an explicit minimum output and partial recall is not built. |
| N-10 | High | **Fixed** | Changing `profitUnlockPeriod` now checkpoints the remaining locked profit and restarts the schedule, and the lock math cannot underflow. |
| N-11 | High | **Fixed for Shariah vaults** | `claimMusharakahProfit` no longer locks the returned depositor share. It was already counted in NAV, so hiding it discounted entrants right after a claim. The base `AutonomousVault` lock and the conventional vault are unchanged. |
| N-12 | High | **Fixed** | `GoldExchangeAdapter.deploy` truncated `lastGoodPrice` to 0. Prices are in USDC (6 dec) per whole PAXG throughout. |
| N-13 | High | **Fixed** | An adapter unlinked from a gold slot is now marked retired and cannot be funded again. A gold adapter that was never linked to a slot can still be funded outside the cap (N-23). |
| N-14 | Medium | **By design** | The Shariah executor tiers always run locally. Gold winners with a destination revert (Task N1). |
| N-15 | Critical | **Fixed** | The unbounded external `lockProfit` is removed from the base vault. `ShariahVault.lockProfit` is bounded by realized profit and rejects zero. |
| N-16 | High | **Fixed** | Gold purchases used a minimum output of 1. They now derive the minimum from a fresh oracle price and revert `StaleGoldPrice` otherwise. `pokePrice` only accepts fresh observations and stores the oracle's own timestamp. |
| N-17 | High | **Fixed** | A third party could pre-submit a return message with an open `destinationCaller` and make the vault's own settle fail. Messages must now name the vault as destination caller, so remote strategies must burn with that value. |

Open: N-32 (known limitation), N-18 and N-28 (conventional vault, out of scope), and the design gaps listed under "Known gaps" below.

| ID | Severity | Status | Issue |
|---|---|---|---|
| N-18 | High | Open | `ConventionalVault.deployCapitalWithFeeAccrual` skips the pause check. Not changed, because conventional vaults are out of scope under the repository rules. |
| N-19 | High | **Fixed for claim-time profit** | Claims no longer lock the depositor share, so nothing from a claim is stranded after the last redemption. Profit locked manually through `lockProfit` can still be left behind if the last holder redeems while it is locked; a manager should not lock profit while exits are expected. |

| N-20 | High | **Fixed** | The 0.5% Wakala fee accrues only when capital is deployed, on current AUM over the whole interval since the last deployment. Deposits, withdrawals and claims do not accrue it, so new depositors can be charged for earlier periods and exiting holders skip fees they owe. |
| N-21 | High | **Fixed** | The high-water mark is an absolute asset amount. Withdrawals create a deficit that suppresses fees on real gains, and deposits can erase one. The deficit is also measured against NAV that already includes the claimed profit. Needs a per-share or cash-flow-adjusted HWM. |
| N-22 | High | **Fixed** | A small `claimMusharakahProfit` resets the checkpoint to the full post-claim NAV, so the unclaimed remainder never goes through purification, charity or the manager split. |
| N-23 | High | **Fixed** | A gold adapter that is screened but never linked to a gold slot can be funded outside the gold cap, the deposit gate and the NAV marking. Needs an enforced gold classification at approval. |

N-11 is fixed for Shariah vaults by removing the claim-time lock (Option A). Remaining trade-offs: yield still enters NAV instantly when it is recalled or returned, so a deposit just before that and a redeem just after can capture a slice. Only the manager's discretionary `lockProfit` guards against it. Streaming yield at recognition was considered and rejected for now (it keeps an entrant discount and makes exiting holders forfeit unvested profit, which needs Shariah sign-off).

### Findings from the latest review round (open)

| ID | Severity | Status | Finding |
|---|---|---|---|
| N-24 | High | **Fixed for Shariah vaults** | A deposit made while profit was locked lowered processed assets per share and could create a recovery deficit with no investment loss. With no claim-time lock, mint price equals the processed price. Regression: `test_N24_depositAfterClaim_createsNoDeficit`. |
| N-25 | High | **Fixed** | `_withdraw` now reduces `profitBase` by the share of supply burned, not by assets over `totalAssets()`. The old doc status was stale. Covered by the pro-rata withdraw tests. |
| N-26 | High | **Fixed** | Unused hurdle allowance now carries forward across partial claims (`hurdleStartTime` moves back, lookback rounded up), so splitting a claim never pays the manager more than one full claim (56 tests, fuzzed). |
| N-27 | High | **Fixed** | Non-gold adapters are marked down (never up) in NAV from a capped set of at most 10 funded adapters (5 since N-33). Reads are gas-capped (100,000; 150,000 since N-33) and fixed-size; a failed read counts as no loss but blocks deposits (`valuationHealthy()`), as does a loss above the dust threshold. Exits stay open at marked NAV. Broken gold and non-gold adapters can be recalled, written off and replaced. Remaining trust assumption: a screened adapter reports its own value, so an adapter that overstates it is not detected. |
| N-28 | High | Open | `ConventionalVault` still omits unbooked admin fees from share pricing and keeps phantom principal after a lossy recall. Left unchanged under the rule not to modify conventional vaults, apart from the pause check. |

Fixed in the same round: zero-value deposits or redemptions can no longer erase Wakala accrual (a fee that rounds to zero keeps its elapsed time).

| ID | Severity | Status | Finding |
|---|---|---|---|
| N-30 | High | **Fixed** | `ShariahVaultV2` runtime was 27,468 bytes, over the 24,576-byte limit Arc Testnet enforces. CCTP settlement, governance timelocks, registry timelock and gold accounting moved into four external linked libraries; runtime is now 23,677 bytes (899 B margin). ABI and behaviour unchanged, 987 Foundry tests pass. Redeployed in run 3. Margin is thin: further vault growth needs another split. |
| N-31 | High | **Fixed** | Deploy scripts left the treasury `feeSource` as the deployer, so Wakala accrual was skipped. `Rehearsal.s.sol` and `DeployShariahV2.s.sol` now call `setFeeSource(vault)`. `DeployShariahV2.s.sol` also now wires `charity.setEscrow(escrow)`, without which profit claims revert. |
| N-32 | Medium | Open (known limitation) | A deposit made while a large unprocessed profit exists AND an HWM deficit is open books its buy-in to that profit as processed capital, which lifts the processed per-share price and can erase the deficit. The reserved manager/charity cut then grows at holders' expense: worst case about 0.28% of holder value for one round trip at max rates and 3 years of hurdle with unclaimed yield larger than the vault (`test_knownLimit_N32_depositErasesDeficit_boundedLoss`). Crediting less processed capital on deposit was tried and charges late depositors twice (about 3 bps loss), so it was reverted. Needs a per-share cash-flow-adjusted checkpoint. |
| N-29 | Medium | **Fixed** | Exit before claim. Shares are priced net of the pending distribution cut (`pendingDistributionCut`), and every exit first settles the leaver's pro-rata share of realized profit through the real claim path (`exitSettle`, try/catch, distribution lock), with hurdle allowance and HWM deficit allocated by the departing fraction so stayers' price is unchanged within a few wei. Degraded mode: if the escrow, charity or treasury is broken, the exit still succeeds and the cut stays in the vault as ordinary profit (part then flows to depositors at the next claim). Original text: exit before claim. Unclaimed yield sits in NAV at full value, including the part that will go to purification, charity and the vault fee. A holder who redeems before a claim leaves the remaining holders to bear that cut. Fixing it needs the non-depositor portion accrued out of the share price as profit is recognised. Not caused by, and not changed by, the removal of the claim-time lock. |
| N-33 | High | **Fixed** (found and fixed 2026-10-31; fork test LP-2) | A cold read of `HalalLPAdapter.currentValue()` against the real Uniswap V3 USDC/EURC 0.05% pool on Arc mainnet costs about 111k gas (`observe()` about 59k over a 1000-slot buffer, `positions()` about 17k, two `balanceOf` about 12k), above the old fixed `ADAPTER_READ_GAS` of 100,000. In a real deposit or exit every read of a funded LP adapter would fail: deposits blocked, exits with no LP mark-down. The warm read (about 77.6k) is why mocks missed it. **Fix:** `ADAPTER_READ_GAS` 100k to 150k; the escrow waterfall preview keeps its own 100k cap (`ESCROW_PREVIEW_GAS`); `EXIT_SETTLE_GAS_PER_ADAPTER` 250k to 1.3M, because settlement re-reads each funded adapter 8 times (23 times per exit in total, measured from traces); `MAX_FUNDED_ADAPTERS` 10 to 5 so a worst-case exit fits Arc's 30M block gas limit (measured 25.3M at 140k per read, cut settled at the minimum non-reverting gas on both vault variants). Vault runtime size unchanged (24,317 B). Tests: `ForkHalalLPArcMainnet.t.sol` `test_N33_coldReadFitsVaultReadGasCap`; `TaskReviewR5Test.Measure` LP-weight (120k) and near-cap (140k) cases; a gold-slot NAV bound in `TaskN27ReviewTest` corrected to the measured 7 reads per `totalAssets()`. Remaining: the 23 redundant reads per exit are the root cost (a per-transaction value cache would cut exit gas sharply, but the vault has 259 B of margin); a real LP adapter exit costs about 6.1M gas, so wallets must not hardcode low limits; not yet measured with the full vault stack on the fork. |
| N-34 | Medium | **Accepted for V2** (found 2026-10-31, fork test N33-A; owner decision D-6, 2026-10-31: operational mitigation in the launch runbook, gate redesign deferred to V3 and raised with the auditors) | With a funded `HalalLPAdapter`, the deposit gate (`valuationHealthy()`: marked non-gold loss must not exceed `effectiveDustThreshold()`, default 1 USDC) closes almost immediately. On the Arc mainnet USDC/EURC pool, funding 5,000 USDC costs about 1.48 USDC in swap fees and impact, so deposits close as soon as the LP is funded, and normal impermanent loss keeps them closed. No funds are at risk: NAV marks the loss and exits stay open. Mitigation available today: the board raises the dust threshold toward its cap (0.5% of NAV) through the 30-day timelock **before** the LP is funded. The cap is re-checked at confirmation and NAV drifts down as Wakala accrues, so a proposal of exactly the cap reverts `DustThresholdAboveCap`; leave headroom (90% worked). With the cap, a 5,000 USDC LP in a 20k vault absorbed a 133-tick shock (33.9 USDC loss) with deposits open. Design question for the audit/board: a loss gate sized for gold dust is a poor fit for LP strategies, where small unrealized losses are normal. Tests: `ForkVaultLPArcMainnet.t.sol` `test_knownFinding_N34_lpEntryCostClosesDepositGateAtDefaultDust`, `test_N34_boardDustAtCap_reopensDeposits_coldTx`. |
| N-35 | Medium | **Fixed** (found and fixed 2026-10-31, Slither arbitrary-send-erc20) | `ShariahVault.returnCapital(strategy, amount)` (owner or manager) pulls with `safeTransferFrom(strategy, vault, amount)` for any address, not only funded adapters. Depositors normally leave an allowance to the vault, so the owner or manager can pull a depositor's wallet USDC into the vault; it becomes NAV for all holders and the victim gets nothing. This contradicts the stated trust model (owner cannot withdraw user funds). The production manager (`RiskTieredExecutor`) has no path to `returnCapital`, so the exposure is the owner multisig. **Fix:** `ShariahAccountingLogic.returnCapital` reverts `AdapterNotFunded(adapter)` unless the adapter holds booked principal; a funded adapter still returns principal plus profit in one call. Vault runtime unchanged (24,317 B). Tests: `StaticAnalysisN35Test.t.sol` (V1 and V2: owner and manager cannot pull a depositor allowance; principal plus profit return; partial return; no pull after full retirement). The conventional `AutonomousVault.returnCapital` keeps the pattern (out of scope). See `docs/static-analysis.md`. |
| N-36 | Low | **Accepted for V2** (known limitation, found 2026-10-31, coverage pass P-4; owner decision D-7, 2026-10-31: the mainnet deployment uses one aggregator for its single Conservative executor and enables only strategies inside mask 38) | `ShariahScoreAggregator.getWinningShariahStrategy()` returns one global winner (highest enabled, fresh score). `RiskTieredExecutor.executeWinner()` then reverts `StrategyNotAllowedForTier` when that winner is outside the tier's mask, instead of falling back to the best allowed strategy. With an aggregator shared across tiers, a high score for a strategy outside the Conservative mask (for example ETH_SPREAD) stalls the Conservative vault's allocation. No funds at risk (capital stays idle). Mitigations: one aggregator per tier, or only enable strategies the tier allows; a code fix would pass the mask to the aggregator. Test: `CoverageGapsP4Test.t.sol` `test_knownLimitation_N36_disallowedGlobalWinnerBlocksTier`. |

N-11, N-24 and N-25 are closed for Shariah vaults. The Shariah vault has no claim-time lock. The Foundry suite is 1794 tests, all passing. `ShariahVaultV2` runtime is 24,244 bytes of the 24,576 limit (332 bytes of margin).

### Known gaps (accepted or not yet addressed)

- **Manager-dependent exits.** Deployed capital is only recoverable when the manager (or owner) recalls it. `maxWithdraw` and `maxRedeem` reflect idle liquidity, and recall and return work while paused, but there is no permissionless withdrawal queue.
- **Concealed LP loss on exit.** When a `HalalLPAdapter` price is unreadable, deposits are blocked but exits are priced at unmarked NAV, so a hidden loss can pass to remaining holders.
- **Emergency exit lead time.** The emergency exit must be enabled 30 days before it is needed, and the 20% floor means a crash beyond 80% still blocks it.
- **Exit gas requirement.** An exit with realized profit reverts `InsufficientExitGas` below 2 x (700k + 1.3M per funded adapter) gas (1.4M with no adapters, 4M with one, 14.4M with five; per-adapter budget raised from 250k by N-33). This closes a live finding on Arc Testnet run 4: `eth_estimateGas` bisects to the lowest gas at which the transaction does not revert, and because a failed settlement is swallowed it picked a limit that skipped the leaver's cut. Since N-33 at most 5 non-gold adapters can be funded; with reads near the 150k cap the measured minimum exit gas is 25.3M, inside the 30M block limit, and the cut is settled at that minimum (`TaskReviewR5Test.Measure` `_runOne` tests).
- **Agent flow prerequisites (testnet).** `executeWinner` only works when the aggregator strategies are enabled (`ShariahScoreAggregator.setEnabled`, off by default and a board decision on a production chain), scores are written within the last 5 minutes by the oracle wallet (the agent server only simulates the on-chain write unless an oracle wallet is configured), the executor's `maxGasPrice` is above the chain gas price (tier defaults of 20/30 gwei are below typical Arc Testnet gas), and a strategy config exists for the winner (HALAL_LP and MURABAHA have none in the rehearsal stack, so they revert `StrategyDisabled` if they win). Gold deployments are clamped to the remaining 30%-of-NAV gold room.
- **Degraded exit mode.** If the escrow, charity or treasury is broken, exits still succeed but the leaver's share of the cut stays in the vault as ordinary profit; part flows to depositors at the next claim.
- **Adapter self-reporting.** A screened adapter reports its own value. Marks are downward-only and gold is oracle-priced, but an adapter that overstates its value is not detected.
- **Owner-controlled hurdle input.** `setHurdlePrincipal` can only increase the value while shares are outstanding; the owner remains a trusted role.
- **Rehearsal infrastructure is testnet-only.** The mock pool, oracle and tokens deployed by `Rehearsal.s.sol` are publicly manipulable, the PAXG spread adapter's router mock has no PAXG inventory, and no script deploys `HalalLPAdapter`.
- **Mainnet readiness.** Not ready. Mainnet preparation material exists (`docs/mainnet-deploy.md`, `docs/mainnet-config.md`, `docs/audit-handoff.md`, `contracts/script/DeployMainnet.s.sol`) but the independent audit, the Shariah board rulings, real Arc mainnet gold dependencies and Arc's mainnet contract size limit are all unconfirmed.
- **Vault size margin.** Any further growth in `ShariahVaultV2` needs another split into the linked libraries.
- **Review coverage.** The last changes (oracle lock while emergency exits are enabled, rehearsal script edits) have not been through a second review pass, and this review is internal. It is not a substitute for an independent audit before any mainnet use.

---

## Arc-Specific Notes

- **USDC dual view.** Gas uses 18 decimals and the ERC-20 uses 6. The vault accounts only in the ERC-20 view. Invariant 3 guards against mixing `address(this).balance` with `balanceOf`.
- **CCTP V2 `feeExecuted`.** Task L1 reads it from body offset 164 (offset 132 is `maxFee`). This is in `AutonomousVault.sol` and all test message builders.
- **Cross-chain NAV.** N-03 is fixed in code. The remaining exposure is the missing fork test against the real Arc contracts, the pending-cap invariant (Invariant 8), and N-06.

## Deployed Addresses Reviewed (Arc Testnet Run-2)

These deployments predate the fixes and run the old bytecode. Redeploy before relying on any of the fixes.

| Contract | Address |
|---|---|
| ShariahVaultV2 | `0xba094D5B01F4fd245EA345Be6B8ac833488c81B0` |
| PurificationEscrow | `0xcC58b11c3Cd251a44989fEf1f05BdcB0e16375ff` |
| CharityModule | `0x1D05a0010C78B984b0De2735A6E868E9c9f5d99F` |
| TreasuryModule | `0xF5B550B87476a4359f1307AeFC425cCC6E2530f5` |

---

*This review is advisory. An independent professional audit is required before any mainnet deployment.*
