ALTER TABLE partner_keys
    ADD COLUMN IF NOT EXISTS provider_id TEXT;

CREATE INDEX IF NOT EXISTS partner_keys_provider_id_idx
    ON partner_keys (provider_id)
    WHERE provider_id IS NOT NULL;
