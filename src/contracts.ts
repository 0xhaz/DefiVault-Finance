/**
 * Contract ABIs and addresses for the DeFiVault system.
 * Replace the placeholder addresses below after deploying the contracts.
 */

/** CCTP domain → human-readable chain name */
export const CCTP_DOMAIN_NAMES: Record<number, string> = {
  0:  'Local',
  1:  'Avalanche Fuji',
  2:  'OP Sepolia',
  3:  'Arb Sepolia',
  6:  'Base Sepolia',
  7:  'Polygon Amoy',
  10: 'Unichain Sepolia',
  26: 'Arc',
};

/** Short two-letter badge labels */
export const CCTP_DOMAIN_BADGES: Record<number, string> = {
  0:  'ARC',
  1:  'AVA',
  2:  'OP',
  3:  'ARB',
  6:  'BASE',
  7:  'POL',
  10: 'UNI',
  26: 'ARC',
};

export const VAULT_ADDRESS = (import.meta.env.VITE_VAULT_ADDRESS ?? '') as `0x${string}`;
export const AGGREGATOR_ADDRESS = (import.meta.env.VITE_AGGREGATOR_ADDRESS ?? '') as `0x${string}`;
export const EXECUTOR_ADDRESS = (import.meta.env.VITE_EXECUTOR_ADDRESS ?? '') as `0x${string}`;
export const TRACKER_ADDRESS = (import.meta.env.VITE_TRACKER_ADDRESS ?? '') as `0x${string}`;

export const VAULT_ABI = [
  {
    type: 'function', name: 'totalAssets', stateMutability: 'view',
    inputs: [], outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function', name: 'totalDeployed', stateMutability: 'view',
    inputs: [], outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function', name: 'totalSupply', stateMutability: 'view',
    inputs: [], outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function', name: 'maxAllocationBps', stateMutability: 'view',
    inputs: [], outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function', name: 'paused', stateMutability: 'view',
    inputs: [], outputs: [{ name: '', type: 'bool' }],
  },
  {
    type: 'function', name: 'manager', stateMutability: 'view',
    inputs: [], outputs: [{ name: '', type: 'address' }],
  },
  {
    type: 'function', name: 'balanceOf', stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function', name: 'convertToAssets', stateMutability: 'view',
    inputs: [{ name: 'shares', type: 'uint256' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function', name: 'deposit', stateMutability: 'nonpayable',
    inputs: [
      { name: 'assets', type: 'uint256' },
      { name: 'receiver', type: 'address' },
    ],
    outputs: [{ name: 'shares', type: 'uint256' }],
  },
  {
    type: 'function', name: 'redeem', stateMutability: 'nonpayable',
    inputs: [
      { name: 'shares', type: 'uint256' },
      { name: 'receiver', type: 'address' },
      { name: 'owner', type: 'address' },
    ],
    outputs: [{ name: 'assets', type: 'uint256' }],
  },
  {
    type: 'function', name: 'sourceDomain', stateMutability: 'view',
    inputs: [], outputs: [{ name: '', type: 'uint32' }],
  },
  {
    type: 'function', name: 'tokenMessenger', stateMutability: 'view',
    inputs: [], outputs: [{ name: '', type: 'address' }],
  },
  {
    type: 'function', name: 'settleCrossChain', stateMutability: 'nonpayable',
    inputs: [{ name: 'nonce', type: 'uint64' }],
    outputs: [],
  },
  {
    type: 'event', name: 'CapitalDeployed',
    inputs: [
      { name: 'strategy', type: 'address', indexed: true },
      { name: 'amount', type: 'uint256', indexed: false },
    ],
  },
  {
    type: 'event', name: 'CapitalReturned',
    inputs: [
      { name: 'strategy', type: 'address', indexed: true },
      { name: 'amount', type: 'uint256', indexed: false },
    ],
  },
  {
    type: 'event', name: 'CapitalDeployedCrossChain',
    inputs: [
      { name: 'destinationDomain', type: 'uint32', indexed: true },
      { name: 'recipient', type: 'bytes32', indexed: true },
      { name: 'amount', type: 'uint256', indexed: false },
      { name: 'nonce', type: 'uint64', indexed: false },
    ],
  },
  {
    type: 'event', name: 'CrossChainSettled',
    inputs: [
      { name: 'nonce', type: 'uint64', indexed: true },
      { name: 'amount', type: 'uint256', indexed: false },
    ],
  },
] as const;

export const AGGREGATOR_ABI = [
  {
    type: 'function', name: 'getAllScores', stateMutability: 'view',
    inputs: [],
    outputs: [
      { name: 'values', type: 'uint8[4]' },
      { name: 'timestamps', type: 'uint40[4]' },
      { name: 'destinationDomains', type: 'uint32[4]' },
    ],
  },
  {
    type: 'function', name: 'getWinningStrategy', stateMutability: 'view',
    inputs: [],
    outputs: [
      { name: 'strategy', type: 'uint8' },
      { name: 'score', type: 'uint8' },
      { name: 'destinationDomain', type: 'uint32' },
    ],
  },
  {
    type: 'function', name: 'oracle', stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'address' }],
  },
  {
    type: 'event', name: 'ScoreUpdated',
    inputs: [
      { name: 'strategy', type: 'uint8', indexed: true },
      { name: 'value', type: 'uint8', indexed: false },
      { name: 'timestamp', type: 'uint40', indexed: false },
      { name: 'dataHash', type: 'bytes32', indexed: false },
      { name: 'destinationDomain', type: 'uint32', indexed: false },
    ],
  },
] as const;

