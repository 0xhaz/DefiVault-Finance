# Implementation Plan: Two-Community Vault System

## Summary
Two parallel vault ecosystems for two user communities — Conventional and Shariah — each with its own scoring system, fee structure, and fully isolated TreasuryModule contract. Capital never mixes between communities. ETH, PAXG, USDC, USDT, and RWA tokens (OUSG, BUIDL) are all permitted in the Shariah vault; it is the *protocol action* (borrowing at interest, perp funding) that is haram, not the asset itself.

---

## Architecture

- **Blockchain**: Arc Testnet (EVM, USDC native gas)
- **Conventional fee model**: Admin fee only — flat 0.75% of AUM annually, accrued per block, no profit share
- **Shariah fee model**: Hybrid Wakala + Musharakah — 0.5% AUM Wakala fee + 10% profit-share above 4% hurdle
- **Treasury**: Two fully isolated TreasuryModule contracts — ConventionalTreasury and ShariahTreasury
- **Frontend**: 3-tier VaultPicker (Passive · Aggressive · Shariah), per-community strategy panels
- **Wallet**: ConnectKit (existing)

---

## Permitted Asset Scope (Shariah Vault)

| Asset | Shariah Status | Basis |
|---|---|---|
| USDC | Permitted | Stablecoin, not interest-bearing by itself |
| USDT | Permitted | Same as USDC |
| ETH | Permitted | Productive asset; staking yield from validation work (not lending) |
| PAXG | Universally halal | Physical gold-backed, 1:1 Brinks custody |
| OUSG / BUIDL / RWA tokens | Permitted as assets | Asset ownership is halal; only riba-based *use* (pledging as Aave collateral) is excluded |

**Excluded actions** (regardless of asset): borrowing at interest (Aave lending), receiving perpetual funding (riba), front-running flows (gharar).

---

## Conventional Strategies (unchanged — S1–S4)

All 4 original strategies remain exactly as built. Fee: 0.75% AUM admin only.

---

## Shariah Strategies (5 strategies, replacing all 4 originals)

### S1-H: USDC/ETH Cross-Chain Spread (every 30s)
- **Instrument**: USDC/ETH price ratio across Uniswap V3 pools on Arbitrum, Base, OP
- **Signal**: Max cross-chain ETH/USDC deviation (ETH is a commodity — arbitrage is permitted)
- **Rule**: Spread ≥ 0.3% → actionable
- **Shariah basis**: Price arbitrage on a commodity pair — no interest, no speculation
- **Score**: ≥0.5% → 90, ≥0.3% → 75, ≥0.15% → 45, below → 15

### S2-H: Tokenized Gold Spread (every 30s)
- **Instrument**: PAXG/USDC Uniswap V3 pools on Arbitrum vs Base vs Mainnet
- **Signal**: Cross-chain PAXG/USDC deviation
- **Rule**: Spread ≥ 0.3% → actionable
- **Shariah basis**: Gold arbitrage, universally halal
- **Score**: ≥0.5% → 90, ≥0.3% → 75, ≥0.15% → 45, below → 15

### S3-H: Halal LP — USDC/ETH or USDC/PAXG Pool (every 30s)
- **Instrument**: Uniswap V3 concentrated liquidity on USDC/ETH or USDC/PAXG
- **Signal**: Pool fee APY from real trading volume (no lending, no yield farming)
- **Rule**: Fee APY ≥ 8% → top score
- **Shariah basis**: Fee income from genuine trade activity = permitted musharakah in a pool
- **Score**: ≥8% → 90, ≥4% → 65, ≥2% → 40, below → 20

### S4-H: Commodity Murabaha (event-driven)
- **Instrument**: CommodityMurabahaAdapter — vault buys PAXG/ETH at spot, sells at disclosed markup
- **Signal**: Trade request event + markup %
- **Rule**: Size ≥ $10K AND markup ≥ 1.0% → actionable
- **Shariah basis**: Cost-plus sale, universally halal; profit fully disclosed upfront
- **Score**: markup ≥ 1.5% → 90, ≥1.0% → 70, no trade → 20

### S5-H: RWA/Sukuk Yield (every 45s)
- **Instrument**: Direct holding of OUSG, BUIDL, or SukukFi tokens — no lending protocol involved
- **Signal**: Distribution/NAV appreciation rate (annualized)
- **Rule**: APY ≥ 6% → actionable
- **Shariah basis**: Holding an asset-backed token and receiving its distributions = permitted; the vault never borrows against it
- **Score**: ≥10% → 90, ≥6% → 70, ≥3% → 40, below → 20

---

## Fee Structure

