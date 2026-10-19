// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IStrategyAdapter} from "../IStrategyAdapter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ICurvePool {
    // add_liquidity for 3pool: coins = [DAI, USDC, USDT]
    function add_liquidity(uint256[3] calldata amounts, uint256 min_mint_amount) external returns (uint256);
    function remove_liquidity_one_coin(uint256 token_amount, int128 i, uint256 min_amount) external returns (uint256);
    function calc_withdraw_one_coin(uint256 token_amount, int128 i) external view returns (uint256);
    function balances(uint256 i) external view returns (uint256);
    function get_virtual_price() external view returns (uint256);
}

interface ICurveLPToken {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract CurveAdapter is IStrategyAdapter, Ownable2Step {
    using SafeERC20 for IERC20;

    error OnlyVault();

    event Deployed(uint256 amount);
    event Recalled(uint256 received);

    address public immutable pool;
    address public immutable lpToken;
    address public immutable usdc;
    address public immutable override vault;

    int128 public constant USDC_INDEX = 1;

    uint256 public totalDeployed;

    constructor(address pool_, address lpToken_, address usdc_, address vault_, address owner_) Ownable(owner_) {
        pool = pool_;
        lpToken = lpToken_;
        usdc = usdc_;
        vault = vault_;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    function deploy(uint256 amount) external onlyVault returns (uint256 deployed) {
        IERC20(usdc).forceApprove(pool, amount);

        uint256[3] memory amounts = [uint256(0), amount, uint256(0)];
        ICurvePool(pool).add_liquidity(amounts, 0);

        IERC20(usdc).forceApprove(pool, 0);

        totalDeployed += amount;

        emit Deployed(amount);
        return amount;
    }

    function recall(uint256 amount) external onlyVault returns (uint256 returned) {
        uint256 lpBalance = ICurveLPToken(lpToken).balanceOf(address(this));
        uint256 totalValue = currentValue();

        if (totalValue == 0) {
            return 0;
        }

        uint256 lpToBurn = (lpBalance * amount) / totalValue;
        if (lpToBurn > lpBalance) {
            lpToBurn = lpBalance;
        }

        // Use SafeERC20 forceApprove to handle non-standard LP token approve return values
        IERC20(lpToken).forceApprove(pool, lpToBurn);
        uint256 received = ICurvePool(pool).remove_liquidity_one_coin(lpToBurn, USDC_INDEX, 0);
        IERC20(lpToken).forceApprove(pool, 0);

        IERC20(usdc).safeTransfer(vault, received);

        // Decrement by actual received amount (not requested) to stay in sync with real capital
        if (received >= totalDeployed) {
            totalDeployed = 0;
        } else {
            totalDeployed -= received;
        }

        emit Recalled(received);
        return received;
    }

    function currentValue() public view returns (uint256) {
        uint256 lp = ICurveLPToken(lpToken).balanceOf(address(this));
        if (lp == 0) {
            return 0;
        }

        return ICurvePool(pool).calc_withdraw_one_coin(lp, USDC_INDEX);
    }

    function protocolName() external pure returns (string memory) {
        return "Curve 3pool";
    }
}
