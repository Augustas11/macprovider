"""SPEC-023 v0.10.x catalog artifact feed + class rate expansion (BYOM v0.2 slice 2a).

Coverage map (SPEC-023 §11):

* AC-CAT-1  — closed feed schema at every level, and signer-identity EQUALITY
              (a valid signature by a different concurrently trusted key).
* AC-CAT-3  — the published candidate catalog gains no `rate_class`, artifact,
              or intake row key.
* AC-CAT-4  — release binding (`version`, `release_id`, `generated_at`,
              `policy_version`, `candidate_catalog_sha256`).
* AC-CAT-5  — primary-artifact consistency, including the `candidate`-row
              all-`declared` carve-out.
* AC-CAT-6  — a `declared` or `blocked` primary artifact cannot carry a
              `listed`/`recommendable` row.
* AC-CAT-8  — the published rate card keeps the §3.3 schema and projection hash.
* AC-CAT-9  — closed `rate-card-source.json`, class precedence, expansion.
* AC-CAT-10 — byte-identical `rows` on the first class-expanded release, and no
              orphan `recommendable` row.
* AC-CAT-11 — a key with no `verified` artifact may not be `listed`.
* AC-CAT-12 — the generator-side half only: nothing here orders or promotes rows.
* AC-CAT-14 — generated-feed / billing-config parity, mutated on both sides.
* AC-CAT-15 — ledger feed sets, artifact-bound activation, downgrade rejection,
              and the unchanged nine-name `components.catalog.files` map.
* AC-CAT-16 — the closed artifact-identity tuple matrix and the GGUF
              `source_ref.digest == "sha256:" + hash` value binding.
* AC-CAT-18 — global `(hash_algorithm, hash)` uniqueness.
* AC-CAT-19 — `artifact_id` grammar, cross-release rebinding, and the concrete
              release-ledger v3 wire shape.

Out of scope for this slice (consumer / coordinator / intake work): AC-CAT-2,
AC-CAT-7, AC-CAT-13, AC-CAT-17, AC-CAT-20, AC-CAT-21.

The end-to-end test stages a complete five-feed release directory signed with a
throwaway Ed25519 key and runs `verify-directory` over it. The only stub is
`verify_tier2_signature`, whose Go-backed signature path is orthogonal to this
slice and is already exercised by `scripts/test-catalog-release.sh`.
"""

from __future__ import annotations

import base64
import copy
import importlib.util
import json
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
CATALOG = ROOT / "phase3-binary" / "catalog" / "autotune"
COORDINATOR_YAML = ROOT / "phase4-coordinator" / "dist" / "coordinator.yaml"


