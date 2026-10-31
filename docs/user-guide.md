# DeFiVault User Guide

DeFiVault is a USDC vault on Arc. You deposit USDC once; the vault allocates it to approved strategies, guided by an AI agent that scores opportunities from live market data. A Shariah tier runs on profit sharing instead of interest, with its rules written into the contracts.

> Hackathon demo on Arc mainnet. The contracts are unaudited, governance is held by single keys, and no Shariah board has ruled on the strategies yet. Use small amounts only.

## Getting started

### What you need

- A browser wallet such as MetaMask or Rabby.
- USDC on Arc. On Arc, USDC is also the gas token, so the same balance pays for transactions. A few cents covers a deposit and a redeem.

### Add Arc to your wallet

The app asks your wallet to switch to Arc automatically when you click Switch to Arc Mainnet. To add it by hand:

| Field | Value |
|---|---|
| Network name | Arc |
| RPC URL | https://rpc.mainnet.arc.io |
| Chain ID | 5042 |
| Currency symbol | USDC |
| Block explorer | https://explorer.arc.io |

### Deposit

1. Click Connect Wallet (top right) and approve the connection.
2. Open Vault and choose a tier.
3. Enter an amount and click Approve USDC. This lets the vault move exactly that amount from your wallet.
4. Click Deposit. You receive vault shares (svUSDC) in return.

### Redeem

1. Open Vault and switch to the Redeem tab.
2. Click Redeem All Shares. Your shares are burned and USDC is sent back to your wallet.

Let your wallet estimate the gas. When the vault has realized profit, a redeem also settles your share of the profit distribution, which needs more gas than a plain transfer; a wallet with a hard-coded low gas limit will fail.

## How the vault works

### Shares and share price

The vault follows the ERC-4626 standard. When you deposit, you receive shares priced at the vault's net asset value (NAV) per share. When you redeem, each share is worth its slice of NAV at that moment. You never hold the strategy positions directly; the vault does.

### How NAV is valued

- Idle USDC counts at face value.
- Losses on deployed capital are marked into the share price straight away.
- Gains count only once they are realized (returned to the vault), so no one can buy in cheaply just before a gain is booked.
- Gold positions are priced from a gold price oracle. If the oracle goes stale, the position is valued at its last good price minus a safety haircut.
- The share price already excludes the cut a profit distribution would take, so no one can redeem just before a distribution and leave others to pay it.

### When you can withdraw

You can redeem at any time, up to the USDC the vault holds idle. Capital deployed into a strategy has to be recalled first, so a very large redeem may be limited to the idle balance. Redemptions are never blocked by oracles or other external systems.

### Safety limits

- At most 80% of the vault can be deployed; the rest stays liquid.
- Gold exposure is capped at 30% of the vault.
- At most 5 non-gold strategies can be funded at once.
- New deposits pause automatically if a strategy's value cannot be read or its losses exceed a small threshold. Exits stay open.

## Vault tiers

Each tier is a separate vault with its own NAV and share token. Capital never moves between tiers.

| Tier | Community | Strategies | Min score | Cooldown | Fees |
|---|---|---|---|---|---|
| Passive | Conventional | S1, S4 | 80 | 2 hours | 0.75% a year |
| Aggressive | Conventional | S1 to S4 | 60 | 30 minutes | 0.75% a year |
| Conservative Shariah | Shariah | S2-H, S3-H, S6-H | 80 | 2 hours | 0.5% Wakala + 10% Musharakah |
| Dynamic Shariah | Shariah | S1-H to S4-H, S6-H | 70 | 1 hour | 0.5% Wakala + 10% Musharakah |

Min score is the AI score (0 to 100) a strategy needs before capital can be deployed into it. Cooldown is the minimum time between two deployments.

On Arc mainnet today, the Conservative Shariah vault is deployed. The other tiers run on Arc Testnet.

## Strategies

Every strategy has a scorer in the AI agent. Each card on the Strategies page shows the live score, how often it updates, what data it reads, what signal it computes, and the rule that turns the signal into a high score.

### Conventional strategies

| | Strategy | What it looks for | High score when |
|---|---|---|---|
| S1 | Cross-Chain Stablecoin Spread | USDC price differences between Uniswap pools on Arbitrum, Base and Optimism | The spread is above 0.3% |
| S2 | Perpetual Funding Rate Arb | Hyperliquid ETH funding, annualized into a carry yield | Annualized funding is above 12% |
| S3 | Bridge Flow Front-Running | Large Stargate bridge transfers and their price impact on arrival | A transfer above $500K with impact above 0.4% |
| S4 | Liquidation + RWA Yield | Aave positions near liquidation, and tokenized treasury yield versus Aave borrow rates | Several at-risk positions and a spread above 1.5% |

