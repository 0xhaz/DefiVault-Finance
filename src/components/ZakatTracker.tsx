/**
 * ZakatTracker — shows lifetime Zakat distributed, the active charity wallet,
 * and the pending timelock change (if any). Used on the Shariah vault pages.
 */
import { useState } from 'react';
import { Heart, Clock, CheckCircle2 } from 'lucide-react';

interface ZakatState {
  totalDistributed: string;     // USDC, formatted
  zakatWallet: string;
  pendingWallet: string | null;
  walletChangeRequestTime: number; // unix seconds, 0 = no pending change
  timelockRemainingSeconds: number;
  zakatBps: number;             // always 250
  lastDistribution: number;     // unix seconds, 0 = never
  lastDistributionAmount: string;
}

const INITIAL_STATE: ZakatState = {
  totalDistributed: '0.00',
  zakatWallet: '0x0000000000000000000000000000000000000000',
  pendingWallet: null,
  walletChangeRequestTime: 0,
  timelockRemainingSeconds: 0,
  zakatBps: 250,
  lastDistribution: 0,
  lastDistributionAmount: '0.00',
};

function useZakatState(): ZakatState {
  // Pre-deploy: return zeros. Post-deploy: fetch from contract.
  const [state] = useState<ZakatState>(INITIAL_STATE);
  return state;
}

function formatAddress(addr: string): string {
  if (!addr || addr === '0x0000000000000000000000000000000000000000') return 'Not configured';
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

function formatRemaining(seconds: number): string {
  if (seconds <= 0) return 'Unlocked';
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  if (days > 0) return `${days}d ${hours}h remaining`;
  return `${hours}h ${Math.floor((seconds % 3600) / 60)}m remaining`;
}

export function ZakatTracker() {
  const state = useZakatState();

  if (!state) return null;

  const hasPending = !!state.pendingWallet;
  const timelockUnlocked = hasPending && state.timelockRemainingSeconds <= 0;

  return (
    <div
      className="rounded-xl p-4 space-y-4"
      style={{ background: 'var(--surface)', border: '1px solid var(--border)' }}
    >
      {/* Header */}
      <div className="flex items-center gap-2">
        <div className="w-7 h-7 rounded-lg flex items-center justify-center" style={{ background: 'rgba(141,216,159,0.12)' }}>
          <Heart size={14} style={{ color: '#8dd89f' }} />
        </div>
        <div>
          <p className="text-sm font-semibold" style={{ color: 'var(--ink-2)' }}>Zakat Distribution</p>
          <p className="text-xs" style={{ color: 'var(--subtle)' }}>2.5% auto-routed from Musharakah profits</p>
        </div>
      </div>

      {/* Stats row */}
      <div className="grid grid-cols-3 gap-2">
        {[
          { label: 'Lifetime Given', value: `$${state.totalDistributed}`, accent: '#8dd89f' },
          { label: 'Zakat Rate',     value: `${state.zakatBps / 100}%`,   accent: 'var(--accent)' },
          { label: 'Last Gift',      value: state.lastDistribution > 0 ? `$${state.lastDistributionAmount}` : '—', accent: 'var(--ink-2)' },
        ].map(item => (
          <div key={item.label} className="rounded-lg px-2 py-2 text-center" style={{ background: 'var(--surface-muted)' }}>
            <p className="text-xs tabular-nums font-semibold" style={{ color: item.accent }}>{item.value}</p>
            <p className="mt-0.5" style={{ color: 'var(--subtle)', fontSize: '0.6rem' }}>{item.label.toUpperCase()}</p>
          </div>
        ))}
      </div>

      {/* Active charity wallet */}
      <div className="rounded-lg px-3 py-2" style={{ background: 'var(--surface-muted)' }}>
        <div className="flex items-center justify-between">
          <span className="text-xs" style={{ color: 'var(--subtle)' }}>Charity wallet</span>
          <div className="flex items-center gap-1.5">
            <CheckCircle2 size={11} style={{ color: '#8dd89f' }} />
            <span className="font-mono text-xs" style={{ color: 'var(--ink-2)' }}>
              {formatAddress(state.zakatWallet)}
            </span>
          </div>
        </div>
      </div>

      {/* Pending timelock change (if any) */}
      {hasPending && (
        <div
          className="rounded-lg px-3 py-2 flex items-start gap-2"
          style={{
            background: timelockUnlocked ? 'rgba(141,216,159,0.06)' : 'rgba(240,180,41,0.06)',
            border: `1px solid ${timelockUnlocked ? 'rgba(141,216,159,0.2)' : 'rgba(240,180,41,0.2)'}`,
          }}
        >
          {timelockUnlocked
            ? <CheckCircle2 size={13} style={{ color: '#8dd89f', flexShrink: 0, marginTop: 1 }} />
            : <Clock size={13} style={{ color: '#f0b429', flexShrink: 0, marginTop: 1 }} />
          }
          <div className="flex-1 min-w-0">
            <p className="text-xs font-medium" style={{ color: timelockUnlocked ? '#8dd89f' : '#f0b429' }}>
              {timelockUnlocked ? 'Ready to confirm' : '30-day timelock active'}
            </p>
            <p className="text-xs truncate" style={{ color: 'var(--subtle)' }}>
              Proposed: {formatAddress(state.pendingWallet!)}
            </p>
            <p className="text-xs" style={{ color: 'var(--subtle)' }}>
              {formatRemaining(state.timelockRemainingSeconds)}
            </p>
          </div>
        </div>
      )}

      {/* Shariah note */}
      <p className="text-xs leading-relaxed" style={{ color: 'var(--subtle)' }}>
        Zakat is a pillar of Islamic finance. The vault automatically deducts 2.5% from every
        Musharakah profit claim before the Wakala-Musharakah split, routing it directly to the
        configured charity address. The 30-day timelock on wallet changes prevents sudden redirections.
      </p>
    </div>
  );
}
