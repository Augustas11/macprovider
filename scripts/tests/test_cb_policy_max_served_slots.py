"""SPEC-038 FR-CB11 (v0.3.22): optional signed `max_served_slots` per CB entry.

The release generator, the live release gate, the coordinator feed validator
and the CLI parser accept the same field: an optional JSON integer in 1..32.
An entry without it keeps its exact pre-v0.3.22 bytes and tuple identity.
"""

from __future__ import annotations

import copy
import importlib.util
import json
import pathlib
import re
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
CATALOG = ROOT / "phase3-binary" / "catalog" / "autotune"


def _load(name: str, relative: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


catalog_release = _load("catalog_release_max_served_slots", "scripts/catalog-release.py")
release_gate = _load("release_gate_max_served_slots", "scripts/verify-live-coordinator-release-gate.py")

CANDIDATE_BYTES = (CATALOG / "autotune-candidates.json").read_bytes()
CANDIDATE_OBJ = catalog_release.validate_candidate(CANDIDATE_BYTES)
CB_POLICY_BYTES = (CATALOG / "continuous-batching-policy.json").read_bytes()
FIELD_FLOOR = (0, 22, 28)
# The floor before the v0.22.28 rollout: no consumer could read the field yet.
PRE_ROLLOUT_FLOOR = (0, 22, 27)
GLM_KEY = "zai-org/glm-5.3-flash"


def lowered_floor():
    """Both loaded copies of cb_release_baselines at the pre-rollout floor."""
    return mock.patch.multiple(
        catalog_release._cb_baselines, CB_POLICY_CONSUMER_FLOOR=PRE_ROLLOUT_FLOOR
    ), mock.patch.multiple(release_gate._cb_baselines, CB_POLICY_CONSUMER_FLOOR=PRE_ROLLOUT_FLOOR)


def start(test: unittest.TestCase, patches) -> None:
    for patch in patches:
        patch.start()
        test.addCleanup(patch.stop)


def with_ceiling(policy: dict, index: int, value: object, *, resign: bool = True) -> bytes:
    changed = copy.deepcopy(policy)
    entry = changed["entries"][index]
    entry["max_served_slots"] = value
    if resign:
        entry["tuple_sha256"] = catalog_release.cb_policy_tuple_sha256(
            release_id=changed["release_id"],
            policy_version=changed["policy_version"],
            generated_at=changed["generated_at"],
            expires_at=changed["expires_at"],
            candidate_catalog_sha256=changed["candidate_catalog_sha256"],
            signer_key_id=changed["signer_key_id"],
            entry=entry,
        )
    return catalog_release.canonical_sorted_bytes(changed)


class MaxServedSlotsGeneratorTest(unittest.TestCase):
    def setUp(self):
        self.policy = catalog_release.validate_cb_policy(CB_POLICY_BYTES, CANDIDATE_BYTES, CANDIDATE_OBJ)
        self.assertTrue(self.policy["entries"], "committed policy has entries to extend")

    def test_committed_policy_caps_qualified_glm_and_qwen8_at_four(self):
        ceilings = {entry["model_key"]: entry.get("max_served_slots") for entry in self.policy["entries"]}
        self.assertEqual(ceilings.pop(GLM_KEY), 4)
        self.assertEqual(ceilings.pop("qwen3-8b"), 4)
        self.assertTrue(ceilings, "committed policy keeps its uncapped entries")
        self.assertEqual(set(ceilings.values()), {None})
        regenerated = catalog_release.default_cb_policy(
            CANDIDATE_BYTES, CANDIDATE_OBJ, signer_key_id=self.policy["signer_key_id"]
        )
        self.assertEqual(regenerated, CB_POLICY_BYTES.rstrip(b"\n"))

    def test_qwen8_policy_preserves_target_qualification_identity(self):
        entry = next(entry for entry in self.policy["entries"] if entry["model_key"] == "qwen3-8b")
        self.assertEqual(entry["rollout"], "on")
        self.assertEqual(entry["hardware_class"], "apple-silicon:Apple M3:ram-16gb")
        self.assertEqual(entry["cache_class"], "KVCacheSimple")
        self.assertFalse(entry["requires_moe"])
        self.assertFalse(entry["cached_turns_accepted"])
        self.assertEqual(entry["provenance"]["source"], "operator_review")
        self.assertEqual(entry["provenance"]["package_manifest_sha256"],
                         "fade093f3684f41bac793e139e6eea276bb73a8543a5bec9e23f4b7c9de552e0")
        self.assertEqual(entry["provenance"]["studio_campaign_sha256"],
                         "ef90fb26ec648d904f97e5bf2bcb41c64b189c940331257b6fd2443f1da85658")

    def test_signed_ceiling_validates(self):
        for value in (1, 4, catalog_release.CB_MAX_SERVED_SLOTS_LIMIT):
            data = with_ceiling(self.policy, 0, value)
            validated = catalog_release.validate_cb_policy(data, CANDIDATE_BYTES, CANDIDATE_OBJ)
            self.assertEqual(validated["entries"][0]["max_served_slots"], value)

    def test_signed_ceiling_is_refused_below_the_consumer_floor(self):
        start(self, lowered_floor())
        data = with_ceiling(self.policy, 0, 4)
        with self.assertRaisesRegex(catalog_release.CatalogError, "CB_POLICY_CONSUMER_FLOOR"):
            catalog_release.validate_cb_policy(data, CANDIDATE_BYTES, CANDIDATE_OBJ)

    def test_malformed_ceiling_is_rejected(self):
        for value in (0, -1, 33, True, False, 4.0, 4.5, "4", None, [4]):
            with self.subTest(value=value):
                data = with_ceiling(self.policy, 0, value)
                with self.assertRaisesRegex(catalog_release.CatalogError, "max_served_slots"):
                    catalog_release.validate_cb_policy(data, CANDIDATE_BYTES, CANDIDATE_OBJ)

    def test_unsigned_ceiling_breaks_the_tuple_identity(self):
        data = with_ceiling(self.policy, 0, 4, resign=False)
        with self.assertRaisesRegex(catalog_release.CatalogError, "tuple_sha256"):
            catalog_release.validate_cb_policy(data, CANDIDATE_BYTES, CANDIDATE_OBJ)


class MaxServedSlotsConsumerFloorTest(unittest.TestCase):
    """SPEC-023 v0.22.28: the generator refuses the field below its consumer floor."""

    def test_floor_refuses_the_field_until_every_consumer_reads_it(self):
        entries = [{"model_key": "m", "max_served_slots": 4}]
        # Raised after CLI 1.8.257 and Pearl runtime v1.8.259 both read the field.
        self.assertGreaterEqual(catalog_release._cb_baselines.CB_POLICY_CONSUMER_FLOOR, FIELD_FLOOR)
        with self.assertRaisesRegex(catalog_release.CatalogError, "CB_POLICY_CONSUMER_FLOOR"):
            catalog_release.require_cb_policy_consumer_floor(entries, floor=PRE_ROLLOUT_FLOOR)
        catalog_release.require_cb_policy_consumer_floor(entries)
        catalog_release.require_cb_policy_consumer_floor([{"model_key": "m"}])

    def test_generator_refuses_an_authored_ceiling_below_the_floor(self):
        start(self, lowered_floor())
        source = catalog_release.cb_policy_source_entries()
        self.assertTrue(source, "committed policy source has entries")
        source[0]["max_served_slots"] = 4
        original = catalog_release.cb_policy_source_entries
        catalog_release.cb_policy_source_entries = lambda: [dict(entry) for entry in source]
        try:
            with self.assertRaisesRegex(catalog_release.CatalogError, "CB_POLICY_CONSUMER_FLOOR"):
                catalog_release.default_cb_policy(CANDIDATE_BYTES, CANDIDATE_OBJ, signer_key_id="test-key")
        finally:
            catalog_release.cb_policy_source_entries = original


class MaxServedSlotsReleaseGateTest(unittest.TestCase):
    def test_live_gate_accepts_a_ceiling_and_rejects_a_malformed_one(self):
        policy = json.loads(CB_POLICY_BYTES)
        baseline_id = "studio-qwen3.6-a3b-v1"
        index = next(
            i for i, entry in enumerate(policy["entries"])
            if release_gate.entry_matches_stable_baseline(entry, release_gate.REQUIRED_CB_BASELINES[baseline_id])
        )
        capped = json.loads(with_ceiling(policy, index, 4))
        with mock.patch.multiple(release_gate._cb_baselines, CB_POLICY_CONSUMER_FLOOR=PRE_ROLLOUT_FLOOR):
            with self.assertRaisesRegex(release_gate.GateError, "CB_POLICY_CONSUMER_FLOOR"):
                release_gate.require_continuous_batching_tuple(capped, baseline_id)
        entry = release_gate.require_continuous_batching_tuple(capped, baseline_id)
        self.assertEqual(entry["max_served_slots"], 4)
        for value in (0, 33, True, "4"):
            with self.subTest(value=value):
                with self.assertRaisesRegex(release_gate.GateError, "max_served_slots"):
                    release_gate.require_continuous_batching_tuple(
                        json.loads(with_ceiling(policy, index, value)), baseline_id
                    )
        unknown = copy.deepcopy(policy)
        unknown["entries"][index]["max_slots"] = 4
        with self.assertRaisesRegex(release_gate.GateError, "unexpected fields"):
            release_gate.require_continuous_batching_tuple(unknown, baseline_id)


class MaxServedSlotsParityTest(unittest.TestCase):
    def test_every_validator_uses_the_served_hard_cap(self):
        swift = (ROOT / "phase3-binary/Sources/macprovider-cli/ProviderStatus.swift").read_text()
        match = re.search(r"static let maxConcurrencyOverrideLimit = (\d+)", swift)
        self.assertIsNotNone(match)
        go = (ROOT / "phase4-coordinator/internal/buyer/continuous_batching_policy_feed.go").read_text()
        go_match = re.search(r"continuousBatchingMaxServedSlotsLimit = (\d+)", go)
        self.assertIsNotNone(go_match)
        self.assertEqual(int(match.group(1)), catalog_release.CB_MAX_SERVED_SLOTS_LIMIT)
        self.assertEqual(int(go_match.group(1)), catalog_release.CB_MAX_SERVED_SLOTS_LIMIT)
        parser = (ROOT / "phase3-binary/Sources/macprovider-cli/ContinuousBatchingSignedPolicy.swift").read_text()
        self.assertIn('"max_served_slots"', parser)
        self.assertIn("ProviderCapacity.maxConcurrencyOverrideLimit", parser)


if __name__ == "__main__":
    unittest.main()
