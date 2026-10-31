import { useReadContract } from 'wagmi';
import { formatUnits } from 'viem';
import { TrendingUp, Lock, Layers, BarChart2 } from 'lucide-react';
import { VAULT_ADDRESS, VAULT_ABI, TRACKER_ADDRESS, TRACKER_ABI } from '../contracts';
import { ARC_CHAIN_ID } from '../chain';

interface StatCardProps {
  label: string;
  value: string;
  sub?: string;
  icon: React.ReactNode;
  highlight?: boolean;
  positive?: boolean;
  negative?: boolean;
}

function StatCard({ label, icon, value, sub, highlight, positive, negative }: StatCardProps) {
  return (
    <div
      className="rounded-xl p-4 flex flex-col gap-3"
      style={{
        background: highlight ? 'rgba(172,198,233,0.08)' : 'var(--surface)',
        border: `1px solid ${highlight ? 'rgba(172,198,233,0.2)' : 'var(--border)'}`,
      }}
    >
      <div className="flex items-center justify-between">
        <span className="text-xs uppercase tracking-wider" style={{ color: 'var(--subtle)', letterSpacing: '0.08em' }}>
          {label}
        </span>
        <span style={{ color: 'var(--subtle)' }}>{icon}</span>
      </div>
      <div>
        <p
          className="display text-2xl font-semibold tabular-nums"
          style={{ color: positive ? 'var(--success)' : negative ? 'var(--danger)' : 'var(--ink)', letterSpacing: '-0.02em' }}
        >
          {value}
        </p>
        {sub && (
          <p className="text-xs mt-1" style={{ color: 'var(--subtle)' }}>
            {sub}
          </p>
        )}
      </div>
    </div>
  );
}


export function VaultStats() {
  const isDeployed = VAULT_ADDRESS.length > 2;

  const { data: totalAssets } = useReadContract({
    address: VAULT_ADDRESS,
    abi: VAULT_ABI,
    functionName: 'totalAssets',
    chainId: ARC_CHAIN_ID,
    query: { enabled: isDeployed, refetchInterval: 15_000 },
  });

  const { data: totalDeployed } = useReadContract({
    address: VAULT_ADDRESS,
    abi: VAULT_ABI,
    functionName: 'totalDeployed',
    chainId: ARC_CHAIN_ID,
    query: { enabled: isDeployed, refetchInterval: 15_000 },
  });

  const { data: maxBps } = useReadContract({
    address: VAULT_ADDRESS,
    abi: VAULT_ABI,
    functionName: 'maxAllocationBps',
    chainId: ARC_CHAIN_ID,
    query: { enabled: isDeployed, refetchInterval: 60_000 },
  });

  const { data: totalPnl } = useReadContract({
    address: TRACKER_ADDRESS,
    abi: TRACKER_ABI,
    functionName: 'getTotalPnl',
    chainId: ARC_CHAIN_ID,
    query: { enabled: TRACKER_ADDRESS.length > 2, refetchInterval: 15_000 },
  });

  function fmt(raw: bigint | undefined): string {
    if (raw === undefined) return '—';
    return `$${parseFloat(formatUnits(raw, 6)).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
  }

  function fmtPnl(raw: bigint | undefined): { text: string; positive: boolean; negative: boolean } {
    if (raw === undefined) return { text: '—', positive: false, negative: false };
    const val = parseFloat(formatUnits(raw < 0n ? -raw : raw, 6));
    const sign = raw < 0n ? '-' : raw > 0n ? '+' : '';
    return {
      text: `${sign}$${val.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`,
      positive: raw > 0n,
      negative: raw < 0n,
    };
  }

  const utilizationPct =
    totalAssets !== undefined && totalAssets > 0n && totalDeployed !== undefined
      ? `${((Number(totalDeployed) / Number(totalAssets)) * 100).toFixed(1)}% deployed`
      : undefined;

  const pnl = fmtPnl(totalPnl);

  return (
    <div className="grid grid-cols-2 lg:grid-cols-4 gap-3">
      <StatCard
        label="Total Assets"
        value={fmt(totalAssets)}
        sub={utilizationPct}
        icon={<Layers size={14} />}
        highlight
      />
      <StatCard
        label="Deployed Capital"
        value={fmt(totalDeployed)}
        sub={maxBps !== undefined ? `Max ${Number(maxBps) / 100}% cap` : undefined}
        icon={<Lock size={14} />}
      />
      <StatCard
        label="Realised PnL"
        value={pnl.text}
        sub="All closed positions"
        icon={<TrendingUp size={14} />}
        positive={pnl.positive}
        negative={pnl.negative}
      />
      <StatCard
        label="Max Allocation"
        value={maxBps !== undefined ? `${Number(maxBps) / 100}%` : '—'}
        sub="Safety cap"
        icon={<BarChart2 size={14} />}
      />
    </div>
  );
}
