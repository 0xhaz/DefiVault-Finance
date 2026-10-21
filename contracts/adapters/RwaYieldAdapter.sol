// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IStrategyAdapter} from "../IStrategyAdapter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IRwaToken {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function mint(address to, uint256 amount) external;
}

interface IRwaOracle {
    function getPrice() external view returns (uint256 price, uint256 timestamp);
}

/// @notice Interest-bearing instrument (holds OUSG/BUIDL — US Treasury-backed funds).
/// @dev NOT for use in Shariah vaults. SR-001: OUSG and BUIDL fail the SC interest-bearing
///      income screen. This adapter may remain active in Conventional vaults only.
///      See docs/agents/SHARIAH_REVIEW.md for the board ruling stub.
contract RwaYieldAdapter is IStrategyAdapter, Ownable2Step {
    using SafeERC20 for IERC20;

    error OnlyVault();
    error LendingProtocolBlocked(address protocol);
    error OracleNotSet();
    error StaleOraclePrice(uint256 age);

    event RwaDeployed(uint256 usdcAmount, uint256 rwaTokensReceived);
    event RwaRecalled(uint256 usdcReturned, uint256 rwaTokensBurned);
    event OracleUpdated(address indexed previous, address indexed current);
    event ProtocolBlocked(address indexed protocol, bool blocked);

    address public immutable rwaToken;
    address public immutable usdc;
    address public immutable override vault;

    address public oracle;
    uint256 public totalDeployed;
    uint256 public rwaTokensHeld;
    string public rwaTokenName;
    bool public lendingProtocolGuard;
    mapping(address => bool) public blockedProtocols;

    constructor(address rwaToken_, address usdc_, address vault_, string memory rwaTokenName_, address owner_)
        Ownable(owner_)
    {
        rwaToken = rwaToken_;
        usdc = usdc_;
        vault = vault_;
        rwaTokenName = rwaTokenName_;
        lendingProtocolGuard = true;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    function deploy(uint256 amount) external onlyVault returns (uint256 deployed) {
        if (!lendingProtocolGuard) revert LendingProtocolBlocked(address(0));

        uint256 rwaPrice = _getRwaPrice();
        uint256 tokensToReceive = (amount * 1e18) / rwaPrice;

        rwaTokensHeld += tokensToReceive;
        totalDeployed += amount;

        emit RwaDeployed(amount, tokensToReceive);
        return amount;
    }

    function recall(uint256 amount) external onlyVault returns (uint256 returned) {
        uint256 rwaPrice = _getRwaPrice();
        uint256 tokensToBurn = (amount * 1e18) / rwaPrice;

        if (tokensToBurn > rwaTokensHeld) {
            tokensToBurn = rwaTokensHeld;
        }

        uint256 usdcReturned = (tokensToBurn * rwaPrice) / 1e18;
        IERC20(usdc).safeTransfer(vault, usdcReturned);

        rwaTokensHeld -= tokensToBurn;
        if (usdcReturned >= totalDeployed) {
            totalDeployed = 0;
        } else {
            totalDeployed -= usdcReturned;
        }

        emit RwaRecalled(usdcReturned, tokensToBurn);
        return usdcReturned;
    }

    function currentValue() external view returns (uint256) {
        if (oracle == address(0)) {
            return totalDeployed;
        }

        (uint256 price,) = IRwaOracle(oracle).getPrice();
        return (rwaTokensHeld * price) / 1e18;
    }

    function protocolName() external view returns (string memory) {
        return string.concat("RWA Yield: ", rwaTokenName);
    }

    // Deliberately no approve-for-lending function — this adapter is read-only from lending protocols by design

    function setOracle(address newOracle) external onlyOwner {
        address previous = oracle;
        oracle = newOracle;
        emit OracleUpdated(previous, newOracle);
    }

    function setBlockedProtocol(address protocol, bool blocked) external onlyOwner {
        blockedProtocols[protocol] = blocked;
        emit ProtocolBlocked(protocol, blocked);
    }

    function _getRwaPrice() internal view returns (uint256) {
        if (oracle == address(0)) {
            return 1e18;
        }

        (uint256 price, uint256 priceTime) = IRwaOracle(oracle).getPrice();
        uint256 age = block.timestamp - priceTime;
        if (age > 1 days) revert StaleOraclePrice(age);
        return price;
    }
}
