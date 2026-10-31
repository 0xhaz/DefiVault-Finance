/**
 * Autonomous AI Agent — Cross-Chain DeFi Capital Allocator
 *
 * 4 strategies, each with its own data source and trigger mode:
 *
 *  Strategy 1 — Cross-Chain Stablecoin Spread         (every 30s)
 *    Sources: Uniswap V3 ETH/USDC pools on Arbitrum, Base, OP
 *    Signal:  max cross-chain USDC/USD deviation (implied from pool ratios)
 *    Rule:    spread ≥ 0.3% → actionable
 *    Output:  score 0-100, destinationDomain = chain with cheapest USDC
 *
 *  Strategy 2 — Perpetual Funding Rate Arbitrage       (every 30s)
 *    Sources: Hyperliquid metaAndAssetCtxs (ETH-PERP funding rate)
 *    Signal:  annualized 8-hour funding APY
 *    Rule:    APY ≥ 12% → top score band (95), 8-12% → 75, < 8% → 50, < 4% → 30
 *    Output:  score 0-100, destinationDomain = 0 (local carry, no bridge needed)
 *
 *  Strategy 3 — Bridge Flow Front-Running             (event-driven)
 *    Sources: Stargate OFT Transfer events + destination pool liquidity reads
 *    Signal:  transfer size AND expected impact on arrival
 *    Rule:    amount > $500K AND impact > 0.4% → score 90 (VERY HIGH)
 *             else → score 30 (skip)
 *    Output:  score 0-100, destinationDomain = destination chain of the flow
 *
 *  Strategy 4 — Liquidation + RWA Yield               (every 45s)
 *    Sources: Aave health factors (Multicall), Aave borrow rate, Ondo OUSG yield
 *    Signal:  at-risk positions count + Treasury-vs-DeFi carry spread
 *    Rule:    ≥ 7 at-risk positions → +40;  spread > 1.5% → +50;  base = 10
 *    Output:  score 0-100, destinationDomain = 0 (local, Arc has Aave)
 *
 * On-chain write: oracle role calls writeBatchScores on ScoreAggregator.
 * Execution: VaultExecutor.executeWinner() is called when the winning score
 *            exceeds minScoreToExecute (default 60) and cooldown has elapsed.
 * Crosschain: VaultExecutor routes deployCrossChain() via CCTP for domains != 0.
 */

import express from 'express';
import cors from 'cors';
import { createPublicClient, http, parseAbi, encodeFunctionData, keccak256, toHex } from 'viem';
import { runShariahScan, SHARIAH_STRATEGY_META, type EthSpreadResult, type GoldSpreadResult, type HalalLPResult, type MurabahaResult, type RwaSukukResult, type GoldAllocationResult } from './shariah-strategies';
import { screen } from './screening/engine.ts';
import { buildProtocolData, listKnownProtocols } from './screening/sources/protocol-profiles.ts';
import permittedAssetsJson from './board/permitted-assets.json';

// ─────────────────────────────────────────────────────────────────
// Chain + RPC
// ─────────────────────────────────────────────────────────────────
const ARC_CHAIN_ID = 5042002;
const proxyChains = (process.env.RPC_PROXY_CHAINS ?? '').split(',');
const rpcUrl: string =
  process.env.RPC_PROXY_BASE_URL && proxyChains.includes('Arc_Testnet')
    ? `${process.env.RPC_PROXY_BASE_URL}/api/rpc/Arc_Testnet?_rpc_token=${process.env.RPC_PROXY_TOKEN}`
    : (() => {
        console.warn('[Agent] RPC_PROXY_CHAINS does not include Arc_Testnet — using public RPC (unknown rate limit)');
        return 'https://rpc.testnet.arc.io'; // arc-studio-allow-onchain-literal
      })();

const arcChainDef = {
  id: ARC_CHAIN_ID,
  name: 'Arc Testnet',
  nativeCurrency: { name: 'USDC', symbol: 'USDC', decimals: 18 },
  rpcUrls: { default: { http: [rpcUrl] } },
};

const publicClient = createPublicClient({
  chain: arcChainDef as Parameters<typeof createPublicClient>[0]['chain'],
  transport: http(rpcUrl),
});

// ─────────────────────────────────────────────────────────────────
// CCTP domain map
// Domain 0 = local (Arc) — also used as "same chain, deployCapital"
// ─────────────────────────────────────────────────────────────────
const CCTP_DOMAIN_NAMES: Record<number, string> = {
  0:  'Local',
  1:  'Avalanche Fuji',
  2:  'OP Sepolia',
  3:  'Arb Sepolia',
  6:  'Base Sepolia',
  7:  'Polygon Amoy',
  10: 'Unichain Sepolia',
  26: 'Arc Testnet',
};

const CCTP_ATTESTATION_API = 'https://iris-api-sandbox.circle.com/v1/attestations'; // arc-studio-allow-onchain-literal

// ─────────────────────────────────────────────────────────────────
// Contract addresses (set after deploy in .env)
// ─────────────────────────────────────────────────────────────────
const AGGREGATOR_ADDRESS        = (process.env.VITE_AGGREGATOR_ADDRESS         ?? '') as `0x${string}`;
const EXECUTOR_ADDRESS          = (process.env.VITE_EXECUTOR_ADDRESS          ?? '') as `0x${string}`;
const PASSIVE_EXECUTOR_ADDRESS  = (process.env.VITE_PASSIVE_EXECUTOR_ADDRESS  ?? '') as `0x${string}`;
const AGGRESSIVE_EXECUTOR_ADDRESS = (process.env.VITE_AGGRESSIVE_EXECUTOR_ADDRESS ?? '') as `0x${string}`;
const PASSIVE_VAULT_ADDRESS     = (process.env.VITE_PASSIVE_VAULT_ADDRESS     ?? '') as `0x${string}`;
const AGGRESSIVE_VAULT_ADDRESS  = (process.env.VITE_AGGRESSIVE_VAULT_ADDRESS  ?? '') as `0x${string}`;
const VAULT_ADDRESS             = (process.env.VITE_VAULT_ADDRESS             ?? '') as `0x${string}`; // eslint-disable-line @typescript-eslint/no-unused-vars

const AGGREGATOR_ABI = parseAbi([
  'function writeBatchScores(uint8[] calldata strategies, uint8[] calldata values, bytes32[] calldata dataHashes, uint32[] calldata destinationDomains) external',
  'function getAllScores() view returns (uint8[4] values, uint40[4] timestamps, uint32[4] destinationDomains)',
  'function getWinningStrategy() view returns (uint8 strategy, uint8 score, uint32 destinationDomain)',
]);

const EXECUTOR_ABI = parseAbi([
  'function executeWinner() external',
  'function minScoreToExecute() view returns (uint8)',
  'function lastExecutionTime() view returns (uint256)',
  'function executionCooldown() view returns (uint256)',
]);

// Vault ABI — used by the oracle wallet to call settleCrossChain after CCTP attestation
const _VAULT_ABI = parseAbi([
  'function settleCrossChain(uint64 nonce) external',
  'function pendingCrossChain(uint64 nonce) view returns (uint256)',
]);

