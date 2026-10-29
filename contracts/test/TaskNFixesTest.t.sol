// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm}      from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20}  from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ShariahVault}           from "../ShariahVault.sol";
import {ShariahVaultV2}         from "../ShariahVaultV2.sol";
import {ShariahAdapterRegistry} from "../ShariahAdapterRegistry.sol";
import {TaskNDustBase}          from "./TaskNTest.DustBase.t.sol";

/// @dev Minimal gold adapter with scriptable value / price sanity.
contract MockGoldAdapterFix {
    function isGoldStrategy() external pure returns (bool) { return true; }
    uint256 public currentValue;
    bool    public isPriceSane = true;
    function set(uint256 v_, bool sane_) external { currentValue = v_; isPriceSane = sane_; }
}

/// @dev R-1 (effectiveDustThreshold) and R-3 (gold adapter exposure lock) — run on V1 and V2.
abstract contract TaskNFixesCommon is TaskNDustBase {
    uint256 internal constant NAV = 1_000_000e6; // cap = 5_000e6

    function _mock(uint256 val, bool sane) internal returns (MockGoldAdapterFix m) {
        m = new MockGoldAdapterFix();
        m.set(val, sane);
    }

    function _confirmThreshold(uint256 val) internal {
        _propose(val);
        vm.warp(block.timestamp + DUST_TIMELOCK);
        _confirm();
        assertEq(v.dustThreshold(), val, "threshold confirmed");
    }

    function _aliceCanDeposit(uint256 amt) internal returns (bool ok) {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(v), type(uint256).max);
        try v.deposit(amt, alice) { ok = true; } catch { ok = false; }
        vm.stopPrank();
    }

    // ───────────────────────── R-1 ─────────────────────────

    function test_R1_constants() public view {
        assertEq(v.MIN_DUST_CAP(), 1e6);
        assertEq(v.MAX_DUST_BPS(), 50);
    }

    function test_R1_shrinkingAum_clampsEffective_andRepausesStaleGold() public {
        _setAssets(NAV);
        _openGold(4_000e6);
        uint256 X = goldAdapter.currentValue();
        assertGt(X, 500e6, "X above clamped value");
        assertLe(X, 5_000e6, "X within confirmed threshold");

        _confirmThreshold(5_000e6);
        // Matching principal bookkeeping now recognizes the stale haircut in NAV; restore the intended AUM boundary.
        _setAssets(NAV);
        assertFalse(goldAdapter.isPriceSane(), "oracle stale");
        assertEq(v.effectiveDustThreshold(), 5_000e6, "full threshold at 1M AUM");
        assertGt(v.maxDeposit(alice), 0, "deposits open at 1M AUM");
        assertGt(v.maxMint(alice), 0, "mints open at 1M AUM");
        assertTrue(_aliceCanDeposit(10e6));

        _setAssets(100_000e6);
        assertEq(v.dustThreshold(), 5_000e6, "stored threshold unchanged by shrink");
        assertEq(v.effectiveDustThreshold(), 500e6, "effective clamped to 0.5% of AUM");
        assertEq(v.maxDeposit(alice), 0, "deposits paused again");
        assertEq(v.maxMint(alice), 0, "mints paused again");
        assertFalse(_aliceCanDeposit(10e6));

        // AUM recovery lifts the clamp again.
        _setAssets(NAV);
        assertEq(v.effectiveDustThreshold(), 5_000e6);
        assertGt(v.maxDeposit(alice), 0, "resumed after AUM recovery");
    }

    function test_R1_defaultThreshold_atHighAum_isStoredValue() public {
        _setAssets(NAV);
        assertEq(v.dustThreshold(), 1e6);
        assertEq(v.effectiveDustThreshold(), 1e6);
    }

    function test_R1_floor_whenAssetsTinyOrZero() public {
        _setAssets(NAV);
        _confirmThreshold(5_000e6);

        _setAssets(0);
        assertEq(v.effectiveDustThreshold(), 1e6, "zero assets -> floor");
        _setAssets(1);
        assertEq(v.effectiveDustThreshold(), 1e6, "1 wei -> floor");
        _setAssets(199_999_999); // cap = 999_999 < floor
        assertEq(v.effectiveDustThreshold(), 1e6, "sub-floor cap -> floor");
        _setAssets(200e6); // cap == 1e6
        assertEq(v.effectiveDustThreshold(), 1e6);
        _setAssets(400e6); // cap == 2e6
        assertEq(v.effectiveDustThreshold(), 2e6);
        assertEq(v.dustThreshold(), 5_000e6, "stored never mutated");
    }

    function test_R1_zeroAssets_defaultThreshold() public view {
        assertEq(v.totalAssets(), 0);
        assertEq(v.effectiveDustThreshold(), 1e6);
    }

    function test_R1_storedBelowCap_staysStored_untilCapFallsBelowIt() public {
        _setAssets(NAV);
        _confirmThreshold(2_000e6);
        assertEq(v.effectiveDustThreshold(), 2_000e6);
        _setAssets(300_000e6); // cap 1_500e6
        assertEq(v.effectiveDustThreshold(), 1_500e6);
        _setAssets(4_000_000e6); // cap 20_000e6, never above stored
        assertEq(v.effectiveDustThreshold(), 2_000e6);
    }

    function test_R1_boundary_positionEqualToEffective_doesNotPause_oneAbovePauses() public {
        _setAssets(NAV);
        _confirmThreshold(5_000e6);
        MockGoldAdapterFix m = _mock(0, false);
        vm.prank(owner);
        v.setGoldAllocationAdapter(address(m));

        _setAssets(100_000e6); // effective = 500e6
        // Keep market value at zero: only funded principal decides the dust boundary.
        _setPrincipal(address(m), 500e6);
        _setAssets(100_000e6);
        assertGt(v.maxDeposit(alice), 0, "== effective: open");
        assertGt(v.maxMint(alice), 0);
        _setPrincipal(address(m), 500e6 + 1);
        _setAssets(100_000e6);
        assertEq(v.maxDeposit(alice), 0, "> effective & insane: paused");
        assertEq(v.maxMint(alice), 0);
        m.set(500e6 + 1, true);
        assertGt(v.maxDeposit(alice), 0, "sane price never pauses");
    }

    function testFuzz_R1_effectiveFormula(uint256 a1, uint256 t, uint256 a2) public {
        a1 = bound(a1, 0, 1e15);
        a2 = bound(a2, 0, 1e15);
        t  = bound(t, 0, _cap(a1));
        _setAssets(a1);
        _confirmThreshold(t);
        _setAssets(a2);

        uint256 eff = v.effectiveDustThreshold();
        uint256 c   = _cap(a2);
        assertLe(eff, v.dustThreshold(), "never exceeds stored");
        assertLe(eff, c, "never exceeds current cap");
        assertEq(eff, t < c ? t : c, "min(stored, max(floor, 0.5% AUM))");
        assertEq(v.dustThreshold(), t, "stored unchanged by AUM moves");
    }

    // Return transfers must retire strategy cost without changing base transfer/access/pause semantics.
    function test_returnCapital_retiresPrincipalClamped_andPreservesNav() public {
        _setAssets(NAV);
        MockGoldAdapterFix m = _mock(0, true);
        _setPrincipal(address(m), 100e6);
        usdc.mint(address(m), 150e6);
        vm.prank(address(m));
        usdc.approve(address(v), 150e6);
        uint256 nav = v.totalAssets();
        vm.expectEmit(true, false, false, true, address(v));
        emit ShariahVault.PrincipalRetired(address(m), 40e6, 40e6);
        vm.prank(manager);
        v.returnCapital(address(m), 40e6);
        assertEq(v.principalOf(address(m)), 60e6);
        assertEq(v.totalDeployed(), 60e6);
        assertEq(v.totalAssets(), nav);
        _setPrincipal(address(goldAdapter), 50e6);
        vm.prank(owner);
        v.returnCapital(address(m), 100e6);
        assertEq(v.principalOf(address(m)), 0);
        // G-3 excess proceeds are profit, not retirement of another position's cost.
        assertEq(v.totalDeployed(), 50e6, "other position remains deployed");
        assertEq(v.principalOf(address(goldAdapter)), 50e6);
    }

    // A zero market value cannot bypass either slot's cost lock; write-off is owner-only and atomic.
    function test_writeOffPrincipal_zeroValue_required_andClamped() public {
        _setAssets(NAV);
        MockGoldAdapterFix m = _mock(0, false);
        vm.startPrank(owner);
        v.setGoldAllocationAdapter(address(m));
        vm.stopPrank();
        _setPrincipal(address(m), 100e6);
        assertEq(v.maxDeposit(alice), 0, "zero value does not silence material cost");
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.GoldAdapterHasExposure.selector, address(m), uint256(100e6)));
        v.setGoldAllocationAdapter(address(0));
        m.set(1, false);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.GoldAdapterHasExposure.selector, address(m), uint256(1)));
        v.writeOffAdapterPrincipal(address(m));
        vm.stopPrank();
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, manager));
        v.writeOffAdapterPrincipal(address(m));
        m.set(0, false);
        // Simulate historical aggregate desync: full adapter cost retires while aggregate subtraction clamps.
        _setAggregateDeployed(50e6);
        vm.expectEmit(true, false, false, true, address(v));
        emit ShariahVault.PrincipalRetired(address(m), 100e6, 0);
        vm.prank(owner);
        v.writeOffAdapterPrincipal(address(m));
        assertEq(v.principalOf(address(m)), 0);
        assertEq(v.totalDeployed(), 0);
        vm.prank(owner);
        v.setGoldAllocationAdapter(address(0));
        assertGt(v.maxDeposit(alice), 0);
    }

    // ───────────────────────── R-3 ─────────────────────────

    function test_R3_spread_exposure_blocksReplaceClearAndSame() public {
        _openGold(4_000e6);
        uint256 val = goldAdapter.currentValue();
        assertGt(val, 0);
        MockGoldAdapterFix other = _mock(0, true);
        bytes memory err = abi.encodeWithSelector(
            ShariahVault.GoldAdapterHasExposure.selector, address(goldAdapter), val
        );
        vm.startPrank(owner);
        vm.expectRevert(err);
        v.setGoldSpreadAdapter(address(other));
        vm.expectRevert(err);
        v.setGoldSpreadAdapter(address(0));
        vm.expectRevert(err);
        v.setGoldSpreadAdapter(address(goldAdapter));
        vm.stopPrank();
        assertEq(v.goldSpreadAdapter(), address(goldAdapter), "pointer unchanged");
    }

    function test_R3_spread_zeroValue_allowsReplaceClearSame_andFromZero() public {
        assertEq(goldAdapter.currentValue(), 0);
        MockGoldAdapterFix other = _mock(0, true);

        vm.startPrank(owner);
        v.setGoldSpreadAdapter(address(goldAdapter)); // same address, zero value
        vm.expectEmit(true, false, false, false, address(v));
        emit ShariahVault.GoldSpreadAdapterUpdated(address(other));
        v.setGoldSpreadAdapter(address(other)); // replace
        assertEq(v.goldSpreadAdapter(), address(other));
        v.setGoldSpreadAdapter(address(0)); // clear
        assertEq(v.goldSpreadAdapter(), address(0));
        v.setGoldSpreadAdapter(address(goldAdapter)); // from zero
        vm.stopPrank();
        assertEq(v.goldSpreadAdapter(), address(goldAdapter));
    }

    function test_R3_spread_replacementWithExposure_isLockedToo_thenUnlocksAtZero() public {
        MockGoldAdapterFix m = _mock(5, true);
        vm.startPrank(owner);
        v.setGoldSpreadAdapter(address(m));
        bytes memory err = abi.encodeWithSelector(ShariahVault.GoldAdapterHasExposure.selector, address(m), uint256(5));
        vm.expectRevert(err);
        v.setGoldSpreadAdapter(address(0));
        vm.expectRevert(err);
        v.setGoldSpreadAdapter(address(m));
        m.set(0, true);
        v.setGoldSpreadAdapter(address(0));
        vm.stopPrank();
        assertEq(v.goldSpreadAdapter(), address(0));
    }

    function test_R3_allocation_fromZero_allowed_andEmits() public {
        assertEq(v.goldAllocationAdapter(), address(0));
        MockGoldAdapterFix m = _mock(123e6, true); // value irrelevant while tracked is zero
        vm.expectEmit(true, false, false, false, address(v));
        emit ShariahVault.GoldAllocationAdapterUpdated(address(m));
        vm.prank(owner);
        v.setGoldAllocationAdapter(address(m));
        assertEq(v.goldAllocationAdapter(), address(m));
    }

    function test_R3_allocation_exposure_blocksReplaceClearAndSame() public {
        MockGoldAdapterFix m = _mock(1, true);
        MockGoldAdapterFix other = _mock(0, true);
        vm.startPrank(owner);
        v.setGoldAllocationAdapter(address(m));
        bytes memory err = abi.encodeWithSelector(ShariahVault.GoldAdapterHasExposure.selector, address(m), uint256(1));
        vm.expectRevert(err);
        v.setGoldAllocationAdapter(address(other));
        vm.expectRevert(err);
        v.setGoldAllocationAdapter(address(0));
        vm.expectRevert(err);
        v.setGoldAllocationAdapter(address(m));
        vm.stopPrank();
        assertEq(v.goldAllocationAdapter(), address(m), "pointer unchanged");
    }

    function test_R3_allocation_zeroValue_allowsReplaceClearSame() public {
        MockGoldAdapterFix m = _mock(0, true);
        MockGoldAdapterFix other = _mock(0, true);
        vm.startPrank(owner);
        v.setGoldAllocationAdapter(address(m));
        v.setGoldAllocationAdapter(address(m));
        v.setGoldAllocationAdapter(address(other));
        assertEq(v.goldAllocationAdapter(), address(other));
        v.setGoldAllocationAdapter(address(0));
        vm.stopPrank();
        assertEq(v.goldAllocationAdapter(), address(0));
    }

    function test_R3_exposureOnOneSlot_doesNotLockTheOther() public {
        _openGold(4_000e6); // spread has exposure
        MockGoldAdapterFix m = _mock(0, true);
        vm.startPrank(owner);
        v.setGoldAllocationAdapter(address(m));
        v.setGoldAllocationAdapter(address(0));
        vm.stopPrank();
        m.set(9, true);
        vm.startPrank(owner);
        v.setGoldAllocationAdapter(address(0)); // already zero -> allowed
        v.setGoldAllocationAdapter(address(m));
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.GoldAdapterHasExposure.selector, address(m), uint256(9)));
        v.setGoldAllocationAdapter(address(0));
        vm.stopPrank();
    }

    function test_R3_nonOwner_cannotSetAdapters() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        v.setGoldSpreadAdapter(address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        v.setGoldAllocationAdapter(address(0));
        vm.stopPrank();
    }

    function test_R3_attack_unlinkToSilenceDepositPause_isBlockedWhileStalePositionExists() public {
        _setAssets(NAV);
        _openGold(4_000e6);
        vm.warp(block.timestamp + 2 days);
        assertFalse(goldAdapter.isPriceSane(), "oracle stale");
        uint256 X = goldAdapter.currentValue();
        assertGt(X, v.effectiveDustThreshold());
        assertEq(v.maxDeposit(alice), 0, "paused by stale position");

        MockGoldAdapterFix clean = _mock(0, true);
        bytes memory err = abi.encodeWithSelector(ShariahVault.GoldAdapterHasExposure.selector, address(goldAdapter), X);
        vm.startPrank(owner);
        vm.expectRevert(err);
        v.setGoldSpreadAdapter(address(0));
        vm.expectRevert(err);
        v.setGoldSpreadAdapter(address(clean));
        vm.stopPrank();
        assertEq(v.maxDeposit(alice), 0, "still paused");
        assertEq(v.maxMint(alice), 0);
        assertFalse(_aliceCanDeposit(10e6));

        // Zero value alone cannot unlink unretired cost; explicitly recognize the loss first.
        vm.mockCall(address(goldAdapter), abi.encodeWithSignature("currentValue()"), abi.encode(uint256(0)));
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.GoldAdapterHasExposure.selector,
            address(goldAdapter), v.principalOf(address(goldAdapter))));
        v.setGoldSpreadAdapter(address(0));
        v.writeOffAdapterPrincipal(address(goldAdapter));
        v.setGoldSpreadAdapter(address(0));
        vm.stopPrank();
        assertGt(v.maxDeposit(alice), 0);
    }
}

