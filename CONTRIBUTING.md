# Contributing to Bro Pay

Thanks for jumping in. This is the dev onboarding + day-to-day reference.

## ⚠️ Branch pivot (2026-05-23) — read first if you already had a local clone

`develop` was force-replaced. The previous `develop` (Vite + Base UI rewrite attempt) has been archived as `develop-vite-rewrite`; the new `develop` is the vinext-based codebase that was on `develop-legacy-before-vite`.

If you already have a local clone with `develop` checked out, your local branch is now divergent. To reset:

```bash
# 1. Save anything you don't want to lose
git stash push -m "pre-pivot wip"   # or commit to a personal branch

# 2. Fetch the new shape
git fetch origin --prune

# 3. Hard-reset your local develop
git checkout develop
git reset --hard origin/develop

# 4. Reinstall deps (lockfile changed)
pnpm install

# 5. (Optional) rebuild api types so frontend RPC types resolve
cd apps/api && pnpm build:types && cd -

# 6. (Optional) wipe + reseed local D1 — migrations 0031–0033 added
pnpm migrate:local && pnpm db:seed
```

Your old `develop` work is recoverable: it's now `develop-vite-rewrite` on the remote, plus your local `git reflog` keeps the previous tip for ~30 days.

**Things that changed in this pivot:**
- All 5 apps (api + 4 frontends) now have `pnpm typecheck` scripts — heap-bumped to 8 GB. Run at root via turbo.
- Frontends are vinext (Next.js App Router on Vite + Workers). Apps directory has `reseller` as its own portal (separate from `merchant`), per the reseller-entity refactor.
- API routes for branding/commissions/downline/sub-merchants moved from `/v1/merchant/*` to `/v1/reseller/*`.
- The legacy `merchant_hierarchy` / `can_resell` / `parent_merchant_id` columns are gone — replaced by `merchants.reseller_id` + the `resellers` table (migrations 0032, 0033).
- `origin/main` is still on the old Vite codebase — production has NOT been promoted yet.

## Prerequisites

- Node.js 22+
- pnpm 10+
- macOS or Linux (Windows via WSL)

You do **not** need a Cloudflare account to develop locally. Wrangler runs everything in local mode against a per-developer SQLite DB.

## New to the redesign?

If you're joining the merchant app rebuild, treat the corresponding admin page as the canonical reference for layout, primitives, and the settlement model — copy from the matching admin file when in doubt.

Shared primitives belong in `packages/ui`; check whether something analogous already exists before adding a new component.

## First-time setup

```bash
git clone git@github.com:Necronds/bropay-cf.git
cd bropay-cf
pnpm install

# Copy env template and ask Jay for the shared secrets
cp apps/api/.dev.vars.example apps/api/.dev.vars
# Generate your own JWT_SECRET:
#   openssl rand -hex 32

# Fresh local database
pnpm migrate:local
pnpm db:seed

# Start api + admin
pnpm dev
```

Then log into the admin at <http://localhost:3000> with your seed account (password `password123`):

| Dev | Email |
|---|---|
| Folk | `folk@bropay.com` |
| Boat | `boat@bropay.com` |
| Tor | `tor@bropay.com` |

## Your local data is yours

Everything wrangler stores lives under `apps/*/\.wrangler/state/` — D1, KV, R2, cache. All gitignored, all per-developer. **Experiment freely.** Wipe, re-seed, break things:

```bash
rm -rf apps/api/.wrangler/state/v3/d1
pnpm migrate:local && pnpm db:seed
```

Seed timestamps use `datetime('now', '-N days')`, so dates always stay relative to today.

## Running individual apps

```bash
pnpm dev              # api + admin
pnpm dev:api          # api only (:8787)
pnpm dev:admin        # admin only (:3000)
pnpm dev:merchant     # merchant portal (:3001)
pnpm dev:checkout     # checkout page (:3002)
```

## Quality gates — run before pushing

```bash
pnpm typecheck        # must be clean
pnpm lint             # biome
pnpm test             # vitest (api)
```

For API-only loops, use `pnpm test:api:unit` during development and
`BROPAY_RUN_INTEGRATION=1 pnpm test:api:integration` for intentional DB-backed
route and integration coverage. CI runs both API test types separately with four
Vitest fork workers by default.

Pre-commit hook auto-fixes staged files with biome. If the hook fails, fix the issue — don't use `--no-verify`.

## Branch + PR flow

1. Create a feature branch from `main`:
   ```bash
   git checkout -b feat/<short-description>
   ```
2. Commit in small, logical units. Follow the existing commit message style — emoji prefix + scope + concise message. Look at `git log` for examples.
3. Push and open a PR against `main`.
4. CI runs lint + typecheck + sharded API tests on every PR.
5. Jay reviews. Don't merge your own PRs.
6. Once approved, **Jay merges and ships**.

## Database migrations

- New migrations go in `apps/api/migrations/NNNN_<name>.sql`
- Number sequentially — no gaps, no re-ordering
- Apply locally via `pnpm migrate:local`
- **Flag destructive migrations in your PR description** (`DROP COLUMN`, `DROP TABLE`, `NOT NULL` on existing columns, backfills). These need extra review.
- Never edit a migration that's already merged to `main`. Write a new one.

## Seed data

- Add new fixtures to `apps/api/seed.sql` using `INSERT OR IGNORE` with stable IDs so re-seeds stay idempotent.
- Use `datetime('now', '-N days')` for timestamps — never hardcode.

## Architecture + conventions

- Root [`CLAUDE.md`](./CLAUDE.md) — API/frontend patterns, DB rules, RBAC, forms
- [`apps/admin/CLAUDE.md`](./apps/admin/CLAUDE.md) — vinext gotchas, static assets, proxy matcher
- [`apps/api/CLAUDE.md`](./apps/api/CLAUDE.md) — Hono routes, middleware, Result pattern

Read these before writing code. They answer 90% of "how should I do X" questions.

## Secrets

- **Never commit secrets.** `apps/api/.dev.vars` and `apps/admin/.env.local` are gitignored for a reason.
- Get shared credentials (Google OAuth, KBNK staging) from Jay via a secure channel (1Password etc.).
- Production credentials are held by Jay only.

## Deployment

| Environment | Who | How |
|---|---|---|
| Local | You | `pnpm dev` |
| Preview (PR) | CI | Automatic on PR push |
| Staging | Jay | Push to `staging` branch (or manual approval) |
| Production | **Jay only** | Merge to `main` + manual approval in GitHub Actions |

Devs cannot deploy to production. Don't ask for the CF token — you don't need it.

## Getting help

- Slack / Discord: ping Jay
- Codebase questions: try the code-review-graph MCP (`semantic_search_nodes_tool`, `query_graph_tool`) before scanning files manually
- For AI-assisted work, the `.claude/agents/` folder has preset sub-agents (`dev`, `reviewer`, `tester`, etc.)

Keep PRs small. Ask questions early. Don't merge your own code.
