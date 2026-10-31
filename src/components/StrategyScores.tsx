import React, { useState, useEffect } from 'react';
import { useReadContract } from 'wagmi';
import { ArrowLeftRight, Zap, Clock, Scale } from 'lucide-react';
import {
  AGGREGATOR_ADDRESS, AGGREGATOR_ABI,
  STRATEGY_NAMES, STRATEGY_DESCRIPTIONS, STRATEGY_COLORS,
  STRATEGY_TRIGGER_MODES, STRATEGY_DETAILS,
  CCTP_DOMAIN_NAMES, CCTP_DOMAIN_BADGES,
} from '../contracts';
import { ARC_CHAIN_ID } from '../chain';

// ─── strategy eligibility per risk tier ─────────────────────────
// Passive mask = 0b1001 (strategies 0 and 3)
// Aggressive mask = 0b1111 (all 4)
const PASSIVE_MASK = 0b1001;
const AGGRESSIVE_MASK = 0b1111;

function isTierEligible(strategyIndex: number, tier: 'passive' | 'aggressive'): boolean {
  const mask = tier === 'passive' ? PASSIVE_MASK : AGGRESSIVE_MASK;
  return ((mask >> strategyIndex) & 1) === 1;
}

// ─── icon map ───────────────────────────────────────────────────
const STRATEGY_ICON_NODES = [
  <ArrowLeftRight size={13} strokeWidth={2} />,
  <Zap size={13} strokeWidth={2} />,
  <Clock size={13} strokeWidth={2} />,
  <Scale size={13} strokeWidth={2} />,
];

function hexToRgb(hex: string): string {
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  return `${r}, ${g}, ${b}`;
}

function scoreLabel(v: number) {
  if (v >= 80) return { text: 'Very High', color: '#8dd89f',      bg: 'rgba(141,216,159,0.12)' };
  if (v >= 60) return { text: 'High',      color: '#acc6e9',      bg: 'rgba(172,198,233,0.12)' };
  if (v >= 40) return { text: 'Medium',    color: '#f0b429',      bg: 'rgba(240,180,41,0.12)' };
  return              { text: 'Low',       color: 'var(--subtle)', bg: 'rgba(255,255,255,0.05)' };
}

function scoreColor(v: number) {
  if (v >= 80) return '#8dd89f';
  if (v >= 60) return '#acc6e9';
  if (v >= 40) return '#f0b429';
  return 'var(--danger)';
}

// ─── agent score (from /api/status) ─────────────────────────────
interface AgentScore {
  score: number;
  signal: string;
  triggered: boolean;
  destinationDomain: number;
}

// ─── shared card view (used by conventional and Shariah tiers) ────
export interface StrategyCardViewProps {
  label: string;               // e.g. "Strategy 1"
  icon: React.ReactNode;
  trigger: string;             // e.g. "Every 30s"
  name: string;
  color: string;               // accent used when highlighted
  score: number;
  hasData: boolean;
  isLive: boolean;
  isStale: boolean;
  highlight: boolean;          // winner / best: tinted card
  badgeLabel: string;          // Simulated | Active | Winner | Expired | Screened | Best
  freshness: string;
  signal?: string;
  chainBadge: string;
  isCrosschain: boolean;
  chainTitle: string;
  eligible: boolean;
  ineligibleTag?: string;      // shown when not eligible for the tier
  description: string;
  details: string[];           // inputs, signal, rule
}

const BADGE_STYLES: Record<string, React.CSSProperties> = {
  Expired:   { background: 'rgba(255,255,255,0.06)', color: 'var(--subtle)', border: '1px solid var(--border)' },
  Suspended: { background: 'rgba(255,255,255,0.06)', color: 'var(--subtle)', border: '1px solid var(--border)' },
  Simulated: { background: 'rgba(240,180,41,0.10)', color: '#f0b429', border: '1px solid rgba(240,180,41,0.25)' },
  Winner:    { background: 'rgba(141,216,159,0.15)', color: '#8dd89f', border: '1px solid rgba(141,216,159,0.3)' },
  Best:      { background: 'rgba(141,216,159,0.15)', color: '#8dd89f', border: '1px solid rgba(141,216,159,0.3)' },
  Screened:  { background: 'rgba(141,216,159,0.08)', color: '#8dd89f', border: '1px solid rgba(141,216,159,0.2)' },
  Active:    { background: 'rgba(172,198,233,0.12)', color: 'var(--accent)', border: '1px solid rgba(172,198,233,0.2)' },
};

