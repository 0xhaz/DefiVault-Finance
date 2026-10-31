// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {GoldExchangeAdapter} from "../adapters/GoldExchangeAdapter.sol";
import {GoldAllocationAdapter} from "../adapters/GoldAllocationAdapter.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {MockXauUsdAggregator} from "../test-helpers/MockXauUsdAggregator.sol";

/// @dev Surface common to both gold adapters (selectors identical).
interface IGoldX {
    function deploy(uint256) external returns (uint256);
    function recall(uint256) external returns (uint256);
    function emergencyExit(uint256, uint256) external returns (uint256);
    function proposeEmergencyExit(uint256, uint256) external;
    function executeEmergencyExit() external returns (uint256);
    function cancelEmergencyExit() external;
    function pendingEmergencyExit() external view returns (uint256, uint256, uint256, uint256);
    function EMERGENCY_EXIT_DELAY() external view returns (uint256);
    function EMERGENCY_EXIT_WINDOW() external view returns (uint256);
    function EMERGENCY_FLOOR_BPS() external view returns (uint256);
    function proposeParamChange(bytes32, uint256) external;
    function executeParamChange(bytes32) external;
    function cancelParamChange(bytes32) external;
    function emergencyExitEnabled() external view returns (bool);
    function totalDeployed() external view returns (uint256);
    function lastGoodPrice() external view returns (uint256);
    function lastGoodPriceAt() external view returns (uint256);
    function currentValue() external view returns (uint256);
    function pendingChanges(bytes32) external view returns (uint256, uint256, bool);
    function PARAM_EMERGENCY_EXIT_ENABLED() external view returns (bytes32);
    function TIMELOCK_DELAY() external view returns (uint256);
    function owner() external view returns (address);
    function vault() external view returns (address);
}

/// @dev Recording / hostile swap router. Price = USDC base units per whole gold token.
contract RecordingRouter {
    struct Params {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    error RouterMinOut();

    address public immutable usdc;
    address public token0;
    address public token1;
    uint160 public sqrtP;
    uint256 public price = 3_300e6;
    uint256 public payoutBps = 10_000;
    bool public enforceMin;

    Params public last;
    uint256 public calls;
    uint256 public allowanceSeen;

    address public hookTarget;
    bytes public hookData;

    constructor(address usdc_, address gold_, uint160 sqrtP_) {
        usdc = usdc_;
        token0 = gold_;
        token1 = usdc_;
        sqrtP = sqrtP_;
    }

    function setPrice(uint256 p) external { price = p; }
    function setPayoutBps(uint256 b) external { payoutBps = b; }
    function setEnforceMin(bool e) external { enforceMin = e; }
    function setHook(address target, bytes calldata data) external { hookTarget = target; hookData = data; }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtP, 0, 0, 1, 1, 0, true);
    }

    /// @dev Always bubbles the hook's revert so reentrancy attempts surface on the outer call.
    function exactInputSingle(Params calldata p) external returns (uint256 out) {
        last = p;
        calls++;
        allowanceSeen = IERC20(p.tokenIn).allowance(msg.sender, address(this));
        if (hookTarget != address(0)) {
            (bool ok, bytes memory r) = hookTarget.call(hookData);
            if (!ok) assembly { revert(add(r, 32), mload(r)) }
        }
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        if (p.tokenIn == usdc) {
            out = p.amountIn * 10 ** IERC20Metadata(p.tokenOut).decimals() / price;
        } else {
            out = p.amountIn * price / 10 ** IERC20Metadata(p.tokenIn).decimals();
        }
        out = out * payoutBps / 10_000;
        if (enforceMin && out < p.amountOutMinimum) revert RouterMinOut();
        IERC20(p.tokenOut).transfer(p.recipient, out);
    }
}

