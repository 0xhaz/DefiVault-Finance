// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AutonomousVault} from "../AutonomousVault.sol";
import {TaskMBase} from "./TaskMTest.Base.t.sol";

/// @title TaskMTest.Settle — atomic settlement accounting, fees, rollback, positions and write-off.
contract TaskMSettleTest is TaskMBase {
    struct Snap {
        uint256 vaultBal;
        uint256 supply;
        uint256 pending;
        uint256 totalPending;
        uint256 totalDeployed;
        uint256 totalAssets;
        bool consumed;
        uint256 transmitterCalls;
    }

    function _snap(uint64 id, uint32 src, bytes32 nonce) internal view returns (Snap memory s) {
        s.vaultBal = usdc.balanceOf(address(vault));
        s.supply = usdc.totalSupply();
        s.pending = vault.pendingCrossChain(id);
        s.totalPending = vault.totalPendingCrossChain();
        s.totalDeployed = vault.totalDeployed();
        s.totalAssets = vault.totalAssets();
        s.consumed = vault.consumedInbound(src, nonce);
        s.transmitterCalls = transmitter.calls();
    }

    function _assertSame(Snap memory a, Snap memory b) internal pure {
        assertEq(a.vaultBal, b.vaultBal, "vault balance rolled back");
        assertEq(a.supply, b.supply, "token supply rolled back");
        assertEq(a.pending, b.pending, "pending rolled back");
        assertEq(a.totalPending, b.totalPending, "totalPending rolled back");
        assertEq(a.totalDeployed, b.totalDeployed, "totalDeployed rolled back");
        assertEq(a.totalAssets, b.totalAssets, "NAV rolled back");
        assertEq(a.consumed, b.consumed, "replay consumption rolled back");
        assertEq(a.transmitterCalls, b.transmitterCalls, "transmitter call rolled back");
    }

    function _settleExpectRevert(uint64 id, Msg memory m, bytes memory err) internal {
        bytes memory message = _encode(m);
        vm.prank(manager);
        vm.expectRevert(err);
        vault.settleCrossChainWithMessage(id, message, hex"a77e57");
    }

    // ───────────── fee cases ─────────────

    function test_settle_zeroFee_booksFullAmount_noFeeEvent() public {
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        uint256 navBefore = vault.totalAssets();
        assertEq(navBefore, DEPOSIT, "NAV neutral while in flight");
        assertEq(usdc.balanceOf(address(vault)), DEPOSIT - SENT);

        vm.recordLogs();
        _settle(id, _msg(SENT, 0, NONCE), SENT);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countLogs(logs, address(vault), AutonomousVault.CrossChainFeeDeducted.selector), 0);
        assertEq(_countLogs(logs, address(vault), AutonomousVault.CrossChainSettled.selector), 1);

        assertEq(usdc.balanceOf(address(vault)), DEPOSIT);
        assertEq(vault.totalDeployed(), 0);
        assertEq(vault.totalPendingCrossChain(), 0);
        assertEq(vault.pendingCrossChain(id), 0);
        assertEq(vault.pendingCrossChainDestinationDomain(id), 0);
        assertEq(vault.totalAssets(), DEPOSIT);
        assertTrue(vault.consumedInbound(REMOTE_DOMAIN, NONCE));
    }

    function test_settle_zeroFee_emitsSettledWithZeroShortfall() public {
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        transmitter.arm(address(vault), SENT);
        vm.expectEmit(true, false, false, true, address(vault));
        emit AutonomousVault.CrossChainSettled(id, SENT, 0);
        _settleArmed(id, _msg(SENT, 0, NONCE));
    }

    function test_settle_nonzeroFee_emitsFeeThenSettled_andNavDropsByFee() public {
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        uint256 fee = 5e6;
        transmitter.arm(address(vault), SENT - fee);
        vm.expectEmit(true, false, false, true, address(vault));
        emit AutonomousVault.CrossChainFeeDeducted(id, fee);
        vm.expectEmit(true, false, false, true, address(vault));
        emit AutonomousVault.CrossChainSettled(id, SENT - fee, fee);
        _settleArmed(id, _msg(SENT, fee, NONCE));

        assertEq(usdc.balanceOf(address(vault)), DEPOSIT - fee);
        assertEq(vault.totalAssets(), DEPOSIT - fee);
        assertEq(vault.totalDeployed(), 0);
        assertEq(vault.totalPendingCrossChain(), 0);
    }

    function test_settle_maxFeeInMessageDiffersFromFeeExecuted_usesFeeExecuted() public {
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        Msg memory m = _msg(SENT, 3e6, NONCE);
        m.maxFee = 20e6; // authorised ceiling, not what was charged
        transmitter.arm(address(vault), SENT - 3e6);
        vm.expectEmit(true, false, false, true, address(vault));
        emit AutonomousVault.CrossChainFeeDeducted(id, 3e6);
        vm.expectEmit(true, false, false, true, address(vault));
        emit AutonomousVault.CrossChainSettled(id, SENT - 3e6, 3e6);
        _settleArmed(id, m);
        assertEq(vault.totalAssets(), DEPOSIT - 3e6);
    }

    function test_settle_strategyLossPlusFee_shortfallIsLossAndFee() public {
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        uint256 returned = 9_000e6; // strategy lost 1_000 on the remote side
        uint256 fee = 4e6;
        transmitter.arm(address(vault), returned - fee);
        vm.expectEmit(true, false, false, true, address(vault));
        emit AutonomousVault.CrossChainFeeDeducted(id, fee);
        vm.expectEmit(true, false, false, true, address(vault));
        emit AutonomousVault.CrossChainSettled(id, returned - fee, SENT - (returned - fee));
        _settleArmed(id, _msg(returned, fee, NONCE));
        assertEq(vault.totalAssets(), DEPOSIT - 1_000e6 - fee);
        assertEq(vault.totalDeployed(), 0);
    }

    function test_settle_gain_zeroShortfall_navRises() public {
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        transmitter.arm(address(vault), 11_000e6);
        vm.expectEmit(true, false, false, true, address(vault));
        emit AutonomousVault.CrossChainSettled(id, 11_000e6, 0);
        _settleArmed(id, _msg(11_000e6, 0, NONCE));
        assertEq(vault.totalAssets(), DEPOSIT + 1_000e6);
    }

    function test_settle_feeExceedsAmount_expectedNetZero_booksFullLoss() public {
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        transmitter.arm(address(vault), 0);
        vm.expectEmit(true, false, false, true, address(vault));
        emit AutonomousVault.CrossChainFeeDeducted(id, 10);
        vm.expectEmit(true, false, false, true, address(vault));
        emit AutonomousVault.CrossChainSettled(id, 0, SENT);
        _settleArmed(id, _msg(5, 10, NONCE));
        assertEq(vault.pendingCrossChain(id), 0);
        assertEq(vault.totalAssets(), DEPOSIT - SENT);
    }

    function testFuzz_settle_netDeltaDrivesAccounting(uint256 returned, uint256 fee) public {
        returned = bound(returned, 1, 1_000_000e6);
        fee = bound(fee, 0, returned);
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        uint256 net = returned - fee;
        _settle(id, _msg(returned, fee, NONCE), net);
        assertEq(usdc.balanceOf(address(vault)), DEPOSIT - SENT + net);
        assertEq(vault.totalAssets(), DEPOSIT - SENT + net);
        assertEq(vault.totalDeployed(), 0);
        assertEq(vault.totalPendingCrossChain(), 0);
    }

    function test_settle_donationBeforeSettle_doesNotAffectDeltaCheck() public {
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        usdc.mint(address(vault), 7e6); // donation: raises balBefore, not the mint delta
        _settle(id, _msg(SENT, 0, NONCE), SENT);
        assertEq(vault.totalAssets(), DEPOSIT + 7e6);
    }

    // ───────────── rollback paths ─────────────

    function test_rollback_mismatch_mintedTooMuch() public {
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        Snap memory before_ = _snap(id, REMOTE_DOMAIN, NONCE);
        transmitter.arm(address(vault), SENT + 1);
        _settleExpectRevert(
            id, _msg(SENT, 0, NONCE), abi.encodeWithSelector(AutonomousVault.MessageAmountMismatch.selector, SENT, SENT + 1)
        );
        _assertSame(before_, _snap(id, REMOTE_DOMAIN, NONCE));
    }

    function test_rollback_mismatch_feeIgnoredByTransmitter() public {
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        Snap memory before_ = _snap(id, REMOTE_DOMAIN, NONCE);
        transmitter.arm(address(vault), SENT); // minted gross although feeExecuted = 5
        _settleExpectRevert(
            id,
            _msg(SENT, 5e6, NONCE),
            abi.encodeWithSelector(AutonomousVault.MessageAmountMismatch.selector, SENT - 5e6, SENT)
        );
        _assertSame(before_, _snap(id, REMOTE_DOMAIN, NONCE));
    }

    function test_rollback_failedMint_mintedToWrongAddress() public {
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        Snap memory before_ = _snap(id, REMOTE_DOMAIN, NONCE);
        transmitter.arm(alice, SENT); // vault never receives
        _settleExpectRevert(
            id, _msg(SENT, 0, NONCE), abi.encodeWithSelector(AutonomousVault.MessageAmountMismatch.selector, SENT, 0)
        );
        _assertSame(before_, _snap(id, REMOTE_DOMAIN, NONCE));
    }

    function test_rollback_falseReceive_afterMint() public {
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        Snap memory before_ = _snap(id, REMOTE_DOMAIN, NONCE);
        transmitter.setRet(false);
        transmitter.arm(address(vault), SENT); // would have minted, but receive reports failure
        _settleExpectRevert(id, _msg(SENT, 0, NONCE), abi.encodeWithSelector(AutonomousVault.MessageReceiveFailed.selector));
        _assertSame(before_, _snap(id, REMOTE_DOMAIN, NONCE));
    }

    function test_rollback_transmitterReverts_bubblesAndRollsBack() public {
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        Snap memory before_ = _snap(id, REMOTE_DOMAIN, NONCE);
        transmitter.setRevert(true);
        _settleExpectRevert(id, _msg(SENT, 0, NONCE), abi.encodeWithSignature("Error(string)", "transmitter: boom"));
        _assertSame(before_, _snap(id, REMOTE_DOMAIN, NONCE));
    }

    function test_rollback_thenRetrySucceeds_sameNonce() public {
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        transmitter.setRet(false);
        transmitter.arm(address(vault), SENT);
        _settleExpectRevert(id, _msg(SENT, 0, NONCE), abi.encodeWithSelector(AutonomousVault.MessageReceiveFailed.selector));
        assertFalse(vault.consumedInbound(REMOTE_DOMAIN, NONCE));

        transmitter.setRet(true);
        _settle(id, _msg(SENT, 0, NONCE), SENT);
        assertTrue(vault.consumedInbound(REMOTE_DOMAIN, NONCE));
        assertEq(usdc.balanceOf(address(vault)), DEPOSIT);
    }

    function test_receiveMessage_gets_exactMessageAndAttestation() public {
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        Msg memory m = _msg(SENT, 0, NONCE);
        _settle(id, m, SENT);
        assertEq(transmitter.lastMsgHash(), keccak256(_encode(m)));
        assertEq(transmitter.lastAttHash(), keccak256(hex"a77e57"));
        assertEq(transmitter.calls(), 1);
    }

    // ───────────── positions ─────────────

    function test_positionIds_sequential_matchCounterAndEvent() public {
        uint256[3] memory amounts = [uint256(1_000e6), 2_000e6, 3_000e6];
        uint32[3] memory domains = [REMOTE_DOMAIN, OTHER_DOMAIN, REMOTE_DOMAIN];
        assertEq(vault.crossChainPositionCounter(), 0);
        uint256 running;
        for (uint64 i = 0; i < 3; i++) {
            vm.expectEmit(true, true, false, true, address(vault));
            emit AutonomousVault.CapitalDeployedCrossChain(
                domains[i], _b32(remoteRecipientAddr), amounts[i], i + 1
            );
            uint64 id = _deploy(domains[i], amounts[i]);
            assertEq(id, i + 1);
            assertEq(vault.crossChainPositionCounter(), i + 1);
            assertEq(vault.pendingCrossChain(id), amounts[i]);
            assertEq(vault.pendingCrossChainDestinationDomain(id), domains[i]);
            running += amounts[i];
            assertEq(vault.totalPendingCrossChain(), running);
            assertEq(vault.totalDeployed(), running);
        }
    }

    function test_settle_oneOfSeveral_leavesOthersUntouched() public {
        uint64 id1 = _deploy(REMOTE_DOMAIN, 1_000e6);
        uint64 id2 = _deploy(OTHER_DOMAIN, 2_000e6);
        uint64 id3 = _deploy(REMOTE_DOMAIN, 3_000e6);
        vm.prank(owner);
        vault.setRemoteTokenMessenger(OTHER_DOMAIN, _b32(remoteMessengerAddr));
        Msg memory m = _msg(2_000e6, 0, NONCE);
        m.sourceDomain = OTHER_DOMAIN;
        _settle(id2, m, 2_000e6);

        assertEq(vault.pendingCrossChain(id1), 1_000e6);
        assertEq(vault.pendingCrossChain(id2), 0);
        assertEq(vault.pendingCrossChain(id3), 3_000e6);
        assertEq(vault.pendingCrossChainDestinationDomain(id1), REMOTE_DOMAIN);
        assertEq(vault.pendingCrossChainDestinationDomain(id3), REMOTE_DOMAIN);
        assertEq(vault.totalPendingCrossChain(), 4_000e6);
        assertEq(vault.totalDeployed(), 4_000e6);
        assertEq(vault.crossChainPositionCounter(), 3, "counter never decrements");
    }

    function test_settle_sameIdTwice_revertsNonceMismatch() public {
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        _settle(id, _msg(SENT, 0, NONCE), SENT);
        bytes memory message = _encode(_msg(SENT, 0, bytes32(uint256(2))));
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.NonceMismatch.selector, id, uint64(0)));
        vault.settleCrossChainWithMessage(id, message, "");
    }

    function test_settle_idNeverDeployed_revertsNonceMismatch() public {
        _deploy(REMOTE_DOMAIN, SENT);
        bytes memory message = _encode(_msg(SENT, 0, NONCE));
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.NonceMismatch.selector, uint64(2), uint64(0)));
        vault.settleCrossChainWithMessage(2, message, "");
    }

    // ───────────── owner-only zero-value write-off ─────────────

    function test_writeOff_ownerOnly_booksFullLoss_andEmits() public {
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        vm.expectEmit(true, false, false, true, address(vault));
        emit AutonomousVault.CrossChainSettled(id, 0, SENT);
        vm.prank(owner);
        vault.settleCrossChain(id, 0);
        assertEq(vault.pendingCrossChain(id), 0);
        assertEq(vault.pendingCrossChainDestinationDomain(id), 0);
        assertEq(vault.totalPendingCrossChain(), 0);
        assertEq(vault.totalDeployed(), 0);
        assertEq(vault.totalAssets(), DEPOSIT - SENT);
    }

    function test_writeOff_managerAndStrangerRejected() public {
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, manager));
        vault.settleCrossChain(id, 0);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.settleCrossChain(id, 0);
        assertEq(vault.pendingCrossChain(id), SENT);
    }

    function test_writeOff_nonZeroReceived_reverts_beforeUnknownIdCheck() public {
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        vm.startPrank(owner);
        vm.expectRevert(AutonomousVault.WriteOffMustBeZero.selector);
        vault.settleCrossChain(id, 1);
        vm.expectRevert(AutonomousVault.WriteOffMustBeZero.selector);
        vault.settleCrossChain(999, 1);
        vm.stopPrank();
    }

    function test_writeOff_unknownOrAlreadySettled_revertsNonceMismatch() public {
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.NonceMismatch.selector, uint64(42), uint64(0)));
        vault.settleCrossChain(42, 0);
        vault.settleCrossChain(id, 0);
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.NonceMismatch.selector, id, uint64(0)));
        vault.settleCrossChain(id, 0);
        vm.stopPrank();
    }

    function test_writeOff_doesNotConsumeAnyInboundKey_andLateMessageCannotSettleIt() public {
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        vm.prank(owner);
        vault.settleCrossChain(id, 0);
        assertFalse(vault.consumedInbound(REMOTE_DOMAIN, NONCE));
        bytes memory message = _encode(_msg(SENT, 0, NONCE));
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.NonceMismatch.selector, id, uint64(0)));
        vault.settleCrossChainWithMessage(id, message, "");
    }
}
