# AutonomousVault — AI Capital Allocator

> Built with Arc Studio - money-powered apps in minutes

## What This App Does

An autonomous ERC-4626 vault powered by an AI agent that scans 5 DeFi data sources in real time, scores 4 strategies (0-100), and autonomously deploys capital into the winning opportunity — no human intervention required.

**Workflow (matches diagram):**
1. AI agent reads: Uniswap V3 spreads, Hyperliquid funding rates, Stargate bridge flows, Aave health factors, Ondo OUSG yields
2. Four scorers compute opportunity scores 0-100
3. ScoreAggregator contract stores scores on-chain
4. VaultExecutor.executeWinner() is called — permissionlessly — when top score ≥ threshold
5. PositionTracker manages open/close lifecycle with PnL

## Tech Stack

- Frontend: React 18, Vite, TypeScript, Tailwind CSS (Arc Dark theme)
- Web3: wagmi v2, viem v2, ConnectKit
- Contracts: Solidity 0.8.28 + Foundry (4 contracts)
- AI Agent: Bun + Express + viem (server/agent.ts, port 3001)
- Chain: Arc Testnet (Chain ID 5042002)
- Token: USDC (ERC-4626 underlying asset)

## Smart Contracts

| Contract | File | Purpose |
|---|---|---|
| AutonomousVault | contracts/AutonomousVault.sol | ERC-4626 vault, manager role, allocation cap |
| ScoreAggregator | contracts/ScoreAggregator.sol | Stores 4 strategy scores, ring-buffer history |
| VaultExecutor | contracts/VaultExecutor.sol | Permissionless executeWinner(), cooldown + gas guard |
| PositionTracker | contracts/PositionTracker.sol | Position lifecycle + PnL tracking |

## Deployed Contract Addresses

*(Update after deploying — run `bun run contracts:build` then deploy each contract)*

- VITE_VAULT_ADDRESS=
- VITE_AGGREGATOR_ADDRESS=
- VITE_EXECUTOR_ADDRESS=
- VITE_TRACKER_ADDRESS=

Set these in `.env` to activate live on-chain data in the dashboard.

## Key Files

- `src/App.tsx` — main layout (thin composition root)
- `src/components/VaultStats.tsx` — totalAssets, deployed, PnL
- `src/components/StrategyScores.tsx` — live 0-100 score bars per strategy
- `src/components/ActivePositions.tsx` — open positions table
- `src/components/AgentActivityFeed.tsx` — live event stream (contract events + heartbeats)
- `src/components/VaultActions.tsx` — Deposit / Redeem / Execute buttons
- `src/components/AgentStatus.tsx` — agent health, market data, last scores
- `src/contracts.ts` — ABIs and contract addresses
- `server/agent.ts` — autonomous AI agent loop

## To Run

```bash
# Terminal 1: frontend
bun run dev

# Terminal 2: AI agent
bun run agent
```

## Post-Deploy Setup

After deploying all 4 contracts:
1. Set the 4 `VITE_*` addresses in `.env`
2. Call `vault.setManager(executorAddress)` so VaultExecutor can deploy capital
3. Call `aggregator.setOracle(agentWalletAddress)` so the agent can write scores
4. Call `tracker.setReporter(executorAddress)` so VaultExecutor can track positions
5. Configure strategy targets with `executor.setStrategyConfig(...)` for each strategy
