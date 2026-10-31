// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {ShariahAdapterRegistry} from "../ShariahAdapterRegistry.sol";
import {ShariahVaultV2} from "../ShariahVaultV2.sol";
import {TreasuryModule} from "../TreasuryModule.sol";
import {ZakatModule} from "../ZakatModule.sol";
import {CharityModule} from "../CharityModule.sol";
import {PurificationEscrow} from "../PurificationEscrow.sol";
import {ShariahScoreAggregator} from "../ShariahScoreAggregator.sol";
import {RiskTieredExecutor} from "../RiskTieredExecutor.sol";
import {GoldExchangeAdapter} from "../adapters/GoldExchangeAdapter.sol";
import {GoldAllocationAdapter} from "../adapters/GoldAllocationAdapter.sol";

interface ILocalDomain {
    function localDomain() external view returns (uint32);
}

/**
 * @title  DeployMainnet
 * @notice Production deploy of the Shariah vault stack on Arc mainnet (chain ID 5042).
 *
 * THIS SCRIPT IS PREPARATION MATERIAL. Arc Studio does not run it against mainnet. You run it,
 * from your own wallet, after an independent audit and your own review (see docs/mainnet-deploy.md).
 *
 * Differences from the testnet Rehearsal script:
 *   - no mocks of any kind; every external address comes from an environment variable and must
 *     have code on chain (checked before broadcasting);
 *   - the registry is ShariahAdapterRegistry with the real 30-day timelock, never the testnet subclass;
 *   - governance addresses must be distinct from the deployer and must be contracts (a Safe) unless
 *     ALLOW_EOA_GOVERNANCE=true is set explicitly;
 *   - fee and rate parameters have no defaults: each must be set in the environment;
 *   - the aggregator strategies and executor strategy configs are left DISABLED; enabling them is a
 *     board decision made after screening;
 *   - ownership of every contract is handed to OWNER_MULTISIG in a separate, final phase.
 *
 * Phases (run in order, each with --sig; record the printed addresses in the environment after each):
 *   check()          read-only validation of environment and chain
 *   deployCore()     registry, treasury, vault, charity, escrow, aggregator, executor + wiring
 *   deployGold()     optional gold adapters (only for addresses you set; see docs/mainnet-config.md)
 *   handoff()        transfer ownership of everything to OWNER_MULTISIG (multisig must then accept)
 *   verify()         strict read-only post-deploy assertions (multisig must own everything)
 *   verifyPendingAcceptance()  same, but accepts ownership still pending acceptance
 *
 * Example (never pass a raw private key on the command line; use an encrypted keystore):
 *   forge script contracts/script/DeployMainnet.s.sol:DeployMainnet --sig "check()" \
 *     --rpc-url "$ARC_MAINNET_RPC" --account <keystore-name> --sender "$DEPLOYER_ADDRESS"
 */
