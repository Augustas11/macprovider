"""#2466: the Sage S2.1 Flash catalog rows in the signed release.

The row was listed in release published-2026-11-26-sage-s21-flash-listed-v296.
Its fragments are read back from the committed catalog inputs: the identity
fields agree across the candidate, artifact-source, Tier-2 and model-facts rows,
the artifact identity matches the committed snapshot manifest, the placement
and price are pinned to the zai-org/glm-5.3-flash row it is a fine-tune of, and
the coordinator rewards row carries the rate-card row.
"""

from __future__ import annotations

import json
import re
import unittest

from scripts.tests import test_catalog_artifact_feed as artifact_tests

catalog_release = artifact_tests.catalog_release
ROOT = artifact_tests.ROOT
CATALOG = catalog_release.CATALOG_DIR
COORDINATOR_YAML = ROOT / "phase4-coordinator" / "dist" / "coordinator.yaml"
RELEASE_ID = "published-2026-11-26-sage-s21-flash-listed-v296"
KEY = "hygaard/sage-s2.1-flash-oq4e-mtp"
SERVED = "Hygaard/Sage-S2.1-Flash-oQ4e-mtp"
REVISION = "a972e256db2553562bd718e677d100089aca5fce"
SHA = "d59ecd8525692c53ea9dd36d5e690d4c3218713f0b0a81fec77637e1f588c261"
GLM = "zai-org/glm-5.3-flash"


def load(name: str) -> dict:
    return json.loads((CATALOG / name).read_text())


def primary(entry: dict) -> dict:
    return entry["artifacts"][entry["primary_artifact_id"]]


def by_model_id(rows: list[dict], model_id: str) -> dict:
    matches = [r for r in rows if r["model_id"] == model_id]
    assert len(matches) == 1, model_id
    return matches[0]


def manifest_records(sha: str) -> list[list[str]]:
    data = (catalog_release.SNAPSHOT_MANIFESTS_DIR / f"{sha}.manifest").read_bytes()
    assert catalog_release.sha256(data) == sha
    lines = data.decode("utf-8").split("\n")
    return [lines[i:i + 3] for i in range(0, len(lines) - 1, 3)]


