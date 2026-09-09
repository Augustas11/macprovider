"""SPEC-023 v0.10.x catalog artifact feed + class rate expansion (BYOM v0.2 slice 2a).

Scope. This module covers the GENERATOR half of the SPEC-023 §11 acceptance
matrix — what `scripts/catalog-release.py` produces, refuses to produce, and
verifies. It does NOT claim the acceptance criteria whose subject is a consumer
(the provider CLI, the coordinator, the buyer surface) or the §16 intake
pipeline, and it does not stand in for the tests that own them.

Generator-side criteria asserted here:

* AC-CAT-1  — closed feed schema at every level, and signer-identity EQUALITY
              (a valid signature by a different concurrently trusted key).
* AC-CAT-3  — the published candidate catalog gains no `rate_class`, artifact,
              or intake row key.
* AC-CAT-4  — release binding (`version`, `release_id`, `generated_at`,
              `policy_version`, `candidate_catalog_sha256`).
* AC-CAT-5  — primary-artifact consistency, including the `candidate`-row
              all-`declared` carve-out.
* AC-CAT-6  — generation refuses a `declared` or `blocked` primary artifact under
              a `listed`/`recommendable` row. The provider-side selection half is
              the CLI-consumption slice's.
* AC-CAT-8  — the published rate card keeps the §3.3 schema and projection hash.
* AC-CAT-9  — closed `rate-card-source.json`, class precedence, expansion.
* AC-CAT-10 — byte-identical `rows` on the first class-expanded release, expanded
              with the COMMITTED artifact source's classes, and no orphan
              `recommendable` row.
* AC-CAT-11 — a key with no `verified` artifact may not be `listed`.
* AC-CAT-14 — generated-feed / billing-config parity, mutated on both sides,
              including release-global rounding and per-row global equality.
* AC-CAT-15 — ledger feed sets, artifact-bound activation, downgrade rejection,
              and the unchanged nine-name `components.catalog.files` map.
* AC-CAT-16 — the closed artifact-identity tuple matrix and the GGUF
              `source_ref.digest == "sha256:" + hash` value binding.
* AC-CAT-18 — global `(hash_algorithm, hash)` uniqueness.
* AC-CAT-19 — `artifact_id` grammar, cross-release rebinding (through the public
              `verify` entry point as well as generation), and the concrete
              release-ledger v3 wire shape including `intake_decision_sha256`.

NOT claimed by this module — owned elsewhere, and this slice ships no code for
them: AC-CAT-2, AC-CAT-7, AC-CAT-12, AC-CAT-13, AC-CAT-17, AC-CAT-20, AC-CAT-21.

Two harnesses back the assertions. `ReleaseDirectoryTest` stages a complete
five-feed release directory signed with a throwaway Ed25519 key and runs
`verify-directory` over it. `HermeticReleaseTest` copies the release inputs into
a temporary tree with a throwaway keyring and drives the real `generate` / sign /
`verify` sequence across the pre-activation, activation, and post-activation
states. The only stubs are `verify_tier2_signature`, whose Go-backed signature
path is orthogonal to this slice and is exercised by
`scripts/test-catalog-release.sh`, and `base_release_ledger`, whose git baseline
cannot be resolved from a temporary tree.
"""

from __future__ import annotations

