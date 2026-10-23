// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title  TaskI — Item I1: AutonomousVault cross-chain settle (updated for J1)
/// @notice Tests 1-5 rewritten to target the J1 API:
///           settleCrossChainWithMessage  — atomic path (primary)
///           settleCrossChain(nonce, 0)   — write-off path (secondary, onlyOwner)

import {Test} from "forge-std/Test.sol";
import {TaskITestBase, MockTokenMessengerI} from "./TaskITest.Base.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AutonomousVault} from "../AutonomousVault.sol";

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

    function setMintAmount(uint256 a) external { mintAmount = a; }

    /// @dev Mints mintAmount to vault. Message/attestation bytes are ignored.
    function receiveMessage(bytes calldata, bytes calldata) external returns (bool) {
        // Mint by giving the vault extra tokens.
        MockERC20Like(usdc).mint(vault, mintAmount);
        return true;
    }
}

interface MockERC20Like {
    function mint(address to, uint256 amount) external;
}

/// @dev CctpMessageDecoder is a library; we test via a thin wrapper.
contract TaskITest_I1 is TaskITestBase {

    MockMessageTransmitter public transmitter;

    // ─── helper: build a fake CCTP V2 message that decodes correctly ──────────
    // Outer header (116 bytes): version(4), srcDomain(4), dstDomain(4), nonce(8), ... padding to 116
    // BurnMessage V2 body appended at offset 116 (164 bytes):
    //   [0..3]    version(4)
    //   [4..35]   burnToken(32)
    //   [36..67]  mintRecipient (bytes32)
    //   [68..99]  amount (uint256)
    //   [100..131] messageSender(32)
    //   [132..163] feeExecuted (uint256)  — CCTP V2 field
    function _buildMessage(uint64 nonce_, uint256 amount_, address mintRecipient_)
        internal pure returns (bytes memory)
    {
        return _buildMessageWithFee(nonce_, amount_, mintRecipient_, 0);
    }

    function _buildMessageWithFee(
        uint64 nonce_,
        uint256 amount_,
        address mintRecipient_,
        uint256 feeExecuted_
    ) internal pure returns (bytes memory) {
        bytes memory header = new bytes(116);
        // nonce at bytes [12..19]
        for (uint256 i = 0; i < 8; i++) {
            header[19 - i] = bytes1(uint8(nonce_ >> (i * 8)));
        }
        // V2 body: 164 bytes (132 original + 32 for feeExecuted)
        bytes memory body = new bytes(164);
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
        // feeExecuted at body[132..163]
        bytes32 feeWord = bytes32(feeExecuted_);
        for (uint256 i = 0; i < 32; i++) {
            body[132 + i] = feeWord[i];
        }
        return abi.encodePacked(header, body);
    }

    function setUp() public override {
        super.setUp();
        // Deploy a MessageTransmitter that will mint 10_000e6 USDC to vault on receiveMessage.
        transmitter = new MockMessageTransmitter(address(usdc), address(vault), 10_000e6);
        // Wire it into the vault.
        vm.prank(owner);
        vault.setMessageTransmitter(address(transmitter));
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
    // Test 4 — replay reverts NonceMismatch (pendingCrossChain[nonce] == 0)
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
            abi.encodeWithSelector(AutonomousVault.NonceMismatch.selector, nonce)
        );
        vault.settleCrossChainWithMessage(nonce, msg_, "");
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
}
