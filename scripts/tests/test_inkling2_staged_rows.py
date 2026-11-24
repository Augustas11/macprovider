"""#2467: the Inkling-2-Mini catalog rows validate against the live tooling.

The base row was listed in release
published-2026-11-24-inkling-2-mini-listed-v289 and promoted to recommendable in
published-2026-11-24-inkling-2-mini-recommendable-v296; its fragments are read
back from the signed catalog inputs. The uncensored row stays in
`docs/evidence/inkling-2-mini-intake-2026-11-24/staged-rows.json` until its
artifact is published: each staged fragment is merged into a copy of the
committed input and run through the same validator `catalog-release.py
generate` uses, and the artifact identity is checked against the committed
snapshot manifest. The uncensored row's artifact is
published by `scripts/lab/2467/job-inkling2-uncensored.sh`; until then its
revision, manifest hash and size are the placeholders its `placeholders` block
names, and once filled its snapshot manifest must be committed and match.
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
UNC_KEY = "openuncensored/inkling-2-mini-uncensored"
UNC_SERVED = "aug11/Inkling-2-Mini-oQ4e-mtp-uncensored"
PLACEHOLDER_REVISION = "0" * 40
PLACEHOLDER_SHA256 = "0" * 64
AUP = "https://thinkingmachines.ai/model-acceptable-use-policy/"


def staged() -> dict:
    return json.loads(STAGED_PATH.read_text())


def listed_base_row() -> dict:
    """The base row's fragments as the signed catalog inputs carry them."""
    def load(name: str) -> dict:
        return json.loads((CATALOG / name).read_text())
    candidate = load("autotune-candidates.json")["rows"][KEY]
    sha = candidate["model_sha256"]
    lines = catalog_release.COORDINATOR_YAML_PATH.read_text().splitlines(keepends=True)
    start = next(i for i, line in enumerate(lines) if line.startswith(f"    {KEY}:"))
    return {
        "candidate_row": candidate,
        "artifact_source_entry": load("autotune-artifacts-source.json")["models"][KEY],
        "rate_card_row": load("rate-card-source.json")["rows"][KEY],
        "acknowledged_pricing_moves": [m for m in load("acknowledged-pricing-moves.json")["moves"] if m["to_row"] == KEY],
        "demand_rank_row": load("demand-rank.json")["rows"][KEY],
        "tier2_catalog_model": next(m for m in load("tier2-catalog.json")["models"] if m["sha256"] == sha),
        "tier2_identity_binding_model": next(m for m in load("tier2-identity-binding.json")["models"] if m["catalog_key"] == KEY),
        "coordinator_rewards_row": "".join(lines[start:start + 4]),
    }


def staged_row(key: str = KEY) -> dict:
    if key == KEY:
        return listed_base_row()
    return staged()["rows"][key]


def primary(row: dict) -> dict:
    entry = row["artifact_source_entry"]
    return entry["artifacts"][entry["primary_artifact_id"]]


def at_cut(row: dict) -> dict:
    """The artifact entry as the cut writes it: verified on the cut date."""
    entry = copy.deepcopy(row["artifact_source_entry"])
    artifact = entry["artifacts"][entry["primary_artifact_id"]]
    artifact["verification_status"] = "verified"
    artifact["verified_at"] = "2026-11-24"
    return entry


def merged_candidates(*keys: str) -> dict:
    value = json.loads((CATALOG / "autotune-candidates.json").read_text())
    for key in keys or (KEY,):
        value["rows"][key] = staged_row(key)["candidate_row"]
    return value


def check_manifest(case: unittest.TestCase, artifact: dict) -> list[str]:
    path = catalog_release.SNAPSHOT_MANIFESTS_DIR / f"{artifact['hash']}.manifest"
    data = path.read_bytes()
    case.assertEqual(catalog_release.sha256(data), artifact["hash"])
    lines = data.decode("utf-8").split("\n")
    case.assertEqual(lines[-1], "")
    records = [lines[i:i + 3] for i in range(0, len(lines) - 1, 3)]
    paths = [r[0] for r in records]
    case.assertEqual(paths, sorted(set(paths)))
    case.assertEqual(sum(int(r[1]) for r in records), artifact["size_bytes"])
    return paths


