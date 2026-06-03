#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# Bootstrap helper — resolves an active merchant fixture via the real API.
#
# Usage: source this file, then call bootstrap_demo_merchant
#
# Merchant resolution order (first match wins):
#   1. $BOOTSTRAP_MERCHANT_ID      — explicit merchant id (highest priority)
#   2. $BOOTSTRAP_MERCHANT_SLUG    — explicit slug (default: unset)
#   3. existing 'bangkok-retail-group' — preserves the current preview default
#   4. first ACTIVE merchant in DB — discovery fallback (e.g. acme-logistics)
#   5. create 'bangkok-retail-group'  — only if no active merchants exist
#
# Exports:
#   DEMO_ADMIN_TOKEN   — staff JWT for super@bropay.com
#   DEMO_OWNER_TOKEN   — JWT for the demo owner account
#   DEMO_OWNER_ID      — account id of the demo owner
#   DEMO_MERCHANT_ID   — resolved merchant id
#   DEMO_MERCHANT_SLUG — resolved slug (informational)
#   DEMO_WALLET_ID     — wallet id for that merchant
# ──────────────────────────────────────────────────────────────────────────────

_BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$_BOOTSTRAP_DIR/_lib.sh"

_BOOTSTRAP_BROPAY="${BROPAY_URL:-http://localhost:8787}"
_BOOTSTRAP_CT="Content-Type: application/json"
_BOOTSTRAP_ORIGIN="Origin: http://localhost:3000"

_DEMO_EMAIL="merchant.owner@bropay.com"
_DEMO_PASSWORD="password123"
_DEMO_NAME="Merchant Owner"
_DEMO_SLUG="bangkok-retail-group"


