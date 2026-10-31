import { useState } from 'react';
import { ArrowRight, Zap, Shield, TrendingUp, ChevronRight, ArrowLeftRight, Moon, Star } from 'lucide-react';
import type { Page } from '../components/Sidebar';
import { ARC_NETWORK_NAME } from '../chain';

interface LandingPageProps {
  onNavigate: (p: Page) => void;
}

const STATS = [
  { label: 'Target APY',      value: '18–34%',  sub: 'Aggressive vault' },
  { label: 'Shariah APY',       value: '8–16%',   sub: 'Shariah Conservative' },
  { label: 'Scan Interval',   value: '30s',      sub: 'Fastest strategy' },
  { label: 'Total Strategies',value: '9',        sub: '4 conventional · 5 screened' },
];

const FEATURES = [
  {
    icon: <Zap size={18} strokeWidth={1.8} />,
    title: 'Autonomous Execution',
    desc: 'The AI agent scans DeFi signals every 30 seconds, scores 9 strategies 0–100, and routes capital to the highest-conviction opportunity with no human input required.',
    color: '#acc6e9',
  },
  {
    icon: <ArrowLeftRight size={18} strokeWidth={1.8} />,
    title: 'Crosschain Capital',
    desc: 'Capital flows across Arbitrum, Base, and Optimism via CCTP. When a better opportunity exists on another chain, the vault bridges USDC atomically and pre-positions automatically.',
    color: '#f0b429',
  },
  {
    icon: <Shield size={18} strokeWidth={1.8} />,
    title: 'Four Risk Tiers',
    desc: 'Passive and Aggressive for conventional DeFi. Conservative Shariah (Gold Spread + LP + Gold Allocation) and Dynamic Shariah (all 5 active screened strategies) for the Muslim community — fully isolated capital.',
    color: '#8dd89f',
  },
  {
    icon: <Moon size={18} strokeWidth={1.8} />,
    title: 'Shariah-Screened',
    desc: 'Two dedicated Shariah vaults with Wakala (0.5% AUM) + Musharakah (10% profit-share above 4% hurdle) fee structure and automatic 2.5% charity routing. 5 active screened strategies. RWA removed per board screening (SR-001).',
    color: '#c9b8f5',
  },
  {
    icon: <TrendingUp size={18} strokeWidth={1.8} />,
    title: 'ERC-4626 Standard',
    desc: 'All four vaults are fully ERC-4626 compliant. Deposit USDC, receive yield-bearing shares. Compatible with any DeFi protocol or aggregator that reads the standard.',
    color: '#e86d7a',
  },
  {
    icon: <Star size={18} strokeWidth={1.8} />,
    title: 'Transparent Fees',
    desc: 'Conventional vaults charge a flat 0.75% AUM admin fee. Shariah vaults use a Wakala+Musharakah model — no hidden spread, no interest, no riba-based protocol actions.',
    color: '#f0c17a',
  },
];

const CONVENTIONAL_STRATEGIES = [
  { num: 'S1', name: 'Cross-Chain Stablecoin Spread',  trigger: 'Every 30s',    rule: 'USDC deviation >0.3% across Arbitrum/Base/OP',              tiers: ['passive'] },
  { num: 'S2', name: 'Perpetual Funding Rate Arb',     trigger: 'Every 30s',    rule: 'Hyperliquid ETH-PERP annualized APY >12%',                   tiers: ['aggressive'] },
  { num: 'S3', name: 'Bridge Flow Front-Running',      trigger: 'Event-driven', rule: 'Stargate transfer >$500K and pool impact >0.4%',             tiers: ['aggressive'] },
  { num: 'S4', name: 'Liquidation + RWA Yield',        trigger: 'Every 45s',    rule: '≥7 at-risk Aave positions (+40) and OUSG spread >1.5% (+50)', tiers: ['passive'] },
];

