// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CctpSettlementLogic, CctpMessageDecoder, AutonomousVault} from "../AutonomousVault.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {LibTestBase, MockTransmitter, MockMessenger} from "./LibraryTests.Base.t.sol";

abstract contract CctpBase is LibTestBase {
    event CrossChainFeeDeducted(uint64 indexed positionId, uint256 feeExecuted);

    uint32 internal constant LOCAL = 26;
    uint32 internal constant SRC = 6;
    uint32 internal constant FALLBACK = 99;
    bytes32 internal constant NONCE = bytes32(uint256(0x1234));
    bytes32 internal constant REMOTE = bytes32(uint256(0xABCDEF));

    MockTransmitter internal tx_;
    MockMessenger internal messenger;
    MockERC20 internal usdc;

    function setUp() public virtual override {
        super.setUp();
        tx_ = new MockTransmitter();
        tx_.setDomain(0, LOCAL);
        messenger = new MockMessenger();
        usdc = new MockERC20("USDC", "USDC", 6);
        h.setRemote(SRC, REMOTE);
    }

    function _cfg() internal view returns (CctpSettlementLogic.Config memory c) {
        c = CctpSettlementLogic.Config({
            asset: address(usdc),
            transmitter: address(tx_),
            messenger: address(messenger),
            fallbackDomain: FALLBACK,
            expectedSource: SRC
        });
    }

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    struct H {
        uint32 version;
        uint32 src;
        uint32 dst;
        bytes32 nonce;
        bytes32 sender;
        bytes32 recipient;
        bytes32 caller;
    }

    function _goodH() internal view returns (H memory x) {
        x = H(1, SRC, LOCAL, NONCE, REMOTE, _b32(address(messenger)), _b32(address(h)));
    }

    function _header(H memory x) internal pure returns (bytes memory) {
        return abi.encodePacked(x.version, x.src, x.dst, x.nonce, x.sender, x.recipient, x.caller, uint32(0), uint32(0));
    }

    function _body(uint32 version, bytes32 mintRecipient, uint256 amount, uint256 fee)
        internal pure returns (bytes memory)
    {
        return abi.encodePacked(
            version, bytes32(0), mintRecipient, amount, bytes32(0), uint256(0), fee, uint256(0)
        );
    }

    function _msg(H memory x, uint256 amount, uint256 fee) internal view returns (bytes memory) {
        return abi.encodePacked(_header(x), _body(1, _b32(address(h)), amount, fee));
    }
}

