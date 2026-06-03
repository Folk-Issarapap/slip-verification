# Merchant API shell E2E

Headless API tests for `/v1/merchant/*`. No browser.

## Prerequisites

- API running: `pnpm dev:api` (default `http://localhost:8787`)
- `python3`, `curl`
- Optional: `wrangler` when a script seeds D1 locally

## Run

```bash
BROPAY_URL=http://localhost:8787 bash scripts/e2e/merchant/run-all.sh
BROPAY_URL=http://localhost:8787 bash scripts/e2e/merchant/analytics.sh
```

## Entry points

| Script | Purpose |
|--------|---------|
| `run-all.sh` | Runs all `merchant/*.sh` in explicit order (canonical aggregator) |
| `index.sh` | Profile-only smoke (`GET/PUT/PATCH /v1/merchant`); included in `run-all.sh` |

## Bootstrap

```bash
source scripts/e2e/_bootstrap.sh
bootstrap_demo_merchant
```

Exports: `DEMO_OWNER_TOKEN`, `DEMO_MERCHANT_ID`, `DEMO_ADMIN_TOKEN`, `DEMO_WALLET_ID`, etc.

Optional: `BOOTSTRAP_MERCHANT_ID`, `BOOTSTRAP_MERCHANT_SLUG`.

## Shared helpers

[`../_merchant-lib.sh`](../_merchant-lib.sh) — `pass`/`fail`/`step`/`json`, `hmac_sign()` for `/v1/api/*`.

## New script header

Copy [`SCRIPT-HEADER.template`](./SCRIPT-HEADER.template) when adding merchant smokes.
