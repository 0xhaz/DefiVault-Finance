// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ScoreAggregator} from "../ScoreAggregator.sol";

contract FuzzScoreAggregator is Test {
    ScoreAggregator internal agg;

    address internal owner = makeAddr("owner");
    address internal oracle = makeAddr("oracle");

    ScoreAggregator.Strategy internal constant S0 = ScoreAggregator.Strategy.STABLECOIN_SPREAD;
    ScoreAggregator.Strategy internal constant S1 = ScoreAggregator.Strategy.FUNDING_RATE_ARB;
    ScoreAggregator.Strategy internal constant S2 = ScoreAggregator.Strategy.BRIDGE_FLOW;
    ScoreAggregator.Strategy internal constant S3 = ScoreAggregator.Strategy.LIQUIDATION_RWA;

    function setUp() public {
        vm.prank(owner);
        agg = new ScoreAggregator(owner);
        vm.prank(owner);
        agg.setOracle(oracle);
    }

    // -----------------------------------------------------------------------
    // Fuzz: any score 0–100 must store and retrieve correctly; >100 must revert
    // -----------------------------------------------------------------------
    function testFuzz_writeScore_value_range(uint8 score) public {
        if (score > 100) {
            vm.prank(oracle);
            vm.expectRevert(ScoreAggregator.InvalidScore.selector);
            agg.writeScore(S0, score, bytes32(0), 0);
        } else {
            vm.prank(oracle);
            agg.writeScore(S0, score, bytes32(0), 0);
            (uint8 stored,,,) = agg.scores(S0);
            assertEq(stored, score);
        }
    }

    // -----------------------------------------------------------------------
    // Fuzz: any score written → getWinningStrategy returns it if it's the only valid one
    // -----------------------------------------------------------------------
    function testFuzz_singleScore_always_wins(uint8 score, uint8 stratIdx) public {
        score = uint8(bound(score, 1, 100));
        stratIdx = uint8(bound(stratIdx, 0, 3));
        ScoreAggregator.Strategy strat = ScoreAggregator.Strategy(stratIdx);

        vm.prank(oracle);
        agg.writeScore(strat, score, bytes32(0), 0);

        (ScoreAggregator.Strategy winner, uint8 winScore,) = agg.getWinningStrategy();
        assertEq(uint8(winner), stratIdx);
        assertEq(winScore, score);
    }

    // -----------------------------------------------------------------------
    // Fuzz: getWinningStrategy always returns the highest score among 4 strategies
    // -----------------------------------------------------------------------
    function testFuzz_winning_strategy_is_highest(
        uint8 s0, uint8 s1, uint8 s2, uint8 s3
    ) public {
        s0 = uint8(bound(s0, 1, 100));
        s1 = uint8(bound(s1, 1, 100));
        s2 = uint8(bound(s2, 1, 100));
        s3 = uint8(bound(s3, 1, 100));

        vm.startPrank(oracle);
        agg.writeScore(S0, s0, bytes32(0), 0);
        agg.writeScore(S1, s1, bytes32(0), 0);
        agg.writeScore(S2, s2, bytes32(0), 0);
        agg.writeScore(S3, s3, bytes32(0), 0);
        vm.stopPrank();

        (, uint8 winScore,) = agg.getWinningStrategy();

        uint8 expectedMax = s0;
        if (s1 > expectedMax) expectedMax = s1;
        if (s2 > expectedMax) expectedMax = s2;
        if (s3 > expectedMax) expectedMax = s3;

        assertEq(winScore, expectedMax, "winner must have the highest score");
    }

    // -----------------------------------------------------------------------
    // Fuzz: staleness — any score written more than 5 min ago is stale
    // -----------------------------------------------------------------------
    function testFuzz_staleness(uint32 elapsed) public {
        vm.prank(oracle);
        agg.writeScore(S0, 80, bytes32(0), 0);

        if (elapsed > 5 minutes) {
            skip(elapsed);
            vm.expectRevert(); // StaleScore
            agg.getWinningStrategy();
        } else {
            skip(elapsed);
            // Should still succeed (not stale)
            (,uint8 winScore,) = agg.getWinningStrategy();
            assertEq(winScore, 80);
        }
    }

    // -----------------------------------------------------------------------
    // Fuzz: destinationDomain stored and retrieved accurately
    // -----------------------------------------------------------------------
    function testFuzz_destinationDomain_roundtrip(uint32 domain, uint8 stratIdx) public {
        stratIdx = uint8(bound(stratIdx, 0, 3));
        ScoreAggregator.Strategy strat = ScoreAggregator.Strategy(stratIdx);

        vm.prank(oracle);
        agg.writeScore(strat, 50, bytes32(0), domain);

        (,, uint32[4] memory domains) = agg.getAllScores();
        assertEq(domains[stratIdx], domain);
    }

    // -----------------------------------------------------------------------
    // Fuzz: ring-buffer never corrupts — write N scores, all 10 history slots valid
    // -----------------------------------------------------------------------
    function testFuzz_ringBuffer_no_corruption(uint8 n) public {
        n = uint8(bound(n, 1, 50));

        vm.startPrank(oracle);
        for (uint8 i = 0; i < n; i++) {
            uint8 score = uint8((i % 100) + 1);
            agg.writeScore(S0, score, keccak256(abi.encode(i)), 0);
        }
        vm.stopPrank();

        ScoreAggregator.Score[10] memory history = agg.getScoreHistory(S0);
        uint256 expectedSlots = n < 10 ? n : 10;
        uint256 nonZero;
        for (uint256 i = 0; i < 10; i++) {
            if (history[i].value > 0) nonZero++;
        }
        assertEq(nonZero, expectedSlots, "ring buffer slot count must match min(n, 10)");
    }

    // -----------------------------------------------------------------------
    // Fuzz: only oracle or owner can write; any other address must revert
    // -----------------------------------------------------------------------
    function testFuzz_access_control(address caller) public {
        vm.assume(caller != oracle && caller != owner);

        vm.prank(caller);
        vm.expectRevert(ScoreAggregator.NotOracle.selector);
        agg.writeScore(S0, 50, bytes32(0), 0);
    }

    // -----------------------------------------------------------------------
    // Fuzz: batch write — any equal-length arrays succeed; mismatched reverts
    // -----------------------------------------------------------------------
    function testFuzz_batchWrite_length_invariant(uint8 len1, uint8 len2) public {
        len1 = uint8(bound(len1, 1, 4));
        len2 = uint8(bound(len2, 0, 4));

        ScoreAggregator.Strategy[] memory strats = new ScoreAggregator.Strategy[](len1);
        uint8[] memory vals = new uint8[](len1);
        bytes32[] memory hashes = new bytes32[](len1);
        uint32[] memory domains = new uint32[](len2); // potentially different length

        for (uint8 i = 0; i < len1; i++) {
            strats[i] = ScoreAggregator.Strategy(i % 4);
            vals[i] = 50;
            hashes[i] = bytes32(0);
        }

        if (len1 != len2) {
            vm.prank(oracle);
            vm.expectRevert(ScoreAggregator.InvalidScore.selector);
            agg.writeBatchScores(strats, vals, hashes, domains);
        } else {
            // Equal lengths — should succeed (all scores are valid ≤100)
            vm.prank(oracle);
            agg.writeBatchScores(strats, vals, hashes, domains);
        }
    }

    // -----------------------------------------------------------------------
    // Fuzz: score of exactly 0 is stored but treated as "no score" by winner
    // -----------------------------------------------------------------------
    function testFuzz_zero_score_not_counted_as_winner(uint8 nonzeroScore) public {
        nonzeroScore = uint8(bound(nonzeroScore, 1, 100));

        vm.startPrank(oracle);
        agg.writeScore(S0, 0, bytes32(0), 0);  // zero — should be skipped
        agg.writeScore(S1, nonzeroScore, bytes32(0), 0);
        vm.stopPrank();

        (ScoreAggregator.Strategy winner, uint8 score,) = agg.getWinningStrategy();
        assertEq(uint8(winner), uint8(S1), "S0 with score=0 must not win");
        assertEq(score, nonzeroScore);
    }
}
