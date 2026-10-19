// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStrategyAdapter} from "../IStrategyAdapter.sol";
import {AutonomousVault} from "../AutonomousVault.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";

// ---------------------------------------------------------------------------
// Mock token messenger — returns a fixed nonce and accepts burn calls
// ---------------------------------------------------------------------------
contract MockTokenMessenger {
    uint64 public nextNonce = 1;

    function depositForBurnWithCaller(
        uint256 /*amount*/,
        uint32 /*destinationDomain*/,
        bytes32 /*mintRecipient*/,
        address /*burnToken*/,
        bytes32 /*destinationCaller*/
    ) external returns (uint64 nonce) {
        nonce = nextNonce++;
    }
}

// ---------------------------------------------------------------------------
// Mock adapter that holds USDC and can be recalled
// ---------------------------------------------------------------------------
contract MockAdapter is IStrategyAdapter {
    address public override vault;
    address public usdc;

    constructor(address vault_, address usdc_) {
        vault = vault_;
        usdc = usdc_;
    }

    function deploy(uint256 amount) external override returns (uint256) {
        // tokens are sent by the vault via deployCapital; just accept them
        return amount;
    }

    function recall(uint256 amount) external override returns (uint256) {
        // transfer back to vault
        IERC20(usdc).transfer(vault, amount);
        return amount;
    }

    function currentValue() external view override returns (uint256) {
        return IERC20(usdc).balanceOf(address(this));
    }

    function protocolName() external pure override returns (string memory) {
        return "MockAdapter";
    }
}

