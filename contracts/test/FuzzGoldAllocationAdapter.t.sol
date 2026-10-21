// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// forge-config: default.fuzz.runs = 512

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GoldAllocationAdapter}   from "../adapters/GoldAllocationAdapter.sol";
import {ShariahVault}            from "../ShariahVault.sol";
import {TreasuryModule}          from "../TreasuryModule.sol";
import {MockERC20}               from "../test-helpers/MockERC20.sol";
import {MockXAUT}                from "../test-helpers/MockXAUT.sol";
import {MockXauUsdAggregator}    from "../test-helpers/MockXauUsdAggregator.sol";
import {MockUniswapV3PoolXAUT}   from "../test-helpers/MockUniswapV3PoolXAUT.sol";

/// @title  FuzzGoldAllocationAdapter
/// @notice Property-based tests for GoldAllocationAdapter (Task F).
///
/// Fuzz runs: 512 (set via inline forge-config above and --fuzz-runs flag).
///
/// Price setup (same as unit tests):
///   Oracle answer:  330_000_000_000  (8-dec, = $3300)
///   oraclePriceUsdc = answer / 100 = 3_300_000_000
///   Pool usdcPerXaut = 3_300_000_000 (matching oracle)
contract FuzzGoldAllocationAdapter is Test {

    // ── Actors ─────────────────────────────────────────────────────────────
    address internal owner   = makeAddr("owner");
    address internal alice   = makeAddr("alice");

    // ── Tokens ─────────────────────────────────────────────────────────────
    MockERC20             internal usdc;
    MockXAUT              internal xaut;
    MockXauUsdAggregator  internal oracle;
    MockUniswapV3PoolXAUT internal pool;

    // ── Protocol ───────────────────────────────────────────────────────────
    TreasuryModule        internal treasury;
    ShariahVault          internal vault;
    GoldAllocationAdapter internal adapter;

    // ── Constants ──────────────────────────────────────────────────────────
    uint32  internal constant SOURCE_DOMAIN       = 26;
    uint256 internal constant MAX_STALENESS       = 3600;
    int256  internal constant DEFAULT_ORACLE_PRICE = 330_000_000_000;   // $3300 × 10^8
    uint256 internal constant DEFAULT_ORACLE_USDC  = 3_300_000_000;     // 3300 USDC (6-dec)
    uint256 internal constant DEFAULT_POOL_PRICE   = 3_300_000_000;

    // ── Pool liquidity budget ───────────────────────────────────────────────
    // Pool must hold enough for all swap scenarios. Fund generously.
    uint256 internal constant POOL_USDC_SEED = 500_000_000e6;   // 500M USDC
    uint256 internal constant POOL_XAUT_SEED = 200_000e6;       // 200k XAUT

    function setUp() public {
        // Warp to a realistic timestamp so staleness math (block.timestamp - updatedAt) doesn't underflow
        vm.warp(1_700_000_000);

        usdc   = new MockERC20("Mock USDC", "mUSDC", 6);
        xaut   = new MockXAUT();
        oracle = new MockXauUsdAggregator();
        pool   = new MockUniswapV3PoolXAUT(address(usdc), address(xaut), DEFAULT_POOL_PRICE);

        vm.startPrank(owner);
        treasury = new TreasuryModule(
            "Shariah",
            address(0),
            address(usdc),
            50, 1000, 400,
            owner
        );
        vault = new ShariahVault(
            IERC20(address(usdc)),
            owner,
            SOURCE_DOMAIN,
            address(treasury),
            address(0)
        );
        adapter = new GoldAllocationAdapter(
            address(usdc),
            address(xaut),
            address(pool),
            3000,
            address(oracle),
            address(vault),
            MAX_STALENESS,
            owner
        );
        vault.setScreened(address(adapter), true);
        vault.setGoldAllocationAdapter(address(adapter));
        vm.stopPrank();

        // Fund pool
        usdc.mint(address(this), POOL_USDC_SEED);
        xaut.mint(address(this), POOL_XAUT_SEED);
        usdc.approve(address(pool), POOL_USDC_SEED);
        xaut.approve(address(pool), POOL_XAUT_SEED);
        pool.fundPool(POOL_USDC_SEED, POOL_XAUT_SEED);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Helpers
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Fund vault from alice, returns shares minted.
    function _fund(uint256 usdcAmount) internal {
        usdc.mint(alice, usdcAmount);
        vm.startPrank(alice);
        usdc.approve(address(vault), usdcAmount);
        vault.deposit(usdcAmount, alice);
        vm.stopPrank();
    }

    /// @dev deployCapital + adapter.deploy()
    function _deploy(uint256 amount) internal {
        vm.prank(owner);
        vault.deployCapital(address(adapter), amount, "");
        vm.prank(address(vault));
        adapter.deploy(amount);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Fuzz 1: currentValue within 1 unit of expected
    // ─────────────────────────────────────────────────────────────────────

    /// @notice currentValue() = xautHeld * oraclePrice / 10^xautDecimals.
    ///         We test the formula directly: deploy a fixed USDC amount at varying oracle
    ///         prices and verify |currentValue() - expected| <= 1 (integer division rounding).
    ///         Strategy: fund vault → deploy → check formula.
    function testFuzz_currentValue_within_1_unit(
        uint128 usdcAmount,
        uint128 priceAnswer
    ) public {
        // Bound: 1 USDC to 1_000 USDC (6-dec), small enough to fit in pool and cap
        usdcAmount = uint128(bound(usdcAmount, 1e6, 1_000e6));
        // Bound: 8-dec oracle price $100–$10_000/oz
        priceAnswer = uint128(bound(priceAnswer, 100e8, 10_000e8));

        // Compute expected oraclePriceUsdc (6-dec USDC per 1 XAUT unit in raw units)
        // oraclePriceUsdc = priceAnswer * 1e6 / 1e8 = priceAnswer / 100
        uint256 oraclePriceUsdc = uint256(priceAnswer) / 100;
        vm.assume(oraclePriceUsdc > 0);

        // Set oracle and pool to the same price (no deviation)
        oracle.setPrice(int256(uint256(priceAnswer)));
        pool.setPrice(oraclePriceUsdc);

        // Fund vault with 10x usdcAmount so allocation cap isn't a problem
        _fund(uint256(usdcAmount) * 10);

        // Check allocation room
        uint256 ta = vault.totalAssets();
        uint256 maxD = (ta * vault.maxAllocationBps()) / 10_000;
        if (uint256(usdcAmount) > maxD) return; // skip if still too constrained

        _deploy(usdcAmount);

        uint256 xHeld = adapter.xautHeld();
        uint256 expected = (xHeld * oraclePriceUsdc) / 1e6; // xautDecimals = 6
        uint256 actual = adapter.currentValue();

        assertApproxEqAbs(actual, expected, 1, "currentValue must be within 1 unit of expected");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Fuzz 2: deploy → recall roundtrip loss within 2x slippage budget
    // ─────────────────────────────────────────────────────────────────────

    /// @notice After deploy then recall, the USDC returned is at least
    ///         amount * (10_000 - 2 * maxSlippageBps) / 10_000.
    ///         The pool charges swapFeeBps on each leg (default 9980/10000 = 0.2%),
    ///         maxSlippageBps defaults to 50 (0.5%), so 2x allowance covers both legs.
    function testFuzz_deploy_recall_roundtrip(uint128 amount) public {
        // Bound: 1 USDC to 1_000 USDC (6-dec)
        amount = uint128(bound(amount, 1e6, 1_000e6));

        _fund(uint256(amount) * 10); // fund 10x for safety

        uint256 maxSlippageBps = adapter.maxSlippageBps();

        _deploy(amount);

        uint256 vaultUsdcBefore = usdc.balanceOf(address(vault));

        vm.prank(address(vault));
        adapter.recall(uint256(amount));

        uint256 vaultUsdcAfter = usdc.balanceOf(address(vault));
        uint256 returned = vaultUsdcAfter - vaultUsdcBefore;

        // Minimum expected: amount * (10_000 - 2 * maxSlippageBps) / 10_000
        uint256 minExpected = (uint256(amount) * (10_000 - 2 * maxSlippageBps)) / 10_000;

        assertGe(returned, minExpected, "USDC returned must be >= amount * (1 - 2*slippage)");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Fuzz 3: combined gold weight never exceeds cap
    // ─────────────────────────────────────────────────────────────────────

    /// @notice At every step after a deploy to goldAllocationAdapter,
    ///         goldSpreadValue + goldAllocationValue <= MAX_GOLD_BPS * totalAssets / 10_000.
    function testFuzz_combined_gold_weight_never_exceeds_cap(
        uint128 depositAmount,
        uint128 spreadValue,
        uint128 deployAmount
    ) public {
        // Bound all inputs
        depositAmount = uint128(bound(depositAmount, 1_000e6, 10_000e6));  // 1k–10k USDC
        spreadValue   = uint128(bound(spreadValue,   0,       1_000e6));   // 0–1k USDC
        deployAmount  = uint128(bound(deployAmount,  1e6,     500e6));     // 1–500 USDC

        _fund(depositAmount);

        uint256 totalAssets_ = vault.totalAssets();
        uint256 goldCap = (totalAssets_ * vault.MAX_GOLD_BPS()) / 10_000;

        // Set up mock spread adapter
        MockGoldSpreadFuzz spreadAdapter = new MockGoldSpreadFuzz(spreadValue);
        vm.startPrank(owner);
        vault.setGoldSpreadAdapter(address(spreadAdapter));
        vm.stopPrank();

        // Determine if deploying `deployAmount` would exceed cap
        // combined = spreadValue + currentXautValue(=0) + deployAmount
        uint256 combined = uint256(spreadValue) + 0 + uint256(deployAmount);

        if (combined > goldCap) {
            // Expect revert GoldCapExceeded
            vm.prank(owner);
            vm.expectRevert();
            vault.deployCapital(address(adapter), deployAmount, "");
            // Cap is preserved — no deployment happened
        } else {
            // Deploy should succeed
            uint256 room = goldCap - uint256(spreadValue);
            if (deployAmount > room) return; // would exceed, skip

            // Check allocation cap as well
            uint256 maxAlloc = (totalAssets_ * vault.maxAllocationBps()) / 10_000;
            uint256 alreadyDeployed = vault.totalDeployed();
            if (deployAmount > maxAlloc - alreadyDeployed) return;

            vm.prank(owner);
            vault.deployCapital(address(adapter), deployAmount, "");
            vm.prank(address(vault));
            adapter.deploy(deployAmount);

            // Invariant: spread + allocation <= cap
            uint256 xautVal = adapter.currentValue();
            uint256 combinedAfter = uint256(spreadValue) + xautVal;
            assertLe(combinedAfter, goldCap, "Combined gold value must not exceed MAX_GOLD_BPS cap");
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Fuzz 4: timelock enforced for any sub-30-day warp
    // ─────────────────────────────────────────────────────────────────────

    /// @notice For any warpTime in [0, 29 days], executing a proposed param change
    ///         before 30 days must revert TimelockNotElapsed.
    /// @dev    Cache param IDs before vm.prank to avoid staticcall consuming the prank.
    function testFuzz_timelock_enforced_for_any_timestamp(uint256 warpTime) public {
        warpTime = bound(warpTime, 0, 30 days - 1);

        // Cache param ID before prank — staticcall must NOT consume the prank
        bytes32 paramId = adapter.PARAM_MAX_SLIPPAGE();
        uint256 proposeTime = block.timestamp;

        vm.prank(owner);
        adapter.proposeParamChange(paramId, 100);

        vm.warp(proposeTime + warpTime);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                GoldAllocationAdapter.TimelockNotElapsed.selector,
                proposeTime + 30 days,
                proposeTime + warpTime
            )
        );
        adapter.executeParamChange(paramId);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Fuzz 5: no XAUT stranded after recall
    // ─────────────────────────────────────────────────────────────────────

    /// @notice After deploy then recall, adapter holds 0 XAUT regardless of price.
    function testFuzz_no_xaut_stranded_after_recall(
        uint128 amount,
        uint32  priceSeed
    ) public {
        // Bound amount: 1 USDC to 1000 USDC (6-dec)
        amount = uint128(bound(amount, 1e6, 1_000e6));

        // Derive a valid oracle price from priceSeed: map to [100e8, 10_000e8]
        uint256 rawPrice = bound(priceSeed, 100e8, 10_000e8);
        // Ensure oraclePriceUsdc is representable
        uint256 oraclePriceUsdc = (rawPrice * 1e6) / 1e8;
        vm.assume(oraclePriceUsdc > 0);

        oracle.setPrice(int256(rawPrice));
        pool.setPrice(oraclePriceUsdc);

        _fund(uint256(amount) * 10);

        // Check there's room in allocation cap
        uint256 ta = vault.totalAssets();
        uint256 maxD = (ta * vault.maxAllocationBps()) / 10_000;
        uint256 ad = vault.totalDeployed();
        if (uint256(amount) > maxD - ad) return;

        _deploy(amount);

        vm.prank(address(vault));
        adapter.recall(uint256(amount));

        assertEq(xaut.balanceOf(address(adapter)), 0, "No XAUT must be stranded in adapter after recall");
        assertEq(adapter.xautHeld(), 0, "xautHeld must be 0 after recall");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Mock helper for fuzz: minimal IGoldAdapter stub
// ─────────────────────────────────────────────────────────────────────────────
contract MockGoldSpreadFuzz {
    uint256 private _value;
    constructor(uint256 value_) { _value = value_; }
    function currentValue() external view returns (uint256) { return _value; }
    function isPriceSane() external pure returns (bool) { return true; }
}
