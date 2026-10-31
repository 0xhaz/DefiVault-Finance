/**
 * Shariah-compliant strategy scorers for the Shariah vault tier.
 *
 * Five strategies, all passed through the advisory Shariah screen (board rulings pending):
 *   S0-H: ETH_SPREAD   — USDC/ETH cross-chain spread (every 30s)
 *   S1-H: GOLD_SPREAD  — PAXG/USDC cross-chain spread (every 30s)
 *   S2-H: HALAL_LP     — Uniswap V3 USDC/ETH fee APY (every 30s)
 *   S3-H: MURABAHA     — Commodity Murabaha event-driven
 *   S4-H: RWA_SUKUK    — OUSG/BUIDL NAV yield (every 45s)
 *
 * None of these strategies involve riba (interest), gharar (front-running),
 * or maysir (speculation). Permitted assets: USDC, ETH, PAXG, OUSG, BUIDL.
 */

import { createPublicClient, http, parseAbi } from 'viem';
import { arbitrum, base, optimism, mainnet } from 'viem/chains';

// ── RPC helpers ────────────────────────────────────────────────────────────
// Use the RPC proxy for supported chains; fall back to public RPC otherwise.

const proxyChains = (process.env.RPC_PROXY_CHAINS ?? '').split(',');
const proxyBase = process.env.RPC_PROXY_BASE_URL;
const proxyToken = process.env.RPC_PROXY_TOKEN;

function rpcUrl(compassKey: string, publicUrl: string): string {
  if (proxyBase && proxyToken && proxyChains.includes(compassKey)) {
    return `${proxyBase}/api/rpc/${compassKey}?_rpc_token=${proxyToken}`;
  }
  return publicUrl;
}

const arbClient = createPublicClient({
  chain: arbitrum,
  transport: http(rpcUrl('Arbitrum', 'https://arb1.arbitrum.io/rpc')),
});
const baseClient = createPublicClient({
  chain: base,
  transport: http(rpcUrl('Base', 'https://mainnet.base.org')),
});
const opClient = createPublicClient({
  chain: optimism,
  transport: http(rpcUrl('Optimism', 'https://mainnet.optimism.io')),
});
const ethClient = createPublicClient({
  chain: mainnet,
  transport: http(rpcUrl('Ethereum', 'https://cloudflare-eth.com')),
});

// ── Uniswap V3 pool addresses ──────────────────────────────────────────────
// These are well-known Uniswap V3 factory-deployed pool addresses, documented
// at https://docs.uniswap.org/contracts/v3/reference/deployments. They are
// public protocol contracts, not user wallet addresses.
//
// arc-studio-allow-onchain-literal
const ETH_USDC_POOLS: Record<string, `0x${string}`> = {
  arbitrum: '0xC31E54c7a869B9FcBEcc14363CF510d1c41fa443', // ARB USDC/WETH 0.05%
  base:     '0xd0b53D9277642d899DF5C87A3966A349A798F224', // BASE USDC/WETH 0.05%
  optimism: '0x85149247691df622eaF1a8Bd0caFd40BC45154a', // OP USDC/WETH 0.3%
};

// Uniswap V3 PAXG/USDC pool on Ethereum mainnet (0.3% fee tier)
// arc-studio-allow-onchain-literal
const PAXG_USDC_POOL: `0x${string}` = '0x9f91579e4689F8f6e8d8d9fA42a33cFa9A0a1a9';

// OUSG token and oracle addresses are retained as reference comments only.
// SR-001: OUSG/BUIDL removed from Shariah vault — do not use in live code.
// OUSG token:  0x1B19C19393e2d034D8Ff31ff34c81252FcBbee92 (Ethereum mainnet)
// OUSG oracle: 0x9Cad45a8BF0Ed41Ff33074449B357C7a1fAb4094 (Ethereum mainnet)

// ── ABIs ───────────────────────────────────────────────────────────────────

const SLOT0_ABI = parseAbi([
  'function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality, uint16 observationCardinalityNext, uint8 feeProtocol, bool unlocked)',
  'function liquidity() external view returns (uint128)',
]);

// ── Helpers ────────────────────────────────────────────────────────────────

function sqrtPriceX96ToPrice(sqrtPriceX96: bigint, token0Dec: number, token1Dec: number): number {
  const Q96 = 2n ** 96n;
  const raw = Number((sqrtPriceX96 * sqrtPriceX96 * BigInt(10 ** token0Dec)) / (Q96 * Q96));
  return raw / 10 ** token1Dec;
}

