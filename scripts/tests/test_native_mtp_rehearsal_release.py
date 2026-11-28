import base64
import hashlib
import json
import os
import stat
import subprocess
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

from scripts import native_mtp_admission_sidecar as sidecar_gen
from scripts import native_mtp_rehearsal_release as rehearsal
from scripts import read_swiftpm_pins


class RuntimeRevisionTests(unittest.TestCase):
    def test_runtime_revision_is_the_resolved_reviewed_fork_pin(self):
        self.assertEqual(rehearsal.runtime_revision(), read_swiftpm_pins.SPEC048_MLX_SWIFT_LM_REVISION)
        entry = rehearsal.tuple_input()["entry"]
        self.assertEqual(entry["runtime_revision"], read_swiftpm_pins.SPEC048_MLX_SWIFT_LM_REVISION)
        self.assertEqual(entry["ordinary_baseline"]["runtime_revision"], entry["runtime_revision"])

    def test_unreviewed_or_missing_pin_fails_closed(self):
        resolved = json.loads(rehearsal.PACKAGE_RESOLVED.read_text())
        for pin in resolved["pins"]:
            if pin["identity"] == "mlx-swift-lm":
                pin["state"]["revision"] = "0" * 40
        with tempfile.TemporaryDirectory() as directory:
            stale = Path(directory) / "Package.resolved"
            stale.write_text(json.dumps(resolved))
            missing = Path(directory) / "absent.resolved"
            for path in (stale, missing):
                with mock.patch.object(rehearsal, "PACKAGE_RESOLVED", path):
                    with self.assertRaises(SystemExit):
                        rehearsal.runtime_revision()


