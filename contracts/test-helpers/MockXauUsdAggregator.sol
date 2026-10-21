// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";

/// @notice Testnet-only settable XAU/USD price feed. Implements AggregatorV3Interface.
/// @dev    Allows tests to set arbitrary prices and staleness conditions.
///         Default price: $3,300 per troy oz = 3_300_000_000_00 (8 dec).
///         Default updatedAt: block.timestamp at construction.
contract MockXauUsdAggregator is AggregatorV3Interface {
    int256  public price;
    uint256 public updatedAt;
    uint256 public startedAt;
    uint8   private _decimals;
    uint80  public roundId;

    constructor() {
        _decimals = 8;
        price     = 3_300_000_000_00; // $3,300.00 × 10^8
        updatedAt = block.timestamp;
        startedAt = block.timestamp;
        roundId   = 1;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function setPrice(int256 newPrice) external {
        price     = newPrice;
        updatedAt = block.timestamp;
        roundId++;
    }

    /// @notice Explicitly set updatedAt for staleness tests.
    function setUpdatedAt(uint256 ts) external {
        updatedAt = ts;
    }

    function setStartedAt(uint256 ts) external {
        startedAt = ts;
    }

    function setDecimals(uint8 dec) external {
        _decimals = dec;
    }

    function latestRoundData()
        external
        view
        override
        returns (
            uint80  roundId_,
            int256  answer,
            uint256 startedAt_,
            uint256 updatedAt_,
            uint80  answeredInRound
        )
    {
        return (roundId, price, startedAt, updatedAt, roundId);
    }
}
