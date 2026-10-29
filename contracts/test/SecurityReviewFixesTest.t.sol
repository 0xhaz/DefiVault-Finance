// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {AutonomousVault}       from "../AutonomousVault.sol";
import {ShariahVault}          from "../ShariahVault.sol";
import {ConventionalVault}     from "../ConventionalVault.sol";
import {TreasuryModule}        from "../TreasuryModule.sol";
import {CharityModule}         from "../CharityModule.sol";
import {PurificationEscrow}    from "../PurificationEscrow.sol";
import {HalalLPAdapter}        from "../adapters/HalalLPAdapter.sol";
import {GoldAllocationAdapter} from "../adapters/GoldAllocationAdapter.sol";
import {TestnetRegistryShortTimelock} from "../script/Rehearsal.s.sol";
import {MockERC20}             from "../test-helpers/MockERC20.sol";
import {MockXAUT}              from "../test-helpers/MockXAUT.sol";
import {MockXauUsdAggregator}  from "../test-helpers/MockXauUsdAggregator.sol";
import {MockUniswapV3PoolXAUT} from "../test-helpers/MockUniswapV3PoolXAUT.sol";
import {MockPositionManager}   from "../test-helpers/MockPositionManager.sol";

/*
 * Regression tests for the security-review fixes F-01 .. F-08.
 *
 *  F-01  PurificationEscrow returns vaultShare to the vault; vault sweepFeesToTreasury balance check
 *  F-02/F-04  AutonomousVault.settleCrossChainWithMessage header validation + setLocalDomain
 *  F-03  HalalLPAdapter slippage timelock + non-zero min amounts
 *  F-05  CharityModule.setEscrow one-shot
 *  F-06  TestnetRegistryShortTimelock mainnet guard
 *  F-07  AutonomousVault.setTokenMessenger / setMessageTransmitter zero-address guards
 *  F-08  GoldAllocationAdapter.setPool is propose-only (timelocked)
 */

// ─── Shared mocks ────────────────────────────────────────────────────────────

contract MockRegistrySRF {
    address public board;
    constructor(address b) { board = b; }
    function isBoard(address a) external view returns (bool) { return a == board; }
}

contract MockMessengerSRF {
    // Task M: record V2's seven arguments; Circle assigns its nonce offchain.
    bytes public lastCall;
    function depositForBurn(uint256 amount, uint32 domain, bytes32 recipient, address token,
        bytes32 caller, uint256 maxFee, uint32 finality) external {
        lastCall = abi.encode(amount, domain, recipient, token, caller, maxFee, finality);
    }
}

/// @dev CCTP transmitter stub WITHOUT localDomain(): vault falls back to its stored domain.
contract MockTransmitterSRF {
    MockERC20 public immutable usdc;
    address public mintTo;
    uint256 public mintAmount;
    constructor(MockERC20 usdc_) { usdc = usdc_; }
    function arm(address to, uint256 amount) external { mintTo = to; mintAmount = amount; }
    function receiveMessage(bytes calldata, bytes calldata) external returns (bool) {
        usdc.mint(mintTo, mintAmount);
        return true;
    }
}

/// @dev Same, but reports a localDomain().
contract MockTransmitterDomainSRF is MockTransmitterSRF {
    uint32 public localDomain;
    constructor(MockERC20 usdc_, uint32 d) MockTransmitterSRF(usdc_) { localDomain = d; }
}