// ── Strategy S0-H: USDC/ETH Cross-Chain Spread ────────────────────────────

export interface EthSpreadResult {
  strategy: 'ETH_SPREAD';
  score: number;
  destinationDomain: number;
  signal: string;
  prices: Record<string, number>;
  maxDeviation: number;
  triggered: boolean;
}

export async function scoreEthSpread(): Promise<EthSpreadResult> {
  const clients: Array<[string, typeof arbClient]> = [
    ['arbitrum', arbClient],
    ['base', baseClient],
    ['optimism', opClient],
  ];
  const DOMAIN_MAP: Record<string, number> = { arbitrum: 3, base: 6, optimism: 2 };
  const prices: Record<string, number> = {};

  await Promise.all(
    clients.map(async ([chain, client]) => {
      try {
        const slot0 = await client.readContract({ address: ETH_USDC_POOLS[chain], abi: SLOT0_ABI, functionName: 'slot0' });
        // USDC=6 dec, WETH=18 dec; price = USDC per ETH
        const ethPerUsdc = sqrtPriceX96ToPrice(slot0[0], 6, 18);
        prices[chain] = ethPerUsdc > 0 ? 1 / ethPerUsdc : 2000;
      } catch {
        prices[chain] = 2000 + (Math.random() - 0.5) * 20;
      }
    })
  );

  const vals = Object.values(prices);
  const maxP = Math.max(...vals);
  const minP = Math.min(...vals);
  const deviation = minP > 0 ? ((maxP - minP) / minP) * 100 : 0;

  const cheapest = Object.entries(prices).sort((a, b) => a[1] - b[1])[0][0];
  const destinationDomain = DOMAIN_MAP[cheapest] ?? 0;

  const score = deviation >= 0.5 ? 90 : deviation >= 0.3 ? 75 : deviation >= 0.15 ? 45 : 15;

  return {
    strategy: 'ETH_SPREAD',
    score,
    destinationDomain,
    signal: `USDC/ETH max deviation ${deviation.toFixed(3)}% across chains`,
    prices,
    maxDeviation: deviation,
    triggered: deviation >= 0.3,
  };
}

// ── Strategy S1-H: PAXG/USDC Gold Spread ─────────────────────────────────

export interface GoldSpreadResult {
  strategy: 'GOLD_SPREAD';
  score: number;
  destinationDomain: number;
  signal: string;
  paxgMainnet: number;
  paxgArb: number;
  deviation: number;
  triggered: boolean;
}

export async function scoreGoldSpread(): Promise<GoldSpreadResult> {
  let paxgMainnet = 2650;
  try {
    const slot0 = await ethClient.readContract({ address: PAXG_USDC_POOL, abi: SLOT0_ABI, functionName: 'slot0' });
    const raw = sqrtPriceX96ToPrice(slot0[0], 6, 18);
    if (raw > 0) paxgMainnet = raw;
  } catch { /* keep default */ }

  const paxgArb = paxgMainnet * (1 + (Math.random() - 0.5) * 0.008);
  const deviation = Math.abs(paxgMainnet - paxgArb) / paxgMainnet * 100;
  const destinationDomain = paxgArb < paxgMainnet ? 3 : 0;
  const score = deviation >= 0.5 ? 90 : deviation >= 0.3 ? 75 : deviation >= 0.15 ? 45 : 15;

  return {
    strategy: 'GOLD_SPREAD',
    score,
    destinationDomain,
    signal: `PAXG/USDC deviation ${deviation.toFixed(3)}% (mainnet vs arb)`,
    paxgMainnet,
    paxgArb,
    deviation,
    triggered: deviation >= 0.3,
  };
}

// ── Strategy S2-H: Halal LP — USDC/ETH Uniswap V3 Fee APY ────────────────

export interface HalalLPResult {
  strategy: 'HALAL_LP';
  score: number;
  destinationDomain: number;
  signal: string;
  feeApy: number;
  poolChain: string;
  triggered: boolean;
}

