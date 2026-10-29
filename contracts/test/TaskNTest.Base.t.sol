// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ShariahVault}           from "../ShariahVault.sol";
import {TreasuryModule}         from "../TreasuryModule.sol";
import {GoldExchangeAdapter}    from "../adapters/GoldExchangeAdapter.sol";
import {GoldAllocationAdapter}  from "../adapters/GoldAllocationAdapter.sol";
import {MockERC20}              from "../test-helpers/MockERC20.sol";
import {MockAllocatedGold}      from "../test-helpers/MockAllocatedGold.sol";
import {MockXAUT}               from "../test-helpers/MockXAUT.sol";
import {MockXauUsdAggregator}   from "../test-helpers/MockXauUsdAggregator.sol";
import {MockUniswapV3PoolXAUT}  from "../test-helpers/MockUniswapV3PoolXAUT.sol";
import {RemoteRecipientFixture, MockTokenMessengerI}    from "./TaskITest.Base.t.sol";

/// @dev Fixed-price USDC<->PAXG router (price = USDC 6-dec units per 1e18 PAXG).
contract MockGoldRouterN {
    address public immutable usdc;
    uint256 public priceUsdc;

    // G-1 recall regressions need execution prices to follow oracle appreciation.
    function setPrice(uint256 price) external { priceUsdc = price; }

    constructor(address usdc_, uint256 priceUsdc_) {
        usdc = usdc_;
        priceUsdc = priceUsdc_;
    }

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

    function exactInputSingle(ExactInputSingleParams calldata p) external returns (uint256 out) {
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        out = p.tokenIn == usdc ? (p.amountIn * 1e18) / priceUsdc : (p.amountIn * priceUsdc) / 1e18;
        require(out >= p.amountOutMinimum, "MockGoldRouterN: slippage");
        IERC20(p.tokenOut).transfer(p.recipient, out);
    }
}

/// @dev Permissive IStrategyAdapter so RiskTieredExecutor (which is not the vault) can
///      run its `adapter.deploy()` leg. Holds whatever USDC the vault sent.
contract MockStrategyAdapterN {
    address public vault;
    constructor(address vault_) { vault = vault_; }
    // Record the caller to distinguish vault-funded execution from the unchanged conventional flow.
    address public lastDeployCaller;
    bool public reenter;
    function setReenter(bool enabled) external { reenter = enabled; }
    function deploy(uint256 amount) external returns (uint256) {
        lastDeployCaller = msg.sender;
        if (reenter) ShariahVault(vault).deployCapitalAndExecute(address(this), amount, "");
        return amount;
    }
    function recall(uint256) external pure returns (uint256) { return 0; }
    function currentValue() external pure returns (uint256) { return 0; }
    function protocolName() external pure returns (string memory) { return "MockStrategyN"; }
}

/// @dev Shared N1 fixture: ShariahVault holding REAL gold in both S2-H (GoldExchangeAdapter)
///      and S6-H (GoldAllocationAdapter), with a configured mock TokenMessenger.
///      No test/fuzz/invariant functions here.
abstract contract TaskNBase is Test {
    address internal owner    = makeAddr("owner");
    address internal manager  = makeAddr("manager");
    address internal alice    = makeAddr("alice");
    address internal stranger = makeAddr("stranger");

    uint32  internal constant SOURCE_DOMAIN = 26;
    uint32  internal constant DEST_DOMAIN   = 3;
    uint8   internal constant ETH_SPREAD    = 0;
    uint8   internal constant GOLD_SPREAD   = 1;
    uint8   internal constant HALAL_LP      = 2;
    uint8   internal constant MURABAHA      = 3;
    uint8   internal constant GOLD_ALLOC    = 5;
    uint256 internal constant PAXG_PRICE    = 3_300e6;
    uint256 internal constant POOL_PRICE    = 3_300_000_000;
    uint256 internal constant DEPOSIT       = 1_000_000e6;
    uint256 internal constant GOLD_BUY      = 100_000e6;

    MockERC20             internal usdc;
    MockAllocatedGold     internal paxg;
    MockXAUT              internal xaut;
    MockXauUsdAggregator  internal oracle;
    MockUniswapV3PoolXAUT internal pool;
    MockGoldRouterN       internal router;
    MockTokenMessengerI   internal messenger;
    TreasuryModule        internal treasury;
    ShariahVault          internal svault;
    GoldExchangeAdapter   internal goldAdapter;   // S2-H
    GoldAllocationAdapter internal allocAdapter;  // S6-H

    function setUp() public virtual {
        vm.warp(1_700_000_000);

        usdc      = new MockERC20("Mock USDC", "mUSDC", 6);
        paxg      = new MockAllocatedGold();
        xaut      = new MockXAUT();
        oracle    = new MockXauUsdAggregator();
        pool      = new MockUniswapV3PoolXAUT(address(usdc), address(xaut), POOL_PRICE);
        router    = new MockGoldRouterN(address(usdc), PAXG_PRICE);
        messenger = new MockTokenMessengerI();

        vm.startPrank(owner);
        // adminFeeBps = 0 so Wakala accrual never needs a feeSource.
        treasury = new TreasuryModule("Shariah", address(0), address(usdc), 0, 0, 0, owner);
        svault = new ShariahVault(
            IERC20(address(usdc)), owner, SOURCE_DOMAIN, address(treasury), address(0)
        );
        svault.setManager(manager);
        goldAdapter = new GoldExchangeAdapter(
            address(usdc), address(paxg), address(router), 3000,
            address(svault), owner, address(oracle)
        );
        allocAdapter = new GoldAllocationAdapter(
            address(usdc), address(xaut), address(pool), 3000,
            address(oracle), address(svault), 3600, owner
        );
        svault.setScreened(address(goldAdapter), true);
        svault.setScreened(address(allocAdapter), true);
        svault.setGoldSpreadAdapter(address(goldAdapter));
        svault.setGoldAllocationAdapter(address(allocAdapter));
        svault.setTokenMessenger(address(messenger));
        svault.setMaxPendingCrossChainBps(5_000);
        vm.stopPrank();

        // Liquidity for the swap venues.
        paxg.mint(address(router), 1_000_000e18);
        usdc.mint(address(router), 50_000_000e6);
        usdc.mint(address(this), 50_000_000e6);
        xaut.mint(address(this), 20_000e6);
        usdc.approve(address(pool), 50_000_000e6);
        xaut.approve(address(pool), 20_000e6);
        pool.fundPool(50_000_000e6, 20_000e6);

        usdc.mint(alice, DEPOSIT);
        vm.startPrank(alice);
        usdc.approve(address(svault), DEPOSIT);
        svault.deposit(DEPOSIT, alice);
        vm.stopPrank();

        RemoteRecipientFixture.approve(vm, svault, owner, DEST_DOMAIN, _bytes32(alice));
        oracle.setPrice(330_000_000_000);

        // Hold gold in BOTH adapters.
        _buyGold(address(goldAdapter), GOLD_BUY);
        // Check realistic 6/18-dec valuation before any oracle refresh can hide entry scaling errors.
        assertApproxEqAbs(goldAdapter.currentValue(), GOLD_BUY, 1);
        assertApproxEqAbs(goldAdapter.lastGoodPrice(), PAXG_PRICE, 1);
        goldAdapter.pokePrice(); // Entry and oracle prices now share units; retain oracle-refresh coverage.
        _buyGold(address(allocAdapter), GOLD_BUY);
    }

    function _buyGold(address adapter, uint256 amount) internal {
        vm.prank(manager);
        svault.deployCapitalAndExecute(adapter, amount, "");
    }

    function _bytes32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }
}