/// @dev Contract-based owner/vault so a hostile router can re-enter with the privileged identity.
///      As the vault it also implements the `retireGoldPrincipal` hook the adapters call after an emergency sale.
contract ActorProxy {
    error RetireFailed();

    bool public failRetire;
    uint256 public retireCalls;
    uint256 public lastSold;
    uint256 public lastHeldBefore;

    function setFailRetire(bool b) external { failRetire = b; }

    function retireGoldPrincipal(uint256 soldTokens, uint256 heldBefore) external {
        if (failRetire) revert RetireFailed();
        retireCalls++;
        lastSold = soldTokens;
        lastHeldBefore = heldBefore;
    }

    function forward(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory r) = target.call(data);
        if (!ok) assembly { revert(add(r, 32), mload(r)) }
        return r;
    }
}

/// @dev Shared fixture. No test functions here.
abstract contract GoldExitBase is Test {
    error ZeroAmount();
    error AmountExceedsHeld(uint256 requested, uint256 held);
    error SlippageExceeded(uint256 amountOut, uint256 minOut);
    error EmergencyExitDisabled();
    error EmergencyExitRequiresProposal();
    error EmergencyExitProposalExists();
    error NoEmergencyExitProposal();
    error EmergencyExitNotReady(uint256 executeAfter);
    error EmergencyExitExpired(uint256 expiresAt);
    error StaleGoldPrice();

    event EmergencyExitProposed(uint256 tokenAmount, uint256 minUsdcOut, uint256 executeAfter, uint256 expiresAt);
    event EmergencyExitCancelled();
    event EmergencyExit(address indexed caller, uint256 tokenSold, uint256 usdcReturned, uint256 minUsdcOut);
    event ParamChangeProposed(bytes32 indexed paramId, uint256 newValue, uint256 executeAfter);
    event ParamChangeExecuted(bytes32 indexed paramId, uint256 newValue);
    event ParamChangeCancelled(bytes32 indexed paramId);
    event LastGoodPriceUpdated(uint256 price, uint256 timestamp);

    bytes32 internal constant PARAM = keccak256("emergencyExitEnabled");
    int256 internal constant ORACLE_PRICE = 330_000_000_000; // $3,300 @ 8 dec
    uint256 internal constant PRICE = 3_300e6; // 6-dec USDC per whole gold token
    uint256 internal constant DEPLOY = 100_000e6;

    address internal manager = makeAddr("manager");
    address internal stranger = makeAddr("stranger");
    address internal owner;
    address internal vault;
    ActorProxy internal ownerP;
    ActorProxy internal vaultP;

    MockERC20 internal usdc;
    MockERC20 internal gold;
    MockXauUsdAggregator internal oracle;
    RecordingRouter internal router;
    IGoldX internal adapter;
    uint8 internal goldDec;
    int256 internal curOracle = ORACLE_PRICE;
    bool internal inOutage;

    // ── per-adapter hooks ───────────────────────────────────────────────
    function _goldDecimals() internal pure virtual returns (uint8);
    function _makeAdapter() internal virtual returns (IGoldX);
    function _held() internal view virtual returns (uint256);
    function _expectInvalidBool(uint256 v) internal virtual;
    function _expectNoProposal() internal virtual;
    function _expectTimelock(uint256 executeAfter) internal virtual;

    function _setActors() internal virtual {
        ownerP = new ActorProxy();
        vaultP = new ActorProxy();
        owner = address(ownerP);
        vault = address(vaultP);
    }

    function _postSetUp() internal virtual {}

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        goldDec = _goldDecimals();
        usdc = new MockERC20("USDC", "USDC", 6);
        gold = new MockERC20("Gold", "GLD", goldDec);
        oracle = new MockXauUsdAggregator();
        oracle.setPrice(ORACLE_PRICE);
        // Raw token1/token0 ratio for a 6-dec gold token at $3,300 (only the allocation adapter reads it).
        uint160 sq = goldDec == 6 ? uint160(Math.sqrt(uint256(3300) << 192)) : 0;
        router = new RecordingRouter(address(usdc), address(gold), sq);
        usdc.mint(address(router), 1e18);
        gold.mint(address(router), 1e30);
        _setActors();
        adapter = _makeAdapter();
        _postSetUp();
    }

    // ── helpers ─────────────────────────────────────────────────────────
    function _open(uint256 usdcAmt) internal {
        usdc.mint(address(adapter), usdcAmt);
        vaultP.forward(address(adapter), abi.encodeCall(IGoldX.deploy, (usdcAmt)));
    }

    function _enable() internal {
        vm.prank(owner);
        adapter.proposeParamChange(PARAM, 1);
        vm.warp(block.timestamp + 30 days);
        vm.prank(owner);
        adapter.executeParamChange(PARAM);
        _freshOracle();
    }

    function _freshOracle() internal { oracle.setPrice(curOracle); }

    /// @dev Move the (fresh) oracle price; later refreshes keep it.
    function _setOracle(int256 p) internal {
        curOracle = p;
        oracle.setPrice(p);
    }

    /// @dev Oracle goes stale (older than both adapters' staleness windows) and stays stale across waits.
    function _outage() internal {
        inOutage = true;
        vm.warp(block.timestamp + 2 days);
    }

    /// @dev Hard floor: 20% of cached-price value, rounded up (at least 1).
    function _floor(uint256 amt) internal view returns (uint256 f) {
        uint256 value = Math.mulDiv(amt, adapter.lastGoodPrice(), 10 ** goldDec);
        f = Math.mulDiv(value, 2000, 10_000, Math.Rounding.Ceil);
        if (f == 0) f = 1;
    }

    function _propose(uint256 amt, uint256 minOut) internal {
        vm.prank(owner);
        adapter.proposeEmergencyExit(amt, minOut);
    }

    function _execute() internal returns (uint256) {
        vm.prank(owner);
        return adapter.executeEmergencyExit();
    }

    /// @dev Wait out the 1h delay; keep the oracle fresh unless an outage is being simulated.
    function _wait() internal {
        vm.warp(block.timestamp + 1 hours);
        if (!inOutage) _freshOracle();
    }

    function _exitMin(uint256 amt, uint256 minOut) internal returns (uint256) {
        _propose(amt, minOut);
        _wait();
        return _execute();
    }

    /// @dev Propose at the hard floor, wait, execute.
    function _exit(uint256 amt) internal returns (uint256) {
        return _exitMin(amt, _floor(amt));
    }

    function _out(uint256 sold, uint256 price_) internal view returns (uint256) {
        return sold * price_ / 10 ** goldDec;
    }
}

