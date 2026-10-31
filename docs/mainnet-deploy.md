# DeFiVault: Arc mainnet deployment runbook

> Warning: Transactions on mainnet involve real funds and, once submitted, are irreversible. Arc Studio may generate or edit code or configuration that references mainnet, but Arc Studio does not deploy to, transact on, sign for, fund, or otherwise interact with mainnet on your behalf. Any code used for mainnet must be independently reviewed, tested, validated, deployed, and operated by you outside of Arc Studio. You are solely responsible for any losses, errors, or other consequences resulting from your use of any code, configuration, or output generated or edited through Arc Studio in connection with mainnet. Before proceeding, you should first use testnet, obtain an independent professional audit, and carefully review all wallet addresses, contract addresses, chain settings, permissions, and other configuration details. Only continue to mainnet after you have completed your independent review and have determined that you want to proceed.

Chain: Arc mainnet, chain ID `5042`. Script: `contracts/script/DeployMainnet.s.sol`. Environment template: `contracts/script/mainnet.env.example`.
Companion documents: `docs/mainnet-config.md` (roles, parameters, timelocks, addresses), `docs/audit-handoff.md` (audit package), `docs/security-review.md` (findings), `docs/agents/SHARIAH_REVIEW.md` (board rulings).

## 0. Status

**Not cleared for mainnet.** This runbook and the script are preparation material. Do not run any broadcast phase until every gate in section 1 is checked by a named person. Nothing in this repository has been run against Arc mainnet. The script was exercised only on local throwaway nodes with stand-in contracts.

## 1. Gates (all must be true)

Security and quality
- [ ] Independent professional audit finished for every contract in `docs/audit-handoff.md` scope; all Critical and High findings fixed and re-reviewed; the audited commit hash is the commit you deploy.
- [ ] Deployed bytecode equals tested bytecode: same compiler (`solc 0.8.28`), same `foundry.toml` (`evm_version = "paris"`, optimizer 200 runs). If you change either, rerun the whole suite and the audit delta.
- [ ] `forge test` passes on the audited commit (see `docs/audit-handoff.md` for the expected count) and `forge build --sizes` shows `ShariahVaultV2` runtime at or below 24,576 bytes.
- [ ] Arc mainnet's contract size limit confirmed (testnet enforces 24,576; the vault is 24,317 with 259 bytes of margin). Confirm with Circle/Arc docs or the dry run in section 4.
- [ ] Open findings (`docs/security-review.md`: N-32, and the "Known gaps" list) read and explicitly accepted, in writing, by the people who own the risk.

Shariah governance
- [ ] The board has ruled on every item in `docs/agents/SHARIAH_REVIEW.md` that blocks launch. 24 of the 27 entries currently read `REVIEW` (3 are superseded). At minimum: SR-002 (charity rate), SR-003 (charity wallet), SR-004 (loss sharing), SR-012, SR-014, SR-018, SR-020, SR-025, SR-026, plus SR-005/008/009/010/013/016 before any gold adapter is enabled.
- [ ] Pronouncement hashes recorded for each adapter you intend to screen.

Operations
- [ ] `OWNER_MULTISIG` and `BOARD_MULTISIG` are deployed Safes with threshold of at least 2 of 3, signers on separate hardware wallets, a tested recovery plan, and addresses double-checked by two people.
- [ ] `CHARITY_WALLET` is the board-approved recipient (cannot be changed without a 30-day timelock).
- [ ] Deployer is a fresh address whose key lives in an encrypted Foundry keystore (`cast wallet import`), funded with enough USDC for gas (Arc gas is paid in USDC; testnet deploy used about 36M gas).
- [ ] You can run Arc Foundry (`arc-forge`, `arc-cast`) or standard Foundry per `https://docs.arc.io/arc/tutorials/install-arc-foundry.md`, and you have read `https://docs.arc.io/arc/references/evm-differences.md`.
- [ ] Monitoring and an incident runbook exist (section 11) and the on-call people hold signer keys.
- [ ] `.env`, keystores and any `*.env` files are not in git (`git check-ignore -v .env`).

External dependencies (only if enabling gold)
- [ ] Real PAXG/XAUT token addresses, a real XAU/USD oracle, and real Uniswap V3-style routers on Arc mainnet are confirmed from official sources. The testnet mocks must not be used. None are confirmed at the time of writing; the script deploys no gold adapters in `deployCore()`.

## 2. Verified Arc mainnet facts (fetched 2026-10-31; re-verify before use)

