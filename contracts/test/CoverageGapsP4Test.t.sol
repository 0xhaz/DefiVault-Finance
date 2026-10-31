// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ShariahVault} from "../ShariahVault.sol";
import {TreasuryModule} from "../TreasuryModule.sol";
import {ShariahScoreAggregator} from "../ShariahScoreAggregator.sol";
import {RiskTieredExecutor} from "../RiskTieredExecutor.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {GoldCapMockAdapter} from "./RiskTieredExecutorGoldCapTest.t.sol";

/// @dev P-4 coverage gaps: ShariahScoreAggregator (history ring buffer, views, oracle role, bounds) had 46% branch
///      coverage; RiskTieredExecutor's tier-mask rejection and mask setter were never exercised.
contract ShariahScoreAggregatorP4Test is Test {
    ShariahScoreAggregator.ShariahStrategy internal constant ETH = ShariahScoreAggregator.ShariahStrategy.ETH_SPREAD;
    ShariahScoreAggregator.ShariahStrategy internal constant GOLD = ShariahScoreAggregator.ShariahStrategy.GOLD_SPREAD;
    ShariahScoreAggregator.ShariahStrategy internal constant LP = ShariahScoreAggregator.ShariahStrategy.HALAL_LP;
    ShariahScoreAggregator.ShariahStrategy internal constant RESERVED = ShariahScoreAggregator.ShariahStrategy.RWA_SUKUK;
    ShariahScoreAggregator.ShariahStrategy internal constant ALLOC = ShariahScoreAggregator.ShariahStrategy.GOLD_ALLOCATION;

    address internal owner = makeAddr("owner");
    address internal oracleA = makeAddr("oracleA");
    address internal oracleB = makeAddr("oracleB");
    ShariahScoreAggregator internal agg;

    function setUp() public {
        vm.warp(1_700_000_000);
        agg = new ShariahScoreAggregator(owner);
    }

    function _write(ShariahScoreAggregator.ShariahStrategy s, uint8 v) internal {
        vm.prank(owner);
        agg.writeScore(s, v, keccak256(abi.encode(v)), 0);
    }

    function test_P4_history_underTen_keepsInsertionOrder_restZero() public {
        for (uint8 i = 1; i <= 3; ++i) {
            _write(LP, i);
            skip(1);
        }
        ShariahScoreAggregator.Score[10] memory h = agg.getScoreHistory(LP);
        for (uint8 i; i < 3; ++i) assertEq(h[i].value, i + 1);
        for (uint256 i = 3; i < 10; ++i) assertEq(h[i].value, 0);
        assertEq(agg.getScoreHistory(GOLD)[0].value, 0, "untouched strategy has empty history");
    }

    function test_P4_history_ringBufferWraps_oldestFirst() public {
        for (uint8 i = 1; i <= 13; ++i) {
            _write(LP, i);
            skip(1);
        }
        ShariahScoreAggregator.Score[10] memory h = agg.getScoreHistory(LP);
        for (uint256 i; i < 10; ++i) {
            assertEq(h[i].value, i + 4, "last ten scores, oldest first");
            if (i > 0) assertGt(h[i].timestamp, h[i - 1].timestamp, "timestamps ascend");
        }
        assertEq(agg.historyIndex(LP), 3, "next overwrite slot");
    }

    function test_P4_getAllShariahScores_reflectsScoresAndEnabledFlags() public {
        vm.prank(owner);
        agg.setEnabled(ALLOC, true);
        vm.prank(owner);
        agg.writeScore(ALLOC, 77, bytes32("x"), 0);
        vm.prank(owner);
        agg.writeScore(ETH, 12, bytes32("y"), 7);
        (uint8[6] memory v, uint40[6] memory t, uint32[6] memory d, bool[6] memory enabled) = agg.getAllShariahScores();
        assertEq(v[5], 77);
        assertEq(v[0], 12);
        assertEq(d[0], 7);
        assertEq(t[5], block.timestamp);
        assertTrue(enabled[5]);
        assertFalse(enabled[0]);
        assertEq(v[4], 0, "reserved index never written");
    }

    function test_P4_setOracle_onlyOwner_rotatesWriter() public {
        vm.prank(oracleA);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, oracleA));
        agg.setOracle(oracleA);

        vm.prank(owner);
        vm.expectEmit(true, true, false, false, address(agg));
        emit ShariahScoreAggregator.OracleUpdated(address(0), oracleA);
        agg.setOracle(oracleA);
        vm.prank(oracleA);
        agg.writeScore(LP, 50, bytes32(0), 0);
        assertEq(agg.getAllShariahScores_value(LP), 50);

        vm.prank(owner);
        agg.setOracle(oracleB);
        vm.prank(oracleA);
        vm.expectRevert(ShariahScoreAggregator.NotOracle.selector);
        agg.writeScore(LP, 51, bytes32(0), 0);
        vm.prank(oracleB);
        agg.writeScore(LP, 52, bytes32(0), 0);
    }

    function test_P4_writeBounds() public {
        vm.prank(owner);
        vm.expectRevert(ShariahScoreAggregator.InvalidScore.selector);
        agg.writeScore(LP, 101, bytes32(0), 0);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ShariahScoreAggregator.StrategyDeprecated.selector, uint8(4)));
        agg.writeScore(RESERVED, 50, bytes32(0), 0);

        ShariahScoreAggregator.ShariahStrategy[] memory s = new ShariahScoreAggregator.ShariahStrategy[](2);
        uint8[] memory v = new uint8[](1);
        bytes32[] memory h = new bytes32[](2);
        uint32[] memory d = new uint32[](2);
        vm.prank(owner);
        vm.expectRevert(ShariahScoreAggregator.InvalidScore.selector);
        agg.writeBatchScores(s, v, h, d);

        vm.prank(oracleA);
        vm.expectRevert(ShariahScoreAggregator.NotOracle.selector);
        agg.writeScore(LP, 1, bytes32(0), 0);
    }

    function test_P4_winner_staleTieAndDisabled() public {
        vm.startPrank(owner);
        agg.setEnabled(GOLD, true);
        agg.setEnabled(LP, true);
        agg.writeScore(GOLD, 80, bytes32(0), 0);
        agg.writeScore(LP, 80, bytes32(0), 0);
        agg.writeScore(ALLOC, 99, bytes32(0), 0); // highest, but not enabled
        vm.stopPrank();
        (ShariahScoreAggregator.ShariahStrategy w, uint8 sc,) = agg.getWinningShariahStrategy();
        assertEq(uint8(w), uint8(GOLD), "tie: lower index wins; disabled strategy skipped");
        assertEq(sc, 80);

        skip(5 minutes + 1);
        vm.expectRevert(ShariahScoreAggregator.NoValidScores.selector);
        agg.getWinningShariahStrategy();
    }
}

