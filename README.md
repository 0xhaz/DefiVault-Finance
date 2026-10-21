# DeFiVault Finance

**Autonomous, AI-powered DeFi capital allocation on Arc Testnet**  
Live at [defivault.finance](https://defivault.finance) · USDC-native

DeFiVault is an ERC-4626 vault protocol with four risk tiers across two communities — Conventional and Shariah. An on-chain AI agent continuously scores strategies, routes capital through protocol adapters, and executes the winning strategy on every cycle. All fees are transparent and on-chain; Shariah vaults auto-route charitable contributions before any profit split.

**Current revision (Oct 2026):** Phase 2 complete. OUSG/BUIDL removed from the Shariah tier (SR-001); gold exchanges enforced as atomic single-transaction swaps for yad bi yad compliance (S2-H); S6-H XAUT Gold Allocation adapter added with Chainlink oracle + pool deviation guard and 30-day timelock on all board-settable parameters; `ShariahScoreAggregator` extended to 6 strategies; combined gold cap `MAX_GOLD_BPS = 3000` (30%) enforced across S2-H + S6-H. 242 tests green. Board rulings SR-001 through SR-011 in `docs/agents/SHARIAH_REVIEW.md`.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Vault Tiers](#vault-tiers)
3. [Contract Hierarchy](#contract-hierarchy)
4. [Core Contracts](#core-contracts)
5. [Strategy Adapters](#strategy-adapters)
6. [Agent Scoring System](#agent-scoring-system)
7. [Execution Workflow](#execution-workflow)
8. [Cross-Chain Flow](#cross-chain-flow)
9. [Shariah Compliance Workflow](#shariah-compliance-workflow)
10. [Fee Architecture](#fee-architecture)
11. [Zakat Distribution](#zakat-distribution)
12. [Security Model](#security-model)
13. [Test Coverage](#test-coverage)
14. [Deployment](#deployment)

---

## Architecture Overview

```mermaid
graph TB
    subgraph UI ["DeFiVault Frontend (React + Vite)"]
        LP[Landing Page]
        VP[Vault Picker]
        SP[Strategies Page]
        DP[Dashboard]
    end

    subgraph Agent ["AI Agent Server (Express)"]
        SA[Strategy Scorers]
        SS[Shariah Scorers]
        CP[CCTP Attestation Poller]
        AC["API: /api/status · /api/shariah · /api/tiers"]
    end

    subgraph Conventional ["Conventional Vaults"]
        CV_P[ConventionalVault · Passive]
        CV_A[ConventionalVault · Aggressive]
        RTE_P[RiskTieredExecutor · PASSIVE]
        RTE_A[RiskTieredExecutor · AGGRESSIVE]
        AGG[ScoreAggregator]
        CT[TreasuryModule · Conventional]
    end

    subgraph Shariah ["Shariah Vaults"]
        SV_C[ShariahVault · Conservative]
        SV_D[ShariahVault · Dynamic]
        RTE_SC[RiskTieredExecutor · SHARIAH_CONSERVATIVE]
        RTE_SD[RiskTieredExecutor · SHARIAH_DYNAMIC]
        SAGG[ShariahScoreAggregator]
        ST[TreasuryModule · Shariah]
        ZM[ZakatModule]
    end

    subgraph Adapters ["Protocol Adapters"]
        COMP[CompoundAdapter]
        CURVE[CurveAdapter]
        AAVE[AaveLoopAdapter]
        GMX[GmxAdapter]
        HLP[HalalLPAdapter]
        MUR[CommodityMurabahaAdapter]
        RWA[RwaYieldAdapter]
    end

    CCTP[Circle CCTP · TokenMessengerV2]

    UI --> Agent
    SA --> AGG
    SS --> SAGG
    RTE_P --> CV_P
    RTE_A --> CV_A
    RTE_SC --> SV_C
    RTE_SD --> SV_D
    CV_P --> CT
    CV_A --> CT
    SV_C --> ST
    SV_C --> ZM
    SV_D --> ST
    SV_D --> ZM
    CV_P --> COMP
    CV_P --> CURVE
    CV_A --> AAVE
    CV_A --> GMX
    SV_C --> HLP
    SV_C --> RWA
    SV_D --> HLP
    SV_D --> MUR
    SV_D --> RWA
    CV_P --> CCTP
    CV_A --> CCTP
    SV_C --> CCTP
    SV_D --> CCTP
```

---

## Vault Tiers

| Tier | Type | Strategies | Min Score | Cooldown | Fee Model |
|---|---|---|---|---|---|
| **Passive** | Conventional | S1 Cross-chain Spread, S4 RWA Yield | 80 | 2h | 0.75% AUM |
| **Aggressive** | Conventional | S1–S4 all | 60 | 30m | 0.75% AUM |
| **Conservative** | Shariah | S2-H Gold Spread, S3-H Halal LP, S6-H Gold Allocation | 80 | 2h | 0.5% Wakala |
| **Dynamic** | Shariah | S1-H through S4-H + S6-H (S5-H retired) | 70 | 1h | 0.5% Wakala + 10% Musharakah |

Each tier is a separate vault deployment (independent NAV, independent share token) — capital from one tier never mixes with another.

---

## Contract Hierarchy

```mermaid
classDiagram
    class ERC4626 {
        <<OpenZeppelin>>
        +deposit()
        +redeem()
        +totalAssets()
    }

    class AutonomousVault {
        +manager: address
        +totalDeployed: uint256
        +maxAllocationBps: uint256
        +sourceDomain: uint32
        +deployCapital()
        +deployCrossChain()
        +returnCapital()
        +recallCapital()
        +settleCrossChain()
    }

    class ConventionalVault {
        +conventionalTreasury: TreasuryModule
        +accrueAdminFee()
        +sweepFeesToTreasury()
        +name() cvUSDC_name
        +symbol() cvUSDC
    }

    class ShariahVault {
        +shariahTreasury: TreasuryModule
        +zakatModule: ZakatModule
        +shariahScreeningEnabled: bool
        +screened: mapping
        +deployCapital() override
        +claimMusharakahProfit()
        +sweepFeesToTreasury()
        +name() svUSDC_name
        +symbol() svUSDC
    }

    class TreasuryModule {
        +feeSource: address
        +adminFeeBps: uint256
        +musharakahShareBps: uint256
        +hurdleRateBps: uint256
        +accrue()
        +claimFees()
        +calculateMusharakahSplit()
    }

    class ZakatModule {
        +ZAKAT_BPS: 250
        +TIMELOCK_PERIOD: 30 days
        +distributeZakat()
        +proposeZakatWalletChange()
        +confirmZakatWalletChange()
    }

    ERC4626 <|-- AutonomousVault
    AutonomousVault <|-- ConventionalVault
    AutonomousVault <|-- ShariahVault
    ShariahVault --> TreasuryModule
    ShariahVault --> ZakatModule
    ConventionalVault --> TreasuryModule
```

---

## Core Contracts

### `AutonomousVault.sol`

Base ERC-4626 vault. All four tier vaults inherit this.

| Feature | Detail |
|---|---|
| Asset | USDC (6 decimals) |
| Share decimals offset | +6 (12 total) — inflation-attack protection |
| Max allocation cap | 80% of `totalAssets()` by default (configurable up to 95%) |
| Manager role | Single address that can call `deployCapital` and `deployCrossChain` |
| CCTP | Immutable `sourceDomain` set at construction; `tokenMessenger` configurable |
| Cross-chain accounting | `pendingCrossChain[nonce]` tracks outbound capital until `settleCrossChain` |

Key functions:

```solidity
function deployCapital(address strategy, uint256 amount, bytes calldata data) public virtual
function deployCrossChain(uint32 destDomain, bytes32 recipient, uint256 amount) external
function returnCapital(address strategy, uint256 amount) external
function recallCapital(address adapter, uint256 amount) external
function settleCrossChain(uint64 nonce) external
```

### `ConventionalVault.sol`

Inherits `AutonomousVault`. Adds admin fee accrual (0.75% AUM, pro-rated per second).

### `ShariahVault.sol`

Inherits `AutonomousVault`. Overrides `deployCapital` to enforce:
1. Adapter must be in `screened` mapping
2. Asset must be in `permittedAssets` mapping (USDC, ETH, PAXG, OUSG, USDT, BUIDL)
3. Wakala fee accrued on every deployment

### `RiskTieredExecutor.sol`

One instance per vault tier. Reads the winning strategy from the aggregator and routes execution.

```mermaid
flowchart LR
    EW[executeWinner] --> GC{gas price OK?}
    GC -- No --> GP[revert GasPriceTooHigh]
    GC -- Yes --> CD{cooldown elapsed?}
    CD -- No --> CDE[revert CooldownNotElapsed]
    CD -- Yes --> GWS[getWinningStrategy]
    GWS --> SC{score >= minScore?}
    SC -- No --> SL[revert ScoreTooLow]
    SC -- Yes --> BM{strategy in bitmask?}
    BM -- No --> SM[revert StrategyNotAllowed]
    BM -- Yes --> AE{adapter enabled?}
    AE -- No --> SD[revert StrategyDisabled]
    AE -- Yes --> DD{destDomain == 0?}
    DD -- Local --> VC[vault.deployCapital]
    DD -- Remote --> VX[vault.deployCrossChain]
```

Tier parameters:

| Tier | `minScoreToExecute` | `executionCooldown` | `maxGasPrice` | `strategyMask` |
|---|---|---|---|---|
| PASSIVE | 80 | 2h | 20 gwei | `9` — `0b001001` (bits 0+3) |
| AGGRESSIVE | 60 | 30m | 50 gwei | `15` — `0b001111` (bits 0–3) |
| SHARIAH_CONSERVATIVE | 80 | 2h | 30 gwei | `38` — `0b100110` (bits 1+2+5) |
| SHARIAH_DYNAMIC | 70 | 1h | 30 gwei | `47` — `0b101111` (bits 0–3+5) |

### `ScoreAggregator.sol`

Stores scores for 4 conventional strategies. Ring-buffer of 10 history slots per strategy. 5-minute staleness guard.

```solidity
enum Strategy {
    STABLECOIN_SPREAD,    // S1 — USDC/USDT cross-chain
    FUNDING_RATE_ARB,     // S2 — Hyperliquid perp funding
    BRIDGE_FLOW,          // S3 — Stargate bridge flow
    LIQUIDATION_RWA       // S4 — Aave liquidation + Ondo RWA
}
```

### `ShariahScoreAggregator.sol`

Parallel aggregator for 6 Shariah strategies. Adds `shariahCertified` bool per strategy — only certified strategies can win. Enum order is fixed (append-only); deprecated slots revert `StrategyDeprecated`.

```solidity
enum ShariahStrategy {
    ETH_SPREAD,       // 0  S1-H USDC/ETH cross-chain spread      — certified
    GOLD_SPREAD,      // 1  S2-H PAXG/USDC atomic swap             — certified
    HALAL_LP,         // 2  S3-H Uniswap V3 swap-fee income        — certified
    MURABAHA,         // 3  S4-H Commodity Murabaha                 — certified
    RESERVED_4,       // 4  S5-H (RWA/Sukuk) — DEPRECATED (SR-001); writeScore(4,...) reverts
    GOLD_ALLOCATION   // 5  S6-H XAUT spot position                 — NOT YET certified (SR-008 pending)
}
```

### `TreasuryModule.sol`

Accounting-only fee ledger. Actual USDC transfer happens only when the vault calls `sweepFeesToTreasury`.

- **Conventional**: `adminFeeBps = 75` (0.75%), `musharakahShareBps = 0`
- **Shariah**: `adminFeeBps = 50` (0.5% Wakala), `musharakahShareBps = 1000` (10%), `hurdleRateBps = 400` (4%)

`claimFees` is accounting-only — it decrements `pendingFees` and emits the event; the caller must separately trigger `sweepFeesToTreasury` on the vault to move actual tokens. Fee sweeps are capped to `pendingFees` to prevent draining depositor principal.

### `ZakatModule.sol`

Auto-routes 2.5% of Shariah gross profit to a charity wallet before the Musharakah split.

- Zakat rate: fixed at `ZAKAT_BPS = 250` (2.5%), non-adjustable
- Wallet changes: 30-day timelock via `proposeZakatWalletChange` → `confirmZakatWalletChange`
- Only the bound vault can call `distributeZakat`

### `PositionTracker.sol`

Tracks open positions per vault, including cross-chain `destinationDomain`, PnL accounting, and position lifecycle (OPEN → CLOSED).

---

## Strategy Adapters

All adapters implement `IStrategyAdapter`:

```solidity
interface IStrategyAdapter {
    function deploy(uint256 amount) external returns (uint256 deployed);
    function recall(uint256 amount) external returns (uint256 returned);
    function currentValue() external view returns (uint256);
    function protocolName() external view returns (string memory);
    function vault() external view returns (address);
}
```

Only the vault can call `deploy` and `recall` (enforced by `onlyVault` modifier on every adapter).

| Adapter | Protocol | Tier(s) | Strategy | Status |
|---|---|---|---|---|
| `CompoundAdapter` | Compound V3 Comet | Passive | S1 | Active |
| `CurveAdapter` | Curve 3pool LP | Passive | S4 | Active |
| `AaveLoopAdapter` | Aave V3 2x leverage | Aggressive | S2 | Active |
| `GmxAdapter` | GMX V2 GLP | Aggressive | S3 | Active |
| `HalalLPAdapter` | Uniswap V3 USDC/ETH | Conservative + Dynamic | S3-H | Active |
| `CommodityMurabahaAdapter` | Murabaha trade lifecycle | Dynamic | S4-H | Active |
| `GoldExchangeAdapter` | PAXG/USDC atomic swap (Uniswap V3) | Conservative + Dynamic | S2-H | Active |
| `GoldAllocationAdapter` | XAUT spot position (oracle + Uniswap V3) | Conservative + Dynamic | S6-H | Pending SR-008 |
| `RwaYieldAdapter` | OUSG / BUIDL direct hold | — | S5-H | Deprecated (SR-001); unscreened from Shariah tier |

### `CommodityMurabahaAdapter` — Trade Lifecycle

```mermaid
stateDiagram-v2
    [*] --> PENDING : requestMurabaha(buyer, amount, markup, window)
    PENDING --> EXECUTED : executeMurabaha() [owner/vault]
    PENDING --> EXPIRED : expireTrade() [deadline passed]
    EXECUTED --> SETTLED : settleMurabaha() [buyer pays salePrice]
    EXECUTED --> EXPIRED : expireTrade() [deadline passed]
    SETTLED --> [*]
    EXPIRED --> [*]
```

- Max 50 concurrent active trades (DoS guard)
- O(1) removal via index mapping + swap-and-pop
- Buyer pays `costAmount + markup` directly to vault on settlement

---

## Agent Scoring System

The Express agent (`server/agent.ts`) runs continuously alongside the frontend. Each strategy has its own scorer with a configurable interval.

```mermaid
flowchart TD
    subgraph CONV ["Conventional Scorers"]
        S1["S1 scorer — 30s — Uniswap + CEX spread"]
        S2["S2 scorer — 30s — Hyperliquid funding rate"]
        S3["S3 scorer — event-driven — Stargate volume"]
        S4["S4 scorer — 45s — Aave + Ondo RWA yield"]
    end

    subgraph SHAR ["Shariah Scorers"]
        SH1["S1-H ETH Spread scorer — 60s"]
        SH2["S2-H Gold Spread scorer — 60s"]
        SH3["S3-H Halal LP scorer — 60s"]
        SH4["S4-H Murabaha scorer — event-driven"]
        SH5["S5-H RWA Sukuk — DISABLED (SR-001)"]
        SH6["S6-H Gold Allocation scorer — 300s"]
    end

    subgraph PROTO ["Protocol Signals"]
        PS["fetchProtocolSignals — 60s — Compound · Curve · Aave · GMX APY"]
    end

    S1 & S2 & S3 & S4 --> AGG_W[ScoreAggregator.writeBatchScores]
    SH1 & SH2 & SH3 & SH4 & SH6 --> SAGG_W[ShariahScoreAggregator.writeBatchScores]
    PS --> S1 & S2 & S3 & S4

    AGG_W --> API["/api/status"]
    SAGG_W --> SHARIAH_API["/api/shariah"]
```

All agent intervals and thresholds are hot-reloadable via `POST /api/config`.

---

## Execution Workflow

```mermaid
sequenceDiagram
    participant Agent as AI Agent
    participant Executor as RiskTieredExecutor
    participant Aggregator as ScoreAggregator
    participant Vault as ConventionalVault / ShariahVault
    participant Adapter as Protocol Adapter
    participant CCTP as Circle CCTP

    Agent->>Aggregator: writeScore(strategy, score, dataHash, destDomain)
    Agent->>Executor: executeWinner()
    Executor->>Executor: check gas price ≤ maxGasPrice
    Executor->>Executor: check block.timestamp ≥ lastExecution + cooldown
    Executor->>Aggregator: getWinningStrategy()
    Aggregator-->>Executor: (strategy, score, destinationDomain)
    Executor->>Executor: check score ≥ minScoreToExecute
    Executor->>Executor: check strategy in strategyMask
    alt Local execution (destinationDomain == 0)
        Executor->>Vault: deployCapital(adapter, amount, data)
        Vault->>Adapter: safeTransfer(amount)
        Vault->>Adapter: deploy(amount)
        Adapter-->>Vault: deployed
        Vault->>Vault: totalDeployed += amount
    else Cross-chain execution
        Executor->>Vault: deployCrossChain(destDomain, recipient, amount)
        Vault->>CCTP: depositForBurnWithCaller(amount, destDomain, recipient, USDC, destCaller)
        CCTP-->>Vault: nonce
        Vault->>Vault: pendingCrossChain[nonce] = amount
    end
    Executor->>Executor: lastExecution = block.timestamp
    Executor-->>Agent: ExecutionTriggered event
```

---

## Cross-Chain Flow

```mermaid
sequenceDiagram
    participant Vault as Source Vault (Arc)
    participant CCTP as Circle CCTP
    participant Dest as Destination Chain
    participant Agent as AI Agent
    participant Owner as Manager / Owner

    Note over Vault,CCTP: Outbound — deploy capital cross-chain
    Vault->>CCTP: depositForBurnWithCaller(amount, destDomain, recipient, USDC, caller)
    CCTP-->>Vault: nonce
    Vault->>Vault: pendingCrossChain[nonce] = amount
    Vault->>Vault: totalDeployed += amount

    Note over Agent,CCTP: Agent polls for CCTP attestation
    Agent->>CCTP: GET /v1/attestations/{messageHash}
    CCTP-->>Agent: {status: "complete", attestation: "..."}

    Note over Dest,Owner: Strategy executes on destination
    Dest->>Dest: capital deployed to protocol

    Note over Owner,Vault: Inbound — settle return
    Owner->>Vault: settleCrossChain(nonce)
    Vault->>Vault: totalDeployed -= pendingCrossChain[nonce]
    Vault->>Vault: delete pendingCrossChain[nonce]
    Vault-->>Owner: CrossChainSettled event
```

---

## Shariah Compliance Workflow

```mermaid
flowchart TD
    D[Depositor sends USDC] --> SV[ShariahVault]

    SV --> SC{Shariah screening enabled?}
    SC -- Yes --> CH{adapter in screened mapping?}
    CH -- No --> REV[revert AdapterNotScreened]
    CH -- Yes --> WF["Accrue Wakala fee — 0.5% AUM/year"]
    SC -- No --> WF

    WF --> DC[deployCapital to halal adapter]

    DC --> PROFIT{Profit realized?}
    PROFIT -- Yes --> ZK["claimMusharakahProfit(grossProfit)"]
    ZK --> ZD["ZakatModule.distributeZakat — 2.5% to charity"]
    ZD --> MS["TreasuryModule.calculateMusharakahSplit — 10% surplus above 4% hurdle"]
    MS --> RP["TreasuryModule.recordMusharakahProfit — vaultShare to pendingFees"]
    RP --> DEP[Depositor keeps depositorShare]

    style SV fill:#1a472a,color:#fff
    style ZD fill:#92400e,color:#fff
    style CH fill:#1e3a5f,color:#fff
```

**Permitted Shariah assets:** USDC, USDT, ETH, PAXG — OUSG and BUIDL removed per SR-001  
**XAUT:** S6-H adapter written; `shariahCertified[5]` is `false` until SR-008 accepted  
**Prohibited actions:** Aave lending (riba), perp funding payments, front-running MEV, non-atomic gold transfers across chain boundaries (`goldCrossChainBlocked = true`)

---

## Fee Architecture

```mermaid
graph LR
    subgraph CFEE ["Conventional"]
        CV[ConventionalVault] -->|accrue fee per-second| CTM["TreasuryModule (Conventional)"]
        CTM -->|claimFees - accounting only| CTM
        CV -->|sweepFeesToTreasury - actual transfer| RECV[Fee receiver]
    end

    subgraph SFEE ["Shariah"]
        SV[ShariahVault] -->|Wakala 0.5% AUM| STM["TreasuryModule (Shariah)"]
        SV -->|Musharakah 10% above 4% hurdle| STM
        SV -->|Zakat 2.5% of gross| ZW[Charity wallet]
        STM -->|sweepFeesToTreasury| SRECV[Fee receiver]
    end
```

| Fee | Rate | Mechanism | When |
|---|---|---|---|
| Admin fee (Conventional) | 0.75% AUM / year | Pro-rated per second, accounting-only | On every `deployCapital` |
| Wakala fee (Shariah) | 0.5% AUM / year | Pro-rated per second | On every Shariah `deployCapital` |
| Musharakah profit share | 10% of profit above 4% hurdle | Applied on `claimMusharakahProfit` | When manager claims |
| Charitable contribution | 2.5% of gross Musharakah profit | Auto-routed before Musharakah split | First, before any split |

---

## Zakat Distribution

```mermaid
sequenceDiagram
    participant Manager
    participant ShariahVault as ShariahVault
    participant ZakatModule as ZakatModule
    participant Charity as Charity Wallet
    participant Treasury as TreasuryModule (Shariah)

    Manager->>ShariahVault: claimMusharakahProfit(grossProfit)
    ShariahVault->>ShariahVault: forceApprove(zakatModule, grossProfit)
    ShariahVault->>ZakatModule: distributeZakat(grossProfit)
    ZakatModule->>ZakatModule: zakatAmount = grossProfit × 2.5%
    ZakatModule->>Charity: safeTransferFrom(vault, charity, zakatAmount)
    ZakatModule-->>ShariahVault: (zakatAmount, remaining)
    ShariahVault->>Treasury: calculateMusharakahSplit(remaining, elapsed, principal)
    Treasury-->>ShariahVault: (hurdleAmount, vaultShare, depositorShare)
    ShariahVault->>Treasury: recordMusharakahProfit(vaultShare)
    ShariahVault->>ShariahVault: reset hurdlePrincipal + hurdleStartTime
    ShariahVault-->>Manager: MusharakahProfitClaimed event
```

**Zakat wallet changes require a 30-day timelock:**

```
proposeZakatWalletChange(newWallet)  →  wait 30 days  →  confirmZakatWalletChange()
```

---

## Security Model

| Threat | Mitigation |
|---|---|
| Inflation attack | `_decimalsOffset = 6` on all vaults (shares have 12 decimals, USDC has 6) |
| Principal drain via fee sweep | `sweepFeesToTreasury` capped to `TreasuryModule.pendingFees` |
| Shariah screening bypass | `deployCapital` overridden in `ShariahVault`; base function is `virtual` |
| Unlimited trade DoS | `CommodityMurabahaAdapter` enforces `MAX_ACTIVE_TRADES = 50` |
| O(n) removal DoS | Active trade removal uses index mapping + swap-and-pop (O(1)) |
| Over-allocation | `maxAllocationBps` cumulative cap (default 80%) enforced on every deployment |
| Stale oracle execution | 5-minute staleness guard in both score aggregators |
| Gas price manipulation | `maxGasPrice` guard per tier in `RiskTieredExecutor` |
| Cross-chain double-settle | `settleCrossChain` deletes `pendingCrossChain[nonce]` atomically |
| Same-domain CCTP loop | `deployCrossChain` reverts `SameDomainDeploy` if `destDomain == sourceDomain` |
| Charitable wallet rug | 30-day timelock on all `ZakatModule` wallet changes |
| RWA lending exposure | `RwaYieldAdapter` has no approve-for-lending function by design |
| Gold cap breach | `ShariahVault.deployCapital` sums `goldSpreadAdapter.currentValue() + goldAllocationAdapter.currentValue()` and reverts `GoldCapExceeded` when combined > `MAX_GOLD_BPS` (30%) |
| Non-atomic gold cross-chain | `ShariahVault.deployCrossChain` reverts `NonAtomicGoldExchange` when `goldCrossChainBlocked = true` |
| Stale Chainlink gold price | `GoldAllocationAdapter._getOraclePrice` checks `startedAt > 0`, `answeredInRound >= roundId`, `answer > 0`, and `block.timestamp - updatedAt <= maxStalenessSecs` |
| Pool-oracle gold deviation | `GoldAllocationAdapter._getPoolPrice` reverts `GoldPriceDeviation` when pool price differs from oracle by more than `maxDeviationBps` (default 100 bps) |
| Parameter manipulation (gold adapter) | All numeric and address params on `GoldAllocationAdapter` require 30-day timelock via `proposeParamChange` / `executeParamChange`; hard caps enforced at proposal time |
| Reentrancy in executor | `RiskTieredExecutor.executeWinner` uses `_executionLocked` guard; `lastExecutionTime` set before external calls |

---

## Test Coverage

242 tests — 142 unit + 100 fuzz — across 17 test files in `contracts/test/`.

| File | Tests | Type | Coverage |
|---|---|---|---|
| `AutonomousVaultTest.t.sol` | 17 | Unit | Deposit, redeem, deploy, cap, cross-chain, pause, inflation |
| `ScoreAggregatorTest.t.sol` | 13 | Unit | Write, batch, staleness, ring-buffer, access control |
| `RiskTieredExecutorTest.t.sol` | 12 | Unit | Execute, cooldown, gas guard, bitmask, tier params |
| `TreasuryModuleTest.t.sol` | 16 | Unit | Accrue, claim, Musharakah split, bps guards |
| `ZakatModuleTest.t.sol` | 12 | Unit | Distribute, timelock, propose/confirm/cancel |
| `CommodityMurabahaAdapterTest.t.sol` | 18 | Unit | Request, execute, settle, expire, DoS guard |
| `ShariahVaultTaskATest.t.sol` | 10 | Unit | StrategyDeprecated guard, mask values, OUSG recall script |
| `GoldExchangeAdapterTest.t.sol` | 31 | Unit | Atomic swap, slippage, cross-chain block, combined cap |
| `GoldAllocationAdapterTest.t.sol` | 28 | Unit | Oracle guards, deviation, timelock params, combined cap |
| `FuzzAutonomousVault.t.sol` | 10 | Fuzz (512 runs) | Round-trip, multi-depositor fairness, cap at all amounts |
| `FuzzScoreAggregator.t.sol` | 9 | Fuzz (512 runs) | Winner invariant, ring-buffer, staleness, access control |
| `FuzzRiskTieredExecutor.t.sol` | 10 | Fuzz (512 runs) | Score/cooldown/gas guards at all param values |
| `FuzzTreasuryModule.t.sol` | 8 | Fuzz (512 runs) | Split invariant: vaultShare + depositorShare == grossProfit |
| `FuzzZakatModule.t.sol` | 9 | Fuzz (512 runs) | Charity amount exactly 2.5%, timelock boundary, accumulation |
| `FuzzCommodityMurabaha.t.sol` | 9 | Fuzz (512 runs) | Sale price math, O(1) removal, max-trade cap |
| `FuzzGoldExchangeAdapter.t.sol` | 13 | Fuzz (512 runs) | Round-trip value, no PAXG stranded, cap invariant |
| `FuzzGoldAllocationAdapter.t.sol` | 5 | Fuzz (512 runs) | `currentValue()` precision, round-trip, gold cap invariant, timelock |

Run the full suite:

```bash
forge test --fuzz-runs 512
```

Run a single file:

```bash
forge test --match-path contracts/test/AutonomousVaultTest.t.sol -vv
```

---

## Deployment

All contracts deploy to **Arc Testnet** (chain ID 2911) with USDC as the native gas token.

**Deploy order (respects dependency graph):**

```
1.  TreasuryModule (Conventional)                  — no deps
2.  TreasuryModule (Shariah)                       — no deps
3.  ZakatModule × 2                                — no deps (one per Shariah vault)
4.  ScoreAggregator                                — no deps
5.  ShariahScoreAggregator (6-strategy)            — no deps   [script: RedeployShariahAggregator.s.sol]
6.  ConventionalVault (Passive)                    — needs TreasuryModule
7.  ConventionalVault (Aggressive)                 — needs TreasuryModule
8.  ShariahVault (Conservative)                    — needs TreasuryModule + ZakatModule
9.  ShariahVault (Dynamic)                         — needs TreasuryModule + ZakatModule
10. RiskTieredExecutor × 4                         — needs vault + aggregator (masks: 9 / 15 / 38 / 47)
11. Adapters × 7 (conventional + halal)            — needs vault address
12. GoldExchangeAdapter (S2-H)                     — needs vault + MockAllocatedGold pool
13. GoldAllocationAdapter (S6-H)                   — needs vault + MockXAUT + oracle + pool [script: DeployGoldAllocation.s.sol]
14. setManager(executor) on each vault             — wires executor as manager
15. setStrategyConfig per adapter                  — configures each adapter per tier
16. setGoldSpreadAdapter / setGoldAllocationAdapter on ShariahVault
17. setCertified(0..3, true) — indices 4 and 5 remain false (SR-001 and SR-008 pending)
```

**Constructor args quick reference:**

```solidity
// TreasuryModule
constructor(
    "Conventional",         // treasuryType
    address(conventionalVault),  // feeSource
    address(USDC),          // asset
    75,                     // adminFeeBps (0.75%)
    0,                      // musharakahShareBps
    0,                      // hurdleRateBps
    owner                   // initialOwner
)

// ShariahVault
constructor(
    IERC20(USDC),
    owner,
    26,                     // sourceDomain (Arc Testnet CCTP domain)
    address(shariahTreasury),
    address(zakatModule)
)

// RiskTieredExecutor (PASSIVE)
constructor(
    address(passiveVault),
    address(scoreAggregator),
    RiskTier.PASSIVE,
    owner
)
```

**Key addresses (Arc Testnet):**

| Contract | Address |
|---|---|
| USDC (ERC-20, Arc Testnet) | `0x3600000000000000000000000000000000000000` |
| CCTP TokenMessengerV2 | `0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA` |
| Arc Testnet CCTP source domain | `26` |
| XAUT (mainnet reference only) | `0x68749665FF8D2d112Fa859AA293F07A622782F38` — not deployed on Arc Testnet; use MockXAUT for tests |

All deployed vault addresses are recorded in `AGENTS.md` after deployment.

---

## Project Structure

```
contracts/
├── AutonomousVault.sol          # Base ERC-4626 vault (pause gates on all capital paths)
├── ConventionalVault.sol        # Conventional tier (admin fee)
├── ShariahVault.sol             # Shariah tier (Wakala + Musharakah + gold cap)
├── ScoreAggregator.sol          # 4-strategy conventional scorer
├── ShariahScoreAggregator.sol   # 6-strategy Shariah scorer (index 4 deprecated)
├── RiskTieredExecutor.sol       # Strategy router (4 tiers; reentrancy guard)
├── TreasuryModule.sol           # Fee accounting module
├── ZakatModule.sol              # Charitable contribution router (30-day timelock)
├── PositionTracker.sol          # Position lifecycle + PnL
├── IStrategyAdapter.sol         # Adapter interface
├── VaultExecutor.sol            # Legacy executor (superseded)
├── interfaces/
│   └── AggregatorV3Interface.sol  # Minimal Chainlink oracle interface
├── adapters/
│   ├── CompoundAdapter.sol         # Compound V3 Comet
│   ├── CurveAdapter.sol            # Curve 3pool LP
│   ├── AaveLoopAdapter.sol         # Aave V3 2x leverage
│   ├── GmxAdapter.sol              # GMX V2 GLP
│   ├── HalalLPAdapter.sol          # Uniswap V3 halal LP (S3-H)
│   ├── CommodityMurabahaAdapter.sol # Murabaha trade lifecycle (S4-H)
│   ├── GoldExchangeAdapter.sol     # PAXG/USDC atomic swap (S2-H)
│   ├── GoldAllocationAdapter.sol   # XAUT spot + oracle guard (S6-H; 30-day timelock)
│   └── RwaYieldAdapter.sol         # OUSG/BUIDL — DEPRECATED per SR-001
├── test-helpers/
│   ├── MockERC20.sol
│   ├── MockAllocatedGold.sol       # PAXG stub (18 dec)
│   ├── MockXAUT.sol                # XAUT stub (6 dec)
│   ├── MockXauUsdAggregator.sol    # Settable XAU/USD oracle
│   └── MockUniswapV3PoolXAUT.sol  # Stripped V3 pool mock (slot0 + exactInputSingle)
├── script/
│   ├── RecallRwaFromShariah.s.sol        # Unscreen RwaYieldAdapter (Task A)
│   ├── RedeployShariahAggregator.s.sol   # Re-deploy 6-strategy aggregator (Task F)
│   └── DeployGoldAllocation.s.sol        # Deploy mocks + adapter + wire vaults (Task F)
└── test/
    ├── *Test.t.sol              # 142 unit tests
    └── Fuzz*.t.sol              # 100 fuzz tests (512 runs each)

server/
├── agent.ts                     # AI agent (scoring + execution)
└── shariah-strategies.ts        # Shariah strategy scorers (6 strategies; S5-H disabled)

src/
├── App.tsx                      # Router + vault-mode state
├── pages/                       # 6 route pages
├── components/                  # UI components
└── lib/shariahSim.ts            # Simulated scores (pre-deploy; 6 strategies)

docs/agents/
├── SHARIAH_REVIEW.md            # Board ruling stubs SR-001 through SR-011
└── shariah-vault-revision-plan.md
```

---

*DeFiVault Finance — Built on [Arc Testnet](https://arc.io) · Powered by [Circle USDC](https://circle.com)*
