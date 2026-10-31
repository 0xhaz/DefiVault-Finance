// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RemoteRecipientFixture, MockTokenMessengerI} from "./TaskITest.Base.t.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AutonomousVault} from "../AutonomousVault.sol";
import {ShariahVault} from "../ShariahVault.sol";
import {ShariahVaultV2} from "../ShariahVaultV2.sol";
import {ShariahAdapterRegistry} from "../ShariahAdapterRegistry.sol";
import {TreasuryModule} from "../TreasuryModule.sol";
import {RiskTieredExecutor} from "../RiskTieredExecutor.sol";
import {ScoreAggregator} from "../ScoreAggregator.sol";
import {ShariahScoreAggregator} from "../ShariahScoreAggregator.sol";
import {GoldExchangeAdapter} from "../adapters/GoldExchangeAdapter.sol";
import {GoldAllocationAdapter} from "../adapters/GoldAllocationAdapter.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {MockAllocatedGold} from "../test-helpers/MockAllocatedGold.sol";
import {MockXauUsdAggregator} from "../test-helpers/MockXauUsdAggregator.sol";
import {MockGoldRouterN, MockStrategyAdapterN} from "./TaskNTest.Base.t.sol";

/// @dev Adapter whose deploy always reverts, used to prove atomic rollback.
contract RevertingAdapterM {
    address public vault;

    constructor(address v) {
        vault = v;
    }

    function deploy(uint256) external pure returns (uint256) {
        revert("adapter: nope");
    }

    function recall(uint256) external pure returns (uint256) {
        return 0;
    }

    function currentValue() external pure returns (uint256) {
        return 0;
    }

    function protocolName() external pure returns (string memory) {
        return "RevertingAdapterM";
    }
}

/// @dev N-06 adapter with explicit proceeds/remaining value and an observation during atomic deployment.
contract PrincipalAdapterM {
    ShariahVault public immutable vault;
    IERC20 public immutable token;
    uint256 public currentValue;
    uint256 public proceeds;
    uint256 public reported;
    uint256 public remaining;
    uint256 public principalDuringDeploy;
    bool public isPriceSane = true;

    constructor(ShariahVault vault_) {
        vault = vault_;
        token = IERC20(vault_.asset());
    }

    function isGoldStrategy() external pure returns (bool) { return true; }

    function setValue(uint256 value, bool sane) external {
        currentValue = value;
        isPriceSane = sane;
    }

    function setRecall(uint256 proceeds_, uint256 reported_, uint256 remaining_) external {
        proceeds = proceeds_;
        reported = reported_;
        remaining = remaining_;
    }

    function deploy(uint256 amount) external returns (uint256) {
        require(msg.sender == address(vault), "only vault");
        principalDuringDeploy = vault.principalOf(address(this));
        // Exercise the new NAV/dust dependency while adapter execution is in progress.
        vault.totalAssets();
        vault.effectiveDustThreshold();
        currentValue += amount;
        return amount;
    }

    function recall(uint256) external returns (uint256) {
        require(msg.sender == address(vault), "only vault");
        token.transfer(address(vault), proceeds);
        currentValue = remaining;
        return reported;
    }
}

