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
MTP_HASH = "a" * 64
TOKENIZER_HASH = "b" * 64


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

    def test_variant_challenge_id_fits_the_provider_cache_namespace(self):
        # Issue #2404: providers up to CLI 1.8.292 refuse a canary whose
        # cache namespace `native_mtp:<64-hex>:<challenge_id>` exceeds 128
        # bytes, so every bank challenge id stays within 52 bytes.
        inputs, bank, manifest = committed()
        _, out_bank, _ = expand(inputs, bank, manifest, variants())
        for challenge in out_bank["entries"]:
            namespace = f"native_mtp:{'0' * 64}:{challenge['challenge_id']}"
            self.assertLessEqual(len(namespace.encode("utf-8")), 128, challenge["challenge_id"])
        committed_ids = [c["challenge_id"] for c in bank["entries"]]
        self.assertTrue(all(len(i.encode("utf-8")) <= catalog_release.NATIVE_MTP_CHALLENGE_ID_MAX_BYTES
                            for i in committed_ids), committed_ids)

    def test_overlong_challenge_id_is_refused(self):
        inputs, bank, manifest = committed()
        bank = copy.deepcopy(bank)
        donor = next(c for c in bank["entries"] if c["model_id"] == DONOR)
        donor["challenge_id"] = "native-mtp-selftest-" + "x" * 40
        bank["entries"].sort(key=lambda entry: entry["challenge_id"])
        with self.assertRaisesRegex(catalog_release.CatalogError, "exceeds 52 bytes"):
            expand(inputs, bank, manifest, variants())

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

    def fit(self, variant_files: dict[str, int], donor_files: dict[str, int], write=None, evidence=None,
            donor_edit=None, variant_edit=None):
        donor_bytes, variant_bytes = snapshot_manifest(donor_files), snapshot_manifest(variant_files)
        donor_hash, variant_hash = catalog_release.sha256(donor_bytes), catalog_release.sha256(variant_bytes)
        artifact_obj = {"models": {
            DONOR: {"artifacts": {"mlx-oq4e-mtp": {"hash": donor_hash}}},
            VARIANT: {"artifacts": {"mlx-oq4e-variant": {"hash": variant_hash}}},
        }}
        variant = {"model_key": VARIANT, "donor_model_key": DONOR, "artifact_id": "mlx-oq4e-variant",
                   "artifact_hash": variant_hash, "mtp_artifact_sha256": MTP_HASH, "tokenizer_sha256": TOKENIZER_HASH}
        donor = {"model_key": DONOR, "artifact_id": "mlx-oq4e-mtp", "max_prompt_tokens": 32768,
                 "qualified_slots": 4, "ram_bytes": 256 * 2**30}
        if donor_edit:
            donor_edit(donor)
        if variant_edit:
            variant_edit(variant)
        donors = {DONOR: donor}
        with tempfile.TemporaryDirectory() as tmp:
            directory = pathlib.Path(tmp)
            (directory / f"{donor_hash}.manifest").write_bytes(donor_bytes)
            (directory / f"{variant_hash}.manifest").write_bytes(variant_bytes)
            if write is not None:
                write(directory, variant_hash)
            if evidence is not None:
                variant["fit_evidence"] = evidence(directory, variant_hash)
            catalog_release.require_native_mtp_variant_weight_fit(
                [variant], donors, artifact_obj, directory, evidence_root=directory
            )

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

    # SPEC-048 0.1.126: a larger variant passes only on its own bound fit evidence.
    LARGER = ({"model-00001.safetensors": 91}, {"model-00001.safetensors": 90})

    @staticmethod
    def evidence(policy_edit=None, analysis_edit=None, path_edit=None):
        def write(directory: pathlib.Path, variant_hash: str) -> dict:
            policy = {
                "schema": catalog_release.NATIVE_MTP_R015_POLICY_SCHEMA,
                "model_id": VARIANT,
                "target_sha256": variant_hash,
                "mtp_sha256": MTP_HASH,
                "tokenizer_sha256": TOKENIZER_HASH,
                "ram_gb": 256,
                "maximum_prompt_tokens": 32768,
                "sustained_cell_id": "s4-p1536-o512",
                "sustained_seconds": 1800,
                "thresholds": {"min_available_memory_fraction": 0.1},
            }
            if policy_edit:
                policy_edit(policy)
            policy_bytes = json.dumps(policy).encode()
            analysis = {
                "schema": catalog_release.NATIVE_MTP_R015_ANALYSIS_SCHEMA,
                "policy_sha256": catalog_release.sha256(policy_bytes),
                "cells": [
                    {"cell_id": "s1-p32768-o128", "memory_failures": [], "hard_failures": [],
                     "min_available_memory_fraction": 0.85, "sustained_runs": 0,
                     "sustained_min_available_memory_fraction": 0, "sustained_duration_seconds": 0},
                    {"cell_id": "s4-p1536-o512", "memory_failures": [], "hard_failures": [],
                     "min_available_memory_fraction": 0.85, "sustained_runs": 42,
                     "sustained_min_available_memory_fraction": 0.85, "sustained_duration_seconds": 1803.9},
                ],
            }
            if analysis_edit:
                analysis_edit(analysis)
            analysis_bytes = json.dumps(analysis).encode()
            folder = directory / "docs" / "evidence" / "variant"
            folder.mkdir(parents=True, exist_ok=True)
            (folder / "policy.json").write_bytes(policy_bytes)
            (folder / "analysis.json").write_bytes(analysis_bytes)
            refs = {
                "policy": {"path": "docs/evidence/variant/policy.json", "sha256": catalog_release.sha256(policy_bytes)},
                "analysis": {"path": "docs/evidence/variant/analysis.json",
                             "sha256": catalog_release.sha256(analysis_bytes)},
            }
            if path_edit:
                path_edit(refs)
            return refs
        return write

    def test_larger_weights_pass_with_their_own_fit_evidence(self):
        self.fit(*self.LARGER, evidence=self.evidence())

    def test_larger_weights_without_fit_evidence_are_refused(self):
        with self.assertRaisesRegex(catalog_release.CatalogError, "it needs its own fit evidence"):
            self.fit(*self.LARGER)

    def test_fit_evidence_refusals(self):
        def setitem(key, value):
            return lambda obj: obj.__setitem__(key, value)
        cases = {
            "target_sha256 does not name": self.evidence(policy_edit=setitem("target_sha256", "d" * 64)),
            "model_id does not name": self.evidence(policy_edit=setitem("model_id", DONOR)),
            "below the donor's max_prompt_tokens": self.evidence(policy_edit=setitem("maximum_prompt_tokens", 8192)),
            "free-memory floor": self.evidence(policy_edit=setitem("thresholds", {"min_available_memory_fraction": 0.05})),
            "records memory failures": self.evidence(analysis_edit=lambda a: a["cells"][1].__setitem__(
                "memory_failures", ["available_memory_below_floor"])),
            "does not name the bound policy": self.evidence(analysis_edit=setitem("policy_sha256", "e" * 64)),
            "sustained cell": self.evidence(policy_edit=setitem("sustained_cell_id", "s4-p4096-o512")),
            "records hard failures": self.evidence(analysis_edit=lambda a: a["cells"][0].__setitem__(
                "hard_failures", ["crash"])),
            "cell 's1-p32768-o128' measured min_available_memory_fraction": self.evidence(
                analysis_edit=lambda a: a["cells"][0].__setitem__("min_available_memory_fraction", 0.05)),
            "measured min_available_memory_fraction None": self.evidence(
                analysis_edit=lambda a: a["cells"][0].pop("min_available_memory_fraction")),
            "sustained min_available_memory_fraction": self.evidence(
                analysis_edit=lambda a: a["cells"][1].__setitem__("sustained_min_available_memory_fraction", 0.02)),
            "no cell ran at the donor's max_prompt_tokens": self.evidence(
                analysis_edit=lambda a: a["cells"][0].__setitem__("cell_id", "s1-p4096-o128")),
            "no cell ran at the donor's qualified_slots": self.evidence(
                policy_edit=setitem("sustained_cell_id", "s2-p1536-o512"),
                analysis_edit=lambda a: a["cells"][1].__setitem__("cell_id", "s2-p1536-o512")),
            "short of the policy's sustained_seconds": self.evidence(
                analysis_edit=lambda a: a["cells"][1].__setitem__("sustained_duration_seconds", 900)),
            "mtp_sha256 does not name": self.evidence(policy_edit=setitem("mtp_sha256", "c" * 64)),
            "tokenizer_sha256 does not name": self.evidence(policy_edit=setitem("tokenizer_sha256", "c" * 64)),
            "does not match the tuple's ram_bytes": self.evidence(policy_edit=setitem("ram_gb", 128)),
            "must be a unique s<slots>": self.evidence(
                analysis_edit=lambda a: a["cells"][0].__setitem__("cell_id", "s1")),
            "does not hash to": self.evidence(path_edit=lambda r: r["policy"].__setitem__("sha256", "f" * 64)),
            "must be a .json file under": self.evidence(
                path_edit=lambda r: r["analysis"].__setitem__("path", "docs/evidence/../x.json")),
        }
        for message, evidence in cases.items():
            with self.subTest(message), self.assertRaisesRegex(catalog_release.CatalogError, message):
                self.fit(*self.LARGER, evidence=evidence)

    def test_fit_evidence_needs_the_variant_mtp_head(self):
        # Without this, a variant with no mtp_artifact_sha256 and a policy with no mtp_sha256
        # would match on None == None.
        def drop_head(policy):
            policy.pop("mtp_sha256")
        with self.assertRaisesRegex(catalog_release.CatalogError, "must declare a hex mtp_artifact_sha256"):
            self.fit(*self.LARGER, evidence=self.evidence(policy_edit=drop_head),
                     variant_edit=lambda v: v.pop("mtp_artifact_sha256"))

    def test_fit_evidence_needs_the_donor_bounds(self):
        for key, message in (("max_prompt_tokens", "no max_prompt_tokens bound"),
                             ("qualified_slots", "no qualified_slots")):
            with self.subTest(key), self.assertRaisesRegex(catalog_release.CatalogError, message):
                self.fit(*self.LARGER, evidence=self.evidence(), donor_edit=lambda d, k=key: d.pop(k))

    def test_fit_evidence_paths_resolve_strictly(self):
        def link_folder(directory: pathlib.Path, variant_hash: str) -> dict:
            refs = self.evidence()(directory, variant_hash)
            real = directory / "docs" / "evidence" / "variant"
            moved = directory / "docs" / "evidence" / "real"
            real.rename(moved)
            real.symlink_to(moved, target_is_directory=True)
            return refs
        with self.assertRaisesRegex(catalog_release.CatalogError, "symlinked component 'variant'"):
            self.fit(*self.LARGER, evidence=link_folder)

        def link_outside(directory: pathlib.Path, variant_hash: str) -> dict:
            refs = self.evidence()(directory, variant_hash)
            docs = directory / "docs"
            outside = directory / "outside"
            (docs / "evidence").rename(outside)
            (docs / "evidence").symlink_to(outside, target_is_directory=True)
            return refs
        with self.assertRaisesRegex(catalog_release.CatalogError, "symlinked component 'evidence'"):
            self.fit(*self.LARGER, evidence=link_outside)

        def link_file(directory: pathlib.Path, variant_hash: str) -> dict:
            refs = self.evidence()(directory, variant_hash)
            policy = directory / "docs" / "evidence" / "variant" / "policy.json"
            target = directory / "policy-elsewhere.json"
            target.write_bytes(policy.read_bytes())
            policy.unlink()
            policy.symlink_to(target)
            return refs
        with self.assertRaisesRegex(catalog_release.CatalogError, "symlinked component 'policy.json'"):
            self.fit(*self.LARGER, evidence=link_file)

    def test_declared_fit_evidence_is_checked_even_when_not_needed(self):
        with self.assertRaisesRegex(catalog_release.CatalogError, "records memory failures"):
            self.fit({"a.safetensors": 1}, {"a.safetensors": 2}, evidence=self.evidence(
                analysis_edit=lambda a: a["cells"][0].__setitem__("memory_failures", ["oom"])))



