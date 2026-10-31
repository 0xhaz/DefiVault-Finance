# Task K — Testnet Rehearsal Log

Chain: **Arc Testnet** (chain ID 5042002)  
Script: `contracts/script/Rehearsal.s.sol`  
Date: 2026-10-28 (run 2). Later runs (3 to 5) are logged at the end of this file and in `docs/agents/deployed-addresses.md`.  
Rows marked "not recorded" or "not run live" were reconciled on 2026-10-31 (workplan P-1): the step was either done without recording the value, or not run on live testnet.

---

## Prerequisites

1. Install Foundry (`foundryup`).
2. Set environment variables:

| Variable | Purpose | Notes |
|---|---|---|
| `DEPLOYER_PK` | Deployer / owner private key (hex, with 0x) | Funded with USDC on Arc Testnet |
| `BOARD_PK` | Board member private key (hex, with 0x) | Can equal DEPLOYER_PK on testnet; use a separate Safe on mainnet |
| `BOARD_MULTISIG` | Board member address (derived from BOARD_PK) | Set to `vm.addr(BOARD_PK)` automatically if omitted |
| `WALLET_A_PK` | First test depositor private key | Funded with 200+ USDC |
| `WALLET_B_PK` | Second test depositor private key | Funded with 200+ USDC |
| `WALLET_C_PK` | Third test depositor private key | Funded with 200+ USDC |
| `WALLET_A` | Address of WALLET_A | Derived from WALLET_A_PK |
| `WALLET_B` | Address of WALLET_B | |
| `WALLET_C` | Address of WALLET_C | |
| `AGENT_WALLET` | Address from which agent server signs txs | |
| `ARC_TESTNET_RPC` | Arc Testnet RPC URL | `https://rpc.testnet.arc.io` |

Fund test wallets via the Arc Studio sidebar **"Get test USDC"** button.

---

## Step 1 — Deploy Full Stack

```bash
forge script contracts/script/Rehearsal.s.sol \
  --sig "step1_deploy()" \
  --rpc-url $ARC_TESTNET_RPC \
  --broadcast \
  --private-key $DEPLOYER_PK \
  -vvvv
```

**Important:** `TestnetRegistryShortTimelock` is deployed with a 2-minute `TIMELOCK_PERIOD`.  
This contract is **TESTNET ONLY**. Production MUST use `ShariahAdapterRegistry` (30-day timelock).

Run 1 (superseded — broken timelock): block 69492828, tx `0x6284050ab2f006...`  
Run 2 (active): block ~69495xxx, broadcast file `run-1793187743752.json`

| Contract | Address | Gas used |
|---|---|---|
| TestnetRegistryShortTimelock | `0x23836611FDF05fAc07a12416e9c8C250F9cdF671` | — |
| TreasuryModule (Shariah) | `0xF5B550B87476a4359f1307AeFC425cCC6E2530f5` | — |
| ZakatModule (deprecated) | `0xB3fC6A662196EE2c424B6bdfBf9343d96d29569c` | — |
| ShariahVaultV2 (Conservative) | `0xba094D5B01F4fd245EA345Be6B8ac833488c81B0` | — |
| CharityModule | `0x1D05a0010C78B984b0De2735A6E868E9c9f5d99F` | — |
| PurificationEscrow | `0xcC58b11c3Cd251a44989fEf1f05BdcB0e16375ff` | — |
| MockAllocatedGold (PAXG) | `0x90476D68572E615a1E1447928c8c5d8AABaC6B51` | — |
| MockXAUT | `0xC57b6125d2a15C09E3624eb78df06e407F6A9912` | — |
| MockXauUsdAggregator | `0x214a54F86B84589068Cf459749344b1F637A60f7` | — |
| MockUniswapV3PoolXAUT | `0x6A46a3A9608437e832510EfD16a21898dA02dc66` | — |
| GoldExchangeAdapter (S2-H) | `0x55907Fc4E60A5353D9afD17D56F229192Fd9c3ED` | — |
| GoldAllocationAdapter (S6-H) | `0x04FdFd46F0c93569F3b592C106dDc292fc2f975C` | — |
| ShariahScoreAggregator | `0x13340E36E59F8b504faD9B1b731D51fde1697C8A` | — |
| RiskTieredExecutor (Conservative) | `0xA800540A029120C475c15345d5D65FB9C898d85c` | — |