export function StrategyCardView(p: StrategyCardViewProps) {
  const lbl = scoreLabel(p.score);
  const bar = scoreColor(p.score);
  const lit = p.highlight && p.isLive;
  return (
    <div
      className="rounded-xl overflow-hidden flex flex-col"
      style={{
        background: lit ? `rgba(${hexToRgb(p.color)}, 0.06)` : 'var(--surface)',
        border: `1px solid ${lit ? `rgba(${hexToRgb(p.color)}, 0.28)` : 'var(--border)'}`,
        transition: 'border-color 0.3s, background 0.3s',
        opacity: p.eligible ? 1 : 0.38,
        filter: p.eligible ? 'none' : 'grayscale(0.6)',
      }}
    >
      {/* ── card header ── */}
      <div className="px-4 pt-4 pb-3 flex items-start justify-between gap-2" style={{ borderBottom: '1px solid var(--border)' }}>
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2 mb-1.5">
            <span className="flex items-center gap-1 text-xs font-medium" style={{ color: lit ? p.color : 'var(--muted)' }}>
              <span style={{ color: lit ? p.color : 'var(--subtle)' }}>{p.icon}</span>
              {p.label}
            </span>
            <span className="text-xs" style={{ color: 'var(--subtle)' }}>{p.trigger}</span>
          </div>
          <p className="text-sm font-semibold leading-snug" style={{ color: 'var(--ink-2)' }}>{p.name}</p>
        </div>

        <div className="flex flex-col items-end gap-1 flex-shrink-0 mt-0.5">
          {!p.eligible && p.ineligibleTag && (
            <span
              className="text-xs px-2 py-0.5 rounded font-medium"
              style={{ background: 'rgba(255,255,255,0.05)', color: 'var(--subtle)', border: '1px solid var(--border)', fontSize: '0.6rem' }}
            >
              {p.ineligibleTag}
            </span>
          )}
          <span className="text-xs px-2 py-0.5 rounded font-medium" style={BADGE_STYLES[p.badgeLabel] ?? BADGE_STYLES.Active}>
            {p.badgeLabel}
          </span>
          <span
            className="mono text-xs px-1.5 py-0.5 rounded"
            title={p.chainTitle}
            style={{
              background: p.isCrosschain ? 'rgba(240,180,41,0.1)' : 'rgba(172,198,233,0.08)',
              color: p.isCrosschain ? '#f0b429' : 'var(--subtle)',
              fontSize: '0.6rem',
              letterSpacing: '0.04em',
            }}
          >
            {p.chainBadge}
          </span>
        </div>
      </div>

      {/* ── live score dial ── */}
      <div className="px-4 py-3">
        <p className="text-xs uppercase mb-2" style={{ color: 'var(--subtle)', letterSpacing: '0.08em', fontSize: '0.65rem' }}>
          Live Score
        </p>
        <div
          className="rounded-xl px-4 py-3 flex items-end justify-between gap-4"
          style={{ background: 'var(--surface-muted)', border: '1px solid var(--border)' }}
        >
          <div className="relative flex items-center justify-center w-14 h-14 flex-shrink-0">
            <svg width="56" height="56" viewBox="0 0 56 56" className="absolute inset-0">
              <circle cx="28" cy="28" r="22" fill="none" stroke="var(--border)" strokeWidth="3" />
              <circle
                cx="28" cy="28" r="22"
                fill="none"
                stroke={p.isLive ? bar : 'var(--border)'}
                strokeWidth="3"
                strokeLinecap="round"
                strokeDasharray={`${2 * Math.PI * 22}`}
                strokeDashoffset={`${2 * Math.PI * 22 * (1 - (p.hasData ? p.score / 100 : 0))}`}
                transform="rotate(-90 28 28)"
                style={{ transition: 'stroke-dashoffset 0.8s ease' }}
              />
            </svg>
            <span className="tabular-nums text-sm font-bold" style={{ color: p.isLive ? bar : 'var(--subtle)', zIndex: 1 }}>
              {p.hasData ? p.score : '—'}
            </span>
          </div>

          <div className="flex-1 min-w-0">
            <div className="flex items-center justify-between mb-1.5">
              {p.hasData ? (
                <span className="text-xs px-1.5 py-0.5 rounded font-medium" style={{ background: lbl.bg, color: lbl.color }}>
                  {lbl.text}
                </span>
              ) : (
                <span className="text-xs" style={{ color: 'var(--subtle)' }}>No data</span>
              )}
              <span className="text-xs tabular-nums" style={{ color: 'var(--subtle)' }}>{p.freshness}</span>
            </div>
            <div className="h-1 rounded-full overflow-hidden" style={{ background: 'var(--border)' }}>
              <div
                className="h-full rounded-full"
                style={{
                  width: p.hasData ? `${p.score}%` : '0%',
                  background: p.isStale ? 'var(--subtle)' : bar,
                  opacity: p.isStale ? 0.4 : 1,
                  transition: 'width 0.8s ease',
                }}
              />
            </div>
            {p.signal && (
              <p className="text-xs mt-1.5 truncate" style={{ color: 'var(--subtle)' }} title={p.signal}>
                {p.signal}
              </p>
            )}
          </div>
        </div>
      </div>

      {/* ── description ── */}
      <div className="px-4 pb-3">
        <p className="text-xs leading-relaxed" style={{ color: 'var(--muted)' }}>{p.description}</p>
      </div>

      {/* ── inputs / signal / rule rows ── */}
      <div className="px-4 pb-4 space-y-1.5">
        {p.details.map((value, ri) => (
          <div key={ri} className="rounded-lg px-3 py-2" style={{ background: 'var(--surface-muted)', border: '1px solid var(--border)' }}>
            <span className="text-xs" style={{ color: 'var(--muted)' }}>{value}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

// ─── conventional card ───────────────────────────────────────────
interface StrategyCardProps {
  index: number;
  value: number;
  timestamp: number;           // 0 means no on-chain data yet
  agentScore: AgentScore | null;
  nowSeconds: number;
  isWinner: boolean;
  destinationDomain: number;
  tierEligible: boolean;
  tier: 'passive' | 'aggressive';
}

function StrategyCard({
  index, value, timestamp, agentScore, nowSeconds,
  isWinner, destinationDomain, tierEligible, tier,
}: StrategyCardProps) {
  // Use on-chain timestamp if available, otherwise trust agent as "live"
  const hasOnChain = timestamp > 0;
  const age        = hasOnChain ? nowSeconds - timestamp : 0;
  const isStale    = hasOnChain && age > 300;

  // Score source: on-chain > agent simulation
  const displayValue    = hasOnChain ? value : (agentScore?.score ?? 0);
  const hasData         = hasOnChain || agentScore !== null;
  const isLive          = hasData && !isStale;
  const effectiveDomain = hasOnChain ? destinationDomain : (agentScore?.destinationDomain ?? 0);

  const badgeLabel =
    !hasData    ? 'Expired' :
    isStale     ? 'Expired' :
    !hasOnChain ? 'Simulated' :
    isWinner    ? 'Winner' :
                  'Active';

  const isCrosschain = effectiveDomain !== 0;
  const details = STRATEGY_DETAILS[index];

  return (
    <StrategyCardView
      label={`Strategy ${index + 1}`}
      icon={STRATEGY_ICON_NODES[index]}
      trigger={STRATEGY_TRIGGER_MODES[index]}
      name={STRATEGY_NAMES[index]}
      color={STRATEGY_COLORS[index]}
      score={displayValue}
      hasData={hasData}
      isLive={isLive}
      isStale={isStale}
      highlight={isWinner}
      badgeLabel={badgeLabel}
      freshness={hasOnChain
        ? (isStale ? `Stale — ${age}s ago` : `Updated ${age}s ago`)
        : (agentScore ? 'Agent simulation' : 'Awaiting data')}
      signal={!hasOnChain ? agentScore?.signal : undefined}
      chainBadge={isCrosschain ? `CCTP→${CCTP_DOMAIN_BADGES[effectiveDomain] ?? effectiveDomain}` : 'LOCAL'}
      isCrosschain={isCrosschain}
      chainTitle={isCrosschain ? `Bridges via CCTP → ${CCTP_DOMAIN_NAMES[effectiveDomain]}` : 'Executes locally on Arc'}
      eligible={tierEligible}
      ineligibleTag={tier === 'passive' ? 'Aggressive only' : 'Passive only'}
      description={STRATEGY_DESCRIPTIONS[index]}
      details={[details.inputs, details.signal, details.rule]}
    />
  );
}


interface StrategyScoresProps {
  tier: 'passive' | 'aggressive';
}

export function StrategyScores({ tier }: StrategyScoresProps) {
  const isDeployed = AGGREGATOR_ADDRESS.length > 2;
  const [nowSeconds, setNowSeconds] = useState(() => Math.floor(Date.now() / 1000));
  const [agentScores, setAgentScores] = useState<AgentScore[] | null>(null);

  useEffect(() => {
    const id = setInterval(() => setNowSeconds(Math.floor(Date.now() / 1000)), 5_000);
    return () => clearInterval(id);
  }, []);

  useEffect(() => {
    let mounted = true;

    function poll() {
      fetch('/api/status')
        .then(r => (r.ok ? r.json() : null))
        .then((data: { scores: Array<{ score: number; signal: string; triggered: boolean; destinationDomain: number }> } | null) => {
          if (!mounted) return;
          if (data && Array.isArray(data.scores) && data.scores.length === 4) {
            setAgentScores(data.scores.map(s => ({
              score: s.score,
              signal: s.signal ?? '',
              triggered: s.triggered ?? false,
              destinationDomain: s.destinationDomain ?? 0,
            })));
          }
        })
        .catch(() => { /* agent not running */ });
    }

    poll();
    const id = setInterval(poll, 15_000);
    return () => {
      mounted = false;
      clearInterval(id);
    };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // On-chain data (only when deployed)
  const { data: scores } = useReadContract({
    address: AGGREGATOR_ADDRESS,
    abi: AGGREGATOR_ABI,
    functionName: 'getAllScores',
    chainId: ARC_CHAIN_ID,
    query: { enabled: isDeployed, refetchInterval: 10_000 },
  });

  const { data: winner } = useReadContract({
    address: AGGREGATOR_ADDRESS,
    abi: AGGREGATOR_ABI,
    functionName: 'getWinningStrategy',
    chainId: ARC_CHAIN_ID,
    query: { enabled: isDeployed, refetchInterval: 10_000 },
  });

  const values             = scores?.[0] ?? [0, 0, 0, 0];
  const timestamps         = scores?.[1] ?? [0, 0, 0, 0];
  const destinationDomains = scores?.[2] ?? [0, 0, 0, 0];
  const winnerIdx          = winner ? Number(winner[0]) : null;

  return (
    <section>
      <div className="flex items-center justify-between mb-4">
        <h2 className="text-xs uppercase tracking-wider" style={{ color: 'var(--subtle)', letterSpacing: '0.08em' }}>
          Strategy Scores
        </h2>
        <div className="flex items-center gap-3">
          {winnerIdx !== null && isDeployed && (
            <span className="text-xs" style={{ color: 'var(--muted)' }}>
              Winning: <span style={{ color: STRATEGY_COLORS[winnerIdx] }}>{STRATEGY_NAMES[winnerIdx]}</span>
            </span>
          )}
          {!isDeployed && agentScores && (
            <span
              className="text-xs px-2 py-0.5 rounded"
              style={{ background: 'rgba(240,180,41,0.1)', color: '#f0b429', border: '1px solid rgba(240,180,41,0.2)' }}
            >
              Agent simulation
            </span>
          )}
        </div>
      </div>

      <div className="grid gap-4 grid-cols-1 sm:grid-cols-2">
        {STRATEGY_NAMES.map((_, i) => (
          <StrategyCard
            key={i}
            index={i}
            value={isDeployed ? Number(values[i]) : 0}
            timestamp={isDeployed ? Number(timestamps[i]) : 0}
            agentScore={agentScores?.[i] ?? null}
            nowSeconds={nowSeconds}
            isWinner={isDeployed && winnerIdx !== null && winnerIdx === i}
            destinationDomain={isDeployed ? Number(destinationDomains[i]) : 0}
            tierEligible={isTierEligible(i, tier)}
            tier={tier}
          />
        ))}
      </div>

      {!isDeployed && !agentScores && (
        <p className="text-xs mt-3 text-center" style={{ color: 'var(--subtle)' }}>
          Deploy contracts and configure addresses to see live scores
        </p>
      )}
    </section>
  );
}
