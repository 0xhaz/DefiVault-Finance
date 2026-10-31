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
    /// @notice An exit with realized profit needs at least 2 * (EXIT_SETTLE_GAS + funded adapters *
    ///         EXIT_SETTLE_GAS_PER_ADAPTER) of gas so the leaver's distribution cut is settled
    ///         rather than silently skipped.
    error InsufficientExitGas();
    uint256 internal constant EXIT_SETTLE_GAS = 700_000;
    /// @dev N-33: settlement re-reads each funded adapter 8 times; 8 x ADAPTER_READ_GAS (150k) plus margin.
    uint256 internal constant EXIT_SETTLE_GAS_PER_ADAPTER = 1_300_000;
    error UseAtomicDeploy(address adapter);
    /// @notice N-35: returnCapital only pulls from an adapter that holds booked principal.
    error AdapterNotFunded(address adapter);
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
    error TooManyFundedAdapters();
    error HurdlePrincipalCannotDecrease();
    error InvalidGoldSaleFraction();

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

    /// @notice Maximum gas forwarded to each adapter currentValue() read.
    uint256 public constant ADAPTER_READ_GAS = ShariahAccountingLogic.ADAPTER_READ_GAS;
    /// @notice Maximum number of funded non-gold adapters.
    uint256 public constant MAX_FUNDED_ADAPTERS = ShariahAccountingLogic.MAX_FUNDED_ADAPTERS;

    /// @notice Non-gold adapters with outstanding principal; order changes on removal.
    address[] public fundedAdapters;
    /// @dev One-based index, zero when absent. Membership is maintained by the linked library.
    mapping(address => uint256) private _fundedAdapterIndex;
    /// @dev Held across fee booking, profit settlement and the final exit transfer.
    bool private _profitDistributionLocked;
    /// @dev Exact ERC-4626 quote protected by the revertible exit settlement.
    uint256 private _exitAssets;
    /// @dev Departing shares, captured before burn; zero for ordinary manager claims.
    uint256 private _exitShares;
    /// @dev Written inside the revertible self-call; a failed settlement rolls it back.
    bool private _exitSettlementRan;

    function fundedAdapterCount() external view returns (uint256) {
        return fundedAdapters.length;
    }

    /// @notice Downward-only non-gold valuation; failed or malformed reads are unmarked.
    function unrealizedAdapterLoss() public view returns (uint256) {
        return ShariahAccountingLogic.unrealizedAdapterLoss(fundedAdapters, principalOf);
    }

    /// @notice Entry is healthy only when every tracked valuation is readable and non-gold loss is within dust.
    /// @dev Failed reads remain unmarked in NAV and never gate withdrawals or redemptions.
    function valuationHealthy() public view returns (bool) {
        return ShariahAccountingLogic.valuationHealthy(
            fundedAdapters, principalOf, goldSpreadAdapter, goldAllocationAdapter
        );
    }

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

    /// @dev Shared loss basis for share pricing and realized AUM; never calls totalAssets.
    function _navBeforeFee(bool includeGoldGain) internal view returns (uint256) {
        return ShariahAccountingLogic.navBeforeFee(
            fundedAdapters, principalOf, asset(), totalDeployed,
            goldSpreadAdapter, goldAllocationAdapter, _currentLockedProfit(),
            shariahTreasury, includeGoldGain
        );
    }

    function _navBeforeUnbookedFee() internal view returns (uint256) {
        return _navBeforeFee(true);
    }

    /// @dev Independent realized AUM base: never calls totalAssets or pendingWakalaFee.
    function _navExGainBeforeUnbookedFee() internal view returns (uint256) {
        return _navBeforeFee(false);
    }

    /// @notice Unbooked time-based fee on realized AUM, already reflected in share pricing.
    function pendingWakalaFee() public view returns (uint256) {
        return Math.mulDiv(
            _navExGainBeforeUnbookedFee(),
            shariahTreasury.adminFeeBps() * (block.timestamp - lastFeeAccrualTime),
            10_000 * 365 days
        );
    }

    /// @dev Preserve the accounting NAV independently of the pricing-only distribution reserve.
    function _totalAssetsBeforeDistributionCut() internal view returns (uint256) {
        uint256 assets = _navBeforeUnbookedFee();
        uint256 fee = pendingWakalaFee();
        return assets > fee ? assets - fee : 0;
    }

    /// @notice Pre-cut accounting NAV, also used by the linked hurdle-carry logic.
    function totalAssetsBeforeDistributionCut() external view returns (uint256) {
        return _totalAssetsBeforeDistributionCut();
    }

    /// @notice Unbooked purification, charity and manager share on all current realized profit.
    /// @dev Failed escrow previews reserve nothing and never gate exits.
    function pendingDistributionCut() public view returns (uint256) {
        return ShariahAccountingLogic.pendingDistributionCut(
            purificationEscrow, hurdleStartTime, hurdlePrincipal
        );
    }

    function totalAssets() public view virtual override returns (uint256) {
        uint256 assets = _totalAssetsBeforeDistributionCut();
        uint256 cut = pendingDistributionCut();
        return assets > cut ? assets - cut : 0;
    }

    /// @notice Aggregate loss below principal for the tracked gold adapters.
    /// @dev Unreadable valuations contribute zero writedown; entry is blocked via valuationHealthy().
    function goldWritedown() public view returns (uint256 writedown) {
        return ShariahAccountingLogic.goldWritedown(principalOf, goldSpreadAdapter, goldAllocationAdapter);
    }

    /// @notice Aggregate appreciation above principal for the tracked gold adapters.
    function goldUnrealizedGain() public view returns (uint256 gain) {
        return ShariahAccountingLogic.goldUnrealizedGain(principalOf, goldSpreadAdapter, goldAllocationAdapter);
    }

    /// @dev Saturate when liabilities consume NAV including some unrealized appreciation.
    function _assetsExcludingGoldGain() internal view returns (uint256) {
        uint256 assets = _totalAssetsBeforeDistributionCut();
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
        if (_profitDistributionLocked) revert AdapterExecutionReentered();
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
        if (_profitDistributionLocked) revert AdapterExecutionReentered();
        _tryAccrueWakalaFee();
        // Hurdle basis follows cash flows: new capital accrues hurdle from now, accrued allowance is kept.
        (hurdleStartTime, hurdlePrincipal) = ShariahAccountingLogic.depositHurdle(
            hurdleStartTime, hurdlePrincipal, totalSupply(), _assetsExcludingGoldGain(), assets
        );
        // Known limitation (N-32): with a large unprocessed profit AND an open HWM deficit, a
        // deposit books its buy-in to that profit as processed capital and can shrink the deficit.
        // Crediting less was tried and charges the newcomer twice (late depositors lost ~3 bps).
        profitBase += assets;
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
        if (_profitDistributionLocked) revert AdapterExecutionReentered();
        _profitDistributionLocked = true;
        _tryAccrueWakalaFee();
        uint256 supplyBefore = totalSupply();
        if (supplyBefore != 0) {
            if (address(purificationEscrow) != address(0) && shares != 0) {
                uint256 grossProfit = Math.mulDiv(realizedProfit(), shares, supplyBefore);
                if (grossProfit != 0) {
                    _exitAssets = assets;
                    _exitShares = shares;
                    // Revert the whole distribution (including approvals and fee booking) on
                    // failure, but never make a failing waterfall a new exit gate.
                    // Retain gas for checkpoint retirement, share burn and payout even if
                    // a distribution callee consumes every unit forwarded to settlement.
                    // eth_estimateGas bisects for the lowest limit at which the transaction does not
                    // revert; because a failed settlement is swallowed, wallets would otherwise pick
                    // a limit that starves the settlement and silently skip the leaver's cut.
                    // Requiring twice the settlement budget up front makes that limit unreachable.
                    // The budget grows with the number of funded adapters because settlement re-reads
                    // each adapter's value several times.
                    if (gasleft() < 2 * (EXIT_SETTLE_GAS + fundedAdapters.length * EXIT_SETTLE_GAS_PER_ADAPTER)) {
                        revert InsufficientExitGas();
                    }
                    try this.exitSettle{gas: gasleft() / 2}(grossProfit) {} catch {}
                    delete _exitAssets;
                    delete _exitShares;
                }
            }
            // Failed/absent settlement must still retire the departed capital's hurdle.
            // Preserve its clock so the accrued allowance scales with remaining shares.
            if (shares >= supplyBefore) hurdlePrincipal = 0;
            else if (!_exitSettlementRan) {
                hurdlePrincipal = Math.mulDiv(hurdlePrincipal, supplyBefore - shares, supplyBefore);
            }
            delete _exitSettlementRan;
            // Exit settlement first checkpoints, then retires its depositor share in full:
            // that processed profit belongs to the exiting shares, not the remaining holders.
            // The pre-existing checkpoint still retires pro rata by shares, including locks.
            uint256 reduction = shares >= supplyBefore
                ? profitBase : Math.mulDiv(profitBase, shares, supplyBefore);
            profitBase = reduction >= profitBase ? 0 : profitBase - reduction;
        }
        super._withdraw(caller, receiver, owner_, assets, shares);
        _profitDistributionLocked = false;
    }

    /// @notice Revertible exit-only profit distribution; never callable by a third party.
    /// @dev The outer withdrawal holds the lock until after the burn and asset transfer.
    function exitSettle(uint256 grossProfit) external {
        if (msg.sender != address(this) || !_profitDistributionLocked) revert NotManager();
        uint256 previousHigh = highWaterMarkPerShare;
        uint256 depositorShare = _claimMusharakahProfit(grossProfit);
        _exitSettlementRan = true;
        // Retiring only a pro-rata fraction of this share would process profit belonging to
        // the stayers and release part of their pending cut. All of it exits in the quoted payout.
        profitBase -= depositorShare;
        // The processed peak earned solely by departing shares must retire with them too;
        // otherwise the stayers acquire an artificial recovery deficit and dodge manager fees.
        highWaterMarkPerShare = previousHigh;
        ShariahAccountingLogic.checkExitLiquidity(asset(), _exitAssets);
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
        _bookAdapterPrincipal(strategy, amount);
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
        _bookAdapterPrincipal(strategy, amount);
        _accrueWakalaFee();
        _adapterExecutionLocked = false;
    }

    function _bookAdapterPrincipal(address strategy, uint256 amount) internal {
        ShariahAccountingLogic.bookPrincipal(
            fundedAdapters, _fundedAdapterIndex, principalOf,
            strategy, amount, goldSpreadAdapter, goldAllocationAdapter
        );
    }

    /// @notice Return transferred capital while retiring the corresponding strategy principal.
    function returnCapital(address strategy, uint256 amount) external virtual override onlyManagerOrOwner {
        // Recovery is never gated by pause: pausing stops deployment and deposits, not exits.
        uint256 retired = ShariahAccountingLogic.returnCapital(
            fundedAdapters, _fundedAdapterIndex, principalOf, asset(), strategy, amount
        );
        totalDeployed -= Math.min(retired, totalDeployed);
    }

    /// @notice Retire gold cost basis after an adapter-side sale, never by sale proceeds.
    function retireGoldPrincipal(uint256 soldTokens, uint256 heldBefore) external {
        if (msg.sender != goldSpreadAdapter && msg.sender != goldAllocationAdapter) revert NotManager();
        totalDeployed = ShariahAccountingLogic.retireGoldPrincipal(
            principalOf, msg.sender, soldTokens, heldBefore, totalDeployed
        );
    }

    /// @notice Recognize a total adapter loss before replacing or unlinking its address.
    /// @dev A zero or unreadable position can be explicitly written off by the owner; principal and deployed cost retire atomically.
    function writeOffAdapterPrincipal(address adapter) external onlyOwner {
        uint256 retired = ShariahAccountingLogic.writeOff(
            fundedAdapters, _fundedAdapterIndex, principalOf, adapter
        );
        totalDeployed = totalDeployed >= retired ? totalDeployed - retired : 0;
    }

    /// @notice Retire requested principal (all remaining principal on full exit) when valuation is readable.
    /// @dev If post-recall valuation fails, only measured token recovery retires principal; no loss is inferred.
    function recallCapital(address adapter, uint256 amount) external virtual override onlyManagerOrOwner {
        // Recovery is never gated by pause: pausing stops deployment and deposits, not exits.
        (uint256 actualReturn, uint256 retired) = ShariahAccountingLogic.recall(
            fundedAdapters, _fundedAdapterIndex, principalOf, asset(), adapter, amount
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
        data;
        ShariahAccountingLogic.deployCapital(
            asset(), strategy, amount, totalDeployed, maxAllocationBps, goldSpreadAdapter, goldAllocationAdapter
        );
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
        // A fee that rounds to zero keeps its elapsed time.
        if (fee == 0 && _feeCanAccrue()) return;
        lastFeeAccrualTime = ShariahAccountingLogic.bookWakalaFee(
            shariahTreasury, fee, lastFeeAccrualTime, false
        );
    }

    /// @dev True when a fee is configured and there is AUM, i.e. elapsed time is worth preserving.
    function _feeCanAccrue() internal view returns (bool) {
        return shariahTreasury.adminFeeBps() > 0 && _navExGainBeforeUnbookedFee() > 0;
    }

    /// @dev Booking replaces an equal view deduction; failed booking cannot gate user exits.
    function _tryAccrueWakalaFee() internal {
        uint256 fee = pendingWakalaFee();
        if (fee == 0 && _feeCanAccrue()) return; // never discard elapsed time through rounding
        lastFeeAccrualTime = ShariahAccountingLogic.bookWakalaFee(
            shariahTreasury, fee, lastFeeAccrualTime, true
        );
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
        if (_profitDistributionLocked) revert AdapterExecutionReentered();
        _profitDistributionLocked = true;
        _tryAccrueWakalaFee();
        uint256 available = realizedProfit();
        if (grossProfit > available) revert ProfitExceedsRealized(grossProfit, available);
        _claimMusharakahProfit(grossProfit);
        _profitDistributionLocked = false;
    }

    /// @dev Shared real distribution; both callers hold the distribution lock before interactions.
    function _claimMusharakahProfit(uint256 grossProfit) internal returns (uint256) {
        // Exit settlement allocates hurdle and deficit allowance to the departing shares only
        // (alpha = shares / supply); an ordinary claim uses the whole vault (alpha = 1).
        uint256 exitShares = _exitShares;
        uint256 exitAssets = _exitAssets;
        (uint256 purified, uint256 charity, uint256 vaultShare, uint256 depositorShare, uint256 nextHurdleStartTime) =
            ShariahAccountingLogic.executeWaterfall(
                asset(), purificationEscrow, grossProfit,
                ShariahAccountingLogic.WaterfallIn(
                    hurdleStartTime, hurdlePrincipal,
                    exitShares == 0 ? 1 : exitShares, exitShares == 0 ? 1 : totalSupply(), exitAssets
                )
            );

        // N-11 / N-24 / N-19: the depositor share is NOT locked. The gross profit was already in
        // NAV before this claim, so returning the depositor share changes nothing about the share
        // price, and hiding it for an unlock period would only discount entrants (N-11), dilute the
        // processed per-share value (N-24) and strand tokens after the last redemption (N-19).
        // Manager-called lockProfit remains available for streaming genuinely new yield.

        // Realized checkpoints must not absorb appreciation before a later recall realizes it.
        // During an exit the payout leaves right after settlement, so stayers' principal excludes it.
        uint256 principalNow = _assetsExcludingGoldGain();
        hurdlePrincipal = principalNow > exitAssets ? principalNow - exitAssets : 0;
        // Advance only by profit already distributed to depositors, not unprocessed yield, so the
        // depositor share cannot be claimed as profit a second time.
        profitBase += depositorShare;
        hurdleStartTime = nextHurdleStartTime;
        // Record the earned depositor peak, never the unprocessed remainder.
        uint256 postClaimPrice = _realizedPricePerShare(_processedNav());
        if (postClaimPrice > highWaterMarkPerShare) highWaterMarkPerShare = postClaimPrice;

        emit MusharakahProfitClaimed(grossProfit, purified, charity, vaultShare, depositorShare);
        return depositorShare;
    }

    /// @notice Sweep accrued fees to a receiver. Amount is capped to `pendingFees` to
    ///         prevent owner from sweeping depositor principal under the guise of fee claims.
    function sweepFeesToTreasury(address receiver, uint256 amount) external onlyOwner {
        ShariahAccountingLogic.sweepFees(asset(), shariahTreasury, receiver, amount);
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
     * @notice Returns 0 when gold prices are insane or adapter valuations are unhealthy.
     * @dev    Failed valuation reads or non-gold losses above dust block entry, never exits.
     *         Withdrawals and redemptions remain priced at marked NAV.
     */
    function maxDeposit(address receiver) public view virtual override returns (uint256) {
        if (!valuationHealthy() || _goldPriceInsane()) return 0;
        return super.maxDeposit(receiver);
    }

    /// @notice Mirror of maxDeposit — blocks minting on insane prices or unhealthy valuations.
    function maxMint(address receiver) public view virtual override returns (uint256) {
        if (!valuationHealthy() || _goldPriceInsane()) return 0;
        return super.maxMint(receiver);
    }

    /// @notice Limits reflect what the vault can pay today: deployed capital is not instantly liquid.
    function maxWithdraw(address owner_) public view virtual override returns (uint256) {
        return Math.min(super.maxWithdraw(owner_), ShariahAccountingLogic.exitLiquidity(asset()));
    }

    function maxRedeem(address owner_) public view virtual override returns (uint256) {
        return ShariahAccountingLogic.liquidRedeemLimit(
            asset(), super.maxRedeem(owner_), totalAssets(), totalSupply() + 10 ** _decimalsOffset()
        );
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
        return ShariahAccountingLogic.goldPriceInsane(principalOf, goldSpreadAdapter, goldAllocationAdapter);
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
        if (totalSupply() != 0 && principal < hurdlePrincipal) revert HurdlePrincipalCannotDecrease();
        hurdlePrincipal = principal;
    }

    /// @notice Set the S2-H gold spread adapter address for combined cap tracking.
    /// @dev    Only used for cap calculation — does not screen the adapter.
    ///         Call setScreened(adapter, true) separately.
    function setGoldSpreadAdapter(address adapter) external onlyOwner {
        ShariahAccountingLogic.replaceGoldAdapter(fundedAdapters, _fundedAdapterIndex, principalOf, retiredGoldAdapter, goldSpreadAdapter, adapter);
        goldSpreadAdapter = adapter;
        if (adapter != address(0)) retiredGoldAdapter[adapter] = false;
        emit GoldSpreadAdapterUpdated(adapter);
    }

    /// @notice Set the S6-H gold allocation adapter address for combined cap tracking.
    /// @dev    Only used for cap calculation — does not screen the adapter.
    ///         Call setScreened(adapter, true) separately.
    function setGoldAllocationAdapter(address adapter) external onlyOwner {
        ShariahAccountingLogic.replaceGoldAdapter(fundedAdapters, _fundedAdapterIndex, principalOf, retiredGoldAdapter, goldAllocationAdapter, adapter);
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

/// @dev Linked valuation and principal accounting, executed in the vault's storage context.
library ShariahAccountingLogic {
    using SafeERC20 for IERC20;

    /// @dev N-33: a cold read of a real Uniswap V3 LP position (HalalLPAdapter on the Arc mainnet USDC/EURC
    ///      pool) costs ~111k gas, so 100k failed every in-transaction read. 150k leaves room for pools with a
    ///      larger observation buffer.
    uint256 internal constant ADAPTER_READ_GAS = 150_000;
    /// @dev Escrow waterfall preview budget, unchanged from the pre-N-33 shared 100k cap.
    uint256 internal constant ESCROW_PREVIEW_GAS = 100_000;
    /// @dev N-33: one exit reads every funded adapter ~23 times. At 150k per read, 5 adapters keep a
    ///      worst-case exit (~17M gas of reads) inside Arc's 30M block gas limit; 10 would not.
    uint256 internal constant MAX_FUNDED_ADAPTERS = 5;

    function retireGoldPrincipal(
        mapping(address => uint256) storage principalOf, address adapter,
        uint256 soldTokens, uint256 heldBefore, uint256 deployed
    ) external returns (uint256) {
        if (soldTokens == 0 || soldTokens > heldBefore) revert ShariahVault.InvalidGoldSaleFraction();
        uint256 principal = principalOf[adapter];
        uint256 retired = soldTokens == heldBefore ? principal : Math.mulDiv(principal, soldTokens, heldBefore);
        principalOf[adapter] = principal - retired;
        emit ShariahVault.PrincipalRetired(adapter, retired, 0);
        return deployed > retired ? deployed - retired : 0;
    }

    /// @dev Exact ERC-4626 floor conversions, including virtual assets and shares.
    /// @dev P2-F1: idle balance less the pending distribution cut. Exit settlement pays the leaver's
    ///      purification and charity out of idle USDC before the liquidity check; that outflow is at most
    ///      the whole-vault cut, so an exit within this limit can always settle instead of skipping it.
    function exitLiquidity(address token) external view returns (uint256) {
        return _exitLiquidity(token);
    }

    function _exitLiquidity(address token) private view returns (uint256) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 cut = ShariahVault(address(this)).pendingDistributionCut();
        return balance > cut ? balance - cut : 0;
    }

    function liquidRedeemLimit(
        address token, uint256 shares, uint256 assets, uint256 virtualSupply
    ) external view returns (uint256) {
        uint256 liquidity = _exitLiquidity(token);
        if (Math.mulDiv(shares, assets + 1, virtualSupply) <= liquidity) return shares;
        return Math.min(shares, Math.mulDiv(liquidity, virtualSupply, assets + 1));
    }

    /// @dev Booking remains in vault context; only the forgiving exit/deposit path catches failure.
    function bookWakalaFee(TreasuryModule treasury, uint256 fee, uint256 lastAccrual, bool forgiving)
        external returns (uint256)
    {
        if (fee != 0) {
            if (forgiving) {
                try treasury.accrue(fee) {} catch {
                    emit ShariahVault.WakalaAccrualSkipped(fee);
                    return lastAccrual;
                }
            } else {
                treasury.accrue(fee);
            }
        }
        emit ShariahVault.WakalaFeeAccrued(fee);
        return block.timestamp;
    }

    function bookPrincipal(
        address[] storage funded, mapping(address => uint256) storage index,
        mapping(address => uint256) storage principalOf,
        address adapter, uint256 amount, address spread, address allocation
    ) external {
        uint256 principal = principalOf[adapter];
        if (principal == 0 && amount != 0 && adapter != spread && adapter != allocation) {
            if (funded.length >= MAX_FUNDED_ADAPTERS) revert ShariahVault.TooManyFundedAdapters();
            funded.push(adapter);
            index[adapter] = funded.length;
        }
        principalOf[adapter] = principal + amount;
    }

    /// @dev Swap/pop keeps removal bounded and updates the moved adapter's one-based index.
    function _remove(address[] storage funded, mapping(address => uint256) storage index, address adapter)
        private
    {
        uint256 position = index[adapter];
        if (position == 0) return;
        uint256 last = funded.length;
        if (position != last) {
            address moved = funded[last - 1];
            funded[position - 1] = moved;
            index[moved] = position;
        }
        funded.pop();
        delete index[adapter];
    }

    function _retire(
        address[] storage funded, mapping(address => uint256) storage index,
        mapping(address => uint256) storage principalOf, address adapter, uint256 amount
    ) private returns (uint256 retired) {
        uint256 principal = principalOf[adapter];
        retired = Math.min(amount, principal);
        principalOf[adapter] = principal - retired;
        if (principal == retired) _remove(funded, index, adapter);
    }

    function returnCapital(
        address[] storage funded, mapping(address => uint256) storage index,
        mapping(address => uint256) storage principalOf, address token, address adapter, uint256 amount
    ) external returns (uint256 retired) {
        // N-35: never pull through an arbitrary allowance (e.g. a depositor's approval to the vault).
        if (principalOf[adapter] == 0) revert ShariahVault.AdapterNotFunded(adapter);
        IERC20(token).safeTransferFrom(adapter, address(this), amount);
        retired = _retire(funded, index, principalOf, adapter, amount);
        emit AutonomousVault.CapitalReturned(adapter, amount);
        emit ShariahVault.PrincipalRetired(adapter, retired, amount);
    }

    function writeOff(
        address[] storage funded, mapping(address => uint256) storage index,
        mapping(address => uint256) storage principalOf, address adapter
    ) external returns (uint256 retired) {
        (bool ok, uint256 value) = _readAdapterValue(adapter);
        if (ok && value != 0) revert ShariahVault.GoldAdapterHasExposure(adapter, value);
        retired = _retire(funded, index, principalOf, adapter, principalOf[adapter]);
        emit ShariahVault.PrincipalRetired(adapter, retired, 0);
    }

    /// @dev Gas-capped, fixed-size output avoids returndata bombs; only exactly 32 bytes is valid.
    ///      A high-level try/catch alone does not catch malformed successful ABI returndata.
    function _readAdapterValue(address adapter) private view returns (bool ok, uint256 value) {
        uint256 selector = uint32(IStrategyAdapter.currentValue.selector);
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, shl(224, selector))
            ok := staticcall(ADAPTER_READ_GAS, adapter, ptr, 4, ptr, 32)
            ok := and(ok, eq(returndatasize(), 32))
            value := mload(ptr)
        }
    }

    function unrealizedAdapterLoss(
        address[] storage funded, mapping(address => uint256) storage principalOf
    ) external view returns (uint256 loss) {
        (loss,) = _unrealizedAdapterLoss(funded, principalOf);
    }

    /// @dev Failed reads do not mark NAV down, but every failure makes entry unhealthy.
    function _unrealizedAdapterLoss(
        address[] storage funded, mapping(address => uint256) storage principalOf
    ) private view returns (uint256 loss, uint256 failedReads) {
        for (uint256 i; i < funded.length; ++i) {
            address adapter = funded[i];
            (bool ok, uint256 value) = _readAdapterValue(adapter);
            if (!ok) ++failedReads;
            else if (principalOf[adapter] > value) loss += principalOf[adapter] - value;
        }
    }

    /// @dev Keep entry checks in the linked library; gold slots are read once per distinct address.
    function valuationHealthy(
        address[] storage funded, mapping(address => uint256) storage principalOf,
        address spread, address allocation
    ) external view returns (bool) {
        (uint256 loss, uint256 failedReads) = _unrealizedAdapterLoss(funded, principalOf);
        if (failedReads != 0) return false;
        if (spread != address(0)) {
            (bool ok,) = _readAdapterValue(spread);
            if (!ok) return false;
        }
        if (allocation != address(0) && allocation != spread) {
            (bool ok,) = _readAdapterValue(allocation);
            if (!ok) return false;
        }
        return loss <= ShariahVault(address(this)).effectiveDustThreshold();
    }

    /// @dev Both NAV paths deduct the same loss once; only pricing includes gold appreciation.
    function navBeforeFee(
        address[] storage funded, mapping(address => uint256) storage principalOf,
        address token, uint256 deployed, address spread, address allocation,
        uint256 locked, TreasuryModule treasury, bool includeGoldGain
    ) external view returns (uint256 assets) {
        assets = IERC20(token).balanceOf(address(this)) + deployed;
        uint256 loss = _goldWritedown(principalOf, spread, allocation);
        assets = assets > loss ? assets - loss : 0;
        (loss,) = _unrealizedAdapterLoss(funded, principalOf);
        assets = assets > loss ? assets - loss : 0;
        if (includeGoldGain) assets += _goldUnrealizedGain(principalOf, spread, allocation);
        assets = assets > locked ? assets - locked : 0;
        uint256 fees = treasury.pendingFees();
        return assets > fees ? assets - fees : 0;
    }

    /// @dev Pricing-only reserve. Bound both gas and copied returndata; invalid splits fail open.
    function pendingDistributionCut(
        PurificationEscrow escrow, uint256 hurdleStartTime, uint256 hurdlePrincipal
    ) external view returns (uint256) {
        if (address(escrow) == address(0) || hurdleStartTime > block.timestamp) return 0;
        ShariahVault vault = ShariahVault(address(this));
        uint256 grossProfit = vault.realizedProfit();
        if (grossProfit == 0) return 0;
        bytes memory input = abi.encodeCall(PurificationEscrow.previewWaterfallHWM, (
            grossProfit, block.timestamp - hurdleStartTime, hurdlePrincipal, vault.hwmDeficit()
        ));
        uint256[4] memory split;
        bool ok;
        assembly ("memory-safe") {
            ok := staticcall(ESCROW_PREVIEW_GAS, escrow, add(input, 32), mload(input), split, 128)
            ok := and(ok, eq(returndatasize(), 128))
        }
        if (!ok) return 0;
        // Subtractive validation decodes all four words without overflow even for hostile output.
        uint256 remaining = grossProfit;
        for (uint256 i; i < 3; ++i) {
            if (split[i] > remaining) return 0;
            remaining -= split[i];
        }
        if (split[3] != remaining) return 0;
        return grossProfit - remaining;
    }

    /// @dev Hurdle basis on a deposit. First deposit (or an unseeded basis) starts the clock now.
    ///      Otherwise the accrued allowance P*t is preserved: the new capital accrues from now,
    ///      i.e. t' = t*P/(P+A) on principal P+A.
    function depositHurdle(
        uint256 start, uint256 principal, uint256 supply, uint256 assetsNow, uint256 assets
    ) external view returns (uint256 newStart, uint256 newPrincipal) {
        if (supply == 0) return (block.timestamp, assets);
        if (principal == 0) return (block.timestamp, assetsNow + assets);
        uint256 elapsed = start < block.timestamp ? block.timestamp - start : 0;
        return (block.timestamp - Math.mulDiv(elapsed, principal, principal + assets), principal + assets);
    }

    /// @dev Waterfall inputs. Preserve approval → processed HWM read → waterfall → allowance reset ordering.
    struct WaterfallIn {
        uint256 start;       // hurdleStartTime
        uint256 principal;   // hurdlePrincipal (whole vault)
        uint256 alphaNum;    // fraction of the vault this distribution covers: num / den
        uint256 alphaDen;
        uint256 exitAssets;  // payout leaving right after an exit settlement (0 otherwise)
    }

    function executeWaterfall(
        address token, PurificationEscrow escrow, uint256 grossProfit, WaterfallIn memory w
    ) external returns (
        uint256 purified, uint256 charity, uint256 vaultShare, uint256 depositorShare,
        uint256 nextHurdleStartTime
    ) {
        IERC20(token).forceApprove(address(escrow), grossProfit);
        // Gross tokens are already in NAV: use the checkpoint-capped processed deficit, and give
        // this distribution only its own fraction of the hurdle and the deficit (alpha = 1 for a
        // whole-vault claim, so ordinary claims are unchanged).
        uint256 deficit = Math.mulDiv(ShariahVault(address(this)).hwmDeficit(), w.alphaNum, w.alphaDen);
        uint256 slice = Math.mulDiv(w.principal, w.alphaNum, w.alphaDen);
        (purified, charity, vaultShare, depositorShare) = escrow.executeWaterfallHWM(
            grossProfit, block.timestamp - w.start, slice, deficit
        );
        IERC20(token).forceApprove(address(escrow), 0);
        // Match the treasury: actual purification/charity deductions, then HWM recovery.
        uint256 net = grossProfit - purified - charity;
        nextHurdleStartTime = _carryHurdle(escrow, w, slice, net > deficit ? net - deficit : 0);
    }

    /// @dev Keep carry arithmetic in the linked waterfall, not the inherited vault runtime.
    ///      The remaining allowance is the whole-vault hurdle minus what this distribution consumed,
    ///      so stayers keep their own share of it after a partial exit.
    function _carryHurdle(
        PurificationEscrow escrow, WaterfallIn memory w, uint256 slice, uint256 netAfterRecovery
    ) private view returns (uint256) {
        uint256 rate = escrow.shariahTreasury().hurdleRateBps();
        uint256 elapsed = block.timestamp - w.start;
        // Same multiplication and flooring as TreasuryModule.calculateMusharakahSplitHWM.
        uint256 hurdle = (w.principal * rate * elapsed) / (10_000 * 365 days);
        uint256 hurdleSlice = (slice * rate * elapsed) / (10_000 * 365 days);
        uint256 consumed = hurdleSlice < netAfterRecovery ? hurdleSlice : netAfterRecovery;
        if (hurdle <= consumed) return block.timestamp;

        ShariahVault vault = ShariahVault(address(this));
        uint256 assets = vault.totalAssetsBeforeDistributionCut();
        uint256 gain = vault.goldUnrealizedGain();
        uint256 newPrincipal = assets > gain ? assets - gain : 0;
        newPrincipal = newPrincipal > w.exitAssets ? newPrincipal - w.exitAssets : 0;
        if (newPrincipal == 0 || rate == 0) return block.timestamp;

        uint256 remaining = hurdle - consumed;
        uint256 annualizedPrincipal = newPrincipal * rate;
        // Clamp before mulDiv so even an unrepresentable lookback cannot overflow.
        if (remaining >= Math.mulDiv(annualizedPrincipal, block.timestamp, 10_000 * 365 days)) return 0;
        // Round UP: flooring the lookback would discard allowance on every partial claim.
        uint256 lookback = Math.mulDiv(
            remaining, 10_000 * 365 days, annualizedPrincipal, Math.Rounding.Ceil
        );
        return block.timestamp - lookback;
    }

    /// @dev Checked inside the self-call so even a rounding/liquidity shortfall rolls back
    ///      only settlement, never the already quoted ERC-4626 payout or its share amount.
    function checkExitLiquidity(address token, uint256 assets) external view {
        uint256 available = IERC20(token).balanceOf(address(this));
        if (available < assets) revert ShariahVault.InsufficientFeeBalance(available, assets);
    }

    function sweepFees(address token, TreasuryModule treasury, address receiver, uint256 amount) external {
        uint256 pending = treasury.pendingFees();
        if (amount > pending) revert AutonomousVault.AllocationExceedsLimit();
        uint256 available = IERC20(token).balanceOf(address(this));
        if (available < amount) revert ShariahVault.InsufficientFeeBalance(available, amount);
        IERC20(token).safeTransfer(receiver, amount);
        treasury.claimFees(receiver, amount);
    }

    function recall(
        address[] storage funded, mapping(address => uint256) storage index,
        mapping(address => uint256) storage principalOf, address token, address adapter, uint256 amount
    ) external returns (uint256 actualReturn, uint256 retired) {
        uint256 recovered;
        {
            uint256 balanceBefore = IERC20(token).balanceOf(address(this));
            uint256 returned = IStrategyAdapter(adapter).recall(amount);
            uint256 balanceAfter = IERC20(token).balanceOf(address(this));
            recovered = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
            actualReturn = recovered > 0 ? recovered : returned;
        }
        (bool ok, uint256 value) = _readAdapterValue(adapter);
        if (!ok) {
            // No inferred closure or loss: only measured recovery retires unreadable principal.
            actualReturn = recovered;
            retired = _retire(funded, index, principalOf, adapter, recovered);
        } else {
            retired = _retire(funded, index, principalOf, adapter, value == 0 ? principalOf[adapter] : amount);
        }
    }

    function replaceGoldAdapter(
        address[] storage funded, mapping(address => uint256) storage index,
        mapping(address => uint256) storage principalOf,
        mapping(address => bool) storage retired, address previous, address replacement
    ) external {
        if (previous != address(0)) {
            uint256 principal = principalOf[previous];
            (bool ok, uint256 value) = _readAdapterValue(previous);
            if (!ok) value = principal;
            if (value > 0) revert ShariahVault.GoldAdapterHasExposure(previous, value);
            if (principal > 0) revert ShariahVault.GoldAdapterHasExposure(previous, principal);
        }
        if (previous != address(0) && previous != replacement) retired[previous] = true;
        // A funded non-gold address can become a gold slot; never mark its loss twice.
        _remove(funded, index, replacement);
    }

    /// @dev Preserve marker → NAV/allocation → combined gold cap → transfer ordering.
    function deployCapital(
        address token, address strategy, uint256 amount, uint256 deployed,
        uint256 maxAllocationBps, address spread, address allocation
    ) external {
        _checkGoldMarker(strategy, spread, allocation);
        uint256 currentAssets = ShariahVault(address(this)).totalAssets();
        uint256 maxDeployable = (currentAssets * maxAllocationBps) / 10_000;
        if (deployed + amount > maxDeployable) revert AutonomousVault.AllocationExceedsLimit();
        _checkGoldCap(strategy, spread, allocation, amount, currentAssets);
        IERC20(token).safeTransfer(strategy, amount);
    }

    function checkGoldMarker(address strategy, address spread, address allocation) external view {
        _checkGoldMarker(strategy, spread, allocation);
    }

    function _checkGoldMarker(address strategy, address spread, address allocation) private view {
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

    /// @dev Preserve allocation-first sanity checks and lazy NAV/dust reads.
    function goldPriceInsane(
        mapping(address => uint256) storage principalOf, address spread, address allocation
    ) external view returns (bool) {
        if (allocation != address(0)) {
            if (!IGoldAdapter(allocation).isPriceSane()
                && principalOf[allocation] > ShariahVault(address(this)).effectiveDustThreshold()) return true;
        }
        if (spread != address(0)) {
            if (!IGoldAdapter(spread).isPriceSane()
                && principalOf[spread] > ShariahVault(address(this)).effectiveDustThreshold()) return true;
        }
        return false;
    }

    function checkGoldCap(
        address strategy, address spread, address allocation, uint256 amount, uint256 currentAssets
    ) external view {
        _checkGoldCap(strategy, spread, allocation, amount, currentAssets);
    }

    function _checkGoldCap(
        address strategy, address spread, address allocation, uint256 amount, uint256 currentAssets
    ) private view {
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
    ) external view returns (uint256) {
        return _goldWritedown(principalOf, spread, allocation);
    }

    function _goldWritedown(
        mapping(address => uint256) storage principalOf, address spread, address allocation
    ) private view returns (uint256 writedown) {
        if (spread != address(0)) {
            (bool ok, uint256 value) = _readAdapterValue(spread);
            uint256 principal = principalOf[spread];
            if (ok && principal > value) writedown = principal - value;
        }
        if (allocation != address(0) && allocation != spread) {
            (bool ok, uint256 value) = _readAdapterValue(allocation);
            uint256 principal = principalOf[allocation];
            if (ok && principal > value) writedown += principal - value;
        }
    }

    function goldUnrealizedGain(
        mapping(address => uint256) storage principalOf, address spread, address allocation
    ) external view returns (uint256) {
        return _goldUnrealizedGain(principalOf, spread, allocation);
    }

    function _goldUnrealizedGain(
        mapping(address => uint256) storage principalOf, address spread, address allocation
    ) private view returns (uint256 gain) {
        if (spread != address(0)) {
            (bool ok, uint256 value) = _readAdapterValue(spread);
            uint256 principal = principalOf[spread];
            if (ok && value > principal) gain = value - principal;
        }
        if (allocation != address(0) && allocation != spread) {
            (bool ok, uint256 value) = _readAdapterValue(allocation);
            uint256 principal = principalOf[allocation];
            if (ok && value > principal) gain += value - principal;
        }
    }
}
