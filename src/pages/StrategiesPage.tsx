import { useState, useEffect } from 'react';
import { StrategyScores } from '../components/StrategyScores';
import { AgentStatus } from '../components/AgentStatus';
import { getSimShariahRows, type SimShariahRow } from '../lib/shariahSim';
import type { VaultMode, TierSelection } from '../App';

interface StrategiesPageProps {
  selectedTier:         TierSelection;
  onSelectTier:         (t: TierSelection) => void;
  onAgentRunningChange: (v: boolean) => void;
  vaultMode:            VaultMode;
}

type TabId = 'passive' | 'aggressive' | 'shariah-conservative' | 'shariah-dynamic';

const ALL_TABS: { id: TabId; label: string; color: string }[] = [
  { id: 'passive',              label: 'Passive',              color: '#acc6e9' },
  { id: 'aggressive',           label: 'Aggressive',           color: '#f0b429' },
  { id: 'shariah-conservative', label: 'Conservative Shariah', color: '#8dd89f' },
  { id: 'shariah-dynamic',      label: 'Dynamic Shariah',      color: '#c9b8f5' },
];

// ── Shariah strategy data ──────────────────────────────────────────
// Seeds from deterministic simulation immediately; replaces with live
// agent data from /api/shariah when the server is reachable.

function useShariahStrategies() {
  const [rows, setRows] = useState<SimShariahRow[]>(() => getSimShariahRows());
  const [online, setOnline] = useState(false);

  useEffect(() => {
    const simId = setInterval(() => {
      if (!online) setRows(getSimShariahRows());
    }, 5_000);

    async function load() {
      try {
        const r = await fetch('/api/shariah');
        if (r.ok) {
          const d = await r.json() as { strategies: SimShariahRow[]; online: boolean };
          if (d.strategies?.length > 0) { setRows(d.strategies); setOnline(d.online); }
        }
      } catch { /* keep simulated */ }
    }
    void load();
    const fetchId = setInterval(() => { void load(); }, 15_000);
    return () => { clearInterval(simId); clearInterval(fetchId); };
  }, [online]);

  return { rows, online };
}

const SHARIAH_COLORS = ['#8dd89f', '#a8d4e8', '#c9b8f5', '#f0c17a', '#e8a0a8', '#d4b896'];

function ShariahStrategyGrid({ minScore }: { minScore: number }) {
  const { rows, online } = useShariahStrategies();

  return (
    <div className="space-y-3">
      {!online && (
        <div
          className="rounded-lg px-4 py-2.5 flex items-center gap-2"
          style={{ background: 'rgba(240,180,41,0.06)', border: '1px solid rgba(240,180,41,0.15)' }}
        >
          <span className="w-1.5 h-1.5 rounded-full" style={{ background: '#f0b429' }} />
          <p className="text-xs" style={{ color: '#f0b429' }}>
            Showing simulated scores — agent server not reachable. Scores will update live once deployed.
          </p>
        </div>
      )}
      {rows.map((s, i) => {
        const eligible  = s.score >= minScore;
        const color     = SHARIAH_COLORS[i % SHARIAH_COLORS.length];
        return (
          <div
            key={s.id}
            className="rounded-xl p-4"
            style={{
              background: 'var(--surface)',
              border: `1px solid ${eligible ? color + '30' : 'var(--border)'}`,
              opacity: eligible ? 1 : 0.6,
            }}
          >
            <div className="flex items-start justify-between gap-3 mb-2">
              <div className="flex-1 min-w-0">
                <div className="flex items-center gap-2 flex-wrap">
                  <span className="text-sm font-semibold" style={{ color: 'var(--ink-2)' }}>{s.name}</span>
                  {eligible && (
                    <span className="text-xs px-1.5 py-0.5 rounded font-medium"
                      style={{ background: `${color}1a`, color, fontSize: '0.6rem' }}>
                      ELIGIBLE
                    </span>
                  )}
                  {s.triggered && (
                    <span className="text-xs px-1.5 py-0.5 rounded font-medium"
                      style={{ background: 'rgba(141,216,159,0.12)', color: '#8dd89f', fontSize: '0.6rem' }}>
                      TRIGGERED
                    </span>
                  )}
                  {!online && (
                    <span className="text-xs px-1.5 py-0.5 rounded font-medium"
                      style={{ background: 'rgba(240,180,41,0.08)', color: '#f0b429', fontSize: '0.55rem' }}>
                      SIM
                    </span>
                  )}
                </div>
                {s.shariahBasis && (
                  <p className="text-xs mt-0.5" style={{ color: 'var(--subtle)', fontSize: '0.65rem' }}>
                    {s.shariahBasis}
                  </p>
                )}
              </div>
              <div className="text-right flex-shrink-0">
                <p className="tabular-nums text-xl font-bold" style={{ color: eligible ? color : 'var(--border)', letterSpacing: '-0.02em' }}>
                  {s.score}
                </p>
                <p className="text-xs" style={{ color: 'var(--subtle)', fontSize: '0.6rem' }}>/ 100</p>
              </div>
            </div>

            {/* Score bar */}
            <div className="h-1 rounded-full overflow-hidden mb-2" style={{ background: 'var(--surface-muted)' }}>
              <div
                className="h-full rounded-full transition-all duration-500"
                style={{ width: `${s.score}%`, background: eligible ? color : 'var(--border)' }}
              />
            </div>

            {/* Signal + permitted assets */}
            <div className="flex items-center justify-between gap-2 flex-wrap">
              <p className="text-xs" style={{ color: 'var(--subtle)', fontSize: '0.65rem', flex: 1, minWidth: 0 }}>
                {s.signalText || 'Awaiting signal data'}
              </p>
              {s.permittedAssets?.length > 0 && (
                <div className="flex items-center gap-1 flex-shrink-0">
                  {s.permittedAssets.slice(0, 3).map((a: string) => (
                    <span key={a} className="text-xs px-1.5 py-0.5 rounded"
                      style={{ background: 'var(--surface-muted)', color: 'var(--subtle)', fontSize: '0.6rem' }}>
                      {a}
                    </span>
                  ))}
                </div>
              )}
            </div>
          </div>
        );
      })}
    </div>
  );
}

