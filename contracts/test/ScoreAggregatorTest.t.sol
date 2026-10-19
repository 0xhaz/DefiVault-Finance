// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ScoreAggregator} from "../ScoreAggregator.sol";

contract ScoreAggregatorTest is Test {
    ScoreAggregator internal agg;

    address internal owner = makeAddr("owner");
    address internal oracle = makeAddr("oracle");
    address internal random = makeAddr("random");

    bytes32 internal constant HASH_A = keccak256("dataA");

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
    // test_writeScore_basic
    // -----------------------------------------------------------------------
    function test_writeScore_basic() public {
        vm.prank(oracle);
        agg.writeScore(S0, 85, HASH_A, 0);

        (uint8 val, uint40 ts, bytes32 dh, uint32 dd) = agg.scores(S0);
        assertEq(val, 85, "value should be 85");
        assertEq(ts, uint40(block.timestamp));
        assertEq(dh, HASH_A);
        assertEq(dd, 0);
    }

    // -----------------------------------------------------------------------
    // test_writeScore_invalid_over_100
    // -----------------------------------------------------------------------
    function test_writeScore_invalid_over_100() public {
        vm.prank(oracle);
        vm.expectRevert(ScoreAggregator.InvalidScore.selector);
        agg.writeScore(S0, 101, HASH_A, 0);
    }

    // -----------------------------------------------------------------------
    // test_getWinningStrategy_picks_highest
    // -----------------------------------------------------------------------
    function test_getWinningStrategy_picks_highest() public {
        vm.startPrank(oracle);
        agg.writeScore(S0, 70, HASH_A, 0);
        agg.writeScore(S1, 90, HASH_A, 0);
        agg.writeScore(S2, 60, HASH_A, 0);
        agg.writeScore(S3, 80, HASH_A, 0);
        vm.stopPrank();

        (ScoreAggregator.Strategy winner, uint8 score,) = agg.getWinningStrategy();
        assertEq(uint8(winner), uint8(S1), "FUNDING_RATE_ARB should win with 90");
        assertEq(score, 90);
    }

    // -----------------------------------------------------------------------
    // test_getWinningStrategy_stale_reverts
    // -----------------------------------------------------------------------
    function test_getWinningStrategy_stale_reverts() public {
        vm.prank(oracle);
        agg.writeScore(S0, 85, HASH_A, 0);

        // warp 6 minutes forward → score is stale (> 5 minutes old)
        skip(6 minutes);

        vm.expectRevert(abi.encodeWithSelector(ScoreAggregator.StaleScore.selector, S0));
        agg.getWinningStrategy();
    }

    // -----------------------------------------------------------------------
    // test_getWinningStrategy_no_scores
    // -----------------------------------------------------------------------
    function test_getWinningStrategy_no_scores() public {
        vm.expectRevert(ScoreAggregator.NoValidScores.selector);
        agg.getWinningStrategy();
    }

    // -----------------------------------------------------------------------
    // test_writeBatchScores
    // -----------------------------------------------------------------------
    function test_writeBatchScores() public {
        ScoreAggregator.Strategy[] memory strats = new ScoreAggregator.Strategy[](4);
        strats[0] = S0; strats[1] = S1; strats[2] = S2; strats[3] = S3;

        uint8[] memory vals = new uint8[](4);
        vals[0] = 80; vals[1] = 75; vals[2] = 65; vals[3] = 90;

        bytes32[] memory hashes = new bytes32[](4);
        hashes[0] = HASH_A; hashes[1] = HASH_A; hashes[2] = HASH_A; hashes[3] = HASH_A;

        uint32[] memory domains = new uint32[](4);
        domains[0] = 1; domains[1] = 2; domains[2] = 3; domains[3] = 4;

        vm.prank(oracle);
        agg.writeBatchScores(strats, vals, hashes, domains);

        (uint8 v0,,,) = agg.scores(S0);
        (uint8 v1,,,) = agg.scores(S1);
        (uint8 v2,,,) = agg.scores(S2);
        (uint8 v3,,,) = agg.scores(S3);
        assertEq(v0, 80);
        assertEq(v1, 75);
        assertEq(v2, 65);
        assertEq(v3, 90);
    }

    // -----------------------------------------------------------------------
    // test_writeBatchScores_length_mismatch
    // -----------------------------------------------------------------------
    function test_writeBatchScores_length_mismatch() public {
        ScoreAggregator.Strategy[] memory strats = new ScoreAggregator.Strategy[](2);
        strats[0] = S0; strats[1] = S1;

        uint8[] memory vals = new uint8[](1); // mismatch
        vals[0] = 80;

        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = HASH_A; hashes[1] = HASH_A;

        uint32[] memory domains = new uint32[](2);
        domains[0] = 0; domains[1] = 0;

        vm.prank(oracle);
        vm.expectRevert(ScoreAggregator.InvalidScore.selector);
        agg.writeBatchScores(strats, vals, hashes, domains);
    }

    // -----------------------------------------------------------------------
    // test_scoreHistory_ring_buffer — write 12 scores, verify only 10 stored
    // -----------------------------------------------------------------------
    function test_scoreHistory_ring_buffer() public {
        // Write 12 scores for STABLECOIN_SPREAD
        vm.startPrank(oracle);
        for (uint8 i = 1; i <= 12; i++) {
            agg.writeScore(S0, i, keccak256(abi.encode(i)), 0);
        }
        vm.stopPrank();

        ScoreAggregator.Score[10] memory history = agg.getScoreHistory(S0);

        // All 10 slots must be filled (no zero-value entries from overflow)
        uint256 nonZero;
        for (uint256 i = 0; i < 10; i++) {
            if (history[i].value != 0) nonZero++;
        }
        assertEq(nonZero, 10, "ring buffer should hold exactly 10 entries");

        // The last written value (12) must appear somewhere in history
        bool foundLast;
        for (uint256 i = 0; i < 10; i++) {
            if (history[i].value == 12) foundLast = true;
        }
        assertTrue(foundLast, "last written value (12) must be in history");

        // Value 2 (written 11th from last) must NOT appear — it was overwritten
        bool foundOldest;
        for (uint256 i = 0; i < 10; i++) {
            if (history[i].value == 2) foundOldest = true;
        }
        assertFalse(foundOldest, "value 2 should have been overwritten in ring buffer");
    }

    // -----------------------------------------------------------------------
    // test_onlyOracle_or_owner — random address reverts NotOracle
    // -----------------------------------------------------------------------
    function test_onlyOracle_or_owner() public {
        vm.prank(random);
        vm.expectRevert(ScoreAggregator.NotOracle.selector);
        agg.writeScore(S0, 85, HASH_A, 0);
    }

    // -----------------------------------------------------------------------
    // test_setOracle
    // -----------------------------------------------------------------------
    function test_setOracle() public {
        address newOracle = makeAddr("newOracle");

        // Owner sets new oracle
        vm.prank(owner);
        agg.setOracle(newOracle);

        // New oracle can write
        vm.prank(newOracle);
        agg.writeScore(S0, 77, HASH_A, 0);
        (uint8 val,,,) = agg.scores(S0);
        assertEq(val, 77);

        // Old oracle can no longer write
        vm.prank(oracle);
        vm.expectRevert(ScoreAggregator.NotOracle.selector);
        agg.writeScore(S0, 50, HASH_A, 0);
    }

    // -----------------------------------------------------------------------
    // test_destinationDomain_stored
    // -----------------------------------------------------------------------
    function test_destinationDomain_stored() public {
        vm.prank(oracle);
        agg.writeScore(S1, 88, HASH_A, 9);

        (,, uint32[4] memory domains) = agg.getAllScores();
        assertEq(domains[uint8(S1)], 9, "destinationDomain should be 9");
    }

    // -----------------------------------------------------------------------
    // test_owner_can_write_score
    // -----------------------------------------------------------------------
    function test_owner_can_write_score() public {
        vm.prank(owner);
        agg.writeScore(S2, 60, HASH_A, 3);
        (uint8 val,,,) = agg.scores(S2);
        assertEq(val, 60);
    }

    // -----------------------------------------------------------------------
    // test_score_100_valid (boundary)
    // -----------------------------------------------------------------------
    function test_score_100_valid() public {
        vm.prank(oracle);
        agg.writeScore(S0, 100, HASH_A, 0);
        (uint8 val,,,) = agg.scores(S0);
        assertEq(val, 100);
    }
}
