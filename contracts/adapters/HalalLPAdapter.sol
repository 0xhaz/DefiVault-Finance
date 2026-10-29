// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IStrategyAdapter} from "../IStrategyAdapter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IPositionFactory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IPositionPool {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
    function observe(uint32[] calldata secondsAgos)
        external view returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function factory() external view returns (address);

    function mint(MintParams calldata params)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function collect(CollectParams calldata params) external returns (uint256 amount0, uint256 amount1);

    function decreaseLiquidity(DecreaseLiquidityParams calldata params) external returns (uint256 amount0, uint256 amount1);

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}

contract HalalLPAdapter is IStrategyAdapter, Ownable2Step {
    using SafeERC20 for IERC20;

    error OnlyVault();
    error NoActivePosition();
    error PositionAlreadyOpen();
    error SpotTwapDeviation(int24 spotTick, int24 twapTick);
    error TwapUnavailable();
    error TwapWindowBelowMinimum(uint32 proposed, uint32 minimum);
    error TwapDeviationAboveCap(uint24 proposed, uint24 cap);
    error SlippageAboveCap(uint256 proposed, uint256 cap);
    error TimelockNotElapsed(uint256 executeAfter, uint256 now_);
    error NoProposalPending();

    uint256 public constant MAX_SLIPPAGE_BPS = 500;
    uint256 public constant TIMELOCK_DELAY = 30 days;
    uint256 public maxSlippageBps = 100;
    uint256 public pendingSlippageBps;
    uint256 public slippageExecuteAfter;
    bool public slippageProposalPending;

    uint32 public constant MIN_TWAP_WINDOW = 300;
    uint24 public constant MAX_TWAP_DEVIATION_TICKS = 500;
    uint32 public twapWindow = 1800;
    uint24 public maxTwapDeviationTicks = 100;
    uint32 public pendingTwapWindow;
    uint256 public twapWindowExecuteAfter;
    bool public twapWindowProposalPending;
    uint24 public pendingMaxTwapDeviationTicks;
    uint256 public twapDeviationExecuteAfter;
    bool public twapDeviationProposalPending;

    event TwapWindowProposed(uint32 newWindow, uint256 executeAfter);
    event TwapWindowExecuted(uint32 newWindow);
    event TwapWindowProposalCancelled();
    event TwapDeviationProposed(uint24 newTicks, uint256 executeAfter);
    event TwapDeviationExecuted(uint24 newTicks);
    event TwapDeviationProposalCancelled();

    event SlippageProposed(uint256 newBps, uint256 executeAfter);
    event SlippageExecuted(uint256 newBps);
    event SlippageProposalCancelled();

    event Deployed(uint256 amount);
    event Recalled(uint256 amount);
    event TickRangeUpdated(int24 lower, int24 upper);

    address public immutable positionManager;
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable poolFee;
    address public immutable usdc;
    address public immutable override vault;

    uint256 public positionTokenId;
    uint256 public totalDeployed;
    int24 public tickLower;
    int24 public tickUpper;

    constructor(
        address positionManager_,
        address token0_,
        address token1_,
        uint24 poolFee_,
        address usdc_,
        address vault_,
        address owner_
    ) Ownable(owner_) {
        positionManager = positionManager_;
        token0 = token0_;
        token1 = token1_;
        poolFee = poolFee_;
        usdc = usdc_;
        vault = vault_;

        tickLower = -887220;
        tickUpper = 887220;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    function deploy(uint256 amount) external onlyVault returns (uint256 deployed) {
        if (positionTokenId != 0) revert PositionAlreadyOpen();
        address factory = INonfungiblePositionManager(positionManager).factory();
        _checkedTwapPrice(IPositionFactory(factory).getPool(token0, token1, poolFee));
        IERC20(usdc).forceApprove(positionManager, amount);

        INonfungiblePositionManager.MintParams memory params;
        params.token0 = token0;
        params.token1 = token1;
        params.fee = poolFee;
        params.tickLower = tickLower;
        params.tickUpper = tickUpper;
        params.amount0Desired = usdc == token0 ? amount : 0;
        params.amount1Desired = usdc == token1 ? amount : 0;
        params.amount0Min = _minimumAmount(params.amount0Desired);
        params.amount1Min = _minimumAmount(params.amount1Desired);
        params.recipient = address(this);
        params.deadline = block.timestamp + 300;

        (uint256 tokenId,,,) = INonfungiblePositionManager(positionManager).mint(params);
        positionTokenId = tokenId;

        IERC20(usdc).forceApprove(positionManager, 0);

        totalDeployed += amount;
        emit Deployed(amount);
        return amount;
    }

    function recall(uint256 amount) external onlyVault returns (uint256 returned) {
        uint256 tokenId = positionTokenId;
        if (tokenId == 0) {
            return 0;
        }

        (,,,,,,, uint128 liquidity,,,,) = INonfungiblePositionManager(positionManager).positions(tokenId);

        uint128 liquidityToBurn;
        if (totalDeployed > 0) {
            liquidityToBurn = uint128((uint256(liquidity) * amount) / totalDeployed);
        } else {
            liquidityToBurn = liquidity;
        }

        if (liquidityToBurn > liquidity) {
            liquidityToBurn = liquidity;
        }

        (uint256 expected0, uint256 expected1) = _expectedAmounts(tokenId, liquidityToBurn);
        INonfungiblePositionManager(positionManager).decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidityToBurn,
                amount0Min: _minimumAmount(expected0),
                amount1Min: _minimumAmount(expected1),
                deadline: block.timestamp + 300
            })
        );

        (uint256 amount0, uint256 amount1) = INonfungiblePositionManager(positionManager).collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: vault,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        if (amount >= totalDeployed) {
            totalDeployed = 0;
        } else {
            totalDeployed -= amount;
        }

        uint256 received = usdc == token0 ? amount0 : amount1;
        emit Recalled(amount);
        return received;
    }

    function currentValue() public view returns (uint256) {
        if (positionTokenId == 0) {
            return 0;
        }

        (,,,,,,,,,, uint128 tokensOwed0, uint128 tokensOwed1) =
            INonfungiblePositionManager(positionManager).positions(positionTokenId);

        uint256 usdcOwed = usdc == token0 ? uint256(tokensOwed0) : uint256(tokensOwed1);
        return usdcOwed + totalDeployed;
    }

    function protocolName() external pure returns (string memory) {
        return "Uniswap V3 Halal LP";
    }

    function proposeMaxSlippageBps(uint256 newBps) external onlyOwner {
        if (newBps > MAX_SLIPPAGE_BPS) revert SlippageAboveCap(newBps, MAX_SLIPPAGE_BPS);
        pendingSlippageBps = newBps;
        slippageExecuteAfter = block.timestamp + TIMELOCK_DELAY;
        slippageProposalPending = true;
        emit SlippageProposed(newBps, slippageExecuteAfter);
    }

    function executeMaxSlippageBps() external onlyOwner {
        if (!slippageProposalPending) revert NoProposalPending();
        if (block.timestamp < slippageExecuteAfter) {
            revert TimelockNotElapsed(slippageExecuteAfter, block.timestamp);
        }
        maxSlippageBps = pendingSlippageBps;
        delete pendingSlippageBps;
        delete slippageExecuteAfter;
        delete slippageProposalPending;
        emit SlippageExecuted(maxSlippageBps);
    }

    function cancelMaxSlippageBps() external onlyOwner {
        if (!slippageProposalPending) revert NoProposalPending();
        delete pendingSlippageBps;
        delete slippageExecuteAfter;
        delete slippageProposalPending;
        emit SlippageProposalCancelled();
    }

    function proposeTwapWindow(uint32 newWindow) external onlyOwner {
        if (newWindow < MIN_TWAP_WINDOW) revert TwapWindowBelowMinimum(newWindow, MIN_TWAP_WINDOW);
        pendingTwapWindow = newWindow;
        twapWindowExecuteAfter = block.timestamp + TIMELOCK_DELAY;
        twapWindowProposalPending = true;
        emit TwapWindowProposed(newWindow, twapWindowExecuteAfter);
    }

    function executeTwapWindow() external onlyOwner {
        if (!twapWindowProposalPending) revert NoProposalPending();
        if (block.timestamp < twapWindowExecuteAfter) {
            revert TimelockNotElapsed(twapWindowExecuteAfter, block.timestamp);
        }
        twapWindow = pendingTwapWindow;
        delete pendingTwapWindow;
        delete twapWindowExecuteAfter;
        delete twapWindowProposalPending;
        emit TwapWindowExecuted(twapWindow);
    }

    function cancelTwapWindow() external onlyOwner {
        if (!twapWindowProposalPending) revert NoProposalPending();
        delete pendingTwapWindow;
        delete twapWindowExecuteAfter;
        delete twapWindowProposalPending;
        emit TwapWindowProposalCancelled();
    }

    function proposeMaxTwapDeviationTicks(uint24 newTicks) external onlyOwner {
        if (newTicks > MAX_TWAP_DEVIATION_TICKS) {
            revert TwapDeviationAboveCap(newTicks, MAX_TWAP_DEVIATION_TICKS);
        }
        pendingMaxTwapDeviationTicks = newTicks;
        twapDeviationExecuteAfter = block.timestamp + TIMELOCK_DELAY;
        twapDeviationProposalPending = true;
        emit TwapDeviationProposed(newTicks, twapDeviationExecuteAfter);
    }

    function executeMaxTwapDeviationTicks() external onlyOwner {
        if (!twapDeviationProposalPending) revert NoProposalPending();
        if (block.timestamp < twapDeviationExecuteAfter) {
            revert TimelockNotElapsed(twapDeviationExecuteAfter, block.timestamp);
        }
        maxTwapDeviationTicks = pendingMaxTwapDeviationTicks;
        delete pendingMaxTwapDeviationTicks;
        delete twapDeviationExecuteAfter;
        delete twapDeviationProposalPending;
        emit TwapDeviationExecuted(maxTwapDeviationTicks);
    }

    function cancelMaxTwapDeviationTicks() external onlyOwner {
        if (!twapDeviationProposalPending) revert NoProposalPending();
        delete pendingMaxTwapDeviationTicks;
        delete twapDeviationExecuteAfter;
        delete twapDeviationProposalPending;
        emit TwapDeviationProposalCancelled();
    }

    function _checkedTwapPrice(address pool) internal view returns (uint160) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;
        int56 delta;
        try IPositionPool(pool).observe(secondsAgos) returns (int56[] memory ticks, uint160[] memory) {
            if (ticks.length != 2) revert TwapUnavailable();
            // Cumulative ticks intentionally wrap at int56, as in the pool oracle.
            unchecked { delta = ticks[1] - ticks[0]; }
        } catch {
            revert TwapUnavailable();
        }
        int56 window = int56(uint56(twapWindow));
        int56 mean = delta / window;
        // Solidity rounds toward zero; arithmetic-mean ticks round toward negative infinity.
        if (delta < 0 && delta % window != 0) mean--;
        if (mean < -887272 || mean > 887272) revert TwapUnavailable();
        int24 averageTick = int24(mean);
        (, int24 spot,,,,,) = IPositionPool(pool).slot0();
        int256 deviation = int256(spot) - int256(averageTick);
        if (deviation < 0) deviation = -deviation;
        if (uint256(deviation) > maxTwapDeviationTicks) revert SpotTwapDeviation(spot, averageTick);
        return _sqrtRatioAtTick(averageTick);
    }

    function _minimumAmount(uint256 expected) internal view returns (uint256) {
        uint256 minimum = Math.mulDiv(expected, 10_000 - maxSlippageBps, 10_000);
        return expected > 0 && minimum == 0 ? 1 : minimum;
    }

    /// @dev Compute raw token amounts from pool price and the position's own ticks.
    function _expectedAmounts(uint256 tokenId, uint128 liquidity)
        internal view returns (uint256 amount0, uint256 amount1)
    {
        (,, address position0, address position1, uint24 fee, int24 lower, int24 upper,,,,,) =
            INonfungiblePositionManager(positionManager).positions(tokenId);
        address factory = INonfungiblePositionManager(positionManager).factory();
        address pool = IPositionFactory(factory).getPool(position0, position1, fee);
        uint160 price = _checkedTwapPrice(pool);
        uint160 sqrtLower = _sqrtRatioAtTick(lower);
        uint160 sqrtUpper = _sqrtRatioAtTick(upper);
        if (price <= sqrtLower) {
            amount0 = _amount0(liquidity, sqrtLower, sqrtUpper);
        } else if (price < sqrtUpper) {
            amount0 = _amount0(liquidity, price, sqrtUpper);
            amount1 = Math.mulDiv(liquidity, uint256(price) - sqrtLower, 1 << 96);
        } else {
            amount1 = Math.mulDiv(liquidity, uint256(sqrtUpper) - sqrtLower, 1 << 96);
        }
    }

    function _amount0(uint128 liquidity, uint160 lower, uint160 upper) internal pure returns (uint256) {
        return Math.mulDiv(uint256(liquidity) << 96, uint256(upper) - lower, upper) / lower;
    }

    /// @dev TickMath Q128.128 factors and Q64.96 round-up, matching the pool's tick pricing.
    function _sqrtRatioAtTick(int24 tick) internal pure returns (uint160) {
        uint256 exponent = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        require(exponent <= 887272, "tick out of range");
        uint256 ratio = exponent & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 1 << 128;
        if (exponent & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (exponent & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (exponent & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (exponent & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (exponent & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (exponent & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (exponent & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (exponent & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (exponent & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (exponent & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (exponent & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (exponent & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (exponent & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (exponent & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (exponent & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (exponent & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (exponent & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (exponent & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (exponent & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;
        if (tick > 0) ratio = type(uint256).max / ratio;
        return uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }

    function setTickRange(int24 lower, int24 upper) external onlyOwner {
        tickLower = lower;
        tickUpper = upper;
        emit TickRangeUpdated(lower, upper);
    }
}
