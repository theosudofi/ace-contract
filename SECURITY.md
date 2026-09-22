# Security and economic assumptions

This repository is not audited. Its tests establish intended behavior, not production safety.

## Trust and control

- The owner can add markets and change risk, borrowing, fee-routing, and price-impact parameters.
- Ownership transfer is two-step. Production ownership should be a timelocked multisig.
- The guardian can pause new positions or disable a market. Users can still decrease positions and
  positions remain liquidatable.
- Oracle adapter and token addresses are trusted configuration. Verify bytecode and proxy upgrade
  authority before registration.

## Accounting assumptions

- One ERC-20 token supplies LP liquidity and isolated trader margin, but custody, OI, PnL, and
  reserves are isolated for every market side.
- Fee-on-transfer, rebasing, callback, and tokens with more than 18 decimals are unsupported.
- LP shares are marked to market using physical assets, aggregate pending position PnL, and the LP
  portion of pending borrowing fees. Conservative collateral and index bounds are used.
- Bad debt is limited by isolated collateral but can still reduce LP assets during fast gaps.
- Market OI caps, leverage, maintenance margin, borrowing factor, and side reserve factor must be
  calibrated together using stress tests.

## Oracle assumptions

- Prices are USD-denominated and normalize to 18 decimals.
- Separate open, close, and liquidation ages must be no longer than provider heartbeats.
- Two-source validation is useful only when sources are genuinely independent.
- RWA markets must configure a status feed; `alwaysOpen` is only appropriate for 24/7 assets.
- Data Streams verifier, feed ID, report decimals, fee behavior, and report schema are trusted
  configuration and must match the deployed verifier version.

## Required before production

1. Independent smart-contract and economic audits.
2. Stateful invariant fuzzing for token conservation, pool solvency, and aggregate OI.
3. Adversarial oracle, sequencer downtime, stale-market, and gap-risk simulations.
4. Withdrawal queue / cooldown, explicit bad-debt socialization, and ADL or recovery handling.
5. Timelocked governance, bounded parameter changes, monitoring, and incident runbooks.
6. Verified Robinhood Chain feed/token addresses and deployment rehearsal on chain ID 46630.
