// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GoldExchangeAdapter} from "../adapters/GoldExchangeAdapter.sol";
import {ShariahVault}        from "../ShariahVault.sol";
import {AutonomousVault}     from "../AutonomousVault.sol";
import {TreasuryModule}      from "../TreasuryModule.sol";
import {MockERC20}           from "../test-helpers/MockERC20.sol";
import {MockAllocatedGold}   from "../test-helpers/MockAllocatedGold.sol";

/// @title  FuzzGoldExchangeAdapter
/// @notice Property-based tests for GoldExchangeAdapter and ShariahVault Task C guard.
///
/// Execution model (same as unit tests):
///   vault.deployCapital(adapter, amount, "")  — pushes USDC; no swap yet.
///   vm.prank(vault); adapter.deploy(amount)   — executes the swap.
///   vault.recallCapital(adapter, amount)      — calls adapter.recall().

// ─── Ratio-configurable mock swap router ─────────────────────────────────────
// outputRatioBps: output = input * ratio / 10_000
// Lets fuzz tests drive gain/loss exit scenarios.

contract RatioSwapRouter {
    uint256 public outputRatioBps;

    constructor(uint256 ratio) { outputRatioBps = ratio; }

    function setOutputRatioBps(uint256 bps) external { outputRatioBps = bps; }

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
        amountOut = (p.amountIn * outputRatioBps) / 10_000;
        if (amountOut < p.amountOutMinimum) revert("RatioSwapRouter: slippage");
        if (amountOut > 0) IERC20(p.tokenOut).transfer(p.recipient, amountOut);
    }
}

// ─── Fuzz test contract ───────────────────────────────────────────────────────

