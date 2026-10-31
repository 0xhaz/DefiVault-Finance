import { VaultStats } from '../components/VaultStats';
import { StrategyScores } from '../components/StrategyScores';
import { AgentStatus } from '../components/AgentStatus';
import { AgentActivityFeed } from '../components/AgentActivityFeed';
import { VaultPicker } from '../components/VaultPicker';
import type { Page } from '../components/Sidebar';
import type { VaultMode, TierSelection } from '../App';

interface DashboardPageProps {
  selectedTier:         TierSelection;
  onSelectTier:         (t: TierSelection) => void;
  onAgentRunningChange: (v: boolean) => void;
  onNavigate:           (p: Page) => void;
  vaultMode:            VaultMode;
}

const TIER_META: Record<TierSelection, { label: string; color: string; desc: string }> = {
  passive:              { label: 'PASSIVE',               color: '#acc6e9', desc: 'Strategies: S1 + S4 · Protocols: Compound V3, Curve 3pool' },
  aggressive:           { label: 'AGGRESSIVE',            color: '#f0b429', desc: 'All 4 strategies · Protocols: Aave 2x Loop, GMX GLP, Compound, Curve' },
  'shariah-conservative': { label: 'SHARIAH CONSERVATIVE', color: '#8dd89f', desc: '3 low-vol screened strategies · Gold Spread, LP, Gold Allocation · Wakala 0.5%' },
  'shariah-dynamic':    { label: 'SHARIAH DYNAMIC',       color: '#a8d4e8', desc: '5 screened strategies · Full Shariah universe · Wakala 0.5% + Musharakah 10%' },
};

export function DashboardPage({ selectedTier, onSelectTier, onAgentRunningChange, vaultMode }: DashboardPageProps) {
  const meta = TIER_META[selectedTier];

  return (
    <div className="space-y-6">
      <div>
        <h1 className="display text-2xl font-bold" style={{ color: 'var(--ink)', letterSpacing: '-0.03em' }}>Dashboard</h1>
        <p className="text-sm mt-1" style={{ color: 'var(--subtle)' }}>Live overview of vault performance and agent activity</p>
      </div>

      <VaultPicker selectedTier={selectedTier} onSelect={onSelectTier} vaultMode={vaultMode} />
      <VaultStats />

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <div className="lg:col-span-2 space-y-6">
          {/* Active tier banner */}
          <div
            className="rounded-lg px-4 py-2.5 flex items-center gap-3"
            style={{
              background: `${meta.color}0f`,
              border: `1px solid ${meta.color}26`,
            }}
          >
            <span
              className="text-xs font-semibold px-2 py-0.5 rounded-full"
              style={{ background: `${meta.color}1a`, color: meta.color }}
            >
              {meta.label}
            </span>
            <p className="text-xs" style={{ color: 'var(--subtle)' }}>{meta.desc}</p>
          </div>

          {/* Strategy scores — show Shariah set when a Shariah tier is active */}
          {(selectedTier === 'shariah-conservative' || selectedTier === 'shariah-dynamic') ? (
            <ShariahStrategyScores />
          ) : (
            <StrategyScores tier={selectedTier} />
          )}
          <AgentActivityFeed />
        </div>
        <div>
          <AgentStatus onRunningChange={onAgentRunningChange} />
        </div>
      </div>
    </div>
  );
}

/** Inline Shariah strategy scores pulled from /api/shariah, simulated fallback */
import { useState, useEffect } from 'react';
import { getSimShariahRows, type SimShariahRow } from '../lib/shariahSim';

function ShariahStrategyScores() {
  const [strategies, setStrategies] = useState<SimShariahRow[]>(() => getSimShariahRows());
  const [live, setLive] = useState(false);

  useEffect(() => {
    // Tick simulated scores every 5s when not live
    const simId = setInterval(() => {
      if (!live) setStrategies(getSimShariahRows());
    }, 5_000);

    async function load() {
      try {
        const r = await fetch('/api/shariah');
        if (r.ok) {
          const d = await r.json() as { strategies: SimShariahRow[]; online: boolean };
          if (d.strategies?.length) { setStrategies(d.strategies); setLive(d.online); }
        }
      } catch { /* keep simulated */ }
    }
    void load();
    const fetchId = setInterval(() => { void load(); }, 15_000);
    return () => { clearInterval(simId); clearInterval(fetchId); };
  }, [live]);

  return (
    <div className="rounded-xl p-5 space-y-3" style={{ background: 'var(--surface)', border: '1px solid var(--border)' }}>
      <div className="flex items-center justify-between mb-1">
        <p className="text-sm font-semibold" style={{ color: 'var(--ink-2)' }}>Shariah Strategies</p>
        <div className="flex items-center gap-2">
          {!live && (
            <span className="text-xs px-1.5 py-0.5 rounded font-medium"
              style={{ background: 'rgba(240,180,41,0.1)', color: '#f0b429', fontSize: '0.55rem' }}>SIM</span>
          )}
          <span className="text-xs px-2 py-0.5 rounded-full"
            style={{ background: 'rgba(141,216,159,0.1)', color: '#8dd89f', fontSize: '0.6rem' }}>SCREENED</span>
        </div>
      </div>
      {strategies.map(s => (
        <div key={s.id} className="space-y-1">
          <div className="flex items-center justify-between">
            <span className="text-xs font-medium" style={{ color: 'var(--ink-2)' }}>{s.name}</span>
            <span className="tabular-nums text-xs font-bold"
              style={{ color: s.score >= 75 ? '#8dd89f' : 'var(--subtle)' }}>{s.score}</span>
          </div>
          <div className="h-1 rounded-full overflow-hidden" style={{ background: 'var(--surface-muted)' }}>
            <div className="h-full rounded-full transition-all duration-500"
              style={{ width: `${s.score}%`, background: s.score >= 75 ? '#8dd89f' : 'var(--border)' }} />
          </div>
          {s.signalText && (
            <p className="text-xs" style={{ color: 'var(--subtle)', fontSize: '0.65rem' }}>{s.signalText}</p>
          )}
        </div>
      ))}
    </div>
  );
}