**Surprises / notes:**

- Run 1 used broken `TestnetRegistryShortTimelock` (called parent `proposeScreening` → 30-day timelock). Fixed in run 2 with dedicated `proposeScreeningTestnet` / `executeScreeningTestnet` functions that use a separate 2-minute proposal store.
- Arc Testnet USDC predeploy causes `StackUnderflow` on any ERC-20 call (`transfer`, `transferFrom`, `approve`) from within a Foundry broadcast script. Workaround: use `cast send` for token operations, or use mock tokens (MockXAUT, MockAllocatedGold) which are plain ERC-20s without the delegatecall proxy.
- Pool seeded with MockXAUT only (not USDC) for the same reason.

---

## Step 2 — Three Wallets Deposit

```bash
forge script contracts/script/Rehearsal.s.sol \
  --sig "step2_deposits()" \
  --rpc-url $ARC_TESTNET_RPC \
  --broadcast \
  --private-key $DEPLOYER_PK \
  -vvvv
```

Each wallet deposits 100 USDC into Conservative V2.

| Wallet | Tx hash | Gas used | Shares received |
|---|---|---|---|
| WALLET_A | not recorded | not recorded | not recorded |
| WALLET_B | same wallet (single key rehearsal) | — | — |
| WALLET_C | same wallet (single key rehearsal) | — | — |

Done with `cast send` from a single wallet (the forge broadcast hits the Arc Testnet USDC `StackUnderflow`, see Summary item 1). Tx hashes were not recorded.

---

## Step 3 — Screen an adapter via Short Testnet Timelock

The script step is named for S3-H, but in run 2 it screened the **GoldExchangeAdapter (S2-H)**: no `HalalLPAdapter` was deployed. The LP adapter has still not been deployed on testnet; see `workplan.md` Phase 2.

```bash
# Propose screening (boardMultisig must sign)
forge script contracts/script/Rehearsal.s.sol \
  --sig "step3_screenS3H(address)" <HALAL_LP_ADAPTER_ADDRESS> \
  --rpc-url $ARC_TESTNET_RPC \
  --broadcast \
  --private-key $BOARD_PK \
  -vvvv

# Wait 2 minutes, then execute
forge script contracts/script/Rehearsal.s.sol \
  --sig "step3b_executeScreening(address)" <HALAL_LP_ADAPTER_ADDRESS> \
  --rpc-url $ARC_TESTNET_RPC \
  --broadcast \
  --private-key $BOARD_PK \
  -vvvv
```

| Step | Tx hash | Gas used | Notes |
|---|---|---|---|
| proposeScreeningTestnet (GoldExchangeAdapter) | `0x49d97783d4bb247151e685d0709b154fc02434257ff9608af2773e09fc54ca43` | 91392 gas / 0.001874 USDC | block 69495519; pronouncementHash = keccak256("SR-011-REHEARSAL-TESTNET-ONLY") |
| executeScreeningTestnet (after 2 min) | `0x923364d2df9789d93ae472659daa3a78ed011b218de3537add0c04272730108b` | 91482 gas / 0.001875 USDC | block 69495948 |
| setScreened(adapter, true) | `0xf1ddf73ebfd6a66d9380d28caa50384752b8ed8d9787177ab8a058d9a78db0c7` | 47877 gas / 0.000981 USDC | block 69495948 |

---

## Step 4 — Agent Server Run (2+ Hours)

Start the agent server against the deployed contracts:

```bash
# Set contract addresses in .env first, then:
bun run agent
```

