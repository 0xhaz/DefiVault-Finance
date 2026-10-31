// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {HalalLPAdapter} from "../adapters/HalalLPAdapter.sol";

/// @dev P-5 (Slither missing-zero-check): every address the adapter depends on is validated at construction.
contract HalalLPAdapterP5Test is Test {
    address internal pm = makeAddr("positionManager");
    address internal router = makeAddr("router");
    address internal usdc = makeAddr("usdc");
    address internal pair = makeAddr("pair");
    address internal vault = makeAddr("vault");
    address internal owner = makeAddr("owner");

    function _new(address pm_, address router_, address t0, address t1, address usdc_, address vault_)
        internal
        returns (HalalLPAdapter)
    {
        return new HalalLPAdapter(pm_, router_, t0, t1, 500, usdc_, vault_, owner);
    }

    function test_P5_validConstruction() public {
        HalalLPAdapter a = _new(pm, router, usdc, pair, usdc, vault);
        assertEq(a.positionManager(), pm);
        assertEq(a.vault(), vault);
    }

    function test_P5_zeroPositionManagerReverts() public {
        vm.expectRevert(HalalLPAdapter.ZeroAddress.selector);
        _new(address(0), router, usdc, pair, usdc, vault);
    }

    function test_P5_zeroRouterReverts() public {
        vm.expectRevert(HalalLPAdapter.ZeroAddress.selector);
        _new(pm, address(0), usdc, pair, usdc, vault);
    }

    function test_P5_zeroVaultReverts() public {
        vm.expectRevert(HalalLPAdapter.ZeroAddress.selector);
        _new(pm, router, usdc, pair, usdc, address(0));
    }

    /// Before P-5 this passed the pair check (usdc == token0 == address(0)).
    function test_P5_zeroTokenWithZeroUsdcReverts() public {
        vm.expectRevert(HalalLPAdapter.ZeroAddress.selector);
        _new(pm, router, address(0), pair, address(0), vault);
        vm.expectRevert(HalalLPAdapter.ZeroAddress.selector);
        _new(pm, router, pair, address(0), address(0), vault);
    }

    function test_P5_pairChecksStillApply() public {
        vm.expectRevert(HalalLPAdapter.InvalidPair.selector);
        _new(pm, router, usdc, usdc, usdc, vault);
        vm.expectRevert(HalalLPAdapter.InvalidPair.selector);
        _new(pm, router, pair, makeAddr("other"), usdc, vault);
    }
}
