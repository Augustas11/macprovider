from __future__ import annotations

import importlib.util
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "lab" / "privacy-class-beta" / "capture-v2-sources.py"
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from privacy_class_beta_journey_evidence import V2_DB_COLUMNS, V2_DB_TABLES, V2_SOURCE_CONTRACT  # noqa: E402

spec = importlib.util.spec_from_file_location("privacy_class_beta_v2_capture", SCRIPT)
assert spec is not None and spec.loader is not None
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)


def run_capture(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True)


def create_db(path: Path, *, missing_column: bool = False, extra_secret: bool = True) -> None:
    db = sqlite3.connect(path)
    try:
        db.execute("PRAGMA journal_mode=WAL")
        for table in V2_DB_TABLES:
            columns = list(V2_DB_COLUMNS[table])
            if missing_column and table == V2_DB_TABLES[0]:
                columns = columns[:-1]
            defs = [f'"{column}" INTEGER' if column.endswith("_unix") or column == "privacy_class" else f'"{column}" TEXT' for column in columns]
            if extra_secret and table == V2_DB_TABLES[0]:
                defs.append('"api_token_secret" TEXT')
            db.execute(f'CREATE TABLE "{table}" ({", ".join(defs)})')
            values = []
            for column in columns:
                if column.endswith("_unix") or column == "privacy_class":
                    values.append(123)
                else:
                    values.append(f"{table}-{column}")
            if extra_secret and table == V2_DB_TABLES[0]:
                values.append("do-not-export")
            marks = ", ".join("?" for _ in values)
            db.execute(f'INSERT INTO "{table}" VALUES ({marks})', values)
        db.commit()
    finally:
        db.close()


def source_for_kind(root: Path, kind: str) -> Path:
    for sources in V2_SOURCE_CONTRACT.values():
        if kind in sources:
            suffix = Path(sources[kind]).suffix
            break
    else:
        raise AssertionError(kind)
    path = root / "sources" / f"{kind}{suffix}"
    path.parent.mkdir(exist_ok=True)
    if suffix == ".pem":
        path.write_text("-----BEGIN PUBLIC KEY-----\nabc\n-----END PUBLIC KEY-----\n")
    elif suffix == ".sig":
        path.write_bytes(f"{kind}-signature".encode())
    else:
        path.write_text('{"cases":[]}\n')
    return path


def capture_all_sources(root: Path, out: Path) -> None:
    db_path = root / "all.db"
    create_db(db_path)
    for sources in V2_SOURCE_CONTRACT.values():
        for kind in sources:
            source = db_path if kind.endswith("_db") or "_db_" in kind or kind.startswith(("enrollment_", "reenroll_")) and kind not in {"enrollment_clients", "reenroll_clients"} else source_for_kind(root, kind)
            completed = run_capture("--out-root", str(out), "--kind", kind, "--source", str(source))
            if completed.returncode != 0:
                raise AssertionError(completed.stderr)


