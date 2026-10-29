// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title  TaskI — Item I2: GoldExchangeAdapter PR1 parity (stale-price valuation)
/// @notice Tests 6-15 from the Task-I specification.

import {TaskITestBase} from "./TaskITest.Base.t.sol";
import {GoldExchangeAdapter} from "../adapters/GoldExchangeAdapter.sol";

contract TaskITest_I2 is TaskITestBase {

    // ─────────────────────────────────────────────────────────────────────────
    // Test 6 — currentValue() uses the live oracle when fresh
    // ─────────────────────────────────────────────────────────────────────────
    // Corrected units make even the raw 1:1 router value its position at the full USDC input.
    function test_I2_currentValue_uses_oracle_when_fresh() public {
        // Use a large deploy to get a non-trivial paxgHeld
        // Fund the svault with more USDC first
        usdc.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdc.approve(address(svault), 1_000_000e6);
        svault.deposit(1_000_000e6, alice);
        vm.stopPrank();

        uint256 deployAmt = 50_000e6;
        _deployAndSwapGold(deployAmt);

        uint256 paxgHeld_     = goldAdapter.paxgHeld();
        // Fresh valuation reads the oracle directly rather than the execution-price cache.
        uint256 expectedGross = (paxgHeld_ * 3_300e6) / 1e18;

        // Must be fresh (just deployed, no warp)
        uint256 cv = goldAdapter.currentValue();
        assertEq(cv, expectedGross, "currentValue != paxgHeld * lastGoodPrice / 1e18 when fresh");
        assertApproxEqAbs(cv, deployAmt, 1, "entry value must not lose a decimal scaling factor");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 7 — currentValue() uses haircut when stale
    // ─────────────────────────────────────────────────────────────────────────
    function test_I2_currentValue_uses_haircut_when_stale() public {
        uint256 deployAmt = 50_000e6;
        usdc.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdc.approve(address(svault), 1_000_000e6);
        svault.deposit(1_000_000e6, alice);
        vm.stopPrank();
        _deployAndSwapGold(deployAmt);

        uint256 paxgHeld_     = goldAdapter.paxgHeld();
        uint256 lastGoodPrice_= goldAdapter.lastGoodPrice();
        uint256 grossValue    = (paxgHeld_ * lastGoodPrice_) / 1e18;

        // Advance past maxStalenessSecs (default 1 day)
        uint256 maxStaleness = goldAdapter.maxStalenessSecs();
        vm.warp(block.timestamp + maxStaleness + 1);

        uint256 haircutBps  = goldAdapter.staleHaircutBps(); // default 500
        uint256 expectedValue = (grossValue * (10_000 - haircutBps)) / 10_000;

        assertEq(goldAdapter.currentValue(), expectedValue, "stale currentValue should apply haircut");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 8 — currentValue() == 0 before any deploy
    // ─────────────────────────────────────────────────────────────────────────
    function test_I2_currentValue_zero_before_deploy() public view {
        assertEq(goldAdapter.currentValue(), 0, "currentValue must be 0 before any swap");
        assertEq(goldAdapter.paxgHeld(), 0, "paxgHeld must be 0 before swap");
        assertEq(goldAdapter.lastGoodPrice(), 0, "lastGoodPrice must be 0 before swap");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 9 — isPriceSane() == true immediately after deploy
    // ─────────────────────────────────────────────────────────────────────────
    function test_I2_isPriceSane_true_when_fresh() public {
        _deployAndSwapGold(1_000e6);
        assertTrue(goldAdapter.isPriceSane(), "isPriceSane should be true right after swap");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 10 — isPriceSane() == false when stale
    // ─────────────────────────────────────────────────────────────────────────
    function test_I2_isPriceSane_false_when_stale() public {
        _deployAndSwapGold(1_000e6);

        uint256 maxStaleness = goldAdapter.maxStalenessSecs();
        vm.warp(block.timestamp + maxStaleness + 1);

        assertFalse(goldAdapter.isPriceSane(), "isPriceSane should be false after staleness window");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 11 — isPriceSane() == true when no position open (no swap ever)
    // ─────────────────────────────────────────────────────────────────────────
    function test_I2_isPriceSane_true_when_no_position() public view {
        // Fresh adapter: lastGoodPriceAt == 0 → isPriceSane returns true
        assertEq(goldAdapter.lastGoodPriceAt(), 0, "no swap yet");
        assertTrue(goldAdapter.isPriceSane(), "should be sane with no position");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 12 — maxDeposit(alice) == 0 when S2-H (goldSpreadAdapter) is stale
    // ─────────────────────────────────────────────────────────────────────────
    // Retain controllable value/sanity coverage independently of the corrected swap price units.
    function test_I2_maxDeposit_zero_when_S2H_stale() public {
        // Wire goldAllocAdapter as S2-H mock (goldSpreadAdapter) with a non-zero position
        goldAllocAdapter.setValue(10_000e6); // 10 000 USDC equivalent — above dustThreshold
        // Seed cost before slot registration: a value-only mock no longer represents funded exposure.
        vm.prank(owner);
        svault.setScreened(address(goldAllocAdapter), true);
        uint256 seededValue = goldAllocAdapter.value(); // read before pranking so the prank hits deployCapital
        vm.prank(owner);
        svault.setGoldSpreadAdapter(address(goldAllocAdapter)); // N-23: marked gold must be linked before funding
        vm.prank(manager);
        svault.deployCapitalAndExecute(address(goldAllocAdapter), seededValue, "");
        goldAllocAdapter.setSane(false);     // simulate stale S2-H

        assertFalse(goldAllocAdapter.isPriceSane(), "S2-H should be insane");
        assertEq(svault.maxDeposit(alice), 0, "maxDeposit should be 0 when S2-H stale");
        assertEq(svault.maxMint(alice), 0, "maxMint should be 0 when S2-H stale");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 13 — S6-H sane, S2-H stale → maxDeposit still 0
    // ─────────────────────────────────────────────────────────────────────────
    function test_I2_maxDeposit_normal_when_S6H_sane_and_S2H_stale() public {
        // goldAdapter (GoldExchangeAdapter) is sane by default (no position open → lastGoodPriceAt=0).
        // Use it as S6-H (goldAllocationAdapter) — it will report isPriceSane=true.
        // Use goldAllocAdapter as S2-H (goldSpreadAdapter) — set stale with a real position.
        goldAllocAdapter.setValue(10_000e6); // above dustThreshold
        // Seed cost before slot registration: a value-only mock no longer represents funded exposure.
        vm.prank(owner);
        svault.setScreened(address(goldAllocAdapter), true);
        uint256 seededValue = goldAllocAdapter.value(); // read before pranking so the prank hits deployCapital
        vm.prank(owner);
        svault.setGoldSpreadAdapter(address(goldAllocAdapter)); // N-23: marked gold must be linked before funding
        vm.prank(manager);
        svault.deployCapitalAndExecute(address(goldAllocAdapter), seededValue, "");
        goldAllocAdapter.setSane(false);     // S2-H stale

        vm.startPrank(owner);
        svault.setGoldAllocationAdapter(address(goldAdapter));  // S6-H sane (no position yet)
        vm.stopPrank();

        assertTrue(goldAdapter.isPriceSane(), "S6-H should be sane (no position open)");
        assertFalse(goldAllocAdapter.isPriceSane(), "S2-H should be stale");

        // S2-H is stale → maxDeposit must still be 0 (either adapter stale blocks deposits)
        assertEq(svault.maxDeposit(alice), 0, "stale S2-H blocks even when S6-H sane");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 14 — same as 13: both adapters needed to be sane for deposits
    // ─────────────────────────────────────────────────────────────────────────
    function test_I2_S6H_sane_S2H_stale_blocks_deposits() public {
        // Same wiring as test 13: S6-H = goldAdapter (sane), S2-H = goldAllocAdapter (stale).
        goldAllocAdapter.setValue(8_000e6); // above dustThreshold
        // Seed cost before slot registration: a value-only mock no longer represents funded exposure.
        vm.prank(owner);
        svault.setScreened(address(goldAllocAdapter), true);
        uint256 seededValue = goldAllocAdapter.value(); // read before pranking so the prank hits deployCapital
        vm.prank(owner);
        svault.setGoldSpreadAdapter(address(goldAllocAdapter)); // N-23: marked gold must be linked before funding
        vm.prank(manager);
        svault.deployCapitalAndExecute(address(goldAllocAdapter), seededValue, "");
        goldAllocAdapter.setSane(false);

        vm.startPrank(owner);
        svault.setGoldAllocationAdapter(address(goldAdapter));
        vm.stopPrank();

        assertFalse(goldAllocAdapter.isPriceSane(), "S2-H stale");
        assertTrue(goldAdapter.isPriceSane(), "S6-H still sane (no position open)");
        assertEq(svault.maxDeposit(alice), 0, "deposits blocked because S2-H stale");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 15 — fuzz: stale value <= fresh value
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzz_I2_stale_value_leq_fresh_value(
        uint128 paxgHeld,
        uint32  timeSeed
    ) public {
        // Corrected units make the stale-value comparison nonzero for every bounded input.
        uint256 elapsed = bound(uint256(timeSeed), 0, 10 days);
        // The raw 1:1 router gives paxgHeld == deployAmt and lastGoodPrice == 1e18.
        uint256 deployAmt = bound(uint256(paxgHeld), 1e6, 10_000e6);

        // Need svault to have enough USDC
        usdc.mint(alice, deployAmt);
        vm.startPrank(alice);
        usdc.approve(address(svault), deployAmt);
        svault.deposit(deployAmt, alice);
        vm.stopPrank();

        _deployAndSwapGold(deployAmt);

        // Capture fresh value
        uint256 freshValue = goldAdapter.currentValue();
        assertApproxEqAbs(freshValue, deployAmt, 1, "fresh value must equal funded input");

        // Warp by elapsed
        vm.warp(block.timestamp + elapsed);

        uint256 staleness = goldAdapter.maxStalenessSecs();
        uint256 valueAfterWarp = goldAdapter.currentValue();

        if (elapsed > staleness) {
            // Stale — should have haircut applied
            assertLe(valueAfterWarp, freshValue, "stale value must be <= fresh value");
        } else {
            // Still fresh — same value
            assertEq(valueAfterWarp, freshValue, "value unchanged while fresh");
        }
    }
}
