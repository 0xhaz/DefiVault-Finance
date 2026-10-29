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
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStrategyAdapter} from "./IStrategyAdapter.sol";

/// @dev Minimal interface to read currentValue() and isPriceSane() from a gold adapter.
interface IGoldAdapter {
    function currentValue() external view returns (uint256);
    function isPriceSane() external view returns (bool);
}

/// @dev Optional marker for strategies that require linked gold accounting.
interface IGoldMarker {
    function isGoldStrategy() external pure returns (bool);
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

    error ZeroAmount();
    error AdapterNotScreened();
    error ProfitExceedsRealized(uint256 requested, uint256 available);
    error AdapterExecutionReentered();
    error UseAtomicDeploy(address adapter);
    error RemoteRecipientNotApproved(uint32 domain, bytes32 recipient);
    error NoPendingRemoteRecipient();
    error RemoteRecipientProposalExists();
    error RemoteRecipientTimelockNotElapsed(uint256 earliest, uint256 current);
    error ZeroRecipient();
    error AssetNotPermitted(address asset_);
    /// @dev Gold strategies cannot use a nonzero destination domain: SR-005 governs
    ///      atomic gold settlement. SR-023's vault-wide transfer restriction is superseded.
    error NonAtomicGoldExchange();
    /// @dev Thrown when deploying to either gold adapter would push combined gold above MAX_GOLD_BPS.
    error GoldCapExceeded(uint256 combinedGoldValue, uint256 cap);
    error GoldAdapterHasExposure(address adapter, uint256 value);
    error RetiredGoldAdapter(address adapter);
    error UntrackedGoldAdapter(address adapter);

    error PurificationEscrowNotSet();
    error InsufficientFeeBalance(uint256 available, uint256 required);
    error NotBoardRole(address caller);
    error DustThresholdAboveCap(uint256 proposed, uint256 cap);
    error DustTimelockNotElapsed(uint256 earliest, uint256 current);
    error NoPendingDustProposal();
    error DustProposalAlreadyExists();

    event AdapterScreened(address indexed adapter, bool approved);
    event PermittedAssetUpdated(address indexed asset_, bool permitted);
    event WakalaFeeAccrued(uint256 amount);
    event WakalaAccrualSkipped(uint256 fee);
    event MusharakahProfitClaimed(uint256 grossProfit, uint256 purified, uint256 charity, uint256 vaultShare, uint256 depositorShare);
    event ShariahScreeningToggled(bool enabled);
    event GoldAllocationAdapterUpdated(address indexed adapter);
    event GoldSpreadAdapterUpdated(address indexed adapter);
    event PurificationEscrowUpdated(address indexed escrow);
    event DustThresholdUpdated(uint256 previous, uint256 updated);
    event DustThresholdProposed(uint256 newValue, uint256 executeAfter);
    event DustThresholdProposalCancelled();
    event RemoteRecipientProposed(uint32 indexed domain, bytes32 indexed recipient, bool approved, uint256 executeAfter);
    event RemoteRecipientProposalCancelled(uint32 indexed domain, bytes32 indexed recipient);
    event RemoteRecipientUpdated(uint32 indexed domain, bytes32 indexed recipient, bool approved);

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
    /// @dev Indices in ShariahScoreAggregator.ShariahStrategy; enum order must remain unchanged.
    uint8 public constant GOLD_SPREAD_IDX = 1;
    uint8 public constant GOLD_ALLOCATION_IDX = 5;

    /// @notice S2-H gold spread adapter (GoldExchangeAdapter — PAXG). Used for combined cap check.
    address public goldSpreadAdapter;

    /// @notice S6-H gold allocation adapter (GoldAllocationAdapter — XAUT). Used for combined cap check.
    address public goldAllocationAdapter;

    /// @notice Minimum adapter principal (USDC, 6 dec) that triggers a deposit pause when price is stale.
    ///         An adapter at or below effectiveDustThreshold() never blocks deposits even if stale.
    ///         Default 1e6 = 1 USDC. Changes require board approval and a 30-day delay.
    uint256 public dustThreshold = 1e6;
    uint256 public constant MAX_DUST_BPS = 50;
    uint256 public constant MIN_DUST_CAP = 1e6;
    uint256 public constant DUST_TIMELOCK = 30 days;

