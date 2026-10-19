// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract ShariahScoreAggregator is Ownable2Step {
    enum ShariahStrategy {
        ETH_SPREAD,
        GOLD_SPREAD,
        HALAL_LP,
        MURABAHA,
        RWA_SUKUK
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

    event OracleUpdated(address indexed previousOracle, address indexed newOracle);
    event ScoreUpdated(
        ShariahStrategy indexed strategy,
        uint8 value,
        uint40 timestamp,
        bytes32 dataHash,
        uint32 destinationDomain
    );
    event StrategyCertified(ShariahStrategy indexed strategy, bool certified);

    address public oracle;

    mapping(ShariahStrategy => Score) public scores;
    mapping(ShariahStrategy => Score[]) public scoreHistory;
    mapping(ShariahStrategy => uint8) public historyIndex;
    mapping(ShariahStrategy => bool) public shariahCertified;

    constructor(address initialOwner) Ownable(initialOwner) {}

    modifier onlyOracleOrOwner() {
        if (msg.sender != owner() && msg.sender != oracle) revert NotOracle();
        _;
    }

    function writeScore(ShariahStrategy strategy, uint8 value, bytes32 dataHash, uint32 destinationDomain)
        external
        onlyOracleOrOwner
    {
        _writeScore(strategy, value, dataHash, destinationDomain);
    }

    function writeBatchScores(
        ShariahStrategy[] calldata strategies,
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

    function getWinningShariahStrategy()
        external
        view
        returns (ShariahStrategy strategy, uint8 score, uint32 destinationDomain)
    {
        ShariahStrategy bestStrategy;
        uint8 bestScore;
        uint32 bestDestinationDomain;
        bool foundValid;

        for (uint8 i = 0; i < 5; i++) {
            ShariahStrategy currentStrategy = ShariahStrategy(i);
            if (!shariahCertified[currentStrategy]) {
                continue;
            }

            Score memory current = scores[currentStrategy];
            if (current.value == 0) {
                continue;
            }

            if (block.timestamp > uint256(current.timestamp) + 5 minutes) {
                continue;
            }

            if (!foundValid || current.value > bestScore) {
                bestScore = current.value;
                bestStrategy = currentStrategy;
                bestDestinationDomain = current.destinationDomain;
                foundValid = true;
            }
        }

        if (!foundValid) revert NoValidScores();

        return (bestStrategy, bestScore, bestDestinationDomain);
    }

    function getAllShariahScores()
        external
        view
        returns (
            uint8[5] memory values,
            uint40[5] memory timestamps,
            uint32[5] memory destinationDomains,
            bool[5] memory certified
        )
    {
        for (uint8 i = 0; i < 5; i++) {
            ShariahStrategy strategy = ShariahStrategy(i);
            Score memory current = scores[strategy];
            values[i] = current.value;
            timestamps[i] = current.timestamp;
            destinationDomains[i] = current.destinationDomain;
            certified[i] = shariahCertified[strategy];
        }
    }

    function getScoreHistory(ShariahStrategy strategy) external view returns (Score[10] memory history) {
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

    function setCertified(ShariahStrategy strategy, bool certified) external onlyOwner {
        shariahCertified[strategy] = certified;
        emit StrategyCertified(strategy, certified);
    }

    function setOracle(address newOracle) external onlyOwner {
        address previousOracle = oracle;
        oracle = newOracle;
        emit OracleUpdated(previousOracle, newOracle);
    }

    function _writeScore(ShariahStrategy strategy, uint8 value, bytes32 dataHash, uint32 destinationDomain) internal {
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
