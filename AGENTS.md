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

## Shariah Vault Revision Tracker

Work order (each task = one branch/PR per the one-task-per-branch rule):

| Task | Items | Status |
|---|---|---|
| A | ShariahVaultV2 with pronoucement hash + expiry gate | DONE |
| B | GoldExchangeAdapter S2-H atomic USDC/PAXG swap | DONE |
| C | CharityModule separate contract + ZakatModule @deprecated | DONE |
| D | Server-side Shariah screening engine (advisory only) | DONE |
| E | S6-H GoldAllocationAdapter (XAUT, oracle-checked) | DONE |
| F | MockXAUT + MockUniswapV3PoolXAUT test helpers | DONE |
| G | G1–G15 safety fixes (G4: board role via timelock; G11: test count policy) | DONE |
| H | PR1 gold haircut / PR2 purification timelock / PR3 depositor fairness | DONE |
| I | I1–I5 hardening: settle verification, S2-H PR1 parity, HWM calc, single-source board, registry constructor | DONE |
| J | J1 atomic settleCrossChainWithMessage; J2 dustThreshold deposit pause + S2-H oracle freshness; J3 RegistryRequired; J4 invariant suite | DONE |

**J4 invariant suite**: `contracts/test/invariant/VaultInvariant.t.sol` — 6 invariants, 256 runs × depth 50.
Run with: `forge test --match-path 'contracts/test/invariant/*' --invariant-runs 256 --invariant-depth 50`

**Test status**: 399/399 Foundry tests pass (512 fuzz runs). 48/48 bun screening tests pass.

**Board review items**: SR-001 through SR-022 — all REVIEW, none approved. See `docs/agents/SHARIAH_REVIEW.md`.

**Hard rules (never violate)**:
- Testnet only; no mainnet deploys
- Never reorder `ShariahStrategy` enum — deprecate or append only
- No forced migration — v1 redemptions always available at NAV
- Every Shariah parameter is board-settable via timelock; safety caps stay hard-coded
- Never use "certified", "halal", "sukuk", or "Zakat" in code or UI without a board pronouncement
- One task per branch/PR
- Agent role boundary: implement screens and flags only; never declare an adapter halal/certified
