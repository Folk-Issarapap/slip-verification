-- seed.sql
-- Production-safe dev seed: staff accounts, merchant preview accounts, KBNK provider.
--
-- Safe to run multiple times (uses INSERT OR IGNORE).
-- Run: pnpm db:seed
--
-- Password for all seed accounts: password123
-- Hash: $2b$10$ySGg52sE9F7ILSe6At2aGeByewBmz/j9AYDdG/T7xzsubNZyE.gFa

PRAGMA foreign_keys = ON;

-- ═══════════════════════════════════════════════
-- SEED STAFF ACCOUNTS
-- staff_role is hardcoded on the account row (no RBAC tables)
-- ═══════════════════════════════════════════════
INSERT OR IGNORE INTO accounts (id, email, name, display_name, password_hash, status, kind, staff_role, email_verified_at) VALUES
  (
    'acct-super-admin-0000-000000000001',
    'super@bropay.com',
    'Super Admin',
    'Super Admin',
    '$2b$10$ySGg52sE9F7ILSe6At2aGeByewBmz/j9AYDdG/T7xzsubNZyE.gFa',
    'active',
    'staff',
    'super_admin',
    datetime('now')
  ),
  (
    'acct-admin-000000-0000-000000000002',
    'admin@bropay.com',
    'Admin User',
    'Admin',
    '$2b$10$ySGg52sE9F7ILSe6At2aGeByewBmz/j9AYDdG/T7xzsubNZyE.gFa',
    'active',
    'staff',
    'admin',
    datetime('now')
  ),
  (
    'acct-dev-0000000-0000-000000000003',
    'dev@bropay.com',
    'Developer User',
    'Developer',
    '$2b$10$ySGg52sE9F7ILSe6At2aGeByewBmz/j9AYDdG/T7xzsubNZyE.gFa',
    'active',
    'staff',
    'developer',
    datetime('now')
  ),
  (
    'acct-mod-0000000-0000-000000000004',
    'moderator@bropay.com',
    'Moderator User',
    'Moderator',
    '$2b$10$ySGg52sE9F7ILSe6At2aGeByewBmz/j9AYDdG/T7xzsubNZyE.gFa',
    'active',
    'staff',
    'moderator',
    datetime('now')
  ),
  (
    'acct-wrt-0000000-0000-000000000005',
    'writer@bropay.com',
    'Writer User',
    'Writer',
    '$2b$10$ySGg52sE9F7ILSe6At2aGeByewBmz/j9AYDdG/T7xzsubNZyE.gFa',
    'active',
    'staff',
    'writer',
    datetime('now')
  ),
  (
    'acct-user-000000-0000-000000000006',
    'user@bropay.com',
    'User Account',
    'User',
    '$2b$10$ySGg52sE9F7ILSe6At2aGeByewBmz/j9AYDdG/T7xzsubNZyE.gFa',
    'active',
    'staff',
    'user',
    datetime('now')
  ),
  (
    'acct-folk-000000-0000-000000000007',
    'folk@bropay.com',
    'Folk',
    'Folk',
    '$2b$10$ySGg52sE9F7ILSe6At2aGeByewBmz/j9AYDdG/T7xzsubNZyE.gFa',
    'active',
    'staff',
    'super_admin',
    datetime('now')
  ),
  (
    'acct-boat-000000-0000-000000000008',
    'boat@bropay.com',
    'Boat',
    'Boat',
    '$2b$10$ySGg52sE9F7ILSe6At2aGeByewBmz/j9AYDdG/T7xzsubNZyE.gFa',
    'active',
    'staff',
    'super_admin',
    datetime('now')
  ),
  (
    'acct-tor-0000000-0000-000000000009',
    'tor@bropay.com',
    'Tor',
    'Tor',
    '$2b$10$ySGg52sE9F7ILSe6At2aGeByewBmz/j9AYDdG/T7xzsubNZyE.gFa',
    'active',
    'staff',
    'super_admin',
    datetime('now')
  );

