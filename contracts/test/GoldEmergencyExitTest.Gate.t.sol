// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GoldExitBase, GoldExitExchangeFixture, GoldExitAllocFixture, IGoldX} from "./GoldEmergencyExitTest.Base.t.sol";

/// @dev Authorization, default-disabled gate, 30-day timelocked toggle, propose-time validation and floor.
abstract contract GoldExitGateSuite is GoldExitBase {
    using stdStorage for StdStorage;
    StdStorage internal ss;

    function _expectUnauthorized(address who) internal {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who));
    }

    function test_paramIdAndDelayConstants() public view {
        assertEq(adapter.PARAM_EMERGENCY_EXIT_ENABLED(), keccak256("emergencyExitEnabled"));
        assertEq(adapter.TIMELOCK_DELAY(), 30 days);
        assertEq(adapter.EMERGENCY_EXIT_DELAY(), 1 hours);
        assertEq(adapter.EMERGENCY_EXIT_WINDOW(), 24 hours);
        assertEq(adapter.EMERGENCY_FLOOR_BPS(), 2000);
        assertFalse(adapter.emergencyExitEnabled(), "default disabled");
    }

    // ── authorization: owner only, all three functions + legacy ─────────
    function test_strangerVaultManager_cannotUseAnyExitFunction_whenDisabled() public {
        address[3] memory who = [stranger, vault, manager];
        for (uint256 i; i < 3; ++i) {
            _expectUnauthorized(who[i]);
            vm.prank(who[i]);
            adapter.proposeEmergencyExit(1, 1);
            _expectUnauthorized(who[i]);
            vm.prank(who[i]);
            adapter.executeEmergencyExit();
            _expectUnauthorized(who[i]);
            vm.prank(who[i]);
            adapter.cancelEmergencyExit();
            _expectUnauthorized(who[i]);
            vm.prank(who[i]);
            adapter.emergencyExit(1, 1);
        }
    }

    function test_strangerVaultManager_cannotUseAnyExitFunction_whenEnabledWithPending() public {
        _open(DEPLOY);
        _enable();
        uint256 amt = _held() / 2;
        _propose(amt, _floor(amt));
        _wait();
        address[3] memory who = [stranger, vault, manager];
        for (uint256 i; i < 3; ++i) {
            _expectUnauthorized(who[i]);
            vm.prank(who[i]);
            adapter.proposeEmergencyExit(1, 1);
            _expectUnauthorized(who[i]);
            vm.prank(who[i]);
            adapter.executeEmergencyExit();
            _expectUnauthorized(who[i]);
            vm.prank(who[i]);
            adapter.cancelEmergencyExit();
        }
        (uint256 t,,,) = adapter.pendingEmergencyExit();
        assertEq(t, amt, "pending proposal untouched");
        assertEq(router.calls(), 1, "only the original deploy swap happened");
    }

    function test_strangerVaultManager_cannotChangeToggle() public {
        address[3] memory who = [stranger, vault, manager];
        for (uint256 i; i < 3; ++i) {
            _expectUnauthorized(who[i]);
            vm.prank(who[i]);
            adapter.proposeParamChange(PARAM, 1);
        }
        vm.prank(owner);
        adapter.proposeParamChange(PARAM, 1);
        vm.warp(block.timestamp + 30 days);
        for (uint256 i; i < 3; ++i) {
            _expectUnauthorized(who[i]);
            vm.prank(who[i]);
            adapter.executeParamChange(PARAM);
            _expectUnauthorized(who[i]);
            vm.prank(who[i]);
            adapter.cancelParamChange(PARAM);
        }
    }

    function test_owner_canProposeExecuteCancel_whenEnabled() public {
        _open(DEPLOY);
        _enable();
        uint256 held = _held();
        uint256 out = _exit(held / 2);
        assertGt(out, 0);
        assertEq(_held(), held - held / 2);
        uint256 amt = _held() / 2;
        _propose(amt, _floor(amt));
        vm.prank(owner);
        adapter.cancelEmergencyExit();
        (uint256 t,,,) = adapter.pendingEmergencyExit();
        assertEq(t, 0);
    }

    // ── default disabled ────────────────────────────────────────────────
    function test_defaultDisabled_ownerProposeReverts_noStateChange() public {
        _open(DEPLOY);
        uint256 held = _held();
        uint256 deployed = adapter.totalDeployed();
        uint256 calls = router.calls();
        uint256 minOut = _floor(held);
        vm.prank(owner);
        vm.expectRevert(EmergencyExitDisabled.selector);
        adapter.proposeEmergencyExit(held, minOut);
        (uint256 t,,,) = adapter.pendingEmergencyExit();
        assertEq(t, 0);
        assertEq(_held(), held);
        assertEq(adapter.totalDeployed(), deployed);
        assertEq(router.calls(), calls);
    }

    function test_defaultDisabled_ownerExecuteReverts() public {
        _open(DEPLOY);
        vm.prank(owner);
        vm.expectRevert(EmergencyExitDisabled.selector);
        adapter.executeEmergencyExit();
    }

    function test_disabledCheckPrecedesZeroAndHeldChecks() public {
        vm.startPrank(owner);
        vm.expectRevert(EmergencyExitDisabled.selector);
        adapter.proposeEmergencyExit(0, 0);
        vm.expectRevert(EmergencyExitDisabled.selector);
        adapter.proposeEmergencyExit(5, 5);
        vm.stopPrank();
    }

    // ── enable via timelock ─────────────────────────────────────────────
    function test_enable_proposeEmitsAndStoresPending() public {
        uint256 executeAfter = block.timestamp + 30 days;
        vm.expectEmit(true, false, false, true, address(adapter));
        emit ParamChangeProposed(PARAM, 1, executeAfter);
        vm.prank(owner);
        adapter.proposeParamChange(PARAM, 1);
        (uint256 v, uint256 ea, bool pending) = adapter.pendingChanges(PARAM);
        assertEq(v, 1);
        assertEq(ea, executeAfter);
        assertTrue(pending);
        assertFalse(adapter.emergencyExitEnabled(), "proposal alone does not enable");
    }

    function test_enable_timelockBoundary() public {
        vm.prank(owner);
        adapter.proposeParamChange(PARAM, 1);
        uint256 executeAfter = block.timestamp + 30 days;

        vm.warp(executeAfter - 1);
        vm.prank(owner);
        _expectTimelock(executeAfter);
        adapter.executeParamChange(PARAM);
        assertFalse(adapter.emergencyExitEnabled());
        vm.prank(owner);
        vm.expectRevert(EmergencyExitDisabled.selector);
        adapter.proposeEmergencyExit(1, 1);

        vm.warp(executeAfter);
        vm.expectEmit(true, false, false, true, address(adapter));
        emit ParamChangeExecuted(PARAM, 1);
        vm.prank(owner);
        adapter.executeParamChange(PARAM);
        assertTrue(adapter.emergencyExitEnabled());
        (,, bool pending) = adapter.pendingChanges(PARAM);
        assertFalse(pending, "proposal consumed");
    }

    function test_execute_withoutProposal_reverts() public {
        vm.prank(owner);
        _expectNoProposal();
        adapter.executeParamChange(PARAM);
    }

    function test_enable_doesNotTouchOtherParams() public {
        vm.startPrank(owner);
        adapter.proposeParamChange(PARAM, 1);
        (,, bool otherPending) = adapter.pendingChanges(keccak256("emergencySlippageBps"));
        assertFalse(otherPending);
        vm.stopPrank();
    }

    // ── cancel of the toggle ────────────────────────────────────────────
    function test_cancel_clearsProposal_andStaysDisabled() public {
        vm.prank(owner);
        adapter.proposeParamChange(PARAM, 1);
        vm.expectEmit(true, false, false, false, address(adapter));
        emit ParamChangeCancelled(PARAM);
        vm.prank(owner);
        adapter.cancelParamChange(PARAM);
        (,, bool pending) = adapter.pendingChanges(PARAM);
        assertFalse(pending);

        vm.warp(block.timestamp + 31 days);
        vm.prank(owner);
        _expectNoProposal();
        adapter.executeParamChange(PARAM);
        assertFalse(adapter.emergencyExitEnabled());
    }

    function test_cancel_withoutProposal_reverts() public {
        vm.prank(owner);
        _expectNoProposal();
        adapter.cancelParamChange(PARAM);
    }

    // ── disable again ───────────────────────────────────────────────────
    function test_disableAgain_requiresTimelock_thenProposeAndExecuteRevert() public {
        _open(DEPLOY);
        _enable();
        uint256 amt = _held() / 4;
        _propose(amt, _floor(amt));
        vm.prank(owner);
        adapter.proposeParamChange(PARAM, 0);
        uint256 executeAfter = block.timestamp + 30 days;

        assertTrue(adapter.emergencyExitEnabled());
        _wait();
        _execute(); // still enabled while the disable proposal ripens

        vm.warp(executeAfter - 1);
        vm.prank(owner);
        _expectTimelock(executeAfter);
        adapter.executeParamChange(PARAM);
        assertTrue(adapter.emergencyExitEnabled());

        vm.warp(executeAfter);
        vm.prank(owner);
        adapter.executeParamChange(PARAM);
        assertFalse(adapter.emergencyExitEnabled());

        vm.prank(owner);
        vm.expectRevert(EmergencyExitDisabled.selector);
        adapter.proposeEmergencyExit(1, 1);
    }

    function test_disabledAfterProposal_executeReverts() public {
        _open(DEPLOY);
        _enable();
        uint256 amt = _held() / 4;
        _propose(amt, _floor(amt));
        vm.prank(owner);
        adapter.proposeParamChange(PARAM, 0);
        vm.warp(block.timestamp + 30 days);
        vm.prank(owner);
        adapter.executeParamChange(PARAM);
        assertFalse(adapter.emergencyExitEnabled());
        vm.prank(owner);
        vm.expectRevert(EmergencyExitDisabled.selector);
        adapter.executeEmergencyExit();
    }

    // ── invalid toggle value ────────────────────────────────────────────
    function test_invalidToggleValue_rejected_noPending() public {
        vm.prank(owner);
        _expectInvalidBool(2);
        adapter.proposeParamChange(PARAM, 2);
        (,, bool pending) = adapter.pendingChanges(PARAM);
        assertFalse(pending);

        vm.prank(owner);
        _expectInvalidBool(type(uint256).max);
        adapter.proposeParamChange(PARAM, type(uint256).max);
    }

    // ── propose-time amount validation ──────────────────────────────────
    function test_zeroAmount_orZeroMinOut_revert() public {
        _open(DEPLOY);
        _enable();
        uint256 held = _held();
        vm.startPrank(owner);
        vm.expectRevert(ZeroAmount.selector);
        adapter.proposeEmergencyExit(0, 1);
        vm.expectRevert(ZeroAmount.selector);
        adapter.proposeEmergencyExit(1, 0);
        vm.expectRevert(ZeroAmount.selector);
        adapter.proposeEmergencyExit(0, 0);
        vm.expectRevert(ZeroAmount.selector);
        adapter.proposeEmergencyExit(held, 0);
        vm.stopPrank();
        (uint256 t,,,) = adapter.pendingEmergencyExit();
        assertEq(t, 0, "nothing stored");
    }

    function test_amountAboveHeld_reverts() public {
        _open(DEPLOY);
        _enable();
        uint256 held = _held();
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(AmountExceedsHeld.selector, held + 1, held));
        adapter.proposeEmergencyExit(held + 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(AmountExceedsHeld.selector, type(uint256).max, held));
        adapter.proposeEmergencyExit(type(uint256).max, 1);
        vm.stopPrank();
    }

    function test_noPosition_anyAmountExceedsHeld() public {
        _enable();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AmountExceedsHeld.selector, 1, 0));
        adapter.proposeEmergencyExit(1, 1);
    }

    function test_zeroAmountPrecedesHeldCheck() public {
        _enable();
        vm.prank(owner);
        vm.expectRevert(ZeroAmount.selector);
        adapter.proposeEmergencyExit(0, 1);
    }

    function test_noCachedPrice_staleGoldPrice() public {
        _open(DEPLOY);
        _enable();
        uint256 held = _held();
        ss.target(address(adapter)).sig("lastGoodPrice()").checked_write(uint256(0));
        assertEq(adapter.lastGoodPrice(), 0);
        vm.prank(owner);
        vm.expectRevert(StaleGoldPrice.selector);
        adapter.proposeEmergencyExit(held, 1);
    }

    // ── hard floor: 20% of cached value ─────────────────────────────────
    function test_floor_exactlyAtFloorPasses_oneBelowReverts() public {
        _open(DEPLOY);
        _enable();
        uint256 amt = _held() / 3;
        uint256 floor = _floor(amt);
        assertEq(floor, (amt * adapter.lastGoodPrice() / 10 ** goldDec) / 5 + ((amt * adapter.lastGoodPrice() / 10 ** goldDec) % 5 == 0 ? 0 : 1));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, floor - 1, floor));
        adapter.proposeEmergencyExit(amt, floor - 1);
        (uint256 t0,,,) = adapter.pendingEmergencyExit();
        assertEq(t0, 0, "rejected proposal stores nothing");

        _propose(amt, floor);
        (uint256 t, uint256 m,,) = adapter.pendingEmergencyExit();
        assertEq(t, amt);
        assertEq(m, floor);
    }

    function test_floor_isTwentyPercentOfCachedValue_notHaircutted() public {
        _open(DEPLOY);
        _enable();
        uint256 amt = _held();
        uint256 value = amt * adapter.lastGoodPrice() / 10 ** goldDec;
        // Far from the stale-haircut path: floor is exactly 20% of un-haircutted cached value (± 1 rounding).
        assertApproxEqAbs(_floor(amt), value / 5, 1);
        assertApproxEqAbs(_floor(amt), DEPLOY / 5, 20e6, "~20% of the 100k cost");
    }

    function test_floor_usesCachedPrice_notOracle() public {
        _open(DEPLOY);
        _enable();
        uint256 amt = _held() / 2;
        uint256 floorBefore = _floor(amt);
        _setOracle(ORACLE_PRICE * 2); // oracle doubles; cached price does not move until a swap
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, floorBefore - 1, floorBefore));
        adapter.proposeEmergencyExit(amt, floorBefore - 1);
        _propose(amt, floorBefore);
    }

    function test_floor_belowTwentyPercent_crashLevelMinOutRejected() public {
        _open(DEPLOY);
        _enable();
        uint256 amt = _held() / 2;
        uint256 crashMin = _out(amt, 500e6); // ~15% of cached price: used to be acceptable
        uint256 floor = _floor(amt);
        assertLt(crashMin, floor);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, crashMin, floor));
        adapter.proposeEmergencyExit(amt, crashMin);
    }

    function testFuzz_floor_boundary(uint256 f) public {
        _open(DEPLOY);
        _enable();
        uint256 minSell = goldDec == 18 ? 1e12 : 1;
        uint256 amt = bound(f, minSell, _held());
        uint256 floor = _floor(amt);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, floor - 1, floor));
        adapter.proposeEmergencyExit(amt, floor - 1);
        _propose(amt, floor);
        (uint256 t, uint256 m,,) = adapter.pendingEmergencyExit();
        assertEq(t, amt);
        assertEq(m, floor);
        // floor is the least integer >= 20% of value
        uint256 value = amt * adapter.lastGoodPrice() / 10 ** goldDec;
        assertGe(floor * 10_000, value * 2000);
        assertLt((floor - 1) * 10_000, value * 2000);
    }
}

contract GoldExchangeEmergencyExitGateTest is GoldExitGateSuite, GoldExitExchangeFixture {}
contract GoldAllocationEmergencyExitGateTest is GoldExitGateSuite, GoldExitAllocFixture {}

/// @dev 18-decimals token with an amount whose 20% is fractional: the floor rounds UP.
contract GoldExchangeFloorRoundingTest is GoldExitExchangeFixture {
    function test_floor_roundsUp() public {
        _open(DEPLOY);
        _enable();
        uint256 amt = 1e18 + 7e11 + 4e8;
        uint256 value = amt * adapter.lastGoodPrice() / 1e18;
        assertTrue(value % 5 != 0, "fractional 20%");
        uint256 expected = value / 5 + 1; // ceil
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, expected - 1, expected));
        adapter.proposeEmergencyExit(amt, expected - 1);
        _propose(amt, expected);
    }
}
