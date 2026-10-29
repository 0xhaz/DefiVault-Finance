// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ShariahVault} from "../ShariahVault.sol";
import {GoldExchangeAdapter} from "../adapters/GoldExchangeAdapter.sol";
import {TaskNBase, MockGoldRouterN} from "./TaskNTest.Base.t.sol";

/// @title TaskMTest.N12 — GoldExchangeAdapter records USDC(6dec)-per-whole-PAXG on deploy (no pokePrice needed).
contract TaskMN12Test is TaskNBase {
    function _fresh(uint256 price) internal returns (GoldExchangeAdapter a) {
        MockGoldRouterN r = new MockGoldRouterN(address(usdc), price);
        paxg.mint(address(r), 1_000_000e18);
        usdc.mint(address(r), 50_000_000e6);
        a = new GoldExchangeAdapter(
            address(usdc), address(paxg), address(r), 3000, address(svault), owner, address(oracle)
        );
        // N-23: close the fixture spread before linking the fresh adapter used by price regressions.
        vm.prank(manager);
        svault.recallCapital(address(goldAdapter), GOLD_BUY);
        vm.startPrank(owner);
        svault.setScreened(address(a), true);
        svault.setGoldSpreadAdapter(address(a));
        vm.stopPrank();
    }

    function _deployVia(GoldExchangeAdapter a, uint256 amount) internal {
        vm.prank(manager);
        svault.deployCapitalAndExecute(address(a), amount, "");
    }

    function test_n12_beforeAnyDeploy_priceAndValueAreZero() public {
        GoldExchangeAdapter a = _fresh(PAXG_PRICE);
        assertEq(a.lastGoodPrice(), 0);
        assertEq(a.lastGoodPriceAt(), 0);
        assertEq(a.currentValue(), 0);
    }

    function test_n12_deploy_setsLastGoodPrice_withoutPokePrice() public {
        // Router price 2_500 differs from the oracle's 3_300, so equality proves the swap price was used.
        GoldExchangeAdapter a = _fresh(2_500e6);
        assertEq(uint256(oracle.price()) / 100, 3_300e6, "oracle price differs from router price");
        uint256 amount = 25_000e6; // buys exactly 10 whole PAXG

        vm.expectEmit(false, false, false, true, address(a));
        emit GoldExchangeAdapter.LastGoodPriceUpdated(2_500e6, block.timestamp);
        _deployVia(a, amount);

        assertEq(a.paxgHeld(), 10e18);
        assertEq(a.lastGoodPrice(), 2_500e6, "USDC (6 dec) per whole PAXG");
        assertEq(a.lastGoodPriceAt(), block.timestamp);
        // Entry-price cache remains observable, but fresh NAV must use the oracle without a poke.
        assertEq(a.currentValue(), (a.paxgHeld() * 3_300e6) / 1e18);
        assertEq(a.currentValue(), 33_000e6);
    }

    function test_n12_priceIsInUsdcUnits_notFixedPointScaled() public {
        GoldExchangeAdapter a = _fresh(PAXG_PRICE);
        _deployVia(a, 33_000e6);
        assertEq(a.paxgHeld(), 10e18);
        assertEq(a.lastGoodPrice(), PAXG_PRICE);
        assertGt(a.lastGoodPrice(), 1e6);
        assertLt(a.lastGoodPrice(), 1e12);
        assertEq(a.currentValue(), 33_000e6);
    }

    function test_n12_nonDivisibleAmount_valueWithinRoundingOfCost() public {
        GoldExchangeAdapter a = _fresh(PAXG_PRICE);
        _deployVia(a, 1_000e6);
        assertApproxEqAbs(a.lastGoodPrice(), PAXG_PRICE, 1);
        assertApproxEqAbs(a.currentValue(), 1_000e6, 1);
        // Fresh NAV uses the exact oracle input rather than a rounded execution-price cache.
        assertEq(a.currentValue(), (a.paxgHeld() * PAXG_PRICE) / 1e18);
    }

    function test_n12_pokePrice_afterDeploy_stillRefreshesFromOracle() public {
        GoldExchangeAdapter a = _fresh(2_500e6);
        _deployVia(a, 25_000e6);
        a.pokePrice();
        assertEq(a.lastGoodPrice(), 3_300e6, "oracle (3300 USD, 8 dec) -> 6 dec");
        assertEq(a.currentValue(), 33_000e6);
    }

    function testFuzz_n12_currentValueTracksCost_andFormulaExact(uint256 amount, uint256 price) public {
        amount = bound(amount, 100e6, 50_000e6); // inside the allocation cap; avoid router rounding at dust sizes
        price = bound(price, 100e6, 3_300e6); // above this the fixture's allocation adapter appreciates past the combined gold cap
        GoldExchangeAdapter a = _fresh(price);
        // N-23: set the oracle after the fixture spread is recalled so the router and oracle agree at deploy time.
        oracle.setPrice(int256(price * 100));
        _deployVia(a, amount);
        uint256 held = a.paxgHeld();
        assertGt(a.lastGoodPrice(), 0);
        assertApproxEqAbs(a.lastGoodPrice(), price, 2);
        // The oracle input is exact; the execution-price cache may have division rounding.
        assertEq(a.currentValue(), (held * price) / 1e18, "exact oracle formula");
        assertApproxEqAbs(a.currentValue(), amount, held / 1e18 + 1);
    }

    function test_n12_valuation_feedsVaultGoldCap() public {
        // Existing fixture holds 200_000 USDC of gold (100k PAXG + 100k XAUT); cap is 30% of NAV (300k).
        vm.prank(manager);
        svault.deployCapitalAndExecute(address(goldAdapter), 50_000e6, "");
        assertApproxEqAbs(goldAdapter.currentValue(), GOLD_BUY + 50_000e6, 2);
        vm.prank(manager);
        vm.expectPartialRevert(ShariahVault.GoldCapExceeded.selector);
        svault.deployCapitalAndExecute(address(goldAdapter), 60_000e6, ""); // 100k alloc + 150k + 60k > 300k
    }
}
