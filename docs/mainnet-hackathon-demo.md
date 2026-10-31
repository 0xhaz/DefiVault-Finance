# Arc mainnet hackathon demo (Arc Microgrants, 2026-10-31)

**Status: unaudited demo, small amounts only.** This is an owner-approved exception to the project's testnet-only rule, made for the Arc Microgrants round (submissions close 2026-11-01). It is **not** the production launch described in `docs/mainnet-deploy.md`: there is no independent audit, no Shariah board ruling, and governance is held by single keys rather than Safes. No strategy adapter is screened. Mainnet screening takes the real 30-day timelock, so the vault holds idle USDC only.

## What is live on Arc mainnet (chain 5042)

Deployed with `contracts/script/DeployMainnet.s.sol` `deployCore()` (unchanged production script, `ALLOW_EOA_GOVERNANCE=true`), broadcast record `broadcast/DeployMainnet.s.sol/5042/deployCore-latest.json`: 24 transactions, all status 1, blocks 28833671 to 28833763, about 0.49 USDC of gas.

| Contract | Address | Creation tx |
|---|---|---|
| ShariahVaultV2 (Conservative) | [`0xDc40ed79F74141BBba84d54f84Eafd43CD8Bc470`](https://explorer.arc.io/address/0xDc40ed79F74141BBba84d54f84Eafd43CD8Bc470) | [`0xe27c7c23…f91d539`](https://explorer.arc.io/tx/0xe27c7c23e087665df928181fb9c0ac28890ba5974fdce8c5d90fa96a8f91d539) |
| ShariahAdapterRegistry (30-day timelock) | [`0xb7b1cFEbB0390aA16945aCe518118d491016A793`](https://explorer.arc.io/address/0xb7b1cFEbB0390aA16945aCe518118d491016A793) | [`0xcb0facaa…c42b3c45`](https://explorer.arc.io/tx/0xcb0facaa25df7b6acc586e8401cd3cb9c42b3c45bb8aabb0252d6a627ea39dcb) |
| TreasuryModule (Wakala 0.5%, Musharakah 10% above a 4% hurdle) | [`0xf17585cB249EF6Ab8bB450595107DB34d46FfE91`](https://explorer.arc.io/address/0xf17585cB249EF6Ab8bB450595107DB34d46FfE91) | [`0x667d5b9c…a82613e7`](https://explorer.arc.io/tx/0x667d5b9cd78e005f1f601d1749cf24aa8564ca2e3f880dcbd4348c15a82613e7) |
| CharityModule | [`0x99D53De353d32e34F18a21c8c760424FC92D01a9`](https://explorer.arc.io/address/0x99D53De353d32e34F18a21c8c760424FC92D01a9) | [`0x29095fb8…ba1b605`](https://explorer.arc.io/tx/0x29095fb8323c6086dee73bb4b80bd0b4049f5300e79a2a5759a303932ba1b605) |
| PurificationEscrow | [`0x3dA4697D8154A794DaC1d63276072142ed7C1890`](https://explorer.arc.io/address/0x3dA4697D8154A794DaC1d63276072142ed7C1890) | [`0xebff6fa2…c77eec1`](https://explorer.arc.io/tx/0xebff6fa25b9eeefb1eb7a2f83d54cd016275404c00897bcc5503d0b68c77eec1) |
| ShariahScoreAggregator | [`0x2b8dA7636aeb97C153F81C7168302dF45eD3643a`](https://explorer.arc.io/address/0x2b8dA7636aeb97C153F81C7168302dF45eD3643a) | [`0x226b3dc6…5b014804`](https://explorer.arc.io/tx/0x226b3dc647e9ab98fe086a6e464591a74c9212fc0c6904d82bf180d45b014804) |
| RiskTieredExecutor (vault manager) | [`0x23836611FDF05fAc07a12416e9c8C250F9cdF671`](https://explorer.arc.io/address/0x23836611FDF05fAc07a12416e9c8C250F9cdF671) | [`0x8cbf94c4…cda3b131`](https://explorer.arc.io/tx/0x8cbf94c48ad15063009e002ab8678facd4e05960251b713ab4ec3060cda3b131) |
| ZakatModule (deprecated v1 constructor input) | [`0xf0f5A1f045136AD43ee03B1E3C703aEb3f1Ff941`](https://explorer.arc.io/address/0xf0f5A1f045136AD43ee03B1E3C703aEb3f1Ff941) | [`0xe6c4612b…5b13`](https://explorer.arc.io/tx/0xe6c4612b5c170ab0c77c29e45171ff470cb1428fc98f305570e95562d93d31b3) |

Linked libraries (same addresses as testnet run 6, deployed by the same nonces): CctpSettlementLogic `0x891453f2C318B79b92a1d4CAe1d308ca29a6F3c6`, ShariahAccountingLogic `0x19151a9058843708E47F48E80b919333b3029AE1`, ShariahGovernanceLogic `0x8e06d14D2a0551cFA2D1E23Ed037D28775128060`, ShariahRegistryLogic `0xCe3aDB44203FaC0Ee90254e5dF8f9A9CA6Fd94C9`.

**Verified:** the vault runtime on Arc mainnet is 24,414 bytes and equals `forge inspect ShariahVaultV2 deployedBytecode` except for library links and immutables. This also answers gate M-2: Arc mainnet accepts a 24,414-byte contract. CCTP wiring: MessageTransmitterV2 `0x81D40F21F12A8F0E3252Bccb954D722d4c464B64`, local domain 26.

## Roles

| Role | Address | Notes |
|---|---|---|
| Deployer, vault owner, oracle operator | `0x3D23214d59CA3582628FffFE44D0Df1CC73D98f9` | Ownership not handed off (`handoff()` not run) |
| Registry board | `0x6e7cEd8C164c427c4486eA51DF47173791546F8F` | Generated for the demo; key in the local `.env` and `~/defivault-mainnet-demo-keys.env` |
| Charity wallet | `0x08701Ab5CFc209e150541cfB9081C3B95B803AeE` | Generated for the demo; same storage |

## USDC moved through the contract (example transactions)

| Step | Tx |
|---|---|
| Unpause (`setPaused(false)`) | [`0x5335c61f…ff7c152f`](https://explorer.arc.io/tx/0x5335c61f5cc489c87cd86f434d99bae36c4e09770839b9bef1502e1eff7c152f) |
| Approve 1 USDC | [`0x1a6c4ac5…4c0a2a`](https://explorer.arc.io/tx/0x1a6c4ac5e8cc1a2c88959e0e55ac57ffdf8b8a994c47c5b2cf7c20152f4c0a2a) |
| **Deposit 1 USDC** (1e12 shares minted, NAV 1.000000 USDC) | [`0xaec64e1e…c1011d`](https://explorer.arc.io/tx/0xaec64e1e7f47eecc6c32c6245df2283868bdf68a302f81f7c82069a0ffc1011d) |
| **Redeem all** (1 USDC back, vault empty) | [`0x0a734ab9…18e30de`](https://explorer.arc.io/tx/0x0a734ab9a97e8929e2eb2f07bcaaa41f4dc949efb1ca21e14e134376518e30de) |

## The app

Build for mainnet: `vite build --mode mainnet` (reads `.env.mainnet`: addresses only, committed). The app shows a banner on mainnet ("unaudited, small amounts"). On macOS, build from a fresh `bun install` outside the repo: the tracked `node_modules` was installed on Linux and lacks the darwin binaries for rollup and TypeScript.

## Limits of this demo

- Unaudited; open findings and accepted limitations are in `docs/security-review.md` (N-32, N-34, N-36, N-40 and "Known gaps").
- No strategy can receive funds before an adapter completes the 30-day registry screening, and none is proposed. Deposits sit idle in the vault.
- Single-key governance. Before holding meaningful funds: run `handoff()` to Safes, and follow every gate in `docs/mainnet-deploy.md` section 1.
