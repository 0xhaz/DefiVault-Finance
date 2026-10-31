/**
 * TreasuryPanel — shows live treasury state for both ConventionalTreasury and ShariahTreasury.
 * Reads from /api/shariah and /api/status for the accrued fee state.
 * Pre-deploy: shows simulated/zeroed accounting state.
 */
import { useState } from 'react';
import { Landmark, Moon, Shield, TrendingUp, DollarSign } from 'lucide-react';

interface TreasuryState {
  type: 'conventional' | 'shariah';
  pendingFees: string;          // formatted USDC
  totalFeesCollected: string;
  adminFeeBps: number;          // 75 = 0.75%, 50 = 0.5%
  musharakahShareBps: number;   // 0 for conventional, 1000 for shariah
  hurdleRateBps: number;        // 0 for conventional, 400 for shariah
  isShariahTreasury: boolean;
  lastAccrualAgo: number;       // seconds since last accrual, -1 = never
}

const MOCK_CONVENTIONAL: TreasuryState = {
  type: 'conventional',
  pendingFees: '0.00',
  totalFeesCollected: '0.00',
  adminFeeBps: 75,
  musharakahShareBps: 0,
  hurdleRateBps: 0,
  isShariahTreasury: false,
  lastAccrualAgo: -1,
};

const MOCK_SHARIAH: TreasuryState = {
  type: 'shariah',
  pendingFees: '0.00',
  totalFeesCollected: '0.00',
  adminFeeBps: 50,
  musharakahShareBps: 1000,
  hurdleRateBps: 400,
  isShariahTreasury: true,
  lastAccrualAgo: -1,
};

function TreasuryCard({ state }: { state: TreasuryState }) {
  const isShariah = state.isShariahTreasury;
  const color = isShariah ? '#c5b3f7' : '#acc6e9';
  const Icon = isShariah ? Moon : Shield;

  const rows = isShariah
    ? [
        { label: 'Annual Wakala fee', value: `${state.adminFeeBps / 100}%` },
        { label: 'Musharakah share', value: `${state.musharakahShareBps / 100}%` },
        { label: 'Hurdle rate', value: `${state.hurdleRateBps / 100}% APY` },
        { label: 'Charity deduction (sadaqah)', value: '2.5% of profits' },
      ]
    : [
        { label: 'Annual admin fee', value: `${state.adminFeeBps / 100}%` },
        { label: 'Performance fee', value: 'None' },
        { label: 'Fee model', value: 'Flat AUM' },
        { label: 'Compliance', value: 'GAAP standard' },
      ];

  return (
    <div
      className="rounded-xl p-4 space-y-3 flex-1"
      style={{ background: 'var(--surface)', border: `1px solid rgba(${isShariah ? '197,179,247' : '172,198,233'},0.2)` }}
    >
      {/* Title */}
      <div className="flex items-center gap-2">
        <div className="w-7 h-7 rounded-lg flex items-center justify-center" style={{ background: `${color}1a` }}>
          <Icon size={14} style={{ color }} />
        </div>
        <div>
          <p className="text-sm font-semibold" style={{ color: 'var(--ink-2)' }}>
            {isShariah ? 'Shariah Treasury' : 'Conventional Treasury'}
          </p>
          <p className="text-xs" style={{ color: 'var(--subtle)' }}>
            {isShariah ? 'Wakala + Musharakah' : '0.75% flat AUM fee'}
          </p>
        </div>
      </div>

      {/* Accrual stats */}
      <div className="grid grid-cols-2 gap-2">
        <div className="rounded-lg px-3 py-2" style={{ background: 'var(--surface-muted)' }}>
          <p className="text-xs" style={{ color: 'var(--subtle)', fontSize: '0.6rem' }}>PENDING FEES</p>
          <p className="tabular-nums text-sm font-semibold mt-0.5 flex items-center gap-1" style={{ color: 'var(--ink-2)' }}>
            <DollarSign size={11} style={{ color }} />
            {state.pendingFees}
          </p>
        </div>
        <div className="rounded-lg px-3 py-2" style={{ background: 'var(--surface-muted)' }}>
          <p className="text-xs" style={{ color: 'var(--subtle)', fontSize: '0.6rem' }}>TOTAL COLLECTED</p>
          <p className="tabular-nums text-sm font-semibold mt-0.5 flex items-center gap-1" style={{ color: 'var(--ink-2)' }}>
            <TrendingUp size={11} style={{ color }} />
            {state.totalFeesCollected}
          </p>
        </div>
      </div>

      {/* Fee params */}
      <div className="space-y-1.5 pt-2" style={{ borderTop: '1px solid var(--border)' }}>
        {rows.map(r => (
          <div key={r.label} className="flex items-center justify-between">
            <span className="text-xs" style={{ color: 'var(--subtle)' }}>{r.label}</span>
            <span className="text-xs font-semibold tabular-nums" style={{ color }}>{r.value}</span>
          </div>
        ))}
      </div>

      {/* Isolation badge */}
      <div
        className="rounded-lg px-3 py-2 flex items-center gap-2"
        style={{ background: 'rgba(141,216,159,0.05)', border: '1px solid rgba(141,216,159,0.1)' }}
      >
        <Landmark size={11} style={{ color: '#8dd89f' }} />
        <p className="text-xs" style={{ color: 'var(--subtle)' }}>
          Fully isolated — {isShariah ? 'Conventional' : 'Shariah'} funds never enter this treasury
        </p>
      </div>
    </div>
  );
}

export function TreasuryPanel({ isShariahTier: _isShariahTier }: { isShariahTier?: boolean }) {
  const [conventionalState] = useState<TreasuryState>(MOCK_CONVENTIONAL);
  const [shariahState] = useState<TreasuryState>(MOCK_SHARIAH);

  return (
    <section className="space-y-3">
      <div className="flex items-center gap-2">
        <Landmark size={13} style={{ color: 'var(--subtle)' }} />
        <h3 className="text-xs uppercase tracking-wider" style={{ color: 'var(--subtle)', letterSpacing: '0.08em' }}>
          Treasury Modules
        </h3>
      </div>

      <div className="flex flex-col md:flex-row gap-4">
        <TreasuryCard state={conventionalState} />
        <TreasuryCard state={shariahState} />
      </div>
    </section>
  );
}
