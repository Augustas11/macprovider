"""SPEC-048 0.1.81 same-architecture variant expansion in catalog-release.py.

A variant inherits its donor's admission: the tuple entry is the donor's with
the variant's identity, the self-test bank entry reuses the donor's prompt, and
the projection names the variant's artifacts. Runs on the committed catalog.
"""

from __future__ import annotations

import copy
import json
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


def variants(record: dict | None = None, donor: str = DONOR) -> dict:
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

    def test_variant_gets_its_own_quantization_provenance(self):
        inputs, bank, manifest = committed()
        donor = next(i["entry"] for i in inputs if i["entry"]["model_key"] == DONOR)
        out_inputs, _, _ = expand(inputs, bank, manifest, variants())
        entry = next(i["entry"] for i in out_inputs if i["entry"]["model_key"] == VARIANT)
        self.assertEqual(entry["quantization"]["representation_manifest_sha256"], "a" * 64)
        self.assertNotEqual(
            entry["quantization"]["representation_manifest_sha256"],
            donor["quantization"]["representation_manifest_sha256"],
        )
        self.assertEqual(entry["quantization"]["kind"], donor["quantization"]["kind"])


if __name__ == "__main__":
    unittest.main()