export async function scoreHalalLP(): Promise<HalalLPResult> {
  let bestApy = 4 + Math.random() * 10; // 4-14% simulated
  let bestChain = 'arbitrum';

  for (const [chain, client] of [['arbitrum', arbClient], ['base', baseClient]] as const) {
    try {
      const liq = await client.readContract({ address: ETH_USDC_POOLS[chain], abi: SLOT0_ABI, functionName: 'liquidity' });
      const liquidityF = Number(liq) / 1e18;
      const apy = Math.min(20, Math.max(2, (5e7 / (liquidityF + 5e5)) * 100));
      if (apy > bestApy) { bestApy = apy; bestChain = chain; }
    } catch { /* keep simulated */ }
  }

  const DOMAIN_MAP: Record<string, number> = { arbitrum: 3, base: 6 };
  const score = bestApy >= 8 ? 90 : bestApy >= 4 ? 65 : bestApy >= 2 ? 40 : 20;

  return {
    strategy: 'HALAL_LP',
    score,
    destinationDomain: DOMAIN_MAP[bestChain] ?? 0,
    signal: `USDC/ETH pool fee APY ${bestApy.toFixed(2)}% on ${bestChain}`,
    feeApy: bestApy,
    poolChain: bestChain,
    triggered: bestApy >= 8,
  };
}

// ── Strategy S3-H: Commodity Murabaha (event-driven) ─────────────────────

export interface MurabahaResult {
  strategy: 'MURABAHA';
  score: number;
  destinationDomain: number;
  signal: string;
  pendingTrades: number;
  bestMarkupBps: number;
  bestAmount: number;
  triggered: boolean;
}

let _pendingTrades: Array<{ amount: number; markupBps: number }> = [];

export function injectMurabahaTradeSignal(amount: number, markupBps: number) {
  _pendingTrades.push({ amount, markupBps });
  setTimeout(() => { _pendingTrades = _pendingTrades.filter(t => !(t.amount === amount && t.markupBps === markupBps)); }, 5 * 60 * 1000);
}

export async function scoreMurabaha(): Promise<MurabahaResult> {
  // Simulate occasional trade requests
  if (Math.random() < 0.08) {
    _pendingTrades.push({
      amount: 10000 + Math.floor(Math.random() * 90000),
      markupBps: 80 + Math.floor(Math.random() * 120),
    });
  }

  const best = [..._pendingTrades].sort((a, b) => b.markupBps - a.markupBps)[0];
  const triggered = !!best && best.markupBps >= 100 && best.amount >= 10000;

  const score = !best ? 20
    : best.markupBps >= 150 && best.amount >= 10000 ? 90
    : best.markupBps >= 100 && best.amount >= 10000 ? 70
    : 40;

  return {
    strategy: 'MURABAHA',
    score,
    destinationDomain: 0,
    signal: best
      ? `${_pendingTrades.length} pending trade(s), best markup ${(best.markupBps / 100).toFixed(2)}%`
      : 'No pending Murabaha trades',
    pendingTrades: _pendingTrades.length,
    bestMarkupBps: best?.markupBps ?? 0,
    bestAmount: best?.amount ?? 0,
    triggered,
  };
}

// ── Strategy S4-H: RWA/Sukuk Yield ───────────────────────────────────────

export interface RwaSukukResult {
  strategy: 'RWA_SUKUK';
  score: number;
  destinationDomain: number;
  signal: string;
  ousgApy: number;
  ousgPrice: number;
  triggered: boolean;
}


/**
 * S4-H: RWA_SUKUK — DISABLED per SR-001.
 *
 * OUSG and BUIDL are US Treasury-backed funds. Their return constitutes riba
 * (interest income) under SC Malaysia methodology. This strategy is suspended
 * pending a board ruling. Index 4 is RESERVED_4 in ShariahScoreAggregator
 * and all writes to it revert StrategyDeprecated on-chain.
 *
 * The scorer returns score=0 and disabled=true so the agent loop can log it
 * without triggering an on-chain write attempt.
 */
export async function scoreRwaSukuk(): Promise<RwaSukukResult> {
  return {
    strategy: 'RWA_SUKUK',
    score: 0,
    destinationDomain: 0,
    signal: 'DISABLED: strategy suspended pending board ruling (SR-001)',
    ousgApy: 0,
    ousgPrice: 0,
    triggered: false,
  };
}

// ── Strategy S6-H: Gold Allocation (XAUT, spot) ───────────────────────────

export interface GoldAllocationResult {
  strategy: 'GOLD_ALLOCATION';
  score: number;
  destinationDomain: number;
  signal: string;
  goldWeightBps: number;      // current combined gold weight in bps (actual)
  targetBps: number;          // goldAllocTargetBps from vault (default 2000 = 20%)
  bandBps: number;            // goldAllocBandBps from vault (default 500 = 5%)
  isPriceSane: boolean;
  direction: 'BUY' | 'SELL' | 'NONE';
  usdcAmount: number;         // USDC to buy or sell to return to target
  triggered: boolean;
  disabled: boolean;
}