import base64
import contextlib
import copy
import importlib.util
import io
import json
import math
import pathlib
import shutil
import subprocess
import tempfile
import unittest
from decimal import Decimal, ROUND_HALF_UP


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
NORMALIZE_CASES_PATH = ROOT / "scripts" / "tests" / "fixtures" / "normalize_model_key_cases.json"
ROUNDING_CASES_PATH = ROOT / "scripts" / "tests" / "fixtures" / "rate_global_rounding_cases.json"

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
        byte-identical to the preceding release's — expanded with the COMMITTED
        artifact source's `rate_class` declarations, not an empty class map.

        Expanding against `{}` proves only that the explicit rows round-trip; it
        cannot see a key whose declared class has no rates, which is exactly the
        state the seeded source is in for `class-30b-moe` and `class-32b`.
        """
        classes = catalog_release.artifact_rate_classes(json.loads(ARTIFACT_SOURCE_BYTES))
        self.assertEqual(len(classes), len(CANDIDATE_OBJ["rows"]))
        source = catalog_release.validate_rate_card_source(RATE_CARD_SOURCE_BYTES)
        expanded = catalog_release.expand_rate_card(source, classes, CANDIDATE_OBJ)
        self.assertEqual(expanded, RATE_CARD_BYTES)
        published = json.loads(RATE_CARD_BYTES)
        self.assertEqual(json.loads(expanded)["rows"], published["rows"])

    def test_every_committed_key_resolves_a_rate_row_through_its_declared_class(self):
        """AC-CAT-10 / §3.3.1 rules 5+7: each of the ten seeded keys resolves to a
        concrete published row, by exact key or by `NormalizeModelKey`, even where
        its declared class carries no rates (`class-30b-moe`, `class-32b`)."""
        classes = catalog_release.artifact_rate_classes(json.loads(ARTIFACT_SOURCE_BYTES))
        rows = json.loads(RATE_CARD_BYTES)["rows"]
        unseeded = set(classes.values()) - set(json.loads(RATE_CARD_SOURCE_BYTES)["classes"])
        self.assertEqual(unseeded, {"class-30b-moe", "class-32b"})
        for key in sorted(classes):
            with self.subTest(key):
                normalized = catalog_release.normalize_model_key(key)
                self.assertTrue(
                    (key in rows and key != "default") or (normalized in rows and normalized != "default"),
                    f"{key!r} resolves to no published rate row",
                )

    def test_normalized_explicit_row_is_not_republished_under_the_feed_spelling(self):
        """§3.3.1 rule 5: resolving an explicit row through `NormalizeModelKey`
        publishes NO second row for the un-normalized spelling — adding one would
        change the published bytes."""
        classes = catalog_release.artifact_rate_classes(json.loads(ARTIFACT_SOURCE_BYTES))
        self.assertEqual(classes["nvidia/nemotron-3-nano-30b-a3b"], "class-30b-moe")
        source = catalog_release.validate_rate_card_source(RATE_CARD_SOURCE_BYTES)
        rows = json.loads(catalog_release.expand_rate_card(source, classes, CANDIDATE_OBJ))["rows"]
        self.assertNotIn("nvidia/nemotron-3-nano-30b-a3b", rows)
        self.assertIn("nemotron-3-nano-30b-a3b", rows)

    def test_missing_class_rates_still_fail_when_no_explicit_row_resolves(self):
        """Normalized resolution is not a bypass: a key with neither an explicit
        row nor class rates still fails the release closed."""
        source = json.loads(RATE_CARD_SOURCE_BYTES)
        del source["rows"]["nemotron-3-nano-30b-a3b"]
        source = catalog_release.validate_rate_card_source(canonical(source))
        with self.assertRaises(catalog_release.CatalogError) as caught:
            catalog_release.expand_rate_card(
                source, {"nvidia/nemotron-3-nano-30b-a3b": "class-30b-moe"}, CANDIDATE_OBJ
            )
        self.assertIn("no rates for that class", str(caught.exception))

    def test_source_rows_must_be_normalized_model_keys(self):
        """§3.3.1 rule 3: `rows` maps NORMALIZED keys. Billing resolves exact
        spelling before `NormalizeModelKey`, so an explicit row under an
        un-normalized spelling would price one model two ways."""
        source = json.loads(RATE_CARD_SOURCE_BYTES)
        source["rows"]["nvidia/nemotron-3-nano-30b-a3b"] = dict(source["rows"]["nemotron-3-nano-30b-a3b"])
        with self.assertRaises(catalog_release.CatalogError) as caught:
            catalog_release.validate_rate_card_source(canonical(source))
        self.assertIn("normalized model key", str(caught.exception))
        self.assertIn("'nemotron-3-nano-30b-a3b'", str(caught.exception))

    def test_class_expansion_materialises_under_the_normalized_key(self):
        """§3.3.1 rule 4: the published and coordinator rows carry the SAME
        normalized key, so a class-only artifact key whose spelling changes under
        `NormalizeModelKey` publishes its row under the normalized spelling — the
        one every equivalent served identifier resolves to — never the raw one."""
        source = json.loads(RATE_CARD_SOURCE_BYTES)
        del source["rows"]["nemotron-3-nano-30b-a3b"]
        source["classes"]["class-30b-moe"] = {
            "completion_rate_per_mtok": 5, "prompt_cache_hit_rate_per_mtok": 3, "prompt_rate_per_mtok": 4,
        }
        source = catalog_release.validate_rate_card_source(canonical(source))
        expanded = json.loads(catalog_release.expand_rate_card(
            source, {"nvidia/nemotron-3-nano-30b-a3b": "class-30b-moe"}, CANDIDATE_OBJ
        ))["rows"]
        self.assertNotIn("nvidia/nemotron-3-nano-30b-a3b", expanded)
        self.assertEqual(expanded["nemotron-3-nano-30b-a3b"]["completion_rate_per_mtok"], 5)
        self.assertEqual(
            catalog_release.normalize_model_key("nvidia/nemotron-3-nano-30b-a3b"), "nemotron-3-nano-30b-a3b"
        )

    def test_conflicting_classes_under_one_normalized_key_fail_closed(self):
        """Two artifact keys that are one model after normalization must declare
        one class; otherwise sort order would silently pick the price."""
        source = json.loads(RATE_CARD_SOURCE_BYTES)
        del source["rows"]["qwen3-8b"]
        source = catalog_release.validate_rate_card_source(canonical(source))
        self.assertEqual(catalog_release.normalize_model_key("mlx-community/qwen3-8b-4bit"), "qwen3-8b")
        with self.assertRaises(catalog_release.CatalogError) as caught:
            catalog_release.expand_rate_card(
                source, {"qwen3-8b": "class-8b", "mlx-community/qwen3-8b-4bit": "class-3b"}, CANDIDATE_OBJ
            )
        self.assertIn("both normalize to 'qwen3-8b'", str(caught.exception))
        # The same class under both spellings is one row, published once.
        expanded = json.loads(catalog_release.expand_rate_card(
            source, {"qwen3-8b": "class-8b", "mlx-community/qwen3-8b-4bit": "class-8b"}, CANDIDATE_OBJ
        ))["rows"]
        self.assertNotIn("mlx-community/qwen3-8b-4bit", expanded)
        self.assertEqual(expanded["qwen3-8b"], json.loads(RATE_CARD_BYTES)["rows"]["qwen3-8b"])

    def test_global_multiplier_ppm_is_bounded_to_the_coordinator_int64_domain(self):
        """The coordinator parses `rewards.global_multiplier` into an int64 ppm;
        a wider source integer is rejected at parse time, before parity."""
        source = json.loads(RATE_CARD_SOURCE_BYTES)
        source["global_multiplier_ppm"] = 2 ** 63
        with self.assertRaises(catalog_release.CatalogError) as caught:
            catalog_release.validate_rate_card_source(canonical(source))
        self.assertIn("64-bit", str(caught.exception))
        source["global_multiplier_ppm"] = 2 ** 63 - 1
        catalog_release.validate_rate_card_source(canonical(source))

    def test_published_rate_card_rejects_an_unnormalized_row_key(self):
        """The normalized-key invariant lives in the SHARED validator, so
        `verify-directory` enforces it on bytes it did not generate."""
        value = json.loads(RATE_CARD_BYTES)
        value["rows"]["mlx-community/qwen3-8b-4bit"] = dict(value["rows"]["qwen3-8b"])
        value["version"] = ""
        value["version"] = catalog_release.rate_card_projection_hash(value)
        with self.assertRaises(catalog_release.CatalogError) as caught:
            catalog_release.validate_rate_card(catalog_release.canonical_sorted_bytes(value))
        self.assertIn("must be the SPEC-005 normalized model key ('qwen3-8b')", str(caught.exception))

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
        """Pin the Python port against `billing.NormalizeModelKey` through the
        SHARED case table.

        Duplicating expectation literals on each side is not a drift detector: a
        Go change would leave this green. Both sides read
        `scripts/tests/fixtures/normalize_model_key_cases.json`, and the Go half
        is `phase4-coordinator/internal/billing/normalize_model_key_cases_test.go`,
        so a change to either implementation alone turns one of them red.
        """
        table = json.loads(NORMALIZE_CASES_PATH.read_text())
        self.assertEqual(table["schema_version"], "macprovider.normalize-model-key-cases.v1")
        self.assertTrue(table["cases"])
        go_test = (
            ROOT / "phase4-coordinator" / "internal" / "billing" / "normalize_model_key_cases_test.go"
        ).read_text()
        self.assertIn("normalize_model_key_cases.json", go_test)
        for case in table["cases"]:
            with self.subTest(case["input"]):
                self.assertEqual(catalog_release.normalize_model_key(case["input"]), case["expected"])

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

    def history(self, bindings) -> dict[str, dict]:
        """A recorded EARLIER artifact-bound release (not the one being cut)."""
        return {"published-earlier-v1": self.artifact_row(bindings, feeds={
            name: {
                "bytes": 10, "sha256": "a" * 64, "signer_key_id": "k",
                "version": "published-earlier-v1" if name not in {
                    catalog_release.TIER2_CATALOG_FEED_NAME, catalog_release.RATE_CARD_FEED_NAME
                } else "own-identity",
            }
            for name in catalog_release.ARTIFACT_BOUND_LEDGER_FEEDS
        })}

    def previous_release(self, feed_obj) -> dict:
        return {
            "release_id": "published-earlier-v1",
            "feed_obj": feed_obj,
            "candidate_obj": CANDIDATE_OBJ,
            "record": None,
        }

    def test_artifact_bound_row_must_record_one_signer_across_both_feeds(self):
        """AC-CAT-1 / §3.7.2 in the SHARED ledger validator.

        The row is the durable record of who signed the release, so a document
        that records two different concurrently trusted signers for the artifact
        feed and the candidate catalog is rejected wherever a ledger is read —
        `verify` included — not only where one is generated.
        """
        _, bindings = self.feed_bindings()
        row = self.artifact_row(bindings)
        row["feeds"]["autotune-artifacts.json"]["signer_key_id"] = "rotation-bridge-v2"
        with self.assertRaises(catalog_release.CatalogError) as caught:
            catalog_release.validate_release_ledger(self.ledger({CANDIDATE_OBJ["version"]: row}))
        self.assertIn("must equal the candidate-catalog signer", str(caught.exception))

    def test_one_delta_may_not_both_activate_and_revert(self):
        """SPEC-023 §3.7.8 / AC-CAT-19 over the COMPLETE current ledger.

        Reading activation off the BASE ledger alone answers "not activated yet"
        for every row in a first-activation delta, so a single hand-assembled
        delta could introduce the activation row AND a chronologically later
        four-feed row and pass. Monotonicity is a property of the resulting
        ledger, not of the rows the base happened to already have.
        """
        _, bindings = self.feed_bindings()
        base = catalog_release.validate_release_ledger(
            self.ledger({"published-2026-09-01-pre-v1": {
                "generated_at": "2026-09-01T00:00:00Z",
                "policy_version": CANDIDATE_OBJ["policy_version"],
                "feeds": {
                    name: {
                        "bytes": 10, "sha256": "a" * 64, "signer_key_id": "k",
                        "version": "published-2026-09-01-pre-v1" if name not in {
                            catalog_release.TIER2_CATALOG_FEED_NAME,
                            catalog_release.RATE_CARD_FEED_NAME,
                        } else "own-identity",
                    }
                    for name in catalog_release.RATE_CARD_BOUND_LEDGER_FEEDS
                },
            }}, schema=catalog_release.LEDGER_SCHEMA_V2)
        )
        activation = self.artifact_row(bindings, feeds={
            name: {
                "bytes": 10, "sha256": "a" * 64, "signer_key_id": "k",
                "version": "published-2026-09-02-activation-v1" if name not in {
                    catalog_release.TIER2_CATALOG_FEED_NAME, catalog_release.RATE_CARD_FEED_NAME
                } else "own-identity",
            }
            for name in catalog_release.ARTIFACT_BOUND_LEDGER_FEEDS
        })
        activation["generated_at"] = "2026-09-02T00:00:00Z"
        later_four_feed = {
            "generated_at": "2026-09-03T00:00:00Z",
            "policy_version": CANDIDATE_OBJ["policy_version"],
            "feeds": {
                name: {
                    "bytes": 10, "sha256": "a" * 64, "signer_key_id": "k",
                    "version": "published-2026-09-03-revert-v1" if name not in {
                        catalog_release.TIER2_CATALOG_FEED_NAME, catalog_release.RATE_CARD_FEED_NAME
                    } else "own-identity",
                }
                for name in catalog_release.RATE_CARD_BOUND_LEDGER_FEEDS
            },
        }
        current = catalog_release.validate_release_ledger(self.ledger({
            **base["releases"],
            "published-2026-09-02-activation-v1": activation,
            "published-2026-09-03-revert-v1": later_four_feed,
        }))
        with self.assertRaises(catalog_release.CatalogError) as caught:
            catalog_release.require_ledger_evolution(base, current)
        self.assertIn("published-2026-09-03-revert-v1", str(caught.exception))
        self.assertIn("reverts to", str(caught.exception))

        # The same delta WITHOUT the later four-feed row is the ordinary
        # activation and must still be accepted.
        catalog_release.require_ledger_evolution(
            base,
            catalog_release.validate_release_ledger(self.ledger({
                **base["releases"],
                "published-2026-09-02-activation-v1": activation,
            })),
        )

    def test_cross_release_rebinding_fails_closed(self):
        feed, bindings = self.feed_bindings()
        history = self.history(bindings)
        previous = self.previous_release(feed)

        # Same id, different bytes -> rebinding.
        rebound = copy.deepcopy(feed)
        rebound["models"]["qwen3-8b"]["artifacts"]["mlx-4bit"]["hash"] = "9" * 64
        with self.assertRaises(catalog_release.CatalogError) as caught:
            catalog_release.require_no_artifact_rebinding(rebound, history, previous)
        self.assertIn("is rebound", str(caught.exception))

        # Removal is not an escape hatch: dropping the pair and reintroducing it
        # bound to different bytes fails exactly as an in-place change does.
        absent = copy.deepcopy(feed)
        del absent["models"]["qwen3-8b"]
        with self.assertRaises(catalog_release.CatalogError) as caught:
            catalog_release.require_no_artifact_rebinding(
                rebound, history, self.previous_release(absent)
            )
        self.assertIn("is rebound", str(caught.exception))

    def test_new_bytes_under_a_new_artifact_id_are_allowed(self):
        """AC-CAT-19 positive case: republishing a model's weights adds a NEW
        `artifact_id` carrying the NEW bytes while the old id stays bound to its
        old bytes, retired as `blocked`. Merely blocking the existing id is not
        this case — it adds no bytes and so proves nothing about the rule."""
        feed, bindings = self.feed_bindings()
        history = self.history(bindings)
        previous = self.previous_release(feed)

        widened = copy.deepcopy(feed)
        model = widened["models"]["qwen3-8b"]
        replacement = copy.deepcopy(model["artifacts"]["mlx-4bit"])
        replacement["hash"] = "7" * 64
        replacement["source_ref"] = dict(replacement["source_ref"], revision="f" * 40)
        model["artifacts"]["mlx-4bit-r2"] = replacement
        model["artifacts"]["mlx-4bit"]["verification_status"] = "blocked"
        model["artifacts"]["mlx-4bit"]["verified_at"] = None
        model["primary_artifact_id"] = "mlx-4bit-r2"

        catalog_release.require_no_artifact_rebinding(widened, history, previous)
        widened_bindings = catalog_release.artifact_bindings(widened)
        pairs = {(row["model_key"], row["artifact_id"]): row["hash"] for row in widened_bindings}
        self.assertEqual(pairs[("qwen3-8b", "mlx-4bit-r2")], "7" * 64)
        self.assertEqual(
            pairs[("qwen3-8b", "mlx-4bit")],
            json.loads(canonical(feed))["models"]["qwen3-8b"]["artifacts"]["mlx-4bit"]["hash"],
        )

        # Reintroducing the RETIRED id later, bound to the replacement's bytes,
        # is still a rebinding: a retired id keeps its bytes forever.
        reintroduced = copy.deepcopy(widened)
        reintroduced["models"]["qwen3-8b"]["artifacts"]["mlx-4bit"]["hash"] = "7" * 64
        del reintroduced["models"]["qwen3-8b"]["artifacts"]["mlx-4bit-r2"]
        reintroduced["models"]["qwen3-8b"]["primary_artifact_id"] = "mlx-4bit"
        with self.assertRaises(catalog_release.CatalogError) as caught:
            catalog_release.require_no_artifact_rebinding(reintroduced, history, previous)
        self.assertIn("is rebound", str(caught.exception))

    def test_first_artifact_bound_release_needs_no_previous_release(self):
        feed, _ = self.feed_bindings()
        catalog_release.require_no_artifact_rebinding(feed, {}, None)

    def test_regenerating_the_same_release_excludes_its_own_row(self):
        """The idempotent re-run `resign-autotune-static.sh` performs: this
        release's own ledger row is not prior history, so a second generation
        neither demands a previous release nor rejects its own bindings."""
        feed, bindings = self.feed_bindings()
        ledger = catalog_release.validate_release_ledger(
            self.ledger({CANDIDATE_OBJ["version"]: self.artifact_row(bindings)})
        )
        history = catalog_release.release_history(ledger, CANDIDATE_OBJ["version"])
        self.assertEqual(history, {})
        catalog_release.require_no_artifact_rebinding(feed, history, None)

    def test_previous_release_dir_is_required_once_activated(self):
        feed, bindings = self.feed_bindings()
        with self.assertRaises(catalog_release.CatalogError) as caught:
            catalog_release.require_no_artifact_rebinding(feed, self.history(bindings), None)
        self.assertIn("--previous-release-dir is required", str(caught.exception))


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

    def test_verify_directory_rejects_a_non_default_row_global(self):
        """AC-CAT-14 through `verify-directory`: a staged release whose
        non-default row carries a different `provider_share_bps` is rejected by
        the shared rate-card validator, BEFORE any signature check — so the
        release directory path enforces the release-global invariant on bytes it
        did not generate, not merely on bytes the generator expanded."""
        with tempfile.TemporaryDirectory() as raw:
            directory = pathlib.Path(raw)
            self.stage(directory)
            rate_card = json.loads((directory / "rate-card.json").read_text())
            rate_card["rows"]["qwen3-8b"]["provider_share_bps"] = 8000
            rate_card["version"] = catalog_release.rate_card_projection_hash(rate_card)
            (directory / "rate-card.json").write_bytes(canonical(rate_card))
            with self.assertRaises(catalog_release.CatalogError) as caught:
                self.run_verify(directory)
            self.assertIn("is not the release-global value", str(caught.exception))

    def test_signer_identity_is_an_equality_not_keyring_membership(self):
        """AC-CAT-1: a VALID signature by a different but concurrently trusted key
        fails closed at generation."""
        with tempfile.TemporaryDirectory() as raw:
            directory = pathlib.Path(raw)
            with self.assertRaises(catalog_release.CatalogError) as caught:
                self.stage(directory, artifact_key_id="test-static-v2")
            self.assertIn("must equal the candidate-catalog signer", str(caught.exception))


class PendingSurfaceListTest(unittest.TestCase):
    """`status`'s pending-surface list is the operator's guard against an
    irreversible activation cut, so it must track the tree: every entry names a
    surface that is still ABSENT. The moment a slice lands one, this fails and
    the entry has to go."""

    PROBES = {
        "CLI release payload": ("phase3-binary/dist/package.sh", "autotune-artifacts.json"),
        "GitHub release assets": (".github/workflows/release.yml", "autotune-artifacts.json"),
        "live release gate": ("scripts/verify-live-coordinator-release-gate.py", "catalog-artifacts"),
        "coordinator serving": ("phase4-coordinator/internal/buyer/server.go", "/v1/catalog-artifacts"),
        "scheduled renewal": (".github/workflows/renew-autotune-static-feed-signed.yml", "AUTOTUNE_PREVIOUS_RELEASE_DIR"),
        "coordinator deploy": ("phase4-coordinator/dist/deploy-pearl-vps.sh", "autotune-artifacts.json"),
    }

    def test_every_pending_surface_is_still_absent_from_the_tree(self):
        for surface, _detail in catalog_release.PENDING_DISTRIBUTION_SURFACES:
            with self.subTest(surface):
                self.assertIn(surface, self.PROBES, f"pending surface {surface!r} has no absence probe")
                relative, marker = self.PROBES[surface]
                text = (ROOT / relative).read_text()
                self.assertNotIn(marker, text, f"{surface}: {relative} already carries {marker!r}; drop it from the pending list")

    def test_deferred_requirements_name_their_owner(self):
        for requirement, detail in catalog_release.DEFERRED_REQUIREMENTS:
            with self.subTest(requirement):
                self.assertIn("SPEC-023-R", detail)


class ArtifactFeedConformanceCorpusTest(unittest.TestCase):
    """The shared §3.7 corpus (`scripts/tests/fixtures/artifact_feed_conformance.json`)
    is read by this generator, the Go coordinator, and the Swift CLI, so the
    three validators cannot drift on the closed schema, the identity matrix,
    release binding, or primary consistency."""

    CORPUS = json.loads((ROOT / "scripts" / "tests" / "fixtures" / "artifact_feed_conformance.json").read_text())

    @staticmethod
    def apply(feed: dict, ops: list[dict]) -> None:
        for op in ops:
            *parents, leaf = op["path"]
            target = feed
            for key in parents:
                target = target[key]
            if op["op"] == "set":
                target[leaf] = copy.deepcopy(op["value"])
            elif op["op"] == "delete":
                del target[leaf]
            else:
                raise AssertionError(op)

    def test_every_corpus_case_matches_the_generator_validator(self):
        candidate_obj = catalog_release.validate_candidate(catalog_release.canonical_sorted_bytes(self.CORPUS["candidate"]))
        candidate = catalog_release.canonical_bytes(candidate_obj)
        self.assertGreaterEqual(len(self.CORPUS["cases"]), 25)
        for case in self.CORPUS["cases"]:
            with self.subTest(case["name"]):
                feed = copy.deepcopy(self.CORPUS["feed"])
                feed["candidate_catalog_sha256"] = catalog_release.sha256(candidate)
                self.apply(feed, case["ops"])
                data = catalog_release.canonical_sorted_bytes(feed)
                if case["expect"] == "accept":
                    catalog_release.validate_artifact_feed(data, candidate, candidate_obj)
                else:
                    with self.assertRaises(catalog_release.CatalogError):
                        catalog_release.validate_artifact_feed(data, candidate, candidate_obj)

    def test_baked_swift_snapshot_carries_the_artifact_feed_only_when_bound(self):
        candidate = CANDIDATE_BYTES
        demand = (CATALOG / "demand-rank.json").read_bytes()
        rate_card = RATE_CARD_BYTES
        unbound = catalog_release.generated_swift(candidate, demand, rate_card)
        self.assertIn("static let bakedArtifactFeedJSON: String? = nil", unbound)
        bound = catalog_release.generated_swift(candidate, demand, rate_card, artifacts=b'{"models":{}}')
        self.assertIn('static let bakedArtifactFeedJSON: String? = """', bound)
        self.assertIn('{"models":{}}', bound)


