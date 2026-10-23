# Task K — Testnet Rehearsal Log

Chain: **Arc Testnet** (chain ID 5042002)  
Script: `contracts/script/Rehearsal.s.sol`  
Date: TBD (populate after run)

---

## Prerequisites

1. Install Foundry (`foundryup`).
2. Set environment variables:

| Variable | Purpose | Notes |
|---|---|---|
| `DEPLOYER_PK` | Deployer / owner private key | Funded with USDC on Arc Testnet |
| `BOARD_MULTISIG` | Board role address (separate from deployer) | Use a test EOA; Safe on mainnet |
| `WALLET_A_PK` | First test depositor private key | Funded with 200+ USDC |
| `WALLET_B_PK` | Second test depositor private key | Funded with 200+ USDC |
| `WALLET_C_PK` | Third test depositor private key | Funded with 200+ USDC |
| `WALLET_A` | Address of WALLET_A | Derived from WALLET_A_PK |
| `WALLET_B` | Address of WALLET_B | |
| `WALLET_C` | Address of WALLET_C | |
| `AGENT_WALLET` | Address from which agent server signs txs | |
| `ARC_TESTNET_RPC` | Arc Testnet RPC URL | From Circle developer docs |

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

| Contract | Address | Tx hash | Gas used |
|---|---|---|---|
| TestnetRegistryShortTimelock | `TBD` | `TBD` | TBD |
| TreasuryModule (Shariah) | `TBD` | `TBD` | TBD |
| ZakatModule (deprecated) | `TBD` | `TBD` | TBD |
| ShariahVaultV2 (Conservative) | `TBD` | `TBD` | TBD |
| CharityModule | `TBD` | `TBD` | TBD |
| PurificationEscrow | `TBD` | `TBD` | TBD |
| MockAllocatedGold (PAXG) | `TBD` | `TBD` | TBD |
| MockXAUT | `TBD` | `TBD` | TBD |
| MockXauUsdAggregator | `TBD` | `TBD` | TBD |
| MockUniswapV3PoolXAUT | `TBD` | `TBD` | TBD |
| GoldExchangeAdapter (S2-H) | `TBD` | `TBD` | TBD |
| GoldAllocationAdapter (S6-H) | `TBD` | `TBD` | TBD |
| ShariahScoreAggregator | `TBD` | `TBD` | TBD |
| RiskTieredExecutor (Conservative) | `TBD` | `TBD` | TBD |

**Surprises / notes:**

> (empty — fill after run)

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
| WALLET_A | `TBD` | TBD | TBD |
| WALLET_B | `TBD` | TBD | TBD |
| WALLET_C | `TBD` | TBD | TBD |

---

## Step 3 — Screen S3-H via Short Testnet Timelock

```bash
# Propose screening (boardMultisig must sign)
forge script contracts/script/Rehearsal.s.sol \
  --sig "step3_screenS3H(address)" <HALAL_LP_ADAPTER_ADDRESS> \
  --rpc-url $ARC_TESTNET_RPC \
  --broadcast \
  --private-key $BOARD_MULTISIG_PK \
  -vvvv

# Wait 2 minutes, then execute
forge script contracts/script/Rehearsal.s.sol \
  --sig "step3b_executeScreening(address)" <HALAL_LP_ADAPTER_ADDRESS> \
  --rpc-url $ARC_TESTNET_RPC \
  --broadcast \
  --private-key $BOARD_MULTISIG_PK \
  -vvvv
```

| Step | Tx hash | Gas used | Notes |
|---|---|---|---|
| proposeScreening | `TBD` | TBD | pronouncementHash = keccak256("SR-011-REHEARSAL-TESTNET-ONLY") |
| executeScreening (after 2 min) | `TBD` | TBD | |

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
| TBD | ExecutionTriggered | TBD | TBD | TBD | TBD |

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
| deployCrossChain | `TBD` | TBD | nonce: TBD |
| settleCrossChainWithMessage | `TBD` | TBD | feeExecuted: TBD |

**CrossChainFeeDeducted emitted?** Yes / No  
**CrossChainSettled shortfall:** TBD  
**NAV before / after:** TBD / TBD

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
| Gold position == 0 (no deploy yet) | `maxDeposit > 0` (dust rule — deposits NOT blocked) | TBD |
| Gold position > dustThreshold AND oracle stale | `maxDeposit == 0` (deposits BLOCKED) | TBD |
| Redemption while oracle stale | Succeeds (redemptions always open) | TBD |

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

Waterfall amounts (from `WaterfallExecuted` + `MusharakahProfitClaimed` events):

| Step | Amount | Notes |
|---|---|---|
| grossProfit | 10 USDC | |
| purified (step 1) | TBD | purificationBps × grossProfit |
| charity / sadaqah (step 2) | TBD | charityBps × afterPurification |
| vaultShare (step 3) | TBD | Musharakah 10% above 4% hurdle |
| depositorShare (step 4) | TBD | remainder |
| lockedProfit after claim | TBD | streams into totalAssets over 3 days |
| unlockedAt | TBD | block.timestamp + 3 days |

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

| Wallet | Tx hash | Gas used | USDC received | Shares remaining |
|---|---|---|---|---|
| WALLET_A | `TBD` | TBD | TBD | 0 |
| WALLET_B | `TBD` | TBD | TBD | 0 |
| WALLET_C | `TBD` | TBD | TBD | 0 |

---

## Summary

**Status:** Not yet run — fill after execution.

**Known issues / surprises:**

- `MSG_TRANSMITTER` address in `Rehearsal.s.sol` is a placeholder (`address(0)`).
  Look up the Arc Testnet `MessageTransmitter` address from Circle developer docs and fill it in
  before attempting step 5. If unavailable, steps 5 and 5b require a manual `vm.prank` against
  a MockMessageTransmitter or must be skipped with a documented reason.

- The CCTP cross-chain step (step 5) requires a funded CCTP `tokenMessenger` on Arc Testnet.
  Confirm it is live at `0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA` before broadcasting.

- The TreasuryModule is deployed with `deployer` as `feeSource` (temporary placeholder).
  Redeploy with the actual vault address as `feeSource` before any live profit claims
  (step 7) to ensure `accrue()` works correctly.

---

*Rehearsal script: `contracts/script/Rehearsal.s.sol`*  
*Deployed addresses: `docs/agents/deployed-addresses.md`*
