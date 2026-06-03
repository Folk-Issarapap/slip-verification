-- ── 0001_initial.sql ────────────────────────────────────────────────────────
-- Squashed canonical development schema for Bro Pay local D1.
-- This file replaces the iterative 0002..0050 migration chain during the
-- dev phase where no production merchant data requires historical replay.
-- ────────────────────────────────────────────────────────────────────────────

PRAGMA defer_foreign_keys = ON;

CREATE TABLE accounts (
  id          TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  email       TEXT NOT NULL UNIQUE,
  name        TEXT NOT NULL,
  display_name TEXT,
  avatar_url   TEXT,
  password_hash TEXT,
  preferred_language TEXT NOT NULL DEFAULT 'th' CHECK (preferred_language IN ('en', 'th')),
  status      TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'password_reset_required')),
  staff_role   TEXT CHECK (staff_role IN ('super_admin', 'admin', 'developer', 'moderator', 'writer', 'user')),
  last_login_at TEXT,
  email_verified_at TEXT,
  created_at   TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at   TEXT NOT NULL DEFAULT (datetime('now')),
  deleted_at   TEXT,
  phone TEXT,
  bio TEXT
, failed_login_attempts INTEGER NOT NULL DEFAULT 0, locked_until TEXT, must_change_password INTEGER NOT NULL DEFAULT 0, kind TEXT NOT NULL DEFAULT 'merchant'
  CHECK (kind IN ('staff', 'merchant', 'reseller')), theme TEXT NOT NULL DEFAULT 'system'
  CHECK (theme IN ('light', 'dark', 'system')), font_size TEXT NOT NULL DEFAULT 'normal'
  CHECK (font_size IN ('small', 'normal', 'large')), density TEXT NOT NULL DEFAULT 'comfortable'
  CHECK (density IN ('comfortable', 'compact')), onboarded_at TEXT);
CREATE INDEX idx_accounts_status      ON accounts (status);
CREATE INDEX idx_accounts_created_at  ON accounts (created_at);
CREATE TABLE sessions (
  id                 TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  account_id         TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  refresh_token_hash TEXT NOT NULL,
  token_family       TEXT NOT NULL,
  revoked_at         TEXT,
  revoke_reason      TEXT,
  expires_at         TEXT NOT NULL,
  created_at         TEXT NOT NULL DEFAULT (datetime('now')),
  user_agent TEXT,
  ip_address TEXT
, last_seen_at TEXT);
CREATE INDEX idx_sessions_refresh_token_hash ON sessions (refresh_token_hash);
CREATE INDEX idx_sessions_token_family       ON sessions (token_family);
CREATE INDEX idx_sessions_expires_at        ON sessions (expires_at);
CREATE INDEX idx_sessions_account_recent    ON sessions (account_id, created_at DESC);
CREATE TABLE oauth_accounts (
  id              TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  account_id       TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  provider        TEXT NOT NULL CHECK (provider IN ('google')),
  provider_account_id TEXT NOT NULL,
  access_token     TEXT,
  refresh_token    TEXT,
  expires_at       TEXT,
  token_type       TEXT,
  scope           TEXT,
  id_token         TEXT,
  created_at       TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at       TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE (provider, provider_account_id)
);
CREATE INDEX idx_oauth_accounts_account_id ON oauth_accounts (account_id);
CREATE TABLE password_reset_tokens (
  id          TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  account_id   TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  token_hash  TEXT NOT NULL UNIQUE,
  used_at     TEXT,
  expires_at   TEXT NOT NULL,
  created_at   TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_password_reset_tokens_account_id ON password_reset_tokens (account_id);
CREATE INDEX idx_password_reset_tokens_expires_at ON password_reset_tokens (expires_at);
CREATE TABLE auth_codes (
  code        TEXT NOT NULL PRIMARY KEY,
  data        TEXT NOT NULL,
  expires_at  TEXT NOT NULL,
  created_at  TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_auth_codes_expires_at ON auth_codes (expires_at);
CREATE TABLE audit_logs (
  id              TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  actor_type       TEXT NOT NULL DEFAULT 'user' CHECK (actor_type IN ('user', 'system', 'api', 'service')),
  actor_id         TEXT,
  actor_email      TEXT,
  actor_name       TEXT,
  action          TEXT NOT NULL,
  resource_type    TEXT NOT NULL,
  resource_id      TEXT,
  merchant_id      TEXT REFERENCES merchants (id) ON DELETE SET NULL,
  before          TEXT,
  after           TEXT,
  diff            TEXT,
  ip_address       TEXT,
  user_agent       TEXT,
  request_id       TEXT,
  status          TEXT NOT NULL DEFAULT 'success' CHECK (status IN ('success', 'failure')),
  error_message    TEXT,
  description     TEXT,
  metadata        TEXT,
  created_at       TEXT NOT NULL DEFAULT (datetime('now'))
, customer_id TEXT REFERENCES customers(id) ON DELETE SET NULL);
CREATE INDEX idx_audit_logs_actor_id      ON audit_logs (actor_id);
CREATE INDEX idx_audit_logs_action        ON audit_logs (action);
CREATE INDEX idx_audit_logs_created_at    ON audit_logs (created_at);
CREATE INDEX idx_audit_logs_merchant_time ON audit_logs (merchant_id, created_at);
CREATE INDEX idx_audit_logs_entity        ON audit_logs (resource_type, resource_id);
CREATE TABLE merchant_memberships (
  id          TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  account_id   TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  merchant_id  TEXT NOT NULL REFERENCES merchants (id) ON DELETE CASCADE,
  role        TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'manager', 'member')),
  status      TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'removed')),
  invited_by   TEXT REFERENCES accounts (id) ON DELETE SET NULL,
  joined_at    TEXT NOT NULL DEFAULT (datetime('now')),
  removed_at   TEXT,
  removed_by   TEXT REFERENCES accounts (id) ON DELETE SET NULL,
  removal_reason TEXT,
  created_at   TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at   TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE (account_id, merchant_id)
);
CREATE INDEX idx_merchant_memberships_merchant_id ON merchant_memberships (merchant_id);
CREATE INDEX idx_merchant_memberships_status      ON merchant_memberships (status);
CREATE UNIQUE INDEX idx_merchant_memberships_one_active_owner
  ON merchant_memberships (merchant_id)
  WHERE role = 'owner' AND status = 'active';
CREATE TABLE merchant_invitations (
  id          TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  merchant_id  TEXT NOT NULL REFERENCES merchants (id) ON DELETE CASCADE,
  email       TEXT NOT NULL,
  role        TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'manager', 'member')),
  token       TEXT NOT NULL UNIQUE,
  status      TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'cancelled', 'expired')),
  invited_by   TEXT NOT NULL REFERENCES accounts (id) ON DELETE RESTRICT,
  accepted_by  TEXT REFERENCES accounts (id) ON DELETE SET NULL,
  accepted_at  TEXT,
  expires_at   TEXT NOT NULL,
  created_at   TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at   TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_merchant_invitations_merchant_id   ON merchant_invitations (merchant_id);
CREATE INDEX idx_merchant_invitations_email         ON merchant_invitations (email);
CREATE INDEX idx_merchant_invitations_status        ON merchant_invitations (status);
CREATE UNIQUE INDEX uidx_merchant_invitations_pending
  ON merchant_invitations (merchant_id, email)
  WHERE status = 'pending';
CREATE TABLE merchant_risk_flags (
  id          TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  merchant_id  TEXT NOT NULL REFERENCES merchants (id) ON DELETE CASCADE,
  flag_type    TEXT NOT NULL,
  severity    TEXT NOT NULL DEFAULT 'low' CHECK (severity IN ('low', 'medium', 'high', 'critical')),
  status      TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'resolved', 'dismissed')),
  description TEXT,
  resolved_by  TEXT REFERENCES accounts (id) ON DELETE SET NULL,
  resolved_at  TEXT,
  metadata    TEXT,
  created_at   TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at   TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_merchant_risk_flags_merchant_id ON merchant_risk_flags (merchant_id);
CREATE INDEX idx_merchant_risk_flags_status      ON merchant_risk_flags (status);
CREATE INDEX idx_merchant_risk_flags_severity    ON merchant_risk_flags (severity);
CREATE TABLE banks (
  id           TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  name         TEXT NOT NULL,
  name_th       TEXT,
  code         TEXT NOT NULL UNIQUE,
  abbreviation TEXT NOT NULL UNIQUE,
  swift_code    TEXT,
  logo_url      TEXT,
  is_active     INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
  sort_order    INTEGER NOT NULL DEFAULT 0,
  created_at    TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at    TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE merchant_bank_accounts (
  id                  TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  merchant_id          TEXT NOT NULL REFERENCES merchants (id) ON DELETE CASCADE,
  bank_id              TEXT NOT NULL REFERENCES banks (id) ON DELETE RESTRICT,
  account_number       TEXT NOT NULL,
  account_holder_name   TEXT NOT NULL,
  account_type         TEXT NOT NULL DEFAULT 'savings' CHECK (account_type IN ('checking', 'savings', 'current')),
  branch_name          TEXT,
  verification_status  TEXT NOT NULL DEFAULT 'pending' CHECK (verification_status IN ('pending', 'in_progress', 'verified', 'failed', 'cancelled', 'expired')),
  for_settlement       INTEGER NOT NULL DEFAULT 0 CHECK (for_settlement IN (0, 1)),
  for_wallet           INTEGER NOT NULL DEFAULT 0 CHECK (for_wallet IN (0, 1)),
  is_default           INTEGER NOT NULL DEFAULT 0 CHECK (is_default IN (0, 1)),
  status              TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'active', 'inactive')),
  created_by           TEXT REFERENCES accounts (id) ON DELETE SET NULL,
  created_at           TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at           TEXT NOT NULL DEFAULT (datetime('now')),
  account_number_last4 TEXT