class RateGlobalsTest(unittest.TestCase):
    """SPEC-023 §3.3.1 rules 3+9 / AC-CAT-14: the release-global share and
    multiplier, exactly as coordinator billing derives them."""

    def setUp(self):
        self.rate_card = catalog_release.validate_rate_card(RATE_CARD_BYTES)
        self.coordinator = COORDINATOR_YAML.read_text()

    def test_scaled_conversion_rejects_values_outside_the_int64_domain(self):
        """Go's float64→int64 conversion is implementation-defined out of range,
        so an unbounded Python integer is not a parity result there."""
        with self.assertRaises(catalog_release.CatalogError) as caught:
            catalog_release.scaled_nonnegative_integer(1e16, 1000000, "rewards.global_multiplier")
        self.assertIn("int64", str(caught.exception))
        self.assertEqual(
            catalog_release.scaled_nonnegative_integer(9.0e12, 1000000, "rewards.global_multiplier"),
            9000000000000000000,
        )

    def test_scaled_conversion_matches_go_binary64_rounding(self):
        """Pin the release gate's conversion against `billing.ParseShareBps` /
        `ParseMultiplierPPM` through the SHARED vector table.

        The two implementations must agree on the BINARY64 PRODUCT, not on the
        operator's decimal intent: Go multiplies the parsed float64 by the float64
        scale and rounds half away from zero, so a port that reconstructs the
        value's decimal text and rounds a `Decimal` answers one unit higher
        wherever the product sits just below a half unit that the text lands on.
        A Python-authored expectation table cannot detect that — it only pins
        Python to itself. Both sides read
        `scripts/tests/fixtures/rate_global_rounding_cases.json`, and the Go half
        is `phase4-coordinator/internal/billing/rate_global_rounding_cases_test.go`.
        """
        table = json.loads(ROUNDING_CASES_PATH.read_text())
        self.assertEqual(table["schema_version"], "macprovider.rate-global-rounding-cases.v1")
        self.assertEqual(table["share_scale"], 10000)
        self.assertEqual(table["multiplier_scale"], 1000000)
        go_test = (
            ROOT / "phase4-coordinator" / "internal" / "billing" / "rate_global_rounding_cases_test.go"
        ).read_text()
        self.assertIn("rate_global_rounding_cases.json", go_test)
        divergent = 0
        for case in table["shares"]:
            with self.subTest(share=case["value"]):
                self.assertEqual(
                    catalog_release.scaled_nonnegative_integer(
                        case["value"], table["share_scale"], "share"
                    ),
                    case["expected_bps"],
                )
            divergent += bool(case.get("decimal_divergence"))
        for case in table["multipliers"]:
            with self.subTest(multiplier=case["value"]):
                self.assertEqual(
                    catalog_release.scaled_nonnegative_integer(
                        case["value"], table["multiplier_scale"], "multiplier"
                    ),
                    case["expected_ppm"],
                )
            divergent += bool(case.get("decimal_divergence"))
        # The table is only a parity guard while it still carries vectors that a
        # decimal-semantics port would get wrong.
        self.assertGreaterEqual(divergent, 2)

    def test_a_decimal_semantics_port_would_fail_the_flagged_vectors(self):
        """The `decimal_divergence` flag is a claim about the two roundings, so
        assert it rather than trusting the annotation: for each flagged vector the
        decimal answer must actually differ from the binary64 one."""
        table = json.loads(ROUNDING_CASES_PATH.read_text())
        for scale_key, cases_key, expected_key in (
            ("share_scale", "shares", "expected_bps"),
            ("multiplier_scale", "multipliers", "expected_ppm"),
        ):
            scale = table[scale_key]
            for case in table[cases_key]:
                decimal_answer = int(
                    (Decimal(repr(case["value"])) * scale).quantize(
                        Decimal(1), rounding=ROUND_HALF_UP
                    )
                )
                diverges = decimal_answer != case[expected_key]
                with self.subTest(value=case["value"]):
                    self.assertEqual(diverges, bool(case.get("decimal_divergence")))

    def test_a_floor_half_add_port_would_fail_the_flagged_vectors(self):
        """`math.Round` is NOT `floor(x + 0.5)`.

        The sum is itself a rounded binary64: for a product immediately below a
        half unit, `x + 0.5` can round up onto the next integer and carry the
        value across a boundary it does not actually reach. Go compares the exact
        fractional part instead, and `scaled_nonnegative_integer` must do the
        same. Assert the `floor_half_add_divergence` annotation rather than trust
        it, and require the table to still carry at least one such vector — the
        guard is only a guard while a wrong port would go red on it.
        """
        table = json.loads(ROUNDING_CASES_PATH.read_text())
        flagged = 0
        for scale_key, cases_key, expected_key in (
            ("share_scale", "shares", "expected_bps"),
            ("multiplier_scale", "multipliers", "expected_ppm"),
        ):
            scale = table[scale_key]
            for case in table[cases_key]:
                product = float(case["value"]) * float(scale)
                floor_half_add = int(math.floor(product + 0.5))
                diverges = floor_half_add != case[expected_key]
                with self.subTest(value=case["value"]):
                    self.assertEqual(diverges, bool(case.get("floor_half_add_divergence")))
                    self.assertEqual(
                        catalog_release.scaled_nonnegative_integer(
                            case["value"], scale, "vector"
                        ),
                        case[expected_key],
                    )
                flagged += bool(case.get("floor_half_add_divergence"))
        self.assertGreaterEqual(flagged, 1)

    def test_scaled_conversion_rejects_a_non_finite_or_negative_value(self):
        for raw in (float("nan"), float("inf"), -0.5, "0.9", True):
            with self.subTest(raw=raw):
                with self.assertRaises(catalog_release.CatalogError):
                    catalog_release.scaled_nonnegative_integer(raw, 10000, "share")

    def test_midpoint_share_disagreement_fails_the_parity_gate(self):
        """A signed rate card whose share is the ties-to-even answer for a
        midpoint coordinator value must not pass parity."""
        document = (
            "rewards:\n  global_multiplier: 1.0\n  provider_share: 0.00005\n"
            + catalog_release.coordinator_rate_card_yaml(self.rate_card)
        )
        published = copy.deepcopy(self.rate_card)
        for row in published["rows"].values():
            row["provider_share_bps"] = 0  # what round() would have produced
        with self.assertRaises(catalog_release.CatalogError) as caught:
            catalog_release.check_rate_card_parity(published, document)
        self.assertIn("provider_share", str(caught.exception))
        for row in published["rows"].values():
            row["provider_share_bps"] = 1
        catalog_release.check_rate_card_parity(published, document)

    def test_a_non_default_row_may_not_carry_a_different_global(self):
        """Rule 3 / architect LOW-1: per-row global equality is enforced by the
        SHARED published-rate-card validator, so every verification path — not
        only expansion — rejects a non-default row that disagrees."""
        for field in ("provider_share_bps", "global_multiplier_ppm"):
            with self.subTest(field):
                mutated = copy.deepcopy(self.rate_card)
                mutated["rows"]["qwen3-8b"][field] += 1
                mutated["version"] = catalog_release.rate_card_projection_hash(mutated)
                with self.assertRaises(catalog_release.CatalogError) as caught:
                    catalog_release.validate_rate_card(canonical(mutated))
                self.assertIn("is not the release-global value", str(caught.exception))

    def test_a_non_default_row_global_fails_the_parity_gate(self):
        mutated = copy.deepcopy(self.rate_card)
        mutated["rows"]["qwen3-8b"]["provider_share_bps"] = 8000
        with self.assertRaises(catalog_release.CatalogError) as caught:
            catalog_release.check_rate_card_parity(mutated, self.coordinator)
        self.assertIn("qwen3-8b.provider_share_bps", str(caught.exception))


