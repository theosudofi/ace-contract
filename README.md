# Ace EVM

Ace EVM is a compact Solidity redesign of the Sui Move `ace-contract` perpetuals protocol. It targets
Robinhood Chain and deliberately avoids carrying Sui-specific or deprecated surface area into the
first EVM release.

> **Status:** functional, tested prototype. It has not been independently audited and must not hold
> production funds until it has completed protocol-specific economic testing and a security audit.

## What is included

- isolated-margin perpetual positions with partial and full close;
- permissionless liquidation, skew-based funding, trading fees, and pool solvency checks;
- LP deposits and withdrawals with an open-interest reserve requirement;
- a path-integrated price-impact model that penalizes skew-increasing trades and gives bounded
  rebates to skew-reducing trades;
- a configurable oracle router with staleness checks, failover, and cross-source deviation limits;
- Chainlink Data Feed, Pyth, and Stork adapters;
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
- maximum price age and maximum cross-source deviation.

Chainlink is intended as the primary Robinhood Chain path. Pyth uses `getPriceNoOlderThan` and
checks its confidence interval. Stork consumes the `getTemporalNumericValueV1` 1e18-quantized
value. Pyth and Stork contracts/feeds must exist on the target network before their adapters can be
enabled. Chainlink Data Streams are not treated as ordinary Data Feeds; a future Streams adapter
should verify reports through Robinhood Chain's verifier proxy before exposing a price.

## Build and test

Foundry is required.

```bash
forge build
forge test --offline
```

The suite covers price-impact path independence, skew rebates, stale and diverging oracle sources,
fallback behavior, profitable close, funding, pause behavior, liquidity reserves, and liquidation.

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

- `src/AcePerp.sol` — positions, liquidity, PnL, fees, funding, and liquidation.
- `src/libraries/PriceImpactModel.sol` — execution-price model.
- `src/oracles/OracleRouter.sol` — source selection and circuit breaking.
- `src/oracles/ChainlinkAdapter.sol` — Chainlink Data Feeds.
- `src/oracles/PythAdapter.sol` and `src/oracles/StorkAdapter.sol` — retained integrations.

See [SECURITY.md](SECURITY.md) for assumptions and pre-production work.
