// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TaskN26Base} from "./TaskN26Test.Base.t.sol";

/// @dev N-26 groups (a)-(c): split-vs-full equivalence, below-hurdle first claim, full consumption reset.
abstract contract TaskN26Core is TaskN26Base {
    uint256 internal constant TOL = 6; // wei, per the ceil-rounded lookback

    // ── (a) one claim vs N partial claims at the same timestamp ─────────────────────
    function _assertSplitEqualsFull(uint256 elapsed, uint256 total, uint256 n) internal {
        _accrue(elapsed, total);
        (uint256 full, uint256 split) = _fullVsChunks(total, n);
        assertLe(split, full + 1, "split claims never pay the manager more");
        assertApproxEqAbs(split, full, TOL, "split ~= full within rounding");
    }

    function test_a_twoClaims_sameFeeAsOne_afterYear() public {
        _assertSplitEqualsFull(YEAR, 100e6, 2);
    }

    function test_a_fiveClaims_sameFeeAsOne_afterYear() public {
        _assertSplitEqualsFull(YEAR, 100e6, 5);
    }

    function test_a_twentyClaims_sameFeeAsOne_afterYear() public {
        _assertSplitEqualsFull(YEAR, 100e6, 20);
    }

    function test_a_manyClaims_oddAmounts_shortElapsed() public {
        _accrue(37 days + 12345, 7_654_321);
        (uint256 full, uint256 split) = _fullVsChunks(7_654_321, 7);
        assertLe(split, full + 1);
        assertApproxEqAbs(split, full, TOL);
    }

    function test_a_totalBelowHurdle_bothPayZero() public {
        _accrue(YEAR, 30e6); // hurdle on 1000e6 @4% for a year = 40e6
        (uint256 full, uint256 split) = _fullVsChunks(30e6, 3);
        assertEq(full, 0);
        assertEq(split, 0);
    }

    function test_a_fullClaimMatchesTreasuryFormula() public {
        _accrue(YEAR, 100e6);
        uint256 expected = _expectedFee(100e6);
        assertGt(expected, 0);
        assertEq(_claimFee(100e6), expected);
        // 10% share of (net - 40e6 hurdle)
        assertApproxEqAbs(expected, (_net(100e6) - 40e6) * SHARE / 10_000, 1);
    }

    // ── (b) first claim below the hurdle ────────────────────────────────────────────
    function test_b_firstClaimBelowHurdle_paysZero_movesStartBack() public {
        _accrue(YEAR, 100e6);
        uint256 startBefore = vault.hurdleStartTime();
        uint256 nowTs = block.timestamp;
        assertEq(_claimFee(20e6), 0, "net 20e6 < 40e6 hurdle -> manager earns nothing");
        uint256 start = vault.hurdleStartTime();
        assertLt(start, nowTs, "unused allowance preserved by a start time in the past");
        assertGt(start, startBefore, "but the consumed part is gone");
        // remaining allowance (against the new principal) ~= H - net
        uint256 remaining = 40e6 - _net(20e6);
        assertGe(_hurdleNow(), remaining, "ceil lookback never discards allowance");
        assertApproxEqAbs(_hurdleNow(), remaining, TOL);
    }

    function test_b_secondClaim_paysOnlyShareOfPminusH() public {
        _accrue(YEAR, 100e6);
        _claim(20e6);
        uint256 expected = _expectedFee(80e6);
        uint256 fee = _claimFee(80e6);
        assertEq(fee, expected, "matches calculateMusharakahSplitHWM on the carried state");
        assertGt(fee, 0);
        uint256 closedForm = (_net(20e6) + _net(80e6) - 40e6) * SHARE / 10_000;
        assertApproxEqAbs(fee, closedForm, TOL);
    }

    function test_b_secondClaim_stillBelowHurdle_stillZero_andStartMovesFurther() public {
        _accrue(YEAR, 100e6);
        _claim(10e6);
        uint256 s1 = vault.hurdleStartTime();
        assertEq(_claimFee(10e6), 0);
        uint256 s2 = vault.hurdleStartTime();
        assertGt(s2, s1, "more allowance consumed -> start moves forward");
        assertLt(s2, block.timestamp);
        assertApproxEqAbs(_hurdleNow(), 40e6 - _net(10e6) - _net(10e6), TOL);
    }

    // ── (c) fully consumed hurdle resets start to now ───────────────────────────────
    function test_c_fullyConsumed_singleClaim_resetsToNow() public {
        _accrue(YEAR, 100e6);
        _claim(100e6);
        assertEq(vault.hurdleStartTime(), block.timestamp);
        assertEq(_hurdleNow(), 0);
    }

    function test_c_consumedBySecondClaim_resetsToNow() public {
        _accrue(YEAR, 100e6);
        _claim(20e6);
        assertLt(vault.hurdleStartTime(), block.timestamp);
        _claim(80e6);
        assertEq(vault.hurdleStartTime(), block.timestamp);
    }

    function test_c_afterReset_nextClaimSameBlockPaysFullShare() public {
        _accrue(YEAR, 100e6);
        _claim(60e6);
        assertEq(vault.hurdleStartTime(), block.timestamp);
        _accrue(0, 10e6);
        assertEq(_claimFee(10e6), _net(10e6) * SHARE / 10_000, "no hurdle left at the same timestamp");
    }

    function test_c_netEqualsHurdle_exactly_resetsToNow() public {
        _accrue(YEAR, 10e6);
        uint256 n = _net(10e6);
        // principal such that floor(principal*RATE*YEAR/(10_000*YEAR)) == n exactly
        vm.prank(owner);
        vault.setHurdlePrincipal(n * 10_000 / RATE);
        assertEq(_hurdleNow(), n);
        assertEq(_claimFee(10e6), 0);
        assertEq(vault.hurdleStartTime(), block.timestamp, "remaining allowance is zero -> reset");
    }
}
