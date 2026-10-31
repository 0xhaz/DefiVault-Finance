// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ShariahVault} from "../ShariahVault.sol";
import {ShariahVaultV2} from "../ShariahVaultV2.sol";
import {TaskN26Base} from "./TaskN26Test.Base.t.sol";
import {HostileEscrowN29} from "./TaskN29Test.Hostile.t.sol";

/// @dev Review R4: the hurdle basis stays honest across exits and the setter can no longer lower it on a live vault.
///      Fixture (TaskN26Base): alice is the sole holder of DEP = 1_000e6, hurdle 4%/yr, manager share 10%.
abstract contract TaskReviewR4Tests is TaskN26Base {
    address internal bob = makeAddr("bob");

    function _fundBob(uint256 amt) internal {
        usdc.mint(bob, amt);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _aliceRedeemBps(uint256 bps) internal returns (uint256 sh) {
        sh = vault.balanceOf(alice) * bps / 10_000;
        vm.prank(alice);
        vault.redeem(sh, alice, alice);
    }

    // ───────────── (D) setter guard ─────────────

    function test_setter_decreaseWithLiveSupply_reverts() public {
        uint256 p = vault.hurdlePrincipal();
        assertGt(vault.totalSupply(), 0);
        vm.prank(owner);
        vm.expectRevert(ShariahVault.HurdlePrincipalCannotDecrease.selector);
        vault.setHurdlePrincipal(p - 1);
        vm.prank(owner);
        vm.expectRevert(ShariahVault.HurdlePrincipalCannotDecrease.selector);
        vault.setHurdlePrincipal(0);
        assertEq(vault.hurdlePrincipal(), p, "unchanged after reverts");
    }

    function test_setter_equalAndIncrease_succeed() public {
        uint256 p = vault.hurdlePrincipal();
        vm.prank(owner);
        vault.setHurdlePrincipal(p);
        assertEq(vault.hurdlePrincipal(), p);
        vm.prank(owner);
        vault.setHurdlePrincipal(p + 1);
        assertEq(vault.hurdlePrincipal(), p + 1);
        vm.prank(owner);
        vault.setHurdlePrincipal(type(uint128).max);
        assertEq(vault.hurdlePrincipal(), type(uint128).max);
    }

    function test_setter_anyValueAtZeroSupply() public {
        _aliceRedeemBps(10_000);
        assertEq(vault.totalSupply(), 0);
        vm.startPrank(owner);
        vault.setHurdlePrincipal(500e6);
        assertEq(vault.hurdlePrincipal(), 500e6);
        vault.setHurdlePrincipal(1e6); // decrease allowed with no holders
        assertEq(vault.hurdlePrincipal(), 1e6);
        vault.setHurdlePrincipal(0);
        assertEq(vault.hurdlePrincipal(), 0);
        vault.setHurdlePrincipal(1e30);
        assertEq(vault.hurdlePrincipal(), 1e30);
        vm.stopPrank();
    }

    function test_setter_nonOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setHurdlePrincipal(DEP * 2);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, manager));
        vault.setHurdlePrincipal(DEP * 2);
    }

    // ───────────── (C) zero-profit exit scales the basis ─────────────

    function test_zeroProfitExit_scalesPrincipal_keepsClock_shrinksAllowance() public {
        skip(100 days);
        uint256 start = vault.hurdleStartTime();
        uint256 p0 = vault.hurdlePrincipal();
        uint256 supply0 = vault.totalSupply();
        uint256 allowBefore = _hurdleNow();
        assertGt(allowBefore, 0);
        assertEq(vault.realizedProfit(), 0);

        uint256 sh = _aliceRedeemBps(3_000);

        assertEq(vault.hurdlePrincipal(), Math.mulDiv(p0, supply0 - sh, supply0), "principal scaled by remaining fraction");
        assertEq(vault.hurdleStartTime(), start, "clock unchanged");
        assertApproxEqAbs(_hurdleNow(), Math.mulDiv(allowBefore, supply0 - sh, supply0), 2, "allowance shrinks by exiting fraction");
    }

    function test_zeroProfitExit_90pct_thenTimeDepositProfitableClaim_usesReducedBasis() public {
        skip(100 days);
        uint256 t0 = vault.hurdleStartTime();
        uint256 p0 = vault.hurdlePrincipal();
        _aliceRedeemBps(9_000);
        uint256 p1 = vault.hurdlePrincipal();
        assertApproxEqAbs(p1, p0 / 10, 1);

        skip(100 days);
        uint256 t1 = block.timestamp;
        uint256 amt = 900e6;
        _fundBob(amt);
        vm.prank(bob);
        vault.deposit(amt, bob);
        assertEq(vault.hurdlePrincipal(), p1 + amt, "deposit adds to the reduced basis");

        skip(165 days);
        uint256 t2 = block.timestamp;
        usdc.mint(address(vault), 100e6);

        // Allowance = p1 over [t0,t2] + amt over [t1,t2]; never the exited 90% (within start-shift rounding).
        uint256 allowExpected = (p1 * (t2 - t0) + amt * (t2 - t1)) * RATE / (10_000 * YEAR);
        assertApproxEqAbs(_hurdleNow(), allowExpected, 5, "allowance on reduced basis");
        uint256 unscaledAllowance = (p0 * (t2 - t0) + amt * (t2 - t1)) * RATE / (10_000 * YEAR);
        assertLt(_hurdleNow() + 10e6, unscaledAllowance, "exited capital no longer accrues hurdle");

        uint256 expected = _expectedFee(100e6); // TreasuryModule.calculateMusharakahSplitHWM on the vault's own inputs
        uint256 fee = _claimFee(100e6);
        assertEq(fee, expected, "fee matches treasury formula on vault inputs");
        assertApproxEqAbs(fee, (_net(100e6) - allowExpected) * SHARE / 10_000, 2, "fee = share of surplus over reduced allowance");
    }

    // ───────────── (C) failed settlement takes the same scaling path ─────────────

    function test_failedSettlementExit_scalesPrincipal_andExitSucceeds() public {
        HostileEscrowN29 stub = new HostileEscrowN29();
        stub.set(HostileEscrowN29.Preview.Valid, HostileEscrowN29.Exec.Revert);
        vm.prank(owner);
        vault.setPurificationEscrow(address(stub));

        skip(120 days);
        usdc.mint(address(vault), 80e6); // realized profit exists -> settlement is attempted, then reverts
        assertGt(vault.realizedProfit(), 0);
        uint256 start = vault.hurdleStartTime();
        uint256 p0 = vault.hurdlePrincipal();
        uint256 supply0 = vault.totalSupply();
        uint256 allowBefore = _hurdleNow();
        uint256 balBefore = usdc.balanceOf(alice);

        uint256 sh = vault.balanceOf(alice) / 4;
        vm.prank(alice);
        uint256 out = vault.redeem(sh, alice, alice);

        assertGt(out, 0, "exit succeeds");
        assertEq(usdc.balanceOf(alice) - balBefore, out);
        assertEq(vault.hurdlePrincipal(), Math.mulDiv(p0, supply0 - sh, supply0), "same scaling as zero-profit exit");
        assertEq(vault.hurdleStartTime(), start);
        assertApproxEqAbs(_hurdleNow(), Math.mulDiv(allowBefore, supply0 - sh, supply0), 2);
        assertEq(treasury.pendingFees(), 0, "failed settlement booked nothing");
    }

    function test_failedSettlementFullExit_zeroesPrincipal() public {
        HostileEscrowN29 stub = new HostileEscrowN29();
        stub.set(HostileEscrowN29.Preview.Valid, HostileEscrowN29.Exec.Revert);
        vm.prank(owner);
        vault.setPurificationEscrow(address(stub));
        skip(30 days);
        usdc.mint(address(vault), 10e6);
        _aliceRedeemBps(10_000);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.hurdlePrincipal(), 0);
    }

    // ───────────── (C) successful settlement keeps post-payout assets ─────────────

    function test_successfulSettlementExit_principalIsPostPayoutAssets_noDoubleReduction() public {
        skip(YEAR);
        usdc.mint(address(vault), 100e6);
        uint256 start = vault.hurdleStartTime();
        uint256 fees0 = treasury.pendingFees();

        _aliceRedeemBps(4_000);

        assertGt(treasury.pendingFees(), fees0, "settlement ran: manager share booked");
        // Vault-held manager fees are not depositor assets: post-payout assets = balance - pendingFees.
        assertEq(
            vault.hurdlePrincipal(),
            usdc.balanceOf(address(vault)) - treasury.pendingFees(),
            "principal = depositor assets left after payout"
        );
        assertEq(vault.hurdlePrincipal(), vault.totalAssetsBeforeDistributionCut(), "== vault's own post-payout assets");
        assertGt(vault.hurdleStartTime(), start, "settlement consumed the allowance");
        assertLe(vault.hurdleStartTime(), block.timestamp);
    }

    // ───────────── (C) full burn ─────────────

    function test_fullExit_zeroProfit_zeroesPrincipal_nextDepositRestartsClock() public {
        skip(200 days);
        _aliceRedeemBps(10_000);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.hurdlePrincipal(), 0);
        skip(50 days);
        _fundBob(250e6);
        vm.prank(bob);
        vault.deposit(250e6, bob);
        assertEq(vault.hurdlePrincipal(), 250e6, "principal = new first deposit");
        assertEq(vault.hurdleStartTime(), block.timestamp, "clock restarts");
    }

    function test_fullExit_withSettlement_zeroesPrincipal_nextDepositRestartsClock() public {
        skip(YEAR);
        usdc.mint(address(vault), 60e6);
        _aliceRedeemBps(10_000);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.hurdlePrincipal(), 0);
        skip(10 days);
        _fundBob(300e6);
        vm.prank(bob);
        vault.deposit(300e6, bob);
        assertEq(vault.hurdlePrincipal(), 300e6);
        assertEq(vault.hurdleStartTime(), block.timestamp);
    }

    // ───────────── fuzz ─────────────

    /// @dev allowance after a principal-only exit == (1 - alpha) * allowance before, and a later claim on the
    ///      remaining capital never pays the manager more than one claim on the full basis would.
    function testFuzz_exit_scalesAllowance_andClaimNeverExceedsFullBasis(
        uint256 bps, uint256 elapsed, uint256 elapsed2, uint256 profit
    ) public {
        bps = bound(bps, 1, 9_999);
        elapsed = bound(elapsed, 1 days, 5 * YEAR);
        elapsed2 = bound(elapsed2, 0, 2 * YEAR);
        profit = bound(profit, 1e6, 500e6);

        skip(elapsed);
        uint256 p0 = vault.hurdlePrincipal();
        uint256 supply0 = vault.totalSupply();
        uint256 allowBefore = _hurdleNow();

        uint256 sh = _aliceRedeemBps(bps);
        assertEq(vault.hurdleStartTime() + elapsed, block.timestamp, "clock unchanged");
        assertApproxEqAbs(_hurdleNow(), Math.mulDiv(allowBefore, supply0 - sh, supply0), 2, "(1-alpha) * allowance");

        skip(elapsed2);
        usdc.mint(address(vault), profit);
        uint256 g = vault.realizedProfit();
        assertGt(g, 0);
        assertEq(vault.hwmDeficit(), 0);
        uint256 feeScaled = _claimFee(g);

        // Same capital had nobody left: full-basis vault earning the proportional gross on the original principal.
        uint256 gFull = Math.mulDiv(g, supply0, supply0 - sh);
        (, uint256 feeFull,) = treasury.calculateMusharakahSplitHWM(_net(gFull), elapsed + elapsed2, p0, 0);
        assertLe(feeScaled, feeFull + 2, "never more than a single claim on the full basis");
    }
}

contract TaskReviewR4V1Test is TaskReviewR4Tests {
    function _newVault() internal override returns (ShariahVault) {
        return new ShariahVault(IERC20(address(usdc)), owner, DOM, address(treasury), address(0));
    }
}

contract TaskReviewR4V2Test is TaskReviewR4Tests {
    function _newVault() internal override returns (ShariahVault) {
        return new ShariahVaultV2(
            IERC20(address(usdc)), owner, DOM, address(treasury), address(0), address(registry)
        );
    }
}
