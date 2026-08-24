from __future__ import annotations

import importlib.util
import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from scripts.check_spec_governance import (
    LOCAL_CONSUMER_ENDPOINT_ARTIFACT_ID,
    LOCAL_CONSUMER_ENDPOINT_EVIDENCE_REQUIREMENT_IDS,
    LOCAL_CONSUMER_ENDPOINT_EXECUTION_MODE,
    LOCAL_CONSUMER_ENDPOINT_JOURNEY_ID,
    LOCAL_CONSUMER_ENDPOINT_STEP_ID_ORDER,
)

REPO_ROOT = Path(__file__).resolve().parents[2]
FINGERPRINT = "a" * 64
OTHER_FINGERPRINT = "b" * 64


def load_capture():
    path = REPO_ROOT / "scripts" / "capture-local-consumer-endpoint-evidence.py"
    import sys

    scripts = str(REPO_ROOT / "scripts")
    inserted = scripts not in sys.path
    if inserted:
        sys.path.insert(0, scripts)
    spec = importlib.util.spec_from_file_location("local_consumer_endpoint_capture", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    try:
        spec.loader.exec_module(module)
        return module
    finally:
        if inserted:
            sys.path.remove(scripts)


def load_builder():
    path = REPO_ROOT / "scripts" / "build-local-consumer-endpoint-journey-result.py"
    import sys

    scripts = str(REPO_ROOT / "scripts")
    inserted = scripts not in sys.path
    if inserted:
        sys.path.insert(0, scripts)
    spec = importlib.util.spec_from_file_location("local_consumer_endpoint_builder", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    try:
        spec.loader.exec_module(module)
        return module
    finally:
        if inserted:
            sys.path.remove(scripts)


def git_init(root: Path) -> str:
    subprocess.run(["git", "init", "-q"], cwd=root, check=True)
    subprocess.run(["git", "config", "user.email", "test@example.invalid"], cwd=root, check=True)
    subprocess.run(["git", "config", "user.name", "test"], cwd=root, check=True)
    marker = root / "README.md"
    marker.write_text("test repository\n", encoding="utf-8")
    subprocess.run(["git", "add", "README.md"], cwd=root, check=True)
    subprocess.run(["git", "commit", "-q", "-m", "initial"], cwd=root, check=True)
    return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()


def write_capture_inputs(root: Path) -> dict[str, Path]:
    inputs = root / "capture-inputs"
    inputs.mkdir(exist_ok=True)
    files = {
        "cli": inputs / "macprovider-cli",
        "ledger": inputs / "ledger.redacted.jsonl",
        "log": inputs / "logs.redacted.txt",
        "rate": inputs / "rate-card.redacted.json",
        "status": inputs / "status.redacted.json",
    }
    files["cli"].write_bytes(b"binary-bytes")
    files["ledger"].write_text('{"state":"settled","redacted":true}\n', encoding="utf-8")
    files["log"].write_text("local endpoint log redacted\n", encoding="utf-8")
    files["rate"].write_text('{"rate_card":"redacted","sha_only":true}\n', encoding="utf-8")
    files["status"].write_text('{"status":"ready","redacted":true}\n', encoding="utf-8")
    return files


def file_record(path: Path) -> dict[str, int | str]:
    payload = path.read_bytes()
    return {"sha256": hashlib.sha256(payload).hexdigest(), "bytes": len(payload)}


def write_review_manifest(root: Path, files: dict[str, Path], run_id: str = "local-consumer-endpoint-20260824T000000Z") -> Path:
    manifest = {
        "schema_version": "macprovider.local-consumer-endpoint-capture-review.v1",
        "journey_id": LOCAL_CONSUMER_ENDPOINT_JOURNEY_ID,
        "run_id": run_id,
        "result": {"status": "pass"},
        "steps": [
            {
                "id": step_id,
                "status": "pass",
                "artifacts": [LOCAL_CONSUMER_ENDPOINT_ARTIFACT_ID],
                "support_artifacts": ["cli_binary", "ledger_capture", "log_capture", "rate_card_capture", "status_capture"],
            }
            for step_id in LOCAL_CONSUMER_ENDPOINT_STEP_ID_ORDER
        ],
        "redaction": {
            "local_account_names_redacted": True,
            "operator_identity_redacted": True,
            "secrets_redacted": True,
        },
        "observations": {
            "bearer_tokens_redacted": True,
            "fake_gateway_used": False,
            "generated_local_token_used_as_api_key": True,
            "held_reservation_survived_restart": True,
            "local_base_url_configured": True,
            "local_token_logged": False,
            "openai_sdk_used": True,
            "over_budget_denial_observed": True,
            "permitted_chat_completion_observed": True,
            "raw_completion_logged": False,
            "raw_prompt_logged": False,
            "raw_prompt_output_redacted": True,
            "recovery_release_observed": True,
            "redacted_artifacts_reviewed": True,
            "staging_or_production_gateway": True,
            "upstream_credential_logged": False,
        },
        "support_artifacts": {
            "cli_binary": file_record(files["cli"]),
            "ledger_capture": file_record(files["ledger"]),
            "log_capture": file_record(files["log"]),
            "rate_card_capture": file_record(files["rate"]),
            "status_capture": file_record(files["status"]),
        },
        "review": {
            "reviewed_at": "2026-08-24T00:01:00Z",
            "reviewer_role": "release-operator",
            "support_artifacts_reviewed": ["cli_binary", "ledger_capture", "log_capture", "rate_card_capture", "status_capture"],
            "real_gateway_basis": "staging-or-production-gateway",
            "sdk_client_basis": "openai-sdk-local-token-api-key",
            "redaction_basis": "redacted-support-artifacts-reviewed",
        },
    }
    path = root / "capture-inputs" / "review-manifest.json"
    path.parent.mkdir(exist_ok=True)
    path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return path


def base_argv(root: Path, commit: str, files: dict[str, Path], output: str) -> list[str]:
    review_manifest = write_review_manifest(root, files)
    return [
        "--root",
        str(root),
        "--output",
        output,
        "--source-sha",
        commit,
        "--captured-at",
        "2026-08-24T00:00:00Z",
        "--expires-at",
        "2999-01-01",
        "--requirement-ids",
        ",".join(sorted(LOCAL_CONSUMER_ENDPOINT_EVIDENCE_REQUIREMENT_IDS)),
        "--review-manifest",
        str(review_manifest),
        "--run-id",
        "local-consumer-endpoint-20260824T000000Z",
        "--operator-role",
        "release-operator",
        "--operator-identity-fingerprint",
        FINGERPRINT,
        "--hardware-profile",
        "local-macos-redacted",
        "--candidate",
        f"commit:{commit}",
        "--gateway-kind",
        "production",
        "--model-id",
        "model-test",
        "--sdk-name",
        "openai-python",
        "--sdk-version",
        "2.0.0",
        "--buyer-credential-fingerprint",
        OTHER_FINGERPRINT,
        "--local-token-fingerprint",
        FINGERPRINT,
        "--local-endpoint-base-url",
        "http://127.0.0.1:4545/v1",
        "--upstream-gateway-origin",
        "https://api.malibu.tech",
        "--cli-version",
        "1.8.99-test",
        "--cli-binary",
        str(files["cli"]),
        "--ledger-capture",
        str(files["ledger"]),
        "--log-capture",
        str(files["log"]),
        "--rate-card-capture",
        str(files["rate"]),
        "--status-capture",
        str(files["status"]),
    ]


class LocalConsumerEndpointEvidenceCaptureTests(unittest.TestCase):
    def test_capture_emits_builder_compatible_redacted_evidence(self) -> None:
        capture = load_capture()
        builder = load_builder()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            commit = git_init(root)
            files = write_capture_inputs(root)
            output = "journeys/evidence/local-consumer-endpoint-20260824T000000Z.redacted.json"
            self.assertEqual(0, capture.main(base_argv(root, commit, files, output)))
            evidence_path = root / output
            evidence = json.loads(evidence_path.read_text(encoding="utf-8"))

            self.assertEqual("macprovider.local-consumer-endpoint-evidence.v1", evidence["schema_version"])
            self.assertEqual(LOCAL_CONSUMER_ENDPOINT_JOURNEY_ID, evidence["journey_id"])
            self.assertEqual(LOCAL_CONSUMER_ENDPOINT_EXECUTION_MODE, evidence["environment"]["class"])
            self.assertEqual(["step-01-capture-local-endpoint", "step-02-openai-sdk-local-client"], [step["id"] for step in evidence["steps"][:2]])
            self.assertEqual([LOCAL_CONSUMER_ENDPOINT_ARTIFACT_ID], evidence["steps"][0]["artifacts"])
            self.assertEqual("pass", evidence["result"]["status"])
            self.assertNotIn("summary", evidence["result"])
            self.assertEqual(sorted(LOCAL_CONSUMER_ENDPOINT_EVIDENCE_REQUIREMENT_IDS), evidence["requirement_ids"])
            self.assertEqual("production", evidence["candidate_identity"]["gateway_kind"])
            self.assertEqual(
                sorted(["cli_binary", "ledger_capture", "log_capture", "rate_card_capture", "status_capture"]),
                sorted(evidence["support_artifacts"]),
            )
            self.assertEqual(
                ["cli_binary", "ledger_capture", "log_capture", "rate_card_capture", "status_capture"],
                evidence["review"]["support_artifacts_reviewed"],
            )

            subprocess.run(["git", "add", output], cwd=root, check=True)
            subprocess.run(["git", "commit", "-q", "-m", "add evidence"], cwd=root, check=True)
            evidence_commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            original_mapped = builder.load_mapped_local_consumer_requirements
            try:
                builder.load_mapped_local_consumer_requirements = lambda root: set(LOCAL_CONSUMER_ENDPOINT_EVIDENCE_REQUIREMENT_IDS)
                payload = builder.build_payload(
                    root,
                    output,
                    source_sha=commit,
                    evidence_sha=evidence_commit,
                    requirement_ids="SPEC-045-R001,SPEC-045-R008",
                )
            finally:
                builder.load_mapped_local_consumer_requirements = original_mapped
            self.assertEqual(["SPEC-045-R001", "SPEC-045-R008"], payload["requirement_ids"])
            self.assertEqual(LOCAL_CONSUMER_ENDPOINT_STEP_ID_ORDER[0], payload["steps"][0]["id"])

    def test_capture_allows_redacted_authorization_header(self) -> None:
        capture = load_capture()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            commit = git_init(root)
            files = write_capture_inputs(root)
            files["log"].write_text("Authorization: Bearer redacted\n", encoding="utf-8")
            self.assertEqual(
                0,
                capture.main(
                    base_argv(
                        root,
                        commit,
                        files,
                        "journeys/evidence/local-consumer-endpoint-redacted-auth.redacted.json",
                    )
                ),
            )

            files = write_capture_inputs(root)
            files["log"].write_text("Authorization: Basic redacted\n", encoding="utf-8")
            self.assertEqual(
                0,
                capture.main(
                    base_argv(
                        root,
                        commit,
                        files,
                        "journeys/evidence/local-consumer-endpoint-redacted-basic-auth.redacted.json",
                    )
                ),
            )

            files = write_capture_inputs(root)
            files["log"].write_text("payload={'authorization': 'Basic redacted'}\n", encoding="utf-8")
            self.assertEqual(
                0,
                capture.main(
                    base_argv(
                        root,
                        commit,
                        files,
                        "journeys/evidence/local-consumer-endpoint-quoted-redacted-basic-auth.redacted.json",
                    )
                ),
            )

            files = write_capture_inputs(root)
            files["log"].write_text('{"authorization":"redacted"}\n', encoding="utf-8")
            self.assertEqual(
                0,
                capture.main(
                    base_argv(
                        root,
                        commit,
                        files,
                        "journeys/evidence/local-consumer-endpoint-json-redacted-auth.redacted.json",
                    )
                ),
            )

    def test_capture_rejects_fake_gateway_kind(self) -> None:
        capture = load_capture()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            commit = git_init(root)
            files = write_capture_inputs(root)
            argv = base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-fake.redacted.json")
            argv[argv.index("--gateway-kind") + 1] = "fake"
            with self.assertRaises(SystemExit):
                capture.main(argv)

    def test_capture_scans_artifacts_for_secrets_and_transcripts(self) -> None:
        capture = load_capture()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            commit = git_init(root)
            files = write_capture_inputs(root)
            files["log"].write_text("Authorization: Bearer secret-value-1234567890\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-secret.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text("Authorization: Basic dXNlcjpwYXNzd29yZA==\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-basic-auth.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text("Authorization: Bearer redacted.actual-secret-token-1234567890\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-redacted-prefix.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text("Authorization: Foo abcdefghijklmnopqrstuvwxyz1234567890\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-unknown-auth.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text("payload={'authorization': 'Basic dXNlcjpwYXNzd29yZA=='}\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-single-quoted-basic-auth.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text('{"authorization":"Basic dXNlcjpwYXNzd29yZA=="}\n', encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-json-basic-auth.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text('{"authorization":"Foo abcdefghijklmnopqrstuvwxyz123456"}\n', encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-json-unknown-auth.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text("payload={'authorization': 'redacted-actual-secret-token-1234567890'}\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-single-quoted-redacted-prefix-auth.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text("Authorization: redacted, Basic dXNlcjpwYXNzd29yZA==\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-comma-redacted-auth.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text("Authorization: Bearer redacted, abcdefghijklmnopqrstuvwxyz1234567890\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-comma-bearer-auth.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text("payload={'authorization': 'redacted, abcdefghijklmnopqrstuvwxyz1234567890'}\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-comma-quoted-auth.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text("Authorization: 'Basic dXNlcjpwYXNzd29yZA==\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-unterminated-quoted-auth.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text("Authorization: \"Basic dXNlcjpwYXNzd29yZA=='\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-mismatched-quoted-auth.redacted.json"))

            files = write_capture_inputs(root)
            files["status"].write_text('{"messages":[{"role":"user","content":"hello"}]}', encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-transcript.redacted.json"))

            files = write_capture_inputs(root)
            files["status"].write_text('{"status":"ready","status":"still-ready"}\n', encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-duplicate-json-key.redacted.json"))

            files = write_capture_inputs(root)
            files["ledger"].write_text('{"state":"settled","state":"settled-again"}\n', encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-duplicate-jsonl-key.redacted.json"))

            files = write_capture_inputs(root)
            files["status"].write_text('{"raw_prompt":"redacted"}\n', encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-raw-prompt-key.redacted.json"))

            files = write_capture_inputs(root)
            files["status"].write_text('{"access_token":"redacted"}\n', encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-access-token-key.redacted.json"))

            files = write_capture_inputs(root)
            files["status"].write_text('{"local-token":"redacted"}\n', encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-local-token-key.redacted.json"))

            files = write_capture_inputs(root)
            files["status"].write_text('{"local_token_fingerprint":"AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abc"}\n', encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-bad-local-token-fingerprint.redacted.json"))

            files = write_capture_inputs(root)
            files["status"].write_text('{"generated_local_token_used_as_api_key":"AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abc"}\n', encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-bad-generated-token-observation.redacted.json"))

            files = write_capture_inputs(root)
            files["status"].write_text('{"raw_prompt_logged":"raw prompt text"}\n', encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-bad-raw-prompt-observation.redacted.json"))

            files = write_capture_inputs(root)
            files["status"].write_text('{"permitted_chat_completion_observed":"raw completion text"}\n', encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-bad-permitted-completion-observation.redacted.json"))

            files = write_capture_inputs(root)
            files["status"].write_text('{"apiKey":"redacted"}\n', encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-api-key-camel.redacted.json"))

            files = write_capture_inputs(root)
            files["status"].write_text('{"rawPrompt":"redacted"}\n', encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-raw-prompt-camel.redacted.json"))

            for key in ["APIKey", "openai_api_key", "upstreamApiKey", "api key", "raw.prompt", "promptText", "request_body"]:
                files = write_capture_inputs(root)
                files["status"].write_text(json.dumps({key: "redacted"}) + "\n", encoding="utf-8")
                safe_key = "".join(char.lower() if char.isalnum() else "-" for char in key).strip("-")
                with self.subTest(key=key), self.assertRaises(SystemExit):
                    capture.main(base_argv(root, commit, files, f"journeys/evidence/local-consumer-endpoint-{safe_key}.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_bytes(b"\xffAuthorization: Bearer secret-value-1234567890\n")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-invalid-utf8.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text("local_token=AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abc\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-local-token.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text("OpenAI(api_key='AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abc')\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-quoted-api-key.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text('local_token="AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abc"\n', encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-quoted-local-token.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text('local_token=""AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abc\n', encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-empty-double-local-token.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text("local_token=''AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abc\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-empty-single-local-token.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text('api_key=""AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abc\n', encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-empty-api-key.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text("local_token=redacted-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-redacted-prefix-token.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text('timestamp payload={"local_token":"AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abc"}\n', encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-framed-local-token.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text("timestamp apiKey=redacted\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-framed-api-key.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text("timestamp rawPrompt=redacted\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-framed-raw-prompt.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text('timestamp payload="{\\"apiKey\\":\\"redacted\\"}"\n', encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-escaped-api-key.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text("{'local_token': 'redacted'}\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-single-quoted-local-token.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text("local[token]=AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abc\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-bracket-local-token.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text("local_token_fingerprint=not-a-fingerprint\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-framed-bad-local-token-fingerprint.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text("generated_local_token_used_as_api_key=not-bool\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-framed-bad-generated-token-observation.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text("raw_prompt_logged=raw prompt text\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-framed-bad-raw-prompt-observation.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text("permitted_chat_completion_observed=raw completion text\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-framed-bad-permitted-completion-observation.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text("local_token_fingerprint=" + FINGERPRINT + ", raw-token-after-valid-prefix\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-framed-comma-local-token-fingerprint.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text("generated_local_token_used_as_api_key=true, raw-token-after-valid-prefix\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-framed-comma-generated-token-observation.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text("raw_prompt_logged=false, raw prompt after valid prefix\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-framed-comma-raw-prompt-observation.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text("local/token=AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abc\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-slash-local-token.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text("messages[0][content]=hello\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-bracket-message-content.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text("local_token_" + ("x" * 90) + "=AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abc\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-long-local-token-key.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text('timestamp payload="{\\"local_token\\":\\"AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abc\\"}"\n', encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-escaped-local-token.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text(
                'timestamp payload="{\\"'
                + "\\u006cocal_token"
                + '\\":\\"AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abc\\"}"\n',
                encoding="utf-8",
            )
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-unicode-local-token.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text(
                'timestamp payload="{\\"'
                + "\\\\u006cocal_token"
                + '\\":\\"AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abc\\"}"\n',
                encoding="utf-8",
            )
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-double-unicode-local-token.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text(
                'prefix '
                + "\\uZZZZ"
                + ' payload="{\\"'
                + "\\u006cocal_token"
                + '\\":\\"AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abc\\"}"\n',
                encoding="utf-8",
            )
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-malformed-escaped-local-token.redacted.json"))

            files = write_capture_inputs(root)
            over_escaped_key = "\\" * 512 + "u006cocal_token"
            files["log"].write_text(
                'timestamp payload="{\\"'
                + over_escaped_key
                + '\\":\\"AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abc\\"}"\n',
                encoding="utf-8",
            )
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-over-escaped-local-token.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text(
                'timestamp payload="{\\"'
                + "\\u006dessages"
                + '\\":[{\\"role\\":\\"user\\",\\"'
                + "\\u0063ontent"
                + '\\":\\"hello\\"}]}"\n',
                encoding="utf-8",
            )
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-unicode-transcript.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text(
                'timestamp payload="{\\"'
                + "\\\\u006dessages"
                + '\\":[{\\"role\\":\\"user\\",\\"'
                + "\\\\u0063ontent"
                + '\\":\\"hello\\"}]}"\n',
                encoding="utf-8",
            )
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-double-unicode-transcript.redacted.json"))

    def test_capture_rejects_duplicate_review_manifest_keys(self) -> None:
        capture = load_capture()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            commit = git_init(root)
            files = write_capture_inputs(root)
            argv = base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-duplicate-manifest-key.redacted.json")
            manifest = Path(argv[argv.index("--review-manifest") + 1])
            text = manifest.read_text(encoding="utf-8")
            duplicated = text.replace(
                '"schema_version": "macprovider.local-consumer-endpoint-capture-review.v1"',
                '"schema_version": "macprovider.local-consumer-endpoint-capture-review.v1",\n  "schema_version": "macprovider.local-consumer-endpoint-capture-review.v1"',
                1,
            )
            manifest.write_text(duplicated, encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(argv)

    def test_capture_rejects_malformed_support_artifacts_reviewed(self) -> None:
        capture = load_capture()
        cases = {
            "object": {
                "cli_binary": False,
                "ledger_capture": False,
                "log_capture": False,
                "rate_card_capture": False,
                "status_capture": False,
            },
            "duplicate": ["cli_binary", "cli_binary", "ledger_capture", "log_capture", "rate_card_capture", "status_capture"],
            "non_string": ["cli_binary", False, "log_capture", "rate_card_capture", "status_capture"],
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            commit = git_init(root)
            for name, reviewed in cases.items():
                files = write_capture_inputs(root)
                argv = base_argv(root, commit, files, f"journeys/evidence/local-consumer-endpoint-review-{name}.redacted.json")
                manifest_path = Path(argv[argv.index("--review-manifest") + 1])
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                manifest["review"]["support_artifacts_reviewed"] = reviewed
                manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
                with self.assertRaises(SystemExit, msg=name):
                    capture.main(argv)

    def test_capture_requires_local_consumer_output_path_and_requirements(self) -> None:
        capture = load_capture()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            commit = git_init(root)
            files = write_capture_inputs(root)
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/not-local.redacted.json"))
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-nested/run.redacted.json"))
            argv = base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-bad-req.redacted.json")
            argv[argv.index("--requirement-ids") + 1] = "SPEC-006-R001"
            with self.assertRaises(SystemExit):
                capture.main(argv)

    def test_capture_rejects_secret_metadata_and_fake_origin(self) -> None:
        capture = load_capture()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            commit = git_init(root)
            files = write_capture_inputs(root)
            argv = base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-secret-metadata.redacted.json")
            argv[argv.index("--candidate") + 1] = "sk-proj-secret00000000000000000000"
            with self.assertRaises(SystemExit):
                capture.main(argv)
            argv = base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-prompt-prose.redacted.json")
            argv[argv.index("--candidate") + 1] = "Summarize confidential merger plans"
            with self.assertRaises(SystemExit):
                capture.main(argv)
            argv = base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-operator-local.redacted.json")
            argv[argv.index("--operator-role") + 1] = "augstar@MacBook-Pro.local"
            with self.assertRaises(SystemExit):
                capture.main(argv)
            argv = base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-operator-bare-local.redacted.json")
            argv[argv.index("--operator-role") + 1] = "augstar-mbp"
            with self.assertRaises(SystemExit):
                capture.main(argv)
            argv = base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-hardware-local.redacted.json")
            argv[argv.index("--hardware-profile") + 1] = "Users/augstar/laptop"
            with self.assertRaises(SystemExit):
                capture.main(argv)
            argv = base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-hardware-bare-local.redacted.json")
            argv[argv.index("--hardware-profile") + 1] = "MacBook-Pro"
            with self.assertRaises(SystemExit):
                capture.main(argv)
            files = write_capture_inputs(root)
            argv = base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-reviewer-local.redacted.json")
            review_manifest = Path(argv[argv.index("--review-manifest") + 1])
            manifest = json.loads(review_manifest.read_text(encoding="utf-8"))
            manifest["review"]["reviewer_role"] = "augstar@MacBook-Pro.local"
            review_manifest.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(argv)
            files = write_capture_inputs(root)
            argv = base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-reviewer-bare-local.redacted.json")
            review_manifest = Path(argv[argv.index("--review-manifest") + 1])
            manifest = json.loads(review_manifest.read_text(encoding="utf-8"))
            manifest["review"]["reviewer_role"] = "augstar-mbp"
            review_manifest.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(argv)
            argv = base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-fake-origin.redacted.json")
            argv[argv.index("--upstream-gateway-origin") + 1] = "https://fake-gateway.example.invalid"
            with self.assertRaises(SystemExit):
                capture.main(argv)
            argv = base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-hash-bypass.redacted.json")
            origin_index = argv.index("--upstream-gateway-origin")
            del argv[origin_index : origin_index + 2]
            argv.extend(["--upstream-gateway-origin-sha256", FINGERPRINT])
            with self.assertRaises(SystemExit):
                capture.main(argv)
            argv = base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-bad-local-url.redacted.json")
            argv[argv.index("--local-endpoint-base-url") + 1] = "http://127.0.0.1:0/not-v1"
            with self.assertRaises(SystemExit):
                capture.main(argv)

    def test_capture_rejects_operator_local_candidate_identity_metadata(self) -> None:
        capture = load_capture()
        cases = {
            "--cli-version": "1.2.3-MacBook-Pro",
            "--model-id": "gpt-5augstar",
            "--sdk-name": "local/sdk",
            "--sdk-version": "augstar-MacBook-Pro",
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            commit = git_init(root)
            for flag, value in cases.items():
                files = write_capture_inputs(root)
                slug = flag.removeprefix("--").replace("-", "_")
                argv = base_argv(root, commit, files, f"journeys/evidence/local-consumer-endpoint-local-{slug}.redacted.json")
                argv[argv.index(flag) + 1] = value
                with self.assertRaises(SystemExit, msg=flag):
                    capture.main(argv)

    def test_capture_rejects_reviewed_artifact_replacement_and_framed_transcripts(self) -> None:
        capture = load_capture()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            commit = git_init(root)
            files = write_capture_inputs(root)
            argv = base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-replaced-artifact.redacted.json")
            files["log"].write_text("local endpoint log redacted after review\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(argv)

            files = write_capture_inputs(root)
            files["log"].write_text('timestamp response={"choices":[{"message":{"content":"raw completion"}}]}\n', encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-framed-transcript.redacted.json"))

            files = write_capture_inputs(root)
            files["log"].write_text('timestamp payload="{\\"messages\\":[{\\"role\\":\\"user\\",\\"content\\":\\"hello\\"}]}"\n', encoding="utf-8")
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-escaped-transcript.redacted.json"))

    def test_capture_rejects_input_and_output_symlinks(self) -> None:
        capture = load_capture()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            commit = git_init(root)
            files = write_capture_inputs(root)
            symlink_input = root / "capture-inputs" / "logs.symlink.txt"
            symlink_input.symlink_to(files["log"])
            argv = base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-input-symlink.redacted.json")
            argv[argv.index("--log-capture") + 1] = str(symlink_input)
            with self.assertRaises(SystemExit):
                capture.main(argv)

            output_parent = root / "journeys" / "evidence"
            output_parent.mkdir(parents=True)
            target = root / "README.md"
            symlink_output = output_parent / "local-consumer-endpoint-output-symlink.redacted.json"
            symlink_output.symlink_to(target)
            with self.assertRaises(SystemExit):
                capture.main(base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-output-symlink.redacted.json"))

            external = root / "external"
            external.mkdir()
            external_log = external / "logs.redacted.txt"
            external_log.write_text("local endpoint log redacted\n", encoding="utf-8")
            symlink_parent = root / "capture-inputs" / "linked-parent"
            symlink_parent.symlink_to(external, target_is_directory=True)
            argv = base_argv(root, commit, files, "journeys/evidence/local-consumer-endpoint-parent-symlink.redacted.json")
            argv[argv.index("--log-capture") + 1] = str(symlink_parent / "logs.redacted.txt")
            with self.assertRaises(SystemExit):
                capture.main(argv)


if __name__ == "__main__":
    unittest.main()
