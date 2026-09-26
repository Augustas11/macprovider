from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import pathlib
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "build1-lane-a-lab-feed.py"
CATALOG = ROOT / "phase3-binary" / "catalog" / "autotune"


def load_module():
    spec = importlib.util.spec_from_file_location("build1_lane_a_lab_feed", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


lab_feed = load_module()


class Build1LaneALabFeedTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="build1-lab-feed-")
        self.root = pathlib.Path(self.temp.name)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_logical_regular_file_bytes_follows_huggingface_style_file_symlinks(self) -> None:
        artifact = self.root / "artifact"
        artifact.mkdir()
        target = artifact / "weights.safetensors"
        target.write_bytes(b"weights")
        (artifact / "alias").symlink_to(target)

        self.assertEqual(len(b"weights") * 2, lab_feed.logical_regular_file_bytes(artifact))

    def test_logical_regular_file_bytes_rejects_symlink_directories(self) -> None:
        artifact = self.root / "artifact"
        artifact.mkdir()
        target = self.root / "target-dir"
        target.mkdir()
        (artifact / "alias-dir").symlink_to(target, target_is_directory=True)

        with self.assertRaises(lab_feed.LabFeedError) as caught:
            lab_feed.logical_regular_file_bytes(artifact)

        self.assertIn("symlink directories", str(caught.exception))

    def test_measure_source_requires_every_published_primary_artifact(self) -> None:
        source = lab_feed.catalog_release.validate_artifact_source(
            (CATALOG / "autotune-artifacts-source.json").read_bytes(),
            candidate_obj=None,
        )
        key = sorted(source["models"])[0]
        artifact = self.root / "only-one"
        artifact.mkdir()
        (artifact / "weights.safetensors").write_bytes(b"one")

        with self.assertRaises(lab_feed.LabFeedError) as caught:
            lab_feed.measure_source(
                source,
                {key: artifact},
                hf_home=self.root / "empty-cache",
                use_default_cache=False,
            )

        self.assertIn("every published primary artifact", str(caught.exception))
        self.assertIn(lab_feed.BUILD1_CATALOG_KEY, str(caught.exception))

    def test_build_feed_uses_measured_sizes_and_validates_published_bytes(self) -> None:
        source_path = CATALOG / "autotune-artifacts-source.json"
        candidate_path = CATALOG / "autotune-candidates.json"
        source = lab_feed.catalog_release.validate_artifact_source(source_path.read_bytes(), candidate_obj=None)
        artifact_paths = {}
        expected_sizes = {}
        for index, key in enumerate(sorted(source["models"]), start=1):
            artifact = self.root / key.replace("/", "__")
            artifact.mkdir(parents=True)
            payload = bytes([index % 251]) * index
            (artifact / "weights.safetensors").write_bytes(payload)
            artifact_paths[key] = artifact
            expected_sizes[key] = len(payload)

        measurements, roots = lab_feed.measure_source(source, artifact_paths)
        self.assertEqual(expected_sizes, measurements)
        self.assertEqual(set(expected_sizes), set(roots))

        feed_bytes = lab_feed.build_feed(candidate_path, source_path, measurements)
        feed = json.loads(feed_bytes)
        for key, size in expected_sizes.items():
            model = feed["models"][key]
            primary = model["artifacts"][model["primary_artifact_id"]]
            self.assertEqual(size, primary["size_bytes"])

        candidate_bytes = candidate_path.read_bytes()
        candidate_obj = lab_feed.catalog_release.validate_candidate(candidate_bytes)
        self.assertEqual(
            feed,
            lab_feed.catalog_release.validate_artifact_feed(feed_bytes, candidate_bytes, candidate_obj),
        )

    def test_measurement_manifest_is_bound_to_source_and_candidate(self) -> None:
        source_path = CATALOG / "autotune-artifacts-source.json"
        candidate_path = CATALOG / "autotune-candidates.json"
        source = lab_feed.catalog_release.validate_artifact_source(source_path.read_bytes(), candidate_obj=None)
        measurements = {key: index for index, key in enumerate(sorted(source["models"]), start=1)}
        roots = {key: f"/redacted/{index}" for index, key in enumerate(sorted(source["models"]), start=1)}

        manifest = lab_feed.measurement_manifest(source, source_path, candidate_path, measurements, roots)
        manifest_path = self.root / "measurements.json"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

        loaded, loaded_roots = lab_feed.measurements_from_manifest(manifest_path, source, source_path, candidate_path)
        self.assertEqual(measurements, loaded)
        self.assertEqual(roots, loaded_roots)

        manifest["source_sha256"] = "0" * 64
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        with self.assertRaises(lab_feed.LabFeedError) as caught:
            lab_feed.measurements_from_manifest(manifest_path, source, source_path, candidate_path)
        self.assertIn("source_sha256", str(caught.exception))

    def test_build_feed_refuses_unmeasured_source_size(self) -> None:
        source_path = CATALOG / "autotune-artifacts-source.json"
        source = lab_feed.catalog_release.validate_artifact_source(source_path.read_bytes(), candidate_obj=None)
        measurements = {key: 1 for key in source["models"]}
        measurements[lab_feed.BUILD1_CATALOG_KEY] = 0

        with self.assertRaises(lab_feed.LabFeedError) as caught:
            lab_feed.build_feed(CATALOG / "autotune-candidates.json", source_path, measurements)

        self.assertIn("positive integer", str(caught.exception))

    def test_serve_has_no_non_loopback_host_override(self) -> None:
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as caught:
                lab_feed.main(
                    [
                        "serve",
                        "--directory",
                        str(self.root),
                        "--host",
                        "0.0.0.0",
                    ]
                )

        self.assertEqual(2, caught.exception.code)


if __name__ == "__main__":
    unittest.main()