, deleted_at TEXT);
CREATE INDEX idx_merchant_bank_accounts_bank_id        ON merchant_bank_accounts (bank_id);
CREATE INDEX idx_merchant_bank_accounts_for_settlement ON merchant_bank_accounts (merchant_id, for_settlement);
CREATE INDEX idx_merchant_bank_accounts_for_wallet     ON merchant_bank_accounts (merchant_id, for_wallet);
CREATE INDEX idx_merchant_bank_accounts_is_default     ON merchant_bank_accounts (merchant_id, is_default);
CREATE TABLE customer_merchants (
  id                  TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  customer_id          TEXT NOT NULL REFERENCES customers (id) ON DELETE CASCADE,
  merchant_id          TEXT NOT NULL REFERENCES merchants (id) ON DELETE CASCADE,
  external_reference_id TEXT,
  status              TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'blocked')),
  created_at           TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at           TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE (customer_id, merchant_id)
);
CREATE INDEX idx_customer_merchants_merchant_id  ON customer_merchants (merchant_id);
CREATE UNIQUE INDEX idx_customer_merchants_ext_ref ON customer_merchants (merchant_id, external_reference_id) WHERE external_reference_id IS NOT NULL;
CREATE TABLE customer_bank_accounts (
  id                  TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  customer_id          TEXT NOT NULL REFERENCES customers (id) ON DELETE CASCADE,
  bank_id              TEXT NOT NULL REFERENCES banks (id) ON DELETE RESTRICT,
  account_number       TEXT NOT NULL,
  account_holder_name   TEXT NOT NULL,
  verification_status  TEXT NOT NULL DEFAULT 'pending' CHECK (verification_status IN ('pending', 'in_progress', 'verified', 'failed', 'cancelled', 'expired')),
  is_default           INTEGER NOT NULL DEFAULT 0 CHECK (is_default IN (0, 1)),
  status              TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'active', 'inactive')),
  created_at           TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at           TEXT NOT NULL DEFAULT (datetime('now')),
  account_number_last4 TEXT
