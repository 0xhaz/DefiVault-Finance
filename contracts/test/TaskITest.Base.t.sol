// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AutonomousVault}       from "../AutonomousVault.sol";
import {ShariahVault}          from "../ShariahVault.sol";
import {TreasuryModule}        from "../TreasuryModule.sol";
import {CharityModule}         from "../CharityModule.sol";
import {PurificationEscrow}    from "../PurificationEscrow.sol";
import {ShariahAdapterRegistry} from "../ShariahAdapterRegistry.sol";
import {GoldExchangeAdapter}    from "../adapters/GoldExchangeAdapter.sol";
import {MockERC20}              from "../test-helpers/MockERC20.sol";
import {MockAllocatedGold}      from "../test-helpers/MockAllocatedGold.sol";
import {MockXauUsdAggregator}   from "../test-helpers/MockXauUsdAggregator.sol";

/// @dev Shared fixture helper: never bypass governance storage or shorten its delay.
library RemoteRecipientFixture {
    function approve(Vm vm, ShariahVault target, address board, uint32 domain, bytes32 recipient) internal {
        if (target.approvedRemoteRecipient(domain, recipient)) return;
        vm.prank(board);
        target.proposeRemoteRecipient(domain, recipient, true);
        vm.warp(block.timestamp + 30 days);
        vm.prank(board);
        target.confirmRemoteRecipient(domain, recipient);
    }
}

// ─── Minimal mock token messenger ────────────────────────────────────────────
// Records native V2 calls; does NOT burn real tokens (balance stays in vault).
contract MockTokenMessengerI is Test {
    // Task M: Circle returns no nonce; retain no-burn fixture intent and record V2 arguments.
    bytes public lastCall;
    uint64 public callCount;
    function depositForBurn(uint256 amount, uint32 domain, bytes32 recipient, address token,
        bytes32 caller, uint256 maxFee, uint32 finality) external {
        lastCall = abi.encode(amount, domain, recipient, token, caller, maxFee, finality);
        ++callCount;
    }
}

// ─── Minimal mock swap router (USDC↔PAXG 1:1) ─────────────────────────────
contract MockSwapRouterI {
    bool public returnZero;
    function setReturnZero(bool z) external { returnZero = z; }

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
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        if (returnZero) return 0;
        amountOut = MockERC20(p.tokenIn).decimals() == 6
            ? p.amountIn * 1e18 / 3_300e6
            : p.amountIn * 3_300e6 / 1e18;
        require(amountOut >= p.amountOutMinimum, "MockSwapRouterI: slippage");
        IERC20(p.tokenOut).transfer(p.recipient, amountOut);
    }
}

// ─── Mock IGoldAdapter for S6-H (GoldAllocationAdapter stub) ─────────────────
contract MockGoldAllocationAdapterI {
    function isGoldStrategy() external pure returns (bool) { return true; }
    bool public sane = true;
    uint256 public value;

    function setSane(bool s) external { sane = s; }
    function setValue(uint256 v) external { value = v; }

    function isPriceSane() external view returns (bool) { return sane; }
    function currentValue() external view returns (uint256) { return value; }
    function deploy(uint256) external returns (uint256) { return 0; } // N-23: vault-executed funding path for the value-only mock
}

// ─── Shared base ─────────────────────────────────────────────────────────────

