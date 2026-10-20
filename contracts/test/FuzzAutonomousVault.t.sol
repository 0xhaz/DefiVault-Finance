// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStrategyAdapter} from "../IStrategyAdapter.sol";
import {AutonomousVault} from "../AutonomousVault.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";

// Minimal passthrough adapter — recall sends USDC back to vault
contract FuzzMockAdapter is IStrategyAdapter {
    address public override vault;
    address public usdc;
    constructor(address v, address u) { vault = v; usdc = u; }
    function deploy(uint256 a) external override returns (uint256) { return a; }
    function recall(uint256 a) external override returns (uint256) {
        IERC20(usdc).transfer(vault, a);
        return a;
    }
    function currentValue() external view override returns (uint256) {
        return IERC20(usdc).balanceOf(address(this));
    }
    function protocolName() external pure override returns (string memory) { return "FuzzMock"; }
}

contract FuzzAutonomousVault is Test {
    MockERC20 internal usdc;
    AutonomousVault internal vault;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    uint32 internal constant SRC = 1;

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);
        vm.prank(owner);
        vault = new AutonomousVault(IERC20(address(usdc)), owner, SRC);
    }

    // -----------------------------------------------------------------------
    // Invariant: depositor always redeems ≥ their deposited amount (no loss)
    // -----------------------------------------------------------------------
    function testFuzz_deposit_redeem_roundtrip(uint96 amount) public {
        vm.assume(amount > 0 && amount <= 1_000_000e6); // up to $1B
        usdc.mint(alice, amount);
        vm.prank(alice);
        usdc.approve(address(vault), amount);

        vm.prank(alice);
        uint256 shares = vault.deposit(amount, alice);

        vm.prank(alice);
        vault.approve(address(vault), shares);
        vm.prank(alice);
        uint256 returned = vault.redeem(shares, alice, alice);

        // Due to rounding (virtual shares offset), returned may be amount or amount-1
        assertGe(returned + 1, amount, "must get back at least amount-1");
    }

    // -----------------------------------------------------------------------
    // Invariant: totalAssets = vault balance + totalDeployed at all times
    // -----------------------------------------------------------------------
    function testFuzz_totalAssets_accounting(uint96 deposit_, uint96 deploy_) public {
        uint256 depositAmt = bound(deposit_, 1e6, 10_000_000e6);
        usdc.mint(alice, depositAmt);
        vm.prank(alice);
        usdc.approve(address(vault), depositAmt);
        vm.prank(alice);
        vault.deposit(depositAmt, alice);

        uint256 maxDeploy = (depositAmt * 8_000) / 10_000;
        uint256 deployAmt = bound(deploy_, 0, maxDeploy);

        if (deployAmt > 0) {
            address strat = makeAddr("strat");
            vm.prank(owner);
            vault.deployCapital(strat, deployAmt, "");
        }

        uint256 vaultBalance = usdc.balanceOf(address(vault));
        assertEq(
            vault.totalAssets(),
            vaultBalance + vault.totalDeployed(),
            "totalAssets must equal balance + deployed"
        );
    }

    // -----------------------------------------------------------------------
    // Invariant: deployCapital always rejects amounts that exceed bps cap
    // -----------------------------------------------------------------------
    function testFuzz_deploy_cap_enforced(uint96 depositAmt_, uint96 deployAmt_) public {
        uint256 depositAmt = bound(depositAmt_, 1e6, 100_000e6);
        usdc.mint(alice, depositAmt);
        vm.prank(alice);
        usdc.approve(address(vault), depositAmt);
        vm.prank(alice);
        vault.deposit(depositAmt, alice);

        address strat = makeAddr("strat");
        uint256 maxAllowed = (vault.totalAssets() * vault.maxAllocationBps()) / 10_000;
        uint256 deployAmt = bound(deployAmt_, maxAllowed + 1, maxAllowed + 10_000e6);

        vm.prank(owner);
        vm.expectRevert(AutonomousVault.AllocationExceedsLimit.selector);
        vault.deployCapital(strat, deployAmt, "");
    }

    // -----------------------------------------------------------------------
    // Invariant: deployCapital within cap always succeeds + totalDeployed correct
    // -----------------------------------------------------------------------
    function testFuzz_deploy_within_cap_succeeds(uint96 depositAmt_, uint16 bpsFraction) public {
        uint256 depositAmt = bound(depositAmt_, 100e6, 10_000_000e6);
        // bpsFraction from 1 to 8000 of totalAssets
        uint256 fraction = bound(bpsFraction, 1, 8_000);

        usdc.mint(alice, depositAmt);
        vm.prank(alice);
        usdc.approve(address(vault), depositAmt);
        vm.prank(alice);
        vault.deposit(depositAmt, alice);

        uint256 deployAmt = (depositAmt * fraction) / 10_000;
        if (deployAmt == 0) return;

        address strat = makeAddr("strat");
        vm.prank(owner);
        vault.deployCapital(strat, deployAmt, "");

        assertEq(vault.totalDeployed(), deployAmt);
    }

    // -----------------------------------------------------------------------
    // Invariant: after returnCapital, totalDeployed decrements correctly
    // -----------------------------------------------------------------------
    function testFuzz_returnCapital_decrements(uint96 depositAmt_, uint16 bpsFraction) public {
        uint256 depositAmt = bound(depositAmt_, 100e6, 10_000_000e6);
        uint256 fraction = bound(bpsFraction, 1, 7_999);

        usdc.mint(alice, depositAmt);
        vm.prank(alice);
        usdc.approve(address(vault), depositAmt);
        vm.prank(alice);
        vault.deposit(depositAmt, alice);

        uint256 deployAmt = (depositAmt * fraction) / 10_000;
        if (deployAmt == 0) return;

        address strat = makeAddr("strat");
        vm.prank(owner);
        vault.deployCapital(strat, deployAmt, "");

        // Strategy returns capital
        vm.prank(strat);
        usdc.approve(address(vault), deployAmt);
        vm.prank(owner);
        vault.returnCapital(strat, deployAmt);

        assertEq(vault.totalDeployed(), 0);
    }

    // -----------------------------------------------------------------------
    // Fuzz: setMaxAllocationBps only accepts 0–9500
    // -----------------------------------------------------------------------
    function testFuzz_setMaxAllocationBps(uint256 bps) public {
        if (bps > 9_500) {
            vm.prank(owner);
            vm.expectRevert(AutonomousVault.InvalidBps.selector);
            vault.setMaxAllocationBps(bps);
        } else {
            vm.prank(owner);
            vault.setMaxAllocationBps(bps);
            assertEq(vault.maxAllocationBps(), bps);
        }
    }

    // -----------------------------------------------------------------------
    // Fuzz: cross-chain deploy tracks pendingCrossChain[nonce] correctly
    // -----------------------------------------------------------------------
    function testFuzz_deployCrossChain_pending(uint96 depositAmt_, uint96 crossAmt_) public {
        uint256 depositAmt = bound(depositAmt_, 1_000e6, 50_000e6);
        usdc.mint(alice, depositAmt);
        vm.prank(alice);
        usdc.approve(address(vault), depositAmt);
        vm.prank(alice);
        vault.deposit(depositAmt, alice);

        // Deploy a minimal mock messenger inline
        MockTokenMessenger messenger = new MockTokenMessenger();
        vm.prank(owner);
        vault.setTokenMessenger(address(messenger));

        uint256 maxCross = (depositAmt * vault.maxAllocationBps()) / 10_000;
        uint256 crossAmt = bound(crossAmt_, 1e6, maxCross);

        bytes32 recipient = bytes32(uint256(uint160(makeAddr("remote"))));
        vm.prank(owner);
        vault.deployCrossChain(2, recipient, crossAmt); // domain 2 != SRC=1

        assertEq(vault.pendingCrossChain(1), crossAmt);
        assertEq(vault.totalDeployed(), crossAmt);
    }

    // -----------------------------------------------------------------------
    // Fuzz: paused=true blocks all deposits regardless of amount
    // -----------------------------------------------------------------------
    function testFuzz_paused_blocks_all_deposits(uint96 amount) public {
        vm.assume(amount > 0);
        vm.prank(owner);
        vault.setPaused(true);

        usdc.mint(alice, amount);
        vm.prank(alice);
        usdc.approve(address(vault), amount);

        vm.prank(alice);
        vm.expectRevert(AutonomousVault.Paused.selector);
        vault.deposit(amount, alice);
    }

    // -----------------------------------------------------------------------
    // Fuzz: recallCapital via adapter — totalDeployed decrements by actual return
    // -----------------------------------------------------------------------
    function testFuzz_recallCapital_accounting(uint96 depositAmt_, uint16 bpsFrac) public {
        uint256 depositAmt = bound(depositAmt_, 100e6, 5_000_000e6);
        uint256 fraction = bound(bpsFrac, 100, 7_000);

        usdc.mint(alice, depositAmt);
        vm.prank(alice);
        usdc.approve(address(vault), depositAmt);
        vm.prank(alice);
        vault.deposit(depositAmt, alice);

        uint256 deployAmt = (depositAmt * fraction) / 10_000;
        if (deployAmt == 0) return;

        FuzzMockAdapter adapter = new FuzzMockAdapter(address(vault), address(usdc));
        vm.prank(owner);
        vault.deployCapital(address(adapter), deployAmt, "");
        assertEq(vault.totalDeployed(), deployAmt);

        vm.prank(owner);
        vault.recallCapital(address(adapter), deployAmt);

        assertEq(vault.totalDeployed(), 0);
        assertEq(usdc.balanceOf(address(vault)), depositAmt);
    }

    // -----------------------------------------------------------------------
    // Fuzz: multiple sequential deposits from different users preserve NAV
    // -----------------------------------------------------------------------
    function testFuzz_multi_depositor_fair_shares(uint64 a1, uint64 a2) public {
        uint256 amt1 = bound(a1, 1e6, 1_000_000e6);
        uint256 amt2 = bound(a2, 1e6, 1_000_000e6);
        address bob = makeAddr("bob");

        usdc.mint(alice, amt1);
        vm.prank(alice);
        usdc.approve(address(vault), amt1);
        vm.prank(alice);
        uint256 sharesA = vault.deposit(amt1, alice);

        usdc.mint(bob, amt2);
        vm.prank(bob);
        usdc.approve(address(vault), amt2);
        vm.prank(bob);
        uint256 sharesB = vault.deposit(amt2, bob);

        // Both should get shares proportional to their deposits (with at most 1-unit rounding)
        if (amt1 > 0 && amt2 > 0) {
            // ratio check: sharesA/sharesB ≈ amt1/amt2 within 1%
            // expressed as cross-multiply to avoid division: sharesA * amt2 ≈ sharesB * amt1
            uint256 lhs = sharesA * amt2;
            uint256 rhs = sharesB * amt1;
            // allow 1% deviation
            uint256 tolerance = rhs / 100 + 1;
            assertApproxEqAbs(lhs, rhs, tolerance, "share ratio must match deposit ratio");
        }
    }
}

// Inline mock messenger for cross-chain fuzz tests
contract MockTokenMessenger {
    uint64 public nextNonce = 1;
    function depositForBurnWithCaller(
        uint256, uint32, bytes32, address, bytes32
    ) external returns (uint64 nonce) {
        nonce = nextNonce++;
    }
}
