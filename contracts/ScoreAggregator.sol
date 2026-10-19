// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract ScoreAggregator is Ownable2Step {
    enum Strategy {
        STABLECOIN_SPREAD,
        FUNDING_RATE_ARB,
        BRIDGE_FLOW,
        LIQUIDATION_RWA
    }

    struct Score {
        uint8 value;
        uint40 timestamp;
        bytes32 dataHash;
        uint32 destinationDomain;
    }

    error NotOracle();
    error InvalidScore();
    error NoValidScores();
    error StaleScore(Strategy strategy);

    event OracleUpdated(address indexed previousOracle, address indexed newOracle);
    event ScoreUpdated(Strategy indexed strategy, uint8 value, uint40 timestamp, bytes32 dataHash, uint32 destinationDomain);

    address public oracle;

    mapping(Strategy => Score) public scores;
    mapping(Strategy => Score[]) public scoreHistory;
    mapping(Strategy => uint8) public historyIndex;

    constructor(address initialOwner) Ownable(initialOwner) {}

    modifier onlyOracleOrOwner() {
        if (msg.sender != owner() && msg.sender != oracle) revert NotOracle();
        _;
    }

    function writeScore(
        Strategy strategy,
        uint8 value,
        bytes32 dataHash,
        uint32 destinationDomain
    ) external onlyOracleOrOwner {
        _writeScore(strategy, value, dataHash, destinationDomain);
    }

    function writeBatchScores(
        Strategy[] calldata strategies,
        uint8[] calldata values,
        bytes32[] calldata dataHashes,
        uint32[] calldata destinationDomains
    ) external onlyOracleOrOwner {
        uint256 length = strategies.length;
        if (length != values.length || length != dataHashes.length || length != destinationDomains.length) {
            revert InvalidScore();
        }

        for (uint256 i = 0; i < length; i++) {
            _writeScore(strategies[i], values[i], dataHashes[i], destinationDomains[i]);
        }
    }

    function getWinningStrategy() external view returns (Strategy strategy, uint8 score, uint32 destinationDomain) {
        Strategy bestStrategy;
        uint8 bestScore;
        uint32 bestDestinationDomain;
        bool foundValid;
        bool foundStale;
        Strategy firstStale;

        for (uint8 i = 0; i < 4; i++) {
            Strategy currentStrategy = Strategy(i);
            Score memory current = scores[currentStrategy];

            if (current.value == 0) {
                continue;
            }

            if (block.timestamp > uint256(current.timestamp) + 5 minutes) {
                if (!foundStale) {
                    foundStale = true;
                    firstStale = currentStrategy;
                }
                continue;
            }

            if (!foundValid || current.value > bestScore) {
                bestScore = current.value;
                bestStrategy = currentStrategy;
                bestDestinationDomain = current.destinationDomain;
                foundValid = true;
            }
        }

        if (!foundValid) {
            if (foundStale) revert StaleScore(firstStale);
            revert NoValidScores();
        }

        return (bestStrategy, bestScore, bestDestinationDomain);
    }

    function getAllScores()
        external
        view
        returns (uint8[4] memory values, uint40[4] memory timestamps, uint32[4] memory destinationDomains)
    {
        for (uint8 i = 0; i < 4; i++) {
            Score memory current = scores[Strategy(i)];
            values[i] = current.value;
            timestamps[i] = current.timestamp;
            destinationDomains[i] = current.destinationDomain;
        }
    }

    function getScoreHistory(Strategy strategy) external view returns (Score[10] memory history) {
        Score[] storage stored = scoreHistory[strategy];
        uint256 length = stored.length;

        if (length == 0) {
            return history;
        }

        if (length < 10) {
            for (uint256 i = 0; i < length; i++) {
                history[i] = stored[i];
            }
            return history;
        }

        uint256 start = historyIndex[strategy];
        for (uint256 i = 0; i < 10; i++) {
            history[i] = stored[(start + i) % 10];
        }
    }

    function setOracle(address newOracle) external onlyOwner {
        address previousOracle = oracle;
        oracle = newOracle;
        emit OracleUpdated(previousOracle, newOracle);
    }

    function _writeScore(Strategy strategy, uint8 value, bytes32 dataHash, uint32 destinationDomain) internal {
        if (value > 100) revert InvalidScore();

        Score memory nextScore = Score({
            value: value,
            timestamp: uint40(block.timestamp),
            dataHash: dataHash,
            destinationDomain: destinationDomain
        });
        scores[strategy] = nextScore;

        Score[] storage history = scoreHistory[strategy];
        uint8 index = historyIndex[strategy];

        if (history.length < 10) {
            history.push(nextScore);
            historyIndex[strategy] = uint8(history.length % 10);
        } else {
            history[index] = nextScore;
            historyIndex[strategy] = uint8((index + 1) % 10);
        }

        emit ScoreUpdated(strategy, value, nextScore.timestamp, dataHash, destinationDomain);
    }
}
