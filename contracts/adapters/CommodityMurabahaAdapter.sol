// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IStrategyAdapter} from "../IStrategyAdapter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract CommodityMurabahaAdapter is IStrategyAdapter, Ownable2Step {
    using SafeERC20 for IERC20;

    enum TradeStatus {
        PENDING,
        EXECUTED,
        SETTLED,
        EXPIRED
    }

    struct MurabahaTrade {
        uint256 id;
        address buyer;
        uint256 costAmount;
        uint256 markupBps;
        uint256 salePrice;
        uint256 requestTime;
        uint256 executeTime;
        uint256 settleTime;
        uint256 deadline;
        TradeStatus status;
    }

    error OnlyVault();
    error OnlyVaultOrOwner();
    error TradeNotFound();
    error InvalidTradeStatus(TradeStatus current, TradeStatus expected);
    error BuyerOnly();
    error DeadlinePassed();
    error InvalidMarkup();
    error InvalidAmount();

    event Deployed(uint256 amount);
    event Recalled(uint256 amount);

    event MurabahaRequested(
        uint256 indexed id,
        address indexed buyer,
        uint256 costAmount,
        uint256 markupBps,
        uint256 salePrice,
        uint256 deadline
    );
    event MurabahaExecuted(uint256 indexed id, uint256 executeTime);
    event MurabahaSettled(uint256 indexed id, uint256 profit, uint256 settleTime);
    event MurabahaExpired(uint256 indexed id);

    address public immutable usdc;
    address public immutable override vault;

    uint256 public tradeCount;
    mapping(uint256 => MurabahaTrade) public trades;
    uint256[] public activeTrades;
    /// @dev tradeId => 1-based index in activeTrades (0 = not in array). Enables O(1) removal.
    mapping(uint256 => uint256) private _activeTradeIndex;
    uint256 public totalDeployed;
    uint256 public totalProfitRealized;
    /// @dev Rate-limit: max active trades at once to prevent unbounded array DoS
    uint256 public constant MAX_ACTIVE_TRADES = 50;

    constructor(address usdc_, address vault_, address owner_) Ownable(owner_) {
        usdc = usdc_;
        vault = vault_;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    modifier onlyVaultOrOwner() {
        if (msg.sender != vault && msg.sender != owner()) revert OnlyVaultOrOwner();
        _;
    }

    function requestMurabaha(address buyer, uint256 amount, uint256 markupBps, uint256 settlementWindow)
        external
        returns (uint256 tradeId)
    {
        if (markupBps == 0 || markupBps > 5000) revert InvalidMarkup();
        if (amount == 0) revert InvalidAmount();
        if (activeTrades.length >= MAX_ACTIVE_TRADES) revert InvalidAmount(); // DoS guard

        uint256 salePrice = amount + ((amount * markupBps) / 10_000);

        tradeId = ++tradeCount;
        uint256 deadline = block.timestamp + settlementWindow;

        trades[tradeId] = MurabahaTrade({
            id: tradeId,
            buyer: buyer,
            costAmount: amount,
            markupBps: markupBps,
            salePrice: salePrice,
            requestTime: block.timestamp,
            executeTime: 0,
            settleTime: 0,
            deadline: deadline,
            status: TradeStatus.PENDING
        });

        activeTrades.push(tradeId);
        _activeTradeIndex[tradeId] = activeTrades.length; // 1-based

        emit MurabahaRequested(tradeId, buyer, amount, markupBps, salePrice, deadline);
    }

    function executeMurabaha(uint256 tradeId) external onlyVaultOrOwner {
        MurabahaTrade storage trade = _loadTrade(tradeId);
        if (trade.status != TradeStatus.PENDING) revert InvalidTradeStatus(trade.status, TradeStatus.PENDING);
        if (block.timestamp > trade.deadline) revert DeadlinePassed();

        trade.status = TradeStatus.EXECUTED;
        trade.executeTime = block.timestamp;

        totalDeployed += trade.costAmount;

        emit MurabahaExecuted(tradeId, block.timestamp);
    }

    function settleMurabaha(uint256 tradeId) external {
        MurabahaTrade storage trade = _loadTrade(tradeId);
        if (trade.status != TradeStatus.EXECUTED) revert InvalidTradeStatus(trade.status, TradeStatus.EXECUTED);
        if (msg.sender != trade.buyer) revert BuyerOnly();
        if (block.timestamp > trade.deadline) revert DeadlinePassed();

        IERC20(usdc).safeTransferFrom(msg.sender, vault, trade.salePrice);

        trade.status = TradeStatus.SETTLED;
        trade.settleTime = block.timestamp;

        uint256 profit = trade.salePrice - trade.costAmount;
        totalProfitRealized += profit;

        if (trade.costAmount >= totalDeployed) {
            totalDeployed = 0;
        } else {
            totalDeployed -= trade.costAmount;
        }

        _removeActiveTrade(tradeId);

        emit MurabahaSettled(tradeId, profit, block.timestamp);
    }

    function expireTrade(uint256 tradeId) external onlyVaultOrOwner {
        MurabahaTrade storage trade = _loadTrade(tradeId);
        TradeStatus current = trade.status;
        bool valid = current == TradeStatus.PENDING || current == TradeStatus.EXECUTED;
        if (!valid) revert InvalidTradeStatus(current, TradeStatus.PENDING);
        if (block.timestamp <= trade.deadline) revert DeadlinePassed();

        trade.status = TradeStatus.EXPIRED;

        if (current == TradeStatus.EXECUTED) {
            if (trade.costAmount >= totalDeployed) {
                totalDeployed = 0;
            } else {
                totalDeployed -= trade.costAmount;
            }
        }

        _removeActiveTrade(tradeId);

        emit MurabahaExpired(tradeId);
    }

    function deploy(uint256 amount) external onlyVault returns (uint256 deployed) {
        totalDeployed += amount;
        emit Deployed(amount);
        return amount;
    }

    function recall(uint256 amount) external onlyVault returns (uint256 returned) {
        IERC20(usdc).safeTransfer(vault, amount);

        if (amount >= totalDeployed) {
            totalDeployed = 0;
        } else {
            totalDeployed -= amount;
        }

        emit Recalled(amount);
        return amount;
    }

    function currentValue() external view returns (uint256) {
        return totalDeployed + IERC20(usdc).balanceOf(address(this));
    }

    function protocolName() external pure returns (string memory) {
        return "Commodity Murabaha";
    }

    function getActiveTrades() external view returns (MurabahaTrade[] memory list) {
        uint256 length = activeTrades.length;
        list = new MurabahaTrade[](length);
        for (uint256 i = 0; i < length; i++) {
            list[i] = trades[activeTrades[i]];
        }
    }

    function getPendingTradeCount() external view returns (uint256 count) {
        uint256 length = activeTrades.length;
        for (uint256 i = 0; i < length; i++) {
            if (trades[activeTrades[i]].status == TradeStatus.PENDING) {
                count++;
            }
        }
    }

    function _loadTrade(uint256 tradeId) internal view returns (MurabahaTrade storage trade) {
        trade = trades[tradeId];
        if (trade.id == 0) revert TradeNotFound();
    }

    /// @dev O(1) removal using stored 1-based index mapping. No linear scan.
    function _removeActiveTrade(uint256 tradeId) internal {
        uint256 idx1 = _activeTradeIndex[tradeId]; // 1-based
        if (idx1 == 0) return; // not in active array

        uint256 idx0 = idx1 - 1;
        uint256 lastId = activeTrades[activeTrades.length - 1];

        activeTrades[idx0] = lastId;
        _activeTradeIndex[lastId] = idx1; // update moved element's index
        activeTrades.pop();
        delete _activeTradeIndex[tradeId];
    }
}