class StagedInkling2RowTests(unittest.TestCase):
    def test_only_the_uncensored_row_is_staged_and_the_base_is_recommendable(self):
        value = staged()
        self.assertEqual(value["schema_version"], "macprovider.staged-catalog-rows.v1")
        self.assertEqual(set(value["rows"]), {UNC_KEY})
        self.assertNotIn("held", value)
        self.assertEqual(staged_row()["candidate_row"]["runtime_status"], "recommendable")
        self.assertIs(staged_row()["demand_rank_row"]["recommendable"], True)
        self.assertEqual(primary(staged_row())["verification_status"], "verified")

    def test_identity_fragments_agree_within_each_row(self):
        for key in (KEY, UNC_KEY):
            row = staged_row(key)
            artifact = primary(row)
            candidate = row["candidate_row"]
            self.assertEqual(candidate["model_sha256"], artifact["hash"], key)
            self.assertEqual(candidate["model_id"], artifact["source_ref"]["repo_id"], key)
            self.assertEqual(candidate["model_revision"], artifact["source_ref"]["revision"], key)
            for fragment in (row["tier2_catalog_model"], row["tier2_identity_binding_model"]):
                self.assertEqual(fragment["sha256"], artifact["hash"], key)
                self.assertEqual(fragment["model_id"], candidate["model_id"], key)
                self.assertEqual(fragment["min_ram_gb"], candidate["min_ram_gb"], key)
            self.assertEqual(row["tier2_identity_binding_model"]["model_revision"], candidate["model_revision"], key)
            self.assertEqual(row["tier2_identity_binding_model"]["catalog_key"], key)

    def test_snapshot_manifest_is_committed_and_matches_the_row(self):
        self.assertIn("mtp.safetensors", check_manifest(self, primary(staged_row())))

    def test_uncensored_identity_is_a_placeholder_until_published(self):
        row = staged_row(UNC_KEY)
        artifact, candidate, held = primary(row), row["candidate_row"], row["placeholders"]
        self.assertEqual(candidate["model_id"], UNC_SERVED)
        if candidate["model_sha256"] == PLACEHOLDER_SHA256:
            # Before the publish step every identity field is exactly the declared placeholder.
            self.assertEqual((held["model_revision"], held["model_sha256"]), (PLACEHOLDER_REVISION, PLACEHOLDER_SHA256))
            self.assertEqual(candidate["model_revision"], PLACEHOLDER_REVISION)
            self.assertEqual(artifact["source_ref"]["revision"], PLACEHOLDER_REVISION)
            self.assertEqual(artifact["size_bytes"], held["size_bytes"])
            self.assertEqual(artifact["size_bytes"], primary(staged_row())["size_bytes"])
            self.assertEqual(artifact["verification_status"], "declared")
        else:
            # After it, the published artifact's manifest is committed like any other row's.
            self.assertNotEqual(candidate["model_revision"], PLACEHOLDER_REVISION)
            self.assertIn("mtp.safetensors", check_manifest(self, artifact))
        self.assertNotEqual(artifact["hash"], primary(staged_row())["hash"])

    def test_uncensored_row_mirrors_the_base_placement_and_price(self):
        base, unc = staged_row(), staged_row(UNC_KEY)
        for field in ("min_bandwidth_tier", "min_ram_gb"):
            self.assertEqual(unc["candidate_row"][field], base["candidate_row"][field], field)
        # SPEC-023 §16.3: a new key enters as `listed`; only a later release promotes it.
        self.assertEqual(unc["candidate_row"]["runtime_status"], "listed")
        self.assertEqual(unc["artifact_source_entry"]["rate_class"], base["artifact_source_entry"]["rate_class"])
        for field in ("quantization", "runtime_format", "allowed_runtime_sources", "min_ram_gb", "hash_algorithm"):
            self.assertEqual(primary(unc)[field], primary(base)[field], field)
        # Abliterated and uncensored rows carry their base's price under their own labelled row.
        self.assertEqual(unc["rate_card_row"], base["rate_card_row"])
        self.assertEqual(unc["demand_rank_row"], {**base["demand_rank_row"], "recommendable": False})

    def test_uncensored_licence_note(self):
        row = staged_row(UNC_KEY)
        for notes in (row["candidate_row"]["notes"], primary(row)["notes"]):
            self.assertIn("Apache-2.0", notes)
            self.assertIn(AUP, notes)
            self.assertIn("operator decision 2026-11-24 to list", notes)
        self.assertEqual(row["licence"], {"license": "apache-2.0", "acceptable_use_policy": AUP,
                                          "operator_decision": "2026-11-24: list"})
        source = row["source_identity"]
        self.assertEqual(source["source_snapshot_manifest_sha256"],
                         "050f1cec9aa9a78bb4b365bebf5cb4758e531713943bd2e8208d43ffd5c869e2")
        self.assertEqual(source["never_loaded"], ["edit.pt"])

    def test_candidate_rows_validate_in_the_committed_catalog(self):
        value = merged_candidates(KEY, UNC_KEY)
        catalog_release.validate_candidate(json.dumps(value).encode("utf-8"))

    def test_artifact_entries_are_valid_and_the_staged_one_is_declared_until_its_cut(self):
        source = json.loads((CATALOG / "autotune-artifacts-source.json").read_text())
        candidates = merged_candidates(KEY, UNC_KEY)
        base = staged_row()["artifact_source_entry"]
        catalog_release.validate_artifact_models({KEY: base}, "listed", allow_unmeasured_size=False)
        catalog_release.require_primary_artifact_consistency({KEY: base}, {"rows": {KEY: candidates["rows"][KEY]}}, "listed")
        row = staged_row(UNC_KEY)
        entry = row["artifact_source_entry"]
        catalog_release.validate_artifact_models({UNC_KEY: entry}, "staged", allow_unmeasured_size=False)
        only = {"rows": {UNC_KEY: candidates["rows"][UNC_KEY]}}
        with self.assertRaisesRegex(catalog_release.CatalogError, "requires a verified primary artifact"):
            catalog_release.require_primary_artifact_consistency({UNC_KEY: entry}, only, "staged")
        cut = at_cut(row)
        catalog_release.validate_artifact_models({UNC_KEY: cut}, "staged", allow_unmeasured_size=False)
        catalog_release.require_primary_artifact_consistency({UNC_KEY: cut}, only, "staged")
        source["models"][UNC_KEY] = cut
        catalog_release.require_unique_artifact_hashes(source["models"], "staged")

    def test_rate_row_validates_and_the_served_id_resolves_to_it(self):
        row = staged_row()
        source = json.loads((CATALOG / "rate-card-source.json").read_text())
        self.assertIn(KEY, source["rows"])
        self.assertNotIn(UNC_KEY, source["rows"])
        source["rows"][KEY] = row["rate_card_row"]
        source["rows"][UNC_KEY] = staged_row(UNC_KEY)["rate_card_row"]
        catalog_release.validate_rate_card_source(json.dumps(source).encode("utf-8"))
        served = row["candidate_row"]["model_id"]
        self.assertEqual(catalog_release.normalize_model_key(served), KEY)
        self.assertEqual(catalog_release.normalize_model_key(KEY), KEY)
        self.assertEqual(catalog_release.normalize_model_key("inkling-2-mini"), KEY)
        # The uncensored build never bills as the original.
        self.assertNotEqual(catalog_release.normalize_model_key("OpenUncensored/Inkling-2-Mini-Uncensored"), KEY)
        acks = {(a["model"], a["from_row"], a["to_row"]) for a in row["acknowledged_pricing_moves"]}
        self.assertEqual(acks, {(served, "default", KEY), (KEY, "default", KEY)})

    def test_uncensored_served_id_resolves_to_its_own_row(self):
        row = staged_row(UNC_KEY)
        for model in (UNC_SERVED, UNC_KEY, "inkling-2-mini-uncensored", "OpenUncensored/Inkling-2-Mini-Uncensored"):
            self.assertEqual(catalog_release.normalize_model_key(model), UNC_KEY, model)
        acks = {(a["model"], a["from_row"], a["to_row"]) for a in row["acknowledged_pricing_moves"]}
        self.assertEqual(acks, {(UNC_SERVED, "default", UNC_KEY), (UNC_KEY, "default", UNC_KEY)})

    def test_coordinator_rewards_rows_match_the_rate_rows(self):
        for key in (KEY, UNC_KEY):
            row = staged_row(key)
            block = row["coordinator_rewards_row"]
            self.assertTrue(block.startswith(f"    {key}:"))
            rates = row["rate_card_row"]
            for source_field, yaml_field in catalog_release.COORDINATOR_RATE_FIELD_MAP.items():
                self.assertIn(f"{yaml_field}: {rates[source_field]} ", block)


if __name__ == "__main__":
    unittest.main()
