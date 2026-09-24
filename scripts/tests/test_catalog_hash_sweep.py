#!/usr/bin/env python3
"""Unit tests for scripts/catalog-hash-sweep.py (issue #1735 step 5)."""

from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
import urllib.parse
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "catalog-hash-sweep.py"
SPEC = importlib.util.spec_from_file_location("catalog_hash_sweep", SCRIPT)
sweep = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
# dataclasses resolve annotations through sys.modules[cls.__module__].
sys.modules[SPEC.name] = sweep
SPEC.loader.exec_module(sweep)

REPO_ID = "mlx-community/Fake-Model-4bit"
REVISION = "0123456789abcdef0123456789abcdef01234567"
HF = "https://huggingface.co"

# Bytes a downloader would store. Shards are LFS in the fake tree; the rest
# are plain git files that the sweep must download and hash itself.
FILES = {
    ".gitattributes": b"*.safetensors filter=lfs diff=lfs merge=lfs -text\n",
    "config.json": b'{"model_type":"fake","num_hidden_layers":2}\n',
    "model-00001-of-00002.safetensors": b"\x00" * 4096 + b"shard-one",
    "model-00002-of-00002.safetensors": b"\x01" * 2048 + b"shard-two",
    "model.safetensors.index.json": b'{"weight_map":{}}\n',
    "tokenizer/tokenizer.json": b'{"version":"1.0"}\n',
    "chat template #1.jinja": b"{{ messages }}\n",
}
LFS = {"model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"}


def swift_style_directory_hash(root: Path) -> str:
    """Independent re-statement of inspectCanonicalArtifact over real files."""
    lines = []
    for dirpath, _, filenames in os.walk(root):
        for name in filenames:
            full = Path(dirpath) / name
            data = full.read_bytes()
            rel = full.relative_to(root).as_posix()
            lines.append((rel, f"{rel}\n{len(data)}\n{hashlib.sha256(data).hexdigest()}\n"))
    return hashlib.sha256("".join(line for _, line in sorted(lines)).encode()).hexdigest()


class FakeHub:
    """Serves the revision, paginated tree, and resolve endpoints."""

    def __init__(self, files: dict[str, bytes], *, siblings: list[str] | None = None,
                 tree_overrides: dict[str, dict] | None = None, page_size: int = 2,
                 fail_status: int | None = None, revision_body: object | None = None) -> None:
        self.files = files
        self.siblings = siblings if siblings is not None else sorted(files)
        self.tree_overrides = tree_overrides or {}
        self.page_size = page_size
        self.fail_status = fail_status
        self.revision_body = revision_body
        self.requests: list[str] = []
        self.resolved: list[str] = []

    def tree_items(self) -> list[dict]:
        items: list[dict] = [{"type": "directory", "path": "tokenizer", "oid": "0" * 40, "size": 0}]
        for path, data in sorted(self.files.items()):
            item = {"type": "file", "path": path, "size": len(data),
                    "oid": hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()}
            if path in LFS:
                item["lfs"] = {"oid": hashlib.sha256(data).hexdigest(), "size": len(data), "pointerSize": 134}
            item.update(self.tree_overrides.get(path, {}))
            items.append(item)
        return items

    def __call__(self, url: str, headers: dict):
        self.requests.append(url)
        if self.fail_status is not None:
            return self.fail_status, b"denied", {}
        revision_api = f"{HF}/api/models/{REPO_ID}/revision/{REVISION}?blobs=true"
        tree_api = f"{HF}/api/models/{REPO_ID}/tree/{REVISION}?recursive=true"
        resolve = f"{HF}/{REPO_ID}/resolve/{REVISION}/"
        if url == revision_api:
            body = self.revision_body
            if body is None:
                body = {"id": REPO_ID, "sha": REVISION, "siblings": [{"rfilename": n} for n in self.siblings]}
            return 200, json.dumps(body).encode(), {}
        if url.startswith(tree_api):
            cursor = int(url.split("cursor=")[1]) if "cursor=" in url else 0
            items = self.tree_items()
            page = items[cursor:cursor + self.page_size]
            headers_out = {}
            if cursor + self.page_size < len(items):
                # HF sends a multi-parameter Link header.
                headers_out["link"] = (
                    f'<{tree_api}&cursor={cursor + self.page_size}>; rel="next"; results="{self.page_size}"'
                )
            return 200, json.dumps(page).encode(), headers_out
        if url.startswith(resolve):
            path = urllib.parse.unquote(url[len(resolve):])
            self.resolved.append(path)
            return 200, self.files[path], {}
        return 404, b"not found", {}


