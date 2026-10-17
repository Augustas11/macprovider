import copy
import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from scripts.native_mtp_admission_sidecar import (
    RELEASE_INPUT_SCHEMA,
    TUPLE_INPUT_SCHEMA,
    SidecarError,
    PROJECTION_V1_SCHEMA,
    PROJECTION_V2_SCHEMA,
    admission_tuple_sha256,
    build,
    build_projection,
    canonical_bytes,
    identity,
    main,
    read_projection,
)

ROOT = Path(__file__).resolve().parents[2]
TUPLE = ROOT / "docs/research/spec048-r015/evidence-2026-10-02-a3b-formal/admission-tuple-input.json"
GOLDEN = Path(__file__).resolve().parent / "fixtures/native_mtp_admission_golden.json"
# Shared with NativeMTPAdmissionSidecarTests.testGoldenSidecarTupleIdentityMatchesPythonGenerator.
GOLDEN_TUPLE_SHA256 = "eac0736b406e032013a6fd7893a306be1b57b6a8a374e655c3ce209770d3d0b4"
# SHA-256 of build(resolved_tuple(), release_input()) from the single-entry
# generator before multi-entry support (origin/main 81961a00d).
SINGLE_ENTRY_SIDECAR_SHA256 = "49881875ea6c053e99f5748d853b5e4d566b330f955cfdd58e1894ed8cbb5a2b"
PROJECTION = ROOT / "phase3-binary/catalog/autotune/native-mtp-artifact-manifest.json"
QWEN_KEY = "qwen/qwen3.6-35b-a3b"
GLM_KEY = "zai-org/glm-5.3-flash"


def release_input():
    return {
        "schema_version": RELEASE_INPUT_SCHEMA,
        "release_id": "1.8.300",
        "issued_at": "2026-10-02T00:00:00Z",
        "expires_at": "2026-12-31T00:00:00Z",
        "signer_key_id": "streamvc-autotune-static-v4",
        "challenge_bank_signer_key_id": "streamvc-autotune-static-v4",
        "revocation_signer_key_id": "streamvc-autotune-static-v4",
        "entry": {
            "artifact_manifest_sha256": "a" * 64,
            "provider_revision": "b" * 40,
            "source_commit": "b" * 40,
            "reproducible_build_sha256": "c" * 64,
            "live_executable_cdhash": "d" * 40,
            "challenge_bank_sha256": "e" * 64,
        },
    }


EVIDENCE_FIELDS = (
    "correctness_evidence_sha256",
    "quality_evidence_sha256",
    "state_rollback_evidence_sha256",
    "batch_evidence_sha256",
    "security_negative_evidence_sha256",
)


def resolved_tuple():
    """The committed tuple with its pending-evidence placeholders resolved to
    stand-in digests, as a release would after the journey passes."""
    value = json.loads(TUPLE.read_text("utf-8"))
    for index, key in enumerate(EVIDENCE_FIELDS):
        value["entry"][key] = f"{index + 1:x}" * 64
    return value


def glm_tuple():
    """A stand-in GLM-5.3-Flash tuple (SPEC-048 0.1.34 glm5_next_mtp_v1):
    embedded MTP, depth 1, greedy only. Digests are placeholders."""
    value = resolved_tuple()
    entry = value["entry"]
    entry["model_key"] = GLM_KEY
    entry["artifact_id"] = "mlx-oq4e-mtp"
    entry["artifact_hash"] = "7" * 64
    entry["ordinary_baseline"]["artifact_hash"] = "7" * 64
    entry["tokenizer_sha256"] = "8" * 64
    entry["mtp_manifest_sha256"] = "9" * 64
    entry["mtp_family_adapter"] = "glm5_next_mtp_v1"
    entry["request_feature_profile"] = "native_mtp_greedy_text_v1"
    entry["qualified_slots"] = 4
    entry["ordinary_baseline"]["qualified_slots"] = 4
    entry["quantization"]["per_layer_exceptions"] = [
        "target/language_model.lm_head",
        "target/language_model.mtp.0.block.self_attn.embed_q",
        "target/language_model.mtp.0.block.self_attn.q_a_proj",
    ]
    entry["quantization"]["representation_manifest_sha256"] = "6" * 64
    return value


def projection_artifacts(tag):
    return {
        name: {"path": f"{tag}/{name}", "sha256": f"{index + 1:x}" * 64}
        for index, name in enumerate(("manifest", "mtp", "target", "tokenizer"))
    }


