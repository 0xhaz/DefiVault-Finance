// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// forge-config: default.fuzz.runs = 512

import {Test} from "forge-std/Test.sol";

import {PurificationEscrow} from "../PurificationEscrow.sol";
import {CharityModule}      from "../CharityModule.sol";
import {TreasuryModule}     from "../TreasuryModule.sol";
import {MockERC20}          from "../test-helpers/MockERC20.sol";

/**
 * @title  FuzzPurificationEscrow
 * @notice Fuzz / property tests for PurificationEscrow.
 *
 * Invariants checked:
 *   1. purified + charity + vaultShare + depositorShare == grossProfit ALWAYS
 *   2. When purificationBps==0, purified==0 always
 *   3. charityAmount proportional to afterPurification * charityBps / 10_000
 *   4. depositorShare >= 0 always (no negative returns)
 *
 * forge-config: default.fuzz.runs = 512
 */
contract FuzzPurificationEscrow is Test {

    // ── Shariah params ────────────────────────────────────────────────────────
    uint256 internal constant ADMIN_FEE_BPS        = 50;
    uint256 internal constant MUSHARAKAH_SHARE_BPS = 1000;
    uint256 internal constant HURDLE_RATE_BPS       = 400;

    // ── actors ────────────────────────────────────────────────────────────────
    address internal owner         = makeAddr("owner");
    address internal charityWallet = makeAddr("charityWallet");

    // ── contracts ─────────────────────────────────────────────────────────────
    MockERC20          internal usdc;
    TreasuryModule     internal treasury;
    CharityModule      internal charityModule;
    PurificationEscrow internal escrow;

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);

        // Pre-compute escrow address to wire feeSource correctly.
        // Deployment order from address(this):
        //   nonce+0 → treasury (deployed by address(this))
        //   charityModule is deployed by owner via vm.prank → does NOT consume test-contract nonce
        //   nonce+1 → escrow (deployed by address(this))
        uint256 nonce = vm.getNonce(address(this));
        address expectedEscrowAddr = vm.computeCreateAddress(address(this), nonce + 1);

        treasury = new TreasuryModule(
            "Shariah",
            expectedEscrowAddr,      // feeSource = escrow
            address(usdc),
            ADMIN_FEE_BPS,
            MUSHARAKAH_SHARE_BPS,
            HURDLE_RATE_BPS,
            owner
        );

        vm.prank(owner);
        charityModule = new CharityModule(
            charityWallet,
            address(usdc),
            expectedEscrowAddr,      // vault = escrow (escrow calls distributeCharity)
            owner,
            address(0)               // no registry for tests
        );

        escrow = new PurificationEscrow(
            address(this),           // vault = test contract
            address(usdc),
            address(charityModule),
            address(treasury),
            owner,
            address(0)               // no registry for tests
        );

        assertEq(address(escrow), expectedEscrowAddr, "escrow address mismatch");

        // Large balance for fuzz runs
        usdc.mint(address(this), type(uint128).max);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. Waterfall invariant: sum of parts always equals grossProfit
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzz_waterfall_invariant(
        uint96 grossProfit,
        uint32 elapsed,
        uint96 principal
    ) public {
        uint256 gross     = bound(uint256(grossProfit), 1e6, 100_000e6);
        uint256 elapsedSec = bound(uint256(elapsed), 0, 5 * 365 days);
        uint256 princ      = bound(uint256(principal), 1e6, 1_000_000e6);

        usdc.approve(address(escrow), gross);
        (uint256 purified, uint256 charity, uint256 vaultShare, uint256 depositorShare) =
            escrow.executeWaterfall(gross, elapsedSec, princ);

        assertEq(
            purified + charity + vaultShare + depositorShare,
            gross,
            "invariant: components must sum to grossProfit"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. purificationBps==0 → purified==0 always
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzz_purification_rate_zero_means_zero_purified(uint96 grossProfit) public {
        uint256 gross = bound(uint256(grossProfit), 1e6, 100_000e6);

        // Confirm default purificationBps is 0
        assertEq(escrow.purificationBps(), 0);

        usdc.approve(address(escrow), gross);
        (uint256 purified,,,) = escrow.executeWaterfall(gross, 365 days, 10_000e6);

        assertEq(purified, 0, "purified must be 0 when purificationBps==0");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. charityAmount proportional to afterPurification * rate / 10_000
    //    (within 1 due to integer truncation)
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzz_charityAmount_proportional(uint96 grossProfit, uint8 rateSeed) public {
        uint256 gross = bound(uint256(grossProfit), 1e6, 100_000e6);
        // Rate must be <= MAX_CHARITY_BPS (500)
        uint256 rate  = bound(uint256(rateSeed), 0, 500);

        // Set charity rate via timelock
        vm.startPrank(owner);
        charityModule.proposeCharityRateChange(rate);
        vm.warp(block.timestamp + 30 days);
        charityModule.confirmCharityRateChange();
        vm.stopPrank();

        assertEq(charityModule.charityBps(), rate);

        usdc.approve(address(escrow), gross);
        (uint256 purified, uint256 charity,,) = escrow.executeWaterfall(gross, 365 days, 10_000e6);

        uint256 afterPurification = gross - purified; // purificationBps=0 → afterPurification=gross
        uint256 expectedCharity   = (afterPurification * rate) / 10_000;

        // Integer division can differ by at most 1
        uint256 diff = charity > expectedCharity ? charity - expectedCharity : expectedCharity - charity;
        assertLe(diff, 1, "charityAmount should match rate * afterPurification / 10_000 within 1");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. depositorShare is always >= 0 (uint256 invariant — never underflows)
    //    Combined with invariant #1 this proves no component goes negative.
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzz_depositorShare_gte_zero(
        uint96 grossProfit,
        uint32 elapsed,
        uint96 principal
    ) public {
        uint256 gross      = bound(uint256(grossProfit), 1e6, 100_000e6);
        uint256 elapsedSec = bound(uint256(elapsed), 0, 5 * 365 days);
        uint256 princ      = bound(uint256(principal), 1e6, 1_000_000e6);

        usdc.approve(address(escrow), gross);
        (uint256 purified, uint256 charity, uint256 vaultShare, uint256 depositorShare) =
            escrow.executeWaterfall(gross, elapsedSec, princ);

        // uint256 cannot be negative; also assert vaultShare <= gross (no overflow)
        assertLe(vaultShare,     gross, "vaultShare must not exceed grossProfit");
        assertLe(depositorShare, gross, "depositorShare must not exceed grossProfit");
        // Redundant but explicit
        assertGe(depositorShare, 0,    "depositorShare must be >= 0");

        // Also verify the invariant holds in this run
        assertEq(purified + charity + vaultShare + depositorShare, gross,
            "invariant must hold for all inputs");
    }
}
