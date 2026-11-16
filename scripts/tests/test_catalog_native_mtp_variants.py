"""SPEC-048 0.1.81 same-architecture variant expansion in catalog-release.py.

A variant inherits its donor's admission: the tuple entry is the donor's with
the variant's identity, the self-test bank entry reuses the donor's prompt, and
the projection names the variant's artifacts. Runs on the committed catalog.
"""

from __future__ import annotations

import copy
import json
import pathlib
import tempfile
import unittest

from scripts.tests import test_catalog_artifact_feed as artifact_tests

catalog_release = artifact_tests.catalog_release
CATALOG = catalog_release.CATALOG_DIR
DONOR = "zai-org/glm-5.3-flash"
VARIANT = "example/glm-5.3-flash-variant"


def committed() -> tuple[list, dict, dict]:
    tuple_value = json.loads(catalog_release.NATIVE_MTP_TUPLE_INPUT_PATH.read_text())
    inputs = tuple_value if isinstance(tuple_value, list) else [tuple_value]
    bank = json.loads((CATALOG / catalog_release.NATIVE_MTP_BANK_NAME).read_text())
    manifest = json.loads((CATALOG / catalog_release.NATIVE_MTP_MANIFEST_NAME).read_text())
    return inputs, bank, manifest


def own_quantization() -> dict:
    """The variant's own block: the donor's kind with another group of
    per-layer exceptions and representation manifest."""
    inputs, _, _ = committed()
    donor = next(i["entry"] for i in inputs if i["entry"]["model_key"] == DONOR)
    quantization = copy.deepcopy(donor["quantization"])
    quantization["per_layer_exceptions"] = quantization["per_layer_exceptions"][:-11]
    quantization["representation_manifest_sha256"] = "e" * 64
    return quantization


def variants(record: dict | None = None, donor: str = DONOR, quantization: object = "own") -> dict:
    variant = {
        "model_key": VARIANT,
        "donor_model_key": donor,
        "artifact_id": "mlx-oq4e-mtp",
        "artifact_hash": "a" * 64,
        "tokenizer_sha256": "b" * 64,
        "mtp_manifest_sha256": "c" * 64,
        "projection_artifacts": {
            "target": {"path": "variant", "sha256": "a" * 64},
            "mtp": {"path": "variant", "sha256": "a" * 64},
            "tokenizer": {"path": "variant/tokenizer.json", "sha256": "b" * 64},
            "manifest": {"path": "variant/config.json", "sha256": "c" * 64},
        },
    }
    if quantization == "own":
        variant["quantization"] = own_quantization()
    elif quantization is not None:
        variant["quantization"] = quantization
    if record is not None:
        variant["self_check_record"] = record
    return {"schema_version": catalog_release.NATIVE_MTP_VARIANTS_SCHEMA, "variants": [variant]}


def feed(variant_kind: object = "oq4e-mixed-4-5-6-8bit-g64", donor_hash: str | None = None) -> dict:
    """An artifact feed naming the committed donor's artifact and the variant's."""
    inputs, _, _ = committed()
    donor = next(i["entry"] for i in inputs if i["entry"]["model_key"] == DONOR)
    donor_record = {"quantization": "oq4e-mixed-4-5-6-8bit-g64", "hash": donor_hash or donor["artifact_hash"]}
    variant_record = {"hash": "a" * 64}
    if variant_kind is not None:
        variant_record["quantization"] = variant_kind
    return {"models": {
        DONOR: {"artifacts": {donor["artifact_id"]: donor_record}},
        VARIANT: {"artifacts": {"mlx-oq4e-mtp": variant_record}},
    }}


def expand(inputs, bank, manifest, variants_obj, artifact_obj=None):
    return catalog_release.expand_native_mtp_variants(
        inputs, bank, manifest, variants_obj, feed() if artifact_obj is None else artifact_obj
    )


