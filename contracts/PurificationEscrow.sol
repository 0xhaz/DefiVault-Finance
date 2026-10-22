// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CharityModule} from "./CharityModule.sol";
import {TreasuryModule} from "./TreasuryModule.sol";

/**
 * @title  PurificationEscrow
 * @notice Implements the Shariah profit-distribution waterfall:
 *
 *           1. Purification (optional, rate = purificationBps)
 *              Deducted FIRST — routes impure income to charity before any split.
 *              Rate is set to 0 until the board identifies non-compliant income.
 *
 *           2. Charitable contribution (sadaqah via CharityModule)
 *              Applied to (grossProfit - purified). Default 2.5% (SR-002 pending).
 *
 *           3. Musharakah split (TreasuryModule.calculateMusharakahSplit)
 *              Applied to remainder: 10% vault share above 4% hurdle.
 *
 *         Invariant: purified + charity + vaultShare + depositorShare == grossProfit
 *         (proven by FuzzPurificationEscrow — see contracts/test/)
 *
 * @dev    Replaces the direct call sequence in ShariahVault.claimMusharakahProfit.
 *         The vault approves this contract for `grossProfit` then calls
 *         `executeWaterfall(grossProfit, elapsed, principal)`.
 *
 *         `purificationBps` is intentionally set to 0 by default. It is ONLY
 *         raised when the board identifies a specific impure-income event
 *         (e.g. a protocol rebate that fails the income screening). Setting a
 *         non-zero rate without a board ruling violates the depositor's trust.
 *
 *         Board rulings required: SR-002, SR-003, SR-004.
 */
