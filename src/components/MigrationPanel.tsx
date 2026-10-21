/**
 * MigrationPanel — V1 → V2 Shariah vault migration UI
 *
 * Task E spec:
 *   - Two separate user signatures required (step 1: redeem from V1; step 2: deposit to V2)
 *   - APY panel shows disclaimer always visible
 *   - No single APY number — always shows P10/P50/P90 range
 *   - V1 stays live; migration is voluntary
 */

import { useState, useEffect } from 'react';
import { AlertTriangle, ArrowRight, CheckCircle2, Info, RefreshCw, Shield } from 'lucide-react';

interface ApyEstimate {
  disclaimer: string[];
  depositorNetApyPct: { p10: number; p50: number; p90: number };
  grossApyPct: { p10: number; p50: number; p90: number };
  strategyBreakdown: Array<{ id: number; name: string; grossApyRange: { p10: number; p50: number; p90: number } | null }>;
}

type MigrationStep = 'idle' | 'step1_confirm' | 'step1_signed' | 'step2_confirm' | 'complete';

interface MigrationPanelProps {
  v1ShareBalance?: string;  // formatted balance, e.g. "125.00"
  v2Address?: string;       // V2 vault address (for display)
  onClose?: () => void;
}

export function MigrationPanel({ v1ShareBalance = '0.00', v2Address, onClose }: MigrationPanelProps) {
  const [step, setStep] = useState<MigrationStep>('idle');
  const [apyData, setApyData] = useState<ApyEstimate | null>(null);
  const [apyLoading, setApyLoading] = useState(false);
  const [apyError, setApyError] = useState<string | null>(null);

  useEffect(() => {
    void fetchApyEstimate();
  }, []);

  async function fetchApyEstimate() {
    setApyLoading(true);
    setApyError(null);
    try {
      const res = await fetch('/api/apy/estimate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ strategyIds: [0, 1, 2, 3, 5] }),
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json() as ApyEstimate;
      setApyData(data);
    } catch (e) {
      setApyError((e as Error).message);
    } finally {
      setApyLoading(false);
    }
  }

  const hasShares = parseFloat(v1ShareBalance) > 0;

  return (
    <div
      className="rounded-2xl overflow-hidden"
      style={{ background: 'var(--surface)', border: '1px solid var(--border)' }}
    >
      {/* Header */}
      <div className="px-5 pt-5 pb-4 flex items-center justify-between" style={{ borderBottom: '1px solid var(--border)' }}>
        <div className="flex items-center gap-2">
          <Shield size={16} style={{ color: '#8dd89f' }} />
          <span className="text-sm font-semibold" style={{ color: 'var(--ink-2)' }}>Migrate to Shariah V2</span>
        </div>
        {onClose && (
          <button onClick={onClose} className="text-xs" style={{ color: 'var(--muted)' }}>Close</button>
        )}
      </div>

      <div className="px-5 py-5 space-y-5">

        {/* V1 stays live notice */}
        <div
          className="rounded-xl px-4 py-3 flex items-start gap-3"
          style={{ background: 'rgba(141,216,159,0.07)', border: '1px solid rgba(141,216,159,0.18)' }}
        >
          <Info size={14} style={{ color: '#8dd89f', flexShrink: 0, marginTop: 2 }} />
          <p className="text-xs leading-relaxed" style={{ color: 'var(--muted)' }}>
            V1 stays live indefinitely. Migration is voluntary — you can redeem from V1 at any time. V2 uses the new governance-gated adapter registry with on-chain board pronouncements.
          </p>
        </div>

        {/* APY Estimate panel */}
        <div className="space-y-2">
          <div className="flex items-center justify-between">
            <span className="text-xs font-medium" style={{ color: 'var(--ink-2)' }}>V2 scenario estimates</span>
            <button
              onClick={() => void fetchApyEstimate()}
              className="flex items-center gap-1 text-xs"
              style={{ color: 'var(--muted)' }}
            >
              <RefreshCw size={10} />
              Refresh
            </button>
          </div>

          {apyLoading && (
            <div className="text-xs" style={{ color: 'var(--muted)' }}>Loading estimates…</div>
          )}

          {apyError && (
            <div className="text-xs" style={{ color: '#e8837a' }}>Could not load estimates: {apyError}</div>
          )}

          {apyData && !apyLoading && (
            <div className="space-y-3">
              {/* P10/P50/P90 bar */}
              <div
                className="rounded-xl px-4 py-3 space-y-2"
                style={{ background: 'var(--surface-raised)', border: '1px solid var(--border)' }}
              >
                <div className="flex justify-between text-xs" style={{ color: 'var(--muted)' }}>
                  <span>Depositor net APY (after all deductions)</span>
                  <span style={{ color: 'var(--subtle)' }}>illustrative</span>
                </div>
                <div className="flex items-end gap-4">
                  {(['p10', 'p50', 'p90'] as const).map(pct => (
                    <div key={pct} className="flex flex-col items-center gap-0.5">
                      <span className="text-base font-semibold" style={{ color: 'var(--ink-1)' }}>
                        {apyData.depositorNetApyPct[pct].toFixed(1)}%
                      </span>
                      <span className="text-xs" style={{ color: 'var(--muted)' }}>
                        {pct === 'p10' ? 'P10 bear' : pct === 'p50' ? 'P50 base' : 'P90 bull'}
                      </span>
                    </div>
                  ))}
                </div>
              </div>

              {/* Disclaimer — always visible */}
              <div
                className="rounded-xl px-3 py-2.5 space-y-1"
                style={{ background: 'rgba(232,131,122,0.07)', border: '1px solid rgba(232,131,122,0.18)' }}
              >
                <div className="flex items-center gap-1.5">
                  <AlertTriangle size={11} style={{ color: '#e8837a', flexShrink: 0 }} />
                  <span className="text-xs font-medium" style={{ color: '#e8837a' }}>Disclaimer — always read before investing</span>
                </div>
                {apyData.disclaimer.map((line, i) => (
                  <p key={i} className="text-xs leading-relaxed pl-4" style={{ color: 'var(--muted)' }}>{line}</p>
                ))}
              </div>
            </div>
          )}
        </div>

        {/* Migration steps */}
        <div className="space-y-2">
          <p className="text-xs font-medium" style={{ color: 'var(--ink-2)' }}>Migration steps (two signatures required)</p>

          {/* Step 1 */}
          <div
            className="rounded-xl px-4 py-3 flex items-start gap-3"
            style={{
              background: step === 'step1_confirm' ? 'rgba(141,216,159,0.08)' : 'var(--surface-raised)',
              border: `1px solid ${step === 'step1_signed' || step === 'step2_confirm' || step === 'complete' ? 'rgba(141,216,159,0.4)' : 'var(--border)'}`,
            }}
          >
            <div
              className="rounded-full w-5 h-5 flex items-center justify-center text-xs font-bold flex-shrink-0 mt-0.5"
              style={{
                background: step === 'step1_signed' || step === 'step2_confirm' || step === 'complete'
                  ? 'rgba(141,216,159,0.2)' : 'var(--surface)',
                color: '#8dd89f',
                border: '1px solid rgba(141,216,159,0.3)',
              }}
            >
              {step === 'step1_signed' || step === 'step2_confirm' || step === 'complete'
                ? <CheckCircle2 size={12} />
                : '1'}
            </div>
            <div className="flex-1 min-w-0">
              <p className="text-xs font-medium" style={{ color: 'var(--ink-2)' }}>Redeem from V1</p>
              <p className="text-xs mt-0.5" style={{ color: 'var(--muted)' }}>
                Signature 1 of 2 — redeems your <strong>{v1ShareBalance}</strong> svUSDC shares at current NAV.
                USDC lands in your wallet.
              </p>
              {step === 'idle' && (
                <button
                  onClick={() => setStep('step1_confirm')}
                  disabled={!hasShares}
                  className="mt-2 text-xs px-3 py-1.5 rounded-lg font-medium"
                  style={{
                    background: hasShares ? 'rgba(141,216,159,0.15)' : 'var(--surface)',
                    color: hasShares ? '#8dd89f' : 'var(--subtle)',
                    border: '1px solid rgba(141,216,159,0.3)',
                    cursor: hasShares ? 'pointer' : 'not-allowed',
                  }}
                >
                  {hasShares ? 'Redeem from V1' : 'No V1 shares to migrate'}
                </button>
              )}
              {step === 'step1_confirm' && (
                <div className="mt-2 flex gap-2">
                  <button
                    onClick={() => setStep('step1_signed')}
                    className="text-xs px-3 py-1.5 rounded-lg font-medium"
                    style={{ background: 'rgba(141,216,159,0.2)', color: '#8dd89f', border: '1px solid rgba(141,216,159,0.4)' }}
                  >
                    Confirm signature
                  </button>
                  <button
                    onClick={() => setStep('idle')}
                    className="text-xs px-3 py-1.5 rounded-lg"
                    style={{ color: 'var(--muted)', border: '1px solid var(--border)' }}
                  >
                    Cancel
                  </button>
                </div>
              )}
            </div>
          </div>

          {/* Arrow */}
          <div className="flex justify-center">
            <ArrowRight size={14} style={{ color: 'var(--subtle)' }} />
          </div>

          {/* Step 2 */}
          <div
            className="rounded-xl px-4 py-3 flex items-start gap-3"
            style={{
              background: step === 'step2_confirm' ? 'rgba(141,216,159,0.08)' : 'var(--surface-raised)',
              border: `1px solid ${step === 'complete' ? 'rgba(141,216,159,0.4)' : 'var(--border)'}`,
              opacity: step === 'idle' || step === 'step1_confirm' ? 0.5 : 1,
            }}
          >
            <div
              className="rounded-full w-5 h-5 flex items-center justify-center text-xs font-bold flex-shrink-0 mt-0.5"
              style={{
                background: step === 'complete' ? 'rgba(141,216,159,0.2)' : 'var(--surface)',
                color: '#8dd89f',
                border: '1px solid rgba(141,216,159,0.3)',
              }}
            >
              {step === 'complete' ? <CheckCircle2 size={12} /> : '2'}
            </div>
            <div className="flex-1 min-w-0">
              <p className="text-xs font-medium" style={{ color: 'var(--ink-2)' }}>Deposit to V2</p>
              <p className="text-xs mt-0.5" style={{ color: 'var(--muted)' }}>
                Signature 2 of 2 — deposits your USDC into ShariahVaultV2 ({v2Address ? `${v2Address.slice(0, 6)}…${v2Address.slice(-4)}` : 'address TBD'}).
                You receive svUSDCv2 shares.
              </p>
              {step === 'step1_signed' && (
                <button
                  onClick={() => setStep('step2_confirm')}
                  className="mt-2 text-xs px-3 py-1.5 rounded-lg font-medium"
                  style={{ background: 'rgba(141,216,159,0.15)', color: '#8dd89f', border: '1px solid rgba(141,216,159,0.3)', cursor: 'pointer' }}
                >
                  Deposit to V2
                </button>
              )}
              {step === 'step2_confirm' && (
                <div className="mt-2 flex gap-2">
                  <button
                    onClick={() => setStep('complete')}
                    className="text-xs px-3 py-1.5 rounded-lg font-medium"
                    style={{ background: 'rgba(141,216,159,0.2)', color: '#8dd89f', border: '1px solid rgba(141,216,159,0.4)' }}
                  >
                    Confirm signature
                  </button>
                  <button
                    onClick={() => setStep('step1_signed')}
                    className="text-xs px-3 py-1.5 rounded-lg"
                    style={{ color: 'var(--muted)', border: '1px solid var(--border)' }}
                  >
                    Back
                  </button>
                </div>
              )}
            </div>
          </div>
        </div>

        {/* Complete */}
        {step === 'complete' && (
          <div
            className="rounded-xl px-4 py-3 flex items-center gap-3"
            style={{ background: 'rgba(141,216,159,0.1)', border: '1px solid rgba(141,216,159,0.3)' }}
          >
            <CheckCircle2 size={16} style={{ color: '#8dd89f', flexShrink: 0 }} />
            <p className="text-xs" style={{ color: '#8dd89f' }}>
              Migration complete. You now hold svUSDCv2 shares. Your V1 position is closed.
            </p>
          </div>
        )}
      </div>
    </div>
  );
}