export const EXECUTOR_ABI = [
  {
    type: 'function', name: 'minScoreToExecute', stateMutability: 'view',
    inputs: [], outputs: [{ name: '', type: 'uint8' }],
  },
  {
    type: 'function', name: 'executionCooldown', stateMutability: 'view',
    inputs: [], outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function', name: 'lastExecutionTime', stateMutability: 'view',
    inputs: [], outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function', name: 'maxGasPrice', stateMutability: 'view',
    inputs: [], outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function', name: 'executeWinner', stateMutability: 'nonpayable',
    inputs: [], outputs: [],
  },
  {
    type: 'event', name: 'ExecutionTriggered',
    inputs: [
      { name: 'strategy', type: 'uint8', indexed: true },
      { name: 'score', type: 'uint8', indexed: false },
      { name: 'amount', type: 'uint256', indexed: false },
      { name: 'target', type: 'address', indexed: true },
    ],
  },
] as const;

export const TRACKER_ABI = [
  {
    type: 'function', name: 'positionCount', stateMutability: 'view',
    inputs: [], outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function', name: 'getActivePositions', stateMutability: 'view',
    inputs: [],
    outputs: [
      {
        name: 'activePositions',
        type: 'tuple[]',
        components: [
          { name: 'id', type: 'uint256' },
          { name: 'strategy', type: 'uint8' },
          { name: 'target', type: 'address' },
          { name: 'amountDeployed', type: 'uint256' },
          { name: 'entryTimestamp', type: 'uint256' },
          { name: 'exitTimestamp', type: 'uint256' },
          { name: 'pnl', type: 'uint256' },
          { name: 'pnlNet', type: 'int256' },
          { name: 'status', type: 'uint8' },
          { name: 'txHash', type: 'bytes32' },
        ],
      },
    ],
  },
  {
    type: 'function', name: 'getTotalPnl', stateMutability: 'view',
    inputs: [],
    outputs: [{ name: 'totalPnl', type: 'int256' }],
  },
  {
    type: 'event', name: 'PositionOpened',
    inputs: [
      { name: 'id', type: 'uint256', indexed: true },
      { name: 'strategy', type: 'uint8', indexed: true },
      { name: 'target', type: 'address', indexed: true },
      { name: 'amount', type: 'uint256', indexed: false },
    ],
  },
  {
    type: 'event', name: 'PositionClosed',
    inputs: [
      { name: 'id', type: 'uint256', indexed: true },
      { name: 'returnAmount', type: 'uint256', indexed: false },
      { name: 'pnlNet', type: 'int256', indexed: false },
    ],
  },
] as const;

export const STRATEGY_NAMES = [
  'Cross-Chain Stablecoin Spread',
  'Perpetual Funding Rate Arb',
  'Bridge Flow Front-Running',
  'Liquidation + RWA Yield',
] as const;

// Strategy trigger modes shown on the card header
export const STRATEGY_TRIGGER_MODES = [
  'Every 30s',
  'Every 30s',
  'Event-driven',
  'Every 45s',
] as const;

// Lucide icon name per strategy (rendered in card header)
export const STRATEGY_ICONS = [
  'ArrowLeftRight',   // cross-chain spread
  'Zap',             // funding rate (fast signal)
  'Clock',           // event-driven / timing
  'Scale',           // liquidation + RWA balance
] as const;

// Long description paragraph shown on the card
export const STRATEGY_DESCRIPTIONS = [
  'Reads ETH/USDC pricing across chains and converts local pool ratios into implied USDC/USD dislocations.',
  'Reads Hyperliquid funding for ETH perps and annualizes the 8-hour rate into an always-on carry signal.',
  'Listens for large Stargate bridge transfers, estimates destination pool impact, and surfaces short-lived pre-positioning windows.',
  'Combines Aave liquidation stress with the spread between OUSG yield and on-chain borrow rates to create a blended score.',
] as const;

// Input/signal/rule rows shown per card (matches screenshots)
export const STRATEGY_DETAILS: Array<{ inputs: string; signal: string; rule: string }> = [
  {
    inputs: 'Uniswap V3 ETH/USDC pools on Arbitrum, Base, and Optimism',
    signal: 'max cross-chain USDC deviation',
    rule:   'spread above 0.3% becomes actionable',
  },
  {
    inputs: "Hyperliquid `metaAndAssetCtxs` funding data",
    signal: 'annualized funding APY',
    rule:   'APY above 12% yields the top score band',
  },
  {
    inputs: 'bridge transfer events plus destination liquidity reads',
    signal: 'transfer size and expected impact on arrival',
    rule:   'amount above $500K and impact above 0.4%',
  },
  {
    inputs: 'Aave health factors, Aave borrow rate, OUSG yield',
    signal: 'at-risk positions plus Treasury-versus-DeFi carry',
    rule:   '7 at-risk positions (+40) and spread above 1.5% (+50)',
  },
];

export const STRATEGY_COLORS = [
  '#acc6e9',
  '#8dd89f',
  '#f0b429',
  '#e86d7a',
] as const;
