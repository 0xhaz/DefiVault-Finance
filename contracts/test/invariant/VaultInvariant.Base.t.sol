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
contract MockPaxgRouter {
    IERC20 public usdc;
    IERC20 public paxg;
    uint256 public constant USDC_PER_PAXG = 3_300_000_000;

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
            amountOut = (p.amountIn * 1e18) / USDC_PER_PAXG;
        } else {
            amountOut = (p.amountIn * USDC_PER_PAXG) / 1e18;
        }
        require(amountOut >= p.amountOutMinimum, "slippage");
        IERC20(p.tokenOut).transfer(p.recipient, amountOut);
    }
}

// ── Mock CCTP TokenMessenger: returns sequential nonces, does NOT burn ────────
// (vault balance is NOT decremented; tests sim cross-chain by calling settle)
contract MockMessengerInv {
    uint64 public nextNonce = 1;
    function depositForBurnWithCaller(
        uint256, uint32, bytes32, address, bytes32
    ) external returns (uint64 nonce) {
        nonce = nextNonce++;
    }
}

// ── Mock CCTP MessageTransmitter: settable mint-on-receiveMessage ─────────────
contract MockTransmitterInv {
    address public usdc;
    address public target; // vault
    uint256 public mintAmount;

    constructor(address usdc_, address target_) {
        usdc   = usdc_;
        target = target_;
    }

    function setMintAmount(uint256 a) external { mintAmount = a; }

    function receiveMessage(bytes calldata, bytes calldata) external returns (bool) {
        if (mintAmount > 0) {
            MockERC20Like2(usdc).mint(target, mintAmount);
        }
        return true;
    }
}

interface MockERC20Like2 {
    function mint(address to, uint256 amount) external;
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
    MockXauUsdAggregator public xauOracle;          // S6-H oracle (XAU/USD)
    MockXauUsdAggregator public goldSpreadOracle_;  // S2-H oracle (K2: mandatory)
    MockUniswapV3PoolXAUT public xautPool;
    MockPaxgRouter       public paxgRouter;

    // ── CCTP mocks ───────────────────────────────────────────────────────────
    MockMessengerInv    public mockMessenger_;
    MockTransmitterInv  public mockTransmitter_;

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
    uint256 internal constant POOL_USDC_PER_XAUT = 3_300_000_000;
    int256  internal constant ORACLE_PRICE      = 330_000_000_000; // 8 dec
    uint256 internal constant MAX_STALENESS     = 30 days;

    // ── Accessor helpers for handler ─────────────────────────────────────────
    function goldSpreadOracle()  public view returns (MockXauUsdAggregator) { return goldSpreadOracle_;  }
    function mockMessenger()     public view returns (MockMessengerInv)     { return mockMessenger_;     }
    function mockTransmitter()   public view returns (MockTransmitterInv)   { return mockTransmitter_;   }

    function setUp() public virtual {
        vm.warp(1_700_000_000); // realistic start time

        actors = [alice, bob, carol];

        // Pre-compute escrow address.
        // Deploys from address(this) in order:
        //   +0: usdc
        //   +1: paxg
        //   +2: xaut
        //   +3: xauOracle
        //   +4: goldSpreadOracle_   (NEW — K2)
        //   +5: xautPool
        //   +6: paxgRouter
        //   +7: mockMessenger_      (NEW — PR2)
        //   +8: registry
        //   +9: treasury
        //   +10: purificationEscrow
        uint256 startNonce = vm.getNonce(address(this));
        address expectedEscrow = vm.computeCreateAddress(address(this), startNonce + 10);

        // ── Tokens ────────────────────────────────────────────────────────────
        usdc             = new MockERC20("Mock USDC", "mUSDC", 6);
        paxg             = new MockAllocatedGold();
        xaut             = new MockXAUT();
        xauOracle        = new MockXauUsdAggregator();
        goldSpreadOracle_ = new MockXauUsdAggregator(); // K2: separate oracle for S2-H
        xautPool         = new MockUniswapV3PoolXAUT(address(usdc), address(xaut), POOL_USDC_PER_XAUT);
        paxgRouter       = new MockPaxgRouter(address(usdc), address(paxg));

        // ── CCTP mocks ────────────────────────────────────────────────────────
        mockMessenger_ = new MockMessengerInv();

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
        registry = new MockRegistryInv(manager);

        // ── Treasury ─────────────────────────────────────────────────────────
        treasury = new TreasuryModule(
            "Shariah",
            expectedEscrow,
            address(usdc),
            50,   // wakalaFeeBps 0.5%
            1000, // musharakahShareBps 10%
            400,  // hurdleRateBps 4%
            owner
        );

        vm.startPrank(owner);

        charityModule = new CharityModule(
            charity,
            address(usdc),
            expectedEscrow,
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
        vault.setShariahScreening(false);
        vault.setMaxAllocationBps(8000);
        // Wire CCTP for cross-chain handler actions (PR2)
        vault.setTokenMessenger(address(mockMessenger_));
        vault.setMaxPendingCrossChainBps(2000); // 20% cap

        goldSpreadAdp = new GoldExchangeAdapter(
            address(usdc), address(paxg), address(paxgRouter), 3000,
            address(vault), owner, address(goldSpreadOracle_) // K2: mandatory oracle
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

        // Deploy MockTransmitter AFTER vault address is known
        // (doesn't count in the escrow nonce since it's after purificationEscrow)
        mockTransmitter_ = new MockTransmitterInv(address(usdc), address(vault));

        vm.startPrank(owner);
        vault.setPurificationEscrow(address(purificationEscrow));
        vault.setMessageTransmitter(address(mockTransmitter_));
        vm.stopPrank();

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
