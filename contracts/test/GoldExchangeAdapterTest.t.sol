// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RemoteRecipientFixture} from "./TaskITest.Base.t.sol";
import {Test} from "forge-std/Test.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GoldExchangeAdapter}    from "../adapters/GoldExchangeAdapter.sol";
import {ShariahVault}           from "../ShariahVault.sol";
import {AutonomousVault}        from "../AutonomousVault.sol";
import {TreasuryModule}         from "../TreasuryModule.sol";
import {MockERC20}              from "../test-helpers/MockERC20.sol";
import {MockAllocatedGold}      from "../test-helpers/MockAllocatedGold.sol";
import {MockXauUsdAggregator}   from "../test-helpers/MockXauUsdAggregator.sol";
import {GoldAllocationAdapter} from "../adapters/GoldAllocationAdapter.sol";
import {MockXAUT} from "../test-helpers/MockXAUT.sol";
import {MockUniswapV3PoolXAUT} from "../test-helpers/MockUniswapV3PoolXAUT.sol";

/// @title  GoldExchangeAdapterTest
/// @notice Comprehensive unit tests for Task C: GoldExchangeAdapter + ShariahVault guard.
///
/// Execution model (important):
///   vault.deployCapitalAndExecute(adapter, amount, "") — funds and executes the swap atomically.
///   vault.recallCapital(adapter, amount)     — calls adapter.recall() which reverses the swap.
///
/// Swap helpers and failure cases use deployCapitalAndExecute throughout.
///
/// Correctness properties verified:
///   C-1  deploy() is atomic — no USDC stranded in adapter after adapter.deploy() returns
///   C-2  recall() is atomic — no MAG stranded in adapter after recallCapital() returns
///   C-3  SlippageExceeded fires when router returns 0 tokens
///   C-4  setMinOutBps range validation (9000–10000)
///   C-5  setMinOutBps emits MinOutBpsUpdated
///   C-6  Strategy-tagged gold transfers reject nonzero destination domains
///   C-7  Held gold leaves unrelated USDC transfers on the inherited path
///   C-8  Only vault may call deploy/recall
///   C-9  renounceOwnership is disabled
///   C-10 Accounting: totalDeployed/paxgHeld track correctly after deploy + recall
///   C-11 paxgHeld mirrors MAG balance of adapter
///   C-12 GoldAcquired event emitted on deploy with correct values
///   C-13 GoldReturned event emitted on recall
///   C-14 Entry uses a fresh oracle floor; oracle refresh preserves observation time
///   C-15 deploy(0) reverts ZeroAmount
///   C-16 recall(0) reverts ZeroAmount
///   C-17 recall when paxgHeld==0 returns 0 gracefully
///   C-18 Removed: global switch event no longer exists
///   C-19 pause gates deployCapital on ShariahVault
///   C-20 pause gates deployCrossChain on ShariahVault
///   C-21 sequential deploys accumulate paxgHeld
///   C-22 non-owner cannot setMinOutBps
///   C-23 Removed: global switch access-control test no longer applies
///   C-24 protocolName() returns correct string
///   C-25 currentValue() equals totalDeployed

// ─── Mock swap router ─────────────────────────────────────────────────────────
// 1:1 USDC<>MAG swap by default. setReturnZero(true) simulates total slippage.

contract MockSwapRouter {
    bool public returnZero;
    uint256 public payoutBps = 10_000;

    function setReturnZero(bool z) external { returnZero = z; }
    function setPayoutBps(uint256 bps) external { payoutBps = bps; }

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata p)
        external returns (uint256 amountOut)
    {
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        if (returnZero) { return 0; }
        amountOut = MockERC20(p.tokenIn).decimals() == 6
            ? p.amountIn * 1e18 / 3_300e6
            : p.amountIn * 3_300e6 / 1e18;
        // Deliberately leave enforcement to the adapter to test its own check.
        amountOut = amountOut * payoutBps / 10_000;
        IERC20(p.tokenOut).transfer(p.recipient, amountOut);
    }
}

// ─── Test contract ────────────────────────────────────────────────────────────