contract LibraryCctpValidateTest is CctpBase {
    function test_HeaderLayoutIs148Bytes() public view {
        assertEq(_header(_goodH()).length, 148);
        assertEq(_msg(_goodH(), 1, 0).length, 148 + 228);
    }

    function test_Validate_ValidHeaderPasses() public view {
        h.validate(_cfg(), _header(_goodH()));
    }

    function test_Validate_ValidFullMessagePasses() public view {
        h.validate(_cfg(), _msg(_goodH(), 5, 1));
    }

    function test_Validate_HeaderTooShortReverts() public {
        bytes memory m = _header(_goodH());
        for (uint256 len = 0; len < 148; len += 37) {
            bytes memory s = new bytes(len);
            for (uint256 i; i < len; ++i) s[i] = m[i];
            vm.expectRevert(abi.encodeWithSelector(CctpMessageDecoder.InvalidMessageRange.selector, len, 0, 148));
            h.validate(_cfg(), s);
        }
    }

    function test_Validate_OneByteShortReverts() public {
        bytes memory m = _header(_goodH());
        bytes memory s = new bytes(147);
        for (uint256 i; i < 147; ++i) s[i] = m[i];
        vm.expectRevert(abi.encodeWithSelector(CctpMessageDecoder.InvalidMessageRange.selector, 147, 0, 148));
        h.validate(_cfg(), s);
    }

    function test_Validate_TrailingBytesAreIgnored() public view {
        h.validate(_cfg(), abi.encodePacked(_header(_goodH()), hex"deadbeef"));
    }

    function test_Validate_WrongHeaderVersion() public {
        H memory x = _goodH();
        x.version = 2;
        vm.expectRevert(abi.encodeWithSelector(CctpMessageDecoder.WrongHeaderVersion.selector, uint32(2)));
        h.validate(_cfg(), _header(x));
        x.version = 0;
        vm.expectRevert(abi.encodeWithSelector(CctpMessageDecoder.WrongHeaderVersion.selector, uint32(0)));
        h.validate(_cfg(), _header(x));
    }

    function test_Validate_WrongDestinationDomainUsesTransmitterDomain() public {
        H memory x = _goodH();
        x.dst = LOCAL + 1;
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.WrongDestinationDomain.selector, LOCAL, LOCAL + 1));
        h.validate(_cfg(), _header(x));
    }

    function test_Validate_FallbackDomainWhenTransmitterReverts() public {
        tx_.setDomain(1, LOCAL);
        H memory x = _goodH();
        x.dst = FALLBACK;
        h.validate(_cfg(), _header(x));
        x.dst = LOCAL;
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.WrongDestinationDomain.selector, FALLBACK, LOCAL));
        h.validate(_cfg(), _header(x));
    }

    function test_Validate_FallbackDomainWhenTransmitterReturnsShortData() public {
        tx_.setDomain(2, LOCAL);
        H memory x = _goodH();
        x.dst = FALLBACK;
        h.validate(_cfg(), _header(x));
    }

    function test_Validate_FallbackDomainWhenTransmitterHasNoCode() public {
        CctpSettlementLogic.Config memory c = _cfg();
        c.transmitter = makeAddr("eoa");
        H memory x = _goodH();
        x.dst = FALLBACK;
        h.validate(c, _header(x));
    }

    function test_Validate_WrongSourceDomain() public {
        H memory x = _goodH();
        x.src = SRC + 1;
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.WrongSourceDomain.selector, SRC, SRC + 1));
        h.validate(_cfg(), _header(x));
    }

    function test_Validate_WrongRecipient() public {
        H memory x = _goodH();
        x.recipient = _b32(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.WrongMessageRecipient.selector, x.recipient));
        h.validate(_cfg(), _header(x));
    }

    function test_Validate_RecipientWithDirtyHighBitsRejected() public {
        H memory x = _goodH();
        x.recipient = bytes32(uint256(_b32(address(messenger))) | (uint256(1) << 200));
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.WrongMessageRecipient.selector, x.recipient));
        h.validate(_cfg(), _header(x));
    }

    function test_Validate_WrongDestinationCaller() public {
        H memory x = _goodH();
        x.caller = bytes32(0);
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.WrongDestinationCaller.selector, bytes32(0)));
        h.validate(_cfg(), _header(x));
        x.caller = _b32(address(this));
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.WrongDestinationCaller.selector, x.caller));
        h.validate(_cfg(), _header(x));
    }

    function test_Validate_RemoteMessengerNotSet() public {
        CctpSettlementLogic.Config memory c = _cfg();
        c.expectedSource = SRC + 1;
        H memory x = _goodH();
        x.src = SRC + 1;
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.RemoteMessengerNotSet.selector, SRC + 1));
        h.validate(c, _header(x));
    }

    function test_Validate_WrongRemoteSender() public {
        H memory x = _goodH();
        x.sender = bytes32(uint256(1));
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.WrongRemoteSender.selector, REMOTE, x.sender));
        h.validate(_cfg(), _header(x));
    }

    function test_Validate_Precedence_VersionThenDestThenSourceThenRecipient() public {
        H memory x = _goodH();
        x.dst = LOCAL + 1;
        x.src = SRC + 1;
        x.recipient = 0;
        x.caller = 0;
        x.sender = 0;
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.WrongDestinationDomain.selector, LOCAL, LOCAL + 1));
        h.validate(_cfg(), _header(x));
        x.dst = LOCAL;
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.WrongSourceDomain.selector, SRC, SRC + 1));
        h.validate(_cfg(), _header(x));
        x.src = SRC;
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.WrongMessageRecipient.selector, bytes32(0)));
        h.validate(_cfg(), _header(x));
        x.recipient = _b32(address(messenger));
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.WrongDestinationCaller.selector, bytes32(0)));
        h.validate(_cfg(), _header(x));
        x.caller = _b32(address(h));
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.WrongRemoteSender.selector, REMOTE, bytes32(0)));
        h.validate(_cfg(), _header(x));
    }

    // ── consumeInbound ──
    function test_Consume_MarksAndRejectsReplay() public {
        bytes memory m = _header(_goodH());
        assertFalse(h.consumed(SRC, NONCE));
        h.consume(m);
        assertTrue(h.consumed(SRC, NONCE));
        vm.expectRevert(AutonomousVault.InboundAlreadyConsumed.selector);
        h.consume(m);
    }

    function test_Consume_IndependentPerNonceAndDomain() public {
        H memory x = _goodH();
        h.consume(_header(x));
        x.nonce = bytes32(uint256(NONCE) + 1);
        h.consume(_header(x));
        x.nonce = NONCE;
        x.src = SRC + 1;
        h.consume(_header(x));
    }

    function test_Consume_ShortMessageReverts() public {
        vm.expectRevert(abi.encodeWithSelector(CctpMessageDecoder.InvalidMessageRange.selector, 10, 0, 148));
        h.consume(new bytes(10));
    }

    function test_Consume_DoesNotRequireValidSender() public {
        H memory x = _goodH();
        x.sender = 0;
        h.consume(_header(x)); // pure replay guard: validation is a separate step
    }

    function testFuzz_ShortMessagesAlwaysRevert(bytes calldata raw, uint8 cut) public {
        uint256 len = bound(cut, 0, 147);
        bytes memory s = new bytes(len);
        for (uint256 i; i < len && i < raw.length; ++i) s[i] = raw[i];
        vm.expectRevert();
        h.validate(_cfg(), s);
    }

    function testFuzz_ValidateAcceptsIffAllFieldsMatch(
        uint32 src, uint32 dst, bytes32 recipient, bytes32 caller, bytes32 sender
    ) public {
        H memory x = H(1, src, dst, NONCE, sender, recipient, caller);
        bool ok = src == SRC && dst == LOCAL && recipient == _b32(address(messenger))
            && caller == _b32(address(h)) && sender == REMOTE;
        bytes memory m = _header(x);
        if (ok) {
            h.validate(_cfg(), m);
        } else {
            vm.expectRevert();
            h.validate(_cfg(), m);
        }
    }

    function testFuzz_ValidMatchWithRandomNonceAndTrailer(bytes32 nonce, bytes calldata trailer) public view {
        H memory x = _goodH();
        x.nonce = nonce;
        h.validate(_cfg(), abi.encodePacked(_header(x), trailer));
    }
}
