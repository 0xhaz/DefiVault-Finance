# DeFiVault Shariah vault: independent audit handoff package

Prepared 2026-10-31 for an external security audit ahead of any Arc mainnet deployment. Everything below describes the repository state at handoff; record the exact commit hash you freeze before the audit starts: `COMMIT: <REPLACE>`. Freeze procedure: merge the reviewed PR stack into `main`, re-run `forge test` and Slither on that commit, tag it `audit-freeze-1`, and write the hash here and in section 11. Line counts and test numbers below were taken on 2026-10-31 at the head of the stack (branch `p7-audit-handoff`).

No part of this stack has been deployed to Arc mainnet. The latest testnet deployment is "run 5" on Arc Testnet (chain ID 5042002); addresses are in `docs/agents/deployed-addresses.md`.

## 1. What the system does

A USDC ERC-4626 vault (`ShariahVaultV2`) for Shariah-governed strategies. Depositors receive shares. A manager contract (`RiskTieredExecutor`) deploys capital into screened strategy adapters (gold spot allocation, gold exchange, optionally an LP adapter), guided by scores written by an oracle operator. Profit is shared under a Musharakah arrangement: a hurdle rate, a high-water mark, a manager share of profit above the hurdle, a Wakala administration fee, a charity contribution and income purification. The vault is immutable and non-upgradeable.

Plain-language rules the code is meant to enforce:
- Only adapters screened by the board (30-day timelock, expiring, pronouncement hash) can receive funds.
- Share price is net of the distribution cut a full claim would take, so a holder cannot exit before a claim and leave others to bear it.
- Every exit settles the leaver's pro-rata share of realized profit through the real claim path.
- Non-gold adapter losses mark the share price down; gold is oracle-priced in both directions; gains from non-gold adapters are never counted until realized.
- Gold exposure is capped at 30 percent of NAV and goes through an atomic swap (no deferred settlement).
- Exits are never blocked by external dependencies, except by the caller's own gas limit (below).

## 2. Scope

In scope (lines of Solidity at handoff):

| File | Lines | Role |
|---|---|---|
| `contracts/ShariahVault.sol` | 1276 | Core vault logic and four linked libraries (accounting, governance, registry timelock, CCTP) |
| `contracts/ShariahVaultV2.sol` | 217 | Registry-gated screening on top of the V1 vault |
| `contracts/AutonomousVault.sol` | 578 | Base vault (ERC-4626, CCTP settlement, caps, pausing) |
| `contracts/TreasuryModule.sol` | 204 | Fee and Musharakah split accounting |
| `contracts/PurificationEscrow.sol` | 316 | Profit waterfall, purification, charity routing |
| `contracts/CharityModule.sol` | 237 | Charity distribution and wallet/rate timelocks |
| `contracts/ShariahAdapterRegistry.sol` | 298 | Board, screening, expiry, 30-day timelock |
| `contracts/RiskTieredExecutor.sol` | 319 | Manager that deploys capital, gold-room clamp |
| `contracts/ShariahScoreAggregator.sol` | 201 | Strategy scores written by the oracle operator |
| `contracts/ZakatModule.sol` | 106 | Deprecated v1-compat module, still a constructor input |
| `contracts/adapters/GoldExchangeAdapter.sol` | 517 | PAXG atomic swap adapter, emergency exit |
| `contracts/adapters/GoldAllocationAdapter.sol` | 633 | XAUT spot allocation adapter, emergency exit |
| `contracts/adapters/HalalLPAdapter.sol` | 569 | Two-sided Uniswap V3 LP adapter (mocks, plus an Arc mainnet fork against the real Uniswap V3 USDC/EURC pool; never deployed on testnet) |
| `contracts/script/DeployMainnet.s.sol` | 384 | Production deployment script |
| `contracts/script/DeployHalalLP.s.sol` | 165 | LP adapter deployment script |

Total: 6,020 lines. The LP adapter is **in scope** (owner decision D-1, 2026-10-31): it is the least-tested code, and a real venue exists on Arc mainnet. Launching with LP enabled still depends on the testnet LP campaign and a board ruling on the pair token.