class IntakeDecisionTest(unittest.TestCase):
    """SPEC-023 §3.7.8: `intake_decision_sha256` is `null` ONLY for a release that
    adds no `listed` row and promotes no row to `recommendable`."""

    DIGEST = "c" * 64

    def candidate_with(self, key: str, status: str) -> dict:
        candidate = copy.deepcopy(CANDIDATE_OBJ)
        if key in candidate["rows"]:
            candidate["rows"][key]["runtime_status"] = status
        else:
            row = copy.deepcopy(candidate["rows"]["qwen3-8b"])
            row["runtime_status"] = status
            candidate["rows"][key] = row
        return candidate

    def tiers(self, overrides: dict[str, str]) -> dict[str, int]:
        tiers = catalog_release.candidate_admission_tiers(CANDIDATE_OBJ)
        for key, status in overrides.items():
            tiers[key] = catalog_release.CANDIDATE_ADMISSION_TIER[status]
        return tiers

    def test_each_add_or_promote_transition_requires_a_digest(self):
        cases = {
            "added as listed": ("brand-new-key", "listed", None),
            "added as recommendable": ("brand-new-key", "recommendable", None),
            "candidate to listed": ("qwen3-8b", "listed", "candidate"),
            "candidate to recommendable": ("qwen3-8b", "recommendable", "candidate"),
            "blocked to listed": ("qwen3-8b", "listed", "blocked"),
            "listed to recommendable": ("qwen3-8b", "recommendable", "listed"),
        }
        for name, (key, status, previous_status) in cases.items():
            with self.subTest(name):
                candidate = self.candidate_with(key, status)
                if previous_status is None:
                    previous = self.tiers({})
                    previous.pop(key, None)
                else:
                    previous = self.tiers({key: previous_status})
                with self.assertRaises(catalog_release.CatalogError) as caught:
                    catalog_release.require_intake_decision(
                        candidate, previous, None, activation=False
                    )
                self.assertIn("intake_decision_sha256 is null", str(caught.exception))
                self.assertIn(key, str(caught.exception))
                # The same release WITH the digest passes.
                catalog_release.require_intake_decision(
                    candidate, previous, self.DIGEST, activation=False
                )

    def test_a_release_with_no_transition_may_carry_null(self):
        catalog_release.require_intake_decision(
            CANDIDATE_OBJ, catalog_release.candidate_admission_tiers(CANDIDATE_OBJ), None, activation=False
        )

    def test_a_demotion_needs_no_intake_decision(self):
        demoted = self.candidate_with("qwen3-8b", "candidate")
        catalog_release.require_intake_decision(
            demoted, catalog_release.candidate_admission_tiers(CANDIDATE_OBJ), None, activation=False
        )

    def test_unavailable_prior_state_fails_closed_after_activation(self):
        with self.assertRaises(catalog_release.CatalogError) as caught:
            catalog_release.require_intake_decision(CANDIDATE_OBJ, None, None, activation=False)
        self.assertIn("--previous-release-dir", str(caught.exception))

    def test_unavailable_prior_state_at_activation_requires_a_digest(self):
        with self.assertRaises(catalog_release.CatalogError) as caught:
            catalog_release.require_intake_decision(CANDIDATE_OBJ, None, None, activation=True)
        self.assertIn("may not be null", str(caught.exception))
        catalog_release.require_intake_decision(CANDIDATE_OBJ, None, self.DIGEST, activation=True)

    def test_prior_state_is_proven_from_the_ledger_candidate_digest(self):
        """The activation release's prior admission state comes from the ledger's
        recorded `autotune-candidates.json` digest: re-stamping the current
        catalog with the preceding release's `version`/`generated_at` reproduces
        its exact bytes when, and only when, nothing else changed."""
        previous_id = "published-earlier-v1"
        restamped = dict(CANDIDATE_OBJ)
        restamped["version"] = previous_id
        restamped["generated_at"] = "2026-08-01T00:00:00Z"
        digest = catalog_release.sha256(catalog_release.canonical_bytes(restamped))
        history = {previous_id: {
            "generated_at": "2026-08-01T00:00:00Z",
            "policy_version": CANDIDATE_OBJ["policy_version"],
            "feeds": {"autotune-candidates.json": {
                "bytes": 10, "sha256": digest, "signer_key_id": "k", "version": previous_id,
            }},
        }}
        self.assertEqual(
            catalog_release.previous_candidate_admission(CANDIDATE_OBJ, history, None),
            catalog_release.candidate_admission_tiers(CANDIDATE_OBJ),
        )
        # A candidate catalog that changed in any other way no longer matches the
        # recorded digest, so prior state is reported unavailable.
        changed = self.candidate_with("qwen3-8b", "listed")
        self.assertIsNone(catalog_release.previous_candidate_admission(changed, history, None))


class HermeticRelease:
    """A throwaway copy of the release inputs the real `generate` can mutate.

    The activation defects this guards against only appear when `generate` is run
    for real, twice, across releases — the unit tests around the helpers were all
    green while the documented signing flow could not complete. Everything here
    is a temp directory and a runtime-generated Ed25519 key; the only stubs are
    `verify_tier2_signature` (Go-backed, orthogonal, covered by
    `scripts/test-catalog-release.sh`) and `base_release_ledger`, whose git
    baseline cannot be resolved for a path outside the repository.
    """

    KEY_ID = "test-hermetic-v1"
    # A SECOND concurrently trusted key, as a rotation bridge has. Its presence is
    # what makes "the keyring accepted this signature" and "one operator signed
    # this release" two different statements (SPEC-023 §3.7.2 / AC-CAT-1).
    ALT_KEY_ID = "test-hermetic-v2"
    SIGNED_FEEDS = ("autotune-candidates.json", "demand-rank.json", "rate-card.json", "autotune-artifacts.json")
    STAGED_FILES = (
        "release.json", "trusted-keys.json", "tier2-catalog.json",
        "autotune-candidates.json", "demand-rank.json", "rate-card.json", "autotune-artifacts.json",
    )

    def __init__(self, root: pathlib.Path, openssl: str):
        self.root = root
        self.openssl = openssl
        self.catalog = root / "catalog"
        self.static = root / "static"
        self.key = root / "signing.pem"
        self.alt_key = root / "signing-alt.pem"
        shutil.copytree(CATALOG, self.catalog)
        # The rule-9 parity gate reads the coordinator config; a throwaway copy
        # lets a test drift it without touching the reviewed money-path file.
        shutil.copy2(COORDINATOR_YAML, root / "coordinator.yaml")
        self.static.mkdir()
        keys = {}
        for key_id, key_path in ((self.KEY_ID, self.key), (self.ALT_KEY_ID, self.alt_key)):
            subprocess.run(
                [openssl, "genpkey", "-algorithm", "ed25519", "-out", str(key_path)],
                check=True, capture_output=True,
            )
            der = subprocess.run(
                [openssl, "pkey", "-in", str(key_path), "-pubout", "-outform", "DER"],
                check=True, capture_output=True,
            ).stdout
            keys[key_id] = {
                "public_key_base64": base64.b64encode(der[-32:]).decode("ascii"),
                "status": "active",
            }
        (self.catalog / "trusted-keys.json").write_text(json.dumps({
            "schema_version": "macprovider.autotune-keys.v1",
            "keys": keys,
        }, indent=2, sort_keys=True) + "\n")
        self.baseline = (self.catalog / "release-ledger.json").read_bytes()
        self._saved: dict[str, object] = {}

    # --- module patching -----------------------------------------------------

    PATHS = {
        "CATALOG_DIR": "catalog",
        "STATIC_DIR": "static",
        "KEYS_PATH": "catalog/trusted-keys.json",
        "MANIFEST_PATH": "catalog/release.json",
        "LEDGER_PATH": "catalog/release-ledger.json",
        "TIER2_BINDING_PATH": "catalog/tier2-identity-binding.json",
        "TIER2_CATALOG_PATH": "catalog/tier2-catalog.json",
        "ARTIFACT_FEED_PATH": "catalog/autotune-artifacts.json",
        "ARTIFACT_SOURCE_PATH": "catalog/autotune-artifacts-source.json",
        "RATE_CARD_SOURCE_PATH": "catalog/rate-card-source.json",
        "INTAKE_DECISION_PATH": "catalog/intake-decision.json",
        "COORDINATOR_YAML_PATH": "coordinator.yaml",
        "SWIFT_GENERATED": "AutotuneCatalog.generated.swift",
        "GO_REJECTED_RELEASES_GENERATED": "rejected_release_ids.generated.go",
    }

    def __enter__(self):
        for name, relative in self.PATHS.items():
            self._saved[name] = getattr(catalog_release, name)
            setattr(catalog_release, name, self.root / relative)
        for name in ("verify_tier2_signature", "base_release_ledger", "keyring", "manifest"):
            self._saved[name] = getattr(catalog_release, name)
        catalog_release.verify_tier2_signature = lambda *args, **kwargs: "tier2-test-key"
        catalog_release.base_release_ledger = lambda: catalog_release.validate_release_ledger(self.baseline)
        # `keyring` and `manifest` bind KEYS_PATH / STATIC_DIR as DEFAULT
        # ARGUMENTS, evaluated at definition time, so rebinding the module
        # globals alone would still read the repository's own release inputs.
        original_keyring = self._saved["keyring"]
        catalog_release.keyring = lambda path=None: original_keyring(
            catalog_release.KEYS_PATH if path is None else path
        )
        original_manifest = self._saved["manifest"]

        def patched_manifest(*args, **kwargs):
            if len(args) < 7 and "sidecar_directory" not in kwargs:
                kwargs["sidecar_directory"] = catalog_release.STATIC_DIR
            return original_manifest(*args, **kwargs)

        catalog_release.manifest = patched_manifest
        return self

    def __exit__(self, *exc):
        for name, value in self._saved.items():
            setattr(catalog_release, name, value)
        return False

    # --- release operations --------------------------------------------------

    def measure_sizes(self) -> None:
        path = self.catalog / "autotune-artifacts-source.json"
        source = json.loads(path.read_text())
        for model in source["models"].values():
            for artifact in model["artifacts"].values():
                artifact["size_bytes"] = FIXTURE_SIZE_BYTES
        path.write_bytes(canonical(source))

    def bump(self, release_id: str, generated_at: str) -> None:
        for name in ("autotune-candidates.json", "demand-rank.json"):
            path = self.catalog / name
            obj = json.loads(path.read_text())
            obj["version"] = release_id
            obj["generated_at"] = generated_at
            path.write_bytes(catalog_release.canonical_bytes(obj))
        source_path = self.catalog / "rate-card-source.json"
        source = json.loads(source_path.read_text())
        source["generated_at"] = generated_at
        source_path.write_text(json.dumps(source, indent=2, sort_keys=True) + "\n")

    def sign_into(
        self,
        directory: pathlib.Path,
        name: str,
        body: bytes,
        key_id: str | None = None,
    ) -> None:
        """Sign `body` into `<name>.sig`. `key_id` selects the alternate trusted
        key, so a test can produce a sidecar that is genuinely valid under the
        keyring yet signed by a different operator key than its sibling feeds."""
        key_id = key_id or self.KEY_ID
        key_path = self.alt_key if key_id == self.ALT_KEY_ID else self.key
        message = directory / f".{name}.signing"
        message.write_bytes(body)
        signature = subprocess.run(
            [self.openssl, "pkeyutl", "-sign", "-rawin", "-inkey", str(key_path), "-in", str(message)],
            check=True, capture_output=True,
        ).stdout
        message.unlink()
        (directory / f"{name}.sig").write_bytes(json.dumps({
            "key_id": key_id,
            "alg": "ed25519",
            "signature": base64.b64encode(signature).decode("ascii"),
        }).encode())

    def sign(self) -> None:
        for name in self.SIGNED_FEEDS:
            path = self.static / name
            if path.exists():
                self.sign_into(self.static, name, path.read_bytes())

    def cut(self, **kwargs) -> None:
        """The documented flow: generate, sign, regenerate, verify."""
        catalog_release.generate(self.KEY_ID, **kwargs)
        self.sign()
        catalog_release.generate(self.KEY_ID, **kwargs)
        catalog_release.verify()

    def stage(self, destination: pathlib.Path) -> pathlib.Path:
        destination.mkdir(parents=True, exist_ok=True)
        for name in self.STAGED_FILES:
            source = self.catalog / name
            if source.exists():
                shutil.copy2(source, destination / name)
        for name in self.SIGNED_FEEDS:
            sidecar = self.static / f"{name}.sig"
            if sidecar.exists():
                shutil.copy2(sidecar, destination / f"{name}.sig")
        return destination

    def ledger(self) -> dict:
        return json.loads((self.catalog / "release-ledger.json").read_text())

    def manifest(self) -> dict:
        return json.loads((self.catalog / "release.json").read_text())


