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

## Deploy batch — 2026-10-28 run 2 (ACTIVE)

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
