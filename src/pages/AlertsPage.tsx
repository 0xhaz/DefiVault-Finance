import { Bell, Zap, AlertTriangle, TrendingUp, CheckCircle, Clock } from 'lucide-react';
import { useState } from 'react';

type AlertSeverity = 'info' | 'warning' | 'success' | 'trigger';

interface Alert {
  id: number;
  severity: AlertSeverity;
  title: string;
  body: string;
  age: string;
  read: boolean;
}

// Static demo alerts — real ones come from ScoreAggregator / VaultExecutor events once deployed
const DEMO_ALERTS: Alert[] = [
  {
    id: 1,
    severity: 'trigger',
    title: 'Strategy 2 crossed threshold',
    body: 'Funding Rate Arb score reached 95 (APY 16.4%). Agent queued execution.',
    age: '2m ago',
    read: false,
  },
  {
    id: 2,
    severity: 'warning',
    title: 'Score staleness detected',
    body: 'Strategy 3 (Bridge Flow) score is 6 min old. Aggregator has not been updated.',
    age: '8m ago',
    read: false,
  },
  {
    id: 3,
    severity: 'success',
    title: 'Execution cooldown elapsed',
    body: 'Aggressive executor cooldown cleared. Next executeWinner() call is unblocked.',
    age: '12m ago',
    read: false,
  },
];

const SEVERITY_STYLES: Record<AlertSeverity, { icon: React.ReactNode; bg: string; border: string; color: string }> = {
  trigger: {
    icon: <Zap size={14} strokeWidth={2} />,
    bg: 'rgba(172,198,233,0.07)',
    border: 'rgba(172,198,233,0.2)',
    color: '#acc6e9',
  },
  warning: {
    icon: <AlertTriangle size={14} strokeWidth={2} />,
    bg: 'rgba(240,180,41,0.07)',
    border: 'rgba(240,180,41,0.2)',
    color: '#f0b429',
  },
  success: {
    icon: <TrendingUp size={14} strokeWidth={2} />,
    bg: 'rgba(141,216,159,0.07)',
    border: 'rgba(141,216,159,0.2)',
    color: '#8dd89f',
  },
  info: {
    icon: <CheckCircle size={14} strokeWidth={2} />,
    bg: 'rgba(255,255,255,0.04)',
    border: 'rgba(255,255,255,0.1)',
    color: 'var(--muted)',
  },
};

const ALERT_SETTINGS = [
  { id: 'score_threshold', label: 'Score threshold crossed', desc: 'Notify when any strategy score crosses its execution threshold', enabled: true },
  { id: 'execution',       label: 'Execution triggered',     desc: 'Notify when the executor deploys capital into a strategy',        enabled: true },
  { id: 'staleness',       label: 'Score staleness',         desc: 'Notify when a strategy score has not been updated in 5+ minutes',  enabled: true },
  { id: 'health_factor',   label: 'Aave health factor',      desc: 'Notify when AaveLoopAdapter health factor drops below 1.8',        enabled: false },
  { id: 'pnl',             label: 'Position PnL',            desc: 'Notify when a closed position has negative PnL',                   enabled: false },
];

