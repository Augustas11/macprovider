-- Bootstrap the hardware verifier login after migration 008 has created the
-- NOLOGIN role and grants. Run with an admin/operator Postgres role:
--
--   export PGDATABASE="$ADMIN_DSN"
--   export STATS_HARDWARE_VERIFIER_PASSWORD="$(openssl rand -base64 36)"
--   psql -f stats-hardware-verifier-bootstrap.sql
--   unset STATS_HARDWARE_VERIFIER_PASSWORD PGDATABASE
--
-- The password is intentionally supplied at execution time, not committed or
-- passed through process arguments.

\getenv verifier_password STATS_HARDWARE_VERIFIER_PASSWORD
\if :{?verifier_password}
\else
  \echo 'missing required STATS_HARDWARE_VERIFIER_PASSWORD environment variable'
  \quit 3
\endif

ALTER ROLE stats_hardware_verifier LOGIN PASSWORD :'verifier_password';
