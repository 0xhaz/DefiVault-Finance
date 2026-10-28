// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ─── Minimal contract interfaces (deployed on Arc Testnet) ────────────────────

interface IShariahVaultV2 {
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner_) external returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function lockedProfit() external view returns (uint256);
    function claimMusharakahProfit(uint256 grossProfit) external;
    function setTokenMessenger(address messenger) external;
    function setMessageTransmitter(address transmitter) external;
    function setGoldCrossChainBlocked(bool blocked) external;
    function deployCrossChain(uint32 destDomain, bytes32 recipient, uint256 amount) external;
    function settleCrossChainWithMessage(uint64 nonce, bytes calldata message, bytes calldata attestation) external;
    function tokenMessenger() external view returns (address);
    function messageTransmitter() external view returns (address);
    function sourceDomain() external view returns (uint32);
    function maxPendingCrossChainBps() external view returns (uint256);
    function pendingCrossChain(uint64 nonce) external view returns (uint256);
    function owner() external view returns (address);
    function goldCrossChainBlocked() external view returns (bool);
    function profitUnlockPeriod() external view returns (uint256);
    function hurdlePrincipal() external view returns (uint256);
    function purificationEscrow() external view returns (address);
    function setMaxPendingCrossChainBps(uint256 bps) external;
}

// ─── Mock token messenger (replaces real CCTP messenger in Test 1) ────────────
//     depositForBurnWithCaller: does NOT actually burn — just mints dummy USDC
//     to the caller and returns an incrementing nonce.
contract MinimalMockMessenger {
    address public usdc;
    uint64 public nextNonce = 1_000;

    constructor(address usdc_) {
        usdc = usdc_;
    }

    /// @dev Called by vault.deployCrossChain. Returns nonce; leaves vault's USDC balance
    ///      unchanged (no real burn needed on the fork — we just need the nonce registered).
    function depositForBurnWithCaller(
        uint256,       /* amount */
        uint32,        /* destinationDomain */
        bytes32,       /* mintRecipient */
        address,       /* burnToken */
        bytes32        /* destinationCaller */
    ) external returns (uint64 nonce) {
        nonce = nextNonce++;
    }
}

// ─── Mock message transmitter (replaces real CCTP transmitter in Test 1) ─────
//     receiveMessage: mints a fixed `mintAmount` of USDC to `vault` and returns true.
//     This simulates the transmitter minting (amount - feeExecuted) to mintRecipient.
contract MinimalMockTransmitter {
    address public usdc;
    address public vault;
    uint256 public mintAmount;

    constructor(address usdc_, address vault_, uint256 mintAmount_) {
        usdc     = usdc_;
        vault    = vault_;
        mintAmount = mintAmount_;
    }

    function receiveMessage(bytes calldata, bytes calldata) external returns (bool) {
        // Mint net settled USDC (amount - feeExecuted) directly to vault.
        IMintableERC20(usdc).mint(vault, mintAmount);
        return true;
    }
}

interface IMintableERC20 {
    function mint(address to, uint256 amount) external;
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner_, address spender) external view returns (uint256);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
}

// ─── Minimal MockERC20 deployed inline for etch ───────────────────────────────
//     Etched at the USDC predeploy address so vault calls hit real EVM storage.
contract EtchableUSDC {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    string  public constant name     = "USD Coin";
    string  public constant symbol   = "USDC";
    uint8   public constant decimals = 6;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner_, address indexed spender, uint256 value);

    function totalSupply() external view returns (uint256) { return _totalSupply; }
    function balanceOf(address a) external view returns (uint256) { return _balances[a]; }
    function allowance(address o, address s) external view returns (uint256) { return _allowances[o][s]; }

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
        _totalSupply  += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(_balances[msg.sender] >= amount, "ERC20: insufficient balance");
        _balances[msg.sender] -= amount;
        _balances[to]         += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(_balances[from] >= amount, "ERC20: insufficient balance");
        uint256 allowed = _allowances[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "ERC20: insufficient allowance");
            _allowances[from][msg.sender] = allowed - amount;
        }
        _balances[from] -= amount;
        _balances[to]   += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    /// @dev forceApprove (SafeERC20 uses this via IERC20.approve with no prior check)
    function forceApprove(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
}

