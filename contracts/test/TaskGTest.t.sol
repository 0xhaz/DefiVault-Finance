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
        vault.deployCapital(address(adapter), amount, "");
        vm.prank(address(vault));
        adapter.deploy(amount);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  G1 — GoldAllocationAdapter stale-oracle & OracleNotSane tests
    // ═════════════════════════════════════════════════════════════════════════

    // ── G1-1 ─────────────────────────────────────────────────────────────────

    /// @notice recall() MUST NOT revert when the oracle is stale.
    function test_G1_recall_succeeds_when_oracle_stale() public {
        // Deploy 1000e6 USDC
        _deployCapital(1_000e6);
        assertGt(adapter.xautHeld(), 0, "must hold XAUT before recall");

        // Make oracle stale
        oracle.setUpdatedAt(0);

        // recall MUST NOT revert — even with stale oracle
        vm.prank(address(vault));
        uint256 usdcReturned = adapter.recall(1_000e6);

        assertGt(usdcReturned, 0, "USDC returned must be > 0");
        assertEq(adapter.xautHeld(), 0, "xautHeld must be 0 after recall");
    }

    // ── G1-2 ─────────────────────────────────────────────────────────────────

    /// @notice When oracle is stale, recall uses totalDeployed as floor:
    ///         usdcReturned >= totalDeployed * (10_000 - maxSlippageBps) / 10_000.
    function test_G1_recall_uses_totalDeployed_floor_when_stale() public {
        uint256 deployAmount = 1_000e6;
        _deployCapital(deployAmount);

        uint256 totalDeployedBefore = adapter.totalDeployed();
        uint256 maxSlippageBps = adapter.maxSlippageBps();

        // Make oracle stale
        oracle.setUpdatedAt(0);

        vm.prank(address(vault));
        uint256 usdcReturned = adapter.recall(deployAmount);

        uint256 expectedFloor = (totalDeployedBefore * (10_000 - maxSlippageBps)) / 10_000;
        assertGe(usdcReturned, expectedFloor, "usdcReturned must be >= totalDeployed floor");
    }

    // ── G1-3 ─────────────────────────────────────────────────────────────────

    /// @notice deploy() MUST revert OracleNotSane() when the oracle is stale.
    function test_G1_deploy_reverts_when_oracle_not_sane() public {
        // Push USDC accounting to vault side (no actual swap yet)
        vm.prank(owner);
        vault.deployCapital(address(adapter), 1_000e6, "");

        // Make oracle stale
        oracle.setUpdatedAt(0);

        vm.prank(address(vault));
        vm.expectRevert(GoldAllocationAdapter.OracleNotSane.selector);
        adapter.deploy(1_000e6);
    }

    // ── G1-4 ─────────────────────────────────────────────────────────────────

    /// @notice currentValue() returns totalDeployed (not 0, not revert) when oracle is stale.
    function test_G1_currentValue_returns_totalDeployed_when_stale() public {
        _deployCapital(1_000e6);

        uint256 totalDeployedSnap = adapter.totalDeployed();
        assertGt(totalDeployedSnap, 0, "totalDeployed must be > 0 after deploy");

        // Make oracle stale
        oracle.setUpdatedAt(0);

        // currentValue() must NOT revert and must return totalDeployed
        uint256 cv = adapter.currentValue();
        assertEq(cv, totalDeployedSnap, "currentValue() must return totalDeployed when oracle stale");
    }

    // ── G1-5 ─────────────────────────────────────────────────────────────────

    /// @notice When pool has 5% deviation from oracle, recall MUST NOT revert —
    ///         it should use the conservative (lower) price path.
    function test_G1_recall_succeeds_when_pool_deviation_high() public {
        _deployCapital(1_000e6);
        assertGt(adapter.xautHeld(), 0, "must hold XAUT");

        // Set pool price 5% above oracle — this causes deviation > maxDeviationBps (1%)
        uint256 deviatedPrice = ORACLE_USDC * 105 / 100; // +5%
        pool.setPrice(deviatedPrice);

        // recall MUST NOT revert; it should use conservative price path
        vm.prank(address(vault));
        uint256 usdcReturned = adapter.recall(1_000e6);

        assertGt(usdcReturned, 0, "USDC returned must be > 0 even with high pool deviation");
        assertEq(adapter.xautHeld(), 0, "xautHeld must be 0 after recall");
    }

    // ── G1-6 ─────────────────────────────────────────────────────────────────

    /// @notice Fuzz: recall() must NEVER revert when oracle becomes stale.
    /// @dev    Lower bound 3_300e6 (≈1 oz gold) ensures the deploy always acquires at least
    ///         one XAUT unit so recall actually executes a swap (amount too small → 0 xaut → recall returns 0).
    function testFuzz_G1_recall_never_reverts_on_stale(
        uint128 amount,
        uint32 stalenessSeed
    ) public {
        // Bound amount: min 3_300e6 (1 oz gold in USDC) so the deploy always gets >0 XAUT.
        // Max 1_000_000e6 (1M USDC) — well within pool liquidity (50M funded in setUp).
        amount = uint128(bound(amount, 3_300e6, 1_000_000e6));

        _deployCapital(amount);

        // Sanity: must have acquired XAUT
        assertGt(adapter.xautHeld(), 0, "xautHeld must be >0 after deploy");

        // Make oracle stale by warping forward past staleness window
        // stalenessSeed adds extra time beyond the staleness threshold
        uint256 extraTime = bound(stalenessSeed, 1, 365 days);
        vm.warp(block.timestamp + MAX_STALENESS + extraTime);

        // recall MUST NOT revert regardless of staleness
        vm.prank(address(vault));
        uint256 usdcReturned = adapter.recall(amount);

        // Basic sanity: some USDC must come back
        assertGt(usdcReturned, 0, "recall must return USDC even with stale oracle");
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

    /// @notice setCertified (backward-compat alias) also sets strategyEnabled.
    function test_G3_setCertified_alias_works() public {
        vm.prank(owner);
        aggregator.setCertified(ShariahScoreAggregator.ShariahStrategy.ETH_SPREAD, true);

        assertTrue(
            aggregator.strategyEnabled(ShariahScoreAggregator.ShariahStrategy.ETH_SPREAD),
            "strategyEnabled must be true after setCertified alias"
        );
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
        ShariahAdapterRegistry freshRegistry = new ShariahAdapterRegistry(registryOwner);

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
        ShariahAdapterRegistry reg = new ShariahAdapterRegistry(boardMember);

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
        ShariahAdapterRegistry reg = new ShariahAdapterRegistry(boardMember);

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
        ShariahAdapterRegistry reg = new ShariahAdapterRegistry(boardMember);

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
        ShariahAdapterRegistry reg = new ShariahAdapterRegistry(boardMember);

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
        ShariahAdapterRegistry reg = new ShariahAdapterRegistry(boardMember);

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
        ShariahAdapterRegistry reg = new ShariahAdapterRegistry(boardMember);

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
        ShariahAdapterRegistry reg = new ShariahAdapterRegistry(boardMember);

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

        ShariahAdapterRegistry registry2 = new ShariahAdapterRegistry(owner);

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