/// @dev Shared N-02 fixture + tests, run once against ShariahVault (V1) and once against ShariahVaultV2.
abstract contract TaskMN02Base is Test {
    address internal owner = makeAddr("owner");
    address internal manager = makeAddr("manager");
    address internal alice = makeAddr("alice");
    address internal stranger = makeAddr("stranger");

    uint32 internal constant DOM = 26;
    uint256 internal constant PRICE = 3_300e6;
    uint256 internal constant DEPOSIT = 1_000_000e6;
    uint8 internal constant GOLD_SPREAD = 1;
    uint8 internal constant HALAL_LP = 2;

    MockERC20 internal usdc;
    MockAllocatedGold internal paxg;
    MockXauUsdAggregator internal oracle;
    MockGoldRouterN internal router;
    TreasuryModule internal treasury;
    ShariahVault internal vault;
    GoldExchangeAdapter internal gold;
    MockStrategyAdapterN internal strat;
    RevertingAdapterM internal bad;

    function _makeVault() internal virtual returns (ShariahVault);
    function _screen(address adapter) internal virtual;
    function _unscreenedRevert(address adapter) internal pure virtual returns (bytes memory);

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);
        paxg = new MockAllocatedGold();
        oracle = new MockXauUsdAggregator();
        router = new MockGoldRouterN(address(usdc), PRICE);
        treasury = new TreasuryModule("Shariah", address(0), address(usdc), 0, 0, 0, owner);
        vault = _makeVault();
        gold = new GoldExchangeAdapter(
            address(usdc), address(paxg), address(router), 3000, address(vault), owner, address(oracle)
        );
        strat = new MockStrategyAdapterN(address(vault));
        bad = new RevertingAdapterM(address(vault));
        paxg.mint(address(router), 1_000_000e18);
        usdc.mint(address(router), 50_000_000e6);

        vm.startPrank(owner);
        vault.setManager(manager);
        vault.setGoldSpreadAdapter(address(gold));
        vm.stopPrank();

        usdc.mint(alice, DEPOSIT);
        vm.startPrank(alice);
        usdc.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, alice);
        vm.stopPrank();

        _screen(address(gold));
        _screen(address(strat));
        _screen(address(bad));
        oracle.setPrice(int256(PRICE * 100)); // screening advances time; refresh before gold buys.
    }

    function _bytes32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    /// @dev Runs both entry points and returns the (identical) failing returndata.
    function _sameRevert(address caller, address strategy, uint256 amount) internal returns (bytes memory r1) {
        vm.prank(caller);
        (bool ok1, bytes memory a) = address(vault).call(
            abi.encodeCall(vault.deployCapital, (strategy, amount, bytes("")))
        );
        vm.prank(caller);
        (bool ok2, bytes memory b) = address(vault).call(
            abi.encodeCall(vault.deployCapitalAndExecute, (strategy, amount, bytes("")))
        );
        assertFalse(ok1, "deployCapital must revert");
        assertFalse(ok2, "deployCapitalAndExecute must revert");
        assertEq(a, b, "identical revert data");
        r1 = a;
    }

    // N-06 exercises both inherited vault versions with cost accounting independent of recall proceeds.
    function test_principal_lossGainAndPartialRecall() public {
        PrincipalAdapterM adapter = new PrincipalAdapterM(vault);
        _screen(address(adapter));
        // N-23: the gold mock must be linked and funded atomically to retain recall-accounting coverage.
        vm.prank(owner);
        vault.setGoldAllocationAdapter(address(adapter));
        vm.prank(manager);
        vault.deployCapitalAndExecute(address(adapter), 1_000e6, "");
        assertEq(vault.principalOf(address(adapter)), 1_000e6);
        adapter.setValue(1_000e6, true);
        adapter.setRecall(300e6, 999e6, 600e6);
        vm.prank(manager);
        vault.recallCapital(address(adapter), 400e6);
        assertEq(vault.principalOf(address(adapter)), 600e6);
        assertEq(vault.totalDeployed(), 600e6);
        assertEq(vault.totalAssets(), DEPOSIT - 100e6);
        usdc.mint(address(adapter), 100e6);
        adapter.setRecall(800e6, 1, 0);
        vm.expectEmit(true, false, false, true, address(vault));
        emit AutonomousVault.CapitalRecalledFromAdapter(address(adapter), 1, 800e6);
        vm.expectEmit(true, false, false, true, address(vault));
        emit ShariahVault.PrincipalRetired(address(adapter), 600e6, 800e6);
        vm.prank(manager);
        vault.recallCapital(address(adapter), 1);
        assertEq(vault.principalOf(address(adapter)), 0);
        assertEq(vault.totalDeployed(), 0);
        assertEq(vault.totalAssets(), DEPOSIT + 100e6);
        assertEq(vault.realizedProfit(), 100e6);
    }

    // N-06 books new principal after deploy returns and floors losses without booking unrealized gains.
    function test_goldWritedown_atomicOrderingAndProfitBound() public {
        PrincipalAdapterM adapter = new PrincipalAdapterM(vault);
        _screen(address(adapter));
        vm.prank(owner);
        vault.setGoldAllocationAdapter(address(adapter));
        vm.prank(manager);
        vault.deployCapitalAndExecute(address(adapter), 100_000e6, "");
        assertEq(adapter.principalDuringDeploy(), 0);
        assertEq(vault.principalOf(address(adapter)), 100_000e6);
        vm.prank(manager);
        vault.deployCapitalAndExecute(address(adapter), 50_000e6, "");
        assertEq(adapter.principalDuringDeploy(), 100_000e6);
        assertEq(vault.principalOf(address(adapter)), 150_000e6);
        adapter.setValue(180_000e6, true);
        assertEq(vault.goldWritedown(), 0);
        // G-1 marks appreciation for share pricing while keeping the realized-profit bound unchanged.
        assertEq(vault.totalAssets(), DEPOSIT + 30_000e6);
        assertEq(vault.goldUnrealizedGain(), 30_000e6);
        assertEq(vault.realizedProfit(), 0);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.ProfitExceedsRealized.selector, 1, 0));
        vault.lockProfit(1);
        adapter.setValue(120_000e6, false);
        assertEq(vault.goldWritedown(), 30_000e6);
        assertEq(vault.totalAssets(), DEPOSIT - 30_000e6);
        assertEq(vault.effectiveDustThreshold(), 1e6);
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
        adapter.setRecall(120_000e6, 150_000e6, 0);
        vm.prank(manager);
        vault.recallCapital(address(adapter), 1);
        assertEq(vault.goldWritedown(), 0);
        assertEq(vault.totalAssets(), DEPOSIT - 30_000e6);
        assertEq(vault.totalDeployed(), 0);
        assertGt(vault.maxDeposit(alice), 0);
    }

    // N-06 uses pre-funding marked NAV for gold caps and aggregates both gold losses with a zero floor.
    function test_goldWritedown_capBothSlotsAndFloor() public {
        PrincipalAdapterM adapter = new PrincipalAdapterM(vault);
        _screen(address(adapter));
        vm.prank(owner);
        vault.setGoldAllocationAdapter(address(adapter));
        vm.prank(manager);
        vault.deployCapitalAndExecute(address(adapter), 100_000e6, "");
        adapter.setValue(80_000e6, true);
        uint256 markedNav = DEPOSIT - 20_000e6;
        uint256 cap = markedNav * vault.MAX_GOLD_BPS() / 10_000;
        uint256 amount = cap - 80_000e6;
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.GoldCapExceeded.selector, cap + 1, cap));
        vault.deployCapitalAndExecute(address(adapter), amount + 1, "");
        vm.prank(manager);
        vault.deployCapitalAndExecute(address(adapter), amount, "");
        assertEq(vault.totalAssets(), markedNav);
        assertEq(vault.principalOf(address(adapter)), 100_000e6 + amount);
        // Aggregate writedowns cover independently funded positions in both slots.
        adapter.setValue(270_000e6, true);
        PrincipalAdapterM spread = new PrincipalAdapterM(vault);
        _screen(address(spread));
        vm.prank(owner);
        vault.setGoldSpreadAdapter(address(spread));
        vm.prank(manager);
        vault.deployCapitalAndExecute(address(spread), 10_000e6, "");
        spread.setValue(8_000e6, true);
        assertEq(vault.goldWritedown(), 46_000e6);
        spread.setValue(0, false);
        adapter.setValue(0, false);
        usdc.burn(address(vault), usdc.balanceOf(address(vault)));
        assertEq(vault.totalAssets(), 0, "full writedown floors NAV");
    }

    // N-06 keeps the base pause/auth checks and reported-return fallback, including a full zero-proceeds loss.
    function test_recallPrincipal_fallbackZeroLossAndGuards() public {
        PrincipalAdapterM adapter = new PrincipalAdapterM(vault);
        _screen(address(adapter));
        // N-23: the gold mock must be linked and funded atomically to retain recall-accounting coverage.
        vm.prank(owner);
        vault.setGoldAllocationAdapter(address(adapter));
        vm.prank(manager);
        vault.deployCapitalAndExecute(address(adapter), 1_000e6, "");
        adapter.setValue(1_000e6, true);
        vm.prank(stranger);
        vm.expectRevert(AutonomousVault.NotManager.selector);
        vault.recallCapital(address(adapter), 100e6);
        // Pause stops new deployment but must NOT trap capital: recall works while paused.
        vm.prank(owner);
        vault.setPaused(true);
        vm.prank(manager);
        vm.expectRevert(AutonomousVault.Paused.selector);
        vault.deployCapital(address(strat), 1e6, "");
        usdc.burn(address(adapter), 1_000e6);
        adapter.setRecall(0, 7, 500e6);
        vm.expectEmit(true, false, false, true, address(vault));
        emit AutonomousVault.CapitalRecalledFromAdapter(address(adapter), 100e6, 7);
        vm.prank(manager);
        vault.recallCapital(address(adapter), 100e6);
        assertEq(vault.principalOf(address(adapter)), 900e6);
        vm.prank(owner);
        vault.setPaused(false);
        adapter.setRecall(0, 0, 0);
        vm.prank(owner);
        vault.recallCapital(address(adapter), 1);
        assertEq(vault.principalOf(address(adapter)), 0);
        assertEq(vault.totalDeployed(), 0);
        assertEq(vault.totalAssets(), DEPOSIT - 1_000e6);
    }

    function test_returnCapital_excessIsProfit_otherPositionsUntouched() public {
        PrincipalAdapterM adapter = new PrincipalAdapterM(vault);
        _screen(address(adapter));
        // N-23: link and atomically fund the gold mock while preserving excess-return accounting intent.
        vm.prank(owner);
        vault.setGoldAllocationAdapter(address(adapter));
        vm.startPrank(manager);
        vault.deployCapitalAndExecute(address(adapter), 100e6, "");
        vault.deployCapital(address(strat), 50e6, "");
        vm.stopPrank();
        usdc.mint(address(adapter), 40e6);
        // The linked mock must report the closed position after the full return, not phantom gold.
        adapter.setValue(0, true);
        vm.prank(address(adapter));
        usdc.approve(address(vault), 140e6);
        vm.expectEmit(true, false, false, true, address(vault));
        emit AutonomousVault.CapitalReturned(address(adapter), 140e6);
        vm.expectEmit(true, false, false, true, address(vault));
        emit ShariahVault.PrincipalRetired(address(adapter), 100e6, 140e6);
        vm.prank(manager);
        vault.returnCapital(address(adapter), 140e6);
        assertEq(vault.principalOf(address(adapter)), 0);
        assertEq(vault.totalDeployed(), 50e6);
        assertEq(vault.principalOf(address(strat)), 50e6);
        assertEq(usdc.balanceOf(address(strat)), 50e6);
        assertEq(vault.totalAssets(), DEPOSIT + 40e6);
        assertEq(vault.realizedProfit(), 40e6);
    }

    function test_returnCapital_partialRetiresOnlyReturnedCost_andKeepsGuards() public {
        vm.prank(manager);
        vault.deployCapital(address(strat), 100e6, "");
        vm.prank(address(strat));
        usdc.approve(address(vault), 100e6);
        vm.prank(stranger);
        vm.expectRevert(AutonomousVault.NotManager.selector);
        vault.returnCapital(address(strat), 40e6);
        // Pause stops new deployment but must NOT block returning capital.
        vm.prank(owner);
        vault.setPaused(true);
        vm.prank(manager);
        vm.expectRevert(AutonomousVault.Paused.selector);
        vault.deployCapital(address(strat), 1e6, "");
        vm.expectEmit(true, false, false, true, address(vault));
        emit ShariahVault.PrincipalRetired(address(strat), 40e6, 40e6);
        vm.prank(owner);
        vault.returnCapital(address(strat), 40e6);
        vm.prank(owner);
        vault.setPaused(false);
        assertEq(vault.principalOf(address(strat)), 60e6);
        assertEq(vault.totalDeployed(), 60e6);
        assertEq(vault.totalAssets(), DEPOSIT);
        assertEq(vault.realizedProfit(), 0);
    }

    function test_depositBeforeRecall_cannotCaptureGoldAppreciation() public {
        vm.prank(manager);
        vault.deployCapitalAndExecute(address(gold), 33_000e6, "");
        oracle.setPrice(int256(3_960e8));
        router.setPrice(3_960e6);
        uint256 nav = DEPOSIT + 6_600e6;
        assertEq(vault.totalAssets(), nav);
        address bob = makeAddr("bob");
        uint256 amount = 100_000e6;
        uint256 supply = vault.totalSupply();
        uint256 fairShares = amount * (supply + 1e6) / (nav + 1);
        uint256 oldValue = vault.convertToAssets(vault.balanceOf(alice));
        usdc.mint(bob, amount);
        vm.startPrank(bob);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, bob);
        vm.stopPrank();
        assertEq(shares, fairShares, "entry pays for appreciation already owned by holders");
        assertLt(shares, amount * (supply + 1e6) / (DEPOSIT + 1));
        uint256 bobBefore = vault.convertToAssets(shares);
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), oldValue, 1);
        vm.prank(manager);
        vault.recallCapital(address(gold), 33_000e6);
        assertEq(vault.totalAssets(), nav + amount);
        assertEq(vault.realizedProfit(), 6_600e6);
        assertEq(vault.convertToAssets(shares), bobBefore, "recall creates no depositor windfall");
        vm.prank(bob);
        uint256 proceeds = vault.redeem(shares, bob, bob);
        assertLe(proceeds, amount, "new depositor cannot extract pre-entry appreciation");
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), oldValue, 1);
    }

    function test_mintAndWithdraw_useMarkedGoldNav_andShareBasedCheckpoint() public {
        vm.prank(manager);
        vault.deployCapitalAndExecute(address(gold), 33_000e6, "");
        oracle.setPrice(int256(3_960e8));
        uint256 nav = DEPOSIT + 6_600e6;
        uint256 supply = vault.totalSupply();
        uint256 shares = 10_000e6 * 1e6;
        uint256 numerator = shares * (nav + 1);
        uint256 fairAssets = (numerator + supply + 1e6 - 1) / (supply + 1e6);
        address bob = makeAddr("bob");
        usdc.mint(bob, fairAssets);
        vm.startPrank(bob);
        usdc.approve(address(vault), fairAssets);
        assertEq(vault.mint(shares, bob), fairAssets, "mint pays marked NAV rounded up");
        vm.stopPrank();
        assertEq(vault.profitBase(), DEPOSIT + fairAssets);
        assertEq(vault.realizedProfit(), 0);
        uint256 base = vault.profitBase();
        uint256 supplyBefore = vault.totalSupply();
        uint256 burnShares = vault.previewWithdraw(1_000e6);
        vm.prank(bob);
        assertEq(vault.withdraw(1_000e6, bob, bob), burnShares);
        assertEq(vault.profitBase(), base - base * burnShares / supplyBefore);
        assertEq(vault.realizedProfit(), 0, "an exit does not distribute unrealized gains");
        oracle.setPrice(int256(2_640e8));
        assertEq(vault.goldUnrealizedGain(), 0);
        assertEq(vault.goldWritedown(), 6_600e6);
        assertEq(vault.totalAssets(), DEPOSIT + fairAssets - 1_000e6 - 6_600e6);
    }

    function test_staleOracle_marksCachedAppreciationWithHaircut() public {
        vm.prank(manager);
        vault.deployCapitalAndExecute(address(gold), 33_000e6, "");
        oracle.setPrice(int256(3_960e8));
        gold.pokePrice();
        assertEq(vault.goldUnrealizedGain(), 6_600e6);
        skip(gold.maxStalenessSecs() + 1);
        uint256 haircutValue = 39_600e6 * (10_000 - gold.staleHaircutBps()) / 10_000;
        assertEq(gold.currentValue(), haircutValue);
        assertEq(vault.goldUnrealizedGain(), haircutValue - 33_000e6);
        assertEq(vault.totalAssets(), DEPOSIT - 33_000e6 + haircutValue);
        assertEq(vault.realizedProfit(), 0);
        assertEq(vault.maxDeposit(alice), 0, "material stale position still blocks entry");
        assertEq(vault.maxMint(alice), 0);
    }

    function test_goldGain_zeroAndDuplicateSlotsCountOnce() public {
        vm.prank(owner);
        vault.setGoldAllocationAdapter(address(gold));
        vm.prank(manager);
        vault.deployCapitalAndExecute(address(gold), 33_000e6, "");
        oracle.setPrice(int256(3_960e8));
        assertEq(vault.goldUnrealizedGain(), 6_600e6);
        assertEq(vault.totalAssets(), DEPOSIT + 6_600e6);
        oracle.setPrice(int256(2_640e8));
        assertEq(vault.goldUnrealizedGain(), 0);
        assertEq(vault.goldWritedown(), 6_600e6);
        assertEq(vault.totalAssets(), DEPOSIT - 6_600e6);
    }

    function test_markedNav_capsDustAndRealizedFeeBase() public {
        PrincipalAdapterM adapter = new PrincipalAdapterM(vault);
        _screen(address(adapter));
        vm.prank(owner);
        vault.setGoldAllocationAdapter(address(adapter));
        vm.prank(manager);
        vault.deployCapitalAndExecute(address(adapter), 100_000e6, "");
        adapter.setValue(150_000e6, true);
        uint256 nav = DEPOSIT + 50_000e6;
        assertEq(vault.totalAssets(), nav);
        vm.startPrank(owner);
        vault.proposeDustThreshold(nav * vault.MAX_DUST_BPS() / 10_000);
        vm.stopPrank();
        skip(30 days);
        vm.prank(owner);
        vault.confirmDustThreshold();
        assertEq(vault.effectiveDustThreshold(), nav * vault.MAX_DUST_BPS() / 10_000);
        uint256 goldCap = nav * vault.MAX_GOLD_BPS() / 10_000;
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.GoldCapExceeded.selector, goldCap + 1, goldCap));
        vault.deployCapitalAndExecute(address(adapter), goldCap - 150_000e6 + 1, "");
        uint256 deployCap = nav * vault.maxAllocationBps() / 10_000;
        uint256 overAllocation = deployCap - vault.totalDeployed() + 1;
        vm.prank(manager);
        vm.expectRevert(AutonomousVault.AllocationExceedsLimit.selector);
        vault.deployCapital(address(strat), overAllocation, "");
        vm.startPrank(owner);
        treasury.setFeeSource(address(vault));
        treasury.setAdminFeeBps(50);
        vm.stopPrank();
        uint256 elapsed = block.timestamp - vault.lastFeeAccrualTime();
        uint256 expectedFee = DEPOSIT * 50 * elapsed / (10_000 * 365 days);
        // N-20: marked previews deduct the same realized-AUM fee before and after strict booking.
        assertEq(vault.pendingWakalaFee(), expectedFee);
        uint256 netNav = vault.totalAssets();
        uint256 quote = vault.previewDeposit(1e6);
        vm.prank(manager);
        vault.deployCapital(address(strat), 1e6, "");
        assertEq(vault.totalAssets(), netNav);
        assertEq(vault.previewDeposit(1e6), quote);
        assertEq(vault.pendingWakalaFee(), 0);
        assertEq(treasury.pendingFees(), expectedFee, "paper gains do not inflate the fee base");
        assertEq(vault.totalAssets(), nav - expectedFee, "fee liability deducted once");
    }

    function test_retiredSpread_blocksBothFundingPaths_evenWhileScreened() public {
        vm.prank(owner);
        vault.setGoldSpreadAdapter(address(0));
        assertTrue(vault.retiredGoldAdapter(address(gold)));
        assertEq(_sameRevert(manager, address(gold), 1e6),
            abi.encodeWithSelector(ShariahVault.RetiredGoldAdapter.selector, address(gold)));
        assertEq(usdc.balanceOf(address(gold)), 0);
        assertEq(vault.principalOf(address(gold)), 0);
        assertEq(vault.totalDeployed(), 0);
    }

    function test_retiredAllocation_replacementBlocksFunding_relinkClearsEitherSlot() public {
        PrincipalAdapterM adapter = new PrincipalAdapterM(vault);
        _screen(address(adapter));
        vm.startPrank(owner);
        vault.setGoldAllocationAdapter(address(adapter));
        vault.setGoldAllocationAdapter(address(adapter));
        assertFalse(vault.retiredGoldAdapter(address(adapter)), "same address is not retirement");
        vault.setGoldAllocationAdapter(address(gold));
        vm.stopPrank();
        assertTrue(vault.retiredGoldAdapter(address(adapter)));
        assertEq(_sameRevert(manager, address(adapter), 1e6),
            abi.encodeWithSelector(ShariahVault.RetiredGoldAdapter.selector, address(adapter)));
        vm.prank(owner);
        vault.setGoldSpreadAdapter(address(adapter));
        assertFalse(vault.retiredGoldAdapter(address(adapter)), "linking either slot revives adapter");
        vm.prank(manager);
        vault.deployCapitalAndExecute(address(adapter), 1e6, "");
        assertEq(vault.principalOf(address(adapter)), 1e6);
    }

    function test_retiredSpread_relinkAllocation_restoresCapAndDepositGate() public {
        vm.startPrank(owner);
        vault.setGoldSpreadAdapter(address(0));
        vault.setGoldAllocationAdapter(address(gold));
        vm.stopPrank();
        assertFalse(vault.retiredGoldAdapter(address(gold)));
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.GoldCapExceeded.selector, 300_000e6 + 1, 300_000e6));
        vault.deployCapitalAndExecute(address(gold), 300_000e6 + 1, "");
        oracle.setPrice(int256(PRICE * 100));
        vm.prank(manager);
        vault.deployCapitalAndExecute(address(gold), 1_000e6, "");
        skip(gold.maxStalenessSecs() + 1);
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
    }

    function test_neverTrackedNonGold_bothFundingPathsUnaffectedAfterRetirement() public {
        vm.prank(owner);
        vault.setGoldSpreadAdapter(address(0));
        assertFalse(vault.retiredGoldAdapter(address(strat)));
        vm.startPrank(manager);
        vault.deployCapital(address(strat), 1e6, "");
        vault.deployCapitalAndExecute(address(strat), 2e6, "");
        vm.stopPrank();
        assertEq(vault.principalOf(address(strat)), 3e6);
        assertEq(usdc.balanceOf(address(strat)), 3e6);
        assertEq(strat.lastDeployCaller(), address(vault));
    }

    function test_unlinkedGoldMock_bothFundingPathsRevert_beforeAnyAccounting() public {
        PrincipalAdapterM adapter = new PrincipalAdapterM(vault);
        _screen(address(adapter));
        assertTrue(adapter.isGoldStrategy());
        assertFalse(vault.retiredGoldAdapter(address(adapter)));
        assertEq(_sameRevert(manager, address(adapter), 1e6),
            abi.encodeWithSelector(ShariahVault.UntrackedGoldAdapter.selector, address(adapter)));
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(vault.principalOf(address(adapter)), 0);
        assertEq(vault.totalDeployed(), 0);
        assertEq(vault.totalAssets(), DEPOSIT);
        vm.prank(owner);
        vault.setGoldAllocationAdapter(address(adapter));
        vm.prank(manager);
        vault.deployCapitalAndExecute(address(adapter), 1e6, "");
        assertEq(vault.principalOf(address(adapter)), 1e6);
        adapter.setValue(2e6, false);
        assertEq(vault.totalAssets(), DEPOSIT + 1e6, "linked gold is marked");
        adapter.setValue(0, false);
        assertEq(vault.totalAssets(), DEPOSIT - 1e6, "linked loss is marked");
    }

    function test_neverLinkedRealGold_bothFundingPathsRevert() public {
        GoldExchangeAdapter unlinked = new GoldExchangeAdapter(
            address(usdc), address(paxg), address(router), 3000, address(vault), owner, address(oracle)
        );
        _screen(address(unlinked));
        assertTrue(unlinked.isGoldStrategy());
        assertFalse(vault.retiredGoldAdapter(address(unlinked)));
        assertEq(_sameRevert(manager, address(unlinked), 1e6),
            abi.encodeWithSelector(ShariahVault.UntrackedGoldAdapter.selector, address(unlinked)));
        assertEq(usdc.balanceOf(address(unlinked)), 0);
        assertEq(vault.totalDeployed(), 0);
    }

    function test_neverLinkedRealAllocation_bothFundingPathsRevert() public {
        GoldAllocationAdapter unlinked = new GoldAllocationAdapter(
            address(usdc), address(paxg), address(router), 3000, address(oracle), address(vault), 3600, owner
        );
        _screen(address(unlinked));
        assertTrue(unlinked.isGoldStrategy());
        assertEq(_sameRevert(manager, address(unlinked), 1e6),
            abi.encodeWithSelector(ShariahVault.UntrackedGoldAdapter.selector, address(unlinked)));
        assertEq(usdc.balanceOf(address(unlinked)), 0);
        assertEq(vault.principalOf(address(unlinked)), 0);
    }

    function test_retiredGold_errorPrecedesMarkerAndPause() public {
        vm.startPrank(owner);
        vault.setGoldSpreadAdapter(address(0));
        vault.setPaused(true);
        vm.stopPrank();
        assertEq(_sameRevert(manager, address(gold), 1e6),
            abi.encodeWithSelector(ShariahVault.RetiredGoldAdapter.selector, address(gold)));
    }

    function test_linkedGoldMock_capAndDepositGateRemainEnforced() public {
        PrincipalAdapterM adapter = new PrincipalAdapterM(vault);
        _screen(address(adapter));
        vm.prank(owner);
        vault.setGoldAllocationAdapter(address(adapter));
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.UseAtomicDeploy.selector, address(adapter)));
        vault.deployCapital(address(adapter), 2e6, "");
        vm.prank(manager);
        vault.deployCapitalAndExecute(address(adapter), 2e6, "");
        adapter.setValue(2e6, false);
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
        uint256 cap = vault.totalAssets() * vault.MAX_GOLD_BPS() / 10_000;
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.GoldCapExceeded.selector, cap + 1, cap));
        vault.deployCapitalAndExecute(address(adapter), cap - 2e6 + 1, "");
    }

    function test_markerFalseAndReverting_nonGoldBothPathsUnaffected() public {
        bytes memory marker = abi.encodeWithSignature("isGoldStrategy()");
        vm.mockCall(address(strat), marker, abi.encode(false));
        vm.startPrank(manager);
        vault.deployCapital(address(strat), 1e6, "");
        vault.deployCapitalAndExecute(address(strat), 2e6, "");
        vm.stopPrank();
        vm.clearMockedCalls();
        vm.mockCallRevert(address(strat), marker, bytes("no marker"));
        vm.startPrank(manager);
        vault.deployCapital(address(strat), 3e6, "");
        vault.deployCapitalAndExecute(address(strat), 4e6, "");
        vm.stopPrank();
        assertEq(vault.principalOf(address(strat)), 10e6);
        assertEq(usdc.balanceOf(address(strat)), 10e6);
    }

    function test_eoaWithoutMarker_transferWorks_atomicKeepsExistingFailure() public {
        address eoa = makeAddr("plain recipient");
        _screen(eoa);
        vm.prank(manager);
        vault.deployCapital(eoa, 1e6, "");
        assertEq(usdc.balanceOf(eoa), 1e6);
        vm.prank(manager);
        (bool ok,) = address(vault).call(
            abi.encodeCall(vault.deployCapitalAndExecute, (eoa, 2e6, bytes("")))
        );
        assertFalse(ok, "EOA still cannot execute an adapter returning uint256");
        assertEq(vault.principalOf(eoa), 1e6);
        assertEq(usdc.balanceOf(eoa), 1e6, "atomic failure rolls funding back");
    }

    // ───────────── core behaviour ─────────────

    function test_realOnlyVaultGoldAdapter_succeedsAtomically() public {
        uint256 amount = 33_000e6;
        vm.expectEmit(true, false, false, true, address(vault));
        emit AutonomousVault.CapitalDeployed(address(gold), amount);
        vm.prank(manager);
        vault.deployCapitalAndExecute(address(gold), amount, "");

        assertEq(gold.paxgHeld(), 10e18);
        assertEq(usdc.balanceOf(address(gold)), 0, "USDC fully swapped");
        assertEq(vault.totalDeployed(), amount);
        assertEq(gold.lastGoodPrice(), PRICE, "N-12: price set by deploy");
        assertEq(gold.currentValue(), amount);
        assertEq(usdc.allowance(address(gold), address(router)), 0);
    }

    function test_adapterIsCalledByTheVault() public {
        vm.prank(manager);
        vault.deployCapitalAndExecute(address(strat), 1_000e6, "");
        assertEq(strat.lastDeployCaller(), address(vault));
        assertEq(usdc.balanceOf(address(strat)), 1_000e6);
        assertEq(vault.totalDeployed(), 1_000e6);
    }

    function test_transferOnlyDeployCapital_cannotExecuteOnlyVaultAdapter() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.UseAtomicDeploy.selector, address(gold)));
        vault.deployCapital(address(gold), 10_000e6, "");
        assertEq(usdc.balanceOf(address(gold)), 0, "transfer-only gold funding rejected");
        assertEq(gold.paxgHeld(), 0);
        vm.prank(manager);
        vm.expectRevert(bytes("GoldExchangeAdapter: caller is not the vault"));
        gold.deploy(10_000e6);
    }

    function test_ownerCanAlsoCallAtomicEntryPoint() public {
        vm.prank(owner);
        vault.deployCapitalAndExecute(address(strat), 500e6, "");
        assertEq(vault.totalDeployed(), 500e6);
    }

    function test_atomicPath_accruesWakalaFeeLikeDeployCapital() public {
        vm.warp(block.timestamp + 10 days);
        vm.expectEmit(false, false, false, false, address(vault));
        emit ShariahVault.WakalaFeeAccrued(0);
        vm.prank(manager);
        vault.deployCapitalAndExecute(address(strat), 1_000e6, "");
        assertEq(vault.lastFeeAccrualTime(), block.timestamp);
    }

    // ───────────── identical checks to deployCapital ─────────────

    function test_sameChecks_nonManager() public {
        bytes memory r = _sameRevert(stranger, address(strat), 1e6);
        assertEq(bytes4(r), AutonomousVault.NotManager.selector);
    }

    function test_sameChecks_paused() public {
        vm.prank(owner);
        vault.setPaused(true);
        bytes memory r = _sameRevert(manager, address(strat), 1e6);
        assertEq(bytes4(r), AutonomousVault.Paused.selector);
    }

    function test_sameChecks_assetNotPermitted() public {
        vm.prank(owner);
        vault.setPermittedAsset(address(usdc), false);
        bytes memory r = _sameRevert(manager, address(strat), 1e6);
        assertEq(bytes4(r), ShariahVault.AssetNotPermitted.selector);
    }

    function test_sameChecks_unscreenedStrategy() public {
        address unscreened = makeAddr("unscreened");
        bytes memory r = _sameRevert(manager, unscreened, 1e6);
        assertEq(r, _unscreenedRevert(unscreened));
    }

    function test_sameChecks_allocationLimit() public {
        bytes memory r = _sameRevert(manager, address(strat), 800_000e6 + 1);
        assertEq(bytes4(r), AutonomousVault.AllocationExceedsLimit.selector);
    }

    function test_sameChecks_goldCap() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.GoldCapExceeded.selector, 300_000e6 + 1, 300_000e6));
        vault.deployCapitalAndExecute(address(gold), 300_000e6 + 1, "");
    }

    function test_goldCap_boundaryExactlyAtCapSucceeds() public {
        vm.prank(manager);
        vault.deployCapitalAndExecute(address(gold), 300_000e6, "");
        assertEq(vault.totalDeployed(), 300_000e6);
    }

    // ───────────── atomic rollback ─────────────

    function test_adapterRevert_rollsBackEverything_andClearsLock() public {
        vm.warp(block.timestamp + 1 days);
        uint256 vaultBal = usdc.balanceOf(address(vault));
        uint256 lastAccrual = vault.lastFeeAccrualTime();
        uint256 deployed = vault.totalDeployed();

        vm.prank(manager);
        vm.expectRevert(bytes("adapter: nope"));
        vault.deployCapitalAndExecute(address(bad), 5_000e6, "");

        assertEq(usdc.balanceOf(address(vault)), vaultBal, "funds not stranded in adapter");
        assertEq(usdc.balanceOf(address(bad)), 0);
        assertEq(vault.totalDeployed(), deployed);
        assertEq(vault.lastFeeAccrualTime(), lastAccrual);
        // N-06 must roll back per-adapter principal alongside funding and aggregate accounting.
        assertEq(vault.principalOf(address(bad)), 0);

        // The reentrancy lock is not left set: a later atomic deployment works.
        vm.prank(manager);
        vault.deployCapitalAndExecute(address(strat), 1_000e6, "");
        assertEq(vault.totalDeployed(), deployed + 1_000e6);
    }

    function test_realGoldAdapterRevert_zeroAmount_rollsBack_transferOnlyRejected() public {
        vm.prank(manager);
        vm.expectRevert(GoldExchangeAdapter.ZeroAmount.selector);
        vault.deployCapitalAndExecute(address(gold), 0, "");
        assertEq(vault.totalDeployed(), 0);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.UseAtomicDeploy.selector, address(gold)));
        vault.deployCapital(address(gold), 0, ""); // zero amount does not bypass the guard
        assertEq(vault.totalDeployed(), 0);
    }

    function test_transferOnlyAllocationAdapter_reverts() public {
        vm.prank(owner);
        vault.setGoldAllocationAdapter(address(strat));
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.UseAtomicDeploy.selector, address(strat)));
        vault.deployCapital(address(strat), 1e6, "");
        assertEq(vault.totalDeployed(), 0);
        assertEq(usdc.balanceOf(address(strat)), 0);
        vm.prank(manager);
        vault.deployCapitalAndExecute(address(strat), 1e6, "");
        assertEq(strat.lastDeployCaller(), address(vault));
    }

    function test_remoteRecipient_approvalDelayEventsAndRevocation() public {
        bytes32 recipient = _bytes32(alice);
        uint256 earliest = block.timestamp + 30 days;
        assertEq(vault.REMOTE_RECIPIENT_TIMELOCK(), 30 days);
        vm.prank(owner);
        vm.expectEmit(true, true, false, true, address(vault));
        emit ShariahVault.RemoteRecipientProposed(3, recipient, true, earliest);
        vault.proposeRemoteRecipient(3, recipient, true);
        (bool approved, uint256 executeAfter, bool exists) = vault.pendingRemoteRecipient(3, recipient);
        assertTrue(approved);
        assertTrue(exists);
        assertEq(executeAfter, earliest);
        assertFalse(vault.approvedRemoteRecipient(3, recipient));
        vm.prank(owner);
        vm.expectRevert(ShariahVault.RemoteRecipientProposalExists.selector);
        vault.proposeRemoteRecipient(3, recipient, false);
        vm.warp(earliest - 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.RemoteRecipientTimelockNotElapsed.selector, earliest, earliest - 1));
        vault.confirmRemoteRecipient(3, recipient);
        vm.warp(earliest);
        vm.prank(owner);
        vm.expectEmit(true, true, false, true, address(vault));
        emit ShariahVault.RemoteRecipientUpdated(3, recipient, true);
        vault.confirmRemoteRecipient(3, recipient);
        assertTrue(vault.approvedRemoteRecipient(3, recipient));
        (approved, executeAfter, exists) = vault.pendingRemoteRecipient(3, recipient);
        assertFalse(approved);
        assertEq(executeAfter, 0);
        assertFalse(exists);
        assertFalse(vault.approvedRemoteRecipient(7, recipient));
        vm.prank(owner);
        vault.proposeRemoteRecipient(3, recipient, false);
        assertTrue(vault.approvedRemoteRecipient(3, recipient));
        vm.warp(block.timestamp + 30 days);
        vm.prank(owner);
        vault.confirmRemoteRecipient(3, recipient);
        assertFalse(vault.approvedRemoteRecipient(3, recipient));
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.RemoteRecipientNotApproved.selector, uint32(3), recipient));
        vault.deployCrossChain(3, recipient, 1e6);
    }

    function test_remoteRecipient_cancelZeroAndMissing() public {
        bytes32 recipient = _bytes32(alice);
        vm.startPrank(owner);
        vm.expectRevert(ShariahVault.ZeroRecipient.selector);
        vault.proposeRemoteRecipient(3, bytes32(0), true);
        vm.expectRevert(ShariahVault.NoPendingRemoteRecipient.selector);
        vault.confirmRemoteRecipient(3, recipient);
        vm.expectRevert(ShariahVault.NoPendingRemoteRecipient.selector);
        vault.cancelRemoteRecipient(3, recipient);
        vault.proposeRemoteRecipient(3, recipient, true);
        vm.expectEmit(true, true, false, true, address(vault));
        emit ShariahVault.RemoteRecipientProposalCancelled(3, recipient);
        vault.cancelRemoteRecipient(3, recipient);
        (,, bool exists) = vault.pendingRemoteRecipient(3, recipient);
        assertFalse(exists);
        assertFalse(vault.approvedRemoteRecipient(3, recipient));
        vm.expectRevert(ShariahVault.NoPendingRemoteRecipient.selector);
        vault.confirmRemoteRecipient(3, recipient);
        vm.stopPrank();
    }

    function test_remoteRecipient_independentPairsAndCancelledRevocation() public {
        bytes32 a = _bytes32(alice);
        bytes32 b = _bytes32(stranger);
        vm.startPrank(owner);
        vault.proposeRemoteRecipient(0, a, true);
        vault.proposeRemoteRecipient(3, a, true);
        vault.proposeRemoteRecipient(0, b, true);
        vault.cancelRemoteRecipient(3, a);
        vm.warp(block.timestamp + 30 days);
        vault.confirmRemoteRecipient(0, a);
        vault.confirmRemoteRecipient(0, b);
        assertTrue(vault.approvedRemoteRecipient(0, a));
        assertTrue(vault.approvedRemoteRecipient(0, b));
        assertFalse(vault.approvedRemoteRecipient(3, a));
        vault.proposeRemoteRecipient(0, a, false);
        vault.cancelRemoteRecipient(0, a);
        assertTrue(vault.approvedRemoteRecipient(0, a));
        vault.proposeRemoteRecipient(0, a, false);
        (, uint256 earliest,) = vault.pendingRemoteRecipient(0, a);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.RemoteRecipientTimelockNotElapsed.selector, earliest, block.timestamp));
        vault.confirmRemoteRecipient(0, a);
        vm.stopPrank();
    }

    function test_transferOnlyNonGold_unchangedWithUnsetGoldSlots() public {
        vm.prank(owner);
        vault.setGoldSpreadAdapter(address(0));
        vm.prank(manager);
        vault.deployCapital(address(strat), 1e6, "");
        assertEq(usdc.balanceOf(address(strat)), 1e6);
        assertEq(vault.totalDeployed(), 1e6);
        assertEq(strat.lastDeployCaller(), address(0));
    }

    function test_remoteRecipient_onlyBoard() public {
        bytes32 recipient = _bytes32(alice);
        vm.startPrank(manager);
        bytes memory err = abi.encodeWithSelector(ShariahVault.NotBoardRole.selector, manager);
        vm.expectRevert(err);
        vault.proposeRemoteRecipient(3, recipient, true);
        vm.expectRevert(err);
        vault.confirmRemoteRecipient(3, recipient);
        vm.expectRevert(err);
        vault.cancelRemoteRecipient(3, recipient);
        vm.stopPrank();
    }

    function test_crossChain_bothPathsScreenAssetAndRecipient() public {
        bytes32 recipient = _bytes32(alice);
        MockTokenMessengerI messenger = new MockTokenMessengerI();
        vm.startPrank(owner);
        vault.setTokenMessenger(address(messenger));
        vault.setShariahScreening(false); // cannot disable remote screening
        vm.stopPrank();
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.RemoteRecipientNotApproved.selector, uint32(3), recipient));
        vault.deployCrossChain(3, recipient, 1e6);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.RemoteRecipientNotApproved.selector, uint32(3), recipient));
        vault.deployCrossChainForStrategy(0, 3, recipient, 1e6);
        assertEq(messenger.callCount(), 0);
        assertEq(vault.totalPendingCrossChain(), 0);
        assertEq(vault.crossChainPositionCounter(), 0);
        assertEq(vault.totalDeployed(), 0);
        assertEq(usdc.balanceOf(address(vault)), DEPOSIT);
        RemoteRecipientFixture.approve(vm, vault, owner, 3, recipient);
        vm.prank(owner);
        vault.setPermittedAsset(address(usdc), false);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.AssetNotPermitted.selector, address(usdc)));
        vault.deployCrossChain(3, recipient, 1e6);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.AssetNotPermitted.selector, address(usdc)));
        vault.deployCrossChainForStrategy(0, 3, recipient, 1e6);
        vm.prank(owner);
        vault.setPermittedAsset(address(usdc), true);
        vm.prank(manager);
        vault.deployCrossChain(3, recipient, 1e6);
        vm.prank(manager);
        vault.deployCrossChainForStrategy(0, 3, recipient, 2e6);
        assertEq(vault.totalPendingCrossChain(), 3e6);
        assertEq(messenger.callCount(), 2);
        vm.prank(manager);
        vm.expectRevert(ShariahVault.NonAtomicGoldExchange.selector);
        vault.deployCrossChainForStrategy(1, 3, recipient, 1e6);
        vm.prank(manager);
        vm.expectRevert(ShariahVault.NonAtomicGoldExchange.selector);
        vault.deployCrossChainForStrategy(5, 0, bytes32(0), 1e6);
    }

    // ───────────── RiskTieredExecutor integration ─────────────

    function _mkShariahExecutor(RiskTieredExecutor.RiskTier tier, uint8 idx, address adapter)
        internal
        returns (RiskTieredExecutor ex)
    {
        ShariahScoreAggregator shAgg = new ShariahScoreAggregator(owner);
        ScoreAggregator conv = new ScoreAggregator(owner);
        vm.startPrank(owner);
        ex = new RiskTieredExecutor(address(vault), address(conv), tier, owner);
        ex.setShariahAggregator(address(shAgg));
        vault.setManager(address(ex));
        ex.setShariahStrategyConfig(idx, adapter, _bytes32(alice), true, 1, 10_000e6);
        shAgg.setEnabled(ShariahScoreAggregator.ShariahStrategy(idx), true);
        shAgg.writeScore(ShariahScoreAggregator.ShariahStrategy(idx), 95, keccak256("m"), 0);
        vm.stopPrank();
    }

    function _shariahExecutorGold(RiskTieredExecutor.RiskTier tier) internal {
        RiskTieredExecutor ex = _mkShariahExecutor(tier, GOLD_SPREAD, address(gold));
        ex.executeWinner();
        assertGt(gold.paxgHeld(), 0, "real gold adapter executed end-to-end");
        assertEq(usdc.balanceOf(address(gold)), 0);
        assertEq(vault.totalDeployed(), 10_000e6);
        assertApproxEqAbs(gold.lastGoodPrice(), PRICE, 1);
        assertApproxEqAbs(gold.currentValue(), 10_000e6, 1);
        assertEq(vault.totalPendingCrossChain(), 0);
    }

    function test_executor_shariahConservative_goldSucceedsEndToEnd() public {
        _shariahExecutorGold(RiskTieredExecutor.RiskTier.SHARIAH_CONSERVATIVE);
    }

    function test_executor_shariahDynamic_goldSucceedsEndToEnd() public {
        _shariahExecutorGold(RiskTieredExecutor.RiskTier.SHARIAH_DYNAMIC);
    }

    function test_executor_shariah_nonGold_adapterCalledByVault() public {
        RiskTieredExecutor ex = _mkShariahExecutor(RiskTieredExecutor.RiskTier.SHARIAH_CONSERVATIVE, HALAL_LP, address(strat));
        ex.executeWinner();
        assertEq(strat.lastDeployCaller(), address(vault));
        assertEq(vault.totalDeployed(), 10_000e6);
    }

    function _mkPassive(address adapter) internal returns (RiskTieredExecutor ex) {
        ScoreAggregator conv = new ScoreAggregator(owner);
        vm.startPrank(owner);
        ex = new RiskTieredExecutor(address(vault), address(conv), RiskTieredExecutor.RiskTier.PASSIVE, owner);
        vault.setManager(address(ex));
        ex.setStrategyConfig(ScoreAggregator.Strategy.STABLECOIN_SPREAD, adapter, _bytes32(alice), true, 1, 10_000e6);
        conv.writeScore(ScoreAggregator.Strategy.STABLECOIN_SPREAD, 95, keccak256("c"), 0);
        vm.stopPrank();
    }

    function test_executor_nonShariahTier_unchanged_callerIsExecutor() public {
        RiskTieredExecutor ex = _mkPassive(address(strat));
        ex.executeWinner();
        assertEq(strat.lastDeployCaller(), address(ex), "conventional tiers still call adapter.deploy directly");
        assertEq(vault.totalDeployed(), 10_000e6);
        assertEq(usdc.balanceOf(address(strat)), 10_000e6);
    }

    function test_executor_nonShariahTier_unchanged_onlyVaultAdapterStillRejected() public {
        RiskTieredExecutor ex = _mkPassive(address(gold));
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.UseAtomicDeploy.selector, address(gold)));
        ex.executeWinner();
        assertEq(vault.totalDeployed(), 0);
        assertEq(gold.paxgHeld(), 0);
    }
}

