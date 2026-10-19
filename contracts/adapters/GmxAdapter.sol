// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IStrategyAdapter} from "../IStrategyAdapter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IGlpManager {
    function addLiquidity(address token, uint256 amount, uint256 minUsdg, uint256 minGlp) external returns (uint256);
    function removeLiquidity(address tokenOut, uint256 glpAmount, uint256 minOut, address receiver)
        external
        returns (uint256);
}

interface IGLP {
    function balanceOf(address account) external view returns (uint256);
}

contract GmxAdapter is IStrategyAdapter, Ownable2Step {
    using SafeERC20 for IERC20;

    error OnlyVault();
    error InsufficientGlp();

    event Deployed(uint256 amount);
    event Recalled(uint256 received);

    address public immutable glpManager;
    address public immutable glpToken;
    address public immutable usdc;
    address public immutable override vault;

    uint256 public totalDeployed;

    constructor(address glpManager_, address glpToken_, address usdc_, address vault_, address owner_) Ownable(owner_) {
        glpManager = glpManager_;
        glpToken = glpToken_;
        usdc = usdc_;
        vault = vault_;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    function deploy(uint256 amount) external onlyVault returns (uint256 deployed) {
        IERC20(usdc).forceApprove(glpManager, amount);
        IGlpManager(glpManager).addLiquidity(usdc, amount, 0, 0);
        IERC20(usdc).forceApprove(glpManager, 0);

        totalDeployed += amount;

        emit Deployed(amount);
        return amount;
    }

    function recall(uint256 amount) external onlyVault returns (uint256 returned) {
        uint256 glpBal = IGLP(glpToken).balanceOf(address(this));

        uint256 glpToBurn = totalDeployed > 0 ? (glpBal * amount) / totalDeployed : glpBal;
        if (glpToBurn > glpBal) {
            glpToBurn = glpBal;
        }
        if (glpToBurn == 0) revert InsufficientGlp();

        // Use SafeERC20 forceApprove to handle non-standard GLP token approve return values
        IERC20(glpToken).forceApprove(glpManager, glpToBurn);
        uint256 received = IGlpManager(glpManager).removeLiquidity(usdc, glpToBurn, 0, vault);
        IERC20(glpToken).forceApprove(glpManager, 0);

        // Decrement by actual received (not requested) to track real capital
        if (received >= totalDeployed) {
            totalDeployed = 0;
        } else {
            totalDeployed -= received;
        }

        emit Recalled(received);
        return received;
    }

    function currentValue() external view returns (uint256) {
        uint256 glpBal = IGLP(glpToken).balanceOf(address(this));
        if (glpBal == 0) {
            return 0;
        }

        // NOTE: Simplified mark. Production should derive USDC value from
        // GlpManager.getAumInUsdg() / totalSupply * glpBal.
        return totalDeployed;
    }

    function protocolName() external pure returns (string memory) {
        return "GMX V2 GLP";
    }
}
