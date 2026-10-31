// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TaskN26Core} from "./TaskN26Test.Core.t.sol";

/// @dev N-26 groups (d)-(g): time between claims, edge cases, HWM-before-hurdle, fuzz.
abstract contract TaskN26Edge is TaskN26Core {
    // ── (d) time between partial claims still accrues extra hurdle ─────────────────
    function test_d_delayBetweenClaims_accruesExtraHurdle() public {
        _accrue(YEAR, 100e6);
        _claim(20e6); // below the 40e6 hurdle -> carries
        uint256 remaining = _hurdleNow();
        skip(180 days);
        uint256 extra = vault.hurdlePrincipal() * RATE * 180 days / (10_000 * YEAR);
        assertGt(extra, 0);
        assertApproxEqAbs(_hurdleNow(), remaining + extra, 1, "allowance = carried + new accrual");
        uint256 expected = _expectedFee(80e6);
        uint256 fee = _claimFee(80e6);
        assertEq(fee, expected);
        uint256 closed = (_net(80e6) - (remaining + extra)) * SHARE / 10_000;
        assertApproxEqAbs(fee, closed, 1);
    }

    function test_d_delayedSecondClaim_paysLessThanImmediate() public {
        _accrue(YEAR, 100e6);
        _claim(20e6);
        uint256 snap = vm.snapshot();
        uint256 immediate = _claimFee(80e6);
        assertTrue(vm.revertTo(snap));
        skip(180 days);
        uint256 delayed = _claimFee(80e6);
        assertLt(delayed, immediate, "extra elapsed time = extra hurdle = less surplus");
    }

    function test_d_delay_splitNeverExceedsSingleClaimAtSameFinalTime() public {
        _accrue(YEAR, 100e6);
        uint256 snap = vm.snapshot();
        skip(90 days);
        uint256 full = _claimFee(100e6);
        assertTrue(vm.revertTo(snap));
        _claim(20e6);
        uint256 newP = vault.hurdlePrincipal(); // carried allowance now accrues on the larger post-claim principal
        skip(90 days);
        uint256 split = _claimFee(80e6);
        assertLe(split, full + 1);
        // The only difference: 90 days of hurdle on the extra (newP - DEP) of principal, times the share.
        uint256 gap = (newP - DEP) * RATE * 90 days / (10_000 * YEAR) * SHARE / 10_000;
        assertApproxEqAbs(full - split, gap, 3 * TOL);
    }

    function test_d_afterReset_hurdleAccruesFromNowOnNewPrincipal() public {
        _accrue(YEAR, 100e6);
        _claim(100e6); // consumed -> start == now
        skip(YEAR);
        usdc.mint(address(vault), 50e6);
        uint256 p = vault.hurdlePrincipal();
        assertEq(_hurdleNow(), p * RATE / 10_000);
        uint256 fee = _claimFee(50e6);
        assertApproxEqAbs(fee, (_net(50e6) - p * RATE / 10_000) * SHARE / 10_000, 1);
    }

    // ── (e) edge cases ──────────────────────────────────────────────────────────────
    function test_e_zeroHurdleRate_noRevert_startIsNow_fullShare() public {
        vm.prank(address(vault));
        treasury.setMusharakahParams(SHARE, 0);
        _accrue(YEAR, 100e6);
        assertEq(_claimFee(30e6), _net(30e6) * SHARE / 10_000);
        assertEq(vault.hurdleStartTime(), block.timestamp);
        assertEq(_claimFee(30e6), _net(30e6) * SHARE / 10_000);
    }

    function test_e_zeroPrincipal_noRevert_startIsNow() public {
        _forceHurdlePrincipal(0);
        _accrue(YEAR, 100e6);
        assertEq(_claimFee(40e6), _net(40e6) * SHARE / 10_000, "zero principal = zero hurdle");
        assertEq(vault.hurdleStartTime(), block.timestamp);
    }

    function test_e_zeroElapsed_claimSameTimestampAsReset() public {
        _accrue(0, 10e6);
        assertEq(vault.hurdleStartTime(), block.timestamp);
        assertEq(_claimFee(10e6), _net(10e6) * SHARE / 10_000);
        assertEq(vault.hurdleStartTime(), block.timestamp);
    }

    function test_e_veryLargeElapsed_noRevert_startNotInFuture() public {
        _accrue(10_000 * YEAR, 100e6);
        uint256 f1 = _claimFee(30e6); // hurdle astronomically larger than profit
        assertEq(f1, 0);
        assertLe(vault.hurdleStartTime(), block.timestamp);
        assertLt(vault.hurdleStartTime(), block.timestamp, "allowance still unconsumed");
        _claim(30e6);
        assertLe(vault.hurdleStartTime(), block.timestamp);
    }

    function test_e_unrepresentableLookback_clampsToZero_andNextClaimWorks() public {
        vm.prank(owner);
        vault.setHurdlePrincipal(1e30); // remaining allowance >> newPrincipal*rate*now
        _accrue(YEAR, 100e6);
        assertEq(_claimFee(10e6), 0);
        assertEq(vault.hurdleStartTime(), 0, "clamped, not underflowed");
        // next claim: elapsed == block.timestamp; must not revert or underflow
        assertEq(_claimFee(10e6), 0);
        assertLe(vault.hurdleStartTime(), block.timestamp);
    }

    function test_e_hurdleBarelyAboveNet_remainingOneWei_stillSane() public {
        _accrue(YEAR, 10e6);
        uint256 n = _net(10e6);
        _forceHurdlePrincipal(n * 10_000 / RATE + 100); // hurdle = n + 4 (floor)
        uint256 h = _hurdleNow();
        assertGt(h, n);
        assertEq(_claimFee(10e6), 0);
        assertLe(vault.hurdleStartTime(), block.timestamp);
        assertApproxEqAbs(_hurdleNow(), h - n, TOL);
    }

    // ── (f) HWM deficit is consumed before the hurdle ───────────────────────────────
    function _lossScenario() internal returns (uint256 deficit) {
        usdc.mint(address(vault), 100e6);
        _claim(100e6);
        skip(vault.profitUnlockPeriod());
        usdc.burn(address(vault), 200e6);
        _deposit(1_000e6);
        skip(YEAR);
        usdc.mint(address(vault), 600e6);
        deficit = vault.hwmDeficit();
        assertGt(deficit, 0);
    }

    function test_f_singleClaim_deficitThenHurdleThenShare() public {
        uint256 deficit = _lossScenario();
        uint256 h = _hurdleNow();
        assertGt(h, 0);
        uint256 net = _net(400e6);
        assertGt(net, deficit + h, "scenario must clear both");
        uint256 expected = _expectedFee(400e6);
        (, uint256 viaTreasury,) = treasury.calculateMusharakahSplitHWM(
            net, block.timestamp - vault.hurdleStartTime(), vault.hurdlePrincipal(), deficit
        );
        assertEq(expected, viaTreasury);
        assertEq(_claimFee(400e6), expected);
        assertApproxEqAbs(expected, (net - deficit - h) * SHARE / 10_000, 1);
        assertEq(vault.hurdleStartTime(), block.timestamp);
    }

    function test_f_claimWithinDeficit_paysZero_andPreservesFullHurdle() public {
        uint256 deficit = _lossScenario();
        uint256 h = _hurdleNow();
        uint256 gross = deficit / 2;
        assertLt(_net(gross), deficit);
        assertEq(_claimFee(gross), 0, "recovery first");
        // Nothing reached the hurdle, so the whole allowance is preserved.
        assertLt(vault.hurdleStartTime(), block.timestamp);
        assertApproxEqAbs(_hurdleNow(), h, 2 * TOL);
    }

    function test_f_deficitThenHurdleAcrossPartialClaims_matchesSingleClaim() public {
        _lossScenario();
        uint256 snap = vm.snapshot();
        uint256 full = _claimFee(400e6);
        assertGt(full, 0);
        assertTrue(vm.revertTo(snap));
        uint256 split = _claimInChunks(400e6, 4);
        assertLe(split, full + 2);
        assertApproxEqAbs(split, full, 4 * TOL);
    }

    // ── (g) fuzz ────────────────────────────────────────────────────────────────────
    function testFuzz_g_splitFeeNeverExceedsFull(uint256 elapsed, uint256 total, uint256 splitAt) public {
        elapsed = bound(elapsed, 1 days, 30 * YEAR);
        total = bound(total, 2e6, 400e6);
        splitAt = bound(splitAt, 1, total - 1);
        _accrue(elapsed, total);
        uint256 snap = vm.snapshot();
        uint256 full = _claimFee(total);
        assertTrue(vm.revertTo(snap));
        uint256 split = _claimFee(splitAt);
        assertLe(vault.hurdleStartTime(), block.timestamp);
        split += _claimFee(total - splitAt);
        assertLe(vault.hurdleStartTime(), block.timestamp);
        assertLe(split, full + TOL, "split manager fee <= single claim fee + rounding");
        assertApproxEqAbs(split, full, TOL);
    }

    function testFuzz_g_delayedSecondClaim_neverExceedsSingleClaimAtFinalTime(
        uint256 elapsed, uint256 delay, uint256 total, uint256 splitAt
    ) public {
        elapsed = bound(elapsed, 1 days, 10 * YEAR);
        delay = bound(delay, 0, 5 * YEAR);
        total = bound(total, 2e6, 400e6);
        _accrue(elapsed, total);
        // Carry semantics apply when the first claim stays within the hurdle.
        uint256 h = _hurdleNow();
        splitAt = bound(splitAt, 1, h < total - 1 ? h : total - 1);
        uint256 snap = vm.snapshot();
        skip(delay);
        uint256 full = _claimFee(total);
        assertTrue(vm.revertTo(snap));
        uint256 split = _claimFee(splitAt);
        skip(delay);
        split += _claimFee(total - splitAt);
        assertLe(vault.hurdleStartTime(), block.timestamp);
        assertLe(split, full + TOL, "carried allowance never lets the manager earn more");
    }
}