### Shariah strategies

| | Strategy | How it earns | Status |
|---|---|---|---|
| S1-H | USDC/ETH Cross-Chain Spread | Price differences on a commodity pair, no interest | Dynamic tier only |
| S2-H | Tokenized Gold Spread | Buys and sells PAXG gold in a single transaction when prices diverge | Screened, board ruling pending |
| S3-H | Uniswap V3 Liquidity Pool | Trading fees from providing liquidity (partnership in a trading pool) | Screened, board ruling pending |
| S4-H | Commodity Murabaha | Cost-plus sale with the markup disclosed before the trade | Dynamic tier only |
| S5-H | RWA Yield | Retired: the underlying is interest-bearing | Suspended |
| S6-H | Gold Allocation | Holds up to 20% in allocated gold (XAUT); return follows the gold price | Screened, board ruling pending |

Gold trades always settle in one transaction (hand-to-hand exchange), and gold strategies are never routed cross-chain.

## The AI agent

### What it does

The agent is a service that runs continuously next to the app. Every 30 to 60 seconds it:

1. Reads live data: Uniswap pools on Ethereum, Arbitrum, Base and Optimism, Hyperliquid funding rates, Stargate bridge flows, Aave health factors and borrow rates, and tokenized treasury yields.
2. Scores each strategy from 0 to 100, with a one-line reason (for example "20.7 bps max deviation").
3. Screens protocols against a Shariah rule set (business activity, interest-bearing income, leverage) and marks each one PASS, REVIEW or FAIL. This screen is advisory. Only the Shariah board can approve a strategy.
4. Publishes the scores and screening results to the app.

The Agent Engine panel shows the raw market data the agent read in its latest cycle and how it evaluated each strategy. Run cycle asks the agent to rescan immediately.

### How a score becomes an allocation

```
market data → AI agent → score (0-100) → score aggregator (on-chain) → executeWinner() → vault deploys capital
```

1. The oracle role writes the scores on-chain to the score aggregator.
2. The aggregator picks the highest-scoring enabled strategy. Scores older than 5 minutes are ignored.
3. Anyone can call `executeWinner()` from the Execute tab on the Vault page. The executor checks that:
   - the winner is allowed in this tier,
   - its score is at or above the tier's minimum,
   - the cooldown has passed,
   - gas is below the executor's ceiling.
4. The executor sizes the deployment (within the tier's limits, the vault's 80% cap and the 30% gold cap) and the vault sends capital to the strategy adapter.

The agent never holds user funds, and it cannot move them. Its only on-chain power is writing scores; the contracts enforce every limit.

### Current status

The agent runs live and scores from real market data. On-chain score writing and execution have been run end to end on Arc Testnet, where `executeWinner()` funded a real Uniswap V3 position through the vault and recalled it. Letting the agent sign its own score updates automatically is the next step on the roadmap.

## Fees

### Conventional tiers

| Fee | Rate | When |
|---|---|---|
| Management fee | 0.75% of assets a year | Accrues over time |

### Shariah tiers

| Fee | Rate | When |
|---|---|---|
| Wakala (agency) fee | 0.5% of assets a year | Accrues over time, like a management fee |
| Musharakah (profit share) | 10% of profit above a 4% yearly hurdle | Only when profit is distributed |

The manager earns no profit share while the share price is below its previous high (a high-water mark), so the manager is not paid for recovering losses.

## Shariah governance

### Profit distribution waterfall

Every profit distribution in a Shariah vault runs these steps in order:

1. Purification: any income the board identifies as non-permissible is sent to the charity wallet. Default 0%, maximum 10%.
2. Charity: a voluntary contribution (sadaqah), default 2.5% of profit, maximum 5%.
3. Musharakah split: the manager's 10% share of profit above the hurdle, subject to the high-water mark.
4. Depositors: the rest stays in the vault and raises the share price.

When you redeem while realized profit exists, your slice of this waterfall is settled at that moment, so departing holders never shift the cost onto the ones who stay.

### Strategy screening

A strategy adapter can receive funds only after it is screened in the on-chain adapter registry:

