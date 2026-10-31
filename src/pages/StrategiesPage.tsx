import React, { useState, useEffect } from 'react';
import { Repeat, Coins, Droplets, Handshake, Building2 } from 'lucide-react';
import { StrategyScores, StrategyCardView } from '../components/StrategyScores';
import { CCTP_DOMAIN_BADGES, CCTP_DOMAIN_NAMES } from '../contracts';
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
const SHARIAH_ICONS: Record<number, React.ReactNode> = {
  0: <Repeat size={13} strokeWidth={2} />,
  1: <Coins size={13} strokeWidth={2} />,
  2: <Droplets size={13} strokeWidth={2} />,
  3: <Handshake size={13} strokeWidth={2} />,
  4: <Building2 size={13} strokeWidth={2} />,
  5: <Coins size={13} strokeWidth={2} />,
};
// Strategy ids each Shariah tier may fund (executor masks: Conservative 0b100110, Dynamic 0b101111).
const TIER_IDS: Record<'shariah-conservative' | 'shariah-dynamic', Set<number>> = {
  'shariah-conservative': new Set([1, 2, 5]),
  'shariah-dynamic':      new Set([0, 1, 2, 3, 5]),
};
const RETIRED_ID = 4;

function ShariahStrategyGrid({ tier }: { tier: 'shariah-conservative' | 'shariah-dynamic' }) {
  const { rows, online } = useShariahStrategies();
  const allowed = TIER_IDS[tier];
  const eligibleRows = rows.filter(r => allowed.has(r.id));
  const bestId = eligibleRows.length ? eligibleRows.reduce((a, b) => (b.score > a.score ? b : a)).id : null;

  return (
    <section>
      <div className="flex items-center justify-between mb-4">
        <h2 className="text-xs uppercase tracking-wider" style={{ color: 'var(--subtle)', letterSpacing: '0.08em' }}>
          Strategy Scores
        </h2>
        <span
          className="text-xs px-2 py-0.5 rounded"
          style={online
            ? { background: 'rgba(141,216,159,0.1)', color: '#8dd89f', border: '1px solid rgba(141,216,159,0.2)' }
            : { background: 'rgba(240,180,41,0.1)', color: '#f0b429', border: '1px solid rgba(240,180,41,0.2)' }}
        >
          {online ? 'Agent live' : 'Agent simulation'}
        </span>
      </div>

      <div className="grid gap-4 grid-cols-1 sm:grid-cols-2">
        {rows.map((r, i) => {
          const eligible = allowed.has(r.id);
          const isBest = eligible && r.id === bestId;
          const domain = r.destinationDomain ?? 0;
          const isCrosschain = domain !== 0;
          return (
            <StrategyCardView
              key={r.id}
              label={`Strategy S${r.id + 1}-H`}
              icon={SHARIAH_ICONS[r.id] ?? <Coins size={13} strokeWidth={2} />}
              trigger={r.trigger ?? ''}
              name={r.name}
              color={SHARIAH_COLORS[i % SHARIAH_COLORS.length]}
              score={r.score}
              hasData
              isLive
              isStale={false}
              highlight={isBest}
              badgeLabel={r.id === RETIRED_ID ? 'Suspended' : !online ? 'Simulated' : isBest ? 'Best' : 'Screened'}
              freshness={online ? 'Agent live' : 'Agent simulation'}
              signal={r.signalText}
              chainBadge={isCrosschain ? `CCTP→${CCTP_DOMAIN_BADGES[domain] ?? domain}` : 'LOCAL'}
              isCrosschain={isCrosschain}
              chainTitle={isCrosschain ? `Bridges via CCTP → ${CCTP_DOMAIN_NAMES[domain] ?? domain}` : 'Executes locally on Arc'}
              eligible={eligible}
              ineligibleTag={r.id === RETIRED_ID ? 'Retired' : 'Dynamic only'}
              description={r.description ?? r.shariahBasis}
              details={[r.inputs, r.signal, r.targetRule].filter((d): d is string => !!d)}
            />
          );
        })}
      </div>
    </section>
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
              ? `Live scores for ${effectiveTier === 'shariah-conservative' ? '3' : '5'} AI-scored screened strategies`
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
            ? <ShariahStrategyGrid tier={effectiveTier as 'shariah-conservative' | 'shariah-dynamic'} />
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
