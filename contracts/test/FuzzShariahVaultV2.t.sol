// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// forge-config: default.fuzz.runs = 512

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AutonomousVault}        from "../AutonomousVault.sol";
import {ShariahVault}           from "../ShariahVault.sol";
import {ShariahVaultV2}         from "../ShariahVaultV2.sol";
import {ShariahAdapterRegistry} from "../ShariahAdapterRegistry.sol";
import {TreasuryModule}         from "../TreasuryModule.sol";
import {ZakatModule}            from "../ZakatModule.sol";
import {MockERC20}              from "../test-helpers/MockERC20.sol";

/// @title FuzzShariahVaultV2
/// @notice Fuzz tests for ShariahVaultV2 and ShariahAdapterRegistry — Task E
contract FuzzShariahVaultV2 is Test {

    // ── actors ────────────────────────────────────────────────────
    address internal owner         = makeAddr("owner");
    address internal alice         = makeAddr("alice");
    address internal charityWallet = makeAddr("charity");

    // ── constants ─────────────────────────────────────────────────
    uint32  internal constant SOURCE_DOMAIN       = 26;
    bytes32 internal constant HASH                = keccak256("SR-005");
    uint256 internal constant TIMELOCK            = 30 days;
    uint256 internal constant VALID_EXPIRY_OFFSET = 365 days;
    uint256 internal constant MAX_EXPIRY_PERIOD   = 730 days;

    // ── contracts ─────────────────────────────────────────────────
    MockERC20              internal usdc;
    TreasuryModule         internal treasury;
    ZakatModule            internal zakatModule;
    ShariahAdapterRegistry internal registry;
    ShariahVaultV2         internal vault;
    ShariahVault           internal vaultV1;

    // ── adapter ───────────────────────────────────────────────────
    address internal adapter = makeAddr("mockAdapter");

    // ─────────────────────────────────────────────────────────────
    // setUp — runs before every fuzz test
    // ─────────────────────────────────────────────────────────────

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);

        vm.startPrank(owner);

        treasury = new TreasuryModule(
            "Shariah",
            address(0), // feeSource: no fee accrual when adminFeeBps=0
            address(usdc),
            0,  // adminFeeBps = 0 → fee=0 → skip accrue() call
            0,
            0,
            owner
        );

        zakatModule = new ZakatModule(charityWallet, address(usdc), address(0), owner);

        registry = new ShariahAdapterRegistry(owner);

        vault = new ShariahVaultV2(
            IERC20(address(usdc)),
            owner,
            SOURCE_DOMAIN,
            address(treasury),
            address(zakatModule),
            address(registry)
        );

        vaultV1 = new ShariahVault(
            IERC20(address(usdc)),
            owner,
            SOURCE_DOMAIN,
            address(treasury),
            address(zakatModule)
        );

        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────

    function _screenAdapter(address _adapter, uint256 expiryOffset) internal {
        // expiresAt must be after the post-warp block.timestamp to be valid.
        // Compute it relative to the timestamp AFTER the timelock warp.
        uint256 expiresAt = block.timestamp + TIMELOCK + expiryOffset;
        vm.prank(owner);
        registry.proposeScreening(_adapter, HASH, expiresAt);
        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(owner);
        registry.executeScreening(_adapter);
    }

    // ─────────────────────────────────────────────────────────────
    // 1. testFuzz_migration_roundtrip
    //    Deposit `amount` to V1, redeem all, deposit to V2.
    //    V2 shares NAV >= 99.9% of USDC redeemed.
    // ─────────────────────────────────────────────────────────────

    function testFuzz_migration_roundtrip(uint96 amount) public {
        uint256 amt = bound(uint256(amount), 1e6, 100_000e6);

        // ── V1 deposit ────────────────────────────────────────────
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(vaultV1), amt);
        uint256 v1Shares = vaultV1.deposit(amt, alice);
        vm.stopPrank();

        // ── Redeem from V1 immediately (no deployment, no fee) ────
        vm.startPrank(alice);
        uint256 usdcReceived = vaultV1.redeem(v1Shares, alice, alice);
        vm.stopPrank();

        // usdcReceived should be non-zero
        assertGt(usdcReceived, 0, "must receive USDC from V1 redeem");

        // ── V2 deposit ────────────────────────────────────────────
        vm.startPrank(alice);
        usdc.approve(address(vault), usdcReceived);
        uint256 v2Shares = vault.deposit(usdcReceived, alice);
        vm.stopPrank();

        // ── 99.9% invariant ───────────────────────────────────────
        uint256 v2Nav = vault.convertToAssets(v2Shares);
        assertGe(v2Nav, (usdcReceived * 999) / 1000, "V2 NAV must be >= 99.9% of redeemed USDC");
    }

    // ─────────────────────────────────────────────────────────────
    // 2. testFuzz_timelock_enforced
    //    For any warpTime in [0, 29 days), propose + warp + execute
    //    must revert TimelockNotElapsed.
    // ─────────────────────────────────────────────────────────────

    function testFuzz_timelock_enforced(uint256 warpTime) public {
        warpTime = bound(warpTime, 0, TIMELOCK - 1);

        uint256 expiresAt = block.timestamp + VALID_EXPIRY_OFFSET;

        vm.prank(owner);
        registry.proposeScreening(adapter, HASH, expiresAt);

        uint256 executeAfter = block.timestamp + TIMELOCK;
        vm.warp(block.timestamp + warpTime);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                ShariahAdapterRegistry.TimelockNotElapsed.selector,
                executeAfter,
                block.timestamp
            )
        );
        registry.executeScreening(adapter);
    }

    // ─────────────────────────────────────────────────────────────
    // 3. testFuzz_screened_expires
    //    Screen adapter with expiresAt = now + validitySeconds.
    //    Immediately: isScreened == true.
    //    After warp past expiresAt: isScreened == false.
    // ─────────────────────────────────────────────────────────────

    function testFuzz_screened_expires(uint256 validitySeconds) public {
        // Bound to [1 day, 730 days] — within MAX_EXPIRY_PERIOD, above zero
        // expiresAt = block.timestamp + TIMELOCK + validitySeconds in _screenAdapter.
        // Registry cap: expiresAt <= block.timestamp + MAX_EXPIRY_PERIOD.
        // After warp: block.timestamp' = block.timestamp + TIMELOCK.
        // So validitySeconds must be <= MAX_EXPIRY_PERIOD - TIMELOCK.
        uint256 maxValidity = MAX_EXPIRY_PERIOD > TIMELOCK ? MAX_EXPIRY_PERIOD - TIMELOCK : 1 days;
        validitySeconds = bound(validitySeconds, 1 days, maxValidity);

        _screenAdapter(adapter, validitySeconds);

        // Right after execute: should be screened (we are still before expiresAt)
        assertTrue(registry.isScreened(adapter), "should be screened immediately after execute");

        // Warp to exactly expiresAt — isScreened checks block.timestamp < expiresAt
        ShariahAdapterRegistry.Screening memory s = registry.getScreening(adapter);
        vm.warp(s.expiresAt);
        assertFalse(registry.isScreened(adapter), "should not be screened at expiresAt");

        // Warp one second further — still not screened
        vm.warp(s.expiresAt + 1);
        assertFalse(registry.isScreened(adapter), "should not be screened past expiresAt");
    }

    // ─────────────────────────────────────────────────────────────
    // 4. testFuzz_deployCapital_cap_respected
    //    Deploy `amount` to adapter. Sum deployed must not exceed
    //    maxAllocationBps * totalAssets / 10_000.
    //    Over-limit amounts revert AllocationExceedsLimit.
    // ─────────────────────────────────────────────────────────────

    function testFuzz_deployCapital_cap_respected(uint96 amount) public {
        uint256 amt = bound(uint256(amount), 1e6, 500e6);

        // Fund the V2 vault so totalAssets is non-trivial
        uint256 depositAmt = 1_000e6;
        usdc.mint(alice, depositAmt);
        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmt);
        vault.deposit(depositAmt, alice);
        vm.stopPrank();

        // Screen the adapter
        _screenAdapter(adapter, VALID_EXPIRY_OFFSET);

        uint256 maxAllocationBps = vault.maxAllocationBps();         // default 8000
        uint256 currentAssets    = vault.totalAssets();               // = depositAmt (nothing deployed yet)
        uint256 maxDeployable    = (currentAssets * maxAllocationBps) / 10_000;

        if (amt <= maxDeployable) {
            // Should succeed
            vm.prank(owner);
            vault.deployCapital(adapter, amt, "");
            assertGe(vault.totalDeployed(), amt, "totalDeployed should reflect deployment");
        } else {
            // Should revert AllocationExceedsLimit
            vm.prank(owner);
            vm.expectRevert(AutonomousVault.AllocationExceedsLimit.selector);
            vault.deployCapital(adapter, amt, "");
        }
    }
}
