// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Testnet-only ERC-20 stub for XAUT (Tether Gold).
/// @dev    NOT a real gold-backed token. Arc Testnet only — XAUT is not deployed on Arc.
///         Mainnet XAUT: 0x68749665FF8D2d112Fa859AA293F07A622782F38 (Ethereum, 6 decimals).
///         6 decimals matches the mainnet XAUT contract. The GoldAllocationAdapter reads
///         decimals() at construction time, so swapping this mock for real XAUT on any
///         chain only requires a redeploy with a different address.
contract MockXAUT is ERC20 {
    constructor() ERC20("Mock Tether Gold", "MockXAUT") {}

    /// @notice 6 decimals — matching mainnet XAUT (Tether Gold).
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Public faucet — mint any amount to any address. Test-only.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
