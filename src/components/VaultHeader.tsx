import { ConnectKitButton } from 'connectkit';
import { useAccount } from 'wagmi';
import { Activity } from 'lucide-react';

interface VaultHeaderProps {
  agentRunning: boolean;
}

export function VaultHeader({ agentRunning }: VaultHeaderProps) {
  const { isConnected } = useAccount();

  return (
    <header className="sticky top-0 z-20 backdrop-blur-md border-b" style={{ borderColor: 'var(--border)', background: 'rgba(13,27,47,0.85)' }}>
      <div className="max-w-7xl mx-auto px-4 sm:px-6 h-14 flex items-center justify-between gap-4">
        <div className="flex items-center gap-3">
          <div className="w-7 h-7 rounded-lg flex items-center justify-center" style={{ background: 'var(--surface-strong)' }}>
            <Activity size={14} style={{ color: 'var(--accent)' }} />
          </div>
          <span className="display font-semibold text-sm tracking-tight" style={{ color: 'var(--ink)' }}>
            DeFiVault
          </span>
          <span className="hidden sm:inline text-xs px-2 py-0.5 rounded-full" style={{ background: 'var(--surface-muted)', color: 'var(--muted)' }}>
            AI Capital Allocator
          </span>
        </div>

        <div className="flex items-center gap-3">
          {isConnected && (
            <div className="flex items-center gap-2">
              <span
                className="w-2 h-2 rounded-full"
                style={{ background: agentRunning ? 'var(--success)' : 'var(--subtle)' }}
              />
              <span className="text-xs" style={{ color: 'var(--muted)' }}>
                {agentRunning ? 'Agent active' : 'Agent idle'}
              </span>
            </div>
          )}
          <ConnectKitButton />
        </div>
      </div>
    </header>
  );
}
