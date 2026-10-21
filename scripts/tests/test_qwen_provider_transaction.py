import importlib.util
import json
import os
import plistlib
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "scripts/ops/lib/qwen-provider-transaction.py"
CONTROLLER_PATH = ROOT / "scripts/ops/qwen-opencode-e2e.sh"
SPEC = importlib.util.spec_from_file_location("qwen_provider_transaction", MODULE_PATH)
assert SPEC and SPEC.loader
transaction = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(transaction)


BASE_CONFIG = """# operator config
model: zai-org/glm-5.3-flash
model_artifact_sha256: {glm_sha}
max_context_override: 65536
max_concurrency_override: 4
provider_token: top-secret-never-journal
coordinator_endpoint: https://coordinator.invalid
""".format(glm_sha="a" * 64)


class QwenProviderTransactionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.config = self.root / "config.yaml"
        self.config.write_text(BASE_CONFIG, encoding="utf-8")
        os.chmod(self.config, 0o600)
        self.journal = self.root / "journal.json"
        self.validator = self.root / "validator"
        self.validator.write_text(
            "#!/bin/sh\n"
            "test \"$1 $2 $3 $4\" = \"models list --json --config\" || exit 91\n"
            "grep -q '^model:' \"$5\" || exit 92\n",
            encoding="utf-8",
        )
        os.chmod(self.validator, stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR)

    def tearDown(self):
        self.temporary.cleanup()

    def args(self, **overrides):
        values = {
            "config": str(self.config),
            "journal": str(self.journal),
            "validator": str(self.validator),
            "transaction_id": "test-transaction",
            "binary_version": "9.8.7",
            "provider_id": "provider-test",
            "cli_sha256": "1" * 64,
            "code_cdhash": "2" * 40,
            "team_id": "TEAM123",
            "signing_identifier": "tech.malibu.macprovider",
            "written_handoff_sha256": "3" * 64,
            "baseline_catalog_version": "signed-release",
            "baseline_catalog_hash": "b" * 64,
            "baseline_pid": 4242,
            "rate_card_version": "signed-rates",
            "remote_scratch": str(self.root / "macprovider-qwen-e2e.test"),
        }
        values.update(overrides)
        return type("Args", (), values)()

    def test_prepare_and_restore_preserve_secret_without_journaling_it(self):
        prepared = transaction.prepare(self.args())
        self.assertEqual(prepared["status"], "prepared")
        changed = self.config.read_text(encoding="utf-8")
        self.assertIn("provider_token: top-secret-never-journal", changed)
        self.assertIn("enable_warm_swap: true", changed)
        self.assertIn("publishes_supported_models: false", changed)
        self.assertIn("  - qwen3-coder-30b-a3b-instruct", changed)
        self.assertIn("  - qwen/qwen3-30b-a3b-instruct-2507", changed)
        self.assertNotIn("top-secret", self.journal.read_text(encoding="utf-8"))
        state = transaction.inspect(self.args())
        self.assertEqual(state["baseline_status"]["pid"], 4242)
        self.assertEqual(state["release_binding"]["binary_version"], "9.8.7")
        self.assertEqual(state["market_binding"]["rate_card_version"], "signed-rates")

        restored = transaction.restore(self.args())
        self.assertEqual(restored["status"], "config_restored")
        self.assertEqual(self.config.read_text(encoding="utf-8"), BASE_CONFIG)
        self.assertTrue(transaction.restore(self.args())["idempotent"])
        transaction.finish_restore(self.args())
        self.assertTrue(transaction.finish_restore(self.args())["idempotent"])

    def test_validator_failure_leaves_config_unchanged_and_no_journal(self):
        self.validator.write_text("#!/bin/sh\nexit 9\n", encoding="utf-8")
        os.chmod(self.validator, 0o700)
        with self.assertRaises(transaction.Refusal):
            transaction.prepare(self.args())
        self.assertEqual(self.config.read_text(encoding="utf-8"), BASE_CONFIG)
        self.assertTrue(self.journal.exists())
        self.assertTrue(transaction.inspect(self.args())["restore_required"])
        self.validator.write_text(
            "#!/bin/sh\ntest \"$1 $2 $3 $4\" = \"models list --json --config\"\n",
            encoding="utf-8",
        )
        os.chmod(self.validator, 0o700)
        transaction.restore(self.args())

    def test_post_rename_failure_keeps_armed_journal_recoverable(self):
        real_replace = transaction.validate_then_replace

        def replace_then_fail(config, _validator, candidate):
            config.write_bytes(candidate)
            raise OSError("simulated directory fsync failure after rename")

        transaction.validate_then_replace = replace_then_fail
        try:
            with self.assertRaises(OSError):
                transaction.prepare(self.args())
        finally:
            transaction.validate_then_replace = real_replace
        journal = json.loads(self.journal.read_text(encoding="utf-8"))
        self.assertEqual(journal["phase"], "armed")
        self.assertEqual(transaction.sha256(self.config.read_bytes()), journal["prepared_config_sha256"])
        transaction.restore(self.args())
        self.assertEqual(self.config.read_text(encoding="utf-8"), BASE_CONFIG)

    def test_duplicate_top_level_key_is_refused(self):
        self.config.write_text(BASE_CONFIG + "model: other\n", encoding="utf-8")
        with self.assertRaisesRegex(transaction.Refusal, "duplicate top-level"):
            transaction.prepare(self.args())

    def test_unowned_change_blocks_restore(self):
        transaction.prepare(self.args())
        self.config.write_text(
            self.config.read_text(encoding="utf-8").replace(
                "coordinator_endpoint: https://coordinator.invalid",
                "coordinator_endpoint: https://other.invalid",
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(transaction.Refusal, "non-owned"):
            transaction.restore(self.args())

    def test_symlink_config_is_refused(self):
        target = self.root / "real-config.yaml"
        self.config.rename(target)
        self.config.symlink_to(target)
        with self.assertRaisesRegex(transaction.Refusal, "regular file"):
            transaction.prepare(self.args())

    def test_owned_adoption_change_can_be_checkpointed_then_restored(self):
        transaction.prepare(self.args())
        recommendation = self.recommendation()
        verify = self.verify_args(recommendation)
        intent_args = self.args(
            phase="adopting_first", recommendation=verify.recommendation, target=verify.target,
            binary_version=verify.binary_version, catalog_version=verify.catalog_version,
            catalog_hash=verify.catalog_hash,
        )
        transaction.begin_adoption(intent_args)
        self.apply_recommendation(verify)
        result = transaction.checkpoint(self.args(
            phase="serving_first",
            recommendation=verify.recommendation,
            target=verify.target,
            binary_version=verify.binary_version,
            catalog_version=verify.catalog_version,
            catalog_hash=verify.catalog_hash,
        ))
        self.assertEqual(result["phase"], "serving_first")
        transaction.restore(self.args())
        transaction.finish_restore(self.args())
        self.assertEqual(self.config.read_text(encoding="utf-8"), BASE_CONFIG)

    def test_owned_change_after_checkpoint_blocks_restore(self):
        self.test_owned_adoption_change_can_be_checkpointed_then_restored()
        # Start a new transaction after the first test's restored journal.
        transaction.prepare(self.args(transaction_id="second"))
        self.config.write_text(
            self.config.read_text(encoding="utf-8").replace(
                "model: zai-org/glm-5.3-flash", "model: arbitrary/external"
            ), encoding="utf-8")
        with self.assertRaisesRegex(transaction.Refusal, "owned config fields"):
            transaction.restore(self.args())

    def test_armed_intended_transition_can_be_restored_before_checkpoint(self):
        transaction.prepare(self.args())
        recommendation = self.recommendation()
        verify = self.verify_args(recommendation)
        transaction.begin_adoption(self.args(
            phase="adopting_first", recommendation=verify.recommendation, target=verify.target,
            binary_version=verify.binary_version, catalog_version=verify.catalog_version,
            catalog_hash=verify.catalog_hash, rate_card_version=verify.rate_card_version,
        ))
        self.apply_recommendation(verify)
        transaction.restore(self.args())
        self.assertEqual(self.config.read_text(encoding="utf-8"), BASE_CONFIG)
        self.assertEqual(transaction.inspect(self.args())["status"], "config_restored")
        transaction.finish_restore(self.args())
        self.assertFalse(transaction.inspect(self.args())["restore_required"])

    def test_supported_models_change_is_not_accepted_as_intended_adoption(self):
        transaction.prepare(self.args())
        verify = self.verify_args(self.recommendation())
        transaction.begin_adoption(self.args(
            phase="adopting_first", recommendation=verify.recommendation, target=verify.target,
            binary_version=verify.binary_version, catalog_version=verify.catalog_version,
            catalog_hash=verify.catalog_hash, rate_card_version=verify.rate_card_version,
        ))
        self.apply_recommendation(verify)
        self.config.write_text(
            self.config.read_text(encoding="utf-8").replace(
                "supported_models:\n", "supported_models:\n  - unrelated/external\n"
            ), encoding="utf-8")
        with self.assertRaisesRegex(transaction.Refusal, "owned config fields"):
            transaction.restore(self.args())

    def test_acceptance_complete_uses_serving_checkpoint_sha(self):
        transaction.prepare(self.args())
        verify = self.verify_args(self.recommendation())
        transaction.begin_adoption(self.args(
            phase="adopting_second", recommendation=verify.recommendation, target=verify.target,
            binary_version=verify.binary_version, catalog_version=verify.catalog_version,
            catalog_hash=verify.catalog_hash, rate_card_version=verify.rate_card_version,
        ))
        self.apply_recommendation(verify)
        transaction.checkpoint(self.args(
            phase="serving_second", recommendation=verify.recommendation, target=verify.target,
            binary_version=verify.binary_version, catalog_version=verify.catalog_version,
            catalog_hash=verify.catalog_hash, rate_card_version=verify.rate_card_version,
        ))
        result = transaction.checkpoint(self.args(
            phase="acceptance_complete", recommendation=verify.recommendation,
            target=verify.target, binary_version=verify.binary_version,
            catalog_version=verify.catalog_version, catalog_hash=verify.catalog_hash,
            rate_card_version=verify.rate_card_version,
        ))
        self.assertEqual(result["phase"], "acceptance_complete")

    def test_restore_post_replace_journal_failure_is_recoverable(self):
        transaction.prepare(self.args())
        real_write = transaction.write_journal

        def fail_config_restored(path, value, **kwargs):
            if value.get("phase") == "config_restored":
                raise OSError("simulated journal fsync failure after config rename")
            return real_write(path, value, **kwargs)

        transaction.write_journal = fail_config_restored
        try:
            with self.assertRaises(OSError):
                transaction.restore(self.args())
        finally:
            transaction.write_journal = real_write
        self.assertEqual(self.config.read_text(encoding="utf-8"), BASE_CONFIG)
        self.assertEqual(transaction.inspect(self.args())["status"], "restoring")
        self.assertEqual(transaction.restore(self.args())["status"], "config_restored")

    def test_failed_readiness_leaves_restoration_required(self):
        transaction.prepare(self.args())
        self.assertEqual(transaction.restore(self.args())["status"], "config_restored")
        state = transaction.inspect(self.args())
        self.assertEqual(state["status"], "config_restored")
        self.assertTrue(state["restore_required"])
        self.assertTrue(transaction.restore(self.args())["idempotent"])
        transaction.finish_restore(self.args())
        self.assertFalse(transaction.inspect(self.args())["restore_required"])

    def recommendation(self, target_name="qwen3-coder-30b-a3b-instruct"):
        target = transaction.TARGETS[target_name]
        return {
            "schema_version": "autotune_recommend.v1",
            "recommended_model": target["catalog_key"],
            "warnings": [],
            "hardware": {"binary_version": "9.8.7"},
            "inputs": {
                "candidate_catalog_version": "signed-release",
                "rate_card_version": "signed-rates",
            },
            "candidates": [{"model": target["catalog_key"], "eligible": True}],
            "serve_config": {
                "model": target["catalog_key"],
                "model_artifact_path": "/cache/model",
                "model_artifact_sha256": target["sha256"],
                "model_catalog_key": target["catalog_key"],
                "model_catalog_model_id": target["model_id"],
                "model_catalog_revision": target["revision"],
                "model_catalog_sha256": target["sha256"],
                "model_catalog_version": "signed-release",
                "model_catalog_hash": "b" * 64,
                "max_context_override": 16384,
                "max_concurrency_override": 12,
                "donor_mode": False,
            },
        }

    def apply_recommendation(self, verify):
        blocks, owned = transaction.split_blocks(self.config.read_bytes())
        for key in transaction.RECOMMENDATION_OWNED:
            owned.pop(key, None)
        expected = transaction.expected_owned(verify)
        for key, value in expected.items():
            if key != "max_context_override_provenance":
                owned[key] = f"{key}: {value}\n".encode()
        generated_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        owned["max_context_override_provenance"] = (
            'max_context_override_provenance: {source: "recommendation_apply", value: 16384, '
            f'model: "{verify.target}", generated_at: "{generated_at}"}}\n'
        ).encode()
        self.config.write_bytes(transaction.render(blocks, owned))

    def verify_args(self, recommendation, target="qwen3-coder-30b-a3b-instruct"):
        path = self.root / "recommendation.json"
        path.write_text(json.dumps(recommendation), encoding="utf-8")
        return type("Args", (), {
            "recommendation": str(path),
            "target": target,
            "binary_version": "9.8.7",
            "catalog_version": "signed-release",
            "catalog_hash": "b" * 64,
            "rate_card_version": "signed-rates",
        })()

    def test_exact_recommendation_is_accepted(self):
        verify = self.verify_args(self.recommendation())
        result = transaction.verify_recommendation(verify)
        self.assertEqual(result["status"], "verified")
        expected = transaction.expected_owned(verify)
        self.assertEqual(expected["max_concurrency_override"], "8")
        self.assertEqual(expected["max_concurrency_depth_override"], "12")
        self.assertNotIn("donor_mode", expected)
        self.assertNotIn("max_concurrency_source", expected)

    def test_wrong_artifact_or_release_is_refused(self):
        value = self.recommendation()
        value["serve_config"]["model_artifact_sha256"] = "c" * 64
        with self.assertRaisesRegex(transaction.Refusal, "qualified target"):
            transaction.verify_recommendation(self.verify_args(value))
        value = self.recommendation()
        value["inputs"]["candidate_catalog_version"] = "stale-release"
        with self.assertRaisesRegex(transaction.Refusal, "live signed release"):
            transaction.verify_recommendation(self.verify_args(value))
        value = self.recommendation()
        value["inputs"]["rate_card_version"] = "stale-rates"
        with self.assertRaisesRegex(transaction.Refusal, "live signed rate card"):
            transaction.verify_recommendation(self.verify_args(value))

    def test_draft_config_and_small_context_are_refused(self):
        self.config.write_text(BASE_CONFIG + "draft_model: local/draft\n", encoding="utf-8")
        with self.assertRaisesRegex(transaction.Refusal, "draft model"):
            transaction.prepare(self.args())
        self.config.write_text(BASE_CONFIG, encoding="utf-8")
        value = self.recommendation()
        value["serve_config"]["max_context_override"] = 8192
        with self.assertRaisesRegex(transaction.Refusal, "16384"):
            transaction.verify_recommendation(self.verify_args(value))

    def test_unfinished_journal_prioritizes_restore(self):
        transaction.prepare(self.args())
        state = transaction.inspect(self.args())
        self.assertTrue(state["restore_required"])
        transaction.restore(self.args())
        transaction.finish_restore(self.args())
        self.assertFalse(transaction.inspect(self.args())["restore_required"])

    def test_restored_config_with_scratch_left_requires_cleanup(self):
        scratch = Path(self.args().remote_scratch)
        scratch.mkdir(mode=0o700)
        transaction.prepare(self.args())
        transaction.restore(self.args())
        transaction.finish_restore(self.args())
        state = transaction.inspect(self.args())
        self.assertEqual(state["status"], "restored")
        self.assertTrue(state["scratch_cleanup_required"])
        self.assertTrue(state["restore_required"])

class RestartServiceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name).resolve()
        self.directory = self.home / "Library" / "LaunchAgents"
        self.directory.mkdir(parents=True, mode=0o700)
        self.binary = self.home / "macprovider-cli"
        self.binary.write_text("reviewed executable fixture\n")
        self.binary.chmod(0o700)
        self.config = self.home / "config.yaml"
        self.config.write_text(BASE_CONFIG)
        self.config.chmod(0o600)
        self.plist = self.directory / "live.malibu.provider.plist"
        self.arguments = [str(self.binary), "serve", "--config", str(self.config)]
        self.document = {"Label": transaction.PROVIDER_LABEL,
                         "ProgramArguments": self.arguments}
        self.write_plist()
        self.args = transaction.parser().parse_args([
            "restart-service", "--config", str(self.config),
            "--validator", str(self.binary),
        ])
        self.target = f"gui/{os.getuid()}/{transaction.PROVIDER_LABEL}"
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(Path, "home", return_value=self.home).start()
        self.run = mock.patch.object(transaction.subprocess, "run").start()
        self.run.side_effect = self.command
        self.loaded = True
        self.pid = 1234
        self.loaded_binary = str(self.binary)
        self.loaded_program = str(self.binary)
        self.loaded_config = str(self.config)
        self.loaded_plist = str(self.plist)
        self.kickstart_code = 0
        self.validator_code = 0

    def write_plist(self):
        self.plist.write_bytes(plistlib.dumps(self.document))
        self.plist.chmod(0o600)

    def command(self, argv, **kwargs):
        if argv[:2] == ["/bin/launchctl", "print"]:
            arguments = [self.loaded_binary, "serve", "--config", self.loaded_config]
            output = (f"{self.target} = {{\n\tpath = {self.loaded_plist}\n"
                      f"\tprogram = {self.loaded_program}\n\targuments = {{\n"
                      + "".join(f"\t\t{value}\n" for value in arguments) + "\t}\n")
            if self.pid is not None:
                output += f"\tpid = {self.pid}\n"
            return subprocess.CompletedProcess(argv, 0 if self.loaded else 113,
                                               output + "}\n", "")
        if argv[:2] == ["/bin/launchctl", "kickstart"]:
            return subprocess.CompletedProcess(argv, self.kickstart_code, "", "")
        self.assertEqual(argv, [str(self.binary), "models", "list", "--json",
                                "--config", str(self.config)])
        return subprocess.CompletedProcess(argv, self.validator_code, "", "")

    def assert_no_kickstart(self):
        self.assertFalse(any(call.args[0][1] == "kickstart"
                             for call in self.run.call_args_list))

    def test_running_and_stopped_loaded_jobs_are_restarted(self):
        for pid in (1234, None):
            with self.subTest(pid=pid):
                self.pid = pid
                self.run.reset_mock()
                result = self.args.run(self.args)
                self.assertEqual(result["status"], "restart_requested")
                self.assertEqual(self.run.call_args.args[0],
                                 ["/bin/launchctl", "kickstart", "-k", self.target])

    def test_loaded_job_different_binary_or_config_is_refused(self):
        for attribute in ("loaded_binary", "loaded_program", "loaded_config", "loaded_plist"):
            with self.subTest(attribute=attribute):
                original = getattr(self, attribute)
                setattr(self, attribute, "/different/path")
                with self.assertRaisesRegex(transaction.Refusal, "loaded provider.*mismatch"):
                    transaction.restart_service(self.args)
                self.assert_no_kickstart()
                setattr(self, attribute, original)

    def test_plist_different_program_or_arguments_are_refused(self):
        for changes in ({"Program": "/wrong/binary"},
                        {"ProgramArguments": ["/wrong/binary", *self.arguments[1:]]},
                        {"ProgramArguments": [*self.arguments[:3], "/wrong/config"]}):
            with self.subTest(changes=changes):
                self.document = {"Label": transaction.PROVIDER_LABEL,
                                 "ProgramArguments": self.arguments, **changes}
                self.write_plist()
                with self.assertRaisesRegex(transaction.Refusal, "LaunchAgent.*mismatch"):
                    transaction.restart_service(self.args)
                self.run.assert_not_called()

    def test_missing_loaded_job_is_refused_without_bootstrap(self):
        self.loaded = False
        with self.assertRaisesRegex(transaction.Refusal, "not loaded"):
            transaction.restart_service(self.args)
        self.assertEqual(self.run.call_count, 1)

    def test_missing_or_symlinked_plist_is_refused(self):
        self.plist.unlink()
        with self.assertRaisesRegex(transaction.Refusal, "missing file"):
            transaction.restart_service(self.args)
        self.plist.symlink_to(self.config)
        with self.assertRaisesRegex(transaction.Refusal, "regular file"):
            transaction.restart_service(self.args)
        self.run.assert_not_called()

    def test_writable_plist_or_directory_is_refused(self):
        for path in (self.plist, self.directory):
            with self.subTest(path=path):
                previous = path.stat().st_mode
                path.chmod(previous | 0o020)
                with self.assertRaisesRegex(transaction.Refusal, "unsafe provider LaunchAgent"):
                    transaction.restart_service(self.args)
                self.run.assert_not_called()
                path.chmod(previous)

    def test_kickstart_failure_is_not_reported_as_restart(self):
        self.kickstart_code = 5
        with self.assertRaisesRegex(transaction.Refusal, "kickstart failed"):
            transaction.restart_service(self.args)

    def test_invalid_config_does_not_restart_job(self):
        self.validator_code = 9
        with self.assertRaisesRegex(transaction.Refusal, "rejected candidate config"):
            transaction.restart_service(self.args)
        self.assert_no_kickstart()


if __name__ == "__main__":
    unittest.main()
