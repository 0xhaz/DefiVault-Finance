// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test}   from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {VaultInvariantBase} from "./VaultInvariant.Base.t.sol";
import {MockERC20}          from "../../test-helpers/MockERC20.sol";

/// @dev Handler that exercises the ShariahVault stack for invariant testing.
contract VaultHandler is Test {

    VaultInvariantBase internal s; // shared state from base

    // Ghost variables for share-price monotonicity tracking
    mapping(address => uint256) public lastShareRatioNumerator;   // totalAssets * shares
    mapping(address => uint256) public lastShareRatioDenominator; // totalSupply
    mapping(address => bool)    public hasDeposited;

    // Ghost: track hwmDeficit before claimProfit
    uint256 public hwmDeficitBeforeClaim;
    uint256 public lastVaultShareFromClaim;
    bool    public claimWasAboveHWM; // true if we claimed when totalAssets > HWM at time of claim

    uint256 public callCount;

    constructor(VaultInvariantBase _s) {
        s = _s;
    }

    function _pickActor(uint8 seed) internal view returns (address) {
        return s.actors(seed % 3);
    }

    // ── Action 1: deposit ─────────────────────────────────────────────────────
    function deposit(uint96 assets, uint8 actorSeed) external {
        callCount++;
        uint256 amount = bound(uint256(assets), 1e6, 100_000e6);
        address actor  = _pickActor(actorSeed);

        uint256 bal = s.usdc().balanceOf(actor);
        if (bal < amount) {
            s.usdc().mint(actor, amount - bal);
        }

        // Snapshot share ratio before deposit (for monotonicity)
        _snapshotRatios();

        vm.prank(actor);
        try s.vault().deposit(amount, actor) {
            hasDeposited[actor] = true;
        } catch {}

        _snapshotRatios();
    }

    // ── Action 2: redeem ──────────────────────────────────────────────────────
    function redeem(uint96 shares, uint8 actorSeed) external {
        callCount++;
        address actor = _pickActor(actorSeed);
        uint256 maxSh = s.vault().maxRedeem(actor);
        if (maxSh == 0) return;

        uint256 amount = bound(uint256(shares), 1, maxSh);
        _snapshotRatios();

        vm.prank(actor);
        try s.vault().redeem(amount, actor, actor) {} catch {}

        _snapshotRatios();
    }

    // ── Action 3: deployToSpread ──────────────────────────────────────────────
    function deployToSpread(uint96 amount) external {
        callCount++;
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

        vm.prank(manager());
        try s.vault().deployCapital(address(s.goldSpreadAdp()), amt, "") {} catch {}
    }

    // ── Action 4: deployToAllocation ─────────────────────────────────────────
    function deployToAllocation(uint96 amount) external {
        callCount++;
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

        vm.prank(manager());
        try s.vault().deployCapital(address(s.goldAllocAdp()), amt, "") {
            // Execute the actual swap (adapter.deploy is gated onlyVault)
            vm.prank(address(s.vault()));
            try s.goldAllocAdp().deploy(amt) {} catch {}
        } catch {}
    }

    // ── Action 5: recallFromSpread ────────────────────────────────────────────
    function recallFromSpread() external {
        callCount++;
        if (s.vault().paused()) return;
        uint256 deployed = s.goldSpreadAdp().totalDeployed();
        if (deployed == 0) return;

        vm.prank(manager());
        try s.vault().recallCapital(address(s.goldSpreadAdp()), deployed) {} catch {}
    }

    // ── Action 6: recallFromAllocation ───────────────────────────────────────
    function recallFromAllocation() external {
        callCount++;
        if (s.vault().paused()) return;
        uint256 deployed = s.goldAllocAdp().totalDeployed();
        if (deployed == 0) return;

        vm.prank(manager());
        try s.vault().recallCapital(address(s.goldAllocAdp()), deployed) {} catch {}
    }

    // ── Action 7: claimProfit ─────────────────────────────────────────────────
    function claimProfit(uint96 grossProfit) external {
        callCount++;
        uint256 gross = bound(uint256(grossProfit), 1e6, 10_000e6);

        // Record HWM deficit before the call
        hwmDeficitBeforeClaim = s.vault().hwmDeficit();
        claimWasAboveHWM = (s.vault().totalAssets() > s.vault().highWaterMark());

        // Mint grossProfit to vault so the approval has backing
        s.usdc().mint(address(s.vault()), gross);

        vm.prank(manager());
        try s.vault().claimMusharakahProfit(gross) {} catch {}
    }

    // ── Action 8: warpTime ────────────────────────────────────────────────────
    function warpTime(uint32 secs) external {
        callCount++;
        uint256 elapsed = bound(uint256(secs), 1, 7 days);
        vm.warp(block.timestamp + elapsed);
    }

    // ── Action 9: moveOraclePrice ─────────────────────────────────────────────
    function moveOraclePrice(int16 pctBps) external {
        callCount++;
        int256 delta = bound(int256(pctBps), -1000, 1000);
        int256 current = s.xauOracle().price();
        int256 newPrice = current + (current * delta) / 10_000;
        if (newPrice <= 0) newPrice = 1e8;
        s.xauOracle().setPrice(newPrice);
        // Also update pool price proportionally (keep pool/oracle in sync)
        uint256 newPoolPrice = (uint256(newPrice) * 1e6) / 1e8; // convert 8-dec to 6-dec
        if (newPoolPrice == 0) newPoolPrice = 1;
        s.xautPool().setPrice(newPoolPrice);
    }

    // ── Action 10: makeOracleStale ────────────────────────────────────────────
    function makeOracleStale() external {
        callCount++;
        uint256 staleBy = s.goldAllocAdp().maxStalenessSecs() + 1;
        vm.warp(block.timestamp + staleBy);
        // Do NOT update oracle's updatedAt → it becomes stale
    }

    // ── Action 11: refreshOracle ──────────────────────────────────────────────
    function refreshOracle() external {
        callCount++;
        // Reset oracle's updatedAt to now so it's fresh again
        s.xauOracle().setUpdatedAt(block.timestamp);
        // Also re-set a valid price to bump roundId
        s.xauOracle().setPrice(s.xauOracle().price());
    }

    // ── Internal helpers ──────────────────────────────────────────────────────
    function _snapshotRatios() internal {
        uint256 ts = s.vault().totalSupply();
        if (ts == 0) return;
        uint256 ta = s.vault().totalAssets();
        for (uint256 i = 0; i < 3; i++) {
            address actor = s.actors(i);
            lastShareRatioNumerator[actor]   = ta * s.vault().balanceOf(actor);
            lastShareRatioDenominator[actor] = ts;
        }
    }

    function manager()  internal view returns (address) { return s.manager();  }
    function owner_()   internal view returns (address) { return s.owner();    }
}
