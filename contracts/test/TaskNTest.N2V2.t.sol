// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ShariahVault}           from "../ShariahVault.sol";
import {ShariahVaultV2}         from "../ShariahVaultV2.sol";
import {ShariahAdapterRegistry} from "../ShariahAdapterRegistry.sol";
import {TaskNDustBase}          from "./TaskNTest.DustBase.t.sol";
import {TaskNDustCommon}        from "./TaskNTest.N2.t.sol";

/// @dev V2: board == registry.isBoard(account); vault owner is NOT board unless registry says so.
contract TaskNDustV2Test is TaskNDustCommon {
    ShariahAdapterRegistry internal registry;
    address internal newBoard = makeAddr("newBoard");

    function _deployVault() internal override {
        registry = new ShariahAdapterRegistry(owner, boardMember); // owner != board
        v = new ShariahVaultV2(
            IERC20(address(usdc)), owner, SOURCE_DOMAIN, address(treasury), address(0), address(registry)
        );
    }

    function _board() internal view override returns (address) { return boardMember; }

    function _denied() internal view override returns (address[] memory d) {
        d = new address[](4);
        d[0] = alice; d[1] = stranger; d[2] = manager; d[3] = owner;
    }

    function test_v2_registryBoardMember_canDoAllThree() public {
        _setAssets(1_000_000e6);
        vm.startPrank(boardMember);
        v.proposeDustThreshold(2_000e6);
        v.cancelDustThreshold();
        v.proposeDustThreshold(3_000e6);
        vm.warp(block.timestamp + DUST_TIMELOCK);
        v.confirmDustThreshold();
        vm.stopPrank();
        assertEq(v.dustThreshold(), 3_000e6);
    }

    function test_v2_ownerWithoutBoardRole_cannotPropose_confirm_orCancel() public {
        assertFalse(registry.boardRole(owner));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.NotBoardRole.selector, owner));
        v.proposeDustThreshold(1e6);

        _propose(1e6);
        vm.warp(block.timestamp + DUST_TIMELOCK);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.NotBoardRole.selector, owner));
        v.confirmDustThreshold();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.NotBoardRole.selector, owner));
        v.cancelDustThreshold();
    }

    function test_v2_zeroRegistry_atConstruction_deniesEveryone() public {
        ShariahVaultV2 z = new ShariahVaultV2(
            IERC20(address(usdc)), owner, SOURCE_DOMAIN, address(treasury), address(0), address(0)
        );
        address[5] memory who = [owner, boardMember, alice, stranger, address(0)];
        for (uint256 i = 0; i < who.length; i++) {
            vm.startPrank(who[i]);
            vm.expectRevert(abi.encodeWithSelector(ShariahVault.NotBoardRole.selector, who[i]));
            z.proposeDustThreshold(0);
            vm.expectRevert(abi.encodeWithSelector(ShariahVault.NotBoardRole.selector, who[i]));
            z.confirmDustThreshold();
            vm.expectRevert(abi.encodeWithSelector(ShariahVault.NotBoardRole.selector, who[i]));
            z.cancelDustThreshold();
            bytes32 recipient = bytes32(uint256(uint160(alice)));
            vm.expectRevert(abi.encodeWithSelector(ShariahVault.NotBoardRole.selector, who[i]));
            z.proposeRemoteRecipient(0, recipient, true);
            vm.expectRevert(abi.encodeWithSelector(ShariahVault.NotBoardRole.selector, who[i]));
            z.confirmRemoteRecipient(0, recipient);
            vm.expectRevert(abi.encodeWithSelector(ShariahVault.NotBoardRole.selector, who[i]));
            z.cancelRemoteRecipient(0, recipient);
            vm.stopPrank();
        }
    }

    function test_v2_proposeZeroRegistry_reverts_andKeepsDustProposal() public {
        _setAssets(1_000_000e6);
        _propose(2_000e6);
        vm.prank(boardMember);
        vm.expectRevert(ShariahVaultV2.ZeroRegistry.selector);
        ShariahVaultV2(address(v)).proposeRegistry(address(0));

        assertEq(address(ShariahVaultV2(address(v)).registry()), address(registry));
        (, , bool exists) = _pending();
        assertTrue(exists);
        vm.warp(block.timestamp + DUST_TIMELOCK);
        _confirm();
        assertEq(v.dustThreshold(), 2_000e6);
    }

    function test_v2_membershipRevoked_deniesLaterCalls_proposalKept() public {
        _setAssets(1_000_000e6);
        _propose(2_000e6);

        vm.prank(owner); // registry owner = owner
        registry.emergencyRevokeBoardRole(boardMember);

        vm.warp(block.timestamp + DUST_TIMELOCK);
        vm.startPrank(boardMember);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.NotBoardRole.selector, boardMember));
        v.confirmDustThreshold();
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.NotBoardRole.selector, boardMember));
        v.cancelDustThreshold();
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.NotBoardRole.selector, boardMember));
        v.proposeDustThreshold(1e6);
        vm.stopPrank();
        (, , bool exists) = _pending();
        assertTrue(exists, "proposal survives revocation");
    }

    function test_v2_membershipGranted_newMemberCanActOnExistingProposal() public {
        _setAssets(1_000_000e6);
        _propose(2_000e6);

        // board adds newBoard through the registry's own 30-day flow
        vm.prank(newBoard);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.NotBoardRole.selector, newBoard));
        v.cancelDustThreshold();

        vm.prank(boardMember);
        registry.proposeBoardRoleChange(newBoard, true);
        vm.warp(block.timestamp + 30 days);
        vm.prank(boardMember);
        registry.executeBoardRoleChange(newBoard);

        vm.prank(newBoard);
        v.confirmDustThreshold();
        assertEq(v.dustThreshold(), 2_000e6);

        vm.prank(newBoard);
        v.proposeDustThreshold(1_000e6);
        vm.prank(newBoard);
        v.cancelDustThreshold();
    }

    function test_v2_replacedRegistry_changesWhoIsBoard() public {
        ShariahAdapterRegistry r2 = new ShariahAdapterRegistry(owner, owner);
        ShariahVaultV2 v2 = ShariahVaultV2(address(v));
        _propose(1e6);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.NotBoardRole.selector, owner));
        v2.proposeRegistry(address(r2));
        vm.prank(boardMember);
        v2.proposeRegistry(address(r2));
        vm.warp(block.timestamp + DUST_TIMELOCK);

        // Membership in the proposed registry grants no authority before confirmation.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.NotBoardRole.selector, owner));
        v2.confirmRegistry();
        vm.prank(boardMember);
        vm.expectEmit(false, false, false, true, address(v));
        emit ShariahVault.DustThresholdProposalCancelled();
        v2.confirmRegistry();
        (, , bool exists) = _pending();
        assertFalse(exists, "old governance proposal cleared");

        vm.prank(boardMember);
        vm.expectRevert(abi.encodeWithSelector(ShariahVault.NotBoardRole.selector, boardMember));
        v.proposeDustThreshold(1e6);

        vm.prank(owner);
        v.proposeDustThreshold(1e6);
        (uint256 nv, , bool newExists) = _pending();
        assertEq(nv, 1e6);
        assertTrue(newExists);
    }
}
