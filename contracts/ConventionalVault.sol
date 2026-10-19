// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AutonomousVault} from "./AutonomousVault.sol";
import {TreasuryModule} from "./TreasuryModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract ConventionalVault is AutonomousVault {
    using SafeERC20 for IERC20;

    event AdminFeeAccrued(uint256 amount);

    TreasuryModule public immutable conventionalTreasury;
    uint256 public lastFeeAccrualTime;

    constructor(IERC20 asset_, address initialOwner, uint32 sourceDomain_, address conventionalTreasury_)
        AutonomousVault(asset_, initialOwner, sourceDomain_)
    {
        conventionalTreasury = TreasuryModule(conventionalTreasury_);
        lastFeeAccrualTime = block.timestamp;
    }

    function name() public pure override(ERC20, IERC20Metadata) returns (string memory) {
        return "Conventional Vault Share";
    }

    function symbol() public pure override(ERC20, IERC20Metadata) returns (string memory) {
        return "cvUSDC";
    }

    function accrueAdminFee() public {
        _accrueAdminFeeInternal();
    }

    /// @notice Conventional deployment path with post-deploy admin fee accrual.
    /// @dev AutonomousVault.deployCapital is non-virtual, so this function is provided instead.
    function deployCapitalWithFeeAccrual(address strategy, uint256 amount, bytes calldata data)
        external
        onlyManagerOrOwner
    {
        data;

        uint256 currentAssets = totalAssets();
        uint256 maxDeployable = (currentAssets * maxAllocationBps) / 10_000;
        if (totalDeployed + amount > maxDeployable) revert AllocationExceedsLimit();

        IERC20(asset()).safeTransfer(strategy, amount);
        totalDeployed += amount;

        emit CapitalDeployed(strategy, amount);

        _accrueAdminFeeInternal();
    }

    /// @notice Sweep accrued fees to a receiver. Amount is capped to `pendingFees` to
    ///         prevent owner from sweeping depositor principal under the guise of fee claims.
    function sweepFeesToTreasury(address receiver, uint256 amount) external onlyOwner {
        uint256 pending = conventionalTreasury.pendingFees();
        if (amount > pending) revert AllocationExceedsLimit();
        IERC20(asset()).safeTransfer(receiver, amount);
        conventionalTreasury.claimFees(receiver, amount);
    }

    function _accrueAdminFeeInternal() internal {
        uint256 elapsed = block.timestamp - lastFeeAccrualTime;
        uint256 aum = totalAssets();
        uint256 fee = (aum * conventionalTreasury.adminFeeBps() * elapsed) / (10_000 * 365 days);

        if (fee > 0) {
            conventionalTreasury.accrue(fee);
        }

        lastFeeAccrualTime = block.timestamp;
        emit AdminFeeAccrued(fee);
    }
}
