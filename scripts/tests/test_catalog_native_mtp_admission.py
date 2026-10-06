"""SPEC-023 §12.5 (R024) native-MTP admission as a ledger-bound release feed.

Drives the real `generate` -> sign -> `generate` -> `verify` flow of
`scripts/catalog-release.py` on the hermetic release copy from
`test_catalog_artifact_feed.py`, then `verify-directory` on the staged
release: ledger v4, the seven-feed set, signer equality, manifest and bank
binding, the challenge-bank signature, and the no-downgrade rule.
"""

from __future__ import annotations

import contextlib
import copy
import json
import pathlib
import shutil
import tempfile
import unittest

from scripts.tests import test_catalog_artifact_feed as artifact_tests

catalog_release = artifact_tests.catalog_release
HermeticRelease = artifact_tests.HermeticRelease
ROOT = artifact_tests.ROOT
FORMAL_TUPLE = ROOT / "docs/research/spec048-r015/evidence-2026-10-02-a3b-formal/admission-tuple-input.json"
NATIVE_RELEASE_ID = "published-2026-10-06-native-mtp-v1"


def tuple_input() -> dict:
    value = json.loads(FORMAL_TUPLE.read_text())
    entry = value["entry"]
    for index, key in enumerate(sorted(k for k, v in entry.items() if v == "0" * 64)):
        entry[key] = f"{index + 1:x}" * 64
    for key in ("provider_revision",):
        entry.pop(key, None)
        entry["ordinary_baseline"].pop(key, None)
    return value


def release_input(key_id: str, manifest: bytes, bank: bytes, release_id: str = NATIVE_RELEASE_ID) -> dict:
    return {
        "schema_version": "macprovider.native-mtp-admission-release-input.v1",
        "release_id": release_id,
        "issued_at": "2026-10-06T00:00:00Z",
        "expires_at": "2026-12-25T00:00:00Z",
        "signer_key_id": key_id,
        "challenge_bank_signer_key_id": key_id,
        "revocation_signer_key_id": key_id,
        "entry": {
            "artifact_manifest_sha256": catalog_release.sha256(manifest),
            "provider_revision": "a" * 40,
            "source_commit": "a" * 40,
            "reproducible_build_sha256": "b" * 64,
            "live_executable_cdhash": "c" * 40,
            "challenge_bank_sha256": catalog_release.sha256(bank),
        },
    }


