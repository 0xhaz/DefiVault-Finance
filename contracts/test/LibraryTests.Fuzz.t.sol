// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ShariahVault, ShariahAccountingLogic} from "../ShariahVault.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {LibTestBase, MockValueAdapter} from "./LibraryTests.Base.t.sol";

/// @dev Adapter that answers any call with exactly `len` bytes (first word = val, rest zero).
contract MockLenAdapter {
    uint256 public len;
    uint256 public val;

    function set(uint256 l, uint256 v) external {
        len = l;
        val = v;
    }

    fallback() external {
        uint256 l = len;
        uint256 v = val;
        assembly {
            mstore(0, v)
            // zero the next words so returns longer than 32 bytes are deterministic
            mstore(32, 0) mstore(64, 0) mstore(96, 0) mstore(128, 0) mstore(160, 0)
            mstore(192, 0) mstore(224, 0) mstore(256, 0) mstore(288, 0) mstore(320, 0)
            return(0, l)
        }
    }
}

contract LibraryFuzzHurdleTest is LibTestBase {
    uint256 internal constant HUGE = type(uint192).max;

    /// PROPERTY: accrued allowance P*t is preserved (to < 1 second on the new principal);
    ///           new principal = old + assets; start never moves backwards nor past `now`.
    function testFuzz_DepositHurdle_PreservesAllowance(uint256 elapsed, uint256 principal, uint256 assets) public view {
        elapsed = bound(elapsed, 0, block.timestamp);
        principal = bound(principal, 1, HUGE);
        assets = bound(assets, 0, HUGE);
        uint256 start = block.timestamp - elapsed;

        (uint256 newStart, uint256 newPrincipal) =
            ShariahAccountingLogic.depositHurdle(start, principal, 1, principal, assets);

        assertEq(newPrincipal, principal + assets, "new principal = old + assets");
        assertGe(newStart, start, "clock never moves backwards");
        assertLe(newStart, block.timestamp, "clock never in the future");

        uint256 newElapsed = block.timestamp - newStart;
        uint256 before = elapsed * principal;       // allowance before (principal-seconds)
        uint256 afterAllowance = newElapsed * newPrincipal;
        assertLe(afterAllowance, before, "never inflates allowance");
        // within one second of hurdle on the new principal
        assertLt(before - afterAllowance, newPrincipal, "loss < 1 second on new principal");
        assertLe(newElapsed, elapsed, "dilution only shortens elapsed time");
    }

    function testFuzz_DepositHurdle_ZeroAssetsKeepsStart(uint256 elapsed, uint256 principal) public view {
        elapsed = bound(elapsed, 0, block.timestamp);
        principal = bound(principal, 1, HUGE);
        uint256 start = block.timestamp - elapsed;
        (uint256 newStart, uint256 newPrincipal) =
            ShariahAccountingLogic.depositHurdle(start, principal, 1, principal, 0);
        assertEq(newStart, start);
        assertEq(newPrincipal, principal);
    }

    function testFuzz_DepositHurdle_MoreAssetsNeverLongerElapsed(uint256 elapsed, uint256 principal, uint256 a1, uint256 a2)
        public
        view
    {
        elapsed = bound(elapsed, 0, block.timestamp);
        principal = bound(principal, 1, HUGE);
        a1 = bound(a1, 0, HUGE);
        a2 = bound(a2, a1, HUGE);
        uint256 start = block.timestamp - elapsed;
        (uint256 s1,) = ShariahAccountingLogic.depositHurdle(start, principal, 1, principal, a1);
        (uint256 s2,) = ShariahAccountingLogic.depositHurdle(start, principal, 1, principal, a2);
        assertGe(s2, s1, "bigger deposit dilutes the clock at least as much");
    }

    /// PROPERTY: never reverts for any bounded inputs, incl. future starts and huge amounts.
    function testFuzz_DepositHurdle_NeverRevertsBounded(uint256 start, uint256 principal, uint256 supply, uint256 assetsNow, uint256 assets)
        public
        view
    {
        start = bound(start, 0, type(uint64).max);
        principal = bound(principal, 0, type(uint256).max / 4);
        assets = bound(assets, 0, type(uint256).max / 4);
        assetsNow = bound(assetsNow, 0, type(uint256).max / 4);
        (uint256 newStart, uint256 newPrincipal) =
            ShariahAccountingLogic.depositHurdle(start, principal, supply, assetsNow, assets);
        assertLe(newStart, block.timestamp);
        if (supply != 0 && principal != 0) assertEq(newPrincipal, principal + assets);
    }

    function testFuzz_DepositHurdle_FirstDepositSeeds(uint256 start, uint256 principal, uint256 assetsNow, uint256 assets) public view {
        start = bound(start, 0, type(uint64).max);
        principal = bound(principal, 0, HUGE);
        assetsNow = bound(assetsNow, 0, HUGE);
        assets = bound(assets, 0, HUGE);
        (uint256 s, uint256 p) = ShariahAccountingLogic.depositHurdle(start, principal, 0, assetsNow, assets);
        assertEq(s, block.timestamp, "zero supply restarts clock");
        assertEq(p, assets, "principal = just the deposit");
    }

    function testFuzz_DepositHurdle_ZeroPrincipalReseeds(uint256 start, uint256 supply, uint256 assetsNow, uint256 assets) public view {
        start = bound(start, 0, type(uint64).max);
        supply = bound(supply, 1, HUGE);
        assetsNow = bound(assetsNow, 0, HUGE);
        assets = bound(assets, 0, HUGE);
        (uint256 s, uint256 p) = ShariahAccountingLogic.depositHurdle(start, 0, supply, assetsNow, assets);
        assertEq(s, block.timestamp);
        assertEq(p, assetsNow + assets);
    }
}