    struct PendingDustThreshold {
        uint256 newValue;
        uint256 executeAfter;
        bool exists;
    }
    PendingDustThreshold public pendingDustThreshold;

    uint256 public lastFeeAccrualTime;
    uint256 public hurdlePrincipal;
    uint256 public hurdleStartTime;
    /// @notice Highest processed realized assets per share, including locked depositor profit, scaled by 1e18.
    /// @dev Uses the same virtual assets/shares as ERC-4626; cash flows never reset it.
    uint256 public highWaterMarkPerShare;
    /// @notice Principal checkpoint in net asset units; deposits are not realized profit.
    uint256 public profitBase;
    bool private _adapterExecutionLocked;
    /// @notice Outstanding locally funded principal per adapter, independent of recall proceeds.
    mapping(address => uint256) public principalOf;

    event PrincipalRetired(address indexed adapter, uint256 retired, uint256 proceeds);

    uint256 public constant REMOTE_RECIPIENT_TIMELOCK = 30 days;
    struct PendingRemoteRecipient {
        bool approved;
        uint256 executeAfter;
        bool exists;
    }
    mapping(uint32 => mapping(bytes32 => bool)) public approvedRemoteRecipient;
    mapping(uint32 => mapping(bytes32 => PendingRemoteRecipient)) public pendingRemoteRecipient;
    /// @notice Previously tracked gold adapters cannot receive capital until explicitly linked again.
    mapping(address => bool) public retiredGoldAdapter;

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
        highWaterMarkPerShare = 1e18 / (10 ** _decimalsOffset());
        permittedAssets[address(asset_)] = true;
    }

    function name() public pure virtual override(ERC20, IERC20Metadata) returns (string memory) {
        return "Shariah Vault Share";
    }

    /// @dev Mark gold in both directions before deducting locked profit and fees.
    function _navBeforeUnbookedFee() internal view returns (uint256) {
        uint256 assets = IERC20(asset()).balanceOf(address(this)) + totalDeployed;
        uint256 writedown = goldWritedown();
        assets = assets > writedown ? assets - writedown : 0;
        assets += goldUnrealizedGain();
        uint256 locked = _currentLockedProfit();
        assets = assets > locked ? assets - locked : 0;
        uint256 fees = shariahTreasury.pendingFees();
        return assets > fees ? assets - fees : 0;
    }

    /// @dev Independent realized AUM base: never calls totalAssets or pendingWakalaFee.
    function _navExGainBeforeUnbookedFee() internal view returns (uint256) {
        uint256 assets = IERC20(asset()).balanceOf(address(this)) + totalDeployed;
        uint256 writedown = goldWritedown();
        assets = assets > writedown ? assets - writedown : 0;
        uint256 locked = _currentLockedProfit();
        assets = assets > locked ? assets - locked : 0;
        uint256 fees = shariahTreasury.pendingFees();
        return assets > fees ? assets - fees : 0;
    }

    /// @notice Unbooked time-based fee on realized AUM, already reflected in share pricing.
    function pendingWakalaFee() public view returns (uint256) {
        return Math.mulDiv(
            _navExGainBeforeUnbookedFee(),
            shariahTreasury.adminFeeBps() * (block.timestamp - lastFeeAccrualTime),
            10_000 * 365 days
        );
    }

    function totalAssets() public view virtual override returns (uint256) {
        uint256 assets = _navBeforeUnbookedFee();
        uint256 fee = pendingWakalaFee();
        return assets > fee ? assets - fee : 0;
    }

    /// @notice Aggregate loss below principal for the tracked gold adapters.
    function goldWritedown() public view returns (uint256 writedown) {
        return ShariahAccountingLogic.goldWritedown(principalOf, goldSpreadAdapter, goldAllocationAdapter);
    }

    /// @notice Aggregate appreciation above principal for the tracked gold adapters.
    function goldUnrealizedGain() public view returns (uint256 gain) {
        return ShariahAccountingLogic.goldUnrealizedGain(principalOf, goldSpreadAdapter, goldAllocationAdapter);
    }

    /// @dev Saturate when liabilities consume NAV including some unrealized appreciation.
    function _assetsExcludingGoldGain() internal view returns (uint256) {
        uint256 assets = totalAssets();
        uint256 gain = goldUnrealizedGain();
        return assets > gain ? assets - gain : 0;
    }

    /// @dev Price uses one virtual asset and 10**offset virtual shares, like ERC-4626.
    function _realizedPricePerShare(uint256 realizedNav) internal view returns (uint256) {
        return Math.mulDiv(realizedNav + 1, 1e18, totalSupply() + 10 ** _decimalsOffset());
    }

    /// @dev Exclude unprocessed yield, but retain processed depositor profit throughout unlock.
    ///      The checkpoint cap prevents gross tokens already in NAV from advancing the high.
    function _processedNav() internal view returns (uint256) {
        return Math.min(_assetsExcludingGoldGain() + _currentLockedProfit(), profitBase);
    }

    /// @notice Asset equivalent of the processed per-share high at the current virtual supply.
    function highWaterMark() public view returns (uint256) {
        uint256 assets = Math.mulDiv(
            highWaterMarkPerShare, totalSupply() + 10 ** _decimalsOffset(), 1e18
        );
        return assets > 0 ? assets - 1 : 0;
    }

    function _hwmDeficit(uint256 realizedNav) internal view returns (uint256) {
        uint256 price = _realizedPricePerShare(realizedNav);
        if (price >= highWaterMarkPerShare) return 0;
        return Math.mulDiv(
            highWaterMarkPerShare - price, totalSupply() + 10 ** _decimalsOffset(), 1e18
        );
    }

    /// @notice Live unrecovered loss on the processed basis, including locked profit, excluding paper appreciation.
    function hwmDeficit() public view returns (uint256) {
        return _hwmDeficit(_processedNav());
    }

    /// @notice Net realized assets above the checkpoint; gold appreciation is never distributable.
    function realizedProfit() public view returns (uint256) {
        uint256 assetsNow = _assetsExcludingGoldGain();
        return assetsNow > profitBase ? assetsNow - profitBase : 0;
    }

    function lockProfit(uint256 amount) external virtual onlyManagerOrOwner {
        if (amount == 0) revert ZeroAmount();
        uint256 available = realizedProfit();
        if (amount > available) revert ProfitExceedsRealized(amount, available);
        _lockProfitInternal(amount);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
        _tryAccrueWakalaFee();
        profitBase += assets;
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
        _tryAccrueWakalaFee();
        // Reduce the checkpoint by the share of supply being burned, not by assets over
        // totalAssets(): totalAssets() excludes locked profit and pending fees, while profitBase
        // includes the locked depositor share, so an assets-based ratio would under-reduce it and
        // make already-distributed profit claimable again after it unlocks.
        uint256 supplyBefore = totalSupply();
        if (supplyBefore != 0) {
            uint256 reduction = shares >= supplyBefore
                ? profitBase : Math.mulDiv(profitBase, shares, supplyBefore);
            profitBase = reduction >= profitBase ? 0 : profitBase - reduction;
        }
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    function symbol() public pure virtual override(ERC20, IERC20Metadata) returns (string memory) {
        return "svUSDC";
    }

    /// @notice Override deployCapital to enforce Shariah screening and accrue Wakala fee.
    /// @dev Transfer-only compatibility path for non-gold strategies; configured gold requires atomic execution.
    function deployCapital(address strategy, uint256 amount, bytes calldata data)
        external
        virtual
        override
        onlyManagerOrOwner
    {
        if (strategy != address(0) && (strategy == goldSpreadAdapter || strategy == goldAllocationAdapter)) {
            revert UseAtomicDeploy(strategy);
        }
        _deployCapital(strategy, amount, data);
        principalOf[strategy] += amount;
        _accrueWakalaFee();
    }

    /// @notice Transfer capital and execute the adapter atomically with this vault as caller.
    function deployCapitalAndExecute(address strategy, uint256 amount, bytes calldata data)
        external
        virtual
        onlyManagerOrOwner
    {
        if (_adapterExecutionLocked) revert AdapterExecutionReentered();
        _deployCapital(strategy, amount, data);
        _adapterExecutionLocked = true;
        IStrategyAdapter(strategy).deploy(amount);
        // Book principal and accrue against completed adapter state, never a half-funded gold position.
        principalOf[strategy] += amount;
        _accrueWakalaFee();
        _adapterExecutionLocked = false;
    }

    /// @notice Return transferred capital while retiring the corresponding strategy principal.
    function returnCapital(address strategy, uint256 amount) external virtual override onlyManagerOrOwner {
        if (paused) revert Paused();
        IERC20(asset()).safeTransferFrom(strategy, address(this), amount);
        uint256 retired = Math.min(amount, principalOf[strategy]);
        principalOf[strategy] -= retired;
        totalDeployed -= Math.min(retired, totalDeployed);
        emit CapitalReturned(strategy, amount);
        emit PrincipalRetired(strategy, retired, amount);
    }

    /// @notice Recognize a total adapter loss before replacing or unlinking its address.
    /// @dev Only a zero-valued position can be written off; principal and deployed cost retire atomically.
    function writeOffAdapterPrincipal(address adapter) external onlyOwner {
        uint256 value = IStrategyAdapter(adapter).currentValue();
        if (value != 0) revert GoldAdapterHasExposure(adapter, value);
        uint256 retired = principalOf[adapter];
        principalOf[adapter] = 0;
        totalDeployed = totalDeployed >= retired ? totalDeployed - retired : 0;
        emit PrincipalRetired(adapter, retired, 0);
    }

    /// @notice Retire requested principal (all remaining principal on full exit), not recall proceeds.
    function recallCapital(address adapter, uint256 amount) external virtual override onlyManagerOrOwner {
        if (paused) revert Paused();
        (uint256 actualReturn, uint256 retired) = ShariahAccountingLogic.recall(
            principalOf, asset(), adapter, amount
        );
        totalDeployed = totalDeployed >= retired ? totalDeployed - retired : 0;

        emit CapitalRecalledFromAdapter(adapter, amount, actualReturn);
        emit PrincipalRetired(adapter, retired, actualReturn);
    }

    /// @dev Screening hook includes pause/asset checks to preserve each version's revert ordering.
    function _checkDeploymentScreening(address strategy) internal view virtual {
        if (paused) revert Paused();
        if (!permittedAssets[asset()]) revert AssetNotPermitted(asset());
        if (shariahScreeningEnabled && !screened[strategy]) revert AdapterNotScreened();
    }

    function _deployCapital(address strategy, uint256 amount, bytes calldata data) internal {
        if (retiredGoldAdapter[strategy]) revert RetiredGoldAdapter(strategy);
        _checkDeploymentScreening(strategy);
        ShariahAccountingLogic.checkGoldMarker(strategy, goldSpreadAdapter, goldAllocationAdapter);
        data;

        uint256 currentAssets = totalAssets();
        uint256 maxDeployable = (currentAssets * maxAllocationBps) / 10_000;
        if (totalDeployed + amount > maxDeployable) revert AllocationExceedsLimit();

        // Combined gold cap: S2-H (PAXG) + S6-H (XAUT) must not exceed MAX_GOLD_BPS of totalAssets.
        // Check only when deploying to either gold adapter.
        ShariahAccountingLogic.checkGoldCap(
            strategy, goldSpreadAdapter, goldAllocationAdapter, amount, currentAssets
        );

        IERC20(asset()).safeTransfer(strategy, amount);
        totalDeployed += amount;

        emit CapitalDeployed(strategy, amount);
    }

    /// @notice Strategy-tagged cross-chain transfer. A gold strategy (S2-H, S6-H) is never routed
    ///         cross-chain: this entry point always moves USDC over CCTP, and domain 0 is a real
    ///         CCTP domain (Ethereum), not "local". Gold strategies that execute locally go
    ///         through deployCapital / the executor instead.
    function deployCrossChainForStrategy(
        uint8 shariahStrategyIdx,
        uint32 destinationDomain,
        bytes32 recipient,
        uint256 amount
    ) external onlyManagerOrOwner {
        if (shariahStrategyIdx == GOLD_SPREAD_IDX || shariahStrategyIdx == GOLD_ALLOCATION_IDX) {
            revert NonAtomicGoldExchange();
        }
        deployCrossChain(destinationDomain, recipient, amount);
    }

    function deployCrossChain(uint32 destinationDomain, bytes32 recipient, uint256 amount)
        public virtual override onlyManagerOrOwner
    {
        if (!permittedAssets[asset()]) revert AssetNotPermitted(asset());
        if (!approvedRemoteRecipient[destinationDomain][recipient]) {
            revert RemoteRecipientNotApproved(destinationDomain, recipient);
        }
        super.deployCrossChain(destinationDomain, recipient, amount);
    }

    /// @notice Board proposes an approval or revocation; both require the full delay.
    function proposeRemoteRecipient(uint32 domain, bytes32 recipient, bool approved) external onlyBoard {
        ShariahGovernanceLogic.proposeRemoteRecipient(pendingRemoteRecipient, domain, recipient, approved);
    }

    function confirmRemoteRecipient(uint32 domain, bytes32 recipient) external onlyBoard {
        ShariahGovernanceLogic.confirmRemoteRecipient(
            pendingRemoteRecipient, approvedRemoteRecipient, domain, recipient
        );
    }

    function cancelRemoteRecipient(uint32 domain, bytes32 recipient) external onlyBoard {
        ShariahGovernanceLogic.cancelRemoteRecipient(pendingRemoteRecipient, domain, recipient);
    }

    function _accrueWakalaFee() internal {
        uint256 fee = pendingWakalaFee();
        if (fee > 0) {
            shariahTreasury.accrue(fee);
        } else if (_feeCanAccrue()) {
            // A fee that rounds to zero keeps its elapsed time so frequent zero-value calls cannot erase accrual.
            return;
        }
        lastFeeAccrualTime = block.timestamp;
        emit WakalaFeeAccrued(fee);
    }

    /// @dev True when a fee is configured and there is AUM, i.e. elapsed time is worth preserving.
    function _feeCanAccrue() internal view returns (bool) {
        return shariahTreasury.adminFeeBps() > 0 && _navExGainBeforeUnbookedFee() > 0;
    }

    /// @dev Booking replaces an equal view deduction; failed booking cannot gate user exits.
    function _tryAccrueWakalaFee() internal {
        uint256 fee = pendingWakalaFee();
        if (fee == 0) {
            if (_feeCanAccrue()) return; // keep elapsed time so rounding to zero never discards accrual
            lastFeeAccrualTime = block.timestamp;
            emit WakalaFeeAccrued(0);
            return;
        }
        try shariahTreasury.accrue(fee) {
            lastFeeAccrualTime = block.timestamp;
            emit WakalaFeeAccrued(fee);
        } catch {
            emit WakalaAccrualSkipped(fee);
        }
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
        _tryAccrueWakalaFee();
        uint256 available = realizedProfit();
        if (grossProfit > available) revert ProfitExceedsRealized(grossProfit, available);

        // Approve escrow to pull the gross profit from vault.
        IERC20(asset()).forceApprove(address(purificationEscrow), grossProfit);

        // Gross tokens are already in NAV: cap at the pre-claim checkpoint, rather than
        // subtracting this claim (which would leave any unprocessed remainder in the price).
        uint256 deficit = _hwmDeficit(_processedNav());

        (uint256 purified, uint256 charity, uint256 vaultShare, uint256 depositorShare) =
            purificationEscrow.executeWaterfallHWM(
                grossProfit,
                block.timestamp - hurdleStartTime,
                hurdlePrincipal,
                deficit
            );

        // Clear any leftover allowance (defensive).
        IERC20(asset()).forceApprove(address(purificationEscrow), 0);

        // N-11 / N-24 / N-19: the depositor share is NOT locked. The gross profit was already in
        // NAV before this claim, so returning the depositor share changes nothing about the share
        // price, and hiding it for an unlock period would only discount entrants (N-11), dilute the
        // processed per-share value (N-24) and strand tokens after the last redemption (N-19).
        // Manager-called lockProfit remains available for streaming genuinely new yield.

        // Realized checkpoints must not absorb appreciation before a later recall realizes it.
        hurdlePrincipal = _assetsExcludingGoldGain();
        // Advance only by profit already distributed to depositors, not unprocessed yield, so the
        // depositor share cannot be claimed as profit a second time.
        profitBase += depositorShare;
        hurdleStartTime = block.timestamp;
        // Record the earned depositor peak, never the unprocessed remainder.
        uint256 postClaimPrice = _realizedPricePerShare(_processedNav());
        if (postClaimPrice > highWaterMarkPerShare) highWaterMarkPerShare = postClaimPrice;

        emit MusharakahProfitClaimed(grossProfit, purified, charity, vaultShare, depositorShare);
    }

    /// @notice Sweep accrued fees to a receiver. Amount is capped to `pendingFees` to
    ///         prevent owner from sweeping depositor principal under the guise of fee claims.
    function sweepFeesToTreasury(address receiver, uint256 amount) external onlyOwner {
        uint256 pending = shariahTreasury.pendingFees();
        if (amount > pending) revert AllocationExceedsLimit(); // reuse error: amount > accrued
        uint256 available = IERC20(asset()).balanceOf(address(this));
        if (available < amount) revert InsufficientFeeBalance(available, amount);
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

    /// @notice Board-set threshold clamped to the current asset-based cap at enforcement time.
    function effectiveDustThreshold() public view returns (uint256) {
        uint256 cap = (totalAssets() * MAX_DUST_BPS) / 10_000;
        if (cap < MIN_DUST_CAP) cap = MIN_DUST_CAP;
        return dustThreshold < cap ? dustThreshold : cap;
    }

    /// @dev Returns true when at least one gold adapter is set, reports price insanity,
    ///      AND has more than effectiveDustThreshold() USDC of outstanding principal.
    ///      An adapter with no material position (e.g. S6-H disabled, S2-H idle) never
    ///      blocks deposits even if its oracle or last-swap timestamp is stale (J2).
    function _goldPriceInsane() internal view returns (bool) {
        if (goldAllocationAdapter != address(0)) {
            IGoldAdapter adp = IGoldAdapter(goldAllocationAdapter);
            if (!adp.isPriceSane() && principalOf[address(adp)] > effectiveDustThreshold()) return true;
        }
        if (goldSpreadAdapter != address(0)) {
            IGoldAdapter adp = IGoldAdapter(goldSpreadAdapter);
            if (!adp.isPriceSane() && principalOf[address(adp)] > effectiveDustThreshold()) return true;
        }
        return false;
    }

    modifier onlyBoard() {
        if (!_isBoard(msg.sender)) revert NotBoardRole(msg.sender);
        _;
    }

    /// @dev V1 has no registry; V2 resolves membership through its registry.
    function _isBoard(address account) internal view virtual returns (bool) {
        return account == owner();
    }

    function _checkDustCap(uint256 proposed) internal view {
        uint256 cap = (totalAssets() * MAX_DUST_BPS) / 10_000;
        if (cap < MIN_DUST_CAP) cap = MIN_DUST_CAP;
        if (proposed > cap) revert DustThresholdAboveCap(proposed, cap);
    }

    /// @notice Board proposes a capped threshold with a 30-day delay.
    function proposeDustThreshold(uint256 newValue) external onlyBoard {
        _checkDustCap(newValue);
        ShariahGovernanceLogic.proposeDustThreshold(pendingDustThreshold, newValue);
    }

    /// @notice Board confirms after the delay, subject to the current asset-based cap.
    function confirmDustThreshold() external onlyBoard {
        PendingDustThreshold memory p = pendingDustThreshold;
        ShariahGovernanceLogic.checkDustConfirmation(pendingDustThreshold);
        _checkDustCap(p.newValue);
        delete pendingDustThreshold;
        uint256 previous = dustThreshold;
        dustThreshold = p.newValue;
        emit DustThresholdUpdated(previous, p.newValue);
    }

    /// @notice Board cancels a pending threshold proposal.
    function cancelDustThreshold() external onlyBoard {
        ShariahGovernanceLogic.cancelDustThreshold(pendingDustThreshold);
    }

    function setHurdlePrincipal(uint256 principal) external onlyOwner {
        hurdlePrincipal = principal;
    }

    /// @notice Set the S2-H gold spread adapter address for combined cap tracking.
    /// @dev    Only used for cap calculation — does not screen the adapter.
    ///         Call setScreened(adapter, true) separately.
    function setGoldSpreadAdapter(address adapter) external onlyOwner {
        ShariahAccountingLogic.replaceGoldAdapter(principalOf, retiredGoldAdapter, goldSpreadAdapter, adapter);
        goldSpreadAdapter = adapter;
        if (adapter != address(0)) retiredGoldAdapter[adapter] = false;
        emit GoldSpreadAdapterUpdated(adapter);
    }

    /// @notice Set the S6-H gold allocation adapter address for combined cap tracking.
    /// @dev    Only used for cap calculation — does not screen the adapter.
    ///         Call setScreened(adapter, true) separately.
    function setGoldAllocationAdapter(address adapter) external onlyOwner {
        ShariahAccountingLogic.replaceGoldAdapter(principalOf, retiredGoldAdapter, goldAllocationAdapter, adapter);
        goldAllocationAdapter = adapter;
        if (adapter != address(0)) retiredGoldAdapter[adapter] = false;
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

/// @dev Linked timelock operations. Authorization and NAV-dependent cap checks stay in the vault.
library ShariahGovernanceLogic {
    function proposeRemoteRecipient(
        mapping(uint32 => mapping(bytes32 => ShariahVault.PendingRemoteRecipient)) storage pending,
        uint32 domain, bytes32 recipient, bool approved
    ) external {
        if (recipient == bytes32(0)) revert ShariahVault.ZeroRecipient();
        if (pending[domain][recipient].exists) revert ShariahVault.RemoteRecipientProposalExists();
        uint256 executeAfter = block.timestamp + 30 days;
        pending[domain][recipient] = ShariahVault.PendingRemoteRecipient(approved, executeAfter, true);
        emit ShariahVault.RemoteRecipientProposed(domain, recipient, approved, executeAfter);
    }

    function confirmRemoteRecipient(
        mapping(uint32 => mapping(bytes32 => ShariahVault.PendingRemoteRecipient)) storage pending,
        mapping(uint32 => mapping(bytes32 => bool)) storage approved,
        uint32 domain, bytes32 recipient
    ) external {
        ShariahVault.PendingRemoteRecipient memory p = pending[domain][recipient];
        if (!p.exists) revert ShariahVault.NoPendingRemoteRecipient();
        if (block.timestamp < p.executeAfter) {
            revert ShariahVault.RemoteRecipientTimelockNotElapsed(p.executeAfter, block.timestamp);
        }
        delete pending[domain][recipient];
        approved[domain][recipient] = p.approved;
        emit ShariahVault.RemoteRecipientUpdated(domain, recipient, p.approved);
    }

    function cancelRemoteRecipient(
        mapping(uint32 => mapping(bytes32 => ShariahVault.PendingRemoteRecipient)) storage pending,
        uint32 domain, bytes32 recipient
    ) external {
        if (!pending[domain][recipient].exists) revert ShariahVault.NoPendingRemoteRecipient();
        delete pending[domain][recipient];
        emit ShariahVault.RemoteRecipientProposalCancelled(domain, recipient);
    }

    function proposeDustThreshold(ShariahVault.PendingDustThreshold storage pending, uint256 newValue) external {
        if (pending.exists) revert ShariahVault.DustProposalAlreadyExists();
        uint256 executeAfter = block.timestamp + 30 days;
        pending.newValue = newValue;
        pending.executeAfter = executeAfter;
        pending.exists = true;
        emit ShariahVault.DustThresholdProposed(newValue, executeAfter);
    }

    function checkDustConfirmation(ShariahVault.PendingDustThreshold storage pending) external view {
        if (!pending.exists) revert ShariahVault.NoPendingDustProposal();
        if (block.timestamp < pending.executeAfter) {
            revert ShariahVault.DustTimelockNotElapsed(pending.executeAfter, block.timestamp);
        }
    }

    function cancelDustThreshold(ShariahVault.PendingDustThreshold storage pending) external {
        if (!pending.exists) revert ShariahVault.NoPendingDustProposal();
        delete pending.newValue;
        delete pending.executeAfter;
        delete pending.exists;
        emit ShariahVault.DustThresholdProposalCancelled();
    }
}

/// @dev Linked gold valuation; each read and saturating subtraction follows the vault's original order.
library ShariahAccountingLogic {
    function recall(
        mapping(address => uint256) storage principalOf, address token, address adapter, uint256 amount
    ) external returns (uint256 actualReturn, uint256 retired) {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        uint256 returned = IStrategyAdapter(adapter).recall(amount);
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        actualReturn = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : returned;
        bool closed = IStrategyAdapter(adapter).currentValue() == 0;
        uint256 principal = principalOf[adapter];
        retired = closed ? principal : Math.min(amount, principal);
        principalOf[adapter] = principal - retired;
    }

    function replaceGoldAdapter(
        mapping(address => uint256) storage principalOf,
        mapping(address => bool) storage retired, address previous, address replacement
    ) external {
        if (previous != address(0)) {
            uint256 value = IGoldAdapter(previous).currentValue();
            if (value > 0) revert ShariahVault.GoldAdapterHasExposure(previous, value);
            uint256 principal = principalOf[previous];
            if (principal > 0) revert ShariahVault.GoldAdapterHasExposure(previous, principal);
        }
        if (previous != address(0) && previous != replacement) retired[previous] = true;
    }

    function checkGoldMarker(address strategy, address spread, address allocation) external view {
        if (strategy.code.length != 0) {
            try IGoldMarker(strategy).isGoldStrategy() returns (bool g) {
                if (g && strategy != spread && strategy != allocation) {
                    revert ShariahVault.UntrackedGoldAdapter(strategy);
                }
            } catch {
                // Missing/reverting markers retain the non-gold compatibility path.
            }
        }
    }

    function checkGoldCap(
        address strategy, address spread, address allocation, uint256 amount, uint256 currentAssets
    ) external view {
        if (strategy == spread || strategy == allocation) {
            uint256 paxgValue = spread != address(0) ? IGoldAdapter(spread).currentValue() : 0;
            uint256 xautValue = allocation != address(0) && allocation != spread
                ? IGoldAdapter(allocation).currentValue() : 0;
            uint256 combined = paxgValue + xautValue + amount;
            uint256 goldCap = (currentAssets * 3000) / 10_000;
            if (combined > goldCap) revert ShariahVault.GoldCapExceeded(combined, goldCap);
        }
    }

    function goldWritedown(
        mapping(address => uint256) storage principalOf, address spread, address allocation
    ) external view returns (uint256 writedown) {
        if (spread != address(0)) {
            uint256 value = IGoldAdapter(spread).currentValue();
            uint256 principal = principalOf[spread];
            if (principal > value) writedown = principal - value;
        }
        if (allocation != address(0) && allocation != spread) {
            uint256 value = IGoldAdapter(allocation).currentValue();
            uint256 principal = principalOf[allocation];
            if (principal > value) writedown += principal - value;
        }
    }

    function goldUnrealizedGain(
        mapping(address => uint256) storage principalOf, address spread, address allocation
    ) external view returns (uint256 gain) {
        if (spread != address(0)) {
            uint256 value = IGoldAdapter(spread).currentValue();
            uint256 principal = principalOf[spread];
            if (value > principal) gain = value - principal;
        }
        if (allocation != address(0) && allocation != spread) {
            uint256 value = IGoldAdapter(allocation).currentValue();
            uint256 principal = principalOf[allocation];
            if (value > principal) gain += value - principal;
        }
    }
}