export function AlertsPage() {
  const [alerts, setAlerts] = useState<Alert[]>(DEMO_ALERTS);
  const [settings, setSettings] = useState(ALERT_SETTINGS);

  const unread = alerts.filter(a => !a.read).length;

  function markAllRead() {
    setAlerts(prev => prev.map(a => ({ ...a, read: true })));
  }

  function toggleSetting(id: string) {
    setSettings(prev => prev.map(s => s.id === id ? { ...s, enabled: !s.enabled } : s));
  }

  return (
    <div className="space-y-6">
      <div className="flex items-start justify-between gap-4">
        <div>
          <h1 className="display text-2xl font-bold" style={{ color: 'var(--ink)', letterSpacing: '-0.03em' }}>Alerts</h1>
          <p className="text-sm mt-1" style={{ color: 'var(--subtle)' }}>Agent notifications and threshold events</p>
        </div>
        {unread > 0 && (
          <button
            onClick={markAllRead}
            className="text-xs px-3 py-1.5 rounded-lg"
            style={{ background: 'rgba(172,198,233,0.1)', color: 'var(--accent)', border: '1px solid rgba(172,198,233,0.2)' }}
          >
            Mark all read
          </button>
        )}
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Feed */}
        <div className="lg:col-span-2 space-y-3">
          <div className="flex items-center justify-between mb-1">
            <p className="text-xs uppercase" style={{ color: 'var(--subtle)', letterSpacing: '0.08em' }}>Recent</p>
            {unread > 0 && (
              <span className="text-xs px-1.5 py-0.5 rounded-full tabular-nums" style={{ background: 'rgba(240,180,41,0.15)', color: '#f0b429', fontWeight: 600 }}>
                {unread} unread
              </span>
            )}
          </div>

          {alerts.length === 0 ? (
            <div className="rounded-xl px-6 py-12 flex flex-col items-center gap-3" style={{ background: 'var(--surface)', border: '1px solid var(--border)' }}>
              <Bell size={20} style={{ color: 'var(--subtle)' }} />
              <p className="text-sm" style={{ color: 'var(--muted)' }}>No alerts yet</p>
            </div>
          ) : (
            alerts.map(a => {
              const s = SEVERITY_STYLES[a.severity];
              return (
                <div
                  key={a.id}
                  className="rounded-xl px-4 py-3.5 flex gap-3 cursor-pointer transition-all"
                  style={{
                    background: a.read ? 'var(--surface)' : s.bg,
                    border: `1px solid ${a.read ? 'var(--border)' : s.border}`,
                    opacity: a.read ? 0.65 : 1,
                  }}
                  onClick={() => setAlerts(prev => prev.map(x => x.id === a.id ? { ...x, read: true } : x))}
                >
                  <div className="w-6 h-6 rounded-md flex items-center justify-center flex-shrink-0 mt-0.5" style={{ background: `rgba(172,198,233,0.08)`, color: s.color }}>
                    {s.icon}
                  </div>
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center justify-between gap-2">
                      <p className="text-sm font-medium" style={{ color: 'var(--ink-2)' }}>{a.title}</p>
                      <div className="flex items-center gap-1.5 flex-shrink-0">
                        <Clock size={11} style={{ color: 'var(--subtle)' }} />
                        <span className="text-xs tabular-nums" style={{ color: 'var(--subtle)' }}>{a.age}</span>
                      </div>
                    </div>
                    <p className="text-xs mt-0.5 leading-relaxed" style={{ color: 'var(--muted)' }}>{a.body}</p>
                  </div>
                  {!a.read && (
                    <span className="w-1.5 h-1.5 rounded-full flex-shrink-0 mt-2" style={{ background: s.color }} />
                  )}
                </div>
              );
            })
          )}
        </div>

        {/* Settings */}
        <div>
          <p className="text-xs uppercase mb-3" style={{ color: 'var(--subtle)', letterSpacing: '0.08em' }}>Notification Settings</p>
          <div className="rounded-xl overflow-hidden" style={{ border: '1px solid var(--border)' }}>
            {settings.map((s, i) => (
              <div
                key={s.id}
                className="flex items-start gap-3 px-4 py-3.5"
                style={{
                  background: 'var(--surface)',
                  borderBottom: i < settings.length - 1 ? '1px solid rgba(255,255,255,0.05)' : 'none',
                }}
              >
                <div className="flex-1 min-w-0 pt-0.5">
                  <p className="text-xs font-medium" style={{ color: 'var(--ink-2)' }}>{s.label}</p>
                  <p className="text-xs mt-0.5 leading-relaxed" style={{ color: 'var(--subtle)' }}>{s.desc}</p>
                </div>
                <button
                  onClick={() => toggleSetting(s.id)}
                  className="flex-shrink-0 mt-0.5 w-9 h-5 rounded-full relative transition-all"
                  style={{ background: s.enabled ? 'rgba(141,216,159,0.4)' : 'rgba(255,255,255,0.1)', border: `1px solid ${s.enabled ? 'rgba(141,216,159,0.6)' : 'rgba(255,255,255,0.15)'}` }}
                >
                  <span
                    className="absolute top-0.5 w-3.5 h-3.5 rounded-full transition-all"
                    style={{
                      background: s.enabled ? '#8dd89f' : 'var(--subtle)',
                      left: s.enabled ? 'calc(100% - 1rem)' : '2px',
                    }}
                  />
                </button>
              </div>
            ))}
          </div>
          <p className="text-xs mt-3" style={{ color: 'var(--subtle)' }}>
            Full push notifications require contract deployment and a webhook endpoint.
          </p>
        </div>
      </div>
    </div>
  );
}
