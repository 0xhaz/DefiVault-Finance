// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IStrategyAdapter
 * @notice Standard interface every protocol adapter must implement.
 *         The vault calls deploy() to send USDC in, recall() to pull it back.
 *         currentValue() returns mark-to-market NAV of the position.
 */
interface IStrategyAdapter {
    /// @notice Deploy `amount` of vault's USDC into the underlying protocol.
    ///         Caller must have already transferred `amount` to this adapter.
    ///         Returns the actual amount deployed (may differ due to fees).
    function deploy(uint256 amount) external returns (uint256 deployed);

    /// @notice Recall up to `amount` of USDC from the protocol back to `vault`.
    ///         Returns the actual amount returned (may differ due to slippage/fees).
    function recall(uint256 amount) external returns (uint256 returned);

    /// @notice Current total value (in USDC) of all assets held in the protocol.
    function currentValue() external view returns (uint256);

    /// @notice Human-readable protocol identifier, e.g. "Compound V3" or "Curve 3pool".
    function protocolName() external view returns (string memory);

    /// @notice Address of the vault that owns this adapter (receives recalled funds).
    function vault() external view returns (address);
}