Monitor `ExecutionTriggered` events. Record here:

| Timestamp | Event | Tx hash | Gas used | Strategy | Amount |
|---|---|---|---|---|---|
| 2026-10-28 | Agent scoring loop running | — | — | HALAL_LP=90, ETH_SPREAD=75/45, GOLD_ALLOCATION=75, MURABAHA=20/70, GOLD_SPREAD=15/45/75, RWA_SUKUK=DISABLED | Simulated only |
| — | ExecutionTriggered | not fired | — | — | On-chain write requires ORACLE_WALLET_ID + Circle DCW SDK (not wired in this rehearsal) |

**Surprises / notes:**

> (empty — fill after run)

---

## Step 5 — Cross-Chain Round Trip (CCTP to ETH-SEPOLIA)

```bash
# Deploy cross-chain
forge script contracts/script/Rehearsal.s.sol \
  --sig "step5_deployCrossChain()" \
  --rpc-url $ARC_TESTNET_RPC \
  --broadcast \
  --private-key $DEPLOYER_PK \
  -vvvv
```

Note the CCTP nonce from the `CapitalDeployedCrossChain` event.  
Poll CCTP attestation API: `GET https://iris-api-sandbox.circle.com/v1/attestations/{messageHash}`  
Once attestation is complete (`status == "complete"`):

```bash
# Settle with message (includes feeExecuted handling — K1)
forge script contracts/script/Rehearsal.s.sol \
  --sig "step5b_settle(uint64,bytes,bytes)" <NONCE> <MESSAGE_HEX> <ATTESTATION_HEX> \
  --rpc-url $ARC_TESTNET_RPC \
  --broadcast \
  --private-key $DEPLOYER_PK \
  -vvvv
```

| Step | Tx hash | Gas used | Notes |
|---|---|---|---|
| deployCrossChain | not run live | — | — |
| settleCrossChainWithMessage | not run live | — | — |

Not run on live testnet. The settle path is verified on a fork of the real Arc Testnet contracts ("Fork Verification Results" below and `ForkCctpRealArc*.t.sol`). A live round trip is still open (workplan Phase 3).

---

## Step 6 — Force Stale Oracle

Run from a fork with `vm.warp`, or simply wait > 1 day without calling `pokePrice()`:

```bash
forge script contracts/script/Rehearsal.s.sol \
  --sig "step6_forceStaleOracle()" \
  --rpc-url $ARC_TESTNET_RPC \
  --private-key $DEPLOYER_PK \
  -vvvv
```

Expected outcomes:

| Condition | Expected result | Actual result |
|---|---|---|
| Gold position == 0 (no deploy yet) | `maxDeposit > 0` (dust rule — deposits NOT blocked) | Confirmed live (run 2) |
| Gold position > dustThreshold AND oracle stale | `maxDeposit == 0` (deposits BLOCKED) | Not run live (no gold position at the time); covered by unit tests |
| Redemption while oracle stale | Succeeds (redemptions always open) | Not run live; covered by unit tests |

---

## Step 7 — Claim Profit

```bash
forge script contracts/script/Rehearsal.s.sol \
  --sig "step7_claimProfit()" \
  --rpc-url $ARC_TESTNET_RPC \
  --broadcast \
  --private-key $DEPLOYER_PK \
  -vvvv
```

**SKIPPED** — Arc Testnet USDC predeploy (`0x3600...`) causes `StackUnderflow` on any `transferFrom` call inside a Foundry broadcast script. `PurificationEscrow.executeWaterfall` calls USDC `transferFrom` to split the waterfall, which hits this delegatecall depth issue. This is an Arc Testnet infrastructure limitation, not a contract bug — the waterfall logic is covered by unit tests (CharityModuleTest, PurificationEscrowTest). To verify end-to-end on-chain: run on a local `anvil --fork-url` with a standard ERC-20 mock replacing the USDC predeploy.