-- ═══════════════════════════════════════════════
-- SEED MERCHANT PREVIEW + MEMBER ACCOUNTS
-- Merchant roles covered: owner, admin, manager, member
-- ═══════════════════════════════════════════════
INSERT OR IGNORE INTO accounts (id, email, name, display_name, password_hash, status, kind, email_verified_at) VALUES
  (
    'acct-m-owner-000-0000-000000000101',
    'merchant.owner@bropay.com',
    'Merchant Owner',
    'Merchant Owner',
    '$2b$10$ySGg52sE9F7ILSe6At2aGeByewBmz/j9AYDdG/T7xzsubNZyE.gFa',
    'active',
    'merchant',
    datetime('now')
  ),
  (
    'acct-m-admin-000-0000-000000000102',
    'merchant.admin@bropay.com',
    'Merchant Admin',
    'Merchant Admin',
    '$2b$10$ySGg52sE9F7ILSe6At2aGeByewBmz/j9AYDdG/T7xzsubNZyE.gFa',
    'active',
    'merchant',
    datetime('now')
  ),
  (
    'acct-m-manager-00-0000-000000000103',
    'merchant.manager@bropay.com',
    'Merchant Manager',
    'Merchant Manager',
    '$2b$10$ySGg52sE9F7ILSe6At2aGeByewBmz/j9AYDdG/T7xzsubNZyE.gFa',
    'active',
    'merchant',
    datetime('now')
  ),
  (
    'acct-m-member-000-0000-000000000104',
    'merchant.member@bropay.com',
    'Merchant Member',
    'Merchant Member',
    '$2b$10$ySGg52sE9F7ILSe6At2aGeByewBmz/j9AYDdG/T7xzsubNZyE.gFa',
    'active',
    'merchant',
    datetime('now')
  );

INSERT OR IGNORE INTO merchants (
  id,
  name,
  slug,
  status,
  merchant_type,
  primary_currency,
  settlement_frequency,
  settlement_method,
  auto_settlement_enabled,
  allow_auto_customer_creation,
  created_by,
  approved_by,
  approved_at
) VALUES (
  'merch-demo-merchant-0000-000000000001',
  'Bangkok Retail Group',
  'bangkok-retail-group',
  'active',
  'other',
  'THB',
  'daily',
  'transaction_based',
  0,
  1,
  'acct-super-admin-0000-000000000001',
  'acct-super-admin-0000-000000000001',
  datetime('now')
);

UPDATE merchants
SET
  name = 'Bangkok Retail Group',
  slug = 'bangkok-retail-group',
  updated_at = datetime('now')
WHERE id = 'merch-demo-merchant-0000-000000000001';

INSERT OR IGNORE INTO wallets (id, merchant_id, currency, status) VALUES
  (
    'wall-demo-merchant-0000-000000000001',
    'merch-demo-merchant-0000-000000000001',
    'THB',
    'active'
  );

INSERT OR IGNORE INTO fee_configurations (
  id,
  merchant_id,
  integration_id,
  stream_type,
  fee_percentage,
  flat_fee_amount,
  min_fee,
  max_fee,
  calculation_method,
  effective_from,
  is_active,
  created_by
) VALUES
  (
    'fee-demo-merch-inbound-0000-000000001',
    'merch-demo-merchant-0000-000000000001',
    NULL,
    'inbound',
    1.50,
    0,
    0,
    NULL,
    'transaction_based',
    datetime('now'),
    1,
    'acct-super-admin-0000-000000000001'
  ),
  (
    'fee-demo-merch-outbound-0000-000000002',
    'merch-demo-merchant-0000-000000000001',
    NULL,
    'outbound',
    1.50,
    0,
    0,
    NULL,
    'transaction_based',
    datetime('now'),
    1,
    'acct-super-admin-0000-000000000001'
  );

INSERT OR IGNORE INTO merchant_memberships (id, account_id, merchant_id, role, status, invited_by, joined_at) VALUES
  (
    'mm-demo-owner-000000000000000000001',
    'acct-m-owner-000-0000-000000000101',
    'merch-demo-merchant-0000-000000000001',
    'owner',
    'active',
    'acct-super-admin-0000-000000000001',
    datetime('now')
  ),
  (
    'mm-demo-admin-000000000000000000002',
    'acct-m-admin-000-0000-000000000102',
    'merch-demo-merchant-0000-000000000001',
    'admin',
    'active',
    'acct-super-admin-0000-000000000001',
    datetime('now')
  ),
  (
    'mm-demo-manager-0000000000000000003',
    'acct-m-manager-00-0000-000000000103',
    'merch-demo-merchant-0000-000000000001',
    'manager',
    'active',
    'acct-super-admin-0000-000000000001',
    datetime('now')
  ),
  (
    'mm-demo-member-00000000000000000004',
    'acct-m-member-000-0000-000000000104',
    'merch-demo-merchant-0000-000000000001',
    'member',
    'active',
    'acct-super-admin-0000-000000000001',
    datetime('now')
  );