def write_feed(tmp: Path, signed_sha: str) -> Path:
    feed = {
        "version": "test", "generated_at": "2026-09-24T00:00:00Z", "policy_version": "p",
        "source": "operator_curated_autotune_candidate_catalog",
        "rows": {"vendor/fake": {"model_id": REPO_ID, "model_revision": REVISION, "model_sha256": signed_sha}},
    }
    path = tmp / "feed.json"
    path.write_text(json.dumps(feed))
    return path


def run(argv: list[str], hub: FakeHub) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        code = sweep.main(argv, fetch=hub)
    return code, out.getvalue(), err.getvalue()


class CanonicalHashTests(unittest.TestCase):
    def test_manifest_format_and_sort_order(self) -> None:
        entries = [
            sweep.FileEntry("b.json", 2, "b" * 64),
            sweep.FileEntry(".gitattributes", 10, "a" * 64),
            sweep.FileEntry("a/z.txt", 0, "c" * 64),
        ]
        expected = hashlib.sha256(
            (f".gitattributes\n10\n{'a' * 64}\n" f"a/z.txt\n0\n{'c' * 64}\n" f"b.json\n2\n{'b' * 64}\n").encode()
        ).hexdigest()
        self.assertEqual(sweep.canonical_manifest_hash(entries), expected)

    def test_rejects_unsafe_and_duplicate_paths(self) -> None:
        for bad in ["", "/abs", "a/../b", "tab\tname"]:
            with self.assertRaises(sweep.SweepError):
                sweep.canonical_manifest_hash([sweep.FileEntry(bad, 1, "a" * 64)])
        with self.assertRaises(sweep.SweepError):
            sweep.canonical_manifest_hash([sweep.FileEntry("x", 1, "a" * 64), sweep.FileEntry("x", 1, "a" * 64)])


class SweepTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        snapshot = self.tmp / "snapshot"
        for rel, data in FILES.items():
            (snapshot / rel).parent.mkdir(parents=True, exist_ok=True)
            (snapshot / rel).write_bytes(data)
        self.expected = swift_style_directory_hash(snapshot)
        (snapshot / ".gitattributes").unlink()
        self.expected_without_gitattributes = swift_style_directory_hash(snapshot)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def sweep_json(self, hub: FakeHub, signed: str) -> tuple[int, dict]:
        feed = write_feed(self.tmp, signed)
        out = self.tmp / "out.json"
        code, _, _ = run(["--feed", str(feed), "--artifact-source", str(self.tmp / "none.json"),
                          "--json-out", str(out)], hub)
        return code, json.loads(out.read_text())[0]

    def test_recomputed_hash_equals_on_disk_hash_of_downloader_file_set(self) -> None:
        hub = FakeHub(FILES)
        code, row = self.sweep_json(hub, self.expected)
        self.assertEqual(code, 0, row)
        self.assertEqual(row["status"], "MATCH")
        self.assertEqual(row["recomputed_sha256"], self.expected)
        self.assertEqual(row["without_gitattributes_sha256"], self.expected_without_gitattributes)
        self.assertEqual(row["file_count"], len(FILES))
        # Pagination was followed and LFS shards were never downloaded.
        self.assertGreater(sum("/tree/" in u for u in hub.requests), 1)
        self.assertEqual(sorted(hub.resolved), sorted(set(FILES) - LFS))

    def test_mismatch_exits_one_and_reports_both_values(self) -> None:
        signed = "350c018e8a3397a753bcb7c22c839a5c5a24041e6dee014bb42c2d766d6db57d"
        code, row = self.sweep_json(FakeHub(FILES), signed)
        self.assertEqual(code, sweep.EXIT_MISMATCH)
        self.assertEqual(row["status"], "MISMATCH")
        self.assertEqual(row["signed_sha256"], signed)
        self.assertEqual(row["recomputed_sha256"], self.expected)

    def test_sibling_and_tree_file_sets_must_agree(self) -> None:
        hub = FakeHub(FILES, siblings=sorted(set(FILES) - {".gitattributes"}))
        code, row = self.sweep_json(hub, self.expected)
        self.assertEqual(code, sweep.EXIT_INCOMPLETE)
        self.assertIn("sibling/tree file sets differ", row["error"])

    def test_plain_file_blob_oid_is_cross_checked(self) -> None:
        hub = FakeHub(FILES, tree_overrides={"config.json": {"oid": "f" * 40}})
        code, row = self.sweep_json(hub, self.expected)
        self.assertEqual(code, sweep.EXIT_INCOMPLETE)
        self.assertIn("git blob SHA-1 mismatch", row["error"])

    def test_lfs_size_disagreement_is_an_error(self) -> None:
        shard = "model-00001-of-00002.safetensors"
        lfs = {"oid": hashlib.sha256(FILES[shard]).hexdigest(), "size": 1, "pointerSize": 134}
        code, row = self.sweep_json(FakeHub(FILES, tree_overrides={shard: {"lfs": lfs}}), self.expected)
        self.assertEqual(code, sweep.EXIT_INCOMPLETE)
        self.assertIn("LFS size", row["error"])

    def test_http_failure_is_an_error_not_a_match(self) -> None:
        code, row = self.sweep_json(FakeHub(FILES, fail_status=403), self.expected)
        self.assertEqual(code, sweep.EXIT_INCOMPLETE)
        self.assertEqual(row["status"], "ERROR")
        self.assertIsNone(row["recomputed_sha256"])

    def test_revision_api_must_confirm_the_pinned_commit(self) -> None:
        for body in ({"siblings": [{"rfilename": n} for n in FILES]},
                     {"sha": "f" * 40, "siblings": [{"rfilename": n} for n in FILES]}):
            code, row = self.sweep_json(FakeHub(FILES, revision_body=body), self.expected)
            self.assertEqual(code, sweep.EXIT_INCOMPLETE)
            self.assertIn("revision API resolved", row["error"])

    def test_unexpected_json_shape_is_a_row_error_not_a_crash(self) -> None:
        code, row = self.sweep_json(FakeHub(FILES, revision_body=["not", "a", "dict"]), self.expected)
        self.assertEqual(code, sweep.EXIT_INCOMPLETE)
        self.assertIn("unexpected JSON shape", row["error"])

    def test_unexpected_exception_in_one_row_keeps_the_sweep_going(self) -> None:
        def boom(url, headers):
            raise RuntimeError("truncated body")
        code, row = self.sweep_json(boom, self.expected)
        self.assertEqual(code, sweep.EXIT_INCOMPLETE)
        self.assertIn("RuntimeError: truncated body", row["error"])

    def test_oversized_plain_file_is_refused_before_download(self) -> None:
        hub = FakeHub(FILES, tree_overrides={"config.json": {"size": sweep.MAX_PLAIN_FILE_BYTES + 1}})
        code, row = self.sweep_json(hub, self.expected)
        self.assertEqual(code, sweep.EXIT_INCOMPLETE)
        self.assertIn("refusing download", row["error"])
        self.assertNotIn("config.json", hub.resolved)

    def test_lfs_size_is_required(self) -> None:
        shard = "model-00002-of-00002.safetensors"
        lfs = {"oid": hashlib.sha256(FILES[shard]).hexdigest()}
        code, row = self.sweep_json(FakeHub(FILES, tree_overrides={shard: {"lfs": lfs}}), self.expected)
        self.assertEqual(code, sweep.EXIT_INCOMPLETE)
        self.assertIn("LFS size", row["error"])

    def test_token_is_not_forwarded_on_redirect(self) -> None:
        captured = {}

        def fake_urlopen(request, timeout):
            captured["request"] = request
            raise sweep.SweepError("stop")

        original = sweep.urllib.request.urlopen
        sweep.urllib.request.urlopen = fake_urlopen
        try:
            with self.assertRaises(sweep.SweepError):
                sweep.default_fetch(f"{HF}/x", {"Authorization": "Bearer t", "User-Agent": "u"})
        finally:
            sweep.urllib.request.urlopen = original
        request = captured["request"]
        # urllib's redirect handler copies request.headers, never unredirected_hdrs.
        self.assertNotIn("Authorization", request.headers)
        self.assertEqual(request.unredirected_hdrs.get("Authorization"), "Bearer t")

    def test_pagination_may_not_leave_huggingface(self) -> None:
        hub = FakeHub(FILES)
        original = hub.__call__

        def evil(url, headers):
            status, body, out = original(url, headers)
            if "link" in out:
                out = {"link": '<https://evil.example/next>; rel="next"'}
            return status, body, out
        code, row = self.sweep_json(evil, self.expected)
        self.assertEqual(code, sweep.EXIT_INCOMPLETE)
        self.assertIn("left huggingface.co", row["error"])

    def test_boolean_size_is_not_a_manifest_integer(self) -> None:
        hub = FakeHub(FILES, tree_overrides={"config.json": {"size": True}})
        code, row = self.sweep_json(hub, self.expected)
        self.assertEqual(code, sweep.EXIT_INCOMPLETE)
        self.assertIn("no size", row["error"])
        self.assertIsNone(row["recomputed_sha256"])

    def test_duplicate_tree_path_is_an_error(self) -> None:
        hub = FakeHub(FILES)
        original = hub.__call__

        def duplicated(url, headers):
            status, body, out = original(url, headers)
            if "/tree/" in url and "cursor=" not in url:
                page = json.loads(body)
                files = [item for item in page if item.get("type") == "file"]
                body = json.dumps(page + [files[0]]).encode()
            return status, body, out

        code, row = self.sweep_json(duplicated, self.expected)
        self.assertEqual(code, sweep.EXIT_INCOMPLETE)
        self.assertIn("duplicate tree path", row["error"])

    def test_missing_revision_is_a_row_error(self) -> None:
        feed = {"rows": {"vendor/fake": {"model_id": REPO_ID, "model_sha256": "ab" * 32}}}
        path = self.tmp / "bad-feed.json"
        path.write_text(json.dumps(feed))
        out = self.tmp / "bad-out.json"
        code, _, _ = run(
            ["--feed", str(path), "--artifact-source", str(self.tmp / "none.json"), "--json-out", str(out)],
            FakeHub(FILES),
        )
        self.assertEqual(code, sweep.EXIT_INCOMPLETE)
        row = json.loads(out.read_text())[0]
        self.assertEqual(row["status"], "ERROR")
        self.assertIn("model_revision", row["error"])
        self.assertIsNone(row["recomputed_sha256"])

    def test_markdown_table_lists_every_row(self) -> None:
        feed = write_feed(self.tmp, self.expected)
        code, out, _ = run(["--feed", str(feed), "--artifact-source", str(self.tmp / "none.json"), "--markdown"],
                           FakeHub(FILES))
        self.assertEqual(code, 0)
        self.assertIn("| `vendor/fake` |", out)
        self.assertIn("MATCH", out)


