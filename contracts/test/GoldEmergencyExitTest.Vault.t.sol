// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ShariahVault} from "../ShariahVault.sol";
import {ShariahVaultV2} from "../ShariahVaultV2.sol";
import {ShariahAdapterRegistry} from "../ShariahAdapterRegistry.sol";
import {TreasuryModule} from "../TreasuryModule.sol";
import {GoldExchangeAdapter} from "../adapters/GoldExchangeAdapter.sol";
import {GoldAllocationAdapter} from "../adapters/GoldAllocationAdapter.sol";
import {GoldExitBase, GoldExitExchangeFixture, GoldExitAllocFixture, IGoldX} from "./GoldEmergencyExitTest.Base.t.sol";

/// @dev Adapter-side emergency exits observed through a real ShariahVaultV2 holding the gold position.
abstract contract GoldExitVaultSuite is GoldExitBase {
    error NotManager();

    uint256 internal constant DEPOSIT = 1_000_000e6;
    int256 internal constant HIGH_ORACLE = 495_000_000_000; // $4,950 (+50%)
    uint256 internal constant HIGH_PRICE = 4_950e6;

    ShariahVaultV2 internal v;
    ShariahAdapterRegistry internal registry;
    TreasuryModule internal treasury;
    address internal alice = makeAddr("alice");

    function _link() internal virtual;
    /// @dev A gold adapter of the OTHER kind, deployed against the same vault but never linked.
    function _otherAdapter() internal virtual returns (address);

    function _setActors() internal virtual override {
        owner = makeAddr("owner");
        registry = new ShariahAdapterRegistry(owner, owner);
        treasury = new TreasuryModule("Shariah", address(0), address(usdc), 0, 0, 0, owner);
        v = new ShariahVaultV2(IERC20(address(usdc)), owner, 26, address(treasury), address(0), address(registry));
        vault = address(v);
        vm.prank(owner);
        v.setManager(manager);
    }

    function _postSetUp() internal virtual override {
        vm.startPrank(owner);
        registry.proposeScreening(address(adapter), keccak256("SR-005"), block.timestamp + 365 days);
        vm.warp(block.timestamp + 30 days);
        registry.executeScreening(address(adapter));
        _link();
        vm.stopPrank();
        _freshOracle();

        usdc.mint(alice, DEPOSIT);
        vm.startPrank(alice);
        usdc.approve(address(v), DEPOSIT);
        v.deposit(DEPOSIT, alice);
        vm.stopPrank();

        vm.prank(manager);
        v.deployCapitalAndExecute(address(adapter), DEPLOY, "");
    }

    /// @dev Entry rounds the bought token down to its own decimals: one token unit of USDC value, plus slack.
    function _granularity() internal view returns (uint256) {
        return PRICE / 10 ** goldDec + 20;
    }

    function _appreciate() internal {
        _setOracle(HIGH_ORACLE);
        router.setPrice(HIGH_PRICE);
    }

    function test_vaultAndManager_cannotCallAdapterExitFunctions() public {
        _enable();
        address[2] memory who = [vault, manager];
        for (uint256 i; i < 2; ++i) {
            bytes memory unauth = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who[i]);
            vm.prank(who[i]);
            vm.expectRevert(unauth);
            adapter.emergencyExit(1, 1);
            vm.prank(who[i]);
            vm.expectRevert(unauth);
            adapter.proposeEmergencyExit(1, 1);
            vm.prank(who[i]);
            vm.expectRevert(unauth);
            adapter.executeEmergencyExit();
            vm.prank(who[i]);
            vm.expectRevert(unauth);
            adapter.cancelEmergencyExit();
        }
    }

    function test_setup_positionHeld() public view {
        assertEq(v.principalOf(address(adapter)), DEPLOY);
        assertEq(v.totalDeployed(), DEPLOY);
        assertEq(adapter.totalDeployed(), DEPLOY);
        assertGt(_held(), 0);
    }

    // ── flat price: principal retires proportionally, NAV is neutral ────
    function test_partialExit_flatPrice_retiresPrincipalProportionally_navNeutral() public {
        _enable();
        uint256 nav0 = v.totalAssets();
        uint256 bal0 = usdc.balanceOf(vault);
        uint256 shareValue0 = v.convertToAssets(1e6);
        uint256 h0 = _held();
        uint256 sold = h0 / 3;
        uint256 retired = Math.mulDiv(DEPLOY, sold, h0);

        _propose(sold, _floor(sold));
        _wait();
        vm.expectEmit(true, false, false, true, address(v));
        emit ShariahVault.PrincipalRetired(address(adapter), retired, 0);
        uint256 out = _execute();

        assertEq(usdc.balanceOf(vault) - bal0, out, "proceeds in vault");
        assertEq(v.principalOf(address(adapter)), DEPLOY - retired, "vault principal retired by token fraction");
        assertEq(v.totalDeployed(), DEPLOY - retired, "vault totalDeployed reduced by retired principal");
        assertLt(adapter.totalDeployed(), DEPLOY, "adapter principal reduced");
        assertApproxEqAbs(v.principalOf(address(adapter)), adapter.totalDeployed(), 1, "vault and adapter agree");
        assertApproxEqAbs(v.totalAssets(), nav0, 10, "NAV neutral within rounding");
        assertApproxEqAbs(v.convertToAssets(1e6), shareValue0, 1, "share price unchanged");
        assertEq(v.goldUnrealizedGain(), 0, "no phantom gain at flat price");
    }

    function testFuzz_partialExit_isNavNeutral(uint256 f) public {
        _enable();
        uint256 minSell = 10 ** (goldDec / 2);
        uint256 nav0 = v.totalAssets();
        uint256 h0 = _held();
        uint256 sold = bound(f, minSell, h0 - minSell);
        _exit(sold);
        assertApproxEqAbs(v.totalAssets(), nav0, 10);
        assertEq(v.principalOf(address(adapter)), DEPLOY - Math.mulDiv(DEPLOY, sold, h0));
        assertEq(v.totalDeployed(), v.principalOf(address(adapter)));
    }

    function test_fullExit_clearsPrincipalAndDeployed() public {
        _enable();
        uint256 h0 = _held();
        _propose(h0, _floor(h0));
        _wait();
        vm.expectEmit(true, false, false, true, address(v));
        emit ShariahVault.PrincipalRetired(address(adapter), DEPLOY, 0);
        _execute();
        assertEq(v.principalOf(address(adapter)), 0, "full principal retired on full sale");
        assertEq(v.totalDeployed(), 0);
        assertEq(adapter.totalDeployed(), 0);
        assertEq(adapter.currentValue(), 0);
        assertEq(v.totalAssets(), usdc.balanceOf(vault), "NAV == idle cash");
        assertApproxEqAbs(v.totalAssets(), DEPOSIT, _granularity());
    }

    function test_afterPartial_ordinaryRecall_reconcilesEverything() public {
        _enable();
        _exit(_held() / 3);
        uint256 principal = v.principalOf(address(adapter));
        vm.prank(manager);
        v.recallCapital(address(adapter), principal);

        assertEq(v.principalOf(address(adapter)), 0, "principal retired");
        assertEq(v.totalDeployed(), 0, "vault deployed retired");
        assertEq(adapter.totalDeployed(), 0);
        assertEq(_held(), 0);
        assertApproxEqAbs(usdc.balanceOf(vault), DEPOSIT, _granularity());
        assertEq(v.totalAssets(), usdc.balanceOf(vault), "NAV == idle cash");
    }

    function test_partialExit_thenWriteOff_revertsWhileExposed() public {
        _enable();
        _exit(_held() / 3);
        uint256 value = adapter.currentValue();
        assertGt(value, 0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.GoldAdapterHasExposure.selector, address(adapter), value));
        v.writeOffAdapterPrincipal(address(adapter));
    }

    function test_outageCrash_recallBlocked_exitAboveHardFloor_realizesLoss() public {
        _enable();
        _outage();
        router.setPrice(1_000e6);

        vm.prank(manager);
        vm.expectPartialRevert(SlippageExceeded.selector);
        v.recallCapital(address(adapter), DEPLOY);
        assertEq(v.principalOf(address(adapter)), DEPLOY, "failed recall changes nothing");

        uint256 h0 = _held();
        uint256 out = _exitMin(h0 / 2, _out(h0 / 2, 900e6));
        out += _exit(_held());
        assertEq(_held(), 0);
        assertEq(adapter.totalDeployed(), 0);
        assertEq(v.principalOf(address(adapter)), 0, "principal retired by the sales themselves");
        assertEq(v.totalDeployed(), 0);

        assertEq(v.totalAssets(), usdc.balanceOf(vault));
        assertApproxEqAbs(usdc.balanceOf(vault), DEPOSIT - DEPLOY + out, 1);
        assertLt(v.totalAssets(), DEPOSIT - 60_000e6, "crash loss realized");
    }

    function test_outageCrashBelowTwentyPercent_rejected_vaultUntouched() public {
        _enable();
        _outage();
        router.setPrice(500e6);
        uint256 sold = _held() / 2;
        uint256 floor = _floor(sold);
        _propose(sold, floor);
        _wait();
        vm.prank(owner);
        vm.expectPartialRevert(SlippageExceeded.selector);
        adapter.executeEmergencyExit();
        assertEq(v.principalOf(address(adapter)), DEPLOY);
        assertEq(v.totalDeployed(), DEPLOY);
        assertEq(usdc.balanceOf(vault), DEPOSIT - DEPLOY);
    }

    // ── appreciation: cost 100k, worth 150k, sell 10% ───────────────────
    function test_appreciation_partialSale_retiresProportionalCost_unsoldGainNotRealized() public {
        _enable();
        _appreciate();
        uint256 valueBefore = adapter.currentValue();
        assertApproxEqAbs(valueBefore, 150_000e6, 5 * _granularity(), "worth ~150k");
        assertApproxEqAbs(v.goldUnrealizedGain(), 50_000e6, 5 * _granularity(), "paper gain ~50k");
        assertEq(v.realizedProfit(), 0, "paper gain is not realized profit");

        uint256 h0 = _held();
        uint256 sold = h0 / 10;
        uint256 retired = Math.mulDiv(DEPLOY, sold, h0);
        assertApproxEqAbs(retired, 10_000e6, 2, "10% of cost");
        uint256 out = _exitMin(sold, _out(sold, HIGH_PRICE) * 9 / 10);
        assertApproxEqAbs(out, 15_000e6, 3 * _granularity(), "10% sold for ~15k");

        // principal: cost basis retires by token fraction, NOT by proceeds
        assertEq(v.principalOf(address(adapter)), DEPLOY - retired, "principalOf ~90k");
        assertApproxEqAbs(v.principalOf(address(adapter)), 90_000e6, 2);
        assertEq(v.totalDeployed(), DEPLOY - retired, "totalDeployed reduced by ~10k");

        // remaining 90% is worth ~135k against 90k cost
        uint256 value = adapter.currentValue();
        assertApproxEqAbs(value, 135_000e6, 5 * _granularity());
        uint256 gain = v.goldUnrealizedGain();
        assertEq(gain, value - (DEPLOY - retired), "gain = remaining value - remaining cost");
        assertApproxEqAbs(gain, 45_000e6, 5 * _granularity(), "unsold appreciation ~45k");

        // realized profit is only the sold slice: proceeds - retired cost (~5k), never the unsold gain
        uint256 realized = v.realizedProfit();
        assertApproxEqAbs(realized, out - retired, 5, "realized == proceeds - retired cost");
        assertApproxEqAbs(realized, 5_000e6, 5 * _granularity());
        assertLt(realized, gain / 5, "unsold appreciation excluded");
    }

    function test_appreciation_laterDistribution_cannotExceedRealized() public {
        _enable();
        _appreciate();
        uint256 h0 = _held();
        _exitMin(h0 / 10, _out(h0 / 10, HIGH_PRICE) * 9 / 10);
        uint256 realized = v.realizedProfit();
        uint256 gain = v.goldUnrealizedGain();
        assertGt(realized, 0);
        assertGt(gain, realized);

        vm.startPrank(manager);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.ProfitExceedsRealized.selector, realized + 1, realized));
        v.lockProfit(realized + 1);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.ProfitExceedsRealized.selector, realized + gain, realized));
        v.lockProfit(realized + gain);
        vm.stopPrank();
    }

    function test_appreciation_unsoldGainRealizesOnlyWhenRecalled() public {
        _enable();
        _appreciate();
        uint256 h0 = _held();
        _exitMin(h0 / 10, _out(h0 / 10, HIGH_PRICE) * 9 / 10);
        uint256 principal = v.principalOf(address(adapter));
        _freshOracle();
        vm.prank(manager);
        v.recallCapital(address(adapter), principal);
        assertEq(v.principalOf(address(adapter)), 0);
        assertEq(v.totalDeployed(), 0);
        assertEq(v.goldUnrealizedGain(), 0);
        assertApproxEqAbs(v.realizedProfit(), 50_000e6, 8 * _granularity(), "whole gain realized after recall");
    }

    function test_appreciation_fullSale_clearsPrincipal_realizesWholeGain() public {
        _enable();
        _appreciate();
        uint256 h0 = _held();
        _propose(h0, _floor(h0));
        _wait();
        vm.expectEmit(true, false, false, true, address(v));
        emit ShariahVault.PrincipalRetired(address(adapter), DEPLOY, 0);
        _execute();
        assertEq(v.principalOf(address(adapter)), 0, "full sale clears principal");
        assertEq(v.totalDeployed(), 0);
        assertEq(v.goldUnrealizedGain(), 0);
        assertApproxEqAbs(v.realizedProfit(), 50_000e6, 5 * _granularity());
    }

    function test_depreciation_partialSale_stillRetiresByFraction() public {
        _enable();
        _setOracle(ORACLE_PRICE / 2);
        router.setPrice(PRICE / 2);
        uint256 h0 = _held();
        uint256 sold = h0 / 4;
        uint256 retired = Math.mulDiv(DEPLOY, sold, h0);
        uint256 out = _exitMin(sold, _out(sold, PRICE / 2));
        assertApproxEqAbs(out, 12_500e6, 3 * _granularity());
        assertEq(v.principalOf(address(adapter)), DEPLOY - retired, "cost retired by fraction, not proceeds");
        assertEq(v.totalDeployed(), DEPLOY - retired);
        assertEq(v.goldUnrealizedGain(), 0);
        assertGt(v.goldWritedown(), 0, "remaining position carries the loss");
    }

    // ── retireGoldPrincipal hook: caller restriction ────────────────────
    function _expectNotManager() internal {
        vm.expectRevert(NotManager.selector);
    }

    function test_hook_unauthorizedCallers_revert_noStateChange() public {
        address other = _otherAdapter();
        address unlinked = makeAddr("unlinkedAdapter");
        address[5] memory who = [stranger, owner, manager, other, unlinked];
        for (uint256 i; i < 5; ++i) {
            vm.prank(who[i]);
            _expectNotManager();
            v.retireGoldPrincipal(1, 2);
        }
        assertEq(v.principalOf(address(adapter)), DEPLOY);
        assertEq(v.principalOf(other), 0);
        assertEq(v.totalDeployed(), DEPLOY);
    }

    function test_hook_vaultItself_cannotCall() public {
        vm.prank(address(v));
        _expectNotManager();
        v.retireGoldPrincipal(1, 2);
    }

    function test_hook_linkedAdapter_canCall_retiresItsOwnFraction() public {
        vm.prank(address(adapter));
        v.retireGoldPrincipal(1, 4);
        assertEq(v.principalOf(address(adapter)), DEPLOY - DEPLOY / 4);
        assertEq(v.totalDeployed(), DEPLOY - DEPLOY / 4);
    }

    function test_hook_invalidFractions_revert() public {
        vm.startPrank(address(adapter));
        vm.expectRevert(ShariahVault.InvalidGoldSaleFraction.selector);
        v.retireGoldPrincipal(0, 4);
        vm.expectRevert(ShariahVault.InvalidGoldSaleFraction.selector);
        v.retireGoldPrincipal(5, 4);
        vm.stopPrank();
        assertEq(v.principalOf(address(adapter)), DEPLOY);
    }

    function test_hook_fullFraction_retiresAllPrincipal() public {
        vm.prank(address(adapter));
        v.retireGoldPrincipal(7, 7);
        assertEq(v.principalOf(address(adapter)), 0);
        assertEq(v.totalDeployed(), 0);
    }

    // ── hook failure reverts the adapter exit atomically ────────────────
    function test_hookFailure_revertsAdapterExit_noStateChange() public {
        _enable();
        uint256 sold = _held() / 2;
        _propose(sold, _floor(sold));
        _wait();
        uint256 h = _held();
        uint256 d = adapter.totalDeployed();
        uint256 bal = usdc.balanceOf(vault);
        uint256 routerCalls = router.calls();
        uint256 routerGold = gold.balanceOf(address(router));
        uint256 nav = v.totalAssets();

        vm.mockCallRevert(vault, abi.encodeWithSelector(ShariahVault.retireGoldPrincipal.selector), "hook down");
        vm.prank(owner);
        vm.expectRevert();
        adapter.executeEmergencyExit();
        vm.clearMockedCalls();

        assertEq(_held(), h, "held unchanged");
        assertEq(adapter.totalDeployed(), d, "adapter principal unchanged");
        assertEq(v.principalOf(address(adapter)), DEPLOY);
        assertEq(v.totalDeployed(), DEPLOY);
        assertEq(usdc.balanceOf(vault), bal, "no proceeds delivered");
        assertEq(router.calls(), routerCalls, "swap rolled back");
        assertEq(gold.balanceOf(address(router)), routerGold);
        assertEq(gold.allowance(address(adapter), address(router)), 0);
        assertEq(v.totalAssets(), nav);
        (uint256 t,,,) = adapter.pendingEmergencyExit();
        assertEq(t, sold, "proposal not consumed");

        // with the hook healthy the same proposal executes
        vm.prank(owner);
        adapter.executeEmergencyExit();
        assertEq(_held(), h - sold);
    }

    function test_withdrawals_workWithProceeds() public {
        _enable();
        uint256 maxBefore = v.maxWithdraw(alice);
        _exit(_held());
        uint256 maxAfter = v.maxWithdraw(alice);
        assertGt(maxAfter, maxBefore, "proceeds expand withdrawable liquidity");
        assertApproxEqAbs(maxAfter, DEPOSIT, _granularity());

        uint256 shares = v.balanceOf(alice);
        vm.prank(alice);
        uint256 assets = v.redeem(shares, alice, alice);
        assertApproxEqAbs(assets, DEPOSIT, _granularity());
        assertEq(usdc.balanceOf(alice), assets);
        assertEq(v.balanceOf(alice), 0);
    }
}

