// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ShariahVault} from "../ShariahVault.sol";
import {RiskTieredExecutor} from "../RiskTieredExecutor.sol";
import {GoldAllocationAdapter} from "../adapters/GoldAllocationAdapter.sol";
import {MockXAUT} from "../test-helpers/MockXAUT.sol";
import {MockXauUsdAggregator} from "../test-helpers/MockXauUsdAggregator.sol";
import {MockUniswapV3PoolXAUT} from "../test-helpers/MockUniswapV3PoolXAUT.sol";

/// @notice Operator script: deploy testnet mocks + GoldAllocationAdapter and wire into both Shariah vaults.
/// @dev    Arc Testnet only — XAUT does not exist on Arc. Mocks are used for testnet simulation.
///
///         Environment variables (all required):
///           DEPLOYER              — deployer and initial adapter owner
///           VAULT_CONSERVATIVE    — address of SHARIAH_CONSERVATIVE ShariahVault
///           VAULT_DYNAMIC         — address of SHARIAH_DYNAMIC ShariahVault
///           EXECUTOR_CONSERVATIVE — address of SHARIAH_CONSERVATIVE RiskTieredExecutor
///           EXECUTOR_DYNAMIC      — address of SHARIAH_DYNAMIC RiskTieredExecutor
///           USDC_ADDRESS          — USDC token address on this chain
///           GOLD_SPREAD_ADAPTER   — address of GoldExchangeAdapter (S2-H, for combined cap)
///
///         Usage:
///           forge script contracts/script/DeployGoldAllocation.s.sol \
///             --rpc-url $RPC_URL --broadcast --private-key $PRIVATE_KEY
contract DeployGoldAllocation is Script {
    uint256 constant INITIAL_USDC_PER_XAUT = 3_300_000_000; // $3300 at 6 dec
    uint256 constant SEED_XAUT_MINT         =       13_030 * 1e6;
    int256  constant INITIAL_ORACLE_PRICE   = 3_300 * 1e8;  // $3300 in 8-dec format
    uint256 constant MAX_STALENESS          = 3600;          // 1 hour

    // Packed addresses to avoid stack-too-deep
    struct Env {
        address deployer;
        address vaultConservative;
        address vaultDynamic;
        address executorConservative;
        address executorDynamic;
        address usdcAddress;
        address goldSpreadAdapter;
    }

    struct Deployed {
        address mockXaut;
        address mockOracle;
        address mockPool;
        address adapter;
    }

    function run() external {
        Env memory e = _loadEnv();
        vm.startBroadcast();
        Deployed memory d = _deployMocks(e);
        _wireVaults(e, d);
        _wireExecutors(e, d);
        vm.stopBroadcast();
        _printSummary(d);
    }

    function _loadEnv() internal view returns (Env memory e) {
        e.deployer             = vm.envAddress("DEPLOYER");
        e.vaultConservative    = vm.envAddress("VAULT_CONSERVATIVE");
        e.vaultDynamic         = vm.envAddress("VAULT_DYNAMIC");
        e.executorConservative = vm.envAddress("EXECUTOR_CONSERVATIVE");
        e.executorDynamic      = vm.envAddress("EXECUTOR_DYNAMIC");
        e.usdcAddress          = vm.envAddress("USDC_ADDRESS");
        e.goldSpreadAdapter    = vm.envAddress("GOLD_SPREAD_ADAPTER");
    }

    function _deployMocks(Env memory e) internal returns (Deployed memory d) {
        MockXAUT xaut = new MockXAUT();
        d.mockXaut = address(xaut);
        console.log("MockXAUT deployed:", d.mockXaut);

        MockXauUsdAggregator oracle = new MockXauUsdAggregator();
        oracle.setPrice(INITIAL_ORACLE_PRICE);
        d.mockOracle = address(oracle);
        console.log("MockXauUsdAggregator deployed:", d.mockOracle);

        MockUniswapV3PoolXAUT pool = new MockUniswapV3PoolXAUT(
            e.usdcAddress, d.mockXaut, INITIAL_USDC_PER_XAUT
        );
        d.mockPool = address(pool);
        console.log("MockUniswapV3PoolXAUT deployed:", d.mockPool);

        // Mint XAUT to deployer for pool seeding
        xaut.mint(e.deployer, SEED_XAUT_MINT);
        console.log("MockXAUT minted to deployer. Fund pool manually with USDC.");

        GoldAllocationAdapter adapter = new GoldAllocationAdapter(
            e.usdcAddress,
            d.mockXaut,
            d.mockPool,     // swapRouter_ = mock pool
            3000,           // poolFee_ = 0.3% tier (ignored by mock)
            d.mockOracle,
            e.vaultConservative,
            MAX_STALENESS,
            e.deployer
        );
        d.adapter = address(adapter);
        console.log("GoldAllocationAdapter deployed:", d.adapter);
    }

    function _wireVaults(Env memory e, Deployed memory d) internal {
        ShariahVault(e.vaultConservative).setPermittedAsset(d.mockXaut, true);
        ShariahVault(e.vaultConservative).setScreened(d.adapter, true);
        ShariahVault(e.vaultConservative).setGoldAllocationAdapter(d.adapter);
        ShariahVault(e.vaultConservative).setGoldSpreadAdapter(e.goldSpreadAdapter);

        ShariahVault(e.vaultDynamic).setPermittedAsset(d.mockXaut, true);
        ShariahVault(e.vaultDynamic).setScreened(d.adapter, true);
        ShariahVault(e.vaultDynamic).setGoldAllocationAdapter(d.adapter);
        ShariahVault(e.vaultDynamic).setGoldSpreadAdapter(e.goldSpreadAdapter);

        console.log("Vaults wired: XAUT permitted, adapter screened, gold cap set");
    }

    function _wireExecutors(Env memory e, Deployed memory d) internal {
        RiskTieredExecutor(e.executorConservative).setShariahStrategyConfig(
            5, d.adapter, bytes32(0), true, 1e6, 100_000 * 1e6
        );
        RiskTieredExecutor(e.executorDynamic).setShariahStrategyConfig(
            5, d.adapter, bytes32(0), true, 1e6, 100_000 * 1e6
        );
        RiskTieredExecutor(e.executorConservative).setStrategyMask(38); // 0b100110
        RiskTieredExecutor(e.executorDynamic).setStrategyMask(47);      // 0b101111
        console.log("Executors: strategy 5 configured, masks 38 and 47");
    }

    function _printSummary(Deployed memory d) internal view {
        console.log("");
        console.log("=== Record in docs/agents/deployed-addresses.md ===");
        console.log("MockXAUT:", d.mockXaut);
        console.log("MockXauUsdAggregator:", d.mockOracle);
        console.log("MockUniswapV3PoolXAUT:", d.mockPool);
        console.log("GoldAllocationAdapter:", d.adapter);
        console.log("");
        console.log("IMPORTANT: shariahCertified[5] = false (GOLD_ALLOCATION).");
        console.log("Set to true ONLY after board accepts SR-008.");
    }
}
