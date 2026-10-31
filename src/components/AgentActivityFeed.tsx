import { useEffect, useState } from 'react';
import { useWatchContractEvent } from 'wagmi';
import { formatUnits } from 'viem';
import { Zap, TrendingUp, AlertCircle, CheckCircle, ArrowUpRight } from 'lucide-react';
import { AGGREGATOR_ADDRESS, AGGREGATOR_ABI, EXECUTOR_ADDRESS, EXECUTOR_ABI, STRATEGY_NAMES, STRATEGY_COLORS } from '../contracts';
import { ARC_CHAIN_ID, ARC_EXPLORER } from '../chain';

type EventKind = 'score' | 'execution' | 'info' | 'warning';

interface ActivityEvent {
  id: string;
  kind: EventKind;
  title: string;
  detail: string;
  timestamp: number;
  strategyIdx?: number;
  txHash?: string;
}

function EventIcon({ kind }: { kind: EventKind }) {
  const style = { width: 14, height: 14 };
  if (kind === 'score') return <TrendingUp style={{ ...style, color: 'var(--accent)' }} />;
  if (kind === 'execution') return <Zap style={{ ...style, color: '#f0b429' }} />;
  if (kind === 'warning') return <AlertCircle style={{ ...style, color: 'var(--danger)' }} />;
  return <CheckCircle style={{ ...style, color: 'var(--success)' }} />;
}

function timeAgo(ts: number): string {
  const diff = Math.floor((Date.now() - ts) / 1000);
  if (diff < 60) return `${diff}s ago`;
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  return `${Math.floor(diff / 3600)}h ago`;
}

function shortHash(h: string): string {
  return `${h.slice(0, 8)}…${h.slice(-6)}`;
}


const SEED_EVENTS: ActivityEvent[] = [
  { id: 'seed-1', kind: 'info', title: 'Agent initialised', detail: 'Scanning 5 data sources in parallel', timestamp: Date.now() - 90_000 },
];

