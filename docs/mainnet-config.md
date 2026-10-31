# DeFiVault: Arc mainnet production configuration

Companion to `docs/mainnet-deploy.md`. Every value marked **REPLACE** is a placeholder you must set yourself; the deploy script rejects the zero address and has no defaults for fee parameters. Nothing here has been applied to Arc mainnet.

## 1. Roles

| Role | Placeholder | Holds | Notes |
|---|---|---|---|
| Deployer | `DEPLOYER_ADDRESS` **REPLACE** | Temporary owner while the stack is wired | Fresh address, encrypted keystore, holds no ownership after `handoff()`. Must differ from every governance address. |
| Owner multisig | `OWNER_MULTISIG` **REPLACE** | `owner()` of all contracts: pause, manager, gold links, permitted assets, executor and aggregator configuration, adapter parameters | Safe, at least 2 of 3. Registry ownership transfers immediately; all other contracts use two-step ownership and need `acceptOwnership()`. |
| Board multisig | `BOARD_MULTISIG` **REPLACE** | Registry board member: adapter screening, rate and wallet changes, dust threshold, remote recipients, board-gated parameters | Safe, at least 2 of 3. Board membership changes need the registry's 30-day timelock. |
| Manager | the deployed `RiskTieredExecutor` | `vault.manager()`: deploys and recalls capital within caps | Contract, not a person. The owner can replace it (`setManager`). Anyone can call `executeWinner()` subject to cooldown, score and gas ceiling. |
| Oracle operator | `ORACLE_OPERATOR` **REPLACE** | Writes strategy scores to the aggregator (`writeScore`, `writeBatchScores`) | Use a dedicated hot key that holds no funds. Compromise can only steer which enabled strategy wins; it cannot move funds directly. |
| Charity wallet | `CHARITY_WALLET` **REPLACE** | Receives charity and purification amounts | Recipient approved by the Shariah board (SR-003). Changes need a 30-day timelock. Must not be USDC-blocklisted. |

## 2. Parameters (no defaults in the script)

| Variable | Meaning | Script bound | Testnet value | Decision needed |
|---|---|---|---|---|
| `ADMIN_FEE_BPS` | Wakala fee per year on assets under management, basis points | 0 to 200 | 50 | **REPLACE**. Board ruling SR-026. |
| `MUSHARAKAH_BPS` | Manager share of profit above the hurdle | 0 to 3000 | 1000 | **REPLACE**. Board ruling SR-004/SR-014. |
| `HURDLE_BPS` | Annual hurdle before the manager shares in profit | 0 to 2000 | 400 | **REPLACE**. |
| `EXECUTOR_MAX_GAS_PRICE_GWEI` | Executor refuses to run above this gas price | 20 to 1000 | 200 | **REPLACE**. Arc drops transactions below 20 gwei maxFeePerGas, so a lower ceiling can never execute. |

Hard-coded in contracts (change requires new deployment): charity rate default 2.5 percent (bounded by `MAX_CHARITY_BPS` = 5 percent; changes 30-day timelock); purification cap 10 percent per adapter and 50 percent combined deductions; gold combined cap 30 percent of NAV; max allocation 80 percent of NAV (owner adjustable); pending cross-chain cap 20 percent (max 50 percent); cross-chain fee cap 1 percent; profit unlock period 3 days (max 14); dust threshold 1 USDC (board-gated, cap 0.5 percent of NAV); max 10 funded non-gold adapters; adapter read gas cap 100,000.

## 3. Timelocks

| Change | Delay | Who |
|---|---|---|
| Adapter screening (propose then execute) | 30 days | Board multisig |
| Registry board membership | 30 days | Board multisig |
| Registry replacement in the vault | 30 days | Owner multisig / board |
| Charity wallet and rate | 30 days | Board multisig |
| Purification rate per adapter | 30 days | Board multisig |
| Dust threshold | 30 days | Board multisig |
| Remote CCTP recipient approval | 30 days | Board multisig |
| Gold adapter parameter changes (oracle staleness, slippage, emergency-exit flag, pool) | 30 days | Adapter owner (owner multisig) |
| Gold emergency exit sale | 1 hour delay, 24 hour window, 20 percent floor | Adapter owner, only if the flag was enabled 30 days earlier |
| Registry ownership transfer | none (plain `Ownable`) | Current owner |