// ─────────────────────────────────────────────────────────────────
// Mutable agent configuration — updated at runtime via POST /api/config
// All timers read from here so changes take effect on the next tick
// without restarting the process.
// ─────────────────────────────────────────────────────────────────
interface AgentConfig {
  strategy1IntervalMs:   number;  // S1 loop (stablecoin spread)
  strategy2IntervalMs:   number;  // S2 loop (funding rate)
  strategy3IntervalMs:   number;  // S3 poll interval (bridge events)
  strategy4IntervalMs:   number;  // S4 sub-timer threshold
  cctpPollIntervalMs:    number;  // CCTP attestation check
  protocolSignalsIntervalMs: number; // Compound/Aave APY refresh
  mainLoopIntervalMs:    number;  // outer setTimeout (drives S1+S2+S3)
  minScorePassive:       number;  // min score for passive executor
  minScoreAggressive:    number;  // min score for aggressive executor
}

const DEFAULT_CONFIG: AgentConfig = {
  strategy1IntervalMs:       30_000,
  strategy2IntervalMs:       30_000,
  strategy3IntervalMs:       30_000,
  strategy4IntervalMs:       45_000,
  cctpPollIntervalMs:        60_000,
  protocolSignalsIntervalMs: 60_000,
  mainLoopIntervalMs:        30_000,
  minScorePassive:           80,
  minScoreAggressive:        60,
};

// Live config — mutated by POST /api/config
let agentConfig: AgentConfig = { ...DEFAULT_CONFIG };

// ─────────────────────────────────────────────────────────────────
// Shariah vault state (ShariahScoreAggregator — separate from conventional)
// ─────────────────────────────────────────────────────────────────
const SHARIAH_AGGREGATOR_ADDRESS = (process.env.VITE_SHARIAH_AGGREGATOR_ADDRESS ?? '') as `0x${string}`;
const SHARIAH_EXECUTOR_ADDRESS   = (process.env.VITE_SHARIAH_EXECUTOR_ADDRESS   ?? '') as `0x${string}`;

type ShariahScanResult = {
  ETH_SPREAD:      EthSpreadResult      | null;
  GOLD_SPREAD:     GoldSpreadResult     | null;
  HALAL_LP:        HalalLPResult        | null;
  MURABAHA:        MurabahaResult       | null;
  RWA_SUKUK:       RwaSukukResult       | null;
  GOLD_ALLOCATION: GoldAllocationResult | null;
};

let latestShariahScan: ShariahScanResult | null = null;
let lastShariahCycleAt = 0;
// Note: lastShariahS45At removed — S4-H (RESERVED_4) disabled per SR-001
let shariahCycleCount  = 0;

// ─────────────────────────────────────────────────────────────────
// Strategy names (matches ScoreAggregator.Strategy enum order)
// ─────────────────────────────────────────────────────────────────
const STRATEGY_NAMES = [
  'Cross-Chain Stablecoin Spread',
  'Perpetual Funding Rate Arb',
  'Bridge Flow Front-Running',
  'Liquidation + RWA Yield',
] as const;

// ─────────────────────────────────────────────────────────────────
// Shared result type
// ─────────────────────────────────────────────────────────────────
interface ScoredStrategy {
  score: number;           // 0-100
  destinationDomain: number;
  signal: string;          // human-readable signal value for the UI
  triggered: boolean;      // did it cross the actionable threshold?
}

// ─────────────────────────────────────────────────────────────────
// STRATEGY 1: Cross-Chain Stablecoin Spread  (every 30s)
//
// Real implementation: multicall Uniswap V3 slot0 on each chain to get
// sqrtPriceX96, convert to implied USDC/USD price, compute max deviation.
//
// Simulation: oscillates realistically to demonstrate scoring logic.
// Swap this block for live Multicall reads once contracts are deployed.
//
// Scoring:
//   deviation ≥ 0.50% → 90 (VERY HIGH — worth bridging)
//   deviation ≥ 0.30% → 75 (HIGH — actionable threshold)
//   deviation ≥ 0.15% → 45 (MEDIUM)
//   deviation < 0.15% → 15 (LOW)
// destinationDomain: chain with cheapest implied USDC (most dislocated)
// ─────────────────────────────────────────────────────────────────

interface SpreadData {
  arbDeviationPct: number;
  baseDeviationPct: number;
  opDeviationPct: number;
  maxDeviationPct: number;
  bestDomain: number;
}

async function fetchStablecoinSpreadData(): Promise<SpreadData> {
  // Simulates reading Uniswap V3 ETH/USDC slot0 on three chains and deriving
  // the implied USDC dislocation from the ETH/USDC ratio vs a reference price.
  const now = Date.now();
  const t = now / 30_000;
  const arb  = Math.max(0, 0.08 + Math.sin(t * 1.3) * 0.15 + Math.random() * 0.05);
  const base = Math.max(0, 0.12 + Math.sin(t * 0.9) * 0.12 + Math.random() * 0.04);
  const op   = Math.max(0, 0.06 + Math.sin(t * 1.7) * 0.18 + Math.random() * 0.06);

  const chains = [
    { deviation: arb,  domain: 3 },  // Arb Sepolia
    { deviation: base, domain: 6 },  // Base Sepolia
    { deviation: op,   domain: 2 },  // OP Sepolia
  ];
  const best = chains.reduce((a, b) => b.deviation > a.deviation ? b : a);

  return {
    arbDeviationPct: arb,
    baseDeviationPct: base,
    opDeviationPct: op,
    maxDeviationPct: best.deviation,
    bestDomain: best.domain,
  };
}

function scoreStablecoinSpread(data: SpreadData): ScoredStrategy {
  const dev = data.maxDeviationPct;
  let score: number;
  if (dev >= 0.50) score = 90;
  else if (dev >= 0.30) score = 75;
  else if (dev >= 0.15) score = 45;
  else score = 15;

  return {
    score,
    destinationDomain: dev >= 0.30 ? data.bestDomain : 0,
    signal: `${(dev * 100).toFixed(1)} bps max deviation`,
    triggered: dev >= 0.30,
  };
}

// ─────────────────────────────────────────────────────────────────
// STRATEGY 2: Perpetual Funding Rate Arbitrage  (every 30s)
//
// Real implementation: POST https://api.hyperliquid.xyz/info
//   body: { type: "metaAndAssetCtxs" }
//   parse response[1][ETH_INDEX].funding  (8-hour rate, e.g. 0.000150 = 0.015%)
//   annualize: APY = rate * 3 * 365 * 100
//
// Scoring:
//   APY ≥ 12% → 95 (VERY HIGH per diagram)
//   APY ≥  8% → 75
//   APY ≥  4% → 50
//   APY <  4% → 30
// destinationDomain: 0 (carry trade executes locally; Hyperliquid settlement
//   happens off-chain, only USDC collateral moves)
// ─────────────────────────────────────────────────────────────────

interface FundingData {
  fundingRate8h: number;   // raw 8h rate, e.g. 0.000150
  annualizedApy: number;   // percent, e.g. 16.4
}

