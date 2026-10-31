import { LayoutDashboard, Vault, BarChart2, Briefcase, Bell, Settings, ChevronRight, Zap, X, Menu, Shield, Moon, Globe, BookOpen } from 'lucide-react';
import { useState } from 'react';
import type { VaultMode } from '../App';
import { ARC_NETWORK_NAME } from '../chain';

export type Page = 'landing' | 'dashboard' | 'vault' | 'strategies' | 'portfolio' | 'alerts' | 'settings' | 'docs';

const NAV_ITEMS: { id: Page; label: string; icon: React.ReactNode; badge?: string }[] = [
  { id: 'dashboard',  label: 'Dashboard',  icon: <LayoutDashboard size={16} strokeWidth={1.8} /> },
  { id: 'vault',      label: 'Vault',      icon: <Vault           size={16} strokeWidth={1.8} /> },
  { id: 'strategies', label: 'Strategies', icon: <BarChart2       size={16} strokeWidth={1.8} /> },
  { id: 'portfolio',  label: 'Portfolio',  icon: <Briefcase       size={16} strokeWidth={1.8} /> },
  { id: 'alerts',     label: 'Alerts',     icon: <Bell            size={16} strokeWidth={1.8} />, badge: '3' },
  { id: 'settings',   label: 'Settings',   icon: <Settings        size={16} strokeWidth={1.8} /> },
];

// Shown at the bottom of the sidebar, above the network card.
const BOTTOM_ITEMS: { id: Page; label: string; icon: React.ReactNode; badge?: string }[] = [
  { id: 'docs', label: 'Docs', icon: <BookOpen size={16} strokeWidth={1.8} /> },
];

const MODE_OPTIONS: { id: VaultMode; label: string; sub: string; icon: typeof Shield; color: string }[] = [
  { id: 'conventional', label: 'Conventional', sub: 'Passive & Aggressive',   icon: Shield, color: '#acc6e9' },
  { id: 'shariah',      label: 'Shariah',       sub: 'Screened strategies only',  icon: Moon,   color: '#8dd89f' },
  { id: 'both',         label: 'Both',          sub: 'All three tiers',        icon: Globe,  color: '#c9b8f5' },
];

interface SidebarProps {
  current: Page;
  onNavigate: (p: Page) => void;
  agentRunning?: boolean;
  vaultMode: VaultMode;
  onVaultModeChange: (m: VaultMode) => void;
}

