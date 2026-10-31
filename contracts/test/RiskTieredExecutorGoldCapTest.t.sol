// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AutonomousVault} from "../AutonomousVault.sol";
import {ShariahVault} from "../ShariahVault.sol";
import {TreasuryModule} from "../TreasuryModule.sol";
import {ScoreAggregator} from "../ScoreAggregator.sol";
import {ShariahScoreAggregator} from "../ShariahScoreAggregator.sol";
import {RiskTieredExecutor} from "../RiskTieredExecutor.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";

/// @dev Controllable adapter. `gold` toggles the isGoldStrategy marker; value tracks deployed amount
///      and can be overridden with setValue to simulate pre-existing gold holdings.
contract GoldCapMockAdapter {
    address public vault;
    bool public gold;
    uint256 public value;

    constructor(address vault_, bool gold_) {
        vault = vault_;
        gold = gold_;
    }

    function isGoldStrategy() external view returns (bool) { return gold; }
    function isPriceSane() external pure returns (bool) { return true; }
    function setValue(uint256 v) external { value = v; }
    function currentValue() external view returns (uint256) { return value; }
    function deploy(uint256 amount) external returns (uint256) { value += amount; return amount; }
    function recall(uint256 amount) external pure returns (uint256) { return amount; }
    function protocolName() external pure returns (string memory) { return "GoldCapMock"; }
}