contract LibraryFuzzRetireTest is LibTestBase {
    address internal ad = makeAddr("adapter");

    /// PROPERTY: retired <= principal, matches floor(P*sold/held), and deployed saturates at 0.
    function testFuzz_Retire_FractionMath(uint256 principal, uint256 held, uint256 sold, uint256 deployed) public {
        held = bound(held, 1, type(uint256).max);
        sold = bound(sold, 1, held);
        h.setPrincipal(ad, principal);

        uint256 newDeployed = h.retire(ad, sold, held, deployed);

        uint256 remaining = h.principalOf(ad);
        assertLe(remaining, principal, "principal never grows");
        uint256 retired = principal - remaining;
        assertEq(retired, sold == held ? principal : Math.mulDiv(principal, sold, held));
        assertEq(newDeployed, deployed > retired ? deployed - retired : 0);
    }

    function testFuzz_Retire_SellingAllHeldRetiresAll(uint256 principal, uint256 held, uint256 deployed) public {
        held = bound(held, 1, type(uint256).max);
        h.setPrincipal(ad, principal);
        h.retire(ad, held, held, deployed);
        assertEq(h.principalOf(ad), 0, "full sale clears principal");
    }

    function testFuzz_Retire_MonotoneInSoldTokens(uint256 principal, uint256 held, uint256 s1, uint256 s2) public {
        held = bound(held, 1, type(uint256).max);
        s1 = bound(s1, 1, held);
        s2 = bound(s2, s1, held);
        h.setPrincipal(ad, principal);
        h.retire(ad, s1, held, 0);
        uint256 retired1 = principal - h.principalOf(ad);
        h.setPrincipal(ad, principal);
        h.retire(ad, s2, held, 0);
        uint256 retired2 = principal - h.principalOf(ad);
        assertLe(retired1, retired2, "selling more retires at least as much");
    }

    /// PROPERTY: sequential partial sales never retire more than the principal and never revert;
    ///           selling the entire remaining holding zeroes it.
    function testFuzz_Retire_SequentialPartialsBoundedByPrincipal(uint256 principal, uint256 held, uint256 a, uint256 b) public {
        held = bound(held, 2, type(uint256).max);
        a = bound(a, 1, held - 1);
        b = bound(b, 1, held - a);
        h.setPrincipal(ad, principal);
        h.retire(ad, a, held, 0);
        uint256 p1 = h.principalOf(ad);
        h.retire(ad, b, held - a, 0);
        uint256 p2 = h.principalOf(ad);
        assertLe(p1, principal);
        assertLe(p2, p1);
        assertLe((principal - p1) + (p1 - p2), principal, "sum of retirements <= principal");
        if (a + b == held) assertEq(p2, 0, "final sale of remainder clears principal");
    }

    function testFuzz_Retire_InvalidFractionReverts(uint256 held, uint256 sold) public {
        held = bound(held, 0, type(uint128).max);
        // either zero sold or sold > held
        bool zero = sold % 2 == 0;
        sold = zero ? 0 : bound(sold, held + 1, uint256(type(uint128).max) + 1);
        vm.expectRevert(ShariahVault.InvalidGoldSaleFraction.selector);
        h.retire(ad, sold, held, 1);
    }
}

