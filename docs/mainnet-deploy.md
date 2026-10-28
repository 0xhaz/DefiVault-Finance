# DeFiVault — Arc Mainnet Deploy Guide

> **This guide targets real funds on Arc mainnet (chain ID 5042). Transactions are
> irreversible. Read the entire checklist before running a single command.**

Chain: **Arc Mainnet** (chain ID `5042`)  
RPC: `https://rpc.mainnet.arc.io`  
Explorer: https://explorer.arc.io  
USDC: `0x3600000000000000000000000000000000000000` (6 decimals, ERC-20)  
CCTP domain: `26`

---

## Prerequisites checklist (do every item before step 1)

- [ ] Independent security audit complete for all contracts in scope
- [ ] Testnet rehearsal (`docs/rehearsal.md`) completed and all 8 steps passed
- [ ] All board review items in `docs/agents/SHARIAH_REVIEW.md` resolved or explicitly accepted
- [ ] Safe multisig created for the board role (`BOARD_MULTISIG`) — use a threshold >= 2/3
- [ ] Deployer wallet funded with USDC on Arc mainnet (for gas)
- [ ] Private key held in an encrypted keystore (`cast wallet import`) — never in plaintext
- [ ] `.env` added to `.gitignore` — verify with `git check-ignore -v .env`
- [ ] `XAUT` mainnet address confirmed from Tether's official docs before wiring S6-H
- [ ] Chainlink XAU/USD mainnet oracle address confirmed before deploying `GoldAllocationAdapter`
- [ ] Uniswap V3 pool addresses (PAXG/USDC, XAUT/USDC) confirmed on Arc mainnet
- [ ] `BOARD_MULTISIG` address double-checked — board role changes require 30-day timelock after deploy

---

## Arc mainnet CCTP V2 contract addresses

Source: https://developers.circle.com/cctp/evm-smart-contracts.md (fetched 2026-10-28)

| Contract | Address |
|---|---|
| TokenMessengerV2 | `0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d` |
| MessageTransmitterV2 | `0x81D40F21F12A8F0E3252Bccb954D722d4c464B64` |
| TokenMinterV2 | `0x71f54F818671cD0D7ea140Da213e5C8b5C92a408` |
| TokenMessengerWithMetadataV2 | `0xfd78EE919681417d192449715b2594ab58f5D002` |

Verify each against https://explorer.arc.io before passing to a constructor or `setX` call.

---

## Environment variables

Add these to `.env` (never commit):

```env
# Deployer wallet — use cast wallet import for the actual key (see below)
# DEPLOYER_PK is only used for local simulation; production uses --account
DEPLOYER_PK=           # raw key for simulation only; remove before any git operation

# Mainnet addresses (no defaults — must be set explicitly)
BOARD_MULTISIG=0x<safe-multisig-address>
AGENT_WALLET=0x<agent-server-signing-address>

# CCTP V2 (Arc mainnet — verified above)
TOKEN_MESSENGER_V2=0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d
MSG_TRANSMITTER_V2=0x81D40F21F12A8F0E3252Bccb954D722d4c464B64

# Gold adapter inputs — confirm from official sources before filling
XAUT_ADDRESS=0x<xaut-on-arc-mainnet>
XAU_USD_ORACLE=0x<chainlink-xau-usd-on-arc-mainnet>
PAXG_USDC_POOL=0x<uniswap-v3-paxg-usdc-pool-on-arc-mainnet>
XAUT_USDC_POOL=0x<uniswap-v3-xaut-usdc-pool-on-arc-mainnet>

# RPC (also in foundry.toml as `arc`)
ARC_MAINNET_RPC=https://rpc.mainnet.arc.io
```

### Secure key handling (mandatory on mainnet)

```bash
# Import once — Foundry encrypts and saves under ~/.foundry/keystores/<name>
cast wallet import defivault-deployer --interactive

# Use --account in every forge script call instead of --private-key
forge script ... --account defivault-deployer --sender $DEPLOYER_ADDRESS
```

---

## Deploy order

Same dependency graph as testnet (see README Deployment section) with these mainnet differences:

1. Skip mock contracts — `MockAllocatedGold`, `MockXAUT`, `MockXauUsdAggregator`, `MockUniswapV3PoolXAUT` are testnet only. Wire the real addresses instead.
2. Pass `ShariahAdapterRegistry` (30-day `TIMELOCK_PERIOD`) — NOT `TestnetRegistryShortTimelock`. The testnet subclass must never appear on mainnet.
3. `sourceDomain = 26` (same as testnet for Arc).

### Step 1 — Deploy TreasuryModules and aggregators

```bash
forge script contracts/script/DeployShariahV2.s.sol \
  --sig "deployTreasury()" \
  --rpc-url $ARC_MAINNET_RPC \
  --broadcast \
  --account defivault-deployer \
  --sender $DEPLOYER_ADDRESS \
  -vvvv
```

Record addresses in `docs/agents/deployed-addresses.md` immediately after each broadcast.

### Step 2 — Deploy ShariahAdapterRegistry

```bash
forge script contracts/script/DeployShariahV2.s.sol \
  --sig "deployRegistry(address,address)" $DEPLOYER_ADDRESS $BOARD_MULTISIG \
  --rpc-url $ARC_MAINNET_RPC \
  --broadcast \
  --account defivault-deployer \
  --sender $DEPLOYER_ADDRESS \
  -vvvv
```

`initialOwner = deployer` (emergency powers only).  
`initialBoardMember = BOARD_MULTISIG` (receives boardRole — I5).

