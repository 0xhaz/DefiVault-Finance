// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/Test.sol";

import {TaskN29V1Mixin, TaskN29V2Mixin} from "./TaskN29Test.Base.t.sol";
import {TaskR5Base} from "./TaskReviewR5Test.Base.t.sol";

/// @dev R5 measurement: smallest outer gas limit at which the exit does not revert, and whether the cut ran there.
///      Inner exitSettle gas is read from `forge test --gas-report` (ShariahVault::exitSettle max column).
abstract contract TaskR5Measure is TaskR5Base {
    /// @dev strict=false is log-only (hostile 90k/read case: valuation reads may exceed the settlement budget).
    ///      Heavy reads (burn > 0) run redeem full / withdraw full only, to keep runtime down.
    function _run(uint256 n, uint256 burn, bool deficit, bool strict) internal {
        uint256 modes = burn == 0 ? 4 : 2;
        _adapters(n, burn);
        _yield(200e6);
        if (deficit) _writeHwm(1_200_000_000_000);
        for (uint256 m; m < modes; ++m) {
            bool w = m & 1 == 1;
            bool p = m & 2 == 2;
            (uint256 minG, bool settled) = strict ? _minOk(w, p) : _minOkOrZero(w, p);
            console2.log(
                string.concat(
                    "R5 n=", vm.toString(n), " burn=", vm.toString(burn), " deficit=", deficit ? "1" : "0",
                    w ? " withdraw" : " redeem", p ? " part" : " full"
                ),
                minG,
                settled ? 1 : 0
            );
            if (strict) assertTrue(settled, "cut routed at the minimum non-reverting gas");
            if (minG != 0) assertGe(minG, _floor(), "min gas at least the floor"); // 0 = never succeeds <= 12M (log-only)
        }
    }

    /// @dev Single generous-gas exit; read ShariahVault::exitSettle gas from the -vvvv trace.
    function _inner(uint256 n, uint256 burn, bool deficit, bool w, bool p) internal {
        _adapters(n, burn);
        _yield(200e6);
        if (deficit) _writeHwm(1_200_000_000_000);
        (bool ok, bool settled,) = _attempt(40_000_000, w, p);
        assertTrue(ok);
        assertTrue(settled, "settles with ample gas");
    }

    function test_inner_1_noDef_redeemFull() public { _inner(1, 0, false, false, false); }
    function test_inner_1_def_withdrawPart() public { _inner(1, 0, true, true, true); }
    function test_inner_10_noDef_redeemFull() public { _inner(10, 0, false, false, false); }
    function test_inner_10_def_redeemPart() public { _inner(10, 0, true, false, true); }
    function test_inner_10_def_withdrawFull() public { _inner(10, 0, true, true, false); }
    function test_inner_10_burn5k_def() public { _inner(10, 5_000, true, false, false); }
    function test_inner_10_burn20k_def() public { _inner(10, 20_000, true, false, false); }
    function test_inner_10_burn90k_def() public { _inner(10, 90_000, true, false, false); }

    function test_measure_1adapter_noDeficit() public {
        _run(1, 0, false, true);
    }

    function test_measure_1adapter_deficit() public {
        _run(1, 0, true, true);
    }

    function test_measure_10adapters_noDeficit() public {
        _run(10, 0, false, true);
    }

    function test_measure_10adapters_deficit() public {
        _run(10, 0, true, true);
    }

    function test_measure_10adapters_heavyReads_noDeficit() public {
        _run(10, 5_000, false, true);
    }

    function test_measure_10adapters_heavyReads_deficit() public {
        _run(10, 20_000, true, true);
    }

    function test_measure_10adapters_heavyReads5k_deficit() public {
        _run(10, 5_000, true, true);
    }

    function test_measure_10adapters_heavyReads20k_noDeficit() public {
        _run(10, 20_000, false, true);
    }

    /// @dev Hostile 90k/read valuation: log-only (cut routing at the minimum G is reported, not asserted).
    function test_measure_10adapters_hostile90k_deficit_logOnly() public {
        _run(10, 90_000, true, false);
    }
}

contract TaskR5MeasureV1Test is TaskR5Measure, TaskN29V1Mixin {}

contract TaskR5MeasureV2Test is TaskR5Measure, TaskN29V2Mixin {}
