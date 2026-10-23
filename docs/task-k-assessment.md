# Task K — Assessment Report

Generated: 2026-10-23  
Checked against: current sandbox HEAD

---

## Summary

| PR | Status | Ready to start? |
|---|---|---|
| PR1 — K1 CCTP V2 fee handling | **Changes needed** | Yes |
| PR1 — K2 mandatory goldOracle | **Changes needed** | Yes |
| PR2 — Invariant suite strengthening | **Changes needed** | Yes |
| PR3 — Docs/README in sync | **Changes needed** | Yes |
| PR4 — Testnet rehearsal | **Blocked** (PRs 1–3 must pass first per task spec) | No |

---

## K1 — CCTP V2 fees vs `MessageAmountMismatch`

### Current state

`settleCrossChainWithMessage` in `AutonomousVault.sol` (lines 294–318) decodes
`msgAmount` from the CCTP burn message body and then asserts:

```solidity
if (msgAmount != received) revert MessageAmountMismatch(msgAmount, received);
```

`received` is the balance delta after `receiveMessage`. In CCTP V2, for a **Fast Transfer**
the minted amount is `amount − feeExecuted`, not `amount`. So `msgAmount` (the amount field
from the burn message = the original burn amount) will be larger than `received` (the net
mint), causing `MessageAmountMismatch` to revert on every fee-charged settle. Capital is
stuck until written off via the owner-only `settleCrossChain(nonce, 0)` path.

Additionally, `feeExecuted` should be booked as a known cost (not just a silent NAV loss).

### What needs to change

1. **Decode `feeExecuted` from the CCTP V2 burn message body.**  
   The CCTP V2 BurnMessage body layout extends past byte 132. The `feeExecuted` field
   is a `uint256` at body offset 132 (bytes 116+132 … 116+164 of the outer message).
   Add a `decodeFee` function to `CctpMessageDecoder`.

2. **Update the mismatch check:**
   ```solidity
   uint256 expectedReceived = msgAmount - feeExecuted;
   if (expectedReceived != received) revert MessageAmountMismatch(expectedReceived, received);
   ```

3. **Pass `feeExecuted` to `_doSettle`** and emit it in `CrossChainSettled` as a new
   `feeCharged` field (or a separate `CrossChainFeeCharged` event).

4. **`_doSettle` adjustment:** the shortfall should be `sent - received - feeExecuted`
   only if `feeExecuted` should be carved out of the shortfall. More precisely:
   `received = msgAmount - feeExecuted`, so the shortfall relative to `sent` is still
   `sent - received`. `feeExecuted` is *part of* the shortfall (a known cost), so
   emitting it separately lets the manager distinguish protocol fees from strategy losses.

5. **Tests required:**
   - `settle with feeExecuted == 0`: should behave identically to the existing test.
   - `settle with feeExecuted > 0`: `received = amount − fee`, `_doSettle` is called with
     the actual delta, no `MessageAmountMismatch`, NAV drops by exactly fee + any strategy
     shortfall.
   - Both in `TaskITest.I1.t.sol` (already covers J1; add two cases alongside the existing five).

### Verdict

**K1 needs code changes and two new tests.** The current check is broken for any non-zero
CCTP V2 fee.

---

## K2 — Make the S2-H oracle mandatory

### Current state

`GoldExchangeAdapter.sol` (lines 107–124):

- `goldOracle` is a mutable, optional `IAggregatorV3` field, default `address(0)`.
- `isPriceSane()` (lines 266–283): when `goldOracle == address(0)` it falls back to
  last-swap age.
- Constructor (lines 109–125): no check that `goldOracle` is non-zero.

For a Shariah deploy this is a problem: J2 spec says "require non-zero `goldOracle` in the
`GoldExchangeAdapter` constructor" and "remove the last-swap fallback".

### What needs to change

1. **Add `address goldOracle_` to the constructor** (7th parameter).  
   `require(goldOracle_ != address(0), "GoldExchangeAdapter: goldOracle required");`  
   Assign `goldOracle = IAggregatorV3(goldOracle_)`.

2. **Remove the fallback branch in `isPriceSane()`:**
   The last three lines (the `// Fallback: last-swap age.` block) should be deleted or
   replaced with `return false;` — if the oracle call succeeds, use it; if not, return false.

3. **`pokePrice()` already no-ops when oracle is zero** — once the constructor enforces
   non-zero, this guard is still harmless but can be kept.

4. **Update all test files** that construct `GoldExchangeAdapter` without `goldOracle_`:
   - `VaultInvariant.Base.t.sol` (line 172)
   - `GoldExchangeAdapterTest.t.sol`
   - `TaskITest.I2.t.sol`
   - `TaskHTest.t.sol` (any construction of the adapter)
   - `FuzzGoldExchangeAdapter.t.sol`
   All must pass a `MockXauUsdAggregator` address as the seventh arg.

