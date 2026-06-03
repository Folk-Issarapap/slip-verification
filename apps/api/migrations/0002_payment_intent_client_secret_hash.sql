-- Store checkout client-secret lookup material as a one-way hash for new rows.
-- The original client_secret column remains in the schema as non-secret display
-- metadata only; public checkout lookup uses client_secret_hash exclusively.
ALTER TABLE payment_intents ADD COLUMN client_secret_hash TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS idx_payment_intents_client_secret_hash
  ON payment_intents (client_secret_hash)
  WHERE client_secret_hash IS NOT NULL;
