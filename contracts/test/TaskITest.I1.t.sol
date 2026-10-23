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

    // ─── helper: build a fake CCTP message that decodes correctly ─────────────
    // Outer header (116 bytes): version(4), srcDomain(4), dstDomain(4), nonce(8), ... padding to 116
    // BurnMessage body appended at offset 116:
    //   [0..35]  version(4)+burnToken(32)
    //   [36..67] mintRecipient (bytes32)
    //   [68..99] amount (uint256)
    //   [100..131] messageSender(32)
    function _buildMessage(uint64 nonce_, uint256 amount_, address mintRecipient_)
        internal pure returns (bytes memory)
    {
        bytes memory header = new bytes(116);
        // nonce at bytes [12..19]
        for (uint256 i = 0; i < 8; i++) {
            header[19 - i] = bytes1(uint8(nonce_ >> (i * 8)));
        }
        bytes memory body = new bytes(132);
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
        // Transmitter mints 10_000e6 but message says 9_000e6.
        bytes memory msg_ = _buildMessage(nonce, 9_000e6, address(vault));

        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(
                AutonomousVault.MessageAmountMismatch.selector,
                9_000e6,
                10_000e6
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
}
