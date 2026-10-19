// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AutonomousVault} from "./AutonomousVault.sol";
import {TreasuryModule} from "./TreasuryModule.sol";
import {ZakatModule} from "./ZakatModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract ShariahVault is AutonomousVault {
    using SafeERC20 for IERC20;

    error AdapterNotScreened();
    error AssetNotPermitted(address asset_);

    event AdapterScreened(address indexed adapter, bool approved);
    event PermittedAssetUpdated(address indexed asset_, bool permitted);
    event WakalaFeeAccrued(uint256 amount);
    event MusharakahProfitClaimed(uint256 grossProfit, uint256 zakatAmount, uint256 vaultShare, uint256 depositorShare);
    event ShariahScreeningToggled(bool enabled);

    TreasuryModule public immutable shariahTreasury;
    ZakatModule public immutable zakatModule;

    bool public shariahScreeningEnabled;
    mapping(address => bool) public screened;
    mapping(address => bool) public permittedAssets;

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
        if (!permittedAssets[asset()]) revert AssetNotPermitted(asset());
        if (shariahScreeningEnabled && !screened[strategy]) revert AdapterNotScreened();

        data;

        uint256 currentAssets = totalAssets();
        uint256 maxDeployable = (currentAssets * maxAllocationBps) / 10_000;
        if (totalDeployed + amount > maxDeployable) revert AllocationExceedsLimit();

        IERC20(asset()).safeTransfer(strategy, amount);
        totalDeployed += amount;

        emit CapitalDeployed(strategy, amount);

        _accrueWakalaFee();
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

    function setShariahScreening(bool enabled) external onlyOwner {
        shariahScreeningEnabled = enabled;
        emit ShariahScreeningToggled(enabled);
    }

    function setHurdlePrincipal(uint256 principal) external onlyOwner {
        hurdlePrincipal = principal;
    }
}
