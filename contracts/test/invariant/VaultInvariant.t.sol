// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {VaultInvariantBase} from "./VaultInvariant.Base.t.sol";
import {VaultHandler}       from "./VaultInvariant.Handler.t.sol";

/// @title  VaultInvariantTest
/// @notice Invariant test suite for ShariahVault.
///
/// PR2 updates:
///   - Invariant 4 REPLACED: "share-price monotone" → "no dilution from other users"
///     (share price CAN fall from gold drops, cross-chain shortfalls, fees, write-offs).
///   - Invariant 7 ADDED: totalPendingCrossChain == Σ open pendingCrossChain[nonce].
///   - Invariant 8 ADDED: cross-chain cap never exceeded after every deploy.
///
/// Run with:
///   forge test --match-path 'contracts/test/invariant/*' --invariant-runs 256 --invariant-depth 50 -vv
contract VaultInvariantTest is VaultInvariantBase {

    VaultHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new VaultHandler(this);
        targetContract(address(handler));
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Invariant 1 — redeem(maxRedeem) never reverts for any actor with shares
    // ══════════════════════════════════════════════════════════════════════════
    function invariant_redeemNeverReverts() public {
        for (uint256 i = 0; i < 3; i++) {
            address actor = actors[i];
            uint256 maxSh = vault.maxRedeem(actor);
            // N-06 prices losses immediately but does not auto-recall: only assert exits covered by idle liquidity.
            uint256 liquidShares = vault.convertToShares(usdc.balanceOf(address(vault)));
            if (maxSh > liquidShares) maxSh = liquidShares;
            if (maxSh == 0) continue;

            uint256 snap = vm.snapshot();
            vm.prank(actor);
            try vault.redeem(maxSh, actor, actor) {
                // success — ok
            } catch (bytes memory err) {
                vm.revertTo(snap);
                bytes memory msg_ = abi.encodePacked(
                    "invariant_redeemNeverReverts: redeem failed for actor ",
                    err
                );
                revert(string(msg_));
            }
            vm.revertTo(snap);
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Invariant 2 — totalAssets accounting is self-consistent
    // ══════════════════════════════════════════════════════════════════════════
    /// @notice N-06 deducts gold writedowns as well as locked profit and fees, within 2 USDC tolerance.
    function invariant_totalAssetsAccounting() public view {
        uint256 idle          = usdc.balanceOf(address(vault));
        uint256 deployed      = vault.totalDeployed();
        uint256 lockedProfitNow = _currentLockedProfitPublic();
        uint256 base          = idle + deployed;
        uint256 writedown     = vault.goldWritedown();
        base = base > writedown ? base - writedown : 0;
        // G-1 includes oracle/cache appreciation in share NAV, never in distributable profit.
        base += vault.goldUnrealizedGain();
        uint256 expected      = base > lockedProfitNow ? base - lockedProfitNow : 0;
        uint256 fees          = treasury.pendingFees();
        expected = expected > fees ? expected - fees : 0;
        // N-20: share NAV includes unbooked time fees even before a state-changing accrual.
        uint256 unbooked = vault.pendingWakalaFee();
        expected = expected > unbooked ? expected - unbooked : 0;
        uint256 actual        = vault.totalAssets();

        uint256 diff = actual > expected ? actual - expected : expected - actual;
        assertLe(diff, 2e6, "totalAssets accounting: deviation > 2 USDC");
    }

    // G-1 allows marked NAV above cost but never distributes unrealized appreciation.
    function invariant_unrealizedGainsNeverDistributable() public view {
        uint256 cost = usdc.balanceOf(address(vault)) + vault.totalDeployed();
        uint256 deductions = _currentLockedProfitPublic() + treasury.pendingFees() + vault.profitBase();
        uint256 available = cost > deductions ? cost - deductions : 0;
        assertLe(vault.realizedProfit(), available);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Invariant 3 — combined gold cap never exceeded
    // ══════════════════════════════════════════════════════════════════════════
    function invariant_goldCapNotExceeded() public view {
        // N-06 loss recognition can shrink NAV after entry; enforce the cap at each deployment instead.
        assertFalse(handler.goldCapViolation(), "gold deployment exceeded entry-time cap");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Invariant 4 (PR2) — no dilution: no actor's share value grows due to
    //                     another actor depositing or redeeming.
    //                     (Share value CAN fall from gold drops, cross-chain loss,
    //                     fees, or write-offs — those are NOT invariant violations.)
    // ══════════════════════════════════════════════════════════════════════════
    /// @notice For each actor: if they held shares BEFORE another actor's action,
    ///         their pro-rata USDC value must not have INCREASED.
    ///         Check: preValue = preAssets * preShares / preSupply
    ///                curValue  = curAssets  * preShares / curSupply
    ///         Dilution would mean curValue < preValue (another actor's deposit
    ///         added assets to the pool, which should never decrease an existing
    ///         holder's share value; a redeem increases others' per-share value —
    ///         that is also fine).
    ///
    ///         Formally: preAssets/preSupply <= curAssets/curSupply + epsilon
    ///         i.e. another actor's action must not lower the exchange rate for
    ///         existing holders (beyond ERC-4626 rounding).
    function invariant_noDilutionFromOtherUsers() public view {
        // N-06 market losses are valid; the handler latches dilution only around deposits/redeems.
        assertFalse(handler.dilutionViolation(), "user action diluted existing shares");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Invariant 5 — vaultShare == 0 when HWM deficit exists before claim
    // ══════════════════════════════════════════════════════════════════════════
    function invariant_vaultShareZero_when_hwmDeficit() public view {
        // N-21: successful recovery-only waterfalls must never book a manager share; excess may earn a split.
        assertFalse(handler.recoveryShareViolation(), "manager earned on unrecovered loss");
    }

    // N-21: prove the recovery ghost observes a successful below-high waterfall rather than only caught reverts.
    function test_N21_recoveryInvariant_observesSuccessfulClaim() public {
        // A full processed peak plus entry after loss creates genuine flow-neutral recovery.
        vm.prank(owner);
        treasury.setAdminFeeBps(0);
        handler.deposit(uint96(1_000e6), 0);
        handler.claimProfit(uint96(300e6));
        assertEq(handler.successfulClaims(), 1);
        skip(vault.profitUnlockPeriod());
        usdc.burn(address(vault), 200e6);
        handler.deposit(uint96(1_000e6), 1);
        // Only half of the loss is recovered: realized profit is measured above the processed basis, so nothing is claimable.
        usdc.mint(address(vault), 100e6);
        handler.claimProfit(uint96(50e6));
        assertEq(handler.successfulClaims(), 1, "no claim while NAV is below the processed basis");
        // Recovery past the old high leaves genuine profit; only that excess can be claimed.
        usdc.mint(address(vault), 200e6);
        handler.claimProfit(uint96(50e6));
        assertEq(handler.successfulClaims(), 2);
        assertEq(handler.recoveryOnlyClaims(), 0, "a claim above the processed basis is never recovery-only");
        assertFalse(handler.recoveryShareViolation());
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Invariant 6 — lockedProfit decays to 0 after unlockedAt
    // ══════════════════════════════════════════════════════════════════════════
    function invariant_lockedProfitDecaysToZero() public view {
        uint256 ua = vault.unlockedAt();
        if (ua == 0) return;
        if (block.timestamp >= ua) {
            uint256 currentLocked = _currentLockedProfitPublic();
            assertEq(currentLocked, 0, "lockedProfit must be 0 after unlockedAt");
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Invariant 7 (PR2) — totalPendingCrossChain == Σ open pendingCrossChain[nonce]
    // ══════════════════════════════════════════════════════════════════════════
    /// @notice The on-chain totalPendingCrossChain must equal the handler's ghost
    ///         sum of still-open nonces.  Any settled/written-off nonce is removed
    ///         from both.
    function invariant_totalPendingCrossChain_consistent() public view {
        uint256 onChain = vault.totalPendingCrossChain();
        uint256 ghost   = handler.pendingCrossChainGhost();
        // Allow 1 USDC tolerance for any rounding during settle
        uint256 diff = onChain > ghost ? onChain - ghost : ghost - onChain;
        assertLe(diff, 1e6, "totalPendingCrossChain deviates from ghost sum");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Invariant 8 (PR2) — cross-chain pending cap never exceeded
    // ══════════════════════════════════════════════════════════════════════════
    /// @notice After every deploy, totalPendingCrossChain must remain <=
    ///         maxPendingCrossChainBps * totalAssets / 10_000.
    ///         (The handler's deployCrossChainAction only deploys when the cap
    ///         permits; this invariant catches any code path that bypasses the guard.)
    function invariant_crossChainCapNeverExceeded() public view {
        // N-06 gold losses may shrink NAV after a valid burn without increasing pending principal.
        assertFalse(handler.crossChainCapViolation(), "cross-chain deployment exceeded entry-time cap");
    }
}
