// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AutonomousVault} from "../AutonomousVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Test-only access to profit streaming, which has no external entry point on the base vault.
contract AutonomousVaultHarness is AutonomousVault {
    constructor(IERC20 asset_, address initialOwner, uint32 sourceDomain_)
        AutonomousVault(asset_, initialOwner, sourceDomain_)
    {}

    function lockProfit(uint256 amount) external onlyManagerOrOwner {
        _lockProfitInternal(amount);
    }
}
