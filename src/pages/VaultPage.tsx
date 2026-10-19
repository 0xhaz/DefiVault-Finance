import { VaultStats } from '../components/VaultStats';
import { VaultActions } from '../components/VaultActions';
import { VaultPicker } from '../components/VaultPicker';
import { ActivePositions } from '../components/ActivePositions';
import { ZakatTracker } from '../components/ZakatTracker';
import { FeeDisclosure } from '../components/FeeDisclosure';
import { TreasuryPanel } from '../components/TreasuryPanel';
import { Shield, Zap, Moon, Info } from 'lucide-react';
import type { VaultMode, TierSelection } from '../App';

interface VaultPageProps {
  selectedTier: TierSelection;
  onSelectTier: (t: TierSelection) => void;
  vaultMode:    VaultMode;
}

const TIER_SPECS: Record<TierSelection, {
  name: string; tagline: string; color: string; icon: React.ReactNode;
  specs: { label: string; value: string }[];
  description: string;
  isShariahTier: boolean;
}> = {
  passive: {
    name: 'Passive Vault', tagline: 'Stable yield, minimal risk', color: '#acc6e9',
    icon: <Shield size={16} strokeWidth={1.8} />,
    isShariahTier: false,
    specs: [
      { label: 'Target APY',          value: '8–14%' },
      { label: 'Max Allocation',      value: '40% of TVL' },
      { label: 'Min Score',           value: '80 / 100' },
      { label: 'Execution Cooldown',  value: '2 hours' },
      { label: 'Max Gas Price',       value: '20 gwei' },
      { label: 'Crosschain',          value: 'Disabled' },
      { label: 'Strategies',          value: 'S1, S4' },
      { label: 'Protocols',           value: 'Compound V3, Curve 3pool' },
    ],
    description: 'Allocates to the two lowest-volatility strategies: stablecoin spread arbitrage and the Liquidation+RWA blend. Capital is kept local on Arc. The execution cooldown and high minimum score mean the agent only fires on strong, well-formed signals.',
  },
  aggressive: {
    name: 'Aggressive Vault', tagline: 'Higher yield, accepts mid risk', color: '#f0b429',
    icon: <Zap size={16} strokeWidth={1.8} />,
    isShariahTier: false,
    specs: [
      { label: 'Target APY',          value: '18–34%' },
      { label: 'Max Allocation',      value: '80% of TVL' },
      { label: 'Min Score',           value: '60 / 100' },
      { label: 'Execution Cooldown',  value: '30 minutes' },
      { label: 'Max Gas Price',       value: '50 gwei' },
      { label: 'Crosschain',          value: 'Enabled via CCTP' },
      { label: 'Strategies',          value: 'S1, S2, S3, S4' },
      { label: 'Protocols',           value: 'Aave 2x Loop, GMX GLP, Compound, Curve' },
    ],
    description: 'All 4 strategies compete for capital. Funding rate arb and bridge front-running add higher-yield opportunities with corresponding volatility. Aave loop amplifies yield via 2x leverage. Crosschain CCTP bridges pre-position ahead of detected capital flows.',
  },
  'shariah-conservative': {
    name: 'Conservative Shariah', tagline: 'Low-volatility halal strategies only', color: '#8dd89f',
    icon: <Moon size={16} strokeWidth={1.8} />,
    isShariahTier: true,
    specs: [
      { label: 'Target APY',          value: '8–16%' },
      { label: 'Max Allocation',      value: '50% of TVL' },
      { label: 'Min Score',           value: '80 / 100' },
      { label: 'Execution Cooldown',  value: '2 hours' },
      { label: 'Wakala Fee',          value: '0.5% AUM/yr' },
      { label: 'Musharakah Share',    value: '10% above 4% hurdle' },
      { label: 'Zakat',               value: '2.5% auto-routed' },
      { label: 'Strategies',          value: 'S2-H, S3-H, S5-H' },
    ],
    description: 'Three low-volatility Shariah strategies: PAXG gold spread, Halal Uniswap V3 LP (USDC/ETH or USDC/PAXG), and RWA/Sukuk yield via OUSG and BUIDL. No Murabaha trades and no stablecoin spread — conservative depositors get stable yield with minimal volatility. No riba-based lending, no perp funding, no front-running.',
  },
  'shariah-dynamic': {
    name: 'Dynamic Shariah', tagline: 'All 5 halal strategies, higher yield', color: '#c9b8f5',
    icon: <Moon size={16} strokeWidth={1.8} />,
    isShariahTier: true,
    specs: [
      { label: 'Target APY',          value: '12–22%' },
      { label: 'Max Allocation',      value: '70% of TVL' },
      { label: 'Min Score',           value: '70 / 100' },
      { label: 'Execution Cooldown',  value: '1 hour' },
      { label: 'Wakala Fee',          value: '0.5% AUM/yr' },
      { label: 'Musharakah Share',    value: '10% above 4% hurdle' },
      { label: 'Zakat',               value: '2.5% auto-routed' },
      { label: 'Strategies',          value: 'All 5 halal (S1-H – S5-H)' },
    ],
    description: 'All five Shariah-board certified strategies: USDC/ETH spread, PAXG gold spread, Halal Uniswap V3 LP, Commodity Murabaha, and RWA/Sukuk yield via OUSG and BUIDL. Dynamic allocation across all five maximises halal yield. No riba-based lending, no perp funding, no front-running. Zakat auto-routed before Musharakah profit split.',
  },
};