class HermeticReleaseTest(unittest.TestCase):
    """SPEC-023 §3.7.8 Stage A activation, driven through the real `generate`."""

    @classmethod
    def setUpClass(cls):
        cls.openssl = catalog_release.openssl_executable()

    @contextlib.contextmanager
    def harness(self):
        with tempfile.TemporaryDirectory() as raw:
            with HermeticRelease(pathlib.Path(raw) / "repo", self.openssl) as harness:
                yield harness

    def test_four_feed_release_is_unaffected_by_the_committed_unmeasured_source(self):
        """The regression the committed source introduced: `resign` and the
        scheduled freshness renewal both call `generate` unconditionally, and a
        source-presence trigger made them fail on `size_bytes: null`."""
        with self.harness() as harness:
            self.assertTrue((harness.catalog / "autotune-artifacts-source.json").exists())
            harness.bump("published-2026-09-20-renewal-v1", "2026-09-20T00:00:00Z")
            harness.cut()
            self.assertFalse((harness.catalog / "autotune-artifacts.json").exists())
            self.assertEqual(
                set(harness.manifest()["feeds"]), catalog_release.RATE_CARD_BOUND_LEDGER_FEEDS
            )
            self.assertEqual(harness.ledger()["schema_version"], catalog_release.LEDGER_SCHEMA_V2)

    def test_activation_requires_the_explicit_flag(self):
        with self.harness() as harness:
            harness.measure_sizes()
            harness.bump("published-2026-09-20-activation-v1", "2026-09-20T00:00:00Z")
            # A fully measured source still does not activate on its own.
            catalog_release.generate(harness.KEY_ID)
            self.assertFalse((harness.catalog / "autotune-artifacts.json").exists())
            self.assertEqual(
                set(harness.manifest()["feeds"]), catalog_release.RATE_CARD_BOUND_LEDGER_FEEDS
            )

    def test_activation_is_refused_while_a_prerequisite_is_unmet(self):
        with self.harness() as harness:
            harness.bump("published-2026-09-20-activation-v1", "2026-09-20T00:00:00Z")
            with self.assertRaises(catalog_release.CatalogError) as caught:
                catalog_release.generate(harness.KEY_ID, activate_artifact_feed=True)
            message = str(caught.exception)
            self.assertIn("not activatable yet", message)
            self.assertIn("size_bytes", message)

    def test_activation_requires_a_new_release_id(self):
        with self.harness() as harness:
            harness.measure_sizes()
            with self.assertRaises(catalog_release.CatalogError) as caught:
                catalog_release.generate(harness.KEY_ID, activate_artifact_feed=True)
            self.assertIn("requires a NEW release_id", str(caught.exception))

    def activate(self, harness) -> str:
        release_id = "published-2026-09-20-activation-v1"
        harness.measure_sizes()
        harness.bump(release_id, "2026-09-20T00:00:00Z")
        harness.cut(activate_artifact_feed=True)
        return release_id

    def test_activation_refuses_a_rate_card_that_differs_from_the_preceding_release(self):
        """§3.3.1 rule 8 as a generation gate: the activation release is the
        first at which class expansion can change a row, and §3.7.8 makes it
        irreversible, so its rate card must project to the ledger's latest
        recorded rate-card version."""
        with self.harness() as harness:
            harness.measure_sizes()
            harness.bump("published-2026-09-20-activation-v1", "2026-09-20T00:00:00Z")
            source_path = harness.catalog / "rate-card-source.json"
            source = json.loads(source_path.read_text())
            source["rows"]["qwen3-8b"]["completion_rate_per_mtok"] += 1
            source_path.write_text(json.dumps(source, indent=2, sort_keys=True) + "\n")
            with self.assertRaises(catalog_release.CatalogError) as caught:
                catalog_release.generate(harness.KEY_ID, activate_artifact_feed=True)
            self.assertIn("rule 8", str(caught.exception))
            self.assertIn("byte-identical to the preceding release", str(caught.exception))

    def test_verify_re_derives_the_rule_eight_gate_for_the_activation_release(self):
        """Call-site pin: `verify` — the gate CI runs on committed bytes — must
        invoke the rule-8 check for the activation release and must NOT invoke
        it for a four-feed release."""
        calls: list[str] = []
        original = catalog_release.require_rate_card_unchanged_at_activation

        def sentinel(rate_card_obj, history):
            calls.append(rate_card_obj["version"])
            raise catalog_release.CatalogError("rule 8 sentinel")

        with self.harness() as harness:
            harness.bump("published-2026-09-15-pre-activation-v1", "2026-09-15T00:00:00Z")
            harness.cut()  # four-feed release: the gate must not be consulted
            catalog_release.require_rate_card_unchanged_at_activation = sentinel
            try:
                catalog_release.verify()
                self.assertEqual(calls, [])
            finally:
                catalog_release.require_rate_card_unchanged_at_activation = original
            self.activate(harness)
            catalog_release.require_rate_card_unchanged_at_activation = sentinel
            try:
                with self.assertRaises(catalog_release.CatalogError) as caught:
                    catalog_release.verify()
                self.assertIn("rule 8 sentinel", str(caught.exception))
                self.assertEqual(len(calls), 1)
            finally:
                catalog_release.require_rate_card_unchanged_at_activation = original
            catalog_release.verify()

    def test_rewards_parser_tab_rejection_is_scoped_to_the_rewards_block(self):
        """The rule-9 parser's tab rule: a tab above the block is the YAML
        loader's concern; a tab inside the block fails closed; a tab-bearing
        top-level key AFTER the block ends the scan instead of failing it."""
        with self.harness() as harness:
            yaml_path = harness.root / "coordinator.yaml"
            original = yaml_path.read_text()
            above = original.replace("rewards:\n", "tabbed_before:\t\"x\"\nrewards:\n", 1)
            self.assertNotEqual(above, original)
            catalog_release.parse_coordinator_rewards(above)
            after = original.rstrip("\n") + "\ntabbed_after:\t\"x\"\n"
            catalog_release.parse_coordinator_rewards(after)
            inside = original.replace("  provider_share: 0.90", "\tprovider_share: 0.90", 1)
            self.assertNotEqual(inside, original)
            with self.assertRaises(catalog_release.CatalogError) as caught:
                catalog_release.parse_coordinator_rewards(inside)
            self.assertIn("tabs are not permitted in the rewards block", str(caught.exception))

    def test_emit_from_source_is_wired_through_the_cli(self):
        with self.harness() as harness:
            import sys

            output = harness.root / "cli-rows.yaml"
            argv = sys.argv
            sys.argv = ["catalog-release.py", "emit-coordinator-rate-card", "--from-source", "--output", str(output)]
            try:
                with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(catalog_release.main(), 0)
            finally:
                sys.argv = argv
            self.assertIn("  rate_card:\n", output.read_text())

    def test_generate_and_verify_each_enforce_coordinator_parity(self):
        """The rule-9 gate's CALL SITES, not only its body: removing either call
        must fail a test, because `verify` is the only thing that catches a
        coordinator.yaml rate edit that never re-cut the catalog."""
        with self.harness() as harness:
            release_id = self.activate(harness)
            self.assertTrue(release_id)
            yaml_path = harness.root / "coordinator.yaml"
            original = yaml_path.read_text()
            self.assertIn("provider_share: 0.90", original)
            drifted = original.replace("provider_share: 0.90", "provider_share: 0.12345", 1)
            yaml_path.write_text(drifted)
            with self.assertRaises(catalog_release.CatalogError) as at_verify:
                catalog_release.verify()
            self.assertIn("rate-card parity", str(at_verify.exception))
            with self.assertRaises(catalog_release.CatalogError) as at_generate:
                catalog_release.generate(harness.KEY_ID)
            self.assertIn("rate-card parity", str(at_generate.exception))
            yaml_path.write_text(original)
            catalog_release.verify()

    def test_emit_from_source_projects_authored_classes_post_activation(self):
        """Post-activation the documented emitter path must not deadlock: the
        next cut needs the coordinator rows before it can publish the feed that
        would make source and published classes agree again."""
        with self.harness() as harness:
            self.activate(harness)
            artifact_source_path = harness.catalog / "autotune-artifacts-source.json"
            artifact_source = json.loads(artifact_source_path.read_text())
            artifact_source["models"]["qwen3-8b"]["rate_class"] = "class-3b"
            artifact_source_path.write_bytes(canonical(artifact_source))
            rate_source_path = harness.catalog / "rate-card-source.json"
            rate_source = json.loads(rate_source_path.read_text())
            del rate_source["rows"]["qwen3-8b"]
            class_3b = rate_source["classes"]["class-3b"]
            rate_source_path.write_text(json.dumps(rate_source, indent=2, sort_keys=True) + "\n")

            with self.assertRaises(catalog_release.CatalogError) as caught:
                catalog_release.cmd_emit_coordinator_rate_card(harness.root / "rows.yaml")
            self.assertIn("must agree", str(caught.exception))

            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                catalog_release.cmd_emit_coordinator_rate_card(harness.root / "rows.yaml", from_source=True)
            self.assertIn("NOTICE", stderr.getvalue())
            block = (harness.root / "rows.yaml").read_text()
            self.assertIn(f"    qwen3-8b:\n      prompt_credits_per_mtok: {class_3b['prompt_rate_per_mtok']}\n", block)

    def test_activation_then_idempotent_regeneration_then_verify(self):
        """`cut()` IS the runbook sequence: generate, sign, regenerate, verify.
        The second generation must not see this release's own freshly written
        ledger row as prior history."""
        with self.harness() as harness:
            release_id = self.activate(harness)
            feed = (harness.catalog / "autotune-artifacts.json").read_bytes()
            self.assertEqual(
                set(harness.manifest()["feeds"]), catalog_release.ARTIFACT_BOUND_LEDGER_FEEDS
            )
            ledger = harness.ledger()
            self.assertEqual(ledger["schema_version"], catalog_release.LEDGER_SCHEMA_V3)
            row = ledger["releases"][release_id]
            self.assertEqual(
                row["artifact_bindings"],
                catalog_release.artifact_bindings(json.loads(feed)),
            )
            # A third generation is still idempotent, with or without the flag.
            catalog_release.generate(harness.KEY_ID)
            catalog_release.verify()
            self.assertEqual((harness.catalog / "autotune-artifacts.json").read_bytes(), feed)

    def test_post_activation_generate_without_a_previous_release_fails_closed(self):
        with self.harness() as harness:
            self.activate(harness)
            harness.bump("published-2026-09-21-next-v1", "2026-09-21T00:00:00Z")
            with self.assertRaises(catalog_release.CatalogError) as caught:
                catalog_release.generate(harness.KEY_ID)
            self.assertIn("--previous-release-dir is required", str(caught.exception))

    def test_post_activation_release_with_the_previous_release_directory(self):
        with self.harness() as harness:
            self.activate(harness)
            previous = harness.stage(harness.root / "previous")
            harness.bump("published-2026-09-21-next-v1", "2026-09-21T00:00:00Z")
            harness.cut(previous_release_dir=previous)
            ledger = harness.ledger()
            self.assertEqual(
                set(ledger["releases"]["published-2026-09-21-next-v1"]["feeds"]),
                catalog_release.ARTIFACT_BOUND_LEDGER_FEEDS,
            )

    def test_activate_flag_is_refused_once_an_earlier_release_activated(self):
        with self.harness() as harness:
            self.activate(harness)
            harness.bump("published-2026-09-21-next-v1", "2026-09-21T00:00:00Z")
            with self.assertRaises(catalog_release.CatalogError) as caught:
                catalog_release.generate(harness.KEY_ID, activate_artifact_feed=True)
            self.assertIn("only to the FIRST artifact-bound release", str(caught.exception))

    def test_a_stale_published_feed_never_activates_implicitly(self):
        with self.harness() as harness:
            harness.measure_sizes()
            harness.bump("published-2026-09-20-stale-v1", "2026-09-20T00:00:00Z")
            (harness.catalog / "autotune-artifacts.json").write_bytes(b"{}")
            with self.assertRaises(catalog_release.CatalogError) as caught:
                catalog_release.generate(harness.KEY_ID)
            self.assertIn("no release-ledger row binds it", str(caught.exception))

    def test_verify_rejects_a_hand_assembled_cross_release_rebinding(self):
        """AC-CAT-19 through the PUBLIC entry point.

        Generation is not the only way a ledger reaches the release host. A
        release assembled by hand and correctly signed could reuse a
        `(model_key, artifact_id)` under a different identity and still verify,
        because row-level validation only checks uniqueness WITHIN a row. The
        check belongs in the shared ledger validator, so `verify` rejects it.
        """
        with self.harness() as harness:
            release_id = self.activate(harness)
            ledger_path = harness.catalog / "release-ledger.json"
            ledger = json.loads(ledger_path.read_text())
            rebound = copy.deepcopy(ledger["releases"][release_id])
            rebound["artifact_bindings"][0]["hash"] = "4" * 64
            for name, feed in rebound["feeds"].items():
                if name not in {catalog_release.TIER2_CATALOG_FEED_NAME, catalog_release.RATE_CARD_FEED_NAME}:
                    feed["version"] = "published-2026-08-01-hand-assembled-v1"
            ledger["releases"]["published-2026-08-01-hand-assembled-v1"] = rebound
            ledger_path.write_bytes(
                json.dumps(ledger, indent=2, sort_keys=True).encode() + b"\n"
            )
            with self.assertRaises(catalog_release.CatalogError) as caught:
                catalog_release.verify()
            self.assertIn("recorded with two different bindings", str(caught.exception))

    def test_verify_rejects_an_activation_delta_carrying_a_later_four_feed_release(self):
        """AC-CAT-19 through the PUBLIC entry point, for the FIRST activation.

        `origin/main` has no artifact-bound row, so a single delta introducing both
        the activation row and a chronologically later four-feed row is the one
        state a base-only activation verdict cannot see.
        """
        with self.harness() as harness:
            release_id = self.activate(harness)
            ledger_path = harness.catalog / "release-ledger.json"
            ledger = json.loads(ledger_path.read_text())
            activation = ledger["releases"][release_id]
            reverted_id = "published-2026-09-30-revert-v1"
            reverted = {
                "generated_at": "2026-09-30T00:00:00Z",
                "policy_version": activation["policy_version"],
                "feeds": {
                    name: dict(
                        activation["feeds"][name],
                        version=activation["feeds"][name]["version"]
                        if name in {
                            catalog_release.TIER2_CATALOG_FEED_NAME,
                            catalog_release.RATE_CARD_FEED_NAME,
                        }
                        else reverted_id,
                    )
                    for name in catalog_release.RATE_CARD_BOUND_LEDGER_FEEDS
                },
            }
            ledger["releases"][reverted_id] = reverted
            ledger_path.write_bytes(json.dumps(ledger, indent=2, sort_keys=True).encode() + b"\n")
            with self.assertRaises(catalog_release.CatalogError) as caught:
                catalog_release.verify()
            self.assertIn(reverted_id, str(caught.exception))
            self.assertIn("reverts to", str(caught.exception))

    def test_a_candidate_change_still_cuts_a_pre_activation_four_feed_release(self):
        """Code L1: pre-activation, the committed artifact source is unpublished
        and may lag the candidate catalog. A routine identity update must keep
        producing the four-feed release it has always produced instead of being
        blocked by drift against a document nothing is serving yet."""
        with self.harness() as harness:
            path = harness.catalog / "autotune-candidates.json"
            candidate = json.loads(path.read_text())
            candidate["rows"]["qwen3-8b"]["min_ram_gb"] += 1
            path.write_bytes(catalog_release.canonical_bytes(candidate))
            harness.bump("published-2026-09-20-drift-v1", "2026-09-20T00:00:00Z")
            harness.cut()
            row = harness.ledger()["releases"]["published-2026-09-20-drift-v1"]
            self.assertEqual(set(row["feeds"]), catalog_release.RATE_CARD_BOUND_LEDGER_FEEDS)
            # The same drift IS an activation-time prerequisite failure.
            unmet = [
                detail
                for satisfied, detail in catalog_release.artifact_activation_prerequisites(
                    catalog_release.validate_candidate(path.read_bytes()),
                    catalog_release.validate_release_ledger(
                        (harness.catalog / "release-ledger.json").read_bytes()
                    ),
                )
                if not satisfied
            ]
            self.assertTrue(any("min_ram_gb" in detail for detail in unmet), unmet)

    def set_status(self, harness, key: str, status: str) -> None:
        path = harness.catalog / "autotune-candidates.json"
        candidate = json.loads(path.read_text())
        candidate["rows"][key]["runtime_status"] = status
        path.write_bytes(catalog_release.canonical_bytes(candidate))

    def test_intake_decision_is_required_when_a_release_promotes_a_row(self):
        """SPEC-023 §3.7.8: `null` is valid only for a release that adds no
        `listed` row and promotes no row to `recommendable`. Hashing
        `intake-decision.json` "when it happens to exist" is not that rule."""
        with self.harness() as harness:
            self.activate(harness)
            previous = harness.stage(harness.root / "previous")

            # Release N+1 DEMOTES a row: no intake decision is required for that.
            harness.bump("published-2026-09-21-demote-v1", "2026-09-21T00:00:00Z")
            self.set_status(harness, "qwen3-8b", "candidate")
            harness.cut(previous_release_dir=previous)
            self.assertIsNone(
                harness.ledger()["releases"]["published-2026-09-21-demote-v1"]["intake_decision_sha256"]
            )
            demoted = harness.stage(harness.root / "demoted")

            # Release N+2 PROMOTES it back: null now fails the release closed.
            harness.bump("published-2026-09-22-promote-v1", "2026-09-22T00:00:00Z")
            self.set_status(harness, "qwen3-8b", "recommendable")
            with self.assertRaises(catalog_release.CatalogError) as caught:
                catalog_release.generate(harness.KEY_ID, previous_release_dir=demoted)
            self.assertIn("intake_decision_sha256 is null", str(caught.exception))
            self.assertIn("qwen3-8b", str(caught.exception))

            (harness.catalog / "intake-decision.json").write_text('{"decision":"promote qwen3-8b"}\n')
            harness.cut(previous_release_dir=demoted)
            row = harness.ledger()["releases"]["published-2026-09-22-promote-v1"]
            self.assertEqual(len(row["intake_decision_sha256"]), 64)

    def test_verify_re_derives_the_intake_transition_with_the_previous_release(self):
        """SPEC-023 §3.7.8 through `verify`, not only through `generate`.

        `generate` is the only place the transition rule ran, so a hand-assembled
        artifact-bound release that promotes a row while recording
        `intake_decision_sha256: null` — with no `intake-decision.json` for the
        digest to disagree with — verified clean. The rule needs the previous
        release's candidate admission state, which the ledger carries only the
        DIGEST of, so `verify` takes the same authenticated `--previous-release-dir`
        input `generate` takes, and says so explicitly when it is absent.
        """
        with self.harness() as harness:
            self.activate(harness)
            previous = harness.stage(harness.root / "previous")

            harness.bump("published-2026-09-21-demote-v1", "2026-09-21T00:00:00Z")
            self.set_status(harness, "qwen3-8b", "candidate")
            harness.cut(previous_release_dir=previous)
            demoted = harness.stage(harness.root / "demoted")

            promoted_id = "published-2026-09-22-promote-v1"
            harness.bump(promoted_id, "2026-09-22T00:00:00Z")
            self.set_status(harness, "qwen3-8b", "recommendable")
            (harness.catalog / "intake-decision.json").write_text('{"decision":"promote qwen3-8b"}\n')
            harness.cut(previous_release_dir=demoted)
            catalog_release.verify(previous_release_dir=demoted)

            # Hand-assemble the null: drop the intake decision AND the ledger
            # digest together, so every OTHER equality `verify` checks still holds.
            (harness.catalog / "intake-decision.json").unlink()
            ledger_path = harness.catalog / "release-ledger.json"
            ledger = json.loads(ledger_path.read_text())
            ledger["releases"][promoted_id]["intake_decision_sha256"] = None
            ledger_path.write_bytes(json.dumps(ledger, indent=2, sort_keys=True).encode() + b"\n")

            # Without the previous release the verdict is not reconstructible, so
            # `verify` must SAY that rather than pass silently.
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                catalog_release.verify()
            self.assertIn("NOTICE", output.getvalue())
            self.assertIn("intake_decision_sha256", output.getvalue())
            self.assertIn("--previous-release-dir", output.getvalue())

            with self.assertRaises(catalog_release.CatalogError) as caught:
                catalog_release.verify(previous_release_dir=demoted)
            self.assertIn("intake_decision_sha256 is null", str(caught.exception))
            self.assertIn("qwen3-8b", str(caught.exception))

    def test_emit_coordinator_rate_card_projects_a_class_only_row_pre_activation(self):
        """The first activation is otherwise circular.

        `rate_class` is authored on the artifact SOURCE and reaches the published
        feed only at the activation cut, while the coordinator fallback row the
        rule-9 parity gate demands has to be in `coordinator.yaml` BEFORE that cut
        succeeds. Reading the classes through the published feed alone therefore
        makes a class-only row unemittable exactly when the operator needs it.
        """
        with self.harness() as harness:
            source_path = harness.catalog / "rate-card-source.json"
            source = json.loads(source_path.read_text())
            explicit = source["rows"].pop("qwen3-8b")
            source_path.write_text(json.dumps(source, indent=2, sort_keys=True) + "\n")
            self.assertNotIn("qwen3-8b", source["rows"])
            self.assertFalse((harness.catalog / "autotune-artifacts.json").exists())

            output_path = harness.root / "rewards-block.yaml"
            catalog_release.cmd_emit_coordinator_rate_card(output_path)
            block = output_path.read_text()
            self.assertIn("    qwen3-8b:\n", block)

            # The emitted block is the one the parity gate accepts, and the class
            # rates it carries are the values that priced the key explicitly.
            candidate_obj = catalog_release.validate_candidate(
                (harness.catalog / "autotune-candidates.json").read_bytes()
            )
            candidate = catalog_release.canonical_bytes(candidate_obj)
            rate_classes = catalog_release.authoring_rate_classes()
            self.assertEqual(rate_classes["qwen3-8b"], "class-8b")
            rate_card = catalog_release.validate_rate_card(
                catalog_release.resolve_rate_card(rate_classes, candidate_obj)
            )
            self.assertEqual(
                {field: rate_card["rows"]["qwen3-8b"][field] for field in explicit},
                explicit,
            )
            catalog_release.check_rate_card_parity(
                rate_card,
                "rewards:\n  global_multiplier: 1.0\n  provider_share: 0.90\n" + block,
            )

    def test_emit_coordinator_rate_card_reads_published_classes_from_the_feed_bytes(self):
        """Post-activation the source and the PUBLISHED feed must agree on
        `rate_class`, and the published side has to come from the committed feed
        bytes: re-deriving it from the source compares the source with itself
        and can never observe the source drifting from what the release binds.
        """
        with self.harness() as harness:
            harness.measure_sizes()
            harness.bump("published-2026-09-20-activation-v1", "2026-09-20T00:00:00Z")
            harness.cut(activate_artifact_feed=True)
            published = catalog_release.published_feed_rate_classes(harness.catalog / "autotune-artifacts.json")
            self.assertEqual(published["qwen3-8b"], "class-8b")
            self.assertEqual(catalog_release.authoring_rate_classes(), published)

            source_path = harness.catalog / "autotune-artifacts-source.json"
            source = json.loads(source_path.read_text())
            source["models"]["qwen3-8b"]["rate_class"] = "class-3b"
            source_path.write_bytes(canonical(source))
            with self.assertRaises(catalog_release.CatalogError) as caught:
                catalog_release.cmd_emit_coordinator_rate_card(harness.root / "rewards-block.yaml")
            self.assertIn("must agree", str(caught.exception))
            self.assertFalse((harness.root / "rewards-block.yaml").exists())
            with self.assertRaises(catalog_release.CatalogError) as drift:
                catalog_release.verify()
            self.assertIn(f"generated drift: {catalog_release.ARTIFACT_FEED_PATH}", str(drift.exception))

    def test_verify_directory_needs_the_pair_beside_a_five_feed_manifest(self):
        """The acceptance signer's invariant: the provider payload stays at nine
        catalog names, so verifying an artifact-bound RELEASE needs a separate
        directory holding the nine payload files plus the verified pair."""
        with self.harness() as harness:
            self.activate(harness)
            staged = harness.stage(harness.root / "staged")
            nine = harness.root / "nine"
            shutil.copytree(staged, nine)
            (nine / "autotune-artifacts.json").unlink()
            (nine / "autotune-artifacts.json.sig").unlink()
            with self.assertRaises(catalog_release.CatalogError):
                catalog_release.verify_directory(nine)
            catalog_release.verify_directory(staged)

    def test_five_feed_release_passes_the_compatibility_manifest_catalog_component(self):
        """AC-CAT-15 FUNCTIONALLY, not as a relation between two constants.

        A test that only compares `ARTIFACT_BOUND_RELEASE_FEEDS` to
        `RATE_CARD_BOUND_RELEASE_FEEDS | {feed}` stays green if the five-feed
        branch stops reading the artifact body or emits the wrong `files` map. So
        run the real `catalog_component` over a real generated five-feed release.
        """
        with self.harness() as harness:
            release_id = self.activate(harness)
            directory = harness.stage(harness.root / "component")
            component = compatibility_set.catalog_component(directory, directory)

            self.assertEqual(component["release_id"], release_id)
            self.assertEqual(
                sorted(component["files"]), sorted(compatibility_set.CATALOG_FILES)
            )
            self.assertNotIn("autotune-artifacts.json", component["files"])
            for name, digest in component["files"].items():
                with self.subTest(name):
                    self.assertEqual(
                        digest, catalog_release.sha256((directory / name).read_bytes())
                    )

            # The artifact feed is not in the `files` map, but it IS validated:
            # release.json binds five feeds, so the body has to be there and match.
            feed = (directory / "autotune-artifacts.json").read_bytes()
            (directory / "autotune-artifacts.json").unlink()
            with self.assertRaises(compatibility_set.ManifestError) as caught:
                compatibility_set.catalog_component(directory, directory)
            self.assertIn("autotune-artifacts.json", str(caught.exception))

            corrupted = feed[:10] + bytes([feed[10] ^ 0x20]) + feed[11:]
            self.assertEqual(len(corrupted), len(feed))
            (directory / "autotune-artifacts.json").write_bytes(corrupted)
            with self.assertRaises(compatibility_set.ManifestError) as caught:
                compatibility_set.catalog_component(directory, directory)
            self.assertIn("digest does not match", str(caught.exception))

    def test_a_pre_activation_static_artifact_leftover_fails_verify(self):
        """Artifact-feed presence must AGREE across the catalog directory,
        dist/static, `release.json`, and the ledger. A body or sidecar left under
        dist/static by an abandoned activation attempt is bound by nothing, yet
        `resign-autotune-static.sh` would sign it and the release would ship a feed
        no manifest, ledger row, or signer accounts for."""
        for leftover in ("autotune-artifacts.json", "autotune-artifacts.json.sig"):
            with self.subTest(leftover=leftover):
                with self.harness() as harness:
                    harness.bump("published-2026-09-20-leftover-v1", "2026-09-20T00:00:00Z")
                    harness.cut()
                    self.assertFalse((harness.catalog / "autotune-artifacts.json").exists())
                    (harness.static / leftover).write_bytes(b"{}")
                    with self.assertRaises(catalog_release.CatalogError) as caught:
                        catalog_release.verify()
                    self.assertIn("publishes no artifact feed", str(caught.exception))
                    self.assertIn(leftover, str(caught.exception))

    def test_the_signer_refuses_a_pre_activation_static_artifact_leftover(self):
        """`resign-autotune-static.sh` signs whatever artifact body is present
        under dist/static, so the same presence-agreement rule has to hold there:
        the shell guard runs after `generate` and before any signing."""
        script = (ROOT / "scripts" / "resign-autotune-static.sh").read_text()
        guard = script.split('catalog-release.py" "${GENERATE_ARGS[@]}"', 1)[1].split("sign_one", 1)[0]
        self.assertIn('if [ ! -f "$CATALOG_DIR/autotune-artifacts.json" ]; then', guard)
        self.assertIn('-e "$STATIC_DIR/autotune-artifacts.json"', guard)
        self.assertIn('-e "$STATIC_DIR/autotune-artifacts.json.sig"', guard)
        self.assertIn("fatal", guard)


