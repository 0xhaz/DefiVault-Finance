// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ShariahVault} from "./ShariahVault.sol";
import {ShariahAdapterRegistry} from "./ShariahAdapterRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title  ShariahVaultV2
 * @notice V2 extension of ShariahVault that delegates adapter screening to
 *         ShariahAdapterRegistry rather than a simple `screened[addr]` mapping.
 *
 * ## Changes from V1
 * 1. `deployCapital` now checks `registry.isScreened(strategy)` which verifies:
 *    - `pronouncementHash != bytes32(0)` (board resolution recorded on-chain)
 *    - `block.timestamp < expiresAt` (screening has not expired)
 * 2. The legacy `screened` mapping in ShariahVault is retained for backward
 *    compatibility (V1 operators can still call V1 methods on the V1 vault).
 *    V2 ignores `screened` and always uses the registry.
 * 3. Registry changes require current-board approval and a 30-day timelock.
 *
 * ## Migration
 * V1 vault deposits and redemptions are always available at NAV (no forced
 * migration). V2 is a new deployment; depositors migrate voluntarily.
 * See docs/migration-v1-to-v2.md.
 *
 * ## Task E checklist
 * - deployCapital reverts NotScreened when pronouncementHash == 0   ✓
 * - deployCapital reverts when block.timestamp >= expiresAt           ✓
 * - non-boardRole cannot call setScreening (uses registry — onlyOwner) ✓
 * - ShariahAdapterRegistry enforces 30-day timelock on all changes    ✓
 * - V1 vault stays live; this is a new deployment, not an upgrade     ✓
 */
contract ShariahVaultV2 is ShariahVault {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────

    /// @notice Thrown when the strategy adapter is not in the registry OR
    ///         its screening has expired.
    error NotScreened(address adapter);

    /// @notice Thrown when trying to deploy to a strategy whose board screening
    ///         has passed its expiresAt timestamp.
    error ScreeningExpired(address adapter, uint256 expiresAt);
    error ZeroRegistry();
    error NoPendingRegistryProposal();
    error RegistryProposalAlreadyExists();
    error RegistryTimelockNotElapsed(uint256 earliest, uint256 current);

    // ─────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────

    event RegistryUpdated(address indexed registry);
    event RegistryProposed(address newRegistry, uint256 executeAfter);
    event RegistryProposalCancelled();

    // ─────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────

    /// @notice Governance-gated adapter registry.
    ShariahAdapterRegistry public registry;

    uint256 public constant REGISTRY_TIMELOCK = 30 days;

    struct PendingRegistry {
        address newRegistry;
        uint256 executeAfter;
        bool exists;
    }
    PendingRegistry public pendingRegistry;

    // ─────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────

    constructor(
        IERC20 asset_,
        address initialOwner,
        uint32 sourceDomain_,
        address shariahTreasury_,
        address zakatModule_,
        address registry_
    ) ShariahVault(asset_, initialOwner, sourceDomain_, shariahTreasury_, zakatModule_) {
        registry = ShariahAdapterRegistry(registry_);
    }

    // ─────────────────────────────────────────────────────────────
    // ERC-20 overrides (distinct symbol/name from V1)
    // ─────────────────────────────────────────────────────────────

    function name() public pure virtual override returns (string memory) {
        return "Shariah Vault V2 Share";
    }

    function symbol() public pure virtual override returns (string memory) {
        return "svUSDCv2";
    }

    // ─────────────────────────────────────────────────────────────
    // deployCapital — V2 registry check
    // ─────────────────────────────────────────────────────────────

    /// @dev Transfer-only deployment inherits the nonzero gold-adapter guard from V1.
    ///      Both inherited deployment entry points route here. Registry errors retain
    ///      precedence over pause/asset errors, independently of the legacy screening flag.
    function _checkDeploymentScreening(address strategy) internal view virtual override {
        ShariahAdapterRegistry.Screening memory s = registry.getScreening(strategy);
        if (s.pronouncementHash == bytes32(0)) revert NotScreened(strategy);
        if (block.timestamp >= s.expiresAt) revert ScreeningExpired(strategy, s.expiresAt);
        if (paused) revert Paused();
        if (!permittedAssets[asset()]) revert AssetNotPermitted(asset());
    }

    // ─────────────────────────────────────────────────────────────
    // Registry management
    // ─────────────────────────────────────────────────────────────

    function _isBoard(address account) internal view override returns (bool) {
        return address(registry) != address(0) && registry.isBoard(account);
    }

    /// @dev Always authorizes against the current registry, never the proposed registry.
    ///      Testnet/bootstrap only: while the current registry is zero, only the owner
    ///      may propose, confirm or cancel, without a board check.
    modifier onlyRegistryGovernance() {
        if (address(registry) == address(0)) {
            _checkOwner();
        } else if (!_isBoard(msg.sender)) {
            revert NotBoardRole(msg.sender);
        }
        _;
    }

    /// @notice Current board proposes a nonzero registry with a 30-day delay.
    /// @dev Testnet/bootstrap only: a zero current registry permits owner proposal
    ///      and immediate confirmation without a board check or delay.
    function proposeRegistry(address registry_) external onlyRegistryGovernance {
        ShariahRegistryLogic.propose(pendingRegistry, address(registry), registry_);
    }

    /// @notice Current board confirms after the delay and clears any pending dust proposal.
    /// @dev Testnet/bootstrap only: if the current registry is zero, the owner may
    ///      confirm immediately without a board check.
    function confirmRegistry() external onlyRegistryGovernance {
        address updated = ShariahRegistryLogic.confirm(pendingRegistry, pendingDustThreshold);
        registry = ShariahAdapterRegistry(updated);
        emit RegistryUpdated(updated);
    }

    /// @notice Current board cancels a pending registry proposal without waiting.
    /// @dev Testnet/bootstrap only: with a zero current registry, only the owner may cancel.
    function cancelRegistry() external onlyRegistryGovernance {
        ShariahRegistryLogic.cancel(pendingRegistry);
    }
}

