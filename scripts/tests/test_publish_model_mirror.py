#!/usr/bin/env python3
"""Unit tests for scripts/publish-model-mirror.py (issue #1737, SPEC-023-R019)."""

from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "publish-model-mirror.py"
SPEC = importlib.util.spec_from_file_location("publish_model_mirror", SCRIPT)
mirror = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = mirror
SPEC.loader.exec_module(mirror)


def canonical_hash(files: dict[str, bytes]) -> str:
    lines = "".join(
        f"{path}\n{len(data)}\n{hashlib.sha256(data).hexdigest()}\n"
        for path, data in sorted(files.items())
    )
    return hashlib.sha256(lines.encode()).hexdigest()


class PublishModelMirrorTest(unittest.TestCase):
    FILES = {
        ".gitattributes": b"*.safetensors filter=lfs\n",
        "config.json": b"{}",
        "model.safetensors": b"weights",
        "sub/tokenizer.json": b"tok",
    }

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(self.tmp, ignore_errors=True))
        self.snapshot = self.tmp / "snapshot"
        for path, data in self.FILES.items():
            target = self.snapshot / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        self.expected = canonical_hash(self.FILES)
        self.catalog = self.tmp / "catalog.json"
        self.catalog.write_text(json.dumps({"rows": {"fake-model": {
            "model_id": "mlx-community/Fake-4bit",
            "model_revision": "0" * 40,
            "model_sha256": self.expected,
        }}}))
        self.out = self.tmp / "out"

    def run_main(self, *extra: str) -> tuple[int, str, str]:
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            code = mirror.main([
                "--model", "fake-model",
                "--snapshot", str(self.snapshot),
                "--out", str(self.out),
                "--catalog", str(self.catalog),
                *extra,
            ])
        return code, stdout.getvalue(), stderr.getvalue()

    def test_publishes_manifest_that_hashes_to_signed_row(self) -> None:
        (self.snapshot / ".DS_Store").write_bytes(b"finder")
        (self.snapshot / "._model.safetensors").write_bytes(b"appledouble")
        (self.snapshot / ".cache" / "huggingface").mkdir(parents=True)
        (self.snapshot / ".cache" / "huggingface" / "download.lock").write_bytes(b"x")

        code, _, stderr = self.run_main()

        self.assertEqual(code, 0, stderr)
        root = self.out / self.expected
        manifest = (root / "manifest").read_bytes()
        self.assertEqual(hashlib.sha256(manifest).hexdigest(), self.expected)
        for path, data in self.FILES.items():
            self.assertEqual((root / "files" / path).read_bytes(), data)
        self.assertFalse((root / "files" / ".DS_Store").exists())
        self.assertFalse((root / "files" / ".cache").exists())

    def test_follows_cache_symlinks(self) -> None:
        blob = self.tmp / "blobs" / "b1"
        blob.parent.mkdir()
        blob.write_bytes(self.FILES["model.safetensors"])
        (self.snapshot / "model.safetensors").unlink()
        os.symlink(blob, self.snapshot / "model.safetensors")

        code, _, stderr = self.run_main()

        self.assertEqual(code, 0, stderr)
        target = self.out / self.expected / "files" / "model.safetensors"
        self.assertFalse(target.is_symlink())
        self.assertEqual(target.read_bytes(), b"weights")

    def test_refuses_snapshot_that_does_not_match(self) -> None:
        (self.snapshot / "extra.txt").write_bytes(b"not signed")

        code, _, stderr = self.run_main()

        self.assertEqual(code, 1)
        self.assertIn("does not match the signed hash", stderr)
        self.assertFalse((self.out / self.expected).exists())

    def test_unknown_model_is_usage_error(self) -> None:
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            code = mirror.main([
                "--model", "missing",
                "--snapshot", str(self.snapshot),
                "--out", str(self.out),
                "--catalog", str(self.catalog),
            ])
        self.assertEqual(code, 2)

    def test_signed_qwen3_8b_row_is_mirrorable(self) -> None:
        catalog = json.loads(mirror.DEFAULT_CATALOG.read_text())
        key, row = mirror.find_row(catalog, "mlx-community/Qwen3-8B-4bit")
        self.assertEqual(key, "qwen3-8b")
        self.assertEqual(len(row["model_sha256"]), 64)


if __name__ == "__main__":
    unittest.main()
