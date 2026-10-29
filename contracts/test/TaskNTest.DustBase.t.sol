// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ShariahVault}           from "../ShariahVault.sol";
import {TreasuryModule}         from "../TreasuryModule.sol";
import {GoldExchangeAdapter}    from "../adapters/GoldExchangeAdapter.sol";
import {MockERC20}              from "../test-helpers/MockERC20.sol";
import {MockAllocatedGold}      from "../test-helpers/MockAllocatedGold.sol";
import {MockXauUsdAggregator}   from "../test-helpers/MockXauUsdAggregator.sol";
import {MockGoldRouterN}        from "./TaskNTest.Base.t.sol";

/// @dev N2 fixture. A ShariahVault flavour (V1 or V2) is created by the concrete subclass
///      via `_deployVault()`. Starts with ZERO assets; use `_setAssets` to move NAV.
///      No test/fuzz/invariant functions here.
abstract contract TaskNDustBase is Test {
    using stdStorage for StdStorage;

    // Synthetic adapter positions must include funded cost now that materiality is principal-based.
    function _setPrincipal(address adapter, uint256 principal) internal {
        uint256 old = v.principalOf(adapter);
        stdstore.target(address(v)).sig("principalOf(address)").with_key(adapter).checked_write(principal);
        stdstore.target(address(v)).sig("totalDeployed()").checked_write(v.totalDeployed() - old + principal);
    }
    function _setAggregateDeployed(uint256 amount) internal {
        stdstore.target(address(v)).sig("totalDeployed()").checked_write(amount);
    }

    address internal owner       = makeAddr("owner");
    address internal manager     = makeAddr("manager");
    address internal alice       = makeAddr("alice");
    address internal stranger    = makeAddr("stranger");
    address internal boardMember = makeAddr("boardMember");

    uint32  internal constant SOURCE_DOMAIN = 26;
    uint256 internal constant DUST_TIMELOCK = 30 days;
    uint256 internal constant PAXG_PRICE    = 3_300e6;

    MockERC20             internal usdc;
    MockAllocatedGold     internal paxg;
    MockXauUsdAggregator  internal oracle;
    MockGoldRouterN       internal router;
    TreasuryModule        internal treasury;
    GoldExchangeAdapter   internal goldAdapter;
    ShariahVault          internal v;

    /// @dev Concrete subclass creates `v` (and any registry) with `owner` as vault owner.
    function _deployVault() internal virtual;
    /// @dev The account that must be accepted as board by this vault flavour.
    function _board() internal view virtual returns (address);
    /// @dev Accounts that must be rejected with NotBoardRole.
    function _denied() internal view virtual returns (address[] memory);

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        usdc   = new MockERC20("Mock USDC", "mUSDC", 6);
        paxg   = new MockAllocatedGold();
        oracle = new MockXauUsdAggregator();
        router = new MockGoldRouterN(address(usdc), PAXG_PRICE);
        paxg.mint(address(router), 1_000_000e18);
        usdc.mint(address(router), 50_000_000e6);

        treasury = new TreasuryModule("Shariah", address(0), address(usdc), 0, 0, 0, owner);
        _deployVault();

        vm.startPrank(owner);
        v.setManager(manager);
        goldAdapter = new GoldExchangeAdapter(
            address(usdc), address(paxg), address(router), 3000, address(v), owner, address(oracle)
        );
        v.setGoldSpreadAdapter(address(goldAdapter));
        vm.stopPrank();
    }

    /// @dev Move vault NAV (totalAssets) to exactly `target` by donating / burning USDC held by the vault.
    function _setAssets(uint256 target) internal {
        uint256 cur = v.totalAssets();
        if (target > cur) usdc.mint(address(v), target - cur);
        else if (target < cur) usdc.burn(address(v), cur - target);
        assertEq(v.totalAssets(), target, "NAV set");
    }

    function _cap(uint256 assets) internal pure returns (uint256 c) {
        c = (assets * 50) / 10_000;
        if (c < 1e6) c = 1e6;
    }

    function _pending() internal view returns (uint256 newValue, uint256 executeAfter, bool exists) {
        return v.pendingDustThreshold();
    }

    function _propose(uint256 value) internal {
        vm.prank(_board());
        v.proposeDustThreshold(value);
    }

    function _confirm() internal {
        vm.prank(_board());
        v.confirmDustThreshold();
    }

    function _cancel() internal {
        vm.prank(_board());
        v.cancelDustThreshold();
    }

    /// @dev Open a gold position of `usdcIn` in S2-H directly (adapter is vault-gated, so prank the vault).
    function _openGold(uint256 usdcIn) internal {
        oracle.setPrice(int256(PAXG_PRICE * 100));
        usdc.mint(address(goldAdapter), usdcIn);
        vm.prank(address(v));
        goldAdapter.deploy(usdcIn);
        goldAdapter.pokePrice(); // value the position at the oracle price
        // Direct adapter execution bypasses vault bookkeeping, so seed matching principal for dust tests.
        _setPrincipal(address(goldAdapter), v.principalOf(address(goldAdapter)) + usdcIn);
    }
}
