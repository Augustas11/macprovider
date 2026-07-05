-- Bootstrap the SPEC-026 auth-policy split login roles after migration 009 has
-- created the NOLOGIN roles and repaired grants. Run with an admin/operator
-- Postgres role during the same maintenance window as the coordinator binary
-- deploy:
--
--   export PGDATABASE="$ADMIN_DSN"
--   export PROVIDER_AUTH_POLICY_REQUESTER_PASSWORD="$(openssl rand -base64 36)"
--   export PROVIDER_AUTH_POLICY_APPROVER_PASSWORD="$(openssl rand -base64 36)"
--   export PROVIDER_AUTH_POLICY_CUTOVER_PASSWORD="$(openssl rand -base64 36)"
--   psql -v ON_ERROR_STOP=1 -f provider-auth-policy-roles-bootstrap.sql
--   unset PROVIDER_AUTH_POLICY_REQUESTER_PASSWORD \
--         PROVIDER_AUTH_POLICY_APPROVER_PASSWORD \
--         PROVIDER_AUTH_POLICY_CUTOVER_PASSWORD \
--         PGDATABASE
--
-- The passwords are intentionally supplied at execution time, not committed or
-- passed through process arguments. Update /etc/macprovider/coordinator.env
-- with matching ONBOARDING_AUTH_POLICY_*_DSN values before restarting the new
-- coordinator binary. Do not run migration 009 ahead of the binary deploy unless
-- the old coordinator can tolerate auth-policy admin endpoints being unavailable.

\set ON_ERROR_STOP on

\getenv requester_password PROVIDER_AUTH_POLICY_REQUESTER_PASSWORD
\getenv approver_password PROVIDER_AUTH_POLICY_APPROVER_PASSWORD
\getenv cutover_password PROVIDER_AUTH_POLICY_CUTOVER_PASSWORD
\if :{?requester_password}
\else
  \echo 'missing required PROVIDER_AUTH_POLICY_REQUESTER_PASSWORD environment variable'
  \quit 3
\endif
\if :{?approver_password}
\else
  \echo 'missing required PROVIDER_AUTH_POLICY_APPROVER_PASSWORD environment variable'
  \quit 3
\endif
\if :{?cutover_password}
\else
  \echo 'missing required PROVIDER_AUTH_POLICY_CUTOVER_PASSWORD environment variable'
  \quit 3
\endif
SELECT NULLIF(:'requester_password', '') IS NOT NULL AS requester_password_ok \gset
\if :requester_password_ok
\else
  \echo 'PROVIDER_AUTH_POLICY_REQUESTER_PASSWORD must be non-empty'
  \quit 3
\endif
SELECT NULLIF(:'approver_password', '') IS NOT NULL AS approver_password_ok \gset
\if :approver_password_ok
\else
  \echo 'PROVIDER_AUTH_POLICY_APPROVER_PASSWORD must be non-empty'
  \quit 3
\endif
SELECT NULLIF(:'cutover_password', '') IS NOT NULL AS cutover_password_ok \gset
\if :cutover_password_ok
\else
  \echo 'PROVIDER_AUTH_POLICY_CUTOVER_PASSWORD must be non-empty'
  \quit 3
\endif

BEGIN;

REVOKE ALL ON provider_identities FROM provider_auth_policy_requester, provider_auth_policy_approver, provider_auth_policy_cutover;
REVOKE ALL ON provider_auth_policy FROM provider_auth_policy_requester, provider_auth_policy_approver, provider_auth_policy_cutover;
REVOKE ALL ON provider_auth_policy_cutover_runs FROM provider_auth_policy_requester, provider_auth_policy_approver, provider_auth_policy_cutover;
REVOKE ALL ON provider_auth_policy_pending FROM provider_auth_policy_requester, provider_auth_policy_approver, provider_auth_policy_cutover;
REVOKE ALL ON provider_auth_policy_grants FROM provider_auth_policy_requester, provider_auth_policy_approver, provider_auth_policy_cutover;

ALTER ROLE provider_auth_policy_requester LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD :'requester_password';
ALTER ROLE provider_auth_policy_approver LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD :'approver_password';
ALTER ROLE provider_auth_policy_cutover LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD :'cutover_password';

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

COMMIT;
