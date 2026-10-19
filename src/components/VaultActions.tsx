import { useState } from 'react';
import { useAccount, useReadContract, useWriteContract, useWaitForTransactionReceipt } from 'wagmi';
import { erc20Abi, formatUnits, parseUnits } from 'viem';
import { toast } from 'sonner';
import { VAULT_ADDRESS, VAULT_ABI, EXECUTOR_ADDRESS, EXECUTOR_ABI } from '../contracts';
import { getUsdc, buildTxExplorerUrl } from '../onchain-facts';

const ARC_CHAIN_ID = 5042002;
const usdcFact = getUsdc(ARC_CHAIN_ID);
const USDC_ADDRESS = (usdcFact?.address ?? '0x3600000000000000000000000000000000000000') as `0x${string}`;

type Tab = 'deposit' | 'withdraw' | 'execute';

export function VaultActions() {
  const { address, isConnected, chainId } = useAccount();
  const [tab, setTab] = useState<Tab>('deposit');
  const [amount, setAmount] = useState('');

  const isDeployed = VAULT_ADDRESS.length > 2;
  const executorDeployed = EXECUTOR_ADDRESS.length > 2;
  const isWrongChain = isConnected && chainId !== ARC_CHAIN_ID;

  const { data: usdcBalance } = useReadContract({
    address: USDC_ADDRESS,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: [address!],
    chainId: ARC_CHAIN_ID,
    query: { enabled: !!address, refetchInterval: 10_000 },
  });

  const { data: vaultShares } = useReadContract({
    address: VAULT_ADDRESS,
    abi: VAULT_ABI,
    functionName: 'balanceOf',
    args: [address!],
    chainId: ARC_CHAIN_ID,
    query: { enabled: !!address && isDeployed, refetchInterval: 10_000 },
  });

  const { data: sharesAsAssets } = useReadContract({
    address: VAULT_ADDRESS,
    abi: VAULT_ABI,
    functionName: 'convertToAssets',
    args: [vaultShares ?? 0n],
    chainId: ARC_CHAIN_ID,
    query: { enabled: !!vaultShares && isDeployed, refetchInterval: 15_000 },
  });

  const { data: allowance } = useReadContract({
    address: USDC_ADDRESS,
    abi: erc20Abi,
    functionName: 'allowance',
    args: [address!, VAULT_ADDRESS],
    chainId: ARC_CHAIN_ID,
    query: { enabled: !!address && isDeployed, refetchInterval: 5_000 },
  });

  const { writeContract, data: txHash, isPending, reset } = useWriteContract();
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash: txHash });

  function fmtBalance(raw: bigint | undefined): string {
    if (!raw) return '0.00';
    return parseFloat(formatUnits(raw, 6)).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  }

  function parsedAmount(): bigint {
    try {
      return parseUnits(amount || '0', 6);
    } catch {
      return 0n;
    }
  }

  const parsed = parsedAmount();
  const needsApproval = tab === 'deposit' && (allowance ?? 0n) < parsed && parsed > 0n;

  function handleAction() {
    if (!address) { toast.error('Connect your wallet first'); return; }
    if (isWrongChain) { toast.error('Switch to Arc Testnet'); return; }
    if (!isDeployed) { toast.error('Contracts not yet deployed'); return; }

    reset();

    try {
      if (tab === 'deposit') {
        if (needsApproval) {
          writeContract({
            address: USDC_ADDRESS, abi: erc20Abi, functionName: 'approve',
            args: [VAULT_ADDRESS, parsed], chainId: ARC_CHAIN_ID,
          });
          toast.info('Approve USDC spend first, then deposit');
          return;
        }
        writeContract({
          address: VAULT_ADDRESS, abi: VAULT_ABI, functionName: 'deposit',
          args: [parsed, address], chainId: ARC_CHAIN_ID,
        });
      } else if (tab === 'withdraw') {
        const shares = vaultShares ?? 0n;
        const sharesToRedeem = shares; // redeem all for simplicity
        writeContract({
          address: VAULT_ADDRESS, abi: VAULT_ABI, functionName: 'redeem',
          args: [sharesToRedeem, address, address], chainId: ARC_CHAIN_ID,
        });
      } else if (tab === 'execute') {
        if (!executorDeployed) { toast.error('Executor not deployed'); return; }
        writeContract({
          address: EXECUTOR_ADDRESS, abi: EXECUTOR_ABI, functionName: 'executeWinner',
          chainId: ARC_CHAIN_ID,
        });
      }
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Transaction failed');
    }
  }

  if (isSuccess && txHash) {
    toast.success('Transaction confirmed', {
      action: { label: 'View', onClick: () => window.open(buildTxExplorerUrl(ARC_CHAIN_ID, txHash), '_blank') },
    });
    reset();
    setAmount('');
  }

  if (!isConnected) {
    return (
      <div className="rounded-xl p-6 text-center" style={{ background: 'var(--surface)', border: '1px solid var(--border)' }}>
        <p className="text-sm mb-1" style={{ color: 'var(--ink-2)' }}>Connect your wallet to interact</p>
        <p className="text-xs" style={{ color: 'var(--subtle)' }}>Deposit USDC, redeem shares, or trigger execution</p>
      </div>
    );
  }

  const tabs: { id: Tab; label: string }[] = [
    { id: 'deposit', label: 'Deposit' },
    { id: 'withdraw', label: 'Redeem' },
    { id: 'execute', label: 'Execute' },
  ];

  const btnLabel = isPending || isConfirming
    ? isPending ? 'Confirm in wallet…' : 'Confirming…'
    : tab === 'execute' ? 'Trigger Execution'
    : tab === 'deposit' ? (needsApproval ? 'Approve USDC' : 'Deposit')
    : 'Redeem All Shares';

  return (
    <div className="rounded-xl overflow-hidden" style={{ border: '1px solid var(--border)', background: 'var(--surface)' }}>
      {/* Tabs */}
      <div className="flex" style={{ borderBottom: '1px solid var(--border)' }}>
        {tabs.map(t => (
          <button
            key={t.id}
            onClick={() => setTab(t.id)}
            className="flex-1 py-3 text-sm font-medium transition-all"
            style={{
              color: tab === t.id ? 'var(--ink)' : 'var(--subtle)',
              background: tab === t.id ? 'var(--surface-strong)' : 'transparent',
              borderBottom: tab === t.id ? '2px solid var(--accent)' : '2px solid transparent',
            }}
          >
            {t.label}
          </button>
        ))}
      </div>

      <div className="p-4 space-y-4">
        {/* Balance row */}
        <div className="flex items-center justify-between text-xs" style={{ color: 'var(--subtle)' }}>
          {tab === 'deposit' ? (
            <>
              <span>USDC balance</span>
              <span className="tabular-nums" style={{ color: 'var(--muted)' }}>{fmtBalance(usdcBalance)} USDC</span>
            </>
          ) : tab === 'withdraw' ? (
            <>
              <span>Vault shares</span>
              <span className="tabular-nums" style={{ color: 'var(--muted)' }}>
                {fmtBalance(vaultShares)} avUSDC ≈ {fmtBalance(sharesAsAssets)} USDC
              </span>
            </>
          ) : (
            <span style={{ color: 'var(--muted)' }}>Permissionless — callable by anyone when score threshold is met</span>
          )}
        </div>

        {/* Amount input (deposit only) */}
        {tab === 'deposit' && (
          <div>
            <div
              className="flex items-center gap-2 rounded-lg px-3 py-2.5"
              style={{ background: 'var(--surface-muted)', border: '1px solid var(--border)' }}
            >
              <input
                type="number"
                min="0"
                step="0.01"
                placeholder="0.00"
                value={amount}
                onChange={e => setAmount(e.target.value)}
                className="flex-1 bg-transparent outline-none tabular-nums text-lg"
                style={{ color: 'var(--ink)', fontFamily: 'Space Grotesk' }}
              />
              <div className="flex items-center gap-2">
                <button
                  onClick={() => setAmount(fmtBalance(usdcBalance).replace(/,/g, ''))}
                  className="text-xs px-2 py-1 rounded"
                  style={{ background: 'var(--surface)', color: 'var(--accent)' }}
                >
                  MAX
                </button>
                <span className="text-sm font-medium" style={{ color: 'var(--muted)' }}>USDC</span>
              </div>
            </div>
          </div>
        )}

        {tab === 'execute' && (
          <div className="rounded-lg p-3 text-xs space-y-1" style={{ background: 'var(--surface-muted)', color: 'var(--subtle)' }}>
            <p>Reads the winning strategy from ScoreAggregator and deploys capital autonomously.</p>
            <p>Requires: score ≥ min threshold, cooldown elapsed, gas price within limit.</p>
          </div>
        )}

        {isWrongChain && (
          <p className="text-xs text-center" style={{ color: 'var(--danger)' }}>Switch to Arc Testnet to continue</p>
        )}

        <button
          onClick={handleAction}
          disabled={
            isPending || isConfirming || !isDeployed ||
            (tab === 'deposit' && (parsed === 0n || amount === '')) ||
            (tab === 'withdraw' && !vaultShares)
          }
          className="w-full py-3 rounded-lg font-semibold text-sm transition-all disabled:opacity-40 disabled:cursor-not-allowed"
          style={{
            background: 'var(--accent)',
            color: 'var(--bg)',
          }}
        >
          {btnLabel}
        </button>
      </div>
    </div>
  );
}
