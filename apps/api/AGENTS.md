# API Codex Instructions

These instructions apply under `apps/api`.

## Stack

Hono on Cloudflare Workers, OpenAPIHono, Zod v4, D1, typed Hono RPC, JWT auth,
RBAC, and production middleware.

## Structure

```text
src/
  index.ts
  lib/
    env.ts
    db.ts
    jwt.ts
    password.ts
    google-oauth.ts
    response.ts
    pagination.ts
    errors.ts
    hooks.ts
  middleware/
    security.ts
    auth.ts
    rate-limit.ts
    idempotency.ts
    audit.ts
  routes/v1/
  test/
```

## Middleware Order

Keep the effective middleware order:

```text
secureHeaders -> requestId -> timeout -> structuredLogger
-> bodyLimit -> csrf -> etag -> serverTiming
-> apiRateLimit -> idempotency -> cors
-> authRateLimit for /v1/auth/*
-> auditLog for /v1/*
-> route handler
```

## Route Pattern

```ts
const router = new OpenAPIHono<{ Bindings: Env; Variables: Variables }>({
  defaultHook: validationHook,
})

router.use("*", authMiddleware)

const listRoute = createRoute({
  method: "get",
  path: "/",
  tags: ["Products"],
  request: { query: ProductsQuerySchema },
  responses: {
    200: {
      content: {
        "application/json": { schema: PaginatedListSchema(ProductSchema) },
      },
      description: "OK",
    },
    500: {
      content: { "application/json": { schema: ErrorSchema } },
      description: "DB error",
    },
  },
})

const typed = router
  .openapi(listRoute, async (c) => {
    // handler
  })
  .openapi(getRoute, async (c) => {
    // handler
  })

export default typed
```

Always chain `.openapi()` and export the typed result. Imperative
`router.openapi(...)` loses RPC types.

## Result Pattern

Use `dbAll`, `dbFirst`, and `dbRun`; never parse raw D1 responses in handlers.

```ts
const result = await dbFirst(stmt, ProductSchema)
if (!result.ok) return c.json(dbError(result.code, result.message), 500)
return c.json(ok(result.data), 200)
```

Response shapes:

```ts
return c.json(ok(item), 200)
return c.json({ data: items, meta: paginationMeta(total, page, limit) }, 200)
return c.json(dbError("NOT_FOUND", "Not found"), 404)
```

Supported error codes include `UNAUTHORIZED`, `TOKEN_INVALID`, `NOT_FOUND`,
`DB_ERROR`, `PARSE_ERROR`, `VALIDATION_ERROR`, `CONFLICT`, `RATE_LIMITED`, and
`ACCOUNT_INACTIVE`.

## Validation

- Use strict Zod schemas with `.openapi()` metadata for public API shapes.
- Use `c.req.valid("json")`, `c.req.valid("query")`, or `c.req.valid("param")`.
- Zod v4 conventions: use `{ error: "..." }`; do not use
  `invalid_type_error` or `required_error`.
- Do not solve type errors with casts in route handlers.

## SQL

- Bind every dynamic value.
- Use allowlisted sort columns.
- For pagination, use `paginate()` and `paginationMeta()`.
- Admin list endpoints cap `limit` at 100. Picker UIs must use searchable
  server-side `q=` endpoints.

## Environment

Validate env at startup and type app bindings from `Env`.

```ts
import type { Env } from "./lib/env"
const app = new OpenAPIHono<{ Bindings: Env }>()
```

Important bindings include `DB`, `JWT_SECRET`, `ENCRYPTION_KEY`,
`ALLOWED_ORIGINS`, `ENVIRONMENT`, Google OAuth vars, frontend URLs, R2 buckets,
rate-limit KV, Cloudflare Email Service vars, platform fee defaults, platform
minimum fee floors, and platform per-transaction limits.

## Merchant Lifecycle

`POST /v1/admin/merchants` should be atomic: create merchant, auto-create wallet,
and insert inbound/outbound merchant fee configuration rows from env defaults.
Every new merchant starts with concrete editable fee rows.

## Amount Limits

Use `resolveAmountLimit()` for deposit, withdrawal, payout, and customer payment
limits.

- Deposit/withdrawal/payout resolution: wallet -> merchant -> env.
- Payment resolution: merchant -> env.
- Violations return 422 with `AMOUNT_BELOW_MIN` or `AMOUNT_ABOVE_MAX` and include
  effective min/max in the error body.

