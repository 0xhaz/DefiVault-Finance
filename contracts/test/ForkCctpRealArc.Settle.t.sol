// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AutonomousVault} from "../AutonomousVault.sol";
import {
    ForkCctpRealArcBase,
    IUSDCArc,
    IMessageTransmitterV2Real,
    ITokenMessengerV2Real
} from "./ForkCctpRealArc.Base.t.sol";

/// @notice N-03 inbound leg: settleCrossChainWithMessage against the REAL MessageTransmitterV2 /
///         TokenMessengerV2 / TokenMinterV2. Messages are native Circle V2 (148-byte header + BurnMessageV2
///         body) signed by a test attester that the REAL on-chain attesterManager enabled (threshold 1).
contract ForkCctpRealArcSettleTest is ForkCctpRealArcBase {
    bytes32 internal constant N1 = keccak256("nonce-1");
    bytes32 internal constant N2 = keccak256("nonce-2");
    uint256 internal constant FEE = 10e6;

    function _err(string memory reason) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("Error(string)", reason);
    }

    function _prep(M memory m) internal view returns (bytes memory message, bytes memory att) {
        message = _enc(m);
        att = _signWith(attesterPk, message);
    }

    function _call(uint64 pid, bytes memory message, bytes memory att) internal {
        vm.prank(manager);
        vault.settleCrossChainWithMessage(pid, message, att);
    }

    /// @dev Settle must revert with `err` (empty err = any revert) and leave the position pending.
    function _expectRejected(uint64 pid, M memory m, bytes memory err) internal {
        (bytes memory message, bytes memory att) = _prep(m);
        _expectRejectedRaw(pid, message, att, err);
    }

    function _expectRejectedRaw(uint64 pid, bytes memory message, bytes memory att, bytes memory err) internal {
        uint256 pending = vault.pendingCrossChain(pid);
        uint256 bal = _usdc(address(vault));
        uint256 deployed = vault.totalDeployed();
        vm.prank(manager);
        if (err.length == 0) vm.expectRevert();
        else vm.expectRevert(err);
        vault.settleCrossChainWithMessage(pid, message, att);
        assertEq(vault.pendingCrossChain(pid), pending, "position still pending");
        assertEq(_usdc(address(vault)), bal, "no USDC minted to the vault");
        assertEq(vault.totalDeployed(), deployed);
    }

    // ───────── happy paths ─────────

    function test_Settle_noFee_booksFullAmount() public {
        uint64 pid = _deployPos(ETH_SEPOLIA, SENT);
        uint256 bal = _usdc(address(vault));
        uint256 supply = IUSDCArc(USDC).totalSupply();
        uint256 nav = vault.totalAssets();
        (bytes memory message, bytes memory att) = _prep(_m(N1, SENT, 0));

        vm.expectEmit(true, false, false, true, address(vault));
        emit AutonomousVault.CrossChainSettled(pid, SENT, 0);
        _call(pid, message, att);

        assertEq(_usdc(address(vault)), bal + SENT, "real TokenMinterV2 minted the full amount to the vault");
        assertEq(IUSDCArc(USDC).totalSupply(), supply + SENT, "USDC totalSupply rose by the mint");
        assertEq(vault.pendingCrossChain(pid), 0);
        assertEq(vault.pendingCrossChainDestinationDomain(pid), 0);
        assertEq(vault.totalPendingCrossChain(), 0);
        assertEq(vault.totalDeployed(), 0);
        assertEq(vault.totalAssets(), nav, "round trip is NAV neutral without fee");
        assertTrue(vault.consumedInbound(ETH_SEPOLIA, N1));
        assertGt(IMessageTransmitterV2Real(MT).usedNonces(N1), 0, "real transmitter consumed the nonce");
    }

    function test_Settle_withFee_booksAmountMinusFee() public {
        uint64 pid = _deployPos(ETH_SEPOLIA, SENT);
        address feeRecipient = ITokenMessengerV2Real(TM).feeRecipient();
        uint256 bal = _usdc(address(vault));
        uint256 feeBal = _usdc(feeRecipient);
        uint256 supply = IUSDCArc(USDC).totalSupply();
        uint256 nav = vault.totalAssets();
        (bytes memory message, bytes memory att) = _prep(_m(N1, SENT, FEE));

        vm.expectEmit(true, false, false, true, address(vault));
        emit AutonomousVault.CrossChainFeeDeducted(pid, FEE);
        vm.expectEmit(true, false, false, true, address(vault));
        emit AutonomousVault.CrossChainSettled(pid, SENT - FEE, FEE);
        _call(pid, message, att);

        assertEq(_usdc(address(vault)), bal + SENT - FEE, "vault received exactly amount - feeExecuted");
        assertEq(_usdc(feeRecipient) - feeBal, FEE, "real TokenMessengerV2 fee recipient got feeExecuted");
        assertEq(IUSDCArc(USDC).totalSupply(), supply + SENT, "net + fee minted in total");
        assertEq(vault.totalDeployed(), 0);
        assertEq(vault.totalPendingCrossChain(), 0);
        assertEq(vault.pendingCrossChain(pid), 0);
        assertEq(vault.totalAssets(), nav - FEE, "the fee is a real NAV cost");
    }

    function test_Settle_partialReturnSettlesOnlyThatPosition() public {
        uint64 p1 = _deployPos(ETH_SEPOLIA, SENT);
        uint64 p2 = _deployPos(ETH_SEPOLIA, 5_000e6);
        _settle(p2, _m(N2, 5_000e6, 0));
        assertEq(vault.pendingCrossChain(p2), 0);
        assertEq(vault.pendingCrossChain(p1), SENT);
        assertEq(vault.totalPendingCrossChain(), SENT);
        assertEq(vault.totalDeployed(), SENT);
    }

    // ───────── replay ─────────

    function test_Settle_replayRejected_byVaultAndByRealTransmitter() public {
        uint64 p1 = _deployPos(ETH_SEPOLIA, SENT);
        uint64 p2 = _deployPos(ETH_SEPOLIA, 5_000e6);
        (bytes memory message, bytes memory att) = _prep(_m(N1, SENT, 0));
        _call(p1, message, att);

        // Same attested message against another pending position: vault consumedInbound guard.
        vm.prank(manager);
        vm.expectRevert(AutonomousVault.InboundAlreadyConsumed.selector);
        vault.settleCrossChainWithMessage(p2, message, att);
        assertEq(vault.pendingCrossChain(p2), 5_000e6);

        // Bypassing the vault guard: the real MessageTransmitterV2 refuses the used nonce itself.
        vm.prank(address(vault));
        vm.expectRevert(_err("Nonce already used"));
        IMessageTransmitterV2Real(MT).receiveMessage(message, att);
        // And the original, already settled position cannot be settled again.
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.NonceMismatch.selector, p1, 0));
        vault.settleCrossChainWithMessage(p1, message, att);
    }

    // ───────── vault-level header negatives (real transmitter localDomain = 26) ─────────

    function test_Settle_wrongDestinationCaller_reverts() public {
        uint64 pid = _deployPos(ETH_SEPOLIA, SENT);
        M memory m = _m(N1, SENT, 0);
        m.destCaller = _b(alice);
        _expectRejected(pid, m, abi.encodeWithSelector(AutonomousVault.WrongDestinationCaller.selector, _b(alice)));
    }

    function test_Settle_wrongSourceDomain_reverts() public {
        uint64 pid = _deployPos(ETH_SEPOLIA, SENT);
        M memory m = _m(N1, SENT, 0);
        m.src = UNSET_AT_VAULT;
        _expectRejected(pid, m, abi.encodeWithSelector(AutonomousVault.WrongSourceDomain.selector, 0, 7));
    }

    function test_Settle_wrongDestinationDomain_reverts() public {
        uint64 pid = _deployPos(ETH_SEPOLIA, SENT);
        M memory m = _m(N1, SENT, 0);
        m.dst = ETH_SEPOLIA;
        _expectRejected(pid, m, abi.encodeWithSelector(AutonomousVault.WrongDestinationDomain.selector, 26, 0));
    }

    function test_Settle_wrongMessageRecipient_reverts() public {
        uint64 pid = _deployPos(ETH_SEPOLIA, SENT);
        M memory m = _m(N1, SENT, 0);
        m.recipient = _b(MT);
        _expectRejected(pid, m, abi.encodeWithSelector(AutonomousVault.WrongMessageRecipient.selector, _b(MT)));
    }

    function test_Settle_wrongMintRecipient_reverts() public {
        uint64 pid = _deployPos(ETH_SEPOLIA, SENT);
        M memory m = _m(N1, SENT, 0);
        m.mintRecipient = _b(alice);
        _expectRejected(pid, m, abi.encodeWithSelector(AutonomousVault.WrongMintRecipient.selector, _b(alice)));
    }

    function test_Settle_remoteMessengerNotSetOnVault_reverts() public {
        // Domain 7 IS registered on the real TokenMessengerV2 but the vault owner never set it on the vault.
        uint64 pid = _deployPos(UNSET_AT_VAULT, SENT);
        M memory m = _m(N1, SENT, 0);
        m.src = UNSET_AT_VAULT;
        _expectRejected(pid, m, abi.encodeWithSelector(AutonomousVault.RemoteMessengerNotSet.selector, 7));
    }

    function test_Settle_senderDiffersFromVaultRegisteredMessenger_reverts() public {
        uint64 pid = _deployPos(ETH_SEPOLIA, SENT);
        bytes32 rogue = _b(makeAddr("rogueMessenger"));
        M memory m = _m(N1, SENT, 0);
        m.sender = rogue;
        _expectRejected(
            pid, m, abi.encodeWithSelector(AutonomousVault.WrongRemoteSender.selector, remoteMessenger, rogue)
        );
    }

    // ───────── real-contract negatives (vault checks pass, the REAL contracts reject) ─────────

    function test_Settle_senderNotRegisteredOnRealTokenMessenger_reverts() public {
        uint64 pid = _deployPos(ETH_SEPOLIA, SENT);
        bytes32 rogue = _b(makeAddr("rogueMessenger"));
        vm.prank(owner);
        vault.setRemoteTokenMessenger(ETH_SEPOLIA, rogue); // vault now trusts the rogue sender...
        M memory m = _m(N1, SENT, 0);
        m.sender = rogue; // ...so only the real TokenMessengerV2 can reject it
        _expectRejected(pid, m, _err("Remote TokenMessenger unsupported"));
        assertFalse(vault.consumedInbound(ETH_SEPOLIA, N1), "vault consume rolled back with the revert");
        assertEq(IMessageTransmitterV2Real(MT).usedNonces(N1), 0);
    }

    function test_Settle_attestationFromUnknownAttester_reverts() public {
        uint64 pid = _deployPos(ETH_SEPOLIA, SENT);
        bytes memory message = _enc(_m(N1, SENT, 0));
        bytes memory att = _signWith(uint256(keccak256("rogue attester")), message);
        _expectRejectedRaw(pid, message, att, _err("Invalid signature: not attester"));
    }

    function test_Settle_attestationWrongLength_reverts() public {
        uint64 pid = _deployPos(ETH_SEPOLIA, SENT);
        bytes memory message = _enc(_m(N1, SENT, 0));
        _expectRejectedRaw(pid, message, hex"a77e57", _err("Invalid attestation length"));
    }

    function test_Settle_tamperedMessageNotCoveredBySignature_reverts() public {
        uint64 pid = _deployPos(ETH_SEPOLIA, SENT);
        bytes memory signedFor = _enc(_m(N1, SENT, 0));
        bytes memory att = _signWith(attesterPk, signedFor);
        bytes memory inflated = _enc(_m(N1, SENT + 1e6, 0)); // attacker inflates the amount
        _expectRejectedRaw(pid, inflated, att, _err("Invalid signature: not attester"));
    }

    function test_Settle_burnTokenNotLinkedOnRealMinter_reverts() public {
        uint64 pid = _deployPos(ETH_SEPOLIA, SENT);
        M memory m = _m(N1, SENT, 0);
        m.burnToken = _b(makeAddr("unlinkedRemoteToken"));
        _expectRejected(pid, m, _err("Mint token not supported"));
    }

    function test_Settle_realTransmitterBindsDestinationCallerToMsgSender() public {
        _deployPos(ETH_SEPOLIA, SENT);
        (bytes memory message, bytes memory att) = _prep(_m(N1, SENT, 0));
        vm.prank(makeAddr("frontrunner"));
        vm.expectRevert(_err("Invalid caller for message")); // only the vault may deliver a vault-bound message
        IMessageTransmitterV2Real(MT).receiveMessage(message, att);
        assertEq(IMessageTransmitterV2Real(MT).usedNonces(N1), 0);
    }

    function test_Settle_unknownPositionReverts() public {
        (bytes memory message, bytes memory att) = _prep(_m(N1, SENT, 0));
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.NonceMismatch.selector, 42, 0));
        vault.settleCrossChainWithMessage(42, message, att);
    }
}
