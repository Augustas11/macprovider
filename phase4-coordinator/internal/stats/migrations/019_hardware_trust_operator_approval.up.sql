-- Issue #582 PR1 — durable operator hardware-trust approval path.
--
-- Adds a dual-control approval workflow that lets two distinct operators
-- promote a provider's waiting_trust hardware-verification job by writing a
-- hardware_verification_trust root out-of-band from the
-- stats-inventory-sync YAML. The coordinator's provider_onboarding role
-- stays UNABLE to write hardware_verification_trust (anti-fraud boundary:
-- provider-submitted evidence must not auto-create trust roots). Instead,
-- SECURITY DEFINER functions owned by the NOLOGIN hardware_trust_definer
-- role perform the writes; EXECUTE is split across hardware_trust_requester
-- and hardware_trust_approver so no single operator key can both request and
-- approve.
--
-- Approval is bound to a real hardware_verification_jobs row parked in
-- status='waiting_trust': the request/approve functions derive the trust
-- tuple (provider_id, hardware_identity_hash, chip_normalized,
-- unified_memory_gb) from the job row rather than trusting a client-supplied
-- tuple. Both functions lock the bound job row FOR SHARE so approval serializes
-- against the verifier's FOR UPDATE SKIP LOCKED claim (verify.go): approval
-- either blocks until the verifier commits a terminal status (then aborts) or
-- holds the row first so the verifier skips it that pass. FOR SHARE requires an
-- UPDATE privilege on the locked table, so the definer is granted a LOCK-ONLY
-- column-level UPDATE(status) — it never actually UPDATEs the jobs table (only
-- the verifier does). A per-provider pg_advisory_xact_lock (taken FIRST, before
-- any row lock, in every function) serializes concurrent approvals and prevents
-- an approve/request lock-order deadlock; the idempotent ON CONFLICT trust
-- insert keeps the outcome correct. Approval re-checks the bound job is still
-- waiting_trust and that its decision_reason is still
-- 'missing_trusted_hardware_identity' (as the request also gates on) so a
-- chip-profile-only wait (or a job the verifier already finalized or re-flagged)
-- can never be approved via this hardware-identity trust root.
--
-- The source column distinguishes operator_api trust roots (created here) from
-- inventory roots (managed by stats-inventory-sync). It is also part of the
-- PRIMARY KEY (see the PK widening below): the operator approval path and the
-- inventory sync each own an INDEPENDENT row per (provider_id,
-- hardware_identity_hash) tuple. There is no cross-authority precedence — each
-- authority only ever writes, updates, or deletes its own row, and admission
-- (every trust-match EXISTS predicate) trusts EITHER source. The sync's
-- reconciling DELETE is scoped to source='inventory' and its ON CONFLICT upsert
-- targets the (provider_id, hardware_identity_hash, source='inventory') row, so
-- it can never touch an operator_api row; durable operator approvals survive
-- every timer run, and an inventory root survives an operator revoke.
--
-- New roles are created NOLOGIN. Pearl provisioning grants them LOGIN with a
-- password from the secret store before the coordinator's two new DSNs are
-- wired.
--
-- DEPLOY SEQUENCING (operator, required): widening the PRIMARY KEY below is
-- INCOMPATIBLE with the stats-inventory-sync binary shipped before issue #582,
-- which reconciles with a 2-column `ON CONFLICT (provider_id,
-- hardware_identity_hash)`. Once this migration flips the PK to 3 columns, that
-- 2-column ON CONFLICT no longer matches a unique constraint and the old
-- binary's reconciliation fails ("no unique or exclusion constraint matching the
-- ON CONFLICT specification"). The required order is: (1) stop and disable
-- stats-inventory-sync.timer / stats-inventory-sync.service (and let any
-- in-flight run drain) so no old-binary reconciliation can fire against the
-- migrated schema, (2) apply this migration, (3) install the new 3-column
-- stats-inventory-sync binary, (4) re-enable the timer.
-- dist/deploy-pearl-vps.sh performs this ENTIRE sequence automatically for the
-- standard deploy: it quiesces the sidecar, then applies this migration ITSELF
-- inside that quiesced window via the coordinator's embedded stats-migrate
-- (ahead of its onboarding migration preflight), then installs the new binary in
-- step 4 and re-enables the timer in step 9 — so operators no longer need to
-- pre-apply this migration by hand. A manual `coordinator stats-migrate` run
-- OUTSIDE that deploy must reproduce steps 1-4 in order by hand. Never leave the
-- old 2-column binary enabled while this 3-column PK is live.

ALTER TABLE hardware_verification_trust
    ADD COLUMN IF NOT EXISTS source TEXT NOT NULL DEFAULT 'inventory'
        CHECK (source IN ('inventory', 'operator_api'));