class InklingRehearsalReleaseTests(unittest.TestCase):
    def _sample_facts(self) -> dict:
        head_commit = subprocess.check_output(
            ["git", "rev-parse", "HEAD"],
            cwd=rehearsal.ROOT,
            text=True,
        ).strip()
        return {
            "source_commit": head_commit,
            "binary_sha256": "b" * 64,
            "live_executable_cdhash": "c" * 40,
            "provider_cli_version": "1.8.301-lab",
            "metallib_sha256": "d" * 64,
            "hardware_class": "apple-m5",
            "ram_bytes": 32 * 1024 * 1024 * 1024,
            "kernel_identifier": "paged_kv_v1_fp16",
            "cb_tokenizer_sha256": "e" * 64,
            "chat_template_sha256": "f" * 64,
        }

    def _sample_identity(self) -> dict:
        return {
            "schema": "macprovider.models-native-mtp-identity.v1",
            "embedded": True,
            "mtp_head_count": 3,
            "artifact_hash": rehearsal.INKLING_TARGET[2],
            "tokenizer_sha256": "1" * 64,
            "mtp_manifest_sha256": "2" * 64,
            "cb_tokenizer_sha256": "e" * 64,
            "chat_template_sha256": "f" * 64,
            "decode_path_digest": rehearsal.current_decode_path_digest(),
            "metallib_sha256": "d" * 64,
            "hardware_class": "apple-m5",
            "ram_bytes": 32 * 1024 * 1024 * 1024,
            "quantization": {
                "kind": "mlx_oq4e",
                "block_size_elements": 64,
                "representation_manifest_sha256": "3" * 64,
                "per_layer_exceptions": [],
                "unquantized_exceptions": [],
            },
        }

    def _write_fake_cli(self, directory: Path, identity: dict, expected_model_dir: Path) -> Path:
        cli = directory / "fake-macprovider-cli"
        cli.write_text(
            "#!/usr/bin/env python3\n"
            "import json, sys\n"
            f"expected = ['models', 'native-mtp-identity', '--model-dir', {str(expected_model_dir)!r}, '--json']\n"
            "assert sys.argv[1:] == expected, f'unexpected argv: {sys.argv[1:]!r} != {expected!r}'\n"
            f"print(json.dumps({identity!r}))\n",
            encoding="utf-8",
        )
        cli.chmod(cli.stat().st_mode | stat.S_IXUSR)
        return cli

    def test_release_refused_when_key_id_or_public_key_appears_in_trusted_keys(self):
        trusted = json.loads(rehearsal.TRUSTED_KEYS_PATH.read_text("utf-8"))
        trusted_id, trusted_meta = next(iter(trusted["keys"].items()))
        trusted_pub = trusted_meta["public_key_base64"]
        fresh_pub = base64.b64encode(b"\x42" * 32).decode("ascii")

        # Key id in trusted-keys.json must be refused.
        with self.assertRaisesRegex(ValueError, "must not appear"):
            rehearsal.validate_throwaway_key_not_in_trusted_keys(trusted_id, fresh_pub)

        # Public key in trusted-keys.json must be refused even with a fresh key id.
        with self.assertRaisesRegex(ValueError, "matches production key"):
            rehearsal.validate_throwaway_key_not_in_trusted_keys("inkling2-fresh-key-id", trusted_pub)

        # End-to-end build_inkling refuses a key_id that appears in trusted-keys.json.
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(ValueError, "must not appear"):
                rehearsal.build_inkling(
                    self._sample_facts(),
                    Path(tmp) / "work",
                    datetime(2026, 11, 28, 8, 0, 0, tzinfo=timezone.utc),
                    identity=self._sample_identity(),
                    key_id=trusted_id,
                )

    def test_inkling_rehearsal_invokes_cli_identity_and_builds_verified_release(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            model_dir = tmp_path / "inkling-snapshot"
            model_dir.mkdir()
            identity = self._sample_identity()
            fake_cli = self._write_fake_cli(tmp_path, identity, model_dir)
            work = tmp_path / "work"
            now = datetime(2026, 11, 28, 8, 0, 0, tzinfo=timezone.utc)

            summary = rehearsal.build_inkling(
                self._sample_facts(),
                work,
                now,
                cli_bin=fake_cli,
                model_dir=model_dir,
                prompt_token_ids=[10, 20, 30, 40],
            )

            self.assertEqual(summary["model_key"], rehearsal.INKLING_MODEL_KEY)
            self.assertEqual(summary["mtp_family_adapter"], rehearsal.INKLING_FAMILY_ADAPTER)
            self.assertGreater(summary["revocation_slots"], 0)
            # Throwaway key must never collide with trusted-keys.json.
            rehearsal.validate_throwaway_key_not_in_trusted_keys(
                summary["key_id"],
                summary["public_key_base64"],
            )

            catalog_dir = work / "catalog"
            sidecar = json.loads((catalog_dir / "native-mtp-admission.json").read_text("utf-8"))
            self.assertEqual(len(sidecar["entries"]), 1)
            entry = sidecar["entries"][0]
            self.assertEqual(entry["model_key"], rehearsal.INKLING_MODEL_KEY)
            self.assertEqual(entry["mtp_family_adapter"], rehearsal.INKLING_FAMILY_ADAPTER)
            self.assertEqual(entry["artifact_hash"], rehearsal.INKLING_TARGET[2])
            self.assertEqual(entry["decode_path_digest"], rehearsal.current_decode_path_digest())
            self.assertEqual(entry["tokenizer_sha256"], identity["tokenizer_sha256"])
            self.assertEqual(entry["mtp_manifest_sha256"], identity["mtp_manifest_sha256"])
            self.assertEqual(
                entry["quantization"]["representation_manifest_sha256"],
                identity["quantization"]["representation_manifest_sha256"],
            )

            proj = json.loads((catalog_dir / "native-mtp-artifact-manifest.json").read_text("utf-8"))
            self.assertEqual(proj["schema_version"], sidecar_gen.PROJECTION_V1_SCHEMA)
            self.assertEqual(proj["artifacts"]["mtp"], proj["artifacts"]["target"])
            self.assertTrue(proj["artifacts"]["manifest"]["path"].endswith("/config.json"))
            self.assertTrue(proj["artifacts"]["tokenizer"]["path"].endswith("/tokenizer.json"))

            bank = json.loads((catalog_dir / "native-mtp-selftest-bank.json").read_text("utf-8"))
            self.assertEqual(len(bank["entries"]), 1)
            self.assertEqual(bank["entries"][0]["prompt_token_ids"], [10, 20, 30, 40])
            self.assertEqual(bank["entries"][0]["model_id"], rehearsal.INKLING_MODEL_KEY)

            cb = json.loads((catalog_dir / "continuous-batching-policy.json").read_text("utf-8"))
            self.assertEqual(cb["entries"][0]["model_key"], rehearsal.INKLING_MODEL_KEY)
            self.assertEqual(cb["entries"][0]["cache_class"], "mixed")

    def test_inkling_production_inputs_share_builder_and_build_valid_multi_entry_sidecar(self):
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = Path(tmp) / "prod-inputs"
            now = datetime(2026, 11, 28, 8, 0, 0, tzinfo=timezone.utc)
            evidence = {
                key: hashlib.sha256(f"inkling-prod-{key}".encode()).hexdigest()
                for key in (
                    "benchmark_policy_sha256",
                    "correctness_evidence_sha256",
                    "quality_evidence_sha256",
                    "state_rollback_evidence_sha256",
                    "batch_evidence_sha256",
                    "security_negative_evidence_sha256",
                    "performance_evidence_sha256",
                    "fit_evidence_sha256",
                )
            }
            summary = rehearsal.build_inkling_production_inputs(
                self._sample_facts(),
                out_dir,
                now,
                identity=self._sample_identity(),
                evidence_digests=evidence,
            )

            self.assertFalse(summary["pending_evidence_placeholders"])
            self.assertIsNotNone(summary["sidecar_identity"])
            tuples = json.loads((out_dir / "native-mtp-admission-tuple.json").read_text("utf-8"))
            keys = [t["entry"]["model_key"] for t in tuples]
            self.assertIn(rehearsal.INKLING_MODEL_KEY, keys)
            self.assertGreater(len(tuples), 1, "must preserve committed production tuples")

            proj = json.loads((out_dir / "native-mtp-artifact-manifest.json").read_text("utf-8"))
            self.assertEqual(proj["schema_version"], sidecar_gen.PROJECTION_V2_SCHEMA)
            self.assertIn(rehearsal.INKLING_MODEL_KEY, proj["models"])
            self.assertEqual(
                proj["models"][rehearsal.INKLING_MODEL_KEY]["mtp"],
                proj["models"][rehearsal.INKLING_MODEL_KEY]["target"],
            )

            bank = json.loads((out_dir / "native-mtp-selftest-bank.json").read_text("utf-8"))
            self.assertIn(rehearsal.INKLING_MODEL_KEY, [e["model_id"] for e in bank["entries"]])

            cb_src = json.loads((out_dir / "continuous-batching-policy-source.json").read_text("utf-8"))
            self.assertIn(rehearsal.INKLING_MODEL_KEY, [e["model_key"] for e in cb_src["entries"]])


if __name__ == "__main__":
    unittest.main()
