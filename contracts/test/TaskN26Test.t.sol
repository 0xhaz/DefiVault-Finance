// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ShariahVault} from "../ShariahVault.sol";
import {ShariahVaultV2} from "../ShariahVaultV2.sol";
import {TaskN26Edge as TaskN26Core} from "./TaskN26Test.Edge.t.sol";

/// @dev N-26: hurdle allowance carries across partial claims. Concrete V1/V2 runs.
contract TaskN26V1Test is TaskN26Core {
    function _newVault() internal override returns (ShariahVault) {
        return new ShariahVault(IERC20(address(usdc)), owner, DOM, address(treasury), address(0));
    }
}

contract TaskN26V2Test is TaskN26Core {
    function _newVault() internal override returns (ShariahVault) {
        return new ShariahVaultV2(
            IERC20(address(usdc)), owner, DOM, address(treasury), address(0), address(registry)
        );
    }
}
