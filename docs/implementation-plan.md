# Task F implementation plan (archived)

> **Historical record.** This is the plan approved before Task F (S6-H Gold Allocation) was built in October 2026. Task F is **done**; the code is the source of truth. Later changes are not reflected here: the aggregator flag is now `strategyEnabled` ("certified" is reserved for board rulings), gold deployment goes through the atomic path (N-23), and the vault has linked libraries (N-30). For current status see `AGENTS.md`, `docs/security-review.md` and `workplan.md`.

## Implementation Plan: Task F — S6-H XAUT Gold Allocation

### XAUT on Arc Testnet — Confirmed Not Deployed

Arc's contract address registry lists only USDC, EURC, USYC, cirBTC, and WETH. XAUT does not exist on Arc Testnet or Arc Mainnet. The search result showing XAUT at `0x73c0778B…` was the Lens Network testnet — a different chain entirely. Ethereum mainnet XAUT is `0x68749665FF8D2d112Fa859AA293F07A622782F38`, 6 decimals, upgradeable OZ proxy.

**Plan consequence:** Three test-only contracts are required — `MockXAUT` (6 dec), `MockXauUsdAggregator`, and `MockUniswapV3PoolXAUT`. The production `GoldAllocationAdapter` reads all decimals from `decimals()` at constructor time; swapping from mock to live XAUT on any future chain requires only a redeploy with a different address.

---

### Summary

Task F adds a sixth Shariah strategy, S6-H "Gold Allocation (XAUT, spot)": a capped spot holding of allocated gold inside the existing USDC vault. Returns come only from gold price movement — no yield. It sits alongside S2-H (PAXG spread, unchanged) behind a combined 30% gold cap. Requires appending enum index 5 to `ShariahScoreAggregator` (non-upgradeable — redeploy script needed), a new `GoldAllocationAdapter` with oracle + deviation + slippage guards, a stripped-down Uniswap V3 pool mock on Arc Testnet, and a full 30-day timelock on all board-settable adapter params matching the Task E `ShariahAdapterRegistry` pattern.

---

### Architecture additions

- **New enum index:** `GOLD_ALLOCATION = 5` appended to `ShariahScoreAggregator.ShariahStrategy` — never touching 0–4
- **New adapter:** `GoldAllocationAdapter.sol` — oracle-gated, single-transaction USDC↔XAUT swap
- **New mock contracts (testnet only):** `MockXAUT`, `MockXauUsdAggregator`, `MockUniswapV3PoolXAUT` (stripped V3 — price settable)
- **Redeploy script:** `RedeployShariahAggregator.s.sol` — deploys fresh 6-enum aggregator, re-applies enabled flags, re-points both executors
- **Deploy script:** `DeployGoldAllocation.s.sol` — deploys all mocks + adapter, wires vaults + executors
- **Masks updated:** Conservative `6` → `38` (`0b100110`), Dynamic `15` → `47` (`0b101111`)
- **Combined gold cap:** `MAX_GOLD_BPS = 3000` hard-coded in `ShariahVault`; board-settable `goldAllocTargetBps` (default 2000) + `goldAllocBandBps` (default 500) behind 30-day timelock
- **Lower-of-prices on redemption:** when `GoldAllocationAdapter.isPriceSane()` is false — deposits paused, redemptions value the XAUT slice at the lower of oracle and pool price

---

### Files to Create / Modify

**New contracts**

