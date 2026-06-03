-- seed-folk-commissions-dev.sql
-- Optional dev data for reseller "commissions" UI (Folk track — RESELLER_FEATURES_CHECKLIST.md).
--
-- Prerequisites:
--   1. pnpm migrate:local && pnpm db:seed   (staff + demo accounts exist)
--   2. Merchant below MUST already exist with can_resell = 1 and a row in `wallets`.
--   3. If you use a different reseller id, replace ALL occurrences of:
--        4460e973-096a-4ca0-a9a2-f13c67448106
--
-- Safe to re-run: uses INSERT OR IGNORE where possible.
-- Idempotent ledger rows use fixed UUIDs.
--
-- Run: pnpm --filter api db:seed:folk
--
PRAGMA foreign_keys = ON;

-- ═══════════════════════════════════════════════════════════════════════════
-- 1) Sub-merchant under your reseller (downline / hierarchy realism)
-- ═══════════════════════════════════════════════════════════════════════════

INSERT OR IGNORE INTO merchants (
  id,
  name,
  slug,
  status,
  merchant_type,
  primary_currency,
  parent_merchant_id,
  can_resell,
  allow_auto_customer_creation,
  created_by,
  approved_by,
  approved_at
) VALUES (
  'b8f0e9d1-0c2a-43be-9f8a-010101010101',
  'Folk Seed Sub-Merchant (dev)',
  'folk-seed-sub-dev',
  'active',
  'other',
  'THB',
  '4460e973-096a-4ca0-a9a2-f13c67448106',
  0,
  1,
  'acct-super-admin-0000-000000000001',
  'acct-super-admin-0000-000000000001',
  datetime('now')
);

INSERT OR IGNORE INTO wallets (id, merchant_id, currency, status, available_balance)
VALUES (
  'c7d6e5f4-3a2b-41ed-9e8f-020202020202',
  'b8f0e9d1-0c2a-43be-9f8a-010101010101',
  'THB',
  'active',
  0
);

-- Closure rows (matches sub-merchant / admin create pattern: self @ depth 0, parent @ depth 1)
INSERT OR IGNORE INTO merchant_hierarchy (ancestor_id, descendant_id, depth, commission_percentage)
VALUES ('b8f0e9d1-0c2a-43be-9f8a-010101010101', 'b8f0e9d1-0c2a-43be-9f8a-010101010101', 0, 0);

INSERT OR IGNORE INTO merchant_hierarchy (ancestor_id, descendant_id, depth, commission_percentage)
VALUES ('4460e973-096a-4ca0-a9a2-f13c67448106', 'b8f0e9d1-0c2a-43be-9f8a-010101010101', 1, 0.35);

-- Merchant-scope fees (inbound/outbound) so the row looks like a normal sub-merchant
INSERT OR IGNORE INTO fee_configurations (
  id,
  merchant_id,
  integration_id,
  stream_type,
  fee_percentage,
  flat_fee_amount,
  calculation_method,
  is_active,
  created_by
) VALUES
(
  'fee-folk-seed-in-00000000000000001',
  'b8f0e9d1-0c2a-43be-9f8a-010101010101',
  NULL,
  'inbound',
  2.0,
  0,
  'transaction_based',
  1,
  'acct-super-admin-0000-000000000001'
),
(
  'fee-folk-seed-out-0000000000000002',
  'b8f0e9d1-0c2a-43be-9f8a-010101010101',
  NULL,
  'outbound',
  1.0,
  0,
  'transaction_based',
  1,
  'acct-super-admin-0000-000000000001'
);

-- ═══════════════════════════════════════════════════════════════════════════
-- 2) Sample commission credits on the reseller wallet (what GET /commissions reads)
-- ═══════════════════════════════════════════════════════════════════════════

INSERT OR IGNORE INTO wallet_ledger_entries (
  id,
  wallet_id,
  entry_type,
  reference_type,
  reference_id,
  amount,
  currency,
  balance_before,
  balance_after,
  description,
  metadata,
  performed_by,
  created_at
)
SELECT
  'e1111111-1111-4111-8111-000000000001',
  w.id,
  'credit',
  'commission',
  'settlement-seed-folk-000000000001',
  15000,
  w.currency,
  200000,
  215000,
  'Dev seed — commission from downline settlement (older period)',
  '{"seed":"folk-commissions-dev","sub_merchant_id":"b8f0e9d1-0c2a-43be-9f8a-010101010101"}',
  NULL,
  datetime('now', '-40 days')
FROM wallets w
WHERE w.merchant_id = '4460e973-096a-4ca0-a9a2-f13c67448106'
LIMIT 1;

INSERT OR IGNORE INTO wallet_ledger_entries (
  id,
  wallet_id,
  entry_type,
  reference_type,
  reference_id,
  amount,
  currency,
  balance_before,
  balance_after,
  description,
  metadata,
  performed_by,
  created_at
)
SELECT
  'e2222222-2222-4222-8222-000000000002',
  w.id,
  'credit',
  'commission',
  'settlement-seed-folk-000000000002',
  23600,
  w.currency,
  215000,
  238600,
  'Dev seed — commission (this month, this week)',
  '{"seed":"folk-commissions-dev","sub_merchant_id":"b8f0e9d1-0c2a-43be-9f8a-010101010101"}',
  NULL,
  datetime('now', '-2 days')
FROM wallets w
WHERE w.merchant_id = '4460e973-096a-4ca0-a9a2-f13c67448106'
LIMIT 1;

INSERT OR IGNORE INTO wallet_ledger_entries (
  id,
  wallet_id,
  entry_type,
  reference_type,
  reference_id,
  amount,
  currency,
  balance_before,
  balance_after,
  description,
  metadata,
  performed_by,
  created_at
)
SELECT
  'e3333333-3333-4333-8333-000000000003',
  w.id,
  'credit',
  'commission',
  'settlement-seed-folk-000000000003',
  17500,
  w.currency,
  238600,
  256100,
  'Dev seed — commission (today)',
  '{"seed":"folk-commissions-dev","sub_merchant_id":"b8f0e9d1-0c2a-43be-9f8a-010101010101"}',
  NULL,
  datetime('now')
FROM wallets w
WHERE w.merchant_id = '4460e973-096a-4ca0-a9a2-f13c67448106'
LIMIT 1;
