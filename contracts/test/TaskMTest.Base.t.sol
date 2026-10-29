// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AutonomousVault, CctpMessageDecoder} from "../AutonomousVault.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";

/// @dev Records the seven native CCTP V2 depositForBurn arguments. Optionally burns (pulls) tokens.
contract MockTokenMessengerM {
    struct Call {
        uint256 amount;
        uint32 destinationDomain;
        bytes32 mintRecipient;
        address burnToken;
        bytes32 destinationCaller;
        uint256 maxFee;
        uint32 minFinalityThreshold;
    }

    Call public last;
    uint256 public callCount;
    bool public pull = true;
    bool public partialPull;
    /// @dev Allowance the vault had granted at the moment depositForBurn ran.
    uint256 public allowanceSeen;

    function configure(bool pull_, bool partial_) external {
        pull = pull_;
        partialPull = partial_;
    }

    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external {
        last = Call(amount, destinationDomain, mintRecipient, burnToken, destinationCaller, maxFee, minFinalityThreshold);
        ++callCount;
        allowanceSeen = IERC20(burnToken).allowance(msg.sender, address(this));
        if (pull) {
            uint256 a = partialPull ? amount / 2 : amount;
            IERC20(burnToken).transferFrom(msg.sender, address(this), a);
        }
    }
}

/// @dev CCTP transmitter stub WITHOUT localDomain(): the vault must fall back to its stored domain.
contract MockTransmitterM {
    MockERC20 public immutable usdc;
    address public mintTo;
    uint256 public mintAmount;
    bool public ret = true;
    bool public doRevert;
    uint256 public calls;
    bytes32 public lastMsgHash;
    bytes32 public lastAttHash;

    constructor(MockERC20 usdc_) {
        usdc = usdc_;
    }

    function arm(address to, uint256 amount) external {
        mintTo = to;
        mintAmount = amount;
    }

    function setRet(bool r) external {
        ret = r;
    }

    function setRevert(bool r) external {
        doRevert = r;
    }

    function receiveMessage(bytes calldata m, bytes calldata a) external returns (bool) {
        ++calls;
        lastMsgHash = keccak256(m);
        lastAttHash = keccak256(a);
        if (doRevert) revert("transmitter: boom");
        if (mintAmount > 0) usdc.mint(mintTo, mintAmount);
        return ret;
    }
}

/// @dev Same, but reports a localDomain().
contract MockTransmitterDomainM is MockTransmitterM {
    uint32 public localDomain;

    constructor(MockERC20 usdc_, uint32 d) MockTransmitterM(usdc_) {
        localDomain = d;
    }

    function setDomain(uint32 d) external {
        localDomain = d;
    }
}

