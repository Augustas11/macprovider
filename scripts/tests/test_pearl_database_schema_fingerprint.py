#!/usr/bin/env python3
"""Run: PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_pearl_database_schema_fingerprint"""
from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "pearl-database-schema-fingerprint.py"


class DatabaseSchemaFingerprintTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp.name)
        self.git("init", "-q")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "user.name", "fixture")
        self.git("config", "commit.gpgsign", "false")
        files = {
            "phase4-coordinator/go.mod": "module coordinator\n",
            "phase4-coordinator/go.sum": "modernc.org/sqlite v1.0.0 h1:x\n",
            "phase5-gateway/go.mod": "module gateway\n",
            "phase5-gateway/go.sum": "",
            "phase4-coordinator/internal/billing/store.go": 'package billing\nconst ddl = "CREATE TABLE IF NOT EXISTS t (a)"\n',
            "phase4-coordinator/internal/billing/types.go": "package billing\ntype Row struct{ A int }\n",
            "phase4-coordinator/internal/billing/store_test.go": 'package billing\nconst x = "DROP TABLE t"\n',
            "phase4-coordinator/internal/router/route.go": "package router\nfunc Route() {}\n",
            "phase5-gateway/internal/storage/lower.go": 'package storage\nconst q = "alter table q add column b"\n',
            "phase5-gateway/internal/http/handler.go": "package http\nfunc Handle() {}\n",
            "phase4-coordinator/internal/payout/migrations/0001.sql": "create table p (a);\n",
            "docs/notes.md": "not fingerprinted\n",
        }
        for path, text in files.items():
            self.write(path, text)
        self.commit()

    def tearDown(self):
        self.temp.cleanup()

    def git(self, *args: str) -> str:
        return subprocess.run(
            ["git", "-C", str(self.repo), *args], check=True, capture_output=True, text=True
        ).stdout

    def write(self, path: str, text: str) -> None:
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def commit(self) -> None:
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "fixture")

    def fingerprint(self, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--repo", str(self.repo), *extra],
            capture_output=True,
            text=True,
        )

    def test_covers_every_non_test_server_file(self):
        result = self.fingerprint("--explain")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout.strip(), r"^[0-9a-f]{64}$")
        self.assertEqual(
            result.stderr.split(),
            [
                "phase4-coordinator/go.mod",
                "phase4-coordinator/go.sum",
                "phase4-coordinator/internal/billing/store.go",
                "phase4-coordinator/internal/billing/types.go",
                "phase4-coordinator/internal/payout/migrations/0001.sql",
                "phase4-coordinator/internal/router/route.go",
                "phase5-gateway/go.mod",
                "phase5-gateway/go.sum",
                "phase5-gateway/internal/http/handler.go",
                "phase5-gateway/internal/storage/lower.go",
            ],
        )

    def test_changes_whenever_server_source_changes(self):
        baseline = self.fingerprint().stdout
        for path, text, changes in (
            ("phase4-coordinator/internal/billing/store_test.go", "package billing\n", False),
            ("phase4-coordinator/internal/router/testdata/golden.json", "{}\n", False),
            ("docs/notes.md", "edited\n", False),
            ("phase4-coordinator/internal/router/route.go", "package router\nfunc Route() { _ = 1 }\n", True),
            ("phase4-coordinator/internal/billing/types.go", "package billing\ntype Row struct{ A, B int }\n", True),
            ("phase5-gateway/go.sum", "modernc.org/sqlite v1.1.0 h1:y\n", True),
            ("phase5-gateway/internal/http/new.go", "package http\n", True),
        ):
            with self.subTest(path):
                self.write(path, text)
                self.commit()
                current = self.fingerprint().stdout
                self.assertEqual(current != baseline, changes)
                baseline = current

    def test_fingerprint_is_read_from_the_commit_not_the_working_tree(self):
        committed = self.fingerprint().stdout
        self.write("phase4-coordinator/internal/billing/store.go", "package billing\n")
        self.assertEqual(self.fingerprint().stdout, committed)
        head = self.git("rev-parse", "HEAD").strip()
        self.commit()
        self.assertNotEqual(self.fingerprint().stdout, committed)
        self.assertEqual(self.fingerprint("--commit", head).stdout, committed)

    def test_missing_module_file_fails_closed(self):
        self.git("rm", "-q", "phase5-gateway/go.sum")
        self.git("commit", "-q", "-m", "drop go.sum")
        result = self.fingerprint()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("go.sum", result.stderr)


if __name__ == "__main__":
    unittest.main()