contract RiskTieredExecutorGoldCapTest is Test {
    ShariahScoreAggregator.ShariahStrategy internal constant GOLD_SPREAD = ShariahScoreAggregator.ShariahStrategy.GOLD_SPREAD;
    ShariahScoreAggregator.ShariahStrategy internal constant HALAL_LP = ShariahScoreAggregator.ShariahStrategy.HALAL_LP;
    ShariahScoreAggregator.ShariahStrategy internal constant MURABAHA = ShariahScoreAggregator.ShariahStrategy.MURABAHA;
    ShariahScoreAggregator.ShariahStrategy internal constant GOLD_ALLOC = ShariahScoreAggregator.ShariahStrategy.GOLD_ALLOCATION;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");

    uint256 internal constant DEPOSIT = 100_000e6;
    bytes32 internal constant H = keccak256("gold-cap");

    MockERC20 internal usdc;
    TreasuryModule internal treasury;
    ShariahVault internal vault;
    ShariahScoreAggregator internal agg;
    RiskTieredExecutor internal exec;
    GoldCapMockAdapter internal spread;
    GoldCapMockAdapter internal alloc;
    GoldCapMockAdapter internal lp;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);

        vm.startPrank(owner);
        // Wakala fees accrue to the treasury over time; the vault (next nonce) must be its feeSource.
        address predictedVault = vm.computeCreateAddress(owner, vm.getNonce(owner) + 1);
        treasury = new TreasuryModule("Shariah", predictedVault, address(usdc), 50, 1000, 400, owner);
        vault = new ShariahVault(IERC20(address(usdc)), owner, 26, address(treasury), address(0));
        require(address(vault) == predictedVault, "vault addr mismatch");
        vault.setMaxAllocationBps(8_000);
        agg = new ShariahScoreAggregator(owner);
        agg.setEnabled(GOLD_SPREAD, true);
        agg.setEnabled(GOLD_ALLOC, true);
        agg.setEnabled(HALAL_LP, true);
        agg.setEnabled(MURABAHA, true);
        exec = new RiskTieredExecutor(
            address(vault), address(0), RiskTieredExecutor.RiskTier.SHARIAH_DYNAMIC, owner
        );
        exec.setShariahAggregator(address(agg));
        vault.setManager(address(exec));

        spread = new GoldCapMockAdapter(address(vault), true);
        alloc = new GoldCapMockAdapter(address(vault), true);
        lp = new GoldCapMockAdapter(address(vault), false);
        vault.setScreened(address(spread), true);
        vault.setScreened(address(alloc), true);
        vault.setScreened(address(lp), true);
        vault.setGoldSpreadAdapter(address(spread));
        vault.setGoldAllocationAdapter(address(alloc));

        exec.setShariahStrategyConfig(1, address(spread), bytes32(0), true, 1e6, type(uint256).max);
        exec.setShariahStrategyConfig(5, address(alloc), bytes32(0), true, 1e6, type(uint256).max);
        exec.setShariahStrategyConfig(2, address(lp), bytes32(0), true, 1e6, type(uint256).max);
        exec.setShariahStrategyConfig(3, address(lp), bytes32(0), true, 1e6, type(uint256).max);
        vm.stopPrank();

        usdc.mint(alice, DEPOSIT);
        vm.startPrank(alice);
        usdc.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, alice);
        vm.stopPrank();
    }

    // ── helpers ──────────────────────────────────────────────────────────────
    function _score(ShariahScoreAggregator.ShariahStrategy s) internal {
        vm.prank(owner);
        agg.writeScore(s, 90, H, 0);
    }

    function _cfg(uint8 idx, address adapter, uint256 minAmt, uint256 maxAmt) internal {
        vm.prank(owner);
        exec.setShariahStrategyConfig(idx, adapter, bytes32(0), true, minAmt, maxAmt);
    }

    function _run(ShariahScoreAggregator.ShariahStrategy s) internal {
        _score(s);
        exec.executeWinner();
    }

    function _nextRound() internal {
        skip(1 hours + 1);
    }

    /// @dev Independent recomputation of the remaining combined gold room from the vault's own view.
    function _expectedRoom() internal view returns (uint256) {
        uint256 cap = vault.totalAssets() * 3000 / 10_000;
        address a = vault.goldSpreadAdapter();
        address b = vault.goldAllocationAdapter();
        uint256 v = GoldCapMockAdapter(a).currentValue();
        if (b != a) v += GoldCapMockAdapter(b).currentValue();
        return cap > v ? cap - v : 0;
    }

    // ── gold clamp: happy paths ──────────────────────────────────────────────
    function test_goldSpread_deploysExactRoom_notAllocationCap() public {
        uint256 room = _expectedRoom();
        assertEq(room, 30_000e6, "room is 30% of NAV");
        uint256 beforeIdle = usdc.balanceOf(address(vault));

        _score(GOLD_SPREAD);
        vm.expectEmit(true, true, false, true, address(exec));
        emit RiskTieredExecutor.ShariahExecutionTriggered(
            GOLD_SPREAD, 90, room, address(spread), RiskTieredExecutor.RiskTier.SHARIAH_DYNAMIC
        );
        exec.executeWinner();

        assertEq(spread.value(), room, "spread got exactly the room");
        assertEq(beforeIdle - usdc.balanceOf(address(vault)), room);
        assertLt(room, (DEPOSIT * 8_000) / 10_000, "not the 80% allocation");
        assertEq(vault.totalDeployed(), room);
    }

    function test_goldAllocation_deploysExactRoom() public {
        uint256 room = _expectedRoom();
        _run(GOLD_ALLOC);
        assertEq(alloc.value(), room);
        assertEq(room, 30_000e6);
        assertEq(spread.value(), 0);
    }

    function test_secondExecution_deploysOnlyRemainingRoom_thenNothingToExecute() public {
        _cfg(1, address(spread), 1e6, 20_000e6); // maxAmount below room: first run is capped by maxAmount
        _run(GOLD_SPREAD);
        assertEq(spread.value(), 20_000e6);

        _nextRound();
        uint256 room2 = _expectedRoom();
        assertApproxEqAbs(room2, 10_000e6, 1e6, "30k cap - 20k held (minus accrued fee)");
        assertLt(room2, 20_000e6, "far below maxAmount / 80% allocation");
        _run(GOLD_SPREAD);
        assertEq(spread.value(), 20_000e6 + room2, "second run only deploys remaining room");
        assertLt(_expectedRoom(), 1e6, "gold cap exhausted");

        _nextRound();
        _score(GOLD_SPREAD);
        vm.expectRevert(RiskTieredExecutor.NothingToExecute.selector);
        exec.executeWinner();
        assertEq(spread.value(), 20_000e6 + room2, "nothing more deployed");
    }

    function test_roomBelowMinAmount_revertsNothingToExecute() public {
        _cfg(1, address(spread), 31_000e6, type(uint256).max); // room is 30k < min 31k (80k allocation > min)
        _score(GOLD_SPREAD);
        vm.expectRevert(RiskTieredExecutor.NothingToExecute.selector);
        exec.executeWinner();
        assertEq(spread.value(), 0);
    }

    function test_roomEqualToMinAmount_executes() public {
        _cfg(1, address(spread), 30_000e6, type(uint256).max);
        _run(GOLD_SPREAD);
        assertEq(spread.value(), 30_000e6);
    }

    function test_goldMaxAmountStillAppliesWhenSmaller() public {
        _cfg(5, address(alloc), 1e6, 7_000e6);
        _run(GOLD_ALLOC);
        assertEq(alloc.value(), 7_000e6);
    }

    // ── combined value ───────────────────────────────────────────────────────
    function test_bothGoldAdaptersHeld_combinedValueUsed() public {
        spread.setValue(10_000e6);
        alloc.setValue(5_000e6);
        uint256 room = _expectedRoom();
        assertGt(room, 0);
        assertLt(room, 30_000e6 - 5_000e6, "both holdings reduce room");
        uint256 before = spread.value();
        _run(GOLD_SPREAD);
        assertEq(spread.value() - before, room, "deploys the combined-aware room");
        assertEq(alloc.value(), 5_000e6);
    }

    function test_spreadEqualsAllocation_countedOnce() public {
        vm.prank(owner);
        vault.setGoldAllocationAdapter(address(spread)); // same adapter in both slots
        assertEq(vault.goldSpreadAdapter(), vault.goldAllocationAdapter());
        spread.setValue(10_000e6);
        uint256 room = _expectedRoom();
        uint256 cap = vault.totalAssets() * 3000 / 10_000;
        assertEq(room, cap - 10_000e6, "counted once, not twice");
        _run(GOLD_SPREAD);
        assertEq(spread.value(), 10_000e6 + room);
    }

    function test_goldAlreadyOverCap_revertsNothingToExecute() public {
        spread.setValue(60_000e6); // far above 30% cap
        _score(GOLD_SPREAD);
        vm.expectRevert(RiskTieredExecutor.NothingToExecute.selector);
        exec.executeWinner();
    }

    // ── non-gold not clamped ─────────────────────────────────────────────────
    function test_halalLp_notClamped() public {
        _run(HALAL_LP);
        assertEq(lp.value(), 80_000e6, "full 80% allocation, no gold clamp");
    }

    function test_murabaha_notClamped() public {
        _run(MURABAHA);
        assertEq(lp.value(), 80_000e6);
    }

    function test_halalLp_notClamped_evenWhenGoldRoomIsZero() public {
        _run(GOLD_SPREAD); // fills 30k gold cap
        _nextRound();
        assertLt(_expectedRoom(), 1e6, "gold room exhausted");
        uint256 remaining = (vault.totalAssets() * 8_000) / 10_000 - vault.totalDeployed();
        assertGt(remaining, 40_000e6);
        _run(HALAL_LP);
        assertEq(lp.value(), remaining, "remaining 80% allocation, unaffected by gold room");
    }

    function test_conservativeTier_alsoClampsGold() public {
        vm.startPrank(owner);
        RiskTieredExecutor c = new RiskTieredExecutor(
            address(vault), address(0), RiskTieredExecutor.RiskTier.SHARIAH_CONSERVATIVE, owner
        );
        c.setShariahAggregator(address(agg));
        c.setShariahStrategyConfig(1, address(spread), bytes32(0), true, 1e6, type(uint256).max);
        vault.setManager(address(c));
        vm.stopPrank();
        _score(GOLD_SPREAD);
        c.executeWinner();
        assertEq(spread.value(), 30_000e6);
    }

    // ── conventional tiers unaffected ────────────────────────────────────────
    function test_conventionalTier_unaffected() public {
        vm.startPrank(owner);
        AutonomousVault cv = new AutonomousVault(IERC20(address(usdc)), owner, 26);
        cv.setMaxAllocationBps(8_000);
        ScoreAggregator sagg = new ScoreAggregator(owner);
        RiskTieredExecutor ce = new RiskTieredExecutor(
            address(cv), address(sagg), RiskTieredExecutor.RiskTier.PASSIVE, owner
        );
        cv.setManager(address(ce));
        GoldCapMockAdapter ca = new GoldCapMockAdapter(address(cv), false);
        ce.setStrategyConfig(ScoreAggregator.Strategy.STABLECOIN_SPREAD, address(ca), bytes32(0), true, 1e6, type(uint256).max);
        sagg.writeScore(ScoreAggregator.Strategy.STABLECOIN_SPREAD, 90, H, 0);
        vm.stopPrank();

        usdc.mint(alice, 10_000e6);
        vm.startPrank(alice);
        usdc.approve(address(cv), 10_000e6);
        cv.deposit(10_000e6, alice);
        vm.stopPrank();

        ce.executeWinner();
        assertEq(cv.totalDeployed(), 8_000e6, "full 80% allocation for conventional tier");
        assertEq(ca.value(), 8_000e6);
    }
}
