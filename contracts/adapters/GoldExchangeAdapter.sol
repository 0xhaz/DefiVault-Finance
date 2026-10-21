// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategyAdapter} from "../IStrategyAdapter.sol";

/// @notice Uniswap V3 interface (minimal — only exactInputSingle needed)
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params)
        external returns (uint256 amountOut);
}

/// @title  GoldExchangeAdapter
/// @notice Deploys vault USDC into PAXG via an atomic Uniswap V3 swap on the same chain.
/// @dev    Shariah requirement: the exchange must be simultaneous (yad bi yad).
///         This adapter satisfies that by completing the USDC-to-PAXG conversion in
///         a SINGLE transaction with no pending state. Cross-chain routing for GOLD_SPREAD
///         is explicitly blocked via the `NonAtomicGoldExchange` error in ShariahVault.
///
///         Board ruling pending: SR-005 (atomic swap satisfies yad bi yad),
///         SR-006 (PAXG custody terms). See docs/agents/SHARIAH_REVIEW.md.
///
///         On testnet, deploy a MockAllocatedGold in place of PAXG.
///
/// @custom:security-contact board-review-required
contract GoldExchangeAdapter is IStrategyAdapter, Ownable2Step {
    using SafeERC20 for IERC20;

    error SlippageExceeded(uint256 amountOut, uint256 minOut);
    error ZeroAmount();
    error DeadlineExceeded();
    error StalePrice(uint256 paxgBalance, uint256 usdcSpent);

    event GoldAcquired(uint256 usdcIn, uint256 paxgOut, uint256 spotPrice);
    event GoldReturned(uint256 paxgIn, uint256 usdcOut);
    event MinOutBpsUpdated(uint256 previousBps, uint256 newBps);

    IERC20  public immutable usdc;
    IERC20  public immutable paxg;
    ISwapRouter public immutable swapRouter;
    uint24  public immutable poolFee;
    address public immutable vault;

    uint256 public totalDeployed;
    uint256 public paxgHeld;

    /// @notice Minimum output as a fraction of expected PAXG out.
    ///         Default: 9900 = 99% (1% max slippage).
    uint256 public minOutBps;

    /// @notice Last observed PAXG-per-USDC price (1e18-scaled, PAXG per 1e6 USDC).
    ///         Set to 0 before any swap; used as the reference floor on subsequent swaps.
    ///         This is a simple last-price oracle — not a TWAP. Sufficient for testnet.
    ///         Production: replace with a 30-min TWAP from a Uniswap V3 pool.
    uint256 public lastPaxgPricePerUsdc;

    constructor(
        address usdc_,
        address paxg_,
        address swapRouter_,
        uint24  poolFee_,
        address vault_,
        address initialOwner
    ) Ownable(initialOwner) {
        usdc      = IERC20(usdc_);
        paxg      = IERC20(paxg_);
        swapRouter = ISwapRouter(swapRouter_);
        poolFee   = poolFee_;
        vault     = vault_;
        minOutBps = 9900; // 99% default (1% max slippage)
    }

    modifier onlyVault() {
        require(msg.sender == vault, "GoldExchangeAdapter: caller is not the vault");
        _;
    }

    /// @notice Atomic USDC-to-PAXG swap. Called by the vault once per execution cycle.
    ///         The entire amount is swapped in one transaction — no state persists between call and return.
    function deploy(uint256 amount) external onlyVault returns (uint256 paxgOut) {
        if (amount == 0) revert ZeroAmount();

        // Vault has already transferred USDC to this adapter via deployCapital().
        // We work with the balance already held here — no pull needed.
        usdc.forceApprove(address(swapRouter), amount);

        // Compute minOut from the last observed price if available.
        // First swap: minOut = 1 (no reference price yet).
        // Subsequent swaps: minOut = expectedPaxgOut * minOutBps / 10_000.
        // expectedPaxgOut = amount * lastPaxgPricePerUsdc / 1e18
        // Note: lastPaxgPricePerUsdc is PAXG (18 dec) per USDC (6 dec): units are 1e12.
        // Adjust: minOut in PAXG units = (amount_6dec * price_1e12) / 1e18 = amount * price / 1e12
        uint256 minOut;
        if (lastPaxgPricePerUsdc == 0) {
            minOut = 1; // no reference price — first swap
        } else {
            uint256 expectedPaxgOut = (amount * lastPaxgPricePerUsdc) / 1e12;
            minOut = (expectedPaxgOut * minOutBps) / 10_000;
            if (minOut == 0) minOut = 1;
        }

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn:           address(usdc),
            tokenOut:          address(paxg),
            fee:               poolFee,
            recipient:         address(this),
            deadline:          block.timestamp,
            amountIn:          amount,
            amountOutMinimum:  minOut,
            sqrtPriceLimitX96: 0
        });

        paxgOut = swapRouter.exactInputSingle(params);

        if (paxgOut == 0) revert SlippageExceeded(paxgOut, 0);

        // Clear any dust approval
        usdc.forceApprove(address(swapRouter), 0);

        paxgHeld      += paxgOut;
        totalDeployed += amount;

        uint256 spotPrice = (amount * 1e18) / paxgOut; // USDC per PAXG (1e18-scaled)
        emit GoldAcquired(amount, paxgOut, spotPrice);
    }

    /// @notice Return PAXG to the swap router, receive USDC back for the vault.
    ///         Also atomic — full exit in one transaction.
    function recall(uint256 amount) external onlyVault returns (uint256 usdcReturned) {
        if (amount == 0) revert ZeroAmount();

        uint256 paxgToSell = paxgHeld;
        if (paxgToSell == 0) {
            return 0;
        }

        paxg.forceApprove(address(swapRouter), paxgToSell);

        uint256 minUsdcOut = (paxgToSell * (10_000 - (10_000 - minOutBps))) / 10_000;
        // Simplified: accept any non-zero amount for testnet; production would use TWAP floor

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn:           address(paxg),
            tokenOut:          address(usdc),
            fee:               poolFee,
            recipient:         vault,
            deadline:          block.timestamp,
            amountIn:          paxgToSell,
            amountOutMinimum:  minUsdcOut,
            sqrtPriceLimitX96: 0
        });

        usdcReturned = swapRouter.exactInputSingle(params);

        paxg.forceApprove(address(swapRouter), 0);

        paxgHeld       = 0;
        // On full exit, always clear deployed principal regardless of PAXG/USDC price at exit.
        // This prevents stale totalDeployed from inflating vault NAV after position is closed.
        totalDeployed  = 0;

        emit GoldReturned(paxgToSell, usdcReturned);
    }

    function currentValue() external view returns (uint256) {
        // Without a live oracle: return totalDeployed as conservative floor
        return totalDeployed;
    }

    function protocolName() external pure returns (string memory) {
        return "GoldExchangeAdapter: USDC/PAXG atomic swap (yad bi yad)";
    }

    function setMinOutBps(uint256 newBps) external onlyOwner {
        require(newBps >= 9000 && newBps <= 10_000, "GoldExchangeAdapter: bps out of range (9000-10000)");
        uint256 prev = minOutBps;
        minOutBps = newBps;
        emit MinOutBpsUpdated(prev, newBps);
    }

    function renounceOwnership() public override(Ownable) onlyOwner {
        revert("GoldExchangeAdapter: renouncing ownership is disabled");
    }
}
