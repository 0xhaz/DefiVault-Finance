// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AutonomousVault} from "./AutonomousVault.sol";
import {ScoreAggregator} from "./ScoreAggregator.sol";

contract VaultExecutor is Ownable2Step {
    struct StrategyConfig {
        address target;
        bytes32 recipient;
        bool enabled;
        uint256 minAmount;
        uint256 maxAmount;
    }

    error ScoreTooLow(uint8 score, uint8 min);
    error CooldownNotElapsed(uint256 remaining);
    error StrategyDisabled();
    error GasPriceTooHigh();
    error NothingToExecute();

    event StrategyConfigUpdated(
        ScoreAggregator.Strategy indexed strategy,
        address indexed target,
        bytes32 recipient,
        bool enabled,
        uint256 minAmount,
        uint256 maxAmount
    );
    event MinScoreUpdated(uint8 previousMinScore, uint8 newMinScore);
    event CooldownUpdated(uint256 previousCooldown, uint256 newCooldown);
    event MaxGasPriceUpdated(uint256 previousMaxGasPrice, uint256 newMaxGasPrice);
    event ExecutionTriggered(
        ScoreAggregator.Strategy indexed strategy,
        uint8 score,
        uint256 amount,
        address indexed target
    );
    event CrossChainExecutionTriggered(
        ScoreAggregator.Strategy indexed strategy,
        uint8 score,
        uint256 amount,
        uint32 indexed destinationDomain,
        bytes32 recipient
    );

    AutonomousVault public immutable vault;
    ScoreAggregator public immutable aggregator;

    uint8 public minScoreToExecute = 60;
    uint256 public executionCooldown = 30 minutes;
    uint256 public lastExecutionTime;
    uint256 public maxGasPrice = 50 gwei;

    mapping(ScoreAggregator.Strategy => StrategyConfig) public strategyConfigs;

    constructor(address vault_, address aggregator_, address initialOwner) Ownable(initialOwner) {
        vault = AutonomousVault(vault_);
        aggregator = ScoreAggregator(aggregator_);
    }

    function executeWinner() external {
        if (tx.gasprice > maxGasPrice) revert GasPriceTooHigh();

        uint256 nextExecutionTime = lastExecutionTime + executionCooldown;
        if (block.timestamp < nextExecutionTime) {
            revert CooldownNotElapsed(nextExecutionTime - block.timestamp);
        }

        (ScoreAggregator.Strategy strategy, uint8 score, uint32 destinationDomain) = aggregator.getWinningStrategy();
        if (score < minScoreToExecute) revert ScoreTooLow(score, minScoreToExecute);

        StrategyConfig memory config = strategyConfigs[strategy];
        if (!config.enabled) revert StrategyDisabled();

        uint256 totalAssets_ = vault.totalAssets();
        uint256 allocationCap = (totalAssets_ * vault.maxAllocationBps()) / 10_000;
        uint256 deployed = vault.totalDeployed();
        if (allocationCap <= deployed) revert NothingToExecute();

        uint256 remainingAllocation = allocationCap - deployed;
        uint256 idleAssets = IERC20(vault.asset()).balanceOf(address(vault));

        uint256 amount = remainingAllocation;
        if (amount > config.maxAmount) amount = config.maxAmount;
        if (amount > idleAssets) amount = idleAssets;

        if (amount < config.minAmount || amount == 0) revert NothingToExecute();

        if (destinationDomain == 0) {
            vault.deployCapital(config.target, amount, "");
            emit ExecutionTriggered(strategy, score, amount, config.target);
        } else {
            vault.deployCrossChain(destinationDomain, config.recipient, amount);
            emit CrossChainExecutionTriggered(strategy, score, amount, destinationDomain, config.recipient);
        }

        lastExecutionTime = block.timestamp;
    }

    function setStrategyConfig(
        ScoreAggregator.Strategy strategy,
        address target,
        bytes32 recipient,
        bool enabled,
        uint256 minAmount,
        uint256 maxAmount
    ) external onlyOwner {
        strategyConfigs[strategy] = StrategyConfig({
            target: target,
            recipient: recipient,
            enabled: enabled,
            minAmount: minAmount,
            maxAmount: maxAmount
        });

        emit StrategyConfigUpdated(strategy, target, recipient, enabled, minAmount, maxAmount);
    }

    function setMinScore(uint8 newMinScore) external onlyOwner {
        uint8 previousMinScore = minScoreToExecute;
        minScoreToExecute = newMinScore;
        emit MinScoreUpdated(previousMinScore, newMinScore);
    }

    function setCooldown(uint256 newCooldown) external onlyOwner {
        require(newCooldown <= 24 hours, "Cooldown too long");
        uint256 previousCooldown = executionCooldown;
        executionCooldown = newCooldown;
        emit CooldownUpdated(previousCooldown, newCooldown);
    }

    function setMaxGasPrice(uint256 newMaxGasPrice) external onlyOwner {
        uint256 previousMaxGasPrice = maxGasPrice;
        maxGasPrice = newMaxGasPrice;
        emit MaxGasPriceUpdated(previousMaxGasPrice, newMaxGasPrice);
    }
}
