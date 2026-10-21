// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Testnet-only ERC-20 stub for PAXG (PAX Gold).
/// @dev    NOT a real gold-backed token. For use in forge tests and Arc Testnet only.
///         Production deployments must use the real PAXG contract.
contract MockAllocatedGold is ERC20 {
    constructor() ERC20("Mock Allocated Gold", "MAG") {}

    /// @notice Faucet — mint any amount to any address. Test-only.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice 18 decimals — matching real PAXG.
    function decimals() public pure override returns (uint8) {
        return 18;
    }
}