Out of scope: `ConventionalVault.sol` and its conventional strategy adapters (not part of the Shariah launch; known findings N-18 and N-28 are recorded), everything under `contracts/test`, `contracts/test-helpers` and `contracts/script/Rehearsal.s.sol` (testnet only), the front end under `src/` and the agent server under `server/`.

Compiler: `solc 0.8.28`, optimizer on, 200 runs, `evm_version = "paris"`. Dependencies: OpenZeppelin Contracts (`@openzeppelin/contracts`) and forge-std only.

## 3. Architecture notes for reviewers

- `ShariahVaultV2` inherits `ShariahVault`, which inherits `AutonomousVault`. All of it compiles into one contract. Runtime size is 24,317 bytes against the 24,576-byte limit, so logic was moved into four external linked libraries called by delegatecall with storage pointers. Review the storage-pointer parameters and the library entry points as part of the vault.
- Dependencies are separate contracts the vault trusts: treasury, charity module, purification escrow, registry, adapters and the executor. Exit settlement calls the escrow, charity module and treasury inside a `try/catch`.
- Arc specifics: USDC is the native gas token; the ERC-20 view has 6 decimals and the native view 18; sends to a blocklisted address revert; the mempool floors `maxFeePerGas` at 20 gwei.

## 4. Areas that deserve the most attention

1. **Exit settlement** (`_withdraw`, `exitSettle`, `ShariahAccountingLogic.executeWaterfall`): self-call in `try/catch` with a distribution lock; a gas guard (`InsufficientExitGas`, 2 x (700k + 1.3M per funded adapter) since N-33) added because `eth_estimateGas` otherwise picks a limit that starves the settlement; degraded mode when the escrow, charity or treasury is broken.
2. **Net-of-cut pricing** (`totalAssets`, `pendingDistributionCut`, `PurificationEscrow.previewWaterfallHWM`): preview must equal the real waterfall; bounded 100k-gas read (`ESCROW_PREVIEW_GAS`); failure yields a zero cut.
3. **Hurdle and high-water-mark accounting**: carry-forward of unused hurdle across partial claims and exits, allocation of hurdle and deficit by the departing share fraction (alpha), deposit-time basis (`depositHurdle`), scaling on withdrawal, owner setter that can only increase with live supply. Known limitation N-32.
4. **Mark-to-market of non-gold adapters** (`unrealizedAdapterLoss`, `valuationHealthy`): bounded assembly `staticcall` (150k gas since N-33, exactly 32 bytes returned), failure counts as zero loss for exits but blocks deposits, cap of 5 funded non-gold adapters (10 before N-33), deposit gate above the dust threshold (see N-34 for how this interacts with LP entry costs).
5. **Gold adapters**: oracle and pool deviation guards, stale-price handling, cached price, per-sale emergency exit (proposal, 1 hour delay, 24 hour window, 20 percent floor, flag enabled by 30-day timelock), `retireGoldPrincipal` hook, oracle replacement lock while the emergency flag is on.
6. **CCTP settlement** (`CctpSettlementLogic`): message header parsing against the real CCTP V2 layout, destination caller, replay protection, balance-delta check, fee handling. Verified on a fork of Arc Testnet against the real contracts; live attestations, the unfinalized path and hook data were not exercised.
7. **Registry and governance**: board role, expiring screening, 30-day timelocks, plain `Ownable` registry (immediate ownership transfer).
8. **Deployment script**: validation, phase ordering, ownership handoff, `verify()` assertions.
9. **Executor**: gold-room clamp, gas ceiling, cooldown, anyone-can-call `executeWinner`.

## 5. Trust model

The table states the intended capabilities. Verifying the "cannot" column is part of the audit.

