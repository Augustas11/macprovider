import csv
import io
import json
import os
import tempfile
import threading
import unittest
from contextlib import redirect_stdout
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from types import SimpleNamespace

from scripts.malibu_fleet_ledger import (
    CSV_FORMULA_PREFIXES,
    FleetLedgerRow,
    NoRedirectHandler,
    USER_BUCKETS,
    classify_admin_provider,
    classify_diagnostics,
    emit_csv,
    fetch_json,
    fetch_admin_providers,
    merge_provider_records,
    read_operator_env_file,
    resolve_operator_token,
    rows_from_sources,
    validate_operator_token,
    validate_admin_base_url,
)


class MalibuFleetLedgerTests(unittest.TestCase):
    def classify(self, payload):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "diagnostics.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            return classify_diagnostics(path)

    def assertValidBucket(self, row):
        self.assertIn(row.bucket, USER_BUCKETS)
        self.assertEqual(sum(1 for bucket in USER_BUCKETS if row.bucket == bucket), 1)

    def test_bucket_contract_is_the_issue_1188_contract(self):
        self.assertEqual(
            USER_BUCKETS,
            (
                "Healthy",
                "Repair provider software",
                "Offline/connectivity",
                "Trust verification needed",
                "Cooldown/requalification",
            ),
        )

    def test_admin_connected_routing_eligible_is_healthy(self):
        row = classify_admin_provider(
            {
                "provider_id": "mp-live",
                "hostname": "anonymous-live-fixture",
                "presence": "connected",
                "binary_version": "1.8.105",
                "model_id": "llama",
                "state": "ready",
                "auth_state": "bearer_validated",
                "routing_eligible": True,
                "tier": "trusted",
                "last_heartbeat_at": "2026-08-26T01:02:03Z",
            },
            source="https://coordinator.example/admin/providers",
        )

        self.assertEqual(row.bucket, "Healthy")
        self.assertEqual(row.hostname, "anonymous-live-fixture")
        self.assertEqual(row.cli_version, "1.8.105")
        self.assertEqual(row.model, "llama")
        self.assertEqual(row.routing_eligibility, "eligible")
        self.assertEqual(row.trust_tier, "trusted")
        self.assertValidBucket(row)

    def test_admin_poolz_merge_preserves_live_hostname_and_admin_diagnostic(self):
        merged = merge_provider_records(
            admin_providers=[
                {
                    "provider_id": "mp-live",
                    "presence": "connected",
                    "diagnostic": "network_offline: redacted",
                    "last_seen_at": "2026-08-26T01:02:04Z",
                }
            ],
            poolz_providers=[
                {
                    "provider_id": "mp-live",
                    "hostname": "anonymous-live-fixture",
                    "binary_version": "1.8.105",
                    "model_id": "llama",
                    "tier": "trusted",
                    "routing_eligible": True,
                    "last_heartbeat_at": "2026-08-26T01:02:03Z",
                }
            ],
        )

        self.assertEqual(len(merged), 1)
        row = classify_admin_provider(merged[0][0], source=merged[0][1])
        self.assertEqual(merged[0][1], "admin+poolz")
        self.assertEqual(row.hostname, "anonymous-live-fixture")
        self.assertEqual(row.last_error, "network_offline: redacted")

    def test_stale_admin_connectivity_diagnostic_does_not_override_live_poolz_truth(self):
        merged = merge_provider_records(
            admin_providers=[
                {
                    "provider_id": "mp-live",
                    "presence": "offline",
                    "state": "unavailable",
                    "routing_eligible": False,
                    "diagnostic": "network_offline: stale coordinator last-known diagnostic",
                    "diagnostic_at": "2026-08-26T01:00:00Z",
                    "last_seen_at": "2026-08-26T01:00:00Z",
                }
            ],
            poolz_providers=[
                {
                    "provider_id": "mp-live",
                    "hostname": "anonymous-live-fixture",
                    "binary_version": "1.8.105",
                    "model_id": "llama",
                    "state": "ready",
                    "tier": "trusted",
                    "routing_eligible": True,
                    "last_heartbeat_at": "2026-08-26T01:02:03Z",
                    "last_activity_at": "2026-08-26T01:02:04Z",
                }
            ],
        )

        row = classify_admin_provider(merged[0][0], source=merged[0][1])

        self.assertEqual(row.bucket, "Healthy")
        self.assertEqual(row.coordinator_presence, "connected")
        self.assertEqual(row.routing_eligibility, "eligible")
        self.assertEqual(row.last_error, "network_offline: stale coordinator last-known diagnostic")
        self.assertIn("diagnostic_at=2026-08-26T01:00:00Z", row.evidence)
        self.assertValidBucket(row)

    def test_stale_admin_version_floor_diagnostic_does_not_override_live_poolz_truth(self):
        merged = merge_provider_records(
            admin_providers=[
                {
                    "provider_id": "mp-live",
                    "presence": "offline",
                    "state": "unavailable",
                    "routing_eligible": False,
                    "diagnostic": "version_unsupported: binary_version 1.8.93 below required 1.8.104; acl_write_rejected:/Users/provider",
                    "diagnostic_at": "2026-08-26T01:00:00Z",
                    "last_seen_at": "2026-08-26T01:00:00Z",
                }
            ],
            poolz_providers=[
                {
                    "provider_id": "mp-live",
                    "hostname": "anonymous-live-fixture",
                    "binary_version": "1.8.105",
                    "model_id": "llama",
                    "state": "ready",
                    "tier": "trusted",
                    "routing_eligible": True,
                    "last_heartbeat_at": "2026-08-26T01:02:03Z",
                    "last_activity_at": "2026-08-26T01:02:04Z",
                }
            ],
        )

        row = classify_admin_provider(merged[0][0], source=merged[0][1])

        self.assertEqual(row.bucket, "Healthy")
        self.assertEqual(row.watchdog_repair_state, "")
        self.assertEqual(
            row.last_error,
            "version_unsupported: binary_version 1.8.93 below required 1.8.104; acl_write_rejected:/Users/provider",
        )
        self.assertIn("diagnostic_at=2026-08-26T01:00:00Z", row.evidence)
        self.assertValidBucket(row)

    def test_admin_offline_without_repair_signature_is_connectivity_bucket(self):
        row = classify_admin_provider(
            {
                "provider_id": "mp-offline",
                "presence": "offline",
                "binary_version": "1.8.57",
                "model_id": "qwen",
                "state": "unavailable",
                "auth_state": "bearer_validated",
                "routing_eligible": False,
                "last_seen_at": "2026-08-26T01:02:03Z",
            },
            source="https://coordinator.example/admin/providers",
        )

        self.assertEqual(row.bucket, "Offline/connectivity")
        self.assertIn("coordinator presence", row.bucket_reason)
        self.assertValidBucket(row)

    def test_admin_version_floor_diagnostic_is_repair_bucket(self):
        row = classify_admin_provider(
            {
                "provider_id": "mp-version-floor",
                "presence": "offline",
                "binary_version": "1.8.93",
                "model_id": "qwen",
                "state": "unavailable",
                "auth_state": "bearer_validated",
                "routing_eligible": False,
                "diagnostic": "version_unsupported: binary_version 1.8.93 below required 1.8.104",
                "last_seen_at": "2026-08-26T01:02:03Z",
            },
            source="https://coordinator.example/admin/providers",
        )

        self.assertEqual(row.bucket, "Repair provider software")
        self.assertEqual(row.watchdog_repair_state, "repair_needed")
        self.assertIn("last_error=version_unsupported", ";".join(row.evidence))
        self.assertValidBucket(row)

    def test_admin_provisional_reward_hold_is_trust_verification_bucket(self):
        row = classify_admin_provider(
            {
                "provider_id": "mp-trust",
                "presence": "connected",
                "state": "ready",
                "auth_state": "self_minted",
                "routing_eligible": False,
                "trust_tier": "provisional",
                "withdrawal_hold_reasons": ["trust_tier_provisional"],
            },
            source="https://coordinator.example/admin/providers",
        )

        self.assertEqual(row.bucket, "Trust verification needed")
        self.assertEqual(row.reward_hold_reason, "trust_tier_provisional")
        self.assertValidBucket(row)

    def test_poolz_integrity_failure_is_trust_bucket_even_when_connected_and_routing(self):
        row = classify_admin_provider(
            {
                "provider_id": "mp-integrity",
                "presence": "connected",
                "state": "ready",
                "auth_state": "bearer_validated",
                "routing_eligible": True,
                "trust_tier": "trusted",
                "hash_status": "hash_mismatch",
                "attestation_status": "failed",
                "encrypted_leg": True,
                "catalog_admission_mode": "current",
                "last_heartbeat_at": "2026-08-26T01:02:03Z",
            },
            source="https://coordinator.example/poolz",
        )

        self.assertEqual(row.bucket, "Trust verification needed")
        self.assertEqual(row.hash_status, "hash_mismatch")
        self.assertEqual(row.attestation_status, "failed")
        self.assertEqual(row.encrypted_leg, "true")
        self.assertEqual(row.catalog_admission_mode, "current")
        self.assertIn("policy_integrity_alert=model hash integrity status is hash_mismatch", row.evidence)
        self.assertValidBucket(row)

    def test_poolz_required_missing_config_is_not_treated_as_row_policy_verdict(self):
        row = classify_admin_provider(
            {
                "provider_id": "mp-policy-config",
                "presence": "connected",
                "state": "ready",
                "auth_state": "bearer_validated",
                "routing_eligible": True,
                "trust_tier": "trusted",
                "hash_status": "missing",
                "require_hash_verified": True,
                "attestation_status": "missing",
                "require_attestation": True,
                "encrypted_leg": False,
                "require_encrypted_leg": True,
                "last_heartbeat_at": "2026-08-26T01:02:03Z",
            },
            source="https://coordinator.example/poolz",
        )

        self.assertEqual(row.bucket, "Healthy")
        self.assertEqual(row.hash_status, "missing")
        self.assertEqual(row.attestation_status, "missing")
        self.assertEqual(row.encrypted_leg, "false")
        self.assertEqual(row.require_hash_verified, "true")
        self.assertEqual(row.require_attestation, "true")
        self.assertEqual(row.require_encrypted_leg, "true")
        self.assertIn("require_hash_verified=true", row.evidence)
        self.assertIn("require_attestation=true", row.evidence)
        self.assertIn("require_encrypted_leg=true", row.evidence)
        self.assertNotIn("policy_integrity_alert=", ";".join(row.evidence))
        self.assertValidBucket(row)

    def test_row_level_tier2_policy_verdict_is_trust_bucket(self):
        row = classify_admin_provider(
            {
                "provider_id": "mp-policy-verdict",
                "presence": "connected",
                "state": "ready",
                "auth_state": "bearer_validated",
                "routing_eligible": True,
                "trust_tier": "trusted",
                "tier2_policy_eligible": False,
                "tier2_policy_reason": "required_attestation_missing",
                "last_heartbeat_at": "2026-08-26T01:02:03Z",
            },
            source="https://coordinator.example/poolz",
        )

        self.assertEqual(row.bucket, "Trust verification needed")
        self.assertEqual(row.tier2_policy_eligible, "false")
        self.assertEqual(row.tier2_policy_reason, "required_attestation_missing")
        self.assertIn("policy_integrity_alert=tier2 policy ineligible: required_attestation_missing", row.evidence)
        self.assertValidBucket(row)

    def test_tier2_policy_ineligible_without_reason_is_preserved_but_not_authoritative(self):
        row = classify_admin_provider(
            {
                "provider_id": "mp-policy-partial",
                "presence": "connected",
                "state": "ready",
                "auth_state": "bearer_validated",
                "routing_eligible": True,
                "trust_tier": "trusted",
                "tier2_policy_eligible": False,
                "last_heartbeat_at": "2026-08-26T01:02:03Z",
            },
            source="https://coordinator.example/poolz",
        )

        self.assertEqual(row.bucket, "Healthy")
        self.assertEqual(row.tier2_policy_eligible, "false")
        self.assertEqual(row.tier2_policy_reason, "")
        self.assertIn("tier2_policy_eligible=false", row.evidence)
        self.assertNotIn("policy_integrity_alert=", ";".join(row.evidence))
        self.assertValidBucket(row)

    def test_admin_demotion_cooldown_is_cooldown_bucket_even_when_trusted(self):
        row = classify_admin_provider(
            {
                "provider_id": "mp-cooldown",
                "presence": "connected",
                "state": "ready",
                "auth_state": "bearer_validated",
                "routing_eligible": False,
                "trust_tier": "trusted",
                "reward_hold_reason": "demotion_cooldown",
            },
            source="https://coordinator.example/admin/providers",
        )

        self.assertEqual(row.bucket, "Cooldown/requalification")
        self.assertEqual(row.trust_tier, "trusted")
        self.assertValidBucket(row)

    def test_update_bridge_catalog_admission_is_repair_bucket(self):
        row = classify_admin_provider(
            {
                "provider_id": "mp-update-bridge",
                "presence": "connected",
                "state": "ready",
                "auth_state": "bearer_validated",
                "routing_eligible": False,
                "trust_tier": "trusted",
                "catalog_admission_mode": "update_bridge",
                "last_heartbeat_at": "2026-08-26T01:02:03Z",
            },
            source="https://coordinator.example/poolz",
        )

        self.assertEqual(row.bucket, "Repair provider software")
        self.assertEqual(row.catalog_admission_mode, "update_bridge")
        self.assertIn("update_bridge", row.bucket_reason)
        self.assertIn("provider software update/repair lane", row.operator_next_action)
        self.assertValidBucket(row)

    def test_legacy_catalog_admission_without_update_bridge_remains_requalification_bucket(self):
        row = classify_admin_provider(
            {
                "provider_id": "mp-legacy-catalog",
                "presence": "connected",
                "state": "ready",
                "auth_state": "bearer_validated",
                "routing_eligible": False,
                "trust_tier": "trusted",
                "catalog_admission_mode": "legacy",
                "last_heartbeat_at": "2026-08-26T01:02:03Z",
            },
            source="https://coordinator.example/poolz",
        )

        self.assertEqual(row.bucket, "Cooldown/requalification")
        self.assertEqual(row.catalog_admission_mode, "legacy")
        self.assertValidBucket(row)

    def test_admin_repair_failed_watchdog_diagnostic_stays_repair_bucket(self):
        row = classify_admin_provider(
            {
                "provider_id": "mp-stuck",
                "hostname": "operator-fixture-host",
                "presence": "connected",
                "binary_version": "1.8.93",
                "model_id": "llama",
                "state": "ready",
                "auth_state": "bearer_validated",
                "routing_eligible": True,
                "tier": "trusted",
                "diagnostic": "old watchdog still acl_write_rejected:/Users/provider after repair already failed",
            },
            source="https://coordinator.example/admin/providers",
        )

        self.assertEqual(row.bucket, "Repair provider software")
        self.assertEqual(row.watchdog_repair_state, "watchdog_layer_repair_blocked")
        self.assertIn("Do not repeat Malibu app install or generic Repair", row.operator_next_action)
        self.assertValidBucket(row)

    def test_home_acl_plus_repair_failure_is_external_provider_a_style_repair_bucket(self):
        row = self.classify(
            {
                "created_at": "2026-08-22T10:22:41.582Z",
                "malibu_version": "1.8.104",
                "provider": {
                    "id": "external-provider-incident-a",
                    "hostname": "external-provider-a-host",
                    "model_id": "meta-llama/llama-3.2-3b-instruct",
                    "network_state": "buyer_serving_unknown",
                    "ui_state": "serving",
                    "cli_version": "1.8.93",
                },
                "logs": {
                    "provider": [
                        "Coordinator tier: trusted",
                        "Provider software could not be verified for repair. Your provider identity was not changed.",
                        "A newer version is available (v1.8.104). Run 'malibu-cli update' to upgrade.",
                    ],
                    "watchdog": [
                        "[2026-08-20T09:34:50Z] autoupdate recovery_error=acl_write_rejected:/Users/external-provider-a",
                        "[2026-08-21T11:10:38Z] warning: provider process is locally healthy, but no ESTABLISHED TCP to coordinator.example:443 for provider_id=external-provider-incident-a",
                    ],
                },
            }
        )

        self.assertEqual(row.bucket, "Repair provider software")
        self.assertEqual(row.watchdog_repair_state, "watchdog_layer_repair_blocked")
        self.assertEqual(row.provider_id, "external-provider-incident-a")
        self.assertEqual(row.hostname, "external-provider-a-host")
        self.assertEqual(row.malibu_app_version, "1.8.104")
        self.assertEqual(row.cli_version, "1.8.93")
        self.assertEqual(row.trust_tier, "trusted")
        self.assertIn("repair_failure_signatures=1", row.evidence)
        self.assertIn("watchdog_home_acl_rejections=1 path=/Users/external-provider-a", row.evidence)
        self.assertValidBucket(row)

    def test_home_acl_without_repair_failure_uses_same_user_bucket(self):
        row = self.classify(
            {
                "provider": {
                    "id": "mp-home-acl",
                    "network_state": "buyer_serving_unknown",
                    "ui_state": "serving",
                },
                "logs": {
                    "provider": ["Coordinator tier: trusted"],
                    "watchdog": [
                        "[2026-08-20T09:34:50Z] autoupdate recovery_error=acl_write_rejected:/Users/provider name"
                    ],
                },
            }
        )

        self.assertEqual(row.bucket, "Repair provider software")
        self.assertEqual(row.watchdog_repair_state, "home_acl_autoupdate_blocked")
        self.assertIn("watchdog_home_acl_rejections=1 path=/Users/provider name", row.evidence)
        self.assertValidBucket(row)

    def test_minimal_row_still_gets_one_user_facing_bucket(self):
        row = classify_admin_provider(
            {"provider_id": "mp-minimal"},
            source="https://coordinator.example/admin/providers",
        )

        self.assertEqual(row.bucket, "Offline/connectivity")
        self.assertValidBucket(row)

    def test_operator_env_file_reads_quoted_value(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "coordinator.env"
            path.write_text("OTHER=ignored\nOPERATOR_KEY='operator-token'\n", encoding="utf-8")
            path.chmod(0o600)

            self.assertEqual(read_operator_env_file(path, "OPERATOR_KEY"), "operator-token")

    def test_admin_url_validation_requires_https_except_loopback(self):
        self.assertEqual(validate_admin_base_url("https://coordinator.example"), "https://coordinator.example")
        self.assertEqual(validate_admin_base_url("http://127.0.0.1:8080"), "http://127.0.0.1:8080")
        self.assertEqual(validate_admin_base_url("http://localhost:8080"), "http://localhost:8080")
        self.assertEqual(validate_admin_base_url("http://[::1]:8080"), "http://[::1]:8080")

        for url in (
            "http://coordinator.example",
            "https://operator:secret@coordinator.example",
            "https://coordinator.example?token=secret",
            "https://coordinator.example#fragment",
        ):
            with self.subTest(url=url):
                with self.assertRaises(SystemExit):
                    validate_admin_base_url(url)

    def test_fetch_json_does_not_follow_admin_redirects(self):
        handler = NoRedirectHandler()

        self.assertIsNone(
            handler.redirect_request(
                req=None,
                fp=None,
                code=302,
                msg="Found",
                headers={},
                newurl="https://coordinator.example/redirected",
            )
        )

    def test_fetch_json_loopback_redirect_does_not_replay_bearer_to_target(self):
        class TargetHandler(BaseHTTPRequestHandler):
            authorizations: list[str] = []

            def do_GET(self):
                type(self).authorizations.append(self.headers.get("Authorization", ""))
                self.send_response(200)
                self.end_headers()

            def log_message(self, fmt, *args):
                return

        try:
            target = HTTPServer(("127.0.0.1", 0), TargetHandler)
        except PermissionError as exc:
            self.skipTest(f"loopback bind unavailable in this sandbox: {exc}")

        class RedirectHandler(BaseHTTPRequestHandler):
            requests: list[str] = []

            def do_GET(self):
                type(self).requests.append(self.headers.get("Authorization", ""))
                self.send_response(302)
                self.send_header("Location", f"http://127.0.0.1:{target.server_port}/target")
                self.end_headers()

            def log_message(self, fmt, *args):
                return

        try:
            redirect = HTTPServer(("127.0.0.1", 0), RedirectHandler)
        except PermissionError as exc:
            target.server_close()
            self.skipTest(f"loopback bind unavailable in this sandbox: {exc}")

        target_thread = threading.Thread(target=target.serve_forever, daemon=True)
        redirect_thread = threading.Thread(target=redirect.serve_forever, daemon=True)
        target_thread.start()
        redirect_thread.start()
        try:
            with self.assertRaises(SystemExit) as error:
                fetch_json(f"http://127.0.0.1:{redirect.server_port}/start", "operator-token!")
            self.assertIn("HTTP 302", str(error.exception))
            self.assertEqual(RedirectHandler.requests, ["Bearer operator-token!"])
            self.assertEqual(TargetHandler.authorizations, [])
        finally:
            redirect.shutdown()
            target.shutdown()
            redirect.server_close()
            target.server_close()

    def test_paginated_admin_failure_redacts_cursor_query_from_error(self):
        cursor = "mp-cursor-fixture"

        class PagingHandler(BaseHTTPRequestHandler):
            paths: list[str] = []

            def do_GET(self):
                type(self).paths.append(self.path)
                if "after=" not in self.path:
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.end_headers()
                    self.wfile.write(
                        json.dumps(
                            {
                                "providers": [],
                                "next_after": cursor,
                                "next_after_seen": "2026-08-26T01:02:03Z",
                            }
                        ).encode("utf-8")
                    )
                    return
                self.send_response(500)
                self.end_headers()

            def log_message(self, fmt, *args):
                return

        try:
            server = HTTPServer(("127.0.0.1", 0), PagingHandler)
        except PermissionError as exc:
            self.skipTest(f"loopback bind unavailable in this sandbox: {exc}")

        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with self.assertRaises(SystemExit) as error:
                fetch_admin_providers(f"http://127.0.0.1:{server.server_port}", "operator-token!", 100)

            message = str(error.exception)
            self.assertIn("HTTP 500", message)
            self.assertIn("/admin/providers", message)
            self.assertNotIn(cursor, message)
            self.assertNotIn("after=", message)
            self.assertNotIn("after_seen=", message)
            self.assertIn(cursor, PagingHandler.paths[-1])
        finally:
            server.shutdown()
            server.server_close()

    def test_fetch_json_rejects_plaintext_non_loopback_before_authorization(self):
        with self.assertRaises(SystemExit) as error:
            fetch_json("http://coordinator.example/admin/providers", "operator-token")

        self.assertIn("HTTPS", str(error.exception))

    def test_malformed_token_file_fails_without_echoing_token_bytes(self):
        leaked_token = "valid-prefix\nsecret-suffix"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "operator-token"
            path.write_text(leaked_token, encoding="utf-8")
            path.chmod(0o600)

            with self.assertRaises(SystemExit) as error:
                resolve_operator_token("OPERATOR_KEY", token_file=path)

        message = str(error.exception)
        self.assertIn("malformed", message)
        self.assertNotIn(leaked_token, message)
        self.assertNotIn("secret-suffix", message)

    def test_fetch_json_rejects_malformed_token_before_request_header_validation(self):
        leaked_token = "bad\rsecret-token"

        with self.assertRaises(SystemExit) as error:
            fetch_json("https://coordinator.example/admin/providers", leaked_token)

        message = str(error.exception)
        self.assertIn("malformed", message)
        self.assertNotIn(leaked_token, message)
        self.assertNotIn("secret-token", message)

    def test_operator_token_validation_allows_server_accepted_punctuation(self):
        self.assertEqual(validate_operator_token("abc.DEF_123-~+/=!"), "abc.DEF_123-~+/=!")

    def test_operator_token_validation_rejects_whitespace_and_non_ascii_without_echo(self):
        for token in ("   ", "token with space", "token\u2603", "token\nsecret"):
            with self.subTest(token=repr(token)):
                with self.assertRaises(SystemExit) as error:
                    validate_operator_token(token)
                message = str(error.exception)
                self.assertIn("malformed", message)
                self.assertNotIn(token, message)

    def test_explicit_token_file_empty_fails_closed_without_ambient_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "operator-token"
            path.write_text("", encoding="utf-8")
            path.chmod(0o600)
            old_value = os.environ.get("OPERATOR_KEY")
            os.environ["OPERATOR_KEY"] = "ambient-token"
            try:
                with self.assertRaises(SystemExit):
                    resolve_operator_token("OPERATOR_KEY", token_file=path)
            finally:
                if old_value is None:
                    os.environ.pop("OPERATOR_KEY", None)
                else:
                    os.environ["OPERATOR_KEY"] = old_value

    def test_explicit_env_file_missing_key_fails_closed_without_ambient_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "coordinator.env"
            path.write_text("OTHER=ignored\n", encoding="utf-8")
            path.chmod(0o600)
            old_value = os.environ.get("OPERATOR_KEY")
            os.environ["OPERATOR_KEY"] = "ambient-token"
            try:
                with self.assertRaises(SystemExit):
                    resolve_operator_token("OPERATOR_KEY", env_file=path)
            finally:
                if old_value is None:
                    os.environ.pop("OPERATOR_KEY", None)
                else:
                    os.environ["OPERATOR_KEY"] = old_value

    def test_group_readable_token_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "operator-token"
            path.write_text("operator-token\n", encoding="utf-8")
            path.chmod(0o640)
            try:
                with self.assertRaises(SystemExit):
                    resolve_operator_token("OPERATOR_KEY", token_file=path)
            finally:
                path.chmod(0o600)

    def test_symlink_token_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "target-token"
            target.write_text("operator-token\n", encoding="utf-8")
            target.chmod(0o600)
            link = Path(directory) / "operator-token"
            link.symlink_to(target)
            try:
                with self.assertRaises(SystemExit):
                    resolve_operator_token("OPERATOR_KEY", token_file=link)
            finally:
                link.unlink()

    def test_csv_output_neutralizes_spreadsheet_formula_prefixes(self):
        row = FleetLedgerRow(
            source="\n=source",
            provider_id="=provider",
            hostname="+host",
            malibu_app_version="-1.8.105",
            cli_version="\t1.8.105",
            watchdog_repair_state="",
            model="@model",
            coordinator_presence="connected",
            routing_eligibility="eligible",
            trust_tier="trusted",
            hash_status="",
            attestation_status="",
            encrypted_leg="",
            catalog_admission_mode="",
            admission_policy_flags="",
            require_hash_verified="",
            require_attestation="",
            require_encrypted_leg="",
            tier2_policy_eligible="",
            tier2_policy_reason="\uff1dreason",
            reward_hold_reason="",
            last_heartbeat="\r2026-08-26T01:02:03Z",
            last_error="=diagnostic",
            bucket="Healthy",
            bucket_reason="+reason",
            operator_next_action="-action",
            evidence=["=evidence"],
        )
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            emit_csv([row])

        parsed = next(csv.DictReader(io.StringIO(buffer.getvalue())))

        self.assertEqual(parsed["source"], "'\n=source")
        self.assertEqual(parsed["provider_id"], "'=provider")
        self.assertEqual(parsed["hostname"], "'+host")
        self.assertEqual(parsed["malibu_app_version"], "'-1.8.105")
        self.assertEqual(parsed["cli_version"], "'\t1.8.105")
        self.assertEqual(parsed["model"], "'@model")
        self.assertEqual(parsed["tier2_policy_reason"], "'\uff1dreason")
        self.assertEqual(parsed["last_heartbeat"], "'\r2026-08-26T01:02:03Z")
        self.assertEqual(parsed["last_error"], "'=diagnostic")
        self.assertEqual(parsed["bucket_reason"], "'+reason")
        self.assertEqual(parsed["operator_next_action"], "'-action")
        self.assertEqual(parsed["evidence"], "'=evidence")

    def test_csv_output_neutralizes_every_configured_formula_prefix(self):
        for prefix in CSV_FORMULA_PREFIXES:
            with self.subTest(prefix=repr(prefix)):
                row = FleetLedgerRow(
                    source=prefix + "formula",
                    provider_id="mp-csv-prefix",
                    hostname="anonymous-live-fixture",
                    malibu_app_version="",
                    cli_version="",
                    watchdog_repair_state="",
                    model="",
                    coordinator_presence="connected",
                    routing_eligibility="eligible",
                    trust_tier="trusted",
                    hash_status="",
                    attestation_status="",
                    encrypted_leg="",
                    catalog_admission_mode="",
                    admission_policy_flags="",
                    require_hash_verified="",
                    require_attestation="",
                    require_encrypted_leg="",
                    tier2_policy_eligible="",
                    tier2_policy_reason="",
                    reward_hold_reason="",
                    last_heartbeat="",
                    last_error="",
                    bucket="Healthy",
                    bucket_reason="ok",
                    operator_next_action="monitor",
                    evidence=[],
                )
                buffer = io.StringIO()
                with redirect_stdout(buffer):
                    emit_csv([row])

                parsed = next(csv.DictReader(io.StringIO(buffer.getvalue())))

                self.assertEqual(parsed["source"], "'" + prefix + "formula")

    def test_rows_from_sources_are_sorted_for_stable_exports(self):
        with tempfile.TemporaryDirectory() as directory:
            admin_path = Path(directory) / "admin.json"
            admin_path.write_text(
                json.dumps(
                    {
                        "providers": [
                            {"provider_id": "mp-sort-b", "presence": "offline"},
                            {
                                "provider_id": "mp-sort-a",
                                "presence": "connected",
                                "routing_eligible": True,
                            },
                            {"provider_id": "mp-sort-c", "presence": "offline"},
                        ]
                    }
                ),
                encoding="utf-8",
            )
            rows = rows_from_sources(
                SimpleNamespace(
                    admin_json=admin_path,
                    poolz_json=None,
                    admin_url=None,
                    no_poolz=False,
                    operator_token_env="OPERATOR_KEY",
                    operator_token_file=None,
                    operator_env_file=None,
                    limit=100,
                    diagnostics=[],
                )
            )

        self.assertEqual(
            [(row.bucket, row.provider_id) for row in rows],
            [
                ("Healthy", "mp-sort-a"),
                ("Offline/connectivity", "mp-sort-b"),
                ("Offline/connectivity", "mp-sort-c"),
            ],
        )


if __name__ == "__main__":
    unittest.main()
