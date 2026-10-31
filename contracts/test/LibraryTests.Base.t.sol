// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CctpSettlementLogic} from "../AutonomousVault.sol";
import {ShariahVault, ShariahGovernanceLogic, ShariahAccountingLogic} from "../ShariahVault.sol";
import {ShariahVaultV2, ShariahRegistryLogic} from "../ShariahVaultV2.sol";
import {ShariahAdapterRegistry} from "../ShariahAdapterRegistry.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";

/// @dev Adapter whose currentValue() read behaves according to `mode`.
///      0 valid(32B) 1 revert 2 short(31B) 3 long(64B) 4 gas-burn 5 empty 6 returndata bomb(100KB)
contract MockValueAdapter {
    uint8 public mode;
    uint256 public val;

    function set(uint8 m, uint256 v) external {
        mode = m;
        val = v;
    }

    fallback() external {
        uint8 m = mode;
        uint256 v = val;
        if (m == 0) {
            assembly { mstore(0, v) return(0, 32) }
        } else if (m == 1) {
            revert("nope");
        } else if (m == 2) {
            assembly { mstore(0, v) return(1, 31) }
        } else if (m == 3) {
            assembly { mstore(0, v) mstore(32, v) return(0, 64) }
        } else if (m == 4) {
            assembly { for {} 1 {} {} }
        } else if (m == 5) {
            assembly { return(0, 0) }
        } else {
            assembly { return(0, 100000) }
        }
    }
}

/// @dev Registry stub returning a configurable Screening.
contract MockScreeningRegistry {
    bytes32 public hash;
    uint256 public expiresAt;

    function set(bytes32 h, uint256 e) external {
        hash = h;
        expiresAt = e;
    }

    function getScreening(address) external view returns (ShariahAdapterRegistry.Screening memory s) {
        s.pronouncementHash = hash;
        s.expiresAt = expiresAt;
        s.setAt = 1;
    }
}

/// @dev CCTP transmitter stub: localDomain modes + receiveMessage that mints `mintAmount` to `to`.
contract MockTransmitter {
    uint8 public domainMode; // 0 ok, 1 revert, 2 short return (31B)
    uint32 public domain;
    bool public receiveOk = true;
    uint256 public mintAmount;
    MockERC20 public token;
    address public to;

    function setDomain(uint8 m, uint32 d) external {
        domainMode = m;
        domain = d;
    }

    function setReceive(bool ok, MockERC20 t, address to_, uint256 amt) external {
        receiveOk = ok;
        token = t;
        to = to_;
        mintAmount = amt;
    }

    function localDomain() external view returns (uint32) {
        if (domainMode == 1) revert("no");
        if (domainMode == 2) {
            uint256 d = domain;
            assembly { mstore(0, d) return(1, 31) }
        }
        return domain;
    }

    function receiveMessage(bytes calldata, bytes calldata) external returns (bool) {
        if (mintAmount != 0) token.mint(to, mintAmount);
        return receiveOk;
    }
}

contract MockMessenger {
    uint256 public amount;
    uint32 public destDomain;
    bytes32 public recipient;
    address public burnToken;
    bytes32 public destCaller;
    uint256 public maxFee;
    uint32 public minFinality;
    uint256 public allowanceSeen;
    uint256 public calls;

    function depositForBurn(uint256 a, uint32 d, bytes32 r, address t, bytes32 c, uint256 f, uint32 m) external {
        amount = a;
        destDomain = d;
        recipient = r;
        burnToken = t;
        destCaller = c;
        maxFee = f;
        minFinality = m;
        allowanceSeen = IERC20(t).allowance(msg.sender, address(this));
        calls++;
    }
}