contract GoldExchangeEmergencyExitVaultTest is GoldExitExchangeFixture, GoldExitVaultSuite {
    function _setActors() internal override(GoldExitBase, GoldExitVaultSuite) { GoldExitVaultSuite._setActors(); }
    function _postSetUp() internal override(GoldExitBase, GoldExitVaultSuite) { GoldExitVaultSuite._postSetUp(); }
    function _link() internal override { v.setGoldSpreadAdapter(address(adapter)); }
    function _otherAdapter() internal override returns (address) {
        return address(new GoldAllocationAdapter(
            address(usdc), address(gold), address(router), 3000, address(oracle), vault, 3600, owner
        ));
    }
}

contract GoldAllocationEmergencyExitVaultTest is GoldExitAllocFixture, GoldExitVaultSuite {
    function _setActors() internal override(GoldExitBase, GoldExitVaultSuite) { GoldExitVaultSuite._setActors(); }
    function _postSetUp() internal override(GoldExitBase, GoldExitVaultSuite) { GoldExitVaultSuite._postSetUp(); }
    function _link() internal override { v.setGoldAllocationAdapter(address(adapter)); }
    function _otherAdapter() internal override returns (address) {
        return address(new GoldExchangeAdapter(
            address(usdc), address(gold), address(router), 3000, vault, owner, address(oracle)
        ));
    }
}
