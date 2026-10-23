// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// forge-config: default.fuzz.runs = 512

import {Test} from "forge-std/Test.sol";

import {CharityModule} from "../CharityModule.sol";
import {MockERC20}     from "../test-helpers/MockERC20.sol";

/**
 * @title  FuzzCharityModule
 * @notice Fuzz / property tests for CharityModule.
 *         Invariants: exact arithmetic, cap enforcement, timelock enforcement,
 *         and accumulator monotonicity.
 *
 * forge-config: default.fuzz.runs = 512
 */
contract FuzzCharityModule is Test {

    // ── actors ────────────────────────────────────────────────────────────────
    address internal owner         = makeAddr("owner");
    address internal charityWallet = makeAddr("charityWallet");

    // ── contracts ─────────────────────────────────────────────────────────────
    MockERC20     internal usdc;
    CharityModule internal module;

    // address(this) is vault
    function setUp() public {
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);

        vm.prank(owner);
        module = new CharityModule(charityWallet, address(usdc), address(this), owner, address(0));

        // Large balance so any fuzz amount can be approved
        usdc.mint(address(this), type(uint96).max);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. charityAmount is exactly grossProfit * 250 / 10_000
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzz_charityAmount_exact(uint96 grossProfit) public {
        grossProfit = uint96(bound(uint256(grossProfit), 1e6, 10_000e6));

        usdc.approve(address(module), grossProfit);
        (uint256 charityAmount,) = module.distributeCharity(grossProfit);

        uint256 expected = (uint256(grossProfit) * 250) / 10_000;
        assertEq(charityAmount, expected, "charityAmount must equal grossProfit * 250 / 10_000");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. charityAmount + remaining == grossProfit (exact conservation)
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzz_remaining_plus_charity_equals_gross(uint96 grossProfit) public {
        grossProfit = uint96(bound(uint256(grossProfit), 1e6, 10_000e6));

        usdc.approve(address(module), grossProfit);
        (uint256 charityAmount, uint256 remaining) = module.distributeCharity(grossProfit);

        assertEq(charityAmount + remaining, uint256(grossProfit),
            "charityAmount + remaining must equal grossProfit");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. Any bps > 500 always reverts CharityRateAboveCap
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzz_charity_above_cap_always_reverts(uint256 bps) public {
        bps = bound(bps, 501, 1_000_000);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(CharityModule.CharityRateAboveCap.selector, bps, 500)
        );
        module.proposeCharityRateChange(bps);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. Wallet timelock enforced for any warp < 30 days
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzz_timelock_enforced_wallet(uint256 warpTime) public {
        warpTime = bound(warpTime, 0, 30 days - 1);

        address newWallet = makeAddr("newWallet");
        vm.startPrank(owner);
        module.proposeCharityWalletChange(newWallet);
        vm.warp(block.timestamp + warpTime);
        vm.expectRevert(); // TimelockNotElapsed
        module.confirmCharityWalletChange();
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 5. Rate timelock enforced for any warp < 30 days
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzz_timelock_enforced_rate(uint256 warpTime) public {
        warpTime = bound(warpTime, 0, 30 days - 1);

        vm.startPrank(owner);
        module.proposeCharityRateChange(300);
        vm.warp(block.timestamp + warpTime);
        vm.expectRevert(); // TimelockNotElapsed
        module.confirmCharityRateChange();
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 6. totalCharityDistributed accumulates correctly over two calls
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzz_totalDistributed_accumulates(uint64 a, uint64 b) public {
        uint256 gross1 = bound(uint256(a), 1e6, 100_000e6);
        uint256 gross2 = bound(uint256(b), 1e6, 100_000e6);

        usdc.approve(address(module), gross1 + gross2);

        (uint256 c1,) = module.distributeCharity(gross1);
        (uint256 c2,) = module.distributeCharity(gross2);

        assertEq(
            module.totalCharityDistributed(),
            c1 + c2,
            "totalCharityDistributed should equal sum of both charity amounts"
        );
    }
}
