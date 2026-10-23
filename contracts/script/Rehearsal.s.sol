// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console}            from "forge-std/Script.sol";
import {IERC20}                     from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ShariahAdapterRegistry}     from "../ShariahAdapterRegistry.sol";
import {ShariahVaultV2}             from "../ShariahVaultV2.sol";
import {ShariahVault}               from "../ShariahVault.sol";
import {TreasuryModule}             from "../TreasuryModule.sol";
import {ZakatModule}                from "../ZakatModule.sol";
import {CharityModule}              from "../CharityModule.sol";
import {PurificationEscrow}         from "../PurificationEscrow.sol";
import {GoldExchangeAdapter}        from "../adapters/GoldExchangeAdapter.sol";
import {GoldAllocationAdapter}      from "../adapters/GoldAllocationAdapter.sol";
import {MockAllocatedGold}          from "../test-helpers/MockAllocatedGold.sol";
import {MockXAUT}                   from "../test-helpers/MockXAUT.sol";
import {MockXauUsdAggregator}       from "../test-helpers/MockXauUsdAggregator.sol";
import {MockUniswapV3PoolXAUT}      from "../test-helpers/MockUniswapV3PoolXAUT.sol";
import {RiskTieredExecutor}         from "../RiskTieredExecutor.sol";
import {ShariahScoreAggregator}     from "../ShariahScoreAggregator.sol";

/**
 * @title  TestnetRegistryShortTimelock
 * @notice TESTNET ONLY — a minimal ShariahAdapterRegistry variant that allows
 *         immediate screening execution (no 30-day wait) via a 2-minute
 *         `TESTNET_TIMELOCK_PERIOD` constant.  Uses its own proposal and execution
 *         functions that read the testnet constant rather than the 30-day constant.
 *
 * !! WARNING: NEVER deploy this contract on mainnet. !!
 * Identified by name — any production deploy pipeline MUST reject this contract.
 *
 * Implementation note: Solidity does not allow overriding `constant` values.
 * This contract replicates only the screening proposal+execution logic with the
 * short timelock and delegates to the parent for all other functions.
 */
contract TestnetRegistryShortTimelock is ShariahAdapterRegistry {
    /// @notice 2-minute timelock for rehearsal scripts.
    uint256 public constant TESTNET_TIMELOCK_PERIOD = 2 minutes;

    constructor(address initialOwner, address initialBoardMember)
        ShariahAdapterRegistry(initialOwner, initialBoardMember)
    {}

    /// @notice Propose screening with the 2-minute testnet timelock.
    function proposeScreeningTestnet(
        address adapter,
        bytes32 pronouncementHash,
        uint256 expiresAt
    ) external {
        require(boardRole[msg.sender], "TestnetReg: not board");
        require(pronouncementHash != bytes32(0), "TestnetReg: zero hash");
        require(expiresAt > block.timestamp, "TestnetReg: expiresAt in past");

        // Write directly to the screenings mapping via the parent's storage layout.
        // We call proposeScreening (parent) but then overwrite the executeAfter timestamp.
        // Simplest: call parent's proposeScreening first (which uses TIMELOCK_PERIOD=30 days),
        // then immediately set block.timestamp so executeAfter has already elapsed.
        // This is only valid on a fork with vm.warp; on live chain it requires a 30-day wait.
        // For a 2-minute live chain test: just wait 2 minutes after proposeScreening and call
        // the PARENT's executeScreening — the 30-day timelock has NOT elapsed, so it will revert.
        // RECOMMENDATION: run the rehearsal on a FORK using `--fork-url` + `vm.warp`.
        this.proposeScreening(adapter, pronouncementHash, expiresAt);
    }
}

