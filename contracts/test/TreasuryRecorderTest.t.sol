// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {TreasuryModule} from "../TreasuryModule.sol";

/// @notice Covers the authorisation changes that make the F-01 fix usable end to end:
///         the fee source can settle its own sweeps and an owner-approved recorder
///         (PurificationEscrow) can book Musharakah profit.
contract TreasuryRecorderTest is Test {
    TreasuryModule treasury;
    address owner = makeAddr("owner");
    address vault = makeAddr("vault");
    address escrow = makeAddr("escrow");
    address attacker = makeAddr("attacker");

    function setUp() public {
        treasury = new TreasuryModule("Shariah", vault, address(0xBEEF), 50, 1000, 400, owner);
    }

    function test_recorder_can_book_profit_only_after_approval() public {
        vm.prank(escrow);
        vm.expectRevert(TreasuryModule.NotFeeSource.selector);
        treasury.recordMusharakahProfit(10e6);

        vm.prank(owner);
        treasury.setProfitRecorder(escrow);

        vm.prank(escrow);
        treasury.recordMusharakahProfit(10e6);
        assertEq(treasury.pendingFees(), 10e6);
    }

    function test_attacker_cannot_book_profit_or_set_recorder() public {
        vm.prank(attacker);
        vm.expectRevert(TreasuryModule.NotFeeSource.selector);
        treasury.recordMusharakahProfit(1);

        vm.prank(attacker);
        vm.expectRevert();
        treasury.setProfitRecorder(attacker);
    }

    function test_feeSource_settles_claim_and_owner_still_can() public {
        vm.prank(vault);
        treasury.accrue(100e6);

        vm.prank(vault);
        treasury.claimFees(owner, 40e6);
        assertEq(treasury.pendingFees(), 60e6);

        vm.prank(owner);
        treasury.claimFees(owner, 60e6);
        assertEq(treasury.pendingFees(), 0);
        assertEq(treasury.totalFeesCollected(), 100e6);
    }

    function test_stranger_cannot_claim() public {
        vm.prank(vault);
        treasury.accrue(100e6);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        treasury.claimFees(attacker, 1);
    }
}
