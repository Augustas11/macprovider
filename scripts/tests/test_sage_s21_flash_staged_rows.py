"""#2466: the Sage S2.1 Flash catalog row validates against the live tooling.

The row stays in `docs/evidence/sage-s2.1-flash-intake-2026-11-26/staged-rows.json`
until the signed catalog release that lists it. Each staged fragment is merged
into a copy of the committed input and run through the validator
`catalog-release.py generate` uses, the artifact identity is checked against
the committed snapshot manifest, and the placement and price are pinned to the
zai-org/glm-5.3-flash row it is a fine-tune of.
"""

from __future__ import annotations

import importlib.util
import json
import unittest

from scripts.tests import test_catalog_artifact_feed as artifact_tests

catalog_release = artifact_tests.catalog_release
ROOT = artifact_tests.ROOT
CATALOG = catalog_release.CATALOG_DIR
STAGED_PATH = ROOT / "docs" / "evidence" / "sage-s2.1-flash-intake-2026-11-26" / "staged-rows.json"
KEY = "hygaard/sage-s2.1-flash-oq4e-mtp"
SERVED = "Hygaard/Sage-S2.1-Flash-oQ4e-mtp"
GLM = "zai-org/glm-5.3-flash"


def load(name: str) -> dict:
    return json.loads((CATALOG / name).read_text())


def staged() -> dict:
    return json.loads(STAGED_PATH.read_text())


def row() -> dict:
    return staged()["rows"][KEY]


def primary(entry: dict) -> dict:
    return entry["artifacts"][entry["primary_artifact_id"]]


def manifest_records(sha: str) -> list[list[str]]:
    data = (catalog_release.SNAPSHOT_MANIFESTS_DIR / f"{sha}.manifest").read_bytes()
    assert catalog_release.sha256(data) == sha
    lines = data.decode("utf-8").split("\n")
    return [lines[i:i + 3] for i in range(0, len(lines) - 1, 3)]


