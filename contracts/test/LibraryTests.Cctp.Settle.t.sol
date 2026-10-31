// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CctpSettlementLogic, CctpMessageDecoder, AutonomousVault} from "../AutonomousVault.sol";
import {Vm} from "forge-std/Vm.sol";
import {CctpBase} from "./LibraryTests.Cctp.t.sol";

/// receiveSettlement / consumeInbound through the LibHarness (library runs via delegatecall in harness storage).
contract LibraryCctpSettleTest is CctpBase {
    uint64 internal constant POS = 7;

    function _arm(uint256 minted) internal {
        tx_.setReceive(true, usdc, address(h), minted);
    }

    function _good(uint256 amount, uint256 fee) internal view returns (bytes memory) {
        return _msg(_goodH(), amount, fee);
    }

    // ── happy paths & fee handling ──
    function test_Settle_NoFee_BooksFullAmountAndConsumes() public {
        _arm(1_000e6);
        uint256 got = h.settle(_cfg(), POS, _good(1_000e6, 0));
        assertEq(got, 1_000e6);
        assertEq(usdc.balanceOf(address(h)), 1_000e6);
        assertTrue(h.consumed(SRC, NONCE));
    }

    function test_Settle_Fee_BooksAmountMinusFeeAndEmits() public {
        _arm(990e6);
        vm.expectEmit(true, false, false, true, address(h));
        emit CrossChainFeeDeducted(POS, 10e6);
        uint256 got = h.settle(_cfg(), POS, _good(1_000e6, 10e6));
        assertEq(got, 990e6, "amount minus feeExecuted");
    }

    function test_Settle_NoFeeNoEvent() public {
        _arm(5e6);
        vm.recordLogs();
        h.settle(_cfg(), POS, _good(5e6, 0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != CrossChainFeeDeducted.selector, "no fee event when fee is 0");
        }
    }

    function test_Settle_PreexistingBalanceDoesNotAffectDelta() public {
        usdc.mint(address(h), 777e6);
        _arm(95e6);
        assertEq(h.settle(_cfg(), POS, _good(100e6, 5e6)), 95e6);
        assertEq(usdc.balanceOf(address(h)), 872e6);
    }

    function test_Settle_FeeEqualsAmountExpectsZeroMint() public {
        _arm(0);
        vm.expectEmit(true, false, false, true, address(h));
        emit CrossChainFeeDeducted(POS, 50e6);
        assertEq(h.settle(_cfg(), POS, _good(50e6, 50e6)), 0);
    }

    function test_Settle_FeeAboveAmountTreatedAsZeroExpectedNet() public {
        _arm(0);
        assertEq(h.settle(_cfg(), POS, _good(50e6, 60e6)), 0);
        _arm(1);
        H memory x = _goodH();
        x.nonce = bytes32(uint256(2));
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.MessageAmountMismatch.selector, 0, 1));
        h.settle(_cfg(), POS, _msg(x, 50e6, 60e6));
    }

    // ── balance-delta check ──
    function test_Settle_TransmitterMintsLessReverts() public {
        _arm(99e6);
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.MessageAmountMismatch.selector, 100e6, 99e6));
        h.settle(_cfg(), POS, _good(100e6, 0));
    }

    function test_Settle_TransmitterMintsMoreReverts() public {
        _arm(101e6);
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.MessageAmountMismatch.selector, 100e6, 101e6));
        h.settle(_cfg(), POS, _good(100e6, 0));
    }

    function test_Settle_TransmitterMintsNothingReverts() public {
        _arm(0);
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.MessageAmountMismatch.selector, 100e6, 0));
        h.settle(_cfg(), POS, _good(100e6, 0));
    }

    function test_Settle_FeeMintedWithoutDeductionReverts() public {
        // transmitter ignores the fee and mints gross: delta (100) != expected net (90)
        _arm(100e6);
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.MessageAmountMismatch.selector, 90e6, 100e6));
        h.settle(_cfg(), POS, _good(100e6, 10e6));
    }

    function test_Settle_ReceiveReturnsFalseReverts() public {
        tx_.setReceive(false, usdc, address(h), 100e6);
        vm.expectRevert(AutonomousVault.MessageReceiveFailed.selector);
        h.settle(_cfg(), POS, _good(100e6, 0));
    }

    function test_Settle_TransmitterWithoutCodeReverts() public {
        CctpSettlementLogic.Config memory c = _cfg();
        c.transmitter = makeAddr("eoa");
        c.fallbackDomain = LOCAL;
        vm.expectRevert();
        h.settle(c, POS, _good(100e6, 0));
    }

    // ── replay protection ──
    function test_Settle_ReplaySameMessageRevertsInboundAlreadyConsumed() public {
        _arm(100e6);
        bytes memory m = _good(100e6, 0);
        h.settle(_cfg(), POS, m);
        _arm(100e6);
        vm.expectRevert(AutonomousVault.InboundAlreadyConsumed.selector);
        h.settle(_cfg(), POS, m);
        assertEq(usdc.balanceOf(address(h)), 100e6, "no second mint");
    }

    function test_Settle_DifferentNonceSettlesAgain() public {
        _arm(100e6);
        h.settle(_cfg(), POS, _good(100e6, 0));
        H memory x = _goodH();
        x.nonce = bytes32(uint256(NONCE) + 1);
        _arm(40e6);
        assertEq(h.settle(_cfg(), POS, _msg(x, 40e6, 0)), 40e6);
        assertEq(usdc.balanceOf(address(h)), 140e6);
    }

    function test_Settle_ReplayGuardSharedWithConsume() public {
        h.consume(_good(100e6, 0));
        _arm(100e6);
        vm.expectRevert(AutonomousVault.InboundAlreadyConsumed.selector);
        h.settle(_cfg(), POS, _good(100e6, 0));
    }

    function test_Settle_FailedSettlementDoesNotBurnTheNonce() public {
        _arm(1e6);
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.MessageAmountMismatch.selector, 100e6, 1e6));
        h.settle(_cfg(), POS, _good(100e6, 0));
        assertFalse(h.consumed(SRC, NONCE), "revert rolls back consumption");
        _arm(100e6);
        assertEq(h.settle(_cfg(), POS, _good(100e6, 0)), 100e6, "retry succeeds");
    }

    // ── body & header checks inside receiveSettlement ──
    function test_Settle_WrongMintRecipientReverts() public {
        _arm(100e6);
        bytes32 other = _b32(makeAddr("other"));
        bytes memory m = abi.encodePacked(_header(_goodH()), _body(1, other, 100e6, 0));
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.WrongMintRecipient.selector, other));
        h.settle(_cfg(), POS, m);
        assertFalse(h.consumed(SRC, NONCE));
    }

    function test_Settle_WrongBodyVersionReverts() public {
        bytes memory m = abi.encodePacked(_header(_goodH()), _body(2, _b32(address(h)), 100e6, 0));
        vm.expectRevert(abi.encodeWithSelector(CctpMessageDecoder.WrongBodyVersion.selector, uint32(2)));
        h.settle(_cfg(), POS, m);
    }

    function test_Settle_HeaderOnlyMessageRevertsInvalidRange() public {
        bytes memory m = _header(_goodH());
        vm.expectRevert(abi.encodeWithSelector(CctpMessageDecoder.InvalidMessageRange.selector, 148, 0, 376));
        h.settle(_cfg(), POS, m);
    }

    function test_Settle_HeaderValidationRunsFirst() public {
        _arm(100e6);
        H memory x = _goodH();
        x.sender = bytes32(uint256(9));
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.WrongRemoteSender.selector, REMOTE, x.sender));
        h.settle(_cfg(), POS, _msg(x, 100e6, 0));
    }

    function test_Settle_HookDataTrailerIgnored() public {
        _arm(10e6);
        bytes memory m = abi.encodePacked(_good(10e6, 0), hex"cafebabe");
        assertEq(h.settle(_cfg(), POS, m), 10e6);
    }

    function testFuzz_Settle_ReceivedIsAlwaysNetOfFee(uint256 amount, uint256 fee, uint256 pre) public {
        amount = bound(amount, 0, type(uint128).max);
        fee = bound(fee, 0, amount);
        pre = bound(pre, 0, type(uint128).max);
        usdc.mint(address(h), pre);
        _arm(amount - fee);
        assertEq(h.settle(_cfg(), POS, _good(amount, fee)), amount - fee);
        assertEq(usdc.balanceOf(address(h)), pre + amount - fee);
    }

    function testFuzz_Settle_AnyMintOtherThanNetReverts(uint256 amount, uint256 fee, uint256 minted) public {
        amount = bound(amount, 0, type(uint128).max);
        fee = bound(fee, 0, amount * 2);
        minted = bound(minted, 0, type(uint128).max);
        uint256 net = fee <= amount ? amount - fee : 0;
        vm.assume(minted != net);
        _arm(minted);
        vm.expectRevert(abi.encodeWithSelector(AutonomousVault.MessageAmountMismatch.selector, net, minted));
        h.settle(_cfg(), POS, _good(amount, fee));
    }

    function testFuzz_Consume_ReplayPerDomainNonce(uint32 d1, uint32 d2, bytes32 n1, bytes32 n2) public {
        H memory a = _goodH();
        a.src = d1;
        a.nonce = n1;
        H memory b = _goodH();
        b.src = d2;
        b.nonce = n2;
        h.consume(_header(a));
        if (d1 == d2 && n1 == n2) {
            vm.expectRevert(AutonomousVault.InboundAlreadyConsumed.selector);
            h.consume(_header(b));
        } else {
            h.consume(_header(b));
        }
    }
}