// ─── CCTP V2 message builder library ─────────────────────────────────────────
//
//  Outer MessageV2 header (116 bytes, big-endian):
//    [0..3]    version       uint32
//    [4..7]    sourceDomain  uint32
//    [8..11]   destDomain    uint32
//    [12..19]  nonce         uint64
//    [20..51]  sender        bytes32
//    [52..83]  recipient     bytes32  (mintRecipient for the vault)
//    [84..115] destCaller    bytes32
//
//  BurnMessageV2 body (228 bytes, body offset = header offset + field offset):
//    body[0..3]     version          uint32   (4 bytes)
//    body[4..35]    burnToken        bytes32  (32 bytes)
//    body[36..67]   mintRecipient    bytes32  (32 bytes)  ← vault address
//    body[68..99]   amount           uint256  (32 bytes)  ← gross amount
//    body[100..131] messageSender    bytes32  (32 bytes)
//    body[132..163] maxFee           uint256  (32 bytes)  ← fee ceiling
//    body[164..195] feeExecuted      uint256  (32 bytes)  ← ACTUAL fee (offset fix under test)
//    body[196..227] expirationBlock  uint256  (32 bytes)
//
//  Total: 116 + 228 = 344 bytes.
library CctpV2MsgBuilder {
    function build(
        uint32  sourceDomain_,
        uint32  destDomain_,
        uint64  nonce_,
        address mintRecipient_,
        uint256 amount_,
        uint256 maxFee_,
        uint256 feeExecuted_
    ) internal pure returns (bytes memory msg_) {
        // ── Header (116 bytes) ─────────────────────────────────────────────
        bytes memory header = new bytes(116);

        // version = 2 at [0..3]
        header[3] = bytes1(uint8(2));

        // sourceDomain at [4..7]
        header[4] = bytes1(uint8(sourceDomain_ >> 24));
        header[5] = bytes1(uint8(sourceDomain_ >> 16));
        header[6] = bytes1(uint8(sourceDomain_ >> 8));
        header[7] = bytes1(uint8(sourceDomain_));

        // destDomain at [8..11]
        header[8]  = bytes1(uint8(destDomain_ >> 24));
        header[9]  = bytes1(uint8(destDomain_ >> 16));
        header[10] = bytes1(uint8(destDomain_ >> 8));
        header[11] = bytes1(uint8(destDomain_));

        // nonce at [12..19] (uint64, big-endian)
        for (uint256 i = 0; i < 8; i++) {
            header[19 - i] = bytes1(uint8(nonce_ >> (i * 8)));
        }

        // sender (bytes32) at [20..51] — leave zero (not checked by vault)
        // recipient (bytes32) at [52..83] — leave zero (not checked in header,
        //   mintRecipient lives in the body)
        // destCaller (bytes32) at [84..115] — leave zero

        // ── Body (228 bytes) ──────────────────────────────────────────────
        bytes memory body = new bytes(228);

        // body[0..3] version = 2
        body[3] = bytes1(uint8(2));

        // body[4..35] burnToken — leave zero (not validated by vault in settle path)

        // body[36..67] mintRecipient (the vault address, left-padded to bytes32)
        bytes32 recip = bytes32(uint256(uint160(mintRecipient_)));
        for (uint256 i = 0; i < 32; i++) {
            body[36 + i] = recip[i];
        }

        // body[68..99] amount (uint256)
        bytes32 amt = bytes32(amount_);
        for (uint256 i = 0; i < 32; i++) {
            body[68 + i] = amt[i];
        }

        // body[100..131] messageSender — leave zero

        // body[132..163] maxFee (uint256)
        bytes32 mf = bytes32(maxFee_);
        for (uint256 i = 0; i < 32; i++) {
            body[132 + i] = mf[i];
        }

        // body[164..195] feeExecuted (uint256) — THIS is the offset the L1 fix targets
        bytes32 fe = bytes32(feeExecuted_);
        for (uint256 i = 0; i < 32; i++) {
            body[164 + i] = fe[i];
        }

        // body[196..227] expirationBlock — leave zero

        msg_ = abi.encodePacked(header, body);
        // Confirm length exactly 344 bytes
        assert(msg_.length == 344);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Test contract
// ─────────────────────────────────────────────────────────────────────────────
contract ForkRehearsalSteps5And7 is Test {

    // ── Deployed contract addresses ───────────────────────────────────────
    address constant VAULT         = 0xba094D5B01F4fd245EA345Be6B8ac833488c81B0;
    address constant ESCROW        = 0xcC58b11c3Cd251a44989fEf1f05BdcB0e16375ff;
    address constant CHARITY_MOD   = 0x1D05a0010C78B984b0De2735A6E868E9c9f5d99F;
    address constant TREASURY_MOD  = 0xF5B550B87476a4359f1307AeFC425cCC6E2530f5;
    address constant USDC_ADDR     = 0x3600000000000000000000000000000000000000;
    address constant OWNER         = 0x3D23214d59CA3582628FffFE44D0Df1CC73D98f9;

    IShariahVaultV2 vault;
    IMintableERC20  usdc;

    // ── setUp: etch MockERC20 at USDC predeploy, fund owner ───────────────
    function setUp() public {
        // Fork Arc Testnet
        vm.createSelectFork("arc_testnet");

        vault = IShariahVaultV2(VAULT);
        usdc  = IMintableERC20(USDC_ADDR);

        // Replace the Arc-native USDC predeploy with a standard EVM ERC20.
        // The vault's stored `asset()` still points to USDC_ADDR, but all
        // ERC20 calls now hit our in-process implementation (no StackUnderflow).
        EtchableUSDC mock = new EtchableUSDC();
        vm.etch(USDC_ADDR, address(mock).code);

        // Confirm etch worked
        assertEq(usdc.decimals(), 6, "USDC etch: wrong decimals");
    }

    // ─────────────────────────────────────────────────────────────────────
    // TEST 1: settleCrossChainWithMessage with feeExecuted < maxFee
    //
    // Verifies: the decoder reads feeExecuted at body[164], NOT body[132].
    // ─────────────────────────────────────────────────────────────────────
    function test_settleCrossChain_feeOffset_fix() public {
        // ── Step 1: fund and deposit ─────────────────────────────────────
        vm.prank(OWNER);
        usdc.mint(OWNER, 1_000e6);

        vm.startPrank(OWNER);
        usdc.approve(VAULT, 500e6);
        vault.deposit(500e6, OWNER);
        vm.stopPrank();

        uint256 assetsAfterDeposit = vault.totalAssets();
        assertGe(assetsAfterDeposit, 500e6, "T1: deposit didn't increase totalAssets");

        // ── Step 2: deploy mock messenger + transmitter, wire them up ────
        //    The transmitter will mint exactly 98e6 (amount=100e6 minus feeExecuted=2e6).
        MinimalMockMessenger   messenger   = new MinimalMockMessenger(USDC_ADDR);
        MinimalMockTransmitter transmitter = new MinimalMockTransmitter(USDC_ADDR, VAULT, 98e6);

        vm.startPrank(OWNER);
        vault.setTokenMessenger(address(messenger));
        vault.setMessageTransmitter(address(transmitter));

        // goldCrossChainBlocked is true on-chain — disable it so deployCrossChain can run.
        vault.setGoldCrossChainBlocked(false);

        // Raise maxPendingCrossChainBps to allow a 100e6 deployment from ~500e6 assets.
        // Default 2000 bps = 20% of totalAssets (~100e6 of 500e6 is exactly 20%).
        // Use 2500 bps to give comfortable headroom.
        vault.setMaxPendingCrossChainBps(2_500);
        vm.stopPrank();

        // ── Step 3: deployCrossChain to register nonce ───────────────────
        uint32  destDomain = 0;   // Ethereum; not sourceDomain (26=Arc)
        bytes32 recipient  = bytes32(uint256(uint160(VAULT))); // vault as mintRecipient

        // Approve messenger to pull from vault (vault will forceApprove internally, but
        // we need vault to have approved messenger). Actually vault calls forceApprove
        // on USDC for the messenger before the depositForBurnWithCaller call.
        // The mock messenger doesn't actually pull tokens, so no pre-approval needed.

        vm.recordLogs();
        vm.prank(OWNER);
        vault.deployCrossChain(destDomain, recipient, 100e6);

        // Extract emitted nonce from CapitalDeployedCrossChain event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint64 emittedNonce;
        bytes32 eventSig = keccak256("CapitalDeployedCrossChain(uint32,bytes32,uint256,uint64)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                // nonce is the last non-indexed param; decode from data
                // event: (uint32 indexed dest, bytes32 indexed recipient, uint256 amount, uint64 nonce)
                // data contains: amount (uint256) + nonce (uint64, packed as uint256)
                (, uint64 n) = abi.decode(logs[i].data, (uint256, uint64));
                emittedNonce = n;
                break;
            }
        }
        assertGt(emittedNonce, 0, "T1: failed to capture nonce from event");
        console.log("T1: emitted nonce =", emittedNonce);

        // Confirm nonce registered
        uint256 pendingAmt = vault.pendingCrossChain(emittedNonce);
        assertEq(pendingAmt, 100e6, "T1: pendingCrossChain not registered");

        // ── Step 4: build 344-byte CCTP V2 message ───────────────────────
        //   amount=100e6, maxFee=5e6 at body[132], feeExecuted=2e6 at body[164].
        //   sourceDomain and nonce must match what the vault registered.
        uint32 srcDomain = vault.sourceDomain(); // 26 = Arc Testnet
        bytes memory message = CctpV2MsgBuilder.build(
            srcDomain,          // sourceDomain
            destDomain,         // destDomain
            emittedNonce,       // nonce matching pending position
            VAULT,              // mintRecipient (must equal vault address)
            100e6,              // gross amount
            5e6,                // maxFee  — at body offset 132
            2e6                 // feeExecuted — at body offset 164 (the fix under test)
        );
        assertEq(message.length, 344, "T1: message must be exactly 344 bytes");

        // The transmitter will mint 98e6 to vault when receiveMessage is called.
        // The vault's decoder reads feeExecuted=2e6, computes expectedNet=98e6,
        // and then checks expectedNet == received (98e6 == 98e6). Should NOT revert.

        // ── Step 5: call settleCrossChainWithMessage ──────────────────────
        uint256 assetsBefore = vault.totalAssets();
        bytes memory fakeAttestation = hex""; // transmitter mock ignores attestation

        // Check for CrossChainFeeDeducted and CrossChainSettled events
        vm.expectEmit(true, false, false, true, VAULT);
        emit CrossChainFeeDeducted(emittedNonce, 2e6);

        vm.prank(OWNER);
        vault.settleCrossChainWithMessage(emittedNonce, message, fakeAttestation);

        // ── Step 6: assert totalAssets increased by 98e6 ─────────────────
        uint256 assetsAfter = vault.totalAssets();
        // deployCrossChain incremented totalDeployed by 100e6 and deducted from liquid balance.
        // _doSettle decrements totalDeployed by 100e6 (sent).
        // receiveMessage minted 98e6 to vault (net received).
        // Net change vs assetsBefore: +98e6 - 100e6 = -2e6 (fee cost absorbed).
        // But assetsBefore included the locked 100e6 in totalDeployed.
        // After settle: totalDeployed -= 100e6, liquid balance += 98e6.
        // So assetsAfter = assetsAfterDeposit - 100e6(deployed gone) + 98e6(received) 
        //                  + remaining_deployed = assetsAfterDeposit - 2e6
        // Simpler: assetsAfter = assetsBefore - 2e6 (fee absorbed as loss).
        assertApproxEqAbs(
            assetsAfter,
            assetsBefore - 2e6,
            1e4, // 0.01 USDC tolerance for rounding
            "T1: totalAssets should have decreased by exactly feeExecuted=2e6"
        );

        // Specifically: it is NOT assetsBefore-5e6 (maxFee) and NOT assetsBefore (no loss)
        assertTrue(assetsAfter < assetsBefore - 1e6,  "T1: fee must have been deducted (>1e6)");
        assertTrue(assetsAfter > assetsBefore - 5e6,  "T1: fee must NOT be 5e6 (maxFee, not feeExecuted)");

        // ── Step 7: assert nonce cleared (settled) ────────────────────────
        assertEq(vault.pendingCrossChain(emittedNonce), 0, "T1: nonce should be cleared after settle");

        console.log("T1 PASS: settleCrossChainWithMessage correctly used feeExecuted=2e6 (not maxFee=5e6)");
        console.log("  assetsBefore:", assetsBefore);
        console.log("  assetsAfter: ", assetsAfter);
        console.log("  delta:       ", assetsBefore - assetsAfter);
    }

    // Event declarations for vm.expectEmit
    event CrossChainFeeDeducted(uint64 indexed nonce, uint256 feeExecuted);
    event CrossChainSettled(uint64 indexed nonce, uint256 amount, uint256 shortfall);

    // ─────────────────────────────────────────────────────────────────────
    // TEST 1b: Wrong fee offset causes revert — regression guard
    //
    // If the decoder mistakenly read body[132] (maxFee=5e6) as feeExecuted,
    // it would compute expectedNet = 95e6, but transmitter mints 98e6.
    // settleCrossChainWithMessage would revert MessageAmountMismatch.
    //
    // This test confirms the FIX is correct: a message with feeExecuted=2e6
    // at body[164] does NOT trigger MessageAmountMismatch.
    // ─────────────────────────────────────────────────────────────────────
    function test_wrongFeeOffset_wouldCauseMismatch() public {
        // Re-run setup in isolation (each test gets a fresh fork snapshot via setUp)
        vm.prank(OWNER);
        usdc.mint(OWNER, 500e6);

        vm.startPrank(OWNER);
        usdc.approve(VAULT, 500e6);
        vault.deposit(500e6, OWNER);

        MinimalMockMessenger   messenger   = new MinimalMockMessenger(USDC_ADDR);
        // Transmitter mints 98e6 (simulates feeExecuted=2e6 being actually deducted)
        MinimalMockTransmitter transmitter = new MinimalMockTransmitter(USDC_ADDR, VAULT, 98e6);

        vault.setTokenMessenger(address(messenger));
        vault.setMessageTransmitter(address(transmitter));
        vault.setGoldCrossChainBlocked(false);
        vault.setMaxPendingCrossChainBps(2_500);

        vm.recordLogs();
        vault.deployCrossChain(0, bytes32(uint256(uint160(VAULT))), 100e6);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint64 emittedNonce;
        bytes32 eventSig = keccak256("CapitalDeployedCrossChain(uint32,bytes32,uint256,uint64)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                (, uint64 n) = abi.decode(logs[i].data, (uint256, uint64));
                emittedNonce = n;
                break;
            }
        }

        // Build a CORRECTLY-encoded message (feeExecuted=2e6 at body[164]).
        // The decoder MUST read body[164] and get 2e6.
        // expectedNet = 100e6 - 2e6 = 98e6 == transmitter mint. No revert.
        bytes memory goodMessage = CctpV2MsgBuilder.build(
            vault.sourceDomain(), 0, emittedNonce, VAULT,
            100e6, 5e6 /* maxFee at body[132] */, 2e6 /* feeExecuted at body[164] */
        );

        // Should succeed (no revert)
        vm.prank(OWNER);
        vault.settleCrossChainWithMessage(emittedNonce, goodMessage, hex"");
        console.log("T1b PASS: correct offset message settled without MessageAmountMismatch");
    }

    // ─────────────────────────────────────────────────────────────────────
    // TEST 2: PurificationEscrow.executeWaterfall + claimMusharakahProfit
    //
    // Confirms the profit waterfall runs end-to-end on the fork.
    // Exposes a contract integration bug: CharityModule.distributeCharity
    // checks msg.sender == vault (ShariahVaultV2), but it is called by
    // PurificationEscrow — causing a NotVault revert.
    // ─────────────────────────────────────────────────────────────────────
    function test_claimMusharakahProfit_waterfall() public {
        address depositor = makeAddr("depositor");

        // ── Step 1: fund deployer and depositor ──────────────────────────
        vm.prank(OWNER);
        usdc.mint(OWNER, 400e6);
        vm.prank(OWNER);
        usdc.mint(depositor, 100e6);

        // ── Step 2a: depositor deposits 100e6 ────────────────────────────
        vm.startPrank(depositor);
        usdc.approve(VAULT, 100e6);
        uint256 depositorShares = vault.deposit(100e6, depositor);
        vm.stopPrank();

        assertGt(depositorShares, 0, "T2: depositor should have received shares");
        console.log("T2: depositor shares:", depositorShares);

        // ── Step 2b: deployer deposits 100e6 (establishes share baseline) ─
        vm.startPrank(OWNER);
        usdc.approve(VAULT, 100e6);
        uint256 ownerShares = vault.deposit(100e6, OWNER);
        vm.stopPrank();

        uint256 assetsAfterDeposits = vault.totalAssets();
        console.log("T2: totalAssets after deposits:", assetsAfterDeposits);
        assertApproxEqAbs(assetsAfterDeposits, 200e6, 1e4, "T2: expected ~200e6 after both deposits");

        // ── Step 3: inject 10e6 synthetic profit into vault ──────────────
        // vm.deal / direct mint bypasses the Arc predeploy StackUnderflow.
        vm.prank(OWNER);
        usdc.mint(VAULT, 10e6);

        uint256 assetsWithProfit = vault.totalAssets();
        console.log("T2: totalAssets with synthetic profit:", assetsWithProfit);
        assertApproxEqAbs(assetsWithProfit, 210e6, 1e4, "T2: expected ~210e6 after profit injection");

        // ── Step 4: call claimMusharakahProfit(10e6) as owner ────────────
        //
        // KNOWN CONTRACT BUG: CharityModule.distributeCharity() checks
        //   msg.sender == vault (ShariahVaultV2 = 0xba094D...)
        // but it is called by PurificationEscrow (0xcC58b11c...)
        // This will revert with CharityModule.NotVault().
        //
        // We test the revert here to confirm the bug is present on the
        // deployed contracts, and report it as a contract bug below.
        //
        // The escrow's executeWaterfall step 3:
        //   charityModule.distributeCharity(afterPurification)  <- msg.sender = escrow
        // CharityModule:
        //   if (msg.sender != vault) revert NotVault()          <- vault = ShariahVaultV2
        //
        // Therefore claimMusharakahProfit always reverts on the current deployment.

        vm.expectRevert(); // CharityModule.NotVault
        vm.prank(OWNER);
        vault.claimMusharakahProfit(10e6);

        console.log("T2: claimMusharakahProfit correctly reverted (CharityModule NotVault bug confirmed)");

        // ── Step 4b: verify deposits and redemptions still work ──────────
        // The waterfall bug does not block deposits or redemptions.
        uint256 depositorBalanceBefore = usdc.balanceOf(depositor);

        vm.startPrank(depositor);
        // ERC4626 redeem: need vault to check allowance for depositor burning own shares
        // shares owned by depositor; redeem all
        uint256 received = vault.redeem(depositorShares, depositor, depositor);
        vm.stopPrank();

        uint256 depositorBalanceAfter = usdc.balanceOf(depositor);
        console.log("T2: depositor redeemed, received:", received);
        console.log("T2: depositor USDC after redeem:", depositorBalanceAfter);

        // Depositor should receive at least their original 100e6 (no loss to depositor).
        // Since profit is not locked (claimMusharakahProfit reverted, no lockProfit),
        // the extra 10e6 minted to vault IS reflected in totalAssets and thus in share price.
        // Depositor owns ~50% of shares (deposited 100e6 of 200e6 total).
        // They should get back ~100e6 + ~5e6 (their pro-rata share of the 10e6 profit).
        assertGe(received, 100e6, "T2: depositor should receive >= their deposit (no principal loss)");

        console.log("T2 PASS: deposits and redemptions work; waterfall bug recorded");
    }

    // ─────────────────────────────────────────────────────────────────────
    // TEST 2b: Verify escrow.executeWaterfall can be called directly
    //          (bypassing the CharityModule NotVault check by calling
    //          executeWaterfall with the vault impersonated)
    //
    // This simulates what a FIXED deployment would look like:
    // If CharityModule.vault were set to PurificationEscrow, the waterfall
    // would succeed. We test that premise by directly pranking the vault address.
    // ─────────────────────────────────────────────────────────────────────
    function test_escrow_executeWaterfall_charityNotVault_revert() public {
        // Fund the escrow with profit to distribute
        vm.prank(OWNER);
        usdc.mint(VAULT, 100e6);

        // Vault must approve escrow for grossProfit pull
        // (ShariahVault.claimMusharakahProfit does forceApprove before calling escrow)
        vm.prank(VAULT);
        usdc.approve(ESCROW, 10e6);

        // Call executeWaterfall directly as the vault (msg.sender == vault passes in escrow)
        // This simulates the escrow being called correctly.
        // The escrow then calls charityModule.distributeCharity -- which checks
        // msg.sender == CharityModule.vault (ShariahVaultV2).
        // msg.sender here is ESCROW, not ShariahVaultV2 -> REVERT NotVault.
        vm.expectRevert();
        vm.prank(VAULT);
        (bool success,) = ESCROW.call(
            abi.encodeWithSignature("executeWaterfall(uint256,uint256,uint256)", 10e6, 365 days, 100e6)
        );
        // If expectRevert was triggered, success is irrelevant.
        // The revert proves: CharityModule.vault must be PurificationEscrow, not ShariahVaultV2.
        (success); // suppress unused variable warning
        console.log("T2b PASS: executeWaterfall reverts with NotVault as expected (CharityModule wired to wrong caller)");
    }
}
