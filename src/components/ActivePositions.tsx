import { useReadContract } from 'wagmi';
import { formatUnits } from 'viem';
import { TRACKER_ADDRESS, TRACKER_ABI, STRATEGY_NAMES, STRATEGY_COLORS } from '../contracts';
import { ARC_CHAIN_ID } from '../chain';

interface Position {
  id: bigint;
  strategy: number;
  target: `0x${string}`;
  amountDeployed: bigint;
  entryTimestamp: bigint;
  exitTimestamp: bigint;
  pnl: bigint;
  pnlNet: bigint;
  status: number;
  txHash: `0x${string}`;
}

const STATUS_LABEL = ['Open', 'Closing', 'Closed'];

function elapsed(ts: bigint): string {
  const secs = Math.floor(Date.now() / 1000) - Number(ts);
  if (secs < 60) return `${secs}s`;
  if (secs < 3600) return `${Math.floor(secs / 60)}m`;
  return `${Math.floor(secs / 3600)}h`;
}

function shortAddr(addr: string): string {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

export function ActivePositions() {
  const isDeployed = TRACKER_ADDRESS.length > 2;

  const { data: positions } = useReadContract({
    address: TRACKER_ADDRESS,
    abi: TRACKER_ABI,
    functionName: 'getActivePositions',
    chainId: ARC_CHAIN_ID,
    query: { enabled: isDeployed, refetchInterval: 15_000 },
  });

  if (!isDeployed) {
    return (
      <section>
        <h2 className="text-xs uppercase tracking-wider mb-3" style={{ color: 'var(--subtle)', letterSpacing: '0.08em' }}>
          Active Positions
        </h2>
        <div className="rounded-xl p-8 text-center" style={{ background: 'var(--surface)', border: '1px solid var(--border)' }}>
          <p className="text-sm" style={{ color: 'var(--subtle)' }}>Deploy contracts to track positions</p>
        </div>
      </section>
    );
  }

  const list = (positions as Position[] | undefined) ?? [];

  return (
    <section>
      <div className="flex items-center justify-between mb-3">
        <h2 className="text-xs uppercase tracking-wider" style={{ color: 'var(--subtle)', letterSpacing: '0.08em' }}>
          Active Positions
        </h2>
        <span className="text-xs px-2 py-0.5 rounded-full" style={{ background: 'var(--surface-muted)', color: 'var(--muted)' }}>
          {list.length} open
        </span>
      </div>

      {list.length === 0 ? (
        <div className="rounded-xl p-8 text-center" style={{ background: 'var(--surface)', border: '1px solid var(--border)' }}>
          <p className="text-sm" style={{ color: 'var(--subtle)' }}>No active positions — the agent is scanning for opportunities</p>
        </div>
      ) : (
        <div className="rounded-xl overflow-hidden" style={{ border: '1px solid var(--border)' }}>
          <table className="w-full text-sm">
            <thead>
              <tr style={{ borderBottom: '1px solid var(--border)', background: 'var(--surface-muted)' }}>
                {['ID', 'Strategy', 'Target', 'Deployed', 'Age', 'Status'].map(h => (
                  <th key={h} className="text-left px-4 py-2 text-xs uppercase" style={{ color: 'var(--subtle)', letterSpacing: '0.06em' }}>
                    {h}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {list.map((pos) => (
                <tr key={pos.id.toString()} style={{ borderBottom: '1px solid var(--border)' }}>
                  <td className="px-4 py-3 mono text-xs" style={{ color: 'var(--muted)' }}>
                    #{pos.id.toString()}
                  </td>
                  <td className="px-4 py-3">
                    <span className="flex items-center gap-1.5">
                      <span className="w-1.5 h-1.5 rounded-full" style={{ background: STRATEGY_COLORS[pos.strategy] }} />
                      <span className="text-xs" style={{ color: 'var(--ink-2)' }}>{STRATEGY_NAMES[pos.strategy]}</span>
                    </span>
                  </td>
                  <td className="px-4 py-3 mono text-xs" style={{ color: 'var(--muted)' }}>
                    {shortAddr(pos.target)}
                  </td>
                  <td className="px-4 py-3 tabular-nums text-xs" style={{ color: 'var(--ink-2)' }}>
                    ${parseFloat(formatUnits(pos.amountDeployed, 6)).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
                  </td>
                  <td className="px-4 py-3 text-xs" style={{ color: 'var(--muted)' }}>
                    {elapsed(pos.entryTimestamp)}
                  </td>
                  <td className="px-4 py-3">
                    <span
                      className="text-xs px-2 py-0.5 rounded-full"
                      style={{
                        background: pos.status === 0 ? 'rgba(141,216,159,0.12)' : pos.status === 1 ? 'rgba(240,180,41,0.12)' : 'rgba(255,255,255,0.06)',
                        color: pos.status === 0 ? '#8dd89f' : pos.status === 1 ? '#f0b429' : 'var(--muted)',
                      }}
                    >
                      {STATUS_LABEL[pos.status]}
                    </span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}