abstract contract GoldExitExchangeFixture is GoldExitBase {
    function _goldDecimals() internal pure override returns (uint8) { return 18; }

    function _makeAdapter() internal override returns (IGoldX) {
        return IGoldX(address(new GoldExchangeAdapter(
            address(usdc), address(gold), address(router), 3000, vault, owner, address(oracle)
        )));
    }

    function _held() internal view override returns (uint256) {
        return GoldExchangeAdapter(address(adapter)).paxgHeld();
    }

    function _expectInvalidBool(uint256) internal override {
        vm.expectRevert("GoldExchangeAdapter: boolean out of range");
    }

    function _expectNoProposal() internal override {
        vm.expectRevert("GoldExchangeAdapter: no proposal pending");
    }

    function _expectTimelock(uint256) internal override {
        vm.expectRevert("GoldExchangeAdapter: timelock not elapsed");
    }
}

abstract contract GoldExitAllocFixture is GoldExitBase {
    function _goldDecimals() internal pure override returns (uint8) { return 6; }

    function _makeAdapter() internal override returns (IGoldX) {
        return IGoldX(address(new GoldAllocationAdapter(
            address(usdc), address(gold), address(router), 3000, address(oracle), vault, 3600, owner
        )));
    }

    function _held() internal view override returns (uint256) {
        return GoldAllocationAdapter(address(adapter)).xautHeld();
    }

    function _expectInvalidBool(uint256 v) internal override {
        vm.expectRevert(abi.encodeWithSelector(
            GoldAllocationAdapter.ParamAboveHardCap.selector, "emergencyExitEnabled", v, uint256(1)
        ));
    }

    function _expectNoProposal() internal override {
        vm.expectRevert(GoldAllocationAdapter.NoProposalPending.selector);
    }

    function _expectTimelock(uint256 executeAfter) internal override {
        vm.expectRevert(abi.encodeWithSelector(
            GoldAllocationAdapter.TimelockNotElapsed.selector, executeAfter, block.timestamp
        ));
    }
}