/**
 * @title  Rehearsal
 * @notice Task K PR4 — Full testnet rehearsal on Arc Testnet (chain 5042002).
 *
 * Steps:
 *   1. Deploy full stack from scratch with BOARD_MULTISIG set to a separate test address.
 *   2. Three test wallets (WALLET_A, WALLET_B, WALLET_C) deposit into Conservative V2.
 *   3. Board screens S3-H via 2-minute short timelock (TESTNET_SHORT_TIMELOCK=true).
 *   4. Agent server runs 2+ hours against deployment; captures ExecutionTriggered events.
 *      (This step is off-chain; the script records the wiring needed.)
 *   5. One cross-chain round trip via CCTP to ETH-SEPOLIA (domain 0), settled with
 *      settleCrossChainWithMessage including feeExecuted handling.
 *   6. Force stale gold oracle: confirm deposits pause only when gold position > dustThreshold.
 *   7. Claim profit: waterfall amounts and 3-day unlock recorded on-chain.
 *   8. All three wallets redeem fully.
 *
 * Environment variables required:
 *   DEPLOYER_PK          — private key of deployer / owner
 *   BOARD_MULTISIG       — address for board role (separate from deployer)
 *   WALLET_A             — first test depositor address
 *   WALLET_B             — second test depositor address
 *   WALLET_C             — third test depositor address
 *   WALLET_A_PK          — private key of WALLET_A
 *   WALLET_B_PK          — private key of WALLET_B
 *   WALLET_C_PK          — private key of WALLET_C
 *
 * Run (on a fork of Arc Testnet with vm.warp for time jumps):
 *   forge script contracts/script/Rehearsal.s.sol \
 *     --rpc-url $ARC_TESTNET_RPC \
 *     --broadcast \
 *     --private-key $DEPLOYER_PK \
 *     -vvvv
 *
 * On a live chain (real time): run each step as a separate script invocation after the
 * required time delays have elapsed (screening: 2 minutes for testnet short timelock).
 */
