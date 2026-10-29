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
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;
}

/// @notice CCTP V2 MessageTransmitter — only the function needed for atomic settle.
interface IMessageTransmitterV2 {
    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool success);
    function localDomain() external view returns (uint32);
}

/// @notice Decoder for native Circle MessageV2 / BurnMessageV2, not a compatibility envelope.
/// @dev All fields are big-endian. Header offsets (148 bytes before body):
///      0: version uint32 (1); 4: sourceDomain uint32; 8: destinationDomain uint32;
///      12: nonce bytes32; 44: sender bytes32 (remote TokenMessenger);
///      76: recipient bytes32 (local TokenMessenger); 108: destinationCaller bytes32;
///      140: minFinalityThreshold uint32; 144: finalityThresholdExecuted uint32; 148: body.
///      Body offsets (228 fixed bytes, relative to 148):
///      0: version uint32 (1); 4: burnToken bytes32; 36: mintRecipient bytes32;
///      68: amount uint256; 100: messageSender bytes32; 132: maxFee uint256;
///      164: feeExecuted uint256; 196: expirationBlock uint256; 228: optional hookData.
library CctpMessageDecoder {
    uint256 internal constant HEADER_LEN = 148;
    uint256 internal constant MIN_MESSAGE_LEN = 148 + 228;

    error InvalidMessageRange(uint256 length, uint256 offset, uint256 size);
    error WrongHeaderVersion(uint32 actual);
    error WrongBodyVersion(uint32 actual);

    struct Header {
        uint32 sourceDomain;
        uint32 destinationDomain;
        bytes32 nonce;
        bytes32 sender;
        bytes32 recipient;
        bytes32 destinationCaller;
    }

    /// @dev Subtraction-based bounds checks also reject oversized offsets without arithmetic panic.
    function _field(bytes calldata message, uint256 offset, uint256 size)
        internal pure returns (bytes calldata)
    {
        if (offset > message.length || size > message.length - offset) {
            revert InvalidMessageRange(message.length, offset, size);
        }
        return message[offset:offset + size];
    }

    function decodeHeader(bytes calldata message) internal pure returns (Header memory h) {
        _field(message, 0, HEADER_LEN);
        uint32 version = uint32(bytes4(_field(message, 0, 4)));
        if (version != 1) revert WrongHeaderVersion(version);
        h.sourceDomain = uint32(bytes4(_field(message, 4, 4)));
        h.destinationDomain = uint32(bytes4(_field(message, 8, 4)));
        h.nonce = bytes32(_field(message, 12, 32));
        h.sender = bytes32(_field(message, 44, 32));
        h.recipient = bytes32(_field(message, 76, 32));
        h.destinationCaller = bytes32(_field(message, 108, 32));
    }

    function decodeBody(bytes calldata message)
        internal pure returns (uint256 amount, bytes32 mintRecipient, uint256 feeExecuted)
    {
        _field(message, 0, MIN_MESSAGE_LEN);
        uint32 version = uint32(bytes4(_field(message, HEADER_LEN, 4)));
        if (version != 1) revert WrongBodyVersion(version);
        mintRecipient = bytes32(_field(message, HEADER_LEN + 36, 32));
        amount = uint256(bytes32(_field(message, HEADER_LEN + 68, 32)));
        feeExecuted = uint256(bytes32(_field(message, HEADER_LEN + 164, 32)));
    }
}

