// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GoldExitBase, GoldExitExchangeFixture, GoldExitAllocFixture, IGoldX, ActorProxy} from "./GoldEmergencyExitTest.Base.t.sol";

/// @dev Proposal lifecycle: legacy one-call path, delay/window boundaries, single pending, cancel, replace, held recheck.
abstract contract GoldExitLifecycleSuite is GoldExitBase {
    uint256 internal amt;
    uint256 internal minOut;

    function _ready() internal {
        _open(DEPLOY);
        _enable();
        amt = _held() / 2;
        minOut = _floor(amt);
    }

    function _pending() internal view returns (uint256 t, uint256 m, uint256 ea, uint256 ex) {
        return adapter.pendingEmergencyExit();
    }

    // ── legacy one-call path is dead ────────────────────────────────────
    function test_legacyEmergencyExit_alwaysReverts_owner() public {
        vm.startPrank(owner);
        vm.expectRevert(EmergencyExitRequiresProposal.selector);
        adapter.emergencyExit(0, 0);
        vm.expectRevert(EmergencyExitRequiresProposal.selector);
        adapter.emergencyExit(1, 1);
        vm.stopPrank();
    }

    function test_legacyEmergencyExit_alwaysReverts_enabledFundedAndRipeProposal() public {
        _ready();
        _propose(amt, minOut);
        _wait();
        uint256 h = _held();
        uint256 calls = router.calls();
        vm.startPrank(owner);
        vm.expectRevert(EmergencyExitRequiresProposal.selector);
        adapter.emergencyExit(amt, minOut);
        vm.expectRevert(EmergencyExitRequiresProposal.selector);
        adapter.emergencyExit(h, type(uint256).max);
        vm.expectRevert(EmergencyExitRequiresProposal.selector);
        adapter.emergencyExit(1, 1);
        vm.stopPrank();
        assertEq(_held(), h);
        assertEq(router.calls(), calls);
        (uint256 t,,,) = _pending();
        assertEq(t, amt, "legacy call does not consume the proposal");
    }

    function test_legacyEmergencyExit_nonOwnerStillUnauthorized() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        adapter.emergencyExit(1, 1);
    }

    // ── proposal storage + event ────────────────────────────────────────
    function test_propose_storesTimesAndEmits() public {
        _ready();
        uint256 ea = block.timestamp + 1 hours;
        uint256 ex = ea + 24 hours;
        uint256 h0 = _held();
        vm.expectEmit(false, false, false, true, address(adapter));
        emit EmergencyExitProposed(amt, minOut, ea, ex);
        _propose(amt, minOut);
        (uint256 t, uint256 m, uint256 a, uint256 e) = _pending();
        assertEq(t, amt);
        assertEq(m, minOut);
        assertEq(a, ea);
        assertEq(e, ex);
        assertEq(_held(), h0, "propose moves nothing");
        assertEq(router.calls(), 1);
    }

    function test_propose_canPropose_fullHeld() public {
        _ready();
        uint256 h = _held();
        _propose(h, _floor(h));
        (uint256 t,,,) = _pending();
        assertEq(t, h);
    }

    // ── delay / window boundaries ───────────────────────────────────────
    function test_execute_oneSecondBeforeExecuteAfter_reverts() public {
        _ready();
        _propose(amt, minOut);
        (,, uint256 ea,) = _pending();
        vm.warp(ea - 1);
        _freshOracle();
        uint256 h = _held();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(EmergencyExitNotReady.selector, ea));
        adapter.executeEmergencyExit();
        assertEq(_held(), h);
        (uint256 t,,,) = _pending();
        assertEq(t, amt, "still pending");
    }

    function test_execute_atExecuteAfter_succeeds() public {
        _ready();
        _propose(amt, minOut);
        (,, uint256 ea,) = _pending();
        vm.warp(ea);
        _freshOracle();
        uint256 h = _held();
        assertGt(_execute(), 0);
        assertEq(_held(), h - amt);
    }

    function test_execute_atExpiresAt_succeeds_inclusive() public {
        _ready();
        _propose(amt, minOut);
        (,,, uint256 ex) = _pending();
        assertEq(ex, block.timestamp + 25 hours);
        vm.warp(ex);
        _freshOracle();
        uint256 h = _held();
        assertGt(_execute(), 0);
        assertEq(_held(), h - amt);
    }

    function test_execute_oneSecondAfterExpiresAt_reverts() public {
        _ready();
        _propose(amt, minOut);
        (,,, uint256 ex) = _pending();
        vm.warp(ex + 1);
        _freshOracle();
        uint256 h = _held();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(EmergencyExitExpired.selector, ex));
        adapter.executeEmergencyExit();
        assertEq(_held(), h);
    }

    function test_execute_immediately_reverts() public {
        _ready();
        _propose(amt, minOut);
        (,, uint256 ea,) = _pending();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(EmergencyExitNotReady.selector, ea));
        adapter.executeEmergencyExit();
    }

    // ── execute consumes the proposal ───────────────────────────────────
    function test_execute_clearsProposal_noReplay() public {
        _ready();
        _exitMin(amt, minOut);
        (uint256 t, uint256 m, uint256 a, uint256 e) = _pending();
        assertEq(t, 0);
        assertEq(m, 0);
        assertEq(a, 0);
        assertEq(e, 0);
        uint256 h = _held();
        vm.prank(owner);
        vm.expectRevert(NoEmergencyExitProposal.selector);
        adapter.executeEmergencyExit();
        assertEq(_held(), h);
    }

    function test_execute_withoutProposal_reverts() public {
        _ready();
        vm.prank(owner);
        vm.expectRevert(NoEmergencyExitProposal.selector);
        adapter.executeEmergencyExit();
    }

    // ── single pending proposal ─────────────────────────────────────────
    function test_secondProposal_reverts_whilePending() public {
        _ready();
        _propose(amt, minOut);
        vm.startPrank(owner);
        vm.expectRevert(EmergencyExitProposalExists.selector);
        adapter.proposeEmergencyExit(amt, minOut);
        vm.expectRevert(EmergencyExitProposalExists.selector);
        adapter.proposeEmergencyExit(1, type(uint256).max);
        vm.stopPrank();
        (uint256 t, uint256 m,,) = _pending();
        assertEq(t, amt);
        assertEq(m, minOut);
    }

    // ── cancel + replace ────────────────────────────────────────────────
    function test_cancel_clearsAndEmits_thenExecuteReverts() public {
        _ready();
        _propose(amt, minOut);
        vm.expectEmit(false, false, false, false, address(adapter));
        emit EmergencyExitCancelled();
        vm.prank(owner);
        adapter.cancelEmergencyExit();
        (uint256 t,,,) = _pending();
        assertEq(t, 0);
        _wait();
        uint256 h = _held();
        vm.prank(owner);
        vm.expectRevert(NoEmergencyExitProposal.selector);
        adapter.executeEmergencyExit();
        assertEq(_held(), h);
    }

    function test_cancel_withoutProposal_reverts() public {
        _ready();
        vm.prank(owner);
        vm.expectRevert(NoEmergencyExitProposal.selector);
        adapter.cancelEmergencyExit();
    }

    function test_cancel_twice_secondReverts() public {
        _ready();
        _propose(amt, minOut);
        vm.startPrank(owner);
        adapter.cancelEmergencyExit();
        vm.expectRevert(NoEmergencyExitProposal.selector);
        adapter.cancelEmergencyExit();
        vm.stopPrank();
    }

    function test_replaceAfterCancel_usesNewParamsAndFreshClock() public {
        _ready();
        _propose(amt, minOut);
        vm.warp(block.timestamp + 30 minutes);
        vm.prank(owner);
        adapter.cancelEmergencyExit();

        uint256 amt2 = _held() / 4;
        uint256 min2 = _floor(amt2) + 5;
        _propose(amt2, min2);
        (uint256 t, uint256 m, uint256 ea, uint256 ex) = _pending();
        assertEq(t, amt2);
        assertEq(m, min2);
        assertEq(ea, block.timestamp + 1 hours, "delay restarts");
        assertEq(ex, ea + 24 hours);

        // the old proposal's timing no longer applies: new delay must elapse
        vm.warp(ea - 1);
        _freshOracle();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(EmergencyExitNotReady.selector, ea));
        adapter.executeEmergencyExit();
        vm.warp(ea);
        _freshOracle();
        uint256 h = _held();
        _execute();
        assertEq(_held(), h - amt2, "executes the replacement amount only");
    }

    // ── expiry ──────────────────────────────────────────────────────────
    function test_expiredProposal_cannotExecute_canBeCancelledAndReplaced() public {
        _ready();
        _propose(amt, minOut);
        (,,, uint256 ex) = _pending();
        vm.warp(ex + 1);
        _freshOracle();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(EmergencyExitExpired.selector, ex));
        adapter.executeEmergencyExit();

        // The expired record still occupies the single slot until cancelled.
        vm.prank(owner);
        vm.expectRevert(EmergencyExitProposalExists.selector);
        adapter.proposeEmergencyExit(amt, minOut);

        vm.prank(owner);
        adapter.cancelEmergencyExit();
        uint256 min2 = _floor(amt);
        _propose(amt, min2);
        (uint256 t,, uint256 ea2,) = _pending();
        assertEq(t, amt);
        assertEq(ea2, block.timestamp + 1 hours);
        _wait();
        uint256 h = _held();
        assertGt(_execute(), 0);
        assertEq(_held(), h - amt);
    }

    // ── held-balance recheck at execution ───────────────────────────────
    function test_execute_rechecksHeld_afterRecall() public {
        _ready();
        uint256 h = _held();
        _propose(h, _floor(h)); // whole position
        vaultP.forward(address(adapter), abi.encodeCall(IGoldX.recall, (DEPLOY)));
        assertEq(_held(), 0);
        _wait();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AmountExceedsHeld.selector, h, 0));
        adapter.executeEmergencyExit();
        (uint256 t,,,) = _pending();
        assertEq(t, h, "proposal retained");
    }

    function test_execute_rechecksHeld_afterRecallAndSmallerRedeploy() public {
        _ready();
        uint256 h = _held();
        _propose(h, _floor(h));
        vaultP.forward(address(adapter), abi.encodeCall(IGoldX.recall, (DEPLOY)));
        _open(10_000e6);
        uint256 h2 = _held();
        assertLt(h2, h);
        _wait();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AmountExceedsHeld.selector, h, h2));
        adapter.executeEmergencyExit();
        assertEq(_held(), h2);
    }

    function test_execute_exactHeld_boundarySucceeds() public {
        _ready();
        uint256 h = _held();
        _propose(h, _floor(h));
        _wait();
        assertGt(_execute(), 0);
        assertEq(_held(), 0);
        assertEq(adapter.totalDeployed(), 0);
    }
}

contract GoldExchangeEmergencyExitLifecycleTest is GoldExitLifecycleSuite, GoldExitExchangeFixture {}
contract GoldAllocationEmergencyExitLifecycleTest is GoldExitLifecycleSuite, GoldExitAllocFixture {}