async function fetchFundingRateData(): Promise<FundingData> {
  try {
    const res = await fetch('https://api.hyperliquid.xyz/info', { // arc-studio-allow-onchain-literal
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ type: 'metaAndAssetCtxs' }),
      signal: AbortSignal.timeout(5000),
    });
    if (res.ok) {
      const body = await res.json() as [{ universe: Array<{ name: string }> }, Array<{ funding: string }>];
      const universe = body[0].universe;
      const ctxs = body[1];
      const ethIdx = universe.findIndex(a => a.name === 'ETH');
      if (ethIdx >= 0 && ctxs[ethIdx]) {
        const rate = parseFloat(ctxs[ethIdx].funding);
        return { fundingRate8h: rate, annualizedApy: rate * 3 * 365 * 100 };
      }
    }
  } catch {
    // API unreachable — fall through to simulation
  }

  // Simulation fallback: oscillates around 0.015%/8h (≈ 16.4% APY) to trigger top band
  const now = Date.now();
  const t = now / 30_000;
  const rate = Math.max(0.0001, 0.000150 + Math.sin(t * 0.7) * 0.000060 + Math.random() * 0.000020);
  return { fundingRate8h: rate, annualizedApy: rate * 3 * 365 * 100 };
}

function scoreFundingRate(data: FundingData): ScoredStrategy {
  const apy = data.annualizedApy;
  let score: number;
  if (apy >= 12) score = 95;
  else if (apy >= 8) score = 75;
  else if (apy >= 4) score = 50;
  else score = 30;

  return {
    score,
    destinationDomain: 0,  // carry is local; no CCTP bridge needed
    signal: `${apy.toFixed(1)}% APY (${(data.fundingRate8h * 100).toFixed(4)}%/8h)`,
    triggered: apy >= 12,
  };
}

// ─────────────────────────────────────────────────────────────────
// STRATEGY 3: Bridge Flow Front-Running  (event-driven)
//
// Real implementation: subscribe to Stargate OFTSent / Packet events on
//   every supported chain; on each event read destination pool liquidity
//   via Multicall to estimate price impact on arrival.
//
// Event loop: We poll every 30s as a simulation of event-driven detection.
// On a deployed system this would be an ethers.js / viem watchContractEvent
// feeding the same scoring function.
//
// Scoring:
//   amount > $500K AND impact > 0.4% → 90 (VERY HIGH, per diagram)
//   amount > $500K OR  impact > 0.4% → 55
//   otherwise                        → 30
// destinationDomain: CCTP domain of the Stargate destination chain
// ─────────────────────────────────────────────────────────────────

interface BridgeFlowData {
  transferAmountUsd: number;
  destinationChain: string;
  destinationDomain: number;
  expectedImpactPct: number;
  poolLiquidityUsd: number;
}

async function fetchBridgeFlowData(): Promise<BridgeFlowData> {
  // Simulates a Stargate Transfer event listener + destination pool liquidity read.
  // In production: subscribe to OFTSent events on all Stargate chains,
  // then call getPool(poolId).totalLiquidity() on the destination chain.
  const now = Date.now();
  const t = now / 60_000;
  // Flow pulses every ~2 minutes to simulate bursty bridge activity
  const flowMultiplier = 0.5 + 0.5 * Math.abs(Math.sin(t * Math.PI));
  const amount = 150_000 + flowMultiplier * 1_350_000 + Math.random() * 50_000;
  const liquidity = 2_000_000 + Math.random() * 500_000;
  const impact = amount / liquidity;

  // Rotate destination chain each flow burst
  const destChains = [
    { name: 'Arbitrum', domain: 3 },
    { name: 'Base', domain: 6 },
    { name: 'Optimism', domain: 2 },
  ];
  const destIdx = Math.floor(now / 120_000) % destChains.length;
  const dest = destChains[destIdx];

  return {
    transferAmountUsd: amount,
    destinationChain: dest.name,
    destinationDomain: dest.domain,
    expectedImpactPct: impact * 100,
    poolLiquidityUsd: liquidity,
  };
}

function scoreBridgeFlow(data: BridgeFlowData): ScoredStrategy {
  const bigFlow    = data.transferAmountUsd > 500_000;
  const highImpact = data.expectedImpactPct > 0.4;
  let score: number;
  if (bigFlow && highImpact) score = 90;
  else if (bigFlow || highImpact) score = 55;
  else score = 30;

  return {
    score,
    destinationDomain: (bigFlow && highImpact) ? data.destinationDomain : 0,
    signal: `$${(data.transferAmountUsd / 1000).toFixed(0)}K → ${data.destinationChain} | ${data.expectedImpactPct.toFixed(2)}% impact`,
    triggered: bigFlow && highImpact,
  };
}

// ─────────────────────────────────────────────────────────────────
// STRATEGY 4: Liquidation + RWA Yield  (every 45s)
//
// Real implementation:
//   - Multicall Aave V3 getUserAccountData across a set of large positions
//     to find healthFactor < 1.1 (at-risk). Count at-risk positions.
//   - Read Aave V3 USDC supply APY from reserveData (the borrow rate proxy).
//   - Read Ondo OUSG oracle / NAV for current yield APY.
//   - Spread = OUSG APY − Aave borrow rate
//
// Scoring:
//   base = 10
//   at-risk positions ≥ 7 → +40
//   spread > 1.5% → +50
//   capped at 100
//
// destinationDomain: 0 (Aave liquidation backstop is local)
// ─────────────────────────────────────────────────────────────────

interface LiquidationRwaData {
  atRiskPositions: number;    // count of positions with HF < 1.1
  minHealthFactor: number;    // lowest HF observed
  aaveBorrowRatePct: number;  // Aave USDC supply APY (%)
  ousgYieldApy: number;       // Ondo OUSG APY (%)
  spreadPct: number;          // OUSG APY − Aave borrow rate
}

async function fetchLiquidationRwaData(): Promise<LiquidationRwaData> {
  // Simulates Aave Multicall + Ondo oracle read.
  // In production:
  //   1. Multicall Aave V3 getUserAccountData for a watchlist of addresses
  //   2. Call Aave V3 getReserveData(USDC) for currentVariableBorrowRate
  //   3. Read OUSG price feed / NAV endpoint for current yield
  const now = Date.now();
  const t = now / 45_000;

  // At-risk count fluctuates — spikes to trigger the +40 bonus
  const atRisk = Math.max(0, Math.round(4 + Math.sin(t * 1.1) * 5 + Math.random() * 2));
  const minHF  = 1.05 + Math.max(0, Math.sin(t * 0.8)) * 0.25 + Math.random() * 0.05;

  // Aave USDC borrow rate oscillates 3–6%
  const aaveBorrow = 3.5 + Math.sin(t * 0.5) * 1.2 + Math.random() * 0.3;

  // OUSG yield is stable ~5.0-5.5% (T-bill backed)
  const ousgYield = 5.0 + Math.sin(t * 0.3) * 0.25 + Math.random() * 0.1;

  return {
    atRiskPositions: atRisk,
    minHealthFactor: minHF,
    aaveBorrowRatePct: aaveBorrow,
    ousgYieldApy: ousgYield,
    spreadPct: ousgYield - aaveBorrow,
  };
}

function scoreLiquidationRwa(data: LiquidationRwaData): ScoredStrategy {
  let score = 10;
  if (data.atRiskPositions >= 7) score += 40;
  if (data.spreadPct > 1.5)      score += 50;
  score = Math.min(100, score);

  return {
    score,
    destinationDomain: 0,
    signal: `${data.atRiskPositions} at-risk pos | OUSG ${data.ousgYieldApy.toFixed(2)}% vs Aave ${data.aaveBorrowRatePct.toFixed(2)}%`,
    triggered: data.atRiskPositions >= 7 || data.spreadPct > 1.5,
  };
}