/// @dev Shared fixture + native MessageV2/BurnMessageV2 encoder. No test functions here.
abstract contract TaskMBase is Test {
    address internal owner = makeAddr("owner");
    address internal manager = makeAddr("manager");
    address internal alice = makeAddr("alice");
    address internal stranger = makeAddr("stranger");
    address internal remoteMessengerAddr = makeAddr("remoteMessenger");
    address internal remoteRecipientAddr = makeAddr("remoteRecipient");

    uint32 internal constant LOCAL_DOMAIN = 26;
    uint32 internal constant REMOTE_DOMAIN = 3;
    uint32 internal constant OTHER_DOMAIN = 7;
    uint256 internal constant DEPOSIT = 100_000e6;
    uint256 internal constant SENT = 10_000e6;
    bytes32 internal constant NONCE = bytes32(uint256(0xC0FFEE));

    MockERC20 internal usdc;
    MockTokenMessengerM internal messenger;
    MockTransmitterDomainM internal transmitter;
    AutonomousVault internal vault;

    struct Msg {
        uint32 headerVersion;
        uint32 sourceDomain;
        uint32 destinationDomain;
        bytes32 nonce;
        bytes32 sender;
        bytes32 recipient;
        bytes32 destinationCaller;
        uint32 minFinality;
        uint32 finalityExecuted;
        uint32 bodyVersion;
        bytes32 burnToken;
        bytes32 mintRecipient;
        uint256 amount;
        bytes32 messageSender;
        uint256 maxFee;
        uint256 feeExecuted;
        uint256 expirationBlock;
        bytes hookData;
    }

    function setUp() public virtual {
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);
        messenger = new MockTokenMessengerM();
        transmitter = new MockTransmitterDomainM(usdc, LOCAL_DOMAIN);

        vm.startPrank(owner);
        vault = new AutonomousVault(IERC20(address(usdc)), owner, LOCAL_DOMAIN);
        vault.setManager(manager);
        vault.setTokenMessenger(address(messenger));
        vault.setMessageTransmitter(address(transmitter));
        vault.setRemoteTokenMessenger(REMOTE_DOMAIN, _b32(remoteMessengerAddr));
        vault.setMaxAllocationBps(9_000);
        vault.setMaxPendingCrossChainBps(5_000);
        vm.stopPrank();

        usdc.mint(alice, DEPOSIT);
        vm.startPrank(alice);
        usdc.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, alice);
        vm.stopPrank();
    }

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _deploy(uint32 domain, uint256 amount) internal returns (uint64 id) {
        vm.prank(manager);
        vault.deployCrossChain(domain, _b32(remoteRecipientAddr), amount);
        id = vault.crossChainPositionCounter();
    }

    /// @dev A fully valid message returning `amount` to the vault, from REMOTE_DOMAIN.
    function _msg(uint256 amount, uint256 fee, bytes32 nonce) internal view returns (Msg memory m) {
        m.headerVersion = 1;
        m.sourceDomain = REMOTE_DOMAIN;
        m.destinationDomain = LOCAL_DOMAIN;
        m.nonce = nonce;
        m.sender = _b32(remoteMessengerAddr);
        m.recipient = _b32(address(messenger));
        m.destinationCaller = _b32(address(vault)); // remote strategies MUST burn with destinationCaller = this vault
        m.minFinality = 2000;
        m.finalityExecuted = 2000;
        m.bodyVersion = 1;
        m.burnToken = _b32(address(usdc));
        m.mintRecipient = _b32(address(vault));
        m.amount = amount;
        m.messageSender = _b32(address(vault));
        m.maxFee = fee;
        m.feeExecuted = fee;
        m.expirationBlock = 0;
    }

    function _encode(Msg memory m) internal pure returns (bytes memory) {
        bytes memory header = abi.encodePacked(
            m.headerVersion, m.sourceDomain, m.destinationDomain, m.nonce, m.sender,
            m.recipient, m.destinationCaller, m.minFinality, m.finalityExecuted
        );
        bytes memory body = abi.encodePacked(
            m.bodyVersion, m.burnToken, m.mintRecipient, m.amount, m.messageSender,
            m.maxFee, m.feeExecuted, m.expirationBlock
        );
        return abi.encodePacked(header, body, m.hookData);
    }

    /// @dev Arms the transmitter to mint `minted` to the vault and settles as the manager.
    function _settle(uint64 id, Msg memory m, uint256 minted) internal {
        transmitter.arm(address(vault), minted);
        _settleArmed(id, m);
    }

    /// @dev Settles without touching the transmitter, so vm.expectEmit can precede it directly.
    function _settleArmed(uint64 id, Msg memory m) internal {
        bytes memory message = _encode(m);
        vm.prank(manager);
        vault.settleCrossChainWithMessage(id, message, hex"a77e57");
    }

    /// @dev Count logs emitted by `emitter` whose topic0 matches `sig`.
    function _countLogs(Vm.Log[] memory logs, address emitter, bytes32 sig) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics.length > 0 && logs[i].topics[0] == sig) n++;
        }
    }
}
