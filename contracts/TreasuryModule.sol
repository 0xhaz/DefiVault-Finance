// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract TreasuryModule is Ownable2Step {
    error NotFeeSource();
    error InsufficientPending(uint256 requested, uint256 available);
    error NotShariahTreasury();
    error InvalidBps();

    struct FeeDisclosure {
        string treasuryType;
        uint256 adminFeeBps;
        uint256 musharakahShareBps;
        uint256 hurdleRateBps;
        uint256 pendingFees;
        uint256 totalFeesCollected;
        bool isShariahTreasury;
    }

    event FeesAccrued(uint256 amount, uint256 totalPending, string treasuryType);
    event FeesClaimed(address indexed receiver, uint256 amount, string treasuryType);
    event MusharakahProfitSplit(
        uint256 grossProfit,
        uint256 hurdleAmount,
        uint256 vaultShare,
        uint256 depositorShare,
        string treasuryType
    );
    event AdminFeeParamsUpdated(uint256 newAdminFeeBps);
    event MusharakahParamsUpdated(uint256 newShareBps, uint256 newHurdleBps);

    string public treasuryType;
    address public immutable feeSource;
    address public asset;
    uint256 public pendingFees;
    uint256 public totalFeesCollected;
    uint256 public lastAccrualTime;
    uint256 public totalAumAccrued;

    uint256 public adminFeeBps;
    uint256 public musharakahShareBps;
    uint256 public hurdleRateBps;
    bool public isShariahTreasury;

    modifier onlyFeeSource() {
        if (msg.sender != feeSource) revert NotFeeSource();
        _;
    }

    constructor(
        string memory treasuryType_,
        address feeSource_,
        address asset_,
        uint256 adminFeeBps_,
        uint256 musharakahShareBps_,
        uint256 hurdleRateBps_,
        address initialOwner
    ) Ownable(initialOwner) {
        if (adminFeeBps_ > 500) revert InvalidBps();
        if (musharakahShareBps_ > 3_000 || hurdleRateBps_ > 2_000) revert InvalidBps();

        treasuryType = treasuryType_;
        feeSource = feeSource_;
        asset = asset_;

        adminFeeBps = adminFeeBps_;
        musharakahShareBps = musharakahShareBps_;
        hurdleRateBps = hurdleRateBps_;
        isShariahTreasury = musharakahShareBps_ > 0;
    }

    function accrue(uint256 amount) external onlyFeeSource {
        pendingFees += amount;
        totalAumAccrued += amount;
        lastAccrualTime = block.timestamp;

        emit FeesAccrued(amount, pendingFees, treasuryType);
    }

    /// @notice Accounting-only claim. Caller must separately call vault.sweepFeesToTreasury()
    ///         to move actual tokens from the vault.
    function claimFees(address receiver, uint256 amount) external onlyOwner {
        if (amount > pendingFees) revert InsufficientPending(amount, pendingFees);

        pendingFees -= amount;
        totalFeesCollected += amount;

        emit FeesClaimed(receiver, amount, treasuryType);
    }

    function calculateMusharakahSplit(uint256 grossProfit, uint256 elapsedSeconds, uint256 principal)
        public
        view
        returns (uint256 hurdleAmount, uint256 vaultShare, uint256 depositorShare)
    {
        if (!isShariahTreasury) revert NotShariahTreasury();

        hurdleAmount = (principal * hurdleRateBps * elapsedSeconds) / (10_000 * 365 days);
        uint256 surplus = grossProfit > hurdleAmount ? grossProfit - hurdleAmount : 0;
        vaultShare = (surplus * musharakahShareBps) / 10_000;
        depositorShare = grossProfit - vaultShare;
    }

    function recordMusharakahProfit(uint256 vaultShare) external onlyFeeSource {
        if (!isShariahTreasury) revert NotShariahTreasury();

        pendingFees += vaultShare;
        totalAumAccrued += vaultShare;
        lastAccrualTime = block.timestamp;

        emit FeesAccrued(vaultShare, pendingFees, treasuryType);
    }

    function getFeeDisclosure() external view returns (FeeDisclosure memory disclosure) {
        disclosure = FeeDisclosure({
            treasuryType: treasuryType,
            adminFeeBps: adminFeeBps,
            musharakahShareBps: musharakahShareBps,
            hurdleRateBps: hurdleRateBps,
            pendingFees: pendingFees,
            totalFeesCollected: totalFeesCollected,
            isShariahTreasury: isShariahTreasury
        });
    }

    function setAdminFeeBps(uint256 bps) external onlyOwner {
        if (bps > 500) revert InvalidBps();
        adminFeeBps = bps;
        emit AdminFeeParamsUpdated(bps);
    }

    function setMusharakahParams(uint256 shareBps, uint256 hurdleBps) external onlyOwner {
        if (!isShariahTreasury) revert NotShariahTreasury();
        if (shareBps > 3_000 || hurdleBps > 2_000) revert InvalidBps();

        musharakahShareBps = shareBps;
        hurdleRateBps = hurdleBps;

        emit MusharakahParamsUpdated(shareBps, hurdleBps);
    }
}