class SageCatalogRowTests(unittest.TestCase):
    def test_listed_in_the_signed_release(self):
        self.assertEqual(load("release.json")["release_id"], RELEASE_ID)
        self.assertIn(RELEASE_ID, load("release-ledger.json")["releases"])
        candidate = load("autotune-candidates.json")["rows"][KEY]
        # SPEC-023 §16.3: a new key enters as `listed`; only a later release promotes it.
        self.assertEqual(candidate["runtime_status"], "listed")
        self.assertIs(load("demand-rank.json")["rows"][KEY]["recommendable"], False)
        decisions = load("intake-decision.json")
        self.assertEqual(decisions["release_id"], RELEASE_ID)
        decision = {d["model_key"]: d for d in decisions["decisions"]}[KEY]
        self.assertEqual((decision["action"], decision["admission_clause"], decision["fit_clause"]),
                         ("admit_listed", "coldstart_slot", "tier_target"))
        self.assertEqual(decisions["thresholds"]["tier_target"], "<= 256 GB")
        self.assertLessEqual(candidate["min_ram_gb"] + 4, 256)

    def test_identity_fragments_agree(self):
        candidate = load("autotune-candidates.json")["rows"][KEY]
        entry = load("autotune-artifacts-source.json")["models"][KEY]
        artifact = primary(entry)
        self.assertEqual((candidate["model_id"], candidate["model_revision"], candidate["model_sha256"]),
                         (SERVED, REVISION, SHA))
        self.assertEqual(artifact["hash"], SHA)
        self.assertEqual(artifact["source_ref"], {"kind": "huggingface_revision", "repo_id": SERVED,
                                                  "revision": REVISION})
        self.assertEqual(artifact["min_ram_gb"], candidate["min_ram_gb"])
        tier2 = by_model_id(load("tier2-catalog.json")["models"], SERVED)
        binding = by_model_id(load("tier2-identity-binding.json")["models"], SERVED)
        for fragment in (tier2, binding):
            self.assertEqual(fragment["sha256"], SHA)
            self.assertEqual(fragment["min_ram_gb"], candidate["min_ram_gb"])
        self.assertEqual((binding["catalog_key"], binding["model_revision"]), (KEY, REVISION))
        facts = load("model-facts.json")["rows"][KEY]
        self.assertEqual((facts["model_id"], facts["model_revision"]), (SERVED, REVISION))
        self.assertEqual(facts["capabilities"], load("model-facts.json")["rows"][GLM]["capabilities"])

    def test_snapshot_manifest_is_committed_and_matches_the_row(self):
        artifact = primary(load("autotune-artifacts-source.json")["models"][KEY])
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
        candidates = load("autotune-candidates.json")["rows"]
        sources = load("autotune-artifacts-source.json")["models"]
        row, glm = candidates[KEY], candidates[GLM]
        self.assertEqual(row["min_bandwidth_tier"], glm["min_bandwidth_tier"])
        self.assertEqual(row["bench_gate"]["max_4k_ttft_ms"], glm["bench_gate"]["max_4k_ttft_ms"])
        self.assertEqual(sources[KEY]["rate_class"], sources[GLM]["rate_class"])
        for field in ("runtime_format", "allowed_runtime_sources", "hash_algorithm"):
            self.assertEqual(primary(sources[KEY])[field], primary(sources[GLM])[field], field)
        # Larger served weights than the base row: never below its RAM floor.
        self.assertGreaterEqual(row["min_ram_gb"], glm["min_ram_gb"])
        # Fine-tunes carry their base's price under their own labelled row.
        rates = load("rate-card-source.json")["rows"]
        self.assertEqual(rates[KEY], rates[GLM])
        demand = load("demand-rank.json")["rows"]
        self.assertEqual(demand[KEY], {**demand["zai-org/glm-5.3-flash-uncensored"], "recommendable": False})

    def test_served_id_resolves_to_its_own_rate_row(self):
        for model in (SERVED, KEY):
            self.assertEqual(catalog_release.normalize_model_key(model), KEY, model)
        # The fine-tune never bills as GLM-5.3-Flash.
        self.assertNotEqual(catalog_release.normalize_model_key(SERVED), GLM)
        acks = {(a["model"], a["from_row"], a["to_row"]) for a in load("acknowledged-pricing-moves.json")["moves"]}
        self.assertTrue({(SERVED, "default", KEY), (KEY, "default", KEY)} <= acks)

    def test_coordinator_rewards_row_matches_the_rate_row(self):
        text = COORDINATOR_YAML.read_text()
        match = re.search(rf"^    {re.escape(KEY)}:.*\n((?:      .*\n){{3}})", text, re.MULTILINE)
        self.assertIsNotNone(match)
        rate = load("rate-card-source.json")["rows"][KEY]
        for source_field, yaml_field in catalog_release.COORDINATOR_RATE_FIELD_MAP.items():
            self.assertIn(f"{yaml_field}: {rate[source_field]} ", match.group(1))

    def test_native_mtp_variant_needs_its_own_fit_evidence(self):
        """R012 (SPEC-048 0.1.126): Sage's served weights exceed GLM-5.3-Flash's,
        so an MTP-13 variant of it must bind its own R015 fit evidence."""
        artifacts = load("autotune-artifacts-source.json")
        own = catalog_release.native_mtp_weight_bytes(artifacts, KEY, "mlx-oq4e-mtp")
        donor = catalog_release.native_mtp_weight_bytes(artifacts, GLM, "mlx-oq4e-mtp")
        self.assertGreater(own, donor)


if __name__ == "__main__":
    unittest.main()