class NativeMTPAdmissionSidecarTests(unittest.TestCase):
    def setUp(self):
        self.tuple = resolved_tuple()

    def test_committed_tuple_with_pending_evidence_is_not_buildable(self):
        committed = json.loads(TUPLE.read_text("utf-8"))
        with self.assertRaisesRegex(SidecarError, "pending-evidence placeholder"):
            build(committed, release_input())

    def test_committed_tuple_builds_canonical_closed_sidecar(self):
        data = build(self.tuple, release_input())
        body = json.loads(data)
        self.assertEqual(data, json.dumps(body, separators=(",", ":"), sort_keys=True).encode())
        entry = body["entries"][0]
        self.assertEqual(entry["max_native_active_rows"], 1)
        self.assertEqual(entry["max_prompt_tokens"], 4096)
        self.assertEqual(entry["qualified_slots"], 8)
        self.assertEqual(entry["artifact_hash"], "3fed776d41b6883888541d19f71a3866acc3bc6e628402066b67e5ac0a676ff1")
        self.assertEqual(entry["ordinary_baseline"]["provider_revision"], "b" * 40)

    def test_identity_is_domain_separated_over_the_full_entry(self):
        data = build(self.tuple, release_input())
        ident = identity(data)
        self.assertEqual(ident["sidecar_sha256"], hashlib.sha256(data).hexdigest())
        body = json.loads(data)
        changed = copy.deepcopy(body["entries"][0])
        changed["max_prompt_tokens"] = 8192
        self.assertNotEqual(
            admission_tuple_sha256(body["release_id"], ident["sidecar_sha256"], changed),
            ident["native_mtp_admission_tuple_sha256"][0],
        )

    def test_release_owned_fields_cannot_come_from_the_tuple(self):
        bad = copy.deepcopy(self.tuple)
        bad["entry"]["live_executable_cdhash"] = "d" * 40
        with self.assertRaisesRegex(SidecarError, "release-owned"):
            build(bad, release_input())

    def test_closed_schema_and_bounds_fail_closed(self):
        cases = {
            "max_prompt_tokens": 0,
            "max_native_active_rows": 9,
            "request_feature_profile": "native_mtp_sampled_text_v2",
            "complete_window_bytes_by_depth": [2, 1],
            "increase_threshold_ppm": 400000,
            "cache_state_classes": ["stageable_rewindable"],
        }
        for key, value in cases.items():
            with self.subTest(key=key):
                bad = copy.deepcopy(self.tuple)
                bad["entry"][key] = value
                with self.assertRaises(SidecarError):
                    build(bad, release_input())
        extra = copy.deepcopy(self.tuple)
        extra["entry"]["unexpected"] = 1
        with self.assertRaisesRegex(SidecarError, "extra"):
            build(extra, release_input())
        missing = copy.deepcopy(self.tuple)
        del missing["entry"]["max_prompt_tokens"]
        with self.assertRaisesRegex(SidecarError, "missing"):
            build(missing, release_input())
        window = release_input()
        window["expires_at"] = "2027-01-01T00:00:01Z"
        with self.assertRaisesRegex(SidecarError, "90 days"):
            build(self.tuple, window)
        for key, value in (("source_commit", "b" * 64), ("artifact_id", "Primary_1")):
            bad_field = copy.deepcopy(self.tuple) if key == "artifact_id" else self.tuple
            bad_release = release_input()
            if key == "artifact_id":
                bad_field["entry"][key] = value
            else:
                bad_release["entry"][key] = value
            with self.assertRaises(SidecarError, msg=key):
                build(bad_field, bad_release)
        spaced = release_input()
        spaced["signer_key_id"] = "static key"
        with self.assertRaises(SidecarError):
            build(self.tuple, spaced)
        bad_cdhash = release_input()
        bad_cdhash["entry"]["live_executable_cdhash"] = "D" * 40
        with self.assertRaises(SidecarError):
            build(self.tuple, bad_cdhash)

    def test_proposal_depth_stays_inside_the_fused_row_envelope(self):
        # SPEC-023-R024 / SPEC-048 0.1.23: a verify row carries depth + 1
        # tokens and must stay within seven tokens per row.
        deep = copy.deepcopy(self.tuple)
        deep["entry"]["proposal_depth"] = 7
        deep["entry"]["complete_window_bytes_by_depth"] = list(range(1, 9))
        with self.assertRaisesRegex(SidecarError, "proposal_depth"):
            build(deep, release_input())
        edge = copy.deepcopy(self.tuple)
        edge["entry"]["proposal_depth"] = 6
        edge["entry"]["complete_window_bytes_by_depth"] = list(range(1, 8))
        build(edge, release_input())

    def test_identity_strings_are_ascii_and_duplicate_keys_fail(self):
        bad = copy.deepcopy(self.tuple)
        bad["entry"]["mtp_family_adapter"] = "qwen3_5_mtp_v1\u00e9"
        with self.assertRaisesRegex(SidecarError, "printable ASCII"):
            build(bad, release_input())
        bad_class = copy.deepcopy(self.tuple)
        bad_class["entry"]["hardware_class"] = "apple_m3.ultra"
        with self.assertRaises(SidecarError):
            build(bad_class, release_input())
        data = build(self.tuple, release_input())
        duplicated = data.replace(b'"schema_version":', b'"schema_version":"x","schema_version":', 1)
        with self.assertRaisesRegex(SidecarError, "duplicate JSON key"):
            identity(duplicated)

    def test_tuple_schema_is_pinned(self):
        bad = copy.deepcopy(self.tuple)
        bad["schema_version"] = "other"
        with self.assertRaises(SidecarError):
            build(bad, release_input())
        self.assertEqual(self.tuple["schema_version"], TUPLE_INPUT_SCHEMA)

    def test_golden_identity_matches_swift_consumer(self):
        data = GOLDEN.read_bytes()
        self.assertEqual(identity(data)["native_mtp_admission_tuple_sha256"], [GOLDEN_TUPLE_SHA256])

    def test_cli_build_writes_bytes_and_prints_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "release.json").write_text(json.dumps(release_input()), "utf-8")
            (tmp / "tuple.json").write_text(json.dumps(self.tuple), "utf-8")
            out = tmp / "native-mtp-admission.json"
            self.assertEqual(main(["build", "--tuple", str(tmp / "tuple.json"), "--release", str(tmp / "release.json"), "--out", str(out)]), 0)
            self.assertEqual(out.read_bytes(), build(self.tuple, release_input()))
            self.assertEqual(main(["identity", "--sidecar", str(out)]), 0)


