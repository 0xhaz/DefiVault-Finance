import type { ReactNode } from 'react';
import { useAccount, useReadContract, usePublicClient } from 'wagmi';
import { useQuery } from '@tanstack/react-query';
import { ConnectKitButton } from 'connectkit';
import { erc20Abi, formatUnits, parseAbiItem } from 'viem';
import { Briefcase, Wallet, ArrowDownToLine, TrendingUp, ExternalLink } from 'lucide-react';
import { ActivePositions } from '../components/ActivePositions';
import { VAULT_ADDRESS, VAULT_ABI, TRACKER_ADDRESS } from '../contracts';
import { ARC_CHAIN_ID, IS_MAINNET, txUrl } from '../chain';

const USDC_ADDRESS = '0x3600000000000000000000000000000000000000' as `0x${string}`;
const SHARE_DECIMALS = 12;

const DEPOSIT_EVENT = parseAbiItem('event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares)');
const WITHDRAW_EVENT = parseAbiItem('event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares)');

// The Arc RPC caps eth_getLogs at a few thousand blocks, so history is read in chunks from the vault's deploy block.
const LOG_CHUNK = 5_000n;
const MAX_CHUNKS = 400n;
const DEPLOY_BLOCK = import.meta.env.VITE_VAULT_DEPLOY_BLOCK ? BigInt(import.meta.env.VITE_VAULT_DEPLOY_BLOCK) : null;

interface HistoryRow {
  kind: 'Deposit' | 'Redeem';
  assets: bigint;
  shares: bigint;
  block: bigint;
  tx: `0x${string}`;
  time?: number;
}

function usdc(raw: bigint | undefined): string {
  if (raw === undefined) return '…';
  return Number(formatUnits(raw, 6)).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 6 });
}

function signedUsdc(raw: bigint): string {
  const sign = raw > 0n ? '+' : raw < 0n ? '−' : '';
  return `${sign}${usdc(raw < 0n ? -raw : raw)}`;
}

function useVaultHistory(owner: `0x${string}` | undefined) {
  const client = usePublicClient({ chainId: ARC_CHAIN_ID });
  return useQuery({
    queryKey: ['vault-history', VAULT_ADDRESS, owner],
    enabled: !!client && !!owner && VAULT_ADDRESS.length > 2,
    refetchInterval: 30_000,
    queryFn: async (): Promise<HistoryRow[]> => {
      if (!client || !owner) return [];
      const latest = await client.getBlockNumber();
      let from = DEPLOY_BLOCK ?? (latest > LOG_CHUNK * 20n ? latest - LOG_CHUNK * 20n : 0n);
      if (latest - from > LOG_CHUNK * MAX_CHUNKS) from = latest - LOG_CHUNK * MAX_CHUNKS;

      const ranges: [bigint, bigint][] = [];
      for (let start = from; start <= latest; start += LOG_CHUNK) {
        const end = start + LOG_CHUNK - 1n > latest ? latest : start + LOG_CHUNK - 1n;
        ranges.push([start, end]);
      }

      const rows: HistoryRow[] = [];
      // A few chunks at a time to stay polite with the public RPC.
      for (let i = 0; i < ranges.length; i += 6) {
        const batch = ranges.slice(i, i + 6);
        const results = await Promise.all(batch.flatMap(([fromBlock, toBlock]) => [
          client.getLogs({ address: VAULT_ADDRESS, event: DEPOSIT_EVENT, args: { owner }, fromBlock, toBlock }),
          client.getLogs({ address: VAULT_ADDRESS, event: WITHDRAW_EVENT, args: { owner }, fromBlock, toBlock }),
        ]));
        for (const logs of results) {
          for (const log of logs) {
            rows.push({
              kind: log.eventName === 'Deposit' ? 'Deposit' : 'Redeem',
              assets: log.args.assets ?? 0n,
              shares: log.args.shares ?? 0n,
              block: log.blockNumber ?? 0n,
              tx: log.transactionHash as `0x${string}`,
            });
          }
        }
      }

      rows.sort((a, b) => (a.block === b.block ? 0 : a.block > b.block ? -1 : 1));
      const blocks = [...new Set(rows.map(r => r.block))].slice(0, 50);
      const times = new Map<bigint, number>();
      await Promise.all(blocks.map(async b => {
        const blk = await client.getBlock({ blockNumber: b });
        times.set(b, Number(blk.timestamp));
      }));
      return rows.map(r => ({ ...r, time: times.get(r.block) }));
    },
  });
}

