// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {N05Base} from "./HalalLPAdapterN05Test.Base.t.sol";
import {MockPositionManager} from "../test-helpers/MockPositionManager.sol";
import {HalalLPAdapter} from "../adapters/HalalLPAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev currentValue(): TWAP mark-to-market; no cost-basis fallback (reverts unless the adapter is empty).
abstract contract N05ValueTests is N05Base {
    uint256 internal constant AMT = 10_000e6;
    // 1.0001^1000 and its inverse (sqrt of a 2000-tick price move), 1e18-scaled.
    uint256 internal constant UP = 1.1051654e18;
    uint256 internal constant DOWN = 0.9048419e18;

    function test_value_beforeDeployCountsIdleOnly() public {
        assertEq(adapter.currentValue(), 0);
        usdc.mint(address(adapter), 5e6);
        pair.mint(address(adapter), _usdcToPair(7e6, _sqrtAt(baseTick)));
        assertApproxEqAbs(adapter.currentValue(), 12e6, 2);
    }

    function test_value_atDeployPriceEqualsCostBasis() public {
        _deploy(AMT);
        assertApproxEqRel(adapter.currentValue(), AMT, 1e13);
    }

    /// @dev Full range ~ constant product: when the pair appreciates by k, NAV scales by sqrt(k).
    function test_value_marksToMarketWhenPairAppreciates() public {
        _deploy(AMT);
        _setPrice(usdc0 ? baseTick - 2000 : baseTick + 2000); // pair 1.0001^2000 (~22%) dearer
        assertApproxEqRel(adapter.currentValue(), AMT * UP / 1e18, 1e15);
        assertGt(adapter.currentValue(), AMT);
        assertEq(adapter.totalDeployed(), AMT, "cost basis untouched");
    }

    function test_value_marksToMarketWhenPairDepreciates() public {
        _deploy(AMT);
        _setPrice(usdc0 ? baseTick + 2000 : baseTick - 2000);
        assertApproxEqRel(adapter.currentValue(), AMT * DOWN / 1e18, 1e15);
        assertLt(adapter.currentValue(), AMT);
    }

    function test_value_usesTwapNotSpot() public {
        _deploy(AMT);
        uint256 before_ = adapter.currentValue();
        pm.setTicks(baseTick + 400, baseTick); // spot far away, TWAP unchanged
        assertEq(adapter.currentValue(), before_, "spot is ignored");
        pm.setTicks(baseTick + 400, baseTick + 400); // TWAP moves too
        assertTrue(adapter.currentValue() != before_, "TWAP drives the mark");
    }

    function test_value_includesTokensOwed() public {
        _deploy(AMT);
        uint256 v0 = adapter.currentValue();
        _accrue(10e6, 0);
        assertApproxEqAbs(adapter.currentValue(), v0 + 10e6, 2);
        _accrue(0, _usdcToPair(25e6, _sqrtAt(baseTick)));
        assertApproxEqAbs(adapter.currentValue(), v0 + 35e6, 100);
    }

    function test_value_includesIdleBalances() public {
        _deploy(AMT);
        uint256 v0 = adapter.currentValue();
        usdc.mint(address(adapter), 40e6);
        assertEq(adapter.currentValue(), v0 + 40e6);
    }

    // ── no cost-basis fallback: an unavailable price propagates the failure ──
    function test_value_twapUnavailable_reverts() public {
        _deploy(AMT);
        _setPrice(usdc0 ? baseTick - 2000 : baseTick + 2000);
        pm.setObserveUnavailable(true);
        vm.expectRevert(HalalLPAdapter.TwapUnavailable.selector);
        adapter.currentValue();
        pm.setObserveUnavailable(false);
        assertTrue(adapter.currentValue() != AMT, "price available again -> marked value");
    }

    function test_value_twapUnavailableAfterPartialRecall_reverts() public {
        _deploy(AMT);
        _recall(4_000e6);
        pm.setObserveUnavailable(true);
        vm.expectRevert(HalalLPAdapter.TwapUnavailable.selector);
        adapter.currentValue();
    }

    function test_value_emptyAdapterAndNoTwap_isZeroNotRevert() public {
        pm.setObserveUnavailable(true);
        assertEq(adapter.currentValue(), 0);
    }

    function test_value_fundedAdapterAfterFullRecallAndNoTwap_isZero() public {
        _deploy(AMT);
        _recall(AMT);
        // Recall may leave dust/idle tokens; if the adapter is completely empty it reports 0.
        pm.setObserveUnavailable(true);
        if (adapter.totalDeployed() == 0 && adapter.positionTokenId() == 0
            && t0.balanceOf(address(adapter)) == 0 && t1.balanceOf(address(adapter)) == 0) {
            assertEq(adapter.currentValue(), 0);
        } else {
            vm.expectRevert(HalalLPAdapter.TwapUnavailable.selector);
            adapter.currentValue();
        }
    }

    function test_value_positionsCallReverts_propagates() public {
        _deploy(AMT);
        vm.mockCallRevert(address(pm), abi.encodeWithSelector(MockPositionManager.positions.selector), "boom");
        vm.expectRevert(bytes("boom"));
        adapter.currentValue();
    }

    function test_value_factoryCallReverts_propagates() public {
        _deploy(AMT);
        vm.mockCallRevert(address(pm), abi.encodeWithSelector(MockPositionManager.factory.selector), "boom");
        vm.expectRevert(bytes("boom"));
        adapter.currentValue();
    }

    function test_value_tokenBalanceReverts_propagates() public {
        _deploy(AMT);
        vm.mockCallRevert(address(pair), abi.encodeWithSelector(IERC20.balanceOf.selector), "boom");
        vm.expectRevert(bytes("boom"));
        adapter.currentValue();
    }

    function test_value_malformedObserveReturn_reverts() public {
        _deploy(AMT);
        vm.mockCall(address(pm), abi.encodeWithSelector(MockPositionManager.observe.selector), hex"01");
        vm.expectRevert();
        adapter.currentValue();
    }

    function test_value_markToMarketIsSelfOnly() public {
        vm.expectRevert(bytes("self only"));
        adapter.markToMarketValue();
    }

    function testFuzz_value_tracksPriceAndRevertsWhenUnavailable(uint256 amount, int256 tickOffset) public {
        amount = bound(amount, 1_000e6, 1e15);
        _deploy(amount);
        _setPrice(int24(baseTick + bound(tickOffset, -20_000, 20_000)));
        uint256 v = adapter.currentValue();
        assertGt(v, 0);
        pm.setObserveUnavailable(true);
        vm.expectRevert(HalalLPAdapter.TwapUnavailable.selector);
        adapter.currentValue();
    }
}

contract HalalLPAdapterN05Value_Usdc0Pair18 is N05ValueTests {
    function _usdcIsToken0() internal pure override returns (bool) { return true; }
    function _pairDecimals() internal pure override returns (uint8) { return 18; }
}

contract HalalLPAdapterN05Value_Usdc1Pair18 is N05ValueTests {
    function _usdcIsToken0() internal pure override returns (bool) { return false; }
    function _pairDecimals() internal pure override returns (uint8) { return 18; }
}

contract HalalLPAdapterN05Value_Usdc0Pair6 is N05ValueTests {
    function _usdcIsToken0() internal pure override returns (bool) { return true; }
    function _pairDecimals() internal pure override returns (uint8) { return 6; }
}

contract HalalLPAdapterN05Value_Usdc1Pair6 is N05ValueTests {
    function _usdcIsToken0() internal pure override returns (bool) { return false; }
    function _pairDecimals() internal pure override returns (uint8) { return 6; }
}