| Actor | Can | Cannot |
|---|---|---|
| Owner multisig | Pause; set manager, gold links, permitted assets, caps; configure executor and aggregator; owner functions on adapters; raise (not lower) the hurdle principal | Withdraw user funds directly; bypass 30-day timelocks; change board members without the timelock |
| Board multisig | Screen adapters, set charity wallet/rate, dust threshold, remote recipients (all timelocked) | Move funds; bypass expiry |
| Manager (executor) | Deploy to screened adapters within caps; recall | Exceed gold cap; use unscreened adapters; withdraw to arbitrary addresses |
| Oracle operator | Write scores for enabled strategies | Move funds |
| Screened adapter | Report its own value (downward marks only for non-gold); hold deployed funds | Raise NAV above principal; block exits (reads are gas-bounded and failures treated as no markdown) |
| Anyone | Deposit and redeem; call `executeWinner` (subject to cooldown, score threshold and gas ceiling) | Skip the exit settlement |

Assumed honest: Circle (USDC and CCTP), the XAU/USD oracle, DEX liquidity for the gold adapters, the Shariah board's rulings, multisig signers.

## 6. Known findings and limitations

Fixed findings are listed with explanations in `docs/security-review.md` (N-01 to N-31, N-33, N-35). Open or accepted at handoff:

- **N-32 (medium, accepted):** a deposit made while a large unprocessed profit exists and an HWM deficit is open can shrink the deficit; worst case measured about 0.28 percent of holder value for one round trip at maximum rates.
- **N-34 (medium, accepted for V2):** with a funded LP adapter, the deposit gate (marked non-gold loss above the dust threshold, default 1 USDC) closes as soon as entry costs are booked. Mitigation: the board raises the dust threshold before LP funding (runbook). We would like the auditors' view on a better gate for LP strategies.
- **N-36 (low, accepted for V2):** the aggregator returns one global winner; a tier whose mask excludes it reverts instead of falling back. Mainnet uses one aggregator for one Conservative executor and enables only strategies in its mask.
- **N-18, N-28:** `ConventionalVault`, out of scope.
- **Manager-dependent exits:** deployed capital returns only when the manager (or owner) recalls it; no permissionless withdrawal queue. `maxWithdraw`/`maxRedeem` reflect idle liquidity.
- **Concealed LP loss:** if a `HalalLPAdapter` price is unreadable, deposits are blocked but exits are priced at unmarked NAV.
- **Emergency exit lead time:** enabling needs 30 days; a crash beyond 80 percent still blocks it.
- **Exit gas floor:** exits with realized profit revert below the gas floor; integrators with hardcoded low gas will fail. Since N-33 an exit reads every funded adapter about 23 times; with at most 5 funded adapters the measured worst case (140k per read) is 25.3M gas, inside Arc's 30M block limit. With one funded real Uniswap V3 LP adapter, a cold exit with realized profit settles the cut from 4.97M gas (full stack on the Arc mainnet fork, `ForkVaultLPArcMainnet.t.sol`).
- **Degraded exit mode:** a broken escrow, charity or treasury leaves the leaver's cut in the vault as ordinary profit.
- **Adapter self-reporting:** a screened adapter that overstates value is not detected.
- **Size margin:** 259 bytes; the vault cannot take another feature without another split.
- **Immutable:** no upgrade path; fixes require a new vault and migration.
- **Pending Shariah rulings:** 24 board items (`docs/agents/SHARIAH_REVIEW.md`) are not yet ruled.

## 7. Test evidence

Run from the repository root with Foundry (`forge 1.x`, the project pins `solc 0.8.28`):

```bash
forge build --sizes                      # ShariahVaultV2 runtime 24,317 B (limit 24,576)
forge test                               # 2074 passed, 0 failed, 4 skipped on 2026-10-31 (fork suites skip without ARC_TESTNET_RPC / ARC_MAINNET_RPC)
forge test --match-path 'contracts/test/invariant/*'
contracts/script/local/run-local.sh      # deploy-script rehearsal on a local anvil: 207 checks passed
```