// ─────────────────────────────────────────────────────────────────
// Unified scan — runs all 4 data fetches in parallel
// ─────────────────────────────────────────────────────────────────
interface ScanResult {
  strategies: ScoredStrategy[];
  raw: {
    spread: SpreadData;
    funding: FundingData;
    bridge: BridgeFlowData;
    liquidation: LiquidationRwaData;
  };
}

async function runScan(): Promise<ScanResult> {
  const [spreadData, fundingData, bridgeData, liquidationData] = await Promise.all([
    fetchStablecoinSpreadData(),
    fetchFundingRateData(),
    fetchBridgeFlowData(),
    fetchLiquidationRwaData(),
  ]);

  return {
    strategies: [
      scoreStablecoinSpread(spreadData),
      scoreFundingRate(fundingData),
      scoreBridgeFlow(bridgeData),
      scoreLiquidationRwa(liquidationData),
    ],
    raw: { spread: spreadData, funding: fundingData, bridge: bridgeData, liquidation: liquidationData },
  };
}

// ─────────────────────────────────────────────────────────────────
// PROTOCOL SIGNALS: Compound APY + Aave Loop Rate
// These feed the passive (Compound, Curve) and aggressive (AaveLoop, GMX)
// adapter decisions. Exposed in /tiers endpoint for the UI.
// ─────────────────────────────────────────────────────────────────

interface ProtocolSignals {
  compoundSupplyApy: number;   // Compound V3 USDC supply APY (%)
  curvePoolApy: number;        // Curve 3pool USDC fee APY (%)
  aaveLoopNetApy: number;      // Aave 2x loop net APY (supply*2 - borrow, %)
  gmxGlpApy: number;           // GMX GLP yield APY (%)
  timestamp: number;
}

async function fetchProtocolSignals(): Promise<ProtocolSignals> {
  // Simulates reading APYs from each protocol.
  // Production: read Compound V3 utilization rate, Curve gauge APY,
  // Aave V3 supplyRate + variableBorrowRate, GMX GLP tracker rewards.
  const now = Date.now();
  const t = now / 60_000;

  // Compound V3 USDC supply APY: stable 3–5%
  const compoundApy = 3.8 + Math.sin(t * 0.4) * 0.8 + Math.random() * 0.2;

  // Curve 3pool fee APY: 0.5–2% from swap fees + CRV gauge
  const curveApy = 1.2 + Math.sin(t * 0.6) * 0.5 + Math.random() * 0.15;

  // Aave 2x loop net APY: supply APY * 1.5 - borrow rate * 0.5
  // (simplified: supply 5.2%, borrow 4.8%, net ≈ 2.6% extra + base)
  const supplyApy = 5.2 + Math.sin(t * 0.5) * 0.6 + Math.random() * 0.2;
  const borrowApy = 4.8 + Math.sin(t * 0.5) * 0.5 + Math.random() * 0.15;
  const aaveLoopNet = supplyApy * 1.5 - borrowApy * 0.5;

  // GMX GLP APY: volatile 15–35% (protocol fees from leverage traders)
  const gmxApy = 20 + Math.sin(t * 1.2) * 10 + Math.random() * 3;

  return {
    compoundSupplyApy: compoundApy,
    curvePoolApy: curveApy,
    aaveLoopNetApy: aaveLoopNet,
    gmxGlpApy: gmxApy,
    timestamp: Math.floor(now / 1000),
  };
}

// ─────────────────────────────────────────────────────────────────
// RISK TIER ROUTING — decides which strategies each vault should act on
//
// Passive vault  (mask=0b1001): S1 (Stablecoin Spread) + S4 (Liquidation+RWA)
//   adapters: CompoundAdapter, CurveAdapter
//   minScore: 80   cooldown: 2h   maxAlloc: 40%
//
// Aggressive vault (mask=0b1111): all 4 strategies
//   adapters: AaveLoopAdapter, GmxAdapter (+ can also use Compound/Curve)
//   minScore: 60   cooldown: 30m  maxAlloc: 80%
// ─────────────────────────────────────────────────────────────────

const PASSIVE_STRATEGY_MASK    = 0b1001; // S1 + S4
const AGGRESSIVE_STRATEGY_MASK = 0b1111; // all 4

interface TierRouting {
  tier: 'passive' | 'aggressive';
  eligibleStrategies: Array<{ idx: number; name: string; score: number; eligible: boolean; reason: string }>;
  winnerIdx: number | null;
  winnerScore: number;
  winnerName: string;
  willExecute: boolean;
  minScore: number;
  cooldownMinutes: number;
  protocolSignals: ProtocolSignals;
}

let latestProtocolSignals: ProtocolSignals | null = null;

function computeTierRouting(
  strategies: ScoredStrategy[],
  tier: 'passive' | 'aggressive',
  protocolSignals: ProtocolSignals
): TierRouting {
  const mask     = tier === 'passive' ? PASSIVE_STRATEGY_MASK : AGGRESSIVE_STRATEGY_MASK;
  const minScore = tier === 'passive' ? 80 : 60;
  const cooldown = tier === 'passive' ? 120 : 30; // minutes

  const eligible = strategies.map((s, i) => {
    const inMask   = ((mask >> i) & 1) === 1;
    const passesScore = s.score >= minScore;
    let reason: string;
    if (!inMask) {
      reason = tier === 'passive'
        ? 'Strategy not allowed in passive tier (too aggressive)'
        : 'All strategies allowed in aggressive tier';
    } else if (!passesScore) {
      reason = `Score ${s.score} < min ${minScore} for ${tier} tier`;
    } else {
      reason = `Eligible — score ${s.score} ≥ ${minScore}`;
    }
    return { idx: i, name: STRATEGY_NAMES[i], score: s.score, eligible: inMask && passesScore, reason };
  });

  const candidates = eligible.filter(e => e.eligible);
  const winner = candidates.length > 0
    ? candidates.reduce((a, b) => b.score > a.score ? b : a)
    : null;

  return {
    tier,
    eligibleStrategies: eligible,
    winnerIdx: winner?.idx ?? null,
    winnerScore: winner?.score ?? 0,
    winnerName: winner?.name ?? 'None',
    willExecute: winner !== null,
    minScore,
    cooldownMinutes: cooldown,
    protocolSignals,
  };
}

// ─────────────────────────────────────────────────────────────────
// On-chain write (oracle wallet required)
// ─────────────────────────────────────────────────────────────────
async function writeScoresToChain(strategies: ScoredStrategy[], rawTs: number): Promise<boolean> {
  if (!AGGREGATOR_ADDRESS || AGGREGATOR_ADDRESS.length < 5) {
    console.log('[Agent] AGGREGATOR not deployed — skipping on-chain write');
    return false;
  }

  const idxs   = [0, 1, 2, 3];
  const values  = strategies.map(s => Math.round(s.score));
  const domains = strategies.map(s => s.destinationDomain);
  const dataHash = keccak256(toHex(JSON.stringify({ values, domains, ts: rawTs })));
  const dataHashes = idxs.map(() => dataHash);

  const calldata = encodeFunctionData({
    abi: AGGREGATOR_ABI,
    functionName: 'writeBatchScores',
    args: [idxs as number[], values, dataHashes as `0x${string}`[], domains],
  });
  console.log('[Agent] writeBatchScores calldata (preview):', calldata.slice(0, 66) + '…');
  // Production: sign + broadcast via Circle DCW SDK (ORACLE_WALLET_ID in .env)
  return true;
}

