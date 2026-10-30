// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface VmDeal {
    function deal(address who, uint256 newBalance) external;
}

/// @notice Fork-test stand-in for Arc's NATIVE-COIN PRECOMPILES, which Foundry's EVM does not implement.
/// @dev The Arc USDC proxy (0x3600...) is an ERC-20 *view* over the chain's native coin (18 decimals,
///      balanceOf = nativeBalance / 1e12). Its mint/burn/transfer/totalSupply/blocklist calls are forwarded
///      to precompiles at 0x1800...0000 (authority) and 0x1800...0001 (blocklist). On a Foundry fork those
///      addresses hold the placeholder code 0x01 and every USDC state change reverts with StackUnderflow.
///      This shim is etched ONLY at those two precompile addresses so the REAL USDC / TokenMinterV2 /
///      TokenMessengerV2 / MessageTransmitterV2 bytecode runs unchanged. It does not stand in for any
///      Circle contract. Native-coin accounting is done with vm.deal on real native balances.
contract ArcNativeCoinShim {
    VmDeal internal constant VM = VmDeal(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    uint256 public supply; // native units (18 decimals)

    function setSupply(uint256 s) external {
        supply = s;
    }

    function totalSupply() external view returns (uint256) {
        return supply;
    }

    function mint(address to, uint256 amount) external returns (bool) {
        VM.deal(to, to.balance + amount);
        supply += amount;
        return true;
    }

    function burn(address from, uint256 amount) external returns (bool) {
        require(from.balance >= amount, "shim: burn exceeds balance");
        VM.deal(from, from.balance - amount);
        supply -= amount;
        return true;
    }

    function transfer(address from, address to, uint256 amount) external returns (bool) {
        require(from.balance >= amount, "shim: transfer exceeds balance");
        if (from == to) return true;
        VM.deal(from, from.balance - amount);
        VM.deal(to, to.balance + amount);
        return true;
    }
}

/// @notice Blocklist precompile stand-in (0x1800...0001): nobody is blocklisted.
contract ArcBlocklistShim {
    function isBlocklisted(address) external pure returns (bool) {
        return false;
    }
}