/// CctpSettlementLogic.burn through the LibHarness with the mock messenger.
contract LibraryCctpBurnTest is CctpBase {
    bytes32 internal constant RCPT = bytes32(uint256(0xBEEF));

    function test_Burn_PassesParametersAndZeroDestinationCaller() public {
        h.burn(address(usdc), address(messenger), 3, RCPT, 1_000e6, 100, 2000);
        assertEq(messenger.calls(), 1);
        assertEq(messenger.amount(), 1_000e6);
        assertEq(messenger.destDomain(), 3);
        assertEq(messenger.recipient(), RCPT);
        assertEq(messenger.burnToken(), address(usdc));
        assertEq(messenger.destCaller(), bytes32(0), "any caller may relay");
    }

    function test_Burn_MaxFeeIsBpsOfAmountFloored() public {
        h.burn(address(usdc), address(messenger), 3, RCPT, 1_000e6, 100, 2000);
        assertEq(messenger.maxFee(), 10e6, "1% of amount");
        h.burn(address(usdc), address(messenger), 3, RCPT, 999, 100, 2000);
        assertEq(messenger.maxFee(), 9, "floor(999*100/10000)");
        h.burn(address(usdc), address(messenger), 3, RCPT, 99, 100, 2000);
        assertEq(messenger.maxFee(), 0, "dust amount -> zero max fee");
    }

    function test_Burn_ZeroBpsMeansZeroMaxFee() public {
        h.burn(address(usdc), address(messenger), 3, RCPT, 1_000e6, 0, 2000);
        assertEq(messenger.maxFee(), 0);
    }

    function test_Burn_LibraryAppliesBpsWithoutOwnCap() public {
        // the 100 bps cap lives in AutonomousVault.setCrossChainMaxFeeBps, not in the library
        h.burn(address(usdc), address(messenger), 3, RCPT, 1_000e6, 10_000, 2000);
        assertEq(messenger.maxFee(), 1_000e6);
    }

    function test_Burn_FastFinalityPassedThrough() public {
        h.burn(address(usdc), address(messenger), 3, RCPT, 1e6, 1, 1000);
        assertEq(messenger.minFinality(), 1000);
    }

    function test_Burn_StandardFinalityPassedThrough() public {
        h.burn(address(usdc), address(messenger), 3, RCPT, 1e6, 1, 2000);
        assertEq(messenger.minFinality(), 2000);
    }

    function test_Burn_ApprovesExactAmountBeforeCall() public {
        h.burn(address(usdc), address(messenger), 3, RCPT, 321e6, 100, 2000);
        assertEq(messenger.allowanceSeen(), 321e6, "messenger saw exact allowance during burn");
    }

    function test_Burn_AllowanceIsSetNotAccumulated() public {
        h.burn(address(usdc), address(messenger), 3, RCPT, 500e6, 100, 2000);
        // mock messenger never pulls funds, so allowance stays; a second burn must overwrite, not add
        h.burn(address(usdc), address(messenger), 3, RCPT, 200e6, 100, 2000);
        assertEq(messenger.allowanceSeen(), 200e6);
        assertEq(usdc.allowance(address(h), address(messenger)), 200e6);
    }

    function test_Burn_LibraryDoesNotItselfClearAllowance() public {
        // Documents behaviour: allowance is consumed by a real messenger's transferFrom, the library
        // does not reset it afterwards. With a non-pulling messenger the exact amount remains.
        h.burn(address(usdc), address(messenger), 3, RCPT, 50e6, 100, 2000);
        assertEq(usdc.allowance(address(h), address(messenger)), 50e6);
    }

    function test_Burn_MessengerWithoutCodeReverts() public {
        vm.expectRevert();
        h.burn(address(usdc), makeAddr("eoa"), 3, RCPT, 1e6, 100, 2000);
    }

    function test_Burn_HugeAmountTimesBpsOverflowReverts() public {
        vm.expectRevert(); // panic 0x11: amount * bps overflows
        h.burn(address(usdc), address(messenger), 3, RCPT, type(uint256).max, 100, 2000);
    }

    function testFuzz_Burn_MaxFeeBoundedByBps(uint256 amount, uint256 bps, uint32 fin, uint32 dd) public {
        amount = bound(amount, 0, type(uint128).max);
        bps = bound(bps, 0, 100);
        h.burn(address(usdc), address(messenger), dd, RCPT, amount, bps, fin);
        assertEq(messenger.maxFee(), (amount * bps) / 10_000);
        assertLe(messenger.maxFee(), amount / 100, "never above 1% for bps<=100");
        assertEq(messenger.minFinality(), fin);
        assertEq(messenger.destDomain(), dd);
        assertEq(messenger.allowanceSeen(), amount);
    }
}
