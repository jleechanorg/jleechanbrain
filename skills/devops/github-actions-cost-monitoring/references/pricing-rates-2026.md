# GH Actions Pricing Reference (2026)

Authoritative per-SKU rates captured from the live cost-monitor work, 2026-08-06. These rates apply to public/private repos on GitHub-hosted runners billed by the minute.

## Standard SKU rates (USD per minute)

| Runner type | Rate | Notes |
|---|---|---|
| Linux hosted (2-core) | $0.008 | The most common case |
| Windows hosted (4-core) | $0.016 | |
| macOS hosted (3-core, M1) | $0.08 | Most expensive |
| macOS hosted (larger, M1 Pro/Intel) | $0.16 / $0.32 | Less common |
| Self-hosted | **$0** | Only machine-wear applies |

## Verification

Live billing API for `jleechanorg` in 2026-08 confirmed:
- All `jleechanorg/*` Actions spend was on self-hosted runners (per PR #8285)
- August MTD total: $6.16 across the entire org (mostly `jleechanorg/ralph`)
- `jleechanorg/worldarchitect.ai` Actions cost: $0.00 in August

## When to re-verify

GitHub can revise rates. Verify at:
- https://github.com/features/actions (pricing page)
- https://docs.github.com/en/billing/managing-billing-for-github-actions/about-billing-for-github-actions

If a rate change happens, patch the constants at the top of `gh-actions-cost-monitor.sh` (or equivalent script) and add a regression test.

## Tax / VAT

GH billing in USD; VAT/tax added at checkout for some regions. Doesn't affect the per-minute constants; only the final invoice.
