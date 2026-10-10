"""app_attest_recorder provisioning (SPEC-033 §2.7): no secret in argv or output."""

from __future__ import annotations

import base64
import hashlib
import hmac
import importlib.util
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from urllib.parse import unquote, urlparse

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "phase4-coordinator/dist/provision-app-attest-recorder.py"
SQL = ROOT / "phase4-coordinator/dist/app-attest-recorder-bootstrap.sql"

spec = importlib.util.spec_from_file_location("provision_app_attest_recorder", SCRIPT)
prov = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prov)

# A fake psql: logs argv, env names, the service file mode and the scram env
# value; answers the verification query with "t" unless FAKE_PSQL_VERIFY=f.
FAKE_PSQL = r"""#!/usr/bin/env python3
import json, os, stat, sys
log = os.environ["FAKE_PSQL_LOG"]
svc = os.environ.get("PGSERVICEFILE", "")
entry = {
    "argv": sys.argv[1:],
    "env_names": sorted(os.environ),
    "scram": os.environ.get("APP_ATTEST_RECORDER_PASSWORD_SCRAM", ""),
    "service_mode": oct(stat.S_IMODE(os.stat(svc).st_mode)) if svc else "",
    "service": open(svc).read() if svc else "",
}
with open(log, "a") as f:
    f.write(json.dumps(entry) + "\n")
if "-f" not in sys.argv:
    sys.stdin.read()
    print(os.environ.get("FAKE_PSQL_VERIFY", "t"))
if "-f" in sys.argv and os.environ.get("FAKE_PSQL_RC", "0") != "0":
    print("ERROR: statement ALTER ROLE ... PASSWORD '" + os.environ.get("APP_ATTEST_RECORDER_PASSWORD_SCRAM", "") + "'")
sys.exit(int(os.environ.get("FAKE_PSQL_RC", "0")) if "-f" in sys.argv else 0)
"""


class Helpers(unittest.TestCase):
    def test_recorder_dsn_keeps_host_db_and_options(self) -> None:
        dsn = prov.recorder_dsn("postgres://provider_onboarding:x@db.internal:5433/stats?sslmode=require", "p/w+d")
        parsed = urlparse(dsn)
        self.assertEqual((parsed.username, unquote(parsed.password), parsed.hostname, parsed.port, parsed.path, parsed.query),
                         ("app_attest_recorder", "p/w+d", "db.internal", 5433, "/stats", "sslmode=require"))
        with self.assertRaises(prov.ProvisionError):
            prov.recorder_dsn("mysql://h/db", "p")
        for query in ("user=postgres", "password=x", "sslmode=disable&service=other", "host=evil"):
            with self.assertRaises(prov.ProvisionError):
                prov.recorder_dsn(f"postgres://u:p@h/db?{query}", "p")
            with self.assertRaises(prov.ProvisionError):
                prov.service_entry("s", f"postgres://u:p@h/db?{query}")
        with self.assertRaises(prov.ProvisionError):
            prov.recorder_dsn("postgres://u:p@h:notaport/db", "p")

    def test_scram_verifier_shape_and_keys(self) -> None:
        salt = b"0123456789abcdef"
        verifier = prov.scram_sha256_verifier("pencil", salt=salt, iterations=4096)
        head, keys = verifier.split("$")[1:]
        self.assertEqual(head, "4096:" + base64.b64encode(salt).decode())
        salted = hashlib.pbkdf2_hmac("sha256", b"pencil", salt, 4096)
        stored = hashlib.sha256(hmac.new(salted, b"Client Key", hashlib.sha256).digest()).digest()
        self.assertEqual(keys.split(":")[0], base64.b64encode(stored).decode())
        self.assertNotIn("pencil", verifier)

    def test_write_env_value_replaces_and_keeps_mode(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            path = Path(d, "coordinator.env")
            path.write_text("A=1\nONBOARDING_APP_ATTEST_RECORD_DSN=old\n# c\nB='2'\n")
            os.chmod(path, 0o640)
            prov.write_env_value(str(path), "ONBOARDING_APP_ATTEST_RECORD_DSN", "new")
            self.assertEqual(path.read_text(), "A=1\n# c\nB='2'\nONBOARDING_APP_ATTEST_RECORD_DSN=new\n")
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o640)
            self.assertEqual(sorted(os.listdir(d)), ["coordinator.env"])
            with self.assertRaises(prov.ProvisionError):
                prov.write_env_value(str(path), "K", "a\nb")


