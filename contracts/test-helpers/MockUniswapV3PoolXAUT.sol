// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Stripped Uniswap V3-compatible mock for USDC/XAUT testing on Arc Testnet.
/// @dev    Satisfies three call surfaces the GoldAllocationAdapter needs:
///           1. slot0() — returns a settable sqrtPriceX96 (pool price for deviation check)
///           2. ISwapRouter.exactInputSingle() — executes at the configured ratio
///           3. ISwapRouter-compatible interface (reuses ISwapRouter struct)
///
///         Price model: 1 XAUT = oracleUsdcPerXaut USDC (6-dec units).
///         sqrtPriceX96 is kept consistent with the price for the deviation check.
///
///         NOT a real Uniswap V3 pool. Arc Testnet only.
///
/// @dev    sqrtPriceX96 encodes the raw token1/token0 ratio, not the whole-token quote.
///         Default ordering is XAUT/USDC; setTokenOrder(false) reverses it.
contract MockUniswapV3PoolXAUT {
    using SafeERC20 for IERC20;

    // ---- ISwapRouter.ExactInputSingleParams (inline to avoid import cycle) ----
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    // ---- Slot0 return (minimal) ----
    struct Slot0Data {
        uint160 sqrtPriceX96;
        int24   tick;
        uint16  observationIndex;
        uint16  observationCardinality;
        uint16  observationCardinalityNext;
        uint8   feeProtocol;
        bool    unlocked;
    }

    error DeadlinePassed();
    error InsufficientOutput(uint256 got, uint256 minimum);
    error ZeroAmountIn();

    event Swapped(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);
    event PriceUpdated(uint160 sqrtPriceX96, uint256 usdcPerXaut);

    IERC20  public immutable usdc;
    IERC20  public immutable xaut;
    address public token0;
    address public token1;
    uint256 public immutable xautScale;

    /// @notice Pool price in USDC-per-XAUT, both in their native decimals (e.g. 3_300_000_000 = $3300 at 6 dec each).
    uint256 public usdcPerXaut;

    /// @notice sqrtPriceX96 consistent with usdcPerXaut. Stored as uint160.
    uint160 public sqrtPriceX96;

    /// @notice Slippage applied to swaps: output = input * ratio / 10_000 (default 9980 = 0.2% fee sim).
    uint256 public swapFeeBps;

    constructor(address usdc_, address xaut_, uint256 initialUsdcPerXaut) {
        usdc         = IERC20(usdc_);
        xaut         = IERC20(xaut_);
        token0       = xaut_;
        token1       = usdc_;
        xautScale    = 10 ** uint256(IERC20Metadata(xaut_).decimals());
        usdcPerXaut  = initialUsdcPerXaut;
        swapFeeBps   = 9980; // simulate 0.2% pool fee
        _updateSqrtPrice(initialUsdcPerXaut);
    }

    // ─────────────────────────────────────────────────────────────
    //  IUniswapV3Pool.slot0() surface
    // ─────────────────────────────────────────────────────────────

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96_,
            int24   tick,
            uint16  observationIndex,
            uint16  observationCardinality,
            uint16  observationCardinalityNext,
            uint8   feeProtocol,
            bool    unlocked
        )
    {
        return (sqrtPriceX96, 0, 0, 1, 1, 0, true);
    }

    // ─────────────────────────────────────────────────────────────
    //  ISwapRouter.exactInputSingle() surface
    // ─────────────────────────────────────────────────────────────

    /// @notice Executes a single-hop swap using USDC base units per whole XAUT.
    ///         Token amounts are normalized by xautScale, then discounted by swapFeeBps.
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut)
    {
        if (block.timestamp > params.deadline) revert DeadlinePassed();
        if (params.amountIn == 0) revert ZeroAmountIn();

        // Pull tokenIn from caller.
        // NOTE: if tokenIn is the Arc Testnet USDC predeploy, safeTransferFrom triggers a
        // delegatecall proxy that can overflow the stack when called from a Foundry script.
        // In tests this is fine (no delegatecall depth). In production the vault pre-approves
        // via forceApprove so the standard transferFrom path is safe at runtime.
        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);

        bool usdcToXaut = params.tokenIn == address(usdc);

        if (usdcToXaut) {
            // Normalize the whole-token quote to XAUT base units, preserving fixture swap outputs.
            amountOut = Math.mulDiv(params.amountIn, xautScale * swapFeeBps, usdcPerXaut * 10_000);
        } else {
            // XAUT in → USDC out: normalize XAUT base units by xautScale.
            amountOut = Math.mulDiv(params.amountIn, usdcPerXaut * swapFeeBps, xautScale * 10_000);
        }

        if (amountOut < params.amountOutMinimum) revert InsufficientOutput(amountOut, params.amountOutMinimum);

        // Send tokenOut to recipient
        IERC20(params.tokenOut).safeTransfer(params.recipient, amountOut);

        emit Swapped(params.tokenIn, params.tokenOut, params.amountIn, amountOut);
    }

    // ─────────────────────────────────────────────────────────────
    //  Test helpers
    // ─────────────────────────────────────────────────────────────

    /// @notice Set the pool price. Used in tests to simulate price movement and deviation.
    function setPrice(uint256 newUsdcPerXaut) external {
        usdcPerXaut = newUsdcPerXaut;
        _updateSqrtPrice(newUsdcPerXaut);
        emit PriceUpdated(sqrtPriceX96, newUsdcPerXaut);
    }

    function setSwapFeeBps(uint256 feeBps) external {
        require(feeBps <= 10_000, "MockUniswapV3PoolXAUT: feeBps > 10000");
        swapFeeBps = feeBps;
    }

    /// @notice Fund the pool with tokens so swaps can execute.
    ///         Pulls tokens from msg.sender via transferFrom.
    ///         NOTE: on Arc Testnet the USDC predeploy's delegatecall proxy can cause a
    ///         StackUnderflow when called from a Foundry broadcast script. Use
    ///         fundPoolDirect() instead when deploying via forge script.
    function fundPool(uint256 usdcAmount, uint256 xautAmount) external {
        if (usdcAmount > 0) usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        if (xautAmount > 0) xaut.safeTransferFrom(msg.sender, address(this), xautAmount);
    }

    /// @notice Fund the pool by accepting tokens already transferred to this contract.
    ///         Caller must send tokens directly (transfer, not approve+transferFrom) before
    ///         calling this function. This avoids triggering the Arc Testnet USDC predeploy's
    ///         delegatecall stack depth issue in Foundry broadcast scripts.
    ///         The function verifies the pool actually holds at least the declared amounts.
    function fundPoolDirect(uint256 usdcAmount, uint256 xautAmount) external {
        // Skip USDC balance check when usdcAmount == 0 to avoid calling the Arc Testnet
        // USDC predeploy (delegatecall proxy causes stack overflow in broadcast scripts).
        if (usdcAmount > 0) {
            require(
                usdc.balanceOf(address(this)) >= usdcAmount,
                "MockPool: insufficient USDC already transferred"
            );
        }
        require(
            xaut.balanceOf(address(this)) >= xautAmount,
            "MockPool: insufficient XAUT already transferred"
        );
        // Tokens are already in the pool — nothing else to do.
    }

    // ─────────────────────────────────────────────────────────────
    //  Internal helpers
    // ─────────────────────────────────────────────────────────────

    /// @notice Configure either real token ordering and preserve the quoted whole-token price.
    function setTokenOrder(bool xautFirst) external {
        token0 = xautFirst ? address(xaut) : address(usdc);
        token1 = xautFirst ? address(usdc) : address(xaut);
        _updateSqrtPrice(usdcPerXaut);
    }

    /// @dev Price is USDC base units per whole XAUT; slot0 encodes token1/token0 raw units.
    function _updateSqrtPrice(uint256 price) internal {
        require(price > 0, "MockPool: zero price");
        uint256 numerator = token0 == address(xaut) ? price : xautScale;
        uint256 denominator = token0 == address(xaut) ? xautScale : price;
        uint256 sqrtVal = Math.sqrt(Math.mulDiv(numerator, 1 << 192, denominator));
        require(sqrtVal <= type(uint160).max && sqrtVal > 0, "MockPool: price out of range");
        sqrtPriceX96 = uint160(sqrtVal);
    }
}
