// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Minimal interface to query board membership from ShariahAdapterRegistry (I4).
interface IShariahRegistry {
    function isBoard(address account) external view returns (bool);
}

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
    error EscrowAlreadySet();
    error NoPendingChange();
    error TimelockNotElapsed(uint256 remaining);
    /// @dev Thrown when a proposed charityBps exceeds MAX_CHARITY_BPS.
    error CharityRateAboveCap(uint256 proposed, uint256 cap);
    /// @dev Thrown when caller is neither owner nor a board member per the registry (I4).
    error NotBoardOrOwner(address caller);
    /// @dev Thrown when deployed without a registry (J3).
    error RegistryRequired();

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
    event EscrowSet(address indexed escrow);

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
    /// @notice PurificationEscrow address.  Set after escrow deploy via setEscrow().
    ///         distributeCharity() accepts calls from either vault or escrow so that
    ///         the waterfall path (vault → escrow → charityModule) works correctly.
    address public escrow;
    /// @notice Optional Shariah registry for single-source board membership (I4).
    ///         When set, board-gated functions check registry.isBoard(msg.sender).
    ///         When address(0), only the owner can call those functions.
    address public immutable boardRegistry;

    // ── Constructor ──────────────────────────────────────────────────────────

    constructor(
        address charityWallet_,
        address asset_,
        address vault_,
        address initialOwner,
        address boardRegistry_ // J3: must be non-zero for Shariah deploys
    ) Ownable(initialOwner) {
        if (charityWallet_ == address(0)) revert ZeroWallet();
        if (boardRegistry_ == address(0)) revert RegistryRequired();
        charityWallet  = charityWallet_;
        asset          = asset_;
        vault          = vault_;
        boardRegistry  = boardRegistry_;
        charityBps     = DEFAULT_CHARITY_BPS;
    }

    // ── Board modifier (I4 / K2) ──────────────────────────────────────────────

    /// @dev Allows only board members per the registry (boardRegistry is always set — J3).
    ///      The owner alone CANNOT call these functions unless they are also on the board.
    ///      An owner who is also the initialBoardMember of the registry may call.
    ///      Renamed from onlyBoardOrOwner to onlyBoard (K2) since boardRegistry is mandatory
    ///      and an owner who is not on the board is blocked regardless.
    modifier onlyBoard() {
        if (!IShariahRegistry(boardRegistry).isBoard(msg.sender)) revert NotBoardOrOwner(msg.sender);
        _;
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
    /// @notice Wire the PurificationEscrow after it is deployed.
    ///         Must be called once by the owner before any profit claim.
    ///         The escrow calls distributeCharity() as part of executeWaterfall().
    function setEscrow(address escrow_) external onlyOwner {
        if (escrow != address(0)) revert EscrowAlreadySet();
        if (escrow_ == address(0)) revert ZeroWallet();
        escrow = escrow_;
        emit EscrowSet(escrow_);
    }

    function distributeCharity(uint256 grossProfit)
        external
        returns (uint256 charityAmount, uint256 remaining)
    {
        // Accept calls from the vault (direct) or from the escrow (waterfall path).
        if (msg.sender != vault && msg.sender != escrow) revert NotVault();
        if (grossProfit == 0) revert ZeroAmount();

        charityAmount = (grossProfit * charityBps) / 10_000;
        remaining     = grossProfit - charityAmount;

        if (charityAmount > 0) {
            // Pull from msg.sender (the escrow holds the profit and has already
            // called forceApprove(charityModule, grossProfit) before this call).
            IERC20(asset).safeTransferFrom(msg.sender, charityWallet, charityAmount);
        }

        totalCharityDistributed += charityAmount;
        emit CharityDistributed(charityAmount, charityWallet, charityBps, block.timestamp);
    }

    // ── Charity wallet timelock ──────────────────────────────────────────────

    function proposeCharityWalletChange(address newWallet) external onlyBoard {
        if (newWallet == address(0)) revert ZeroWallet();
        pendingCharityWallet   = newWallet;
        walletChangeRequestTime = block.timestamp;
        emit CharityWalletChangeProposed(newWallet, block.timestamp + TIMELOCK_PERIOD);
    }

    function confirmCharityWalletChange() external onlyBoard {
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

    function cancelCharityWalletChange() external onlyBoard {
        address proposed = pendingCharityWallet;
        if (proposed == address(0)) revert NoPendingChange();
        emit CharityWalletChangeCancelled(proposed);
        pendingCharityWallet   = address(0);
        walletChangeRequestTime = 0;
    }

    // ── Charity rate timelock ────────────────────────────────────────────────

    function proposeCharityRateChange(uint256 newBps) external onlyBoard {
        if (newBps > MAX_CHARITY_BPS) revert CharityRateAboveCap(newBps, MAX_CHARITY_BPS);
        pendingCharityBps    = newBps;
        rateChangeRequestTime = block.timestamp;
        hasPendingRateChange  = true;
        emit CharityRateChangeProposed(newBps, block.timestamp + TIMELOCK_PERIOD);
    }

    function confirmCharityRateChange() external onlyBoard {
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

    function cancelCharityRateChange() external onlyBoard {
        if (!hasPendingRateChange) revert NoPendingChange();
        emit CharityRateChangeCancelled(pendingCharityBps);
        pendingCharityBps    = 0;
        rateChangeRequestTime = 0;
        hasPendingRateChange  = false;
    }
}
