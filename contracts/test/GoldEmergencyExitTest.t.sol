// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    GoldExitBase, GoldExitExchangeFixture, GoldExitAllocFixture, IGoldX, ActorProxy, RecordingRouter
} from "./GoldEmergencyExitTest.Base.t.sol";

/// @dev Execution behaviour: outage, exact router params, approvals, atomicity, cache policy, reentrancy, fuzz.
abstract contract GoldExitBehaviourSuite is GoldExitBase {
    uint256 internal lp0;
    uint256 internal lpAt0;

    /// @dev Open a position, enable the exit, refresh the oracle; remember the entry-time cache.
    function _scenario() internal {
        _open(DEPLOY);
        lp0 = adapter.lastGoodPrice();
        lpAt0 = adapter.lastGoodPriceAt();
        _enable();
    }

    function _assertCache(uint256 p, uint256 at) internal view {
        assertEq(adapter.lastGoodPrice(), p, "lastGoodPrice");
        assertEq(adapter.lastGoodPriceAt(), at, "lastGoodPriceAt");
    }

    function _recallCall() internal pure returns (bytes memory) {
        return abi.encodeCall(IGoldX.recall, (DEPLOY));
    }

    function _vaultHook() internal view returns (ActorProxy) {
        return ActorProxy(vault);
    }

    function _pendingAmount() internal view returns (uint256 t) {
        (t,,,) = adapter.pendingEmergencyExit();
    }

    // ── outage: ordinary recall fails, emergency exit works above the 20% floor ─
    function test_outage_recallReverts_butExitSucceeds_partialThenRemainder() public {
        _scenario();
        assertGt(lp0, 0);
        _outage();
        uint256 exitPrice = 1_000e6; // ~30% of cached: under the haircut + 10% outage floor, above the 20% hard floor
        router.setPrice(exitPrice);

        vm.expectPartialRevert(SlippageExceeded.selector);
        vaultP.forward(address(adapter), _recallCall());

        uint256 h0 = _held();
        uint256 d0 = adapter.totalDeployed();
        uint256 sold = h0 * 40 / 100;
        uint256 minOut = _out(sold, 900e6);
        assertGe(minOut, _floor(sold));
        uint256 expectedOut = _out(sold, exitPrice);
        uint256 vaultBefore = usdc.balanceOf(vault);

        _propose(sold, minOut);
        _wait();
        vm.expectEmit(true, false, false, true, address(adapter));
        emit EmergencyExit(owner, sold, expectedOut, minOut);
        uint256 got = _execute();

        assertEq(got, expectedOut, "return value");
        assertEq(usdc.balanceOf(vault) - vaultBefore, expectedOut, "USDC lands in vault");
        assertEq(usdc.balanceOf(address(adapter)), 0, "no USDC stranded");
        assertEq(_held(), h0 - sold);
        assertEq(gold.balanceOf(address(adapter)), h0 - sold, "token balance mirrors held");
        uint256 d1 = d0 - Math.mulDiv(d0, sold, h0);
        assertEq(adapter.totalDeployed(), d1, "principal reduced proportionally");
        assertGe(d1 * h0, d0 * (h0 - sold));
        assertLt(d1 * h0, d0 * (h0 - sold) + h0);
        _assertCache(lp0, lpAt0); // untouched during the outage
        assertEq(_vaultHook().retireCalls(), 1, "vault hook called once");
        assertEq(_vaultHook().lastSold(), sold);
        assertEq(_vaultHook().lastHeldBefore(), h0);

        // Ordinary recall is still blocked while the oracle is down.
        vm.expectPartialRevert(SlippageExceeded.selector);
        vaultP.forward(address(adapter), _recallCall());

        // Remainder: full close zeroes principal.
        uint256 rest = _held();
        uint256 outRest = _exit(rest);
        assertEq(outRest, _out(rest, exitPrice));
        assertEq(_held(), 0);
        assertEq(adapter.totalDeployed(), 0, "full close zeroes principal");
        assertEq(gold.balanceOf(address(adapter)), 0);
        assertEq(usdc.balanceOf(vault) - vaultBefore, expectedOut + outRest);
        assertEq(_vaultHook().retireCalls(), 2);
        assertEq(_vaultHook().lastSold(), rest);
        assertEq(_vaultHook().lastHeldBefore(), rest, "full sale: sold == heldBefore");
        _assertCache(lp0, lpAt0);
    }

    function test_outage_crashBelowTwentyPercent_executionRejected_atomic() public {
        _scenario();
        _outage();
        router.setPrice(500e6); // ~15% of cached price: used to succeed, now must not
        uint256 sold = _held() / 2;
        uint256 floor = _floor(sold);
        uint256 out = _out(sold, 500e6);
        assertLt(out, floor);
        uint256 h = _held();
        uint256 d = adapter.totalDeployed();

        // A minOut matching the crash price cannot even be proposed.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, out, floor));
        adapter.proposeEmergencyExit(sold, out);

        // A floor-compliant proposal cannot be filled at the crash price.
        _propose(sold, floor);
        _wait();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, out, floor));
        adapter.executeEmergencyExit();
        assertEq(_held(), h);
        assertEq(adapter.totalDeployed(), d);
        assertEq(_vaultHook().retireCalls(), 0);
        assertEq(_pendingAmount(), sold, "proposal survives a failed execution");
        assertEq(gold.allowance(address(adapter), address(router)), 0);
    }

    function test_outage_priceEqualToOracle_stillDoesNotRefreshCache() public {
        _scenario();
        _outage();
        _exit(_held() / 2);
        _assertCache(lp0, lpAt0);
    }

    function test_freshSaneOracle_updatesCache() public {
        _scenario();
        router.setPrice(3_290e6); // 0.3% from oracle, inside the 1% tolerance
        uint256 sold = _held() / 3;
        uint256 out = _exit(sold);
        assertEq(adapter.lastGoodPriceAt(), block.timestamp, "timestamp refreshed");
        assertEq(adapter.lastGoodPrice(), Math.mulDiv(out, 10 ** goldDec, sold), "exit price cached");
        assertApproxEqRel(adapter.lastGoodPrice(), 3_290e6, 0.001e18);
    }

    function test_freshOracle_butExitPriceInsane_doesNotUpdateCache() public {
        _scenario();
        router.setPrice(2_000e6); // ~40% below oracle
        _exit(_held() / 3);
        _assertCache(lp0, lpAt0);
        router.setPrice(3_250e6); // 1.5% below oracle: outside 1% tolerance
        _exit(_held() / 2);
        _assertCache(lp0, lpAt0);
        router.setPrice(3_400e6); // above oracle by >1%: also not cached
        _exit(_held() / 2);
        _assertCache(lp0, lpAt0);
    }

    // ── exact router params + approvals ─────────────────────────────────
    function test_routerParams_exact_andApprovalsZero() public {
        _scenario();
        uint256 sold = _held() / 3;
        uint256 minOut = _out(sold, 3_000e6);
        uint256 callsBefore = router.calls();
        _exitMin(sold, minOut);

        assertEq(router.calls(), callsBefore + 1, "exactly one swap");
        (address tIn, address tOut, uint24 fee, address recipient, uint256 deadline, uint256 amtIn, uint256 min,
            uint160 limit) = router.last();
        assertEq(tIn, address(gold));
        assertEq(tOut, address(usdc));
        assertEq(fee, 3000);
        assertEq(recipient, vault, "recipient is the vault");
        assertEq(deadline, block.timestamp);
        assertEq(amtIn, sold, "sells exactly tokenAmount");
        assertEq(min, minOut, "proposal's bound minOut forwarded");
        assertEq(limit, 0);
        assertEq(router.allowanceSeen(), sold, "approval during swap == tokenAmount");
        assertEq(gold.allowance(address(adapter), address(router)), 0, "gold approval zeroed");
        assertEq(usdc.allowance(address(adapter), address(router)), 0, "usdc approval zero");
    }

    function test_approvalsZero_afterRevert() public {
        _scenario();
        uint256 sold = _held() / 2;
        uint256 out = _out(sold, PRICE);
        _propose(sold, out + 1);
        _wait();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, out, out + 1));
        adapter.executeEmergencyExit();
        assertEq(gold.allowance(address(adapter), address(router)), 0);
        assertEq(usdc.allowance(address(adapter), address(router)), 0);

        router.setEnforceMin(true); // router itself rejects
        vm.prank(owner);
        vm.expectRevert(RecordingRouter.RouterMinOut.selector);
        adapter.executeEmergencyExit();
        assertEq(gold.allowance(address(adapter), address(router)), 0);
    }

    function test_belowMinOut_revertsAtomically_noStateChange() public {
        _scenario();
        uint256 sold = _held() / 2;
        uint256 out = _out(sold, PRICE);
        _propose(sold, out + 1);
        _wait();
        uint256 h = _held();
        uint256 d = adapter.totalDeployed();
        uint256 calls = router.calls();
        uint256 vaultUsdc = usdc.balanceOf(vault);
        uint256 routerGold = gold.balanceOf(address(router));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, out, out + 1));
        adapter.executeEmergencyExit();

        assertEq(_held(), h);
        assertEq(adapter.totalDeployed(), d);
        assertEq(gold.balanceOf(address(adapter)), h);
        assertEq(usdc.balanceOf(vault), vaultUsdc);
        assertEq(gold.balanceOf(address(router)), routerGold);
        assertEq(router.calls(), calls);
        assertEq(_vaultHook().retireCalls(), 0);
        assertEq(_pendingAmount(), sold, "proposal not consumed");
        _assertCache(lp0, lpAt0);

        // exact boundary passes after replacing the proposal
        vm.prank(owner);
        adapter.cancelEmergencyExit();
        assertEq(_exitMin(sold, out), out);
    }

    function test_vaultHookFailure_revertsWholeExit_atomic() public {
        _scenario();
        uint256 sold = _held() / 2;
        _propose(sold, _floor(sold));
        _wait();
        uint256 h = _held();
        uint256 d = adapter.totalDeployed();
        uint256 calls = router.calls();
        uint256 vaultUsdc = usdc.balanceOf(vault);
        uint256 routerGold = gold.balanceOf(address(router));
        _vaultHook().setFailRetire(true);

        vm.prank(owner);
        vm.expectRevert(ActorProxy.RetireFailed.selector);
        adapter.executeEmergencyExit();

        assertEq(_held(), h, "held unchanged");
        assertEq(adapter.totalDeployed(), d, "totalDeployed unchanged");
        assertEq(gold.balanceOf(address(adapter)), h);
        assertEq(usdc.balanceOf(vault), vaultUsdc, "no proceeds delivered");
        assertEq(gold.balanceOf(address(router)), routerGold);
        assertEq(router.calls(), calls, "swap rolled back");
        assertEq(gold.allowance(address(adapter), address(router)), 0);
        assertEq(_pendingAmount(), sold, "proposal not consumed");
        _assertCache(lp0, lpAt0);

        _vaultHook().setFailRetire(false);
        _execute();
        assertEq(_held(), h - sold);
        assertEq(_vaultHook().retireCalls(), 1);
    }

    function test_event_fields_onFullClose() public {
        _scenario();
        uint256 held = _held();
        uint256 minOut = _floor(held);
        uint256 out = _out(held, PRICE);
        _propose(held, minOut);
        _wait();
        vm.expectEmit(true, false, false, true, address(adapter));
        emit EmergencyExit(owner, held, out, minOut);
        _execute();
        assertEq(adapter.totalDeployed(), 0);
        assertEq(_held(), 0);
        assertEq(_pendingAmount(), 0, "proposal cleared");
    }

    function test_ordinaryRecall_stillSellsEverything_afterPartialExit() public {
        _scenario();
        uint256 h = _held();
        _exit(h / 4);
        uint256 remaining = _held();
        uint256 vaultBefore = usdc.balanceOf(vault);
        vaultP.forward(address(adapter), _recallCall());
        assertEq(_held(), 0);
        assertEq(adapter.totalDeployed(), 0);
        assertEq(usdc.balanceOf(vault) - vaultBefore, _out(remaining, PRICE));
    }

    function test_deployAfterExit_buildsOnReducedPosition() public {
        _scenario();
        _exit(_held() / 2);
        uint256 d = adapter.totalDeployed();
        _open(10_000e6);
        assertEq(adapter.totalDeployed(), d + 10_000e6);
    }

    // ── reentrancy through a hostile router ─────────────────────────────
    function _reenter(uint8 outer, uint8 inner) internal {
        _scenario();
        bytes memory innerCall = inner == 0
            ? abi.encodeCall(IGoldX.deploy, (1e6))
            : inner == 1 ? abi.encodeCall(IGoldX.recall, (1)) : abi.encodeCall(IGoldX.executeEmergencyExit, ());
        ActorProxy actor = inner == 2 ? ownerP : vaultP;

        bytes memory outerCall;
        if (outer == 0) {
            usdc.mint(address(adapter), 10_000e6);
            outerCall = abi.encodeCall(IGoldX.deploy, (10_000e6));
        } else if (outer == 1) {
            outerCall = abi.encodeCall(IGoldX.recall, (1));
        } else {
            uint256 amt = _held() / 2;
            _propose(amt, _floor(amt));
            _wait();
            outerCall = abi.encodeCall(IGoldX.executeEmergencyExit, ());
        }
        router.setHook(address(actor), abi.encodeCall(ActorProxy.forward, (address(adapter), innerCall)));
        ActorProxy caller = outer == 2 ? ownerP : vaultP;
        uint256 h = _held();
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        caller.forward(address(adapter), outerCall);
        assertEq(_held(), h, "nothing changed");
    }

    function test_reenter_deploy_into_deploy() public { _reenter(0, 0); }
    function test_reenter_deploy_into_recall() public { _reenter(0, 1); }
    function test_reenter_deploy_into_exit() public { _reenter(0, 2); }
    function test_reenter_recall_into_deploy() public { _reenter(1, 0); }
    function test_reenter_recall_into_recall() public { _reenter(1, 1); }
    function test_reenter_recall_into_exit() public { _reenter(1, 2); }
    function test_reenter_exit_into_deploy() public { _reenter(2, 0); }
    function test_reenter_exit_into_recall() public { _reenter(2, 1); }
    function test_reenter_exit_into_exit() public { _reenter(2, 2); }

    // ── fuzz ────────────────────────────────────────────────────────────
    function testFuzz_repeatedPartialsThenFullClose(uint256 principal, uint256 f1, uint256 f2, uint256 f3) public {
        principal = bound(principal, 1_000e6, 50_000_000e6);
        _open(principal);
        _enable();
        uint256 minSell = 10 ** (goldDec / 2);
        uint256[3] memory fr = [f1, f2, f3];
        uint256 sumOut;
        uint256 vaultBefore = usdc.balanceOf(vault);
        for (uint256 i; i < 3; ++i) {
            uint256 H = _held();
            if (H < 2 * minSell) break;
            uint256 D = adapter.totalDeployed();
            uint256 s = bound(fr[i], minSell, H - minSell);
            sumOut += _exit(s);
            uint256 D2 = adapter.totalDeployed();
            assertEq(D2, D - Math.mulDiv(D, s, H), "model");
            assertEq(D2, Math.mulDiv(D, H - s, H, Math.Rounding.Ceil), "remaining principal rounds up");
            assertLe(D2, D);
            assertGt(D2, 0, "partial exit never closes principal");
            assertEq(_held(), H - s);
            assertEq(_vaultHook().lastSold(), s);
            assertEq(_vaultHook().lastHeldBefore(), H);
        }
        uint256 rest = _held();
        sumOut += _exit(rest);
        assertEq(_held(), 0);
        assertEq(adapter.totalDeployed(), 0, "full close = 0");
        assertEq(gold.balanceOf(address(adapter)), 0);
        assertEq(usdc.balanceOf(vault) - vaultBefore, sumOut);
    }

    function testFuzz_exitSucceedsIffOutMeetsMin(uint256 priceF, uint256 minF, bool outage) public {
        _scenario();
        if (outage) _outage();
        uint256 p = bound(priceF, 1e6, 20_000e6);
        router.setPrice(p);
        uint256 sold = _held() / 3;
        uint256 out = _out(sold, p);
        uint256 floor = _floor(sold);
        uint256 minOut = bound(minF, floor, floor + out * 2 + 1);
        uint256 h = _held();
        uint256 vaultBefore = usdc.balanceOf(vault);
        _propose(sold, minOut);
        _wait();
        vm.prank(owner);
        if (out >= minOut) {
            assertEq(adapter.executeEmergencyExit(), out);
            assertEq(usdc.balanceOf(vault) - vaultBefore, out);
            assertEq(_held(), h - sold);
        } else {
            vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, out, minOut));
            adapter.executeEmergencyExit();
            assertEq(_held(), h);
            assertEq(usdc.balanceOf(vault), vaultBefore);
            assertEq(_pendingAmount(), sold);
        }
    }
}

contract GoldExchangeEmergencyExitTest is GoldExitBehaviourSuite, GoldExitExchangeFixture {}
contract GoldAllocationEmergencyExitTest is GoldExitBehaviourSuite, GoldExitAllocFixture {}
