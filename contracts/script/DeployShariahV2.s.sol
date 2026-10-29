// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ShariahAdapterRegistry} from "../ShariahAdapterRegistry.sol";
import {ShariahVaultV2} from "../ShariahVaultV2.sol";
import {TreasuryModule} from "../TreasuryModule.sol";
import {ZakatModule} from "../ZakatModule.sol";
import {CharityModule} from "../CharityModule.sol";
import {PurificationEscrow} from "../PurificationEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title  DeployShariahV2
 * @notice Deploys the full V2 Shariah vault stack.
 *
 * Deploys (in order):
 *   1. ShariahAdapterRegistry
 *   2. TreasuryModule (Shariah config)
 *   3. ZakatModule (v1 compatibility — kept for deployment parity)
 *   4. ShariahVaultV2
 *   5. CharityModule
 *   6. PurificationEscrow
 *   7. Wires PurificationEscrow into the vault
 *   8. Records all addresses
 *
 * After deploy the operator must:
 *   a. For each adapter: proposeScreening → wait 30 days → executeScreening
 *   b. setPermittedAsset for each permitted asset
 *   c. setGoldSpreadAdapter / setGoldAllocationAdapter if applicable
 */
contract DeployShariahV2 is Script {

    // ── Constructor args — override via env or edit before deploy ──
    address constant USDC_ARC_TESTNET = 0x3600000000000000000000000000000000000000;
    uint32  constant ARC_TESTNET_DOMAIN = 26;
    uint256 constant ADMIN_FEE_BPS     = 50;    // 0.5% Wakala
    uint256 constant MUSHARAKAH_BPS    = 1000;  // 10% above hurdle
    uint256 constant HURDLE_RATE_BPS   = 400;   // 4% hurdle
    uint256 constant CHARITY_BPS       = 250;   // 2.5% sadaqah (default)
    // Screening expiry: 1 year from deploy
    uint256 constant SCREENING_VALIDITY = 365 days;

    struct Addresses {
        address registry;
        address shariahTreasury;
        address zakatModule;
        address vault;
        address charityModule;
        address purificationEscrow;
    }

    function run() external returns (Addresses memory addrs) {
        address deployer = msg.sender;
        // I5: Read the board multisig from env (BOARD_MULTISIG). Falls back to deployer on testnet.
        // On production: set BOARD_MULTISIG to the organisation's Safe or multisig address.
        address boardMultisig = vm.envOr("BOARD_MULTISIG", deployer);

        vm.startBroadcast();

        addrs = _deploy(deployer, boardMultisig);

        vm.stopBroadcast();
        _log(addrs);
    }

    function _deploy(address deployer, address boardMultisig) internal returns (Addresses memory addrs) {
        // 1. Registry — deployer is owner (can emergency-revoke); boardMultisig receives boardRole.
        //    On testnet: boardMultisig == deployer (acceptable; document the risk).
        //    On production: boardMultisig must be the organisation's Safe.
        ShariahAdapterRegistry reg = new ShariahAdapterRegistry(deployer, boardMultisig);
        addrs.registry = address(reg);
        console.log("ShariahAdapterRegistry:", addrs.registry);

        // 3. ZakatModule (v1 compat — deprecated, kept for deployment completeness)
        //    charityWallet set to deployer; operator should update via board resolution SR-003.
        //    Constructor: (zakatWallet_, asset_, vault_, initialOwner)
        //    vault_ is not known yet — deploy a placeholder and re-deploy after vault, or use deployer.
        //    For testnet deploy, pass deployer as vault_ placeholder (operator must call setVault if available,
        //    or accept ZakatModule is not used in V2 flow).
        ZakatModule zakat = new ZakatModule(deployer, USDC_ARC_TESTNET, deployer, deployer);
        addrs.zakatModule = address(zakat);
        console.log("ZakatModule (deprecated):", addrs.zakatModule);

        // 4. ShariahVaultV2
        //    TreasuryModule.feeSource is immutable — must be set at construction.
        //    We need the vault address before deploying the treasury. Use CREATE2 or
        //    deploy treasury with a temporary feeSource (deployer) and note the limitation.
        //    For simplicity on testnet: deploy treasury with deployer as feeSource first,
        //    then deploy V2 vault. The vault calls shariahTreasury.accrue() which checks
        //    msg.sender == feeSource — so the treasury needs to be redeployed with the vault address.
        //    Testnet approach: deploy vault with deployer as feeSource placeholder, then deploy
        //    a fresh treasury with vault as feeSource and call vault.replaceShariahTreasury.
        //    Since ShariahVault has no such method, we deploy treasury AFTER vault using a two-pass:
        //    pass deployer as temporary feeSource, then operators call accrue manually from deployer.
        //    Board must redeploy treasury with correct feeSource before live use.
        TreasuryModule treasury = new TreasuryModule(
            "Shariah",
            deployer, // temporary feeSource — must redeploy with vault address before live use
            USDC_ARC_TESTNET,
            ADMIN_FEE_BPS,
            MUSHARAKAH_BPS,
            HURDLE_RATE_BPS,
            deployer
        );
        addrs.shariahTreasury = address(treasury);
        console.log("ShariahTreasury (feeSource=deployer - redeploy with vault):", addrs.shariahTreasury);

        ShariahVaultV2 vault = new ShariahVaultV2(
            IERC20(USDC_ARC_TESTNET),
            deployer,
            ARC_TESTNET_DOMAIN,
            addrs.shariahTreasury,
            addrs.zakatModule,
            addrs.registry
        );
        addrs.vault = address(vault);
        console.log("ShariahVaultV2:", addrs.vault);

        // 5. CharityModule — boardRegistry set to registry (I4: board changes propagate from registry)
        CharityModule charity = new CharityModule(
            deployer,        // charityWallet — MUST be updated via SR-003 board resolution
            USDC_ARC_TESTNET,
            addrs.vault,
            deployer,        // owner
            addrs.registry   // boardRegistry (I4) — board membership sourced from registry
        );
        addrs.charityModule = address(charity);
        console.log("CharityModule:", addrs.charityModule);

        // Propose default charity rate (250 bps = 2.5%) — no-op since it is the default.
        // Board must complete SR-002 (rate) and SR-003 (wallet) before any live distribution.

        // 6. PurificationEscrow — boardRegistry set to registry (I4)
        PurificationEscrow escrow = new PurificationEscrow(
            addrs.vault,
            USDC_ARC_TESTNET,
            addrs.charityModule,
            addrs.shariahTreasury,
            deployer,        // owner
            addrs.registry   // boardRegistry (I4) — board membership sourced from registry
        );
        addrs.purificationEscrow = address(escrow);
        console.log("PurificationEscrow:", addrs.purificationEscrow);

        // 7. Wire escrow into vault
        vault.setPurificationEscrow(addrs.purificationEscrow);
        console.log("PurificationEscrow wired into vault.");

        // 8. Let the escrow book the manager's Musharakah share in the treasury (treasury owner = deployer).
        TreasuryModule(addrs.shariahTreasury).setProfitRecorder(addrs.purificationEscrow);

        return addrs;
    }

    function _log(Addresses memory addrs) internal view {
        console.log("\n=== ShariahVaultV2 Deployment Summary ===");
        console.log("ShariahAdapterRegistry : ", addrs.registry);
        console.log("ShariahTreasury        : ", addrs.shariahTreasury);
        console.log("ZakatModule (deprecated): ", addrs.zakatModule);
        console.log("ShariahVaultV2         : ", addrs.vault);
        console.log("CharityModule          : ", addrs.charityModule);
        console.log("PurificationEscrow     : ", addrs.purificationEscrow);
        console.log("\nNext steps:");
        console.log("  1. For each adapter: registry.proposeScreening(adapter, hash, expiresAt)");
        console.log("  2. Wait 30 days, then: registry.executeScreening(adapter)");
        console.log("  3. vault.setPermittedAsset(USDC, true)");
        console.log("  4. Board must resolve SR-002 and SR-003 before any live profit distribution.");
    }
}