class NativeMTPVariantExpansionTests(unittest.TestCase):
    def test_variant_inherits_the_donor_entry_and_prompt(self):
        inputs, bank, manifest = committed()
        out_inputs, out_bank, out_manifest = expand(
            inputs, bank, manifest, variants()
        )
        donor = next(i["entry"] for i in inputs if i["entry"]["model_key"] == DONOR)
        entry = next(i["entry"] for i in out_inputs if i["entry"]["model_key"] == VARIANT)
        for key in ("mtp_family_adapter", "proposal_depth", "qualified_slots",
                    "max_native_active_rows", "max_prompt_tokens", "performance_evidence_sha256",
                    "fit_evidence_sha256", "hardware_class"):
            self.assertEqual(entry[key], donor[key], key)
        self.assertEqual(entry["artifact_hash"], "a" * 64)
        self.assertEqual(entry["ordinary_baseline"]["artifact_hash"], "a" * 64)
        donor_challenge = next(c for c in bank["entries"] if c["model_id"] == DONOR)
        challenge = next(c for c in out_bank["entries"] if c["model_id"] == VARIANT)
        self.assertEqual(challenge["prompt_token_ids"], donor_challenge["prompt_token_ids"])
        self.assertEqual(challenge["model_hash"], "a" * 64)
        # GLM-5.3-Flash carries its drafter in the checkpoint: the drafter
        # artifact is the variant's own target artifact.
        self.assertEqual(challenge["artifact_sha256"], "a" * 64)
        self.assertNotEqual(challenge["challenge_id"], donor_challenge["challenge_id"])
        ids = [c["challenge_id"] for c in out_bank["entries"]]
        self.assertEqual(ids, sorted(ids))
        self.assertIn(VARIANT, out_manifest["models"])
        self.assertIn(DONOR, out_manifest["models"])

    def test_expansion_is_a_fixpoint(self):
        inputs, bank, manifest = committed()
        once = expand(inputs, bank, manifest, variants())
        twice = expand(*once, variants())
        self.assertEqual(once, twice)

    def test_self_check_record_sets_the_variant_expectations(self):
        inputs, bank, manifest = committed()
        record = {
            "expected_token_ids": [5, 6, 7],
            "expected_terminal_reason": "length",
            "expected_counters": {"accepted": 1, "rejected": 0, "bonus": 1, "committed": 2},
            "expected_committed_state_sha256": "d" * 64,
        }
        _, out_bank, _ = expand(
            inputs, bank, manifest, variants(copy.deepcopy(record))
        )
        challenge = next(c for c in out_bank["entries"] if c["model_id"] == VARIANT)
        self.assertEqual(challenge["expected_token_ids"], [5, 6, 7])
        self.assertEqual(
            challenge["expected_token_id_sha256"],
            catalog_release.sha256(b"[5,6,7]"),
        )
        self.assertEqual(challenge["expected_committed_state_sha256"], "d" * 64)

    def test_unknown_donor_is_refused(self):
        inputs, bank, manifest = committed()
        with self.assertRaisesRegex(catalog_release.CatalogError, "donor_model_key"):
            expand(inputs, bank, manifest, variants(donor="nobody/model"))

    def test_mismatched_quantization_kind_is_refused(self):
        inputs, bank, manifest = committed()
        with self.assertRaisesRegex(catalog_release.CatalogError, "quantization kind '4bit' differs"):
            expand(inputs, bank, manifest, variants(), feed(variant_kind="4bit"))

    def test_missing_quantization_kind_is_refused(self):
        inputs, bank, manifest = committed()
        with self.assertRaisesRegex(catalog_release.CatalogError, "no quantization kind"):
            expand(inputs, bank, manifest, variants(), feed(variant_kind=None))
        with self.assertRaisesRegex(catalog_release.CatalogError, "no quantization kind"):
            catalog_release.expand_native_mtp_variants(inputs, bank, manifest, variants(), None)

    def test_variant_signs_its_own_quantization_block(self):
        inputs, bank, manifest = committed()
        donor = next(i["entry"] for i in inputs if i["entry"]["model_key"] == DONOR)
        out_inputs, _, _ = expand(inputs, bank, manifest, variants())
        entry = next(i["entry"] for i in out_inputs if i["entry"]["model_key"] == VARIANT)
        self.assertEqual(entry["quantization"], own_quantization())
        self.assertNotEqual(entry["quantization"], donor["quantization"])
        self.assertEqual(entry["quantization"]["kind"], donor["quantization"]["kind"])
        # The donor's own entry keeps its block.
        out_donor = next(i["entry"] for i in out_inputs if i["entry"]["model_key"] == DONOR)
        self.assertEqual(out_donor["quantization"], donor["quantization"])

    def test_variant_without_its_own_quantization_block_is_refused(self):
        inputs, bank, manifest = committed()
        with self.assertRaisesRegex(catalog_release.CatalogError, "declares no quantization block"):
            expand(inputs, bank, manifest, variants(quantization=None))

    def test_variant_with_an_invalid_quantization_block_is_refused(self):
        inputs, bank, manifest = committed()
        quantization = own_quantization()
        del quantization["representation_manifest_sha256"]
        with self.assertRaisesRegex(ValueError, "variants\\[0\\].quantization"):
            expand(inputs, bank, manifest, variants(quantization=quantization))

    def test_variant_declaring_another_quantization_kind_is_refused(self):
        inputs, bank, manifest = committed()
        quantization = own_quantization()
        quantization["kind"] = "base"
        for key in ("packed_data_dtype", "packed_layout", "scale_dtype", "scale_layout", "padding_rule"):
            quantization[key] = "none"
        quantization.update(block_size_elements=None, per_layer_exceptions=[], unquantized_exceptions=[])
        with self.assertRaisesRegex(catalog_release.CatalogError, "quantization.kind 'base' differs"):
            expand(inputs, bank, manifest, variants(quantization=quantization))


