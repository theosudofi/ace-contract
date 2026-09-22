# Ace EVM

Ace EVM is a compact Solidity redesign of the Sui Move `ace-contract` perpetuals protocol. It targets
Robinhood Chain and deliberately avoids carrying Sui-specific or deprecated surface area into the
first EVM release.

> **Status:** functional, tested prototype. It has not been independently audited and must not hold
> production funds until it has completed protocol-specific economic testing and a security audit.

## What is included

- isolated per-market, per-side vaults with transferable ERC-20 LP shares;
- position increase, collateral add/withdraw, partial/full close, minimum remainder, and liquidation;
- utilization-based borrowing, trading fees, and independently routed treasury, insurance, keeper,
  and LP fee shares;
- marked-to-market LP pricing over pool assets, aggregate pending position PnL, and pending LP
  borrowing fees;
- a path-integrated price-impact model that penalizes skew-increasing trades and gives bounded
  rebates to skew-reducing trades;
- escrowed limit, stop-loss, and take-profit orders with expiry, cancellation, and native execution
  fees;
- an oracle router with bid/ask prices, action-specific age limits, order timestamp binding,
  market status, failover, cross-source checks, and a historical-deviation circuit breaker;
- Chainlink Data Feed and verified Data Streams adapters plus same-transaction Pyth/Stork updates;
- two-step ownership, a separate pause guardian, and close/liquidate availability while paused.

## Deliberately removed from the first EVM core

The original Move repository contains deprecated entrypoints and several features coupled to Sui's
object model. This version does not port the duplicated v1/v2/v3 functions, `SCARD`, referral
storage, USDZ minting, delayed order variants, Move capability wrappers, dynamic object bags,
multi-collateral swaps, or legacy valuation snapshots. Direct execution and one settlement token
keep the accounting and audit surface small. These features should return only as separate modules
with a demonstrated product need.

## Price impact

The old model applies a spread from final-side utilization and then adds a reference-size
multiplier. The new model assigns a bounded potential to absolute OI skew:

```text
potential(skew) = maxOI * impactFactor * (min(|longOI-shortOI| / maxOI, 1) ^ exponent)
impactUSD        = potential(before) - potential(after)
impactRate       = impactUSD / tradeSize
```

Negative impact is a cost; positive impact is a rebate. Because execution uses the change in
potential over the full OI path, splitting one order into smaller orders produces the same
size-weighted impact (apart from integer rounding). Exponents are restricted to 1 or 2, eliminating
the unsafe arbitrary fixed-point exponentiation found in the Move implementation.

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

Each market deploys independent long and short `MarketPoolToken` vaults. Trader collateral for a
side and that side's LP liquidity are held in the same vault but tracked separately. Its LP NAV is:

```text
vault assets - open-position collateral - aggregate trader PnL + pending LP borrowing fees
```

Aggregate size tokens preserve entry-price exposure without iterating positions. A profitable
trader liability lowers the LP token price immediately; a loss or accrued LP borrowing fee raises
it. One market or side cannot withdraw another market's assets.

## Build and test

Foundry is required.

```bash
forge build
forge test --offline
```

The suite covers isolated vaults, transferable shares, marked-to-market NAV, borrowing, position
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

The deployment script registers Chainlink adapters for collateral and one index asset, then deploys
the core. Create each market only after independently verifying the token, feed addresses,
heartbeat, decimals, market hours, and risk parameters. For stock/RWA markets, operational logic
must account for exchange closures and feed market status; a merely recent price is not proof that
the underlying venue is open.

## Main contracts

- `src/AcePerp.sol` — isolated vault accounting, positions, PnL, borrowing, fees, and liquidation.
- `src/AceOrderManager.sol` — conditional-order escrow, expiry, cancellation, and keeper payment.
- `src/market/MarketPoolToken.sol` — transferable LP share and isolated side vault.
- `src/libraries/PriceImpactModel.sol` — execution-price model.
- `src/oracles/OracleRouter.sol` — source selection and circuit breaking.
- `src/oracles/ChainlinkAdapter.sol` — Chainlink Data Feeds.
- `src/oracles/ChainlinkDataStreamAdapter.sol` — verified signed bid/ask reports.
- `src/oracles/PythAdapter.sol` and `src/oracles/StorkAdapter.sol` — retained integrations.

See [SECURITY.md](SECURITY.md) for assumptions and pre-production work.
