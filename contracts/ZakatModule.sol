// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @dev DEPRECATED — superseded by CharityModule + PurificationEscrow (Task B).
 *
 *      ZakatModule remains deployed and functional so that v1 vault history and
 *      existing on-chain recordings are preserved. New ShariahVault deployments
 *      MUST use CharityModule + PurificationEscrow instead.
 *
 *      ZakatModule MUST NOT be used as the primary profit-routing mechanism in any
 *      new vault deployment. See SHARIAH_REVIEW.md SR-002 / SR-003 / SR-004 for the
 *      board rulings required before CharityModule goes live.
 *
 *      "Zakat" is a specific religious obligation (2.5% of annual nisab-exceeding
 *      wealth). This contract calculates and routes a fixed 2.5% of Musharakah
 *      gross profit, which may not satisfy the legal definition of Zakat without
 *      a formal board pronouncement. CharityModule uses the term "sadaqah" instead.
 */
contract ZakatModule is Ownable2Step {
    using SafeERC20 for IERC20;

    error NotVault();
    error TimelockNotElapsed(uint256 remaining);
    error NoPendingChange();
    error ZeroWallet();
    error ZeroAmount();

    event ZakatDistributed(uint256 amount, address indexed zakatWallet, uint256 timestamp);
    event ZakatWalletChangeProposed(address indexed proposed, uint256 executeAfter);
    event ZakatWalletConfirmed(address indexed previous, address indexed confirmed);
    event ZakatWalletChangeCancelled(address indexed cancelled);

    address public zakatWallet;
    address public pendingZakatWallet;
    uint256 public walletChangeRequestTime;

    uint256 public constant TIMELOCK_PERIOD = 30 days;
    uint256 public constant ZAKAT_BPS = 250;

    uint256 public totalZakatDistributed;
    address public immutable asset;
    address public immutable vault;

    constructor(address zakatWallet_, address asset_, address vault_, address initialOwner) Ownable(initialOwner) {
        if (zakatWallet_ == address(0)) revert ZeroWallet();

        zakatWallet = zakatWallet_;
        asset = asset_;
        vault = vault_;
    }

    function distributeZakat(uint256 grossProfit) external returns (uint256 zakatAmount, uint256 remaining) {
        if (msg.sender != vault) revert NotVault();
        if (grossProfit == 0) revert ZeroAmount();

        zakatAmount = (grossProfit * ZAKAT_BPS) / 10_000;
        remaining = grossProfit - zakatAmount;

        IERC20(asset).safeTransferFrom(vault, zakatWallet, zakatAmount);

        totalZakatDistributed += zakatAmount;
        emit ZakatDistributed(zakatAmount, zakatWallet, block.timestamp);
    }

    function proposeZakatWalletChange(address newWallet) external onlyOwner {
        if (newWallet == address(0)) revert ZeroWallet();

        pendingZakatWallet = newWallet;
        walletChangeRequestTime = block.timestamp;

        emit ZakatWalletChangeProposed(newWallet, block.timestamp + TIMELOCK_PERIOD);
    }

    function confirmZakatWalletChange() external onlyOwner {
        address proposed = pendingZakatWallet;
        if (proposed == address(0)) revert NoPendingChange();

        uint256 executeAfter = walletChangeRequestTime + TIMELOCK_PERIOD;
        if (block.timestamp < executeAfter) {
            revert TimelockNotElapsed(executeAfter - block.timestamp);
        }

        address previous = zakatWallet;
        zakatWallet = proposed;
        pendingZakatWallet = address(0);
        walletChangeRequestTime = 0;

        emit ZakatWalletConfirmed(previous, zakatWallet);
    }

    function cancelZakatWalletChange() external onlyOwner {
        address proposed = pendingZakatWallet;
        if (proposed == address(0)) revert NoPendingChange();

        emit ZakatWalletChangeCancelled(proposed);

        pendingZakatWallet = address(0);
        walletChangeRequestTime = 0;
    }
}