class StagedSageRowTests(unittest.TestCase):
    def test_only_the_sage_row_is_staged_and_it_is_not_yet_in_the_catalog(self):
        value = staged()
        self.assertEqual(value["schema_version"], "macprovider.staged-catalog-rows.v1")
        self.assertEqual(value["issue"], 2466)
        self.assertEqual(set(value["rows"]), {KEY})
        # SPEC-023 §16.3: a new key enters as `listed`; only a later release promotes it.
        self.assertEqual(row()["candidate_row"]["runtime_status"], "listed")
        self.assertIs(row()["demand_rank_row"]["recommendable"], False)
        self.assertNotIn(KEY, load("autotune-candidates.json")["rows"])
        self.assertNotIn(KEY, load("rate-card-source.json")["rows"])

    def test_identity_fragments_agree(self):
        r = row()
        artifact, candidate = primary(r["artifact_source_entry"]), r["candidate_row"]
        self.assertEqual(candidate["model_id"], SERVED)
        self.assertEqual(candidate["model_sha256"], artifact["hash"])
        self.assertEqual(candidate["model_id"], artifact["source_ref"]["repo_id"])
        self.assertEqual(candidate["model_revision"], artifact["source_ref"]["revision"])
        self.assertEqual(candidate["min_ram_gb"], artifact["min_ram_gb"])
        for fragment in (r["tier2_catalog_model"], r["tier2_identity_binding_model"]):
            self.assertEqual(fragment["sha256"], artifact["hash"])
            self.assertEqual(fragment["model_id"], SERVED)
            self.assertEqual(fragment["min_ram_gb"], candidate["min_ram_gb"])
        self.assertEqual(r["tier2_identity_binding_model"]["model_revision"], candidate["model_revision"])
        self.assertEqual(r["tier2_identity_binding_model"]["catalog_key"], KEY)
        facts = r["model_facts_row"]
        self.assertEqual((facts["model_id"], facts["model_revision"]), (SERVED, candidate["model_revision"]))

    def test_snapshot_manifest_is_committed_and_matches_the_row(self):
        artifact = primary(row()["artifact_source_entry"])
        records = manifest_records(artifact["hash"])
        paths = [r[0] for r in records]
        self.assertEqual(paths, sorted(set(paths)))
        self.assertEqual(len(records), 71)
        self.assertEqual(sum(int(r[1]) for r in records), artifact["size_bytes"])
        self.assertIn("config.json", paths)
        # The GLM-5.3-Flash tokenizer, byte for byte.
        glm = primary(load("autotune-artifacts-source.json")["models"][GLM])
        tokenizer = {r[0]: r[2] for r in manifest_records(glm["hash"])}["tokenizer.json"]
        self.assertEqual({r[0]: r[2] for r in records}["tokenizer.json"], tokenizer)

    def test_row_mirrors_the_glm53_flash_placement_and_price(self):
        r = row()
        glm_candidate = load("autotune-candidates.json")["rows"][GLM]
        glm_entry = load("autotune-artifacts-source.json")["models"][GLM]
        self.assertEqual(r["candidate_row"]["min_bandwidth_tier"], glm_candidate["min_bandwidth_tier"])
        self.assertEqual(r["candidate_row"]["bench_gate"]["max_4k_ttft_ms"], glm_candidate["bench_gate"]["max_4k_ttft_ms"])
        self.assertEqual(r["artifact_source_entry"]["rate_class"], glm_entry["rate_class"])
        for field in ("runtime_format", "allowed_runtime_sources", "hash_algorithm"):
            self.assertEqual(primary(r["artifact_source_entry"])[field], primary(glm_entry)[field], field)
        # Larger served weights than the base row: never below its RAM floor.
        self.assertGreaterEqual(r["candidate_row"]["min_ram_gb"], glm_candidate["min_ram_gb"])
        # Fine-tunes carry their base's price under their own labelled row.
        self.assertEqual(r["rate_card_row"], load("rate-card-source.json")["rows"][GLM])
        self.assertEqual(r["demand_rank_row"], {**load("demand-rank.json")["rows"]["zai-org/glm-5.3-flash-uncensored"],
                                                "recommendable": False})

    def test_candidate_row_validates_in_the_committed_catalog(self):
        value = load("autotune-candidates.json")
        value["rows"][KEY] = row()["candidate_row"]
        catalog_release.validate_candidate(json.dumps(value).encode("utf-8"))

    def test_artifact_entry_validates(self):
        entry = row()["artifact_source_entry"]
        catalog_release.validate_artifact_models({KEY: entry}, "staged", allow_unmeasured_size=False)
        catalog_release.require_primary_artifact_consistency(
            {KEY: entry}, {"rows": {KEY: row()["candidate_row"]}}, "staged")
        source = load("autotune-artifacts-source.json")
        source["models"][KEY] = entry
        catalog_release.require_unique_artifact_hashes(source["models"], "staged")

    def test_rate_row_validates_and_the_served_id_resolves_to_it(self):
        r = row()
        source = load("rate-card-source.json")
        source["rows"][KEY] = r["rate_card_row"]
        catalog_release.validate_rate_card_source(json.dumps(source).encode("utf-8"))
        for model in (SERVED, KEY):
            self.assertEqual(catalog_release.normalize_model_key(model), KEY, model)
        # The fine-tune never bills as GLM-5.3-Flash.
        self.assertNotEqual(catalog_release.normalize_model_key(SERVED), GLM)
        acks = {(a["model"], a["from_row"], a["to_row"]) for a in r["acknowledged_pricing_moves"]}
        self.assertEqual(acks, {(SERVED, "default", KEY), (KEY, "default", KEY)})

    def test_coordinator_rewards_row_matches_the_rate_row(self):
        r = row()
        block = r["coordinator_rewards_row"]
        self.assertTrue(block.startswith(f"    {KEY}:"))
        for source_field, yaml_field in catalog_release.COORDINATOR_RATE_FIELD_MAP.items():
            self.assertIn(f"{yaml_field}: {r['rate_card_row'][source_field]} ", block)

    def test_model_facts_row_validates(self):
        spec = importlib.util.spec_from_file_location("model_facts", ROOT / "scripts" / "model-facts.py")
        model_facts = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(model_facts)
        facts = json.loads((CATALOG / "model-facts.json").read_text())
        facts["rows"][KEY] = row()["model_facts_row"]
        model_facts.validate(facts)
        self.assertEqual(row()["model_facts_row"]["capabilities"], facts["rows"][GLM]["capabilities"])

    def test_native_mtp_variant_needs_its_own_fit_evidence(self):
        """R012 (SPEC-048 0.1.126): Sage's served weights exceed GLM-5.3-Flash's,
        so an MTP-13 variant of it must bind its own R015 fit evidence."""
        artifacts = {"models": {KEY: row()["artifact_source_entry"],
                                GLM: load("autotune-artifacts-source.json")["models"][GLM]}}
        own = catalog_release.native_mtp_weight_bytes(artifacts, KEY, "mlx-oq4e-mtp")
        donor = catalog_release.native_mtp_weight_bytes(artifacts, GLM, "mlx-oq4e-mtp")
        self.assertGreater(own, donor)


if __name__ == "__main__":
    unittest.main()
