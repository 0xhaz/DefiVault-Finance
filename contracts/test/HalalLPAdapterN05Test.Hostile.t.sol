// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {MockSwapRouter} from "../test-helpers/MockSwapRouter.sol";
import {MockPositionManager} from "../test-helpers/MockPositionManager.sol";
import {HalalLPAdapter, IHalalSwapRouter} from "../adapters/HalalLPAdapter.sol";

/// @dev A vault contract that re-enters the adapter (as the legitimate vault) from a hook.
contract N05ReentrantVault {
    HalalLPAdapter public adapter;
    bool public hooked;
    bool internal inHook;
    bytes4 public deployErr;
    bytes4 public recallErr;

    function setAdapter(HalalLPAdapter a) external { adapter = a; }

    function hook() external {
        if (inHook) return;
        inHook = true;
        hooked = true;
        try adapter.deploy(1) {} catch (bytes memory e) { deployErr = bytes4(e); }
        try adapter.recall(1) {} catch (bytes memory e) { recallErr = bytes4(e); }
        inHook = false;
    }

    function callDeploy(uint256 a) external returns (uint256) { return adapter.deploy(a); }
    function callRecall(uint256 a) external returns (uint256) { return adapter.recall(a); }
}

/// @dev Pair token that calls back into the vault on every balance movement once armed.
contract N05HookToken is MockERC20 {
    N05ReentrantVault public target;

    constructor() MockERC20("HOOK", "HOOK", 6) {}

    function arm(N05ReentrantVault t) external { target = t; }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (address(target) != address(0)) target.hook();
    }
}

/// @dev Router that re-enters via the vault, then performs an honest swap through `inner`.
contract N05HookRouter is IHalalSwapRouter {
    MockSwapRouter public immutable inner;
    N05ReentrantVault public target;

    constructor(MockSwapRouter i) { inner = i; }

    function arm(N05ReentrantVault t) external { target = t; }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256) {
        if (address(target) != address(0)) target.hook();
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        IERC20(p.tokenIn).approve(address(inner), p.amountIn);
        return inner.exactInputSingle(p);
    }
}

/// @dev Takes the input, pays out half of the parity amount, never checks the minimum.
contract N05ShortRouter is IHalalSwapRouter {
    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 out) {
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        out = p.amountIn / 2;
        IERC20(p.tokenOut).transfer(p.recipient, out);
    }
}

/// @dev Pulls only half of the approved input (leaves allowance stranded unless the adapter clears it).
contract N05HalfPullRouter is IHalalSwapRouter {
    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 out) {
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn / 2);
        out = p.amountIn;
        IERC20(p.tokenOut).transfer(p.recipient, out);
    }
}

