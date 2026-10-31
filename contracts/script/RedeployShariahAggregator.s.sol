// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ShariahScoreAggregator} from "../ShariahScoreAggregator.sol";
import {RiskTieredExecutor} from "../RiskTieredExecutor.sol";

/// @notice Operator script: deploy a fresh 6-enum ShariahScoreAggregator and re-point both executors.
/// @dev    Required because ShariahScoreAggregator is not upgradeable.
///         Run after Task F to activate GOLD_ALLOCATION (index 5).
///
///         WARNING: The old aggregator's score history is NOT migrated.
///         After running this script, the agent must re-score all strategies.
///
///         Environment variables:
///           DEPLOYER            — address that will own the new aggregator
///           OLD_AGGREGATOR      — address of the old ShariahScoreAggregator (for reference)
///           EXECUTOR_CONSERVATIVE — address of the SHARIAH_CONSERVATIVE RiskTieredExecutor
///           EXECUTOR_DYNAMIC      — address of the SHARIAH_DYNAMIC RiskTieredExecutor
///           AGENT_ORACLE          — address of the agent wallet (set as oracle on new aggregator)
///
///         Usage:
///           forge script contracts/script/RedeployShariahAggregator.s.sol \
///             --rpc-url $RPC_URL --broadcast --private-key $PRIVATE_KEY
contract RedeployShariahAggregator is Script {
    function run() external {
        address deployer           = vm.envAddress("DEPLOYER");
        address oldAggregator      = vm.envAddress("OLD_AGGREGATOR");
        address executorConservative = vm.envAddress("EXECUTOR_CONSERVATIVE");
        address executorDynamic    = vm.envAddress("EXECUTOR_DYNAMIC");
        address agentOracle        = vm.envAddress("AGENT_ORACLE");

        console.log("Deploying new 6-enum ShariahScoreAggregator...");
        console.log("  Old aggregator (DEPRECATED - history lost):", oldAggregator);

        vm.startBroadcast();

        // 1. Deploy fresh aggregator with 6-enum build
        ShariahScoreAggregator newAggregator = new ShariahScoreAggregator(deployer);
        console.log("  New aggregator deployed:", address(newAggregator));

        // 2. Re-apply certified flags:
        //    indices 0,1,2,3 = true  (ETH_SPREAD, GOLD_SPREAD, HALAL_LP, MURABAHA)
        //    index 4 = false         (RESERVED_4 / RWA_SUKUK — blocked per SR-001)
        //    index 5 = false         (GOLD_ALLOCATION — pending board acceptance SR-008)
        newAggregator.setEnabled(ShariahScoreAggregator.ShariahStrategy.ETH_SPREAD, true);
        newAggregator.setEnabled(ShariahScoreAggregator.ShariahStrategy.GOLD_SPREAD, true);
        newAggregator.setEnabled(ShariahScoreAggregator.ShariahStrategy.HALAL_LP, true);
        newAggregator.setEnabled(ShariahScoreAggregator.ShariahStrategy.MURABAHA, true);
        // RESERVED_4 (index 4): stays false — no setEnabled needed
        // GOLD_ALLOCATION (index 5): stays false — pending SR-008 board acceptance
        console.log("  Certified flags applied: [0..3]=true, [4,5]=false");

        // 3. Set agent as oracle
        newAggregator.setOracle(agentOracle);
        console.log("  Oracle set to agent:", agentOracle);

        // 4. Re-point both executors to the new aggregator
        RiskTieredExecutor(executorConservative).setShariahAggregator(address(newAggregator));
        RiskTieredExecutor(executorDynamic).setShariahAggregator(address(newAggregator));
        console.log("  Conservative executor re-pointed:", executorConservative);
        console.log("  Dynamic executor re-pointed:", executorDynamic);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Update docs/agents/deployed-addresses.md ===");
        console.log("DEPRECATED_ShariahScoreAggregator_v1:", oldAggregator);
        console.log("ShariahScoreAggregator_v2:", address(newAggregator));
        console.log("");
        console.log("IMPORTANT: Agent must re-score all strategies after this deploy.");
        console.log("IMPORTANT: Index 5 (GOLD_ALLOCATION) remains uncertified until SR-008 board acceptance.");
    }
}
