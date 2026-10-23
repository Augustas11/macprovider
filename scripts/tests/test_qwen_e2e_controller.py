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
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CONTROLLER = ROOT / "scripts/ops/qwen-opencode-e2e.sh"
CATALOG = ROOT / "scripts/ops/catalog-activate.sh"
COMMON = ROOT / "scripts/ops/lib/common.sh"


def shell_function(path, name):
    # Select the actual function, excluding entrypoint dispatch and ops.env.
    source = path.read_text(encoding="utf-8")
    match = re.search(r"^" + re.escape(name) + r"\(\) \{.*?^\}", source, re.M | re.S)
    if match is None:
        raise AssertionError("Missing shell function: " + name)
    return match.group(0)


class QwenE2EControllerTests(unittest.TestCase):
    def run_shell(self, names, body, journal=None, files=None, source=CONTROLLER):
        with tempfile.TemporaryDirectory(prefix="qwen-controller-test-") as directory:
            root = Path(directory)
            journal_file = root / "fixture.json"
            journal_file.write_text(json.dumps(journal or {}), encoding="utf-8")
            for name, text in (files or {}).items():
                (root / name).write_text(text, encoding="utf-8")
            definitions = "\n".join(shell_function(source, name) for name in names)
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
NATIVE_PROFILE=qwen36-native-mtp
DSV4_PROFILE=dsv4-flash-window
TRANSACTION_PROFILE=opencode-dual-30b
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

    def test_legacy_controller_routes_native_journal_away_from_generic_restore(self):
        native = {
            "profile": "qwen36-native-mtp", "status": "serving_target",
            "restore_required": True,
        }
        result, _ = self.run_shell(
            ["gather"],
            '''
NATIVE_PROFILE=qwen36-native-mtp
DSV4_PROFILE=dsv4-flash-window
studio_helper() { [ "$1" = inspect ]; cat "$FIXTURE"; }
gather
printf '%s\n' "$NEXT_KIND" "$NEXT_CMD" "$NEXT_REASON"
''',
            native,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertEqual(lines[:2], ["blocked", ""])
        self.assertIn("catalog-activate:qwen_restore", lines[2])

        refused, trace = self.run_shell(
            ["run_restore"],
            '''
studio_helper() { [ "$1" = inspect ]; cat "$FIXTURE"; }
load_journal_context() { trace forbidden_load; }
run_restore
''',
            native,
        )
        self.assertNotEqual(refused.returncode, 0)
        self.assertNotIn("forbidden_load", trace)
        self.assertTrue(any("catalog controller" in row for row in trace), trace)

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

    def test_native_profile_requires_mtp_and_continuous_batching(self):
        valid = {
            "native_mtp": {"enabled": True, "mode": "eligible"},
            "continuous_batching": {"active": True},
        }
        for mutate, expected in (
            (lambda d: d["native_mtp"].update(mode="disabled"), False),
            (lambda d: d["continuous_batching"].update(active=False), False),
            (lambda d: None, True),
        ):
            document = json.loads(json.dumps(valid))
            mutate(document)
            result, _ = self.run_shell(
                ["validate_native_target_status"],
                """
NATIVE_TARGET_KEY=qwen/qwen3.6-35b-a3b
validate_status() { :; }
validate_native_target_status "$FIXTURE" 41
""",
                document,
            )
            self.assertEqual(result.returncode == 0, expected, result.stderr)

    def test_native_profile_has_no_opencode_or_legacy_target_preflight(self):
        function = shell_function(CONTROLLER, "run_native_mtp_campaign")
        for forbidden in ("QWEN_E2E_OPENCODE", "run_recorder", "REMOTE_RECORDER=\"$REMOTE_SCRATCH/opencode",
                          "TARGET_ONE", "TARGET_TWO", "fetch_market"):
            self.assertNotIn(forbidden, function)
        self.assertIn("fetch_native_mtp_market", function)
        self.assertEqual(function.count('"$OPS_DIR/catalog-activate.sh" _gateway-proof'), 1)
        self.assertIn("checkpoint_remote proof_complete", function)
        self.assertIn('validate_buyer_token_file "$BUYER_TOKEN_FILE"', function)
        self.assertIn("QWEN_E2E_WRITTEN_HANDBACK BUYER_TOKEN_FILE", function)
        self.assertIn("verify_published_release_identity", function)
        self.assertLess(function.index("load_live_context"),
                        function.index("validate_native_release_binding"))
        self.assertLess(function.index("--purpose catalog-activate:qwen_restore"),
                        function.index("studio_helper prepare"))
        self.assertLess(function.index('"$OPS_DIR/catalog-activate.sh" _gateway-proof'),
                        function.index("restore_provider"))

    def test_dsv4_window_status_requires_one_slot_with_cb_and_mtp_off(self):
        valid = {
            "native_mtp": {"enabled": False, "mode": "disabled"},
            "continuous_batching": {"active": False},
            "capacity": {"max_concurrency": 1},
        }
        for mutate, expected in (
            (lambda d: d["native_mtp"].update(enabled=True, mode="eligible"), False),
            (lambda d: d["continuous_batching"].update(active=True), False),
            (lambda d: d["capacity"].update(max_concurrency=4), False),
            (lambda d: d.pop("capacity"), False),
            (lambda d: None, True),
        ):
            document = json.loads(json.dumps(valid))
            mutate(document)
            result, _ = self.run_shell(
                ["validate_dsv4_target_status"],
                """
DSV4_TARGET_KEY=deepseek/deepseek-v4-flash
validate_status() { :; }
validate_dsv4_target_status "$FIXTURE" 41
""",
                document,
            )
            self.assertEqual(result.returncode == 0, expected, result.stderr)

    def test_dsv4_window_restore_requires_glm_with_cb_and_native_mtp(self):
        valid = {"native_mtp": {"enabled": True, "mode": "active"}, "continuous_batching": {"active": True}}
        for mutate, expected in (
            (lambda d: d["native_mtp"].update(mode="disabled"), False),
            (lambda d: d["continuous_batching"].update(active=False), False),
            (lambda d: None, True),
        ):
            document = json.loads(json.dumps(valid))
            mutate(document)
            result, _ = self.run_shell(
                ["validate_glm_restored_status"],
                """
GLM_INCUMBENT=zai-org/glm-5.3-flash
validate_status() { :; }
validate_glm_restored_status "$FIXTURE"
""",
                document,
            )
            self.assertEqual(result.returncode == 0, expected, result.stderr)

    def test_dsv4_window_order_imports_pins_and_restores(self):
        function = shell_function(CONTROLLER, "run_dsv4_window")
        for forbidden in ("QWEN_E2E_OPENCODE", "run_recorder", "fetch_market ", "_gateway-proof"):
            self.assertNotIn(forbidden, function)
        self.assertIn("require_catalog_lock catalog-activate:buyer_ux_conformance_owed", function)
        self.assertIn('validate_buyer_token_file "$BUYER_TOKEN_FILE"', function)
        self.assertIn("verify_published_release_identity", function)
        order = [
            "fetch_dsv4_market",
            'studio_helper prepare --profile "$DSV4_PROFILE"',
            'models import "$DSV4_TARGET_KEY" --from "$DSV4_IMPORT_DIR"',
            'emit_recommendation "$DSV4_TARGET_KEY"',
            "begin_adoption_remote adopting_target",
            "adopt_recommendation",
            "checkpoint_remote serving_target",
            "studio_helper dsv4-window-settings",
            'restart_and_wait "$DSV4_TARGET_KEY"',
            "validate_dsv4_target_status",
            "buyer_ux_conformance.py\" run",
            "checkpoint_remote proof_complete",
            "restore_provider",
            'validate_glm_restored_status "$OPS_TMP_DIR/restore-after.json"',
        ]
        positions = [function.index(item) for item in order]
        self.assertEqual(positions, sorted(positions))
        # The conformance record goes to the ops state, never the checkout.
        self.assertIn('--record "$record"', function)
        restore = shell_function(CONTROLLER, "run_dsv4_restore")
        self.assertIn("require_catalog_lock catalog-activate:dsv4_restore", restore)
        self.assertIn('= "$DSV4_PROFILE" ]', restore)

    def test_catalog_routes_dsv4_journal_to_its_restore_before_normal_steps(self):
        gather = shell_function(CATALOG, "gather")
        self.assertIn('"$qwen_profile" = "$DSV4_WINDOW_PROFILE"', gather)
        self.assertIn("qwen-opencode-e2e.sh _catalog-dsv4-restore", gather)
        self.assertLess(gather.index("_catalog-dsv4-restore"), gather.index("gather_buyer_ux_conformance"))
        owed = shell_function(CATALOG, "gather_buyer_ux_conformance_owed")
        self.assertIn("qwen-opencode-e2e.sh _catalog-dsv4-conformance", owed)
        self.assertIn("$DSV4_WINDOW_DOWNTIME", owed)

    def test_buyer_token_must_be_owner_only_regular_file(self):
        result, _ = self.run_shell(
            ["validate_buyer_token_file"],
            """
chmod 600 "$FIXTURE"
validate_buyer_token_file "$FIXTURE"
chmod 644 "$FIXTURE"
if validate_buyer_token_file "$FIXTURE"; then exit 9; fi
""",
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_native_profile_binds_committed_admission_release_identity(self):
        source = CONTROLLER.read_text(encoding="utf-8")
        self.assertIn("NATIVE_PROFILE=qwen36-native-mtp", source)
        self.assertNotIn("NATIVE_RELEASE_VERSION=", source)
        release = {
            "schema_version": "macprovider.native-mtp-admission-release-input.v1",
            "release_id": "signed-release",
            "entry": {
                "reproducible_build_sha256": "a" * 64,
                "live_executable_cdhash": "b" * 40,
            },
        }
        result, _ = self.run_shell(
            ["validate_native_release_binding"],
            """
REPO_ROOT="$OPS_TMP_DIR"
NATIVE_ADMISSION_RELEASE=admission.json
LIVE_RELEASE=signed-release HB_VERSION=1.8.261 HB_SHA="$(printf 'a%.0s' {1..64})"
HB_CDHASH="$(printf 'b%.0s' {1..40})" HB_TEAM=TEAM HB_IDENTIFIER=identifier
RELEASE_TEAM_ID=TEAM RELEASE_SIGNING_IDENTIFIER=identifier
git() { :; }
validate_native_release_binding
HB_SHA="$(printf 'c%.0s' {1..64})"
if validate_native_release_binding; then exit 9; fi
HB_SHA="$(printf 'a%.0s' {1..64})" LIVE_RELEASE=other-release
if validate_native_release_binding; then exit 10; fi
""",
            files={"admission.json": json.dumps(release)},
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_decode_path_admission_accepts_any_signed_cli_running_the_admitted_decode_path(self):
        """SPEC-048-R013 (0.1.51): a new CLI cut with the same decode path
        needs no identity rebind; a different decode path is refused."""
        release = {
            "schema_version": "macprovider.native-mtp-admission-release-input.v1",
            "release_id": "signed-release",
            "provider_decode_path_digest": "d" * 64,
            "entry": {
                "reproducible_build_sha256": "a" * 64,
                "live_executable_cdhash": "b" * 40,
            },
        }
        status = {"build_identity": {"decode_path_digest": "d" * 64}}
        changed = {"build_identity": {"decode_path_digest": "e" * 64}}
        result, _ = self.run_shell(
            ["validate_native_release_binding"],
            """
REPO_ROOT="$OPS_TMP_DIR"
NATIVE_ADMISSION_RELEASE=admission.json
LIVE_RELEASE=signed-release HB_VERSION=1.8.262 HB_SHA="$(printf 'c%.0s' {1..64})"
HB_CDHASH="$(printf 'f%.0s' {1..40})" HB_TEAM=TEAM HB_IDENTIFIER=identifier
RELEASE_TEAM_ID=TEAM RELEASE_SIGNING_IDENTIFIER=identifier
git() { :; }
cp "$OPS_TMP_DIR/same.json" "$OPS_TMP_DIR/preflight-status.json"
validate_native_release_binding
cp "$OPS_TMP_DIR/changed.json" "$OPS_TMP_DIR/preflight-status.json"
if validate_native_release_binding; then exit 9; fi
rm "$OPS_TMP_DIR/preflight-status.json"
if validate_native_release_binding; then exit 10; fi
cp "$OPS_TMP_DIR/same.json" "$OPS_TMP_DIR/preflight-status.json"
HB_IDENTIFIER=other
if validate_native_release_binding; then exit 11; fi
""",
            files={
                "admission.json": json.dumps(release),
                "same.json": json.dumps(status),
                "changed.json": json.dumps(changed),
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_native_recovery_uses_journal_frozen_release_identity(self):
        restore = shell_function(CONTROLLER, "run_native_mtp_restore")
        self.assertIn("validate_native_journal_release_binding", restore)
        self.assertNotIn("validate_native_release_binding", restore)
        self.assertIn("verify_installed_cli", restore)

    def test_catalog_owns_qwen_mutation_and_recovery_precedes_normal_steps(self):
        source = CATALOG.read_text(encoding="utf-8")
        gather = shell_function(CATALOG, "gather")
        release = shell_function(CATALOG, "release_live_lock")
        self.assertIn('set_next qwen_restore mutate', gather)
        self.assertIn('qwen-opencode-e2e.sh _catalog-qwen36-restore', gather)
        self.assertLess(gather.index("set_next qwen_restore mutate"),
                        gather.index("catalog-release.py"))
        self.assertIn('set_next gateway_proof mutate', gather)
        self.assertIn('qwen-opencode-e2e.sh _catalog-qwen36-proof', gather)
        self.assertNotIn('qwen-opencode-e2e.sh next --run', source)
        self.assertIn("require_qwen_proof_lock", shell_function(CATALOG, "gateway_proof"))
        self.assertIn('catalog-activate:qwen_restore', release)
        self.assertIn('live-lock.sh" acquire "$owner"', release)
        self.assertIn('active Qwen restoration journal is unreadable', gather)
        self.assertLess(gather.index('active Qwen restoration journal is unreadable'),
                        gather.index('fact origin_main_sha'))

    def test_catalog_qwen_marker_is_bound_to_model_release_digest_and_session(self):
        validator = shell_function(CATALOG, "gateway_proof_marker_valid")
        for field in ("proof_model", "catalog_release_id", "catalog_digest",
                      "served_session_sha256", "mtp_forwards_delta"):
            self.assertIn(field, validator)

        marker = {
            "step": "gateway_proof", "served_by_canary": True,
            "request_id": "paid-request", "cb_shared_forward_calls_delta": 1,
            "mtp_forwards_delta": 2, "native_mtp_forward_required": True,
            "proof_model": "qwen/qwen3.6-35b-a3b", "catalog_release_id": "release",
            "catalog_digest": "d" * 64, "served_session_sha256": "e" * 64,
        }
        body = """
marker_path() { printf '%s\n' "$FIXTURE"; }
gateway_proof_marker_valid scope true true qwen/qwen3.6-35b-a3b release "$(printf 'd%.0s' {1..64})"
"""
        accepted, _ = self.run_shell(
            ["gateway_proof_marker_valid"], body, marker, source=CATALOG,
        )
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        pending_body = """
marker_path() { printf '%s\n' "$FIXTURE"; }
mkdir -p "$OPS_TMP_DIR/qwen-gateway-proof"
ln -s "$OPS_TMP_DIR/missing" "$OPS_TMP_DIR/qwen-gateway-proof/qwen-gateway-proof.pending.json"
gateway_proof_marker_valid scope true true qwen/qwen3.6-35b-a3b release "$(printf 'd%.0s' {1..64})"
"""
        pending, _ = self.run_shell(
            ["gateway_proof_marker_valid"], pending_body, marker, source=CATALOG,
        )
        self.assertNotEqual(pending.returncode, 0)
        marker["proof_model"] = "zai-org/glm-5.3-flash"
        rejected, _ = self.run_shell(
            ["gateway_proof_marker_valid"], body, marker, source=CATALOG,
        )
        self.assertNotEqual(rejected.returncode, 0)
        marker["proof_model"] = "qwen/qwen3.6-35b-a3b"
        marker["served_session_sha256"] = "Z" * 64
        rejected, _ = self.run_shell(
            ["gateway_proof_marker_valid"], body, marker, source=CATALOG,
        )
        self.assertNotEqual(rejected.returncode, 0)

    def test_qwen_proof_intent_uses_uuid_and_durable_terminal_resolution(self):
        request_id = str(uuid.uuid4())
        result, trace = self.run_shell(
            ["write_qwen_proof_intent", "validate_qwen_proof_intent",
             "resolve_qwen_proof_intent"],
            f'''
pending="$OPS_TMP_DIR/state/scope/qwen-gateway-proof.pending.json"
OPS_SCOPE=scope; marker_path() {{ printf '%s\n' "$OPS_TMP_DIR/state/scope/gateway_proof.json"; }}
write_qwen_proof_intent "$pending" {request_id} qwen/qwen3.6-35b-a3b release \
  "$(printf 'd%.0s' {{1..64}})" "$(printf 'e%.0s' {{1..64}})" 7 8 true 9
read -r rid stored_session_hash <<< "$(validate_qwen_proof_intent "$pending" \
  qwen/qwen3.6-35b-a3b release "$(printf 'd%.0s' {{1..64}})")"
[ "$rid" = {request_id} ] && [ "$stored_session_hash" = "$(printf 'e%.0s' {{1..64}})" ]
python3 -c 'import os,stat,sys; raise SystemExit(stat.S_IMODE(os.lstat(sys.argv[1]).st_mode) != 0o600)' "$pending"
resolve_qwen_proof_intent "$pending" accepted_with_counter_evidence
[ ! -e "$pending" ]
python3 - "$OPS_TMP_DIR/state/scope/qwen-gateway-proof-attempts/{request_id}.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["resolution"] == "accepted_with_counter_evidence"
assert d["intent"]["request_id"] == "{request_id}"
PY
# Simulate a crash after the archive rename but before pending unlink. The
# first durable terminal result remains authoritative on recovery.
write_qwen_proof_intent "$pending" {request_id} qwen/qwen3.6-35b-a3b release \
  "$(printf 'd%.0s' {{1..64}})" "$(printf 'e%.0s' {{1..64}})" 7 8 true 9
resolve_qwen_proof_intent "$pending" wrong_provider
[ ! -e "$pending" ]
python3 - "$OPS_TMP_DIR/state/scope/qwen-gateway-proof-attempts/{request_id}.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))["resolution"] == "accepted_with_counter_evidence"
PY
trace resolved
''',
            source=CATALOG,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace, ["resolved"])

    def test_old_qwen_intent_reconciles_missing_row_before_fresh_send(self):
        request_id = str(uuid.uuid4())
        result, trace = self.run_shell(
            ["write_qwen_proof_intent", "validate_qwen_proof_intent",
             "resolve_qwen_proof_intent", "reconcile_qwen_proof_intent"],
            f'''
pending="$OPS_TMP_DIR/state/scope/qwen-gateway-proof.pending.json"
OPS_SCOPE=scope; marker_path() {{ printf '%s\n' "$OPS_TMP_DIR/state/scope/gateway_proof.json"; }}
write_qwen_proof_intent "$pending" {request_id} qwen/qwen3.6-35b-a3b release \
  "$(printf 'd%.0s' {{1..64}})" "$(printf 'e%.0s' {{1..64}})" 7 8 true 9
pearl_ssh() {{ trace query_old_request; }}
sleep() {{ :; }}
reconcile_qwen_proof_intent "$pending" qwen/qwen3.6-35b-a3b release \
  "$(printf 'd%.0s' {{1..64}})" /db /sqlite
[ ! -e "$pending" ]
python3 - "$OPS_TMP_DIR/state/scope/qwen-gateway-proof-attempts/{request_id}.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))["resolution"] == "request_log_missing"
PY
trace fresh_send
''',
            source=CATALOG,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace, ["query_old_request"] * 6 + ["fresh_send"])

    def test_pending_with_exact_durable_marker_recovers_without_query_or_send(self):
        request_id = str(uuid.uuid4())
        result, trace = self.run_shell(
            ["write_qwen_proof_intent", "validate_qwen_proof_intent",
             "resolve_qwen_proof_intent", "qwen_marker_matches_pending",
             "qwen_resolution_status", "reconcile_qwen_proof_intent"],
            f'''
pending="$OPS_TMP_DIR/state/scope/qwen-gateway-proof.pending.json"
marker="$OPS_TMP_DIR/state/scope/gateway_proof.json"
OPS_SCOPE=scope; marker_path() {{ printf '%s\n' "$OPS_TMP_DIR/state/scope/gateway_proof.json"; }}
write_qwen_proof_intent "$pending" {request_id} qwen/qwen3.6-35b-a3b release \
  "$(printf 'd%.0s' {{1..64}})" "$(printf 'e%.0s' {{1..64}})" 7 8 true 9
python3 - "$marker" <<'PY'
import json, os, sys
d={{"step":"gateway_proof","request_id":"{request_id}","sent_request_id":"{request_id}",
"proof_model":"qwen/qwen3.6-35b-a3b","catalog_release_id":"release","catalog_digest":"{'d' * 64}",
"served_session_sha256":"{'e' * 64}","served_by_canary":True,"native_mtp_forward_required":True,
"mtp_forwards_delta":1,"cb_shared_forward_calls_delta":1}}
json.dump(d,open(sys.argv[1],"w")); os.chmod(sys.argv[1],0o600)
PY
pearl_ssh() {{ trace forbidden_query; return 9; }}
out="$(reconcile_qwen_proof_intent "$pending" qwen/qwen3.6-35b-a3b release \
  "$(printf 'd%.0s' {{1..64}})" /db /sqlite)"
[ "$out" = recovered_success ] && [ ! -e "$pending" ] && [ -f "$marker" ]
# Simulate archive rename succeeding before pending unlink. The accepted
# archive plus exact marker clears the recreated pending state without query.
write_qwen_proof_intent "$pending" {request_id} qwen/qwen3.6-35b-a3b release \
  "$(printf 'd%.0s' {{1..64}})" "$(printf 'e%.0s' {{1..64}})" 7 8 true 9
out="$(reconcile_qwen_proof_intent "$pending" qwen/qwen3.6-35b-a3b release \
  "$(printf 'd%.0s' {{1..64}})" /db /sqlite)"
[ "$out" = recovered_success ] && [ ! -e "$pending" ] && [ -f "$marker" ]
trace recovered_without_send
''',
            source=CATALOG,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace, ["recovered_without_send"])

    def test_old_qwen_intent_uses_stored_session_after_provider_session_changes(self):
        request_id = str(uuid.uuid4())
        session = "session-42"
        session_hash = hashlib.sha256(session.encode()).hexdigest()
        result, trace = self.run_shell(
            ["write_qwen_proof_intent", "validate_qwen_proof_intent",
             "resolve_qwen_proof_intent", "reconcile_qwen_proof_intent"],
            f'''
pending="$OPS_TMP_DIR/state/scope/qwen-gateway-proof.pending.json"
OPS_SCOPE=scope; marker_path() {{ printf '%s\n' "$OPS_TMP_DIR/state/scope/gateway_proof.json"; }}
write_qwen_proof_intent "$pending" {request_id} qwen/qwen3.6-35b-a3b release \
  "$(printf 'd%.0s' {{1..64}})" {session_hash} 7 8 true 9
# The retry has adopted the provider under a different current session. The
# old attempt is attributed against its stored session hash.
current_session_hash="$(printf 'f%.0s' {{1..64}})"
[ "$current_session_hash" != {session_hash} ]
pearl_ssh() {{ printf '%s\n' {session}; }}
reconcile_qwen_proof_intent "$pending" qwen/qwen3.6-35b-a3b release \
  "$(printf 'd%.0s' {{1..64}})" /db /sqlite
python3 - "$OPS_TMP_DIR/state/scope/qwen-gateway-proof-attempts/{request_id}.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))["resolution"] == "accepted_missing_counter_evidence"
PY
trace reconciled_without_success
''',
            source=CATALOG,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace, ["reconciled_without_success"])

    def test_malformed_or_context_drifted_qwen_intent_refuses_without_query(self):
        request_id = str(uuid.uuid4())
        result, trace = self.run_shell(
            ["write_qwen_proof_intent", "validate_qwen_proof_intent",
             "resolve_qwen_proof_intent", "reconcile_qwen_proof_intent"],
            f'''
pending="$OPS_TMP_DIR/state/scope/qwen-gateway-proof.pending.json"
OPS_SCOPE=scope; marker_path() {{ printf '%s\n' "$OPS_TMP_DIR/state/scope/gateway_proof.json"; }}
write_qwen_proof_intent "$pending" {request_id} qwen/qwen3.6-35b-a3b release \
  "$(printf 'd%.0s' {{1..64}})" "$(printf 'e%.0s' {{1..64}})" 7 8 true 9
pearl_ssh() {{ trace forbidden_query; }}
if (reconcile_qwen_proof_intent "$pending" qwen/qwen3.6-35b-a3b other-release \
  "$(printf 'd%.0s' {{1..64}})" /db /sqlite); then
  exit 9
fi
[ -f "$pending" ]
trace pending_retained
''',
            source=CATALOG,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace[-1], "pending_retained")
        self.assertNotIn("forbidden_query", trace)

    def test_qwen_proof_orders_intent_before_curl_and_keeps_it_on_failures(self):
        proof = shell_function(CATALOG, "gateway_proof")
        self.assertIn("uuid.uuid4()", proof)
        self.assertIn('[ "$rid" = "$sent_rid" ]', proof)
        self.assertLess(proof.index("write_qwen_proof_intent"), proof.index("curl -sS"))
        self.assertLess(proof.index("curl -sS"), proof.index("mark_done"))
        self.assertLess(proof.index("mark_done"), proof.index("fsync_file_and_parent"))
        self.assertLess(proof.index("fsync_file_and_parent"),
                        proof.index("resolve_qwen_proof_intent"))
        self.assertIn("discard_file_durably", proof)
        self.assertNotIn('discard_file_durably "$(marker_path "$OPS_SCOPE" gateway_proof)" || true',
                         proof)
        self.assertEqual(proof.count("resolve_qwen_proof_intent"), 1)

    def test_catalog_qwen_proof_requires_authenticated_durable_lock(self):
        result, _ = self.run_shell(
            ["require_qwen_proof_lock"],
            """
OPS_DIR="$OPS_TMP_DIR"
MACPROVIDER_OPS_ENTRYPOINT=1 MACPROVIDER_OPS_OWNER=owner
cat > "$OPS_DIR/live-lock.sh" <<'SH'
#!/bin/sh
printf '%s\n' '{"held":true,"lock":{"owner":"owner","purpose":"catalog-activate:qwen_restore"}}'
SH
chmod 700 "$OPS_DIR/live-lock.sh"
require_qwen_proof_lock
cat > "$OPS_DIR/live-lock.sh" <<'SH'
#!/bin/sh
printf '%s\n' '{"held":true,"lock":{"owner":"owner","purpose":"catalog-activate:gateway_proof"}}'
SH
if (require_qwen_proof_lock); then exit 9; fi
""",
            source=CATALOG,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_catalog_restore_lock_blocks_normal_steps_without_exact_recovered_journal(self):
        cases = (
            (False, {}),
            (True, {"status": "absent", "restore_required": False}),
            (True, {"profile": "other", "status": "restored", "restore_required": False}),
        )
        for configured, journal in cases:
            body = '''
REPO_ROOT="$OPS_TMP_DIR"
AUTOTUNE=autotune
QWEN_NATIVE_PROFILE=qwen36-native-mtp
mkdir -p "$REPO_ROOT/$AUTOTUNE"
printf '%s\n' '{"release_id":"release","feeds":{}}' > "$REPO_ROOT/$AUTOTUNE/release.json"
origin_main_sha() { printf '%040d\n' 0; }
git() { printf '%040d\n' 0; }
live_lock_purpose() { printf '%s\n' "${LOCK_PURPOSE-catalog-activate:qwen_restore}"; }
qwen_journal_probe() { cat "$FIXTURE"; }
qwen_intent_probe() { printf '%s\n' '{"status":"absent"}'; }
qwen_scratch_probe() { printf '%s\n' '{"scratch_absent":true}'; }
step() { :; }
'''
            body += ('QWEN_E2E_JOURNAL=/journal\n' if configured
                     else 'unset QWEN_E2E_JOURNAL\n')
            body += '''
gather
printf '%s\n' "$NEXT_KIND" "$NEXT_CMD" "$NEXT_REASON"
'''
            result, _ = self.run_shell(["gather"], body, journal, source=CATALOG)
            with self.subTest(configured=configured, journal=journal):
                self.assertEqual(result.returncode, 0, result.stderr)
                lines = result.stdout.splitlines()
                self.assertEqual(lines[:2], ["blocked", ""])
                self.assertIn("durable restoration lock", lines[2])

        recovered = {
            "profile": "qwen36-native-mtp", "status": "restored",
            "restore_required": False,
        }
        result, _ = self.run_shell(
            ["gather"],
            '''
REPO_ROOT="$OPS_TMP_DIR"
AUTOTUNE=autotune
QWEN_NATIVE_PROFILE=qwen36-native-mtp
QWEN_E2E_JOURNAL=/journal
mkdir -p "$REPO_ROOT/$AUTOTUNE"
printf '%s\n' '{"release_id":"release","feeds":{}}' > "$REPO_ROOT/$AUTOTUNE/release.json"
origin_main_sha() { printf '%040d\n' 0; }
git() { printf '%040d\n' 0; }
live_lock_purpose() { printf '%s\n' "${LOCK_PURPOSE-catalog-activate:qwen_restore}"; }
qwen_journal_probe() { cat "$FIXTURE"; }
qwen_intent_probe() { printf '%s\n' '{"status":"absent"}'; }
qwen_scratch_probe() { printf '%s\n' '{"scratch_absent":true}'; }
step() { :; }
gather
printf '%s\n' "$NEXT_ID" "$NEXT_KIND" "$NEXT_CMD"
''',
            recovered, source=CATALOG,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            "qwen_lock_reconcile", "mutate",
            "/unused/ops/catalog-activate.sh _qwen-lock-reconcile",
        ])

        scratch_present_body = '''
REPO_ROOT="$OPS_TMP_DIR"; AUTOTUNE=autotune; QWEN_NATIVE_PROFILE=qwen36-native-mtp
QWEN_E2E_JOURNAL=/journal
mkdir -p "$REPO_ROOT/$AUTOTUNE"
printf '%s\n' '{"release_id":"release","feeds":{}}' > "$REPO_ROOT/$AUTOTUNE/release.json"
origin_main_sha() { printf '%040d\n' 0; }; git() { printf '%040d\n' 0; }
live_lock_purpose() { printf '%s\n' catalog-activate:qwen_restore; }
qwen_journal_probe() { cat "$FIXTURE"; }
qwen_intent_probe() { printf '%s\n' '{"status":"absent"}'; }
qwen_scratch_probe() { printf '%s\n' '{"scratch_absent":false}'; }
step() { :; }
gather
printf '%s\n' "$NEXT_ID" "$NEXT_CMD"
'''
        scratch_present, _ = self.run_shell(
            ["gather"], scratch_present_body, recovered, source=CATALOG,
        )
        self.assertEqual(scratch_present.returncode, 0, scratch_present.stderr)
        self.assertEqual(scratch_present.stdout.splitlines(), [
            "qwen_restore",
            "/unused/ops/qwen-opencode-e2e.sh _catalog-qwen36-restore",
        ])

    def test_prejournal_intent_is_durable_before_lock_and_routes_only_absent_journal(self):
        campaign = shell_function(CONTROLLER, "run_native_mtp_campaign")
        self.assertLess(campaign.index("write_native_intent"),
                        campaign.index("--purpose catalog-activate:qwen_restore"))
        self.assertLess(campaign.index("studio_helper prepare"),
                        campaign.index("native_intent_matches_journal"))
        self.assertLess(campaign.index("native_intent_matches_journal"),
                        campaign.index("clear_native_intent"))

        base = '''
REPO_ROOT="$OPS_TMP_DIR"; AUTOTUNE=autotune; QWEN_NATIVE_PROFILE=qwen36-native-mtp
QWEN_E2E_JOURNAL=/journal
mkdir -p "$REPO_ROOT/$AUTOTUNE"
printf '%s\n' '{"release_id":"release","feeds":{}}' > "$REPO_ROOT/$AUTOTUNE/release.json"
origin_main_sha() { printf '%040d\n' 0; }; git() { printf '%040d\n' 0; }
live_lock_purpose() { printf '%s\n' "${LOCK_PURPOSE-catalog-activate:qwen_restore}"; }
qwen_journal_probe() { cat "$FIXTURE"; }
qwen_intent_probe() { printf '%s\n' '{"schema_version":"macprovider.qwen_native_intent.v1"}'; }
qwen_scratch_probe() { printf '%s\n' '{"scratch_absent":true}'; }
step() { :; }
gather
printf '%s\n' "$NEXT_ID" "$NEXT_CMD"
'''
        absent, _ = self.run_shell(
            ["gather"], base, {"status": "absent", "restore_required": False},
            source=CATALOG,
        )
        self.assertEqual(absent.returncode, 0, absent.stderr)
        self.assertEqual(absent.stdout.splitlines(), [
            "qwen_prejournal_reconcile",
            "/unused/ops/qwen-opencode-e2e.sh _catalog-qwen36-prejournal-reconcile",
        ])
        for purpose in ("catalog-activate:gateway_proof", ""):
            interrupted, _ = self.run_shell(
                ["gather"], f"LOCK_PURPOSE={shlex.quote(purpose)}\n" + base,
                {"status": "absent", "restore_required": False}, source=CATALOG,
            )
            self.assertEqual(interrupted.returncode, 0, interrupted.stderr)
            self.assertEqual(interrupted.stdout.splitlines()[0],
                             "qwen_prejournal_reconcile")
        env_unset = base.replace(
            "QWEN_E2E_JOURNAL=/journal",
            'unset QWEN_E2E_JOURNAL\nOPS_STATE_DIR="$OPS_TMP_DIR/state"\n'
            'mkdir -p "$OPS_STATE_DIR"\n'
            'touch "$OPS_STATE_DIR/qwen-native-mtp-transaction-intent.json"',
        )
        env_unset = env_unset.replace(
            "step() { :; }",
            "qwen_intent_probe() { printf '%s\\n' "
            "'{\"schema_version\":\"macprovider.qwen_native_intent.v1\",\"journal_path\":\"/journal\"}'; }\n"
            "qwen_journal_probe() { bash -c '[ \"$QWEN_E2E_JOURNAL\" = /journal ]' || return; cat \"$FIXTURE\"; }\n"
            "step() { :; }",
        )
        for purpose in ("catalog-activate:gateway_proof", ""):
            interrupted, _ = self.run_shell(
                ["gather"], f"LOCK_PURPOSE={shlex.quote(purpose)}\n" + env_unset,
                {"status": "absent", "restore_required": False}, source=CATALOG,
            )
            self.assertEqual(interrupted.returncode, 0, interrupted.stderr)
            self.assertEqual(interrupted.stdout.splitlines()[0],
                             "qwen_prejournal_reconcile")
        malformed_body = base.replace("qwen_intent_probe() {", "old_qwen_intent_probe() {")
        malformed_body = malformed_body.replace("step() { :; }", "qwen_intent_probe() { return 3; }\nstep() { :; }")
        malformed, _ = self.run_shell(
            ["gather"], malformed_body,
            {"status": "absent", "restore_required": False}, source=CATALOG,
        )
        self.assertEqual(malformed.returncode, 0, malformed.stderr)
        self.assertEqual(malformed.stdout.splitlines()[1], "")
        active, _ = self.run_shell(
            ["gather"], base,
            {"profile": "qwen36-native-mtp", "status": "prepared", "restore_required": True},
            source=CATALOG,
        )
        self.assertEqual(active.returncode, 0, active.stderr)
        self.assertEqual(active.stdout.splitlines()[0], "qwen_restore")
        restored, _ = self.run_shell(
            ["gather"], base,
            {"profile": "qwen36-native-mtp", "status": "restored", "restore_required": False},
            source=CATALOG,
        )
        self.assertEqual(restored.returncode, 0, restored.stderr)
        self.assertEqual(restored.stdout.splitlines()[0], "qwen_restore")
        mismatch, _ = self.run_shell(
            ["gather"], malformed_body,
            {"profile": "qwen36-native-mtp", "status": "prepared", "restore_required": True},
            source=CATALOG,
        )
        self.assertEqual(mismatch.returncode, 0, mismatch.stderr)
        self.assertEqual(mismatch.stdout.splitlines(), ["qwen_prejournal_reconcile", ""])

        reconcile = shell_function(CONTROLLER, "run_native_prejournal_reconcile")
        self.assertLess(reconcile.index("--purpose catalog-activate:gateway_proof"),
                        reconcile.index("clear_native_intent"))
        cleanup = shell_function(CONTROLLER, "campaign_cleanup")
        self.assertLess(cleanup.index("--purpose catalog-activate:gateway_proof"),
                        cleanup.rindex("clear_native_intent"))

    def test_native_prejournal_intent_round_trip_is_strict_and_owner_only(self):
        transaction_id = str(uuid.uuid4())
        result, trace = self.run_shell(
            ["native_intent_path", "write_native_intent", "validate_native_intent"],
            f'''
OPS_STATE_DIR="$OPS_TMP_DIR/state"
write_native_intent {transaction_id} release "$(printf 'a%.0s' {{1..64}})" 1.2.3 provider \
  "$(printf 'b%.0s' {{1..64}})" "$(printf 'c%.0s' {{1..40}})" TEAM identifier \
  "$(printf 'd%.0s' {{1..64}})" /remote/journal /tmp/macprovider-qwen-e2e.test
validate_native_intent > "$OPS_TMP_DIR/validated.json"
python3 -c 'import os,stat,sys; raise SystemExit(stat.S_IMODE(os.lstat(sys.argv[1]).st_mode) != 0o600)' "$(native_intent_path)"
[ "$(json_field "$OPS_TMP_DIR/validated.json" 'd["transaction_id"]')" = {transaction_id} ]
trace valid_intent
''',
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace, ["valid_intent"])

    def test_prejournal_reconcile_rejects_configured_journal_path_drift(self):
        reconcile = shell_function(CONTROLLER, "run_native_prejournal_reconcile")
        self.assertIn('d["journal_path"]', reconcile)
        self.assertIn('= "$QWEN_E2E_JOURNAL"', reconcile)
        self.assertLess(reconcile.index('= "$QWEN_E2E_JOURNAL"'),
                        reconcile.index("studio_helper inspect"))
        restore = shell_function(CONTROLLER, "run_native_mtp_restore")
        self.assertLess(restore.index("native_intent_matches_journal"),
                        restore.index("restore_provider"))
        self.assertLess(restore.index("remove_remote_scratch"),
                        restore.index("clear_native_intent"))

    def test_same_owner_cannot_rebind_or_release_uncertain_catalog_restore_lock(self):
        result, trace = self.run_shell(
            ["acquire_live_lock_for_step", "qwen_native_journal_recovered",
             "live_lock_purpose"],
            '''
OPS_DIR="$OPS_TMP_DIR"
QWEN_NATIVE_PROFILE=qwen36-native-mtp
MACPROVIDER_OPS_OWNER=owner
NEXT_ID=catalog_verify
unset QWEN_E2E_JOURNAL
cat > "$OPS_DIR/live-lock.sh" <<'SH'
#!/bin/sh
if [ "$1" = status ]; then
  printf '%s\n' '{"held":true,"lock":{"owner":"owner","purpose":"catalog-activate:qwen_restore"}}'
else
  printf '%s\n' "$*" >> "$TEST_LOCK_CALLS"
fi
SH
chmod 700 "$OPS_DIR/live-lock.sh"
export TEST_LOCK_CALLS="$OPS_TMP_DIR/lock-calls"
acquire_live_lock_for_step
''',
            source=CATALOG,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(any("valid restored native journal" in row for row in trace), trace)

        released, release_trace = self.run_shell(
            ["release_live_lock", "qwen_native_journal_recovered", "live_lock_purpose"],
            '''
OPS_DIR="$OPS_TMP_DIR"
QWEN_NATIVE_PROFILE=qwen36-native-mtp
OPS_LOCK_OWNER=owner
unset QWEN_E2E_JOURNAL
cat > "$OPS_DIR/live-lock.sh" <<'SH'
#!/bin/sh
if [ "$1" = status ]; then
  printf '%s\n' '{"held":true,"lock":{"owner":"owner","purpose":"catalog-activate:qwen_restore"}}'
else
  printf '%s\n' "$*" >> "$TEST_LOCK_CALLS"
fi
SH
chmod 700 "$OPS_DIR/live-lock.sh"
export TEST_LOCK_CALLS="$OPS_TMP_DIR/lock-calls"
release_live_lock
[ ! -e "$TEST_LOCK_CALLS" ] || exit 88
[ -z "$OPS_LOCK_OWNER" ]
''',
            source=CATALOG,
        )
        self.assertEqual(released.returncode, 0, released.stderr)
        self.assertEqual(release_trace, [])

    def test_surviving_native_intent_keeps_catalog_lock_durable(self):
        for purpose in ("catalog-activate:qwen_restore", "catalog-activate:gateway_proof"):
            result, _ = self.run_shell(
                ["release_live_lock", "qwen_native_journal_recovered",
                 "qwen_native_intent_present", "live_lock_purpose"],
                f'''
OPS_DIR="$OPS_TMP_DIR"; OPS_STATE_DIR="$OPS_TMP_DIR/state"; OPS_LOCK_OWNER=owner
OPS_TMP_DIR="$OPS_TMP_DIR"; QWEN_NATIVE_PROFILE=qwen36-native-mtp
QWEN_E2E_JOURNAL=/journal
mkdir -p "$OPS_STATE_DIR"
touch "$OPS_STATE_DIR/qwen-native-mtp-transaction-intent.json"
qwen_journal_probe() {{ printf '%s\n' '{{"profile":"qwen36-native-mtp","status":"restored","restore_required":false}}'; }}
cat > "$OPS_DIR/live-lock.sh" <<'SH'
#!/bin/sh
if [ "$1" = status ]; then
  printf '%s\n' '{{"held":true,"lock":{{"owner":"owner","purpose":"{purpose}"}}}}'
else
  printf '%s\n' "$*" >> "$TEST_LOCK_CALLS"
fi
SH
chmod 700 "$OPS_DIR/live-lock.sh"
export TEST_LOCK_CALLS="$OPS_TMP_DIR/lock-calls"
release_live_lock
[ -z "$OPS_LOCK_OWNER" ]
if [ {shlex.quote(purpose)} = catalog-activate:qwen_restore ]; then
  [ ! -e "$TEST_LOCK_CALLS" ]
else
  grep -q '^acquire owner --purpose catalog-activate:qwen_restore$' "$TEST_LOCK_CALLS"
  ! grep -q '^release ' "$TEST_LOCK_CALLS"
fi
''',
                source=CATALOG,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

        scratch_present, _ = self.run_shell(
            ["release_live_lock", "qwen_native_journal_recovered",
             "qwen_native_intent_present", "live_lock_purpose"],
            '''
OPS_DIR="$OPS_TMP_DIR"; OPS_STATE_DIR="$OPS_TMP_DIR/state"; OPS_LOCK_OWNER=owner
QWEN_NATIVE_PROFILE=qwen36-native-mtp; QWEN_E2E_JOURNAL=/journal
mkdir -p "$OPS_STATE_DIR"
qwen_journal_probe() { printf '%s\n' '{"profile":"qwen36-native-mtp","status":"restored","restore_required":false}'; }
qwen_scratch_probe() { printf '%s\n' '{"scratch_absent":false}'; }
cat > "$OPS_DIR/live-lock.sh" <<'SH'
#!/bin/sh
if [ "$1" = status ]; then
  printf '%s\n' '{"held":true,"lock":{"owner":"owner","purpose":"catalog-activate:qwen_restore"}}'
else
  printf '%s\n' "$*" >> "$TEST_LOCK_CALLS"
fi
SH
chmod 700 "$OPS_DIR/live-lock.sh"
export TEST_LOCK_CALLS="$OPS_TMP_DIR/lock-calls"
release_live_lock
[ ! -e "$TEST_LOCK_CALLS" ]
[ -z "$OPS_LOCK_OWNER" ]
''',
            source=CATALOG,
        )
        self.assertEqual(scratch_present.returncode, 0, scratch_present.stderr)

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

    def test_native_pre_journal_failure_restores_outer_catalog_lock_only_after_cleanup(self):
        result, trace = self.run_shell(
            ["campaign_cleanup"],
            '''
OPS_DIR="$OPS_TMP_DIR"
MACPROVIDER_OPS_OWNER=owner
TRANSACTION_PROFILE="$NATIVE_PROFILE"
studio_helper() { [ "$1" = inspect ]; cat "$FIXTURE"; }
remove_remote_scratch() { trace scratch_cleanup; }
cleanup_ops() {
  grep -qx 'acquire owner --purpose catalog-activate:gateway_proof' "$TEST_LOCK_CALLS" &&
    trace outer_lock_restored
  trace common_cleanup
}
cat > "$OPS_DIR/live-lock.sh" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_LOCK_CALLS"
SH
chmod 700 "$OPS_DIR/live-lock.sh"
export TEST_LOCK_CALLS="$OPS_TMP_DIR/lock-calls"
trap campaign_cleanup EXIT
exit 17
''',
            {"status": "absent", "restore_required": False},
        )
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertEqual(trace, ["scratch_cleanup", "outer_lock_restored",
                                 "common_cleanup"])

    def test_native_pre_journal_unreadable_retains_durable_lock(self):
        result, trace = self.run_shell(
            ["campaign_cleanup"],
            '''
OPS_DIR="$OPS_TMP_DIR"
MACPROVIDER_OPS_OWNER=owner
TRANSACTION_PROFILE="$NATIVE_PROFILE"
studio_helper() { return 1; }
remove_remote_scratch() { trace scratch_cleanup; }
cleanup_ops() {
  [ ! -e "$TEST_LOCK_CALLS" ] && trace durable_lock_retained
  trace common_cleanup
}
cat > "$OPS_DIR/live-lock.sh" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_LOCK_CALLS"
SH
chmod 700 "$OPS_DIR/live-lock.sh"
export TEST_LOCK_CALLS="$OPS_TMP_DIR/lock-calls"
trap campaign_cleanup EXIT
exit 17
''',
            {"status": "absent", "restore_required": False},
        )
        self.assertEqual(result.returncode, 70, result.stderr)
        self.assertEqual(trace, ["scratch_cleanup", "durable_lock_retained",
                                 "common_cleanup"])

    def test_interrupted_native_cleanup_uses_journal_profile_scratch_names(self):
        journal = {
            "profile": "qwen36-native-mtp",
            "status": "serving_target",
            "restore_required": True,
            "baseline_model": "zai-org/glm-5.3-flash",
            "release_binding": {"binary_version": "1.8.261"},
            "baseline_status": {
                "catalog_version": "release", "catalog_hash": "a" * 64, "pid": 42,
            },
            "market_binding": {"rate_card_version": "rates"},
            "remote_scratch": "/placeholder",
        }
        result, trace = self.run_shell(
            ["campaign_cleanup", "load_journal_context", "set_remote_scratch_paths",
             "remove_remote_scratch"],
            r'''
REMOTE_SCRATCH="$OPS_TMP_DIR/macprovider-qwen-e2e.native"
mkdir -m 700 "$REMOTE_SCRATCH"
printf '{}\n' > "$REMOTE_SCRATCH/qwen36.recommendation.json"
python3 - "$FIXTURE" "$REMOTE_SCRATCH" <<'PY'
import json, sys
path, scratch = sys.argv[1:]
value = json.load(open(path))
value["remote_scratch"] = scratch
json.dump(value, open(path, "w"))
PY
studio_helper() { [ "$1" = inspect ]; cat "$FIXTURE"; }
studio_command() { "$@"; }
verify_installed_cli() { trace installed_provenance; }
restore_provider() { trace restore_provider; }
cleanup_ops() {
  [ ! -e "$REMOTE_SCRATCH" ] && trace scratch_removed
  trace common_cleanup
}
trap campaign_cleanup EXIT
exit 17
''',
            journal,
        )
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertEqual(trace, ["installed_provenance", "restore_provider",
                                 "scratch_removed", "common_cleanup"])

    def test_absent_bound_scratch_cleanup_is_idempotent_for_recovery(self):
        result, trace = self.run_shell(
            ["remove_remote_scratch"],
            r'''
REMOTE_SCRATCH="$OPS_TMP_DIR/macprovider-qwen-e2e.already-removed"
REMOTE_REC_ONE="$REMOTE_SCRATCH/qwen36.recommendation.json"
REMOTE_REC_TWO="$REMOTE_SCRATCH/unused.recommendation.json"
REMOTE_RECORDER="$REMOTE_SCRATCH/unused-recorder.py"
studio_command() { "$@"; }
remove_remote_scratch
trace cleanup_idempotent
''',
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace, ["cleanup_idempotent"])

    def test_legacy_v1_journal_retains_legacy_scratch_names_and_unknown_profile_refuses(self):
        journal = {
            "baseline_model": "incumbent",
            "release_binding": {"binary_version": "1.0.0"},
            "baseline_status": {
                "catalog_version": "release", "catalog_hash": "a" * 64, "pid": 42,
            },
            "market_binding": {"rate_card_version": "rates"},
            "remote_scratch": "/tmp/macprovider-qwen-e2e.legacy",
        }
        result, _ = self.run_shell(
            ["load_journal_context", "set_remote_scratch_paths"],
            '''
load_journal_context "$FIXTURE"
printf '%s\n' "$REMOTE_REC_ONE" "$REMOTE_REC_TWO" "$REMOTE_RECORDER"
''',
            journal,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            "/tmp/macprovider-qwen-e2e.legacy/one.recommendation.json",
            "/tmp/macprovider-qwen-e2e.legacy/two.recommendation.json",
            "/tmp/macprovider-qwen-e2e.legacy/opencode-gateway-check.py",
        ])
        journal["profile"] = "unreviewed-profile"
        rejected, _ = self.run_shell(
            ["load_journal_context", "set_remote_scratch_paths"],
            'load_journal_context "$FIXTURE"', journal,
        )
        self.assertNotEqual(rejected.returncode, 0)

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