contract LibraryFuzzLiquidLimitTest is LibTestBase {
    uint256 internal constant CAP = 2 ** 120;

    function _tok(uint256 bal) internal returns (MockERC20 t) {
        t = new MockERC20("T", "T", 6);
        t.mint(address(this), bal);
    }

    /// PROPERTY: limit <= shares, and the payout for `limit` shares never exceeds the token balance.
    function testFuzz_LiquidLimit_NeverExceedsBalance(uint256 bal, uint256 shares, uint256 assets, uint256 vs) public {
        bal = bound(bal, 0, CAP);
        shares = bound(shares, 0, CAP);
        assets = bound(assets, 0, CAP);
        vs = bound(vs, 1, CAP);
        MockERC20 t = _tok(bal);
        uint256 lim = ShariahAccountingLogic.liquidRedeemLimit(address(t), shares, assets, vs);
        assertLe(lim, shares);
        assertLe(Math.mulDiv(lim, assets + 1, vs), bal, "payout for limit fits in liquidity");
    }

    /// PROPERTY: when the full redemption is payable the limit equals all shares; otherwise it is strictly less.
    function testFuzz_LiquidLimit_FullSharesIffPayable(uint256 bal, uint256 shares, uint256 assets, uint256 vs) public {
        bal = bound(bal, 0, CAP);
        shares = bound(shares, 0, CAP);
        assets = bound(assets, 0, CAP);
        vs = bound(vs, 1, CAP);
        MockERC20 t = _tok(bal);
        uint256 lim = ShariahAccountingLogic.liquidRedeemLimit(address(t), shares, assets, vs);
        bool payable_ = Math.mulDiv(shares, assets + 1, vs) <= bal;
        if (payable_) assertEq(lim, shares, "payable -> full shares");
        else assertLt(lim, shares, "not payable -> strictly fewer shares");
    }

    function testFuzz_LiquidLimit_MonotoneInLiquidity(uint256 b1, uint256 b2, uint256 shares, uint256 assets, uint256 vs) public {
        b1 = bound(b1, 0, CAP);
        b2 = bound(b2, b1, CAP);
        shares = bound(shares, 0, CAP);
        assets = bound(assets, 0, CAP);
        vs = bound(vs, 1, CAP);
        MockERC20 t1 = _tok(b1);
        MockERC20 t2 = _tok(b2);
        uint256 l1 = ShariahAccountingLogic.liquidRedeemLimit(address(t1), shares, assets, vs);
        uint256 l2 = ShariahAccountingLogic.liquidRedeemLimit(address(t2), shares, assets, vs);
        assertLe(l1, l2, "more liquidity never lowers the limit");
    }

    function testFuzz_LiquidLimit_ZeroLiquidityOnlyAllowsFreeShares(uint256 shares, uint256 assets, uint256 vs) public {
        shares = bound(shares, 0, CAP);
        assets = bound(assets, 0, CAP);
        vs = bound(vs, 1, CAP);
        MockERC20 t = _tok(0);
        uint256 lim = ShariahAccountingLogic.liquidRedeemLimit(address(t), shares, assets, vs);
        assertEq(Math.mulDiv(lim, assets + 1, vs), 0, "nothing payable from empty balance");
    }
}

contract LibraryFuzzAdapterReadTest is LibTestBase {
    /// PROPERTY: a valid 32-byte value is returned exactly (observed via the writeOff exposure error).
    function testFuzz_ValidValueReturnedExactly(uint256 value, uint256 principal) public {
        value = bound(value, 1, type(uint256).max);
        principal = bound(principal, 1, type(uint128).max);
        MockValueAdapter m = _adapter(0, value);
        h.book(address(m), principal, address(0), address(0));
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.GoldAdapterHasExposure.selector, address(m), value));
        h.writeOff(address(m));
    }

    function testFuzz_ValidValueDrivesLossExactly(uint256 value, uint256 principal) public {
        principal = bound(principal, 1, type(uint128).max);
        MockValueAdapter m = _adapter(0, value);
        h.book(address(m), principal, address(0), address(0));
        assertEq(h.loss(), principal > value ? principal - value : 0);
        assertEq(h.healthy(address(0), address(0)), principal <= value, "healthy iff no loss (dust 0)");
    }

    function testFuzz_ValidZeroValueAllowsWriteOff(uint256 principal) public {
        principal = bound(principal, 1, type(uint128).max);
        MockValueAdapter m = _adapter(0, 0);
        h.book(address(m), principal, address(0), address(0));
        assertEq(h.writeOff(address(m)), principal);
        assertEq(h.principalOf(address(m)), 0);
    }

    /// PROPERTY: revert / short / long / empty / gas burn / returndata bomb all yield the failure
    ///           result: no loss counted, entry unhealthy, never reverts the caller.
    function testFuzz_MalformedReadsAreFailureNeverRevert(uint8 mode, uint256 value, uint256 principal) public {
        mode = uint8(bound(mode, 1, 6));
        principal = bound(principal, 1, type(uint128).max);
        MockValueAdapter m = _adapter(mode, value);
        h.book(address(m), principal, address(0), address(0));
        assertEq(h.loss(), 0, "failed read marks nothing down");
        assertFalse(h.healthy(address(0), address(0)), "failed read -> unhealthy");
        assertEq(h.writedown(address(m), address(0)), 0, "failed gold read -> no writedown");
        assertEq(h.gain(address(m), address(0)), 0, "failed gold read -> no gain");
        assertEq(h.writeOff(address(m)), principal, "unreadable adapter can be written off");
    }

    /// PROPERTY: for ANY returndata length, only exactly 32 bytes is a valid read.
    function testFuzz_ReturndataLengthOnly32IsValid(uint256 len, uint256 value, uint256 principal) public {
        len = bound(len, 0, 300);
        principal = bound(principal, 1, type(uint128).max);
        MockLenAdapter m = new MockLenAdapter();
        m.set(len, value);
        h.book(address(m), principal, address(0), address(0));
        uint256 expectedLoss = (len == 32 && principal > value) ? principal - value : 0;
        assertEq(h.loss(), expectedLoss);
        bool expectHealthy = len == 32 && principal <= value;
        assertEq(h.healthy(address(0), address(0)), expectHealthy);
    }

    function testFuzz_EoaAdapterIsFailedRead(address eoa, uint256 principal) public {
        vm.assume(eoa.code.length == 0 && uint160(eoa) > 0xff && eoa != address(h) && eoa != address(vm));
        principal = bound(principal, 1, type(uint128).max);
        h.book(eoa, principal, address(0), address(0));
        assertEq(h.loss(), 0);
        assertFalse(h.healthy(address(0), address(0)));
    }
}

