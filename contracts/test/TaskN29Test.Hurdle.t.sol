// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/Test.sol";

import {TaskN29Base, TaskN29V1Mixin, TaskN29V2Mixin} from "./TaskN29Test.Base.t.sol";

/// @dev N-29 review finding: the exit settlement allocates hurdle and HWM deficit by alpha = shares/supply.
///      Farming resistance, exit-sequence <= full claim, hurdle carry for stayers, alpha = 1, zero rate/deficit.
abstract contract TaskN29Hurdle is TaskN29Base {
    uint256 internal constant YEAR = 365 days;

    /// @dev Realistic chain time, so a hurdle lookback can never be clamped by forge's timestamp-1 default.
    function setUp() public virtual override {
        vm.warp(1_700_000_000);
        super.setUp();
    }

    function _maxRates() internal {
        vm.prank(address(vault));
        treasury.setMusharakahParams(3000, 2000); // max permitted: 30% share, 20%/yr hurdle
    }

    /// @dev Everything that is not a holder or the exiting manager: charity wallet, booked fees, reserved cut.
    function _sinks() internal view returns (uint256) {
        return usdc.balanceOf(charityWallet) + treasury.pendingFees() + vault.pendingDistributionCut();
    }

    function _holders() internal view returns (uint256) {
        return _value(alice) + _value(bob);
    }

    /// @dev Whole-vault hurdle allowance right now, from the vault's own hurdle inputs.
    function _hurdleNow() internal view returns (uint256) {
        return (vault.hurdlePrincipal() * treasury.hurdleRateBps() * (block.timestamp - vault.hurdleStartTime()))
            / (10_000 * YEAR);
    }

    /// @dev One second of hurdle on the post-exit principal: the carry's Ceil lookback granularity.
    function _secondOfHurdle() internal view returns (uint256) {
        return (vault.hurdlePrincipal() * treasury.hurdleRateBps()) / (10_000 * YEAR) + TOL;
    }

    /// @dev depositHurdle rescales the hurdle clock in WHOLE seconds (t' = floor(t*P/(P+A))), so one deposit can
    ///      shift the allowance by at most one second of hurdle on the post-deposit principal. The extra take that
    ///      this rounding can route to the manager/charity is therefore bounded by that second at the max rate
    ///      (20%/yr) and max manager share (30%): ceil(principal * 2000 / (10_000 * YEAR)) * 3000 / 10_000. It scales
    ///      with the principal (deposit size), not with the profit, and is a rounding-only effect.
    function _depositClockTol(uint256 principalAfter) internal pure returns (uint256) {
        uint256 secondOfHurdle = (principalAfter * 2000 + 10_000 * YEAR - 1) / (10_000 * YEAR);
        return (secondOfHurdle * 3000) / 10_000 + TOL;
    }

    // ───────────── manager-beneficiary round-trip farming ─────────────

    function _farm(uint256 y, uint256 years_, uint256 x, uint256 trips) internal {
        _maxRates();
        _fund(manager);
        skip(years_ * YEAR);
        usdc.mint(address(vault), y);
        uint256 lost;
        uint256 gained;
        for (uint256 i; i < trips; ++i) {
            uint256 h0 = _holders();
            uint256 s0 = _sinks();
            uint256 m0 = usdc.balanceOf(manager);
            uint256 secTol = _depositClockTol(vault.hurdlePrincipal() + x);
            vm.prank(manager);
            uint256 sh = vault.deposit(x, manager);
            vm.prank(manager);
            vault.redeem(sh, manager, manager);
            uint256 h1 = _holders();

            assertGe(h1 + _driftTol(h0), h0, "round trip moved value away from other holders");
            assertLe(_sinks(), s0 + _driftTol(s0) + secTol, "round trip inflated manager/charity take");
            assertLe(usdc.balanceOf(manager), m0 + TOL, "round trip paid the manager more than it put in");
            if (h0 > h1) lost += h0 - h1;
            else gained += h1 - h0;
            skip(1 days);
        }
        console2.log("holders lost (wei) over trips:", lost);
        console2.log("holders gained (wei) over trips:", gained);
        assertLe(lost, trips * TOL, "cumulative loss over all round trips is a few wei per trip");
    }

    function test_farming_managerRoundTrips_profitAboveHurdle() public {
        _farm(3_000e6, 3, 1_000e6, 20); // 3y x 20% on 2_000e6 = 1_200e6 hurdle < 3_000e6 profit
    }

    function test_farming_managerRoundTrips_profitBelowHurdle() public {
        _farm(800e6, 4, 1_000e6, 20); // 4y hurdle 1_600e6 > profit: leaver slice is partly unused
    }

    function test_farming_managerRoundTrips_largeDeposit() public {
        _farm(3_000e6, 5, 50_000e6, 20); // manager dominates the vault (alpha ~ 0.96)
    }

    /// @dev KNOWN LIMITATION (N-32, documented in docs/security-review.md): a deposit made while a large
    ///      unprocessed profit exists AND an HWM deficit is open lifts the processed per-share price above the
    ///      HWM and erases the deficit, so the reserved manager cut grows at holders' expense. This pins the
    ///      current worst case (max rates, 3 years of hurdle, unclaimed yield larger than the vault) so a
    ///      regression is visible: a single manager round trip moves < 0.5% of holders' value and the manager
    ///      never ends up with more USDC than it put in.
    function test_knownLimit_N32_depositErasesDeficit_boundedLoss() public {
        _maxRates();
        _writeHwm(1_030_000_000_000);
        assertGt(vault.hwmDeficit(), 0);
        _fund(manager);
        skip(3 * YEAR);
        usdc.mint(address(vault), 3_000e6);
        uint256 h0 = _holders();
        uint256 m0 = usdc.balanceOf(manager);
        vm.prank(manager);
        uint256 sh = vault.deposit(2_000e6, manager);
        vm.prank(manager);
        vault.redeem(sh, manager, manager);
        uint256 h1 = _holders();
        assertLe(usdc.balanceOf(manager), m0 + TOL, "manager must not profit directly");
        assertGe(h1 * 1000, h0 * 995, "known limitation: holder loss must stay below 0.5%");
    }

    /// @dev Deficit-free farming fuzz. The deficit variant is test_farming_managerRoundTrips_withDeficit (finding).
    function testFuzz_farming_managerRoundTrips(uint256 y, uint256 years_, uint256 x) public {
        y = bound(y, 1e6, 6_000e6);
        years_ = bound(years_, 1, 6);
        x = bound(x, 10e6, 60_000e6);
        _farm(y, years_, x, 4);
    }

    // ───────────── partial exits, then a final full claim ≤ one full claim ─────────────

    struct Seq {
        uint256 fullClaimTotal;
        uint256 fullClaimAlice;
    }

    /// @dev Bob leaves in steps of num_i/den_i of his remaining shares; a final full claim follows at the
    ///      same instant. Recipients (charity wallet + fees) must not exceed a single full claim.
    function _runSequence(uint256[3] memory nums, uint256[3] memory dens) internal {
        Seq memory s;
        uint256 snap = vm.snapshotState();
        _claimAll();
        s.fullClaimTotal = _distributed();
        s.fullClaimAlice = _value(alice);
        vm.revertToState(snap);

        for (uint256 i; i < 3; ++i) {
            _exitAndCheckCarry(bob, nums[i], dens[i]);
        }
        if (vault.realizedProfit() != 0) _claimAll();
        uint256 seqTotal = _distributed();
        console2.log("sequence recipients:", seqTotal);
        console2.log("single full claim  :", s.fullClaimTotal);
        assertLe(seqTotal, s.fullClaimTotal + 8 * TOL, "exit sequence + final claim pays recipients more than one claim");
        assertApproxEqAbs(_value(alice), s.fullClaimAlice, 8 * TOL + s.fullClaimAlice / 1e9, "stayer value matches a single claim");
    }

    /// @dev Exit a fraction and verify the stayers' hurdle: not consumed, start never beyond now.
    function _exitAndCheckCarry(address who, uint256 num, uint256 den) internal {
        uint256 shares = (vault.balanceOf(who) * num) / den;
        uint256 supply = vault.totalSupply();
        uint256 hBefore = _hurdleNow();
        uint256 slice = (hBefore * shares) / supply;
        uint256 g = (vault.realizedProfit() * shares) / supply;
        uint256 net = g - (g * 250) / 10_000; // purification is 0 in this fixture
        net = net > (vault.hwmDeficit() * shares) / supply ? net - (vault.hwmDeficit() * shares) / supply : 0;
        vm.prank(who);
        vault.redeem(shares, who, who);

        assertLe(vault.hurdleStartTime(), block.timestamp, "hurdleStartTime never beyond now");
        if (g == 0 || net == 0) return;
        uint256 expected = hBefore - (slice < net ? slice : net); // stayers' (1-alpha) share + unused leaver slice
        uint256 afterH = _hurdleNow();
        console2.log("carried hurdle expected / actual:", expected, afterH);
        assertGe(afterH + _secondOfHurdle(), expected, "stayers' hurdle was consumed");
        assertLe(afterH, expected + _secondOfHurdle(), "stayers' hurdle was inflated");
    }

    function test_exitSequence_thenFullClaim_noMoreThanFullClaim() public {
        _yield(200e6);
        _runSequence([uint256(1), 1, 1], [uint256(4), 3, 2]);
    }

    function test_exitSequence_maxRates_noMoreThanFullClaim() public {
        _maxRates();
        skip(2 * YEAR);
        usdc.mint(address(vault), 1_500e6);
        _runSequence([uint256(1), 1, 1], [uint256(3), 2, 2]);
    }

    function test_exitSequence_withDeficit_noMoreThanFullClaim() public {
        _yield(200e6);
        _writeHwm(1_020_000_000_000);
        assertGt(vault.hwmDeficit(), 0);
        _runSequence([uint256(1), 1, 1], [uint256(4), 3, 2]);
    }

    function testFuzz_exitSequence_noMoreThanFullClaim(
        uint256 y, uint256 d, uint256 n1, uint256 n2, uint256 shareBps, uint256 hurdleBps, uint256 hwmOn
    ) public {
        shareBps = bound(shareBps, 0, 3000);
        hurdleBps = bound(hurdleBps, 0, 2000);
        vm.prank(address(vault));
        treasury.setMusharakahParams(shareBps, hurdleBps);
        skip(bound(d, 1, 3 * 365) * 1 days);
        usdc.mint(address(vault), bound(y, 1e6, 6_000e6));
        if (hwmOn % 2 == 1) _writeHwm(1_015_000_000_000);
        _runSequence([bound(n1, 1, 9), 1, 1], [uint256(10), bound(n2, 2, 5), 2]);
    }

    // ───────────── carried hurdle: unused leaver slice stays with the stayers ─────────────

    function test_exit_unusedLeaverHurdleSlice_staysWithStayers() public {
        _yield(3e6); // leaver's net profit < her hurdle slice
        uint256 hBefore = _hurdleNow();
        uint256 shares = vault.balanceOf(bob) / 2;
        uint256 supply = vault.totalSupply();
        uint256 g = (vault.realizedProfit() * shares) / supply;
        uint256 net = g - (g * 250) / 10_000;
        uint256 slice = (hBefore * shares) / supply;
        assertLt(net, slice, "scenario: leaver cannot use its whole slice");
        vm.prank(bob);
        vault.redeem(shares, bob, bob);
        uint256 afterH = _hurdleNow();
        assertGe(afterH + _secondOfHurdle(), hBefore - net, "stayers keep (1-alpha)H plus the unused part");
        assertGt(afterH, hBefore - slice, "more than the bare (1-alpha) share");
        assertLe(vault.hurdleStartTime(), block.timestamp);
    }

    // ───────────── alpha = 1 (last holder) behaves like a full claim ─────────────

    function _lastHolderEqualsClaim(bool withDeficit) internal {
        _yield(200e6);
        _redeemFrac(bob, 1, 1); // bob leaves; alice is now the only holder
        _yield(300e6);
        if (withDeficit) _writeHwm(1_040_000_000_000);
        assertEq(vault.balanceOf(alice), vault.totalSupply());
        uint256 snap = vm.snapshotState();

        _claimAll();
        uint256 distA = _distributed();
        uint256 outA = _redeemFrac(alice, 1, 1);
        vm.revertToState(snap);

        uint256 outB = _redeemFrac(alice, 1, 1);
        assertEq(_distributed(), distA, "alpha = 1 exit routes exactly what a full claim routes");
        assertApproxEqAbs(outB, outA, TOL, "same payout as claim-then-redeem");
    }

    function test_lastHolderExit_behavesLikeFullClaim() public {
        _lastHolderEqualsClaim(false);
    }

    function test_lastHolderExit_behavesLikeFullClaim_withDeficit() public {
        _lastHolderEqualsClaim(true);
    }

    function test_lastHolderExit_behavesLikeFullClaim_maxRates() public {
        _maxRates();
        _lastHolderEqualsClaim(true);
    }

    // ───────────── zero hurdle rate / zero deficit ─────────────

    function _expectedFee(uint256 g, uint256 shares) internal view returns (uint256 fee) {
        uint256 supply = vault.totalSupply();
        uint256 net = g - (g * 250) / 10_000;
        (, fee,) = treasury.calculateMusharakahSplitHWM(
            net,
            block.timestamp - vault.hurdleStartTime(),
            (vault.hurdlePrincipal() * shares) / supply,
            (vault.hwmDeficit() * shares) / supply
        );
    }

    function test_exit_zeroHurdleRate_routesAndStayersUnchanged() public {
        vm.prank(address(vault));
        treasury.setMusharakahParams(1000, 0);
        _yield(200e6);
        _writeHwm(1_020_000_000_000);
        uint256 shares = vault.balanceOf(bob) / 2;
        uint256 expectedFee = _expectedFee((vault.realizedProfit() * shares) / vault.totalSupply(), shares);
        assertGt(expectedFee, 0);
        uint256 aliceBefore = _value(alice);
        uint256 feesBefore = treasury.pendingFees();
        vm.prank(bob);
        vault.redeem(shares, bob, bob);
        assertEq(treasury.pendingFees() - feesBefore, expectedFee, "fee on deficit-reduced profit, no hurdle");
        assertEq(vault.hurdleStartTime(), block.timestamp, "no hurdle to carry at a zero rate");
        assertApproxEqAbs(_value(alice), aliceBefore, _driftTol(aliceBefore));
    }

    function test_exit_zeroDeficit_withHurdle_routesAndStayersUnchanged() public {
        _yield(200e6);
        assertEq(vault.hwmDeficit(), 0);
        uint256 shares = vault.balanceOf(bob) / 3;
        uint256 expectedFee = _expectedFee((vault.realizedProfit() * shares) / vault.totalSupply(), shares);
        assertGt(expectedFee, 0);
        uint256 aliceBefore = _value(alice);
        uint256 feesBefore = treasury.pendingFees();
        vm.prank(bob);
        vault.redeem(shares, bob, bob);
        assertEq(treasury.pendingFees() - feesBefore, expectedFee);
        assertApproxEqAbs(_value(alice), aliceBefore, _driftTol(aliceBefore));
    }

    function test_exit_zeroRateZeroDeficit_stillSettles() public {
        vm.prank(address(vault));
        treasury.setMusharakahParams(2000, 0);
        _yield(200e6);
        uint256 shares = vault.balanceOf(bob) / 2;
        uint256 expectedFee = _expectedFee((vault.realizedProfit() * shares) / vault.totalSupply(), shares);
        uint256 aliceBefore = _value(alice);
        uint256 feesBefore = treasury.pendingFees();
        vm.prank(bob);
        vault.redeem(shares, bob, bob);
        assertEq(treasury.pendingFees() - feesBefore, expectedFee);
        assertApproxEqAbs(_value(alice), aliceBefore, _driftTol(aliceBefore));
    }
}

contract TaskN29HurdleV1Test is TaskN29Hurdle, TaskN29V1Mixin {
    function setUp() public override(TaskN29Base, TaskN29Hurdle) {
        TaskN29Hurdle.setUp();
    }
}

contract TaskN29HurdleV2Test is TaskN29Hurdle, TaskN29V2Mixin {
    function setUp() public override(TaskN29Base, TaskN29Hurdle) {
        TaskN29Hurdle.setUp();
    }
}