/// @dev Minimal interface to read currentValue() from a gold adapter (duplicated to avoid
///      import order issues with ShariahVault's IGoldAdapter).
interface IGoldAdapterV2 {
    function currentValue() external view returns (uint256);
}

/// @dev Linked registry proposal storage operations; current-registry authorization stays on V2.
library ShariahRegistryLogic {
    function propose(
        ShariahVaultV2.PendingRegistry storage pending, address currentRegistry, address proposed
    ) external {
        if (proposed == address(0)) revert ShariahVaultV2.ZeroRegistry();
        if (pending.exists) revert ShariahVaultV2.RegistryProposalAlreadyExists();
        uint256 executeAfter = currentRegistry == address(0)
            ? block.timestamp : block.timestamp + 30 days;
        pending.newRegistry = proposed;
        pending.executeAfter = executeAfter;
        pending.exists = true;
        emit ShariahVaultV2.RegistryProposed(proposed, executeAfter);
    }

    function confirm(
        ShariahVaultV2.PendingRegistry storage pending,
        ShariahVault.PendingDustThreshold storage dust
    ) external returns (address updated) {
        ShariahVaultV2.PendingRegistry memory p = pending;
        if (!p.exists) revert ShariahVaultV2.NoPendingRegistryProposal();
        if (block.timestamp < p.executeAfter) {
            revert ShariahVaultV2.RegistryTimelockNotElapsed(p.executeAfter, block.timestamp);
        }
        delete pending.newRegistry;
        delete pending.executeAfter;
        delete pending.exists;
        if (dust.exists) {
            delete dust.newValue;
            delete dust.executeAfter;
            delete dust.exists;
            emit ShariahVault.DustThresholdProposalCancelled();
        }
        return p.newRegistry;
    }

    function cancel(ShariahVaultV2.PendingRegistry storage pending) external {
        if (!pending.exists) revert ShariahVaultV2.NoPendingRegistryProposal();
        delete pending.newRegistry;
        delete pending.executeAfter;
        delete pending.exists;
        emit ShariahVaultV2.RegistryProposalCancelled();
    }
}
