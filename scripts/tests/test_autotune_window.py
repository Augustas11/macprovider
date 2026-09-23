#!/usr/bin/env python3
"""Hermetic tests for scripts/autotune_window.py (no root, tmp dirs only)."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("autotune_window", REPO / "scripts" / "autotune_window.py")
assert SPEC is not None and SPEC.loader is not None
aw = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(aw)

UID = os.getuid()
GID = os.getgid()


class ComputeWindowTests(unittest.TestCase):
    def test_prepend_outgoing(self) -> None:
        self.assertEqual(
            aw.compute_window(["releases/b", "releases/c"], "releases/a", "releases/new"),
            ["releases/a", "releases/b", "releases/c"],
        )

    def test_incoming_equals_outgoing_is_noop(self) -> None:
        existing = ["releases/b", "releases/c"]
        self.assertEqual(aw.compute_window(existing, "releases/x", "releases/x"), existing)

    def test_incoming_never_in_window(self) -> None:
        got = aw.compute_window(["releases/new", "releases/b"], "releases/a", "releases/new")
        self.assertEqual(got, ["releases/a", "releases/b"])
        got = aw.compute_window(["releases/new"], None, "releases/new")
        self.assertEqual(got, [])

    def test_dedupe_preserves_order(self) -> None:
        got = aw.compute_window(["releases/b", "releases/a", "releases/b"], "releases/a", "releases/n")
        self.assertEqual(got, ["releases/a", "releases/b"])

    def test_truncates_to_three_keeping_predecessor(self) -> None:
        got = aw.compute_window(["releases/b", "releases/c", "releases/d"], "releases/a", "releases/n")
        self.assertEqual(got, ["releases/a", "releases/b", "releases/c"])
        self.assertEqual(got[0], "releases/a")

    def test_outgoing_none_or_empty_omitted(self) -> None:
        self.assertEqual(aw.compute_window(["releases/b"], None, "releases/n"), ["releases/b"])
        self.assertEqual(aw.compute_window(["releases/b"], "", "releases/n"), ["releases/b"])

    def test_invalid_entries_rejected(self) -> None:
        for bad in ("releases/", "releases/../x", "releases/a/b", "other/a", "releases/.hidden",
                    "releases/a b", "releases/" + "a" * 193, " releases/a"):
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError):
                    aw.compute_window([bad], "releases/a", "releases/n")
                with self.assertRaises(ValueError):
                    aw.compute_window([], bad, "releases/n")
                with self.assertRaises(ValueError):
                    aw.compute_window([], "releases/a", bad)


class FileTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name) / "autotune"
        self.root.mkdir(mode=0o755)
        os.chmod(self.root, 0o755)
        (self.root / "releases").mkdir()
        os.symlink("releases/cur", self.root / "current")
        self.pt = self.root / aw.FILE_NAME

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def write(self, entries: list[str], **kw) -> None:
        aw.write_window(str(self.root), entries, group=GID, required_uid=UID, **kw)

    def cli(self, *argv: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = aw.main([*argv, "--root", str(self.root), "--required-uid", str(UID), "--group", str(GID)])
        return rc, out.getvalue(), err.getvalue()

    def test_write_and_read_roundtrip(self) -> None:
        self.write(["releases/a", "releases/b"])
        self.assertEqual(self.pt.read_text(), "releases/a\nreleases/b\n")
        self.assertEqual(self.pt.stat().st_mode & 0o777, 0o640)
        fd = aw.open_root(str(self.root), required_uid=UID)
        try:
            self.assertEqual(aw.read_window(fd, required_uid=UID), ["releases/a", "releases/b"])
        finally:
            os.close(fd)
        self.assertEqual([p.name for p in self.root.iterdir() if ".tmp." in p.name], [])

    def test_read_window_skips_blank_and_comments(self) -> None:
        self.pt.write_text("# header\n\n  releases/a  \nreleases/b")
        fd = aw.open_root(str(self.root), required_uid=UID)
        try:
            self.assertEqual(aw.read_window(fd, required_uid=UID), ["releases/a", "releases/b"])
        finally:
            os.close(fd)

    def test_four_line_existing_rejected(self) -> None:
        self.pt.write_text("releases/a\nreleases/b\nreleases/c\nreleases/d\n")
        fd = aw.open_root(str(self.root), required_uid=UID)
        try:
            with self.assertRaises(aw.WindowError):
                aw.read_window(fd, required_uid=UID)
        finally:
            os.close(fd)
        rc, _, err = self.cli("plan", "--incoming", "releases/n")
        self.assertNotEqual(rc, 0)
        self.assertIn("max 3", err)

    def test_invalid_existing_entry_rejected(self) -> None:
        self.pt.write_text("releases/../etc\n")
        rc, _, err = self.cli("plan", "--incoming", "releases/n")
        self.assertNotEqual(rc, 0)
        self.assertIn("invalid", err)

    def test_symlinked_previous_target_refused(self) -> None:
        target = Path(self._tmp.name) / "elsewhere"
        target.write_text("releases/a\n")
        os.symlink(target, self.pt)
        with self.assertRaises(aw.WindowError):
            self.write(["releases/b"])
        self.assertEqual(target.read_text(), "releases/a\n")
        rc, _, _ = self.cli("plan", "--incoming", "releases/n")
        self.assertNotEqual(rc, 0)

    def test_symlinked_root_refused(self) -> None:
        link = Path(self._tmp.name) / "link-root"
        os.symlink(self.root, link)
        with self.assertRaises(aw.WindowError):
            aw.write_window(str(link), ["releases/a"], group=GID, required_uid=UID)
        self.assertFalse(self.pt.exists())

    def test_wrong_owner_refused(self) -> None:
        with self.assertRaises(aw.WindowError):
            aw.write_window(str(self.root), ["releases/a"], group=GID, required_uid=UID + 1)
        self.assertFalse(self.pt.exists())

    def test_cas_mismatch_refused(self) -> None:
        self.pt.write_text("releases/old\n")
        with self.assertRaises(aw.WindowError):
            self.write(["releases/a"], expect_current="releases/other")
        self.assertEqual(self.pt.read_text(), "releases/old\n")
        rc, _, err = self.cli("apply", "--incoming", "releases/n", "--expect-current", "releases/other")
        self.assertNotEqual(rc, 0)
        self.assertIn("expected", err)
        self.assertEqual(self.pt.read_text(), "releases/old\n")

    def test_apply_prepends_current(self) -> None:
        self.pt.write_text("releases/p1\nreleases/p2\nreleases/p3\n")
        rc, out, err = self.cli("apply", "--incoming", "releases/n", "--expect-current", "releases/cur")
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.pt.read_text(), "releases/cur\nreleases/p1\nreleases/p2\n")
        self.assertTrue(json.loads(out)["changed"])

    def test_apply_noop_when_incoming_is_current(self) -> None:
        self.pt.write_bytes(b"# keep\nreleases/p1\n")
        before = os.stat(self.pt)
        rc, out, err = self.cli("apply", "--incoming", "releases/cur", "--expect-current", "releases/cur")
        self.assertEqual(rc, 0, err)
        self.assertFalse(json.loads(out)["changed"])
        self.assertEqual(self.pt.read_bytes(), b"# keep\nreleases/p1\n")
        self.assertEqual(os.stat(self.pt).st_ino, before.st_ino)

    def test_empty_result_removes_file(self) -> None:
        self.pt.write_text("releases/n\n")
        os.unlink(self.root / "current")
        rc, out, err = self.cli("apply", "--incoming", "releases/n", "--expect-current", "releases/cur")
        self.assertNotEqual(rc, 0)  # no current: CAS refuses
        self.write([])
        self.assertFalse(self.pt.exists())
        self.write([])  # idempotent on missing file

    def test_restore_writes_exact_entries(self) -> None:
        self.pt.write_text("releases/x\n")
        src = Path(self._tmp.name) / "backup"
        src.write_text("releases/b\nreleases/a\nreleases/b\n")
        rc, out, err = self.cli("restore", "--from-file", str(src), "--expect-current", "releases/cur")
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.pt.read_text(), "releases/b\nreleases/a\nreleases/b\n")
        src.write_text("")
        rc, _, err = self.cli("restore", "--from-file", str(src), "--expect-current", "releases/cur")
        self.assertEqual(rc, 0, err)
        self.assertFalse(self.pt.exists())
        rc, _, _ = self.cli("restore", "--from-file", str(src), "--expect-current", "releases/nope")
        self.assertNotEqual(rc, 0)

    def test_plan_json_shape(self) -> None:
        self.pt.write_text("releases/p1\n")
        rc, out, err = self.cli("plan", "--incoming", "releases/n")
        self.assertEqual(rc, 0, err)
        self.assertEqual(json.loads(out), {
            "current": "releases/cur",
            "incoming": "releases/n",
            "window_before": ["releases/p1"],
            "window_after": ["releases/cur", "releases/p1"],
            "changed": True,
        })
        self.assertEqual(self.pt.read_text(), "releases/p1\n")
        rc, out, _ = self.cli("plan", "--incoming", "releases/n", "--outgoing", "releases/o")
        self.assertEqual(json.loads(out)["window_after"], ["releases/o", "releases/p1"])

    def test_go_compat_fixture_matches_writer(self) -> None:
        fixture = REPO / "phase4-coordinator/internal/buyer/testdata/autotune_window_previous_target.txt"
        self.pt.write_text("releases/v2-b\nreleases/v1_a\n")
        os.unlink(self.root / "current")
        os.symlink("releases/v3.c", self.root / "current")
        rc, _, err = self.cli("apply", "--incoming", "releases/v4", "--expect-current", "releases/v3.c")
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.pt.read_bytes(), fixture.read_bytes())


if __name__ == "__main__":
    unittest.main()
