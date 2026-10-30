// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm, StdStorage, stdStorage} from "forge-std/Test.sol";

import {AutonomousVault} from "../AutonomousVault.sol";
import {ShariahVault} from "../ShariahVault.sol";
import {TaskN29Base, TaskN29V1Mixin, TaskN29V2Mixin} from "./TaskN29Test.Base.t.sol";

/// @dev N-29: what the exit actually routes to purification/charity/treasury, escrow preview parity,
///      deficit-before-hurdle ordering, and exitSettle access control.
abstract contract TaskN29Dist is TaskN29Base {
    using stdStorage for StdStorage;

    bytes32 internal constant CLAIMED_SIG =
        keccak256("MusharakahProfitClaimed(uint256,uint256,uint256,uint256,uint256)");

    struct Split {
        uint256 gross;
        uint256 purified;
        uint256 charityAmt;
        uint256 vaultShare;
        uint256 depositorShare;
    }

    function _expected(uint256 g, uint256 purBps, uint256 elapsed, uint256 principal, uint256 deficit)
        internal
        pure
        returns (Split memory s)
    {
        s.gross = g;
        s.purified = (g * purBps) / 10_000;
        uint256 after_ = g - s.purified;
        s.charityAmt = (after_ * 250) / 10_000;
        uint256 net = after_ - s.charityAmt;
        uint256 hurdle = (principal * 400 * elapsed) / (10_000 * 365 days);
        uint256 afterRecovery = net > deficit ? net - deficit : 0;
        uint256 surplus = afterRecovery > hurdle ? afterRecovery - hurdle : 0;
        s.vaultShare = (surplus * 1000) / 10_000;
        s.depositorShare = g - s.purified - s.charityAmt - s.vaultShare;
    }

    // ───────────── cut routed on exit ─────────────

    function test_exit_routesLeaversCutToCharityAndTreasury() public {
        _yield(200e6);
        uint256 shares = vault.balanceOf(bob);
        uint256 g = (vault.realizedProfit() * shares) / vault.totalSupply();
        Split memory e = _expected(g, 0, block.timestamp - vault.hurdleStartTime(), vault.hurdlePrincipal(), 0);
        assertGt(e.vaultShare, 0, "scenario exercises the manager share");

        uint256 charityCtrBefore = charity.totalCharityDistributed();
        uint256 feesBefore = treasury.pendingFees();
        uint256 walletBefore = usdc.balanceOf(charityWallet);
        vm.prank(bob);
        vault.redeem(shares, bob, bob);

        assertEq(charity.totalCharityDistributed() - charityCtrBefore, e.charityAmt, "charity counter += pro-rata charity");
        assertEq(usdc.balanceOf(charityWallet) - walletBefore, e.charityAmt, "charity wallet paid");
        assertEq(treasury.pendingFees() - feesBefore, e.vaultShare, "treasury pendingFees += pro-rata manager share");
    }

    function test_exit_routesPurificationToCharityWallet() public {
        _setPurification(100); // 1%
        usdc.mint(address(vault), 0);
        _yield(200e6);
        uint256 shares = vault.balanceOf(bob);
        uint256 g = (vault.realizedProfit() * shares) / vault.totalSupply();
        Split memory e = _expected(g, 100, block.timestamp - vault.hurdleStartTime(), vault.hurdlePrincipal(), 0);
        assertGt(e.purified, 0);

        uint256 charityCtrBefore = charity.totalCharityDistributed();
        uint256 feesBefore = treasury.pendingFees();
        uint256 walletBefore = usdc.balanceOf(charityWallet);
        vm.prank(bob);
        vault.redeem(shares, bob, bob);

        // Purification bypasses the CharityModule counter but lands in the same wallet.
        assertEq(charity.totalCharityDistributed() - charityCtrBefore, e.charityAmt);
        assertEq(usdc.balanceOf(charityWallet) - walletBefore, e.purified + e.charityAmt);
        assertEq(treasury.pendingFees() - feesBefore, e.vaultShare);
    }

    function test_exit_emitsMusharakahProfitClaimed() public {
        _yield(200e6);
        uint256 shares = vault.balanceOf(bob);
        vm.expectEmit(false, false, false, false, address(vault));
        emit MusharakahProfitClaimed(0, 0, 0, 0, 0);
        vm.prank(bob);
        vault.redeem(shares, bob, bob);
    }

    function test_exit_eventCarriesProRataSplit_withdrawPath() public {
        _setPurification(100);
        _yield(200e6);
        uint256 g = (vault.realizedProfit() * vault.balanceOf(bob)) / vault.totalSupply();
        Split memory e = _expected(g, 100, block.timestamp - vault.hurdleStartTime(), vault.hurdlePrincipal(), 0);
        uint256 assets = vault.maxWithdraw(bob);
        vm.recordLogs();
        vm.prank(bob);
        vault.withdraw(assets, bob, bob);
        Vm.Log[] memory logs = _logs(vm.getRecordedLogs(), CLAIMED_SIG);
        assertEq(logs.length, 1, "exactly one settlement event per exit");
        (uint256 gross, uint256 pur, uint256 ch, uint256 vs, uint256 ds) =
            abi.decode(logs[0].data, (uint256, uint256, uint256, uint256, uint256));
        assertApproxEqAbs(gross, e.gross, 2, "gross = realizedProfit * shares / supply");
        assertEq(gross, pur + ch + vs + ds, "conservation inside the event");
        assertApproxEqAbs(pur, e.purified, 1);
        assertApproxEqAbs(ch, e.charityAmt, 1);
        assertApproxEqAbs(vs, e.vaultShare, 1);
    }

    function test_exit_withoutProfit_emitsNothingAndRoutesNothing() public {
        skip(30 days); // no yield
        vm.recordLogs();
        uint256 out = _redeemFrac(bob, 1, 1);
        assertEq(_logs(vm.getRecordedLogs(), CLAIMED_SIG).length, 0);
        assertEq(_distributed(), 0);
        assertApproxEqAbs(out, DEP, TOL);
    }

    function test_exit_payoutEqualsQuote() public {
        _yield(200e6);
        uint256 shares = vault.balanceOf(bob);
        uint256 quote = vault.previewRedeem(shares);
        uint256 bal = usdc.balanceOf(bob);
        vm.prank(bob);
        uint256 out = vault.redeem(shares, bob, bob);
        assertEq(out, quote, "return value is the quote");
        assertEq(usdc.balanceOf(bob) - bal, quote, "exact quoted payout transferred");
    }

    // ───────────── HWM deficit consumed before hurdle ─────────────

    function _setHwm(uint256 perShare) internal {
        stdstore.target(address(vault)).sig("highWaterMarkPerShare()").checked_write(perShare);
    }

    function test_cut_deficitConsumedBeforeHurdle() public {
        _yield(200e6);
        _setHwm(1_050_000_000_000); // +5% over the 1e12 start price → ~100e6 deficit on 2e15 shares
        uint256 d = vault.hwmDeficit();
        assertApproxEqAbs(d, 100e6, 1e3);
        Split memory e = _expected(200e6, 0, block.timestamp - vault.hurdleStartTime(), vault.hurdlePrincipal(), d);
        uint256 hurdle = (vault.hurdlePrincipal() * 400 * (block.timestamp - vault.hurdleStartTime())) / (10_000 * 365 days);
        assertGt(hurdle, 0, "non-zero hurdle");
        // deficit then hurdle are both subtracted (not max(d, hurdle)).
        assertEq(e.vaultShare, ((195e6 - d - hurdle) * 1000) / 10_000);
        assertEq(vault.pendingDistributionCut(), e.charityAmt + e.vaultShare + e.purified);
        // And the real claim distributes exactly what was reserved.
        uint256 cut = vault.pendingDistributionCut();
        _claimAll();
        assertEq(_distributed(), cut);
    }

    function test_cut_deficitAbsorbsAllProfit_onlyCharityLeaves() public {
        _yield(200e6);
        _setHwm(1_200_000_000_000); // deficit ≫ profit
        assertGt(vault.hwmDeficit(), 195e6);
        assertEq(vault.pendingDistributionCut(), (200e6 * 250) / 10_000, "manager earns nothing during recovery");
        uint256 shares = vault.balanceOf(bob);
        uint256 feesBefore = treasury.pendingFees();
        vm.prank(bob);
        vault.redeem(shares, bob, bob);
        assertEq(treasury.pendingFees(), feesBefore, "no manager share while recovering a deficit");
        assertGt(charity.totalCharityDistributed(), 0);
    }

    function test_exit_deficitConsumedBeforeHurdle_inSettlement() public {
        _yield(200e6);
        _setHwm(1_020_000_000_000);
        uint256 d = vault.hwmDeficit();
        uint256 shares = vault.balanceOf(bob);
        uint256 g = (vault.realizedProfit() * shares) / vault.totalSupply();
        Split memory e = _expected(g, 0, block.timestamp - vault.hurdleStartTime(), vault.hurdlePrincipal(), d);
        uint256 feesBefore = treasury.pendingFees();
        vm.prank(bob);
        vault.redeem(shares, bob, bob);
        assertEq(treasury.pendingFees() - feesBefore, e.vaultShare, "settlement applies deficit, then hurdle");
    }

    function test_exit_restoresPreSettlementHwm() public {
        _yield(200e6);
        uint256 hwm = vault.highWaterMarkPerShare();
        _redeemFrac(bob, 1, 1);
        assertEq(vault.highWaterMarkPerShare(), hwm, "leaver's processed peak retires with the leaver");
        assertEq(vault.hwmDeficit(), 0, "stayers acquire no artificial recovery deficit");
    }

    // ───────────── escrow preview parity ─────────────

    function testFuzz_previewWaterfallHWM_matchesExecute(
        uint256 gross, uint256 elapsed, uint256 principal, uint256 deficit,
        uint256 purBps, uint256 shareBps, uint256 hurdleBps
    ) public {
        gross = bound(gross, 1, 1e15);
        elapsed = bound(elapsed, 0, 20 * 365 days);
        principal = bound(principal, 0, 1e15);
        deficit = bound(deficit, 0, 2e15);
        purBps = bound(purBps, 0, 1000);
        shareBps = bound(shareBps, 0, 3000);
        hurdleBps = bound(hurdleBps, 0, 2000);
        if (purBps > 0) _setPurification(purBps);
        vm.prank(address(vault));
        treasury.setMusharakahParams(shareBps, hurdleBps);
        _parity(gross, elapsed, principal, deficit);
    }

    function _parity(uint256 gross, uint256 elapsed, uint256 principal, uint256 deficit) internal {
        uint256[4] memory pv;
        (pv[0], pv[1], pv[2], pv[3]) = escrow.previewWaterfallHWM(gross, elapsed, principal, deficit);
        assertEq(pv[0] + pv[1] + pv[2] + pv[3], gross, "preview conserves gross");

        usdc.mint(address(vault), gross);
        uint256[4] memory before_ = [
            charity.totalCharityDistributed(), treasury.pendingFees(),
            usdc.balanceOf(charityWallet), usdc.balanceOf(address(vault))
        ];
        uint256[4] memory ex;
        vm.startPrank(address(vault));
        usdc.approve(address(escrow), gross);
        (ex[0], ex[1], ex[2], ex[3]) = escrow.executeWaterfallHWM(gross, elapsed, principal, deficit);
        vm.stopPrank();

        for (uint256 i; i < 4; ++i) assertEq(ex[i], pv[i], "preview == execute");
        assertEq(charity.totalCharityDistributed() - before_[0], ex[1]);
        assertEq(treasury.pendingFees() - before_[1], ex[2]);
        assertEq(usdc.balanceOf(charityWallet) - before_[2], ex[0] + ex[1]);
        assertEq(before_[3] - usdc.balanceOf(address(vault)), ex[0] + ex[1], "vault only loses what leaves the system");
    }

    function testFuzz_vaultCut_matchesEscrowPreview(uint256 y, uint256 days_, uint256 purBps) public {
        y = bound(y, 1, 5_000e6);
        days_ = bound(days_, 0, 1000);
        purBps = bound(purBps, 0, 1000);
        if (purBps > 0) _setPurification(purBps);
        skip(days_ * 1 days);
        usdc.mint(address(vault), y);
        uint256 g = vault.realizedProfit();
        uint256 expectedCut;
        if (g > 0) {
            (uint256 p, uint256 c, uint256 v,) = escrow.previewWaterfallHWM(
                g, block.timestamp - vault.hurdleStartTime(), vault.hurdlePrincipal(), vault.hwmDeficit()
            );
            expectedCut = p + c + v;
        }
        assertEq(vault.pendingDistributionCut(), expectedCut);
        assertEq(vault.totalAssets(), vault.totalAssetsBeforeDistributionCut() - expectedCut);
    }

    // ───────────── exitSettle is self-only ─────────────

    function test_exitSettle_notCallableByOutsiders() public {
        _yield(200e6);
        address[4] memory callers = [stranger, owner, manager, bob];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(AutonomousVault.NotManager.selector);
            vault.exitSettle(1e6);
        }
    }

    function test_exitSettle_vaultItselfOutsideAnExit_reverts() public {
        _yield(200e6);
        vm.prank(address(vault));
        vm.expectRevert(AutonomousVault.NotManager.selector);
        vault.exitSettle(1e6);
    }

    function test_exitSettle_escrowCannotReachIt() public {
        _yield(200e6);
        vm.prank(address(escrow));
        vm.expectRevert(AutonomousVault.NotManager.selector);
        vault.exitSettle(1e6);
    }
}

contract TaskN29DistV1Test is TaskN29Dist, TaskN29V1Mixin {}

contract TaskN29DistV2Test is TaskN29Dist, TaskN29V2Mixin {}
