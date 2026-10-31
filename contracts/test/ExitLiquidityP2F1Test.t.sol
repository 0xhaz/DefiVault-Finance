// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TaskN29V1Mixin, TaskN29V2Mixin} from "./TaskN29Test.Base.t.sol";
import {TaskR5Base, GasAdapterR5} from "./TaskReviewR5Test.Base.t.sol";

/// @dev P2-F1 (second review pass): exit settlement pays the leaver's purification and charity out of idle
///      USDC, then requires the payout to still be covered. maxWithdraw/maxRedeem used to allow the whole idle
///      balance, so a max-size exit made the settlement revert inside its try/catch and the cut was skipped.
///      The limits now reserve the pending distribution cut.
abstract contract ExitLiquidityP2F1Tests is TaskR5Base {
    function _setupDeployed() internal {
        GasAdapterR5 a = new GasAdapterR5(IERC20(address(usdc)), 0);
        vm.startPrank(owner);
        vault.setScreened(address(a), true);
        registry.proposeScreening(address(a), keccak256("P2F1"), block.timestamp + 365 days);
        vm.stopPrank();
        skip(30 days + 1);
        vm.startPrank(owner);
        registry.executeScreening(address(a));
        vault.deployCapital(address(a), 1_500e6, "");
        vm.stopPrank();
        _yield(200e6); // idle = 700e6, realized profit 200e6
    }

    function test_P2F1_maxRedeemExit_settlesCut() public {
        _setupDeployed();
        uint256 shares = vault.maxRedeem(bob);
        assertLt(shares, vault.balanceOf(bob), "exit is liquidity-bound");
        uint256 base = _distNow();
        vm.prank(bob);
        vault.redeem(shares, bob, bob);
        assertGt(_distNow(), base, "leaver's cut settled at the max exit");
    }

    function test_P2F1_maxWithdrawExit_settlesCut() public {
        _setupDeployed();
        uint256 assets = vault.maxWithdraw(bob);
        uint256 base = _distNow();
        vm.prank(bob);
        vault.withdraw(assets, bob, bob);
        assertGt(_distNow(), base, "leaver's cut settled at the max withdraw");
    }

    function test_P2F1_limitsReservePendingCut() public {
        _setupDeployed();
        uint256 cut = vault.pendingDistributionCut();
        assertGt(cut, 0);
        uint256 idle = usdc.balanceOf(address(vault));
        assertLe(vault.maxWithdraw(bob), idle - cut);
        assertLe(vault.previewRedeem(vault.maxRedeem(bob)), idle - cut);
    }

    function test_P2F1_noProfit_limitIsWholeIdleBalance() public {
        GasAdapterR5 a = new GasAdapterR5(IERC20(address(usdc)), 0);
        vm.startPrank(owner);
        vault.setScreened(address(a), true);
        registry.proposeScreening(address(a), keccak256("P2F1b"), block.timestamp + 365 days);
        vm.stopPrank();
        skip(30 days + 1);
        vm.startPrank(owner);
        registry.executeScreening(address(a));
        vault.deployCapital(address(a), 1_500e6, "");
        vm.stopPrank();
        assertEq(vault.pendingDistributionCut(), 0);
        uint256 idle = usdc.balanceOf(address(vault));
        assertEq(vault.maxWithdraw(bob), idle < vault.previewRedeem(vault.balanceOf(bob)) ? idle : vault.previewRedeem(vault.balanceOf(bob)));
    }
}

contract ExitLiquidityP2F1V1Test is ExitLiquidityP2F1Tests, TaskN29V1Mixin {}

contract ExitLiquidityP2F1V2Test is ExitLiquidityP2F1Tests, TaskN29V2Mixin {}