-- ═══════════════════════════════════════════════
-- SEED RESELLER PREVIEW
-- Dedicated reseller entity (resellers table) + owner account + membership.
-- Login: reseller.owner@bropay.com / password123
-- ═══════════════════════════════════════════════
INSERT OR IGNORE INTO accounts (id, email, name, display_name, password_hash, status, kind, email_verified_at) VALUES
  (
    'acct-r-owner-000-0000-000000000201',
    'reseller.owner@bropay.com',
    'Reseller Owner',
    'Reseller Owner',
    '$2b$10$ySGg52sE9F7ILSe6At2aGeByewBmz/j9AYDdG/T7xzsubNZyE.gFa',
    'active',
    'reseller',
    datetime('now')
  );

-- Preview credentials are shared in local docs; keep these accounts usable
-- under the first-login password-rotation gate.
UPDATE accounts
SET
  must_change_password = 0,
  last_login_at = COALESCE(last_login_at, datetime('now')),
  updated_at = datetime('now')
WHERE email IN (
  'super@bropay.com',
  'admin@bropay.com',
  'dev@bropay.com',
  'moderator@bropay.com',
  'writer@bropay.com',
  'user@bropay.com',
  'folk@bropay.com',
  'boat@bropay.com',
  'tor@bropay.com',
  'merchant.owner@bropay.com',
  'merchant.admin@bropay.com',
  'merchant.manager@bropay.com',
  'merchant.member@bropay.com',
  'reseller.owner@bropay.com'
);

INSERT OR IGNORE INTO resellers (id, name, slug, status, commission_percentage, created_by) VALUES
  (
    'res-demo-reseller-0000-000000000001',
    'Bangkok Partner Network',
    'bangkok-partner-network',
    'active',
    1.5,
    'acct-super-admin-0000-000000000001'
  );

UPDATE resellers
SET
  name = 'Bangkok Partner Network',
  slug = 'bangkok-partner-network',
  updated_at = datetime('now')
WHERE id = 'res-demo-reseller-0000-000000000001';

INSERT OR IGNORE INTO reseller_memberships (account_id, reseller_id, role, status) VALUES
  (
    'acct-r-owner-000-0000-000000000201',
    'res-demo-reseller-0000-000000000001',
    'owner',
    'active'
  );

-- Reseller wallet (commission credits land here; merchant_id NULL per 0033).
INSERT OR IGNORE INTO wallets (id, reseller_id, currency, status) VALUES
  (
    'wall-demo-reseller-0000-000000000001',
    'res-demo-reseller-0000-000000000001',
    'THB',
    'active'
  );


-- ═══════════════════════════════════════════════
-- SEED KBNK PROVIDER
-- ═══════════════════════════════════════════════
INSERT OR IGNORE INTO providers (
  id, name, slug, description, provider_type, status, auth_method,
  api_endpoint, health_check_endpoint, health_check_interval, health_check_timeout,
  health_status, is_default
) VALUES
  (
    'prov-kbnk-000000-0000-000000000001',
    'KBNK',
    'kbnk',
    'KBank payment gateway — deposits, withdrawals, KYC',
    'payment_gateway',
    'active',
    'oauth2',
    'https://kbnk-payment-api-staging.example.com',
    'https://kbnk-payment-api-staging.example.com/health',
    60,
    10,
    'unknown',
    1
  );

INSERT OR IGNORE INTO provider_capabilities (id, provider_id, supports_payment, supports_settlement, supports_wallet, supports_bank_account_verification, supports_refund, supports_webhook) VALUES
  (
    'pcap-kbnk-000000-0000-000000000001',
    'prov-kbnk-000000-0000-000000000001',
    1, 1, 1, 1, 0, 1
  );

INSERT OR IGNORE INTO provider_payment_config (id, provider_id, supported_methods, min_amount, max_amount, promptpay_expiry_min, bank_transfer_expiry_min, fee_percentage) VALUES
  (
    'ppay-kbnk-000000-0000-000000000001',
    'prov-kbnk-000000-0000-000000000001',
    '["promptpay","bank_transfer"]',
    1,
    10000000,
    15,
    60,
    0
  );

INSERT OR IGNORE INTO provider_bank_account_verification_config (id, provider_id, supports_name_matching, min_similarity_score, timeout_seconds) VALUES
  (
    'pbav-kbnk-000000-0000-000000000001',
    'prov-kbnk-000000-0000-000000000001',
    1,
    80,
    300
  );


-- Platform default fee configurations intentionally not seeded here.
-- `resolveFeeConfig` falls back to env vars (PLATFORM_FEE_INBOUND_PCT,
-- PLATFORM_FEE_OUTBOUND_PCT) when no row matches, so the table can start empty.
-- Seed admin can create rows via the admin UI if table-level overrides are needed.
