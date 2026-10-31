import { useState, useEffect } from 'react';
import { Save, RefreshCw, Info, Shield, Zap, Moon, Globe, ExternalLink, RotateCcw, CheckCircle, AlertCircle } from 'lucide-react';
import { MigrationPanel } from '../components/MigrationPanel';
import type { VaultMode, TierSelection } from '../App';

interface SettingsPageProps {
  selectedTier:       TierSelection;
  onSelectTier:       (t: TierSelection) => void;
  vaultMode:          VaultMode;
  onVaultModeChange:  (m: VaultMode) => void;
}

const ENV_VARS = [
  { key: 'VITE_AGGREGATOR_ADDRESS',          label: 'Score Aggregator',        placeholder: '0x…', note: 'ScoreAggregator contract' },
  { key: 'VITE_PASSIVE_VAULT_ADDRESS',        label: 'Passive Vault',           placeholder: '0x…', note: 'DeFiVault (Passive)' },
  { key: 'VITE_AGGRESSIVE_VAULT_ADDRESS',     label: 'Aggressive Vault',        placeholder: '0x…', note: 'DeFiVault (Aggressive)' },
  { key: 'VITE_PASSIVE_EXECUTOR_ADDRESS',     label: 'Passive Executor',        placeholder: '0x…', note: 'RiskTieredExecutor (Passive)' },
  { key: 'VITE_AGGRESSIVE_EXECUTOR_ADDRESS',  label: 'Aggressive Executor',     placeholder: '0x…', note: 'RiskTieredExecutor (Aggressive)' },
  { key: 'VITE_POSITION_TRACKER_ADDRESS',     label: 'Position Tracker',        placeholder: '0x…', note: 'PositionTracker contract' },
];

interface AgentConfig {
  strategy1IntervalMs:       number;
  strategy2IntervalMs:       number;
  strategy3IntervalMs:       number;
  strategy4IntervalMs:       number;
  cctpPollIntervalMs:        number;
  protocolSignalsIntervalMs: number;
  mainLoopIntervalMs:        number;
  minScorePassive:           number;
  minScoreAggressive:        number;
}

type ConfigKey = keyof AgentConfig;

interface ConfigField {
  key: ConfigKey;
  label: string;
  note: string;
  unit: 's' | 'pts';
  min: number;
  max: number;
  /** convert stored ms value to display value */
  toDisplay: (v: number) => number;
  /** convert display value back to ms for storage */
  fromDisplay: (v: number) => number;
  readonly?: boolean;
}

const CONFIG_FIELDS: ConfigField[] = [
  { key: 'strategy1IntervalMs',       label: 'Strategy 1 interval',     note: 'Cross-Chain Stablecoin Spread',  unit: 's', min: 5,  max: 300, toDisplay: v => v / 1000, fromDisplay: v => v * 1000 },
  { key: 'strategy2IntervalMs',       label: 'Strategy 2 interval',     note: 'Perpetual Funding Rate Arb',     unit: 's', min: 5,  max: 300, toDisplay: v => v / 1000, fromDisplay: v => v * 1000 },
  { key: 'strategy3IntervalMs',       label: 'Strategy 3 poll',         note: 'Bridge Flow (Stargate events)',  unit: 's', min: 5,  max: 300, toDisplay: v => v / 1000, fromDisplay: v => v * 1000, readonly: true },
  { key: 'strategy4IntervalMs',       label: 'Strategy 4 interval',     note: 'Liquidation + RWA Yield',        unit: 's', min: 5,  max: 300, toDisplay: v => v / 1000, fromDisplay: v => v * 1000 },
  { key: 'cctpPollIntervalMs',        label: 'CCTP attestation poll',   note: 'Circle Iris API',                unit: 's', min: 10, max: 300, toDisplay: v => v / 1000, fromDisplay: v => v * 1000 },
  { key: 'protocolSignalsIntervalMs', label: 'Protocol signals',        note: 'Compound/Aave APY refresh',      unit: 's', min: 10, max: 300, toDisplay: v => v / 1000, fromDisplay: v => v * 1000 },
  { key: 'minScorePassive',           label: 'Passive min score',       note: 'Minimum score to execute (0-100)', unit: 'pts', min: 0, max: 100, toDisplay: v => v, fromDisplay: v => v },
  { key: 'minScoreAggressive',        label: 'Aggressive min score',    note: 'Minimum score to execute (0-100)', unit: 'pts', min: 0, max: 100, toDisplay: v => v, fromDisplay: v => v },
];

