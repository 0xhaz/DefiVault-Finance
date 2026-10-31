// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {INonfungiblePositionManager} from "../adapters/HalalLPAdapter.sol";

/// @notice Single-position manager, factory and pool facade for HalalLPAdapter.
/// Uses V3 range liquidity math for both legs. Existing oracle/slippage controls
/// and recorded parameters remain available to regression tests.
contract MockPositionManager {
    using SafeERC20 for IERC20;

    address public immutable token0;
    address public immutable token1;
    uint256 public payoutBps = 10_000;
    uint160 public sqrtPriceX96 = uint160(1 << 96);
    int24 public spotTick;
    int24 public twapTick;
    bool public observeUnavailable;

    function setTicks(int24 spot, int24 twap) external {
        spotTick = spot;
        twapTick = twap;
        sqrtPriceX96 = _sqrtRatioAtTick(spot);
    }

    function setObserveUnavailable(bool unavailable) external {
        observeUnavailable = unavailable;
    }

    uint24 public posFee;
    int24 public posLower;
    int24 public posUpper;
    uint128 public posLiquidity;
    uint128 public owed0;
    uint128 public owed1;
    uint256 public nextId = 1;

    uint256 public mintCount;
    uint256 public lastMintAmount0Min;
    uint256 public lastMintAmount1Min;
    uint256 public lastMintAmount0Desired;
    uint256 public lastMintAmount1Desired;
    uint256 public decreaseCount;
    uint256 public lastDecAmount0Min;
    uint256 public lastDecAmount1Min;
    uint128 public lastDecLiquidity;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function setPayoutBps(uint256 bps) external {
        require(bps <= 10_000, "bps");
        payoutBps = bps;
    }

    function factory() external view returns (address) { return address(this); }
    function getPool(address, address, uint24) external view returns (address) { return address(this); }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, spotTick, 0, 0, 0, 0, true);
    }

    function observe(uint32[] calldata secondsAgos)
        external view returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        require(!observeUnavailable, "observations unavailable");
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
        for (uint256 i = 0; i < secondsAgos.length; i++) {
            tickCumulatives[i] = -int56(twapTick) * int56(uint56(secondsAgos[i]));
        }
    }

    function mint(INonfungiblePositionManager.MintParams calldata p)
        external returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        mintCount++;
        lastMintAmount0Min = p.amount0Min;
        lastMintAmount1Min = p.amount1Min;
        lastMintAmount0Desired = p.amount0Desired;
        lastMintAmount1Desired = p.amount1Desired;
        require(p.token0 == token0 && p.token1 == token1, "pair");
        uint160 lower = _sqrtRatioAtTick(p.tickLower);
        uint160 upper = _sqrtRatioAtTick(p.tickUpper);
        require(lower < upper, "range");
        uint256 nominal;
        if (sqrtPriceX96 <= lower) {
            nominal = _liquidity0(p.amount0Desired, lower, upper);
        } else if (sqrtPriceX96 >= upper) {
            nominal = Math.mulDiv(p.amount1Desired, 1 << 96, uint256(upper) - lower);
        } else {
            nominal = Math.min(
                _liquidity0(p.amount0Desired, sqrtPriceX96, upper),
                Math.mulDiv(p.amount1Desired, 1 << 96, uint256(sqrtPriceX96) - lower)
            );
        }
        nominal = Math.mulDiv(nominal, payoutBps, 10_000);
        require(nominal > 0 && nominal <= type(uint128).max, "liquidity");
        liquidity = uint128(nominal);
        (amount0, amount1) = _amounts(liquidity, lower, upper, true);
        require(amount0 <= p.amount0Desired && amount1 <= p.amount1Desired, "desired");
        require(amount0 >= p.amount0Min && amount1 >= p.amount1Min, "Price slippage check");
        if (amount0 != 0) IERC20(p.token0).safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 != 0) IERC20(p.token1).safeTransferFrom(msg.sender, address(this), amount1);
        tokenId = nextId++;
        posLiquidity += liquidity;
        posFee = p.fee;
        posLower = p.tickLower;
        posUpper = p.tickUpper;
    }

    function decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams calldata p)
        external returns (uint256 amount0, uint256 amount1)
    {
        decreaseCount++;
        lastDecAmount0Min = p.amount0Min;
        lastDecAmount1Min = p.amount1Min;
        lastDecLiquidity = p.liquidity;
        require(p.liquidity <= posLiquidity, "liquidity");
        (amount0, amount1) = _amounts(p.liquidity, _sqrtRatioAtTick(posLower), _sqrtRatioAtTick(posUpper), false);
        amount0 = Math.mulDiv(amount0, payoutBps, 10_000);
        amount1 = Math.mulDiv(amount1, payoutBps, 10_000);
        require(amount0 >= p.amount0Min && amount1 >= p.amount1Min, "Price slippage check");
        require(amount0 <= type(uint128).max && amount1 <= type(uint128).max, "owed");
        posLiquidity -= p.liquidity;
        owed0 += uint128(amount0);
        owed1 += uint128(amount1);
    }

    function collect(INonfungiblePositionManager.CollectParams calldata p)
        external returns (uint256 amount0, uint256 amount1)
    {
        amount0 = Math.min(owed0, p.amount0Max);
        amount1 = Math.min(owed1, p.amount1Max);
        owed0 -= uint128(amount0);
        owed1 -= uint128(amount1);
        if (amount0 != 0) IERC20(token0).safeTransfer(p.recipient, amount0);
        if (amount1 != 0) IERC20(token1).safeTransfer(p.recipient, amount1);
    }

    /// @notice Back fees by transferring tokens in, rather than inventing balances.
    function accrueFees(uint128 amount0, uint128 amount1) external {
        if (amount0 != 0) IERC20(token0).safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 != 0) IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1);
        owed0 += amount0;
        owed1 += amount1;
    }

    function positions(uint256) external view returns (
        uint96 nonce, address operator, address t0, address t1, uint24 fee,
        int24 tickLower, int24 tickUpper, uint128 liquidity,
        uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128,
        uint128 tokensOwed0, uint128 tokensOwed1
    ) {
        return (0, address(0), token0, token1, posFee, posLower, posUpper, posLiquidity, 0, 0, owed0, owed1);
    }

    function _liquidity0(uint256 amount, uint160 lower, uint160 upper) internal pure returns (uint256) {
        return Math.mulDiv(amount, Math.mulDiv(lower, upper, 1 << 96), uint256(upper) - lower);
    }

    function _amounts(uint128 liquidity, uint160 lower, uint160 upper, bool roundUp)
        internal view returns (uint256 amount0, uint256 amount1)
    {
        uint160 price = sqrtPriceX96;
        if (price < upper) {
            uint160 start = price > lower ? price : lower;
            uint256 numerator = uint256(liquidity) << 96;
            if (roundUp) {
                amount0 = Math.ceilDiv(Math.mulDiv(numerator, uint256(upper) - start, upper, Math.Rounding.Ceil), start);
            } else {
                amount0 = Math.mulDiv(numerator, uint256(upper) - start, upper) / start;
            }
        }
        if (price > lower) {
            uint160 end = price < upper ? price : upper;
            amount1 = Math.mulDiv(liquidity, uint256(end) - lower, 1 << 96,
                roundUp ? Math.Rounding.Ceil : Math.Rounding.Floor);
        }
    }

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
}
