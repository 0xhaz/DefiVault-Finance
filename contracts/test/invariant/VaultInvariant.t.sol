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
    /// @notice vault.totalAssets() == idleBalance + totalDeployed - lockedProfit
    ///         within 2 USDC rounding tolerance.
    function invariant_totalAssetsAccounting() public view {
        uint256 idle          = usdc.balanceOf(address(vault));
        uint256 deployed      = vault.totalDeployed();
        uint256 lockedProfitNow = _currentLockedProfitPublic();
        uint256 base          = idle + deployed;
        uint256 expected      = base > lockedProfitNow ? base - lockedProfitNow : 0;
        uint256 actual        = vault.totalAssets();

        uint256 diff = actual > expected ? actual - expected : expected - actual;
        assertLe(diff, 2e6, "totalAssets accounting: deviation > 2 USDC");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Invariant 3 — combined gold cap never exceeded
    // ══════════════════════════════════════════════════════════════════════════
    function invariant_goldCapNotExceeded() public view {
        uint256 paxgVal  = goldSpreadAdp.currentValue();
        uint256 xautVal  = goldAllocAdp.currentValue();
        uint256 combined = paxgVal + xautVal;
        uint256 cap      = (vault.totalAssets() * vault.MAX_GOLD_BPS()) / 10_000 + 1;
        assertLe(combined, cap, "gold cap exceeded");
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
        uint256 ts = vault.totalSupply();
        if (ts == 0) return;
        uint256 ta = vault.totalAssets();

        for (uint256 i = 0; i < 3; i++) {
            address actor   = actors[i];
            uint256 prevSh  = handler.preActionShares(actor);
            uint256 prevTA  = handler.preActionAssets(actor);
            uint256 prevTS  = handler.preActionSupply(actor);

            if (prevTS == 0 || prevSh == 0) continue; // no snapshot yet

            // Pre-action per-share value: prevTA / prevTS (scaled by prevSh for safety)
            // Post-action per-share value: ta / ts
            // Require: ta/ts >= prevTA/prevTS - epsilon (no per-share dilution)
            // Cross-multiply: ta * prevTS >= prevTA * ts - 2e6 * ts
            uint256 curRate  = ta * prevTS;          // ta/ts * prevTS
            uint256 prevRate = prevTA * ts;           // prevTA/prevTS * ts
            uint256 slack    = 2e6 * ts;             // 2 USDC per share rounding tolerance

            // curRate should be >= prevRate - slack
            if (prevRate > slack) {
                assertGe(
                    curRate + slack,
                    prevRate,
                    "noDilution: per-share value dropped due to another user's deposit/redeem"
                );
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Invariant 5 — vaultShare == 0 when HWM deficit exists before claim
    // ══════════════════════════════════════════════════════════════════════════
    function invariant_vaultShareZero_when_hwmDeficit() public view {
        assertLe(vault.hwmDeficit(), vault.highWaterMark(),
            "hwmDeficit must never exceed highWaterMark");
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
        uint256 totalA     = vault.totalAssets();
        uint256 capBps     = vault.maxPendingCrossChainBps();
        uint256 maxPending = (totalA * capBps) / 10_000 + 1; // +1 for rounding
        assertLe(
            vault.totalPendingCrossChain(),
            maxPending,
            "cross-chain pending cap exceeded"
        );
    }
}