// ═════════════════════════════════════════════════════════════════════════════
//  F-01  PurificationEscrow → vault token return + sweepFeesToTreasury balance check
// ═════════════════════════════════════════════════════════════════════════════
contract SRF01EscrowAndSweepTest is Test {
    address internal owner         = makeAddr("owner");
    address internal charityWallet = makeAddr("charityWallet");
    address internal feeReceiver   = makeAddr("feeReceiver");
    address internal attacker      = makeAddr("attacker");
    uint32  internal constant DOMAIN = 26;

    MockERC20          internal usdc;
    MockRegistrySRF    internal reg;
    TreasuryModule     internal treasury;
    ShariahVault       internal vault;
    CharityModule      internal charity;
    PurificationEscrow internal escrow;

    TreasuryModule     internal cTreasury;
    ConventionalVault  internal cvault;

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);
        reg  = new MockRegistrySRF(owner);

        // Shariah stack: treasury(n) → vault(n+1) → charity(n+2) → escrow(n+3)
        uint256 n = vm.getNonce(address(this));
        address escrowAddr = vm.computeCreateAddress(address(this), n + 3);
        // NOTE: sweepFeesToTreasury calls treasury.claimFees (onlyOwner) as msg.sender == vault,
        // so the sweep success path requires the treasury to be OWNED BY THE VAULT.
        address vaultAddr = vm.computeCreateAddress(address(this), n + 1);
        treasury = new TreasuryModule("Shariah", escrowAddr, address(usdc), 50, 1000, 400, vaultAddr);
        vault    = new ShariahVault(IERC20(address(usdc)), owner, DOMAIN, address(treasury), address(0));
        charity  = new CharityModule(charityWallet, address(usdc), escrowAddr, owner, address(reg));
        escrow   = new PurificationEscrow(
            address(vault), address(usdc), address(charity), address(treasury), owner, address(reg)
        );
        assertEq(address(escrow), escrowAddr, "escrow address precompute");
        vm.prank(owner);
        vault.setPurificationEscrow(address(escrow));

        // Conventional stack: treasury(m) → vault(m+1); treasury feeSource = vault
        uint256 m = vm.getNonce(address(this));
        address cvaultAddr = vm.computeCreateAddress(address(this), m + 1);
        cTreasury = new TreasuryModule("Conventional", cvaultAddr, address(usdc), 50, 0, 0, cvaultAddr);
        cvault    = new ConventionalVault(IERC20(address(usdc)), owner, DOMAIN, address(cTreasury));
        assertEq(address(cvault), cvaultAddr, "cvault address precompute");
    }

    // ── executeWaterfall: end-to-end through the real vault ──────────────────

    // Principal checkpoints must reject arbitrary claims while retaining the existing funded waterfall tests.
    function test_profitCheckpoint_depositMintWithdrawRedeem() public {
        usdc.mint(address(this), 2_000e6);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e6, address(this));
        uint256 shares = vault.previewDeposit(500e6);
        uint256 mintedAssets = vault.mint(shares, address(this));
        assertEq(vault.profitBase(), 1_000e6 + mintedAssets);
        assertEq(vault.realizedProfit(), 0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.ProfitExceedsRealized.selector, 1, 0));
        vault.claimMusharakahProfit(1);
        usdc.mint(address(vault), 100e6);
        uint256 base = vault.profitBase();
        uint256 nav = vault.totalAssets();
        vault.withdraw(100e6, address(this), address(this));
        // checkpoint now shrinks by shares burned / supply; allow 1-wei virtual-share rounding
        assertApproxEqAbs(vault.profitBase(), base - base * 100e6 / nav, 2);
        base = vault.profitBase();
        nav = vault.totalAssets();
        uint256 assets = vault.redeem(vault.balanceOf(address(this)), address(this), address(this));
        assertApproxEqAbs(vault.profitBase(), base - base * assets / nav, 2);
    }

    // A successful claim checkpoints post-claim net NAV, including locked profit and pending fees.
    function test_profitCheckpoint_claimAndOverclaim() public {
        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(vault), 1_000e6);
        vault.deposit(1_000e6, address(this));
        usdc.mint(address(vault), 100e6);
        assertEq(vault.realizedProfit(), 100e6);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.ProfitExceedsRealized.selector, 100e6 + 1, 100e6));
        vault.claimMusharakahProfit(100e6 + 1);
        vm.prank(owner);
        vault.claimMusharakahProfit(100e6);
        // checkpoint counts the locked (already distributed) depositor share as well
        assertEq(vault.profitBase(), vault.totalAssets() + vault.lockedProfit());
        assertEq(vault.realizedProfit(), 0);
        assertEq(usdc.allowance(address(vault), address(escrow)), 0);
    }

    // Deployments preserve principal NAV; locks and fee accrual can only reduce available profit.
    function test_profitCheckpoint_principalWithDeploymentLocksAndFees() public {
        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(vault), 1_000e6);
        vault.deposit(1_000e6, address(this));
        vm.startPrank(owner);
        vault.setScreened(attacker, true);
        vault.deployCapital(attacker, 500e6, "");
        assertEq(vault.realizedProfit(), 0);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.ProfitExceedsRealized.selector, 100e6, 0));
        vault.lockProfit(100e6);
        vm.stopPrank();
        vm.prank(address(escrow));
        treasury.accrue(10e6);
        assertEq(vault.profitBase(), 1_000e6);
        assertEq(vault.realizedProfit(), 0);
        skip(3 days);
        assertEq(vault.realizedProfit(), 0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.ProfitExceedsRealized.selector, 1, 0));
        vault.claimMusharakahProfit(1);
    }

    function test_F01_claimReturnsVaultShareToVault() public {
        // N-20: isolate the funded waterfall return from the independently tested annual fee.
        vm.prank(address(vault));
        treasury.setAdminFeeBps(0);
        uint256 gross = 1_000e6;
        usdc.mint(address(vault), gross); // vault holds profit only (no depositor capital)
        vm.prank(owner);
        vault.setHurdlePrincipal(10_000e6);
        skip(365 days);

        vm.prank(owner);
        vault.claimMusharakahProfit(gross);

        // hurdle = 10_000e6 * 4% = 400e6; charity 2.5% = 25e6; surplus = 975e6-400e6 = 575e6; fee = 10% = 57.5e6
        assertEq(treasury.pendingFees(), 57_500_000, "pendingFees == vaultShare");
        assertEq(usdc.balanceOf(address(escrow)), 0, "escrow drained");
        assertEq(usdc.balanceOf(charityWallet), 25e6, "charity paid");
        assertEq(usdc.balanceOf(address(vault)), gross - 25e6, "vault keeps vaultShare + depositorShare");
        assertGe(usdc.balanceOf(address(vault)), treasury.pendingFees(), "vault backs pendingFees");
    }

    function test_F01_feesSweepableAfterClaim() public {
        // N-20: retain the manager-fee sweep fixture without introducing annual admin liabilities.
        vm.prank(address(vault));
        treasury.setAdminFeeBps(0);
        usdc.mint(address(vault), 1_000e6);
        vm.prank(owner);
        vault.setHurdlePrincipal(10_000e6);
        skip(365 days);
        vm.prank(owner);
        vault.claimMusharakahProfit(1_000e6);

        uint256 fees = treasury.pendingFees();
        vm.prank(owner);
        vault.sweepFeesToTreasury(feeReceiver, fees);

        assertEq(usdc.balanceOf(feeReceiver), fees);
        assertEq(treasury.pendingFees(), 0);
        assertEq(treasury.totalFeesCollected(), fees);
    }

    function test_F01_escrowForwardsDonatedDust() public {
        usdc.mint(address(escrow), 7); // stray tokens sitting in escrow
        usdc.mint(address(vault), 1_000e6);
        vm.startPrank(address(vault));
        usdc.approve(address(escrow), 1_000e6);
        escrow.executeWaterfall(1_000e6, 365 days, 10_000e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    /// @dev purified + charity + vaultShare + depositorShare == grossProfit; escrow ends at 0;
    ///      vault balance >= pendingFees.
    function testFuzz_F01_waterfallConservesAndDrainsEscrow(
        uint256 gross,
        uint256 elapsed,
        uint256 principal,
        uint256 purBps
    ) public {
        gross     = bound(gross, 1, 1_000_000_000e6);
        elapsed   = bound(elapsed, 0, 10 * 365 days);
        principal = bound(principal, 0, 1_000_000_000e6);
        purBps    = bound(purBps, 0, 1000);

        if (purBps > 0) {
            vm.prank(owner);
            escrow.proposePurificationRate(purBps);
            skip(30 days);
            vm.prank(owner);
            escrow.confirmPurificationRate();
        }

        usdc.mint(address(vault), gross);
        vm.startPrank(address(vault));
        usdc.approve(address(escrow), gross);
        (uint256 p, uint256 c, uint256 v, uint256 d) = escrow.executeWaterfall(gross, elapsed, principal);
        vm.stopPrank();

        assertEq(p + c + v + d, gross, "components sum to gross");
        assertEq(usdc.balanceOf(address(escrow)), 0, "escrow balance zero");
        assertEq(treasury.pendingFees(), v, "pendingFees == vaultShare");
        assertGe(usdc.balanceOf(address(vault)), treasury.pendingFees(), "vault balance >= pendingFees");
        assertEq(usdc.balanceOf(address(vault)), v + d, "vault received vaultShare + depositorShare");
        assertEq(usdc.balanceOf(charityWallet), p + c, "purification + charity reach charity wallet");
    }

    // ── sweepFeesToTreasury: InsufficientFeeBalance ───────────────────────────

    function test_F01_shariahSweepRevertsWhenVaultBalanceZero() public {
        vm.prank(address(escrow)); // feeSource
        treasury.accrue(100e6);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.InsufficientFeeBalance.selector, 0, 100e6));
        vault.sweepFeesToTreasury(feeReceiver, 100e6);
    }

    function test_F01_shariahSweepRevertsWhenBalanceBelowAmount() public {
        vm.prank(address(escrow));
        treasury.accrue(100e6);
        usdc.mint(address(vault), 40e6);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.InsufficientFeeBalance.selector, 40e6, 100e6));
        vault.sweepFeesToTreasury(feeReceiver, 100e6);
        assertEq(treasury.pendingFees(), 100e6, "accounting untouched on revert");
    }

    function test_F01_shariahSweepSucceedsWhenFunded() public {
        vm.prank(address(escrow));
        treasury.accrue(100e6);
        usdc.mint(address(vault), 100e6);
        vm.prank(owner);
        vault.sweepFeesToTreasury(feeReceiver, 100e6);
        assertEq(usdc.balanceOf(feeReceiver), 100e6);
        assertEq(treasury.pendingFees(), 0);
    }

    function test_F01_shariahSweepAbovePendingReverts() public {
        vm.prank(address(escrow));
        treasury.accrue(100e6);
        usdc.mint(address(vault), 500e6);
        vm.prank(owner);
        vm.expectRevert(AutonomousVault.AllocationExceedsLimit.selector);
        vault.sweepFeesToTreasury(feeReceiver, 100e6 + 1);
    }

    function test_F01_shariahSweepNonOwnerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vault.sweepFeesToTreasury(feeReceiver, 0);
    }

    function test_F01_conventionalSweepRevertsWhenVaultBalanceZero() public {
        vm.prank(address(cvault));
        cTreasury.accrue(100e6);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ConventionalVault.InsufficientFeeBalance.selector, 0, 100e6));
        cvault.sweepFeesToTreasury(feeReceiver, 100e6);
    }

    function test_F01_conventionalSweepRevertsWhenBalanceBelowAmount() public {
        vm.prank(address(cvault));
        cTreasury.accrue(100e6);
        usdc.mint(address(cvault), 99e6);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ConventionalVault.InsufficientFeeBalance.selector, 99e6, 100e6));
        cvault.sweepFeesToTreasury(feeReceiver, 100e6);
    }

    function test_F01_conventionalSweepSucceedsWhenFunded() public {
        vm.prank(address(cvault));
        cTreasury.accrue(100e6);
        usdc.mint(address(cvault), 100e6);
        vm.prank(owner);
        cvault.sweepFeesToTreasury(feeReceiver, 100e6);
        assertEq(usdc.balanceOf(feeReceiver), 100e6);
        assertEq(cTreasury.pendingFees(), 0);
    }

    function test_R2_conventionalFeesExcludedAndSweepNeutral() public {
        usdc.mint(address(this), 1_000e6);
        vm.startPrank(address(this));
        usdc.approve(address(cvault), 1_000e6);
        uint256 shares = cvault.deposit(1_000e6, address(this));
        vm.stopPrank();
        vm.prank(address(cvault));
        cTreasury.accrue(100e6);
        assertEq(cvault.totalAssets(), 900e6);
        uint256 redeemable = cvault.previewRedeem(shares);
        uint256 depositShares = cvault.previewDeposit(100e6);
        uint256 withdrawalShares = cvault.previewWithdraw(100e6);
        vm.prank(owner);
        cvault.sweepFeesToTreasury(feeReceiver, 100e6);
        assertEq(cvault.totalAssets(), 900e6);
        assertEq(cvault.previewRedeem(shares), redeemable);
        assertEq(cvault.previewDeposit(100e6), depositShares);
        assertEq(cvault.previewWithdraw(100e6), withdrawalShares);
        vm.prank(address(this));
        cvault.redeem(shares, address(this), address(this));
        assertLe(usdc.balanceOf(address(this)), 900e6);
    }

    function test_conventionalDeployment_pauseThenUnpause_preservesFeesAndAccounting() public {
        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(cvault), 1_000e6);
        cvault.deposit(1_000e6, address(this));
        skip(365 days);
        uint256 lastAccrual = cvault.lastFeeAccrualTime();
        vm.startPrank(owner);
        cvault.setPaused(true);
        vm.expectRevert(AutonomousVault.Paused.selector);
        cvault.deployCapitalWithFeeAccrual(attacker, 100e6, "");
        vm.expectRevert(AutonomousVault.Paused.selector);
        cvault.deployCapital(attacker, 100e6, "");
        assertEq(usdc.balanceOf(attacker), 0);
        assertEq(cvault.totalDeployed(), 0);
        assertEq(cvault.lastFeeAccrualTime(), lastAccrual);
        assertEq(cTreasury.pendingFees(), 0);
        cvault.setPaused(false);
        vm.expectEmit(true, false, false, true, address(cvault));
        emit AutonomousVault.CapitalDeployed(attacker, 100e6);
        cvault.deployCapitalWithFeeAccrual(attacker, 100e6, "");
        assertEq(usdc.balanceOf(attacker), 100e6);
        assertEq(cvault.totalDeployed(), 100e6);
        assertEq(cTreasury.pendingFees(), 5e6);
        assertEq(cvault.totalAssets(), 995e6);
        assertEq(cvault.lastFeeAccrualTime(), block.timestamp);
        cvault.deployCapital(attacker, 10e6, "");
        assertEq(cvault.totalDeployed(), 110e6);
        assertEq(cTreasury.pendingFees(), 5e6, "inherited path does not accrue fees");
        cvault.lockProfit(10e6);
        assertEq(cvault.totalAssets(), 985e6, "conventional locking is unchanged");
        cvault.sweepFeesToTreasury(feeReceiver, 5e6);
        assertEq(cvault.totalAssets(), 985e6, "fee sweep remains NAV neutral");
        vm.stopPrank();
    }

    function test_conventionalDeployment_authAndAllocationUnchanged() public {
        usdc.mint(address(cvault), 1_000e6);
        vm.prank(attacker);
        vm.expectRevert(AutonomousVault.NotManager.selector);
        cvault.deployCapitalWithFeeAccrual(attacker, 1e6, "");
        vm.startPrank(owner);
        vm.expectRevert(AutonomousVault.AllocationExceedsLimit.selector);
        cvault.deployCapitalWithFeeAccrual(attacker, 800e6 + 1, "");
        cvault.setManager(feeReceiver);
        vm.stopPrank();
        vm.prank(feeReceiver);
        cvault.deployCapitalWithFeeAccrual(attacker, 100e6, "");
        assertEq(cvault.totalDeployed(), 100e6);
    }

    function test_R2_conventionalAssetsFloorAtZero() public {
        usdc.mint(address(cvault), 100e6);
        vm.prank(address(cvault));
        cTreasury.accrue(100e6);
        assertEq(cvault.totalAssets(), 0);
        vm.prank(address(cvault));
        cTreasury.accrue(1);
        assertEq(cvault.totalAssets(), 0);
    }

    function test_F01_conventionalSweepNonOwnerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        cvault.sweepFeesToTreasury(feeReceiver, 0);
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  F-02 / F-04 / F-07  AutonomousVault CCTP settlement header checks + config guards
// ═════════════════════════════════════════════════════════════════════════════
contract SRF02VaultCctpTest is Test {
    address internal owner    = makeAddr("owner");
    address internal manager  = makeAddr("manager");
    address internal alice    = makeAddr("alice");
    address internal attacker = makeAddr("attacker");

    uint32  internal constant SOURCE_DOMAIN = 26;
    uint32  internal constant BURN_DOMAIN   = 3;
    uint256 internal constant SENT          = 10_000e6;

    MockERC20        internal usdc;
    MockMessengerSRF internal messenger;
    MockTransmitterSRF internal transmitter;
    AutonomousVault  internal vault;
    uint64           internal nonce;

    function setUp() public {
        usdc        = new MockERC20("Mock USDC", "mUSDC", 6);
        messenger   = new MockMessengerSRF();
        transmitter = new MockTransmitterSRF(usdc);

        vm.startPrank(owner);
        vault = new AutonomousVault(IERC20(address(usdc)), owner, SOURCE_DOMAIN);
        vault.setManager(manager);
        vault.setTokenMessenger(address(messenger));
        vault.setRemoteTokenMessenger(BURN_DOMAIN, bytes32(uint256(0xCC7)));
        vault.setMaxAllocationBps(9_000);
        vault.setMaxPendingCrossChainBps(5_000);
        vault.setMessageTransmitter(address(transmitter));
        vm.stopPrank();

        usdc.mint(alice, 100_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, alice);
        vm.stopPrank();

        // Task M: pending accounting uses the next local position ID.
        nonce = vault.crossChainPositionCounter() + 1;
        vm.prank(manager);
        vault.deployCrossChain(BURN_DOMAIN, bytes32(uint256(uint160(alice))), SENT);
        assertEq(vault.pendingCrossChain(nonce), SENT);
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _bytes32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    /// 148-byte native header (version, domains, bytes32 nonce, sender, recipient, caller, finality fields)
    /// + 228-byte V2 burn body (version, burnToken, mintRecipient, amount, msgSender, maxFee, feeExecuted, expiry)
    function _msg(uint64 n, uint32 destDomain, bytes32 destCaller, uint256 amount, uint256 fee)
        internal
        view
        returns (bytes memory)
    {
        // Task M: use the native 148-byte header with an independent bytes32 return nonce.
        bytes memory header = abi.encodePacked(
            uint32(1), BURN_DOMAIN, destDomain, bytes32(uint256(n)),
            vault.remoteTokenMessenger(BURN_DOMAIN), _bytes32(address(messenger)), destCaller,
            uint32(2000), uint32(2000)
        );
        bytes memory body = abi.encodePacked(
            uint32(1), bytes32(0), _bytes32(address(vault)), amount, bytes32(0), uint256(0), fee, uint256(0)
        );
        return bytes.concat(header, body);
    }

    function _settle(uint64 n, bytes memory m) internal {
        vm.prank(manager);
        vault.settleCrossChainWithMessage(n, m, hex"");
    }

    // ── F-02: header validation ──────────────────────────────────────────────

    function test_F02_unknownNonceReverts() public {
        bytes memory m = _msg(77, SOURCE_DOMAIN, _bytes32(address(vault)), SENT, 0);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.NonceMismatch.selector, uint64(77), uint64(0)));
        vault.settleCrossChainWithMessage(77, m, hex"");
    }

    function test_F02_independentReturnNonceSucceeds() public {
        bytes memory m = _msg(99, SOURCE_DOMAIN, _bytes32(address(vault)), SENT, 0);
        transmitter.arm(address(vault), SENT);
        _settle(nonce, m);
        assertEq(vault.pendingCrossChain(nonce), 0);
        assertTrue(vault.consumedInbound(BURN_DOMAIN, bytes32(uint256(99))));
    }

    function test_R2_wrongMessageRecipientReverts() public {
        bytes memory m = _msg(99, SOURCE_DOMAIN, _bytes32(address(vault)), SENT, 0);
        bytes32 bad = _bytes32(attacker);
        for (uint256 i = 0; i < 32; i++) m[76 + i] = bad[i];
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.WrongMessageRecipient.selector, bad));
        _settle(nonce, m);
        assertFalse(vault.consumedInbound(BURN_DOMAIN, bytes32(uint256(99))));
    }

    function test_R2_wrongSourceDomainReverts() public {
        bytes memory m = _msg(99, SOURCE_DOMAIN, _bytes32(address(vault)), SENT, 0);
        m[7] = bytes1(uint8(7));
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.WrongSourceDomain.selector, BURN_DOMAIN, uint32(7)));
        _settle(nonce, m);
    }

    function test_R2_inboundCannotSettleAnotherPendingEntry() public {
        transmitter.arm(address(vault), SENT);
        bytes memory m = _msg(99, SOURCE_DOMAIN, _bytes32(address(vault)), SENT, 0);
        _settle(nonce, m);
        uint64 second = vault.crossChainPositionCounter() + 1;
        vm.prank(manager);
        vault.deployCrossChain(BURN_DOMAIN, _bytes32(alice), SENT);
        vm.expectRevert(AutonomousVault.InboundAlreadyConsumed.selector);
        _settle(second, m);
        assertEq(vault.pendingCrossChain(second), SENT);
    }

    function test_R2_failedMintDoesNotConsumeInbound() public {
        bytes memory m = _msg(99, SOURCE_DOMAIN, _bytes32(address(vault)), SENT, 0);
        // Unarmed transmitter mock: the mint fails, so the whole settle must revert and roll back.
        vm.expectRevert();
        _settle(nonce, m);
        assertFalse(vault.consumedInbound(BURN_DOMAIN, bytes32(uint256(99))));
        transmitter.arm(address(vault), SENT);
        _settle(nonce, m);
        assertTrue(vault.consumedInbound(BURN_DOMAIN, bytes32(uint256(99))));
    }

    function test_F02_wrongDestinationDomainReverts() public {
        bytes memory m = _msg(nonce, 7, _bytes32(address(vault)), SENT, 0);
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(AutonomousVault.WrongDestinationDomain.selector, SOURCE_DOMAIN, uint32(7))
        );
        vault.settleCrossChainWithMessage(nonce, m, hex"");
    }

    function test_F02_wrongDestinationCallerReverts() public {
        bytes32 bad = _bytes32(attacker);
        bytes memory m = _msg(nonce, SOURCE_DOMAIN, bad, SENT, 0);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.WrongDestinationCaller.selector, bad));
        vault.settleCrossChainWithMessage(nonce, m, hex"");
    }

    // Remote strategies MUST burn with destinationCaller = this vault so third parties cannot pre-consume the message.
    function test_F02_rejectsZeroDestinationCaller() public {
        transmitter.arm(address(vault), SENT);
        bytes memory m = _msg(nonce, SOURCE_DOMAIN, bytes32(0), SENT, 0);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.WrongDestinationCaller.selector, bytes32(0)));
        vault.settleCrossChainWithMessage(nonce, m, hex"");
        assertEq(vault.pendingCrossChain(nonce), SENT);
    }

    function test_F02_acceptsVaultDestinationCaller_emitsSettled() public {
        transmitter.arm(address(vault), SENT);
        bytes memory m = _msg(nonce, SOURCE_DOMAIN, _bytes32(address(vault)), SENT, 0);

        vm.expectEmit(true, false, false, true, address(vault));
        emit AutonomousVault.CrossChainSettled(nonce, SENT, 0);
        _settle(nonce, m);

        assertEq(vault.pendingCrossChain(nonce), 0);
        assertEq(vault.totalPendingCrossChain(), 0);
        assertEq(vault.totalDeployed(), 0);
    }

    function test_F02_acceptsVaultAsDestinationCaller() public {
        transmitter.arm(address(vault), SENT);
        bytes memory m = _msg(nonce, SOURCE_DOMAIN, _bytes32(address(vault)), SENT, 0);
        _settle(nonce, m);
        assertEq(vault.pendingCrossChain(nonce), 0);
    }

    function test_F02_settleOnlyManagerOrOwner() public {
        bytes memory m = _msg(nonce, SOURCE_DOMAIN, _bytes32(address(vault)), SENT, 0);
        vm.prank(attacker);
        vm.expectRevert(AutonomousVault.NotManager.selector);
        vault.settleCrossChainWithMessage(nonce, m, hex"");
    }

    function test_F02_transmitterReportedDomainIsEnforced() public {
        MockTransmitterDomainSRF t5 = new MockTransmitterDomainSRF(usdc, 5);
        vm.prank(owner);
        vault.setMessageTransmitter(address(t5));
        assertEq(vault.localDomain(), 5, "vault adopts transmitter-reported domain");

        // Message for the constructor domain (26) is now wrong.
        bytes memory bad = _msg(nonce, SOURCE_DOMAIN, _bytes32(address(vault)), SENT, 0);
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(AutonomousVault.WrongDestinationDomain.selector, uint32(5), SOURCE_DOMAIN)
        );
        vault.settleCrossChainWithMessage(nonce, bad, hex"");

        // Message for domain 5 settles.
        t5.arm(address(vault), SENT);
        _settle(nonce, _msg(nonce, 5, _bytes32(address(vault)), SENT, 0));
        assertEq(vault.pendingCrossChain(nonce), 0);
    }

    // ── F-04: setLocalDomain ─────────────────────────────────────────────────

    function test_F04_setLocalDomainOnlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vault.setLocalDomain(9);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, manager));
        vault.setLocalDomain(9);
    }

    function test_F04_ownerSetsLocalDomainAndSettlementFollows() public {
        vm.prank(owner);
        vault.setLocalDomain(9);
        assertEq(vault.localDomain(), 9);

        bytes memory old = _msg(nonce, SOURCE_DOMAIN, _bytes32(address(vault)), SENT, 0);
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(AutonomousVault.WrongDestinationDomain.selector, uint32(9), SOURCE_DOMAIN)
        );
        vault.settleCrossChainWithMessage(nonce, old, hex"");

        transmitter.arm(address(vault), SENT);
        _settle(nonce, _msg(nonce, 9, _bytes32(address(vault)), SENT, 0));
        assertEq(vault.pendingCrossChain(nonce), 0);
    }

    function test_F04_domainZeroIsValid() public {
        vm.prank(owner);
        vault.setLocalDomain(0);
        assertEq(vault.localDomain(), 0);
    }

    function test_F04_setLocalDomainWithoutTransmitterReverts() public {
        vm.prank(owner);
        AutonomousVault fresh = new AutonomousVault(IERC20(address(usdc)), owner, SOURCE_DOMAIN);
        vm.prank(owner);
        vm.expectRevert(AutonomousVault.ZeroAddress.selector);
        fresh.setLocalDomain(1);
    }

    function test_F04_setLocalDomainMustMatchTransmitterReport() public {
        MockTransmitterDomainSRF t5 = new MockTransmitterDomainSRF(usdc, 5);
        vm.startPrank(owner);
        vault.setMessageTransmitter(address(t5));
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.LocalDomainMismatch.selector, uint32(5), uint32(6)));
        vault.setLocalDomain(6);
        vault.setLocalDomain(5); // matching value accepted
        vm.stopPrank();
        assertEq(vault.localDomain(), 5);
    }

    // ── F-07: zero-address guards ────────────────────────────────────────────

    function test_F07_setTokenMessengerZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(AutonomousVault.ZeroAddress.selector);
        vault.setTokenMessenger(address(0));
        assertEq(vault.tokenMessenger(), address(messenger), "unchanged");
    }

    function test_F07_setMessageTransmitterZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(AutonomousVault.ZeroAddress.selector);
        vault.setMessageTransmitter(address(0));
        assertEq(vault.messageTransmitter(), address(transmitter), "unchanged");
    }

    function test_F07_setTokenMessengerOwnerHappyPath() public {
        address newMessenger = address(new MockMessengerSRF());
        vm.expectEmit(true, true, false, false, address(vault));
        emit AutonomousVault.TokenMessengerUpdated(address(messenger), newMessenger);
        vm.prank(owner);
        vault.setTokenMessenger(newMessenger);
        assertEq(vault.tokenMessenger(), newMessenger);
    }

    function test_F07_setMessageTransmitterOwnerHappyPath() public {
        MockTransmitterSRF t2 = new MockTransmitterSRF(usdc);
        vm.prank(owner);
        vault.setMessageTransmitter(address(t2));
        assertEq(vault.messageTransmitter(), address(t2));
        assertEq(vault.localDomain(), SOURCE_DOMAIN, "falls back to constructor domain");
    }

    function test_F07_settersNonOwnerRevert() public {
        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vault.setTokenMessenger(address(1));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vault.setMessageTransmitter(address(1));
        vm.stopPrank();
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  F-03  HalalLPAdapter — timelocked slippage + non-zero min amounts
// ═════════════════════════════════════════════════════════════════════════════
contract SRF03HalalLPTest is Test {
    address internal owner    = makeAddr("owner");
    address internal vault    = makeAddr("vault");
    address internal attacker = makeAddr("attacker");

    MockERC20         internal usdc;
    MockERC20         internal pair;
    MockPositionManager internal pm;
    HalalLPAdapter    internal adapter;

    event SlippageProposed(uint256 newBps, uint256 executeAfter);
    event SlippageExecuted(uint256 newBps);
    event SlippageProposalCancelled();

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);
        pair = new MockERC20("Pair", "PAIR", 18);
        pm   = new MockPositionManager(address(usdc), address(pair));
        adapter = new HalalLPAdapter(
            address(pm), address(usdc), address(pair), 3000, address(usdc), vault, owner
        );
        // The mock manager pays out the paired token on collect().
        pair.mint(address(pm), 1_000_000e18);
    }

    function _deploy(uint256 amount) internal {
        usdc.mint(address(adapter), amount);
        vm.prank(vault);
        adapter.deploy(amount);
    }

    // ── timelock ─────────────────────────────────────────────────────────────

    function test_F03_defaultsAndConstants() public view {
        assertEq(adapter.maxSlippageBps(), 100);
        assertEq(adapter.MAX_SLIPPAGE_BPS(), 500);
        assertEq(adapter.TIMELOCK_DELAY(), 30 days);
        assertFalse(adapter.slippageProposalPending());
    }

    function test_F03_proposeDoesNotChangeValueAndEmits() public {
        vm.expectEmit(false, false, false, true, address(adapter));
        emit SlippageProposed(300, block.timestamp + 30 days);
        vm.prank(owner);
        adapter.proposeMaxSlippageBps(300);

        assertEq(adapter.maxSlippageBps(), 100, "unchanged until execute");
        assertEq(adapter.pendingSlippageBps(), 300);
        assertEq(adapter.slippageExecuteAfter(), block.timestamp + 30 days);
        assertTrue(adapter.slippageProposalPending());
    }

    function test_F03_executeBeforeTimelockReverts() public {
        vm.prank(owner);
        adapter.proposeMaxSlippageBps(300);
        uint256 executeAfter = adapter.slippageExecuteAfter();

        skip(30 days - 1);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(HalalLPAdapter.TimelockNotElapsed.selector, executeAfter, block.timestamp)
        );
        adapter.executeMaxSlippageBps();
        assertEq(adapter.maxSlippageBps(), 100);
    }

    function test_F03_executeAfterTimelockAppliesAndClears() public {
        vm.prank(owner);
        adapter.proposeMaxSlippageBps(300);
        skip(30 days);

        vm.expectEmit(false, false, false, true, address(adapter));
        emit SlippageExecuted(300);
        vm.prank(owner);
        adapter.executeMaxSlippageBps();

        assertEq(adapter.maxSlippageBps(), 300);
        assertFalse(adapter.slippageProposalPending());
        assertEq(adapter.pendingSlippageBps(), 0);
        assertEq(adapter.slippageExecuteAfter(), 0);

        vm.prank(owner);
        vm.expectRevert(HalalLPAdapter.NoProposalPending.selector);
        adapter.executeMaxSlippageBps();
    }

    function test_F03_executeWithoutProposalReverts() public {
        vm.prank(owner);
        vm.expectRevert(HalalLPAdapter.NoProposalPending.selector);
        adapter.executeMaxSlippageBps();
    }

    function test_F03_cancelClearsProposal() public {
        vm.prank(owner);
        adapter.proposeMaxSlippageBps(300);

        vm.expectEmit(false, false, false, false, address(adapter));
        emit SlippageProposalCancelled();
        vm.prank(owner);
        adapter.cancelMaxSlippageBps();

        assertFalse(adapter.slippageProposalPending());
        assertEq(adapter.maxSlippageBps(), 100);
        skip(30 days);
        vm.prank(owner);
        vm.expectRevert(HalalLPAdapter.NoProposalPending.selector);
        adapter.executeMaxSlippageBps();
    }

    function test_F03_cancelWithoutProposalReverts() public {
        vm.prank(owner);
        vm.expectRevert(HalalLPAdapter.NoProposalPending.selector);
        adapter.cancelMaxSlippageBps();
    }

    function test_F03_capIsInclusive500() public {
        vm.prank(owner);
        adapter.proposeMaxSlippageBps(500);
        assertEq(adapter.pendingSlippageBps(), 500);
    }

    function test_F03_aboveCapReverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HalalLPAdapter.SlippageAboveCap.selector, 501, 500));
        adapter.proposeMaxSlippageBps(501);
        assertFalse(adapter.slippageProposalPending());
    }

    function testFuzz_F03_capEnforced(uint256 bps) public {
        vm.prank(owner);
        if (bps > 500) {
            vm.expectRevert(abi.encodeWithSelector(HalalLPAdapter.SlippageAboveCap.selector, bps, 500));
            adapter.proposeMaxSlippageBps(bps);
        } else {
            adapter.proposeMaxSlippageBps(bps);
            assertEq(adapter.pendingSlippageBps(), bps);
        }
    }

    function test_F03_nonOwnerReverts() public {
        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        adapter.proposeMaxSlippageBps(200);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        adapter.executeMaxSlippageBps();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        adapter.cancelMaxSlippageBps();
        vm.stopPrank();
    }

    // ── non-zero min amounts to the position manager ─────────────────────────

    function test_F03_deployPassesNonZeroMinAmount() public {
        _deploy(1_000e6);
        assertEq(pm.mintCount(), 1);
        assertEq(pm.lastMintAmount0Desired(), 1_000e6);
        assertEq(pm.lastMintAmount0Min(), 990e6, "99% of desired at default 100 bps");
        assertEq(pm.lastMintAmount1Min(), 0, "no min on the zero-desired side");
        assertEq(usdc.allowance(address(adapter), address(pm)), 0, "allowance cleared");
        assertEq(adapter.totalDeployed(), 1_000e6);
    }

    function test_F03_deployTinyAmountStillHasMinOfOne() public {
        _deploy(1);
        assertEq(pm.lastMintAmount0Min(), 1);
    }

    function testFuzz_F03_deployMinNeverZero(uint256 amount) public {
        amount = bound(amount, 1, 1e15);
        _deploy(amount);
        uint256 min0 = pm.lastMintAmount0Min();
        assertGt(min0, 0, "min amount must be non-zero");
        assertLe(min0, amount);
    }

    function test_F03_deployRevertsWhenManagerPaysBelowMin() public {
        pm.setPayoutBps(9_000); // 10% shortfall > 1% tolerance
        usdc.mint(address(adapter), 1_000e6);
        vm.prank(vault);
        vm.expectRevert(bytes("Price slippage check"));
        adapter.deploy(1_000e6);
    }

    function test_F03_deployToleratesShortfallWithinSlippage() public {
        pm.setPayoutBps(9_900); // exactly 1%
        _deploy(1_000e6);
        assertEq(adapter.totalDeployed(), 1_000e6);
    }

    function test_F03_recallPassesNonZeroMinAmounts() public {
        _deploy(1_000e6);
        vm.prank(vault);
        uint256 returned = adapter.recall(400e6);

        assertEq(pm.decreaseCount(), 1);
        assertEq(pm.lastDecLiquidity(), 400e6);
        assertGt(pm.lastDecAmount0Min(), 0, "amount0Min non-zero");
        assertGt(pm.lastDecAmount1Min(), 0, "amount1Min non-zero");
        assertLe(pm.lastDecAmount0Min(), 400e6);
        assertEq(returned, 400e6);
        assertEq(usdc.balanceOf(vault), 400e6);
        assertEq(adapter.totalDeployed(), 600e6);
    }

    function test_F03_recallRevertsWhenManagerPaysBelowMin() public {
        _deploy(1_000e6);
        pm.setPayoutBps(9_000);
        vm.prank(vault);
        vm.expectRevert(bytes("Price slippage check"));
        adapter.recall(400e6);
    }

    function test_F03_recallWithNoPositionReturnsZero() public {
        vm.prank(vault);
        assertEq(adapter.recall(1e6), 0);
        assertEq(pm.decreaseCount(), 0);
    }

    function test_F03_executedSlippageWidensMinAmounts() public {
        vm.prank(owner);
        adapter.proposeMaxSlippageBps(500);
        skip(30 days);
        vm.prank(owner);
        adapter.executeMaxSlippageBps();

        pm.setPayoutBps(9_700); // 3% shortfall: would revert at 1%, ok at 5%
        _deploy(1_000e6);
        assertEq(pm.lastMintAmount0Min(), 950e6, "95% of desired at 500 bps");
    }

    function test_R2_secondDeployRevertsWithoutOverwritingPosition() public {
        _deploy(1_000e6);
        uint256 id = adapter.positionTokenId();
        usdc.mint(address(adapter), 1e6);
        vm.prank(vault);
        vm.expectRevert(bytes4(keccak256("PositionAlreadyOpen()")));
        adapter.deploy(1e6);
        assertEq(adapter.positionTokenId(), id);
        assertEq(pm.mintCount(), 1);
    }

    function test_R2_spotDeviationBlocksMintAndRecall() public {
        pm.setTicks(101, 0);
        usdc.mint(address(adapter), 1_000e6);
        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSignature("SpotTwapDeviation(int24,int24)", int24(101), int24(0)));
        adapter.deploy(1_000e6);
        pm.setTicks(100, 0);
        vm.prank(vault);
        adapter.deploy(1_000e6);
        pm.setTicks(-101, 0);
        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSignature("SpotTwapDeviation(int24,int24)", int24(-101), int24(0)));
        adapter.recall(400e6);
        assertEq(pm.decreaseCount(), 0);
    }

    function test_R2_observationFailureBlocksMintAndRecall() public {
        pm.setObserveUnavailable(true);
        usdc.mint(address(adapter), 1_000e6);
        vm.prank(vault);
        vm.expectRevert(bytes4(keccak256("TwapUnavailable()")));
        adapter.deploy(1_000e6);
        pm.setObserveUnavailable(false);
        vm.prank(vault);
        adapter.deploy(1_000e6);
        pm.setObserveUnavailable(true);
        vm.prank(vault);
        vm.expectRevert(bytes4(keccak256("TwapUnavailable()")));
        adapter.recall(400e6);
    }

    function test_R2_negativeAverageRoundsDown() public {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 1800;
        int56[] memory cumulatives = new int56[](2);
        cumulatives[1] = -1801;
        uint160[] memory secondsPerLiquidity = new uint160[](2);
        vm.mockCall(address(pm), abi.encodeWithSignature("observe(uint32[])", secondsAgos),
            abi.encode(cumulatives, secondsPerLiquidity));
        pm.setTicks(99, 0);
        usdc.mint(address(adapter), 1_000e6);
        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSignature("SpotTwapDeviation(int24,int24)", int24(99), int24(-2)));
        adapter.deploy(1_000e6);
    }

    function test_R2_minimumAmountsUseAverageNotSpot() public {
        _deploy(1_000e6);
        uint256 snapshot = vm.snapshotState();
        vm.prank(vault);
        adapter.recall(400e6);
        uint256 min0 = pm.lastDecAmount0Min();
        uint256 min1 = pm.lastDecAmount1Min();
        vm.revertToState(snapshot);
        pm.setTicks(100, 0);
        vm.prank(vault);
        adapter.recall(400e6);
        assertEq(pm.lastDecAmount0Min(), min0);
        assertEq(pm.lastDecAmount1Min(), min1);
    }

    function test_R2_windowTimelockAndBounds() public {
        assertEq(adapter.twapWindow(), 1800);
        assertEq(adapter.MIN_TWAP_WINDOW(), 300);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSignature("TwapWindowBelowMinimum(uint32,uint32)", uint32(299), uint32(300)));
        adapter.proposeTwapWindow(299);
        adapter.proposeTwapWindow(300);
        assertEq(adapter.twapWindow(), 1800);
        uint256 executeAfter = adapter.twapWindowExecuteAfter();
        vm.expectRevert(abi.encodeWithSignature("TimelockNotElapsed(uint256,uint256)", executeAfter, block.timestamp));
        adapter.executeTwapWindow();
        skip(30 days);
        adapter.executeTwapWindow();
        assertEq(adapter.twapWindow(), 300);
        assertFalse(adapter.twapWindowProposalPending());
        assertEq(adapter.pendingTwapWindow(), 0);
        assertEq(adapter.twapWindowExecuteAfter(), 0);
        adapter.proposeTwapWindow(3600);
        adapter.cancelTwapWindow();
        vm.expectRevert(bytes4(keccak256("NoProposalPending()")));
        adapter.executeTwapWindow();
        vm.stopPrank();
    }

    function test_R2_deviationTimelockAndBounds() public {
        assertEq(adapter.maxTwapDeviationTicks(), 100);
        assertEq(adapter.MAX_TWAP_DEVIATION_TICKS(), 500);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSignature("TwapDeviationAboveCap(uint24,uint24)", uint24(501), uint24(500)));
        adapter.proposeMaxTwapDeviationTicks(501);
        adapter.proposeMaxTwapDeviationTicks(500);
        assertEq(adapter.maxTwapDeviationTicks(), 100);
        uint256 executeAfter = adapter.twapDeviationExecuteAfter();
        vm.expectRevert(abi.encodeWithSignature("TimelockNotElapsed(uint256,uint256)", executeAfter, block.timestamp));
        adapter.executeMaxTwapDeviationTicks();
        skip(30 days);
        adapter.executeMaxTwapDeviationTicks();
        assertEq(adapter.maxTwapDeviationTicks(), 500);
        assertFalse(adapter.twapDeviationProposalPending());
        assertEq(adapter.pendingMaxTwapDeviationTicks(), 0);
        assertEq(adapter.twapDeviationExecuteAfter(), 0);
        adapter.proposeMaxTwapDeviationTicks(0);
        adapter.cancelMaxTwapDeviationTicks();
        vm.expectRevert(bytes4(keccak256("NoProposalPending()")));
        adapter.executeMaxTwapDeviationTicks();
        vm.stopPrank();
    }

    function test_R2_oracleConfigOnlyOwner() public {
        vm.startPrank(attacker);
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker);
        vm.expectRevert(err);
        adapter.proposeTwapWindow(300);
        vm.expectRevert(err);
        adapter.executeTwapWindow();
        vm.expectRevert(err);
        adapter.cancelTwapWindow();
        vm.expectRevert(err);
        adapter.proposeMaxTwapDeviationTicks(500);
        vm.expectRevert(err);
        adapter.executeMaxTwapDeviationTicks();
        vm.expectRevert(err);
        adapter.cancelMaxTwapDeviationTicks();
        vm.stopPrank();
    }

    function test_F03_deployAndRecallOnlyVault() public {
        vm.startPrank(attacker);
        vm.expectRevert(HalalLPAdapter.OnlyVault.selector);
        adapter.deploy(1);
        vm.expectRevert(HalalLPAdapter.OnlyVault.selector);
        adapter.recall(1);
        vm.stopPrank();
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  F-05  CharityModule.setEscrow — one-shot
// ═════════════════════════════════════════════════════════════════════════════
contract SRF05CharityEscrowOnceTest is Test {
    address internal owner         = makeAddr("owner");
    address internal charityWallet = makeAddr("charityWallet");
    address internal escrowA       = makeAddr("escrowA");
    address internal escrowB       = makeAddr("escrowB");
    address internal attacker      = makeAddr("attacker");

    MockERC20       internal usdc;
    MockRegistrySRF internal reg;
    CharityModule   internal module;

    function setUp() public {
        usdc   = new MockERC20("Mock USDC", "mUSDC", 6);
        reg    = new MockRegistrySRF(owner);
        module = new CharityModule(charityWallet, address(usdc), makeAddr("vault"), owner, address(reg));
    }

    function test_F05_firstSetEscrowSucceedsAndEmits() public {
        vm.expectEmit(true, false, false, false, address(module));
        emit CharityModule.EscrowSet(escrowA);
        vm.prank(owner);
        module.setEscrow(escrowA);
        assertEq(module.escrow(), escrowA);
    }

    function test_F05_secondSetEscrowReverts() public {
        vm.startPrank(owner);
        module.setEscrow(escrowA);
        vm.expectRevert(CharityModule.EscrowAlreadySet.selector);
        module.setEscrow(escrowB);
        vm.expectRevert(CharityModule.EscrowAlreadySet.selector);
        module.setEscrow(escrowA); // even re-setting the same value
        vm.stopPrank();
        assertEq(module.escrow(), escrowA, "escrow immutable once set");
    }

    function test_F05_zeroAddressAfterSetRevertsEscrowAlreadySet() public {
        vm.startPrank(owner);
        module.setEscrow(escrowA);
        vm.expectRevert(CharityModule.EscrowAlreadySet.selector);
        module.setEscrow(address(0));
        vm.stopPrank();
        assertEq(module.escrow(), escrowA, "cannot be cleared");
    }

    /// @dev On a fresh module a zero address is rejected with ZeroWallet (source order:
    ///      EscrowAlreadySet check first, then the zero check) and escrow stays unset.
    function test_F05_zeroAddressOnFreshModuleReverts() public {
        vm.prank(owner);
        vm.expectRevert(CharityModule.ZeroWallet.selector);
        module.setEscrow(address(0));
        assertEq(module.escrow(), address(0));
    }

    function test_F05_nonOwnerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        module.setEscrow(escrowA);
    }

    function test_F05_escrowCanDistributeOnlyAfterSet() public {
        usdc.mint(escrowA, 1_000e6);
        vm.prank(escrowA);
        usdc.approve(address(module), 1_000e6);

        vm.prank(escrowA);
        vm.expectRevert(CharityModule.NotVault.selector);
        module.distributeCharity(1_000e6);

        vm.prank(owner);
        module.setEscrow(escrowA);
        vm.prank(escrowA);
        (uint256 charityAmt,) = module.distributeCharity(1_000e6);
        assertEq(charityAmt, 25e6);
    }

    function testFuzz_F05_onlyFirstEscrowWins(address a, address b) public {
        vm.assume(a != address(0));
        vm.startPrank(owner);
        module.setEscrow(a);
        vm.expectRevert(CharityModule.EscrowAlreadySet.selector);
        module.setEscrow(b);
        vm.stopPrank();
        assertEq(module.escrow(), a);
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  F-06  Rehearsal.s.sol TestnetRegistryShortTimelock — mainnet chain guard
// ═════════════════════════════════════════════════════════════════════════════
contract SRF06RehearsalGuardTest is Test {
    address internal owner  = makeAddr("owner");
    address internal board  = makeAddr("board");
    address internal adapter = makeAddr("adapter");

    function test_F06_deployRevertsOnArcMainnet5042() public {
        vm.chainId(5042);
        vm.expectRevert(bytes("mainnet forbidden"));
        new TestnetRegistryShortTimelock(owner, board);
    }

    function test_F06_deployWorksOnArcTestnet5042002() public {
        vm.chainId(5042002);
        TestnetRegistryShortTimelock r = new TestnetRegistryShortTimelock(owner, board);
        assertEq(r.owner(), owner);
        assertTrue(r.isBoard(board));
        assertEq(r.TESTNET_TIMELOCK_PERIOD(), 2 minutes);
    }

    function testFuzz_F06_deployWorksOnAnyChainExcept5042(uint64 chainId) public {
        vm.assume(chainId != 5042 && chainId != 0);
        vm.chainId(chainId);
        TestnetRegistryShortTimelock r = new TestnetRegistryShortTimelock(owner, board);
        assertEq(r.owner(), owner);
    }

    function test_F06_screeningFunctionsRevertIfChainBecomes5042() public {
        vm.chainId(5042002);
        TestnetRegistryShortTimelock r = new TestnetRegistryShortTimelock(owner, board);
        vm.chainId(5042);
        vm.startPrank(board);
        vm.expectRevert(bytes("mainnet forbidden"));
        r.proposeScreeningTestnet(adapter, keccak256("ruling"), block.timestamp + 365 days);
        vm.expectRevert(bytes("mainnet forbidden"));
        r.executeScreeningTestnet(adapter);
        vm.stopPrank();
    }

    function test_F06_shortTimelockFlowOnTestnet() public {
        vm.chainId(5042002);
        TestnetRegistryShortTimelock r = new TestnetRegistryShortTimelock(owner, board);
        bytes32 h = keccak256("ruling");
        uint256 expiry = block.timestamp + 365 days;

        vm.startPrank(board);
        r.proposeScreeningTestnet(adapter, h, expiry);
        vm.expectRevert(bytes("TestnetReg: timelock not elapsed"));
        r.executeScreeningTestnet(adapter);
        skip(2 minutes);
        r.executeScreeningTestnet(adapter);
        vm.stopPrank();

        (bytes32 pHash, uint256 exp,) = r.screenings(adapter);
        assertEq(pHash, h);
        assertEq(exp, expiry);
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  F-08  GoldAllocationAdapter.setPool — propose-only, 30-day timelock
// ═════════════════════════════════════════════════════════════════════════════
contract SRF08GoldPoolTimelockTest is Test {
    address internal owner    = makeAddr("owner");
    address internal vault    = makeAddr("vault");
    address internal attacker = makeAddr("attacker");

    uint256 internal constant POOL_PRICE = 3_300_000_000;
    int256  internal constant ORACLE_PRICE = 330_000_000_000;

    MockERC20             internal usdc;
    MockXAUT              internal xaut;
    MockXauUsdAggregator  internal oracle;
    MockUniswapV3PoolXAUT internal poolA;
    MockUniswapV3PoolXAUT internal poolB;
    GoldAllocationAdapter internal adapter;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc   = new MockERC20("Mock USDC", "mUSDC", 6);
        xaut   = new MockXAUT();
        oracle = new MockXauUsdAggregator();
        poolA  = new MockUniswapV3PoolXAUT(address(usdc), address(xaut), POOL_PRICE);
        poolB  = new MockUniswapV3PoolXAUT(address(usdc), address(xaut), POOL_PRICE * 2);
        adapter = new GoldAllocationAdapter(
            address(usdc), address(xaut), address(poolA), 3000, address(oracle), vault, 3600, owner
        );
    }

    function test_F08_setPoolOnlyProposes() public {
        assertEq(adapter.pool(), address(poolA));
        vm.expectEmit(true, false, false, true, address(adapter));
        emit GoldAllocationAdapter.PoolProposed(address(poolB), block.timestamp + 30 days);
        vm.prank(owner);
        adapter.setPool(address(poolB));

        assertEq(adapter.pool(), address(poolA), "pool unchanged until executePool");
        (address pending, uint256 executeAfter, bool isPending) = adapter.pendingPool();
        assertEq(pending, address(poolB));
        assertEq(executeAfter, block.timestamp + 30 days);
        assertTrue(isPending);
    }

    function test_F08_executeEarlyReverts() public {
        vm.prank(owner);
        adapter.setPool(address(poolB));
        (, uint256 executeAfter,) = adapter.pendingPool();

        skip(30 days - 1);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(GoldAllocationAdapter.TimelockNotElapsed.selector, executeAfter, block.timestamp)
        );
        adapter.executePool();
        assertEq(adapter.pool(), address(poolA));
    }

    function test_F08_executeAfterTimelockSwitchesPool() public {
        vm.prank(owner);
        adapter.setPool(address(poolB));
        skip(30 days);

        vm.expectEmit(true, true, false, false, address(adapter));
        emit GoldAllocationAdapter.PoolExecuted(address(poolA), address(poolB));
        vm.prank(owner);
        adapter.executePool();

        assertEq(adapter.pool(), address(poolB));
        (,, bool isPending) = adapter.pendingPool();
        assertFalse(isPending);

        vm.prank(owner);
        vm.expectRevert(GoldAllocationAdapter.NoProposalPending.selector);
        adapter.executePool();
    }

    function test_F08_proposePoolAliasBehavesTheSame() public {
        vm.prank(owner);
        adapter.proposePool(address(poolB));
        assertEq(adapter.pool(), address(poolA));
        (address pending,, bool isPending) = adapter.pendingPool();
        assertEq(pending, address(poolB));
        assertTrue(isPending);
    }

    function test_F08_cancelPoolWorks() public {
        vm.prank(owner);
        adapter.setPool(address(poolB));

        vm.expectEmit(false, false, false, false, address(adapter));
        emit GoldAllocationAdapter.PoolProposalCancelled();
        vm.prank(owner);
        adapter.cancelPool();

        (,, bool isPending) = adapter.pendingPool();
        assertFalse(isPending);
        skip(30 days);
        vm.prank(owner);
        vm.expectRevert(GoldAllocationAdapter.NoProposalPending.selector);
        adapter.executePool();
        assertEq(adapter.pool(), address(poolA));
    }

    function test_F08_cancelWithoutProposalReverts() public {
        vm.prank(owner);
        vm.expectRevert(GoldAllocationAdapter.NoProposalPending.selector);
        adapter.cancelPool();
    }

    function test_F08_nonOwnerReverts() public {
        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        adapter.setPool(address(poolB));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        adapter.proposePool(address(poolB));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        adapter.executePool();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        adapter.cancelPool();
        vm.stopPrank();
    }

    /// @dev Behavioural: price sanity keeps reading the OLD pool until executePool.
    function test_F08_priceSanityFollowsActivePoolOnly() public {
        oracle.setPrice(ORACLE_PRICE);
        assertTrue(adapter.isPriceSane());
        vm.prank(owner);
        adapter.setPool(address(poolB)); // poolB is 2x the oracle price
        assertTrue(adapter.isPriceSane(), "proposal alone must not change price source");

        skip(30 days);
        oracle.setPrice(ORACLE_PRICE); // refresh staleness
        assertTrue(adapter.isPriceSane(), "still old pool right before execute");

        vm.prank(owner);
        adapter.executePool();
        assertFalse(adapter.isPriceSane(), "deviating pool is live only after execute");
    }
}