/// @dev View helper so the oracle test can read a single score without unpacking four arrays.
library AggView {
    function getAllShariahScores_value(ShariahScoreAggregator a, ShariahScoreAggregator.ShariahStrategy s)
        internal
        view
        returns (uint8)
    {
        (uint8[6] memory v,,,) = a.getAllShariahScores();
        return v[uint8(s)];
    }
}

using AggView for ShariahScoreAggregator;

contract RiskTieredExecutorTierMaskP4Test is Test {
    ShariahScoreAggregator.ShariahStrategy internal constant ETH = ShariahScoreAggregator.ShariahStrategy.ETH_SPREAD;
    ShariahScoreAggregator.ShariahStrategy internal constant ALLOC = ShariahScoreAggregator.ShariahStrategy.GOLD_ALLOCATION;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    MockERC20 internal usdc;
    ShariahVault internal vault;
    ShariahScoreAggregator internal agg;
    RiskTieredExecutor internal conservative;
    GoldCapMockAdapter internal alloc;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);
        vm.startPrank(owner);
        address predictedVault = vm.computeCreateAddress(owner, vm.getNonce(owner) + 1);
        TreasuryModule treasury = new TreasuryModule("Shariah", predictedVault, address(usdc), 50, 1000, 400, owner);
        vault = new ShariahVault(IERC20(address(usdc)), owner, 26, address(treasury), address(0));
        require(address(vault) == predictedVault, "vault addr mismatch");
        agg = new ShariahScoreAggregator(owner);
        agg.setEnabled(ETH, true);
        agg.setEnabled(ALLOC, true);
        conservative = new RiskTieredExecutor(address(vault), address(0), RiskTieredExecutor.RiskTier.SHARIAH_CONSERVATIVE, owner);
        conservative.setShariahAggregator(address(agg));
        vault.setManager(address(conservative));
        alloc = new GoldCapMockAdapter(address(vault), true);
        vault.setScreened(address(alloc), true);
        vault.setGoldAllocationAdapter(address(alloc));
        conservative.setShariahStrategyConfig(5, address(alloc), bytes32(0), true, 1e6, type(uint256).max);
        vm.stopPrank();
        usdc.mint(alice, 100_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(100_000e6, alice);
        vm.stopPrank();
    }

    /// KNOWN LIMITATION N-36 (Low, open): the aggregator returns one global winner. If that winner is outside the
    /// tier's mask (ETH_SPREAD is not in Conservative's mask 38), executeWinner reverts instead of falling back to
    /// the best allowed strategy, so a shared aggregator can stall a tier's allocation.
    function test_knownLimitation_N36_disallowedGlobalWinnerBlocksTier() public {
        assertEq(conservative.strategyMask(), 38);
        vm.startPrank(owner);
        agg.writeScore(ETH, 95, bytes32(0), 0);
        agg.writeScore(ALLOC, 90, bytes32(0), 0);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(RiskTieredExecutor.StrategyNotAllowedForTier.selector, uint8(0), uint8(38)));
        conservative.executeWinner();

        // Once the disallowed strategy is not the winner, the allowed one executes.
        vm.prank(owner);
        agg.setEnabled(ETH, false);
        conservative.executeWinner();
        assertGt(alloc.currentValue(), 0, "gold allocation funded");
    }

    function test_P4_setStrategyMask_onlyOwner_gatesWinner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        conservative.setStrategyMask(0);

        vm.prank(owner);
        conservative.setStrategyMask(38 & ~uint8(1 << 5)); // drop GOLD_ALLOCATION
        vm.prank(owner);
        agg.setEnabled(ETH, false);
        vm.prank(owner);
        agg.writeScore(ALLOC, 90, bytes32(0), 0);
        vm.expectRevert(abi.encodeWithSelector(RiskTieredExecutor.StrategyNotAllowedForTier.selector, uint8(5), uint8(6)));
        conservative.executeWinner();
    }
}
