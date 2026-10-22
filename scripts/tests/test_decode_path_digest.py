"""Tests for scripts/decode_path_digest.py (SPEC-048-R013 0.1.51)."""

import hashlib
import json
import shutil
import tempfile
import unittest
from pathlib import Path

from scripts import decode_path_digest as tool

ROOT = Path(__file__).resolve().parents[2]


class DecodePathDigestTests(unittest.TestCase):
    def copy_package(self) -> Path:
        temp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp)
        files, _ = tool.load_manifest()
        for name in (tool.MANIFEST.name, tool.RESOLVED.name):
            shutil.copy(tool.PACKAGE / name, temp / name)
        for item in files:
            (temp / item).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(tool.PACKAGE / item, temp / item)
        return temp

    def test_committed_constant_is_current(self):
        self.assertEqual(tool.main(["--check"]), 0)
        self.assertEqual(tool.GENERATED.read_text("utf-8"), tool.render(tool.compute()))

    def test_changed_decode_path_file_changes_the_digest(self):
        package = self.copy_package()
        digest = tool.compute(package)
        self.assertEqual(digest, tool.compute())
        files, _ = tool.load_manifest(package)
        with open(package / files[0], "a", encoding="utf-8") as handle:
            handle.write("\n// changed\n")
        self.assertNotEqual(tool.compute(package), digest)

    def test_missing_listed_file_fails(self):
        package = self.copy_package()
        files, _ = tool.load_manifest(package)
        (package / files[-1]).unlink()
        with self.assertRaisesRegex(tool.DecodePathError, "not a regular file"):
            tool.compute(package)

    def test_dependency_revision_is_part_of_the_digest(self):
        package = self.copy_package()
        digest = tool.compute(package)
        resolved = json.loads((package / tool.RESOLVED.name).read_text("utf-8"))
        for pin in resolved["pins"]:
            if pin["identity"] == "mlx-swift-lm":
                pin["state"]["revision"] = "0" * 40
        (package / tool.RESOLVED.name).write_text(json.dumps(resolved), "utf-8")
        self.assertNotEqual(tool.compute(package), digest)

    def test_manifest_is_closed_sorted_and_cannot_list_the_generated_file(self):
        package = self.copy_package()
        manifest = json.loads((package / tool.MANIFEST.name).read_text("utf-8"))
        for mutate, message in (
            (lambda m: m.update(extra=1), "exactly"),
            (lambda m: m["files"].reverse(), "sorted"),
            (lambda m: m["files"].insert(0, "../escape.swift"), "relative"),
            (lambda m: m.update(files=sorted(m["files"] + ["Sources/macprovider-cli/DecodePathIdentity.generated.swift"])),
             "own digest"),
        ):
            bad = json.loads(json.dumps(manifest))
            mutate(bad)
            (package / tool.MANIFEST.name).write_text(json.dumps(bad), "utf-8")
            with self.assertRaisesRegex(tool.DecodePathError, message):
                tool.compute(package)

    def test_algorithm_is_the_documented_line_format(self):
        files, deps = tool.load_manifest()
        revisions = tool.resolved_revisions()
        lines = [tool.DOMAIN]
        lines += [f"file {f} {hashlib.sha256((tool.PACKAGE / f).read_bytes()).hexdigest()}" for f in files]
        lines += [f"dependency {d} {revisions[d]}" for d in deps]
        self.assertEqual(tool.compute(), hashlib.sha256(("\n".join(lines) + "\n").encode()).hexdigest())

    def test_binary_marker_extraction(self):
        with tempfile.NamedTemporaryFile() as handle:
            handle.write(b"\x00junk" + tool.MARKER_PREFIX.encode() + b"a" * 64 + b"\x00tail")
            handle.flush()
            self.assertEqual(tool.embedded_in_binary(Path(handle.name)), "a" * 64)
        with tempfile.NamedTemporaryFile() as handle:
            handle.write(b"no marker here")
            handle.flush()
            self.assertIsNone(tool.embedded_in_binary(Path(handle.name)))

    def test_admission_status(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "native-mtp-admission.json"
            path.write_text(json.dumps({"entries": [{"model_key": "m"}]}), "utf-8")
            self.assertEqual(tool.admission_status(path, "a" * 64), "legacy")
            path.write_text(json.dumps({"entries": [{"decode_path_digest": "a" * 64}]}), "utf-8")
            self.assertEqual(tool.admission_status(path, "a" * 64), "match")
            self.assertEqual(tool.admission_status(path, "b" * 64), "mismatch")


if __name__ == "__main__":
    unittest.main()
