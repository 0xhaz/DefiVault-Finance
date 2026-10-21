// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal Chainlink AggregatorV3Interface — only what GoldAllocationAdapter needs.
/// @dev    Full interface: https://github.com/smartcontractkit/chainlink/blob/develop/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    /// @return roundId       The round ID.
    /// @return answer        The price answer (positive; negative means invalid).
    /// @return startedAt     Timestamp when the round started.
    /// @return updatedAt     Timestamp of the last update — used for staleness check.
    /// @return answeredInRound Round ID of when the answer was computed.
    function latestRoundData()
        external
        view
        returns (
            uint80  roundId,
            int256  answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80  answeredInRound
        );
}
