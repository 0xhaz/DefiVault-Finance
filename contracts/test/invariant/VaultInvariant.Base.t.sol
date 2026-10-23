// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test}      from "forge-std/Test.sol";
import {IERC20}    from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ShariahVault}           from "../../ShariahVault.sol";
import {TreasuryModule}         from "../../TreasuryModule.sol";
import {CharityModule}          from "../../CharityModule.sol";
import {PurificationEscrow}     from "../../PurificationEscrow.sol";
import {GoldExchangeAdapter}    from "../../adapters/GoldExchangeAdapter.sol";
import {GoldAllocationAdapter}  from "../../adapters/GoldAllocationAdapter.sol";
import {MockERC20}              from "../../test-helpers/MockERC20.sol";
import {MockAllocatedGold}      from "../../test-helpers/MockAllocatedGold.sol";
import {MockXAUT}               from "../../test-helpers/MockXAUT.sol";
import {MockXauUsdAggregator}   from "../../test-helpers/MockXauUsdAggregator.sol";
import {MockUniswapV3PoolXAUT}  from "../../test-helpers/MockUniswapV3PoolXAUT.sol";

// ── Minimal mock registry: only the manager is a board member ─────────────────
contract MockRegistryInv {
    address public boardMember;
    constructor(address b) { boardMember = b; }
    function isBoard(address a) external view returns (bool) { return a == boardMember; }
}

