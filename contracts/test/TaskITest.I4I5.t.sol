// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title  TaskI — Items I4 & I5: Single-source board role + Registry constructor board param
/// @notice Tests 21-28 from the Task-I specification.

import {TaskITestBase} from "./TaskITest.Base.t.sol";
import {CharityModule}          from "../CharityModule.sol";
import {PurificationEscrow}     from "../PurificationEscrow.sol";
import {ShariahAdapterRegistry} from "../ShariahAdapterRegistry.sol";

contract TaskITest_I4I5 is TaskITestBase {

    // ─────────────────────────────────────────────────────────────────────────
    // I4 — Test 21: registry board member (not owner) can proposeCharityWalletChange
    // ─────────────────────────────────────────────────────────────────────────
    function test_I4_registry_board_can_propose_charityWallet() public {
        // boardMember is in registry (set at construction in setUp)
        assertTrue(registry.isBoard(boardMember), "boardMember should be in registry");

        address newWallet = makeAddr("newWallet");

        // boardMember (not owner) can propose
        vm.prank(boardMember);
        charity.proposeCharityWalletChange(newWallet);

        assertEq(charity.pendingCharityWallet(), newWallet, "pending wallet should be set");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // I4 — Test 22: non-board, non-owner cannot proposeCharityWalletChange
    // ─────────────────────────────────────────────────────────────────────────
    function test_I4_non_board_non_owner_cannot_propose_charity() public {
        address newWallet = makeAddr("newWallet");

        vm.prank(nonBoard);
        vm.expectRevert(
            abi.encodeWithSelector(CharityModule.NotBoardOrOwner.selector, nonBoard)
        );
        charity.proposeCharityWalletChange(newWallet);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // I4 — Test 23: board change propagates to CharityModule via registry
    // A new board member granted by registry can propose charity changes.
    // ─────────────────────────────────────────────────────────────────────────
    function test_I4_registry_board_change_propagates_to_charity() public {
        address newBoardMember = makeAddr("newBoardMember");

        // boardMember proposes to grant newBoardMember board role
        vm.prank(boardMember);
        registry.proposeBoardRoleChange(newBoardMember, true);

        // Warp past timelock
        vm.warp(block.timestamp + registry.TIMELOCK_PERIOD() + 1);

        // Execute the proposal
        vm.prank(boardMember);
        registry.executeBoardRoleChange(newBoardMember);

        assertTrue(registry.isBoard(newBoardMember), "newBoardMember should be board after grant");

        // Now newBoardMember can propose charity changes
        address newWallet = makeAddr("newWallet2");
        vm.prank(newBoardMember);
        charity.proposeCharityWalletChange(newWallet);

        assertEq(charity.pendingCharityWallet(), newWallet, "new board member can propose");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // I4 — Test 24: registry board member can proposePurificationRate on Escrow
    // ─────────────────────────────────────────────────────────────────────────
    function test_I4_registry_board_can_propose_purification_rate() public {
        // boardMember is in registry → can call proposePurificationRate
        vm.prank(boardMember);
        escrow.proposePurificationRate(100); // 1%

        (uint256 newBps, uint256 executeAfter, bool exists) = escrow.pendingRateChange();
        assertTrue(exists, "pending rate change should exist");
        assertEq(newBps, 100, "newBps should be 100");
        assertGt(executeAfter, 0, "executeAfter should be set");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // I4 — Test 25: owner alone cannot propose when registry is set and owner is not board
    // ─────────────────────────────────────────────────────────────────────────
    // setUp: registry = new ShariahAdapterRegistry(owner, boardMember)
    //        → owner does NOT have boardRole (I5 requirement)
    //        → escrow.boardRegistry = registry
    //   onlyBoard checks registry.isBoard(msg.sender) when boardRegistry != 0
    //   registry.isBoard(owner) == false  → revert NotBoardRole
    function test_I4_owner_alone_cannot_propose_when_registry_set_and_not_board() public {
        assertFalse(registry.isBoard(owner), "owner should NOT be board (I5)");

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(PurificationEscrow.NotBoardRole.selector, owner)
        );
        escrow.proposePurificationRate(50);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // I5 — Test 26: deployer (owner) does NOT get boardRole; initialBoardMember does
    // ─────────────────────────────────────────────────────────────────────────
    function test_I5_deployer_not_board_by_default() public {
        address deployer      = makeAddr("deployer");
        address boardMultisig = makeAddr("boardMultisig");

        // Deploy a fresh registry where deployer != boardMultisig
        ShariahAdapterRegistry reg = new ShariahAdapterRegistry(deployer, boardMultisig);

        assertFalse(reg.boardRole(deployer),      "deployer must NOT have boardRole");
        assertTrue( reg.boardRole(boardMultisig), "boardMultisig must have boardRole");
        assertEq(reg.owner(), deployer,           "deployer is still the owner");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // I5 — Test 27: owner (not board) cannot call proposeBoardRoleChange
    // ─────────────────────────────────────────────────────────────────────────
    function test_I5_owner_cannot_propose_board_change_when_not_board() public {
        address deployer      = makeAddr("deployer2");
        address boardMultisig = makeAddr("boardMultisig2");
        address target        = makeAddr("target");

        ShariahAdapterRegistry reg = new ShariahAdapterRegistry(deployer, boardMultisig);

        // deployer is owner but NOT board → proposeBoardRoleChange must revert
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(ShariahAdapterRegistry.NotBoardRole.selector, deployer)
        );
        reg.proposeBoardRoleChange(target, true);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // I5 — Test 28: boardMultisig (board member) can call proposeBoardRoleChange
    // ─────────────────────────────────────────────────────────────────────────
    function test_I5_board_multisig_can_propose() public {
        address deployer      = makeAddr("deployer3");
        address boardMultisig = makeAddr("boardMultisig3");
        address target        = makeAddr("target3");

        ShariahAdapterRegistry reg = new ShariahAdapterRegistry(deployer, boardMultisig);

        vm.prank(boardMultisig);
        reg.proposeBoardRoleChange(target, true);

        (bool grant, uint256 executeAfterP, bool exists) = reg.boardRoleProposals(target);
        assertTrue(exists, "proposal should exist");
        assertTrue(grant,  "proposal.grant should be true");
        assertGt(executeAfterP, 0, "executeAfter should be set");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Bonus: I4 — owner of CharityModule CAN propose when registry set if owner IS board
    // (Confirms the onlyBoardOrOwner modifier logic — owner-or-board, not owner-and-board)
    // ─────────────────────────────────────────────────────────────────────────
    function test_I4_owner_who_is_also_board_can_propose() public {
        // Grant owner board role via the existing boardMember
        vm.prank(boardMember);
        registry.proposeBoardRoleChange(owner, true);
        vm.warp(block.timestamp + registry.TIMELOCK_PERIOD() + 1);
        vm.prank(boardMember);
        registry.executeBoardRoleChange(owner);

        assertTrue(registry.isBoard(owner), "owner is now also board");

        // Now owner (who is board) can propose charity change
        address newWallet = makeAddr("ownerWallet");
        vm.prank(owner);
        charity.proposeCharityWalletChange(newWallet);
        assertEq(charity.pendingCharityWallet(), newWallet);
    }
}
