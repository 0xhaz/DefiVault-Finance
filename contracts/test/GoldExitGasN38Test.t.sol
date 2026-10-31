// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2, StdStorage, stdStorage} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TaskN29V1Mixin, TaskN29V2Mixin} from "./TaskN29Test.Base.t.sol";
import {TaskR5Base, GasAdapterR5} from "./TaskReviewR5Test.Base.t.sol";

/// @dev N-38 (P-2 F3): the exit gas floor now budgets each linked gold slot (EXIT_SETTLE_GAS_PER_GOLD), so an exit
///      at the minimum non-reverting gas (what eth_estimateGas picks) still settles the leaver's cut.
abstract contract GoldExitGasN38Tests is TaskR5Base {
    using stdStorage for StdStorage;

    function _goldSlot(uint256 burn, bool both) internal {
        GasAdapterR5 g1 = new GasAdapterR5(IERC20(address(usdc)), burn);
        GasAdapterR5 g2 = new GasAdapterR5(IERC20(address(usdc)), burn);
        vm.startPrank(owner);
        vault.setGoldSpreadAdapter(address(g1));
        if (both) vault.setGoldAllocationAdapter(address(g2));
        vm.stopPrank();
        _fundGold(address(g1));
        if (both) _fundGold(address(g2));
    }

    function _fundGold(address g) internal {
        vm.prank(address(vault));
        usdc.transfer(g, 100e6);
        stdstore.target(address(vault)).sig("principalOf(address)").with_key(g).checked_write(uint256(100e6));
        uint256 d = vault.totalDeployed();
        stdstore.target(address(vault)).sig("totalDeployed()").checked_write(d + 100e6);
        vm.cool(g);
    }

    function _go(uint256 burn, bool both) internal {
        _goldSlot(burn, both);
        _yield(200e6);
        (uint256 minG, bool settled) = _minOk(false, true);
        console2.log("gold burn", burn, both ? 2 : 1);
        console2.log("  minGas / settled", minG, settled ? 1 : 0);
        assertTrue(settled, "cut settled at minimum non-reverting gas");
        assertLt(minG, 30_000_000, "fits the block");
    }

    function test_N38_oneGold_25k() public { _go(25_000, false); }
    function test_N38_twoGold_25k() public { _go(25_000, true); }
    function test_N38_oneGold_10k() public { _go(10_000, false); }
    function test_N38_oneGold_5k() public { _go(5_000, false); }
    function test_N38_oneGold_15k() public { _go(15_000, false); }
    function test_N38_twoGold_60k() public { _go(60_000, true); }
}


contract GoldExitGasN38V1Test is GoldExitGasN38Tests, TaskN29V1Mixin {}

contract GoldExitGasN38V2Test is GoldExitGasN38Tests, TaskN29V2Mixin {}