/// @title N-02 against ShariahVault (V1).
contract TaskMN02V1Test is TaskMN02Base {
    function _makeVault() internal override returns (ShariahVault) {
        return new ShariahVault(IERC20(address(usdc)), owner, DOM, address(treasury), address(0));
    }

    function _screen(address adapter) internal override {
        vm.prank(owner);
        vault.setScreened(adapter, true);
    }

    function _unscreenedRevert(address) internal pure override returns (bytes memory) {
        return abi.encodeWithSelector(ShariahVault.AdapterNotScreened.selector);
    }
}

/// @title N-02 against ShariahVaultV2 (registry-based screening).
contract TaskMN02V2Test is TaskMN02Base {
    ShariahAdapterRegistry internal registry;
    bytes32 internal constant HASH = keccak256("SR-005");

    function _makeVault() internal override returns (ShariahVault) {
        registry = new ShariahAdapterRegistry(owner, owner);
        return new ShariahVaultV2(
            IERC20(address(usdc)), owner, DOM, address(treasury), address(0), address(registry)
        );
    }

    function _screen(address adapter) internal override {
        vm.prank(owner);
        registry.proposeScreening(adapter, HASH, block.timestamp + 365 days);
        vm.warp(block.timestamp + 30 days);
        vm.prank(owner);
        registry.executeScreening(adapter);
    }

    function _unscreenedRevert(address adapter) internal pure override returns (bytes memory) {
        return abi.encodeWithSelector(ShariahVaultV2.NotScreened.selector, adapter);
    }

    function test_v2_remoteRecipient_usesCurrentBoardNotOwner() public {
        bytes32 recipient = _bytes32(alice);
        vm.prank(owner);
        vault.proposeRemoteRecipient(3, recipient, true);
        vm.prank(owner);
        registry.proposeBoardRoleChange(stranger, true);
        vm.warp(block.timestamp + 30 days);
        vm.prank(owner);
        registry.executeBoardRoleChange(stranger);
        vm.prank(owner);
        registry.emergencyRevokeBoardRole(owner);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.NotBoardRole.selector, owner));
        vault.confirmRemoteRecipient(3, recipient);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.NotBoardRole.selector, owner));
        vault.cancelRemoteRecipient(3, recipient);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.NotBoardRole.selector, owner));
        vault.proposeRemoteRecipient(7, recipient, true);
        vm.prank(stranger);
        vault.confirmRemoteRecipient(3, recipient);
        assertTrue(vault.approvedRemoteRecipient(3, recipient));
    }

    function test_v2_expiredScreening_sameRevertOnBothPaths() public {
        ShariahAdapterRegistry.Screening memory s = registry.getScreening(address(strat));
        vm.warp(s.expiresAt);
        bytes memory r = _sameRevert(manager, address(strat), 1e6);
        assertEq(r, abi.encodeWithSelector(ShariahVaultV2.ScreeningExpired.selector, address(strat), s.expiresAt));
    }

    function test_v2_legacyScreeningFlagIrrelevant_registryDecides() public {
        vm.prank(owner);
        vault.setShariahScreening(false);
        address unscreened = makeAddr("unscreened");
        bytes memory r = _sameRevert(manager, unscreened, 1e6);
        assertEq(r, _unscreenedRevert(unscreened));
    }
}
