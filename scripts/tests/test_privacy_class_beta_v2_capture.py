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


def set_first_provider_id(path: Path, provider_id: str) -> None:
    with sqlite3.connect(path) as db:
        db.execute(f'UPDATE "{V2_DB_TABLES[0]}" SET "provider_id" = ?', (provider_id,))


def open_wal_writer(path: Path) -> sqlite3.Connection:
    db = sqlite3.connect(path)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA wal_autocheckpoint=0")
    return db


def insert_provider_row(db: sqlite3.Connection, provider_id: str) -> None:
    db.execute(
        'INSERT INTO "privacy_class_enrollment" ("provider_id", "identity_fingerprint") VALUES (?, ?)',
        (provider_id, f"{provider_id}-fingerprint"),
    )
    db.commit()


def remove_sqlite_sidecars(path: Path) -> None:
    with sqlite3.connect(path) as db:
        db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        db.execute("PRAGMA journal_mode=DELETE")
    for suffix in ("-wal", "-shm"):
        sidecar = Path(f"{path}{suffix}")
        if sidecar.exists():
            sidecar.unlink()


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

    def test_captures_committed_wal_row_while_writer_connection_stays_open(self) -> None:
        db_path = self.root / "wal-live.db"
        create_db(db_path)
        writer = open_wal_writer(db_path)
        try:
            insert_provider_row(writer, "wal-only-provider")
            self.assertTrue(Path(f"{db_path}-wal").exists())
            self.assertGreater(Path(f"{db_path}-wal").stat().st_size, 0)
            fd, source, st = capture.open_source_fd(db_path, capture.MAX_DB_SOURCE_BYTES)
            try:
                snapshot = capture.export_snapshot(source, fd, st)
            finally:
                os.close(fd)
            rows = snapshot["tables"]["privacy_class_enrollment"]["rows"]
            self.assertIn("wal-only-provider", {row["provider_id"] for row in rows})
        finally:
            writer.close()

    def test_captures_pinned_db_when_source_path_is_temporarily_swapped_during_snapshot_open(self) -> None:
        db_path = self.root / "live.db"
        attacker_path = self.root / "attacker.db"
        create_db(db_path)
        create_db(attacker_path)
        set_first_provider_id(db_path, "trusted-pinned-source")
        set_first_provider_id(attacker_path, "attacker-source")
        original_open = capture.open_readonly_db

        def swapping_open(path: Path) -> sqlite3.Connection:
            trusted_hold = self.root / "trusted-source.hold"
            db_path.rename(trusted_hold)
            attacker_path.rename(db_path)
            try:
                return original_open(path)
            finally:
                db_path.rename(attacker_path)
                trusted_hold.rename(db_path)

        fd, source, st = capture.open_source_fd(db_path, capture.MAX_DB_SOURCE_BYTES)
        try:
            capture.open_readonly_db = swapping_open
            snapshot = capture.export_snapshot(source, fd, st)
            rows = snapshot["tables"]["privacy_class_enrollment"]["rows"]
            self.assertIn("trusted-pinned-source", {row["provider_id"] for row in rows})
            self.assertNotIn("attacker-source", {row["provider_id"] for row in rows})
        finally:
            capture.open_readonly_db = original_open
            os.close(fd)

    def test_refuses_main_db_metadata_change_after_snapshot_source_copy(self) -> None:
        db_path = self.root / "main-delta.db"
        create_db(db_path)
        original_copy = capture.copy_fd_to_path

        def mutating_copy(fd: int, expected: os.stat_result, target: Path, label: str, max_bytes: int, *, allow_empty: bool) -> None:
            original_copy(fd, expected, target, label, max_bytes, allow_empty=allow_empty)
            if label == "SQLite source":
                os.utime(db_path, None)

        fd, source, st = capture.open_source_fd(db_path, capture.MAX_DB_SOURCE_BYTES)
        try:
            capture.copy_fd_to_path = mutating_copy
            with self.assertRaisesRegex(capture.CaptureError, "SQLite source changed"):
                capture.export_snapshot(source, fd, st)
        finally:
            capture.copy_fd_to_path = original_copy
            os.close(fd)

    def test_refuses_wal_delta_after_each_snapshot_copy_phase(self) -> None:
        for label in ("SQLite source", "SQLite sidecar -wal", "SQLite sidecar -shm"):
            with self.subTest(label=label):
                db_path = self.root / f"{label.replace(' ', '_').replace('-', '')}.db"
                create_db(db_path)
                writer = open_wal_writer(db_path)
                insert_provider_row(writer, f"before-{label}")
                self.assertTrue(Path(f"{db_path}-wal").exists())
                self.assertTrue(Path(f"{db_path}-shm").exists())
                original_copy = capture.copy_fd_to_path

                def mutating_copy(fd: int, expected: os.stat_result, target: Path, copy_label: str, max_bytes: int, *, allow_empty: bool) -> None:
                    original_copy(fd, expected, target, copy_label, max_bytes, allow_empty=allow_empty)
                    if copy_label == label:
                        insert_provider_row(writer, f"after-{label}")

                fd, source, st = capture.open_source_fd(db_path, capture.MAX_DB_SOURCE_BYTES)
                try:
                    capture.copy_fd_to_path = mutating_copy
                    with self.assertRaisesRegex(capture.CaptureError, "changed while"):
                        capture.export_snapshot(source, fd, st)
                finally:
                    capture.copy_fd_to_path = original_copy
                    os.close(fd)
                    writer.close()

    def test_refuses_sidecar_appearing_after_snapshot_source_copy(self) -> None:
        db_path = self.root / "sidecar-appears.db"
        create_db(db_path)
        remove_sqlite_sidecars(db_path)
        original_copy = capture.copy_fd_to_path

        def mutating_copy(fd: int, expected: os.stat_result, target: Path, label: str, max_bytes: int, *, allow_empty: bool) -> None:
            original_copy(fd, expected, target, label, max_bytes, allow_empty=allow_empty)
            if label == "SQLite source":
                Path(f"{db_path}-wal").write_bytes(b"new wal")

        fd, source, st = capture.open_source_fd(db_path, capture.MAX_DB_SOURCE_BYTES)
        try:
            capture.copy_fd_to_path = mutating_copy
            with self.assertRaisesRegex(capture.CaptureError, "appeared while capturing snapshot"):
                capture.export_snapshot(source, fd, st)
        finally:
            capture.copy_fd_to_path = original_copy
            os.close(fd)

    def test_refuses_oversize_sqlite_sidecar(self) -> None:
        db_path = self.root / "oversize-sidecar.db"
        create_db(db_path)
        sidecar = Path(f"{db_path}-wal")
        sidecar.write_bytes(b"")
        with sidecar.open("r+b") as handle:
            handle.truncate(capture.MAX_DB_SIDECAR_SOURCE_BYTES + 1)
        fd, source, st = capture.open_source_fd(db_path, capture.MAX_DB_SOURCE_BYTES)
        try:
            with self.assertRaisesRegex(capture.CaptureError, "SQLite sidecar -wal must be at most"):
                capture.export_snapshot(source, fd, st)
        finally:
            os.close(fd)

    def test_export_cleanup_runs_when_rollback_and_close_fail_after_export_error(self) -> None:
        db_path = self.root / "cleanup-error.db"
        create_db(db_path)
        original_open_source_fd = capture.open_source_fd
        original_private_snapshot = capture.private_sqlite_snapshot
        original_open_readonly_db = capture.open_readonly_db
        captured: dict[str, object] = {}
        open_count = 0

        class FailingExportDB:
            def __init__(self, real: sqlite3.Connection) -> None:
                self.real = real

            def execute(self, sql: str, *args: object) -> object:
                if sql == "ROLLBACK":
                    try:
                        self.real.execute(sql)
                    finally:
                        raise RuntimeError("rollback cleanup failed")
                raise capture.CaptureError("export boom")

            def close(self) -> None:
                try:
                    self.real.close()
                finally:
                    raise RuntimeError("close cleanup failed")

        def tracking_open_source_fd(path: Path, max_bytes: int) -> tuple[int, Path, os.stat_result]:
            fd, resolved, st = original_open_source_fd(path, max_bytes)
            captured["fd"] = fd
            return fd, resolved, st

        def tracking_private_snapshot(path: Path, source_fd: int, source_st: os.stat_result) -> tuple[Path, tempfile.TemporaryDirectory[str]]:
            snapshot, tmp = original_private_snapshot(path, source_fd, source_st)
            captured["tmp"] = Path(tmp.name)
            return snapshot, tmp

        def failing_export_open(path: Path) -> sqlite3.Connection:
            nonlocal open_count
            open_count += 1
            real = original_open_readonly_db(path)
            if open_count == 1:
                return real
            return FailingExportDB(real)  # type: ignore[return-value]

        try:
            capture.open_source_fd = tracking_open_source_fd
            capture.private_sqlite_snapshot = tracking_private_snapshot
            capture.open_readonly_db = failing_export_open
            with self.assertRaisesRegex(capture.CaptureError, "export boom"):
                capture.export_snapshot(db_path)
            self.assertFalse(captured["tmp"].exists())  # type: ignore[union-attr]
            with self.assertRaises(OSError):
                os.fstat(captured["fd"])  # type: ignore[arg-type]
        finally:
            capture.open_source_fd = original_open_source_fd
            capture.private_sqlite_snapshot = original_private_snapshot
            capture.open_readonly_db = original_open_readonly_db

    def test_private_snapshot_cleans_temp_when_sidecar_close_fails(self) -> None:
        db_path = self.root / "sidecar-close.db"
        create_db(db_path)
        writer = open_wal_writer(db_path)
        insert_provider_row(writer, "sidecar-close-row")
        original_collect = capture.collect_sqlite_sidecars
        original_temp_parent = capture.private_temp_parent
        original_close = os.close
        sidecar_fds: list[int] = []

        def tracking_collect(path: Path, source_fd: int, source_st: os.stat_result) -> tuple[dict[str, tuple[int, os.stat_result]], dict[str, os.stat_result | None]]:
            sidecars, identities = original_collect(path, source_fd, source_st)
            sidecar_fds.extend(fd for fd, _st in sidecars.values())
            return sidecars, identities

        def failing_close(fd: int) -> None:
            if fd in sidecar_fds:
                raise OSError("sidecar close failed")
            original_close(fd)

        fd, source, st = capture.open_source_fd(db_path, capture.MAX_DB_SOURCE_BYTES)
        try:
            capture.collect_sqlite_sidecars = tracking_collect
            capture.private_temp_parent = lambda: self.root
            capture.os.close = failing_close
            with self.assertRaisesRegex(OSError, "sidecar close failed"):
                capture.private_sqlite_snapshot(source, fd, st)
            self.assertEqual([], list(self.root.glob("privacy-capture-sqlite-*")))
        finally:
            capture.collect_sqlite_sidecars = original_collect
            capture.private_temp_parent = original_temp_parent
            capture.os.close = original_close
            for sidecar_fd in sidecar_fds:
                try:
                    original_close(sidecar_fd)
                except OSError:
                    pass
            original_close(fd)
            writer.close()

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
