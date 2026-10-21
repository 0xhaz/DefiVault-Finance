// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {CharityModule} from "../CharityModule.sol";
import {MockERC20}     from "../test-helpers/MockERC20.sol";

/**
 * @title  CharityModuleTest
 * @notice Unit tests for CharityModule — 20+ tests covering distribution,
 *         wallet timelock, and rate timelock.
 *
 * Setup: test contract IS the vault (address(this) == vault).
 *        Owner is a separate EOA to keep onlyOwner / onlyVault orthogonal.
 */
contract CharityModuleTest is Test {

    // ── actors ────────────────────────────────────────────────────────────────
    address internal owner        = makeAddr("owner");
    address internal charityWallet = makeAddr("charityWallet");
    address internal other        = makeAddr("other");

    // ── contracts ─────────────────────────────────────────────────────────────
    MockERC20     internal usdc;
    CharityModule internal module;

    // ── helpers ───────────────────────────────────────────────────────────────
    uint256 internal constant INITIAL_BALANCE = 1_000_000e6;

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);

        // address(this) is vault; owner is the Ownable owner
        vm.prank(owner);
        module = new CharityModule(charityWallet, address(usdc), address(this), owner);

        // Fund this contract (acting as vault) with USDC
        usdc.mint(address(this), INITIAL_BALANCE);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. Basic distribution
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice distributeCharity(1000e6) → charityAmount = 25e6 (2.5%), remaining = 975e6
    function test_distributeCharity_basic() public {
        uint256 gross = 1_000e6;
        usdc.approve(address(module), gross);

        (uint256 charityAmount, uint256 remaining) = module.distributeCharity(gross);

        assertEq(charityAmount, 25e6,    "charityAmount should be 2.5% of gross");
        assertEq(remaining,     975e6,   "remaining should be gross - charity");
        assertEq(usdc.balanceOf(charityWallet), 25e6, "charityWallet should receive 25e6");
    }

    /// @notice distributeCharity(0) must revert ZeroAmount
    function test_distributeCharity_zero_reverts() public {
        vm.expectRevert(CharityModule.ZeroAmount.selector);
        module.distributeCharity(0);
    }

    /// @notice Non-vault caller must revert NotVault
    function test_distributeCharity_not_vault_reverts() public {
        vm.prank(other);
        vm.expectRevert(CharityModule.NotVault.selector);
        module.distributeCharity(1e6);
    }

    /// @notice totalCharityDistributed accumulates across two calls
    function test_totalCharityDistributed_accumulates() public {
        uint256 gross1 = 1_000e6;
        uint256 gross2 = 2_000e6;

        usdc.approve(address(module), gross1 + gross2);

        (uint256 c1,) = module.distributeCharity(gross1);
        (uint256 c2,) = module.distributeCharity(gross2);

        assertEq(module.totalCharityDistributed(), c1 + c2, "totalCharityDistributed should sum both calls");
    }

    /// @notice Default charityBps is 250
    function test_default_charityBps_is_250() public view {
        assertEq(module.charityBps(), 250);
    }

    /// @notice MAX_CHARITY_BPS constant is 500
    function test_MAX_CHARITY_BPS_is_500() public view {
        assertEq(module.MAX_CHARITY_BPS(), 500);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. Wallet timelock
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice proposeCharityWalletChange sets pendingCharityWallet
    function test_proposeWalletChange_sets_pending() public {
        address newWallet = makeAddr("newWallet");
        vm.prank(owner);
        module.proposeCharityWalletChange(newWallet);
        assertEq(module.pendingCharityWallet(), newWallet, "pendingCharityWallet should be set");
    }

    /// @notice Confirming immediately after proposal reverts TimelockNotElapsed
    function test_confirmWalletChange_before_timelock_reverts() public {
        address newWallet = makeAddr("newWallet");
        vm.startPrank(owner);
        module.proposeCharityWalletChange(newWallet);
        vm.expectRevert(); // TimelockNotElapsed(remaining)
        module.confirmCharityWalletChange();
        vm.stopPrank();
    }

    /// @notice Confirming after 30 days updates charityWallet
    function test_confirmWalletChange_after_30_days_succeeds() public {
        address newWallet = makeAddr("newWallet");
        vm.startPrank(owner);
        module.proposeCharityWalletChange(newWallet);
        vm.warp(block.timestamp + 30 days);
        module.confirmCharityWalletChange();
        vm.stopPrank();
        assertEq(module.charityWallet(), newWallet, "charityWallet should be updated");
        assertEq(module.pendingCharityWallet(), address(0), "pendingCharityWallet should be cleared");
    }

    /// @notice cancelCharityWalletChange clears pendingCharityWallet
    function test_cancelWalletChange_clears_pending() public {
        address newWallet = makeAddr("newWallet");
        vm.startPrank(owner);
        module.proposeCharityWalletChange(newWallet);
        module.cancelCharityWalletChange();
        vm.stopPrank();
        assertEq(module.pendingCharityWallet(), address(0), "pendingCharityWallet should be cleared");
    }

    /// @notice Confirming with no pending proposal reverts NoPendingChange
    function test_confirmWalletChange_no_pending_reverts() public {
        vm.prank(owner);
        vm.expectRevert(CharityModule.NoPendingChange.selector);
        module.confirmCharityWalletChange();
    }

    /// @notice proposeCharityWalletChange(address(0)) reverts ZeroWallet
    function test_proposeWalletChange_zero_reverts() public {
        vm.prank(owner);
        vm.expectRevert(CharityModule.ZeroWallet.selector);
        module.proposeCharityWalletChange(address(0));
    }

    /// @notice Non-owner cannot propose wallet change — reverts OwnableUnauthorizedAccount
    function test_proposeWalletChange_nonOwner_reverts() public {
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other)
        );
        module.proposeCharityWalletChange(makeAddr("x"));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. Rate timelock
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice proposeCharityRateChange(501) reverts CharityRateAboveCap(501, 500)
    function test_proposeRateChange_above_cap_reverts() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(CharityModule.CharityRateAboveCap.selector, 501, 500)
        );
        module.proposeCharityRateChange(501);
    }

    /// @notice proposeCharityRateChange(500) succeeds and sets hasPendingRateChange
    function test_proposeRateChange_at_cap_succeeds() public {
        vm.prank(owner);
        module.proposeCharityRateChange(500);
        assertTrue(module.hasPendingRateChange(), "hasPendingRateChange should be true");
        assertEq(module.pendingCharityBps(), 500);
    }

    /// @notice Confirming rate change immediately reverts TimelockNotElapsed
    function test_confirmRateChange_before_timelock_reverts() public {
        vm.startPrank(owner);
        module.proposeCharityRateChange(300);
        vm.expectRevert(); // TimelockNotElapsed(remaining)
        module.confirmCharityRateChange();
        vm.stopPrank();
    }

    /// @notice Confirming rate change after 30 days updates charityBps
    function test_confirmRateChange_after_30_days_succeeds() public {
        vm.startPrank(owner);
        module.proposeCharityRateChange(100);
        vm.warp(block.timestamp + 30 days);
        module.confirmCharityRateChange();
        vm.stopPrank();
        assertEq(module.charityBps(), 100, "charityBps should be 100 after confirmation");
        assertFalse(module.hasPendingRateChange(), "hasPendingRateChange should be cleared");
    }

    /// @notice cancelCharityRateChange clears hasPendingRateChange
    function test_cancelRateChange() public {
        vm.startPrank(owner);
        module.proposeCharityRateChange(300);
        module.cancelCharityRateChange();
        vm.stopPrank();
        assertFalse(module.hasPendingRateChange(), "hasPendingRateChange should be false after cancel");
        assertEq(module.pendingCharityBps(), 0, "pendingCharityBps should be cleared");
    }

    /// @notice Confirming rate change with no pending reverts NoPendingChange
    function test_confirmRateChange_no_pending_reverts() public {
        vm.prank(owner);
        vm.expectRevert(CharityModule.NoPendingChange.selector);
        module.confirmCharityRateChange();
    }

    /// @notice After rate change to 100 bps, distributeCharity uses updated rate
    function test_distributeCharity_uses_updated_rate() public {
        // Propose and confirm a rate of 100 bps
        vm.startPrank(owner);
        module.proposeCharityRateChange(100);
        vm.warp(block.timestamp + 30 days);
        module.confirmCharityRateChange();
        vm.stopPrank();

        uint256 gross = 1_000e6;
        usdc.approve(address(module), gross);
        (uint256 charityAmount, uint256 remaining) = module.distributeCharity(gross);

        // 100 bps = 1% of 1000e6 = 10e6
        assertEq(charityAmount, 10e6,   "charityAmount should reflect updated rate of 100 bps");
        assertEq(remaining,     990e6,  "remaining should be gross - charityAmount");
    }
}
