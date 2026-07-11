#!/usr/bin/env python3
from __future__ import annotations

import ast
import grp
import importlib.machinery
import importlib.util
import io
import json
import os
import pwd
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("macprovider-pearl-update")
loader = importlib.machinery.SourceFileLoader("pearl_updater", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
assert spec is not None
updater_module = importlib.util.module_from_spec(spec)
sys.modules[loader.name] = updater_module
loader.exec_module(updater_module)

ALERT_SCRIPT = SCRIPT.with_name("macprovider-pearl-updater-alert")
alert_loader = importlib.machinery.SourceFileLoader("pearl_updater_alert", str(ALERT_SCRIPT))
alert_spec = importlib.util.spec_from_loader(alert_loader.name, alert_loader)
assert alert_spec is not None
alert_module = importlib.util.module_from_spec(alert_spec)
sys.modules[alert_loader.name] = alert_module
alert_loader.exec_module(alert_module)


class FixtureUpdater(updater_module.Updater):
    def audit(self, event, outcome, **fields):
        pass

    def run_command(self, argv, *, check=True, timeout, env=None):
        if Path(argv[0]).name in (updater_module.COORDINATOR_ASSET, updater_module.GATEWAY_ASSET):
            if "--validate-config" in argv:
                return subprocess.CompletedProcess(argv, 0, stdout="config: ok\n", stderr="")
            executions = getattr(self, "candidate_executions", None)
            if executions is not None:
                executions.append(Path(argv[0]).name)
            version = getattr(self, "candidate_version", "v1.8.27")
            return subprocess.CompletedProcess(argv, 0, stdout=version + "\n", stderr="")
        if Path(argv[0]).name in ("coordinator", "gateway"):
            versions = getattr(self, "installed_versions", {})
            version = versions.get(Path(argv[0]).name)
            if version is not None:
                return subprocess.CompletedProcess(argv, 0, stdout=version + "\n", stderr="")
        return super().run_command(argv, check=check, timeout=timeout, env=env)

    def run_candidate_command(self, argv, *, timeout, cwd, environment=None):
        executions = getattr(self, "candidate_executions", None)
        if executions is not None:
            executions.append(Path(argv[0]).name)
        invocations = getattr(self, "candidate_invocations", None)
        if invocations is not None:
            invocations.append(
                {
                    "argv": list(argv),
                    "cwd": cwd,
                    "environment": dict(environment or {}),
                    "uid": self.candidate_uid,
                    "gid": self.candidate_gid,
                }
            )
        if "--validate-config" in argv:
            return subprocess.CompletedProcess(argv, 0, stdout="config: ok\n", stderr="")
        version = getattr(self, "candidate_version", "v1.8.27")
        return subprocess.CompletedProcess(argv, 0, stdout=version + "\n", stderr="")


def fake_elf(label: str) -> bytes:
    header = bytearray(64)
    header[:4] = b"\x7fELF"
    header[4] = 2
    header[5] = 1
    header[6] = 1
    header[16:18] = (2).to_bytes(2, "little")
    header[18:20] = (62).to_bytes(2, "little")
    return bytes(header) + label.encode("ascii")


class PearlUpdaterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.key = self.root / "release-private.pem"
        self.public = self.root / "release-public.pem"
        subprocess.run(
            ["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(self.key)],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            ["openssl", "ec", "-in", str(self.key), "-pubout", "-out", str(self.public)],
            check=True,
            capture_output=True,
        )
        self.bundle = self.root / "bundle"
        self.bundle.mkdir()
        self.boot_id = self.root / "boot-id"
        self.boot_id.write_text("11111111-2222-3333-4444-555555555555\n")
        self.boot_id.chmod(0o600)
        self.make_bundle()
        self.config = updater_module.Config(
            enabled=True,
            minimum_version=updater_module.SemVer.parse("1.8.26"),
            retry_backoff_s=0,
            revoked_versions_file=self.root / "revoked",
        )
        (self.root / "revoked").write_text("# required fail-closed policy; intentionally empty\n")
        (self.root / "revoked").chmod(0o600)
        self.updater = FixtureUpdater(
            self.config,
            public_key=self.public,
            install_root=self.root / "opt",
            state_root=self.root / "state",
            audit_path=self.root / "audit.jsonl",
            lock_path=self.root / "updater.lock",
            gateway_db=self.root / "gateway.db",
            databases=(),
            gate_state_root=self.root / "gate-runtime",
            boot_id_path=self.boot_id,
            trusted_uid=os.geteuid(),
            candidate_uid=os.geteuid(),
            candidate_gid=os.getegid(),
            sleep=lambda _: None,
        )
        self.updater.candidate_executions = []
        self.updater.candidate_invocations = []

    def tearDown(self):
        self.temp.cleanup()

    def sign(self, payload: Path, signature: Path):
        subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", str(self.key), "-out", str(signature), str(payload)],
            check=True,
            capture_output=True,
        )

    def make_bundle(self, version: str = "1.8.27", advertised_version: str | None = None):
        tag = "v" + version
        advertised_version = advertised_version or version
        coordinator = self.bundle / updater_module.COORDINATOR_ASSET
        gateway = self.bundle / updater_module.GATEWAY_ASSET
        coordinator.write_bytes(fake_elf("coordinator"))
        gateway.write_bytes(fake_elf("gateway"))
        metadata = {
            "schema_version": 1,
            "repository": updater_module.PINNED_REPOSITORY,
            "tag": tag,
            "release_version": version,
            "commit": "a" * 40,
            "architecture": "linux-amd64",
            "provider_advertised_version": advertised_version,
            "components": {
                "coordinator": {
                    "asset": coordinator.name,
                    "sha256": updater_module.sha256_file(coordinator),
                    "embedded_version": tag,
                },
                "gateway": {
                    "asset": gateway.name,
                    "sha256": updater_module.sha256_file(gateway),
                    "embedded_version": tag,
                },
            },
        }
        metadata_path = self.bundle / "pearl-release.json"
        metadata_path.write_text(json.dumps(metadata, sort_keys=True, separators=(",", ":")) + "\n")
        self.sign(metadata_path, self.bundle / "pearl-release.json.sig")
        assets = [metadata_path, self.bundle / "pearl-release.json.sig", coordinator, gateway]
        checksums = self.bundle / "checksums.txt"
        checksums.write_text("".join(f"{updater_module.sha256_file(path)}  {path.name}\n" for path in assets))
        self.sign(checksums, self.bundle / "checksums.txt.sig")

    def verify(self):
        return self.updater.verify_release(self.bundle, "v1.8.27")

    def stage(self, release):
        return self.updater.stage_candidate_validation(release, self.root)

    def install_pair(self, coordinator: str, gateway: str, durable: str | None = None):
        install = self.updater.install_root
        install.mkdir(parents=True, exist_ok=True)
        (install / "coordinator").write_text("installed coordinator\n")
        (install / "gateway").write_text("installed gateway\n")
        self.updater.installed_versions = {"coordinator": coordinator, "gateway": gateway}
        if durable is not None:
            self.updater.state_root.mkdir(parents=True, exist_ok=True)
            state = self.updater.state_root / "current-release.json"
            state.write_text(
                json.dumps({"version": durable}) + "\n"
            )
            state.chmod(0o600)

    def install_coherent_pair(self, release):
        install = self.updater.install_root
        install.mkdir(parents=True, exist_ok=True)
        shutil.copy2(release.directory / release.coordinator.asset, install / "coordinator")
        shutil.copy2(release.directory / release.gateway.asset, install / "gateway")
        self.updater.installed_versions = {
            "coordinator": str(release.version),
            "gateway": str(release.version),
        }
        self.updater.state_root.mkdir(parents=True, exist_ok=True)
        state = self.updater.state_root / "current-release.json"
        state.write_text(
            json.dumps(
                {
                    "schema_version": updater_module.CURRENT_RELEASE_SCHEMA_VERSION,
                    "version": str(release.version),
                    "tag": release.tag,
                    "commit": release.commit,
                    "coordinator_sha256": release.coordinator.sha256,
                    "gateway_sha256": release.gateway.sha256,
                }
            )
            + "\n"
        )
        state.chmod(0o600)

    def test_valid_signed_pair(self):
        release = self.stage(self.verify())
        self.assertEqual(str(release.version), "1.8.27")
        self.assertEqual(release.provider_advertised_version, "1.8.27")
        self.assertEqual(self.updater.candidate_executions, [])
        self.updater.verify_candidate_versions(release)
        self.assertEqual(
            self.updater.candidate_executions,
            [updater_module.COORDINATOR_ASSET, updater_module.GATEWAY_ASSET],
        )

    def test_signed_advertised_version_must_match_release_pair(self):
        self.make_bundle(advertised_version="1.8.26")
        with self.assertRaisesRegex(updater_module.UpdateError, "advertised version must match"):
            self.verify()

    def test_signature_failure_rejected_before_artifact_execution(self):
        signature = self.bundle / "pearl-release.json.sig"
        signature.write_bytes(signature.read_bytes()[:-1] + b"x")
        with self.assertRaisesRegex(updater_module.UpdateError, "signature verification failed"):
            self.verify()

    def test_checksum_mismatch_rejected(self):
        with (self.bundle / updater_module.GATEWAY_ASSET).open("ab") as handle:
            handle.write(b"tampered")
        with self.assertRaisesRegex(updater_module.UpdateError, "checksum mismatch"):
            self.verify()

    def test_partial_download_rejected_and_removed(self):
        class PartialResponse(io.BytesIO):
            headers = {"Content-Length": "99"}
            status = 200

            def __enter__(self):
                return self

            def __exit__(self, *_):
                self.close()

        destination = self.root / "partial"
        with mock.patch.object(updater_module.urllib.request, "urlopen", side_effect=lambda *_a, **_k: PartialResponse(b"short")):
            with self.assertRaisesRegex(updater_module.UpdateError, "download failed"):
                self.updater.download("https://example.invalid/asset", destination)
        self.assertFalse(destination.exists())

    def test_oversized_download_rejected_before_body_read(self):
        class OversizedResponse(io.BytesIO):
            headers = {"Content-Length": str(updater_module.MAX_DOWNLOAD_BYTES + 1)}
            status = 200

            def __enter__(self):
                return self

            def __exit__(self, *_):
                self.close()

        destination = self.root / "oversized"
        with mock.patch.object(
            updater_module.urllib.request,
            "urlopen",
            side_effect=lambda *_a, **_k: OversizedResponse(b"must-not-be-read"),
        ):
            with self.assertRaisesRegex(updater_module.UpdateError, "download failed"):
                self.updater.download("https://example.invalid/asset", destination)
        self.assertFalse(destination.exists())

    def test_downgrade_rejected_from_durable_state(self):
        self.install_pair("1.9.0", "1.9.0", "1.9.0")
        release = self.verify()
        with self.assertRaisesRegex(updater_module.UpdateError, "downgrade rejected"):
            self.updater.assess_candidate(release)
        self.assertEqual(self.updater.candidate_executions, [])

    def test_revoked_candidate_rejected(self):
        self.install_pair("1.8.26", "1.8.26", "1.8.26")
        revoked = self.root / "revoked"
        revoked.write_text("1.8.27 # incident\n")
        revoked.chmod(0o600)
        with self.assertRaisesRegex(updater_module.UpdateError, "is revoked"):
            self.updater.assess_candidate(self.verify())
        self.assertEqual(self.updater.candidate_executions, [])

    def test_missing_revocation_policy_fails_closed(self):
        self.config.revoked_versions_file.unlink()
        with self.assertRaisesRegex(updater_module.UpdateError, "required revoked versions policy is missing"):
            self.updater.revoked_versions()

    def test_minimum_is_policy_floor_not_installed_version_seed(self):
        self.install_pair("1.8.25", "1.8.25", "1.8.25")
        self.make_bundle("1.8.26")
        self.updater.candidate_version = "v1.8.26"
        release = self.stage(self.updater.verify_release(self.bundle, "v1.8.26"))

        current, decision = self.updater.assess_candidate(release)

        self.assertEqual(str(current), "1.8.25")
        self.assertEqual(decision, "upgrade")

    def test_mismatched_installed_pair_is_repaired_not_skipped(self):
        self.install_pair("1.8.27", "1.8.26", "1.8.27")
        current, decision = self.updater.eligibility(self.verify())
        self.assertEqual(str(current), "1.8.27")
        self.assertEqual(decision, "repair_pair")

    def test_advertised_version_update_preserves_config_and_validates_candidate(self):
        install = self.updater.install_root
        install.mkdir(parents=True)
        base = install / "coordinator.yaml"
        original = (
            'auth:\n  operator_key: "env:OPERATOR_KEY"\n'
            'coordinator_advertised_version:\n'
            '  latest_binary_version: "1.8.26" # preserve this comment\n'
            '  update_base_url: "https://github.com/Augustas11/macprovider/releases/download"\n'
        )
        base.write_text(original)
        self.updater.coordinator_runtime = mock.Mock(
            return_value=updater_module.CoordinatorRuntime(
                base_config=base,
                overlay_config=None,
                environment={"OPERATOR_KEY": "secret-from-running-service"},
            )
        )
        release = self.stage(self.verify())
        self.updater.verify_candidate_versions(release)

        update = self.updater.prepare_config_update(release)

        self.assertEqual(update.target, base)
        self.assertEqual(update.previous_version, "1.8.26")
        self.assertEqual(update.next_version, "1.8.27")
        self.assertEqual(base.read_text(), original)
        self.assertEqual(
            update.staged.read_text(),
            original.replace('latest_binary_version: "1.8.26"', 'latest_binary_version: "1.8.27"'),
        )
        self.assertIn('operator_key: "env:OPERATOR_KEY"', update.staged.read_text())

        self.install_pair("1.8.26", "1.8.26")
        self.updater.atomic_install = mock.Mock()
        self.updater.install_release(release)
        self.assertEqual(base.read_text(), update.staged.read_text())
        self.updater.get_json = mock.Mock(
            return_value={
                "status": "ok",
                "version": "v1.8.27",
                "recommended_binary_version": "1.8.27",
            }
        )
        self.assertTrue(self.updater.local_coordinator_ready(release, False))
        self.updater.get_json.return_value["recommended_binary_version"] = "1.8.26"
        self.assertFalse(self.updater.local_coordinator_ready(release, False))

    def test_advertised_version_update_targets_effective_overlay(self):
        install = self.updater.install_root
        install.mkdir(parents=True)
        base = install / "coordinator.yaml"
        overlay = self.root / "coordinator.overlay.yaml"
        base.write_text('coordinator_advertised_version:\n  latest_binary_version: "1.8.25"\n')
        overlay.write_text(
            'pool:\n  canary_enabled: false\n'
            'coordinator_advertised_version:\n  latest_binary_version: "1.8.26"\n'
        )
        self.updater.coordinator_runtime = mock.Mock(
            return_value=updater_module.CoordinatorRuntime(base, overlay, {})
        )
        release = self.stage(self.verify())
        self.updater.verify_candidate_versions(release)

        update = self.updater.prepare_config_update(release)

        self.assertEqual(update.target, overlay)
        self.assertIn('latest_binary_version: "1.8.27"', update.staged.read_text())
        self.assertIn('canary_enabled: false', update.staged.read_text())

        (install / "gateway.yaml").write_text("gateway: config\n")
        self.install_pair("1.8.26", "1.8.26")
        absent_database = self.root / "candidate-created.sqlite"
        self.updater.databases = (absent_database,)
        transaction = self.updater.snapshot(release)
        manifest = json.loads((transaction / "configuration-manifest.json").read_text())
        self.assertIn(str(overlay), {row["source"] for row in manifest})
        database_manifest = json.loads((transaction / "database-manifest.json").read_text())
        self.assertEqual(
            database_manifest,
            [{"source": str(absent_database), "existed": False}],
        )

    def test_candidate_config_failure_never_exposes_candidate_output(self):
        install = self.updater.install_root
        install.mkdir(parents=True)
        base = install / "coordinator.yaml"
        base.write_text('coordinator_advertised_version:\n  latest_binary_version: "1.8.26"\n')
        self.updater.coordinator_runtime = mock.Mock(
            return_value=updater_module.CoordinatorRuntime(base, None, {"TOKEN": "sentinel-secret"})
        )
        self.updater.run_candidate_command = mock.Mock(
            return_value=subprocess.CompletedProcess(["candidate"], 1, stdout="sentinel-secret", stderr="sentinel-secret")
        )
        release = self.stage(self.verify())

        with self.assertRaises(updater_module.UpdateError) as raised:
            self.updater.prepare_config_update(release)

        self.assertNotIn("sentinel-secret", str(raised.exception))

    def test_lock_refuses_concurrent_trigger(self):
        with updater_module.FileLock(self.root / "lock", required_uid=os.geteuid()):
            with self.assertRaises(updater_module.LockBusy):
                with updater_module.FileLock(self.root / "lock", required_uid=os.geteuid()):
                    pass

    def test_lock_refuses_symlink_without_touching_target(self):
        target = self.root / "lock-target"
        target.write_text("operator-owned\n")
        target.chmod(0o644)
        link = self.root / "lock"
        link.symlink_to(target)

        with self.assertRaisesRegex(updater_module.UpdateError, "symlinked updater lock"):
            with updater_module.FileLock(link, required_uid=os.geteuid()):
                pass

        self.assertEqual(target.read_text(), "operator-owned\n")
        self.assertEqual(target.stat().st_mode & 0o777, 0o644)

    def test_lock_repairs_mode_and_refuses_multiple_links(self):
        lock = self.root / "lock"
        lock.write_text("stale\n")
        lock.chmod(0o666)
        with updater_module.FileLock(lock, required_uid=os.geteuid()):
            self.assertEqual(lock.stat().st_mode & 0o777, 0o600)

        alias = self.root / "lock-alias"
        os.link(lock, alias)
        with self.assertRaisesRegex(updater_module.UpdateError, "exactly one link"):
            with updater_module.FileLock(lock, required_uid=os.geteuid()):
                pass

    def test_provider_connected_guard_fails_before_mutation(self):
        self.updater.get_json = mock.Mock(return_value={"pool_size": 1})
        self.updater.systemctl = mock.Mock()
        with self.assertRaisesRegex(updater_module.UpdateError, "provider drain protection"):
            self.updater.stop_for_rollout()
        self.updater.systemctl.assert_not_called()

    def test_restart_failure_invokes_rollback(self):
        release = self.verify()
        self.updater.audit = mock.Mock()
        self.updater.enter_deadman_maintenance = mock.Mock(
            side_effect=lambda: setattr(self.updater, "deadman_restore_required", True)
        )
        self.updater.restore_deadman_monitoring = mock.Mock()
        self.updater.stop_for_rollout = mock.Mock()
        self.updater.snapshot = mock.Mock(return_value=self.root / "tx")
        self.updater.capture_rollout_state = mock.Mock()
        self.updater.install_release = mock.Mock()
        self.updater.verify_rollout = mock.Mock(side_effect=updater_module.UpdateError("restart failed"))
        self.updater.restore_transaction = mock.Mock()
        with self.assertRaisesRegex(updater_module.UpdateError, "restart failed"):
            self.updater.apply(release, updater_module.SemVer.parse("1.8.26"))
        self.updater.restore_transaction.assert_called_once_with()
        self.updater.restore_deadman_monitoring.assert_called_once_with()

    def test_restart_order_and_external_canary_final_gate(self):
        release = self.verify()
        self.updater.systemctl = mock.Mock()
        self.updater.run_canary_gate = mock.Mock()
        self.updater.service_active = mock.Mock(return_value=True)
        self.updater.local_coordinator_ready = mock.Mock(return_value=True)
        self.updater.local_gateway_ready = mock.Mock(return_value=True)
        self.updater.gateway_serving_ready = mock.Mock(return_value=True)
        self.updater.public_ready = mock.Mock(return_value=True)
        self.updater.prove_serving_recovery = mock.Mock()
        self.updater.restore_auxiliary_services = mock.Mock()
        self.updater.restore_auxiliary_timers = mock.Mock()
        self.updater.wait_for = lambda _description, _timeout, check: self.assertTrue(check())
        self.updater.verify_rollout(release)

        self.assertEqual(
            self.updater.systemctl.call_args_list,
            [
                mock.call("start", "macprovider-coordinator.service"),
                mock.call("start", "macprovider-gateway.service"),
            ],
        )
        self.updater.prove_serving_recovery.assert_called_once_with(
            self.updater.release_identity(release)
        )

    def test_rollback_stops_gateway_until_exact_coordinator_health_is_restored(self):
        self.updater.previous_services = {
            "macprovider-coordinator.service": True,
            "macprovider-gateway.service": True,
        }
        self.updater.service_active = mock.Mock(side_effect=[True, False])
        self.updater.systemctl = mock.Mock()
        self.updater.assert_unit_quiescent = mock.Mock()
        self.updater.wait_for = mock.Mock(
            side_effect=[None, updater_module.UpdateError("old coordinator version unavailable")]
        )

        with self.assertRaisesRegex(updater_module.UpdateError, "old coordinator version unavailable"):
            self.updater.restore_backend_runtime(
                updater_module.RuntimeIdentity("v1.8.26", "v1.8.26", "1.8.26")
            )

        self.assertEqual(
            self.updater.systemctl.call_args_list,
            [
                mock.call("stop", "macprovider-gateway.service"),
                mock.call("start", "macprovider-coordinator.service"),
            ],
        )
        self.assertNotIn(
            mock.call("start", "macprovider-gateway.service"),
            self.updater.systemctl.call_args_list,
        )

    def test_rollback_serving_proof_runs_canary_even_when_previously_idle(self):
        identity = updater_module.RuntimeIdentity("v1.8.26", "v1.8.26", "1.8.26")
        self.updater.canary_service_was_active = False
        self.updater.local_coordinator_identity_ready = mock.Mock(return_value=True)
        self.updater.gateway_serving_ready = mock.Mock(return_value=True)
        self.updater.public_identity_ready = mock.Mock(return_value=True)
        self.updater.run_canary_gate = mock.Mock()
        self.updater.wait_for = lambda _description, _timeout, check: self.assertTrue(check())

        self.updater.prove_serving_recovery(identity)

        self.updater.run_canary_gate.assert_called_once_with()

    def test_snapshot_failure_restores_previously_active_services(self):
        release = self.verify()
        order = []
        self.updater.audit = mock.Mock()
        self.updater.enter_deadman_maintenance = mock.Mock(
            side_effect=lambda: (
                order.append("maintenance"),
                setattr(self.updater, "deadman_previous_paused", False),
                setattr(self.updater, "deadman_restore_required", True),
            )
        )
        self.updater.stop_for_rollout = mock.Mock(side_effect=lambda: order.append("quiesce"))
        self.updater.snapshot = mock.Mock(
            side_effect=lambda _release: (order.append("snapshot"), (_ for _ in ()).throw(updater_module.UpdateError("snapshot failed")))[1]
        )
        self.updater.restore_previous_services = mock.Mock(side_effect=lambda: order.append("restore-runtime"))
        self.updater.restore_deadman_monitoring = mock.Mock(side_effect=lambda: order.append("restore-heartbeat"))
        self.updater.restore_transaction = mock.Mock()
        self.updater.install_release = mock.Mock()
        self.updater.capture_rollout_state = mock.Mock(
            side_effect=lambda: (
                order.append("capture"),
                self.updater.previous_services.update({
                    "macprovider-coordinator.service": True,
                    "macprovider-gateway.service": True,
                }),
                setattr(self.updater, "canary_timer_was_active", True),
                setattr(self.updater, "canary_service_was_active", False),
            )
        )
        with self.assertRaisesRegex(updater_module.UpdateError, "snapshot failed"):
            self.updater.apply(release, updater_module.SemVer.parse("1.8.26"))
        self.updater.restore_previous_services.assert_called_once_with()
        self.updater.restore_deadman_monitoring.assert_called_once_with()
        self.updater.restore_transaction.assert_not_called()
        self.updater.install_release.assert_not_called()
        self.assertEqual(
            order,
            ["capture", "maintenance", "quiesce", "snapshot", "restore-runtime", "restore-heartbeat"],
        )
        self.assertFalse(self.updater.rollback_armed)
        self.assertFalse(self.updater.live_mutation_started)

    def test_canary_timeout_cancels_the_systemd_job(self):
        self.updater.run_command = mock.Mock(
            side_effect=[
                updater_module.CommandTimeout("deadline"),
                subprocess.CompletedProcess(["systemctl", "stop"], 0, stdout="", stderr=""),
                subprocess.CompletedProcess(["systemctl", "is-active"], 3, stdout="inactive\n", stderr=""),
            ]
        )

        with self.assertRaisesRegex(updater_module.UpdateError, "job was cancelled"):
            self.updater.run_canary_gate()

        self.assertEqual(
            self.updater.run_command.call_args_list,
            [
                mock.call(
                    ["systemctl", "start", "canary-buyer.service"],
                    check=False,
                    timeout=720,
                ),
                mock.call(
                    ["systemctl", "stop", "canary-buyer.service"],
                    check=False,
                    timeout=420,
                ),
                mock.call(
                    ["systemctl", "is-active", "--quiet", "canary-buyer.service"],
                    check=False,
                    timeout=10,
                ),
            ],
        )

    def test_rollout_stops_timer_and_inflight_canary_before_drain(self):
        self.updater.get_json = mock.Mock(return_value={"pool_size": 0})
        self.updater.previous_services = {
            "macprovider-coordinator.service": True,
            "macprovider-gateway.service": True,
        }
        self.updater.canary_timer_was_active = True
        self.updater.canary_service_was_active = True
        self.updater.systemctl = mock.Mock()
        self.updater.assert_unit_quiescent = mock.Mock()
        self.updater.drain_gateway = mock.Mock()
        self.updater.gateway_reservations = mock.Mock(return_value=0)
        self.updater.wait_for = mock.Mock()

        self.updater.stop_for_rollout()

        self.assertTrue(self.updater.canary_timer_was_active)
        self.assertTrue(self.updater.canary_service_was_active)
        self.assertEqual(
            self.updater.systemctl.call_args_list,
            [
                mock.call("stop", "macprovider-archive-rotate.timer"),
                mock.call("stop", "stats-billing-mirror.timer"),
                mock.call("stop", "macprovider-archive-rotate.service"),
                mock.call("stop", "stats-billing-mirror.service"),
                mock.call("stop", "canary-buyer.timer"),
                mock.call("stop", "canary-buyer.service"),
                mock.call("stop", "macprovider-gateway.service"),
                mock.call("stop", "macprovider-coordinator.service"),
            ],
        )

    def test_canary_rollout_authority_binds_files_and_loaded_unit(self):
        files = {}
        for name in ("probe.mjs", "run-canary.sh", "canary-buyer.service", "canary-buyer.timer"):
            path = self.root / name
            path.write_text(name + "\n")
            files[path] = updater_module.sha256_file(path)
        dropin = self.root / "canary-buyer.service.d" / updater_module.TRANSACTION_GATE_DROPIN_NAME
        dropin.parent.mkdir()
        dropin.write_text(updater_module.TRANSACTION_GATE_DROPIN_TEXT)

        def show_unit(argv, **_kwargs):
            unit = argv[-1]
            timeout = "TimeoutStartUSec=11min\n" if unit.endswith(".service") else ""
            dropins = str(dropin) if unit.endswith(".service") else ""
            return subprocess.CompletedProcess(
                argv,
                0,
                stdout=(
                    f"FragmentPath={self.root / unit}\n"
                    f"DropInPaths={dropins}\n"
                    "NeedDaemonReload=no\n"
                    + timeout
                ),
                stderr="",
            )

        self.updater.run_command = mock.Mock(side_effect=show_unit)

        with (
            mock.patch.object(updater_module, "CANARY_AUTHORITY_FILES", files),
            mock.patch.object(updater_module, "SYSTEMD_ROOT", self.root),
        ):
            self.updater.verify_canary_authority()

    def test_deadman_pause_and_prior_state_restoration_are_verified(self):
        token = self.root / "betterstack-token"
        token.write_text("uptime-api-token\n")
        token.chmod(0o600)
        self.updater.config = updater_module.dataclasses.replace(
            self.updater.config,
            deadman_heartbeat_id="12345",
            deadman_api_token_file=token,
        )

        class Response(io.BytesIO):
            status = 200

            def __enter__(self):
                return self

            def __exit__(self, *_):
                self.close()

        responses = [
            Response(b'{"data":{"attributes":{"status":"up","paused_at":null}}}'),
            Response(b'{"data":{"attributes":{"paused_at":"2026-07-10T12:00:00Z"}}}'),
            Response(b'{"data":{"attributes":{"status":"paused","paused_at":"2026-07-10T12:00:00Z"}}}'),
            Response(b'{"data":{"attributes":{"paused_at":null}}}'),
            Response(b'{"data":{"attributes":{"status":"up","paused_at":null}}}'),
        ]
        with mock.patch.object(updater_module.urllib.request, "urlopen", side_effect=responses) as urlopen:
            self.updater.enter_deadman_maintenance()
            self.assertTrue(self.updater.deadman_restore_required)
            self.updater.restore_deadman_monitoring()

        requests = [call.args[0] for call in urlopen.call_args_list]
        self.assertEqual(
            [request.get_method() for request in requests],
            ["GET", "PATCH", "GET", "PATCH", "GET"],
        )
        self.assertEqual(
            [request.get_header("Authorization") for request in requests],
            ["Bearer uptime-api-token"] * 5,
        )
        self.assertEqual(json.loads(requests[1].data), {"paused": True})
        self.assertEqual(json.loads(requests[3].data), {"paused": False})
        self.assertFalse(self.updater.deadman_restore_required)

    def test_rollback_restores_binaries_and_configuration(self):
        install = self.root / "opt"
        install.mkdir()
        tx = self.root / "tx"
        tx.mkdir()
        (tx / "databases").mkdir()
        (tx / "configurations").mkdir()
        database = self.root / "live.sqlite"
        database.write_text("new-database")
        (tx / "databases" / "0.sqlite").write_text("old-database")
        state = self.root / "state"
        state.mkdir()
        (state / "current-release.json").write_text('{"version":"1.8.27"}\n')
        (tx / "previous-current-release.json").write_text('{"version":"1.8.26"}\n')
        (tx / "state-manifest.json").write_text('{"existed":true}\n')
        for name in ("coordinator", "gateway"):
            (install / name).write_text("new-" + name)
            (tx / name).write_text("old-" + name)
        configuration_manifest = []
        for index, name in enumerate(("coordinator.yaml", "gateway.yaml")):
            live_config = install / name
            live_config.write_text("new-" + name)
            config_snapshot = tx / "configurations" / f"{index}.config"
            config_snapshot.write_text("old-" + name)
            live_stat = live_config.stat()
            configuration_manifest.append(
                {
                    "source": str(live_config),
                    "snapshot": config_snapshot.name,
                    "uid": live_stat.st_uid,
                    "gid": live_stat.st_gid,
                    "mode": 0o600,
                }
            )
        (tx / "configuration-manifest.json").write_text(
            json.dumps(configuration_manifest) + "\n"
        )
        database_stat = database.stat()
        (tx / "database-manifest.json").write_text(
            json.dumps(
                [
                    {
                        "source": str(database),
                        "existed": True,
                        "snapshot": "0.sqlite",
                        "uid": database_stat.st_uid,
                        "gid": database_stat.st_gid,
                        "mode": 0o600,
                    }
                ]
            )
            + "\n"
        )
        (tx / "previous-versions.json").write_text('{"coordinator":"old-c","gateway":"old-g"}\n')
        (tx / "previous-runtime.json").write_text(
            '{"coordinator_version":"old-c","gateway_version":"old-g","advertised_version":"1.8.26"}\n'
        )
        self.updater.transaction = tx
        self.updater.previous_services = {
            "macprovider-coordinator.service": False,
            "macprovider-gateway.service": False,
        }
        self.updater.previous_auxiliary_units = {
            unit: False for unit in updater_module.AUXILIARY_UNITS
        }
        self.updater.atomic_install = lambda source, destination: shutil.copy2(source, destination)
        self.updater.systemctl = mock.Mock()
        self.updater.service_active = mock.Mock(return_value=False)
        self.updater.assert_unit_quiescent = mock.Mock()
        self.updater.validate_transaction = mock.Mock()
        self.updater._prove_rollback_serving = mock.Mock()
        for path in tx.rglob("*"):
            if path.is_file():
                path.chmod(0o600)
        self.updater.restore_transaction()
        self.updater._prove_rollback_serving.assert_called_once_with(tx)
        for name in ("coordinator", "gateway", "coordinator.yaml", "gateway.yaml"):
            self.assertEqual((install / name).read_text(), "old-" + name)
        self.assertEqual(database.read_text(), "old-database")
        self.assertEqual(database.stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads((state / "current-release.json").read_text())["version"], "1.8.26")

    def test_rollback_removes_database_and_sidecars_absent_before_candidate(self):
        transaction = self.root / "absent-database-transaction"
        transaction.mkdir(mode=0o700)
        database = self.root / "candidate-created.sqlite"
        for path in (
            database,
            database.with_name(database.name + "-wal"),
            database.with_name(database.name + "-shm"),
        ):
            path.write_text("candidate state\n")
        manifest = transaction / "database-manifest.json"
        manifest.write_text(json.dumps([{"source": str(database), "existed": False}]) + "\n")
        manifest.chmod(0o600)

        self.updater._restore_databases(transaction)

        self.assertFalse(database.exists())
        self.assertFalse(database.with_name(database.name + "-wal").exists())
        self.assertFalse(database.with_name(database.name + "-shm").exists())

    def test_same_version_requires_signed_hashes_and_durable_commit(self):
        release = self.verify()
        self.install_coherent_pair(release)
        current, decision = self.updater.eligibility(release)
        self.assertEqual((str(current), decision), ("1.8.27", "already_current"))

        with (self.updater.install_root / "gateway").open("ab") as handle:
            handle.write(b"tampered")
        _, decision = self.updater.eligibility(release)
        self.assertEqual(decision, "repair_pair")

        self.install_coherent_pair(release)
        state = self.updater.state_root / "current-release.json"
        durable = json.loads(state.read_text())
        durable["commit"] = "b" * 40
        state.write_text(json.dumps(durable) + "\n")
        state.chmod(0o600)
        _, decision = self.updater.eligibility(release)
        self.assertEqual(decision, "repair_pair")

    def test_deadman_rejects_legacy_or_inconsistent_schema(self):
        with self.assertRaisesRegex(updater_module.UpdateError, "status/paused_at"):
            self.updater._deadman_get_state({"data": {"attributes": {"paused": True}}})
        with self.assertRaisesRegex(updater_module.UpdateError, "non-null paused_at"):
            self.updater._deadman_get_state(
                {"data": {"attributes": {"status": "up", "paused_at": "stale"}}}
            )

    def test_timer_queued_job_is_not_quiescent(self):
        self.updater.run_command = mock.Mock(
            return_value=subprocess.CompletedProcess(
                ["systemctl", "show"],
                0,
                stdout="ActiveState=inactive\nSubState=dead\nJob=/org/freedesktop/systemd1/job/91\n",
                stderr="",
            )
        )
        with self.assertRaisesRegex(updater_module.UpdateError, "queued systemd job"):
            self.updater.assert_unit_quiescent("canary-buyer.timer")

    def test_rollback_aborts_before_mutation_when_quiescence_is_unprovable(self):
        self.updater.transaction = self.root / "transaction"
        self.updater.validate_transaction = mock.Mock()
        self.updater.systemctl = mock.Mock()
        self.updater.assert_unit_quiescent = mock.Mock(
            side_effect=updater_module.UpdateError("timer race")
        )
        self.updater.atomic_install = mock.Mock()

        with self.assertRaisesRegex(updater_module.UpdateError, "timer race"):
            self.updater.restore_transaction()

        self.assertEqual(
            self.updater.systemctl.call_args_list,
            [
                mock.call("stop", "macprovider-archive-rotate.timer"),
                mock.call("stop", "stats-billing-mirror.timer"),
                mock.call("stop", "macprovider-archive-rotate.service"),
                mock.call("stop", "stats-billing-mirror.service"),
                mock.call("stop", "canary-buyer.timer"),
                mock.call("stop", "canary-buyer.service"),
                mock.call("stop", "macprovider-gateway.service"),
                mock.call("stop", "macprovider-coordinator.service"),
            ],
        )
        self.updater.atomic_install.assert_not_called()

    def test_candidate_execution_is_unprivileged_and_environment_bounded(self):
        runner = updater_module.Updater(
            self.config,
            public_key=self.public,
            install_root=self.root / "opt-sandbox",
            state_root=self.root / "state-sandbox",
            audit_path=self.root / "audit-sandbox" / "audit.jsonl",
            lock_path=self.root / "sandbox.lock",
            gateway_db=self.root / "sandbox.db",
            databases=(),
            trusted_uid=os.geteuid(),
            candidate_uid=1234,
            candidate_gid=2345,
            isolate_candidate_network=False,
        )
        with mock.patch.object(
            updater_module.subprocess,
            "run",
            return_value=subprocess.CompletedProcess(["candidate"], 0, stdout="v1.8.27\n", stderr=""),
        ) as run:
            runner.run_candidate_command(
                ["/staged/coordinator", "--version"],
                timeout=10,
                cwd=self.bundle,
                environment={"REQUIRED_TOKEN": "bounded"},
            )
        kwargs = run.call_args.kwargs
        self.assertEqual((kwargs["user"], kwargs["group"]), (1234, 2345))
        self.assertEqual(kwargs["extra_groups"], ())
        self.assertTrue(kwargs["close_fds"])
        self.assertEqual(kwargs["cwd"], self.bundle)
        self.assertEqual(kwargs["env"]["REQUIRED_TOKEN"], "bounded")
        self.assertNotIn("SECRET_FROM_LIVE_ROOT", kwargs["env"])

    def test_production_candidate_execution_adds_network_and_privilege_barriers(self):
        runner = updater_module.Updater(
            self.config,
            public_key=self.public,
            install_root=self.root / "opt-isolated",
            state_root=self.root / "state-isolated",
            audit_path=self.root / "audit-isolated" / "audit.jsonl",
            lock_path=self.root / "isolated.lock",
            gateway_db=self.root / "isolated.db",
            databases=(),
            trusted_uid=os.geteuid(),
            candidate_uid=1234,
            candidate_gid=2345,
            isolate_candidate_network=True,
        )
        with mock.patch.object(updater_module.shutil, "which", side_effect=lambda name: f"/usr/bin/{name}"), mock.patch.object(
            updater_module.subprocess,
            "run",
            return_value=subprocess.CompletedProcess(["candidate"], 0, stdout="v1.8.27\n", stderr=""),
        ) as run:
            runner.run_candidate_command(
                [str(self.bundle / updater_module.GATEWAY_ASSET), "--version"],
                timeout=10,
                cwd=self.bundle,
            )
        command = run.call_args.args[0]
        self.assertEqual(
            command[:8],
            ["/usr/bin/unshare", "--mount", "--pid", "--net", "--ipc", "--uts", "--fork", "--kill-child"],
        )
        self.assertIn("--no-new-privs", command)
        self.assertIn("/usr/bin/chroot", command)
        self.assertIn("--userspec=1234:2345", command)
        self.assertIn("--groups=2345", command)
        self.assertEqual(command[-2:], ["/" + updater_module.GATEWAY_ASSET, "--version"])
        outside = self.root / "outside-candidate"
        outside.write_text("host data\n")
        with mock.patch.object(updater_module.shutil, "which", side_effect=lambda name: f"/usr/bin/{name}"):
            with self.assertRaisesRegex(updater_module.UpdateError, "outside its sandbox"):
                runner.run_candidate_command([str(outside), "--version"], timeout=10, cwd=self.bundle)

    def test_runtime_database_paths_come_from_effective_configs(self):
        install = self.updater.install_root
        install.mkdir(parents=True)
        coordinator = install / "coordinator.yaml"
        overlay = self.root / "coordinator.overlay.yaml"
        gateway = install / "gateway.yaml"
        stats_fragment = self.root / "stats-billing-mirror.service"
        stats_dropin = self.root / updater_module.TRANSACTION_GATE_DROPIN_NAME
        coordinator.write_text("storage:\n  db_path: /srv/macprovider/coordinator.sqlite\n")
        overlay.write_text("malibu_emission:\n  sqlite_payout_db_path: /srv/macprovider/payout.sqlite\n")
        gateway.write_text("storage:\n  db_path: /srv/macprovider/gateway.sqlite\n")
        stats_fragment.write_text("[Service]\nExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /srv/macprovider/stats.sqlite\n")
        stats_dropin.write_text(updater_module.TRANSACTION_GATE_DROPIN_TEXT)
        self.updater.gateway_db = None
        self.updater.databases = ()
        self.updater.coordinator_runtime_state = updater_module.CoordinatorRuntime(coordinator, overlay, {})
        self.updater.gateway_config_path = mock.Mock(return_value=gateway)
        self.updater.stats_mirror_runtime = mock.Mock(
            return_value=((stats_fragment, stats_dropin), Path("/srv/macprovider/stats.sqlite"))
        )

        self.updater.capture_database_paths()

        self.assertEqual(self.updater.gateway_db, Path("/srv/macprovider/gateway.sqlite"))
        self.assertEqual(
            self.updater.databases,
            (
                Path("/srv/macprovider/gateway.sqlite"),
                Path("/srv/macprovider/coordinator.sqlite"),
                Path("/srv/macprovider/stats.sqlite"),
                Path("/srv/macprovider/payout.sqlite"),
            ),
        )
        self.assertEqual(
            set(self.updater.runtime_config_hashes),
            {coordinator, overlay, gateway, stats_fragment, stats_dropin},
        )
        self.updater.run_command = mock.Mock(
            return_value=subprocess.CompletedProcess(["sqlite3"], 0, stdout="0\n", stderr="")
        )
        self.assertEqual(self.updater.gateway_reservations(), 0)
        self.assertEqual(self.updater.run_command.call_args.args[0][2], "/srv/macprovider/gateway.sqlite")

    def test_runtime_database_parser_rejects_relative_or_duplicate_paths(self):
        with self.assertRaisesRegex(updater_module.UpdateError, "absolute path"):
            self.updater._database_path("gateway.db", "gateway storage.db_path")
        self.updater.gateway_db = self.root / "same.sqlite"
        self.updater.databases = (self.root / "same.sqlite",)
        with self.assertRaisesRegex(updater_module.UpdateError, "distinct absolute"):
            self.updater.capture_database_paths()

    def test_stats_mirror_database_path_comes_from_loaded_unit(self):
        systemd_root = self.root / "systemd"
        systemd_root.mkdir()
        fragment = systemd_root / "stats-billing-mirror.service"
        dropin = systemd_root / "stats-billing-mirror.service.d" / updater_module.TRANSACTION_GATE_DROPIN_NAME
        dropin.parent.mkdir()
        dropin.write_text(updater_module.TRANSACTION_GATE_DROPIN_TEXT)
        fragment.write_text(
            "[Service]\n"
            "ExecStart=/opt/macprovider-stats/stats-billing-mirror "
            "--sqlite /srv/macprovider/stats.sqlite --ensure-schema=false\n"
        )
        systemctl_state = (
            f"FragmentPath={fragment}\n"
            f"DropInPaths={dropin}\n"
            "NeedDaemonReload=no\n"
        )
        self.updater.run_command = mock.Mock(
            return_value=subprocess.CompletedProcess(["systemctl"], 0, stdout=systemctl_state, stderr="")
        )
        with mock.patch.object(updater_module, "SYSTEMD_ROOT", systemd_root):
            loaded, database = self.updater.stats_mirror_runtime()
        self.assertEqual((loaded, database), ((fragment, dropin), Path("/srv/macprovider/stats.sqlite")))

    def test_stats_mirror_runtime_rejects_stale_or_unverified_unit_state(self):
        systemd_root = self.root / "systemd"
        systemd_root.mkdir()
        fragment = systemd_root / "stats-billing-mirror.service"
        dropin = systemd_root / "stats-billing-mirror.service.d" / updater_module.TRANSACTION_GATE_DROPIN_NAME
        dropin.parent.mkdir()
        fragment.write_text(
            "[Service]\n"
            "ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /srv/macprovider/stats.sqlite\n"
        )
        dropin.write_text(updater_module.TRANSACTION_GATE_DROPIN_TEXT)

        for dropin_paths, need_reload, expected_error in (
            (str(dropin), "yes", "must reload"),
            (str(systemd_root / "unexpected.conf"), "no", "unverified systemd drop-ins"),
        ):
            with self.subTest(dropin_paths=dropin_paths, need_reload=need_reload):
                systemctl_state = (
                    f"FragmentPath={fragment}\n"
                    f"DropInPaths={dropin_paths}\n"
                    f"NeedDaemonReload={need_reload}\n"
                )
                self.updater.run_command = mock.Mock(
                    return_value=subprocess.CompletedProcess(
                        ["systemctl"], 0, stdout=systemctl_state, stderr=""
                    )
                )
                with mock.patch.object(updater_module, "SYSTEMD_ROOT", systemd_root):
                    with self.assertRaisesRegex(updater_module.UpdateError, expected_error):
                        self.updater.stats_mirror_runtime()

    def test_database_config_drift_fails_before_snapshot(self):
        config = self.root / "gateway-runtime.yaml"
        config.write_text("storage:\n  db_path: /srv/macprovider/gateway.sqlite\n")
        self.updater.runtime_config_hashes = {config: updater_module.sha256_file(config)}
        self.updater.config_update = updater_module.ConfigUpdate(
            config, config, updater_module.sha256_file(config), "1.8.26", "1.8.27"
        )
        config.write_text("storage:\n  db_path: /srv/macprovider/changed.sqlite\n")

        with self.assertRaisesRegex(updater_module.UpdateError, "changed after capture"):
            self.updater.snapshot(self.verify())

        self.assertFalse((self.updater.state_root / "transactions").exists())

    def test_candidate_staging_is_owner_controlled_and_macprovider_traversable(self):
        release = self.stage(self.verify())
        directory_stat = release.directory.stat()
        self.assertEqual(directory_stat.st_uid, os.geteuid())
        self.assertEqual(directory_stat.st_gid, os.getegid())
        self.assertEqual(stat.S_IMODE(directory_stat.st_mode), 0o750)
        for component in (release.coordinator, release.gateway):
            component_stat = (release.directory / component.asset).stat()
            self.assertEqual(component_stat.st_uid, os.geteuid())
            self.assertEqual(component_stat.st_gid, os.getegid())
            self.assertEqual(stat.S_IMODE(component_stat.st_mode), 0o550)
        staged_yaml = self.updater.stage_candidate_config(
            release.directory,
            "coordinator-validation.yaml",
            "coordinator_advertised_version:\n  latest_binary_version: v1.8.27\n",
        )
        yaml_stat = staged_yaml.stat()
        self.assertEqual((yaml_stat.st_uid, yaml_stat.st_gid), (os.geteuid(), os.getegid()))
        self.assertEqual(stat.S_IMODE(yaml_stat.st_mode), 0o640)

    def test_candidate_staging_survives_real_dropped_uid_filesystem_access(self):
        if os.geteuid() != 0:
            sudo = shutil.which("sudo")
            probe = subprocess.run(
                [sudo, "-n", "true"] if sudo else ["false"],
                check=False,
                capture_output=True,
            )
            if not sudo or probe.returncode != 0:
                self.skipTest("real uid-drop regression requires root or passwordless sudo")
            child = subprocess.run(
                [
                    sudo,
                    "-n",
                    sys.executable,
                    str(Path(__file__).resolve()),
                    f"{self.__class__.__name__}.{self._testMethodName}",
                ],
                check=False,
                text=True,
                capture_output=True,
            )
            self.assertEqual(child.returncode, 0, child.stdout + child.stderr)
            return
        account = pwd.getpwnam("nobody")
        self.assertNotEqual(account.pw_uid, 0)
        work = self.root / "dropped-uid-work"
        work.mkdir(mode=0o700)
        script = b"#!/bin/sh\ncat \"$1\"\n"
        components = []
        for asset in (updater_module.COORDINATOR_ASSET, updater_module.GATEWAY_ASSET):
            path = work / asset
            path.write_bytes(script)
            components.append(
                updater_module.Component(asset, updater_module.sha256_file(path), "v1.8.27")
            )
        release = updater_module.Release(
            "v1.8.27",
            updater_module.SemVer.parse("1.8.27"),
            "a" * 40,
            "1.8.27",
            components[0],
            components[1],
            work,
        )
        runner = updater_module.Updater(
            self.config,
            public_key=self.public,
            install_root=self.root / "drop-opt",
            state_root=self.root / "drop-state",
            audit_path=self.root / "drop-audit" / "audit.jsonl",
            lock_path=self.root / "drop.lock",
            gateway_db=self.root / "drop.db",
            databases=(),
            trusted_uid=0,
            candidate_uid=account.pw_uid,
            candidate_gid=account.pw_gid,
            isolate_candidate_network=False,
        )
        staged = runner.stage_candidate_validation(release, self.root)
        yaml_path = runner.stage_candidate_config(staged.directory, "staged.yaml", "config: readable\n")
        result = runner.run_candidate_command(
            [str(staged.directory / staged.coordinator.asset), str(yaml_path)],
            timeout=10,
            cwd=staged.directory,
        )
        self.assertEqual((result.returncode, result.stdout), (0, "config: readable\n"))

    def test_trusted_inputs_reject_symlinks_hardlinks_and_writable_files(self):
        config = self.root / "updater.conf"
        config.write_text("PEARL_UPDATER_ENABLED=0\n")
        config.chmod(0o600)
        alias = self.root / "updater.conf.alias"
        os.link(config, alias)
        with self.assertRaisesRegex(updater_module.UpdateError, "exactly one link"):
            updater_module.load_config(config, trusted_uid=os.geteuid())
        alias.unlink()

        config.chmod(0o620)
        with self.assertRaisesRegex(updater_module.UpdateError, "writable by group or other"):
            updater_module.load_config(config, trusted_uid=os.geteuid())
        config.chmod(0o600)
        symlink = self.root / "updater-link.conf"
        symlink.symlink_to(config)
        with self.assertRaisesRegex(updater_module.UpdateError, "regular file"):
            updater_module.load_config(symlink, trusted_uid=os.geteuid())

    def test_policy_and_state_surfaces_require_trusted_ownership_and_modes(self):
        config_path = self.root / "pearl-updater.conf"
        config_path.write_text("PEARL_UPDATER_ENABLED=0\n")
        config_path.chmod(0o600)
        token = self.root / "betterstack-token"
        token.write_text("api-token\n")
        token.chmod(0o600)
        self.updater.config = updater_module.dataclasses.replace(
            self.updater.config,
            deadman_api_token_file=token,
        )
        self.updater.state_root.mkdir(mode=0o755)
        with self.assertRaisesRegex(updater_module.UpdateError, "mode must be 0700"):
            self.updater.validate_policy_inputs(config_path)

        self.updater.state_root.chmod(0o700)
        self.public.chmod(0o666)
        with self.assertRaisesRegex(updater_module.UpdateError, "writable by group or other"):
            self.updater.validate_policy_inputs(config_path)

    def test_rollout_policy_fails_closed_without_independent_gmail_credential(self):
        config_path = self.root / "pearl-updater.conf"
        config_path.write_text("PEARL_UPDATER_ENABLED=0\n")
        config_path.chmod(0o600)
        token = self.root / "betterstack-token"
        token.write_text("api-token\n")
        token.chmod(0o600)
        alert_directory = self.root / "alert-config"
        alert_directory.mkdir(mode=0o750)
        alert_env = alert_directory / "monitor.env"
        alert_env.write_text(
            "ALERT_EMAIL=operator@example.invalid\n"
            "GMAIL_USER=sender@example.invalid\n"
            "GMAIL_APP_PASSWORD=\n"
        )
        alert_env.chmod(0o640)
        self.updater.config = updater_module.dataclasses.replace(
            self.updater.config,
            deadman_api_token_file=token,
        )
        with mock.patch.object(updater_module, "INDEPENDENT_ALERT_ENV_PATH", alert_env):
            with self.assertRaisesRegex(updater_module.UpdateError, "GMAIL_APP_PASSWORD is empty"):
                self.updater.validate_policy_inputs(config_path)
            alert_env.write_text(
                "ALERT_EMAIL=operator@example.invalid\n"
                "GMAIL_USER=sender@example.invalid\n"
                "GMAIL_APP_PASSWORD=app-password\n"
            )
            alert_env.chmod(0o640)
            self.updater.validate_policy_inputs(config_path)

            alert_env.chmod(0o600)
            with self.assertRaisesRegex(updater_module.UpdateError, "mode 0640"):
                self.updater.validate_independent_alert_configuration()

    def test_independent_alert_policy_uses_alert_group_not_candidate_sandbox_group(self):
        alert_directory = self.root / "alert-group-policy"
        alert_directory.mkdir(mode=0o750)
        alert_env = alert_directory / "monitor.env"
        alert_env.write_text(
            "ALERT_EMAIL=operator@example.invalid\n"
            "GMAIL_USER=sender@example.invalid\n"
            "GMAIL_APP_PASSWORD=app-password\n"
        )
        alert_env.chmod(0o640)

        self.updater.candidate_gid = os.getegid() + 10000
        self.updater.independent_alert_gid = os.getegid()
        with mock.patch.object(updater_module, "INDEPENDENT_ALERT_ENV_PATH", alert_env):
            self.updater.validate_independent_alert_configuration()

            self.updater.independent_alert_gid = self.updater.candidate_gid
            with self.assertRaisesRegex(updater_module.UpdateError, "config directory"):
                self.updater.validate_independent_alert_configuration()

    def test_independent_alert_group_resolution_uses_named_group(self):
        account = mock.Mock(pw_uid=1234, pw_gid=2345)
        group = mock.Mock(gr_gid=3456)
        with (
            mock.patch.object(updater_module.pwd, "getpwnam", return_value=account) as account_lookup,
            mock.patch.object(updater_module.grp, "getgrnam", return_value=group) as group_lookup,
        ):
            self.assertEqual(
                updater_module.resolve_service_group_gid("macprovider", "macprovider"),
                group.gr_gid,
            )
        account_lookup.assert_called_once_with("macprovider")
        group_lookup.assert_called_once_with("macprovider")
        self.assertNotEqual(account.pw_gid, group.gr_gid)

    def test_independent_alert_group_resolution_rejects_missing_or_root_identity(self):
        with mock.patch.object(updater_module.pwd, "getpwnam", side_effect=KeyError):
            with self.assertRaisesRegex(updater_module.UpdateError, "service account is missing"):
                updater_module.resolve_service_group_gid("macprovider", "macprovider")

        with mock.patch.object(
            updater_module.pwd,
            "getpwnam",
            return_value=mock.Mock(pw_uid=0, pw_gid=1234),
        ):
            with self.assertRaisesRegex(updater_module.UpdateError, "must not use the root uid"):
                updater_module.resolve_service_group_gid("macprovider", "macprovider")

        with (
            mock.patch.object(
                updater_module.pwd,
                "getpwnam",
                return_value=mock.Mock(pw_uid=1234, pw_gid=2345),
            ),
            mock.patch.object(updater_module.grp, "getgrnam", side_effect=KeyError),
        ):
            with self.assertRaisesRegex(updater_module.UpdateError, "service group is missing"):
                updater_module.resolve_service_group_gid("macprovider", "macprovider")

        with (
            mock.patch.object(
                updater_module.pwd,
                "getpwnam",
                return_value=mock.Mock(pw_uid=1234, pw_gid=2345),
            ),
            mock.patch.object(updater_module.grp, "getgrnam", return_value=mock.Mock(gr_gid=0)),
        ):
            with self.assertRaisesRegex(updater_module.UpdateError, "must not use the root gid"):
                updater_module.resolve_service_group_gid("macprovider", "macprovider")

    def test_independent_alert_sender_checks_monitor_gmail_configuration(self):
        sender = SCRIPT.with_name("macprovider-pearl-updater-alert")
        alert_directory = self.root / "alert-config"
        alert_directory.mkdir(mode=0o750)
        alert_env = alert_directory / "monitor-alert.env"
        alert_env.write_text(
            "ALERT_EMAIL=operator@example.invalid\n"
            "GMAIL_USER=sender@example.invalid\n"
            "GMAIL_APP_PASSWORD=\n"
        )
        alert_env.chmod(0o640)
        environment = {**os.environ, "MACPROVIDER_UPDATER_ALERT_TESTING": "1"}
        failed = subprocess.run(
            [str(sender), "--check-config", "--env-file", str(alert_env), "updater.service"],
            text=True,
            capture_output=True,
            timeout=10,
            env=environment,
        )
        self.assertEqual(failed.returncode, 1)
        self.assertIn("GMAIL_APP_PASSWORD is empty", failed.stderr)

        alert_env.write_text(
            "ALERT_EMAIL=operator@example.invalid\n"
            "GMAIL_USER=sender@example.invalid\n"
            "GMAIL_APP_PASSWORD=app-password\n"
        )
        alert_env.chmod(0o640)
        checked = subprocess.run(
            [str(sender), "--check-config", "--env-file", str(alert_env), "updater.service"],
            text=True,
            capture_output=True,
            timeout=10,
            env=environment,
        )
        self.assertEqual(checked.returncode, 0, checked.stderr)
        self.assertIn("configuration is present", checked.stdout)

    def test_independent_alert_sender_requires_safe_path_and_exact_mode(self):
        alert_directory = self.root / "alert-path-policy"
        alert_directory.mkdir(mode=0o750)
        alert_env = alert_directory / "monitor.env"
        alert_env.write_text(
            "ALERT_EMAIL=operator@example.invalid\n"
            "GMAIL_USER=sender@example.invalid\n"
            "GMAIL_APP_PASSWORD=app-password\n"
        )
        environment = {"MACPROVIDER_UPDATER_ALERT_TESTING": "1"}
        with mock.patch.dict(os.environ, environment, clear=False):
            alert_env.chmod(0o600)
            with self.assertRaisesRegex(alert_module.AlertError, "mode must be 0640"):
                alert_module.load_env(alert_env)

            alert_env.chmod(0o640)
            alert_directory.chmod(0o770)
            with self.assertRaisesRegex(alert_module.AlertError, "mode must be 0750"):
                alert_module.load_env(alert_env)

            alert_directory.chmod(0o750)
            target = alert_directory / "target.env"
            alert_env.rename(target)
            alert_env.symlink_to(target)
            with self.assertRaisesRegex(alert_module.AlertError, "not a regular file"):
                alert_module.load_env(alert_env)

    def test_independent_alert_sender_uses_verified_starttls_context(self):
        alert_directory = self.root / "alert-tls"
        alert_directory.mkdir(mode=0o750)
        alert_env = alert_directory / "monitor.env"
        alert_env.write_text(
            "ALERT_EMAIL=operator@example.invalid\n"
            "GMAIL_USER=sender@example.invalid\n"
            "GMAIL_APP_PASSWORD=app-password\n"
        )
        alert_env.chmod(0o640)
        smtp = mock.MagicMock()
        smtp.__enter__.return_value = smtp
        context = mock.sentinel.verified_ssl_context
        with (
            mock.patch.dict(os.environ, {"MACPROVIDER_UPDATER_ALERT_TESTING": "1"}, clear=False),
            mock.patch.object(alert_module.ssl, "create_default_context", return_value=context) as create_context,
            mock.patch.object(alert_module.smtplib, "SMTP", return_value=smtp),
            mock.patch("sys.stdout", new=io.StringIO()),
        ):
            self.assertEqual(
                alert_module.main(["--env-file", str(alert_env), "updater.service"]),
                0,
            )

        create_context.assert_called_once_with()
        smtp.starttls.assert_called_once_with(context=context)

    def test_transaction_gate_blocks_without_permit_and_consumes_permit_once(self):
        release = self.verify()
        self.updater._start_journal(release, updater_module.SemVer.parse("1.8.26"))
        gate = SCRIPT.with_name("macprovider-pearl-update-gate")
        environment = {
            **os.environ,
            "MACPROVIDER_UPDATER_GATE_TESTING": "1",
            "PEARL_UPDATER_GATE_JOURNAL": str(self.updater.journal_path),
            "PEARL_UPDATER_GATE_ROOT": str(self.updater.gate_state_root),
            "PEARL_UPDATER_GATE_BOOT_ID": str(self.boot_id),
            "PEARL_UPDATER_GATE_LOCK": str(self.updater.lock_path),
        }
        self.updater.gate_state_root.mkdir(mode=0o700)
        (self.updater.gate_state_root / "permits").mkdir(mode=0o700)

        with updater_module.FileLock(self.updater.lock_path, required_uid=os.geteuid()):
            blocked = subprocess.run(
                [str(gate), "macprovider-coordinator.service"],
                text=True,
                capture_output=True,
                timeout=10,
                env=environment,
            )
            self.assertEqual(blocked.returncode, 1)
            self.assertIn("no single-use permit", blocked.stderr)

            self.updater.issue_start_permit("macprovider-coordinator.service")
            allowed = subprocess.run(
                [str(gate), "macprovider-coordinator.service"],
                text=True,
                capture_output=True,
                timeout=10,
                env=environment,
            )
            replayed = subprocess.run(
                [str(gate), "macprovider-coordinator.service"],
                text=True,
                capture_output=True,
                timeout=10,
                env=environment,
            )
        self.assertEqual(allowed.returncode, 0, allowed.stderr)
        self.assertEqual(replayed.returncode, 1)
        self.assertIn("no single-use permit", replayed.stderr)

        self.updater.issue_start_permit("macprovider-coordinator.service")
        orphaned = subprocess.run(
            [str(gate), "macprovider-coordinator.service"],
            text=True,
            capture_output=True,
            timeout=10,
            env=environment,
        )
        self.assertEqual(orphaned.returncode, 1)
        self.assertIn("no running updater/reconciler", orphaned.stderr)

    def test_transaction_gate_rejects_permit_from_another_boot(self):
        release = self.verify()
        self.updater._start_journal(release, updater_module.SemVer.parse("1.8.26"))
        self.updater.issue_start_permit("macprovider-gateway.service")
        self.boot_id.write_text("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n")
        gate = SCRIPT.with_name("macprovider-pearl-update-gate")
        with updater_module.FileLock(self.updater.lock_path, required_uid=os.geteuid()):
            result = subprocess.run(
                [str(gate), "macprovider-gateway.service"],
                text=True,
                capture_output=True,
                timeout=10,
                env={
                    **os.environ,
                    "MACPROVIDER_UPDATER_GATE_TESTING": "1",
                    "PEARL_UPDATER_GATE_JOURNAL": str(self.updater.journal_path),
                    "PEARL_UPDATER_GATE_ROOT": str(self.updater.gate_state_root),
                    "PEARL_UPDATER_GATE_BOOT_ID": str(self.boot_id),
                    "PEARL_UPDATER_GATE_LOCK": str(self.updater.lock_path),
                },
            )
        self.assertEqual(result.returncode, 1)
        self.assertIn("another boot", result.stderr)

    def test_journal_and_audit_refuse_symlink_targets(self):
        self.updater.state_root.mkdir(mode=0o700)
        target = self.root / "operator-owned"
        target.write_text("do not touch\n")
        target.chmod(0o600)
        self.updater.journal_path.symlink_to(target)
        with self.assertRaisesRegex(updater_module.UpdateError, "regular file"):
            self.updater._load_journal()
        self.updater.journal_path.unlink()

        self.updater.audit_path.symlink_to(target)
        with self.assertRaisesRegex(updater_module.UpdateError, "regular file"):
            updater_module.Updater.audit(self.updater, "test", "failed")
        self.assertEqual(target.read_text(), "do not touch\n")

    def test_phase_journal_is_private_and_reconciles_live_mutation_crashes(self):
        phases = ("file_replace_pending", "database_sidecars_remove_pending", "success_state_persist_pending")
        for phase in phases:
            with self.subTest(phase=phase):
                self.updater.state_root.mkdir(mode=0o700, exist_ok=True)
                payload = {
                    "schema_version": updater_module.JOURNAL_SCHEMA_VERSION,
                    "transaction_id": "1" * 64,
                    "boot_id": self.boot_id.read_text().strip(),
                    "phase": phase,
                    "previous_services": {
                        "macprovider-coordinator.service": True,
                        "macprovider-gateway.service": True,
                    },
                    "canary_timer_was_active": True,
                    "canary_service_was_active": False,
                    "previous_auxiliary_units": {
                        unit: False for unit in updater_module.AUXILIARY_UNITS
                    },
                    "previous_versions": {"coordinator": "v1.8.26", "gateway": "v1.8.26"},
                    "previous_advertised_version": "1.8.26",
                    "database_paths": [],
                    "deadman_previous_paused": False,
                    "deadman_restore_required": False,
                    "transaction": str(self.root / "tx-reconcile"),
                    "rollback_armed": True,
                    "live_mutation_started": True,
                    "success_persisted": False,
                }
                self.updater.journal_path.write_text(json.dumps(payload) + "\n")
                self.updater.journal_path.chmod(0o600)
                self.updater.restore_transaction = mock.Mock()
                self.updater.audit = mock.Mock()

                self.assertTrue(self.updater.reconcile())

                self.updater.restore_transaction.assert_called_once_with()
                self.assertFalse(self.updater.journal_path.exists())
                self.assertEqual(self.updater.state_root.stat().st_mode & 0o777, 0o700)
                self.updater.audit.assert_any_call(
                    "rollout_reconciliation", "success", recovered_phase=phase
                )

    def test_reconcile_committed_success_moves_forward_to_candidate(self):
        release = self.stage(self.verify())
        self.install_coherent_pair(release)
        self.updater.state_root.chmod(0o700)
        self.updater.config_update = updater_module.ConfigUpdate(
            self.root / "config", self.root / "staged", "a" * 64, "1.8.26", "1.8.27"
        )
        self.updater._start_journal(release, updater_module.SemVer.parse("1.8.26"))
        self.updater.journal.update(
            {
                "phase": "success_state_persisted",
                "previous_services": {
                    "macprovider-coordinator.service": True,
                    "macprovider-gateway.service": True,
                },
                "previous_auxiliary_units": {unit: False for unit in updater_module.AUXILIARY_UNITS},
                "previous_versions": {"coordinator": "v1.8.26", "gateway": "v1.8.26"},
                "database_paths": [str(self.root / "gateway.sqlite")],
                "canary_timer_was_active": True,
                "canary_service_was_active": False,
                "rollback_armed": True,
                "live_mutation_started": True,
                "success_persisted": True,
                "deadman_previous_paused": False,
                "deadman_restore_required": True,
            }
        )
        self.updater._journal_transition("success_state_persisted")
        self.updater.verify_rollout = mock.Mock()
        self.updater.restore_transaction = mock.Mock()
        self.updater.restore_previous_services = mock.Mock()
        self.updater.restore_deadman_monitoring = mock.Mock(
            side_effect=lambda: setattr(self.updater, "deadman_restore_required", False)
        )

        self.assertTrue(self.updater.reconcile())

        self.updater.verify_rollout.assert_called_once()
        self.updater.restore_transaction.assert_not_called()
        self.updater.restore_previous_services.assert_not_called()
        self.updater.restore_deadman_monitoring.assert_called_once_with()
        self.assertFalse(self.updater.journal_path.exists())

    def test_rollback_marks_intent_before_quiescence_or_file_mutation(self):
        self.updater.state_root.mkdir(mode=0o700)
        self.updater.transaction = self.root / "tx-intent"
        self.updater.journal = {
            "schema_version": updater_module.JOURNAL_SCHEMA_VERSION,
            "phase": "live_mutation_armed",
            "rollback_armed": True,
            "rollback_in_progress": False,
            "rollback_completed_steps": [],
            "success_persisted": True,
        }
        self.updater.validate_transaction = mock.Mock()
        observed = []

        def assert_marked():
            payload = json.loads(self.updater.journal_path.read_text())
            observed.append((payload["rollback_in_progress"], payload["success_persisted"]))
            raise updater_module.UpdateError("crash before quiescence")

        self.updater.quiesce_for_restore = assert_marked
        with self.assertRaisesRegex(updater_module.UpdateError, "crash before quiescence"):
            self.updater.restore_transaction()
        self.assertEqual(observed, [(True, False)])

    def test_reconcile_resumes_idempotently_after_every_completed_restore_phase(self):
        actions = {
            "quiescence": "quiesce_for_restore",
            "binaries": "_restore_binaries",
            "configurations": "_restore_configurations",
            "databases": "_restore_databases",
            "success_state": "_restore_success_state",
            "backend_services": "_restore_backend_services",
            "auxiliary_services": "restore_auxiliary_services",
            "serving_validation": "_prove_rollback_serving",
            "auxiliary_timers": "restore_auxiliary_timers",
            "canary_timer": "_restore_canary_timer",
        }
        for completed_count in range(len(updater_module.ROLLBACK_STEPS) + 1):
            with self.subTest(completed_count=completed_count):
                shutil.rmtree(self.updater.state_root, ignore_errors=True)
                self.updater.state_root.mkdir(mode=0o700)
                completed = list(updater_module.ROLLBACK_STEPS[:completed_count])
                payload = {
                    "schema_version": updater_module.JOURNAL_SCHEMA_VERSION,
                    "transaction_id": "2" * 64,
                    "boot_id": self.boot_id.read_text().strip(),
                    "phase": "simulated_crash",
                    "previous_services": {
                        "macprovider-coordinator.service": True,
                        "macprovider-gateway.service": True,
                    },
                    "canary_timer_was_active": True,
                    "canary_service_was_active": True,
                    "previous_auxiliary_units": {
                        unit: False for unit in updater_module.AUXILIARY_UNITS
                    },
                    "previous_versions": {"coordinator": "v1.8.26", "gateway": "v1.8.26"},
                    "previous_advertised_version": "1.8.26",
                    "database_paths": [],
                    "deadman_previous_paused": False,
                    "deadman_restore_required": False,
                    "transaction": str(self.root / "tx-resume"),
                    "rollback_armed": True,
                    "rollback_in_progress": True,
                    "rollback_completed_steps": completed,
                    "live_mutation_started": True,
                    "success_persisted": False,
                }
                self.updater.journal_path.write_text(json.dumps(payload) + "\n")
                self.updater.journal_path.chmod(0o600)
                self.updater.validate_transaction = mock.Mock()
                mocks = {}
                for step, attribute in actions.items():
                    mocks[step] = mock.Mock()
                    setattr(self.updater, attribute, mocks[step])
                self.updater.audit = mock.Mock()

                self.assertTrue(self.updater.reconcile())

                for index, step in enumerate(updater_module.ROLLBACK_STEPS):
                    self.assertEqual(mocks[step].call_count, 0 if index < completed_count else 1)
                self.assertFalse(self.updater.journal_path.exists())

    def test_maintenance_and_quiescence_precede_snapshot(self):
        release = self.verify()
        order = []
        self.updater.capture_rollout_state = mock.Mock(side_effect=lambda: order.append("capture"))
        self.updater.snapshot = mock.Mock(side_effect=lambda _release: order.append("snapshot") or self.root / "tx")
        self.updater.enter_deadman_maintenance = mock.Mock(side_effect=lambda: order.append("deadman"))
        self.updater.stop_for_rollout = mock.Mock(side_effect=lambda: order.append("stop"))
        self.updater.install_release = mock.Mock(side_effect=lambda _release: order.append("install"))
        self.updater.verify_rollout = mock.Mock(side_effect=lambda _release: order.append("verify"))
        self.updater.persist_success = mock.Mock(side_effect=lambda *_args: order.append("persist"))
        self.updater.restore_deadman_monitoring = mock.Mock(side_effect=lambda: order.append("restore-deadman"))

        self.updater.apply(release, updater_module.SemVer.parse("1.8.26"))

        self.assertLess(order.index("deadman"), order.index("snapshot"))
        self.assertLess(order.index("stop"), order.index("snapshot"))

    def test_config_defaults_disable_production_apply(self):
        config = updater_module.load_config(self.root / "does-not-exist")
        self.assertFalse(config.enabled)
        self.assertFalse(config.allow_provider_drain)
        self.assertEqual(config.canary_timeout_s, 720)

    def test_no_sanction_recovery_or_internal_canary_enablement(self):
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("/admin/reject", source)
        self.assertNotIn("canary_enabled", source)

    def test_runbook_requires_load_credentials_and_removes_legacy_env(self):
        runbook = SCRIPT.parent.parent / "runbooks" / "pearl-release-updater.md"
        text = runbook.read_text(encoding="utf-8")
        self.assertIn("/etc/macprovider/canary-buyer.token", text)
        self.assertIn("/etc/macprovider/canary-buyer.heartbeat", text)
        self.assertIn("test ! -e /etc/macprovider/canary-buyer.env", text)
        self.assertNotIn("test -s /etc/macprovider/canary-buyer.env", text)

    def test_every_subprocess_invocation_has_an_explicit_timeout(self):
        tree = ast.parse(SCRIPT.read_text(encoding="utf-8"))
        calls = [
            node
            for node in ast.walk(tree)
            if isinstance(node, ast.Call)
            and isinstance(node.func, ast.Attribute)
            and node.func.attr == "run_command"
        ]
        self.assertGreater(len(calls), 0)
        for call in calls:
            self.assertIn("timeout", {keyword.arg for keyword in call.keywords}, f"line {call.lineno}")

    def test_systemd_preserves_transaction_until_internal_bounds_finish(self):
        transaction_gate = SCRIPT.with_name(
            "macprovider-pearl-updater-transaction-gate.conf"
        ).read_text(encoding="utf-8")
        self.assertEqual(transaction_gate, updater_module.TRANSACTION_GATE_DROPIN_TEXT)
        self.assertIn("ExecStartPre=+/usr/local/sbin/macprovider-pearl-update-gate %n", transaction_gate)
        unit = SCRIPT.with_name("macprovider-pearl-updater.service").read_text(encoding="utf-8")
        self.assertIn("TimeoutStartSec=infinity", unit)
        self.assertIn("TimeoutStopSec=infinity", unit)
        self.assertIn("ExecStopPost=/usr/local/sbin/macprovider-pearl-update --reconcile", unit)
        self.assertIn("OnFailure=macprovider-pearl-updater-alert@%n.service", unit)
        self.assertIn("RefuseManualStop=yes", unit)
        boot = SCRIPT.with_name("macprovider-pearl-updater-reconcile.service").read_text(encoding="utf-8")
        self.assertIn("TimeoutStartSec=infinity", boot)
        self.assertIn("ConditionPathExists=/var/lib/macprovider-pearl-updater/active-transaction.json", boot)
        self.assertIn("ExecStart=/usr/local/sbin/macprovider-pearl-update --reconcile", boot)
        self.assertIn(
            "Before=macprovider-coordinator.service macprovider-gateway.service "
            "canary-buyer.service canary-buyer.timer macprovider-archive-rotate.service "
            "macprovider-archive-rotate.timer stats-billing-mirror.service "
            "stats-billing-mirror.timer macprovider-pearl-updater.service",
            boot,
        )
        self.assertIn("WantedBy=multi-user.target", boot)
        alert = SCRIPT.with_name("macprovider-pearl-updater-alert@.service").read_text(encoding="utf-8")
        self.assertIn("User=macprovider", alert)
        self.assertIn("Group=macprovider", alert)
        self.assertIn("ExecStart=/usr/local/sbin/macprovider-pearl-updater-alert %i", alert)
        for hardened in (unit, boot):
            self.assertIn("NoNewPrivileges=true", hardened)
            self.assertIn("PrivateDevices=true", hardened)
            self.assertIn("MemoryDenyWriteExecute=true", hardened)

    def test_installer_preserves_config_directory_for_unprivileged_alert_reader(self):
        prefix = self.root / "installed-root"
        config_directory = prefix / "etc" / "macprovider"
        config_directory.mkdir(parents=True)
        config_directory.chmod(0o777)
        monitor = config_directory / "monitor.env"
        monitor.write_text("GMAIL_APP_PASSWORD=preserve-me\n")
        monitor.chmod(0o640)
        owner = pwd.getpwuid(os.geteuid()).pw_name
        group = grp.getgrgid(os.getegid()).gr_name
        environment = {
            **os.environ,
            "MACPROVIDER_UPDATER_TESTING": "1",
            "MACPROVIDER_UPDATER_INSTALL_ROOT": str(prefix),
            "MACPROVIDER_UPDATER_INSTALL_OWNER": owner,
            "MACPROVIDER_UPDATER_INSTALL_ROOT_GROUP": group,
            "MACPROVIDER_UPDATER_INSTALL_GROUP": group,
            "MACPROVIDER_UPDATER_SKIP_SYSTEMD": "1",
        }
        installed_result = subprocess.run(
            ["bash", str(SCRIPT.with_name("install-pearl-updater.sh"))],
            check=True,
            text=True,
            capture_output=True,
            env=environment,
        )
        self.assertIn(
            "manual success, failed-rollout rollback, and interrupted committed-success reconciliation drills all pass",
            installed_result.stdout,
        )
        installed = config_directory.stat()
        self.assertEqual((installed.st_uid, installed.st_gid), (os.geteuid(), os.getegid()))
        self.assertEqual(stat.S_IMODE(installed.st_mode), 0o750)
        self.assertEqual(monitor.read_text(), "GMAIL_APP_PASSWORD=preserve-me\n")
        self.assertEqual(stat.S_IMODE(monitor.stat().st_mode), 0o640)
        self.assertTrue((prefix / "usr/local/sbin/macprovider-pearl-update-gate").is_file())
        installer = SCRIPT.with_name("install-pearl-updater.sh").read_text(encoding="utf-8")
        self.assertIn("useradd --system --gid macprovider-updater-validate", installer)
        for unit in updater_module.GATED_SERVICE_UNITS:
            dropin = (
                prefix
                / "etc/systemd/system"
                / f"{unit}.d"
                / updater_module.TRANSACTION_GATE_DROPIN_NAME
            )
            self.assertEqual(dropin.read_text(), updater_module.TRANSACTION_GATE_DROPIN_TEXT)


if __name__ == "__main__":
    unittest.main()
