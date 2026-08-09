import json
import tempfile
import unittest
from pathlib import Path

from scripts.read_swiftpm_pins import read_pins
from scripts.compare_upstream_watch import material_changes, merge_snapshot


class SwiftPMPinParsingTests(unittest.TestCase):
    def test_reads_versions_from_swiftpm_state_objects(self):
        fixture = Path(__file__).with_name("fixtures") / "package-resolved-v2.json"

        self.assertEqual(
            read_pins(fixture),
            {
                "mlx_swift": "0.31.4",
                "mlx_swift_revision": "dc43e62d7055353c7f99fa071a4e71d29dfddc44",
                "mlx_swift_lm": "3.31.4",
                "mlx_swift_lm_revision": "bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57",
                "swift_transformers": "1.0.0",
                "swift_transformers_revision": "transformers-revision",
                "swift_jinja": "2.4.2",
                "swift_jinja_revision": "jinja-revision",
            },
        )

    def test_fails_closed_when_required_pin_is_missing(self):
        with tempfile.TemporaryDirectory() as directory:
            resolved = Path(directory) / "Package.resolved"
            resolved.write_text(json.dumps({"pins": []}))

            with self.assertRaisesRegex(ValueError, "missing required SwiftPM pins"):
                read_pins(resolved)

    def test_fails_closed_when_identity_is_redirected_to_a_fork(self):
        fixture = Path(__file__).with_name("fixtures") / "package-resolved-v2.json"
        payload = json.loads(fixture.read_text())
        payload["pins"][0]["location"] = "https://example.invalid/fork/mlx-swift"
        with tempfile.TemporaryDirectory() as temporary:
            resolved = Path(temporary) / "Package.resolved"
            resolved.write_text(json.dumps(payload))
            with self.assertRaisesRegex(ValueError, "unexpected SwiftPM source location"):
                read_pins(resolved)


