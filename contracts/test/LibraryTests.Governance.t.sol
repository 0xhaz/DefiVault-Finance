// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ShariahVault} from "../ShariahVault.sol";
import {ShariahVaultV2} from "../ShariahVaultV2.sol";
import {LibTestBase, MockScreeningRegistry} from "./LibraryTests.Base.t.sol";

contract LibraryGovernanceTest is LibTestBase {
    event RemoteRecipientProposed(uint32 indexed domain, bytes32 indexed recipient, bool approved, uint256 executeAfter);
    event RemoteRecipientProposalCancelled(uint32 indexed domain, bytes32 indexed recipient);
    event RemoteRecipientUpdated(uint32 indexed domain, bytes32 indexed recipient, bool approved);
    event DustThresholdProposed(uint256 newValue, uint256 executeAfter);
    event DustThresholdProposalCancelled();
    event RegistryProposed(address newRegistry, uint256 executeAfter);
    event RegistryProposalCancelled();

    uint32 internal constant DOM = 6;
    bytes32 internal constant REC = bytes32(uint256(0xBEEF));
    uint256 internal constant DELAY = 30 days;

    // ───────────────────────── remote recipient ─────────────────────────
    function test_RR_ProposeStoresAndEmits() public {
        uint256 ea = block.timestamp + DELAY;
        vm.expectEmit(true, true, false, true, address(h));
        emit RemoteRecipientProposed(DOM, REC, true, ea);
        h.gPropose(DOM, REC, true);
        (bool approved, uint256 executeAfter, bool exists) = h.pendingRR(DOM, REC);
        assertTrue(approved);
        assertEq(executeAfter, ea);
        assertTrue(exists);
        assertFalse(h.approvedRR(DOM, REC), "not approved until confirmed");
    }

    function test_RR_ZeroRecipientReverts() public {
        vm.expectRevert(ShariahVault.ZeroRecipient.selector);
        h.gPropose(DOM, bytes32(0), true);
    }

    function test_RR_DuplicateProposalReverts() public {
        h.gPropose(DOM, REC, true);
        vm.expectRevert(ShariahVault.RemoteRecipientProposalExists.selector);
        h.gPropose(DOM, REC, false);
    }

    function test_RR_ProposalsAreIndependentPerDomainAndRecipient() public {
        h.gPropose(DOM, REC, true);
        h.gPropose(DOM + 1, REC, true);
        h.gPropose(DOM, bytes32(uint256(2)), true);
    }

    function test_RR_ConfirmWithoutProposalReverts() public {
        vm.expectRevert(ShariahVault.NoPendingRemoteRecipient.selector);
        h.gConfirm(DOM, REC);
    }

    function test_RR_ConfirmOneSecondBeforeTimelockReverts() public {
        h.gPropose(DOM, REC, true);
        uint256 ea = block.timestamp + DELAY;
        vm.warp(ea - 1);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.RemoteRecipientTimelockNotElapsed.selector, ea, ea - 1));
        h.gConfirm(DOM, REC);
    }

    function test_RR_ConfirmExactlyAtTimelockSucceeds() public {
        h.gPropose(DOM, REC, true);
        vm.warp(block.timestamp + DELAY);
        vm.expectEmit(true, true, false, true, address(h));
        emit RemoteRecipientUpdated(DOM, REC, true);
        h.gConfirm(DOM, REC);
        assertTrue(h.approvedRR(DOM, REC));
        (,, bool exists) = h.pendingRR(DOM, REC);
        assertFalse(exists, "pending cleared");
    }

    function test_RR_NoExpiryConfirmYearsLater() public {
        h.gPropose(DOM, REC, true);
        vm.warp(block.timestamp + 3650 days);
        h.gConfirm(DOM, REC);
        assertTrue(h.approvedRR(DOM, REC));
    }

    function test_RR_RevokeViaApprovedFalse() public {
        h.gPropose(DOM, REC, true);
        vm.warp(block.timestamp + DELAY);
        h.gConfirm(DOM, REC);
        h.gPropose(DOM, REC, false);
        vm.warp(block.timestamp + DELAY);
        h.gConfirm(DOM, REC);
        assertFalse(h.approvedRR(DOM, REC));
    }

    function test_RR_ConfirmTwiceReverts() public {
        h.gPropose(DOM, REC, true);
        vm.warp(block.timestamp + DELAY);
        h.gConfirm(DOM, REC);
        vm.expectRevert(ShariahVault.NoPendingRemoteRecipient.selector);
        h.gConfirm(DOM, REC);
    }

    function test_RR_CancelClearsAndAllowsReproposal() public {
        h.gPropose(DOM, REC, true);
        vm.expectEmit(true, true, false, false, address(h));
        emit RemoteRecipientProposalCancelled(DOM, REC);
        h.gCancel(DOM, REC);
        (,, bool exists) = h.pendingRR(DOM, REC);
        assertFalse(exists);
        vm.expectRevert(ShariahVault.NoPendingRemoteRecipient.selector);
        h.gConfirm(DOM, REC);
        h.gPropose(DOM, REC, true);
    }

    function test_RR_CancelWithoutProposalReverts() public {
        vm.expectRevert(ShariahVault.NoPendingRemoteRecipient.selector);
        h.gCancel(DOM, REC);
    }

    function test_RR_CancelAfterTimelockStillWorks() public {
        h.gPropose(DOM, REC, true);
        vm.warp(block.timestamp + DELAY + 1);
        h.gCancel(DOM, REC);
        assertFalse(h.approvedRR(DOM, REC));
    }

    // ───────────────────────── dust threshold ─────────────────────────
    function test_Dust_ProposeStoresAndEmits() public {
        uint256 ea = block.timestamp + DELAY;
        vm.expectEmit(false, false, false, true, address(h));
        emit DustThresholdProposed(5e6, ea);
        h.dPropose(5e6);
        (uint256 v, uint256 e, bool x) = h.dust();
        assertEq(v, 5e6);
        assertEq(e, ea);
        assertTrue(x);
    }

    function test_Dust_ProposeTwiceReverts() public {
        h.dPropose(1);
        vm.expectRevert(ShariahVault.DustProposalAlreadyExists.selector);
        h.dPropose(2);
    }

    function test_Dust_CheckWithoutProposalReverts() public {
        vm.expectRevert(ShariahVault.NoPendingDustProposal.selector);
        h.dCheck();
    }

    function test_Dust_CheckBoundary() public {
        h.dPropose(7);
        uint256 ea = block.timestamp + DELAY;
        vm.warp(ea - 1);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.DustTimelockNotElapsed.selector, ea, ea - 1));
        h.dCheck();
        vm.warp(ea);
        h.dCheck();
        vm.warp(ea + 5000 days);
        h.dCheck();
    }

    function test_Dust_CancelClearsEverything() public {
        h.dPropose(7);
        vm.expectEmit(false, false, false, false, address(h));
        emit DustThresholdProposalCancelled();
        h.dCancel();
        (uint256 v, uint256 e, bool x) = h.dust();
        assertEq(v, 0);
        assertEq(e, 0);
        assertFalse(x);
        h.dPropose(9);
    }

    function test_Dust_CancelWithoutProposalReverts() public {
        vm.expectRevert(ShariahVault.NoPendingDustProposal.selector);
        h.dCancel();
    }

    // ───────────────────────── registry timelock ─────────────────────────
    address internal reg1 = makeAddr("reg1");
    address internal reg2 = makeAddr("reg2");

    function test_Reg_ProposeZeroReverts() public {
        vm.expectRevert(ShariahVaultV2.ZeroRegistry.selector);
        h.rPropose(reg1, address(0));
    }

    function test_Reg_ProposeWithCurrentUses30DayDelay() public {
        uint256 ea = block.timestamp + DELAY;
        vm.expectEmit(false, false, false, true, address(h));
        emit RegistryProposed(reg2, ea);
        h.rPropose(reg1, reg2);
        (address n, uint256 e, bool x) = h.pendingReg();
        assertEq(n, reg2);
        assertEq(e, ea);
        assertTrue(x);
    }

    function test_Reg_BootstrapWithZeroCurrentIsImmediate() public {
        h.rPropose(address(0), reg1);
        (, uint256 e,) = h.pendingReg();
        assertEq(e, block.timestamp);
        assertEq(h.rConfirm(), reg1);
    }

    function test_Reg_DuplicateProposalReverts() public {
        h.rPropose(reg1, reg2);
        vm.expectRevert(ShariahVaultV2.RegistryProposalAlreadyExists.selector);
        h.rPropose(reg1, reg2);
    }

    function test_Reg_ConfirmWithoutProposalReverts() public {
        vm.expectRevert(ShariahVaultV2.NoPendingRegistryProposal.selector);
        h.rConfirm();
    }

    function test_Reg_ConfirmBoundary() public {
        h.rPropose(reg1, reg2);
        uint256 ea = block.timestamp + DELAY;
        vm.warp(ea - 1);
        vm.expectRevert(abi.encodeWithSelector(ShariahVaultV2.RegistryTimelockNotElapsed.selector, ea, ea - 1));
        h.rConfirm();
        vm.warp(ea);
        assertEq(h.rConfirm(), reg2);
        (address n, uint256 e, bool x) = h.pendingReg();
        assertEq(n, address(0));
        assertEq(e, 0);
        assertFalse(x);
    }

    function test_Reg_ConfirmCancelsPendingDustProposal() public {
        h.dPropose(9);
        h.rPropose(reg1, reg2);
        vm.warp(block.timestamp + DELAY);
        vm.expectEmit(false, false, false, false, address(h));
        emit DustThresholdProposalCancelled();
        h.rConfirm();
        (uint256 v, uint256 e, bool x) = h.dust();
        assertEq(v, 0);
        assertEq(e, 0);
        assertFalse(x);
    }

    function test_Reg_ConfirmWithoutDustEmitsNoDustCancel() public {
        h.rPropose(reg1, reg2);
        vm.warp(block.timestamp + DELAY);
        vm.recordLogs();
        h.rConfirm();
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_Reg_CancelClearsAndAllowsReproposal() public {
        h.rPropose(reg1, reg2);
        vm.expectEmit(false, false, false, false, address(h));
        emit RegistryProposalCancelled();
        h.rCancel();
        (address n,, bool x) = h.pendingReg();
        assertEq(n, address(0));
        assertFalse(x);
        h.rPropose(reg1, reg1);
    }

    function test_Reg_CancelWithoutProposalReverts() public {
        vm.expectRevert(ShariahVaultV2.NoPendingRegistryProposal.selector);
        h.rCancel();
    }

    // ───────────────────────── screening check ─────────────────────────
    function test_Screening_UnscreenedReverts() public {
        MockScreeningRegistry r = new MockScreeningRegistry();
        r.set(bytes32(0), block.timestamp + 1 days);
        address s = makeAddr("s");
        vm.expectRevert(abi.encodeWithSelector(ShariahVaultV2.NotScreened.selector, s));
        h.rScreen(address(r), s);
    }

    function test_Screening_ExpiryBoundary() public {
        MockScreeningRegistry r = new MockScreeningRegistry();
        address s = makeAddr("s");
        uint256 exp = block.timestamp + 100;
        r.set(keccak256("p"), exp);
        h.rScreen(address(r), s);
        vm.warp(exp - 1);
        h.rScreen(address(r), s);
        vm.warp(exp);
        vm.expectRevert(abi.encodeWithSelector(ShariahVaultV2.ScreeningExpired.selector, s, exp));
        h.rScreen(address(r), s);
    }

    function test_Screening_NotScreenedTakesPrecedenceOverExpired() public {
        MockScreeningRegistry r = new MockScreeningRegistry();
        address s = makeAddr("s");
        r.set(bytes32(0), 0);
        vm.expectRevert(abi.encodeWithSelector(ShariahVaultV2.NotScreened.selector, s));
        h.rScreen(address(r), s);
    }

    // ───────────────────────── fuzz ─────────────────────────
    function testFuzz_RR_TimelockBoundary(uint32 dom, bytes32 rec, bool approved, uint256 wait) public {
        vm.assume(rec != bytes32(0));
        wait = bound(wait, 0, 2 * DELAY);
        h.gPropose(dom, rec, approved);
        vm.warp(block.timestamp + wait);
        if (wait < DELAY) {
            vm.expectRevert();
            h.gConfirm(dom, rec);
            assertFalse(h.approvedRR(dom, rec));
        } else {
            h.gConfirm(dom, rec);
            assertEq(h.approvedRR(dom, rec), approved);
        }
    }

    function testFuzz_Reg_TimelockBoundary(address cur, address proposed, uint256 wait) public {
        vm.assume(proposed != address(0));
        wait = bound(wait, 0, 2 * DELAY);
        h.rPropose(cur, proposed);
        vm.warp(block.timestamp + wait);
        uint256 delay = cur == address(0) ? 0 : DELAY;
        if (wait < delay) {
            vm.expectRevert();
            h.rConfirm();
        } else {
            assertEq(h.rConfirm(), proposed);
        }
    }
}
