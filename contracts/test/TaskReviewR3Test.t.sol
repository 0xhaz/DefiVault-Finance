// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {ShariahAccountingLogic} from "../ShariahVault.sol";
import {AutonomousVault} from "../AutonomousVault.sol";
import {TaskN27Base, TaskN27V1Fixture, TaskN27V2Fixture} from "./TaskN27Test.Base.t.sol";

/// @dev Review R3: exit liquidity limits, recovery under pause, and the deposit-maintained hurdle basis.
///      Fixture: alice deposits D (1_000_000e6) as the FIRST deposit; setHurdlePrincipal is never called.
abstract contract TaskReviewR3Tests is TaskN27Base {
    using stdStorage for StdStorage;

    uint256 internal constant YEAR = 365 days;
    uint256 internal constant HURDLE_BPS = 1_000; // 10 %/yr
    uint256 internal constant SHARE_BPS = 2_000; // 20 % manager share

    function setUp() public virtual override {
        super.setUp();
        vm.prank(owner);
        treasury.setMusharakahParams(SHARE_BPS, HURDLE_BPS);
    }

    function _depositAs(address who, uint256 amt) internal returns (uint256 sh) {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(vault), type(uint256).max);
        sh = vault.deposit(amt, who);
        vm.stopPrank();
    }

    function _idle() internal view returns (uint256) {
        return usdc.balanceOf(address(vault));
    }

    function _recallAll(uint256 amt) internal {
        a.setRecall(amt, 0);
        vm.prank(manager);
        vault.recallCapital(address(a), amt);
    }

    // ───────────── maxWithdraw / maxRedeem are limited by idle liquidity ─────────────

    function test_maxWithdrawRedeem_limitedByIdleLiquidity() public {
        _fund(a, 600_000e6);
        assertEq(_idle(), D - 600_000e6);
        assertEq(vault.maxWithdraw(alice), _idle(), "capped at idle");
        uint256 shares = vault.balanceOf(alice);
        uint256 mr = vault.maxRedeem(alice);
        assertLt(mr, shares, "not all shares payable");
        assertLe(vault.previewRedeem(mr), _idle(), "max redeem is payable");
        assertGt(vault.previewRedeem(mr + 2 * 10 ** (vault.decimals() - 6)), _idle(), "max redeem is tight");
    }

    function test_withdrawAboveIdle_revertsExceededMaxWithdraw() public {
        _fund(a, 600_000e6);
        uint256 idle = _idle();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, alice, idle + 1, idle));
        vault.withdraw(idle + 1, alice, alice);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(idle, alice, alice);
        assertEq(usdc.balanceOf(alice) - before, idle);
        assertEq(_idle(), 0);
        assertEq(vault.maxWithdraw(alice), 0, "nothing liquid left");
        assertEq(vault.maxRedeem(alice), 0);
    }

    function test_redeemAboveMaxRedeem_reverts() public {
        _fund(a, 600_000e6);
        uint256 mr = vault.maxRedeem(alice);
        uint256 all = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxRedeem.selector, alice, all, mr));
        vault.redeem(all, alice, alice);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 out = vault.redeem(mr, alice, alice);
        assertEq(usdc.balanceOf(alice) - before, out);
        assertLe(out, D - 600_000e6);
    }

    function test_redeemAllShares_succeedsWhenFullyLiquid() public {
        uint256 all = vault.balanceOf(alice);
        assertEq(vault.maxRedeem(alice), all, "fully liquid -> full balance");
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 out = vault.redeem(all, alice, alice);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(alice) - before, out);
        assertApproxEqAbs(out, D, 2);
    }

    function test_partialLiquidity_secondHolderSeesRemainingLiquidityOnly() public {
        _depositAs(bob, D);
        _fund(a, 1_500_000e6); // idle 500_000e6 against two holders owed ~1_000_000e6 each
        assertEq(vault.maxWithdraw(alice), 500_000e6);
        assertEq(vault.maxWithdraw(bob), 500_000e6);
        vm.prank(alice);
        vault.withdraw(500_000e6, alice, alice);
        assertEq(vault.maxWithdraw(bob), 0, "liquidity already consumed");
        assertEq(vault.maxRedeem(bob), 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, bob, 1, 0));
        vault.withdraw(1, bob, bob);
        // Capital comes back -> bob can exit again.
        _recallAll(1_500_000e6);
        assertEq(vault.maxRedeem(bob), vault.balanceOf(bob));
    }

    // ───────────── recall / return are not blocked by pause ─────────────

    function test_recallWhilePaused_thenFullWithdraw() public {
        _fund(a, 600_000e6);
        vm.prank(owner);
        vault.setPaused(true);

        vm.prank(manager);
        vm.expectRevert(AutonomousVault.Paused.selector);
        vault.deployCapital(address(b), 1e6, "");

        _recallAll(600_000e6);
        assertEq(vault.principalOf(address(a)), 0);
        assertEq(vault.totalDeployed(), 0);
        assertEq(_idle(), D);

        uint256 all = vault.balanceOf(alice);
        assertEq(vault.maxRedeem(alice), all);
        vm.prank(alice);
        uint256 out = vault.redeem(all, alice, alice);
        assertApproxEqAbs(out, D, 2);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_returnCapitalWhilePaused_succeeds_depositStillBlocked() public {
        _fund(a, 100e6);
        a.approveVault();
        vm.prank(owner);
        vault.setPaused(true);

        vm.prank(manager);
        vault.returnCapital(address(a), 40e6);
        assertEq(vault.principalOf(address(a)), 60e6);
        assertEq(vault.totalDeployed(), 60e6);

        usdc.mint(bob, 10e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 10e6);
        vm.expectRevert(AutonomousVault.Paused.selector);
        vault.deposit(10e6, bob);
        vm.stopPrank();
    }

    // ───────────── hurdle basis (no setHurdlePrincipal anywhere) ─────────────

    function test_firstDeposit_seedsHurdleBasis() public view {
        assertEq(vault.hurdlePrincipal(), D, "principal = first deposit");
        assertEq(vault.hurdleStartTime(), block.timestamp, "clock starts at first deposit");
    }

    function _net(uint256 g) internal view returns (uint256) {
        return g - (g * charity.charityBps()) / 10_000;
    }

    function test_claim_usesNonZeroHurdleFromDeposit() public {
        skip(YEAR);
        usdc.mint(address(vault), 300_000e6);
        uint256 g = vault.realizedProfit();
        assertEq(g, 300_000e6);
        uint256 allowance = D * HURDLE_BPS / 10_000; // exactly one year on D
        uint256 net = _net(g);
        (uint256 hurdleAmount, uint256 expectedShare,) = treasury.calculateMusharakahSplitHWM(
            net, block.timestamp - vault.hurdleStartTime(), vault.hurdlePrincipal(), vault.hwmDeficit()
        );
        assertEq(hurdleAmount, allowance, "non-zero hurdle");
        assertEq(expectedShare, (net - allowance) * SHARE_BPS / 10_000);
        (,uint256 noHurdleShare,) = treasury.calculateMusharakahSplitHWM(net, 0, 0, 0);
        assertLt(expectedShare, noHurdleShare, "hurdle reduces the manager share");

        uint256 feesBefore = treasury.pendingFees();
        vm.prank(manager);
        vault.claimMusharakahProfit(g);
        assertEq(treasury.pendingFees() - feesBefore, expectedShare, "manager share uses the seeded hurdle");
    }

    function test_secondDeposit_keepsAccruedAllowance_accruesNewCapitalFromNow() public {
        uint256 t0 = block.timestamp;
        uint256 d2 = 3 * D;
        skip(180 days);
        uint256 allowanceBefore = vault.hurdlePrincipal() * HURDLE_BPS * (block.timestamp - vault.hurdleStartTime())
            / (10_000 * YEAR);
        _depositAs(bob, d2);
        assertEq(vault.hurdlePrincipal(), D + d2, "principal grows by the deposit");
        assertEq(vault.hurdleStartTime(), block.timestamp - 45 days, "t' = t * P / (P + A)");
        uint256 allowanceAfter = vault.hurdlePrincipal() * HURDLE_BPS * (block.timestamp - vault.hurdleStartTime())
            / (10_000 * YEAR);
        assertEq(allowanceAfter, allowanceBefore, "accrued allowance is preserved by the deposit");

        skip(185 days);
        assertEq(block.timestamp, t0 + YEAR);
        usdc.mint(address(vault), 500_000e6);
        uint256 g = vault.realizedProfit();
        assertEq(g, 500_000e6, "deposits are not profit");
        // alice earned the allowance for a full year on D; bob for 185 days on d2.
        uint256 expectedAllowance = (D * HURDLE_BPS * YEAR + d2 * HURDLE_BPS * 185 days) / (10_000 * YEAR);
        uint256 net = _net(g);
        uint256 expectedShare = (net - expectedAllowance) * SHARE_BPS / 10_000;

        uint256 feesBefore = treasury.pendingFees();
        vm.prank(manager);
        vault.claimMusharakahProfit(g);
        assertApproxEqAbs(treasury.pendingFees() - feesBefore, expectedShare, 1, "allowance kept + new capital from now");
    }

    function test_firstDepositAfterEveryoneExited_restartsClock() public {
        skip(400 days);
        uint256 all = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(all, alice, alice);
        assertEq(vault.totalSupply(), 0);
        skip(100 days);
        uint256 amt = 500e6;
        _depositAs(bob, amt);
        assertEq(vault.hurdleStartTime(), block.timestamp, "clock restarts");
        assertEq(vault.hurdlePrincipal(), amt, "principal = new first deposit");
    }

    function test_zeroHurdlePrincipal_isSeededWithAssetsPlusDeposit_andClockRestarts() public {
        // Setter refuses decreases on a live vault: force the zero basis by storage write.
        stdstore.target(address(vault)).sig("hurdlePrincipal()").checked_write(uint256(0));
        assertEq(vault.hurdlePrincipal(), 0);
        skip(200 days);
        usdc.mint(address(vault), 7e6); // donation counts in current assets
        uint256 assetsNow = vault.totalAssetsBeforeDistributionCut(); // gross assets, no gold in this fixture
        uint256 amt = 250e6;
        _depositAs(bob, amt);
        assertEq(vault.hurdlePrincipal(), assetsNow + amt, "seeded with current assets + deposit");
        assertEq(vault.hurdleStartTime(), block.timestamp, "clock restarts");
    }

    // ───────────── depositHurdle arithmetic ─────────────

    function test_depositHurdle_unit() public {
        vm.warp(1_000_000);
        (uint256 s, uint256 p) = ShariahAccountingLogic.depositHurdle(0, 0, 0, 55, 9);
        assertEq(s, 1_000_000);
        assertEq(p, 9, "supply == 0 -> principal = deposit");
        (s, p) = ShariahAccountingLogic.depositHurdle(123, 0, 5, 100, 20);
        assertEq(s, 1_000_000);
        assertEq(p, 120, "principal == 0 -> assets + deposit");
        (s, p) = ShariahAccountingLogic.depositHurdle(1_000_000 - 800, 100, 5, 100, 300);
        assertEq(p, 400);
        assertEq(s, 1_000_000 - 200, "t' = 800 * 100 / 400");
        (s, p) = ShariahAccountingLogic.depositHurdle(2_000_000, 100, 5, 100, 300); // start in the future
        assertEq(s, 1_000_000, "future start -> now");
        assertEq(p, 400);
    }

    function testFuzz_depositHurdle_preservesAllowanceAndNeverUnderflows(
        uint256 start, uint256 principal, uint256 supply, uint256 assetsNow, uint256 assets, uint256 nowTs
    ) public {
        nowTs = bound(nowTs, 1, type(uint64).max);
        vm.warp(nowTs);
        start = bound(start, 0, nowTs);
        principal = bound(principal, 1, 1e30);
        assets = bound(assets, 0, 1e30);
        supply = bound(supply, 1, type(uint128).max);
        (uint256 s, uint256 p) = ShariahAccountingLogic.depositHurdle(start, principal, supply, assetsNow, assets);
        assertEq(p, principal + assets);
        assertLe(s, nowTs, "start never beyond now");
        assertGe(s, start, "clock never moves earlier");
        uint256 elapsed = nowTs - start;
        // allowance (P' * t') never exceeds, and loses < one second of new principal vs (P * t).
        assertLe(p * (nowTs - s), principal * elapsed, "never inflates the accrued allowance");
        assertGt(p * (nowTs - s) + p, principal * elapsed, "loses less than one second on the new principal");
    }

    function testFuzz_depositHurdle_hugeValues_noUnderflow(
        uint256 start, uint256 principal, uint256 supply, uint256 assetsNow, uint256 assets, uint256 nowTs
    ) public {
        nowTs = bound(nowTs, 1, type(uint64).max);
        vm.warp(nowTs);
        start = bound(start, 0, type(uint256).max);
        principal = bound(principal, 0, type(uint256).max / 2);
        assets = bound(assets, 0, type(uint256).max / 2);
        assetsNow = bound(assetsNow, 0, type(uint256).max / 2);
        (uint256 s, uint256 p) = ShariahAccountingLogic.depositHurdle(start, principal, supply, assetsNow, assets);
        assertLe(s, nowTs, "start never beyond now");
        if (supply == 0) assertEq(p, assets);
        else if (principal == 0) assertEq(p, assetsNow + assets);
        else {
            assertEq(p, principal + assets);
            if (start < nowTs) assertGe(s, start);
        }
    }
}

contract TaskReviewR3V1Test is TaskN27V1Fixture, TaskReviewR3Tests {
    function setUp() public override(TaskN27Base, TaskReviewR3Tests) {
        TaskReviewR3Tests.setUp();
    }
}

contract TaskReviewR3V2Test is TaskN27V2Fixture, TaskReviewR3Tests {
    function setUp() public override(TaskN27Base, TaskReviewR3Tests) {
        TaskReviewR3Tests.setUp();
    }
}