class ReleaseOrderingTest(unittest.TestCase):
    """`generated_at` is RFC3339 with any explicit offset, so "the latest release"
    is a CHRONOLOGICAL question. Lexical string order answers it wrongly, and both
    helpers feed decisions that must not be wrong: which release the §3.7.4
    rebinding check authenticates against, and which release's admission tiers the
    §3.7.8 intake-decision rule compares to."""

    def row(self, release_id: str, generated_at: str, artifact_bound: bool) -> dict:
        names = (
            catalog_release.ARTIFACT_BOUND_LEDGER_FEEDS
            if artifact_bound
            else catalog_release.RATE_CARD_BOUND_LEDGER_FEEDS
        )
        record = {
            "generated_at": generated_at,
            "policy_version": CANDIDATE_OBJ["policy_version"],
            "feeds": {
                name: {"bytes": 10, "sha256": "a" * 64, "signer_key_id": "k", "version": release_id}
                for name in names
            },
        }
        if artifact_bound:
            record["artifact_bindings"] = []
            record["intake_decision_sha256"] = None
        return record

    # 2026-09-19T23:00:00-02:00 is 2026-09-20T01:00:00Z: LATER than
    # 2026-09-20T00:00:00Z, but lexically smaller.
    EARLIER = ("published-a-v1", "2026-09-20T00:00:00Z")
    LATER = ("published-b-v1", "2026-09-19T23:00:00-02:00")

    def test_latest_artifact_bound_release_is_chronological_not_lexical(self):
        releases = {
            self.EARLIER[0]: self.row(*self.EARLIER, artifact_bound=True),
            self.LATER[0]: self.row(*self.LATER, artifact_bound=True),
        }
        self.assertEqual(
            catalog_release.latest_artifact_bound_release(releases)[0], self.LATER[0]
        )

    def test_latest_release_is_chronological_not_lexical(self):
        releases = {
            self.EARLIER[0]: self.row(*self.EARLIER, artifact_bound=False),
            self.LATER[0]: self.row(*self.LATER, artifact_bound=False),
        }
        self.assertEqual(catalog_release.latest_release(releases)[0], self.LATER[0])

    def test_fractional_seconds_do_not_reorder_the_same_instant(self):
        """`...:00Z` and `...:00.000Z` are the same instant spelled two ways;
        lexically the fractional form sorts LATER. The tie-break must be the
        release ID, not the spelling."""
        releases = {
            "published-zz-v1": self.row("published-zz-v1", "2026-09-20T00:00:00Z", artifact_bound=False),
            "published-aa-v1": self.row("published-aa-v1", "2026-09-20T00:00:00.000Z", artifact_bound=False),
        }
        self.assertEqual(catalog_release.latest_release(releases)[0], "published-zz-v1")

    def test_an_offset_release_id_is_only_the_tie_breaker(self):
        releases = {
            "published-zz-v1": self.row("published-zz-v1", "2026-09-20T00:00:00Z", artifact_bound=False),
            "published-aa-v1": self.row("published-aa-v1", "2026-09-21T00:00:00+02:00", artifact_bound=False),
        }
        self.assertEqual(catalog_release.latest_release(releases)[0], "published-aa-v1")


