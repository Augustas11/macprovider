-- Existing deployments have already recorded 006_spec_026_identity, so the
-- approval function repair must ship as a forward migration.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'provider_auth_policy_definer') THEN
        CREATE ROLE provider_auth_policy_definer NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'provider_auth_policy_requester') THEN
        CREATE ROLE provider_auth_policy_requester NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'provider_auth_policy_approver') THEN
        CREATE ROLE provider_auth_policy_approver NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'provider_auth_policy_cutover') THEN
        CREATE ROLE provider_auth_policy_cutover NOLOGIN;
    END IF;
    ALTER ROLE provider_auth_policy_definer NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
    ALTER ROLE provider_auth_policy_requester NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
    ALTER ROLE provider_auth_policy_approver NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
    ALTER ROLE provider_auth_policy_cutover NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
END
$$;

CREATE OR REPLACE FUNCTION seed_provider_auth_policy_cutover(
    p_cutover TIMESTAMPTZ,
    p_cli_provider_ids TEXT[] DEFAULT ARRAY[]::TEXT[]
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
    inserted_app BIGINT := 0;
    inserted_cli BIGINT := 0;
    inserted_run BIGINT := 0;
    effective_cutover TIMESTAMPTZ;
BEGIN
    IF p_cutover IS NULL THEN
        RAISE EXCEPTION 'cutover time is required';
    END IF;
    IF p_cutover > NOW() + INTERVAL '5 minutes' THEN
        RAISE EXCEPTION 'cutover time cannot be in the future';
    END IF;

    INSERT INTO provider_auth_policy_cutover_runs (singleton_id, cutover_time)
    VALUES (TRUE, p_cutover)
    ON CONFLICT (singleton_id) DO NOTHING;
    GET DIAGNOSTICS inserted_run = ROW_COUNT;
    IF inserted_run <> 1 THEN
        RAISE EXCEPTION 'cutover seed already completed';
    END IF;

    SELECT cutover_time INTO effective_cutover
      FROM provider_auth_policy_cutover_runs
     WHERE singleton_id = TRUE
     FOR UPDATE;

    WITH inserted AS (
        INSERT INTO provider_auth_policy (
            provider_id, kind, signature_exempt_until, granted_by, granted_reason, granted_at
        )
        SELECT i.provider_id, 'app', effective_cutover + INTERVAL '7 days', 'migration', 'spec-026-cutover-legacy', effective_cutover
          FROM provider_identities i
         WHERE i.first_seen_ts <= effective_cutover
        ON CONFLICT (provider_id) DO NOTHING
        RETURNING provider_id, signature_exempt_until, granted_reason, granted_at
    ), grant_insert AS (
        INSERT INTO provider_auth_policy_grants (
            grant_id, pending_id, provider_id, grant_source, requested_by, approved_by,
            requested_until, reason, incident_id, granted_at
        )
        SELECT (
            SUBSTR(MD5('spec-026-cutover:' || provider_id || ':' || effective_cutover::TEXT), 1, 8) || '-' ||
            SUBSTR(MD5('spec-026-cutover:' || provider_id || ':' || effective_cutover::TEXT), 9, 4) || '-' ||
            SUBSTR(MD5('spec-026-cutover:' || provider_id || ':' || effective_cutover::TEXT), 13, 4) || '-' ||
            SUBSTR(MD5('spec-026-cutover:' || provider_id || ':' || effective_cutover::TEXT), 17, 4) || '-' ||
            SUBSTR(MD5('spec-026-cutover:' || provider_id || ':' || effective_cutover::TEXT), 21, 12)
        )::UUID,
        NULL, provider_id, 'migration', 'migration', 'migration',
        signature_exempt_until, granted_reason, NULL, granted_at
          FROM inserted
        ON CONFLICT DO NOTHING
        RETURNING 1
    )
    SELECT COUNT(*) INTO inserted_app FROM inserted;

    WITH cli_ids AS (
        SELECT DISTINCT BTRIM(id) AS provider_id
          FROM unnest(COALESCE(p_cli_provider_ids, ARRAY[]::TEXT[])) AS id
         WHERE NULLIF(BTRIM(id), '') IS NOT NULL
           AND BTRIM(id) NOT LIKE 'p\_%' ESCAPE '\'
    ), inserted AS (
        INSERT INTO provider_auth_policy (
            provider_id, kind, signature_exempt_until, granted_by, granted_reason, granted_at
        )
        SELECT provider_id, 'cli', effective_cutover + INTERVAL '7 days', 'migration', 'spec-026-cutover-legacy', effective_cutover
          FROM cli_ids
        ON CONFLICT (provider_id) DO NOTHING
        RETURNING provider_id, signature_exempt_until, granted_reason, granted_at
    ), grant_insert AS (
        INSERT INTO provider_auth_policy_grants (
            grant_id, pending_id, provider_id, grant_source, requested_by, approved_by,
            requested_until, reason, incident_id, granted_at
        )
        SELECT (
            SUBSTR(MD5('spec-026-cutover:' || provider_id || ':' || effective_cutover::TEXT), 1, 8) || '-' ||
            SUBSTR(MD5('spec-026-cutover:' || provider_id || ':' || effective_cutover::TEXT), 9, 4) || '-' ||
            SUBSTR(MD5('spec-026-cutover:' || provider_id || ':' || effective_cutover::TEXT), 13, 4) || '-' ||
            SUBSTR(MD5('spec-026-cutover:' || provider_id || ':' || effective_cutover::TEXT), 17, 4) || '-' ||
            SUBSTR(MD5('spec-026-cutover:' || provider_id || ':' || effective_cutover::TEXT), 21, 12)
        )::UUID,
        NULL, provider_id, 'migration', 'migration', 'migration',
        signature_exempt_until, granted_reason, NULL, granted_at
          FROM inserted
        ON CONFLICT DO NOTHING
        RETURNING 1
    )
    SELECT COUNT(*) INTO inserted_cli FROM inserted;

    RETURN inserted_app + inserted_cli;
END;
$$;

CREATE OR REPLACE FUNCTION request_provider_auth_policy_exemption(
    p_pending_id UUID,
    p_provider_id TEXT,
    p_requested_by TEXT,
    p_requested_until TIMESTAMPTZ,
    p_reason TEXT,
    p_incident_id TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
    request_time TIMESTAMPTZ := NOW();
    used_exemption INTERVAL;
    requested_exemption INTERVAL;
BEGIN
    IF p_pending_id IS NULL THEN
        RAISE EXCEPTION 'pending_id is required';
    END IF;
    IF NULLIF(BTRIM(p_provider_id), '') IS NULL THEN
        RAISE EXCEPTION 'provider_id is required';
    END IF;
    IF p_requested_by !~ '^operator:[^[:space:]]+$' THEN
        RAISE EXCEPTION 'requested_by must use operator:<admin_id>';
    END IF;
    IF NULLIF(BTRIM(p_reason), '') IS NULL THEN
        RAISE EXCEPTION 'reason is required';
    END IF;
    IF p_requested_until <= request_time THEN
        RAISE EXCEPTION 'requested_until must be in the future';
    END IF;
    IF p_requested_until - request_time > INTERVAL '30 days' THEN
        RAISE EXCEPTION 'requested_until exceeds 30 day ceiling';
    END IF;
    IF p_requested_until - request_time > INTERVAL '7 days' AND NULLIF(BTRIM(COALESCE(p_incident_id, '')), '') IS NULL THEN
        RAISE EXCEPTION 'incident_id required for exemptions over 7 days';
    END IF;
    IF p_provider_id LIKE 'p\_%' ESCAPE '\' AND NOT EXISTS (
        SELECT 1 FROM provider_identities i WHERE i.provider_id = p_provider_id
    ) THEN
        RAISE EXCEPTION 'provider_id not found';
    END IF;
    PERFORM pg_advisory_xact_lock(26026, hashtext(BTRIM(p_provider_id)));
    IF NULLIF(BTRIM(COALESCE(p_incident_id, '')), '') IS NOT NULL AND EXISTS (
        SELECT 1 FROM provider_auth_policy_grants g
         WHERE g.provider_id = BTRIM(p_provider_id)
           AND g.incident_id = NULLIF(BTRIM(COALESCE(p_incident_id, '')), '')
    ) THEN
        RAISE EXCEPTION 'incident_id already used';
    END IF;
    SELECT COALESCE(SUM(GREATEST(g.requested_until - g.granted_at, INTERVAL '0 seconds')), INTERVAL '0 seconds')
      INTO used_exemption
      FROM provider_auth_policy_grants g
     WHERE g.provider_id = BTRIM(p_provider_id);
    requested_exemption := GREATEST(p_requested_until - request_time, INTERVAL '0 seconds');
    IF used_exemption + requested_exemption > INTERVAL '30 days' THEN
        RAISE EXCEPTION 'renewal cap exceeded';
    END IF;

    INSERT INTO provider_auth_policy_pending (
        pending_id, provider_id, requested_by, requested_until, reason, incident_id
    ) VALUES (
        p_pending_id,
        BTRIM(p_provider_id),
        BTRIM(p_requested_by),
        p_requested_until,
        BTRIM(p_reason),
        NULLIF(BTRIM(COALESCE(p_incident_id, '')), '')
    );
    RETURN p_pending_id;
END;
$$;

CREATE OR REPLACE FUNCTION approve_provider_auth_policy_exemption(
    p_pending_id UUID,
    p_approved_by TEXT
)
RETURNS TABLE (
    provider_id TEXT,
    requested_by TEXT,
    requested_until TIMESTAMPTZ,
    reason TEXT,
    incident_id TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
    pending provider_auth_policy_pending%ROWTYPE;
    approval_time TIMESTAMPTZ := NOW();
    used_exemption INTERVAL;
    requested_exemption INTERVAL;
BEGIN
    IF p_approved_by !~ '^operator:[^[:space:]]+$' THEN
        RAISE EXCEPTION 'approved_by must use operator:<admin_id>';
    END IF;

    SELECT * INTO pending
      FROM provider_auth_policy_pending
     WHERE pending_id = p_pending_id
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pending exemption not found';
    END IF;
    IF pending.committed_at IS NOT NULL THEN
        RAISE EXCEPTION 'pending exemption already committed';
    END IF;
    IF pending.requested_by = BTRIM(p_approved_by) THEN
        RAISE EXCEPTION 'dual_control_required';
    END IF;
    IF pending.requested_until <= approval_time THEN
        RAISE EXCEPTION 'requested_until must be in the future';
    END IF;
    PERFORM pg_advisory_xact_lock(26026, hashtext(pending.provider_id));
    IF pending.incident_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM provider_auth_policy_grants g
         WHERE g.provider_id = pending.provider_id
           AND g.incident_id = pending.incident_id
    ) THEN
        RAISE EXCEPTION 'incident_id already used';
    END IF;
    SELECT COALESCE(SUM(GREATEST(g.requested_until - g.granted_at, INTERVAL '0 seconds')), INTERVAL '0 seconds')
      INTO used_exemption
      FROM provider_auth_policy_grants g
     WHERE g.provider_id = pending.provider_id;
    requested_exemption := GREATEST(pending.requested_until - approval_time, INTERVAL '0 seconds');
    IF used_exemption + requested_exemption > INTERVAL '30 days' THEN
        RAISE EXCEPTION 'renewal cap exceeded';
    END IF;

    UPDATE provider_auth_policy_pending
       SET approved_by = BTRIM(p_approved_by),
           approved_at = approval_time,
           committed_at = approval_time
     WHERE pending_id = p_pending_id;

    INSERT INTO provider_auth_policy (
        provider_id, kind, signature_exempt_until, granted_by, granted_reason, granted_at
    ) VALUES (
        pending.provider_id,
        CASE WHEN pending.provider_id LIKE 'p\_%' ESCAPE '\' THEN 'app' ELSE 'cli' END,
        pending.requested_until,
        BTRIM(p_approved_by),
        pending.reason,
        approval_time
    )
    ON CONFLICT ON CONSTRAINT provider_auth_policy_pkey DO UPDATE
       SET kind = EXCLUDED.kind,
           signature_exempt_until = EXCLUDED.signature_exempt_until,
           granted_by = EXCLUDED.granted_by,
           granted_reason = EXCLUDED.granted_reason,
           granted_at = EXCLUDED.granted_at;

    INSERT INTO provider_auth_policy_grants (
        grant_id, pending_id, provider_id, requested_by, approved_by,
        requested_until, reason, incident_id, granted_at
    ) VALUES (
        pending.pending_id,
        pending.pending_id,
        pending.provider_id,
        pending.requested_by,
        BTRIM(p_approved_by),
        pending.requested_until,
        pending.reason,
        pending.incident_id,
        approval_time
    );

    RETURN QUERY SELECT pending.provider_id, pending.requested_by, pending.requested_until, pending.reason, pending.incident_id;
END;
$$;

GRANT USAGE, CREATE ON SCHEMA public TO provider_auth_policy_definer;
GRANT USAGE ON SCHEMA public TO provider_auth_policy_requester;
GRANT USAGE ON SCHEMA public TO provider_auth_policy_approver;
GRANT USAGE ON SCHEMA public TO provider_auth_policy_cutover;
GRANT SELECT ON provider_identities TO provider_auth_policy_definer;
GRANT SELECT, INSERT, UPDATE ON provider_auth_policy TO provider_auth_policy_definer;
GRANT SELECT, INSERT, UPDATE ON provider_auth_policy_cutover_runs TO provider_auth_policy_definer;
GRANT SELECT, INSERT, UPDATE ON provider_auth_policy_pending TO provider_auth_policy_definer;
GRANT SELECT, INSERT ON provider_auth_policy_grants TO provider_auth_policy_definer;
REVOKE ALL ON provider_identities FROM provider_auth_policy_requester, provider_auth_policy_approver, provider_auth_policy_cutover;
REVOKE ALL ON provider_auth_policy FROM provider_auth_policy_requester, provider_auth_policy_approver, provider_auth_policy_cutover;
REVOKE ALL ON provider_auth_policy_cutover_runs FROM provider_auth_policy_requester, provider_auth_policy_approver, provider_auth_policy_cutover;
REVOKE ALL ON provider_auth_policy_pending FROM provider_auth_policy_requester, provider_auth_policy_approver, provider_auth_policy_cutover;
REVOKE ALL ON provider_auth_policy_grants FROM provider_auth_policy_requester, provider_auth_policy_approver, provider_auth_policy_cutover;

REVOKE ALL ON FUNCTION seed_provider_auth_policy_cutover(TIMESTAMPTZ, TEXT[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION request_provider_auth_policy_exemption(UUID, TEXT, TEXT, TIMESTAMPTZ, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION approve_provider_auth_policy_exemption(UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION seed_provider_auth_policy_cutover(TIMESTAMPTZ, TEXT[]) FROM provider_onboarding;
REVOKE ALL ON FUNCTION request_provider_auth_policy_exemption(UUID, TEXT, TEXT, TIMESTAMPTZ, TEXT, TEXT) FROM provider_onboarding;
REVOKE ALL ON FUNCTION approve_provider_auth_policy_exemption(UUID, TEXT) FROM provider_onboarding;

GRANT EXECUTE ON FUNCTION seed_provider_auth_policy_cutover(TIMESTAMPTZ, TEXT[]) TO provider_auth_policy_cutover;
GRANT EXECUTE ON FUNCTION request_provider_auth_policy_exemption(UUID, TEXT, TEXT, TIMESTAMPTZ, TEXT, TEXT) TO provider_auth_policy_requester;
GRANT EXECUTE ON FUNCTION approve_provider_auth_policy_exemption(UUID, TEXT) TO provider_auth_policy_approver;
ALTER FUNCTION seed_provider_auth_policy_cutover(TIMESTAMPTZ, TEXT[]) OWNER TO provider_auth_policy_definer;
ALTER FUNCTION request_provider_auth_policy_exemption(UUID, TEXT, TEXT, TIMESTAMPTZ, TEXT, TEXT) OWNER TO provider_auth_policy_definer;
ALTER FUNCTION approve_provider_auth_policy_exemption(UUID, TEXT) OWNER TO provider_auth_policy_definer;
REVOKE CREATE ON SCHEMA public FROM provider_auth_policy_definer;
DO $$
DECLARE
    membership RECORD;
BEGIN
    FOR membership IN
        SELECT granted.rolname AS parent_role, member.rolname AS member_role
          FROM pg_auth_members m
          JOIN pg_roles granted ON granted.oid = m.roleid
          JOIN pg_roles member ON member.oid = m.member
         WHERE member.rolname IN ('provider_auth_policy_definer', 'provider_auth_policy_requester', 'provider_auth_policy_approver', 'provider_auth_policy_cutover')
            OR granted.rolname IN ('provider_auth_policy_definer', 'provider_auth_policy_requester', 'provider_auth_policy_approver', 'provider_auth_policy_cutover')
    LOOP
        EXECUTE format('REVOKE %I FROM %I', membership.parent_role, membership.member_role);
    END LOOP;
END
$$;
