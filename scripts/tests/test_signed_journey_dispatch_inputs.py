"""signed-journey.yml stays within GitHub's workflow_dispatch input cap."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "signed-journey.yml"
DECODER = REPO_ROOT / "scripts" / "signed-journeys" / "oncall" / "decode-record.py"

# GitHub rejects the workflow file above this, including on push.
MAX_WORKFLOW_DISPATCH_INPUTS = 25

EXPECTED_INPUTS = {
    "journey",
    "source_sha",
    "redacted_evidence_path",
    "requirement_ids",
    "promotion_confirmed",
    "evidence_confirmed",
    "postcut_asset_id",
    "postcut_asset_sha256",
    "postcut_release_id",
    "signed_candidate_path",
    "live_activation_target",
    "schema_migration_hash",
    "approval_record_version",
    "creator_agreement_version",
    "pricing_schedule_version",
    "authorization_id",
    "authorized_actor",
    "credential_id",
    "operation_id",
    "oncall_record",
}


def workflow_dispatch_inputs(text: str) -> list[str]:
    keys: list[str] = []
    in_inputs = False
    for line in text.splitlines():
        if line.startswith("    inputs:"):
            in_inputs = True
            continue
        if not in_inputs:
            continue
        if line.startswith("permissions:") or (line and not line.startswith(" ")):
            break
        if line.startswith("      ") and not line.startswith("        ") and line.rstrip().endswith(":"):
            keys.append(line.strip()[:-1])
    return keys


def load_decoder():
    spec = importlib.util.spec_from_file_location("oncall_decode_record", DECODER)
    if spec is None or spec.loader is None:
        raise RuntimeError("decode-record.py is not loadable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class SignedJourneyDispatchInputsTest(unittest.TestCase):
    def test_input_count_is_within_the_github_cap(self) -> None:
        keys = workflow_dispatch_inputs(WORKFLOW.read_text(encoding="utf-8"))
        self.assertEqual(len(keys), len(set(keys)))
        self.assertEqual(set(keys), EXPECTED_INPUTS)
        self.assertLessEqual(len(keys), MAX_WORKFLOW_DISPATCH_INPUTS)

    def test_decoder_exports_the_oncall_fields(self) -> None:
        decoder = load_decoder()
        record = {
            "launch_environment_id": "production",
            "record_version": "v1",
            "primary_operator_contact": "primary'ops",
            "secondary_operator_contact": "secondary",
            "break_glass_escalation_path": "page",
            "compromise_notification_channel": "channel",
            "creator_agreement_notification_commitment_ack": "acked",
            "creator_emergency_notification_mechanism": "page-creator",
            "confirmation_ttl_seconds": 3600,
            "signing_confirmed": True,
        }
        values = decoder.decode(json.dumps(record))
        self.assertEqual(values["LAUNCH_ENV_INPUT"], "production")
        self.assertEqual(values["LAUNCH_ENV"], "production")
        self.assertEqual(values["RECORD_VERSION"], "v1")
        self.assertEqual(values["PRIMARY"], "primary'ops")
        self.assertEqual(values["TTL_INPUT"], "3600")
        self.assertEqual(values["TTL"], "3600")
        self.assertEqual(values["SIGNING_CONFIRMED_INPUT"], "true")

    def test_decoder_defaults_match_the_old_inputs(self) -> None:
        decoder = load_decoder()
        values = decoder.decode("{}")
        self.assertEqual(values["TTL_INPUT"], "7776000")
        self.assertEqual(values["SIGNING_CONFIRMED_INPUT"], "false")
        self.assertEqual(values["LAUNCH_ENV_INPUT"], "")

    def test_decoder_rejects_a_string_signing_flag_and_unknown_fields(self) -> None:
        decoder = load_decoder()
        with self.assertRaises(SystemExit):
            decoder.decode(json.dumps({"signing_confirmed": "true"}))
        with self.assertRaises(SystemExit):
            decoder.decode(json.dumps({"extra": "nope"}))
        with self.assertRaises(SystemExit):
            decoder.decode(json.dumps({"primary_operator_contact": "line\nbreak"}))
        with self.assertRaises(SystemExit):
            decoder.decode("[]")
        with self.assertRaises(SystemExit):
            decoder.decode("")

    def test_cli_writes_a_sourceable_shell_file(self) -> None:
        record = {
            "launch_environment_id": "production",
            "record_version": "v1",
            "signing_confirmed": True,
            "confirmation_ttl_seconds": "90",
        }
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            shell_path = root / "decoded.sh"
            env_path = root / "github.env"
            env_path.write_text("", encoding="utf-8")
            completed = subprocess.run(
                [
                    sys.executable,
                    str(DECODER),
                    "--shell",
                    str(shell_path),
                    "--github-env",
                    str(env_path),
                    "--json",
                    json.dumps(record),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(shell_path.stat().st_mode & 0o777, 0o600)
            sourced = subprocess.run(
                ["bash", "-c", f'set -euo pipefail; source "{shell_path}"; printf %s "$SIGNING_CONFIRMED_INPUT $TTL_INPUT $LAUNCH_ENV"'],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(sourced.returncode, 0, sourced.stderr)
            self.assertEqual(sourced.stdout, "true 90 production")
            github_env = env_path.read_text(encoding="utf-8")
            self.assertIn("SIGNING_CONFIRMED_INPUT<<", github_env)
            self.assertIn("\ntrue\n", github_env)


if __name__ == "__main__":
    unittest.main()