class RenewalFlowTest(unittest.TestCase):
    """The scheduled freshness renewal, driven through the real code path.

    `scripts/renew-autotune-static-feed.sh` runs monthly against a production
    signing key: the signed feed carries a 30-day client freshness horizon, so a
    renewal that cannot complete strands every provider that restarts after the
    horizon. Its restamp is `catalog-release.py restamp`, and these tests run that
    restamp → generate → sign → generate → verify sequence in both the
    pre-activation four-feed state and the post-activation five-feed state.
    """

    NOW = "2026-10-05T09:15:00Z"

    @classmethod
    def setUpClass(cls):
        cls.openssl = catalog_release.openssl_executable()

    @contextlib.contextmanager
    def harness(self):
        with tempfile.TemporaryDirectory() as raw:
            with HermeticRelease(pathlib.Path(raw) / "repo", self.openssl) as harness:
                yield harness

    def assert_atomic_release(self, harness, release_id: str, generated_at: str) -> dict:
        candidate = json.loads((harness.catalog / "autotune-candidates.json").read_text())
        demand = json.loads((harness.catalog / "demand-rank.json").read_text())
        rate_card = json.loads((harness.catalog / "rate-card.json").read_text())
        source = json.loads((harness.catalog / "rate-card-source.json").read_text())
        self.assertEqual(candidate["version"], release_id)
        self.assertEqual(demand["version"], release_id)
        for name, obj in (
            ("candidate", candidate), ("demand", demand),
            ("rate-card", rate_card), ("rate-card-source", source),
        ):
            self.assertEqual(obj["generated_at"], generated_at, name)
        return harness.ledger()["releases"][release_id]

    def test_pre_activation_renewal_restamps_generates_and_verifies(self):
        release_id = "published-2026-10-05-inband-provenance-v1"
        with self.harness() as harness:
            catalog_release.restamp(release_id, self.NOW)
            harness.cut()
            row = self.assert_atomic_release(harness, release_id, self.NOW)
            self.assertEqual(set(row["feeds"]), catalog_release.RATE_CARD_BOUND_LEDGER_FEEDS)

    def test_post_activation_renewal_restamps_generates_and_verifies(self):
        with self.harness() as harness:
            harness.measure_sizes()
            harness.bump("published-2026-09-20-activation-v1", "2026-09-20T00:00:00Z")
            harness.cut(activate_artifact_feed=True)
            previous = harness.stage(harness.root / "previous")

            release_id = "published-2026-10-05-inband-provenance-v1"
            catalog_release.restamp(release_id, self.NOW)
            harness.cut(previous_release_dir=previous)
            row = self.assert_atomic_release(harness, release_id, self.NOW)
            self.assertEqual(set(row["feeds"]), catalog_release.ARTIFACT_BOUND_LEDGER_FEEDS)
            feed = json.loads((harness.catalog / "autotune-artifacts.json").read_text())
            self.assertEqual(feed["release_id"], release_id)
            self.assertEqual(feed["generated_at"], self.NOW)

    def test_continuity_check_covers_the_artifact_feed_by_presence_and_content(self):
        """The freshness-only deploy guard in `renew-autotune-static-feed.sh`. A
        restamp changes only release-derived fields; a change confined to the
        artifact feed's `models` — or the feed appearing or disappearing — is a
        catalog release and must not ride the scheduled renewal."""
        restamped = "published-2026-10-05-inband-provenance-v1"
        with self.harness() as harness:
            harness.measure_sizes()
            harness.bump("published-2026-09-20-activation-v1", "2026-09-20T00:00:00Z")
            harness.cut(activate_artifact_feed=True)
            live = harness.stage(harness.root / "live")
            incoming = harness.stage(harness.root / "incoming")
            self.assertEqual(catalog_release.feed_continuity_drift(incoming, live), [])

            def rewrite(name: str, **fields) -> dict:
                path = incoming / name
                obj = json.loads(path.read_text())
                obj.update(fields)
                path.write_bytes(catalog_release.canonical_bytes(obj))
                return obj

            rewrite("autotune-candidates.json", version=restamped, generated_at=self.NOW)
            rewrite("demand-rank.json", version=restamped, generated_at=self.NOW)
            rewrite("rate-card.json", generated_at=self.NOW)
            feed = rewrite(
                "autotune-artifacts.json", version=restamped, release_id=restamped,
                generated_at=self.NOW, candidate_catalog_sha256="0" * 64,
            )
            self.assertEqual(catalog_release.feed_continuity_drift(incoming, live), [])
            catalog_release.cmd_continuity_check(incoming, live)

            feed["models"]["qwen3-8b"]["rate_class"] = "class-3b"
            (incoming / "autotune-artifacts.json").write_bytes(catalog_release.canonical_bytes(feed))
            self.assertEqual(catalog_release.feed_continuity_drift(incoming, live), ["autotune-artifacts.json"])
            with self.assertRaises(catalog_release.CatalogError) as caught:
                catalog_release.cmd_continuity_check(incoming, live)
            self.assertIn("autotune-artifacts.json", str(caught.exception))
            self.assertIn("freshness-only", str(caught.exception))

            (incoming / "autotune-artifacts.json").unlink()
            self.assertEqual(catalog_release.feed_continuity_drift(incoming, live), ["autotune-artifacts.json"])
            (live / "autotune-artifacts.json").unlink()
            self.assertEqual(catalog_release.feed_continuity_drift(incoming, live), [])
            (live / "autotune-artifacts.json").write_bytes(catalog_release.canonical_bytes(feed))
            self.assertEqual(catalog_release.feed_continuity_drift(incoming, live), ["autotune-artifacts.json"])

            (live / "autotune-artifacts.json").unlink()
            rewrite("autotune-candidates.json", policy_version="autotune-policy-v999")
            self.assertEqual(catalog_release.feed_continuity_drift(incoming, live), ["autotune-candidates.json"])

    def test_restamping_the_generated_rate_card_instead_of_its_source_aborts(self):
        """The regression this replaced. `rate-card.json` is MATERIALISED from
        `rate-card-source.json`, so re-dating the generated file is reverted by the
        very next `generate` and the atomic-release check then aborts the renewal
        on a rate card whose date no longer matches the candidate catalog."""
        release_id = "published-2026-10-05-inband-provenance-v1"
        with self.harness() as harness:
            for name in ("autotune-candidates.json", "demand-rank.json"):
                path = harness.catalog / name
                obj = json.loads(path.read_text())
                obj["version"] = release_id
                obj["generated_at"] = self.NOW
                path.write_bytes(catalog_release.canonical_bytes(obj))
            rate_card_path = harness.catalog / "rate-card.json"
            rate_card = json.loads(rate_card_path.read_text())
            rate_card["generated_at"] = self.NOW
            rate_card_path.write_bytes(catalog_release.canonical_bytes(rate_card))
            with self.assertRaises(catalog_release.CatalogError) as caught:
                catalog_release.generate(harness.KEY_ID)
            self.assertIn("rate-card generated_at", str(caught.exception))

    def test_restamp_falls_back_to_the_published_rate_card_without_a_source(self):
        """A checkout that predates the §3.3.1 authoring source has no
        `rate-card-source.json`; there `rate-card.json` IS the source of truth."""
        release_id = "published-2026-10-05-inband-provenance-v1"
        with self.harness() as harness:
            (harness.catalog / "rate-card-source.json").unlink()
            catalog_release.restamp(release_id, self.NOW)
            harness.cut()
            rate_card = json.loads((harness.catalog / "rate-card.json").read_text())
            self.assertEqual(rate_card["generated_at"], self.NOW)

    def test_restamp_rejects_a_malformed_timestamp(self):
        with self.harness() as harness:
            with self.assertRaises(catalog_release.CatalogError):
                catalog_release.restamp("published-2026-10-05-v1", "2026-10-05 09:15:00")
            with self.assertRaises(catalog_release.CatalogError):
                catalog_release.restamp("published-2026-10-05-v1", "2026-10-05T09:15:00")

    def test_the_renewal_script_delegates_the_restamp_to_the_generator(self):
        """The shell script must not hand-edit the release inputs: which files are
        SOURCES and which are GENERATED is the generator's knowledge, and a
        duplicate in shell is exactly how the two drifted apart."""
        script = (ROOT / "scripts" / "renew-autotune-static-feed.sh").read_text()
        self.assertIn("catalog-release.py restamp", script)
        restamp_block = script.split("catalog-release.py restamp", 1)[1].split("\n\n", 1)[0]
        self.assertIn("--release-id", restamp_block)
        self.assertIn("--generated-at", restamp_block)
        before_generate = script.split("catalog-release.py \"${GENERATE_ARGS[@]}\"", 1)[0]
        self.assertNotIn('rc = cat_dir / "rate-card.json"', before_generate)