1. `contracts/adapters/GoldAllocationAdapter.sol` — IStrategyAdapter; oracle-checked atomic USDC↔XAUT swap; all board params behind `GoldAllocationParamTimelock` pattern; `currentValue()` = `xautBalance × oraclePrice` normalised across 3 decimal domains; `isPriceSane()` false when stale or pool deviates > `maxDeviationBps`
2. `contracts/interfaces/AggregatorV3Interface.sol` — minimal Chainlink aggregator interface (`latestRoundData()` only)
3. `contracts/test-helpers/MockXAUT.sol` — ERC-20, 6 decimals, public `mint()`; never used in production
4. `contracts/test-helpers/MockXauUsdAggregator.sol` — settable price + `updatedAt`; `decimals()` returns 8; implements `AggregatorV3Interface`
5. `contracts/test-helpers/MockUniswapV3PoolXAUT.sol` — stripped V3 pool mock; settable `sqrtPriceX96`; returns a pool price that the adapter reads via `slot0()`; `swap()` executes at configured ratio; used in place of a real V3 pool on Arc Testnet
6. `contracts/script/RedeployShariahAggregator.s.sol` — deploys 6-enum `ShariahScoreAggregator`; re-applies certified[0..3] = true, certified[4] = false, certified[5] = false; re-points both executors; logs old + new addresses
7. `contracts/script/DeployGoldAllocation.s.sol` — deploys MockXAUT + MockXauUsdAggregator + MockUniswapV3PoolXAUT + GoldAllocationAdapter; calls `vault.setPermittedAsset(xaut, true)` on both Shariah vaults; calls `setGoldAllocationAdapter(adapter)` on both Shariah vaults; calls `setStrategyMask` on both executors; calls `setShariahStrategyConfig(5, adapter, ...)` on both executors; records all to `docs/agents/deployed-addresses.md`

**Modified contracts**

8. `contracts/ShariahScoreAggregator.sol` — append `GOLD_ALLOCATION = 5`; change `for i < 5` → `i < 6` in `getWinningShariahStrategy()` and `getAllShariahScores()`; change all fixed-size array return types `[5]` → `[6]`; `_writeScore` deprecation guard stays at index 4 only
9. `contracts/RiskTieredExecutor.sol` — `SHARIAH_CONSERVATIVE` mask `6` → `38`; `SHARIAH_DYNAMIC` mask `15` → `47`; update both comments; `strategyMask` is `uint8` — 47 fits (`uint8` max 255)
10. `contracts/ShariahVault.sol` — add `uint256 public constant MAX_GOLD_BPS = 3000`; add `uint256 public goldAllocTargetBps` (default 2000) + `uint256 public goldAllocBandBps` (default 500) with 30-day timelock setters (propose + execute pattern, matching Task E `ShariahAdapterRegistry`); add `address public goldAllocationAdapter`; add `GoldCapExceeded()` error; override `deployCapital` to check combined S2-H PAXG value + S6-H XAUT value vs `MAX_GOLD_BPS × totalAssets`; override `totalAssets()` to value XAUT slice at lower-of-oracle/pool when `!isPriceSane()`; override `deposit()` / `mint()` to revert when `!isPriceSane()`

**New tests**

11. `contracts/test/GoldAllocationAdapterTest.t.sol` — all unit cases from task section 7:
    - aggregator accepts scores for index 5; index 4 still reverts; S1–S4 unchanged
    - executor masks equal 38 and 47 respectively
    - deploy/recall settle in one call, no residual USDC or XAUT
    - stale oracle → `StaleGoldPrice()` revert
    - pool deviation > `maxDeviationBps` → `GoldPriceDeviation()` revert
    - slippage → `SlippageExceeded()` revert
    - combined cap: S2-H + S6-H at boundary → `GoldCapExceeded()`; one unit over → revert
    - deposits paused / redemptions open / lower-price valuation when `!isPriceSane()`
    - timelock setters: wrong role reverts; above hard caps reverts; execute before delay reverts; succeeds after 30 days

12. `contracts/test/FuzzGoldAllocationAdapter.t.sol` — 512 runs:
    - decimal normalisation: `currentValue()` within 1 unit of expected for any `(xautBalance, price)` pair
    - deploy→recall round trip loses ≤ `2 × maxSlippageBps / 10_000` of principal at constant pool price
    - combined gold weight never exceeds `MAX_GOLD_BPS` after any sequence of `deploy`, `deposit`, `redeem` across both gold adapters