abstract contract TaskITestBase is Test {

    // ── Actors ───────────────────────────────────────────────────────────────
    address internal owner        = makeAddr("owner");
    address internal manager      = makeAddr("manager");
    address internal alice        = makeAddr("alice");
    address internal boardMember  = makeAddr("boardMember");
    address internal nonBoard     = makeAddr("nonBoard");

    // ── Common tokens ────────────────────────────────────────────────────────
    MockERC20         internal usdc;
    MockAllocatedGold internal paxg;

    // ── I1: AutonomousVault with mock CCTP messenger ──────────────────────────
    MockTokenMessengerI  internal messenger;
    AutonomousVault      internal vault;

    // ── I2: GoldExchangeAdapter + ShariahVault ────────────────────────────────
    MockSwapRouterI            internal router;
    MockXauUsdAggregator       internal xauOracle;
    ShariahVault               internal svault;
    TreasuryModule             internal sTreasury;
    GoldExchangeAdapter        internal goldAdapter;
    MockGoldAllocationAdapterI internal goldAllocAdapter;

    // ── I3: TreasuryModule (Shariah) ──────────────────────────────────────────
    TreasuryModule internal treasury;

    // ── I4/I5: Registry, CharityModule, PurificationEscrow ───────────────────
    ShariahAdapterRegistry internal registry;
    CharityModule           internal charity;
    PurificationEscrow      internal escrow;

    uint32 internal constant SOURCE_DOMAIN = 26;
    uint32 internal constant DEST_DOMAIN   = 3;

    function setUp() public virtual {
        // ── Tokens ──────────────────────────────────────────────────────────
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);
        paxg = new MockAllocatedGold();

        // ── I1: AutonomousVault ──────────────────────────────────────────────
        messenger = new MockTokenMessengerI();
        vm.startPrank(owner);
        vault = new AutonomousVault(IERC20(address(usdc)), owner, SOURCE_DOMAIN);
        vault.setManager(manager);
        vault.setTokenMessenger(address(messenger));
        vault.setMaxAllocationBps(9_000); // allow up to 90%
        vault.setMaxPendingCrossChainBps(5_000); // 50% cross-chain cap
        vm.stopPrank();

        // Seed vault: alice deposits 100k USDC
        usdc.mint(alice, 100_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, alice);
        vm.stopPrank();

        // ── I2: ShariahVault + GoldExchangeAdapter ───────────────────────────
        router    = new MockSwapRouterI();
        xauOracle = new MockXauUsdAggregator(); // K2: mandatory oracle

        vm.startPrank(owner);
        sTreasury = new TreasuryModule(
            "Shariah", address(0), address(usdc), 50, 1000, 400, owner
        );
        svault = new ShariahVault(
            IERC20(address(usdc)), owner, SOURCE_DOMAIN, address(sTreasury), address(0)
        );
        svault.setManager(manager);
        goldAdapter = new GoldExchangeAdapter(
            address(usdc), address(paxg), address(router), 3000,
            address(svault), owner, address(xauOracle)
        );
        svault.setScreened(address(goldAdapter), true);
        svault.setGoldSpreadAdapter(address(goldAdapter));
        // S6-H mock
        goldAllocAdapter = new MockGoldAllocationAdapterI();
        vm.stopPrank();

        // Seed router with PAXG for swaps (1:1)
        paxg.mint(address(router), 2_000_000e18);
        // Seed router with USDC for reverse swaps
        usdc.mint(address(router), 50_000_000e6);

        // Alice deposits 100k USDC into svault
        usdc.mint(alice, 100_000e6);
        vm.startPrank(alice);
        usdc.approve(address(svault), 100_000e6);
        svault.deposit(100_000e6, alice);
        vm.stopPrank();

        // ── I3: Pure TreasuryModule (no feeSource required for view fn) ───────
        treasury = new TreasuryModule(
            "Shariah", address(0), address(usdc), 50, 1000, 400, owner
        );

        // ── I4/I5: Registry + CharityModule + PurificationEscrow ─────────────
        // I5: deployer != boardMember
        registry = new ShariahAdapterRegistry(owner, boardMember);

        // CharityModule with registry
        charity = new CharityModule(
            makeAddr("charityWallet"),
            address(usdc),
            address(svault),
            owner,
            address(registry)
        );

        // PurificationEscrow with registry
        // Need charityModule vault to be the escrow (or bypass). Use a minimal setup:
        // escrow's vault = address(this test contract) so we can call executeWaterfall
        escrow = new PurificationEscrow(
            address(svault),       // vault
            address(usdc),
            address(charity),
            address(sTreasury),
            owner,
            address(registry)      // boardRegistry → I4
        );
    }

    // ── Helper: deploy cross-chain from vault (I1) ──────────────────────────
    // Task M: return the vault's local position ID, not an offchain CCTP nonce.
    function _deployCrossChainI1(uint256 amount) internal returns (uint64 positionId) {
        vm.prank(manager);
        vault.deployCrossChain(DEST_DOMAIN, bytes32(uint256(uint160(alice))), amount);
        positionId = vault.crossChainPositionCounter();
    }

    // ── Helper: deploy + swap via svault/goldAdapter ──────────────────────────
    function _deployAndSwapGold(uint256 usdcAmt) internal {
        vm.prank(manager);
        // Use the atomic entry point so the real vault satisfies adapter caller authorization.
        svault.deployCapitalAndExecute(address(goldAdapter), usdcAmt, "");
    }
}
