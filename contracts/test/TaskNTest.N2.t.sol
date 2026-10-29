// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ShariahVault}           from "../ShariahVault.sol";
import {ShariahVaultV2}         from "../ShariahVaultV2.sol";
import {ShariahAdapterRegistry} from "../ShariahAdapterRegistry.sol";
import {TaskNDustBase}          from "./TaskNTest.DustBase.t.sol";

/// @dev Behaviour that must hold for BOTH vault flavours (V1 owner-board, V2 registry-board).
abstract contract TaskNDustCommon is TaskNDustBase {

    // ── constants / removal ─────────────────────────────────────────────

    function test_constants_and_default() public view {
        assertEq(v.DUST_TIMELOCK(), 30 days);
        assertEq(v.MAX_DUST_BPS(), 50);
        assertEq(v.MIN_DUST_CAP(), 1e6);
        assertEq(v.dustThreshold(), 1e6, "default 1 USDC");
        (, , bool exists) = _pending();
        assertFalse(exists);
    }

    function test_setDustThreshold_removed() public {
        vm.prank(_board());
        (bool ok,) = address(v).call(abi.encodeWithSignature("setDustThreshold(uint256)", 5e6));
        assertFalse(ok, "setDustThreshold must no longer exist");
        vm.prank(owner);
        (ok,) = address(v).call(abi.encodeWithSignature("setDustThreshold(uint256)", 5e6));
        assertFalse(ok);
        assertEq(v.dustThreshold(), 1e6);
    }

    // ── access control ──────────────────────────────────────────────────

    function test_nonBoard_cannotPropose() public {
        address[] memory d = _denied();
        for (uint256 i = 0; i < d.length; i++) {
            vm.prank(d[i]);
            vm.expectRevert(abi.encodeWithSelector(ShariahVault.NotBoardRole.selector, d[i]));
            v.proposeDustThreshold(1e6);
        }
    }

    function test_nonBoard_cannotConfirm_orCancel_evenWithPendingProposal() public {
        _propose(1e6);
        vm.warp(block.timestamp + DUST_TIMELOCK);
        address[] memory d = _denied();
        for (uint256 i = 0; i < d.length; i++) {
            vm.prank(d[i]);
            vm.expectRevert(abi.encodeWithSelector(ShariahVault.NotBoardRole.selector, d[i]));
            v.confirmDustThreshold();
            vm.prank(d[i]);
            vm.expectRevert(abi.encodeWithSelector(ShariahVault.NotBoardRole.selector, d[i]));
            v.cancelDustThreshold();
        }
        (, , bool exists) = _pending();
        assertTrue(exists, "proposal untouched");
    }

    function testFuzz_randomCaller_cannotPropose(address caller) public {
        vm.assume(caller != _board());
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.NotBoardRole.selector, caller));
        v.proposeDustThreshold(0);
    }

    function test_nonBoard_errorPrecedesNothingPending() public {
        // Unauthorised caller gets NotBoardRole, not NoPendingDustProposal.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.NotBoardRole.selector, stranger));
        v.confirmDustThreshold();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.NotBoardRole.selector, stranger));
        v.cancelDustThreshold();
    }

    // ── propose ─────────────────────────────────────────────────────────

    function test_propose_recordsValueAndTime_andLeavesActiveUnchanged() public {
        _setAssets(1_000_000e6);
        uint256 t0 = block.timestamp;

        vm.expectEmit(false, false, false, true, address(v));
        emit ShariahVault.DustThresholdProposed(2_500e6, t0 + DUST_TIMELOCK);
        _propose(2_500e6);

        (uint256 nv, uint256 ea, bool exists) = _pending();
        assertEq(nv, 2_500e6);
        assertEq(ea, t0 + DUST_TIMELOCK);
        assertTrue(exists);
        assertEq(v.dustThreshold(), 1e6, "active threshold unchanged until confirm");
    }

    function test_propose_duplicate_reverts_evenSameValue() public {
        _setAssets(1_000_000e6);
        _propose(2_000e6);
        vm.prank(_board());
        vm.expectRevert(ShariahVault.DustProposalAlreadyExists.selector);
        v.proposeDustThreshold(3_000e6);
        vm.prank(_board());
        vm.expectRevert(ShariahVault.DustProposalAlreadyExists.selector);
        v.proposeDustThreshold(2_000e6);
        (uint256 nv, , ) = _pending();
        assertEq(nv, 2_000e6, "original proposal retained");
    }

    function test_propose_zeroThreshold_accepted_andConfirms() public {
        _propose(0);
        (uint256 nv, , bool exists) = _pending();
        assertEq(nv, 0);
        assertTrue(exists);
        vm.warp(block.timestamp + DUST_TIMELOCK);
        _confirm();
        assertEq(v.dustThreshold(), 0);
    }

    // ── cap math ────────────────────────────────────────────────────────

    function test_cap_exactAccepted_capPlusOneReverts_atPropose() public {
        _setAssets(1_000_000e6); // cap = 5_000e6
        vm.prank(_board());
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.DustThresholdAboveCap.selector, 5_000e6 + 1, 5_000e6));
        v.proposeDustThreshold(5_000e6 + 1);
        _propose(5_000e6);
        (uint256 nv, , ) = _pending();
        assertEq(nv, 5_000e6);
    }

    function test_cap_zeroAssets_usesFloor() public {
        assertEq(v.totalAssets(), 0);
        vm.prank(_board());
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.DustThresholdAboveCap.selector, 1e6 + 1, 1e6));
        v.proposeDustThreshold(1e6 + 1);
        _propose(1e6);
        (uint256 nv, , ) = _pending();
        assertEq(nv, 1e6);
    }

    function test_cap_crossover_200usdc_isExactly1e6() public {
        _setAssets(200e6); // 200e6 * 50 / 10_000 == 1e6
        vm.prank(_board());
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.DustThresholdAboveCap.selector, 1e6 + 1, 1e6));
        v.proposeDustThreshold(1e6 + 1);
        _propose(1e6);
    }

    function test_cap_belowCrossover_floorStillApplies() public {
        _setAssets(199e6); // bps cap = 995_000 < floor
        _propose(1e6);
        (uint256 nv, , ) = _pending();
        assertEq(nv, 1e6);
    }

    function test_cap_aboveCrossover_bpsGovern() public {
        _setAssets(400e6); // cap 2e6
        vm.prank(_board());
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.DustThresholdAboveCap.selector, 2e6 + 1, 2e6));
        v.proposeDustThreshold(2e6 + 1);
        _propose(2e6);
    }

    function testFuzz_cap_boundary(uint256 assets, uint256 proposed) public {
        assets = bound(assets, 0, 1e18);
        _setAssets(assets);
        uint256 cap = _cap(assets);
        proposed = bound(proposed, 0, cap * 2 + 10);
        if (proposed <= cap) {
            _propose(proposed);
            (uint256 nv, , bool exists) = _pending();
            assertEq(nv, proposed);
            assertTrue(exists);
        } else {
            vm.prank(_board());
            vm.expectRevert(abi.encodeWithSelector(ShariahVault.DustThresholdAboveCap.selector, proposed, cap));
            v.proposeDustThreshold(proposed);
            (, , bool exists) = _pending();
            assertFalse(exists);
        }
    }

    function test_cap_exactlyCapAndCapPlusOne_atBoundaryOfAssets() public {
        // assets 1e12-1 => cap 4_999_999_999 ; assets 1e12 => cap 5_000_000_000
        _setAssets(1_000_000e6 - 1);
        vm.prank(_board());
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.DustThresholdAboveCap.selector, 5_000e6, 5_000e6 - 1));
        v.proposeDustThreshold(5_000e6);
        _propose(5_000e6 - 1);
    }

    // ── confirm / timelock ──────────────────────────────────────────────

    function test_confirm_nothingPending_reverts() public {
        vm.prank(_board());
        vm.expectRevert(ShariahVault.NoPendingDustProposal.selector);
        v.confirmDustThreshold();
    }

    function test_cancel_nothingPending_reverts() public {
        vm.prank(_board());
        vm.expectRevert(ShariahVault.NoPendingDustProposal.selector);
        v.cancelDustThreshold();
    }

    function test_confirm_oneSecondEarly_reverts() public {
        _setAssets(1_000_000e6);
        uint256 t0 = block.timestamp;
        _propose(2_000e6);
        vm.warp(t0 + DUST_TIMELOCK - 1);
        vm.prank(_board());
        vm.expectRevert(abi.encodeWithSelector(
            ShariahVault.DustTimelockNotElapsed.selector, t0 + DUST_TIMELOCK, t0 + DUST_TIMELOCK - 1
        ));
        v.confirmDustThreshold();
        assertEq(v.dustThreshold(), 1e6);
        (, , bool exists) = _pending();
        assertTrue(exists);
    }

    function test_confirm_atExactly30Days_succeeds_emits_andClearsState() public {
        _setAssets(1_000_000e6);
        uint256 t0 = block.timestamp;
        _propose(2_000e6);
        vm.warp(t0 + DUST_TIMELOCK);

        vm.expectEmit(false, false, false, true, address(v));
        emit ShariahVault.DustThresholdUpdated(1e6, 2_000e6);
        _confirm();

        assertEq(v.dustThreshold(), 2_000e6);
        (uint256 nv, uint256 ea, bool exists) = _pending();
        assertEq(nv, 0);
        assertEq(ea, 0);
        assertFalse(exists);

        // second confirm has nothing to do
        vm.prank(_board());
        vm.expectRevert(ShariahVault.NoPendingDustProposal.selector);
        v.confirmDustThreshold();
    }

    function test_confirm_afterLongDelay_stillSucceeds() public {
        _setAssets(1_000_000e6);
        _propose(2_000e6);
        vm.warp(block.timestamp + 365 days);
        _confirm();
        assertEq(v.dustThreshold(), 2_000e6);
    }

    function test_confirm_thenRepropose_usesPreviousAsPrevious() public {
        _setAssets(1_000_000e6);
        _propose(2_000e6);
        vm.warp(block.timestamp + DUST_TIMELOCK);
        _confirm();
        _propose(3_000e6);
        vm.warp(block.timestamp + DUST_TIMELOCK);
        vm.expectEmit(false, false, false, true, address(v));
        emit ShariahVault.DustThresholdUpdated(2_000e6, 3_000e6);
        _confirm();
        assertEq(v.dustThreshold(), 3_000e6);
    }

    function test_confirm_rechecksCap_capPlusOne_reverts_proposalKept() public {
        _setAssets(1_000_000e6);
        _propose(5_000e6); // exactly cap now
        vm.warp(block.timestamp + DUST_TIMELOCK);
        usdc.burn(address(v), 1); // assets 1e12 - 1 => cap = 5_000e6 - 1
        vm.prank(_board());
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.DustThresholdAboveCap.selector, 5_000e6, 5_000e6 - 1));
        v.confirmDustThreshold();
        (uint256 nv, , bool exists) = _pending();
        assertTrue(exists, "proposal kept");
        assertEq(nv, 5_000e6);
        assertEq(v.dustThreshold(), 1e6, "active unchanged");
    }

    function test_confirm_shrinkingAssets_reverts_thenRecoveryAllowsConfirm() public {
        _setAssets(1_000_000e6);
        _propose(4_000e6);
        vm.warp(block.timestamp + DUST_TIMELOCK);
        _setAssets(100_000e6); // cap 500e6 < 4_000e6
        vm.prank(_board());
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.DustThresholdAboveCap.selector, 4_000e6, 500e6));
        v.confirmDustThreshold();
        (, , bool exists) = _pending();
        assertTrue(exists);
        _setAssets(1_000_000e6); // NAV recovers
        _confirm();
        assertEq(v.dustThreshold(), 4_000e6);
    }

    function test_confirm_shrinkingToZero_floorStillAllowsSmallProposal() public {
        _setAssets(1_000_000e6);
        _propose(1e6);
        vm.warp(block.timestamp + DUST_TIMELOCK);
        _setAssets(0);
        _confirm(); // 1e6 <= floor
        assertEq(v.dustThreshold(), 1e6);
    }

    function test_confirm_growingAssets_doesNotRaiseAlreadyProposedValue() public {
        _setAssets(1_000_000e6);
        _propose(1_000e6);
        _setAssets(10_000_000e6);
        vm.warp(block.timestamp + DUST_TIMELOCK);
        _confirm();
        assertEq(v.dustThreshold(), 1_000e6);
    }

    // ── cancel ──────────────────────────────────────────────────────────

    function test_cancel_emits_clears_andAllowsRepropose() public {
        _setAssets(1_000_000e6);
        _propose(2_000e6);

        vm.expectEmit(false, false, false, false, address(v));
        emit ShariahVault.DustThresholdProposalCancelled();
        _cancel();

        (uint256 nv, uint256 ea, bool exists) = _pending();
        assertEq(nv, 0);
        assertEq(ea, 0);
        assertFalse(exists);
        assertEq(v.dustThreshold(), 1e6);

        // cancelled proposal cannot be confirmed
        vm.warp(block.timestamp + DUST_TIMELOCK);
        vm.prank(_board());
        vm.expectRevert(ShariahVault.NoPendingDustProposal.selector);
        v.confirmDustThreshold();

        // fresh proposal restarts the clock
        uint256 t1 = block.timestamp;
        _propose(3_000e6);
        (nv, ea, exists) = _pending();
        assertEq(nv, 3_000e6);
        assertEq(ea, t1 + DUST_TIMELOCK);
        assertTrue(exists);
    }

    function test_cancel_ignoresTimelockAndCap() public {
        _setAssets(1_000_000e6);
        _propose(5_000e6);
        _setAssets(0); // proposal now above cap; cancel must still work
        _cancel();
        (, , bool exists) = _pending();
        assertFalse(exists);
    }
}

