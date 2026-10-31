# Build submission text

Copy each block into the matching field of the "Create a new Build" form.

## Logo

Upload `public/brand/defivault-logo.png` (512 x 512). The source is `public/brand/defivault-logo.svg`.

## Name of your Build

```
DeFiVault Finance
```

## Brief description

```
An AI-guided USDC vault on Arc, with a Shariah-screened tier that shares profit instead of paying interest.
```

## Tags

```
DeFi, AI Agent, USDC, Arc, Stablecoin, ERC-4626, Islamic Finance, Circle CCTP, Uniswap V3
```

## Links

| Field | Value |
|---|---|
| Website | https://defi-vault-finance.vercel.app |
| GitHub Repo | https://github.com/0xhaz/DefiVault-Finance |
| Video | (your walkthrough video link) |
| Other | https://explorer.arc.io/address/0xDc40ed79F74141BBba84d54f84Eafd43CD8Bc470 |

## Description (Markdown editor)

```markdown
## The problem

Yield in DeFi moves fast. Keeping capital in the best opportunity means watching many venues at once, and most depositors can't. For Muslim savers it is harder still: most on-chain yield is interest-based, and products that say they avoid interest rarely show how profit is shared, how non-permissible income is removed, or who decides what is allowed.

## How it works

DeFiVault is an ERC-4626 vault for USDC on Arc. You deposit once and receive shares priced from the vault's net asset value.

1. An AI agent reads live market data every 30 to 60 seconds (Uniswap pools on four chains, Hyperliquid funding, Stargate bridge flows, Aave positions, tokenized treasury yields) and scores each strategy from 0 to 100.
2. The scores are written on-chain to a score aggregator.
3. Anyone can call `executeWinner()`. The executor checks the tier's minimum score, cooldown, gas ceiling and allowed strategies, sizes the deployment within the vault's limits, and the vault funds the strategy.
4. Losses are marked into the share price immediately; gains count only once realized.
5. In the Shariah tier, every profit distribution runs a fixed waterfall: purification of non-permissible income, a charity contribution, then the Musharakah split, where the manager earns 10% only above a 4% hurdle.

The agent never holds or moves user funds. It only publishes scores, and the contracts enforce every limit.

## Key features

- Four risk tiers in separate vaults: Passive and Aggressive (conventional), Conservative and Dynamic (Shariah).
- Live AI scoring with a plain-language reason for every score, shown in the app.
- An advisory Shariah screen (11 rules) on every protocol. Only the board can approve a strategy: adapters need an on-chain screening with a 30-day timelock and an expiry date.
- Every Shariah parameter changes only through a board proposal and a 30-day timelock. Safety caps (80% max deployed, 30% gold cap) are fixed in code.
- Redemptions are never blocked by oracles, and an exit settles the leaver's share of the profit waterfall so the cost never falls on the holders who stay.
- Cross-chain capital through Circle CCTP V2, limited to board-approved recipients.
- An in-app user guide with diagrams of every flow.

## Tech stack

- Contracts: Solidity 0.8.28, Foundry, OpenZeppelin ERC-4626, four linked libraries to fit the 24 KB limit.
- Chain: Arc (USDC as gas), Circle CCTP V2.
- AI agent: Bun, Express and viem, hosted on Railway.
- App: React, Vite, TypeScript, Tailwind, wagmi and viem, hosted on Vercel.
- Testing: 2,097 Foundry tests including 8 invariants, fork tests against Circle CCTP on Arc Testnet and against Uniswap's real USDC/EURC pool on an Arc mainnet fork, Slither and Aderyn static analysis.

## Live on Arc mainnet

- Vault: [0xDc40ed79F74141BBba84d54f84Eafd43CD8Bc470](https://explorer.arc.io/address/0xDc40ed79F74141BBba84d54f84Eafd43CD8Bc470)
- USDC deposit: [0xaec64e1e…c1011d](https://explorer.arc.io/tx/0xaec64e1e7f47eecc6c32c6245df2283868bdf68a302f81f7c82069a0ffc1011d)
- USDC redeem: [0x0a734ab9…18e30de](https://explorer.arc.io/tx/0x0a734ab9a97e8929e2eb2f07bcaaa41f4dc949efb1ca21e14e134376518e30de)
- App: https://defi-vault-finance.vercel.app
- Agent API: https://defivault-finance-production.up.railway.app/status

On Arc Testnet the full loop also ran live: we deployed the official Uniswap V3 contracts, and `executeWinner()` funded a real liquidity position through the vault and recalled it at a 0.05% round-trip cost.

## Built with Arc Studio

The contracts, tests, agent, app and deployment scripts were built in Arc Studio.

## Status

This is an unaudited demo. Governance is held by single keys, and no Shariah board has ruled on the strategies yet, so the mainnet vault holds deposits idle until an adapter completes its 30-day screening. Next steps: an independent audit, board rulings, multisig governance, and letting the agent sign its own score updates.
```
