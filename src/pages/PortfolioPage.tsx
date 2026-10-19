import { ActivePositions } from '../components/ActivePositions';
import { TrendingUp, TrendingDown, Minus, Briefcase } from 'lucide-react';

// Summary stats — show real values if available from PositionTracker, otherwise placeholder state
const PORTFOLIO_CARDS = [
  { label: 'Total Deployed',    value: '—',    sub: 'Awaiting deployment',    icon: <Briefcase  size={15} strokeWidth={1.8} />, color: '#acc6e9' },
  { label: 'Realized PnL',      value: '—',    sub: 'Closed positions',        icon: <TrendingUp size={15} strokeWidth={1.8} />, color: '#8dd89f' },
  { label: 'Open Positions',    value: '—',    sub: 'Active strategies',       icon: <Minus      size={15} strokeWidth={1.8} />, color: '#f0b429' },
  { label: 'Unrealized PnL',    value: '—',    sub: 'Mark-to-market',          icon: <TrendingDown size={15} strokeWidth={1.8} />, color: '#e86d7a' },
];

const HISTORY_EMPTY = true; // flip to false once contracts are deployed

export function PortfolioPage() {
  return (
    <div className="space-y-6">
      <div>
        <h1 className="display text-2xl font-bold" style={{ color: 'var(--ink)', letterSpacing: '-0.03em' }}>Portfolio</h1>
        <p className="text-sm mt-1" style={{ color: 'var(--subtle)' }}>Your positions, PnL, and capital history</p>
      </div>

      {/* Summary cards */}
      <div className="grid grid-cols-2 sm:grid-cols-4 gap-4">
        {PORTFOLIO_CARDS.map(c => (
          <div
            key={c.label}
            className="rounded-xl px-4 py-4"
            style={{ background: 'var(--surface)', border: '1px solid var(--border)' }}
          >
            <div
              className="w-7 h-7 rounded-lg flex items-center justify-center mb-3"
              style={{ background: `rgba(172,198,233,0.1)`, color: c.color }}
            >
              {c.icon}
            </div>
            <p className="display text-xl font-bold tabular-nums" style={{ color: 'var(--ink-2)', letterSpacing: '-0.02em' }}>{c.value}</p>
            <p className="text-xs font-medium mt-0.5" style={{ color: 'var(--muted)' }}>{c.label}</p>
            <p className="text-xs mt-0.5" style={{ color: 'var(--subtle)' }}>{c.sub}</p>
          </div>
        ))}
      </div>

      {/* Active positions */}
      <ActivePositions />

      {/* Trade history */}
      <section>
        <h2 className="text-xs uppercase mb-4" style={{ color: 'var(--subtle)', letterSpacing: '0.08em' }}>Trade History</h2>
        {HISTORY_EMPTY ? (
          <div
            className="rounded-xl px-6 py-12 flex flex-col items-center justify-center gap-3"
            style={{ background: 'var(--surface)', border: '1px solid var(--border)' }}
          >
            <div className="w-10 h-10 rounded-full flex items-center justify-center" style={{ background: 'rgba(255,255,255,0.05)' }}>
              <Briefcase size={18} style={{ color: 'var(--subtle)' }} />
            </div>
            <p className="text-sm font-medium" style={{ color: 'var(--muted)' }}>No closed positions yet</p>
            <p className="text-xs text-center" style={{ color: 'var(--subtle)', maxWidth: '28ch' }}>
              Once the agent executes and closes its first strategy, history will appear here.
            </p>
          </div>
        ) : (
          <div className="rounded-xl overflow-hidden" style={{ border: '1px solid var(--border)' }}>
            {/* Table would be populated from PositionTracker events once deployed */}
            <p className="text-xs px-5 py-4" style={{ color: 'var(--subtle)' }}>Closed positions from PositionTracker contract.</p>
          </div>
        )}
      </section>
    </div>
  );
}
