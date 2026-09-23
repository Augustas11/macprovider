#!/usr/bin/env python3
"""Hermetic tests for scripts/autotune_window.py (no root, tmp dirs only)."""

from __future__ import annotations

import contextlib
import hashlib
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


class CoverageTests(unittest.TestCase):
    """coverage: the post-activation admissible set vs connected providers."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        base = Path(os.path.realpath(self._tmp.name))
        self.root = base / "autotune"
        self.root.mkdir(mode=0o755)
        os.chmod(self.root, 0o755)
        (self.root / "releases").mkdir()
        self.poolz = base / "poolz.json"
        self.shas: dict[str, str] = {}

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def release(self, name: str, version: str, *, marker: str = "", signer: str | None = "k1") -> str:
        d = self.root / "releases" / name
        d.mkdir()
        raw = json.dumps({"version": version, "source": "x", "rows": {"r": {"marker": marker or name}}}).encode()
        (d / "autotune-candidates.json").write_bytes(raw)
        sha = hashlib.sha256(raw).hexdigest()
        if signer is not None:
            (d / "release.json").write_text(json.dumps(
                {"release_id": version, "feeds": {"autotune-candidates.json": {"sha256": sha, "signer_key_id": signer}}}))
        self.shas[name] = sha
        return sha

    def current(self, name: str) -> None:
        os.symlink(f"releases/{name}", self.root / "current")

    def pool(self, *providers: dict) -> None:
        self.poolz.write_text(json.dumps({"pool": list(providers), "summary": {}}))

    def provider(self, release_id: str, name: str, *, eligible: bool = True, upper: bool = False) -> dict:
        sha = self.shas[name].upper() if upper else self.shas[name]
        return {"provider_id": "p", "catalog_release_id": release_id, "catalog_candidate_sha256": sha,
                "routing_eligible": eligible}

    def cov(self, incoming: str = "releases/new") -> tuple[int, dict | None, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = aw.main(["coverage", "--root", str(self.root), "--required-uid", str(UID),
                          "--incoming", incoming, "--poolz-json", str(self.poolz)])
        return rc, (json.loads(out.getvalue()) if out.getvalue() else None), err.getvalue()

    def test_current_and_window_covered(self) -> None:
        self.release("cur", "v2")
        self.release("p1", "v1")
        self.release("new", "v3")
        self.current("cur")
        (self.root / aw.FILE_NAME).write_text("releases/p1\n")
        self.pool(self.provider("v2", "cur"), self.provider("v1", "p1", upper=True), self.provider("v3", "new"))
        rc, got, err = self.cov()
        self.assertEqual(rc, 0, err)
        self.assertEqual(got["uncovered"], [])
        self.assertEqual(got["advertised_total"], 3)
        self.assertEqual([c["dir"] for c in got["covered"]], ["releases/new", "releases/cur", "releases/p1"])
        self.assertEqual(got["covered"][0], {"dir": "releases/new", "release_id": "v3", "sha": self.shas["new"]})

    def test_dropped_release_uncovered(self) -> None:
        # Window is full; the oldest entry falls out on activation.
        for name, version in (("cur", "v4"), ("p1", "v3"), ("p2", "v2"), ("p3", "v1"), ("new", "v5")):
            self.release(name, version)
        self.current("cur")
        (self.root / aw.FILE_NAME).write_text("releases/p1\nreleases/p2\nreleases/p3\n")
        self.pool(self.provider("v1", "p3"), self.provider("v1", "p3", eligible=False), self.provider("v4", "cur"))
        rc, got, err = self.cov()
        self.assertEqual(rc, 4, err)
        self.assertEqual(got["uncovered"], [
            {"release_id": "v1", "sha": self.shas["p3"], "providers": 2, "routing_eligible": 1}])
        self.assertEqual(got["advertised_total"], 3)

    def test_same_release_id_different_sha_uncovered(self) -> None:
        self.release("cur", "v2")
        self.release("new", "v3")
        self.current("cur")
        self.pool({"catalog_release_id": "v2", "catalog_candidate_sha256": "ab" * 32, "routing_eligible": True})
        rc, got, _ = self.cov()
        self.assertEqual(rc, 4)
        self.assertEqual(got["uncovered"][0]["sha"], "ab" * 32)

    def test_restamp_of_incoming_version_covered(self) -> None:
        self.release("cur", "v2")
        self.release("new", "v3")
        self.release("v3-0123456789abcdef", "v3", marker="restamp")
        self.current("cur")
        self.pool(self.provider("v3", "v3-0123456789abcdef"))
        rc, got, err = self.cov()
        self.assertEqual(rc, 0, err)
        self.assertIn("releases/v3-0123456789abcdef", [c["dir"] for c in got["covered"]])

    def test_restamp_rules_mirror_go(self) -> None:
        self.release("cur", "v2")
        self.release("new", "v3")
        # Another signer is not a restamp; a restamp of a non-current version is
        # not admissible; a dir name that is not <version>-<sha16> is ignored.
        self.release("v3-1111111111111111", "v3", marker="a", signer="other")
        self.release("v2-2222222222222222", "v2", marker="b")
        self.release("v3-33333333333333", "v3", marker="c")
        self.release("v3-444444444444444A", "v3", marker="d")
        self.current("cur")
        self.pool(*(self.provider(v, n) for v, n in (
            ("v3", "v3-1111111111111111"), ("v2", "v2-2222222222222222"),
            ("v3", "v3-33333333333333"), ("v3", "v3-444444444444444A"))))
        rc, got, _ = self.cov()
        self.assertEqual(rc, 4)
        self.assertEqual(len(got["uncovered"]), 4)

    def test_restamp_scan_cap(self) -> None:
        self.release("cur", "v2")
        self.release("new", "v3")
        for i in range(aw.MAX_RESTAMP_EXAMINED + 1):
            self.release(f"v3-{i:016x}", "v3", marker=str(i))
        self.current("cur")
        self.pool(self.provider("v3", f"v3-{aw.MAX_RESTAMP_EXAMINED - 1:016x}"))
        self.assertEqual(self.cov()[0], 0)
        self.pool(self.provider("v3", f"v3-{aw.MAX_RESTAMP_EXAMINED:016x}"))
        self.assertEqual(self.cov()[0], 4)

    def test_empty_pool(self) -> None:
        self.release("new", "v3")
        self.current("new")
        self.pool()
        rc, got, err = self.cov()
        self.assertEqual(rc, 0, err)
        self.assertEqual(got["uncovered"], [])
        self.assertEqual(got["advertised_total"], 0)

    def test_provider_without_catalog_ignored(self) -> None:
        self.release("cur", "v2")
        self.release("new", "v3")
        self.current("cur")
        self.pool({"provider_id": "legacy", "routing_eligible": True},
                  {"provider_id": "bridge", "catalog_release_id": "", "catalog_candidate_sha256": ""})
        rc, got, err = self.cov()
        self.assertEqual(rc, 0, err)
        self.assertEqual(got["advertised_total"], 0)

    def test_malformed_input_is_refusal(self) -> None:
        self.release("cur", "v2")
        self.release("new", "v3")
        self.current("cur")
        for body in ("{not json", "[]", '{"pool": {}}', '{"pool": [1]}',
                     '{"pool": [{"catalog_release_id": "v2"}]}',
                     '{"pool": [{"catalog_release_id": "v2", "catalog_candidate_sha256": "zz"}]}',
                     '{"pool": [{"catalog_release_id": 7, "catalog_candidate_sha256": "' + "a" * 64 + '"}]}'):
            with self.subTest(body=body):
                self.poolz.write_text(body)
                rc, got, _ = self.cov()
                self.assertEqual(rc, 1)
                self.assertIsNone(got)

    def test_unloadable_window_entry_is_refusal(self) -> None:
        self.release("cur", "v2")
        self.release("new", "v3")
        self.current("cur")
        (self.root / aw.FILE_NAME).write_text("releases/missing\n")
        self.pool()
        self.assertEqual(self.cov()[0], 1)

    def test_missing_poolz_is_refusal(self) -> None:
        self.release("new", "v3")
        self.assertEqual(self.cov()[0], 1)


if __name__ == "__main__":
    unittest.main()
