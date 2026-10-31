/**
 * VaultPicker — Passive, Aggressive, Shariah Conservative, Shariah Dynamic.
 * Visible cards are gated by `vaultMode`.
 */
import { useState, useEffect } from 'react';
import { Shield, Zap, Moon, Star, TrendingUp, Lock } from 'lucide-react';
import { STRATEGY_NAMES, STRATEGY_COLORS } from '../contracts';
import {
  getSimShariahRows,
  getSimWinner,
  type SimShariahRow,
} from '../lib/shariahSim';
import type { VaultMode, TierSelection } from '../App';

// ─── API shapes ───────────────────────────────────────────────────

interface ProtocolSignals {
  compoundSupplyApy: number;
  curvePoolApy:      number;
  aaveLoopNetApy:    number;
  gmxGlpApy:         number;
  timestamp:         number;
}

interface EligibleStrategy {
  idx:      number;
  name:     string;
  score:    number;
  eligible: boolean;
  reason:   string;
}

interface TierRouting {
  tier:               'passive' | 'aggressive';
  eligibleStrategies: EligibleStrategy[];
  winnerIdx:          number | null;
  winnerScore:        number;
  winnerName:         string;
  willExecute:        boolean;
  minScore:           number;
  cooldownMinutes:    number;
  protocolSignals:    ProtocolSignals;
}

interface TierData {
  passive:          TierRouting;
  aggressive:       TierRouting;
  passiveVault:     string | null;
  aggressiveVault:  string | null;
}

// ─── Props ────────────────────────────────────────────────────────

interface VaultPickerProps {
  selectedTier: TierSelection;
  onSelect:     (tier: TierSelection) => void;
  vaultMode:    VaultMode;
}

// ─── Static labels ────────────────────────────────────────────────

const PROTOCOL_LABELS_PASSIVE = [
  { key: 'compoundSupplyApy', label: 'Compound V3 APY', format: (v: number) => `${v.toFixed(2)}%` },
  { key: 'curvePoolApy',      label: 'Curve 3pool APY', format: (v: number) => `${v.toFixed(2)}%` },
];
const PROTOCOL_LABELS_AGGRESSIVE = [
  { key: 'aaveLoopNetApy', label: 'Aave 2x Loop Net', format: (v: number) => `${v.toFixed(2)}%` },
  { key: 'gmxGlpApy',     label: 'GMX GLP Yield',     format: (v: number) => `${v.toFixed(2)}%` },
];
// Conservative: Gold Spread + Halal LP + Gold Allocation (mask 0b100110)
const CONSERVATIVE_PROTOCOLS = [
  { label: 'PAXG Gold Spread',      value: '2-6% APY' },
  { label: 'LP swap fees (Uni V3)',     value: '4-9% APY' },
  { label: 'XAUT Allocation (spot)', value: 'Gold price return' },
];
// Dynamic: all 5 active halal strategies (mask 0b101111)
const DYNAMIC_PROTOCOLS = [
  { label: 'ETH Cross-Chain Arb',   value: '3-8% APY' },
  { label: 'PAXG Gold Spread',      value: '2-6% APY' },
  { label: 'LP swap fees (Uni V3)',     value: '4-9% APY' },
  { label: 'Murabaha Trades',       value: 'Event-driven' },
  { label: 'XAUT Allocation (spot)', value: 'Gold price return' },
];

// ─── Tiny sub-components ──────────────────────────────────────────

function ProtocolSignalRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-center justify-between">
      <span className="text-xs" style={{ color: 'var(--subtle)' }}>{label}</span>
      <span className="tabular-nums text-xs font-semibold" style={{ color: 'var(--accent)' }}>{value}</span>
    </div>
  );
}

