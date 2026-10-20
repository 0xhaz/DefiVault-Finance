// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CommodityMurabahaAdapter} from "../adapters/CommodityMurabahaAdapter.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";

contract FuzzCommodityMurabaha is Test {
    MockERC20 internal usdc;
    CommodityMurabahaAdapter internal adapter;

    address internal owner = makeAddr("owner");
    address internal vault = makeAddr("vault");
    address internal alice = makeAddr("alice");

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);
        vm.prank(owner);
        adapter = new CommodityMurabahaAdapter(address(usdc), vault, owner);
    }

    // -----------------------------------------------------------------------
    // Fuzz: salePrice = costAmount + (costAmount * markupBps / 10_000) — no overflow
    // -----------------------------------------------------------------------
    function testFuzz_salePrice_math(uint64 amount_, uint16 markupBps_) public {
        // Minimum amount=10_000e6 so that even 1 bps markup produces at least 1 unit of profit
        // (1 bps of 10_000e6 = 1_000_000 which rounds to 1_000_000 > 0)
        uint256 amount    = bound(amount_,    10_000e6, 100_000_000e6);
        uint256 markupBps = bound(markupBps_, 1, 5_000);

        uint256 tradeId = adapter.requestMurabaha(alice, amount, markupBps, 7 days);

        (,, uint256 costAmount,, uint256 salePrice,,,,, ) = adapter.trades(tradeId);

        uint256 expectedSalePrice = amount + (amount * markupBps) / 10_000;
        assertEq(salePrice, expectedSalePrice, "salePrice must match formula");
        assertEq(costAmount, amount);
        assertGt(salePrice, costAmount, "salePrice must exceed costAmount");
    }

    // -----------------------------------------------------------------------
    // Fuzz: markup boundaries — [1, 5000] always succeed; 0 and >5000 revert
    // -----------------------------------------------------------------------
    function testFuzz_markup_boundary(uint16 markup) public {
        if (markup == 0 || markup > 5_000) {
            vm.expectRevert(CommodityMurabahaAdapter.InvalidMarkup.selector);
            adapter.requestMurabaha(alice, 1_000e6, markup, 7 days);
        } else {
            uint256 id = adapter.requestMurabaha(alice, 1_000e6, markup, 7 days);
            assertGt(id, 0);
        }
    }

    // -----------------------------------------------------------------------
    // Fuzz: settlement window stored as deadline = block.timestamp + window
    // -----------------------------------------------------------------------
    function testFuzz_deadline_stored_correctly(uint32 window) public {
        window = uint32(bound(window, 1, 365 days));
        uint256 before = block.timestamp;

        uint256 tradeId = adapter.requestMurabaha(alice, 1_000e6, 200, window);

        (,,,,,,,, uint256 deadline,) = adapter.trades(tradeId);
        assertEq(deadline, before + window, "deadline must be timestamp + window");
    }

    // -----------------------------------------------------------------------
    // Fuzz: expired trade can always be expired after deadline
    // -----------------------------------------------------------------------
    function testFuzz_expire_always_works_after_deadline(uint32 window, uint32 extra) public {
        window = uint32(bound(window, 1, 30 days));
        extra  = uint32(bound(extra,  1, 30 days));

        uint256 tradeId = adapter.requestMurabaha(alice, 1_000e6, 200, window);

        skip(uint256(window) + extra);

        vm.prank(owner);
        adapter.expireTrade(tradeId);

        (,,,,,,,,, CommodityMurabahaAdapter.TradeStatus status) = adapter.trades(tradeId);
        assertEq(uint8(status), uint8(CommodityMurabahaAdapter.TradeStatus.EXPIRED));
    }

    // -----------------------------------------------------------------------
    // Fuzz: non-buyer can never settle
    // -----------------------------------------------------------------------
    function testFuzz_only_buyer_settles(address nonBuyer) public {
        vm.assume(nonBuyer != alice && nonBuyer != address(0));

        uint256 tradeId = adapter.requestMurabaha(alice, 1_000e6, 200, 7 days);
        vm.prank(owner);
        adapter.executeMurabaha(tradeId);

        vm.prank(nonBuyer);
        vm.expectRevert(CommodityMurabahaAdapter.BuyerOnly.selector);
        adapter.settleMurabaha(tradeId);
    }

    // -----------------------------------------------------------------------
    // Fuzz: full happy-path settle — vault receives exact salePrice, profit exact
    // -----------------------------------------------------------------------
    function testFuzz_settle_full_roundtrip(uint64 amount_, uint16 markupBps_) public {
        uint256 amount    = bound(amount_,    1_000e6, 10_000_000e6);
        uint256 markupBps = bound(markupBps_, 1, 5_000);

        uint256 salePrice = amount + (amount * markupBps) / 10_000;
        uint256 profit    = salePrice - amount;

        uint256 tradeId = adapter.requestMurabaha(alice, amount, markupBps, 7 days);
        vm.prank(owner);
        adapter.executeMurabaha(tradeId);

        usdc.mint(alice, salePrice);
        vm.prank(alice);
        usdc.approve(address(adapter), salePrice);
        vm.prank(alice);
        adapter.settleMurabaha(tradeId);

        assertEq(usdc.balanceOf(vault), salePrice, "vault must receive full salePrice");
        assertEq(adapter.totalProfitRealized(), profit, "profit must match markup amount");
        assertEq(adapter.totalDeployed(), 0, "totalDeployed must be 0 after settle");
    }

    // -----------------------------------------------------------------------
    // Fuzz: activeTrades.length never exceeds MAX_ACTIVE_TRADES
    // -----------------------------------------------------------------------
    function testFuzz_active_trades_capped(uint8 n) public {
        // Fill to max (50), then verify 51st reverts
        n = uint8(bound(n, 1, 50));
        for (uint256 i = 0; i < n; i++) {
            adapter.requestMurabaha(alice, 1_000e6, 200, 7 days);
        }
        assertLe(adapter.getActiveTrades().length, 50, "active trades must not exceed 50");
    }

    // -----------------------------------------------------------------------
    // Fuzz: deploy + recall roundtrip — totalDeployed always returns to 0
    // -----------------------------------------------------------------------
    function testFuzz_deploy_recall_roundtrip(uint64 amount_) public {
        uint256 amount = bound(amount_, 1e6, 10_000_000e6);

        usdc.mint(vault, amount);

        vm.prank(vault);
        adapter.deploy(amount);
        assertEq(adapter.totalDeployed(), amount);

        // Give adapter the USDC to recall
        usdc.mint(address(adapter), amount);
        vm.prank(vault);
        adapter.recall(amount);

        assertEq(adapter.totalDeployed(), 0, "totalDeployed must be 0 after full recall");
        assertEq(usdc.balanceOf(vault), amount * 2, "vault gets original + recalled");
    }

    // -----------------------------------------------------------------------
    // Invariant: tradeCount monotonically increases, never resets
    // -----------------------------------------------------------------------
    function testFuzz_tradeCount_monotonic(uint8 n) public {
        n = uint8(bound(n, 1, 20));
        for (uint8 i = 0; i < n; i++) {
            adapter.requestMurabaha(alice, 1_000e6, 200, 7 days);
        }
        assertEq(adapter.tradeCount(), n, "tradeCount must equal total requests");
    }
}