class NativeMTPAdmissionReleaseTest(unittest.TestCase):
    MANIFEST = b'{"schema_version":"macprovider.native-mtp-artifact-manifest.v1"}'
    BANK = b'{"schema_version":"macprovider.native-mtp-challenge-bank.v1","challenges":[]}'

    @classmethod
    def setUpClass(cls):
        cls.openssl = catalog_release.openssl_executable()

    @contextlib.contextmanager
    def activated(self):
        with tempfile.TemporaryDirectory() as raw:
            with HermeticRelease(pathlib.Path(raw) / "repo", self.openssl) as harness:
                saved = {
                    name: getattr(catalog_release, name)
                    for name in ("NATIVE_MTP_TUPLE_INPUT_PATH", "NATIVE_MTP_RELEASE_INPUT_PATH")
                }
                catalog_release.NATIVE_MTP_TUPLE_INPUT_PATH = harness.catalog / "native-mtp-admission-tuple.json"
                catalog_release.NATIVE_MTP_RELEASE_INPUT_PATH = harness.catalog / "native-mtp-admission-release.json"
                try:
                    harness.measure_sizes()
                    harness.bump("published-2026-09-26-activation-v1", "2026-09-26T00:00:00Z")
                    harness.cut(activate_artifact_feed=True)
                    yield harness
                finally:
                    for name, value in saved.items():
                        setattr(catalog_release, name, value)

    def write_native_inputs(self, harness, release_id: str = NATIVE_RELEASE_ID, bank: bytes | None = None) -> None:
        bank = self.BANK if bank is None else bank
        (harness.catalog / "native-mtp-artifact-manifest.json").write_bytes(self.MANIFEST)
        (harness.catalog / "native-mtp-selftest-bank.json").write_bytes(bank)
        (harness.catalog / "native-mtp-admission-tuple.json").write_text(json.dumps(tuple_input(), indent=2))
        (harness.catalog / "native-mtp-admission-release.json").write_text(
            json.dumps(release_input(harness.KEY_ID, self.MANIFEST, bank, release_id), indent=2)
        )

    def sign_native(self, harness) -> None:
        for name in ("native-mtp-admission.json", "native-mtp-selftest-bank.json"):
            path = harness.static / name
            if path.exists():
                harness.sign_into(harness.static, name, path.read_bytes())

    def cut_native(self, harness, previous: pathlib.Path, release_id: str = NATIVE_RELEASE_ID) -> None:
        harness.bump(release_id, "2026-10-06T00:00:00Z")
        catalog_release.generate(harness.KEY_ID, previous_release_dir=previous)
        harness.sign()
        self.sign_native(harness)
        catalog_release.generate(harness.KEY_ID, previous_release_dir=previous)
        catalog_release.verify()

    def stage_native(self, harness, destination: pathlib.Path) -> pathlib.Path:
        harness.stage(destination)
        for name in (
            "native-mtp-admission.json", "native-mtp-admission.json.sig",
            "native-mtp-artifact-manifest.json",
            "native-mtp-selftest-bank.json", "native-mtp-selftest-bank.json.sig",
        ):
            shutil.copy2(harness.static / name, destination / name)
        return destination

    def test_native_release_binds_the_sidecar_in_ledger_v4_and_verifies_staged(self):
        with self.activated() as harness:
            previous = harness.stage(harness.root / "previous")
            self.write_native_inputs(harness)
            self.cut_native(harness, previous)

            manifest = harness.manifest()
            self.assertEqual(set(manifest["feeds"]), catalog_release.NATIVE_MTP_BOUND_LEDGER_FEEDS)
            record = manifest["feeds"]["native-mtp-admission.json"]
            self.assertEqual(record["version"], NATIVE_RELEASE_ID)
            self.assertEqual(record["signer_key_id"], harness.KEY_ID)
            ledger = harness.ledger()
            self.assertEqual(ledger["schema_version"], catalog_release.LEDGER_SCHEMA_V4)
            row = ledger["releases"][NATIVE_RELEASE_ID]
            self.assertEqual(row["native_mtp_admission_sha256"], record["sha256"])
            sidecar = (harness.static / "native-mtp-admission.json").read_bytes()
            self.assertEqual(catalog_release.sha256(sidecar), record["sha256"])
            body = json.loads(sidecar)
            self.assertEqual(body["entries"][0]["challenge_bank_sha256"], catalog_release.sha256(self.BANK))

            staged = self.stage_native(harness, harness.root / "staged")
            catalog_release.verify_directory(staged, allow_expired_tier2=True)

            # A staged bank re-signed by the alternate trusted key is not the
            # sidecar's pinned challenge-bank signer.
            tampered = self.stage_native(harness, harness.root / "tampered-bank-signer")
            harness.sign_into(tampered, "native-mtp-selftest-bank.json", self.BANK, key_id=harness.ALT_KEY_ID)
            with self.assertRaisesRegex(catalog_release.CatalogError, "challenge_bank_signer_key_id"):
                catalog_release.verify_directory(tampered, allow_expired_tier2=True)

            # A swapped manifest no longer matches the digest every entry binds.
            swapped = self.stage_native(harness, harness.root / "swapped-manifest")
            (swapped / "native-mtp-artifact-manifest.json").write_bytes(b'{"swapped":true}')
            with self.assertRaisesRegex(catalog_release.CatalogError, "artifact_manifest_sha256"):
                catalog_release.verify_directory(swapped, allow_expired_tier2=True)

    def test_release_input_must_name_this_release_and_bind_the_committed_bank(self):
        with self.activated() as harness:
            previous = harness.stage(harness.root / "previous")
            self.write_native_inputs(harness, release_id="published-2026-10-05-other-v1")
            harness.bump(NATIVE_RELEASE_ID, "2026-10-06T00:00:00Z")
            with self.assertRaisesRegex(catalog_release.CatalogError, "is not this release"):
                catalog_release.generate(harness.KEY_ID, previous_release_dir=previous)
            self.write_native_inputs(harness)
            (harness.catalog / "native-mtp-selftest-bank.json").write_bytes(b'{"drift":true}')
            with self.assertRaisesRegex(catalog_release.CatalogError, "challenge_bank_sha256"):
                catalog_release.generate(harness.KEY_ID, previous_release_dir=previous)
            (harness.catalog / "native-mtp-admission-release.json").unlink()
            with self.assertRaisesRegex(catalog_release.CatalogError, "must be committed together"):
                catalog_release.generate(harness.KEY_ID, previous_release_dir=previous)

    def test_a_later_release_cannot_drop_the_native_mtp_sidecar(self):
        with self.activated() as harness:
            previous = harness.stage(harness.root / "previous")
            self.write_native_inputs(harness)
            self.cut_native(harness, previous)
            native_previous = self.stage_native(harness, harness.root / "native-previous")
            for name in ("native-mtp-admission-tuple.json", "native-mtp-admission-release.json",
                         "native-mtp-admission.json"):
                (harness.catalog / name).unlink()
            harness.bump("published-2026-10-13-renewal-v1", "2026-10-13T00:00:00Z")
            with self.assertRaisesRegex(catalog_release.CatalogError, "native-mtp-admission.json"):
                catalog_release.generate(harness.KEY_ID, previous_release_dir=native_previous)

    def test_renewal_rebinds_the_sidecar_and_continuity_allows_only_that(self):
        with self.activated() as harness:
            previous = harness.stage(harness.root / "previous")
            self.write_native_inputs(harness)
            self.cut_native(harness, previous)
            live = self.stage_native(harness, harness.root / "live")
            renewal_id = "published-2026-10-13-renewal-v1"
            catalog_release.restamp(renewal_id, "2026-10-13T00:00:00Z")
            release_input = json.loads((harness.catalog / "native-mtp-admission-release.json").read_text())
            self.assertEqual(release_input["release_id"], renewal_id)
            self.assertEqual(release_input["issued_at"], "2026-10-13T00:00:00Z")
            self.assertEqual(release_input["expires_at"], "2027-01-10T00:00:00Z")
            catalog_release.generate(harness.KEY_ID, previous_release_dir=live)
            harness.sign()
            self.sign_native(harness)
            catalog_release.generate(harness.KEY_ID, previous_release_dir=live)
            catalog_release.verify()
            renewed = self.stage_native(harness, harness.root / "renewed")
            self.assertEqual(catalog_release.feed_continuity_drift(renewed, live), [])
            self.assertEqual(json.loads((renewed / "native-mtp-admission.json").read_bytes())["release_id"], renewal_id)

            changed = json.loads((renewed / "native-mtp-admission.json").read_bytes())
            changed["entries"][0]["throughput_delta_ppm"] += 1
            (renewed / "native-mtp-admission.json").write_bytes(catalog_release.canonical_sorted_bytes(changed))
            self.assertIn("native-mtp-admission.json", catalog_release.feed_continuity_drift(renewed, live))
            (renewed / "native-mtp-admission.json").unlink()
            self.assertIn("native-mtp-admission.json", catalog_release.feed_continuity_drift(renewed, live))

    def test_ledger_v4_rows_are_closed_and_v4_is_required(self):
        with self.activated() as harness:
            previous = harness.stage(harness.root / "previous")
            self.write_native_inputs(harness)
            self.cut_native(harness, previous)
            ledger = harness.ledger()
            v3 = copy.deepcopy(ledger)
            v3["schema_version"] = catalog_release.LEDGER_SCHEMA_V3
            with self.assertRaisesRegex(catalog_release.CatalogError, "must be .*v4"):
                catalog_release.validate_release_ledger(json.dumps(v3).encode())
            missing = copy.deepcopy(ledger)
            del missing["releases"][NATIVE_RELEASE_ID]["native_mtp_admission_sha256"]
            with self.assertRaises(catalog_release.CatalogError):
                catalog_release.validate_release_ledger(json.dumps(missing).encode())
            wrong = copy.deepcopy(ledger)
            wrong["releases"][NATIVE_RELEASE_ID]["native_mtp_admission_sha256"] = "f" * 64
            with self.assertRaisesRegex(catalog_release.CatalogError, "does not equal its feed record"):
                catalog_release.validate_release_ledger(json.dumps(wrong).encode())


if __name__ == "__main__":
    unittest.main()
