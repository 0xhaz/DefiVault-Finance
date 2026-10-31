// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CctpSettlementLogic} from "../AutonomousVault.sol";
import {ShariahAccountingLogic, ShariahGovernanceLogic} from "../ShariahVault.sol";
import {ShariahRegistryLogic} from "../ShariahVaultV2.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";

/// @dev P-6 / audit question 2: the vault's four linked libraries run via DELEGATECALL with storage pointers. Called
///      directly (CALL) at the library address, every state-modifying entry point must revert (Solidity's library
///      call protection), so nobody can operate on the library's own storage or move tokens the library address
///      holds or is approved for. View entry points may be called directly; they only read the library's own
///      (empty) storage. Selectors are from `forge inspect <Library> methodIdentifiers`; mutability from source.
contract LibraryDirectCallP6Test is Test {
    bytes internal pad;

    function setUp() public {
        pad = new bytes(4096); // generous zeroed argument area for every signature
    }

    function _assertDirectCallReverts(address lib, bytes4 sel, string memory name) internal {
        assertGt(lib.code.length, 0, "library is linked and deployed");
        (bool ok,) = lib.call(abi.encodePacked(sel, pad));
        assertFalse(ok, string.concat("direct call must revert: ", name));
    }

    function test_P6_cctpSettlementLogic_mutatingEntryPointsRevertWhenCalledDirectly() public {
        address lib = address(CctpSettlementLogic);
        _assertDirectCallReverts(lib, 0xf12ecfe5, "burn");
        _assertDirectCallReverts(lib, 0x5d7f4b0a, "consumeInbound");
        _assertDirectCallReverts(lib, 0x4aa3ddf4, "receiveSettlement");
    }

    function test_P6_shariahAccountingLogic_mutatingEntryPointsRevertWhenCalledDirectly() public {
        address lib = address(ShariahAccountingLogic);
        _assertDirectCallReverts(lib, 0xc9a324a9, "retireGoldPrincipal");
        _assertDirectCallReverts(lib, 0x235f5552, "bookWakalaFee");
        _assertDirectCallReverts(lib, 0x3023273a, "bookPrincipal");
        _assertDirectCallReverts(lib, 0x2b3359ce, "returnCapital");
        _assertDirectCallReverts(lib, 0x67e7062f, "writeOff");
        _assertDirectCallReverts(lib, 0xf7ff58ad, "executeWaterfall");
        _assertDirectCallReverts(lib, 0xd014748e, "sweepFees");
        _assertDirectCallReverts(lib, 0x4cfbcdd9, "recall");
        _assertDirectCallReverts(lib, 0x387cfccd, "replaceGoldAdapter");
        _assertDirectCallReverts(lib, 0x4b11ec07, "deployCapital");
    }

    function test_P6_shariahGovernanceLogic_mutatingEntryPointsRevertWhenCalledDirectly() public {
        address lib = address(ShariahGovernanceLogic);
        _assertDirectCallReverts(lib, 0xc4080a08, "proposeRemoteRecipient");
        _assertDirectCallReverts(lib, 0x10f45edd, "confirmRemoteRecipient");
        _assertDirectCallReverts(lib, 0x7fed6034, "cancelRemoteRecipient");
        _assertDirectCallReverts(lib, 0xe10ca35e, "proposeDustThreshold");
        _assertDirectCallReverts(lib, 0x5642ccc9, "cancelDustThreshold");
    }

    function test_P6_shariahRegistryLogic_mutatingEntryPointsRevertWhenCalledDirectly() public {
        address lib = address(ShariahRegistryLogic);
        _assertDirectCallReverts(lib, 0xbc47b3c3, "propose");
        _assertDirectCallReverts(lib, 0x63685f49, "confirm");
        _assertDirectCallReverts(lib, 0x2e8e0f32, "cancel");
    }

    /// Concrete attack: a victim mistakenly approves the library address itself. Calling returnCapital directly
    /// with a crafted pull (storage pointers passed as raw slot numbers) must not move the victim's tokens.
    function test_P6_directReturnCapital_cannotPullThroughApprovalToLibrary() public {
        MockERC20 token = new MockERC20("T", "T", 6);
        address victim = makeAddr("victim");
        address lib = address(ShariahAccountingLogic);
        token.mint(victim, 1_000e6);
        vm.prank(victim);
        token.approve(lib, type(uint256).max);

        bytes memory data = abi.encodeWithSelector(
            bytes4(0x2b3359ce), uint256(0), uint256(1), uint256(2), address(token), victim, uint256(1_000e6)
        );
        (bool ok,) = lib.call(data);
        assertFalse(ok, "library call protection blocks the direct pull");
        assertEq(token.balanceOf(victim), 1_000e6);
        assertEq(token.balanceOf(lib), 0);
    }

    /// Control: a view entry point is callable directly and only sees the library's own empty storage.
    function test_P6_viewEntryPointDirectCall_isHarmless() public view {
        (bool ok, bytes memory ret) = address(ShariahAccountingLogic).staticcall(
            abi.encodeWithSelector(bytes4(0x8fd8ae16), uint256(0), uint256(1)) // unrealizedAdapterLoss(slot, slot)
        );
        assertTrue(ok);
        assertEq(abi.decode(ret, (uint256)), 0, "empty library storage: no funded adapters, zero loss");
    }
}
