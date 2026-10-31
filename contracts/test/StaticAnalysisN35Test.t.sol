// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ShariahVault} from "../ShariahVault.sol";
import {TaskN29Base, TaskN29V1Mixin, TaskN29V2Mixin} from "./TaskN29Test.Base.t.sol";

/// @dev Transfer-funded adapter that lets the vault pull its balance back through returnCapital.
contract ReturnAdapterN35 {
    IERC20 internal immutable token;

    constructor(IERC20 token_, address vault_) {
        token = token_;
        token_.approve(vault_, type(uint256).max);
    }

    function currentValue() external view returns (uint256) {
        return token.balanceOf(address(this));
    }
}

/// @dev N-35 (Slither arbitrary-send-erc20): returnCapital used to pull with safeTransferFrom(strategy, vault,
///      amount) for ANY address, so the owner or manager could drain a depositor's wallet through the
///      depositor's allowance to the vault. It now requires booked principal.
abstract contract N35Tests is TaskN29Base {
    function test_N35_ownerCannotPullDepositorAllowance() public {
        uint256 walletBefore = usdc.balanceOf(carol); // carol approved the vault (max) but never deposited
        assertGt(usdc.allowance(carol, address(vault)), 0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.AdapterNotFunded.selector, carol));
        vault.returnCapital(carol, 500e6);
        assertEq(usdc.balanceOf(carol), walletBefore);
    }

    function test_N35_managerCannotPullDepositorAllowance() public {
        uint256 walletBefore = usdc.balanceOf(alice); // alice is a depositor with a max allowance
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.AdapterNotFunded.selector, alice));
        vault.returnCapital(alice, 1e6);
        assertEq(usdc.balanceOf(alice), walletBefore);
    }

    function _fundedAdapter(uint256 amount) internal returns (ReturnAdapterN35 a) {
        a = new ReturnAdapterN35(IERC20(address(usdc)), address(vault));
        vm.startPrank(owner);
        vault.setScreened(address(a), true); // V1 screening
        registry.proposeScreening(address(a), keccak256("N35"), block.timestamp + 365 days); // V2 screening
        vm.stopPrank();
        skip(30 days + 1);
        vm.prank(owner);
        registry.executeScreening(address(a));
        vm.prank(manager);
        vault.deployCapital(address(a), amount, "");
        assertEq(vault.principalOf(address(a)), amount);
    }

    function test_N35_fundedAdapterReturnsPrincipalPlusProfit_thenCannotPullAgain() public {
        ReturnAdapterN35 a = _fundedAdapter(100e6);
        usdc.mint(address(a), 10e6); // adapter profit
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        vm.prank(manager);
        vault.returnCapital(address(a), 110e6);

        assertEq(usdc.balanceOf(address(vault)), vaultBefore + 110e6, "principal and profit returned");
        assertEq(vault.principalOf(address(a)), 0, "principal fully retired");
        assertEq(vault.fundedAdapterCount(), 0);

        usdc.mint(address(a), 1e6); // a later balance is no longer pullable through returnCapital
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.AdapterNotFunded.selector, address(a)));
        vault.returnCapital(address(a), 1e6);
    }

    function test_N35_partialReturnKeepsAdapterFunded() public {
        ReturnAdapterN35 a = _fundedAdapter(100e6);
        vm.prank(manager);
        vault.returnCapital(address(a), 40e6);
        assertEq(vault.principalOf(address(a)), 60e6);
        vm.prank(manager);
        vault.returnCapital(address(a), 60e6);
        assertEq(vault.principalOf(address(a)), 0);
    }
}

contract N35V1Test is N35Tests, TaskN29V1Mixin {}

contract N35V2Test is N35Tests, TaskN29V2Mixin {}