**New server file**

13. `server/screening/scorers/scoreGoldAllocation.ts` — S6-H scorer; checks `goldWeight` vs `goldAllocTargetBps ± goldAllocBandBps` and `isPriceSane()`; returns score 0 when unsound; encodes buy/sell direction and USDC amount; polled every 5 minutes independently of other scorers

**Modified server file**

14. `server/shariah-strategies.ts` — import and wire `scoreGoldAllocation`; add to the main score-batch loop at index 5; do not touch indices 0–4

**Modified frontend files**

15. `src/lib/shariahSim.ts` — append `GOLD_ALLOCATION` entry at index 5 (`domain: 0`, no yield); update `CONSERVATIVE_STRATEGY_IDS` to `Set([1, 2, 5])`; add `"No yield — return from gold price only"` note
16. `src/pages/LandingPage.tsx` — add S6-H card (after S4-H, S5-H slot stays retired/commented); update stats 8→9 strategies, 4→5 halal; update Conservative tier to S2-H + S3-H + S6-H; update Dynamic to "all 5 halal"; remove `HALAL` badge from Shariah tab toggle → plain `Shariah`; fix S3-H copy to "Swap-fee income"; add Conservative gold disclosure line
17. `src/pages/StrategiesPage.tsx` — add S6-H row with "no yield" disclosure; Conservative section: show combined gold weight, target, cap
18. `src/components/VaultPicker.tsx` — add S6-H to Conservative strategy list with `(no yield)` annotation
19. `src/components/StrategyScores.tsx` — extend to handle up to 6 Shariah strategies

**New docs**

20. `docs/agents/SHARIAH_REVIEW.md` — add SR-008 through SR-011:
    - SR-008: XAUT — board acceptance of Amanah Advisors certification, custody/allocation terms, qabd hukmi via on-chain transfer
    - SR-009: Holding PAXG (S2-H, uncertified, REVIEW) + XAUT (S6-H) simultaneously; 30% combined cap rationale
    - SR-010: Lower-of-two-prices valuation on redemption during oracle/pool deviation — confirm depositor fairness
    - SR-011: S3-H USDC/PAXG LP — keep or add USDC/XAUT LP; IL disclosure required either way
21. `README.md` — update enum table (add index 5), tier table (new masks), adapter table, permitted assets

---

### Build Sequence

```
1.  contracts/interfaces/AggregatorV3Interface.sol
2.  contracts/test-helpers/MockXAUT.sol
3.  contracts/test-helpers/MockXauUsdAggregator.sol
4.  contracts/test-helpers/MockUniswapV3PoolXAUT.sol  (stripped V3 mock)
5.  contracts/adapters/GoldAllocationAdapter.sol
6.  contracts/ShariahScoreAggregator.sol  (append GOLD_ALLOCATION, extend loops/arrays)
7.  contracts/RiskTieredExecutor.sol  (masks 38 + 47)
8.  contracts/ShariahVault.sol  (gold cap, lower-of-prices, goldAllocationAdapter field)
9.  forge build  — must be zero errors before any tests
10. contracts/test/GoldAllocationAdapterTest.t.sol  (all unit cases)
11. contracts/test/FuzzGoldAllocationAdapter.t.sol  (512 runs)
12. forge test --fuzz-runs 512  — full suite green
13. contracts/script/RedeployShariahAggregator.s.sol
14. contracts/script/DeployGoldAllocation.s.sol
15. server/screening/scorers/scoreGoldAllocation.ts
16. server/shariah-strategies.ts  (wire index 5)
17. src/lib/shariahSim.ts
18. src/pages/LandingPage.tsx  (S6-H card, badge fix, S3-H copy fix)
19. src/pages/StrategiesPage.tsx
20. src/components/VaultPicker.tsx
21. src/components/StrategyScores.tsx
22. docs/agents/SHARIAH_REVIEW.md  (SR-008 to SR-011)
23. README.md
24. bun run check  — zero errors
```

