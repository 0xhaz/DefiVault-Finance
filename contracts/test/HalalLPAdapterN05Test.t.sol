// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {N05Base} from "./HalalLPAdapterN05Test.Base.t.sol";
import {HalalLPAdapter} from "../adapters/HalalLPAdapter.sol";

/// @dev Deploy-side behaviour of the two-sided HalalLPAdapter (finding N-05).
abstract contract N05DeployTests is N05Base {
    uint256 internal constant AMT = 10_000e6;

    event Deployed(uint256 amount);

    // ── two-sided deploy ─────────────────────────────────────────────────────
    function test_deploy_usesBothTokensAtPriceRatio() public {
        _deploy(AMT);
        uint160 p = _sqrtAt(baseTick);
        (uint256 usdcLeg, uint256 pairLeg) = _legs();

        assertEq(router.swapCount(), 1, "one swap");
        assertEq(router.lastTokenIn(), address(usdc));
        assertEq(router.lastTokenOut(), address(pair));
        assertEq(pm.mintCount(), 1);
        assertEq(adapter.positionTokenId(), 1);
        assertEq(adapter.totalDeployed(), AMT);
        assertGt(usdcLeg, 0);
        assertGt(pairLeg, 0);
        // Full-range position: both legs carry equal USDC value.
        assertApproxEqRel(usdcLeg, _pairToUsdc(pairLeg, p), 1e13, "legs balanced by value");
        assertEq(usdcLeg + router.lastAmountIn(), AMT, "legs partition the deployed amount");
        // Both tokens were actually consumed by the position manager.
        assertGt(usdc.balanceOf(address(pm)), 0, "pm holds usdc");
        assertGt(pair.balanceOf(address(pm)), 0, "pm holds pair token");
        // Conservation: nothing lost between adapter, pm and router.
        assertEq(usdc.balanceOf(address(pm)) + usdc.balanceOf(address(adapter)) + router.lastAmountIn(), AMT);
        assertEq(pair.balanceOf(address(pm)) + pair.balanceOf(address(adapter)), pairLeg);
        // Almost all of both legs was consumed.
        assertLe(usdc.balanceOf(address(adapter)), AMT / 1e5 + 1);
        assertLe(_pairToUsdc(pair.balanceOf(address(adapter)), p), AMT / 1e5 + 1);
        _assertNoApprovals();
    }

    function test_deploy_emitsDeployed() public {
        usdc.mint(address(adapter), AMT);
        vm.expectEmit(false, false, false, true, address(adapter));
        emit Deployed(AMT);
        vm.prank(vault);
        assertEq(adapter.deploy(AMT), AMT);
    }

    function test_deploy_mintMinimumsAre99PercentOfEachLeg() public {
        _deploy(AMT);
        assertEq(pm.lastMintAmount0Min(), pm.lastMintAmount0Desired() * 9_900 / 10_000);
        assertEq(pm.lastMintAmount1Min(), pm.lastMintAmount1Desired() * 9_900 / 10_000);
    }

    function test_deploy_leftoversStayInAdapterAndCountInCurrentValue() public {
        pm.setPayoutBps(9_950); // manager consumes only 99.5% of each leg (inside the 1% bound)
        _deploy(AMT);
        uint160 p = _sqrtAt(baseTick);
        (uint256 usdcLeg, uint256 pairLeg) = _legs();

        assertApproxEqRel(usdc.balanceOf(address(adapter)), usdcLeg / 200, 1e15, "usdc leftover ~0.5%");
        assertApproxEqRel(pair.balanceOf(address(adapter)), pairLeg / 200, 1e15, "pair leftover ~0.5%");
        assertGt(pair.balanceOf(address(adapter)), 0);
        // Leftovers are part of NAV: value is still ~ the cost basis.
        assertApproxEqRel(adapter.currentValue(), AMT, 1e13, "NAV includes leftovers");
        uint256 leftoverValue = usdc.balanceOf(address(adapter)) + _pairToUsdc(pair.balanceOf(address(adapter)), p);
        assertGt(adapter.currentValue(), leftoverValue, "position + leftovers");
        _assertNoApprovals();
    }

    function test_deploy_secondDeployRevertsWhilePositionOpen() public {
        _deploy(AMT);
        usdc.mint(address(adapter), 1e6);
        vm.prank(vault);
        vm.expectRevert(HalalLPAdapter.PositionAlreadyOpen.selector);
        adapter.deploy(1e6);
    }

    // ── range edges: only one token is needed ────────────────────────────────
    function _oneSided(int24 tick, bool token0Only) internal {
        _setRange(baseTick - 1000, baseTick + 1000);
        _setPrice(tick);
        _deploy(AMT);
        uint256 d0 = pm.lastMintAmount0Desired();
        uint256 d1 = pm.lastMintAmount1Desired();
        if (token0Only) {
            assertGt(d0, 0);
            assertEq(d1, 0);
            assertEq(pm.lastMintAmount1Min(), 0);
        } else {
            assertGt(d1, 0);
            assertEq(d0, 0);
            assertEq(pm.lastMintAmount0Min(), 0);
        }
        bool swapped = token0Only ? !usdc0 : usdc0;
        assertEq(router.swapCount(), swapped ? 1 : 0, "swap only when USDC is not the needed token");
        if (swapped) assertEq(router.lastAmountIn(), AMT, "whole deposit swapped");
        else assertEq(usdc.balanceOf(address(pm)) + usdc.balanceOf(address(adapter)), AMT);
        assertEq(adapter.totalDeployed(), AMT);
        assertGt(adapter.positionTokenId(), 0);
        assertApproxEqRel(adapter.currentValue(), AMT, 1e13, "one-sided NAV");
        _assertNoApprovals();
    }

    function test_range_priceAtLowerEdge_onlyToken0() public { _oneSided(baseTick - 1000, true); }
    function test_range_priceBelowRange_onlyToken0() public { _oneSided(baseTick - 1050, true); }
    function test_range_priceAtUpperEdge_onlyToken1() public { _oneSided(baseTick + 1000, false); }
    function test_range_priceAboveRange_onlyToken1() public { _oneSided(baseTick + 1050, false); }

    function test_range_priceInsideRange_usesBoth() public {
        _setRange(baseTick - 1000, baseTick + 1000);
        _deploy(AMT);
        uint160 p = _sqrtAt(baseTick);
        (uint256 usdcLeg, uint256 pairLeg) = _legs();
        assertGt(usdcLeg, 0);
        assertGt(pairLeg, 0);
        // Centered range: symmetric weights => ~equal value legs.
        assertApproxEqRel(usdcLeg, _pairToUsdc(pairLeg, p), 1e15);
        assertEq(router.swapCount(), 1);
        assertApproxEqRel(adapter.currentValue(), AMT, 1e13);
    }

    // ── realistic decimal-adjusted pricing ───────────────────────────────────
    function test_realisticPrice_pairWorth2000Usdc() public {
        // pair token priced at 2000 USDC: ln(2000)/ln(1.0001) ~= 76013 ticks of raw ratio
        _setPrice(usdc0 ? baseTick - 76013 : baseTick + 76013);
        uint256 amt = 1_000_000e6;
        _deploy(amt);
        (uint256 usdcLeg, uint256 pairLeg) = _legs();
        assertApproxEqRel(usdcLeg, 500_000e6, 1e15, "half stays USDC");
        assertApproxEqRel(pairLeg, 250 * 10 ** pairDec, 1e15, "other half buys 250 pair tokens");
        assertApproxEqRel(adapter.currentValue(), amt, 1e13);
    }

    // ── swap slippage ────────────────────────────────────────────────────────
    function test_swapShortfallBeyondMax_reverts_noStrandedState() public {
        router.setPayoutBps(9_899); // 1.01% short > 100 bps
        usdc.mint(address(adapter), AMT);
        vm.prank(vault);
        vm.expectRevert(bytes("Too little received"));
        adapter.deploy(AMT);

        assertEq(adapter.totalDeployed(), 0);
        assertEq(adapter.positionTokenId(), 0);
        assertEq(usdc.balanceOf(address(adapter)), AMT, "funds untouched");
        assertEq(pair.balanceOf(address(adapter)), 0);
        assertEq(router.swapCount(), 0);
        assertEq(pm.mintCount(), 0);
        _assertNoApprovals();
    }

    function test_swapShortfallAtMax_succeeds() public {
        router.setPayoutBps(9_900); // exactly 100 bps
        _deploy(AMT);
        assertEq(adapter.totalDeployed(), AMT);
        _assertNoApprovals();
    }

    function test_swapMinimumIsDerivedFromTwapNotSpot() public {
        uint160 pTwap = _sqrtAt(baseTick);
        uint160 pSpot = _sqrtAt(baseTick + 50);
        pm.setTicks(baseTick + 50, baseTick); // spot moves, TWAP does not
        router.setPrice(pSpot); // the router quotes spot

        _deploy(AMT);
        uint256 amountIn = router.lastAmountIn();
        uint256 quoteTwap = _usdcToPair(amountIn, pTwap);
        uint256 quoteSpot = _usdcToPair(amountIn, pSpot);
        assertEq(router.lastAmountOutMinimum(), quoteTwap * 9_900 / 10_000, "min = 99% of TWAP quote");
        assertTrue(router.lastAmountOutMinimum() != quoteSpot * 9_900 / 10_000, "not the spot quote");
    }

    function test_routerOffTwapAdversely_reverts() public {
        // Router is manipulated 5% against the adapter while pool TWAP/spot are untouched.
        router.setPrice(_sqrtAt(usdc0 ? baseTick - 500 : baseTick + 500));
        usdc.mint(address(adapter), AMT);
        vm.prank(vault);
        vm.expectRevert(bytes("Too little received"));
        adapter.deploy(AMT);
    }

    // ── oracle guard on deploy ───────────────────────────────────────────────
    function test_spotMovedButTwapNot_deployReverts() public {
        usdc.mint(address(adapter), AMT);
        pm.setTicks(baseTick + 101, baseTick);
        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(HalalLPAdapter.SpotTwapDeviation.selector, baseTick + 101, baseTick));
        adapter.deploy(AMT);
        pm.setTicks(baseTick - 101, baseTick);
        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(HalalLPAdapter.SpotTwapDeviation.selector, baseTick - 101, baseTick));
        adapter.deploy(AMT);
        assertEq(router.swapCount(), 0);
        assertEq(usdc.balanceOf(address(adapter)), AMT);
    }

    function test_twapUnavailable_deployReverts() public {
        usdc.mint(address(adapter), AMT);
        pm.setObserveUnavailable(true);
        vm.prank(vault);
        vm.expectRevert(HalalLPAdapter.TwapUnavailable.selector);
        adapter.deploy(AMT);
    }

    // ── access ───────────────────────────────────────────────────────────────
    function test_onlyVaultCanDeploy() public {
        usdc.mint(address(adapter), AMT);
        address[3] memory callers = [attacker, owner, address(this)];
        for (uint256 i; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(HalalLPAdapter.OnlyVault.selector);
            adapter.deploy(AMT);
        }
        assertEq(adapter.totalDeployed(), 0);
    }

    // ── fuzz ─────────────────────────────────────────────────────────────────
    function testFuzz_deploy_anyAmountAndPrice(uint256 amount, int256 tickOffset) public {
        amount = bound(amount, 1_000e6, 1e15);
        int24 tick = int24(baseTick + bound(tickOffset, -20_000, 20_000));
        _setPrice(tick);
        _deploy(amount);
        uint160 p = _sqrtAt(tick);

        (uint256 usdcLeg, uint256 pairLeg) = _legs();
        assertGt(usdcLeg, 0);
        assertGt(pairLeg, 0);
        assertEq(usdcLeg + router.lastAmountIn(), amount);
        assertEq(adapter.totalDeployed(), amount);
        assertGt(adapter.positionTokenId(), 0);
        assertApproxEqRel(usdcLeg, _pairToUsdc(pairLeg, p), 1e14, "balanced legs");
        assertApproxEqAbs(adapter.currentValue(), amount, amount / 10_000 + 100, "NAV ~ cost");
        _assertNoApprovals();
    }

    function testFuzz_deploy_narrowRangeAnyPrice(uint256 amount, int256 tickOffset) public {
        amount = bound(amount, 1_000e6, 1e15);
        _setRange(baseTick - 1000, baseTick + 1000);
        int24 tick = int24(baseTick + bound(tickOffset, -3_000, 3_000));
        _setPrice(tick);
        _deploy(amount);
        assertEq(adapter.totalDeployed(), amount);
        assertGt(adapter.positionTokenId(), 0);
        assertApproxEqAbs(adapter.currentValue(), amount, amount / 10_000 + 100, "NAV ~ cost");
        _assertNoApprovals();
    }
}

contract HalalLPAdapterN05Test_Usdc0Pair18 is N05DeployTests {
    function _usdcIsToken0() internal pure override returns (bool) { return true; }
    function _pairDecimals() internal pure override returns (uint8) { return 18; }
}

contract HalalLPAdapterN05Test_Usdc1Pair18 is N05DeployTests {
    function _usdcIsToken0() internal pure override returns (bool) { return false; }
    function _pairDecimals() internal pure override returns (uint8) { return 18; }
}

contract HalalLPAdapterN05Test_Usdc0Pair6 is N05DeployTests {
    function _usdcIsToken0() internal pure override returns (bool) { return true; }
    function _pairDecimals() internal pure override returns (uint8) { return 6; }
}

contract HalalLPAdapterN05Test_Usdc1Pair6 is N05DeployTests {
    function _usdcIsToken0() internal pure override returns (bool) { return false; }
    function _pairDecimals() internal pure override returns (uint8) { return 6; }
}