contract PurificationEscrow is Ownable2Step {
    using SafeERC20 for IERC20;

    // ── Errors ──────────────────────────────────────────────────────────────

    error NotVault();
    error ZeroAmount();
    /// @dev Thrown when purificationBps + charityModule.charityBps would exceed 5000 (50%).
    ///      Safeguard against misconfiguration that would drain depositor principal.
    error CombinedDeductionAboveCap(uint256 combined, uint256 cap);
    /// @dev Thrown when purificationBps is set above the hard cap (1000 = 10%).
    error PurificationAboveCap(uint256 proposed, uint256 cap);
    /// @dev PR2: board role required to propose rate change.
    error NotBoardRole(address caller);
    /// @dev Proposal executed before timelock elapsed.
    error TimelockNotElapsed(uint256 earliest, uint256 current);
    /// @dev No pending proposal to execute or cancel.
    error NoPendingProposal();
    /// @dev A proposal already exists; cancel it first.
    error ProposalAlreadyExists();

    // ── Events ──────────────────────────────────────────────────────────────

    event WaterfallExecuted(
        uint256 grossProfit,
        uint256 purified,
        uint256 charity,
        uint256 vaultShare,
        uint256 depositorShare
    );
    event PurificationBpsUpdated(uint256 previous, uint256 updated);
    event PurificationRateProposed(uint256 newBps, uint256 executeAfter);
    event PurificationRateProposalCancelled();

    // ── Constants ────────────────────────────────────────────────────────────

    /// @notice Hard cap: purificationBps cannot exceed 10% of gross profit.
    uint256 public constant MAX_PURIFICATION_BPS = 1000;
    /// @notice Hard cap: purification + charity combined cannot exceed 50%.
    uint256 public constant MAX_COMBINED_DEDUCTION_BPS = 5000;
    /// @notice Board role must propose; 30-day timelock before execution (PR2, SR-G6 → SR-012).
    uint256 public constant PURIFICATION_TIMELOCK = 30 days;

    // ── State ────────────────────────────────────────────────────────────────

    /// @notice Fraction of grossProfit to set aside as purification (default 0).
    ///         Raised only when the board identifies a specific impure-income event.
    uint256 public purificationBps;

    /// @notice Board members authorised to propose rate changes (PR2).
    mapping(address => bool) public boardRole;

    struct PendingRateChange {
        uint256 newBps;
        uint256 executeAfter;
        bool exists;
    }
    /// @notice Pending purification rate proposal.
    PendingRateChange public pendingRateChange;

    address public immutable vault;
    address public immutable asset;
    CharityModule  public immutable charityModule;
    TreasuryModule public immutable shariahTreasury;

    // ── Constructor ──────────────────────────────────────────────────────────

    constructor(
        address vault_,
        address asset_,
        address charityModule_,
        address shariahTreasury_,
        address initialOwner
    ) Ownable(initialOwner) {
        vault           = vault_;
        asset           = asset_;
        charityModule   = CharityModule(charityModule_);
        shariahTreasury = TreasuryModule(shariahTreasury_);
        purificationBps = 0; // no impure income identified at deploy
        boardRole[initialOwner] = true; // deployer is initial board member
    }

    // ── Waterfall ────────────────────────────────────────────────────────────

    /**
     * @notice Execute the full Shariah profit waterfall.
     * @dev    The vault MUST have approved this contract for `grossProfit` before calling.
     *         Approval is typically done with `forceApprove` directly before this call.
     *
     *         Steps:
     *           1. Pull grossProfit from vault into escrow
     *           2. Deduct purification (purificationBps) — send to charityWallet directly
     *           3. Approve CharityModule for remaining; call distributeCharity()
     *           4. Call shariahTreasury.calculateMusharakahSplit() on remainder after charity
     *           5. Push vaultShare to shariahTreasury via recordMusharakahProfit
     *           6. Push depositorShare back to vault
     *           7. Emit WaterfallExecuted
     *
     * @param  grossProfit  Total USDC profit. Must be > 0.
     * @param  elapsed      Seconds since hurdleStartTime (passed from vault).
     * @param  principal    Hurdle principal (passed from vault).
     * @return purified       Amount sent as purification.
     * @return charity        Amount sent as charitable contribution.
     * @return vaultShare     Manager's Musharakah share (accrued in treasury).
     * @return depositorShare  Depositor's share (returned to vault).
     */
    function executeWaterfall(
        uint256 grossProfit,
        uint256 elapsed,
        uint256 principal
    )
        external
        returns (
            uint256 purified,
            uint256 charity,
            uint256 vaultShare,
            uint256 depositorShare
        )
    {
        if (msg.sender != vault) revert NotVault();
        if (grossProfit == 0) revert ZeroAmount();

        // Validate combined deduction will not exceed cap before pulling funds.
        uint256 combinedBps = purificationBps + charityModule.charityBps();
        if (combinedBps > MAX_COMBINED_DEDUCTION_BPS) {
            revert CombinedDeductionAboveCap(combinedBps, MAX_COMBINED_DEDUCTION_BPS);
        }

        // 1. Pull grossProfit from vault into escrow.
        IERC20(asset).safeTransferFrom(vault, address(this), grossProfit);

        // 2. Purification: send directly to charity wallet, no CharityModule counter.
        if (purificationBps > 0) {
            purified = (grossProfit * purificationBps) / 10_000;
            IERC20(asset).safeTransfer(charityModule.charityWallet(), purified);
        }

        uint256 afterPurification = grossProfit - purified;

        // 3. Charitable contribution via CharityModule.
        //    Approve charityModule to pull from escrow, then call distributeCharity.
        IERC20(asset).forceApprove(address(charityModule), afterPurification);
        (, uint256 afterCharity) = charityModule.distributeCharity(afterPurification);
        charity = afterPurification - afterCharity;
        IERC20(asset).forceApprove(address(charityModule), 0);

        // 4. Musharakah split on the remainder.
        (, uint256 vaultShareCalc, uint256 depositorShareCalc) =
            shariahTreasury.calculateMusharakahSplit(afterCharity, elapsed, principal);
        vaultShare     = vaultShareCalc;
        depositorShare = depositorShareCalc;

        // 5. Record vault's share in treasury (accounting only — no token transfer).
        shariahTreasury.recordMusharakahProfit(vaultShare);

        // 6. Return depositor share to vault.
        if (depositorShare > 0) {
            IERC20(asset).safeTransfer(vault, depositorShare);
        }

        // Sanity: any dust (rounding) stays in escrow — negligible in practice.
        emit WaterfallExecuted(grossProfit, purified, charity, vaultShare, depositorShare);
    }

    // ── Owner controls ───────────────────────────────────────────────────────

    // ── Board role management ────────────────────────────────────────────────

    modifier onlyBoard() {
        if (!boardRole[msg.sender]) revert NotBoardRole(msg.sender);
        _;
    }

    /// @notice Owner grants board membership (no timelock — owner is trusted for membership).
    function grantBoardRole(address account) external onlyOwner { boardRole[account] = true; }

    /// @notice Owner revokes board membership.
    function revokeBoardRole(address account) external onlyOwner { boardRole[account] = false; }

    // ── Purification rate — timelocked (PR2 / SR-012) ───────────────────────

    /**
     * @notice Board proposes a new purification rate (30-day timelock).
     * @dev    ONLY raise this when the board has identified a specific impure-income event.
     */
    function proposePurificationRate(uint256 newBps) external onlyBoard {
        if (newBps > MAX_PURIFICATION_BPS) revert PurificationAboveCap(newBps, MAX_PURIFICATION_BPS);
        uint256 combined = newBps + charityModule.charityBps();
        if (combined > MAX_COMBINED_DEDUCTION_BPS) revert CombinedDeductionAboveCap(combined, MAX_COMBINED_DEDUCTION_BPS);
        if (pendingRateChange.exists) revert ProposalAlreadyExists();
        uint256 executeAfter = block.timestamp + PURIFICATION_TIMELOCK;
        pendingRateChange = PendingRateChange({newBps: newBps, executeAfter: executeAfter, exists: true});
        emit PurificationRateProposed(newBps, executeAfter);
    }

    /// @notice Board confirms the pending rate change after the 30-day timelock.
    function confirmPurificationRate() external onlyBoard {
        PendingRateChange memory p = pendingRateChange;
        if (!p.exists) revert NoPendingProposal();
        if (block.timestamp < p.executeAfter) revert TimelockNotElapsed(p.executeAfter, block.timestamp);
        delete pendingRateChange;
        uint256 previous = purificationBps;
        purificationBps  = p.newBps;
        emit PurificationBpsUpdated(previous, p.newBps);
    }

    /// @notice Board cancels the pending rate proposal.
    function cancelPurificationRate() external onlyBoard {
        if (!pendingRateChange.exists) revert NoPendingProposal();
        delete pendingRateChange;
        emit PurificationRateProposalCancelled();
    }
}
