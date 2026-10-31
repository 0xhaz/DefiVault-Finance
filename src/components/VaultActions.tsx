import { useState } from 'react';
import { useAccount, useReadContract, useWriteContract, useWaitForTransactionReceipt, useSwitchChain, useSimulateContract } from 'wagmi';
import { ConnectKitButton } from 'connectkit';
import { BaseError, ContractFunctionRevertedError, erc20Abi, formatUnits, parseUnits } from 'viem';
import { ARC_CHAIN_ID, ARC_NETWORK_NAME, IS_MAINNET, txUrl } from '../chain';
import { toast } from 'sonner';
import { VAULT_ADDRESS, VAULT_ABI, EXECUTOR_ADDRESS, EXECUTOR_ABI } from '../contracts';

// Arc USDC (ERC-20 view, 6 decimals); same address on testnet and mainnet
const USDC_ADDRESS = '0x3600000000000000000000000000000000000000' as `0x${string}`;

function buildTxExplorerUrl(txHash: string): string {
  return txUrl(txHash);
}

type Tab = 'deposit' | 'withdraw' | 'execute';

/** Plain-language reason for an executeWinner() dry-run revert. */
function executeBlockReason(err: unknown): string {
  const reverted = err instanceof BaseError
    ? err.walk(e => e instanceof ContractFunctionRevertedError) as ContractFunctionRevertedError | null
    : null;
  const name = reverted?.data?.errorName;
  const args = (reverted?.data?.args ?? []) as readonly unknown[];
  switch (name) {
    case 'NoValidScores':
      return IS_MAINNET
        ? 'No strategy has an on-chain score yet. On mainnet every strategy stays disabled until the Shariah board screens its adapter (30-day timelock), so deposits stay idle in the vault until then.'
        : 'No enabled strategy has an on-chain score yet. The oracle must write scores before execution can run.';
    case 'ScoreTooLow':
      return `The top score (${String(args[0])}) is below this tier's minimum of ${String(args[1])}.`;
    case 'CooldownNotElapsed': {
      const mins = Math.ceil(Number(args[0] ?? 0n) / 60);
      return `The executor is cooling down. Try again in about ${mins} min.`;
    }
    case 'StrategyDisabled':
    case 'AdapterNotSet':
    case 'StrategyNotAllowedForTier':
    case 'StrategyDeprecated':
      return 'The top-scoring strategy has no screened adapter for this tier yet.';
    case 'GasPriceTooHigh':
      return "The network gas price is above the executor's limit.";
    case 'NothingToExecute':
      return 'Nothing to deploy: the vault has no idle USDC within its allocation cap.';
    case 'NonAtomicGoldExchange':
      return 'The gold strategy needs an atomic exchange adapter before it can run.';
    default:
      return name ? `The executor would revert (${name}).` : 'The executor would revert right now.';
  }
}

export function VaultActions() {
  const { address, isConnected, chainId } = useAccount();
  const [tab, setTab] = useState<Tab>('deposit');
  const [amount, setAmount] = useState('');

  const isDeployed = VAULT_ADDRESS.length > 2;
  const executorDeployed = EXECUTOR_ADDRESS.length > 2;
  const isWrongChain = isConnected && chainId !== ARC_CHAIN_ID;
  const { switchChain, isPending: isSwitching } = useSwitchChain();

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

  // Dry-run executeWinner() so the Execute tab can say why it would fail before the user pays gas.
  const execSim = useSimulateContract({
    address: EXECUTOR_ADDRESS,
    abi: EXECUTOR_ABI,
    functionName: 'executeWinner',
    account: address,
    chainId: ARC_CHAIN_ID,
    query: { enabled: tab === 'execute' && executorDeployed && !!address, refetchInterval: 20_000, retry: false },
  });
  const execBlocked = tab === 'execute' && execSim.isError;
  const execReason = execSim.isError ? executeBlockReason(execSim.error) : null;

  const { writeContract, data: txHash, isPending, reset } = useWriteContract();
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash: txHash });

  function fmtBalance(raw: bigint | undefined, decimals = 6): string {
    if (!raw) return '0.00';
    return parseFloat(formatUnits(raw, decimals)).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
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
    if (isWrongChain) { toast.error(`Switch to ${ARC_NETWORK_NAME}`); return; }
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
      action: { label: 'View', onClick: () => window.open(buildTxExplorerUrl(txHash), '_blank') },
    });
    reset();
    setAmount('');
  }

  if (!isConnected) {
    return (
      <div className="rounded-xl p-6 text-center" style={{ background: 'var(--surface)', border: '1px solid var(--border)' }}>
        <p className="text-sm mb-1" style={{ color: 'var(--ink-2)' }}>Connect your wallet to interact</p>
        <p className="text-xs mb-4" style={{ color: 'var(--subtle)' }}>Deposit USDC, redeem shares, or trigger execution</p>
        <div className="flex justify-center">
          <ConnectKitButton />
        </div>
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
                {fmtBalance(vaultShares, 12)} svUSDC ≈ {fmtBalance(sharesAsAssets)} USDC
              </span>
            </>
          ) : (
            <span style={{ color: 'var(--muted)' }}>Anyone can call this once the top score meets the threshold</span>
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
            <p>Reads the winning strategy from the score aggregator and deploys capital into it.</p>
            <p>Requires: score ≥ min threshold, cooldown elapsed, gas price within limit.</p>
          </div>
        )}

        {tab === 'execute' && executorDeployed && (
          <div
            className="rounded-lg p-3 text-xs leading-relaxed"
            style={execBlocked
              ? { background: 'rgba(245, 158, 11, 0.08)', border: '1px solid rgba(245, 158, 11, 0.25)', color: 'var(--ink-2)' }
              : { background: 'rgba(141, 216, 159, 0.08)', border: '1px solid rgba(141, 216, 159, 0.25)', color: 'var(--ink-2)' }}
          >
            {execSim.isLoading ? 'Checking whether execution can run…'
              : execBlocked ? <><span style={{ color: '#f0b429' }}>Not ready.</span> {execReason}</>
              : execSim.isSuccess ? <><span style={{ color: '#8dd89f' }}>Ready.</span> A dry run of the call succeeds.</>
              : 'Connect a wallet to check whether execution can run.'}
          </div>
        )}

        {isWrongChain && (
          <div className="space-y-2">
            <p className="text-xs text-center" style={{ color: 'var(--danger)' }}>Your wallet is on another network.</p>
            <button
              onClick={() => switchChain({ chainId: ARC_CHAIN_ID })}
              disabled={isSwitching}
              className="w-full py-2.5 rounded-lg text-sm font-medium disabled:opacity-40"
              style={{ border: '1px solid var(--accent)', color: 'var(--accent)' }}
            >
              {isSwitching ? 'Switching…' : `Switch to ${ARC_NETWORK_NAME}`}
            </button>
          </div>
        )}

        <button
          onClick={handleAction}
          disabled={
            isPending || isConfirming || !isDeployed ||
            (tab === 'deposit' && (parsed === 0n || amount === '')) ||
            (tab === 'withdraw' && !vaultShares) ||
            (tab === 'execute' && (execBlocked || execSim.isLoading))
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
