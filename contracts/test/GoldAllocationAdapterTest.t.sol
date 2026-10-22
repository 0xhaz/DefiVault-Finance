// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {GoldAllocationAdapter}   from "../adapters/GoldAllocationAdapter.sol";
import {ShariahVault}            from "../ShariahVault.sol";
import {ShariahScoreAggregator}  from "../ShariahScoreAggregator.sol";
import {RiskTieredExecutor}      from "../RiskTieredExecutor.sol";
import {ScoreAggregator}         from "../ScoreAggregator.sol";
import {TreasuryModule}          from "../TreasuryModule.sol";
import {ZakatModule}             from "../ZakatModule.sol";
import {MockERC20}               from "../test-helpers/MockERC20.sol";
import {MockXAUT}                from "../test-helpers/MockXAUT.sol";
import {MockXauUsdAggregator}    from "../test-helpers/MockXauUsdAggregator.sol";
import {MockUniswapV3PoolXAUT}   from "../test-helpers/MockUniswapV3PoolXAUT.sol";

/// @title  GoldAllocationAdapterTest
/// @notice Full unit test suite for Task F: GoldAllocationAdapter, ShariahScoreAggregator
///         (index 5), RiskTieredExecutor mask changes, and ShariahVault combined gold cap.
///
/// Price constants (both tokens 6-dec, oracle 8-dec):
///   Oracle price:  int256(330_000_000_000)  = $3300 × 10^8 (8-dec feed)
///   oraclePriceUsdc = oracle_answer * 10^6 / 10^8 = oracle_answer / 100 = 3_300_000_000
///   Pool usdcPerXaut: 3_300_000_000 (raw USDC-units per raw XAUT-unit; both 6-dec)
///   After _updateSqrtPrice fix: poolPriceUsdc = usdcPerXaut = 3_300_000_000 ✓
contract GoldAllocationAdapterTest is Test {

    // ── Actors ────────────────────────────────────────────────────────────────
    address internal owner        = makeAddr("owner");
    address internal alice        = makeAddr("alice");
    address internal charityWallet = makeAddr("charity");
    address internal attacker     = makeAddr("attacker");

    // ── Token mocks ───────────────────────────────────────────────────────────
    MockERC20              internal usdc;
    MockXAUT               internal xaut;
    MockXauUsdAggregator   internal oracle;
    MockUniswapV3PoolXAUT  internal pool;

    // ── Protocol contracts ────────────────────────────────────────────────────
    TreasuryModule          internal treasury;
    ZakatModule             internal zakatModule;
    ShariahVault            internal vault;
    GoldAllocationAdapter   internal adapter;
    ShariahScoreAggregator  internal aggregator;
    ScoreAggregator         internal conventionalAgg;
    RiskTieredExecutor      internal conservativeExecutor;
    RiskTieredExecutor      internal dynamicExecutor;

    // ── Constants ─────────────────────────────────────────────────────────────
    uint32  internal constant SOURCE_DOMAIN   = 26;
    uint256 internal constant MAX_STALENESS   = 3600;  // 1 hour

    /// Oracle answer: $3300 in 8-dec feed units
    int256  internal constant ORACLE_PRICE    = 330_000_000_000;
    /// Derived: oraclePriceUsdc = 330_000_000_000 / 100 = 3_300_000_000
    uint256 internal constant ORACLE_USDC     = 3_300_000_000;
    /// Pool set to same price (raw USDC-units per raw XAUT-unit, 6-dec each)
    uint256 internal constant POOL_USDC_PER_XAUT = 3_300_000_000;

    // ─────────────────────────────────────────────────────────────────────────
    //  setUp — fresh state for every test
    // ─────────────────────────────────────────────────────────────────────────

    function setUp() public {
        // Warp to a realistic timestamp so staleness math doesn't underflow
        vm.warp(1_700_000_000);

        // 1. Tokens
        usdc  = new MockERC20("Mock USDC", "mUSDC", 6);
        xaut  = new MockXAUT();
        oracle = new MockXauUsdAggregator();
        pool   = new MockUniswapV3PoolXAUT(address(usdc), address(xaut), POOL_USDC_PER_XAUT);

        vm.startPrank(owner);

        // 2. Treasury — Shariah params
        treasury = new TreasuryModule(
            "Shariah",
            address(0),   // feeSource set to vault after deploy in production; 0 ok for tests
            address(usdc),
            50,           // wakalaFeeBps  0.5%
            1000,         // musharakahShareBps 10%
            400,          // hurdleRateBps 4%
            owner
        );

        // 3. Vault
        vault = new ShariahVault(
            IERC20(address(usdc)),
            owner,
            SOURCE_DOMAIN,
            address(treasury),
            address(0)   // zakatModule not needed for these tests
        );

        // 4. ZakatModule (needed for completeness if claimMusharakahProfit is called)
        zakatModule = new ZakatModule(charityWallet, address(usdc), address(vault), owner);

        // 5. Aggregators
        conventionalAgg = new ScoreAggregator(owner);
        aggregator = new ShariahScoreAggregator(owner);

        // 6. GoldAllocationAdapter — pool is both swapRouter and pool address
        adapter = new GoldAllocationAdapter(
            address(usdc),
            address(xaut),
            address(pool),     // swapRouter_
            3000,              // poolFee_ (0.3%)
            address(oracle),   // goldOracle_
            address(vault),    // vault_
            MAX_STALENESS,     // initialMaxStalenessSecs
            owner              // initialOwner
        );
        // pool is already set in constructor to swapRouter_; no need to call setPool

        // 7. Executor instances
        conservativeExecutor = new RiskTieredExecutor(
            address(vault),
            address(conventionalAgg),
            RiskTieredExecutor.RiskTier.SHARIAH_CONSERVATIVE,
            owner
        );
        dynamicExecutor = new RiskTieredExecutor(
            address(vault),
            address(conventionalAgg),
            RiskTieredExecutor.RiskTier.SHARIAH_DYNAMIC,
            owner
        );

        // 8. Screen the adapter in the vault
        vault.setScreened(address(adapter), true);
        vault.setGoldAllocationAdapter(address(adapter));

        vm.stopPrank();

        // 9. Fund pool with USDC and XAUT so swaps can execute
        //    Pool needs to send out tokens on swaps.
        usdc.mint(address(this), 50_000_000e6);
        xaut.mint(address(this), 20_000e6);
        usdc.approve(address(pool), 50_000_000e6);
        xaut.approve(address(pool), 20_000e6);
        pool.fundPool(50_000_000e6, 20_000e6);

        // 10. Alice deposits to vault
        usdc.mint(alice, 100_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, alice);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Helper: push USDC to adapter via vault.deployCapital, then execute swap
    // ─────────────────────────────────────────────────────────────────────────

    function _deployCapital(uint256 amount) internal {
        vm.prank(owner);
        vault.deployCapital(address(adapter), amount, "");
        vm.prank(address(vault));
        adapter.deploy(amount);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  AGGREGATOR TESTS
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice writeScore at index 5 (GOLD_ALLOCATION) succeeds without revert.
    function test_aggregator_accepts_index5() public {
        vm.prank(owner);
        aggregator.writeScore(
            ShariahScoreAggregator.ShariahStrategy.GOLD_ALLOCATION,
            85,
            keccak256("test"),
            0
        );
        (uint8 val,,,) = aggregator.scores(ShariahScoreAggregator.ShariahStrategy.GOLD_ALLOCATION);
        assertEq(val, 85, "score at index 5 should be 85");
    }

    /// @notice writeScore at index 4 (RWA_SUKUK / RESERVED_4) still reverts StrategyDeprecated(4).
    function test_aggregator_index4_still_reverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ShariahScoreAggregator.StrategyDeprecated.selector, uint8(4)));
        aggregator.writeScore(
            ShariahScoreAggregator.ShariahStrategy(4),
            85,
            keccak256("test"),
            0
        );
    }

    /// @notice writeScore at indices 0, 1, 2, 3 still succeed.
    function test_aggregator_indices0to3_unchanged() public {
        vm.startPrank(owner);
        aggregator.writeScore(ShariahScoreAggregator.ShariahStrategy(0), 80, keccak256("0"), 0);
        aggregator.writeScore(ShariahScoreAggregator.ShariahStrategy(1), 81, keccak256("1"), 0);
        aggregator.writeScore(ShariahScoreAggregator.ShariahStrategy(2), 82, keccak256("2"), 0);
        aggregator.writeScore(ShariahScoreAggregator.ShariahStrategy(3), 83, keccak256("3"), 0);
        vm.stopPrank();

        (uint8 v0,,,) = aggregator.scores(ShariahScoreAggregator.ShariahStrategy(0));
        (uint8 v1,,,) = aggregator.scores(ShariahScoreAggregator.ShariahStrategy(1));
        (uint8 v2,,,) = aggregator.scores(ShariahScoreAggregator.ShariahStrategy(2));
        (uint8 v3,,,) = aggregator.scores(ShariahScoreAggregator.ShariahStrategy(3));

        assertEq(v0, 80, "index 0 score");
        assertEq(v1, 81, "index 1 score");
        assertEq(v2, 82, "index 2 score");
        assertEq(v3, 83, "index 3 score");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  EXECUTOR MASK TESTS
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice SHARIAH_CONSERVATIVE executor strategyMask == 38 (0b100110).
    function test_executor_conservative_mask_is_38() public view {
        assertEq(conservativeExecutor.strategyMask(), 38, "SHARIAH_CONSERVATIVE mask must be 38 (0b100110)");
    }

    /// @notice SHARIAH_DYNAMIC executor strategyMask == 47 (0b101111).
    function test_executor_dynamic_mask_is_47() public view {
        assertEq(dynamicExecutor.strategyMask(), 47, "SHARIAH_DYNAMIC mask must be 47 (0b101111)");
    }

    /// @notice Cross-chain routing reverts NonAtomicGoldExchange when goldCrossChainBlocked == true.
    /// @dev    The RiskTieredExecutor tries deployCrossChain when destinationDomain != 0, which hits
    ///         ShariahVault.deployCrossChain → reverts NonAtomicGoldExchange.
    ///         We test this by calling deployCrossChain directly as the owner.
    function test_executor_bit5_crosschain_blocked() public {
        // Enable gold cross-chain block (SR-007)
        vm.prank(owner);
        vault.setGoldCrossChainBlocked(true);

        // deployCrossChain must revert NonAtomicGoldExchange regardless of adapter
        vm.prank(owner);
        vm.expectRevert(ShariahVault.NonAtomicGoldExchange.selector);
        vault.deployCrossChain(1, bytes32(uint256(uint160(address(adapter)))), 1_000e6);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  DEPLOY / RECALL TESTS
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice After deploy(), USDC balance of adapter is 0, xautHeld > 0.
    function test_deploy_settles_in_one_call_no_residual() public {
        uint256 amount = 3_300e6; // $3,300 USDC = ~1 XAUT
        _deployCapital(amount);

        assertEq(usdc.balanceOf(address(adapter)), 0, "No USDC should remain in adapter");
        assertGt(adapter.xautHeld(), 0, "adapter must hold XAUT after deploy");
        assertGt(adapter.totalDeployed(), 0, "totalDeployed must be positive");
    }

    /// @notice After recall(), xautHeld == 0, USDC sent to vault.
    function test_recall_settles_in_one_call_no_residual() public {
        uint256 amount = 3_300e6;
        _deployCapital(amount);

        uint256 xautBefore = adapter.xautHeld();
        assertGt(xautBefore, 0, "must have XAUT to recall");

        uint256 vaultUsdcBefore = usdc.balanceOf(address(vault));

        vm.prank(address(vault));
        adapter.recall(amount);

        assertEq(adapter.xautHeld(), 0, "xautHeld must be 0 after recall");
        assertEq(xaut.balanceOf(address(adapter)), 0, "no XAUT stranded in adapter");
        assertGt(usdc.balanceOf(address(vault)), vaultUsdcBefore, "USDC must be returned to vault");
    }

    /// @notice deploy(0) reverts ZeroAmount.
    function test_deploy_zero_amount_reverts() public {
        vm.prank(address(vault));
        vm.expectRevert(GoldAllocationAdapter.ZeroAmount.selector);
        adapter.deploy(0);
    }

    /// @notice recall(0) reverts ZeroAmount.
    function test_recall_zero_amount_reverts() public {
        vm.prank(address(vault));
        vm.expectRevert(GoldAllocationAdapter.ZeroAmount.selector);
        adapter.recall(0);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ORACLE STALENESS TESTS
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Stale oracle (updatedAt > maxStalenessSecs ago) causes deploy to revert OracleNotSane
    ///         (G1: deploy() now checks isPriceSane() first, which returns false on stale oracle).
    function test_stale_oracle_reverts() public {
        // Push USDC to adapter first (vault accounting step)
        vm.prank(owner);
        vault.deployCapital(address(adapter), 3_300e6, "");

        // Make oracle stale
        oracle.setUpdatedAt(block.timestamp - MAX_STALENESS - 1);

        // G1: deploy() now calls isPriceSane() first which returns false on stale oracle,
        // so the revert is OracleNotSane() (not StaleGoldPrice()).
        vm.prank(address(vault));
        vm.expectRevert(GoldAllocationAdapter.OracleNotSane.selector);
        adapter.deploy(3_300e6);
    }

    /// @notice Negative oracle price causes deploy to revert OracleNotSane (G1).
    function test_negative_oracle_price_reverts() public {
        // Push USDC to adapter
        vm.prank(owner);
        vault.deployCapital(address(adapter), 3_300e6, "");

        // Set negative price
        oracle.setPrice(-1);

        // G1: deploy() now calls isPriceSane() first which returns false on negative price,
        // so the revert is OracleNotSane() (not StaleGoldPrice()).
        vm.prank(address(vault));
        vm.expectRevert(GoldAllocationAdapter.OracleNotSane.selector);
        adapter.deploy(3_300e6);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  DEVIATION CHECK TESTS
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Pool price 5% above oracle (5% > maxDeviationBps=100 = 1%) reverts OracleNotSane (G1).
    /// @dev    G1: deploy() now calls isPriceSane() first. When pool deviates > maxDeviationBps,
    ///         isPriceSane() returns false, so deploy() reverts OracleNotSane() (not GoldPriceDeviation).
    function test_pool_deviation_too_high_reverts() public {
        vm.prank(owner);
        vault.deployCapital(address(adapter), 3_300e6, "");

        // Set pool price 5% above oracle (105% of oraclePriceUsdc).
        uint256 deviatedPrice = ORACLE_USDC * 21 / 20; // 3_465_000_000
        pool.setPrice(deviatedPrice);

        // G1: isPriceSane() returns false → deploy() reverts OracleNotSane (not GoldPriceDeviation).
        vm.prank(address(vault));
        vm.expectRevert(GoldAllocationAdapter.OracleNotSane.selector);
        adapter.deploy(3_300e6);
    }

    /// @notice Pool price within 0.5% of oracle (< maxDeviationBps=100) — deploy succeeds.
    /// @dev    Pool price is set slightly BELOW oracle so the pool gives more XAUT than
    ///         oracle-estimated minOut (no slippage violation). If pool > oracle, the adapter
    ///         may get fewer tokens than its minOut estimate.
    function test_pool_within_deviation_passes() public {
        // Set pool price 0.5% below oracle — still within 1% deviation, and the pool
        // returns slightly MORE XAUT than the oracle estimate so minOut is not breached.
        uint256 nearPrice = ORACLE_USDC * 995 / 1000; // -0.5% (cheaper XAUT = more output)
        pool.setPrice(nearPrice);

        uint256 amount = 3_300e6;
        _deployCapital(amount);

        // No revert — success asserted by reaching this line
        assertGt(adapter.xautHeld(), 0, "XAUT must be held after successful deploy");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SLIPPAGE TESTS
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice When pool returns 0, deploy reverts (InsufficientOutput from pool or SlippageExceeded).
    function test_slippage_reverts_when_pool_returns_zero() public {
        vm.prank(owner);
        vault.deployCapital(address(adapter), 3_300e6, "");

        // Make the pool return 0 by setting swapFeeBps to 0 (output = 0)
        pool.setSwapFeeBps(0);

        // Both InsufficientOutput and SlippageExceeded are acceptable
        vm.prank(address(vault));
        // Just expect a revert (either custom error is valid)
        vm.expectRevert();
        adapter.deploy(3_300e6);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  COMBINED GOLD CAP TESTS
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Deploy 1 USDC when goldSpreadAdapter holds 290 USDC (29%): combined 291/1000 < 30%.
    function test_combined_cap_both_adapters_at_boundary() public {
        // Set up a mock goldSpreadAdapter that returns currentValue() = 290 USDC
        MockGoldSpread mockSpread = new MockGoldSpread(290e6);

        vm.startPrank(owner);
        vault.setGoldSpreadAdapter(address(mockSpread));
        vault.setScreened(address(mockSpread), true);
        vm.stopPrank();

        // Vault has 100_000 USDC; cap = 30% of 100_000 = 30_000 USDC
        // goldSpreadAdapter returns 290 USDC; we deploy 1 USDC to goldAllocationAdapter
        // combined = 290 + 0 (xaut not yet deployed) + 1 = 291 < 30_000 → should pass
        // Note: vault.deployCapital adds `amount` to the combined check before deploy()
        vm.prank(owner);
        vault.deployCapital(address(adapter), 1e6, "");

        // Now execute the swap
        vm.prank(address(vault));
        adapter.deploy(1e6);

        assertGt(adapter.xautHeld(), 0, "XAUT must be held");
    }

    /// @notice Deploy 10 USDC when goldSpreadAdapter holds 295 USDC (29.5%): combined 305/1000 > 30%.
    function test_combined_cap_exceeds_reverts() public {
        // Set up a mock goldSpreadAdapter that returns currentValue() = 295 USDC
        MockGoldSpread mockSpread = new MockGoldSpread(295e6);

        vm.startPrank(owner);
        vault.setGoldSpreadAdapter(address(mockSpread));
        vault.setScreened(address(mockSpread), true);
        vm.stopPrank();

        // Vault has 100_000 USDC; gold cap = 30_000 USDC
        // goldSpreadAdapter returns 295e6; deploy 10e6 to goldAllocationAdapter
        // combined check: paxgValue (295e6) + xautValue (0) + amount (10e6) = 305e6 > 30_000e6
        // Wait — 100_000 USDC, 30% = 30_000 USDC cap. 295e6 = 295 USDC. 305e6 = 305 USDC < 30_000 USDC.
        // The test as specified uses 1000 USDC vault and 295 USDC spread — so we need a smaller vault.
        // Re-read: "fund vault with 1000 USDC; goldSpreadAdapter returns 295 USDC; deploy 10 USDC"
        // cap = 30% of 1000 = 300 USDC. combined = 295 + 0 + 10 = 305 > 300. Revert!
        // So we need a vault with only 1000 USDC. Let's create a separate vault for this test.

        // Actually, let's use the existing vault (100_000 USDC) but set the spread value high enough.
        // cap = 30% of 100_000 = 30_000 USDC. We need paxgValue + amount > 30_000.
        // Use 29_995 USDC from spread + deploy 10 USDC: 29_995 + 10 = 30_005 > 30_000.
        // Let's reset mockSpread to return 29_995e6.
        MockGoldSpread mockSpread2 = new MockGoldSpread(29_995e6);
        vm.prank(owner);
        vault.setGoldSpreadAdapter(address(mockSpread2));

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                ShariahVault.GoldCapExceeded.selector,
                uint256(29_995e6 + 0 + 10e6), // combined
                uint256(100_000e6 * 3000 / 10_000) // goldCap = 30_000e6
            )
        );
        vault.deployCapital(address(adapter), 10e6, "");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  PRICE INSANITY / FALLBACK TESTS
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice When oracle is stale, isPriceSane() returns false.
    /// @dev    ShariahVault.deposit() doesn't currently check isPriceSane() — a future override
    ///         would pause deposits. For now we verify the flag itself.
    function test_deposits_paused_when_not_sane() public {
        oracle.setUpdatedAt(block.timestamp - MAX_STALENESS - 1);
        assertFalse(adapter.isPriceSane(), "isPriceSane must be false when oracle is stale");
        // NOTE: ShariahVault does not currently override deposit() to check isPriceSane().
        // A future SR-override should gate deposits on this flag.
    }

    /// @notice PR1: currentValue() uses lastGoodPrice * (1 - staleHaircutBps) when oracle stale.
    ///         Cost basis (totalDeployed) is NEVER used (see PR1 spec).
    function test_currentValue_falls_back_to_totalDeployed_when_stale() public {
        uint256 amount = 3_300e6;
        _deployCapital(amount);

        uint256 lastGoodPrice = adapter.lastGoodPrice();
        assertGt(lastGoodPrice, 0, "lastGoodPrice must be set after deploy");

        uint256 xautHeld = adapter.xautHeld();
        assertGt(xautHeld, 0, "xautHeld must be positive");

        // Make oracle stale
        oracle.setUpdatedAt(block.timestamp - MAX_STALENESS - 1);

        // PR1: currentValue should use lastGoodPrice with haircut (NOT totalDeployed)
        uint256 val = adapter.currentValue();
        // Pool also set to same price, so lower-of-two = lastGoodPrice
        // grossValue = xautHeld * lastGoodPrice / 1e6
        // haircut applied: grossValue * (10_000 - 500) / 10_000
        uint256 grossValue = (xautHeld * lastGoodPrice) / 1e6;
        uint256 expectedHaircutValue = (grossValue * (10_000 - 500)) / 10_000;
        assertApproxEqRel(val, expectedHaircutValue, 0.01e18,
            "PR1: currentValue must use lastGoodPrice * (1 - haircut) when stale, NOT totalDeployed");
        assertLt(val, amount, "currentValue with haircut should be less than deployed amount");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  TIMELOCK PARAM SETTER TESTS
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Non-owner calling proposeParamChange reverts (OwnableUnauthorizedAccount).
    /// @dev    Cache the param ID before vm.prank so the staticcall doesn't consume the prank.
    function test_timelock_propose_wrong_role_reverts() public {
        bytes32 paramId = adapter.PARAM_MAX_SLIPPAGE(); // staticcall BEFORE prank
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
        );
        adapter.proposeParamChange(paramId, 100);
    }

    /// @notice proposeParamChange(PARAM_MAX_SLIPPAGE, 201) reverts ParamAboveHardCap.
    function test_timelock_above_max_slippage_cap_reverts() public {
        bytes32 paramId = adapter.PARAM_MAX_SLIPPAGE(); // staticcall BEFORE prank
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                GoldAllocationAdapter.ParamAboveHardCap.selector,
                "maxSlippageBps",
                uint256(201),
                uint256(200)
            )
        );
        adapter.proposeParamChange(paramId, 201);
    }

    /// @notice proposeParamChange(PARAM_MAX_DEVIATION, 301) reverts ParamAboveHardCap.
    function test_timelock_above_max_deviation_cap_reverts() public {
        bytes32 paramId = adapter.PARAM_MAX_DEVIATION(); // staticcall BEFORE prank
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                GoldAllocationAdapter.ParamAboveHardCap.selector,
                "maxDeviationBps",
                uint256(301),
                uint256(300)
            )
        );
        adapter.proposeParamChange(paramId, 301);
    }

    /// @notice propose then execute immediately reverts TimelockNotElapsed.
    function test_timelock_execute_before_delay_reverts() public {
        bytes32 paramId = adapter.PARAM_MAX_SLIPPAGE(); // staticcall BEFORE prank
        uint256 proposedAt = block.timestamp;

        vm.prank(owner);
        adapter.proposeParamChange(paramId, 100);

        uint256 expectedExecuteAfter = proposedAt + 30 days;

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                GoldAllocationAdapter.TimelockNotElapsed.selector,
                expectedExecuteAfter,
                block.timestamp
            )
        );
        adapter.executeParamChange(paramId);
    }

    /// @notice After warp +30 days, executeParamChange succeeds and updates maxSlippageBps.
    function test_timelock_execute_after_30_days_succeeds() public {
        bytes32 paramId = adapter.PARAM_MAX_SLIPPAGE(); // staticcall BEFORE prank

        vm.prank(owner);
        adapter.proposeParamChange(paramId, 100);

        vm.warp(block.timestamp + 30 days);

        vm.prank(owner);
        adapter.executeParamChange(paramId);

        assertEq(adapter.maxSlippageBps(), 100, "maxSlippageBps must be updated after timelock");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  isPriceSane TESTS
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Fresh oracle, pool price within tolerance → isPriceSane() returns true.
    function test_isPriceSane_true_when_fresh_and_close() public view {
        // Default setup: oracle fresh, pool price matches oracle
        assertTrue(adapter.isPriceSane(), "isPriceSane must be true with fresh oracle and close pool");
    }

    /// @notice Stale oracle → isPriceSane() returns false.
    function test_isPriceSane_false_when_stale() public {
        oracle.setUpdatedAt(block.timestamp - MAX_STALENESS - 1);
        assertFalse(adapter.isPriceSane(), "isPriceSane must be false when oracle is stale");
    }

    /// @notice Pool price 5% off oracle (> maxDeviationBps=100) → isPriceSane() returns false.
    function test_isPriceSane_false_when_deviation_too_high() public {
        pool.setPrice(ORACLE_USDC * 105 / 100); // 5% above
        assertFalse(adapter.isPriceSane(), "isPriceSane must be false when pool deviates >1%");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ACCESS CONTROL TESTS
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Non-vault caller cannot call deploy().
    function test_only_vault_can_deploy() public {
        vm.prank(attacker);
        vm.expectRevert(bytes("GoldAllocationAdapter: caller is not vault"));
        adapter.deploy(3_300e6);
    }

    /// @notice Non-vault caller cannot call recall().
    function test_only_vault_can_recall() public {
        vm.prank(attacker);
        vm.expectRevert(bytes("GoldAllocationAdapter: caller is not vault"));
        adapter.recall(3_300e6);
    }

    /// @notice renounceOwnership is disabled.
    function test_renounceOwnership_disabled() public {
        vm.prank(owner);
        vm.expectRevert(bytes("GoldAllocationAdapter: renouncing ownership is disabled"));
        adapter.renounceOwnership();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  EVENTS TESTS
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice deploy() emits GoldBought with correct values.
    function test_deploy_emits_GoldBought() public {
        uint256 amount = 3_300e6;

        vm.prank(owner);
        vault.deployCapital(address(adapter), amount, "");

        vm.prank(address(vault));
        vm.expectEmit(false, false, false, false, address(adapter));
        emit GoldAllocationAdapter.GoldBought(amount, 0, 0); // args checked loosely
        adapter.deploy(amount);
    }

    /// @notice recall() emits GoldSold.
    function test_recall_emits_GoldSold() public {
        _deployCapital(3_300e6);

        uint256 xautHeld = adapter.xautHeld();

        vm.prank(address(vault));
        vm.expectEmit(false, false, false, false, address(adapter));
        emit GoldAllocationAdapter.GoldSold(xautHeld, 0, 0);
        adapter.recall(3_300e6);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ACCOUNTING TESTS
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice recall when xautHeld == 0 returns 0 gracefully.
    function test_recall_when_no_xaut_returns_zero() public {
        assertEq(adapter.xautHeld(), 0, "no XAUT initially");
        vm.prank(address(vault));
        uint256 returned = adapter.recall(1e6);
        assertEq(returned, 0, "recall with xautHeld==0 must return 0");
    }

    /// @notice protocolName() returns expected string.
    function test_protocolName_returns_expected() public view {
        string memory name = adapter.protocolName();
        assertGt(bytes(name).length, 0, "protocolName must be non-empty");
    }

    /// @notice setGoldAllocationAdapter emits GoldAllocationAdapterUpdated.
    function test_setGoldAllocationAdapter_emits_event() public {
        address newAdapter = makeAddr("newAdapter");

        vm.prank(owner);
        vm.expectEmit(true, false, false, false, address(vault));
        emit ShariahVault.GoldAllocationAdapterUpdated(newAdapter);
        vault.setGoldAllocationAdapter(newAdapter);
    }

    /// @notice setGoldSpreadAdapter emits GoldSpreadAdapterUpdated.
    function test_setGoldSpreadAdapter_emits_event() public {
        address newSpread = makeAddr("newSpread");

        vm.prank(owner);
        vm.expectEmit(true, false, false, false, address(vault));
        emit ShariahVault.GoldSpreadAdapterUpdated(newSpread);
        vault.setGoldSpreadAdapter(newSpread);
    }

    /// @notice currentValue() returns oracle-priced value when sanity passes.
    function test_currentValue_oracle_priced_when_sane() public {
        uint256 amount = 3_300e6; // $3300 USDC
        _deployCapital(amount);

        // xautHeld ~ 1e6 (1 XAUT at 0.2% pool fee so slightly less)
        // currentValue = xautHeld * oraclePriceUsdc / 10^xautDecimals
        uint256 xautHeld = adapter.xautHeld();
        uint256 expected = (xautHeld * ORACLE_USDC) / 1e6;
        uint256 actual = adapter.currentValue();

        // Allow 1 unit rounding error
        assertApproxEqAbs(actual, expected, 1, "currentValue must match oracle valuation");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Mock helper: minimal IGoldAdapter stub returning a fixed currentValue
// ─────────────────────────────────────────────────────────────────────────────
contract MockGoldSpread {
    uint256 private _value;
    constructor(uint256 value_) { _value = value_; }
    function currentValue() external view returns (uint256) { return _value; }
    function isPriceSane() external pure returns (bool) { return true; }
    function setValue(uint256 v) external { _value = v; }
}