export function Sidebar({ current, onNavigate, agentRunning, vaultMode, onVaultModeChange }: SidebarProps) {
  const [mobileOpen, setMobileOpen]   = useState(false);
  const [modeOpen,   setModeOpen]     = useState(false);

  const activeMeta = MODE_OPTIONS.find(m => m.id === vaultMode) ?? MODE_OPTIONS[2];

  const renderNavItem = (item: (typeof NAV_ITEMS)[number]) => {
          const active = current === item.id;
          return (
            <button
              key={item.id}
              onClick={() => { onNavigate(item.id); setMobileOpen(false); setModeOpen(false); }}
              className="w-full flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm font-medium transition-all"
              style={{
                background: active ? 'rgba(172,198,233,0.12)' : 'transparent',
                color:      active ? 'var(--accent)' : 'var(--muted)',
                border:     active ? '1px solid rgba(172,198,233,0.18)' : '1px solid transparent',
              }}
            >
              <span style={{ color: active ? 'var(--accent)' : 'var(--subtle)', flexShrink: 0 }}>{item.icon}</span>
              <span className="flex-1 text-left">{item.label}</span>
              {item.badge && (
                <span
                  className="text-xs px-1.5 py-0.5 rounded-full tabular-nums"
                  style={{ background: 'rgba(240,180,41,0.15)', color: '#f0b429', fontSize: '0.6rem', fontWeight: 600 }}
                >
                  {item.badge}
                </span>
              )}
              {active && <ChevronRight size={12} style={{ color: 'var(--accent)', flexShrink: 0 }} />}
            </button>
          );
  };

  const content = (
    <div className="flex flex-col h-full" style={{ background: '#0a1628', borderRight: '1px solid rgba(255,255,255,0.07)' }}>
      {/* Logo */}
      <button
        className="flex items-center gap-2.5 px-5 pt-6 pb-5 text-left w-full"
        onClick={() => { onNavigate('landing'); setMobileOpen(false); }}
      >
        <div
          className="w-8 h-8 rounded-lg flex items-center justify-center flex-shrink-0"
          style={{ background: 'linear-gradient(135deg, #acc6e9 0%, #5e9bd4 100%)' }}
        >
          <Zap size={14} strokeWidth={2.5} style={{ color: '#0a1628' }} />
        </div>
        <div>
          <p className="text-sm font-semibold display leading-none" style={{ color: 'var(--ink-2)', letterSpacing: '-0.02em' }}>
            DeFiVault
          </p>
          <p className="text-xs mt-0.5" style={{ color: 'var(--subtle)' }}>AI Capital Allocator</p>
        </div>
      </button>

      {/* Agent status pill */}
      <div className="px-4 mb-3">
        <div
          className="flex items-center gap-2 rounded-lg px-3 py-2"
          style={{
            background: agentRunning ? 'rgba(141,216,159,0.08)' : 'rgba(255,255,255,0.04)',
            border: `1px solid ${agentRunning ? 'rgba(141,216,159,0.2)' : 'rgba(255,255,255,0.08)'}`,
          }}
        >
          <span
            className="w-1.5 h-1.5 rounded-full flex-shrink-0"
            style={{
              background: agentRunning ? '#8dd89f' : 'var(--subtle)',
              boxShadow: agentRunning ? '0 0 6px #8dd89f' : 'none',
            }}
          />
          <span className="text-xs font-medium" style={{ color: agentRunning ? '#8dd89f' : 'var(--subtle)' }}>
            {agentRunning ? 'Agent active' : 'Agent offline'}
          </span>
        </div>
      </div>

      {/* ── Vault mode picker ── */}
      <div className="px-4 mb-5">
        <p className="text-xs mb-1.5 px-1" style={{ color: 'var(--subtle)', fontSize: '0.6rem', letterSpacing: '0.08em', textTransform: 'uppercase' }}>
          Community
        </p>
        <div className="relative">
          <button
            onClick={() => setModeOpen(v => !v)}
            className="w-full flex items-center gap-2 rounded-lg px-3 py-2 text-left transition-all"
            style={{
              background: 'rgba(255,255,255,0.05)',
              border: `1px solid ${modeOpen ? activeMeta.color + '44' : 'rgba(255,255,255,0.1)'}`,
            }}
          >
            <activeMeta.icon size={13} style={{ color: activeMeta.color, flexShrink: 0 }} />
            <div className="flex-1 min-w-0">
              <p className="text-xs font-semibold leading-none" style={{ color: activeMeta.color }}>{activeMeta.label}</p>
              <p className="text-xs mt-0.5 truncate" style={{ color: 'var(--subtle)', fontSize: '0.6rem' }}>{activeMeta.sub}</p>
            </div>
            <ChevronRight
              size={12}
              style={{
                color: 'var(--subtle)',
                flexShrink: 0,
                transform: modeOpen ? 'rotate(90deg)' : 'rotate(0deg)',
                transition: 'transform 0.15s',
              }}
            />
          </button>

          {modeOpen && (
            <div
              className="absolute left-0 right-0 top-full mt-1 rounded-lg overflow-hidden z-10"
              style={{ background: '#0e1f3a', border: '1px solid rgba(255,255,255,0.12)', boxShadow: '0 8px 32px rgba(0,0,0,0.4)' }}
            >
              {MODE_OPTIONS.map(opt => {
                const active = vaultMode === opt.id;
                return (
                  <button
                    key={opt.id}
                    onClick={() => { onVaultModeChange(opt.id); setModeOpen(false); }}
                    className="w-full flex items-center gap-3 px-3 py-2.5 text-left transition-all"
                    style={{
                      background: active ? `${opt.color}12` : 'transparent',
                      borderLeft: active ? `2px solid ${opt.color}` : '2px solid transparent',
                    }}
                  >
                    <opt.icon size={13} style={{ color: active ? opt.color : 'var(--subtle)', flexShrink: 0 }} />
                    <div>
                      <p className="text-xs font-medium" style={{ color: active ? opt.color : 'var(--ink-2)' }}>{opt.label}</p>
                      <p className="text-xs" style={{ color: 'var(--subtle)', fontSize: '0.6rem' }}>{opt.sub}</p>
                    </div>
                    {active && (
                      <span className="ml-auto w-1.5 h-1.5 rounded-full flex-shrink-0" style={{ background: opt.color }} />
                    )}
                  </button>
                );
              })}
            </div>
          )}
        </div>
      </div>

      {/* Nav */}
      <nav className="flex-1 px-3 space-y-0.5">
        <p className="text-xs px-2 mb-2" style={{ color: 'var(--subtle)', letterSpacing: '0.08em', fontSize: '0.6rem', textTransform: 'uppercase' }}>
          Main
        </p>
        {NAV_ITEMS.map(renderNavItem)}
      </nav>

      {/* Bottom: docs link, then chain info */}
      <div className="px-3 pt-3" style={{ borderTop: '1px solid rgba(255,255,255,0.06)' }}>
        {BOTTOM_ITEMS.map(renderNavItem)}
      </div>
      <div className="px-4 pb-5 pt-2">
        <div
          className="rounded-lg px-3 py-2.5 flex items-center gap-3"
          style={{ background: 'rgba(255,255,255,0.04)', border: '1px solid rgba(255,255,255,0.07)' }}
        >
          <div className="w-6 h-6 rounded-full flex items-center justify-center flex-shrink-0" style={{ background: 'rgba(172,198,233,0.18)' }}>
            <span className="text-xs font-bold" style={{ color: 'var(--accent)' }}>DV</span>
          </div>
          <div className="flex-1 min-w-0">
            <p className="text-xs font-medium truncate" style={{ color: 'var(--ink-2)' }}>defivault.finance</p>
            <p className="text-xs truncate" style={{ color: 'var(--subtle)' }}>{ARC_NETWORK_NAME}</p>
          </div>
        </div>
      </div>
    </div>
  );

  return (
    <>
      {/* Mobile toggle */}
      <button
        className="lg:hidden fixed top-4 left-4 z-50 w-9 h-9 flex items-center justify-center rounded-lg"
        style={{ background: 'rgba(255,255,255,0.08)', border: '1px solid var(--border)' }}
        onClick={() => setMobileOpen(v => !v)}
      >
        {mobileOpen ? <X size={16} style={{ color: 'var(--ink-2)' }} /> : <Menu size={16} style={{ color: 'var(--ink-2)' }} />}
      </button>

      {/* Desktop sidebar */}
      <aside className="hidden lg:flex flex-col w-60 h-screen sticky top-0 flex-shrink-0">
        {content}
      </aside>

      {/* Mobile drawer */}
      {mobileOpen && (
        <>
          <div
            className="lg:hidden fixed inset-0 z-40"
            style={{ background: 'rgba(0,0,0,0.5)' }}
            onClick={() => setMobileOpen(false)}
          />
          <aside className="lg:hidden fixed left-0 top-0 h-full w-60 z-50">
            {content}
          </aside>
        </>
      )}
    </>
  );
}
