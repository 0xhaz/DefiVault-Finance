# Workplan: testnet completion, security audit and mainnet preparation

Created 2026-10-31 from a pass over `README.md`, `AGENTS.md` and every file in `docs/`.
Scope: finish the testnet gaps (mainly the LP adapter), get the code ready for an independent audit, and prepare the mainnet launch. Nothing here deploys to mainnet. Mainnet transactions are run by the operator, outside Arc Studio, after the gates in `docs/mainnet-deploy.md` section 1 are met.

Rules that apply to every task (from `AGENTS.md`): testnet only, one task per branch/PR, never reorder `ShariahStrategy`, no forced migration, Shariah parameters board-settable through a timelock, no "certified/halal/sukuk/Zakat" wording without a board pronouncement.

---

## 1. Where things stand

| Area | State | Source |
|---|---|---|
| Contracts | Tasks A–L and N done. Findings N-01 to N-31 fixed, except N-18 and N-28 (conventional vault, out of scope). N-32 accepted as a known limitation | `docs/security-review.md` |
| Testnet | Run 5 is live (`ShariahVaultV2` `0x9217…2CaC`). Verified live: deposit, `writeScore`, `executeWinner` into gold allocation, yield, claim, recall, full redeem | `docs/agents/deployed-addresses.md` |
| LP adapter (`HalalLPAdapter`, S3-H) | Rewritten as a two-sided LP (N-05), 216 tests, **mocks only**. Not deployed on testnet, never run against a real Uniswap pool or router. No executor strategy config, so if HALAL_LP wins, `executeWinner` reverts `StrategyDisabled`. The agent scored HALAL_LP=90 and it won consistently in the rehearsal | `security-review.md` N-05, "Known gaps"; `rehearsal.md` step 4 |
| CCTP | Fork-tested against the real Arc Testnet contracts. No live round trip (step 5) | `rehearsal.md`, N-03 |
| Mainnet material | `DeployMainnet.s.sol`, runbook, config, audit handoff. Exercised only on local anvil (207 checks) | `mainnet-deploy.md`, `audit-handoff.md` |
| Shariah board | 24 of 27 SR items still read REVIEW, none approved | `docs/agents/SHARIAH_REVIEW.md` |
| Audit | Not started. Only internal AI-assisted reviews so far | `audit-handoff.md` section 8 |

### Problems found while reading

1. **Work is not committed.** About 950 lines across `ShariahVault.sol`, `RiskTieredExecutor.sol`, all three adapters and `Rehearsal.s.sol`, plus untracked `DeployMainnet.s.sol`, `DeployHalalLP.s.sol`, `script/local/`, `MockSwapRouter.sol`, `DeployMainnetStubs.sol` and the GoldEmergencyExit, GoldOracleLock, HalalLPAdapterN05 and LibraryTests suites. Build artifacts (`contracts/out`, `contracts/cache`) show up in git status. (The untracked nested copy `DefiVault-Finance/` was an older snapshot from 07:34 on 2026-10-31 with no unique files; it was deleted on 2026-10-31.)
2. **The docs disagree with each other.**
   - Test counts: 503, 987, 1794 and 2066 are all quoted in different places.
   - Vault size: 24,244 B (332 B margin) in one place, 24,317 B (259 B margin) in another.
   - Rows N-20 to N-23 in `security-review.md` say **Fixed**, but their text still describes the bug as open.
   - The "Arc-Specific Notes" in `security-review.md` say the CCTP fork test is missing, but it exists. The "Deployed Addresses Reviewed" table there lists run 2, which is stale.
   - The README adapter table lists `HalalLPAdapter` as "Active" with no mocks-only caveat.
   - README line 620 still describes `lockProfit(depositorShare)` at claim time. That was removed in N-11.
   - In `rehearsal.md`: step 3 says it screens the LP adapter, but the gold adapter was screened. Steps 2, 5 and 7 still have TBD rows, and the header date is TBD.
   - `docs/implementation-plan.md` is a pasted Task F chat transcript ("say build to proceed"), not a plan.
3. **LP valuation gas is unmeasured.** The vault reads `currentValue()` with a hard 100,000 gas cap (`ADAPTER_READ_GAS`). The LP version runs a TWAP `observe`, `positions()` and liquidity math. If a real pool pushes that over 100k, the read fails every time, `valuationHealthy()` goes false and deposits are blocked for as long as the LP is funded. No test measures this.
4. **`HalalLPAdapter` constructor** only zero-checks `swapRouter`. `positionManager`, `vault` and `usdc` are not checked. This is low severity because the deploy script validates inputs, but it should be fixed or documented before the audit.