contract TaskNFixesV1Test is TaskNFixesCommon {
    function _deployVault() internal override {
        v = new ShariahVault(IERC20(address(usdc)), owner, SOURCE_DOMAIN, address(treasury), address(0));
    }
    function _board() internal view override returns (address) { return owner; }
    function _denied() internal view override returns (address[] memory d) { d = new address[](0); }
}

/// @dev V2 flavour + R-2 registry replacement (propose / confirm / cancel with 30-day timelock).
contract TaskNFixesV2Test is TaskNFixesCommon {
    ShariahAdapterRegistry internal registry; // board = boardMember, registry owner = owner (NOT board)
    ShariahAdapterRegistry internal r2;       // honest replacement, board = newBoard
    ShariahVaultV2         internal v2;
    address internal newBoard = makeAddr("newBoard");
    address internal strat    = makeAddr("strat");

    function _deployVault() internal override {
        registry = new ShariahAdapterRegistry(owner, boardMember);
        v = new ShariahVaultV2(
            IERC20(address(usdc)), owner, SOURCE_DOMAIN, address(treasury), address(0), address(registry)
        );
        v2 = ShariahVaultV2(address(v));
        r2 = new ShariahAdapterRegistry(owner, newBoard);
    }
    function _board() internal view override returns (address) { return boardMember; }
    function _denied() internal view override returns (address[] memory d) { d = new address[](0); }

    function _nbe(address who) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ShariahVault.NotBoardRole.selector, who);
    }
    function _proposeReg(address r) internal {
        vm.prank(boardMember);
        v2.proposeRegistry(r);
    }
    function _pendingReg() internal view returns (address nr, uint256 ea, bool ex) {
        return v2.pendingRegistry();
    }

    // ── surface ──

    function test_R2_timelockConstant_andNoSetRegistry() public {
        assertEq(v2.REGISTRY_TIMELOCK(), 30 days);
        (bool okOwner,) = address(v2).call(abi.encodeWithSignature("setRegistry(address)", address(r2)));
        assertFalse(okOwner, "setRegistry removed");
        vm.prank(owner);
        (bool ok,) = address(v2).call(abi.encodeWithSignature("setRegistry(address)", address(r2)));
        assertFalse(ok, "setRegistry removed (owner)");
        assertEq(address(v2.registry()), address(registry));
        (, , bool ex) = _pendingReg();
        assertFalse(ex);
    }

    // ── authorization against a live registry ──

    function test_R2_ownerWithoutBoardRole_cannotProposeConfirmOrCancel() public {
        assertFalse(registry.isBoard(owner));
        vm.prank(owner);
        vm.expectRevert(_nbe(owner));
        v2.proposeRegistry(address(r2));

        _proposeReg(address(r2));
        vm.warp(block.timestamp + 30 days);
        vm.startPrank(owner);
        vm.expectRevert(_nbe(owner));
        v2.confirmRegistry();
        vm.expectRevert(_nbe(owner));
        v2.cancelRegistry();
        vm.stopPrank();

        address[3] memory others = [stranger, manager, alice];
        for (uint256 i = 0; i < others.length; i++) {
            vm.startPrank(others[i]);
            vm.expectRevert(_nbe(others[i]));
            v2.proposeRegistry(address(r2));
            vm.expectRevert(_nbe(others[i]));
            v2.confirmRegistry();
            vm.expectRevert(_nbe(others[i]));
            v2.cancelRegistry();
            vm.stopPrank();
        }
        (address nr, , bool ex) = _pendingReg();
        assertTrue(ex);
        assertEq(nr, address(r2));
        assertEq(address(v2.registry()), address(registry));
    }

    function test_R2_boardMember_proposeAndConfirm_afterTimelock() public {
        uint256 t0 = block.timestamp;
        vm.expectEmit(false, false, false, true, address(v));
        emit ShariahVaultV2.RegistryProposed(address(r2), t0 + 30 days);
        _proposeReg(address(r2));
        (address nr, uint256 ea, bool ex) = _pendingReg();
        assertEq(nr, address(r2));
        assertEq(ea, t0 + 30 days);
        assertTrue(ex);
        assertEq(address(v2.registry()), address(registry), "not applied on propose");

        vm.warp(t0 + 30 days);
        vm.expectEmit(true, false, false, false, address(v));
        emit ShariahVaultV2.RegistryUpdated(address(r2));
        vm.prank(boardMember);
        v2.confirmRegistry();
        assertEq(address(v2.registry()), address(r2));
        (address nr2, uint256 ea2, bool ex2) = _pendingReg();
        assertEq(nr2, address(0));
        assertEq(ea2, 0);
        assertFalse(ex2, "pending cleared");

        // Governance now follows the new registry.
        vm.prank(boardMember);
        vm.expectRevert(_nbe(boardMember));
        v.proposeDustThreshold(1e6);
        vm.prank(newBoard);
        v.proposeDustThreshold(1e6);
    }

    function test_R2_confirm_oneSecondEarly_reverts_exactTimelock_succeeds() public {
        uint256 t0 = block.timestamp;
        _proposeReg(address(r2));
        vm.warp(t0 + 30 days - 1);
        vm.prank(boardMember);
        vm.expectRevert(abi.encodeWithSelector(
            ShariahVaultV2.RegistryTimelockNotElapsed.selector, t0 + 30 days, t0 + 30 days - 1
        ));
        v2.confirmRegistry();
        assertEq(address(v2.registry()), address(registry));

        vm.warp(t0 + 30 days);
        vm.prank(boardMember);
        v2.confirmRegistry();
        assertEq(address(v2.registry()), address(r2));
    }

    function test_R2_confirmAndCancel_withoutProposal_revert() public {
        vm.startPrank(boardMember);
        vm.expectRevert(ShariahVaultV2.NoPendingRegistryProposal.selector);
        v2.confirmRegistry();
        vm.expectRevert(ShariahVaultV2.NoPendingRegistryProposal.selector);
        v2.cancelRegistry();
        vm.stopPrank();
    }

    function test_R2_cancel_clearsPending_blocksConfirm_andAllowsRepropose() public {
        _proposeReg(address(r2));
        vm.expectEmit(false, false, false, false, address(v));
        emit ShariahVaultV2.RegistryProposalCancelled();
        vm.prank(boardMember);
        v2.cancelRegistry(); // no waiting needed
        (, , bool ex) = _pendingReg();
        assertFalse(ex);

        vm.warp(block.timestamp + 30 days);
        vm.prank(boardMember);
        vm.expectRevert(ShariahVaultV2.NoPendingRegistryProposal.selector);
        v2.confirmRegistry();

        ShariahAdapterRegistry r3 = new ShariahAdapterRegistry(owner, newBoard);
        uint256 t1 = block.timestamp;
        vm.prank(boardMember);
        v2.proposeRegistry(address(r3));
        (address nr, uint256 ea, bool ex2) = _pendingReg();
        assertEq(nr, address(r3));
        assertEq(ea, t1 + 30 days, "fresh timelock after re-propose");
        assertTrue(ex2);
        assertEq(address(v2.registry()), address(registry));
    }

    function test_R2_duplicatePropose_reverts() public {
        _proposeReg(address(r2));
        ShariahAdapterRegistry r3 = new ShariahAdapterRegistry(owner, newBoard);
        vm.startPrank(boardMember);
        vm.expectRevert(ShariahVaultV2.RegistryProposalAlreadyExists.selector);
        v2.proposeRegistry(address(r2));
        vm.expectRevert(ShariahVaultV2.RegistryProposalAlreadyExists.selector);
        v2.proposeRegistry(address(r3));
        vm.stopPrank();
        (address nr, , ) = _pendingReg();
        assertEq(nr, address(r2), "original proposal retained");
    }

    function test_R2_proposeZeroRegistry_reverts() public {
        vm.prank(boardMember);
        vm.expectRevert(ShariahVaultV2.ZeroRegistry.selector);
        v2.proposeRegistry(address(0));
        (, , bool ex) = _pendingReg();
        assertFalse(ex);
    }

    // ── interaction with dust governance ──

    function test_R2_confirm_clearsPendingDustProposal_andEmits() public {
        _setAssets(NAV);
        _propose(2_000e6);
        _proposeReg(address(r2));
        vm.warp(block.timestamp + 30 days);
        vm.expectEmit(false, false, false, false, address(v));
        emit ShariahVault.DustThresholdProposalCancelled();
        vm.prank(boardMember);
        v2.confirmRegistry();
        (, , bool exists) = _pending();
        assertFalse(exists, "dust proposal cleared");
        assertEq(v.dustThreshold(), 1e6, "stored threshold untouched");
    }

    function test_R2_confirm_withoutDustProposal_emitsNoDustCancelled() public {
        _proposeReg(address(r2));
        vm.warp(block.timestamp + 30 days);
        vm.recordLogs();
        vm.prank(boardMember);
        v2.confirmRegistry();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 dustSig = keccak256("DustThresholdProposalCancelled()");
        bytes32 updSig  = keccak256("RegistryUpdated(address)");
        bool sawUpdated;
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != dustSig, "no dust cancel event");
            if (logs[i].topics[0] == updSig) sawUpdated = true;
        }
        assertTrue(sawUpdated);
    }

    // ── the review attack ──

    function test_R2_attack_ownerSwapsInOwnedRegistryToSelfAppointBoard_isImpossible() public {
        _setAssets(NAV);
        _propose(2_000e6);                         // honest board proposal ...
        vm.warp(block.timestamp + DUST_TIMELOCK);  // ... matured

        // Owner builds a registry where owner is board.
        ShariahAdapterRegistry evil = new ShariahAdapterRegistry(owner, owner);
        assertTrue(evil.isBoard(owner));

        vm.startPrank(owner);
        vm.expectRevert(_nbe(owner));
        v2.proposeRegistry(address(evil));
        vm.expectRevert(_nbe(owner));
        v2.confirmRegistry();
        vm.expectRevert(_nbe(owner));
        v2.cancelRegistry();
        vm.expectRevert(_nbe(owner));
        v.confirmDustThreshold(); // cannot confirm the matured proposal either
        (bool ok,) = address(v2).call(abi.encodeWithSignature("setRegistry(address)", address(evil)));
        assertFalse(ok);
        vm.stopPrank();

        assertEq(address(v2.registry()), address(registry), "registry unchanged");
        (, , bool pendingReg) = _pendingReg();
        assertFalse(pendingReg);
        (, , bool dustPending) = _pending();
        assertTrue(dustPending, "dust proposal untouched");
        assertEq(v.dustThreshold(), 1e6);

        // The honest board can still finish its own proposal.
        _confirm();
        assertEq(v.dustThreshold(), 2_000e6);
    }

    // ── deployCapital screening follows the OLD registry until confirm ──

    function test_R2_deployCapital_oldRegistryScreening_appliesUntilConfirm() public {
        _setAssets(NAV);
        uint256 t0 = block.timestamp;
        vm.startPrank(boardMember);
        registry.proposeScreening(strat, keccak256("old"), t0 + 300 days);
        v2.proposeRegistry(address(r2));
        vm.stopPrank();
        vm.warp(t0 + 30 days);
        vm.prank(boardMember);
        registry.executeScreening(strat);

        vm.prank(manager);
        v.deployCapital(strat, 1_000e6, ""); // proposal pending, old registry still decides
        assertEq(usdc.balanceOf(strat), 1_000e6);

        vm.prank(boardMember);
        v2.confirmRegistry();
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ShariahVaultV2.NotScreened.selector, strat));
        v.deployCapital(strat, 1_000e6, "");
    }

    function test_R2_deployCapital_newRegistryScreening_ignoredUntilConfirm() public {
        _setAssets(NAV);
        uint256 t0 = block.timestamp;
        vm.prank(newBoard);
        r2.proposeScreening(strat, keccak256("new"), t0 + 300 days);
        _proposeReg(address(r2));
        vm.warp(t0 + 30 days);
        vm.prank(newBoard);
        r2.executeScreening(strat);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ShariahVaultV2.NotScreened.selector, strat));
        v.deployCapital(strat, 1_000e6, "");

        vm.prank(boardMember);
        v2.confirmRegistry();
        vm.prank(manager);
        v.deployCapital(strat, 1_000e6, "");
        assertEq(usdc.balanceOf(strat), 1_000e6);
    }

    // ── bootstrap (current registry == address(0)) ──

    function _zeroRegVault() internal returns (ShariahVaultV2 z) {
        z = new ShariahVaultV2(
            IERC20(address(usdc)), owner, SOURCE_DOMAIN, address(treasury), address(0), address(0)
        );
    }

    function test_R2_bootstrap_nonOwner_cannotPropose_confirm_orCancel() public {
        ShariahVaultV2 z = _zeroRegVault();
        address[3] memory who = [boardMember, alice, stranger];
        for (uint256 i = 0; i < who.length; i++) {
            bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who[i]);
            vm.startPrank(who[i]);
            vm.expectRevert(err);
            z.proposeRegistry(address(registry));
            vm.expectRevert(err);
            z.confirmRegistry();
            vm.expectRevert(err);
            z.cancelRegistry();
            vm.stopPrank();
        }
    }

    function test_R2_bootstrap_ownerProposesAndConfirmsImmediately_noBoardCheck() public {
        ShariahVaultV2 z = _zeroRegVault();
        assertFalse(registry.isBoard(owner), "owner is not board anywhere");

        vm.expectEmit(false, false, false, true, address(z));
        emit ShariahVaultV2.RegistryProposed(address(registry), block.timestamp);
        vm.startPrank(owner);
        z.proposeRegistry(address(registry));
        vm.expectEmit(true, false, false, false, address(z));
        emit ShariahVaultV2.RegistryUpdated(address(registry));
        z.confirmRegistry(); // same block, no delay
        vm.stopPrank();

        assertEq(address(z.registry()), address(registry));
        (, , bool ex) = z.pendingRegistry();
        assertFalse(ex);
    }

    function test_R2_bootstrap_zeroDuplicateMissingAndCancel() public {
        ShariahVaultV2 z = _zeroRegVault();
        vm.startPrank(owner);
        vm.expectRevert(ShariahVaultV2.ZeroRegistry.selector);
        z.proposeRegistry(address(0));
        vm.expectRevert(ShariahVaultV2.NoPendingRegistryProposal.selector);
        z.confirmRegistry();
        vm.expectRevert(ShariahVaultV2.NoPendingRegistryProposal.selector);
        z.cancelRegistry();

        z.proposeRegistry(address(registry));
        vm.expectRevert(ShariahVaultV2.RegistryProposalAlreadyExists.selector);
        z.proposeRegistry(address(r2));
        z.cancelRegistry();
        (, , bool ex) = z.pendingRegistry();
        assertFalse(ex);
        z.proposeRegistry(address(r2));
        z.confirmRegistry();
        vm.stopPrank();
        assertEq(address(z.registry()), address(r2));
    }

    function test_R2_bootstrap_stopsBeingImmediate_afterRegistrySet() public {
        ShariahVaultV2 z = _zeroRegVault();
        vm.startPrank(owner);
        z.proposeRegistry(address(registry));
        z.confirmRegistry();
        // Owner (not board of `registry`) has lost the bootstrap powers.
        vm.expectRevert(_nbe(owner));
        z.proposeRegistry(address(r2));
        vm.expectRevert(_nbe(owner));
        z.cancelRegistry();
        vm.stopPrank();

        uint256 t0 = block.timestamp;
        vm.prank(boardMember);
        z.proposeRegistry(address(r2));
        (, uint256 ea, ) = z.pendingRegistry();
        assertEq(ea, t0 + 30 days, "delay applies after bootstrap");
        vm.prank(boardMember);
        vm.expectRevert(abi.encodeWithSelector(
            ShariahVaultV2.RegistryTimelockNotElapsed.selector, t0 + 30 days, t0
        ));
        z.confirmRegistry();
        vm.prank(owner);
        vm.expectRevert(_nbe(owner));
        z.confirmRegistry();
    }
}
