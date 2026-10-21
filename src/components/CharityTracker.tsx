/**
 * CharityTracker — shows lifetime charitable contributions (sadaqah), the active
 * charity wallet, pending timelock change (if any), and a per-share estimate.
 *
 * Replaces ZakatTracker. The word "Zakat" is intentionally absent per AGENTS.md.
 * Board rulings SR-002 and SR-003 must be completed before live distributions.
 */
import { useState } from 'react';
import { Heart, Clock, CheckCircle2, AlertCircle } from 'lucide-react';

interface CharityState {
  totalDistributed: string;       // USDC, formatted
  charityWallet: string;
  pendingWallet: string | null;
  walletChangeRequestTime: number; // unix seconds, 0 = no pending change
  timelockRemainingSeconds: number;
  charityBps: number;             // default 250
  purificationBps: number;        // default 0
  lastDistribution: number;       // unix seconds, 0 = never
  lastDistributionAmount: string;
  boardRulingPending: boolean;    // SR-002 + SR-003 not yet approved
}

const INITIAL_STATE: CharityState = {
  totalDistributed: '0.00',
  charityWallet: '0x0000000000000000000000000000000000000000',
  pendingWallet: null,
  walletChangeRequestTime: 0,
  timelockRemainingSeconds: 0,
  charityBps: 250,
  purificationBps: 0,
  lastDistribution: 0,
  lastDistributionAmount: '0.00',
  boardRulingPending: true, // SR-002 and SR-003 outstanding
};

function useCharityState(): CharityState {
  // Pre-deploy: return defaults. Post-deploy: read from CharityModule contract.
  const [state] = useState<CharityState>(INITIAL_STATE);
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

export function CharityTracker() {
  const state = useCharityState();
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
        <div className="flex-1 min-w-0">
          <p className="text-sm font-semibold" style={{ color: 'var(--ink-2)' }}>Charitable Contribution</p>
          <p className="text-xs" style={{ color: 'var(--subtle)' }}>
            {state.charityBps / 100}% sadaqah auto-routed from Musharakah profits
          </p>
        </div>
        {state.boardRulingPending && (
          <span
            className="text-xs px-2 py-0.5 rounded-full font-semibold flex-shrink-0"
            style={{ background: 'rgba(240,180,41,0.12)', color: '#f0b429', fontSize: '0.6rem' }}
          >
            SR-002 PENDING
          </span>
        )}
      </div>

      {/* Board ruling notice */}
      {state.boardRulingPending && (
        <div
          className="rounded-lg px-3 py-2 flex items-start gap-2"
          style={{ background: 'rgba(240,180,41,0.06)', border: '1px solid rgba(240,180,41,0.18)' }}
        >
          <AlertCircle size={12} style={{ color: '#f0b429', flexShrink: 0, marginTop: 1 }} />
          <p className="text-xs leading-relaxed" style={{ color: 'var(--subtle)' }}>
            Distribution is pending board approval of the charity rate (SR-002) and
            designated wallet (SR-003). No funds will be routed until both rulings are recorded.
          </p>
        </div>
      )}

      {/* Stats row */}
      <div className="grid grid-cols-3 gap-2">
        {[
          { label: 'Lifetime Given',    value: `$${state.totalDistributed}`,         accent: '#8dd89f' },
          { label: 'Charity Rate',      value: `${state.charityBps / 100}%`,         accent: 'var(--accent)' },
          { label: 'Purification Rate', value: state.purificationBps > 0 ? `${state.purificationBps / 100}%` : 'None', accent: 'var(--ink-2)' },
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
          <span className="text-xs" style={{ color: 'var(--subtle)' }}>Charity wallet (SR-003)</span>
          <div className="flex items-center gap-1.5">
            {state.boardRulingPending
              ? <AlertCircle size={11} style={{ color: '#f0b429' }} />
              : <CheckCircle2 size={11} style={{ color: '#8dd89f' }} />
            }
            <span className="font-mono text-xs" style={{ color: 'var(--ink-2)' }}>
              {formatAddress(state.charityWallet)}
            </span>
          </div>
        </div>
      </div>

      {/* Pending timelock change */}
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
              {timelockUnlocked ? 'Wallet change ready to confirm' : '30-day timelock active'}
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

      {/* Disclosure */}
      <p className="text-xs leading-relaxed" style={{ color: 'var(--subtle)' }}>
        The vault deducts {state.charityBps / 100}% from every Musharakah profit claim before the
        Wakala-Musharakah split, routing it to the board-approved charity address. This is a
        voluntary charitable contribution (sadaqah). The 30-day timelock on wallet and rate
        changes prevents sudden redirections. Purification ({state.purificationBps > 0 ? `${state.purificationBps / 100}%` : 'currently 0%'}) is
        applied only when the board identifies a specific impure-income event.
      </p>
    </div>
  );
}
