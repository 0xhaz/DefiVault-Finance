# ShariahVault V1 → V2 Migration Guide

## V1 stays live — indefinitely

V1 vaults are never deprecated or paused. Depositors can always redeem at NAV from V1.
Migration is voluntary. There is no governance-forced migration. No deadline.

## What changed in V2

| Feature | V1 | V2 |
|---|---|---|
| Adapter screening | `screened[addr]` mapping (owner sets directly) | `ShariahAdapterRegistry` (board-gated, 30-day timelock per entry) |
| Pronouncement on-chain | No | Yes — `pronouncementHash` must be non-zero |
| Screening expiry | No | Yes — `expiresAt` enforced at deploy time |
| Profit routing | V1: ZakatModule (deprecated) | V2: PurificationEscrow waterfall |
| Share token | `svUSDC` | `svUSDCv2` |

## Migration round-trip invariant

The migration is implemented as a V1 redeem → V2 deposit. The V2 share value must be at least 99.9% of the USDC value redeemed from V1. This invariant is verified by `FuzzShariahVaultV2.t.sol:testFuzz_migration_roundtrip`.

## Step-by-step for depositors

### Requirements
- V1 `svUSDC` shares in your wallet
- V2 vault deployed and configured (registry set, adapters screened)
- Two separate signatures required (prevents accidental migration)

### Steps

1. **Approve V1 vault to redeem your shares** (ERC-4626 `redeem`).
   Signature 1 of 2: sign the `redeem(shares, receiver, owner)` transaction.

2. **Wait for USDC to arrive** in your wallet. Confirm the balance.

3. **Approve V2 vault** to accept your USDC deposit.
   Signature 2 of 2: sign the `deposit(assets, receiver)` transaction.

4. You now hold `svUSDCv2` shares. V1 position is closed.

### Important notes
- Redeeming from V1 triggers a Wakala fee accrual on the V1 vault.
- Any pending Musharakah profit claims on V1 are the vault manager's responsibility.
- V2 resets `hurdlePrincipal` and `hurdleStartTime` on your deposit — the V1 profit
  history is not carried over.

## For vault operators

### Deploying V2

```bash
forge script contracts/script/DeployShariahV2.s.sol --broadcast --rpc-url $RPC_URL
```

This script:
1. Deploys `ShariahAdapterRegistry`
2. Deploys `ShariahVaultV2` (same asset, new registry)
3. Deploys `PurificationEscrow` + `CharityModule`
4. Sets `purificationEscrow` on the new vault
5. Records all addresses to `contracts/contract-metadata/`

### Screening adapters on the registry

Each adapter requires two board transactions separated by 30 days:

```solidity
// Propose (board member):
registry.proposeScreening(adapterAddress, keccak256(pronouncementDocument), expiresAt);

// Execute (after 30 days):
registry.executeScreening(adapterAddress);
```

### Updating an expired screening

Same as above — `proposeScreening` → 30-day wait → `executeScreening`.

## FAQ

**Can I keep my V1 position forever?**
Yes. V1 is live indefinitely. There is no deadline or forced migration.

**What happens if V2 adds a strategy V1 never had?**
V1 can only access the adapters screened in its `screened` mapping. V2 uses the registry.
They are independent.

**What if the board revokes an adapter's screening mid-term?**
V2 `deployCapital` will revert for that adapter. Existing deployed capital is NOT automatically
recalled — the vault manager must call `recallCapital` manually.

**Is V2 an upgrade to V1's storage?**
No. V2 is a new contract deployment. V1 storage is untouched.