class ProvisionWithFakePsql(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir)
        self.psql = Path(self.dir, "psql")
        self.psql.write_text(FAKE_PSQL)
        self.psql.chmod(0o755)
        self.log = Path(self.dir, "psql.log")
        self.env = Path(self.dir, "coordinator.env")
        self.env.write_text(
            "COORDINATOR_PARTNER_KEYS_ADMIN_DSN=postgres://admin:adminpw@127.0.0.1:5432/stats?sslmode=disable\n"
            "ONBOARDING_POSTGRES_DSN=postgres://provider_onboarding:obpw@127.0.0.1:5432/stats?sslmode=disable\n")
        os.chmod(self.env, 0o600)
        os.environ["FAKE_PSQL_LOG"] = str(self.log)
        self.addCleanup(lambda: [os.environ.pop(k, None) for k in ("FAKE_PSQL_LOG", "FAKE_PSQL_VERIFY", "FAKE_PSQL_RC")])

    def run_script(self, *extra: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, "-I", str(SCRIPT), "--env-file", str(self.env), "--sql", str(SQL), "--psql", str(self.psql), *extra],
                              capture_output=True, text=True, check=False, env=os.environ.copy())

    def calls(self) -> list[dict]:
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_provisions_without_leaking_the_password(self) -> None:
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        values = prov.parse_env_file(str(self.env))
        dsn = values["ONBOARDING_APP_ATTEST_RECORD_DSN"]
        password = unquote(urlparse(dsn).password)
        self.assertGreaterEqual(len(password), 40)
        self.assertEqual(urlparse(dsn).username, "app_attest_recorder")
        self.assertNotIn(password, result.stdout + result.stderr)
        self.assertEqual(stat.S_IMODE(self.env.stat().st_mode), 0o600)
        calls = self.calls()
        self.assertEqual(len(calls), 2)
        bootstrap, verify = calls
        self.assertEqual(bootstrap["argv"][-2:], ["-f", str(SQL)])
        self.assertIn("user=admin", bootstrap["service"])
        self.assertTrue(bootstrap["scram"].startswith("SCRAM-SHA-256$4096:"))
        self.assertIn("user=app_attest_recorder", verify["service"])
        for call in calls:
            self.assertEqual(call["service_mode"], "0o600")
            self.assertFalse(any(password in a or "adminpw" in a for a in call["argv"]), call["argv"])
            self.assertNotIn(password, call["scram"])
        self.assertNotIn("PGPASSWORD", bootstrap["env_names"])

        # A second run finds the working DSN and changes nothing.
        before = self.env.read_text()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already provisioned", result.stdout)
        self.assertEqual(self.env.read_text(), before)
        self.assertEqual(len(self.calls()), 3)

        # A set but broken DSN is refused unless --rotate.
        os.environ["FAKE_PSQL_VERIFY"] = "f"
        self.assertEqual(self.run_script().returncode, 1)
        self.assertEqual(self.env.read_text(), before)
        os.environ["FAKE_PSQL_VERIFY"] = "t"
        self.assertEqual(self.run_script("--rotate").returncode, 0)
        self.assertNotEqual(prov.parse_env_file(str(self.env))["ONBOARDING_APP_ATTEST_RECORD_DSN"], dsn)

    def test_bootstrap_failure_leaves_env_file_untouched(self) -> None:
        before = self.env.read_text()
        os.environ["FAKE_PSQL_RC"] = "3"
        result = self.run_script()
        self.assertEqual(result.returncode, 1)
        self.assertIn("bootstrap SQL failed (rc=3)", result.stderr)
        # Raw psql output (which could quote statements) is not echoed.
        self.assertNotIn("SCRAM-SHA-256", result.stderr)
        self.assertEqual(self.env.read_text(), before)

    def test_check_reports_absent_valid_invalid(self) -> None:
        def check() -> subprocess.CompletedProcess:
            return self.run_script("--check")
        result = check()
        self.assertEqual((result.returncode, result.stdout.strip()), (10, "absent"))
        self.assertEqual(self.run_script().returncode, 0)
        result = check()
        self.assertEqual((result.returncode, result.stdout.strip()), (0, "valid"))
        os.environ["FAKE_PSQL_VERIFY"] = "f"
        result = check()
        self.assertEqual((result.returncode, result.stdout.strip()), (11, "invalid"))
        password = unquote(urlparse(prov.parse_env_file(str(self.env))["ONBOARDING_APP_ATTEST_RECORD_DSN"]).password)
        self.assertNotIn(password, result.stdout + result.stderr)

    def test_forbidden_onboarding_query_fails_before_any_sql(self) -> None:
        self.env.write_text(
            "COORDINATOR_PARTNER_KEYS_ADMIN_DSN=postgres://admin:adminpw@127.0.0.1:5432/stats\n"
            "ONBOARDING_POSTGRES_DSN=postgres://provider_onboarding:obpw@127.0.0.1:5432/stats?user=postgres\n")
        result = self.run_script()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.calls(), [])

    def test_missing_admin_dsn_is_refused(self) -> None:
        self.env.write_text("ONBOARDING_POSTGRES_DSN=postgres://u:p@h/db\n")
        result = self.run_script()
        self.assertEqual(result.returncode, 1)
        self.assertIn("COORDINATOR_PARTNER_KEYS_ADMIN_DSN", result.stderr)
        self.assertEqual(self.calls(), [])