### Conventional Vault — Admin Fee Only
- Flat **0.75% per annum on AUM**, accrued per block
- No profit share, no entry/exit fee — simple and predictable
- Accrued to `ConventionalTreasury` contract exclusively
- `claimAdminFee()` callable by treasury owner to sweep to a receiver address

### Shariah Vault — Hybrid Wakala + Musharakah
- **Wakala fee**: 0.5% per annum on AUM, accrued per block, routes to `ShariahTreasury`
- **Musharakah profit-share**: 10% of realized profit above 4% hurdle rate
  - `hurdleAccrued = principal × 4% × (elapsed / 365 days)`
  - Vault takes 10% of surplus; depositors keep 90%
  - Routes to `ShariahTreasury` exclusively — never touches ConventionalTreasury
- **Zakat**: 2.5% of gross Musharakah profit deducted BEFORE the split, routed to `zakatWallet`

### Two Isolated TreasuryModule Contracts
Both `ConventionalTreasury.sol` and `ShariahTreasury.sol` are deployments of the same `TreasuryModule.sol` base with different constructor args. Each has:
- `pendingFees` counter (accrued but unclaimed)
- `totalFeesCollected` lifetime counter
- `claimFees(address receiver, uint256 amount)` — owner only
- `feeSource` address (the vault that feeds it — only that address can call `accrue`)
- `treasuryType` string ("Conventional" or "Shariah") — emitted in all events for indexing
- Full event log: `FeesAccrued`, `FeesClaimed`, `FeeSourceUpdated`
- Zero ability to receive funds from the other treasury's vault

---

## New Contracts

1. **contracts/TreasuryModule.sol** — base treasury; deployed twice:
   - `ConventionalTreasury`: `adminFeeBps=75` (0.75%), `treasuryType="Conventional"`
   - `ShariahTreasury`: `wakalaFeeBps=50` (0.5%), `musharakahShareBps=1000` (10%), `hurdleRateBps=400` (4%), `treasuryType="Shariah"`
   - `feeSource` — only this vault address can call `accrue()`
   - `pendingFees`, `totalFeesCollected`, `claimFees(receiver, amount)`
   - Full isolation: no cross-treasury calls possible

2. **contracts/ZakatModule.sol** — Shariah-only zakat router:
   - `zakatBps=250` (2.5%), 30-day timelock on `zakatWallet` change
   - `distributeZakat(uint256 grossProfit)` → `(zakatAmount, remaining)`
   - `totalZakatDistributed` public counter
   - Called by ShariahVault before Musharakah profit split

3. **contracts/ShariahVault.sol** — ERC-4626 for Muslim community:
   - Inherits AutonomousVault base
   - `shariahScreeningEnabled` bool — `deployCapital` reverts if adapter not on screen list
   - `permittedAssets` mapping (USDC, USDT, ETH, PAXG, OUSG, BUIDL — all set at deploy)
   - Integrates `ShariahTreasury` for fee accrual (wakala per block)
   - Integrates `ZakatModule` — called on `claimMusharakahProfit(uint256 grossProfit)`
   - `hurdlePrincipal`, `hurdleAccrued` for Musharakah calc
   - `screened` mapping: `address adapter → bool`; `setScreened(adapter, bool)` owner-only

4. **contracts/ConventionalVault.sol** — ERC-4626 for conventional community:
   - Inherits AutonomousVault base
   - Integrates `ConventionalTreasury` — accrues 0.75% AUM admin fee per block
   - No profit share, no zakat
   - `claimAdminFee()` callable by treasury owner

5. **contracts/ShariahScoreAggregator.sol** — separate aggregator for 5 Shariah strategies:
   - Strategy enum: `ETH_SPREAD=0`, `GOLD_SPREAD=1`, `HALAL_LP=2`, `MURABAHA=3`, `RWA_SUKUK=4`
   - `shariahCertified` bool per strategy (owner-set, represents Shariah board sign-off)
   - `getWinningShariahStrategy()` only returns certified strategies
   - Same Score struct + ring buffer as existing ScoreAggregator

6. **contracts/adapters/HalalLPAdapter.sol** — Uniswap V3 USDC/ETH or USDC/PAXG LP:
   - `tokenA`, `tokenB` set at deploy (owner picks the halal pair)
   - Mints concentrated LP position; `currentValue()` reads NonfungiblePositionManager

