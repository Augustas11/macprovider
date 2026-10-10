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

VERIFY_SQL = """\
SELECT current_user = 'app_attest_recorder'
   AND session_user = current_user
   AND has_table_privilege(current_user, 'provider_app_attest_verifications', 'SELECT')
   AND has_table_privilege(current_user, 'provider_app_attest_verifications', 'INSERT')
   AND NOT has_table_privilege(current_user, 'provider_app_attest_verifications', 'UPDATE')
   AND NOT has_table_privilege(current_user, 'provider_app_attest_verifications', 'DELETE')
   AND NOT has_table_privilege(current_user, 'provider_app_attest_verifications', 'TRUNCATE')
   AND NOT EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.member WHERE r.rolname = current_user);
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


def recorder_dsn(onboarding_dsn: str, password: str) -> str:
    parsed = urlparse(onboarding_dsn)
    if parsed.scheme not in ("postgres", "postgresql") or not parsed.hostname:
        raise ProvisionError(f"{ONBOARDING_KEY} is not a postgres:// URL with a host")
    host = parsed.hostname
    if ":" in host:
        host = f"[{host}]"
    netloc = f"{ROLE}:{quote(password, safe='')}@{host}"
    if parsed.port is not None:
        netloc += f":{parsed.port}"
    return urlunparse((parsed.scheme, netloc, parsed.path, "", parsed.query, ""))


def service_entry(name: str, dsn: str) -> str:
    parsed = urlparse(dsn)
    if parsed.scheme not in ("postgres", "postgresql"):
        raise ProvisionError("unsupported Postgres DSN scheme")
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
    result = run_psql(psql, admin, ["-f", sql_path], extra_env={"APP_ATTEST_RECORDER_PASSWORD_SCRAM": scram_sha256_verifier(password)})
    if result.returncode != 0:
        # psql output names the failing check; it never contains the plaintext.
        raise ProvisionError(f"bootstrap SQL failed (rc={result.returncode}): {(result.stdout + result.stderr).strip()[-400:]}")
    dsn = recorder_dsn(onboarding, password)
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
    args = parser.parse_args(argv)
    try:
        outcome = provision(args.env_file, args.sql, args.psql, args.rotate)
    except (ProvisionError, OSError, subprocess.SubprocessError) as exc:
        print(f"app_attest_recorder provisioning failed: {exc}", file=sys.stderr)
        return 1
    print(f"app_attest_recorder {outcome}; {ENV_KEY} is set in {args.env_file}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
