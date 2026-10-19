// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IStrategyAdapter} from "../IStrategyAdapter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf) external;
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf) external returns (uint256);
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

interface IAToken {
    function balanceOf(address account) external view returns (uint256);
}

contract AaveLoopAdapter is IStrategyAdapter, Ownable2Step {
    using SafeERC20 for IERC20;

    error OnlyVault();
    error HealthFactorTooLow(uint256 hf);

    event LoopDeployed(uint256 principal, uint256 borrowed);
    event LoopRecalled(uint256 amount, uint256 repaid);

    address public immutable aavePool;
    address public immutable aToken;
    address public immutable usdc;
    address public immutable override vault;

    uint256 public totalDeployed;
    uint256 public totalBorrowed;

    uint256 public constant LOOP_BORROW_BPS = 5000;
    uint256 public constant MIN_HEALTH_FACTOR = 1.5e18;

    constructor(address aavePool_, address aToken_, address usdc_, address vault_, address owner_) Ownable(owner_) {
        aavePool = aavePool_;
        aToken = aToken_;
        usdc = usdc_;
        vault = vault_;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    function deploy(uint256 amount) external onlyVault returns (uint256 deployed) {
        // First supply — approve aavePool to pull USDC from this adapter
        IERC20(usdc).forceApprove(aavePool, amount);
        IAavePool(aavePool).supply(usdc, amount, address(this), 0);
        IERC20(usdc).forceApprove(aavePool, 0);

        // Borrow 50% of principal at variable rate (mode=2)
        uint256 loop1 = (amount * LOOP_BORROW_BPS) / 10_000;
        IAavePool(aavePool).borrow(usdc, loop1, 2, 0, address(this));

        // Health-factor check BEFORE second supply to catch unsafe state early
        (, , , , , uint256 healthFactor) = IAavePool(aavePool).getUserAccountData(address(this));
        if (healthFactor < MIN_HEALTH_FACTOR) revert HealthFactorTooLow(healthFactor);

        // Second supply with borrowed amount
        IERC20(usdc).forceApprove(aavePool, loop1);
        IAavePool(aavePool).supply(usdc, loop1, address(this), 0);
        IERC20(usdc).forceApprove(aavePool, 0);

        totalDeployed += amount;
        totalBorrowed += loop1;

        emit LoopDeployed(amount, loop1);
        return amount;
    }

    function recall(uint256 amount) external onlyVault returns (uint256 returned) {
        if (totalDeployed == 0) return 0;

        // Proportional unwind: repay borrow first, then withdraw collateral
        // Use live aToken balance to avoid stale-counter drift from interest accrual
        uint256 aTokenBal = IAToken(aToken).balanceOf(address(this));
        if (aTokenBal == 0) return 0;

        // Proportion of position to unwind (capped at 100%)
        uint256 proportion = amount >= totalDeployed ? 1e18 : (amount * 1e18) / totalDeployed;

        // Repay proportional borrow first (repay before withdraw to keep HF safe)
        uint256 repayAmt = (totalBorrowed * proportion) / 1e18;
        if (repayAmt > 0) {
            // Withdraw just enough to cover repayment from aToken collateral
            IAavePool(aavePool).withdraw(usdc, repayAmt, address(this));
            IERC20(usdc).forceApprove(aavePool, repayAmt);
            uint256 repaid = IAavePool(aavePool).repay(usdc, repayAmt, 2, address(this));
            IERC20(usdc).forceApprove(aavePool, 0);
            if (repaid >= totalBorrowed) {
                totalBorrowed = 0;
            } else {
                totalBorrowed -= repaid;
            }
        }

        // Withdraw the principal portion to vault
        uint256 withdrawPrincipal = amount >= totalDeployed ? type(uint256).max : amount;
        uint256 actualOut = IAavePool(aavePool).withdraw(usdc, withdrawPrincipal, vault);

        if (amount >= totalDeployed) {
            totalDeployed = 0;
        } else {
            totalDeployed -= actualOut;
        }

        emit LoopRecalled(actualOut, repayAmt);
        return actualOut;
    }

    function currentValue() external view returns (uint256) {
        uint256 aTokenBal = IAToken(aToken).balanceOf(address(this));
        if (totalBorrowed > aTokenBal) {
            return 0;
        }

        return aTokenBal - totalBorrowed;
    }

    function protocolName() external pure returns (string memory) {
        return "Aave V3 2x Loop";
    }
}
