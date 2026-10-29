// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title  TaskI — Item I1: AutonomousVault cross-chain settle (updated for J1)
/// @notice Tests 1-5 rewritten to target the J1 API:
///           settleCrossChainWithMessage  — atomic path (primary)
///           settleCrossChain(nonce, 0)   — write-off path (secondary, onlyOwner)

import {Test} from "forge-std/Test.sol";
import {TaskITestBase, MockTokenMessengerI} from "./TaskITest.Base.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AutonomousVault, CctpMessageDecoder} from "../AutonomousVault.sol";

/// @dev Minimal mock MessageTransmitter: when receiveMessage is called it mints
///      `mintAmount` USDC to the vault and returns true.
contract MockMessageTransmitter {
    address public usdc;
    address public vault;
    uint256 public mintAmount;

    constructor(address usdc_, address vault_, uint256 mintAmount_) {
        usdc      = usdc_;
        vault     = vault_;
        mintAmount = mintAmount_;
    }

    bool public receiveResult = true;
    function setReceiveResult(bool result) external { receiveResult = result; }
    function setMintAmount(uint256 a) external { mintAmount = a; }

    /// @dev Mints mintAmount to vault. Message/attestation bytes are ignored.
    function receiveMessage(bytes calldata, bytes calldata) external returns (bool) {
        // Mint by giving the vault extra tokens.
        MockERC20Like(usdc).mint(vault, mintAmount);
        return receiveResult;
    }
}

interface MockERC20Like {
    function mint(address to, uint256 amount) external;
}

// Task M: expose bounds-checked decoder helpers without changing the vault's external ABI.
contract TaskMDecoderHarness {
    function header(bytes calldata message) external pure returns (CctpMessageDecoder.Header memory) {
        return CctpMessageDecoder.decodeHeader(message);
    }
    function field(bytes calldata message, uint256 offset, uint256 size) external pure returns (bytes memory) {
        return CctpMessageDecoder._field(message, offset, size);
    }
}

