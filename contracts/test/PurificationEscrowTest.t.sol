// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test}     from "forge-std/Test.sol";
import {IERC20}   from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable}  from "@openzeppelin/contracts/access/Ownable.sol";

import {PurificationEscrow} from "../PurificationEscrow.sol";
import {CharityModule}      from "../CharityModule.sol";
import {TreasuryModule}     from "../TreasuryModule.sol";
import {ShariahVault}       from "../ShariahVault.sol";
import {MockERC20}          from "../test-helpers/MockERC20.sol";

/**
 * @title  PurificationEscrowTest
 * @notice Unit tests for PurificationEscrow — 15+ tests covering the waterfall,
 *         purification rate controls, and ShariahVault integration.
 *
 * ── Deployment topology ────────────────────────────────────────────────────
 *
 *  MockERC20 (USDC, 6 dec)
 *  TreasuryModule  ← feeSource = address(escrow)  (set in setUp after escrow is known)
 *  CharityModule   ← vault = address(this),  owner = owner
 *  PurificationEscrow ← vault = address(this), feeSource = escrow itself
 *
 * For ShariahVault integration sub-tests we deploy a second set wired together.
 *
 * address(this) acts as the "vault" for standalone escrow calls.
 * We approve escrow for grossProfit before each executeWaterfall call.
 */
