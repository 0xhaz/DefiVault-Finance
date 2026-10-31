// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HalalLPAdapter, IHalalSwapRouter} from "../adapters/HalalLPAdapter.sol";
import {ArcNativeCoinShim, ArcBlocklistShim} from "../test-helpers/ArcNativeCoinShim.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {ShariahAccountingLogic} from "../ShariahVault.sol";
import {UniswapV3TestnetDeployer as U, IUniV3FactoryT} from "../script/DeployUniswapV3Testnet.s.sol";

interface INpmMint {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function mint(MintParams calldata) external payable returns (uint256, uint128, uint256, uint256);
    function factory() external view returns (address);
}

interface IPoolObserve {
    function observe(uint32[] calldata) external view returns (int56[] memory, uint160[] memory);
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

/// @title LP-3/LP-4 rehearsal: official Uniswap V3 deployed on an Arc Testnet fork, driven by HalalLPAdapter
/// @notice Runs the same deployment code as DeployUniswapV3Testnet.s.sol (byte-identical official Uniswap V3) on a
///         local fork of Arc Testnet, seeds both pools, builds 30 min of TWAP history, then deploys and recalls
///         through the unmodified adapter. The volatile pool has USDC as token1, the case the mainnet fork
///         (USDC/EURC, USDC token0) could not cover. Nothing is broadcast. Skips unless ARC_TESTNET_RPC is set.
///         The test contract impersonates the vault; Arc's native-coin precompiles are shimmed as in the other forks.
contract ForkUniV3ArcTestnetTest is Test {
    address internal constant NATIVE_AUTHORITY = 0x1800000000000000000000000000000000000000;
    address internal constant NATIVE_BLOCKLIST = 0x1800000000000000000000000000000000000001;
    uint256 internal constant NATIVE_SCALE = 1e12;

    address internal vault = makeAddr("vault");
    address internal owner = makeAddr("owner");
    address internal lp = makeAddr("lp");
    address internal trader = makeAddr("trader");

    U.Deployment internal d;
    HalalLPAdapter internal stableAdapter; // USDC token0
    HalalLPAdapter internal volatileAdapter; // USDC token1

    function setUp() public {
        string memory rpc = vm.envOr("ARC_TESTNET_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        try vm.createSelectFork(rpc) returns (uint256) {} catch { vm.skip(true); }
        if (block.chainid != 5042002) vm.skip(true);

        vm.etch(NATIVE_AUTHORITY, address(new ArcNativeCoinShim()).code);
        vm.allowCheatcodes(NATIVE_AUTHORITY);
        vm.etch(NATIVE_BLOCKLIST, address(new ArcBlocklistShim()).code);
        ArcNativeCoinShim(NATIVE_AUTHORITY).setSupply(type(uint128).max);

        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/contracts/script/uniswap-v3/creation-bytecode.json"));
        d = U.deployCore(vm, json);
        (bytes32 salt, address predicted) = U.mockSalt(address(this));
        d.mockToken = address(new MockERC20{salt: salt}("Mock Volatile", "MVOL", 6));
        assertEq(d.mockToken, predicted);
        d = U.createPools(d);

        // Stable pool: liquidity concentrated around the price, like the mainnet USDC/EURC pool. Full-range
        // liquidity of this size is too shallow: the adapter's half-deposit swap would move the price ~1.5%.
        _seed(d.poolStable, U.USDC, U.EURC, U.FEE_STABLE, -1600, -600, 200_000e6, 179_400e6);
        // Volatile pool: full range, deep enough that a 5k deploy stays inside the adapter's slippage bound.
        _seed(d.poolVolatile, d.mockToken, U.USDC, U.FEE_VOLATILE, -887220, 887220, 2_000_000e6, 2_000_000e6);

        // 30 min of history, with swaps to write observations along the way.
        for (uint256 i; i < 4; ++i) {
            skip(10 minutes);
            _swap(U.USDC, U.EURC, U.FEE_STABLE, 50e6);
            _swap(U.USDC, d.mockToken, U.FEE_VOLATILE, 50e6);
        }

        stableAdapter = new HalalLPAdapter(d.npm, d.router, U.USDC, U.EURC, U.FEE_STABLE, U.USDC, vault, owner);
        volatileAdapter = new HalalLPAdapter(d.npm, d.router, d.mockToken, U.USDC, U.FEE_VOLATILE, U.USDC, vault, owner);
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _fund(address token, address who, uint256 amt) internal {
        if (token == U.USDC) vm.deal(who, who.balance + amt * NATIVE_SCALE);
        else if (token == d.mockToken) MockERC20(token).mint(who, amt);
        else deal(token, who, IERC20(token).balanceOf(who) + amt);
    }

    function _seed(address, address t0, address t1, uint24 fee, int24 lo, int24 hi, uint256 a0, uint256 a1) internal {
        _fund(t0, lp, a0);
        _fund(t1, lp, a1);
        vm.startPrank(lp);
        IERC20(t0).approve(d.npm, a0);
        IERC20(t1).approve(d.npm, a1);
        INpmMint(d.npm).mint(INpmMint.MintParams(t0, t1, fee, lo, hi, a0, a1, 0, 0, lp, block.timestamp));
        vm.stopPrank();
    }

    function _swap(address tokenIn, address tokenOut, uint24 fee, uint256 amt) internal returns (uint256 out) {
        _fund(tokenIn, trader, amt);
        vm.startPrank(trader);
        IERC20(tokenIn).approve(d.router, amt);
        out = IHalalSwapRouter(d.router).exactInputSingle(IHalalSwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn, tokenOut: tokenOut, fee: fee, recipient: trader,
            amountIn: amt, amountOutMinimum: 0, sqrtPriceLimitX96: 0
        }));
        vm.stopPrank();
    }

    function _deploy(HalalLPAdapter a, uint256 amt) internal {
        _fund(U.USDC, address(a), amt);
        vm.prank(vault);
        a.deploy(amt);
    }

    function _recallAll(HalalLPAdapter a) internal returns (uint256 got) {
        uint256 before = IERC20(U.USDC).balanceOf(vault);
        uint256 principal = a.totalDeployed();
        vm.prank(vault);
        a.recall(principal);
        got = IERC20(U.USDC).balanceOf(vault) - before;
    }

    function _coldBoundedRead(HalalLPAdapter a) internal returns (bool ok, uint256 value, uint256 gasUsed) {
        vm.cool(address(a));
        vm.cool(d.npm);
        vm.cool(IUniV3FactoryT(d.factory).getPool(a.token0(), a.token1(), a.poolFee()));
        vm.cool(U.USDC);
        uint256 g = gasleft();
        (bool success, bytes memory ret) = address(a).staticcall{gas: ShariahAccountingLogic.ADAPTER_READ_GAS}(
            abi.encodeCall(HalalLPAdapter.currentValue, ())
        );
        gasUsed = g - gasleft();
        if (success && ret.length == 32) return (true, abi.decode(ret, (uint256)), gasUsed);
        return (false, 0, gasUsed);
    }

    // ───────────────────────────── tests ─────────────────────────────

    function test_LP3_deploymentWiring() public view {
        assertEq(INpmMint(d.npm).factory(), d.factory, "NPM points at our factory");
        assertEq(IUniV3FactoryT(d.factory).getPool(U.USDC, U.EURC, U.FEE_STABLE), d.poolStable);
        assertEq(IUniV3FactoryT(d.factory).getPool(U.USDC, d.mockToken, U.FEE_VOLATILE), d.poolVolatile);
        assertLt(uint160(d.mockToken), uint160(U.USDC), "USDC is token1 in the volatile pool");
        uint32[] memory ago = new uint32[](2);
        ago[0] = 1800;
        IPoolObserve(d.poolStable).observe(ago);
        IPoolObserve(d.poolVolatile).observe(ago);
        (,,,, uint16 next,,) = IPoolObserve(d.poolStable).slot0();
        assertEq(next, U.CARDINALITY, "cardinality grown for TWAP history");
    }

    /// The canonical PoolAddress init-code hash in NPM/SwapRouter02 must match pools our factory creates, otherwise
    /// every NPM mint and router swap would revert. Seeding and swaps in setUp prove it; this checks it directly.
    function test_LP3_initCodeHashMatchesPeriphery() public view {
        bytes32 POOL_INIT_CODE_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
        address computed = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff), d.factory, keccak256(abi.encode(U.USDC, U.EURC, U.FEE_STABLE)), POOL_INIT_CODE_HASH
        )))));
        assertEq(computed, d.poolStable);
    }

    function test_LP3_stablePool_usdcToken0_roundTrip() public {
        _deploy(stableAdapter, 5_000e6);
        (bool ok, uint256 v, uint256 g) = _coldBoundedRead(stableAdapter);
        console.log("stable cold read gas", g, "value", v);
        assertTrue(ok, "cold read fits the vault read cap");
        assertApproxEqRel(v, 5_000e6, 0.01e18, "value near principal");
        uint256 got = _recallAll(stableAdapter);
        console.log("stable round trip", got);
        assertApproxEqRel(got, 5_000e6, 0.01e18);
        assertEq(stableAdapter.positionTokenId(), 0, "position closed");
    }

    function test_LP3_volatilePool_usdcToken1_roundTrip() public {
        assertEq(volatileAdapter.token1(), U.USDC);
        _deploy(volatileAdapter, 5_000e6);
        (bool ok, uint256 v, uint256 g) = _coldBoundedRead(volatileAdapter);
        console.log("volatile cold read gas", g, "value", v);
        assertTrue(ok, "cold read fits the vault read cap");
        assertApproxEqRel(v, 5_000e6, 0.02e18, "value near principal");
        uint256 got = _recallAll(volatileAdapter);
        console.log("volatile round trip", got);
        assertApproxEqRel(got, 5_000e6, 0.02e18);
    }

    /// Impermanent loss path (LP-6 d) with USDC as token1: a large move marks the position down, never up.
    function test_LP3_volatilePool_priceMove_marksDown() public {
        _deploy(volatileAdapter, 5_000e6);
        uint256 before = volatileAdapter.currentValue();
        _swap(d.mockToken, U.USDC, U.FEE_VOLATILE, 400_000e6); // dump MVOL: its USDC price falls
        skip(31 minutes); // let the TWAP follow
        _swap(U.USDC, d.mockToken, U.FEE_VOLATILE, 1e6); // write an observation at the new price
        uint256 afterMove = volatileAdapter.currentValue();
        console.log("value before / after move", before, afterMove);
        assertLt(afterMove, before, "impermanent loss marks the position down");
        assertLe(afterMove, volatileAdapter.totalDeployed(), "never marked above cost");
    }
}