class NativeMTPAdmissionMultiEntryTests(unittest.TestCase):
    """SPEC-048 0.1.34: one sidecar carries every admitted model tuple."""

    def setUp(self):
        self.qwen = resolved_tuple()
        self.glm = glm_tuple()

    def test_single_entry_bytes_are_unchanged(self):
        single = build(self.qwen, release_input())
        self.assertEqual(hashlib.sha256(single).hexdigest(), SINGLE_ENTRY_SIDECAR_SHA256)
        self.assertEqual(build([self.qwen], release_input()), single)

    def test_merged_entries_are_sorted_and_leave_the_qwen_entry_byte_identical(self):
        single = json.loads(build(self.qwen, release_input()))["entries"][0]
        merged = build([self.qwen, self.glm], release_input())
        self.assertEqual(build([self.glm, self.qwen], release_input()), merged)
        body = json.loads(merged)
        self.assertEqual([entry["model_key"] for entry in body["entries"]], [QWEN_KEY, GLM_KEY])
        qwen_entry = body["entries"][0]
        self.assertEqual(canonical_bytes(qwen_entry), canonical_bytes(single))
        self.assertEqual(body["entries"][1]["mtp_family_adapter"], "glm5_next_mtp_v1")
        self.assertEqual(body["entries"][1]["ordinary_baseline"]["provider_revision"], "b" * 40)
        # Each entry's tuple identity is still computed over its own unchanged
        # entry; it differs from the single-entry sidecar's only through the
        # sidecar_sha256 SPEC-023 §12.5 binds into the identity.
        ident = identity(merged)
        self.assertEqual(
            ident["native_mtp_admission_tuple_sha256"][0],
            admission_tuple_sha256(body["release_id"], ident["sidecar_sha256"], single),
        )
        self.assertNotEqual(
            ident["native_mtp_admission_tuple_sha256"][0],
            identity(build(self.qwen, release_input()))["native_mtp_admission_tuple_sha256"][0],
        )

    def test_glm_tuple_signs_only_the_greedy_profile(self):
        # SPEC-048 MTP-2: the glm5_next drafter proposes greedily only.
        body = json.loads(build([self.qwen, self.glm], release_input()))
        self.assertEqual(body["entries"][1]["request_feature_profile"], "native_mtp_greedy_text_v1")
        sampled = copy.deepcopy(self.glm)
        sampled["entry"]["request_feature_profile"] = "native_mtp_sampled_text_v1"
        with self.assertRaisesRegex(SidecarError, "greedy only"):
            build([self.qwen, sampled], release_input())
        # Qwen may still sign the sampled profile.
        self.assertEqual(body["entries"][0]["request_feature_profile"], self.qwen["entry"]["request_feature_profile"])

    def test_duplicate_or_empty_tuple_lists_fail_closed(self):
        with self.assertRaisesRegex(SidecarError, "sorted by the SPEC-023 sort key"):
            build([self.qwen, copy.deepcopy(self.qwen)], release_input())
        with self.assertRaisesRegex(SidecarError, "at least one"):
            build([], release_input())
        bad = copy.deepcopy(self.glm)
        bad["entry"]["proposal_depth"] = 0
        with self.assertRaisesRegex(SidecarError, r"\$tuple\[1\]\.entry\.proposal_depth"):
            build([self.qwen, bad], release_input())
        owned = copy.deepcopy(self.glm)
        owned["entry"]["source_commit"] = "b" * 40
        with self.assertRaisesRegex(SidecarError, r"\$tuple\[1\]\.entry: release-owned"):
            build([self.qwen, owned], release_input())

    def test_exception_arrays_hold_up_to_1024_entries(self):
        # SPEC-023 v0.22.25: GLM-5.3-Flash records 554 per-module overrides.
        names = sorted(f"target/language_model.model.layers.{i}.mlp.switch_mlp.down_proj" for i in range(1024))
        wide = copy.deepcopy(self.glm)
        wide["entry"]["quantization"]["per_layer_exceptions"] = names
        body = json.loads(build([self.qwen, wide], release_input()))
        self.assertEqual(len(body["entries"][1]["quantization"]["per_layer_exceptions"]), 1024)
        wide["entry"]["quantization"]["per_layer_exceptions"] = sorted(names + ["target/language_model.lm_head"])
        with self.assertRaisesRegex(SidecarError, "at most 1024"):
            build([self.qwen, wide], release_input())

    def test_cli_accepts_repeated_and_list_tuple_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "release.json").write_text(json.dumps(release_input()), "utf-8")
            (tmp / "qwen.json").write_text(json.dumps(self.qwen), "utf-8")
            (tmp / "glm.json").write_text(json.dumps(self.glm), "utf-8")
            (tmp / "both.json").write_text(json.dumps([self.glm, self.qwen]), "utf-8")
            expected = build([self.qwen, self.glm], release_input())
            for args in (["--tuple", str(tmp / "qwen.json"), "--tuple", str(tmp / "glm.json")],
                         ["--tuple", str(tmp / "both.json")]):
                out = tmp / "out.json"
                self.assertEqual(main(["build", *args, "--release", str(tmp / "release.json"), "--out", str(out)]), 0)
                self.assertEqual(out.read_bytes(), expected)


