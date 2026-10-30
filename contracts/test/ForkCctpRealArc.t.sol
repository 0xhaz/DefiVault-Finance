// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AutonomousVault} from "../AutonomousVault.sol";
import {ShariahVault} from "../ShariahVault.sol";
import {ShariahVaultV2} from "../ShariahVaultV2.sol";
import {
    ForkCctpRealArcBase,
    IUSDCArc,
    IMessageTransmitterV2Real,
    ITokenMessengerV2Real,
    ITokenMinterV2Real
} from "./ForkCctpRealArc.Base.t.sol";

/// @notice N-03: the vault's CCTP V2 integration against the REAL Arc Testnet TokenMessengerV2 /
///         MessageTransmitterV2 / TokenMinterV2 / USDC (chain 5042002 fork). Skipped when ARC_TESTNET_RPC is
///         missing or the fork cannot be created. Outbound + setup tests; inbound settle is in the Settle file.
contract ForkCctpRealArcTest is ForkCctpRealArcBase {
    bytes32 internal constant DEPOSIT_FOR_BURN_SIG =
        keccak256("DepositForBurn(address,uint256,address,bytes32,uint32,bytes32,bytes32,uint256,uint32,bytes)");
    bytes32 internal constant MESSAGE_SENT_SIG = keccak256("MessageSent(bytes)");

    function dealExt(address to, uint256 a) external {
        deal(USDC, to, a);
    }

    // ───────── real-contract wiring ─────────

    function test_RealContractsAreWiredTogether() public view {
        assertEq(block.chainid, 5042002);
        assertEq(IUSDCArc(USDC).decimals(), 6);
        assertEq(ITokenMessengerV2Real(TM).localMessageTransmitter(), MT);
        assertEq(ITokenMinterV2Real(minter).getLocalToken(ETH_SEPOLIA, SEPOLIA_USDC), USDC);
        assertEq(IMessageTransmitterV2Real(MT).localDomain(), 26);
        assertEq(remoteMessenger, _b(TM), "domain 0 remote messenger registered on the real TokenMessengerV2");
    }

    function test_RealOwnersRegisterTestAttester() public view {
        assertTrue(IMessageTransmitterV2Real(MT).isEnabledAttester(attester));
        assertEq(IMessageTransmitterV2Real(MT).signatureThreshold(), 1);
    }

    // ───────── (1) setMessageTransmitter reads localDomain() from the real transmitter ─────────

    function test_SetMessageTransmitter_readsLocalDomain26FromRealTransmitter() public {
        assertEq(vault.localDomain(), 26);
        assertEq(vault.messageTransmitter(), MT);
        // A vault whose constructor domain is WRONG (5) must be corrected by the real transmitter's answer.
        vm.startPrank(owner);
        ShariahVaultV2 v2 =
            new ShariahVaultV2(IERC20(USDC), owner, 5, address(treasury), address(0), address(registry));
        assertEq(v2.localDomain(), 5);
        vm.expectEmit(false, false, false, true, address(v2));
        emit AutonomousVault.LocalDomainUpdated(26);
        vm.expectEmit(true, true, false, false, address(v2));
        emit AutonomousVault.MessageTransmitterUpdated(address(0), MT);
        v2.setMessageTransmitter(MT);
        vm.stopPrank();
        assertEq(v2.localDomain(), 26, "domain came from the real MessageTransmitterV2, not the ctor fallback");
        assertEq(v2.sourceDomain(), 5, "immutable sourceDomain untouched");
    }

    function test_SetLocalDomain_rejectsValueDifferentFromRealTransmitter() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.LocalDomainMismatch.selector, 26, 27));
        vault.setLocalDomain(27);
        vm.prank(owner);
        vault.setLocalDomain(26);
        assertEq(vault.localDomain(), 26);
    }

    // ───────── funding methods on the Arc USDC predeploy ─────────

    function test_Funding_stdDealUnsupportedOnArcUsdc() public {
        vm.expectRevert(); // stdstore: "Slot(s) not found" — balances are the NATIVE coin balance, not a storage slot
        this.dealExt(alice, 1e6);
    }

    function test_Funding_nativeDealWorks_scale1e12() public {
        address bob = makeAddr("bob");
        vm.deal(bob, 5e6 * NATIVE_SCALE);
        assertEq(_usdc(bob), 5e6, "ERC-20 view = native balance / 1e12");
    }

    function test_Funding_realMinterMintWorks_andRaisesTotalSupply() public {
        address bob = makeAddr("bob");
        uint256 supplyBefore = IUSDCArc(USDC).totalSupply();
        assertEq(supplyBefore, realSupply + DEPOSIT, "shimmed supply = real on-chain totalSupply + setUp mint");
        _mintUsdc(bob, 7e6);
        assertEq(_usdc(bob), 7e6);
        assertEq(IUSDCArc(USDC).totalSupply(), supplyBefore + 7e6);
    }

    // ───────── (2) deployCrossChain burns through the real TokenMessengerV2.depositForBurn ─────────

    function test_DeployCrossChain_burnsUsdcThroughRealTokenMessenger() public {
        uint256 vaultBal = _usdc(address(vault));
        uint256 supply = IUSDCArc(USDC).totalSupply();
        uint256 nav = vault.totalAssets();
        uint256 minterBal = _usdc(minter);
        uint256 tmBal = _usdc(TM);

        vm.recordLogs();
        vm.expectEmit(true, true, false, true, address(vault));
        emit AutonomousVault.CapitalDeployedCrossChain(ETH_SEPOLIA, _b(remoteRecipient), SENT, 1);
        vm.prank(manager);
        vault.deployCrossChain(ETH_SEPOLIA, _b(remoteRecipient), SENT);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_usdc(address(vault)), vaultBal - SENT, "vault USDC burned");
        assertEq(IUSDCArc(USDC).totalSupply(), supply - SENT, "USDC totalSupply dropped by the burn");
        assertEq(_usdc(minter), minterBal, "no USDC retained by the real TokenMinterV2");
        assertEq(_usdc(TM), tmBal, "no USDC retained by the real TokenMessengerV2");
        assertEq(IUSDCArc(USDC).allowance(address(vault), TM), 0, "burn allowance cleared");
        assertEq(vault.crossChainPositionCounter(), 1);
        assertEq(vault.pendingCrossChain(1), SENT);
        assertEq(vault.pendingCrossChainDestinationDomain(1), ETH_SEPOLIA);
        assertEq(vault.totalPendingCrossChain(), SENT);
        assertEq(vault.totalDeployed(), SENT);
        assertEq(vault.totalAssets(), nav, "NAV unchanged: burned USDC is booked as deployed");
        _assertRealDepositForBurnLog(logs, SENT, 0);
    }

    /// @dev Decodes the REAL TokenMessengerV2 DepositForBurn log and checks the 7-argument fields the vault sent.
    function _assertRealDepositForBurnLog(Vm.Log[] memory logs, uint256 amount, uint256 maxFee) internal view {
        uint256 hits;
        uint256 sent;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == MT && logs[i].topics[0] == MESSAGE_SENT_SIG) sent++;
            if (logs[i].emitter != TM || logs[i].topics[0] != DEPOSIT_FOR_BURN_SIG) continue;
            hits++;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), USDC, "burnToken");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), address(vault), "depositor");
            (uint256 a, bytes32 mintRecipient, uint32 dom, bytes32 destTM, bytes32 destCaller, uint256 mf,) =
                abi.decode(logs[i].data, (uint256, bytes32, uint32, bytes32, bytes32, uint256, bytes));
            assertEq(a, amount);
            assertEq(mintRecipient, _b(remoteRecipient));
            assertEq(dom, ETH_SEPOLIA);
            assertEq(destTM, remoteMessenger);
            assertEq(destCaller, bytes32(0));
            assertEq(mf, maxFee);
        }
        assertEq(hits, 1, "exactly one real DepositForBurn");
        assertEq(sent, 1, "exactly one real MessageSent from the MessageTransmitterV2");
    }

    function test_DeployCrossChain_fastFinalityWithMaxFeeBps() public {
        vm.startPrank(owner);
        vault.setCrossChainMinFinality(1000);
        vault.setCrossChainMaxFeeBps(10); // 0.10%
        vm.stopPrank();
        vm.recordLogs();
        _deployPos(ETH_SEPOLIA, SENT);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertRealDepositForBurnLog(logs, SENT, SENT * 10 / 10_000);
        assertEq(vault.pendingCrossChain(1), SENT);
        assertEq(IUSDCArc(USDC).allowance(address(vault), TM), 0);
    }

    function test_DeployCrossChain_secondPositionGetsNewId() public {
        _deployPos(ETH_SEPOLIA, SENT);
        uint64 pid = _deployPos(ETH_SEPOLIA, 5_000e6);
        assertEq(pid, 2);
        assertEq(vault.totalPendingCrossChain(), 15_000e6);
        assertEq(vault.totalDeployed(), 15_000e6);
    }

    // ───────── deployCrossChain negatives (vault guards + real-contract reverts) ─────────

    function test_DeployCrossChain_unapprovedRecipientReverts() public {
        bytes32 stranger = _b(makeAddr("notApproved"));
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.RemoteRecipientNotApproved.selector, ETH_SEPOLIA, stranger));
        vault.deployCrossChain(ETH_SEPOLIA, stranger, SENT);
    }

    function test_DeployCrossChain_localDomainNeverApproved_reverts() public {
        // Domain 26 (this chain) can never be burned to: the recipient is not approved for it.
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(ShariahVault.RemoteRecipientNotApproved.selector, ARC_DOMAIN, _b(remoteRecipient))
        );
        vault.deployCrossChain(ARC_DOMAIN, _b(remoteRecipient), SENT);
    }

    function test_DeployCrossChain_pendingCapReverts() public {
        uint256 cap = vault.totalAssets() * vault.maxPendingCrossChainBps() / 10_000;
        vm.prank(manager);
        vm.expectRevert(AutonomousVault.PendingCrossChainCapExceeded.selector);
        vault.deployCrossChain(ETH_SEPOLIA, _b(remoteRecipient), cap + 1);
    }

    function test_DeployCrossChain_nonManagerReverts() public {
        vm.prank(alice);
        vm.expectRevert(AutonomousVault.NotManager.selector);
        vault.deployCrossChain(ETH_SEPOLIA, _b(remoteRecipient), SENT);
    }

    function test_DeployCrossChain_domainUnregisteredAtRealTokenMessengerReverts_atomically() public {
        assertEq(ITokenMessengerV2Real(TM).remoteTokenMessengers(UNREGISTERED_AT_TM), bytes32(0));
        uint256 vaultBal = _usdc(address(vault));
        uint256 supply = IUSDCArc(USDC).totalSupply();
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "No TokenMessenger for domain")); // real TokenMessengerV2
        vault.deployCrossChain(UNREGISTERED_AT_TM, _b(remoteRecipient), SENT);
        assertEq(_usdc(address(vault)), vaultBal);
        assertEq(IUSDCArc(USDC).totalSupply(), supply);
        assertEq(vault.totalDeployed(), 0);
        assertEq(vault.totalPendingCrossChain(), 0);
        assertEq(vault.crossChainPositionCounter(), 0);
        assertEq(IUSDCArc(USDC).allowance(address(vault), TM), 0);
    }

    function test_DeployCrossChain_pausedReverts() public {
        vm.prank(owner);
        vault.setPaused(true);
        vm.prank(manager);
        vm.expectRevert(AutonomousVault.Paused.selector);
        vault.deployCrossChain(ETH_SEPOLIA, _b(remoteRecipient), SENT);
    }
}
