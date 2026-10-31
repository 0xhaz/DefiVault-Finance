// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHalalSwapRouter} from "../adapters/HalalLPAdapter.sol";

/// @notice Fund both tokens at this address before swapping. Rates are RAW token
/// units (token1/token0), not human-readable amounts adjusted for decimals.
contract MockSwapRouter is IHalalSwapRouter {
    using SafeERC20 for IERC20;

    address public immutable token0;
    address public immutable token1;
    uint256 public rateNumerator = 1;
    uint256 public rateDenominator = 1;
    uint160 public sqrtPriceX96;
    uint256 public payoutBps = 10_000;
    uint256 public swapCount;
    address public lastTokenIn;
    address public lastTokenOut;
    uint256 public lastAmountIn;
    uint256 public lastAmountOutMinimum;

    constructor(address token0_, address token1_) {
        require(token0_ != token1_, "pair");
        token0 = token0_;
        token1 = token1_;
    }

    function setRate(uint256 numerator, uint256 denominator) external {
        require(numerator != 0 && denominator != 0, "rate");
        rateNumerator = numerator;
        rateDenominator = denominator;
        sqrtPriceX96 = 0;
    }

    function setPrice(uint160 price) external {
        require(price != 0, "price");
        sqrtPriceX96 = price;
    }

    function setPayoutBps(uint256 bps) external {
        require(bps <= 10_000, "bps");
        payoutBps = bps;
    }

    function exactInputSingle(ExactInputSingleParams calldata p)
        external payable returns (uint256 amountOut)
    {
        bool zeroForOne = p.tokenIn == token0 && p.tokenOut == token1;
        require(zeroForOne || (p.tokenIn == token1 && p.tokenOut == token0), "pair");
        if (sqrtPriceX96 == 0) {
            amountOut = zeroForOne ? Math.mulDiv(p.amountIn, rateNumerator, rateDenominator)
                : Math.mulDiv(p.amountIn, rateDenominator, rateNumerator);
        } else if (sqrtPriceX96 <= type(uint128).max) {
            uint256 ratio = uint256(sqrtPriceX96) * sqrtPriceX96;
            amountOut = zeroForOne ? Math.mulDiv(p.amountIn, ratio, 1 << 192)
                : Math.mulDiv(p.amountIn, 1 << 192, ratio);
        } else {
            uint256 ratio = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
            amountOut = zeroForOne ? Math.mulDiv(p.amountIn, ratio, 1 << 128)
                : Math.mulDiv(p.amountIn, 1 << 128, ratio);
        }
        amountOut = Math.mulDiv(amountOut, payoutBps, 10_000);
        require(amountOut >= p.amountOutMinimum, "Too little received");
        swapCount++;
        lastTokenIn = p.tokenIn;
        lastTokenOut = p.tokenOut;
        lastAmountIn = p.amountIn;
        lastAmountOutMinimum = p.amountOutMinimum;
        IERC20(p.tokenIn).safeTransferFrom(msg.sender, address(this), p.amountIn);
        IERC20(p.tokenOut).safeTransfer(p.recipient, amountOut);
    }
}