These are per-transaction limits and are distinct from daily/monthly aggregate
limits.

## Settlement Fee Model

Inbound settlement uses the positive-fee model.

- Merchant settlement bank receives gross amount.
- Fee is collected as wallet debit with `entry_type = "debit"` and
  `reference_type = "fee"`.
- Fee is distributed to reseller commissions and platform fee.
- Preflight must ensure wallet available balance can pay the fee.
- If insufficient, return a 422 insufficient-wallet response with a capped subset
  preview.
- Conservation rule: `fee_debit == sum(commissions) + platform_fee`.

Outbound payouts are unchanged: wallet debits `amount + fee`; destination
receives the requested amount.

## Money Unit Standard

DB schema, API contracts, and money math use integer satang. Human UI display and
form input use THB and convert at the frontend boundary. Amount, balance, fee,
volume, and money-limit columns should be `INTEGER` satang in migrations;
percentages/rates/scores can be `REAL`.

For money schema/code changes, use `.claude/agents/money-auditor.md` first. It
must audit the final migrated schema for `REAL` money columns, verify API
schemas/examples are satang, and check provider/UI conversion boundaries. Do not
write fractional money to D1.

## Ledger Rules

- Inbound payment success must not credit merchant wallet.
- Outbound create reserves amount plus fee.
- Provider completion finalizes the deduction.
- Provider failure/cancel releases the reservation.
- General ledger dual-writes must stay in sync with legacy wallet ledger writes.
- Reconciliation utilities should compare wallet `available_balance` against GL
  wallet account sums and preserve counts for legacy and GL entries.

## Auth And RBAC

- Staff dashboard login: `/v1/auth/staff/login`.
- Merchant dashboard login: `/v1/auth/merchant/login`.
- Old `/v1/auth/login` is removed.
- JWT middleware sets `userId`, `userRole`, `accountKind`, and `accountStatus`.
- Merchant routes require `X-Merchant-Id` and membership verification.
- Reseller routes use reseller membership from JWT, not `X-Merchant-Id`.
- Use `requirePermission` for staff CASL checks and
  `requireMerchantPermission` for merchant CASL checks.

## Reseller Rules

- Reseller model is exactly Platform -> Reseller -> Merchant.
- `resellers` are dedicated entities; do not revive `merchants.can_resell`,
  `parent_merchant_id`, or hierarchy tables.
- `wallets` belongs to exactly one merchant or reseller.
- Settlement commission is a single split using reseller commission percentage.
- Reseller fee floor violations return 422 `FEE_FLOOR_VIOLATION`.

## Migrations

`0001_initial.sql` is the squashed canonical schema. Do not back-edit it. Add the
next numbered migration for new schema changes. Fix migrations when tests fail;
do not patch schema in test setup.

## Tests

```bash
pnpm test
BROPAY_RUN_INTEGRATION=1 pnpm test:integration
```

Tests use real SQLite through `src/test/mock-d1.ts`. Test helpers in
`src/test/setup.ts` should create merchants, accounts, wallets, and integrations;
do not rely on seeded merchant IDs.
Vitest scripts default to four fork workers because test DBs clone a
pre-migrated SQLite template; set `VITEST_MAX_WORKERS=1` or `2` when debugging
or on constrained machines.
Integration tests are opt-in guarded. During normal development and agent work,
run only `pnpm test`. Do not run `pnpm test:integration` unless the user
explicitly asks, the work is a deploy/prod handoff, the change touches routes/
migrations/DB helpers/auth/RBAC/money/ledger/webhooks/Vitest config/shared test
setup, or unit tests cannot explain a failure. When integration is required, use
`BROPAY_RUN_INTEGRATION=1 pnpm test:integration`.

Use the narrowest test type that covers the edit: `pnpm test` for `src/lib`,
middleware, scheduler, setup, security, enum guards, and other non-route unit
tests; `BROPAY_RUN_INTEGRATION=1 pnpm test:integration` for DB-backed route
tests and `src/test/integration`. Direct Vitest file filters are acceptable for
one touched test file. Run both test types before deploy/prod handoff when
changes cross route/lib/integration boundaries, touch migrations or shared test
setup, alter auth/RBAC/money/ledger/webhook behavior, update dependencies or
Vitest config, or when a narrower slice cannot explain a failure.
