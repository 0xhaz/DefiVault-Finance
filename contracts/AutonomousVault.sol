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
    event CrossChainSettled(uint64 indexed nonce, uint256 amount);
    event TokenMessengerUpdated(address indexed previousMessenger, address indexed newMessenger);

    address public manager;
    bool public paused;
    uint256 public maxAllocationBps = 8_000;
    uint256 public totalDeployed;
    address public tokenMessenger;
    /// @dev The CCTP domain of THIS chain (set in constructor, used to guard deployCrossChain)
    uint32 public immutable sourceDomain;
    /// @dev Tracks pending crosschain positions: nonce => amount, for settlement accounting
    mapping(uint64 => uint256) public pendingCrossChain;

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

    function totalAssets() public view virtual override returns (uint256) {
        return super.totalAssets() + totalDeployed;
    }

    function deployCapital(address strategy, uint256 amount, bytes calldata data) external virtual onlyManagerOrOwner {
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
    ) external onlyManagerOrOwner {
        if (tokenMessenger == address(0)) revert CrossChainNotConfigured();
        // Use immutable sourceDomain (not a hardcoded constant) to block same-chain burns
        if (destinationDomain == sourceDomain) revert SameDomainDeploy();

        uint256 currentAssets = totalAssets();
        uint256 maxDeployable = (currentAssets * maxAllocationBps) / 10_000;
        if (totalDeployed + amount > maxDeployable) revert AllocationExceedsLimit();

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
        // Record pending position so settleCrossChain can decrement totalDeployed on return
        pendingCrossChain[nonce] = amount;

        emit CapitalDeployedCrossChain(destinationDomain, recipient, amount, nonce);
    }

    function returnCapital(address strategy, uint256 amount) external onlyManagerOrOwner {
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
    function settleCrossChain(uint64 nonce) external onlyManagerOrOwner {
        uint256 amount = pendingCrossChain[nonce];
        if (amount == 0) revert NonceMismatch(nonce);
        delete pendingCrossChain[nonce];
        totalDeployed -= amount;
        emit CrossChainSettled(nonce, amount);
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