const SHARIAH_STRATEGIES = [
  { num: 'S1-H', name: 'USDC/ETH Cross-Chain Spread',    trigger: 'Every 30s',    rule: 'Spread >0.35% between Arc/Arbitrum/Base — commodity arbitrage (SR-007 pending)',                tiers: ['dynamic'] },
  { num: 'S2-H', name: 'Atomic Gold Spread',             trigger: 'Every 30s',    rule: 'PAXG/USDC swap >0.4% premium — single-tx atomic swap (yad bi yad, SR-005)',                      tiers: ['conservative', 'dynamic'] },
  { num: 'S3-H', name: 'Swap-fee Liquidity Pool',           trigger: 'Event-driven', rule: 'Uniswap V3 USDC/ETH swap-fee APY >8% — swap-fee income only',                                    tiers: ['conservative', 'dynamic'] },
  { num: 'S4-H', name: 'Commodity Murabaha',             trigger: 'Event-driven', rule: 'Murabaha trade request with markup >1.2% — cost-plus, counterparty required',                     tiers: ['dynamic'] },
  // S5-H (RWA/Sukuk) removed — OUSG/BUIDL are US Treasury-backed; yield is riba. SR-001.
  { num: 'S6-H', name: 'Gold Allocation (XAUT, spot)',   trigger: 'Every 5 min',  rule: 'XAUT weight drifts >5% from 20% target — no yield, value follows gold price (SR-008 pending)',   tiers: ['conservative', 'dynamic'] },
];

const VAULT_TIERS = [
  {
    label: 'Passive',
    color: '#acc6e9',
    community: 'Conventional',
    apy: '8–14%',
    risk: 'Minimal',
    strategies: 'S1 + S4',
    protocols: 'Compound V3, Curve 3pool',
    minScore: 80,
    cooldown: '2h',
    halal: false,
  },
  {
    label: 'Aggressive',
    color: '#f0b429',
    community: 'Conventional',
    apy: '18–34%',
    risk: 'Managed',
    strategies: 'All 4',
    protocols: 'Aave 2x Loop, GMX GLP',
    minScore: 60,
    cooldown: '30m',
    halal: false,
  },
  {
    label: 'Conservative Shariah',
    color: '#8dd89f',
    community: 'Shariah',
    apy: '8–16%',
    risk: 'Low volatility',
    strategies: 'S2-H + S3-H + S6-H',
    protocols: 'Uniswap V3, PAXG, XAUT (atomic)',
    minScore: 80,
    cooldown: '2h',
    halal: true,
  },
  {
    label: 'Dynamic Shariah',
    color: '#c9b8f5',
    community: 'Shariah',
    apy: '12–22%',
    risk: 'Moderate',
    strategies: 'All 5 screened',
    protocols: 'Uniswap V3, PAXG, XAUT, Murabaha',
    minScore: 70,
    cooldown: '1h',
    halal: true,
  },
];

type StratTab = 'conventional' | 'shariah';

