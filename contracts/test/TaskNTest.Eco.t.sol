// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ShariahVault}           from "../ShariahVault.sol";
import {ShariahVaultV2}         from "../ShariahVaultV2.sol";
import {ShariahAdapterRegistry} from "../ShariahAdapterRegistry.sol";
import {TaskNDustBase}          from "./TaskNTest.DustBase.t.sol";

/// @dev Economic behaviour: a stale gold position larger than dustThreshold pauses deposits;
///      only a board-confirmed (30-day timelocked, NAV-capped) raise can resume them.
abstract contract TaskNEconomic is TaskNDustBase {
    uint256 internal constant NAV = 1_000_000e6; // cap = 5_000e6

    function _seedNavAndGold(uint256 goldUsdc) internal {
        usdc.mint(alice, NAV);
        vm.startPrank(alice);
        usdc.approve(address(v), type(uint256).max);
        v.deposit(NAV, alice);
        vm.stopPrank();
        _openGold(goldUsdc);
    }

    function _makeOracleStale() internal {
        vm.warp(block.timestamp + 2 days); // adapter heartbeat window is 1 day
        assertFalse(goldAdapter.isPriceSane(), "oracle stale");
    }

    function _aliceCanDeposit(uint256 amt) internal returns (bool ok) {
        usdc.mint(alice, amt);
        vm.prank(alice);
        try v.deposit(amt, alice) { ok = true; } catch { ok = false; }
    }

    function test_eco_staleGoldAboveDust_pauses_andResumesOnlyAfterConfirmedRaise() public {
        _seedNavAndGold(3_000e6);
        assertGt(v.maxDeposit(alice), 0, "fresh oracle: open");
        assertTrue(_aliceCanDeposit(10e6));

        _makeOracleStale();
        // Pause materiality uses funded cost, not the haircutted market value.
        uint256 X = v.principalOf(address(goldAdapter));
        assertGt(X, v.dustThreshold(), "position above default dust");
        assertLe(X, _cap(v.totalAssets()), "X is within the NAV cap");
        assertEq(v.maxDeposit(alice), 0, "deposits paused");
        assertEq(v.maxMint(alice), 0, "mints paused");
        assertFalse(_aliceCanDeposit(10e6));

        // proposing alone changes nothing
        uint256 t0 = block.timestamp;
        _propose(X);
        assertEq(v.maxDeposit(alice), 0, "still paused after propose");

        // 1s before the timelock: confirm fails, still paused
        vm.warp(t0 + DUST_TIMELOCK - 1);
        vm.prank(_board());
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.DustTimelockNotElapsed.selector, t0 + DUST_TIMELOCK, t0 + DUST_TIMELOCK - 1));
        v.confirmDustThreshold();
        assertEq(v.maxDeposit(alice), 0);
        assertFalse(goldAdapter.isPriceSane());

        // at the timelock: confirm, deposits resume (X > X is false)
        vm.warp(t0 + DUST_TIMELOCK);
        assertEq(v.principalOf(address(goldAdapter)), X, "funded cost is time-independent");
        _confirm();
        assertEq(v.dustThreshold(), X);
        assertGt(v.maxDeposit(alice), 0, "deposits resume");
        assertGt(v.maxMint(alice), 0);
        assertTrue(_aliceCanDeposit(10e6));
    }

    function test_eco_thresholdOneBelowPosition_staysPaused() public {
        _seedNavAndGold(3_000e6);
        _makeOracleStale();
        // Pause materiality uses funded cost, not the haircutted market value.
        uint256 X = v.principalOf(address(goldAdapter));
        _propose(X - 1);
        vm.warp(block.timestamp + DUST_TIMELOCK);
        _confirm();
        assertEq(v.dustThreshold(), X - 1);
        assertEq(v.maxDeposit(alice), 0, "X > X-1 still pauses");
    }

    function test_eco_smallStalePosition_doesNotPause() public {
        _seedNavAndGold(1e6); // stale value ~0.95e6 <= default dust 1e6
        _makeOracleStale();
        // Equality at the funded-cost boundary stays open even after the stale haircut.
        assertLe(v.principalOf(address(goldAdapter)), v.dustThreshold());
        assertGt(v.maxDeposit(alice), 0);
        assertTrue(_aliceCanDeposit(10e6));
    }

    function test_eco_positionAboveCap_cannotBeSilenced_untilNavGrows() public {
        _seedNavAndGold(10_000e6);
        _makeOracleStale();
        // Pause materiality uses funded cost, not the haircutted market value.
        uint256 X = v.principalOf(address(goldAdapter));
        uint256 cap = _cap(v.totalAssets());
        assertGt(X, cap, "position larger than cap");
        assertEq(v.maxDeposit(alice), 0);

        // Cannot propose above the cap.
        vm.prank(_board());
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.DustThresholdAboveCap.selector, X, cap));
        v.proposeDustThreshold(X);

        // Max allowed raise still leaves deposits paused.
        _propose(cap);
        vm.warp(block.timestamp + DUST_TIMELOCK);
        _confirm();
        assertEq(v.dustThreshold(), cap);
        assertEq(v.maxDeposit(alice), 0, "X > cap: still paused");

        // NAV doubles (e.g. via donation) => cap doubles to cover X.
        usdc.mint(address(v), NAV * 2);
        uint256 cap2 = _cap(v.totalAssets());
        assertGe(cap2, X);
        _propose(X);
        vm.warp(block.timestamp + DUST_TIMELOCK);
        _confirm();
        assertGt(v.maxDeposit(alice), 0, "resumed after cap allowed the raise");
    }

    function test_eco_navShrinkBetweenProposeAndConfirm_blocksResume() public {
        _seedNavAndGold(3_000e6);
        _makeOracleStale();
        // Pause materiality uses funded cost, not the haircutted market value.
        uint256 X = v.principalOf(address(goldAdapter));
        _propose(X);
        vm.warp(block.timestamp + DUST_TIMELOCK);

        // Withdraw most NAV: cap collapses below X.
        uint256 sh = v.balanceOf(alice);
        vm.prank(alice);
        v.redeem(sh * 9 / 10, alice, alice);
        uint256 cap = _cap(v.totalAssets());
        assertLt(cap, X);

        vm.prank(_board());
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.DustThresholdAboveCap.selector, X, cap));
        v.confirmDustThreshold();
        assertEq(v.maxDeposit(alice), 0, "still paused");
        (, , bool exists) = _pending();
        assertTrue(exists, "proposal retained");
    }
}

contract TaskNEconomicV1Test is TaskNEconomic {
    function _deployVault() internal override {
        v = new ShariahVault(IERC20(address(usdc)), owner, SOURCE_DOMAIN, address(treasury), address(0));
    }
    function _board() internal view override returns (address) { return owner; }
    function _denied() internal view override returns (address[] memory d) { d = new address[](0); }
}

contract TaskNEconomicV2Test is TaskNEconomic {
    function _deployVault() internal override {
        ShariahAdapterRegistry reg = new ShariahAdapterRegistry(owner, boardMember);
        v = new ShariahVaultV2(
            IERC20(address(usdc)), owner, SOURCE_DOMAIN, address(treasury), address(0), address(reg)
        );
    }
    function _board() internal view override returns (address) { return boardMember; }
    function _denied() internal view override returns (address[] memory d) { d = new address[](0); }
}
