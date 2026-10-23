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
| K | K1 CCTP V2 feeExecuted decode + CrossChainFeeDeducted emit + 3 new K1 tests (fee=0, fee>0, fee+strategy-loss); K2 GoldExchangeAdapter mandatory oracle + onlyBoard rename in CharityModule; PR2 invariant suite extended to 8 invariants + 17 handler actions (cross-chain, losses, no-dilution, cap); PR3 README sync (class diagram, flow diagram, adapter table, security model); PR4 Rehearsal.s.sol + docs/rehearsal.md | DONE |
| L | L1 CctpMessageDecoder offset corrected (feeExecuted at body[164..195], not body[132..163] which is maxFee); MIN_MESSAGE_LEN raised to 344; all 4 message builders updated; 2 new L1 tests (body-too-short revert, golden fixture); L2 audit: 396 non-invariant tests confirmed intact — README count of 353 was a doc error; L3 README fixes (J2 oracle mandatory note, K1 offset note, foundry.toml invariant note) | DONE |

**Invariant suite**: `contracts/test/invariant/VaultInvariant.t.sol` — 8 invariants, 17 handler actions.
Runs/depth set in `foundry.toml` [profile.default.invariant]: runs=256, depth=50.
Run with: `forge test --match-path 'contracts/test/invariant/*'`

**Test status**: 398/398 non-invariant Foundry tests pass (512 fuzz runs). 8/8 invariants pass (256 runs x depth 50). 48/48 bun screening tests pass.

**Known**: TreasuryModule feeSource placeholder issue in Rehearsal.s.sol — noted in docs/rehearsal.md, redeploy required before live profit claims. MSG_TRANSMITTER on Arc Testnet must be confirmed from Circle docs before step 5 of rehearsal. L4 (live rehearsal run) not yet executed.

**Board review items**: SR-001 through SR-022 — all REVIEW, none approved. See `docs/agents/SHARIAH_REVIEW.md`.

**Hard rules (never violate)**:
- Testnet only; no mainnet deploys
- Never reorder `ShariahStrategy` enum — deprecate or append only
- No forced migration — v1 redemptions always available at NAV
- Every Shariah parameter is board-settable via timelock; safety caps stay hard-coded
- Never use "certified", "halal", "sukuk", or "Zakat" in code or UI without a board pronouncement
- One task per branch/PR
- Agent role boundary: implement screens and flags only; never declare an adapter halal/certified
