from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path

MODULE = Path(__file__).resolve().parents[1] / "lab" / "minimax" / "publish_abliterated.py"
spec = importlib.util.spec_from_file_location("publish_abliterated", MODULE)
pub = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pub)


class SnapshotManifestCacheTests(unittest.TestCase):
    def test_cache_directory_at_root_is_a_blocker(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "config.json").write_text("{}")
            (root / ".cache" / "huggingface").mkdir(parents=True)
            (root / ".cache" / "huggingface" / "x").write_text("x")
            with self.assertRaises(SystemExit) as cm:
                pub.snapshot_manifest_sha256(root)
            self.assertEqual(
                str(cm.exception),
                f"BLOCKER: {root}/.cache present: the provider hashes it; remove it from the lab copy",
            )

    def test_snapshot_without_cache_still_hashes(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "config.json").write_text("{}")
            self.assertEqual(len(pub.snapshot_manifest_sha256(root)), 64)


if __name__ == "__main__":
    unittest.main()
