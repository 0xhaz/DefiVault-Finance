// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AutonomousVault} from "./AutonomousVault.sol";
import {TreasuryModule} from "./TreasuryModule.sol";
import {ZakatModule} from "./ZakatModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Minimal interface to read currentValue() and isPriceSane() from a gold adapter.
interface IGoldAdapter {
    function currentValue() external view returns (uint256);
    function isPriceSane() external view returns (bool);
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

    event AdapterScreened(address indexed adapter, bool approved);
    event PermittedAssetUpdated(address indexed asset_, bool permitted);
    event WakalaFeeAccrued(uint256 amount);
    event MusharakahProfitClaimed(uint256 grossProfit, uint256 zakatAmount, uint256 vaultShare, uint256 depositorShare);
    event ShariahScreeningToggled(bool enabled);
    event GoldCrossChainBlockedUpdated(bool blocked);
    event GoldAllocationAdapterUpdated(address indexed adapter);
    event GoldSpreadAdapterUpdated(address indexed adapter);

    TreasuryModule public immutable shariahTreasury;
    ZakatModule public immutable zakatModule;

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

    uint256 public lastFeeAccrualTime;
    uint256 public hurdlePrincipal;
    uint256 public hurdleStartTime;

    constructor(
        IERC20 asset_,
        address initialOwner,
        uint32 sourceDomain_,
        address shariahTreasury_,
        address zakatModule_
    ) AutonomousVault(asset_, initialOwner, sourceDomain_) {
        shariahTreasury = TreasuryModule(shariahTreasury_);
        zakatModule = ZakatModule(zakatModule_);

        shariahScreeningEnabled = true;
        lastFeeAccrualTime = block.timestamp;
        hurdleStartTime = block.timestamp;
        permittedAssets[address(asset_)] = true;
    }

    function name() public pure override(ERC20, IERC20Metadata) returns (string memory) {
        return "Shariah Vault Share";
    }

    function symbol() public pure override(ERC20, IERC20Metadata) returns (string memory) {
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

    function claimMusharakahProfit(uint256 grossProfit) external onlyManagerOrOwner {
        IERC20(asset()).forceApprove(address(zakatModule), grossProfit);
        (uint256 zakatAmount, uint256 remaining) = zakatModule.distributeZakat(grossProfit);
        IERC20(asset()).forceApprove(address(zakatModule), 0);

        (uint256 hurdleAmount, uint256 vaultShare, uint256 depositorShare) = shariahTreasury.calculateMusharakahSplit(
            remaining,
            block.timestamp - hurdleStartTime,
            hurdlePrincipal
        );
        hurdleAmount;

        shariahTreasury.recordMusharakahProfit(vaultShare);

        hurdlePrincipal = totalAssets();
        hurdleStartTime = block.timestamp;

        emit MusharakahProfitClaimed(grossProfit, zakatAmount, vaultShare, depositorShare);
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
}
