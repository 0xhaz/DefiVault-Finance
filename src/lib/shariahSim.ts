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
}

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
    id: 1, key: 'GOLD_SPREAD', name: 'Tokenized Gold Spread',
    shariahBasis: 'Gold arbitrage — physical asset, universally halal',
    permittedAssets: ['USDC', 'PAXG'],
    baseScore: 65, amp: 22, freq: 0.8, phase: 1.2,
    signal: (s: number) => `PAXG/USDC deviation ${(s * 0.003).toFixed(3)}%`,
    threshold: 75, domain: 3,
  },
  {
    id: 2, key: 'HALAL_LP',   name: 'Halal Liquidity Pool',
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
  {
    id: 4, key: 'RWA_SUKUK',  name: 'RWA / Sukuk Yield',
    shariahBasis: 'Asset ownership yielding distributions — halal',
    permittedAssets: ['USDC', 'OUSG', 'BUIDL'],
    baseScore: 68, amp: 12, freq: 0.6, phase: 1.9,
    signal: (s: number) => `OUSG NAV $${(100 + s * 0.2).toFixed(4)}, est APY ${(4 + s * 0.02).toFixed(2)}%`,
    threshold: 75, domain: 0,
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
    };
  });
}

/** Strategy IDs eligible for the Conservative tier (Halal LP=2, Gold Spread=1, RWA/Sukuk=4) */
export const CONSERVATIVE_STRATEGY_IDS = new Set([1, 2, 4]);

/** Returns only the 3 low-vol strategies for the Conservative tier. */
export function getSimConservativeRows(now = Date.now()): SimShariahRow[] {
  return getSimShariahRows(now).filter(r => CONSERVATIVE_STRATEGY_IDS.has(r.id));
}

/** Returns the highest-scoring row among the provided rows. */
export function getSimWinner(rows: SimShariahRow[]): SimShariahRow {
  return rows.reduce((a, b) => b.score > a.score ? b : a);
}
