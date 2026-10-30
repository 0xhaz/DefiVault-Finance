// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {console2} from "forge-std/Test.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {ShariahVault} from "../ShariahVault.sol";
import {AdapterN27, TaskN27Base, TaskN27V1Fixture, TaskN27V2Fixture} from "./TaskN27Test.Base.t.sol";

/// @dev N-27: downward-only mark-to-market of non-gold adapters. Run against V1 and V2 below.
abstract contract TaskN27Tests is TaskN27Base {
    // ───────────── loss lowers NAV / price immediately; HWM deficit; fee ─────────────

    function test_loss_lowersTotalAssetsAndSharePriceImmediately() public {
        _fund(a, P);
        uint256 shares = vault.balanceOf(alice);
        uint256 navBefore = vault.totalAssets();
        uint256 redeemBefore = vault.previewRedeem(shares);
        uint256 sharesPerThousandBefore = vault.previewDeposit(1_000e6);
        assertEq(navBefore, D, "cost basis == par");
        assertEq(vault.unrealizedAdapterLoss(), 0);

        a.setValue(40e6);

        assertEq(vault.unrealizedAdapterLoss(), 60e6, "loss = principal - value");
        assertEq(vault.totalAssets(), D - 60e6, "NAV drops same block");
        uint256 redeemAfter = vault.previewRedeem(shares);
        assertLt(redeemAfter, redeemBefore, "share price fell");
        assertApproxEqAbs(redeemBefore - redeemAfter, 60e6, 100, "holders bear the full loss");
        assertGt(vault.previewDeposit(1_000e6), sharesPerThousandBefore, "new entrants get more shares");

        // The marked price is what a real redemption pays out.
        uint256 half = shares / 2;
        uint256 quote = vault.previewRedeem(half);
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(half, alice, alice);
        assertEq(usdc.balanceOf(alice) - balBefore, quote);
    }

    function test_loss_createsHwmDeficit_noManagerFeeUntilRecovery() public {
        assertEq(vault.hwmDeficit(), 0, "no deficit at par");
        _fund(a, P);
        a.setValue(40e6);

        uint256 deficit = vault.hwmDeficit();
        assertApproxEqAbs(deficit, 60e6, 100, "mark-down opens a deficit vs the high-water mark");
        assertEq(vault.realizedProfit(), 0);

        // Deficit is reserved before any performance split: 50 USDC of gross profit earns no manager share.
        (, uint256 shareDuringDeficit,) = treasury.calculateMusharakahSplitHWM(50e6, 0, 0, deficit);
        (, uint256 shareNoDeficit,) = treasury.calculateMusharakahSplitHWM(50e6, 0, 0, 0);
        assertEq(shareDuringDeficit, 0, "no fee while below HWM");
        assertGt(shareNoDeficit, 0, "control: fee would exist without the mark");

        // Partial recovery by donation: still no distributable profit, claim is refused.
        usdc.mint(address(vault), 50e6);
        assertEq(vault.realizedProfit(), 0);
        assertApproxEqAbs(vault.hwmDeficit(), 10e6, 100);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.ProfitExceedsRealized.selector, 1, 0));
        vault.claimMusharakahProfit(1);

        // The adapter recovers to par: deficit closes and the 50 USDC becomes claimable profit.
        a.setValue(P);
        assertEq(vault.hwmDeficit(), 0);
        assertEq(vault.realizedProfit(), 50e6);
        uint256 feesBefore = treasury.pendingFees();
        vm.prank(manager);
        vault.claimMusharakahProfit(50e6);
        uint256 afterCharity = 50e6 - (50e6 * charity.charityBps()) / 10_000;
        uint256 expectedShare = afterCharity * treasury.musharakahShareBps() / 10_000;
        assertGt(expectedShare, 0);
        assertEq(treasury.pendingFees() - feesBefore, expectedShare, "fee only after recovery");
    }

    // ───────────── downward-only ─────────────

    function test_valueAboveCost_neverRaisesNavOrRealizedProfit() public {
        _fund(a, P);
        uint256 redeemBefore = vault.previewRedeem(vault.balanceOf(alice));
        a.setValue(500e6);
        assertEq(vault.unrealizedAdapterLoss(), 0);
        assertEq(vault.totalAssets(), D, "no upward mark");
        assertEq(vault.realizedProfit(), 0);
        assertEq(vault.hwmDeficit(), 0);
        assertEq(vault.previewRedeem(vault.balanceOf(alice)), redeemBefore);

        a.setValue(type(uint256).max);
        assertEq(vault.totalAssets(), D, "max value cannot overflow or inflate NAV");
        assertEq(vault.realizedProfit(), 0);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.ProfitExceedsRealized.selector, 1, 0));
        vault.lockProfit(1);
    }

    // ───────────── hostile / malformed adapters are unmarked and never brick the vault ─────────────

    function _assertHarmless(AdapterN27.Mode m) internal {
        _fund(a, P);
        // Control: a truthful zero reading WOULD mark the whole principal down.
        a.setValue(0);
        assertEq(vault.unrealizedAdapterLoss(), P);
        a.setMode(m);

        uint256 g = gasleft();
        uint256 navRead = vault.totalAssets();
        // The adapter is forwarded at most ADAPTER_READ_GAS per read; allow overhead for the other NAV terms.
        assertLt(g - gasleft(), 2 * vault.ADAPTER_READ_GAS() + 400_000, "NAV read gas bounded by the stipend");
        assertEq(navRead, D);
        assertEq(vault.unrealizedAdapterLoss(), 0, "failed/malformed read is unmarked");
        assertEq(vault.totalAssets(), D, "contributes zero loss");
        assertEq(vault.hwmDeficit(), 0);

        // Entry is blocked: unreadable valuation => unhealthy => maxDeposit/maxMint == 0.
        assertFalse(vault.valuationHealthy(), "unreadable valuation is unhealthy");
        assertEq(vault.maxDeposit(bob), 0);
        assertEq(vault.maxMint(bob), 0);
        usdc.mint(bob, 1_000e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, bob, 1_000e6, 0));
        vault.deposit(1_000e6, bob);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxMint.selector, bob, 1e18, 0));
        vault.mint(1e18, bob);
        vm.stopPrank();
        assertEq(vault.totalAssets(), D, "rejected entry changed nothing");

        // Exits stay open at marked NAV.
        uint256 aliceShares = vault.balanceOf(alice);
        assertGt(vault.previewRedeem(aliceShares), 0);
        uint256 balBefore = usdc.balanceOf(alice);
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        vault.withdraw(1_000e6, alice, alice);
        uint256 exitGas = gasBefore - gasleft();
        assertEq(usdc.balanceOf(alice) - balBefore, 1_000e6, "withdraw pays in full");
        assertEq(vault.totalAssets(), D - 1_000e6);

        uint256 aliceQuarter = vault.balanceOf(alice) / 4;
        uint256 quote = vault.previewRedeem(aliceQuarter);
        balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 out = vault.redeem(aliceQuarter, alice, alice);
        assertEq(out, quote, "redeem pays the previewed marked-NAV amount");
        assertEq(usdc.balanceOf(alice) - balBefore, quote);

        // A single hostile adapter costs at most its stipend per NAV read.
        assertLt(exitGas, 6_000_000, "bounded exit gas");
    }

    function test_revertingAdapter_contributesNoLoss() public {
        _assertHarmless(AdapterN27.Mode.Revert);
    }

    function test_gasBurningAdapter_contributesNoLoss_andIsGasCapped() public {
        _assertHarmless(AdapterN27.Mode.GasBurn);
    }

    function test_shortReturndata_contributesNoLoss() public {
        _assertHarmless(AdapterN27.Mode.Short);
    }

    function test_oversizedReturndata_contributesNoLoss() public {
        _assertHarmless(AdapterN27.Mode.Long);
    }

    function test_returndataBomb_contributesNoLoss() public {
        _assertHarmless(AdapterN27.Mode.Bomb);
    }

    function test_emptyReturndata_contributesNoLoss() public {
        _assertHarmless(AdapterN27.Mode.Empty);
    }

    function test_hostileAdapters_doNotMaskHonestLoss() public {
        AdapterN27 c = _newScreened();
        AdapterN27 d = _newScreened();
        _fund(a, P);
        _fund(b, P);
        _fund(c, P);
        _fund(d, P);
        a.setValue(70e6); // honest loss 30
        b.setMode(AdapterN27.Mode.Revert);
        c.setMode(AdapterN27.Mode.GasBurn);
        d.setMode(AdapterN27.Mode.Long);
        assertEq(vault.unrealizedAdapterLoss(), 30e6, "only the honest reading is marked");
        assertEq(vault.totalAssets(), D - 30e6);
        assertEq(vault.maxDeposit(bob), 0, "unreadable + above-dust loss blocks entry");
        uint256 aliceTenth = vault.balanceOf(alice) / 10;
        vm.prank(alice);
        vault.redeem(aliceTenth, alice, alice);
    }

    // ───────────── recall: loss counted exactly once ─────────────

    function test_recallFull_lossCountedOnce() public {
        _fund(a, P);
        a.setValue(40e6); // loss 60
        uint256 navBefore = vault.totalAssets();
        uint256 redeemBefore = vault.previewRedeem(vault.balanceOf(alice));
        assertEq(navBefore, D - 60e6, "marked before recall");

        a.setRecall(40e6, 0);
        vm.prank(manager);
        vault.recallCapital(address(a), P);

        assertEq(vault.principalOf(address(a)), 0);
        assertEq(vault.totalDeployed(), 0);
        assertEq(vault.unrealizedAdapterLoss(), 0, "nothing left to mark");
        assertEq(vault.totalAssets(), navBefore, "realized loss == previously marked loss");
        assertEq(usdc.balanceOf(address(vault)), D - 60e6, "loss now realized in cash");
        assertEq(vault.previewRedeem(vault.balanceOf(alice)), redeemBefore, "no second deduction");
        assertEq(vault.realizedProfit(), 0);
        assertEq(vault.fundedAdapterCount(), 0);
    }

    function test_recallPartial_lossCountedOnce() public {
        _fund(a, P);
        a.setValue(40e6); // loss 60
        uint256 navBefore = vault.totalAssets();
        uint256 redeemBefore = vault.previewRedeem(vault.balanceOf(alice));

        // Recall 50 of cost; 20 comes back and 20 value remains in the adapter.
        a.setRecall(20e6, 20e6);
        vm.prank(manager);
        vault.recallCapital(address(a), 50e6);

        assertEq(vault.principalOf(address(a)), 50e6);
        assertEq(vault.totalDeployed(), 50e6);
        assertEq(vault.fundedAdapterCount(), 1);
        assertEq(vault.unrealizedAdapterLoss(), 30e6, "remaining cost 50 - remaining value 20");
        assertEq(vault.totalAssets(), navBefore, "total loss stays 60: 30 realized + 30 marked");
        assertEq(vault.previewRedeem(vault.balanceOf(alice)), redeemBefore);
    }

    // ───────────── returnCapital / writeOffAdapterPrincipal membership ─────────────

    function test_returnCapital_full_removesAdapterFromFundedSet() public {
        _fund(a, P);
        assertEq(vault.fundedAdapterCount(), 1);
        assertEq(_fundedAt(0), address(a));
        a.approveVault();
        vm.prank(manager);
        vault.returnCapital(address(a), P);
        assertEq(vault.principalOf(address(a)), 0);
        assertEq(vault.totalDeployed(), 0);
        assertEq(vault.fundedAdapterCount(), 0, "removed at zero principal");
        assertEq(vault.totalAssets(), D);
    }

    function test_returnCapital_partial_keepsAdapter_excessRemovesAndIsProfit() public {
        _fund(a, P);
        a.approveVault();
        vm.prank(manager);
        vault.returnCapital(address(a), 40e6);
        assertEq(vault.principalOf(address(a)), 60e6);
        assertEq(vault.fundedAdapterCount(), 1, "still funded");

        usdc.mint(address(a), 30e6); // adapter earned 30 beyond cost
        vm.prank(manager);
        vault.returnCapital(address(a), 90e6); // 60 cost + 30 gain
        assertEq(vault.principalOf(address(a)), 0);
        assertEq(vault.fundedAdapterCount(), 0);
        assertEq(vault.totalDeployed(), 0);
        assertEq(vault.realizedProfit(), 30e6, "only the excess over cost is profit");
    }

    function test_returnCapital_underwaterPartial_markStaysConsistent() public {
        _fund(a, P);
        a.setValue(40e6); // loss 60
        uint256 navBefore = vault.totalAssets();
        a.approveVault();
        vm.prank(manager);
        vault.returnCapital(address(a), 40e6); // all remaining value returned
        a.setValue(0);
        assertEq(vault.principalOf(address(a)), 60e6);
        assertEq(vault.unrealizedAdapterLoss(), 60e6, "unreturned cost remains marked");
        assertEq(vault.totalAssets(), navBefore);
    }

    function test_writeOff_removesAdapter_realizesLossOnce() public {
        _fund(a, P);
        a.setValue(0);
        assertEq(vault.unrealizedAdapterLoss(), P);
        uint256 navBefore = vault.totalAssets();
        vm.prank(owner);
        vault.writeOffAdapterPrincipal(address(a));
        assertEq(vault.principalOf(address(a)), 0);
        assertEq(vault.totalDeployed(), 0);
        assertEq(vault.fundedAdapterCount(), 0, "removed from fundedAdapters");
        assertEq(vault.unrealizedAdapterLoss(), 0);
        assertEq(vault.totalAssets(), navBefore, "marked loss became realized, not doubled");
        assertEq(vault.totalAssets(), D - P);
    }

    function test_writeOff_guards() public {
        _fund(a, P);
        a.setValue(40e6);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.GoldAdapterHasExposure.selector, address(a), 40e6));
        vault.writeOffAdapterPrincipal(address(a));
        a.setValue(0);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, manager));
        vault.writeOffAdapterPrincipal(address(a));
        assertEq(vault.fundedAdapterCount(), 1);
    }

    function test_removal_swapAndPopKeepsOtherAdaptersMarked() public {
        AdapterN27 c = _newScreened();
        _fund(a, P);
        _fund(b, P);
        _fund(c, P);
        assertEq(vault.fundedAdapterCount(), 3);
        a.setValue(0);
        vm.prank(owner);
        vault.writeOffAdapterPrincipal(address(a));
        assertEq(vault.fundedAdapterCount(), 2);
        assertEq(_fundedAt(0), address(c), "last element swapped into the hole");
        assertEq(_fundedAt(1), address(b));

        c.setValue(0);
        vm.prank(owner);
        vault.writeOffAdapterPrincipal(address(c));
        assertEq(vault.fundedAdapterCount(), 1);
        assertEq(_fundedAt(0), address(b));

        b.setValue(30e6);
        assertEq(vault.unrealizedAdapterLoss(), 70e6, "survivor still marked");
        assertEq(vault.totalAssets(), D - 2 * P - 70e6);
    }

    // ───────────── 10-adapter cap ─────────────

    function _eleven() internal returns (AdapterN27[] memory ads) {
        ads = new AdapterN27[](11);
        address[] memory list = new address[](11);
        for (uint256 i; i < 11; ++i) {
            ads[i] = new AdapterN27(address(vault), address(usdc));
            list[i] = address(ads[i]);
        }
        _screenBatch(list);
    }

    function test_eleventhFundedAdapter_reverts_refundingExistingDoesNot() public {
        AdapterN27[] memory ads = _eleven();
        for (uint256 i; i < 10; ++i) _fund(ads[i], 1e6);
        assertEq(vault.fundedAdapterCount(), 10);
        assertEq(vault.MAX_FUNDED_ADAPTERS(), 10);

        vm.prank(manager);
        vm.expectRevert(ShariahVault.TooManyFundedAdapters.selector);
        vault.deployCapital(address(ads[10]), 1e6, "");
        vm.prank(manager);
        vm.expectRevert(ShariahVault.TooManyFundedAdapters.selector);
        vault.deployCapitalAndExecute(address(ads[10]), 1e6, "");
        assertEq(usdc.balanceOf(address(ads[10])), 0, "revert is atomic");
        assertEq(vault.principalOf(address(ads[10])), 0);

        // Topping up an existing member is not a new slot.
        vm.prank(manager);
        vault.deployCapital(address(ads[5]), 1e6, "");
        vm.prank(manager);
        vault.deployCapitalAndExecute(address(ads[6]), 1e6, "");
        assertEq(vault.fundedAdapterCount(), 10);
        assertEq(vault.principalOf(address(ads[5])), 2e6);
        assertEq(vault.principalOf(address(ads[6])), 2e6);

        // Freeing a slot (write-off) lets the 11th in.
        ads[3].setValue(0);
        vm.prank(owner);
        vault.writeOffAdapterPrincipal(address(ads[3]));
        assertEq(vault.fundedAdapterCount(), 9);
        _fund(ads[10], 1e6);
        assertEq(vault.fundedAdapterCount(), 10);
    }

    function test_tenGasBurningAdapters_boundedGas_entryRejected_exitsOpen() public {
        AdapterN27[] memory ads = _eleven();
        for (uint256 i; i < 10; ++i) {
            _fund(ads[i], 1e6);
            ads[i].setMode(AdapterN27.Mode.GasBurn);
        }
        assertEq(vault.fundedAdapterCount(), 10);
        usdc.mint(bob, 1_000e6);

        uint256 g = gasleft();
        uint256 nav = vault.totalAssets();
        uint256 navGas = g - gasleft();
        g = gasleft();
        assertEq(vault.maxDeposit(bob), 0);
        uint256 maxDepGas = g - gasleft();
        console2.log("totalAssets gas, 10 gas burners", navGas);
        console2.log("maxDeposit gas, 10 gas burners", maxDepGas);
        assertEq(nav, D, "burners contribute zero loss");
        assertEq(vault.unrealizedAdapterLoss(), 0);
        // Each read is capped at ADAPTER_READ_GAS; NAV reads the set twice (nav + fee base) and
        // N-29's distribution cut re-reads it twice more through realizedProfit() (zero profit
        // short-circuits before the hwmDeficit/escrow reads).
        uint256 cap = vault.ADAPTER_READ_GAS();
        assertLt(navGas, 4 * 10 * cap + 600_000, "totalAssets gas bounded");
        assertLt(maxDepGas, 4 * 10 * cap + 1_000_000, "maxDeposit gas bounded");

        // Entry rejected.
        assertFalse(vault.valuationHealthy());
        assertEq(vault.maxMint(bob), 0);
        vm.startPrank(bob);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, bob, 1_000e6, 0));
        vault.deposit(1_000e6, bob);
        vm.stopPrank();

        // Exits still work and fit in a block.
        uint256 shares = vault.balanceOf(alice) / 10;
        uint256 quote = vault.previewRedeem(shares);
        g = gasleft();
        vm.prank(alice);
        uint256 out = vault.redeem(shares, alice, alice);
        uint256 used = g - gasleft();
        console2.log("redeem gas with 10 gas-burning adapters", used);
        assertEq(out, quote);
        assertLt(used, 30_000_000, "redeem must fit in a block");
    }

    // ───────────── gold-slot link removes duplicate marking ─────────────

    function test_linkFundedAdapterAsGoldAllocation_removesDuplicateMark() public {
        _fund(a, P);
        a.setValue(40e6);
        assertEq(vault.unrealizedAdapterLoss(), 60e6);
        assertEq(vault.goldWritedown(), 0);
        assertEq(vault.fundedAdapterCount(), 1);
        uint256 nav = vault.totalAssets();
        assertEq(nav, D - 60e6);

        vm.prank(owner);
        vault.setGoldAllocationAdapter(address(a));

        assertEq(vault.fundedAdapterCount(), 0, "left the non-gold set");
        assertEq(vault.unrealizedAdapterLoss(), 0);
        assertEq(vault.goldWritedown(), 60e6, "gold path now owns the mark");
        assertEq(vault.totalAssets(), nav, "loss counted exactly once");
        assertGt(vault.maxDeposit(bob), 0);
    }

    function test_linkFundedAdapterAsGoldSpread_removesDuplicateMark() public {
        _fund(a, P);
        _fund(b, P);
        a.setValue(10e6); // loss 90
        b.setValue(80e6); // loss 20
        uint256 nav = vault.totalAssets();
        assertEq(nav, D - 110e6);

        vm.prank(owner);
        vault.setGoldSpreadAdapter(address(a));

        assertEq(vault.fundedAdapterCount(), 1);
        assertEq(_fundedAt(0), address(b));
        assertEq(vault.unrealizedAdapterLoss(), 20e6);
        assertEq(vault.goldWritedown(), 90e6);
        assertEq(vault.totalAssets(), nav);
    }

    // ───────────── aggregation ─────────────

    function test_multipleAdapters_lossesSum() public {
        AdapterN27 c = _newScreened();
        _fund(a, P);
        _fund(b, P);
        _fund(c, P);
        a.setValue(60e6); // 40
        b.setValue(75e6); // 25
        c.setValue(300e6); // gain, ignored
        assertEq(vault.unrealizedAdapterLoss(), 65e6);
        assertEq(vault.totalAssets(), D - 65e6);
        b.setValue(P); // recovery of one leg
        assertEq(vault.unrealizedAdapterLoss(), 40e6);
        assertEq(vault.totalAssets(), D - 40e6);
    }

    // ───────────── Wakala fee base is the marked NAV ─────────────

    function test_wakalaFee_usesMarkedNav() public {
        _fund(a, P);
        a.setValue(0); // loss 100
        vm.prank(owner);
        treasury.setAdminFeeBps(100);
        skip(365 days);

        uint256 elapsed = block.timestamp - vault.lastFeeAccrualTime();
        uint256 marked = D - P;
        uint256 expected = marked * 100 * elapsed / (10_000 * 365 days);
        uint256 unmarked = D * 100 * elapsed / (10_000 * 365 days);
        assertEq(vault.pendingWakalaFee(), expected, "fee on marked NAV");
        assertLt(expected, unmarked);
        assertEq(vault.totalAssets(), marked - expected);

        // Under markdown (> dust) entry is closed, so the fee is booked through an exit.
        assertEq(vault.maxDeposit(bob), 0);
        uint256 priceBefore = vault.previewRedeem(1e18);
        uint256 tenth = vault.balanceOf(alice) / 10;
        uint256 quote = vault.previewRedeem(tenth);
        assertEq(treasury.pendingFees(), 0);
        vm.prank(alice);
        uint256 out = vault.redeem(tenth, alice, alice);
        assertEq(out, quote, "exit pays the marked, fee-net quote");
        assertEq(treasury.pendingFees(), expected, "booked fee equals the marked-base preview");
        assertEq(vault.pendingWakalaFee(), 0, "fee fully booked");
        assertApproxEqAbs(vault.previewRedeem(1e18), priceBefore, 2, "share price unchanged by booking");
    }

    // ───────────── fuzz ─────────────

    function _checkNav(uint256 p1, uint256 p2, uint256 v1, uint256 v2) internal {
        _fund(a, p1);
        _fund(b, p2);
        a.setValue(v1);
        b.setValue(v2);
        uint256 l1 = p1 > v1 ? p1 - v1 : 0;
        uint256 l2 = p2 > v2 ? p2 - v2 : 0;
        uint256 expected = usdc.balanceOf(address(vault)) + vault.totalDeployed() - l1 - l2;
        assertEq(vault.unrealizedAdapterLoss(), l1 + l2);
        assertEq(vault.totalAssets(), expected, "NAV == balance + deployed - sum(max(0, principal-value))");
        assertLe(vault.totalAssets(), D, "never above cost basis from marks");
        assertEq(vault.realizedProfit(), 0);
        // Pricing remains usable for every state.
        vault.previewRedeem(vault.balanceOf(alice));
        vault.previewDeposit(1e6);
    }

    function testFuzz_nav_nearPrincipal(uint256 p1, uint256 p2, uint256 v1, uint256 v2) public {
        p1 = bound(p1, 1, 400_000e6);
        p2 = bound(p2, 1, 400_000e6);
        v1 = bound(v1, 0, 2 * p1);
        v2 = bound(v2, 0, 2 * p2);
        _checkNav(p1, p2, v1, v2);
    }

    function testFuzz_nav_fullRangeValues(uint256 p1, uint256 p2, uint256 v1, uint256 v2) public {
        p1 = bound(p1, 1, 400_000e6);
        p2 = bound(p2, 1, 400_000e6);
        _checkNav(p1, p2, v1, v2);
    }
}

contract TaskN27V1Test is TaskN27Tests, TaskN27V1Fixture {}

contract TaskN27V2Test is TaskN27Tests, TaskN27V2Fixture {}