The delays come from the contract constants (`TIMELOCK_PERIOD`, `PURIFICATION_TIMELOCK`, `DUST_TIMELOCK`, `REMOTE_RECIPIENT_TIMELOCK`, `REGISTRY_TIMELOCK`, `TIMELOCK_DELAY`, `EMERGENCY_EXIT_DELAY`). Confirm the exact caller of each timelocked function in the source before you plan signers. Because most changes take a month, set parameters right the first time and stage changes early.

## 4. Addresses

Fixed addresses (verified 2026-10-31 against `docs.arc.io` and `developers.circle.com`; re-verify on `https://explorer.arc.io` before use):

| Item | Address |
|---|---|
| USDC (ERC-20 view) | `0x3600000000000000000000000000000000000000` |
| TokenMessengerV2 | `0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d` |
| MessageTransmitterV2 | `0x81D40F21F12A8F0E3252Bccb954D722d4c464B64` |

Gold inputs, **REPLACE after confirming each on Arc mainnet** (none are confirmed today; the Ethereum mainnet addresses in the old guide are not Arc addresses):

| Input | Variable | Status |
|---|---|---|
| XAU/USD oracle (8 decimals) | `GOLD_ORACLE` | REPLACE. No Arc mainnet feed confirmed. |
| PAXG token | `GOLD_PAXG` | REPLACE. |
| PAXG router | `GOLD_PAXG_ROUTER` | REPLACE. Must be a Uniswap V3 SwapRouter02-style router (`exactInputSingle`, no deadline). |
| XAUT token (6 decimals) | `GOLD_XAUT` | REPLACE. |
| XAUT router | `GOLD_XAUT_ROUTER` | REPLACE. Liquidity depth must be reviewed (the Ethereum pool was about $300K). |
| Oracle staleness | `GOLD_MAX_STALENESS_SECONDS` | REPLACE (300 to 604800; 3600 used on testnet). |

`HalalLPAdapter` is not deployed by `DeployMainnet.s.sol`. Use `contracts/script/DeployHalalLP.s.sol` only after a real Uniswap V3 position manager and router exist on Arc and the adapter has been tested against them.

## 5. What the script sets, and what it deliberately leaves alone

Set by `deployCore()`: vault asset USDC (domain 26), registry with the real 30-day timelock, treasury fee source = vault, CCTP messenger and transmitter, USDC permitted, charity and escrow wired, executor as manager, executor gas ceiling, aggregator oracle, **vault paused**.

Left for you: aggregator strategy enabling (`setEnabled`, board decision), executor strategy configs (created disabled by `deployGold()`), adapter screening (board, 30 days), vault unpause, charity rate changes, gold cap and allocation adjustments, deposit communication limits.

## 6. Differences from the testnet rehearsal

| Testnet | Mainnet |
|---|---|
| `TestnetRegistryShortTimelock` (2 minutes) | `ShariahAdapterRegistry` (30 days) |
| Mock PAXG, XAUT, oracle and pool | Real tokens, oracle and routers, all confirmed first |
| Deployer is owner, board and oracle | Separate Safes and a dedicated oracle key |
| Strategies enabled for demos | Disabled until the board decides |
| Executor gas ceiling 200 gwei | Chosen deliberately (`EXECUTOR_MAX_GAS_PRICE_GWEI`) |
| `--private-key` on the command line | Encrypted keystore only |

## 7. Environment variable reference

Governance: `DEPLOYER_ADDRESS`, `OWNER_MULTISIG`, `BOARD_MULTISIG`, `CHARITY_WALLET`, `ORACLE_OPERATOR`, `ALLOW_EOA_GOVERNANCE` (optional, discouraged).
Parameters: `ADMIN_FEE_BPS`, `MUSHARAKAH_BPS`, `HURDLE_BPS`, `EXECUTOR_MAX_GAS_PRICE_GWEI`.
Deployed addresses (after `deployCore()`): `REGISTRY`, `ZAKAT`, `TREASURY`, `VAULT`, `CHARITY`, `ESCROW`, `AGGREGATOR`, `EXECUTOR`.
Gold (optional): `GOLD_ORACLE`, `GOLD_PAXG`, `GOLD_PAXG_ROUTER`, `GOLD_PAXG_POOL_FEE`, `GOLD_XAUT`, `GOLD_XAUT_ROUTER`, `GOLD_XAUT_POOL_FEE`, `GOLD_MAX_STALENESS_SECONDS`.
RPC: `ARC_MAINNET_RPC`. No private key variable exists on purpose.
