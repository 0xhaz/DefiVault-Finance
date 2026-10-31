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

## Arc MAINNET hackathon demo — 2026-10-31 (chain 5042; unaudited, small amounts)

Owner-approved exception to the testnet-only rule. Full record, roles and example transactions: `docs/mainnet-hackathon-demo.md`. ShariahVaultV2 `0xDc40ed79F74141BBba84d54f84Eafd43CD8Bc470`, registry `0xb7b1cFEbB0390aA16945aCe518118d491016A793`, executor `0x23836611FDF05fAc07a12416e9c8C250F9cdF671`, aggregator `0x2b8dA7636aeb97C153F81C7168302dF45eD3643a`, treasury `0xf17585cB249EF6Ab8bB450595107DB34d46FfE91`, charity `0x99D53De353d32e34F18a21c8c760424FC92D01a9`, escrow `0x3dA4697D8154A794DaC1d63276072142ed7C1890`, zakat shim `0xf0f5A1f045136AD43ee03B1E3C703aEb3f1Ff941`.

---

## Deploy batch — 2026-10-31 run 6 (ACTIVE)

Script: `contracts/script/Rehearsal.s.sol:Rehearsal` → `step1_deploy()` (broadcast: `broadcast/Rehearsal.s.sol/5042002/step1_deploy-latest.json`, 39 transactions, all status 1, blocks 70015865 to 70016012, first tx `0x65ed46097783b689af328e95ff57bcdf803832fef7d2e8bdc063608edfd8261e`)  
Deployer, owner and testnet board: `0x3D23214d59CA3582628FffFE44D0Df1CC73D98f9` (single testnet key).  
Source: the head of the PR stack (#1 to #24), including N-33 and N-35 to N-41. Verified: the `ShariahVaultV2` runtime on chain is 24,414 bytes and matches `forge inspect ShariahVaultV2 deployedBytecode` except for library links and immutables (882 bytes, all explained).  
Run 5 is superseded: it predates N-33 and N-35 to N-41.

| Contract | Address | Notes |
|---|---|---|
| TestnetRegistryShortTimelock | `0xC38385015e2Bf2d73F832f01d7C73e37f523A188` | 2-minute timelock, Arc Testnet or local only (N-41) |
| ZakatModule | `0x44C7A194f40055488a85C79845eCf5AE012388f8` | v1 compat shim |
| TreasuryModule | `0x0B19d294A250eD18d99EB2B78213fB1F91B6AeD6` | feeSource = vault |
| ShariahVaultV2 (Conservative) | `0x682EA638a167cf812a5694ebCDb15Ae2516e75c6` | Primary vault |
| CharityModule | `0x166844F88CC45214f52642329d00d97314659cF9` | escrow wired |
| PurificationEscrow | `0xc242613D7739E2E83b9A2290c1fCf06B5B1b7C73` | |
| GoldExchangeAdapter (S2-H) | `0xeb4Ec01d020c01ffE8C1651Ed39f950036950dc4` | |
| GoldAllocationAdapter (S6-H) | `0xE6f20E0c173c8eCdd520A3D0Abe543cD929bd9d5` | |
| ShariahScoreAggregator | `0xDAb78c83EF0DF6778E79BA26dC4Bd21Ba39d1641` | |
| RiskTieredExecutor | `0xBd106C388b0ca97129F7F13e55d52e7c9Fc8AbAF` | vault manager |
| HalalLPAdapter (S3-H, USDC/EURC 0.05%) | `0xB0452Ac499bDF8F94F83cDc5cA64b4F06e1cd911` | `DeployHalalLP.s.sol`; pool from the testnet Uniswap V3 below |
| MockAllocatedGold (PAXG) | `0xE260b4307eA80C3B03BFEBCc26cD81Ec48A502A2` | Testnet mock only |
| MockXAUT | `0xa7AF135b82794246c03694f701A6253B4522162F` | Testnet mock only |
| MockXauUsdAggregator | `0xC7C78C39347cf9a4B980C8461349eae9f5000368` | Testnet mock only |
| MockUniswapV3PoolXAUT | `0x2F98AA588536e7aF3186520d9B941B3BE4B5d546` | Testnet mock only |
| CctpSettlementLogic (library) | `0x891453f2C318B79b92a1d4CAe1d308ca29a6F3c6` | |
| ShariahAccountingLogic (library) | `0x19151a9058843708E47F48E80b919333b3029AE1` | |
| ShariahGovernanceLogic (library) | `0x8e06d14D2a0551cFA2D1E23Ed037D28775128060` | |
| ShariahRegistryLogic (library) | `0xCe3aDB44203FaC0Ee90254e5dF8f9A9CA6Fd94C9` | |

## Uniswap V3 on Arc Testnet (deployed by us, 2026-10-31, LP-3)

Official Uniswap V3 code (byte-identical to the Arc mainnet deployment apart from immutables; see `contracts/script/uniswap-v3/PROVENANCE.md`), deployed with `contracts/script/DeployUniswapV3Testnet.s.sol` (broadcast: `broadcast/DeployUniswapV3Testnet.s.sol/5042002/run-latest.json`, 10 transactions, all status 1, from block 70015544) and seeded with `contracts/script/uniswap-v3/seed-testnet.sh`. Testnet only; WETH9 and the NFT descriptor are inert placeholders.

| Contract | Address | Notes |
|---|---|---|
| UniswapV3Factory | `0x212349EB7aC46556aBca4872C906DA937Bac95E6` | |
| NonfungiblePositionManager | `0xb628B1a433A8C9188c27886fCc7105D80C27eC05` | |
| SwapRouter02 | `0x3D9fCC1a29ce7ec531031342c6A030DFde228553` | |
| MockVolatile (MVOL) | `0x1f500146310A4F6f21dDd671B6F23232Dce2B361` | Testnet mock, permissionless mint, sorts below USDC |
| Pool USDC/EURC 0.05% | `0xf9FC660B168E8a2194725D008d85a8933Da8E590` | USDC token0, initialized at the mainnet price (tick -1089), cardinality 300, seeded about 9.6 USDC + 9 EURC in ticks -1600 to -600 |
| Pool MVOL/USDC 0.3% | `0x36B8E43d1270701e5E1539Ee1c9e23FaB4dCba63` | USDC token1, 1:1, cardinality 300, seeded 10 USDC + 10 MVOL full range |

Live check: a 0.1 USDC swap through SwapRouter02 returned 0.089616 EURC (tx `0x3ccace1b5e0452e22706de0453a86fada44f56d1cf0c146ea7a55a50cf8964d7`). This confirms the pool and NPM work with Arc's native-coin USDC.

---

## Deploy batch — 2026-10-31 run 5 (SUPERSEDED by run 6)

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
