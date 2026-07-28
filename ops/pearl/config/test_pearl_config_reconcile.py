#!/usr/bin/env python3
import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
TOOL = ROOT / "ops/pearl/config/reconcile_pearl_config.py"
DATA = ROOT / "ops/pearl/config/testdata"

spec = importlib.util.spec_from_file_location("reconcile_pearl_config", TOOL)
assert spec is not None and spec.loader is not None
reconcile_module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = reconcile_module
spec.loader.exec_module(reconcile_module)


class PearlConfigReconcileTest(unittest.TestCase):
    def run_tool(self, *args):
        return subprocess.run(
            [sys.executable, str(TOOL), *args],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_known_drift_fixture_is_classified(self):
        result = self.run_tool(
            "--tracked-config",
            str(DATA / "known-drift-tracked.yaml"),
            "--live-config",
            str(DATA / "known-drift-live.yaml"),
            "--live-overlay",
            str(DATA / "known-drift-overlay.yaml"),
            "--live-env",
            str(DATA / "known-drift.env"),
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Evidence:", result.stdout)
        self.assertIn("pool.heartbeat_interval_s: value_mismatch: tracked=30 live=1", result.stdout)
        self.assertIn(
            "pool.warmup_gate_enabled: value_mismatch: tracked=True live=False",
            result.stdout,
        )
        self.assertIn(
            "coordinator_advertised_version.latest_binary_version: "
            "value_mismatch: tracked='1.8.66' live='1.8.61'",
            result.stdout,
        )
        self.assertIn(
            "coordinator_advertised_version.required_binary_version: "
            "tracked_only: tracked='1.8.33' live=<ABSENT>",
            result.stdout,
        )
        self.assertIn(
            "auth.credential_bootstrap_token_ttl_s: "
            "tracked_only: tracked=600 live=<ABSENT> "
            "[base_product_defaults; class=intentional Pearl production posture]",
            result.stdout,
        )
        self.assertIn(
            "autotune.public_keys.streamvc-autotune-static-v5: "
            "tracked_only: tracked='vpTgWfvvrnbc1QhdTAxULFisoDU7jQ4mB1yZIHIGjBA=' live=<ABSENT> "
            "[fleet_version_admission_policy; class=fleet/version-admission policy]",
            result.stdout,
        )
        self.assertIn(
            "coordinator.env.COORDINATOR_PARTNER_KEYS_ADMIN_DSN: "
            "key name is classified; value=<MASKED> "
            "[pearl_operator_secrets; class=secrets/env-owned setting]",
            result.stdout,
        )
        self.assertIn(
            "production_overlay.pool.canary_challenges[0].prompt: "
            "live canary challenge field is classified; value=<MASKED> "
            "[pearl_production_overlay; class=overlay-owned Pearl production setting]",
            result.stdout,
        )
        self.assertIn(
            "production_overlay.referrals.hmac_keys.k1: "
            "live referral HMAC key reference is classified; value=<MASKED> "
            "[pearl_operator_secrets; class=secrets/env-owned setting]",
            result.stdout,
        )
        self.assertIn(
            "referrals.require_for_registration: tracked_only: tracked=False live=<ABSENT> "
            "[base_product_defaults; class=overlay-owned Pearl production setting]",
            result.stdout,
        )
        self.assertIn("Inference:", result.stdout)
        self.assertIn(
            "providers.augustass-macbook-air: live-only provider row is classified",
            result.stdout,
        )
        self.assertIn("Unknown:\n- none", result.stdout)

    def test_unknown_config_drift_exits_nonzero(self):
        result = self.run_tool(
            "--tracked-config",
            str(DATA / "known-drift-tracked.yaml"),
            "--live-config",
            str(DATA / "unknown-live.yaml"),
            "--live-overlay",
            str(DATA / "known-drift-overlay.yaml"),
            "--live-env",
            str(DATA / "known-drift.env"),
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Unknown:", result.stdout)
        self.assertIn("routing.request_timeout_s", result.stdout)
        self.assertIn("rewards.rate_card.default.prompt_credits_per_mtok", result.stdout)

    def test_live_env_is_required_for_fixture_mode(self):
        result = self.run_tool(
            "--tracked-config",
            str(DATA / "known-drift-tracked.yaml"),
            "--live-config",
            str(DATA / "known-drift-live.yaml"),
            "--live-overlay",
            str(DATA / "known-drift-overlay.yaml"),
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("--live-env is required when not using --ssh-target", result.stderr)

    def test_malformed_env_line_exits_nonzero_without_value(self):
        result = self.run_tool(
            "--tracked-config",
            str(DATA / "known-drift-tracked.yaml"),
            "--live-config",
            str(DATA / "known-drift-live.yaml"),
            "--live-overlay",
            str(DATA / "known-drift-overlay.yaml"),
            "--live-env",
            str(DATA / "malformed-env.env"),
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("coordinator.env.line_2", result.stdout)
        self.assertIn("malformed env line", result.stdout)
        self.assertNotIn("redaction-sentinel-not-for-output", result.stdout)

    def test_secret_shaped_values_are_masked(self):
        result = self.run_tool(
            "--tracked-config",
            str(DATA / "known-drift-tracked.yaml"),
            "--live-config",
            str(DATA / "unknown-live.yaml"),
            "--live-overlay",
            str(DATA / "known-drift-overlay.yaml"),
            "--live-env",
            str(DATA / "known-drift.env"),
        )
        forbidden = [
            "redaction-sentinel-not-for-output",
            "inline-redaction-sentinel-not-for-output",
        ]
        for value in forbidden:
            self.assertNotIn(value, result.stdout)
            self.assertNotIn(value, result.stderr)
        self.assertIn("coordinator.env.OPERATOR_KEY: key name is classified; value=<MASKED>", result.stdout)
        self.assertIn("diagnostics.debug_label", result.stdout)
        self.assertIn("diagnostics.debug_label: live_only: tracked=<ABSENT> live=<MASKED>", result.stdout)

    def test_embedded_secret_shaped_substrings_are_masked(self):
        values = [
            "prefix bearer abcdefghijklmnop suffix",
            "prefix ghp_abcdefghijklmnopqrstuvwxyz suffix",
            "prefix 0123456789abcdef0123456789abcdef suffix",
        ]
        for value in values:
            self.assertEqual(reconcile_module.display_value("diagnostics.note", value), "<MASKED>")

        rendered_path = reconcile_module.render_safe_path(
            "diagnostics.prefix-ghp_abcdefghijklmnopqrstuvwxyz-suffix"
        )
        self.assertIn("diagnostics.<MASKED:", rendered_path)
        self.assertNotIn("ghp_abcdefghijklmnopqrstuvwxyz", rendered_path)

    def test_config_false_positive_secret_paths_are_not_masked(self):
        self.assertEqual(reconcile_module.display_value("auth.credential_bootstrap_token_ttl_s", 600), "600")
        self.assertEqual(
            reconcile_module.display_value(
                "autotune.public_keys.streamvc-autotune-static-v5",
                "vpTgWfvvrnbc1QhdTAxULFisoDU7jQ4mB1yZIHIGjBA=",
            ),
            "'vpTgWfvvrnbc1QhdTAxULFisoDU7jQ4mB1yZIHIGjBA='",
        )
        self.assertEqual(reconcile_module.display_value("referrals.current_key_id", "k1"), "'k1'")
        self.assertEqual(reconcile_module.display_value("referrals.hmac_keys.k1", "secret"), "<MASKED>")

    def test_local_yaml_parse_error_does_not_print_source_snippet(self):
        with tempfile.TemporaryDirectory() as tmp:
            live_config = Path(tmp) / "live.yaml"
            live_config.write_text(
                "listen:\n"
                "  buyer_port: 8443\n"
                "diagnostics: [sk-redaction-sentinel-not-for-output\n",
                encoding="utf-8",
            )
            result = self.run_tool(
                "--tracked-config",
                str(DATA / "known-drift-tracked.yaml"),
                "--live-config",
                str(live_config),
                "--live-overlay",
                str(DATA / "known-drift-overlay.yaml"),
                "--live-env",
                str(DATA / "known-drift.env"),
            )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("failed to parse", result.stderr)
        self.assertNotIn("redaction-sentinel-not-for-output", result.stdout)
        self.assertNotIn("redaction-sentinel-not-for-output", result.stderr)

    def test_secret_shaped_provider_id_is_masked_in_paths(self):
        tracked_config = reconcile_module.load_yaml_file(DATA / "known-drift-tracked.yaml")
        live_config = reconcile_module.load_yaml_file(DATA / "known-drift-live.yaml")
        secret_provider_id = "sk-redaction-sentinel-not-for-output-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        live_config["providers"].append({"provider_id": secret_provider_id, "endpoint_url": ""})
        live_config["providers"].append({"provider_id": secret_provider_id, "endpoint_url": ""})

        tracked_index = reconcile_module.provider_index(tracked_config, side="tracked")
        live_index = reconcile_module.provider_index(live_config, side="live")
        evidence, inference, unknown = reconcile_module.classify_provider_rows(
            tracked_index.rows,
            live_index.rows,
            reconcile_module.load_yaml_file(ROOT / "ops/pearl/config/source-of-truth.yaml"),
        )
        rendered = reconcile_module.render_findings(evidence, inference, live_index.unknown + unknown)

        self.assertIn("providers.<MASKED:", rendered)
        self.assertNotIn(secret_provider_id, rendered)

    def test_secret_shaped_dynamic_keys_are_masked_in_rendered_paths(self):
        manifest = reconcile_module.load_yaml_file(ROOT / "ops/pearl/config/source-of-truth.yaml")
        secret_yaml_key = "sk-redaction-sentinel-not-for-output-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        secret_env_key = "sk_redaction_sentinel_not_for_output_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

        _, _, config_unknown = reconcile_module.classify_config_drifts(
            [reconcile_module.Drift(path=secret_yaml_key, kind="live_only", tracked=reconcile_module._ABSENT, live={})],
            manifest,
        )
        overlay_evidence, overlay_unknown = reconcile_module.classify_overlay({secret_yaml_key: {}}, manifest)
        env_evidence, env_unknown = reconcile_module.classify_env_lines(
            reconcile_module.parse_env_lines(f"{secret_env_key}=value\n"),
            manifest,
        )
        rendered = reconcile_module.render_findings(
            overlay_evidence + env_evidence,
            [],
            config_unknown + overlay_unknown + env_unknown,
        )

        self.assertIn("<MASKED:", rendered)
        self.assertNotIn(secret_yaml_key, rendered)
        self.assertNotIn(secret_env_key, rendered)

    def test_unknown_overlay_field_exits_nonzero_without_value(self):
        result = self.run_tool(
            "--tracked-config",
            str(DATA / "known-drift-tracked.yaml"),
            "--live-config",
            str(DATA / "known-drift-live.yaml"),
            "--live-overlay",
            str(DATA / "unknown-overlay.yaml"),
            "--live-env",
            str(DATA / "known-drift.env"),
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("production_overlay.unexpected.private_key", result.stdout)
        self.assertIn("value=<MASKED>", result.stdout)
        self.assertNotIn("redaction-sentinel-not-for-output", result.stdout)

    def test_referral_overlay_secret_fields_must_be_env_references(self):
        manifest = reconcile_module.load_yaml_file(ROOT / "ops/pearl/config/source-of-truth.yaml")
        overlay = {
            "referrals": {
                "hmac_keys": {"k1": "inline-redaction-sentinel-not-for-output"},
                "x_api_bearer_token": "env:X_API_BEARER_TOKEN",
            }
        }

        evidence, unknown = reconcile_module.classify_overlay(overlay, manifest)
        rendered = reconcile_module.render_findings(evidence, [], unknown)

        self.assertIn("production_overlay.referrals.x_api_bearer_token", rendered)
        self.assertIn("production_overlay.referrals.hmac_keys.k1", rendered)
        self.assertIn("classified only when value is an env:NAME reference", rendered)
        self.assertNotIn("inline-redaction-sentinel-not-for-output", rendered)

    def test_unknown_referral_overlay_field_exits_nonzero(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            overlay_path = Path(tmpdir) / "unknown-referral-overlay.yaml"
            overlay_path.write_text(
                "referrals:\n"
                "  unexpected_private_token: redaction-sentinel-not-for-output\n",
                encoding="utf-8",
            )
            result = self.run_tool(
                "--tracked-config",
                str(DATA / "known-drift-tracked.yaml"),
                "--live-config",
                str(DATA / "known-drift-live.yaml"),
                "--live-overlay",
                str(overlay_path),
                "--live-env",
                str(DATA / "known-drift.env"),
            )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("production_overlay.referrals.unexpected_private_token", result.stdout)
        self.assertIn("live overlay field is not listed in source-of-truth manifest", result.stdout)
        self.assertNotIn("redaction-sentinel-not-for-output", result.stdout)

    def test_unknown_canary_challenge_leaf_exits_nonzero(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            overlay_path = Path(tmpdir) / "unknown-canary-overlay.yaml"
            overlay_path.write_text(
                "pool:\n"
                "  canary_challenges:\n"
                "    - prompt: 'Return nonce {nonce}'\n"
                "      expected: '{nonce}'\n"
                "      private_token: redaction-sentinel-not-for-output\n",
                encoding="utf-8",
            )
            result = self.run_tool(
                "--tracked-config",
                str(DATA / "known-drift-tracked.yaml"),
                "--live-config",
                str(DATA / "known-drift-live.yaml"),
                "--live-overlay",
                str(overlay_path),
                "--live-env",
                str(DATA / "known-drift.env"),
            )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("production_overlay.pool.canary_challenges[0].private_token", result.stdout)
        self.assertIn("live overlay field is not listed in source-of-truth manifest", result.stdout)
        self.assertNotIn("redaction-sentinel-not-for-output", result.stdout)

    def test_nested_canary_challenge_field_exits_nonzero(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            overlay_path = Path(tmpdir) / "nested-canary-overlay.yaml"
            overlay_path.write_text(
                "pool:\n"
                "  canary_challenges:\n"
                "    - prompt: 'Return nonce {nonce}'\n"
                "      expected: '{nonce}'\n"
                "      private:\n"
                "        prompt: redaction-sentinel-not-for-output\n"
                "  canary_interval_s:\n"
                "    private: redaction-sentinel-not-for-output\n"
                "  model_class_challenges:\n"
                "    qwen3-coder-30b-a3b-instruct:\n"
                "      - prompt: 'Return nonce {nonce}'\n"
                "        expected: '{nonce}'\n"
                "        private:\n"
                "          expected: redaction-sentinel-not-for-output\n",
                encoding="utf-8",
            )
            result = self.run_tool(
                "--tracked-config",
                str(DATA / "known-drift-tracked.yaml"),
                "--live-config",
                str(DATA / "known-drift-live.yaml"),
                "--live-overlay",
                str(overlay_path),
                "--live-env",
                str(DATA / "known-drift.env"),
            )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("production_overlay.pool.canary_challenges[0].private.prompt", result.stdout)
        self.assertIn("production_overlay.pool.canary_interval_s.private", result.stdout)
        self.assertIn(
            "production_overlay.pool.model_class_challenges.qwen3-coder-30b-a3b-instruct[0].private.expected",
            result.stdout,
        )
        self.assertNotIn("redaction-sentinel-not-for-output", result.stdout)

    def test_unknown_overlay_owned_prefix_children_exit_nonzero(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            overlay_path = Path(tmpdir) / "unknown-prefix-overlay.yaml"
            overlay_path.write_text(
                "malibu_emission:\n"
                "  private_token: redaction-sentinel-not-for-output\n"
                "proof_of_weights:\n"
                "  telemetry_drift:\n"
                "    hash_alert_on_status:\n"
                "      - ready\n"
                "      - degraded\n"
                "      - redaction-sentinel-not-for-output\n"
                "opoi:\n"
                "  private_token: redaction-sentinel-not-for-output\n",
                encoding="utf-8",
            )
            result = self.run_tool(
                "--tracked-config",
                str(DATA / "known-drift-tracked.yaml"),
                "--live-config",
                str(DATA / "known-drift-live.yaml"),
                "--live-overlay",
                str(overlay_path),
                "--live-env",
                str(DATA / "known-drift.env"),
            )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("production_overlay.malibu_emission.private_token", result.stdout)
        self.assertIn("production_overlay.proof_of_weights.telemetry_drift.hash_alert_on_status[2]", result.stdout)
        self.assertIn("production_overlay.opoi.private_token", result.stdout)
        self.assertNotIn("redaction-sentinel-not-for-output", result.stdout)

    def test_referral_overlay_env_reference_must_be_allowlisted_and_present(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            typo_overlay_path = Path(tmpdir) / "typo-referral-env-overlay.yaml"
            typo_overlay_path.write_text(
                "referrals:\n"
                "  hmac_keys:\n"
                "    k1: env:MAL_REFERRAL_HMAC_K2\n",
                encoding="utf-8",
            )
            typo_result = self.run_tool(
                "--tracked-config",
                str(DATA / "known-drift-tracked.yaml"),
                "--live-config",
                str(DATA / "known-drift-live.yaml"),
                "--live-overlay",
                str(typo_overlay_path),
                "--live-env",
                str(DATA / "known-drift.env"),
            )
            missing_env_path = Path(tmpdir) / "missing-x-api.env"
            missing_env_path.write_text(
                "OPERATOR_KEY=redaction-sentinel-not-for-output\n"
                "GATEWAY_SERVICE_TOKEN=redaction-sentinel-not-for-output\n"
                "MAL_REFERRAL_HMAC_K1=redaction-sentinel-not-for-output\n",
                encoding="utf-8",
            )
            missing_result = self.run_tool(
                "--tracked-config",
                str(DATA / "known-drift-tracked.yaml"),
                "--live-config",
                str(DATA / "known-drift-live.yaml"),
                "--live-overlay",
                str(DATA / "known-drift-overlay.yaml"),
                "--live-env",
                str(missing_env_path),
            )
        self.assertEqual(typo_result.returncode, 1, typo_result.stdout + typo_result.stderr)
        self.assertIn("production_overlay.referrals.hmac_keys.k1", typo_result.stdout)
        self.assertIn("overlay env reference is not listed in source-of-truth manifest", typo_result.stdout)
        self.assertEqual(missing_result.returncode, 1, missing_result.stdout + missing_result.stderr)
        self.assertIn("production_overlay.referrals.x_api_bearer_token", missing_result.stdout)
        self.assertIn("overlay env reference is absent from live coordinator.env inventory", missing_result.stdout)

    def test_unknown_env_key_exits_nonzero_without_value(self):
        result = self.run_tool(
            "--tracked-config",
            str(DATA / "known-drift-tracked.yaml"),
            "--live-config",
            str(DATA / "known-drift-live.yaml"),
            "--live-overlay",
            str(DATA / "known-drift-overlay.yaml"),
            "--live-env",
            str(DATA / "unknown-env.env"),
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("coordinator.env.CATALOG_CANARY_PRIVATE_KEY", result.stdout)
        self.assertNotIn("redaction-sentinel-not-for-output", result.stdout)

    def test_duplicate_env_key_is_unknown(self):
        manifest = reconcile_module.load_yaml_file(ROOT / "ops/pearl/config/source-of-truth.yaml")
        _, unknown = reconcile_module.classify_env_lines(
            reconcile_module.parse_env_lines("OPERATOR_KEY=first\nOPERATOR_KEY=second\n"),
            manifest,
        )
        self.assertEqual([finding.path for finding in unknown], ["coordinator.env.OPERATOR_KEY"])
        self.assertIn("duplicate env key", unknown[0].message)

    def test_ssh_target_validation_rejects_option_like_target(self):
        result = self.run_tool("--ssh-target=-oProxyCommand=echo")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("ssh target must be a conservative alias or user@host", result.stderr)

    def test_ssh_env_inventory_preserves_malformed_line_marker(self):
        manifest = reconcile_module.load_yaml_file(ROOT / "ops/pearl/config/source-of-truth.yaml")
        calls = []

        def fake_run_ssh(target, remote_script):
            calls.append(remote_script)
            if "coordinator.pearl-overlays.yaml" in remote_script:
                return "coordinator:\n  compatibility_set:\n    target_id: example\n"
            if "coordinator.env" in remote_script:
                return "OPERATOR_KEY=<MASKED>\n__MACPROVIDER_MALFORMED_ENV_LINE_42=<MASKED>\n"
            return "{}\n"

        original = reconcile_module.run_ssh
        reconcile_module.run_ssh = fake_run_ssh
        try:
            live_evidence = reconcile_module.read_live_via_ssh("pearl", manifest)
        finally:
            reconcile_module.run_ssh = original

        self.assertTrue(any("__MACPROVIDER_MALFORMED_ENV_LINE_" in call for call in calls))
        _, unknown = reconcile_module.classify_env_lines(
            reconcile_module.parse_env_lines(live_evidence.env_text),
            manifest,
        )
        self.assertEqual([finding.path for finding in unknown], ["coordinator.env.line_42"])

    def test_ssh_missing_overlay_evidence_is_unknown(self):
        manifest_path = ROOT / "ops/pearl/config/source-of-truth.yaml"

        def fake_run_ssh(target, remote_script):
            if "coordinator.pearl-overlays.yaml" in remote_script:
                return "__MACPROVIDER_OVERLAY_MISSING__\n"
            if "coordinator.env" in remote_script:
                return "OPERATOR_KEY=<MASKED>\nGATEWAY_SERVICE_TOKEN=<MASKED>\n"
            return (DATA / "known-drift-live.yaml").read_text(encoding="utf-8")

        original = reconcile_module.run_ssh
        reconcile_module.run_ssh = fake_run_ssh
        try:
            output, rc = reconcile_module.reconcile(
                manifest_path=manifest_path,
                tracked_config_path=DATA / "known-drift-tracked.yaml",
                live_config_path=None,
                live_overlay_path=None,
                live_env_path=None,
                ssh_target="pearl",
            )
        finally:
            reconcile_module.run_ssh = original

        self.assertEqual(rc, 1, output)
        self.assertIn("production_overlay: overlay evidence file is missing or unreadable", output)

    def test_present_empty_overlay_is_inference_not_unknown(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            overlay_path = Path(tmpdir) / "empty-overlay.yaml"
            overlay_path.write_text("", encoding="utf-8")
            result = self.run_tool(
                "--tracked-config",
                str(DATA / "known-drift-tracked.yaml"),
                "--live-config",
                str(DATA / "known-drift-live.yaml"),
                "--live-overlay",
                str(overlay_path),
                "--live-env",
                str(DATA / "known-drift.env"),
            )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(
            "production_overlay: overlay file absent or empty in provided evidence",
            result.stdout,
        )
        self.assertIn("Unknown:\n- none", result.stdout)

    def test_malformed_provider_rows_are_unknown(self):
        live_config = reconcile_module.load_yaml_file(DATA / "known-drift-live.yaml")
        live_config["providers"].append({"endpoint_url": "https://example.invalid"})
        live_config["providers"].append("not-a-provider-row")
        live_config["providers"].append({"provider_id": "augustass-macbook-air", "endpoint_url": ""})

        index = reconcile_module.provider_index(live_config, side="live")

        paths = [finding.path for finding in index.unknown]
        self.assertIn("providers.live[2]", paths)
        self.assertIn("providers.live[3]", paths)
        self.assertIn("providers.live[4].provider_id", paths)

    def test_live_only_registered_provider_unknown_fields_are_unknown(self):
        manifest = reconcile_module.load_yaml_file(ROOT / "ops/pearl/config/source-of-truth.yaml")
        tracked_config = reconcile_module.load_yaml_file(DATA / "known-drift-tracked.yaml")
        live_config = reconcile_module.load_yaml_file(DATA / "known-drift-live.yaml")
        live_config["providers"][1]["private_note"] = "short-note"
        live_config["providers"][1]["tags"] = [{"private_note": "nested-short-note"}]
        live_config["providers"][1]["endpoint_url"] = 7

        evidence, inference, unknown = reconcile_module.classify_provider_rows(
            reconcile_module.provider_index(tracked_config, side="tracked").rows,
            reconcile_module.provider_index(live_config, side="live").rows,
            manifest,
        )
        rendered = reconcile_module.render_findings(evidence, inference, unknown)

        self.assertIn("providers.augustass-macbook-air.private_note", rendered)
        self.assertIn("providers.augustass-macbook-air.tags", rendered)
        self.assertIn("providers.augustass-macbook-air.endpoint_url", rendered)
        self.assertIn("value=<MASKED>", rendered)
        self.assertNotIn("short-note", rendered)
        self.assertNotIn("nested-short-note", rendered)

    def test_secret_container_children_are_masked(self):
        result = self.run_tool(
            "--tracked-config",
            str(DATA / "known-drift-tracked.yaml"),
            "--live-config",
            str(DATA / "unknown-live.yaml"),
            "--live-overlay",
            str(DATA / "known-drift-overlay.yaml"),
            "--live-env",
            str(DATA / "known-drift.env"),
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("auth.operator_keys.alice", result.stdout)
        self.assertIn("live=<MASKED>", result.stdout)
        self.assertNotIn("inline-redaction-sentinel-not-for-output", result.stdout)


if __name__ == "__main__":
    unittest.main()
