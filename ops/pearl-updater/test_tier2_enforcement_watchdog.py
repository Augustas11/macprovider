import importlib.machinery
import importlib.util
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).with_name("macprovider-tier2-enforcement-watchdog")
LOADER = importlib.machinery.SourceFileLoader("tier2_enforcement_watchdog", str(SCRIPT))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
watchdog = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(watchdog)
REAL_RELOAD_SERVICE_IF_ACTIVE = watchdog.reload_service_if_active
REAL_SCHEDULE_WATCHDOG = watchdog.schedule_watchdog


class Tier2EnforcementWatchdogTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        config_root = root / "opt" / "macprovider"
        state_root = root / "state"
        releases = config_root / "autotune" / "releases"
        release = releases / "test-release"
        release.mkdir(parents=True)
        current = config_root / "autotune" / "current"
        current.symlink_to(release)
        config_root.mkdir(parents=True, exist_ok=True)
        self.config = config_root / "coordinator.yaml"
        self.config.write_text(
            "server:\n"
            "  address: 127.0.0.1\n"
            "tier2:\n"
            "  catalog_path: /opt/macprovider/autotune/current/tier2-catalog.json\n"
            "  catalog_public_key: test\n"
            "  require_hash_verified: false\n"
            "pool:\n"
            "  canary_enabled: false\n",
            encoding="utf-8",
        )
        os.chmod(self.config, 0o640)
        state_root.mkdir(mode=0o700)
        patches = {
            "CONFIG_PATH": self.config,
            "CURRENT_RELEASE": current,
            "RELEASE_ROOT": releases,
            "STATE_ROOT": state_root,
            "JOURNAL_PATH": state_root / "tier2-enforcement-transaction.json",
            "BACKUP_ROOT": state_root / "tier2-enforcement-backups",
            "LOCK_PATH": root / "updater.lock",
            "SELF_PATH": root / "watchdog",
            "TRUSTED_UID": os.getuid(),
            "TRUSTED_GID": os.getgid(),
        }
        self.patchers = [mock.patch.object(watchdog, name, value) for name, value in patches.items()]
        for patcher in self.patchers:
            patcher.start()
        self.schedule = mock.patch.object(watchdog, "schedule_watchdog")
        self.cancel = mock.patch.object(watchdog, "cancel_watchdog")
        self.reload = mock.patch.object(watchdog, "reload_service")
        self.rollback_reload = mock.patch.object(watchdog, "reload_service_if_active")
        self.schedule_mock = self.schedule.start()
        self.cancel_mock = self.cancel.start()
        self.reload_mock = self.reload.start()
        self.rollback_reload_mock = self.rollback_reload.start()

    def tearDown(self):
        self.rollback_reload.stop()
        self.reload.stop()
        self.cancel.stop()
        self.schedule.stop()
        for patcher in reversed(self.patchers):
            patcher.stop()
        self.temporary.cleanup()

    def test_arm_and_commit_leave_enforcement_true_without_journal(self):
        transaction = watchdog.arm()

        self.assertIn("require_hash_verified: true", self.config.read_text(encoding="utf-8"))
        self.assertTrue(watchdog.JOURNAL_PATH.is_file())
        self.assertEqual(stat.S_IMODE(watchdog.JOURNAL_PATH.stat().st_mode), 0o600)
        self.schedule_mock.assert_called_once_with()
        self.reload_mock.assert_called_once_with()

        committed = watchdog.commit(transaction["transaction_id"])

        self.assertEqual(committed["phase"], "committed")
        self.assertFalse(watchdog.JOURNAL_PATH.exists())
        self.assertIn("require_hash_verified: true", self.config.read_text(encoding="utf-8"))
        self.cancel_mock.assert_called_once_with()

    def test_rollback_restores_false_and_clears_journal(self):
        transaction = watchdog.arm()
        self.reload_mock.reset_mock()

        restored = watchdog.rollback(transaction["transaction_id"])

        self.assertEqual(restored["phase"], "rolled_back")
        self.assertIn("require_hash_verified: false", self.config.read_text(encoding="utf-8"))
        self.assertFalse(watchdog.JOURNAL_PATH.exists())
        self.rollback_reload_mock.assert_called_once_with()

    def test_arm_reload_failure_rolls_back_before_returning(self):
        self.reload_mock.side_effect = [
            watchdog.EnforcementError("reload failed"),
        ]

        with self.assertRaisesRegex(watchdog.EnforcementError, "reload failed"):
            watchdog.arm()

        self.assertIn("require_hash_verified: false", self.config.read_text(encoding="utf-8"))
        self.assertFalse(watchdog.JOURNAL_PATH.exists())
        self.reload_mock.assert_called_once_with()
        self.rollback_reload_mock.assert_called_once_with()

    def test_arm_and_rollback_failure_preserve_durable_recovery_identity(self):
        self.reload_mock.side_effect = watchdog.EnforcementError("reload failed")
        self.rollback_reload_mock.side_effect = watchdog.EnforcementError(
            "rollback reload failed"
        )

        with self.assertRaisesRegex(
            watchdog.EnforcementError,
            r"arm failed and immediate rollback failed; transaction [0-9a-f]{64} remains durable",
        ) as raised:
            watchdog.arm()

        self.assertIn("arm=reload failed", str(raised.exception))
        self.assertIn("rollback=rollback reload failed", str(raised.exception))
        self.assertIn("require_hash_verified: false", self.config.read_text(encoding="utf-8"))
        self.assertTrue(watchdog.JOURNAL_PATH.exists())

    def test_commit_cancel_failure_preserves_recovery_state(self):
        transaction = watchdog.arm()
        self.cancel_mock.side_effect = watchdog.EnforcementError("timer cancellation failed")

        with self.assertRaisesRegex(watchdog.EnforcementError, "timer cancellation failed"):
            watchdog.commit(transaction["transaction_id"])

        self.assertTrue(watchdog.JOURNAL_PATH.exists())
        self.assertTrue(Path(transaction["backup_path"]).exists())
        self.assertIn("require_hash_verified: true", self.config.read_text(encoding="utf-8"))

        journal = watchdog.load_journal()
        self.assertIsNotNone(journal)
        self.assertEqual(journal["phase"], "committed")
        self.cancel_mock.side_effect = None
        reconciled = watchdog.rollback()
        self.assertEqual(reconciled["phase"], "committed")
        self.assertFalse(watchdog.JOURNAL_PATH.exists())
        self.assertIn("require_hash_verified: true", self.config.read_text(encoding="utf-8"))
        self.rollback_reload_mock.assert_not_called()

    def test_reconcile_restores_false_despite_release_drift(self):
        transaction = watchdog.arm()
        other = watchdog.RELEASE_ROOT / "other-release"
        other.mkdir()
        watchdog.CURRENT_RELEASE.unlink()
        watchdog.CURRENT_RELEASE.symlink_to(other)

        restored = watchdog.rollback()

        self.assertEqual(restored["phase"], "rolled_back")
        self.assertEqual(restored["observed_release_pointer"], str(other.resolve()))
        self.assertFalse(watchdog.JOURNAL_PATH.exists())
        self.assertFalse(Path(transaction["backup_path"]).exists())
        self.assertIn("require_hash_verified: false", self.config.read_text(encoding="utf-8"))

    def test_stale_config_refuses_rollback_without_overwrite(self):
        transaction = watchdog.arm()
        self.config.write_text("tier2:\n  require_hash_verified: false\n# drift\n", encoding="utf-8")
        os.chmod(self.config, 0o640)

        with self.assertRaisesRegex(watchdog.EnforcementError, "live coordinator config changed"):
            watchdog.rollback(transaction["transaction_id"])

        self.assertIn("# drift", self.config.read_text(encoding="utf-8"))
        self.assertTrue(watchdog.JOURNAL_PATH.exists())

    def test_transaction_identity_is_required_for_operator_commit_and_rollback(self):
        args = watchdog.parse_args(["--commit", "--transaction-id", "a" * 64])
        self.assertTrue(args.commit)
        with self.assertRaises(SystemExit):
            watchdog.parse_args(["--rollback"])
        with self.assertRaisesRegex(watchdog.EnforcementError, "identity changed"):
            watchdog.require_transaction({"transaction_id": "a" * 64}, "b" * 64)

    def test_rollback_skips_reload_when_service_is_inactive_at_boot(self):
        with mock.patch.object(watchdog.subprocess, "run") as run_mock:
            run_mock.return_value = mock.Mock(returncode=3)
            REAL_RELOAD_SERVICE_IF_ACTIVE()
        run_mock.assert_called_once_with(
            ["systemctl", "is-active", "--quiet", watchdog.SERVICE],
            check=False,
            text=True,
            capture_output=True,
            timeout=15,
        )

    def test_transient_watchdog_retries_failed_reconciliation(self):
        with (
            mock.patch.object(watchdog, "run") as run_mock,
            mock.patch.object(watchdog, "run_optional"),
        ):
            REAL_SCHEDULE_WATCHDOG()
        systemd_run = run_mock.call_args_list[0].args[0]
        self.assertIn("--property=Restart=on-failure", systemd_run)
        self.assertIn("--property=RestartSec=30s", systemd_run)
        self.assertIn("--collect", systemd_run)

    def test_flip_requires_direct_tier2_enforcement_field(self):
        with self.assertRaisesRegex(watchdog.EnforcementError, "exactly false"):
            watchdog.flip_to_enforced(
                b"tier2:\n"
                b"  nested:\n"
                b"    require_hash_verified: false\n"
            )
        updated = watchdog.flip_to_enforced(
            b"tier2:\n"
            b"    catalog_path: /release/tier2-catalog.json\n"
            b"    require_hash_verified: false\n"
        )
        self.assertIn(b"    require_hash_verified: true\n", updated)


if __name__ == "__main__":
    unittest.main()