export function AgentActivityFeed() {
  const [events, setEvents] = useState<ActivityEvent[]>(SEED_EVENTS);

  function push(ev: ActivityEvent) {
    setEvents(prev => [ev, ...prev].slice(0, 50));
  }

  const aggregatorEnabled = AGGREGATOR_ADDRESS.length > 2;
  const executorEnabled = EXECUTOR_ADDRESS.length > 2;

  useWatchContractEvent({
    address: AGGREGATOR_ADDRESS,
    abi: AGGREGATOR_ABI,
    eventName: 'ScoreUpdated',
    chainId: ARC_CHAIN_ID,
    enabled: aggregatorEnabled,
    onLogs(logs) {
      for (const log of logs) {
        const { strategy, value } = log.args as { strategy: number; value: number; timestamp: number; dataHash: string };
        const stratIdx = Number(strategy);
        push({
          id: log.transactionHash ?? `score-${Date.now()}`,
          kind: 'score',
          title: `${STRATEGY_NAMES[stratIdx] ?? `Strategy ${stratIdx}`} scored`,
          detail: `New score ${value}/100, ${value >= 80 ? 'VERY HIGH' : value >= 60 ? 'HIGH' : value >= 40 ? 'MEDIUM' : 'LOW'} opportunity`,
          timestamp: Date.now(),
          strategyIdx: stratIdx,
          txHash: log.transactionHash ?? undefined,
        });
      }
    },
  });

  useWatchContractEvent({
    address: EXECUTOR_ADDRESS,
    abi: EXECUTOR_ABI,
    eventName: 'ExecutionTriggered',
    chainId: ARC_CHAIN_ID,
    enabled: executorEnabled,
    onLogs(logs) {
      for (const log of logs) {
        const { strategy, score, amount, target } = log.args as { strategy: number; score: number; amount: bigint; target: string };
        push({
          id: log.transactionHash ?? `exec-${Date.now()}`,
          kind: 'execution',
          title: `Capital deployed`,
          detail: `$${parseFloat(formatUnits(amount, 6)).toLocaleString()} → ${STRATEGY_NAMES[Number(strategy)] ?? `Strategy ${strategy}`} (score ${score}) at ${target.slice(0, 10)}…`,
          timestamp: Date.now(),
          strategyIdx: Number(strategy),
          txHash: log.transactionHash ?? undefined,
        });
      }
    },
  });

  // Simulate agent heartbeats when contracts not yet deployed
  useEffect(() => {
    if (aggregatorEnabled) return;
    const strategies = [
      { name: 'Stablecoin Spread', detail: 'USDC spread 0.18%, APY ~11.4%', score: 45 },
      { name: 'Funding Rate Arb', detail: 'ETH-PERP funding rate 0.015%/8h, APY 16.4%', score: 95 },
      { name: 'Bridge Flow', detail: 'Stargate $1.2M flow detected, impact 0.42%', score: 90 },
      { name: 'Liquidation + RWA', detail: 'Aave HF 1.12, OUSG yield 4.8% APY', score: 60 },
    ];
    let idx = 0;
    const timer = setInterval(() => {
      const s = strategies[idx % strategies.length];
      push({
        id: `sim-${Date.now()}`,
        kind: 'score',
        title: `${s.name} evaluated`,
        detail: `${s.detail} → Score: ${s.score}/100`,
        timestamp: Date.now(),
        strategyIdx: idx % 4,
      });
      idx++;
    }, 8_000);
    return () => clearInterval(timer);
  }, [aggregatorEnabled]);

  return (
    <section>
      <div className="flex items-center justify-between mb-3">
        <h2 className="text-xs uppercase tracking-wider" style={{ color: 'var(--subtle)', letterSpacing: '0.08em' }}>
          Agent Activity
        </h2>
        <span className="flex items-center gap-1.5">
          <span className="w-1.5 h-1.5 rounded-full animate-pulse" style={{ background: 'var(--success)' }} />
          <span className="text-xs" style={{ color: 'var(--subtle)' }}>Live</span>
        </span>
      </div>

      <div
        className="rounded-xl overflow-hidden"
        style={{ border: '1px solid var(--border)', background: 'var(--surface)' }}
      >
        {events.length === 0 ? (
          <div className="p-8 text-center">
            <p className="text-sm" style={{ color: 'var(--subtle)' }}>Waiting for events…</p>
          </div>
        ) : (
          <div className="divide-y" style={{ '--tw-divide-opacity': 1 } as React.CSSProperties}>
            {events.map((ev) => (
              <div
                key={ev.id}
                className="flex items-start gap-3 px-4 py-3 transition-all"
                style={{ borderColor: 'var(--border)' }}
              >
                <div className="mt-0.5 flex-shrink-0">
                  <EventIcon kind={ev.kind} />
                </div>
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2 flex-wrap">
                    <p className="text-sm font-medium" style={{ color: 'var(--ink-2)' }}>{ev.title}</p>
                    {ev.strategyIdx !== undefined && (
                      <span
                        className="w-1.5 h-1.5 rounded-full flex-shrink-0"
                        style={{ background: STRATEGY_COLORS[ev.strategyIdx] }}
                      />
                    )}
                    {ev.txHash && (
                      <a
                        href={`${ARC_EXPLORER}/tx/${ev.txHash}`}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="flex items-center gap-0.5 mono text-xs"
                        style={{ color: 'var(--accent)' }}
                      >
                        {shortHash(ev.txHash)}
                        <ArrowUpRight size={10} />
                      </a>
                    )}
                  </div>
                  <p className="text-xs mt-0.5" style={{ color: 'var(--subtle)' }}>{ev.detail}</p>
                </div>
                <span className="text-xs flex-shrink-0 mt-0.5" style={{ color: 'var(--subtle)' }}>
                  {timeAgo(ev.timestamp)}
                </span>
              </div>
            ))}
          </div>
        )}
      </div>
    </section>
  );
}
