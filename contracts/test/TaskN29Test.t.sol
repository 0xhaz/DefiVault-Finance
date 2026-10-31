// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm, console2} from "forge-std/Test.sol";

import {ShariahVault} from "../ShariahVault.sol";
import {TaskN29Base, TaskN29V1Mixin, TaskN29V2Mixin} from "./TaskN29Test.Base.t.sol";

/// @dev N-29 economics: exit settlement fairness, price continuity, late entrants, distribution routing.
abstract contract TaskN29Core is TaskN29Base {
    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    // ───────────── exit-before-claim fairness ─────────────

    function test_exitBeforeClaim_paysSameAsExitAfterFullClaim_redeem() public {
        _yield(200e6);
        uint256 snap = vm.snapshotState();
        uint256 before_ = _redeemFrac(bob, 1, 2);
        vm.revertToState(snap);
        _claimAll();
        uint256 after_ = _redeemFrac(bob, 1, 2);
        assertApproxEqAbs(before_, after_, TOL, "exit before claim == exit after full claim");
    }

    function test_exitBeforeClaim_paysSameAsExitAfterFullClaim_withdraw() public {
        _yield(200e6);
        uint256 snap = vm.snapshotState();
        uint256 want = vault.previewRedeem(vault.balanceOf(bob) / 4);
        vm.prank(bob);
        vault.withdraw(want, bob, bob);
        uint256 sharesLeft = vault.balanceOf(bob);
        vm.revertToState(snap);
        _claimAll();
        vm.prank(bob);
        vault.withdraw(want, bob, bob);
        // Same assets, same burned shares (within virtual-share rounding).
        assertApproxEqAbs(vault.balanceOf(bob), sharesLeft, 1e13);
    }

    function test_exitBeforeClaim_fullHolder_paysSameAsAfterClaim() public {
        _yield(200e6);
        uint256 snap = vm.snapshotState();
        uint256 a = _redeemFrac(alice, 1, 1);
        vm.revertToState(snap);
        _claimAll();
        uint256 b = _redeemFrac(alice, 1, 1);
        assertApproxEqAbs(a, b, TOL);
    }

    function testFuzz_exitBeforeClaim_equalsAfterClaim(uint256 y, uint256 num, uint256 elapsedDays) public {
        y = bound(y, 1e6, 5_000e6);
        num = bound(num, 1, 100);
        elapsedDays = bound(elapsedDays, 1, 720);
        skip(elapsedDays * 1 days);
        usdc.mint(address(vault), y);
        uint256 snap = vm.snapshotState();
        uint256 a = _redeemFrac(bob, num, 100);
        vm.revertToState(snap);
        _claimAll();
        uint256 b = _redeemFrac(bob, num, 100);
        assertApproxEqAbs(a, b, 50, "fairness holds across yield, fraction and elapsed time");
    }

    // ───────────── stayers are unaffected ─────────────

    function _noHurdle() internal {
        _forceHurdlePrincipal(0);
    }

    /// @dev Exit allocates hurdle and deficit allowance pro rata to the leaver, so the stayers' value must be
    ///      unchanged in BOTH directions (tolerance: 10 wei + 1e-9 relative). Logs the measured drift.
    function _assertStayerUnchanged(uint256 before_, uint256 after_, string memory tag) internal view {
        console2.log(tag, "stayer drift (wei):", _absDiff(before_, after_));
        assertApproxEqAbs(after_, before_, _driftTol(before_), tag);
    }

    function test_exit_doesNotMoveRemainingHoldersPrice() public {
        _noHurdle();
        _yield(200e6);
        uint256 aliceBefore = _value(alice);
        _redeemFrac(bob, 1, 2);
        assertApproxEqAbs(_value(alice), aliceBefore, TOL, "alice price after bob's partial exit");
        _redeemFrac(bob, 1, 1);
        assertApproxEqAbs(_value(alice), aliceBefore, TOL, "alice price after bob's full exit");
    }

    /// @dev Non-zero hurdle: a partial exit leaves the stayers' previewRedeem unchanged (a few wei).
    function test_exit_withHurdle_stayerDriftBounded() public {
        _yield(200e6);
        assertGt(vault.hurdlePrincipal(), 0);
        uint256 aliceBefore = _value(alice);
        _redeemFrac(bob, 1, 2);
        _assertStayerUnchanged(aliceBefore, _value(alice), "hurdle only, half exit");
    }

    /// @dev Non-zero hurdle AND non-zero HWM deficit: still unchanged, for several exit fractions.
    function test_exit_withHurdleAndDeficit_stayerUnchanged() public {
        _yield(200e6);
        _writeHwm(1_020_000_000_000);
        assertGt(vault.hwmDeficit(), 0);
        assertGt(vault.hurdlePrincipal(), 0);
        uint256 aliceBefore = _value(alice);
        _redeemFrac(bob, 1, 2);
        _assertStayerUnchanged(aliceBefore, _value(alice), "hurdle+deficit, 1/2 exit");
        aliceBefore = _value(alice);
        _redeemFrac(bob, 1, 3);
        _assertStayerUnchanged(aliceBefore, _value(alice), "hurdle+deficit, 1/3 of remainder");
    }

    /// @dev Deficit exceeding profit: the leaver's share is all recovery; stayers unchanged.
    function test_exit_withHurdleAndLargeDeficit_stayerUnchanged() public {
        _yield(200e6);
        _writeHwm(1_200_000_000_000);
        assertGt(vault.hwmDeficit(), 195e6);
        uint256 aliceBefore = _value(alice);
        _redeemFrac(bob, 3, 4);
        _assertStayerUnchanged(aliceBefore, _value(alice), "large deficit, 3/4 exit");
    }

    function test_exit_stayersCutStillReservedAfterExit() public {
        _noHurdle();
        _yield(200e6);
        uint256 cutBefore = vault.pendingDistributionCut();
        _redeemFrac(bob, 1, 1);
        // Bob's half of the cut left with him; alice's half is still reserved against her profit.
        assertApproxEqAbs(vault.pendingDistributionCut(), cutBefore / 2, 3);
        assertApproxEqAbs(vault.realizedProfit(), 100e6, 3);
    }

    function testFuzz_exit_doesNotMoveRemainingHoldersPrice(
        uint256 y, uint256 num, uint256 hurdleOn, uint256 hwm
    ) public {
        y = bound(y, 1e6, 5_000e6);
        num = bound(num, 1, 99);
        bool withHurdle = hurdleOn % 2 == 1;
        if (!withHurdle) _noHurdle();
        _yield(y);
        // Half of the runs also carry a non-zero HWM deficit (up to +15% over the launch price).
        if (hwm % 2 == 1) {
            _writeHwm(bound(hwm, 1_001_000_000_000, 1_150_000_000_000));
            assertGt(vault.hwmDeficit(), 0);
        }
        uint256 aliceBefore = _value(alice);
        _redeemFrac(bob, num, 100);
        assertApproxEqAbs(_value(alice), aliceBefore, _driftTol(aliceBefore), "stayer unchanged (hurdle and/or deficit)");
    }

    // ───────────── two-step exit ≤ one full exit ─────────────

    function test_twoStepExit_paysNoMoreThanOneFullExit() public {
        _yield(200e6);
        uint256 snap = vm.snapshotState();
        uint256 one = _redeemFrac(bob, 1, 1);
        vm.revertToState(snap);
        uint256 two = _redeemFrac(bob, 1, 2) + _redeemFrac(bob, 1, 1);
        assertLe(two, one + TOL, "splitting an exit cannot extract more");
        assertApproxEqAbs(two, one, TOL);
    }

    function testFuzz_twoStepExit_paysNoMoreThanOneFullExit(uint256 y, uint256 num) public {
        y = bound(y, 1e6, 5_000e6);
        num = bound(num, 1, 99);
        _yield(y);
        uint256 snap = vm.snapshotState();
        uint256 one = _redeemFrac(bob, 1, 1);
        vm.revertToState(snap);
        uint256 two = _redeemFrac(bob, num, 100) + _redeemFrac(bob, 1, 1);
        assertLe(two, one + 50);
    }

    // ───────────── last holder ─────────────

    function test_lastHolderExit_leavesNothingStranded() public {
        _yield(200e6);
        _redeemFrac(bob, 1, 1);
        _redeemFrac(alice, 1, 1);
        assertEq(vault.totalSupply(), 0);
        assertLe(vault.totalAssets(), 2);
        assertLe(vault.realizedProfit(), 2, "no realized profit stranded");
        assertLe(vault.totalAssetsBeforeDistributionCut(), 2);
        assertLe(vault.pendingDistributionCut(), 2);
    }

    function test_lastHolderExit_afterPartialClaim() public {
        _yield(200e6);
        _claim(vault.realizedProfit() / 3);
        _redeemFrac(alice, 1, 1);
        _redeemFrac(bob, 1, 1);
        assertLe(vault.totalAssets(), 2);
        assertLe(vault.realizedProfit(), 2);
    }

    function testFuzz_lastHolderExit_leavesNothingStranded(uint256 y, uint256 bobFirst) public {
        y = bound(y, 0, 5_000e6);
        _yield(y);
        // Virtual-share dust scales with NAV (1e6 virtual shares over a 2e15 supply = 5e-10 of NAV).
        uint256 dust = 2 + vault.totalAssetsBeforeDistributionCut() / 1e9;
        if (bobFirst % 2 == 0) {
            _redeemFrac(bob, 1, 1);
            _redeemFrac(alice, 1, 1);
        } else {
            _redeemFrac(alice, 1, 1);
            _redeemFrac(bob, 1, 1);
        }
        assertLe(vault.totalAssets(), dust);
        assertLe(vault.realizedProfit(), dust);
    }

    // ───────────── price continuity ─────────────

    function test_priceContinuity_acrossFullClaim() public {
        _yield(200e6);
        uint256 before_ = _value(alice);
        _claimAll();
        assertApproxEqAbs(_value(alice), before_, TOL, "full claim must not move the share price");
        assertEq(vault.pendingDistributionCut(), 0, "nothing left to reserve");
    }

    function test_priceContinuity_acrossPartialClaims() public {
        _yield(200e6);
        uint256 before_ = _value(alice);
        _claim(vault.realizedProfit() / 4);
        assertApproxEqAbs(_value(alice), before_, TOL, "first partial claim");
        _claim(vault.realizedProfit() / 2);
        assertApproxEqAbs(_value(alice), before_, TOL, "second partial claim");
        _claimAll();
        assertApproxEqAbs(_value(alice), before_, TOL, "final claim");
    }

    function testFuzz_priceContinuity_acrossClaims(uint256 y, uint256 frac) public {
        y = bound(y, 1e6, 5_000e6);
        frac = bound(frac, 1, 100);
        _yield(y);
        uint256 before_ = _value(alice);
        _claim(_min((vault.realizedProfit() * frac) / 100 + 1, vault.realizedProfit()));
        assertApproxEqAbs(_value(alice), before_, 50);
    }

    // ───────────── late depositor ─────────────

    function test_lateDepositor_withUnclaimedYield_paysFairPrice() public {
        _yield(200e6);
        uint256 aliceBefore = _value(alice);
        vm.prank(carol);
        uint256 shares = vault.deposit(DEP, carol);
        assertApproxEqAbs(vault.previewRedeem(shares), DEP, TOL, "late entrant owns exactly what she paid");
        assertApproxEqAbs(_value(alice), aliceBefore, TOL, "incumbent price unchanged by entrant");
        // Entering before or after the claim buys the same number of shares.
        uint256 snap = vm.snapshotState();
        _claimAll();
        vm.prank(stranger);
        uint256 afterClaim = vault.previewDeposit(DEP);
        vm.revertToState(snap);
        assertApproxEqAbs(shares, afterClaim, 1e13);
    }

    function test_lateDepositor_immediateExit_isNeitherProfitNorLoss() public {
        _noHurdle();
        _yield(200e6);
        uint256 aliceBefore = _value(alice);
        uint256 bal = usdc.balanceOf(carol);
        vm.prank(carol);
        vault.deposit(DEP, carol);
        _redeemFrac(carol, 1, 1);
        assertApproxEqAbs(usdc.balanceOf(carol), bal, TOL, "round trip returns the deposit");
        assertApproxEqAbs(_value(alice), aliceBefore, TOL, "incumbent unaffected by the round trip");
    }

    function test_lateDepositor_immediateExit_withHurdle_incumbentNeverEnriched() public {
        _yield(200e6);
        uint256 aliceBefore = _value(alice);
        uint256 bal = usdc.balanceOf(carol);
        vm.prank(carol);
        vault.deposit(DEP, carol);
        _redeemFrac(carol, 1, 1);
        assertApproxEqAbs(usdc.balanceOf(carol), bal, TOL, "round trip returns the deposit");
        _assertStayerUnchanged(aliceBefore, _value(alice), "late depositor round trip, hurdle on");
    }

    function testFuzz_lateDepositor_noValueTransfer(uint256 y, uint256 dep) public {
        y = bound(y, 1e6, 5_000e6);
        dep = bound(dep, 1e6, 100_000e6);
        _yield(y);
        uint256 aliceBefore = _value(alice);
        vm.prank(carol);
        uint256 shares = vault.deposit(dep, carol);
        assertApproxEqAbs(vault.previewRedeem(shares), dep, 50);
        assertApproxEqAbs(_value(alice), aliceBefore, 50);
    }

    // ───────────── ordinary accounting unchanged ─────────────

    function test_realizedProfit_isGrossAndUnchangedByCut() public {
        _yield(200e6);
        assertEq(vault.realizedProfit(), 200e6, "realizedProfit is gross, not net of the reserve");
        assertGt(vault.pendingDistributionCut(), 0);
        assertEq(vault.totalAssets(), vault.totalAssetsBeforeDistributionCut() - vault.pendingDistributionCut());
    }

    function test_ordinaryClaim_amountsUnchanged() public {
        _yield(200e6);
        uint256 hurdle = (2 * DEP * 400 * 30 days) / (10_000 * 365 days);
        uint256 charityAmt = (200e6 * 250) / 10_000;
        uint256 vaultShare = ((200e6 - charityAmt - hurdle) * 1000) / 10_000;
        vm.expectEmit(false, false, false, true, address(vault));
        emit MusharakahProfitClaimed(200e6, 0, charityAmt, vaultShare, 200e6 - charityAmt - vaultShare);
        _claim(200e6);
        assertEq(charity.totalCharityDistributed(), charityAmt);
        assertEq(treasury.pendingFees(), vaultShare);
        assertEq(usdc.balanceOf(charityWallet), charityAmt);
    }

    function test_cutMatchesClaimCost() public {
        _yield(200e6);
        uint256 cut = vault.pendingDistributionCut();
        _claimAll();
        assertEq(_distributed(), cut, "reserved cut equals what a full claim distributes");
    }
}

contract TaskN29CoreV1Test is TaskN29Core, TaskN29V1Mixin {}

contract TaskN29CoreV2Test is TaskN29Core, TaskN29V2Mixin {}