function StatCard({ label, value, sub, icon, color }: { label: string; value: string; sub: string; icon: ReactNode; color: string }) {
  return (
    <div className="rounded-xl px-4 py-4" style={{ background: 'var(--surface)', border: '1px solid var(--border)' }}>
      <div className="w-7 h-7 rounded-lg flex items-center justify-center mb-3" style={{ background: 'rgba(172,198,233,0.1)', color }}>
        {icon}
      </div>
      <p className="display text-xl font-bold tabular-nums" style={{ color: 'var(--ink-2)', letterSpacing: '-0.02em' }}>{value}</p>
      <p className="text-xs font-medium mt-0.5" style={{ color: 'var(--muted)' }}>{label}</p>
      <p className="text-xs mt-0.5" style={{ color: 'var(--subtle)' }}>{sub}</p>
    </div>
  );
}

export function PortfolioPage() {
  const { address, isConnected } = useAccount();
  const isDeployed = VAULT_ADDRESS.length > 2;
  const read = { chainId: ARC_CHAIN_ID } as const;

  const { data: shares } = useReadContract({
    ...read, address: VAULT_ADDRESS, abi: VAULT_ABI, functionName: 'balanceOf', args: [address!],
    query: { enabled: !!address && isDeployed, refetchInterval: 15_000 },
  });
  const { data: value } = useReadContract({
    ...read, address: VAULT_ADDRESS, abi: VAULT_ABI, functionName: 'convertToAssets', args: [shares ?? 0n],
    query: { enabled: shares !== undefined && isDeployed, refetchInterval: 15_000 },
  });
  const { data: walletUsdc } = useReadContract({
    ...read, address: USDC_ADDRESS, abi: erc20Abi, functionName: 'balanceOf', args: [address!],
    query: { enabled: !!address, refetchInterval: 15_000 },
  });
  const { data: totalAssets } = useReadContract({
    ...read, address: VAULT_ADDRESS, abi: VAULT_ABI, functionName: 'totalAssets',
    query: { enabled: isDeployed, refetchInterval: 15_000 },
  });
  const { data: totalDeployed } = useReadContract({
    ...read, address: VAULT_ADDRESS, abi: VAULT_ABI, functionName: 'totalDeployed',
    query: { enabled: isDeployed, refetchInterval: 15_000 },
  });
  const { data: totalSupply } = useReadContract({
    ...read, address: VAULT_ADDRESS, abi: VAULT_ABI, functionName: 'totalSupply',
    query: { enabled: isDeployed, refetchInterval: 15_000 },
  });

  const history = useVaultHistory(address);
  const rows = history.data ?? [];
  const netDeposited = rows.reduce((acc, r) => (r.kind === 'Deposit' ? acc + r.assets : acc - r.assets), 0n);
  const pnl = value !== undefined && history.isSuccess ? value - netDeposited : undefined;

  const ownershipBps = shares && totalSupply ? Number((shares * 10_000n) / totalSupply) : 0;
  const yourDeployed = totalDeployed !== undefined && totalSupply && shares ? (totalDeployed * shares) / totalSupply : 0n;
  const idle = totalAssets !== undefined && totalDeployed !== undefined ? totalAssets - totalDeployed : undefined;

  return (
    <div className="space-y-6">
      <div>
        <h1 className="display text-2xl font-bold" style={{ color: 'var(--ink)', letterSpacing: '-0.03em' }}>Portfolio</h1>
        <p className="text-sm mt-1" style={{ color: 'var(--subtle)' }}>Your vault position, profit and loss, and history</p>
      </div>

      {!isConnected ? (
        <div className="rounded-xl p-8 text-center" style={{ background: 'var(--surface)', border: '1px solid var(--border)' }}>
          <p className="text-sm mb-1" style={{ color: 'var(--ink-2)' }}>Connect your wallet to see your position</p>
          <p className="text-xs mb-4" style={{ color: 'var(--subtle)' }}>Balances and history are read directly from the vault contract</p>
          <div className="flex justify-center"><ConnectKitButton /></div>
        </div>
      ) : (
        <>
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-4">
            <StatCard label="Position value" value={`$${usdc(value)}`}
              sub={`${shares !== undefined ? Number(formatUnits(shares, SHARE_DECIMALS)).toLocaleString('en-US', { maximumFractionDigits: 4 }) : '…'} shares`}
              icon={<Briefcase size={15} strokeWidth={1.8} />} color="#acc6e9" />
            <StatCard label="Net deposited" value={history.isSuccess ? `$${usdc(netDeposited)}` : '…'}
              sub="Deposits minus redemptions" icon={<ArrowDownToLine size={15} strokeWidth={1.8} />} color="#f0b429" />
            <StatCard label="Profit / loss" value={pnl !== undefined ? `$${signedUsdc(pnl)}` : '…'}
              sub="Value minus net deposited" icon={<TrendingUp size={15} strokeWidth={1.8} />} color={pnl !== undefined && pnl < 0n ? '#e86d7a' : '#8dd89f'} />
            <StatCard label="Wallet USDC" value={`$${usdc(walletUsdc)}`}
              sub="Available to deposit" icon={<Wallet size={15} strokeWidth={1.8} />} color="#acc6e9" />
          </div>

          <section>
            <h2 className="text-xs uppercase mb-4" style={{ color: 'var(--subtle)', letterSpacing: '0.08em' }}>Where your USDC is</h2>
            <div className="rounded-xl p-5 space-y-3 text-sm" style={{ background: 'var(--surface)', border: '1px solid var(--border)' }}>
              <div className="flex justify-between"><span style={{ color: 'var(--muted)' }}>Your share of the vault</span>
                <span className="tabular-nums" style={{ color: 'var(--ink-2)' }}>{(ownershipBps / 100).toFixed(2)}%</span></div>
              <div className="flex justify-between"><span style={{ color: 'var(--muted)' }}>Vault total assets</span>
                <span className="tabular-nums" style={{ color: 'var(--ink-2)' }}>${usdc(totalAssets)}</span></div>
              <div className="flex justify-between"><span style={{ color: 'var(--muted)' }}>Idle in the vault (redeemable now)</span>
                <span className="tabular-nums" style={{ color: 'var(--ink-2)' }}>${usdc(idle)}</span></div>
              <div className="flex justify-between"><span style={{ color: 'var(--muted)' }}>Deployed to strategies</span>
                <span className="tabular-nums" style={{ color: 'var(--ink-2)' }}>${usdc(totalDeployed)} (your share ${usdc(yourDeployed)})</span></div>
              {totalDeployed === 0n && (
                <p className="text-xs pt-2" style={{ color: 'var(--subtle)', borderTop: '1px solid var(--border)' }}>
                  {IS_MAINNET
                    ? 'No capital is in a strategy yet. On mainnet a strategy can receive funds only after the Shariah board screens its adapter through a 30-day timelock, so deposits wait in the vault and stay redeemable.'
                    : 'No capital is in a strategy yet. It moves when someone triggers execution and the top score clears the tier minimum.'}
                </p>
              )}
            </div>
          </section>

          {TRACKER_ADDRESS.length > 2 && <ActivePositions />}

          <section>
            <h2 className="text-xs uppercase mb-4" style={{ color: 'var(--subtle)', letterSpacing: '0.08em' }}>History</h2>
            <div className="rounded-xl overflow-hidden" style={{ background: 'var(--surface)', border: '1px solid var(--border)' }}>
              {history.isLoading ? (
                <p className="text-xs px-5 py-6" style={{ color: 'var(--subtle)' }}>Reading your deposits and redemptions from the vault…</p>
              ) : history.isError ? (
                <p className="text-xs px-5 py-6" style={{ color: 'var(--danger)' }}>Could not read history from the RPC. It will retry shortly.</p>
              ) : rows.length === 0 ? (
                <p className="text-xs px-5 py-6" style={{ color: 'var(--subtle)' }}>No deposits or redemptions from this wallet yet.</p>
              ) : (
                <div className="overflow-x-auto">
                  <table className="w-full text-sm">
                    <thead>
                      <tr style={{ background: 'var(--surface-muted)' }}>
                        {['Date', 'Action', 'USDC', 'Shares', 'Transaction'].map(h => (
                          <th key={h} className="text-left px-4 py-2 text-xs font-semibold" style={{ color: 'var(--muted)' }}>{h}</th>
                        ))}
                      </tr>
                    </thead>
                    <tbody>
                      {rows.map(r => (
                        <tr key={`${r.tx}-${r.kind}`} style={{ borderTop: '1px solid var(--border)' }}>
                          <td className="px-4 py-2 whitespace-nowrap text-xs" style={{ color: 'var(--subtle)' }}>
                            {r.time ? new Date(r.time * 1000).toLocaleString() : `Block ${r.block}`}
                          </td>
                          <td className="px-4 py-2" style={{ color: r.kind === 'Deposit' ? '#8dd89f' : '#f0b429' }}>{r.kind}</td>
                          <td className="px-4 py-2 tabular-nums" style={{ color: 'var(--ink-2)' }}>{usdc(r.assets)}</td>
                          <td className="px-4 py-2 tabular-nums" style={{ color: 'var(--ink-2)' }}>
                            {Number(formatUnits(r.shares, SHARE_DECIMALS)).toLocaleString('en-US', { maximumFractionDigits: 4 })}
                          </td>
                          <td className="px-4 py-2">
                            <a href={txUrl(r.tx)} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1 mono text-xs"
                              style={{ color: 'var(--accent)' }}>
                              {r.tx.slice(0, 10)}…<ExternalLink size={11} />
                            </a>
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </div>
          </section>
        </>
      )}
    </div>
  );
}
