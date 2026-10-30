// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ShariahVault} from "../ShariahVault.sol";
import {PurificationEscrow} from "../PurificationEscrow.sol";
import {TreasuryModule} from "../TreasuryModule.sol";
import {TaskN29Base, TaskN29V1Mixin, TaskN29V2Mixin, IHookTargetN29, HookTokenN29} from "./TaskN29Test.Base.t.sol";

/// @dev Shareholder + manager + charity wallet that tries every vault entry point from inside callbacks.
contract ReentrantN29 is IHookTargetN29 {
    ShariahVault public vault;
    HookTokenN29 public usdc;
    bool public armed;
    bool private busy;
    uint256 public callbacks;
    uint256 public attempts;
    uint256 public succeeded;
    bytes4 public depositErr;
    bytes4 public claimErr;
    bytes4 public redeemErr;
    bytes4 public exitSettleErr;

    constructor(ShariahVault v, HookTokenN29 t) {
        vault = v;
        usdc = t;
        t.approve(address(v), type(uint256).max);
    }

    function arm(bool a) external {
        armed = a;
    }

    function deposit(uint256 amt) external {
        vault.deposit(amt, address(this));
    }

    function redeemAll() external returns (uint256) {
        return vault.redeem(vault.balanceOf(address(this)), address(this), address(this));
    }

    function withdrawAssets(uint256 assets) external returns (uint256) {
        return vault.withdraw(assets, address(this), address(this));
    }

    function _try(bytes memory data) private returns (bytes4 err) {
        ++attempts;
        (bool ok, bytes memory ret) = address(vault).call(data);
        if (ok) ++succeeded;
        else if (ret.length >= 4) err = bytes4(ret);
    }

    function onTokenReceived() external {
        ++callbacks;
        if (!armed || busy) return;
        busy = true;
        uint256 sh = vault.balanceOf(address(this));
        // First observed error wins: later callbacks (e.g. the payout, after the burn) may fail earlier checks.
        bytes4 e;
        e = _try(abi.encodeCall(vault.deposit, (1e6, address(this))));
        if (depositErr == 0) depositErr = e;
        _try(abi.encodeCall(vault.mint, (1e9, address(this))));
        e = _try(abi.encodeCall(vault.claimMusharakahProfit, (1)));
        if (claimErr == 0) claimErr = e;
        e = _try(abi.encodeCall(vault.redeem, (sh / 2 + 1, address(this), address(this))));
        if (redeemErr == 0) redeemErr = e;
        _try(abi.encodeCall(vault.withdraw, (1e6, address(this), address(this))));
        _try(abi.encodeCall(vault.lockProfit, (1)));
        e = _try(abi.encodeCall(vault.exitSettle, (1e6)));
        if (exitSettleErr == 0) exitSettleErr = e;
        busy = false;
    }
}

/// @dev Charity stub that calls back into the attacker mid-distribution, then pays like the real module.
contract CallbackCharityN29 {
    using SafeERC20 for IERC20;

    address public charityWallet;
    IERC20 public token;
    IHookTargetN29 public target;
    uint256 public totalCharityDistributed;

    constructor(address wallet, IERC20 t, IHookTargetN29 target_) {
        charityWallet = wallet;
        token = t;
        target = target_;
    }

    function charityBps() external pure returns (uint256) {
        return 250;
    }

    function distributeCharity(uint256 g) external returns (uint256 c, uint256 remaining) {
        target.onTokenReceived();
        c = (g * 250) / 10_000;
        remaining = g - c;
        if (c > 0) token.safeTransferFrom(msg.sender, charityWallet, c);
        totalCharityDistributed += c;
    }
}

