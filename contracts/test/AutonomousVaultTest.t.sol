// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStrategyAdapter} from "../IStrategyAdapter.sol";
import {AutonomousVault} from "../AutonomousVault.sol";
import {AutonomousVaultHarness} from "../test-helpers/AutonomousVaultHarness.sol";
import {ConventionalVault} from "../ConventionalVault.sol";
import {TreasuryModule} from "../TreasuryModule.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";

// ---------------------------------------------------------------------------
// Mock token messenger — records native V2 burn calls without a return value
// ---------------------------------------------------------------------------
contract MockTokenMessenger {
    // Task M: V2 burns return no nonce; record all seven arguments instead.
    bytes public lastCall;
    function depositForBurn(uint256 amount, uint32 domain, bytes32 recipient, address token,
        bytes32 caller, uint256 maxFee, uint32 finality) external {
        lastCall = abi.encode(amount, domain, recipient, token, caller, maxFee, finality);
    }
}

// ---------------------------------------------------------------------------
// Mock MessageTransmitter — mints a fixed amount of USDC to the vault on receiveMessage (J1)
// ---------------------------------------------------------------------------
contract MockMessageTransmitterAVT {
    address public usdc;
    address public vault;
    uint256 public mintAmount;
    constructor(address usdc_, address vault_, uint256 amount_) { usdc = usdc_; vault = vault_; mintAmount = amount_; }
    function receiveMessage(bytes calldata, bytes calldata) external returns (bool) {
        MockERC20(usdc).mint(vault, mintAmount);
        return true;
    }
}

