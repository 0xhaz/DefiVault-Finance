// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, StdStorage, stdStorage} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ShariahVault} from "../ShariahVault.sol";
import {ShariahVaultV2} from "../ShariahVaultV2.sol";
import {ShariahAdapterRegistry} from "../ShariahAdapterRegistry.sol";
import {TreasuryModule} from "../TreasuryModule.sol";
import {CharityModule} from "../CharityModule.sol";
import {PurificationEscrow} from "../PurificationEscrow.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {MockRegistrySRF} from "./SecurityReviewFixesTest.t.sol";

/// @dev N-26 fixture: NON-ZERO hurdle (4%/yr, 10% manager share), hurdlePrincipal seeded to the deposit.
///      Shared setup + helpers only; no test functions (category files inherit this).
abstract contract TaskN26Base is Test {
    using stdStorage for StdStorage;

    address internal owner = makeAddr("owner");
    address internal manager = makeAddr("manager");
    address internal alice = makeAddr("alice");
    address internal charityWallet = makeAddr("charityWallet");
    uint32 internal constant DOM = 26;
    uint256 internal constant DEP = 1_000e6;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant RATE = 400; // hurdle bps
    uint256 internal constant SHARE = 1000; // manager share bps

    MockERC20 internal usdc;
    MockRegistrySRF internal reg;
    ShariahAdapterRegistry internal registry;
    TreasuryModule internal treasury;
    ShariahVault internal vault;
    CharityModule internal charity;
    PurificationEscrow internal escrow;

    function _newVault() internal virtual returns (ShariahVault);

    function setUp() public virtual {
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);
        reg = new MockRegistrySRF(owner);
        registry = new ShariahAdapterRegistry(owner, owner);

        uint256 n = vm.getNonce(address(this));
        address escrowAddr = vm.computeCreateAddress(address(this), n + 3);
        address vaultAddr = vm.computeCreateAddress(address(this), n + 1);
        treasury = new TreasuryModule("Shariah", escrowAddr, address(usdc), 50, SHARE, RATE, vaultAddr);
        vault = _newVault();
        charity = new CharityModule(charityWallet, address(usdc), escrowAddr, owner, address(reg));
        escrow = new PurificationEscrow(
            address(vault), address(usdc), address(charity), address(treasury), owner, address(reg)
        );
        assertEq(address(vault), vaultAddr);
        assertEq(address(escrow), escrowAddr);

        vm.startPrank(owner);
        vault.setPurificationEscrow(address(escrow));
        vault.setManager(manager);
        vm.stopPrank();
        vm.startPrank(address(vault));
        treasury.setAdminFeeBps(0); // isolate from time-based wakala fees
        treasury.setMusharakahParams(SHARE, RATE); // non-zero hurdle (explicit)
        vm.stopPrank();

        usdc.mint(alice, 100_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);

        _deposit(DEP);
        // Initial hurdlePrincipal is 0 on a fresh vault; seed it so the hurdle is live from deploy time.
        vm.prank(owner);
        vault.setHurdlePrincipal(DEP);
    }

    /// @dev Test-only: set the hurdle basis by storage write (the setter refuses decreases on a live vault).
    function _forceHurdlePrincipal(uint256 v) internal {
        stdstore.target(address(vault)).sig("hurdlePrincipal()").checked_write(v);
    }

    function _deposit(uint256 amount) internal {
        vm.prank(alice);
        vault.deposit(amount, alice);
    }

    function _claim(uint256 gross) internal {
        vm.prank(owner);
        vault.claimMusharakahProfit(gross);
    }

    /// @dev Claim and return the manager fee delta (treasury.pendingFees).
    function _claimFee(uint256 gross) internal returns (uint256 fee) {
        uint256 before = treasury.pendingFees();
        _claim(gross);
        fee = treasury.pendingFees() - before;
    }

    /// @dev Net after purification (0 bps) and charity, mirroring the escrow waterfall.
    function _net(uint256 gross) internal view returns (uint256) {
        return gross - (gross * charity.charityBps()) / 10_000;
    }

    /// @dev Elapsed-time hurdle on the CURRENT vault checkpoint (same floor as TreasuryModule).
    function _hurdleNow() internal view returns (uint256) {
        return (vault.hurdlePrincipal() * treasury.hurdleRateBps() * (block.timestamp - vault.hurdleStartTime()))
            / (10_000 * YEAR);
    }

    /// @dev Manager fee the treasury formula predicts for claiming `gross` right now.
    function _expectedFee(uint256 gross) internal view returns (uint256 fee) {
        (, fee,) = treasury.calculateMusharakahSplitHWM(
            _net(gross), block.timestamp - vault.hurdleStartTime(), vault.hurdlePrincipal(), vault.hwmDeficit()
        );
    }

    /// @dev Mint `profit` into the vault after `elapsed` seconds have passed.
    function _accrue(uint256 elapsed, uint256 profit) internal {
        skip(elapsed);
        usdc.mint(address(vault), profit);
    }

    /// @dev Claim `total` in `n` equal chunks (remainder on the last) at one timestamp; returns summed fee.
    function _claimInChunks(uint256 total, uint256 n) internal returns (uint256 fee) {
        uint256 chunk = total / n;
        uint256 done;
        for (uint256 i; i < n; ++i) {
            uint256 g = i == n - 1 ? total - done : chunk;
            fee += _claimFee(g);
            done += g;
            assertLe(vault.hurdleStartTime(), block.timestamp, "start never exceeds now");
        }
    }

    /// @dev Single full claim vs `n` chunk claims at the same timestamp. Returns (full, split).
    function _fullVsChunks(uint256 total, uint256 n) internal returns (uint256 full, uint256 split) {
        uint256 snap = vm.snapshot();
        full = _claimFee(total);
        assertTrue(vm.revertTo(snap));
        split = _claimInChunks(total, n);
    }
}
