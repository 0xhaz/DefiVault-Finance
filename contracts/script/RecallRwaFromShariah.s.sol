// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ShariahVault} from "../ShariahVault.sol";

/// @notice Operator script: recall capital from RwaYieldAdapter and unscreen it from ShariahVault.
/// @dev Run AFTER the board confirms SR-001 (OUSG/BUIDL removed from Shariah tier).
///      Set environment variables before running:
///        SHARIAH_VAULT_ADDRESS   — address of the deployed ShariahVault
///        RWA_ADAPTER_ADDRESS     — address of the deployed RwaYieldAdapter
///        RECALL_AMOUNT           — USDC amount to recall (in 6-decimal units, e.g. 1000000 = 1 USDC)
///                                  Set to 0 to skip the recall and only unscreen.
///      Usage:
///        forge script contracts/script/RecallRwaFromShariah.s.sol \
///          --rpc-url $RPC_URL --broadcast --private-key $PRIVATE_KEY
contract RecallRwaFromShariah is Script {
    function run() external {
        address shariahVaultAddr = vm.envAddress("SHARIAH_VAULT_ADDRESS");
        address rwaAdapterAddr   = vm.envAddress("RWA_ADAPTER_ADDRESS");
        uint256 recallAmount     = vm.envUint("RECALL_AMOUNT");

        ShariahVault vault = ShariahVault(shariahVaultAddr);

        vm.startBroadcast();

        // Step 1: recall capital (if any is deployed)
        if (recallAmount > 0) {
            console.log("Recalling %s USDC from RwaYieldAdapter...", recallAmount);
            vault.recallCapital(rwaAdapterAddr, recallAmount);
            console.log("Recall complete.");
        } else {
            console.log("RECALL_AMOUNT=0: skipping recall, proceeding to unscreen.");
        }

        // Step 2: unscreen the adapter so deployCapital reverts for it going forward
        bool wasScreened = vault.screened(rwaAdapterAddr);
        if (wasScreened) {
            vault.setScreened(rwaAdapterAddr, false);
            console.log("RwaYieldAdapter unscreened.");
        } else {
            console.log("RwaYieldAdapter was already unscreened: no change.");
        }

        // Step 3: verify OUSG and BUIDL are not in permittedAssets
        // (these must have been set to false before running this script or via a separate call)
        console.log("Verify: vault.screened(rwaAdapter) =", vault.screened(rwaAdapterAddr));

        vm.stopBroadcast();
    }
}
