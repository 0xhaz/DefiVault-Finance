/**
 * Shared simulated Shariah strategy data.
 * Used by VaultPicker, DashboardPage, and StrategiesPage so all three
 * show the same consistent data while the agent is not reachable.
 * Scores oscillate deterministically so cards animate across refreshes.
 */

export interface SimShariahRow {
  id:              number;
  key:             string;
  name:            string;
  score:           number;
  triggered:       boolean;
  signalText:      string;
  shariahBasis:    string;
  permittedAssets: string[];
  destinationDomain: number;
  // Card text (same fields the live agent serves from /api/shariah)
  trigger?:     string;
  description?: string;
  inputs?:      string;
  signal?:      string;
  targetRule?:  string;
}

const META: Record<number, Pick<SimShariahRow, 'trigger' | 'description' | 'inputs' | 'signal' | 'targetRule'>> = {
  0: { trigger: 'Every 30s', description: 'Reads ETH/USDC pricing across chains and identifies price dislocations in this commodity pair.',
       inputs: 'Uniswap V3 USDC/ETH pools on Arbitrum, Base, and Optimism', signal: 'Max cross-chain ETH/USDC deviation', targetRule: 'Spread above 0.3% becomes actionable' },
  1: { trigger: 'Every 30s', description: 'Reads PAXG/USDC pricing across chains. PAX Gold is 1:1 physically-backed gold in Brinks vaults.',
       inputs: 'Uniswap V3 PAXG/USDC pools on mainnet and Arbitrum', signal: 'Cross-chain gold price deviation', targetRule: 'Spread above 0.3% becomes actionable' },
  2: { trigger: 'Every 30s', description: 'Provides liquidity to Uniswap V3 USDC/ETH pools. Earns trading fees only — no lending or yield farming.',
       inputs: 'Uniswap V3 USDC/ETH pool liquidity depth on Arbitrum and Base', signal: 'Pool trading fee APY (real volume, no interest)', targetRule: 'Fee APY above 8% yields top score' },
  3: { trigger: 'Event-driven', description: 'Executes cost-plus commodity trades. The vault buys an asset at spot and sells at a pre-disclosed markup.',
       inputs: 'Trade request events from CommodityMurabahaAdapter', signal: 'Pending trade size and markup percentage', targetRule: 'Trade above $10K and markup above 1.0% becomes actionable' },
  5: { trigger: 'Every 5 min', description: 'Holds up to 20% in allocated gold (XAUT), bought and sold in a single transaction. No yield; value follows the gold price.',
       inputs: 'Gold allocation adapter value, vault total assets, target weight, oracle sanity', signal: 'Gold weight drift outside target band', targetRule: 'Weight outside the target band while the oracle price is sane' },
};

const STRATEGIES = [
  {
    id: 0, key: 'ETH_SPREAD',  name: 'USDC/ETH Cross-Chain Spread',
    shariahBasis: 'Commodity pair arbitrage — no interest involved',
    permittedAssets: ['USDC', 'ETH'],
    baseScore: 72, amp: 18, freq: 1.1, phase: 0,
    signal: (s: number) => `ETH cross-chain deviation ${(s * 0.004).toFixed(3)}%`,
    threshold: 75, domain: 3,
  },
  {
    id: 1, key: 'GOLD_SPREAD', name: 'Atomic Gold Spread',
    shariahBasis: 'Gold allocation (spot) — single-tx atomic USDC/PAXG swap (yad bi yad). Cross-chain routing blocked by NonAtomicGoldExchange guard. Board ruling pending (SR-005, SR-006).',
    permittedAssets: ['USDC', 'PAXG'],
    baseScore: 65, amp: 22, freq: 0.8, phase: 1.2,
    signal: (s: number) => `PAXG/USDC deviation ${(s * 0.003).toFixed(3)}%`,
    threshold: 75, domain: 0, // 0 = local only; cross-chain is blocked by vault guard
  },
  {
    id: 2, key: 'HALAL_LP',   name: 'Uniswap V3 Liquidity Pool',
    shariahBasis: 'Musharakah in a trading pool — fee income only',
    permittedAssets: ['USDC', 'ETH'],
    baseScore: 70, amp: 15, freq: 1.4, phase: 2.4,
    signal: (s: number) => `Pool fee APY ${(4 + s * 0.08).toFixed(2)}% on arbitrum`,
    threshold: 75, domain: 6,
  },
  {
    id: 3, key: 'MURABAHA',   name: 'Commodity Murabaha',
    shariahBasis: 'Cost-plus sale — profit fully disclosed before execution',
    permittedAssets: ['USDC', 'PAXG', 'ETH'],
    baseScore: 35, amp: 45, freq: 0.4, phase: 0.7,
    signal: (s: number) => s > 75 ? '2 pending trades, best markup 1.4%' : 'No pending Murabaha trades',
    threshold: 75, domain: 0,
  },
  // id:4 (RESERVED_4) intentionally omitted — strategy suspended per SR-001.
  // OUSG/BUIDL are US Treasury-backed instruments; yield is interest income (riba).
  // See docs/agents/SHARIAH_REVIEW.md for board ruling stub.
  {
    id: 5, key: 'GOLD_ALLOCATION', name: 'Gold Allocation (XAUT, spot)',
    shariahBasis: 'Spot allocated-gold holding — single-tx atomic USDC/XAUT swap (yad bi yad). No yield; return follows gold price. Board acceptance pending (SR-008, SR-009). XAUT not yet deployed on Arc Testnet — testnet uses MockXAUT.',
    permittedAssets: ['USDC', 'XAUT'],
    baseScore: 45, amp: 30, freq: 0.6, phase: 3.1,
    signal: (s: number) => `Gold weight ${(s * 0.2).toFixed(1)}% vs target 20% (drift ${((s - 50) * 0.08).toFixed(2)}%)`,
    threshold: 75, domain: 0, // 0 = local only; same atomic rule as S2-H
  },
];

export function getSimShariahRows(now = Date.now()): SimShariahRow[] {
  const t = now / 30_000;
  return STRATEGIES.map(s => {
    const score = Math.round(Math.max(10, Math.min(99,
      s.baseScore + Math.sin(t * s.freq + s.phase) * s.amp + (Math.sin(t * s.freq * 2.3) * s.amp * 0.3)
    )));
    return {
      id:               s.id,
      key:              s.key,
      name:             s.name,
      score,
      triggered:        score >= s.threshold,
      signalText:       s.signal(score),
      shariahBasis:     s.shariahBasis,
      permittedAssets:  s.permittedAssets,
      destinationDomain: score >= s.threshold ? s.domain : 0,
      ...META[s.id],
    };
  });
}

/**
 * Strategy IDs eligible for the Conservative tier.
 * Mask 0b100110 = Gold Spread (bit1) + Halal LP (bit2) + Gold Allocation (bit5).
 * RWA_SUKUK (id:4) removed per SR-001.
 * GOLD_ALLOCATION (id:5) added per Task F.
 */
export const CONSERVATIVE_STRATEGY_IDS = new Set([1, 2, 5]);

/** Returns only the 3 low-vol Conservative strategies. */
export function getSimConservativeRows(now = Date.now()): SimShariahRow[] {
  return getSimShariahRows(now).filter(r => CONSERVATIVE_STRATEGY_IDS.has(r.id));
}

/** Returns the highest-scoring row among the provided rows. */
export function getSimWinner(rows: SimShariahRow[]): SimShariahRow {
  return rows.reduce((a, b) => b.score > a.score ? b : a);
}
