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

    def test_committed_policy_is_unchanged_and_carries_no_ceiling(self):
        for entry in self.policy["entries"]:
            self.assertNotIn("max_served_slots", entry)
        regenerated = catalog_release.default_cb_policy(
            CANDIDATE_BYTES, CANDIDATE_OBJ, signer_key_id=self.policy["signer_key_id"]
        )
        self.assertEqual(regenerated, CB_POLICY_BYTES.rstrip(b"\n"))

    def test_signed_ceiling_validates(self):
        for value in (1, 4, catalog_release.CB_MAX_SERVED_SLOTS_LIMIT):
            data = with_ceiling(self.policy, 0, value)
            validated = catalog_release.validate_cb_policy(data, CANDIDATE_BYTES, CANDIDATE_OBJ)
            self.assertEqual(validated["entries"][0]["max_served_slots"], value)

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
        self.assertLess(catalog_release.CB_POLICY_CONSUMER_FLOOR, (0, 22, 28))
        with self.assertRaisesRegex(catalog_release.CatalogError, "CB_POLICY_CONSUMER_FLOOR"):
            catalog_release.require_cb_policy_consumer_floor(entries)
        catalog_release.require_cb_policy_consumer_floor(entries, floor=(0, 22, 28))
        catalog_release.require_cb_policy_consumer_floor([{"model_key": "m"}])

    def test_generator_refuses_an_authored_ceiling_below_the_floor(self):
        source = catalog_release.cb_policy_source_entries()
        self.assertTrue(source, "committed policy source has entries")
        source[0]["max_served_slots"] = 4
        original = catalog_release.cb_policy_source_entries
        catalog_release.cb_policy_source_entries = lambda: [dict(entry) for entry in source]
        try:
            with self.assertRaisesRegex(catalog_release.CatalogError, "max_served_slots needs every consumer"):
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