, deleted_at TEXT);
CREATE INDEX idx_customer_bank_accounts_customer_id ON customer_bank_accounts (customer_id);
CREATE INDEX idx_customer_bank_accounts_bank_id     ON customer_bank_accounts (bank_id);
CREATE TABLE merchant_api_keys (
  id              TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  merchant_id      TEXT NOT NULL REFERENCES merchants (id) ON DELETE CASCADE,
  integration_id   TEXT REFERENCES integrations (id) ON DELETE CASCADE,
  name            TEXT NOT NULL,
  key_hash         TEXT NOT NULL,
  key_hint         TEXT NOT NULL,
  is_active        INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
  last_used_at      TEXT,
  expires_at       TEXT,
  created_by       TEXT REFERENCES accounts (id) ON DELETE SET NULL,
  revoked_by       TEXT REFERENCES accounts (id) ON DELETE SET NULL,
  revoked_at       TEXT,
  created_at       TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at       TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_merchant_api_keys_merchant_id    ON merchant_api_keys (merchant_id);
CREATE INDEX idx_merchant_api_keys_integration_id ON merchant_api_keys (integration_id);
CREATE INDEX idx_merchant_api_keys_key_hash       ON merchant_api_keys (key_hash);
CREATE TABLE integration_feature_flags (
  id            TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  integration_id TEXT NOT NULL REFERENCES integrations (id) ON DELETE CASCADE,
  flag_key       TEXT NOT NULL,
  flag_value     TEXT NOT NULL DEFAULT '0',
  description   TEXT,
  updated_by     TEXT REFERENCES accounts (id) ON DELETE SET NULL,
  created_at     TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at     TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE (integration_id, flag_key)
);
CREATE TABLE customer_integrations (
  id                  TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  customer_id          TEXT NOT NULL REFERENCES customers (id) ON DELETE CASCADE,
  integration_id       TEXT NOT NULL REFERENCES integrations (id) ON DELETE CASCADE,
  merchant_id          TEXT NOT NULL REFERENCES merchants (id) ON DELETE CASCADE,
  external_reference_id TEXT,
  metadata            TEXT,
  created_at           TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at           TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE (customer_id, integration_id)
);
CREATE INDEX idx_customer_integrations_integration_id ON customer_integrations (integration_id);
CREATE INDEX idx_customer_integrations_merchant_id    ON customer_integrations (merchant_id);
CREATE TABLE settlement_events (
  id              TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  settlement_id    TEXT NOT NULL REFERENCES settlements (id) ON DELETE CASCADE,
  event_type       TEXT NOT NULL CHECK (event_type IN ('created', 'processing', 'completed', 'failed', 'cancelled', 'fee_distributed')),
  status          TEXT NOT NULL,
  description     TEXT,
  metadata        TEXT,
  performed_by     TEXT REFERENCES accounts (id) ON DELETE SET NULL,
  created_at       TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_settlement_events_settlement_id ON settlement_events (settlement_id);
CREATE INDEX idx_settlement_events_event_type    ON settlement_events (event_type);
CREATE TABLE settlement_slips (
  id TEXT PRIMARY KEY NOT NULL,
  settlement_id TEXT NOT NULL REFERENCES settlements (id) ON DELETE CASCADE,
  r2_key TEXT NOT NULL UNIQUE,
  mime_type TEXT NOT NULL CHECK (mime_type IN ('image/jpeg', 'image/png', 'application/pdf')),
  file_size INTEGER NOT NULL CHECK (file_size > 0 AND file_size <= 5242880),
  original_filename TEXT,
  uploaded_by TEXT NOT NULL REFERENCES accounts (id) ON DELETE RESTRICT,
  uploaded_at TEXT NOT NULL DEFAULT (datetime('now')),
  replaced_at TEXT,
  replaced_by TEXT REFERENCES accounts (id) ON DELETE SET NULL
);
CREATE INDEX idx_settlement_slips_settlement ON settlement_slips (settlement_id, replaced_at);
CREATE INDEX idx_settlement_slips_active     ON settlement_slips (settlement_id) WHERE replaced_at IS NULL;
CREATE TABLE settlement_completion_locks (
  settlement_id TEXT PRIMARY KEY,
  acquired_at   TEXT NOT NULL DEFAULT (datetime('now')),
  FOREIGN KEY (settlement_id) REFERENCES settlements (id) ON DELETE CASCADE
);
CREATE TABLE payout_events (
  id          TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  payout_id    TEXT NOT NULL REFERENCES payouts (id) ON DELETE CASCADE,
  event_type   TEXT NOT NULL CHECK (event_type IN ('created', 'processing', 'completed', 'failed', 'cancelled', 'fee_charged')),
  status      TEXT NOT NULL,
  description TEXT,
  metadata    TEXT,
  performed_by TEXT REFERENCES accounts (id) ON DELETE SET NULL,
  created_at   TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_payout_events_payout_id  ON payout_events (payout_id);
CREATE INDEX idx_payout_events_event_type ON payout_events (event_type);
CREATE TABLE providers (
  id                    TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  name                  TEXT NOT NULL,
  slug                  TEXT NOT NULL UNIQUE,
  description           TEXT,
  provider_type          TEXT NOT NULL DEFAULT 'payment_gateway' CHECK (provider_type IN ('payment_gateway', 'bank_transfer', 'ewallet', 'other')),
  status                TEXT NOT NULL DEFAULT 'inactive' CHECK (status IN ('active', 'inactive', 'maintenance', 'deprecated')),
  api_endpoint           TEXT,
  webhook_endpoint       TEXT,
  auth_method            TEXT NOT NULL DEFAULT 'oauth2' CHECK (auth_method IN ('oauth2', 'api_key', 'hmac', 'basic_auth')),
  token_endpoint         TEXT,
  health_status          TEXT NOT NULL DEFAULT 'unknown' CHECK (health_status IN ('healthy', 'degraded', 'down', 'unknown')),
  health_check_endpoint   TEXT,
  health_check_interval   INTEGER NOT NULL DEFAULT 60,
  health_check_timeout    INTEGER NOT NULL DEFAULT 10,
  last_health_check_at     TEXT,
  metadata              TEXT,
  is_default             INTEGER NOT NULL DEFAULT 0 CHECK (is_default IN (0, 1)),
  created_at             TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at             TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE UNIQUE INDEX uidx_providers_single_default
  ON providers (is_default)
  WHERE is_default = 1;
CREATE TABLE provider_credentials (
  id              TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  provider_id     TEXT NOT NULL REFERENCES providers (id) ON DELETE CASCADE,
  credential_name TEXT NOT NULL,
  encrypted_value TEXT NOT NULL,
  metadata        TEXT,
  created_at      TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at      TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE (provider_id, credential_name)
);
CREATE TABLE provider_capabilities (
  id                          TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  provider_id                  TEXT NOT NULL UNIQUE REFERENCES providers (id) ON DELETE CASCADE,
  supports_payment             INTEGER NOT NULL DEFAULT 0 CHECK (supports_payment IN (0, 1)),
  supports_settlement          INTEGER NOT NULL DEFAULT 0 CHECK (supports_settlement IN (0, 1)),
  supports_wallet              INTEGER NOT NULL DEFAULT 0 CHECK (supports_wallet IN (0, 1)),
  supports_bank_account_verification INTEGER NOT NULL DEFAULT 0 CHECK (supports_bank_account_verification IN (0, 1)),
  supports_refund              INTEGER NOT NULL DEFAULT 0 CHECK (supports_refund IN (0, 1)),
  supports_webhook             INTEGER NOT NULL DEFAULT 0 CHECK (supports_webhook IN (0, 1)),
  created_at                   TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at                   TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE provider_bank_account_verification_config (
  id                      TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  provider_id              TEXT NOT NULL UNIQUE REFERENCES providers (id) ON DELETE CASCADE,
  supported_methods        TEXT NOT NULL DEFAULT '["name_match"]',
  supports_name_matching    INTEGER NOT NULL DEFAULT 1 CHECK (supports_name_matching IN (0, 1)),
  min_similarity_score      REAL NOT NULL DEFAULT 80 CHECK (min_similarity_score >= 0 AND min_similarity_score <= 100),
  timeout_seconds          INTEGER NOT NULL DEFAULT 300,
  created_at               TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at               TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE provider_health_events (
  id              TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  provider_id      TEXT NOT NULL REFERENCES providers (id) ON DELETE CASCADE,
  previous_status  TEXT NOT NULL CHECK (previous_status IN ('healthy', 'degraded', 'down', 'unknown')),
  current_status   TEXT NOT NULL CHECK (current_status IN ('healthy', 'degraded', 'down', 'unknown')),
  response_time_ms  INTEGER,
  http_status      INTEGER,
  error_message    TEXT,
  metadata        TEXT,
  created_at       TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_provider_health_events_provider_id ON provider_health_events (provider_id);
CREATE TABLE provider_routing_policies (
  id              TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  name            TEXT NOT NULL,
  policy_type      TEXT NOT NULL CHECK (policy_type IN ('round_robin', 'weighted', 'priority', 'failover', 'load_balanced')),
  is_active        INTEGER NOT NULL DEFAULT 0 CHECK (is_active IN (0, 1)),
  stream_type      TEXT NOT NULL DEFAULT 'inbound' CHECK (stream_type IN ('inbound', 'outbound')),
  payment_method   TEXT CHECK (payment_method IN ('promptpay', 'bank_transfer', 'all')),
  config          TEXT NOT NULL DEFAULT '{}',
  description     TEXT,
  created_by       TEXT REFERENCES accounts (id) ON DELETE SET NULL,
  created_at       TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at       TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE bank_account_verifications (
  id TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  merchant_bank_account_id TEXT REFERENCES merchant_bank_accounts (id) ON DELETE CASCADE,
  customer_bank_account_id TEXT REFERENCES customer_bank_accounts (id) ON DELETE CASCADE,
  provider_id TEXT REFERENCES providers (id) ON DELETE RESTRICT,
  provider_verification_id TEXT,
  provider_reference_id TEXT,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'in_progress', 'verified', 'failed', 'cancelled', 'expired')),
  similarity_score REAL CHECK (similarity_score IS NULL OR (similarity_score >= 0 AND similarity_score <= 100)),
  threshold REAL NOT NULL DEFAULT 80,
  provider_response TEXT,
  manually_overridden INTEGER NOT NULL DEFAULT 0 CHECK (manually_overridden IN (0, 1)),
  override_reason TEXT,
  overridden_by TEXT REFERENCES accounts (id) ON DELETE SET NULL,
  overridden_at TEXT,
  attempt_number INTEGER NOT NULL DEFAULT 1,
  completed_at TEXT,
  expires_at TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  CHECK (
    (merchant_bank_account_id IS NOT NULL AND customer_bank_account_id IS NULL)
    OR (merchant_bank_account_id IS NULL AND customer_bank_account_id IS NOT NULL)
  )
);
CREATE INDEX idx_bank_account_verifications_merchant_ba            ON bank_account_verifications (merchant_bank_account_id);
CREATE INDEX idx_bank_account_verifications_customer_ba            ON bank_account_verifications (customer_bank_account_id);
CREATE INDEX idx_bank_account_verifications_status                 ON bank_account_verifications (status);
CREATE INDEX idx_bank_account_verifications_provider_id            ON bank_account_verifications (provider_id);
CREATE INDEX idx_bank_account_verifications_provider_verification_id ON bank_account_verifications (provider_verification_id);
CREATE TABLE idempotency_keys (
  id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  actor_id TEXT NOT NULL,
  key TEXT NOT NULL,
  resource_path TEXT NOT NULL,
  response_body TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  status_code INTEGER NOT NULL DEFAULT 200
, request_hash TEXT);
CREATE UNIQUE INDEX idx_idempotency_keys_actor_key ON idempotency_keys (actor_id, key);
CREATE INDEX idx_idempotency_keys_created_at ON idempotency_keys (created_at);
CREATE TABLE kbnk_webhook_seen (
  idempotency_key TEXT NOT NULL PRIMARY KEY,
  received_at     TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_kbnk_webhook_seen_received_at ON kbnk_webhook_seen (received_at);
CREATE INDEX idx_audit_logs_customer_id ON audit_logs(customer_id);
CREATE INDEX idx_customer_bank_accounts_deleted_at ON customer_bank_accounts (deleted_at);
CREATE INDEX idx_merchant_bank_accounts_deleted_at ON merchant_bank_accounts (deleted_at);
CREATE TABLE wallet_deposits (
  id                   TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
  reference_number     TEXT NOT NULL UNIQUE,
  merchant_id          TEXT NOT NULL REFERENCES merchants (id) ON DELETE RESTRICT,
  wallet_id            TEXT NOT NULL REFERENCES wallets (id) ON DELETE RESTRICT,
  integration_id       TEXT REFERENCES integrations (id) ON DELETE RESTRICT,
  amount               INTEGER NOT NULL,
  currency             TEXT NOT NULL DEFAULT 'THB',
  payment_method       TEXT NOT NULL DEFAULT 'promptpay',
  status               TEXT NOT NULL DEFAULT 'processing'
    CHECK (status IN ('processing', 'succeeded', 'failed', 'expired', 'cancelled')),
  expiry_minutes       INTEGER NOT NULL DEFAULT 15,
  expires_at           TEXT NOT NULL,
  next_action          TEXT,
  provider_payment_id  TEXT,
  provider_response    TEXT,
  notes                TEXT,
  idempotency_key      TEXT,
  created_at           TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at           TEXT NOT NULL DEFAULT (datetime('now')),
  succeeded_at         TEXT,
  cancelled_at         TEXT,
  failed_at            TEXT,
  cancellation_reason  TEXT, created_by TEXT REFERENCES accounts(id) ON DELETE SET NULL,
  UNIQUE (integration_id, idempotency_key)
);
CREATE INDEX idx_wallet_deposits_wallet          ON wallet_deposits (wallet_id);
CREATE INDEX idx_wallet_deposits_merchant        ON wallet_deposits (merchant_id);
CREATE INDEX idx_wallet_deposits_status          ON wallet_deposits (status);
CREATE INDEX idx_wallet_deposits_created_at      ON wallet_deposits (created_at);
CREATE INDEX idx_wallet_deposits_provider_payment ON wallet_deposits (provider_payment_id);
CREATE INDEX idx_wallet_deposits_created_by ON wallet_deposits(created_by);
CREATE TABLE wallet_withdrawals (
  id                   TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
  reference_number     TEXT NOT NULL UNIQUE,
  merchant_id          TEXT NOT NULL REFERENCES merchants (id) ON DELETE RESTRICT,
  wallet_id            TEXT NOT NULL REFERENCES wallets (id) ON DELETE RESTRICT,
  bank_account_id      TEXT NOT NULL REFERENCES merchant_bank_accounts (id) ON DELETE RESTRICT,
  amount               INTEGER NOT NULL,
  currency             TEXT NOT NULL DEFAULT 'THB',
  status               TEXT NOT NULL DEFAULT 'pending'
                            CHECK (status IN ('pending', 'completed', 'failed', 'cancelled')),
  bank_reference       TEXT,
  notes                TEXT,
  cancellation_reason  TEXT,
  failure_reason       TEXT,
  idempotency_key      TEXT,
  created_by           TEXT REFERENCES accounts (id) ON DELETE SET NULL,
  completed_by         TEXT REFERENCES accounts (id) ON DELETE SET NULL,
  cancelled_by         TEXT REFERENCES accounts (id) ON DELETE SET NULL,
  created_at           TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at           TEXT NOT NULL DEFAULT (datetime('now')),
  completed_at         TEXT,
  cancelled_at         TEXT,
  failed_at            TEXT,
  UNIQUE (bank_account_id, idempotency_key)
);
CREATE INDEX idx_wallet_withdrawals_wallet     ON wallet_withdrawals (wallet_id);
CREATE INDEX idx_wallet_withdrawals_merchant   ON wallet_withdrawals (merchant_id);
CREATE INDEX idx_wallet_withdrawals_status     ON wallet_withdrawals (status);
CREATE INDEX idx_wallet_withdrawals_created_at ON wallet_withdrawals (created_at);
CREATE TABLE wallet_withdrawal_slips (
  id                  TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
  withdrawal_id       TEXT NOT NULL REFERENCES wallet_withdrawals (id) ON DELETE CASCADE,
  r2_key              TEXT NOT NULL,
  mime_type           TEXT NOT NULL,
  file_size           INTEGER NOT NULL,
  original_filename   TEXT,
  uploaded_by         TEXT REFERENCES accounts (id) ON DELETE SET NULL,
  uploaded_at         TEXT NOT NULL DEFAULT (datetime('now')),
  replaced_at         TEXT,
  replaced_by         TEXT REFERENCES accounts (id) ON DELETE SET NULL
);
CREATE INDEX idx_wallet_withdrawal_slips_active ON wallet_withdrawal_slips (withdrawal_id) WHERE replaced_at IS NULL;
CREATE TABLE email_outbox (
  id             TEXT    NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
  to_address     TEXT    NOT NULL,
  subject        TEXT    NOT NULL,
  body           TEXT    NOT NULL,
  html_body      TEXT,
  status         TEXT    NOT NULL DEFAULT 'pending'
                   CHECK (status IN ('pending', 'sent', 'failed', 'dead')),
  attempt_count  INTEGER NOT NULL DEFAULT 0,
  max_attempts   INTEGER NOT NULL DEFAULT 5,
  next_retry_at  TEXT,
  last_error     TEXT,
  last_attempt_at TEXT,
  sent_at        TEXT,
  metadata       TEXT,
  created_at     TEXT    NOT NULL DEFAULT (datetime('now')),
  updated_at     TEXT    NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_email_outbox_status ON email_outbox (status);
CREATE INDEX idx_email_outbox_next_retry ON email_outbox (next_retry_at)
  WHERE status IN ('pending', 'failed');
CREATE INDEX idx_email_outbox_created_at ON email_outbox (created_at);
CREATE TRIGGER merchant_memberships_no_staff_check_insert
BEFORE INSERT ON merchant_memberships
FOR EACH ROW
WHEN (SELECT kind FROM accounts WHERE id = NEW.account_id) = 'staff'
BEGIN
  SELECT RAISE(ABORT, 'merchant_memberships cannot reference a staff account (kind=staff)');
END;
CREATE TRIGGER merchant_memberships_no_staff_check_update
BEFORE UPDATE ON merchant_memberships
FOR EACH ROW
WHEN (SELECT kind FROM accounts WHERE id = NEW.account_id) = 'staff'
BEGIN
  SELECT RAISE(ABORT, 'merchant_memberships cannot reference a staff account (kind=staff)');
END;
CREATE TABLE payment_access_tokens (
  id              TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  payment_intent_id TEXT NOT NULL REFERENCES payment_intents (id) ON DELETE CASCADE,
  token           TEXT NOT NULL UNIQUE,
  used            INTEGER NOT NULL DEFAULT 0 CHECK (used IN (0, 1)),
  expires_at       TEXT NOT NULL,
  created_at       TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_payment_access_tokens_payment_intent_id ON payment_access_tokens (payment_intent_id);
CREATE INDEX idx_payment_access_tokens_expires_at        ON payment_access_tokens (expires_at);
CREATE TABLE resellers (
  id                    TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  name                  TEXT NOT NULL,
  slug                  TEXT NOT NULL UNIQUE,
  status                TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'closed')),
  branding              TEXT,
  commission_percentage REAL NOT NULL DEFAULT 0 CHECK (commission_percentage >= 0 AND commission_percentage <= 100),
  created_by            TEXT REFERENCES accounts (id) ON DELETE SET NULL,
  created_at            TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at            TEXT NOT NULL DEFAULT (datetime('now')),
  deleted_at            TEXT
);
CREATE INDEX idx_resellers_status     ON resellers (status);
CREATE INDEX idx_resellers_deleted_at ON resellers (deleted_at);
CREATE TABLE reseller_memberships (
  id            TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  account_id    TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  reseller_id   TEXT NOT NULL REFERENCES resellers (id) ON DELETE CASCADE,
  role          TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'member')),
  status        TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'removed')),
  invited_by    TEXT REFERENCES accounts (id) ON DELETE SET NULL,
  joined_at     TEXT NOT NULL DEFAULT (datetime('now')),
  removed_at    TEXT,
  removed_by    TEXT REFERENCES accounts (id) ON DELETE SET NULL,
  removal_reason TEXT,
  created_at    TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at    TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE (account_id, reseller_id)
);
CREATE INDEX idx_reseller_memberships_reseller_id ON reseller_memberships (reseller_id);
CREATE INDEX idx_reseller_memberships_status      ON reseller_memberships (status);
CREATE UNIQUE INDEX idx_reseller_memberships_one_active_owner
  ON reseller_memberships (reseller_id)
  WHERE role = 'owner' AND status = 'active';
CREATE TABLE email_verification_tokens (
  id          TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  account_id  TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  token_hash  TEXT NOT NULL UNIQUE,
  used_at     TEXT,
  expires_at  TEXT NOT NULL,
  created_at  TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_email_verification_tokens_account_id  ON email_verification_tokens (account_id);
CREATE INDEX idx_email_verification_tokens_expires_at  ON email_verification_tokens (expires_at);
CREATE INDEX idx_sessions_account_last_seen ON sessions (account_id, last_seen_at DESC);
CREATE TABLE ledger_entries (
  id                TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  transaction_id    TEXT NOT NULL,
  account_id        TEXT NOT NULL REFERENCES ledger_accounts(id) ON DELETE RESTRICT,
  direction         TEXT NOT NULL CHECK (direction IN ('debit','credit')),
  amount            INTEGER NOT NULL CHECK (amount > 0),
  currency          TEXT NOT NULL DEFAULT 'THB',
  source_type       TEXT NOT NULL CHECK (source_type IN (
    'payment_intent','wallet_deposit','payout','wallet_withdrawal',
    'settlement','fee','commission','adjustment','refund','chargeback',
    'manual','reserve_release'
  )),
  source_id         TEXT NOT NULL,
  description       TEXT,
  created_at        TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_ledger_entries_transaction_id ON ledger_entries(transaction_id);
CREATE INDEX idx_ledger_entries_account_id     ON ledger_entries(account_id, created_at);
CREATE INDEX idx_ledger_entries_source         ON ledger_entries(source_type, source_id);
CREATE TABLE settlements (
  id                    TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  merchant_id            TEXT NOT NULL REFERENCES merchants (id) ON DELETE RESTRICT,
  integration_id         TEXT REFERENCES integrations (id) ON DELETE SET NULL,
  bank_account_id         TEXT NOT NULL REFERENCES merchant_bank_accounts (id) ON DELETE RESTRICT,
  wallet_id              TEXT NOT NULL REFERENCES wallets (id) ON DELETE RESTRICT,
  settlement_date        TEXT NOT NULL,
  period_start           TEXT,
  period_end             TEXT,
  transaction_count      INTEGER NOT NULL DEFAULT 0,
  gross_amount           INTEGER NOT NULL CHECK (gross_amount >= 0),
  fee_amount             INTEGER NOT NULL DEFAULT 0 CHECK (fee_amount >= 0),
  net_amount             INTEGER NOT NULL CHECK (net_amount >= 0),
  currency              TEXT NOT NULL DEFAULT 'THB',
  status                TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'completed', 'failed', 'cancelled')),
  calculation_method     TEXT NOT NULL DEFAULT 'transaction_based' CHECK (calculation_method IN ('transaction_based', 'settlement_based')),
  fee_config_id           TEXT REFERENCES fee_configurations (id) ON DELETE SET NULL,
  reference_number       TEXT NOT NULL UNIQUE DEFAULT ('STL-' || substr(strftime('%Y%m%d', 'now', '+7 hours'), 3) || '-' || upper(substr(hex(randomblob(4)), 1, 6))),
  settlement_type        TEXT NOT NULL DEFAULT 'auto' CHECK (settlement_type IN ('auto', 'manual')),
  processing_started_at   TEXT,
  completed_at           TEXT,
  failed_at              TEXT,
  cancelled_at           TEXT,
  cancelled_by           TEXT REFERENCES accounts (id) ON DELETE SET NULL,
  cancellation_reason    TEXT,
  created_by             TEXT REFERENCES accounts (id) ON DELETE SET NULL,
  created_at             TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at             TEXT NOT NULL DEFAULT (datetime('now')),
  failure_reason         TEXT
);
CREATE UNIQUE INDEX idx_settlement_pending_per_integration
  ON settlements (merchant_id, integration_id)
  WHERE status = 'pending' AND integration_id IS NOT NULL;
CREATE INDEX idx_settlements_bank_account_id ON settlements (bank_account_id);
CREATE INDEX idx_settlements_integration_id  ON settlements (integration_id);
CREATE INDEX idx_settlements_merchant_status ON settlements (merchant_id, status, created_at);
CREATE INDEX idx_settlements_settlement_date ON settlements (settlement_date);
CREATE INDEX idx_settlements_status          ON settlements (status);
CREATE INDEX idx_settlements_wallet_id       ON settlements (wallet_id);
CREATE TABLE payouts (
  id                      TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  reference_number         TEXT NOT NULL UNIQUE DEFAULT ('PYT-' || substr(strftime('%Y%m%d', 'now', '+7 hours'), 3) || '-' || upper(substr(hex(randomblob(4)), 1, 6))),
  merchant_id              TEXT NOT NULL REFERENCES merchants (id) ON DELETE RESTRICT,
  integration_id           TEXT REFERENCES integrations (id) ON DELETE SET NULL,
  wallet_id                TEXT NOT NULL REFERENCES wallets (id) ON DELETE RESTRICT,
  merchant_bank_account_id   TEXT REFERENCES merchant_bank_accounts (id) ON DELETE RESTRICT,
  customer_bank_account_id   TEXT REFERENCES customer_bank_accounts (id) ON DELETE RESTRICT,
  customer_id              TEXT REFERENCES customers (id) ON DELETE SET NULL,
  amount                  INTEGER NOT NULL CHECK (amount > 0),
  currency                TEXT NOT NULL DEFAULT 'THB',
  fee_amount               INTEGER NOT NULL DEFAULT 0 CHECK (fee_amount >= 0),
  net_amount               INTEGER NOT NULL CHECK (net_amount >= 0),
  fee_config_id             TEXT REFERENCES fee_configurations (id) ON DELETE SET NULL,
  status                  TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'completed', 'failed', 'cancelled')),
  source                  TEXT NOT NULL DEFAULT 'dashboard' CHECK (source IN ('dashboard', 'api')),
  idempotency_key          TEXT,
  provider_id              TEXT REFERENCES providers (id) ON DELETE RESTRICT,
  provider_transfer_id      TEXT,
  provider_response        TEXT,
  reserved_at              TEXT,
  reservation_released_at   TEXT,
  description             TEXT,
  metadata                TEXT,
  cancellation_reason      TEXT,
  cancelled_at             TEXT,
  cancelled_by             TEXT REFERENCES accounts (id) ON DELETE SET NULL,
  processing_started_at     TEXT,
  completed_at             TEXT,
  failed_at                TEXT,
  created_by               TEXT REFERENCES accounts (id) ON DELETE SET NULL,
  created_at               TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at               TEXT NOT NULL DEFAULT (datetime('now')), provider_reconciliation_status TEXT NOT NULL DEFAULT 'none'
  CHECK (provider_reconciliation_status IN ('none', 'unknown_provider_state', 'reconcile_required')), provider_reconciliation_reason TEXT, provider_reconciliation_at TEXT,
  CHECK (
    (merchant_bank_account_id IS NOT NULL AND customer_bank_account_id IS NULL)
    OR (merchant_bank_account_id IS NULL AND customer_bank_account_id IS NOT NULL)
  )
);
CREATE INDEX idx_payouts_customer_bank_account ON payouts (customer_bank_account_id);
CREATE INDEX idx_payouts_customer_id           ON payouts (customer_id);
CREATE UNIQUE INDEX idx_payouts_idempotency_key
  ON payouts (merchant_id, idempotency_key)
  WHERE idempotency_key IS NOT NULL;
CREATE INDEX idx_payouts_integration_id        ON payouts (integration_id);
CREATE INDEX idx_payouts_merchant_bank_account ON payouts (merchant_bank_account_id);
CREATE INDEX idx_payouts_merchant_status       ON payouts (merchant_id, status, created_at);
CREATE INDEX idx_payouts_status                ON payouts (status);
CREATE INDEX idx_payouts_wallet_id             ON payouts (wallet_id);
CREATE TABLE payment_intents (
  id                        TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  reference_number          TEXT NOT NULL UNIQUE DEFAULT ('PIN-' || substr(strftime('%Y%m%d', 'now', '+7 hours'), 3) || '-' || upper(substr(hex(randomblob(4)), 1, 6))),
  merchant_id               TEXT NOT NULL REFERENCES merchants (id) ON DELETE RESTRICT,
  integration_id            TEXT REFERENCES integrations (id) ON DELETE RESTRICT,
  customer_id               TEXT REFERENCES customers (id) ON DELETE SET NULL,
  customer_bank_account_id  TEXT REFERENCES customer_bank_accounts (id) ON DELETE SET NULL,
  amount                    INTEGER NOT NULL CHECK (amount >= 1),
  currency                  TEXT NOT NULL DEFAULT 'THB',
  status                    TEXT NOT NULL DEFAULT 'requires_payment_method'
    CHECK (status IN (
      'requires_payment_method',
      'requires_confirmation',
      'requires_action',
      'processing',
      'succeeded',
      'failed',
      'cancelled',
      'expired'
    )),
  payment_method            TEXT CHECK (payment_method IN ('promptpay', 'bank_transfer')),
  expiry_minutes            INTEGER NOT NULL DEFAULT 15,
  expires_at                TEXT,
  provider_id               TEXT REFERENCES providers (id) ON DELETE RESTRICT,
  provider_deposit_id       TEXT,
  next_action               TEXT,
  provider_fee_amount       INTEGER,
  provider_response         TEXT,
  client_secret             TEXT NOT NULL UNIQUE,
  idempotency_key           TEXT,
  ref1                      TEXT CHECK (ref1 IS NULL OR length(ref1) <= 20),
  ref2                      TEXT CHECK (ref2 IS NULL OR length(ref2) <= 20),
  ref3                      TEXT CHECK (ref3 IS NULL OR length(ref3) <= 20),
  invoice_number            TEXT,
  order_id                  TEXT,
  statement_descriptor      TEXT CHECK (statement_descriptor IS NULL OR length(statement_descriptor) <= 22),
  merchant_note             TEXT,
  customer_note             TEXT,
  return_url                TEXT,
  cancel_url                TEXT,
  description               TEXT,
  metadata                  TEXT,
  daily_limit_snapshot      INTEGER,
  monthly_limit_snapshot    INTEGER,
  cancellation_reason       TEXT,
  cancelled_at              TEXT,
  cancelled_by              TEXT REFERENCES accounts (id) ON DELETE SET NULL,
  processing_started_at     TEXT,
  succeeded_at              TEXT,
  failed_at                 TEXT,
  created_at                TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at                TEXT NOT NULL DEFAULT (datetime('now')),
  wallet_id                 TEXT REFERENCES wallets (id) ON DELETE SET NULL
);
CREATE INDEX idx_payment_intents_customer_id      ON payment_intents (customer_id);
CREATE INDEX idx_payment_intents_expiry           ON payment_intents (expires_at) WHERE status IN ('requires_payment_method', 'requires_action', 'processing');
CREATE INDEX idx_payment_intents_integration_id   ON payment_intents (integration_id);
CREATE INDEX idx_payment_intents_invoice          ON payment_intents (merchant_id, invoice_number);
CREATE INDEX idx_payment_intents_merchant_status  ON payment_intents (merchant_id, status, created_at);
CREATE INDEX idx_payment_intents_order            ON payment_intents (merchant_id, order_id);
CREATE INDEX idx_payment_intents_ref1             ON payment_intents (merchant_id, ref1);
CREATE INDEX idx_payment_intents_status           ON payment_intents (status);
CREATE INDEX idx_payment_intents_wallet_id        ON payment_intents (wallet_id);
CREATE TABLE fee_configurations (
  id                  TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  merchant_id          TEXT REFERENCES merchants (id) ON DELETE CASCADE,
  integration_id       TEXT REFERENCES integrations (id) ON DELETE CASCADE,
  stream_type          TEXT NOT NULL DEFAULT 'inbound' CHECK (stream_type IN ('inbound', 'outbound')),
  fee_percentage       REAL NOT NULL DEFAULT 0 CHECK (fee_percentage >= 0 AND fee_percentage <= 100),
  flat_fee_amount      INTEGER NOT NULL DEFAULT 0 CHECK (flat_fee_amount >= 0),
  min_fee              INTEGER CHECK (min_fee IS NULL OR min_fee >= 0),
  max_fee              INTEGER CHECK (max_fee IS NULL OR max_fee >= 0),
  calculation_method   TEXT NOT NULL DEFAULT 'transaction_based' CHECK (calculation_method IN ('transaction_based', 'settlement_based')),
  effective_from       TEXT NOT NULL DEFAULT (datetime('now')),
  effective_to         TEXT,
  is_active            INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
  created_by           TEXT REFERENCES accounts (id) ON DELETE SET NULL,
  created_at           TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at           TEXT NOT NULL DEFAULT (datetime('now')),
  wallet_id            TEXT REFERENCES wallets(id) ON DELETE CASCADE,
  version              INTEGER NOT NULL DEFAULT 1
);
CREATE UNIQUE INDEX idx_fee_config_one_active_per_stream
  ON fee_configurations (
    COALESCE(merchant_id, ''),
    COALESCE(integration_id, ''),
    COALESCE(wallet_id, ''),
    stream_type
  )
  WHERE is_active = 1;
CREATE INDEX idx_fee_configs_wallet
  ON fee_configurations(wallet_id)
  WHERE wallet_id IS NOT NULL;
CREATE INDEX idx_fee_configurations_integration_id ON fee_configurations (integration_id);
CREATE INDEX idx_fee_configurations_resolver
  ON fee_configurations (merchant_id, integration_id, stream_type, is_active);
CREATE TABLE merchants (
  id                          TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  name                        TEXT NOT NULL UNIQUE,
  slug                        TEXT NOT NULL UNIQUE,
  tax_id                       TEXT,
  merchant_type                TEXT NOT NULL DEFAULT 'other' CHECK (merchant_type IN ('sole_proprietorship', 'partnership', 'limited_company', 'public_company', 'other')),
  status                      TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'active', 'suspended', 'blocked', 'closed')),
  risk_level                   TEXT NOT NULL DEFAULT 'low' CHECK (risk_level IN ('low', 'medium', 'high')),
  risk_score                   REAL NOT NULL DEFAULT 0 CHECK (risk_score >= 0 AND risk_score <= 100),
  industry_code                TEXT,
  merchant_description         TEXT,
  primary_currency             TEXT NOT NULL DEFAULT 'THB',
  established_date             TEXT,
  settlement_frequency         TEXT NOT NULL DEFAULT 'daily' CHECK (settlement_frequency IN ('daily', 'weekly', 'monthly', 'manual')),
  settlement_method            TEXT NOT NULL DEFAULT 'transaction_based' CHECK (settlement_method IN ('transaction_based', 'settlement_based')),
  auto_settlement_enabled       INTEGER NOT NULL DEFAULT 0 CHECK (auto_settlement_enabled IN (0, 1)),
  daily_transaction_limit       INTEGER NOT NULL DEFAULT 50000000,
  monthly_transaction_limit     INTEGER NOT NULL DEFAULT 200000000,
  daily_transaction_count_limit  INTEGER NOT NULL DEFAULT 10000,
  monthly_transaction_count_limit INTEGER NOT NULL DEFAULT 300000,
  address                     TEXT,
  contact                     TEXT,
  metadata                    TEXT,
  logo_url                     TEXT,
  branding                    TEXT,
  allow_auto_customer_creation   INTEGER NOT NULL DEFAULT 0 CHECK (allow_auto_customer_creation IN (0, 1)),
  created_by                   TEXT REFERENCES accounts (id) ON DELETE SET NULL,
  approved_by                  TEXT REFERENCES accounts (id) ON DELETE SET NULL,
  approved_at                  TEXT,
  last_risk_review_at            TEXT,
  created_at                   TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at                   TEXT NOT NULL DEFAULT (datetime('now')),
  deleted_at                   TEXT,
  min_deposit_amount    INTEGER,
  max_deposit_amount    INTEGER,
  min_withdrawal_amount INTEGER,
  max_withdrawal_amount INTEGER,
  min_payout_amount     INTEGER,
  max_payout_amount     INTEGER,
  min_payment_amount    INTEGER,
  max_payment_amount    INTEGER,
  last_auto_settlement_at TEXT,
  default_daily_deposit_limit     INTEGER,
  default_monthly_deposit_limit    INTEGER,
  default_daily_withdrawal_limit   INTEGER,
  default_monthly_withdrawal_limit INTEGER,
  reseller_id TEXT REFERENCES resellers (id) ON DELETE RESTRICT