export function VaultPage({ selectedTier, onSelectTier, vaultMode }: VaultPageProps) {
  const spec = TIER_SPECS[selectedTier];

  return (
    <div className="space-y-6">
      <div>
        <h1 className="display text-2xl font-bold" style={{ color: 'var(--ink)', letterSpacing: '-0.03em' }}>Vault</h1>
        <p className="text-sm mt-1" style={{ color: 'var(--subtle)' }}>Deposit USDC and manage your position</p>
      </div>

      <VaultPicker selectedTier={selectedTier} onSelect={onSelectTier} vaultMode={vaultMode} />

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Left column */}
        <div className="lg:col-span-2 space-y-5">
          <VaultStats />

          {/* Spec card */}
          <div className="rounded-xl p-5" style={{ background: 'var(--surface)', border: '1px solid var(--border)' }}>
            <div className="flex items-start gap-3 mb-4">
              <div
                className="w-9 h-9 rounded-lg flex items-center justify-center flex-shrink-0"
                style={{ background: `${spec.color}1a`, color: spec.color, border: `1px solid ${spec.color}26` }}
              >
                {spec.icon}
              </div>
              <div>
                <p className="text-sm font-semibold" style={{ color: 'var(--ink-2)' }}>{spec.name}</p>
                <p className="text-xs mt-0.5" style={{ color: 'var(--subtle)' }}>{spec.tagline}</p>
              </div>
              {spec.isShariahTier && (
                <span
                  className="ml-auto text-xs px-2 py-0.5 rounded-full font-semibold"
                  style={{ background: 'rgba(141,216,159,0.12)', color: '#8dd89f', fontSize: '0.6rem', alignSelf: 'flex-start' }}
                >
                  SHARIAH CERTIFIED
                </span>
              )}
            </div>

            <p className="text-xs leading-relaxed mb-5 text-pretty" style={{ color: 'var(--muted)', maxWidth: '52ch' }}>
              {spec.description}
            </p>

            <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
              {spec.specs.map(s => (
                <div key={s.label} className="rounded-lg px-3 py-2.5"
                  style={{ background: 'var(--surface-muted)', border: '1px solid var(--border)' }}>
                  <p className="text-xs" style={{ color: 'var(--subtle)', fontSize: '0.6rem', letterSpacing: '0.06em', textTransform: 'uppercase' }}>{s.label}</p>
                  <p className="text-sm font-semibold mt-0.5 tabular-nums" style={{ color: 'var(--ink-2)' }}>{s.value}</p>
                </div>
              ))}
            </div>
          </div>

          {/* Shariah-specific panels */}
          {spec.isShariahTier && (
            <div className="space-y-4">
              <ZakatTracker />
              <FeeDisclosure isShariahTier />
              <TreasuryPanel isShariahTier />
            </div>
          )}

          {!spec.isShariahTier && (
            <FeeDisclosure isShariahTier={false} />
          )}

          <ActivePositions />
        </div>

        {/* Right column */}
        <div className="space-y-4">
          <VaultActions />
          <div
            className="rounded-xl px-4 py-3.5 flex gap-3"
            style={{ background: `${spec.color}0a`, border: `1px solid ${spec.color}26` }}
          >
            <Info size={14} style={{ color: spec.color, flexShrink: 0, marginTop: 1 }} />
            <p className="text-xs leading-relaxed" style={{ color: 'var(--muted)' }}>
              {spec.isShariahTier
                ? 'Shares are ERC-4626 compliant and Shariah-certified. Withdraw any time — Musharakah profit is claimed separately by the vault manager after the settlement period.'
                : 'Shares are ERC-4626 compliant. Withdraw any time — the agent will automatically recall capital from the active strategy adapter to fulfil your redemption.'}
            </p>
          </div>
        </div>
      </div>
    </div>
  );
}
