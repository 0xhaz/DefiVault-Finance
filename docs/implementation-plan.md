Good. Now I have everything I need. Let me update the plan with the final decisions and then build. Good. Now updating the plan with your final answers — refined strategies, conventional admin-fee-only model, two fully isolated TreasuryModule contracts — then building. Here is the final revised plan:

---

## Implementation Plan: Two-Community Vault System

**Saved to** `arc-studio-plans/SHARIAH_VAULT.md`

---

### Core architecture decision

Two completely isolated vault communities. Capital, fees, and treasury accounts never mix.

| | Conventional | Shariah |
|---|---|---|
| Fee | 0.75% AUM admin fee — flat, no profit share | 0.5% Wakala (AUM) + 10% Musharakah above 4% hurdle |
| Zakat | None | 2.5% of gross Musharakah profit, auto-routed before split |
| Treasury | `ConventionalTreasury.sol` | `ShariahTreasury.sol` |
| Strategies | S1–S4 (unchanged) | S1-H through S5-H (5 halal strategies) |
| Score engine | Existing `ScoreAggregator` | New `ShariahScoreAggregator` (5-strategy enum) |

---

### Shariah asset scope confirmed

USDC, USDT, ETH, PAXG, OUSG, BUIDL — all permitted. The *asset* is halal; only the *protocol action* (lending at interest, perp funding, front-running) is haram. The `ShariahVault` enforces this via a `screened` adapter mapping — `deployCapital` reverts for any unscreened address.

---

### 5 Shariah strategies

| | Name | Trigger | Signal | Rule | Shariah basis |
|---|---|---|---|---|---|
| S1-H | USDC/ETH Cross-Chain Spread | 30s | ETH/USDC deviation across chains | ≥0.3% | Commodity pair arbitrage |
| S2-H | Tokenized Gold Spread | 30s | PAXG/USDC deviation | ≥0.3% | Gold arbitrage, universally halal |
| S3-H | Halal LP (USDC/ETH or USDC/PAXG) | 30s | Uniswap V3 fee APY, no lending | ≥8% APY | Fee income from real trades |
| S4-H | Commodity Murabaha | Event-driven | Trade request + markup % | ≥$10K AND ≥1.0% markup | Cost-plus sale, fully disclosed |
| S5-H | RWA/Sukuk Yield | 45s | OUSG/BUIDL NAV appreciation | ≥6% APY | Asset ownership, no borrowing |

---

### Two isolated TreasuryModules

Both are deployments of the same `TreasuryModule.sol` base. The `feeSource` constructor arg locks each treasury to exactly one vault — no other address can call `accrue()`. Events emit `treasuryType` ("Conventional" / "Shariah") on every accrual and claim for clean indexing.

---

### New contracts (8 files)
`TreasuryModule.sol` · `ZakatModule.sol` · `ShariahVault.sol` · `ConventionalVault.sol` · `ShariahScoreAggregator.sol` · `HalalLPAdapter.sol` · `CommodityMurabahaAdapter.sol` · `RwaYieldAdapter.sol`

---

## Ready to build?

Say "build" and I'll start with the treasury contracts, then the vaults, adapters, score aggregator, agent strategies, and finally the frontend components — all in the sequence above.
