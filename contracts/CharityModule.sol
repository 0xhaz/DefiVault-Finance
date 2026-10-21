// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title  CharityModule
 * @notice Routes a configurable percentage of Shariah vault profit to a board-approved
 *         charity wallet (sadaqah) before the Musharakah profit split.
 *
 * @dev    Replaces the fixed-rate ZakatModule (now @deprecated) with:
 *           - A board-settable `charityBps` (default 250 = 2.5%, hard cap 500 = 5%)
 *           - 30-day timelock on both the charity wallet and the rate
 *           - Separate `totalCharityDistributed` counter (does NOT add to ZakatModule's counter)
 *
 *         Terminology: "Zakat" is a specific religious obligation with precise
 *         nisab and haul rules. This module distributes voluntary sadaqah.
 *         The word "Zakat" MUST NOT appear in any user-facing string without a
 *         board pronouncement per AGENTS.md rule on terminology.
 *
 *         Board rulings required before live use: SR-002 (rate), SR-003 (wallet).
 */
contract CharityModule is Ownable2Step {
    using SafeERC20 for IERC20;

    // ── Errors ──────────────────────────────────────────────────────────────

    error NotVault();
    error ZeroAmount();
    error ZeroWallet();
    error NoPendingChange();
    error TimelockNotElapsed(uint256 remaining);
    /// @dev Thrown when a proposed charityBps exceeds MAX_CHARITY_BPS.
    error CharityRateAboveCap(uint256 proposed, uint256 cap);

    // ── Events ──────────────────────────────────────────────────────────────

    event CharityDistributed(
        uint256 amount,
        address indexed charityWallet,
        uint256 charityBps,
        uint256 timestamp
    );
    event CharityWalletChangeProposed(address indexed proposed, uint256 executeAfter);
    event CharityWalletConfirmed(address indexed previous, address indexed confirmed);
    event CharityWalletChangeCancelled(address indexed cancelled);
    event CharityRateChangeProposed(uint256 proposed, uint256 executeAfter);
    event CharityRateConfirmed(uint256 previous, uint256 confirmed);
    event CharityRateChangeCancelled(uint256 cancelled);

    // ── Constants ────────────────────────────────────────────────────────────

    uint256 public constant TIMELOCK_PERIOD   = 30 days;
    /// @notice Hard cap on the charity rate — cannot exceed 5% of gross profit.
    ///         Requires a contract upgrade to raise. Protects depositor principal.
    uint256 public constant MAX_CHARITY_BPS   = 500;
    /// @notice Default charity rate: 2.5% of gross Musharakah profit.
    ///         Must be confirmed by the board (SR-002) before live use.
    uint256 public constant DEFAULT_CHARITY_BPS = 250;

    // ── State ────────────────────────────────────────────────────────────────

    /// @notice Active charity wallet. Must be a board-approved address (SR-003).
    address public charityWallet;
    /// @notice Pending wallet change (awaiting 30-day timelock).
    address public pendingCharityWallet;
    uint256 public walletChangeRequestTime;

    /// @notice Current charity rate in basis points (default 250 = 2.5%).
    uint256 public charityBps;
    /// @notice Pending rate change (awaiting 30-day timelock).
    uint256 public pendingCharityBps;
    uint256 public rateChangeRequestTime;
    bool    public hasPendingRateChange;

    /// @notice Lifetime USDC distributed to the charity wallet.
    uint256 public totalCharityDistributed;

    address public immutable asset;
    address public immutable vault;

    // ── Constructor ──────────────────────────────────────────────────────────

    constructor(
        address charityWallet_,
        address asset_,
        address vault_,
        address initialOwner
    ) Ownable(initialOwner) {
        if (charityWallet_ == address(0)) revert ZeroWallet();
        charityWallet = charityWallet_;
        asset         = asset_;
        vault         = vault_;
        charityBps    = DEFAULT_CHARITY_BPS;
    }

    // ── Distribution ─────────────────────────────────────────────────────────

    /**
     * @notice Deduct `charityBps` from `grossProfit` and transfer it to the charity wallet.
     * @dev    Called by the ShariahVault (via PurificationEscrow waterfall) BEFORE the
     *         Musharakah split. Caller must have approved this contract for `grossProfit`.
     * @param  grossProfit  Total USDC profit before any split. Must be > 0.
     * @return charityAmount  USDC sent to the charity wallet.
     * @return remaining      grossProfit minus charityAmount; passed on to Musharakah split.
     */
    function distributeCharity(uint256 grossProfit)
        external
        returns (uint256 charityAmount, uint256 remaining)
    {
        if (msg.sender != vault) revert NotVault();
        if (grossProfit == 0) revert ZeroAmount();

        charityAmount = (grossProfit * charityBps) / 10_000;
        remaining     = grossProfit - charityAmount;

        if (charityAmount > 0) {
            IERC20(asset).safeTransferFrom(vault, charityWallet, charityAmount);
        }

        totalCharityDistributed += charityAmount;
        emit CharityDistributed(charityAmount, charityWallet, charityBps, block.timestamp);
    }

    // ── Charity wallet timelock ──────────────────────────────────────────────

    function proposeCharityWalletChange(address newWallet) external onlyOwner {
        if (newWallet == address(0)) revert ZeroWallet();
        pendingCharityWallet   = newWallet;
        walletChangeRequestTime = block.timestamp;
        emit CharityWalletChangeProposed(newWallet, block.timestamp + TIMELOCK_PERIOD);
    }

    function confirmCharityWalletChange() external onlyOwner {
        address proposed = pendingCharityWallet;
        if (proposed == address(0)) revert NoPendingChange();
        uint256 executeAfter = walletChangeRequestTime + TIMELOCK_PERIOD;
        if (block.timestamp < executeAfter) revert TimelockNotElapsed(executeAfter - block.timestamp);

        address previous = charityWallet;
        charityWallet         = proposed;
        pendingCharityWallet   = address(0);
        walletChangeRequestTime = 0;

        emit CharityWalletConfirmed(previous, charityWallet);
    }

    function cancelCharityWalletChange() external onlyOwner {
        address proposed = pendingCharityWallet;
        if (proposed == address(0)) revert NoPendingChange();
        emit CharityWalletChangeCancelled(proposed);
        pendingCharityWallet   = address(0);
        walletChangeRequestTime = 0;
    }

    // ── Charity rate timelock ────────────────────────────────────────────────

    function proposeCharityRateChange(uint256 newBps) external onlyOwner {
        if (newBps > MAX_CHARITY_BPS) revert CharityRateAboveCap(newBps, MAX_CHARITY_BPS);
        pendingCharityBps    = newBps;
        rateChangeRequestTime = block.timestamp;
        hasPendingRateChange  = true;
        emit CharityRateChangeProposed(newBps, block.timestamp + TIMELOCK_PERIOD);
    }

    function confirmCharityRateChange() external onlyOwner {
        if (!hasPendingRateChange) revert NoPendingChange();
        uint256 executeAfter = rateChangeRequestTime + TIMELOCK_PERIOD;
        if (block.timestamp < executeAfter) revert TimelockNotElapsed(executeAfter - block.timestamp);

        uint256 previous = charityBps;
        charityBps           = pendingCharityBps;
        pendingCharityBps    = 0;
        rateChangeRequestTime = 0;
        hasPendingRateChange  = false;

        emit CharityRateConfirmed(previous, charityBps);
    }

    function cancelCharityRateChange() external onlyOwner {
        if (!hasPendingRateChange) revert NoPendingChange();
        emit CharityRateChangeCancelled(pendingCharityBps);
        pendingCharityBps    = 0;
        rateChangeRequestTime = 0;
        hasPendingRateChange  = false;
    }
}