contract DeployMainnet is Script {
    // ── Arc mainnet constants (source: docs.arc.io contract-addresses, developers.circle.com CCTP, 2026-10-31).
    //    Verify every address on https://explorer.arc.io before broadcasting. check() also confirms code exists.
    uint256 internal constant ARC_MAINNET_CHAIN_ID = 5042;
    address internal constant USDC = 0x3600000000000000000000000000000000000000;
    uint32 internal constant ARC_CCTP_DOMAIN = 26;
    address internal constant TOKEN_MESSENGER_V2 = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address internal constant MESSAGE_TRANSMITTER_V2 = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    uint256 internal constant MAX_RUNTIME_BYTES = 24_576; // EIP-170; confirm Arc mainnet's limit in your dry run.

    struct Cfg {
        address deployer;
        address owner; // OWNER_MULTISIG: final owner of every contract
        address board; // BOARD_MULTISIG: registry board member (screening, rates, wallets)
        address charityWallet;
        address oracleOperator; // writes strategy scores to the aggregator
        uint256 adminFeeBps;
        uint256 musharakahBps;
        uint256 hurdleBps;
        uint256 executorMaxGasPriceGwei;
    }

    struct Deployed {
        address registry;
        address zakat;
        address treasury;
        address vault;
        address charity;
        address escrow;
        address aggregator;
        address executor;
    }

    // ───────────────────────────── check ─────────────────────────────

    function check() external view {
        Cfg memory c = _load();
        _validate(c);
        console.log("check() OK. Deployer :", c.deployer);
        console.log("Owner multisig        :", c.owner);
        console.log("Board multisig        :", c.board);
        console.log("Charity wallet        :", c.charityWallet);
        console.log("Oracle operator       :", c.oracleOperator);
        console.log("Admin fee bps         :", c.adminFeeBps);
        console.log("Musharakah share bps  :", c.musharakahBps);
        console.log("Hurdle bps            :", c.hurdleBps);
        console.log("Executor max gas gwei :", c.executorMaxGasPriceGwei);
    }

    // ───────────────────────────── deployCore ─────────────────────────────

    function deployCore() external returns (Deployed memory d) {
        Cfg memory c = _load();
        _validate(c);

        vm.startBroadcast();

        ShariahAdapterRegistry reg = new ShariahAdapterRegistry(c.deployer, c.board);
        d.registry = address(reg);

        // Deprecated v1-compat module the vault constructor still takes; wallet = charity wallet.
        d.zakat = address(new ZakatModule(c.charityWallet, USDC, c.deployer, c.deployer));

        TreasuryModule treasury = new TreasuryModule(
            "Shariah", c.deployer, USDC, c.adminFeeBps, c.musharakahBps, c.hurdleBps, c.deployer
        );
        d.treasury = address(treasury);

        ShariahVaultV2 vault =
            new ShariahVaultV2(IERC20(USDC), c.deployer, ARC_CCTP_DOMAIN, d.treasury, d.zakat, d.registry);
        d.vault = address(vault);
        treasury.setFeeSource(d.vault);

        vault.setTokenMessenger(TOKEN_MESSENGER_V2);
        vault.setMessageTransmitter(MESSAGE_TRANSMITTER_V2);
        vault.setPermittedAsset(USDC, true);

        CharityModule charity = new CharityModule(c.charityWallet, USDC, d.vault, c.deployer, d.registry);
        d.charity = address(charity);
        PurificationEscrow escrow = new PurificationEscrow(d.vault, USDC, d.charity, d.treasury, c.deployer, d.registry);
        d.escrow = address(escrow);
        vault.setPurificationEscrow(d.escrow);
        treasury.setProfitRecorder(d.escrow);
        charity.setEscrow(d.escrow);

        ShariahScoreAggregator agg = new ShariahScoreAggregator(c.deployer);
        d.aggregator = address(agg);
        RiskTieredExecutor exec =
            new RiskTieredExecutor(d.vault, d.aggregator, RiskTieredExecutor.RiskTier.SHARIAH_CONSERVATIVE, c.deployer);
        d.executor = address(exec);
        vault.setManager(d.executor);
        // Launch paused: no deposits or deployments until the owner multisig has run every check and unpauses.
        vault.setPaused(true);
        exec.setShariahAggregator(d.aggregator);
        exec.setMaxGasPrice(c.executorMaxGasPriceGwei * 1 gwei);
        agg.setOracle(c.oracleOperator);
        // Aggregator strategies stay disabled and executor strategy configs stay unset until the board
        // has screened an adapter and the owner multisig enables it (docs/mainnet-deploy.md).

        vm.stopBroadcast();
        _logCore(d);
    }

    // ───────────────────────────── deployGold (optional) ─────────────────────────────

    /// @dev Env: VAULT, EXECUTOR, GOLD_ORACLE (XAU/USD feed), plus any of
    ///      the PAXG set (GOLD_PAXG, GOLD_PAXG_ROUTER, GOLD_PAXG_POOL_FEE) and the XAUT set
    ///      (GOLD_XAUT, GOLD_XAUT_ROUTER, GOLD_XAUT_POOL_FEE, GOLD_MAX_STALENESS_SECONDS). A set is deployed only if its token is non-zero.
    function deployGold() external returns (address spreadAdapter, address allocationAdapter) {
        Cfg memory c = _load();
        require(msg.sender == c.deployer, "run with --sender DEPLOYER_ADDRESS");
        address vaultAddr = vm.envAddress("VAULT");
        address execAddr = vm.envAddress("EXECUTOR");
        address oracle = vm.envAddress("GOLD_ORACLE");
        _requireCode(vaultAddr, "VAULT");
        _requireCode(execAddr, "EXECUTOR");
        _requireCode(oracle, "GOLD_ORACLE");
        require(
            vm.envOr("GOLD_PAXG", address(0)) != address(0) || vm.envOr("GOLD_XAUT", address(0)) != address(0),
            "set GOLD_PAXG and/or GOLD_XAUT"
        );

        vm.startBroadcast();
        if (vm.envOr("GOLD_PAXG", address(0)) != address(0)) {
            spreadAdapter = _deploySpread(c.deployer, vaultAddr, execAddr, oracle);
        }
        if (vm.envOr("GOLD_XAUT", address(0)) != address(0)) {
            allocationAdapter = _deployAllocation(c.deployer, vaultAddr, execAddr, oracle);
        }
        vm.stopBroadcast();

        console.log("GoldExchangeAdapter (PAXG)  :", spreadAdapter);
        console.log("GoldAllocationAdapter (XAUT):", allocationAdapter);
        console.log("Next: board proposeScreening for each adapter, wait 30 days, executeScreening.");
        console.log("Then the owner multisig enables the executor config and the aggregator strategy.");
    }

    function _deploySpread(address deployer, address vaultAddr, address execAddr, address oracle)
        internal
        returns (address adapter)
    {
        address paxg = vm.envAddress("GOLD_PAXG");
        address router = vm.envAddress("GOLD_PAXG_ROUTER");
        uint24 fee = uint24(vm.envUint("GOLD_PAXG_POOL_FEE"));
        _requireCode(paxg, "GOLD_PAXG");
        _requireCode(router, "GOLD_PAXG_ROUTER");
        adapter = address(new GoldExchangeAdapter(USDC, paxg, router, fee, vaultAddr, deployer, oracle));
        ShariahVaultV2(vaultAddr).setPermittedAsset(paxg, true);
        ShariahVaultV2(vaultAddr).setGoldSpreadAdapter(adapter);
        // Disabled until the adapter is screened and the owner multisig enables it.
        RiskTieredExecutor(execAddr).setShariahStrategyConfig(1, adapter, bytes32(0), false, 1e6, 0);
    }

    function _deployAllocation(address deployer, address vaultAddr, address execAddr, address oracle)
        internal
        returns (address adapter)
    {
        address xaut = vm.envAddress("GOLD_XAUT");
        address router = vm.envAddress("GOLD_XAUT_ROUTER");
        uint24 fee = uint24(vm.envUint("GOLD_XAUT_POOL_FEE"));
        uint256 maxStale = vm.envUint("GOLD_MAX_STALENESS_SECONDS");
        require(maxStale >= 300 && maxStale <= 7 days, "GOLD_MAX_STALENESS_SECONDS out of range");
        _requireCode(xaut, "GOLD_XAUT");
        _requireCode(router, "GOLD_XAUT_ROUTER");
        adapter = address(new GoldAllocationAdapter(USDC, xaut, router, fee, oracle, vaultAddr, maxStale, deployer));
        ShariahVaultV2(vaultAddr).setPermittedAsset(xaut, true);
        ShariahVaultV2(vaultAddr).setGoldAllocationAdapter(adapter);
        RiskTieredExecutor(execAddr).setShariahStrategyConfig(5, adapter, bytes32(0), false, 1e6, 0);
    }

    // ───────────────────────────── handoff ─────────────────────────────

    /// @dev Env: OWNER_MULTISIG plus REGISTRY, ZAKAT, TREASURY, VAULT, CHARITY, ESCROW, AGGREGATOR, EXECUTOR.
    ///      Gold adapters are read from the vault's linked slots, so they cannot be forgotten.
    ///      Run only when everything is wired.
    function handoff() external {
        Cfg memory c = _load();
        require(msg.sender == c.deployer, "run with --sender DEPLOYER_ADDRESS");
        address[] memory targets = _ownedContracts();

        vm.startBroadcast();
        // The registry uses plain Ownable: this transfer is immediate and irreversible.
        Ownable(vm.envAddress("REGISTRY")).transferOwnership(c.owner);
        for (uint256 i = 0; i < targets.length; i++) {
            Ownable2Step(targets[i]).transferOwnership(c.owner);
        }
        vm.stopBroadcast();

        console.log("Ownership transferred. OWNER_MULTISIG must now call acceptOwnership() on each Ownable2Step contract:");
        for (uint256 i = 0; i < targets.length; i++) {
            console.log("  acceptOwnership on", targets[i]);
        }
    }

    // ───────────────────────────── verify ─────────────────────────────

    /// @notice Strict final check: the multisig must already OWN every contract (acceptOwnership done).
    function verify() external view {
        _verify(true);
    }

    /// @notice Check after handoff() but before the multisig has accepted: ownership may still be pending.
    function verifyPendingAcceptance() external view {
        _verify(false);
    }

    function _verify(bool requireAccepted) internal view {
        Cfg memory c = _load();
        require(block.chainid == ARC_MAINNET_CHAIN_ID, "not Arc mainnet");
        Deployed memory d = _envDeployed();

        ShariahVaultV2 vault = ShariahVaultV2(d.vault);
        require(address(vault.asset()) == USDC, "vault asset");
        require(address(vault.registry()) == d.registry, "vault registry");
        require(address(vault.purificationEscrow()) == d.escrow, "vault escrow");
        require(vault.manager() == d.executor, "vault manager");
        require(vault.tokenMessenger() == TOKEN_MESSENGER_V2, "tokenMessenger");
        require(vault.messageTransmitter() == MESSAGE_TRANSMITTER_V2, "messageTransmitter");
        require(ILocalDomain(MESSAGE_TRANSMITTER_V2).localDomain() == ARC_CCTP_DOMAIN, "transmitter domain");
        require(TreasuryModule(d.treasury).feeSource() == d.vault, "treasury feeSource");
        require(CharityModule(d.charity).escrow() == d.escrow, "charity escrow");
        require(ShariahAdapterRegistry(d.registry).TIMELOCK_PERIOD() == 30 days, "registry timelock");
        require(ShariahAdapterRegistry(d.registry).isBoard(c.board), "board member");
        require(d.vault.code.length <= MAX_RUNTIME_BYTES, "vault runtime too large");

        address[] memory targets = _ownedContracts();
        for (uint256 i = 0; i < targets.length; i++) {
            Ownable2Step t = Ownable2Step(targets[i]);
            if (t.owner() == c.owner) continue;
            require(!requireAccepted, "OWNER_MULTISIG has not accepted ownership");
            require(t.pendingOwner() == c.owner, "ownership not handed off");
        }
        require(Ownable(d.registry).owner() == c.owner, "registry owner");
        console.log(requireAccepted ? "verify() OK (ownership accepted)." : "verifyPendingAcceptance() OK.");
        console.log("Vault runtime bytes:", d.vault.code.length);
    }

    // ───────────────────────────── internals ─────────────────────────────

    function _load() internal view returns (Cfg memory c) {
        c.deployer = vm.envAddress("DEPLOYER_ADDRESS");
        c.owner = vm.envAddress("OWNER_MULTISIG");
        c.board = vm.envAddress("BOARD_MULTISIG");
        c.charityWallet = vm.envAddress("CHARITY_WALLET");
        c.oracleOperator = vm.envAddress("ORACLE_OPERATOR");
        c.adminFeeBps = vm.envUint("ADMIN_FEE_BPS");
        c.musharakahBps = vm.envUint("MUSHARAKAH_BPS");
        c.hurdleBps = vm.envUint("HURDLE_BPS");
        c.executorMaxGasPriceGwei = vm.envUint("EXECUTOR_MAX_GAS_PRICE_GWEI");
    }

    function _validate(Cfg memory c) internal view {
        require(block.chainid == ARC_MAINNET_CHAIN_ID, "not Arc mainnet (chain id 5042)");
        require(msg.sender == c.deployer, "run with --sender DEPLOYER_ADDRESS");
        _requireCode(USDC, "USDC");
        _requireCode(TOKEN_MESSENGER_V2, "TokenMessengerV2");
        _requireCode(MESSAGE_TRANSMITTER_V2, "MessageTransmitterV2");
        require(ILocalDomain(MESSAGE_TRANSMITTER_V2).localDomain() == ARC_CCTP_DOMAIN, "transmitter domain != 26");

        _requireReal(c.deployer, "DEPLOYER_ADDRESS");
        _requireReal(c.owner, "OWNER_MULTISIG");
        _requireReal(c.board, "BOARD_MULTISIG");
        _requireReal(c.charityWallet, "CHARITY_WALLET");
        _requireReal(c.oracleOperator, "ORACLE_OPERATOR");
        require(c.owner != c.deployer && c.board != c.deployer, "governance must differ from the deployer");
        require(c.charityWallet != c.deployer, "CHARITY_WALLET must not be the deployer");
        if (!vm.envOr("ALLOW_EOA_GOVERNANCE", false)) {
            require(c.owner.code.length > 0, "OWNER_MULTISIG must be a contract (Safe)");
            require(c.board.code.length > 0, "BOARD_MULTISIG must be a contract (Safe)");
        }
        require(c.adminFeeBps <= 200, "ADMIN_FEE_BPS > 2%");
        require(c.musharakahBps <= 3000, "MUSHARAKAH_BPS > 30%");
        require(c.hurdleBps <= 2000, "HURDLE_BPS > 20%");
        // Arc enforces a 20 gwei minimum maxFeePerGas; a lower executor limit would never execute.
        require(c.executorMaxGasPriceGwei >= 20 && c.executorMaxGasPriceGwei <= 1000, "EXECUTOR_MAX_GAS_PRICE_GWEI");
    }

    function _requireReal(address a, string memory name) internal pure {
        require(a != address(0), string.concat(name, " is unset or zero (replace the placeholder)"));
        require(a != address(0xdead) && a != address(1), string.concat(name, " is a burn/placeholder address"));
    }

    function _requireCode(address a, string memory name) internal view {
        require(a.code.length > 0, string.concat(name, " has no code on this chain"));
    }

    function _envDeployed() internal view returns (Deployed memory d) {
        d.registry = vm.envAddress("REGISTRY");
        d.zakat = vm.envAddress("ZAKAT");
        d.treasury = vm.envAddress("TREASURY");
        d.vault = vm.envAddress("VAULT");
        d.charity = vm.envAddress("CHARITY");
        d.escrow = vm.envAddress("ESCROW");
        d.aggregator = vm.envAddress("AGGREGATOR");
        d.executor = vm.envAddress("EXECUTOR");
    }

    /// @dev Every Ownable2Step contract the deployer owns after deployCore/deployGold (the registry is separate).
    ///      Gold adapters come from the vault's linked slots so a missing env variable cannot skip them.
    function _ownedContracts() internal view returns (address[] memory out) {
        Deployed memory d = _envDeployed();
        address spread = ShariahVaultV2(d.vault).goldSpreadAdapter();
        address alloc = ShariahVaultV2(d.vault).goldAllocationAdapter();
        uint256 n = 7 + (spread != address(0) ? 1 : 0) + (alloc != address(0) ? 1 : 0);
        out = new address[](n);
        uint256 i;
        out[i++] = d.zakat;
        out[i++] = d.treasury;
        out[i++] = d.vault;
        out[i++] = d.charity;
        out[i++] = d.escrow;
        out[i++] = d.aggregator;
        out[i++] = d.executor;
        if (spread != address(0)) out[i++] = spread;
        if (alloc != address(0)) out[i++] = alloc;
    }

    function _logCore(Deployed memory d) internal view {
        console.log("=== Mainnet core deployed. Put these in your environment ===");
        console.log("REGISTRY   =", d.registry);
        console.log("ZAKAT      =", d.zakat);
        console.log("TREASURY   =", d.treasury);
        console.log("VAULT      =", d.vault);
        console.log("CHARITY    =", d.charity);
        console.log("ESCROW     =", d.escrow);
        console.log("AGGREGATOR =", d.aggregator);
        console.log("EXECUTOR   =", d.executor);
        console.log("Vault runtime bytes:", d.vault.code.length);
        console.log("Next: record addresses, deployGold() if gold addresses are confirmed, board screening, handoff(), verify().");
    }
}