/// @dev Holds the storage the linked libraries expect and forwards to them (delegatecall via linking).
contract LibHarness {
    mapping(address => uint256) public principalOf;
    address[] public funded;
    mapping(address => uint256) public fundedIndex;
    mapping(address => bool) public retiredGold;
    mapping(uint32 => mapping(bytes32 => ShariahVault.PendingRemoteRecipient)) public pendingRR;
    mapping(uint32 => mapping(bytes32 => bool)) public approvedRR;
    ShariahVault.PendingDustThreshold public dust;
    ShariahVaultV2.PendingRegistry public pendingReg;
    mapping(uint32 => bytes32) public remoteMessenger;
    mapping(uint32 => mapping(bytes32 => bool)) public consumed;
    uint256 public dustValue;

    function effectiveDustThreshold() external view returns (uint256) {
        return dustValue;
    }

    function setDustValue(uint256 v) external {
        dustValue = v;
    }

    function setRemote(uint32 d, bytes32 m) external {
        remoteMessenger[d] = m;
    }

    function setPrincipal(address a, uint256 p) external {
        principalOf[a] = p;
    }

    function fundedLength() external view returns (uint256) {
        return funded.length;
    }

    // ── accounting ──
    function retire(address adapter, uint256 sold, uint256 held, uint256 deployed) external returns (uint256) {
        return ShariahAccountingLogic.retireGoldPrincipal(principalOf, adapter, sold, held, deployed);
    }

    function book(address adapter, uint256 amount, address spread, address allocation) external {
        ShariahAccountingLogic.bookPrincipal(funded, fundedIndex, principalOf, adapter, amount, spread, allocation);
    }

    function writeOff(address adapter) external returns (uint256) {
        return ShariahAccountingLogic.writeOff(funded, fundedIndex, principalOf, adapter);
    }

    function loss() external view returns (uint256) {
        return ShariahAccountingLogic.unrealizedAdapterLoss(funded, principalOf);
    }

    function healthy(address spread, address allocation) external view returns (bool) {
        return ShariahAccountingLogic.valuationHealthy(funded, principalOf, spread, allocation);
    }

    function writedown(address spread, address allocation) external view returns (uint256) {
        return ShariahAccountingLogic.goldWritedown(principalOf, spread, allocation);
    }

    function gain(address spread, address allocation) external view returns (uint256) {
        return ShariahAccountingLogic.goldUnrealizedGain(principalOf, spread, allocation);
    }

    // ── governance ──
    function gPropose(uint32 d, bytes32 r, bool a) external {
        ShariahGovernanceLogic.proposeRemoteRecipient(pendingRR, d, r, a);
    }

    function gConfirm(uint32 d, bytes32 r) external {
        ShariahGovernanceLogic.confirmRemoteRecipient(pendingRR, approvedRR, d, r);
    }

    function gCancel(uint32 d, bytes32 r) external {
        ShariahGovernanceLogic.cancelRemoteRecipient(pendingRR, d, r);
    }

    function dPropose(uint256 v) external {
        ShariahGovernanceLogic.proposeDustThreshold(dust, v);
    }

    function dCheck() external view {
        ShariahGovernanceLogic.checkDustConfirmation(dust);
    }

    function dCancel() external {
        ShariahGovernanceLogic.cancelDustThreshold(dust);
    }

    // ── registry ──
    function rPropose(address current, address proposed) external {
        ShariahRegistryLogic.propose(pendingReg, current, proposed);
    }

    function rConfirm() external returns (address) {
        return ShariahRegistryLogic.confirm(pendingReg, dust);
    }

    function rCancel() external {
        ShariahRegistryLogic.cancel(pendingReg);
    }

    function rScreen(address registry, address strategy) external view {
        ShariahRegistryLogic.checkScreening(ShariahAdapterRegistry(registry), strategy);
    }

    // ── cctp ──
    function seedDust(uint256 v, uint256 after_, bool exists) external {
        dust = ShariahVault.PendingDustThreshold(v, after_, exists);
    }

    function validate(CctpSettlementLogic.Config memory c, bytes calldata message) external view {
        CctpSettlementLogic.validateHeader(c, remoteMessenger, message);
    }

    function consume(bytes calldata message) external {
        CctpSettlementLogic.consumeInbound(consumed, message);
    }

    function settle(CctpSettlementLogic.Config memory c, uint64 id, bytes calldata message)
        external returns (uint256)
    {
        return CctpSettlementLogic.receiveSettlement(c, remoteMessenger, consumed, id, message, hex"abcd");
    }

    function burn(address token, address messenger, uint32 dd, bytes32 r, uint256 amt, uint256 bps, uint32 fin)
        external
    {
        CctpSettlementLogic.burn(token, messenger, dd, r, amt, bps, fin);
    }
}

abstract contract LibTestBase is Test {
    LibHarness internal h;

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        h = new LibHarness();
    }

    function _adapter(uint8 mode, uint256 v) internal returns (MockValueAdapter m) {
        m = new MockValueAdapter();
        m.set(mode, v);
    }
}