/// @dev N-29: the distribution lock stops re-entry through token hooks and charity callbacks.
abstract contract TaskN29Reentry is TaskN29Base {
    ReentrantN29 internal atk;

    function _initAttacker() internal {
        atk = new ReentrantN29(vault, usdc);
        usdc.mint(address(atk), 10_000e6);
        vm.prank(owner);
        vault.setManager(address(atk));
        atk.deposit(DEP);
    }

    /// @dev Route the charity wallet to the attacker through the real board timelock.
    function _attackerIsCharityWallet() internal {
        vm.prank(owner);
        charity.proposeCharityWalletChange(address(atk));
        skip(30 days + 1);
        vm.prank(owner);
        charity.confirmCharityWalletChange();
        usdc.setHookTarget(address(atk));
    }

    function _assertAllAttemptsBlocked() internal view {
        assertGt(atk.callbacks(), 0, "hook actually fired");
        assertGt(atk.attempts(), 0, "attacker actually tried");
        assertEq(atk.succeeded(), 0, "no re-entrant call succeeded");
        assertEq(atk.depositErr(), ShariahVault.AdapterExecutionReentered.selector, "deposit blocked by lock");
        assertEq(atk.claimErr(), ShariahVault.AdapterExecutionReentered.selector, "claim blocked by lock");
        assertEq(atk.redeemErr(), ShariahVault.AdapterExecutionReentered.selector, "nested exit blocked by lock");
    }

    // ───────────── token hook on the charity transfer / payout ─────────────

    function test_reentry_attackerExit_hookOnCharityAndPayout() public {
        _attackerIsCharityWallet();
        _yield(200e6);
        atk.arm(true);
        uint256 shares = vault.balanceOf(address(atk));
        uint256 g = (vault.realizedProfit() * shares) / vault.totalSupply();
        uint256 charityBefore = charity.totalCharityDistributed();
        uint256 feesBefore = treasury.pendingFees();
        atk.redeemAll();
        _assertAllAttemptsBlocked();
        assertEq(charity.totalCharityDistributed() - charityBefore, (g * 250) / 10_000, "exactly one charity cut");
        assertGt(treasury.pendingFees() - feesBefore, 0);
        assertEq(vault.balanceOf(address(atk)), 0);
    }

    function test_reentry_honestExit_attackerIsCharityWallet() public {
        _attackerIsCharityWallet();
        _yield(200e6);
        atk.arm(true);
        uint256 bobShares = vault.balanceOf(bob);
        uint256 quote = vault.previewRedeem(bobShares);
        uint256 bal = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.redeem(bobShares, bob, bob);
        _assertAllAttemptsBlocked();
        assertEq(usdc.balanceOf(bob) - bal, quote);
    }

    function test_reentry_duringOrdinaryClaim() public {
        _attackerIsCharityWallet();
        _yield(200e6);
        atk.arm(true);
        _claimAll();
        _assertAllAttemptsBlocked();
        assertEq(vault.realizedProfit(), 0);
    }

    function test_reentry_noDoubleDistribution_vsUnarmedBaseline() public {
        _attackerIsCharityWallet();
        _yield(200e6);
        uint256 snap = vm.snapshotState();

        atk.arm(true);
        atk.redeemAll();
        _claimAll();
        uint256 ctrArmed = charity.totalCharityDistributed();
        uint256 feesArmed = treasury.pendingFees();
        uint256 supplyArmed = vault.totalSupply();
        assertEq(atk.succeeded(), 0);

        vm.revertToState(snap);
        atk.arm(false);
        atk.redeemAll();
        _claimAll();
        assertEq(charity.totalCharityDistributed(), ctrArmed, "charity paid identically");
        assertEq(treasury.pendingFees(), feesArmed, "fees booked identically");
        assertEq(vault.totalSupply(), supplyArmed);
    }

    function test_reentry_lockReleasedAfterExit() public {
        _attackerIsCharityWallet();
        _yield(200e6);
        atk.arm(true);
        atk.redeemAll();
        atk.arm(false);
        vm.prank(carol);
        vault.deposit(10e6, carol); // not stuck behind the lock
        _claimAll(); // claim path usable afterwards
        _redeemFrac(bob, 1, 1);
    }

    function test_reentry_withdrawPath() public {
        _attackerIsCharityWallet();
        _yield(200e6);
        atk.arm(true);
        atk.withdrawAssets(vault.maxWithdraw(address(atk)) / 2);
        _assertAllAttemptsBlocked();
    }

    // ───────────── charity module callback mid-settlement ─────────────

    function _useCallbackCharity() internal returns (CallbackCharityN29 cc) {
        cc = new CallbackCharityN29(charityWallet, IERC20(address(usdc)), IHookTargetN29(address(atk)));
        PurificationEscrow e = new PurificationEscrow(
            address(vault), address(usdc), address(cc), address(treasury), owner, address(reg)
        );
        vm.startPrank(address(vault));
        treasury.setProfitRecorder(address(e));
        vm.stopPrank();
        vm.prank(owner);
        vault.setPurificationEscrow(address(e));
    }

    function test_reentry_charityCallback_duringExit() public {
        CallbackCharityN29 cc = _useCallbackCharity();
        _yield(200e6);
        atk.arm(true);
        uint256 bobShares = vault.balanceOf(bob);
        uint256 g = (vault.realizedProfit() * bobShares) / vault.totalSupply();
        vm.prank(bob);
        vault.redeem(bobShares, bob, bob);
        _assertAllAttemptsBlocked();
        assertEq(cc.totalCharityDistributed(), (g * 250) / 10_000, "single settlement only");
    }

    function test_reentry_charityCallback_duringClaim() public {
        CallbackCharityN29 cc = _useCallbackCharity();
        _yield(200e6);
        atk.arm(true);
        uint256 g = vault.realizedProfit();
        _claim(g);
        _assertAllAttemptsBlocked();
        assertEq(cc.totalCharityDistributed(), (g * 250) / 10_000);
    }
}

contract TaskN29ReentryV1Test is TaskN29Reentry, TaskN29V1Mixin {
    function setUp() public override {
        super.setUp();
        _initAttacker();
    }
}

contract TaskN29ReentryV2Test is TaskN29Reentry, TaskN29V2Mixin {
    function setUp() public override {
        super.setUp();
        _initAttacker();
    }
}