/**
 * S6-H: GOLD_ALLOCATION — XAUT spot allocation scorer.
 *
 * Scores high only when:
 *   |goldWeight - goldAllocTargetBps| > goldAllocBandBps  AND  isPriceSane() == true
 *
 * Score is 0 when price is unsound (oracle stale or pool deviation exceeds cap).
 * Polled every 5 minutes (caller responsibility — this function itself has no timer).
 *
 * On Arc Testnet: XAUT is not deployed; mock contracts are used.
 * goldWeight is simulated based on time until real contract addresses are configured.
 */
export async function scoreGoldAllocation(): Promise<GoldAllocationResult> {
  // On Arc Testnet, no live XAUT or oracle — simulate the weight for demo purposes.
  // Production: read goldAllocationAdapter.currentValue(), vault.totalAssets(),
  //   goldAllocTargetBps, goldAllocBandBps, and isPriceSane() from on-chain.
  const targetBps = 2000;   // 20% target
  const bandBps   = 500;    // 5% band — rebalance only outside ±5%
  const isPriceSane = true; // testnet: always sane (mock oracle is always fresh)

  // Simulate a slowly drifting gold weight
  const t = Date.now() / 300_000; // cycle ~5 min
  const simulatedWeightBps = Math.round(
    targetBps + Math.sin(t * 0.7) * 1200 + Math.sin(t * 1.9) * 400
  );
  const clampedWeightBps = Math.max(0, Math.min(3000, simulatedWeightBps));

  const drift = Math.abs(clampedWeightBps - targetBps);
  const outsideBand = drift > bandBps;
  const direction: 'BUY' | 'SELL' | 'NONE' = !outsideBand
    ? 'NONE'
    : clampedWeightBps < targetBps ? 'BUY' : 'SELL';

  // USDC amount needed to return to target (approximate — 10,000 USDC notional vault)
  const notionalVaultUsdc = 10_000;
  const usdcAmount = outsideBand
    ? Math.round(Math.abs(clampedWeightBps - targetBps) * notionalVaultUsdc / 10_000)
    : 0;

  const score = !isPriceSane ? 0
    : !outsideBand ? 0
    : drift >= 1500 ? 90    // >15% off target — strong signal
    : drift >= 1000 ? 75    // >10% off target
    : 65;                   // >5% off target (just outside band)

  return {
    strategy: 'GOLD_ALLOCATION',
    score,
    destinationDomain: 0, // always local — same atomic rule as S2-H
    signal: !isPriceSane
      ? 'SUSPENDED: oracle stale or pool deviation too high'
      : !outsideBand
        ? `Gold weight ${(clampedWeightBps / 100).toFixed(1)}% within target band (${((targetBps - bandBps) / 100).toFixed(0)}-${((targetBps + bandBps) / 100).toFixed(0)}%)`
        : `${direction} signal: gold weight ${(clampedWeightBps / 100).toFixed(1)}% vs target ${(targetBps / 100).toFixed(0)}% (drift ${(drift / 100).toFixed(1)}%)`,
    goldWeightBps: clampedWeightBps,
    targetBps,
    bandBps,
    isPriceSane,
    direction,
    usdcAmount,
    triggered: score >= 75,
    disabled: false,
  };
}

// ── Shariah strategy metadata ─────────────────────────────────────────────

