// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ZakatModule} from "../ZakatModule.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";

contract FuzzZakatModule is Test {
    MockERC20 internal usdc;
    ZakatModule internal zakatModule;

    address internal owner        = makeAddr("owner");
    address internal charityWallet = makeAddr("charity");
    // The test contract itself is the vault
    address internal vault;

    function setUp() public {
        vault = address(this);
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);
        vm.prank(owner);
        zakatModule = new ZakatModule(charityWallet, address(usdc), vault, owner);
    }

    function _fund(uint256 amount) internal {
        usdc.mint(vault, amount);
        usdc.approve(address(zakatModule), amount);
    }

    // -----------------------------------------------------------------------
    // Fuzz: zakat amount is always exactly 2.5% of grossProfit
    // -----------------------------------------------------------------------
    function testFuzz_zakat_amount_exact(uint96 grossProfit_) public {
        uint256 grossProfit = bound(grossProfit_, 1, 1_000_000_000e6);
        _fund(grossProfit);

        (uint256 zakatAmount, uint256 remaining) = zakatModule.distributeZakat(grossProfit);

        uint256 expectedZakat = (grossProfit * 250) / 10_000;
        assertEq(zakatAmount, expectedZakat, "zakat must be exactly 2.5%");
        assertEq(remaining, grossProfit - expectedZakat, "remaining must be grossProfit - zakat");
        assertEq(zakatAmount + remaining, grossProfit, "zakat + remaining must equal gross");
    }

    // -----------------------------------------------------------------------
    // Fuzz: charity wallet receives exact zakat amount
    // -----------------------------------------------------------------------
    function testFuzz_charity_receives_correct_amount(uint96 grossProfit_) public {
        uint256 grossProfit = bound(grossProfit_, 1, 100_000_000e6);
        _fund(grossProfit);

        uint256 beforeBalance = usdc.balanceOf(charityWallet);
        (uint256 zakatAmount,) = zakatModule.distributeZakat(grossProfit);

        assertEq(
            usdc.balanceOf(charityWallet) - beforeBalance,
            zakatAmount,
            "charity balance delta must equal zakatAmount"
        );
    }

    // -----------------------------------------------------------------------
    // Fuzz: totalZakatDistributed accumulates correctly across N calls
    // -----------------------------------------------------------------------
    function testFuzz_totalZakat_accumulates(uint64 a, uint64 b, uint64 c) public {
        uint256 g1 = bound(a, 1, 1_000_000e6);
        uint256 g2 = bound(b, 1, 1_000_000e6);
        uint256 g3 = bound(c, 1, 1_000_000e6);
        uint256 totalGross = g1 + g2 + g3;

        _fund(totalGross);
        // Need to approve in batches since _fund sets one approval
        usdc.approve(address(zakatModule), totalGross);

        zakatModule.distributeZakat(g1);
        zakatModule.distributeZakat(g2);
        zakatModule.distributeZakat(g3);

        uint256 expectedTotal = (g1 * 250 / 10_000) + (g2 * 250 / 10_000) + (g3 * 250 / 10_000);
        // allow off-by-one rounding across 3 divisions
        assertApproxEqAbs(zakatModule.totalZakatDistributed(), expectedTotal, 3);
    }

    // -----------------------------------------------------------------------
    // Fuzz: non-vault caller always reverts regardless of amount
    // -----------------------------------------------------------------------
    function testFuzz_only_vault_can_distribute(address caller, uint96 amount) public {
        vm.assume(caller != vault && amount > 0);

        vm.prank(caller);
        vm.expectRevert(ZakatModule.NotVault.selector);
        zakatModule.distributeZakat(amount);
    }

    // -----------------------------------------------------------------------
    // Fuzz: zero amount always reverts
    // -----------------------------------------------------------------------
    function testFuzz_zero_amount_always_reverts() public {
        vm.expectRevert(ZakatModule.ZeroAmount.selector);
        zakatModule.distributeZakat(0);
    }

    // -----------------------------------------------------------------------
    // Fuzz: timelock confirmation — elapsed < 30 days always reverts
    // -----------------------------------------------------------------------
    function testFuzz_timelock_not_elapsed(uint32 elapsed) public {
        vm.assume(elapsed < 30 days);

        address newWallet = makeAddr("newWallet");
        vm.prank(owner);
        zakatModule.proposeZakatWalletChange(newWallet);

        skip(elapsed);

        vm.prank(owner);
        vm.expectRevert(); // TimelockNotElapsed
        zakatModule.confirmZakatWalletChange();
    }

    // -----------------------------------------------------------------------
    // Fuzz: timelock confirmation — elapsed ≥ 30 days always succeeds
    // -----------------------------------------------------------------------
    function testFuzz_timelock_elapsed_succeeds(uint32 extra) public {
        extra = uint32(bound(extra, 0, 365 days));
        address newWallet = makeAddr("newWallet");

        vm.prank(owner);
        zakatModule.proposeZakatWalletChange(newWallet);

        skip(30 days + extra);

        vm.prank(owner);
        zakatModule.confirmZakatWalletChange();

        assertEq(zakatModule.zakatWallet(), newWallet);
        assertEq(zakatModule.pendingZakatWallet(), address(0));
    }

    // -----------------------------------------------------------------------
    // Fuzz: propose rejects address(0) always
    // -----------------------------------------------------------------------
    function testFuzz_propose_zero_always_reverts() public {
        vm.prank(owner);
        vm.expectRevert(ZakatModule.ZeroWallet.selector);
        zakatModule.proposeZakatWalletChange(address(0));
    }

    // -----------------------------------------------------------------------
    // Fuzz: cancel clears state regardless of how much time elapsed
    // -----------------------------------------------------------------------
    function testFuzz_cancel_clears_state(uint32 elapsed) public {
        elapsed = uint32(bound(elapsed, 0, 365 days));
        address newWallet = makeAddr("newWallet");

        vm.prank(owner);
        zakatModule.proposeZakatWalletChange(newWallet);
        skip(elapsed);

        vm.prank(owner);
        zakatModule.cancelZakatWalletChange();

        assertEq(zakatModule.pendingZakatWallet(), address(0));
        assertEq(zakatModule.walletChangeRequestTime(), 0);
        // zakatWallet should be unchanged
        assertEq(zakatModule.zakatWallet(), charityWallet);
    }
}