// ─────────────────────────────────────────────────────────────────────────
//  V1: board == owner
// ─────────────────────────────────────────────────────────────────────────
contract TaskNDustV1Test is TaskNDustCommon {
    function _deployVault() internal override {
        v = new ShariahVault(IERC20(address(usdc)), owner, SOURCE_DOMAIN, address(treasury), address(0));
    }

    function _board() internal view override returns (address) { return owner; }

    function _denied() internal view override returns (address[] memory d) {
        d = new address[](4);
        d[0] = alice; d[1] = stranger; d[2] = manager; d[3] = boardMember;
    }

    function test_v1_owner_canDoAllThree() public {
        _setAssets(1_000_000e6);
        vm.startPrank(owner);
        v.proposeDustThreshold(2_000e6);
        v.cancelDustThreshold();
        v.proposeDustThreshold(3_000e6);
        vm.warp(block.timestamp + DUST_TIMELOCK);
        v.confirmDustThreshold();
        vm.stopPrank();
        assertEq(v.dustThreshold(), 3_000e6);
    }

    function test_v1_ownershipTransfer_movesBoardRole() public {
        _setAssets(1_000_000e6);
        _propose(2_000e6);
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        v.transferOwnership(newOwner);
        vm.prank(newOwner);
        v.acceptOwnership();

        vm.warp(block.timestamp + DUST_TIMELOCK);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.NotBoardRole.selector, owner));
        v.confirmDustThreshold();

        vm.prank(newOwner);
        v.confirmDustThreshold();
        assertEq(v.dustThreshold(), 2_000e6);
    }
}
