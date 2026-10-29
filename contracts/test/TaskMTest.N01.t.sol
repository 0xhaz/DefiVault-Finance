// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AutonomousVault} from "../AutonomousVault.sol";
import {ShariahVault} from "../ShariahVault.sol";
import {ShariahVaultV2} from "../ShariahVaultV2.sol";
import {ShariahAdapterRegistry} from "../ShariahAdapterRegistry.sol";
import {TreasuryModule} from "../TreasuryModule.sol";
import {CharityModule} from "../CharityModule.sol";
import {PurificationEscrow} from "../PurificationEscrow.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {MockRegistrySRF} from "./SecurityReviewFixesTest.t.sol";
import {PrincipalAdapterM} from "./TaskMTest.N02.t.sol";

/// @dev N-01: claimMusharakahProfit is bounded by realizedProfit(); run against V1 and V2 vaults.
abstract contract TaskMN01Base is Test {
    address internal owner = makeAddr("owner");
    address internal manager = makeAddr("manager");
    address internal alice = makeAddr("alice");
    address internal stranger = makeAddr("stranger");
    address internal charityWallet = makeAddr("charityWallet");
    uint32 internal constant DOM = 26;

    MockERC20 internal usdc;
    MockRegistrySRF internal reg;
    ShariahAdapterRegistry internal registry;
    TreasuryModule internal treasury;
    ShariahVault internal vault;
    CharityModule internal charity;
    PurificationEscrow internal escrow;

    function _newVault() internal virtual returns (ShariahVault);

    function setUp() public virtual {
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);
        reg = new MockRegistrySRF(owner);
        registry = new ShariahAdapterRegistry(owner, owner);

        // treasury(n) -> vault(n+1) -> charity(n+2) -> escrow(n+3); treasury is owned by the vault.
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
        // N-20: isolate realized-profit/streaming tests from time-based fees; fee coverage has its own fixture.
        vm.prank(address(vault));
        treasury.setAdminFeeBps(0);

        usdc.mint(alice, 10_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _deposit(uint256 amount) internal {
        vm.prank(alice);
        vault.deposit(amount, alice);
    }

    function _claim(uint256 gross) internal {
        vm.prank(owner);
        vault.claimMusharakahProfit(gross);
    }

    function _expectExceeds(uint256 requested, uint256 available) internal {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.ProfitExceedsRealized.selector, requested, available));
        vault.claimMusharakahProfit(requested);
    }

    function _appreciatingGold() internal returns (PrincipalAdapterM adapter) {
        _deposit(1_000e6);
        adapter = new PrincipalAdapterM(vault);
        vm.startPrank(owner);
        vault.setGoldSpreadAdapter(address(adapter));
        vault.setScreened(address(adapter), true);
        registry.proposeScreening(address(adapter), keccak256("gold"), block.timestamp + 365 days);
        vm.stopPrank();
        skip(30 days);
        vm.prank(owner);
        registry.executeScreening(address(adapter));
        vm.startPrank(address(vault));
        treasury.setAdminFeeBps(0);
        treasury.setFeeSource(address(vault));
        treasury.setProfitRecorder(address(escrow));
        vm.stopPrank();
        vm.prank(manager);
        vault.deployCapitalAndExecute(address(adapter), 200e6, "");
        adapter.setValue(300e6, true);
        usdc.mint(address(adapter), 100e6);
        adapter.setRecall(300e6, 300e6, 0);
    }

    function test_unrealizedGoldGain_isNeitherClaimableNorLockable() public {
        _appreciatingGold();
        assertEq(vault.goldUnrealizedGain(), 100e6);
        assertEq(vault.totalAssets(), 1_100e6);
        assertEq(vault.realizedProfit(), 0);
        _expectExceeds(1, 0);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.ProfitExceedsRealized.selector, 1, 0));
        vault.lockProfit(1);
    }

    function test_goldRecall_realizesGainExactlyOnce_afterEarlierClaim() public {
        PrincipalAdapterM adapter = _appreciatingGold();
        usdc.mint(address(vault), 40e6);
        _claim(40e6);
        uint256 gain = vault.goldUnrealizedGain();
        assertEq(vault.hurdlePrincipal(), vault.totalAssets() - gain);
        assertEq(vault.profitBase(), vault.totalAssets() - gain + vault.lockedProfit());
        // Processed depositor profit raises the high while locked; paper gold still does not.
        assertEq(vault.highWaterMarkPerShare(), _processedPrice());
        skip(vault.profitUnlockPeriod());
        assertEq(vault.realizedProfit(), 0);
        uint256 nav = vault.totalAssets();
        vm.prank(manager);
        vault.recallCapital(address(adapter), 200e6);
        assertEq(vault.totalAssets(), nav, "recall changes realization, not marked NAV");
        assertEq(vault.goldUnrealizedGain(), 0);
        assertEq(vault.realizedProfit(), gain, "only the recalled appreciation becomes available");
        _claim(gain);
        _expectExceeds(1, 0);
        skip(vault.profitUnlockPeriod());
        assertEq(vault.realizedProfit(), 0, "distributed gain cannot be claimed twice");
        _expectExceeds(1, 0);
    }

    function test_claimHWM_deficitUsesRealizedAssetUnits_notPaperGoldGain() public {
        _appreciatingGold();
        usdc.mint(address(vault), 100e6);
        _claim(100e6);
        skip(vault.profitUnlockPeriod());
        uint256 high = vault.highWaterMarkPerShare();
        usdc.burn(address(vault), 200e6);
        _deposit(1_000e6);
        usdc.mint(address(vault), 240e6);
        assertEq(vault.goldUnrealizedGain(), 100e6);
        uint256 deficit = vault.hwmDeficit();
        assertGt(deficit, 40e6);
        uint256 feesBefore = treasury.pendingFees();
        _claim(40e6);
        assertEq(vault.highWaterMarkPerShare(), high);
        assertEq(treasury.pendingFees(), feesBefore, "paper gold cannot erase recovery");
        // Locked processed recovery counts immediately, not only when it unlocks.
        uint256 remaining = vault.hwmDeficit();
        assertLt(remaining, deficit);
        skip(vault.profitUnlockPeriod());
        assertEq(vault.hwmDeficit(), remaining);
        assertEq(usdc.allowance(address(vault), address(escrow)), 0);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_claimHWM_excessPaysOnlyAfterDeficitAndHurdle() public {
        _deposit(1_000e6);
        usdc.mint(address(vault), 100e6);
        _claim(100e6);
        skip(vault.profitUnlockPeriod());
        usdc.burn(address(vault), 200e6);
        _deposit(1_000e6);
        skip(365 days);
        usdc.mint(address(vault), 600e6);
        // The waterfall now receives the CURRENT capped processed deficit, not NAV minus gross.
        uint256 deficit = vault.hwmDeficit();
        uint256 elapsed = block.timestamp - vault.hurdleStartTime();
        (, uint256 expected,) = treasury.calculateMusharakahSplitHWM(
            400e6 - 400e6 * charity.charityBps() / 10_000, elapsed, vault.hurdlePrincipal(), deficit
        );
        assertGt(deficit, 0);
        assertGt(expected, 0);
        uint256 feesBefore = treasury.pendingFees();
        _claim(400e6);
        assertEq(vault.hwmDeficit(), 0, "processed recovery includes the locked depositor share");
        assertEq(treasury.pendingFees() - feesBefore, expected);
    }

    function test_lockProfit_zeroCannotRestartUnlockSchedule() public {
        _deposit(1_000e6);
        usdc.mint(address(vault), 100e6);
        vm.prank(manager);
        vault.lockProfit(100e6);
        uint256 end = vault.unlockedAt();
        skip(vault.profitUnlockPeriod() / 2);
        uint256 nav = vault.totalAssets();
        vm.prank(manager);
        vm.expectRevert(ShariahVault.ZeroAmount.selector);
        vault.lockProfit(0);
        assertEq(vault.unlockedAt(), end);
        assertEq(vault.lockedProfit(), 100e6);
        assertEq(vault.totalAssets(), nav);
        vm.warp(end);
        assertEq(vault.totalAssets(), 1_100e6);
    }

    // N-20/N-21 regressions share the V1/V2 fixture so inherited behavior cannot drift.
    function _enableWakala() internal {
        vm.startPrank(address(vault));
        treasury.setFeeSource(address(vault));
        treasury.setProfitRecorder(address(escrow));
        treasury.setAdminFeeBps(50);
        vm.stopPrank();
    }

    function test_N20_emptyYear_firstDepositHasNoHistoricalFee() public {
        _enableWakala();
        skip(365 days);
        _deposit(1_000e6);
        assertEq(treasury.pendingFees(), 0);
        assertEq(vault.pendingWakalaFee(), 0);
        assertEq(vault.lastFeeAccrualTime(), block.timestamp);
        assertEq(vault.totalAssets(), 1_000e6);
    }

    function test_N20_yearLaterRedeem_previewEqualsActualNetOfFee() public {
        _enableWakala();
        _deposit(1_000e6);
        skip(365 days);
        assertEq(vault.pendingWakalaFee(), 5e6);
        uint256 shares = vault.balanceOf(alice);
        uint256 quoted = vault.previewRedeem(shares);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 received = vault.redeem(shares, alice, alice);
        assertEq(received, quoted);
        assertEq(usdc.balanceOf(alice) - before, quoted);
        assertApproxEqAbs(received, 995e6, 1);
        assertEq(treasury.pendingFees(), 5e6);
        assertEq(vault.pendingWakalaFee(), 0);
    }

    function test_N20_laterDepositor_onlyPaysAfterEntry() public {
        _enableWakala();
        _deposit(1_000e6);
        skip(365 days);
        uint256 quoted = vault.previewDeposit(1_000e6);
        usdc.mint(stranger, 1_000e6);
        vm.startPrank(stranger);
        usdc.approve(address(vault), 1_000e6);
        assertEq(vault.deposit(1_000e6, stranger), quoted);
        vm.stopPrank();
        assertApproxEqAbs(vault.previewRedeem(vault.balanceOf(stranger)), 1_000e6, 1);
        assertEq(treasury.pendingFees(), 5e6, "only existing AUM pays the old year");
        assertEq(vault.totalAssets(), 1_995e6);
        skip(365 days);
        assertEq(vault.pendingWakalaFee(), 9_975_000, "new AUM pays only its next year");
    }

    function test_N20_viewAndBooking_areNavNeutral() public {
        _enableWakala();
        _deposit(1_000e6);
        skip(365 days);
        uint256 nav = vault.totalAssets();
        uint256 fee = vault.pendingWakalaFee();
        uint256 quoted = vault.previewDeposit(1e6);
        _deposit(1e6);
        assertEq(treasury.pendingFees(), fee);
        assertEq(vault.pendingWakalaFee(), 0);
        assertEq(vault.totalAssets(), nav + 1e6);
        // Rebuild the same quote at the booked NAV, with pre-deposit virtual supply.
        assertEq(quoted, Math.mulDiv(1e6, vault.totalSupply() - quoted + 1e6, nav + 1));
    }

    function test_N20_badFeeSource_depositAndRedeemEmitSkip_preserveTimestamp() public {
        _enableWakala();
        _deposit(1_000e6);
        uint256 checkpoint = vault.lastFeeAccrualTime();
        vm.prank(address(vault));
        treasury.setFeeSource(stranger);
        skip(365 days);
        uint256 fee = vault.pendingWakalaFee();
        vm.expectEmit(false, false, false, true, address(vault));
        emit ShariahVault.WakalaAccrualSkipped(fee);
        _deposit(100e6);
        assertEq(vault.lastFeeAccrualTime(), checkpoint);
        uint256 shares = vault.balanceOf(alice) / 2;
        uint256 quoted = vault.previewRedeem(shares);
        fee = vault.pendingWakalaFee();
        vm.expectEmit(false, false, false, true, address(vault));
        emit ShariahVault.WakalaAccrualSkipped(fee);
        vm.prank(alice);
        assertEq(vault.redeem(shares, alice, alice), quoted);
        assertEq(vault.lastFeeAccrualTime(), checkpoint);
        assertEq(treasury.pendingFees(), 0);
    }

    function test_N20_roundedZero_keepsElapsedTime() public {
        _enableWakala();
        _deposit(1);
        uint256 checkpoint = vault.lastFeeAccrualTime();
        skip(1);
        assertEq(vault.pendingWakalaFee(), 0);
        _deposit(1);
        // A fee that rounds to zero must keep its elapsed time, so zero-value calls cannot erase accrual.
        assertEq(vault.lastFeeAccrualTime(), checkpoint);
    }

    function test_N20_frequentZeroCalls_doNotEraseAccrual() public {
        _enableWakala();
        _deposit(1e6); // small AUM so each 6 s slice rounds to zero fee
        uint256 start = block.timestamp;
        for (uint256 i; i < 50; ++i) {
            skip(6);
            vm.prank(alice);
            vault.deposit(0, alice);
        }
        assertEq(vault.lastFeeAccrualTime(), start, "interrupted interval keeps its start");
        skip(365 days);
        assertGt(vault.pendingWakalaFee(), 0);
    }

    function test_N20_claim_booksFeeBeforeProfitBound() public {
        _enableWakala();
        _deposit(1_000e6);
        usdc.mint(address(vault), 100e6);
        skip(365 days);
        uint256 fee = vault.pendingWakalaFee();
        uint256 available = vault.realizedProfit();
        _expectExceeds(available + 1, available);
        uint256 before = treasury.pendingFees();
        _claim(available);
        assertGe(treasury.pendingFees() - before, fee);
        assertEq(vault.pendingWakalaFee(), 0);
        assertEq(vault.lastFeeAccrualTime(), block.timestamp);
    }

    function test_N20_claim_badFeeSourceStillDistributes() public {
        _enableWakala();
        _deposit(1_000e6);
        vm.prank(address(vault));
        treasury.setFeeSource(stranger);
        usdc.mint(address(vault), 100e6);
        skip(365 days);
        uint256 checkpoint = vault.lastFeeAccrualTime();
        vm.expectEmit(false, false, false, true, address(vault));
        emit ShariahVault.WakalaAccrualSkipped(vault.pendingWakalaFee());
        _claim(10e6);
        assertEq(vault.lastFeeAccrualTime(), checkpoint);
        assertGt(vault.profitBase(), 1_000e6, "depositor share still checkpointed");
        assertEq(vault.lockedProfit(), 0, "claim does not lock the depositor share");
    }

    function test_N20_strictDeployment_badFeeSourceRollsBack() public {
        PrincipalAdapterM adapter = _appreciatingGold();
        _enableWakala();
        vm.prank(address(vault));
        treasury.setFeeSource(stranger);
        skip(1 days);
        uint256 deployed = vault.totalDeployed();
        uint256 balance = usdc.balanceOf(address(vault));
        vm.prank(manager);
        vm.expectRevert(TreasuryModule.NotFeeSource.selector);
        vault.deployCapitalAndExecute(address(adapter), 1e6, "");
        assertEq(vault.totalDeployed(), deployed);
        assertEq(usdc.balanceOf(address(vault)), balance);
    }

    function test_N21_withdrawalAlone_createsNoDeficit() public {
        _deposit(1_000e6);
        uint256 high = vault.highWaterMarkPerShare();
        vm.prank(alice);
        vault.withdraw(400e6, alice, alice);
        assertEq(vault.highWaterMarkPerShare(), high);
        assertEq(vault.hwmDeficit(), 0);
        assertEq(vault.highWaterMark(), 600e6);
    }

    function test_N21_depositDoesNotEraseGenuineDeficit() public {
        _deposit(1_000e6);
        usdc.burn(address(vault), 200e6);
        uint256 high = vault.highWaterMarkPerShare();
        uint256 deficit = vault.hwmDeficit();
        assertGt(deficit, 0);
        _deposit(1_000e6);
        assertEq(vault.highWaterMarkPerShare(), high);
        assertGe(vault.hwmDeficit(), deficit, "new supply cannot erase the old price gap");
    }

    function test_N21_lossAndPartialRecovery_managerZeroUntilOldHigh() public {
        _deposit(1_000e6);
        usdc.mint(address(vault), 300e6);
        // N-21: establish an earned peak with a full claim, not unprocessed yield.
        _claim(300e6);
        skip(vault.profitUnlockPeriod());
        uint256 high = vault.highWaterMarkPerShare();
        usdc.burn(address(vault), 200e6);
        _deposit(1_000e6);
        usdc.mint(address(vault), 250e6);
        uint256 fees = treasury.pendingFees();
        _claim(50e6);
        assertEq(treasury.pendingFees(), fees);
        assertEq(vault.highWaterMarkPerShare(), high);
        skip(vault.profitUnlockPeriod());
        assertGt(vault.hwmDeficit(), 0);
    }

    function test_N21_review1100_loss200_recovery210_noShareBelowHigh() public {
        _deposit(1_000e6);
        usdc.mint(address(vault), 100e6);
        // N-21: the earned high includes the FULL claim's locked depositor profit.
        _claim(100e6);
        uint256 high = vault.highWaterMarkPerShare();
        skip(vault.profitUnlockPeriod());
        usdc.burn(address(vault), 200e6);
        _deposit(1_000e6);
        // Recovery of 210 gross less 20 costs is still below the old processed high.
        usdc.mint(address(vault), 210e6);
        usdc.burn(address(vault), 20e6);
        assertGt(vault.hwmDeficit(), 0);
        _expectExceeds(1, 0);
        // Even a later claimable 50 remains recovery after the intervening deposit.
        usdc.mint(address(vault), 60e6);
        uint256 fees = treasury.pendingFees();
        _claim(50e6);
        assertEq(treasury.pendingFees(), fees);
        assertEq(vault.highWaterMarkPerShare(), high);
        assertGt(vault.hwmDeficit(), 0);
    }

    function test_N21_paperGold_neverAdvancesPerShareHigh() public {
        PrincipalAdapterM adapter = _appreciatingGold();
        uint256 high = vault.highWaterMarkPerShare();
        uint256 deficit = vault.hwmDeficit();
        adapter.setValue(400e6, true);
        assertEq(vault.highWaterMarkPerShare(), high);
        assertEq(vault.hwmDeficit(), deficit);
        usdc.mint(address(vault), 10e6);
        _claim(10e6);
        // Only processed cash profit moves the high; the larger paper gain stays excluded.
        assertEq(vault.highWaterMarkPerShare(), _processedPrice());
        assertGt(vault.highWaterMarkPerShare(), high);
        uint256 earnedHigh = vault.highWaterMarkPerShare();
        adapter.setValue(500e6, true);
        assertEq(vault.highWaterMarkPerShare(), earnedHigh);
        assertEq(vault.hwmDeficit(), 0);
    }

    function _currentLocked() internal view returns (uint256) {
        uint256 period = vault.profitUnlockPeriod();
        uint256 end = vault.unlockedAt();
        if (period == 0 || block.timestamp >= end || end < period || end - period > block.timestamp) return 0;
        return Math.mulDiv(vault.lockedProfit(), end - block.timestamp, period);
    }

    function _processedPrice() internal view returns (uint256) {
        uint256 nav = vault.totalAssets();
        uint256 gain = vault.goldUnrealizedGain();
        nav = nav > gain ? nav - gain : 0;
        nav = Math.min(nav + _currentLocked(), vault.profitBase());
        return Math.mulDiv(nav + 1, 1e18, vault.totalSupply() + 1e6);
    }

    function _zeroHurdle() internal {
        vm.prank(address(vault));
        treasury.setMusharakahParams(1000, 0);
    }

    function _assertSplitClaimMatchesFull(uint256 first) internal {
        _zeroHurdle(); // Isolate HWM/rounding from the time-dependent hurdle between claims.
        _deposit(1_000e6);
        usdc.mint(address(vault), 100e6);
        uint256 snapshot = vm.snapshot();
        _claim(100e6);
        uint256 fullManager = treasury.pendingFees();
        uint256 fullHigh = vault.highWaterMarkPerShare();
        uint256 fullBase = vault.profitBase();
        assertTrue(vm.revertTo(snapshot));
        _claim(first);
        assertEq(vault.hwmDeficit(), 0, "partial claim cannot invent recovery");
        assertEq(vault.highWaterMarkPerShare(), _processedPrice());
        skip(vault.profitUnlockPeriod());
        assertEq(vault.hwmDeficit(), 0, "unlock cannot invent recovery");
        assertEq(vault.realizedProfit(), 100e6 - first);
        uint256 firstManager = treasury.pendingFees();
        _claim(100e6 - first);
        assertGt(treasury.pendingFees(), firstManager, "remaining yield still pays manager");
        assertApproxEqAbs(treasury.pendingFees(), fullManager, 1);
        assertApproxEqAbs(vault.profitBase(), fullBase, 2);
        assertApproxEqAbs(vault.highWaterMarkPerShare(), fullHigh, 2000);
        assertEq(vault.hwmDeficit(), 0);
    }

    function test_N21_fullVsOneThenNinetyNine_sameManagerShare() public {
        _assertSplitClaimMatchesFull(1e6);
    }

    function testFuzz_N21_splitClaim_sameManagerShare(uint256 first) public {
        first = bound(first, 1e6, 99e6);
        _assertSplitClaimMatchesFull(first);
    }

    function test_N21_partialClaim_noDeficitThroughoutUnlock() public {
        _deposit(1_000e6);
        usdc.mint(address(vault), 100e6);
        _claim(1e6);
        uint256 high = vault.highWaterMarkPerShare();
        assertEq(high, _processedPrice());
        assertApproxEqAbs(vault.highWaterMark(), vault.profitBase(), 2);
        assertEq(vault.hwmDeficit(), 0);
        skip(vault.profitUnlockPeriod() / 2);
        assertEq(vault.hwmDeficit(), 0);
        assertEq(_processedPrice(), high);
        skip(vault.profitUnlockPeriod());
        assertEq(vault.hwmDeficit(), 0);
        assertEq(_processedPrice(), high);
    }

    function test_N21_fullClaim_recordsEarnedPeak() public {
        _deposit(1_000e6);
        usdc.mint(address(vault), 100e6);
        _claim(100e6);
        assertEq(vault.lockedProfit(), 0, "depositor share is not locked");
        assertEq(vault.highWaterMarkPerShare(), _processedPrice());
        assertApproxEqAbs(vault.highWaterMark(), vault.totalAssets(), 2);
        uint256 high = vault.highWaterMarkPerShare();
        skip(vault.profitUnlockPeriod());
        assertEq(_processedPrice(), high);
        assertEq(vault.hwmDeficit(), 0);
    }

    function test_N21_fullClaim_lossCashFlows_recoveryThenExcess() public {
        _zeroHurdle();
        _deposit(1_000e6);
        usdc.mint(address(vault), 100e6);
        _claim(100e6);
        uint256 high = vault.highWaterMarkPerShare();
        assertGt(high, 1e12);
        skip(vault.profitUnlockPeriod());
        usdc.burn(address(vault), 200e6);
        _deposit(1_000e6);
        assertEq(vault.highWaterMarkPerShare(), high);
        vm.prank(alice);
        vault.withdraw(100e6, alice, alice);
        assertEq(vault.highWaterMarkPerShare(), high);
        assertGt(vault.hwmDeficit(), 0);
        // Restore NAV above the checkpoint so a recovery-only claim is available.
        uint256 needed = vault.profitBase() - vault.totalAssets();
        usdc.mint(address(vault), needed + 50e6);
        uint256 deficit = vault.hwmDeficit();
        assertGt(deficit, 50e6);
        uint256 fees = treasury.pendingFees();
        _claim(50e6);
        assertEq(treasury.pendingFees(), fees);
        assertEq(vault.highWaterMarkPerShare(), high);
        uint256 remaining = vault.hwmDeficit();
        assertGt(remaining, 0);
        skip(vault.profitUnlockPeriod());
        assertEq(vault.hwmDeficit(), remaining);
        usdc.mint(address(vault), 500e6);
        uint256 gross = vault.realizedProfit();
        uint256 net = gross - gross * charity.charityBps() / 10_000;
        (, uint256 expected,) = treasury.calculateMusharakahSplitHWM(net, 0, 0, remaining);
        assertGt(expected, 0);
        _claim(gross);
        assertEq(treasury.pendingFees() - fees, expected);
        assertGt(_processedPrice(), high);
        assertEq(vault.highWaterMarkPerShare(), _processedPrice());
        assertEq(vault.hwmDeficit(), 0);
    }

    // ───────────── profitBase ─────────────

    function test_profitBase_startsZero_andTracksDepositsAndMints() public {
        assertEq(vault.profitBase(), 0);
        assertEq(vault.realizedProfit(), 0);
        _deposit(1_000e6);
        assertEq(vault.profitBase(), 1_000e6);
        uint256 shares = vault.previewDeposit(500e6);
        vm.prank(alice);
        uint256 assetsIn = vault.mint(shares, alice);
        assertEq(vault.profitBase(), 1_000e6 + assetsIn);
        assertEq(vault.realizedProfit(), 0, "deposits are not profit");
    }

    function test_principalOnlyVault_hasNoClaimableProfit() public {
        _deposit(1_000e6);
        assertEq(vault.realizedProfit(), 0);
        _expectExceeds(1, 0);
        _expectExceeds(1_000e6, 0);
        // Even the manager (non-owner) cannot claim principal.
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.ProfitExceedsRealized.selector, 1, 0));
        vault.claimMusharakahProfit(1);
        assertEq(usdc.balanceOf(address(vault)), 1_000e6);
    }

    function test_realizedProfit_equalsDonatedYield() public {
        _deposit(1_000e6);
        usdc.mint(address(vault), 100e6);
        assertEq(vault.realizedProfit(), 100e6);
        assertEq(vault.profitBase(), 1_000e6, "base unaffected by yield");
    }

    // ───────────── bound ─────────────

    function test_overLimit_reverts_exactLimit_succeeds() public {
        _deposit(1_000e6);
        usdc.mint(address(vault), 100e6);
        _expectExceeds(100e6 + 1, 100e6);

        vm.expectEmit(false, false, false, false, address(vault));
        emit ShariahVault.MusharakahProfitClaimed(0, 0, 0, 0, 0);
        _claim(100e6);
        assertEq(usdc.allowance(address(vault), address(escrow)), 0, "escrow allowance cleared");
    }

    function test_partialClaim_leavesRemainderClaimable() public {
        _deposit(1_000e6);
        usdc.mint(address(vault), 100e6);
        uint256 baseBefore = vault.profitBase();
        _claim(40e6);
        // N-22: preserve unprocessed yield while checkpointing only the distributed depositor share.
        uint256 firstShare = vault.profitBase() - baseBefore;
        assertGt(firstShare, 0, "waterfall returned a depositor share");
        assertEq(vault.lockedProfit(), 0);
        assertEq(vault.hurdlePrincipal(), vault.totalAssets());
        // The processed price includes the depositor share and excludes the unprocessed remainder.
        assertApproxEqAbs(vault.highWaterMark(), vault.profitBase(), 2);
        // With no lock the unprocessed remainder is claimable immediately and exactly.
        assertEq(vault.realizedProfit(), 60e6);
        _expectExceeds(60e6 + 1, 60e6);
        skip(vault.profitUnlockPeriod());
        assertEq(vault.realizedProfit(), 60e6, "time does not change the remainder");
        _claim(60e6);
        uint256 secondShare = vault.profitBase() - baseBefore - firstShare;
        assertGt(secondShare, 0);
        assertEq(vault.realizedProfit(), 0);
        skip(vault.profitUnlockPeriod());
        assertEq(vault.realizedProfit(), 0, "neither depositor share can be claimed twice");
        _expectExceeds(1, 0);
    }

    function testFuzz_partialClaims_preserveRemainderAndExcludeDistributedShare(uint256 first) public {
        first = bound(first, 1, 100e6 - 1);
        _deposit(1_000e6);
        usdc.mint(address(vault), 100e6);
        _claim(first);
        uint256 firstShare = vault.profitBase() - 1_000e6;
        assertEq(vault.lockedProfit(), 0);
        uint256 remainder = 100e6 - first;
        assertEq(vault.realizedProfit(), remainder, "remainder claimable immediately");
        skip(vault.profitUnlockPeriod());
        assertEq(vault.realizedProfit(), remainder);
        _expectExceeds(remainder + 1, remainder);
        _claim(remainder);
        assertGe(vault.profitBase(), 1_000e6 + firstShare);
        skip(vault.profitUnlockPeriod());
        assertEq(vault.realizedProfit(), 0);
        _expectExceeds(1, 0);
    }

    function test_partialClaims_zeroUnlockPeriod_remainderImmediatelyAvailable() public {
        vm.prank(owner);
        vault.setProfitUnlockPeriod(0);
        _deposit(1_000e6);
        usdc.mint(address(vault), 100e6);
        _claim(40e6);
        assertEq(vault.realizedProfit(), 60e6);
        _expectExceeds(60e6 + 1, 60e6);
        _claim(60e6);
        assertEq(vault.realizedProfit(), 0);
        _expectExceeds(1, 0);
    }

    function test_postClaim_checkpointIsNetNav_andSecondClaimReverts() public {
        _deposit(1_000e6);
        usdc.mint(address(vault), 100e6);
        _claim(100e6);
        assertEq(
            vault.profitBase(), vault.totalAssets() + vault.lockedProfit(),
            "checkpoint = post-claim net NAV + locked depositor share"
        );
        assertEq(vault.realizedProfit(), 0);
        assertEq(vault.hurdlePrincipal(), vault.totalAssets());
        _expectExceeds(1, 0);
    }

    function test_claimZero_revertsAtEscrow_notBound() public {
        _deposit(1_000e6);
        usdc.mint(address(vault), 10e6);
        vm.prank(owner);
        vm.expectRevert(PurificationEscrow.ZeroAmount.selector);
        vault.claimMusharakahProfit(0);
    }

    function test_escrowUnset_revertsBeforeBoundCheck() public {
        _deposit(1_000e6);
        vm.startPrank(owner);
        vault.setPurificationEscrow(address(0));
        vm.expectRevert(ShariahVault.PurificationEscrowNotSet.selector);
        vault.claimMusharakahProfit(1);
        vm.stopPrank();
    }

    function test_claim_onlyManagerOrOwner() public {
        _deposit(1_000e6);
        usdc.mint(address(vault), 10e6);
        vm.prank(stranger);
        vm.expectRevert(AutonomousVault.NotManager.selector);
        vault.claimMusharakahProfit(1);
        vm.prank(manager);
        vault.claimMusharakahProfit(10e6);
    }

    // ───────────── pro-rata reduction on withdraw / redeem ─────────────

    function test_withdraw_reducesProfitBaseProRata() public {
        _deposit(1_000e6);
        usdc.mint(address(vault), 100e6); // NAV 1_100
        uint256 base = vault.profitBase();
        uint256 nav = vault.totalAssets();
        vm.prank(alice);
        vault.withdraw(110e6, alice, alice); // 10% of NAV
        assertEq(vault.profitBase(), base - Math.mulDiv(base, 110e6, nav));
        assertEq(vault.profitBase(), 900e6);
        assertEq(vault.realizedProfit(), 90e6, "profit shrinks pro rata with the exit");
        _expectExceeds(90e6 + 1, 90e6);
    }

    function test_redeem_partialThenAll_baseReachesZero() public {
        _deposit(1_000e6);
        usdc.mint(address(vault), 100e6);
        uint256 half = vault.balanceOf(alice) / 2;
        uint256 base = vault.profitBase();
        uint256 nav = vault.totalAssets();
        vm.prank(alice);
        uint256 assets = vault.redeem(half, alice, alice);
        // checkpoint shrinks by shares burned / supply; allow 1-wei virtual-share rounding
        assertApproxEqAbs(vault.profitBase(), base - Math.mulDiv(base, assets, nav), 2);
        uint256 rest = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(rest, alice, alice);
        // Virtual-share rounding can leave a 1-wei residue in both base and NAV.
        assertLe(vault.profitBase(), 1);
        assertApproxEqAbs(vault.realizedProfit(), vault.totalAssets(), 1);
        assertLe(vault.totalAssets(), 2);
    }

    function testFuzz_withdraw_proRata_neverCreatesProfit(uint256 dep, uint256 yield_, uint256 w) public {
        dep = bound(dep, 1e6, 10_000e6);
        yield_ = bound(yield_, 0, 5_000e6);
        _deposit(dep);
        usdc.mint(address(vault), yield_);
        uint256 profitBefore = vault.realizedProfit();
        w = bound(w, 1, vault.maxWithdraw(alice));
        vm.prank(alice);
        vault.withdraw(w, alice, alice);
        assertLe(vault.realizedProfit(), profitBefore + 1, "exits cannot inflate realized profit");
        assertLe(vault.profitBase(), dep);
    }

    // ───────────── fees and locked profit reduce the bound ─────────────

    function test_pendingFees_reduceRealizedProfit() public {
        _deposit(1_000e6);
        usdc.mint(address(vault), 100e6);
        vm.prank(address(escrow));
        treasury.accrue(30e6);
        assertEq(vault.realizedProfit(), 70e6);
        _expectExceeds(70e6 + 1, 70e6);
    }

    function test_lockProfit_rejectsPrincipalAndOverlock() public {
        _deposit(1_000e6);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.ProfitExceedsRealized.selector, 1, 0));
        vault.lockProfit(1);
        usdc.mint(address(vault), 100e6);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.ProfitExceedsRealized.selector, 100e6 + 1, 100e6));
        vault.lockProfit(100e6 + 1);
        vm.prank(manager);
        vault.lockProfit(60e6);
        assertEq(vault.realizedProfit(), 40e6);
        vm.prank(owner);
        vault.lockProfit(40e6);
        assertEq(vault.lockedProfit(), 100e6);
        assertEq(vault.realizedProfit(), 0);
    }

    function test_lockProfit_onlyManagerOrOwner() public {
        vm.prank(stranger);
        vm.expectRevert(AutonomousVault.NotManager.selector);
        vault.lockProfit(0);
    }

    function test_lockedProfit_excludedUntilItUnlocks() public {
        _deposit(1_000e6);
        usdc.mint(address(vault), 100e6);
        vm.prank(owner);
        vault.lockProfit(100e6);
        assertEq(vault.realizedProfit(), 0);
        _expectExceeds(1, 0);
        skip(vault.profitUnlockPeriod());
        assertEq(vault.realizedProfit(), 100e6);
    }

    // ───────────── N-11 / N-24 regressions: no claim-time lock ─────────────

    function test_N11_entrantAfterClaim_getsNoUnlockDiscount() public {
        _deposit(1_000e6);
        usdc.mint(address(vault), 100e6);
        _claim(100e6);
        uint256 sharesNow = vault.previewDeposit(100e6);
        uint256 redeemNow = vault.previewRedeem(sharesNow);
        skip(vault.profitUnlockPeriod());
        // Price does not drift upward after the claim, so a fresh entrant captures nothing from holders.
        assertEq(vault.previewDeposit(100e6), sharesNow, "entry price must not change as time passes");
        assertEq(vault.previewRedeem(sharesNow), redeemNow);
    }

    function test_N24_depositAfterClaim_createsNoDeficit() public {
        _deposit(1_000e6);
        usdc.mint(address(vault), 100e6);
        _claim(100e6);
        assertEq(vault.hwmDeficit(), 0);
        _deposit(1_000e6);
        assertEq(vault.hwmDeficit(), 0, "a deposit cannot manufacture a recovery deficit");
        assertEq(vault.highWaterMarkPerShare(), _processedPrice());
    }

    // ───────────── observation: depositor share after a claim ─────────────

    /// @dev The distributed depositor share is counted in the checkpoint and sits in NAV
    ///      immediately, so it is never claimable again.
    function test_depositorShare_doesNotReenterRealizedProfit() public {
        _deposit(1_000e6);
        usdc.mint(address(vault), 100e6);
        uint256 baseBefore = vault.profitBase();
        _claim(100e6);
        assertGt(vault.profitBase(), baseBefore, "waterfall returned a depositor share");
        assertEq(vault.lockedProfit(), 0, "depositor share is not locked");
        assertEq(vault.realizedProfit(), 0);
        skip(vault.profitUnlockPeriod());
        assertEq(vault.realizedProfit(), 0, "depositor share must not be re-claimable");
        // Genuinely new profit is still claimable.
        usdc.mint(address(vault), 40e6);
        assertEq(vault.realizedProfit(), 40e6);
    }
}

contract TaskMN01V1Test is TaskMN01Base {
    function _newVault() internal override returns (ShariahVault) {
        return new ShariahVault(IERC20(address(usdc)), owner, DOM, address(treasury), address(0));
    }
}

contract TaskMN01V2Test is TaskMN01Base {
    function _newVault() internal override returns (ShariahVault) {
        return new ShariahVaultV2(
            IERC20(address(usdc)), owner, DOM, address(treasury), address(0), address(registry)
        );
    }
}