contract FuzzGoldExchangeAdapter is Test {

    address internal owner   = makeAddr("owner");
    address internal manager = makeAddr("manager");
    address internal alice   = makeAddr("alice");

    MockERC20           internal usdc;
    MockAllocatedGold   internal mag;
    RatioSwapRouter     internal router;
    ShariahVault        internal vault;
    TreasuryModule      internal treasury;
    GoldExchangeAdapter internal adapter;

    uint32 internal constant SRC = 26;

    function setUp() public {
        usdc   = new MockERC20("Mock USDC", "mUSDC", 6);
        mag    = new MockAllocatedGold();
        router = new RatioSwapRouter(10_000); // 1:1 default

        vm.startPrank(owner);
        treasury = new TreasuryModule(
            "Shariah", address(0), address(usdc), 50, 1000, 400, owner
        );
        vault = new ShariahVault(
            IERC20(address(usdc)), owner, SRC, address(treasury), address(0)
        );
        vault.setManager(manager);
        adapter = new GoldExchangeAdapter(
            address(usdc), address(mag), address(router), 3000, address(vault), owner
        );
        vault.setScreened(address(adapter), true);
        // Widen slippage floor so ratio router variations still pass the 99% check
        adapter.setMinOutBps(9000);
        vm.stopPrank();

        // Large MAG reserve so any fuzz amount up to 10M USDC can be served 1:1
        mag.mint(address(this), 200_000_000e18);
        IERC20(address(mag)).transfer(address(router), 200_000_000e18);
    }

    // ── Two-step deploy helper ──────────────────────────────────────────────

    function _pushAndSwap(uint256 amount) internal {
        vm.prank(manager);
        vault.deployCapital(address(adapter), amount, "");
        vm.prank(address(vault));
        adapter.deploy(amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INVARIANT 1: No USDC stranded in adapter after adapter.deploy()
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzz_deploy_no_usdc_stranded(uint64 rawAmount) public {
        uint256 depositAmt = bound(rawAmount, 1_000e6, 10_000_000e6);
        uint256 deployAmt  = (depositAmt * 7_000) / 10_000;

        usdc.mint(alice, depositAmt);
        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmt);
        vault.deposit(depositAmt, alice);
        vm.stopPrank();

        _pushAndSwap(deployAmt);

        assertEq(usdc.balanceOf(address(adapter)), 0,
            "Invariant: no USDC stranded in adapter after deploy");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INVARIANT 2: No MAG stranded in adapter after recallCapital()
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzz_recall_no_mag_stranded(uint64 rawAmount) public {
        uint256 depositAmt = bound(rawAmount, 1_000e6, 10_000_000e6);
        uint256 deployAmt  = (depositAmt * 7_000) / 10_000;

        usdc.mint(alice, depositAmt);
        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmt);
        vault.deposit(depositAmt, alice);
        vm.stopPrank();

        _pushAndSwap(deployAmt);
        assertGt(adapter.paxgHeld(), 0);

        // Seed router with USDC for reverse swap
        usdc.mint(address(router), 50_000_000e6);

        vm.prank(manager);
        vault.recallCapital(address(adapter), deployAmt);

        assertEq(mag.balanceOf(address(adapter)), 0,
            "Invariant: no MAG stranded in adapter after recall");
        assertEq(adapter.paxgHeld(), 0,
            "Invariant: paxgHeld must be zero after full recall");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INVARIANT 3: totalDeployed zeros on full recall regardless of exit price
    //              (test with varied gain/loss ratios)
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzz_totalDeployed_zeros_on_recall(uint64 rawAmount, uint16 exitRatioBps_) public {
        uint256 depositAmt = bound(rawAmount, 1_000e6, 5_000_000e6);
        uint256 deployAmt  = (depositAmt * 5_000) / 10_000;
        // Simulate exit ratio 90%–110% (loss or gain)
        uint256 exitRatio  = bound(exitRatioBps_, 9000, 11_000);

        usdc.mint(alice, depositAmt);
        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmt);
        vault.deposit(depositAmt, alice);
        vm.stopPrank();

        _pushAndSwap(deployAmt);
        assertGt(adapter.totalDeployed(), 0);

        // Change router ratio to simulate price movement
        router.setOutputRatioBps(exitRatio);
        // Supply USDC liquidity for MAG->USDC recall swap
        usdc.mint(address(router), 50_000_000e6);

        vm.prank(manager);
        vault.recallCapital(address(adapter), deployAmt);

        assertEq(adapter.totalDeployed(), 0,
            "Invariant: totalDeployed must zero on full exit regardless of exit price");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INVARIANT 4: paxgHeld always equals adapter's MAG balance after any swap
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzz_paxgHeld_equals_balance(uint64 rawAmt1, uint16 splitBps) public {
        uint256 total  = bound(rawAmt1, 10_000e6, 5_000_000e6);
        uint256 frac   = bound(splitBps, 1000, 3000);
        uint256 d1     = (total * frac) / 10_000;
        uint256 d2     = (total * 1000) / 10_000;
        vm.assume(d1 + d2 <= (total * 7_500) / 10_000);

        usdc.mint(alice, total);
        vm.startPrank(alice);
        usdc.approve(address(vault), total);
        vault.deposit(total, alice);
        vm.stopPrank();

        _pushAndSwap(d1);
        assertEq(adapter.paxgHeld(), mag.balanceOf(address(adapter)),
            "paxgHeld must equal MAG balance after first swap");

        _pushAndSwap(d2);
        assertEq(adapter.paxgHeld(), mag.balanceOf(address(adapter)),
            "paxgHeld must equal MAG balance after second swap");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INVARIANT 5: totalAssets = vaultBalance + totalDeployed at all times
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzz_totalAssets_invariant(uint64 rawDeposit, uint16 deployFrac) public {
        uint256 depositAmt = bound(rawDeposit, 100e6, 10_000_000e6);
        uint256 fraction   = bound(deployFrac, 0, 7_000);

        usdc.mint(alice, depositAmt);
        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmt);
        vault.deposit(depositAmt, alice);
        vm.stopPrank();

        uint256 deployAmt = (depositAmt * fraction) / 10_000;
        if (deployAmt >= 1e6) {
            _pushAndSwap(deployAmt);
        }

        assertEq(
            vault.totalAssets(),
            usdc.balanceOf(address(vault)) + vault.totalDeployed(),
            "totalAssets must equal vaultBalance + totalDeployed"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INVARIANT 6: deployCrossChain always reverts NonAtomicGoldExchange
    //              when goldCrossChainBlocked is true, for any domain/recipient/amount
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzz_deployCrossChain_always_blocked(
        uint32 domain,
        bytes32 recipient,
        uint64 amount
    ) public {
        vm.assume(domain != SRC && domain != 0);
        vm.assume(amount > 0);

        vm.prank(owner);
        vault.setGoldCrossChainBlocked(true);

        vm.prank(manager);
        vm.expectRevert(ShariahVault.NonAtomicGoldExchange.selector);
        vault.deployCrossChain(domain, recipient, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INVARIANT 7: setMinOutBps only accepts 9000–10000
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzz_setMinOutBps_range(uint256 bps) public {
        vm.prank(owner);
        if (bps < 9000 || bps > 10_000) {
            vm.expectRevert(bytes("GoldExchangeAdapter: bps out of range (9000-10000)"));
            adapter.setMinOutBps(bps);
        } else {
            adapter.setMinOutBps(bps);
            assertEq(adapter.minOutBps(), bps);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INVARIANT 8: deploy within 80% cap always succeeds
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzz_deploy_within_cap_succeeds(uint64 rawDeposit, uint16 allocFrac) public {
        uint256 depositAmt = bound(rawDeposit, 1_000e6, 50_000_000e6);
        uint256 fraction   = bound(allocFrac, 100, 7_000); // 1%–70%

        usdc.mint(alice, depositAmt);
        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmt);
        vault.deposit(depositAmt, alice);
        vm.stopPrank();

        uint256 deployAmt = (depositAmt * fraction) / 10_000;
        if (deployAmt == 0) return;

        // Both steps should succeed
        vm.prank(manager);
        vault.deployCapital(address(adapter), deployAmt, "");
        vm.prank(address(vault));
        adapter.deploy(deployAmt);

        assertGt(vault.totalDeployed(), 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INVARIANT 9: deployCapital reverts AllocationExceedsLimit above cap
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzz_deploy_above_cap_reverts(uint64 rawDeposit) public {
        uint256 depositAmt = bound(rawDeposit, 1_000e6, 50_000_000e6);

        usdc.mint(alice, depositAmt);
        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmt);
        vault.deposit(depositAmt, alice);
        vm.stopPrank();

        uint256 maxAllowed = (vault.totalAssets() * vault.maxAllocationBps()) / 10_000;

        vm.prank(manager);
        vm.expectRevert(AutonomousVault.AllocationExceedsLimit.selector);
        vault.deployCapital(address(adapter), maxAllowed + 1e6, "");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INVARIANT 10: pause blocks deployCapital for any amount
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzz_pause_blocks_deployCapital(uint64 rawAmount) public {
        uint256 amount = bound(rawAmount, 1e6, 1_000_000e6);

        usdc.mint(alice, amount);
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.setPaused(true);

        vm.prank(manager);
        vm.expectRevert(AutonomousVault.Paused.selector);
        vault.deployCapital(address(adapter), (amount * 5_000) / 10_000, "");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INVARIANT 11: round-trip deposit → pushAndSwap → recall → redeem
    //               depositor recovers at least amount - 1 (rounding only)
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzz_round_trip_preserves_value(uint64 rawAmount) public {
        uint256 amount = bound(rawAmount, 1_000e6, 5_000_000e6);

        usdc.mint(alice, amount);
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);
        vm.stopPrank();

        uint256 deployAmt = (amount * 4_000) / 10_000; // 40%
        if (deployAmt < 1e6) return;

        _pushAndSwap(deployAmt);

        // Seed router with USDC for recall
        usdc.mint(address(router), 50_000_000e6);

        vm.prank(manager);
        vault.recallCapital(address(adapter), deployAmt);

        vm.startPrank(alice);
        vault.approve(address(vault), shares);
        uint256 redeemed = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        assertGe(redeemed + 1, amount,
            "Invariant: depositor must recover at least amount-1 after round-trip");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INVARIANT 12: adapter.deploy() always reverts for non-vault caller
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzz_deploy_only_vault_caller(address caller, uint64 rawAmount) public {
        vm.assume(caller != address(vault));
        vm.assume(caller != address(0));
        uint256 amount = bound(rawAmount, 1e6, 1_000_000e6);

        vm.prank(caller);
        vm.expectRevert(bytes("GoldExchangeAdapter: caller is not the vault"));
        adapter.deploy(amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INVARIANT 13: adapter.recall() always reverts for non-vault caller
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzz_recall_only_vault_caller(address caller, uint64 rawAmount) public {
        vm.assume(caller != address(vault));
        vm.assume(caller != address(0));
        uint256 amount = bound(rawAmount, 1e6, 1_000_000e6);

        vm.prank(caller);
        vm.expectRevert(bytes("GoldExchangeAdapter: caller is not the vault"));
        adapter.recall(amount);
    }
}
