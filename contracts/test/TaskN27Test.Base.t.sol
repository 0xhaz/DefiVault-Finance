// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ShariahVault} from "../ShariahVault.sol";
import {ShariahVaultV2} from "../ShariahVaultV2.sol";
import {ShariahAdapterRegistry} from "../ShariahAdapterRegistry.sol";
import {TreasuryModule} from "../TreasuryModule.sol";
import {CharityModule} from "../CharityModule.sol";
import {PurificationEscrow} from "../PurificationEscrow.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";

/// @dev Configurable non-gold adapter for N-27. `value` is what currentValue() reports in Normal mode;
///      every other mode is a hostile / malformed valuation response.
contract AdapterN27 {
    enum Mode { Normal, Revert, GasBurn, Short, Long, Bomb, Empty }

    address public vault;
    IERC20 public token;
    uint256 public value;
    Mode public mode;
    uint256 public recallProceeds;
    uint256 public recallRemaining;

    constructor(address vault_, address token_) {
        vault = vault_;
        token = IERC20(token_);
    }

    function setValue(uint256 v) external { value = v; }
    function setMode(Mode m) external { mode = m; }
    function setRecall(uint256 proceeds_, uint256 remaining_) external {
        recallProceeds = proceeds_;
        recallRemaining = remaining_;
    }
    function approveVault() external { token.approve(vault, type(uint256).max); }

    function deploy(uint256 amount) external pure returns (uint256) { return amount; }

    function recall(uint256) external returns (uint256) {
        uint256 bal = token.balanceOf(address(this));
        uint256 p = recallProceeds > bal ? bal : recallProceeds;
        token.transfer(vault, p);
        value = recallRemaining;
        return p;
    }

    /// @dev Only consulted when linked into a gold slot.
    function isPriceSane() external pure returns (bool) { return true; }

    function protocolName() external pure returns (string memory) { return "AdapterN27"; }

    function currentValue() external view returns (uint256) {
        Mode m = mode;
        if (m == Mode.Revert) revert("adapter: hostile");
        if (m == Mode.GasBurn) {
            uint256 h;
            while (true) { h = uint256(keccak256(abi.encode(h, gasleft()))); }
        }
        if (m == Mode.Short) { assembly { return(0, 31) } }
        if (m == Mode.Long) { assembly { mstore(0, 0) mstore(32, 0) return(0, 64) } }
        if (m == Mode.Bomb) { assembly { return(0, 100000) } }
        if (m == Mode.Empty) { assembly { return(0, 0) } }
        return value;
    }
}

/// @dev Shared N-27 fixture; no test functions here. Concrete V1 / V2 variants supply vault + screening.
abstract contract TaskN27Base is Test {
    address internal owner = makeAddr("owner");
    address internal manager = makeAddr("manager");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal charityWallet = makeAddr("charityWallet");

    uint32 internal constant DOM = 26;
    uint256 internal constant D = 1_000_000e6;
    uint256 internal constant P = 100e6;

    MockERC20 internal usdc;
    ShariahAdapterRegistry internal registry;
    TreasuryModule internal treasury;
    CharityModule internal charity;
    PurificationEscrow internal escrow;
    ShariahVault internal vault;
    AdapterN27 internal a;
    AdapterN27 internal b;

    function _makeVault() internal virtual returns (ShariahVault);
    /// @dev Screen every adapter in one go (V2 needs a single 30-day timelock for the whole batch).
    function _screenBatch(address[] memory adapters) internal virtual;

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);
        registry = new ShariahAdapterRegistry(owner, owner);

        // treasury(n) -> vault(n+1) -> charity(n+2) -> escrow(n+3)
        uint256 n = vm.getNonce(address(this));
        address escrowAddr = vm.computeCreateAddress(address(this), n + 3);
        treasury = new TreasuryModule("Shariah", address(0), address(usdc), 0, 2_000, 0, owner);
        vault = _makeVault();
        charity = new CharityModule(charityWallet, address(usdc), escrowAddr, owner, address(registry));
        escrow = new PurificationEscrow(
            address(vault), address(usdc), address(charity), address(treasury), owner, address(registry)
        );
        assertEq(address(escrow), escrowAddr, "escrow address precompute");

        vm.startPrank(owner);
        treasury.setFeeSource(address(vault));
        treasury.setProfitRecorder(address(escrow));
        vault.setManager(manager);
        vault.setPurificationEscrow(address(escrow));
        vm.stopPrank();

        a = new AdapterN27(address(vault), address(usdc));
        b = new AdapterN27(address(vault), address(usdc));
        address[] memory list = new address[](2);
        list[0] = address(a);
        list[1] = address(b);
        _screenBatch(list);

        usdc.mint(alice, D);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(D, alice);
        vm.stopPrank();
    }

    function _newScreened() internal returns (AdapterN27 x) {
        x = new AdapterN27(address(vault), address(usdc));
        address[] memory list = new address[](1);
        list[0] = address(x);
        _screenBatch(list);
    }

    /// @dev Fund via the transfer-only path and mark the adapter at par.
    function _fund(AdapterN27 x, uint256 amount) internal {
        vm.prank(manager);
        vault.deployCapital(address(x), amount, "");
        x.setValue(vault.principalOf(address(x)));
    }

    function _fundedAt(uint256 i) internal view returns (address) {
        return vault.fundedAdapters(i);
    }
}

abstract contract TaskN27V1Fixture is TaskN27Base {
    function _makeVault() internal override returns (ShariahVault) {
        return new ShariahVault(IERC20(address(usdc)), owner, DOM, address(treasury), address(0));
    }

    function _screenBatch(address[] memory adapters) internal override {
        vm.startPrank(owner);
        for (uint256 i; i < adapters.length; ++i) vault.setScreened(adapters[i], true);
        vm.stopPrank();
    }
}

abstract contract TaskN27V2Fixture is TaskN27Base {
    bytes32 internal constant HASH = keccak256("SR-005");

    function _makeVault() internal override returns (ShariahVault) {
        return new ShariahVaultV2(
            IERC20(address(usdc)), owner, DOM, address(treasury), address(0), address(registry)
        );
    }

    function _screenBatch(address[] memory adapters) internal override {
        vm.startPrank(owner);
        for (uint256 i; i < adapters.length; ++i) {
            registry.proposeScreening(adapters[i], HASH, block.timestamp + 365 days);
        }
        vm.warp(block.timestamp + 30 days);
        for (uint256 i; i < adapters.length; ++i) registry.executeScreening(adapters[i]);
        vm.stopPrank();
    }
}