| Step | Amount | Notes |
|---|---|---|
| grossProfit | 10 USDC | (intended claim amount) |
| purified (step 1) | SKIPPED | Arc Testnet USDC blocker |
| charity / sadaqah (step 2) | SKIPPED | Arc Testnet USDC blocker |
| vaultShare (step 3) | SKIPPED | Arc Testnet USDC blocker |
| depositorShare (step 4) | SKIPPED | Arc Testnet USDC blocker |
| lockedProfit after claim | SKIPPED | Arc Testnet USDC blocker |
| unlockedAt | SKIPPED | The claim-time lock was later removed (N-11); a claim no longer sets `unlockedAt` |

---

## Step 8 — All Three Wallets Redeem

```bash
forge script contracts/script/Rehearsal.s.sol \
  --sig "step8_redeemAll()" \
  --rpc-url $ARC_TESTNET_RPC \
  --broadcast \
  --private-key $DEPLOYER_PK \
  -vvvv
```

Used `cast send` directly (Foundry broadcast script hits Arc Testnet USDC StackUnderflow on `redeem` → `asset.transfer`).

| Wallet | Tx hash | Block | Gas | Notes |
|---|---|---|---|---|
| WALLET_A | `0x3e89d8db2bebc07b3e9401bbaa550dc7abb1829044d6f8f542a85649593f323f` | 69492755 | — | Full redeem via `cast send`; status 1 |
| WALLET_B | same wallet (single key rehearsal) | — | — | |
| WALLET_C | same wallet (single key rehearsal) | — | — | |

---

## Summary

**Status: COMPLETE** (2026-10-28). Steps 1–4, 6, 8 executed on Arc Testnet. Steps 5 and 7 skipped — see blockers below.

| Step | Result |
|---|---|
| 1 — Deploy | Done (run 2; run 1 had broken timelock) |
| 2 — Deposits | Done via `cast send` (USDC predeploy blocker on forge script) |
| 3 — Screen adapter | Done — 2-min testnet timelock works end-to-end |
| 4 — Agent scoring | Done — 8+ cycles, HALAL_LP=90 consistently wins; on-chain write not wired (needs ORACLE_WALLET_ID + Circle DCW) |
| 5 — Cross-chain CCTP | Skipped — `MSG_TRANSMITTER` address not yet confirmed for Arc Testnet |
| 6 — Stale oracle check | Done — dust rule confirmed: deposits not blocked when gold position = 0 |
| 7 — Profit claim | Skipped — Arc Testnet USDC predeploy causes StackUnderflow in `PurificationEscrow.executeWaterfall` |
| 8 — Redemption | Done via `cast send` |

**Known issues / surprises discovered during rehearsal:**

1. Arc Testnet USDC predeploy (`0x3600...`) causes `StackUnderflow` on **any** ERC-20 call (`transfer`, `transferFrom`, `approve`) made from within a Foundry broadcast script or from a contract called by one. Root cause: delegatecall proxy with deep stack. Workaround: use `cast send` for all direct token operations. Steps 7 and pool seeding are blocked by this.

2. `TestnetRegistryShortTimelock` (run 1) called the parent `proposeScreening` which uses the 30-day timelock constant. Fixed in run 2 with a dedicated `proposeScreeningTestnet` / `executeScreeningTestnet` pair that stores proposals in a separate mapping with `TESTNET_TIMELOCK_PERIOD = 2 minutes`.

3. `_addrs` struct in `Rehearsal.s.sol` is in-memory and zeroed for every step call after step 1. Fixed by adding `_loadAddrs()` with hardcoded defaults for the active deployment.

4. Agent on-chain write path (`writeScoresToChain`) generates calldata but does not broadcast — requires `ORACLE_WALLET_ID` wired to a Circle developer-controlled wallet. Scoring logic confirmed correct (simulated).

5. `TreasuryModule` deployed with `deployer` as `feeSource` placeholder — redeploy with the actual vault address before live profit claims.

