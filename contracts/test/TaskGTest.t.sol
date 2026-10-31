// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {GoldAllocationAdapter}   from "../adapters/GoldAllocationAdapter.sol";
import {ShariahVault}            from "../ShariahVault.sol";
import {ShariahVaultV2}          from "../ShariahVaultV2.sol";
import {ShariahScoreAggregator}  from "../ShariahScoreAggregator.sol";
import {ShariahAdapterRegistry}  from "../ShariahAdapterRegistry.sol";
import {TreasuryModule}          from "../TreasuryModule.sol";
import {ZakatModule}             from "../ZakatModule.sol";
import {MockERC20}               from "../test-helpers/MockERC20.sol";
import {MockXAUT}                from "../test-helpers/MockXAUT.sol";
import {MockXauUsdAggregator}    from "../test-helpers/MockXauUsdAggregator.sol";
import {MockUniswapV3PoolXAUT}   from "../test-helpers/MockUniswapV3PoolXAUT.sol";

/// @title  TaskGTest
/// @notice Tests for Task G fixes: G1 (GoldAllocationAdapter), G3 (ShariahScoreAggregator),
///         G4 (ShariahAdapterRegistry), and G10 (ShariahVaultV2 zero zakatModule).
contract TaskGTest is Test {

    // ── Actors ────────────────────────────────────────────────────────────────
    address internal owner        = makeAddr("owner");
    address internal alice        = makeAddr("alice");
    address internal charityWallet = makeAddr("charity");

    // ── Token / oracle mocks ─────────────────────────────────────────────────
    MockERC20              internal usdc;
    MockXAUT               internal xaut;
    MockXauUsdAggregator   internal oracle;
    MockUniswapV3PoolXAUT  internal pool;

    // ── Protocol contracts ────────────────────────────────────────────────────
    TreasuryModule          internal treasury;
    ShariahVault            internal vault;
    GoldAllocationAdapter   internal adapter;
    ShariahScoreAggregator  internal aggregator;

    // ── Constants ─────────────────────────────────────────────────────────────
    uint32  internal constant SOURCE_DOMAIN = 26;
    uint256 internal constant MAX_STALENESS = 3600; // 1 hour

    int256  internal constant ORACLE_PRICE      = 330_000_000_000; // $3300 × 10^8
    uint256 internal constant ORACLE_USDC       = 3_300_000_000;   // oraclePriceUsdc
    uint256 internal constant POOL_USDC_PER_XAUT = 3_300_000_000;

    // ─────────────────────────────────────────────────────────────────────────
    //  setUp — runs before every test
    // ─────────────────────────────────────────────────────────────────────────

    function setUp() public {
        // Warp to a realistic timestamp so staleness math doesn't underflow
        vm.warp(1_700_000_000);

        // 1. Deploy tokens + mocks
        usdc   = new MockERC20("Mock USDC", "mUSDC", 6);
        xaut   = new MockXAUT();
        oracle = new MockXauUsdAggregator();
        pool   = new MockUniswapV3PoolXAUT(address(usdc), address(xaut), POOL_USDC_PER_XAUT);

        vm.startPrank(owner);

        // 2. TreasuryModule — zero wakalaFeeBps avoids feeSource check in tests
        treasury = new TreasuryModule(
            "Shariah",
            address(0),
            address(usdc),
            0,    // wakalaFeeBps = 0
            0,    // musharakahShareBps
            0,    // hurdleRateBps
            owner
        );

        // 3. ShariahVault (V1)
        vault = new ShariahVault(
            IERC20(address(usdc)),
            owner,
            SOURCE_DOMAIN,
            address(treasury),
            address(0) // zakatModule not needed
        );

        // 4. ShariahScoreAggregator
        aggregator = new ShariahScoreAggregator(owner);

        // 5. GoldAllocationAdapter
        adapter = new GoldAllocationAdapter(
            address(usdc),
            address(xaut),
            address(pool),   // swapRouter_
            3000,            // poolFee_ (0.3%)
            address(oracle), // goldOracle_
            address(vault),  // vault_
            MAX_STALENESS,   // initialMaxStalenessSecs
            owner            // initialOwner
        );

        // 6. Screen the adapter in the vault
        vault.setScreened(address(adapter), true);
        vault.setGoldAllocationAdapter(address(adapter));

        vm.stopPrank();

        // 7. Fund pool with USDC and XAUT
        usdc.mint(address(this), 50_000_000e6);
        xaut.mint(address(this), 20_000e6);
        usdc.approve(address(pool), 50_000_000e6);
        xaut.approve(address(pool), 20_000e6);
        pool.fundPool(50_000_000e6, 20_000e6);

        // 8. Alice deposits to vault
        usdc.mint(alice, 10_000_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 10_000_000e6);
        vault.deposit(10_000_000e6, alice);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Deploy `amount` USDC from vault to adapter (accounts + swaps).
    function _deployCapital(uint256 amount) internal {
        vm.prank(owner);
        vault.deployCapitalAndExecute(address(adapter), amount, "");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  G1 — GoldAllocationAdapter stale-oracle & OracleNotSane tests
    // ═════════════════════════════════════════════════════════════════════════

    // ── G1-1 ─────────────────────────────────────────────────────────────────

    // N-09 keeps stale exits open only when proceeds meet the discounted cached-price floor.
    function test_G1_recall_succeeds_when_oracle_stale() public {
        // Deploy 1000e6 USDC
        _deployCapital(1_000e6);
        assertGt(adapter.xautHeld(), 0, "must hold XAUT before recall");

        // Make oracle stale
        oracle.setUpdatedAt(0);

        pool.setPrice(ORACLE_USDC * 90 / 100); // A 10% decline still clears the outage floor.
        uint256 floor = adapter.xautHeld() * adapter.lastGoodPrice() / 1e6;
        floor = floor * (10_000 - adapter.staleHaircutBps()) / 10_000;
        floor = floor * (10_000 - adapter.emergencySlippageBps()) / 10_000;
        vm.prank(address(vault));
        uint256 usdcReturned = adapter.recall(1_000e6);

        assertGe(usdcReturned, floor, "stale recall must meet cached-price floor");
        assertEq(adapter.xautHeld(), 0, "xautHeld must be 0 after recall");
    }

    // ── G1-2 ─────────────────────────────────────────────────────────────────

    // N-09 replaces cost basis with cached market value and two explicit outage discounts.
    function test_G1_recall_uses_lastGoodPrice_floor_when_stale() public {
        _deployCapital(1_000e6);
        oracle.setPrice(264_000_000_000);
        adapter.pokePrice(); // A newer lower cached price must override entry cost basis.
        uint256 gross = adapter.xautHeld() * adapter.lastGoodPrice() / 1e6;
        uint256 expectedFloor = gross * (10_000 - adapter.staleHaircutBps()) / 10_000;
        expectedFloor = expectedFloor * (10_000 - adapter.emergencySlippageBps()) / 10_000;
        oracle.setUpdatedAt(0);
        pool.setPrice(ORACLE_USDC * 72 / 100);
        vm.prank(address(vault));
        uint256 returned = adapter.recall(1_000e6);
        assertGe(returned, expectedFloor);
        assertLt(returned, 995e6, "ordinary decline must not be blocked by principal floor");
    }

    function test_G1_recall_below_stale_floor_reverts() public {
        _deployCapital(1_000e6);
        uint256 floor = adapter.xautHeld() * adapter.lastGoodPrice() / 1e6;
        floor = floor * (10_000 - adapter.staleHaircutBps()) / 10_000;
        floor = floor * (10_000 - adapter.emergencySlippageBps()) / 10_000;
        oracle.setUpdatedAt(0);
        vm.mockCall(address(pool), abi.encodeWithSelector(bytes4(keccak256(
            "exactInputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160))"
        ))), abi.encode(floor - 1));
        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(GoldAllocationAdapter.SlippageExceeded.selector, floor - 1, floor));
        adapter.recall(1_000e6);
        assertGt(adapter.xautHeld(), 0);
    }

    // ── G1-3 ─────────────────────────────────────────────────────────────────

    /// @notice deploy() MUST revert OracleNotSane() when the oracle is stale.
    function test_G1_deploy_reverts_when_oracle_not_sane() public {
        oracle.setUpdatedAt(0);
        vm.prank(owner);
        vm.expectRevert(GoldAllocationAdapter.OracleNotSane.selector);
        vault.deployCapitalAndExecute(address(adapter), 1_000e6, "");
        assertEq(vault.totalDeployed(), 0);
        assertEq(usdc.balanceOf(address(adapter)), 0);
    }

    // ── G1-4 ─────────────────────────────────────────────────────────────────

    /// @notice PR1: currentValue() uses lastGoodPrice * (1 - haircut) when oracle is stale.
    ///         Cost basis (totalDeployed) is NEVER used (PR1 spec supersedes G1 fallback).
    function test_G1_currentValue_returns_totalDeployed_when_stale() public {
        _deployCapital(1_000e6);

        uint256 lastGoodPrice = adapter.lastGoodPrice();
        assertGt(lastGoodPrice, 0, "lastGoodPrice must be set after deploy");

        uint256 xautHeld = adapter.xautHeld();
        assertGt(xautHeld, 0, "xautHeld must be > 0 after deploy");

        // Make oracle stale
        oracle.setUpdatedAt(0);

        // PR1: currentValue() must NOT revert, and must use lastGoodPrice * haircut
        uint256 cv = adapter.currentValue();
        assertGt(cv, 0, "currentValue() must return > 0 after deploy (lastGoodPrice set)");

        // Verify it uses lastGoodPrice, not totalDeployed:
        // grossValue = xautHeld * lastGoodPrice / 1e6
        // haircutValue = grossValue * (10_000 - 500) / 10_000
        uint256 grossValue = (xautHeld * lastGoodPrice) / 1e6;
        uint256 haircutValue = (grossValue * 9_500) / 10_000;
        assertApproxEqRel(cv, haircutValue, 0.01e18,
            "PR1: currentValue() must use lastGoodPrice * (1-haircut) when stale");
    }

    // ── G1-5 ─────────────────────────────────────────────────────────────────

    // N-09 prevents a manipulated low spot price from lowering the fresh-oracle exit floor.
    function test_G1_recall_reverts_when_pool_deviation_low() public {
        _deployCapital(1_000e6);
        uint256 held = adapter.xautHeld();
        pool.setPrice(ORACLE_USDC * 95 / 100);
        vm.prank(address(vault));
        // the mock pool rejects output below the oracle-derived minimum (custom error carries args)
        vm.expectRevert();
        adapter.recall(1_000e6);
        assertEq(adapter.xautHeld(), held);
    }

    // N-09 still permits favorable pool deviation when output clears the unchanged oracle floor.
    function test_G1_recall_succeeds_when_pool_deviation_high() public {
        _deployCapital(1_000e6);
        pool.setPrice(ORACLE_USDC * 105 / 100);
        vm.prank(address(vault));
        assertGt(adapter.recall(1_000e6), 0);
        assertEq(adapter.xautHeld(), 0);
    }

    // ── G1-6 ─────────────────────────────────────────────────────────────────

    // N-09 replaces unconditional stale-exit success with success exactly at the discounted floor.
    function testFuzz_G1_recall_enforces_stale_floor(
        uint128 amount,
        uint32 stalenessSeed,
        bool belowFloor
    ) public {
        amount = uint128(bound(amount, 3_300e6, 1_000_000e6));
        _deployCapital(amount);
        uint256 floor = adapter.xautHeld() * adapter.lastGoodPrice() / 1e6;
        floor = floor * (10_000 - adapter.staleHaircutBps()) / 10_000;
        floor = floor * (10_000 - adapter.emergencySlippageBps()) / 10_000;
        vm.warp(block.timestamp + MAX_STALENESS + bound(stalenessSeed, 1, 365 days));
        uint256 payout = belowFloor ? floor - 1 : floor;
        vm.mockCall(address(pool), abi.encodeWithSelector(bytes4(keccak256(
            "exactInputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160))"
        ))), abi.encode(payout));
        vm.prank(address(vault));
        if (belowFloor) {
            vm.expectRevert(abi.encodeWithSelector(GoldAllocationAdapter.SlippageExceeded.selector, payout, floor));
            adapter.recall(amount);
            assertGt(adapter.xautHeld(), 0);
        } else {
            assertEq(adapter.recall(amount), floor);
            assertEq(adapter.xautHeld(), 0);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  G3 — ShariahScoreAggregator renamed mapping & events
    // ═════════════════════════════════════════════════════════════════════════

    // ── G3-7 ─────────────────────────────────────────────────────────────────

    /// @notice strategyEnabled mapping is publicly readable (was shariahCertified).
    function test_G3_strategyEnabled_mapping_exists() public view {
        // Just reading the mapping with a valid strategy index must not revert
        bool enabled = aggregator.strategyEnabled(ShariahScoreAggregator.ShariahStrategy.GOLD_SPREAD);
        // Fresh deployment — should be false
        assertFalse(enabled, "strategyEnabled should be false by default");
    }

    // ── G3-8 ─────────────────────────────────────────────────────────────────

    /// @notice setEnabled(GOLD_SPREAD, true) sets strategyEnabled[GOLD_SPREAD] = true.
    function test_G3_setEnabled_works() public {
        vm.prank(owner);
        aggregator.setEnabled(ShariahScoreAggregator.ShariahStrategy.GOLD_SPREAD, true);

        assertTrue(
            aggregator.strategyEnabled(ShariahScoreAggregator.ShariahStrategy.GOLD_SPREAD),
            "strategyEnabled must be true after setEnabled"
        );
    }

    // ── G3-9 ─────────────────────────────────────────────────────────────────

    /// @notice P-8: the setCertified alias is removed ("certified" is reserved for board rulings).
    function test_G3_setCertified_alias_removed() public {
        vm.prank(owner);
        (bool ok,) = address(aggregator).call(
            abi.encodeWithSignature("setCertified(uint8,bool)", uint8(ShariahScoreAggregator.ShariahStrategy.ETH_SPREAD), true)
        );
        assertFalse(ok, "setCertified selector must not exist");
        assertFalse(aggregator.strategyEnabled(ShariahScoreAggregator.ShariahStrategy.ETH_SPREAD));
    }

    // ── G3-10 ────────────────────────────────────────────────────────────────

    /// @notice setEnabled emits StrategyEnabledUpdated (renamed from StrategyCertified).
    function test_G3_StrategyEnabledUpdated_event_emitted() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true, address(aggregator));
        emit ShariahScoreAggregator.StrategyEnabledUpdated(
            ShariahScoreAggregator.ShariahStrategy.GOLD_ALLOCATION,
            true
        );
        aggregator.setEnabled(ShariahScoreAggregator.ShariahStrategy.GOLD_ALLOCATION, true);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  G4 — ShariahAdapterRegistry timelock-based board-role management
    // ═════════════════════════════════════════════════════════════════════════

    // ── G4-11 ────────────────────────────────────────────────────────────────

    /// @notice After emergencyRevokeBoardRole removes owner's own board role,
    ///         calling proposeBoardRoleChange reverts NotBoardRole.
    function test_G4_owner_cannot_grant_board_role_directly() public {
        // Deploy a fresh registry — deployer is owner AND board member
        address registryOwner = makeAddr("regOwner");
        vm.prank(registryOwner);
        ShariahAdapterRegistry freshRegistry = new ShariahAdapterRegistry(registryOwner, registryOwner);

        // registryOwner has board role from constructor
        assertTrue(freshRegistry.boardRole(registryOwner), "deployer must have board role");

        // Owner calls emergencyRevokeBoardRole to remove own board membership
        vm.prank(registryOwner);
        freshRegistry.emergencyRevokeBoardRole(registryOwner);
        assertFalse(freshRegistry.boardRole(registryOwner), "board role must be gone");

        // Now registryOwner (as owner but NOT board) tries proposeBoardRoleChange — must revert
        vm.prank(registryOwner);
        vm.expectRevert(
            abi.encodeWithSelector(ShariahAdapterRegistry.NotBoardRole.selector, registryOwner)
        );
        freshRegistry.proposeBoardRoleChange(makeAddr("newMember"), true);
    }

    // ── G4-12 ────────────────────────────────────────────────────────────────

    /// @notice Board member can propose granting a new board role and proposal is recorded.
    function test_G4_board_can_propose_grant() public {
        address newMember = makeAddr("newMember");
        address boardMember = makeAddr("boardDeployer");

        vm.prank(boardMember);
        ShariahAdapterRegistry reg = new ShariahAdapterRegistry(boardMember, boardMember);

        // boardMember proposes to grant to newMember
        vm.prank(boardMember);
        reg.proposeBoardRoleChange(newMember, true);

        // Proposal must exist
        (, , bool exists) = reg.boardRoleProposals(newMember);
        assertTrue(exists, "proposal must exist after propose");
    }

    // ── G4-13 ────────────────────────────────────────────────────────────────

    /// @notice executeBoardRoleChange before timelock reverts TimelockNotElapsed.
    function test_G4_execute_before_timelock_reverts() public {
        address newMember = makeAddr("boardMember13");
        address boardMember = makeAddr("boardDeployer13");

        vm.prank(boardMember);
        ShariahAdapterRegistry reg = new ShariahAdapterRegistry(boardMember, boardMember);

        vm.prank(boardMember);
        reg.proposeBoardRoleChange(newMember, true);

        // Try to execute immediately (before timelock)
        uint256 expectedExecuteAfter = block.timestamp + 30 days;
        vm.prank(boardMember);
        vm.expectRevert(
            abi.encodeWithSelector(
                ShariahAdapterRegistry.TimelockNotElapsed.selector,
                expectedExecuteAfter,
                block.timestamp
            )
        );
        reg.executeBoardRoleChange(newMember);
    }

    // ── G4-14 ────────────────────────────────────────────────────────────────

    /// @notice executeBoardRoleChange after 30-day timelock grants the board role.
    function test_G4_execute_after_timelock_succeeds() public {
        address newMember = makeAddr("boardMember14");
        address boardMember = makeAddr("boardDeployer14");

        vm.prank(boardMember);
        ShariahAdapterRegistry reg = new ShariahAdapterRegistry(boardMember, boardMember);

        vm.prank(boardMember);
        reg.proposeBoardRoleChange(newMember, true);

        // Warp past the 30-day timelock
        vm.warp(block.timestamp + 30 days);

        vm.prank(boardMember);
        reg.executeBoardRoleChange(newMember);

        assertTrue(reg.boardRole(newMember), "boardRole must be true after execute");
    }

    // ── G4-15 ────────────────────────────────────────────────────────────────

    /// @notice cancelBoardRoleChange clears the pending proposal.
    function test_G4_cancel_clears_proposal() public {
        address account = makeAddr("acct15");
        address boardMember = makeAddr("boardDeployer15");

        vm.prank(boardMember);
        ShariahAdapterRegistry reg = new ShariahAdapterRegistry(boardMember, boardMember);

        vm.prank(boardMember);
        reg.proposeBoardRoleChange(account, true);

        // Proposal exists before cancel
        (,, bool existsBefore) = reg.boardRoleProposals(account);
        assertTrue(existsBefore, "proposal must exist before cancel");

        vm.prank(boardMember);
        reg.cancelBoardRoleChange(account);

        // Proposal cleared
        (,, bool existsAfter) = reg.boardRoleProposals(account);
        assertFalse(existsAfter, "proposal must not exist after cancel");
    }

    // ── G4-16 ────────────────────────────────────────────────────────────────

    /// @notice emergencyRevokeBoardRole is onlyOwner — non-owner reverts.
    function test_G4_emergencyRevoke_owner_only() public {
        address boardMember = makeAddr("boardDeployer16");
        address nonOwner    = makeAddr("nonOwner16");

        vm.prank(boardMember);
        ShariahAdapterRegistry reg = new ShariahAdapterRegistry(boardMember, boardMember);

        vm.prank(nonOwner);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner)
        );
        reg.emergencyRevokeBoardRole(boardMember);
    }

    // ── G4-17 ────────────────────────────────────────────────────────────────

    /// @notice emergencyRevokeBoardRole immediately removes board role, no timelock.
    function test_G4_emergencyRevoke_works() public {
        address boardMember = makeAddr("boardDeployer17");

        vm.prank(boardMember);
        ShariahAdapterRegistry reg = new ShariahAdapterRegistry(boardMember, boardMember);

        // boardMember has board role from constructor
        assertTrue(reg.boardRole(boardMember), "must have board role initially");

        // Owner (== boardMember here) calls emergency revoke
        vm.prank(boardMember);
        reg.emergencyRevokeBoardRole(boardMember);

        assertFalse(reg.boardRole(boardMember), "boardRole must be false after emergencyRevoke");
    }

    // ── G4-18 ────────────────────────────────────────────────────────────────

    /// @notice A second proposeBoardRoleChange for the same account reverts BoardRoleProposalExists.
    function test_G4_double_propose_reverts() public {
        address account = makeAddr("acct18");
        address boardMember = makeAddr("boardDeployer18");

        vm.prank(boardMember);
        ShariahAdapterRegistry reg = new ShariahAdapterRegistry(boardMember, boardMember);

        vm.prank(boardMember);
        reg.proposeBoardRoleChange(account, true);

        // Second propose must revert BoardRoleProposalExists
        vm.prank(boardMember);
        vm.expectRevert(
            abi.encodeWithSelector(ShariahAdapterRegistry.BoardRoleProposalExists.selector, account)
        );
        reg.proposeBoardRoleChange(account, true);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  G10 — ShariahVaultV2 accepts address(0) for zakatModule_
    // ═════════════════════════════════════════════════════════════════════════

    // ── G10-19 ───────────────────────────────────────────────────────────────

    /// @notice ShariahVaultV2 deploys and operates normally when zakatModule_ == address(0).
    function test_G10_ShariahVaultV2_works_with_zero_zakatModule() public {
        // Build minimal support contracts
        MockERC20 usdc2 = new MockERC20("Mock USDC2", "mUSDC2", 6);

        vm.startPrank(owner);

        TreasuryModule treasury2 = new TreasuryModule(
            "Shariah2",
            address(0),
            address(usdc2),
            0,    // wakalaFeeBps = 0
            0,
            0,
            owner
        );

        ShariahAdapterRegistry registry2 = new ShariahAdapterRegistry(owner, owner);

        // Deploy ShariahVaultV2 with zakatModule_ = address(0)
        ShariahVaultV2 vault2 = new ShariahVaultV2(
            IERC20(address(usdc2)),
            owner,
            SOURCE_DOMAIN,
            address(treasury2),
            address(0),       // zakatModule_ = address(0) — G10 fix
            address(registry2)
        );

        vm.stopPrank();

        // Deposit 1000e6 USDC
        usdc2.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc2.approve(address(vault2), 1_000e6);
        uint256 shares = vault2.deposit(1_000e6, alice);
        vm.stopPrank();

        assertGt(shares, 0, "shares must be minted on deposit");

        // Redeem — must NOT revert due to zakatModule == address(0)
        vm.startPrank(alice);
        uint256 usdcReturned = vault2.redeem(shares, alice, alice);
        vm.stopPrank();

        assertGt(usdcReturned, 0, "redeem must return USDC");
    }
}
