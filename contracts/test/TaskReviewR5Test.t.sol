// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Test.sol";

import {ShariahVault} from "../ShariahVault.sol";
import {TaskN29V1Mixin, TaskN29V2Mixin} from "./TaskN29Test.Base.t.sol";
import {HostileCharityN29, HostileTreasuryN29, HostileEscrowN29} from "./TaskN29Test.Hostile.t.sol";
import {TaskR5Base} from "./TaskReviewR5Test.Base.t.sol";

/// @dev Review R5: `_withdraw` needs gasleft() >= 2 * EXIT_SETTLE_GAS before running a realized-profit settlement,
///      otherwise it reverts InsufficientExitGas(); the floor depends on caller gas only.
abstract contract TaskR5Tests is TaskR5Base {
    uint256 internal constant AMPLE = 8_000_000;

    function _sel() internal pure returns (bytes4) {
        return ShariahVault.InsufficientExitGas.selector;
    }

    // ───────────── floor: below reverts untouched, at/above settles ─────────────

    function _assertFloorBoundary(bool w, bool p) internal {
        (uint256 minG, bool settled) = _minOk(w, p);
        assertTrue(settled, "cut routed at the minimum non-reverting gas");
        assertGe(minG, _floor(), "exit cannot succeed below the floor");

        (bool ok,, bytes4 reason) = _attempt(minG - 1, w, p);
        assertFalse(ok, "one gas below the minimum reverts");
        assertEq(reason, _sel(), "reverts InsufficientExitGas");
    }

    function test_floor_redeemFull() public {
        _adapters(1, 0);
        _yield(200e6);
        _assertFloorBoundary(false, false);
    }

    function test_floor_redeemPartial() public {
        _adapters(1, 0);
        _yield(200e6);
        _assertFloorBoundary(false, true);
    }

    function test_floor_withdrawFull() public {
        _adapters(1, 0);
        _yield(200e6);
        _assertFloorBoundary(true, false);
    }

    function test_floor_withdrawPartial_withDeficit() public {
        _adapters(5, 0);
        _yield(200e6);
        _writeHwm(1_200_000_000_000);
        _assertFloorBoundary(true, true);
    }

    function test_belowFloor_noStateChange_sharesIntact() public {
        _adapters(1, 0);
        _yield(200e6);
        (uint256 minG,) = _minOk(false, false);
        uint256 shares = vault.balanceOf(bob);
        uint256 supply = vault.totalSupply();
        uint256 bobBal = usdc.balanceOf(bob);
        uint256 vaultBal = usdc.balanceOf(address(vault));
        uint256 dist = _distNow();
        uint256 base = vault.profitBase();

        _cool(); // fresh-transaction (cold) access costs, as in _attempt
        vm.prank(bob);
        vm.expectRevert(_sel());
        vault.redeem{gas: minG - 1}(shares, bob, bob);

        assertEq(vault.balanceOf(bob), shares, "shares intact");
        assertEq(vault.totalSupply(), supply);
        assertEq(usdc.balanceOf(bob), bobBal);
        assertEq(usdc.balanceOf(address(vault)), vaultBal);
        assertEq(_distNow(), dist);
        assertEq(vault.profitBase(), base);

        // The same exit with ample gas still works afterwards (lock released, nothing stuck).
        vm.prank(bob);
        vault.redeem{gas: AMPLE}(shares, bob, bob);
        assertEq(vault.balanceOf(bob), 0);
    }

    function test_atThreshold_settlesAndEmitsClaim() public {
        _adapters(1, 0);
        _yield(200e6);
        (uint256 minG,) = _minOk(false, false);
        uint256 shares = vault.balanceOf(bob);
        uint256 wallet = usdc.balanceOf(charityWallet);
        uint256 charityTotal = charity.totalCharityDistributed();
        uint256 fees = treasury.pendingFees();

        _cool();
        vm.recordLogs();
        vm.prank(bob);
        vault.redeem{gas: minG}(shares, bob, bob);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_logs(logs, keccak256("MusharakahProfitClaimed(uint256,uint256,uint256,uint256,uint256)")).length, 1, "claim emitted");
        assertGt(charity.totalCharityDistributed(), charityTotal, "charity credited");
        assertGt(usdc.balanceOf(charityWallet), wallet, "charity wallet paid");
        assertGt(treasury.pendingFees(), fees, "manager cut booked");
        assertEq(vault.balanceOf(bob), 0);
    }

    function test_aboveThreshold_alwaysSettles_noSkipRegion() public {
        _adapters(1, 0);
        _yield(200e6);
        (uint256 minG,) = _minOk(false, false);
        for (uint256 g = minG; g <= minG + 3_000_000; g += 150_000) {
            (bool ok, bool settled,) = _attempt(g, false, false);
            assertTrue(ok, "no revert at or above the minimum");
            assertTrue(settled, "settled at every gas >= minimum");
        }
    }

    // ───────────── exits without realized profit / without escrow are not gated ─────────────

    function test_zeroRealizedProfit_notGated_lowGas() public {
        _adapters(1, 0);
        skip(30 days);
        assertEq(vault.realizedProfit(), 0);
        uint256 shares = vault.balanceOf(bob) / 2;
        uint256 bal = usdc.balanceOf(bob);
        (bool ok,, bytes4 reason) = _attempt(900_000, false, true);
        assertTrue(ok, "redeem works below the floor when nothing to settle");
        assertTrue(reason != _sel());
        (ok,, reason) = _attempt(900_000, true, true);
        assertTrue(ok, "withdraw works below the floor when nothing to settle");

        vm.prank(bob);
        vault.redeem{gas: 900_000}(shares, bob, bob);
        assertGt(usdc.balanceOf(bob), bal);
        assertEq(_distNow(), 0);
    }

    function test_noEscrow_notGated_lowGas() public {
        _adapters(1, 0);
        _yield(200e6);
        vm.prank(owner);
        vault.setPurificationEscrow(address(0));
        assertGt(vault.realizedProfit(), 0);
        (bool ok,, bytes4 reason) = _attempt(900_000, false, false);
        assertTrue(ok, "redeem works below the floor without an escrow");
        assertTrue(reason != _sel());
        (ok,,) = _attempt(900_000, true, true);
        assertTrue(ok, "withdraw works below the floor without an escrow");
        uint256 shares = vault.balanceOf(bob);
        vm.prank(bob);
        vault.redeem{gas: 900_000}(shares, bob, bob);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(_distNow(), 0);
    }

    // ───────────── hostile callees: the floor depends on caller gas only ─────────────

    function _assertHostileFallback() internal {
        (uint256 minG,,) = _hostileMin();
        assertGe(minG, _floor());
        (bool ok,, bytes4 reason) = _attempt(minG - 1, false, false);
        assertFalse(ok);
        assertEq(reason, _sel(), "below the floor still the same gate");

        // Exit at the minimum caller gas finishes even though the callee burns every forwarded unit.
        uint256 shares = vault.balanceOf(bob);
        uint256 bal = usdc.balanceOf(bob);
        uint256 quote = vault.previewRedeem(shares);
        vm.prank(bob);
        uint256 out = vault.redeem{gas: minG}(shares, bob, bob);
        assertEq(out, quote, "payout unchanged");
        assertEq(usdc.balanceOf(bob) - bal, quote);
        assertEq(vault.balanceOf(bob), 0, "shares burned");
        assertEq(_distNow(), 0, "no partial distribution");

        // And with generous gas.
    }

    function _hostileMin() internal returns (uint256 minG, bool settled, bool ok) {
        (minG, settled) = _minOk(false, false);
        ok = true;
    }

    function test_hostileCharityBurn_fallsBackAtMinimumGas() public {
        _useHostile(HostileCharityN29.Mode.Burn, HostileTreasuryN29.Mode.Ok);
        _yield(200e6);
        _assertHostileFallback();
    }

    function test_hostileTreasuryBurn_fallsBackAtMinimumGas() public {
        _useHostile(HostileCharityN29.Mode.Ok, HostileTreasuryN29.Mode.Burn);
        _yield(200e6);
        _assertHostileFallback();
    }

    function test_hostileCharityRevert_fallsBackAtMinimumGas() public {
        _useHostile(HostileCharityN29.Mode.Revert, HostileTreasuryN29.Mode.Ok);
        _yield(200e6);
        _assertHostileFallback();
    }

    function test_hostileEscrowBurn_fallsBackAtMinimumGas() public {
        HostileEscrowN29 stub = new HostileEscrowN29();
        stub.set(HostileEscrowN29.Preview.Valid, HostileEscrowN29.Exec.Burn);
        vm.prank(owner);
        vault.setPurificationEscrow(address(stub));
        _yield(200e6);
        _assertHostileFallback();
    }

    function test_hostileBurn_ampleGas_withdrawAlsoWorks() public {
        _useHostile(HostileCharityN29.Mode.Burn, HostileTreasuryN29.Mode.Burn);
        _yield(200e6);
        uint256 assets = vault.previewRedeem(vault.balanceOf(bob) / 2);
        uint256 bal = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.withdraw{gas: AMPLE}(assets, bob, bob);
        assertEq(usdc.balanceOf(bob) - bal, assets);
        assertEq(_distNow(), 0);
    }

    // ───────────── eth_estimateGas simulation ─────────────

    /// @dev eth_estimateGas returns (about) the lowest limit at which the tx does not revert.
    ///      Prove the cut was routed there, and that no succeed-without-settling band exists anywhere around it.
    function _assertEstimateRoutesCut(bool w, bool p) internal {
        (uint256 minG, bool settledAtMin) = _minOk(w, p);
        assertTrue(settledAtMin, "cut routed at the lowest non-reverting limit");
        for (uint256 g = 100_000; g <= minG + 600_000; g += 150_000) {
            (bool ok, bool settled,) = _attempt(g, w, p);
            if (g < minG) assertFalse(ok, "reverts below the estimate");
            else assertTrue(ok && settled, "every limit at/above the estimate routes the cut");
        }
    }

    function test_estimateGas_redeem_1adapter() public {
        _adapters(1, 0);
        _yield(200e6);
        _assertEstimateRoutesCut(false, false);
    }

    function test_estimateGas_withdraw_partial_1adapter() public {
        _adapters(1, 0);
        _yield(200e6);
        _assertEstimateRoutesCut(true, true);
    }

    function test_estimateGas_redeem_5adapters_deficit() public {
        _adapters(5, 0);
        _yield(200e6);
        _writeHwm(1_200_000_000_000);
        _assertEstimateRoutesCut(false, false);
    }

    function test_estimateGas_withdraw_5adapters_noDeficit() public {
        _adapters(5, 0);
        _yield(200e6);
        _assertEstimateRoutesCut(true, false);
    }

    function test_estimateGas_redeem_noAdapters() public {
        _yield(200e6);
        _assertEstimateRoutesCut(false, true);
    }
}

contract TaskR5V1Test is TaskR5Tests, TaskN29V1Mixin {}

contract TaskR5V2Test is TaskR5Tests, TaskN29V2Mixin {}
