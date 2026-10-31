# Uniswap V3 creation bytecode (testnet only)

`creation-bytecode.json` holds the unmodified creation bytecode of three official Uniswap contracts. `DeployUniswapV3Testnet.s.sol` deploys them on Arc Testnet, where Uniswap has not deployed V3 (workplan LP-3). It is never used for Arc mainnet: the official Uniswap deployment already exists there.

| Key | Contract | npm package | Tarball SHA-256 | Creation bytecode SHA-256 |
|---|---|---|---|---|
| `factory` | `UniswapV3Factory` | `@uniswap/v3-core@1.0.1` | `141b001e2a376fff867cb24e0713b2834095cb1250c13aae263d9a646446d329` | `62013628a11b8fa975d023551100c633363a6380a820476e86f6ceb1aeb08b1e` |
| `npm` | `NonfungiblePositionManager` | `@uniswap/v3-periphery@1.4.4` | `7177174c4b8c66bd1d61e7c4127ee15e95f851edfb1a65ee8225b6ab4f818bd7` | `f803985e92b60a4a49c6cf0628a10ef8105bc812ff98cf13aa5af4a133a72052` |
| `router02` | `SwapRouter02` | `@uniswap/swap-router-contracts@1.3.1` | `efad19ccb35c90338981f06ef7acc6daa5cce7a8139611167270eb7b2a1e26df` | `31a31fd0fd58214139a9dbf53b9c5b55013472843d5adbfa37c4820a2d865f4c` |

Each value is the `bytecode` field of the package's Hardhat artifact (none has link references).

## Match with the official Arc mainnet deployment

Checked 2026-10-31 with read-only `cast code` against Arc mainnet (chain 5042). The artifact runtime code (`deployedBytecode`) has the same length as the code at the official addresses. Every differing byte lies inside a 32-byte immutable slot:

- Factory `0xf0db7b58379503491d857dB50AC9ece64c653918`: 20 bytes, the `NoDelegateCall` self-address.
- NonfungiblePositionManager `0x39654A85A4C05127f5Fd6ED22CAeC077A0fB1377`: factory, WETH9, token descriptor, and the EIP-712 name/version hashes.
- SwapRouter02 `0x53BF6B0684Ec7eF91e1387Da3D1a1769bC5A6F77`: V2 factory, V3 factory, position manager, WETH9.

So the testnet deployment runs the same code as the venue the mainnet LP adapter targets.

## Constructor arguments on Arc Testnet

- WETH9 and the token descriptor are not deployed on Arc Testnet. `HalalLPAdapter` never sends native value and never reads `tokenURI`, so the script passes inert placeholders (`0x…dEaD` for WETH9, `0x…bEEF` for the descriptor). Native-value paths (`refundETH`, `unwrapWETH9`, `tokenURI`) are unsupported on this deployment.
- SwapRouter02's V2 factory is `address(0)`; V2 paths are unused.

## Licence

`@uniswap/v3-core` is BUSL-1.1 with a Change Date of 2023-04-01, after which it is GPL-2.0-or-later. The periphery and swap-router packages are GPL-2.0-or-later.