---

## 2. Order of work

```
Phase 0  Freeze and clean up        (days 1-2)       ──┐
Phase 1  Pre-audit internal pass    (week 1)           ├─► Phase 4  Testnet run 6 (only if code changed)
Phase 2  LP testnet campaign        (weeks 1-3)        │                 │
Phase 3  Other testnet gaps         (weeks 1-5, 30-day ┘                 ▼
          clocks run in parallel)                       Phase 5  Independent audit ─► fixes ─► run 7 if needed
                                                                          │
Phase 6  Mainnet preparation (board, Safes, gold deps, ops) runs in parallel from week 1
```

**Critical path:** the 30-day timelocks (Phase 3, T-5) and the board rulings (Phase 6, M-1). Start both on day 1. A redeploy resets every 30-day clock on the new contracts. So land every contract change that is already known (Phases 1 and 2) **before** starting long clocks on a new run, or run the clocks on run 5 and accept that they prove the flow, not the final bytecode.

---

## Phase 0: Freeze and clean up (blocks everything else)

| ID | Task | Done when |
|---|---|---|
| F-1 | **Done 2026-10-31** (local commits, not pushed). Stacked branches from `main`, each green on `forge test` at its own commit: `f1/halal-lp-n05` (N-05 LP adapter, mocks, DeployHalalLP), `f1/vault-hardening` (vault, executor, gold adapters, R3-R5 and library tests, security review), `f1/mainnet-prep` (DeployMainnet, local rehearsal, mainnet docs), `f1/testnet-run5-records` (broadcast logs, addresses, AGENTS.md), `lp-1-fork-test-arc-v3` (LP-1 fork test, N-33 recorded open), `n33-adapter-read-gas` (N-33 fix), `docs/workplan` (this file). Not committed: tracked build artifacts (F-2) and a mode-only change to `lib/forge-std/scripts/vm.py` | Open PRs in stack order and merge bottom-up |
| F-2 | ~~Delete the nested `DefiVault-Finance/` directory~~ (done 2026-10-31). Add `contracts/out/` and `contracts/cache/` to `.gitignore` if they are not meant to be tracked | Builds no longer dirty the tree |
| F-3 | Record the baseline: `forge build --sizes` and the full `forge test` count, invariants included, plus a fork run with `ARC_TESTNET_RPC` set | One authoritative number for tests and vault size, written in `AGENTS.md` |
| F-4 | Check that run 5's on-chain runtime bytecode matches the frozen commit (`cast code` against `forge inspect … deployedBytecode`, with library links resolved) | Match confirmed, or a note that run 5 predates commit X |

## Phase 1: Pre-audit internal pass