contract LibraryFuzzLossSumTest is LibTestBase {
    /// PROPERTY: loss == sum(max(principal-value,0)) over readable adapters; <= sum of principals;
    ///           gains and failed reads contribute nothing.
    function testFuzz_LossSummation(uint256 seed, uint8 count) public {
        uint256 n = bound(count, 1, ShariahAccountingLogic.MAX_FUNDED_ADAPTERS);
        uint256 sumPrincipal;
        uint256 expected;
        uint256 lossOnlyFromReadable;
        for (uint256 i; i < n; ++i) {
            uint256 p = bound(uint256(keccak256(abi.encode(seed, i, "p"))), 1, 2 ** 100);
            uint256 v = bound(uint256(keccak256(abi.encode(seed, i, "v"))), 0, 2 ** 101);
            uint8 mode = uint8(uint256(keccak256(abi.encode(seed, i, "m"))) % 7);
            MockValueAdapter m = _adapter(mode, v);
            h.book(address(m), p, address(0), address(0));
            sumPrincipal += p;
            if (mode == 0 && p > v) expected += p - v;
            if (mode == 0) lossOnlyFromReadable += p;
        }
        assertEq(h.fundedLength(), n);
        uint256 loss_ = h.loss();
        assertEq(loss_, expected, "loss = sum of shortfalls of readable adapters");
        assertLe(loss_, sumPrincipal, "loss never exceeds sum of principals");
        assertLe(loss_, lossOnlyFromReadable);
    }

    function testFuzz_GainsNeverOffsetLoss(uint256 pLoss, uint256 vLoss, uint256 pGain, uint256 extraGain) public {
        pLoss = bound(pLoss, 2, 2 ** 100);
        vLoss = bound(vLoss, 0, pLoss - 1);
        pGain = bound(pGain, 1, 2 ** 100);
        extraGain = bound(extraGain, 1, 2 ** 100);
        MockValueAdapter a = _adapter(0, vLoss);
        MockValueAdapter b = _adapter(0, pGain + extraGain);
        h.book(address(a), pLoss, address(0), address(0));
        h.book(address(b), pGain, address(0), address(0));
        assertEq(h.loss(), pLoss - vLoss, "gain on b does not reduce loss on a");
    }

    function testFuzz_AllGainsMeansZeroLoss(uint256 seed, uint8 count) public {
        uint256 n = bound(count, 1, ShariahAccountingLogic.MAX_FUNDED_ADAPTERS);
        for (uint256 i; i < n; ++i) {
            uint256 p = bound(uint256(keccak256(abi.encode(seed, i, "p"))), 1, 2 ** 100);
            uint256 extra = bound(uint256(keccak256(abi.encode(seed, i, "e"))), 0, 2 ** 100);
            h.book(address(_adapter(0, p + extra)), p, address(0), address(0));
        }
        assertEq(h.loss(), 0);
        assertTrue(h.healthy(address(0), address(0)));
    }
}