7. **contracts/adapters/CommodityMurabahaAdapter.sol** — Murabaha trade lifecycle:
   - `requestMurabaha(uint256 amount, uint256 markupBps, address buyer)` — buyer initiates
   - `executeMurabaha(uint256 tradeId)` — vault deploys capital, buys commodity at spot
   - `settleMurabaha(uint256 tradeId)` — buyer pays cost+markup; vault records profit
   - All terms stored onchain before execution (cost, markup, deadline)
   - Events: `MurabahaRequested`, `MurabahaExecuted`, `MurabahaSettled`

8. **contracts/adapters/RwaYieldAdapter.sol** — direct RWA token holding:
   - Holds OUSG or BUIDL tokens directly (no lending protocol)
   - `deploy(amount)` buys RWA tokens via their instant mint
   - `recall(amount)` redeems RWA tokens → USDC
   - `currentValue()` reads RWA token NAV oracle
   - Explicitly guards against any `approve` to lending protocols

---

## Files to Create / Modify

### New contracts
1. `contracts/TreasuryModule.sol` — base treasury, deployed as ConventionalTreasury + ShariahTreasury
2. `contracts/ZakatModule.sol` — 2.5% auto-zakat router with 30-day timelock
3. `contracts/ShariahVault.sol` — Shariah ERC-4626 with asset screening + Wakala/Musharakah fees
4. `contracts/ConventionalVault.sol` — Conventional ERC-4626 with 0.75% admin fee only
5. `contracts/ShariahScoreAggregator.sol` — 5-strategy aggregator for Shariah tier
6. `contracts/adapters/HalalLPAdapter.sol` — Uniswap V3 halal pair LP
7. `contracts/adapters/CommodityMurabahaAdapter.sol` — full Murabaha lifecycle
8. `contracts/adapters/RwaYieldAdapter.sol` — direct OUSG/BUIDL hold, no lending protocol

### Modified contracts
9. `contracts/RiskTieredExecutor.sol` — add `RiskTier.SHARIAH` (mask=all 5 Shariah strategies, minScore=75, cooldown=1h)

### New agent files
10. `server/shariah-strategies.ts` — 5 Shariah scorers (ETH spread, gold spread, halal LP, murabaha events, RWA yield)
11. Wire into `server/agent.ts` main loop alongside existing 4 conventional strategies

### New frontend files
12. `src/components/ZakatTracker.tsx` — total distributed, wallet, last distribution time
13. `src/components/FeeDisclosure.tsx` — all fee params displayed publicly
14. `src/components/TreasuryPanel.tsx` — per-community treasury: pending fees, total collected, claim button

### Modified frontend files
15. `src/components/VaultPicker.tsx` — add Shariah tier card (teal/gold accent, Scale icon, "Shariah Compliant" badge)
16. `src/pages/StrategiesPage.tsx` — Shariah tab: 5 strategy cards (S1-H through S5-H)
17. `src/pages/VaultPage.tsx` — Shariah section: FeeDisclosure + ZakatTracker + asset permit list
18. `src/pages/SettingsPage.tsx` — Shariah board approval status, zakatWallet field, treasury addresses

---

## Build Sequence

1. `TreasuryModule.sol` + `ZakatModule.sol` (no dependencies)
2. `ShariahVault.sol` + `ConventionalVault.sol` (depend on treasury modules)
3. `HalalLPAdapter.sol`, `CommodityMurabahaAdapter.sol`, `RwaYieldAdapter.sol`
4. `ShariahScoreAggregator.sol`
5. Extend `RiskTieredExecutor.sol` with SHARIAH tier
6. Security review all new contracts (balanced)
7. `server/shariah-strategies.ts` + wire into agent loop
8. Frontend: `ZakatTracker`, `FeeDisclosure`, `TreasuryPanel` components
9. Update `VaultPicker`, `StrategiesPage`, `VaultPage`, `SettingsPage`
10. Lint + typecheck

---

## Done When

- [ ] Both TreasuryModule deployments compile; ConventionalTreasury cannot receive ShariahVault fees
- [ ] `ZakatModule` 30-day timelock enforced on wallet change
- [ ] `ShariahVault.deployCapital()` reverts for unscreened adapters
- [ ] `ConventionalVault` accrues only admin fee — no profit-share logic present
- [ ] `CommodityMurabahaAdapter` stores all trade terms onchain before execution
- [ ] Agent scores all 5 Shariah strategies separately from 4 conventional strategies
- [ ] VaultPicker shows 3 tiers: Passive · Aggressive · Shariah
- [ ] Strategies page Shariah tab shows 5 cards with halal basis notes
- [ ] FeeDisclosure shows all params for the selected community
- [ ] ZakatTracker shows running total + last distribution
- [ ] TreasuryPanel shows pending fees per community, claimable by owner
- [ ] Lint/typecheck passes with zero errors
