# Bro Pay

Payment orchestration platform for Thai businesses. Sits on top of Thai bank and PromptPay rails (via KBNK) to give merchants a single unified API for collecting payments, managing wallets, settling to bank, and paying out to customers.

> For the full product spec, see [PRD.md](./PRD.md). For architectural conventions, see [CLAUDE.md](./CLAUDE.md).

## Apps and packages

| Workspace | What it is | Dev port |
|---|---|---|
| `apps/api` | Hono REST API on Cloudflare Workers + D1 (OpenAPIHono, Zod, Hono RPC) | `:8787` |
| `apps/admin` | Internal ops dashboard — staff manage merchants, customers, transactions, settlements, payouts, providers, webhooks | `:3000` |
| `apps/merchant` | Merchant portal — wallet, bank accounts, team, integrations; white-label branded | `:3001` |
| `apps/reseller` | Reseller portal — sub-merchant onboarding, commissions, branding, downline (separate from merchant since the 2026-05-21 reseller-entity refactor) | `:3002` |
| `apps/checkout` | Public payment page — customer completes PromptPay QR / bank transfer | `:3003` |
| `packages/ui` | shadcn/ui-derived components shared across apps | — |
| `packages/permissions` | Custom RBAC — staff roles, merchant roles, `buildAbility()` | — |
| `packages/typescript-config` | Shared tsconfig presets | — |

All five apps run on Cloudflare Workers. The frontend apps (admin, merchant, reseller, checkout) use **vinext** (Next.js App Router on Vite + Workers, not standard Next.js).

## Money flows

**Inbound (customer → merchant)**

```
merchant creates integration → issues API key
  → POST /v1/payment-intents (HMAC) → customer pays on checkout
  → KBNK confirms deposit → transaction recorded
  → settlement batches transactions → gross − fee → NET wired to merchant bank
  → fee cascades: reseller commission credits + platform-fee credit (see migrations 0032/0033)
```

**Outbound (merchant → customer)**

```
merchant tops up wallet (same KBNK QR flow)
  → creates payout to customer's verified bank account
  → KBNK executes bank transfer
  → wallet debited (gross + fee), ledger entry written
```

Fees never touch the merchant's wallet on the inbound side — they're deducted at settlement. On the outbound side fees come straight out of wallet balance.

## Prerequisites

- Node.js 22+
- pnpm 10+
- Cloudflare account (Workers, D1, KV, R2) + `wrangler login`

## Quickstart

```bash
# 1. Install
pnpm install

# 2. Environment
cp apps/api/.dev.vars.example apps/api/.dev.vars
# edit JWT_SECRET, Google OAuth creds, KBNK credentials

# 3. Database — fresh local D1
pnpm migrate:local
pnpm db:seed

# 4. Dev — api + admin (add --filter for others)
pnpm dev
```

Then log into the admin at http://localhost:3000 with any seed account.

## Seed accounts

All use password `password123`.

| Email | Role | Purpose |
|---|---|---|
| `super@bropay.com` | `super_admin` | Platform owner |
| `admin@bropay.com` | `admin` | Platform admin |
| `dev@bropay.com` | `developer` | Generic dev login |
| `folk@bropay.com` | `super_admin` | Dev — Folk |
| `boat@bropay.com` | `super_admin` | Dev — Boat |
| `tor@bropay.com` | `super_admin` | Dev — Tor |

Fixture data includes: 1 merchant (Thai Coffee Co), 1 KBNK-verified merchant bank account, 1 HMAC integration, 3 customers with verified bank accounts, 6 historical payment intents (mixed statuses), 3 transactions, 1 settlement (gross 60000 / fee 900 / net 59100), 1 completed payout, 1 webhook endpoint.

Seed is idempotent (`INSERT OR IGNORE` on stable IDs) and timestamps use `datetime('now', '-N days')` so dates slide forward every re-seed.

## Commands

| Command | What it does |
|---|---|
| `pnpm dev` | Turbo dev (api + admin) |
| `pnpm dev:api` \| `dev:admin` \| `dev:merchant` \| `dev:checkout` | One app |
| `pnpm build` | Build every workspace |
| `pnpm typecheck` | `tsc --noEmit` across all packages |
| `pnpm lint` | Biome lint |
| `pnpm test` \| `pnpm test:api:unit` | API unit tests for local development |
| `BROPAY_RUN_INTEGRATION=1 pnpm test:api:integration` | DB-backed API route and integration tests |
| `pnpm e2e` | Playwright (admin) |
| `pnpm migrate:local` \| `migrate:remote` | Apply D1 migrations |
| `pnpm db:seed` | Seed local D1 |
| `pnpm deploy:api` \| `deploy:admin` \| `deploy:merchant` \| `deploy:checkout` | Deploy to Cloudflare Workers |

## Deployment

GitHub Actions (`.github/workflows/ci.yml`) runs three environments:

| Trigger | Environment | Steps |
|---|---|---|
| Pull request | Preview | lint + typecheck + API unit/integration tests → deploy preview → comment PR with URLs |
| Push to `staging` | Staging | check → migrate → deploy (api + admin + merchant + checkout) → smoke test |
| Push to `main` | Production | check → migrate → deploy → smoke test |

**Required GitHub secrets:**

```
CLOUDFLARE_API_TOKEN
CLOUDFLARE_ACCOUNT_ID
JWT_SECRET
GOOGLE_CLIENT_ID
GOOGLE_CLIENT_SECRET
KBNK_CLIENT_ID
KBNK_CLIENT_SECRET
```

## Testing

- **Unit / integration** — `pnpm test` / `pnpm test:api:unit` runs the fast API unit suite for local development. `BROPAY_RUN_INTEGRATION=1 pnpm test:api:integration` runs DB-backed API route tests plus `apps/api/src/test/integration` against in-process SQLite via `node:sqlite` (the D1 mock lives in `apps/api/src/test/mock-d1.ts` — real SQLite, no query stubbing). API Vitest scripts default to four fork workers; use `VITEST_MAX_WORKERS=1` or `2` for constrained machines or debugging. Deploy/CI runs both types.
- **Enum drift guard** — `apps/api/src/test/db-enum-guard.test.ts` fails if a UI enum array diverges from a DB `CHECK` constraint. Keeps UI and schema in sync.
- **E2E shell flows** — `scripts/e2e/*.sh` hit a running API against the KBNK staging sandbox (payment, settlement, wallet, KBNK integration).
- **Playwright** — admin navigation + auth (`apps/admin/e2e/`).

## AI-assisted development

`.claude/agents/` contains nine Claude Code sub-agents preconfigured with the project's patterns: `dev`, `reviewer`, `tester`, `migrator`, `refactorer`, `deployer`, `debugger`, `auditor`, `documenter`.

## Further reading

- [PRD.md](./PRD.md) — full product spec, personas, phases, schema, API surface
- [CLAUDE.md](./CLAUDE.md) — architectural conventions, coding rules, API patterns
- [apps/admin/CLAUDE.md](./apps/admin/CLAUDE.md) — admin-specific gotchas (vinext, static assets, proxy matcher)
- [apps/api/CLAUDE.md](./apps/api/CLAUDE.md) — API route/middleware conventions

## License

Proprietary — Bro Pay internal.