- A board member proposes the adapter together with the hash of a published pronouncement.
- A 30-day timelock must pass before the screening takes effect.
- Every screening has an expiry date.

"Screened, board ruling pending" in the app means the protocol passed the agent's advisory screen but the board has not issued a ruling. Until it does, no capital goes to that strategy on mainnet.

### Changing the rules

Every Shariah parameter (charity rate and wallet, purification rate, the deposit-pause threshold, cross-chain recipients) can only change through a board proposal followed by a 30-day timelock. Hard safety caps, such as the 30% gold limit and the maximum charity rate, are fixed in the contracts and cannot be changed.

## Risks

- The contracts are unaudited. The code has passed more than 2,000 automated tests, static analysis and internal reviews, but no independent audit.
- Governance is held by single keys rather than multisig wallets.
- Liquidity positions can lose value when prices move (impermanent loss); gold positions follow the gold price.
- Gold valuation depends on a price oracle; a stale oracle triggers a haircut and pauses deposits.
- Only idle USDC can be redeemed instantly; deployed capital must be recalled first.
- The Shariah board has not ruled on any strategy yet.

## Contract addresses (Arc mainnet)

| Contract | Address |
|---|---|
| Shariah vault (Conservative) | [0xDc40ed79F74141BBba84d54f84Eafd43CD8Bc470](https://explorer.arc.io/address/0xDc40ed79F74141BBba84d54f84Eafd43CD8Bc470) |
| Adapter registry | [0xb7b1cFEbB0390aA16945aCe518118d491016A793](https://explorer.arc.io/address/0xb7b1cFEbB0390aA16945aCe518118d491016A793) |
| Executor | [0x23836611FDF05fAc07a12416e9c8C250F9cdF671](https://explorer.arc.io/address/0x23836611FDF05fAc07a12416e9c8C250F9cdF671) |
| Score aggregator | [0x2b8dA7636aeb97C153F81C7168302dF45eD3643a](https://explorer.arc.io/address/0x2b8dA7636aeb97C153F81C7168302dF45eD3643a) |
| Treasury | [0xf17585cB249EF6Ab8bB450595107DB34d46FfE91](https://explorer.arc.io/address/0xf17585cB249EF6Ab8bB450595107DB34d46FfE91) |
| Charity module | [0x99D53De353d32e34F18a21c8c760424FC92D01a9](https://explorer.arc.io/address/0x99D53De353d32e34F18a21c8c760424FC92D01a9) |
| Purification escrow | [0x3dA4697D8154A794DaC1d63276072142ed7C1890](https://explorer.arc.io/address/0x3dA4697D8154A794DaC1d63276072142ed7C1890) |

## FAQ

**Why is my deposit button disabled?**
Check that your wallet is connected, on Arc, and holds enough USDC. Deposits also pause automatically while a strategy's value cannot be read or a gold oracle is stale.

**Why can I redeem only part of my balance?**
Only idle USDC can be paid out at once. The rest is deployed in strategies and returns when the manager recalls it.

**Can the AI agent take my funds?**
No. The agent only publishes scores. Deposits and withdrawals go through the vault contract, and the executor can only send capital to strategies screened in the registry, within fixed limits.

**Is the Shariah vault approved by scholars?**
Not yet. The design follows Shariah principles (profit sharing, purification, charity, no interest-bearing strategies), and the agent screens protocols, but no board has issued a ruling. The app says "board ruling pending" wherever that applies.

**What does "Live" mean on a strategy card?**
The score comes from the running AI agent and today's market data. If the app cannot reach the agent, it shows clearly marked simulated scores instead.

## Glossary

| Term | Meaning |
|---|---|
| NAV | Net asset value: everything the vault owns, valued by the rules above |
| Share (svUSDC) | Your claim on a slice of the vault's NAV |
| Wakala | An agency fee paid for managing the vault |
| Musharakah | A partnership where profit is shared and losses are borne by capital |
| Hurdle | The yearly return depositors receive before the manager shares in profit |
| High-water mark | The highest share price reached; the manager earns nothing until it is exceeded again |
| Purification | Giving away income identified as non-permissible |
| Sadaqah | A voluntary charitable contribution |
| Murabaha | A cost-plus sale with the profit margin disclosed upfront |
| Timelock | A mandatory waiting period before a governance change takes effect |
| CCTP | Circle's Cross-Chain Transfer Protocol, used to move USDC between chains |
