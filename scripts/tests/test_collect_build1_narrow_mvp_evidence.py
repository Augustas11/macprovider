from __future__ import annotations

import copy
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from scripts.tests.test_build1_narrow_mvp_evidence import valid_evidence


REPO_ROOT = Path(__file__).resolve().parents[2]
COLLECTOR_SCRIPT = REPO_ROOT / "scripts" / "collect-build1-narrow-mvp-evidence.py"
VALIDATOR_SCRIPT = REPO_ROOT / "scripts" / "validate-build1-narrow-mvp-evidence.py"


def load_module(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


collector = load_module(COLLECTOR_SCRIPT, "build1_narrow_mvp_collector")
validator = load_module(VALIDATOR_SCRIPT, "build1_narrow_mvp_validator_for_collector_tests")


def write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def source_event_id(key: str, manifest: dict) -> str:
    if key in {"physical_run_log", "status_before", "status_after"}:
        return manifest["provider"]["provider_id"]
    return manifest["request"]["request_id"]


def source_capture_envelope(key: str, payload: dict, manifest: dict) -> dict:
    return {
        "schema_version": collector.SOURCE_CAPTURE_SCHEMA,
        "capture_kind": key,
        "source_tool": collector.SOURCE_CAPTURE_TOOLS[key],
        "captured_at": manifest["capture"]["completed_at"],
        "event_id": source_event_id(key, manifest),
        "payload_jcs_sha256": validator._jcs_sha256(payload),
        "payload": payload,
    }


def write_source_captures(root: Path, manifest: dict, *, payload_only: bool = False) -> dict[str, str]:
    feed = copy.deepcopy(manifest["artifact_feed"])
    feed["route_binding"] = collector.artifact_binding(feed)
    route_digest = validator._jcs_sha256(manifest["route_snapshot_v1"])
    settlement_verdict = copy.deepcopy(manifest["settlement_verdict"])
    settlement_verdict["route_snapshot_digest"] = route_digest
    settlement_verdict["artifact_binding"] = collector.artifact_binding(feed)
    payloads = {
        "physical_run_log": {
            "hardware": manifest["hardware"],
            "runtime": manifest["runtime"],
            "artifact_feed": feed,
            "preparation": manifest["preparation"],
            "provider": manifest["provider"],
            "admission": manifest["admission"],
        },
        "request_transcript": manifest["request"],
        "status_before": manifest["provider"]["status_before"],
        "status_after": manifest["provider"]["status_after"],
        "provider_receipt_audit": manifest["provider"]["correlation"],
        "coordinator_route_snapshot": manifest["route_snapshot_v1"],
        "coordinator_settlement_verdict": settlement_verdict,
        "redaction_report": {"redaction_passed": True},
    }
    captures = {}
    for key, payload in payloads.items():
        name = f"{key}.redacted.json"
        source_payload = {"payload": payload} if payload_only else source_capture_envelope(key, payload, manifest)
        write_json(root / name, source_payload)
        captures[key] = name
    return captures


def capture_manifest_from_valid_evidence(root: Path, evidence: dict | None = None, *, payload_only: bool = False) -> Path:
    evidence = valid_evidence() if evidence is None else evidence
    manifest = {
        "schema_version": collector.CAPTURE_MANIFEST_SCHEMA,
        "capture": {
            "started_at": evidence["capture"]["started_at"],
            "completed_at": evidence["capture"]["completed_at"],
            "binary_version": evidence["capture"]["binary_version"],
            "binary_sha256": evidence["capture"]["binary_sha256"],
        },
        "staging_config": evidence["staging_config"],
        "hardware": evidence["hardware"],
        "runtime": evidence["runtime"],
        "artifact_feed": {key: value for key, value in evidence["artifact_feed"].items() if key != "route_binding"},
        "preparation": evidence["preparation"],
        "provider": evidence["provider"],
        "admission": evidence["admission"],
        "request": evidence["request"],
        "route_snapshot_v1": evidence["route_snapshot"]["route_snapshot_v1"],
        "settlement": evidence["settlement"],
        "settlement_verdict": evidence["settlement_verdict"],
    }
    manifest["source_captures"] = write_source_captures(root, manifest, payload_only=payload_only)
    path = root / "capture-manifest.json"
    write_json(path, manifest)
    return path


class Build1NarrowMVPEvidenceCollectorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="build1-mvp-collector-")
        self.capture_root = Path(self.temp.name)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_assembles_redacted_capture_manifest_into_validator_valid_evidence(self) -> None:
        manifest = capture_manifest_from_valid_evidence(self.capture_root)
        output = self.capture_root / "evidence.redacted.json"

        payload = collector.assemble_evidence(REPO_ROOT, manifest, captured_at=None)
        collector.write_json_atomically(output, payload)

        self.assertEqual([], validator.validate_build1_narrow_mvp_evidence(payload).errors)
        self.assertEqual("schema_valid_structural_only", payload["validation_scope"])
        self.assertEqual("physical_staging", payload["evidence_class"])
        self.assertEqual(
            validator._jcs_sha256(payload["route_snapshot"]["route_snapshot_v1"]),
            payload["route_snapshot"]["route_snapshot_digest"],
        )
        self.assertEqual(
            validator._jcs_sha256(payload["route_snapshot"]["artifact_binding"]),
            payload["route_snapshot"]["artifact_binding_digest"],
        )
        self.assertFalse(payload["production_blockers"]["production_activation_enabled"])
        self.assertTrue(output.is_file())

    def test_cli_requires_explicit_redacted_acknowledgement(self) -> None:
        manifest = capture_manifest_from_valid_evidence(self.capture_root)
        output = self.capture_root / "evidence.redacted.json"

        completed = subprocess.run(
            [
                sys.executable,
                str(COLLECTOR_SCRIPT),
                "--root",
                str(REPO_ROOT),
                "--input-manifest",
                str(manifest),
                "--output",
                str(output),
            ],
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn("--redacted is required", completed.stderr)
        self.assertFalse(output.exists())

    def test_cli_writes_validator_valid_evidence_from_redacted_manifest(self) -> None:
        manifest = capture_manifest_from_valid_evidence(self.capture_root)
        output = self.capture_root / "evidence.redacted.json"

        completed = subprocess.run(
            [
                sys.executable,
                str(COLLECTOR_SCRIPT),
                "--root",
                str(REPO_ROOT),
                "--redacted",
                "--input-manifest",
                str(manifest),
                "--output",
                str(output),
            ],
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertIn("wrote validated evidence", completed.stdout)
        payload = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual([], validator.validate_build1_narrow_mvp_evidence(payload).errors)

    def test_writes_blocker_report_without_acceptance_claim_when_inputs_are_missing(self) -> None:
        output = self.capture_root / "blockers.json"
        completed = subprocess.run(
            [
                sys.executable,
                str(COLLECTOR_SCRIPT),
                "--root",
                str(REPO_ROOT),
                "--blocker-output",
                str(output),
                "--captured-at",
                "2026-09-14T10:00:00Z",
            ],
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertEqual(0, completed.returncode, completed.stderr)
        report = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(collector.BLOCKER_SCHEMA, report["schema_version"])
        self.assertEqual("blocked_missing_redacted_staging_inputs", report["status"])
        self.assertFalse(report["non_activation_boundary"]["production_activation_enabled"])
        self.assertIn("provider_receipt_audit", report["required_source_capture_files"])

    def test_refuses_unredacted_source_capture(self) -> None:
        manifest = capture_manifest_from_valid_evidence(self.capture_root)
        write_json(self.capture_root / "provider_receipt_audit.redacted.json", {"payload": {"note": "Bearer abcdefghijk"}})

        with self.assertRaisesRegex(collector.CaptureError, "failed redaction scan"):
            collector.assemble_evidence(REPO_ROOT, manifest, captured_at=None)

    def test_refuses_source_capture_that_does_not_match_manifest_claims(self) -> None:
        manifest = capture_manifest_from_valid_evidence(self.capture_root)
        source_payload = {"request_id": "req-other", "provider_id": "mp-other"}
        write_json(
            self.capture_root / "coordinator_route_snapshot.redacted.json",
            source_capture_envelope("coordinator_route_snapshot", source_payload, json.loads(manifest.read_text())),
        )

        with self.assertRaisesRegex(collector.CaptureError, "coordinator_route_snapshot"):
            collector.assemble_evidence(REPO_ROOT, manifest, captured_at=None)

    def test_refuses_payload_only_source_capture_mirrors(self) -> None:
        manifest = capture_manifest_from_valid_evidence(self.capture_root, payload_only=True)

        with self.assertRaisesRegex(collector.CaptureError, "must contain exactly expected fields"):
            collector.assemble_evidence(REPO_ROOT, manifest, captured_at=None)

    def test_refuses_source_capture_without_timestamp(self) -> None:
        manifest = capture_manifest_from_valid_evidence(self.capture_root)
        source = self.capture_root / "provider_receipt_audit.redacted.json"
        payload = json.loads(source.read_text(encoding="utf-8"))
        payload["captured_at"] = None
        write_json(source, payload)

        with self.assertRaisesRegex(collector.CaptureError, "captured_at must be a non-empty"):
            collector.assemble_evidence(REPO_ROOT, manifest, captured_at=None)

    def test_refuses_fake_or_fixture_evidence_before_writing(self) -> None:
        evidence = valid_evidence()
        evidence["provider"]["fake_provider"] = True
        evidence["request"]["actual_mlx_inference"] = False
        manifest = capture_manifest_from_valid_evidence(self.capture_root, evidence)

        with self.assertRaisesRegex(collector.CaptureError, "assembled evidence failed validator"):
            collector.assemble_evidence(REPO_ROOT, manifest, captured_at=None)

    def test_refuses_route_digest_drift_from_settlement_source(self) -> None:
        evidence = valid_evidence()
        evidence["settlement"]["route_snapshot_digest"] = "0" * 64
        manifest = capture_manifest_from_valid_evidence(self.capture_root, evidence)

        with self.assertRaisesRegex(collector.CaptureError, "settlement.route_snapshot_digest"):
            collector.assemble_evidence(REPO_ROOT, manifest, captured_at=None)

    def test_cli_rejects_missing_nested_provider_fields_without_traceback(self) -> None:
        for field in ("status_before", "status_after", "correlation"):
            with self.subTest(field=field):
                temp = tempfile.TemporaryDirectory(prefix=f"build1-mvp-missing-{field}-")
                self.addCleanup(temp.cleanup)
                capture_root = Path(temp.name)
                manifest = capture_manifest_from_valid_evidence(capture_root)
                manifest_payload = json.loads(manifest.read_text(encoding="utf-8"))
                del manifest_payload["provider"][field]
                physical_log_path = capture_root / manifest_payload["source_captures"]["physical_run_log"]
                physical_log = json.loads(physical_log_path.read_text(encoding="utf-8"))
                del physical_log["payload"]["provider"][field]
                physical_log["payload_jcs_sha256"] = validator._jcs_sha256(physical_log["payload"])
                write_json(physical_log_path, physical_log)
                write_json(manifest, manifest_payload)
                output = capture_root / "evidence.redacted.json"

                completed = subprocess.run(
                    [
                        sys.executable,
                        str(COLLECTOR_SCRIPT),
                        "--root",
                        str(REPO_ROOT),
                        "--redacted",
                        "--input-manifest",
                        str(manifest),
                        "--output",
                        str(output),
                    ],
                    capture_output=True,
                    text=True,
                    check=False,
                )

                self.assertNotEqual(0, completed.returncode)
                self.assertIn("collect-build1-narrow-mvp-evidence:", completed.stderr)
                self.assertNotIn("Traceback", completed.stderr)
                self.assertFalse(output.exists())

    def test_refuses_symlink_or_reused_source_capture_files(self) -> None:
        manifest = capture_manifest_from_valid_evidence(self.capture_root)
        source = self.capture_root / "status_before.redacted.json"
        symlink = self.capture_root / "status-before-link.redacted.json"
        symlink.symlink_to(source)
        data = json.loads(manifest.read_text(encoding="utf-8"))
        data["source_captures"]["status_before"] = symlink.name
        write_json(manifest, data)

        with self.assertRaisesRegex(collector.CaptureError, "must not be a symlink"):
            collector.assemble_evidence(REPO_ROOT, manifest, captured_at=None)

        data["source_captures"]["status_before"] = source.name
        data["source_captures"]["status_after"] = source.name
        write_json(manifest, data)
        with self.assertRaisesRegex(collector.CaptureError, "unique source capture"):
            collector.assemble_evidence(REPO_ROOT, manifest, captured_at=None)

    def test_cli_rejects_invalid_root_without_traceback(self) -> None:
        output = self.capture_root / "blockers.json"
        completed = subprocess.run(
            [
                sys.executable,
                str(COLLECTOR_SCRIPT),
                "--root",
                str(self.capture_root / "absent"),
                "--blocker-output",
                str(output),
            ],
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn("collect-build1-narrow-mvp-evidence:", completed.stderr)
        self.assertNotIn("Traceback", completed.stderr)
        self.assertFalse(output.exists())

    def test_cli_rejects_malformed_captured_at_for_blocker_report(self) -> None:
        output = self.capture_root / "blockers.json"
        completed = subprocess.run(
            [
                sys.executable,
                str(COLLECTOR_SCRIPT),
                "--root",
                str(REPO_ROOT),
                "--blocker-output",
                str(output),
                "--captured-at",
                "not-a-date",
            ],
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn("--captured-at must be UTC ISO-8601", completed.stderr)
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
