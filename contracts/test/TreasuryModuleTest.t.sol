// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TreasuryModule} from "../TreasuryModule.sol";

contract TreasuryModuleTest is Test {
    // Conventional treasury (no Shariah params)
    TreasuryModule internal treasury;
    // Shariah treasury (musharakah enabled)
    TreasuryModule internal shariahTreasury;

    address internal owner = makeAddr("owner");
    address internal feeSource = makeAddr("feeSource");
    address internal asset = makeAddr("asset");
    address internal receiver = makeAddr("receiver");
    address internal random = makeAddr("random");

    function setUp() public {
        // Conventional: adminFeeBps=100, musharakah=0, hurdle=0
        vm.prank(owner);
        treasury = new TreasuryModule(
            "Conventional",
            feeSource,
            asset,
            100,  // adminFeeBps
            0,    // musharakahShareBps
            0,    // hurdleRateBps
            owner
        );

        // Shariah: musharakahShareBps=1000 (10%), hurdleRateBps=400 (4%)
        vm.prank(owner);
        shariahTreasury = new TreasuryModule(
            "Shariah",
            feeSource,
            asset,
            100,  // adminFeeBps
            1000, // musharakahShareBps = 10%
            400,  // hurdleRateBps = 4%
            owner
        );
    }

    // -----------------------------------------------------------------------
    // test_conventional_accrue_and_claim
    // -----------------------------------------------------------------------
    function test_conventional_accrue_and_claim() public {
        vm.prank(feeSource);
        treasury.accrue(100e6);
        assertEq(treasury.pendingFees(), 100e6, "pendingFees should be 100e6");

        vm.prank(owner);
        treasury.claimFees(receiver, 50e6);
        assertEq(treasury.pendingFees(), 50e6, "pendingFees should be 50e6 after partial claim");
        assertEq(treasury.totalFeesCollected(), 50e6);
    }

    // -----------------------------------------------------------------------
    // test_accrue_only_fee_source
    // -----------------------------------------------------------------------
    function test_accrue_only_fee_source() public {
        vm.prank(random);
        vm.expectRevert(TreasuryModule.NotFeeSource.selector);
        treasury.accrue(100e6);
    }

    // -----------------------------------------------------------------------
    // test_claim_fees_over_pending_reverts
    // -----------------------------------------------------------------------
    function test_claim_fees_over_pending_reverts() public {
        vm.prank(feeSource);
        treasury.accrue(50e6);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(TreasuryModule.InsufficientPending.selector, 51e6, 50e6)
        );
        treasury.claimFees(receiver, 51e6);
    }

    // -----------------------------------------------------------------------
    // test_claim_fees_only_owner
    // -----------------------------------------------------------------------
    function test_claim_fees_only_owner() public {
        vm.prank(feeSource);
        treasury.accrue(100e6);

        vm.prank(random);
        vm.expectRevert();
        treasury.claimFees(receiver, 50e6);
    }

    // -----------------------------------------------------------------------
    // test_musharakah_split_calculation
    // 1-year elapsed, 10000e6 principal, 4% hurdle:
    //   hurdleAmount = 10000e6 * 400 * 365 days / (10000 * 365 days) = 400e6
    //   grossProfit = 600e6 (for a nice example)
    //   surplus = 600e6 - 400e6 = 200e6
    //   vaultShare = 200e6 * 1000 / 10000 = 20e6
    //   depositorShare = 600e6 - 20e6 = 580e6
    // -----------------------------------------------------------------------
    function test_musharakah_split_calculation() public view {
        uint256 oneYear = 365 days;
        uint256 principal = 10_000e6;
        uint256 grossProfit = 600e6;

        (uint256 hurdleAmount, uint256 vaultShare, uint256 depositorShare) =
            shariahTreasury.calculateMusharakahSplit(grossProfit, oneYear, principal);

        assertEq(hurdleAmount, 400e6, "hurdle should be 400e6");
        assertEq(vaultShare, 20e6, "vault share should be 20e6");
        assertEq(depositorShare, 580e6, "depositor share should be 580e6");
    }

    // -----------------------------------------------------------------------
    // test_musharakah_split_on_conventional_reverts
    // -----------------------------------------------------------------------
    function test_musharakah_split_on_conventional_reverts() public {
        vm.expectRevert(TreasuryModule.NotShariahTreasury.selector);
        treasury.calculateMusharakahSplit(100e6, 365 days, 1000e6);
    }

    // -----------------------------------------------------------------------
    // test_record_musharakah_profit
    // -----------------------------------------------------------------------
    function test_record_musharakah_profit() public {
        vm.prank(feeSource);
        shariahTreasury.recordMusharakahProfit(50e6);

        assertEq(shariahTreasury.pendingFees(), 50e6, "pendingFees should increase by vault share");
    }

    // -----------------------------------------------------------------------
    // test_record_musharakah_profit_conventional_reverts
    // -----------------------------------------------------------------------
    function test_record_musharakah_profit_conventional_reverts() public {
        vm.prank(feeSource);
        vm.expectRevert(TreasuryModule.NotShariahTreasury.selector);
        treasury.recordMusharakahProfit(50e6);
    }

    // -----------------------------------------------------------------------
    // test_setAdminFeeBps_max_500
    // -----------------------------------------------------------------------
    function test_setAdminFeeBps_max_500() public {
        vm.prank(owner);
        vm.expectRevert(TreasuryModule.InvalidBps.selector);
        treasury.setAdminFeeBps(501);
    }

    // -----------------------------------------------------------------------
    // test_setAdminFeeBps_valid
    // -----------------------------------------------------------------------
    function test_setAdminFeeBps_valid() public {
        vm.prank(owner);
        treasury.setAdminFeeBps(200);
        assertEq(treasury.adminFeeBps(), 200);
    }

    // -----------------------------------------------------------------------
    // test_setMusharakahParams_only_shariah
    // -----------------------------------------------------------------------
    function test_setMusharakahParams_only_shariah() public {
        vm.prank(owner);
        vm.expectRevert(TreasuryModule.NotShariahTreasury.selector);
        treasury.setMusharakahParams(500, 200);
    }

    // -----------------------------------------------------------------------
    // test_constructor_invalid_bps — adminFeeBps > 500 reverts
    // -----------------------------------------------------------------------
    function test_constructor_invalid_bps() public {
        vm.prank(owner);
        vm.expectRevert(TreasuryModule.InvalidBps.selector);
        new TreasuryModule(
            "Test",
            feeSource,
            asset,
            501, // invalid
            0,
            0,
            owner
        );
    }

    // -----------------------------------------------------------------------
    // test_constructor_invalid_musharakah_bps
    // -----------------------------------------------------------------------
    function test_constructor_invalid_musharakah_bps() public {
        vm.prank(owner);
        vm.expectRevert(TreasuryModule.InvalidBps.selector);
        new TreasuryModule(
            "Test",
            feeSource,
            asset,
            100,
            3001, // > 3000
            0,
            owner
        );
    }

    // -----------------------------------------------------------------------
    // test_getFeeDisclosure_fields
    // -----------------------------------------------------------------------
    function test_getFeeDisclosure_fields() public {
        vm.prank(feeSource);
        treasury.accrue(200e6);
        vm.prank(owner);
        treasury.claimFees(receiver, 100e6);

        TreasuryModule.FeeDisclosure memory d = treasury.getFeeDisclosure();

        assertEq(d.adminFeeBps, 100);
        assertEq(d.musharakahShareBps, 0);
        assertEq(d.hurdleRateBps, 0);
        assertEq(d.pendingFees, 100e6);
        assertEq(d.totalFeesCollected, 100e6);
        assertFalse(d.isShariahTreasury);
        assertEq(keccak256(bytes(d.treasuryType)), keccak256(bytes("Conventional")));
    }

    // -----------------------------------------------------------------------
    // test_setMusharakahParams_valid
    // -----------------------------------------------------------------------
    function test_setMusharakahParams_valid() public {
        vm.prank(owner);
        shariahTreasury.setMusharakahParams(2000, 500);
        assertEq(shariahTreasury.musharakahShareBps(), 2000);
        assertEq(shariahTreasury.hurdleRateBps(), 500);
    }

    // -----------------------------------------------------------------------
    // test_accrue_updates_totalAumAccrued
    // -----------------------------------------------------------------------
    function test_accrue_updates_totalAumAccrued() public {
        vm.prank(feeSource);
        treasury.accrue(300e6);
        assertEq(treasury.totalAumAccrued(), 300e6);
    }
}
