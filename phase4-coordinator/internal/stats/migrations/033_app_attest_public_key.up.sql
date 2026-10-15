-- Issue #1911 / SPEC-033 v0.9.0 §5.7 (SPEC-033-R004), SPEC-049-R033.
--
-- A recorded App Attest verification now keeps the attested public key with
-- its key id, so the coordinator can verify App Attest assertions made later
-- with the same key (SPEC-049 code-bound privacy postures). The column is
-- nullable only for rows recorded before this migration; those rows cannot
-- serve code-bound postures. A present key must be the 65-byte uncompressed
-- P-256 point whose SHA-256 is the key id, so a row can never pair a key id
-- with any other key.
--
-- The table stays insert-only. app_attest_recorder keeps exactly SELECT and
-- INSERT on it (a table-level INSERT covers the new column), and no other
-- grant changes.

ALTER TABLE provider_app_attest_verifications
    ADD COLUMN IF NOT EXISTS app_attest_public_key BYTEA NULL;

ALTER TABLE provider_app_attest_verifications
    DROP CONSTRAINT IF EXISTS provider_app_attest_verifications_public_key_check;
ALTER TABLE provider_app_attest_verifications
    ADD CONSTRAINT provider_app_attest_verifications_public_key_check
        CHECK (
            app_attest_public_key IS NULL
            OR (
                octet_length(app_attest_public_key) = 65
                AND get_byte(app_attest_public_key, 0) = 4
                AND sha256(app_attest_public_key) = app_attest_key_id
            )
        );