// ─────────────────────────────────────────────────────────────────
// Execution trigger — checks cooldown then calls executeWinner()
// ─────────────────────────────────────────────────────────────────
async function triggerExecution(strategies: ScoredStrategy[]): Promise<void> {
  if (!EXECUTOR_ADDRESS || EXECUTOR_ADDRESS.length < 5) return;
  try {
    const [minScore, lastExec, cooldown] = await Promise.all([
      publicClient.readContract({ address: EXECUTOR_ADDRESS, abi: EXECUTOR_ABI, functionName: 'minScoreToExecute' }),
      publicClient.readContract({ address: EXECUTOR_ADDRESS, abi: EXECUTOR_ABI, functionName: 'lastExecutionTime' }),
      publicClient.readContract({ address: EXECUTOR_ADDRESS, abi: EXECUTOR_ABI, functionName: 'executionCooldown' }),
    ]);

    const now = BigInt(Math.floor(Date.now() / 1000));
    const nextExec = (lastExec as bigint) + (cooldown as bigint);
    if (now < nextExec) {
      console.log(`[Agent] Execution cooldown: ${Number(nextExec - now)}s remaining`);
      return;
    }

    // Read the winning strategy back from the aggregator to confirm on-chain state
    try {
      const result = await publicClient.readContract({
        address: AGGREGATOR_ADDRESS,
        abi: AGGREGATOR_ABI,
        functionName: 'getWinningStrategy',
      }) as [number, number, number];
      const [winnerIdx, winnerScore, destDomain] = result;

      if (winnerScore < Number(minScore)) {
        console.log(`[Agent] Winner score ${winnerScore} < min ${Number(minScore)} — no execution`);
        return;
      }

      const route = destDomain === 0
        ? 'LOCAL (deployCapital)'
        : `CROSSCHAIN via CCTP → ${CCTP_DOMAIN_NAMES[destDomain] ?? `domain ${destDomain}`}`;
      console.log(`[Agent] Winner: ${STRATEGY_NAMES[winnerIdx]} score=${winnerScore} → ${route}`);
      console.log(`[Agent] Agent signal: "${strategies[winnerIdx]?.signal}" — executeWinner() would be called`);
    } catch {
      console.log('[Agent] No valid on-chain scores yet (stale or zero)');
    }
  } catch (err) {
    console.log('[Agent] Execution check skipped:', (err as Error).message?.slice(0, 80));
  }
}

// ─────────────────────────────────────────────────────────────────
// CCTP attestation poller — watches pending crosschain nonces
// ─────────────────────────────────────────────────────────────────
interface PendingCctpPosition {
  nonce: bigint;
  amount: bigint;
  messageHash: string;
  destinationDomain: number;
  createdAt: number;
}

const pendingCctpPositions = new Map<string, PendingCctpPosition>();

async function checkCctpAttestations(): Promise<void> {
  if (pendingCctpPositions.size === 0) return;
  for (const [key, pos] of pendingCctpPositions.entries()) {
    try {
      const res = await fetch(`${CCTP_ATTESTATION_API}/${pos.messageHash}`, {
        signal: AbortSignal.timeout(4000),
      });
      if (!res.ok) continue;
      const body = await res.json() as { status?: string; attestation?: string };
      if (body.status === 'complete' && body.attestation) {
        console.log(`[Agent] CCTP attestation complete for nonce ${pos.nonce} → settleCrossChain() would be called`);
        pendingCctpPositions.delete(key);
      } else {
        console.log(`[Agent] CCTP nonce ${pos.nonce} status: ${body.status ?? 'pending'}`);
      }
    } catch {
      // Attestation API unreachable — retry next cycle
    }
  }
}

// ─────────────────────────────────────────────────────────────────
// State
// ─────────────────────────────────────────────────────────────────
let running = false;
let lastCycleAt: number | null = null;
let cycleCount = 0;
let latestStrategies: ScoredStrategy[] = STRATEGY_NAMES.map(() => ({ score: 0, destinationDomain: 0, signal: 'No data yet', triggered: false }));
let latestRaw: ScanResult['raw'] | null = null;

// ─────────────────────────────────────────────────────────────────
// Express HTTP server
// ─────────────────────────────────────────────────────────────────
const app = express();
app.use(cors());
app.use(express.json());

app.get('/health', (_req, res) => {
  res.json({ ok: true, running, lastCycleAt, cycleCount });
});

app.get('/status', (_req, res) => {
  const scores = latestStrategies.map((v, i) => ({
    strategy: STRATEGY_NAMES[i],
    score: v.score,
    destinationDomain: v.destinationDomain,
    destinationName: CCTP_DOMAIN_NAMES[v.destinationDomain] ?? `domain ${v.destinationDomain}`,
    signal: v.signal,
    triggered: v.triggered,
  }));
  res.json({
    running,
    lastCycleAt,
    cycleCount,
    scores,
    pendingCctp: pendingCctpPositions.size,
    raw: latestRaw
      ? {
          uniswapSpread: latestRaw.spread.maxDeviationPct,
          fundingRatePct: latestRaw.funding.fundingRate8h * 100,
          stargateFlowUsd: latestRaw.bridge.transferAmountUsd,
          stargateImpactPct: latestRaw.bridge.expectedImpactPct,
          aaveHealthFactor: latestRaw.liquidation.minHealthFactor,
          ondoYieldApy: latestRaw.liquidation.ousgYieldApy,
        }
      : null,
  });
});

app.post('/trigger', async (_req, res) => {
  console.log('[Agent] Manual scan triggered');
  try {
    const scan = await runScan();
    latestStrategies = scan.strategies;
    latestRaw = scan.raw;
    await writeScoresToChain(scan.strategies, Math.floor(Date.now() / 1000));
    res.json({
      ok: true,
      scores: scan.strategies.map((v, i) => ({
        strategy: STRATEGY_NAMES[i],
        score: v.score,
        signal: v.signal,
        triggered: v.triggered,
        destinationDomain: v.destinationDomain,
        destinationName: CCTP_DOMAIN_NAMES[v.destinationDomain] ?? `domain ${v.destinationDomain}`,
      })),
    });
  } catch (err) {
    res.status(500).json({ ok: false, error: (err as Error).message });
  }
});

// Risk tier routing — passive vs aggressive vault decisions
app.get('/tiers', (_req, res) => {
  const signals = latestProtocolSignals ?? {
    compoundSupplyApy: 0, curvePoolApy: 0, aaveLoopNetApy: 0, gmxGlpApy: 0,
    timestamp: 0,
  };
  res.json({
    passive: computeTierRouting(latestStrategies, 'passive', signals),
    aggressive: computeTierRouting(latestStrategies, 'aggressive', signals),
    passiveVault: PASSIVE_VAULT_ADDRESS || null,
    aggressiveVault: AGGRESSIVE_VAULT_ADDRESS || null,
    passiveExecutor: PASSIVE_EXECUTOR_ADDRESS || null,
    aggressiveExecutor: AGGRESSIVE_EXECUTOR_ADDRESS || null,
  });
});

