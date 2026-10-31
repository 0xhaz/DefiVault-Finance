// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStrategyAdapter} from "../IStrategyAdapter.sol";

/// @dev Mandatory atomic cost-basis retirement after an adapter-side gold sale.
interface IGoldExchangeVaultAccounting {
    function retireGoldPrincipal(uint256 soldTokens, uint256 heldBefore) external;
}

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
contract GoldExchangeAdapter is IStrategyAdapter, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error AmountExceedsHeld(uint256 requested, uint256 held);
    error EmergencyExitDisabled();
    error OracleLockedWhileEmergencyEnabled();
    error EmergencyExitRequiresProposal();
    error EmergencyExitProposalExists();
    error NoEmergencyExitProposal();
    error EmergencyExitNotReady(uint256 executeAfter);
    error EmergencyExitExpired(uint256 expiresAt);

    uint256 public constant EMERGENCY_EXIT_DELAY = 1 hours;
    uint256 public constant EMERGENCY_EXIT_WINDOW = 24 hours;
    uint256 public constant EMERGENCY_FLOOR_BPS = 2000;

    struct PendingEmergencyExit {
        uint256 tokenAmount;
        uint256 minUsdcOut;
        uint256 executeAfter;
        uint256 expiresAt;
    }
    PendingEmergencyExit public pendingEmergencyExit;

    event EmergencyExitProposed(uint256 tokenAmount, uint256 minUsdcOut, uint256 executeAfter, uint256 expiresAt);
    event EmergencyExitCancelled();

    event EmergencyExit(address indexed caller, uint256 tokenSold, uint256 usdcReturned, uint256 minUsdcOut);

    /// @notice Explicit-minimum exits are disabled until a timelocked proposal executes.
    bool public emergencyExitEnabled;
    bytes32 public constant PARAM_EMERGENCY_EXIT_ENABLED = keccak256("emergencyExitEnabled");

    error SlippageExceeded(uint256 amountOut, uint256 minOut);
    error ZeroAmount();
    error DeadlineExceeded();
    error StalePrice(uint256 paxgBalance, uint256 usdcSpent);
    /// @notice Thrown when the stale-haircut BPS exceeds the hard cap.
    error HaircutAboveCap(uint256 proposed, uint256 cap);
    /// @notice Thrown when the constructor is called without a non-zero gold oracle address (K2).
    error OracleRequired();
    error StaleGoldPrice();

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

    uint256 public emergencySlippageBps = 1000;
    uint256 public constant MAX_EMERGENCY_SLIPPAGE_BPS = 2500;
    uint256 public constant TIMELOCK_DELAY = 30 days;
    bytes32 public constant PARAM_EMERGENCY_SLIPPAGE = keccak256("emergencySlippageBps");

    struct PendingChange {
        uint256 newValue;
        uint256 executeAfter;
        bool pending;
    }
    mapping(bytes32 => PendingChange) public pendingChanges;

    event ParamChangeProposed(bytes32 indexed paramId, uint256 newValue, uint256 executeAfter);
    event ParamChangeExecuted(bytes32 indexed paramId, uint256 newValue);
    event ParamChangeCancelled(bytes32 indexed paramId);
    event EmergencySlippageBpsUpdated(uint256 previous, uint256 updated);

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

    /// @notice Mandatory XAU/USD Chainlink oracle (K2 — address(0) reverts OracleRequired).
    ///         isPriceSane() uses the oracle's `updatedAt` heartbeat for the freshness check,
    ///         so a 3-day idle S2-H with a fresh oracle stays sane.
    ///         pokePrice() updates lastGoodPrice from the oracle.
    ///         On testnet, pass MockXauUsdAggregator.
    IAggregatorV3 public goldOracle;

    constructor(
        address usdc_,
        address paxg_,
        address swapRouter_,
        uint24  poolFee_,
        address vault_,
        address initialOwner,
        address goldOracle_ // K2: mandatory — pass the XAU/USD feed (or MockXauUsdAggregator on testnet)
    ) Ownable(initialOwner) {
        if (goldOracle_ == address(0)) revert OracleRequired();
        usdc      = IERC20(usdc_);
        paxg      = IERC20(paxg_);
        swapRouter = ISwapRouter(swapRouter_);
        poolFee   = poolFee_;
        vault     = vault_;
        goldOracle       = IAggregatorV3(goldOracle_);
        minOutBps        = 9900;  // 99% default (1% max slippage)
        staleHaircutBps  = 500;   // 5% default stale haircut (matches GoldAllocationAdapter)
        maxStalenessSecs = 1 days; // oracle heartbeat window (max 7 days)
    }

    modifier onlyVault() {
        require(msg.sender == vault, "GoldExchangeAdapter: caller is not the vault");
        _;
    }

    /// @notice Atomic USDC-to-PAXG swap. Called by the vault once per execution cycle.
    ///         The entire amount is swapped in one transaction — no state persists between call and return.
    function deploy(uint256 amount) external onlyVault nonReentrant returns (uint256 paxgOut) {
        if (amount == 0) revert ZeroAmount();

        // Vault has already transferred USDC to this adapter via deployCapital().
        // We work with the balance already held here — no pull needed.
        usdc.forceApprove(address(swapRouter), amount);

        (uint256 oraclePrice,) = _freshOraclePrice();
        if (oraclePrice == 0) revert StaleGoldPrice();
        uint256 minOut = ((amount * 1e18 / oraclePrice) * minOutBps) / 10_000;
        if (minOut == 0) minOut = 1;

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

        if (paxgOut < minOut) revert SlippageExceeded(paxgOut, minOut);

        // Clear any dust approval
        usdc.forceApprove(address(swapRouter), 0);

        paxgHeld      += paxgOut;
        totalDeployed += amount;

        // Price is 6-dec USDC per whole PAXG (1e18 token units), matching pokePrice().
        uint256 spotPrice = (amount * 1e18) / paxgOut;
        // PR1: Record lastGoodPrice in USDC units (6 dec) — USDC paid per 1e18 PAXG.
        lastGoodPrice    = spotPrice;
        lastGoodPriceAt  = block.timestamp;
        emit LastGoodPriceUpdated(lastGoodPrice, block.timestamp);
        emit GoldAcquired(amount, paxgOut, spotPrice);
    }

    /// @notice Return PAXG to the swap router, receive USDC back for the vault.
    ///         Also atomic — full exit in one transaction.
    function recall(uint256 amount) external onlyVault nonReentrant returns (uint256 usdcReturned) {
        if (amount == 0) revert ZeroAmount();

        uint256 paxgToSell = paxgHeld;
        if (paxgToSell == 0) {
            return 0;
        }

        paxg.forceApprove(address(swapRouter), paxgToSell);

        (uint256 oraclePrice,) = _freshOraclePrice();
        uint256 minUsdcOut;
        if (oraclePrice > 0) {
            minUsdcOut = Math.mulDiv(Math.mulDiv(paxgToSell, oraclePrice, 1e18), minOutBps, 10_000);
        } else {
            if (lastGoodPrice == 0) revert StaleGoldPrice();
            uint256 cachedValue = Math.mulDiv(paxgToSell, lastGoodPrice, 1e18);
            uint256 haircutValue = Math.mulDiv(cachedValue, 10_000 - staleHaircutBps, 10_000);
            minUsdcOut = Math.mulDiv(haircutValue, 10_000 - emergencySlippageBps, 10_000);
        }
        if (minUsdcOut == 0) minUsdcOut = 1;

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
        if (usdcReturned < minUsdcOut) revert SlippageExceeded(usdcReturned, minUsdcOut);

        paxg.forceApprove(address(swapRouter), 0);

        // PR1: Compute exit price and update lastGoodPrice/At so currentValue() stays accurate
        //      after the position is closed and before a new one is opened.
        if (paxgToSell > 0 && usdcReturned > 0) {
            uint256 exitSpotPrice = (usdcReturned * 1e18) / paxgToSell;
            // Exit price uses the same 6-dec USDC per whole PAXG unit as entry/oracle prices.
            lastGoodPrice   = exitSpotPrice;
            lastGoodPriceAt = block.timestamp;
            emit LastGoodPriceUpdated(lastGoodPrice, block.timestamp);
        }

        paxgHeld       = 0;
        // On full exit, always clear deployed principal regardless of PAXG/USDC price at exit.
        // This prevents stale totalDeployed from inflating vault NAV after position is closed.
        totalDeployed  = 0;

        emit GoldReturned(paxgToSell, usdcReturned);
    }

    /// @dev Retained ABI, but the one-call emergency sale is permanently disabled.
    function emergencyExit(uint256, uint256) external onlyOwner returns (uint256) {
        revert EmergencyExitRequiresProposal();
    }

    /// @notice Authorize one exact sale after one hour, valid for the following 24 hours.
    function proposeEmergencyExit(uint256 tokenAmount, uint256 minUsdcOut) external onlyOwner {
        if (!emergencyExitEnabled) revert EmergencyExitDisabled();
        if (pendingEmergencyExit.tokenAmount != 0) revert EmergencyExitProposalExists();
        if (tokenAmount == 0 || minUsdcOut == 0) revert ZeroAmount();
        if (tokenAmount > paxgHeld) revert AmountExceedsHeld(tokenAmount, paxgHeld);
        if (lastGoodPrice == 0) revert StaleGoldPrice();
        uint256 cachedValue = Math.mulDiv(tokenAmount, lastGoodPrice, 1e18);
        uint256 floor = Math.mulDiv(cachedValue, EMERGENCY_FLOOR_BPS, 10_000, Math.Rounding.Ceil);
        if (minUsdcOut < floor) revert SlippageExceeded(minUsdcOut, floor);
        uint256 executeAfter = block.timestamp + EMERGENCY_EXIT_DELAY;
        uint256 expiresAt = executeAfter + EMERGENCY_EXIT_WINDOW;
        pendingEmergencyExit = PendingEmergencyExit(tokenAmount, minUsdcOut, executeAfter, expiresAt);
        emit EmergencyExitProposed(tokenAmount, minUsdcOut, executeAfter, expiresAt);
    }

    function cancelEmergencyExit() external onlyOwner {
        if (pendingEmergencyExit.tokenAmount == 0) revert NoEmergencyExitProposal();
        delete pendingEmergencyExit;
        emit EmergencyExitCancelled();
    }

    function executeEmergencyExit() external onlyOwner nonReentrant returns (uint256 usdcReturned) {
        if (!emergencyExitEnabled) revert EmergencyExitDisabled();
        PendingEmergencyExit memory p = pendingEmergencyExit;
        if (p.tokenAmount == 0) revert NoEmergencyExitProposal();
        if (block.timestamp < p.executeAfter) revert EmergencyExitNotReady(p.executeAfter);
        if (block.timestamp > p.expiresAt) revert EmergencyExitExpired(p.expiresAt);
        uint256 tokenAmount = p.tokenAmount;
        uint256 minUsdcOut = p.minUsdcOut;
        uint256 heldBefore = paxgHeld;
        if (tokenAmount > heldBefore) revert AmountExceedsHeld(tokenAmount, heldBefore);
        delete pendingEmergencyExit;

        // Snapshot oracle health before execution; outage exits must not refresh the cache.
        (uint256 oraclePrice,) = _freshOraclePrice();
        paxgHeld = heldBefore - tokenAmount;
        totalDeployed = tokenAmount == heldBefore
            ? 0
            : totalDeployed - Math.mulDiv(totalDeployed, tokenAmount, heldBefore);

        paxg.forceApprove(address(swapRouter), 0);
        paxg.forceApprove(address(swapRouter), tokenAmount);
        usdcReturned = swapRouter.exactInputSingle(ISwapRouter.ExactInputSingleParams({
            tokenIn: address(paxg),
            tokenOut: address(usdc),
            fee: poolFee,
            recipient: vault,
            deadline: block.timestamp,
            amountIn: tokenAmount,
            amountOutMinimum: minUsdcOut,
            sqrtPriceLimitX96: 0
        }));
        if (usdcReturned < minUsdcOut) revert SlippageExceeded(usdcReturned, minUsdcOut);
        paxg.forceApprove(address(swapRouter), 0);

        // Cache only a realized price within the ordinary fresh-oracle tolerance,
        // in either direction. A distressed sale may execute without becoming a good price.
        if (oraclePrice > 0) {
            uint256 exitPrice = Math.mulDiv(usdcReturned, 1e18, tokenAmount);
            uint256 diff = exitPrice > oraclePrice ? exitPrice - oraclePrice : oraclePrice - exitPrice;
            if (exitPrice > 0 && diff <= Math.mulDiv(oraclePrice, 10_000 - minOutBps, 10_000)) {
                lastGoodPrice = exitPrice;
                lastGoodPriceAt = block.timestamp;
                emit LastGoodPriceUpdated(exitPrice, block.timestamp);
            }
        }

        // Mandatory: failure rolls back the swap, approvals, accounting and proposal deletion.
        IGoldExchangeVaultAccounting(vault).retireGoldPrincipal(tokenAmount, heldBefore);
        emit EmergencyExit(msg.sender, tokenAmount, usdcReturned, minUsdcOut);
    }

    /// @notice Live fresh oracle valuation; otherwise cached price, haircutted after its observation expires.
    /// @dev pokePrice maintains the fallback cache but is not required for fresh-price NAV correctness.
    function currentValue() external view returns (uint256) {
        try this.positionValueUsdc() returns (uint256 value) {
            return value;
        } catch {
            return 0;
        }
    }

    /// @dev Read-only boundary catches malformed observations and unrepresentable valuation arithmetic.
    function positionValueUsdc() external view returns (uint256) {
        if (paxgHeld == 0) return 0;
        (uint256 oraclePrice,) = _freshOraclePrice();
        if (oraclePrice > 0) return Math.mulDiv(paxgHeld, oraclePrice, 1e18);
        if (lastGoodPrice == 0) return 0;
        uint256 grossValue = Math.mulDiv(paxgHeld, lastGoodPrice, 1e18);
        bool fresh = lastGoodPriceAt > 0 && lastGoodPriceAt <= block.timestamp
            && block.timestamp - lastGoodPriceAt <= maxStalenessSecs;
        if (fresh) return grossValue;
        return Math.mulDiv(grossValue, 10_000 - staleHaircutBps, 10_000);
    }

    /// @notice Returns false when the XAU/USD oracle is stale or unhealthy (K2 update).
    ///         The oracle is now mandatory — the last-swap-age fallback has been removed.
    ///         Uses the oracle's `updatedAt` field for the freshness check, independent of
    ///         when the last atomic PAXG swap was executed. A 3-day idle S2-H adapter with a
    ///         fresh oracle heartbeat stays sane. Returns true when no position is open
    ///         (lastGoodPriceAt == 0 means no swap has been executed yet).
    function isPriceSane() external view returns (bool) {
        if (lastGoodPriceAt == 0) return true; // no position open — no oracle concern
        (uint256 price,) = _freshOraclePrice();
        return price > 0;
    }

    /// @dev Returns zero for an unavailable, incomplete, invalid or stale observation.
    ///      Price is 6-dec USDC per whole 18-dec PAXG, as used by pokePrice().
    function _freshOraclePrice() internal view returns (uint256 price, uint256 observedAt) {
        try goldOracle.latestRoundData() returns (
            uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
        ) {
            if (startedAt == 0 || answeredInRound < roundId || answer <= 0) return (0, 0);
            if (updatedAt == 0 || updatedAt > block.timestamp) return (0, 0);
            if (block.timestamp - updatedAt > maxStalenessSecs) return (0, 0);
            try goldOracle.decimals() returns (uint8 oracDec) {
                // Reject unrepresentable scaling rather than reverting during an exit.
                if (oracDec > 83) return (0, 0);
                if (oracDec < 6 && uint256(answer) > type(uint256).max / (10 ** uint256(6 - oracDec))) {
                    return (0, 0);
                }
                price = oracDec >= 6
                    ? uint256(answer) / (10 ** uint256(oracDec - 6))
                    : uint256(answer) * (10 ** uint256(6 - oracDec));
                observedAt = updatedAt;
            } catch {}
        } catch {}
    }

    /// @notice Refresh the cache only from a fresh, complete oracle observation.
    function pokePrice() external {
        (uint256 price, uint256 observedAt) = _freshOraclePrice();
        if (price == 0) return;
        lastGoodPrice = price;
        lastGoodPriceAt = observedAt;
        emit LastGoodPriceUpdated(price, observedAt);
    }

    /// @notice Owner updates the XAU/USD oracle (K2 — must be non-zero; reverts OracleRequired).
    ///         Use this to rotate the oracle feed without redeploying the adapter.
    function setGoldOracle(address oracle) external onlyOwner {
        // The emergency-sale floor derives from the cached oracle price; while emergency exits are
        // armed the feed cannot be swapped instantly (disable them first via the 30-day timelock).
        if (emergencyExitEnabled) revert OracleLockedWhileEmergencyEnabled();
        if (oracle == address(0)) revert OracleRequired();
        address previous = address(goldOracle);
        goldOracle = IAggregatorV3(oracle);
        emit GoldOracleUpdated(previous, oracle);
    }

    function isGoldStrategy() external pure returns (bool) {
        return true;
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

    /// @notice Emergency exit tolerance changes take effect only after 30 days.
    function proposeParamChange(bytes32 paramId, uint256 newValue) external onlyOwner {
        require(
            paramId == PARAM_EMERGENCY_SLIPPAGE || paramId == PARAM_EMERGENCY_EXIT_ENABLED,
            "GoldExchangeAdapter: unknown param"
        );
        if (paramId == PARAM_EMERGENCY_EXIT_ENABLED) {
            require(newValue <= 1, "GoldExchangeAdapter: boolean out of range");
        } else if (newValue > MAX_EMERGENCY_SLIPPAGE_BPS) {
            revert HaircutAboveCap(newValue, MAX_EMERGENCY_SLIPPAGE_BPS);
        }
        uint256 executeAfter = block.timestamp + TIMELOCK_DELAY;
        pendingChanges[paramId] = PendingChange(newValue, executeAfter, true);
        emit ParamChangeProposed(paramId, newValue, executeAfter);
    }

    function executeParamChange(bytes32 paramId) external onlyOwner {
        PendingChange memory pc = pendingChanges[paramId];
        require(pc.pending, "GoldExchangeAdapter: no proposal pending");
        require(block.timestamp >= pc.executeAfter, "GoldExchangeAdapter: timelock not elapsed");
        delete pendingChanges[paramId];
        if (paramId == PARAM_EMERGENCY_EXIT_ENABLED) {
            emergencyExitEnabled = pc.newValue == 1;
        } else {
            uint256 previous = emergencySlippageBps;
            emergencySlippageBps = pc.newValue;
            emit EmergencySlippageBpsUpdated(previous, pc.newValue);
        }
        emit ParamChangeExecuted(paramId, pc.newValue);
    }

    function cancelParamChange(bytes32 paramId) external onlyOwner {
        require(pendingChanges[paramId].pending, "GoldExchangeAdapter: no proposal pending");
        delete pendingChanges[paramId];
        emit ParamChangeCancelled(paramId);
    }

    function renounceOwnership() public override(Ownable) onlyOwner {
        revert("GoldExchangeAdapter: renouncing ownership is disabled");
    }
}