| Item | Value | Source |
|---|---|---|
| Chain ID | `5042` | `docs.arc.io` |
| RPC | `https://rpc.mainnet.arc.io` | `docs.arc.io/arc/references/rpc-endpoints.md` |
| Explorer | `https://explorer.arc.io` | `docs.arc.io` |
| USDC (ERC-20 view, 6 decimals) | `0x3600000000000000000000000000000000000000` | `docs.arc.io/arc/references/contract-addresses.md` |
| CCTP domain | `26` | `developers.circle.com/cctp/evm-smart-contracts` |
| TokenMessengerV2 | `0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d` | same |
| MessageTransmitterV2 | `0x81D40F21F12A8F0E3252Bccb954D722d4c464B64` | same |
| TokenMinterV2 | `0xfd78EE919681417d192449715b2594ab58f5D002` | same (not used by the vault directly) |
| TokenMessengerWithFees | `0x71f54F818671cD0D7ea140Da213e5C8b5C92a408` | same (not used) |

Correction to an older version of this file: `0x71f54F81...` is TokenMessengerWithFees, not TokenMinterV2. The vault needs only TokenMessengerV2 and MessageTransmitterV2.

Arc behaviours that matter here (`evm-differences.md`): native gas is USDC (18 decimals natively, 6 in the ERC-20 view); the mempool silently drops transactions with `maxFeePerGas` below 20 gwei; sends to the zero address revert; USDC blocklisting reverts transfers (a blocklisted charity wallet, treasury or depositor makes that transfer fail). Arc targets the Osaka baseline while this project compiles for `paris`; the bytecode was tested as-is on Arc Testnet.

## 3. Prepare the environment

```bash
cp contracts/script/mainnet.env.example ~/defivault-mainnet.env   # outside the repository
$EDITOR ~/defivault-mainnet.env                                     # replace every placeholder
set -a; source ~/defivault-mainnet.env; set +a
cast wallet import defivault-deployer --interactive                 # one time; key stays encrypted
```

Every value marked REPLACE in the template is rejected while it is the zero address. Fee parameters have no defaults on purpose. See `docs/mainnet-config.md` for what each one means and the script's bounds.

## 4. Phase check: read-only validation and dry run

```bash
forge script contracts/script/DeployMainnet.s.sol:DeployMainnet --sig "check()" \
  --rpc-url "$ARC_MAINNET_RPC" --account defivault-deployer --sender "$DEPLOYER_ADDRESS"
```

`check()` confirms: chain ID 5042, code at USDC and both CCTP contracts, `localDomain() == 26`, sender equals `DEPLOYER_ADDRESS`, governance addresses are set, distinct from the deployer and (by default) contracts, and parameters are inside bounds. Fix anything it reports; do not work around it.

Then simulate the core deploy without broadcasting (omit `--broadcast`) and read the printed gas estimate and cost:

```bash
forge script contracts/script/DeployMainnet.s.sol:DeployMainnet --sig "deployCore()" \
  --rpc-url "$ARC_MAINNET_RPC" --account defivault-deployer --sender "$DEPLOYER_ADDRESS" -vvv
```

A local simulation applies standard EVM rules, so it does not by itself prove Arc's node accepts the vault's size: confirm Arc mainnet's contract size limit from Arc/Circle documentation or your Circle contact before broadcasting.

## 5. Phase deployCore (broadcast)

```bash
forge script contracts/script/DeployMainnet.s.sol:DeployMainnet --sig "deployCore()" \
  --rpc-url "$ARC_MAINNET_RPC" --account defivault-deployer --sender "$DEPLOYER_ADDRESS" \
  --broadcast -vvv
```

Four linked libraries are deployed first, then registry, treasury, vault, charity module, escrow, score aggregator and executor. Wiring performed by the script: treasury fee source = vault; vault CCTP messenger and transmitter; USDC permitted; escrow and charity linked; executor is the vault manager; the **vault is left paused**; aggregator oracle set. Aggregator strategies and executor strategy configs are left disabled/unset.

1. Copy the printed addresses into `~/defivault-mainnet.env` (REGISTRY, ZAKAT, TREASURY, VAULT, CHARITY, ESCROW, AGGREGATOR, EXECUTOR) and into the table in section 10.
2. Check every contract on `https://explorer.arc.io` and verify the source there.

## 6. Optional: gold adapters (only with confirmed real addresses)

