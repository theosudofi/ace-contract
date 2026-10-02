# Ace

Ace is a Solidity perpetuals protocol for Robinhood Chain. One shared LP pool holds a collateral
set, and one or more perp markets trade against that pool.

> **Status:** functional, tested prototype. It has not been independently audited and must not hold
> production funds until it has completed protocol-specific economic testing and a security audit.

## What is included

- one shared LP pool per collateral set, with one or more perp markets on that pool;
- position increase, collateral add/withdraw, partial/full close, minimum remainder, and liquidation;
- a per-token vault reserving fee, plus funding either from open-interest skew or from LP PnL
  including open mark-to-market, with trading fees routed to treasury, insurance, keeper, and LPs;
- LP pricing over each token's cash, escrow, and unpaid reserving fee, plus unpaid funding.
  Open trader PnL is settled from the position escrow and is not marked into the share price;
- a path-integrated price-impact model that penalizes skew-increasing trades and gives bounded
  rebates to skew-reducing trades;
- market, limit, stop-loss, and take-profit orders. Opens and decreases are created first and
  filled by a keeper. An empty keeper list is permissionless; a non-empty list is an allowlist;
- target weights and a rebase fee on deposits, withdrawals, and collateral swaps. A withdrawal
  pays only from that token's vault and cannot exceed that vault's value;
- a loss-protection vault that can take a cut of trader losses and fund a share of wins;
- a function mask and a `migrate` entrypoint that advances the version by one;
- an oracle router with bid/ask prices, action-specific age limits, order timestamp binding,
  market status, failover, cross-source checks, and a historical-deviation circuit breaker;
- Chainlink Data Feed and verified Data Streams adapters plus same-transaction Pyth/Stork updates;
- two-step ownership, a separate pause guardian, and close/liquidate availability while paused.

## Price impact

Price impact is a bounded potential on absolute open-interest skew:

```text
potential(skew) = maxOI * impactFactor * (min(|longOI-shortOI| / maxOI, 1) ^ exponent)
impactUSD        = potential(before) - potential(after)
impactRate       = impactUSD / tradeSize
```

Negative impact is a cost; positive impact is a rebate. Because execution uses the change in
potential over the full OI path, splitting one order into smaller orders produces the same
size-weighted impact (apart from integer rounding). Exponents are restricted to 1 or 2.

## Oracle model

`OracleRouter` maps a protocol asset ID to a primary and optional secondary adapter. It supports:

- primary-only reads;
- primary reads with automatic fallback;
- both-sources-required reads;
- maximum price age and maximum cross-source deviation;
- conservative min/max prices (bid/ask or Pyth confidence bounds);
- a requirement that an execution price was published no earlier than its order submission;
- RWA market-open status and L2 sequencer availability checks in adapters;
- a historical price-deviation breaker with a configurable cooldown window.

Chainlink is intended as the primary Robinhood Chain path. `ChainlinkDataStreamAdapter` submits the
signed payload to the configured verifier and stores only the verified feed's bid/ask report. Pyth
uses price ± confidence and Stork uses its 1e18-quantized value; both adapters accept update
payloads in the same transaction as order execution. Addresses, report schema, feed decimals, and
fees must be checked against the live provider deployment before production configuration.

## Isolated pool accounting

Each pool lists the tokens it accepts and deploys one `MarketPoolToken`. Long and short are
position directions, not separate vaults. Several markets can share that pool: an NVDA/USDG pool
can margin both the NVDA perp and another perp, in either token. Trader margin is accounted on the position. LP coins escrowed for that position are accounted
on the token vault. The LP price is:

```text
sum of each token vault (LP cash + escrowed LP coins + unpaid reserving fee)
  + unpaid funding
Trader margin and open mark-to-market are outside this price. A withdrawal in one token
cannot take more than that token's own vault value.
```

Aggregate size tokens preserve entry-price exposure without iterating positions. Open profit
does not move the LP price until it settles, and then only through the escrowed coins. A reserving
fee accrues on each token's escrow. A pool cannot withdraw another pool's assets. Markets on the
same pool share its LP token and its per-token vaults.

## Build and test

Foundry is required.

```bash
forge build
forge test --offline
```

The suite covers a shared pool, multiple markets, transferable shares, marked-to-market NAV,
borrowing, funding, imbalance fees, collateral swaps, keeper execution, loss protection, position
changes, minimum partial-close size, orders, price-impact path independence, oracle timestamp and
market-status rules, sequencer checks, Data Streams verification, and Pyth/Stork updates.

## Robinhood Chain

| Network | Chain ID | RPC |
| --- | ---: | --- |
| Mainnet | 4663 | `https://rpc.mainnet.chain.robinhood.com` |
| Testnet | 46630 | `https://rpc.testnet.chain.robinhood.com` |

Robinhood Chain is EVM-compatible and supports normal Foundry deployment. See the official
[deployment guide](https://docs.robinhood.com/chain/deploy-smart-contracts/) and
[Chainlink Data Streams page](https://docs.robinhood.com/chain/data-streams/).

Copy `.env.example`, use a throwaway testnet deployer, and run:

```bash
source .env
forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$RH_TESTNET_RPC_URL" \
  --broadcast
```

The deployment script deploys `OracleRouter`, `AcePerp`, and `AceOrderManager`, then points the core
at the order manager. Collateral tokens, oracle feeds,
pools, and markets are configured afterward by the owner. Create a pool with the tokens it should
accept, register a price for each of those asset ids, then attach one market. For an NVDA perp
margined in NVDA or USDG, the pool lists both tokens and the market's index asset is NVDA. Verify
token and feed addresses, heartbeat, decimals, market hours, and risk parameters first. For
stock/RWA markets, operational logic must account for exchange closures and feed market status; a
merely recent price is not proof that the underlying venue is open.

## Main contracts

- `src/AcePerp.sol` — shared vault accounting, positions, PnL, borrowing, funding, fees, swaps, and liquidation.
- `src/AceOrderManager.sol` — market and conditional orders, keeper allowlist, and native execution fees.
- `src/market/MarketPoolToken.sol` — transferable LP share and shared pool vault.
- `src/libraries/PriceImpactModel.sol` — execution-price model.
- `src/oracles/OracleRouter.sol` — source selection and circuit breaking.
- `src/oracles/ChainlinkAdapter.sol` — Chainlink Data Feeds.
- `src/oracles/ChainlinkDataStreamAdapter.sol` — verified signed bid/ask reports.
- `src/oracles/PythAdapter.sol` and `src/oracles/StorkAdapter.sol` — same-transaction price updates.

See [SECURITY.md](SECURITY.md) for assumptions and pre-production work.
