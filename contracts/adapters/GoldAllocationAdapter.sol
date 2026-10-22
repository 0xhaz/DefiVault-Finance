// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategyAdapter} from "../IStrategyAdapter.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";

/// @notice Uniswap V3 interface (minimal — only exactInputSingle needed)
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut);
}

/// @notice Minimal pool interface for reading slot0 sqrtPriceX96.
interface IUniswapV3PoolSlot0 {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}

contract GoldAllocationAdapter is IStrategyAdapter, Ownable2Step {
    using SafeERC20 for IERC20;

    error ZeroAmount();
    error StaleGoldPrice();
    error GoldPriceDeviation(uint256 poolPrice, uint256 oraclePrice, uint256 maxDeviationBps);
    error SlippageExceeded(uint256 amountOut, uint256 minOut);
    error ParamAboveHardCap(string param, uint256 value, uint256 cap);
    error TimelockNotElapsed(uint256 executeAfter, uint256 now_);
    error NoProposalPending();

    event GoldBought(uint256 usdcIn, uint256 xautOut, uint256 oraclePrice);
    event GoldSold(uint256 xautIn, uint256 usdcOut, uint256 oraclePrice);
    event ParamChangeProposed(bytes32 indexed paramId, uint256 newValue, uint256 executeAfter);
    event ParamChangeExecuted(bytes32 indexed paramId, uint256 newValue);

    uint256 public constant MAX_SLIPPAGE_BPS = 200;
    uint256 public constant MAX_DEVIATION_BPS = 300;
    uint256 public constant TIMELOCK_DELAY = 30 days;

    IERC20 public immutable usdc;
    IERC20 public immutable xaut;
    uint8 public immutable usdcDecimals;
    uint8 public immutable xautDecimals;
    /// @dev Mutable — updated atomically when goldOracle is changed via executeAddressParamChange.
    ///      Cannot be immutable because the oracle address itself is board-settable.
    uint8 public oracleDecimals;
    address public immutable vault;

    ISwapRouter public swapRouter;
    AggregatorV3Interface public goldOracle;
    uint24 public poolFee;
    uint256 public maxStalenessSecs;
    uint256 public maxSlippageBps;
    uint256 public maxDeviationBps;

    uint256 public xautHeld;
    uint256 public totalDeployed;

    address public pool;

    struct PendingChange {
        uint256 newValue;
        uint256 executeAfter;
        bool pending;
    }

    struct PendingAddressChange {
        address newValue;
        uint256 executeAfter;
        bool pending;
    }

    mapping(bytes32 => PendingChange) public pendingChanges;
    mapping(bytes32 => PendingAddressChange) public pendingAddressChanges;

    bytes32 public constant PARAM_MAX_STALENESS = keccak256("maxStalenessSecs");
    bytes32 public constant PARAM_MAX_SLIPPAGE = keccak256("maxSlippageBps");
    bytes32 public constant PARAM_MAX_DEVIATION = keccak256("maxDeviationBps");
    bytes32 public constant PARAM_POOL_FEE = keccak256("poolFee");
    bytes32 public constant PARAM_SWAP_ROUTER = keccak256("swapRouter");
    bytes32 public constant PARAM_GOLD_ORACLE = keccak256("goldOracle");

    constructor(
        address usdc_,
        address xaut_,
        address swapRouter_,
        uint24 poolFee_,
        address goldOracle_,
        address vault_,
        uint256 initialMaxStalenessSecs,
        address initialOwner
    ) Ownable(initialOwner) {
        usdc = IERC20(usdc_);
        xaut = IERC20(xaut_);
        usdcDecimals = IERC20Metadata(usdc_).decimals();
        xautDecimals = IERC20Metadata(xaut_).decimals();
        oracleDecimals = AggregatorV3Interface(goldOracle_).decimals();

        swapRouter = ISwapRouter(swapRouter_);
        goldOracle = AggregatorV3Interface(goldOracle_);
        poolFee = poolFee_;
        vault = vault_;
        pool = swapRouter_;

        maxSlippageBps = 50;
        maxDeviationBps = 100;
        maxStalenessSecs = initialMaxStalenessSecs;
    }

    modifier onlyVault() {
        require(msg.sender == vault, "GoldAllocationAdapter: caller is not vault");
        _;
    }

    function _pow10(uint8 d) internal pure returns (uint256) {
        return 10 ** uint256(d);
    }

    function _getOraclePrice() internal view returns (uint256 oraclePriceUsdc) {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
            = goldOracle.latestRoundData();

        // Round completeness checks (Chainlink best practice)
        if (startedAt == 0) revert StaleGoldPrice();            // round not started
        if (answeredInRound < roundId) revert StaleGoldPrice(); // stale round
        if (answer <= 0) revert StaleGoldPrice();               // invalid/negative price
        if (block.timestamp - updatedAt > maxStalenessSecs) revert StaleGoldPrice(); // heartbeat

        oraclePriceUsdc = (uint256(answer) * _pow10(usdcDecimals)) / _pow10(oracleDecimals);
    }

    /// @notice Non-reverting oracle read. Returns (price, true) when fresh and valid,
    ///         or (0, false) when stale/invalid. Used by recall() so redemptions never brick.
    function _getOraclePriceSafe() internal view returns (uint256 oraclePriceUsdc, bool ok) {
        try goldOracle.latestRoundData() returns (
            uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
        ) {
            if (startedAt == 0 || answeredInRound < roundId || answer <= 0) return (0, false);
            if (block.timestamp - updatedAt > maxStalenessSecs) return (0, false);
            oraclePriceUsdc = (uint256(answer) * _pow10(usdcDecimals)) / _pow10(oracleDecimals);
            ok = true;
        } catch {
            return (0, false);
        }
    }

    function _getPoolPrice(uint256 oraclePriceUsdc) internal view returns (uint256 poolPriceUsdc) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3PoolSlot0(pool).slot0();

        uint256 poolPriceRaw = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 192;

        poolPriceUsdc = (poolPriceRaw * _pow10(usdcDecimals)) / _pow10(xautDecimals);

        if (poolPriceUsdc == 0) {
            revert GoldPriceDeviation(poolPriceUsdc, oraclePriceUsdc, maxDeviationBps);
        }
    }

    function isPriceSane() public view returns (bool) {
        try this._checkPriceSanity() {
            return true;
        } catch {
            return false;
        }
    }

    function _checkPriceSanity() external view {
        uint256 oraclePrice = _getOraclePrice();
        uint256 poolPrice = _getPoolPrice(oraclePrice);
        uint256 diff = oraclePrice > poolPrice ? oraclePrice - poolPrice : poolPrice - oraclePrice;
        uint256 deviation = (diff * 10_000) / oraclePrice;
        if (deviation > maxDeviationBps) revert GoldPriceDeviation(poolPrice, oraclePrice, maxDeviationBps);
    }

    /// @notice Error emitted when a new deploy is attempted while the oracle is not sane.
    /// @dev    Deposits are blocked when price is stale/deviated; recalls remain open (G1).
    error OracleNotSane();

    function deploy(uint256 usdcAmount) external onlyVault returns (uint256 xautReceived) {
        if (usdcAmount == 0) revert ZeroAmount();
        // Block new gold buys when oracle is not sane (G1: deposits paused on insane price).
        if (!isPriceSane()) revert OracleNotSane();

        uint256 oraclePrice = _getOraclePrice();
        uint256 poolPrice = _getPoolPrice(oraclePrice);

        uint256 diff = oraclePrice > poolPrice ? oraclePrice - poolPrice : poolPrice - oraclePrice;
        if ((diff * 10_000) / oraclePrice > maxDeviationBps) {
            revert GoldPriceDeviation(poolPrice, oraclePrice, maxDeviationBps);
        }

        uint256 expectedXautOut = (usdcAmount * _pow10(xautDecimals)) / oraclePrice;
        uint256 minOut = (expectedXautOut * (10_000 - maxSlippageBps)) / 10_000;
        if (minOut == 0) minOut = 1;

        usdc.forceApprove(address(swapRouter), usdcAmount);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(usdc),
            tokenOut: address(xaut),
            fee: poolFee,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: usdcAmount,
            amountOutMinimum: minOut,
            sqrtPriceLimitX96: 0
        });

        xautReceived = swapRouter.exactInputSingle(params);

        if (xautReceived < minOut) revert SlippageExceeded(xautReceived, minOut);

        usdc.forceApprove(address(swapRouter), 0);

        xautHeld += xautReceived;
        totalDeployed += usdcAmount;

        emit GoldBought(usdcAmount, xautReceived, oraclePrice);
    }

    /// @notice Sell all held XAUT back to USDC and return proceeds to vault.
    /// @dev    MUST NOT revert due to oracle failure — stale oracle bricks redemptions
    ///         (G1 fix). When the oracle is unavailable, use `totalDeployed` as the
    ///         conservative floor price so the swap still executes. Deposits are blocked
    ///         separately via `deploy()` checking `isPriceSane()`.
    function recall(uint256 usdcAmount) external onlyVault returns (uint256 usdcReturned) {
        if (usdcAmount == 0) revert ZeroAmount();
        if (xautHeld == 0) return 0;

        // Use safe (non-reverting) oracle read. Fall back to totalDeployed-implied price
        // when oracle is stale so redemptions are never bricked.
        (uint256 oraclePrice, bool oracleOk) = _getOraclePriceSafe();

        uint256 xautToSell = xautHeld;
        uint256 minUsdcOut;

        if (oracleOk) {
            // Normal path: oracle fresh — apply deviation check and slippage floor.
            uint256 poolPrice = _getPoolPrice(oraclePrice);
            uint256 diff = oraclePrice > poolPrice ? oraclePrice - poolPrice : poolPrice - oraclePrice;
            if ((diff * 10_000) / oraclePrice > maxDeviationBps) {
                // Deviation too high — use conservative (lower) price as floor.
                uint256 conservativePrice = oraclePrice < poolPrice ? oraclePrice : poolPrice;
                uint256 expectedOut = (xautToSell * conservativePrice) / _pow10(xautDecimals);
                minUsdcOut = (expectedOut * (10_000 - maxSlippageBps)) / 10_000;
            } else {
                uint256 expectedOut = (xautToSell * oraclePrice) / _pow10(xautDecimals);
                minUsdcOut = (expectedOut * (10_000 - maxSlippageBps)) / 10_000;
            }
        } else {
            // Degraded path: oracle unavailable — use totalDeployed as conservative floor.
            // minUsdcOut = totalDeployed * (1 - maxSlippage) gives depositor a fair floor.
            minUsdcOut = (totalDeployed * (10_000 - maxSlippageBps)) / 10_000;
        }

        if (minUsdcOut == 0) minUsdcOut = 1;

        xaut.forceApprove(address(swapRouter), xautToSell);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(xaut),
            tokenOut: address(usdc),
            fee: poolFee,
            recipient: vault,
            deadline: block.timestamp,
            amountIn: xautToSell,
            amountOutMinimum: minUsdcOut,
            sqrtPriceLimitX96: 0
        });

        usdcReturned = swapRouter.exactInputSingle(params);

        if (usdcReturned < minUsdcOut) revert SlippageExceeded(usdcReturned, minUsdcOut);

        xaut.forceApprove(address(swapRouter), 0);

        xautHeld = 0;
        totalDeployed = 0;

        emit GoldSold(xautToSell, usdcReturned, oraclePrice);
    }

    function currentValue() external view returns (uint256) {
        if (!isPriceSane()) return totalDeployed;
        uint256 oraclePrice = _getOraclePrice();
        return (xautHeld * oraclePrice) / _pow10(xautDecimals);
    }

    function protocolName() external pure returns (string memory) {
        return "GoldAllocationAdapter: USDC/XAUT spot allocation (S6-H, yad bi yad, board-pending SR-008)";
    }

    function proposeParamChange(bytes32 paramId, uint256 newValue) external onlyOwner {
        if (paramId == PARAM_MAX_SLIPPAGE && newValue > MAX_SLIPPAGE_BPS) {
            revert ParamAboveHardCap("maxSlippageBps", newValue, MAX_SLIPPAGE_BPS);
        }

        if (paramId == PARAM_MAX_DEVIATION && newValue > MAX_DEVIATION_BPS) {
            revert ParamAboveHardCap("maxDeviationBps", newValue, MAX_DEVIATION_BPS);
        }

        if (paramId == PARAM_MAX_STALENESS && newValue == 0) {
            revert ParamAboveHardCap("maxStalenessSecs", newValue, 0);
        }

        if (paramId == PARAM_POOL_FEE && newValue > type(uint24).max) {
            revert ParamAboveHardCap("poolFee", newValue, type(uint24).max);
        }

        uint256 executeAfter = block.timestamp + TIMELOCK_DELAY;
        pendingChanges[paramId] = PendingChange({newValue: newValue, executeAfter: executeAfter, pending: true});

        emit ParamChangeProposed(paramId, newValue, executeAfter);
    }

    function executeParamChange(bytes32 paramId) external onlyOwner {
        PendingChange memory pc = pendingChanges[paramId];
        if (!pc.pending) revert NoProposalPending();
        if (block.timestamp < pc.executeAfter) revert TimelockNotElapsed(pc.executeAfter, block.timestamp);

        delete pendingChanges[paramId];

        if (paramId == PARAM_MAX_STALENESS) maxStalenessSecs = pc.newValue;
        else if (paramId == PARAM_MAX_SLIPPAGE) maxSlippageBps = pc.newValue;
        else if (paramId == PARAM_MAX_DEVIATION) maxDeviationBps = pc.newValue;
        else if (paramId == PARAM_POOL_FEE) poolFee = uint24(pc.newValue);

        emit ParamChangeExecuted(paramId, pc.newValue);
    }

    function proposeAddressParamChange(bytes32 paramId, address newValue) external onlyOwner {
        uint256 executeAfter = block.timestamp + TIMELOCK_DELAY;
        pendingAddressChanges[paramId] = PendingAddressChange({newValue: newValue, executeAfter: executeAfter, pending: true});

        emit ParamChangeProposed(paramId, uint256(uint160(newValue)), executeAfter);
    }

    function executeAddressParamChange(bytes32 paramId) external onlyOwner {
        PendingAddressChange memory pc = pendingAddressChanges[paramId];
        if (!pc.pending) revert NoProposalPending();
        if (block.timestamp < pc.executeAfter) revert TimelockNotElapsed(pc.executeAfter, block.timestamp);

        delete pendingAddressChanges[paramId];

        if (paramId == PARAM_SWAP_ROUTER) {
            swapRouter = ISwapRouter(pc.newValue);
        } else if (paramId == PARAM_GOLD_ORACLE) {
            goldOracle = AggregatorV3Interface(pc.newValue);
            // Update cached decimals atomically to avoid price mispricing with new oracle.
            oracleDecimals = AggregatorV3Interface(pc.newValue).decimals();
        }

        emit ParamChangeExecuted(paramId, uint256(uint160(pc.newValue)));
    }

    /// @dev Pool address setter — no timelock. Production: add timelock before mainnet.
    function setPool(address pool_) external onlyOwner {
        pool = pool_;
    }

    /// @dev renounceOwnership disabled — owner controls gold capital allocation.
    function renounceOwnership() public override(Ownable) onlyOwner {
        revert("GoldAllocationAdapter: renouncing ownership is disabled");
    }
}
