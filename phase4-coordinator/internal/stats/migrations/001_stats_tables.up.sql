-- SPEC-017 v0.1.8 §9.1 — rollup tables owned by SPEC-017.
-- All DDL here is idempotent (IF NOT EXISTS) so partial re-runs
-- cannot brick coordinator startup. Step 1 is creation only;
-- alter/drop migrations are out of scope per BUILD §F.1.
--
-- v0.1.7 removed earnings_work_bucket and earnings_rewards_bucket
-- from the leaderboard schema (§9.1 + §6.2). v0.1.8 has no further
-- column deltas on the §9.1 tables.

CREATE TABLE IF NOT EXISTS stats_overview_current (
    singleton                BOOLEAN PRIMARY KEY DEFAULT TRUE
                             CHECK (singleton = TRUE),
    generated_at             TIMESTAMPTZ NOT NULL,
    tokens_in                BIGINT NOT NULL,
    tokens_out               BIGINT NOT NULL,
    requests                 BIGINT NOT NULL,
    nodes_online             INT NOT NULL,
    nodes_hardware_attested  INT NOT NULL,
    bandwidth_gb_per_s       BIGINT NOT NULL,
    network_power_kw         DOUBLE PRECISION NOT NULL,
    network_utilization_pct  INT NOT NULL,
    gpu_cores_total          INT NOT NULL,
    cpu_cores_total          INT NOT NULL,
    unified_ram_gb_total     INT NOT NULL,
    models_serving           INT NOT NULL
);