| ID | Task | Done when |
|---|---|---|
| P-1 | Reconcile the docs (every item in "Problems found" #2). Turn `implementation-plan.md` into a short historical note or archive it | No contradictory numbers across README, AGENTS, security review and audit handoff |
| P-2 | Second review pass over the last unreviewed changes: oracle lock while emergency exits are enabled, the `retireGoldPrincipal` hook, the exit gas guard and the `Rehearsal.s.sol` edits (`security-review.md` "Review coverage") | Findings logged as N-33 and up, fixed or accepted |
| P-3 | Static analysis: run Slither and Aderyn over the in-scope contracts and triage every result (fix, or mark as a false positive with a reason) | Report saved at `docs/static-analysis.md` |
| P-4 | Coverage: run `forge coverage` (with `--ir-minimum` if stack-too-deep) on the in-scope files. Add tests for uncovered branches in the vault, the libraries and the adapters | Line/branch coverage table in the audit handoff, and no untested revert path in the vault |
| P-5 | Fix or document the `HalalLPAdapter` constructor zero-checks (Problems #4) | Test added |
| P-6 | Library direct-call safety: test that calling each of the four linked libraries directly at its deployed address cannot change state or move funds (auditor question 2) | Tests in `LibraryTests.*` |
| P-7 | Finish `docs/audit-handoff.md`: frozen commit hash, line count for `DeployHalalLP.s.sol`, contacts, coverage and static-analysis results, the LP scope decision (D-1) | No `<REPLACE>` left apart from the auditors' contact details |

## Phase 2: LP testnet campaign (the main testnet gap)

Goal: prove `HalalLPAdapter` against real Uniswap V3 code and on Arc Testnet before the audit locks the bytecode.

### LP venue survey (checked on-chain 2026-10-31)

| Venue | Network | Status | Usable by `HalalLPAdapter` (v3 ABI)? |
|---|---|---|---|
| Official Uniswap V3 (factory `0xf0db7b58379503491d857db50ac9ece64c653918`, NPM `0x39654a85a4c05127f5fd6ed22caec077a0fb1377`, SwapRouter02 `0x53bf6b0684ec7ef91e1387da3d1a1769bc5a6f77`) | **Arc mainnet** (5042) | Live. USDC/EURC 0.05% pool `0x6fd5F2fb831940DcD61A98c5B3aCB7D8C6f3bFc1`: about 30.5k USDC + 55.5k EURC, observation cardinality 1000 (a 1800 s TWAP works). The 0.3% and 1% pools are dust | **Yes**: matches the adapter's ABI. Depth is thin (about $90k), so per-deploy size must stay small |
| Official Uniswap V3 | Arc Testnet (5042002) | **Not deployed** (no code at the mainnet addresses) | Not available |
| UnitFlow V3 fork (factory `0xb0bC…10CB`, NPM `0xf8ec…5181`, router `0x75eD…0930`) | Arc Testnet | Live, but its router uses the old `SwapRouter` call (`exactInputSingle` with a deadline, selector `0x414bf389`). One junk pool only (USDC/"SDFSDF", cardinality 1) | No: swaps would revert without a shim |
| Official Uniswap **v4** (PoolManager `0x8366a39cc670b4001a1121b8f6a443a643e40951`, PositionManager `0x6049c9a0e26405c0985f9e3685c87d0ae917f82b`, StateView `0xf3334192d15450cdd385c8b70e03f9a6bd9e673b`) | Arc Testnet (same addresses on mainnet) | Live, 546 pools. USDC/EURC 0.05% hookless pool id `0xf775c49a5149d5d85f0667782c0b5ccde7fbaeeac0cdbe0ea3b47eea8d7829ea`, realistic price, but nearly empty (about 10 EURC in the PoolManager) | **No**: different architecture, see V3-LP4 |

Decision: stay on Uniswap V3 for `ShariahVaultV2`. Test with a fork (LP-1/LP-2) and with our own deployment of official V3 on Arc Testnet (LP-3). Mainnet target: the official V3 USDC/EURC 0.05% pool. LP-3's pair changes from USDC/WETH to **USDC/EURC** (EURC testnet `0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a`, mainnet `0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1`, both 6 decimals). This avoids the open ETH question (SR-027) and matches the mainnet pool. Add one volatile mock pair on our own testnet V3 so the impermanent-loss mark-down path gets exercised. A stable pair will barely move.

| ID | Task | Done when |
|---|---|---|
| LP-1/2 status | **Done 2026-10-31** on branch `lp-1-fork-test-arc-v3`: `contracts/test/ForkHalalLPArcMainnet.t.sol`, 10 tests against the real Arc mainnet V3 USDC/EURC 0.05% pool (local fork, block 28789291, nothing broadcast). Results: deploy and value within 0.03% of principal; full-recall round trip returns 99.95%; partial then full recall works; real swap fees collected; single deploys up to 80k USDC pass the 1% slippage settings; a 171-tick shock (25k EURC sold) blocks recall until the TWAP catches up, and the value stays unmarked (about 0.85% hidden) for that roughly 30-minute window, then it is marked down and realized. **Finding N-33 (High):** the cold `currentValue()` read cost about 111k gas, above the vault's 100k read cap. **Fixed on branch `n33-adapter-read-gas`:** read cap 150k, settlement budget 1.3M per funded adapter, at most 5 funded non-gold adapters; full suite 2046 pass. N33-A **done** on branch `n33a-vault-lp-fork` (`ForkVaultLPArcMainnet.t.sol`, 7 tests, full ShariahVaultV2 stack plus the real LP adapter on the Arc mainnet fork): a cold vault read marks the real LP value; a cold exit with realized profit needs 4.97M gas (floor 4.0M) and settles the cut at that minimum; recall through the vault retires principal (99.95% back); a 133-tick shock is marked down, deposits close and exits stay open. **New finding N-34 (Medium, open):** at the default 1 USDC dust threshold, LP entry costs (about 1.48 USDC on 5k) close the deposit gate as soon as the LP is funded. Mitigation: the board raises dust toward the 0.5% NAV cap 30 days before funding (leave headroom; see D-6). Follow-up: N33-B, a per-transaction value cache to remove the 23 redundant reads per exit (needs vault bytes, so consider it for ShariahVaultV3). Not yet covered: USDC as token1 (needs a second pool, e.g. an Ethereum fork) | |
| LP-1 | **Fork test against real Uniswap V3.** Fork Ethereum mainnet (or Base) and use the real USDC/WETH 0.05% pool, `NonfungiblePositionManager` and `SwapRouter02`, whose `exactInputSingle` has no deadline, which matches the adapter. Cover: deploy, partial and full recall, fee collection, `currentValue` against an independent calculation, `SpotTwapDeviation` after a large swap, `TwapUnavailable` on a pool with low cardinality, both token orders (USDC as token0 and as token1) | `HalalLPAdapterFork.t.sol` passes. It skips when no RPC is set, like the CCTP fork tests |
| LP-2 | **Gas of `currentValue()` against the 100k read cap.** Measure it on the fork with a 1800 s TWAP window, then at the minimum and maximum cardinality. Also measure the recall path against the exit gas floor assumption of 250k per funded adapter | Measured numbers recorded. If any exceeds the cap, fix it before the audit (cheaper read path or cached tick) |
| LP-3 | **Deploy official Uniswap V3 on Arc Testnet** (the survey above found no compatible venue). Deploy the canonical v3-core Factory, v3-periphery `NonfungiblePositionManager` and `SwapRouter02` from official artifacts (testnet only, recorded in `deployed-addresses.md`). Pairs: USDC/EURC 0.05% (mirrors the mainnet target), plus one USDC/mock volatile pair for impermanent-loss tests. Also add an Arc mainnet fork test against pool `0x6fd5…bFc1` | Factory, NPM and router addresses recorded, plus the pools initialized at realistic prices |
| LP-4 | **Pool setup.** Seed liquidity, call `increaseObservationCardinalityNext` (at least enough for a 1800 s window), and generate swaps for at least 30 min of TWAP history. Arc's USDC predeploy fails ERC-20 calls inside Foundry broadcast scripts, so use `cast send` for USDC operations (`rehearsal.md` issue 1). Confirm that Uniswap's pool and NPM work with Arc's native-coin USDC | Pool `observe()` returns a valid TWAP |
| LP-5 | **Deploy and wire.** Run `DeployHalalLP.s.sol` (`check()` first) against run 5 (or run 6), screen it through the 2-minute testnet registry, add a `setShariahStrategyConfig` for HALAL_LP, and enable aggregator index 2 (testnet only) | `executeWinner` with HALAL_LP as the winner funds the adapter |
| LP-6 | **Live scenarios** (log each one in `rehearsal.md`): (a) deploy through `executeWinner`; (b) swap volume, then fees collected on recall; (c) partial recall, then full recall; (d) price move, with the NAV marked down by impermanent loss and never marked up; (e) spot moved away from TWAP, so deploy/recall revert; (f) position out of range; (g) second deploy reverts `PositionAlreadyOpen`; (h) user exit while the LP is funded, checking the gas floor and the settlement cut; (i) unreadable price, so deposits are blocked and exits stay open; (j) recall, write-off and replace a broken LP adapter; (k) fee tier 10000 with aligned ticks | Every scenario has a tx hash and the expected vs actual result |
| LP-7 | **Concealed LP loss** (Known gap). With LP-6(i) running, measure how much loss can pass to remaining holders while the price is unreadable. Decide D-2 | Number recorded and decision written |
| LP-8 | Rehearsal `step3_screenS3H` and `rehearsal.md`: point them at the real LP adapter, or rename them so they match what was actually screened | Script and doc agree |

## Phase 3: Other testnet gaps

| ID | Task | Done when |
|---|---|---|
| T-1 | **Live CCTP round trip** (rehearsal step 5). Propose the remote recipient now (30-day `REMOTE_RECIPIENT_TIMELOCK`), then burn to ETH-Sepolia, return with a real attestation and `settleCrossChainWithMessage`. Record `feeExecuted` and the NAV before and after | Step 5 table filled in |
| T-2 | **Live stale oracle** (step 6) with a funded gold position above dust: deposits blocked, redemptions work, `currentValue` uses the haircut fallback | Step 6 table filled in |
| T-3 | **Agent on-chain path.** Configure the oracle wallet so `server/agent.ts` actually writes scores (it currently only simulates). Run at least 2 h and check the executor gas ceiling against live Arc gas | `ExecutionTriggered` events logged from the agent itself |
| T-4 | **Three real wallets.** Earlier runs used one key. Run deposit, claim and redeem with three distinct depositors entering and leaving at different times (exercises N-29/N-32 live) | Per-wallet results logged |
| T-5 | **30-day timelock flows end to end** (start on day 1). Propose on the live stack: gold emergency-exit flag, one adapter parameter (LP slippage or TWAP), dust threshold, charity wallet/rate, remote recipient. Execute each after 30 days, and test cancel on one of them | All executed or cancelled on-chain |
| T-6 | **Gold emergency exit live** (after T-5 enables the flag): propose, wait 1 h, execute inside the 24 h window, check `retireGoldPrincipal` | Logged |
| T-7 | **Mainnet script on a testnet-like chain.** `DeployMainnet.s.sol` is locked to chain 5042. Either add a guarded testnet profile, or run `check`/`deployCore`/`handoff`/`verify` on an anvil fork of Arc Testnet with the chain id overridden. If Safe is available on Arc Testnet, rehearse `acceptOwnership` from real Safes | Full script run end to end, outside the stand-in-only local run |

## Phase 4: Testnet run 6 (only if Phases 1–3 changed contract code)

| ID | Task | Done when |
|---|---|---|
| R-1 | Redeploy the full stack from the frozen commit, including the LP adapter, with `Rehearsal.s.sol` | Addresses in `deployed-addresses.md`; run 5 marked superseded |
| R-2 | Rerun the smoke test: deposit, `executeWinner` (gold and LP), claim, recall, three-wallet redeem | Logged in `rehearsal.md` |
| R-3 | Restart any T-5 clocks the redeploy reset | Proposals pending on run 6 |

## Phase 5: Independent audit

| ID | Task | Done when |
|---|---|---|
| A-1 | Pick the firm(s). Consider a contest after the private audit, given the size of the accounting logic | Signed engagement and dates |
| A-2 | Hand over the frozen commit, `audit-handoff.md` and the static-analysis and coverage reports. Keep code frozen during the audit; any change counts as a delta | Kickoff held |
| A-3 | Fix Critical and High findings, one branch per finding group, each with regression tests | Auditor re-review signed off |
| A-4 | Redeploy on testnet if the fixes touch deployed code (repeat Phase 4) | Testnet runs the audited bytecode |
| A-5 | Publish the audit report and update `security-review.md` | Linked from README |

## Phase 6: Mainnet preparation (in parallel, nothing broadcast)

| ID | Task | Owner | Done when |
|---|---|---|---|
| M-1 | Board rulings needed for launch: SR-002, 003, 004, 012, 014, 018, 020, 025, 026. Before gold: SR-005, 008, 009, 010, 013, 016. Before LP: SR-011 and SR-027 (ETH) | Board | Pronouncements and hashes recorded |
| M-2 | Confirm Arc mainnet's contract size limit (259 B margin) | Operator / Circle contact | Written confirmation |
| M-3 | Gold dependencies on Arc mainnet: PAXG, XAUT, XAU/USD oracle, routers, liquidity depth. If they don't exist, launch without gold | Operator | Addresses verified, or gold deferred |
| M-4 | LP venue on Arc mainnet: official Uniswap V3 is live and has a USDC/EURC 0.05% pool with about $90k depth (survey in Phase 2). Still to do: set a per-deploy size cap against that depth, recheck liquidity right before launch, and get a board ruling on EURC as a permitted pair asset (new SR item) | Operator / board | Size cap set and the SR item ruled |
| M-5 | Owner and Board Safes (at least 2-of-3, hardware signers, recovery plan), the oracle operator hot key, and the charity wallet (not blocklisted) | Operator / board | Addresses double-checked by two people |
| M-6 | Parameter decisions: `ADMIN_FEE_BPS`, `MUSHARAKAH_BPS`, `HURDLE_BPS`, `EXECUTOR_MAX_GAS_PRICE_GWEI` (`mainnet-config.md` section 2) | Board / operator | Values filled in the env file kept outside the repo |
| M-7 | Monitoring and incident runbook: the events and views in `mainnet-deploy.md` section 11, plus alerts for `valuationHealthy() == false`, `InsufficientExitGas` and stale oracles | Operator | Alerts firing on testnet |
| M-8 | Written risk acceptance for N-32 and each "Known gap" | Risk owners | Signed |
| M-9 | Legal/regulatory review and USDC gas funding through Circle (`mainnet-deploy.md` section 12) | Operator | Done |

---

## Phase 7: Future: ShariahVaultV3 with Uniswap v4 LP (after the V2 launch; not in the current audit scope)

Uniswap v4 is live on Arc Testnet and mainnet and seems to be where most Arc DEX activity is, but it cannot plug into `HalalLPAdapter`. Track it as a ShariahVaultV3 item. Under the no-forced-migration rule, V2 redemptions stay open.

| ID | Task | Notes |
|---|---|---|
| V3-LP1 | Design `HalalLPAdapterV4`: liquidity through `PositionManager.modifyLiquidities` (encoded actions plus Permit2), swaps through the Universal Router or an `unlock` callback, pool lookup by PoolKey/id | v4 uses one singleton PoolManager, not one contract per pool |
| V3-LP2 | **Price source.** v4 has no built-in `observe()`. Choose between (a) an oracle-hook pool (then the hook is screened and audited too) or (b) an external EURC/USD feed. Spot pricing is not allowed (F-03) | This is the main design question |
| V3-LP3 | **Native currency.** Many Arc v4 pools use `address(0)` (native USDC, 18 decimals). Either restrict to ERC-20 USDC (`0x3600…`) pools or handle the 18/6 view explicitly | Same risk as Invariant 3 |
| V3-LP4 | Testnet: use the existing v4 USDC/EURC hookless pool `0xf775…29ea` (seed liquidity from the faucet), or a pool with an oracle hook | Pool exists, depth is negligible |
| V3-LP5 | Shariah review: hooks can carry arbitrary logic, so the board screening must cover the hook as well as the pool | New SR item |
| V3-LP6 | Size budget: the V2 vault has 259 B of margin. A V3 vault is a new deployment and can be restructured | Plan the library split up front |

## 3. Decisions needed

| ID | Decision | Recommendation |
|---|---|---|
| D-1 | Is the LP adapter part of the mainnet launch? | Keep it **in audit scope** (it is already in the handoff and is the least tested code). A real venue now exists (official Uniswap V3 USDC/EURC on Arc mainnet, about $90k depth), so LP can launch if LP-1 to LP-6 pass, with a small per-deploy cap and a board ruling on EURC. Gold depends on M-3 the same way. Fallback: launch with idle USDC plus gold, or USDC only |
| D-6 | N-34: keep the dust-based deposit gate for LP strategies (and run the board dust change before funding), or change the gate for LP adapters (for example, a threshold relative to the adapter's principal)? | For V2: use the board dust mitigation and add it to the launch runbook (no vault bytes needed). Ask the auditors and the board about a better gate for V3 |
| D-5 | Uniswap v4 support | Defer to ShariahVaultV3 (Phase 7). It needs a new adapter and a price source, so it should not grow the current audit |
| D-2 | Concealed LP loss: accept it, or block exits pro rata while the LP price is unreadable? | Decide after LP-7 measures it. If the loss can be material, a contract change is needed, and it must land before the audit freeze |
| D-3 | Run the 30-day clocks on run 5 now, or wait for run 6? | Start them on run 5 now for flow evidence, and restart them on the final run only for things the launch depends on |
| D-4 | `DeployMainnet.s.sol` testnet profile vs fork-only rehearsal (T-7) | Fork with the chain id overridden, so no test path is added to the production script |

## 4. Exit criteria for "ready to hand to the operator for mainnet"

- [ ] Phase 0 and Phase 1 complete, with one consistent set of numbers in the docs
- [ ] LP either validated (LP-1 to LP-7) or excluded from launch in writing
- [ ] T-1 to T-7 logged
- [ ] Testnet runs the audited bytecode (A-4)
- [ ] Audit complete, Critical and High findings fixed and re-reviewed
- [ ] Every gate in `docs/mainnet-deploy.md` section 1 ticked by a named person
