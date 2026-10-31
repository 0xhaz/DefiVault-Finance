// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HalalLPAdapter, IHalalSwapRouter} from "../adapters/HalalLPAdapter.sol";
import {ArcNativeCoinShim, ArcBlocklistShim} from "../test-helpers/ArcNativeCoinShim.sol";

interface IV3PoolReal {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
    function observe(uint32[] calldata) external view returns (int56[] memory, uint160[] memory);
}

interface IV3FactoryReal {
    function getPool(address, address, uint24) external view returns (address);
}

/// @title LP-1 / LP-2: HalalLPAdapter against the REAL Uniswap V3 deployment on Arc mainnet (READ-ONLY FORK)
/// @notice Runs the unmodified adapter against Uniswap's official Arc mainnet factory, NonfungiblePositionManager,
///         SwapRouter02 and the USDC/EURC 0.05% pool. Nothing is broadcast: this is a local fork, no mainnet tx.
///         Skipped unless ARC_MAINNET_RPC is set. Optional ARC_MAINNET_FORK_BLOCK pins the block.
///
///         The test contract impersonates the vault (adapter.onlyVault) so the adapter is isolated; vault-level
///         flows stay covered by the mock suites. Foundry does not implement Arc's native-coin precompiles, so the
///         same ArcNativeCoinShim used by ForkCctpRealArc is etched at 0x1800..00/01; USDC itself is the real proxy.
contract ForkHalalLPArcMainnetTest is Test {
    address internal constant USDC = 0x3600000000000000000000000000000000000000;
    address internal constant EURC = 0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1;
    address internal constant FACTORY = 0xf0db7b58379503491d857dB50AC9ece64c653918;
    address internal constant NPM = 0x39654A85A4C05127f5Fd6ED22CAeC077A0fB1377;
    address internal constant ROUTER = 0x53BF6B0684Ec7eF91e1387Da3D1a1769bC5A6F77;
    address internal constant POOL = 0x6fd5F2fb831940DcD61A98c5B3aCB7D8C6f3bFc1;
    uint24 internal constant FEE = 500;

    address internal constant NATIVE_AUTHORITY = 0x1800000000000000000000000000000000000000;
    address internal constant NATIVE_BLOCKLIST = 0x1800000000000000000000000000000000000001;
    uint256 internal constant NATIVE_SCALE = 1e12;
    uint256 internal constant ADAPTER_READ_GAS = 100_000; // ShariahAccountingLogic.ADAPTER_READ_GAS

    bytes32 internal constant DECREASE_SIG = keccak256("DecreaseLiquidity(uint256,uint128,uint256,uint256)");
    bytes32 internal constant COLLECT_SIG = keccak256("Collect(uint256,address,uint256,uint256)");

    address internal vault = makeAddr("vault");
    address internal owner = makeAddr("owner");
    address internal whale = makeAddr("whale");
    HalalLPAdapter internal adapter;

    function setUp() public {
        string memory rpc = vm.envOr("ARC_MAINNET_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        uint256 pin = vm.envOr("ARC_MAINNET_FORK_BLOCK", uint256(0));
        if (pin == 0) {
            try vm.createSelectFork(rpc) returns (uint256) {} catch { vm.skip(true); }
        } else {
            try vm.createSelectFork(rpc, pin) returns (uint256) {} catch { vm.skip(true); }
        }
        if (block.chainid != 5042) vm.skip(true);

        vm.etch(NATIVE_AUTHORITY, address(new ArcNativeCoinShim()).code);
        vm.allowCheatcodes(NATIVE_AUTHORITY);
        vm.etch(NATIVE_BLOCKLIST, address(new ArcBlocklistShim()).code);
        ArcNativeCoinShim(NATIVE_AUTHORITY).setSupply(type(uint128).max);

        adapter = new HalalLPAdapter(NPM, ROUTER, USDC, EURC, FEE, USDC, vault, owner);
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _fundUsdc(address who, uint256 amt) internal {
        // Arc USDC's ERC-20 view is nativeBalance / 1e12.
        vm.deal(who, who.balance + amt * NATIVE_SCALE);
    }

    function _fundEurc(address who, uint256 amt) internal {
        deal(EURC, who, IERC20(EURC).balanceOf(who) + amt);
    }

    function _deploy(uint256 amt) internal {
        _fundUsdc(address(adapter), amt);
        vm.prank(vault);
        adapter.deploy(amt);
    }

    function _recall(uint256 amt) internal returns (uint256 got) {
        uint256 before = IERC20(USDC).balanceOf(vault);
        vm.prank(vault);
        adapter.recall(amt);
        got = IERC20(USDC).balanceOf(vault) - before;
    }

    function _swap(address tokenIn, uint256 amt) internal returns (uint256 out) {
        address tokenOut = tokenIn == USDC ? EURC : USDC;
        if (tokenIn == USDC) _fundUsdc(whale, amt);
        else _fundEurc(whale, amt);
        vm.startPrank(whale);
        IERC20(tokenIn).approve(ROUTER, amt);
        out = IHalalSwapRouter(ROUTER).exactInputSingle(IHalalSwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn, tokenOut: tokenOut, fee: FEE, recipient: whale,
            amountIn: amt, amountOutMinimum: 0, sqrtPriceLimitX96: 0
        }));
        vm.stopPrank();
    }

    function _spotTick() internal view returns (int24 t) {
        (, t,,,,,) = IV3PoolReal(POOL).slot0();
    }

    /// @dev Same call shape as the vault: staticcall with a hard 100k gas budget, exactly 32 bytes back.
    function _boundedValueRead() internal view returns (bool ok, uint256 value) {
        (bool success, bytes memory ret) =
            address(adapter).staticcall{gas: ADAPTER_READ_GAS}(abi.encodeCall(HalalLPAdapter.currentValue, ()));
        if (success && ret.length == 32) return (true, abi.decode(ret, (uint256)));
        return (false, 0);
    }

    // ───────────────────────────── tests ─────────────────────────────

    function test_fork_wiringMatchesRealPool() public view {
        assertEq(IV3FactoryReal(FACTORY).getPool(USDC, EURC, FEE), POOL, "factory resolves pool");
        assertEq(IV3PoolReal(POOL).token0(), USDC, "USDC is token0");
        assertEq(IV3PoolReal(POOL).token1(), EURC, "EURC is token1");
        assertEq(IERC20Decimals(EURC).decimals(), 6);
        assertGt(IV3PoolReal(POOL).liquidity(), 0, "pool has in-range liquidity");
        (,,, uint16 card,,,) = IV3PoolReal(POOL).slot0();
        uint32[] memory ago = new uint32[](2);
        ago[0] = adapter.twapWindow();
        IV3PoolReal(POOL).observe(ago); // reverts if the 1800 s window is not covered
        assertEq(adapter.currentValue(), 0, "empty adapter values at zero");
        console.log("block", block.number, "cardinality", card);
        console.log("spot tick");
        console.logInt(_spotTick());
    }

    function test_fork_deploy_mintsRealPosition_valueNearPrincipal() public {
        uint256 amt = 1_000e6;
        _deploy(amt);
        assertGt(adapter.positionTokenId(), 0, "NFT minted");
        assertEq(adapter.totalDeployed(), amt);
        assertEq(IERC20(USDC).allowance(address(adapter), NPM), 0, "USDC approval cleared");
        assertEq(IERC20(EURC).allowance(address(adapter), NPM), 0, "EURC approval cleared");
        assertEq(IERC20(USDC).allowance(address(adapter), ROUTER), 0, "router approval cleared");
        uint256 v = adapter.currentValue();
        console.log("deploy 1000 USDC -> currentValue", v);
        console.log("idle USDC", IERC20(USDC).balanceOf(address(adapter)), "idle EURC", IERC20(EURC).balanceOf(address(adapter)));
        assertGe(v, amt * 99 / 100, "value within 1% of principal after real swap + mint");
        assertLe(v, amt * 1001 / 1000, "value not inflated");
    }

    /// LP-2: the vault reads currentValue() with a 100k gas cap; above it, deposits are blocked while funded.
    function test_fork_currentValue_fitsVaultReadGasCap() public {
        _deploy(1_000e6);
        uint256 g = gasleft();
        uint256 direct = adapter.currentValue();
        uint256 used = g - gasleft();
        (bool ok, uint256 bounded) = _boundedValueRead();
        console.log("currentValue gas (warm, incl. call overhead)", used);
        assertTrue(ok, "currentValue must succeed within ADAPTER_READ_GAS");
        assertEq(bounded, direct, "bounded read equals direct read");
    }

    /// KNOWN FINDING (LP-2, open): in a real deposit/exit transaction the adapter, position manager and pool
    /// storage are cold. The cold read costs ~111k gas (observe() ~59k on a 1000-slot buffer, positions() ~17k,
    /// two balanceOf ~12k), above the vault's 100k ADAPTER_READ_GAS. The vault would treat every read as failed:
    /// valuationHealthy() == false, deposits blocked while the LP is funded, exits unmarked.
    /// Flip this assertion to assertTrue once the read budget or the adapter's read path is fixed.
    function test_knownFinding_LP2_coldReadExceedsVaultReadGasCap() public {
        _deploy(1_000e6);
        // Fresh transaction context: the read is the first touch of these accounts/slots in the tx.
        vm.cool(address(adapter));
        vm.cool(NPM);
        vm.cool(FACTORY);
        vm.cool(POOL);
        vm.cool(USDC);
        vm.cool(EURC);
        (bool ok,) = _boundedValueRead();
        assertFalse(ok, "LP-2 fixed? cold read now fits ADAPTER_READ_GAS: flip to assertTrue and update the workplan");
    }

    /// Diagnostic: smallest cold-read budget (5k steps) at which currentValue() succeeds.
    function test_fork_currentValue_coldGasRequired() public {
        _deploy(1_000e6);
        uint256 needed;
        for (uint256 budget = 80_000; budget <= 300_000; budget += 5_000) {
            vm.cool(address(adapter)); vm.cool(NPM); vm.cool(FACTORY); vm.cool(POOL); vm.cool(USDC); vm.cool(EURC);
            vm.cool(NATIVE_AUTHORITY);
            (bool ok,) = address(adapter).staticcall{gas: budget}(abi.encodeCall(HalalLPAdapter.currentValue, ()));
            if (ok) { needed = budget; break; }
        }
        console.log("cold currentValue needs (<=)", needed, "vault cap", ADAPTER_READ_GAS);
        assertGt(needed, 0);
    }

    function test_fork_fullRecall_returnsPrincipalLessCosts() public {
        uint256 amt = 1_000e6;
        _deploy(amt);
        uint256 g = gasleft();
        uint256 got = _recall(amt);
        console.log("full recall gas", g - gasleft());
        console.log("full recall returned", got);
        assertEq(adapter.positionTokenId(), 0);
        assertEq(adapter.totalDeployed(), 0);
        assertEq(IERC20(EURC).balanceOf(address(adapter)), 0, "no EURC stranded");
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0, "no USDC stranded");
        assertEq(adapter.currentValue(), 0);
        assertGe(got, amt * 99 / 100, "round trip loses < 1% (two 0.05% swaps + impact)");
    }

    function test_fork_partialThenFullRecall() public {
        uint256 amt = 2_000e6;
        _deploy(amt);
        uint256 v0 = adapter.currentValue();
        uint256 half = _recall(amt / 2);
        assertEq(adapter.totalDeployed(), amt / 2);
        assertGt(adapter.positionTokenId(), 0, "position kept open");
        uint256 v1 = adapter.currentValue();
        console.log("partial recall returned", half, "value after", v1);
        assertApproxEqRel(v1, v0 / 2, 0.01e18, "remaining value ~ half");
        assertApproxEqRel(half, v0 / 2, 0.01e18, "partial proceeds ~ half");
        uint256 rest = _recall(amt / 2);
        assertEq(adapter.positionTokenId(), 0);
        assertEq(IERC20(EURC).balanceOf(address(adapter)), 0);
        assertGe(half + rest, amt * 99 / 100);
    }

    function test_fork_realSwapVolume_accruesFeesCollectedOnRecall() public {
        _deploy(5_000e6);
        // Round-trip volume that leaves the price near where it started (keeps spot within the TWAP guard).
        for (uint256 i; i < 5; ++i) {
            uint256 eurcOut = _swap(USDC, 2_000e6);
            _swap(EURC, eurcOut);
        }
        int24 drift = _spotTick() - _twapTick();
        console.log("spot-TWAP drift after volume (ticks)");
        console.logInt(drift);

        vm.recordLogs();
        _recall(5_000e6);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 dec0; uint256 dec1; uint256 col0; uint256 col1;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != NPM) continue;
            if (logs[i].topics[0] == DECREASE_SIG) (, dec0, dec1) = abi.decode(logs[i].data, (uint128, uint256, uint256));
            if (logs[i].topics[0] == COLLECT_SIG) (, col0, col1) = abi.decode(logs[i].data, (address, uint256, uint256));
        }
        console.log("fees collected USDC", col0 - dec0, "EURC", col1 - dec1);
        assertGt((col0 - dec0) + (col1 - dec1), 0, "real swap fees reach the adapter on recall");
    }

    /// Large adverse move: deploy/recall revert until the TWAP catches up; then the loss is marked and realised.
    function test_fork_priceShock_guardBlocksThenMarksDown() public {
        uint256 amt = 1_000e6;
        _deploy(amt);
        uint256 v0 = adapter.currentValue();
        int24 t0 = _spotTick();
        // Sell EURC until spot moves past the guard (EURC cheaper => tick up).
        uint256 sold;
        for (uint256 i; i < 20 && _spotTick() - t0 <= int24(adapter.maxTwapDeviationTicks()); ++i) {
            _swap(EURC, 5_000e6);
            sold += 5_000e6;
        }
        console.log("EURC sold to move > guard", sold);
        console.log("tick move");
        console.logInt(_spotTick() - t0);
        assertGt(_spotTick() - t0, int24(adapter.maxTwapDeviationTicks()), "shock exceeded guard");

        vm.prank(vault);
        vm.expectPartialRevert(HalalLPAdapter.SpotTwapDeviation.selector);
        adapter.recall(amt);

        // Unmarked at the old TWAP right after the shock (the known exposure window).
        uint256 vShock = adapter.currentValue();
        console.log("value at shock (TWAP still old)", vShock);

        vm.warp(block.timestamp + adapter.twapWindow() + 60);
        vm.roll(block.number + 1);
        uint256 v1 = adapter.currentValue();
        console.log("value before", v0, "after TWAP catches up", v1);
        assertLt(v1, v0, "loss marked down once TWAP reflects the move");

        uint256 got = _recall(amt);
        console.log("recall after shock returned", got);
        assertApproxEqRel(got, v1, 0.01e18, "realised ~ marked value");
    }

    /// Deploy-size ladder against real depth: logs the largest single deploy the 1% slippage settings allow.
    function test_fork_deploySizeLadder() public {
        uint256[6] memory sizes = [uint256(1_000e6), 5_000e6, 10_000e6, 20_000e6, 40_000e6, 80_000e6];
        bool firstOk;
        for (uint256 i; i < sizes.length; ++i) {
            uint256 snap = vm.snapshotState();
            _fundUsdc(address(adapter), sizes[i]);
            vm.prank(vault);
            try adapter.deploy(sizes[i]) {
                console.log("deploy OK   USDC", sizes[i] / 1e6, "value", adapter.currentValue() / 1e6);
                if (i == 0) firstOk = true;
            } catch (bytes memory err) {
                console.log("deploy FAIL USDC", sizes[i] / 1e6);
                console.logBytes(err.length >= 4 ? _sel(err) : err);
            }
            vm.revertToState(snap);
        }
        assertTrue(firstOk, "1k USDC must deploy");
    }

    // ───────────────────────────── internals ─────────────────────────────

    function _twapTick() internal view returns (int24) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = adapter.twapWindow();
        (int56[] memory c,) = IV3PoolReal(POOL).observe(ago);
        int56 d = c[1] - c[0];
        int56 w = int56(uint56(ago[0]));
        int56 m = d / w;
        if (d < 0 && d % w != 0) m--;
        return int24(m);
    }

    function _sel(bytes memory err) internal pure returns (bytes memory s) {
        s = new bytes(4);
        for (uint256 i; i < 4; ++i) s[i] = err[i];
    }
}

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}
