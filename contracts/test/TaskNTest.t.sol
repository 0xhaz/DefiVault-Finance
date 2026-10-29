// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AutonomousVault}         from "../AutonomousVault.sol";
import {ShariahVault}            from "../ShariahVault.sol";
import {RiskTieredExecutor}      from "../RiskTieredExecutor.sol";
import {ScoreAggregator}         from "../ScoreAggregator.sol";
import {ShariahScoreAggregator}  from "../ShariahScoreAggregator.sol";
import {RemoteRecipientFixture} from "./TaskITest.Base.t.sol";
import {TaskNBase, MockStrategyAdapterN} from "./TaskNTest.Base.t.sol";

/// @title TaskNTest — N1: gold guard moved from vault-wide flag to strategy-tagged entry point.
contract TaskNTest is TaskNBase {
    ShariahScoreAggregator internal shAgg;
    ScoreAggregator        internal conv;
    MockStrategyAdapterN   internal stratAdapter;

    function setUp() public override {
        super.setUp();
        shAgg = new ShariahScoreAggregator(owner);
        conv  = new ScoreAggregator(owner);
        stratAdapter = new MockStrategyAdapterN(address(svault));
    }

    // ─────────────────────────────────────────────────────────────────────
    // Fixture sanity: gold really is held in both adapters
    // ─────────────────────────────────────────────────────────────────────

    function test_fixture_goldHeldInBothAdapters() public view {
        assertGt(goldAdapter.paxgHeld(), 0, "S2-H holds PAXG");
        assertGt(allocAdapter.xautHeld(), 0, "S6-H holds XAUT");
        assertGt(goldAdapter.currentValue(), 0, "S2-H valued");
        assertGt(allocAdapter.currentValue(), 0, "S6-H valued");
        assertEq(svault.totalDeployed(), 2 * GOLD_BUY);
    }

    // ─────────────────────────────────────────────────────────────────────
    // (a) idx 0 USDC cross-chain succeeds while gold is held
    // ─────────────────────────────────────────────────────────────────────

    function test_a_forStrategy_idx0_succeeds_withGoldHeld_andUpdatesPending() public {
        uint256 amt = 10_000e6;
        bytes32 rcpt = _bytes32(alice);
        // Task M: predict the next local position ID for pending/event assertions.
        uint64 nonce = svault.crossChainPositionCounter() + 1;
        uint256 deployedBefore = svault.totalDeployed();

        vm.expectEmit(true, true, false, true, address(svault));
        emit AutonomousVault.CapitalDeployedCrossChain(DEST_DOMAIN, rcpt, amt, nonce);
        vm.prank(manager);
        svault.deployCrossChainForStrategy(ETH_SPREAD, DEST_DOMAIN, rcpt, amt);

        assertEq(svault.pendingCrossChain(nonce), amt);
        assertEq(svault.pendingCrossChainDestinationDomain(nonce), DEST_DOMAIN);
        assertEq(svault.totalPendingCrossChain(), amt);
        assertEq(svault.totalDeployed(), deployedBefore + amt);
    }

    function test_a_plainDeployCrossChain_succeeds_withGoldHeld_andUpdatesPending() public {
        uint256 amt = 10_000e6;
        bytes32 rcpt = _bytes32(alice);
        // Task M: predict the next local position ID for pending/event assertions.
        uint64 nonce = svault.crossChainPositionCounter() + 1;
        uint256 deployedBefore = svault.totalDeployed();

        vm.expectEmit(true, true, false, true, address(svault));
        emit AutonomousVault.CapitalDeployedCrossChain(DEST_DOMAIN, rcpt, amt, nonce);
        vm.prank(manager);
        svault.deployCrossChain(DEST_DOMAIN, rcpt, amt);

        assertEq(svault.pendingCrossChain(nonce), amt);
        assertEq(svault.pendingCrossChainDestinationDomain(nonce), DEST_DOMAIN);
        assertEq(svault.totalPendingCrossChain(), amt);
        assertEq(svault.totalDeployed(), deployedBefore + amt);
    }

    function test_a_ownerCanAlsoDeployCrossChain_bothEntryPoints() public {
        vm.startPrank(owner);
        svault.deployCrossChainForStrategy(ETH_SPREAD, DEST_DOMAIN, _bytes32(alice), 1_000e6);
        svault.deployCrossChain(DEST_DOMAIN, _bytes32(alice), 2_000e6);
        vm.stopPrank();
        assertEq(svault.totalPendingCrossChain(), 3_000e6);
    }

    function testFuzz_a_nonGoldIdx_anyDomain_succeeds(uint8 idx, uint32 domain, bytes32 rcpt, uint256 amt) public {
        vm.assume(idx != GOLD_SPREAD && idx != GOLD_ALLOC);
        vm.assume(domain != SOURCE_DOMAIN);
        vm.assume(rcpt != bytes32(0));
        RemoteRecipientFixture.approve(vm, svault, owner, domain, rcpt);
        amt = bound(amt, 0, 400_000e6);
        // Task M: predict the next local position ID for pending/event assertions.
        uint64 nonce = svault.crossChainPositionCounter() + 1;

        vm.prank(manager);
        svault.deployCrossChainForStrategy(idx, domain, rcpt, amt);

        assertEq(svault.pendingCrossChain(nonce), amt);
        assertEq(svault.pendingCrossChainDestinationDomain(nonce), domain);
        assertEq(svault.totalPendingCrossChain(), amt);
    }

    function test_a_goldCrossChainBlocked_removed() public {
        // Selector no longer exists on the vault: low-level calls hit no function (no fallback) => revert.
        (bool ok,) = address(svault).staticcall(abi.encodeWithSignature("goldCrossChainBlocked()"));
        assertFalse(ok, "goldCrossChainBlocked getter removed");
        vm.prank(owner);
        (bool ok2,) = address(svault).call(abi.encodeWithSignature("setGoldCrossChainBlocked(bool)", true));
        assertFalse(ok2, "setter removed");
    }

    // ─────────────────────────────────────────────────────────────────────
    // (b) gold idx 1 / 5 with nonzero domain reverts NonAtomicGoldExchange
    // ─────────────────────────────────────────────────────────────────────

    function _expectNonAtomicAndNoStateChange(address caller, uint8 idx, uint32 domain, bytes32 rcpt, uint256 amt) internal {
        uint256 pendingBefore = svault.totalPendingCrossChain();
        uint256 deployedBefore = svault.totalDeployed();
        uint64 nonceBefore = messenger.callCount();

        vm.prank(caller);
        vm.expectRevert(ShariahVault.NonAtomicGoldExchange.selector);
        svault.deployCrossChainForStrategy(idx, domain, rcpt, amt);

        assertEq(svault.totalPendingCrossChain(), pendingBefore);
        assertEq(svault.totalDeployed(), deployedBefore);
        assertEq(messenger.callCount(), nonceBefore, "messenger must not be called");
    }

    function testFuzz_b_goldIdx_nonzeroDomain_reverts(bool pickAlloc, bool useOwner, uint32 domain, bytes32 rcpt, uint256 amt) public {
        domain = uint32(bound(domain, 1, type(uint32).max));
        _expectNonAtomicAndNoStateChange(
            useOwner ? owner : manager, pickAlloc ? GOLD_ALLOC : GOLD_SPREAD, domain, rcpt, amt
        );
    }

    function test_b_goldIdx_sourceDomain_reverts_beforeSameDomainCheck() public {
        _expectNonAtomicAndNoStateChange(manager, GOLD_SPREAD, SOURCE_DOMAIN, _bytes32(alice), 1e6);
        _expectNonAtomicAndNoStateChange(manager, GOLD_ALLOC, SOURCE_DOMAIN, _bytes32(alice), 1e6);
    }

    function test_b_goldIdx_amountZeroAndMax_reverts() public {
        _expectNonAtomicAndNoStateChange(manager, GOLD_SPREAD, DEST_DOMAIN, _bytes32(alice), 0);
        _expectNonAtomicAndNoStateChange(manager, GOLD_ALLOC, DEST_DOMAIN, _bytes32(alice), 0);
        _expectNonAtomicAndNoStateChange(manager, GOLD_SPREAD, DEST_DOMAIN, _bytes32(alice), type(uint256).max);
        _expectNonAtomicAndNoStateChange(manager, GOLD_ALLOC, DEST_DOMAIN, _bytes32(alice), type(uint256).max);
    }

    function test_b_goldIdx_maxDomain_zeroRecipient_reverts() public {
        _expectNonAtomicAndNoStateChange(owner, GOLD_SPREAD, type(uint32).max, bytes32(0), 5e6);
        _expectNonAtomicAndNoStateChange(owner, GOLD_ALLOC, 1, bytes32(0), 5e6);
    }

    /// @dev Domain 0 is a real CCTP domain (Ethereum), not "local". The strategy-tagged entry point
    ///      is cross-chain by definition, so gold indices revert for domain 0 as well.
    function testFuzz_b_goldIdx_domainZero_alsoReverts(bool pickAlloc, bytes32 rcpt, uint256 amt) public {
        uint8 idx = pickAlloc ? GOLD_ALLOC : GOLD_SPREAD;
        amt = bound(amt, 0, 400_000e6);
        _expectNonAtomicAndNoStateChange(manager, idx, 0, rcpt, amt);
    }

    function test_b_goldIdx_domainZero_reverts_noPendingBooked() public {
        _expectNonAtomicAndNoStateChange(manager, GOLD_SPREAD, 0, _bytes32(alice), 1_000e6);
        _expectNonAtomicAndNoStateChange(owner, GOLD_ALLOC, 0, _bytes32(alice), 1_000e6);
    }

    function test_b_plainDeployCrossChain_notBlockedByGold_forGoldAdapters() public {
        // Gold held in both adapters; the plain entry point has no gold guard at all.
        vm.prank(manager);
        svault.deployCrossChain(DEST_DOMAIN, _bytes32(alice), 1_000e6);
        assertEq(svault.totalPendingCrossChain(), 1_000e6);
    }

    // ─────────────────────────────────────────────────────────────────────
    // (c) NotManager for strangers
    // ─────────────────────────────────────────────────────────────────────

    function testFuzz_c_stranger_forStrategy_reverts_NotManager(
        address caller, uint8 idx, uint32 domain, bytes32 rcpt, uint256 amt
    ) public {
        vm.assume(caller != owner && caller != manager);
        vm.prank(caller);
        vm.expectRevert(AutonomousVault.NotManager.selector);
        svault.deployCrossChainForStrategy(idx, domain, rcpt, amt);
    }

    function test_c_stranger_goldIdx_nonzeroDomain_getsNotManager_notGoldError() public {
        vm.prank(stranger);
        vm.expectRevert(AutonomousVault.NotManager.selector);
        svault.deployCrossChainForStrategy(GOLD_SPREAD, DEST_DOMAIN, _bytes32(alice), 1e6);
    }

    function test_c_stranger_plainDeployCrossChain_reverts_NotManager() public {
        vm.prank(stranger);
        vm.expectRevert(AutonomousVault.NotManager.selector);
        svault.deployCrossChain(DEST_DOMAIN, _bytes32(alice), 1e6);
    }

    // ─────────────────────────────────────────────────────────────────────
    // (d) RiskTieredExecutor — Shariah tiers
    // ─────────────────────────────────────────────────────────────────────

    function _mkExec(RiskTieredExecutor.RiskTier tier) internal returns (RiskTieredExecutor ex) {
        vm.startPrank(owner);
        ex = new RiskTieredExecutor(address(svault), address(conv), tier, owner);
        ex.setShariahAggregator(address(shAgg));
        svault.setManager(address(ex));
        svault.setScreened(address(stratAdapter), true);
        uint8[5] memory idxs = [0, 1, 2, 3, 5];
        for (uint256 i = 0; i < idxs.length; i++) {
            ex.setShariahStrategyConfig(idxs[i], address(stratAdapter), _bytes32(alice), true, 1, 10_000e6);
            shAgg.setEnabled(ShariahScoreAggregator.ShariahStrategy(idxs[i]), true);
        }
        vm.stopPrank();
    }

    function _score(uint8 idx, uint32 domain) internal {
        vm.prank(owner);
        shAgg.writeScore(ShariahScoreAggregator.ShariahStrategy(idx), 95, keccak256("n1"), domain);
    }

    function _assertExecutedLocally(RiskTieredExecutor ex, uint256 deployedBefore) internal view {
        assertEq(svault.totalDeployed(), deployedBefore + 10_000e6, "local deployCapital booked");
        assertEq(usdc.balanceOf(address(stratAdapter)), 10_000e6, "adapter funded");
        // Atomic tiers call the adapter from the vault; conventional tiers retain the executor caller.
        bool atomicTier = ex.riskTier() == RiskTieredExecutor.RiskTier.SHARIAH_CONSERVATIVE
            || ex.riskTier() == RiskTieredExecutor.RiskTier.SHARIAH_DYNAMIC;
        assertEq(stratAdapter.lastDeployCaller(), atomicTier ? address(svault) : address(ex));
        assertEq(svault.totalPendingCrossChain(), 0, "no cross-chain pending");
        assertEq(messenger.callCount(), 0, "messenger untouched");
        assertEq(ex.lastExecutionTime(), block.timestamp);
    }

    function _goldRevertsForTier(RiskTieredExecutor.RiskTier tier) internal {
        RiskTieredExecutor ex = _mkExec(tier);
        uint8[2] memory golds = [GOLD_SPREAD, GOLD_ALLOC];
        for (uint256 i = 0; i < 2; i++) {
            // zero out the other gold score so the intended gold index is the winner (ties go to the lower idx)
            vm.prank(owner);
            shAgg.writeScore(ShariahScoreAggregator.ShariahStrategy(golds[1 - i]), 0, bytes32(0), 0);
            _score(golds[i], 7);
            vm.expectRevert(RiskTieredExecutor.NonAtomicGoldExchange.selector);
            ex.executeWinner();
        }
        assertEq(ex.lastExecutionTime(), 0, "no execution recorded");
        assertEq(messenger.callCount(), 0);
    }

    function test_d_conservative_goldWinner_nonzeroDomain_reverts() public {
        _goldRevertsForTier(RiskTieredExecutor.RiskTier.SHARIAH_CONSERVATIVE);
    }

    function test_d_dynamic_goldWinner_nonzeroDomain_reverts() public {
        _goldRevertsForTier(RiskTieredExecutor.RiskTier.SHARIAH_DYNAMIC);
    }

    function testFuzz_d_goldWinner_anyNonzeroDomain_reverts(bool pickAlloc, bool dynamicTier, uint32 domain) public {
        domain = uint32(bound(domain, 1, type(uint32).max));
        RiskTieredExecutor ex = _mkExec(
            dynamicTier ? RiskTieredExecutor.RiskTier.SHARIAH_DYNAMIC : RiskTieredExecutor.RiskTier.SHARIAH_CONSERVATIVE
        );
        _score(pickAlloc ? GOLD_ALLOC : GOLD_SPREAD, domain);
        vm.expectRevert(RiskTieredExecutor.NonAtomicGoldExchange.selector);
        ex.executeWinner();
    }

    function _goldDomainZeroLocal(RiskTieredExecutor.RiskTier tier, uint8 idx) internal {
        RiskTieredExecutor ex = _mkExec(tier);
        uint256 before_ = svault.totalDeployed();
        _score(idx, 0);

        vm.expectEmit(true, true, false, true, address(ex));
        emit RiskTieredExecutor.ShariahExecutionTriggered(
            ShariahScoreAggregator.ShariahStrategy(idx), 95, 10_000e6, address(stratAdapter), tier
        );
        ex.executeWinner();
        _assertExecutedLocally(ex, before_);
    }

    // Execute a real onlyVault adapter so permissive mocks cannot hide caller-authorization regressions.
    function test_d_conservative_realGoldAdapter_executesAtomically() public {
        RiskTieredExecutor ex = _mkExec(RiskTieredExecutor.RiskTier.SHARIAH_CONSERVATIVE);
        vm.prank(owner);
        ex.setShariahStrategyConfig(GOLD_SPREAD, address(goldAdapter), _bytes32(alice), true, 1, 10_000e6);
        _score(GOLD_SPREAD, 0);
        uint256 heldBefore = goldAdapter.paxgHeld();
        uint256 deployedBefore = svault.totalDeployed();
        ex.executeWinner();
        assertGt(goldAdapter.paxgHeld(), heldBefore);
        assertEq(usdc.balanceOf(address(goldAdapter)), 0);
        assertEq(svault.totalDeployed(), deployedBefore + 10_000e6);
        assertEq(svault.totalPendingCrossChain(), 0);
    }

    // An authorized adapter callback must not nest the atomic entry point, and failure must clear the lock.
    function test_atomicDeployment_reentryRevertsAndRollsBack() public {
        vm.startPrank(owner);
        svault.setManager(address(stratAdapter));
        svault.setScreened(address(stratAdapter), true);
        stratAdapter.setReenter(true);
        uint256 before_ = svault.totalDeployed();
        vm.expectRevert(ShariahVault.AdapterExecutionReentered.selector);
        svault.deployCapitalAndExecute(address(stratAdapter), 1_000e6, "");
        assertEq(svault.totalDeployed(), before_);
        assertEq(usdc.balanceOf(address(stratAdapter)), 0);
        stratAdapter.setReenter(false);
        svault.deployCapitalAndExecute(address(stratAdapter), 1_000e6, "");
        vm.stopPrank();
        assertEq(svault.totalDeployed(), before_ + 1_000e6);
    }

    function test_d_conservative_goldSpread_domainZero_executesLocally() public {
        _goldDomainZeroLocal(RiskTieredExecutor.RiskTier.SHARIAH_CONSERVATIVE, GOLD_SPREAD);
    }

    function test_d_conservative_goldAlloc_domainZero_executesLocally() public {
        _goldDomainZeroLocal(RiskTieredExecutor.RiskTier.SHARIAH_CONSERVATIVE, GOLD_ALLOC);
    }

    function test_d_dynamic_goldSpread_domainZero_executesLocally() public {
        _goldDomainZeroLocal(RiskTieredExecutor.RiskTier.SHARIAH_DYNAMIC, GOLD_SPREAD);
    }

    function test_d_dynamic_goldAlloc_domainZero_executesLocally() public {
        _goldDomainZeroLocal(RiskTieredExecutor.RiskTier.SHARIAH_DYNAMIC, GOLD_ALLOC);
    }

    function test_d_conservative_nonGold_nonzeroDomain_executesLocally() public {
        RiskTieredExecutor ex = _mkExec(RiskTieredExecutor.RiskTier.SHARIAH_CONSERVATIVE);
        uint256 before_ = svault.totalDeployed();
        _score(HALAL_LP, 7);
        ex.executeWinner();
        _assertExecutedLocally(ex, before_);
    }

    function testFuzz_d_dynamic_nonGold_nonzeroDomain_executesLocally(uint8 pick, uint32 domain) public {
        domain = uint32(bound(domain, 1, type(uint32).max));
        uint8[3] memory nonGold = [ETH_SPREAD, HALAL_LP, MURABAHA];
        RiskTieredExecutor ex = _mkExec(RiskTieredExecutor.RiskTier.SHARIAH_DYNAMIC);
        uint256 before_ = svault.totalDeployed();
        _score(nonGold[pick % 3], domain);
        ex.executeWinner();
        _assertExecutedLocally(ex, before_);
    }

    function test_d_higherScoredNonGoldWinsOverRemoteGold_executesLocally() public {
        // Gold score 90 w/ remote domain would win -> revert; a higher non-gold score wins -> local.
        RiskTieredExecutor ex = _mkExec(RiskTieredExecutor.RiskTier.SHARIAH_DYNAMIC);
        _score(GOLD_SPREAD, 9);
        vm.prank(owner);
        shAgg.writeScore(ShariahScoreAggregator.ShariahStrategy.HALAL_LP, 99, keccak256("lp"), 0);
        uint256 before_ = svault.totalDeployed();
        ex.executeWinner();
        _assertExecutedLocally(ex, before_);
    }

    function test_d_conventionalTier_routingUnchanged_crossChainViaPlainDeploy() public {
        RiskTieredExecutor ex = new RiskTieredExecutor(
            address(svault), address(conv), RiskTieredExecutor.RiskTier.PASSIVE, owner
        );
        vm.startPrank(owner);
        svault.setManager(address(ex));
        ex.setStrategyConfig(
            ScoreAggregator.Strategy.STABLECOIN_SPREAD, address(stratAdapter), _bytes32(alice), true, 1, 10_000e6
        );
        conv.writeScore(ScoreAggregator.Strategy.STABLECOIN_SPREAD, 95, keccak256("c"), DEST_DOMAIN);
        vm.stopPrank();

        // Task M: predict the next local position ID for pending/event assertions.
        uint64 nonce = svault.crossChainPositionCounter() + 1;
        ex.executeWinner(); // gold held in both adapters; plain deployCrossChain is not gold-blocked
        assertEq(svault.pendingCrossChain(nonce), 10_000e6);
        assertEq(svault.pendingCrossChainDestinationDomain(nonce), DEST_DOMAIN);
        assertEq(svault.totalPendingCrossChain(), 10_000e6);
        assertEq(usdc.balanceOf(address(stratAdapter)), 0);
    }

    function test_d_conventionalTier_domainZero_executesLocally() public {
        RiskTieredExecutor ex = new RiskTieredExecutor(
            address(svault), address(conv), RiskTieredExecutor.RiskTier.PASSIVE, owner
        );
        vm.startPrank(owner);
        svault.setManager(address(ex));
        svault.setScreened(address(stratAdapter), true);
        ex.setStrategyConfig(
            ScoreAggregator.Strategy.STABLECOIN_SPREAD, address(stratAdapter), _bytes32(alice), true, 1, 10_000e6
        );
        conv.writeScore(ScoreAggregator.Strategy.STABLECOIN_SPREAD, 95, keccak256("c"), 0);
        vm.stopPrank();

        uint256 before_ = svault.totalDeployed();
        ex.executeWinner();
        _assertExecutedLocally(ex, before_);
    }
}