_json() { python3 -c "import sys,json
try:
    $1
except Exception:
    print('')
" 2>/dev/null; }

# Try merchant/login, then reseller/login when the seeded owner sits on a
# can_resell=1 merchant (migration 0029 promotes kind to 'reseller').
# On success prints the JSON body to stdout. Sets _BOOTSTRAP_LOGIN_ERR on failure.
_bootstrap_owner_login() {
  local bropay=$1 ct=$2 origin=$3 endpoint raw http body err
  _BOOTSTRAP_LOGIN_ERR=""
  for endpoint in merchant reseller; do
    raw=$(curl -s -w "\n%{http_code}" "$bropay/v1/auth/$endpoint/login" -H "$ct" -H "$origin" \
      -d "{\"email\":\"$_DEMO_EMAIL\",\"password\":\"$_DEMO_PASSWORD\"}")
    http=$(echo "$raw" | tail -n1)
    body=$(echo "$raw" | sed '$d')
    if [ "$http" = "200" ]; then
      echo "$body"
      return 0
    fi
    err=$(_json "print(json.load(sys.stdin).get('error',{}).get('code',''))" <<< "$body")
    _BOOTSTRAP_LOGIN_ERR="$err"
    # Wrong portal for this account kind — try the other login endpoint.
    [ "$err" = "WRONG_LOGIN_KIND" ] || break
  done
  echo "$body" >&2
  return 1
}

bootstrap_demo_merchant() {
  local BROPAY="$_BOOTSTRAP_BROPAY"
  local CT="$_BOOTSTRAP_CT"
  local ORIGIN="$_BOOTSTRAP_ORIGIN"

  # ── 1. Admin login ──────────────────────────────────────────────────────────
  local ADMIN_RES
  ADMIN_RES=$(curl -s "$BROPAY/v1/auth/staff/login" -H "$CT" -H "$ORIGIN" \
    -d '{"email":"boat@bropay.com","password":"password123"}')
  DEMO_ADMIN_TOKEN=$(_json "print(json.load(sys.stdin)['data']['accessToken'])" <<< "$ADMIN_RES")
  [ -n "$DEMO_ADMIN_TOKEN" ] || { echo "bootstrap: admin login failed" >&2; return 1; }

  # ── 2. Ensure owner account exists; obtain owner ID via admin API ───────────
  # merchant/login (or reseller/login for can_resell memberships) requires an
  # active membership, which may not exist yet (fresh DB) or may be on a
  # different merchant (reused DB).  We resolve the owner account via the admin
  # users endpoint when needed, self-heal membership in step 5c, then re-login.
  local OWNER_RES
  if OWNER_RES=$(_bootstrap_owner_login "$BROPAY" "$CT" "$ORIGIN"); then
    DEMO_OWNER_TOKEN=$(_json "print(json.load(sys.stdin)['data']['accessToken'])" <<< "$OWNER_RES")
    DEMO_OWNER_ID=$(_json "print(json.load(sys.stdin)['data']['user']['id'])" <<< "$OWNER_RES")
  elif [ "$_BOOTSTRAP_LOGIN_ERR" = "NO_MEMBERSHIPS" ] || [ "$_BOOTSTRAP_LOGIN_ERR" = "NOT_RESELLER" ]; then
    # Account doesn't have a usable membership yet (403) or doesn't exist (401).
    # Try to register; if that returns CONFLICT the account already exists.
    local REG_RES
    REG_RES=$(curl -s "$BROPAY/v1/auth/register" -H "$CT" -H "$ORIGIN" \
      -d "{\"email\":\"$_DEMO_EMAIL\",\"password\":\"$_DEMO_PASSWORD\",\"name\":\"$_DEMO_NAME\"}")
    local REG_TOKEN
    REG_TOKEN=$(_json "print(json.load(sys.stdin)['data']['accessToken'])" <<< "$REG_RES")
    if [ -n "$REG_TOKEN" ]; then
      # Fresh registration — extract ID from register response
      DEMO_OWNER_ID=$(_json "print(json.load(sys.stdin)['data']['user']['id'])" <<< "$REG_RES")
    else
      # CONFLICT — account already exists (no membership yet). Look up via admin API.
      local ADMIN_AUTH="Authorization: Bearer $DEMO_ADMIN_TOKEN"
      local LOOKUP_RES
      LOOKUP_RES=$(curl -s "$BROPAY/v1/admin/users?q=$_DEMO_EMAIL&limit=1" \
        -H "$ADMIN_AUTH" -H "$ORIGIN")
      DEMO_OWNER_ID=$(_json "d=json.load(sys.stdin).get('data',[]); print(d[0]['id'] if d else '')" <<< "$LOOKUP_RES")
      [ -n "$DEMO_OWNER_ID" ] || { echo "bootstrap: owner account lookup failed — $LOOKUP_RES" >&2; return 1; }
    fi
    # DEMO_OWNER_TOKEN will be populated after the membership self-heal below.
    DEMO_OWNER_TOKEN=""
  else
    echo "bootstrap: owner login failed ($_BOOTSTRAP_LOGIN_ERR)" >&2
    return 1
  fi

  [ -n "$DEMO_OWNER_ID" ] || { echo "bootstrap: could not resolve owner account id" >&2; return 1; }

  # ── 4. Resolve merchant (env override → preview merchant → first active → create)
  DEMO_MERCHANT_ID=""
  DEMO_MERCHANT_SLUG=""
  local AUTH="Authorization: Bearer $DEMO_ADMIN_TOKEN"

  # 4a. $BOOTSTRAP_MERCHANT_ID — explicit id
  if [ -n "${BOOTSTRAP_MERCHANT_ID:-}" ]; then
    local BY_ID
    BY_ID=$(curl -s "$BROPAY/v1/admin/merchants/$BOOTSTRAP_MERCHANT_ID" -H "$AUTH" -H "$ORIGIN")
    DEMO_MERCHANT_ID=$(_json "print(json.load(sys.stdin).get('data',{}).get('id',''))" <<< "$BY_ID")
    DEMO_MERCHANT_SLUG=$(_json "print(json.load(sys.stdin).get('data',{}).get('slug',''))" <<< "$BY_ID")
    [ -n "$DEMO_MERCHANT_ID" ] || { echo "bootstrap: BOOTSTRAP_MERCHANT_ID=$BOOTSTRAP_MERCHANT_ID not found" >&2; return 1; }
  fi

  # 4b. $BOOTSTRAP_MERCHANT_SLUG — explicit slug, OR fall through to default lookup
  if [ -z "$DEMO_MERCHANT_ID" ]; then
    local SEARCH_SLUG="${BOOTSTRAP_MERCHANT_SLUG:-$_DEMO_SLUG}"
    local BY_SLUG
    BY_SLUG=$(curl -s "$BROPAY/v1/admin/merchants?q=$SEARCH_SLUG&limit=5" -H "$AUTH" -H "$ORIGIN")
    DEMO_MERCHANT_ID=$(_json "print(next((m['id'] for m in json.load(sys.stdin).get('data', []) if m.get('slug') == '$SEARCH_SLUG'), ''))" <<< "$BY_SLUG")
    if [ -n "$DEMO_MERCHANT_ID" ]; then
      DEMO_MERCHANT_SLUG="$SEARCH_SLUG"
    elif [ -n "${BOOTSTRAP_MERCHANT_SLUG:-}" ]; then
      # Caller asked for a specific slug that doesn't exist — fail loudly
      echo "bootstrap: BOOTSTRAP_MERCHANT_SLUG=$BOOTSTRAP_MERCHANT_SLUG not found" >&2
      return 1
    fi
  fi

  # 4c. Discovery — pick the first active merchant in the system
  if [ -z "$DEMO_MERCHANT_ID" ]; then
    local ACTIVE_LIST
    ACTIVE_LIST=$(curl -s "$BROPAY/v1/admin/merchants?status=active&limit=5&sort=created_at&order=asc" -H "$AUTH" -H "$ORIGIN")
    DEMO_MERCHANT_ID=$(_json "d=json.load(sys.stdin).get('data', []); print(d[0]['id'] if d else '')" <<< "$ACTIVE_LIST")
    DEMO_MERCHANT_SLUG=$(_json "d=json.load(sys.stdin).get('data', []); print(d[0].get('slug','') if d else '')" <<< "$ACTIVE_LIST")
  fi

  # 4d. Last resort — create the demo merchant
  if [ -z "$DEMO_MERCHANT_ID" ]; then
    local CREATE_RES
    CREATE_RES=$(curl -s "$BROPAY/v1/admin/merchants" -X POST \
      -H "$AUTH" -H "$ORIGIN" -H "$CT" \
      -d "{\"name\":\"Bangkok Retail Group\",\"slug\":\"$_DEMO_SLUG\",\"merchant_type\":\"limited_company\",\"primary_currency\":\"THB\",\"can_resell\":1,\"owner_account_id\":\"$DEMO_OWNER_ID\"}")
    DEMO_MERCHANT_ID=$(_json "print(json.load(sys.stdin).get('data',{}).get('id',''))" <<< "$CREATE_RES")
    [ -n "$DEMO_MERCHANT_ID" ] || { echo "bootstrap: merchant create failed — $CREATE_RES" >&2; return 1; }
    DEMO_MERCHANT_SLUG="$_DEMO_SLUG"

    curl -s "$BROPAY/v1/admin/merchants/$DEMO_MERCHANT_ID/activate" -X POST \
      -H "$AUTH" -H "$ORIGIN" -H "$CT" -d '{}' > /dev/null
  fi

  [ -n "$DEMO_MERCHANT_ID" ] || { echo "bootstrap: no merchant id resolved" >&2; return 1; }

  # ── 5c. Self-heal membership (API — same D1 the Worker uses) ───────────────
  # When the merchant is reused from a prior run, its active `owner` row may
  # belong to a different account, so `owner@demo.com` has no membership. We
  # cannot add a second active `owner` (unique index on merchant for owner role),
  # so we add the demo account as `admin` via the admin API (idempotent).
  #
  # Avoid `wrangler d1 execute` here: it targets CLI local D1 state and often
  # diverges from the database the dev Worker is reading, which produced
  # NO_MEMBERSHIPS after a "successful" silent INSERT.
  local HEAL_RAW HEAL_HTTP HEAL_ERR
  HEAL_RAW=$(curl -s -w "\n%{http_code}" \
    "$BROPAY/v1/admin/merchants/$DEMO_MERCHANT_ID/members" -X POST \
    -H "$AUTH" -H "$ORIGIN" -H "$CT" \
    -d "{\"account_id\":\"$DEMO_OWNER_ID\",\"role\":\"admin\"}")
  HEAL_HTTP=$(echo "$HEAL_RAW" | tail -n1)
  HEAL_BODY=$(echo "$HEAL_RAW" | sed '$d')
  HEAL_ERR=$(_json "print(json.load(sys.stdin).get('error',{}).get('code',''))" <<< "$HEAL_BODY")
  if [ "$HEAL_HTTP" = "201" ]; then
    :
  elif [ "$HEAL_HTTP" = "400" ] && [ "$HEAL_ERR" = "CONFLICT" ]; then
    :
  else
    echo "bootstrap: admin add merchant member failed (HTTP $HEAL_HTTP) — $HEAL_BODY" >&2
    return 1
  fi

  # ── 5d. Re-login owner after membership self-heal ─────────────────────────
  # If we registered fresh or had no membership at the start, the self-heal above
  # has now inserted the membership — merchant or reseller login should succeed.
  if [ -z "$DEMO_OWNER_TOKEN" ]; then
    local RELOGIN_RES
    if ! RELOGIN_RES=$(_bootstrap_owner_login "$BROPAY" "$CT" "$ORIGIN"); then
      echo "bootstrap: owner login after membership self-heal failed ($_BOOTSTRAP_LOGIN_ERR) — $RELOGIN_RES" >&2
      return 1
    fi
    DEMO_OWNER_TOKEN=$(_json "print(json.load(sys.stdin)['data']['accessToken'])" <<< "$RELOGIN_RES")
    [ -n "$DEMO_OWNER_TOKEN" ] || { echo "bootstrap: owner login after membership self-heal returned no token" >&2; return 1; }
  fi

  # ── 6. Resolve wallet id ────────────────────────────────────────────────────
  local WALLET_RES
  WALLET_RES=$(curl -s "$BROPAY/v1/admin/wallets?merchant_id=$DEMO_MERCHANT_ID&limit=1" \
    -H "Authorization: Bearer $DEMO_ADMIN_TOKEN" -H "$ORIGIN")
  DEMO_WALLET_ID=$(_json "d=json.load(sys.stdin); items=d.get('data',[]); print(items[0]['id'] if items else '')" <<< "$WALLET_RES")
  [ -n "$DEMO_WALLET_ID" ] || { echo "bootstrap: wallet not found for merchant $DEMO_MERCHANT_ID" >&2; return 1; }

  export DEMO_ADMIN_TOKEN DEMO_OWNER_TOKEN DEMO_OWNER_ID DEMO_MERCHANT_ID DEMO_MERCHANT_SLUG DEMO_WALLET_ID
}