5. **Adapter table row in README:** change the staleness description from
   `stale detection: last-swap age > maxStalenessSecs (1 day default) → isPriceSane() false`
   to `stale detection: XAU/USD oracle heartbeat age > maxStalenessSecs; oracle is required at construction`.

### Verdict

**K2 needs code changes in GoldExchangeAdapter and updates to all construction sites in tests.**

---

## PR2 — Strengthen the invariant suite

### Current state

The handler (`VaultInvariant.Handler.t.sol`) has 11 actions:
deposit, redeem, deployToSpread, deployToAllocation, recallFromSpread, recallFromAllocation,
claimProfit, warpTime, moveOraclePrice, makeOracleStale, refreshOracle.

**Missing actions:**
- No cross-chain settle (with shortfall or with fee)
- No write-off action
- No loss-making recall (where the adapter returns less than deployed)

**Invariant 4 (`invariant_sharePrice_monotone_across_users`):**  
This invariant currently asserts that a user's ratio does NOT increase, which prevents the
handler from producing NAV losses. But the task spec says: share price MUST be able to fall.
The invariant should instead assert: **no user's share value changes because another user
deposits or redeems** (beyond rounding). Price-driven changes (gold drop, stale haircut,
cross-chain shortfall) must be allowed.

**Missing invariant:**
`totalPendingCrossChain == Σ pendingCrossChain[all open nonces]` and the cross-chain cap
holds after every `deployCrossChain`.

### What needs to change

1. **Handler: add cross-chain actions** (requires a mock CCTP messenger + transmitter in
   the base setup):
   - `deployCrossChain(uint96 amount, uint8 destDomain)` — records the nonce.
   - `settleCrossChainWithFee(uint96 feeBps)` — settles with a partial return.
   - `settleCrossChainWithShortfall(uint96 returnBps)` — settles with strategy loss.
   - `writeOff()` — settles nonce at 0 (owner-only path).

2. **Handler: add loss-making recall** — mock router returns less than deposited USDC;
   recallFromSpread or recallFromAllocation at a loss.

3. **Replace Invariant 4** — keep the cross-multiplied ratio check but reframe it:
   the share ratio for actor A must not INCREASE due to deposits/redeems by other actors
   (B, C). It is allowed to decrease for any actor due to NAV losses. The snapshot logic in
   the handler should record ratios only when the current actor is NOT the one who just acted.

4. **Add Invariant 7** — `totalPendingCrossChain` consistency:  
   Since the test cannot enumerate all open nonces easily (no getter), implement via ghost
   tracking in the handler:
   ```
   ghost: openNonces[] (push on deployCrossChain, pop on settle/writeOff)
   ghost: ghostPendingTotal (running sum)
   invariant: vault.totalPendingCrossChain == ghostPendingTotal
   invariant: ghostPendingTotal <= vault.totalAssets() * vault.maxPendingCrossChainBps() / 10_000 (+ 1 rounding)
   ```

5. **Report call counts** — `forge test -vv` will print summary; no code change needed.
   The handler's `callCount` field already tracks this. In the PR description, paste
   `forge test --match-path 'contracts/test/invariant/*' --invariant-runs 512 --invariant-depth 50 -vv` output.

### Verdict

**PR2 needs handler additions, new mock CCTP helpers in Base, and a revised Invariant 4 + new Invariant 7.**

---

## PR3 — Docs in sync

### Items to fix in README.md

All references are confirmed stale by reading the current source code.

1. **Key functions block (AutonomousVault section, line ~302–305):**  
   Still shows `settleCrossChain(nonce, received)` as a regular function.  
   Fix: rename to `settleCrossChainWithMessage(nonce, message, attestation)` as the primary
   path; add `settleCrossChain(nonce, 0)` as the owner-only write-off with `received MUST be 0`.

2. **Class diagram (AutonomousVault node, line ~164):**  
   `+settleCrossChain(nonce, received) — books shortfall` is stale.  
   Fix: `+settleCrossChainWithMessage(nonce, message, attestation) — atomic CCTP V2 settle`  
   and `+settleCrossChain(nonce, 0) — owner-only write-off; received must be 0`.

3. **Cross-chain Flow diagram (line ~571–577):**  
   `Owner->>Vault: settleCrossChain(nonce, received)` is the old owner-supplied settle.  
   Fix the sequence diagram to show:
   - Agent polls for CCTP attestation (already there)
   - Agent calls `settleCrossChainWithMessage(nonce, message, attestation)` — atomic CCTP V2 mint
   - The write-off path: `Owner->>Vault: settleCrossChain(nonce, 0)` only when USDC is unrecoverable.

4. **ShariahVault text (line ~320):**  
   `maxDeposit`/`maxMint` description says "when `goldAllocationAdapter.isPriceSane()` is false"
   but omits the `dustThreshold` dust rule (J2).  
   Fix: "… when a gold adapter is stale AND its `currentValue() > dustThreshold` (default 1 USDC).
   An adapter with no open position never blocks deposits even when the oracle is stale."

