// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TreasuryModule} from "../TreasuryModule.sol";

contract FuzzTreasuryModule is Test {
    TreasuryModule internal treasury;
    TreasuryModule internal shariahTreasury;

    address internal owner     = makeAddr("owner");
    address internal feeSource = makeAddr("feeSource");
    address internal asset     = makeAddr("asset");
    address internal receiver  = makeAddr("receiver");

    function setUp() public {
        vm.prank(owner);
        treasury = new TreasuryModule("Conventional", feeSource, asset, 75, 0, 0, owner);

        vm.prank(owner);
        shariahTreasury = new TreasuryModule("Shariah", feeSource, asset, 50, 1000, 400, owner);
    }

    // -----------------------------------------------------------------------
    // Fuzz: accrue any amount — pendingFees accumulates correctly
    // -----------------------------------------------------------------------
    function testFuzz_accrue_accumulates(uint96 a1, uint96 a2) public {
        uint256 amt1 = bound(a1, 0, 1e18);
        uint256 amt2 = bound(a2, 0, 1e18);

        vm.startPrank(feeSource);
        treasury.accrue(amt1);
        treasury.accrue(amt2);
        vm.stopPrank();

        assertEq(treasury.pendingFees(), amt1 + amt2);
        assertEq(treasury.totalAumAccrued(), amt1 + amt2);
    }

    // -----------------------------------------------------------------------
    // Fuzz: claimFees can never claim more than pendingFees
    // -----------------------------------------------------------------------
    function testFuzz_claimFees_never_exceeds_pending(uint96 accrued_, uint96 claim_) public {
        uint256 accrued = bound(accrued_, 1, 1e18);
        uint256 claim   = bound(claim_,   1, 2e18);

        vm.prank(feeSource);
        treasury.accrue(accrued);

        if (claim > accrued) {
            vm.prank(owner);
            vm.expectRevert(
                abi.encodeWithSelector(TreasuryModule.InsufficientPending.selector, claim, accrued)
            );
            treasury.claimFees(receiver, claim);
        } else {
            vm.prank(owner);
            treasury.claimFees(receiver, claim);
            assertEq(treasury.pendingFees(), accrued - claim);
            assertEq(treasury.totalFeesCollected(), claim);
        }
    }

    // -----------------------------------------------------------------------
    // Fuzz: adminFeeBps setter enforces 0–500 range
    // -----------------------------------------------------------------------
    function testFuzz_setAdminFeeBps_range(uint256 bps) public {
        if (bps > 500) {
            vm.prank(owner);
            vm.expectRevert(TreasuryModule.InvalidBps.selector);
            treasury.setAdminFeeBps(bps);
        } else {
            vm.prank(owner);
            treasury.setAdminFeeBps(bps);
            assertEq(treasury.adminFeeBps(), bps);
        }
    }

    // -----------------------------------------------------------------------
    // Fuzz: musharakah split math — depositorShare + vaultShare == grossProfit always
    // -----------------------------------------------------------------------
    function testFuzz_musharakah_split_conservation(
        uint96 grossProfit_,
        uint32 elapsed_,
        uint96 principal_
    ) public view {
        uint256 grossProfit = bound(grossProfit_, 0, 1_000_000e6);
        uint256 elapsed     = bound(elapsed_,     0, 10 * 365 days);
        uint256 principal   = bound(principal_,   0, 1_000_000_000e6);

        (,uint256 vaultShare, uint256 depositorShare) =
            shariahTreasury.calculateMusharakahSplit(grossProfit, elapsed, principal);

        assertEq(
            vaultShare + depositorShare,
            grossProfit,
            "vaultShare + depositorShare must always equal grossProfit"
        );
    }

    // -----------------------------------------------------------------------
    // Fuzz: vaultShare is always ≤ grossProfit (no over-extraction)
    // -----------------------------------------------------------------------
    function testFuzz_musharakah_vault_share_bounded(
        uint96 gross,
        uint32 elapsed,
        uint96 principal
    ) public view {
        uint256 grossProfit = bound(gross,     0, 1_000_000e6);
        uint256 el          = bound(elapsed,   0, 5 * 365 days);
        uint256 prin        = bound(principal, 0, 1_000_000_000e6);

        (, uint256 vaultShare,) = shariahTreasury.calculateMusharakahSplit(grossProfit, el, prin);
        assertLe(vaultShare, grossProfit, "vault share must never exceed gross profit");
    }

    // -----------------------------------------------------------------------
    // Fuzz: depositorShare is always ≥ hurdleAmount (hurdle goes to depositor, not vault)
    // -----------------------------------------------------------------------
    function testFuzz_musharakah_depositor_gets_hurdle(
        uint96 gross,
        uint32 elapsed,
        uint96 principal
    ) public view {
        uint256 grossProfit = bound(gross,     0, 1_000_000e6);
        uint256 el          = bound(elapsed,   0, 5 * 365 days);
        uint256 prin        = bound(principal, 0, 1_000_000_000e6);

        (uint256 hurdleAmt, , uint256 depositorShare) =
            shariahTreasury.calculateMusharakahSplit(grossProfit, el, prin);

        if (grossProfit >= hurdleAmt) {
            // depositorShare must include at least the hurdle portion
            assertGe(depositorShare, hurdleAmt, "depositor must receive at least hurdle amount");
        }
    }

    // -----------------------------------------------------------------------
    // Fuzz: setMusharakahParams enforces share ≤ 3000, hurdle ≤ 2000
    // -----------------------------------------------------------------------
    function testFuzz_setMusharakahParams_bounds(uint256 shareBps, uint256 hurdleBps) public {
        bool valid = shareBps <= 3_000 && hurdleBps <= 2_000;

        if (!valid) {
            vm.prank(owner);
            vm.expectRevert(TreasuryModule.InvalidBps.selector);
            shariahTreasury.setMusharakahParams(shareBps, hurdleBps);
        } else {
            vm.prank(owner);
            shariahTreasury.setMusharakahParams(shareBps, hurdleBps);
            assertEq(shariahTreasury.musharakahShareBps(), shareBps);
            assertEq(shariahTreasury.hurdleRateBps(), hurdleBps);
        }
    }

    // -----------------------------------------------------------------------
    // Fuzz: recordMusharakahProfit increments pendingFees by exact amount
    // -----------------------------------------------------------------------
    function testFuzz_recordMusharakahProfit(uint96 a1, uint96 a2) public {
        uint256 amt1 = bound(a1, 0, 1e18);
        uint256 amt2 = bound(a2, 0, 1e18);

        vm.startPrank(feeSource);
        shariahTreasury.recordMusharakahProfit(amt1);
        shariahTreasury.recordMusharakahProfit(amt2);
        vm.stopPrank();

        assertEq(shariahTreasury.pendingFees(), amt1 + amt2);
    }

    // -----------------------------------------------------------------------
    // Fuzz: constructor rejects any adminFeeBps > 500
    // -----------------------------------------------------------------------
    function testFuzz_constructor_adminBps_guard(uint256 bps) public {
        vm.assume(bps > 500 && bps < type(uint128).max);
        vm.prank(owner);
        vm.expectRevert(TreasuryModule.InvalidBps.selector);
        new TreasuryModule("T", feeSource, asset, bps, 0, 0, owner);
    }

    // -----------------------------------------------------------------------
    // Fuzz: constructor rejects musharakahShareBps > 3000
    // -----------------------------------------------------------------------
    function testFuzz_constructor_musharakahBps_guard(uint256 shareBps) public {
        vm.assume(shareBps > 3_000 && shareBps < type(uint128).max);
        vm.prank(owner);
        vm.expectRevert(TreasuryModule.InvalidBps.selector);
        new TreasuryModule("T", feeSource, asset, 50, shareBps, 0, owner);
    }
}