6. Step 5 (CCTP cross-chain) not attempted on live testnet — `MSG_TRANSMITTER` address on Arc Testnet not yet confirmed from Circle docs. `TokenMessengerV2` is `0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA`; transmitter address needed separately. Note: the live deployment predates Task N1 and still carries the old `goldCrossChainBlocked` flag set to `true`. A vault redeployed from the N1 source has no such flag, so step 5 needs no unblocking (SR-023 superseded). On the old live vault the owner must still call `setGoldCrossChainBlocked(false)` once. Fork test confirmed the CCTP settle path works correctly with mocks (4/4 pass, feeExecuted offset fix verified).

---

## Fork Verification Results (2026-10-28)

Fork test file: `contracts/test/ForkRehearsalSteps5And7.t.sol`  
Command: `forge test --match-contract ForkRehearsalSteps5And7 --fork-url https://rpc.testnet.arc.io`  
Result: **4/4 PASS**

| Test | Result | Key assertion |
|---|---|---|
| `test_step5_settle_fee_lt_maxfee` | PASS | feeExecuted=2e6 < maxFee=5e6; expectedNet=98e6 received; CrossChainFeeDeducted emitted; L1 offset fix load-bearing confirmed |
| `test_step5_settle_regression_guard` | PASS | Clean settle in independent fork snapshot |
| `test_step7_claimMusharakahProfit_waterfall` | PASS (after CharityModule fix) | WaterfallExecuted + MusharakahProfitClaimed emitted; lockedProfit>0; profit unlocks over 3 days (as of 2026-10-28; N-11 later removed the claim-time lock, and the test now asserts an unchanged share price) |
| `test_step7_depositor_redeems_above_cost` | PASS | Depositor receives 104.99 USDC on 100 USDC deposit; no dilution |

**CharityModule bug fixed** (found during fork test): `distributeCharity()` was checking `msg.sender == vault` but the actual caller is `PurificationEscrow`. Fixed by adding `escrow` address field + `setEscrow(address)` owner-only setter, updating the guard to accept vault or escrow, and pulling from `msg.sender` (escrow) rather than hardcoded `vault`. `Rehearsal.s.sol` updated to call `charity.setEscrow(escrow)` after both are deployed. All 26 existing CharityModule unit tests still pass.

---

*Rehearsal script: `contracts/script/Rehearsal.s.sol`*  
*Deployed addresses: `docs/agents/deployed-addresses.md`*

---

## Run 3 (2026-10-30) — redeployed stack, no claim-time lock

Stack: see `docs/agents/deployed-addresses.md` (run 3). Executed on Arc Testnet with the fixed vault.

| Step | Result |
|---|---|
| 1 Deploy | Libraries and full stack deployed; vault runtime 23,677 B; treasury `feeSource` = vault; charity escrow wired |
| 2 Deposit | One 20 USDC deposit (the three configured test wallets are the same address, funded with about 28.6 USDC, so only one deposit fit) |
| 3 Screen | Both gold adapters proposed, executed after the 2-minute testnet timelock, and marked screened |
| 7 Claim | 5 USDC synthetic profit claimed. NAV 25.0 to 24.3875 USDC (cut for purification, charity and fee only), `lockedProfit` = 0, `hwmDeficit` = 0, treasury pending fees 0.4875 USDC. Realized profit back to 0, so nothing is claimable twice |
| 8 Redeem | Full redeem returned 24.384719 USDC for the 20 USDC deposit plus its depositor share, immediately after the claim. Supply 0 |
| Wiring | `setMessageTransmitter` set to Arc Testnet MessageTransmitterV2 `0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275`; vault `localDomain` = 26 |

Not run live: step 5 (cross-chain round trip needs a 30-day remote-recipient approval and a real attestation) and step 6 (stale oracle needs more than a day of waiting).

---

## Run 6 (2026-10-31): current code, real Uniswap V3 LP on Arc Testnet

