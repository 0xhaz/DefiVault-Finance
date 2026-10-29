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
| N-03 | Critical | **Fixed in code, fork test pending** | The vault now uses the real CCTP V2 interface: 7-argument `depositForBurn` (no return value), the 148-byte `MessageV2` header with a `bytes32` nonce, and the `BurnMessageV2` body (amount at 68, `feeExecuted` at 164). Pending entries use vault-assigned position ids. Settlement checks source and destination domain, recipient, `destinationCaller == vault`, the registered remote TokenMessenger, mint recipient, replay, and the balance change against `amount − feeExecuted`. It has only run against mocks. A fork test against the real Arc MessageTransmitterV2 is still required. |
| N-04 | High | **Fixed** | Pool price math now reads the pool's token order and decimals and uses full-precision `mulDiv`. The constructor still takes one address as both pool and router, so a real deployment sets the real pool through the 30-day `proposePool` flow or needs a constructor change. |
| N-05 | High | Open | `HalalLPAdapter.deploy` supplies only USDC across a near-full-range position, which a real V3 pool needs both tokens for. |
| N-06 | High | **Fixed for Shariah vaults** | `ShariahVault` tracks principal per adapter, retires it on `recallCapital` and `returnCapital` (all of it when the adapter reports zero value), and marks both gold adapters in `totalAssets()` in both directions. Unrealized gains are excluded from distributable profit. The base `AutonomousVault.recallCapital` and the conventional vault still retire proceeds, not principal, and keep the phantom-asset behavior; they are out of scope under the rule not to touch conventional vaults. |
| N-07 | High | **Fixed** | The waterfall now receives the high-water-mark deficit (`executeWaterfallHWM`), so the manager earns nothing during recovery. Still open: the HWM is an absolute asset amount that deposits and withdrawals distort (N-21), and the deficit is measured after the claimed profit is already in NAV. |
| N-08 | High | **Fixed for Shariah vaults** | Cross-chain deploys now require a permitted asset and a recipient approved through a board-gated 30-day flow (`proposeRemoteRecipient` / `confirmRemoteRecipient`). `deployCrossChainForStrategy` takes a caller-supplied strategy index, so it is a guard for honest callers, not an authenticated identity. |
| N-09 | High | **Partly fixed** | A fresh oracle now sets the recall floor and the pool price never lowers it. During an oracle outage the floor is the last cached price less the stale haircut and a bounded, timelocked emergency slippage (default 10%, cap 25%). Still open: a decline beyond that bound blocks exits for the whole outage, and both adapters sell the whole position. A separately authorized emergency exit with an explicit minimum output and partial recall is not built. |
| N-10 | High | **Fixed** | Changing `profitUnlockPeriod` now checkpoints the remaining locked profit and restarts the schedule, and the lock math cannot underflow. |
| N-11 | High | **Fixed for Shariah vaults** | `claimMusharakahProfit` no longer locks the returned depositor share. It was already counted in NAV, so hiding it discounted entrants right after a claim. The base `AutonomousVault` lock and the conventional vault are unchanged. |
| N-12 | High | **Fixed** | `GoldExchangeAdapter.deploy` truncated `lastGoodPrice` to 0. Prices are in USDC (6 dec) per whole PAXG throughout. |
| N-13 | High | **Fixed** | An adapter unlinked from a gold slot is now marked retired and cannot be funded again. A gold adapter that was never linked to a slot can still be funded outside the cap (N-23). |
| N-14 | Medium | **By design** | The Shariah executor tiers always run locally. Gold winners with a destination revert (Task N1). |
| N-15 | Critical | **Fixed** | The unbounded external `lockProfit` is removed from the base vault. `ShariahVault.lockProfit` is bounded by realized profit and rejects zero. |
| N-16 | High | **Fixed** | Gold purchases used a minimum output of 1. They now derive the minimum from a fresh oracle price and revert `StaleGoldPrice` otherwise. `pokePrice` only accepts fresh observations and stores the oracle's own timestamp. |
| N-17 | High | **Fixed** | A third party could pre-submit a return message with an open `destinationCaller` and make the vault's own settle fail. Messages must now name the vault as destination caller, so remote strategies must burn with that value. |

Open: N-05, the partial remainders of N-07, N-09 and N-13, and the items below.

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
| N-26 | High | Open | Each partial claim resets the hurdle start and principal and discards the unused hurdle allowance, so split claims can pay the manager more than one full claim when a hurdle rate applies. |
| N-27 | High | Open | Only the two gold adapters are marked to market in NAV. Losses on other strategies reach the share price only on recall or write-off. |
| N-28 | High | Open | `ConventionalVault` still omits unbooked admin fees from share pricing and keeps phantom principal after a lossy recall. Left unchanged under the rule not to modify conventional vaults, apart from the pause check. |

Fixed in the same round: zero-value deposits or redemptions can no longer erase Wakala accrual (a fee that rounds to zero keeps its elapsed time).

| ID | Severity | Status | Finding |
|---|---|---|---|
| N-30 | High | Open (deploy blocker) | `ShariahVaultV2` runtime is 27,468 bytes, 2,892 over the 24,576-byte limit. Arc Testnet enforces it (a 30,000-byte test deploy reverts with `CreateContractSizeLimit`), so the current code cannot be deployed. Lowering optimizer runs to 1 only reaches 26,890. The deployed Run-2 vault predates the Task M/N growth. Needs a size refactor (move cross-chain/CCTP settlement or other heavy logic into a library or companion contract). |
| N-29 | Medium | Open | Exit before claim. Unclaimed yield sits in NAV at full value, including the part that will go to purification, charity and the vault fee. A holder who redeems before a claim leaves the remaining holders to bear that cut. Fixing it needs the non-depositor portion accrued out of the share price as profit is recognised. Not caused by, and not changed by, the removal of the claim-time lock. |

N-11, N-24 and N-25 are closed for Shariah vaults. The Shariah vault now has no claim-time lock; the 983-test Foundry suite passes with the lock-dependent tests rewritten. Redeploy before relying on this: deployed vaults run the old bytecode.

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
