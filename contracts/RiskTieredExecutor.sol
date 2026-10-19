// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AutonomousVault} from "./AutonomousVault.sol";
import {ScoreAggregator} from "./ScoreAggregator.sol";
import {ShariahScoreAggregator} from "./ShariahScoreAggregator.sol";
import {IStrategyAdapter} from "./IStrategyAdapter.sol";

contract RiskTieredExecutor is Ownable2Step {
    enum RiskTier {
        PASSIVE,
        AGGRESSIVE,
        SHARIAH_CONSERVATIVE, // Halal LP (bit1) + Gold Spread (bit2) + RWA Sukuk (bit3) — low-vol only
        SHARIAH_DYNAMIC       // All 5 halal strategies — full Shariah universe
    }

    struct StrategyConfig {
        address adapter;
        bytes32 recipient;
        bool enabled;
        uint256 minAmount;
        uint256 maxAmount;
    }

    error ScoreTooLow(uint8 score, uint8 min);
    error CooldownNotElapsed(uint256 remaining);
    error StrategyDisabled();
    error StrategyNotAllowedForTier(uint8 strategyIdx, uint8 mask);
    error GasPriceTooHigh();
    error NothingToExecute();
    error AdapterNotSet();

    event ExecutionTriggered(
        ScoreAggregator.Strategy indexed strategy,
        uint8 score,
        uint256 amount,
        address indexed adapter,
        RiskTier tier
    );
    event ShariahExecutionTriggered(
        ShariahScoreAggregator.ShariahStrategy indexed strategy,
        uint8 score,
        uint256 amount,
        address indexed adapter,
        RiskTier tier
    );
    event CrossChainExecutionTriggered(
        ScoreAggregator.Strategy indexed strategy,
        uint8 score,
        uint256 amount,
        uint32 indexed destinationDomain,
        bytes32 recipient,
        RiskTier tier
    );
    event StrategyConfigUpdated(
        ScoreAggregator.Strategy indexed strategy,
        address adapter,
        bool enabled,
        RiskTier tier
    );
    event ShariahStrategyConfigUpdated(uint8 indexed strategyIdx, address adapter, bool enabled, RiskTier tier);
    event MinScoreUpdated(uint8 prev, uint8 next);
    event CooldownUpdated(uint256 prev, uint256 next);
    event MaxGasPriceUpdated(uint256 prev, uint256 next);
    event StrategyMaskUpdated(uint8 prev, uint8 next);
    event ShariahAggregatorUpdated(address prev, address next);

    AutonomousVault public immutable vault;
    ScoreAggregator public immutable aggregator;
    RiskTier public immutable riskTier;
    string public tierName;

    ShariahScoreAggregator public shariahAggregator;

    uint8 public minScoreToExecute;
    uint256 public executionCooldown;
    uint256 public maxGasPrice;
    uint256 public lastExecutionTime;

    uint8 public strategyMask;

    mapping(ScoreAggregator.Strategy => StrategyConfig) public strategyConfigs;
    mapping(uint8 => StrategyConfig) public shariahStrategyConfigs;

    constructor(address vault_, address aggregator_, RiskTier tier_, address initialOwner) Ownable(initialOwner) {
        vault = AutonomousVault(vault_);
        aggregator = ScoreAggregator(aggregator_);
        riskTier = tier_;

        if (tier_ == RiskTier.PASSIVE) {
            minScoreToExecute = 80;
            executionCooldown = 2 hours;
            maxGasPrice = 20 gwei;
            strategyMask = 9;   // 0b00001001 — S0 + S3
            tierName = "Passive";
        } else if (tier_ == RiskTier.SHARIAH_CONSERVATIVE) {
            // Halal LP (bit1), Gold Spread (bit2), RWA/Sukuk (bit4) = 0b10110
            minScoreToExecute = 80;
            executionCooldown = 2 hours;
            maxGasPrice = 20 gwei;
            strategyMask = 22;  // 0b00010110 — bits 1,2,4
            tierName = "Shariah Conservative";
        } else if (tier_ == RiskTier.SHARIAH_DYNAMIC) {
            // All 5 halal strategies = 0b11111
            minScoreToExecute = 70;
            executionCooldown = 1 hours;
            maxGasPrice = 30 gwei;
            strategyMask = 31;  // 0b00011111
            tierName = "Shariah Dynamic";
        } else {
            // AGGRESSIVE
            minScoreToExecute = 60;
            executionCooldown = 30 minutes;
            maxGasPrice = 50 gwei;
            strategyMask = 15;  // 0b00001111 — all 4 conventional
            tierName = "Aggressive";
        }
    }

    function executeWinner() external {
        if (tx.gasprice > maxGasPrice) revert GasPriceTooHigh();

        uint256 nextExecutionTime = lastExecutionTime + executionCooldown;
        if (block.timestamp < nextExecutionTime) {
            revert CooldownNotElapsed(nextExecutionTime - block.timestamp);
        }

        uint8 score;
        uint8 idx;
        uint32 destinationDomain;
        StrategyConfig memory config;

        ScoreAggregator.Strategy strategy;
        ShariahScoreAggregator.ShariahStrategy shariahStrategy;

        if (riskTier == RiskTier.SHARIAH_CONSERVATIVE || riskTier == RiskTier.SHARIAH_DYNAMIC) {
            (shariahStrategy, score, destinationDomain) = shariahAggregator.getWinningShariahStrategy();
            if (score < minScoreToExecute) revert ScoreTooLow(score, minScoreToExecute);

            idx = uint8(shariahStrategy);
            if (((strategyMask >> idx) & 1) == 0) {
                revert StrategyNotAllowedForTier(idx, strategyMask);
            }

            config = shariahStrategyConfigs[idx];
            destinationDomain = 0;
        } else {
            (strategy, score, destinationDomain) = aggregator.getWinningStrategy();
            if (score < minScoreToExecute) revert ScoreTooLow(score, minScoreToExecute);

            idx = uint8(strategy);
            if (((strategyMask >> idx) & 1) == 0) {
                revert StrategyNotAllowedForTier(idx, strategyMask);
            }

            config = strategyConfigs[strategy];
        }

        if (!config.enabled) revert StrategyDisabled();
        if (config.adapter == address(0)) revert AdapterNotSet();

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

        bool isShariahTier = (riskTier == RiskTier.SHARIAH_CONSERVATIVE || riskTier == RiskTier.SHARIAH_DYNAMIC);
        if (isShariahTier || destinationDomain == 0) {
            vault.deployCapital(config.adapter, amount, "");
            IStrategyAdapter(config.adapter).deploy(amount);

            if (isShariahTier) {
                emit ShariahExecutionTriggered(shariahStrategy, score, amount, config.adapter, riskTier);
            } else {
                emit ExecutionTriggered(strategy, score, amount, config.adapter, riskTier);
            }
        } else {
            vault.deployCrossChain(destinationDomain, config.recipient, amount);

            emit CrossChainExecutionTriggered(strategy, score, amount, destinationDomain, config.recipient, riskTier);
        }

        lastExecutionTime = block.timestamp;
    }

    function setStrategyConfig(
        ScoreAggregator.Strategy strategy,
        address adapter,
        bytes32 recipient,
        bool enabled,
        uint256 minAmount,
        uint256 maxAmount
    ) external onlyOwner {
        strategyConfigs[strategy] = StrategyConfig({
            adapter: adapter,
            recipient: recipient,
            enabled: enabled,
            minAmount: minAmount,
            maxAmount: maxAmount
        });

        emit StrategyConfigUpdated(strategy, adapter, enabled, riskTier);
    }

    function setShariahStrategyConfig(
        uint8 strategyIdx,
        address adapter,
        bytes32 recipient,
        bool enabled,
        uint256 minAmount,
        uint256 maxAmount
    ) external onlyOwner {
        shariahStrategyConfigs[strategyIdx] = StrategyConfig({
            adapter: adapter,
            recipient: recipient,
            enabled: enabled,
            minAmount: minAmount,
            maxAmount: maxAmount
        });

        emit ShariahStrategyConfigUpdated(strategyIdx, adapter, enabled, riskTier);
    }

    function setShariahAggregator(address aggregator_) external onlyOwner {
        address prev = address(shariahAggregator);
        shariahAggregator = ShariahScoreAggregator(aggregator_);
        emit ShariahAggregatorUpdated(prev, aggregator_);
    }

    function setMinScore(uint8 newMinScore) external onlyOwner {
        require(newMinScore <= 100, "Score too high");
        uint8 prev = minScoreToExecute;
        minScoreToExecute = newMinScore;
        emit MinScoreUpdated(prev, newMinScore);
    }

    function setCooldown(uint256 newCooldown) external onlyOwner {
        require(newCooldown <= 24 hours, "Cooldown too long");
        uint256 prev = executionCooldown;
        executionCooldown = newCooldown;
        emit CooldownUpdated(prev, newCooldown);
    }

    function setMaxGasPrice(uint256 newMaxGasPrice) external onlyOwner {
        uint256 prev = maxGasPrice;
        maxGasPrice = newMaxGasPrice;
        emit MaxGasPriceUpdated(prev, newMaxGasPrice);
    }

    function setStrategyMask(uint8 mask) external onlyOwner {
        uint8 prev = strategyMask;
        strategyMask = mask;
        emit StrategyMaskUpdated(prev, mask);
    }

    function isStrategyAllowed(ScoreAggregator.Strategy strategy) external view returns (bool) {
        uint8 idx = uint8(strategy);
        return ((strategyMask >> idx) & 1) == 1;
    }

    function getConfig(ScoreAggregator.Strategy strategy) external view returns (StrategyConfig memory) {
        return strategyConfigs[strategy];
    }
}
