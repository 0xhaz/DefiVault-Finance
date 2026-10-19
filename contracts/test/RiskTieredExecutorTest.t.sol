// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStrategyAdapter} from "../IStrategyAdapter.sol";
import {AutonomousVault} from "../AutonomousVault.sol";
import {ScoreAggregator} from "../ScoreAggregator.sol";
import {RiskTieredExecutor} from "../RiskTieredExecutor.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";

// ---------------------------------------------------------------------------
// MockAdapter that accepts deploy/recall for the executor tests
// ---------------------------------------------------------------------------
contract ExecMockAdapter is IStrategyAdapter {
    address public override vault;
    address public usdc;

    constructor(address vault_, address usdc_) {
        vault = vault_;
        usdc = usdc_;
    }

    function deploy(uint256 amount) external override returns (uint256) {
        return amount;
    }

    function recall(uint256 amount) external override returns (uint256) {
        IERC20(usdc).transfer(vault, amount);
        return amount;
    }

    function currentValue() external view override returns (uint256) {
        return IERC20(usdc).balanceOf(address(this));
    }

    function protocolName() external pure override returns (string memory) {
        return "ExecMockAdapter";
    }
}

// ---------------------------------------------------------------------------
// RiskTieredExecutorTest
// ---------------------------------------------------------------------------
contract RiskTieredExecutorTest is Test {
    MockERC20 internal usdc;
    AutonomousVault internal vault;
    ScoreAggregator internal aggregator;
    RiskTieredExecutor internal executor;
    ExecMockAdapter internal adapter;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal random = makeAddr("random");

    uint32 internal constant SOURCE_DOMAIN = 1;

    ScoreAggregator.Strategy internal constant S0 = ScoreAggregator.Strategy.STABLECOIN_SPREAD;  // idx 0
    ScoreAggregator.Strategy internal constant S1 = ScoreAggregator.Strategy.FUNDING_RATE_ARB;   // idx 1
    ScoreAggregator.Strategy internal constant S2 = ScoreAggregator.Strategy.BRIDGE_FLOW;        // idx 2
    ScoreAggregator.Strategy internal constant S3 = ScoreAggregator.Strategy.LIQUIDATION_RWA;    // idx 3

    bytes32 internal constant DATA_HASH = keccak256("test");

    function setUp() public {
        // Deploy stack
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);

        vm.startPrank(owner);
        vault = new AutonomousVault(IERC20(address(usdc)), owner, SOURCE_DOMAIN);
        aggregator = new ScoreAggregator(owner);
        executor = new RiskTieredExecutor(
            address(vault),
            address(aggregator),
            RiskTieredExecutor.RiskTier.PASSIVE,
            owner
        );
        vm.stopPrank();

        // Deploy adapter (vault is owner for adapter purposes)
        adapter = new ExecMockAdapter(address(vault), address(usdc));

        // Fund vault with 10_000e6 so there's allocation room
        usdc.mint(alice, 10_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), 10_000e6);
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // Set executor as vault manager
        vm.prank(owner);
        vault.setManager(address(executor));

        // Raise maxGasPrice so default gas doesn't trigger GasPriceTooHigh
        vm.prank(owner);
        executor.setMaxGasPrice(100 gwei);
    }

    // -----------------------------------------------------------------------
    // Helper: configure S0 adapter
    // -----------------------------------------------------------------------
    function _configureS0(uint256 minAmt, uint256 maxAmt) internal {
        vm.prank(owner);
        executor.setStrategyConfig(
            S0,
            address(adapter),
            bytes32(0),
            true,
            minAmt,
            maxAmt
        );
    }

    /// @dev Write a fresh score (always at current block.timestamp so it is not stale).
    function _writeScore(ScoreAggregator.Strategy strat, uint8 score, uint32 domain) internal {
        vm.prank(owner);
        aggregator.writeScore(strat, score, DATA_HASH, domain);
    }

    /// @dev Skip cooldown AND then write a fresh score — score is always current after the skip.
    function _skipCooldownAndWriteScore(ScoreAggregator.Strategy strat, uint8 score, uint32 domain) internal {
        skip(2 hours + 1);
        _writeScore(strat, score, domain);
    }

    // -----------------------------------------------------------------------
    // test_executeWinner_happy_path
    // -----------------------------------------------------------------------
    function test_executeWinner_happy_path() public {
        _configureS0(1e6, 2_000e6);

        // Skip past cooldown, then write a fresh score
        _skipCooldownAndWriteScore(S0, 85, 0);

        vm.txGasPrice(1 gwei);
        vm.expectEmit(true, false, false, false, address(executor));
        emit RiskTieredExecutor.ExecutionTriggered(S0, 85, 0, address(adapter), RiskTieredExecutor.RiskTier.PASSIVE);
        executor.executeWinner();

        assertGt(vault.totalDeployed(), 0, "capital should have been deployed");
    }

    // -----------------------------------------------------------------------
    // test_executeWinner_score_too_low (PASSIVE min=80)
    // -----------------------------------------------------------------------
    function test_executeWinner_score_too_low() public {
        _configureS0(1e6, 2_000e6);

        _skipCooldownAndWriteScore(S0, 70, 0); // 70 < 80

        vm.txGasPrice(1 gwei);
        vm.expectRevert(abi.encodeWithSelector(RiskTieredExecutor.ScoreTooLow.selector, uint8(70), uint8(80)));
        executor.executeWinner();
    }

    // -----------------------------------------------------------------------
    // test_executeWinner_cooldown_not_elapsed
    // -----------------------------------------------------------------------
    function test_executeWinner_cooldown_not_elapsed() public {
        _configureS0(1e6, 2_000e6);

        _skipCooldownAndWriteScore(S0, 85, 0);

        vm.txGasPrice(1 gwei);
        executor.executeWinner(); // first execution succeeds

        // Re-write fresh score immediately after execution
        _writeScore(S0, 85, 0);

        // Try again without waiting cooldown — should revert CooldownNotElapsed
        vm.txGasPrice(1 gwei);
        vm.expectRevert(); // CooldownNotElapsed
        executor.executeWinner();
    }

    // -----------------------------------------------------------------------
    // test_executeWinner_cooldown_boundary — exact boundary warp
    // -----------------------------------------------------------------------
    function test_executeWinner_cooldown_boundary() public {
        _configureS0(1e6, 2_000e6);

        // Record current time as lastExecutionTime baseline (it's 0 by default → cooldown already elapsed)
        // First: do an execution to set lastExecutionTime
        _skipCooldownAndWriteScore(S0, 85, 0);
        vm.txGasPrice(1 gwei);
        executor.executeWinner();
        uint256 lastExec = executor.lastExecutionTime();

        // cooldown is 2 hours; warp to exactly lastExec+cooldown-1 → should revert
        vm.warp(lastExec + 2 hours - 1);
        _writeScore(S0, 85, 0);
        vm.txGasPrice(1 gwei);
        vm.expectRevert(); // CooldownNotElapsed
        executor.executeWinner();

        // Return capital so vault has headroom
        _returnAdapterCapital();

        // warp 1 more second → exactly at cooldown → should succeed
        vm.warp(lastExec + 2 hours);
        _writeScore(S0, 85, 0);
        vm.txGasPrice(1 gwei);
        executor.executeWinner();
    }

    // -----------------------------------------------------------------------
    // test_executeWinner_gas_price_too_high
    // -----------------------------------------------------------------------
    function test_executeWinner_gas_price_too_high() public {
        _configureS0(1e6, 2_000e6);

        _skipCooldownAndWriteScore(S0, 85, 0);

        // Set gas price above maxGasPrice (100 gwei in setUp)
        vm.txGasPrice(101 gwei);
        vm.expectRevert(RiskTieredExecutor.GasPriceTooHigh.selector);
        executor.executeWinner();
    }

    // -----------------------------------------------------------------------
    // test_executeWinner_strategy_not_in_mask
    // PASSIVE mask=9 (bits 0+3), BRIDGE_FLOW is bit 2 → not allowed
    // -----------------------------------------------------------------------
    function test_executeWinner_strategy_not_in_mask() public {
        // Configure S2 adapter but PASSIVE mask doesn't include it
        vm.prank(owner);
        executor.setStrategyConfig(S2, address(adapter), bytes32(0), true, 1e6, 2_000e6);

        // Write a score only for S2 (so it wins)
        _skipCooldownAndWriteScore(S2, 85, 0);

        vm.txGasPrice(1 gwei);
        vm.expectRevert(
            abi.encodeWithSelector(RiskTieredExecutor.StrategyNotAllowedForTier.selector, uint8(2), uint8(9))
        );
        executor.executeWinner();
    }

    // -----------------------------------------------------------------------
    // test_executeWinner_adapter_not_set
    // -----------------------------------------------------------------------
    function test_executeWinner_adapter_not_set() public {
        // S0 is in mask (PASSIVE mask bit 0), but no adapter configured
        _skipCooldownAndWriteScore(S0, 85, 0);

        vm.txGasPrice(1 gwei);
        // StrategyDisabled is checked first (enabled=false, adapter=address(0))
        vm.expectRevert(RiskTieredExecutor.StrategyDisabled.selector);
        executor.executeWinner();
    }

    // -----------------------------------------------------------------------
    // test_executeWinner_strategy_disabled
    // -----------------------------------------------------------------------
    function test_executeWinner_strategy_disabled() public {
        // Set adapter but enabled=false
        vm.prank(owner);
        executor.setStrategyConfig(S0, address(adapter), bytes32(0), false, 1e6, 2_000e6);

        _skipCooldownAndWriteScore(S0, 85, 0);

        vm.txGasPrice(1 gwei);
        vm.expectRevert(RiskTieredExecutor.StrategyDisabled.selector);
        executor.executeWinner();
    }

    // -----------------------------------------------------------------------
    // test_executeWinner_adapter_address_zero_reverts
    // With enabled=true but adapter=address(0) → AdapterNotSet
    // -----------------------------------------------------------------------
    function test_executeWinner_adapter_address_zero_reverts() public {
        // Configure with enabled=true, adapter=address(0)
        vm.prank(owner);
        executor.setStrategyConfig(S0, address(0), bytes32(0), true, 1e6, 2_000e6);

        _skipCooldownAndWriteScore(S0, 85, 0);

        vm.txGasPrice(1 gwei);
        vm.expectRevert(RiskTieredExecutor.AdapterNotSet.selector);
        executor.executeWinner();
    }

    // -----------------------------------------------------------------------
    // test_setStrategyConfig_only_owner
    // -----------------------------------------------------------------------
    function test_setStrategyConfig_only_owner() public {
        vm.prank(random);
        vm.expectRevert();
        executor.setStrategyConfig(S0, address(adapter), bytes32(0), true, 1e6, 2_000e6);
    }

    // -----------------------------------------------------------------------
    // test_aggressive_tier_lower_min_score
    // AGGRESSIVE min=60; write score 65 → should execute
    // -----------------------------------------------------------------------
    function test_aggressive_tier_lower_min_score() public {
        // Deploy a fresh aggressive executor
        vm.prank(owner);
        RiskTieredExecutor aggExec = new RiskTieredExecutor(
            address(vault),
            address(aggregator),
            RiskTieredExecutor.RiskTier.AGGRESSIVE,
            owner
        );
        // AGGRESSIVE mask=15 — all 4 strategies; configure S0
        vm.prank(owner);
        aggExec.setStrategyConfig(S0, address(adapter), bytes32(0), true, 1e6, 2_000e6);

        // Set aggExec as manager
        vm.prank(owner);
        vault.setManager(address(aggExec));

        // Raise gas ceiling
        vm.prank(owner);
        aggExec.setMaxGasPrice(100 gwei);

        // Skip 31 minutes (past 30-min AGGRESSIVE cooldown), then write fresh score
        skip(31 minutes);
        _writeScore(S0, 65, 0); // 65 >= 60 (AGGRESSIVE min)

        vm.txGasPrice(1 gwei);
        aggExec.executeWinner(); // must NOT revert ScoreTooLow
        assertGt(vault.totalDeployed(), 0, "capital should have been deployed");
    }

    // -----------------------------------------------------------------------
    // test_cooldown_resets_after_execution
    // -----------------------------------------------------------------------
    function test_cooldown_resets_after_execution() public {
        _configureS0(1e6, 2_000e6);

        // First execution
        _skipCooldownAndWriteScore(S0, 85, 0);
        vm.txGasPrice(1 gwei);
        executor.executeWinner();
        uint256 firstDeploy = vault.totalDeployed();
        assertGt(firstDeploy, 0, "first deploy should succeed");

        // Return capital so vault has headroom for second deploy
        _returnAdapterCapital();
        assertEq(vault.totalDeployed(), 0);

        // Wait for cooldown again, write fresh score
        skip(2 hours + 1);
        _writeScore(S0, 85, 0);
        vm.txGasPrice(1 gwei);
        executor.executeWinner(); // should succeed again
        assertGt(vault.totalDeployed(), 0, "second deploy should succeed");
    }

    // -----------------------------------------------------------------------
    // Internal helper: return capital from adapter back to vault
    // -----------------------------------------------------------------------
    function _returnAdapterCapital() internal {
        uint256 deployed = vault.totalDeployed();
        if (deployed == 0) return;

        // Adapter holds the USDC; approve vault to pull back
        vm.prank(address(adapter));
        usdc.approve(address(vault), deployed);
        vm.prank(owner);
        vault.returnCapital(address(adapter), deployed);
    }
}
