import { useState } from 'react';
import { Sidebar, type Page } from './components/Sidebar';
import { LandingPage } from './pages/LandingPage';
import { DashboardPage } from './pages/DashboardPage';
import { VaultPage } from './pages/VaultPage';
import { StrategiesPage } from './pages/StrategiesPage';
import { PortfolioPage } from './pages/PortfolioPage';
import { AlertsPage } from './pages/AlertsPage';
import { SettingsPage } from './pages/SettingsPage';
import { IS_MAINNET } from './chain';

/** Top-level community filter — gates which vault tiers and strategy sets are shown. */
export type VaultMode = 'conventional' | 'shariah' | 'both';

/** Tier selection — two Shariah tiers (Conservative/Dynamic) alongside Passive/Aggressive. */
export type TierSelection = 'passive' | 'aggressive' | 'shariah-conservative' | 'shariah-dynamic';

export default function App() {
  const [page, setPage]               = useState<Page>('landing');
  const [agentRunning, setAgentRunning] = useState(false);
  const [selectedTier, setSelectedTier] = useState<TierSelection>('passive');
  const [vaultMode, setVaultMode]     = useState<VaultMode>('both');

  const isLanding = page === 'landing';

  // When mode changes, ensure selected tier stays valid for the new mode
  function handleVaultModeChange(mode: VaultMode) {
    setVaultMode(mode);
    const isShariahTier = selectedTier === 'shariah-conservative' || selectedTier === 'shariah-dynamic';
    if (mode === 'shariah' && !isShariahTier) {
      setSelectedTier('shariah-conservative');
    } else if (mode === 'conventional' && isShariahTier) {
      setSelectedTier('passive');
    }
  }

  return (
    <div className="flex min-h-dvh" style={{ background: 'var(--bg-gradient)' }}>
      {!isLanding && (
        <Sidebar
          current={page}
          onNavigate={setPage}
          agentRunning={agentRunning}
          vaultMode={vaultMode}
          onVaultModeChange={handleVaultModeChange}
        />
      )}

      <div className={`flex-1 min-w-0 ${!isLanding ? 'overflow-y-auto' : ''}`}>
        {IS_MAINNET && (
          <div
            role="alert"
            className="px-4 py-2 text-xs text-center"
            style={{ background: 'rgba(245, 158, 11, 0.12)', color: 'var(--ink-2)', borderBottom: '1px solid var(--border)' }}
          >
            Arc mainnet hackathon demo. The contracts are unaudited and strategies are pending Shariah board
            screening. Use only small amounts of USDC.
          </div>
        )}
        {isLanding ? (
          <LandingPage onNavigate={setPage} />
        ) : (
          <main className="max-w-6xl mx-auto px-4 sm:px-6 py-8 lg:py-10">
            {page === 'dashboard' && (
              <DashboardPage
                selectedTier={selectedTier}
                onSelectTier={setSelectedTier}
                onAgentRunningChange={setAgentRunning}
                onNavigate={setPage}
                vaultMode={vaultMode}
              />
            )}
            {page === 'vault' && (
              <VaultPage
                selectedTier={selectedTier}
                onSelectTier={setSelectedTier}
                vaultMode={vaultMode}
              />
            )}
            {page === 'strategies' && (
              <StrategiesPage
                selectedTier={selectedTier}
                onSelectTier={setSelectedTier}
                onAgentRunningChange={setAgentRunning}
                vaultMode={vaultMode}
              />
            )}
            {page === 'portfolio' && <PortfolioPage />}
            {page === 'alerts'    && <AlertsPage />}
            {page === 'settings'  && (
              <SettingsPage
                selectedTier={selectedTier}
                onSelectTier={setSelectedTier}
                vaultMode={vaultMode}
                onVaultModeChange={handleVaultModeChange}
              />
            )}
          </main>
        )}
      </div>
    </div>
  );
}
