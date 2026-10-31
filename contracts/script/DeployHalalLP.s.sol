// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {HalalLPAdapter} from "../adapters/HalalLPAdapter.sol";

/**
 * @title DeployHalalLP
 * @notice Run from /home/user/app. The caller supplies the signing key to Forge;
 * this script never reads, stores, or logs a private key.
 *
 * Validate only (no broadcast or deployment):
 * forge script --root /home/user/app contracts/script/DeployHalalLP.s.sol:DeployHalalLP --sig "check()" --rpc-url "$ARC_TESTNET_RPC" --private-key "$DEPLOYER_PK" -vvvv
 * Simulate deployment (no broadcast):
 * forge script --root /home/user/app contracts/script/DeployHalalLP.s.sol:DeployHalalLP --sig "run()" --rpc-url "$ARC_TESTNET_RPC" --private-key "$DEPLOYER_PK" -vvvv
 * Broadcast deployment:
 * forge script --root /home/user/app contracts/script/DeployHalalLP.s.sol:DeployHalalLP --sig "run()" --rpc-url "$ARC_TESTNET_RPC" --private-key "$DEPLOYER_PK" --broadcast -vvvv
 *
 * Required env addresses: HALAL_LP_POSITION_MANAGER, HALAL_LP_SWAP_ROUTER,
 * HALAL_LP_TOKEN0, HALAL_LP_TOKEN1, HALAL_LP_VAULT (ShariahVaultV2).
 * Required env uint: HALAL_LP_POOL_FEE (100, 500, 3000, or 10000).
 * Optional: HALAL_LP_OWNER (defaults to Forge's caller/broadcaster),
 * HALAL_LP_USDC (defaults to Arc Testnet USDC below).
 * Optional signed decimal ticks: HALAL_LP_TICK_LOWER / HALAL_LP_TICK_UPPER;
 * supply BOTH or neither. These use envInt because ticks may be negative.
 * Defaults remain the adapter's -887220 / 887220. For fee 10000, explicitly
 * supply spacing-200-aligned ticks (the adapter defaults are not aligned).
 * When owner != broadcaster, a requested tick update is printed, not sent;
 * the owner must apply it BEFORE executor funding.
 *
 * Arc Testnet has no canonical Uniswap V3 deployment known to Arc Studio.
 * Supply real deployed, compatible position-manager and swap-router addresses.
 * This script deploys no mocks. Code presence is not proof of compatibility:
 * independently verify factory/pool, token order, router ABI and TWAP history.
 * The adapter uses the deadline-free exactInputSingle router ABI in its source.
 * No pool proposal or adapter capital-cap setter exists in this adapter.
 * Slippage/TWAP changes require proposal + 30-day wait + execution; untouched here.
 */
