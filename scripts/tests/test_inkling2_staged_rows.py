"""#2467: the staged Inkling-2-Mini catalog row validates against the live tooling.

The row in `docs/evidence/inkling-2-mini-intake-2026-11-24/staged-rows.json` is
applied to the signed catalog inputs only at the cut, after the rule-15 speed
gate passes. These tests keep it valid in the meantime: each staged fragment is
merged into a copy of the committed input and run through the same validator
`catalog-release.py generate` uses, and the artifact identity is checked
against the committed snapshot manifest.
"""

from __future__ import annotations

import copy
import json
import unittest

from scripts.tests import test_catalog_artifact_feed as artifact_tests

catalog_release = artifact_tests.catalog_release
ROOT = artifact_tests.ROOT
CATALOG = catalog_release.CATALOG_DIR
STAGED_PATH = ROOT / "docs" / "evidence" / "inkling-2-mini-intake-2026-11-24" / "staged-rows.json"
KEY = "thinkingmachines/inkling-2-mini"
HELD_KEY = "openuncensored/inkling-2-mini-uncensored"


def staged() -> dict:
    return json.loads(STAGED_PATH.read_text())


def staged_row() -> dict:
    return staged()["rows"][KEY]


def at_cut(row: dict) -> dict:
    """The artifact entry as the cut writes it: verified on the cut date."""
    entry = copy.deepcopy(row["artifact_source_entry"])
    artifact = entry["artifacts"][entry["primary_artifact_id"]]
    artifact["verification_status"] = "verified"
    artifact["verified_at"] = "2026-11-24"
    return entry


def merged_candidates(row: dict) -> dict:
    value = json.loads((CATALOG / "autotune-candidates.json").read_text())
    value["rows"][KEY] = row["candidate_row"]
    return value


class StagedInkling2RowTests(unittest.TestCase):
    def test_only_the_original_row_is_staged_and_the_uncensored_row_is_held(self):
        value = staged()
        self.assertEqual(value["schema_version"], "macprovider.staged-catalog-rows.v1")
        self.assertEqual(set(value["rows"]), {KEY})
        self.assertEqual(set(value["held"]), {HELD_KEY})
        self.assertIsNone(value["held"][HELD_KEY]["served_artifact"])

    def test_snapshot_manifest_is_committed_and_matches_the_row(self):
        row = staged_row()
        entry = row["artifact_source_entry"]
        artifact = entry["artifacts"][entry["primary_artifact_id"]]
        path = catalog_release.SNAPSHOT_MANIFESTS_DIR / f"{artifact['hash']}.manifest"
        data = path.read_bytes()
        self.assertEqual(catalog_release.sha256(data), artifact["hash"])
        lines = data.decode("utf-8").split("\n")
        self.assertEqual(lines[-1], "")
        records = [lines[i:i + 3] for i in range(0, len(lines) - 1, 3)]
        paths = [r[0] for r in records]
        self.assertEqual(paths, sorted(set(paths)))
        self.assertEqual(sum(int(r[1]) for r in records), artifact["size_bytes"])
        self.assertIn("mtp.safetensors", paths)
        candidate = row["candidate_row"]
        self.assertEqual(candidate["model_sha256"], artifact["hash"])
        self.assertEqual(candidate["model_id"], artifact["source_ref"]["repo_id"])
        self.assertEqual(candidate["model_revision"], artifact["source_ref"]["revision"])
        for fragment in (row["tier2_catalog_model"], row["tier2_identity_binding_model"]):
            self.assertEqual(fragment["sha256"], artifact["hash"])
            self.assertEqual(fragment["model_id"], candidate["model_id"])
            self.assertEqual(fragment["min_ram_gb"], candidate["min_ram_gb"])

    def test_candidate_row_validates_in_the_committed_catalog(self):
        value = merged_candidates(staged_row())
        catalog_release.validate_candidate(json.dumps(value).encode("utf-8"))

    def test_artifact_entry_is_declared_now_and_valid_listed_at_the_cut(self):
        row = staged_row()
        entry = row["artifact_source_entry"]
        catalog_release.validate_artifact_models({KEY: entry}, "staged", allow_unmeasured_size=False)
        candidates = merged_candidates(row)
        only = {"rows": {KEY: candidates["rows"][KEY]}}
        with self.assertRaisesRegex(catalog_release.CatalogError, "requires a verified primary artifact"):
            catalog_release.require_primary_artifact_consistency({KEY: entry}, only, "staged")
        cut = at_cut(row)
        catalog_release.validate_artifact_models({KEY: cut}, "staged", allow_unmeasured_size=False)
        catalog_release.require_primary_artifact_consistency({KEY: cut}, only, "staged")
        source = json.loads((CATALOG / "autotune-artifacts-source.json").read_text())
        source["models"][KEY] = cut
        catalog_release.require_unique_artifact_hashes(source["models"], "staged")

    def test_rate_row_validates_and_the_served_id_resolves_to_it(self):
        row = staged_row()
        source = json.loads((CATALOG / "rate-card-source.json").read_text())
        self.assertNotIn(KEY, source["rows"])
        source["rows"][KEY] = row["rate_card_row"]
        catalog_release.validate_rate_card_source(json.dumps(source).encode("utf-8"))
        served = row["candidate_row"]["model_id"]
        self.assertEqual(catalog_release.normalize_model_key(served), KEY)
        self.assertEqual(catalog_release.normalize_model_key(KEY), KEY)
        self.assertEqual(catalog_release.normalize_model_key("inkling-2-mini"), KEY)
        # The uncensored build never bills as the original.
        self.assertNotEqual(catalog_release.normalize_model_key("OpenUncensored/Inkling-2-Mini-Uncensored"), KEY)
        acks = {(a["model"], a["from_row"], a["to_row"]) for a in row["acknowledged_pricing_moves"]}
        self.assertEqual(acks, {(served, "default", KEY), (KEY, "default", KEY)})

    def test_coordinator_rewards_row_matches_the_rate_row(self):
        row = staged_row()
        block = row["coordinator_rewards_row"]
        self.assertTrue(block.startswith(f"    {KEY}:"))
        rates = row["rate_card_row"]
        for source_field, yaml_field in catalog_release.COORDINATOR_RATE_FIELD_MAP.items():
            self.assertIn(f"{yaml_field}: {rates[source_field]} ", block)


if __name__ == "__main__":
    unittest.main()