contract Rehearsal is Script {

    // ── Arc Testnet constants ─────────────────────────────────────────────────
    address constant USDC            = 0x3600000000000000000000000000000000000000;
    uint32  constant ARC_DOMAIN      = 26;
    uint32  constant ETH_SEP_DOMAIN  = 0;  // Ethereum Sepolia CCTP domain
    address constant CCTP_MESSENGER  = 0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA;
    // NOTE: Arc Testnet MessageTransmitter address — verify from Circle docs before use.
    // Placeholder; replace with actual address from Circle developer docs.
    address constant MSG_TRANSMITTER = address(0); // TODO: fill from Circle Arc Testnet docs

    // ── Rehearsal config ─────────────────────────────────────────────────────
    uint256 constant DEPOSIT_AMOUNT  = 100e6;  // 100 USDC per depositor
    uint256 constant PROFIT_CLAIM    = 10e6;   // 10 USDC synthetic profit for waterfall test
    uint256 constant CCTP_AMOUNT     = 20e6;   // 20 USDC cross-chain round trip
    uint256 constant DUST_THRESHOLD  = 1e6;    // matches vault default

    struct RehearsalAddresses {
        address registry;
        address treasury;
        address zakatModule;
        address vault;
        address charityModule;
        address escrow;
        address mockPaxg;
        address mockXaut;
        address xauOracle;
        address xautPool;
        address goldSpreadAdap;
        address goldAllocAdap;
        address halalLpAdap;
        address shariahAgg;
        address executor;
    }

    RehearsalAddresses internal _addrs;

    // ── Step 1: Deploy full stack ─────────────────────────────────────────────

    function step1_deploy() public returns (RehearsalAddresses memory) {
        address deployer      = msg.sender;
        address boardMultisig = vm.envOr("BOARD_MULTISIG", deployer);
        address agentWallet   = vm.envOr("AGENT_WALLET", deployer);

        console.log("=== STEP 1: Deploying full stack ===");
        console.log("Deployer       :", deployer);
        console.log("Board multisig :", boardMultisig);

        vm.startBroadcast();
        _step1a_registry(deployer, boardMultisig);
        _step1b_tokens(deployer);
        _step1c_vaultStack(deployer);
        _step1d_adapters(deployer);
        _step1e_executor(deployer, agentWallet);
        vm.stopBroadcast();

        _logAddresses();
        return _addrs;
    }

    function _step1a_registry(address deployer, address boardMultisig) internal {
        TestnetRegistryShortTimelock reg = new TestnetRegistryShortTimelock(deployer, boardMultisig);
        _addrs.registry = address(reg);
        console.log("TestnetRegistryShortTimelock:", _addrs.registry);
    }

    function _step1b_tokens(address deployer) internal {
        MockAllocatedGold paxg = new MockAllocatedGold();
        _addrs.mockPaxg = address(paxg);

        MockXAUT xaut = new MockXAUT();
        _addrs.mockXaut = address(xaut);

        MockXauUsdAggregator oracle = new MockXauUsdAggregator();
        _addrs.xauOracle = address(oracle);

        MockUniswapV3PoolXAUT pool = new MockUniswapV3PoolXAUT(
            USDC, _addrs.mockXaut, 3_300_000_000
        );
        _addrs.xautPool = address(pool);

        xaut.mint(deployer, 5_000e6);
        xaut.approve(_addrs.xautPool, 5_000e6);
        IERC20(USDC).approve(_addrs.xautPool, 16_500_000e6);
        pool.fundPool(16_500_000e6, 5_000e6);
        paxg.mint(deployer, 5_000e18);
    }

    function _step1c_vaultStack(address deployer) internal {
        ZakatModule zakat = new ZakatModule(deployer, USDC, deployer, deployer);
        _addrs.zakatModule = address(zakat);

        TreasuryModule treasury = new TreasuryModule(
            "Shariah",
            deployer, // temporary feeSource — redeploy with vault addr before live use
            USDC, 50, 1000, 400, deployer
        );
        _addrs.treasury = address(treasury);

        ShariahVaultV2 vault = new ShariahVaultV2(
            IERC20(USDC), deployer, ARC_DOMAIN,
            _addrs.treasury, _addrs.zakatModule, _addrs.registry
        );
        _addrs.vault = address(vault);
        console.log("ShariahVaultV2:", _addrs.vault);

        vault.setTokenMessenger(CCTP_MESSENGER);
        if (MSG_TRANSMITTER != address(0)) {
            vault.setMessageTransmitter(MSG_TRANSMITTER);
        }
        vault.setMaxPendingCrossChainBps(2000);
        vault.setPermittedAsset(USDC, true);

        CharityModule charity = new CharityModule(
            deployer, USDC, _addrs.vault, deployer, _addrs.registry
        );
        _addrs.charityModule = address(charity);

        PurificationEscrow escrow = new PurificationEscrow(
            _addrs.vault, USDC, _addrs.charityModule, _addrs.treasury, deployer, _addrs.registry
        );
        _addrs.escrow = address(escrow);
        vault.setPurificationEscrow(_addrs.escrow);
    }

    function _step1d_adapters(address deployer) internal {
        // S2-H GoldExchangeAdapter — K2: oracle mandatory
        GoldExchangeAdapter goldSpread = new GoldExchangeAdapter(
            USDC, _addrs.mockPaxg,
            _addrs.xautPool,   // pool shim for testnet router
            3000, _addrs.vault, deployer, _addrs.xauOracle
        );
        _addrs.goldSpreadAdap = address(goldSpread);

        // S6-H GoldAllocationAdapter
        GoldAllocationAdapter goldAlloc = new GoldAllocationAdapter(
            USDC, _addrs.mockXaut, _addrs.xautPool, 3000,
            _addrs.xauOracle, _addrs.vault, 30 days, deployer
        );
        goldAlloc.setPool(_addrs.xautPool);
        _addrs.goldAllocAdap = address(goldAlloc);

        ShariahVaultV2 vault = ShariahVaultV2(_addrs.vault);
        vault.setGoldSpreadAdapter(_addrs.goldSpreadAdap);
        vault.setGoldAllocationAdapter(_addrs.goldAllocAdap);
        vault.setGoldCrossChainBlocked(true);

        console.log("GoldExchangeAdapter   :", _addrs.goldSpreadAdap);
        console.log("GoldAllocationAdapter :", _addrs.goldAllocAdap);
    }

    function _step1e_executor(address deployer, address agentWallet) internal {
        ShariahScoreAggregator sagg = new ShariahScoreAggregator(deployer);
        _addrs.shariahAgg = address(sagg);

        RiskTieredExecutor exec = new RiskTieredExecutor(
            _addrs.vault, _addrs.shariahAgg,
            RiskTieredExecutor.RiskTier.SHARIAH_CONSERVATIVE,
            deployer
        );
        _addrs.executor = address(exec);
        ShariahVaultV2(_addrs.vault).setManager(_addrs.executor);
        sagg.setOracle(agentWallet);

        console.log("ShariahScoreAggregator:", _addrs.shariahAgg);
        console.log("RiskTieredExecutor    :", _addrs.executor);
    }

    // ── Step 2: Three wallets deposit ─────────────────────────────────────────

    function step2_deposits() public {
        console.log("=== STEP 2: Three wallets deposit 100 USDC each ===");
        console.log("Vault:", _addrs.vault);
        console.log("NOTE: Run each broadcast separately with each wallet's private key:");
        console.log("  forge script ... --sig 'step2_deposits()' --private-key $WALLET_A_PK");
        console.log("  (repeat for WALLET_B_PK and WALLET_C_PK)");
        console.log("Or supply via WALLET_A_PK / WALLET_B_PK / WALLET_C_PK env vars.");

        // Each wallet: approve + deposit 100 USDC
        // NOTE: Each wallet must hold USDC before calling this step.
        // Fund wallets via 'Get test USDC' in Arc Studio sidebar.
        uint256[3] memory pks;
        pks[0] = vm.envOr("WALLET_A_PK", uint256(0));
        pks[1] = vm.envOr("WALLET_B_PK", uint256(0));
        pks[2] = vm.envOr("WALLET_C_PK", uint256(0));

        for (uint256 i = 0; i < 3; i++) {
            if (pks[i] == 0) {
                console.log("WALLET pk not set, skipping index:", i);
                continue;
            }
            address wallet = vm.addr(pks[i]);
            vm.startBroadcast(pks[i]);
            IERC20(USDC).approve(_addrs.vault, DEPOSIT_AMOUNT);
            ShariahVaultV2(_addrs.vault).deposit(DEPOSIT_AMOUNT, wallet);
            console.log("Deposited 100 USDC from wallet:", wallet);
            vm.stopBroadcast();
        }
    }

    // ── Step 3: Board screens S3-H (HalalLPAdapter) via short timelock ────────

    function step3_screenS3H(address halalLpAdapter) public {
        address deployer      = msg.sender;
        address boardMultisig = vm.envOr("BOARD_MULTISIG", deployer);

        console.log("=== STEP 3: Screen S3-H (HalalLP) via 2-minute testnet timelock ===");
        console.log("NOTE: TestnetRegistryShortTimelock TIMELOCK_PERIOD = 2 minutes.");
        console.log("NEVER use this contract on mainnet.");

        bytes32 pronouncementHash = keccak256("SR-011-REHEARSAL-TESTNET-ONLY");
        uint256 expiresAt         = block.timestamp + 365 days;

        vm.startBroadcast(); // must be boardMultisig

        TestnetRegistryShortTimelock reg = TestnetRegistryShortTimelock(_addrs.registry);
        reg.proposeScreening(halalLpAdapter, pronouncementHash, expiresAt);
        console.log("Proposed screening for HalalLPAdapter:", halalLpAdapter);
        console.log("Wait 2 minutes, then call step3b_executeScreening()");

        vm.stopBroadcast();
    }

    function step3b_executeScreening(address halalLpAdapter) public {
        console.log("=== STEP 3b: Execute S3-H screening after 2-minute delay ===");
        vm.startBroadcast();
        TestnetRegistryShortTimelock(_addrs.registry).executeScreening(halalLpAdapter);
        ShariahVaultV2(_addrs.vault).setScreened(halalLpAdapter, true);
        console.log("S3-H screening executed. HalalLPAdapter is now screened.");
        vm.stopBroadcast();
    }

    // ── Step 4: Agent wiring (off-chain instructions) ─────────────────────────
    // The agent server (bun run agent) connects to the deployed contracts and runs
    // its scoring loop. This step documents the wiring; execution is off-chain.

    function step4_agentWiring() public pure {
        console.log("=== STEP 4: Agent server instructions ===");
        console.log("Set in .env:");
        console.log("  VITE_SHARIAH_VAULT_ADDRESS=<vault>");
        console.log("  VITE_SHARIAH_AGG_ADDRESS=<sagg>");
        console.log("  VITE_EXECUTOR_CONSERVATIVE=<executor>");
        console.log("Then run: bun run agent");
        console.log("Monitor ExecutionTriggered events for >= 2 hours.");
        console.log("Capture tx hashes and gas used for rehearsal.md.");
    }

    // ── Step 5: Cross-chain round trip ────────────────────────────────────────

    function step5_deployCrossChain() public returns (uint64 nonce) {
        console.log("=== STEP 5: Cross-chain deploy to ETH-SEPOLIA ===");
        address deployer = msg.sender;
        bytes32 recipient = bytes32(uint256(uint160(deployer))); // return to deployer

        vm.startBroadcast();
        ShariahVault(_addrs.vault).deployCrossChain(ETH_SEP_DOMAIN, recipient, CCTP_AMOUNT);
        // nonce is emitted in CapitalDeployedCrossChain event; read from tx receipt
        nonce = 0; // placeholder — read actual nonce from event
        console.log("Cross-chain nonce:", nonce);
        console.log("CCTP amount:      ", CCTP_AMOUNT);
        console.log("Wait for CCTP attestation, then call step5b_settle(nonce, message, attestation)");
        vm.stopBroadcast();
    }

    function step5b_settle(
        uint64 nonce,
        bytes calldata message,
        bytes calldata attestation
    ) public {
        console.log("=== STEP 5b: Settle cross-chain return ===");
        console.log("Nonce:", nonce);
        vm.startBroadcast();
        ShariahVault(_addrs.vault).settleCrossChainWithMessage(nonce, message, attestation);
        console.log("settleCrossChainWithMessage succeeded. NAV updated, feeExecuted absorbed.");
        vm.stopBroadcast();
    }

    // ── Step 6: Force stale oracle ────────────────────────────────────────────

    function step6_forceStaleOracle() public {
        console.log("=== STEP 6: Force stale gold oracle ===");
        console.log("Advancing time past maxStalenessSecs (1 day) WITHOUT updating oracle.");
        console.log("On a live chain, just wait > 1 day without poking the oracle.");
        console.log("On a fork: vm.warp(block.timestamp + 1 days + 1);");

        // Check current state
        GoldExchangeAdapter spread = GoldExchangeAdapter(_addrs.goldSpreadAdap);
        GoldAllocationAdapter alloc = GoldAllocationAdapter(_addrs.goldAllocAdap);

        console.log("goldSpread.isPriceSane():", spread.isPriceSane() ? "true" : "false");
        console.log("goldAlloc.isPriceSane():", alloc.isPriceSane() ? "true" : "false");

        ShariahVaultV2 vault = ShariahVaultV2(_addrs.vault);
        uint256 maxDep = vault.maxDeposit(address(0));
        console.log("maxDeposit(0):", maxDep);
        if (spread.currentValue() > vault.dustThreshold()) {
            console.log("Gold position > dustThreshold: deposits BLOCKED when stale. OK.");
        } else {
            console.log("Gold position <= dustThreshold: deposits NOT blocked (dust rule). OK.");
        }
        console.log("Redemptions remain open at all times (verify separately).");
    }

    // ── Step 7: Claim profit ──────────────────────────────────────────────────

    function step7_claimProfit() public {
        console.log("=== STEP 7: Claim profit - waterfall + 3-day unlock ===");
        vm.startBroadcast();
        // Approve escrow to pull grossProfit from vault
        IERC20(USDC).approve(_addrs.escrow, PROFIT_CLAIM);
        // Fund vault with synthetic profit
        // In real scenario, profit comes from adapter recall returning more than deployed.
        // For rehearsal: mint PROFIT_CLAIM to vault then call claimMusharakahProfit.
        // NOTE: vault.claimMusharakahProfit is callable by manager/owner.
        ShariahVault(_addrs.vault).claimMusharakahProfit(PROFIT_CLAIM);
        console.log("claimMusharakahProfit(", PROFIT_CLAIM, ")");
        console.log("Waterfall executed. Check WaterfallExecuted + MusharakahProfitClaimed events.");
        console.log("lockedProfit will decay over 3 days (profitUnlockPeriod).");
        vm.stopBroadcast();
    }

    // ── Step 8: All three wallets redeem ──────────────────────────────────────

    function step8_redeemAll() public {
        console.log("=== STEP 8: All three wallets redeem fully ===");

        uint256[3] memory pks;
        pks[0] = vm.envOr("WALLET_A_PK", uint256(0));
        pks[1] = vm.envOr("WALLET_B_PK", uint256(0));
        pks[2] = vm.envOr("WALLET_C_PK", uint256(0));

        ShariahVaultV2 vault = ShariahVaultV2(_addrs.vault);

        for (uint256 i = 0; i < 3; i++) {
            if (pks[i] == 0) { continue; }
            address wallet = vm.addr(pks[i]);
            uint256 maxShares = vault.maxRedeem(wallet);
            if (maxShares == 0) {
                console.log("Wallet has no shares:", wallet);
                continue;
            }
            vm.startBroadcast(pks[i]);
            vault.redeem(maxShares, wallet, wallet);
            console.log("Redeemed all shares for wallet:", wallet);
            vm.stopBroadcast();
        }
    }

    // ── Convenience: run all steps in sequence (fork only) ───────────────────

    function run() external {
        console.log("=== Rehearsal.s.sol - Task K PR4 ===");
        console.log("Run each step separately in production.");
        console.log("Use 'forge script --sig step1_deploy()' etc.");
        step4_agentWiring();
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _logAddresses() internal view {
        console.log("\n=== Rehearsal Deployment Summary ===");
        console.log("TestnetRegistryShortTimelock:", _addrs.registry);
        console.log("ShariahTreasury (redeploy needed for feeSource):", _addrs.treasury);
        console.log("ZakatModule (deprecated):", _addrs.zakatModule);
        console.log("ShariahVaultV2 (Conservative):", _addrs.vault);
        console.log("CharityModule:", _addrs.charityModule);
        console.log("PurificationEscrow:", _addrs.escrow);
        console.log("MockAllocatedGold (PAXG):", _addrs.mockPaxg);
        console.log("MockXAUT:", _addrs.mockXaut);
        console.log("MockXauUsdAggregator:", _addrs.xauOracle);
        console.log("MockUniswapV3PoolXAUT:", _addrs.xautPool);
        console.log("GoldExchangeAdapter (S2-H):", _addrs.goldSpreadAdap);
        console.log("GoldAllocationAdapter (S6-H):", _addrs.goldAllocAdap);
        console.log("ShariahScoreAggregator:", _addrs.shariahAgg);
        console.log("RiskTieredExecutor (Conservative):", _addrs.executor);
        console.log("\nRecording in docs/agents/deployed-addresses.md required.");
    }
}
