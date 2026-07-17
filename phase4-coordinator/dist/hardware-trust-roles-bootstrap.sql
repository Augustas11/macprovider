-- Bootstrap the issue #582 hardware-trust split login roles after migration 019
-- has created the NOLOGIN roles (hardware_trust_definer / _requester / _approver)
-- and repaired grants. Run with an admin/operator Postgres role during the same
-- maintenance window as the coordinator binary deploy:
--
--   export PGDATABASE="$ADMIN_DSN"
--   export HARDWARE_TRUST_REQUESTER_PASSWORD="$(openssl rand -base64 36)"
--   export HARDWARE_TRUST_APPROVER_PASSWORD="$(openssl rand -base64 36)"
--   psql -v ON_ERROR_STOP=1 -f hardware-trust-roles-bootstrap.sql
--   unset HARDWARE_TRUST_REQUESTER_PASSWORD \
--         HARDWARE_TRUST_APPROVER_PASSWORD \
--         PGDATABASE
--
-- Only the requester and approver roles gain LOGIN; hardware_trust_definer stays
-- NOLOGIN (it exists only to own the SECURITY DEFINER functions). The passwords
-- are supplied at execution time, never committed or passed through process
-- arguments. Update /etc/macprovider/coordinator.env with matching
-- ONBOARDING_HARDWARE_TRUST_REQUEST_DSN / ONBOARDING_HARDWARE_TRUST_APPROVE_DSN
-- values before restarting the new coordinator binary. Do not run migration 019
-- ahead of the binary deploy unless the old coordinator can tolerate the
-- hardware-trust admin endpoints being unavailable.

\set ON_ERROR_STOP on

\getenv requester_password HARDWARE_TRUST_REQUESTER_PASSWORD
\getenv approver_password HARDWARE_TRUST_APPROVER_PASSWORD
\if :{?requester_password}
\else
  \echo 'missing required HARDWARE_TRUST_REQUESTER_PASSWORD environment variable'
  \quit 3
\endif
\if :{?approver_password}
\else
  \echo 'missing required HARDWARE_TRUST_APPROVER_PASSWORD environment variable'
  \quit 3
\endif
SELECT NULLIF(:'requester_password', '') IS NOT NULL AS requester_password_ok \gset
\if :requester_password_ok
\else
  \echo 'HARDWARE_TRUST_REQUESTER_PASSWORD must be non-empty'
  \quit 3
\endif
SELECT NULLIF(:'approver_password', '') IS NOT NULL AS approver_password_ok \gset
\if :approver_password_ok
\else
  \echo 'HARDWARE_TRUST_APPROVER_PASSWORD must be non-empty'
  \quit 3
\endif

BEGIN;

REVOKE ALL ON hardware_trust_pending FROM hardware_trust_requester, hardware_trust_approver;
REVOKE ALL ON hardware_trust_grants FROM hardware_trust_requester, hardware_trust_approver;
REVOKE ALL ON hardware_verification_trust FROM hardware_trust_requester, hardware_trust_approver;

ALTER ROLE hardware_trust_requester LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD :'requester_password';
ALTER ROLE hardware_trust_approver LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD :'approver_password';

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

COMMIT;