### Step 3 — Deploy vaults and modules

```bash
forge script contracts/script/DeployShariahV2.s.sol \
  --sig "deployVaults()" \
  --rpc-url $ARC_MAINNET_RPC \
  --broadcast \
  --account defivault-deployer \
  --sender $DEPLOYER_ADDRESS \
  -vvvv
```

### Step 4 — Deploy adapters (real addresses, no mocks)

Pass real `XAUT_ADDRESS`, `XAU_USD_ORACLE`, `PAXG_USDC_POOL`, `XAUT_USDC_POOL` from `.env`.

```bash
forge script contracts/script/DeployGoldAllocation.s.sol \
  --sig "run()" \
  --rpc-url $ARC_MAINNET_RPC \
  --broadcast \
  --account defivault-deployer \
  --sender $DEPLOYER_ADDRESS \
  -vvvv
```

### Step 5 — Wire CCTP

```bash
# On each vault:
cast send $VAULT_ADDRESS "setTokenMessenger(address)" $TOKEN_MESSENGER_V2 \
  --rpc-url $ARC_MAINNET_RPC \
  --account defivault-deployer

cast send $VAULT_ADDRESS "setMessageTransmitter(address)" $MSG_TRANSMITTER_V2 \
  --rpc-url $ARC_MAINNET_RPC \
  --account defivault-deployer
```

### Step 6 — Wire manager, adapters, set caps

```bash
cast send $VAULT_ADDRESS "setManager(address)" $EXECUTOR_ADDRESS ...
cast send $VAULT_ADDRESS "setGoldSpreadAdapter(address)" $GOLD_EXCHANGE_ADAPTER ...
cast send $VAULT_ADDRESS "setGoldAllocationAdapter(address)" $GOLD_ALLOC_ADAPTER ...
```

### Step 7 — Board screening (30-day timelock)

The board multisig must sign `proposeScreening` for each adapter, then wait 30 days before calling `executeScreening`. No adapter is usable in ShariahVaultV2 until its screening is executed with a non-zero `pronouncementHash` and a valid `expiresAt`.

```bash
# Board proposes (must be signed by board multisig)
cast send $REGISTRY "proposeScreening(address,bytes32,uint256)" \
  $ADAPTER_ADDRESS $PRONOUNCEMENT_HASH $EXPIRES_AT \
  --rpc-url $ARC_MAINNET_RPC \
  --account board-multisig-key

# After 30 days:
cast send $REGISTRY "executeScreening(address)" $ADAPTER_ADDRESS \
  --rpc-url $ARC_MAINNET_RPC \
  --account board-multisig-key
```

---

## Post-deploy verification

Run each check before enabling the agent:

```bash
# Confirm CCTP wiring
cast call $VAULT "tokenMessenger()" --rpc-url $ARC_MAINNET_RPC
cast call $VAULT "messageTransmitter()" --rpc-url $ARC_MAINNET_RPC

# Confirm sourceDomain matches Arc CCTP domain 26
cast call $VAULT "sourceDomain()" --rpc-url $ARC_MAINNET_RPC

# Confirm gold adapters wired
cast call $VAULT "goldSpreadAdapter()" --rpc-url $ARC_MAINNET_RPC
cast call $VAULT "goldAllocationAdapter()" --rpc-url $ARC_MAINNET_RPC

# Confirm oracle is live (isPriceSane should return true before any deployment)
cast call $GOLD_EXCHANGE_ADAPTER "isPriceSane()" --rpc-url $ARC_MAINNET_RPC
cast call $GOLD_ALLOC_ADAPTER "isPriceSane()" --rpc-url $ARC_MAINNET_RPC

# Confirm registry has the correct board member
cast call $REGISTRY "isBoard(address)" $BOARD_MULTISIG --rpc-url $ARC_MAINNET_RPC
```

---

## Deployed addresses

Fill after each step. Keep in sync with `docs/agents/deployed-addresses.md`.

| Contract | Address | Tx hash | Block |
|---|---|---|---|
| ShariahAdapterRegistry | | | |
| TreasuryModule (Shariah) | | | |
| ZakatModule (v1 compat) | | | |
| ShariahVaultV2 (Conservative) | | | |
| ShariahVaultV2 (Dynamic) | | | |
| CharityModule | | | |
| PurificationEscrow | | | |
| ShariahScoreAggregator | | | |
| RiskTieredExecutor (Conservative) | | | |
| RiskTieredExecutor (Dynamic) | | | |
| GoldExchangeAdapter (S2-H) | | | |
| GoldAllocationAdapter (S6-H) | | | |

---

## Known gaps before going live

- [ ] `XAUT` on Arc mainnet: confirm address from Tether's official contract list — not deployed at the testnet mock address. S6-H must remain `strategyEnabled[5] = false` until the board approves SR-008 AND the real XAUT address is wired.
- [ ] Chainlink XAU/USD feed on Arc mainnet: confirm address and heartbeat interval. If no Chainlink feed exists on Arc mainnet yet, S2-H and S6-H cannot go live until one is available or an alternative oracle is board-approved.
- [ ] Uniswap V3 PAXG/USDC and XAUT/USDC pools on Arc mainnet: confirm addresses and initial liquidity before enabling gold adapters.
- [ ] `TreasuryModule.feeSource` must point at the deployed vault, not a placeholder. Redeploy if it was set to `address(0)` during the Rehearsal run.

---

*All addresses in this file must be independently verified on https://explorer.arc.io before use.*