What exists:
- Unit and scenario tests per module; fuzz tests (256 runs and above) for waterfall, hurdle, exits, retirement and valuation helpers.
- Eight invariants (256 runs, depth 50): see `contracts/test/invariant/VaultInvariant.*.t.sol`.
- Hostile-counterparty tests: reverting, gas-burning, malformed-returndata and re-entering adapters, escrows, charity wallets and treasuries.
- Fork tests of CCTP V2 against the real Arc Testnet contracts (`ForkCctpRealArc*.t.sol`).
- Library-level tests (`LibraryTests.*.t.sol`).
- Gas measurement tests for the exit floor (`TaskReviewR5Test*.t.sol`).
- Arc mainnet fork tests of `HalalLPAdapter` against the real Uniswap V3 USDC/EURC 0.05% pool, alone (`ForkHalalLPArcMainnet.t.sol`, 10 tests) and inside the full V2 stack (`ForkVaultLPArcMainnet.t.sol`, 7 tests). Local fork only; nothing broadcast. Run with `ARC_MAINNET_RPC=https://rpc.mainnet.arc.io ARC_MAINNET_FORK_BLOCK=28789291`.
- Direct-call tests for all four linked libraries (`LibraryDirectCallP6Test.t.sol`): every state-changing entry point reverts when called on the library address (question 2 below).
- Static analysis: Slither 0.11.6, every High and Medium result in scope triaged in `docs/static-analysis.md` (one real finding, N-35, fixed). Aderyn not yet run.
- Coverage: `docs/coverage.md` (`forge coverage --ir-minimum`). Vault and libraries about 96 percent of lines and branches; lowest branch coverage 65 to 73 percent in the registry, charity, escrow and gold adapters, mostly revert branches of timelocked setters.
- Live Arc Testnet runs on run 5: deposit, executor deployment into gold, profit claim (share price unchanged across the claim), recall, and redemption with the settlement routed to charity and treasury.
- Deploy-script rehearsal on a local anvil: governance validation, phase ordering, two-step ownership handoff, strict verification.

What was not covered: transactions on Arc mainnet (only read-only forks); `HalalLPAdapter` on a live chain (fork only), and with USDC as `token1`; real PAXG/XAUT; real Chainlink-style feeds on Arc; real Safe execution; live CCTP attestations; the 30-day flows end to end on a real chain.

## 8. Review history

Internal AI-assisted reviews ran repeatedly during development (rule-based and functional passes). They produced the N-series findings, all but the items above are fixed with regression tests. Several review runs returned no usable report and were repeated or covered by hand; this history is not an independent assurance. A pre-audit pass on 2026-10-31 added static analysis (P-3), coverage (P-4), library direct-call tests (P-6), doc reconciliation (P-1) and a second review of the latest vault changes (P-2, results in `docs/security-review.md`). Findings and decisions: `docs/security-review.md`, `docs/agents/SHARIAH_REVIEW.md`, `AGENTS.md`.

## 9. Deployment parameters under review

See `docs/mainnet-config.md`: fee parameters (Wakala, Musharakah share, hurdle), charity rate and wallet, caps, timelocks, executor gas ceiling, role split. Ask the auditors to comment on each default and bound.

## 10. Questions for the auditors

1. Is the net-of-cut share pricing combined with exit-time settlement free of manipulable windows (donation, sandwiching a claim, first-depositor effects with the 1e6 virtual-share offset)?
2. Are the storage-pointer conventions of the library entry points sound? (Direct calls on the library address are covered by `LibraryDirectCallP6Test.t.sol`; please confirm.)
3. Can any actor force degraded exit mode, make exits unaffordable, or push cost onto other holders?
4. Is the hurdle and deficit allocation by departing fraction exact enough, and are there deposit/withdraw sequences that let the manager earn more than a single claim would pay?
5. Are the gold emergency-exit controls sufficient given the oracle lock, the 20 percent floor and the 30-day enable flag?
6. Does the CCTP settlement handle every message variation the real MessageTransmitterV2 can deliver to the vault?
7. Is the deployment script's ownership handoff sound, and does `verify()` prove the final state?
8. Given Arc's USDC semantics (native gas token, blocklist, 6/18 decimal views), are there transfer or accounting edge cases?
9. For LP strategies, is a deposit gate tied to the dust threshold the right design (N-34), and is the concealed-loss window while the TWAP lags acceptable?

## 11. Contacts and logistics

Maintainer contact: `<REPLACE>`. Board contact for rulings: `<REPLACE>`. Preferred channel and report format: `<REPLACE>`. Frozen commit and tag: `<REPLACE>`.