contract DeployHalalLP is Script {
    struct Parameters {
        address positionManager;
        address swapRouter;
        address token0;
        address token1;
        uint24 poolFee;
        address usdc;
        address vault;
        address owner;
        bool configureTicks;
        int24 tickLower;
        int24 tickUpper;
    }

    function check() external view {
        Parameters memory p = _resolveAndValidate();
        _logParameters(p);
    }

    function run() external returns (HalalLPAdapter adapter) {
        // Forge sets msg.sender from the caller's --private-key / --sender.
        // All environment resolution and validations precede startBroadcast().
        Parameters memory p = _resolveAndValidate();
        _logParameters(p);

        vm.startBroadcast();
        adapter = new HalalLPAdapter(
            p.positionManager, p.swapRouter, p.token0, p.token1,
            p.poolFee, p.usdc, p.vault, p.owner
        );
        if (p.configureTicks && p.owner == msg.sender) {
            adapter.setTickRange(p.tickLower, p.tickUpper);
        }
        vm.stopBroadcast();

        console.log("Deployed HalalLPAdapter:", address(adapter));
        if (p.configureTicks && p.owner != msg.sender) {
            console.log("REQUIRED before funding: HALAL_LP_OWNER must call setTickRange(int24,int24) on:", address(adapter));
            console.logInt(int256(p.tickLower));
            console.logInt(int256(p.tickUpper));
        } else if (p.configureTicks) {
            console.log("Requested tick range configured by broadcaster/owner.");
        }
        _logNextSteps(address(adapter));
    }

    function _resolveAndValidate() internal view returns (Parameters memory p) {
        p.positionManager = vm.envAddress("HALAL_LP_POSITION_MANAGER");
        p.swapRouter = vm.envAddress("HALAL_LP_SWAP_ROUTER");
        p.token0 = vm.envAddress("HALAL_LP_TOKEN0");
        p.token1 = vm.envAddress("HALAL_LP_TOKEN1");
        p.vault = vm.envAddress("HALAL_LP_VAULT");
        p.owner = vm.envOr("HALAL_LP_OWNER", msg.sender);
        p.usdc = vm.envOr("HALAL_LP_USDC", address(0x3600000000000000000000000000000000000000));
        uint256 fee = vm.envUint("HALAL_LP_POOL_FEE");
        require(fee == 100 || fee == 500 || fee == 3000 || fee == 10000,
            "HALAL_LP_POOL_FEE must be 100, 500, 3000 or 10000");
        // Validate the full uint256 before narrowing; never silently truncate.
        p.poolFee = uint24(fee);

        _requireContract(p.positionManager, "HALAL_LP_POSITION_MANAGER");
        _requireContract(p.swapRouter, "HALAL_LP_SWAP_ROUTER");
        _requireContract(p.token0, "HALAL_LP_TOKEN0");
        _requireContract(p.token1, "HALAL_LP_TOKEN1");
        _requireContract(p.usdc, "HALAL_LP_USDC");
        _requireContract(p.vault, "HALAL_LP_VAULT");
        require(p.owner != address(0), "HALAL_LP_OWNER is zero");
        require(p.token0 != p.token1, "HALAL_LP_TOKEN0 and HALAL_LP_TOKEN1 must differ");
        require(p.token0 == p.usdc || p.token1 == p.usdc, "HALAL_LP pair must contain USDC");
        require(p.token0 < p.token1, "HALAL_LP tokens must follow V3 token0 < token1 order");

        bool hasLower = vm.envExists("HALAL_LP_TICK_LOWER");
        bool hasUpper = vm.envExists("HALAL_LP_TICK_UPPER");
        require(hasLower == hasUpper, "Supply both HALAL_LP_TICK_LOWER and HALAL_LP_TICK_UPPER");
        p.configureTicks = hasLower;
        int256 lower = hasLower ? vm.envInt("HALAL_LP_TICK_LOWER") : int256(-887220);
        int256 upper = hasUpper ? vm.envInt("HALAL_LP_TICK_UPPER") : int256(887220);
        require(lower >= -887272 && upper <= 887272 && lower < upper, "Invalid HALAL_LP tick bounds");
        int256 spacing = fee == 100 ? int256(1) : fee == 500 ? int256(10) : fee == 3000 ? int256(60) : int256(200);
        require(lower % spacing == 0 && upper % spacing == 0,
            "Ticks must align with fee spacing; fee 10000 requires explicit aligned tick env vars");
        p.tickLower = int24(lower);
        p.tickUpper = int24(upper);
    }

    function _requireContract(address target, string memory name) internal view {
        require(target != address(0), string.concat(name, " is zero"));
        require(target.code.length > 0, string.concat(name, " has no deployed code"));
    }

    function _logParameters(Parameters memory p) internal view {
        console.log("Broadcaster (Forge caller):", msg.sender);
        console.log("HALAL_LP_POSITION_MANAGER:", p.positionManager);
        console.log("HALAL_LP_SWAP_ROUTER:", p.swapRouter);
        console.log("HALAL_LP_TOKEN0:", p.token0);
        console.log("HALAL_LP_TOKEN1:", p.token1);
        console.log("HALAL_LP_POOL_FEE:", uint256(p.poolFee));
        console.log("HALAL_LP_USDC:", p.usdc);
        console.log("HALAL_LP_VAULT:", p.vault);
        console.log("HALAL_LP_OWNER:", p.owner);
        console.log("Resolved tick lower / upper (apply before funding):");
        console.logInt(int256(p.tickLower));
        console.logInt(int256(p.tickUpper));
        console.log("Arc Testnet has no canonical Uniswap V3 deployment known to Arc Studio; supply real addresses.");
        console.log("Code checks do not establish authenticity or router/pool compatibility. No mocks are deployed.");
    }

    function _logNextSteps(address adapter) internal view {
        console.log("NEXT: screen this printed adapter on HALAL_LP_VAULT's registry:", adapter);
        console.log("Set REHEARSAL_VAULT=HALAL_LP_VAULT and REHEARSAL_REGISTRY to that vault's registry (not stale defaults).");
        console.log("With board authorization, Rehearsal.s.sol step3_screenS3H(address), passing the printed adapter address.");
        console.log("After the registry delay, run step3b_executeScreening(address) with the same address.");
        console.log("Rehearsal short screening is ONLY for its testnet short-timelock registry; otherwise use the registry's native governance flow.");
        console.log("Rehearsal requires BOARD_PK and DEPLOYER_PK (vault owner) for its separate authorized calls.");
        console.log("No adapter pool proposal or capital-cap setter is required/available; pool comes from positionManager.factory().getPool().");
        console.log("Before funding: verify the initialized pool, fee tickSpacing, liquidity, token order and >=1800 seconds TWAP history.");
        console.log("Defaults retained: maxSlippageBps=100 (cap 500), twapWindow=1800 (min 300), maxTwapDeviationTicks=100 (cap 500).");
        console.log("Optional owner changes: proposeMaxSlippageBps(uint256) -> wait 30 days -> executeMaxSlippageBps().");
        console.log("Optional owner changes: proposeTwapWindow(uint32) -> wait 30 days -> executeTwapWindow().");
        console.log("Optional owner changes: proposeMaxTwapDeviationTicks(uint24) -> wait 30 days -> executeMaxTwapDeviationTicks().");
        console.log("Funding: executor owner sets setShariahStrategyConfig(2, adapter, bytes32(0), true, minAmount, maxAmount) with chosen USDC bounds.");
        console.log("Wire the Shariah aggregator and vault manager to the executor; ensure LP bit 2, screening, permitted assets and allocation caps allow execution.");
        console.log("Fund the vault via deposits, then executor.executeWinner() when HALAL_LP wins and score/cooldown/gas gates pass.");
        console.log("Executor calls vault.deployCapitalAndExecute; do not call adapter.deploy directly (onlyVault) or fund it by direct transfer.");
    }
}
