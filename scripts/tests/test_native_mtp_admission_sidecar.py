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
    admission_tuple_sha256,
    build,
    identity,
    main,
)

ROOT = Path(__file__).resolve().parents[2]
TUPLE = ROOT / "docs/research/spec048-r015/evidence-2026-10-02-a3b-formal/admission-tuple-input.json"
GOLDEN = Path(__file__).resolve().parent / "fixtures/native_mtp_admission_golden.json"
# Shared with NativeMTPAdmissionSidecarTests.testGoldenSidecarTupleIdentityMatchesPythonGenerator.
GOLDEN_TUPLE_SHA256 = "fd54231d7ae6d1caf1e96c4e54a2c8217fad600b6493cea8c88dc1d9dd058182"


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


class NativeMTPAdmissionSidecarTests(unittest.TestCase):
    def setUp(self):
        self.tuple = json.loads(TUPLE.read_text("utf-8"))

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
        bad_cdhash = release_input()
        bad_cdhash["entry"]["live_executable_cdhash"] = "D" * 40
        with self.assertRaises(SidecarError):
            build(self.tuple, bad_cdhash)

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
            out = tmp / "native-mtp-admission.json"
            self.assertEqual(main(["build", "--tuple", str(TUPLE), "--release", str(tmp / "release.json"), "--out", str(out)]), 0)
            self.assertEqual(out.read_bytes(), build(self.tuple, release_input()))
            self.assertEqual(main(["identity", "--sidecar", str(out)]), 0)


if __name__ == "__main__":
    unittest.main()
