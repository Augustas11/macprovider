#!/usr/bin/env python3
"""Provision the app_attest_recorder login on the coordinator host (SPEC-033 §2.7).

Runs as root on the host that holds the coordinator env file, normally through
`scripts/ops/pearl-runtime.sh next --run` (step app_attest_recorder), before
the runtime apply that ships `onboarding.app_attest_record_dsn`.

1. If ONBOARDING_APP_ATTEST_RECORD_DSN is already set and logs in as
   app_attest_recorder, do nothing (exit 0). If it is set but does not work,
   refuse unless --rotate.
2. Generate a random password in memory, derive its SCRAM-SHA-256 verifier,
   and run app-attest-recorder-bootstrap.sql as the admin role with only the
   verifier in the environment (\\getenv). The plaintext never reaches argv,
   the database session or its logs.
3. Write ONBOARDING_APP_ATTEST_RECORD_DSN (same host, port, database and
   options as ONBOARDING_POSTGRES_DSN, user app_attest_recorder) into the env
   file atomically, keeping its mode and owner.
4. Log in with the new DSN and check the role and its least privilege.

Nothing secret is printed. DSNs reach psql only through a 0600 service file.
The env file is read as data, never sourced.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import os
import re
import secrets
import subprocess
import sys
import tempfile
from urllib.parse import parse_qsl, quote, unquote, urlparse, urlunparse

ENV_KEY = "ONBOARDING_APP_ATTEST_RECORD_DSN"
ADMIN_KEY = "COORDINATOR_PARTNER_KEYS_ADMIN_DSN"
ONBOARDING_KEY = "ONBOARDING_POSTGRES_DSN"
ROLE = "app_attest_recorder"
SCRAM_ITERATIONS = 4096
# Connection parameters a DSN query string may not carry: they would override
# the credentials or target this script sets.
FORBIDDEN_QUERY_KEYS = {"user", "password", "passfile", "service", "servicefile", "host", "hostaddr", "port", "dbname"}
SCRAM_RE = re.compile(r"^SCRAM-SHA-256\$[0-9]+:[A-Za-z0-9+/=]+\$[A-Za-z0-9+/=]+:[A-Za-z0-9+/=]+$")
# The bootstrap's own refusal messages; any other psql output is redacted.
BOOTSTRAP_MESSAGES = (
    "missing required APP_ATTEST_RECORDER_PASSWORD_SCRAM environment variable",
    "APP_ATTEST_RECORDER_PASSWORD_SCRAM must be a SCRAM-SHA-256 verifier, not a plaintext password",
    "app_attest_recorder or provider_app_attest_verifications is missing: apply stats migration 031 first",
)
EXIT_ABSENT = 10
EXIT_INVALID = 11

# onboarding.AppAttestRecorderPolicySQL verbatim; a Go test keeps the copies identical.
VERIFY_SQL = """\
SELECT current_user = 'app_attest_recorder'
   AND session_user = current_user
   AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = current_user AND rolcanlogin AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolinherit AND NOT rolreplication AND NOT rolbypassrls)
   AND NOT EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles g ON g.oid = m.roleid JOIN pg_roles r ON r.oid = m.member WHERE r.rolname = current_user OR g.rolname = current_user)
   AND NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_roles r ON r.oid = c.relowner WHERE r.rolname = current_user)
   AND NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner WHERE r.rolname = current_user)
   AND has_table_privilege(current_user, 'provider_app_attest_verifications', 'SELECT')
   AND has_table_privilege(current_user, 'provider_app_attest_verifications', 'INSERT')
   AND NOT EXISTS (SELECT 1 FROM unnest(ARRAY['UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER']) AS p(name) WHERE has_table_privilege(current_user, 'provider_app_attest_verifications', p.name))
   AND NOT has_any_column_privilege(current_user, 'provider_app_attest_verifications', 'UPDATE')
   AND NOT has_any_column_privilege(current_user, 'provider_app_attest_verifications', 'REFERENCES')
   AND NOT EXISTS (SELECT 1 FROM unnest(ARRAY['hardware_verification_trust', 'hardware_trust_grants', 'hardware_trust_pending', 'hardware_verification_jobs', 'provider_identities', 'provider_hardware_profiles']) AS t(name) WHERE to_regclass(t.name) IS NOT NULL AND (has_any_column_privilege(current_user, t.name, 'SELECT') OR has_any_column_privilege(current_user, t.name, 'INSERT') OR has_any_column_privilege(current_user, t.name, 'UPDATE') OR has_any_column_privilege(current_user, t.name, 'REFERENCES') OR has_table_privilege(current_user, t.name, 'DELETE') OR has_table_privilege(current_user, t.name, 'TRUNCATE') OR has_table_privilege(current_user, t.name, 'TRIGGER')))
   AND NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.prosecdef AND has_function_privilege(current_user, p.oid, 'EXECUTE'));