app.post('/cctp/register', (req, res) => {
  const { nonce, amount, messageHash, destinationDomain } = req.body as {
    nonce?: string; amount?: string; messageHash?: string; destinationDomain?: number;
  };
  if (!nonce || !amount || !messageHash || destinationDomain === undefined) {
    res.status(400).json({ ok: false, error: 'nonce, amount, messageHash, destinationDomain required' });
    return;
  }
  pendingCctpPositions.set(messageHash, {
    nonce: BigInt(nonce), amount: BigInt(amount), messageHash, destinationDomain, createdAt: Date.now(),
  });
  console.log(`[Agent] Registered CCTP position: nonce=${nonce} domain=${destinationDomain}`);
  res.json({ ok: true });
});

// ─────────────────────────────────────────────────────────────────
// GET /api/charity/estimate
// Returns a per-share charitable contribution estimate and a
// calculation template for the caller's UI.
//
// This is advisory only — it does NOT write to chain or trigger
// any distribution. All fields are estimates based on current
// share value and the configured charityBps (default 250 = 2.5%).
//
// Board rulings SR-002 and SR-003 must be completed before any
// live distribution is triggered on-chain.
// ─────────────────────────────────────────────────────────────────
app.get('/api/charity/estimate', (req, res) => {
  // Parse optional query parameters for the caller to supply their own figures.
  const grossProfitUsdc  = parseFloat((req.query.grossProfitUsdc  as string) ?? '0') || 0;
  const shareCount       = parseFloat((req.query.shareCount       as string) ?? '0') || 0;
  const charityBps       = parseInt  ((req.query.charityBps       as string) ?? '250', 10) || 250;
  const purificationBps  = parseInt  ((req.query.purificationBps  as string) ?? '0', 10) || 0;

  // Clamp to hard caps (mirrors CharityModule and PurificationEscrow constants).
  const safeCharityBps      = Math.min(Math.max(0, charityBps), 500);
  const safePurificationBps = Math.min(Math.max(0, purificationBps), 1000);

  // Waterfall calculation (mirrors PurificationEscrow.executeWaterfall logic).
  const purified       = Math.floor(grossProfitUsdc * safePurificationBps / 10_000);
  const afterPurify    = grossProfitUsdc - purified;
  const charityAmount  = Math.floor(afterPurify    * safeCharityBps / 10_000);
  const afterCharity   = afterPurify - charityAmount;

  // Per-share charity estimate (advisory).
  const perShareCharity = shareCount > 0 ? charityAmount / shareCount : 0;

  res.json({
    disclaimer: [
      'This is an estimate only. No distribution has been triggered.',
      'Board rulings SR-002 (charity rate) and SR-003 (charity wallet) must be',
      'completed before any on-chain charitable distribution is executed.',
      'The contribution is voluntary sadaqah, not Zakat.',
    ],
    inputs: {
      grossProfitUsdc,
      shareCount,
      charityBps: safeCharityBps,
      purificationBps: safePurificationBps,
    },
    waterfall: {
      grossProfit:    grossProfitUsdc,
      purified,
      afterPurification: afterPurify,
      charityContribution: charityAmount,
      afterCharity,
    },
    perShareEstimate: {
      charityUsdc:   perShareCharity,
      note: shareCount > 0
        ? `Each share contributes ~$${perShareCharity.toFixed(6)} USDC to charity from this profit claim.`
        : 'Provide shareCount to compute per-share estimate.',
    },
    calculationTemplate: {
      step1: `purified = grossProfit × ${safePurificationBps} / 10000`,
      step2: `charityContribution = (grossProfit - purified) × ${safeCharityBps} / 10000`,
      step3: 'remainder = grossProfit - purified - charityContribution',
      step4: 'Musharakah split applied to remainder (10% vault share above 4% hurdle)',
    },
  });
});

app.get('/cctp/pending', (_req, res) => {
  const list = Array.from(pendingCctpPositions.values()).map(p => ({
    ...p,
    nonce: p.nonce.toString(),
    amount: p.amount.toString(),
    destinationName: CCTP_DOMAIN_NAMES[p.destinationDomain] ?? `domain ${p.destinationDomain}`,
  }));
  res.json({ count: list.length, positions: list });
});

// ─────────────────────────────────────────────────────────────────
// GET /api/shariah — live Shariah vault strategy state
// ─────────────────────────────────────────────────────────────────
app.get('/shariah', (_req, res) => {
  const strategies = latestShariahScan ? Object.entries(latestShariahScan).map(([key, val], idx) => {
    const meta = SHARIAH_STRATEGY_META[idx];
    return {
      id: idx,
      key,
      name: meta?.name ?? key,
      trigger: meta?.trigger ?? '—',
      description: meta?.description ?? '',
      inputs: meta?.inputs ?? '',
      signal: meta?.signal ?? '',
      targetRule: meta?.targetRule ?? '',
      shariahBasis: meta?.shariahBasis ?? '',
      permittedAssets: meta?.permittedAssets ?? [],
      score: val?.score ?? 0,
      destinationDomain: val?.destinationDomain ?? 0,
      signalText: val?.signal ?? 'No data',
      triggered: val?.triggered ?? false,
      timestamp: Math.floor(lastShariahCycleAt / 1000),
    };
  }) : [];

  const winner = strategies.length > 0
    ? strategies.reduce((a, b) => b.score > a.score ? b : a)
    : null;

  res.json({
    online: latestShariahScan !== null,
    cycleCount: shariahCycleCount,
    lastCycleAt: lastShariahCycleAt,
    strategies,
    winner,
    aggregatorAddress: SHARIAH_AGGREGATOR_ADDRESS,
    executorAddress: SHARIAH_EXECUTOR_ADDRESS,
    meta: SHARIAH_STRATEGY_META,
  });
});

// ─────────────────────────────────────────────────────────────────
// GET /api/config — returns live config + default reference
// POST /api/config — merges partial update into live config
//   Body: Partial<AgentConfig> (unknown keys silently ignored)
//   Intervals: min 5 000 ms, max 300 000 ms (5 min) enforced
// ─────────────────────────────────────────────────────────────────
app.get('/api/config', (_req, res) => {
  res.json({ config: agentConfig, defaults: DEFAULT_CONFIG });
});

app.post('/api/config', (req, res) => {
  const body = req.body as Partial<AgentConfig>;
  const intervalKeys: (keyof AgentConfig)[] = [
    'strategy1IntervalMs', 'strategy2IntervalMs', 'strategy3IntervalMs',
    'strategy4IntervalMs', 'cctpPollIntervalMs', 'protocolSignalsIntervalMs',
    'mainLoopIntervalMs',
  ];
  const scoreKeys: (keyof AgentConfig)[] = ['minScorePassive', 'minScoreAggressive'];
  const updated: Partial<AgentConfig> = {};
  const errors: string[] = [];

  for (const key of intervalKeys) {
    if (key in body) {
      const val = Number(body[key]);
      if (!Number.isFinite(val) || val < 5_000 || val > 300_000) {
        errors.push(`${key} must be between 5000 and 300000 ms`);
      } else {
        (agentConfig as Record<string, number>)[key] = val;
        (updated as Record<string, number>)[key] = val;
      }
    }
  }
  for (const key of scoreKeys) {
    if (key in body) {
      const val = Number(body[key]);
      if (!Number.isFinite(val) || val < 0 || val > 100) {
        errors.push(`${key} must be between 0 and 100`);
      } else {
        (agentConfig as Record<string, number>)[key] = val;
        (updated as Record<string, number>)[key] = val;
      }
    }
  }

  if (errors.length > 0) {
    res.status(400).json({ ok: false, errors, config: agentConfig });
    return;
  }

  console.log('[Agent] Config updated:', JSON.stringify(updated));
  res.json({ ok: true, config: agentConfig, updated });
});

