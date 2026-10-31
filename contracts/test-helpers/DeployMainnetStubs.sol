// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Local-only stubs for exercising DeployMainnet.s.sol on a local anvil / forge test.
///      Runtime bytecode is installed with anvil_setCode / vm.etch, so NO state depends on a constructor:
///      every value is a compile-time constant. Not for any real network.

/// @dev ERC-20 with constant decimals (6): stand-in for native USDC at 0x3600...
contract StubToken6 is ERC20("Stub6", "S6") {
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

/// @dev ERC-20 with constant decimals (18): stand-in for PAXG.
contract StubToken18 is ERC20("Stub18", "S18") {
    function decimals() public pure override returns (uint8) { return 18; }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

/// @dev CCTP MessageTransmitterV2 stub reporting localDomain() == 26 (Arc).
contract StubTransmitter26 {
    function localDomain() external pure returns (uint32) { return 26; }
}

/// @dev Same, but a WRONG domain (negative test).
contract StubTransmitter7 {
    function localDomain() external pure returns (uint32) { return 7; }
}

/// @dev TokenMessengerV2 / swap router stub: only needs to have code for the deploy script.
contract StubCodeOnly {
    function ping() external pure returns (bool) { return true; }
}

/// @dev Chainlink-style XAU/USD feed stub: constructors only call decimals().
contract StubOracle8 {
    function decimals() external pure returns (uint8) { return 8; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2_000e8, block.timestamp, block.timestamp, 1);
    }
}