---

### Done When

- [ ] `ShariahScoreAggregator.writeScore(5, ...)` accepted; `writeScore(4, ...)` still reverts `StrategyDeprecated`
- [ ] `SHARIAH_CONSERVATIVE` mask is `38` (0b100110); `SHARIAH_DYNAMIC` mask is `47` (0b101111)
- [ ] `GoldAllocationAdapter.deploy()` completes in one transaction; no USDC or XAUT stranded
- [ ] Stale oracle → `StaleGoldPrice()`; pool deviation > cap → `GoldPriceDeviation()`
- [ ] Combined S2-H + S6-H value exceeding `MAX_GOLD_BPS` → `GoldCapExceeded()` on the next deploy
- [ ] Deposits revert when `isPriceSane()` is false; redemptions remain open using lower-of-prices
- [ ] All board-settable params (`maxSlippageBps`, `maxDeviationBps`, `maxStalenessSecs`) reject changes before 30-day timelock elapses
- [ ] `GoldAllocationAdapter`: wrong-role setter reverts; above-hard-cap setter reverts
- [ ] Fuzz: `currentValue()` within 1 unit of expected for any `(balance, price)` pair (512 runs)
- [ ] Fuzz: deploy→recall round trip loses ≤ `2 × maxSlippageBps / 10_000` at constant price (512 runs)
- [ ] Fuzz: combined gold weight never exceeds `MAX_GOLD_BPS` after any deposit/deploy/redeem sequence (512 runs)
- [ ] MockXAUT has 6 decimals; adapter reads `decimals()` at construction — no hardcoded decimals anywhere
- [ ] `RedeployShariahAggregator.s.sol` compiles; re-applies certified[0..3] = true, certified[4..5] = false
- [ ] `DeployGoldAllocation.s.sol` compiles; records all addresses
- [ ] S6-H card visible in UI with "No yield" disclosure; Conservative disclosure shows gold weight
- [ ] `HALAL` badge removed from Shariah toggle in LandingPage
- [ ] S3-H copy reads "Swap-fee income" not "Musharakah fee income only"
- [ ] SR-008 through SR-011 in `SHARIAH_REVIEW.md`
- [ ] `forge build` zero errors; `bun run check` zero errors
- [ ] All 200 existing tests still green

---

### Notes recorded at approval time

**The stripped Uniswap V3 pool mock adds real scope.** A genuine V3 pool (`IUniswapV3Pool`) requires implementing `slot0()`, `swap()` with callback routing, and `sqrtPriceX96` ↔ price conversion. The mock does not need to be a full fork — it only needs to satisfy the three calls `GoldAllocationAdapter` makes: `slot0()` (to read pool price for deviation check) and `exactInputSingle()` on the router (to execute the swap). The stripped mock stores a settable `sqrtPriceX96`, returns it from `slot0()`, and executes swaps at that price. That is roughly 80–100 lines of Solidity, not 3,000+.

**The 30-day timelock on param changes has a testnet usability cost.** Setting `maxSlippageBps` or `maxDeviationBps` for the first time requires proposing a change, then warping `block.timestamp` forward 30 days in tests, then executing. Tests handle this with `vm.warp`. But any live testnet operator wanting to tune these params will wait a real 30 days per change. That is the intended behaviour per your answer — flagging it so there are no surprises.

**Redeploy of `ShariahScoreAggregator` loses score history.** The contract is not upgradeable and the enum must grow from 5 to 6 entries. `RedeployShariahAggregator.s.sol` will log a clear warning and re-apply all enabled flags. The old aggregator address should be kept in `deployed-addresses.md` as `DEPRECATED_ShariahScoreAggregator_v1` so indexers can still read historical data from it.

**Order of F within the overall sequence.** The task file says "Do this task before Task E; v2 reuses this adapter." So the order becomes: A (done) → C (done) → **F** → B → D → E. The plan file records this correctly in the build sequence.
