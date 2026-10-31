/**
 * FeeDisclosure — side-by-side fee model comparison for all three vault tiers.
 * Conventional (0.75% AUM), Shariah (0.5% Wakala + 10% Musharakah), and a comparison row.
 */
import { Info, Shield, Moon } from 'lucide-react';

interface FeeRow {
  label: string;
  conventional: string;
  shariah: string;
  note?: string;
}

const FEE_ROWS: FeeRow[] = [
  {
    label: 'Annual management fee',
    conventional: '0.75% AUM',
    shariah: '0.5% Wakala',
    note: 'AUM-based, accrued continuously',
  },
  {
    label: 'Performance fee',
    conventional: 'None',
    shariah: '10% Musharakah profit-share',
    note: 'Only on profits above the 4% hurdle rate',
  },
  {
    label: 'Hurdle rate',
    conventional: '—',
    shariah: '4% APY',
    note: 'Vault only participates in profits above 4%',
  },
  {
    label: 'Charity deduction (sadaqah)',
    conventional: '—',
    shariah: '2.5% of gross Musharakah profit',
    note: 'Routed to charity wallet before fee split',
  },
  {
    label: 'Fee destination',
    conventional: 'ConventionalTreasury',
    shariah: 'ShariahTreasury',
    note: 'Separate treasuries; funds never mix',
  },
  {
    label: 'Fee mechanism',
    conventional: 'Accounting-only accrual; owner sweeps on claim',
    shariah: 'Accounting-only accrual; owner sweeps on claim',
    note: 'A sweep can never exceed the fees owed',
  },
];

interface TierBadgeProps {
  label: string;
  icon: typeof Shield;
  color: string;
}

function TierBadge({ label, icon: Icon, color }: TierBadgeProps) {
  return (
    <div className="flex items-center gap-1.5">
      <div className="w-5 h-5 rounded flex items-center justify-center" style={{ background: `${color}1a` }}>
        <Icon size={11} style={{ color }} />
      </div>
      <span className="text-xs font-semibold" style={{ color }}>{label}</span>
    </div>
  );
}

export function FeeDisclosure({ isShariahTier: _isShariahTier }: { isShariahTier?: boolean }) {
  return (
    <div
      className="rounded-xl overflow-hidden"
      style={{ background: 'var(--surface)', border: '1px solid var(--border)' }}
    >
      {/* Header */}
      <div className="px-4 py-3 flex items-center gap-2" style={{ borderBottom: '1px solid var(--border)' }}>
        <Info size={13} style={{ color: 'var(--subtle)' }} />
        <p className="text-sm font-semibold" style={{ color: 'var(--ink-2)' }}>Fee Disclosure</p>
        <span
          className="ml-auto text-xs px-2 py-0.5 rounded-full font-medium"
          style={{ background: 'rgba(141,216,159,0.1)', color: '#8dd89f' }}
        >
          Shariah compliant
        </span>
      </div>

      {/* Column headers */}
      <div
        className="grid px-4 py-2"
        style={{
          gridTemplateColumns: '1.6fr 1fr 1fr',
          borderBottom: '1px solid var(--border)',
          background: 'var(--surface-muted)',
        }}
      >
        <span className="text-xs" style={{ color: 'var(--subtle)' }}>Fee item</span>
        <TierBadge label="Conventional" icon={Shield} color="#acc6e9" />
        <TierBadge label="Shariah" icon={Moon} color="#c5b3f7" />
      </div>

      {/* Rows */}
      <div className="divide-y" style={{ borderColor: 'var(--border)' }}>
        {FEE_ROWS.map(row => (
          <div
            key={row.label}
            className="grid px-4 py-2.5 gap-2 items-start"
            style={{ gridTemplateColumns: '1.6fr 1fr 1fr' }}
          >
            <div>
              <p className="text-xs font-medium" style={{ color: 'var(--ink-2)' }}>{row.label}</p>
              {row.note && (
                <p className="text-xs mt-0.5 leading-relaxed" style={{ color: 'var(--subtle)', fontSize: '0.65rem' }}>
                  {row.note}
                </p>
              )}
            </div>
            <p className="text-xs" style={{ color: row.conventional === '—' ? 'var(--border)' : 'var(--ink-2)' }}>
              {row.conventional}
            </p>
            <p
              className="text-xs font-medium"
              style={{
                color: row.shariah === '—' ? 'var(--border)'
                  : row.label.startsWith('Charity') || row.shariah.includes('Musharakah') ? '#c5b3f7'
                  : 'var(--ink-2)',
              }}
            >
              {row.shariah}
            </p>
          </div>
        ))}
      </div>

      {/* Footer note */}
      <div className="px-4 py-3" style={{ borderTop: '1px solid var(--border)', background: 'rgba(197,179,247,0.04)' }}>
        <p className="text-xs leading-relaxed" style={{ color: 'var(--subtle)' }}>
          <span className="font-medium" style={{ color: '#c5b3f7' }}>Musharakah structure:</span> The vault acts as a
          silent partner (Rab al-Mal), providing capital. Returns are profit-sharing, not interest. The 10% vault share
          is earned only after depositors clear their 4% hurdle. Purification and the charity deduction come first, before
          any split.
        </p>
      </div>
    </div>
  );
}

// Compact inline variant for the vault cards
export function FeeDisclosureBadge({ tier }: { tier: 'conventional' | 'shariah' | 'passive' | 'aggressive' }) {
  if (tier === 'shariah') {
    return (
      <div className="flex flex-wrap gap-1.5">
        {[
          { label: '0.5% Wakala', color: '#c5b3f7' },
          { label: '10% Musharakah', color: '#c5b3f7' },
          { label: '2.5% Charity', color: '#8dd89f' },
        ].map(b => (
          <span
            key={b.label}
            className="text-xs px-1.5 py-0.5 rounded font-medium"
            style={{ background: `${b.color}1a`, color: b.color, fontSize: '0.65rem' }}
          >
            {b.label}
          </span>
        ))}
      </div>
    );
  }
  return (
    <span
      className="text-xs px-1.5 py-0.5 rounded font-medium"
      style={{ background: 'rgba(172,198,233,0.1)', color: '#acc6e9', fontSize: '0.65rem' }}
    >
      0.75% AUM
    </span>
  );
}