contract PurificationEscrowTest is Test {

    // ── Shariah params ────────────────────────────────────────────────────────
    uint256 internal constant ADMIN_FEE_BPS       = 50;   // 0.5%
    uint256 internal constant MUSHARAKAH_SHARE_BPS = 1000; // 10%
    uint256 internal constant HURDLE_RATE_BPS      = 400;  // 4%

    // ── actors ────────────────────────────────────────────────────────────────
    address internal owner         = makeAddr("owner");
    address internal charityWallet = makeAddr("charityWallet");
    address internal other         = makeAddr("other");

    // ── CCTP domain ───────────────────────────────────────────────────────────
    uint32 internal constant SOURCE_DOMAIN = 26;

    // ── contracts (standalone waterfall tests — vault = address(this)) ────────
    MockERC20          internal usdc;
    TreasuryModule     internal treasury;
    CharityModule      internal charityModule;
    PurificationEscrow internal escrow;

    // ── contracts (ShariahVault integration tests) ────────────────────────────
    TreasuryModule     internal vaultTreasury;
    CharityModule      internal vaultCharityModule;
    PurificationEscrow internal vaultEscrow;
    ShariahVault       internal vault;

    function setUp() public {
        // ── 1. Shared MockERC20 ──────────────────────────────────────────────
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);

        // ── 2. Standalone stack (vault = address(this)) ──────────────────────
        // CharityModule: vault = address(this), owner = owner
        vm.prank(owner);
        charityModule = new CharityModule(
            charityWallet,
            address(usdc),
            address(this), // vault for CharityModule — will be overridden to escrow below
            owner
        );

        // TreasuryModule placeholder — feeSource must be escrow, deployed next.
        // Use a two-step: deploy treasury with feeSource = address(this), then deploy
        // escrow; treasury's feeSource is immutable so we deploy it with the CORRECT
        // feeSource address. We compute escrow address deterministically using CREATE.
        // Simpler approach: deploy treasury with feeSource = address(this), let
        // escrow use address(this) to call recordMusharakahProfit by pranking.
        //
        // Actually the cleanest approach for unit tests:
        // • Deploy treasury with feeSource = address(this) (test contract).
        // • Deploy CharityModule with vault = address(this).
        // • Deploy PurificationEscrow with vault = address(this).
        // • In executeWaterfall, escrow calls treasury.recordMusharakahProfit —
        //   BUT feeSource=address(this) so that call will revert with NotFeeSource.
        //
        // Correct fix: feeSource must = address(escrow).
        // We pre-compute the escrow address with vm.computeCreateAddress:

        uint256 deployerNonce = vm.getNonce(address(this));
        // CharityModule was just deployed (nonce consumed), treasury is next (+0),
        // then escrow (+1).
        address expectedTreasuryAddr = vm.computeCreateAddress(address(this), deployerNonce);
        address expectedEscrowAddr   = vm.computeCreateAddress(address(this), deployerNonce + 1);

        treasury = new TreasuryModule(
            "Shariah",
            expectedEscrowAddr,  // feeSource = escrow (pre-computed)
            address(usdc),
            ADMIN_FEE_BPS,
            MUSHARAKAH_SHARE_BPS,
            HURDLE_RATE_BPS,
            owner
        );

        // CharityModule vault must also be the escrow so distributeCharity can be called by escrow.
        // Re-deploy charityModule with vault = expectedEscrowAddr.
        vm.prank(owner);
        charityModule = new CharityModule(
            charityWallet,
            address(usdc),
            expectedEscrowAddr,  // vault = escrow
            owner
        );

        escrow = new PurificationEscrow(
            address(this),    // vault = test contract
            address(usdc),
            address(charityModule),
            address(treasury),
            owner
        );

        // Sanity: confirm addresses match
        assertEq(address(escrow),  expectedEscrowAddr,  "escrow address mismatch - adjust nonce offset");

        // Fund test contract (acting as vault)
        usdc.mint(address(this), 10_000_000e6);

        // ── 3. ShariahVault integration stack ────────────────────────────────
        vm.startPrank(owner);

        vaultTreasury = new TreasuryModule(
            "ShariahV2",
            address(0), // placeholder — will be replaced below
            address(usdc),
            ADMIN_FEE_BPS,
            MUSHARAKAH_SHARE_BPS,
            HURDLE_RATE_BPS,
            owner
        );

        vault = new ShariahVault(
            IERC20(address(usdc)),
            owner,
            SOURCE_DOMAIN,
            address(vaultTreasury),
            address(0) // no ZakatModule
        );

        vaultCharityModule = new CharityModule(
            charityWallet,
            address(usdc),
            address(0), // placeholder — will be the vaultEscrow address
            owner
        );

        vm.stopPrank();

        // Pre-compute vaultEscrow address
        uint256 vaultEscrowNonce = vm.getNonce(address(this));
        address expectedVaultEscrowAddr = vm.computeCreateAddress(address(this), vaultEscrowNonce);

        // Re-deploy vaultTreasury and vaultCharityModule with correct feeSource/vault addresses
        vm.startPrank(owner);

        vaultTreasury = new TreasuryModule(
            "ShariahV2",
            expectedVaultEscrowAddr,  // feeSource = vaultEscrow
            address(usdc),
            ADMIN_FEE_BPS,
            MUSHARAKAH_SHARE_BPS,
            HURDLE_RATE_BPS,
            owner
        );

        vaultCharityModule = new CharityModule(
            charityWallet,
            address(usdc),
            expectedVaultEscrowAddr,  // vault = vaultEscrow (escrow calls distributeCharity)
            owner
        );

        vm.stopPrank();

        // Re-compute after the two re-deploys
        uint256 vaultEscrowNonce2 = vm.getNonce(address(this));
        address expectedVaultEscrowAddr2 = vm.computeCreateAddress(address(this), vaultEscrowNonce2);

        vaultEscrow = new PurificationEscrow(
            address(vault),
            address(usdc),
            address(vaultCharityModule),
            address(vaultTreasury),
            owner
        );

        assertEq(address(vaultEscrow), expectedVaultEscrowAddr2, "vaultEscrow address mismatch");

        // Wire vault → escrow and fund vault
        vm.prank(owner);
        vault.setPurificationEscrow(address(vaultEscrow));

        usdc.mint(address(vault), 10_000_000e6);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. Waterfall invariant: purified + charity + vaultShare + depositorShare == grossProfit
    // ─────────────────────────────────────────────────────────────────────────
    function test_waterfall_invariant() public {
        uint256 gross     = 1_000e6;
        uint256 elapsed   = 365 days;
        uint256 principal = 10_000e6;

        usdc.approve(address(escrow), gross);
        (uint256 purified, uint256 charity, uint256 vaultShare, uint256 depositorShare) =
            escrow.executeWaterfall(gross, elapsed, principal);

        assertEq(
            purified + charity + vaultShare + depositorShare,
            gross,
            "waterfall invariant: components must sum to grossProfit"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. purificationBps=0 → purified==0, charity==25e6 (2.5% of 1000e6)
    // ─────────────────────────────────────────────────────────────────────────
    function test_waterfall_zero_purification() public {
        // Default purificationBps is 0
        assertEq(escrow.purificationBps(), 0);

        uint256 gross = 1_000e6;
        usdc.approve(address(escrow), gross);
        (uint256 purified, uint256 charity,,) = escrow.executeWaterfall(gross, 365 days, 10_000e6);

        assertEq(purified, 0,    "purified should be 0 when purificationBps=0");
        assertEq(charity,  25e6, "charity should be 2.5% of full gross when purification=0");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. setPurificationBps(100) → purified==10e6 from 1000e6
    // ─────────────────────────────────────────────────────────────────────────
    function test_waterfall_with_purification() public {
        vm.prank(owner);
        escrow.setPurificationBps(100); // 1%

        uint256 gross = 1_000e6;
        usdc.approve(address(escrow), gross);
        (uint256 purified, uint256 charity,,) = escrow.executeWaterfall(gross, 365 days, 10_000e6);

        // purified = 1000e6 * 100 / 10_000 = 10e6
        assertEq(purified, 10e6, "purified should be 1% of grossProfit");

        // charity = (1000e6 - 10e6) * 250 / 10_000 = 990e6 * 250 / 10_000 = 24.75e6
        uint256 afterPurification = gross - purified;
        uint256 expectedCharity   = (afterPurification * 250) / 10_000;
        assertEq(charity, expectedCharity, "charity should be 2.5% of afterPurification");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. Non-vault caller reverts NotVault
    // ─────────────────────────────────────────────────────────────────────────
    function test_waterfall_not_vault_reverts() public {
        vm.prank(other);
        vm.expectRevert(PurificationEscrow.NotVault.selector);
        escrow.executeWaterfall(1_000e6, 365 days, 10_000e6);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 5. grossProfit==0 reverts ZeroAmount
    // ─────────────────────────────────────────────────────────────────────────
    function test_waterfall_zero_amount_reverts() public {
        vm.expectRevert(PurificationEscrow.ZeroAmount.selector);
        escrow.executeWaterfall(0, 365 days, 10_000e6);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 6. WaterfallExecuted event emitted with correct params
    // ─────────────────────────────────────────────────────────────────────────
    function test_waterfall_emits_event() public {
        uint256 gross     = 1_000e6;
        uint256 elapsed   = 365 days;
        uint256 principal = 10_000e6;

        usdc.approve(address(escrow), gross);

        // Pre-compute expected values
        uint256 purified = 0; // purificationBps = 0
        uint256 afterPurification = gross;
        uint256 expectedCharity   = (afterPurification * 250) / 10_000; // 25e6
        uint256 afterCharity      = afterPurification - expectedCharity;

        (uint256 hurdleAmt, uint256 expectedVaultShare, uint256 expectedDepositorShare) =
            treasury.calculateMusharakahSplit(afterCharity, elapsed, principal);
        (hurdleAmt); // suppress unused warning

        vm.expectEmit(false, false, false, true, address(escrow));
        emit PurificationEscrow.WaterfallExecuted(
            gross,
            purified,
            expectedCharity,
            expectedVaultShare,
            expectedDepositorShare
        );

        escrow.executeWaterfall(gross, elapsed, principal);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 7. setPurificationBps above cap reverts PurificationAboveCap
    // ─────────────────────────────────────────────────────────────────────────
    function test_setPurificationBps_above_cap_reverts() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(PurificationEscrow.PurificationAboveCap.selector, 1001, 1000)
        );
        escrow.setPurificationBps(1001);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 8. CombinedDeductionAboveCap is checked in executeWaterfall runtime guard.
    //    Individual caps on setPurificationBps (<=1000) and charityBps (<=500)
    //    make combined<=1500 in normal operation, so the setPurificationBps path
    //    cannot reach the combined cap. We test the executeWaterfall guard by
    //    directly writing purificationBps to a high value via vm.store, bypassing
    //    the setter cap, then confirming executeWaterfall reverts.
    // ─────────────────────────────────────────────────────────────────────────
    function test_setPurificationBps_combined_above_cap_reverts() public {
        // Raise charityBps to 500 via 30-day timelock
        vm.startPrank(owner);
        charityModule.proposeCharityRateChange(500);
        vm.warp(block.timestamp + 30 days);
        charityModule.confirmCharityRateChange();
        vm.stopPrank();
        assertEq(charityModule.charityBps(), 500, "charityBps should be 500");

        // Write purificationBps = 4501 directly (slot 2 of PurificationEscrow storage:
        //   slot 0 = _owner, slot 1 = _pendingOwner, slot 2 = purificationBps)
        // Combined = 4501 + 500 = 5001 > 5000 → CombinedDeductionAboveCap
        vm.store(address(escrow), bytes32(uint256(2)), bytes32(uint256(4501)));
        assertEq(escrow.purificationBps(), 4501, "purificationBps should be 4501 via store");

        uint256 gross = 1_000e6;
        usdc.approve(address(escrow), gross);

        vm.expectRevert(
            abi.encodeWithSelector(
                PurificationEscrow.CombinedDeductionAboveCap.selector,
                5001,
                5000
            )
        );
        escrow.executeWaterfall(gross, 365 days, 10_000e6);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 9. Non-owner cannot call setPurificationBps
    // ─────────────────────────────────────────────────────────────────────────
    function test_setPurificationBps_nonOwner_reverts() public {
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other)
        );
        escrow.setPurificationBps(100);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 10. charityWallet receives correct purification amount directly
    // ─────────────────────────────────────────────────────────────────────────
    function test_charityWallet_receives_correct_purification() public {
        vm.prank(owner);
        escrow.setPurificationBps(200); // 2%

        uint256 gross = 1_000e6;
        usdc.approve(address(escrow), gross);

        uint256 balanceBefore = usdc.balanceOf(charityWallet);
        (uint256 purified,,,) = escrow.executeWaterfall(gross, 365 days, 10_000e6);

        // purified = 1000e6 * 200 / 10_000 = 20e6
        assertEq(purified, 20e6, "purified should be 2% of gross");

        // charityWallet receives purification directly PLUS charity via CharityModule
        // But the purification portion goes directly to charityWallet
        uint256 balanceAfterWaterfall = usdc.balanceOf(charityWallet);
        // The total increase includes both purification (direct) and charity (via CharityModule)
        // We check that balance increased by at least the purification amount
        assertGe(
            balanceAfterWaterfall - balanceBefore,
            purified,
            "charityWallet should receive at least the purification amount"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 11. CharityModule.totalCharityDistributed == 25e6 when purificationBps=0
    // ─────────────────────────────────────────────────────────────────────────
    function test_charityModule_receives_correct_charity() public {
        // purificationBps = 0 (default), so afterPurification = gross = 1000e6
        // charity = 1000e6 * 250 / 10_000 = 25e6
        uint256 gross = 1_000e6;
        usdc.approve(address(escrow), gross);
        escrow.executeWaterfall(gross, 365 days, 10_000e6);

        assertEq(
            charityModule.totalCharityDistributed(),
            25e6,
            "totalCharityDistributed should be 25e6 (2.5% of 1000e6)"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 12. depositorShare is returned to vault (test contract's balance increases)
    // ─────────────────────────────────────────────────────────────────────────
    function test_depositorShare_returned_to_vault() public {
        uint256 gross = 1_000e6;
        usdc.approve(address(escrow), gross);

        uint256 balanceBefore = usdc.balanceOf(address(this));

        (,,, uint256 depositorShare) = escrow.executeWaterfall(gross, 365 days, 10_000e6);

        uint256 balanceAfter = usdc.balanceOf(address(this));
        // vault sent gross to escrow, escrow returned depositorShare back
        // net change = depositorShare - gross
        assertEq(
            balanceAfter,
            balanceBefore - gross + depositorShare,
            "vault balance should change by depositorShare - gross"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 13. ShariahVault.claimMusharakahProfit reverts if escrow not set
    // ─────────────────────────────────────────────────────────────────────────
    function test_ShariahVault_claimMusharakahProfit_no_escrow_reverts() public {
        // Deploy a standalone vault without setting escrow
        vm.startPrank(owner);

        TreasuryModule standaloneTreasury = new TreasuryModule(
            "ShariahStandalone",
            makeAddr("placeholder"),
            address(usdc),
            ADMIN_FEE_BPS,
            MUSHARAKAH_SHARE_BPS,
            HURDLE_RATE_BPS,
            owner
        );

        ShariahVault standaloneVault = new ShariahVault(
            IERC20(address(usdc)),
            owner,
            SOURCE_DOMAIN,
            address(standaloneTreasury),
            address(0)
        );

        vm.stopPrank();

        // Fund vault
        usdc.mint(address(standaloneVault), 1_000e6);

        // claimMusharakahProfit without escrow set → PurificationEscrowNotSet
        vm.prank(owner);
        vm.expectRevert(ShariahVault.PurificationEscrowNotSet.selector);
        standaloneVault.claimMusharakahProfit(1_000e6);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 14. ShariahVault.claimMusharakahProfit succeeds when escrow is set
    // ─────────────────────────────────────────────────────────────────────────
    function test_ShariahVault_claimMusharakahProfit_with_escrow_succeeds() public {
        // vault and vaultEscrow are wired together in setUp
        assertEq(
            address(vault.purificationEscrow()),
            address(vaultEscrow),
            "purificationEscrow should be set"
        );

        uint256 gross = 1_000e6;

        // Fund vault with enough USDC (already done in setUp)
        uint256 vaultBalanceBefore = usdc.balanceOf(address(vault));
        assertGe(vaultBalanceBefore, gross, "vault must have enough USDC");

        vm.prank(owner);
        // Should not revert
        vault.claimMusharakahProfit(gross);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 15. MusharakahProfitClaimed event has 5 parameters
    // ─────────────────────────────────────────────────────────────────────────
    function test_ShariahVault_event_has_5_params() public {
        uint256 gross = 1_000e6;

        // Pre-compute expected waterfall output using vaultEscrow state
        // purificationBps=0, charityBps=250
        uint256 purified = 0;
        uint256 afterPurification = gross;
        uint256 expectedCharity   = (afterPurification * 250) / 10_000; // 25e6
        uint256 afterCharity      = afterPurification - expectedCharity;

        // Calculate Musharakah split (elapsed ≈ 0 for fresh vault, principal=0)
        // elapsed = block.timestamp - hurdleStartTime; hurdleStartTime set in constructor = block.timestamp
        // principal = hurdlePrincipal = 0 (never set)
        (, uint256 expectedVaultShare, uint256 expectedDepositorShare) =
            vaultTreasury.calculateMusharakahSplit(afterCharity, 0, 0);

        vm.expectEmit(false, false, false, true, address(vault));
        emit ShariahVault.MusharakahProfitClaimed(
            gross,
            purified,
            expectedCharity,
            expectedVaultShare,
            expectedDepositorShare
        );

        vm.prank(owner);
        vault.claimMusharakahProfit(gross);
    }
}