CREATE TABLE IF NOT EXISTS stats_timeseries_rpm_30m (
    bucket_start             TIMESTAMPTZ PRIMARY KEY,
    requests                 BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS stats_timeseries_tpm_30m (
    bucket_start             TIMESTAMPTZ PRIMARY KEY,
    input_tokens             BIGINT NOT NULL,
    output_tokens            BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS stats_leaderboard_24h (
    provider_id              TEXT NOT NULL,
    pseudonym                TEXT NOT NULL,
    generated_at             TIMESTAMPTZ NOT NULL,
    rank_earnings            INT NOT NULL,
    rank_tokens              INT NOT NULL,
    rank_jobs                INT NOT NULL,
    earnings_usd             NUMERIC(18,2) NOT NULL DEFAULT 0,
    earnings_work_usd        NUMERIC(18,2) NOT NULL DEFAULT 0,
    earnings_rewards_usd     NUMERIC(18,2) NOT NULL DEFAULT 0,
    earnings_bucket          TEXT NOT NULL,
    tokens                   BIGINT NOT NULL DEFAULT 0,
    jobs                     BIGINT NOT NULL DEFAULT 0,
    first_seen_at            TIMESTAMPTZ,
    last_seen_at             TIMESTAMPTZ,
    PRIMARY KEY (provider_id)
);
CREATE INDEX IF NOT EXISTS stats_leaderboard_24h_rank_earnings_idx
    ON stats_leaderboard_24h (rank_earnings);
CREATE INDEX IF NOT EXISTS stats_leaderboard_24h_rank_tokens_idx
    ON stats_leaderboard_24h (rank_tokens);
CREATE INDEX IF NOT EXISTS stats_leaderboard_24h_rank_jobs_idx
    ON stats_leaderboard_24h (rank_jobs);

CREATE TABLE IF NOT EXISTS stats_leaderboard_7d (
    provider_id              TEXT NOT NULL,
    pseudonym                TEXT NOT NULL,
    generated_at             TIMESTAMPTZ NOT NULL,
    rank_earnings            INT NOT NULL,
    rank_tokens              INT NOT NULL,
    rank_jobs                INT NOT NULL,
    earnings_usd             NUMERIC(18,2) NOT NULL DEFAULT 0,
    earnings_work_usd        NUMERIC(18,2) NOT NULL DEFAULT 0,
    earnings_rewards_usd     NUMERIC(18,2) NOT NULL DEFAULT 0,
    earnings_bucket          TEXT NOT NULL,
    tokens                   BIGINT NOT NULL DEFAULT 0,
    jobs                     BIGINT NOT NULL DEFAULT 0,
    first_seen_at            TIMESTAMPTZ,
    last_seen_at             TIMESTAMPTZ,
    PRIMARY KEY (provider_id)
);
CREATE INDEX IF NOT EXISTS stats_leaderboard_7d_rank_earnings_idx
    ON stats_leaderboard_7d (rank_earnings);
CREATE INDEX IF NOT EXISTS stats_leaderboard_7d_rank_tokens_idx
    ON stats_leaderboard_7d (rank_tokens);
CREATE INDEX IF NOT EXISTS stats_leaderboard_7d_rank_jobs_idx
    ON stats_leaderboard_7d (rank_jobs);

CREATE TABLE IF NOT EXISTS stats_leaderboard_30d (
    provider_id              TEXT NOT NULL,
    pseudonym                TEXT NOT NULL,
    generated_at             TIMESTAMPTZ NOT NULL,
    rank_earnings            INT NOT NULL,
    rank_tokens              INT NOT NULL,
    rank_jobs                INT NOT NULL,
    earnings_usd             NUMERIC(18,2) NOT NULL DEFAULT 0,
    earnings_work_usd        NUMERIC(18,2) NOT NULL DEFAULT 0,
    earnings_rewards_usd     NUMERIC(18,2) NOT NULL DEFAULT 0,
    earnings_bucket          TEXT NOT NULL,
    tokens                   BIGINT NOT NULL DEFAULT 0,
    jobs                     BIGINT NOT NULL DEFAULT 0,
    first_seen_at            TIMESTAMPTZ,
    last_seen_at             TIMESTAMPTZ,
    PRIMARY KEY (provider_id)
);
CREATE INDEX IF NOT EXISTS stats_leaderboard_30d_rank_earnings_idx
    ON stats_leaderboard_30d (rank_earnings);
CREATE INDEX IF NOT EXISTS stats_leaderboard_30d_rank_tokens_idx
    ON stats_leaderboard_30d (rank_tokens);
CREATE INDEX IF NOT EXISTS stats_leaderboard_30d_rank_jobs_idx
    ON stats_leaderboard_30d (rank_jobs);

CREATE TABLE IF NOT EXISTS stats_leaderboard_all (
    provider_id              TEXT NOT NULL,
    pseudonym                TEXT NOT NULL,
    generated_at             TIMESTAMPTZ NOT NULL,
    rank_earnings            INT NOT NULL,
    rank_tokens              INT NOT NULL,
    rank_jobs                INT NOT NULL,
    earnings_usd             NUMERIC(18,2) NOT NULL DEFAULT 0,
    earnings_work_usd        NUMERIC(18,2) NOT NULL DEFAULT 0,
    earnings_rewards_usd     NUMERIC(18,2) NOT NULL DEFAULT 0,
    earnings_bucket          TEXT NOT NULL,
    tokens                   BIGINT NOT NULL DEFAULT 0,
    jobs                     BIGINT NOT NULL DEFAULT 0,
    first_seen_at            TIMESTAMPTZ,
    last_seen_at             TIMESTAMPTZ,
    PRIMARY KEY (provider_id)
);
CREATE INDEX IF NOT EXISTS stats_leaderboard_all_rank_earnings_idx
    ON stats_leaderboard_all (rank_earnings);
CREATE INDEX IF NOT EXISTS stats_leaderboard_all_rank_tokens_idx
    ON stats_leaderboard_all (rank_tokens);
CREATE INDEX IF NOT EXISTS stats_leaderboard_all_rank_jobs_idx
    ON stats_leaderboard_all (rank_jobs);

-- v0.1.7 §9.1 — component enum has 7 values: overview,
-- timeseries_rpm, timeseries_tpm, leaderboard_24h, leaderboard_7d,
-- leaderboard_30d, leaderboard_all. The handler-derived JSON
-- `status` field is computed at request time; there is no `status`
-- column here (BUILD §A.4 CRITICAL invariant).
CREATE TABLE IF NOT EXISTS stats_components_health (
    component                TEXT PRIMARY KEY
                             CHECK (component IN (
                                 'overview',
                                 'timeseries_rpm',
                                 'timeseries_tpm',
                                 'leaderboard_24h',
                                 'leaderboard_7d',
                                 'leaderboard_30d',
                                 'leaderboard_all'
                             )),
    generated_at             TIMESTAMPTZ NOT NULL,
    last_ok_at               TIMESTAMPTZ NOT NULL,
    last_error_at            TIMESTAMPTZ,
    last_error_message       TEXT
);

CREATE TABLE IF NOT EXISTS stats_late_events (
    id                       BIGSERIAL PRIMARY KEY,
    recorded_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    event_unix_ts            BIGINT NOT NULL,
    provider_id              TEXT NOT NULL,
    delta_usd                NUMERIC(18,2),
    delta_tokens             BIGINT,
    source_billing_row       TEXT
);

-- §9.1a — rewards-source skeleton. Operator-populated. v0.1 MAY
-- ship empty. The rollup (Step 2) reads this; the handler MUST
-- NOT (§7.2.1 deny list).
CREATE TABLE IF NOT EXISTS provider_rewards_ledger (
    id            BIGSERIAL PRIMARY KEY,
    provider_id   TEXT NOT NULL,
    unix_ts       BIGINT NOT NULL,
    amount_usd    NUMERIC(18,2) NOT NULL,
    reason        TEXT,
    external_ref  TEXT
);
CREATE INDEX IF NOT EXISTS provider_rewards_ledger_pid_ts_idx
    ON provider_rewards_ledger (provider_id, unix_ts);

-- §9.1a rewards_populated storage. Implementation choice (BUILD §A.8):
-- a small lookup table keyed by window. The rollup (Step 2) writes;
-- the handler (Step 3) reads. The handler MUST NOT compute this
-- synchronously from provider_rewards_ledger (the request-path role
-- does not have SELECT on the ledger — that is by design).
CREATE TABLE IF NOT EXISTS stats_rewards_populated (
    window             TEXT PRIMARY KEY
                       CHECK (window IN ('24h','7d','30d','all')),
    rewards_populated  BOOLEAN NOT NULL DEFAULT FALSE,
    generated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- §6.1 provider_visibility — SPEC-017-owned side table.
-- v0.1.7 added `blocked_from_partner_projection BOOLEAN NOT NULL
-- DEFAULT FALSE` as a column stub (v0.1 rollup MUST NOT consume it;
-- §11 Q11).
CREATE TABLE IF NOT EXISTS provider_visibility (
    provider_id                       TEXT PRIMARY KEY,
    mode                              TEXT NOT NULL DEFAULT 'bucketed'
                                      CHECK (mode IN ('bucketed','exact')),
    blocked_from_partner_projection   BOOLEAN NOT NULL DEFAULT FALSE,
    updated_at                        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- §6.5 audit table. BIGSERIAL backing sequence is consumed by the
-- provider_portal grant USAGE,SELECT ON SEQUENCE.
CREATE TABLE IF NOT EXISTS provider_visibility_audit (
    id           BIGSERIAL PRIMARY KEY,
    provider_id  TEXT NOT NULL,
    old_mode     TEXT NOT NULL,
    new_mode     TEXT NOT NULL,
    actor_kind   TEXT NOT NULL CHECK (actor_kind IN ('provider','operator')),
    actor_id     TEXT NOT NULL,
    changed_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    source_ip    INET,
    user_agent   TEXT
);
CREATE INDEX IF NOT EXISTS provider_visibility_audit_pid_changed_idx
    ON provider_visibility_audit (provider_id, changed_at);

-- §5.4.1 partner_keys. v0.1.8 removed `rate_limit_burst`.
CREATE TABLE IF NOT EXISTS partner_keys (
    id                BIGSERIAL PRIMARY KEY,
    label             TEXT NOT NULL,
    token_hash        BYTEA NOT NULL,
    token_hash_alg    TEXT NOT NULL DEFAULT 'sha256',
    prefix            TEXT NOT NULL,
    allowed_origins   TEXT[] NOT NULL DEFAULT '{}',
    rate_limit_rpm    INT NOT NULL DEFAULT 600,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by        TEXT NOT NULL,
    revoked_at        TIMESTAMPTZ,
    revoked_reason    TEXT,
    rotated_from_id   BIGINT REFERENCES partner_keys(id),
    last_used_at      TIMESTAMPTZ,
    UNIQUE (token_hash)
);
CREATE INDEX IF NOT EXISTS partner_keys_prefix_idx
    ON partner_keys (prefix);
