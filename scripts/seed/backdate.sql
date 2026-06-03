-- Backdate preview merchant rows across the last 90 days.
--
-- SQLite doesn't have power() so we approximate log-weighting by dividing
-- a uniform 0–90 offset by a random divisor of 1, 2, or 3.
-- This clusters ~50% of rows within 30 days and trails off toward 90 days.
--
-- Formula:
--   base_offset = abs(random()) % 90          → uniform 0–89 days
--   divisor     = 1 + abs(random()) % 3       → 1, 2, or 3
--   final_days  = base_offset / divisor        → biased toward 0 (recent)
--
-- IMPORTANT: run from apps/api (wrangler must be invoked there).

-- customers
UPDATE customers
SET
  created_at = datetime('now',
    '-' || (abs(random()) % 90 / (1 + abs(random()) % 3)) || ' days',
    '-' || (abs(random()) % 24) || ' hours',
    '-' || (abs(random()) % 60) || ' minutes'),
  updated_at = created_at
WHERE id IN (
  SELECT customer_id FROM customer_merchants
  WHERE merchant_id = 'merch-demo-merchant-0000-000000000001'
);

-- payment_intents — created_at + updated_at
UPDATE payment_intents
SET
  created_at = datetime('now',
    '-' || (abs(random()) % 90 / (1 + abs(random()) % 3)) || ' days',
    '-' || (abs(random()) % 24) || ' hours',
    '-' || (abs(random()) % 60) || ' minutes'),
  updated_at = created_at
WHERE merchant_id = 'merch-demo-merchant-0000-000000000001';

-- payment_intents — succeeded_at = created_at + a few minutes
UPDATE payment_intents
SET succeeded_at = datetime(created_at, '+' || (abs(random()) % 30 + 1) || ' minutes')
WHERE merchant_id = 'merch-demo-merchant-0000-000000000001'
  AND status = 'succeeded';

-- payment_intents — failed_at = created_at + a few minutes
UPDATE payment_intents
SET failed_at = datetime(created_at, '+' || (abs(random()) % 15 + 1) || ' minutes')
WHERE merchant_id = 'merch-demo-merchant-0000-000000000001'
  AND status = 'failed';

-- payment_intents — cancelled_at = created_at + a few minutes
UPDATE payment_intents
SET cancelled_at = datetime(created_at, '+' || (abs(random()) % 10 + 1) || ' minutes')
WHERE merchant_id = 'merch-demo-merchant-0000-000000000001'
  AND status = 'cancelled';

-- payment_intents — expires_at for expired: set to created_at + 15min (already past)
UPDATE payment_intents
SET expires_at = datetime(created_at, '+15 minutes')
WHERE merchant_id = 'merch-demo-merchant-0000-000000000001'
  AND status = 'expired';

-- settlements — backdate created_at + settlement_date + period_start/end
UPDATE settlements
SET
  created_at = datetime('now',
    '-' || (abs(random()) % 60 / (1 + abs(random()) % 2)) || ' days',
    '-' || (abs(random()) % 12) || ' hours'),
  updated_at = created_at,
  settlement_date = date(created_at),
  period_start = date(created_at, '-7 days'),
  period_end   = date(created_at, '-1 day'),
  completed_at = CASE
    WHEN status = 'completed' THEN datetime(created_at, '+1 day', '+' || (abs(random()) % 6) || ' hours')
    ELSE completed_at
  END,
  failed_at = CASE
    WHEN status = 'failed' THEN datetime(created_at, '+' || (abs(random()) % 24) || ' hours')
    ELSE failed_at
  END
WHERE merchant_id = 'merch-demo-merchant-0000-000000000001';

-- payouts
UPDATE payouts
SET
  created_at = datetime('now',
    '-' || (abs(random()) % 60 / (1 + abs(random()) % 2)) || ' days',
    '-' || (abs(random()) % 24) || ' hours'),
  updated_at = created_at,
  reserved_at = created_at,
  completed_at = CASE
    WHEN status = 'completed' THEN datetime(created_at, '+' || (abs(random()) % 24 + 1) || ' hours')
    ELSE completed_at
  END,
  failed_at = CASE
    WHEN status = 'failed' THEN datetime(created_at, '+' || (abs(random()) % 12 + 1) || ' hours')
    ELSE failed_at
  END
WHERE merchant_id = 'merch-demo-merchant-0000-000000000001';

-- webhook_deliveries — smear across last 30 days (more recent than PIs)
UPDATE webhook_deliveries
SET
  created_at = datetime('now',
    '-' || (abs(random()) % 30 / (1 + abs(random()) % 3)) || ' days',
    '-' || (abs(random()) % 24) || ' hours'),
  updated_at = created_at,
  last_attempt_at = CASE
    WHEN last_attempt_at IS NOT NULL
    THEN datetime(created_at, '+' || (abs(random()) % 60) || ' minutes')
    ELSE NULL
  END
WHERE endpoint_id IN (
  SELECT id FROM webhook_endpoints
  WHERE merchant_id = 'merch-demo-merchant-0000-000000000001'
);

-- ledger_entries — gl_activity is the new transactions list. This is local
-- fixture shaping only: temporarily relax the append-only UPDATE trigger,
-- align GL entry timestamps to their final domain lifecycle rows, then restore it.
DROP TRIGGER IF EXISTS ledger_entries_no_update;

UPDATE ledger_entries
SET created_at = COALESCE(
  (
    SELECT COALESCE(pi.succeeded_at, pi.failed_at, pi.cancelled_at, pi.created_at)
    FROM payment_intents pi
    WHERE pi.id = ledger_entries.source_id
  ),
  created_at
)
WHERE source_type = 'payment_intent';

UPDATE ledger_entries
SET created_at = COALESCE(
  (
    SELECT COALESCE(s.completed_at, s.failed_at, s.cancelled_at, s.created_at)
    FROM settlements s
    WHERE s.id = ledger_entries.source_id
  ),
  created_at
)
WHERE source_type = 'settlement';

UPDATE ledger_entries
SET created_at = COALESCE(
  (
    SELECT COALESCE(p.completed_at, p.failed_at, p.cancelled_at, p.created_at)
    FROM payouts p
    WHERE p.id = ledger_entries.source_id
  ),
  created_at
)
WHERE source_type = 'payout';

UPDATE ledger_entries
SET created_at = datetime('now', '-90 days')
WHERE source_type = 'adjustment'
  AND source_id LIKE 'bank-topup-%';

CREATE TRIGGER ledger_entries_no_update
  BEFORE UPDATE ON ledger_entries
BEGIN
  SELECT RAISE(ABORT, 'ledger_entries is append-only (no UPDATE)');
END;
