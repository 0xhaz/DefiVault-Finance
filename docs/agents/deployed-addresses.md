# Deployed Contract Addresses

All deployments are to **Arc Testnet** (chain ID 5042002).  
This file is the canonical address record — update after every deploy broadcast.  
AGENTS.md points here; do not record addresses elsewhere.

---

## Status

No contracts have been deployed yet. This file will be populated after the first testnet deployment using `DeployShariahV2.s.sol` and `DeployGoldAllocation.s.sol`.

---

## When populated, record in this format

```
## Deploy batch — YYYY-MM-DD

| Contract | Address | Tx hash | Deploy script |
|---|---|---|---|
| TreasuryModule (Conventional) | 0x... | 0x... | DeployCreate2.s.sol |
| TreasuryModule (Shariah) | 0x... | 0x... | DeployCreate2.s.sol |
| ZakatModule (v1 compat) | 0x... | 0x... | DeployCreate2.s.sol |
| ShariahScoreAggregator | 0x... | 0x... | RedeployShariahAggregator.s.sol |
| ScoreAggregator | 0x... | 0x... | DeployCreate2.s.sol |
| ConventionalVault (Passive) | 0x... | 0x... | DeployCreate2.s.sol |
| ConventionalVault (Aggressive) | 0x... | 0x... | DeployCreate2.s.sol |
| ShariahVault (Conservative) | 0x... | 0x... | DeployCreate2.s.sol |
| ShariahVault (Dynamic) | 0x... | 0x... | DeployCreate2.s.sol |
| RiskTieredExecutor (Passive) | 0x... | 0x... | DeployCreate2.s.sol |
| RiskTieredExecutor (Aggressive) | 0x... | 0x... | DeployCreate2.s.sol |
| RiskTieredExecutor (Conservative) | 0x... | 0x... | DeployCreate2.s.sol |
| RiskTieredExecutor (Dynamic) | 0x... | 0x... | DeployCreate2.s.sol |
| MockAllocatedGold (PAXG testnet) | 0x... | 0x... | DeployGoldAllocation.s.sol |
| MockXAUT | 0x... | 0x... | DeployGoldAllocation.s.sol |
| MockXauUsdAggregator | 0x... | 0x... | DeployGoldAllocation.s.sol |
| MockUniswapV3PoolXAUT | 0x... | 0x... | DeployGoldAllocation.s.sol |
| GoldExchangeAdapter | 0x... | 0x... | DeployGoldAllocation.s.sol |
| GoldAllocationAdapter | 0x... | 0x... | DeployGoldAllocation.s.sol |
| CharityModule | 0x... | 0x... | DeployShariahV2.s.sol |
| PurificationEscrow | 0x... | 0x... | DeployShariahV2.s.sol |
| ShariahAdapterRegistry | 0x... | 0x... | DeployShariahV2.s.sol |
| ShariahVaultV2 (Conservative) | 0x... | 0x... | DeployShariahV2.s.sol |
| ShariahVaultV2 (Dynamic) | 0x... | 0x... | DeployShariahV2.s.sol |
```

---

## Known constant addresses (Arc Testnet)

| Token | Address | Decimals | Notes |
|---|---|---|---|
| USDC (ERC-20) | `0x3600000000000000000000000000000000000000` | 6 | Native gas asset on Arc; also ERC-20 |
| CCTP TokenMessengerV2 | `0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA` | — | CCTP domain 26 |

Note: PAXG, XAUT, and Chainlink XAU/USD feeds are **not** deployed on Arc Testnet.  
MockAllocatedGold, MockXAUT, and MockXauUsdAggregator must be deployed before any gold strategy tests.
