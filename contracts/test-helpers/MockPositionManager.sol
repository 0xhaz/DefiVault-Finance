// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INonfungiblePositionManager} from "../adapters/HalalLPAdapter.sol";

/// @notice Minimal Uniswap-V3-style NonfungiblePositionManager + factory + pool mock for
///         HalalLPAdapter tests. It is its own factory and pool (`factory()`, `getPool()`
///         and `slot0()` all resolve to this contract).
/// @dev    Liquidity maps 1:1 to token units. `payoutBps` lets tests simulate slippage:
///         mint/decreaseLiquidity pay out `payoutBps / 10_000` of the nominal amount and,
///         like the real manager, revert with "Price slippage check" if the payout is
///         below the caller-supplied minimum. Records the last min amounts it received.
contract MockPositionManager {
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
    }

    function setObserveUnavailable(bool unavailable) external {
        observeUnavailable = unavailable;
    }

    // ── single tracked position ──
    uint24 public posFee;
    int24 public posLower;
    int24 public posUpper;
    uint128 public posLiquidity;
    uint128 public owed0;
    uint128 public owed1;
    uint256 public nextId = 1;

    // ── recorded call params ──
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
        payoutBps = bps;
    }

    // ── factory / pool facade ──
    function factory() external view returns (address) {
        return address(this);
    }

    function getPool(address, address, uint24) external view returns (address) {
        return address(this);
    }

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

    // ── position manager ──
    function mint(INonfungiblePositionManager.MintParams calldata p)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        mintCount++;
        lastMintAmount0Min = p.amount0Min;
        lastMintAmount1Min = p.amount1Min;
        lastMintAmount0Desired = p.amount0Desired;
        lastMintAmount1Desired = p.amount1Desired;

        amount0 = (p.amount0Desired * payoutBps) / 10_000;
        amount1 = (p.amount1Desired * payoutBps) / 10_000;
        require(amount0 >= p.amount0Min && amount1 >= p.amount1Min, "Price slippage check");

        if (amount0 > 0) IERC20(p.token0).transferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) IERC20(p.token1).transferFrom(msg.sender, address(this), amount1);

        tokenId = nextId++;
        liquidity = uint128(amount0 + amount1);
        posLiquidity += liquidity;
        posFee = p.fee;
        posLower = p.tickLower;
        posUpper = p.tickUpper;
    }

    function decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams calldata p)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        decreaseCount++;
        lastDecAmount0Min = p.amount0Min;
        lastDecAmount1Min = p.amount1Min;
        lastDecLiquidity = p.liquidity;

        require(p.liquidity <= posLiquidity, "liquidity");
        amount0 = (uint256(p.liquidity) * payoutBps) / 10_000;
        amount1 = (uint256(p.liquidity) * payoutBps) / 10_000;
        require(amount0 >= p.amount0Min && amount1 >= p.amount1Min, "Price slippage check");

        posLiquidity -= p.liquidity;
        owed0 += uint128(amount0);
        owed1 += uint128(amount1);
    }

    function collect(INonfungiblePositionManager.CollectParams calldata p)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        amount0 = owed0 < p.amount0Max ? owed0 : p.amount0Max;
        amount1 = owed1 < p.amount1Max ? owed1 : p.amount1Max;
        owed0 -= uint128(amount0);
        owed1 -= uint128(amount1);
        if (amount0 > 0) IERC20(token0).transfer(p.recipient, amount0);
        if (amount1 > 0) IERC20(token1).transfer(p.recipient, amount1);
    }

    function positions(uint256)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address t0,
            address t1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        return (0, address(0), token0, token1, posFee, posLower, posUpper, posLiquidity, 0, 0, owed0, owed1);
    }
}
