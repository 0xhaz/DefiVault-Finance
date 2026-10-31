# Deployed Contract Addresses

All deployments are to **Arc Testnet** (chain ID 5042002) unless noted.  
This file is the canonical address record — update after every deploy broadcast.  
AGENTS.md points here; do not record addresses elsewhere.

---

## Deploy batch — 2026-10-28 run 1 (SUPERSEDED — broken TestnetRegistryShortTimelock)

Script: `contracts/script/Rehearsal.s.sol` → `step1_deploy()`  
Tx: `0x6284050ab2f006a6fd23e4aae529bdfd8c749dbeaa32e310463b6bc9105a7338` Block: 69 492 828  
**Replaced by run 2 below. Do not use these addresses.**

---

## Deploy batch — 2026-10-31 run 5 (ACTIVE)

Script: `contracts/script/Rehearsal.s.sol` → `step1_deploy()` (broadcast: `broadcast/Rehearsal.s.sol/5042002/step1_deploy-latest.json`)  
Deployer: `0x3D23214d59CA3582628FffFE44D0Df1CC73D98f9`  
Run 4 (same day) is superseded: a live smoke test showed `eth_estimateGas` picked a gas limit that starved the exit settlement, so the leaver skipped the distribution cut. Run 5 adds an up-front exit gas requirement (`InsufficientExitGas`, 2 x (700k + 250k per funded adapter)). Wallets and scripts must let `eth_estimateGas` run or set at least that limit for exits while realized profit exists.  
Executor note: the original run 5 executor was replaced the same day (`0x08f0078F8460F64331Ab72191989632D74aA1740`, now the vault manager). The first one sized gold deployments to the 80% allocation limit and always hit `GoldCapExceeded` (gold is capped at 30% of NAV). The new `RiskTieredExecutor` clamps gold strategies to the remaining gold room. Its tier gas limit was raised to 200 gwei (Arc Testnet gas runs about 20 to 50 gwei, above the 20/30 gwei tier defaults), and the aggregator strategies for GOLD_SPREAD and GOLD_ALLOCATION were enabled (testnet only). End-to-end verified live on this stack: deposit, `writeScore`, `executeWinner` (gold allocation, 1.2 USDC), 1 USDC of yield, `claimMusharakahProfit` (share price unchanged across the claim), `recallCapital`, then a full redeem that left only the pending fees in the vault.  
Includes: N-26 hurdle carry, N-27 non-gold mark-to-market with deposit gate, N-29 net-of-cut pricing with exit settlement, N-09 gold emergency exit (per-sale proposal, 20% floor), principal hook `retireGoldPrincipal`, hurdle basis on deposits and withdrawals, liquidity-aware `maxWithdraw`/`maxRedeem`, executor wired to the Shariah aggregator with gold strategies enabled, message transmitter set to the Arc Testnet MessageTransmitterV2.  
`ShariahVaultV2` runtime on chain: 24,317 bytes (limit 24,576). Four linked libraries are deployed first (addresses in the broadcast file). `HalalLPAdapter` is not part of this deploy. Run 5 predates the N-33 fix (adapter read cap 150k, exit budget 1.3M per funded adapter, at most 5 funded adapters) and the N-35 fix (`returnCapital` only from funded adapters); do not fund a real LP adapter on it.

| Contract | Address | Notes |
|---|---|---|
| TestnetRegistryShortTimelock | `0xf0565b9f59c4C1CEBD17444BdE2ED5fC506738E9` | 2-minute timelock, TESTNET ONLY |
| ZakatModule | `0x6a37239Cc8ddEfd7B15361E74881AC3Cb17A4BA7` | v1 compat shim |
| TreasuryModule | `0x5950B060BAB62071c089023379fF551e63a38b2d` | feeSource = vault |
| ShariahVaultV2 (Conservative) | `0x921745edB0c2600481aA7E2e52D3A31ecE032CaC` | Primary vault |
| CharityModule | `0xb012199314D0C4A430a7E3CfacdBC4a70dB5B4aF` | escrow wired |
| PurificationEscrow | `0x30D0F57737271dF7A50e6098cbe590474f1530f5` | |
| GoldExchangeAdapter (S2-H) | `0x325b43346bB47ca4a57BA8CF66A01f42063F6891` | |
| GoldAllocationAdapter (S6-H) | `0x45cdaa572abf6A6712303DA1E903D1F8a60909Dc` | |
| ShariahScoreAggregator | `0x8D4a426f6285d8f779731Eeaf7431B5C2C0A8B9B` | |
| RiskTieredExecutor | `0x08f0078F8460F64331Ab72191989632D74aA1740` | vault manager |
| MockAllocatedGold (PAXG) | `0x59dD438935A3c3D7E8DD582bE2f71B3218825A4f` | Testnet mock only |
| MockXAUT | `0xa66aEe9767bAf57e6c5552626911B31606823e51` | Testnet mock only |
| MockXauUsdAggregator | `0x25bC73c81869070C2115Bf95CF40b43AA05EeF28` | Testnet mock only |
| MockUniswapV3PoolXAUT | `0xaB832009832460522B26230a60C2673648aF6D70` | Testnet mock only |

Adapters must be screened on this registry before any capital is deployed (gold adapters: see the status line below).

---

## Deploy batch — 2026-10-30 run 3 (SUPERSEDED by runs 4 and 5)

