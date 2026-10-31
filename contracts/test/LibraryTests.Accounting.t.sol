// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ShariahVault, ShariahAccountingLogic} from "../ShariahVault.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {LibTestBase, MockValueAdapter} from "./LibraryTests.Base.t.sol";

contract LibraryAccountingTest is LibTestBase {
    event PrincipalRetired(address indexed adapter, uint256 retired, uint256 proceeds);

    address internal ad = makeAddr("adapter");

    // ───────────────────────── retireGoldPrincipal ─────────────────────────
    function test_Retire_ZeroSoldReverts() public {
        h.setPrincipal(ad, 100);
        vm.expectRevert(ShariahVault.InvalidGoldSaleFraction.selector);
        h.retire(ad, 0, 10, 100);
    }

    function test_Retire_SoldAboveHeldReverts() public {
        h.setPrincipal(ad, 100);
        vm.expectRevert(ShariahVault.InvalidGoldSaleFraction.selector);
        h.retire(ad, 11, 10, 100);
    }

    function test_Retire_ZeroHeldReverts() public {
        vm.expectRevert(ShariahVault.InvalidGoldSaleFraction.selector);
        h.retire(ad, 0, 0, 100);
        vm.expectRevert(ShariahVault.InvalidGoldSaleFraction.selector);
        h.retire(ad, 1, 0, 100);
    }

    function test_Retire_FullSaleClearsAllPrincipal() public {
        h.setPrincipal(ad, 123_457);
        vm.expectEmit(true, false, false, true, address(h));
        emit PrincipalRetired(ad, 123_457, 0);
        uint256 newDeployed = h.retire(ad, 7, 7, 200_000);
        assertEq(h.principalOf(ad), 0);
        assertEq(newDeployed, 200_000 - 123_457);
    }

    function test_Retire_PartialRoundsDownLeavingDustInPrincipal() public {
        h.setPrincipal(ad, 10);
        // 10 * 1 / 3 = 3 (floor)
        uint256 nd = h.retire(ad, 1, 3, 10);
        assertEq(h.principalOf(ad), 7);
        assertEq(nd, 7);
    }

    function test_Retire_DeployedSaturatesAtZero() public {
        h.setPrincipal(ad, 1000);
        uint256 nd = h.retire(ad, 1, 2, 100); // retired 500 > deployed 100
        assertEq(nd, 0);
        assertEq(h.principalOf(ad), 500);
    }

    function test_Retire_DeployedEqualRetiredIsZero() public {
        h.setPrincipal(ad, 1000);
        assertEq(h.retire(ad, 1, 2, 500), 0);
    }

    function test_Retire_ZeroPrincipalRetiresNothing() public {
        vm.expectEmit(true, false, false, true, address(h));
        emit PrincipalRetired(ad, 0, 0);
        assertEq(h.retire(ad, 3, 9, 77), 77);
        assertEq(h.principalOf(ad), 0);
    }

    function test_Retire_HugeValuesNoOverflow() public {
        h.setPrincipal(ad, type(uint256).max);
        h.retire(ad, type(uint256).max - 1, type(uint256).max, type(uint256).max);
        // mulDiv(max, max-1, max) == max-1 -> remaining 1
        assertEq(h.principalOf(ad), 1);
    }

    function test_Retire_HugePrincipalFullSale() public {
        h.setPrincipal(ad, type(uint256).max);
        uint256 nd = h.retire(ad, type(uint256).max, type(uint256).max, type(uint256).max);
        assertEq(h.principalOf(ad), 0);
        assertEq(nd, 0);
    }

    // ───────────────────────── depositHurdle ─────────────────────────
    function test_DepositHurdle_ZeroSupplyStartsClockNow() public view {
        (uint256 s, uint256 p) = ShariahAccountingLogic.depositHurdle(5, 999, 0, 777, 42);
        assertEq(s, block.timestamp);
        assertEq(p, 42, "principal = just the deposit");
    }

    function test_DepositHurdle_ZeroPrincipalReseedsFromAssetsNow() public view {
        (uint256 s, uint256 p) = ShariahAccountingLogic.depositHurdle(5, 0, 10, 777, 42);
        assertEq(s, block.timestamp);
        assertEq(p, 777 + 42);
    }

    function test_DepositHurdle_PreservesAllowanceHalfDilution() public view {
        uint256 start = block.timestamp - 1000;
        (uint256 s, uint256 p) = ShariahAccountingLogic.depositHurdle(start, 100, 1, 100, 100);
        assertEq(p, 200);
        assertEq(block.timestamp - s, 500, "t' = t*P/(P+A)");
        assertEq((block.timestamp - s) * p, 1000 * 100, "allowance P*t preserved exactly");
    }

    function test_DepositHurdle_ZeroAssetsKeepsStart() public view {
        uint256 start = block.timestamp - 12345;
        (uint256 s, uint256 p) = ShariahAccountingLogic.depositHurdle(start, 1e12, 1, 1e12, 0);
        assertEq(s, start);
        assertEq(p, 1e12);
    }

    function test_DepositHurdle_FutureStartTreatedAsNoElapsed() public view {
        (uint256 s, uint256 p) = ShariahAccountingLogic.depositHurdle(block.timestamp + 5 days, 100, 1, 100, 50);
        assertEq(s, block.timestamp);
        assertEq(p, 150);
    }

    function test_DepositHurdle_StartEqualsNow() public view {
        (uint256 s,) = ShariahAccountingLogic.depositHurdle(block.timestamp, 100, 1, 100, 50);
        assertEq(s, block.timestamp);
    }

    function test_DepositHurdle_HugeElapsedAndPrincipalNoOverflow() public {
        vm.warp(type(uint64).max);
        uint256 P = type(uint128).max;
        (uint256 s, uint256 p) = ShariahAccountingLogic.depositHurdle(1, P, 1, P, P);
        assertEq(p, 2 * P);
        // elapsed = max64-1, halved
        assertEq(block.timestamp - s, (uint256(type(uint64).max) - 1) / 2);
    }

    function test_DepositHurdle_HugeAssetsDoNotUnderflowStart() public view {
        (uint256 s, uint256 p) =
            ShariahAccountingLogic.depositHurdle(block.timestamp - 1 days, 1, 1, 1, type(uint128).max);
        assertEq(s, block.timestamp, "dilution to ~0 elapsed");
        assertEq(p, uint256(type(uint128).max) + 1);
    }

    function test_DepositHurdle_PrincipalPlusAssetsOverflowReverts() public {
        vm.expectRevert();
        this.callDepositHurdle(block.timestamp - 1, type(uint256).max, 1, 1, 1);
    }

    function callDepositHurdle(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e)
        external view returns (uint256, uint256)
    {
        return ShariahAccountingLogic.depositHurdle(a, b, c, d, e);
    }

    // ───────────────────────── liquidRedeemLimit ─────────────────────────
    function _tok(uint256 bal) internal returns (MockERC20 t) {
        t = new MockERC20("T", "T", 6);
        t.mint(address(this), bal);
    }

    function test_LiquidLimit_FullyLiquidReturnsShares() public {
        MockERC20 t = _tok(1_000e6);
        assertEq(ShariahAccountingLogic.liquidRedeemLimit(address(t), 100e6, 500e6, 1_000e6), 100e6);
    }

    function test_LiquidLimit_ExactBoundaryReturnsShares() public {
        // value = shares*(assets+1)/vs = 10*(99+1)/100 = 10 == liquidity
        MockERC20 t = _tok(10);
        assertEq(ShariahAccountingLogic.liquidRedeemLimit(address(t), 10, 99, 100), 10);
    }

    function test_LiquidLimit_OneBelowBoundaryScalesDown() public {
        MockERC20 t = _tok(9);
        // floor(9*100/100) = 9 shares
        assertEq(ShariahAccountingLogic.liquidRedeemLimit(address(t), 10, 99, 100), 9);
    }

    function test_LiquidLimit_ZeroLiquidityReturnsZero() public {
        MockERC20 t = _tok(0);
        assertEq(ShariahAccountingLogic.liquidRedeemLimit(address(t), 10, 99, 100), 0);
    }

    function test_LiquidLimit_ZeroSharesReturnsZero() public {
        MockERC20 t = _tok(0);
        assertEq(ShariahAccountingLogic.liquidRedeemLimit(address(t), 0, 99, 100), 0);
    }

    function test_LiquidLimit_RoundsDownSoPayoutNeverExceedsLiquidity() public {
        MockERC20 t = _tok(7);
        uint256 lim = ShariahAccountingLogic.liquidRedeemLimit(address(t), 1_000, 2, 3);
        // floor(7*3/3)=7; payout floor(7*3/3)=7 <= 7
        assertEq(lim, 7);
        MockERC20 t2 = _tok(5);
        lim = ShariahAccountingLogic.liquidRedeemLimit(address(t2), 1_000, 10, 3); // floor(5*3/11)=1
        assertEq(lim, 1);
    }

    function test_LiquidLimit_ZeroVirtualSupplyReverts() public {
        MockERC20 t = _tok(1);
        vm.expectRevert();
        this.callLimit(address(t), 1, 1, 0);
    }

    function test_LiquidLimit_HugeValues() public {
        MockERC20 t = _tok(type(uint128).max);
        uint256 lim = ShariahAccountingLogic.liquidRedeemLimit(address(t), type(uint128).max, type(uint128).max, 1);
        assertLe(lim, type(uint128).max);
    }

    function callLimit(address t, uint256 s, uint256 a, uint256 v) external view returns (uint256) {
        return ShariahAccountingLogic.liquidRedeemLimit(t, s, a, v);
    }

    // ───────────────────────── adapter value read / loss ─────────────────────────
    function _fund(MockValueAdapter m, uint256 principal) internal {
        h.book(address(m), principal, address(0), address(0));
    }

    function test_Loss_ValidReadBelowPrincipalCountsLoss() public {
        MockValueAdapter m = _adapter(0, 60);
        _fund(m, 100);
        assertEq(h.loss(), 40);
    }

    function test_Loss_ValueAbovePrincipalIsNoLoss() public {
        MockValueAdapter m = _adapter(0, 160);
        _fund(m, 100);
        assertEq(h.loss(), 0);
    }

    function test_Loss_RevertingAdapterContributesNoLossButUnhealthy() public {
        MockValueAdapter m = _adapter(1, 0);
        _fund(m, 100);
        assertEq(h.loss(), 0);
        assertFalse(h.healthy(address(0), address(0)));
    }

    function test_Loss_ShortReturndataTreatedAsFailedRead() public {
        MockValueAdapter m = _adapter(2, 1);
        _fund(m, 100);
        assertEq(h.loss(), 0, "short data is not a 0 value");
        assertFalse(h.healthy(address(0), address(0)));
    }

    function test_Loss_LongReturndataTreatedAsFailedRead() public {
        MockValueAdapter m = _adapter(3, 1);
        _fund(m, 100);
        assertEq(h.loss(), 0);
        assertFalse(h.healthy(address(0), address(0)));
    }

    function test_Loss_EmptyReturndataAndEoaAreFailedReads() public {
        MockValueAdapter m = _adapter(5, 0);
        _fund(m, 100);
        h.book(makeAddr("eoa"), 50, address(0), address(0));
        assertEq(h.loss(), 0);
        assertFalse(h.healthy(address(0), address(0)));
    }

    function test_Loss_ReturndataBombIsFailedReadAndCheap() public {
        MockValueAdapter m = _adapter(6, 1);
        _fund(m, 100);
        uint256 g = gasleft();
        assertEq(h.loss(), 0);
        assertLt(g - gasleft(), 250_000, "bounded copy");
        assertFalse(h.healthy(address(0), address(0)));
    }

    function test_Loss_GasBurningAdapterCappedAtReadGas() public {
        MockValueAdapter m = _adapter(4, 0);
        _fund(m, 100);
        uint256 g = gasleft();
        uint256 l = h.loss();
        uint256 used = g - gasleft();
        assertEq(l, 0);
        assertLt(used, ShariahAccountingLogic.ADAPTER_READ_GAS + 60_000, "burn capped near the read cap");
        assertFalse(h.healthy(address(0), address(0)));
    }

    function test_Loss_ManyGasBurnersStillBounded() public {
        uint256 n = ShariahAccountingLogic.MAX_FUNDED_ADAPTERS;
        for (uint256 i; i < n; ++i) {
            _fund(_adapter(4, 0), 1);
        }
        uint256 g = gasleft();
        h.loss();
        assertLt(g - gasleft(), n * ShariahAccountingLogic.ADAPTER_READ_GAS + 300_000);
    }

    function test_Loss_SumsAcrossAdaptersAndSkipsFailures() public {
        _fund(_adapter(0, 10), 100);
        _fund(_adapter(1, 0), 500);
        _fund(_adapter(0, 0), 7);
        assertEq(h.loss(), 90 + 7);
    }

    function test_Healthy_LossWithinDustIsHealthyAboveIsNot() public {
        _fund(_adapter(0, 95), 100); // loss 5
        h.setDustValue(5);
        assertTrue(h.healthy(address(0), address(0)));
        h.setDustValue(4);
        assertFalse(h.healthy(address(0), address(0)));
    }

    function test_Healthy_UnreadableGoldAdapterBlocks() public {
        MockValueAdapter good = _adapter(0, 1);
        MockValueAdapter bad = _adapter(1, 0);
        assertTrue(h.healthy(address(good), address(0)));
        assertFalse(h.healthy(address(bad), address(0)));
        assertFalse(h.healthy(address(good), address(bad)));
        assertTrue(h.healthy(address(good), address(good)));
    }

    function test_GoldWritedownAndGain() public {
        MockValueAdapter spread = _adapter(0, 70);
        MockValueAdapter alloc = _adapter(0, 150);
        h.setPrincipal(address(spread), 100);
        h.setPrincipal(address(alloc), 100);
        assertEq(h.writedown(address(spread), address(alloc)), 30);
        assertEq(h.gain(address(spread), address(alloc)), 50);
        // same adapter in both slots is counted once
        assertEq(h.writedown(address(spread), address(spread)), 30);
        // unreadable contributes nothing
        MockValueAdapter bad = _adapter(2, 1);
        h.setPrincipal(address(bad), 999);
        assertEq(h.writedown(address(bad), address(0)), 0);
        assertEq(h.gain(address(bad), address(0)), 0);
    }

    // ───────────────────────── bookPrincipal / writeOff ─────────────────────────
    function test_Book_FirstFundingTracksAdapterOnce() public {
        h.book(ad, 10, address(0), address(0));
        h.book(ad, 5, address(0), address(0));
        assertEq(h.fundedLength(), 1);
        assertEq(h.principalOf(ad), 15);
        assertEq(h.fundedIndex(ad), 1);
    }

    function test_Book_ZeroAmountDoesNotTrack() public {
        h.book(ad, 0, address(0), address(0));
        assertEq(h.fundedLength(), 0);
    }

    function test_Book_GoldSlotsAreNotTracked() public {
        address spread = makeAddr("spread");
        address alloc = makeAddr("alloc");
        h.book(spread, 10, spread, alloc);
        h.book(alloc, 10, spread, alloc);
        assertEq(h.fundedLength(), 0);
        assertEq(h.principalOf(spread), 10);
        assertEq(h.principalOf(alloc), 10);
    }

    function test_Book_CapsFundedAdapters() public {
        for (uint256 i; i < ShariahAccountingLogic.MAX_FUNDED_ADAPTERS; ++i) {
            h.book(address(uint160(0x1000 + i)), 1, address(0), address(0));
        }
        vm.expectRevert(ShariahVault.TooManyFundedAdapters.selector);
        h.book(address(0x9999), 1, address(0), address(0));
        // topping up an already tracked adapter is still allowed
        h.book(address(0x1000), 1, address(0), address(0));
        assertEq(h.principalOf(address(0x1000)), 2);
    }

    function test_WriteOff_SwapAndPopKeepsIndicesConsistent() public {
        MockValueAdapter a1 = _adapter(0, 0);
        MockValueAdapter a2 = _adapter(0, 0);
        MockValueAdapter a3 = _adapter(0, 0);
        _fund(a1, 10);
        _fund(a2, 20);
        _fund(a3, 30);
        vm.expectEmit(true, false, false, true, address(h));
        emit PrincipalRetired(address(a1), 10, 0);
        assertEq(h.writeOff(address(a1)), 10);
        assertEq(h.fundedLength(), 2);
        assertEq(h.fundedIndex(address(a1)), 0);
        assertEq(h.fundedIndex(address(a3)), 1, "last moved into slot 1");
        assertEq(h.funded(0), address(a3));
        assertEq(h.funded(1), address(a2));
        assertEq(h.writeOff(address(a3)), 30);
        assertEq(h.funded(0), address(a2));
        assertEq(h.fundedIndex(address(a2)), 1);
    }

    function test_WriteOff_RevertsWhenAdapterStillHasValue() public {
        MockValueAdapter m = _adapter(0, 5);
        _fund(m, 10);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.GoldAdapterHasExposure.selector, address(m), uint256(5)));
        h.writeOff(address(m));
    }

    function test_WriteOff_UnreadableAdapterCanBeWrittenOff() public {
        MockValueAdapter m = _adapter(4, 0);
        _fund(m, 10);
        assertEq(h.writeOff(address(m)), 10);
        assertEq(h.principalOf(address(m)), 0);
        assertEq(h.fundedLength(), 0);
    }
}
