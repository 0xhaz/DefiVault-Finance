// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CommodityMurabahaAdapter} from "../adapters/CommodityMurabahaAdapter.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";

contract CommodityMurabahaAdapterTest is Test {
    MockERC20 internal usdc;
    CommodityMurabahaAdapter internal adapter;

    address internal owner = makeAddr("owner");
    address internal vault = makeAddr("vault");   // acts as vault for deploy/recall
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal random = makeAddr("random");

    uint256 internal constant SETTLEMENT_WINDOW = 7 days;

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);
        vm.prank(owner);
        adapter = new CommodityMurabahaAdapter(address(usdc), vault, owner);
    }

    // -----------------------------------------------------------------------
    // test_requestMurabaha_basic
    // amount=1000e6, markupBps=200 (2%) → salePrice=1020e6
    // -----------------------------------------------------------------------
    function test_requestMurabaha_basic() public {
        uint256 tradeId = adapter.requestMurabaha(alice, 1_000e6, 200, SETTLEMENT_WINDOW);

        assertEq(tradeId, 1, "first trade id should be 1");

        (
            uint256 id,
            address buyer,
            uint256 costAmount,
            uint256 markupBps,
            uint256 salePrice,
            ,,,
            ,
            CommodityMurabahaAdapter.TradeStatus status
        ) = adapter.trades(tradeId);

        assertEq(id, 1);
        assertEq(buyer, alice);
        assertEq(costAmount, 1_000e6);
        assertEq(markupBps, 200);
        assertEq(salePrice, 1_020e6, "salePrice should be 1020e6");
        assertEq(uint8(status), uint8(CommodityMurabahaAdapter.TradeStatus.PENDING));
    }

    // -----------------------------------------------------------------------
    // test_requestMurabaha_zero_markup_reverts
    // -----------------------------------------------------------------------
    function test_requestMurabaha_zero_markup_reverts() public {
        vm.expectRevert(CommodityMurabahaAdapter.InvalidMarkup.selector);
        adapter.requestMurabaha(alice, 1_000e6, 0, SETTLEMENT_WINDOW);
    }

    // -----------------------------------------------------------------------
    // test_requestMurabaha_over_5000bps_reverts
    // -----------------------------------------------------------------------
    function test_requestMurabaha_over_5000bps_reverts() public {
        vm.expectRevert(CommodityMurabahaAdapter.InvalidMarkup.selector);
        adapter.requestMurabaha(alice, 1_000e6, 5001, SETTLEMENT_WINDOW);
    }

    // -----------------------------------------------------------------------
    // test_requestMurabaha_zero_amount_reverts
    // -----------------------------------------------------------------------
    function test_requestMurabaha_zero_amount_reverts() public {
        vm.expectRevert(CommodityMurabahaAdapter.InvalidAmount.selector);
        adapter.requestMurabaha(alice, 0, 200, SETTLEMENT_WINDOW);
    }

    // -----------------------------------------------------------------------
    // test_executeMurabaha_by_owner
    // -----------------------------------------------------------------------
    function test_executeMurabaha_by_owner() public {
        uint256 tradeId = adapter.requestMurabaha(alice, 1_000e6, 200, SETTLEMENT_WINDOW);

        vm.prank(owner);
        adapter.executeMurabaha(tradeId);

        (,,,,,,uint256 executeTime,,, CommodityMurabahaAdapter.TradeStatus status) = adapter.trades(tradeId);
        assertEq(uint8(status), uint8(CommodityMurabahaAdapter.TradeStatus.EXECUTED));
        assertGt(executeTime, 0);
    }

    // -----------------------------------------------------------------------
    // test_executeMurabaha_wrong_status_reverts (execute twice)
    // -----------------------------------------------------------------------
    function test_executeMurabaha_wrong_status_reverts() public {
        uint256 tradeId = adapter.requestMurabaha(alice, 1_000e6, 200, SETTLEMENT_WINDOW);

        vm.prank(owner);
        adapter.executeMurabaha(tradeId);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                CommodityMurabahaAdapter.InvalidTradeStatus.selector,
                CommodityMurabahaAdapter.TradeStatus.EXECUTED,
                CommodityMurabahaAdapter.TradeStatus.PENDING
            )
        );
        adapter.executeMurabaha(tradeId);
    }

    // -----------------------------------------------------------------------
    // test_settleMurabaha_happy_path
    // -----------------------------------------------------------------------
    function test_settleMurabaha_happy_path() public {
        uint256 tradeId = adapter.requestMurabaha(alice, 1_000e6, 200, SETTLEMENT_WINDOW);

        vm.prank(owner);
        adapter.executeMurabaha(tradeId);

        // Alice approves salePrice (1020e6) and settles
        usdc.mint(alice, 1_020e6);
        vm.prank(alice);
        usdc.approve(address(adapter), 1_020e6);

        vm.prank(alice);
        adapter.settleMurabaha(tradeId);

        (,,,,,,,,, CommodityMurabahaAdapter.TradeStatus status) = adapter.trades(tradeId);
        assertEq(uint8(status), uint8(CommodityMurabahaAdapter.TradeStatus.SETTLED));
        assertEq(usdc.balanceOf(vault), 1_020e6, "vault should receive salePrice");
        assertEq(adapter.totalProfitRealized(), 20e6, "profit should be 20e6");
    }

    // -----------------------------------------------------------------------
    // test_settleMurabaha_non_buyer_reverts
    // -----------------------------------------------------------------------
    function test_settleMurabaha_non_buyer_reverts() public {
        uint256 tradeId = adapter.requestMurabaha(alice, 1_000e6, 200, SETTLEMENT_WINDOW);

        vm.prank(owner);
        adapter.executeMurabaha(tradeId);

        vm.prank(bob);
        vm.expectRevert(CommodityMurabahaAdapter.BuyerOnly.selector);
        adapter.settleMurabaha(tradeId);
    }

    // -----------------------------------------------------------------------
    // test_settleMurabaha_after_deadline_reverts
    // -----------------------------------------------------------------------
    function test_settleMurabaha_after_deadline_reverts() public {
        uint256 tradeId = adapter.requestMurabaha(alice, 1_000e6, 200, SETTLEMENT_WINDOW);

        vm.prank(owner);
        adapter.executeMurabaha(tradeId);

        skip(SETTLEMENT_WINDOW + 1);

        usdc.mint(alice, 1_020e6);
        vm.prank(alice);
        usdc.approve(address(adapter), 1_020e6);

        vm.prank(alice);
        vm.expectRevert(CommodityMurabahaAdapter.DeadlinePassed.selector);
        adapter.settleMurabaha(tradeId);
    }

    // -----------------------------------------------------------------------
    // test_expireTrade_after_deadline
    // -----------------------------------------------------------------------
    function test_expireTrade_after_deadline() public {
        uint256 tradeId = adapter.requestMurabaha(alice, 1_000e6, 200, SETTLEMENT_WINDOW);

        skip(SETTLEMENT_WINDOW + 1);

        vm.prank(owner);
        adapter.expireTrade(tradeId);

        (,,,,,,,,, CommodityMurabahaAdapter.TradeStatus status) = adapter.trades(tradeId);
        assertEq(uint8(status), uint8(CommodityMurabahaAdapter.TradeStatus.EXPIRED));
    }

    // -----------------------------------------------------------------------
    // test_expireTrade_before_deadline_reverts
    // -----------------------------------------------------------------------
    function test_expireTrade_before_deadline_reverts() public {
        uint256 tradeId = adapter.requestMurabaha(alice, 1_000e6, 200, SETTLEMENT_WINDOW);

        vm.prank(owner);
        vm.expectRevert(CommodityMurabahaAdapter.DeadlinePassed.selector);
        adapter.expireTrade(tradeId);
    }

    // -----------------------------------------------------------------------
    // test_max_active_trades_dos_guard — 51st request reverts
    // -----------------------------------------------------------------------
    function test_max_active_trades_dos_guard() public {
        for (uint256 i = 0; i < 50; i++) {
            adapter.requestMurabaha(alice, 1_000e6, 200, SETTLEMENT_WINDOW);
        }

        vm.expectRevert(CommodityMurabahaAdapter.InvalidAmount.selector);
        adapter.requestMurabaha(alice, 1_000e6, 200, SETTLEMENT_WINDOW);
    }

    // -----------------------------------------------------------------------
    // test_active_trade_removal_o1
    // Request and settle two trades, verifying activeTrades stays consistent
    // -----------------------------------------------------------------------
    function test_active_trade_removal_o1() public {
        uint256 id1 = adapter.requestMurabaha(alice, 1_000e6, 200, SETTLEMENT_WINDOW);
        uint256 id2 = adapter.requestMurabaha(bob, 500e6, 100, SETTLEMENT_WINDOW);

        // Execute and settle id1
        vm.prank(owner);
        adapter.executeMurabaha(id1);
        usdc.mint(alice, 1_020e6);
        vm.prank(alice);
        usdc.approve(address(adapter), 1_020e6);
        vm.prank(alice);
        adapter.settleMurabaha(id1);

        // Only id2 should remain active
        CommodityMurabahaAdapter.MurabahaTrade[] memory active = adapter.getActiveTrades();
        assertEq(active.length, 1, "only 1 trade should remain active");
        assertEq(active[0].id, id2, "remaining active trade should be id2");

        // Execute and settle id2
        vm.prank(owner);
        adapter.executeMurabaha(id2);
        usdc.mint(bob, 505e6); // 500e6 * 100/10000 = 5e6 markup
        vm.prank(bob);
        usdc.approve(address(adapter), 505e6);
        vm.prank(bob);
        adapter.settleMurabaha(id2);

        active = adapter.getActiveTrades();
        assertEq(active.length, 0, "no active trades should remain");
    }

    // -----------------------------------------------------------------------
    // test_deploy_and_recall
    // -----------------------------------------------------------------------
    function test_deploy_and_recall() public {
        // Mint USDC to vault so it can transfer to adapter via deploy
        usdc.mint(vault, 500e6);

        // vault calls deploy (adapter just records totalDeployed)
        vm.prank(vault);
        adapter.deploy(500e6);
        assertEq(adapter.totalDeployed(), 500e6, "totalDeployed should be 500e6");

        // Mint the USDC to adapter so recall can actually transfer
        usdc.mint(address(adapter), 500e6);

        vm.prank(vault);
        adapter.recall(500e6);
        assertEq(adapter.totalDeployed(), 0, "totalDeployed should be 0 after recall");
        assertEq(usdc.balanceOf(vault), 1_000e6, "vault should receive recalled USDC (500 original + 500 recalled)");
    }

    // -----------------------------------------------------------------------
    // test_getActiveTrades_returns_correct_list
    // -----------------------------------------------------------------------
    function test_getActiveTrades_returns_correct_list() public {
        uint256 id1 = adapter.requestMurabaha(alice, 1_000e6, 200, SETTLEMENT_WINDOW);
        uint256 id2 = adapter.requestMurabaha(bob, 500e6, 100, SETTLEMENT_WINDOW);
        uint256 id3 = adapter.requestMurabaha(random, 2_000e6, 300, SETTLEMENT_WINDOW);

        CommodityMurabahaAdapter.MurabahaTrade[] memory active = adapter.getActiveTrades();
        assertEq(active.length, 3, "should return 3 active trades");
        assertEq(active[0].id, id1);
        assertEq(active[1].id, id2);
        assertEq(active[2].id, id3);
    }

    // -----------------------------------------------------------------------
    // test_o1_removal_middle_trade — request 3 trades, settle middle one (id=2)
    // After swap-and-pop, activeTrades should contain [1,3] in some order
    // -----------------------------------------------------------------------
    function test_o1_removal_middle_trade() public {
        uint256 id1 = adapter.requestMurabaha(alice, 1_000e6, 200, SETTLEMENT_WINDOW);
        uint256 id2 = adapter.requestMurabaha(bob, 500e6, 100, SETTLEMENT_WINDOW);
        uint256 id3 = adapter.requestMurabaha(random, 2_000e6, 300, SETTLEMENT_WINDOW);

        // Execute id2
        vm.prank(owner);
        adapter.executeMurabaha(id2);

        // Settle id2
        uint256 salePrice2 = 500e6 + (500e6 * 100) / 10_000; // 505e6
        usdc.mint(bob, salePrice2);
        vm.prank(bob);
        usdc.approve(address(adapter), salePrice2);
        vm.prank(bob);
        adapter.settleMurabaha(id2);

        // activeTrades should have 2 elements: id1 and id3
        CommodityMurabahaAdapter.MurabahaTrade[] memory active = adapter.getActiveTrades();
        assertEq(active.length, 2, "two trades should remain");

        bool foundId1;
        bool foundId3;
        for (uint256 i = 0; i < active.length; i++) {
            if (active[i].id == id1) foundId1 = true;
            if (active[i].id == id3) foundId3 = true;
        }
        assertTrue(foundId1, "id1 should still be active");
        assertTrue(foundId3, "id3 should still be active");
    }

    // -----------------------------------------------------------------------
    // test_executeMurabaha_after_deadline_reverts
    // -----------------------------------------------------------------------
    function test_executeMurabaha_after_deadline_reverts() public {
        uint256 tradeId = adapter.requestMurabaha(alice, 1_000e6, 200, SETTLEMENT_WINDOW);

        skip(SETTLEMENT_WINDOW + 1);

        vm.prank(owner);
        vm.expectRevert(CommodityMurabahaAdapter.DeadlinePassed.selector);
        adapter.executeMurabaha(tradeId);
    }

    // -----------------------------------------------------------------------
    // test_markup_boundary — exactly 5000 bps is valid, 5001 reverts
    // -----------------------------------------------------------------------
    function test_markup_boundary() public {
        // 5000 bps should succeed
        uint256 tradeId = adapter.requestMurabaha(alice, 1_000e6, 5000, SETTLEMENT_WINDOW);
        assertEq(tradeId, 1);

        // 5001 bps should revert
        vm.expectRevert(CommodityMurabahaAdapter.InvalidMarkup.selector);
        adapter.requestMurabaha(alice, 1_000e6, 5001, SETTLEMENT_WINDOW);
    }
}