const DEFAULT_DISPLAY: Record<ConfigKey, number> = {
  strategy1IntervalMs: 30, strategy2IntervalMs: 30, strategy3IntervalMs: 30,
  strategy4IntervalMs: 45, cctpPollIntervalMs: 60, protocolSignalsIntervalMs: 60,
  mainLoopIntervalMs: 30, minScorePassive: 80, minScoreAggressive: 60,
};

type SaveState = 'idle' | 'saving' | 'saved' | 'error' | 'resetting';

const MODE_OPTIONS: { id: VaultMode; label: string; sub: string; icon: typeof Shield; color: string }[] = [
  { id: 'conventional', label: 'Conventional', sub: 'Passive + Aggressive vaults', icon: Shield, color: '#acc6e9' },
  { id: 'shariah',      label: 'Shariah',       sub: 'Shariah-screened vault only',  icon: Moon,   color: '#8dd89f' },
  { id: 'both',         label: 'Both',          sub: 'All three vault tiers',       icon: Globe,  color: '#c9b8f5' },
];

export function SettingsPage({ selectedTier, onSelectTier, vaultMode, onVaultModeChange }: SettingsPageProps) {
  // Draft values (in display units: seconds or points)
  const [draft, setDraft] = useState<Record<ConfigKey, number>>({ ...DEFAULT_DISPLAY });
  const [liveConfig, setLiveConfig] = useState<AgentConfig | null>(null);
  const [saveState, setSaveState] = useState<SaveState>('idle');
  const [errorMsg, setErrorMsg] = useState('');
  const [agentOnline, setAgentOnline] = useState(false);

  // Load live config from agent on mount
  useEffect(() => {
    fetch('/api/config')
      .then(r => (r.ok ? r.json() : null))
      .then((data: { config: AgentConfig } | null) => {
        if (data?.config) {
          setLiveConfig(data.config);
          setAgentOnline(true);
          const newDraft: Record<string, number> = {};
          for (const f of CONFIG_FIELDS) {
            newDraft[f.key] = f.toDisplay(data.config[f.key]);
          }
          setDraft(newDraft);
        }
      })
      .catch(() => setAgentOnline(false));
  }, []);

  function handleChange(key: ConfigKey, raw: string) {
    const val = parseFloat(raw);
    if (!isNaN(val)) setDraft(d => ({ ...d, [key]: val }));
  }

  function isDirty(field: ConfigField) {
    if (!liveConfig) return false;
    return field.toDisplay(liveConfig[field.key]) !== draft[field.key];
  }
  const anyDirty = CONFIG_FIELDS.some(f => isDirty(f));

  async function handleSave() {
    setSaveState('saving');
    setErrorMsg('');
    try {
      const body: Partial<AgentConfig> = {};
      for (const f of CONFIG_FIELDS) {
        (body as Record<string, number>)[f.key] = f.fromDisplay(draft[f.key]);
      }
      const res = await fetch('/api/config', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      const data = await res.json() as { ok: boolean; config?: AgentConfig; errors?: string[] };
      if (!res.ok || !data.ok) {
        setSaveState('error');
        setErrorMsg(data.errors?.join(', ') ?? 'Unknown error');
        return;
      }
      if (data.config) setLiveConfig(data.config);
      setSaveState('saved');
      setTimeout(() => setSaveState('idle'), 2500);
    } catch {
      setSaveState('error');
      setErrorMsg('Agent not reachable — is it running?');
      setTimeout(() => setSaveState('idle'), 3000);
    }
  }

  async function handleReset() {
    setSaveState('resetting');
    try {
      const res = await fetch('/api/config/reset', { method: 'POST' });
      const data = await res.json() as { ok: boolean; config?: AgentConfig };
      if (data.config) {
        setLiveConfig(data.config);
        const newDraft: Record<string, number> = {};
        for (const f of CONFIG_FIELDS) newDraft[f.key] = f.toDisplay(data.config[f.key]);
        setDraft(newDraft);
      }
      setSaveState('saved');
      setTimeout(() => setSaveState('idle'), 2000);
    } catch {
      setSaveState('error');
      setErrorMsg('Reset failed — agent not reachable');
      setTimeout(() => setSaveState('idle'), 3000);
    }
  }

  const isBusy = saveState === 'saving' || saveState === 'resetting';

  return (
    <div className="space-y-6 max-w-2xl">
      <div>
        <h1 className="display text-2xl font-bold" style={{ color: 'var(--ink)', letterSpacing: '-0.03em' }}>Settings</h1>
        <p className="text-sm mt-1" style={{ color: 'var(--subtle)' }}>Contract addresses, risk tier, and agent configuration</p>
      </div>

      {/* Community / vault mode */}
      <section>
        <p className="text-xs uppercase mb-3" style={{ color: 'var(--subtle)', letterSpacing: '0.08em' }}>Community</p>
        <div className="rounded-xl overflow-hidden" style={{ border: '1px solid var(--border)' }}>
          {MODE_OPTIONS.map((opt, i) => {
            const active = vaultMode === opt.id;
            return (
              <button
                key={opt.id}
                onClick={() => onVaultModeChange(opt.id)}
                className="w-full flex items-center gap-4 px-5 py-4 text-left transition-all"
                style={{
                  background: active ? `${opt.color}0d` : 'var(--surface)',
                  borderBottom: i < MODE_OPTIONS.length - 1 ? '1px solid var(--border)' : 'none',
                }}
              >
                <div className="w-8 h-8 rounded-lg flex items-center justify-center flex-shrink-0"
                  style={{ background: `${opt.color}15`, color: opt.color }}>
                  <opt.icon size={15} strokeWidth={1.8} />
                </div>
                <div className="flex-1">
                  <p className="text-sm font-medium" style={{ color: active ? opt.color : 'var(--ink-2)' }}>{opt.label}</p>
                  <p className="text-xs mt-0.5" style={{ color: 'var(--subtle)' }}>{opt.sub}</p>
                </div>
                <div
                  className="w-4 h-4 rounded-full flex-shrink-0 flex items-center justify-center"
                  style={{ border: `2px solid ${active ? opt.color : 'var(--border)'}`, background: active ? opt.color : 'transparent' }}
                >
                  {active && <span className="w-1.5 h-1.5 rounded-full" style={{ background: '#0a1628' }} />}
                </div>
              </button>
            );
          })}
        </div>
        <p className="text-xs mt-2" style={{ color: 'var(--subtle)' }}>
          Controls which vault tiers are shown in the picker. Switching to Shariah hides conventional strategies.
        </p>
      </section>

      {/* Default vault tier */}
      <section>
        <p className="text-xs uppercase mb-3" style={{ color: 'var(--subtle)', letterSpacing: '0.08em' }}>Default Vault Tier</p>
        <div className="rounded-xl overflow-hidden" style={{ border: '1px solid var(--border)' }}>
          {([
            { id: 'passive'    as const, label: 'Passive',    sub: 'Min score 80, cooldown 2h, 40% max alloc',      color: '#acc6e9', icon: Shield, visible: vaultMode !== 'shariah' },
            { id: 'aggressive' as const, label: 'Aggressive', sub: 'Min score 60, cooldown 30min, 80% max alloc',   color: '#f0b429', icon: Zap,    visible: vaultMode !== 'shariah' },
            { id: 'shariah-conservative' as const, label: 'Conservative Shariah', sub: 'Min score 80, cooldown 2h, S2-H S3-H S5-H only',  color: '#8dd89f', icon: Moon, visible: vaultMode !== 'conventional' },
            { id: 'shariah-dynamic'      as const, label: 'Dynamic Shariah',      sub: 'Min score 70, cooldown 1h, all 5 screened strategies', color: '#c9b8f5', icon: Moon, visible: vaultMode !== 'conventional' },
          ] as const).filter(t => t.visible).map((t, i, arr) => {
            const active = selectedTier === t.id;
            return (
              <button
                key={t.id}
                onClick={() => onSelectTier(t.id)}
                className="w-full flex items-center gap-4 px-5 py-4 text-left transition-all"
                style={{
                  background: active ? `${t.color}0d` : 'var(--surface)',
                  borderBottom: i < arr.length - 1 ? '1px solid var(--border)' : 'none',
                }}
              >
                <div className="w-8 h-8 rounded-lg flex items-center justify-center flex-shrink-0"
                  style={{ background: `${t.color}15`, color: t.color }}>
                  <t.icon size={15} strokeWidth={1.8} />
                </div>
                <div className="flex-1">
                  <p className="text-sm font-medium" style={{ color: active ? t.color : 'var(--ink-2)' }}>{t.label} Vault</p>
                  <p className="text-xs mt-0.5" style={{ color: 'var(--subtle)' }}>{t.sub}</p>
                </div>
                <div
                  className="w-4 h-4 rounded-full flex-shrink-0 flex items-center justify-center"
                  style={{ border: `2px solid ${active ? t.color : 'var(--border)'}`, background: active ? t.color : 'transparent' }}
                >
                  {active && <span className="w-1.5 h-1.5 rounded-full" style={{ background: '#0a1628' }} />}
                </div>
              </button>
            );
          })}
        </div>
      </section>

      {/* Contract addresses */}
      <section>
        <div className="flex items-center gap-2 mb-3">
          <p className="text-xs uppercase" style={{ color: 'var(--subtle)', letterSpacing: '0.08em' }}>Contract Addresses</p>
          <div className="flex items-center gap-1 rounded px-1.5 py-0.5" style={{ background: 'rgba(172,198,233,0.08)', border: '1px solid rgba(172,198,233,0.15)' }}>
            <Info size={10} style={{ color: 'var(--accent)' }} />
            <span className="text-xs" style={{ color: 'var(--accent)', fontSize: '0.6rem' }}>Configure in .env</span>
          </div>
        </div>
        <div className="rounded-xl overflow-hidden" style={{ border: '1px solid var(--border)' }}>
          {ENV_VARS.map((v, i) => {
            const current = import.meta.env[v.key] as string | undefined;
            const isSet = !!(current && current.length > 2);
            return (
              <div
                key={v.key}
                className="flex items-center gap-4 px-4 py-3.5"
                style={{
                  background: 'var(--surface)',
                  borderBottom: i < ENV_VARS.length - 1 ? '1px solid rgba(255,255,255,0.05)' : 'none',
                }}
              >
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2">
                    <p className="text-xs font-medium" style={{ color: 'var(--ink-2)' }}>{v.label}</p>
                    <span className="mono text-xs" style={{ color: 'var(--subtle)', fontSize: '0.6rem' }}>{v.key}</span>
                  </div>
                  <p className="mono text-xs mt-0.5 truncate" style={{ color: isSet ? 'var(--muted)' : 'var(--subtle)' }}>
                    {isSet ? current : v.placeholder}
                  </p>
                </div>
                <div className="flex items-center gap-2 flex-shrink-0">
                  {isSet && (
                    <a
                      href={`https://explorer.arc.io/address/${current}`}
                      target="_blank"
                      rel="noreferrer"
                      className="flex items-center gap-1 text-xs"
                      style={{ color: 'var(--accent)' }}
                    >
                      <ExternalLink size={11} />
                    </a>
                  )}
                  <span
                    className="text-xs px-1.5 py-0.5 rounded"
                    style={{
                      background: isSet ? 'rgba(141,216,159,0.1)' : 'rgba(255,255,255,0.05)',
                      color: isSet ? '#8dd89f' : 'var(--subtle)',
                      fontSize: '0.6rem',
                    }}
                  >
                    {isSet ? 'Set' : 'Not set'}
                  </span>
                </div>
              </div>
            );
          })}
        </div>
        <p className="text-xs mt-2.5" style={{ color: 'var(--subtle)' }}>
          Edit <span className="mono" style={{ color: 'var(--muted)' }}>.env</span> and restart the dev server to apply contract addresses.
        </p>
      </section>

      {/* Agent config — editable */}
      <section>
        <div className="flex items-center justify-between mb-3">
          <div className="flex items-center gap-2">
            <p className="text-xs uppercase" style={{ color: 'var(--subtle)', letterSpacing: '0.08em' }}>Agent Configuration</p>
            {/* online/offline pill */}
            <div
              className="flex items-center gap-1 rounded-full px-2 py-0.5"
              style={{
                background: agentOnline ? 'rgba(141,216,159,0.1)' : 'rgba(232,109,122,0.1)',
                border: `1px solid ${agentOnline ? 'rgba(141,216,159,0.2)' : 'rgba(232,109,122,0.2)'}`,
              }}
            >
              <span
                className="w-1.5 h-1.5 rounded-full"
                style={{ background: agentOnline ? '#8dd89f' : '#e86d7a' }}
              />
              <span className="text-xs" style={{ color: agentOnline ? '#8dd89f' : '#e86d7a', fontSize: '0.65rem' }}>
                {agentOnline ? 'Agent online' : 'Agent offline'}
              </span>
            </div>
          </div>
          {anyDirty && (
            <span className="text-xs" style={{ color: '#f0b429' }}>Unsaved changes</span>
          )}
        </div>

        <div className="rounded-xl overflow-hidden" style={{ border: '1px solid var(--border)' }}>
          {CONFIG_FIELDS.map((field, i) => {
            const dirty = isDirty(field);
            const isScore = field.unit === 'pts';
            return (
              <div
                key={field.key}
                className="flex items-center gap-4 px-4 py-3"
                style={{
                  background: dirty ? 'rgba(240,180,41,0.04)' : 'var(--surface)',
                  borderBottom: i < CONFIG_FIELDS.length - 1 ? '1px solid rgba(255,255,255,0.05)' : 'none',
                  borderLeft: dirty ? '2px solid rgba(240,180,41,0.4)' : '2px solid transparent',
                }}
              >
                <div className="flex-1 min-w-0">
                  <p className="text-xs font-medium" style={{ color: dirty ? '#f0b429' : 'var(--ink-2)' }}>{field.label}</p>
                  <p className="text-xs mt-0.5" style={{ color: 'var(--subtle)' }}>{field.note}</p>
                </div>

                {field.readonly ? (
                  /* Event-driven strategy — not an interval, just a label */
                  <div className="flex items-center gap-2">
                    <span
                      className="mono text-xs px-2 py-1 rounded"
                      style={{ background: 'var(--surface-muted)', color: 'var(--subtle)', border: '1px solid var(--border)' }}
                    >
                      Event
                    </span>
                    <Info size={12} style={{ color: 'var(--subtle)' }} />
                  </div>
                ) : (
                  /* Editable numeric input */
                  <div className="flex items-center gap-1.5 flex-shrink-0">
                    <div
                      className="flex items-center rounded-lg overflow-hidden"
                      style={{ border: `1px solid ${dirty ? 'rgba(240,180,41,0.4)' : 'var(--border)'}`, background: 'var(--surface-muted)' }}
                    >
                      <input
                        type="number"
                        min={field.min}
                        max={field.max}
                        step={isScore ? 1 : 5}
                        value={draft[field.key]}
                        disabled={!agentOnline || isBusy}
                        onChange={e => handleChange(field.key, e.target.value)}
                        className="mono text-xs w-14 px-2 py-1.5 bg-transparent outline-none tabular-nums text-right"
                        style={{
                          color: dirty ? '#f0b429' : 'var(--ink-2)',
                          WebkitAppearance: 'textfield',
                        }}
                      />
                      <span
                        className="mono text-xs pr-2"
                        style={{ color: 'var(--subtle)', fontSize: '0.6rem' }}
                      >
                        {field.unit}
                      </span>
                    </div>
                    {/* Show default hint when dirty */}
                    {dirty && (
                      <span className="text-xs tabular-nums" style={{ color: 'var(--subtle)', fontSize: '0.6rem' }}>
                        was {DEFAULT_DISPLAY[field.key]}{field.unit}
                      </span>
                    )}
                  </div>
                )}
              </div>
            );
          })}
        </div>

        {/* Error message */}
        {saveState === 'error' && (
          <div
            className="flex items-center gap-2 mt-2 px-3 py-2 rounded-lg"
            style={{ background: 'rgba(232,109,122,0.08)', border: '1px solid rgba(232,109,122,0.2)' }}
          >
            <AlertCircle size={13} style={{ color: '#e86d7a', flexShrink: 0 }} />
            <p className="text-xs" style={{ color: '#e86d7a' }}>{errorMsg}</p>
          </div>
        )}

        <p className="text-xs mt-2" style={{ color: 'var(--subtle)' }}>
          Changes apply on the agent&apos;s next cycle — no restart needed. Min 5s, max 300s. Strategy 3 is event-driven.
        </p>
      </section>

      {/* V2 Migration — shown only in Shariah or Both modes */}
      {(vaultMode === 'shariah' || vaultMode === 'both') && (
        <section>
          <p className="text-xs uppercase mb-3" style={{ color: 'var(--subtle)', letterSpacing: '0.08em' }}>Shariah Vault V2 Migration</p>
          <MigrationPanel
            v1ShareBalance="0.00"
            v2Address={import.meta.env.VITE_SHARIAH_VAULT_V2_ADDRESS as string | undefined}
          />
        </section>
      )}

      {/* Action row */}
      <div className="flex items-center gap-3 pt-1">
        <button
          onClick={() => { void handleSave(); }}
          disabled={isBusy || !agentOnline || !anyDirty}
          className="flex items-center gap-2 px-5 py-2.5 rounded-xl text-sm font-semibold transition-opacity"
          style={{
            background: 'var(--accent)',
            color: '#0a1628',
            opacity: (isBusy || !agentOnline || !anyDirty) ? 0.4 : 1,
            cursor: (isBusy || !agentOnline || !anyDirty) ? 'not-allowed' : 'pointer',
          }}
        >
          {saveState === 'saving' ? (
            <><RefreshCw size={14} className="animate-spin" /> Applying…</>
          ) : saveState === 'saved' ? (
            <><CheckCircle size={14} /> Applied</>
          ) : (
            <><Save size={14} /> Apply Changes</>
          )}
        </button>

        <button
          onClick={() => { void handleReset(); }}
          disabled={isBusy || !agentOnline}
          className="flex items-center gap-2 px-4 py-2.5 rounded-xl text-sm font-medium transition-opacity"
          style={{
            background: 'var(--surface)',
            border: '1px solid var(--border)',
            color: 'var(--muted)',
            opacity: (isBusy || !agentOnline) ? 0.4 : 1,
            cursor: (isBusy || !agentOnline) ? 'not-allowed' : 'pointer',
          }}
        >
          <RotateCcw size={14} />
          Reset to defaults
        </button>

        {!agentOnline && (
          <p className="text-xs" style={{ color: 'var(--subtle)' }}>Start the agent server to edit configuration.</p>
        )}
      </div>
    </div>
  );
}