export function LandingPage({ onNavigate }: LandingPageProps) {
  const [stratTab, setStratTab] = useState<StratTab>('conventional');

  return (
    <div className="min-h-dvh" style={{ background: 'var(--bg-gradient)' }}>

      {/* ── Hero ─────────────────────────────────────────── */}
      <section className="relative overflow-hidden">
        {/* Background grid */}
        <div
          className="absolute inset-0 pointer-events-none"
          style={{
            backgroundImage: 'linear-gradient(rgba(172,198,233,0.04) 1px, transparent 1px), linear-gradient(90deg, rgba(172,198,233,0.04) 1px, transparent 1px)',
            backgroundSize: '48px 48px',
          }}
        />
        {/* Radial glow — dual: blue for conventional, green for Shariah */}
        <div
          className="absolute top-0 left-1/3 w-[600px] h-[400px] pointer-events-none"
          style={{ background: 'radial-gradient(ellipse at top, rgba(172,198,233,0.07) 0%, transparent 65%)' }}
        />
        <div
          className="absolute top-0 right-1/4 w-[500px] h-[350px] pointer-events-none"
          style={{ background: 'radial-gradient(ellipse at top, rgba(141,216,159,0.06) 0%, transparent 65%)' }}
        />

        <div className="relative max-w-5xl mx-auto px-6 pt-24 pb-20 text-center">
          {/* Brand badge */}
          <div className="inline-flex items-center gap-2 rounded-full px-3 py-1.5 mb-6" style={{ background: 'rgba(172,198,233,0.08)', border: '1px solid rgba(172,198,233,0.2)' }}>
            <span className="w-1.5 h-1.5 rounded-full" style={{ background: 'var(--success)', boxShadow: '0 0 6px #8dd89f' }} />
            <span className="text-xs font-medium" style={{ color: 'var(--accent)' }}>defivault.finance · {ARC_NETWORK_NAME} · Shariah Screened</span>
          </div>

          {/* Wordmark */}
          <p className="display text-base font-semibold mb-3 tracking-widest uppercase" style={{ color: 'var(--subtle)', letterSpacing: '0.18em' }}>
            DeFiVault
          </p>

          <h1
            className="display text-5xl sm:text-6xl lg:text-7xl font-bold mb-6 text-balance"
            style={{ color: 'var(--ink)', letterSpacing: '-0.04em', lineHeight: 1.05 }}
          >
            DeFi capital,{' '}
            <span
              style={{
                background: 'linear-gradient(135deg, #acc6e9 0%, #5e9bd4 45%, #8dd89f 100%)',
                WebkitBackgroundClip: 'text',
                WebkitTextFillColor: 'transparent',
                backgroundClip: 'text',
              }}
            >
              autonomously allocated
            </span>
          </h1>

          <p
            className="text-lg sm:text-xl max-w-2xl mx-auto mb-4 text-pretty"
            style={{ color: 'var(--muted)', lineHeight: 1.65 }}
          >
            An ERC-4626 vault where an AI agent hunts for the highest-yield signal across 8 strategies and 5 chains — and deploys your USDC without any human intervention.
          </p>

          {/* Community callout */}
          <p className="text-sm max-w-xl mx-auto mb-10 text-pretty" style={{ color: 'var(--subtle)', lineHeight: 1.6 }}>
            Two communities, four vaults. Conventional investors get Passive and Aggressive tiers.
            The Muslim community gets two fully isolated Shariah vaults with Wakala fees and charity routing — 5 screened strategies including gold allocation (XAUT, spot). RWA removed per SR-001.
          </p>

          <div className="flex flex-col sm:flex-row items-center justify-center gap-3">
            <button
              onClick={() => onNavigate('dashboard')}
              className="flex items-center gap-2 px-6 py-3 rounded-xl text-sm font-semibold transition-all"
              style={{ background: 'var(--accent)', color: '#0a1628' }}
            >
              Open App
              <ArrowRight size={15} strokeWidth={2.5} />
            </button>
            <button
              onClick={() => onNavigate('strategies')}
              className="flex items-center gap-2 px-6 py-3 rounded-xl text-sm font-medium"
              style={{ background: 'rgba(255,255,255,0.06)', color: 'var(--ink-2)', border: '1px solid var(--border)' }}
            >
              View Strategies
            </button>
          </div>
        </div>
      </section>

      {/* ── Stats row ────────────────────────────────────── */}
      <section className="max-w-5xl mx-auto px-6 pb-16">
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-4">
          {STATS.map(s => (
            <div
              key={s.label}
              className="rounded-xl px-5 py-4 text-center"
              style={{ background: 'var(--surface)', border: '1px solid var(--border)' }}
            >
              <p className="display text-2xl font-bold tabular-nums" style={{ color: 'var(--ink)', letterSpacing: '-0.03em' }}>{s.value}</p>
              <p className="text-xs font-medium mt-0.5" style={{ color: 'var(--muted)' }}>{s.label}</p>
              <p className="text-xs mt-0.5" style={{ color: 'var(--subtle)' }}>{s.sub}</p>
            </div>
          ))}
        </div>
      </section>

      {/* ── Vault Tiers ──────────────────────────────────── */}
      <section className="max-w-5xl mx-auto px-6 pb-20">
        <div className="flex items-center justify-between mb-6">
          <p className="text-xs uppercase" style={{ color: 'var(--subtle)', letterSpacing: '0.1em' }}>Four vault tiers</p>
          <button
            onClick={() => onNavigate('vault')}
            className="flex items-center gap-1 text-xs"
            style={{ color: 'var(--accent)' }}
          >
            Open vault <ChevronRight size={12} />
          </button>
        </div>
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
          {VAULT_TIERS.map(t => (
            <button
              key={t.label}
              onClick={() => onNavigate('vault')}
              className="rounded-xl p-4 text-left transition-all hover:scale-[1.02]"
              style={{
                background: `linear-gradient(135deg, rgba(${hexToRgb(t.color)},0.06) 0%, transparent 100%)`,
                border: `1px solid rgba(${hexToRgb(t.color)},0.22)`,
              }}
            >
              <div className="flex items-start justify-between mb-3">
                <div>
                  <p className="text-xs font-semibold" style={{ color: t.color, letterSpacing: '0.05em' }}>
                    {t.community.toUpperCase()}
                  </p>
                  <p className="text-sm font-semibold mt-0.5" style={{ color: 'var(--ink-2)' }}>{t.label}</p>
                </div>
                {t.halal && (
                  <span
                    className="text-xs px-1.5 py-0.5 rounded font-semibold flex-shrink-0"
                    style={{ background: 'rgba(141,216,159,0.12)', color: '#8dd89f', fontSize: '0.6rem', letterSpacing: '0.06em' }}
                  >
                    Shariah
                  </span>
                )}
              </div>

              <p className="display text-xl font-bold tabular-nums mb-1" style={{ color: t.color, letterSpacing: '-0.02em' }}>{t.apy}</p>
              <p className="text-xs mb-3" style={{ color: 'var(--subtle)' }}>Target APY · {t.risk} risk</p>

              <div className="space-y-1 pt-2" style={{ borderTop: `1px solid rgba(${hexToRgb(t.color)},0.12)` }}>
                <div className="flex items-center justify-between">
                  <span className="text-xs" style={{ color: 'var(--subtle)' }}>Strategies</span>
                  <span className="text-xs font-medium" style={{ color: 'var(--ink-2)' }}>{t.strategies}</span>
                </div>
                <div className="flex items-center justify-between">
                  <span className="text-xs" style={{ color: 'var(--subtle)' }}>Min score</span>
                  <span className="text-xs font-medium tabular-nums" style={{ color: 'var(--ink-2)' }}>{t.minScore}</span>
                </div>
                <div className="flex items-center justify-between">
                  <span className="text-xs" style={{ color: 'var(--subtle)' }}>Cooldown</span>
                  <span className="text-xs font-medium" style={{ color: 'var(--ink-2)' }}>{t.cooldown}</span>
                </div>
              </div>
            </button>
          ))}
        </div>
      </section>

      {/* ── Features ─────────────────────────────────────── */}
      <section className="max-w-5xl mx-auto px-6 pb-20">
        <p className="text-xs uppercase mb-8 text-center" style={{ color: 'var(--subtle)', letterSpacing: '0.1em' }}>How it works</p>
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-5">
          {FEATURES.map(f => (
            <div
              key={f.title}
              className="rounded-xl p-5"
              style={{ background: 'var(--surface)', border: '1px solid var(--border)' }}
            >
              <div
                className="w-9 h-9 rounded-lg flex items-center justify-center mb-4"
                style={{ background: `rgba(${hexToRgb(f.color)}, 0.12)`, border: `1px solid rgba(${hexToRgb(f.color)}, 0.2)`, color: f.color }}
              >
                {f.icon}
              </div>
              <h3 className="text-sm font-semibold mb-2" style={{ color: 'var(--ink-2)' }}>{f.title}</h3>
              <p className="text-xs leading-relaxed text-pretty" style={{ color: 'var(--muted)' }}>{f.desc}</p>
            </div>
          ))}
        </div>
      </section>

      {/* ── Strategies table ─────────────────────────────── */}
      <section className="max-w-5xl mx-auto px-6 pb-20">
        <div className="flex items-center justify-between mb-5">
          <p className="text-xs uppercase" style={{ color: 'var(--subtle)', letterSpacing: '0.1em' }}>Live strategies</p>
          <button
            onClick={() => onNavigate('strategies')}
            className="flex items-center gap-1 text-xs"
            style={{ color: 'var(--accent)' }}
          >
            View all <ChevronRight size={12} />
          </button>
        </div>

        {/* Tab bar */}
        <div className="flex gap-1 mb-4 p-1 rounded-lg w-fit" style={{ background: 'var(--surface)', border: '1px solid var(--border)' }}>
          {(['conventional', 'shariah'] as StratTab[]).map(tab => (
            <button
              key={tab}
              onClick={() => setStratTab(tab)}
              className="px-4 py-1.5 rounded-md text-xs font-semibold transition-all capitalize"
              style={
                stratTab === tab
                  ? { background: tab === 'shariah' ? 'rgba(141,216,159,0.15)' : 'rgba(172,198,233,0.15)', color: tab === 'shariah' ? '#8dd89f' : 'var(--accent)' }
                  : { color: 'var(--subtle)' }
              }
            >
              {tab === 'shariah' ? 'Shariah' : 'Conventional'}
            </button>
          ))}
        </div>

        <div className="rounded-xl overflow-hidden" style={{ border: '1px solid var(--border)' }}>
          {(stratTab === 'conventional' ? CONVENTIONAL_STRATEGIES : SHARIAH_STRATEGIES).map((s, i, arr) => (
            <div
              key={s.num}
              className="flex items-start gap-4 px-5 py-4"
              style={{
                background: i % 2 === 0 ? 'var(--surface)' : 'rgba(255,255,255,0.03)',
                borderBottom: i < arr.length - 1 ? '1px solid rgba(255,255,255,0.05)' : 'none',
              }}
            >
              <span className="mono text-xs pt-0.5 flex-shrink-0 tabular-nums" style={{ color: 'var(--subtle)' }}>{s.num}</span>
              <div className="flex-1 min-w-0">
                <p className="text-sm font-medium" style={{ color: 'var(--ink-2)' }}>{s.name}</p>
                <p className="text-xs mt-0.5 text-pretty" style={{ color: 'var(--subtle)' }}>{s.rule}</p>
              </div>
              <div className="flex items-center gap-2 flex-shrink-0 flex-wrap justify-end">
                {s.tiers.map(tier => (
                  <span
                    key={tier}
                    className="text-xs px-2 py-0.5 rounded"
                    style={{
                      background: TIER_PILL_BG[tier] ?? 'rgba(172,198,233,0.1)',
                      color: TIER_PILL_COLOR[tier] ?? 'var(--accent)',
                      fontSize: '0.6rem',
                      fontWeight: 600,
                      textTransform: 'uppercase',
                      letterSpacing: '0.06em',
                    }}
                  >
                    {tier}
                  </span>
                ))}
                <span className="text-xs" style={{ color: 'var(--subtle)' }}>{s.trigger}</span>
              </div>
            </div>
          ))}
        </div>
      </section>

      {/* ── Community split banner ───────────────────────── */}
      <section className="max-w-5xl mx-auto px-6 pb-20">
        <div
          className="rounded-2xl overflow-hidden"
          style={{ border: '1px solid var(--border)' }}
        >
          <div className="grid grid-cols-1 sm:grid-cols-2">
            {/* Conventional side */}
            <div
              className="px-8 py-8"
              style={{ background: 'linear-gradient(135deg, rgba(172,198,233,0.08) 0%, transparent 100%)', borderRight: '1px solid var(--border)' }}
            >
              <p className="text-xs uppercase mb-3 font-semibold" style={{ color: 'var(--accent)', letterSpacing: '0.1em' }}>Conventional</p>
              <h3 className="display text-xl font-bold mb-2" style={{ color: 'var(--ink)', letterSpacing: '-0.02em' }}>Two risk tiers, maximum yield</h3>
              <p className="text-sm mb-5 text-pretty" style={{ color: 'var(--muted)', lineHeight: 1.6 }}>
                Passive vault runs S1+S4 with Compound V3 and Curve 3pool. Aggressive adds leveraged Aave loops and GMX GLP for higher yield.
                Flat 0.75% AUM admin fee.
              </p>
              <div className="flex gap-3">
                <div className="rounded-lg px-3 py-2 text-center" style={{ background: 'rgba(172,198,233,0.08)', border: '1px solid rgba(172,198,233,0.15)' }}>
                  <p className="display text-lg font-bold" style={{ color: '#acc6e9' }}>8–14%</p>
                  <p className="text-xs" style={{ color: 'var(--subtle)' }}>Passive APY</p>
                </div>
                <div className="rounded-lg px-3 py-2 text-center" style={{ background: 'rgba(240,180,41,0.08)', border: '1px solid rgba(240,180,41,0.15)' }}>
                  <p className="display text-lg font-bold" style={{ color: '#f0b429' }}>18–34%</p>
                  <p className="text-xs" style={{ color: 'var(--subtle)' }}>Aggressive APY</p>
                </div>
              </div>
            </div>

            {/* Shariah side */}
            <div
              className="px-8 py-8"
              style={{ background: 'linear-gradient(135deg, rgba(141,216,159,0.07) 0%, transparent 100%)' }}
            >
              <div className="flex items-center gap-2 mb-3">
                <p className="text-xs uppercase font-semibold" style={{ color: '#8dd89f', letterSpacing: '0.1em' }}>Shariah</p>
              </div>
              <h3 className="display text-xl font-bold mb-2" style={{ color: 'var(--ink)', letterSpacing: '-0.02em' }}>Two Shariah tiers, no riba</h3>
              <p className="text-sm mb-5 text-pretty" style={{ color: 'var(--muted)', lineHeight: 1.6 }}>
                Conservative Shariah runs Gold Spread + LP + Gold Allocation (mask 0b100110). Dynamic Shariah runs all 5 active strategies (mask 0b101111).
                Wakala 0.5% + Musharakah 10% fees. Charity 2.5% routing. RWA removed per SR-001.
              </p>
              <div className="flex gap-3">
                <div className="rounded-lg px-3 py-2 text-center" style={{ background: 'rgba(141,216,159,0.08)', border: '1px solid rgba(141,216,159,0.15)' }}>
                  <p className="display text-lg font-bold" style={{ color: '#8dd89f' }}>8–16%</p>
                  <p className="text-xs" style={{ color: 'var(--subtle)' }}>Conservative APY</p>
                </div>
                <div className="rounded-lg px-3 py-2 text-center" style={{ background: 'rgba(201,184,245,0.08)', border: '1px solid rgba(201,184,245,0.15)' }}>
                  <p className="display text-lg font-bold" style={{ color: '#c9b8f5' }}>12–22%</p>
                  <p className="text-xs" style={{ color: 'var(--subtle)' }}>Dynamic APY</p>
                </div>
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* ── CTA banner ───────────────────────────────────── */}
      <section className="max-w-5xl mx-auto px-6 pb-24">
        <div
          className="rounded-2xl px-8 py-10 text-center relative overflow-hidden"
          style={{ background: 'linear-gradient(135deg, rgba(172,198,233,0.08) 0%, rgba(141,216,159,0.06) 100%)', border: '1px solid rgba(172,198,233,0.2)' }}
        >
          <div
            className="absolute top-0 right-0 w-64 h-64 pointer-events-none"
            style={{ background: 'radial-gradient(circle at top right, rgba(172,198,233,0.07) 0%, transparent 60%)' }}
          />
          <div
            className="absolute bottom-0 left-0 w-48 h-48 pointer-events-none"
            style={{ background: 'radial-gradient(circle at bottom left, rgba(141,216,159,0.06) 0%, transparent 60%)' }}
          />
          <h2 className="display text-2xl font-bold mb-3 relative" style={{ color: 'var(--ink)', letterSpacing: '-0.03em' }}>
            Ready to let the agent work?
          </h2>
          <p className="text-sm mb-2 relative" style={{ color: 'var(--muted)' }}>
            Deposit USDC, choose your risk tier and community, and the agent handles the rest.
          </p>
          <p className="text-xs mb-8 relative" style={{ color: 'var(--subtle)' }}>
            Conventional investors: Passive or Aggressive. Muslim community: Conservative Shariah or Dynamic Shariah.
          </p>
          <div className="flex flex-col sm:flex-row items-center justify-center gap-3 relative">
            <button
              onClick={() => onNavigate('vault')}
              className="inline-flex items-center gap-2 px-6 py-3 rounded-xl text-sm font-semibold"
              style={{ background: 'var(--accent)', color: '#0a1628' }}
            >
              Open Vault
              <ArrowRight size={15} strokeWidth={2.5} />
            </button>
            <button
              onClick={() => onNavigate('strategies')}
              className="inline-flex items-center gap-2 px-6 py-3 rounded-xl text-sm font-medium"
              style={{ background: 'rgba(141,216,159,0.1)', color: '#8dd89f', border: '1px solid rgba(141,216,159,0.2)' }}
            >
              Shariah Vaults
              <Moon size={14} strokeWidth={2} />
            </button>
          </div>
        </div>
      </section>

      {/* Footer */}
      <footer className="border-t pb-8 pt-6 text-center" style={{ borderColor: 'rgba(255,255,255,0.06)' }}>
        <p className="text-xs" style={{ color: 'var(--subtle)' }}>
          DeFiVault · defivault.finance · AI-powered ERC-4626 capital allocator · {ARC_NETWORK_NAME}
        </p>
      </footer>
    </div>
  );
}

const TIER_PILL_BG: Record<string, string> = {
  passive:      'rgba(172,198,233,0.1)',
  aggressive:   'rgba(240,180,41,0.1)',
  conservative: 'rgba(141,216,159,0.1)',
  dynamic:      'rgba(201,184,245,0.1)',
};

const TIER_PILL_COLOR: Record<string, string> = {
  passive:      '#acc6e9',
  aggressive:   '#f0b429',
  conservative: '#8dd89f',
  dynamic:      '#c9b8f5',
};

function hexToRgb(hex: string): string {
  if (hex.startsWith('#')) {
    const r = parseInt(hex.slice(1, 3), 16);
    const g = parseInt(hex.slice(3, 5), 16);
    const b = parseInt(hex.slice(5, 7), 16);
    return `${r}, ${g}, ${b}`;
  }
  return '172, 198, 233';
}