class BindSelfCheckRecordTest(unittest.TestCase):
    """SPEC-048 MTP-16: a captured on-device self-check binds as the variant's
    self_check_record, only for the variant's own expanded challenge."""

    CHALLENGE = "native-mtp-selftest-donor-0001-vabcdef012345"
    RECORD = {"expected_token_ids": [1, 2, 3], "expected_terminal_reason": "length",
              "expected_counters": {"accepted": 1, "rejected": 0, "bonus": 1, "committed": 3},
              "expected_committed_state_sha256": "c" * 64}

    def bind(self, source_text: str, model_key: str = VARIANT):
        with tempfile.TemporaryDirectory() as tmp:
            directory = pathlib.Path(tmp)
            variants = directory / "native-mtp-variants.json"
            variants.write_text(json.dumps({"schema_version": "macprovider.native-mtp-variants.v1", "variants": [
                {"model_key": VARIANT, "donor_model_key": DONOR}]}, indent=2, sort_keys=True) + "\n")
            bank = directory / "bank.json"
            bank.write_text(json.dumps({"entries": [
                {"challenge_id": "native-mtp-selftest-donor-0001", "model_id": DONOR},
                {"challenge_id": self.CHALLENGE, "model_id": VARIANT}]}))
            source = directory / "job.log"
            source.write_text(source_text)
            bound = catalog_release.bind_native_mtp_self_check_record(model_key, source, variants, bank)
            return bound, json.loads(variants.read_text())

    def event(self, challenge=CHALLENGE, record=None):
        return (f"12:00:00 event=native_mtp_self_check_record challenge_id={challenge} "
                f"record={json.dumps(record or self.RECORD, sort_keys=True)}\n")

    def test_binds_the_variant_record_from_a_provider_log(self):
        bound, variants = self.bind("noise\n" + self.event("native-mtp-selftest-donor-0001") + self.event())
        self.assertEqual(bound, self.CHALLENGE)
        self.assertEqual(variants["variants"][0]["self_check_record"], self.RECORD)

    def test_binds_the_job_record_json(self):
        bound, variants = self.bind(json.dumps({"challenge_id": self.CHALLENGE, "record": self.RECORD}))
        self.assertEqual(variants["variants"][0]["self_check_record"], self.RECORD)

    def test_refusals(self):
        bad_tokens = dict(self.RECORD, expected_token_ids=[])
        extra = dict(self.RECORD, extra=1)
        cases = {
            "found 0": "no record here\n",
            "found 2": self.event() + self.event(),
            "non-empty list of token ids": self.event(record=bad_tokens),
            "self_check_record|bind-native-mtp-self-check-record": self.event(record=extra),
        }
        for message, text in cases.items():
            with self.subTest(message), self.assertRaisesRegex(catalog_release.CatalogError, message):
                self.bind(text)
        with self.assertRaisesRegex(catalog_release.CatalogError, "exactly one challenge"):
            self.bind(self.event(), model_key="example/unknown")

if __name__ == "__main__":
    unittest.main()
