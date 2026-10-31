// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TaskN29Base, TaskN29V1Mixin, TaskN29V2Mixin} from "./TaskN29Test.Base.t.sol";

/// @dev N-35 (Slither arbitrary-send-erc20): ShariahVault.returnCapital(strategy, amount) pulls with
///      safeTransferFrom(strategy, vault, amount) for ANY strategy address. Depositors normally leave an
///      allowance to the vault, so the owner or manager can pull a depositor's wallet USDC into the vault.
abstract contract N35Tests is TaskN29Base {
    /// KNOWN FINDING N-35 (open): flip to expectRevert once returnCapital is restricted to funded adapters.
    function test_knownFinding_N35_ownerPullsDepositorAllowanceViaReturnCapital() public {
        uint256 walletBefore = usdc.balanceOf(carol); // carol approved the vault (max) but never deposited
        assertGt(usdc.allowance(carol, address(vault)), 0);
        assertEq(vault.principalOf(carol), 0, "carol is not an adapter");

        vm.prank(owner);
        vault.returnCapital(carol, 500e6);

        assertEq(usdc.balanceOf(carol), walletBefore - 500e6, "N-35 fixed? owner no longer pulls: flip this test");
    }

    function test_knownFinding_N35_managerPullsDepositorAllowanceViaReturnCapital() public {
        uint256 walletBefore = usdc.balanceOf(carol);
        vm.prank(manager);
        vault.returnCapital(carol, 1e6);
        assertEq(usdc.balanceOf(carol), walletBefore - 1e6, "N-35 fixed? manager no longer pulls: flip this test");
    }
}

contract N35V1Test is N35Tests, TaskN29V1Mixin {}

contract N35V2Test is N35Tests, TaskN29V2Mixin {}