@unittest.skipUnless(os.environ.get("MACPROVIDER_STATS_TEST_PG_HOSTPORT") and shutil.which("psql"),
                     "set MACPROVIDER_STATS_TEST_PG_HOSTPORT (disposable cluster, superuser postgres) to run against Postgres")
class ProvisionAgainstPostgres(unittest.TestCase):
    def test_bootstrap_sql_and_provisioning(self) -> None:
        hostport = os.environ["MACPROVIDER_STATS_TEST_PG_HOSTPORT"]
        db = f"app_attest_prov_{int(time.time() * 1000)}"
        admin = f"postgres://postgres@{hostport}/{db}?sslmode=disable"
        maint = f"postgres://postgres@{hostport}/postgres?sslmode=disable"

        def sql(dsn: str, text: str) -> str:
            out = subprocess.run(["psql", dsn, "-v", "ON_ERROR_STOP=1", "-qAtX"], input=text, capture_output=True, text=True, check=True)
            return out.stdout.strip()

        sql(maint, f"CREATE DATABASE {db};")
        self.addCleanup(lambda: sql(maint, f"DROP DATABASE IF EXISTS {db};"))
        # The migration-031 shape the bootstrap expects, plus drift to repair.
        sql(admin, """
DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_attest_recorder') THEN CREATE ROLE app_attest_recorder NOLOGIN; END IF; END $$;
CREATE TABLE provider_app_attest_verifications (provider_id TEXT PRIMARY KEY, app_attest_key_id BYTEA NOT NULL UNIQUE);
GRANT SELECT, INSERT, UPDATE ON provider_app_attest_verifications TO app_attest_recorder;
""")
        with tempfile.TemporaryDirectory() as d:
            env = Path(d, "coordinator.env")
            env.write_text(f"COORDINATOR_PARTNER_KEYS_ADMIN_DSN={admin}\nONBOARDING_POSTGRES_DSN=postgres://provider_onboarding:x@{hostport}/{db}?sslmode=disable\n")
            os.chmod(env, 0o600)
            # Plaintext is refused by the SQL itself.
            refused = subprocess.run(["psql", admin, "-v", "ON_ERROR_STOP=1", "-qAtX", "-f", str(SQL)],
                                     env={**os.environ, "APP_ATTEST_RECORDER_PASSWORD_SCRAM": "plaintext"}, capture_output=True, text=True)
            self.assertEqual(refused.returncode, 3, refused.stdout + refused.stderr)
            result = subprocess.run([sys.executable, "-I", str(SCRIPT), "--env-file", str(env), "--sql", str(SQL)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            dsn = prov.parse_env_file(str(env))["ONBOARDING_APP_ATTEST_RECORD_DSN"]
            password = unquote(urlparse(dsn).password)
            stored = sql(admin, "SELECT rolpassword FROM pg_authid WHERE rolname = 'app_attest_recorder';")
            iterations, salt = stored.split("$")[1].split(":")
            self.assertEqual(prov.scram_sha256_verifier(password, base64.b64decode(salt), int(iterations)), stored)
            self.assertEqual(sql(dsn, "SELECT current_user;"), "app_attest_recorder")
            self.assertEqual(sql(admin, "SELECT has_table_privilege('app_attest_recorder', 'provider_app_attest_verifications', 'UPDATE');"), "f")
            self.assertNotIn(password, result.stdout + result.stderr)
            # A column-level write on a trust table fails the policy; --rotate repairs it.
            sql(admin, "CREATE TABLE hardware_verification_trust (trusted_by TEXT); GRANT UPDATE (trusted_by) ON hardware_verification_trust TO app_attest_recorder;")
            run = lambda *a: subprocess.run([sys.executable, "-I", str(SCRIPT), "--env-file", str(env), "--sql", str(SQL), *a], capture_output=True, text=True)
            self.assertEqual(run("--check").returncode, 11)
            self.assertEqual(run("--rotate").returncode, 0)
            self.assertEqual(run("--check").returncode, 0)


if __name__ == "__main__":
    unittest.main()
