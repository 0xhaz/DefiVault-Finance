// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ShariahVault} from "../ShariahVault.sol";
import {ShariahVaultV2} from "../ShariahVaultV2.sol";
import {ShariahAdapterRegistry} from "../ShariahAdapterRegistry.sol";
import {TreasuryModule} from "../TreasuryModule.sol";
import {CharityModule} from "../CharityModule.sol";
import {PurificationEscrow} from "../PurificationEscrow.sol";
import {HalalLPAdapter, IHalalSwapRouter} from "../adapters/HalalLPAdapter.sol";
import {ArcNativeCoinShim, ArcBlocklistShim} from "../test-helpers/ArcNativeCoinShim.sol";

/// @title N33-A: full ShariahVaultV2 stack with the real Uniswap V3 LP adapter on an Arc mainnet fork
/// @notice LOCAL FORK ONLY, nothing is broadcast. The vault, registry, treasury, charity and escrow are fresh
///         deployments on the fork; USDC, EURC, the Uniswap V3 factory, position manager, SwapRouter02 and the
///         USDC/EURC 0.05% pool are the real Arc mainnet contracts. The adapter is screened through the real
///         30-day registry flow and funded through the vault, so every read below goes through the vault's
///         bounded staticcall. Skipped unless ARC_MAINNET_RPC is set (ARC_MAINNET_FORK_BLOCK optionally pins).
contract ForkVaultLPArcMainnetTest is Test {
    address internal constant USDC = 0x3600000000000000000000000000000000000000;
    address internal constant EURC = 0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1;
    address internal constant FACTORY = 0xf0db7b58379503491d857dB50AC9ece64c653918;
    address internal constant NPM = 0x39654A85A4C05127f5Fd6ED22CAeC077A0fB1377;
    address internal constant ROUTER = 0x53BF6B0684Ec7eF91e1387Da3D1a1769bC5A6F77;
    address internal constant POOL = 0x6fd5F2fb831940DcD61A98c5B3aCB7D8C6f3bFc1;
    uint24 internal constant FEE = 500;
    uint32 internal constant ARC_DOMAIN = 26;

    address internal constant NATIVE_AUTHORITY = 0x1800000000000000000000000000000000000000;
    address internal constant NATIVE_BLOCKLIST = 0x1800000000000000000000000000000000000001;
    uint256 internal constant NATIVE_SCALE = 1e12;

    /// @dev Mirrors ShariahVault's internal exit-settlement constants (N-33 values).
    uint256 internal constant SETTLE_GAS = 700_000;
    uint256 internal constant SETTLE_GAS_PER_ADAPTER = 1_300_000;
    uint256 internal constant BLOCK_GAS = 30_000_000; // Arc mainnet/testnet block gas limit (2026-10-31)

    uint256 internal constant DEP = 10_000e6;
    uint256 internal constant LP_AMOUNT = 5_000e6;

    address internal owner = makeAddr("owner"); // owner and board member of the fixture registry
    address internal manager = makeAddr("manager");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal whale = makeAddr("whale");
    address internal charityWallet = makeAddr("charityWallet");

    ShariahAdapterRegistry internal registry;
    TreasuryModule internal treasury;
    ShariahVaultV2 internal vault;
    CharityModule internal charity;
    PurificationEscrow internal escrow;
    HalalLPAdapter internal lp;

    function setUp() public {
        string memory rpc = vm.envOr("ARC_MAINNET_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        uint256 pin = vm.envOr("ARC_MAINNET_FORK_BLOCK", uint256(0));
        if (pin == 0) {
            try vm.createSelectFork(rpc) returns (uint256) {} catch { vm.skip(true); }
        } else {
            try vm.createSelectFork(rpc, pin) returns (uint256) {} catch { vm.skip(true); }
        }
        if (block.chainid != 5042) vm.skip(true);

        vm.etch(NATIVE_AUTHORITY, address(new ArcNativeCoinShim()).code);
        vm.allowCheatcodes(NATIVE_AUTHORITY);
        vm.etch(NATIVE_BLOCKLIST, address(new ArcBlocklistShim()).code);
        ArcNativeCoinShim(NATIVE_AUTHORITY).setSupply(type(uint128).max);

        _deployStack();
        _fundAndDeposit(alice, DEP);
        _fundAndDeposit(bob, DEP);

        lp = new HalalLPAdapter(NPM, ROUTER, USDC, EURC, FEE, USDC, address(vault), owner);
        vm.startPrank(owner);
        vault.setScreened(address(lp), true);
        registry.proposeScreening(address(lp), keccak256("N33A-FORK-TEST-ONLY"), block.timestamp + 365 days);
        vm.stopPrank();
        skip(30 days + 1); // registry timelock; the pool TWAP then extrapolates the current tick
        vm.roll(block.number + 1);
        vm.prank(owner);
        registry.executeScreening(address(lp));

        vm.prank(manager);
        vault.deployCapitalAndExecute(address(lp), LP_AMOUNT, "");
        assertEq(vault.fundedAdapterCount(), 1, "LP adapter is a funded non-gold adapter");
    }

    // ───────────────────────────── fixture ─────────────────────────────

    function _deployStack() internal {
        registry = new ShariahAdapterRegistry(owner, owner);
        uint256 n = vm.getNonce(address(this));
        address escrowAddr = vm.computeCreateAddress(address(this), n + 3);
        address vaultAddr = vm.computeCreateAddress(address(this), n + 1);
        treasury = new TreasuryModule("Shariah", escrowAddr, USDC, 50, 1000, 400, vaultAddr);
        vault = new ShariahVaultV2(IERC20(USDC), owner, ARC_DOMAIN, address(treasury), address(0), address(registry));
        charity = new CharityModule(charityWallet, USDC, escrowAddr, owner, address(registry));
        escrow = new PurificationEscrow(address(vault), USDC, address(charity), address(treasury), owner, address(registry));
        assertEq(address(vault), vaultAddr);
        assertEq(address(escrow), escrowAddr);

        vm.startPrank(address(vault)); // the treasury is owned by the vault
        treasury.setFeeSource(address(vault));
        treasury.setProfitRecorder(address(escrow));
        vm.stopPrank();

        vm.startPrank(owner);
        vault.setPurificationEscrow(address(escrow));
        vault.setManager(manager);
        vault.setPermittedAsset(USDC, true);
        vm.stopPrank();
    }

    function _usdcTo(address who, uint256 amt) internal {
        vm.deal(who, who.balance + amt * NATIVE_SCALE); // Arc USDC ERC-20 view = native balance / 1e12
    }

    function _fundAndDeposit(address who, uint256 amt) internal {
        _usdcTo(who, amt);
        vm.startPrank(who);
        IERC20(USDC).approve(address(vault), type(uint256).max);
        vault.deposit(amt, who);
        vm.stopPrank();
    }

    /// @dev Realized profit for the exit-settlement path: USDC lands in the vault (e.g. recalled LP fees).
    function _yield(uint256 amt) internal {
        _usdcTo(address(vault), amt);
    }

    function _distributed() internal view returns (uint256) {
        return charity.totalCharityDistributed() + treasury.pendingFees();
    }

    function _floor() internal view returns (uint256) {
        return 2 * (SETTLE_GAS + vault.fundedAdapterCount() * SETTLE_GAS_PER_ADAPTER);
    }

    /// @dev First touch in a fresh transaction: every account and slot the exit reads is cold.
    function _cool() internal {
        address[15] memory a = [
            address(vault), USDC, EURC, address(escrow), address(charity), address(treasury), address(registry),
            address(lp), NPM, FACTORY, POOL, bob, charityWallet, NATIVE_AUTHORITY, NATIVE_BLOCKLIST
        ];
        for (uint256 i; i < a.length; ++i) vm.cool(a[i]);
    }

    function _attemptRedeem(uint256 gasLimit, uint256 shares) internal returns (bool ok, bool settled) {
        uint256 snap = vm.snapshotState();
        uint256 base = _distributed();
        _cool();
        vm.prank(bob);
        try vault.redeem{gas: gasLimit}(shares, bob, bob) returns (uint256) {
            ok = true;
        } catch {}
        settled = _distributed() > base;
        vm.revertToState(snap);
    }

    function _minExitGas(uint256 shares) internal returns (uint256 minG, bool settledThere) {
        uint256 lo = _floor();
        uint256 hi;
        for (uint256 g = lo; g <= BLOCK_GAS; g += 500_000) {
            (bool ok,) = _attemptRedeem(g, shares);
            if (ok) { hi = g; break; }
            lo = g;
        }
        require(hi != 0, "exit never succeeds within the block gas limit");
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            (bool ok,) = _attemptRedeem(mid, shares);
            if (ok) hi = mid;
            else lo = mid;
        }
        minG = hi;
        (, settledThere) = _attemptRedeem(minG, shares);
    }

    function _shock() internal returns (int24 moved) {
        (, int24 t0,,,,,) = IV3PoolSlot0(POOL).slot0();
        int24 t = t0;
        for (uint256 i; i < 20 && t - t0 <= int24(lp.maxTwapDeviationTicks()); ++i) {
            deal(EURC, whale, 5_000e6);
            vm.startPrank(whale);
            IERC20(EURC).approve(ROUTER, 5_000e6);
            IHalalSwapRouter(ROUTER).exactInputSingle(IHalalSwapRouter.ExactInputSingleParams({
                tokenIn: EURC, tokenOut: USDC, fee: FEE, recipient: whale,
                amountIn: 5_000e6, amountOutMinimum: 0, sqrtPriceLimitX96: 0
            }));
            vm.stopPrank();
            (, t,,,,,) = IV3PoolSlot0(POOL).slot0();
        }
        moved = t - t0;
    }

    // ───────────────────────────── tests ─────────────────────────────

    /// N-33 end to end: in a fresh (cold) transaction the vault's bounded read returns the real LP mark.
    /// A failed read would count as zero loss, so a non-zero loss equal to the adapter's shortfall proves success.
    function test_N33A_coldVaultRead_marksRealLPValue() public {
        uint256 shortfall = LP_AMOUNT - lp.currentValue();
        assertGt(shortfall, 0, "real entry costs leave a small shortfall");
        _cool();
        assertEq(vault.unrealizedAdapterLoss(), shortfall, "cold bounded read succeeded and marked the LP");
    }

    function test_N33A_navMarksLPCostsDownOnly() public view {
        uint256 lpValue = lp.currentValue();
        uint256 loss = vault.unrealizedAdapterLoss();
        uint256 fees = treasury.pendingFees(); // Wakala accrued over the 30-day screening wait
        console.log("LP principal", vault.principalOf(address(lp)), "LP value", lpValue);
        console.log("unrealized LP loss marked in NAV", loss, "pending fees", fees);
        assertEq(loss, LP_AMOUNT > lpValue ? LP_AMOUNT - lpValue : 0, "NAV marks the real LP shortfall");
        assertApproxEqAbs(vault.totalAssets(), 2 * DEP - loss - fees, 2, "NAV = deposits - LP loss - pending fees");
        assertLe(loss, LP_AMOUNT / 100, "entry costs (swap fee + impact) below 1%");
    }

    /// KNOWN FINDING N-34 (open): the deposit gate closes when marked non-gold losses exceed the dust threshold
    /// (default 1 USDC). Funding 5,000 USDC into the real LP costs ~1.48 USDC (two 0.05% swaps + impact), so
    /// deposits close the moment the LP is funded, and normal impermanent loss keeps them closed.
    function test_knownFinding_N34_lpEntryCostClosesDepositGateAtDefaultDust() public {
        _cool();
        uint256 loss = vault.unrealizedAdapterLoss();
        assertGt(loss, vault.effectiveDustThreshold(), "entry cost alone exceeds the 1 USDC default dust");
        assertFalse(vault.valuationHealthy(), "N-34 fixed? deposit gate now open: update the finding");
        assertEq(vault.maxDeposit(carol), 0);
    }

    /// N-34 mitigation available today: the board raises the dust threshold to its cap (0.5% of NAV) through the
    /// 30-day timelock. With that, a cold deposit transaction passes the gate while the LP is funded.
    function test_N34_boardDustAtCap_reopensDeposits_coldTx() public {
        // The cap is re-checked at confirmation and NAV drifts down as Wakala accrues over the 30 days, so a
        // proposal of exactly 0.5% of NAV reverts DustThresholdAboveCap at confirm. Leave 10% headroom.
        uint256 cap = vault.totalAssets() * vault.MAX_DUST_BPS() / 10_000;
        vm.prank(owner); // owner is the fixture registry's board member
        vault.proposeDustThreshold(cap * 9 / 10);
        skip(30 days + 1);
        vm.roll(block.number + 1);
        vm.prank(owner);
        vault.confirmDustThreshold();
        console.log("dust threshold set to", vault.effectiveDustThreshold());

        _cool();
        assertTrue(vault.valuationHealthy(), "gate open at the capped dust threshold");
        _usdcTo(carol, 1_000e6);
        vm.prank(carol);
        IERC20(USDC).approve(address(vault), type(uint256).max);
        _cool();
        uint256 g = gasleft();
        vm.prank(carol);
        vault.deposit(1_000e6, carol);
        console.log("cold deposit gas with 1 funded LP adapter", g - gasleft());
        assertGt(vault.balanceOf(carol), 0);
    }

    /// The exit floor must leave enough gas for settlement at the minimum gas a wallet estimate would pick.
    function test_N33A_exitWithRealizedProfit_minGasSettlesCut() public {
        _yield(200e6);
        assertGt(vault.realizedProfit(), 0, "realized profit present");
        uint256 shares = vault.balanceOf(bob) / 2;
        (uint256 minG, bool settled) = _minExitGas(shares);
        console.log("min exit gas (cold, 1 funded LP adapter)", minG, "floor", _floor());
        assertTrue(settled, "leaver's cut settled at the minimum non-reverting gas");
        assertGe(minG, _floor());
        assertLt(minG, BLOCK_GAS);
    }

    function test_N33A_recallThroughVault_retiresPrincipal() public {
        uint256 before = IERC20(USDC).balanceOf(address(vault));
        vm.prank(manager);
        vault.recallCapital(address(lp), LP_AMOUNT);
        uint256 got = IERC20(USDC).balanceOf(address(vault)) - before;
        console.log("recalled through vault", got);
        assertEq(vault.fundedAdapterCount(), 0);
        assertEq(vault.principalOf(address(lp)), 0);
        assertEq(lp.positionTokenId(), 0);
        assertGe(got, LP_AMOUNT * 99 / 100);
    }

    /// A real adverse move: once the TWAP reflects it, NAV marks the loss, the deposit gate closes, exits stay open.
    function test_N33A_priceShock_marksLoss_blocksEntry_exitsOpen() public {
        uint256 navBefore = vault.totalAssets();
        int24 moved = _shock();
        assertGt(moved, int24(lp.maxTwapDeviationTicks()));
        skip(lp.twapWindow() + 60);
        vm.roll(block.number + 1);

        uint256 loss = vault.unrealizedAdapterLoss();
        console.log("tick move");
        console.logInt(moved);
        console.log("marked LP loss", loss, "dust threshold", vault.effectiveDustThreshold());
        assertGt(loss, vault.effectiveDustThreshold(), "shock loss above dust");
        assertLt(vault.totalAssets(), navBefore, "NAV marked down");
        assertFalse(vault.valuationHealthy(), "deposit gate closed");
        assertEq(vault.maxDeposit(carol), 0);

        uint256 shares = vault.balanceOf(alice) / 4;
        uint256 quote = vault.previewRedeem(shares);
        vm.prank(alice);
        uint256 out = vault.redeem(shares, alice, alice);
        assertEq(out, quote, "exit open at marked NAV");
    }
}

interface IV3PoolSlot0 {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}