class NativeMTPProjectionManifestTests(unittest.TestCase):
    """SPEC-048 0.1.34 projection manifest: v1 for one model, v2 keyed by model_key."""

    def test_single_model_projection_is_the_committed_v1_bytes(self):
        committed = PROJECTION.read_bytes()
        artifacts = json.loads(committed)["artifacts"]
        self.assertEqual(build_projection({QWEN_KEY: artifacts}), committed)
        self.assertEqual(read_projection(committed, [QWEN_KEY], QWEN_KEY), artifacts)

    def test_multi_model_projection_is_v2_keyed_by_model_key(self):
        models = {QWEN_KEY: projection_artifacts("qwen"), GLM_KEY: projection_artifacts("glm")}
        data = build_projection(models)
        body = json.loads(data)
        self.assertEqual(body["schema_version"], PROJECTION_V2_SCHEMA)
        self.assertEqual(sorted(body["models"]), [QWEN_KEY, GLM_KEY])
        self.assertEqual(data, canonical_bytes(body))
        for key in models:
            self.assertEqual(read_projection(data, [QWEN_KEY, GLM_KEY, QWEN_KEY], key), models[key])

    def test_projection_reader_fails_closed(self):
        v1 = build_projection({QWEN_KEY: projection_artifacts("qwen")})
        self.assertEqual(json.loads(v1)["schema_version"], PROJECTION_V1_SCHEMA)
        with self.assertRaisesRegex(SidecarError, "exactly one model_key"):
            read_projection(v1, [QWEN_KEY, GLM_KEY], QWEN_KEY)
        v2 = build_projection({QWEN_KEY: projection_artifacts("qwen"), GLM_KEY: projection_artifacts("glm")})
        with self.assertRaisesRegex(SidecarError, "exactly the sidecar's model keys"):
            read_projection(v2, [QWEN_KEY], QWEN_KEY)
        with self.assertRaisesRegex(SidecarError, "not an entry"):
            read_projection(v2, [QWEN_KEY, GLM_KEY], "other/model")
        with self.assertRaisesRegex(SidecarError, "schema_version"):
            read_projection(b'{"schema_version":"other"}', [QWEN_KEY], QWEN_KEY)
        extra = projection_artifacts("glm")
        extra["vision"] = {"path": "x", "sha256": "1" * 64}
        with self.assertRaisesRegex(SidecarError, "extra"):
            build_projection({GLM_KEY: extra})
        escape = projection_artifacts("glm")
        escape["mtp"]["path"] = "../escape"
        with self.assertRaisesRegex(SidecarError, "relative path"):
            build_projection({GLM_KEY: escape})
        with self.assertRaisesRegex(SidecarError, "1..256"):
            build_projection({})


if __name__ == "__main__":
    unittest.main()
