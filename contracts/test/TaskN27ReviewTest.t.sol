// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {ShariahVault} from "../ShariahVault.sol";
import {AdapterN27, TaskN27Base, TaskN27V1Fixture, TaskN27V2Fixture} from "./TaskN27Test.Base.t.sol";

/// @dev Post-security-review behaviour: valuationHealthy() gates entry only; exits stay open at marked NAV.
///      Run against V1 and V2 below.
abstract contract TaskN27ReviewTests is TaskN27Base {
    uint256 internal constant DUST = 1e6; // dustThreshold default == effectiveDustThreshold at this NAV

    function _blockedEntry() internal {
        assertFalse(vault.valuationHealthy(), "unhealthy");
        assertEq(vault.maxDeposit(bob), 0, "maxDeposit==0");
        assertEq(vault.maxMint(bob), 0, "maxMint==0");
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, bob, 1_000e6, 0));
        vault.deposit(1_000e6, bob);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxMint.selector, bob, 1e18, 0));
        vault.mint(1e18, bob);
        vm.stopPrank();
        assertEq(vault.balanceOf(bob), 0, "no cheap shares");
    }

    function _bobFunds() internal {
        usdc.mint(bob, 10_000e6);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _exitsWork(uint256 assetsOut) internal {
        uint256 shares = vault.balanceOf(alice) / 10;
        uint256 quote = vault.previewRedeem(shares);
        assertGt(quote, 0);
        uint256 bal = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 out = vault.redeem(shares, alice, alice);
        assertEq(out, quote, "redeem == preview");
        assertEq(usdc.balanceOf(alice) - bal, quote);
        bal = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(assetsOut, alice, alice);
        assertEq(usdc.balanceOf(alice) - bal, assetsOut, "withdraw pays in full");
    }

    // ───────────── oscillation attack ─────────────

    function test_oscillation_zeroThenRestore_attackClosed() public {
        _fund(a, P);
        _bobFunds();
        uint256 quoteBefore = vault.previewDeposit(1_000e6);

        a.setValue(0); // adapter transiently reports 0 -> NAV marked down by P
        assertEq(vault.unrealizedAdapterLoss(), P);
        assertEq(vault.totalAssets(), D - P);
        assertGt(vault.previewDeposit(1_000e6), quoteBefore, "control: marked price WOULD be cheap");
        _blockedEntry(); // attacker deposit attempt during the 0 period reverts

        a.setValue(P); // honest recovery
        assertTrue(vault.valuationHealthy(), "healthy again");
        assertGt(vault.maxDeposit(bob), 0);
        assertGt(vault.maxMint(bob), 0);
        assertEq(vault.totalAssets(), D);
        vm.prank(bob);
        uint256 minted = vault.deposit(1_000e6, bob);
        assertEq(minted, quoteBefore, "entry at the honest price only");
        assertApproxEqAbs(vault.previewRedeem(vault.balanceOf(alice)), D, 2, "alice not diluted");
        assertApproxEqAbs(vault.previewRedeem(minted), 1_000e6, 2, "bob gained nothing");
    }

    function test_oscillation_revertThenRestore_attackClosed() public {
        _fund(a, P);
        _bobFunds();
        uint256 quoteBefore = vault.previewDeposit(1_000e6);
        a.setMode(AdapterN27.Mode.Revert);
        _blockedEntry();
        a.setMode(AdapterN27.Mode.Normal);
        assertTrue(vault.valuationHealthy());
        vm.prank(bob);
        assertEq(vault.deposit(1_000e6, bob), quoteBefore);
        vm.prank(bob);
        assertGt(vault.mint(1e12, bob), 0); // 1e12 shares ~ 1 USDC
    }

    // ───────────── dust threshold boundary ─────────────

    function test_smallLoss_withinDust_keepsDepositsOpen() public {
        assertEq(vault.effectiveDustThreshold(), DUST);
        _fund(a, P);
        _bobFunds();
        a.setValue(P - DUST); // loss == threshold
        assertEq(vault.unrealizedAdapterLoss(), DUST);
        assertTrue(vault.valuationHealthy(), "loss <= dust is healthy");
        assertGt(vault.maxDeposit(bob), 0);
        assertGt(vault.maxMint(bob), 0);
        vm.prank(bob);
        uint256 minted = vault.deposit(1_000e6, bob);
        assertGt(minted, 0);
        vm.prank(bob);
        assertGt(vault.mint(1e12, bob), 0); // 1e12 shares ~ 1 USDC

        a.setValue(P - DUST - 1); // one wei above the threshold
        assertFalse(vault.valuationHealthy());
        assertEq(vault.maxDeposit(bob), 0);
        assertEq(vault.maxMint(bob), 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, bob, 1e6, 0));
        vault.deposit(1e6, bob);
        // Exits remain open at marked NAV.
        uint256 shares = vault.balanceOf(bob);
        uint256 quote = vault.previewRedeem(shares);
        vm.prank(bob);
        assertEq(vault.redeem(shares, bob, bob), quote);
    }

    function test_largeAboveDustLoss_blocksEntry_exitsOpen() public {
        _fund(a, P);
        a.setValue(P - 2 * DUST);
        _blockedEntry();
        _exitsWork(1_000e6);
    }

    // ───────────── reverting gold adapter ─────────────

    function _linkGold(AdapterN27 g, bool spread) internal {
        _fund(g, P);
        vm.prank(owner);
        if (spread) vault.setGoldSpreadAdapter(address(g));
        else vault.setGoldAllocationAdapter(address(g));
        assertEq(vault.fundedAdapterCount(), 0, "moved out of the non-gold set");
        assertEq(vault.principalOf(address(g)), P, "principal kept");
    }

    function _goldRevertDoesNotFreezeExits(bool spread) internal {
        _linkGold(a, spread);
        _bobFunds();
        assertTrue(vault.valuationHealthy());
        uint256 nav = vault.totalAssets();
        assertEq(nav, D);

        uint256 snap = vm.snapshotState();
        for (uint256 m = 1; m <= uint256(AdapterN27.Mode.Empty); ++m) {
            a.setMode(AdapterN27.Mode(m));
            uint256 g = gasleft();
            uint256 navNow = vault.totalAssets();
            // Measured (N-33): one totalAssets() reads a linked gold slot 7 times, each capped at ADAPTER_READ_GAS.
            assertLt(g - gasleft(), 7 * vault.ADAPTER_READ_GAS() + 400_000, "bounded NAV gas");
            assertEq(navNow, D, "no writedown/gain from an unreadable gold read");
            assertEq(vault.goldWritedown(), 0);
            assertEq(vault.goldUnrealizedGain(), 0);
            _blockedEntry();
            _exitsWork(500e6);
            vm.revertToState(snap);
            snap = vm.snapshotState();
        }
    }

    function test_revertingGoldAllocation_doesNotFreezeExits_blocksEntry() public {
        _goldRevertDoesNotFreezeExits(false);
    }

    function test_revertingGoldSpread_doesNotFreezeExits_blocksEntry() public {
        _goldRevertDoesNotFreezeExits(true);
    }

    function test_goldAdapter_readableLossAndGain_stillMarked() public {
        _linkGold(a, false);
        a.setValue(P - 30e6);
        assertEq(vault.goldWritedown(), 30e6);
        assertEq(vault.totalAssets(), D - 30e6);
        a.setValue(P + 20e6);
        assertEq(vault.goldWritedown(), 0);
        assertEq(vault.goldUnrealizedGain(), 20e6);
        assertTrue(vault.valuationHealthy());
    }

    // ───────────── broken gold adapter removal ─────────────

    function _removeBrokenGold(bool spread, bool replaceWithNew) internal {
        _linkGold(a, spread);
        AdapterN27 c = _newScreened();
        a.setMode(AdapterN27.Mode.Revert);
        address replacement = replaceWithNew ? address(c) : address(0);

        // Without reconciling principal the swap is refused (unreadable => treated as full exposure).
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.GoldAdapterHasExposure.selector, address(a), P));
        if (spread) vault.setGoldSpreadAdapter(replacement);
        else vault.setGoldAllocationAdapter(replacement);

        assertEq(vault.totalDeployed(), P);
        vm.prank(owner);
        vault.writeOffAdapterPrincipal(address(a)); // accepts unreadable valuation
        assertEq(vault.principalOf(address(a)), 0, "principal reconciled");
        assertEq(vault.totalDeployed(), 0, "totalDeployed reconciled");
        assertEq(vault.totalAssets(), D - P, "loss realized once");

        vm.prank(owner);
        if (spread) vault.setGoldSpreadAdapter(replacement);
        else vault.setGoldAllocationAdapter(replacement);

        assertEq(spread ? vault.goldSpreadAdapter() : vault.goldAllocationAdapter(), replacement);
        assertTrue(vault.retiredGoldAdapter(address(a)), "old adapter retired");
        assertEq(vault.principalOf(address(a)), 0);
        assertEq(vault.totalDeployed(), 0);
        assertEq(vault.totalAssets(), D - P);
        assertTrue(vault.valuationHealthy(), "entry reopens once the broken gold slot is gone");
        assertGt(vault.maxDeposit(bob), 0);
        _bobFunds();
        vm.prank(bob);
        assertGt(vault.deposit(1_000e6, bob), 0);
    }

    function test_brokenGoldAllocation_writeOffThenUnlink() public {
        _removeBrokenGold(false, false);
    }

    function test_brokenGoldAllocation_writeOffThenReplace() public {
        _removeBrokenGold(false, true);
    }

    function test_brokenGoldSpread_writeOffThenUnlink() public {
        _removeBrokenGold(true, false);
    }

    function test_brokenGoldSpread_writeOffThenReplace() public {
        _removeBrokenGold(true, true);
    }

    // ───────────── recall with unreadable post-recall valuation ─────────────

    function test_recall_unreadableValuation_fullRecovery_retiresPrincipal() public {
        _fund(a, P);
        a.setRecall(P, 0);
        a.setMode(AdapterN27.Mode.Revert);
        uint256 balBefore = usdc.balanceOf(address(vault));

        vm.expectEmit(true, false, false, true, address(vault));
        emit ShariahVault.PrincipalRetired(address(a), P, P);
        vm.prank(manager);
        vault.recallCapital(address(a), P);

        assertEq(usdc.balanceOf(address(vault)) - balBefore, P, "recovered USDC kept");
        assertEq(vault.principalOf(address(a)), 0, "principal retired");
        assertEq(vault.totalDeployed(), 0);
        assertEq(vault.fundedAdapterCount(), 0);
        assertEq(vault.totalAssets(), D);
        assertTrue(vault.valuationHealthy(), "unreadable adapter is gone from the set");
    }

    function test_recall_unreadableValuation_partialRecovery_noInferredLoss() public {
        _fund(a, P);
        a.setRecall(30e6, 70e6);
        a.setMode(AdapterN27.Mode.GasBurn);

        vm.prank(manager);
        vault.recallCapital(address(a), P); // asked for all, only 30 measured back

        assertEq(vault.principalOf(address(a)), 70e6, "only measured recovery retires principal");
        assertEq(vault.totalDeployed(), 70e6);
        assertEq(vault.fundedAdapterCount(), 1, "still tracked");
        assertEq(vault.totalAssets(), D, "no loss inferred from unreadable valuation");
        assertEq(usdc.balanceOf(address(vault)), D - P + 30e6);
        assertFalse(vault.valuationHealthy(), "still unreadable -> entry blocked");
        _exitsWork(500e6);
    }

    function test_recall_readableZeroValue_closesWholePosition() public {
        _fund(a, P);
        a.setRecall(40e6, 0);
        vm.prank(manager);
        vault.recallCapital(address(a), 40e6);
        assertEq(vault.principalOf(address(a)), 0, "readable zero value => position closed");
        assertEq(vault.fundedAdapterCount(), 0);
        assertEq(vault.totalAssets(), D - 60e6);
    }

    // ───────────── writeOff of a reverting adapter ─────────────

    function test_writeOff_unreadableAdapter_removedFromFundedSet() public {
        AdapterN27 c = _newScreened();
        _fund(a, P);
        _fund(b, P);
        _fund(c, P);
        assertEq(vault.fundedAdapterCount(), 3);

        uint256 snap = vm.snapshotState();
        for (uint256 m = 1; m <= uint256(AdapterN27.Mode.Empty); ++m) {
            a.setMode(AdapterN27.Mode(m));
            assertFalse(vault.valuationHealthy());
            assertEq(vault.totalAssets(), D, "unreadable => unmarked");

            vm.expectEmit(true, false, false, true, address(vault));
            emit ShariahVault.PrincipalRetired(address(a), P, 0);
            vm.prank(owner);
            vault.writeOffAdapterPrincipal(address(a));

            assertEq(vault.principalOf(address(a)), 0);
            assertEq(vault.totalDeployed(), 2 * P);
            assertEq(vault.fundedAdapterCount(), 2, "removed from funded set");
            assertEq(_fundedAt(0), address(c), "swap-and-pop");
            assertEq(_fundedAt(1), address(b));
            assertEq(vault.totalAssets(), D - P, "loss realized once");
            assertTrue(vault.valuationHealthy(), "entry reopens");
            assertGt(vault.maxDeposit(bob), 0);
            vm.revertToState(snap);
            snap = vm.snapshotState();
        }
    }

    function test_writeOff_readableNonZero_stillRefused_onlyOwner() public {
        _fund(a, P);
        a.setValue(1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.GoldAdapterHasExposure.selector, address(a), 1));
        vault.writeOffAdapterPrincipal(address(a));
        assertEq(vault.fundedAdapterCount(), 1);
    }

    // ───────────── valuationHealthy aggregates every tracked adapter ─────────────

    function test_valuationHealthy_anyOneFailedReadBlocks() public {
        _fund(a, P);
        _fund(b, P);
        assertTrue(vault.valuationHealthy());
        b.setMode(AdapterN27.Mode.Bomb);
        assertFalse(vault.valuationHealthy());
        assertEq(vault.maxDeposit(alice), 0);
        b.setMode(AdapterN27.Mode.Normal);
        assertTrue(vault.valuationHealthy());
        // Losses sum across adapters against one threshold.
        a.setValue(P - DUST / 2);
        b.setValue(P - DUST / 2);
        assertTrue(vault.valuationHealthy(), "sum == threshold");
        b.setValue(P - DUST / 2 - 1);
        assertFalse(vault.valuationHealthy(), "sum above threshold");
    }
}

contract TaskN27ReviewV1Test is TaskN27ReviewTests, TaskN27V1Fixture {}

contract TaskN27ReviewV2Test is TaskN27ReviewTests, TaskN27V2Fixture {}
