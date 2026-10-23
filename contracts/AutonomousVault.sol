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

/// @notice CCTP V2 MessageTransmitter — only the function needed for atomic settle.
interface IMessageTransmitterV2 {
    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool success);
}

/// @notice Minimal decoder for the CCTP V2 burn message to extract nonce, amount,
///         mintRecipient, and feeExecuted.
///
///         Outer message header layout (116 bytes, all big-endian):
///           [0..3]    version (uint32)
///           [4..7]    sourceDomain (uint32)
///           [8..11]   destinationDomain (uint32)
///           [12..19]  nonce (uint64)
///           [20..51]  sender (bytes32)
///           [52..83]  recipient (bytes32)
///           [84..115] destinationCaller (bytes32)
///
///         BurnMessage body layout (at outer header offset 116, all big-endian):
///           [0..3]    version (uint32)
///           [4..35]   burnToken (bytes32)
///           [36..67]  mintRecipient (bytes32)
///           [68..99]  amount (uint256)
///           [100..131] messageSender (bytes32)
///           [132..163] feeExecuted (uint256)  — CCTP V2 Fast Transfer field;
///                       zero for Standard Transfer. The CCTP V2 transmitter mints
///                       (amount - feeExecuted) to the mintRecipient — NOT the full amount.
library CctpMessageDecoder {
    /// @dev Minimum message length: 116-byte header + 164-byte V2 body.
    uint256 internal constant MIN_MESSAGE_LEN = 116 + 164;

    /// @dev Returns the `nonce` embedded in the outer CCTP message header.
    ///      Header layout (bytes):
    ///        [0..3]   version
    ///        [4..7]   sourceDomain
    ///        [8..11]  destinationDomain
    ///        [12..19] nonce (uint64)
    ///        ... (rest unused here)
    function decodeNonce(bytes calldata message) internal pure returns (uint64 nonce) {
        require(message.length >= 20, "CCTP: message too short");
        nonce = uint64(bytes8(bytes20(message[12:20])));
    }

    /// @dev Returns `amount`, `mintRecipient`, and `feeExecuted` from the V2 BurnMessage body.
    ///      The outer message header is 116 bytes; the body starts at offset 116.
    ///      For Standard Transfer, `feeExecuted` is zero and the full `amount` is minted.
    ///      For Fast Transfer, `feeExecuted` > 0 and the net minted amount is
    ///      `amount - feeExecuted`.
    function decodeBody(bytes calldata message)
        internal
        pure
        returns (uint256 amount, bytes32 mintRecipient, uint256 feeExecuted)
    {
        require(message.length >= MIN_MESSAGE_LEN, "CCTP: message body too short");
        // body offset 36..67 = mintRecipient
        mintRecipient = bytes32(message[116 + 36 : 116 + 68]);
        // body offset 68..99 = amount (gross, before fee deduction)
        amount        = uint256(bytes32(message[116 + 68 : 116 + 100]));
        // body offset 132..163 = feeExecuted (zero for Standard Transfer)
        feeExecuted   = uint256(bytes32(message[116 + 132 : 116 + 164]));
    }
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
    /// @notice Thrown by settleCrossChainWithMessage when the decoded mintRecipient is not this vault.
    error WrongMintRecipient(bytes32 recipient);
    /// @notice Thrown by settleCrossChainWithMessage when the net minted amount
    ///         (message amount minus feeExecuted) does not equal the actual USDC balance delta.
    error MessageAmountMismatch(uint256 expectedNet, uint256 balanceDelta);
    /// @notice Thrown by the write-off path when received > 0 (write-off must book a full loss).
    error WriteOffMustBeZero();

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
    /// @notice Emitted when a CCTP Fast Transfer fee is deducted from the minted amount.
    ///         `feeExecuted` is booked as part of the cross-chain cost alongside any strategy loss.
    event CrossChainFeeDeducted(uint64 indexed nonce, uint256 feeExecuted);
    event TokenMessengerUpdated(address indexed previousMessenger, address indexed newMessenger);
    event MessageTransmitterUpdated(address indexed previous, address indexed updated);
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

    /// @notice CCTP V2 MessageTransmitter used by settleCrossChainWithMessage.
    ///         Set via setMessageTransmitter(). Optional — only needed for atomic settle.
    address public messageTransmitter;

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
        // Record pending position so settle can decrement totalDeployed on return.
        pendingCrossChain[nonce] = amount;

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

    /**
     * @notice Atomic cross-chain settle: calls MessageTransmitter.receiveMessage in the same
     *         transaction, measures the exact USDC balance delta, and books the result.
     * @dev    J1: Replaces the old snapshot-based approach. Nothing else can move the USDC
     *         balance inside a single call, so `received` is always exact.
     *         Also verifies that the decoded mintRecipient is this vault and that the
     *         message-encoded amount matches the actual balance delta.
     * @param nonce        CCTP burn nonce from the original deployCrossChain.
     * @param message      Attested CCTP message bytes (returned by the CCTP attestation API).
     * @param attestation  Corresponding attestation bytes.
     */
    function settleCrossChainWithMessage(
        uint64 nonce,
        bytes calldata message,
        bytes calldata attestation
    ) external onlyManagerOrOwner {
        uint256 sent = pendingCrossChain[nonce];
        if (sent == 0) revert NonceMismatch(nonce);

        // Decode and validate the message before minting.
        // feeExecuted > 0 on CCTP V2 Fast Transfer — the transmitter mints (amount - feeExecuted).
        (uint256 msgAmount, bytes32 mintRecipient, uint256 feeExecuted) =
            CctpMessageDecoder.decodeBody(message);
        if (mintRecipient != bytes32(uint256(uint160(address(this))))) {
            revert WrongMintRecipient(mintRecipient);
        }

        // Net amount expected to be minted by the transmitter.
        // feeExecuted must be <= msgAmount (defensive: treat > as full fee coverage = 0 net).
        uint256 expectedNet = feeExecuted <= msgAmount ? msgAmount - feeExecuted : 0;

        // Snapshot balance, call receiveMessage (mints USDC to this vault), measure delta.
        uint256 balBefore = IERC20(asset()).balanceOf(address(this));
        IMessageTransmitterV2(messageTransmitter).receiveMessage(message, attestation);
        uint256 balAfter  = IERC20(asset()).balanceOf(address(this));
        uint256 received  = balAfter > balBefore ? balAfter - balBefore : 0;

        // Cross-check: the net expected amount must equal the actual minted amount.
        // This guards against fee mis-encoding and transmitter bugs.
        if (expectedNet != received) revert MessageAmountMismatch(expectedNet, received);

        // Emit fee cost so callers can observe the total cross-chain cost
        // (fee + any strategy shortfall = totalDeployed - received).
        if (feeExecuted > 0) {
            emit CrossChainFeeDeducted(nonce, feeExecuted);
        }

        _doSettle(nonce, sent, received);
    }

    /**
     * @notice Write off a lost cross-chain transfer (USDC never arrives or is unrecoverable).
     * @dev    J1: Degraded path — `received` MUST be 0. Books the full sent amount as a loss.
     *         Only callable by the owner (not the manager) to prevent accidental write-offs.
     * @param nonce  CCTP burn nonce from the original deployCrossChain.
     */
    function settleCrossChain(uint64 nonce, uint256 received) external onlyOwner {
        if (received != 0) revert WriteOffMustBeZero();
        uint256 sent = pendingCrossChain[nonce];
        if (sent == 0) revert NonceMismatch(nonce);
        _doSettle(nonce, sent, 0);
    }

    /// @dev Shared accounting for both settle paths.
    function _doSettle(uint64 nonce, uint256 sent, uint256 received) internal {
        delete pendingCrossChain[nonce];

        uint256 shortfall = sent > received ? sent - received : 0;
        // Decrement totalDeployed by the full sent amount. The received USDC tokens are
        // already in vault balance (minted by CCTP). Do NOT add received back — that would
        // double-count. Net NAV change = received - sent = -shortfall (immediate loss).
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

    function setMessageTransmitter(address transmitter) external onlyOwner {
        address previous = messageTransmitter;
        messageTransmitter = transmitter;
        emit MessageTransmitterUpdated(previous, transmitter);
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
