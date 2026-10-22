// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ShariahAdapterRegistry} from "../ShariahAdapterRegistry.sol";

/// @title ShariahAdapterRegistryTest
/// @notice Unit tests for ShariahAdapterRegistry — Task E
contract ShariahAdapterRegistryTest is Test {

    // ── actors ────────────────────────────────────────────────────
    address internal deployer = makeAddr("deployer");
    address internal other    = makeAddr("other");

    // ── contract under test ───────────────────────────────────────
    ShariahAdapterRegistry internal registry;

    // ── constants ─────────────────────────────────────────────────
    address internal constant ADAPTER     = address(0x42);
    bytes32 internal constant HASH        = keccak256("SR-005");
    uint256 internal constant TIMELOCK    = 30 days;
    uint256 internal constant VALID_EXPIRY_OFFSET = 365 days;

    // ─────────────────────────────────────────────────────────────
    // setUp — runs before every test
    // ─────────────────────────────────────────────────────────────

    function setUp() public {
        vm.prank(deployer);
        registry = new ShariahAdapterRegistry(deployer);
        // deployer has boardRole automatically (set in constructor)
    }

    // ─────────────────────────────────────────────────────────────
    // 1. isScreened false by default
    // ─────────────────────────────────────────────────────────────

    function test_isScreened_false_by_default() public view {
        assertFalse(registry.isScreened(ADAPTER));
    }

    // ─────────────────────────────────────────────────────────────
    // 2. isScreened false after propose before execute
    // ─────────────────────────────────────────────────────────────

    function test_isScreened_false_after_propose_before_execute() public {
        vm.prank(deployer);
        registry.proposeScreening(ADAPTER, HASH, block.timestamp + VALID_EXPIRY_OFFSET);

        // Proposal exists but not executed yet — screening not live
        assertFalse(registry.isScreened(ADAPTER));
    }

    // ─────────────────────────────────────────────────────────────
    // 3. isScreened true after propose + warp + execute
    // ─────────────────────────────────────────────────────────────

    function test_isScreened_true_after_execute() public {
        uint256 expiresAt = block.timestamp + VALID_EXPIRY_OFFSET;

        vm.prank(deployer);
        registry.proposeScreening(ADAPTER, HASH, expiresAt);

        vm.warp(block.timestamp + TIMELOCK);

        vm.prank(deployer);
        registry.executeScreening(ADAPTER);

        assertTrue(registry.isScreened(ADAPTER));
    }

    // ─────────────────────────────────────────────────────────────
    // 4. isScreened false after screening expires
    // ─────────────────────────────────────────────────────────────

    function test_isScreened_false_after_expiry() public {
        uint256 expiresAt = block.timestamp + VALID_EXPIRY_OFFSET;

        vm.prank(deployer);
        registry.proposeScreening(ADAPTER, HASH, expiresAt);

        vm.warp(block.timestamp + TIMELOCK);

        vm.prank(deployer);
        registry.executeScreening(ADAPTER);

        // Warp to exact expiry — isScreened checks block.timestamp < expiresAt
        vm.warp(expiresAt);
        assertFalse(registry.isScreened(ADAPTER));
    }

    // ─────────────────────────────────────────────────────────────
    // 5. Non-board address cannot propose
    // ─────────────────────────────────────────────────────────────

    function test_nonBoard_propose_reverts() public {
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(ShariahAdapterRegistry.NotBoardRole.selector, other));
        registry.proposeScreening(ADAPTER, HASH, block.timestamp + VALID_EXPIRY_OFFSET);
    }

    // ─────────────────────────────────────────────────────────────
    // 6. Execute before timelock reverts TimelockNotElapsed
    // ─────────────────────────────────────────────────────────────

    function test_execute_before_timelock_reverts() public {
        vm.prank(deployer);
        registry.proposeScreening(ADAPTER, HASH, block.timestamp + VALID_EXPIRY_OFFSET);

        uint256 executeAfter = block.timestamp + TIMELOCK;

        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ShariahAdapterRegistry.TimelockNotElapsed.selector,
                executeAfter,
                block.timestamp
            )
        );
        registry.executeScreening(ADAPTER);
    }

    // ─────────────────────────────────────────────────────────────
    // 7. Execute with no pending proposal reverts NoPendingProposal
    // ─────────────────────────────────────────────────────────────

    function test_execute_no_proposal_reverts() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(ShariahAdapterRegistry.NoPendingProposal.selector, ADAPTER)
        );
        registry.executeScreening(ADAPTER);
    }

    // ─────────────────────────────────────────────────────────────
    // 8. Double propose reverts AlreadyProposed
    // ─────────────────────────────────────────────────────────────

    function test_double_propose_reverts() public {
        vm.prank(deployer);
        registry.proposeScreening(ADAPTER, HASH, block.timestamp + VALID_EXPIRY_OFFSET);

        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(ShariahAdapterRegistry.AlreadyProposed.selector, ADAPTER)
        );
        registry.proposeScreening(ADAPTER, HASH, block.timestamp + VALID_EXPIRY_OFFSET);
    }

    // ─────────────────────────────────────────────────────────────
    // 9. Zero hash reverts ZeroHash
    // ─────────────────────────────────────────────────────────────

    function test_zero_hash_reverts() public {
        vm.prank(deployer);
        vm.expectRevert(ShariahAdapterRegistry.ZeroHash.selector);
        registry.proposeScreening(ADAPTER, bytes32(0), block.timestamp + VALID_EXPIRY_OFFSET);
    }

    // ─────────────────────────────────────────────────────────────
    // 10. Zero adapter reverts ZeroAdapter
    // ─────────────────────────────────────────────────────────────

    function test_zero_adapter_reverts() public {
        vm.prank(deployer);
        vm.expectRevert(ShariahAdapterRegistry.ZeroAdapter.selector);
        registry.proposeScreening(address(0), HASH, block.timestamp + VALID_EXPIRY_OFFSET);
    }

    // ─────────────────────────────────────────────────────────────
    // 11. Expiry too far reverts ExpiryTooFar
    // ─────────────────────────────────────────────────────────────

    function test_expiry_too_far_reverts() public {
        uint256 tooFar = block.timestamp + 731 days;
        uint256 maxAllowed = block.timestamp + registry.MAX_EXPIRY_PERIOD();

        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(ShariahAdapterRegistry.ExpiryTooFar.selector, tooFar, maxAllowed)
        );
        registry.proposeScreening(ADAPTER, HASH, tooFar);
    }

    // ─────────────────────────────────────────────────────────────
    // 12. Cancel clears proposal
    // ─────────────────────────────────────────────────────────────

    function test_cancel_clears_proposal() public {
        vm.prank(deployer);
        registry.proposeScreening(ADAPTER, HASH, block.timestamp + VALID_EXPIRY_OFFSET);

        // Proposal exists before cancel
        (,, , bool existsBefore) = registry.proposals(ADAPTER);
        assertTrue(existsBefore);

        vm.prank(deployer);
        registry.cancelProposal(ADAPTER);

        // Proposal gone after cancel
        (,, , bool existsAfter) = registry.proposals(ADAPTER);
        assertFalse(existsAfter);
    }

    // ─────────────────────────────────────────────────────────────
    // 13. Removal before timelock reverts TimelockNotElapsed
    // ─────────────────────────────────────────────────────────────

    function test_removal_before_timelock_reverts() public {
        // First screen the adapter
        vm.prank(deployer);
        registry.proposeScreening(ADAPTER, HASH, block.timestamp + VALID_EXPIRY_OFFSET);
        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(deployer);
        registry.executeScreening(ADAPTER);

        // Propose removal
        vm.prank(deployer);
        registry.proposeRemoval(ADAPTER);

        uint256 executeAfter = block.timestamp + TIMELOCK;

        // Try to execute immediately
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ShariahAdapterRegistry.TimelockNotElapsed.selector,
                executeAfter,
                block.timestamp
            )
        );
        registry.executeRemoval(ADAPTER);
    }

    // ─────────────────────────────────────────────────────────────
    // 14. Removal after timelock succeeds — isScreened false after
    // ─────────────────────────────────────────────────────────────

    function test_removal_after_timelock_succeeds() public {
        // Screen the adapter first
        uint256 expiresAt = block.timestamp + VALID_EXPIRY_OFFSET;
        vm.prank(deployer);
        registry.proposeScreening(ADAPTER, HASH, expiresAt);
        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(deployer);
        registry.executeScreening(ADAPTER);
        assertTrue(registry.isScreened(ADAPTER), "should be screened before removal");

        // Propose and execute removal
        vm.prank(deployer);
        registry.proposeRemoval(ADAPTER);
        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(deployer);
        registry.executeRemoval(ADAPTER);

        // Screening entry deleted
        assertFalse(registry.isScreened(ADAPTER), "should not be screened after removal");
        ShariahAdapterRegistry.Screening memory s = registry.getScreening(ADAPTER);
        assertEq(s.pronouncementHash, bytes32(0));
        assertEq(s.expiresAt, 0);
    }

    // ─────────────────────────────────────────────────────────────
    // 15. Grant and revoke board role via propose/timelock/execute (G4)
    // ─────────────────────────────────────────────────────────────

    function test_grant_revoke_board_role() public {
        // Initially `other` has no board role
        assertFalse(registry.boardRole(other));

        // Board member (deployer) proposes granting board role to `other`
        vm.prank(deployer);
        registry.proposeBoardRoleChange(other, true);

        // Proposal exists but not executed yet — board role not granted
        assertFalse(registry.boardRole(other));

        // Warp past the 30-day timelock and execute
        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(deployer);
        registry.executeBoardRoleChange(other);
        assertTrue(registry.boardRole(other));

        // Board member (deployer) proposes revoking board role from `other`
        vm.prank(deployer);
        registry.proposeBoardRoleChange(other, false);

        // Warp past the 30-day timelock and execute
        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(deployer);
        registry.executeBoardRoleChange(other);
        assertFalse(registry.boardRole(other));
    }

    // ─────────────────────────────────────────────────────────────
    // 16. getScreening returns correct struct after execute
    // ─────────────────────────────────────────────────────────────

    function test_getScreening_returns_correct_struct() public {
        uint256 expiresAt = block.timestamp + VALID_EXPIRY_OFFSET;

        vm.prank(deployer);
        registry.proposeScreening(ADAPTER, HASH, expiresAt);
        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(deployer);
        registry.executeScreening(ADAPTER);

        ShariahAdapterRegistry.Screening memory s = registry.getScreening(ADAPTER);
        assertEq(s.pronouncementHash, HASH);
        assertEq(s.expiresAt, expiresAt);
        assertGt(s.setAt, 0);
    }

    // ─────────────────────────────────────────────────────────────
    // 17. Non-board address cannot proposeBoardRoleChange (G4)
    // ─────────────────────────────────────────────────────────────

    function test_board_role_not_nonOwner() public {
        // `other` has no board role — proposeBoardRoleChange reverts NotBoardRole
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(ShariahAdapterRegistry.NotBoardRole.selector, other)
        );
        registry.proposeBoardRoleChange(makeAddr("newMember"), true);
    }

    // ─────────────────────────────────────────────────────────────
    // 18. emergencyRevokeBoardRole is owner-only and works instantly (G4)
    // ─────────────────────────────────────────────────────────────

    function test_emergencyRevoke_board_role() public {
        // deployer has board role from constructor
        assertTrue(registry.boardRole(deployer));

        // Owner calls emergencyRevokeBoardRole — instant removal, no timelock
        vm.prank(deployer);
        registry.emergencyRevokeBoardRole(deployer);
        assertFalse(registry.boardRole(deployer));
    }

    // ─────────────────────────────────────────────────────────────
    // 19. cancelBoardRoleChange clears a pending proposal (G4)
    // ─────────────────────────────────────────────────────────────

    function test_cancelBoardRoleChange_clears_proposal() public {
        vm.prank(deployer);
        registry.proposeBoardRoleChange(other, true);

        // Proposal now exists
        (,, bool exists) = registry.boardRoleProposals(other);
        assertTrue(exists, "proposal should exist after propose");

        // Cancel it
        vm.prank(deployer);
        registry.cancelBoardRoleChange(other);

        // Proposal cleared
        (,, bool existsAfter) = registry.boardRoleProposals(other);
        assertFalse(existsAfter, "proposal should be gone after cancel");
    }
}