-- TERMINAL STRUCTURAL FIX (issue #582): widen the PRIMARY KEY from
-- (provider_id, hardware_identity_hash) to
-- (provider_id, hardware_identity_hash, source). Migration 008 created the
-- 2-column key, which forced the operator-approval and inventory-sync
-- authorities onto ONE shared row and required the fragile "ride-along"
-- reconciliation in approve_hardware_trust_approval that kept racing
-- stats-inventory-sync (the 4th recurrence of the dual-authority-over-one-row
-- conflict). Keying by source gives each authority its own row: approval always
-- writes only the operator_api row, the sync always writes only the inventory
-- row, and neither reads or clobbers the other. Existing rows already carry a
-- populated source (the ADD COLUMN above defaults 'inventory') and were unique
-- on the 2-column key, so they remain unique under the wider key and the swap is
-- a metadata-only rewrite. Postgres auto-names the CREATE TABLE primary key
-- <table>_pkey, so the dropped and re-added constraint share the name
-- hardware_verification_trust_pkey.
ALTER TABLE hardware_verification_trust
    DROP CONSTRAINT hardware_verification_trust_pkey;
ALTER TABLE hardware_verification_trust
    ADD PRIMARY KEY (provider_id, hardware_identity_hash, source);

-- FIX 1 (issue #582): the profile-promotion guard trigger (last defined by
-- migration 016) re-validates the backing hardware trust root with `now()`
-- (transaction_timestamp, frozen at transaction start). That is the SAME
-- frozen-clock bug as the verifier's in-transaction re-check: a revoke that sets
-- expires_at = clock_timestamp() AFTER the verifier's transaction began still
-- satisfies `t.expires_at > now()` (frozen), so the trigger would pass a
-- just-revoked root through and let verified := TRUE stick. Replace the guard
-- forward (migrations are apply-only; existing deploys already recorded 016) so
-- the trust-activity comparison uses clock_timestamp() and a mid-transaction
-- revocation is seen as inactive. Only the trust-activity `expires_at` predicate
-- changes; the evidence-age window is left on now() (a revoke never touches
-- generated_at, and the Go verifier already gates evidence staleness).
CREATE OR REPLACE FUNCTION provider_hardware_profiles_guard_verification()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF current_user = 'provider_onboarding' THEN
        IF TG_OP = 'INSERT' THEN
            NEW.verified := FALSE;
        ELSIF NEW.chip_normalized IS DISTINCT FROM OLD.chip_normalized
           OR NEW.unified_memory_gb IS DISTINCT FROM OLD.unified_memory_gb THEN
            NEW.verified := FALSE;
        ELSE
            NEW.verified := OLD.verified;
        END IF;

        RETURN NEW;
    END IF;

    IF current_user = 'stats_hardware_verifier' THEN
        IF TG_OP = 'UPDATE' AND NEW.last_reported_at < OLD.last_reported_at THEN
            RAISE EXCEPTION 'stats_hardware_verifier may not move hardware profile timestamps backward';
        END IF;

        IF NEW.verified IS DISTINCT FROM TRUE THEN
            RAISE EXCEPTION 'stats_hardware_verifier may only promote verified hardware profiles';
        END IF;

        IF NOT EXISTS (
            SELECT 1
              FROM hardware_verification_jobs j
              JOIN hardware_verification_trust t
                ON t.provider_id = j.provider_id
               AND t.hardware_identity_hash = j.evidence #>> '{hardware,hardware_identity_hash}'
               AND t.chip_normalized = j.chip_normalized
               AND t.unified_memory_gb = j.unified_memory_gb
               AND (t.expires_at IS NULL OR t.expires_at > clock_timestamp())
              JOIN chip_hardware_profiles ch
                ON ch.chip_normalized = j.chip_normalized
             WHERE j.provider_id = NEW.provider_id
               AND j.chip_normalized = NEW.chip_normalized
               AND j.unified_memory_gb = NEW.unified_memory_gb
               AND j.os_version = NEW.macos_version
               AND j.binary_version = NEW.app_version
               AND j.generated_at = NEW.last_reported_at
               AND j.generated_at >= now() - interval '7 days'
               AND j.status IN ('pending', 'waiting_trust')
               AND j.benchmark_count > 0
               AND j.max_sustained_tps > 0
               AND COALESCE(j.evidence #>> '{hardware,hardware_identity_hash}', '') <> ''
        ) THEN
            RAISE EXCEPTION 'stats_hardware_verifier promotion requires matching trusted hardware evidence';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION provider_hardware_profiles_guard_verification() FROM PUBLIC;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hardware_trust_definer') THEN
        CREATE ROLE hardware_trust_definer NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hardware_trust_requester') THEN
        CREATE ROLE hardware_trust_requester NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hardware_trust_approver') THEN
        CREATE ROLE hardware_trust_approver NOLOGIN;
    END IF;
    ALTER ROLE hardware_trust_definer NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
    ALTER ROLE hardware_trust_requester NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
    ALTER ROLE hardware_trust_approver NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
END
$$;

-- Dual-approval workflow. Empty until an operator requests a trust approval.
-- Each pending row is bound to a waiting_trust job and carries the trust tuple
-- derived from that job at request time.
CREATE TABLE IF NOT EXISTS hardware_trust_pending (
    pending_id             UUID PRIMARY KEY,
    job_id                 BIGINT NOT NULL,
    provider_id            TEXT NOT NULL,
    hardware_identity_hash TEXT NOT NULL,
    chip_normalized        TEXT NOT NULL,
    unified_memory_gb      INT NOT NULL CHECK (unified_memory_gb >= 0 AND unified_memory_gb <= 4096),
    requested_by           TEXT NOT NULL,
    requested_until        TIMESTAMPTZ NULL,
    reason                 TEXT NOT NULL,
    incident_id            TEXT NULL,
    approved_by            TEXT NULL,
    approved_at            TIMESTAMPTZ NULL,
    committed_at           TIMESTAMPTZ NULL,
    cancelled_at           TIMESTAMPTZ NULL,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (approved_by IS NULL OR approved_by <> requested_by)
);

CREATE INDEX IF NOT EXISTS idx_hardware_trust_pending_provider_id
    ON hardware_trust_pending(provider_id);

CREATE INDEX IF NOT EXISTS idx_hardware_trust_pending_open
    ON hardware_trust_pending(job_id)
    WHERE committed_at IS NULL AND cancelled_at IS NULL;

-- An open pending is one that is neither committed nor cancelled. An
-- expired-but-uncommitted row is auto-cancelled on the next request so it
-- never blocks a replacement (issue #582).
CREATE UNIQUE INDEX IF NOT EXISTS idx_hardware_trust_pending_open_incident
    ON hardware_trust_pending(provider_id, incident_id)
    WHERE incident_id IS NOT NULL AND committed_at IS NULL AND cancelled_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_hardware_trust_pending_open_identity
    ON hardware_trust_pending(provider_id, hardware_identity_hash)
    WHERE committed_at IS NULL AND cancelled_at IS NULL;

CREATE TABLE IF NOT EXISTS hardware_trust_grants (
    grant_id               UUID PRIMARY KEY,
    pending_id             UUID NULL UNIQUE REFERENCES hardware_trust_pending(pending_id),
    provider_id            TEXT NOT NULL,
    hardware_identity_hash TEXT NOT NULL,
    chip_normalized        TEXT NOT NULL,
    unified_memory_gb      INT NOT NULL,
    action                 TEXT NOT NULL DEFAULT 'grant' CHECK (action IN ('grant', 'revoke')),
    grant_source           TEXT NOT NULL DEFAULT 'operator' CHECK (grant_source IN ('operator')),
    requested_by           TEXT NOT NULL,
    approved_by            TEXT NOT NULL,
    requested_until        TIMESTAMPTZ NULL,
    reason                 TEXT NOT NULL,
    incident_id            TEXT NULL,
    granted_at             TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_hardware_trust_grants_provider_id
    ON hardware_trust_grants(provider_id, granted_at);

-- Only grant actions consume an incident_id; revoke actions are audit-only and
-- may repeat, so the incident uniqueness is scoped to action='grant'.
CREATE UNIQUE INDEX IF NOT EXISTS idx_hardware_trust_grants_incident
    ON hardware_trust_grants(provider_id, incident_id)
    WHERE incident_id IS NOT NULL AND action = 'grant';

-- FIX 1 (SQLSTATE 42702): the RETURNS TABLE output columns are PL/pgSQL
-- variables under the Postgres default plpgsql.variable_conflict=error. If any
-- output name collides with an unqualified selected column (e.g. an unqualified
-- provider_id in a SELECT ... INTO), the RETURN QUERY / SELECT raises 42702 and
-- every call fails. Output columns are therefore prefixed out_* so they can
-- never collide with a table column, and every column reference in the body is
-- table-qualified. The Go store (internal/onboarding/store_pg.go) scans these
-- functions' results positionally, so the out_* rename is contract-safe.
-- LIVE-POSTGRES SMOKE REQUIRED: this repo has no live PG, so a
-- request -> approve -> revoke round-trip against a real PostgreSQL must be run
-- out-of-band before promotion to confirm 42702 is gone end-to-end.
CREATE OR REPLACE FUNCTION request_hardware_trust_approval(
    p_pending_id UUID,
    p_job_id BIGINT,
    p_requested_by TEXT,
    p_requested_until TIMESTAMPTZ,
    p_reason TEXT,
    p_incident_id TEXT DEFAULT NULL
)
RETURNS TABLE (
    out_pending_id UUID,
    out_provider_id TEXT,
    out_hardware_identity_hash TEXT,
    out_chip_normalized TEXT,
    out_unified_memory_gb INT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
    -- FIX 6: request_time is sampled with clock_timestamp() AFTER the advisory
    -- and FOR SHARE lock waits below, NOT with now()/transaction_timestamp()
    -- (which freeze at transaction start). A long lock wait could otherwise let
    -- an already-expired requested_until, or an over-deadline stale pending,
    -- through against a stale start-of-transaction clock.
    request_time TIMESTAMPTZ;
    v_provider TEXT;
    job RECORD;
    v_incident TEXT;
BEGIN
    IF p_pending_id IS NULL THEN
        RAISE EXCEPTION 'pending_id is required';
    END IF;
    IF p_job_id IS NULL OR p_job_id <= 0 THEN
        RAISE EXCEPTION 'job_id is required';
    END IF;
    IF p_requested_by !~ '^operator:[^[:space:]]+$' THEN
        RAISE EXCEPTION 'requested_by must use operator:<admin_id>';
    END IF;
    IF NULLIF(BTRIM(p_reason), '') IS NULL THEN
        RAISE EXCEPTION 'reason is required';
    END IF;

    -- Canonical lock order (issue #582 FIX 5): pg_advisory_xact_lock(provider)
    -- FIRST, then row locks. Read the provider WITHOUT a row lock so the advisory
    -- lock precedes the FOR SHARE job read below and matches
    -- approve_hardware_trust_approval; otherwise a concurrent approve (advisory
    -- then row locks) and request (row lock then advisory) could deadlock.
    SELECT j.provider_id INTO v_provider
      FROM hardware_verification_jobs j
     WHERE j.id = p_job_id
       AND j.status = 'waiting_trust';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'job not waiting_trust';
    END IF;

    PERFORM pg_advisory_xact_lock(582026, hashtext(v_provider));

    -- Bind to the waiting_trust job and derive the trust tuple, locking the job
    -- row FOR SHARE so this request serializes against the verifier's
    -- FOR UPDATE SKIP LOCKED claim (issue #582 FIX 1): if the verifier holds the
    -- row we block until it commits, then re-observe status='waiting_trust' below
    -- and abort if it finalized the job; if we hold the row first the verifier
    -- skips this job for that pass. FOR SHARE is permitted by the LOCK-ONLY
    -- column-level UPDATE(status) grant on hardware_verification_jobs — the
    -- function never actually UPDATEs the jobs table.
    SELECT j.provider_id AS provider_id,
           j.chip_normalized AS chip_normalized,
           j.unified_memory_gb AS unified_memory_gb,
           j.decision_reason AS decision_reason,
           NULLIF(BTRIM(COALESCE(j.evidence #>> '{hardware,hardware_identity_hash}', '')), '') AS hardware_identity_hash
      INTO job
      FROM hardware_verification_jobs j
     WHERE j.id = p_job_id
       AND j.status = 'waiting_trust'
     FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'job not waiting_trust';
    END IF;

    -- FIX 6: re-sample the wall clock AFTER the advisory + FOR SHARE lock waits.
    -- clock_timestamp() (unlike now()/transaction_timestamp()) advances during
    -- the transaction, so the expiry checks and stale-cleanup below evaluate
    -- against real time at this post-wait point rather than the frozen
    -- start-of-transaction time.
    request_time := clock_timestamp();
    IF p_requested_until IS NOT NULL AND p_requested_until <= request_time THEN
        RAISE EXCEPTION 'requested_until must be in the future';
    END IF;

    IF job.hardware_identity_hash IS NULL THEN
        RAISE EXCEPTION 'job evidence missing hardware_identity_hash';
    END IF;

    -- waiting_trust covers both missing_trusted_hardware_identity and
    -- missing_trusted_chip_profile; a hardware-identity trust root only unblocks
    -- the former. Reject the latter (or any other reason) with an actionable
    -- error instead of committing a pending that never promotes. The stored
    -- decision_reason is version-prefixed
    -- (e.g. 'hardware-verifier.v2:missing_trusted_hardware_identity'), so compare
    -- the bare reason after the last ':'.
    IF regexp_replace(COALESCE(job.decision_reason, ''), '^.*:', '') IS DISTINCT FROM 'missing_trusted_hardware_identity' THEN
        RAISE EXCEPTION 'job not approvable via hardware trust: %', COALESCE(job.decision_reason, '');
    END IF;

    v_incident := NULLIF(BTRIM(COALESCE(p_incident_id, '')), '');
    IF v_incident IS NOT NULL AND EXISTS (
        SELECT 1 FROM hardware_trust_grants g
         WHERE g.provider_id = job.provider_id
           AND g.action = 'grant'
           AND g.incident_id = v_incident
    ) THEN
        RAISE EXCEPTION 'incident_id already used';
    END IF;

    -- Reclaim stale open pendings so a stale row never permanently blocks a fresh
    -- request. The open-uniqueness indexes span (provider_id,
    -- hardware_identity_hash) and (provider_id, incident_id), so an expired
    -- pending from a DIFFERENT older job — or an abandoned non-expiring pending —
    -- must be cancellable across those same domains, not just the incoming
    -- job_id. Staleness = past its requested_until, OR (for non-expiring /
    -- abandoned rows) older than the fixed 7-day approval deadline. A still-active
    -- recent pending is left intact so the unique index correctly rejects the
    -- duplicate (issue #582).
    UPDATE hardware_trust_pending
       SET cancelled_at = request_time
     WHERE hardware_trust_pending.committed_at IS NULL
       AND hardware_trust_pending.cancelled_at IS NULL
       AND (
             (hardware_trust_pending.provider_id = job.provider_id
              AND hardware_trust_pending.hardware_identity_hash = job.hardware_identity_hash)
          OR (v_incident IS NOT NULL
              AND hardware_trust_pending.provider_id = job.provider_id
              AND hardware_trust_pending.incident_id = v_incident)
          OR hardware_trust_pending.job_id = p_job_id
       )
       AND (
             (hardware_trust_pending.requested_until IS NOT NULL
              AND hardware_trust_pending.requested_until <= request_time)
          OR hardware_trust_pending.created_at < request_time - interval '7 days'
       );

    INSERT INTO hardware_trust_pending (
        pending_id, job_id, provider_id, hardware_identity_hash, chip_normalized,
        unified_memory_gb, requested_by, requested_until, reason, incident_id
    ) VALUES (
        p_pending_id,
        p_job_id,
        job.provider_id,
        job.hardware_identity_hash,
        job.chip_normalized,
        job.unified_memory_gb,
        BTRIM(p_requested_by),
        p_requested_until,
        BTRIM(p_reason),
        v_incident
    );

    RETURN QUERY SELECT
        p_pending_id,
        job.provider_id,
        job.hardware_identity_hash,
        job.chip_normalized,
        job.unified_memory_gb;
END;
$$;

CREATE OR REPLACE FUNCTION approve_hardware_trust_approval(
    p_pending_id UUID,
    p_approved_by TEXT
)
RETURNS TABLE (
    out_provider_id TEXT,
    out_hardware_identity_hash TEXT,
    out_chip_normalized TEXT,
    out_unified_memory_gb INT,
    out_requested_until TIMESTAMPTZ,
    out_reason TEXT,
    out_incident_id TEXT,
    -- Terminal structural fix (issue #582): approval ALWAYS writes the operator_api
    -- trust row for the job tuple and never rides an inventory row, so out_source is
    -- always 'operator_api' and out_effective_expires_at is always the operator_api
    -- row's expiry (pending.requested_until). The columns are retained (the Go store
    -- scans them positionally) so a client learns the source/expiry and knows the
    -- approval is operator-revocable.
    out_source TEXT,
    out_effective_expires_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
    v_provider TEXT;
    pending hardware_trust_pending%ROWTYPE;
    job RECORD;
    -- FIX 2 (issue #582): sampled with clock_timestamp() AFTER the advisory lock,
    -- the pending FOR UPDATE, AND the job FOR SHARE lock waits below — not with a
    -- frozen start-of-transaction now(). Every time-sensitive check (the 7-day
    -- abandonment deadline, requested_until, the hardcoded evidence-age gate) and
    -- the trust root's effective trusted_at/expires_at time then reflect real time
    -- at the post-wait point rather than the frozen transaction start.
    approval_time TIMESTAMPTZ;
    -- FIX 4 (round-8): OLDEST benchmark timestamp in the evidence JSON. The verifier
    -- rejects stale_benchmark on per-benchmark timestamps, so a job with a fresh
    -- top-level generated_at but an older benchmark would pass approval then be
    -- rejected; gate it here on the same evidence-age boundary.
    v_oldest_benchmark TIMESTAMPTZ;
BEGIN
    IF p_approved_by !~ '^operator:[^[:space:]]+$' THEN
        RAISE EXCEPTION 'approved_by must use operator:<admin_id>';
    END IF;

    -- Canonical lock order (issue #582 FIX 5): pg_advisory_xact_lock(provider)
    -- FIRST, then row locks. Read the provider WITHOUT a row lock so the advisory
    -- lock precedes the pending FOR UPDATE and the job FOR SHARE below; this
    -- matches request_hardware_trust_approval and prevents an approve/request
    -- deadlock on the same provider. The column is table-qualified so it can
    -- never bind to the out_provider_id output variable (FIX 1, SQLSTATE 42702).
    SELECT hardware_trust_pending.provider_id INTO v_provider
      FROM hardware_trust_pending
     WHERE hardware_trust_pending.pending_id = p_pending_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pending approval not found';
    END IF;

    PERFORM pg_advisory_xact_lock(582026, hashtext(v_provider));

    SELECT * INTO pending
      FROM hardware_trust_pending
     WHERE hardware_trust_pending.pending_id = p_pending_id
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pending approval not found';
    END IF;

    -- Clock-independent gates first (issue #582 FIX 2): committed/cancelled/
    -- dual-control do not depend on wall time, so evaluate them before the job
    -- FOR SHARE lock wait; the time-sensitive checks are deferred until AFTER that
    -- lock is held (below), so a long wait cannot let a since-expired pending or
    -- over-age job commit against a frozen clock.
    IF pending.committed_at IS NOT NULL THEN
        RAISE EXCEPTION 'pending approval already committed';
    END IF;
    IF pending.cancelled_at IS NOT NULL THEN
        RAISE EXCEPTION 'pending approval cancelled';
    END IF;
    IF pending.requested_by = BTRIM(p_approved_by) THEN
        RAISE EXCEPTION 'dual_control_required';
    END IF;

    -- Re-check the bound job is STILL waiting_trust and its derived tuple still
    -- matches what was captured at request time, locking the job row FOR SHARE so
    -- this approval serializes against the verifier's FOR UPDATE SKIP LOCKED
    -- claim (issue #582 FIX 1). If the verifier committed a terminal status the
    -- status='waiting_trust' predicate returns NOT FOUND and we abort. FOR SHARE
    -- is permitted by the LOCK-ONLY column-level UPDATE(status) grant; the
    -- function never UPDATEs the jobs table. generated_at is read for the FIX 5
    -- evidence-age gate below.
    SELECT j.provider_id AS provider_id,
           j.chip_normalized AS chip_normalized,
           j.unified_memory_gb AS unified_memory_gb,
           j.decision_reason AS decision_reason,
           j.generated_at AS generated_at,
           j.evidence AS evidence,
           NULLIF(BTRIM(COALESCE(j.evidence #>> '{hardware,hardware_identity_hash}', '')), '') AS hardware_identity_hash
      INTO job
      FROM hardware_verification_jobs j
     WHERE j.id = pending.job_id
       AND j.status = 'waiting_trust'
     FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'job no longer waiting_trust';
    END IF;
    IF job.hardware_identity_hash IS NULL
       OR job.provider_id IS DISTINCT FROM pending.provider_id
       OR job.hardware_identity_hash IS DISTINCT FROM pending.hardware_identity_hash
       OR job.chip_normalized IS DISTINCT FROM pending.chip_normalized
       OR job.unified_memory_gb IS DISTINCT FROM pending.unified_memory_gb THEN
        RAISE EXCEPTION 'job tuple changed since request';
    END IF;
    -- Re-assert the decision_reason still gates on missing_trusted_hardware_identity
    -- (issue #582 FIX 7): a still-waiting_trust job whose reason flipped to
    -- missing_trusted_chip_profile during the dual-control window must not be
    -- approved via a hardware-identity trust root that would never unblock it.
    IF regexp_replace(COALESCE(job.decision_reason, ''), '^.*:', '') IS DISTINCT FROM 'missing_trusted_hardware_identity' THEN
        RAISE EXCEPTION 'job not approvable via hardware trust: %', COALESCE(job.decision_reason, '');
    END IF;

    -- FIX 3 (round-8, issue #582): waiting_trust can mean
    -- missing_trusted_hardware_identity OR missing_trusted_chip_profile, and the
    -- verifier re-checks BOTH on promotion. A job parked for the identity reason can
    -- still lack a chip profile if that profile was removed after the job was last
    -- evaluated (or the job was missing both and only the identity reason was
    -- stored). Approving on the identity reason would then commit a trust root the
    -- verifier immediately re-parks for missing_trusted_chip_profile. Fail closed
    -- with a distinct error the caller maps to 409 unless a chip profile for the
    -- job's chip exists. Clock-independent, so gate here before sampling the wall
    -- clock below.
    IF NOT EXISTS (
        SELECT 1 FROM chip_hardware_profiles ch
         WHERE ch.chip_normalized = job.chip_normalized
    ) THEN
        RAISE EXCEPTION 'hardware_trust_chip_profile_missing';
    END IF;

    -- FIX 2 (issue #582): sample the wall clock AFTER the advisory lock, the
    -- pending FOR UPDATE, AND the job FOR SHARE are all held, then run every
    -- expiry/deadline comparison against it. clock_timestamp() advances during
    -- the transaction (unlike now()/transaction_timestamp(), frozen at start), so
    -- a long lock wait cannot let a since-expired pending, an elapsed
    -- requested_until, or over-age evidence through against a stale clock. The
    -- trust root's trusted_at/expires_at effective time (written below) uses the
    -- same post-wait sample.
    approval_time := clock_timestamp();
    -- Enforce the fixed 7-day abandonment deadline AT approval (issue #582 FIX 6).
    -- The request-side cleanup only cancels stale pendings when a later request
    -- happens to touch the same domain, so a non-expiring (requested_until IS
    -- NULL) pending would otherwise stay approvable forever. Fail closed: RAISE a
    -- distinct error the caller maps to 410 Gone. The operator re-requests, which
    -- auto-cancels this stale pending via request's stale-cleanup UPDATE (the
    -- cancel is intentionally NOT attempted here — a RAISE rolls back the txn, so
    -- the deadline is enforced by refusing to approve rather than by mutating the
    -- pending in this aborted transaction).
    IF pending.created_at < approval_time - interval '7 days' THEN
        RAISE EXCEPTION 'hardware_trust_pending_expired';
    END IF;
    IF pending.requested_until IS NOT NULL AND pending.requested_until <= approval_time THEN
        RAISE EXCEPTION 'requested_until must be in the future';
    END IF;
    -- FIX 5 (issue #582): reject a job whose evidence has aged past the verifier's
    -- limit — e.g. during a verifier outage. Committing it would write a trust root
    -- the verifier immediately rejects as stale_job on its next pass, forcing a
    -- resubmit. Fail closed with a distinct error the caller maps to 409
    -- resubmit-required so the two gates share one evidence-age boundary.
    --
    -- The '7 days' window is HARDCODED here (not a caller parameter) so it is a
    -- definer-owned invariant that cannot be bypassed with a NULL/0/huge argument.
    -- Keep it in sync with hardwareverify.MaxEvidenceAgeDays / maxEvidenceAge in
    -- internal/stats/hardwareverify/verify.go (currently 7); if that constant
    -- changes, change this interval to match.
    IF job.generated_at < approval_time - interval '7 days' THEN
        RAISE EXCEPTION 'hardware_trust_job_evidence_stale';
    END IF;
    -- FIX 6 (round-6 regression fix): approval can commit seconds before
    -- requested_until or the 7-day evidence boundary, while the verifier timer runs
    -- up to ~90s later — so a job that "succeeds" here would re-park or reject
    -- almost immediately. Reject up front (distinct error → 409) unless the
    -- effective trust root retains a small (5-minute) promotion runway: the
    -- requested expiry is at least 5 minutes out, AND the evidence is at least 5
    -- minutes short of the 7-day staleness cutoff. The operator lengthens
    -- requested_until or has the provider resubmit fresh evidence, then re-requests.
    IF (pending.requested_until IS NOT NULL
        AND pending.requested_until < approval_time + interval '5 minutes')
       OR job.generated_at < approval_time - interval '7 days' + interval '5 minutes' THEN
        RAISE EXCEPTION 'hardware_trust_promotion_runway_insufficient: extend requested_until or resubmit fresh evidence';
    END IF;
    -- FIX 4 (round-8, issue #582): the verifier's stale_benchmark check gates on
    -- per-benchmark timestamps (evidence->'benchmarks'[].generated_at), not just the
    -- top-level generated_at. A job with a fresh generated_at but an older benchmark
    -- would pass the generated_at gate above, get approved, then be rejected by the
    -- verifier as stale_benchmark on its next pass. Compute the OLDEST benchmark
    -- timestamp and apply the SAME 7-day-minus-5-minute-runway staleness boundary,
    -- matching hardwareverify.maxEvidenceAge on evidence.Benchmarks[].GeneratedAt.
    -- Any job that reached waiting_trust with missing_trusted_hardware_identity has
    -- already passed the verifier's full benchmark validation, so the array is
    -- present with parseable RFC3339 generated_at values; a NULL result (empty/absent
    -- array) fails closed. RAISE the same distinct error the caller maps to 409.
    SELECT min((b->>'generated_at')::timestamptz)
      INTO v_oldest_benchmark
      FROM jsonb_array_elements(COALESCE(job.evidence->'benchmarks', '[]'::jsonb)) b;
    IF v_oldest_benchmark IS NULL
       OR v_oldest_benchmark < approval_time - interval '7 days' + interval '5 minutes' THEN
        RAISE EXCEPTION 'hardware_trust_job_evidence_stale';
    END IF;

    IF pending.incident_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM hardware_trust_grants g
         WHERE g.provider_id = pending.provider_id
           AND g.action = 'grant'
           AND g.incident_id = pending.incident_id
    ) THEN
        RAISE EXCEPTION 'incident_id already used';
    END IF;

    UPDATE hardware_trust_pending
       SET approved_by = BTRIM(p_approved_by),
           approved_at = approval_time,
           committed_at = approval_time
     WHERE hardware_trust_pending.pending_id = p_pending_id;

    -- TERMINAL STRUCTURAL FIX (issue #582): UNCONDITIONALLY upsert the operator_api
    -- trust row for the EXACT job tuple. Because the PRIMARY KEY now includes source
    -- (provider_id, hardware_identity_hash, source), this INSERT ... ON CONFLICT
    -- (provider_id, hardware_identity_hash, source) DO UPDATE targets ONLY the
    -- operator_api row — it never reads, rides, or clobbers an inventory row. An
    -- active operator_api root for the tuple is therefore guaranteed to exist
    -- afterward (fresh insert, or idempotent refresh of an existing operator_api
    -- row), so the verifier promotes the job. An inventory root, if any, coexists as
    -- its own independent row and is left untouched; admission trusts EITHER source.
    -- This removes the earlier "ride-along" probe/branch and its race with
    -- stats-inventory-sync entirely: the approval is always operator-owned and
    -- operator-revocable.
    INSERT INTO hardware_verification_trust (
        provider_id, hardware_identity_hash, chip_normalized, unified_memory_gb,
        trusted_by, trusted_at, expires_at, notes, source
    ) VALUES (
        pending.provider_id,
        pending.hardware_identity_hash,
        pending.chip_normalized,
        pending.unified_memory_gb,
        BTRIM(p_approved_by),
        approval_time,
        pending.requested_until,
        pending.reason,
        'operator_api'
    )
    ON CONFLICT (provider_id, hardware_identity_hash, source) DO UPDATE
       SET chip_normalized = EXCLUDED.chip_normalized,
           unified_memory_gb = EXCLUDED.unified_memory_gb,
           trusted_by = EXCLUDED.trusted_by,
           trusted_at = EXCLUDED.trusted_at,
           expires_at = EXCLUDED.expires_at,
           notes = EXCLUDED.notes;

    INSERT INTO hardware_trust_grants (
        grant_id, pending_id, provider_id, hardware_identity_hash, chip_normalized,
        unified_memory_gb, action, requested_by, approved_by, requested_until, reason,
        incident_id, granted_at
    ) VALUES (
        pending.pending_id,
        pending.pending_id,
        pending.provider_id,
        pending.hardware_identity_hash,
        pending.chip_normalized,
        pending.unified_memory_gb,
        'grant',
        pending.requested_by,
        BTRIM(p_approved_by),
        pending.requested_until,
        pending.reason,
        pending.incident_id,
        approval_time
    );

    -- out_source is always 'operator_api' and out_effective_expires_at is always the
    -- operator_api row's expiry (pending.requested_until): approval writes only that
    -- row and it is always operator-revocable.
    RETURN QUERY SELECT
        pending.provider_id,
        pending.hardware_identity_hash,
        pending.chip_normalized,
        pending.unified_memory_gb,
        pending.requested_until,
        pending.reason,
        pending.incident_id,
        'operator_api'::text,
        pending.requested_until;
END;
$$;

-- Revoke an operator-granted trust root with an audit trail. Trust-reducing, so
-- a single operator actor is acceptable (fail-safe), but the actor MUST be
-- operator-authenticated and the action is ledgered in hardware_trust_grants
-- with action='revoke'. EXECUTE is granted to hardware_trust_approver.
CREATE OR REPLACE FUNCTION revoke_hardware_trust_approval(
    p_grant_id UUID,
    p_provider_id TEXT,
    p_hardware_identity_hash TEXT,
    p_revoked_by TEXT,
    p_reason TEXT
)
RETURNS TABLE (
    out_provider_id TEXT,
    out_hardware_identity_hash TEXT,
    out_chip_normalized TEXT,
    out_unified_memory_gb INT,
    -- FIX 1 (round-12, issue #582): TRUE when NO active trust root of ANY source
    -- remains for the (provider_id, hardware_identity_hash, chip_normalized,
    -- unified_memory_gb) tuple after this revoke expired the operator_api root —
    -- i.e. the provider is now FULLY untrusted. The revoke handler evicts the live
    -- session only when this is TRUE; a still-active inventory root leaves the
    -- session connected.
    out_now_untrusted BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
    -- FIX 3 (issue #582): sampled with clock_timestamp() AFTER the advisory lock
    -- is acquired (below), NOT with NOW()/transaction_timestamp() (frozen at
    -- transaction start). A root that expired DURING the advisory-lock wait must
    -- be seen as already-inactive for the expiry set and the demotion active-trust
    -- proof, so the revoke does not treat it as still active against a stale clock.
    revoke_time TIMESTAMPTZ;
    revoked RECORD;
    -- FIX 1 (round-12, issue #582): whether the tuple has any remaining active
    -- trust root of any source after the operator_api root was expired above.
    now_untrusted BOOLEAN;
BEGIN
    IF p_grant_id IS NULL THEN
        RAISE EXCEPTION 'grant_id is required';
    END IF;
    IF NULLIF(BTRIM(p_provider_id), '') IS NULL THEN
        RAISE EXCEPTION 'provider_id is required';
    END IF;
    IF NULLIF(BTRIM(p_hardware_identity_hash), '') IS NULL THEN
        RAISE EXCEPTION 'hardware_identity_hash is required';
    END IF;
    IF p_revoked_by !~ '^operator:[^[:space:]]+$' THEN
        RAISE EXCEPTION 'revoked_by must use operator:<admin_id>';
    END IF;
    IF NULLIF(BTRIM(p_reason), '') IS NULL THEN
        RAISE EXCEPTION 'reason is required';
    END IF;

    PERFORM pg_advisory_xact_lock(582026, hashtext(BTRIM(p_provider_id)));

    -- FIX 3 (issue #582): sample the wall clock AFTER the advisory lock wait so
    -- the expiry set and the demotion active-trust proof below evaluate against
    -- real time at this post-wait point, not the frozen start-of-transaction time.
    revoke_time := clock_timestamp();

    UPDATE hardware_verification_trust t
       SET expires_at = revoke_time
     WHERE t.provider_id = BTRIM(p_provider_id)
       AND t.hardware_identity_hash = BTRIM(p_hardware_identity_hash)
       AND t.source = 'operator_api'
       AND (t.expires_at IS NULL OR t.expires_at > revoke_time)
    RETURNING t.chip_normalized, t.unified_memory_gb
        INTO revoked;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'active operator_api trust root not found';
    END IF;

    INSERT INTO hardware_trust_grants (
        grant_id, pending_id, provider_id, hardware_identity_hash, chip_normalized,
        unified_memory_gb, action, requested_by, approved_by, requested_until, reason,
        incident_id, granted_at
    ) VALUES (
        p_grant_id,
        NULL,
        BTRIM(p_provider_id),
        BTRIM(p_hardware_identity_hash),
        revoked.chip_normalized,
        revoked.unified_memory_gb,
        'revoke',
        BTRIM(p_revoked_by),
        BTRIM(p_revoked_by),
        NULL,
        BTRIM(p_reason),
        NULL,
        revoke_time
    );

    -- Atomically demote the provider's verified profile in the SAME transaction
    -- (issue #582 FIX 4). Without this, consumers and the profile's verified bit
    -- keep trusting the just-revoked hardware until the next stats-inventory-sync
    -- demotion sweep — indefinitely if that sync fails (fail-open). The condition
    -- mirrors applyTrustDemotions (source <> 'operator', hash-precise active-trust
    -- proof) scoped to this provider; the trust root we just expired above no
    -- longer satisfies (t.expires_at > now()), so a profile backed only by it is
    -- demoted immediately. Running as hardware_trust_definer (not
    -- provider_onboarding) the verification guard trigger passes NEW through, so
    -- verified := FALSE sticks.
    UPDATE provider_hardware_profiles ph
       SET verified = FALSE
     WHERE ph.provider_id = BTRIM(p_provider_id)
       AND ph.verified = TRUE
       AND ph.source <> 'operator'
       AND NOT EXISTS (
           SELECT 1
             FROM hardware_verification_jobs j
             JOIN hardware_verification_trust t
               ON t.provider_id = j.provider_id
              AND t.hardware_identity_hash = j.evidence #>> '{hardware,hardware_identity_hash}'
              AND t.chip_normalized = j.chip_normalized
              AND t.unified_memory_gb = j.unified_memory_gb
              AND (t.expires_at IS NULL OR t.expires_at > revoke_time)
            WHERE j.status = 'verified'
              AND j.provider_id = ph.provider_id
              AND j.chip_normalized = ph.chip_normalized
              AND j.unified_memory_gb = ph.unified_memory_gb
              AND j.os_version = ph.macos_version
              AND j.binary_version = ph.app_version
              AND j.generated_at = ph.last_reported_at
       );

    -- FIX 1 (round-12, issue #582): the provider is now FULLY untrusted for this
    -- hardware tuple iff NO active trust root of ANY source (inventory OR
    -- operator_api) remains for it after the operator_api root was expired above.
    -- Evaluated against revoke_time (the post-lock clock, matching the expiry set
    -- and demotion proof) so a root that lapsed during the lock wait counts as
    -- inactive. When an inventory root is still active this is FALSE and the revoke
    -- handler leaves the (inventory-trusted) live session connected rather than
    -- needlessly draining it; only the sole-operator_api-root case returns TRUE and
    -- evicts the session.
    now_untrusted := NOT EXISTS (
        SELECT 1
          FROM hardware_verification_trust t
         WHERE t.provider_id = BTRIM(p_provider_id)
           AND t.hardware_identity_hash = BTRIM(p_hardware_identity_hash)
           AND t.chip_normalized = revoked.chip_normalized
           AND t.unified_memory_gb = revoked.unified_memory_gb
           AND (t.expires_at IS NULL OR t.expires_at > revoke_time)
    );

    RETURN QUERY SELECT
        BTRIM(p_provider_id),
        BTRIM(p_hardware_identity_hash),
        revoked.chip_normalized,
        revoked.unified_memory_gb,
        now_untrusted;
END;
$$;

GRANT USAGE, CREATE ON SCHEMA public TO hardware_trust_definer;
GRANT USAGE ON SCHEMA public TO hardware_trust_requester;
GRANT USAGE ON SCHEMA public TO hardware_trust_approver;

-- provider_onboarding needs the non-normalized chip display column to list
-- waiting_trust jobs; decision_reason SELECT is already granted by migration 015
-- and must survive this migration's rollback.
GRANT SELECT (chip) ON hardware_verification_jobs TO provider_onboarding;

-- FIX 4 (round-6 root-cause fix, issue #582): the autotune admission gate
-- (internal/autotune/evidence_pg.go LatestVerified) now re-checks live trust by
-- joining hardware_verification_trust, so the denormalized
-- provider_hardware_profiles.verified bit is no longer security-load-bearing: a
-- revoked/expired root fails admission immediately even while the bit is briefly
-- stale. That read-only join requires provider_onboarding to SELECT the trust
-- table. Round-3 removed this grant as unnecessary; the admission re-check
-- re-introduces the need. This is a READ-ONLY grant — provider_onboarding still
-- has NO INSERT/UPDATE/DELETE on hardware_verification_trust and NO EXECUTE on
-- the SECURITY DEFINER trust functions, so the anti-fraud write boundary
-- (provider-submitted evidence must never auto-create trust roots) is preserved.
GRANT SELECT ON hardware_verification_trust TO provider_onboarding;

-- The definer role reads waiting_trust jobs to derive the trust tuple and gate
-- approval on decision_reason inside the SECURITY DEFINER functions; it never
-- gains a LOGIN. os_version/binary_version/generated_at are read by the FIX 4
-- revoke-time demotion's verified-job proof (mirrors applyTrustDemotions).
GRANT SELECT (id, provider_id, status, chip_normalized, unified_memory_gb, os_version, binary_version, generated_at, evidence, decision_reason) ON hardware_verification_jobs TO hardware_trust_definer;

-- FIX 3 (round-8, issue #582): approve_hardware_trust_approval re-checks that a
-- chip_hardware_profiles row exists for the job's chip before committing, so the
-- verifier cannot re-park an approved job for missing_trusted_chip_profile. The
-- definer needs SELECT on the normalized chip column to run that EXISTS probe.
GRANT SELECT (chip_normalized) ON chip_hardware_profiles TO hardware_trust_definer;

-- LOCK-ONLY column-level UPDATE(status) (issue #582 FIX 1): Postgres requires an
-- UPDATE privilege on a locked table for FOR SHARE row locks. The request/approve
-- functions take FOR SHARE on the bound job row to serialize against the
-- verifier's FOR UPDATE SKIP LOCKED claim; they NEVER actually UPDATE
-- hardware_verification_jobs (only stats_hardware_verifier does). This grant
-- exists solely to satisfy the row-lock privilege check.
GRANT UPDATE (status) ON hardware_verification_jobs TO hardware_trust_definer;

-- FIX 4: revoke_hardware_trust_approval flips the provider's verified bit in the
-- same transaction as the trust-root expiry, so the definer needs to read the
-- profile capacity tuple and write the verified column. Column-scoped for least
-- privilege; the verification guard trigger passes definer writes through
-- unchanged (only provider_onboarding is force-unverified).
GRANT SELECT (provider_id, chip_normalized, unified_memory_gb, macos_version, app_version, last_reported_at, source, verified) ON provider_hardware_profiles TO hardware_trust_definer;
GRANT UPDATE (verified) ON provider_hardware_profiles TO hardware_trust_definer;

-- Only the definer role (via the SECURITY DEFINER functions) writes the
-- workflow tables and the trust root.
GRANT SELECT, INSERT, UPDATE ON hardware_trust_pending TO hardware_trust_definer;
GRANT SELECT, INSERT ON hardware_trust_grants TO hardware_trust_definer;
GRANT SELECT, INSERT, UPDATE ON hardware_verification_trust TO hardware_trust_definer;

REVOKE ALL ON hardware_trust_pending FROM hardware_trust_requester, hardware_trust_approver;
REVOKE ALL ON hardware_trust_grants FROM hardware_trust_requester, hardware_trust_approver;
REVOKE ALL ON hardware_verification_trust FROM hardware_trust_requester, hardware_trust_approver;

REVOKE ALL ON hardware_trust_pending FROM provider_onboarding, PUBLIC;
REVOKE ALL ON hardware_trust_grants FROM provider_onboarding, PUBLIC;
REVOKE ALL ON FUNCTION request_hardware_trust_approval(UUID, BIGINT, TEXT, TIMESTAMPTZ, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION approve_hardware_trust_approval(UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION revoke_hardware_trust_approval(UUID, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION request_hardware_trust_approval(UUID, BIGINT, TEXT, TIMESTAMPTZ, TEXT, TEXT) FROM provider_onboarding;
REVOKE ALL ON FUNCTION approve_hardware_trust_approval(UUID, TEXT) FROM provider_onboarding;
REVOKE ALL ON FUNCTION revoke_hardware_trust_approval(UUID, TEXT, TEXT, TEXT, TEXT) FROM provider_onboarding;

GRANT EXECUTE ON FUNCTION request_hardware_trust_approval(UUID, BIGINT, TEXT, TIMESTAMPTZ, TEXT, TEXT) TO hardware_trust_requester;
GRANT EXECUTE ON FUNCTION approve_hardware_trust_approval(UUID, TEXT) TO hardware_trust_approver;
GRANT EXECUTE ON FUNCTION revoke_hardware_trust_approval(UUID, TEXT, TEXT, TEXT, TEXT) TO hardware_trust_approver;
ALTER FUNCTION request_hardware_trust_approval(UUID, BIGINT, TEXT, TIMESTAMPTZ, TEXT, TEXT) OWNER TO hardware_trust_definer;
ALTER FUNCTION approve_hardware_trust_approval(UUID, TEXT) OWNER TO hardware_trust_definer;
ALTER FUNCTION revoke_hardware_trust_approval(UUID, TEXT, TEXT, TEXT, TEXT) OWNER TO hardware_trust_definer;
REVOKE CREATE ON SCHEMA public FROM hardware_trust_definer;

DO $$
DECLARE
    membership RECORD;
BEGIN
    FOR membership IN
        SELECT granted.rolname AS parent_role, member.rolname AS member_role
          FROM pg_auth_members m
          JOIN pg_roles granted ON granted.oid = m.roleid
          JOIN pg_roles member ON member.oid = m.member
         WHERE member.rolname IN ('hardware_trust_definer', 'hardware_trust_requester', 'hardware_trust_approver')
            OR granted.rolname IN ('hardware_trust_definer', 'hardware_trust_requester', 'hardware_trust_approver')
    LOOP
        EXECUTE format('REVOKE %I FROM %I', membership.parent_role, membership.member_role);
    END LOOP;
END
$$;
