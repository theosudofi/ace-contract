# Security and economic assumptions

This repository is not audited. Its tests establish intended behavior, not production safety.

## Trust and control

- The owner can add markets and change risk, fee, funding, and price-impact parameters.
- Ownership transfer is two-step. Production ownership should be a timelocked multisig.
- The guardian can pause new positions or disable a market. Users can still decrease positions and
  positions remain liquidatable.
- Oracle adapter and token addresses are trusted configuration. Verify bytecode and proxy upgrade
  authority before registration.

## Accounting assumptions

- One ERC-20 token supplies LP liquidity and isolated trader margin.
- Fee-on-transfer, rebasing, callback, and tokens with more than 18 decimals are unsupported.
- LP shares reflect realized pool token accounting. Unrealized position PnL is not marked into the
  share price. A production vault should add withdrawal queues and conservative unrealized-PnL
  accounting.
- Bad debt is limited by isolated collateral but can still reduce LP assets during fast gaps.
- Market OI caps, leverage, maintenance margin, and the global liquidity reserve must be calibrated
  together using stress tests.

## Oracle assumptions

- Prices are USD-denominated and normalize to 18 decimals.
- `maxPriceAge` must be no longer than the feed heartbeat and should be tighter for liquidation.
- Two-source validation is useful only when sources are genuinely independent.
- RWA markets require market-hours and status validation in addition to timestamp freshness.
- Chainlink Data Streams require a dedicated report-verification adapter; do not put its verifier
  proxy into `ChainlinkAdapter`.

## Required before production

1. Independent smart-contract and economic audits.
2. Stateful invariant fuzzing for token conservation, pool solvency, and aggregate OI.
3. Adversarial oracle, sequencer downtime, stale-market, and gap-risk simulations.
4. Withdrawal queue / cooldown, per-market reserve attribution, and bad-debt handling.
5. Timelocked governance, bounded parameter changes, monitoring, and incident runbooks.
6. Verified Robinhood Chain feed/token addresses and deployment rehearsal on chain ID 46630.
