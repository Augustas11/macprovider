"""Offline controller recovery tests; no SSH, provider or credential access."""

import base64
import hashlib
import json
import os
import re
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CONTROLLER = ROOT / "scripts/ops/qwen-opencode-e2e.sh"
COMMON = ROOT / "scripts/ops/lib/common.sh"


def shell_function(path, name):
    # Select the actual function, excluding entrypoint dispatch and ops.env.
    source = path.read_text(encoding="utf-8")
    match = re.search(r"^" + re.escape(name) + r"\(\) \{.*?^\}", source, re.M | re.S)
    if match is None:
        raise AssertionError("Missing shell function: " + name)
    return match.group(0)


class QwenE2EControllerTests(unittest.TestCase):
    def run_shell(self, names, body, journal=None, files=None):
        with tempfile.TemporaryDirectory(prefix="qwen-controller-test-") as directory:
            root = Path(directory)
            journal_file = root / "fixture.json"
            journal_file.write_text(json.dumps(journal or {}), encoding="utf-8")
            for name, text in (files or {}).items():
                (root / name).write_text(text, encoding="utf-8")
            definitions = "\n".join(shell_function(CONTROLLER, name) for name in names)
            common = "\n".join(shell_function(COMMON, name) for name in ("json_field", "set_next"))
            script = f"""
set -euo pipefail
OPS_TMP_DIR={shlex.quote(directory)}
FIXTURE={shlex.quote(str(journal_file))}
TRACE="$OPS_TMP_DIR/trace"
OPS_DIR=/unused/ops
QWEN_E2E_CLI=/unused/cli
QWEN_E2E_CONFIG=/unused/config
QWEN_E2E_JOURNAL=/unused/journal
MACPROVIDER_OPS_ENTRYPOINT=1
NEXT_ID= NEXT_KIND= NEXT_TITLE= NEXT_CMD= NEXT_REASON=
INCUMBENT_MODEL=incumbent BASELINE_PID=42
trace() {{ printf '%s\\n' "$*" >> "$TRACE"; }}
fact() {{ :; }}
log() {{ :; }}
refuse() {{ trace "refused:$*"; exit 3; }}
require_abs() {{ case "$2" in /*) ;; *) exit 91 ;; esac; }}
require_studio_ssh() {{ :; }}
read_studio_status() {{ trace forbidden_status; return 92; }}
fetch_market() {{ trace forbidden_market; return 93; }}
validate_handback() {{ trace forbidden_handback; return 94; }}
cleanup_ops() {{ trace common_cleanup; }}
{common}
{definitions}
{body}
"""
            result = subprocess.run(
                ["/bin/bash", "-c", script],
                env={"PATH": os.environ["PATH"], "LC_ALL": "C"},
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=10,
            )
            trace_path = root / "trace"
            trace = trace_path.read_text().splitlines() if trace_path.exists() else []
            return result, trace

    def test_interrupted_restore_precedes_market_handback_and_client_inputs(self):
        result, trace = self.run_shell(
            ["gather"],
            """
studio_helper() { [ "$1" = inspect ]; cat "$FIXTURE"; }
gather
printf '%s\\n' "$NEXT_ID" "$NEXT_KIND" "$NEXT_CMD"
""",
            {"status": "config_restored", "restore_required": True},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(),
                         ["restore", "mutate", "/unused/ops/qwen-opencode-e2e.sh _restore"])
        self.assertEqual(trace, [])

    def test_recovery_does_not_require_running_status_or_buyer_key(self):
        result, trace = self.run_shell(
            ["run_restore"],
            """
studio_helper() { [ "$1" = inspect ]; cat "$FIXTURE"; }
load_journal_context() { trace load_journal; }
verify_installed_cli() { trace installed_provenance; }
restore_provider() { trace restore_provider; }
remove_remote_scratch() { trace scratch_cleanup; }
run_restore
""",
            {"status": "config_restored", "restore_required": True},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace, ["load_journal", "installed_provenance",
                                 "restore_provider", "scratch_cleanup"])

    def restore_case(self, restart_rc=0, ready_rc=0, config_rc=0):
        return self.run_shell(
            ["restore_provider"],
            f"""
studio_helper() {{ trace "$1"; case "$1" in restore) return {config_rc};; restart-service) return {restart_rc};; esac; }}
studio_command() {{ trace forbidden_cli_restart; return 99; }}
poll_ready() {{ trace ready; return {ready_rc}; }}
result=0
# EXIT cleanup calls recovery in a conditional with errexit disabled.
set +e
restore_provider || result=$?
exit "$result"
""",
        )

    def test_restore_finishes_only_after_restart_and_readiness(self):
        result, trace = self.restore_case()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace, ["restore", "restart-service", "ready", "finish-restore"])

    def test_failed_restart_cannot_mark_service_restored(self):
        result, trace = self.restore_case(restart_rc=23)
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(trace, ["restore", "restart-service"])

    def test_failed_readiness_cannot_mark_service_restored(self):
        result, trace = self.restore_case(ready_rc=24)
        self.assertEqual(result.returncode, 24, result.stderr)
        self.assertEqual(trace, ["restore", "restart-service", "ready"])

    def test_failed_config_restore_cannot_restart_or_finish(self):
        result, trace = self.restore_case(config_rc=22)
        self.assertEqual(result.returncode, 22, result.stderr)
        self.assertEqual(trace, ["restore"])

    def receipt_binding_case(self, provider="studio", catalog_hash="a" * 64):
        key = {"provider_id": provider, "receipt_pubkey": base64.b64encode(b"p" * 32).decode()}
        catalog = {"catalog_id": "signed-catalog", "models": [{"model_id": "artifact", "sha256": catalog_hash}]}
        market = {"target_artifacts": {"alias": {"model_id": "artifact", "sha256": "a" * 64}}}
        return self.run_shell(
            ["fetch_receipt_binding"],
            """
HB_PROVIDER=studio
coordinator_url() { printf 'https://coordinator.example'; }
http_get() {
  case "$1" in
    https://coordinator.example/v1/receipt-keys/studio) cp "$OPS_TMP_DIR/key.json" "$2";;
    https://coordinator.example/catalog/current) cp "$OPS_TMP_DIR/catalog.json" "$2";;
    *) return 99;;
  esac
  printf 200
}
fetch_receipt_binding alias
cat "$OPS_TMP_DIR/receipt-binding.json"
""",
            files={"key.json": json.dumps(key), "catalog.json": json.dumps(catalog), "market.json": json.dumps(market)},
        )[0]

    def test_receipt_binding_uses_bound_provider_and_qualified_artifact(self):
        result = self.receipt_binding_case()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {
            "provider_key_fingerprint": "ed25519-sha256:" + hashlib.sha256(b"p" * 32).hexdigest(),
            "model_hash": "a" * 64, "catalog_id": "signed-catalog",
        })

    def test_receipt_binding_rejects_other_provider_or_catalog_artifact(self):
        self.assertNotEqual(self.receipt_binding_case(provider="other").returncode, 0)
        self.assertNotEqual(self.receipt_binding_case(catalog_hash="b" * 64).returncode, 0)

    def test_failed_host_check_stops_even_when_caller_tests_return_code(self):
        result, trace = self.run_shell(
            ["verify_installed_cli"],
            """
studio_ssh() { trace host_check; return 27; }
studio_command() { trace forbidden_command; return 0; }
result=0
verify_installed_cli || result=$?
exit "$result"
""",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(trace, ["host_check"])

    def test_failed_status_read_stops_preflight_before_process_inspection(self):
        result, trace = self.run_shell(
            ["studio_preflight"],
            """
verify_installed_cli() { trace installed_provenance; }
read_studio_status() { trace status_read; return 28; }
status_pid() { trace forbidden_pid; printf 42; }
studio_command() { trace forbidden_command; return 0; }
result=0
studio_preflight "$OPS_TMP_DIR/status.json" || result=$?
exit "$result"
""",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(trace, ["installed_provenance", "status_read"])

    def cleanup_case(self, recovery_rc=0, signal=False):
        command = "kill -TERM $$" if signal else "exit 17"
        return self.run_shell(
            ["campaign_cleanup"],
            f"""
studio_helper() {{ [ "$1" = inspect ]; cat "$FIXTURE"; }}
load_journal_context() {{ trace load_journal; }}
verify_installed_cli() {{ trace installed_provenance; }}
restore_provider() {{ trace restore_provider; return {recovery_rc}; }}
remove_remote_scratch() {{ trace scratch_cleanup; }}
trap campaign_cleanup EXIT
trap 'exit 143' TERM
{command}
""",
            {"status": "serving_first", "restore_required": True},
        )

    def test_failed_campaign_restores_and_chains_common_cleanup(self):
        result, trace = self.cleanup_case()
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertIn("restore_provider", trace)
        self.assertEqual(trace[-1], "common_cleanup")

    def test_failed_recovery_is_not_success_and_releases_controller_resources(self):
        result, trace = self.cleanup_case(recovery_rc=25)
        self.assertEqual(result.returncode, 70, result.stderr)
        self.assertIn("restore_provider", trace)
        self.assertEqual(trace[-1], "common_cleanup")

    def test_term_runs_recovery_before_controller_cleanup(self):
        result, trace = self.cleanup_case(signal=True)
        self.assertEqual(result.returncode, 143, result.stderr)
        self.assertLess(trace.index("restore_provider"), trace.index("common_cleanup"))

    def test_pre_journal_failure_cleans_scratch_without_inventing_recovery(self):
        result, trace = self.run_shell(
            ["campaign_cleanup"],
            """
studio_helper() { [ "$1" = inspect ]; cat "$FIXTURE"; }
load_journal_context() { trace unexpected_journal; return 99; }
restore_provider() { trace unexpected_restore; return 99; }
remove_remote_scratch() { trace scratch_cleanup; }
trap campaign_cleanup EXIT
exit 17
""",
            {"status": "absent", "restore_required": False},
        )
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertEqual(trace, ["scratch_cleanup", "common_cleanup"])

    def handback_case(self, text):
        return self.run_shell(
            ["written_handoff_sha"],
            """
QWEN_E2E_WRITTEN_HANDBACK="$OPS_TMP_DIR/handoff.md"
written_handoff_sha 1.8.260
""",
            files={"handoff.md": text},
        )[0]

    def test_explicit_markdown_handback_is_accepted(self):
        result = self.handback_case(
            "- **2026-10-20 10:00Z Studio released by Claude**: "
            "signed 1.8.260; original provider is buyer-serving.\n"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout.strip(), r"^[0-9a-f]{64}$")

    def test_quoted_or_negated_handback_instructions_are_not_release(self):
        records = [
            '- **STUDIO LOCK:** do NOT start until this file records '
            '"1.8.260 owner pin removed" or "Studio released by Claude".\n',
            "- Wait for Studio released by Claude before starting.\n",
            "- Studio released by Claude has not happened.\n",
            "- 1.8.260 owner pin removed is the required future handback.\n",
        ]
        for record in records:
            with self.subTest(record=record):
                self.assertNotEqual(self.handback_case(record).returncode, 0)

    def test_later_reservation_revokes_handback(self):
        for reservation in (
            "- Studio reserved by another campaign.\n",
            "- **STUDIO LOCK:** another campaign now owns the provider.\n",
        ):
            with self.subTest(reservation=reservation):
                result = self.handback_case("Studio released by Claude\n" + reservation)
                self.assertNotEqual(result.returncode, 0)

    def test_unrelated_progress_does_not_invalidate_release_binding(self):
        release = "1.8.260 owner pin removed\n"
        before = self.handback_case(release)
        after = self.handback_case(release + "- Recorder unit tests passed.\n")
        self.assertEqual(before.returncode, 0, before.stderr)
        self.assertEqual(after.returncode, 0, after.stderr)
        self.assertEqual(before.stdout, after.stdout)


if __name__ == "__main__":
    unittest.main()