class CaptureV2SourceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.out = self.root / "capture"

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_captures_db_snapshot_with_live_wal_read_transaction_and_allowlist(self) -> None:
        db_path = self.root / "live.db"
        create_db(db_path)
        completed = run_capture("--out-root", str(self.out), "--kind", "auto_db_before", "--source", str(db_path))
        self.assertEqual(0, completed.returncode, completed.stderr)
        raw_path = self.out / V2_SOURCE_CONTRACT["auto-mode.json"]["auto_db_before"]
        doc = json.loads(raw_path.read_text())
        self.assertEqual({"captured_at_unix", "tables"}, set(doc))
        self.assertEqual(set(V2_DB_TABLES), set(doc["tables"]))
        first = doc["tables"][V2_DB_TABLES[0]]
        self.assertEqual(list(V2_DB_COLUMNS[V2_DB_TABLES[0]]), first["columns"])
        self.assertEqual(1, first["row_count"])
        self.assertFalse(first["truncated"])
        self.assertNotIn("api_token_secret", json.dumps(first))
        self.assertNotIn("do-not-export", json.dumps(first))
        self.assertEqual(0o700, self.out.stat().st_mode & 0o777)
        self.assertEqual(0o600, raw_path.stat().st_mode & 0o777)

    def test_refuses_db_source_swap_when_sqlite_connection_opens(self) -> None:
        db_path = self.root / "live.db"
        attacker_path = self.root / "attacker.db"
        create_db(db_path)
        create_db(attacker_path)
        original_connect = capture.sqlite3.connect

        def swapping_connect(*args: object, **kwargs: object) -> sqlite3.Connection:
            db_path.unlink()
            attacker_path.rename(db_path)
            return original_connect(*args, **kwargs)

        fd, source, st = capture.open_source_fd(db_path, capture.MAX_DB_SOURCE_BYTES)
        try:
            capture.sqlite3.connect = swapping_connect
            with self.assertRaises(capture.CaptureError):
                capture.export_snapshot(source, fd, st)
        finally:
            capture.sqlite3.connect = original_connect
            os.close(fd)

    def test_refuses_db_source_replaced_before_sqlite_connection_opens(self) -> None:
        db_path = self.root / "live.db"
        attacker_path = self.root / "attacker.db"
        create_db(db_path)
        create_db(attacker_path)
        fd, source, st = capture.open_source_fd(db_path, capture.MAX_DB_SOURCE_BYTES)
        try:
            db_path.unlink()
            attacker_path.rename(db_path)
            with self.assertRaises(capture.CaptureError):
                capture.export_snapshot(source, fd, st)
        finally:
            os.close(fd)

    def test_refuses_db_source_replaced_after_sqlite_connection_opens(self) -> None:
        db_path = self.root / "live.db"
        attacker_path = self.root / "attacker.db"
        create_db(db_path)
        create_db(attacker_path)
        original_db_columns = capture.db_columns
        replaced = False

        def replacing_db_columns(db: sqlite3.Connection, table: str) -> list[str]:
            nonlocal replaced
            if not replaced:
                db_path.unlink()
                attacker_path.rename(db_path)
                replaced = True
            return original_db_columns(db, table)

        fd, source, st = capture.open_source_fd(db_path, capture.MAX_DB_SOURCE_BYTES)
        try:
            capture.db_columns = replacing_db_columns
            with self.assertRaises(capture.CaptureError):
                capture.export_snapshot(source, fd, st)
        finally:
            capture.db_columns = original_db_columns
            os.close(fd)

    def test_refuses_db_missing_required_allowlisted_column(self) -> None:
        db_path = self.root / "missing.db"
        create_db(db_path, missing_column=True)
        completed = run_capture("--out-root", str(self.out), "--kind", "auto_db_before", "--source", str(db_path))
        self.assertNotEqual(0, completed.returncode)
        self.assertIn("missing required column", completed.stderr)

    def test_refuses_db_snapshot_that_exceeds_bounded_raw_source_size_without_output(self) -> None:
        db_path = self.root / "large.db"
        create_db(db_path)
        payload = "x" * 5000
        with sqlite3.connect(db_path) as db:
            for index in range(260):
                db.execute(
                    'INSERT INTO "privacy_class_enrollment" ("provider_id", "identity_fingerprint") VALUES (?, ?)',
                    (f"provider-{index}", payload),
                )
        completed = run_capture("--out-root", str(self.out), "--kind", "auto_db_before", "--source", str(db_path))
        self.assertNotEqual(0, completed.returncode)
        self.assertIn("DB snapshot exceeds bounded raw-source budget", completed.stderr)
        self.assertFalse((self.out / V2_SOURCE_CONTRACT["auto-mode.json"]["auto_db_before"]).exists())

    def test_refuses_unknown_kind_and_existing_output(self) -> None:
        source = self.root / "launch.json"
        source.write_text('{"cases":[]}\n')
        unknown = run_capture("--out-root", str(self.out), "--kind", "not_a_kind", "--source", str(source))
        self.assertNotEqual(0, unknown.returncode)
        self.assertIn("unknown v2 source kind", unknown.stderr)
        first = run_capture("--out-root", str(self.out), "--kind", "auto_launch", "--source", str(source))
        self.assertEqual(0, first.returncode, first.stderr)
        second = run_capture("--out-root", str(self.out), "--kind", "auto_launch", "--source", str(source))
        self.assertNotEqual(0, second.returncode)
        self.assertIn("refusing to overwrite", second.stderr)

    def test_refuses_duplicate_json_keys_and_oversize_file(self) -> None:
        dup = self.root / "dup.json"
        dup.write_text('{"cases":[],"cases":[]}\n')
        completed = run_capture("--out-root", str(self.out), "--kind", "auto_launch", "--source", str(dup))
        self.assertNotEqual(0, completed.returncode)
        self.assertIn("repeats key", completed.stderr)
        huge = self.root / "huge.json"
        huge.write_bytes(b" " * ((1 << 20) + 1))
        completed = run_capture("--out-root", str(self.root / "huge-out"), "--kind", "auto_launch", "--source", str(huge))
        self.assertNotEqual(0, completed.returncode)
        self.assertIn("source must be between", completed.stderr)

    def test_refuses_symlink_source_and_symlink_output_root(self) -> None:
        source = self.root / "launch.json"
        source.write_text('{"cases":[]}\n')
        link = self.root / "linked.json"
        link.symlink_to(source)
        completed = run_capture("--out-root", str(self.out), "--kind", "auto_launch", "--source", str(link))
        self.assertNotEqual(0, completed.returncode)
        self.assertIn("source must not traverse a symlink", completed.stderr)
        real_out = self.root / "real-out"
        real_out.mkdir(mode=0o700)
        out_link = self.root / "out-link"
        out_link.symlink_to(real_out, target_is_directory=True)
        completed = run_capture("--out-root", str(out_link), "--kind", "auto_launch", "--source", str(source))
        self.assertNotEqual(0, completed.returncode)
        self.assertIn("output root must not traverse a symlink", completed.stderr)

    def test_refuses_existing_intermediate_output_symlink_without_writing_or_chmodding_target(self) -> None:
        source = self.root / "launch.json"
        source.write_text('{"cases":[]}\n')
        self.out.mkdir(mode=0o700)
        outside = self.root / "outside"
        outside.mkdir(mode=0o755)
        (self.out / "evidence").symlink_to(outside, target_is_directory=True)
        before_mode = outside.stat().st_mode & 0o777
        completed = run_capture("--out-root", str(self.out), "--kind", "auto_launch", "--source", str(source))
        self.assertNotEqual(0, completed.returncode)
        self.assertIn("must not be a symlink", completed.stderr)
        self.assertFalse((outside / "v2-raw" / "auto-mode" / "launch.json").exists())
        self.assertEqual(before_mode, outside.stat().st_mode & 0o777)

    def test_refuses_source_intermediate_symlink_and_hardlink(self) -> None:
        real_dir = self.root / "real-source"
        real_dir.mkdir()
        source = real_dir / "launch.json"
        source.write_text('{"cases":[]}\n')
        link_dir = self.root / "source-link"
        link_dir.symlink_to(real_dir, target_is_directory=True)
        completed = run_capture("--out-root", str(self.out), "--kind", "auto_launch", "--source", str(link_dir / "launch.json"))
        self.assertNotEqual(0, completed.returncode)
        self.assertIn("source must not traverse a symlink", completed.stderr)
        hardlink = self.root / "hardlink.json"
        os.link(source, hardlink)
        completed = run_capture("--out-root", str(self.out), "--kind", "auto_launch", "--source", str(source))
        self.assertNotEqual(0, completed.returncode)
        self.assertIn("source must not be hard-linked", completed.stderr)

    def test_public_key_and_signature_file_type_validation(self) -> None:
        private = self.root / "key.pem"
        # Deliberately fake envelope, assembled at runtime so repository secret
        # scanners never see a private-key PEM marker literal.
        private_label = "PRIVATE" + " " + "KEY"
        private.write_text(f"-----BEGIN {private_label}-----\nabc\n-----END {private_label}-----\n")
        completed = run_capture("--out-root", str(self.out), "--kind", "release_public_key", "--source", str(private))
        self.assertNotEqual(0, completed.returncode)
        self.assertIn("public key PEM", completed.stderr)
        public = self.root / "public.pem"
        public.write_text("-----BEGIN PUBLIC KEY-----\nabc\n-----END PUBLIC KEY-----\n")
        completed = run_capture("--out-root", str(self.out), "--kind", "release_public_key", "--source", str(public))
        self.assertEqual(0, completed.returncode, completed.stderr)
        sig = self.root / "release.sig"
        sig.write_bytes(b"signature-bytes")
        completed = run_capture("--out-root", str(self.out), "--kind", "release_signature", "--source", str(sig))
        self.assertEqual(0, completed.returncode, completed.stderr)

    def test_finalize_requires_exact_closed_inventory(self) -> None:
        (self.out / "evidence" / "v2-raw").mkdir(parents=True, mode=0o700)
        os.chmod(self.out, 0o700)
        extra = self.out / "evidence" / "v2-raw" / "extra.json"
        extra.write_text("{}\n")
        completed = run_capture("--out-root", str(self.out), "--finalize")
        self.assertNotEqual(0, completed.returncode)
        self.assertIn("missing closed v2 raw source", completed.stderr)

    def test_finalize_rejects_raw_source_drift_after_capture(self) -> None:
        capture_all_sources(self.root, self.out)
        raw = self.out / V2_SOURCE_CONTRACT["auto-mode.json"]["auto_launch"]
        raw.write_text('{"cases":["mutated"]}\n')
        completed = run_capture("--out-root", str(self.out), "--finalize")
        self.assertNotEqual(0, completed.returncode)
        self.assertIn("finalized source drifted after capture", completed.stderr)

    def test_finalize_rejects_oversize_and_hardlinked_raw_sources(self) -> None:
        capture_all_sources(self.root, self.out)
        raw = self.out / V2_SOURCE_CONTRACT["auto-mode.json"]["auto_launch"]
        raw.unlink()
        raw.write_bytes(b" " * ((1 << 20) + 1))
        completed = run_capture("--out-root", str(self.out), "--finalize")
        self.assertNotEqual(0, completed.returncode)
        self.assertIn("source must be between", completed.stderr)
        raw.unlink()
        replacement = self.root / "replacement.json"
        replacement.write_text('{"cases":[]}\n')
        os.link(replacement, raw)
        completed = run_capture("--out-root", str(self.out), "--finalize")
        self.assertNotEqual(0, completed.returncode)
        self.assertIn("source must not be hard-linked", completed.stderr)


if __name__ == "__main__":
    unittest.main()
