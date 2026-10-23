// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title  TaskI — Item I3: TreasuryModule.calculateMusharakahSplitHWM
/// @notice Tests 16-20 from the Task-I specification.
///
/// calculateMusharakahSplitHWM(grossProfit, elapsedSeconds, principal, hwmDeficit)
///   → (hurdleAmount, vaultShare, depositorShare)
///
/// Formula:
///   hurdleAmount  = principal * hurdleRateBps * elapsed / (10_000 * 365 days)
///   afterRecovery = grossProfit > hwmDeficit ? grossProfit - hwmDeficit : 0
///   surplus       = afterRecovery > hurdleAmount ? afterRecovery - hurdleAmount : 0
///   vaultShare    = surplus * musharakahShareBps / 10_000
///   depositorShare = grossProfit - vaultShare
///   (sum: hurdleAmount + vaultShare + depositorShare == grossProfit + hurdleAmount — not additive)
///   INVARIANT: vaultShare + depositorShare == grossProfit  (hurdleAmount is informational)

import {TaskITestBase} from "./TaskITest.Base.t.sol";
import {TreasuryModule} from "../TreasuryModule.sol";

contract TaskITest_I3 is TaskITestBase {

    // musharakahShareBps = 1000 (10%), hurdleRateBps = 400 (4%)

    // ─────────────────────────────────────────────────────────────────────────
    // Test 16 — deficit=100e6, gross=150e6, elapsed=0, principal=0
    //   hurdleAmount  = 0 (elapsed=0 → 0)
    //   afterRecovery = 150e6 - 100e6 = 50e6
    //   surplus       = 50e6 - 0 = 50e6
    //   vaultShare    = 50e6 * 1000 / 10_000 = 5e6
    //   depositorShare = 150e6 - 5e6 = 145e6
    // ─────────────────────────────────────────────────────────────────────────
    function test_I3_split_on_excess_only_when_deficit_partial() public view {
        uint256 gross    = 150e6;
        uint256 deficit  = 100e6;
        uint256 elapsed  = 0;
        uint256 principal= 0;

        (uint256 hurdle, uint256 vaultShare, uint256 depositorShare) =
            treasury.calculateMusharakahSplitHWM(gross, elapsed, principal, deficit);

        assertEq(hurdle, 0, "hurdle should be 0 with elapsed=0");
        assertEq(vaultShare, 5e6, "vaultShare = 5e6 (10% of 50e6 excess)");
        assertEq(depositorShare, 145e6, "depositorShare = gross - vaultShare");
        // Invariant: vaultShare + depositorShare == gross
        assertEq(vaultShare + depositorShare, gross, "sum invariant");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 17 — deficit=100e6, gross=150e6 → after recovery, vaultShare > 0
    //   afterRecovery = 50e6 > 0, surplus = 50e6, vaultShare = 5e6 > 0
    //   Confirms HWM deficit is fully absorbed before the manager earns.
    // ─────────────────────────────────────────────────────────────────────────
    function test_I3_deficit_fully_cleared_after_recovery() public view {
        uint256 gross   = 150e6;
        uint256 deficit = 100e6;

        (, uint256 vaultShare, uint256 depositorShare) =
            treasury.calculateMusharakahSplitHWM(gross, 0, 0, deficit);

        // afterRecovery = 50e6 > 0 → manager earns something
        assertGt(vaultShare, 0, "vaultShare > 0: recovery absorbed, manager earns on excess");
        assertEq(vaultShare + depositorShare, gross, "sum invariant");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 18 — deficit=200e6 > gross=100e6 → afterRecovery=0, vaultShare=0
    //   depositorShare = gross = 100e6 (manager earns nothing)
    // ─────────────────────────────────────────────────────────────────────────
    function test_I3_vaultShare_zero_when_gross_below_deficit() public view {
        uint256 gross   = 100e6;
        uint256 deficit = 200e6;

        (, uint256 vaultShare, uint256 depositorShare) =
            treasury.calculateMusharakahSplitHWM(gross, 0, 0, deficit);

        assertEq(vaultShare, 0, "vaultShare = 0 when gross < deficit");
        assertEq(depositorShare, gross, "depositorShare = gross when vaultShare = 0");
        assertEq(vaultShare + depositorShare, gross, "sum invariant");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 19 — hurdle on excess, not full gross
    //   deficit=100e6, gross=300e6, principal=1_000_000e6, elapsed=365 days
    //   hurdleAmount = 1_000_000e6 * 400 * 365days / (10_000 * 365days) = 40_000e6
    //   afterRecovery = 300e6 - 100e6 = 200e6
    //   surplus = 200e6 > 40_000e6 ? NO → surplus = 0
    //   vaultShare = 0
    //   depositorShare = 300e6
    // ─────────────────────────────────────────────────────────────────────────
    function test_I3_hurdle_on_excess_not_full_gross() public view {
        uint256 gross     = 300e6;
        uint256 deficit   = 100e6;
        uint256 principal = 1_000_000e6;
        uint256 elapsed   = 365 days;

        (uint256 hurdle, uint256 vaultShare, uint256 depositorShare) =
            treasury.calculateMusharakahSplitHWM(gross, elapsed, principal, deficit);

        // hurdle = principal * 400 * elapsed / (10000 * 365 days)
        //        = 1_000_000e6 * 400 / 10000 = 40_000e6
        assertEq(hurdle, 40_000e6, "hurdleAmount = 40_000e6");
        // afterRecovery = 200e6 < hurdle (40_000e6) → surplus = 0
        assertEq(vaultShare, 0, "vaultShare = 0 when afterRecovery < hurdle");
        assertEq(depositorShare, gross, "depositorShare = gross");
        assertEq(vaultShare + depositorShare, gross, "sum invariant");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 20 — fuzz: vaultShare + depositorShare == gross always
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzz_I3_invariant(
        uint96 gross,
        uint96 deficit,
        uint96 principal,
        uint32 elapsed
    ) public view {
        // Bound to avoid absurd values while covering interesting edge cases
        uint256 g = bound(uint256(gross),     0,       100_000_000e6);
        uint256 d = bound(uint256(deficit),   0,       200_000_000e6);
        uint256 p = bound(uint256(principal), 0,       1_000_000_000e6);
        uint256 e = bound(uint256(elapsed),   0,       730 days);

        if (g == 0) return; // calculateMusharakahSplitHWM is view so no revert for 0, but skip trivial

        (, uint256 vaultShare, uint256 depositorShare) =
            treasury.calculateMusharakahSplitHWM(g, e, p, d);

        // Core invariant: the split must cover exactly the gross profit
        assertEq(
            vaultShare + depositorShare,
            g,
            "vaultShare + depositorShare must equal grossProfit"
        );

        // vaultShare must not exceed gross
        assertLe(vaultShare, g, "vaultShare cannot exceed gross");
    }
}