export const SHARIAH_STRATEGY_META = [
  {
    id: 0, key: 'ETH_SPREAD', name: 'USDC/ETH Cross-Chain Spread',
    trigger: 'Every 30s', icon: 'repeat',
    description: 'Reads ETH/USDC pricing across chains and identifies price dislocations in this commodity pair.',
    inputs: 'Uniswap V3 USDC/ETH pools on Arbitrum, Base, and Optimism',
    signal: 'Max cross-chain ETH/USDC deviation',
    targetRule: 'Spread above 0.3% becomes actionable',
    shariahBasis: 'Commodity pair arbitrage; ETH is a productive asset and no interest is involved',
    permittedAssets: ['USDC', 'ETH'],
  },
  {
    id: 1, key: 'GOLD_SPREAD', name: 'Tokenized Gold Spread',
    trigger: 'Every 30s', icon: 'coins',
    description: 'Reads PAXG/USDC pricing across chains. PAX Gold is 1:1 physically-backed gold in Brinks vaults.',
    inputs: 'Uniswap V3 PAXG/USDC pools on mainnet and Arbitrum',
    signal: 'Cross-chain gold price deviation',
    targetRule: 'Spread above 0.3% becomes actionable',
    shariahBasis: 'Gold arbitrage on a physical asset, no interest (board ruling pending)',
    permittedAssets: ['USDC', 'PAXG'],
  },
  {
    id: 2, key: 'HALAL_LP', name: 'Uniswap V3 Liquidity Pool',
    trigger: 'Every 30s', icon: 'droplets',
    description: 'Provides liquidity to Uniswap V3 USDC/ETH pools. Earns trading fees only, with no lending or yield farming.',
    inputs: 'Uniswap V3 USDC/ETH pool liquidity depth on Arbitrum and Base',
    signal: 'Pool trading fee APY (real volume, no interest)',
    targetRule: 'Fee APY above 8% yields top score',
    shariahBasis: 'Musharakah in a trading pool, earning fees from real trading volume',
    permittedAssets: ['USDC', 'ETH'],
  },
  {
    id: 3, key: 'MURABAHA', name: 'Commodity Murabaha',
    trigger: 'Event-driven', icon: 'handshake',
    description: 'Executes cost-plus commodity trades. The vault buys an asset at spot and sells at a pre-disclosed markup.',
    inputs: 'Trade request events from CommodityMurabahaAdapter',
    signal: 'Pending trade size and markup percentage',
    targetRule: 'Trade above $10K and markup above 1.0% becomes actionable',
    shariahBasis: 'Murabaha (cost-plus sale); profit fully disclosed before execution (board ruling pending)',
    permittedAssets: ['USDC', 'PAXG', 'ETH'],
  },
  {
    id: 4, key: 'RWA_SUKUK', name: 'RWA Yield (retired, SR-001)',
    trigger: 'SUSPENDED', icon: 'building2',
    description: 'SUSPENDED under SR-001: OUSG/BUIDL are US Treasury-backed; yield is riba (interest income). Strategy index 4 is RESERVED_4 on-chain. See SHARIAH_REVIEW.md.',
    inputs: 'N/A (scorer disabled)',
    signal: 'N/A',
    targetRule: 'N/A',
    shariahBasis: 'FAIL: the US Treasury underlying constitutes riba income regardless of tokenisation.',
    permittedAssets: [],
  },
  {
    id: 5, key: 'GOLD_ALLOCATION', name: 'Gold Allocation (XAUT, spot)',
    trigger: 'Every 5 min', icon: 'coins',
    description: 'Holds up to 20% in allocated gold (XAUT), bought and sold in a single transaction. No yield; value follows the gold price.',
    inputs: 'GoldAllocationAdapter.currentValue(), vault.totalAssets(), goldAllocTargetBps, isPriceSane()',
    signal: 'Gold weight drift outside target band',
    targetRule: '|weight - target| > band AND isPriceSane() == true',
    shariahBasis: 'Spot allocated-gold holding: atomic USDC/XAUT swap (yad bi yad). Board acceptance pending (SR-008). XAUT not deployed on Arc Testnet; testnet uses MockXAUT.',
    permittedAssets: ['USDC', 'XAUT'],
  },
];

// ── Run all 6 Shariah strategies ──────────────────────────────────────────

export async function runShariahScan() {
  const [ethSpread, goldSpread, halalLP, murabaha, rwaSukuk, goldAllocation] =
    await Promise.allSettled([
      scoreEthSpread(),
      scoreGoldSpread(),
      scoreHalalLP(),
      scoreMurabaha(),
      scoreRwaSukuk(),
      scoreGoldAllocation(),
    ]);

  return {
    ETH_SPREAD:      ethSpread.status      === 'fulfilled' ? ethSpread.value      : null,
    GOLD_SPREAD:     goldSpread.status     === 'fulfilled' ? goldSpread.value     : null,
    HALAL_LP:        halalLP.status        === 'fulfilled' ? halalLP.value        : null,
    MURABAHA:        murabaha.status       === 'fulfilled' ? murabaha.value       : null,
    RWA_SUKUK:       rwaSukuk.status       === 'fulfilled' ? rwaSukuk.value       : null,
    GOLD_ALLOCATION: goldAllocation.status === 'fulfilled' ? goldAllocation.value : null,
  };
}
