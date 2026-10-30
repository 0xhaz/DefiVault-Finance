// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ShariahVault} from "../ShariahVault.sol";
import {ShariahVaultV2} from "../ShariahVaultV2.sol";
import {ShariahAdapterRegistry} from "../ShariahAdapterRegistry.sol";
import {TreasuryModule} from "../TreasuryModule.sol";
import {CharityModule} from "../CharityModule.sol";
import {PurificationEscrow} from "../PurificationEscrow.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {MockRegistrySRF} from "./SecurityReviewFixesTest.t.sol";

interface IHookTargetN29 {
    function onTokenReceived() external;
}

/// @dev Mock USDC that notifies one configurable recipient after each credit (ERC-777 style hook).
contract HookTokenN29 is MockERC20 {
    address public hookTarget;

    constructor() MockERC20("Mock USDC", "mUSDC", 6) {}

    function setHookTarget(address t) external {
        hookTarget = t;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (to != address(0) && to == hookTarget) IHookTargetN29(to).onTokenReceived();
    }
}

/// @dev N-29 fixture: real escrow/charity/treasury wiring, non-zero charity rate (2.5%), Musharakah
///      share (10%) and hurdle (4%/yr on a 2_000e6 principal). alice and bob each hold 1_000e6.
abstract contract TaskN29Base is Test {
    address internal owner = makeAddr("owner");
    address internal manager = makeAddr("manager");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal stranger = makeAddr("stranger");
    address internal charityWallet = makeAddr("charityWallet");
    uint32 internal constant DOM = 26;
    uint256 internal constant DEP = 1_000e6;
    /// @dev Rounding tolerance in asset wei for "within a few wei" comparisons.
    uint256 internal constant TOL = 10;

    HookTokenN29 internal usdc;
    MockRegistrySRF internal reg;
    ShariahAdapterRegistry internal registry;
    TreasuryModule internal treasury;
    ShariahVault internal vault;
    CharityModule internal charity;
    PurificationEscrow internal escrow;

    event MusharakahProfitClaimed(uint256 grossProfit, uint256 purified, uint256 charity, uint256 vaultShare, uint256 depositorShare);

    function _newVault() internal virtual returns (ShariahVault);

    function setUp() public virtual {
        usdc = new HookTokenN29();
        reg = new MockRegistrySRF(owner);
        registry = new ShariahAdapterRegistry(owner, owner);

        uint256 n = vm.getNonce(address(this));
        address escrowAddr = vm.computeCreateAddress(address(this), n + 3);
        address vaultAddr = vm.computeCreateAddress(address(this), n + 1);
        treasury = new TreasuryModule("Shariah", escrowAddr, address(usdc), 50, 1000, 400, vaultAddr);
        vault = _newVault();
        charity = new CharityModule(charityWallet, address(usdc), escrowAddr, owner, address(reg));
        escrow = new PurificationEscrow(
            address(vault), address(usdc), address(charity), address(treasury), owner, address(reg)
        );
        assertEq(address(vault), vaultAddr);
        assertEq(address(escrow), escrowAddr);

        vm.startPrank(owner);
        vault.setPurificationEscrow(address(escrow));
        vault.setManager(manager);
        vm.stopPrank();
        vm.prank(address(vault));
        treasury.setAdminFeeBps(0); // isolate profit accounting from time-based wakala fees

        _fund(alice);
        _fund(bob);
        _fund(carol);
        vm.prank(alice);
        vault.deposit(DEP, alice);
        vm.prank(bob);
        vault.deposit(DEP, bob);
        vm.prank(owner);
        vault.setHurdlePrincipal(2 * DEP); // non-zero hurdle base
    }

    function _fund(address who) internal {
        usdc.mint(who, 1_000_000e6);
        vm.prank(who);
        usdc.approve(address(vault), type(uint256).max);
    }

    /// @dev Let the hurdle clock run, then add realized yield to the vault.
    function _yield(uint256 y) internal {
        skip(30 days);
        usdc.mint(address(vault), y);
    }

    function _claim(uint256 g) internal {
        vm.prank(owner);
        vault.claimMusharakahProfit(g);
    }

    function _claimAll() internal returns (uint256 g) {
        g = vault.realizedProfit();
        _claim(g);
    }

    function _value(address a) internal view returns (uint256) {
        return vault.previewRedeem(vault.balanceOf(a));
    }

    function _redeemFrac(address who, uint256 num, uint256 den) internal returns (uint256 out) {
        uint256 shares = (vault.balanceOf(who) * num) / den;
        vm.prank(who);
        out = vault.redeem(shares, who, who);
    }

    /// @dev Everything routed out of the vault by distributions: charity wallet + purification + manager fees.
    function _distributed() internal view returns (uint256) {
        return usdc.balanceOf(charityWallet) + treasury.pendingFees();
    }

    function _setPurification(uint256 bps) internal {
        vm.prank(owner);
        escrow.proposePurificationRate(bps);
        skip(30 days + 1);
        vm.prank(owner);
        escrow.confirmPurificationRate();
    }

    function _logs(Vm.Log[] memory logs, bytes32 sig) internal view returns (Vm.Log[] memory out) {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == sig) ++n;
        }
        out = new Vm.Log[](n);
        n = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == sig) out[n++] = logs[i];
        }
    }
}

abstract contract TaskN29V1Mixin is TaskN29Base {
    function _newVault() internal override returns (ShariahVault) {
        return new ShariahVault(IERC20(address(usdc)), owner, DOM, address(treasury), address(0));
    }
}

abstract contract TaskN29V2Mixin is TaskN29Base {
    function _newVault() internal override returns (ShariahVault) {
        return new ShariahVaultV2(
            IERC20(address(usdc)), owner, DOM, address(treasury), address(0), address(registry)
        );
    }
}
