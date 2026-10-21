// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ShariahVault}           from "../ShariahVault.sol";
import {ShariahScoreAggregator} from "../ShariahScoreAggregator.sol";
import {RiskTieredExecutor}     from "../RiskTieredExecutor.sol";
import {TreasuryModule}         from "../TreasuryModule.sol";
import {ZakatModule}            from "../ZakatModule.sol";
import {ScoreAggregator}        from "../ScoreAggregator.sol";
import {MockERC20}              from "../test-helpers/MockERC20.sol";

/// @title ShariahVaultTaskATest
/// @notice Task A verification: OUSG/BUIDL removed, masks fixed, index-4 writes blocked.
contract ShariahVaultTaskATest is Test {

    // ── actors ────────────────────────────────────────────────────
    address internal owner       = makeAddr("owner");
    address internal alice       = makeAddr("alice");
    address internal charityWallet = makeAddr("charity");

    // ── mock assets ───────────────────────────────────────────────
    MockERC20 internal usdc;
    /// @dev Stand-in for any unscreened adapter address (e.g. RwaYieldAdapter)
    address   internal rwaAdapterAddr;
    /// @dev Stand-in for OUSG token address
    address   internal ousgAddr;

    // ── contracts ─────────────────────────────────────────────────
    TreasuryModule         internal shariahTreasury;
    ZakatModule            internal zakatModule;
    ShariahVault           internal vault;
    ShariahScoreAggregator internal aggregator;
    ScoreAggregator        internal conventionalAggregator;

    // ── constants ─────────────────────────────────────────────────
    uint32 internal constant SOURCE_DOMAIN = 26; // Arc Testnet CCTP domain

    function setUp() public {
        usdc            = new MockERC20("Mock USDC", "mUSDC", 6);
        rwaAdapterAddr  = makeAddr("rwaAdapter");
        ousgAddr        = makeAddr("ousg");

        vm.startPrank(owner);

        // Treasury — Shariah params
        shariahTreasury = new TreasuryModule(
            "Shariah",
            address(0), // feeSource set after vault deploy
            address(usdc),
            50,   // wakalaFeeBps = 0.5%
            1000, // musharakahShareBps = 10%
            400,  // hurdleRateBps = 4%
            owner
        );

        // Vault (feeSource address is itself — set correctly in a real deploy via a two-step)
        vault = new ShariahVault(
            IERC20(address(usdc)),
            owner,
            SOURCE_DOMAIN,
            address(shariahTreasury),
            address(0) // no zakatModule needed for these tests
        );

        // ZakatModule (not used in these specific tests but needed for completeness)
        zakatModule = new ZakatModule(charityWallet, address(usdc), address(vault), owner);

        // Score aggregators
        conventionalAggregator = new ScoreAggregator(owner);
        aggregator = new ShariahScoreAggregator(owner);

        vm.stopPrank();

        // Fund vault
        usdc.mint(alice, 100_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), 100_000e6);
        vm.prank(alice);
        vault.deposit(100_000e6, alice);
    }

    // ── Test A-1: RwaYieldAdapter cannot be deployed to once unscreened ─────

    /// @notice deployCapital to an unscreened adapter must revert AdapterNotScreened.
    /// The rwaAdapterAddr was never screened (setUp doesn't screen it) so this
    /// covers the post-recall / post-unscreen state.
    function test_rwaAdapter_not_screened_reverts() public {
        // Screening is enabled by default; rwaAdapterAddr was never screened
        assertFalse(vault.screened(rwaAdapterAddr), "adapter should not be screened");

        vm.prank(owner);
        vm.expectRevert(ShariahVault.AdapterNotScreened.selector);
        vault.deployCapital(rwaAdapterAddr, 1_000e6, "");
    }

    /// @notice Even if we screen the adapter, deploying to an OUSG-like address that
    /// is not in permittedAssets doesn't matter here — the asset check is on the
    /// vault asset (USDC), which IS permitted.  The real guard is the screened mapping.
    /// This test verifies setScreened → deploy succeeds (confirming the guard is the only gatekeeper).
    function test_screened_adapter_can_be_deployed_to() public {
        address fakeHalalAdapter = makeAddr("halalAdapter");

        vm.startPrank(owner);
        vault.setScreened(fakeHalalAdapter, true);
        // deployCapital transfers USDC to the adapter — must not revert
        vault.deployCapital(fakeHalalAdapter, 1_000e6, "");
        vm.stopPrank();

        assertGt(vault.totalDeployed(), 0, "capital should be deployed");
    }

    // ── Test A-2: OUSG address is not in permittedAssets ───────────────────

    /// @notice permittedAssets[OUSG] must be false by default (never added in constructor
    ///         after Task A — only USDC is added in the constructor).
    function test_ousg_not_in_permittedAssets_by_default() public view {
        assertFalse(vault.permittedAssets(ousgAddr), "OUSG must not be a permitted asset");
    }

    /// @notice Owner can add a permitted asset but OUSG should never be added per SR-001;
    ///         this test confirms the flag is false out of the box and requires an explicit
    ///         owner action to set it (which the board must not approve per SR-001).
    function test_owner_can_add_asset_but_ousg_starts_false() public {
        vm.prank(owner);
        vault.setPermittedAsset(ousgAddr, true);
        assertTrue(vault.permittedAssets(ousgAddr), "owner can set it true (guard is social, not code)");

        // Reset — board should not approve this
        vm.prank(owner);
        vault.setPermittedAsset(ousgAddr, false);
        assertFalse(vault.permittedAssets(ousgAddr));
    }

    // ── Test A-3: ShariahScoreAggregator rejects writes to index 4 ─────────

    /// @notice writeScore for strategy index 4 must revert StrategyDeprecated.
    function test_scoreAggregator_rejects_index4() public {
        ShariahScoreAggregator.ShariahStrategy deprecated =
            ShariahScoreAggregator.ShariahStrategy(4); // RESERVED_4

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(ShariahScoreAggregator.StrategyDeprecated.selector, uint8(4))
        );
        aggregator.writeScore(deprecated, 75, bytes32(0), 0);
    }

    /// @notice writeBatchScores including index 4 must revert StrategyDeprecated.
    function test_scoreAggregator_batchRejects_index4() public {
        ShariahScoreAggregator.ShariahStrategy[] memory strats =
            new ShariahScoreAggregator.ShariahStrategy[](2);
        strats[0] = ShariahScoreAggregator.ShariahStrategy.ETH_SPREAD;
        strats[1] = ShariahScoreAggregator.ShariahStrategy(4); // RESERVED_4

        uint8[] memory vals = new uint8[](2);
        vals[0] = 80; vals[1] = 70;

        bytes32[] memory hashes = new bytes32[](2);
        uint32[] memory domains = new uint32[](2);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(ShariahScoreAggregator.StrategyDeprecated.selector, uint8(4))
        );
        aggregator.writeBatchScores(strats, vals, hashes, domains);
    }

    /// @notice Writes to indices 0–3 still succeed (not deprecated).
    function test_scoreAggregator_accepts_indices_0_to_3() public {
        // Mark strategies 0-3 as certified and write scores — all as owner
        vm.startPrank(owner);
        for (uint8 i = 0; i < 4; i++) {
            aggregator.setCertified(ShariahScoreAggregator.ShariahStrategy(i), true);
        }
        aggregator.writeScore(ShariahScoreAggregator.ShariahStrategy.ETH_SPREAD,  80, bytes32(0), 0);
        aggregator.writeScore(ShariahScoreAggregator.ShariahStrategy.GOLD_SPREAD, 70, bytes32(0), 0);
        aggregator.writeScore(ShariahScoreAggregator.ShariahStrategy.HALAL_LP,    65, bytes32(0), 0);
        aggregator.writeScore(ShariahScoreAggregator.ShariahStrategy.MURABAHA,    60, bytes32(0), 0);
        vm.stopPrank();
        // If any of the above reverted the test would fail — this just asserts no revert
    }

    // ── Test A-4: RiskTieredExecutor masks ──────────────────────────────────

    /// @notice SHARIAH_CONSERVATIVE executor mask updated in Task F to 38 (0b100110 = bits 1,2,5:
    ///         Gold Spread + Halal LP + Gold Allocation).  Old value 6 was pre-Task F.
    function test_conservativeMask_is_6() public {
        RiskTieredExecutor conservativeExec = new RiskTieredExecutor(
            address(vault),
            address(conventionalAggregator),
            RiskTieredExecutor.RiskTier.SHARIAH_CONSERVATIVE,
            owner
        );
        // Updated by Task F: mask is now 38 (0b100110) — bit5 (GOLD_ALLOCATION) added.
        assertEq(conservativeExec.strategyMask(), 38, "Conservative mask must be 0b100110 (Task F)");
    }

    /// @notice SHARIAH_DYNAMIC executor mask updated in Task F to 47 (0b101111 = bits 0-3,5:
    ///         all active halal strategies including Gold Allocation).  Old value 15 was pre-Task F.
    function test_dynamicMask_is_15() public {
        RiskTieredExecutor dynamicExec = new RiskTieredExecutor(
            address(vault),
            address(conventionalAggregator),
            RiskTieredExecutor.RiskTier.SHARIAH_DYNAMIC,
            owner
        );
        // Updated by Task F: mask is now 47 (0b101111) — bit5 (GOLD_ALLOCATION) added.
        assertEq(dynamicExec.strategyMask(), 47, "Dynamic mask must be 0b101111 (Task F)");
    }

    /// @notice Bit 4 (index 4 = RESERVED_4) must NOT be set in either Shariah mask.
    function test_bit4_not_set_in_any_shariah_mask() public {
        RiskTieredExecutor conservativeExec = new RiskTieredExecutor(
            address(vault),
            address(conventionalAggregator),
            RiskTieredExecutor.RiskTier.SHARIAH_CONSERVATIVE,
            owner
        );
        RiskTieredExecutor dynamicExec = new RiskTieredExecutor(
            address(vault),
            address(conventionalAggregator),
            RiskTieredExecutor.RiskTier.SHARIAH_DYNAMIC,
            owner
        );

        uint8 bit4 = (1 << 4);
        assertEq(conservativeExec.strategyMask() & bit4, 0, "Conservative must not include bit4");
        assertEq(dynamicExec.strategyMask()     & bit4, 0, "Dynamic must not include bit4");
    }

    // ── Test A-5: setScreened owner-only guard still works ──────────────────

    function test_setScreened_only_owner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setScreened(rwaAdapterAddr, true);
    }
}