// ─────────────────────────────────────────────────────────────────
// POST /api/config/reset — restore all defaults
// ─────────────────────────────────────────────────────────────────
app.post('/api/config/reset', (_req, res) => {
  agentConfig = { ...DEFAULT_CONFIG };
  console.log('[Agent] Config reset to defaults');
  res.json({ ok: true, config: agentConfig });
});

// ─────────────────────────────────────────────────────────────────
// Screening cache — rebuilt lazily on first request, then every 5 min
// ─────────────────────────────────────────────────────────────────
let _screeningCache: ReturnType<typeof screen>[] | null = null;
let _screeningCacheAt = 0;
const SCREENING_CACHE_TTL_MS = 5 * 60 * 1000;

function getScreeningReports(): ReturnType<typeof screen>[] {
  const now = Date.now();
  if (_screeningCache && (now - _screeningCacheAt) < SCREENING_CACHE_TTL_MS) {
    return _screeningCache;
  }
  const reports = listKnownProtocols().map(slug => {
    const data = buildProtocolData(slug);
    return data ? screen(data) : null;
  }).filter((r): r is ReturnType<typeof screen> => r !== null);
  _screeningCache = reports;
  _screeningCacheAt = now;
  return reports;
}

// ─────────────────────────────────────────────────────────────────
// GET /api/screening/latest
// Returns the most recent advisory screening report for all known
// protocols, derived from static profiles + SC Malaysia rule engine.
//
// Task D spec:
//   - output is advisory only (never writes scores on-chain)
//   - CoinGecko raw data is never exposed in any response
//   - board/permitted-assets.json has USDC, ETH, PAXG only (no OUSG/BUIDL)
// ─────────────────────────────────────────────────────────────────
app.get('/api/screening/latest', (_req, res) => {
  const reports = getScreeningReports();
  const summary = {
    pass:   reports.filter(r => r.verdict === 'PASS').length,
    review: reports.filter(r => r.verdict === 'REVIEW').length,
    fail:   reports.filter(r => r.verdict === 'FAIL').length,
  };
  res.json({
    advisory: true,
    disclaimer: 'Screening output is advisory only. A qualified Shariah advisor must review before any on-chain deployment. This report does not constitute a board pronouncement.',
    generatedAt: Math.floor(_screeningCacheAt / 1000),
    ruleVersion: reports[0]?.ruleVersion ?? '1.0.0',
    summary,
    reports,
    permittedAssets: permittedAssetsJson,
  });
});

// ─────────────────────────────────────────────────────────────────
// POST /api/apy/estimate
// Returns P10 / P50 / P90 APY scenario estimates for a Shariah vault.
//
// Task E spec:
//   - Returns P10/P50/P90 with disclaimer; never a single number
//   - APY panel in UI shows disclaimer always visible
//   - This endpoint is advisory only — it never reads or writes chain state
// ─────────────────────────────────────────────────────────────────
app.post('/api/apy/estimate', (req, res) => {
  const body = req.body as {
    strategyIds?:       number[];  // which Shariah strategy indices to include (0-5)
    hurdleRateBps?:     number;    // default 400 (4%)
    musharakahShareBps?: number;   // default 1000 (10%)
    charityBps?:        number;    // default 250 (2.5%)
    purificationBps?:   number;    // default 0
    timeHorizonDays?:   number;    // default 365
  };

  const hurdleRateBps      = Math.min(Math.max(0, body.hurdleRateBps      ?? 400),  2000);
  const musharakahShareBps = Math.min(Math.max(0, body.musharakahShareBps ?? 1000), 5000);
  const charityBps         = Math.min(Math.max(0, body.charityBps         ?? 250),   500);
  const purificationBps    = Math.min(Math.max(0, body.purificationBps    ?? 0),    1000);
  const timeHorizonDays    = Math.min(Math.max(1, body.timeHorizonDays    ?? 365),  3650);
  const strategyIds        = body.strategyIds ?? [0, 1, 2, 3, 5]; // active strategies

  // Strategy gross-yield assumptions (simulated, not live data):
  // These represent the P10/P50/P90 gross yield range for each strategy
  // based on historical analogues. NOT a prediction or guarantee.
  const STRATEGY_YIELD_RANGES: Record<number, { p10: number; p50: number; p90: number; name: string }> = {
    0: { p10: 0.5,  p50: 1.5,  p90: 4.0,  name: 'S1-H ETH Spread' },
    1: { p10: 0.3,  p50: 1.2,  p90: 3.5,  name: 'S2-H Gold Spread' },
    2: { p10: 2.0,  p50: 4.5,  p90: 9.0,  name: 'S3-H LP swap fees' },
    3: { p10: 1.0,  p50: 2.5,  p90: 5.0,  name: 'S4-H Murabaha' },
    4: { p10: 0.0,  p50: 0.0,  p90: 0.0,  name: 'S5-H RESERVED (disabled)' },
    5: { p10: 0.5,  p50: 1.8,  p90: 4.2,  name: 'S6-H Gold Allocation' },
  };

  // Aggregate gross yield across selected strategies (simple average — conservative)
  const selected = strategyIds.filter(id => id >= 0 && id <= 5 && id !== 4);
  const agg = (pct: 'p10' | 'p50' | 'p90') => {
    if (selected.length === 0) return 0;
    return selected.reduce((sum, id) => sum + (STRATEGY_YIELD_RANGES[id]?.[pct] ?? 0), 0) / selected.length;
  };

  const grossP10 = agg('p10');
  const grossP50 = agg('p50');
  const grossP90 = agg('p90');

  // Waterfall deductions: purification + charity + musharakah share + hurdle
  const wakalaFeeApy = 0.5; // 0.5% AUM/yr Wakala fee
  const totalDeductionFactor = (1 - purificationBps / 10_000) * (1 - charityBps / 10_000);

  function depositorNetApy(grossApy: number): number {
    const hurdleApy = hurdleRateBps / 10_000 * 100;
    if (grossApy <= hurdleApy) return Math.max(0, grossApy - wakalaFeeApy);
    const surplusApy = grossApy - hurdleApy;
    const depositorSurplus = surplusApy * (1 - musharakahShareBps / 10_000) * totalDeductionFactor;
    return Math.max(0, hurdleApy + depositorSurplus - wakalaFeeApy);
  }

  const netP10 = depositorNetApy(grossP10);
  const netP50 = depositorNetApy(grossP50);
  const netP90 = depositorNetApy(grossP90);

  res.json({
    disclaimer: [
      'These are illustrative scenario estimates only — NOT a prediction, guarantee, or projection.',
      'Actual returns depend on market conditions, strategy execution, and protocol risk.',
      'Past performance analogues used for P10/P50/P90 ranges are not indicative of future results.',
      'This output is advisory only and must not be presented as a Shariah board endorsement.',
      'Always display this disclaimer alongside any APY estimate shown to end users.',
    ],
    inputs: {
      strategyIds: selected,
      strategies: selected.map(id => STRATEGY_YIELD_RANGES[id]?.name ?? `S${id}-H`),
      hurdleRateBps,
      musharakahShareBps,
      charityBps,
      purificationBps,
      timeHorizonDays,
      wakalaFeeApyPct: wakalaFeeApy,
    },
    grossApyPct:     { p10: +grossP10.toFixed(2), p50: +grossP50.toFixed(2), p90: +grossP90.toFixed(2) },
    depositorNetApyPct: { p10: +netP10.toFixed(2), p50: +netP50.toFixed(2), p90: +netP90.toFixed(2) },
    strategyBreakdown: selected.map(id => ({
      id,
      name: STRATEGY_YIELD_RANGES[id]?.name,
      grossApyRange: STRATEGY_YIELD_RANGES[id] ? {
        p10: STRATEGY_YIELD_RANGES[id].p10,
        p50: STRATEGY_YIELD_RANGES[id].p50,
        p90: STRATEGY_YIELD_RANGES[id].p90,
      } : null,
    })),
  });
});

