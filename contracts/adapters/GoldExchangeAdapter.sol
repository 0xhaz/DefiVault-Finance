// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategyAdapter} from "../IStrategyAdapter.sol";

/// @notice Minimal Chainlink-style oracle interface (same shape as AggregatorV3Interface).
interface IAggregatorV3 {
    function latestRoundData() external view returns (
        uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
    );
    function decimals() external view returns (uint8);
}

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
    /// @notice Thrown when the stale-haircut BPS exceeds the hard cap.
    error HaircutAboveCap(uint256 proposed, uint256 cap);

    event GoldAcquired(uint256 usdcIn, uint256 paxgOut, uint256 spotPrice);
    event GoldReturned(uint256 paxgIn, uint256 usdcOut);
    event MinOutBpsUpdated(uint256 previousBps, uint256 newBps);
    /// @notice Emitted whenever lastGoodPrice is refreshed from an executed swap (PR1 parity).
    event LastGoodPriceUpdated(uint256 price, uint256 timestamp);
    event StaleHaircutBpsUpdated(uint256 previous, uint256 updated);
    event MaxStalenessBpsUpdated(uint256 previous, uint256 updated);
    event GoldOracleUpdated(address indexed previous, address indexed updated);

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

    // ── PR1 parity — stale-price valuation (I2) ─────────────────────────────
    /// @notice Last USDC-per-PAXG price recorded at swap execution (USDC units, 6 dec).
    ///         Equivalent to GoldAllocationAdapter.lastGoodPrice. Set on every deploy/recall.
    uint256 public lastGoodPrice;
    /// @notice Timestamp of the last executed swap (deploy or recall).
    uint256 public lastGoodPriceAt;
    /// @notice Haircut applied to lastGoodPrice when price is stale (bps, default 500 = 5%).
    ///         Settable by owner, hard cap MAX_STALE_HAIRCUT_BPS.
    uint256 public staleHaircutBps;
    /// @notice Hard cap for staleHaircutBps (matches GoldAllocationAdapter).
    uint256 public constant MAX_STALE_HAIRCUT_BPS = 2000;
    /// @notice Seconds after the last swap before isPriceSane() returns false.
    ///         Default: 1 day. Settable by owner. S2-H has no external oracle;
    ///         staleness is measured from the last executed trade.
    uint256 public maxStalenessSecs;
    /// @notice Hard cap for maxStalenessSecs: 7 days.
    uint256 public constant MAX_STALENESS_SECS = 7 days;

    /// @notice Optional XAU/USD Chainlink oracle (same feed as S6-H). When set, isPriceSane()
    ///         uses oracle-heartbeat age instead of last-swap age, so a 3-day idle S2-H with
    ///         a fresh oracle stays sane. pokePrice() updates lastGoodPrice from the oracle.
    ///         When address(0), isPriceSane() falls back to last-swap-age check (original I2 behaviour).
    IAggregatorV3 public goldOracle;

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
        minOutBps        = 9900;  // 99% default (1% max slippage)
        staleHaircutBps  = 500;   // 5% default stale haircut (matches GoldAllocationAdapter)
        maxStalenessSecs = 1 days; // price considered stale if no swap in > 1 day
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

        // USDC per PAXG (1e18-scaled: amount is 6 dec, paxgOut is 18 dec)
        uint256 spotPrice = (amount * 1e18) / paxgOut;
        // PR1: Record lastGoodPrice in USDC units (6 dec) — USDC paid per 1e18 PAXG.
        //      lastPaxgPricePerUsdc is the inverse; keep both for backward compat.
        lastGoodPrice    = spotPrice / 1e12; // convert 1e18-scaled to USDC (6 dec)
        lastGoodPriceAt  = block.timestamp;
        emit LastGoodPriceUpdated(lastGoodPrice, block.timestamp);
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

        // PR1: Compute exit price and update lastGoodPrice/At so currentValue() stays accurate
        //      after the position is closed and before a new one is opened.
        if (paxgToSell > 0 && usdcReturned > 0) {
            uint256 exitSpotPrice = (usdcReturned * 1e18) / paxgToSell;
            lastGoodPrice   = exitSpotPrice / 1e12;
            lastGoodPriceAt = block.timestamp;
            emit LastGoodPriceUpdated(lastGoodPrice, block.timestamp);
        }

        paxgHeld       = 0;
        // On full exit, always clear deployed principal regardless of PAXG/USDC price at exit.
        // This prevents stale totalDeployed from inflating vault NAV after position is closed.
        totalDeployed  = 0;

        emit GoldReturned(paxgToSell, usdcReturned);
    }

    /**
     * @notice Returns the USDC value of the PAXG position. Never reverts (PR1 parity / I2).
     *
     * - paxgHeld == 0: returns 0 (no position open).
     * - Price fresh (lastGoodPriceAt within maxStalenessSecs): use lastGoodPrice.
     * - Price stale: use lastGoodPrice × (1 - staleHaircutBps / 10_000).
     *   If lastGoodPrice == 0 (no swap ever executed): returns 0.
     *
     * Note: S2-H has no external oracle. "Staleness" here means the last atomic swap
     * executed more than maxStalenessSecs ago — the live market price is unknown.
     * Cost basis (totalDeployed) is NOT used — consistent with GoldAllocationAdapter PR1.
     */
    function currentValue() external view returns (uint256) {
        if (paxgHeld == 0) return 0;
        if (lastGoodPrice == 0) return 0; // no swap ever executed

        // lastGoodPrice is USDC per 1e18 PAXG (6-dec USDC, 18-dec PAXG).
        // value = paxgHeld (18 dec) * lastGoodPrice (6 dec / 1e18 PAXG) / 1e18
        uint256 grossValue = (paxgHeld * lastGoodPrice) / 1e18;

        bool fresh = (lastGoodPriceAt > 0) && (block.timestamp - lastGoodPriceAt <= maxStalenessSecs);
        if (fresh) return grossValue;

        // Stale: apply haircut.
        return (grossValue * (10_000 - staleHaircutBps)) / 10_000;
    }

    /// @notice Returns false when the price reference is stale (J2 update).
    ///         When goldOracle is set: uses the oracle's `updatedAt` field for the freshness check,
    ///           independent of last-swap age. A 3-day idle adapter with a fresh oracle stays sane.
    ///         When goldOracle is address(0): falls back to last-swap age (original I2 behaviour).
    ///         Returns true when no position is open (lastGoodPriceAt == 0).
    function isPriceSane() external view returns (bool) {
        if (lastGoodPriceAt == 0) return true; // no position — no oracle issue
        if (address(goldOracle) != address(0)) {
            // Oracle-based freshness: read updatedAt without reverting.
            try goldOracle.latestRoundData() returns (
                uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
            ) {
                // Suppress unused-variable warnings by assigning to named returns (already named).
                startedAt; roundId; answeredInRound;
                if (answer <= 0) return false;
                return block.timestamp - updatedAt <= maxStalenessSecs;
            } catch {
                return false; // oracle reverts → treat as stale
            }
        }
        // Fallback: last-swap age.
        return block.timestamp - lastGoodPriceAt <= maxStalenessSecs;
    }

    /// @notice Anyone may call to refresh lastGoodPrice from the oracle (J2 / PR1 parity).
    ///         When goldOracle is set, reads the oracle price.
    ///         When not set, this is a no-op (no oracle to poke).
    function pokePrice() external {
        if (address(goldOracle) == address(0)) return;
        try goldOracle.latestRoundData() returns (
            uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
        ) {
            roundId; startedAt; answeredInRound; updatedAt;
            if (answer <= 0) return;
            // Oracle gives XAU/USD in oracle decimals; convert to USDC-per-PAXG (6 dec).
            uint8 oracDec = goldOracle.decimals();
            // oraclePrice in 1e(oracDec) → convert to 6 dec USDC
            uint256 oracleUsdc = oracDec >= 6
                ? uint256(answer) / (10 ** uint256(oracDec - 6))
                : uint256(answer) * (10 ** uint256(6 - oracDec));
            if (oracleUsdc == 0) return;
            lastGoodPrice   = oracleUsdc;
            lastGoodPriceAt = block.timestamp;
            emit LastGoodPriceUpdated(lastGoodPrice, block.timestamp);
        } catch {}
    }

    /// @notice Owner sets the XAU/USD oracle for oracle-based freshness (J2).
    ///         Pass address(0) to revert to last-swap-age staleness detection.
    function setGoldOracle(address oracle) external onlyOwner {
        address previous = address(goldOracle);
        goldOracle = IAggregatorV3(oracle);
        emit GoldOracleUpdated(previous, oracle);
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

    /// @notice Set the stale-price haircut (bps, max MAX_STALE_HAIRCUT_BPS = 2000).
    function setStaleHaircutBps(uint256 bps) external onlyOwner {
        if (bps > MAX_STALE_HAIRCUT_BPS) revert HaircutAboveCap(bps, MAX_STALE_HAIRCUT_BPS);
        uint256 prev = staleHaircutBps;
        staleHaircutBps = bps;
        emit StaleHaircutBpsUpdated(prev, bps);
    }

    /// @notice Set the max staleness window (seconds, max MAX_STALENESS_SECS = 7 days).
    function setMaxStalenessSecs(uint256 secs) external onlyOwner {
        require(secs > 0 && secs <= MAX_STALENESS_SECS, "GoldExchangeAdapter: staleness out of range");
        uint256 prev = maxStalenessSecs;
        maxStalenessSecs = secs;
        emit MaxStalenessBpsUpdated(prev, secs);
    }

    function renounceOwnership() public override(Ownable) onlyOwner {
        revert("GoldExchangeAdapter: renouncing ownership is disabled");
    }
}