, deposit_destination TEXT NOT NULL DEFAULT 'bank' CHECK (deposit_destination IN ('bank', 'wallet')), inbound_enabled INTEGER NOT NULL DEFAULT 1 CHECK (inbound_enabled IN (0, 1)), outbound_enabled INTEGER NOT NULL DEFAULT 0 CHECK (outbound_enabled IN (0, 1)), daily_payment_limit INTEGER, monthly_payment_limit INTEGER, daily_payout_limit INTEGER, monthly_payout_limit INTEGER);
CREATE INDEX idx_merchants_active        ON merchants (status) WHERE deleted_at IS NULL;
CREATE INDEX idx_merchants_deleted_at    ON merchants (deleted_at);
CREATE INDEX idx_merchants_reseller_id   ON merchants (reseller_id);
CREATE INDEX idx_merchants_risk_level    ON merchants (risk_level);
CREATE INDEX idx_merchants_status        ON merchants (status);
CREATE TABLE customers (
  id                    TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  reference_number       TEXT NOT NULL UNIQUE DEFAULT ('CUS-' || substr(strftime('%Y%m%d', 'now', '+7 hours'), 3) || '-' || upper(substr(hex(randomblob(4)), 1, 6))),
  first_name             TEXT,
  last_name              TEXT,
  business_name          TEXT,
  email                 TEXT,
  phone                 TEXT,
  national_id            TEXT,
  status                TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'blocked')),
  risk_score             REAL NOT NULL DEFAULT 0 CHECK (risk_score >= 0 AND risk_score <= 100),
  risk_level             TEXT NOT NULL DEFAULT 'low' CHECK (risk_level IN ('low', 'medium', 'high', 'critical')),
  risk_factors           TEXT,
  total_transactions     INTEGER NOT NULL DEFAULT 0,
  total_amount_paid       INTEGER NOT NULL DEFAULT 0,
  total_amount_received   INTEGER NOT NULL DEFAULT 0,
  last_transaction_at     TEXT,
  failed_transaction_count INTEGER NOT NULL DEFAULT 0,
  metadata              TEXT,
  created_at             TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at             TEXT NOT NULL DEFAULT (datetime('now')),
  deleted_at             TEXT
);
CREATE INDEX idx_customers_deleted_at ON customers (deleted_at);
CREATE INDEX idx_customers_email      ON customers (email);
CREATE INDEX idx_customers_risk_level ON customers (risk_level);
CREATE INDEX idx_customers_status     ON customers (status);
CREATE TABLE integrations (
  id              TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  merchant_id      TEXT NOT NULL REFERENCES merchants (id) ON DELETE CASCADE,
  name            TEXT NOT NULL,
  slug            TEXT NOT NULL,
  description     TEXT,
  status          TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'active', 'suspended')),
  inbound_enabled  INTEGER NOT NULL DEFAULT 1 CHECK (inbound_enabled IN (0, 1)),
  outbound_enabled INTEGER NOT NULL DEFAULT 0 CHECK (outbound_enabled IN (0, 1)),
  webhook_url      TEXT,
  webhook_secret   TEXT,
  metadata        TEXT,
  created_by       TEXT REFERENCES accounts (id) ON DELETE SET NULL,
  created_at       TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at       TEXT NOT NULL DEFAULT (datetime('now')),
  deposit_destination TEXT NOT NULL DEFAULT 'bank' CHECK (deposit_destination IN ('bank', 'wallet')),
  min_payment_amount INTEGER,
  max_payment_amount INTEGER,
  min_payout_amount  INTEGER,
  max_payout_amount  INTEGER,
  daily_payment_limit   INTEGER,
  monthly_payment_limit INTEGER,
  daily_payout_limit    INTEGER,
  monthly_payout_limit  INTEGER,
  UNIQUE (merchant_id, slug)
);
CREATE INDEX idx_integrations_slug        ON integrations (slug);
CREATE INDEX idx_integrations_status      ON integrations (status);
CREATE TABLE provider_payment_config (
  id                  TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  provider_id          TEXT NOT NULL UNIQUE REFERENCES providers (id) ON DELETE CASCADE,
  supported_methods    TEXT NOT NULL DEFAULT '["promptpay","bank_transfer"]',
  min_amount           INTEGER NOT NULL DEFAULT 1,
  max_amount           INTEGER NOT NULL DEFAULT 10000000,
  daily_limit          INTEGER,
  monthly_limit        INTEGER,
  promptpay_expiry_min  INTEGER NOT NULL DEFAULT 15,
  bank_transfer_expiry_min INTEGER NOT NULL DEFAULT 60,
  supports_refund      INTEGER NOT NULL DEFAULT 0 CHECK (supports_refund IN (0, 1)),
  fee_percentage       REAL NOT NULL DEFAULT 0 CHECK (fee_percentage >= 0),
  flat_fee_amount       INTEGER NOT NULL DEFAULT 0 CHECK (flat_fee_amount >= 0),
  created_at           TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at           TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE provider_settlement_config (
  id                  TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  provider_id          TEXT NOT NULL UNIQUE REFERENCES providers (id) ON DELETE CASCADE,
  min_amount           INTEGER NOT NULL DEFAULT 0,
  max_amount           INTEGER,
  fee_percentage       REAL NOT NULL DEFAULT 0 CHECK (fee_percentage >= 0),
  flat_fee_amount       INTEGER NOT NULL DEFAULT 0 CHECK (flat_fee_amount >= 0),
  processing_time_hours INTEGER NOT NULL DEFAULT 24,
  cutoff_time_utc       TEXT,
  created_at           TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at           TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE provider_wallet_config (
  id                    TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  provider_id            TEXT NOT NULL UNIQUE REFERENCES providers (id) ON DELETE CASCADE,
  daily_deposit_limit     INTEGER,
  monthly_deposit_limit   INTEGER,
  daily_withdrawal_limit  INTEGER,
  monthly_withdrawal_limit INTEGER,
  supports_qr            INTEGER NOT NULL DEFAULT 0 CHECK (supports_qr IN (0, 1)),
  supports_bank_transfer  INTEGER NOT NULL DEFAULT 0 CHECK (supports_bank_transfer IN (0, 1)),
  created_at             TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at             TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE provider_daily_usage (
  id                        TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  provider_id                TEXT NOT NULL REFERENCES providers (id) ON DELETE CASCADE,
  date                      TEXT NOT NULL,
  payment_count              INTEGER NOT NULL DEFAULT 0,
  payment_success_count       INTEGER NOT NULL DEFAULT 0,
  payment_failure_count       INTEGER NOT NULL DEFAULT 0,
  payment_volume             INTEGER NOT NULL DEFAULT 0,
  payout_count               INTEGER NOT NULL DEFAULT 0,
  payout_success_count        INTEGER NOT NULL DEFAULT 0,
  payout_failure_count        INTEGER NOT NULL DEFAULT 0,
  payout_volume              INTEGER NOT NULL DEFAULT 0,
  verification_count         INTEGER NOT NULL DEFAULT 0,
  verification_success_count  INTEGER NOT NULL DEFAULT 0,
  avg_response_time_ms         INTEGER,
  uptime_percentage          REAL,
  created_at                 TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at                 TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE (provider_id, date)
);
CREATE TABLE ledger_accounts (
  id              TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  account_type    TEXT NOT NULL CHECK (account_type IN (
    'wallet',
    'wallet_reserved',
    'platform_fees',
    'reseller_commission',
    'customer_bank',
    'provider_clearing'
  )),
  owner_id        TEXT,
  currency        TEXT NOT NULL DEFAULT 'THB',
  normal_balance  TEXT NOT NULL CHECK (normal_balance IN ('debit','credit')),
  created_at      TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_ledger_accounts_owner ON ledger_accounts(owner_id);
CREATE UNIQUE INDEX uidx_ledger_accounts_owned
  ON ledger_accounts(account_type, owner_id, currency)
  WHERE owner_id IS NOT NULL;
CREATE UNIQUE INDEX uidx_ledger_accounts_singleton
  ON ledger_accounts(account_type, currency)
  WHERE owner_id IS NULL;
CREATE TABLE wallets (
  id                       TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  merchant_id              TEXT UNIQUE REFERENCES merchants (id) ON DELETE RESTRICT,
  reseller_id              TEXT UNIQUE REFERENCES resellers (id) ON DELETE RESTRICT,
  currency                 TEXT NOT NULL DEFAULT 'THB',
  status                   TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'frozen', 'closed')),
  available_balance        INTEGER NOT NULL DEFAULT 0 CHECK (available_balance >= 0),
  reserved_balance         INTEGER NOT NULL DEFAULT 0 CHECK (reserved_balance >= 0),
  low_balance_threshold    INTEGER NOT NULL DEFAULT 0,
  alert_enabled            INTEGER NOT NULL DEFAULT 0 CHECK (alert_enabled IN (0, 1)),
  daily_deposit_limit      INTEGER DEFAULT 10000000,
  monthly_deposit_limit    INTEGER DEFAULT 100000000,
  daily_withdrawal_limit   INTEGER DEFAULT 10000000,
  monthly_withdrawal_limit INTEGER DEFAULT 100000000,
  created_at               TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at               TEXT NOT NULL DEFAULT (datetime('now')),
  min_deposit_amount       INTEGER,
  max_deposit_amount       INTEGER,
  min_withdrawal_amount    INTEGER,
  max_withdrawal_amount    INTEGER,
  min_payout_amount        INTEGER,
  max_payout_amount        INTEGER,
  CHECK (
    (merchant_id IS NOT NULL AND reseller_id IS NULL) OR
    (merchant_id IS NULL AND reseller_id IS NOT NULL)
  )
);
CREATE INDEX idx_wallets_status      ON wallets (status);
CREATE TABLE ledger_batch_guards (
  id         TEXT PRIMARY KEY,
  label      TEXT NOT NULL,
  ok         INTEGER NOT NULL CHECK (ok = 1),
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE settlement_items (
  id                TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  settlement_id     TEXT NOT NULL REFERENCES settlements (id) ON DELETE CASCADE,
  payment_intent_id TEXT NOT NULL REFERENCES payment_intents (id) ON DELETE RESTRICT,
  amount            INTEGER NOT NULL CHECK (amount > 0),
  fee_amount        INTEGER NOT NULL DEFAULT 0 CHECK (fee_amount >= 0),
  net_amount        INTEGER NOT NULL CHECK (net_amount >= 0),
  currency          TEXT NOT NULL DEFAULT 'THB',
  created_at        TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE (settlement_id, payment_intent_id)
);
CREATE INDEX idx_settlement_items_payment_intent_id ON settlement_items (payment_intent_id);
CREATE VIEW gl_activity AS
WITH tx AS (
  SELECT transaction_id, source_type, source_id, MIN(created_at) AS created_at
  FROM ledger_entries
  GROUP BY transaction_id, source_type, source_id
),
wallet_leg AS (
  -- Single merchant/reseller wallet leg for adjustment/reserve_release/manual
  -- transactions (which have no domain record).
  SELECT
    le.transaction_id,
    MIN(w.merchant_id)   AS merchant_id,
    MIN(la.owner_id)     AS wallet_id,
    MIN(le.amount)       AS amount,
    MIN(le.direction)    AS direction
  FROM ledger_entries le
  JOIN ledger_accounts la ON la.id = le.account_id AND la.account_type = 'wallet'
  JOIN wallets w ON w.id = la.owner_id
  WHERE le.source_type IN ('adjustment', 'reserve_release', 'manual')
  GROUP BY le.transaction_id
),
fee_leg AS (
  -- GL-derived fee per transaction: the portion of the gross that did NOT reach
  -- the paying merchant — i.e. credits to platform / reseller wallets. Accurate
  -- for every source type (wallet-routed payment fee, settlement fee split,
  -- payout/deposit fee) without depending on per-domain fee columns.
  SELECT le.transaction_id, SUM(le.amount) AS fee
  FROM ledger_entries le
  JOIN ledger_accounts la ON la.id = le.account_id AND la.account_type = 'wallet'
  JOIN wallets w ON w.id = la.owner_id
  WHERE le.direction = 'credit'
    AND (w.merchant_id = '__platform__' OR w.reseller_id IS NOT NULL)
  GROUP BY le.transaction_id
)
SELECT
  tx.transaction_id AS id,
  tx.transaction_id,
  tx.source_type,
  tx.source_id,
  tx.created_at,
  COALESCE(pi.merchant_id, po.merchant_id, wd.merchant_id, ww.merchant_id, s.merchant_id, wl.merchant_id) AS merchant_id,
  COALESCE(pi.integration_id, po.integration_id, wd.integration_id, s.integration_id) AS integration_id,
  COALESCE(pi.customer_id, po.customer_id) AS customer_id,
  COALESCE(po.wallet_id, wd.wallet_id, ww.wallet_id, s.wallet_id, wl.wallet_id) AS wallet_id,
  COALESCE(pi.reference_number, po.reference_number, wd.reference_number, ww.reference_number, s.reference_number) AS reference_number,
  COALESCE(pi.amount, po.amount, wd.amount, ww.amount, s.gross_amount, wl.amount) AS amount,
  COALESCE(fl.fee, 0) AS fee_amount,
  COALESCE(pi.amount, po.amount, wd.amount, ww.amount, s.gross_amount, wl.amount, 0) - COALESCE(fl.fee, 0) AS net_amount,
  COALESCE(pi.currency, po.currency, wd.currency, ww.currency, s.currency, 'THB') AS currency,
  COALESCE(pi.status, po.status, wd.status, ww.status, s.status, 'completed') AS status,
  CASE tx.source_type
    WHEN 'payment_intent'    THEN 'credit'
    WHEN 'wallet_deposit'    THEN 'credit'
    WHEN 'reserve_release'   THEN 'credit'
    WHEN 'payout'            THEN 'debit'
    WHEN 'wallet_withdrawal' THEN 'debit'
    WHEN 'settlement'        THEN 'debit'
    WHEN 'adjustment'        THEN COALESCE(wl.direction, 'debit')
    WHEN 'manual'            THEN COALESCE(wl.direction, 'debit')
    ELSE 'debit'
  END AS direction
FROM tx
LEFT JOIN payment_intents    pi ON tx.source_type = 'payment_intent'    AND tx.source_id = pi.id
LEFT JOIN payouts            po ON tx.source_type = 'payout'            AND tx.source_id = po.id
LEFT JOIN wallet_deposits    wd ON tx.source_type = 'wallet_deposit'    AND tx.source_id = wd.id
LEFT JOIN wallet_withdrawals ww ON tx.source_type = 'wallet_withdrawal' AND tx.source_id = ww.id
LEFT JOIN settlements        s  ON tx.source_type = 'settlement'        AND tx.source_id = s.id
LEFT JOIN wallet_leg         wl ON wl.transaction_id = tx.transaction_id
LEFT JOIN fee_leg            fl ON fl.transaction_id = tx.transaction_id
/* gl_activity(id,transaction_id,source_type,source_id,created_at,merchant_id,integration_id,customer_id,wallet_id,reference_number,amount,fee_amount,net_amount,currency,status,direction) */;
CREATE TABLE integration_hmac_credentials (
  id                   TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  merchant_id          TEXT NOT NULL REFERENCES merchants (id) ON DELETE CASCADE,
  integration_id       TEXT UNIQUE REFERENCES integrations (id) ON DELETE CASCADE,
  api_key              TEXT NOT NULL UNIQUE,
  secret_key_encrypted TEXT NOT NULL,
  is_active            INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
  last_used_at         TEXT,
  created_at           TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at           TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_hmac_credentials_merchant_id    ON integration_hmac_credentials (merchant_id);
CREATE UNIQUE INDEX idx_payment_intents_idempotency_key
  ON payment_intents (merchant_id, idempotency_key)
  WHERE idempotency_key IS NOT NULL;
CREATE TABLE webhook_endpoints (
  id                TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  integration_id    TEXT REFERENCES integrations (id) ON DELETE SET NULL,
  merchant_id       TEXT NOT NULL REFERENCES merchants (id) ON DELETE CASCADE,
  url               TEXT NOT NULL,
  description       TEXT,
  signing_secret    TEXT NOT NULL,
  subscribed_events TEXT NOT NULL DEFAULT '[]',
  is_active         INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
  timeout_seconds   INTEGER NOT NULL DEFAULT 30 CHECK (timeout_seconds BETWEEN 5 AND 60),
  max_retries       INTEGER NOT NULL DEFAULT 3 CHECK (max_retries BETWEEN 0 AND 10),
  delivery_mode     TEXT NOT NULL DEFAULT 'fire_and_forget' CHECK (delivery_mode IN ('fire_and_forget', 'acknowledgment')),
  created_by        TEXT REFERENCES accounts (id) ON DELETE SET NULL,
  created_at        TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at        TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_webhook_endpoints_integration_id ON webhook_endpoints (integration_id);
CREATE INDEX idx_webhook_endpoints_merchant_url   ON webhook_endpoints (merchant_id, url);
CREATE TABLE webhook_events (
  id                  TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  integration_id      TEXT REFERENCES integrations (id) ON DELETE SET NULL,
  merchant_id         TEXT NOT NULL REFERENCES merchants (id) ON DELETE CASCADE,
  event_type          TEXT NOT NULL CHECK (event_type IN (
    'payment.created', 'payment.completed', 'payment.failed', 'payment.expired', 'payment.cancelled',
    'withdrawal.created', 'withdrawal.completed', 'withdrawal.failed', 'withdrawal.cancelled',
    'settlement.created', 'settlement.completed', 'settlement.failed', 'settlement.cancelled',
    'wallet.frozen', 'wallet.low_balance',
    'payout.created', 'payout.completed', 'payout.failed',
    'customer.created', 'customer.updated',
    'kyc.verified', 'kyc.failed',
    'merchant.updated',
    'wallet_deposit.succeeded', 'wallet_deposit.failed', 'wallet_deposit.expired', 'wallet_deposit.cancelled'
  )),
  payload             TEXT NOT NULL,
  payload_version     TEXT NOT NULL DEFAULT '1',
  payload_schema_hash TEXT,
  reference_id        TEXT,
  reference_type      TEXT,
  idempotency_key     TEXT UNIQUE,
  created_at          TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_webhook_events_integration_id ON webhook_events (integration_id);
CREATE INDEX idx_webhook_events_merchant_id    ON webhook_events (merchant_id);
CREATE INDEX idx_webhook_events_event_type     ON webhook_events (event_type);
CREATE INDEX idx_webhook_events_reference_id   ON webhook_events (reference_id);
CREATE INDEX idx_webhook_events_created_at     ON webhook_events (created_at);
CREATE TABLE webhook_deliveries (
  id               TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  reference_number TEXT NOT NULL UNIQUE DEFAULT ('WHD-' || substr(strftime('%Y%m%d', 'now', '+7 hours'), 3) || '-' || upper(substr(hex(randomblob(4)), 1, 6))),
  webhook_event_id TEXT NOT NULL REFERENCES webhook_events (id) ON DELETE CASCADE,
  endpoint_id      TEXT NOT NULL REFERENCES webhook_endpoints (id) ON DELETE CASCADE,
  status           TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'delivered', 'failed', 'permanently_failed', 'retrying')),
  attempt_count    INTEGER NOT NULL DEFAULT 0,
  max_attempts     INTEGER NOT NULL DEFAULT 3,
  next_retry_at    TEXT,
  last_attempt_at  TEXT,
  created_at       TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at       TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE (webhook_event_id, endpoint_id)
);
CREATE INDEX idx_webhook_deliveries_endpoint_id ON webhook_deliveries (endpoint_id);
CREATE INDEX idx_webhook_deliveries_status      ON webhook_deliveries (status);
CREATE INDEX idx_webhook_deliveries_retry       ON webhook_deliveries (next_retry_at) WHERE status IN ('pending', 'retrying');
CREATE TABLE webhook_delivery_attempts (
  id              TEXT NOT NULL PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  delivery_id      TEXT NOT NULL REFERENCES webhook_deliveries (id) ON DELETE CASCADE,
  attempt_number   INTEGER NOT NULL,
  status           TEXT NOT NULL CHECK (status IN ('success', 'failed', 'timeout')),
  http_status      INTEGER,
  response_body    TEXT,
  request_headers  TEXT,
  duration_ms      INTEGER,
  error_message    TEXT,
  created_at       TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_webhook_delivery_attempts_delivery_id ON webhook_delivery_attempts (delivery_id);
CREATE UNIQUE INDEX idx_settlement_pending_all_integration
  ON settlements (merchant_id)
  WHERE status = 'pending' AND integration_id IS NULL;
CREATE TRIGGER ledger_entries_no_update
  BEFORE UPDATE ON ledger_entries
BEGIN
  SELECT RAISE(ABORT, 'ledger_entries is append-only (no UPDATE)');
END;
CREATE TRIGGER ledger_entries_no_delete
  BEFORE DELETE ON ledger_entries
BEGIN
  SELECT RAISE(ABORT, 'ledger_entries is append-only (no DELETE)');
END;
CREATE TRIGGER ledger_entries_currency_uniform
  BEFORE INSERT ON ledger_entries
  WHEN EXISTS (
    SELECT 1 FROM ledger_entries le
    WHERE le.transaction_id = NEW.transaction_id
      AND le.currency != NEW.currency
  )
BEGIN
  SELECT RAISE(ABORT, 'ledger_entries currency must be uniform within a transaction');
END;
CREATE INDEX idx_payouts_provider_reconciliation
  ON payouts (provider_reconciliation_status, updated_at);
CREATE TABLE provider_reconciliation_runs (
  id                              TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  provider_id                     TEXT NOT NULL REFERENCES providers (id) ON DELETE RESTRICT,
  reconciliation_date             TEXT NOT NULL,
  window_start                    TEXT NOT NULL,
  window_end                      TEXT NOT NULL,
  lookback_days                   INTEGER NOT NULL DEFAULT 1 CHECK (lookback_days >= 1),
  status                          TEXT NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'completed', 'failed', 'skipped')),
  deposits_checked                INTEGER NOT NULL DEFAULT 0 CHECK (deposits_checked >= 0),
  transfers_checked               INTEGER NOT NULL DEFAULT 0 CHECK (transfers_checked >= 0),
  matched_count                   INTEGER NOT NULL DEFAULT 0 CHECK (matched_count >= 0),
  mismatch_count                  INTEGER NOT NULL DEFAULT 0 CHECK (mismatch_count >= 0),
  provider_balance_available      INTEGER,
  local_provider_clearing_balance INTEGER,
  error_message                   TEXT,
  started_at                      TEXT NOT NULL DEFAULT (datetime('now')),
  completed_at                    TEXT,
  created_at                      TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_provider_reconciliation_runs_provider
  ON provider_reconciliation_runs (provider_id, reconciliation_date);
CREATE INDEX idx_provider_reconciliation_runs_status
  ON provider_reconciliation_runs (status, created_at);
CREATE TABLE provider_reconciliation_items (
  id                   TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6)))),
  run_id               TEXT NOT NULL REFERENCES provider_reconciliation_runs (id) ON DELETE CASCADE,
  provider_id          TEXT NOT NULL REFERENCES providers (id) ON DELETE RESTRICT,
  provider_reference   TEXT,
  local_source_type    TEXT CHECK (local_source_type IN ('payment_intent', 'wallet_deposit', 'payout', 'settlement', 'unknown')),
  local_source_id      TEXT,
  amount               INTEGER,
  currency             TEXT NOT NULL DEFAULT 'THB',
  direction            TEXT NOT NULL CHECK (direction IN ('inbound', 'outbound', 'settlement', 'unknown')),
  provider_status      TEXT,
  local_status         TEXT,
  match_result         TEXT NOT NULL CHECK (match_result IN ('matched', 'missing_local', 'missing_provider', 'amount_mismatch', 'status_mismatch', 'duplicate_provider_ref')),
  raw_payload_hash     TEXT,
  created_at           TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_provider_reconciliation_items_run
  ON provider_reconciliation_items (run_id, match_result);
CREATE INDEX idx_provider_reconciliation_items_provider_ref
  ON provider_reconciliation_items (provider_id, provider_reference);
CREATE INDEX idx_provider_reconciliation_items_local
  ON provider_reconciliation_items (local_source_type, local_source_id);

-- ── Seed data ───────────────────────────────────────────────────────────────

INSERT INTO banks VALUES('bank-kbank-0000-0000-000000000001','Kasikornbank','ธนาคารกสิกรไทย','004','KBANK','KASITHBK',NULL,1,1,'2026-05-03 08:53:47','2026-05-03 08:53:47');
INSERT INTO banks VALUES('bank-scb00-0000-0000-000000000002','Siam Commercial Bank','ธนาคารไทยพาณิชย์','014','SCB','SICOTHBK',NULL,1,2,'2026-05-03 08:53:47','2026-05-03 08:53:47');
INSERT INTO banks VALUES('bank-bbl00-0000-0000-000000000003','Bangkok Bank','ธนาคารกรุงเทพ','002','BBL','BKKBTHBK',NULL,1,3,'2026-05-03 08:53:47','2026-05-03 08:53:47');
INSERT INTO banks VALUES('bank-ktb00-0000-0000-000000000004','Krungthai Bank','ธนาคารกรุงไทย','006','KTB','KRTHTHBK',NULL,1,4,'2026-05-03 08:53:47','2026-05-03 08:53:47');
INSERT INTO banks VALUES('bank-ttb00-0000-0000-000000000005','TMBThanachart Bank','ธนาคารทหารไทยธนชาต','011','TTB','TMBKTHBK',NULL,1,5,'2026-05-03 08:53:47','2026-05-03 08:53:47');
INSERT INTO banks VALUES('bank-bay00-0000-0000-000000000006','Bank of Ayudhya (Krungsri)','ธนาคารกรุงศรีอยุธยา','025','BAY','AYUDTHBK',NULL,1,6,'2026-05-03 08:53:47','2026-05-03 08:53:47');
INSERT INTO banks VALUES('bank-gsb00-0000-0000-000000000007','Government Savings Bank','ธนาคารออมสิน','030','GSB','GSBATHBK',NULL,1,7,'2026-05-03 08:53:47','2026-05-03 08:53:47');
INSERT INTO banks VALUES('bank-uob00-0000-0000-000000000008','United Overseas Bank','ธนาคารยูโอบี','024','UOB','UOVBTHBK',NULL,1,8,'2026-05-03 08:53:47','2026-05-03 08:53:47');
INSERT INTO banks VALUES('bank-citi0-0000-0000-000000000009','Citibank Thailand','ซิตี้แบงก์','017','CITI','CITIFRPP',NULL,1,9,'2026-05-03 08:53:47','2026-05-03 08:53:47');
INSERT INTO banks VALUES('bank-lhfg0-0000-0000-00000000000a','LH Bank','ธนาคารแลนด์ แอนด์ เฮ้าส์','073','LHFG','LAHRTHB1',NULL,1,10,'2026-05-03 08:53:47','2026-05-03 08:53:47');
INSERT INTO banks VALUES('bank-baac0-0000-0000-00000000000b','Bank for Agriculture and Agricultural Cooperatives','ธนาคารเพื่อการเกษตรและสหกรณ์การเกษตร','034','BAAC','BAABTHBK',NULL,1,11,'2026-05-03 08:53:47','2026-05-03 08:53:47');
INSERT INTO banks VALUES('bank-ghb00-0000-0000-00000000000c','Government Housing Bank','ธนาคารอาคารสงเคราะห์','033','GHB','GOHATHB1',NULL,1,12,'2026-05-03 08:53:47','2026-05-03 08:53:47');

-- Platform merchant + wallet used by platform fee GL helpers.
INSERT OR IGNORE INTO merchants (
  id, name, slug, merchant_type, status, risk_level, risk_score,
  primary_currency, settlement_frequency, settlement_method,
  auto_settlement_enabled, daily_transaction_limit, monthly_transaction_limit,
  daily_transaction_count_limit, monthly_transaction_count_limit,
  allow_auto_customer_creation, created_at, updated_at, deleted_at
) VALUES (
  '__platform__', 'Bro Pay Platform', 'bro-pay-platform', 'other', 'closed', 'low', 0,
  'THB', 'manual', 'transaction_based', 0, 0, 0, 0, 0, 0,
  datetime('now'), datetime('now'), datetime('now')
);

INSERT OR IGNORE INTO wallets (
  id, merchant_id, currency, status,
  available_balance, reserved_balance, low_balance_threshold, alert_enabled,
  daily_deposit_limit, monthly_deposit_limit,
  daily_withdrawal_limit, monthly_withdrawal_limit,
  created_at, updated_at
) VALUES (
  'wallet__platform__', '__platform__', 'THB', 'active',
  0, 0, 0, 0,
  NULL, NULL, NULL, NULL,
  datetime('now'), datetime('now')
);

INSERT OR IGNORE INTO ledger_accounts (account_type, owner_id, currency, normal_balance)
VALUES
  ('platform_fees', NULL, 'THB', 'credit'),
  ('customer_bank', NULL, 'THB', 'debit'),
  ('provider_clearing', NULL, 'THB', 'credit'),
  ('wallet', 'wallet__platform__', 'THB', 'credit'),
  ('wallet_reserved', 'wallet__platform__', 'THB', 'credit');

PRAGMA foreign_keys = ON;