Set the `GOLD_*` variables in the template and run `deployGold()` the same way. Adapters are created with the deployer as owner, linked into the vault, and registered in the executor as **disabled**. Nothing may fund an adapter until section 7 is complete.

## 7. Screening and enabling (30 days minimum)

Using the board multisig, for each adapter: `registry.proposeScreening(adapter, pronouncementHash, expiresAt)`, wait the 30-day timelock, then `registry.executeScreening(adapter)`. Then, with the owner multisig and only after the board has approved: enable the strategy in the aggregator (`setEnabled`), enable and size the executor config (`setShariahStrategyConfig`), and write scores from `ORACLE_OPERATOR`. The agent needs `maxGasPrice` above the live Arc gas price; adjust with `setMaxGasPrice` if needed.

## 8. Hand ownership to the multisig

Run only when wiring is complete (including any gold adapters):

```bash
forge script contracts/script/DeployMainnet.s.sol:DeployMainnet --sig "handoff()" \
  --rpc-url "$ARC_MAINNET_RPC" --account defivault-deployer --sender "$DEPLOYER_ADDRESS" --broadcast -vvv
```

- The registry uses plain `Ownable`: its transfer is immediate and irreversible. Triple-check `OWNER_MULTISIG` before this step.
- Every other contract uses two-step ownership: from `OWNER_MULTISIG`, call `acceptOwnership()` on each address the script prints (7 core contracts plus one per gold adapter).
- Check progress with `verifyPendingAcceptance()`, then run the strict `verify()` once everything is accepted:

```bash
forge script contracts/script/DeployMainnet.s.sol:DeployMainnet --sig "verify()" --rpc-url "$ARC_MAINNET_RPC"
```

`verify()` asserts the wiring listed in section 5, the 30-day registry timelock, the board member, the vault runtime size, and that the multisig owns everything including gold adapters linked in the vault.

## 9. Unpause and first use

1. From `OWNER_MULTISIG`: `vault.setPaused(false)` only after `verify()` passes and the audit conditions are met.
2. First deposit and exit with a small amount from an ordinary wallet. Exits while profit exists require a minimum gas limit (the exit-settlement guard: 2 x (700k + 1.3M per funded adapter): 1.4M with no funded adapters, 4M with one; a funded LP adapter exit measured about 6.1M). Let the node estimate gas; do not hardcode a lower limit in wallets or integrations.
3. Keep the first weeks small. The vault has no deposit cap; limit exposure by pausing or by staged communication.

## 10. Record of the deployment (fill in, keep in sync with `docs/agents/deployed-addresses.md`)

| Contract | Address | Tx hash | Block |
|---|---|---|---|
| ShariahAdapterRegistry | | | |
| TreasuryModule | | | |
| ZakatModule (v1 compat, unused) | | | |
| ShariahVaultV2 | | | |
| CharityModule | | | |
| PurificationEscrow | | | |
| ShariahScoreAggregator | | | |
| RiskTieredExecutor | | | |
| GoldExchangeAdapter (optional) | | | |
| GoldAllocationAdapter (optional) | | | |
| Linked libraries (4) | see broadcast file | | |

## 11. Operations and incident response

- **Pause:** `vault.setPaused(true)` (owner multisig) stops deposits and deployments. Recalls and exits stay available.
- **Cannot be undone quickly:** registry ownership, charity wallet and rate changes, screening, adapter parameter changes and the gold emergency-exit flag all carry 30-day timelocks. Plan changes a month ahead.
- **Gold emergency exit:** per-sale proposal (1 hour delay, 24 hour window, 20 percent floor) and only if the flag was enabled 30 days earlier.
- **Watch:** vault events (`MusharakahProfitClaimed`, `PauseUpdated`, `PrincipalRetired`, CCTP settlement events), `valuationHealthy()`, `pendingDistributionCut()`, gold `isPriceSane()`, treasury `pendingFees`, executor cooldown and gas ceiling, and failed exits (`InsufficientExitGas`).
- **Known degraded mode:** if the escrow, charity or treasury cannot receive funds (for example a blocklisted address), exits still succeed but the distribution cut stays in the vault as ordinary profit.
- **No upgrade path:** the vault is immutable. A fix means a new vault plus migration (see `docs/migration-v1-to-v2.md` for the pattern).

## 12. What this runbook does not cover

Legal, regulatory and licensing review; custody and key ceremony procedures; Circle gas funding arrangements (the Arc guidance is to request mainnet gas USDC through your Circle point of contact); front-end hosting and domain controls; real-world gold custody and settlement for PAXG/XAUT.
