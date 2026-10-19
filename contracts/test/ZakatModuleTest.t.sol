// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ZakatModule} from "../ZakatModule.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";

/// @dev The test contract itself acts as the vault so it can call distributeZakat.
contract ZakatModuleTest is Test {
    MockERC20 internal usdc;
    ZakatModule internal zakatModule;

    address internal owner = makeAddr("owner");
    address internal charityWallet = makeAddr("charity");
    address internal random = makeAddr("random");
    address internal newWallet = makeAddr("newWallet");

    // The test contract is the vault
    address internal vault;

    function setUp() public {
        vault = address(this);
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);

        vm.prank(owner);
        zakatModule = new ZakatModule(charityWallet, address(usdc), vault, owner);
    }

    // -----------------------------------------------------------------------
    // Helper: mint to vault (this contract) and approve zakatModule
    // -----------------------------------------------------------------------
    function _fundVault(uint256 amount) internal {
        usdc.mint(vault, amount);
        usdc.approve(address(zakatModule), amount);
    }

    // -----------------------------------------------------------------------
    // test_distributeZakat_basic
    // grossProfit=1000e6 → zakat=25e6 (2.5%), remaining=975e6
    // -----------------------------------------------------------------------
    function test_distributeZakat_basic() public {
        _fundVault(1_000e6);

        (uint256 zakatAmount, uint256 remaining) = zakatModule.distributeZakat(1_000e6);

        assertEq(zakatAmount, 25e6, "zakat should be 2.5% = 25e6");
        assertEq(remaining, 975e6, "remaining should be 975e6");
        assertEq(usdc.balanceOf(charityWallet), 25e6, "charity wallet should receive zakat");
    }

    // -----------------------------------------------------------------------
    // test_distributeZakat_only_vault
    // -----------------------------------------------------------------------
    function test_distributeZakat_only_vault() public {
        vm.prank(random);
        vm.expectRevert(ZakatModule.NotVault.selector);
        zakatModule.distributeZakat(1_000e6);
    }

    // -----------------------------------------------------------------------
    // test_distributeZakat_zero_amount
    // -----------------------------------------------------------------------
    function test_distributeZakat_zero_amount() public {
        vm.expectRevert(ZakatModule.ZeroAmount.selector);
        zakatModule.distributeZakat(0);
    }

    // -----------------------------------------------------------------------
    // test_propose_wallet_change
    // -----------------------------------------------------------------------
    function test_propose_wallet_change() public {
        vm.prank(owner);
        zakatModule.proposeZakatWalletChange(newWallet);

        assertEq(zakatModule.pendingZakatWallet(), newWallet, "pending wallet should be set");
        assertGt(zakatModule.walletChangeRequestTime(), 0);
    }

    // -----------------------------------------------------------------------
    // test_confirm_before_timelock_reverts
    // -----------------------------------------------------------------------
    function test_confirm_before_timelock_reverts() public {
        vm.prank(owner);
        zakatModule.proposeZakatWalletChange(newWallet);

        // Warp 30 days - 1 second — still within timelock
        skip(30 days - 1);

        vm.prank(owner);
        vm.expectRevert(); // TimelockNotElapsed
        zakatModule.confirmZakatWalletChange();
    }

    // -----------------------------------------------------------------------
    // test_confirm_after_timelock_succeeds
    // -----------------------------------------------------------------------
    function test_confirm_after_timelock_succeeds() public {
        vm.prank(owner);
        zakatModule.proposeZakatWalletChange(newWallet);

        skip(30 days + 1);

        vm.prank(owner);
        zakatModule.confirmZakatWalletChange();

        assertEq(zakatModule.zakatWallet(), newWallet, "zakatWallet should be updated");
        assertEq(zakatModule.pendingZakatWallet(), address(0), "pending should be cleared");
    }

    // -----------------------------------------------------------------------
    // test_cancel_wallet_change
    // -----------------------------------------------------------------------
    function test_cancel_wallet_change() public {
        vm.prank(owner);
        zakatModule.proposeZakatWalletChange(newWallet);

        vm.prank(owner);
        zakatModule.cancelZakatWalletChange();

        assertEq(zakatModule.pendingZakatWallet(), address(0), "pending should be cleared after cancel");
    }

    // -----------------------------------------------------------------------
    // test_cancel_no_pending_reverts
    // -----------------------------------------------------------------------
    function test_cancel_no_pending_reverts() public {
        vm.prank(owner);
        vm.expectRevert(ZakatModule.NoPendingChange.selector);
        zakatModule.cancelZakatWalletChange();
    }

    // -----------------------------------------------------------------------
    // test_zero_wallet_constructor_reverts
    // -----------------------------------------------------------------------
    function test_zero_wallet_constructor_reverts() public {
        vm.prank(owner);
        vm.expectRevert(ZakatModule.ZeroWallet.selector);
        new ZakatModule(address(0), address(usdc), vault, owner);
    }

    // -----------------------------------------------------------------------
    // test_total_zakat_distributed_accumulates
    // -----------------------------------------------------------------------
    function test_total_zakat_distributed_accumulates() public {
        // First distribution: 1000e6 gross → 25e6 zakat
        _fundVault(2_000e6);
        usdc.approve(address(zakatModule), 2_000e6);

        zakatModule.distributeZakat(1_000e6);
        zakatModule.distributeZakat(1_000e6);

        assertEq(zakatModule.totalZakatDistributed(), 50e6, "total should accumulate across calls");
        assertEq(usdc.balanceOf(charityWallet), 50e6);
    }

    // -----------------------------------------------------------------------
    // test_timelock_boundary — warp 30 days - 1s reverts, +1s more passes
    // -----------------------------------------------------------------------
    function test_timelock_boundary() public {
        vm.prank(owner);
        zakatModule.proposeZakatWalletChange(newWallet);
        uint256 requestTime = zakatModule.walletChangeRequestTime();

        // Exactly at timelock boundary - 1 second: should revert
        vm.warp(requestTime + 30 days - 1);
        vm.prank(owner);
        vm.expectRevert();
        zakatModule.confirmZakatWalletChange();

        // One second past boundary: should succeed
        vm.warp(requestTime + 30 days);
        vm.prank(owner);
        zakatModule.confirmZakatWalletChange();
        assertEq(zakatModule.zakatWallet(), newWallet);
    }

    // -----------------------------------------------------------------------
    // test_propose_zero_wallet_reverts
    // -----------------------------------------------------------------------
    function test_propose_zero_wallet_reverts() public {
        vm.prank(owner);
        vm.expectRevert(ZakatModule.ZeroWallet.selector);
        zakatModule.proposeZakatWalletChange(address(0));
    }
}
