// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ShariahVaultV2} from "../ShariahVaultV2.sol";
import {ShariahAdapterRegistry} from "../ShariahAdapterRegistry.sol";
import {TreasuryModule} from "../TreasuryModule.sol";
import {CharityModule} from "../CharityModule.sol";
import {PurificationEscrow} from "../PurificationEscrow.sol";
import {ArcNativeCoinShim, ArcBlocklistShim} from "../test-helpers/ArcNativeCoinShim.sol";

interface IUSDCArc {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
    function decimals() external view returns (uint8);
    function mint(address to, uint256 amount) external;
}

interface IMessageTransmitterV2Real {
    function localDomain() external view returns (uint32);
    function owner() external view returns (address);
    function attesterManager() external view returns (address);
    function signatureThreshold() external view returns (uint256);
    function isEnabledAttester(address) external view returns (bool);
    function usedNonces(bytes32) external view returns (uint256);
    function enableAttester(address) external;
    function setSignatureThreshold(uint256) external;
    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool);
}

interface ITokenMessengerV2Real {
    function owner() external view returns (address);
    function localMinter() external view returns (address);
    function localMessageTransmitter() external view returns (address);
    function feeRecipient() external view returns (address);
    function remoteTokenMessengers(uint32) external view returns (bytes32);
}

interface ITokenMinterV2Real {
    function tokenController() external view returns (address);
    function getLocalToken(uint32 remoteDomain, bytes32 remoteToken) external view returns (address);
    function burnLimitsPerMessage(address) external view returns (uint256);
    function linkTokenPair(address localToken, uint32 remoteDomain, bytes32 remoteToken) external;
    function setMaxBurnAmountPerMessage(address localToken, uint256 amount) external;
}