// ── Mock PAXG swap router: fixed-ratio USDC↔PAXG swaps ──────────────────────
// 1 PAXG (18 dec) = 3_300_000_000 USDC (6 dec)
// USDC→PAXG: amountOut_paxg = amountIn_usdc * 1e18 / 3_300_000_000
// PAXG→USDC: amountOut_usdc = amountIn_paxg * 3_300_000_000 / 1e18
contract MockPaxgRouter {
    IERC20 public usdc;
    IERC20 public paxg;
    uint256 public constant USDC_PER_PAXG = 3_300_000_000; // 6-dec USDC per PAXG (1oz ≈ $3300)

    constructor(address usdc_, address paxg_) {
        usdc = IERC20(usdc_);
        paxg = IERC20(paxg_);
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

    function exactInputSingle(ExactInputSingleParams calldata p)
        external returns (uint256 amountOut)
    {
        require(block.timestamp <= p.deadline, "deadline");
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        if (p.tokenIn == address(usdc)) {
            // USDC→PAXG
            amountOut = (p.amountIn * 1e18) / USDC_PER_PAXG;
        } else {
            // PAXG→USDC
            amountOut = (p.amountIn * USDC_PER_PAXG) / 1e18;
        }
        require(amountOut >= p.amountOutMinimum, "slippage");
        IERC20(p.tokenOut).transfer(p.recipient, amountOut);
    }
}

// ── Shared base: deploys the full ShariahVault stack ─────────────────────────
abstract contract VaultInvariantBase is Test {

    // ── Actors ──────────────────────────────────────────────────────────────
    address public owner   = makeAddr("owner");
    address public manager = makeAddr("manager");
    address public alice   = makeAddr("alice");
    address public bob     = makeAddr("bob");
    address public carol   = makeAddr("carol");
    address public charity = makeAddr("charity");

    address[3] public actors;

    // ── Tokens ───────────────────────────────────────────────────────────────
    MockERC20            public usdc;
    MockAllocatedGold    public paxg;
    MockXAUT             public xaut;
    MockXauUsdAggregator public xauOracle;
    MockUniswapV3PoolXAUT public xautPool;
    MockPaxgRouter       public paxgRouter;

    // ── Protocol ─────────────────────────────────────────────────────────────
    TreasuryModule       public treasury;
    CharityModule        public charityModule;
    PurificationEscrow   public purificationEscrow;
    GoldExchangeAdapter  public goldSpreadAdp;
    GoldAllocationAdapter public goldAllocAdp;
    ShariahVault         public vault;
    MockRegistryInv      public registry;

    // ── Constants ─────────────────────────────────────────────────────────────
    uint32  internal constant SOURCE_DOMAIN     = 26;
    uint256 internal constant POOL_USDC_PER_XAUT = 3_300_000_000; // $3300
    int256  internal constant ORACLE_PRICE      = 330_000_000_000; // 8 dec
    uint256 internal constant MAX_STALENESS     = 30 days;        // match adapter

    function setUp() public virtual {
        vm.warp(1_700_000_000); // realistic start time

        actors = [alice, bob, carol];

        // Pre-compute escrow address: record nonce BEFORE any deploy from address(this).
        // Deploys from address(this):
        //   +0: usdc, +1: paxg, +2: xaut, +3: xauOracle, +4: xautPool, +5: paxgRouter,
        //   +6: registry, +7: treasury, +8: purificationEscrow
        // Deploys from owner (vm.prank) do NOT consume address(this)'s nonce.
        uint256 startNonce = vm.getNonce(address(this));
        address expectedEscrow = vm.computeCreateAddress(address(this), startNonce + 8);

        // ── Tokens ────────────────────────────────────────────────────────────
        usdc      = new MockERC20("Mock USDC", "mUSDC", 6);
        paxg      = new MockAllocatedGold();
        xaut      = new MockXAUT();
        xauOracle = new MockXauUsdAggregator();
        xautPool  = new MockUniswapV3PoolXAUT(address(usdc), address(xaut), POOL_USDC_PER_XAUT);
        paxgRouter = new MockPaxgRouter(address(usdc), address(paxg));

        // Seed pool with liquidity
        usdc.mint(address(this), 100_000_000e6);
        xaut.mint(address(this), 100_000e6);
        usdc.approve(address(xautPool), 100_000_000e6);
        xaut.approve(address(xautPool), 100_000e6);
        xautPool.fundPool(100_000_000e6, 100_000e6);

        // Seed PAXG router
        paxg.mint(address(paxgRouter), 10_000e18);
        usdc.mint(address(paxgRouter), 100_000_000e6);

        // ── Registry ──────────────────────────────────────────────────────────
        registry = new MockRegistryInv(manager); // manager is the board member

        // ── Treasury ─────────────────────────────────────────────────────────
        // feeSource = expectedEscrow (deployed as deploy #8 from address(this))
        treasury = new TreasuryModule(
            "Shariah",
            expectedEscrow, // feeSource = escrow
            address(usdc),
            50,    // wakalaFeeBps 0.5%
            1000,  // musharakahShareBps 10%
            400,   // hurdleRateBps 4%
            owner
        );

        vm.startPrank(owner);

        charityModule = new CharityModule(
            charity,
            address(usdc),
            expectedEscrow, // vault = escrow (charityModule.distributeCharity called by escrow)
            owner,
            address(registry)
        );

        vault = new ShariahVault(
            IERC20(address(usdc)),
            owner,
            SOURCE_DOMAIN,
            address(treasury),
            address(0) // no ZakatModule
        );
        vault.setManager(manager);
        vault.setShariahScreening(false); // disable screening for simplicity
        vault.setMaxAllocationBps(8000);

        goldSpreadAdp = new GoldExchangeAdapter(
            address(usdc), address(paxg), address(paxgRouter), 3000,
            address(vault), owner
        );

        goldAllocAdp = new GoldAllocationAdapter(
            address(usdc),
            address(xaut),
            address(xautPool),
            3000,
            address(xauOracle),
            address(vault),
            MAX_STALENESS,
            owner
        );
        // pool address for slot0 read
        goldAllocAdp.setPool(address(xautPool));

        vault.setScreened(address(goldSpreadAdp), true);
        vault.setScreened(address(goldAllocAdp), true);
        vault.setGoldSpreadAdapter(address(goldSpreadAdp));
        vault.setGoldAllocationAdapter(address(goldAllocAdp));

        vm.stopPrank();

        purificationEscrow = new PurificationEscrow(
            address(vault),
            address(usdc),
            address(charityModule),
            address(treasury),
            owner,
            address(registry)
        );
        require(address(purificationEscrow) == expectedEscrow, "escrow addr mismatch");

        vm.prank(owner);
        vault.setPurificationEscrow(address(purificationEscrow));

        // ── Seed depositors ────────────────────────────────────────────────────
        for (uint256 i = 0; i < actors.length; i++) {
            usdc.mint(actors[i], 1_000_000e6);
            vm.prank(actors[i]);
            usdc.approve(address(vault), type(uint256).max);
        }
    }

    // ── Helper: compute _currentLockedProfit() inline ────────────────────────
    function _currentLockedProfitPublic() internal view returns (uint256) {
        uint256 lp = vault.lockedProfit();
        if (lp == 0) return 0;
        uint256 ua = vault.unlockedAt();
        if (block.timestamp >= ua) return 0;
        uint256 period   = vault.profitUnlockPeriod();
        uint256 elapsed  = block.timestamp - (ua - period);
        if (elapsed >= period) return 0;
        return (lp * (period - elapsed)) / period;
    }
}
