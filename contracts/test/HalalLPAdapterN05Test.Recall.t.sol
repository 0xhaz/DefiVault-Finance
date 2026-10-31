// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {N05Base} from "./HalalLPAdapterN05Test.Base.t.sol";
import {HalalLPAdapter} from "../adapters/HalalLPAdapter.sol";

/// @dev Recall-side behaviour of the two-sided HalalLPAdapter (finding N-05).
abstract contract N05RecallTests is N05Base {
    uint256 internal constant AMT = 10_000e6;

    event Recalled(uint256 amount);

    function _donateIdle(uint256 usdcAmt) internal returns (uint256 pairAmt) {
        pairAmt = _usdcToPair(usdcAmt, _sqrtAt(baseTick));
        usdc.mint(address(adapter), usdcAmt);
        pair.mint(address(adapter), pairAmt);
    }

    // ── partial recall ───────────────────────────────────────────────────────
    function test_recallPartial_returnsUsdcToVault() public {
        _deploy(AMT);
        uint256 liq = pm.posLiquidity();
        uint256 cv = adapter.currentValue();

        vm.expectEmit(false, false, false, true, address(adapter));
        emit Recalled(4_000e6);
        uint256 returned = _recall(4_000e6);

        assertEq(usdc.balanceOf(vault), returned, "vault received exactly the returned USDC");
        assertApproxEqRel(returned, cv * 4 / 10, 1e12, "40% of NAV");
        assertEq(adapter.totalDeployed(), 6_000e6);
        assertEq(adapter.positionTokenId(), 1, "position stays open");
        assertEq(pm.lastDecLiquidity(), liq * 4_000 / 10_000, "40% of liquidity burned");
        assertEq(pair.balanceOf(vault), 0, "vault never sees the pair token");
        assertLe(usdc.balanceOf(address(adapter)), AMT / 1e5 + 1);
        // Fresh pair proceeds were swapped back; only dust from the deploy leftovers remains.
        assertLe(_pairToUsdc(pair.balanceOf(address(adapter)), _sqrtAt(baseTick)), AMT / 1e5 + 1, "pair dust only");
        assertApproxEqRel(adapter.currentValue(), cv * 6 / 10, 1e12, "60% of NAV left");
        _assertNoApprovals();
    }

    function test_recallPartial_sweepsIdleBalancesProportionally() public {
        _deploy(AMT);
        uint256 idlePair = _donateIdle(1_000e6);
        uint256 u0 = usdc.balanceOf(address(adapter));
        uint256 p0 = pair.balanceOf(address(adapter));
        assertGe(p0, idlePair);
        uint256 cv = adapter.currentValue();

        uint256 returned = _recall(4_000e6);

        // Exactly 40% of each pre-existing idle balance left; all fresh proceeds left.
        assertEq(usdc.balanceOf(address(adapter)), u0 - Math.mulDiv(u0, 4_000, 10_000), "idle usdc pro rata");
        assertEq(pair.balanceOf(address(adapter)), p0 - Math.mulDiv(p0, 4_000, 10_000), "idle pair pro rata");
        assertApproxEqRel(returned, cv * 4 / 10, 1e12, "share of NAV incl. idle");
        assertEq(usdc.balanceOf(vault), returned);
        _assertNoApprovals();
    }

    function test_recallPartial_leavesProRataOfFees() public {
        _deploy(AMT);
        uint160 p = _sqrtAt(baseTick);
        _accrue(50e6, _usdcToPair(50e6, p));
        uint256 cv = adapter.currentValue();
        uint256 returned = _recall(4_000e6);
        assertApproxEqRel(returned, cv * 4 / 10, 1e12, "includes 40% of fees");
        assertApproxEqRel(adapter.currentValue(), cv * 6 / 10, 1e12, "60% of fees still owed");
    }

    // ── full recall ──────────────────────────────────────────────────────────
    function test_recallFull_closesPositionAndSweepsEverything() public {
        _deploy(AMT);
        _donateIdle(500e6);
        uint256 cv = adapter.currentValue();

        uint256 returned = _recall(AMT);

        assertEq(adapter.positionTokenId(), 0, "position cleared");
        assertEq(adapter.totalDeployed(), 0);
        assertEq(pm.posLiquidity(), 0);
        assertEq(usdc.balanceOf(address(adapter)), 0, "no usdc left");
        assertEq(pair.balanceOf(address(adapter)), 0, "no pair left");
        assertEq(usdc.balanceOf(vault), returned);
        assertApproxEqRel(returned, cv, 1e12, "full NAV incl. donation");
        _assertNoApprovals();
    }

    function test_recallFull_amountAboveBasisIsFull() public {
        _deploy(AMT);
        uint256 returned = _recall(type(uint256).max);
        assertEq(adapter.positionTokenId(), 0);
        assertEq(adapter.totalDeployed(), 0);
        assertApproxEqRel(returned, AMT, 1e12);
        assertEq(usdc.balanceOf(vault), returned);
    }

    function test_recallFull_thenRedeployWorks() public {
        _deploy(AMT);
        _recall(AMT);
        _deploy(2_000e6);
        assertEq(adapter.positionTokenId(), 2);
        assertEq(adapter.totalDeployed(), 2_000e6);
    }

    function test_recall_zeroAmountIsNoop() public {
        _deploy(AMT);
        uint256 swaps = router.swapCount();
        assertEq(_recall(0), 0);
        assertEq(router.swapCount(), swaps);
        assertEq(pm.decreaseCount(), 0);
        assertEq(adapter.totalDeployed(), AMT);
    }

    function test_recall_noPositionSweepsIdleUsdcToVault() public {
        // With no cost basis any recall is "full": idle balances are swept to the vault.
        usdc.mint(address(adapter), 123e6);
        assertEq(_recall(1), 123e6);
        assertEq(usdc.balanceOf(vault), 123e6);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(router.swapCount(), 0);
    }

    function test_recall_feesIncludedInFullRecall() public {
        _deploy(AMT);
        uint160 p = _sqrtAt(baseTick);
        uint256 cv0 = adapter.currentValue();
        _accrue(50e6, _usdcToPair(50e6, p));
        assertApproxEqAbs(adapter.currentValue(), cv0 + 100e6, 1e3, "fees counted in NAV");
        uint256 returned = _recall(AMT);
        assertApproxEqRel(returned, cv0 + 100e6, 1e12, "fees paid out as USDC");
        assertEq(pm.owed0(), 0);
        assertEq(pm.owed1(), 0);
        assertEq(pair.balanceOf(address(adapter)), 0);
    }

    // ── slippage / oracle on recall ──────────────────────────────────────────
    function test_recallSwapShortfallBeyondMax_reverts() public {
        _deploy(AMT);
        router.setPayoutBps(9_899);
        vm.prank(vault);
        vm.expectRevert(bytes("Too little received"));
        adapter.recall(4_000e6);
        assertEq(adapter.totalDeployed(), AMT);
        assertEq(adapter.positionTokenId(), 1);
        assertEq(pm.decreaseCount(), 0, "burn rolled back with the reverted call");
        assertEq(usdc.balanceOf(vault), 0);
        _assertNoApprovals();
    }

    function test_recallSpotMovedButTwapNot_reverts() public {
        _deploy(AMT);
        pm.setTicks(baseTick + 101, baseTick);
        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(HalalLPAdapter.SpotTwapDeviation.selector, baseTick + 101, baseTick));
        adapter.recall(AMT);
        assertEq(adapter.totalDeployed(), AMT);
    }

    function test_recallSwapMinimumDerivedFromTwap() public {
        _deploy(AMT);
        uint160 pTwap = _sqrtAt(baseTick);
        router.setPrice(_sqrtAt(baseTick + 50)); // only the router quote moves (0.5%)
        _recall(AMT);
        assertEq(router.lastTokenIn(), address(pair));
        uint256 expected = _pairToUsdc(router.lastAmountIn(), pTwap) * 9_900 / 10_000;
        assertEq(router.lastAmountOutMinimum(), expected);
    }

    // ── access ───────────────────────────────────────────────────────────────
    function test_onlyVaultCanRecall() public {
        _deploy(AMT);
        address[3] memory callers = [attacker, owner, address(this)];
        for (uint256 i; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(HalalLPAdapter.OnlyVault.selector);
            adapter.recall(AMT);
        }
        assertEq(adapter.totalDeployed(), AMT);
    }

    // ── round trip ───────────────────────────────────────────────────────────
    function test_roundTrip_unchangedPrice_lossBoundedByRounding() public {
        _deploy(AMT);
        uint256 returned = _recall(AMT);
        assertLe(returned, AMT, "no free money");
        assertGe(returned, AMT - AMT / 1e5, "loss <= 0.001% with a lossless router/manager");
    }

    function test_roundTrip_withSwapSlippage_lossBoundedBySlippage() public {
        router.setPayoutBps(9_950); // 50 bps lost on each swap
        _deploy(AMT);
        uint256 returned = _recall(AMT);
        // Each swap touches ~half of the funds: expected loss ~ 0.5% of AMT, hard cap = 1%.
        assertLe(returned, AMT);
        assertGe(returned, AMT - AMT * 100 / 10_000, "loss <= maxSlippageBps of principal");
        assertApproxEqRel(returned, AMT * 995 / 1000, 2e15, "loss ~ 0.5% (two half-size 0.5% swaps)");
    }

    function test_roundTrip_withFees_returnsFeesPlusPrincipal() public {
        _deploy(AMT);
        _accrue(30e6, _usdcToPair(20e6, _sqrtAt(baseTick)));
        uint256 returned = _recall(AMT);
        assertApproxEqRel(returned, AMT + 50e6, 1e12);
    }

    function testFuzz_roundTrip_anyAmountAndPrice(uint256 amount, int256 tickOffset) public {
        amount = bound(amount, 1_000e6, 1e15);
        int24 tick = int24(baseTick + bound(tickOffset, -20_000, 20_000));
        _setPrice(tick);
        _deploy(amount);
        uint256 returned = _recall(amount);
        assertLe(returned, amount, "no free money");
        assertGe(returned, amount - amount / 10_000 - 100, "tight loss bound");
        assertEq(usdc.balanceOf(vault), returned);
        assertEq(adapter.positionTokenId(), 0);
        assertEq(adapter.totalDeployed(), 0);
        assertEq(pair.balanceOf(address(adapter)), 0);
        _assertNoApprovals();
    }

    function testFuzz_partialRecallThenFull_conservesValue(uint256 amount, uint256 firstBps) public {
        amount = bound(amount, 1_000e6, 1e15);
        firstBps = bound(firstBps, 1, 9_999);
        _deploy(amount);
        uint256 r1 = _recall(amount * firstBps / 10_000);
        uint256 r2 = _recall(type(uint256).max);
        assertLe(r1 + r2, amount);
        assertGe(r1 + r2, amount - amount / 10_000 - 100, "tight loss bound");
        assertEq(adapter.positionTokenId(), 0);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(pair.balanceOf(address(adapter)), 0);
    }
}

contract HalalLPAdapterN05Recall_Usdc0Pair18 is N05RecallTests {
    function _usdcIsToken0() internal pure override returns (bool) { return true; }
    function _pairDecimals() internal pure override returns (uint8) { return 18; }
}

contract HalalLPAdapterN05Recall_Usdc1Pair18 is N05RecallTests {
    function _usdcIsToken0() internal pure override returns (bool) { return false; }
    function _pairDecimals() internal pure override returns (uint8) { return 18; }
}

contract HalalLPAdapterN05Recall_Usdc0Pair6 is N05RecallTests {
    function _usdcIsToken0() internal pure override returns (bool) { return true; }
    function _pairDecimals() internal pure override returns (uint8) { return 6; }
}

contract HalalLPAdapterN05Recall_Usdc1Pair6 is N05RecallTests {
    function _usdcIsToken0() internal pure override returns (bool) { return false; }
    function _pairDecimals() internal pure override returns (uint8) { return 6; }
}