def snapshot_manifest(files: dict[str, int]) -> bytes:
    return "".join(f"{path}\n{size}\n{'f' * 64}\n" for path, size in sorted(files.items())).encode("utf-8")


class NativeMTPVariantWeightFitTests(unittest.TestCase):
    """R012: served safetensors bytes, read from the hash-bound snapshot manifest."""

    def fit(self, variant_files: dict[str, int], donor_files: dict[str, int], write=None):
        donor_bytes, variant_bytes = snapshot_manifest(donor_files), snapshot_manifest(variant_files)
        donor_hash, variant_hash = catalog_release.sha256(donor_bytes), catalog_release.sha256(variant_bytes)
        artifact_obj = {"models": {
            DONOR: {"artifacts": {"mlx-oq4e-mtp": {"hash": donor_hash}}},
            VARIANT: {"artifacts": {"mlx-oq4e-variant": {"hash": variant_hash}}},
        }}
        variant = {"model_key": VARIANT, "donor_model_key": DONOR, "artifact_id": "mlx-oq4e-variant"}
        donors = {DONOR: {"model_key": DONOR, "artifact_id": "mlx-oq4e-mtp"}}
        with tempfile.TemporaryDirectory() as tmp:
            directory = pathlib.Path(tmp)
            (directory / f"{donor_hash}.manifest").write_bytes(donor_bytes)
            (directory / f"{variant_hash}.manifest").write_bytes(variant_bytes)
            if write is not None:
                write(directory, variant_hash)
            catalog_release.require_native_mtp_variant_weight_fit([variant], donors, artifact_obj, directory)

    def test_larger_snapshot_with_no_larger_weights_passes(self):
        # The #2382 shape: GGUF and mmproj files make the snapshot larger,
        # the served safetensors are smaller than the donor's.
        self.fit(
            {"model-00001.safetensors": 90, "model-00002.safetensors": 9, "dflash2.gguf": 500, "mmproj.gguf": 50},
            {"model-00001.safetensors": 90, "model-00002.safetensors": 10, "README.md": 5},
        )

    def test_genuinely_larger_weights_are_refused(self):
        with self.assertRaisesRegex(catalog_release.CatalogError, "served weight bytes 101 exceed its donor's 100"):
            self.fit(
                {"model-00001.safetensors": 91, "model-00002.safetensors": 10},
                {"model-00001.safetensors": 90, "model-00002.safetensors": 10, "dflash2.gguf": 500},
            )

    def test_missing_manifest_is_refused(self):
        def remove(directory, variant_hash):
            (directory / f"{variant_hash}.manifest").unlink()
        with self.assertRaisesRegex(catalog_release.CatalogError, "R012 needs its snapshot manifest"):
            self.fit({"a.safetensors": 1}, {"a.safetensors": 2}, remove)

    def test_manifest_not_matching_the_feed_hash_is_refused(self):
        def tamper(directory, variant_hash):
            # Understating the weights breaks the hash binding.
            (directory / f"{variant_hash}.manifest").write_bytes(snapshot_manifest({"a.safetensors": 1}))
        with self.assertRaisesRegex(catalog_release.CatalogError, "does not hash to the feed's artifact hash"):
            self.fit({"a.safetensors": 3}, {"a.safetensors": 2}, tamper)


if __name__ == "__main__":
    unittest.main()