class ApplePathTests(unittest.TestCase):
    def test_foundation_url_vectors(self) -> None:
        # Scalars measured from URL.appendingPathComponent on this Mac.
        vectors = {
            "caf\u00e9.json": "cafe\u0301.json",
            "dir/caf\u00e9.json": "dir/cafe\u0301.json",
            "\u1e9b\u0323": "\u017f\u0323\u0307",
            "\u212b.txt": "\u212b.txt",
            "\u00c5.txt": "A\u030a.txt",
            "e\u0340": "e\u0300",
            "\u00e9\u0323": "e\u0323\u0301",
            "\uac00": "\u1100\u1161",
            "foo/\u2126/bar": "foo/\u2126/bar",
        }
        for raw, stored in vectors.items():
            self.assertEqual(sweep.apple_relative_path(raw), stored, raw)

    def test_nfc_filename_is_hashed_under_the_stored_path(self) -> None:
        name = "caf\u00e9.json"
        data = b"{}\n"
        stored = "cafe\u0301.json"
        digest = hashlib.sha256(data).hexdigest()
        expected = hashlib.sha256(f"{stored}\n{len(data)}\n{digest}\n".encode()).hexdigest()
        code, row = self._sweep({name: data}, [name], expected)
        self.assertEqual(code, 0, row)
        self.assertEqual(row["file_count"], 1)
        self.assertEqual(row["recomputed_sha256"], expected)

    def test_equivalent_names_collapse_to_the_last_sibling(self) -> None:
        nfc, nfd = "caf\u00e9.txt", "cafe\u0301.txt"
        files = {nfc: b"first", nfd: b"second"}
        digest = hashlib.sha256(b"second").hexdigest()
        expected = hashlib.sha256(f"{nfd}\n6\n{digest}\n".encode()).hexdigest()
        code, row = self._sweep(files, [nfc, nfd], expected)
        self.assertEqual(code, 0, row)
        self.assertEqual(row["file_count"], 1)
        self.assertEqual(row["recomputed_sha256"], expected)

    def test_angstrom_keeps_the_last_url_form(self) -> None:
        angstrom, aring = "\u212b.txt", "\u00c5.txt"
        files = {angstrom: b"ANG", aring: b"ARING"}
        stored = "A\u030a.txt"
        digest = hashlib.sha256(b"ARING").hexdigest()
        expected = hashlib.sha256(f"{stored}\n5\n{digest}\n".encode()).hexdigest()
        code, row = self._sweep(files, [angstrom, aring], expected)
        self.assertEqual(code, 0, row)
        self.assertEqual(row["recomputed_sha256"], expected)
        digest = hashlib.sha256(b"ANG").hexdigest()
        expected = hashlib.sha256(f"{angstrom}\n3\n{digest}\n".encode()).hexdigest()
        code, row = self._sweep(files, [aring, angstrom], expected)
        self.assertEqual(code, 0, row)
        self.assertEqual(row["recomputed_sha256"], expected)

    def _sweep(self, files: dict[str, bytes], siblings: list[str], signed: str) -> tuple[int, dict]:
        hub = FakeHub(files, siblings=siblings)
        # FakeHub's LFS set is the module constant; these names are plain files.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            feed = write_feed(root, signed)
            out = root / "out.json"
            code, _, _ = run(
                ["--feed", str(feed), "--artifact-source", str(root / "none.json"), "--json-out", str(out)],
                hub,
            )
            return code, json.loads(out.read_text())[0]


class SignedFeedShapeTests(unittest.TestCase):
    def test_every_committed_signed_row_is_loadable_and_pinned(self) -> None:
        rows = sweep.load_rows(sweep.SIGNED_FEED, sweep.ARTIFACT_SOURCE)
        self.assertTrue(rows)
        for row in rows:
            self.assertRegex(row.revision, r"^[0-9a-f]{40}$", row.key)
            self.assertRegex(row.signed_sha256, r"^[0-9a-f]{64}$", row.key)


if __name__ == "__main__":
    unittest.main()