Script: `contracts/script/Rehearsal.s.sol` → `step1_deploy()` (broadcast: `broadcast/Rehearsal.s.sol/5042002/step1_deploy-latest.json`)  
Deployer: `0x3D23214d59CA3582628FffFE44D0Df1CC73D98f9`  
Includes: no claim-time profit lock (N-11/N-24), vault split into external libraries to fit the 24,576-byte limit (runtime 23,677 B), treasury `feeSource` = vault.  
Four linked libraries deployed first: `CctpSettlementLogic`, `ShariahAccountingLogic`, `ShariahGovernanceLogic`, `ShariahRegistryLogic` (addresses in the broadcast file).

| Contract | Address | Notes |
|---|---|---|
| TestnetRegistryShortTimelock | `0x2D4AEFFA868aEf498fBa9B214ffa1F60a2A5986B` | 2-minute timelock, TESTNET ONLY |
| ZakatModule | `0x6E2B7B9c065Bb8669C75bcd95b7A31aB2559A1Ff` | v1 compat shim |
| TreasuryModule | `0xF590B3C9e8EfD25e1e13DcFd718AA6ADF1B9a957` | feeSource = vault |
| ShariahVaultV2 (Conservative) | `0x2046b3e560d578f8907ca4ec3812Be1CEd5f60fB` | Primary vault |
| CharityModule | `0x29BdD154b3e33Fc7913cbb946BAC95D017A52754` | escrow wired |
| PurificationEscrow | `0x1511c7f141aC1C13305af3aCBDE1ead68dEa8207` | |
| GoldExchangeAdapter (S2-H) | `0x82Dc6699957913a74Df58237c4fC8416CB8d189c` | |
| GoldAllocationAdapter (S6-H) | `0xD8f359a80942F5E3897e1cbf23273Cf9bC13a3E2` | |
| ShariahScoreAggregator | `0x1eb5Fc5832f8dD5943C2bF4F3c0Cf615c5Adb19a` | |
| RiskTieredExecutor | `0x6FBdbf49880650f3FAb02f0C4C133bD0881266C8` | vault manager |
| MockAllocatedGold (PAXG) | `0x4e22e749cada3Da6Fd9A08cdbf2f89876a45385e` | Testnet mock only |
| MockXAUT | `0xFFC25A26B0123fD7f39C87f19bBdb2a49ECe294a` | Testnet mock only |
| MockXauUsdAggregator | `0x6d2ec4355c9c08aCcda6732b09f5d4776CBEEC52` | Testnet mock only |
| MockUniswapV3PoolXAUT | `0x0179b906669e754De5996E4557C781b56bbBce19` | Testnet mock only |

The registry and gold adapters are fresh, so adapter screenings from run 2 must be repeated.

---

## Deploy batch — 2026-10-28 run 2 (SUPERSEDED by run 3)

Script: `contracts/script/Rehearsal.s.sol` → `step1_deploy()`  
Deployer: `0x3D23214d59CA3582628FffFE44D0Df1CC73D98f9`  
Block: (from broadcast file `run-1793187743752.json`)

| Contract | Address | Notes |
|---|---|---|
| TestnetRegistryShortTimelock | `0x23836611FDF05fAc07a12416e9c8C250F9cdF671` | Fixed — uses `proposeScreeningTestnet` / `executeScreeningTestnet` |
| ZakatModule | `0xB3fC6A662196EE2c424B6bdfBf9343d96d29569c` | v1 compat shim |
| TreasuryModule | `0xF5B550B87476a4359f1307AeFC425cCC6E2530f5` | Shariah fee recipient |
| ShariahVaultV2 (Conservative) | `0xba094D5B01F4fd245EA345Be6B8ac833488c81B0` | Primary rehearsal vault |
| CharityModule | `0x1D05a0010C78B984b0De2735A6E868E9c9f5d99F` | |
| PurificationEscrow | `0xcC58b11c3Cd251a44989fEf1f05BdcB0e16375ff` | |
| GoldExchangeAdapter (S2-H) | `0x55907Fc4E60A5353D9afD17D56F229192Fd9c3ED` | Mandatory oracle wired at construction |
| GoldAllocationAdapter (S6-H) | `0x04FdFd46F0c93569F3b592C106dDc292fc2f975C` | |
| ShariahScoreAggregator | `0x13340E36E59F8b504faD9B1b731D51fde1697C8A` | |
| RiskTieredExecutor | `0xA800540A029120C475c15345d5D65FB9C898d85c` | |
| MockAllocatedGold (PAXG) | `0x90476D68572E615a1E1447928c8c5d8AABaC6B51` | Testnet mock only |
| MockXAUT | `0xC57b6125d2a15C09E3624eb78df06e407F6A9912` | Testnet mock only |
| MockXauUsdAggregator | `0x214a54F86B84589068Cf459749344b1F637A60f7` | Testnet mock only |
| MockUniswapV3PoolXAUT | `0x6A46a3A9608437e832510EfD16a21898dA02dc66` | Testnet mock only; seeded with MockXAUT only |

---

## Known constant addresses (Arc Testnet)

| Token | Address | Decimals | Notes |
|---|---|---|---|
| USDC (ERC-20) | `0x3600000000000000000000000000000000000000` | 6 | Native gas asset on Arc; also ERC-20 |
| CCTP TokenMessengerV2 | `0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA` | — | CCTP domain 26 |

Note: PAXG, XAUT, and Chainlink XAU/USD feeds are not deployed on Arc Testnet.  
MockAllocatedGold, MockXAUT, and MockXauUsdAggregator are now deployed — see batch above.
