#!/usr/bin/env python3
"""Hermetic tests for scripts/autotune_window.py (no root, tmp dirs only)."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import stat
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
        # realpath: open_root walks from / without following symlinks
        # (macOS /var -> private/var).
        self.root = Path(os.path.realpath(self._tmp.name)) / "autotune"
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

    def test_symlinked_ancestor_refused(self) -> None:
        link = Path(os.path.realpath(self._tmp.name)) / "link-parent"
        os.symlink(self.root.parent, link)
        with self.assertRaises(aw.WindowError):
            aw.write_window(str(link / "autotune"), ["releases/a"], group=GID, required_uid=UID)
        self.assertFalse(self.pt.exists())

    def test_group_writable_ancestor_refused(self) -> None:
        parent = self.root.parent
        mode = parent.stat().st_mode & 0o7777
        os.chmod(parent, mode | 0o020)
        try:
            with self.assertRaises(aw.WindowError):
                self.write(["releases/a"])
        finally:
            os.chmod(parent, mode)
        self.assertFalse(self.pt.exists())

    def test_group_writable_root_refused(self) -> None:
        os.chmod(self.root, 0o775)
        with self.assertRaises(aw.WindowError):
            self.write(["releases/a"])
        self.assertFalse(self.pt.exists())

    def test_relative_root_refused(self) -> None:
        with self.assertRaises(aw.WindowError):
            aw.write_window("autotune", ["releases/a"], group=GID, required_uid=UID)

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

    def test_restore_writes_original_bytes(self) -> None:
        # SPEC-023-R013 exact-byte rollback: comments, blank lines and trailing
        # newlines survive; entries are still validated.
        src = Path(self._tmp.name) / "backup"
        raw = b"# hand-restored\nreleases/a\n\n  releases/b  \n\n\n"
        src.write_bytes(raw)
        rc, out, err = self.cli("restore", "--from-file", str(src), "--expect-current", "releases/cur")
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.pt.read_bytes(), raw)
        self.assertEqual(json.loads(out)["window_after"], ["releases/a", "releases/b"])
        self.assertEqual(stat.S_IMODE(os.stat(self.pt).st_mode), 0o640)
        for bad in (b"releases/../x\n", b"releases/a\nreleases/b\nreleases/c\nreleases/d\n", b"releases/\xff\n"):
            with self.subTest(bad=bad):
                src.write_bytes(bad)
                rc, _, _ = self.cli("restore", "--from-file", str(src), "--expect-current", "releases/cur")
                self.assertNotEqual(rc, 0)
                self.assertEqual(self.pt.read_bytes(), raw)

    def test_write_window_bytes_api(self) -> None:
        aw.write_window_bytes(str(self.root), b"releases/a\n\n", group=GID, required_uid=UID,
                              expect_current="releases/cur")
        self.assertEqual(self.pt.read_bytes(), b"releases/a\n\n")
        with self.assertRaises(aw.WindowError):
            aw.write_window_bytes(str(self.root), b"releases/b\n", group=GID, required_uid=UID,
                                  expect_current="releases/other")
        self.assertEqual(self.pt.read_bytes(), b"releases/a\n\n")
        aw.write_window_bytes(str(self.root), None, group=GID, required_uid=UID, expect_current="releases/cur")
        self.assertFalse(self.pt.exists())

    def test_empty_expect_current_means_no_current(self) -> None:
        with self.assertRaises(aw.WindowError):
            aw.write_window(str(self.root), ["releases/a"], group=GID, required_uid=UID, expect_current="")
        os.unlink(self.root / "current")
        aw.write_window(str(self.root), ["releases/a"], group=GID, required_uid=UID, expect_current="")
        self.assertEqual(self.pt.read_text(), "releases/a\n")

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


class AdmittedJsonCoverageTests(unittest.TestCase):
    """coverage --admitted-json: the coordinator validator's admitted list is
    the admissible set; nothing is loaded or verified in Python."""

    SHA_A, SHA_B, SHA_C = "a" * 64, "b" * 64, "c" * 64

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.base = Path(self._tmp.name)
        self.poolz = self.base / "poolz.json"
        self.verdict = self.base / "admitted.json"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def write(self, ok: object = True, admitted: object = None) -> None:
        if admitted is None:
            admitted = [
                {"release_id": "v3", "candidates_sha256": self.SHA_A, "source": "current"},
                {"release_id": "v2", "candidates_sha256": self.SHA_B, "source": "retained"},
                {"release_id": "v3", "candidates_sha256": self.SHA_C, "source": "restamp"},
            ]
        body = {"ok": ok, "release_id": "v3", "admitted": admitted, "errors": [], "notes": []}
        self.verdict.write_text(json.dumps(body) + "\n")

    def pool(self, *pairs: tuple[str, str]) -> None:
        self.poolz.write_text(json.dumps({"pool": [
            {"provider_id": "p", "catalog_release_id": rid, "catalog_candidate_sha256": sha, "routing_eligible": True}
            for rid, sha in pairs]}))

    def cov(self, *extra: str) -> tuple[int, dict | None, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = aw.main(["coverage", "--admitted-json", str(self.verdict), "--poolz-json", str(self.poolz), *extra])
        return rc, (json.loads(out.getvalue()) if out.getvalue() else None), err.getvalue()

    def test_admitted_list_is_the_admissible_set(self) -> None:
        self.write()
        self.pool(("v3", self.SHA_A), ("v2", self.SHA_B.upper()), ("v3", self.SHA_C))
        rc, got, err = self.cov()
        self.assertEqual(rc, 0, err)
        self.assertEqual(got["uncovered"], [])
        self.assertEqual(got["advertised_total"], 3)
        self.assertEqual(got["covered"][1], {"release_id": "v2", "sha": self.SHA_B, "source": "retained"})

    def test_release_not_admitted_is_uncovered(self) -> None:
        self.write()
        self.pool(("v1", "d" * 64), ("v2", self.SHA_A))
        rc, got, err = self.cov()
        self.assertEqual(rc, 4, err)
        self.assertEqual(got["uncovered"], [
            {"release_id": "v1", "sha": "d" * 64, "providers": 1, "routing_eligible": 1},
            {"release_id": "v2", "sha": self.SHA_A, "providers": 1, "routing_eligible": 1}])

    def test_legacy_root_mode_is_gone(self) -> None:
        # No Python admission mirror: --root/--incoming are not coverage options.
        self.write()
        self.pool(("v3", self.SHA_A))
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as cm:
            self.cov("--root", str(self.base / "missing"), "--incoming", "releases/x")
        self.assertEqual(cm.exception.code, 2)

    def test_empty_pool(self) -> None:
        self.write()
        self.pool()
        rc, got, err = self.cov()
        self.assertEqual(rc, 0, err)
        self.assertEqual(got["uncovered"], [])
        self.assertEqual(got["advertised_total"], 0)

    def test_provider_without_catalog_ignored(self) -> None:
        self.write()
        self.poolz.write_text(json.dumps({"pool": [
            {"provider_id": "legacy", "routing_eligible": True},
            {"provider_id": "bridge", "catalog_release_id": "", "catalog_candidate_sha256": ""}]}))
        rc, got, err = self.cov()
        self.assertEqual(rc, 0, err)
        self.assertEqual(got["advertised_total"], 0)

    def test_malformed_poolz_is_refusal(self) -> None:
        self.write()
        for body in ("{not json", "[]", '{"pool": {}}', '{"pool": [1]}',
                     '{"pool": [{"catalog_release_id": "v2"}]}',
                     '{"pool": [{"catalog_release_id": "v2", "catalog_candidate_sha256": "zz"}]}',
                     '{"pool": [{"catalog_release_id": 7, "catalog_candidate_sha256": "' + "a" * 64 + '"}]}'):
            with self.subTest(body=body):
                self.poolz.write_text(body)
                rc, got, _ = self.cov()
                self.assertEqual(rc, 1)
                self.assertIsNone(got)

    def test_missing_poolz_is_refusal(self) -> None:
        self.write()
        self.assertEqual(self.cov()[0], 1)

    def test_validator_not_ok_or_malformed_is_refusal(self) -> None:
        good = {"release_id": "v3", "candidates_sha256": self.SHA_A, "source": "current"}
        cases = {
            "not ok": (False, None),
            "ok missing": ("true", None),
            "no admitted": (True, []),
            "admitted not list": (True, {"x": good}),
            "extra key": (True, [dict(good, dir="releases/x")]),
            "missing key": (True, [{"release_id": "v3", "candidates_sha256": self.SHA_A}]),
            "upper sha": (True, [dict(good, candidates_sha256=self.SHA_A.upper())]),
            "short sha": (True, [dict(good, candidates_sha256="ab")]),
            "bad release id": (True, [dict(good, release_id="../x")]),
            "bad source": (True, [dict(good, source="previous")]),
            "no current": (True, [dict(good, source="retained")]),
            "two current": (True, [good, dict(good, candidates_sha256=self.SHA_B)]),
            "current not first": (True, [dict(good, candidates_sha256=self.SHA_B, source="retained"), good]),
        }
        self.pool()
        for name, (ok, admitted) in cases.items():
            with self.subTest(name=name):
                self.write(ok, admitted)
                rc, got, err = self.cov()
                self.assertEqual(rc, 1)
                self.assertIsNone(got)
                self.assertIn("refusing", err)
        for body in ("", "{not json", "[]", "\xff"):
            with self.subTest(body=body):
                self.verdict.write_text(body, encoding="latin-1")
                self.assertEqual(self.cov()[0], 1)

    def test_missing_verdict_is_refusal(self) -> None:
        self.pool()
        self.assertEqual(self.cov()[0], 1)

    def test_admitted_json_is_required(self) -> None:
        self.pool()
        err = io.StringIO()
        with contextlib.redirect_stderr(err), self.assertRaises(SystemExit) as cm:
            aw.main(["coverage", "--poolz-json", str(self.poolz)])
        self.assertEqual(cm.exception.code, 2)
        self.assertIn("--admitted-json", err.getvalue())

if __name__ == "__main__":
    unittest.main()
