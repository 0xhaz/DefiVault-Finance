// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStrategyAdapter} from "../IStrategyAdapter.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";

/// @dev Mandatory atomic cost-basis retirement after an adapter-side gold sale.
interface IGoldAllocationVaultAccounting {
    function retireGoldPrincipal(uint256 soldTokens, uint256 heldBefore) external;
}

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
    function token0() external view returns (address);
    function token1() external view returns (address);
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

contract GoldAllocationAdapter is IStrategyAdapter, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error AmountExceedsHeld(uint256 requested, uint256 held);
    error EmergencyExitDisabled();
    error EmergencyExitRequiresProposal();
    error EmergencyExitProposalExists();
    error NoEmergencyExitProposal();
    error EmergencyExitNotReady(uint256 executeAfter);
    error EmergencyExitExpired(uint256 expiresAt);

    uint256 public constant EMERGENCY_EXIT_DELAY = 1 hours;
    uint256 public constant EMERGENCY_EXIT_WINDOW = 24 hours;
    uint256 public constant EMERGENCY_FLOOR_BPS = 2000;

    struct PendingEmergencyExit {
        uint256 tokenAmount;
        uint256 minUsdcOut;
        uint256 executeAfter;
        uint256 expiresAt;
    }
    PendingEmergencyExit public pendingEmergencyExit;

    event EmergencyExitProposed(uint256 tokenAmount, uint256 minUsdcOut, uint256 executeAfter, uint256 expiresAt);
    event EmergencyExitCancelled();

    event EmergencyExit(address indexed caller, uint256 tokenSold, uint256 usdcReturned, uint256 minUsdcOut);

    /// @notice Explicit-minimum exits are disabled until a timelocked proposal executes.
    bool public emergencyExitEnabled;
    bytes32 public constant PARAM_EMERGENCY_EXIT_ENABLED = keccak256("emergencyExitEnabled");

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
    /// @notice Emitted whenever lastGoodPrice is refreshed from the oracle.
    event LastGoodPriceUpdated(uint256 price, uint256 timestamp);

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

    /// @notice Last oracle price successfully validated (USDC per XAUT, usdc-decimal scaled).
    ///         Updated on every successful deploy(), recall(), and pokePrice() call.
    ///         Used as the conservative floor when the oracle goes stale (PR1).
    uint256 public lastGoodPrice;

    /// @notice Oracle observation timestamp of the last validated price.
    uint256 public lastGoodPriceAt;

    /// @notice Haircut applied to lastGoodPrice when oracle is stale (bps, default 500 = 5%).
    ///         Board-settable via the standard propose/execute timelock.
    ///         Hard cap: MAX_STALE_HAIRCUT_BPS = 2000.
    uint256 public staleHaircutBps;
    uint256 public emergencySlippageBps = 1000;
    uint256 public constant MAX_EMERGENCY_SLIPPAGE_BPS = 2500;
    bytes32 public constant PARAM_EMERGENCY_SLIPPAGE = keccak256("emergencySlippageBps");
    event EmergencySlippageBpsUpdated(uint256 previous, uint256 updated);
    event ParamChangeCancelled(bytes32 indexed paramId);

    /// @notice Hard cap for the stale-price haircut.
    uint256 public constant MAX_STALE_HAIRCUT_BPS = 2000;

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

    bytes32 public constant PARAM_MAX_STALENESS   = keccak256("maxStalenessSecs");
    bytes32 public constant PARAM_MAX_SLIPPAGE    = keccak256("maxSlippageBps");
    bytes32 public constant PARAM_MAX_DEVIATION   = keccak256("maxDeviationBps");
    bytes32 public constant PARAM_POOL_FEE        = keccak256("poolFee");
    bytes32 public constant PARAM_SWAP_ROUTER     = keccak256("swapRouter");
    bytes32 public constant PARAM_GOLD_ORACLE     = keccak256("goldOracle");
    bytes32 public constant PARAM_STALE_HAIRCUT   = keccak256("staleHaircutBps");

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

        maxSlippageBps   = 50;
        maxDeviationBps  = 100;
        maxStalenessSecs = initialMaxStalenessSecs;
        staleHaircutBps  = 500; // 5% default haircut on stale-price valuation
    }

    modifier onlyVault() {
        require(msg.sender == vault, "GoldAllocationAdapter: caller is not vault");
        _;
    }

    function _pow10(uint8 d) internal pure returns (uint256) {
        return 10 ** uint256(d);
    }

    function _getOraclePrice() internal view returns (uint256 price, uint256 observedAt) {
        bool ok;
        (price, ok, observedAt) = _getOraclePriceSafe();
        if (!ok) revert StaleGoldPrice();
    }

    /// @notice Returns the validated price and observation timestamp, or ok=false.
    ///         Used by recall() so oracle failure does not block redemptions.
    function _getOraclePriceSafe() internal view returns (uint256 oraclePriceUsdc, bool ok, uint256 observedAt) {
        try goldOracle.latestRoundData() returns (
            uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
        ) {
            if (startedAt == 0 || answeredInRound < roundId || answer <= 0) return (0, false, 0);
            if (updatedAt == 0 || updatedAt > block.timestamp) return (0, false, 0);
            if (block.timestamp - updatedAt > maxStalenessSecs) return (0, false, 0);
            // Normalize without an overflowing intermediate; malformed scales are invalid observations.
            if (oracleDecimals >= usdcDecimals) {
                uint8 shift = oracleDecimals - usdcDecimals;
                if (shift > 77) return (0, false, 0);
                oraclePriceUsdc = uint256(answer) / _pow10(shift);
            } else {
                uint8 shift = usdcDecimals - oracleDecimals;
                if (shift > 77) return (0, false, 0);
                uint256 scale = _pow10(shift);
                if (uint256(answer) > type(uint256).max / scale) return (0, false, 0);
                oraclePriceUsdc = uint256(answer) * scale;
            }
            ok = oraclePriceUsdc > 0;
            observedAt = updatedAt;
        } catch {
            return (0, false, 0);
        }
    }

    /// @dev USDC base units per whole XAUT; zero means unreadable or unrepresentable.
    ///      The external boundary also catches arithmetic failures for NAV reads.
    function _readPoolPrice() internal view returns (uint256 price) {
        try this.poolPriceUsdc() returns (uint256 value) {
            return value;
        } catch {
            return 0;
        }
    }

    /// @dev Read-only boundary for catching malformed pool responses and math failures.
    function poolPriceUsdc() external view returns (uint256) {
        address token0 = IUniswapV3PoolSlot0(pool).token0();
        address token1 = IUniswapV3PoolSlot0(pool).token1();
        bool xautFirst = token0 == address(xaut) && token1 == address(usdc);
        bool usdcFirst = token0 == address(usdc) && token1 == address(xaut);
        if (!xautFirst && !usdcFirst) return 0;
        (uint160 sqrtP,,,,,,) = IUniswapV3PoolSlot0(pool).slot0();
        if (sqrtP == 0) return 0;
        uint256 scale = _pow10(xautDecimals);
        if (xautFirst) {
            return Math.mulDiv(Math.mulDiv(sqrtP, sqrtP, 1 << 64), scale, 1 << 128);
        }
        return Math.mulDiv(Math.mulDiv(scale, 1 << 96, sqrtP), 1 << 96, sqrtP);
    }

    function _getPoolPrice(uint256 oraclePriceUsdc) internal view returns (uint256 poolPriceUsdc_) {
        poolPriceUsdc_ = _readPoolPrice();
        if (poolPriceUsdc_ == 0) {
            revert GoldPriceDeviation(poolPriceUsdc_, oraclePriceUsdc, maxDeviationBps);
        }
    }

    /// @dev Called after every successful oracle read to cache the last known good price.
    function _updateLastGoodPrice(uint256 price, uint256 observedAt) internal {
        lastGoodPrice   = price;
        lastGoodPriceAt = observedAt;
        emit LastGoodPriceUpdated(price, observedAt);
    }

    /// @notice Refresh the cache only from a fresh, complete oracle observation.
    function pokePrice() external {
        (uint256 oraclePrice, bool ok, uint256 observedAt) = _getOraclePriceSafe();
        if (!ok) return;
        _updateLastGoodPrice(oraclePrice, observedAt);
    }

    function isPriceSane() public view returns (bool) {
        try this._checkPriceSanity() {
            return true;
        } catch {
            return false;
        }
    }

    function _checkPriceSanity() external view {
        (uint256 oraclePrice,) = _getOraclePrice();
        uint256 poolPrice = _getPoolPrice(oraclePrice);
        uint256 diff = oraclePrice > poolPrice ? oraclePrice - poolPrice : poolPrice - oraclePrice;
        uint256 deviation = (diff * 10_000) / oraclePrice;
        if (deviation > maxDeviationBps) revert GoldPriceDeviation(poolPrice, oraclePrice, maxDeviationBps);
    }

    /// @notice Error emitted when a new deploy is attempted while the oracle is not sane.
    /// @dev    Deposits are blocked when price is stale/deviated; recalls remain open (G1).
    error OracleNotSane();

    function deploy(uint256 usdcAmount) external onlyVault nonReentrant returns (uint256 xautReceived) {
        if (usdcAmount == 0) revert ZeroAmount();
        // Block new gold buys when oracle is not sane (G1: deposits paused on insane price).
        if (!isPriceSane()) revert OracleNotSane();

        (uint256 oraclePrice, uint256 observedAt) = _getOraclePrice();
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

        _updateLastGoodPrice(oraclePrice, observedAt);
        emit GoldBought(usdcAmount, xautReceived, oraclePrice);
    }

    /// @notice Sell all held XAUT back to USDC and return proceeds to vault.
    /// @dev Fresh oracle floors never depend on spot pool state. During outages,
    ///      cached price, stale haircut and emergency slippage bound the exit.
    function recall(uint256 usdcAmount) external onlyVault nonReentrant returns (uint256 usdcReturned) {
        if (usdcAmount == 0) revert ZeroAmount();
        if (xautHeld == 0) return 0;

        (uint256 oraclePrice, bool oracleOk, uint256 observedAt) = _getOraclePriceSafe();

        uint256 xautToSell = xautHeld;
        uint256 minUsdcOut;

        if (oracleOk) {
            _updateLastGoodPrice(oraclePrice, observedAt);
            uint256 expectedOut = Math.mulDiv(xautToSell, oraclePrice, _pow10(xautDecimals));
            minUsdcOut = Math.mulDiv(expectedOut, 10_000 - maxSlippageBps, 10_000);
        } else {
            if (lastGoodPrice == 0) revert StaleGoldPrice();
            uint256 expectedOut = Math.mulDiv(xautToSell, lastGoodPrice, _pow10(xautDecimals));
            uint256 haircutValue = Math.mulDiv(expectedOut, 10_000 - staleHaircutBps, 10_000);
            minUsdcOut = Math.mulDiv(haircutValue, 10_000 - emergencySlippageBps, 10_000);
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

    /// @dev Retained ABI, but the one-call emergency sale is permanently disabled.
    function emergencyExit(uint256, uint256) external onlyOwner returns (uint256) {
        revert EmergencyExitRequiresProposal();
    }

    /// @notice Authorize one exact sale after one hour, valid for the following 24 hours.
    function proposeEmergencyExit(uint256 tokenAmount, uint256 minUsdcOut) external onlyOwner {
        if (!emergencyExitEnabled) revert EmergencyExitDisabled();
        if (pendingEmergencyExit.tokenAmount != 0) revert EmergencyExitProposalExists();
        if (tokenAmount == 0 || minUsdcOut == 0) revert ZeroAmount();
        if (tokenAmount > xautHeld) revert AmountExceedsHeld(tokenAmount, xautHeld);
        if (lastGoodPrice == 0) revert StaleGoldPrice();
        uint256 cachedValue = Math.mulDiv(tokenAmount, lastGoodPrice, _pow10(xautDecimals));
        uint256 floor = Math.mulDiv(cachedValue, EMERGENCY_FLOOR_BPS, 10_000, Math.Rounding.Ceil);
        if (minUsdcOut < floor) revert SlippageExceeded(minUsdcOut, floor);
        uint256 executeAfter = block.timestamp + EMERGENCY_EXIT_DELAY;
        uint256 expiresAt = executeAfter + EMERGENCY_EXIT_WINDOW;
        pendingEmergencyExit = PendingEmergencyExit(tokenAmount, minUsdcOut, executeAfter, expiresAt);
        emit EmergencyExitProposed(tokenAmount, minUsdcOut, executeAfter, expiresAt);
    }

    function cancelEmergencyExit() external onlyOwner {
        if (pendingEmergencyExit.tokenAmount == 0) revert NoEmergencyExitProposal();
        delete pendingEmergencyExit;
        emit EmergencyExitCancelled();
    }

    function executeEmergencyExit() external onlyOwner nonReentrant returns (uint256 usdcReturned) {
        if (!emergencyExitEnabled) revert EmergencyExitDisabled();
        PendingEmergencyExit memory p = pendingEmergencyExit;
        if (p.tokenAmount == 0) revert NoEmergencyExitProposal();
        if (block.timestamp < p.executeAfter) revert EmergencyExitNotReady(p.executeAfter);
        if (block.timestamp > p.expiresAt) revert EmergencyExitExpired(p.expiresAt);
        uint256 tokenAmount = p.tokenAmount;
        uint256 minUsdcOut = p.minUsdcOut;
        uint256 heldBefore = xautHeld;
        if (tokenAmount > heldBefore) revert AmountExceedsHeld(tokenAmount, heldBefore);
        delete pendingEmergencyExit;

        // Snapshot oracle health before execution; outage exits must not refresh the cache.
        (uint256 oraclePrice, bool oracleOk,) = _getOraclePriceSafe();
        xautHeld = heldBefore - tokenAmount;
        totalDeployed = tokenAmount == heldBefore
            ? 0
            : totalDeployed - Math.mulDiv(totalDeployed, tokenAmount, heldBefore);

        xaut.forceApprove(address(swapRouter), 0);
        xaut.forceApprove(address(swapRouter), tokenAmount);
        usdcReturned = swapRouter.exactInputSingle(ISwapRouter.ExactInputSingleParams({
            tokenIn: address(xaut),
            tokenOut: address(usdc),
            fee: poolFee,
            recipient: vault,
            deadline: block.timestamp,
            amountIn: tokenAmount,
            amountOutMinimum: minUsdcOut,
            sqrtPriceLimitX96: 0
        }));
        if (usdcReturned < minUsdcOut) revert SlippageExceeded(usdcReturned, minUsdcOut);
        xaut.forceApprove(address(swapRouter), 0);

        // Validate the realized observation against the fresh oracle, not distressed pool spot.
        // An exit outside the ordinary deviation bound succeeds without refreshing the cache.
        if (oracleOk) {
            uint256 exitPrice = Math.mulDiv(usdcReturned, _pow10(xautDecimals), tokenAmount);
            uint256 diff = exitPrice > oraclePrice ? exitPrice - oraclePrice : oraclePrice - exitPrice;
            if (exitPrice > 0 && diff <= Math.mulDiv(oraclePrice, maxDeviationBps, 10_000)) {
                _updateLastGoodPrice(exitPrice, block.timestamp);
            }
        }

        // Mandatory: failure rolls back the swap, approvals, accounting and proposal deletion.
        IGoldAllocationVaultAccounting(vault).retireGoldPrincipal(tokenAmount, heldBefore);
        emit EmergencyExit(msg.sender, tokenAmount, usdcReturned, minUsdcOut);
    }

    /// @notice Oracle-only position value; stale/invalid observations use the cached price with haircut.
    /// @dev Pool spot is reserved for execution sanity, never NAV. Read/math failures return zero.
    function currentValue() external view returns (uint256) {
        try this.positionValueUsdc() returns (uint256 value) {
            return value;
        } catch {
            return 0;
        }
    }

    /// @dev Read-only boundary so malformed observations and unrepresentable values cannot revert NAV reads.
    function positionValueUsdc() external view returns (uint256) {
        if (xautHeld == 0) return 0;
        (uint256 oraclePrice, bool oracleOk,) = _getOraclePriceSafe();
        if (oracleOk) return Math.mulDiv(xautHeld, oraclePrice, _pow10(xautDecimals));
        if (lastGoodPrice == 0) return 0;
        uint256 grossValue = Math.mulDiv(xautHeld, lastGoodPrice, _pow10(xautDecimals));
        return Math.mulDiv(grossValue, 10_000 - staleHaircutBps, 10_000);
    }

    function isGoldStrategy() external pure returns (bool) {
        return true;
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

        if (paramId == PARAM_STALE_HAIRCUT && newValue > MAX_STALE_HAIRCUT_BPS) {
            revert ParamAboveHardCap("staleHaircutBps", newValue, MAX_STALE_HAIRCUT_BPS);
        }

        if (paramId == PARAM_EMERGENCY_SLIPPAGE && newValue > MAX_EMERGENCY_SLIPPAGE_BPS) {
            revert ParamAboveHardCap("emergencySlippageBps", newValue, MAX_EMERGENCY_SLIPPAGE_BPS);
        }

        if (paramId == PARAM_EMERGENCY_EXIT_ENABLED && newValue > 1) {
            revert ParamAboveHardCap("emergencyExitEnabled", newValue, 1);
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
        else if (paramId == PARAM_STALE_HAIRCUT) staleHaircutBps = pc.newValue;
        else if (paramId == PARAM_EMERGENCY_EXIT_ENABLED) emergencyExitEnabled = pc.newValue == 1;
        else if (paramId == PARAM_EMERGENCY_SLIPPAGE) {
            uint256 previous = emergencySlippageBps;
            emergencySlippageBps = pc.newValue;
            emit EmergencySlippageBpsUpdated(previous, pc.newValue);
        }

        emit ParamChangeExecuted(paramId, pc.newValue);
    }

    function cancelParamChange(bytes32 paramId) external onlyOwner {
        if (!pendingChanges[paramId].pending) revert NoProposalPending();
        delete pendingChanges[paramId];
        emit ParamChangeCancelled(paramId);
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

    event PoolProposed(address indexed proposed, uint256 executeAfter);
    event PoolExecuted(address indexed previous, address indexed updated);
    event PoolProposalCancelled();

    PendingAddressChange public pendingPool;

    /// @dev Retained ABI: this setter now proposes rather than immediately updating.
    function setPool(address pool_) external onlyOwner {
        _proposePool(pool_);
    }

    function proposePool(address pool_) external onlyOwner {
        _proposePool(pool_);
    }

    function _proposePool(address pool_) internal {
        uint256 executeAfter = block.timestamp + TIMELOCK_DELAY;
        pendingPool = PendingAddressChange({newValue: pool_, executeAfter: executeAfter, pending: true});
        emit PoolProposed(pool_, executeAfter);
    }

    function executePool() external onlyOwner {
        PendingAddressChange memory pc = pendingPool;
        if (!pc.pending) revert NoProposalPending();
        if (block.timestamp < pc.executeAfter) revert TimelockNotElapsed(pc.executeAfter, block.timestamp);
        delete pendingPool;
        address previous = pool;
        pool = pc.newValue;
        emit PoolExecuted(previous, pc.newValue);
    }

    function cancelPool() external onlyOwner {
        if (!pendingPool.pending) revert NoProposalPending();
        delete pendingPool;
        emit PoolProposalCancelled();
    }

    /// @dev renounceOwnership disabled — owner controls gold capital allocation.
    function renounceOwnership() public override(Ownable) onlyOwner {
        revert("GoldAllocationAdapter: renouncing ownership is disabled");
    }
}
