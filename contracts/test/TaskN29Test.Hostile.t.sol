// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AutonomousVault} from "../AutonomousVault.sol";
import {ShariahVault} from "../ShariahVault.sol";
import {PurificationEscrow} from "../PurificationEscrow.sol";
import {TaskN29Base, TaskN29V1Mixin, TaskN29V2Mixin} from "./TaskN29Test.Base.t.sol";

/// @dev Escrow stub: configurable preview and execution failure modes.
contract HostileEscrowN29 {
    enum Preview { Valid, Revert, Burn, Short, Long, BadSum, Overflow }
    enum Exec { Revert, Burn, Short }

    Preview public previewMode;
    Exec public execMode;

    function set(Preview p, Exec e) external {
        previewMode = p;
        execMode = e;
    }

    function previewWaterfallHWM(uint256 g, uint256, uint256, uint256)
        external
        view
        returns (uint256, uint256, uint256, uint256)
    {
        Preview m = previewMode;
        if (m == Preview.Revert) revert("hostile preview");
        if (m == Preview.Burn) {
            assembly { for {} 1 {} {} }
        }
        if (m == Preview.Short) {
            assembly { return(0, 64) }
        }
        if (m == Preview.Long) {
            assembly { return(0, 4096) }
        }
        if (m == Preview.BadSum) return (g, g, g, g);
        if (m == Preview.Overflow) return (type(uint256).max, type(uint256).max, 0, 0);
        uint256 charity = (g * 250) / 10_000;
        uint256 vaultShare = (g * 1000) / 10_000;
        return (0, charity, vaultShare, g - charity - vaultShare);
    }

    function executeWaterfallHWM(uint256, uint256, uint256, uint256) external view returns (uint256, uint256, uint256, uint256) {
        if (execMode == Exec.Revert) revert("hostile exec");
        if (execMode == Exec.Burn) {
            assembly { for {} 1 {} {} }
        }
        assembly { return(0, 1) }
    }

    function shariahTreasury() external pure returns (address) {
        return address(0);
    }
}