/// @notice ERC-4626 vault with native Circle CCTP V2 burns and atomic return settlement.
/// @dev Pending uint64 keys are local position IDs; inbound Circle nonces are bytes32.
contract AutonomousVault is ERC4626, Ownable2Step {
    using SafeERC20 for IERC20;

    error Paused();
    error NotManager();
    error AllocationExceedsLimit();
    error InvalidBps();
    error CrossChainNotConfigured();
    error SameDomainDeploy();
    error NonceMismatch(uint64 expected, uint64 actual);
    error ZeroAddress();
    error WrongDestinationDomain(uint32 expected, uint32 actual);
    error WrongSourceDomain(uint32 expected, uint32 actual);
    error WrongMessageRecipient(bytes32 actual);
    error InboundAlreadyConsumed();
    error WrongDestinationCaller(bytes32 actual);
    error LocalDomainMismatch(uint32 expected, uint32 actual);
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
    error InvalidCrossChainMinFinality();
    error RemoteMessengerNotSet(uint32 domain);
    error WrongRemoteSender(bytes32 expected, bytes32 actual);
    error MessageReceiveFailed();

    event CrossChainMinFinalityUpdated(uint32 previous, uint32 updated);
    event CrossChainMaxFeeBpsUpdated(uint256 previous, uint256 updated);
    event RemoteTokenMessengerUpdated(uint32 indexed domain, bytes32 messenger);

    uint64 public crossChainPositionCounter;
    uint32 public crossChainMinFinality = 2000;
    uint256 public crossChainMaxFeeBps;
    uint256 public constant MAX_CROSS_CHAIN_FEE_BPS = 100;
    mapping(uint32 => bytes32) public remoteTokenMessenger;

    function setCrossChainMinFinality(uint32 finality) external onlyOwner {
        if (finality != 1000 && finality != 2000) revert InvalidCrossChainMinFinality();
        emit CrossChainMinFinalityUpdated(crossChainMinFinality, finality);
        crossChainMinFinality = finality;
    }

    function setCrossChainMaxFeeBps(uint256 bps) external onlyOwner {
        if (bps > MAX_CROSS_CHAIN_FEE_BPS) revert InvalidBps();
        emit CrossChainMaxFeeBpsUpdated(crossChainMaxFeeBps, bps);
        crossChainMaxFeeBps = bps;
    }

    function setRemoteTokenMessenger(uint32 domain, bytes32 messenger) external onlyOwner {
        if (messenger == bytes32(0)) revert ZeroAddress();
        remoteTokenMessenger[domain] = messenger;
        emit RemoteTokenMessengerUpdated(domain, messenger);
    }

    event ManagerUpdated(address indexed previousManager, address indexed newManager);
    event MaxAllocationBpsUpdated(uint256 previousBps, uint256 newBps);
    event PauseUpdated(bool paused);
    event CapitalDeployed(address indexed strategy, uint256 amount);
    event CapitalReturned(address indexed strategy, uint256 amount);
    event CapitalRecalledFromAdapter(address indexed adapter, uint256 requested, uint256 returned);
    /// @notice positionId is a local pending-position key, not Circle's offchain bytes32 nonce.
    event CapitalDeployedCrossChain(
        uint32 indexed destinationDomain,
        bytes32 indexed recipient,
        uint256 amount,
        uint64 positionId
    );
    event CrossChainSettled(uint64 indexed positionId, uint256 amount, uint256 shortfall);
    /// @notice Emitted when a CCTP Fast Transfer fee is deducted from the minted amount.
    ///         `feeExecuted` is booked as part of the cross-chain cost alongside any strategy loss.
    event CrossChainFeeDeducted(uint64 indexed positionId, uint256 feeExecuted);
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
    /// @dev Constructor domain is the fallback for transmitters without localDomain().
    uint32 public localDomain;
    /// @dev Tracks pending cross-chain positions: local positionId => amount.
    mapping(uint64 => uint256) public pendingCrossChain;
    mapping(uint64 => uint32) public pendingCrossChainDestinationDomain;
    mapping(uint32 => mapping(bytes32 => bool)) public consumedInbound;
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
        localDomain = sourceDomain_;
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
        uint256 duration = profitUnlockPeriod;
        if (duration == 0 || unlockedAt < duration) return 0;
        uint256 start = unlockedAt - duration;
        if (start > block.timestamp) return 0;
        uint256 elapsed = block.timestamp - start;
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
     *      Derived vaults decide which external entry points may lock profit.
     */
    function _lockProfitInternal(uint256 amount) internal {
        uint256 remaining = _currentLockedProfit();
        lockedProfit = remaining + amount;
        unlockedAt   = block.timestamp + profitUnlockPeriod;
        emit ProfitLocked(amount, unlockedAt);
    }

    /// @notice Owner updates profit unlock period (board-settable; max 14 days).
    function setProfitUnlockPeriod(uint256 period) external onlyOwner {
        if (period > MAX_PROFIT_UNLOCK_PERIOD) revert InvalidUnlockPeriod();
        uint256 remaining = _currentLockedProfit();
        lockedProfit = remaining;
        profitUnlockPeriod = period;
        if (remaining > 0) unlockedAt = block.timestamp + period;
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

        CctpSettlementLogic.burn(
            asset(), tokenMessenger, destinationDomain, recipient, amount,
            crossChainMaxFeeBps, crossChainMinFinality
        );
        // Preserve the position-counter update before clearing the burn allowance.
        uint64 positionId = ++crossChainPositionCounter;
        IERC20(asset()).forceApprove(tokenMessenger, 0);
        totalDeployed += amount;
        totalPendingCrossChain += amount;
        pendingCrossChain[positionId] = amount;
        pendingCrossChainDestinationDomain[positionId] = destinationDomain;
        emit CapitalDeployedCrossChain(destinationDomain, recipient, amount, positionId);
    }

    function returnCapital(address strategy, uint256 amount) external virtual onlyManagerOrOwner {
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
    function recallCapital(address adapter, uint256 amount) external virtual onlyManagerOrOwner {
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
     * @param positionId   Local pending-position ID emitted by deployCrossChain, not a CCTP nonce.
     * @param message      Attested CCTP message bytes (returned by the CCTP attestation API).
     * @param attestation  Corresponding attestation bytes.
     */
    function settleCrossChainWithMessage(
        uint64 positionId,
        bytes calldata message,
        bytes calldata attestation
    ) external onlyManagerOrOwner {
        uint256 sent = pendingCrossChain[positionId];
        if (sent == 0) revert NonceMismatch(positionId, 0);

        if (messageTransmitter == address(0)) revert CrossChainNotConfigured();
        uint256 received = CctpSettlementLogic.receiveSettlement(
            _settlementConfig(positionId), remoteTokenMessenger, consumedInbound,
            positionId, message, attestation
        );
        _doSettle(positionId, sent, received);
    }

    /**
     * @notice Write off a lost cross-chain transfer (USDC never arrives or is unrecoverable).
     * @dev    J1: Degraded path — `received` MUST be 0. Books the full sent amount as a loss.
     *         Only callable by the owner (not the manager) to prevent accidental write-offs.
     * @param positionId  Local pending-position ID emitted by deployCrossChain.
     */
    function settleCrossChain(uint64 positionId, uint256 received) external onlyOwner {
        if (received != 0) revert WriteOffMustBeZero();
        uint256 sent = pendingCrossChain[positionId];
        if (sent == 0) revert NonceMismatch(positionId, 0);
        _doSettle(positionId, sent, 0);
    }

    /// @dev Values are passed explicitly; mappings retain their original storage roots.
    function _settlementConfig(uint64 positionId) internal view returns (CctpSettlementLogic.Config memory) {
        return CctpSettlementLogic.Config(
            asset(), messageTransmitter, tokenMessenger, localDomain,
            pendingCrossChainDestinationDomain[positionId]
        );
    }

    function _validateSettlementHeader(uint64 positionId, bytes calldata message) internal view {
        CctpSettlementLogic.validateHeader(_settlementConfig(positionId), remoteTokenMessenger, message);
    }

    function _consumeInbound(bytes calldata message) internal {
        CctpSettlementLogic.consumeInbound(consumedInbound, message);
    }

    /// @dev Shared accounting for both settle paths.
    function _doSettle(uint64 positionId, uint256 sent, uint256 received) internal {
        delete pendingCrossChain[positionId];
        delete pendingCrossChainDestinationDomain[positionId];

        uint256 shortfall = sent > received ? sent - received : 0;
        // Decrement totalDeployed by the full sent amount. The received USDC tokens are
        // already in vault balance (minted by CCTP). Do NOT add received back — that would
        // double-count. Net NAV change = received - sent = -shortfall (immediate loss).
        totalDeployed          = totalDeployed >= sent ? totalDeployed - sent : 0;
        totalPendingCrossChain = totalPendingCrossChain >= sent ? totalPendingCrossChain - sent : 0;

        emit CrossChainSettled(positionId, received, shortfall);
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
        if (messenger == address(0)) revert ZeroAddress();
        address previous = tokenMessenger;
        tokenMessenger = messenger;
        emit TokenMessengerUpdated(previous, messenger);
    }

    event LocalDomainUpdated(uint32 domain);

    function setLocalDomain(uint32 domain) external onlyOwner {
        if (messageTransmitter == address(0)) revert ZeroAddress();
        (bool ok, bytes memory data) = messageTransmitter.staticcall(abi.encodeWithSignature("localDomain()"));
        if (ok && data.length == 32) {
            uint32 reported = abi.decode(data, (uint32));
            if (domain != reported) revert LocalDomainMismatch(reported, domain);
        }
        localDomain = domain; // Domain zero is valid.
        emit LocalDomainUpdated(domain);
    }

    function setMessageTransmitter(address transmitter) external onlyOwner {
        if (transmitter == address(0)) revert ZeroAddress();
        (bool ok, bytes memory data) = transmitter.staticcall(abi.encodeWithSignature("localDomain()"));
        localDomain = ok && data.length == 32 ? abi.decode(data, (uint32)) : sourceDomain;
        emit LocalDomainUpdated(localDomain);
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

/// @dev Linked CCTP execution in the vault's context; no independent storage or authority.
library CctpSettlementLogic {
    using SafeERC20 for IERC20;

    struct Config {
        address asset;
        address transmitter;
        address messenger;
        uint32 fallbackDomain;
        uint32 expectedSource;
    }

    function burn(
        address token, address messenger, uint32 destinationDomain, bytes32 recipient,
        uint256 amount, uint256 maxFeeBps, uint32 minFinality
    ) external {
        IERC20(token).forceApprove(messenger, amount);
        ITokenMessenger(messenger).depositForBurn(
            amount, destinationDomain, recipient, token, bytes32(0),
            (amount * maxFeeBps) / 10_000, minFinality
        );
    }

    function validateHeader(
        Config memory c, mapping(uint32 => bytes32) storage remoteMessenger, bytes calldata message
    ) external view {
        _validateHeader(c, remoteMessenger, message);
    }

    function _validateHeader(
        Config memory c, mapping(uint32 => bytes32) storage remoteMessenger, bytes calldata message
    ) private view {
        CctpMessageDecoder.Header memory h = CctpMessageDecoder.decodeHeader(message);
        uint32 domain = c.fallbackDomain;
        (bool ok, bytes memory data) = c.transmitter.staticcall(abi.encodeWithSignature("localDomain()"));
        if (ok && data.length == 32) domain = abi.decode(data, (uint32));
        if (h.destinationDomain != domain) revert AutonomousVault.WrongDestinationDomain(domain, h.destinationDomain);
        if (h.sourceDomain != c.expectedSource) revert AutonomousVault.WrongSourceDomain(c.expectedSource, h.sourceDomain);
        if (h.recipient != bytes32(uint256(uint160(c.messenger)))) revert AutonomousVault.WrongMessageRecipient(h.recipient);
        if (h.destinationCaller != bytes32(uint256(uint160(address(this))))) {
            revert AutonomousVault.WrongDestinationCaller(h.destinationCaller);
        }
        bytes32 expectedSender = remoteMessenger[h.sourceDomain];
        if (expectedSender == bytes32(0)) revert AutonomousVault.RemoteMessengerNotSet(h.sourceDomain);
        if (h.sender != expectedSender) revert AutonomousVault.WrongRemoteSender(expectedSender, h.sender);
    }

    function consumeInbound(
        mapping(uint32 => mapping(bytes32 => bool)) storage consumed, bytes calldata message
    ) external {
        _consumeInbound(consumed, message);
    }

    function _consumeInbound(
        mapping(uint32 => mapping(bytes32 => bool)) storage consumed, bytes calldata message
    ) private {
        CctpMessageDecoder.Header memory h = CctpMessageDecoder.decodeHeader(message);
        if (consumed[h.sourceDomain][h.nonce]) revert AutonomousVault.InboundAlreadyConsumed();
        consumed[h.sourceDomain][h.nonce] = true;
    }

    function receiveSettlement(
        Config memory c,
        mapping(uint32 => bytes32) storage remoteMessenger,
        mapping(uint32 => mapping(bytes32 => bool)) storage consumed,
        uint64 positionId, bytes calldata message, bytes calldata attestation
    ) external returns (uint256 received) {
        _validateHeader(c, remoteMessenger, message);
        (uint256 msgAmount, bytes32 mintRecipient, uint256 feeExecuted) = CctpMessageDecoder.decodeBody(message);
        if (mintRecipient != bytes32(uint256(uint160(address(this))))) {
            revert AutonomousVault.WrongMintRecipient(mintRecipient);
        }
        _consumeInbound(consumed, message);
        uint256 expectedNet = feeExecuted <= msgAmount ? msgAmount - feeExecuted : 0;
        received = _receive(c, message, attestation, expectedNet);
        if (feeExecuted > 0) emit AutonomousVault.CrossChainFeeDeducted(positionId, feeExecuted);
    }

    function _receive(Config memory c, bytes calldata message, bytes calldata attestation, uint256 expectedNet)
        private returns (uint256 received)
    {
        uint256 balBefore = IERC20(c.asset).balanceOf(address(this));
        if (!IMessageTransmitterV2(c.transmitter).receiveMessage(message, attestation)) {
            revert AutonomousVault.MessageReceiveFailed();
        }
        uint256 balAfter = IERC20(c.asset).balanceOf(address(this));
        received = balAfter > balBefore ? balAfter - balBefore : 0;
        if (expectedNet != received) revert AutonomousVault.MessageAmountMismatch(expectedNet, received);
    }
}
