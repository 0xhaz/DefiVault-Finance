// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IStrategyAdapter} from "../IStrategyAdapter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IComet {
    function supply(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

contract CompoundAdapter is IStrategyAdapter, Ownable2Step {
    using SafeERC20 for IERC20;

    error OnlyVault();

    event Deployed(uint256 amount);
    event Recalled(uint256 amount);

    address public immutable comet;
    address public immutable usdc;
    address public immutable override vault;
    uint256 public totalDeployed;

    constructor(address comet_, address usdc_, address vault_, address owner_) Ownable(owner_) {
        comet = comet_;
        usdc = usdc_;
        vault = vault_;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    function deploy(uint256 amount) external onlyVault returns (uint256 deployed) {
        IERC20(usdc).forceApprove(comet, amount);
        IComet(comet).supply(usdc, amount);
        IERC20(usdc).forceApprove(comet, 0);

        totalDeployed += amount;

        emit Deployed(amount);
        return amount;
    }

    function recall(uint256 amount) external onlyVault returns (uint256 returned) {
        IComet(comet).withdraw(usdc, amount);
        IERC20(usdc).safeTransfer(vault, amount);

        if (amount >= totalDeployed) {
            totalDeployed = 0;
        } else {
            totalDeployed -= amount;
        }

        emit Recalled(amount);
        return amount;
    }

    function currentValue() external view returns (uint256) {
        return IComet(comet).balanceOf(address(this));
    }

    function protocolName() external pure returns (string memory) {
        return "Compound V3";
    }
}