5. **Security Model table "Stale oracle deposit block" row (line ~727):**  
   Similarly omits the dust rule: `return 0 when goldAllocationAdapter.isPriceSane() is false`.  
   Fix to include: "only when `currentValue() > dustThreshold`; empty adapters never block deposits".

6. **CharityModule docs (line ~332):**  
   "When `boardRegistry` is set … the owner alone cannot propose".  
   The code (CharityModule.sol line 122) is `modifier onlyBoardOrOwner()` with a comment
   "Rename note: called onlyBoardOrOwner for backward-compat; effectively onlyBoard because
   boardRegistry is required."  
   K3 asks: if the owner can no longer act alone, rename the modifier in source to `onlyBoard`.
   The current source retains the name AND still allows the owner (when also on the board).
   Decision needed:
   - **Option A (minimal):** Update the README text to say the modifier is named `onlyBoardOrOwner`
     but the registry is always required, so in practice only board members (who may also be
     the owner) can call it.
   - **Option B (full fix per K3):** Rename the modifier in `CharityModule.sol` (and
     `PurificationEscrow.sol`) to `onlyBoard`, update the README, update test references.
   The task says "Rename the modifier to `onlyBoard` if the owner can no longer act alone."
   The current code does allow a non-board owner to call (line 124 `bool isOwner_`), so the
   condition is not yet met. Either remove the owner-only path first (making the rename
   correct), or document that the modifier name is intentionally kept for the case where the
   deployer is both owner and a board member.
   **Recommendation:** PR3 should update the README to accurately describe the current
   `onlyBoardOrOwner` semantics (owner can call only if also a board member in production;
   the deployer convenience path is noted). The modifier rename is a code change that belongs
   in a separate task.

### Verdict

**PR3 needs README edits at items 1–5 and a clarifying note for item 6.** No contract code
changes are required for PR3 (item 6 is a doc clarification, not a rename).

---

## PR4 — Testnet rehearsal

**Status: blocked on PRs 1–3.** The task spec states "PRs 1–3 merged with tests green
(forge test --fuzz-runs 512, invariant suite, bun)" before rehearsal begins.

Additionally, `script/Rehearsal.s.sol` and `docs/rehearsal.md` do not exist yet; the deploy
script (`DeployShariahV2.s.sol`) and the CCTP MessageTransmitter address on Arc Testnet
need to be verified before the script is written.

**Pre-conditions for PR4:**
1. K1 fix merged + `TaskITest.I1.t.sol` extended.
2. K2 fix merged + all construction sites updated + adapter table row updated.
3. PR2 invariants green at 512 runs × depth 50 with the loss and cross-chain actions.
4. PR3 README edits merged.
5. Arc Testnet CCTP MessageTransmitterV2 address confirmed (the README lists TokenMessengerV2
   at `0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA`; MessageTransmitterV2 address is not
   listed and must be looked up or confirmed from Circle docs before Rehearsal.s.sol is written).

---

## Test count implication

399 tests are currently green. After PRs 1–3:
- K1: +2 tests in `TaskITest.I1.t.sol`
- K2: no new tests (existing tests updated to pass oracle address); net 0
- PR2: +3–5 handler actions; Invariant 7 is new; invariant count goes from 6 → 7
- PR3: 0 tests

Estimated new count: **401 Foundry tests + 1 new invariant** (7 total).

---

## Work order

```
PR 1 (one branch):
  1a. contracts/AutonomousVault.sol — CctpMessageDecoder.decodeFee + updated check + emit feeCharged
  1b. contracts/adapters/GoldExchangeAdapter.sol — mandatory oracle constructor arg + remove fallback
  1c. contracts/test/TaskITest.I1.t.sol — 2 new settle tests (fee=0, fee>0)
  1d. All GoldExchangeAdapter construction sites in tests — add oracle arg
  1e. bun run check + forge test --fuzz-runs 512

PR 2 (one branch):
  2a. contracts/test/invariant/VaultInvariant.Base.t.sol — mock CCTP messenger + transmitter
  2b. contracts/test/invariant/VaultInvariant.Handler.t.sol — 3 cross-chain actions + loss-recall + writeOff
  2c. contracts/test/invariant/VaultInvariant.t.sol — rephrase Invariant 4, add Invariant 7
  2d. forge test --match-path 'contracts/test/invariant/*' --invariant-runs 512 --invariant-depth 50 -vv

PR 3 (one branch):
  3a. README.md — 5 targeted edits (key-functions block, class diagram, cross-chain flow,
      ShariahVault dust rule text, security model dust rule row, CharityModule modifier note)

PR 4 (one branch, after 1–3 merged):
  4a. Confirm MessageTransmitterV2 address on Arc Testnet
  4b. contracts/script/Rehearsal.s.sol — 8-step deploy + exercise script
  4c. docs/rehearsal.md — tx hash log template
  4d. Run rehearsal; fill docs/agents/deployed-addresses.md
```