function StrategyEligibilityRow({ s, isWinner }: { s: EligibleStrategy; isWinner: boolean }) {
  return (
    <div className="flex items-center gap-2 py-0.5">
      <span className="w-1.5 h-1.5 rounded-full flex-shrink-0"
        style={{ background: s.eligible ? STRATEGY_COLORS[s.idx] : 'var(--border)' }} />
      <span className="text-xs flex-1 truncate"
        style={{ color: s.eligible ? 'var(--ink-2)' : 'var(--subtle)' }}>
        {STRATEGY_NAMES[s.idx]}
      </span>
      {isWinner && (
        <span className="text-xs px-1 py-0.5 rounded font-medium"
          style={{ background: 'rgba(141,216,159,0.12)', color: '#8dd89f', fontSize: '0.6rem' }}>
          WINNER
        </span>
      )}
      <span className="tabular-nums text-xs font-semibold flex-shrink-0"
        style={{ color: s.eligible ? STRATEGY_COLORS[s.idx] : 'var(--border)' }}>
        {s.score}
      </span>
    </div>
  );
}

// ─── Main component ───────────────────────────────────────────────

export function VaultPicker({ selectedTier, onSelect, vaultMode }: VaultPickerProps) {
  const [tierData, setTierData] = useState<TierData | null>(null);

  // Shariah simulated state — seeded immediately, replaced by live data when available
  const [shariahRows, setShariahRows] = useState<SimShariahRow[]>(() => getSimShariahRows());
  const [shariahLive, setShariahLive] = useState(false);

  useEffect(() => {
    const simId = setInterval(() => {
      if (!shariahLive) setShariahRows(getSimShariahRows());
    }, 5_000);

    async function fetchAll() {
      try {
        const [tr, sr] = await Promise.all([
          fetch('/api/tiers'),
          fetch('/api/shariah'),
        ]);
        if (tr.ok) setTierData(await tr.json() as TierData);
        if (sr.ok) {
          const d = await sr.json() as { strategies: SimShariahRow[]; online: boolean };
          if (d.strategies?.length) { setShariahRows(d.strategies); setShariahLive(d.online); }
        }
      } catch { /* keep simulated */ }
    }
    void fetchAll();
    const fetchId = setInterval(() => { void fetchAll(); }, 15_000);
    return () => { clearInterval(simId); clearInterval(fetchId); };
  }, [shariahLive]);

  // Conservative subset = Gold Spread (id:1) + Halal LP (id:2) + Gold Allocation (id:5). SR-001 removed RWA/Sukuk.
  const conservativeRows = shariahRows.filter(r => [1, 2, 5].includes(r.id));
  const dynamicRows      = shariahRows;

  const showConventional = vaultMode === 'conventional' || vaultMode === 'both';
  const showShariah      = vaultMode === 'shariah'      || vaultMode === 'both';

  // Grid: up to 4 cols when all shown, 2 for conventional-only, 2 for shariah-only
  const colCount = (showConventional ? 2 : 0) + (showShariah ? 2 : 0);
  const gridClass =
    colCount === 4 ? 'grid-cols-1 sm:grid-cols-2 lg:grid-cols-4' :
    colCount === 2 ? 'grid-cols-1 sm:grid-cols-2' :
                     'grid-cols-1 max-w-sm';

  return (
    <section>
      <div className="flex items-center gap-2 mb-3">
        <TrendingUp size={13} style={{ color: 'var(--subtle)' }} />
        <h2 className="text-xs uppercase tracking-wider"
          style={{ color: 'var(--subtle)', letterSpacing: '0.08em' }}>
          Choose Vault Tier
        </h2>
        <span
          className="text-xs px-2 py-0.5 rounded-full ml-auto font-medium"
          style={{
            background: vaultMode === 'shariah'      ? 'rgba(141,216,159,0.1)'
                      : vaultMode === 'conventional' ? 'rgba(172,198,233,0.1)'
                      :                                'rgba(201,184,245,0.1)',
            color:      vaultMode === 'shariah'      ? '#8dd89f'
                      : vaultMode === 'conventional' ? '#acc6e9'
                      :                                '#c9b8f5',
            fontSize: '0.6rem',
          }}
        >
          {vaultMode === 'both' ? 'ALL TIERS' : vaultMode.toUpperCase()}
        </span>
      </div>

      <div className={`grid gap-4 ${gridClass}`}>

        {/* ── Passive ── */}
        {showConventional && (
          <TierCard
            tierKey="passive"
            label="Passive"
            tagline="Stable yield, minimal risk"
            icon={Shield}
            iconColor="#acc6e9"
            isSelected={selectedTier === 'passive'}
            onSelect={() => onSelect('passive')}
            params={{ maxAlloc: '40%', cooldown: tierData?.passive ? `${tierData.passive.cooldownMinutes}m` : '2h', minScore: tierData?.passive ? String(tierData.passive.minScore) : '80', strategies: 'S1 + S4' }}
            protocols={PROTOCOL_LABELS_PASSIVE}
            signals={tierData?.passive?.protocolSignals ?? null}
            eligibleStrategies={tierData?.passive?.eligibleStrategies ?? null}
            winnerIdx={tierData?.passive?.winnerIdx ?? null}
            willExecute={tierData?.passive?.willExecute ?? false}
            winnerName={tierData?.passive?.winnerName ?? ''}
            winnerScore={tierData?.passive?.winnerScore ?? 0}
          />
        )}

        {/* ── Aggressive ── */}
        {showConventional && (
          <TierCard
            tierKey="aggressive"
            label="Aggressive"
            tagline="Maximum yield, managed risk"
            icon={Zap}
            iconColor="#f0b429"
            isSelected={selectedTier === 'aggressive'}
            onSelect={() => onSelect('aggressive')}
            params={{ maxAlloc: '80%', cooldown: tierData?.aggressive ? `${tierData.aggressive.cooldownMinutes}m` : '30m', minScore: tierData?.aggressive ? String(tierData.aggressive.minScore) : '60', strategies: 'All 4' }}
            protocols={PROTOCOL_LABELS_AGGRESSIVE}
            signals={tierData?.aggressive?.protocolSignals ?? null}
            eligibleStrategies={tierData?.aggressive?.eligibleStrategies ?? null}
            winnerIdx={tierData?.aggressive?.winnerIdx ?? null}
            willExecute={tierData?.aggressive?.willExecute ?? false}
            winnerName={tierData?.aggressive?.winnerName ?? ''}
            winnerScore={tierData?.aggressive?.winnerScore ?? 0}
          />
        )}

        {/* ── Shariah Conservative ── */}
        {showShariah && (
          <ShariahTierCard
            tierKey="shariah-conservative"
            label="Conservative"
            tagline="Low-vol screened strategies"
            icon={Moon}
            params={{ maxAlloc: '40%', cooldown: '2h', minScore: '80', strategies: '3 screened' }}
            protocols={CONSERVATIVE_PROTOCOLS}
            rows={conservativeRows}
            isSelected={selectedTier === 'shariah-conservative'}
            onSelect={() => onSelect('shariah-conservative')}
            live={shariahLive}
          />
        )}

        {/* ── Shariah Dynamic ── */}
        {showShariah && (
          <ShariahTierCard
            tierKey="shariah-dynamic"
            label="Dynamic"
            tagline="Full screened universe"
            icon={Star}
            params={{ maxAlloc: '70%', cooldown: '1h', minScore: '70', strategies: '5 screened' }}
            protocols={DYNAMIC_PROTOCOLS}
            rows={dynamicRows}
            isSelected={selectedTier === 'shariah-dynamic'}
            onSelect={() => onSelect('shariah-dynamic')}
            live={shariahLive}
          />
        )}
      </div>
    </section>
  );
}