"""


class ProvisionError(Exception):
    pass


def parse_env_file(path: str) -> dict[str, str]:
    """KEY=VALUE lines; optional matching quotes; comments and blanks skipped."""
    values: dict[str, str] = {}
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            if key.startswith("export "):
                key = key[len("export "):].strip()
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
                value = value[1:-1]
            values[key] = value
    return values


def scram_sha256_verifier(password: str, salt: bytes | None = None, iterations: int = SCRAM_ITERATIONS) -> str:
    """The verifier PostgreSQL stores for a SCRAM-SHA-256 password (RFC 5802/7677)."""
    salt = salt if salt is not None else secrets.token_bytes(16)
    salted = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)
    client_key = hmac.new(salted, b"Client Key", hashlib.sha256).digest()
    stored_key = hashlib.sha256(client_key).digest()
    server_key = hmac.new(salted, b"Server Key", hashlib.sha256).digest()
    b64 = lambda b: base64.b64encode(b).decode("ascii")  # noqa: E731
    return f"SCRAM-SHA-256${iterations}:{b64(salt)}${b64(stored_key)}:{b64(server_key)}"


def checked_query(parsed) -> str:
    keys = {k.lower() for k, _ in parse_qsl(parsed.query, keep_blank_values=True)}
    if keys & FORBIDDEN_QUERY_KEYS:
        raise ProvisionError("a Postgres DSN query may not set " + ", ".join(sorted(keys & FORBIDDEN_QUERY_KEYS)))
    return parsed.query


def recorder_dsn(onboarding_dsn: str, password: str) -> str:
    parsed = urlparse(onboarding_dsn)
    if parsed.scheme not in ("postgres", "postgresql") or not parsed.hostname:
        raise ProvisionError(f"{ONBOARDING_KEY} is not a postgres:// URL with a host")
    try:
        port = parsed.port
    except ValueError:
        raise ProvisionError(f"{ONBOARDING_KEY} has an invalid port") from None
    query = checked_query(parsed)
    host = parsed.hostname
    if ":" in host:
        host = f"[{host}]"
    netloc = f"{ROLE}:{quote(password, safe='')}@{host}"
    if port is not None:
        netloc += f":{port}"
    return urlunparse((parsed.scheme, netloc, parsed.path, "", query, ""))


def service_entry(name: str, dsn: str) -> str:
    parsed = urlparse(dsn)
    if parsed.scheme not in ("postgres", "postgresql"):
        raise ProvisionError("unsupported Postgres DSN scheme")
    checked_query(parsed)
    values = {
        "host": parsed.hostname or "",
        "user": unquote(parsed.username or ""),
        "password": unquote(parsed.password or ""),
        "dbname": unquote(parsed.path[1:] if parsed.path.startswith("/") else parsed.path),
    }
    if parsed.port is not None:
        values["port"] = str(parsed.port)
    for key, value in parse_qsl(parsed.query, keep_blank_values=True):
        values[key] = value
    lines = [f"[{name}]"]
    for key, value in values.items():
        if any(ch in value for ch in "\r\n"):
            raise ProvisionError("invalid newline in Postgres DSN value")
        if value != "":
            lines.append(f"{key}={value}")
    return "\n".join(lines) + "\n"


def run_psql(psql: str, dsn: str, args: list[str], extra_env: dict[str, str] | None = None, stdin: str | None = None) -> subprocess.CompletedProcess:
    fd, path = tempfile.mkstemp(prefix="pgservice-")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(service_entry("app_attest_provision", dsn))
        env = {k: v for k, v in os.environ.items() if not k.startswith("PG")}
        env.update({"PGSERVICEFILE": path, "PGSERVICE": "app_attest_provision"})
        env.update(extra_env or {})
        return subprocess.run([psql, "-v", "ON_ERROR_STOP=1", "-qAtX", *args], env=env, input=stdin,
                              capture_output=True, text=True, timeout=60, check=False)
    finally:
        os.unlink(path)


def recorder_login_ok(psql: str, dsn: str) -> bool:
    result = run_psql(psql, dsn, [], stdin=VERIFY_SQL)
    return result.returncode == 0 and result.stdout.strip() == "t"


def write_env_value(path: str, key: str, value: str) -> None:
    """Replace or append key=value atomically, keeping the file's mode and owner."""
    if any(ch in value for ch in "\r\n"):
        raise ProvisionError("refusing to write a value with a newline")
    st = os.stat(path)
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()
    kept = [ln for ln in lines if not (ln.strip().split("=", 1)[0].strip().removeprefix("export ").strip() == key and "=" in ln)]
    kept.append(f"{key}={value}")
    directory = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(prefix=".coordinator.env.", dir=directory)
    try:
        os.fchmod(fd, st.st_mode & 0o7777)
        try:
            os.fchown(fd, st.st_uid, st.st_gid)
        except PermissionError:
            if (st.st_uid, st.st_gid) != (os.getuid(), os.getgid()):
                raise
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write("\n".join(kept) + "\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
        dir_fd = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def check(env_file: str, psql: str) -> int:
    """0 when the recorder DSN works under the policy, EXIT_ABSENT when it is
    unset, EXIT_INVALID otherwise. Prints nothing secret."""
    existing = parse_env_file(env_file).get(ENV_KEY, "")
    if not existing:
        return EXIT_ABSENT
    try:
        return 0 if recorder_login_ok(psql, existing) else EXIT_INVALID
    except (ProvisionError, OSError, subprocess.SubprocessError):
        return EXIT_INVALID


def provision(env_file: str, sql_path: str, psql: str, rotate: bool) -> str:
    env = parse_env_file(env_file)
    existing = env.get(ENV_KEY, "")
    if existing and not rotate:
        if recorder_login_ok(psql, existing):
            return "already provisioned"
        raise ProvisionError(f"{ENV_KEY} is set in {env_file} but does not log in as {ROLE} with least privilege; rerun with --rotate")
    admin = env.get(ADMIN_KEY, "")
    onboarding = env.get(ONBOARDING_KEY, "")
    if not admin or not onboarding:
        raise ProvisionError(f"{env_file} must set {ADMIN_KEY} and {ONBOARDING_KEY}")
    password = secrets.token_urlsafe(36)
    # Everything that can fail statically fails before the role changes.
    dsn = recorder_dsn(onboarding, password)
    service_entry("check", dsn)
    service_entry("check", admin)
    verifier = scram_sha256_verifier(password)
    if not SCRAM_RE.fullmatch(verifier):
        raise ProvisionError("generated SCRAM verifier is malformed")
    result = run_psql(psql, admin, ["-f", sql_path], extra_env={"APP_ATTEST_RECORDER_PASSWORD_SCRAM": verifier})
    if result.returncode != 0:
        # Only the bootstrap's own refusal messages are shown; server
        # diagnostics can quote statement text.
        known = [m for m in BOOTSTRAP_MESSAGES if m in result.stdout + result.stderr]
        raise ProvisionError(f"bootstrap SQL failed (rc={result.returncode})" + (f": {known[0]}" if known else ""))
    write_env_value(env_file, ENV_KEY, dsn)
    if not recorder_login_ok(psql, dsn):
        raise ProvisionError(f"{ENV_KEY} was written but does not log in as {ROLE} with least privilege")
    return "provisioned"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    here = os.path.dirname(os.path.abspath(__file__))
    parser.add_argument("--env-file", default="/etc/macprovider/coordinator.env")
    parser.add_argument("--sql", default=os.path.join(here, "app-attest-recorder-bootstrap.sql"))
    parser.add_argument("--psql", default="psql")
    parser.add_argument("--rotate", action="store_true", help="replace a set but non-working DSN")
    parser.add_argument("--check", action="store_true",
                        help=f"only report: exit 0 valid, {EXIT_ABSENT} unset, {EXIT_INVALID} set but failing the policy")
    args = parser.parse_args(argv)
    if args.check:
        try:
            rc = check(args.env_file, args.psql)
        except OSError:
            rc = EXIT_INVALID
        print({0: "valid", EXIT_ABSENT: "absent", EXIT_INVALID: "invalid"}[rc])
        return rc
    try:
        outcome = provision(args.env_file, args.sql, args.psql, args.rotate)
    except (ProvisionError, OSError, subprocess.SubprocessError) as exc:
        print(f"app_attest_recorder provisioning failed: {exc}", file=sys.stderr)
        return 1
    print(f"app_attest_recorder {outcome}; {ENV_KEY} is set in {args.env_file}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