class PreviousReleaseDirectoryTest(unittest.TestCase):
    """SPEC-023 §3.7.4: the previous release is an AUTHENTICATED named input."""

    @classmethod
    def setUpClass(cls):
        cls.openssl = catalog_release.openssl_executable()

    @contextlib.contextmanager
    def activated(self):
        with tempfile.TemporaryDirectory() as raw:
            with HermeticRelease(pathlib.Path(raw) / "repo", self.openssl) as harness:
                harness.measure_sizes()
                harness.bump("published-2026-09-20-activation-v1", "2026-09-20T00:00:00Z")
                harness.cut(activate_artifact_feed=True)
                previous = harness.stage(harness.root / "previous")
                ledger = catalog_release.validate_release_ledger(
                    (harness.catalog / "release-ledger.json").read_bytes()
                )
                yield harness, previous, ledger["releases"]

    def test_a_conforming_previous_release_loads(self):
        with self.activated() as (harness, previous, releases):
            loaded = catalog_release.load_previous_release(previous, releases)
            self.assertEqual(loaded["release_id"], "published-2026-09-20-activation-v1")

    def test_tampered_feed_bytes_fail_the_release_json_binding(self):
        """Changing the staged feed and re-signing it with the trusted key is not
        enough: `release.json` still binds the original digest and length."""
        with self.activated() as (harness, previous, releases):
            feed = json.loads((previous / "autotune-artifacts.json").read_text())
            del feed["models"]["qwen3-8b"]
            body = canonical(feed)
            (previous / "autotune-artifacts.json").write_bytes(body)
            harness.sign_into(previous, "autotune-artifacts.json", body)
            with self.assertRaises(catalog_release.CatalogError) as caught:
                catalog_release.load_previous_release(previous, releases)
            self.assertIn("does not match its release.json binding", str(caught.exception))

    def test_ledger_bindings_must_equal_the_signed_feed_exactly(self):
        """Missing pair, extra pair, or a differing identity: the previous
        release's ledger row and its signed feed must agree element for element,
        or the rebinding check is comparing against unproven history."""
        release_id = "published-2026-09-20-activation-v1"
        extra = {
            "artifact_id": "mlx-4bit-extra",
            "hash": "5" * 64,
            "hash_algorithm": catalog_release.SNAPSHOT_MANIFEST_ALG,
            "model_key": "zzz-not-published",
        }
        mutations = {
            "missing pair": lambda rows: rows.pop(),
            "extra pair": lambda rows: rows.append(extra),
            "changed identity": lambda rows: rows[0].update({"hash": "4" * 64}),
        }
        with self.activated() as (harness, previous, releases):
            for name, mutate in mutations.items():
                with self.subTest(name):
                    mutated = copy.deepcopy(releases)
                    mutate(mutated[release_id]["artifact_bindings"])
                    with self.assertRaises(catalog_release.CatalogError) as caught:
                        catalog_release.load_previous_release(previous, mutated)
                    self.assertIn(
                        "do not equal the release-ledger artifact_bindings", str(caught.exception)
                    )

    def test_the_wrong_release_fails_closed(self):
        with self.activated() as (harness, previous, releases):
            manifest = json.loads((previous / "release.json").read_text())
            manifest["release_id"] = "published-2026-01-01-someone-elses-v1"
            (previous / "release.json").write_bytes(
                json.dumps(manifest, indent=2, sort_keys=True).encode() + b"\n"
            )
            with self.assertRaises(catalog_release.CatalogError) as caught:
                catalog_release.load_previous_release(previous, releases)
            self.assertIn("the ledger's latest artifact-bound release is", str(caught.exception))

    def test_two_valid_concurrently_trusted_signers_fail_closed(self):
        """AC-CAT-1 / §3.7.2 across the PREVIOUS release.

        Every other check in `load_previous_release` is per-feed: digest, length,
        sidecar-vs-binding signer, and Ed25519 verification under the trusted
        keyring. A previous release whose artifact feed is signed by a second
        concurrently trusted key — with `release.json` and the ledger row both
        honestly recording that second key — satisfies all of them, and would
        otherwise become the rebinding authority for every later release. The
        equality is over the AUTHENTICATED signers, so re-signing with a real
        second trusted key is the condition that has to fail, not a doctored
        sidecar `key_id`.
        """
        with self.activated() as (harness, previous, releases):
            body = (previous / "autotune-artifacts.json").read_bytes()
            harness.sign_into(previous, "autotune-artifacts.json", body, key_id=harness.ALT_KEY_ID)
            manifest = json.loads((previous / "release.json").read_text())
            manifest["feeds"]["autotune-artifacts.json"]["signer_key_id"] = harness.ALT_KEY_ID
            (previous / "release.json").write_bytes(
                json.dumps(manifest, indent=2, sort_keys=True).encode() + b"\n"
            )
            rotated = copy.deepcopy(releases)
            release_id = "published-2026-09-20-activation-v1"
            rotated[release_id]["feeds"]["autotune-artifacts.json"]["signer_key_id"] = harness.ALT_KEY_ID
            with self.assertRaises(catalog_release.CatalogError) as caught:
                catalog_release.load_previous_release(previous, rotated)
            self.assertIn("must equal the candidate-catalog signer", str(caught.exception))

    def test_the_wrong_signer_fails_closed(self):
        with self.activated() as (harness, previous, releases):
            sidecar = json.loads((previous / "autotune-artifacts.json.sig").read_text())
            sidecar["key_id"] = "some-other-key-v9"
            (previous / "autotune-artifacts.json.sig").write_text(json.dumps(sidecar))
            with self.assertRaises(catalog_release.CatalogError) as caught:
                catalog_release.load_previous_release(previous, releases)
            self.assertIn("not the", str(caught.exception))

    def test_an_invalid_signature_fails_closed(self):
        with self.activated() as (harness, previous, releases):
            sidecar = json.loads((previous / "autotune-artifacts.json.sig").read_text())
            raw = bytearray(base64.b64decode(sidecar["signature"]))
            raw[0] ^= 0xFF
            sidecar["signature"] = base64.b64encode(bytes(raw)).decode("ascii")
            (previous / "autotune-artifacts.json.sig").write_text(json.dumps(sidecar))
            with self.assertRaises(catalog_release.CatalogError) as caught:
                catalog_release.load_previous_release(previous, releases)
            self.assertIn("signature", str(caught.exception).lower())


if __name__ == "__main__":
    unittest.main()