// Helper to build a minimal CCTP message for tests (matches CctpMessageDecoder offsets)
library TestCctpMsg {
    function build(uint64 nonce_, uint256 amount_, address recipient_) internal view returns (bytes memory) {
        AutonomousVault target = AutonomousVault(recipient_);
        // Task M: native 148-byte V2 header, bytes32 nonce and registered remote sender.
        uint32 remote = target.pendingCrossChainDestinationDomain(1);
        bytes memory header = abi.encodePacked(
            uint32(1), remote, target.localDomain(), bytes32(uint256(nonce_)),
            target.remoteTokenMessenger(remote), bytes32(uint256(uint160(target.tokenMessenger()))),
            bytes32(uint256(uint160(recipient_))), uint32(2000), uint32(2000) // destinationCaller = vault
        );
        // BurnMessageV2 body: 228 bytes (version+burnToken+mintRecipient+amount+
        //   messageSender+maxFee+feeExecuted+expirationBlock = 4+32+32+32+32+32+32+32).
        bytes memory body = new bytes(228);
        body[3] = 0x01; // Task M: native BurnMessageV2 version.
        bytes32 rw = bytes32(uint256(uint160(recipient_)));
        for (uint256 i = 0; i < 32; i++) body[36 + i] = rw[i];
        bytes32 aw = bytes32(amount_);
        for (uint256 i = 0; i < 32; i++) body[68 + i] = aw[i];
        // maxFee at [132..163], feeExecuted at [164..195] — both zero (Standard Transfer)
        return abi.encodePacked(header, body);
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

    // Shortening an active schedule must checkpoint remaining profit instead of moving its start into the future.
    function test_profitStreaming_shortenActivePeriod_keepsNavAndDepositsLive() public {
        AutonomousVaultHarness harness = new AutonomousVaultHarness(IERC20(address(usdc)), owner, SOURCE_DOMAIN);
        usdc.mint(address(harness), 300e6);
        vm.prank(owner);
        harness.lockProfit(300e6);
        skip(1 days);
        assertEq(harness.totalAssets(), 100e6);
        vm.prank(owner);
        harness.setProfitUnlockPeriod(1 days);
        assertEq(harness.lockedProfit(), 200e6);
        assertEq(harness.unlockedAt(), block.timestamp + 1 days);
        assertEq(harness.totalAssets(), 100e6);
        usdc.mint(alice, 10e6);
        vm.startPrank(alice);
        usdc.approve(address(harness), 10e6);
        harness.deposit(10e6, alice);
        vm.stopPrank();
        assertEq(harness.totalAssets(), 110e6);
        skip(12 hours);
        assertEq(harness.totalAssets(), 210e6);
        skip(12 hours);
        assertEq(harness.totalAssets(), 310e6);
    }

    // N-15 preserves streaming coverage via a test-only subclass, never a production base entry point.
    function test_profitStreaming_harnessOnly() public {
        AutonomousVaultHarness harness = new AutonomousVaultHarness(IERC20(address(usdc)), owner, SOURCE_DOMAIN);
        usdc.mint(address(harness), 300e6);
        vm.prank(owner);
        harness.lockProfit(300e6);
        assertEq(harness.totalAssets(), 0);
        skip(1.5 days);
        assertEq(harness.totalAssets(), 150e6);
        skip(1.5 days);
        assertEq(harness.totalAssets(), 300e6);
        vm.prank(owner);
        (bool ok,) = address(vault).call(abi.encodeWithSignature("lockProfit(uint256)", 1));
        assertFalse(ok, "plain base has no external lockProfit");
    }

    // N-15 preserves ConventionalVault's former inherited locking and proceeds-based recall semantics.
    function test_conventionalBaseSemantics_unchanged() public {
        TreasuryModule treasury = new TreasuryModule("Conventional", address(0), address(usdc), 0, 0, 0, owner);
        ConventionalVault conventional = new ConventionalVault(IERC20(address(usdc)), owner, SOURCE_DOMAIN, address(treasury));
        usdc.mint(address(conventional), 1_000e6);
        vm.prank(owner);
        conventional.lockProfit(100e6);
        assertEq(conventional.totalAssets(), 900e6);
        skip(3 days);
        MockAdapter adapter = new MockAdapter(address(conventional), address(usdc));
        vm.prank(owner);
        conventional.deployCapital(address(adapter), 500e6, "");
        vm.prank(owner);
        conventional.recallCapital(address(adapter), 400e6);
        assertEq(conventional.totalDeployed(), 100e6);
        assertEq(conventional.totalAssets(), 1_000e6);
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
        // PR3.3: maxPendingCrossChainBps = 2000 (20% of 1000e6 = 200e6 cap).
        // Use 150e6 which is within the 20% cap.
        vault.deployCrossChain(DEST_DOMAIN, recipient, 150e6);

        assertEq(vault.totalDeployed(), 150e6, "totalDeployed should be 150e6");
        // nonce 1 was used by the messenger
        assertEq(vault.pendingCrossChain(1), 150e6, "pendingCrossChain[1] should be 150e6");
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
    // test_settleCrossChain — J1: uses settleCrossChainWithMessage (atomic path)
    // -----------------------------------------------------------------------
    function test_settleCrossChain() public {
        _fund(alice, 1_000e6);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        vm.prank(owner);
        vault.setTokenMessenger(address(messenger));

        bytes32 recipient = bytes32(uint256(uint160(makeAddr("remoteVault"))));
        vm.prank(owner);
        // PR3.3: use 150e6 (within 20% cap of 1000e6)
        vault.deployCrossChain(DEST_DOMAIN, recipient, 150e6);
        assertEq(vault.totalDeployed(), 150e6);

        // J1: deploy a mock transmitter that mints 150e6 on receiveMessage.
        MockMessageTransmitterAVT transmitter =
            new MockMessageTransmitterAVT(address(usdc), address(vault), 150e6);
        vm.prank(owner);
        vault.setMessageTransmitter(address(transmitter));
        vm.prank(owner);
        vault.setRemoteTokenMessenger(DEST_DOMAIN, bytes32(uint256(0xCC7)));

        bytes memory msg_  = TestCctpMsg.build(99, 150e6, address(vault));
        vm.prank(owner);
        vault.settleCrossChainWithMessage(1, msg_, "");

        assertEq(vault.pendingCrossChain(1), 0, "pending should be cleared");
    }

    // -----------------------------------------------------------------------
    // test_settleCrossChain_wrong_nonce — J1: write-off path with wrong nonce
    // -----------------------------------------------------------------------
    function test_settleCrossChain_wrong_nonce() public {
        _fund(alice, 1_000e6);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        vm.prank(owner);
        vault.setTokenMessenger(address(messenger));

        bytes32 recipient = bytes32(uint256(uint160(makeAddr("remoteVault"))));
        vm.prank(owner);
        // PR3.3: use 150e6 (within 20% cap of 1000e6)
        vault.deployCrossChain(DEST_DOMAIN, recipient, 150e6);

        // Write-off with unused nonce 99 reverts NonceMismatch.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.NonceMismatch.selector, uint64(99), uint64(0)));
        vault.settleCrossChain(99, 0); // J1: write-off only; received must be 0
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
