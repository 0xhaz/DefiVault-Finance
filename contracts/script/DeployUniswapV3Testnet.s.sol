// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";

interface IUniV3FactoryT {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
    function getPool(address, address, uint24) external view returns (address);
}

interface IUniV3PoolT {
    function initialize(uint160 sqrtPriceX96) external;
    function increaseObservationCardinalityNext(uint16 next) external;
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/// @notice Shared deployment logic, used by the broadcast script and by the fork test.
library UniswapV3TestnetDeployer {
    address internal constant USDC = 0x3600000000000000000000000000000000000000;
    address internal constant EURC = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;
    /// @dev Inert placeholders: WETH9 and the NFT descriptor are not deployed on Arc Testnet and are never used by
    ///      HalalLPAdapter (no native value, no tokenURI). See contracts/script/uniswap-v3/PROVENANCE.md.
    address internal constant WETH9_PLACEHOLDER = 0x000000000000000000000000000000000000dEaD;
    address internal constant DESCRIPTOR_PLACEHOLDER = 0x000000000000000000000000000000000000bEEF;

    uint24 internal constant FEE_STABLE = 500; // mirrors the mainnet USDC/EURC 0.05% pool
    uint24 internal constant FEE_VOLATILE = 3000;
    /// @dev Mainnet USDC/EURC 0.05% pool slot0 on 2026-10-31 (tick -1089, about 0.897 EURC per USDC).
    uint160 internal constant SQRT_PRICE_USDC_EURC = 75030237240879664286151369836;
    uint160 internal constant SQRT_PRICE_ONE = 79228162514264337593543950336; // 2**96
    /// @dev Enough history for the adapter's 1800 s TWAP under regular swaps (mainnet pool uses 1000).
    uint16 internal constant CARDINALITY = 300;

    struct Deployment {
        address factory;
        address npm;
        address router;
        address mockToken;
        address poolStable;
        address poolVolatile;
    }

    function _create(bytes memory initCode) private returns (address a) {
        assembly ("memory-safe") {
            a := create(0, add(initCode, 32), mload(initCode))
        }
        require(a != address(0) && a.code.length != 0, "UniV3Deploy: create failed");
    }

    function deployCore(Vm vm, string memory bytecodeJson) internal returns (Deployment memory d) {
        bytes memory factoryCode = vm.parseJsonBytes(bytecodeJson, ".factory");
        bytes memory npmCode = vm.parseJsonBytes(bytecodeJson, ".npm");
        bytes memory routerCode = vm.parseJsonBytes(bytecodeJson, ".router02");
        d.factory = _create(factoryCode);
        d.npm = _create(abi.encodePacked(npmCode, abi.encode(d.factory, WETH9_PLACEHOLDER, DESCRIPTOR_PLACEHOLDER)));
        d.router = _create(abi.encodePacked(routerCode, abi.encode(address(0), d.factory, d.npm, WETH9_PLACEHOLDER)));
    }

    /// @dev Salt whose CREATE2 address sorts below USDC, so USDC is token1 in the volatile pool. The stable pool
    ///      has USDC as token0 (0x36.. < 0x89..), so together they cover both token orders in the adapter.
    function mockSalt(address create2Deployer) internal pure returns (bytes32 salt, address predicted) {
        bytes32 initHash = keccak256(abi.encodePacked(type(MockERC20).creationCode, abi.encode("Mock Volatile", "MVOL", uint8(6))));
        for (uint256 i; i < 256; ++i) {
            salt = bytes32(i);
            predicted = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), create2Deployer, salt, initHash)))));
            if (predicted < USDC) return (salt, predicted);
        }
        revert("UniV3Deploy: no salt");
    }

    function createPools(Deployment memory d) internal returns (Deployment memory) {
        d.poolStable = IUniV3FactoryT(d.factory).createPool(USDC, EURC, FEE_STABLE);
        IUniV3PoolT(d.poolStable).initialize(SQRT_PRICE_USDC_EURC);
        IUniV3PoolT(d.poolStable).increaseObservationCardinalityNext(CARDINALITY);
        d.poolVolatile = IUniV3FactoryT(d.factory).createPool(USDC, d.mockToken, FEE_VOLATILE);
        IUniV3PoolT(d.poolVolatile).initialize(SQRT_PRICE_ONE);
        IUniV3PoolT(d.poolVolatile).increaseObservationCardinalityNext(CARDINALITY);
        require(IUniV3PoolT(d.poolStable).token0() == USDC, "UniV3Deploy: USDC must be token0 (stable)");
        require(IUniV3PoolT(d.poolVolatile).token1() == USDC, "UniV3Deploy: USDC must be token1 (volatile)");
        return d;
    }
}

/// @title LP-3: deploy the official Uniswap V3 factory, NonfungiblePositionManager and SwapRouter02 on Arc Testnet
/// @notice Arc Testnet only (5042002), or local anvil (31337). Uniswap has deployed V3 on Arc mainnet but not on
///         the testnet. This deploys byte-identical code (see uniswap-v3/PROVENANCE.md), a mock volatile token, and
///         two pools: USDC/EURC 0.05% (USDC is token0, mainnet price) and MVOL/USDC 0.3% (USDC is token1, 1:1).
///         No USDC moves here (Arc's USDC fails ERC-20 calls inside Foundry broadcasts); seed liquidity afterwards
///         with contracts/script/uniswap-v3/seed-testnet.sh.
///
///         forge script contracts/script/DeployUniswapV3Testnet.s.sol --rpc-url arc_testnet \
///           --private-key $DEPLOYER_PK --broadcast
contract DeployUniswapV3Testnet is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external returns (UniswapV3TestnetDeployer.Deployment memory d) {
        require(block.chainid == 5042002 || block.chainid == 31337, "Arc Testnet or local only");
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/contracts/script/uniswap-v3/creation-bytecode.json"));
        (bytes32 salt, address predicted) = UniswapV3TestnetDeployer.mockSalt(CREATE2_DEPLOYER);

        vm.startBroadcast();
        d = UniswapV3TestnetDeployer.deployCore(vm, json);
        d.mockToken = address(new MockERC20{salt: salt}("Mock Volatile", "MVOL", 6));
        require(d.mockToken == predicted, "mock address mismatch");
        d = UniswapV3TestnetDeployer.createPools(d);
        vm.stopBroadcast();

        console.log("UniswapV3Factory          ", d.factory);
        console.log("NonfungiblePositionManager", d.npm);
        console.log("SwapRouter02              ", d.router);
        console.log("MockVolatile (MVOL)       ", d.mockToken);
        console.log("Pool USDC/EURC 0.05%      ", d.poolStable);
        console.log("Pool MVOL/USDC 0.3%       ", d.poolVolatile);
    }
}
