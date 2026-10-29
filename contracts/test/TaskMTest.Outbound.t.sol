// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AutonomousVault} from "../AutonomousVault.sol";
import {TaskMBase, MockTransmitterM} from "./TaskMTest.Base.t.sol";

/// @title TaskMTest.Outbound — native depositForBurn arguments plus owner-only configuration setters.
contract TaskMOutboundTest is TaskMBase {
    function _lastCall()
        internal
        view
        returns (uint256 amount, uint32 domain, bytes32 rcpt, address token, bytes32 caller, uint256 maxFee, uint32 fin)
    {
        return messenger.last();
    }

    // ───────────── outbound depositForBurn ─────────────

    function test_outbound_defaults_recordAllSevenArgs() public {
        _deploy(REMOTE_DOMAIN, SENT);
        (uint256 amount, uint32 domain, bytes32 rcpt, address token, bytes32 caller, uint256 maxFee, uint32 fin) =
            _lastCall();
        assertEq(amount, SENT);
        assertEq(domain, REMOTE_DOMAIN);
        assertEq(rcpt, _b32(remoteRecipientAddr));
        assertEq(token, address(usdc), "burnToken = asset");
        assertEq(caller, bytes32(0), "destinationCaller = 0");
        assertEq(maxFee, 0, "default bps 0 -> maxFee 0");
        assertEq(fin, 2000, "default finality = standard");
        assertEq(messenger.callCount(), 1);
    }

    function test_outbound_configuredFeeAndFinality_integerRounding() public {
        vm.startPrank(owner);
        vault.setCrossChainMaxFeeBps(37);
        vault.setCrossChainMinFinality(1000);
        vm.stopPrank();
        uint256 amount = 12_345_678; // 12.345678 USDC: 37 bps = 4567.9 -> rounds down
        _deploy(OTHER_DOMAIN, amount);
        (uint256 a, uint32 domain, bytes32 rcpt, address token, bytes32 caller, uint256 maxFee, uint32 fin) =
            _lastCall();
        assertEq(a, amount);
        assertEq(domain, OTHER_DOMAIN);
        assertEq(rcpt, _b32(remoteRecipientAddr));
        assertEq(token, address(usdc));
        assertEq(caller, bytes32(0));
        assertEq(maxFee, (amount * 37) / 10_000);
        assertEq(maxFee, 45_679);
        assertEq(fin, 1000);
    }

    function test_outbound_tinyAmount_feeRoundsToZero() public {
        vm.prank(owner);
        vault.setCrossChainMaxFeeBps(100);
        _deploy(REMOTE_DOMAIN, 99); // 99 * 100 / 10_000 = 0
        (, , , , , uint256 maxFee,) = _lastCall();
        assertEq(maxFee, 0);
    }

    function test_outbound_maxBps_isOnePercent() public {
        vm.prank(owner);
        vault.setCrossChainMaxFeeBps(100);
        _deploy(REMOTE_DOMAIN, SENT);
        (, , , , , uint256 maxFee,) = _lastCall();
        assertEq(maxFee, SENT / 100);
    }

    function testFuzz_outbound_maxFeeFormula_andAllowanceCleared(uint256 amount, uint256 bps, bool fast) public {
        amount = bound(amount, 1, 40_000e6);
        bps = bound(bps, 0, 100);
        vm.startPrank(owner);
        vault.setCrossChainMaxFeeBps(bps);
        vault.setCrossChainMinFinality(fast ? 1000 : 2000);
        vm.stopPrank();
        _deploy(REMOTE_DOMAIN, amount);
        (uint256 a, , , , , uint256 maxFee, uint32 fin) = _lastCall();
        assertEq(a, amount);
        assertEq(maxFee, (amount * bps) / 10_000);
        assertEq(fin, fast ? 1000 : 2000);
        assertEq(usdc.allowance(address(vault), address(messenger)), 0);
    }

    function test_outbound_exactAllowanceGranted_thenCleared() public {
        _deploy(REMOTE_DOMAIN, SENT);
        assertEq(messenger.allowanceSeen(), SENT, "exact allowance during burn");
        assertEq(usdc.allowance(address(vault), address(messenger)), 0, "cleared afterwards");
        assertEq(usdc.balanceOf(address(messenger)), SENT, "tokens burned/pulled");
    }

    function test_outbound_partialPull_residualAllowanceCleared() public {
        messenger.configure(true, true);
        _deploy(REMOTE_DOMAIN, SENT);
        assertEq(usdc.balanceOf(address(messenger)), SENT / 2);
        assertEq(usdc.allowance(address(vault), address(messenger)), 0, "residual allowance cleared");
    }

    function test_outbound_noPull_allowanceStillCleared() public {
        messenger.configure(false, false);
        _deploy(REMOTE_DOMAIN, SENT);
        assertEq(usdc.allowance(address(vault), address(messenger)), 0);
    }

    function test_outbound_ownerCanAlsoDeploy_andBookkeepingUpdated() public {
        vm.prank(owner);
        vault.deployCrossChain(REMOTE_DOMAIN, _b32(alice), SENT);
        assertEq(vault.pendingCrossChain(1), SENT);
        assertEq(vault.totalDeployed(), SENT);
        assertEq(vault.totalPendingCrossChain(), SENT);
    }

    function test_outbound_revertPaths() public {
        vm.prank(stranger);
        vm.expectRevert(AutonomousVault.NotManager.selector);
        vault.deployCrossChain(REMOTE_DOMAIN, _b32(alice), SENT);

        vm.prank(manager);
        vm.expectRevert(AutonomousVault.SameDomainDeploy.selector);
        vault.deployCrossChain(LOCAL_DOMAIN, _b32(alice), SENT);

        vm.prank(manager);
        vm.expectRevert(AutonomousVault.PendingCrossChainCapExceeded.selector);
        vault.deployCrossChain(REMOTE_DOMAIN, _b32(alice), 50_000e6 + 1);

        vm.prank(manager);
        vm.expectRevert(AutonomousVault.AllocationExceedsLimit.selector);
        vault.deployCrossChain(REMOTE_DOMAIN, _b32(alice), DEPOSIT);

        vm.prank(owner);
        vault.setPaused(true);
        vm.prank(manager);
        vm.expectRevert(AutonomousVault.Paused.selector);
        vault.deployCrossChain(REMOTE_DOMAIN, _b32(alice), SENT);
        assertEq(messenger.callCount(), 0);
        assertEq(vault.crossChainPositionCounter(), 0);
    }

    function test_outbound_messengerUnset_revertsNotConfigured() public {
        vm.prank(owner);
        AutonomousVault v2 = new AutonomousVault(IERC20(address(usdc)), owner, LOCAL_DOMAIN);
        vm.prank(owner);
        v2.setManager(manager);
        vm.prank(manager);
        vm.expectRevert(AutonomousVault.CrossChainNotConfigured.selector);
        v2.deployCrossChain(REMOTE_DOMAIN, _b32(alice), 1);
    }

    function test_outbound_capRevert_doesNotAdvanceCounterOrPending() public {
        _deploy(REMOTE_DOMAIN, 45_000e6); // pending cap is 50% of 100_000e6
        uint256 counterBefore = vault.crossChainPositionCounter();
        vm.prank(manager);
        vm.expectRevert(AutonomousVault.PendingCrossChainCapExceeded.selector);
        vault.deployCrossChain(REMOTE_DOMAIN, _b32(alice), 6_000e6);
        assertEq(vault.crossChainPositionCounter(), counterBefore);
        assertEq(vault.totalPendingCrossChain(), 45_000e6);
    }

    // ───────────── setters: crossChainMinFinality ─────────────

    function test_defaults() public view {
        assertEq(vault.crossChainMinFinality(), 2000);
        assertEq(vault.crossChainMaxFeeBps(), 0);
        assertEq(vault.MAX_CROSS_CHAIN_FEE_BPS(), 100);
        assertEq(vault.crossChainPositionCounter(), 0);
    }

    function test_setMinFinality_1000_and_2000_emit() public {
        vm.startPrank(owner);
        vm.expectEmit(false, false, false, true, address(vault));
        emit AutonomousVault.CrossChainMinFinalityUpdated(2000, 1000);
        vault.setCrossChainMinFinality(1000);
        assertEq(vault.crossChainMinFinality(), 1000);
        vm.expectEmit(false, false, false, true, address(vault));
        emit AutonomousVault.CrossChainMinFinalityUpdated(1000, 2000);
        vault.setCrossChainMinFinality(2000);
        assertEq(vault.crossChainMinFinality(), 2000);
        vm.stopPrank();
    }

    function testFuzz_setMinFinality_otherValuesRevert(uint32 f) public {
        vm.assume(f != 1000 && f != 2000);
        vm.prank(owner);
        vm.expectRevert(AutonomousVault.InvalidCrossChainMinFinality.selector);
        vault.setCrossChainMinFinality(f);
        assertEq(vault.crossChainMinFinality(), 2000);
    }

    function test_setMinFinality_boundaryNeighboursRevert() public {
        uint32[6] memory bad = [uint32(0), 1, 999, 1001, 1999, 2001];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.prank(owner);
            vm.expectRevert(AutonomousVault.InvalidCrossChainMinFinality.selector);
            vault.setCrossChainMinFinality(bad[i]);
        }
    }

    function test_setMinFinality_ownerOnly() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, manager));
        vault.setCrossChainMinFinality(1000);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.setCrossChainMinFinality(1000);
    }

    // ───────────── setters: crossChainMaxFeeBps ─────────────

    function test_setMaxFeeBps_bounds_andEvents() public {
        vm.startPrank(owner);
        vm.expectEmit(false, false, false, true, address(vault));
        emit AutonomousVault.CrossChainMaxFeeBpsUpdated(0, 100);
        vault.setCrossChainMaxFeeBps(100);
        assertEq(vault.crossChainMaxFeeBps(), 100);
        vm.expectEmit(false, false, false, true, address(vault));
        emit AutonomousVault.CrossChainMaxFeeBpsUpdated(100, 0);
        vault.setCrossChainMaxFeeBps(0);
        assertEq(vault.crossChainMaxFeeBps(), 0);
        vault.setCrossChainMaxFeeBps(1);
        assertEq(vault.crossChainMaxFeeBps(), 1);
        vm.expectRevert(AutonomousVault.InvalidBps.selector);
        vault.setCrossChainMaxFeeBps(101);
        vm.stopPrank();
        assertEq(vault.crossChainMaxFeeBps(), 1);
    }

    function testFuzz_setMaxFeeBps_aboveCapReverts_belowAccepted(uint256 bps) public {
        vm.prank(owner);
        if (bps > 100) {
            vm.expectRevert(AutonomousVault.InvalidBps.selector);
            vault.setCrossChainMaxFeeBps(bps);
            assertEq(vault.crossChainMaxFeeBps(), 0);
        } else {
            vault.setCrossChainMaxFeeBps(bps);
            assertEq(vault.crossChainMaxFeeBps(), bps);
        }
    }

    function test_setMaxFeeBps_ownerOnly() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, manager));
        vault.setCrossChainMaxFeeBps(1);
    }

    // ───────────── setters: remote messenger / local wiring ─────────────

    function test_setRemoteTokenMessenger_storesAndEmits() public {
        bytes32 m = _b32(makeAddr("anotherRemote"));
        vm.expectEmit(true, false, false, true, address(vault));
        emit AutonomousVault.RemoteTokenMessengerUpdated(OTHER_DOMAIN, m);
        vm.prank(owner);
        vault.setRemoteTokenMessenger(OTHER_DOMAIN, m);
        assertEq(vault.remoteTokenMessenger(OTHER_DOMAIN), m);
        // overwrite allowed, domain 0 is a real domain
        vm.startPrank(owner);
        vault.setRemoteTokenMessenger(OTHER_DOMAIN, _b32(remoteMessengerAddr));
        vault.setRemoteTokenMessenger(0, m);
        vm.stopPrank();
        assertEq(vault.remoteTokenMessenger(OTHER_DOMAIN), _b32(remoteMessengerAddr));
        assertEq(vault.remoteTokenMessenger(0), m);
    }

    function test_setRemoteTokenMessenger_zeroReverts_ownerOnly() public {
        vm.prank(owner);
        vm.expectRevert(AutonomousVault.ZeroAddress.selector);
        vault.setRemoteTokenMessenger(OTHER_DOMAIN, bytes32(0));
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, manager));
        vault.setRemoteTokenMessenger(OTHER_DOMAIN, _b32(alice));
    }

    function test_setTokenMessenger_zeroReverts_updatesAndEmits_ownerOnly() public {
        vm.prank(owner);
        vm.expectRevert(AutonomousVault.ZeroAddress.selector);
        vault.setTokenMessenger(address(0));

        address newM = makeAddr("newMessenger");
        vm.expectEmit(true, true, false, false, address(vault));
        emit AutonomousVault.TokenMessengerUpdated(address(messenger), newM);
        vm.prank(owner);
        vault.setTokenMessenger(newM);
        assertEq(vault.tokenMessenger(), newM);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, manager));
        vault.setTokenMessenger(newM);
    }

    function test_setMessageTransmitter_zeroReverts_updatesAndEmits_ownerOnly() public {
        vm.prank(owner);
        vm.expectRevert(AutonomousVault.ZeroAddress.selector);
        vault.setMessageTransmitter(address(0));

        MockTransmitterM plain = new MockTransmitterM(usdc);
        vm.expectEmit(true, true, false, false, address(vault));
        emit AutonomousVault.MessageTransmitterUpdated(address(transmitter), address(plain));
        vm.prank(owner);
        vault.setMessageTransmitter(address(plain));
        assertEq(vault.messageTransmitter(), address(plain));

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, manager));
        vault.setMessageTransmitter(address(plain));
    }

    function test_setMessageTransmitter_adoptsReportedDomain_includingZero() public {
        transmitter.setDomain(0);
        vm.expectEmit(false, false, false, true, address(vault));
        emit AutonomousVault.LocalDomainUpdated(0);
        vm.prank(owner);
        vault.setMessageTransmitter(address(transmitter));
        assertEq(vault.localDomain(), 0);
        transmitter.setDomain(77);
        vm.prank(owner);
        vault.setMessageTransmitter(address(transmitter));
        assertEq(vault.localDomain(), 77);
    }

    function test_setLocalDomain_mismatchWithTransmitterReverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.LocalDomainMismatch.selector, LOCAL_DOMAIN, uint32(5)));
        vault.setLocalDomain(5);
        vm.prank(owner);
        vault.setLocalDomain(LOCAL_DOMAIN);
        assertEq(vault.localDomain(), LOCAL_DOMAIN);
    }

    function test_setLocalDomain_transmitterWithoutLocalDomain_acceptsAnyIncludingZero() public {
        MockTransmitterM plain = new MockTransmitterM(usdc);
        vm.startPrank(owner);
        vault.setMessageTransmitter(address(plain));
        vm.expectEmit(false, false, false, true, address(vault));
        emit AutonomousVault.LocalDomainUpdated(0);
        vault.setLocalDomain(0);
        assertEq(vault.localDomain(), 0, "domain zero is valid");
        vault.setLocalDomain(123);
        assertEq(vault.localDomain(), 123);
        vm.stopPrank();
    }

    function test_setLocalDomain_noTransmitter_revertsZeroAddress_ownerOnly() public {
        vm.prank(owner);
        AutonomousVault v2 = new AutonomousVault(IERC20(address(usdc)), owner, LOCAL_DOMAIN);
        vm.prank(owner);
        vm.expectRevert(AutonomousVault.ZeroAddress.selector);
        v2.setLocalDomain(1);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, manager));
        vault.setLocalDomain(LOCAL_DOMAIN);
    }
}
