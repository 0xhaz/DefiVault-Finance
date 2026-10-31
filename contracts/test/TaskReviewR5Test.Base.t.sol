// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ShariahVault} from "../ShariahVault.sol";
import {PurificationEscrow} from "../PurificationEscrow.sol";
import {TaskN29Base} from "./TaskN29Test.Base.t.sol";
import {HostileCharityN29, HostileTreasuryN29} from "./TaskN29Test.Hostile.t.sol";

/// @dev Strategy adapter whose currentValue() read burns a configurable amount of gas (realistic heavy valuation).
contract GasAdapterR5 {
    IERC20 internal immutable token;
    uint256 public immutable burn;

    constructor(IERC20 token_, uint256 burn_) {
        token = token_;
        burn = burn_;
    }

    function currentValue() external view returns (uint256) {
        uint256 g = gasleft();
        uint256 target = burn;
        while (g - gasleft() < target) {}
        return token.balanceOf(address(this));
    }
}

/// @dev Review R5: the exit-settlement gas floor (InsufficientExitGas) and the gas probes around it.
abstract contract TaskR5Base is TaskN29Base {
    /// @dev Mirrors the contract's internal EXIT_SETTLE_GAS.
    uint256 internal constant SETTLE_GAS = 700_000;
    /// @dev Mirrors the contract's internal EXIT_SETTLE_GAS_PER_ADAPTER.
    uint256 internal constant SETTLE_GAS_PER_ADAPTER = 250_000;
    uint256 internal constant SEARCH_CEILING = 12_000_000;
    uint256 internal constant SCAN_STEP = 500_000;

    GasAdapterR5[] internal adapters;

    /// @dev Expected exit gas floor: 2 * (700k + funded adapters * 250k). Every adapter created here is funded.
    function _floor() internal view returns (uint256) {
        return 2 * (SETTLE_GAS + adapters.length * SETTLE_GAS_PER_ADAPTER);
    }

    /// @dev Fund `n` adapters with 20e6 each; `burn` gas is consumed by each valuation read.
    function _adapters(uint256 n, uint256 burn) internal {
        for (uint256 i; i < n; ++i) {
            GasAdapterR5 a = new GasAdapterR5(IERC20(address(usdc)), burn);
            adapters.push(a);
            vm.startPrank(owner);
            vault.setScreened(address(a), true); // V1 screening
            registry.proposeScreening(address(a), keccak256("R5"), block.timestamp + 365 days); // V2 screening
            vm.stopPrank();
        }
        skip(30 days + 1);
        for (uint256 i; i < n; ++i) {
            vm.startPrank(owner);
            registry.executeScreening(address(adapters[i]));
            vault.deployCapital(address(adapters[i]), 20e6, "");
            vm.stopPrank();
        }
    }

    function _distNow() internal view returns (uint256) {
        return charity.totalCharityDistributed() + treasury.pendingFees();
    }

    /// @dev Make every touched account/slot cold again so gas matches a fresh transaction.
    function _cool() internal {
        vm.cool(address(vault));
        vm.cool(address(usdc));
        vm.cool(address(escrow));
        vm.cool(address(charity));
        vm.cool(address(treasury));
        vm.cool(address(reg));
        vm.cool(address(registry));
        vm.cool(alice);
        vm.cool(bob);
        vm.cool(charityWallet);
        vm.cool(owner);
        vm.cool(address(vault.purificationEscrow()));
        for (uint256 i; i < adapters.length; ++i) vm.cool(address(adapters[i]));
    }

    /// @dev One exit attempt with an explicit outer gas limit; state is always rolled back.
    /// @return ok the exit did not revert; settled the cut was routed; reason revert selector if any.
    function _attempt(uint256 gasLimit, bool useWithdraw, bool part)
        internal
        returns (bool ok, bool settled, bytes4 reason)
    {
        uint256 shares = vault.balanceOf(bob);
        if (part) shares /= 2;
        uint256 assets = vault.previewRedeem(shares);
        uint256 snap = vm.snapshotState();
        uint256 base = _distNow();
        _cool();
        vm.prank(bob);
        if (useWithdraw) {
            try vault.withdraw{gas: gasLimit}(assets, bob, bob) returns (uint256) {
                ok = true;
            } catch (bytes memory err) {
                reason = err.length >= 4 ? bytes4(err) : bytes4(0);
            }
        } else {
            try vault.redeem{gas: gasLimit}(shares, bob, bob) returns (uint256) {
                ok = true;
            } catch (bytes memory err) {
                reason = err.length >= 4 ? bytes4(err) : bytes4(0);
            }
        }
        settled = _distNow() > base;
        vm.revertToState(snap);
    }

    /// @dev Smallest outer gas for which the exit does not revert (ascending scan then bisect).
    function _minOk(bool useWithdraw, bool part) internal returns (uint256 minG, bool settledThere) {
        (minG, settledThere) = _minOkOrZero(useWithdraw, part);
        require(minG != 0, "never succeeds <= 12M");
    }

    /// @dev Same search, but returns (0,false) when the exit never succeeds up to SEARCH_CEILING.
    function _minOkOrZero(bool useWithdraw, bool part) internal returns (uint256 minG, bool settledThere) {
        uint256 lo = 100_000;
        uint256 hi;
        for (uint256 g = 100_000; g <= SEARCH_CEILING; g += SCAN_STEP) {
            (bool ok,,) = _attempt(g, useWithdraw, part);
            if (ok) {
                hi = g;
                break;
            }
            lo = g;
        }
        if (hi == 0) return (0, false);
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            (bool ok,,) = _attempt(mid, useWithdraw, part);
            if (ok) hi = mid;
            else lo = mid;
        }
        minG = hi;
        (,settledThere,) = _attempt(minG, useWithdraw, part);
    }

    function _useHostile(HostileCharityN29.Mode cm, HostileTreasuryN29.Mode tm) internal {
        HostileCharityN29 hc = new HostileCharityN29(charityWallet, IERC20(address(usdc)));
        hc.setMode(cm);
        HostileTreasuryN29 ht = new HostileTreasuryN29();
        ht.setMode(tm);
        PurificationEscrow e = new PurificationEscrow(
            address(vault), address(usdc), address(hc), address(ht), owner, address(reg)
        );
        vm.prank(owner);
        vault.setPurificationEscrow(address(e));
    }
}
