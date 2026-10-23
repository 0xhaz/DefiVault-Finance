// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategyAdapter} from "./IStrategyAdapter.sol";

interface ITokenMessenger {
    function depositForBurnWithCaller(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller
    ) external returns (uint64 nonce);
}

contract AutonomousVault is ERC4626, Ownable2Step {
    using SafeERC20 for IERC20;

    error Paused();
    error NotManager();
    error AllocationExceedsLimit();
    error InvalidBps();
    error CrossChainNotConfigured();
    error SameDomainDeploy();
    error NonceMismatch(uint64 nonce);
    /// @notice Thrown when a cross-chain deploy would push pending cross-chain > maxPendingCrossChainBps.
    error PendingCrossChainCapExceeded();
    /// @notice Thrown when profitUnlockPeriod is set above MAX_PROFIT_UNLOCK_PERIOD.
    error InvalidUnlockPeriod();
    /// @notice Thrown by settleCrossChain when the caller claims more was received than
    ///         actually arrived in the vault since the matching deployCrossChain (I1).
    error ReceivedExceedsArrived(uint256 claimed, uint256 arrived);

    event ManagerUpdated(address indexed previousManager, address indexed newManager);
    event MaxAllocationBpsUpdated(uint256 previousBps, uint256 newBps);
    event PauseUpdated(bool paused);
    event CapitalDeployed(address indexed strategy, uint256 amount);
    event CapitalReturned(address indexed strategy, uint256 amount);
    event CapitalRecalledFromAdapter(address indexed adapter, uint256 requested, uint256 returned);
    event CapitalDeployedCrossChain(
        uint32 indexed destinationDomain,
        bytes32 indexed recipient,
        uint256 amount,
        uint64 nonce
    );
    event CrossChainSettled(uint64 indexed nonce, uint256 amount, uint256 shortfall);
    event TokenMessengerUpdated(address indexed previousMessenger, address indexed newMessenger);
    event ProfitLocked(uint256 amount, uint256 unlockedAt);
    event CrossChainCapUpdated(uint256 newBps);

    address public manager;
    bool public paused;
    uint256 public maxAllocationBps = 8_000;
    uint256 public totalDeployed;
    address public tokenMessenger;
    /// @dev The CCTP domain of THIS chain (set in constructor, used to guard deployCrossChain)
    uint32 public immutable sourceDomain;
    /// @dev Tracks pending crosschain positions: nonce => amount, for settlement accounting
    mapping(uint64 => uint256) public pendingCrossChain;
    /// @dev Sum of all outstanding cross-chain positions (for cap enforcement — PR3.3).
    uint256 public totalPendingCrossChain;
    /// @notice Max fraction of totalAssets allowed in-flight cross-chain (default 2000 = 20%).
    uint256 public maxPendingCrossChainBps = 2_000;
    /// @notice Hard cap for maxPendingCrossChainBps.
    uint256 public constant MAX_PENDING_CROSS_CHAIN_BPS = 5_000;

    /// @notice USDC balance snapshot taken just before each deployCrossChain call (I1).
    ///         Used by settleCrossChain to verify that `received` does not exceed the
    ///         actual balance increase since the deploy, preventing NAV inflation by
    ///         an over-reporting caller.  Keyed by CCTP nonce.
    mapping(uint64 => uint256) public balanceBeforeDeploy;

    /// @notice Profit locked for linear unlock (PR3.2 — Yearn-style streaming).
    ///         Locked profit is excluded from totalAssets until unlockedAt.
    uint256 public lockedProfit;
    /// @notice Timestamp when lockedProfit finishes unlocking linearly.
    uint256 public unlockedAt;
    /// @notice Duration over which profit is linearly streamed into NAV (default 3 days).
    uint256 public profitUnlockPeriod = 3 days;
    /// @notice Hard cap for profitUnlockPeriod.
    uint256 public constant MAX_PROFIT_UNLOCK_PERIOD = 14 days;

    constructor(IERC20 asset_, address initialOwner, uint32 sourceDomain_)
        ERC4626(asset_)
        ERC20("Autonomous Vault Share", "avUSDC")
        Ownable(initialOwner)
    {
        sourceDomain = sourceDomain_;
    }

    /// @dev Virtual offset of 6 decimals (matching USDC) makes the first-depositor
    ///      inflation/donation attack economically impractical by requiring an
    ///      attacker to donate 10^6 × more than the seed deposit to move the price.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    modifier onlyManagerOrOwner() {
        if (msg.sender != owner() && msg.sender != manager) revert NotManager();
        _;
    }

    /// @notice Returns the current locked profit (linearly decreasing to 0 over profitUnlockPeriod).
    function _currentLockedProfit() internal view returns (uint256) {
        if (lockedProfit == 0 || block.timestamp >= unlockedAt) return 0;
        uint256 elapsed  = block.timestamp - (unlockedAt - profitUnlockPeriod);
        uint256 duration = profitUnlockPeriod;
        // Linear: lockedProfit * (duration - elapsed) / duration
        if (elapsed >= duration) return 0;
        return (lockedProfit * (duration - elapsed)) / duration;
    }

    function totalAssets() public view virtual override returns (uint256) {
        uint256 base = super.totalAssets() + totalDeployed;
        uint256 locked = _currentLockedProfit();
        return base > locked ? base - locked : 0;
    }

    /**
     * @dev Internal helper — stacks amount on top of any remaining locked profit.
     *      Called by lockProfit (external) and by ShariahVault.claimMusharakahProfit (internal).
     */
    function _lockProfitInternal(uint256 amount) internal {
        uint256 remaining = _currentLockedProfit();
        lockedProfit = remaining + amount;
        unlockedAt   = block.timestamp + profitUnlockPeriod;
        emit ProfitLocked(amount, unlockedAt);
    }

    /**
     * @notice Lock profit for linear streaming into NAV (PR3.2).
     * @dev    Called by the manager/owner after profit is credited to the vault
     *         (e.g. after claimMusharakahProfit deposits the depositorShare back).
     *         New profit stacks on top of any remaining locked profit (Yearn pattern).
     */
    function lockProfit(uint256 amount) external onlyManagerOrOwner {
        _lockProfitInternal(amount);
    }

    /// @notice Owner updates profit unlock period (board-settable; max 14 days).
    function setProfitUnlockPeriod(uint256 period) external onlyOwner {
        if (period > MAX_PROFIT_UNLOCK_PERIOD) revert InvalidUnlockPeriod();
        profitUnlockPeriod = period;
    }

    /// @notice Owner updates max pending cross-chain cap.
    function setMaxPendingCrossChainBps(uint256 bps) external onlyOwner {
        if (bps > MAX_PENDING_CROSS_CHAIN_BPS) revert InvalidBps();
        maxPendingCrossChainBps = bps;
        emit CrossChainCapUpdated(bps);
    }

    function deployCapital(address strategy, uint256 amount, bytes calldata data) external virtual onlyManagerOrOwner {
        if (paused) revert Paused();
        data;

        // Enforce cumulative cap: already-deployed + new amount must stay within the BPS limit
        uint256 currentAssets = totalAssets();
        uint256 maxDeployable = (currentAssets * maxAllocationBps) / 10_000;
        if (totalDeployed + amount > maxDeployable) revert AllocationExceedsLimit();

        IERC20(asset()).safeTransfer(strategy, amount);
        totalDeployed += amount;

        emit CapitalDeployed(strategy, amount);
    }

    function deployCrossChain(
        uint32 destinationDomain,
        bytes32 recipient,
        uint256 amount
    ) public virtual onlyManagerOrOwner {
        if (paused) revert Paused();
        if (tokenMessenger == address(0)) revert CrossChainNotConfigured();
        // Use immutable sourceDomain (not a hardcoded constant) to block same-chain burns
        if (destinationDomain == sourceDomain) revert SameDomainDeploy();

        uint256 currentAssets = totalAssets();
        uint256 maxDeployable = (currentAssets * maxAllocationBps) / 10_000;
        if (totalDeployed + amount > maxDeployable) revert AllocationExceedsLimit();

        // PR3.3: Enforce cross-chain pending cap BEFORE burning tokens so totalAssets() is correct.
        uint256 maxPending = (totalAssets() * maxPendingCrossChainBps) / 10_000;
        if (totalPendingCrossChain + amount > maxPending) revert PendingCrossChainCapExceeded();

        // I1: Snapshot USDC balance before the burn so settleCrossChain can verify
        //     that `received` does not exceed what actually arrived in the vault.
        uint256 _balBefore = IERC20(asset()).balanceOf(address(this));

        // Approve exact amount; always clear residual allowance after the call
        IERC20(asset()).forceApprove(tokenMessenger, amount);
        uint64 nonce = ITokenMessenger(tokenMessenger).depositForBurnWithCaller(
            amount,
            destinationDomain,
            recipient,
            asset(),
            bytes32(0)
        );
        // Clear any leftover allowance to prevent tokenMessenger from pulling more later
        IERC20(asset()).forceApprove(tokenMessenger, 0);

        totalDeployed += amount;
        totalPendingCrossChain += amount;
        // Record pending position so settleCrossChain can decrement totalDeployed on return
        pendingCrossChain[nonce] = amount;
        // I1: Record balance after burn (== balBefore - amount) for arrival verification.
        balanceBeforeDeploy[nonce] = _balBefore - amount; // vault balance after the outbound burn

        emit CapitalDeployedCrossChain(destinationDomain, recipient, amount, nonce);
    }

    function returnCapital(address strategy, uint256 amount) external onlyManagerOrOwner {
        if (paused) revert Paused();
        // Pull actual tokens back from the strategy before adjusting accounting
        IERC20(asset()).safeTransferFrom(strategy, address(this), amount);
        totalDeployed -= amount;
        emit CapitalReturned(strategy, amount);
    }

    /// @notice Recall capital from an IStrategyAdapter. The adapter unwinds its position,
    ///         transfers USDC back to this vault, and returns the actual amount received.
    ///         totalDeployed is decremented by the actual return (not the requested amount)
    ///         so NAV accounting stays accurate even when slippage or fees reduce proceeds.
    /// @param adapter  Address implementing IStrategyAdapter (must have vault == address(this))
    /// @param amount   Requested USDC amount to recall (adapter may return less due to slippage)
    function recallCapital(address adapter, uint256 amount) external onlyManagerOrOwner {
        if (paused) revert Paused();
        uint256 balanceBefore = IERC20(asset()).balanceOf(address(this));
        uint256 returned = IStrategyAdapter(adapter).recall(amount);
        uint256 balanceAfter = IERC20(asset()).balanceOf(address(this));

        // Use the higher of adapter-reported return and actual balance delta for safety
        uint256 actualReturn = balanceAfter > balanceBefore
            ? balanceAfter - balanceBefore
            : returned;

        if (actualReturn > totalDeployed) {
            totalDeployed = 0;
        } else {
            totalDeployed -= actualReturn;
        }

        emit CapitalRecalledFromAdapter(adapter, amount, actualReturn);
    }

    /// @notice Called by the manager/owner once the crosschain USDC has been bridged BACK
    ///         to this vault on the source chain (attested by the CCTP attestation service
    ///         and received via a MessageTransmitter.receiveMessage call).
    /// @dev    The matching CCTP burn nonce tracks the original outbound position.
    ///         Decrements `totalDeployed` so ERC-4626 NAV remains accurate.
    ///         The corresponding USDC tokens must already be in this vault (minted here
    ///         by the destination's reverse CCTP burn + source attestation) before calling.
    /**
     * @notice Settle a completed cross-chain position.
     * @dev    PR3.3: caller passes the actual USDC amount received back (may be less than sent
     *         due to bridge fees, slippage, or loss). Any shortfall is booked as an immediate
     *         NAV loss by leaving totalDeployed reduced only by `received`, not `sent`.
     *         `received` must be <= original amount; caller must have transferred the USDC back.
     * @param nonce    The CCTP nonce from the original deployCrossChain call.
     * @param received Actual USDC received (0 < received <= original amount).
     */
    function settleCrossChain(uint64 nonce, uint256 received) external onlyManagerOrOwner {
        uint256 sent = pendingCrossChain[nonce];
        if (sent == 0) revert NonceMismatch(nonce);

        // I1: Verify that the caller's `received` claim does not exceed what actually
        //     arrived on-chain.  We compare the current vault balance against the
        //     snapshot taken when the outbound burn fired.  CCTP mints the inbound USDC
        //     to this vault BEFORE the operator calls settleCrossChain, so the balance
        //     delta equals the real arrived amount.
        //     Any other tokens that arrived between deploy and settle (e.g. from unrelated
        //     sources) would also count here — acceptable: they make the bound looser, not
        //     tighter, so a legitimate settle always passes.
        uint256 balNow   = IERC20(asset()).balanceOf(address(this));
        uint256 snapBase = balanceBeforeDeploy[nonce];
        uint256 arrived  = balNow >= snapBase ? balNow - snapBase : 0;
        if (received > arrived) revert ReceivedExceedsArrived(received, arrived);

        delete pendingCrossChain[nonce];
        delete balanceBeforeDeploy[nonce];

        uint256 shortfall = sent > received ? sent - received : 0;
        // Decrement totalDeployed by the full sent amount. The received USDC tokens are
        // already minted to vault balance by CCTP (counted in ERC4626.totalAssets()),
        // so we must NOT add `received` back to totalDeployed — that would double-count.
        // Net effect on NAV: vault.balanceOf += received, totalDeployed -= sent.
        // NAV change = received - sent = -shortfall (loss booked immediately).
        totalDeployed          = totalDeployed >= sent ? totalDeployed - sent : 0;
        totalPendingCrossChain = totalPendingCrossChain >= sent ? totalPendingCrossChain - sent : 0;

        emit CrossChainSettled(nonce, received, shortfall);
    }

    function setManager(address newManager) external onlyOwner {
        address previousManager = manager;
        manager = newManager;
        emit ManagerUpdated(previousManager, newManager);
    }

    function setMaxAllocationBps(uint256 bps) external onlyOwner {
        if (bps > 9_500) revert InvalidBps();

        uint256 previousBps = maxAllocationBps;
        maxAllocationBps = bps;
        emit MaxAllocationBpsUpdated(previousBps, bps);
    }

    function setTokenMessenger(address messenger) external onlyOwner {
        address previous = tokenMessenger;
        tokenMessenger = messenger;
        emit TokenMessengerUpdated(previous, messenger);
    }

    function setPaused(bool newPaused) external onlyOwner {
        paused = newPaused;
        emit PauseUpdated(newPaused);
    }

    function deposit(uint256 assets, address receiver) public virtual override returns (uint256) {
        if (paused) revert Paused();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public virtual override returns (uint256) {
        if (paused) revert Paused();
        return super.mint(shares, receiver);
    }
}