contract GoldExchangeAdapterTest is Test {
    using stdStorage for StdStorage;

    address internal owner    = makeAddr("owner");
    address internal manager  = makeAddr("manager");
    address internal alice    = makeAddr("alice");
    address internal attacker = makeAddr("attacker");

    MockERC20              internal usdc;
    MockAllocatedGold      internal mag;
    MockSwapRouter         internal router;
    MockXauUsdAggregator   internal xauOracle;
    ShariahVault           internal vault;
    TreasuryModule         internal treasury;
    GoldExchangeAdapter    internal adapter;

    uint32 internal constant SOURCE_DOMAIN = 26;

    function setUp() public {
        usdc      = new MockERC20("Mock USDC", "mUSDC", 6);
        mag       = new MockAllocatedGold();
        router    = new MockSwapRouter();
        xauOracle = new MockXauUsdAggregator(); // K2: mandatory oracle

        vm.startPrank(owner);
        treasury = new TreasuryModule(
            "Shariah", address(0), address(usdc), 50, 1000, 400, owner
        );
        vault = new ShariahVault(
            IERC20(address(usdc)), owner, SOURCE_DOMAIN, address(treasury), address(0)
        );
        vault.setManager(manager);
        adapter = new GoldExchangeAdapter(
            address(usdc), address(mag), address(router), 3000,
            address(vault), owner, address(xauOracle)
        );
        vault.setScreened(address(adapter), true);
        // N-23: keep swap regressions on a tracked gold strategy rather than bypassing vault gold controls.
        vault.setGoldSpreadAdapter(address(adapter));
        vm.stopPrank();

        // Seed router with MAG (stand-in for Uniswap V3 USDC/PAXG pool)
        mag.mint(address(this), 2_000_000e18);
        IERC20(address(mag)).transfer(address(router), 2_000_000e18);

        // Alice deposits 100k USDC
        usdc.mint(alice, 100_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, alice);
        vm.stopPrank();
    }

    /// @dev Push USDC to adapter (vault accounting) then execute the swap (adapter side).
    function _deployAndSwap(uint256 amount) internal {
        vm.prank(manager);
        // Exercise vault-funded execution without impersonating the adapter's onlyVault caller.
        vault.deployCapitalAndExecute(address(adapter), amount, "");
    }

    // ─── C-1: deploy() is atomic ─────────────────────────────────────────────

    function test_C1_deploy_no_usdc_stranded() public {
        _deployAndSwap(10_000e6);

        assertEq(usdc.balanceOf(address(adapter)), 0,
            "No USDC should remain in adapter after atomic swap");
        assertGt(mag.balanceOf(address(adapter)), 0,
            "Adapter must hold MAG after swap");
        assertGt(adapter.paxgHeld(), 0,     "paxgHeld must be updated");
        assertGt(adapter.totalDeployed(), 0, "totalDeployed must be updated");
    }

    // ─── C-2: recall() is atomic ─────────────────────────────────────────────

    function test_C2_recall_no_mag_stranded() public {
        _deployAndSwap(10_000e6);

        assertGt(mag.balanceOf(address(adapter)), 0);

        // Seed router with USDC for the reverse swap
        usdc.mint(address(router), 50_000_000e6);

        vm.prank(manager);
        vault.recallCapital(address(adapter), 10_000e6);

        assertEq(adapter.paxgHeld(), 0,
            "paxgHeld must be zero after full recall");
        assertEq(mag.balanceOf(address(adapter)), 0,
            "No MAG should remain in adapter after recall");
    }

    // ─── C-3: SlippageExceeded when router returns 0 ─────────────────────────

    function test_C3_slippage_exceeded_when_router_returns_zero() public {
        router.setReturnZero(true);
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(GoldExchangeAdapter.SlippageExceeded.selector, uint256(0), ((uint256(5_000e6) * 1e18 / 3_300e6) * 9900 / 10_000))
        );
        vault.deployCapitalAndExecute(address(adapter), 5_000e6, "");
    }

    // ─── C-4: setMinOutBps range validation ──────────────────────────────────

    function test_C4a_setMinOutBps_below_9000_reverts() public {
        vm.prank(owner);
        vm.expectRevert(bytes("GoldExchangeAdapter: bps out of range (9000-10000)"));
        adapter.setMinOutBps(8999);
    }

    function test_C4b_setMinOutBps_above_10000_reverts() public {
        vm.prank(owner);
        vm.expectRevert(bytes("GoldExchangeAdapter: bps out of range (9000-10000)"));
        adapter.setMinOutBps(10_001);
    }

    function test_C4c_setMinOutBps_9000_accepted() public {
        vm.prank(owner);
        adapter.setMinOutBps(9000);
        assertEq(adapter.minOutBps(), 9000);
    }

    function test_C4d_setMinOutBps_10000_accepted() public {
        vm.prank(owner);
        adapter.setMinOutBps(10_000);
        assertEq(adapter.minOutBps(), 10_000);
    }

    // ─── C-5: setMinOutBps emits event ───────────────────────────────────────

    function test_C5_setMinOutBps_emits_event() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit GoldExchangeAdapter.MinOutBpsUpdated(9900, 9950);
        adapter.setMinOutBps(9950);
        assertEq(adapter.minOutBps(), 9950);
    }

    // ─── C-6: Only gold strategy routing rejects nonzero domains ─────────────

    function test_C6_deployCrossChain_gold_strategies_revert() public {
        vm.prank(manager);
        vm.expectRevert(ShariahVault.NonAtomicGoldExchange.selector);
        vault.deployCrossChainForStrategy(1, 3, bytes32(0), 0);
        vm.prank(manager);
        vm.expectRevert(ShariahVault.NonAtomicGoldExchange.selector);
        vault.deployCrossChainForStrategy(5, 3, bytes32(0), type(uint256).max);
    }

    // ─── C-7: Held gold does not block unrelated USDC transfers ──────────────

    function test_C7_deployCrossChain_with_gold_hits_base_revert() public {
        _deployAndSwap(5_000e6);
        MockXAUT xaut = new MockXAUT();
        MockUniswapV3PoolXAUT pool = new MockUniswapV3PoolXAUT(
            address(usdc), address(xaut), 3_300_000_000
        );
        GoldAllocationAdapter second = new GoldAllocationAdapter(
            address(usdc), address(xaut), address(pool), 3000,
            address(xauOracle), address(vault), 3600, owner
        );
        xaut.mint(address(pool), 100e6);
        vm.startPrank(owner);
        vault.setScreened(address(second), true);
        // N-23: setup already links the funded spread; re-setting it would hit the exposure guard.
        vault.setGoldAllocationAdapter(address(second));
        vm.stopPrank();
        vm.prank(manager);
        vault.deployCapitalAndExecute(address(second), 3_300e6, "");
        assertGt(adapter.paxgHeld(), 0);
        assertGt(second.xautHeld(), 0);

        bytes32 recipient = bytes32(uint256(uint160(alice)));
        RemoteRecipientFixture.approve(vm, vault, owner, 3, recipient);
        vm.prank(manager);
        vm.expectRevert(AutonomousVault.CrossChainNotConfigured.selector);
        vault.deployCrossChain(3, recipient, 1_000e6);
        vm.prank(manager);
        vm.expectRevert(AutonomousVault.CrossChainNotConfigured.selector);
        vault.deployCrossChainForStrategy(0, 3, recipient, 1_000e6);
    }

    // ─── C-8: only vault address can call adapter deploy/recall ───────────────

    function test_C8a_deploy_only_vault() public {
        vm.prank(attacker);
        vm.expectRevert(bytes("GoldExchangeAdapter: caller is not the vault"));
        adapter.deploy(1_000e6);
    }

    function test_C8b_recall_only_vault() public {
        vm.prank(attacker);
        vm.expectRevert(bytes("GoldExchangeAdapter: caller is not the vault"));
        adapter.recall(1_000e6);
    }

    // ─── C-9: renounceOwnership is disabled ──────────────────────────────────

    function test_C9_renounceOwnership_disabled() public {
        vm.prank(owner);
        vm.expectRevert(bytes("GoldExchangeAdapter: renouncing ownership is disabled"));
        adapter.renounceOwnership();
    }

    // ─── C-10: accounting tracks correctly after deploy + recall ─────────────

    function test_C10a_totalDeployed_increments_after_swap() public {
        assertEq(adapter.totalDeployed(), 0);
        _deployAndSwap(8_000e6);
        assertEq(adapter.totalDeployed(), 8_000e6);
    }

    function test_C10b_totalDeployed_zeros_after_recall() public {
        _deployAndSwap(8_000e6);
        assertGt(adapter.totalDeployed(), 0);

        usdc.mint(address(router), 50_000_000e6);
        vm.prank(manager);
        vault.recallCapital(address(adapter), 8_000e6);

        assertEq(adapter.totalDeployed(), 0,
            "totalDeployed must zero on full recall regardless of price");
    }

    // ─── C-11: paxgHeld mirrors adapter MAG balance ───────────────────────────

    function test_C11_paxgHeld_matches_mag_balance() public {
        _deployAndSwap(5_000e6);
        assertEq(adapter.paxgHeld(), mag.balanceOf(address(adapter)));
    }

    // ─── C-12: GoldAcquired event emitted on adapter.deploy() ────────────────

    function test_C12_goldAcquired_event_emitted() public {
        uint256 expectedOut = uint256(10_000e6) * 1e18 / 3_300e6;
        uint256 expectedPrice = uint256(10_000e6) * 1e18 / expectedOut;
        vm.prank(manager);
        vm.expectEmit(false, false, false, true, address(adapter));
        emit GoldExchangeAdapter.GoldAcquired(10_000e6, expectedOut, expectedPrice);
        vault.deployCapitalAndExecute(address(adapter), 10_000e6, "");
    }

    // ─── C-13: GoldReturned event emitted on recall ───────────────────────────

    function test_C13_goldReturned_event_emitted() public {
        _deployAndSwap(10_000e6);
        usdc.mint(address(router), 50_000_000e6);

        vm.prank(manager);
        vm.expectEmit(false, false, false, false); // check event fires, values vary
        emit GoldExchangeAdapter.GoldReturned(0, 0);
        vault.recallCapital(address(adapter), 10_000e6);
    }

    function test_deploy_belowOracleMinimum_reverts() public {
        router.setPayoutBps(9800);
        usdc.mint(address(adapter), 3_300e6);
        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(
            GoldExchangeAdapter.SlippageExceeded.selector, uint256(0.98e18), uint256(0.99e18)
        ));
        adapter.deploy(3_300e6);
    }

    function test_deploy_staleOracle_reverts() public {
        vm.warp(block.timestamp + adapter.maxStalenessSecs() + 1);
        usdc.mint(address(adapter), 1_000e6);
        vm.prank(address(vault));
        vm.expectRevert(GoldExchangeAdapter.StaleGoldPrice.selector);
        adapter.deploy(1_000e6);
    }

    function test_pokePrice_keepsObservationTimestamp_andIgnoresStale() public {
        vm.warp(1_700_000_000);
        xauOracle.setPrice(330_000_000_000);
        uint256 observedAt = block.timestamp - 60;
        xauOracle.setUpdatedAt(observedAt);
        adapter.pokePrice();
        assertEq(adapter.lastGoodPriceAt(), observedAt);
        assertEq(adapter.lastGoodPrice(), 3_300e6);
        vm.warp(block.timestamp + adapter.maxStalenessSecs() + 1);
        adapter.pokePrice();
        assertEq(adapter.lastGoodPriceAt(), observedAt);
        xauOracle.setUpdatedAt(block.timestamp + 1);
        adapter.pokePrice();
        assertEq(adapter.lastGoodPriceAt(), observedAt);
        xauOracle.setUpdatedAt(0);
        adapter.pokePrice();
        assertEq(adapter.lastGoodPriceAt(), observedAt);
    }

    // N-09 allows ordinary declines during outages, but never output below the cached-price floor.
    function test_recall_staleOracle_retainsBoundedFloor() public {
        _deployAndSwap(3_300e6);
        vm.warp(block.timestamp + adapter.maxStalenessSecs() + 1);
        uint256 floor = adapter.paxgHeld() * adapter.lastGoodPrice() / 1e18;
        floor = floor * (10_000 - adapter.staleHaircutBps()) / 10_000;
        floor = floor * (10_000 - adapter.emergencySlippageBps()) / 10_000;
        router.setPayoutBps(8549);
        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(
            GoldExchangeAdapter.SlippageExceeded.selector, uint256(3_300e6 * 8549 / 10_000), floor
        ));
        adapter.recall(3_300e6);
        router.setPayoutBps(8550);
        vm.prank(address(vault));
        assertEq(adapter.recall(3_300e6), floor);
    }

    function test_recall_staleWithoutCachedPrice_reverts() public {
        _deployAndSwap(3_300e6);
        xauOracle.setUpdatedAt(0);
        // Simulate a legacy position without a populated cache; principal is not an exit-price fallback.
        stdstore.target(address(adapter)).sig("lastGoodPrice()").checked_write(uint256(0));
        vm.prank(address(vault));
        vm.expectRevert(GoldExchangeAdapter.StaleGoldPrice.selector);
        adapter.recall(3_300e6);
    }

    function test_recall_staleOracle_usesRefreshedCache_notEntryCost() public {
        _deployAndSwap(3_300e6);
        xauOracle.setPrice(264_000_000_000);
        adapter.pokePrice();
        xauOracle.setUpdatedAt(0);
        router.setPayoutBps(7000); // Clears the refreshed cache floor, but not the entry-price floor.
        vm.prank(address(vault));
        assertEq(adapter.recall(3_300e6), 2_310e6);
    }

    function test_recall_freshOracle_neverUsesEmergencyTolerance() public {
        _deployAndSwap(3_300e6);
        router.setPayoutBps(9000);
        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(
            GoldExchangeAdapter.SlippageExceeded.selector, uint256(2_970e6), uint256(3_267e6)
        ));
        adapter.recall(3_300e6);
    }

    function test_emergencySlippage_timelock_cap_cancel_ownerOnly() public {
        bytes32 id = adapter.PARAM_EMERGENCY_SLIPPAGE();
        assertEq(adapter.emergencySlippageBps(), 1000);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(GoldExchangeAdapter.HaircutAboveCap.selector, uint256(2501), uint256(2500)));
        adapter.proposeParamChange(id, 2501);
        adapter.proposeParamChange(id, 2500);
        assertEq(adapter.emergencySlippageBps(), 1000);
        vm.expectRevert(bytes("GoldExchangeAdapter: timelock not elapsed"));
        adapter.executeParamChange(id);
        vm.warp(block.timestamp + 30 days);
        vm.expectEmit(false, false, false, true, address(adapter));
        emit GoldExchangeAdapter.EmergencySlippageBpsUpdated(1000, 2500);
        adapter.executeParamChange(id);
        assertEq(adapter.emergencySlippageBps(), 2500);
        adapter.proposeParamChange(id, 0);
        adapter.cancelParamChange(id);
        vm.expectRevert(bytes("GoldExchangeAdapter: no proposal pending"));
        adapter.executeParamChange(id);
        vm.stopPrank();
        vm.startPrank(attacker);
        vm.expectRevert();
        adapter.proposeParamChange(id, 100);
        vm.expectRevert();
        adapter.executeParamChange(id);
        vm.expectRevert();
        adapter.cancelParamChange(id);
        vm.stopPrank();
    }

    // ─── C-15: deploy(0) reverts ZeroAmount ──────────────────────────────────

    function test_C15_deploy_zero_reverts() public {
        // Create adapter pointing at address(this) so we can call deploy() directly
        GoldExchangeAdapter da = new GoldExchangeAdapter(
            address(usdc), address(mag), address(router), 3000,
            address(this), owner, address(xauOracle)
        );
        vm.expectRevert(GoldExchangeAdapter.ZeroAmount.selector);
        da.deploy(0);
    }

    // ─── C-16: recall(0) reverts ZeroAmount ──────────────────────────────────

    function test_C16_recall_zero_reverts() public {
        GoldExchangeAdapter da = new GoldExchangeAdapter(
            address(usdc), address(mag), address(router), 3000,
            address(this), owner, address(xauOracle)
        );
        vm.expectRevert(GoldExchangeAdapter.ZeroAmount.selector);
        da.recall(0);
    }

    // ─── C-17: recall when paxgHeld==0 returns 0 gracefully ──────────────────

    function test_C17_recall_with_zero_paxgHeld_returns_zero() public {
        GoldExchangeAdapter da = new GoldExchangeAdapter(
            address(usdc), address(mag), address(router), 3000,
            address(this), owner, address(xauOracle)
        );
        uint256 ret = da.recall(1);
        assertEq(ret, 0, "recall with zero paxgHeld must return 0 gracefully");
    }

    // C-18 removed: the global switch and its event no longer exist; C-6 covers the strategy guard.

    // ─── C-19: pause gates deployCapital on ShariahVault ─────────────────────

    function test_C19_pause_blocks_deployCapital() public {
        vm.prank(owner);
        vault.setPaused(true);

        vm.prank(manager);
        vm.expectRevert(AutonomousVault.Paused.selector);
        vault.deployCapitalAndExecute(address(adapter), 5_000e6, "");
    }

    // ─── C-20: pause gates deployCrossChain on ShariahVault ──────────────────

    function test_C20_pause_blocks_deployCrossChain() public {
        // The inherited transfer path retains the base pause check.
        vm.prank(owner);
        ShariahVault fresh = new ShariahVault(
            IERC20(address(usdc)), owner, SOURCE_DOMAIN, address(treasury), address(0)
        );
        vm.prank(owner);
        fresh.setManager(manager);
        vm.prank(owner);
        fresh.setPaused(true);

        RemoteRecipientFixture.approve(vm, fresh, owner, 3, bytes32(uint256(uint160(makeAddr("r")))));
        vm.prank(manager);
        vm.expectRevert(AutonomousVault.Paused.selector);
        fresh.deployCrossChain(3, bytes32(uint256(uint160(makeAddr("r")))), 1_000e6);
    }

    // ─── C-21: sequential deploys accumulate paxgHeld ────────────────────────

    function test_C21_sequential_deploys_accumulate() public {
        _deployAndSwap(5_000e6);
        uint256 held1 = adapter.paxgHeld();
        assertGt(held1, 0);

        _deployAndSwap(5_000e6);
        uint256 held2 = adapter.paxgHeld();
        assertGt(held2, held1, "second deploy must increase paxgHeld");
        assertEq(adapter.totalDeployed(), 10_000e6);
    }

    // ─── C-22: non-owner cannot setMinOutBps ─────────────────────────────────

    function test_C22_setMinOutBps_only_owner() public {
        vm.prank(attacker);
        vm.expectRevert();
        adapter.setMinOutBps(9500);
    }

    // C-23 removed: no owner-controlled global switch remains to exercise.

    // ─── C-24: protocolName() ─────────────────────────────────────────────────

    function test_C24_protocolName() public view {
        assertEq(
            adapter.protocolName(),
            "GoldExchangeAdapter: USDC/PAXG atomic swap (yad bi yad)"
        );
    }

    // ─── C-25: currentValue() == totalDeployed ────────────────────────────────

    // Regression coverage uses the corrected price units rather than accepting a self-consistent zero value.
    function test_entryAndExitPrice_shareUnits() public {
        _deployAndSwap(6_600e6);
        assertEq(adapter.lastGoodPrice(), 3_300e6);
        assertEq(adapter.currentValue(), 6_600e6);
        vm.prank(manager);
        vault.recallCapital(address(adapter), 6_600e6);
        assertEq(adapter.lastGoodPrice(), 3_300e6);
        assertEq(adapter.currentValue(), 0);
    }

    // Adapter failure must roll back funding and vault accounting on the new entry point.
    function test_atomicFailure_rollsBackFunding() public {
        router.setReturnZero(true);
        uint256 balanceBefore = usdc.balanceOf(address(vault));
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(GoldExchangeAdapter.SlippageExceeded.selector,
            uint256(0), ((uint256(5_000e6) * 1e18 / 3_300e6) * 9900 / 10_000)));
        vault.deployCapitalAndExecute(address(adapter), 5_000e6, "");
        assertEq(usdc.balanceOf(address(vault)), balanceBefore);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(vault.totalDeployed(), 0);
        assertEq(adapter.paxgHeld(), 0);
        router.setReturnZero(false);
        _deployAndSwap(5_000e6);
    }

    // Fresh losses must affect adapter value and vault NAV before any keeper refresh.
    function test_currentValue_freshLossBeforePoke_updatesNav() public {
        vm.prank(owner);
        vault.setGoldSpreadAdapter(address(adapter));
        _deployAndSwap(6_600e6);
        uint256 cached = adapter.lastGoodPrice();
        uint256 beforeNav = vault.totalAssets();
        xauOracle.setPrice(264_000_000_000);
        assertEq(adapter.currentValue(), 5_280e6);
        assertEq(adapter.lastGoodPrice(), cached);
        assertEq(vault.goldWritedown(), 1_320e6);
        assertEq(vault.totalAssets(), beforeNav - 1_320e6);
        uint256 sharesBefore = vault.previewDeposit(100e6);
        adapter.pokePrice();
        assertEq(adapter.currentValue(), 5_280e6);
        assertEq(vault.previewDeposit(100e6), sharesBefore);
        xauOracle.setUpdatedAt(0);
        assertEq(adapter.currentValue(), 5_280e6, "recent cache needs no haircut yet");
        skip(adapter.maxStalenessSecs() + 1);
        assertEq(adapter.currentValue(), 5_016e6);
    }

    function test_C25_currentValue_usesFreshOracle() public {
        _deployAndSwap(7_000e6);
        // Fresh oracle valuation must be independent of the cached execution price.
        uint256 expected = (adapter.paxgHeld() * 3_300e6) / 1e18;
        assertEq(adapter.currentValue(), expected,
            "currentValue should equal paxgHeld * fresh oracle / 1e18");
    }
}