/// @dev Fixture + native CCTP V2 message builder for the real-Arc-testnet fork tests. No test functions.
abstract contract ForkCctpRealArcBase is Test {
    address internal constant USDC = 0x3600000000000000000000000000000000000000;
    address internal constant TM = 0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA;
    address internal constant MT = 0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275;
    address internal constant NATIVE_AUTHORITY = 0x1800000000000000000000000000000000000000;
    address internal constant NATIVE_BLOCKLIST = 0x1800000000000000000000000000000000000001;
    bytes32 internal constant SEPOLIA_USDC = bytes32(uint256(uint160(0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238)));
    uint256 internal constant NATIVE_SCALE = 1e12; // Arc native coin 18 dec vs ERC-20 view 6 dec
    uint32 internal constant ARC_DOMAIN = 26;
    uint32 internal constant ETH_SEPOLIA = 0;
    uint32 internal constant UNSET_AT_VAULT = 7; // registered at the real TokenMessengerV2, not on the vault
    uint32 internal constant UNREGISTERED_AT_TM = 99; // not registered on the real TokenMessengerV2
    uint256 internal constant DEPOSIT = 100_000e6;
    uint256 internal constant SENT = 10_000e6;

    address internal owner = makeAddr("owner");
    address internal manager = makeAddr("manager");
    address internal alice = makeAddr("alice");
    address internal charityWallet = makeAddr("charityWallet");
    address internal remoteRecipient = makeAddr("remoteRecipient");
    address internal remoteStrategy = makeAddr("remoteStrategy");
    address internal attester;
    uint256 internal attesterPk;

    ShariahAdapterRegistry internal registry;
    TreasuryModule internal treasury;
    ShariahVaultV2 internal vault;
    CharityModule internal charity;
    PurificationEscrow internal escrow;
    address internal minter;
    bytes32 internal remoteMessenger; // real TokenMessengerV2.remoteTokenMessengers(ETH_SEPOLIA)
    uint256 internal realSupply;

    function setUp() public virtual {
        if (!vm.envExists("ARC_TESTNET_RPC")) vm.skip(true);
        try vm.createSelectFork(vm.envString("ARC_TESTNET_RPC")) returns (uint256) {} catch { vm.skip(true); }
        if (block.chainid != 5042002) vm.skip(true);

        (attester, attesterPk) = makeAddrAndKey("attester");
        _etchNativePrecompiles();
        minter = ITokenMessengerV2Real(TM).localMinter();
        remoteMessenger = ITokenMessengerV2Real(TM).remoteTokenMessengers(ETH_SEPOLIA);
        _deployStack();
        _registerAttesterAndLinks();
        _approveRecipients();
        _mintUsdc(alice, DEPOSIT);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, alice);
        vm.stopPrank();
    }

    /// @dev Foundry does not implement Arc's native-coin precompiles; see ArcNativeCoinShim.
    function _etchNativePrecompiles() internal {
        vm.etch(NATIVE_AUTHORITY, address(new ArcNativeCoinShim()).code);
        vm.allowCheatcodes(NATIVE_AUTHORITY); // the shim moves native balances with vm.deal
        vm.etch(NATIVE_BLOCKLIST, address(new ArcBlocklistShim()).code);
        realSupply = 309_122_258_036_120_272; // fallback = value observed on testnet
        try vm.rpc("eth_call", string.concat('[{"to":"', vm.toString(USDC), '","data":"0x18160ddd"},"latest"]'))
        returns (bytes memory r) {
            if (r.length == 32) realSupply = abi.decode(r, (uint256));
        } catch {}
        ArcNativeCoinShim(NATIVE_AUTHORITY).setSupply(realSupply * NATIVE_SCALE);
    }

    function _deployStack() internal {
        registry = new ShariahAdapterRegistry(owner, owner);
        // treasury(n) -> vault(n+1) -> charity(n+2) -> escrow(n+3); treasury is owned by the vault.
        uint256 n = vm.getNonce(address(this));
        address escrowAddr = vm.computeCreateAddress(address(this), n + 3);
        address vaultAddr = vm.computeCreateAddress(address(this), n + 1);
        treasury = new TreasuryModule("Shariah", escrowAddr, USDC, 50, 1000, 400, vaultAddr);
        vault = new ShariahVaultV2(IERC20(USDC), owner, ARC_DOMAIN, address(treasury), address(0), address(registry));
        charity = new CharityModule(charityWallet, USDC, escrowAddr, owner, address(registry));
        escrow = new PurificationEscrow(address(vault), USDC, address(charity), address(treasury), owner, address(registry));
        assertEq(address(vault), vaultAddr);
        assertEq(address(escrow), escrowAddr);

        vm.startPrank(address(vault)); // treasury is owned by the vault
        treasury.setFeeSource(address(vault));
        treasury.setProfitRecorder(address(escrow));
        vm.stopPrank();

        vm.startPrank(owner);
        vault.setPurificationEscrow(address(escrow));
        vault.setManager(manager);
        vault.setTokenMessenger(TM);
        vault.setMessageTransmitter(MT);
        vault.setMaxPendingCrossChainBps(2000);
        vault.setPermittedAsset(USDC, true);
        vault.setRemoteTokenMessenger(ETH_SEPOLIA, remoteMessenger);
        vm.stopPrank();
    }

    /// @dev Real on-chain owners are impersonated (vm.prank) to register a test attester and pair/limit config.
    function _registerAttesterAndLinks() internal {
        address mgr = IMessageTransmitterV2Real(MT).attesterManager();
        vm.startPrank(mgr);
        IMessageTransmitterV2Real(MT).enableAttester(attester);
        IMessageTransmitterV2Real(MT).setSignatureThreshold(1);
        vm.stopPrank();

        ITokenMinterV2Real m = ITokenMinterV2Real(minter);
        address ctrl = m.tokenController();
        if (m.getLocalToken(ETH_SEPOLIA, SEPOLIA_USDC) != USDC) {
            vm.prank(ctrl);
            m.linkTokenPair(USDC, ETH_SEPOLIA, SEPOLIA_USDC);
        }
        if (m.burnLimitsPerMessage(USDC) == 0) {
            vm.prank(ctrl);
            m.setMaxBurnAmountPerMessage(USDC, 10_000_000e6);
        }
    }

    function _approveRecipients() internal {
        bytes32 r = _b(remoteRecipient);
        vm.startPrank(owner); // owner is the board member of the fixture registry
        vault.proposeRemoteRecipient(ETH_SEPOLIA, r, true);
        vault.proposeRemoteRecipient(UNSET_AT_VAULT, r, true);
        vault.proposeRemoteRecipient(UNREGISTERED_AT_TM, r, true);
        vm.stopPrank();
        skip(30 days);
        vm.startPrank(owner);
        vault.confirmRemoteRecipient(ETH_SEPOLIA, r);
        vault.confirmRemoteRecipient(UNSET_AT_VAULT, r);
        vault.confirmRemoteRecipient(UNREGISTERED_AT_TM, r);
        vm.stopPrank();
    }

    // ───────────── helpers ─────────────

    function _b(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _usdc(address a) internal view returns (uint256) {
        return IUSDCArc(USDC).balanceOf(a);
    }

    /// @dev Fund via the real TokenMinterV2 (a registered USDC minter with allowance), as a real minter would.
    function _mintUsdc(address to, uint256 amt) internal {
        vm.prank(minter);
        IUSDCArc(USDC).mint(to, amt);
    }

    function _deployPos(uint32 dom, uint256 amt) internal returns (uint64) {
        vm.prank(manager);
        vault.deployCrossChain(dom, _b(remoteRecipient), amt);
        return vault.crossChainPositionCounter();
    }

    struct M {
        uint32 src;
        uint32 dst;
        bytes32 nonce;
        bytes32 sender;
        bytes32 recipient;
        bytes32 destCaller;
        bytes32 burnToken;
        bytes32 mintRecipient;
        uint256 amount;
        uint256 maxFee;
        uint256 fee;
    }

    /// @dev Valid message: Sepolia -> Arc, sender = real registered remote TokenMessenger, caller = vault.
    function _m(bytes32 nonce, uint256 amount, uint256 fee) internal view returns (M memory) {
        return M(ETH_SEPOLIA, ARC_DOMAIN, nonce, remoteMessenger, _b(TM), _b(address(vault)), SEPOLIA_USDC,
            _b(address(vault)), amount, fee, fee);
    }

    function _enc(M memory m) internal view returns (bytes memory) {
        bytes memory header = abi.encodePacked(
            uint32(1), m.src, m.dst, m.nonce, m.sender, m.recipient, m.destCaller, uint32(2000), uint32(2000)
        );
        bytes memory body = abi.encodePacked(
            uint32(1), m.burnToken, m.mintRecipient, m.amount, _b(remoteStrategy), m.maxFee, m.fee, uint256(0)
        );
        return abi.encodePacked(header, body);
    }

    function _signWith(uint256 pk, bytes memory message) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, keccak256(message));
        return abi.encodePacked(r, s, v);
    }

    function _settle(uint64 pid, M memory m) internal {
        bytes memory message = _enc(m);
        bytes memory att = _signWith(attesterPk, message);
        vm.prank(manager);
        vault.settleCrossChainWithMessage(pid, message, att);
    }
}