/// @dev CctpMessageDecoder is a library; we test via a thin wrapper.
contract TaskITest_I1 is TaskITestBase {

    MockMessageTransmitter public transmitter;

    // Task M: native V2 validation and outbound settings regression coverage (not executed here).
    function test_M_outboundDefaultsAndSettings() public {
        assertEq(vault.crossChainMinFinality(), 2000);
        assertEq(vault.crossChainMaxFeeBps(), 0);
        vm.startPrank(owner);
        vault.setCrossChainMinFinality(1000);
        vault.setCrossChainMaxFeeBps(100);
        vm.expectRevert(AutonomousVault.InvalidCrossChainMinFinality.selector);
        vault.setCrossChainMinFinality(1999);
        vm.expectRevert(AutonomousVault.InvalidBps.selector);
        vault.setCrossChainMaxFeeBps(101);
        vm.expectRevert(AutonomousVault.ZeroAddress.selector);
        vault.setRemoteTokenMessenger(DEST_DOMAIN, bytes32(0));
        vm.stopPrank();
        uint64 positionId = _deployCrossChainI1(10_001);
        assertEq(positionId, 1);
        assertEq(messenger.lastCall(), abi.encode(
            uint256(10_001), DEST_DOMAIN, bytes32(uint256(uint160(alice))), address(usdc),
            bytes32(0), uint256(100), uint32(1000)
        ));
        assertEq(usdc.allowance(address(vault), address(messenger)), 0);
        assertEq(_deployCrossChainI1(10_001), 2);
    }

    function test_M_settingsOnlyOwner() public {
        vm.startPrank(manager);
        vm.expectRevert();
        vault.setCrossChainMinFinality(1000);
        vm.expectRevert();
        vault.setCrossChainMaxFeeBps(1);
        vm.expectRevert();
        vault.setRemoteTokenMessenger(DEST_DOMAIN, bytes32(uint256(1)));
        vm.stopPrank();
    }

    function test_M_wrongVersionsAndRemoteSender() public {
        uint64 positionId = _deployCrossChainI1(10_000e6);
        bytes memory message = _buildMessage(99, 10_000e6, address(vault));
        message[3] = 0x02;
        vm.expectRevert(abi.encodeWithSelector(CctpMessageDecoder.WrongHeaderVersion.selector, uint32(2)));
        vm.prank(manager);
        vault.settleCrossChainWithMessage(positionId, message, "");
        message[3] = 0x01;
        message[151] = 0x02;
        vm.expectRevert(abi.encodeWithSelector(CctpMessageDecoder.WrongBodyVersion.selector, uint32(2)));
        vm.prank(manager);
        vault.settleCrossChainWithMessage(positionId, message, "");
        message[151] = 0x01;
        bytes32 badSender = bytes32(uint256(123));
        for (uint256 i; i < 32; ++i) message[44 + i] = badSender[i];
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.WrongRemoteSender.selector,
            vault.remoteTokenMessenger(DEST_DOMAIN), badSender));
        vm.prank(manager);
        vault.settleCrossChainWithMessage(positionId, message, "");
        assertFalse(vault.consumedInbound(DEST_DOMAIN, bytes32(uint256(99))));
    }

    function test_M_missingRemoteMessenger() public {
        uint64 positionId = _deployCrossChainI1(10_000e6);
        bytes memory message = _buildMessage(99, 10_000e6, address(vault));
        // A fresh source domain has no registered messenger; update both recorded route and header.
        vm.prank(manager);
        vault.deployCrossChain(7, bytes32(uint256(uint160(alice))), 10_000e6);
        positionId = vault.crossChainPositionCounter();
        message[7] = 0x07;
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.RemoteMessengerNotSet.selector, uint32(7)));
        vm.prank(manager);
        vault.settleCrossChainWithMessage(positionId, message, "");
    }

    function test_M_bytes32NonceHighBitsDistinctAndReplayRollback() public {
        uint64 first = _deployCrossChainI1(10_000e6);
        bytes memory message = _buildMessage(99, 10_000e6, address(vault));
        // Same low 64 bits but different high bits must produce distinct replay keys.
        bytes32 highNonce = bytes32((uint256(1) << 255) | 99);
        for (uint256 i; i < 32; ++i) message[12 + i] = highNonce[i];
        transmitter.setMintAmount(1);
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.MessageAmountMismatch.selector, uint256(10_000e6), uint256(1)));
        vm.prank(manager);
        vault.settleCrossChainWithMessage(first, message, "");
        assertFalse(vault.consumedInbound(DEST_DOMAIN, highNonce));
        transmitter.setMintAmount(10_000e6);
        vm.prank(manager);
        vault.settleCrossChainWithMessage(first, message, "");
        assertTrue(vault.consumedInbound(DEST_DOMAIN, highNonce));
        uint64 second = _deployCrossChainI1(10_000e6);
        vm.expectRevert(AutonomousVault.InboundAlreadyConsumed.selector);
        vm.prank(manager);
        vault.settleCrossChainWithMessage(second, message, "");
        message = _buildMessage(99, 10_000e6, address(vault));
        vm.prank(manager);
        vault.settleCrossChainWithMessage(second, message, "");
        assertTrue(vault.consumedInbound(DEST_DOMAIN, bytes32(uint256(99))));
    }

    function test_M_falseReceiveRollsBackMintAndReplay() public {
        uint64 positionId = _deployCrossChainI1(10_000e6);
        bytes memory message = _buildMessage(99, 10_000e6, address(vault));
        uint256 balanceBefore = usdc.balanceOf(address(vault));
        transmitter.setReceiveResult(false);
        vm.expectRevert(AutonomousVault.MessageReceiveFailed.selector);
        vm.prank(manager);
        vault.settleCrossChainWithMessage(positionId, message, "");
        assertEq(usdc.balanceOf(address(vault)), balanceBefore);
        assertFalse(vault.consumedInbound(DEST_DOMAIN, bytes32(uint256(99))));
        assertEq(vault.pendingCrossChain(positionId), 10_000e6);
    }

    function test_M_shortHeaderAndOversizedOffsets() public {
        TaskMDecoderHarness harness = new TaskMDecoderHarness();
        vm.expectRevert(abi.encodeWithSelector(CctpMessageDecoder.InvalidMessageRange.selector,
            uint256(147), uint256(0), uint256(148)));
        harness.header(new bytes(147));
        vm.expectRevert(abi.encodeWithSelector(CctpMessageDecoder.InvalidMessageRange.selector,
            uint256(0), type(uint256).max, uint256(32)));
        harness.field("", type(uint256).max, 32);
        vm.expectRevert(abi.encodeWithSelector(CctpMessageDecoder.InvalidMessageRange.selector,
            uint256(1), uint256(1), type(uint256).max));
        harness.field(hex"00", 1, type(uint256).max);
    }

    // ─── helper: build a fake CCTP V2 message matching the real BurnMessageV2 layout ───
    //
    // Task M: native 148-byte header, version 1; domains @4/8, bytes32 nonce @12,
    // sender @44, recipient @76, caller @108, finality fields @140/144.
    // BurnMessageV2 body (228 bytes, at message offset 148):
    //   [0..3]    version(4)
    //   [4..35]   burnToken(32)
    //   [36..67]  mintRecipient(32)
    //   [68..99]  amount(32)
    //   [100..131] messageSender(32)
    //   [132..163] maxFee(32)        — fee ceiling (not the actual fee)
    //   [164..195] feeExecuted(32)   — actual fee taken; 0 for Standard Transfer
    //   [196..227] expirationBlock(32)
    //
    // Total minimum message length: 148 + 228 = 376 bytes.
    function _buildMessage(uint64 nonce_, uint256 amount_, address mintRecipient_)
        internal view returns (bytes memory)
    {
        return _buildMessageWithFee(nonce_, amount_, mintRecipient_, 0, 0);
    }

    /// @dev Build with a specific feeExecuted; maxFee is set to feeExecuted as a safe ceiling.
    function _buildMessageWithFee(
        uint64 nonce_,
        uint256 amount_,
        address mintRecipient_,
        uint256 feeExecuted_
    ) internal view returns (bytes memory) {
        return _buildMessageWithFee(nonce_, amount_, mintRecipient_, feeExecuted_, feeExecuted_);
    }

    /// @dev Full builder: explicit maxFee and feeExecuted (feeExecuted <= maxFee in real messages).
    function _buildMessageWithFee(
        uint64 nonce_,
        uint256 amount_,
        address mintRecipient_,
        uint256 feeExecuted_,
        uint256 maxFee_
    ) internal view returns (bytes memory) {
        // Task M: native MessageV2 header; the inbound nonce is independent of the position ID.
        bytes memory header = abi.encodePacked(
            uint32(1), DEST_DOMAIN, SOURCE_DOMAIN, bytes32(uint256(nonce_)),
            vault.remoteTokenMessenger(DEST_DOMAIN),
            bytes32(uint256(uint160(address(messenger)))), bytes32(uint256(uint160(address(vault)))), uint32(2000), uint32(2000)
        );
        // BurnMessageV2 body: 228 bytes
        bytes memory body = new bytes(228);
        body[3] = 0x01; // Task M: native BurnMessageV2 version.
        // mintRecipient at body[36..67]
        bytes32 recipientWord = bytes32(uint256(uint160(mintRecipient_)));
        for (uint256 i = 0; i < 32; i++) {
            body[36 + i] = recipientWord[i];
        }
        // amount at body[68..99]
        bytes32 amountWord = bytes32(amount_);
        for (uint256 i = 0; i < 32; i++) {
            body[68 + i] = amountWord[i];
        }
        // maxFee at body[132..163]
        bytes32 maxFeeWord = bytes32(maxFee_);
        for (uint256 i = 0; i < 32; i++) {
            body[132 + i] = maxFeeWord[i];
        }
        // feeExecuted at body[164..195]
        bytes32 feeWord = bytes32(feeExecuted_);
        for (uint256 i = 0; i < 32; i++) {
            body[164 + i] = feeWord[i];
        }
        // expirationBlock at body[196..227] — left zero (no expiry in tests)
        return abi.encodePacked(header, body);
    }

    function test_independent_return_nonce_succeeds() public {
        uint64 nonce = _deployCrossChainI1(10_000e6);
        bytes memory message = _buildMessage(nonce + 1, 10_000e6, address(vault));
        vm.prank(manager);
        vault.settleCrossChainWithMessage(nonce, message, "");
        assertEq(vault.pendingCrossChain(nonce), 0);
        assertTrue(vault.consumedInbound(DEST_DOMAIN, bytes32(uint256(nonce + 1))));
    }

    function test_wrong_destination_domain_reverts() public {
        uint64 nonce = _deployCrossChainI1(10_000e6);
        bytes memory message = _buildMessage(nonce, 10_000e6, address(vault));
        message[11] = bytes1(uint8(SOURCE_DOMAIN + 1));
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.WrongDestinationDomain.selector, SOURCE_DOMAIN, SOURCE_DOMAIN + 1));
        vm.prank(manager);
        vault.settleCrossChainWithMessage(nonce, message, "");
    }

    function test_wrong_destination_caller_reverts() public {
        uint64 nonce = _deployCrossChainI1(10_000e6);
        bytes memory message = _buildMessage(nonce, 10_000e6, address(vault));
        bytes32 caller = bytes32(uint256(uint160(address(0xBEEF))));
        for (uint256 i = 0; i < 32; i++) message[108 + i] = caller[i];
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.WrongDestinationCaller.selector, caller));
        vm.prank(manager);
        vault.settleCrossChainWithMessage(nonce, message, "");
    }

    function setUp() public override {
        super.setUp();
        // Deploy a MessageTransmitter that will mint 10_000e6 USDC to vault on receiveMessage.
        transmitter = new MockMessageTransmitter(address(usdc), address(vault), 10_000e6);
        // Wire it into the vault.
        vm.prank(owner);
        vault.setMessageTransmitter(address(transmitter));
        vm.prank(owner);
        vault.setRemoteTokenMessenger(DEST_DOMAIN, bytes32(uint256(0xCC7)));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 1 — atomic settle: received == minted by transmitter
    // ─────────────────────────────────────────────────────────────────────────
    function test_I1_atomic_settle_exact() public {
        uint256 deployAmt = 10_000e6;
        uint64  nonce     = _deployCrossChainI1(deployAmt);

        uint256 navBefore = vault.totalAssets();

        bytes memory msg_  = _buildMessage(nonce, deployAmt, address(vault));
        bytes memory attest = "";

        vm.prank(manager);
        vm.expectEmit(true, false, false, true);
        emit AutonomousVault.CrossChainSettled(nonce, deployAmt, 0);
        vault.settleCrossChainWithMessage(nonce, msg_, attest);

        // shortfall == 0: NAV should be back to navBefore
        // (transmitter minted 10_000e6 back, totalDeployed -= 10_000e6)
        assertApproxEqAbs(vault.totalAssets(), navBefore, 1, "NAV unchanged on exact atomic settle");
        assertEq(vault.pendingCrossChain(nonce), 0, "pendingCrossChain cleared");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 2 — atomic settle: wrong mintRecipient reverts WrongMintRecipient
    // ─────────────────────────────────────────────────────────────────────────
    function test_I1_wrong_recipient_reverts() public {
        uint64 nonce = _deployCrossChainI1(10_000e6);

        address badRecipient = address(0xBEEF);
        bytes memory msg_ = _buildMessage(nonce, 10_000e6, badRecipient);

        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(
                AutonomousVault.WrongMintRecipient.selector,
                bytes32(uint256(uint160(badRecipient)))
            )
        );
        vault.settleCrossChainWithMessage(nonce, msg_, "");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 3 — message amount mismatch reverts MessageAmountMismatch
    // ─────────────────────────────────────────────────────────────────────────
    function test_I1_amount_mismatch_reverts() public {
        uint64 nonce = _deployCrossChainI1(10_000e6);
        // Transmitter mints 10_000e6 but message says 9_000e6 (no fee).
        // expectedNet = 9_000e6, balanceDelta = 10_000e6 → mismatch.
        bytes memory msg_ = _buildMessage(nonce, 9_000e6, address(vault));

        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(
                AutonomousVault.MessageAmountMismatch.selector,
                9_000e6,   // expectedNet (= msgAmount - feeExecuted = 9_000e6 - 0)
                10_000e6   // balanceDelta (transmitter minted 10_000e6)
            )
        );
        vault.settleCrossChainWithMessage(nonce, msg_, "");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 4 — same pending key reverts NonceMismatch; another key cannot reuse the inbound message.
    // ─────────────────────────────────────────────────────────────────────────
    function test_I1_replay_reverts() public {
        uint64 nonce = _deployCrossChainI1(10_000e6);
        bytes memory msg_ = _buildMessage(nonce, 10_000e6, address(vault));

        // First settle succeeds.
        vm.prank(manager);
        vault.settleCrossChainWithMessage(nonce, msg_, "");

        // Replay reverts because pendingCrossChain[nonce] was deleted.
        // Transmitter would mint again, but we never reach that — the nonce check fires first.
        // Re-deploy a fresh transmitter to avoid double-counting.
        MockMessageTransmitter tx2 = new MockMessageTransmitter(address(usdc), address(vault), 10_000e6);
        vm.prank(owner);
        vault.setMessageTransmitter(address(tx2));

        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(AutonomousVault.NonceMismatch.selector, nonce, uint64(0))
        );
        vault.settleCrossChainWithMessage(nonce, msg_, "");

        uint64 second = _deployCrossChainI1(10_000e6);
        vm.prank(manager);
        vm.expectRevert(AutonomousVault.InboundAlreadyConsumed.selector);
        vault.settleCrossChainWithMessage(second, msg_, "");
        assertEq(vault.pendingCrossChain(second), 10_000e6);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 5 — write-off path books full loss; non-zero received reverts
    // ─────────────────────────────────────────────────────────────────────────
    function test_I1_writeoff_path_books_full_loss() public {
        uint256 deployAmt = 10_000e6;
        uint64  nonce     = _deployCrossChainI1(deployAmt);

        uint256 navBefore = vault.totalAssets();

        // Non-zero received reverts WriteOffMustBeZero.
        vm.prank(owner);
        vm.expectRevert(AutonomousVault.WriteOffMustBeZero.selector);
        vault.settleCrossChain(nonce, 1);

        // Zero received (full write-off) succeeds.
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit AutonomousVault.CrossChainSettled(nonce, 0, deployAmt);
        vault.settleCrossChain(nonce, 0);

        // Full loss: NAV drops by deployAmt (totalDeployed -= sent; no USDC returned).
        assertEq(vault.totalAssets(), navBefore - deployAmt, "write-off books full loss");
        assertEq(vault.pendingCrossChain(nonce), 0, "pendingCrossChain cleared on write-off");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // K1 Test 6 — Fast Transfer with fee=0: behaves identically to Standard.
    //             Settle succeeds; NAV unchanged (full amount returned).
    // ─────────────────────────────────────────────────────────────────────────
    function test_K1_settle_with_fee_zero_succeeds() public {
        uint256 deployAmt = 10_000e6;
        uint64  nonce     = _deployCrossChainI1(deployAmt);

        uint256 navBefore = vault.totalAssets();

        // message: amount=10_000e6, feeExecuted=0 → expectedNet=10_000e6
        // transmitter mints 10_000e6 → balanceDelta=10_000e6 → match
        bytes memory msg_ = _buildMessageWithFee(nonce, deployAmt, address(vault), 0);

        vm.prank(manager);
        vm.expectEmit(true, false, false, true);
        emit AutonomousVault.CrossChainSettled(nonce, deployAmt, 0);
        vault.settleCrossChainWithMessage(nonce, msg_, "");

        // No fee: shortfall == 0, NAV unchanged
        assertApproxEqAbs(vault.totalAssets(), navBefore, 1,
            "NAV unchanged on zero-fee settle");
        assertEq(vault.pendingCrossChain(nonce), 0, "nonce cleared");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // K1 Test 7 — Fast Transfer with fee > 0: settle succeeds; NAV drops by fee.
    //             Fee is emitted as CrossChainFeeDeducted; total cost = fee.
    // ─────────────────────────────────────────────────────────────────────────
    function test_K1_settle_with_fee_nonzero_succeeds_and_nav_drops() public {
        uint256 deployAmt  = 10_000e6;
        uint256 feeAmt     = 500e6;   // $500 CCTP fast-transfer fee
        uint256 netAmt     = deployAmt - feeAmt; // 9_500e6 minted to vault

        uint64  nonce = _deployCrossChainI1(deployAmt);

        // Adjust transmitter to mint net amount (after fee deduction)
        transmitter.setMintAmount(netAmt);

        uint256 navBefore = vault.totalAssets();

        // message: amount=10_000e6, feeExecuted=500e6 → expectedNet=9_500e6
        bytes memory msg_ = _buildMessageWithFee(nonce, deployAmt, address(vault), feeAmt);

        vm.prank(manager);
        // Expect fee event
        vm.expectEmit(true, false, false, true);
        emit AutonomousVault.CrossChainFeeDeducted(nonce, feeAmt);
        // Expect settle event: received=9_500e6, shortfall=500e6
        vm.expectEmit(true, false, false, true);
        emit AutonomousVault.CrossChainSettled(nonce, netAmt, feeAmt);
        vault.settleCrossChainWithMessage(nonce, msg_, "");

        // NAV drops by exactly the fee (the 9_500e6 was minted back, 500e6 is gone)
        // After settle: totalDeployed -= 10_000e6; vault balance += 9_500e6.
        // Net: vault lost 500e6 in assets.
        assertEq(vault.totalAssets(), navBefore - feeAmt,
            "NAV must drop by exactly feeExecuted");
        assertEq(vault.pendingCrossChain(nonce), 0, "nonce cleared after fee settle");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // K1 Test 8 — Both fee and strategy loss: NAV drops by fee + shortfall.
    //             (message.amount > deployed: not possible. But fee + strategy loss combo.)
    //             Scenario: deployed 10_000, came back 9_000 net, fee=200 (so amount=9_200 in msg).
    // ─────────────────────────────────────────────────────────────────────────
    function test_K1_settle_fee_plus_strategy_loss_nav_drops_by_total_cost() public {
        uint256 deployAmt  = 10_000e6;
        uint256 msgAmount  = 9_200e6; // gross burned amount on the return leg
        uint256 feeAmt     = 200e6;
        uint256 netAmt     = msgAmount - feeAmt; // 9_000e6 actually minted

        uint64 nonce = _deployCrossChainI1(deployAmt);

        // Transmitter mints only 9_000e6 (strategy returned less + fee taken)
        transmitter.setMintAmount(netAmt);

        uint256 navBefore = vault.totalAssets();

        bytes memory msg_ = _buildMessageWithFee(nonce, msgAmount, address(vault), feeAmt);

        vm.prank(manager);
        // shortfall in _doSettle = deployAmt(10_000) - received(9_000) = 1_000e6
        vm.expectEmit(true, false, false, true);
        emit AutonomousVault.CrossChainFeeDeducted(nonce, feeAmt);
        vm.expectEmit(true, false, false, true);
        emit AutonomousVault.CrossChainSettled(nonce, netAmt, deployAmt - netAmt);
        vault.settleCrossChainWithMessage(nonce, msg_, "");

        // Total cost = 1_000e6 (strategy loss + fee combined)
        assertEq(vault.totalAssets(), navBefore - (deployAmt - netAmt),
            "NAV drops by total cross-chain cost (fee + strategy loss)");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Task M: a body shorter than 228 bytes reverts InvalidMessageRange.
    //             MIN_MESSAGE_LEN = 148 + 228 = 376. A 375-byte message must revert.
    // ─────────────────────────────────────────────────────────────────────────
    function test_L1_body_too_short_reverts() public {
        uint64 nonce = _deployCrossChainI1(10_000e6);

        // Build a valid 376-byte message then truncate to 375 bytes.
        bytes memory full = _buildMessage(nonce, 10_000e6, address(vault));
        assertEq(full.length, 376, "sanity: builder produces 376-byte message");

        bytes memory truncated = new bytes(375);
        for (uint256 i = 0; i < 375; i++) truncated[i] = full[i];

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CctpMessageDecoder.InvalidMessageRange.selector, uint256(375), uint256(0), uint256(376)));
        vault.settleCrossChainWithMessage(nonce, truncated, "");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // L1 Test 10 — golden fixture: a hand-crafted BurnMessageV2 with known field
    //              values round-trips through settleCrossChainWithMessage and the
    //              emitted events must carry exactly those values.
    //
    //  This test exercises CctpMessageDecoder end-to-end without a shim.
    //
    //  Fixture fields:
    //    amount       = 5_000_000   (5 USDC, 6 dec)
    //    maxFee       = 100_000     (0.1 USDC ceiling — placed at body[132..163])
    //    feeExecuted  = 50_000      (0.05 USDC actual — placed at body[164..195])
    //    mintRecipient = vault address
    //
    //  If the decoder were reading body[132] instead of body[164], feeExecuted would
    //  equal maxFee (100_000) instead of 50_000, and expectedNet would be 4_900_000
    //  instead of 4_950_000 — the transmitter mints 4_950_000, the check fails.
    //  This test therefore fails specifically when the offset is wrong.
    // ─────────────────────────────────────────────────────────────────────────
    function test_L1_golden_fixture_correct_offset() public {
        uint256 fixtureAmount  = 5_000_000;  // 5 USDC
        uint256 fixtureMaxFee  = 100_000;    // 0.1 USDC — must NOT be decoded as feeExecuted
        uint256 fixtureFeeExec = 50_000;     // 0.05 USDC actual fee
        uint256 expectedNet    = fixtureAmount - fixtureFeeExec; // 4_950_000

        // Pre-condition: maxFee != feeExecuted so an offset mix-up is detectable.
        assertTrue(fixtureMaxFee != fixtureFeeExec, "fixture design: maxFee must differ from feeExecuted");

        // Deploy 5 USDC cross-chain so there is a pending nonce.
        uint64 nonce = _deployCrossChainI1(fixtureAmount);

        // Transmitter mints exactly expectedNet (= amount - feeExecuted).
        transmitter.setMintAmount(expectedNet);
        uint256 navBefore = vault.totalAssets();

        bytes memory msg_ = _buildMessageWithFee(
            nonce, fixtureAmount, address(vault), fixtureFeeExec, fixtureMaxFee
        );
        assertEq(msg_.length, 376, "fixture message length must be 376 bytes");

        vm.prank(manager);
        // Expect CrossChainFeeDeducted with the actual feeExecuted (50_000), not maxFee.
        vm.expectEmit(true, false, false, true);
        emit AutonomousVault.CrossChainFeeDeducted(nonce, fixtureFeeExec);
        // Expect CrossChainSettled: received=4_950_000, shortfall=50_000
        vm.expectEmit(true, false, false, true);
        emit AutonomousVault.CrossChainSettled(nonce, expectedNet, fixtureFeeExec);
        vault.settleCrossChainWithMessage(nonce, msg_, "");

        // NAV drops by exactly fixtureFeeExec (not fixtureMaxFee).
        assertEq(vault.totalAssets(), navBefore - fixtureFeeExec,
            "NAV drop must equal feeExecuted, not maxFee");
    }

}