/// @dev Charity stub: reads like the real module, but distribution can revert or burn all gas.
contract HostileCharityN29 {
    using SafeERC20 for IERC20;

    enum Mode { Ok, Revert, Burn }
    Mode public mode;
    address public charityWallet;
    IERC20 public token;

    constructor(address wallet, IERC20 token_) {
        charityWallet = wallet;
        token = token_;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function charityBps() external pure returns (uint256) {
        return 250;
    }

    function distributeCharity(uint256 g) external returns (uint256 c, uint256 remaining) {
        if (mode == Mode.Revert) revert("hostile charity");
        if (mode == Mode.Burn) {
            assembly { for {} 1 {} {} }
        }
        c = (g * 250) / 10_000;
        remaining = g - c;
        if (c > 0) token.safeTransferFrom(msg.sender, charityWallet, c);
    }
}

/// @dev Treasury stub: same split maths as the real module, hostile booking.
contract HostileTreasuryN29 {
    enum Mode { Ok, Revert, Burn }
    Mode public mode;

    function setMode(Mode m) external {
        mode = m;
    }

    function hurdleRateBps() external pure returns (uint256) {
        return 400;
    }

    function calculateMusharakahSplitHWM(uint256 gross, uint256 elapsed, uint256 principal, uint256 deficit)
        external
        pure
        returns (uint256 hurdle, uint256 vaultShare, uint256 depositorShare)
    {
        hurdle = (principal * 400 * elapsed) / (10_000 * 365 days);
        uint256 afterRecovery = gross > deficit ? gross - deficit : 0;
        uint256 surplus = afterRecovery > hurdle ? afterRecovery - hurdle : 0;
        vaultShare = (surplus * 1000) / 10_000;
        depositorShare = gross - vaultShare;
    }

    function recordMusharakahProfit(uint256) external view {
        if (mode == Mode.Revert) revert("hostile treasury");
        if (mode == Mode.Burn) {
            assembly { for {} 1 {} {} }
        }
    }
}

/// @dev N-29: exits, conversions and previews are never gated by hostile distribution dependencies.
abstract contract TaskN29Hostile is TaskN29Base {
    using stdStorage for StdStorage;

    uint256 internal constant EXIT_GAS = 8_000_000;

    HostileEscrowN29 internal stubEscrow;

    function _useStub(HostileEscrowN29.Preview p, HostileEscrowN29.Exec e) internal {
        stubEscrow = new HostileEscrowN29();
        stubEscrow.set(p, e);
        vm.prank(owner);
        vault.setPurificationEscrow(address(stubEscrow));
    }

    /// @dev Nothing in the read surface may revert, and a hostile preview reserves nothing.
    function _assertReadSurfaceOpen() internal {
        uint256 gasBefore = gasleft();
        uint256 ta = vault.totalAssets();
        assertLt(gasBefore - gasleft(), 2_000_000, "preview gas is bounded");
        assertEq(ta, vault.totalAssetsBeforeDistributionCut(), "failed preview reserves nothing");
        assertEq(vault.pendingDistributionCut(), 0);
        vault.convertToAssets(1e15);
        vault.convertToShares(1e9);
        vault.previewDeposit(1e9);
        vault.previewMint(1e15);
        vault.previewRedeem(1e15);
        vault.previewWithdraw(1e6);
        vault.maxWithdraw(bob);
        vault.maxRedeem(bob);
        vault.realizedProfit();
        vault.hwmDeficit();
        vault.highWaterMark();
    }

    function _assertExitsWork() internal {
        uint256 shares = vault.balanceOf(bob);
        uint256 quote = vault.previewRedeem(shares / 2);
        uint256 bal = usdc.balanceOf(bob);
        vm.prank(bob);
        uint256 out = vault.redeem{gas: EXIT_GAS}(shares / 2, bob, bob);
        assertEq(out, quote, "payout unchanged");
        assertEq(usdc.balanceOf(bob) - bal, quote);
        // withdraw path
        uint256 want = vault.previewRedeem(vault.balanceOf(bob));
        vm.prank(bob);
        vault.withdraw{gas: EXIT_GAS}(want, bob, bob);
        assertLe(vault.balanceOf(bob), 1e6, "at most sub-wei share dust left");
        // entry still works
        vm.prank(carol);
        vault.deposit{gas: EXIT_GAS}(100e6, carol);
        assertEq(_distributed(), 0, "nothing was distributed");
    }

    // ───────────── escrow unset / zero profit ─────────────

    function test_escrowUnset_cutZero_exitsAndConversionsWork() public {
        vm.prank(owner);
        vault.setPurificationEscrow(address(0));
        _yield(200e6);
        _assertReadSurfaceOpen();
        _assertExitsWork();
    }

    function test_realizedProfitZero_cutZero_exitsWork() public {
        skip(30 days);
        assertEq(vault.realizedProfit(), 0);
        assertEq(vault.pendingDistributionCut(), 0);
        assertEq(vault.totalAssets(), vault.totalAssetsBeforeDistributionCut());
        vault.convertToAssets(1e15);
        _assertExitsWork();
    }

    function test_hurdleStartInFuture_cutZero() public {
        _yield(200e6);
        vm.store(address(vault), bytes32(stdStoreSlot("hurdleStartTime()")), bytes32(block.timestamp + 1 days));
        assertEq(vault.pendingDistributionCut(), 0);
        vault.totalAssets();
        _redeemFrac(bob, 1, 1);
    }

    function stdStoreSlot(string memory sig) internal returns (uint256) {
        return stdstore.target(address(vault)).sig(sig).find();
    }

    // ───────────── hostile escrow previews ─────────────

    function test_hostilePreview_revert() public {
        _useStub(HostileEscrowN29.Preview.Revert, HostileEscrowN29.Exec.Revert);
        _yield(200e6);
        _assertReadSurfaceOpen();
        _assertExitsWork();
    }

    function test_hostilePreview_gasBurn() public {
        _useStub(HostileEscrowN29.Preview.Burn, HostileEscrowN29.Exec.Burn);
        _yield(200e6);
        _assertReadSurfaceOpen();
        _assertExitsWork();
    }

    function test_hostilePreview_shortReturndata() public {
        _useStub(HostileEscrowN29.Preview.Short, HostileEscrowN29.Exec.Short);
        _yield(200e6);
        _assertReadSurfaceOpen();
        _assertExitsWork();
    }

    function test_hostilePreview_oversizedReturndata() public {
        _useStub(HostileEscrowN29.Preview.Long, HostileEscrowN29.Exec.Short);
        _yield(200e6);
        _assertReadSurfaceOpen();
        _assertExitsWork();
    }

    function test_hostilePreview_inconsistentSplit() public {
        _useStub(HostileEscrowN29.Preview.BadSum, HostileEscrowN29.Exec.Revert);
        _yield(200e6);
        _assertReadSurfaceOpen();
        _assertExitsWork();
    }

    function test_hostilePreview_overflowingSplit() public {
        _useStub(HostileEscrowN29.Preview.Overflow, HostileEscrowN29.Exec.Revert);
        _yield(200e6);
        _assertReadSurfaceOpen();
        _assertExitsWork();
    }

    function test_noEscrowCode_cutZero() public {
        vm.prank(owner);
        vault.setPurificationEscrow(makeAddr("eoa"));
        _yield(200e6);
        _assertReadSurfaceOpen();
        _assertExitsWork();
    }

    // ───────────── valid preview, failing settlement → fallback ─────────────

    function _assertFallbackExit(string memory why) internal {
        uint256 cut = vault.pendingDistributionCut();
        assertGt(cut, 0, "preview reserves a cut");
        uint256 shares = vault.balanceOf(bob);
        uint256 quote = vault.previewRedeem(shares);
        uint256 bal = usdc.balanceOf(bob);
        uint256 vaultBal = usdc.balanceOf(address(vault));
        uint256 supply = vault.totalSupply();
        vm.prank(bob);
        uint256 out = vault.redeem{gas: EXIT_GAS}(shares, bob, bob);
        assertEq(out, quote, why);
        assertEq(usdc.balanceOf(bob) - bal, quote, "payout unchanged");
        assertEq(vaultBal - usdc.balanceOf(address(vault)), quote, "settlement rolled back entirely");
        assertEq(supply - vault.totalSupply(), shares, "shares burned in full");
        assertEq(_distributed(), 0, "no partial distribution");
        assertEq(usdc.allowance(address(vault), address(vault.purificationEscrow())), 0, "approval rolled back");
        assertEq(usdc.balanceOf(address(vault.purificationEscrow())), 0, "no tokens stranded in escrow");
        // withdraw path and remaining holder can still exit
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem{gas: EXIT_GAS}(aliceShares, alice, alice);
        assertEq(vault.totalSupply(), 0);
    }

    function test_settlementFailure_stubExecRevert() public {
        _useStub(HostileEscrowN29.Preview.Valid, HostileEscrowN29.Exec.Revert);
        _yield(200e6);
        _assertFallbackExit("exec revert");
    }

    function test_settlementFailure_stubExecGasBurn() public {
        _useStub(HostileEscrowN29.Preview.Valid, HostileEscrowN29.Exec.Burn);
        _yield(200e6);
        _assertFallbackExit("exec gas burn");
    }

    function test_settlementFailure_stubExecMalformedReturn() public {
        _useStub(HostileEscrowN29.Preview.Valid, HostileEscrowN29.Exec.Short);
        _yield(200e6);
        _assertFallbackExit("exec malformed returndata");
    }

    function _useHostileCharity(HostileCharityN29.Mode m) internal {
        HostileCharityN29 hc = new HostileCharityN29(charityWallet, IERC20(address(usdc)));
        hc.setMode(m);
        HostileTreasuryN29 ht = new HostileTreasuryN29();
        PurificationEscrow e = new PurificationEscrow(
            address(vault), address(usdc), address(hc), address(ht), owner, address(reg)
        );
        vm.prank(owner);
        vault.setPurificationEscrow(address(e));
    }

    function _useHostileTreasury(HostileTreasuryN29.Mode m) internal {
        HostileCharityN29 hc = new HostileCharityN29(charityWallet, IERC20(address(usdc)));
        HostileTreasuryN29 ht = new HostileTreasuryN29();
        ht.setMode(m);
        PurificationEscrow e = new PurificationEscrow(
            address(vault), address(usdc), address(hc), address(ht), owner, address(reg)
        );
        vm.prank(owner);
        vault.setPurificationEscrow(address(e));
    }

    function test_settlementFailure_charityReverts_exitFallsBack() public {
        _useHostileCharity(HostileCharityN29.Mode.Revert);
        _yield(200e6);
        _assertFallbackExit("charity revert");
    }

    function test_settlementFailure_charityGasBurn_exitFallsBack() public {
        _useHostileCharity(HostileCharityN29.Mode.Burn);
        _yield(200e6);
        _assertFallbackExit("charity gas burn");
    }

    function test_settlementFailure_treasuryReverts_exitFallsBack() public {
        _useHostileTreasury(HostileTreasuryN29.Mode.Revert);
        _yield(200e6);
        _assertFallbackExit("treasury revert");
    }

    function test_settlementFailure_treasuryGasBurn_exitFallsBack() public {
        _useHostileTreasury(HostileTreasuryN29.Mode.Burn);
        _yield(200e6);
        _assertFallbackExit("treasury gas burn");
    }

    function test_settlementFailure_withdrawPathFallsBack() public {
        _useHostileCharity(HostileCharityN29.Mode.Revert);
        _yield(200e6);
        uint256 assets = vault.previewRedeem(vault.balanceOf(bob) / 3);
        uint256 bal = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.withdraw{gas: EXIT_GAS}(assets, bob, bob);
        assertEq(usdc.balanceOf(bob) - bal, assets);
        assertEq(_distributed(), 0);
    }

    function test_healthyHostileStubs_behaveLikeRealSettlement() public {
        // Control: the same stub wiring with benign modes settles through the real exit path.
        HostileCharityN29 hc = new HostileCharityN29(charityWallet, IERC20(address(usdc)));
        HostileTreasuryN29 ht = new HostileTreasuryN29();
        PurificationEscrow e = new PurificationEscrow(
            address(vault), address(usdc), address(hc), address(ht), owner, address(reg)
        );
        vm.prank(owner);
        vault.setPurificationEscrow(address(e));
        _yield(200e6);
        uint256 walletBefore = usdc.balanceOf(charityWallet);
        _redeemFrac(bob, 1, 1);
        assertGt(usdc.balanceOf(charityWallet), walletBefore, "benign settlement does distribute");
    }
}

contract TaskN29HostileV1Test is TaskN29Hostile, TaskN29V1Mixin {}

contract TaskN29HostileV2Test is TaskN29Hostile, TaskN29V2Mixin {}
