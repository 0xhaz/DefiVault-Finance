// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ShariahVault}           from "../ShariahVault.sol";
import {ShariahVaultV2}         from "../ShariahVaultV2.sol";
import {ShariahAdapterRegistry} from "../ShariahAdapterRegistry.sol";
import {TreasuryModule}         from "../TreasuryModule.sol";
import {ZakatModule}            from "../ZakatModule.sol";
import {MockERC20}              from "../test-helpers/MockERC20.sol";

/// @title ShariahVaultV2Test
/// @notice Unit tests for ShariahVaultV2 — Task E
contract ShariahVaultV2Test is Test {

    // ── actors ────────────────────────────────────────────────────
    address internal owner        = makeAddr("owner");
    address internal alice        = makeAddr("alice");
    address internal charityWallet = makeAddr("charity");

    // ── constants ─────────────────────────────────────────────────
    uint32 internal constant SOURCE_DOMAIN = 26;
    bytes32 internal constant HASH         = keccak256("SR-005");
    uint256 internal constant TIMELOCK     = 30 days;
    uint256 internal constant VALID_EXPIRY_OFFSET = 365 days;
    uint256 internal constant INITIAL_DEPOSIT = 1_000e6;

    // ── contracts ─────────────────────────────────────────────────
    MockERC20              internal usdc;
    TreasuryModule         internal treasury;
    ZakatModule            internal zakatModule;
    ShariahAdapterRegistry internal registry;
    ShariahVaultV2         internal vault;
    ShariahVault           internal vaultV1;

    // ── adapter (plain address — deployCapital only safeTransfers to it) ─
    address internal adapter = makeAddr("mockAdapter");

    // ─────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────

    /// @dev Screen `adapter` in the registry: propose → warp 30 days → execute.
    /// @param expiryOffset  Seconds from current block.timestamp for expiresAt.
    function _screenAdapter(address _adapter, uint256 expiryOffset) internal {
        uint256 expiresAt = block.timestamp + expiryOffset;
        vm.prank(owner);
        registry.proposeScreening(_adapter, HASH, expiresAt);
        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(owner);
        registry.executeScreening(_adapter);
    }

    // ─────────────────────────────────────────────────────────────
    // setUp — runs before every test
    // ─────────────────────────────────────────────────────────────

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);

        vm.startPrank(owner);

        // TreasuryModule with adminFeeBps=0 so _accrueWakalaFee() computes fee=0
        // and skips the accrue() call (which requires feeSource == vault address).
        // This allows us to deploy the treasury before the vault.
        treasury = new TreasuryModule(
            "Shariah",
            address(0),   // feeSource: not needed when adminFeeBps=0
            address(usdc),
            0,    // adminFeeBps = 0 → no fee accrual → no feeSource check
            0,    // musharakahShareBps
            0,    // hurdleRateBps
            owner
        );

        zakatModule = new ZakatModule(charityWallet, address(usdc), address(0), owner);

        registry = new ShariahAdapterRegistry(owner);
        // owner gets boardRole automatically

        vault = new ShariahVaultV2(
            IERC20(address(usdc)),
            owner,
            SOURCE_DOMAIN,
            address(treasury),
            address(zakatModule),
            address(registry)
        );

        // V1 vault for migration tests
        vaultV1 = new ShariahVault(
            IERC20(address(usdc)),
            owner,
            SOURCE_DOMAIN,
            address(treasury),
            address(zakatModule)
        );

        vm.stopPrank();

        // Fund vault with 1000e6 USDC via deposit
        usdc.mint(alice, INITIAL_DEPOSIT);
        vm.startPrank(alice);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, alice);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────
    // 1. deployCapital to unscreened adapter reverts NotScreened
    // ─────────────────────────────────────────────────────────────

    function test_deployCapital_unscreened_reverts() public {
        // `adapter` address is not in the registry at all
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(ShariahVaultV2.NotScreened.selector, adapter)
        );
        vault.deployCapital(adapter, 100e6, "");
    }

    // ─────────────────────────────────────────────────────────────
    // 2. deployCapital to screened, non-expired adapter succeeds
    // ─────────────────────────────────────────────────────────────

    function test_deployCapital_screened_succeeds() public {
        _screenAdapter(adapter, VALID_EXPIRY_OFFSET);

        uint256 balBefore = usdc.balanceOf(adapter);

        vm.prank(owner);
        vault.deployCapital(adapter, 100e6, "");

        assertEq(usdc.balanceOf(adapter) - balBefore, 100e6, "adapter should receive USDC");
        assertEq(vault.totalDeployed(), 100e6);
    }

    // ─────────────────────────────────────────────────────────────
    // 3. deployCapital past expiresAt reverts ScreeningExpired
    // ─────────────────────────────────────────────────────────────

    function test_deployCapital_expired_reverts() public {
        uint256 expiresAt = block.timestamp + VALID_EXPIRY_OFFSET;
        _screenAdapter(adapter, VALID_EXPIRY_OFFSET);

        // Warp past expiresAt
        vm.warp(expiresAt + 1);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(ShariahVaultV2.ScreeningExpired.selector, adapter, expiresAt)
        );
        vault.deployCapital(adapter, 100e6, "");
    }

    // ─────────────────────────────────────────────────────────────
    // 4. deployCapital when hash is zero — isScreened false → NotScreened
    //    (This verifies test_deployCapital_unscreened_reverts covers the zero-hash case.)
    // ─────────────────────────────────────────────────────────────

    function test_deployCapital_hash_zero_reverts() public {
        // An adapter with zero hash in the screening struct is equivalent to unscreened.
        // getScreening returns zeroed struct → pronouncementHash == 0 → NotScreened.
        assertFalse(registry.isScreened(adapter), "fresh adapter must not be screened");

        ShariahAdapterRegistry.Screening memory s = registry.getScreening(adapter);
        assertEq(s.pronouncementHash, bytes32(0), "hash must be zero for unregistered adapter");

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(ShariahVaultV2.NotScreened.selector, adapter)
        );
        vault.deployCapital(adapter, 100e6, "");
    }

    // ─────────────────────────────────────────────────────────────
    // 5. name and symbol
    // ─────────────────────────────────────────────────────────────

    function test_name_and_symbol() public view {
        assertEq(vault.name(),   "Shariah Vault V2 Share");
        assertEq(vault.symbol(), "svUSDCv2");
    }

    // ─────────────────────────────────────────────────────────────
    // 6. setRegistry updates the registry address
    // ─────────────────────────────────────────────────────────────

    function test_setRegistry_updates() public {
        ShariahAdapterRegistry newRegistry = new ShariahAdapterRegistry(owner);

        vm.prank(owner);
        vault.setRegistry(address(newRegistry));

        assertEq(address(vault.registry()), address(newRegistry));
    }

    // ─────────────────────────────────────────────────────────────
    // 7. setRegistry by non-owner reverts OwnableUnauthorizedAccount
    // ─────────────────────────────────────────────────────────────

    function test_setRegistry_nonOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice)
        );
        vault.setRegistry(address(0));
    }

    // ─────────────────────────────────────────────────────────────
    // 8. V1 vault still accessible via screened[] mapping
    // ─────────────────────────────────────────────────────────────

    function test_v1_still_accessible() public {
        // Fund V1 vault
        usdc.mint(alice, INITIAL_DEPOSIT);
        vm.startPrank(alice);
        usdc.approve(address(vaultV1), INITIAL_DEPOSIT);
        vaultV1.deposit(INITIAL_DEPOSIT, alice);
        vm.stopPrank();

        // V1 uses screened[] mapping — screen the adapter via setScreened
        vm.prank(owner);
        vaultV1.setScreened(adapter, true);

        uint256 balBefore = usdc.balanceOf(adapter);

        vm.prank(owner);
        vaultV1.deployCapital(adapter, 100e6, "");

        assertGt(usdc.balanceOf(adapter) - balBefore, 0, "V1 should deploy capital successfully");
    }

    // ─────────────────────────────────────────────────────────────
    // 9. Migration round-trip value: V1 deposit → redeem → V2 deposit
    //    V2 shares NAV >= 99.9% of USDC redeemed
    // ─────────────────────────────────────────────────────────────

    function test_migration_roundtrip_value() public {
        uint256 depositAmount = 1_000e6;

        // ── V1 deposit ────────────────────────────────────────────
        usdc.mint(alice, depositAmount);
        vm.startPrank(alice);
        usdc.approve(address(vaultV1), depositAmount);
        uint256 v1Shares = vaultV1.deposit(depositAmount, alice);
        vm.stopPrank();

        // ── Immediately redeem from V1 at NAV ─────────────────────
        vm.startPrank(alice);
        uint256 usdcReceived = vaultV1.redeem(v1Shares, alice, alice);
        vm.stopPrank();

        // ── V2 deposit with the redeemed USDC ────────────────────
        vm.startPrank(alice);
        usdc.approve(address(vault), usdcReceived);
        uint256 v2Shares = vault.deposit(usdcReceived, alice);
        vm.stopPrank();

        // ── Check: NAV of V2 shares >= 99.9% of usdcReceived ─────
        uint256 v2Nav = vault.convertToAssets(v2Shares);
        // 99.9% = amount * 999 / 1000
        assertGe(v2Nav, (usdcReceived * 999) / 1000, "V2 NAV must be >= 99.9% of redeemed USDC");
    }
}