class UpstreamWatchComparisonTests(unittest.TestCase):
    @staticmethod
    def _baseline():
        return {
            "macprovider_pins": {"mlx_swift": "0.31.4", "mlx_swift_lm": "3.31.4"},
            "blockers": {
                "mlx_swift_lm_406_compile_kv_offset": {"state": "OPEN", "closed_at": None},
                "mlx_swift_lm_364_gemma_moe": {"state": "MERGED", "merged_at": "2026-07-21T19:43:49Z"},
                "mlx_swift_lm_312_quantized_cache_ownership": {"state": "OPEN"},
                "mlx_swift_lm_453_typed_cache_storage": {"state": "MERGED", "merged_at": "x"},
                "mlx_swift_lm_424_speculative_cache_wrap": {"state": "OPEN"},
                "mlx_swift_lm_518_remote_package_unsafe_flags": {"state": "OPEN"},
            },
            "releases": {
                "mlx_swift_latest": {"tag": "0.31.6"},
                "mlx_swift_lm_latest": {"tag": "3.31.4"},
                "swift_transformers_latest": {"tag": "1.3.3"},
                "swift_jinja_latest": {"tag": "2.4.2"},
            },
            "implementation_signals": {"kvcache_offset_graph_traceable": False},
        }

    def test_existing_newer_upstream_tag_is_not_a_change_every_run(self):
        baseline = {
            "macprovider_pins": {"mlx_swift": "0.31.4", "mlx_swift_lm": "3.31.4"},
            "blockers": {
                "mlx_swift_lm_406_compile_kv_offset": {"state": "OPEN", "closed_at": None},
                "mlx_swift_lm_364_gemma_moe": {"state": "MERGED", "merged_at": "2026-07-21T19:43:49Z"},
                "mlx_swift_lm_312_quantized_cache_ownership": {"state": "OPEN"},
                "mlx_swift_lm_453_typed_cache_storage": {"state": "MERGED", "merged_at": "x"},
                "mlx_swift_lm_424_speculative_cache_wrap": {"state": "OPEN"},
                "mlx_swift_lm_518_remote_package_unsafe_flags": {"state": "OPEN"},
            },
            "releases": {
                "mlx_swift_latest": {"tag": "0.31.6"},
                "mlx_swift_lm_latest": {"tag": "3.31.4"},
                "swift_transformers_latest": {"tag": "1.3.3"},
                "swift_jinja_latest": {"tag": "2.4.2"},
            },
            "implementation_signals": {"kvcache_offset_graph_traceable": False},
        }
        self.assertEqual(material_changes(baseline, baseline), (False, "unchanged"))

    def test_new_release_tag_is_material_and_reports_pin(self):
        old = {
            "macprovider_pins": {"mlx_swift": "0.31.4", "mlx_swift_lm": "3.31.4"},
            "blockers": {
                "mlx_swift_lm_406_compile_kv_offset": {"state": "OPEN"},
                "mlx_swift_lm_364_gemma_moe": {"state": "MERGED", "merged_at": "x"},
                "mlx_swift_lm_312_quantized_cache_ownership": {"state": "OPEN"},
                "mlx_swift_lm_453_typed_cache_storage": {"state": "MERGED", "merged_at": "x"},
                "mlx_swift_lm_424_speculative_cache_wrap": {"state": "OPEN"},
                "mlx_swift_lm_518_remote_package_unsafe_flags": {"state": "OPEN"},
            },
            "releases": {
                "mlx_swift_latest": {"tag": "0.31.6"},
                "mlx_swift_lm_latest": {"tag": "3.31.4"},
                "swift_transformers_latest": {"tag": "1.3.3"},
                "swift_jinja_latest": {"tag": "2.4.2"},
            },
            "implementation_signals": {"kvcache_offset_graph_traceable": False},
        }
        new = json.loads(json.dumps(old))
        new["releases"]["mlx_swift_lm_latest"]["tag"] = "3.32.0"
        changed, reason = material_changes(old, new)
        self.assertTrue(changed)
        self.assertIn("3.31.4 -> 3.32.0", reason)
        self.assertIn("pin 3.31.4", reason)

    def test_resolved_revision_change_is_material(self):
        old = {
            "macprovider_pins": {"mlx_swift": "0.31.4", "mlx_swift_revision": "old"},
            "blockers": {key: {"state": "OPEN"} for key in (
                "mlx_swift_lm_406_compile_kv_offset",
                "mlx_swift_lm_364_gemma_moe",
                "mlx_swift_lm_312_quantized_cache_ownership",
                "mlx_swift_lm_453_typed_cache_storage",
                "mlx_swift_lm_424_speculative_cache_wrap",
                "mlx_swift_lm_518_remote_package_unsafe_flags",
            )},
            "releases": {key: {"tag": None} for key in (
                "mlx_swift_lm_latest", "mlx_swift_latest",
                "swift_transformers_latest", "swift_jinja_latest",
            )},
            "implementation_signals": {"kvcache_offset_graph_traceable": False},
        }
        new = json.loads(json.dumps(old))
        new["macprovider_pins"]["mlx_swift_revision"] = "new"
        self.assertEqual(
            material_changes(old, new),
            (True, "resolved production pin graph changed"),
        )

    def test_snapshot_merge_preserves_reviewed_metadata_and_watchlist(self):
        old = self._baseline()
        old["blockers"]["mlx_swift_lm_364_gemma_moe"]["status"] = "awaiting_release_tag"
        old["trackers"] = {"mlx_swift_lm_364_gemma_moe": "#700"}
        old["watchlist"] = {"omlx": {"latest_release_tag": "v0.5.7"}}
        old["blockers"]["reviewed_only"] = {"state": "OPEN", "status": "blocked"}
        new = self._baseline()
        new["blockers"]["mlx_swift_lm_364_gemma_moe"]["updated_at"] = "new"

        merged = merge_snapshot(old, new)

        self.assertEqual(
            merged["blockers"]["mlx_swift_lm_364_gemma_moe"]["status"],
            "awaiting_release_tag",
        )
        self.assertEqual(merged["trackers"]["mlx_swift_lm_364_gemma_moe"], "#700")
        self.assertEqual(merged["watchlist"]["omlx"]["latest_release_tag"], "v0.5.7")
        self.assertEqual(merged["blockers"]["reviewed_only"]["status"], "blocked")
        self.assertEqual(
            merged["blockers"]["mlx_swift_lm_364_gemma_moe"]["updated_at"], "new"
        )


if __name__ == "__main__":
    unittest.main()