// ── Page component ───────────────────────────────────────────────

export function StrategiesPage({ selectedTier, onSelectTier, onAgentRunningChange, vaultMode }: StrategiesPageProps) {
  // Visible tabs based on vault mode
  const visibleTabs = ALL_TABS.filter(t => {
    const isShariahId = t.id === 'shariah-conservative' || t.id === 'shariah-dynamic';
    if (vaultMode === 'conventional') return !isShariahId;
    if (vaultMode === 'shariah')      return isShariahId;
    return true;
  });

  // If current tab is not visible in this mode, snap to first visible
  const effectiveTier: TabId = visibleTabs.some(t => t.id === selectedTier)
    ? (selectedTier)
    : (visibleTabs[0]?.id ?? 'passive');

  const isShariahTab = effectiveTier === 'shariah-conservative' || effectiveTier === 'shariah-dynamic';

  return (
    <div className="space-y-6">
      <div className="flex items-start justify-between gap-4 flex-wrap">
        <div>
          <h1 className="display text-2xl font-bold" style={{ color: 'var(--ink)', letterSpacing: '-0.03em' }}>Strategies</h1>
          <p className="text-sm mt-1" style={{ color: 'var(--subtle)' }}>
            {isShariahTab
              ? `Live scores for ${effectiveTier === 'shariah-conservative' ? '3' : '5'} active screened strategies${effectiveTier === 'shariah-conservative' ? ' (Conservative: Gold Spread + Halal LP + Gold Allocation)' : ''}`
              : 'Live scores for all 4 AI-scored signal strategies'}
          </p>
        </div>

        {/* Tier tabs */}
        <div className="flex rounded-lg overflow-hidden" style={{ border: '1px solid var(--border)' }}>
          {visibleTabs.map((t, i) => (
            <button
              key={t.id}
              onClick={() => onSelectTier(t.id)}
              className="px-4 py-2 text-xs font-semibold transition-all flex items-center gap-1.5"
              style={{
                background: effectiveTier === t.id ? 'rgba(255,255,255,0.08)' : 'transparent',
                color:      effectiveTier === t.id ? t.color : 'var(--subtle)',
                borderRight: i < visibleTabs.length - 1 ? '1px solid var(--border)' : 'none',
              }}
            >
              {t.label}

            </button>
          ))}
        </div>
      </div>

      {/* Legend */}
      <div
        className="rounded-lg px-4 py-3 flex flex-wrap items-center gap-4"
        style={{ background: 'var(--surface)', border: '1px solid var(--border)' }}
      >
        <p className="text-xs" style={{ color: 'var(--subtle)' }}>Strategy eligibility:</p>
        <div className="flex items-center gap-2">
          <span className="w-2 h-2 rounded-full" style={{ background: 'var(--accent)' }} />
          <span className="text-xs" style={{ color: 'var(--muted)' }}>Full opacity = eligible for selected tier</span>
        </div>
        <div className="flex items-center gap-2">
          <span className="w-2 h-2 rounded-full" style={{ background: 'var(--subtle)', opacity: 0.4 }} />
          <span className="text-xs" style={{ color: 'var(--muted)' }}>Dimmed = below min score or other tier</span>
        </div>
        {isShariahTab && (
          <div className="flex items-center gap-2">
            <span className="text-xs px-2 py-0.5 rounded"
              style={{ background: 'rgba(141,216,159,0.1)', color: '#8dd89f', fontSize: '0.6rem' }}>SCREENED</span>
            <span className="text-xs" style={{ color: 'var(--muted)' }}>Screened; board ruling pending</span>
          </div>
        )}
        {!isShariahTab && (
          <div className="flex items-center gap-2">
            <span className="text-xs px-2 py-0.5 rounded"
              style={{ background: 'rgba(240,180,41,0.1)', color: '#f0b429', fontSize: '0.6rem' }}>SIMULATED</span>
            <span className="text-xs" style={{ color: 'var(--muted)' }}>Agent scores (pre-deploy)</span>
          </div>
        )}
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <div className="lg:col-span-2">
          {isShariahTab
            ? <ShariahStrategyGrid minScore={75} />
            : <StrategyScores tier={effectiveTier} />
          }
        </div>
        <div>
          <p className="text-xs uppercase mb-3" style={{ color: 'var(--subtle)', letterSpacing: '0.08em' }}>Agent Engine</p>
          <AgentStatus onRunningChange={onAgentRunningChange} />
        </div>
      </div>
    </div>
  );
}