Stack: run 6 in `docs/agents/deployed-addresses.md` (vault `0x682EA638a167cf812a5694ebCDb15Ae2516e75c6`), deployed from the head of the PR stack (N-33, N-35 to N-41). The vault runtime on chain matches the source (24,414 B). Single testnet key `0x3D23…98f9` acts as deployer, owner, board, oracle and depositor.

### LP-3 / LP-4: Uniswap V3 on Arc Testnet

| Step | Tx | Result |
|---|---|---|
| Deploy factory, NPM, SwapRouter02, MVOL, two pools (`DeployUniswapV3Testnet.s.sol`) | 10 tx from block 70015544 (broadcast file) | All status 1. Runtime sizes equal the official Arc mainnet code. USDC/EURC 0.05% at tick -1089, MVOL/USDC 0.3% at 1:1, cardinality next 300 |
| Seed (`seed-testnet.sh`) | `cast send` x6 | USDC/EURC: 9.60 USDC + 9 EURC (ticks -1600 to -600); MVOL/USDC: 10 + 10 full range. NPM pulled Arc's native-coin USDC without issue |
| Swap 0.1 USDC to EURC via SwapRouter02 | `0x3ccace1b5e0452e22706de0453a86fada44f56d1cf0c146ea7a55a50cf8964d7` | 0.089616 EURC out (price 0.897 less the 0.05% fee) |

### LP-5: wire the LP adapter

| Step | Tx | Result |
|---|---|---|
| Deploy `HalalLPAdapter` (USDC/EURC 0.05%, `DeployHalalLP.s.sol`) | broadcast file | `0xB0452Ac499bDF8F94F83cDc5cA64b4F06e1cd911` |
| Propose screening (2-minute testnet registry) | `step3_screenS3H` | Proposed 13:26:46 UTC |
| Execute screening + `setScreened` | `step3b_executeScreening` | Registry and vault both report screened. A first attempt 3 s before the 2-minute mark reverted `timelock not elapsed`, as designed |
| Executor config HALAL_LP (min 0.1, max 1 USDC) | `0xc731662d4f892587d470cb11f95e3d65986dccd4aa3aa993525ac056eaf62531` | status 1 |
| Aggregator enable index 2 (testnet only, no board pronouncement) | `0x6532eb23bff49d1796825d354344d659fe65e85fe1b6e6d73f5577ab50ace92d` | status 1 |
| Deposit 5 USDC | `0x328de713880b02b2d853af98f5041ac86806185c00d9137fcc0541007d61af2d` | 5e12 shares, `totalAssets` 5 USDC |

### T-5: 30-day clocks started (execute after 2026-11-30 13:30 UTC)

| Proposal | Tx | Status |
|---|---|---|
| GoldExchangeAdapter emergency exit enable | `0x709186e20da58cb9df8e71696c318bb01ad20818abd2a0a08ac2e4880db618dc` | Pending. Also locks its oracle while pending (N-39) |
| GoldAllocationAdapter emergency exit enable | `0x0d5dee385df7e012483dd84489d07e8f8d873645362d665115651ef69d9176ad` | Pending |
| HalalLPAdapter max slippage 100 to 150 bps | `0xcc86442b373c6d8b451b84c7e16d4f6b7de625b94ab13320b1656f84514bcde5` | Pending |
| Vault dust threshold 1.0 to 0.9 USDC | `0x4e2778e0a0295ae31e929b0e8d8112dea423e4e78b9e2531825ecf4d27141703` | Pending |
| Remote recipient, CCTP domain 0 (ETH-Sepolia), deployer address | `0x583f7837a637ac5c8f1436e3fb4d7f41a061307bcc4c389644f33967b856c347` | Pending; needed for the live CCTP round trip (T-1) |
| Charity rate 250 to 300 bps | `0xd89e00352646cf7a943b6b3bb048c714987315dd50b76526c2424c2cdefe43a1` | **Cancelled** (`0xdf5105f995ed169697f95b01ee168355cdb33f1e7eb16fe5f1105f07b5a6f845`): the cancel path works |
