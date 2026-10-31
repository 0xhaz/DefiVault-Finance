// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {GoldExchangeAdapter} from "../adapters/GoldExchangeAdapter.sol";
import {MockXauUsdAggregator} from "../test-helpers/MockXauUsdAggregator.sol";
import {GoldExitExchangeFixture} from "./GoldEmergencyExitTest.Base.t.sol";

/// @dev GoldExchangeAdapter.setGoldOracle is locked while emergencyExitEnabled is true.
contract GoldOracleLockTest is GoldExitExchangeFixture {
    event GoldOracleUpdated(address indexed previous, address indexed updated);

    GoldExchangeAdapter internal a;
    MockXauUsdAggregator internal oracle2;

    function setUp() public override {
        super.setUp();
        a = GoldExchangeAdapter(address(adapter));
        oracle2 = new MockXauUsdAggregator();
    }

    function _disable() internal {
        vm.prank(owner);
        a.proposeParamChange(PARAM, 0);
        vm.warp(block.timestamp + 30 days);
        vm.prank(owner);
        a.executeParamChange(PARAM);
    }

    // ── setGoldOracle gating ─────────────────────────────────────────────
    function test_SetGoldOracleWorksWhileDisabled() public {
        assertFalse(a.emergencyExitEnabled());
        vm.expectEmit(true, true, false, false, address(a));
        emit GoldOracleUpdated(address(oracle), address(oracle2));
        vm.prank(owner);
        a.setGoldOracle(address(oracle2));
        assertEq(address(a.goldOracle()), address(oracle2));
    }

    function test_ParamIdMatchesConstant() public view {
        assertEq(a.PARAM_EMERGENCY_EXIT_ENABLED(), keccak256("emergencyExitEnabled"));
    }

    function test_SetGoldOracleRevertsAfterEnabledViaTimelock() public {
        _enable();
        assertTrue(a.emergencyExitEnabled());
        vm.expectRevert(GoldExchangeAdapter.OracleLockedWhileEmergencyEnabled.selector);
        vm.prank(owner);
        a.setGoldOracle(address(oracle2));
        assertEq(address(a.goldOracle()), address(oracle), "oracle unchanged");
    }

    function test_ProposingEnableAloneDoesNotLockOracle() public {
        vm.prank(owner);
        a.proposeParamChange(PARAM, 1);
        vm.prank(owner);
        a.setGoldOracle(address(oracle2));
        assertEq(address(a.goldOracle()), address(oracle2));
        // Timelock not yet elapsed -> still cannot execute.
        vm.warp(block.timestamp + 30 days - 1);
        vm.expectRevert("GoldExchangeAdapter: timelock not elapsed");
        vm.prank(owner);
        a.executeParamChange(PARAM);
        vm.prank(owner);
        a.setGoldOracle(address(oracle));
    }

    function test_StillLockedUntilDisableTimelockElapses() public {
        _enable();
        vm.prank(owner);
        a.proposeParamChange(PARAM, 0);
        vm.warp(block.timestamp + 30 days - 1);
        vm.expectRevert("GoldExchangeAdapter: timelock not elapsed");
        vm.prank(owner);
        a.executeParamChange(PARAM);
        vm.expectRevert(GoldExchangeAdapter.OracleLockedWhileEmergencyEnabled.selector);
        vm.prank(owner);
        a.setGoldOracle(address(oracle2));
    }

    function test_SetGoldOracleWorksAgainAfterDisable() public {
        _enable();
        _disable();
        assertFalse(a.emergencyExitEnabled());
        vm.prank(owner);
        a.setGoldOracle(address(oracle2));
        assertEq(address(a.goldOracle()), address(oracle2));
    }

    function test_ZeroOracleRevertsOracleRequired() public {
        vm.expectRevert(GoldExchangeAdapter.OracleRequired.selector);
        vm.prank(owner);
        a.setGoldOracle(address(0));
    }

    function test_ZeroOracleRevertsOracleRequiredAfterReDisable() public {
        _enable();
        _disable();
        vm.expectRevert(GoldExchangeAdapter.OracleRequired.selector);
        vm.prank(owner);
        a.setGoldOracle(address(0));
    }

    function test_LockTakesPrecedenceOverZeroCheckWhenEnabled() public {
        _enable();
        vm.expectRevert(GoldExchangeAdapter.OracleLockedWhileEmergencyEnabled.selector);
        vm.prank(owner);
        a.setGoldOracle(address(0));
    }

    function test_NonOwnerCannotSetOracle() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        a.setGoldOracle(address(oracle2));
        _enable();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        a.setGoldOracle(address(oracle2));
    }

    function test_NonOwnerCannotTouchEnableFlag() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        a.proposeParamChange(PARAM, 1);
    }

    // ── pokePrice while locked ───────────────────────────────────────────
    function test_PokePriceSetsCacheToFreshOracleWhileLocked() public {
        _open(DEPLOY);
        _enable();
        _setOracle(300_000_000_000); // $3,000 fresh
        a.pokePrice();
        assertEq(a.lastGoodPrice(), 3_000e6, "cache == fresh reading, never below");
    }

    function test_PokePriceCannotLowerCacheBelowFreshReading() public {
        _open(DEPLOY);
        _enable();
        _setOracle(350_000_000_000);
        a.pokePrice();
        uint256 cached = a.lastGoodPrice();
        assertEq(cached, 3_500e6);
        // Oracle swap (the only way to feed a lower fake reading) is blocked.
        MockXauUsdAggregator low = new MockXauUsdAggregator();
        low.setPrice(1_000_000_000);
        vm.expectRevert(GoldExchangeAdapter.OracleLockedWhileEmergencyEnabled.selector);
        vm.prank(owner);
        a.setGoldOracle(address(low));
        a.pokePrice();
        assertEq(a.lastGoodPrice(), cached, "poke still tracks the original oracle");
    }

    function test_PokePriceWithStaleOracleDoesNotLowerCache() public {
        _open(DEPLOY);
        _enable();
        uint256 before_ = a.lastGoodPrice();
        assertGt(before_, 0);
        oracle.setUpdatedAt(block.timestamp - 2 days); // stale
        a.pokePrice();
        assertEq(a.lastGoodPrice(), before_);
    }

    function test_PokePriceWithInvalidOracleDoesNotLowerCache() public {
        _open(DEPLOY);
        _enable();
        uint256 before_ = a.lastGoodPrice();
        oracle.setPrice(-1);
        a.pokePrice();
        assertEq(a.lastGoodPrice(), before_, "negative answer ignored");
        oracle.setPrice(0);
        a.pokePrice();
        assertEq(a.lastGoodPrice(), before_, "zero answer ignored");
    }

    function testFuzz_PokePriceEqualsOracleWhenFresh(int256 answer) public {
        answer = int256(bound(uint256(answer), 1e8, 1e13));
        _open(DEPLOY);
        _enable();
        _setOracle(answer);
        a.pokePrice();
        assertEq(a.lastGoodPrice(), uint256(answer) / 100);
    }

    // ── emergency floor uses cached price; swap blocked ──────────────────
    function test_EmergencyFloorUsesCachedPrice() public {
        _open(DEPLOY);
        _enable();
        uint256 amt = a.paxgHeld();
        uint256 floor = _floor(amt);
        assertGt(floor, 1);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, floor - 1, floor));
        vm.prank(owner);
        a.proposeEmergencyExit(amt, floor - 1);
        vm.prank(owner);
        a.proposeEmergencyExit(amt, floor);
        (, uint256 minOut,,) = a.pendingEmergencyExit();
        assertEq(minOut, floor);
    }

    function test_OwnerOracleSwapCannotLowerEmergencyFloor() public {
        _open(DEPLOY);
        _enable();
        uint256 amt = a.paxgHeld();
        uint256 floorBefore = _floor(amt);
        // Attempt: swap to a feed reporting a very low price, then poke to drag the cache down.
        MockXauUsdAggregator low = new MockXauUsdAggregator();
        low.setPrice(1_00000000); // $1
        vm.expectRevert(GoldExchangeAdapter.OracleLockedWhileEmergencyEnabled.selector);
        vm.prank(owner);
        a.setGoldOracle(address(low));
        a.pokePrice();
        assertEq(_floor(amt), floorBefore, "floor unchanged");
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, uint256(1), floorBefore));
        vm.prank(owner);
        a.proposeEmergencyExit(amt, 1);
    }

    function test_FloorUsesCachedNotLiveOraclePrice() public {
        _open(DEPLOY);
        _enable();
        uint256 amt = a.paxgHeld();
        uint256 cached = a.lastGoodPrice();
        // Live oracle halves but nobody pokes: floor is derived from the cache, not the live feed.
        _setOracle(ORACLE_PRICE / 2);
        uint256 expected = Math.mulDiv(Math.mulDiv(amt, cached, 1e18), 2000, 10_000, Math.Rounding.Ceil);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, expected - 1, expected));
        vm.prank(owner);
        a.proposeEmergencyExit(amt, expected - 1);
    }

    function test_FloorAfterDisableAndOracleSwapStillRequiresNewProposalFlow() public {
        _open(DEPLOY);
        _enable();
        _disable();
        // swap allowed again, but exits are disabled until re-enabled through the timelock.
        vm.prank(owner);
        a.setGoldOracle(address(oracle2));
        uint256 held = a.paxgHeld(); // read before expectRevert so the view call does not consume it
        vm.expectRevert(EmergencyExitDisabled.selector);
        vm.prank(owner);
        a.proposeEmergencyExit(held, 1e6);
    }
}