/// @dev Parity setup (USDC token0, 6-decimal pair, tick 0) with hostile counterparties.
contract HalalLPAdapterN05HostileTest is Test {
    uint256 internal constant AMT = 10_000e6;

    MockERC20 internal usdc;
    N05HookToken internal pair;
    MockSwapRouter internal inner;
    MockPositionManager internal pm;
    N05ReentrantVault internal rv;
    HalalLPAdapter internal adapter;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        pair = new N05HookToken();
        pm = new MockPositionManager(address(usdc), address(pair));
        inner = new MockSwapRouter(address(usdc), address(pair));
        rv = new N05ReentrantVault();
        usdc.mint(address(inner), 1e30);
        pair.mint(address(inner), 1e30);
        pm.setTicks(0, 0);
        inner.setPrice(pm.sqrtPriceX96());
    }

    function _build(address router) internal {
        adapter = new HalalLPAdapter(
            address(pm), router, address(usdc), address(pair), 3000, address(usdc), address(rv), address(this)
        );
        rv.setAdapter(adapter);
    }

    function _assertBlocked() internal view {
        assertTrue(rv.hooked(), "hook ran");
        assertEq(rv.deployErr(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector, "deploy re-entry blocked");
        assertEq(rv.recallErr(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector, "recall re-entry blocked");
    }

    // ── reentrancy ───────────────────────────────────────────────────────────
    function test_hostileRouter_cannotReenterDuringDeploy() public {
        N05HookRouter hr = new N05HookRouter(inner);
        _build(address(hr));
        hr.arm(rv);
        usdc.mint(address(adapter), AMT);

        rv.callDeploy(AMT);

        _assertBlocked();
        assertEq(pm.mintCount(), 1, "only the outer mint happened");
        assertEq(adapter.totalDeployed(), AMT, "no double accounting");
        assertEq(adapter.positionTokenId(), 1);
        assertEq(usdc.allowance(address(adapter), address(hr)), 0);
        assertEq(pair.allowance(address(adapter), address(hr)), 0);
    }

    function test_hostileRouter_cannotReenterDuringRecall() public {
        N05HookRouter hr = new N05HookRouter(inner);
        _build(address(hr));
        usdc.mint(address(adapter), AMT);
        rv.callDeploy(AMT); // honest
        assertFalse(rv.hooked());
        hr.arm(rv);

        uint256 returned = rv.callRecall(AMT);

        _assertBlocked();
        assertEq(adapter.totalDeployed(), 0);
        assertEq(usdc.balanceOf(address(rv)), returned);
        assertApproxEqRel(returned, AMT, 1e12);
        assertEq(pm.decreaseCount(), 1);
        assertEq(usdc.allowance(address(adapter), address(hr)), 0);
        assertEq(pair.allowance(address(adapter), address(hr)), 0);
    }

    function test_hostileToken_cannotReenterDuringDeploy() public {
        _build(address(inner));
        pair.arm(rv);
        usdc.mint(address(adapter), AMT);

        rv.callDeploy(AMT);

        _assertBlocked();
        assertEq(pm.mintCount(), 1);
        assertEq(adapter.totalDeployed(), AMT);
        assertEq(usdc.allowance(address(adapter), address(pm)), 0);
        assertEq(pair.allowance(address(adapter), address(pm)), 0);
    }

    function test_hostileToken_cannotReenterDuringRecall() public {
        _build(address(inner));
        usdc.mint(address(adapter), AMT);
        rv.callDeploy(AMT);
        pair.arm(rv);

        uint256 returned = rv.callRecall(AMT / 2);

        _assertBlocked();
        assertEq(adapter.totalDeployed(), AMT / 2);
        assertEq(usdc.balanceOf(address(rv)), returned);
        assertEq(pm.decreaseCount(), 1, "no nested burn");
        assertEq(usdc.allowance(address(adapter), address(inner)), 0);
        assertEq(pair.allowance(address(adapter), address(inner)), 0);
    }

    // ── dishonest router ─────────────────────────────────────────────────────
    function test_routerPayingBelowMinimum_revertsSwapSlippage() public {
        N05ShortRouter sr = new N05ShortRouter();
        usdc.mint(address(sr), 1e30);
        pair.mint(address(sr), 1e30);
        _build(address(sr));
        usdc.mint(address(adapter), AMT);

        vm.expectRevert(HalalLPAdapter.SwapSlippage.selector);
        rv.callDeploy(AMT);

        assertEq(adapter.totalDeployed(), 0);
        assertEq(usdc.balanceOf(address(adapter)), AMT);
        assertEq(usdc.allowance(address(adapter), address(sr)), 0);
    }

    function test_routerPullingLessThanApproved_leavesNoAllowance() public {
        N05HalfPullRouter hp = new N05HalfPullRouter();
        usdc.mint(address(hp), 1e30);
        pair.mint(address(hp), 1e30);
        _build(address(hp));
        usdc.mint(address(adapter), AMT);

        rv.callDeploy(AMT);

        assertEq(usdc.allowance(address(adapter), address(hp)), 0, "unused approval cleared");
        assertEq(pair.allowance(address(adapter), address(hp)), 0);
        assertEq(usdc.allowance(address(adapter), address(pm)), 0);
        assertEq(pair.allowance(address(adapter), address(pm)), 0);
        assertGt(adapter.positionTokenId(), 0);
    }
}
