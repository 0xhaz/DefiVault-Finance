// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStrategyAdapter} from "../IStrategyAdapter.sol";
import {AutonomousVault} from "../AutonomousVault.sol";
import {ScoreAggregator} from "../ScoreAggregator.sol";
import {RiskTieredExecutor} from "../RiskTieredExecutor.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";

contract FuzzExecAdapter is IStrategyAdapter {
    address public override vault;
    address public usdc;
    constructor(address v, address u) { vault = v; usdc = u; }
    function deploy(uint256 a) external override returns (uint256) { return a; }
    function recall(uint256 a) external override returns (uint256) {
        IERC20(usdc).transfer(vault, a);
        return a;
    }
    function currentValue() external view override returns (uint256) {
        return IERC20(usdc).balanceOf(address(this));
    }
    function protocolName() external pure override returns (string memory) { return "Fuzz"; }
}

contract FuzzRiskTieredExecutor is Test {
    MockERC20 internal usdc;
    AutonomousVault internal vault;
    ScoreAggregator internal aggregator;
    RiskTieredExecutor internal executor; // PASSIVE
    FuzzExecAdapter internal adapter;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");

    ScoreAggregator.Strategy internal constant S0 = ScoreAggregator.Strategy.STABLECOIN_SPREAD;
    ScoreAggregator.Strategy internal constant S3 = ScoreAggregator.Strategy.LIQUIDATION_RWA;

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);

        vm.startPrank(owner);
        vault      = new AutonomousVault(IERC20(address(usdc)), owner, 1);
        aggregator = new ScoreAggregator(owner);
        executor   = new RiskTieredExecutor(
            address(vault), address(aggregator),
            RiskTieredExecutor.RiskTier.PASSIVE, owner
        );
        vm.stopPrank();

        adapter = new FuzzExecAdapter(address(vault), address(usdc));

        // Fund vault
        usdc.mint(alice, 100_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), 100_000e6);
        vm.prank(alice);
        vault.deposit(100_000e6, alice);

        vm.prank(owner);
        vault.setManager(address(executor));

        vm.prank(owner);
        executor.setMaxGasPrice(1_000 gwei); // never hit in tests

        // Configure S0 (bit 0, in PASSIVE mask=9)
        vm.prank(owner);
        executor.setStrategyConfig(S0, address(adapter), bytes32(0), true, 1e6, 50_000e6);

        // Skip initial cooldown
        skip(2 hours + 1);
    }

    // -----------------------------------------------------------------------
    // Fuzz: any score below minScoreToExecute reverts ScoreTooLow
    // -----------------------------------------------------------------------
    function testFuzz_score_too_low_always_reverts(uint8 score) public {
        // score=0 is treated as "no score written" by ScoreAggregator — winner selection
        // reverts NoValidScores before the ScoreTooLow check can fire.
        // Constrain to 1–79 so a valid-but-low score is always written.
        score = uint8(bound(score, 1, 79)); // PASSIVE min = 80

        vm.prank(owner);
        aggregator.writeScore(S0, score, bytes32(0), 0);

        vm.txGasPrice(1 gwei);
        vm.expectRevert(
            abi.encodeWithSelector(RiskTieredExecutor.ScoreTooLow.selector, score, uint8(80))
        );
        executor.executeWinner();
    }

    // -----------------------------------------------------------------------
    // Fuzz: any score ≥ minScoreToExecute succeeds (assuming cooldown elapsed)
    // -----------------------------------------------------------------------
    function testFuzz_score_sufficient_executes(uint8 score) public {
        score = uint8(bound(score, 80, 100)); // PASSIVE min = 80

        vm.prank(owner);
        aggregator.writeScore(S0, score, bytes32(0), 0);

        vm.txGasPrice(1 gwei);
        executor.executeWinner();

        assertGt(vault.totalDeployed(), 0, "capital should be deployed");
    }

    // -----------------------------------------------------------------------
    // Fuzz: gas price above maxGasPrice always reverts
    // -----------------------------------------------------------------------
    function testFuzz_gas_price_too_high(uint256 gasPrice) public {
        uint256 max = executor.maxGasPrice();
        gasPrice = bound(gasPrice, max + 1, type(uint64).max);

        vm.prank(owner);
        aggregator.writeScore(S0, 90, bytes32(0), 0);

        vm.txGasPrice(gasPrice);
        vm.expectRevert(RiskTieredExecutor.GasPriceTooHigh.selector);
        executor.executeWinner();
    }

    // -----------------------------------------------------------------------
    // Fuzz: any gas price ≤ maxGasPrice does not trigger gas-price revert
    // -----------------------------------------------------------------------
    function testFuzz_gas_price_within_limit(uint256 gasPrice) public {
        uint256 max = executor.maxGasPrice();
        gasPrice = bound(gasPrice, 0, max);

        vm.prank(owner);
        aggregator.writeScore(S0, 90, bytes32(0), 0);

        vm.txGasPrice(gasPrice);
        // Must not revert with GasPriceTooHigh — may revert for other reasons (none here)
        executor.executeWinner();
    }

    // -----------------------------------------------------------------------
    // Fuzz: cooldown guard — any elapsed < cooldown reverts CooldownNotElapsed
    // -----------------------------------------------------------------------
    function testFuzz_cooldown_guard(uint32 shortElapsed) public {
        // First execution to set lastExecutionTime
        vm.prank(owner);
        aggregator.writeScore(S0, 90, bytes32(0), 0);
        vm.txGasPrice(1 gwei);
        executor.executeWinner();

        // Return capital
        uint256 deployed = vault.totalDeployed();
        vm.prank(address(adapter));
        usdc.approve(address(vault), deployed);
        vm.prank(owner);
        vault.returnCapital(address(adapter), deployed);

        uint256 cd = executor.executionCooldown();
        shortElapsed = uint32(bound(shortElapsed, 0, cd > 1 ? cd - 1 : 0));
        skip(shortElapsed);

        // Write fresh score
        vm.prank(owner);
        aggregator.writeScore(S0, 90, bytes32(0), 0);

        vm.txGasPrice(1 gwei);
        if (shortElapsed < cd) {
            vm.expectRevert(); // CooldownNotElapsed
            executor.executeWinner();
        }
    }

    // -----------------------------------------------------------------------
    // Fuzz: strategy not in mask always reverts StrategyNotAllowedForTier
    //   PASSIVE mask = 9 = 0b00001001 (bits 0 and 3 only)
    //   strategies 1 and 2 are NOT in mask
    // -----------------------------------------------------------------------
    function testFuzz_strategy_not_in_mask_reverts(uint8 stratIdx) public {
        // Strategies with bit NOT in PASSIVE mask=9 → bits 1 and 2
        stratIdx = uint8(bound(stratIdx, 1, 2));
        ScoreAggregator.Strategy strat = ScoreAggregator.Strategy(stratIdx);

        // Configure that strategy's adapter (enabled) but mask excludes it
        vm.prank(owner);
        executor.setStrategyConfig(strat, address(adapter), bytes32(0), true, 1e6, 50_000e6);

        // Write a very high score for this strategy and 0 for the others
        // so it would win — then the mask check must block it
        vm.prank(owner);
        aggregator.writeScore(strat, 99, bytes32(0), 0);

        vm.txGasPrice(1 gwei);
        // Winner will be this out-of-mask strategy; must revert
        vm.expectRevert(
            abi.encodeWithSelector(
                RiskTieredExecutor.StrategyNotAllowedForTier.selector,
                stratIdx,
                uint8(9)
            )
        );
        executor.executeWinner();
    }

    // -----------------------------------------------------------------------
    // Fuzz: setMinScore enforces 0–100 range
    // -----------------------------------------------------------------------
    function testFuzz_setMinScore(uint256 score) public {
        if (score > 100) {
            vm.prank(owner);
            vm.expectRevert(); // "Score too high"
            executor.setMinScore(uint8(score > 255 ? 255 : score));
        } else {
            vm.prank(owner);
            executor.setMinScore(uint8(score));
            assertEq(executor.minScoreToExecute(), uint8(score));
        }
    }

    // -----------------------------------------------------------------------
    // Fuzz: setCooldown rejects > 24 hours
    // -----------------------------------------------------------------------
    function testFuzz_setCooldown(uint256 cd) public {
        if (cd > 24 hours) {
            vm.prank(owner);
            vm.expectRevert(); // "Cooldown too long"
            executor.setCooldown(cd);
        } else {
            vm.prank(owner);
            executor.setCooldown(cd);
            assertEq(executor.executionCooldown(), cd);
        }
    }

    // -----------------------------------------------------------------------
    // Fuzz: setMaxGasPrice always accepted (no explicit bound in contract)
    // -----------------------------------------------------------------------
    function testFuzz_setMaxGasPrice(uint256 gp) public {
        vm.prank(owner);
        executor.setMaxGasPrice(gp);
        assertEq(executor.maxGasPrice(), gp);
    }

    // -----------------------------------------------------------------------
    // Fuzz: isStrategyAllowed matches bitmask logic
    // -----------------------------------------------------------------------
    function testFuzz_isStrategyAllowed_matches_mask(uint8 stratIdx) public view {
        stratIdx = uint8(bound(stratIdx, 0, 3));
        ScoreAggregator.Strategy strat = ScoreAggregator.Strategy(stratIdx);

        bool expected = ((executor.strategyMask() >> stratIdx) & 1) == 1;
        assertEq(executor.isStrategyAllowed(strat), expected, "isStrategyAllowed must match mask bit");
    }
}
