// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AutonomousVault} from "./AutonomousVault.sol";
import {TreasuryModule} from "./TreasuryModule.sol";
import {ZakatModule} from "./ZakatModule.sol";
import {PurificationEscrow} from "./PurificationEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Minimal interface to read currentValue() and isPriceSane() from a gold adapter.
interface IGoldAdapter {
    function currentValue() external view returns (uint256);
    function isPriceSane() external view returns (bool);
}

/// @dev Minimal Chainlink-style oracle interface for price reads (same as AggregatorV3Interface).
interface IGoldOracle {
    function latestRoundData() external view returns (
        uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
    );
    function decimals() external view returns (uint8);
}

contract ShariahVault is AutonomousVault {
    using SafeERC20 for IERC20;

    error AdapterNotScreened();
    error AssetNotPermitted(address asset_);
    /// @dev Thrown when the vault tries to route a GOLD_SPREAD position cross-chain.
    ///      Gold exchanges must be atomic (yad bi yad) — cross-chain is non-atomic.
    ///      SR-005 must be resolved before lifting this guard.
    error NonAtomicGoldExchange();
    /// @dev Thrown when deploying to either gold adapter would push combined gold above MAX_GOLD_BPS.
    error GoldCapExceeded(uint256 combinedGoldValue, uint256 cap);

    error PurificationEscrowNotSet();

    event AdapterScreened(address indexed adapter, bool approved);
    event PermittedAssetUpdated(address indexed asset_, bool permitted);
    event WakalaFeeAccrued(uint256 amount);
    event MusharakahProfitClaimed(uint256 grossProfit, uint256 purified, uint256 charity, uint256 vaultShare, uint256 depositorShare);
    event ShariahScreeningToggled(bool enabled);
    event GoldCrossChainBlockedUpdated(bool blocked);
    event GoldAllocationAdapterUpdated(address indexed adapter);
    event GoldSpreadAdapterUpdated(address indexed adapter);
    event PurificationEscrowUpdated(address indexed escrow);
    event DustThresholdUpdated(uint256 previous, uint256 updated);

    TreasuryModule public immutable shariahTreasury;
    /// @dev v1 — DEPRECATED. Kept for history. New profit routing uses purificationEscrow.
    ZakatModule public immutable zakatModule;
    /// @notice v2 profit-distribution waterfall: purification → sadaqah → Musharakah split.
    ///         Set via setPurificationEscrow(). If zero, claimMusharakahProfit reverts.
    PurificationEscrow public purificationEscrow;

    /// @notice Hard cap: combined S2-H (PAXG) + S6-H (XAUT) value must not exceed 30% of totalAssets.
    /// @dev    Hard-coded — not board-settable. Requires a contract upgrade to change.
    uint256 public constant MAX_GOLD_BPS = 3000;

    bool public shariahScreeningEnabled;
    mapping(address => bool) public screened;
    mapping(address => bool) public permittedAssets;
    /// @notice When true, all deployCrossChain calls revert NonAtomicGoldExchange.
    /// @dev    Set to true when the GoldExchangeAdapter is configured for this vault.
    ///         Only blocks cross-chain routing; local deployCapital() is unaffected.
    ///         SR-007 pending: will narrow this to GOLD_SPREAD-specific routing when
    ///         the ETH_SPREAD board ruling is complete.
    bool public goldCrossChainBlocked;

    /// @notice S2-H gold spread adapter (GoldExchangeAdapter — PAXG). Used for combined cap check.
    address public goldSpreadAdapter;

    /// @notice S6-H gold allocation adapter (GoldAllocationAdapter — XAUT). Used for combined cap check.
    address public goldAllocationAdapter;

    /// @notice Minimum adapter value (USDC, 6 dec) that triggers a deposit pause when price is stale.
    ///         An empty adapter (currentValue <= dustThreshold) never blocks deposits even if stale.
    ///         Default 1e6 = 1 USDC. Board-settable via setDustThreshold().
    uint256 public dustThreshold = 1e6;

    uint256 public lastFeeAccrualTime;
    uint256 public hurdlePrincipal;
    uint256 public hurdleStartTime;
    /// @notice Cumulative unrecovered loss below the high-water mark (PR3.1).
    ///         Set to max(0, highWaterMark - totalAssets()) at each profit claim.
    ///         Cleared when totalAssets() recovers to highWaterMark.
    uint256 public hwmDeficit;
    /// @notice Highest totalAssets() seen at the start of any claim period (PR3.1).
    uint256 public highWaterMark;

    constructor(
        IERC20 asset_,
        address initialOwner,
        uint32 sourceDomain_,
        address shariahTreasury_,
        address zakatModule_ // pass address(0) for V2 deployments (ZakatModule is deprecated)
    ) AutonomousVault(asset_, initialOwner, sourceDomain_) {
        shariahTreasury = TreasuryModule(shariahTreasury_);
        zakatModule = ZakatModule(zakatModule_); // zero address is valid — v2 uses PurificationEscrow

        shariahScreeningEnabled = true;
        lastFeeAccrualTime = block.timestamp;
        hurdleStartTime    = block.timestamp;
        highWaterMark      = 0; // set on first deposit or explicit call
        permittedAssets[address(asset_)] = true;
    }

    function name() public pure virtual override(ERC20, IERC20Metadata) returns (string memory) {
        return "Shariah Vault Share";
    }

    function symbol() public pure virtual override(ERC20, IERC20Metadata) returns (string memory) {
        return "svUSDC";
    }

    /// @notice Override deployCapital to enforce Shariah screening and accrue Wakala fee.
    /// @dev Screening check gates ALL deployments — base `deployCapital` is now virtual
    ///      so this override is the single entry point for ShariahVault capital deployment.
    function deployCapital(address strategy, uint256 amount, bytes calldata data)
        external
        virtual
        override
        onlyManagerOrOwner
    {
        if (paused) revert Paused();
        if (!permittedAssets[asset()]) revert AssetNotPermitted(asset());
        if (shariahScreeningEnabled && !screened[strategy]) revert AdapterNotScreened();

        data;

        uint256 currentAssets = totalAssets();
        uint256 maxDeployable = (currentAssets * maxAllocationBps) / 10_000;
        if (totalDeployed + amount > maxDeployable) revert AllocationExceedsLimit();

        // Combined gold cap: S2-H (PAXG) + S6-H (XAUT) must not exceed MAX_GOLD_BPS of totalAssets.
        // Check only when deploying to either gold adapter.
        if (strategy == goldSpreadAdapter || strategy == goldAllocationAdapter) {
            uint256 paxgValue  = goldSpreadAdapter      != address(0) ? IGoldAdapter(goldSpreadAdapter).currentValue()      : 0;
            uint256 xautValue  = goldAllocationAdapter  != address(0) ? IGoldAdapter(goldAllocationAdapter).currentValue()  : 0;
            uint256 combined   = paxgValue + xautValue + amount;
            uint256 goldCap    = (currentAssets * MAX_GOLD_BPS) / 10_000;
            if (combined > goldCap) revert GoldCapExceeded(combined, goldCap);
        }

        IERC20(asset()).safeTransfer(strategy, amount);
        totalDeployed += amount;

        emit CapitalDeployed(strategy, amount);

        _accrueWakalaFee();
    }

    /// @notice Override deployCrossChain to block gold-strategy cross-chain routing.
    /// @dev    GOLD_SPREAD requires atomic (same-transaction) settlement (yad bi yad).
    ///         Any attempt to route the goldExchangeAdapter cross-chain reverts here.
    ///         ETH_SPREAD is NOT yet gated here — see SR-007 for the pending ruling.
    function deployCrossChain(uint32 destinationDomain, bytes32 recipient, uint256 amount)
        public
        override
        onlyManagerOrOwner
    {
        if (goldCrossChainBlocked) revert NonAtomicGoldExchange();
        super.deployCrossChain(destinationDomain, recipient, amount);
    }

    function _accrueWakalaFee() internal {
        uint256 elapsed = block.timestamp - lastFeeAccrualTime;
        uint256 aum = totalAssets();
        uint256 fee = (aum * shariahTreasury.adminFeeBps() * elapsed) / (10_000 * 365 days);

        if (fee > 0) {
            shariahTreasury.accrue(fee);
        }

        lastFeeAccrualTime = block.timestamp;
        emit WakalaFeeAccrued(fee);
    }

    /**
     * @notice Distribute Shariah profit through the v2 waterfall (purification → sadaqah → Musharakah).
     * @dev    Requires `purificationEscrow` to be set (setPurificationEscrow).
     *         The escrow contract enforces the full invariant:
     *           purified + charity + vaultShare + depositorShare == grossProfit
     *
     *         v1 ZakatModule path has been removed. Existing v1 vaults retain their
     *         ZakatModule and continue to function — only new profit claims use this path.
     */
    function claimMusharakahProfit(uint256 grossProfit) external onlyManagerOrOwner {
        if (address(purificationEscrow) == address(0)) revert PurificationEscrowNotSet();

        // Approve escrow to pull the gross profit from vault.
        IERC20(asset()).forceApprove(address(purificationEscrow), grossProfit);

        // PR3.1: Update high-water mark and deficit BEFORE claiming profit.
        uint256 assetsNow = totalAssets();
        if (assetsNow > highWaterMark) {
            highWaterMark = assetsNow;
            hwmDeficit    = 0;
        } else {
            // Below high-water mark: deficit persists, manager earns nothing on recovery.
            hwmDeficit = highWaterMark - assetsNow;
        }

        (uint256 purified, uint256 charity, uint256 vaultShare, uint256 depositorShare) =
            purificationEscrow.executeWaterfall(
                grossProfit,
                block.timestamp - hurdleStartTime,
                hurdlePrincipal
            );

        // Clear any leftover allowance (defensive).
        IERC20(asset()).forceApprove(address(purificationEscrow), 0);

        // PR3.2: Lock the depositor share for linear unlock (prevents deposit-claim-redeem sandwich).
        if (depositorShare > 0) {
            _lockProfitInternal(depositorShare);
        }

        hurdlePrincipal = totalAssets();
        hurdleStartTime = block.timestamp;
        // Update HWM to new assets after claim.
        if (totalAssets() > highWaterMark) highWaterMark = totalAssets();

        emit MusharakahProfitClaimed(grossProfit, purified, charity, vaultShare, depositorShare);
    }

    /// @notice Sweep accrued fees to a receiver. Amount is capped to `pendingFees` to
    ///         prevent owner from sweeping depositor principal under the guise of fee claims.
    function sweepFeesToTreasury(address receiver, uint256 amount) external onlyOwner {
        uint256 pending = shariahTreasury.pendingFees();
        if (amount > pending) revert AllocationExceedsLimit(); // reuse error: amount > accrued
        IERC20(asset()).safeTransfer(receiver, amount);
        shariahTreasury.claimFees(receiver, amount);
    }

    function setScreened(address adapter, bool approved) external onlyOwner {
        screened[adapter] = approved;
        emit AdapterScreened(adapter, approved);
    }

    function setPermittedAsset(address asset_, bool permitted) external onlyOwner {
        permittedAssets[asset_] = permitted;
        emit PermittedAssetUpdated(asset_, permitted);
    }

    function setGoldCrossChainBlocked(bool blocked) external onlyOwner {
        goldCrossChainBlocked = blocked;
        emit GoldCrossChainBlockedUpdated(blocked);
    }

    function setShariahScreening(bool enabled) external onlyOwner {
        shariahScreeningEnabled = enabled;
        emit ShariahScreeningToggled(enabled);
    }

    /**
     * @notice Returns 0 when any gold adapter reports an insane price (PR1 — deposit pause).
     * @dev    Keeps redemptions open — only blocks new capital entering at a wrong price.
     *         If neither gold adapter is set, falls through to the ERC-4626 default.
     */
    function maxDeposit(address receiver) public view virtual override returns (uint256) {
        if (_goldPriceInsane()) return 0;
        return super.maxDeposit(receiver);
    }

    /// @notice Mirror of maxDeposit — blocks minting when oracle is insane.
    function maxMint(address receiver) public view virtual override returns (uint256) {
        if (_goldPriceInsane()) return 0;
        return super.maxMint(receiver);
    }

    /// @dev Returns true when at least one gold adapter is set, reports price insanity,
    ///      AND holds more than dustThreshold USDC of value.
    ///      An adapter with no material position (e.g. S6-H disabled, S2-H idle) never
    ///      blocks deposits even if its oracle or last-swap timestamp is stale (J2).
    function _goldPriceInsane() internal view returns (bool) {
        if (goldAllocationAdapter != address(0)) {
            IGoldAdapter adp = IGoldAdapter(goldAllocationAdapter);
            if (!adp.isPriceSane() && adp.currentValue() > dustThreshold) return true;
        }
        if (goldSpreadAdapter != address(0)) {
            IGoldAdapter adp = IGoldAdapter(goldSpreadAdapter);
            if (!adp.isPriceSane() && adp.currentValue() > dustThreshold) return true;
        }
        return false;
    }

    /// @notice Set the dust threshold for deposit-pause logic (J2).
    function setDustThreshold(uint256 threshold) external onlyOwner {
        uint256 previous = dustThreshold;
        dustThreshold = threshold;
        emit DustThresholdUpdated(previous, threshold);
    }

    function setHurdlePrincipal(uint256 principal) external onlyOwner {
        hurdlePrincipal = principal;
    }

    /// @notice Set the S2-H gold spread adapter address for combined cap tracking.
    /// @dev    Only used for cap calculation — does not screen the adapter.
    ///         Call setScreened(adapter, true) separately.
    function setGoldSpreadAdapter(address adapter) external onlyOwner {
        goldSpreadAdapter = adapter;
        emit GoldSpreadAdapterUpdated(adapter);
    }

    /// @notice Set the S6-H gold allocation adapter address for combined cap tracking.
    /// @dev    Only used for cap calculation — does not screen the adapter.
    ///         Call setScreened(adapter, true) separately.
    function setGoldAllocationAdapter(address adapter) external onlyOwner {
        goldAllocationAdapter = adapter;
        emit GoldAllocationAdapterUpdated(adapter);
    }

    /// @notice Set the PurificationEscrow address for v2 Musharakah profit distribution.
    /// @dev    Must be set before claimMusharakahProfit() can be called.
    ///         The escrow must be constructed with this vault's address, asset,
    ///         a CharityModule, and the shariahTreasury.
    function setPurificationEscrow(address escrow) external onlyOwner {
        purificationEscrow = PurificationEscrow(escrow);
        emit PurificationEscrowUpdated(escrow);
    }
}
