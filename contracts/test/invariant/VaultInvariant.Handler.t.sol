// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test}   from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {VaultInvariantBase} from "./VaultInvariant.Base.t.sol";
import {MockERC20}          from "../../test-helpers/MockERC20.sol";
import {ShariahVault}       from "../../ShariahVault.sol";

/// @dev Handler that exercises the ShariahVault stack for invariant testing.
///      PR2: extended with cross-chain actions, gold price drop, stale oracle,
///      fee settle, write-off, and loss-making recall so the fuzzer can produce
///      real losses and observe the new invariants.
contract VaultHandler is Test {

    VaultInvariantBase internal s; // shared state from base

    // ── Ghost variables for no-dilution invariant ─────────────────────────────
    // Tracks each actor's USDC value of shares (totalAssets * balance / totalSupply)
    // snapshots taken AROUND other actors' deposits and redeems.
    mapping(address => uint256) public preActionShares;   // shares held before an other-actor action
    mapping(address => uint256) public preActionAssets;   // totalAssets before the action
    mapping(address => uint256) public preActionSupply;   // totalSupply before the action
    mapping(address => bool)    public hasDeposited;

    // Legacy fields kept for HWM invariant
    uint256 public hwmDeficitBeforeClaim;
    uint256 public lastVaultShareFromClaim;
    bool    public claimWasAboveHWM;
    bool public recoveryShareViolation;
    uint256 public successfulClaims;
    uint256 public recoveryOnlyClaims;

    // ── Ghost: cross-chain nonce tracking for totalPendingCrossChain invariant ─
    uint64[] public openNonces;
    mapping(uint64 => bool)    public nonceOpen;
    mapping(uint64 => uint256) public nonceSent;   // amount stored when nonce opened
    uint256 public pendingCrossChainGhost;          // sum of open pendingCrossChain[nonce]

    uint256 public callCount;
    // N-06 caps apply at deployment; later market losses may reduce NAV without a new allocation.
    bool public goldCapViolation;
    bool public crossChainCapViolation;
    bool public dilutionViolation;

    function _checkUserDilution() internal {
        uint256 assetsNow = s.vault().totalAssets();
        uint256 supplyNow = s.vault().totalSupply();
        for (uint256 i = 0; i < 3; i++) {
            address actor = s.actors(i);
            uint256 previousAssets = preActionAssets[actor];
            if (preActionSupply[actor] == 0 || preActionShares[actor] == 0 || supplyNow == 0) continue;
            if (assetsNow * preActionSupply[actor] + 2e6 * supplyNow < previousAssets * supplyNow) {
                dilutionViolation = true;
            }
        }
    }

    // Per-function call counts for -vv summary (PR2: report losses actually happen)
    uint256 public depositCalls;
    uint256 public redeemCalls;
    uint256 public deploySpreadCalls;
    uint256 public deployAllocCalls;
    uint256 public recallSpreadCalls;
    uint256 public recallAllocCalls;
    uint256 public claimProfitCalls;
    uint256 public warpTimeCalls;
    uint256 public moveOracleCalls;
    uint256 public makeOracleStaleCalls;
    uint256 public refreshOracleCalls;
    uint256 public dropGoldPriceCalls;
    uint256 public deployCCCalls;          // deployCrossChain
    uint256 public settleWithFeeCalls;
    uint256 public settleShortfallCalls;
    uint256 public writeOffCalls;
    uint256 public lossRecallCalls;

    constructor(VaultInvariantBase _s) {
        s = _s;
    }

    function _pickActor(uint8 seed) internal view returns (address) {
        return s.actors(seed % 3);
    }

    // ── Snapshot helpers ─────────────────────────────────────────────────────

    function _snapshotForActor(address actor) internal {
        preActionShares[actor]  = s.vault().balanceOf(actor);
        preActionAssets[actor]  = s.vault().totalAssets();
        preActionSupply[actor]  = s.vault().totalSupply();
    }

    function _snapshotAll() internal {
        for (uint256 i = 0; i < 3; i++) {
            _snapshotForActor(s.actors(i));
        }
    }

    // ── Action 1: deposit ─────────────────────────────────────────────────────────
    function deposit(uint96 assets, uint8 actorSeed) external {
        callCount++; depositCalls++;
        uint256 amount = bound(uint256(assets), 1e6, 100_000e6);
        address actor  = _pickActor(actorSeed);

        uint256 bal = s.usdc().balanceOf(actor);
        if (bal < amount) {
            s.usdc().mint(actor, amount - bal);
        }

        _snapshotAll();

        vm.prank(actor);
        try s.vault().deposit(amount, actor) {
            hasDeposited[actor] = true;
            // N-06 isolates dilution checks from subsequent market-driven NAV changes.
            _checkUserDilution();
        } catch {}
    }

    // ── Action 2: redeem ──────────────────────────────────────────────────────────
    function redeem(uint96 shares, uint8 actorSeed) external {
        callCount++; redeemCalls++;
        address actor = _pickActor(actorSeed);
        uint256 maxSh = s.vault().maxRedeem(actor);
        if (maxSh == 0) return;

        uint256 amount = bound(uint256(shares), 1, maxSh);

        _snapshotAll();

        vm.prank(actor);
        // N-06 checks dilution only around the user action, not around unrelated later losses.
        try s.vault().redeem(amount, actor, actor) { _checkUserDilution(); } catch {}
    }

    // ── Action 3: deployToSpread ──────────────────────────────────────────────
    function deployToSpread(uint96 amount) external {
        callCount++; deploySpreadCalls++;
        if (s.vault().paused()) return;
        uint256 totalA = s.vault().totalAssets();
        if (totalA == 0) return;
        uint256 maxDeploy = (totalA * s.vault().maxAllocationBps()) / 10_000;
        uint256 already   = s.vault().totalDeployed();
        if (already >= maxDeploy) return;

        uint256 canDeploy = maxDeploy - already;
        uint256 amt = bound(uint256(amount), 1e6, 10_000e6);
        amt = amt > canDeploy ? canDeploy : amt;
        if (amt == 0) return;

        uint256 vaultBal = s.usdc().balanceOf(address(s.vault()));
        if (vaultBal < amt) return;

        // N-06 records cap compliance at entry so later losses cannot invalidate a permitted deployment.
        uint256 combined = s.goldSpreadAdp().currentValue() + s.goldAllocAdp().currentValue() + amt;
        uint256 cap = totalA * s.vault().MAX_GOLD_BPS() / 10_000;
        vm.prank(manager());
        try s.vault().deployCapitalAndExecute(address(s.goldSpreadAdp()), amt, "") {
            if (combined > cap) goldCapViolation = true;
        } catch {}
    }

    // ── Action 4: deployToAllocation ─────────────────────────────────────────
    function deployToAllocation(uint96 amount) external {
        callCount++; deployAllocCalls++;
        if (s.vault().paused()) return;
        uint256 totalA = s.vault().totalAssets();
        if (totalA == 0) return;
        uint256 maxDeploy = (totalA * s.vault().maxAllocationBps()) / 10_000;
        uint256 already   = s.vault().totalDeployed();
        if (already >= maxDeploy) return;

        uint256 canDeploy = maxDeploy - already;
        uint256 amt = bound(uint256(amount), 1e6, 10_000e6);
        amt = amt > canDeploy ? canDeploy : amt;
        if (amt == 0) return;

        if (!s.goldAllocAdp().isPriceSane()) return;

        uint256 vaultBal = s.usdc().balanceOf(address(s.vault()));
        if (vaultBal < amt) return;

        // N-06 records cap compliance at entry while retaining price-drop and loss-recall actions.
        uint256 combined = s.goldSpreadAdp().currentValue() + s.goldAllocAdp().currentValue() + amt;
        uint256 cap = totalA * s.vault().MAX_GOLD_BPS() / 10_000;
        vm.prank(manager());
        try s.vault().deployCapitalAndExecute(address(s.goldAllocAdp()), amt, "") {
            if (combined > cap) goldCapViolation = true;
        } catch {}
    }

    // ── Action 5: recallFromSpread ────────────────────────────────────────────
    function recallFromSpread() external {
        callCount++; recallSpreadCalls++;
        if (s.vault().paused()) return;
        uint256 deployed = s.goldSpreadAdp().totalDeployed();
        if (deployed == 0) return;

        vm.prank(manager());
        try s.vault().recallCapital(address(s.goldSpreadAdp()), deployed) {} catch {}
    }

    // ── Action 6: recallFromAllocation ───────────────────────────────────────
    function recallFromAllocation() external {
        callCount++; recallAllocCalls++;
        if (s.vault().paused()) return;
        uint256 deployed = s.goldAllocAdp().totalDeployed();
        if (deployed == 0) return;

        vm.prank(manager());
        try s.vault().recallCapital(address(s.goldAllocAdp()), deployed) {} catch {}
    }

    // ── Action 7: claimProfit ─────────────────────────────────────────────────
    function claimProfit(uint96 grossProfit) external {
        callCount++; claimProfitCalls++;
        uint256 gross = bound(uint256(grossProfit), 1e6, 10_000e6);

        s.usdc().mint(address(s.vault()), gross);
        // Bound claims to net realized profit so losses/locked profit never turn principal into fees.
        uint256 available = s.vault().realizedProfit();
        if (available == 0) return;
        gross = bound(gross, 1, available);
        // N-21: compare the pre-claim processed price and record only successful claims, excluding Wakala booking.
        uint256 deficit = _preProfitDeficit();
        uint256 fees = s.treasury().pendingFees();
        uint256 unbooked = s.vault().pendingWakalaFee();
        uint256 net = gross - gross * s.purificationEscrow().purificationBps() / 10_000;
        net -= net * s.charityModule().charityBps() / 10_000;
        // Resolve every external getter before the prank: a call in the try expression would consume it.
        ShariahVault v = s.vault();
        address mgr = manager();
        vm.prank(mgr);
        try v.claimMusharakahProfit(gross) {
            successfulClaims++;
            hwmDeficitBeforeClaim = deficit;
            claimWasAboveHWM = deficit == 0;
            lastVaultShareFromClaim = s.treasury().pendingFees() - fees - unbooked;
            if (deficit > 0 && net <= deficit) {
                recoveryOnlyClaims++;
                if (lastVaultShareFromClaim != 0) recoveryShareViolation = true;
            }
        } catch {}
    }

    function _preProfitDeficit() internal view returns (uint256) {
        uint256 nav = s.vault().totalAssets();
        uint256 gain = s.vault().goldUnrealizedGain();
        nav = nav > gain ? nav - gain : 0;
        uint256 period = s.vault().profitUnlockPeriod();
        uint256 end = s.vault().unlockedAt();
        if (period != 0 && block.timestamp < end && end >= period && end - period <= block.timestamp) {
            nav += Math.mulDiv(s.vault().lockedProfit(), end - block.timestamp, period);
        }
        nav = Math.min(nav, s.vault().profitBase());
        uint256 supply = s.vault().totalSupply() + 1e6;
        uint256 price = Math.mulDiv(nav + 1, 1e18, supply);
        uint256 high = s.vault().highWaterMarkPerShare();
        return high > price ? Math.mulDiv(high - price, supply, 1e18) : 0;
    }

    // ── Action 8: warpTime ────────────────────────────────────────────────────
    function warpTime(uint32 secs) external {
        callCount++; warpTimeCalls++;
        uint256 elapsed = bound(uint256(secs), 1, 7 days);
        vm.warp(block.timestamp + elapsed);
    }

    // ── Action 9: moveOraclePrice ─────────────────────────────────────────────
    function moveOraclePrice(int16 pctBps) external {
        callCount++; moveOracleCalls++;
        int256 delta = bound(int256(pctBps), -1000, 1000);
        int256 current = s.xauOracle().price();
        int256 newPrice = current + (current * delta) / 10_000;
        if (newPrice <= 0) newPrice = 1e8;
        s.xauOracle().setPrice(newPrice);
        uint256 newPoolPrice = (uint256(newPrice) * 1e6) / 1e8;
        if (newPoolPrice == 0) newPoolPrice = 1;
        s.xautPool().setPrice(newPoolPrice);
    }

    // ── Action 10: makeOracleStale ────────────────────────────────────────────
    function makeOracleStale() external {
        callCount++; makeOracleStaleCalls++;
        uint256 staleBy = s.goldAllocAdp().maxStalenessSecs() + 1;
        vm.warp(block.timestamp + staleBy);
        // Do NOT update oracle's updatedAt → it becomes stale
    }

    // ── Action 11: refreshOracle ──────────────────────────────────────────────
    function refreshOracle() external {
        callCount++; refreshOracleCalls++;
        s.xauOracle().setUpdatedAt(block.timestamp);
        s.xauOracle().setPrice(s.xauOracle().price());
        // Also refresh GoldExchangeAdapter's S2-H oracle timestamp
        s.goldSpreadOracle().setUpdatedAt(block.timestamp);
        s.goldSpreadOracle().setPrice(s.goldSpreadOracle().price());
    }

    // ── Action 12 (PR2): dropGoldPrice — large price drop causes NAV to fall ──
    // This proves the handler CAN produce losses (share price CAN fall).
    function dropGoldPrice(uint8 pctDrop) external {
        callCount++; dropGoldPriceCalls++;
        // Drop price 1%–30%
        uint256 drop = bound(uint256(pctDrop), 100, 3000); // bps
        int256 current = s.xauOracle().price();
        if (current <= 0) return;
        int256 newPrice = current - (current * int256(drop)) / 10_000;
        if (newPrice <= 0) newPrice = 1e8;
        s.xauOracle().setPrice(newPrice);
        // Pool price drops proportionally
        uint256 newPoolPrice = (uint256(newPrice) * 1e6) / 1e8;
        if (newPoolPrice == 0) newPoolPrice = 1;
        s.xautPool().setPrice(newPoolPrice);
        // Also drop S2-H oracle price
        int256 cur2 = s.goldSpreadOracle().price();
        if (cur2 > 0) {
            int256 np2 = cur2 - (cur2 * int256(drop)) / 10_000;
            if (np2 <= 0) np2 = 1e8;
            s.goldSpreadOracle().setPrice(np2);
            s.paxgRouter().setPrice(uint256(np2) / 100);
        }
        // N-06 refreshes cached gold values so the drop action immediately exercises vault writedowns.
        s.goldSpreadAdp().pokePrice();
        s.goldAllocAdp().pokePrice();
    }

    // ── Action 13 (PR2): deployCrossChain — put capital in-flight ────────────
    function deployCrossChainAction(uint96 amount) external {
        callCount++; deployCCCalls++;
        if (s.vault().paused()) return;
        if (address(s.mockMessenger()) == address(0)) return;

        uint256 totalA = s.vault().totalAssets();
        if (totalA == 0) return;

        uint256 maxDeploy = (totalA * s.vault().maxAllocationBps()) / 10_000;
        uint256 already   = s.vault().totalDeployed();
        if (already >= maxDeploy) return;

        uint256 canDeploy = maxDeploy - already;
        uint256 maxPending = (totalA * s.vault().maxPendingCrossChainBps()) / 10_000;
        uint256 inFlight   = s.vault().totalPendingCrossChain();
        if (inFlight >= maxPending) return;
        uint256 canPend = maxPending - inFlight;

        uint256 amt = bound(uint256(amount), 1e6, 5_000e6);
        amt = amt > canDeploy ? canDeploy : amt;
        amt = amt > canPend   ? canPend   : amt;
        if (amt == 0) return;

        uint256 vaultBal = s.usdc().balanceOf(address(s.vault()));
        if (vaultBal < amt) return;

        // Task M: ghost keys track local positions rather than Circle's offchain nonce.
        uint64 nonceNow = s.vault().crossChainPositionCounter() + 1;

        vm.prank(manager());
        try s.vault().deployCrossChain(6, bytes32(uint256(uint160(makeAddr("dest")))), amt) {
            // N-06 checks the entry-time pending cap, not a smaller NAV after subsequent losses.
            if (inFlight + amt > maxPending) crossChainCapViolation = true;
            nonceOpen[nonceNow]    = true;
            nonceSent[nonceNow]    = amt;
            openNonces.push(nonceNow);
            pendingCrossChainGhost += amt;
        } catch {}
    }

    // ── Action 14 (PR2): settleWithFee — return most capital with a CCTP fee ──
    function settleWithFee(uint8 nonceSeed, uint8 feePctBps) external {
        callCount++; settleWithFeeCalls++;
        if (openNonces.length == 0) return;

        uint256 idx   = uint256(nonceSeed) % openNonces.length;
        uint64  nonce = openNonces[idx];
        if (!nonceOpen[nonce]) return;

        uint256 sent    = nonceSent[nonce];
        uint256 feeAmt  = bound(uint256(feePctBps), 0, 300) * sent / 10_000;
        uint256 netAmt  = sent - feeAmt; // received after fee

        // Task M: mint inside receiveMessage so atomic balance-delta accounting is exercised.
        bytes memory msg_ = _buildCctpMsg(nonce, sent, feeAmt);
        s.mockTransmitter().setMintAmount(netAmt);

        vm.prank(manager());
        try s.vault().settleCrossChainWithMessage(nonce, msg_, "") {
            _removeNonce(idx, nonce, sent);
        } catch {}
    }

    // ── Action 15 (PR2): settleShortfall — strategy returned less ────────────
    function settleShortfall(uint8 nonceSeed, uint8 returnPctBps) external {
        callCount++; settleShortfallCalls++;
        if (openNonces.length == 0) return;

        uint256 idx   = uint256(nonceSeed) % openNonces.length;
        uint64  nonce = openNonces[idx];
        if (!nonceOpen[nonce]) return;

        uint256 sent      = nonceSent[nonce];
        uint256 returnPct = bound(uint256(returnPctBps), 7000, 10_000); // 70%-100% returned
        uint256 netAmt    = sent * returnPct / 10_000;

        // Task M: the transmitter mints during the measured atomic settle call.
        bytes memory msg_ = _buildCctpMsg(nonce, netAmt, 0); // no fee, just shortfall
        s.mockTransmitter().setMintAmount(netAmt);

        vm.prank(manager());
        try s.vault().settleCrossChainWithMessage(nonce, msg_, "") {
            _removeNonce(idx, nonce, sent);
        } catch {}
    }

    // ── Action 16 (PR2): writeOff — book a cross-chain loss (owner only) ─────
    function writeOff(uint8 nonceSeed) external {
        callCount++; writeOffCalls++;
        if (openNonces.length == 0) return;

        uint256 idx   = uint256(nonceSeed) % openNonces.length;
        uint64  nonce = openNonces[idx];
        if (!nonceOpen[nonce]) return;

        uint256 sent = nonceSent[nonce];

        vm.prank(owner_());
        try s.vault().settleCrossChain(nonce, 0) {
            _removeNonce(idx, nonce, sent);
        } catch {}
    }

    // ── Action 17 (PR2): lossRecall — recall when market moved against position
    function lossRecall() external {
        callCount++; lossRecallCalls++;
        if (s.vault().paused()) return;

        // Drop gold price dramatically before recalling allocation adapter
        int256 current = s.xauOracle().price();
        if (current > 0) {
            int256 lower = current * 85 / 100; // 15% drop
            if (lower <= 0) lower = 1e8;
            s.xauOracle().setPrice(lower);
            uint256 newPool = (uint256(lower) * 1e6) / 1e8;
            if (newPool == 0) newPool = 1;
            s.xautPool().setPrice(newPool);
        }

        uint256 deployed = s.goldAllocAdp().totalDeployed();
        if (deployed == 0) return;

        vm.prank(manager());
        try s.vault().recallCapital(address(s.goldAllocAdp()), deployed) {} catch {}
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    /// @dev Build a minimal CCTP V2 BurnMessageV2 (376 bytes: 148 header + 228 body).
    ///      Body layout: version(4)+burnToken(32)+mintRecipient(32)+amount(32)+
    ///                   messageSender(32)+maxFee(32)+feeExecuted(32)+expirationBlock(32).
    function _buildCctpMsg(uint64 nonce_, uint256 amount_, uint256 feeExecuted_)
        internal view returns (bytes memory)
    {
        // Task M: native header with bytes32 nonce and registered remote messenger.
        uint32 remoteDomain = s.vault().pendingCrossChainDestinationDomain(nonce_);
        bytes memory header = abi.encodePacked(
            uint32(1), remoteDomain, s.vault().localDomain(), bytes32(uint256(nonce_)),
            s.vault().remoteTokenMessenger(remoteDomain),
            bytes32(uint256(uint160(s.vault().tokenMessenger()))),
            bytes32(uint256(uint160(address(s.vault())))), uint32(2000), uint32(2000) // destinationCaller = vault
        );
        bytes memory body = new bytes(228);
        body[3] = 0x01;
        // mintRecipient at body[36..67] = vault address
        bytes32 recipientWord = bytes32(uint256(uint160(address(s.vault()))));
        for (uint256 i = 0; i < 32; i++) {
            body[36 + i] = recipientWord[i];
        }
        // amount at body[68..99]
        bytes32 amountWord = bytes32(amount_);
        for (uint256 i = 0; i < 32; i++) {
            body[68 + i] = amountWord[i];
        }
        // maxFee at body[132..163] — set equal to feeExecuted as a valid ceiling
        bytes32 maxFeeWord = bytes32(feeExecuted_);
        for (uint256 i = 0; i < 32; i++) {
            body[132 + i] = maxFeeWord[i];
        }
        // feeExecuted at body[164..195] (actual fee taken; 0 for Standard Transfer)
        bytes32 feeWord = bytes32(feeExecuted_);
        for (uint256 i = 0; i < 32; i++) {
            body[164 + i] = feeWord[i];
        }
        // expirationBlock at body[196..227] — left zero
        return abi.encodePacked(header, body);
    }

    function _removeNonce(uint256 idx, uint64 nonce, uint256 sent) internal {
        nonceOpen[nonce]        = false;
        pendingCrossChainGhost  = pendingCrossChainGhost >= sent
            ? pendingCrossChainGhost - sent : 0;
        // swap-and-pop
        uint256 last = openNonces.length - 1;
        if (idx != last) {
            openNonces[idx] = openNonces[last];
        }
        openNonces.pop();
    }

    function manager()  internal view returns (address) { return s.manager();  }
    function owner_()   internal view returns (address) { return s.owner();    }

    function openNoncesLength() external view returns (uint256) {
        return openNonces.length;
    }
}
