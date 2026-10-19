// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IStrategyAdapter} from "../IStrategyAdapter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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
        IERC20(usdc).forceApprove(positionManager, amount);

        INonfungiblePositionManager.MintParams memory params;
        params.token0 = token0;
        params.token1 = token1;
        params.fee = poolFee;
        params.tickLower = tickLower;
        params.tickUpper = tickUpper;
        params.amount0Desired = usdc == token0 ? amount : 0;
        params.amount1Desired = usdc == token1 ? amount : 0;
        params.amount0Min = 0;
        params.amount1Min = 0;
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

        INonfungiblePositionManager(positionManager).decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidityToBurn,
                amount0Min: 0,
                amount1Min: 0,
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

    function setTickRange(int24 lower, int24 upper) external onlyOwner {
        tickLower = lower;
        tickUpper = upper;
        emit TickRangeUpdated(lower, upper);
    }
}
