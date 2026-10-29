// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AutonomousVault, CctpMessageDecoder} from "../AutonomousVault.sol";
import {TaskMBase, MockTransmitterM} from "./TaskMTest.Base.t.sol";

/// @title TaskMTest.Validation — native CCTP V2 inbound validation order, replay and decoder bounds.
contract TaskMValidationTest is TaskMBase {
    bytes32 internal constant BAD = bytes32(uint256(0xBAD));

    function _expectSettleRevert(uint64 id, Msg memory m, bytes memory err) internal {
        bytes memory message = _encode(m);
        vm.prank(manager);
        vm.expectRevert(err);
        vault.settleCrossChainWithMessage(id, message, "");
    }

    function _truncate(bytes memory b, uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i = 0; i < n; i++) out[i] = b[i];
    }

    // ───────────── precedence of pre-message checks ─────────────

    function test_unknownPositionId_revertsNonceMismatch_beforeAnyMessageDecoding() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.NonceMismatch.selector, uint64(99), uint64(0)));
        vault.settleCrossChainWithMessage(99, hex"", hex"");
    }

    function test_positionIdZero_revertsNonceMismatch() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.NonceMismatch.selector, uint64(0), uint64(0)));
        vault.settleCrossChainWithMessage(0, hex"", hex"");
    }

    function test_transmitterUnset_revertsCrossChainNotConfigured_beforeDecoding() public {
        vm.startPrank(owner);
        AutonomousVault v2 = new AutonomousVault(IERC20(address(usdc)), owner, LOCAL_DOMAIN);
        v2.setManager(manager);
        v2.setTokenMessenger(address(messenger));
        v2.setMaxAllocationBps(9_000);
        v2.setMaxPendingCrossChainBps(5_000);
        vm.stopPrank();
        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(v2), 1_000e6);
        v2.deposit(1_000e6, alice);
        vm.stopPrank();
        vm.prank(manager);
        v2.deployCrossChain(REMOTE_DOMAIN, _b32(alice), 100e6);
        vm.prank(manager);
        vm.expectRevert(AutonomousVault.CrossChainNotConfigured.selector);
        v2.settleCrossChainWithMessage(1, hex"", hex"");
    }

    function test_onlyManagerOrOwner_canSettle() public {
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        bytes memory message = _encode(_msg(SENT, 0, NONCE));
        vm.prank(stranger);
        vm.expectRevert(AutonomousVault.NotManager.selector);
        vault.settleCrossChainWithMessage(id, message, "");

        transmitter.arm(address(vault), SENT);
        vm.prank(owner);
        vault.settleCrossChainWithMessage(id, message, "");
        assertEq(vault.pendingCrossChain(id), 0);
    }

    // ───────────── full validation order (each step fixes exactly one field) ─────────────

    function test_validationOrder_headerVersion_destDomain_sourceDomain_recipient_caller_remote_body_mint() public {
        uint64 id = _deploy(OTHER_DOMAIN, SENT); // no remote messenger registered for domain 7
        Msg memory m = _msg(SENT, 0, NONCE);
        m.headerVersion = 2;
        m.destinationDomain = 99;
        m.sourceDomain = 55;
        m.recipient = BAD;
        m.destinationCaller = BAD;
        m.sender = BAD;
        m.bodyVersion = 2;
        m.mintRecipient = BAD;

        // 1. header version
        _expectSettleRevert(id, m, abi.encodeWithSelector(CctpMessageDecoder.WrongHeaderVersion.selector, uint32(2)));
        m.headerVersion = 1;
        // 2. local destination domain
        _expectSettleRevert(id, m, abi.encodeWithSelector(AutonomousVault.WrongDestinationDomain.selector, LOCAL_DOMAIN, uint32(99)));
        m.destinationDomain = LOCAL_DOMAIN;
        // 3. recorded source domain
        _expectSettleRevert(id, m, abi.encodeWithSelector(AutonomousVault.WrongSourceDomain.selector, OTHER_DOMAIN, uint32(55)));
        m.sourceDomain = OTHER_DOMAIN;
        // 4. local messenger recipient
        _expectSettleRevert(id, m, abi.encodeWithSelector(AutonomousVault.WrongMessageRecipient.selector, BAD));
        m.recipient = _b32(address(messenger));
        // 5. destinationCaller must be exactly the vault
        _expectSettleRevert(id, m, abi.encodeWithSelector(AutonomousVault.WrongDestinationCaller.selector, BAD));
        m.destinationCaller = _b32(address(vault));
        // 6. remote messenger not registered for the source domain
        _expectSettleRevert(id, m, abi.encodeWithSelector(AutonomousVault.RemoteMessengerNotSet.selector, OTHER_DOMAIN));
        vm.prank(owner);
        vault.setRemoteTokenMessenger(OTHER_DOMAIN, _b32(remoteMessengerAddr));
        // 7. registered remote messenger != message sender
        _expectSettleRevert(
            id, m, abi.encodeWithSelector(AutonomousVault.WrongRemoteSender.selector, _b32(remoteMessengerAddr), BAD)
        );
        m.sender = _b32(remoteMessengerAddr);
        // 8. body version
        _expectSettleRevert(id, m, abi.encodeWithSelector(CctpMessageDecoder.WrongBodyVersion.selector, uint32(2)));
        m.bodyVersion = 1;
        // 9. vault mintRecipient
        _expectSettleRevert(id, m, abi.encodeWithSelector(AutonomousVault.WrongMintRecipient.selector, BAD));
        m.mintRecipient = _b32(address(vault));

        // 10. everything valid -> settles and nothing was consumed by the failed attempts
        assertFalse(vault.consumedInbound(OTHER_DOMAIN, NONCE));
        _settle(id, m, SENT);
        assertTrue(vault.consumedInbound(OTHER_DOMAIN, NONCE));
        assertEq(vault.pendingCrossChain(id), 0);
    }

    // Remote strategies MUST burn with destinationCaller = this vault so third parties cannot pre-consume the message.
    function test_destinationCaller_onlyVaultAccepted_zeroAndOthersRejected() public {
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        Msg memory m = _msg(SENT, 0, bytes32(uint256(1)));

        m.destinationCaller = bytes32(0);
        _expectSettleRevert(id, m, abi.encodeWithSelector(AutonomousVault.WrongDestinationCaller.selector, bytes32(0)));

        m.destinationCaller = _b32(stranger);
        _expectSettleRevert(id, m, abi.encodeWithSelector(AutonomousVault.WrongDestinationCaller.selector, _b32(stranger)));

        m.destinationCaller = _b32(address(messenger));
        _expectSettleRevert(id, m, abi.encodeWithSelector(AutonomousVault.WrongDestinationCaller.selector, _b32(address(messenger))));

        assertEq(vault.totalPendingCrossChain(), SENT);
        m.destinationCaller = _b32(address(vault));
        _settle(id, m, SENT);
        assertEq(vault.totalPendingCrossChain(), 0);
    }

    function test_wrongRecipient_localMessengerOnly() public {
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        Msg memory m = _msg(SENT, 0, NONCE);
        m.recipient = _b32(address(vault)); // vault is not the local TokenMessenger
        _expectSettleRevert(id, m, abi.encodeWithSelector(AutonomousVault.WrongMessageRecipient.selector, _b32(address(vault))));
    }

    function test_sourceDomain_mustMatchPositionDestination() public {
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        vm.prank(owner);
        vault.setRemoteTokenMessenger(OTHER_DOMAIN, _b32(remoteMessengerAddr));
        Msg memory m = _msg(SENT, 0, NONCE);
        m.sourceDomain = OTHER_DOMAIN; // valid remote, but not the domain this position was sent to
        _expectSettleRevert(id, m, abi.encodeWithSelector(AutonomousVault.WrongSourceDomain.selector, REMOTE_DOMAIN, OTHER_DOMAIN));
    }

    // ───────────── body checks precede replay; replay precedes receiveMessage ─────────────

    function test_bodyChecks_precedeReplay_andReplayPrecedesReceive() public {
        uint64 id1 = _deploy(REMOTE_DOMAIN, SENT);
        uint64 id2 = _deploy(REMOTE_DOMAIN, SENT);
        _settle(id1, _msg(SENT, 0, NONCE), SENT);
        assertTrue(vault.consumedInbound(REMOTE_DOMAIN, NONCE));

        Msg memory m = _msg(SENT, 0, NONCE); // replayed nonce for position 2
        m.bodyVersion = 2;
        _expectSettleRevert(id2, m, abi.encodeWithSelector(CctpMessageDecoder.WrongBodyVersion.selector, uint32(2)));
        m.bodyVersion = 1;
        m.mintRecipient = BAD;
        _expectSettleRevert(id2, m, abi.encodeWithSelector(AutonomousVault.WrongMintRecipient.selector, BAD));
        m.mintRecipient = _b32(address(vault));

        // Replay is rejected before the transmitter is ever invoked (even if it would return false).
        transmitter.setRet(false);
        uint256 callsBefore = transmitter.calls();
        _expectSettleRevert(id2, m, abi.encodeWithSelector(AutonomousVault.InboundAlreadyConsumed.selector));
        assertEq(transmitter.calls(), callsBefore);
        assertEq(vault.pendingCrossChain(id2), SENT);
    }

    // ───────────── 32-byte nonce high bits ─────────────

    function test_nonce_highBitsPreserved_distinctNoncesSettleDistinctPositions() public {
        bytes32 n1 = bytes32(uint256(1));
        bytes32 n2 = bytes32(uint256(1) | (uint256(0xAA) << 248));
        bytes32 n3 = bytes32(uint256(1) | (uint256(0xBB) << 128)); // differ only in the middle
        uint64 id1 = _deploy(REMOTE_DOMAIN, SENT);
        uint64 id2 = _deploy(REMOTE_DOMAIN, SENT);
        uint64 id3 = _deploy(REMOTE_DOMAIN, SENT);

        _settle(id1, _msg(SENT, 0, n1), SENT);
        assertTrue(vault.consumedInbound(REMOTE_DOMAIN, n1));
        assertFalse(vault.consumedInbound(REMOTE_DOMAIN, n2), "high-bit-only variant must be distinct");
        assertFalse(vault.consumedInbound(REMOTE_DOMAIN, n3));

        _settle(id2, _msg(SENT, 0, n2), SENT);
        _settle(id3, _msg(SENT, 0, n3), SENT);
        assertTrue(vault.consumedInbound(REMOTE_DOMAIN, n2));
        assertTrue(vault.consumedInbound(REMOTE_DOMAIN, n3));
        assertEq(vault.totalPendingCrossChain(), 0);
    }

    function test_nonce_consumedKeyCannotSettleAnotherPosition() public {
        uint64 id1 = _deploy(REMOTE_DOMAIN, SENT);
        uint64 id2 = _deploy(REMOTE_DOMAIN, 4_000e6);
        _settle(id1, _msg(SENT, 0, NONCE), SENT);
        // Same inbound key presented for position 2 is a replay.
        transmitter.arm(address(vault), 4_000e6);
        bytes memory message = _encode(_msg(4_000e6, 0, NONCE));
        vm.prank(manager);
        vm.expectRevert(AutonomousVault.InboundAlreadyConsumed.selector);
        vault.settleCrossChainWithMessage(id2, message, "");
        assertEq(vault.pendingCrossChain(id2), 4_000e6);
        assertEq(vault.totalPendingCrossChain(), 4_000e6);
    }

    function test_nonce_sameValueDifferentSourceDomain_isIndependentKey() public {
        vm.prank(owner);
        vault.setRemoteTokenMessenger(OTHER_DOMAIN, _b32(remoteMessengerAddr));
        uint64 id1 = _deploy(REMOTE_DOMAIN, SENT);
        uint64 id2 = _deploy(OTHER_DOMAIN, SENT);
        _settle(id1, _msg(SENT, 0, NONCE), SENT);
        Msg memory m = _msg(SENT, 0, NONCE);
        m.sourceDomain = OTHER_DOMAIN;
        _settle(id2, m, SENT);
        assertTrue(vault.consumedInbound(REMOTE_DOMAIN, NONCE));
        assertTrue(vault.consumedInbound(OTHER_DOMAIN, NONCE));
    }

    function testFuzz_nonce_anyTwoDistinctNonces_bothConsumable(bytes32 a, bytes32 b) public {
        vm.assume(a != b);
        uint64 id1 = _deploy(REMOTE_DOMAIN, SENT);
        uint64 id2 = _deploy(REMOTE_DOMAIN, SENT);
        _settle(id1, _msg(SENT, 0, a), SENT);
        assertTrue(vault.consumedInbound(REMOTE_DOMAIN, a));
        assertFalse(vault.consumedInbound(REMOTE_DOMAIN, b));
        _settle(id2, _msg(SENT, 0, b), SENT);
        assertTrue(vault.consumedInbound(REMOTE_DOMAIN, b));
    }

    // ───────────── decoder bounds ─────────────

    function test_decoder_exact376Bytes_passes() public {
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        Msg memory m = _msg(SENT, 0, NONCE);
        assertEq(_encode(m).length, 376);
        _settle(id, m, SENT);
        assertEq(vault.pendingCrossChain(id), 0);
    }

    function test_decoder_trailingHookData_passes() public {
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        Msg memory m = _msg(SENT, 0, NONCE);
        m.hookData = hex"deadbeefcafebabe0102030405060708090a0b0c0d0e0f10";
        assertEq(_encode(m).length, 376 + 24);
        _settle(id, m, SENT);
        assertEq(vault.pendingCrossChain(id), 0);
        assertEq(transmitter.lastMsgHash(), keccak256(_encode(m)), "full message incl. hook forwarded");
    }

    function test_decoder_375Bytes_revertsInvalidMessageRange() public {
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        bytes memory cut = _truncate(_encode(_msg(SENT, 0, NONCE)), 375);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CctpMessageDecoder.InvalidMessageRange.selector, 375, 0, 376));
        vault.settleCrossChainWithMessage(id, cut, "");
        assertEq(vault.pendingCrossChain(id), SENT);
    }

    function test_decoder_headerOnly148Bytes_failsAtBodyBound() public {
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        bytes memory cut = _truncate(_encode(_msg(SENT, 0, NONCE)), 148);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CctpMessageDecoder.InvalidMessageRange.selector, 148, 0, 376));
        vault.settleCrossChainWithMessage(id, cut, "");
    }

    function test_decoder_headerShorterThan148_reverts() public {
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        bytes memory full = _encode(_msg(SENT, 0, NONCE));
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CctpMessageDecoder.InvalidMessageRange.selector, 147, 0, 148));
        vault.settleCrossChainWithMessage(id, _truncate(full, 147), "");
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CctpMessageDecoder.InvalidMessageRange.selector, 0, 0, 148));
        vault.settleCrossChainWithMessage(id, "", "");
    }

    function testFuzz_decoder_anyLengthBelow376_reverts(uint256 len) public {
        len = bound(len, 148, 375);
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        bytes memory cut = _truncate(_encode(_msg(SENT, 0, NONCE)), len);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CctpMessageDecoder.InvalidMessageRange.selector, len, 0, 376));
        vault.settleCrossChainWithMessage(id, cut, "");
    }

    function testFuzz_decoder_wrongHeaderVersion_reverts(uint32 v) public {
        vm.assume(v != 1);
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        Msg memory m = _msg(SENT, 0, NONCE);
        m.headerVersion = v;
        _expectSettleRevert(id, m, abi.encodeWithSelector(CctpMessageDecoder.WrongHeaderVersion.selector, v));
    }

    function testFuzz_decoder_wrongBodyVersion_reverts(uint32 v) public {
        vm.assume(v != 1);
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        Msg memory m = _msg(SENT, 0, NONCE);
        m.bodyVersion = v;
        _expectSettleRevert(id, m, abi.encodeWithSelector(CctpMessageDecoder.WrongBodyVersion.selector, v));
    }

    function test_decoder_headerVersionZeroAndTwo_revert() public {
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        Msg memory m = _msg(SENT, 0, NONCE);
        m.headerVersion = 0;
        _expectSettleRevert(id, m, abi.encodeWithSelector(CctpMessageDecoder.WrongHeaderVersion.selector, uint32(0)));
        m.headerVersion = 2;
        _expectSettleRevert(id, m, abi.encodeWithSelector(CctpMessageDecoder.WrongHeaderVersion.selector, uint32(2)));
    }

    // ───────────── local domain resolution ─────────────

    function test_localDomain_transmitterReportedValueIsLive() public {
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        transmitter.setDomain(30); // transmitter now reports 30; stored value is stale
        Msg memory m = _msg(SENT, 0, NONCE);
        _expectSettleRevert(id, m, abi.encodeWithSelector(AutonomousVault.WrongDestinationDomain.selector, uint32(30), LOCAL_DOMAIN));
        m.destinationDomain = 30;
        _settle(id, m, SENT);
        assertEq(vault.pendingCrossChain(id), 0);
    }

    function test_localDomain_fallbackToStoredWhenTransmitterLacksLocalDomain() public {
        MockTransmitterM plain = new MockTransmitterM(usdc);
        vm.prank(owner);
        vault.setMessageTransmitter(address(plain));
        assertEq(vault.localDomain(), LOCAL_DOMAIN, "fallback to constructor sourceDomain");
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        Msg memory m = _msg(SENT, 0, NONCE);
        m.destinationDomain = 5;
        _expectSettleRevert(id, m, abi.encodeWithSelector(AutonomousVault.WrongDestinationDomain.selector, LOCAL_DOMAIN, uint32(5)));
        m.destinationDomain = LOCAL_DOMAIN;
        plain.arm(address(vault), SENT);
        bytes memory message = _encode(m);
        vm.prank(manager);
        vault.settleCrossChainWithMessage(id, message, "");
        assertEq(vault.pendingCrossChain(id), 0);
    }

    function test_localDomain_zeroIsValid_forInboundDestination() public {
        transmitter.setDomain(0);
        vm.prank(owner);
        vault.setMessageTransmitter(address(transmitter)); // refresh stored domain from transmitter
        assertEq(vault.localDomain(), 0);
        uint64 id = _deploy(REMOTE_DOMAIN, SENT);
        Msg memory m = _msg(SENT, 0, NONCE);
        _expectSettleRevert(id, m, abi.encodeWithSelector(AutonomousVault.WrongDestinationDomain.selector, uint32(0), LOCAL_DOMAIN));
        m.destinationDomain = 0;
        _settle(id, m, SENT);
        assertEq(vault.pendingCrossChain(id), 0);
    }
}