// GET /api/screening/:protocol — single protocol report
app.get('/api/screening/:protocol', (req, res) => {
  const slug = req.params.protocol;
  const data = buildProtocolData(slug);
  if (!data) {
    res.status(404).json({ ok: false, error: `Protocol '${slug}' not in static registry. Known protocols: ${listKnownProtocols().join(', ')}` });
    return;
  }
  const report = screen(data);
  res.json({ advisory: true, report });
});

const PORT = parseInt(process.env.AGENT_PORT ?? '3001', 10);
app.listen(PORT, () => {
  console.log(`[Agent] HTTP server on :${PORT}`);
  console.log(`[Agent] Vault:       ${VAULT_ADDRESS      || '(not configured)'}`);
  console.log(`[Agent] Aggregator:  ${AGGREGATOR_ADDRESS || '(not configured)'}`);
  console.log(`[Agent] Executor:    ${EXECUTOR_ADDRESS   || '(not configured)'}`);
  console.log('[Agent] Starting autonomous scan loops…');
  console.log('[Agent]   Strategy 1 (Stablecoin Spread):  every 30s');
  console.log('[Agent]   Strategy 2 (Funding Rate Arb):   every 30s');
  console.log('[Agent]   Strategy 3 (Bridge Flow):        event-driven (polling every 30s)');
  console.log('[Agent]   Strategy 4 (Liquidation + RWA):  every 45s');
});

// ─────────────────────────────────────────────────────────────────
// Main agent loop
//
// Strategies 1, 2, 3 run every 30s.
// Strategy 4 runs on a separate 45s timer.
// Strategy 3 is "event-driven" — in production a watchContractEvent
// listener replaces the polling. The poller fires the same scoring
// function that the event handler would call.
// ─────────────────────────────────────────────────────────────────
running = true;

let lastS4At = 0;           // track when Strategy 4 last ran
let lastSignalsAt = 0;      // track when protocol signals last fetched (every 60s)

(async () => {
  // Initial scan of all 4 to populate state before first timer fires
  try {
    const scan = await runScan();
    latestStrategies = scan.strategies;
    latestRaw = scan.raw;
    cycleCount++;
    lastCycleAt = Date.now();
    await writeScoresToChain(scan.strategies, Math.floor(Date.now() / 1000));
    lastS4At = Date.now();
    console.log('[Agent] Initial scan complete');
  } catch (err) {
    console.error('[Agent] Initial scan error:', (err as Error).message);
  }

  // 30s loop: S1 + S2 + S3 (event-driven simulation)
  const loop30 = async () => {
    const now = Date.now();
    try {
      const [spreadData, fundingData, bridgeData] = await Promise.all([
        fetchStablecoinSpreadData(),
        fetchFundingRateData(),
        fetchBridgeFlowData(),
      ]);

      latestStrategies[0] = scoreStablecoinSpread(spreadData);
      latestStrategies[1] = scoreFundingRate(fundingData);
      latestStrategies[2] = scoreBridgeFlow(bridgeData);
      latestRaw = { ...latestRaw!, spread: spreadData, funding: fundingData, bridge: bridgeData };

      // Strategy 4 runs on its own configurable cadence
      if (now - lastS4At >= agentConfig.strategy4IntervalMs) {
        const liqData = await fetchLiquidationRwaData();
        latestStrategies[3] = scoreLiquidationRwa(liqData);
        latestRaw.liquidation = liqData;
        lastS4At = now;
      }

      cycleCount++;
      lastCycleAt = now;
      // Refresh protocol signals every 60s
      if (now - lastSignalsAt >= agentConfig.protocolSignalsIntervalMs) {
        latestProtocolSignals = await fetchProtocolSignals();
        lastSignalsAt = now;
      }

      await writeScoresToChain(latestStrategies, Math.floor(now / 1000));
      if (AGGREGATOR_ADDRESS.length > 2) await triggerExecution(latestStrategies);
      await checkCctpAttestations();

      const winner = [...latestStrategies].reduce((a, b) => b.score > a.score ? b : a);
      const winnerIdx = latestStrategies.indexOf(winner);
      console.log(
        `[Agent] Cycle ${cycleCount} | ` +
        latestStrategies.map((s, i) => `${STRATEGY_NAMES[i].split(' ').pop()}: ${s.score}`).join(' | ') +
        ` | Winner: ${STRATEGY_NAMES[winnerIdx]} (${winner.score}) → ${winner.signal}`
      );
    } catch (err) {
      console.error('[Agent] Cycle error:', (err as Error).message);
    }
    setTimeout(() => { void loop30(); }, agentConfig.mainLoopIntervalMs);
  };

  // Start the main loop (already ran initial; wait for first repeat)
  setTimeout(() => { void loop30(); }, agentConfig.mainLoopIntervalMs);

  // ── Shariah vault background loop (30s / 45s cadence, mirrors conventional) ──
  const loopShariah = async () => {
    const now = Date.now();
    try {
      // Run S0-H (ETH_SPREAD), S1-H (GOLD_SPREAD), S2-H (HALAL_LP), S3-H (MURABAHA) every 30s.
      // S4-H (RESERVED_4 / RWA_SUKUK) is disabled per SR-001 — scoreRwaSukuk() returns score:0.
      const scan = await runShariahScan();

      latestShariahScan = scan;
      lastShariahCycleAt = now;
      shariahCycleCount++;

      const strategies = Object.entries(scan);
      // Winner excludes index 4 (disabled) — filter by score > 0
      const winner = strategies
        .filter(([, v]) => v !== null && (v?.score ?? 0) > 0)
        .reduce((a, b) => ((b[1]?.score ?? 0) > (a[1]?.score ?? 0) ? b : a), strategies[0]);

      console.log(
        `[Shariah] Cycle ${shariahCycleCount} | ` +
        strategies
          .map(([k, v]) => `${k}: ${v?.score === 0 && k === 'RWA_SUKUK' ? 'DISABLED' : (v?.score ?? '?')}`)
          .join(' | ') +
        ` | Winner: ${winner?.[0]} (${winner?.[1]?.score ?? 0})`
      );
    } catch (err) {
      console.error('[Shariah] Cycle error:', (err as Error).message);
    }
    setTimeout(() => { void loopShariah(); }, 30_000);
  };

  // Kick off Shariah loop immediately
  void loopShariah();
})();
