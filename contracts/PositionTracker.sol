// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {ScoreAggregator} from "./ScoreAggregator.sol";

contract PositionTracker is Ownable2Step {
    enum PositionStatus {
        OPEN,
        CLOSING,
        CLOSED
    }

    struct Position {
        uint256 id;
        ScoreAggregator.Strategy strategy;
        address target;
        uint256 amountDeployed;
        uint256 entryTimestamp;
        uint256 exitTimestamp;
        uint256 pnl;
        int256 pnlNet;
        PositionStatus status;
        bytes32 txHash;
        uint32 destinationDomain;
    }

    error NotReporter();
    error PositionNotFound();
    error PositionAlreadyClosed();

    event ReporterUpdated(address indexed previousReporter, address indexed newReporter);
    event PositionOpened(
        uint256 indexed id,
        ScoreAggregator.Strategy indexed strategy,
        address indexed target,
        uint256 amount,
        uint32 destinationDomain
    );
    event PositionClosed(uint256 indexed id, uint256 returnAmount, int256 pnlNet);
    event PositionStatusUpdated(uint256 indexed id, PositionStatus status);

    address public reporter;
    uint256 public positionCount;

    mapping(uint256 => Position) public positions;
    uint256[] public activePositionIds;

    constructor(address initialOwner) Ownable(initialOwner) {}

    modifier onlyReporterOrOwner() {
        if (msg.sender != owner() && msg.sender != reporter) revert NotReporter();
        _;
    }

    function openPosition(
        ScoreAggregator.Strategy strategy,
        address target,
        uint256 amount,
        bytes32 txHash,
        uint32 destinationDomain
    ) external onlyReporterOrOwner returns (uint256 id) {
        id = ++positionCount;

        positions[id] = Position({
            id: id,
            strategy: strategy,
            target: target,
            amountDeployed: amount,
            entryTimestamp: block.timestamp,
            exitTimestamp: 0,
            pnl: 0,
            pnlNet: 0,
            status: PositionStatus.OPEN,
            txHash: txHash,
            destinationDomain: destinationDomain
        });

        activePositionIds.push(id);

        emit PositionOpened(id, strategy, target, amount, destinationDomain);
    }

    function closePosition(uint256 id, uint256 returnAmount, bytes32 closeTxHash) external onlyReporterOrOwner {
        if (id == 0 || id > positionCount) revert PositionNotFound();

        Position storage position = positions[id];
        if (position.status == PositionStatus.CLOSED) revert PositionAlreadyClosed();

        position.status = PositionStatus.CLOSED;
        position.exitTimestamp = block.timestamp;
        position.txHash = closeTxHash;

        if (returnAmount >= position.amountDeployed) {
            position.pnl = returnAmount - position.amountDeployed;
            position.pnlNet = int256(returnAmount - position.amountDeployed);
        } else {
            position.pnl = position.amountDeployed - returnAmount;
            position.pnlNet = -int256(position.amountDeployed - returnAmount);
        }

        _removeActivePosition(id);

        emit PositionClosed(id, returnAmount, position.pnlNet);
    }

    function updateStatus(uint256 id, PositionStatus status) external onlyReporterOrOwner {
        if (id == 0 || id > positionCount) revert PositionNotFound();

        Position storage position = positions[id];
        if (position.status == PositionStatus.CLOSED) revert PositionAlreadyClosed();

        position.status = status;
        emit PositionStatusUpdated(id, status);
    }

    function getActivePositions() external view returns (Position[] memory activePositions) {
        uint256 length = activePositionIds.length;
        activePositions = new Position[](length);

        for (uint256 i = 0; i < length; i++) {
            activePositions[i] = positions[activePositionIds[i]];
        }
    }

    function getTotalPnl() external view returns (int256 totalPnl) {
        for (uint256 id = 1; id <= positionCount; id++) {
            Position storage position = positions[id];
            if (position.status == PositionStatus.CLOSED) {
                totalPnl += position.pnlNet;
            }
        }
    }

    function setReporter(address newReporter) external onlyOwner {
        address previousReporter = reporter;
        reporter = newReporter;
        emit ReporterUpdated(previousReporter, newReporter);
    }

    function _removeActivePosition(uint256 id) internal {
        uint256 length = activePositionIds.length;
        for (uint256 i = 0; i < length; i++) {
            if (activePositionIds[i] == id) {
                if (i != length - 1) {
                    activePositionIds[i] = activePositionIds[length - 1];
                }
                activePositionIds.pop();
                return;
            }
        }
    }
}