// ─── TierCard (conventional) ──────────────────────────────────────

interface ProtocolLabelDef {
  key:    string;
  label:  string;
  format: (v: number) => string;
}

interface TierCardProps {
  tierKey:            string;
  label:              string;
  tagline:            string;
  icon:               typeof Shield;
  iconColor:          string;
  isSelected:         boolean;
  onSelect:           () => void;
  params:             { maxAlloc: string; cooldown: string; minScore: string; strategies: string };
  protocols:          ProtocolLabelDef[];
  signals:            ProtocolSignals | null;
  eligibleStrategies: EligibleStrategy[] | null;
  winnerIdx:          number | null;
  willExecute:        boolean;
  winnerName:         string;
  winnerScore:        number;
}

function TierCard({
  tierKey, label, tagline, icon: TierIcon, iconColor,
  isSelected, onSelect, params, protocols, signals,
  eligibleStrategies, winnerIdx, willExecute, winnerName, winnerScore,
}: TierCardProps) {
  const borderColor = `${iconColor}40`;
  const bgColor     = `${iconColor}0f`;

  return (
    <button
      key={tierKey}
      onClick={onSelect}
      className="text-left rounded-xl p-4 transition-all"
      style={{
        background: isSelected ? bgColor : 'var(--surface)',
        border: `1.5px solid ${isSelected ? borderColor : 'var(--border)'}`,
        outline: 'none',
      }}
    >
      <div className="flex items-start justify-between mb-3">
        <div className="flex items-center gap-2">
          <div className="w-7 h-7 rounded-lg flex items-center justify-center"
            style={{ background: `${iconColor}18` }}>
            <TierIcon size={14} style={{ color: iconColor }} />
          </div>
          <div>
            <p className="text-sm font-semibold" style={{ color: 'var(--ink-2)' }}>{label}</p>
            <p className="text-xs" style={{ color: 'var(--subtle)' }}>{tagline}</p>
          </div>
        </div>
        {isSelected && (
          <span className="text-xs px-2 py-0.5 rounded-full font-medium"
            style={{ background: `${iconColor}18`, color: iconColor }}>
            Selected
          </span>
        )}
      </div>

      <div className="grid grid-cols-2 gap-1.5 mb-3">
        {[
          { label: 'Max alloc',  value: params.maxAlloc },
          { label: 'Cooldown',   value: params.cooldown },
          { label: 'Min score',  value: params.minScore },
          { label: 'Strategies', value: params.strategies },
        ].map(item => (
          <div key={item.label} className="rounded-lg px-2 py-1.5"
            style={{ background: 'var(--surface-muted)' }}>
            <p className="text-xs" style={{ color: 'var(--subtle)', fontSize: '0.6rem' }}>
              {item.label.toUpperCase()}
            </p>
            <p className="tabular-nums text-xs font-semibold" style={{ color: 'var(--ink-2)' }}>
              {item.value}
            </p>
          </div>
        ))}
      </div>

      {signals && signals.timestamp > 0 && (
        <div className="space-y-1 mb-3 pt-2" style={{ borderTop: '1px solid var(--border)' }}>
          {protocols.map(p => (
            <ProtocolSignalRow
              key={p.key}
              label={p.label}
              value={p.format(signals[p.key as keyof ProtocolSignals])}
            />
          ))}
        </div>
      )}

      {eligibleStrategies && (
        <div className="pt-2 space-y-0.5" style={{ borderTop: '1px solid var(--border)' }}>
          {eligibleStrategies.map(s => (
            <StrategyEligibilityRow key={s.idx} s={s} isWinner={winnerIdx === s.idx} />
          ))}
          {willExecute ? (
            <p className="text-xs mt-1.5 font-medium" style={{ color: '#8dd89f' }}>
              Ready: {winnerName} ({winnerScore})
            </p>
          ) : (
            <p className="text-xs mt-1.5 flex items-center gap-1" style={{ color: 'var(--subtle)' }}>
              <Lock size={10} /> No eligible winner yet
            </p>
          )}
        </div>
      )}
    </button>
  );
}

