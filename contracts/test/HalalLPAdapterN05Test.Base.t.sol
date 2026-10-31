// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {MockSwapRouter} from "../test-helpers/MockSwapRouter.sol";
import {MockPositionManager} from "../test-helpers/MockPositionManager.sol";
import {HalalLPAdapter} from "../adapters/HalalLPAdapter.sol";

/// @dev Shared fixture for the N-05 (two-sided deploy / swap-back recall / TWAP mark) suite.
/// Concrete test contracts choose which side USDC sits on and the pair token's decimals.
/// No test functions live here (every category file inherits it).
abstract contract N05Base is Test {
    address internal owner = makeAddr("owner");
    address internal vault = makeAddr("vault");
    address internal attacker = makeAddr("attacker");

    MockERC20 internal usdc;
    MockERC20 internal pair;
    MockERC20 internal t0;
    MockERC20 internal t1;
    MockSwapRouter internal router;
    MockPositionManager internal pm;
    HalalLPAdapter internal adapter;

    bool internal usdc0;
    uint8 internal pairDec;
    /// @dev tick at which 1 pair token == 1 USDC after decimal adjustment (raw token1/token0 price).
    int24 internal baseTick;

    function _usdcIsToken0() internal view virtual returns (bool);
    function _pairDecimals() internal view virtual returns (uint8);

    function setUp() public virtual {
        usdc0 = _usdcIsToken0();
        pairDec = _pairDecimals();
        usdc = new MockERC20("USDC", "USDC", 6);
        pair = new MockERC20("PAIR", "PAIR", pairDec);
        (t0, t1) = usdc0 ? (usdc, pair) : (pair, usdc);
        // 6 -> 18 decimals: 1 USDC (1e6 raw) == 1 pair (1e18 raw) => raw ratio 1e12 (~tick 276324).
        baseTick = pairDec == 6 ? int24(0) : (usdc0 ? int24(276324) : int24(-276324));
        pm = new MockPositionManager(address(t0), address(t1));
        router = new MockSwapRouter(address(t0), address(t1));
        adapter = new HalalLPAdapter(
            address(pm), address(router), address(t0), address(t1), 3000, address(usdc), vault, owner
        );
        usdc.mint(address(router), 1e30);
        pair.mint(address(router), 1e36);
        _setPrice(baseTick);
    }

    // ── price helpers ────────────────────────────────────────────────────────
    function _setPrice(int24 t) internal {
        pm.setTicks(t, t);
        router.setPrice(pm.sqrtPriceX96());
    }

    function _sqrtAt(int24 t) internal returns (uint160 p) {
        int24 s = pm.spotTick();
        int24 w = pm.twapTick();
        pm.setTicks(t, t);
        p = pm.sqrtPriceX96();
        pm.setTicks(s, w);
    }

    /// @dev Raw-unit conversion of a pair amount into USDC at sqrt price `p`.
    function _pairToUsdc(uint256 pairAmt, uint160 p) internal view returns (uint256) {
        uint256 ratio = uint256(p) * p;
        return usdc0 ? Math.mulDiv(pairAmt, 1 << 192, ratio) : Math.mulDiv(pairAmt, ratio, 1 << 192);
    }

    function _usdcToPair(uint256 usdcAmt, uint160 p) internal view returns (uint256) {
        uint256 ratio = uint256(p) * p;
        return usdc0 ? Math.mulDiv(usdcAmt, ratio, 1 << 192) : Math.mulDiv(usdcAmt, 1 << 192, ratio);
    }

    // ── action helpers ───────────────────────────────────────────────────────
    function _deploy(uint256 a) internal {
        usdc.mint(address(adapter), a);
        vm.prank(vault);
        adapter.deploy(a);
    }

    function _recall(uint256 a) internal returns (uint256 r) {
        vm.prank(vault);
        r = adapter.recall(a);
    }

    function _setRange(int24 lo, int24 hi) internal {
        vm.prank(owner);
        adapter.setTickRange(lo, hi);
    }

    function _legs() internal view returns (uint256 usdcLeg, uint256 pairLeg) {
        usdcLeg = usdc0 ? pm.lastMintAmount0Desired() : pm.lastMintAmount1Desired();
        pairLeg = usdc0 ? pm.lastMintAmount1Desired() : pm.lastMintAmount0Desired();
    }

    /// @dev Back fees with real tokens: `usdcFee` USDC and `pairFee` pair tokens become tokensOwed.
    function _accrue(uint256 usdcFee, uint256 pairFee) internal {
        usdc.mint(address(this), usdcFee);
        pair.mint(address(this), pairFee);
        usdc.approve(address(pm), usdcFee);
        pair.approve(address(pm), pairFee);
        pm.accrueFees(uint128(usdc0 ? usdcFee : pairFee), uint128(usdc0 ? pairFee : usdcFee));
    }

    function _assertNoApprovals() internal view {
        assertEq(usdc.allowance(address(adapter), address(router)), 0, "usdc->router allowance");
        assertEq(pair.allowance(address(adapter), address(router)), 0, "pair->router allowance");
        assertEq(usdc.allowance(address(adapter), address(pm)), 0, "usdc->pm allowance");
        assertEq(pair.allowance(address(adapter), address(pm)), 0, "pair->pm allowance");
    }
}
