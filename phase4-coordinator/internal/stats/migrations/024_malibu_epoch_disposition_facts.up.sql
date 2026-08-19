-- SPEC-021 v0.4 first-class epoch disposition facts.
CREATE TABLE IF NOT EXISTS malibu_epoch_disposition_facts (
    id BIGSERIAL PRIMARY KEY,
    epoch_id TEXT NOT NULL,
    policy_revision TEXT NOT NULL,
    subject_type TEXT NOT NULL CHECK (
        subject_type IN ('ledger_row', 'useful_work_source', 'provider', 'wallet', 'cohort', 'duplicate_class', 'epoch')
    ),
    subject_id TEXT NOT NULL,
    provider_id TEXT NULL,
    ledger_id BIGINT NULL REFERENCES provider_rewards_ledger(id),
    external_ref TEXT NULL,
    aggregate_ref TEXT NULL,
    disposition TEXT NOT NULL CHECK (
        disposition IN ('hold', 'exclude', 'burn', 'retire')
    ),
    reason_code TEXT NOT NULL,
    decision_actor TEXT NOT NULL,
    decided_at TIMESTAMPTZ NOT NULL,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    clears_disposition_id BIGINT NULL REFERENCES malibu_epoch_disposition_facts(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (clears_disposition_id IS NULL),
    CHECK (
        subject_type <> 'provider'
        OR provider_id IS NULL
        OR provider_id = subject_id
    )
);

CREATE TABLE IF NOT EXISTS malibu_epoch_disposition_subject_memberships (
    id BIGSERIAL PRIMARY KEY,
    disposition_id BIGINT NOT NULL REFERENCES malibu_epoch_disposition_facts(id),
    epoch_id TEXT NOT NULL,
    policy_revision TEXT NOT NULL,
    subject_type TEXT NOT NULL CHECK (
        subject_type IN ('wallet', 'cohort', 'duplicate_class', 'epoch')
    ),
    subject_id TEXT NOT NULL,
    provider_id TEXT NOT NULL,
    ledger_id BIGINT NULL REFERENCES provider_rewards_ledger(id),
    external_ref TEXT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (ledger_id IS NOT NULL OR external_ref IS NOT NULL)
);

CREATE UNIQUE INDEX IF NOT EXISTS malibu_epoch_disposition_membership_unique_idx
    ON malibu_epoch_disposition_subject_memberships (
        disposition_id,
        epoch_id,
        policy_revision,
        subject_type,
        subject_id,
        provider_id,
        COALESCE(ledger_id, 0),
        COALESCE(external_ref, '')
    );

CREATE INDEX IF NOT EXISTS malibu_epoch_disposition_membership_subject_idx
    ON malibu_epoch_disposition_subject_memberships (subject_type, subject_id, provider_id);

CREATE INDEX IF NOT EXISTS malibu_epoch_disposition_subject_idx
    ON malibu_epoch_disposition_facts (subject_type, subject_id)
    WHERE active = TRUE OR disposition IN ('burn', 'retire');

CREATE INDEX IF NOT EXISTS malibu_epoch_disposition_provider_idx
    ON malibu_epoch_disposition_facts (provider_id)
    WHERE provider_id IS NOT NULL AND (active = TRUE OR disposition IN ('burn', 'retire'));

CREATE INDEX IF NOT EXISTS malibu_epoch_disposition_ledger_idx
    ON malibu_epoch_disposition_facts (ledger_id)
    WHERE ledger_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS malibu_epoch_disposition_external_ref_idx
    ON malibu_epoch_disposition_facts (external_ref)
    WHERE external_ref IS NOT NULL;

CREATE OR REPLACE VIEW malibu_rewards_ledger_with_disposition AS
SELECT
    prl.*,
    medf_block.disposition IS NOT NULL AS epoch_disposition_blocked,
    CASE medf_block.disposition
        WHEN 'hold' THEN 'held_epoch_disposition'
        WHEN 'exclude' THEN 'excluded_epoch_disposition'
        WHEN 'burn' THEN 'burned_or_retired_epoch_disposition'
        WHEN 'retire' THEN 'burned_or_retired_epoch_disposition'
        ELSE NULL
    END AS epoch_disposition_hold_reason
FROM provider_rewards_ledger prl
LEFT JOIN LATERAL (
    SELECT medf.disposition
      FROM malibu_epoch_disposition_facts medf
     WHERE (
           (medf.active = TRUE AND medf.disposition IN ('hold', 'exclude'))
           OR medf.disposition IN ('burn', 'retire')
       )
       AND (
           medf.ledger_id = prl.id
           OR (medf.subject_type = 'ledger_row' AND medf.subject_id = prl.id::TEXT)
           OR (
               medf.subject_type = 'useful_work_source'
               AND (medf.subject_id = prl.external_ref OR medf.external_ref = prl.external_ref)
           )
           OR (
               medf.subject_type = 'provider'
               AND medf.subject_id = prl.provider_id
           )
           OR (
               medf.subject_type IN ('wallet', 'cohort', 'duplicate_class', 'epoch')
               AND (
                   medf.ledger_id = prl.id
                   OR medf.external_ref = prl.external_ref
                   OR EXISTS (
                       SELECT 1
                         FROM malibu_epoch_disposition_subject_memberships mesm
                        WHERE mesm.disposition_id = medf.id
                          AND mesm.epoch_id = medf.epoch_id
                          AND mesm.policy_revision = medf.policy_revision
                          AND mesm.subject_type = medf.subject_type
                          AND mesm.subject_id = medf.subject_id
                          AND mesm.provider_id = prl.provider_id
                          AND (mesm.ledger_id = prl.id OR mesm.external_ref = prl.external_ref)
                   )
               )
           )
       )
     ORDER BY CASE medf.disposition
              WHEN 'burn' THEN 1
              WHEN 'retire' THEN 1
              WHEN 'exclude' THEN 2
              WHEN 'hold' THEN 3
              ELSE 4
          END,
          medf.id ASC
     LIMIT 1
) medf_block ON TRUE;

GRANT SELECT, INSERT ON malibu_epoch_disposition_facts TO rewards_writer;
GRANT USAGE, SELECT ON SEQUENCE malibu_epoch_disposition_facts_id_seq TO rewards_writer;
GRANT SELECT, INSERT ON malibu_epoch_disposition_subject_memberships TO rewards_writer;
GRANT USAGE, SELECT ON SEQUENCE malibu_epoch_disposition_subject_memberships_id_seq TO rewards_writer;
GRANT SELECT ON malibu_rewards_ledger_with_disposition TO rewards_writer;
