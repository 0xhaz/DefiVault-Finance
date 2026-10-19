import { useEffect, useState } from 'react';
import { Brain, RefreshCw, Wifi, WifiOff } from 'lucide-react';
import { STRATEGY_NAMES, STRATEGY_COLORS, CCTP_DOMAIN_BADGES } from '../contracts';

interface AgentStatusData {
  running: boolean;
  lastCycleAt: number | null;
  cycleCount: number;
  pendingCctp?: number;
  scores: Array<{ strategy: string; score: number; signal?: string; triggered?: boolean; destinationDomain?: number; destinationName?: string }>;
  raw: {
    uniswapSpread: number;
    fundingRatePct: number;
    stargateFlowUsd: number;
    stargateImpactPct: number;
    aaveHealthFactor: number;
    ondoYieldApy: number;
  } | null;
}

interface AgentStatusProps {
  onRunningChange?: (running: boolean) => void;
}

export function AgentStatus({ onRunningChange }: AgentStatusProps) {
  const [status, setStatus] = useState<AgentStatusData | null>(null);
  const [error, setError] = useState(false);
  const [triggering, setTriggering] = useState(false);

  async function fetchStatus() {
    try {
      const res = await fetch('/api/status');
      if (!res.ok) throw new Error('not ok');
      const data = await res.json() as AgentStatusData;
      setStatus(data);
      setError(false);
      onRunningChange?.(data.running);
    } catch {
      setError(true);
      onRunningChange?.(false);
    }
  }

  async function manualTrigger() {
    setTriggering(true);
    try {
      await fetch('/api/trigger', { method: 'POST' });
      await fetchStatus();
    } catch {
      // ignore
    } finally {
      setTriggering(false);
    }
  }

  useEffect(() => {
    void fetchStatus();
    const id = setInterval(() => { void fetchStatus(); }, 10_000);
    return () => clearInterval(id);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const dataItems = status?.raw ? [
    { label: 'USDC Spread', value: `${(status.raw.uniswapSpread * 100).toFixed(1)} bps` },
    { label: 'ETH Funding Rate', value: `${status.raw.fundingRatePct.toFixed(4)}%/8h` },
    { label: 'Bridge Flow', value: `$${(status.raw.stargateFlowUsd / 1000).toFixed(0)}K` },
    { label: 'Bridge Impact', value: `${status.raw.stargateImpactPct.toFixed(2)}%` },
    { label: 'Aave HF', value: status.raw.aaveHealthFactor.toFixed(3) },
    { label: 'OUSG APY', value: `${status.raw.ondoYieldApy.toFixed(2)}%` },
  ] : [];

  return (
    <div className="rounded-xl overflow-hidden" style={{ border: '1px solid var(--border)', background: 'var(--surface)' }}>
      {/* Header */}
      <div
        className="flex items-center justify-between px-4 py-3"
        style={{ borderBottom: '1px solid var(--border)', background: 'var(--surface-muted)' }}
      >
        <div className="flex items-center gap-2">
          <Brain size={14} style={{ color: 'var(--accent)' }} />
          <span className="text-sm font-medium" style={{ color: 'var(--ink-2)' }}>AI Agent</span>
          {error ? (
            <WifiOff size={12} style={{ color: 'var(--danger)' }} />
          ) : status?.running ? (
            <Wifi size={12} style={{ color: 'var(--success)' }} />
          ) : null}
        </div>
        <div className="flex items-center gap-2">
          {status && (
            <span className="text-xs" style={{ color: 'var(--subtle)' }}>
              Cycle #{status.cycleCount}
            </span>
          )}
          <button
            onClick={() => { void manualTrigger(); }}
            disabled={triggering}
            className="flex items-center gap-1 text-xs px-2.5 py-1 rounded-lg transition-all disabled:opacity-40"
            style={{ background: 'var(--surface)', color: 'var(--accent)', border: '1px solid var(--border)' }}
          >
            <RefreshCw size={11} className={triggering ? 'animate-spin' : ''} />
            Run cycle
          </button>
        </div>
      </div>

      {error ? (
        <div className="px-4 py-3 text-center">
          <p className="text-xs" style={{ color: 'var(--subtle)' }}>
            Agent not running — start with <span className="mono">bun run agent</span>
          </p>
        </div>
      ) : !status ? (
        <div className="px-4 py-3 text-center">
          <p className="text-xs" style={{ color: 'var(--subtle)' }}>Connecting to agent…</p>
        </div>
      ) : (
        <div className="p-4 space-y-4">
          {/* Market data grid */}
          <div>
            <p className="text-xs uppercase mb-2" style={{ color: 'var(--subtle)', letterSpacing: '0.06em' }}>
              Live Market Data
            </p>
            <div className="grid grid-cols-3 gap-2">
              {dataItems.map(item => (
                <div key={item.label} className="rounded-lg px-2.5 py-2" style={{ background: 'var(--surface-muted)' }}>
                  <p className="text-xs" style={{ color: 'var(--subtle)' }}>{item.label}</p>
                  <p className="tabular-nums text-sm font-medium" style={{ color: 'var(--ink-2)' }}>{item.value}</p>
                </div>
              ))}
            </div>
          </div>

          {/* Agent scores */}
          {status.scores.length > 0 && (
            <div>
              <p className="text-xs uppercase mb-2" style={{ color: 'var(--subtle)', letterSpacing: '0.06em' }}>
                Agent Evaluation
              </p>
              <div className="space-y-2">
                {status.scores.map((s, i) => {
                  const domain = s.destinationDomain ?? 0;
                  const badge = domain === 0 ? 'LOCAL' : `CCTP→${CCTP_DOMAIN_BADGES[domain] ?? domain}`;
                  return (
                    <div key={s.strategy} className="rounded-lg p-2.5" style={{ background: 'var(--surface-muted)' }}>
                      <div className="flex items-center gap-2 mb-1">
                        <span className="w-1.5 h-1.5 rounded-full flex-shrink-0" style={{ background: STRATEGY_COLORS[i] }} />
                        <span className="text-xs flex-1 font-medium" style={{ color: 'var(--ink-2)' }}>
                          {STRATEGY_NAMES[i] ?? s.strategy}
                        </span>
                        <span
                          className="mono px-1 py-0.5 rounded"
                          style={{
                            background: domain === 0 ? 'rgba(172,198,233,0.08)' : 'rgba(240,180,41,0.1)',
                            color: domain === 0 ? 'var(--subtle)' : '#f0b429',
                            fontSize: '0.58rem',
                          }}
                        >
                          {badge}
                        </span>
                        {s.triggered && (
                          <span className="mono px-1 py-0.5 rounded" style={{ background: 'rgba(141,216,159,0.12)', color: '#8dd89f', fontSize: '0.58rem' }}>
                            TRIGGERED
                          </span>
                        )}
                        <span className="tabular-nums text-xs font-bold" style={{ color: STRATEGY_COLORS[i] }}>
                          {s.score}
                        </span>
                      </div>
                      {s.signal && (
                        <p className="text-xs pl-3.5" style={{ color: 'var(--subtle)' }}>{s.signal}</p>
                      )}
                      <div className="mt-1.5 h-0.5 rounded-full overflow-hidden" style={{ background: 'var(--border)' }}>
                        <div className="h-full rounded-full" style={{ width: `${s.score}%`, background: STRATEGY_COLORS[i], transition: 'width 0.5s ease' }} />
                      </div>
                    </div>
                  );
                })}
              </div>
            </div>
          )}

          {/* Pending CCTP attestations */}
          {(status.pendingCctp ?? 0) > 0 && (
            <div className="rounded-lg px-3 py-2 flex items-center justify-between" style={{ background: 'rgba(240,180,41,0.08)', border: '1px solid rgba(240,180,41,0.2)' }}>
              <span className="text-xs" style={{ color: '#f0b429' }}>Pending CCTP attestations</span>
              <span className="tabular-nums text-xs font-semibold" style={{ color: '#f0b429' }}>{status.pendingCctp}</span>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
