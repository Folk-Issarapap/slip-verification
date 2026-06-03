#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

echo "[codex] Installing workspace dependencies"
pnpm install

if [ ! -f apps/api/.dev.vars ]; then
  echo "[codex] Creating apps/api/.dev.vars for local preview"
  cat > apps/api/.dev.vars <<'VARS'
ENVIRONMENT=local
ALLOWED_ORIGINS=http://localhost:3000,http://localhost:3001,http://localhost:3002,http://localhost:3003
JWT_SECRET=local-preview-jwt-secret-change-me-32-chars
ENCRYPTION_KEY=local-preview-encryption-key-change-me-32-chars
GOOGLE_CLIENT_ID=local-google-client-id
GOOGLE_CLIENT_SECRET=local-google-client-secret
GOOGLE_REDIRECT_URI=http://localhost:8787/v1/auth/google/callback
WEB_URL=http://localhost:3000
MERCHANT_WEB_URL=http://localhost:3001
ASSETS_URL=http://localhost:8787/assets
CF_API_TOKEN=
CF_ACCOUNT_ID=
EMAIL_FROM=noreply@example.com
PLATFORM_FEE_INBOUND_PCT=1.5
PLATFORM_FEE_INBOUND_FLAT=0
PLATFORM_FEE_OUTBOUND_PCT=1.5
PLATFORM_FEE_OUTBOUND_FLAT=0
PLATFORM_MIN_DEPOSIT=5000
PLATFORM_MAX_DEPOSIT=10000000
PLATFORM_MIN_WITHDRAWAL=10000
PLATFORM_MAX_WITHDRAWAL=50000000
PLATFORM_MIN_PAYOUT=1000
PLATFORM_MAX_PAYOUT=50000000
PLATFORM_MIN_PAYMENT=5000
PLATFORM_MAX_PAYMENT=10000000
PLATFORM_MIN_FEE_INBOUND_PCT=0
PLATFORM_MIN_FEE_OUTBOUND_PCT=0
VARS
else
  echo "[codex] apps/api/.dev.vars already exists; leaving it unchanged"
fi

echo "[codex] Applying local D1 migrations"
if ! pnpm migrate:local; then
  cat <<'MSG' >&2
[codex] Local D1 migration failed.
[codex] If this is a disposable Codex worktree with partial local D1 state,
[codex] reset only that worktree's local D1 sqlite files, then rerun setup.
MSG
  exit 1
fi

echo "[codex] Seeding base local data"
pnpm db:seed

if [ "${BROPAY_CODEX_REALISTIC_SEED:-0}" = "1" ]; then
  echo "[codex] Seeding realistic demo data"
  pnpm db:seed:realistic
else
  echo "[codex] Skipping realistic seed; set BROPAY_CODEX_REALISTIC_SEED=1 to enable it"
fi