// ---------------------------------------------------------------------------
// Test contract
// ---------------------------------------------------------------------------
contract AutonomousVaultTest is Test {
    MockERC20 internal usdc;
    AutonomousVault internal vault;
    MockTokenMessenger internal messenger;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal random = makeAddr("random");

    uint32 internal constant SOURCE_DOMAIN = 1;
    uint32 internal constant DEST_DOMAIN = 6; // different from 1

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);
        vm.prank(owner);
        vault = new AutonomousVault(IERC20(address(usdc)), owner, SOURCE_DOMAIN);
        messenger = new MockTokenMessenger();
    }

    // -----------------------------------------------------------------------
    // Helper: give `who` `amount` USDC and approve vault
    // -----------------------------------------------------------------------
    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(vault), amount);
    }

    // -----------------------------------------------------------------------
    // test_deposit_and_withdraw
    // -----------------------------------------------------------------------
    function test_deposit_and_withdraw() public {
        _fund(alice, 1_000e6);

        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e6, alice);
        assertGt(shares, 0, "shares should be nonzero");
        assertEq(usdc.balanceOf(address(vault)), 1_000e6);

        vm.prank(alice);
        vault.approve(address(vault), shares);

        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);
        assertEq(assets, 1_000e6, "should get back 1000e6");
        assertEq(usdc.balanceOf(alice), 1_000e6);
    }

    // -----------------------------------------------------------------------
    // test_deployCapital_basic
    // -----------------------------------------------------------------------
    function test_deployCapital_basic() public {
        _fund(alice, 1_000e6);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        address strategy = makeAddr("strategy");
        vm.prank(owner);
        vault.deployCapital(strategy, 800e6, "");

        assertEq(vault.totalDeployed(), 800e6, "totalDeployed should be 800e6");
        assertEq(usdc.balanceOf(strategy), 800e6);
    }

    // -----------------------------------------------------------------------
    // test_deployCapital_exceeds_cap (80% of 1000e6 = 800e6; 810e6 reverts)
    // -----------------------------------------------------------------------
    function test_deployCapital_exceeds_cap() public {
        _fund(alice, 1_000e6);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        address strategy = makeAddr("strategy");
        vm.prank(owner);
        vm.expectRevert(AutonomousVault.AllocationExceedsLimit.selector);
        vault.deployCapital(strategy, 810e6, "");
    }

    // -----------------------------------------------------------------------
    // test_deployCapital_only_manager_or_owner
    // -----------------------------------------------------------------------
    function test_deployCapital_only_manager_or_owner() public {
        _fund(alice, 1_000e6);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        vm.prank(random);
        vm.expectRevert(AutonomousVault.NotManager.selector);
        vault.deployCapital(makeAddr("strat"), 100e6, "");
    }

    // -----------------------------------------------------------------------
    // test_returnCapital
    // -----------------------------------------------------------------------
    function test_returnCapital() public {
        _fund(alice, 1_000e6);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        address strategy = makeAddr("strategy");
        vm.prank(owner);
        vault.deployCapital(strategy, 800e6, "");
        assertEq(vault.totalDeployed(), 800e6);

        // strategy approves vault to pull back
        vm.prank(strategy);
        usdc.approve(address(vault), 800e6);

        vm.prank(owner);
        vault.returnCapital(strategy, 800e6);

        assertEq(vault.totalDeployed(), 0, "totalDeployed should be 0");
        assertEq(usdc.balanceOf(address(vault)), 1_000e6, "vault should have all USDC back");
    }

    // -----------------------------------------------------------------------
    // test_recallCapital_via_adapter
    // -----------------------------------------------------------------------
    function test_recallCapital_via_adapter() public {
        _fund(alice, 1_000e6);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        MockAdapter adapter = new MockAdapter(address(vault), address(usdc));

        vm.prank(owner);
        vault.deployCapital(address(adapter), 800e6, "");
        assertEq(vault.totalDeployed(), 800e6);

        // Adapter now holds 800e6 USDC; recallCapital triggers adapter.recall()
        vm.prank(owner);
        vault.recallCapital(address(adapter), 800e6);

        assertEq(vault.totalDeployed(), 0, "totalDeployed should be 0 after recall");
        assertEq(usdc.balanceOf(address(vault)), 1_000e6, "vault should have all USDC back");
    }

    // -----------------------------------------------------------------------
    // test_deployCrossChain_basic
    // -----------------------------------------------------------------------
    function test_deployCrossChain_basic() public {
        _fund(alice, 1_000e6);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        vm.prank(owner);
        vault.setTokenMessenger(address(messenger));

        bytes32 recipient = bytes32(uint256(uint160(makeAddr("remoteVault"))));
        vm.prank(owner);
        vault.deployCrossChain(DEST_DOMAIN, recipient, 500e6);

        assertEq(vault.totalDeployed(), 500e6, "totalDeployed should be 500e6");
        // nonce 1 was used by the messenger
        assertEq(vault.pendingCrossChain(1), 500e6, "pendingCrossChain[1] should be 500e6");
    }

    // -----------------------------------------------------------------------
    // test_deployCrossChain_same_domain_reverts
    // -----------------------------------------------------------------------
    function test_deployCrossChain_same_domain_reverts() public {
        _fund(alice, 1_000e6);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        vm.prank(owner);
        vault.setTokenMessenger(address(messenger));

        bytes32 recipient = bytes32(uint256(uint160(makeAddr("remoteVault"))));
        vm.prank(owner);
        vm.expectRevert(AutonomousVault.SameDomainDeploy.selector);
        vault.deployCrossChain(SOURCE_DOMAIN, recipient, 500e6);
    }

    // -----------------------------------------------------------------------
    // test_deployCrossChain_not_configured
    // -----------------------------------------------------------------------
    function test_deployCrossChain_not_configured() public {
        _fund(alice, 1_000e6);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        // tokenMessenger is still address(0)
        bytes32 recipient = bytes32(uint256(uint160(makeAddr("remoteVault"))));
        vm.prank(owner);
        vm.expectRevert(AutonomousVault.CrossChainNotConfigured.selector);
        vault.deployCrossChain(DEST_DOMAIN, recipient, 500e6);
    }

    // -----------------------------------------------------------------------
    // test_settleCrossChain
    // -----------------------------------------------------------------------
    function test_settleCrossChain() public {
        _fund(alice, 1_000e6);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        vm.prank(owner);
        vault.setTokenMessenger(address(messenger));

        bytes32 recipient = bytes32(uint256(uint160(makeAddr("remoteVault"))));
        vm.prank(owner);
        vault.deployCrossChain(DEST_DOMAIN, recipient, 500e6);
        assertEq(vault.totalDeployed(), 500e6);

        // Simulate USDC bridged back: mint 500e6 to vault
        usdc.mint(address(vault), 500e6);

        vm.prank(owner);
        vault.settleCrossChain(1);

        assertEq(vault.totalDeployed(), 0, "totalDeployed should be 0 after settlement");
        assertEq(vault.pendingCrossChain(1), 0, "pending should be cleared");
    }

    // -----------------------------------------------------------------------
    // test_settleCrossChain_wrong_nonce
    // -----------------------------------------------------------------------
    function test_settleCrossChain_wrong_nonce() public {
        _fund(alice, 1_000e6);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        vm.prank(owner);
        vault.setTokenMessenger(address(messenger));

        bytes32 recipient = bytes32(uint256(uint160(makeAddr("remoteVault"))));
        vm.prank(owner);
        vault.deployCrossChain(DEST_DOMAIN, recipient, 500e6);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.NonceMismatch.selector, uint64(99)));
        vault.settleCrossChain(99);
    }

    // -----------------------------------------------------------------------
    // test_paused_deposit_reverts
    // -----------------------------------------------------------------------
    function test_paused_deposit_reverts() public {
        vm.prank(owner);
        vault.setPaused(true);

        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), 1_000e6);

        vm.prank(alice);
        vm.expectRevert(AutonomousVault.Paused.selector);
        vault.deposit(1_000e6, alice);
    }

    // -----------------------------------------------------------------------
    // test_setMaxAllocationBps_over_9500_reverts
    // -----------------------------------------------------------------------
    function test_setMaxAllocationBps_over_9500_reverts() public {
        vm.prank(owner);
        vm.expectRevert(AutonomousVault.InvalidBps.selector);
        vault.setMaxAllocationBps(9_501);
    }

    // -----------------------------------------------------------------------
    // test_decimals_offset — share decimals = asset.decimals() + 6
    // -----------------------------------------------------------------------
    function test_decimals_offset() public view {
        // USDC has 6 decimals; offset is 6 → share decimals = 12
        assertEq(vault.decimals(), 12, "vault share decimals should be 12");
    }

    // -----------------------------------------------------------------------
    // test_inflation_attack_protection
    // -----------------------------------------------------------------------
    function test_inflation_attack_protection() public {
        // Attacker donates 1e6-1 USDC directly to vault BEFORE first deposit
        usdc.mint(address(vault), 1e6 - 1);

        // Second depositor deposits 1e6 USDC
        _fund(bob, 1e6);
        vm.prank(bob);
        uint256 bobShares = vault.deposit(1e6, bob);

        // First depositor (alice) deposits 1e6 USDC after donation
        _fund(alice, 1e6);
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(1e6, alice);

        // Alice should get at least 99% of what bob got (fair shares)
        // With _decimalsOffset=6, the virtual shares make the attack ineffective
        assertGt(aliceShares, (bobShares * 99) / 100, "alice should receive fair shares");
    }

    // -----------------------------------------------------------------------
    // test_max_allocation_boundary — exactly at 80% succeeds, 80%+1 reverts
    // -----------------------------------------------------------------------
    function test_max_allocation_boundary() public {
        _fund(alice, 1_000e6);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        address strategy = makeAddr("strategy");

        // 801e6 = 80.1% of 1000e6 → should revert
        vm.prank(owner);
        vm.expectRevert(AutonomousVault.AllocationExceedsLimit.selector);
        vault.deployCapital(strategy, 801e6, "");

        // 800e6 = exactly 80% → should succeed
        vm.prank(owner);
        vault.deployCapital(strategy, 800e6, "");
        assertEq(vault.totalDeployed(), 800e6);
    }

    // -----------------------------------------------------------------------
    // test_manager_can_deploy
    // -----------------------------------------------------------------------
    function test_manager_can_deploy() public {
        address mgr = makeAddr("manager");
        vm.prank(owner);
        vault.setManager(mgr);

        _fund(alice, 1_000e6);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        vm.prank(mgr);
        vault.deployCapital(makeAddr("strategy"), 500e6, "");
        assertEq(vault.totalDeployed(), 500e6);
    }
}