// ─── ShariahTierCard ──────────────────────────────────────────────

interface ShariahTierCardProps {
  tierKey:    string;
  label:      string;
  tagline:    string;
  icon:       typeof Moon;
  params:     { maxAlloc: string; cooldown: string; minScore: string; strategies: string };
  protocols:  { label: string; value: string }[];
  rows:       SimShariahRow[];
  isSelected: boolean;
  onSelect:   () => void;
  live:       boolean;
}

function ShariahTierCard({
  tierKey, label, tagline, icon: TierIcon,
  params, protocols, rows, isSelected, onSelect, live,
}: ShariahTierCardProps) {
  const iconColor   = '#8dd89f';
  const borderColor = 'rgba(141,216,159,0.35)';
  const bgColor     = 'rgba(141,216,159,0.06)';
  const winner      = rows.length > 0 ? getSimWinner(rows) : null;

  return (
    <button
      key={tierKey}
      onClick={onSelect}
      className="text-left rounded-xl p-4 transition-all"
      style={{
        background: isSelected ? bgColor : 'var(--surface)',
        border: `1.5px solid ${isSelected ? borderColor : 'var(--border)'}`,
        outline: 'none',
      }}
    >
      {/* Header */}
      <div className="flex items-start justify-between mb-3">
        <div className="flex items-center gap-2">
          <div className="w-7 h-7 rounded-lg flex items-center justify-center"
            style={{ background: 'rgba(141,216,159,0.15)' }}>
            <TierIcon size={14} style={{ color: iconColor }} />
          </div>
          <div>
            <p className="text-sm font-semibold" style={{ color: 'var(--ink-2)' }}>{label}</p>
            <p className="text-xs" style={{ color: 'var(--subtle)' }}>{tagline}</p>
          </div>
        </div>
        <div className="flex flex-col items-end gap-1">
          {isSelected && (
            <span className="text-xs px-2 py-0.5 rounded-full font-medium"
              style={{ background: 'rgba(141,216,159,0.15)', color: iconColor }}>
              Selected
            </span>
          )}
          <span className="text-xs px-1.5 py-0.5 rounded font-medium"
            style={{ background: 'rgba(141,216,159,0.1)', color: iconColor, fontSize: '0.6rem' }}>
            SCREENED
          </span>
        </div>
      </div>

      {/* Params */}
      <div className="grid grid-cols-2 gap-1.5 mb-3">
        {[
          { label: 'Max alloc',  value: params.maxAlloc },
          { label: 'Cooldown',   value: params.cooldown },
          { label: 'Min score',  value: params.minScore },
          { label: 'Strategies', value: params.strategies },
        ].map(item => (
          <div key={item.label} className="rounded-lg px-2 py-1.5"
            style={{ background: 'var(--surface-muted)' }}>
            <p className="text-xs" style={{ color: 'var(--subtle)', fontSize: '0.6rem' }}>
              {item.label.toUpperCase()}
            </p>
            <p className="tabular-nums text-xs font-semibold" style={{ color: 'var(--ink-2)' }}>
              {item.value}
            </p>
          </div>
        ))}
      </div>

      {/* Protocol APY ranges */}
      <div className="space-y-1 mb-3 pt-2" style={{ borderTop: '1px solid var(--border)' }}>
        {protocols.map(p => (
          <ProtocolSignalRow key={p.label} label={p.label} value={p.value} />
        ))}
      </div>

      {/* Strategy score bars */}
      <div className="pt-2 space-y-0.5" style={{ borderTop: '1px solid var(--border)' }}>
        {rows.slice(0, 3).map(s => (
          <div key={s.id} className="flex items-center gap-2 py-0.5">
            <span className="w-1.5 h-1.5 rounded-full flex-shrink-0"
              style={{ background: s.score >= 75 ? iconColor : 'var(--border)' }} />
            <span className="text-xs flex-1 truncate"
              style={{ color: s.score >= 75 ? 'var(--ink-2)' : 'var(--subtle)' }}>
              {s.name}
            </span>
            {winner?.id === s.id && (
              <span className="text-xs px-1 py-0.5 rounded font-medium"
                style={{ background: 'rgba(141,216,159,0.12)', color: iconColor, fontSize: '0.6rem' }}>
                {live ? 'BEST' : 'SIM'}
              </span>
            )}
            <span className="tabular-nums text-xs font-semibold flex-shrink-0"
              style={{ color: s.score >= 75 ? iconColor : 'var(--border)' }}>
              {s.score}
            </span>
          </div>
        ))}
        {winner && (
          <p className="text-xs mt-1.5 flex items-center gap-1.5"
            style={{ color: winner.score >= 75 ? iconColor : 'var(--subtle)' }}>
            {winner.score >= 75
              ? <>{live ? 'Ready' : 'Simulated'}: {winner.name} ({winner.score})</>
              : <><Lock size={10} /> No eligible winner yet</>
            }
          </p>
        )}
      </div>
    </button>
  );
}