def _load(name: str, relative: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


catalog_release = _load("catalog_release", "scripts/catalog-release.py")
compatibility_set = _load("compatibility_set_manifest", "scripts/compatibility-set-manifest.py")

CANDIDATE_BYTES = (CATALOG / "autotune-candidates.json").read_bytes()
DEMAND_BYTES = (CATALOG / "demand-rank.json").read_bytes()
RATE_CARD_BYTES = (CATALOG / "rate-card.json").read_bytes()
RATE_CARD_SOURCE_BYTES = (CATALOG / "rate-card-source.json").read_bytes()
ARTIFACT_SOURCE_BYTES = (CATALOG / "autotune-artifacts-source.json").read_bytes()
CANDIDATE_OBJ = catalog_release.validate_candidate(CANDIDATE_BYTES)

# A fixture-only measured size; the committed source deliberately carries
# `size_bytes: null` until an operator measures each snapshot.
FIXTURE_SIZE_BYTES = 4_900_000_000
GGUF_HASH = "b" * 64


def canonical(value: dict) -> bytes:
    return catalog_release.canonical_sorted_bytes(value)


def artifact_source() -> dict:
    """The committed operator source with fixture byte counts filled in."""
    source = json.loads(ARTIFACT_SOURCE_BYTES)
    for model in source["models"].values():
        for artifact in model["artifacts"].values():
            artifact["size_bytes"] = FIXTURE_SIZE_BYTES
    return source


def feed_from(source: dict) -> dict:
    """Materialise a published feed object without running the validators."""
    return {
        "candidate_catalog_sha256": catalog_release.sha256(CANDIDATE_BYTES),
        "generated_at": CANDIDATE_OBJ["generated_at"],
        "models": source["models"],
        "policy_version": CANDIDATE_OBJ["policy_version"],
        "release_id": CANDIDATE_OBJ["version"],
        "source": "operator_curated_autotune_artifact_catalog",
        "version": CANDIDATE_OBJ["version"],
    }


def gguf_artifact(hash_hex: str = GGUF_HASH) -> dict:
    return {
        "runtime_format": "gguf",
        "quantization": "Q4_K_M",
        "source_ref": {
            "kind": "ollama_library_tag",
            "library_tag": "qwen3:8b",
            "digest": "sha256:" + hash_hex,
        },
        "hash_algorithm": "macprovider.gguf-file.v1",
        "hash": hash_hex,
        "size_bytes": FIXTURE_SIZE_BYTES,
        "min_ram_gb": 12,
        "allowed_runtime_sources": ["ollama_loopback", "llamacpp_loopback"],
        "verification_status": "declared",
        "verified_at": None,
    }


class ArtifactFeedValidationTest(unittest.TestCase):
    def validate(self, feed: dict, candidate_obj: dict | None = None) -> dict:
        return catalog_release.validate_artifact_feed(
            canonical(feed), CANDIDATE_BYTES, candidate_obj or CANDIDATE_OBJ
        )

    def rejects(self, feed: dict, candidate_obj: dict | None = None) -> str:
        with self.assertRaises(catalog_release.CatalogError) as caught:
            self.validate(feed, candidate_obj)
        return str(caught.exception)

    # --- AC-CAT-1: the schema is CLOSED at every level -------------------------

    def test_seeded_source_materialises_a_valid_feed(self):
        feed = self.validate(feed_from(artifact_source()))
        self.assertEqual(sorted(feed["models"]), sorted(CANDIDATE_OBJ["rows"]))
        for model in feed["models"].values():
            primary = model["artifacts"][model["primary_artifact_id"]]
            self.assertEqual(primary["verification_status"], "verified")
            self.assertEqual(primary["runtime_format"], "mlx_safetensors")

    def test_top_level_schema_is_closed(self):
        base = feed_from(artifact_source())
        unknown = {**base, "extra_field": 1}
        self.assertIn("unknown fields", self.rejects(unknown))
        for field in sorted(base):
            missing = {key: value for key, value in base.items() if key != field}
            self.assertIn("missing fields", self.rejects(missing))
        wrong_type = {**base, "models": []}
        self.assertIn("models", self.rejects(wrong_type))

    def test_model_entry_schema_is_closed(self):
        base = feed_from(artifact_source())
        key = "qwen3-8b"
        unknown = copy.deepcopy(base)
        unknown["models"][key]["artifact_set_version"] = 2
        self.assertIn("unknown fields", self.rejects(unknown))
        missing = copy.deepcopy(base)
        del missing["models"][key]["primary_artifact_id"]
        self.assertIn("missing fields", self.rejects(missing))
        wrong_type = copy.deepcopy(base)
        wrong_type["models"][key]["artifacts"] = []
        self.assertIn("artifacts must be a non-empty object", self.rejects(wrong_type))
        bad_class = copy.deepcopy(base)
        bad_class["models"][key]["rate_class"] = "class-13b"
        self.assertIn("invalid rate_class", self.rejects(bad_class))

    def test_artifact_entry_schema_is_closed(self):
        base = feed_from(artifact_source())
        key, artifact_id = "qwen3-8b", "mlx-4bit"
        unknown = copy.deepcopy(base)
        unknown["models"][key]["artifacts"][artifact_id]["license"] = "apache-2.0"
        self.assertIn("unknown fields", self.rejects(unknown))
        for field in ("runtime_format", "hash", "size_bytes", "verification_status", "verified_at"):
            missing = copy.deepcopy(base)
            del missing["models"][key]["artifacts"][artifact_id][field]
            self.assertIn("missing fields", self.rejects(missing))
        wrong_type = copy.deepcopy(base)
        wrong_type["models"][key]["artifacts"][artifact_id]["size_bytes"] = "4900000000"
        self.assertIn("size_bytes", self.rejects(wrong_type))
        unmeasured = copy.deepcopy(base)
        unmeasured["models"][key]["artifacts"][artifact_id]["size_bytes"] = None
        self.assertIn("must be measured", self.rejects(unmeasured))

    def test_verified_at_must_be_a_bare_full_date(self):
        base = feed_from(artifact_source())
        artifact = base["models"]["qwen3-8b"]["artifacts"]["mlx-4bit"]
        artifact["verified_at"] = "2026-09-02T00:00:00Z"
        self.assertIn("full-date", self.rejects(base))
        artifact["verified_at"] = None
        self.assertIn("full-date", self.rejects(base))
        artifact["verified_at"] = "2026-02-30"
        self.assertIn("not a real date", self.rejects(base))

    def test_source_ref_variants_are_closed(self):
        base = feed_from(artifact_source())
        artifact = base["models"]["qwen3-8b"]["artifacts"]["mlx-4bit"]
        artifact["source_ref"] = {"kind": "git_branch", "repo_id": "a/b", "revision": "0" * 40}
        self.assertIn("source_ref.kind", self.rejects(base))
        # One variant's fields under the other variant's kind.
        artifact["source_ref"] = {
            "kind": "ollama_library_tag", "library_tag": "qwen3:8b", "digest": "sha256:" + "a" * 64,
        }
        self.assertIn("source_ref.kind", self.rejects(base))
        artifact["source_ref"] = {
            "kind": "huggingface_revision", "repo_id": "mlx-community/Qwen3-8B-4bit",
            "revision": "545dc4251c05440727734bcd94334791f6ab0192", "mirror": "https://example.invalid",
        }
        self.assertIn("unknown fields", self.rejects(base))

    def test_mutable_revision_is_rejected(self):
        base = feed_from(artifact_source())
        base["models"]["qwen3-8b"]["artifacts"]["mlx-4bit"]["source_ref"]["revision"] = "main"
        self.assertIn("revision", self.rejects(base))

    # --- AC-CAT-4: release binding --------------------------------------------

    def test_release_binding_disagreement_fails_closed(self):
        for field, value in (
            ("version", "published-2026-10-01-v1"),
            ("release_id", "published-2026-10-01-v1"),
            ("generated_at", "2026-09-03T00:00:00Z"),
            ("policy_version", "autotune-policy-v2"),
            ("candidate_catalog_sha256", "c" * 64),
            ("source", "operator_curated_something_else"),
        ):
            with self.subTest(field=field):
                feed = feed_from(artifact_source())
                feed[field] = value
                self.rejects(feed)

    # --- AC-CAT-5 / AC-CAT-6 / AC-CAT-11: primary-artifact consistency ---------

    def test_primary_artifact_must_match_the_candidate_row(self):
        key = "qwen3-8b"
        for field, value in (
            ("hash", "d" * 64),
            ("min_ram_gb", 99),
        ):
            with self.subTest(field=field):
                feed = feed_from(artifact_source())
                feed["models"][key]["artifacts"]["mlx-4bit"][field] = value
                self.assertIn(field, self.rejects(feed))
        feed = feed_from(artifact_source())
        feed["models"][key]["artifacts"]["mlx-4bit"]["source_ref"]["repo_id"] = "mlx-community/Other-8B-4bit"
        self.assertIn("repo_id", self.rejects(feed))
        feed = feed_from(artifact_source())
        feed["models"][key]["artifacts"]["mlx-4bit"]["source_ref"]["revision"] = "0" * 40
        self.assertIn("revision", self.rejects(feed))

    def test_recommendable_row_requires_a_verified_primary_and_a_rate_class(self):
        feed = feed_from(artifact_source())
        artifact = feed["models"]["qwen3-8b"]["artifacts"]["mlx-4bit"]
        artifact["verification_status"] = "declared"
        artifact["verified_at"] = None
        self.assertIn("requires a verified primary artifact", self.rejects(feed))
        feed = feed_from(artifact_source())
        del feed["models"]["qwen3-8b"]["rate_class"]
        self.assertIn("must declare a rate_class", self.rejects(feed))

    def test_listed_row_requires_a_verified_primary_artifact(self):
        candidate = copy.deepcopy(CANDIDATE_OBJ)
        candidate["rows"]["qwen3-8b"]["runtime_status"] = "listed"
        feed = feed_from(artifact_source())
        # A `listed` row needs no rate class, but still needs verified bytes.
        del feed["models"]["qwen3-8b"]["rate_class"]
        self.validate(feed, candidate)
        artifact = feed["models"]["qwen3-8b"]["artifacts"]["mlx-4bit"]
        artifact["verification_status"] = "declared"
        artifact["verified_at"] = None
        self.assertIn("requires a verified primary artifact", self.rejects(feed, candidate))

    def test_candidate_row_may_stay_declared_but_must_still_be_identity_bound(self):
        candidate = copy.deepcopy(CANDIDATE_OBJ)
        candidate["rows"]["qwen3-8b"]["runtime_status"] = "candidate"
        feed = feed_from(artifact_source())
        artifact = feed["models"]["qwen3-8b"]["artifacts"]["mlx-4bit"]
        artifact["verification_status"] = "declared"
        artifact["verified_at"] = None
        del feed["models"]["qwen3-8b"]["rate_class"]
        self.validate(feed, candidate)
        artifact["hash"] = "e" * 64
        self.assertIn("hash", self.rejects(feed, candidate))

    def test_listed_row_without_a_model_entry_fails_closed(self):
        feed = feed_from(artifact_source())
        del feed["models"]["qwen3-8b"]
        self.assertIn("no artifact-feed model entry", self.rejects(feed))

    def test_model_key_absent_from_the_candidate_catalog_fails_closed(self):
        feed = feed_from(artifact_source())
        clone = copy.deepcopy(feed["models"]["qwen3-8b"])
        clone["artifacts"]["mlx-4bit"]["hash"] = "7" * 64
        feed["models"]["not-a-catalog-key"] = clone
        self.assertIn("absent from the candidate catalog", self.rejects(feed))

    # --- AC-CAT-16: closed identity matrix + GGUF digest binding ---------------

    def test_illegal_identity_tuples_are_rejected(self):
        cases = {
            "mlx with gguf algorithm": ("mlx-4bit", {"hash_algorithm": "macprovider.gguf-file.v1"}),
            "mlx allowing a loopback adapter": ("mlx-4bit", {"allowed_runtime_sources": ["mlx_cache", "ollama_loopback"]}),
        }
        for label, (artifact_id, patch) in cases.items():
            with self.subTest(label):
                feed = feed_from(artifact_source())
                feed["models"]["qwen3-8b"]["artifacts"][artifact_id].update(patch)
                self.rejects(feed)

        gguf_cases = {
            "gguf with snapshot-manifest algorithm": {"hash_algorithm": "macprovider.snapshot-manifest.v1"},
            "gguf allowing mlx_cache": {"allowed_runtime_sources": ["mlx_cache"]},
            "gguf with a huggingface source_ref": {
                "source_ref": {
                    "kind": "huggingface_revision",
                    "repo_id": "mlx-community/Qwen3-8B-4bit",
                    "revision": "545dc4251c05440727734bcd94334791f6ab0192",
                }
            },
            "unknown runtime_format": {"runtime_format": "onnx"},
        }
        for label, patch in gguf_cases.items():
            with self.subTest(label):
                feed = feed_from(artifact_source())
                artifact = gguf_artifact()
                artifact.update(patch)
                feed["models"]["qwen3-8b"]["artifacts"]["gguf-q4-k-m"] = artifact
                self.rejects(feed)

    def test_verified_artifact_may_not_allow_openai_compatible_loopback(self):
        feed = feed_from(artifact_source())
        artifact = gguf_artifact()
        artifact["verification_status"] = "verified"
        artifact["verified_at"] = "2026-09-02"
        artifact["allowed_runtime_sources"] = ["ollama_loopback", "openai_compatible_loopback"]
        feed["models"]["qwen3-8b"]["artifacts"]["gguf-q4-k-m"] = artifact
        self.assertIn("openai_compatible_loopback", self.rejects(feed))
        artifact["verification_status"] = "declared"
        artifact["verified_at"] = None
        self.validate(feed)

    def test_gguf_source_digest_must_equal_sha256_plus_hash(self):
        feed = feed_from(artifact_source())
        artifact = gguf_artifact()
        feed["models"]["qwen3-8b"]["artifacts"]["gguf-q4-k-m"] = artifact
        self.validate(feed)
        for bad_digest in (
            "sha256:" + "c" * 64,
            GGUF_HASH,
            "sha256:" + GGUF_HASH.upper(),
        ):
            with self.subTest(bad_digest[:16]):
                artifact["source_ref"]["digest"] = bad_digest
                self.rejects(feed)

    # --- AC-CAT-18: one hash resolves to one pricing identity ------------------

    def test_duplicate_hash_under_two_model_keys_fails_closed(self):
        feed = feed_from(artifact_source())
        shared = copy.deepcopy(feed["models"]["qwen3-8b"]["artifacts"]["mlx-4bit"])
        shared["verification_status"] = "declared"
        shared["verified_at"] = None
        feed["models"]["qwen3-32b"]["artifacts"]["mlx-8b-clone"] = shared
        self.assertIn("resolve to exactly one pricing identity", self.rejects(feed))

    def test_duplicate_hash_under_one_model_key_fails_closed(self):
        feed = feed_from(artifact_source())
        clone = copy.deepcopy(feed["models"]["qwen3-8b"]["artifacts"]["mlx-4bit"])
        clone["verification_status"] = "declared"
        clone["verified_at"] = None
        feed["models"]["qwen3-8b"]["artifacts"]["mlx-4bit-copy"] = clone
        self.assertIn("resolve to exactly one pricing identity", self.rejects(feed))

    def test_candidate_conflicting_hash_check_still_runs_independently(self):
        # Neither check subsumes the other: the candidate-catalog check rejects two
        # different model_sha256 values under ONE normalized model_id.
        candidate = copy.deepcopy(CANDIDATE_OBJ)
        candidate["rows"]["qwen3-8b-alias"] = copy.deepcopy(candidate["rows"]["qwen3-8b"])
        candidate["rows"]["qwen3-8b-alias"]["model_sha256"] = "f" * 64
        with self.assertRaises(catalog_release.CatalogError) as caught:
            catalog_release.validate_candidate(catalog_release.canonical_bytes(candidate))
        self.assertIn("conflicting", str(caught.exception))

    # --- AC-CAT-19: artifact_id grammar ---------------------------------------

    def test_artifact_id_grammar(self):
        for bad_id in ("MLX-4bit", "mlx_4bit", "-mlx", "", "a" * 65, "mlx 4bit"):
            with self.subTest(bad_id):
                feed = feed_from(artifact_source())
                model = feed["models"]["qwen3-8b"]
                model["artifacts"][bad_id] = model["artifacts"].pop("mlx-4bit")
                model["primary_artifact_id"] = bad_id
                self.rejects(feed)
        feed = feed_from(artifact_source())
        model = feed["models"]["qwen3-8b"]
        model["artifacts"]["a" * 64] = model["artifacts"].pop("mlx-4bit")
        model["primary_artifact_id"] = "a" * 64
        self.validate(feed)

    def test_primary_artifact_id_must_name_an_mlx_artifact_of_the_model(self):
        feed = feed_from(artifact_source())
        feed["models"]["qwen3-8b"]["primary_artifact_id"] = "not-present"
        self.assertIn("does not name an artifact", self.rejects(feed))
        feed = feed_from(artifact_source())
        model = feed["models"]["qwen3-8b"]
        model["artifacts"]["gguf-q4-k-m"] = gguf_artifact()
        model["primary_artifact_id"] = "gguf-q4-k-m"
        self.assertIn("must name an mlx_safetensors artifact", self.rejects(feed))


class ArtifactSourceTest(unittest.TestCase):
    def test_committed_source_validates_and_seeds_every_catalog_row(self):
        source = catalog_release.validate_artifact_source(ARTIFACT_SOURCE_BYTES, CANDIDATE_OBJ)
        self.assertEqual(sorted(source["models"]), sorted(CANDIDATE_OBJ["rows"]))
        for key, model in source["models"].items():
            primary = model["artifacts"][model["primary_artifact_id"]]
            self.assertEqual(primary["hash"], CANDIDATE_OBJ["rows"][key]["model_sha256"])
            self.assertIsNone(primary["size_bytes"], "seeded sizes await an operator measurement")
            self.assertEqual(len(model["artifacts"]), 1, "no GGUF artifacts are seeded yet")

    def test_source_schema_is_closed(self):
        base = json.loads(ARTIFACT_SOURCE_BYTES)
        for mutate in (
            lambda value: value.update({"generated_at": "2026-09-02T00:00:00Z"}),
            lambda value: value.update({"schema_version": "macprovider.autotune-artifacts-source.v2"}),
            lambda value: value.pop("models"),
            lambda value: value.update({"source": "operator_curated_something_else"}),
        ):
            with self.subTest(repr(mutate)):
                value = copy.deepcopy(base)
                mutate(value)
                with self.assertRaises(catalog_release.CatalogError):
                    catalog_release.validate_artifact_source(canonical(value), CANDIDATE_OBJ)

    def test_generation_fails_closed_on_an_unmeasured_artifact(self):
        source = catalog_release.validate_artifact_source(ARTIFACT_SOURCE_BYTES, CANDIDATE_OBJ)
        with self.assertRaises(catalog_release.CatalogError) as caught:
            catalog_release.build_artifact_feed(source, CANDIDATE_BYTES, CANDIDATE_OBJ)
        self.assertIn("size_bytes must be measured", str(caught.exception))

    def test_build_is_deterministic_and_canonical(self):
        source = artifact_source()
        first = catalog_release.build_artifact_feed(source, CANDIDATE_BYTES, CANDIDATE_OBJ)
        second = catalog_release.build_artifact_feed(copy.deepcopy(source), CANDIDATE_BYTES, CANDIDATE_OBJ)
        self.assertEqual(first, second)
        self.assertEqual(first, canonical(json.loads(first)))


class RateCardSourceTest(unittest.TestCase):
    """SPEC-023 §3.3.1 rules 3-9 (AC-CAT-8, AC-CAT-9, AC-CAT-10, AC-CAT-14)."""

    def test_committed_source_reproduces_the_published_rows_byte_for_byte(self):
        """AC-CAT-10: the first class-expanded release publishes a `rows` map
        byte-identical to the preceding release's."""
        source = catalog_release.validate_rate_card_source(RATE_CARD_SOURCE_BYTES)
        expanded = catalog_release.expand_rate_card(source, {}, CANDIDATE_OBJ)
        self.assertEqual(expanded, RATE_CARD_BYTES)
        published = json.loads(RATE_CARD_BYTES)
        self.assertEqual(json.loads(expanded)["rows"], published["rows"])

    def test_published_schema_is_unchanged(self):
        """AC-CAT-8: no `classes` key, no per-row class field, §3.3 projection hash."""
        source = catalog_release.validate_rate_card_source(RATE_CARD_SOURCE_BYTES)
        published = catalog_release.validate_rate_card(
            catalog_release.expand_rate_card(source, {}, CANDIDATE_OBJ)
        )
        self.assertNotIn("classes", published)
        for row in published["rows"].values():
            self.assertNotIn("rate_class", row)
        self.assertEqual(published["version"], catalog_release.rate_card_projection_hash(published))

    def test_class_expansion_fills_a_key_with_no_explicit_row(self):
        """AC-CAT-9: a key with only a `rate_class` publishes a concrete row."""
        source = json.loads(RATE_CARD_SOURCE_BYTES)
        del source["rows"]["qwen3-8b"]
        source = catalog_release.validate_rate_card_source(canonical(source))
        expanded = json.loads(catalog_release.expand_rate_card(source, {"qwen3-8b": "class-8b"}, CANDIDATE_OBJ))
        self.assertEqual(expanded["rows"]["qwen3-8b"], json.loads(RATE_CARD_BYTES)["rows"]["qwen3-8b"])

    def test_explicit_row_beats_class_expansion(self):
        """AC-CAT-9 precedence: the explicit row publishes verbatim."""
        source = json.loads(RATE_CARD_SOURCE_BYTES)
        source["classes"]["class-8b"] = {
            "completion_rate_per_mtok": 1, "prompt_cache_hit_rate_per_mtok": 1, "prompt_rate_per_mtok": 1,
        }
        source = catalog_release.validate_rate_card_source(canonical(source))
        expanded = json.loads(catalog_release.expand_rate_card(source, {"qwen3-8b": "class-8b"}, CANDIDATE_OBJ))
        self.assertEqual(expanded["rows"]["qwen3-8b"]["completion_rate_per_mtok"], 27000)

    def test_missing_class_rates_fail_the_release_closed(self):
        source = json.loads(RATE_CARD_SOURCE_BYTES)
        del source["rows"]["qwen3-8b"]
        source = catalog_release.validate_rate_card_source(canonical(source))
        with self.assertRaises(catalog_release.CatalogError) as caught:
            catalog_release.expand_rate_card(source, {"qwen3-8b": "class-32b"}, CANDIDATE_OBJ)
        self.assertIn("no rates for that class", str(caught.exception))

    def test_recommendable_row_with_no_resolvable_rate_row_fails_closed(self):
        """AC-CAT-10: no orphan `recommendable` row; `default` does not satisfy it."""
        source = json.loads(RATE_CARD_SOURCE_BYTES)
        del source["rows"]["qwen3-8b"]
        source = catalog_release.validate_rate_card_source(canonical(source))
        with self.assertRaises(catalog_release.CatalogError) as caught:
            catalog_release.expand_rate_card(source, {}, CANDIDATE_OBJ)
        self.assertIn("resolves to no rate-card row", str(caught.exception))

    def test_normalized_key_satisfies_the_rule_seven_invariant(self):
        # `nvidia/nemotron-3-nano-30b-a3b` has no exact row; it resolves through
        # NormalizeModelKey to `nemotron-3-nano-30b-a3b`.
        self.assertNotIn("nvidia/nemotron-3-nano-30b-a3b", json.loads(RATE_CARD_BYTES)["rows"])
        catalog_release.require_recommendable_rate_rows(
            CANDIDATE_OBJ, catalog_release.validate_rate_card(RATE_CARD_BYTES)
        )

    def test_normalize_model_key_matches_the_go_implementation(self):
        """Pin the Python port against `billing.NormalizeModelKey` behaviour."""
        table = {
            "qwen3-8b": "qwen3-8b",
            "nvidia/nemotron-3-nano-30b-a3b": "nemotron-3-nano-30b-a3b",
            "mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit": "nemotron-3-nano-30b-a3b",
            "mlx-community/Qwen3-8B-4bit": "qwen3-8b",
            "mlx-community/gpt-oss-20b-MXFP4-Q8": "openai/gpt-oss-20b",
            "openai/gpt-oss-120b": "openai/gpt-oss-120b",
            "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit": "meta-llama/llama-3.1-8b-instruct",
            "meta-llama/Llama-3.2-3B-Instruct": "meta-llama/llama-3.2-3b-instruct",
            "google/gpt-oss-20b": "gpt-oss-20b",
            "  Qwen3-32B-8bit  ": "qwen3-32b",
        }
        for served, expected in table.items():
            with self.subTest(served):
                self.assertEqual(catalog_release.normalize_model_key(served), expected)

    def test_source_top_level_is_closed(self):
        base = json.loads(RATE_CARD_SOURCE_BYTES)
        with self.assertRaises(catalog_release.CatalogError):
            catalog_release.validate_rate_card_source(canonical({**base, "notes": "x"}))
        for field in sorted(base):
            with self.subTest(field):
                value = {key: item for key, item in base.items() if key != field}
                with self.assertRaises(catalog_release.CatalogError):
                    catalog_release.validate_rate_card_source(canonical(value))
        for field, bad in (
            ("schema_version", "macprovider.rate-card-source.v2"),
            ("usd_per_million_credits", "1.0"),
            ("provider_share_bps", 10001),
            ("global_multiplier_ppm", "1000000"),
            ("rows", []),
            ("classes", []),
        ):
            with self.subTest(field):
                with self.assertRaises(catalog_release.CatalogError):
                    catalog_release.validate_rate_card_source(canonical({**base, field: bad}))

    def test_empty_rows_and_classes_are_valid(self):
        base = json.loads(RATE_CARD_SOURCE_BYTES)
        value = catalog_release.validate_rate_card_source(canonical({**base, "rows": {}, "classes": {}}))
        self.assertEqual(value["rows"], {})

    def test_class_may_not_declare_a_share_or_multiplier(self):
        base = json.loads(RATE_CARD_SOURCE_BYTES)
        for field, value in (("provider_share_bps", 9000), ("global_multiplier_ppm", 1000000)):
            with self.subTest(field):
                source = copy.deepcopy(base)
                source["classes"]["class-8b"][field] = value
                with self.assertRaises(catalog_release.CatalogError) as caught:
                    catalog_release.validate_rate_card_source(canonical(source))
                self.assertIn("unknown fields", str(caught.exception))

    def test_row_may_not_carry_a_fourth_field(self):
        base = json.loads(RATE_CARD_SOURCE_BYTES)
        base["rows"]["qwen3-8b"]["rate_class"] = "class-8b"
        with self.assertRaises(catalog_release.CatalogError):
            catalog_release.validate_rate_card_source(canonical(base))

    def test_unknown_class_name_is_rejected(self):
        base = json.loads(RATE_CARD_SOURCE_BYTES)
        base["classes"]["class-13b"] = dict(base["classes"]["class-8b"])
        with self.assertRaises(catalog_release.CatalogError):
            catalog_release.validate_rate_card_source(canonical(base))

    def test_the_source_is_never_the_published_feed(self):
        self.assertNotEqual(RATE_CARD_SOURCE_BYTES, RATE_CARD_BYTES)
        for name in ("release.json", "release-ledger.json"):
            self.assertNotIn("rate-card-source.json", (CATALOG / name).read_text())
        self.assertFalse((ROOT / "phase3-binary" / "dist" / "static" / "rate-card-source.json").exists())


class CoordinatorParityTest(unittest.TestCase):
    """SPEC-023 §3.3.1 rule 9 / AC-CAT-14."""

    def setUp(self):
        self.rate_card = catalog_release.validate_rate_card(RATE_CARD_BYTES)
        self.coordinator = COORDINATOR_YAML.read_text()

    def test_committed_release_is_in_parity(self):
        catalog_release.check_rate_card_parity(self.rate_card, self.coordinator)

    def test_changed_credit_value_on_either_side_fails_closed(self):
        published = copy.deepcopy(self.rate_card)
        published["rows"]["qwen3-8b"]["completion_rate_per_mtok"] += 1
        with self.assertRaises(catalog_release.CatalogError) as caught:
            catalog_release.check_rate_card_parity(published, self.coordinator)
        self.assertIn("disagrees with coordinator", str(caught.exception))

        mutated = self.coordinator.replace(
            "    qwen3-8b:                                # P2-02 — small-dense lane (matches Llama 3.1 8B pricing)\n"
            "      prompt_credits_per_mtok: 13500",
            "    qwen3-8b:\n      prompt_credits_per_mtok: 13501",
        )
        self.assertNotEqual(mutated, self.coordinator)
        with self.assertRaises(catalog_release.CatalogError):
            catalog_release.check_rate_card_parity(self.rate_card, mutated)

    def test_missing_and_extra_rows_fail_closed(self):
        published = copy.deepcopy(self.rate_card)
        published["rows"]["a-new-key"] = copy.deepcopy(published["rows"]["qwen3-8b"])
        with self.assertRaises(catalog_release.CatalogError) as caught:
            catalog_release.check_rate_card_parity(published, self.coordinator)
        self.assertIn("missing rows", str(caught.exception))

        published = copy.deepcopy(self.rate_card)
        del published["rows"]["qwen3-8b"]
        with self.assertRaises(catalog_release.CatalogError) as caught:
            catalog_release.check_rate_card_parity(published, self.coordinator)
        self.assertIn("extra rows", str(caught.exception))

    def test_per_row_share_in_the_coordinator_config_fails_closed(self):
        mutated = self.coordinator.replace(
            "    qwen3-8b:                                # P2-02 — small-dense lane (matches Llama 3.1 8B pricing)",
            "    qwen3-8b:\n      provider_share_bps: 9000",
        )
        with self.assertRaises(catalog_release.CatalogError) as caught:
            catalog_release.check_rate_card_parity(self.rate_card, mutated)
        self.assertIn("not a credit field", str(caught.exception))

    def test_global_disagreement_fails_closed(self):
        for original, replacement, needle in (
            ("  provider_share: 0.90", "  provider_share: 0.80", "provider_share"),
            ("  global_multiplier: 1.0", "  global_multiplier: 1.5", "global_multiplier"),
        ):
            with self.subTest(needle):
                mutated = self.coordinator.replace(original, replacement)
                self.assertNotEqual(mutated, self.coordinator)
                with self.assertRaises(catalog_release.CatalogError) as caught:
                    catalog_release.check_rate_card_parity(self.rate_card, mutated)
                self.assertIn(needle, str(caught.exception))

    def test_emitted_coordinator_block_reparses_into_parity(self):
        block = catalog_release.coordinator_rate_card_yaml(self.rate_card)
        document = "rewards:\n  global_multiplier: 1.0\n  provider_share: 0.90\n" + block
        catalog_release.check_rate_card_parity(self.rate_card, document)


class LedgerV3Test(unittest.TestCase):
    """SPEC-023 §3.7.8 / AC-CAT-15, AC-CAT-19."""

    def feed_bindings(self):
        source = artifact_source()
        feed = catalog_release.validate_artifact_feed(
            catalog_release.build_artifact_feed(source, CANDIDATE_BYTES, CANDIDATE_OBJ),
            CANDIDATE_BYTES,
            CANDIDATE_OBJ,
        )
        return feed, catalog_release.artifact_bindings(feed)

    def artifact_row(self, bindings, feeds=None):
        return {
            "generated_at": CANDIDATE_OBJ["generated_at"],
            "policy_version": CANDIDATE_OBJ["policy_version"],
            "feeds": feeds or {
                name: {"bytes": 10, "sha256": "a" * 64, "signer_key_id": "k", "version": CANDIDATE_OBJ["version"]}
                for name in catalog_release.ARTIFACT_BOUND_LEDGER_FEEDS
            },
            "artifact_bindings": bindings,
            "intake_decision_sha256": None,
        }

    def ledger(self, rows, schema=None):
        return json.dumps({
            "schema_version": schema or catalog_release.LEDGER_SCHEMA_V3,
            "releases": rows,
            "tombstones": {},
        }).encode()

    def test_bindings_are_complete_ordered_and_unique(self):
        feed, bindings = self.feed_bindings()
        published = {
            (model_key, artifact_id)
            for model_key, model in feed["models"].items()
            for artifact_id in model["artifacts"]
        }
        self.assertEqual({(row["model_key"], row["artifact_id"]) for row in bindings}, published)
        keys = [(row["model_key"].encode(), row["artifact_id"].encode()) for row in bindings]
        self.assertEqual(keys, sorted(keys))

    def test_declared_and_blocked_artifacts_are_recorded_too(self):
        source = artifact_source()
        source["models"]["qwen3-8b"]["artifacts"]["gguf-q4-k-m"] = gguf_artifact()
        feed = catalog_release.validate_artifact_feed(
            catalog_release.build_artifact_feed(source, CANDIDATE_BYTES, CANDIDATE_OBJ),
            CANDIDATE_BYTES,
            CANDIDATE_OBJ,
        )
        bindings = catalog_release.artifact_bindings(feed)
        self.assertIn(("qwen3-8b", "gguf-q4-k-m"), {(row["model_key"], row["artifact_id"]) for row in bindings})

    def test_artifact_bound_row_is_a_closed_five_key_set(self):
        _, bindings = self.feed_bindings()
        catalog_release.validate_release_ledger(self.ledger({CANDIDATE_OBJ["version"]: self.artifact_row(bindings)}))
        for mutate in (
            lambda row: row.update({"unexpected": 1}),
            lambda row: row.pop("artifact_bindings"),
            lambda row: row.pop("intake_decision_sha256"),
            lambda row: row.update({"intake_decision_sha256": "not-a-digest"}),
        ):
            with self.subTest(repr(mutate)):
                row = self.artifact_row(bindings)
                mutate(row)
                with self.assertRaises(catalog_release.CatalogError):
                    catalog_release.validate_release_ledger(self.ledger({CANDIDATE_OBJ["version"]: row}))

    def test_binding_element_shape_is_closed(self):
        _, bindings = self.feed_bindings()
        for mutate in (
            lambda rows: rows[0].update({"size_bytes": 1}),
            lambda rows: rows[0].pop("hash_algorithm"),
            lambda rows: rows[0].update({"hash": "not-hex"}),
            lambda rows: rows[0].update({"hash_algorithm": "macprovider.made-up.v1"}),
            lambda rows: rows[0].update({"artifact_id": "NOT_VALID"}),
            lambda rows: rows[0].update({"model_key": ""}),
            lambda rows: rows.reverse(),
            lambda rows: rows.append(copy.deepcopy(rows[0])),
        ):
            with self.subTest(repr(mutate)):
                rows = copy.deepcopy(bindings)
                mutate(rows)
                with self.assertRaises(catalog_release.CatalogError):
                    catalog_release.validate_release_ledger(
                        self.ledger({CANDIDATE_OBJ["version"]: self.artifact_row(rows)})
                    )

    def test_artifact_bound_row_requires_a_v3_document(self):
        _, bindings = self.feed_bindings()
        with self.assertRaises(catalog_release.CatalogError) as caught:
            catalog_release.validate_release_ledger(
                self.ledger({CANDIDATE_OBJ["version"]: self.artifact_row(bindings)}, catalog_release.LEDGER_SCHEMA_V2)
            )
        self.assertIn("must be macprovider.autotune-release-ledger.v3", str(caught.exception))

    def test_historical_rows_stay_valid_and_may_not_gain_the_new_keys(self):
        committed = catalog_release.validate_release_ledger((CATALOG / "release-ledger.json").read_bytes())
        self.assertEqual(committed["schema_version"], catalog_release.LEDGER_SCHEMA_V2)
        rate_card_bound = {
            name: {"bytes": 10, "sha256": "a" * 64, "signer_key_id": "k", "version": CANDIDATE_OBJ["version"]}
            for name in catalog_release.RATE_CARD_BOUND_LEDGER_FEEDS
        }
        for name in ("autotune-candidates.json", "demand-rank.json"):
            rate_card_bound[name]["version"] = "legacy"
        historical = {
            "generated_at": CANDIDATE_OBJ["generated_at"],
            "policy_version": CANDIDATE_OBJ["policy_version"],
            "feeds": rate_card_bound,
        }
        # A historical-feed-set row is accepted inside a v3 document unchanged.
        catalog_release.validate_release_ledger(self.ledger({"legacy": historical}))
        _, bindings = self.feed_bindings()
        with self.assertRaises(catalog_release.CatalogError) as caught:
            catalog_release.validate_release_ledger(
                self.ledger({"legacy": {**historical, "artifact_bindings": bindings}})
            )
        self.assertIn("unknown fields", str(caught.exception))

    def test_downgrade_after_activation_fails_closed(self):
        _, bindings = self.feed_bindings()
        base = catalog_release.validate_release_ledger(
            self.ledger({CANDIDATE_OBJ["version"]: self.artifact_row(bindings)})
        )
        downgraded = {**base, "schema_version": catalog_release.LEDGER_SCHEMA_V2}
        with self.assertRaises(catalog_release.CatalogError) as caught:
            catalog_release.require_ledger_evolution(base, downgraded)
        self.assertIn("may not be downgraded", str(caught.exception))

        reverted = copy.deepcopy(base)
        reverted["releases"]["published-later-v1"] = {
            "generated_at": CANDIDATE_OBJ["generated_at"],
            "policy_version": CANDIDATE_OBJ["policy_version"],
            "feeds": {
                name: {"bytes": 10, "sha256": "a" * 64, "signer_key_id": "k", "version": "published-later-v1"}
                for name in catalog_release.RATE_CARD_BOUND_LEDGER_FEEDS
            },
        }
        with self.assertRaises(catalog_release.CatalogError) as caught:
            catalog_release.require_ledger_evolution(base, reverted)
        self.assertIn("reverts to", str(caught.exception))

    def test_cross_release_rebinding_fails_closed(self):
        feed, bindings = self.feed_bindings()
        base = catalog_release.validate_release_ledger(
            self.ledger({CANDIDATE_OBJ["version"]: self.artifact_row(bindings)})
        )
        previous = catalog_release.build_artifact_feed(artifact_source(), CANDIDATE_BYTES, CANDIDATE_OBJ)

        # Same id, different bytes -> rebinding.
        rebound = copy.deepcopy(feed)
        rebound["models"]["qwen3-8b"]["artifacts"]["mlx-4bit"]["hash"] = "9" * 64
        with self.assertRaises(catalog_release.CatalogError) as caught:
            catalog_release.require_no_artifact_rebinding(rebound, base, previous)
        self.assertIn("is rebound", str(caught.exception))

        # New bytes under a NEW id, old id retired as blocked -> allowed.
        widened = copy.deepcopy(feed)
        model = widened["models"]["qwen3-8b"]
        retired = copy.deepcopy(model["artifacts"]["mlx-4bit"])
        retired["verification_status"] = "blocked"
        retired["verified_at"] = None
        model["artifacts"]["mlx-4bit"] = retired
        catalog_release.require_no_artifact_rebinding(widened, base, previous)

        # Removal is not an escape hatch: dropping the pair and reintroducing it
        # bound to different bytes fails exactly as an in-place change does.
        removed = copy.deepcopy(feed)
        removed["models"]["qwen3-8b"]["artifacts"]["mlx-4bit"]["hash"] = "9" * 64
        absent_previous = copy.deepcopy(json.loads(previous))
        del absent_previous["models"]["qwen3-8b"]
        with self.assertRaises(catalog_release.CatalogError) as caught:
            catalog_release.require_no_artifact_rebinding(removed, base, canonical(absent_previous))
        self.assertIn("is rebound", str(caught.exception))

    def test_first_artifact_bound_release_needs_no_previous_feed(self):
        feed, _ = self.feed_bindings()
        catalog_release.require_no_artifact_rebinding(feed, catalog_release.empty_release_ledger(), None)

    def test_previous_feed_is_required_once_activated(self):
        feed, bindings = self.feed_bindings()
        base = catalog_release.validate_release_ledger(
            self.ledger({CANDIDATE_OBJ["version"]: self.artifact_row(bindings)})
        )
        with self.assertRaises(catalog_release.CatalogError) as caught:
            catalog_release.require_no_artifact_rebinding(feed, base, None)
        self.assertIn("--previous-artifact-feed is required", str(caught.exception))


class StageActivationTest(unittest.TestCase):
    """SPEC-023 §3.7.8 Stage A (AC-CAT-15)."""

    def test_components_catalog_files_map_is_the_unchanged_nine_name_set(self):
        expected = (
            "release.json",
            "trusted-keys.json",
            "tier2-catalog.json",
            "autotune-candidates.json",
            "autotune-candidates.json.sig",
            "demand-rank.json",
            "demand-rank.json.sig",
            "rate-card.json",
            "rate-card.json.sig",
        )
        self.assertEqual(compatibility_set.CATALOG_FILES, expected)
        self.assertNotIn("autotune-artifacts.json", compatibility_set.CATALOG_FILES)
        swift = (
            ROOT / "phase3-binary" / "Sources" / "macprovider-cli" / "CompatibilitySetManifest.swift"
        ).read_text()
        self.assertNotIn("autotune-artifacts.json", swift)

    def test_acceptance_candidate_catalog_name_set_is_unchanged(self):
        acceptance = _load("acceptance_candidate_metadata", "scripts/acceptance-candidate-metadata.py")
        self.assertNotIn("autotune-artifacts.json", acceptance.CATALOG_NAMES)
        self.assertEqual(len(acceptance.CATALOG_NAMES), 9)

    def test_release_json_feeds_check_accepts_both_bound_sets(self):
        self.assertEqual(
            compatibility_set.ARTIFACT_BOUND_RELEASE_FEEDS,
            compatibility_set.RATE_CARD_BOUND_RELEASE_FEEDS | {"autotune-artifacts.json"},
        )

    def test_candidate_catalog_gains_no_new_row_key(self):
        """AC-CAT-3: the published candidate catalog carries no v0.10 field."""
        allowed = {
            "model_id", "model_revision", "model_sha256", "min_ram_gb", "min_bandwidth_tier",
            "bench_gate", "runtime_status", "notes", "draft_candidates", "workload_profiles",
        }
        for key, row in CANDIDATE_OBJ["rows"].items():
            with self.subTest(key):
                self.assertLessEqual(set(row), allowed)
                self.assertNotIn("rate_class", row)
                self.assertNotIn("artifacts", row)


class ReleaseDirectoryTest(unittest.TestCase):
    """End-to-end: stage a signed five-feed release and verify it (AC-CAT-1)."""

    @classmethod
    def setUpClass(cls):
        cls.openssl = catalog_release.openssl_executable()

    def keypair(self, directory: pathlib.Path, name: str) -> tuple[pathlib.Path, str]:
        key = directory / f"{name}.pem"
        subprocess.run(
            [self.openssl, "genpkey", "-algorithm", "ed25519", "-out", str(key)],
            check=True, capture_output=True,
        )
        der = subprocess.run(
            [self.openssl, "pkey", "-in", str(key), "-pubout", "-outform", "DER"],
            check=True, capture_output=True,
        ).stdout
        return key, base64.b64encode(der[-32:]).decode("ascii")

    def sidecar(self, directory: pathlib.Path, key: pathlib.Path, key_id: str, data: bytes) -> bytes:
        message = directory / "message.bin"
        message.write_bytes(data)
        signature = subprocess.run(
            [self.openssl, "pkeyutl", "-sign", "-rawin", "-inkey", str(key), "-in", str(message)],
            check=True, capture_output=True,
        ).stdout
        message.unlink()
        return json.dumps({
            "key_id": key_id,
            "alg": "ed25519",
            "signature": base64.b64encode(signature).decode("ascii"),
        }).encode()

    def tier2_catalog(self) -> bytes:
        row = CANDIDATE_OBJ["rows"]["qwen3-8b"]
        return json.dumps({
            "catalog_id": "test-artifact-slice",
            "issued_at": "2026-09-02T00:00:00Z",
            "expires_at": "2099-01-01T00:00:00Z",
            "version": 1,
            "models": [{
                "artifact_kind": "mlx_weight_file",
                "hash_scope": "artifact_manifest",
                "model_id": row["model_id"],
                "sha256": row["model_sha256"],
                "source": "test",
            }],
            "signature": {
                "alg": "Ed25519",
                "key_id": "test",
                "sig": base64.urlsafe_b64encode(b"x" * 64).rstrip(b"=").decode("ascii"),
            },
        }, indent=2, sort_keys=True).encode() + b"\n"

    def stage(self, directory: pathlib.Path, *, artifact_key_id: str | None = None) -> None:
        """Write a complete artifact-bound release directory."""
        primary_key, primary_public = self.keypair(directory, "primary")
        bridge_key, bridge_public = self.keypair(directory, "bridge")
        keys = {
            "schema_version": "macprovider.autotune-keys.v1",
            "keys": {
                "test-static-v1": {"public_key_base64": primary_public, "status": "active"},
                "test-static-v2": {"public_key_base64": bridge_public, "status": "bridge"},
            },
        }
        (directory / "trusted-keys.json").write_text(json.dumps(keys, indent=2, sort_keys=True) + "\n")

        artifacts = catalog_release.build_artifact_feed(artifact_source(), CANDIDATE_BYTES, CANDIDATE_OBJ)
        artifact_obj = catalog_release.validate_artifact_feed(artifacts, CANDIDATE_BYTES, CANDIDATE_OBJ)
        tier2 = self.tier2_catalog()
        (directory / "tier2-catalog.json").write_bytes(tier2)

        signed = {
            "autotune-candidates.json": CANDIDATE_BYTES,
            "demand-rank.json": DEMAND_BYTES,
            "rate-card.json": RATE_CARD_BYTES,
            "autotune-artifacts.json": artifacts,
        }
        for name, body in signed.items():
            (directory / name).write_bytes(body)
            key, key_id = primary_key, "test-static-v1"
            if name == "autotune-artifacts.json" and artifact_key_id is not None:
                key, key_id = bridge_key, artifact_key_id
            (directory / f"{name}.sig").write_bytes(self.sidecar(directory, key, key_id, body))

        manifest_bytes = catalog_release.manifest(
            CANDIDATE_BYTES, DEMAND_BYTES, RATE_CARD_BYTES, CANDIDATE_OBJ,
            catalog_release.validate_demand(DEMAND_BYTES),
            catalog_release.validate_rate_card(RATE_CARD_BYTES),
            directory,
            tier2=tier2,
            tier2_obj=catalog_release.validate_tier2_catalog(tier2),
            tier2_signer_key_id="tier2-test-key",
            artifacts=artifacts,
            artifact_obj=artifact_obj,
        )
        (directory / "release.json").write_bytes(manifest_bytes)

    def run_verify(self, directory: pathlib.Path) -> None:
        original = catalog_release.verify_tier2_signature
        # The Tier-2 Go signature path is orthogonal to this slice and is covered
        # by scripts/test-catalog-release.sh; stub only that call.
        catalog_release.verify_tier2_signature = lambda *args, **kwargs: "tier2-test-key"
        try:
            catalog_release.verify_directory(directory)
        finally:
            catalog_release.verify_tier2_signature = original

    def test_artifact_bound_release_directory_verifies(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = pathlib.Path(raw)
            self.stage(directory)
            self.run_verify(directory)
            manifest = json.loads((directory / "release.json").read_bytes())
            self.assertEqual(set(manifest["feeds"]), catalog_release.ARTIFACT_BOUND_LEDGER_FEEDS)
            self.assertEqual(
                manifest["feeds"]["autotune-artifacts.json"]["version"], CANDIDATE_OBJ["version"]
            )

    def test_tampered_artifact_feed_bytes_fail_signature_verification(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = pathlib.Path(raw)
            self.stage(directory)
            feed = json.loads((directory / "autotune-artifacts.json").read_bytes())
            feed["models"]["qwen3-8b"]["artifacts"]["mlx-4bit"]["notes"] = "tampered"
            (directory / "autotune-artifacts.json").write_bytes(canonical(feed))
            with self.assertRaises(catalog_release.CatalogError):
                self.run_verify(directory)

    def test_signer_identity_is_an_equality_not_keyring_membership(self):
        """AC-CAT-1: a VALID signature by a different but concurrently trusted key
        fails closed at generation."""
        with tempfile.TemporaryDirectory() as raw:
            directory = pathlib.Path(raw)
            with self.assertRaises(catalog_release.CatalogError) as caught:
                self.stage(directory, artifact_key_id="test-static-v2")
            self.assertIn("must equal the candidate-catalog signer", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
