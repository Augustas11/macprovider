#!/usr/bin/env python3
from __future__ import annotations

import ast
import grp
import hashlib
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
import time
import unittest
import uuid
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("macprovider-pearl-update")
REPO_ROOT = SCRIPT.parents[2]
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

    def run_command(self, argv, *, check=True, timeout, env=None, input_text=None):
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
        return super().run_command(
            argv,
            check=check,
            timeout=timeout,
            env=env,
            input_text=input_text,
        )

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
            provider_recovery_timeout_s=240,
            revoked_versions_file=self.root / "revoked",
            provider_admission_policy="bridge_required",
            minimum_pool_ready_after_rollout=2,
            minimum_bridge_remaining_s=360,
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
            backend_gid=os.getegid(),
            catalog_verifier=REPO_ROOT / "scripts/catalog-release.py",
            tier2_coordinator_config=REPO_ROOT / "phase4-coordinator/dist/coordinator.yaml",
            catalog_canary_proof=SCRIPT.with_name("catalog-canary-proof.py"),
            canary_rollback_authorization=self.root / "canary-runtime" / "legacy-rollback.json",
            sleep=lambda _: None,
        )
        self.updater.candidate_executions = []
        self.updater.candidate_invocations = []

    def tearDown(self):
        self.temp.cleanup()

    class BuyerProofResponse:
        def __init__(
            self,
            *,
            request_id: str,
            provider_id: str = "catalog-canary",
            status: int = 200,
            url: str = "https://api.streamvc.live/v1/chat/completions",
            lines: list[bytes] | None = None,
        ):
            self.headers = {"X-Provider-Id": provider_id, "X-Request-Id": request_id}
            self.status = status
            self._url = url
            self._lines = lines if lines is not None else [
                b'data: {"model":"mlx-community/Llama-3.2-3B-Instruct-4bit","choices":[{"delta":{"content":"ok"}}]}\n\n',
                b"data: [DONE]\n\n",
            ]
            self.readline_limits: list[int] = []
            self._buffer = io.BytesIO(b"".join(self._lines))

        def geturl(self):
            return self._url

        def __enter__(self):
            return self

        def __exit__(self, *_args):
            return False

        def __iter__(self):
            return iter(self._lines)

        def readline(self, limit=-1):
            self.readline_limits.append(limit)
            return self._buffer.readline(limit)

    class BuyerProofOpener:
        def __init__(self, response_factory):
            self.response_factory = response_factory
            self.requests = []
            self.timeouts = []

        def open(self, request, *, timeout):
            self.requests.append(request)
            self.timeouts.append(timeout)
            response = self.response_factory(request)
            if isinstance(response, BaseException):
                raise response
            return response

    def buyer_proof_opener(self, response_factory):
        opener = self.BuyerProofOpener(response_factory)
        return opener, mock.patch.object(updater_module, "_credential_safe_opener", return_value=opener)

    def sign(self, payload: Path, signature: Path):
        subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", str(self.key), "-out", str(signature), str(payload)],
            check=True,
            capture_output=True,
        )

    def make_bundle(
        self,
        version: str = "1.8.27",
        advertised_version: str | None = None,
        rollout_mode: str = "bridge_required",
        channel: str | None = None,
        runtime_only: bool = False,
        ):
        tag = "v" + version
        advertised_version = advertised_version or version
        if runtime_only and rollout_mode == "bridge_required":
            rollout_mode = "strict_post_migration"
        coordinator = self.bundle / updater_module.COORDINATOR_ASSET
        coordinator_cli = self.bundle / updater_module.COORDINATOR_CLI_ASSET
        gateway = self.bundle / updater_module.GATEWAY_ASSET
        coordinator.write_bytes(fake_elf("coordinator"))
        coordinator_cli.write_bytes(fake_elf("coordinator-cli"))
        gateway.write_bytes(fake_elf("gateway"))
        for name in updater_module.CATALOG_ASSETS:
            (self.bundle / name).unlink(missing_ok=True)
        catalog_metadata = None
        catalog_assets = []
        release_lane = updater_module.RELEASE_LANE_RUNTIME
        if not runtime_only:
            catalog_sources = {
                "release.json": REPO_ROOT / "phase3-binary/catalog/autotune/release.json",
                "trusted-keys.json": REPO_ROOT / "phase3-binary/catalog/autotune/trusted-keys.json",
                "tier2-catalog.json": REPO_ROOT / "phase3-binary/catalog/autotune/tier2-catalog.json",
                "rate-card.json": REPO_ROOT / "phase3-binary/dist/static/rate-card.json",
                "rate-card.json.sig": REPO_ROOT / "phase3-binary/dist/static/rate-card.json.sig",
                "autotune-candidates.json": REPO_ROOT / "phase3-binary/dist/static/autotune-candidates.json",
                "autotune-candidates.json.sig": REPO_ROOT / "phase3-binary/dist/static/autotune-candidates.json.sig",
                "demand-rank.json": REPO_ROOT / "phase3-binary/dist/static/demand-rank.json",
                "demand-rank.json.sig": REPO_ROOT / "phase3-binary/dist/static/demand-rank.json.sig",
            }
            for name, source in catalog_sources.items():
                shutil.copyfile(source, self.bundle / name)
            catalog_manifest = json.loads((self.bundle / "release.json").read_text(encoding="utf-8"))
            catalog_assets = [self.bundle / name for name in updater_module.CATALOG_ASSETS]
            catalog_metadata = {
                "release_id": catalog_manifest["release_id"],
                "policy_version": catalog_manifest["policy_version"],
                "files": {
                    name: updater_module.sha256_file(self.bundle / name)
                    for name in updater_module.CATALOG_ASSETS
                },
            }
            release_lane = updater_module.RELEASE_LANE_RUNTIME_WITH_CATALOG
        metadata = {
            "schema_version": 1,
            "release_lane": release_lane,
            "repository": updater_module.PINNED_REPOSITORY,
            "tag": tag,
            "release_version": version,
            "commit": "a" * 40,
            "architecture": "linux-amd64",
            "provider_admission_rollout": {
                "mode": rollout_mode,
                "enforce_provider_admission": rollout_mode == "strict_post_migration",
                "bridge_duration_s": 0 if rollout_mode == "strict_post_migration" else 86400,
            },
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
            "catalog": catalog_metadata,
            "operator_artifacts": {
                "coordinator_cli": {
                    "asset": coordinator_cli.name,
                    "sha256": updater_module.sha256_file(coordinator_cli),
                },
            },
        }
        if not runtime_only:
            metadata["provider_advertised_version"] = advertised_version
        if channel is not None:
            metadata["channel"] = channel
        metadata_path = self.bundle / "pearl-release.json"
        metadata_path.write_text(json.dumps(metadata, sort_keys=True, separators=(",", ":")) + "\n")
        self.sign(metadata_path, self.bundle / "pearl-release.json.sig")
        assets = [
            metadata_path,
            self.bundle / "pearl-release.json.sig",
            coordinator,
            coordinator_cli,
            gateway,
            *catalog_assets,
        ]
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
        catalog_directory_name = self.updater._catalog_release_directory_name(release)
        catalog_release = install / "autotune" / "releases" / catalog_directory_name
        catalog_release.mkdir(parents=True, mode=0o750, exist_ok=True)
        (install / "autotune").chmod(0o750)
        (install / "autotune" / "releases").chmod(0o750)
        for name in updater_module.CATALOG_ASSETS:
            shutil.copy2(release.directory / name, catalog_release / name)
            (catalog_release / name).chmod(0o640)
        (install / "autotune" / "current").unlink(missing_ok=True)
        (install / "autotune" / "current").symlink_to(
            f"releases/{catalog_directory_name}"
        )
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
                    "catalog_release_id": release.catalog.release_id,
                    "catalog_policy_version": release.catalog.policy_version,
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

    def test_private_acceptance_channel_is_disabled_by_default(self):
        self.make_bundle(
            advertised_version="1.8.26",
            channel="private_acceptance",
        )
        with self.assertRaisesRegex(
            updater_module.UpdateError,
            "PEARL_UPDATER_ALLOW_PRIVATE_ACCEPTANCE=1",
        ):
            self.verify()

    def test_private_acceptance_channel_allows_independent_provider_version_when_enabled(self):
        self.make_bundle(
            advertised_version="1.8.26",
            channel="private_acceptance",
        )
        self.updater.config = updater_module.dataclasses.replace(
            self.updater.config,
            allow_private_acceptance=True,
        )
        release = self.verify()
        self.assertEqual(release.provider_advertised_version, "1.8.26")

    def test_private_acceptance_independent_provider_version_survives_journal_recovery(self):
        self.make_bundle(
            advertised_version="1.8.26",
            channel="private_acceptance",
        )
        self.updater.config = updater_module.dataclasses.replace(
            self.updater.config,
            allow_private_acceptance=True,
        )
        release = self.verify()
        self.updater._start_journal(release, updater_module.SemVer.parse("1.8.25"))

        recovered = self.updater.committed_release(self.updater.journal["release"])

        self.assertEqual(recovered.version, updater_module.SemVer.parse("1.8.27"))
        self.assertEqual(recovered.provider_advertised_version, "1.8.26")

    def test_runtime_only_release_verifies_without_catalog_feed_assets(self):
        self.make_bundle(runtime_only=True)

        release = self.verify()

        self.assertEqual(release.release_lane, updater_module.RELEASE_LANE_RUNTIME)
        self.assertIsNone(release.catalog)
        for name in updater_module.CATALOG_ASSETS:
            self.assertFalse((release.directory / name).exists(), name)

    def test_runtime_only_release_requires_explicit_tag_for_remote_acquire(self):
        self.make_bundle(runtime_only=True)
        self.updater.release_tags = mock.Mock(return_value=["v1.8.27"])
        self.updater.audit = mock.Mock()

        def fake_download(url: str, destination: Path) -> None:
            shutil.copyfile(self.bundle / url.rsplit("/", 1)[-1], destination)

        self.updater.download = mock.Mock(side_effect=fake_download)
        auto_work = self.root / "auto-acquire"
        explicit_work = self.root / "explicit-acquire"
        auto_work.mkdir()
        explicit_work.mkdir()

        with self.assertRaisesRegex(updater_module.NoEligibleRelease, "no signed Pearl runtime release"):
            self.updater.acquire_release(auto_work, None, None)

        self.updater.audit.assert_any_call(
            "release_skipped",
            "runtime_only_requires_explicit_tag",
            candidate="v1.8.27",
        )

        release = self.updater.acquire_release(explicit_work, None, "v1.8.27")

        self.assertEqual(release.release_lane, updater_module.RELEASE_LANE_RUNTIME)

    def test_runtime_only_metadata_rejects_provider_config_authority(self):
        self.make_bundle(runtime_only=True)
        payload = json.loads((self.bundle / "pearl-release.json").read_text())
        payload["provider_advertised_version"] = "1.8.27"

        with self.assertRaisesRegex(updater_module.UpdateError, "must not carry provider advertised version"):
            self.updater.parse_metadata(payload, self.bundle)

    def test_runtime_only_metadata_rejects_provider_bridge_policy(self):
        self.make_bundle(runtime_only=True)
        payload = json.loads((self.bundle / "pearl-release.json").read_text())
        payload["provider_admission_rollout"] = {
            "mode": "bridge_required",
            "enforce_provider_admission": False,
            "bridge_duration_s": 86400,
        }

        with self.assertRaisesRegex(updater_module.UpdateError, "must not bind provider admission bridge policy"):
            self.updater.parse_metadata(payload, self.bundle)

    def test_runtime_only_plan_preserves_existing_catalog_pointer(self):
        self.make_bundle(runtime_only=True)
        install = self.updater.install_root
        install.mkdir(parents=True)
        base = install / "coordinator.yaml"
        existing_catalog = "/opt/macprovider/autotune/current/tier2-catalog.json"
        base.write_text(
            'coordinator_advertised_version:\n  latest_binary_version: "1.8.26"\n'
            "tier2:\n"
            f"  catalog_path: {existing_catalog}\n"
            "  require_hash_verified: false\n"
        )
        self.updater.coordinator_runtime = mock.Mock(
            return_value=updater_module.CoordinatorRuntime(base, None, {})
        )
        release = self.stage(self.verify())

        update = self.updater.prepare_config_update(release)

        self.assertIsNone(update.catalog_target)
        self.assertIsNone(update.catalog_staged)
        self.assertEqual(update.previous_version, "1.8.26")
        self.assertEqual(update.next_version, "1.8.26")
        self.assertIn('latest_binary_version: "1.8.26"', update.staged.read_text())
        self.assertIn(f"catalog_path: {existing_catalog}", update.staged.read_text())
        self.assertEqual(
            self.updater.release_identity(release),
            updater_module.RuntimeIdentity("v1.8.27", "v1.8.27", "1.8.26"),
        )

    def test_runtime_only_success_preserves_durable_catalog_identity(self):
        catalog_release = self.verify().catalog
        self.assertIsNotNone(catalog_release)
        self.updater.state_root.mkdir(parents=True, exist_ok=True)
        self.updater.state_root.chmod(0o700)
        state = self.updater.state_root / "current-release.json"
        state.write_text(
            json.dumps(
                {
                    "schema_version": updater_module.CURRENT_RELEASE_SCHEMA_VERSION,
                    "version": "1.8.26",
                    "tag": "v1.8.26",
                    "commit": "b" * 40,
                    "coordinator_sha256": "0" * 64,
                    "gateway_sha256": "1" * 64,
                    "catalog_release_id": catalog_release.release_id,
                    "catalog_policy_version": catalog_release.policy_version,
                    "catalog_files": dict(catalog_release.files),
                }
            )
            + "\n"
        )
        state.chmod(0o600)
        self.make_bundle(runtime_only=True)
        release = self.verify()
        self.updater.transaction = self.root / "tx-runtime-success"

        self.updater.persist_success(release, updater_module.SemVer.parse("1.8.26"))

        persisted = json.loads(state.read_text())
        self.assertEqual(persisted["release_lane"], updater_module.RELEASE_LANE_RUNTIME)
        self.assertEqual(persisted["catalog_release_id"], catalog_release.release_id)
        self.assertEqual(persisted["catalog_policy_version"], catalog_release.policy_version)
        self.assertEqual(persisted["catalog_files"], catalog_release.files)

    def test_private_acceptance_opt_in_does_not_relax_production_metadata(self):
        self.make_bundle(advertised_version="1.8.26")
        self.updater.config = updater_module.dataclasses.replace(
            self.updater.config,
            allow_private_acceptance=True,
        )
        with self.assertRaisesRegex(updater_module.UpdateError, "advertised version must match"):
            self.verify()

    def test_unknown_release_channel_is_rejected(self):
        self.make_bundle(channel="staging")
        with self.assertRaisesRegex(updater_module.UpdateError, "channel is invalid"):
            self.verify()

    def test_signature_failure_rejected_before_artifact_execution(self):
        signature = self.bundle / "pearl-release.json.sig"
        corrupted = bytearray(signature.read_bytes())
        corrupted[-1] ^= 0x01
        signature.write_bytes(corrupted)
        with self.assertRaisesRegex(updater_module.UpdateError, "signature verification failed"):
            self.verify()

    def test_checksum_mismatch_rejected(self):
        with (self.bundle / updater_module.GATEWAY_ASSET).open("ab") as handle:
            handle.write(b"tampered")
        with self.assertRaisesRegex(updater_module.UpdateError, "checksum mismatch"):
            self.verify()

    def test_signed_checksums_cannot_override_catalog_manifest_binding(self):
        catalog = self.bundle / "autotune-candidates.json"
        catalog.write_bytes(catalog.read_bytes() + b"\n")
        assets = [
            self.bundle / "pearl-release.json",
            self.bundle / "pearl-release.json.sig",
            self.bundle / updater_module.COORDINATOR_ASSET,
            self.bundle / updater_module.COORDINATOR_CLI_ASSET,
            self.bundle / updater_module.GATEWAY_ASSET,
            *(self.bundle / name for name in updater_module.CATALOG_ASSETS),
        ]
        checksums = self.bundle / "checksums.txt"
        checksums.write_text(
            "".join(f"{updater_module.sha256_file(path)}  {path.name}\n" for path in assets)
        )
        self.sign(checksums, self.bundle / "checksums.txt.sig")
        with self.assertRaisesRegex(updater_module.UpdateError, "catalog metadata checksum mismatch"):
            self.verify()

    def test_catalog_inner_ed25519_verifier_rejects_resigned_outer_bundle(self):
        sidecar = self.bundle / "autotune-candidates.json.sig"
        signature = json.loads(sidecar.read_text(encoding="utf-8"))
        signature["signature"] = "A" * len(signature["signature"])
        sidecar.write_text(json.dumps(signature, sort_keys=True, separators=(",", ":")) + "\n")

        metadata_path = self.bundle / "pearl-release.json"
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        metadata["catalog"]["files"][sidecar.name] = updater_module.sha256_file(sidecar)
        metadata_path.write_text(json.dumps(metadata, sort_keys=True, separators=(",", ":")) + "\n")
        self.sign(metadata_path, self.bundle / "pearl-release.json.sig")
        assets = [
            metadata_path,
            self.bundle / "pearl-release.json.sig",
            self.bundle / updater_module.COORDINATOR_ASSET,
            self.bundle / updater_module.COORDINATOR_CLI_ASSET,
            self.bundle / updater_module.GATEWAY_ASSET,
            *(self.bundle / name for name in updater_module.CATALOG_ASSETS),
        ]
        checksums = self.bundle / "checksums.txt"
        checksums.write_text(
            "".join(f"{updater_module.sha256_file(path)}  {path.name}\n" for path in assets)
        )
        self.sign(checksums, self.bundle / "checksums.txt.sig")

        with self.assertRaisesRegex(updater_module.UpdateError, "inner Ed25519 verification failed"):
            self.verify()

    def test_catalog_install_and_rollback_restore_exact_pointers(self):
        release = self.stage(self.verify())
        catalog_directory_name = self.updater._catalog_release_directory_name(release)
        install = self.updater.install_root
        releases = install / "autotune" / "releases"
        releases.mkdir(parents=True, mode=0o750)
        (install / "autotune").chmod(0o750)
        releases.chmod(0o750)
        old_catalog = releases / "old-catalog"
        old_catalog.mkdir(mode=0o750)
        old_catalog.chmod(0o750)
        (old_catalog / "tier2-catalog.json").write_bytes(b'previous signed Tier-2 bytes\n')
        (old_catalog / "tier2-catalog.json").chmod(0o640)
        (releases / "older-catalog").mkdir(mode=0o750)
        (install / "autotune" / "current").symlink_to("releases/old-catalog")
        previous = install / "autotune" / ".previous-target"
        previous.write_text("releases/older-catalog\n")
        previous.chmod(0o600)
        legacy_tier2 = install / "tier2-catalog.json"
        legacy_tier2.write_bytes(b'previous signed Tier-2 bytes\n')
        legacy_tier2.chmod(0o600)
        legacy_stat = legacy_tier2.stat()

        self.updater.install_catalog(release)

        self.assertEqual(
            os.readlink(install / "autotune" / "current"),
            f"releases/{catalog_directory_name}",
        )
        self.assertEqual(previous.read_text().strip(), "releases/old-catalog")
        for name in updater_module.CATALOG_ASSETS:
            self.assertEqual(
                updater_module.sha256_file(releases / catalog_directory_name / name),
                release.catalog.files[name],
            )
        self.assertFalse(legacy_tier2.exists())

        tx = self.root / "catalog-rollback"
        tx.mkdir(mode=0o700)
        previous_tier2 = tx / "previous-tier2-catalog.json"
        previous_tier2.write_bytes(b'previous signed Tier-2 bytes\n')
        previous_tier2.chmod(0o600)
        (tx / "catalog-manifest.json").write_text(
            json.dumps(
                {
                    "current_target": "releases/old-catalog",
                    "previous_target": "releases/older-catalog",
                    "candidate_existed": False,
                    "candidate_release_id": catalog_directory_name,
                    "legacy_tier2": {
                        "existed": True,
                        "sha256": updater_module.sha256_file(previous_tier2),
                        "uid": legacy_stat.st_uid,
                        "gid": legacy_stat.st_gid,
                        "mode": 0o600,
                    },
                }
            )
            + "\n"
        )
        (tx / "catalog-manifest.json").chmod(0o600)
        self.updater._restore_catalog(tx)
        self.assertEqual(os.readlink(install / "autotune" / "current"), "releases/old-catalog")
        self.assertEqual(previous.read_text().strip(), "releases/older-catalog")
        self.assertEqual(previous.stat().st_gid, self.updater.catalog_gid)
        self.assertEqual(stat.S_IMODE(previous.stat().st_mode), 0o640)
        self.assertFalse((releases / catalog_directory_name).exists())
        self.assertEqual(legacy_tier2.read_bytes(), b'previous signed Tier-2 bytes\n')
        self.assertEqual(legacy_tier2.stat().st_uid, legacy_stat.st_uid)
        self.assertEqual(legacy_tier2.stat().st_gid, legacy_stat.st_gid)
        self.assertEqual(stat.S_IMODE(legacy_tier2.stat().st_mode), 0o600)

    def test_catalog_rollback_removes_legacy_when_previously_absent(self):
        release = self.stage(self.verify())
        catalog_directory_name = self.updater._catalog_release_directory_name(release)
        install = self.updater.install_root
        releases = install / "autotune" / "releases"
        releases.mkdir(parents=True, mode=0o750)
        (install / "autotune").chmod(0o750)
        releases.chmod(0o750)
        (install / "autotune" / "current").symlink_to(
            f"releases/{catalog_directory_name}"
        )
        legacy_tier2 = install / "tier2-catalog.json"
        legacy_tier2.write_text("candidate-created legacy file\n")
        legacy_tier2.chmod(0o640)
        tx = self.root / "catalog-rollback-absent"
        tx.mkdir(mode=0o700)
        (tx / "catalog-manifest.json").write_text(
            json.dumps(
                {
                    "current_target": None,
                    "previous_target": None,
                    "candidate_existed": False,
                    "candidate_release_id": catalog_directory_name,
                    "legacy_tier2": {"existed": False},
                }
            )
            + "\n"
        )
        (tx / "catalog-manifest.json").chmod(0o600)

        self.updater._restore_catalog(tx)

        self.assertFalse((install / "autotune" / "current").exists())
        self.assertFalse(legacy_tier2.exists())

    def test_runtime_only_snapshot_does_not_capture_catalog_ownership(self):
        self.make_bundle(runtime_only=True)
        install = self.updater.install_root
        install.mkdir(parents=True)
        for name in ("coordinator", "gateway"):
            (install / name).write_bytes(fake_elf("installed-" + name))
            (install / name).chmod(0o750)
        (install / "gateway.yaml").write_text("gateway: {}\n")
        (install / "gateway.yaml").chmod(0o600)
        base = install / "coordinator.yaml"
        base.write_text(
            'coordinator_advertised_version:\n  latest_binary_version: "1.8.26"\n'
            "tier2:\n"
            f"  catalog_path: {install}/autotune/current/tier2-catalog.json\n"
            "  require_hash_verified: false\n"
        )
        base.chmod(0o600)
        releases = install / "autotune" / "releases"
        releases.mkdir(parents=True, mode=0o750)
        (install / "autotune").chmod(0o750)
        (releases / "catalog-a").mkdir(mode=0o750)
        (install / "autotune" / "current").symlink_to("releases/catalog-a")
        previous = install / "autotune" / ".previous-target"
        previous.write_text("releases/catalog-a\n")
        previous.chmod(0o600)
        self.updater.coordinator_runtime = mock.Mock(
            return_value=updater_module.CoordinatorRuntime(base, None, {})
        )
        self.updater.previous_versions = {
            "coordinator": "1.8.26",
            "gateway": "1.8.26",
        }
        release = self.stage(self.verify())
        self.updater.prepare_config_update(release)

        tx = self.updater.snapshot(release)

        manifest = json.loads((tx / "catalog-manifest.json").read_text())
        self.assertEqual(manifest, {"owns_catalog": False})
        self.assertFalse((tx / "previous-tier2-catalog.json").exists())

    def test_runtime_only_catalog_rollback_is_noop(self):
        install = self.updater.install_root
        releases = install / "autotune" / "releases"
        releases.mkdir(parents=True, mode=0o750)
        (install / "autotune").chmod(0o750)
        (releases / "catalog-b").mkdir(mode=0o750)
        (install / "autotune" / "current").symlink_to("releases/catalog-b")
        previous = install / "autotune" / ".previous-target"
        previous.write_text("releases/catalog-b\n")
        previous.chmod(0o600)
        tx = self.root / "runtime-only-catalog-noop"
        tx.mkdir(mode=0o700)
        (tx / "catalog-manifest.json").write_text('{"owns_catalog":false}\n')
        (tx / "catalog-manifest.json").chmod(0o600)
        self.updater.audit = mock.Mock()

        self.updater._restore_catalog(tx)

        self.assertEqual(os.readlink(install / "autotune" / "current"), "releases/catalog-b")
        self.assertEqual(previous.read_text().strip(), "releases/catalog-b")
        self.updater.audit.assert_called_once_with(
            "catalog_rollback",
            "skipped",
            reason="runtime-only transaction",
        )

    def test_catalog_install_uses_service_group_and_repairs_restrictive_umask(self):
        release = self.stage(self.verify())
        install = self.updater.install_root
        install.mkdir(mode=0o750)
        install.chmod(0o750)
        service_gid = os.getegid()
        self.updater.catalog_gid = service_gid
        self.updater.candidate_gid = service_gid + 10_000

        with (
            mock.patch.object(updater_module.os, "chown", wraps=os.chown) as chown,
            mock.patch.object(updater_module.os, "fchown", wraps=os.fchown) as fchown,
        ):
            previous_umask = os.umask(0o077)
            try:
                self.updater.install_catalog(release)
            finally:
                os.umask(previous_umask)

        self.assertGreaterEqual(chown.call_count, 3)
        for call in chown.call_args_list:
            self.assertEqual(call.args[2], service_gid)
            self.assertEqual(call.kwargs, {"follow_symlinks": False})
        releases = install / "autotune" / "releases"
        destination = releases / self.updater._catalog_release_directory_name(release)
        self.assertIn(install / "autotune", [call.args[0] for call in chown.call_args_list])
        self.assertIn(releases, [call.args[0] for call in chown.call_args_list])
        for directory in (install / "autotune", releases, destination):
            self.assertEqual(directory.stat().st_gid, service_gid)
            self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o750)
        self.assertGreaterEqual(fchown.call_count, len(updater_module.CATALOG_ASSETS) + 1)
        for call in fchown.call_args_list:
            self.assertEqual(call.args[2], service_gid)
        for name in updater_module.CATALOG_ASSETS:
            installed = destination / name
            self.assertEqual(installed.stat().st_gid, service_gid)
            self.assertEqual(stat.S_IMODE(installed.stat().st_mode), 0o640)

    def test_catalog_cutover_gate_rejects_mismatched_legacy_before_mutation(self):
        release = self.stage(self.verify())
        install = self.updater.install_root
        catalog_root = install / "autotune"
        releases = catalog_root / "releases"
        active = releases / "active-catalog"
        active.mkdir(parents=True, mode=0o750)
        catalog_root.chmod(0o750)
        releases.chmod(0o750)
        active.chmod(0o750)
        shutil.copy2(release.directory / "tier2-catalog.json", active / "tier2-catalog.json")
        (active / "tier2-catalog.json").chmod(0o640)
        (catalog_root / "current").symlink_to("releases/active-catalog")
        legacy = install / "tier2-catalog.json"
        legacy.write_text("different legacy bytes\n")
        legacy.chmod(0o640)

        with mock.patch.object(self.updater, "_repair_catalog_directory") as repair:
            with self.assertRaisesRegex(
                updater_module.UpdateError,
                "does not match the active release-bound catalog",
            ):
                self.updater.install_catalog(release)

        repair.assert_not_called()
        self.assertTrue(legacy.exists())
        self.assertEqual(os.readlink(catalog_root / "current"), "releases/active-catalog")

    def test_catalog_cutover_gate_rejects_symlinked_release_directory(self):
        release = self.stage(self.verify())
        install = self.updater.install_root
        catalog_root = install / "autotune"
        releases = catalog_root / "releases"
        releases.mkdir(parents=True, mode=0o750)
        catalog_root.chmod(0o750)
        releases.chmod(0o750)
        external = self.root / "external-catalog"
        external.mkdir(mode=0o750)
        current_tier2 = external / "tier2-catalog.json"
        shutil.copy2(release.directory / "tier2-catalog.json", current_tier2)
        current_tier2.chmod(0o640)
        (releases / "active-catalog").symlink_to(external, target_is_directory=True)
        (catalog_root / "current").symlink_to("releases/active-catalog")
        legacy = install / "tier2-catalog.json"
        shutil.copy2(current_tier2, legacy)
        legacy.chmod(0o640)

        with mock.patch.object(self.updater, "_repair_catalog_directory") as repair:
            with self.assertRaisesRegex(
                updater_module.UpdateError,
                "installed catalog release is not a directory",
            ):
                self.updater.install_catalog(release)

        repair.assert_not_called()
        self.assertTrue(legacy.exists())
        self.assertEqual(os.readlink(catalog_root / "current"), "releases/active-catalog")

    def test_remove_legacy_tier2_rejects_non_regular_path(self):
        legacy = self.updater.install_root / "tier2-catalog.json"
        legacy.parent.mkdir(parents=True)
        target = self.root / "legacy-target"
        target.write_text("signed bytes\n")
        legacy.symlink_to(target)

        with self.assertRaisesRegex(
            updater_module.UpdateError,
            "legacy Tier-2 catalog is not a regular file",
        ):
            self.updater._remove_legacy_tier2_catalog()

        self.assertTrue(legacy.is_symlink())
        self.assertEqual(target.read_text(), "signed bytes\n")

    def test_candidate_assessment_rejects_legacy_mismatch_before_mutation(self):
        release = self.stage(self.verify())
        self.install_coherent_pair(release)
        legacy = self.updater.install_root / "tier2-catalog.json"
        legacy.write_text("different legacy bytes\n")
        legacy.chmod(0o640)
        self.updater.atomic_install = mock.Mock()
        self.updater.install_catalog = mock.Mock()
        self.updater.candidate_executions.clear()

        with self.assertRaisesRegex(
            updater_module.UpdateError,
            "does not match the active release-bound catalog",
        ):
            self.updater.assess_candidate(release)

        self.updater.atomic_install.assert_not_called()
        self.updater.install_catalog.assert_not_called()
        self.assertEqual(self.updater.candidate_executions, [])

    def test_candidate_assessment_rejects_upgrade_while_legacy_tier2_exists(self):
        old_release = self.stage(self.verify())
        self.install_coherent_pair(old_release)
        legacy = self.updater.install_root / "tier2-catalog.json"
        shutil.copy2(self.updater._current_tier2_catalog_path(), legacy)
        legacy.chmod(0o640)
        self.make_bundle("1.8.28")
        self.updater.candidate_version = "v1.8.28"
        upgrade = self.stage(self.updater.verify_release(self.bundle, "v1.8.28"))
        self.updater.candidate_executions.clear()

        with self.assertRaisesRegex(
            updater_module.UpdateError,
            "requires same-version repair_pair before upgrade",
        ):
            self.updater.assess_candidate(upgrade)

        self.assertEqual(self.updater.candidate_executions, [])

    def test_catalog_cutover_gate_rejects_unsafe_legacy_before_mutation(self):
        release = self.stage(self.verify())
        install = self.updater.install_root
        catalog_root = install / "autotune"
        releases = catalog_root / "releases"
        active = releases / "active-catalog"
        active.mkdir(parents=True, mode=0o750)
        catalog_root.chmod(0o750)
        releases.chmod(0o750)
        active.chmod(0o750)
        shutil.copy2(release.directory / "tier2-catalog.json", active / "tier2-catalog.json")
        (active / "tier2-catalog.json").chmod(0o640)
        (catalog_root / "current").symlink_to("releases/active-catalog")
        target = self.root / "unsafe-target"
        target.write_text("do not overwrite\n")
        legacy = install / "tier2-catalog.json"
        legacy.symlink_to(target)

        with mock.patch.object(self.updater, "_repair_catalog_directory") as repair:
            with self.assertRaisesRegex(
                updater_module.UpdateError,
                "legacy Tier-2 catalog is not a regular file",
            ):
                self.updater.install_catalog(release)

        repair.assert_not_called()
        self.assertTrue(legacy.is_symlink())
        self.assertEqual(target.read_text(), "do not overwrite\n")

    def test_catalog_cutover_gate_rejects_legacy_without_valid_current_before_mutation(self):
        release = self.stage(self.verify())
        install = self.updater.install_root
        install.mkdir(mode=0o750)
        legacy = install / "tier2-catalog.json"
        legacy.write_bytes((release.directory / "tier2-catalog.json").read_bytes())
        legacy.chmod(0o640)

        with mock.patch.object(self.updater, "_repair_catalog_directory") as repair:
            with self.assertRaisesRegex(
                updater_module.UpdateError,
                "without a valid current catalog pointer",
            ):
                self.updater.install_catalog(release)

        repair.assert_not_called()
        self.assertTrue(legacy.exists())

    def test_catalog_install_allows_bootstrap_when_current_and_legacy_are_absent(self):
        release = self.stage(self.verify())
        self.updater.install_root.mkdir(mode=0o750)
        self.updater.install_catalog(release)

        install = self.updater.install_root
        self.assertEqual(
            os.readlink(install / "autotune" / "current"),
            f"releases/{self.updater._catalog_release_directory_name(release)}",
        )
        self.assertFalse((install / "tier2-catalog.json").exists())

    def test_catalog_directory_identity_includes_keyring_digest(self):
        release = self.stage(self.verify())
        changed_files = dict(release.catalog.files)
        changed_files["trusted-keys.json"] = "f" * 64
        rebound_keyring = updater_module.Release(
            release.tag,
            release.version,
            release.commit,
            release.provider_advertised_version,
            release.coordinator,
            release.gateway,
            updater_module.CatalogRelease(
                release.catalog.release_id,
                release.catalog.policy_version,
                changed_files,
            ),
            release.provider_admission_rollout,
            release.directory,
            updater_module.RELEASE_LANE_RUNTIME_WITH_CATALOG,
        )

        original_name = self.updater._catalog_release_directory_name(release)
        rebound_name = self.updater._catalog_release_directory_name(rebound_keyring)

        self.assertNotEqual(original_name, rebound_name)
        self.assertTrue(original_name.startswith(f"{release.catalog.release_id}-"))
        self.assertTrue(rebound_name.startswith(f"{release.catalog.release_id}-"))

    def test_catalog_install_repairs_existing_release_permissions_for_service(self):
        release = self.stage(self.verify())
        install = self.updater.install_root
        releases = install / "autotune" / "releases"
        destination = releases / self.updater._catalog_release_directory_name(release)
        destination.mkdir(parents=True, mode=0o700)
        (install / "autotune").chmod(0o700)
        releases.chmod(0o700)
        destination.chmod(0o700)
        for name in updater_module.CATALOG_ASSETS:
            installed = destination / name
            shutil.copyfile(release.directory / name, installed)
            installed.chmod(0o600)

        service_gid = os.getegid()
        self.updater.catalog_gid = service_gid
        self.updater.candidate_gid = service_gid + 10_000
        self.updater.install_catalog(release)

        for directory in (install / "autotune", releases, destination):
            self.assertEqual(directory.stat().st_gid, service_gid)
            self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o750)
        for name in updater_module.CATALOG_ASSETS:
            installed = destination / name
            self.assertEqual(installed.stat().st_gid, service_gid)
            self.assertEqual(stat.S_IMODE(installed.stat().st_mode), 0o640)

    def test_catalog_existing_hash_mismatch_does_not_partially_repair_release(self):
        release = self.stage(self.verify())
        destination = (
            self.updater.install_root
            / "autotune"
            / "releases"
            / self.updater._catalog_release_directory_name(release)
        )
        destination.mkdir(parents=True, mode=0o700)
        (self.updater.install_root / "autotune").chmod(0o700)
        destination.parent.chmod(0o700)
        destination.chmod(0o700)
        for name in updater_module.CATALOG_ASSETS:
            installed = destination / name
            shutil.copyfile(release.directory / name, installed)
            installed.chmod(0o600)
        (destination / updater_module.CATALOG_ASSETS[-1]).write_text("tampered\n")
        before = {
            path: stat.S_IMODE(path.stat().st_mode)
            for path in (destination, *(destination / name for name in updater_module.CATALOG_ASSETS))
        }

        with self.assertRaisesRegex(updater_module.UpdateError, "already exists with different bytes"):
            self.updater.install_catalog(release)

        after = {path: stat.S_IMODE(path.stat().st_mode) for path in before}
        self.assertEqual(after, before)

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

    def test_clean_legacy_git_describe_pair_can_bootstrap_to_newer_signed_release(self):
        self.install_pair("v1.8.26-4-g64083ef", "v1.8.20-4-ga5e12c2")
        self.make_bundle("1.8.30")
        self.updater.candidate_version = "v1.8.30"
        release = self.stage(self.updater.verify_release(self.bundle, "v1.8.30"))

        current, decision = self.updater.assess_candidate(release)

        self.assertEqual(str(current), "1.8.26")
        self.assertEqual(decision, "upgrade")

    def test_legacy_git_describe_bootstrap_requires_strictly_newer_release(self):
        self.install_pair("v1.8.26-4-g64083ef", "v1.8.20-4-ga5e12c2")
        self.make_bundle("1.8.26")
        release = self.updater.verify_release(self.bundle, "v1.8.26")

        with self.assertRaisesRegex(updater_module.UpdateError, "requires a signed release newer"):
            self.updater.eligibility(release)

    def test_legacy_bootstrap_rejects_dirty_or_ambiguous_build_versions(self):
        for value in (
            "v1.8.26-4-g64083ef-dirty",
            "v1.8.26-4-g64083ef-dirty-forced",
            "64083ef",
            "v1.8.26-0-g64083ef",
            "v1.8.26-4-gNOTHEX",
        ):
            with self.subTest(value=value):
                self.install_pair(value, "v1.8.20-4-ga5e12c2")
                with self.assertRaisesRegex(updater_module.UpdateError, "does not report a semantic version"):
                    self.updater.installed_release()

    def test_legacy_bootstrap_rejects_conflicting_durable_release_state(self):
        self.install_pair("v1.8.26-4-g64083ef", "v1.8.20-4-ga5e12c2", "1.8.26")

        with self.assertRaisesRegex(updater_module.UpdateError, "cannot coexist"):
            self.updater.installed_release()

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
            'tier2:\n'
            '  catalog_path: /opt/macprovider/tier2-catalog.json\n'
            '  require_hash_verified: false\n'
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
        staged_text = update.staged.read_text()
        self.assertIn('latest_binary_version: "1.8.27"', staged_text)
        self.assertIn('operator_key: "env:OPERATOR_KEY"', staged_text)
        self.assertIn("enforce_provider_admission: false", staged_text)
        self.assertIn(
            f"catalog_path: {self.updater.install_root}/autotune/current/tier2-catalog.json",
            staged_text,
        )
        self.assertIn("require_hash_verified: false", staged_text)
        self.assertRegex(staged_text, r'provider_admission_bridge_deadline: "[^"]+Z"')

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

    def test_advertised_version_update_preserves_hash_enforcement(self):
        install = self.updater.install_root
        install.mkdir(parents=True)
        base = install / "coordinator.yaml"
        base.write_text(
            'coordinator_advertised_version:\n'
            '  latest_binary_version: "1.8.26"\n'
            'tier2:\n'
            f'  catalog_path: {install}/autotune/current/tier2-catalog.json\n'
            '  require_hash_verified: true\n'
        )
        self.updater.coordinator_runtime = mock.Mock(
            return_value=updater_module.CoordinatorRuntime(base, None, {})
        )
        release = self.stage(self.verify())
        self.updater.verify_candidate_versions(release)

        update = self.updater.prepare_config_update(release)

        self.assertIn("require_hash_verified: true", update.staged.read_text())

    def test_advertised_version_update_rejects_legacy_algorithm_bridge_when_enforced(self):
        install = self.updater.install_root
        install.mkdir(parents=True)
        base = install / "coordinator.yaml"
        base.write_text(
            'coordinator_advertised_version:\n'
            '  latest_binary_version: "1.8.26"\n'
            'tier2:\n'
            f'  catalog_path: {install}/autotune/current/tier2-catalog.json\n'
            '  require_hash_verified: true\n'
            '  model_hash_legacy_until: env:MODEL_HASH_LEGACY_UNTIL\n'
        )
        self.updater.coordinator_runtime = mock.Mock(
            return_value=updater_module.CoordinatorRuntime(
                base,
                None,
                {"MODEL_HASH_LEGACY_UNTIL": "2026-07-24T00:00:00Z"},
            )
        )
        release = self.stage(self.verify())

        with self.assertRaisesRegex(
            updater_module.UpdateError,
            "cannot retain the model hash algorithm legacy bridge",
        ):
            self.updater.prepare_config_update(release)

    def test_atomic_install_uses_backend_group_not_legacy_destination_group(self):
        source = self.root / "candidate-coordinator"
        destination = self.root / "coordinator"
        source.write_bytes(fake_elf("candidate"))
        destination.write_bytes(fake_elf("legacy"))
        legacy_gid = self.updater.backend_gid + 10_000
        installed = mock.Mock(
            st_gid=self.updater.backend_gid,
            st_mode=stat.S_IFREG | 0o750,
        )
        with (
            mock.patch.object(
                self.updater,
                "_trusted_regular_file",
                side_effect=[mock.Mock(st_gid=legacy_gid), installed],
            ),
            mock.patch.object(self.updater, "atomic_replace") as replace,
            mock.patch.object(
                updater_module,
                "sha256_file",
                side_effect=["candidate-sha", "candidate-sha"],
            ),
        ):
            self.updater.atomic_install(source, destination)

        replace.assert_called_once_with(
            source,
            destination,
            uid=self.updater.trusted_uid,
            gid=self.updater.backend_gid,
            mode=0o750,
        )

    def test_restore_binaries_normalizes_backend_group_and_mode(self):
        install = self.updater.install_root
        transaction = self.root / "rollback-binaries"
        install.mkdir(parents=True)
        transaction.mkdir()
        for name in ("coordinator", "gateway"):
            (install / name).write_bytes(fake_elf("candidate-" + name))
            (install / name).chmod(0o755)
            (transaction / name).write_bytes(fake_elf("previous-" + name))
            (transaction / name).chmod(0o600)

        self.updater._restore_binaries(transaction)

        for name in ("coordinator", "gateway"):
            restored = install / name
            self.assertEqual(restored.read_bytes(), fake_elf("previous-" + name))
            self.assertEqual(restored.stat().st_uid, self.updater.trusted_uid)
            self.assertEqual(restored.stat().st_gid, self.updater.backend_gid)
            self.assertEqual(stat.S_IMODE(restored.stat().st_mode), 0o750)

    def test_strict_signed_release_enforces_admission_and_removes_bridge_deadline(self):
        self.make_bundle(rollout_mode="strict_post_migration")
        install = self.updater.install_root
        install.mkdir(parents=True)
        base = install / "coordinator.yaml"
        base.write_text(
            "autotune:\n"
            "  enforce_provider_admission: false\n"
            '  provider_admission_bridge_deadline: "2026-07-12T00:00:00Z"\n'
            "coordinator_advertised_version:\n"
            '  latest_binary_version: "1.8.26"\n'
            "tier2:\n"
            f"  catalog_path: {self.updater.install_root}/tier2-catalog.json\n"
            "  require_hash_verified: false\n"
        )
        self.updater.config = updater_module.dataclasses.replace(
            self.updater.config,
            provider_admission_policy="strict_post_migration",
            minimum_bridge_remaining_s=0,
        )
        self.updater.coordinator_runtime = mock.Mock(
            return_value=updater_module.CoordinatorRuntime(base, None, {})
        )
        release = self.stage(self.verify())
        self.updater.verify_candidate_versions(release)

        update = self.updater.prepare_config_update(release)

        staged = update.staged.read_text()
        self.assertIn("enforce_provider_admission: true", staged)
        self.assertNotIn("provider_admission_bridge_deadline", staged)

    def test_legacy_rollback_accepts_only_an_absent_advertised_version_field(self):
        legacy = updater_module.RuntimeIdentity(
            "v1.8.26-4-g64083ef",
            "v1.8.20-4-ga5e12c2",
            "1.8.26",
        )
        release = updater_module.RuntimeIdentity("v1.8.30", "v1.8.30", "1.8.30")
        self.updater.get_json = mock.Mock(
            return_value={
                "status": "ok",
                "version": legacy.coordinator_version,
            }
        )

        self.assertTrue(self.updater.local_coordinator_identity_ready(legacy, False))
        self.updater.get_json.return_value["recommended_binary_version"] = "1.8.25"
        self.assertFalse(self.updater.local_coordinator_identity_ready(legacy, False))
        self.updater.get_json.return_value["recommended_binary_version"] = None
        self.assertFalse(self.updater.local_coordinator_identity_ready(legacy, False))
        self.updater.get_json.return_value = {
            "status": "ok",
            "version": release.coordinator_version,
        }
        self.assertFalse(self.updater.local_coordinator_identity_ready(release, False))

    def test_legacy_rollback_public_health_accepts_the_same_omission(self):
        legacy = updater_module.RuntimeIdentity(
            "v1.8.26-4-g64083ef",
            "v1.8.20-4-ga5e12c2",
            "1.8.26",
        )
        coordinator = {
            "status": "ok",
            "version": legacy.coordinator_version,
        }
        gateway = {
            "status": "ok",
            "version": legacy.gateway_version,
        }
        self.updater.get_json = mock.Mock(side_effect=[coordinator, gateway])

        self.assertTrue(self.updater.public_identity_ready(legacy))
        coordinator["recommended_binary_version"] = None
        self.updater.get_json = mock.Mock(side_effect=[coordinator, gateway])
        self.assertFalse(self.updater.public_identity_ready(legacy))

    def test_advertised_version_update_targets_effective_overlay(self):
        install = self.updater.install_root
        install.mkdir(parents=True)
        base = install / "coordinator.yaml"
        overlay = self.root / "coordinator.overlay.yaml"
        base.write_text(
            'coordinator_advertised_version:\n  latest_binary_version: "1.8.25"\n'
            "tier2:\n"
            f"  catalog_path: {self.updater.install_root}/tier2-catalog.json\n"
            "  require_hash_verified: false\n"
        )
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
        self.assertEqual(update.catalog_target, base)
        self.assertIn('latest_binary_version: "1.8.27"', update.staged.read_text())
        self.assertIn('canary_enabled: false', update.staged.read_text())
        self.assertIn(
            f"catalog_path: {self.updater.install_root}/autotune/current/tier2-catalog.json",
            update.catalog_staged.read_text(),
        )
        self.assertNotIn("latest_binary_version: \"1.8.27\"", update.catalog_staged.read_text())

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
        base.write_text(
            'coordinator_advertised_version:\n  latest_binary_version: "1.8.26"\n'
            "tier2:\n"
            f"  catalog_path: {self.updater.install_root}/tier2-catalog.json\n"
            "  require_hash_verified: false\n"
        )
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

    def test_global_lock_is_released_after_holder_is_interrupted(self):
        lock = self.root / "global-deployment.lock"
        child = subprocess.Popen(
            [
                sys.executable,
                "-c",
                (
                    "import fcntl,sys,time; "
                    "f=open(sys.argv[1],'w'); fcntl.flock(f,fcntl.LOCK_EX); "
                    "print('LOCKED',flush=True); time.sleep(60)"
                ),
                str(lock),
            ],
            stdout=subprocess.PIPE,
            text=True,
        )
        self.assertEqual(child.stdout.readline().strip(), "LOCKED")
        with self.assertRaises(updater_module.LockBusy):
            with updater_module.FileLock(lock, required_uid=os.geteuid()):
                pass
        child.kill()
        child.wait(timeout=5)
        child.stdout.close()
        with updater_module.FileLock(lock, required_uid=os.geteuid()):
            pass

    def test_provider_connected_guard_fails_before_mutation(self):
        self.updater.get_json = mock.Mock(return_value={"pool_size": 1, "pool_ready": 1})
        self.updater.systemctl = mock.Mock()
        with self.assertRaisesRegex(updater_module.UpdateError, "provider drain protection"):
            self.updater.stop_for_rollout()
        self.updater.systemctl.assert_not_called()

    def test_capture_rollout_state_records_ready_provider_baseline(self):
        expected_fleet = self.root / "capture-expected-fleet.json"
        expected_providers = [
            {"provider_id": f"provider-{index}", "model_id": f"model-{index}"}
            for index in range(3)
        ]
        expected_fleet.write_text(
            json.dumps({"schema_version": 1, "providers": expected_providers}) + "\n"
        )
        expected_fleet.chmod(0o600)
        self.updater.capture_database_paths = mock.Mock()
        self.updater.get_json = mock.Mock(
            return_value={"pool_size": 4, "pool_ready": 3}
        )
        self.updater.coordinator_operator_token = mock.Mock(return_value="operator-token")
        self.updater.get_authorized_json = mock.Mock(return_value={
            "pool": [
                {
                    "provider_id": f"provider-{index}",
                    "model_id": f"model-{index}",
                    "state": "ready",
                    "routing_eligible": True,
                }
                for index in range(3)
            ] + [{"provider_id": "degraded", "state": "degraded", "routing_eligible": False}]
        })
        self.updater.config = updater_module.dataclasses.replace(
            self.updater.config, allow_provider_drain=True
        )
        self.updater.service_active = mock.Mock(return_value=True)
        self.updater.read_installed_versions = mock.Mock(
            return_value={"coordinator": "v1.8.26", "gateway": "v1.8.26"}
        )
        self.updater._journal_transition = mock.Mock()

        with mock.patch.object(updater_module, "CANARY_EXPECTED_FLEET", expected_fleet):
            self.updater.capture_rollout_state()

        self.assertEqual(self.updater.previous_pool_ready, 3)
        self.assertEqual(
            self.updater.previous_protected_providers,
            ["provider-0", "provider-1", "provider-2"],
        )
        self.assertEqual(
            self.updater.previous_protected_fleet,
            expected_providers,
        )
        self.assertEqual(
            self.updater._journal_transition.call_args.kwargs["previous_pool_ready"],
            3,
        )
        self.assertEqual(
            self.updater._journal_transition.call_args.kwargs["previous_protected_fleet"],
            expected_providers,
        )

    def test_capture_rollout_state_uses_live_tuple_baseline_despite_stale_expected_fleet(self):
        expected_fleet = self.root / "stale-capture-expected-fleet.json"
        expected_fleet.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "providers": [{"provider_id": "provider-0", "model_id": "model-0"}],
                }
            )
            + "\n"
        )
        expected_fleet.chmod(0o600)
        protected_providers = [
            {"provider_id": f"provider-{index}", "model_id": f"model-{index}"}
            for index in range(3)
        ]
        self.updater.capture_database_paths = mock.Mock()
        self.updater.get_json = mock.Mock(
            return_value={"pool_size": 3, "pool_ready": 3}
        )
        self.updater.coordinator_operator_token = mock.Mock(return_value="operator-token")
        self.updater.get_authorized_json = mock.Mock(return_value={
            "pool": [
                {
                    **row,
                    "state": "ready",
                    "routing_eligible": True,
                    "binary_version": "1.8.30",
                }
                for row in protected_providers
            ]
        })
        self.updater.config = updater_module.dataclasses.replace(
            self.updater.config, allow_provider_drain=True
        )
        self.updater.service_active = mock.Mock(return_value=True)
        self.updater.read_installed_versions = mock.Mock(
            return_value={"coordinator": "v1.8.30", "gateway": "v1.8.30"}
        )
        self.updater._journal_transition = mock.Mock()

        with mock.patch.object(updater_module, "CANARY_EXPECTED_FLEET", expected_fleet):
            self.updater.capture_rollout_state()

        self.assertEqual(self.updater.previous_protected_fleet, protected_providers)
        self.assertEqual(
            self.updater.previous_protected_providers,
            ["provider-0", "provider-1", "provider-2"],
        )
        self.updater.journal = {
            "transaction_id": "d" * 64,
            "previous_advertised_version": "1.8.30",
            "rollback_armed": True,
            "rollback_in_progress": True,
            "live_mutation_started": True,
            "success_persisted": False,
        }

        with mock.patch.object(updater_module, "CANARY_EXPECTED_FLEET", expected_fleet):
            self.updater._write_legacy_rollback_authorization("1.8.30")

        document = json.loads(self.updater.canary_rollback_authorization.read_text())
        self.assertEqual(
            document["providers"],
            [{**row, "binary_version": "1.8.30"} for row in protected_providers],
        )

    def test_restart_failure_invokes_rollback(self):
        release = self.verify()
        self.updater.audit = mock.Mock()
        self.updater.enter_deadman_maintenance = mock.Mock(
            side_effect=lambda: setattr(self.updater, "deadman_restore_required", True)
        )
        self.updater.restore_deadman_monitoring = mock.Mock()
        self.updater.stop_for_rollout = mock.Mock()
        self.updater.snapshot = mock.Mock(return_value=self.root / "tx")
        self.updater.verify_buyer_canary_rollout_posture = mock.Mock()
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
        self.updater.assert_effective_tier2_catalog_path = mock.Mock()
        self.updater.prove_serving_recovery = mock.Mock()
        self.updater.verify_provider_admission_rollout_policy = mock.Mock()
        self.updater.verify_exact_catalog_admission = mock.Mock()
        self.updater.verify_exact_provider_canary = mock.Mock()
        self.updater.verify_buyer_canary_rollout_posture = mock.Mock()
        self.updater.verify_live_runtime_binding = mock.Mock()
        self.updater.restore_auxiliary_services = mock.Mock()
        self.updater.restore_auxiliary_timers = mock.Mock()
        self.updater._restore_canary_timer = mock.Mock()
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
        self.updater.assert_effective_tier2_catalog_path.assert_called_once_with()
        self.updater.verify_provider_admission_rollout_policy.assert_called_once_with()
        self.updater.verify_live_runtime_binding.assert_called_once_with(release)
        self.updater.verify_exact_catalog_admission.assert_called_once_with(release)
        self.updater.verify_exact_provider_canary.assert_called_once_with(release)
        self.updater.verify_buyer_canary_rollout_posture.assert_called_once_with()
        self.updater._restore_canary_timer.assert_called_once_with()

    def test_rollout_rejects_tier2_drift_after_coordinator_health_before_gateway(self):
        release = self.verify()
        self.updater.systemctl = mock.Mock()
        self.updater.service_active = mock.Mock(return_value=True)
        self.updater.local_coordinator_ready = mock.Mock(return_value=True)
        self.updater.local_gateway_ready = mock.Mock(return_value=True)
        self.updater.assert_effective_tier2_catalog_path = mock.Mock(
            side_effect=updater_module.UpdateError("effective tier2.catalog_path is not the release-bound current catalog path")
        )
        self.updater.wait_for = lambda _description, _timeout, check: self.assertTrue(check())

        with self.assertRaisesRegex(updater_module.UpdateError, "effective tier2.catalog_path"):
            self.updater.verify_rollout(release)

        self.updater.assert_effective_tier2_catalog_path.assert_called_once_with()
        self.assertEqual(
            self.updater.systemctl.call_args_list,
            [mock.call("start", "macprovider-coordinator.service")],
        )
        self.updater.local_gateway_ready.assert_not_called()

    def test_bridge_rollout_requires_capacity_and_safe_active_deadline(self):
        deadline = (
            updater_module.datetime.datetime.now(updater_module.datetime.timezone.utc)
            + updater_module.datetime.timedelta(hours=1)
        ).isoformat().replace("+00:00", "Z")
        coordinator = self.root / "coordinator.yaml"
        coordinator.write_text(
            "autotune:\n"
            "  enforce_provider_admission: false\n"
            f"  provider_admission_bridge_deadline: {deadline}\n"
        )
        self.updater.coordinator_runtime_state = updater_module.CoordinatorRuntime(
            coordinator, None, {}
        )
        self.updater.previous_pool_ready = 3
        self.updater.previous_protected_providers = ["provider-0", "provider-1", "provider-2"]
        self.updater.previous_protected_fleet = [
            {"provider_id": f"provider-{index}", "model_id": f"model-{index}"}
            for index in range(3)
        ]
        self.updater.get_json = mock.Mock(
            return_value={"pool_size": 3, "pool_ready": 3}
        )
        admitted_rows = [
            {
                "provider_id": f"provider-{index}",
                "model_id": f"model-{index}",
                "state": "ready",
                "routing_eligible": True,
                "catalog_admission_mode": "legacy_bridge",
            }
            for index in range(3)
        ]
        self.updater.coordinator_operator_token = mock.Mock(return_value="operator-token")
        self.updater.get_authorized_json = mock.Mock(return_value={"pool": admitted_rows})
        self.updater.audit = mock.Mock()

        self.updater.verify_provider_admission_rollout_policy()

        self.updater.audit.assert_called_once()
        _, outcome = self.updater.audit.call_args.args[:2]
        self.assertEqual(outcome, "success")
        self.assertEqual(self.updater.audit.call_args.kwargs["pool_ready"], 3)

        self.updater.get_authorized_json.return_value = {"pool": admitted_rows[:-1]}
        with self.assertRaisesRegex(updater_module.UpdateError, "protected provider lost"):
            self.updater.verify_provider_admission_rollout_policy()
        self.updater.get_authorized_json.return_value = {"pool": admitted_rows}
        self.updater.get_authorized_json.return_value = {
            "pool": [{**admitted_rows[0], "model_id": "drifted-model"}, *admitted_rows[1:]]
        }
        with self.assertRaisesRegex(updater_module.UpdateError, "protected provider lost"):
            self.updater.verify_provider_admission_rollout_policy()
        self.updater.get_authorized_json.return_value = {"pool": admitted_rows}

        self.updater.get_json.return_value = {"pool_size": 3, "pool_ready": 1}
        with self.assertRaisesRegex(updater_module.UpdateError, "fleet floor"):
            self.updater.verify_provider_admission_rollout_policy()

    def test_bridge_rollout_rejects_strict_enforcement_or_expiring_window(self):
        coordinator = self.root / "coordinator.yaml"
        coordinator.write_text(
            "autotune:\n"
            "  enforce_provider_admission: true\n"
            "  provider_admission_bridge_deadline: 2099-01-01T00:00:00Z\n"
        )
        self.updater.coordinator_runtime_state = updater_module.CoordinatorRuntime(
            coordinator, None, {}
        )
        self.updater.get_json = mock.Mock(
            return_value={"pool_size": 3, "pool_ready": 3}
        )
        with self.assertRaisesRegex(updater_module.UpdateError, "strict catalog admission"):
            self.updater.verify_provider_admission_rollout_policy()

        deadline = (
            updater_module.datetime.datetime.now(updater_module.datetime.timezone.utc)
            + updater_module.datetime.timedelta(hours=25)
        ).isoformat().replace("+00:00", "Z")
        coordinator.write_text(
            "autotune:\n"
            "  enforce_provider_admission: false\n"
            f"  provider_admission_bridge_deadline: {deadline}\n"
        )
        with self.assertRaisesRegex(updater_module.UpdateError, "24-hour"):
            self.updater.verify_provider_admission_rollout_policy()

        deadline = (
            updater_module.datetime.datetime.now(updater_module.datetime.timezone.utc)
            + updater_module.datetime.timedelta(seconds=330)
        ).isoformat().replace("+00:00", "Z")
        coordinator.write_text(
            "autotune:\n"
            "  enforce_provider_admission: false\n"
            f"  provider_admission_bridge_deadline: {deadline}\n"
        )
        with self.assertRaisesRegex(updater_module.UpdateError, "safe remaining window"):
            self.updater.verify_provider_admission_rollout_policy()

    def test_strict_post_migration_is_the_only_policy_that_accepts_enforcement(self):
        coordinator = self.root / "coordinator.yaml"
        coordinator.write_text("autotune:\n  enforce_provider_admission: true\n")
        self.updater.coordinator_runtime_state = updater_module.CoordinatorRuntime(
            coordinator, None, {}
        )
        self.updater.config = updater_module.dataclasses.replace(
            self.updater.config,
            provider_admission_policy="strict_post_migration",
            minimum_bridge_remaining_s=0,
        )
        self.updater.get_json = mock.Mock(
            return_value={"pool_size": 2, "pool_ready": 2}
        )
        self.updater.audit = mock.Mock()

        self.updater.verify_provider_admission_rollout_policy()

        coordinator.write_text("autotune:\n  enforce_provider_admission: false\n")
        with self.assertRaisesRegex(updater_module.UpdateError, "bridge is enabled"):
            self.updater.verify_provider_admission_rollout_policy()

    def test_bridge_configuration_window_exceeds_full_recovery_budget(self):
        self.updater.config = updater_module.dataclasses.replace(
            self.updater.config,
            minimum_bridge_remaining_s=(
                self.updater.config.provider_recovery_timeout_s
                + self.updater.config.service_health_timeout_s
            ),
        )
        with self.assertRaisesRegex(updater_module.UpdateError, "service-health windows"):
            self.updater.validate_provider_admission_policy_config()

    def test_catalog_admission_requires_exact_release_policy_and_feed_evidence(self):
        release = self.verify()
        manifest = json.loads((release.directory / "release.json").read_text(encoding="utf-8"))
        response = {
            "status": "live_verified",
            "release_id": release.catalog.release_id,
            "policy_version": release.catalog.policy_version,
            "feeds": {
                "autotune_candidates": {
                    "sha256": manifest["feeds"]["autotune-candidates.json"]["sha256"],
                    "signer_key_id": manifest["feeds"]["autotune-candidates.json"]["signer_key_id"],
                },
                "demand_rank": {
                    "sha256": manifest["feeds"]["demand-rank.json"]["sha256"],
                    "signer_key_id": manifest["feeds"]["demand-rank.json"]["signer_key_id"],
                },
                "rate_card": {
                    "sha256": manifest["feeds"]["rate-card.json"]["sha256"],
                    "signer_key_id": manifest["feeds"]["rate-card.json"]["signer_key_id"],
                },
            },
        }
        self.updater.get_json = mock.Mock(return_value=response)

        self.assertTrue(self.updater.catalog_admission_ready(release, "https://example.invalid/v1/autotune-release"))
        response["policy_version"] = "wrong-policy"
        self.assertFalse(self.updater.catalog_admission_ready(release, "https://example.invalid/v1/autotune-release"))

    def test_exact_catalog_admission_uses_the_local_buyer_listener(self):
        release = self.verify()
        self.updater.catalog_admission_ready = mock.Mock(return_value=True)
        self.updater.wait_for = lambda _description, _timeout, check: self.assertTrue(check())
        self.updater.audit = mock.Mock()

        self.updater.verify_exact_catalog_admission(release)

        self.assertEqual(
            self.updater.catalog_admission_ready.call_args_list,
            [
                mock.call(release, "http://127.0.0.1:8443/v1/autotune-release"),
                mock.call(release, "https://coordinator.streamvc.live/v1/autotune-release"),
            ],
        )

    def test_exact_provider_canary_matches_pool_envelope_to_independent_mac_row(self):
        release = self.verify()
        digest, signer = self.updater.catalog_candidate_identity(release)
        row_identity = "b" * 64
        response = {
            "provider_id": "catalog-canary",
            "assigned_id": "session-canary",
            "buyer_serving": True,
            "catalog_evidence_source": "provider_reported",
            "catalog_admission_mode": "current",
            "catalog_release_id": release.catalog.release_id,
            "catalog_policy_version": release.catalog.policy_version,
            "catalog_candidate_sha256": digest,
            "catalog_signer_key_id": signer,
            "catalog_row_identity": row_identity,
        }
        self.updater.get_authorized_json = mock.Mock(return_value=response)

        with mock.patch.object(updater_module.time, "monotonic", return_value=100.0):
            self.assertTrue(self.updater.catalog_provider_admission_ready(
                release,
                "catalog-canary",
                "t" * 32,
                digest,
                signer,
                row_identity,
                "session-canary",
                deadline=125.0,
            ))
        self.assertIn("assigned_id=session-canary", self.updater.get_authorized_json.call_args.args[0])
        self.assertEqual(self.updater.get_authorized_json.call_args.kwargs["timeout_s"], 25.0)
        response["assigned_id"] = "wrong-session"
        self.assertFalse(self.updater.catalog_provider_admission_ready(
            release,
            "catalog-canary",
            "t" * 32,
            digest,
            signer,
            row_identity,
            "session-canary",
        ))
        response["assigned_id"] = "session-canary"
        response["catalog_row_identity"] = "c" * 64
        self.assertFalse(self.updater.catalog_provider_admission_ready(
            release,
            "catalog-canary",
            "t" * 32,
            digest,
            signer,
            row_identity,
            "session-canary",
        ))

    def test_exact_provider_canary_mac_proof_is_pinned_and_matches_catalog_files(self):
        release = self.verify()
        digest, signer = self.updater.catalog_candidate_identity(release)
        row_identity = "b" * 64
        proof = {
            "provider_id": "catalog-canary",
            "assigned_id": "session-canary",
            "catalog_key": "llama-3.2-3b-instruct",
            "model_id": "mlx-community/Llama-3.2-3B-Instruct-4bit",
            "launchd_pid": 123,
            "local_status": {
                "provider_id": "catalog-canary",
                "network_state": "buyer_serving",
                "model": "llama-3.2-3b-instruct",
                "model_loaded": True,
                "coordinator": {"connected": True, "session": "session-canary"},
                "catalog": {
                    "release_id": release.catalog.release_id,
                    "policy_version": release.catalog.policy_version,
                    "digest": digest,
                    "signer_key_id": signer,
                    "row_identity": row_identity,
                    "catalog_key": "llama-3.2-3b-instruct",
                    "model_id": "mlx-community/Llama-3.2-3B-Instruct-4bit",
                },
            },
            "files": dict(release.catalog.files),
        }
        self.updater.config = updater_module.dataclasses.replace(
            self.updater.config,
            catalog_canary_ssh_target="operator@canary.example",
            catalog_canary_ssh_port=2222,
            catalog_canary_ssh_key_file=Path("/run/secrets/catalog-canary-ssh-key"),
            catalog_canary_known_hosts_file=Path("/etc/macprovider/catalog-canary-known-hosts"),
        )
        self.updater.run_command = mock.Mock(
            return_value=subprocess.CompletedProcess(
                ["ssh"], 0, stdout=json.dumps(proof), stderr=""
            )
        )

        with mock.patch.object(updater_module.time, "monotonic", return_value=100.0):
            self.assertEqual(
                self.updater.prove_catalog_canary_mac(
                    release,
                    "catalog-canary",
                    digest,
                    signer,
                    deadline=125.0,
                ),
                updater_module.CatalogCanaryEvidence(
                    row_identity=row_identity,
                    assigned_id="session-canary",
                    catalog_key="llama-3.2-3b-instruct",
                    model_id="mlx-community/Llama-3.2-3B-Instruct-4bit",
                ),
            )
        args, kwargs = self.updater.run_command.call_args
        self.assertIn(
            "UserKnownHostsFile=/etc/macprovider/catalog-canary-known-hosts",
            args[0],
        )
        self.assertIn("GlobalKnownHostsFile=/dev/null", args[0])
        self.assertIn("-F", args[0])
        self.assertIn("/dev/null", args[0])
        port_index = args[0].index("-p")
        self.assertEqual(args[0][port_index + 1], "2222")
        self.assertEqual(args[0][-2], "operator@canary.example")
        self.assertIn("catalog-canary", args[0][-1])
        self.assertIn("running_text_vnode", kwargs["input_text"])
        self.assertIn('local_status.get("model_loaded") is not True', kwargs["input_text"])
        self.assertIn("catalog_key != model_id", kwargs["input_text"])
        self.assertEqual(kwargs["timeout"], 25.0)

        proof["files"]["release.json"] = "0" * 64
        self.updater.run_command.return_value = subprocess.CompletedProcess(
            ["ssh"], 0, stdout=json.dumps(proof), stderr=""
        )
        with self.assertRaisesRegex(
            updater_module.UpdateError,
            "does not match the candidate release",
        ):
            self.updater.prove_catalog_canary_mac(
                release, "catalog-canary", digest, signer
            )

        proof["files"] = dict(release.catalog.files)
        invalid_model_proofs = {
            "runtime model missing": {"local_status.model": None},
            "runtime model not loaded": {"local_status.model_loaded": False},
            "catalog key mismatch": {"local_status.catalog.catalog_key": "different-key"},
            "catalog model ID missing": {"local_status.catalog.model_id": None},
            "emitted catalog key mismatch": {"catalog_key": "different-key"},
            "emitted model ID mismatch": {"model_id": "different-model"},
        }
        for label, mutations in invalid_model_proofs.items():
            with self.subTest(label=label):
                invalid_proof = json.loads(json.dumps(proof))
                for path, value in mutations.items():
                    target = invalid_proof
                    parts = path.split(".")
                    for part in parts[:-1]:
                        target = target[part]
                    target[parts[-1]] = value
                self.updater.run_command.return_value = subprocess.CompletedProcess(
                    ["ssh"], 0, stdout=json.dumps(invalid_proof), stderr=""
                )
                with self.assertRaisesRegex(
                    updater_module.UpdateError,
                    "does not match the candidate release",
                ):
                    self.updater.prove_catalog_canary_mac(
                        release, "catalog-canary", digest, signer
                    )

    def test_exact_provider_canary_runs_mac_proof_before_authoritative_pool_gate(self):
        release = self.verify()
        token = self.root / "catalog-token"
        key = self.root / "catalog-ssh-key"
        known_hosts = self.root / "catalog-known-hosts"
        token.write_text("t" * 32 + "\n")
        key.write_text("private-key\n")
        known_hosts.write_text("canary.example ssh-ed25519 AAAATEST\n")
        token.chmod(0o600)
        key.chmod(0o600)
        known_hosts.chmod(0o600)
        self.updater.config = updater_module.dataclasses.replace(
            self.updater.config,
            catalog_canary_provider_id="catalog-canary",
            catalog_canary_auth_token_file=token,
            catalog_canary_ssh_target="operator@canary.example",
            catalog_canary_ssh_key_file=key,
            catalog_canary_known_hosts_file=known_hosts,
        )
        self.updater.coordinator_operator_token = mock.Mock(return_value="t" * 32)
        order = []
        self.updater.prove_catalog_canary_mac = mock.Mock(
            side_effect=lambda *_args, **_kwargs: order.append("mac")
            or updater_module.CatalogCanaryEvidence(
                row_identity="b" * 64,
                assigned_id="session-canary",
                catalog_key="llama-3.2-3b-instruct",
                model_id="mlx-community/Llama-3.2-3B-Instruct-4bit",
            )
        )
        self.updater.catalog_provider_admission_ready = mock.Mock(
            side_effect=lambda *_args, **_kwargs: order.append("pool") or True
        )
        self.updater.wait_for_with_deadline = (
            lambda _description, timeout, check: self.assertTrue(
                check(updater_module.time.monotonic() + timeout)
            )
        )

        self.assertEqual(
            self.updater.verify_exact_provider_canary(release),
            updater_module.CatalogCanaryEvidence(
                row_identity="b" * 64,
                assigned_id="session-canary",
                catalog_key="llama-3.2-3b-instruct",
                model_id="mlx-community/Llama-3.2-3B-Instruct-4bit",
            ),
        )

        self.assertEqual(order, ["mac", "pool"])

    def test_exact_provider_canary_requires_operator_key_token(self):
        release = self.verify()
        token = self.root / "catalog-token"
        key = self.root / "catalog-ssh-key"
        known_hosts = self.root / "catalog-known-hosts"
        token.write_text("s" * 32 + "\n")
        key.write_text("private-key\n")
        known_hosts.write_text("canary.example ssh-ed25519 AAAATEST\n")
        token.chmod(0o600)
        key.chmod(0o600)
        known_hosts.chmod(0o600)
        self.updater.config = updater_module.dataclasses.replace(
            self.updater.config,
            catalog_canary_provider_id="catalog-canary",
            catalog_canary_auth_token_file=token,
            catalog_canary_ssh_target="operator@canary.example",
            catalog_canary_ssh_key_file=key,
            catalog_canary_known_hosts_file=known_hosts,
        )
        self.updater.coordinator_operator_token = mock.Mock(return_value="o" * 32)
        self.updater.prove_catalog_canary_mac = mock.Mock()

        with self.assertRaisesRegex(updater_module.UpdateError, "must be the coordinator operator key"):
            self.updater.verify_exact_provider_canary(release)
        self.updater.prove_catalog_canary_mac.assert_not_called()

    def test_exact_provider_canary_retries_full_proof_and_session_bound_admission(self):
        release = self.verify()
        token = self.root / "catalog-token"
        key = self.root / "catalog-ssh-key"
        known_hosts = self.root / "catalog-known-hosts"
        token.write_text("t" * 32 + "\n")
        key.write_text("private-key\n")
        known_hosts.write_text("canary.example ssh-ed25519 AAAATEST\n")
        token.chmod(0o600)
        key.chmod(0o600)
        known_hosts.chmod(0o600)
        self.updater.config = updater_module.dataclasses.replace(
            self.updater.config,
            provider_recovery_timeout_s=10,
            catalog_canary_provider_id="catalog-canary",
            catalog_canary_auth_token_file=token,
            catalog_canary_ssh_target="operator@canary.example",
            catalog_canary_ssh_key_file=key,
            catalog_canary_known_hosts_file=known_hosts,
        )
        self.updater.coordinator_operator_token = mock.Mock(return_value="t" * 32)
        row_identity = "b" * 64
        self.updater.prove_catalog_canary_mac = mock.Mock(
            side_effect=[
                updater_module.UpdateError("provider not installed yet"),
                updater_module.CatalogCanaryEvidence(
                    row_identity=row_identity,
                    assigned_id="session-before-reconnect",
                    catalog_key="llama-3.2-3b-instruct",
                    model_id="mlx-community/Llama-3.2-3B-Instruct-4bit",
                ),
                updater_module.CatalogCanaryEvidence(
                    row_identity=row_identity,
                    assigned_id="session-after-reconnect",
                    catalog_key="llama-3.2-3b-instruct",
                    model_id="mlx-community/Llama-3.2-3B-Instruct-4bit",
                ),
            ]
        )
        self.updater.catalog_provider_admission_ready = mock.Mock(
            side_effect=[False, True]
        )
        self.updater.sleep = mock.Mock()
        self.updater.audit = mock.Mock()

        self.updater.verify_exact_provider_canary(release)

        self.assertEqual(self.updater.prove_catalog_canary_mac.call_count, 3)
        assigned_ids = [
            call.args[-1]
            for call in self.updater.catalog_provider_admission_ready.call_args_list
        ]
        self.assertEqual(
            assigned_ids,
            ["session-before-reconnect", "session-after-reconnect"],
        )
        self.updater.audit.assert_any_call(
            "exact_catalog_provider_canary",
            "success",
            provider_id="catalog-canary",
            catalog_release_id=release.catalog.release_id,
            catalog_policy_version=release.catalog.policy_version,
            catalog_candidate_sha256=self.updater.catalog_candidate_identity(release)[0],
            catalog_signer_key_id=self.updater.catalog_candidate_identity(release)[1],
            catalog_row_identity=row_identity,
            assigned_id="session-after-reconnect",
            catalog_key="llama-3.2-3b-instruct",
            model="mlx-community/Llama-3.2-3B-Instruct-4bit",
        )

    def test_gateway_buyer_stream_requires_provider_model_token_done_and_request_id(self):
        token = self.root / "buyer-token"
        token.write_text("buyer-token-value\n")
        token.chmod(0o600)
        opener, opener_patch = self.buyer_proof_opener(
            lambda request: self.BuyerProofResponse(
                request_id=request.get_header("X-request-id"),
            )
        )

        with (
            mock.patch.object(updater_module, "CANARY_BUYER_TOKEN", token),
            opener_patch,
        ):
            proof = self.updater.prove_gateway_buyer_stream(
                cycle=1,
                provider_id="catalog-canary",
                model_id="mlx-community/Llama-3.2-3B-Instruct-4bit",
            )

        request = opener.requests[0]
        self.assertEqual(request.full_url, "https://api.streamvc.live/v1/chat/completions")
        self.assertEqual(request.get_header("Authorization"), "Bearer buyer-token-value")
        self.assertEqual(request.get_header("Accept"), "text/event-stream")
        payload = json.loads(request.data)
        self.assertTrue(payload["stream"])
        self.assertEqual(payload["model"], "mlx-community/Llama-3.2-3B-Instruct-4bit")
        self.assertEqual(payload["messages"][0]["role"], "user")
        self.assertIn("cycle 1", payload["messages"][0]["content"])
        request_uuid = uuid.UUID(request.get_header("X-request-id"))
        self.assertEqual(request_uuid.version, 4)
        self.assertIsNone(request.get_header("X-macprovider-proof-cycle"))
        self.assertIsNone(request.get_header("X-macprovider-proof-timestamp"))
        self.assertEqual(proof["request_id"], str(request_uuid))
        self.assertEqual(proof["response_request_id"], str(request_uuid))
        self.assertEqual(proof["provider_id"], "catalog-canary")

    def test_gateway_buyer_stream_rejects_wrong_provider_or_missing_done(self):
        token = self.root / "buyer-token"
        token.write_text("buyer-token-value\n")
        token.chmod(0o600)
        wrong_provider_opener, wrong_provider_patch = self.buyer_proof_opener(
            lambda request: self.BuyerProofResponse(
                request_id=request.get_header("X-request-id"),
                provider_id="other-provider",
                lines=[],
            )
        )
        missing_done_opener, missing_done_patch = self.buyer_proof_opener(
            lambda request: self.BuyerProofResponse(
                request_id=request.get_header("X-request-id"),
                lines=[
                    b'data: {"model":"mlx-community/Llama-3.2-3B-Instruct-4bit","choices":[{"delta":{"content":"ok"}}]}\n\n',
                ],
            )
        )

        with (
            mock.patch.object(updater_module, "CANARY_BUYER_TOKEN", token),
            wrong_provider_patch,
        ):
            with self.assertRaisesRegex(updater_module.UpdateError, "X-Provider-Id"):
                self.updater.prove_gateway_buyer_stream(
                    cycle=1,
                    provider_id="catalog-canary",
                    model_id="mlx-community/Llama-3.2-3B-Instruct-4bit",
                )
        with (
            mock.patch.object(updater_module, "CANARY_BUYER_TOKEN", token),
            missing_done_patch,
        ):
            with self.assertRaisesRegex(updater_module.UpdateError, "did not terminate"):
                self.updater.prove_gateway_buyer_stream(
                    cycle=1,
                    provider_id="catalog-canary",
                    model_id="mlx-community/Llama-3.2-3B-Instruct-4bit",
                )
        self.assertEqual(len(wrong_provider_opener.requests), 1)
        self.assertEqual(len(missing_done_opener.requests), 1)

    def test_gateway_buyer_stream_rejects_mismatched_request_id(self):
        token = self.root / "buyer-token"
        token.write_text("buyer-token-value\n")
        token.chmod(0o600)
        opener, opener_patch = self.buyer_proof_opener(
            lambda _request: self.BuyerProofResponse(
                request_id="other-request",
                lines=[],
            )
        )

        with (
            mock.patch.object(updater_module, "CANARY_BUYER_TOKEN", token),
            opener_patch,
        ):
            with self.assertRaisesRegex(updater_module.UpdateError, "did not echo X-Request-Id"):
                self.updater.prove_gateway_buyer_stream(
                    cycle=1,
                    provider_id="catalog-canary",
                    model_id="mlx-community/Llama-3.2-3B-Instruct-4bit",
                )
        self.assertEqual(len(opener.requests), 1)

    def test_gateway_buyer_stream_rejects_redirect_non_200_and_oversized_streams(self):
        token = self.root / "buyer-token"
        token.write_text("buyer-token-value\n")
        token.chmod(0o600)

        cases = [
            (
                lambda request: self.BuyerProofResponse(
                    request_id=request.get_header("X-request-id"),
                    url="https://api.streamvc.live/redirected",
                ),
                "exact HTTP 200",
            ),
            (
                lambda request: self.BuyerProofResponse(
                    request_id=request.get_header("X-request-id"),
                    status=500,
                ),
                "exact HTTP 200",
            ),
            (
                lambda request: self.BuyerProofResponse(
                    request_id=request.get_header("X-request-id"),
                    lines=[b"x" * (updater_module.MAX_BUYER_PROOF_STREAM_LINE_BYTES + 1)],
                ),
                "stream line exceeds",
            ),
            (
                lambda request: self.BuyerProofResponse(
                    request_id=request.get_header("X-request-id"),
                    lines=[b":" + (b"x" * (updater_module.MAX_BUYER_PROOF_STREAM_LINE_BYTES - 2)) + b"\n"]
                    * ((updater_module.MAX_BUYER_PROOF_STREAM_BYTES // updater_module.MAX_BUYER_PROOF_STREAM_LINE_BYTES) + 1),
                ),
                "stream exceeds",
            ),
        ]
        for response_factory, message in cases:
            opener, opener_patch = self.buyer_proof_opener(response_factory)
            with (
                self.subTest(message=message),
                mock.patch.object(updater_module, "CANARY_BUYER_TOKEN", token),
                opener_patch,
            ):
                with self.assertRaisesRegex(updater_module.UpdateError, message):
                    self.updater.prove_gateway_buyer_stream(
                        cycle=1,
                        provider_id="catalog-canary",
                        model_id="mlx-community/Llama-3.2-3B-Instruct-4bit",
                    )
            self.assertEqual(len(opener.requests), 1)

    def test_gateway_buyer_stream_rejects_oversized_unterminated_line_with_bounded_read(self):
        token = self.root / "buyer-token"
        token.write_text("buyer-token-value\n")
        token.chmod(0o600)
        responses = []

        def response_factory(request):
            response = self.BuyerProofResponse(
                request_id=request.get_header("X-request-id"),
                lines=[b"x" * (updater_module.MAX_BUYER_PROOF_STREAM_LINE_BYTES + 100)],
            )
            responses.append(response)
            return response

        opener, opener_patch = self.buyer_proof_opener(response_factory)
        with (
            mock.patch.object(updater_module, "CANARY_BUYER_TOKEN", token),
            opener_patch,
        ):
            with self.assertRaisesRegex(updater_module.UpdateError, "stream line exceeds"):
                self.updater.prove_gateway_buyer_stream(
                    cycle=1,
                    provider_id="catalog-canary",
                    model_id="mlx-community/Llama-3.2-3B-Instruct-4bit",
                )

        self.assertEqual(len(opener.requests), 1)
        self.assertEqual(
            responses[0].readline_limits,
            [updater_module.MAX_BUYER_PROOF_STREAM_LINE_BYTES + 1],
        )

    def test_gateway_buyer_stream_rejects_elapsed_deadline(self):
        token = self.root / "buyer-token"
        token.write_text("buyer-token-value\n")
        token.chmod(0o600)

        class TimeoutResponse(self.BuyerProofResponse):
            def readline(self, limit=-1):
                self.readline_limits.append(limit)
                raise TimeoutError("alarm")

        opener, opener_patch = self.buyer_proof_opener(
            lambda request: TimeoutResponse(
                request_id=request.get_header("X-request-id"),
            )
        )
        self.updater.config = updater_module.dataclasses.replace(
            self.updater.config,
            request_timeout_s=5,
        )
        with (
            mock.patch.object(updater_module, "CANARY_BUYER_TOKEN", token),
            opener_patch,
        ):
            with self.assertRaisesRegex(updater_module.UpdateError, "elapsed-time limit"):
                self.updater.prove_gateway_buyer_stream(
                    cycle=1,
                    provider_id="catalog-canary",
                    model_id="mlx-community/Llama-3.2-3B-Instruct-4bit",
                )
        self.assertEqual(opener.timeouts, [5])

    def test_gateway_buyer_stream_uses_no_proxy_no_redirect_opener(self):
        token = self.root / "buyer-token"
        token.write_text("buyer-token-value\n")
        token.chmod(0o600)
        opener = self.BuyerProofOpener(
            lambda request: self.BuyerProofResponse(
                request_id=request.get_header("X-request-id"),
            )
        )
        with (
            mock.patch.object(updater_module, "CANARY_BUYER_TOKEN", token),
            mock.patch.object(updater_module.urllib.request, "build_opener", return_value=opener) as build_opener,
        ):
            self.updater.prove_gateway_buyer_stream(
                cycle=1,
                provider_id="catalog-canary",
                model_id="mlx-community/Llama-3.2-3B-Instruct-4bit",
            )

        handlers = build_opener.call_args.args
        self.assertEqual(handlers[0].proxies, {})
        self.assertIsInstance(handlers[1], updater_module.NoRedirect)

    def test_live_runtime_binding_checks_processes_after_config_and_catalog_publication(self):
        release = self.stage(self.verify())
        self.install_coherent_pair(release)
        config = self.root / "coordinator.yaml"
        config.write_text(
            "tier2:\n"
            f"  catalog_path: {self.updater.install_root}/autotune/current/tier2-catalog.json\n"
            "  require_hash_verified: false\n"
        )
        gateway_config = self.root / "gateway.yaml"
        gateway_config.write_text("gateway: config\n")
        self.updater.coordinator_runtime = mock.Mock(
            return_value=updater_module.CoordinatorRuntime(config, None, {})
        )
        self.updater.gateway_config_path = mock.Mock(return_value=gateway_config)
        self.updater.local_coordinator_identity_ready = mock.Mock(return_value=True)
        self.updater.local_gateway_identity_ready = mock.Mock(return_value=True)
        now = time.time_ns()
        os.utime(config, ns=(now, now))
        os.utime(gateway_config, ns=(now + 5, now + 5))
        os.utime(self.updater.install_root / "autotune" / "current", ns=(now + 10, now + 10), follow_symlinks=False)
        self.updater._prove_live_service_binary = mock.Mock(
            side_effect=[
                {"pid": 101, "inode": 201},
                {"pid": 102, "inode": 202},
            ]
        )
        self.updater.audit = mock.Mock()

        self.updater.verify_live_runtime_binding(release)

        min_start_after_ns = max(
            config.lstat().st_mtime_ns,
            gateway_config.lstat().st_mtime_ns,
            (self.updater.install_root / "autotune" / "current").lstat().st_mtime_ns,
        )
        self.assertEqual(
            self.updater._prove_live_service_binary.call_args_list,
            [
                mock.call(
                    "macprovider-coordinator.service",
                    self.updater.install_root / "coordinator",
                    release.coordinator.sha256,
                    release.tag,
                    min_start_after_ns,
                ),
                mock.call(
                    "macprovider-gateway.service",
                    self.updater.install_root / "gateway",
                    release.gateway.sha256,
                    release.tag,
                    min_start_after_ns,
                ),
            ],
        )
        self.updater.audit.assert_called_once()
        self.assertEqual(self.updater.audit.call_args.args[:2], ("live_runtime_binding", "success"))

        config.write_text(
            "tier2:\n"
            f"  catalog_path: {self.updater.install_root}/autotune/current/tier2-catalog.json\n"
            "  require_hash_verified: true\n"
        )
        self.updater._prove_live_service_binary.reset_mock(
            side_effect=True,
            return_value=True,
        )
        self.updater._prove_live_service_binary.side_effect = [
            {"pid": 101, "inode": 201},
            {"pid": 102, "inode": 202},
        ]
        self.updater.audit.reset_mock()

        self.updater.verify_live_sighup_binding(release, "true")

        self.assertEqual(
            self.updater._prove_live_service_binary.call_args_list,
            [
                mock.call(
                    "macprovider-coordinator.service",
                    self.updater.install_root / "coordinator",
                    release.coordinator.sha256,
                    release.tag,
                    None,
                ),
                mock.call(
                    "macprovider-gateway.service",
                    self.updater.install_root / "gateway",
                    release.gateway.sha256,
                    release.tag,
                    None,
                ),
            ],
        )
        self.assertEqual(
            self.updater.audit.call_args.args[:2],
            ("live_sighup_binding", "success"),
        )

    def test_live_service_binary_rejects_malformed_or_stale_systemd_start_timestamp(self):
        binary = self.updater.install_root / "coordinator"
        binary.parent.mkdir(parents=True, exist_ok=True)
        binary.write_text("binary\n")
        binary.chmod(0o755)
        self.updater.run_command = mock.Mock()

        self.updater._service_properties = mock.Mock(
            return_value={
                "MainPID": "123",
                "ExecMainStartTimestampMonotonic": "not-an-int",
            }
        )
        with self.assertRaisesRegex(updater_module.UpdateError, "ExecMainStartTimestampMonotonic is invalid"):
            self.updater._prove_live_service_binary(
                "macprovider-coordinator.service",
                binary,
                "a" * 64,
                "1.8.60",
                1_000_000_000,
            )

        self.updater._service_properties = mock.Mock(
            return_value={
                "MainPID": "123",
                "ExecMainStartTimestampMonotonic": "2000000",
            }
        )
        with (
            mock.patch.object(updater_module.time, "time_ns", return_value=1_000_000_000),
            mock.patch.object(updater_module.time, "monotonic_ns", return_value=2_000_000_000),
        ):
            with self.assertRaisesRegex(updater_module.UpdateError, "did not start after"):
                self.updater._prove_live_service_binary(
                    "macprovider-coordinator.service",
                    binary,
                    "a" * 64,
                    "1.8.60",
                    1_000_500_000,
                )
        self.updater.run_command.assert_not_called()

    def test_exact_provider_canary_cannot_cross_the_outer_handoff_deadline(self):
        release = self.verify()
        self.updater.config = updater_module.dataclasses.replace(
            self.updater.config,
            provider_recovery_timeout_s=900,
        )
        self.updater.validate_catalog_canary_configuration = mock.Mock(
            return_value=("catalog-canary", "t" * 32)
        )
        clock = [1_000.0]
        attempt_budgets: list[float] = []

        def unavailable_mac_proof(*_args, deadline: float):
            remaining_s = deadline - clock[0]
            attempt_budgets.append(remaining_s)
            clock[0] += min(300.0, remaining_s)
            raise updater_module.UpdateError("provider not installed yet")

        self.updater.prove_catalog_canary_mac = mock.Mock(
            side_effect=unavailable_mac_proof
        )
        self.updater.catalog_provider_admission_ready = mock.Mock()
        self.updater.sleep = lambda seconds: clock.__setitem__(0, clock[0] + seconds)
        self.updater.audit = mock.Mock()

        with mock.patch.object(
            updater_module.time,
            "monotonic",
            side_effect=lambda: clock[0],
        ):
            with self.assertRaisesRegex(
                updater_module.UpdateError,
                "timeout waiting for exact catalog-aware provider proof and admission",
            ):
                self.updater.verify_exact_provider_canary(release)

        self.assertLessEqual(clock[0] - 1_000.0, 900.0)
        self.assertEqual(attempt_budgets, [900.0, 598.0, 296.0])
        self.updater.catalog_provider_admission_ready.assert_not_called()

    def test_deadline_wait_rejects_success_completed_after_expiry(self):
        clock = [100.0]

        def late_success(deadline: float) -> bool:
            clock[0] = deadline + 1.0
            return True

        self.updater.audit = mock.Mock()
        with mock.patch.object(
            updater_module.time,
            "monotonic",
            side_effect=lambda: clock[0],
        ):
            with self.assertRaisesRegex(
                updater_module.UpdateError,
                "completed after its deadline",
            ):
                self.updater.wait_for_with_deadline("late success", 10, late_success)

        self.updater.audit.assert_any_call(
            "rollout_check",
            "failed",
            check="late success",
            reason="late success completed after its deadline",
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

    def test_serving_proof_disabled_mode_preserves_recovery_gates_without_running_canary(self):
        identity = updater_module.RuntimeIdentity("v1.8.60", "v1.8.60", "1.8.60")
        self.updater.config = updater_module.dataclasses.replace(
            self.updater.config,
            buyer_canary_mode=updater_module.BUYER_CANARY_MODE_DISABLED,
        )
        self.updater.previous_protected_providers = ["provider-a", "provider-b"]
        self.updater.local_coordinator_identity_ready = mock.Mock(return_value=True)
        self.updater.gateway_serving_ready = mock.Mock(return_value=True)
        self.updater.public_identity_ready = mock.Mock(return_value=True)
        self.updater.protected_provider_fleet_ready = mock.Mock(return_value=True)
        self.updater.verify_disabled_buyer_canary_posture = mock.Mock()
        self.updater.run_canary_gate = mock.Mock()
        self.updater.audit = mock.Mock()

        self.updater.prove_serving_recovery(identity)

        self.assertEqual(self.updater.protected_provider_fleet_ready.call_count, 3)
        self.updater.verify_disabled_buyer_canary_posture.assert_called_once_with()
        self.updater.run_canary_gate.assert_not_called()
        self.updater.audit.assert_any_call(
            "buyer_canary_gate",
            "skipped",
            mode=updater_module.BUYER_CANARY_MODE_DISABLED,
            replacement_gates=(
                "public_identity,"
                "stable_protected_fleet,"
                "exact_catalog_admission,"
                "exact_provider_canary"
            ),
        )

    def test_rollback_serving_proof_relaxes_baseline_only_with_required_canary(self):
        identity = updater_module.RuntimeIdentity("v1.8.30", "v1.8.30", "1.8.30")
        self.updater.previous_protected_providers = ["provider-a", "provider-b"]
        self.updater.local_coordinator_identity_ready = mock.Mock(return_value=True)
        self.updater.gateway_serving_ready = mock.Mock(return_value=True)
        self.updater.public_identity_ready = mock.Mock(return_value=True)
        self.updater.protected_provider_fleet_ready = mock.Mock(return_value=True)
        self.updater.run_canary_gate = mock.Mock()

        def wait_until_success(_description, _timeout, check):
            for _ in range(4):
                if check():
                    return
            self.fail("wait_for check did not succeed")

        self.updater.wait_for = wait_until_success

        self.updater.prove_serving_recovery(identity, legacy_rollback_version="1.8.30")

        self.assertEqual(
            self.updater.protected_provider_fleet_ready.call_args_list,
            [mock.call(require_previous_baseline=False)] * 3,
        )
        self.updater.run_canary_gate.assert_called_once_with(
            legacy_rollback_version="1.8.30"
        )

    def test_disabled_rollback_serving_proof_keeps_exact_baseline(self):
        identity = updater_module.RuntimeIdentity("v1.8.30", "v1.8.30", "1.8.30")
        self.updater.config = updater_module.dataclasses.replace(
            self.updater.config,
            buyer_canary_mode=updater_module.BUYER_CANARY_MODE_DISABLED,
        )
        self.updater.previous_protected_providers = ["provider-a", "provider-b"]
        self.updater.local_coordinator_identity_ready = mock.Mock(return_value=True)
        self.updater.gateway_serving_ready = mock.Mock(return_value=True)
        self.updater.public_identity_ready = mock.Mock(return_value=True)
        self.updater.protected_provider_fleet_ready = mock.Mock(return_value=True)
        self.updater.verify_disabled_buyer_canary_posture = mock.Mock()
        self.updater.run_canary_gate = mock.Mock()
        self.updater.audit = mock.Mock()

        def wait_until_success(_description, _timeout, check):
            for _ in range(4):
                if check():
                    return
            self.fail("wait_for check did not succeed")

        self.updater.wait_for = wait_until_success

        self.updater.prove_serving_recovery(identity, legacy_rollback_version="1.8.30")

        self.assertEqual(
            self.updater.protected_provider_fleet_ready.call_args_list,
            [mock.call(require_previous_baseline=True)] * 3,
        )
        self.updater.verify_disabled_buyer_canary_posture.assert_called_once_with()
        self.updater.run_canary_gate.assert_not_called()

    def test_runtime_only_rollout_requires_buyer_canary_mode(self):
        self.make_bundle(runtime_only=True)
        release = self.verify()
        self.updater.config = updater_module.dataclasses.replace(
            self.updater.config,
            buyer_canary_mode=updater_module.BUYER_CANARY_MODE_DISABLED,
        )

        with self.assertRaisesRegex(updater_module.UpdateError, "runtime-only Pearl release requires buyer canary"):
            self.updater.verify_rollout(release)

    def test_runtime_only_apply_rejects_disabled_canary_before_journal_or_mutation(self):
        self.make_bundle(runtime_only=True)
        release = self.verify()
        self.updater.config = updater_module.dataclasses.replace(
            self.updater.config,
            buyer_canary_mode=updater_module.BUYER_CANARY_MODE_DISABLED,
        )
        self.updater.audit = mock.Mock()
        self.updater._start_journal = mock.Mock()
        self.updater.stop_for_rollout = mock.Mock()
        self.updater.install_release = mock.Mock()

        with self.assertRaisesRegex(updater_module.UpdateError, "runtime-only Pearl release requires buyer canary"):
            self.updater.apply(release, updater_module.SemVer.parse("1.8.26"))

        self.updater.audit.assert_not_called()
        self.updater._start_journal.assert_not_called()
        self.updater.stop_for_rollout.assert_not_called()
        self.updater.install_release.assert_not_called()

    def test_run_canary_gate_rejects_disabled_mode(self):
        self.updater.config = updater_module.dataclasses.replace(
            self.updater.config,
            buyer_canary_mode=updater_module.BUYER_CANARY_MODE_DISABLED,
        )
        with self.assertRaisesRegex(updater_module.UpdateError, "outside required mode"):
            self.updater.run_canary_gate()

    def test_transaction_rollback_serving_proof_authorizes_exact_prior_version(self):
        transaction = self.root / "rollback-serving-transaction"
        transaction.mkdir()
        (transaction / "previous-runtime.json").write_text(
            json.dumps(
                {
                    "coordinator_version": "v1.8.30",
                    "gateway_version": "v1.8.30",
                    "advertised_version": "1.8.30",
                }
            )
            + "\n"
        )
        (transaction / "previous-runtime.json").chmod(0o600)
        self.updater.prove_serving_recovery = mock.Mock()

        self.updater._prove_rollback_serving(transaction)

        identity = updater_module.RuntimeIdentity("v1.8.30", "v1.8.30", "1.8.30")
        self.updater.prove_serving_recovery.assert_called_once_with(
            identity,
            legacy_rollback_version="1.8.30",
        )

    def test_serving_proof_requires_three_consecutive_public_fleet_samples(self):
        identity = updater_module.RuntimeIdentity("v1.8.36", "v1.8.36", "1.8.36")
        self.updater.previous_pool_ready = 2
        self.updater.previous_protected_providers = ["provider-a", "provider-b"]
        self.updater.previous_protected_fleet = [
            {"provider_id": "provider-a", "model_id": "model-a"},
            {"provider_id": "provider-b", "model_id": "model-b"},
        ]
        self.updater.local_coordinator_identity_ready = mock.Mock(return_value=True)
        self.updater.gateway_serving_ready = mock.Mock(return_value=True)
        self.updater.public_identity_ready = mock.Mock(return_value=True)
        self.updater.protected_provider_fleet_ready = mock.Mock(
            side_effect=[True, True, False, True, True, True]
        )
        self.updater.run_canary_gate = mock.Mock()

        self.updater.prove_serving_recovery(identity)

        self.assertEqual(self.updater.protected_provider_fleet_ready.call_count, 6)
        self.updater.run_canary_gate.assert_called_once_with()

    def test_serving_proof_resets_consecutive_samples_after_sample_error(self):
        identity = updater_module.RuntimeIdentity("v1.8.36", "v1.8.36", "1.8.36")
        self.updater.previous_pool_ready = 2
        self.updater.previous_protected_providers = ["provider-a", "provider-b"]
        self.updater.local_coordinator_identity_ready = mock.Mock(return_value=True)
        self.updater.gateway_serving_ready = mock.Mock(return_value=True)
        self.updater.public_identity_ready = mock.Mock(return_value=True)
        self.updater.protected_provider_fleet_ready = mock.Mock(
            side_effect=[
                True,
                True,
                updater_module.UpdateError("transient public sample failure"),
                True,
                True,
                True,
            ]
        )
        self.updater.run_canary_gate = mock.Mock()

        self.updater.prove_serving_recovery(identity)

        self.assertEqual(self.updater.protected_provider_fleet_ready.call_count, 6)
        self.updater.run_canary_gate.assert_called_once_with()

    def test_public_protected_fleet_sample_requires_exact_ready_baseline(self):
        self.updater.previous_pool_ready = 2
        self.updater.previous_protected_providers = ["provider-a", "provider-b"]
        self.updater.previous_protected_fleet = [
            {"provider_id": "provider-a", "model_id": "model-a"},
            {"provider_id": "provider-b", "model_id": "model-b"},
        ]
        self.updater.coordinator_operator_token = mock.Mock(return_value="operator-token")
        rows = [
            {
                "provider_id": row["provider_id"],
                "model_id": row["model_id"],
                "state": "ready",
                "routing_eligible": True,
            }
            for row in self.updater.previous_protected_fleet
        ]
        self.updater.get_authorized_json = mock.Mock(
            return_value={"summary": {"ready": 2}, "pool": rows}
        )

        self.assertTrue(self.updater.protected_provider_fleet_ready())
        self.updater.get_authorized_json.assert_called_once_with(
            "https://coordinator.streamvc.live/poolz",
            "operator-token",
        )

        self.updater.get_authorized_json.return_value = {
            "summary": {"ready": 1},
            "pool": rows,
        }
        self.assertFalse(self.updater.protected_provider_fleet_ready())
        self.updater.get_authorized_json.return_value = {
            "summary": {"ready": 2},
            "pool": [{**rows[0], "routing_eligible": False}, rows[1]],
        }
        self.assertFalse(self.updater.protected_provider_fleet_ready())
        self.updater.get_authorized_json.return_value = {
            "summary": {"ready": 2},
            "pool": [{**rows[0], "model_id": "drifted-model"}, rows[1]],
        }
        self.assertFalse(self.updater.protected_provider_fleet_ready())

    def test_public_protected_fleet_sample_relaxes_stale_baseline_for_rollback(self):
        self.updater.previous_pool_ready = 5
        self.updater.previous_protected_providers = [
            "provider-a",
            "provider-b",
            "provider-c",
            "provider-d",
            "provider-e",
        ]
        self.updater.previous_protected_fleet = [
            {"provider_id": provider_id, "model_id": f"model-{suffix}"}
            for provider_id, suffix in zip(
                self.updater.previous_protected_providers,
                ("a", "b", "c", "d", "e"),
            )
        ]
        self.updater.coordinator_operator_token = mock.Mock(return_value="operator-token")
        rows = [
            {
                "provider_id": f"provider-{suffix}",
                "model_id": f"model-{suffix}",
                "state": "ready",
                "routing_eligible": True,
            }
            for suffix in ("a", "b", "c", "d")
        ]
        self.updater.get_authorized_json = mock.Mock(
            return_value={"summary": {"ready": 4}, "pool": rows}
        )

        self.assertFalse(self.updater.protected_provider_fleet_ready())
        self.assertTrue(
            self.updater.protected_provider_fleet_ready(require_previous_baseline=False)
        )

        self.updater.get_authorized_json.return_value = {
            "summary": {"ready": 0},
            "pool": rows,
        }
        self.assertFalse(
            self.updater.protected_provider_fleet_ready(require_previous_baseline=False)
        )
        self.updater.get_authorized_json.return_value = {
            "summary": {"ready": 4},
            "pool": [{**rows[0], "routing_eligible": False}, *rows[1:]],
        }
        self.assertFalse(
            self.updater.protected_provider_fleet_ready(require_previous_baseline=False)
        )

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
        self.updater.verify_buyer_canary_rollout_posture = mock.Mock()
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
        self.updater.verify_canary_authority = mock.Mock()
        self.updater.verify_canary_rollout_readiness = mock.Mock()
        self.updater.run_command = mock.Mock(
            side_effect=[
                updater_module.CommandTimeout("deadline"),
                subprocess.CompletedProcess(["systemctl", "stop"], 0, stdout="", stderr=""),
                subprocess.CompletedProcess(
                    ["systemctl", "show"],
                    0,
                    stdout="ActiveState=inactive\nSubState=dead\nJob=\n",
                    stderr="",
                ),
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
                    [
                        "systemctl",
                        "show",
                        "--property=ActiveState",
                        "--property=SubState",
                        "--property=Job",
                        "canary-buyer.service",
                    ],
                    check=False,
                    timeout=10,
                ),
            ],
        )

    def test_canary_nonzero_start_is_stopped_and_proven_quiescent(self):
        self.updater.verify_canary_authority = mock.Mock()
        self.updater.verify_canary_rollout_readiness = mock.Mock()
        self.updater._journal_transition = mock.Mock()
        self.updater.assert_unit_quiescent = mock.Mock()
        self.updater.run_command = mock.Mock(
            side_effect=[
                subprocess.CompletedProcess(
                    ["systemctl", "start"], 1, stdout="", stderr="buyer proof failed"
                ),
                subprocess.CompletedProcess(["systemctl", "stop"], 0, stdout="", stderr=""),
            ]
        )

        with self.assertRaisesRegex(updater_module.UpdateError, "buyer proof failed"):
            self.updater.run_canary_gate()

        self.updater.assert_unit_quiescent.assert_called_once_with("canary-buyer.service")
        self.assertEqual(
            self.updater.run_command.call_args_list[-1],
            mock.call(
                ["systemctl", "stop", "canary-buyer.service"],
                check=False,
                timeout=420,
            ),
        )

    def test_canary_status_failure_is_stopped_and_proven_quiescent(self):
        self.updater.verify_canary_authority = mock.Mock()
        self.updater.verify_canary_rollout_readiness = mock.Mock()
        self.updater._journal_transition = mock.Mock()
        self.updater.assert_unit_quiescent = mock.Mock()
        self.updater.run_command = mock.Mock(
            side_effect=[
                subprocess.CompletedProcess(
                    ["systemctl", "start"], 0, stdout="", stderr=""
                ),
                updater_module.CommandTimeout("status deadline"),
                subprocess.CompletedProcess(["systemctl", "stop"], 0, stdout="", stderr=""),
            ]
        )

        with self.assertRaisesRegex(updater_module.UpdateError, "status could not be verified"):
            self.updater.run_canary_gate()

        self.updater.assert_unit_quiescent.assert_called_once_with("canary-buyer.service")

    def test_canary_cancellation_still_quiesces_when_journaling_fails(self):
        self.updater._journal_transition = mock.Mock(
            side_effect=updater_module.UpdateError("journal unavailable")
        )
        self.updater.assert_unit_quiescent = mock.Mock()
        self.updater.run_command = mock.Mock(
            return_value=subprocess.CompletedProcess(
                ["systemctl", "stop"], 0, stdout="", stderr=""
            )
        )

        with self.assertRaisesRegex(updater_module.UpdateError, "was quiesced.*journaling failed"):
            self.updater._stop_failed_canary_gate(
                "canary-buyer.service",
                "serving gate failed",
            )

        self.updater.run_command.assert_called_once_with(
            ["systemctl", "stop", "canary-buyer.service"],
            check=False,
            timeout=420,
        )
        self.updater.assert_unit_quiescent.assert_called_once_with("canary-buyer.service")

    def test_canary_skip_status_cannot_satisfy_serving_gate(self):
        for status in (20, 21):
            with self.subTest(status=status):
                self.updater.verify_canary_authority = mock.Mock()
                self.updater.verify_canary_rollout_readiness = mock.Mock()
                self.updater.audit = mock.Mock()
                self.updater._journal_transition = mock.Mock()
                self.updater.issue_start_permit = mock.Mock(return_value=None)
                self.updater.assert_unit_quiescent = mock.Mock()
                self.updater.run_command = mock.Mock(
                    side_effect=[
                        subprocess.CompletedProcess(
                            ["systemctl", "start"], 0, stdout="", stderr=""
                        ),
                        subprocess.CompletedProcess(
                            ["systemctl", "show"],
                            0,
                            stdout=f"Result=success\nExecMainStatus={status}\n",
                            stderr="",
                        ),
                        subprocess.CompletedProcess(
                            ["systemctl", "stop"], 0, stdout="", stderr=""
                        ),
                    ]
                )

                with self.assertRaisesRegex(
                    updater_module.UpdateError, "did not complete successfully"
                ):
                    self.updater.run_canary_gate()

                self.updater.verify_canary_authority.assert_called_once_with()
                self.updater.verify_canary_rollout_readiness.assert_called_once_with()
                self.updater.assert_unit_quiescent.assert_called_once_with(
                    "canary-buyer.service"
                )

    def test_canary_zero_exec_status_is_required_and_accepted(self):
        self.updater.verify_canary_authority = mock.Mock()
        self.updater.verify_canary_rollout_readiness = mock.Mock()
        self.updater.audit = mock.Mock()
        self.updater._journal_transition = mock.Mock()
        self.updater.issue_start_permit = mock.Mock(return_value=None)
        self.updater.run_command = mock.Mock(
            side_effect=[
                subprocess.CompletedProcess(
                    ["systemctl", "start"], 0, stdout="", stderr=""
                ),
                subprocess.CompletedProcess(
                    ["systemctl", "show"],
                    0,
                    stdout="Result=success\nExecMainStatus=0\n",
                    stderr="",
                ),
            ]
        )

        self.updater.run_canary_gate()

        self.updater.audit.assert_called_once_with(
            "canary_serving_gate",
            "success",
            authority=updater_module.CANARY_AUTHORITY_VERSION,
        )

    def test_rollout_stops_timer_and_inflight_canary_before_drain(self):
        self.updater.get_json = mock.Mock(return_value={"pool_size": 0, "pool_ready": 0})
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
        modes = {}
        paths = {}
        for name in (
            "probe.mjs",
            "safety.mjs",
            "run-canary.sh",
            "emergency-disable.sh",
            "canary-buyer.service",
            "canary-buyer.timer",
        ):
            path = self.root / name
            path.write_text(name + "\n")
            path.chmod(0o644 if name.endswith((".service", ".timer")) else 0o755)
            files[path] = updater_module.sha256_file(path)
            modes[path] = stat.S_IMODE(path.stat().st_mode)
            paths[name] = path
        private_files = {}
        private_paths = {}
        private_values = {
            "buyer-token": "buyer-token-value\n",
            "heartbeat": "https://heartbeat.invalid/canary-token\n",
            "operator-token": "operator-token-value\n",
        }
        for name, value in private_values.items():
            path = self.root / name
            path.write_text(value)
            path.chmod(0o600)
            private_files[path] = name
            private_paths[name] = path
        expected_fleet = self.root / "expected-fleet.json"
        expected_fleet.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "providers": [
                        {
                            "provider_id": "provider-a",
                            "model_id": "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
                        },
                        {
                            "provider_id": "provider-b",
                            "model_id": "mlx-community/Llama-3.2-3B-Instruct-4bit",
                        },
                        {
                            "provider_id": "provider-c",
                            "model_id": "mlx-community/Qwen3-8B-4bit",
                        },
                    ],
                }
            )
        )
        expected_fleet.chmod(0o600)
        private_files[expected_fleet] = "canary expected fleet"
        control_dir = self.root / "canary-control"
        control_dir.mkdir(mode=0o755)
        enable_gate = control_dir / "enabled"
        enable_gate.write_bytes(b"")
        enable_gate.chmod(0o644)
        disable_sentinel = self.root / "DISABLED"
        dropin = self.root / "canary-buyer.service.d" / updater_module.TRANSACTION_GATE_DROPIN_NAME
        dropin.parent.mkdir()
        dropin.write_text(updater_module.TRANSACTION_GATE_DROPIN_TEXT)

        def show_unit(argv, **_kwargs):
            unit = argv[-1]
            timeout = "TimeoutStartUSec=3min\n" if unit.endswith(".service") else ""
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
            mock.patch.object(updater_module, "CANARY_AUTHORITY_FILE_MODES", modes),
            mock.patch.object(updater_module, "CANARY_AUTHORITY_PRIVATE_FILES", private_files),
            mock.patch.object(
                updater_module, "CANARY_BUYER_TOKEN", private_paths["buyer-token"]
            ),
            mock.patch.object(
                updater_module, "CANARY_HEARTBEAT_URL", private_paths["heartbeat"]
            ),
            mock.patch.object(
                updater_module, "CANARY_OPERATOR_TOKEN", private_paths["operator-token"]
            ),
            mock.patch.object(updater_module, "CANARY_EXPECTED_FLEET", expected_fleet),
            mock.patch.object(updater_module, "CANARY_ENABLE_GATE", enable_gate),
            mock.patch.object(updater_module, "CANARY_DISABLE_SENTINEL", disable_sentinel),
            mock.patch.object(updater_module, "SYSTEMD_ROOT", self.root),
        ):
            self.updater.verify_canary_authority()
            self.updater.verify_canary_rollout_readiness()

            control_dir.chmod(0o775)
            with self.assertRaisesRegex(updater_module.UpdateError, "canary control directory mode"):
                self.updater.verify_canary_rollout_readiness()
            control_dir.chmod(0o755)

            paths["emergency-disable.sh"].chmod(0o644)
            with self.assertRaisesRegex(updater_module.UpdateError, "requires mode 0755"):
                self.updater.verify_canary_authority()
            paths["emergency-disable.sh"].chmod(0o755)

            private_paths["heartbeat"].chmod(0o400)
            with self.assertRaisesRegex(updater_module.UpdateError, "exact root-owned 0600"):
                self.updater.verify_canary_authority()
            private_paths["heartbeat"].chmod(0o600)

            private_paths["buyer-token"].write_text("  \n")
            with self.assertRaisesRegex(updater_module.UpdateError, "buyer token.*whitespace"):
                self.updater.verify_canary_authority()
            private_paths["buyer-token"].write_text(private_values["buyer-token"])

            private_paths["operator-token"].write_text("operator token\n")
            with self.assertRaisesRegex(updater_module.UpdateError, "operator token.*whitespace"):
                self.updater.verify_canary_authority()
            private_paths["operator-token"].write_text(private_values["operator-token"])

            private_paths["heartbeat"].write_text("http://heartbeat.invalid/token\n")
            with self.assertRaisesRegex(updater_module.UpdateError, "must be one HTTPS URL"):
                self.updater.verify_canary_authority()
            private_paths["heartbeat"].write_text(" https://heartbeat.invalid/token\n")
            with self.assertRaisesRegex(updater_module.UpdateError, "must be one HTTPS URL"):
                self.updater.verify_canary_authority()
            private_paths["heartbeat"].write_text(private_values["heartbeat"])

            expected_fleet.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "providers": [],
                    }
                )
            )
            with self.assertRaisesRegex(updater_module.UpdateError, "unique protected providers"):
                self.updater.verify_canary_authority()

    def test_canary_rollout_authority_hashes_match_issue_825_duplicate_fleet_runtime(self):
        sources = {
            Path("/opt/macprovider-canary-buyer/probe.mjs"):
                REPO_ROOT / "test/e2e/canary-buyer/probe.mjs",
            Path("/opt/macprovider-canary-buyer/safety.mjs"):
                REPO_ROOT / "test/e2e/canary-buyer/safety.mjs",
            Path("/opt/macprovider-canary-buyer/run-canary.sh"):
                REPO_ROOT / "test/e2e/canary-buyer/run-canary.sh",
            Path("/opt/macprovider-canary-buyer/emergency-disable.sh"):
                REPO_ROOT / "test/e2e/canary-buyer/emergency-disable.sh",
            Path("/etc/systemd/system/canary-buyer.service"):
                REPO_ROOT / "test/e2e/canary-buyer/canary-buyer.service",
            Path("/etc/systemd/system/canary-buyer.timer"):
                REPO_ROOT / "test/e2e/canary-buyer/canary-buyer.timer",
        }
        self.assertEqual(set(updater_module.CANARY_AUTHORITY_FILES), set(sources))
        self.assertEqual(set(updater_module.CANARY_AUTHORITY_FILE_MODES), set(sources))
        for installed, source in sources.items():
            source_at_authority = subprocess.run(
                [
                    "git",
                    "show",
                    f"{updater_module.CANARY_AUTHORITY_COMMIT}:{source.relative_to(REPO_ROOT).as_posix()}",
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
            ).stdout
            self.assertEqual(
                updater_module.CANARY_AUTHORITY_FILES[installed],
                updater_module.sha256_file(source),
            )
            self.assertEqual(
                updater_module.CANARY_AUTHORITY_FILES[installed],
                hashlib.sha256(source_at_authority).hexdigest(),
            )
        self.assertEqual(updater_module.CANARY_AUTHORITY_VERSION, "issue-825-canary-fleet-r6")
        self.assertEqual(
            updater_module.CANARY_AUTHORITY_COMMIT,
            "fb3f4f1680b9cf2404c0f40317bef3696d659f58",
        )
        subprocess.run(
            ["git", "cat-file", "-e", f"{updater_module.CANARY_AUTHORITY_COMMIT}^{{commit}}"],
            cwd=REPO_ROOT,
            check=True,
        )
        self.assertEqual(
            updater_module.CANARY_AUTHORITY_FILE_MODES,
            {
                Path("/opt/macprovider-canary-buyer/probe.mjs"): 0o755,
                Path("/opt/macprovider-canary-buyer/safety.mjs"): 0o755,
                Path("/opt/macprovider-canary-buyer/run-canary.sh"): 0o755,
                Path("/opt/macprovider-canary-buyer/emergency-disable.sh"): 0o755,
                Path("/etc/systemd/system/canary-buyer.service"): 0o644,
                Path("/etc/systemd/system/canary-buyer.timer"): 0o644,
            },
        )
        self.assertEqual(
            updater_module.CANARY_EXPECTED_MODELS,
            {
                "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
                "mlx-community/Llama-3.2-3B-Instruct-4bit",
                "mlx-community/Qwen3-8B-4bit",
            },
        )
        service_text = (REPO_ROOT / "test/e2e/canary-buyer/canary-buyer.service").read_text()
        self.assertNotIn("Environment=CANARY_MODELS=", service_text)
        self.assertNotIn("Environment=CANARY_MIN_READY_PROVIDERS=", service_text)
        self.assertEqual(updater_module.CANARY_UNIT_BUDGET_S, 180)

    def test_canary_expected_fleet_accepts_full_protected_duplicate_model_inventory(self):
        expected_fleet = self.root / "five-provider-fleet.json"
        providers = [
            {
                "provider_id": "provider-a",
                "model_id": "mlx-community/Llama-3.2-3B-Instruct-4bit",
            },
            {
                "provider_id": "provider-b",
                "model_id": "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
            },
            {
                "provider_id": "provider-c",
                "model_id": "mlx-community/Qwen3-8B-4bit",
            },
            {
                "provider_id": "provider-d",
                "model_id": "mlx-community/Llama-3.2-3B-Instruct-4bit",
            },
            {
                "provider_id": "provider-e",
                "model_id": "mlx-community/Llama-3.2-3B-Instruct-4bit",
            },
        ]
        expected_fleet.write_text(
            json.dumps({"schema_version": 1, "providers": providers}) + "\n"
        )
        expected_fleet.chmod(0o600)

        with mock.patch.object(updater_module, "CANARY_EXPECTED_FLEET", expected_fleet):
            self.assertEqual(self.updater._canary_expected_fleet(), providers)

        singleton = [
            {
                "provider_id": "provider-a",
                "model_id": "mlx-community/Llama-3.2-3B-Instruct-4bit",
            }
        ]
        expected_fleet.write_text(
            json.dumps({"schema_version": 1, "providers": singleton}) + "\n"
        )
        with mock.patch.object(updater_module, "CANARY_EXPECTED_FLEET", expected_fleet):
            self.assertEqual(self.updater._canary_expected_fleet(), singleton)

        providers[0] = {**providers[0], "provider_id": "provider-b"}
        expected_fleet.write_text(
            json.dumps({"schema_version": 1, "providers": providers}) + "\n"
        )
        with (
            mock.patch.object(updater_module, "CANARY_EXPECTED_FLEET", expected_fleet),
            self.assertRaisesRegex(updater_module.UpdateError, "unique protected providers"),
        ):
            self.updater._canary_expected_fleet()

    def test_legacy_rollback_authorization_is_exact_and_removed_after_gate(self):
        expected_fleet = self.root / "rollback-expected-fleet.json"
        providers = [
            {
                "provider_id": "provider-a",
                "model_id": "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
            },
            {
                "provider_id": "provider-b",
                "model_id": "mlx-community/Llama-3.2-3B-Instruct-4bit",
            },
            {
                "provider_id": "provider-c",
                "model_id": "mlx-community/Qwen3-8B-4bit",
            },
        ]
        expected_fleet.write_text(
            json.dumps({"schema_version": 1, "providers": providers}) + "\n"
        )
        expected_fleet.chmod(0o600)
        self.updater.previous_services = {
            "macprovider-coordinator.service": True,
            "macprovider-gateway.service": True,
        }
        self.updater.previous_pool_ready = 3
        self.updater.previous_protected_providers = ["provider-a", "provider-b", "provider-c"]
        self.updater.previous_protected_fleet = providers
        self.updater.journal = {
            "transaction_id": "a" * 64,
            "previous_advertised_version": "1.8.30",
            "rollback_armed": True,
            "rollback_in_progress": True,
            "live_mutation_started": True,
            "success_persisted": False,
        }
        self.updater.verify_canary_authority = mock.Mock()
        self.updater.verify_canary_rollout_readiness = mock.Mock()
        self.updater._journal_transition = mock.Mock()
        self.updater.issue_start_permit = mock.Mock(return_value=None)
        self.updater.coordinator_operator_token = mock.Mock(return_value="operator-token")
        self.updater.get_authorized_json = mock.Mock(
            return_value={
                "pool": [
                    {
                        **row,
                        "state": "ready",
                        "routing_eligible": True,
                        "binary_version": "1.8.30",
                    }
                    for row in providers
                ]
            }
        )
        observed = {}

        def run_canary(argv, **_kwargs):
            if argv[1] == "start":
                path = self.updater.canary_rollback_authorization
                observed["mode"] = stat.S_IMODE(path.stat().st_mode)
                observed["parent_mode"] = stat.S_IMODE(path.parent.stat().st_mode)
                observed["document"] = json.loads(path.read_text())
                return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")
            return subprocess.CompletedProcess(
                argv,
                0,
                stdout="Result=success\nExecMainStatus=0\n",
                stderr="",
            )

        self.updater.run_command = mock.Mock(side_effect=run_canary)
        with mock.patch.object(updater_module, "CANARY_EXPECTED_FLEET", expected_fleet):
            self.updater.run_canary_gate(legacy_rollback_version="v1.8.30")

        self.assertFalse(self.updater.canary_rollback_authorization.exists())
        self.assertEqual(observed["mode"], 0o644)
        self.assertEqual(observed["parent_mode"], 0o755)
        self.assertEqual(
            observed["document"],
            {
                "schema_version": 1,
                "kind": "legacy_rollback",
                "authority": "issue-825-canary-fleet-r6",
                "transaction_id": "a" * 64,
                "expires_at": observed["document"]["expires_at"],
                "providers": [
                    {**row, "binary_version": "1.8.30"} for row in providers
                ],
            },
        )

    def test_legacy_rollback_authorization_is_removed_after_gate_failure(self):
        expected_fleet = self.root / "rollback-failure-expected-fleet.json"
        providers = [
            {
                "provider_id": "provider-a",
                "model_id": "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
            },
            {
                "provider_id": "provider-b",
                "model_id": "mlx-community/Llama-3.2-3B-Instruct-4bit",
            },
            {
                "provider_id": "provider-c",
                "model_id": "mlx-community/Qwen3-8B-4bit",
            },
        ]
        expected_fleet.write_text(
            json.dumps({"schema_version": 1, "providers": providers}) + "\n"
        )
        expected_fleet.chmod(0o600)
        self.updater.previous_services = {
            "macprovider-coordinator.service": True,
            "macprovider-gateway.service": True,
        }
        self.updater.previous_pool_ready = 3
        self.updater.previous_protected_providers = ["provider-a", "provider-b", "provider-c"]
        self.updater.previous_protected_fleet = providers
        self.updater.journal = {
            "transaction_id": "a" * 64,
            "previous_advertised_version": "1.8.30",
            "rollback_armed": True,
            "rollback_in_progress": True,
            "live_mutation_started": True,
            "success_persisted": False,
        }
        self.updater.verify_canary_authority = mock.Mock()
        self.updater.verify_canary_rollout_readiness = mock.Mock()
        self.updater._journal_transition = mock.Mock()
        self.updater.issue_start_permit = mock.Mock(return_value=None)
        self.updater.assert_unit_quiescent = mock.Mock()
        self.updater.coordinator_operator_token = mock.Mock(return_value="operator-token")
        self.updater.get_authorized_json = mock.Mock(
            return_value={
                "pool": [
                    {
                        **row,
                        "state": "ready",
                        "routing_eligible": True,
                        "binary_version": "1.8.30",
                    }
                    for row in providers
                ]
            }
        )
        self.updater.run_command = mock.Mock(
            side_effect=[
                subprocess.CompletedProcess(
                    ["systemctl", "start"], 1, stdout="", stderr="buyer proof failed"
                ),
                subprocess.CompletedProcess(
                    ["systemctl", "stop"], 0, stdout="", stderr=""
                ),
            ]
        )

        with (
            mock.patch.object(updater_module, "CANARY_EXPECTED_FLEET", expected_fleet),
            self.assertRaisesRegex(updater_module.UpdateError, "buyer proof failed"),
        ):
            self.updater.run_canary_gate(legacy_rollback_version="1.8.30")

        self.assertFalse(self.updater.canary_rollback_authorization.exists())
        self.updater.assert_unit_quiescent.assert_called_once_with("canary-buyer.service")

    def test_canary_readiness_rejects_stale_legacy_rollback_authorization(self):
        control_dir = self.root / "canary-control-stale"
        control_dir.mkdir(mode=0o755)
        enable_gate = control_dir / "enabled"
        enable_gate.write_bytes(b"")
        enable_gate.chmod(0o644)
        rollback_dir = self.updater.canary_rollback_authorization.parent
        rollback_dir.mkdir(mode=0o755)
        self.updater.canary_rollback_authorization.write_text("{}\n")
        self.updater.canary_rollback_authorization.chmod(0o644)

        with (
            mock.patch.object(updater_module, "CANARY_ENABLE_GATE", enable_gate),
            mock.patch.object(
                updater_module,
                "CANARY_DISABLE_SENTINEL",
                self.root / "no-disable-sentinel",
            ),
        ):
            with self.assertRaisesRegex(updater_module.UpdateError, "stale legacy rollback"):
                self.updater.verify_canary_rollout_readiness()

    def test_legacy_rollback_authorization_rejects_wrong_fleet_or_context(self):
        expected_fleet = self.root / "rollback-context-fleet.json"
        expected_fleet.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "providers": [
                        {
                            "provider_id": "provider-a",
                            "model_id": "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
                        },
                        {
                            "provider_id": "provider-b",
                            "model_id": "mlx-community/Llama-3.2-3B-Instruct-4bit",
                        },
                        {
                            "provider_id": "provider-c",
                            "model_id": "mlx-community/Qwen3-8B-4bit",
                        },
                    ],
                }
            )
            + "\n"
        )
        expected_fleet.chmod(0o600)
        self.updater.previous_pool_ready = 3
        self.updater.previous_protected_providers = ["provider-a", "provider-b", "provider-c"]
        self.updater.previous_protected_fleet = [
            {
                "provider_id": "provider-a",
                "model_id": "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
            },
            {
                "provider_id": "provider-b",
                "model_id": "mlx-community/Llama-3.2-3B-Instruct-4bit",
            },
            {
                "provider_id": "provider-c",
                "model_id": "mlx-community/Qwen3-8B-4bit",
            },
        ]
        self.updater.journal = {
            "transaction_id": "b" * 64,
            "previous_advertised_version": "1.8.30",
            "rollback_armed": True,
            "rollback_in_progress": False,
            "live_mutation_started": True,
            "success_persisted": False,
        }

        with mock.patch.object(updater_module, "CANARY_EXPECTED_FLEET", expected_fleet):
            with self.assertRaisesRegex(updater_module.UpdateError, "outside an active restoration"):
                self.updater._write_legacy_rollback_authorization("1.8.30")
            self.updater.journal["rollback_in_progress"] = True
            self.updater.previous_protected_providers = ["provider-a", "wrong-provider"]
            self.updater.coordinator_operator_token = mock.Mock(return_value="operator-token")
            self.updater.get_authorized_json = mock.Mock(
                return_value={
                    "pool": [
                        {
                            "provider_id": "provider-a",
                            "model_id": "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
                            "state": "ready",
                            "routing_eligible": True,
                            "binary_version": "1.8.30",
                        }
                    ]
                }
            )
            with self.assertRaisesRegex(updater_module.UpdateError, "captured protected providers"):
                self.updater._write_legacy_rollback_authorization("1.8.30")

    def test_legacy_rollback_authorization_rejects_restored_model_drift(self):
        self.updater.previous_services = {
            "macprovider-coordinator.service": True,
            "macprovider-gateway.service": True,
        }
        self.updater.previous_pool_ready = 1
        self.updater.previous_protected_providers = ["provider-a"]
        self.updater.previous_protected_fleet = [
            {"provider_id": "provider-a", "model_id": "model-before-rollout"},
        ]
        self.updater.journal = {
            "transaction_id": "c" * 64,
            "previous_advertised_version": "1.8.30",
            "rollback_armed": True,
            "rollback_in_progress": True,
            "live_mutation_started": True,
            "success_persisted": False,
        }
        self.updater.coordinator_operator_token = mock.Mock(return_value="operator-token")
        self.updater.get_authorized_json = mock.Mock(
            return_value={
                "pool": [
                    {
                        "provider_id": "provider-a",
                        "model_id": "model-after-rollout",
                        "state": "ready",
                        "routing_eligible": True,
                        "binary_version": "1.8.30",
                    }
                ]
            }
        )

        with self.assertRaisesRegex(
            updater_module.UpdateError,
            "captured protected providers",
        ):
            self.updater._write_legacy_rollback_authorization("1.8.30")

    def test_canary_rollout_readiness_requires_reviewed_enable_gate(self):
        files = {}
        for name in ("canary-buyer.service", "canary-buyer.timer"):
            path = self.root / name
            path.write_text(name + "\n")
            files[path] = updater_module.sha256_file(path)
        expected_fleet = self.root / "expected-fleet.json"
        expected_fleet.write_text(
            '{"schema_version":1,"providers":['
            '{"provider_id":"a","model_id":"mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"},'
            '{"provider_id":"b","model_id":"mlx-community/Llama-3.2-3B-Instruct-4bit"},'
            '{"provider_id":"c","model_id":"mlx-community/Qwen3-8B-4bit"}]}'
        )
        expected_fleet.chmod(0o600)

        with (
            mock.patch.object(updater_module, "CANARY_AUTHORITY_FILES", files),
            mock.patch.object(
                updater_module,
                "CANARY_AUTHORITY_PRIVATE_FILES",
                {expected_fleet: "canary expected fleet"},
            ),
            mock.patch.object(updater_module, "CANARY_EXPECTED_FLEET", expected_fleet),
            mock.patch.object(
                updater_module,
                "CANARY_ENABLE_GATE",
                self.root / "missing-canary-buyer.enabled",
            ),
            mock.patch.object(
                updater_module,
                "CANARY_DISABLE_SENTINEL",
                self.root / "DISABLED",
            ),
        ):
            with self.assertRaisesRegex(updater_module.UpdateError, "canary reviewed enable gate"):
                self.updater.verify_canary_rollout_readiness()

    def test_canary_rollout_readiness_honors_emergency_disable(self):
        files = {}
        for name in ("canary-buyer.service", "canary-buyer.timer"):
            path = self.root / name
            path.write_text(name + "\n")
            files[path] = updater_module.sha256_file(path)
        expected_fleet = self.root / "expected-fleet.json"
        expected_fleet.write_text(
            '{"schema_version":1,"providers":['
            '{"provider_id":"a","model_id":"mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"},'
            '{"provider_id":"b","model_id":"mlx-community/Llama-3.2-3B-Instruct-4bit"},'
            '{"provider_id":"c","model_id":"mlx-community/Qwen3-8B-4bit"}]}'
        )
        expected_fleet.chmod(0o600)
        control_dir = self.root / "canary-control"
        control_dir.mkdir(mode=0o755)
        enable_gate = control_dir / "enabled"
        enable_gate.write_bytes(b"")
        enable_gate.chmod(0o644)
        disable_sentinel = self.root / "DISABLED"
        disable_sentinel.write_bytes(b"")

        with (
            mock.patch.object(updater_module, "CANARY_AUTHORITY_FILES", files),
            mock.patch.object(
                updater_module,
                "CANARY_AUTHORITY_PRIVATE_FILES",
                {expected_fleet: "canary expected fleet"},
            ),
            mock.patch.object(updater_module, "CANARY_EXPECTED_FLEET", expected_fleet),
            mock.patch.object(updater_module, "CANARY_ENABLE_GATE", enable_gate),
            mock.patch.object(updater_module, "CANARY_DISABLE_SENTINEL", disable_sentinel),
        ):
            with self.assertRaisesRegex(updater_module.UpdateError, "emergency-disable sentinel"):
                self.updater.verify_canary_rollout_readiness()

    def test_disabled_buyer_canary_posture_requires_hard_disabled_units(self):
        state_root = self.root / "canary-state"
        state_root.mkdir(mode=0o755)
        sentinel = state_root / "DISABLED"
        sentinel.write_bytes(b"")
        sentinel.chmod(0o644)
        self.updater.run_command = mock.Mock(
            side_effect=[
                subprocess.CompletedProcess([], 1, stdout="disabled\n", stderr=""),
                subprocess.CompletedProcess([], 3, stdout="inactive\n", stderr=""),
                subprocess.CompletedProcess([], 3, stdout="inactive\n", stderr=""),
            ]
        )
        self.updater.audit = mock.Mock()

        with (
            mock.patch.object(
                updater_module,
                "CANARY_ENABLE_GATE",
                self.root / "missing-reviewed-enable-gate",
            ),
            mock.patch.object(
                updater_module,
                "CANARY_LEGACY_ENABLE_GATE",
                self.root / "missing-legacy-enable-gate",
            ),
            mock.patch.object(updater_module, "CANARY_DISABLE_SENTINEL", sentinel),
        ):
            self.updater.verify_disabled_buyer_canary_posture()

        self.assertEqual(self.updater.run_command.call_count, 3)
        self.updater.audit.assert_called_once_with(
            "buyer_canary_rollout_posture",
            "disabled",
            mode=updater_module.BUYER_CANARY_MODE_DISABLED,
            timer_enabled=False,
            timer_active=False,
            service_active=False,
        )

    def test_disabled_buyer_canary_posture_rejects_any_enable_gate(self):
        gate = self.root / "enabled"
        gate.write_bytes(b"")
        state_root = self.root / "canary-state"
        state_root.mkdir(mode=0o755)
        sentinel = state_root / "DISABLED"
        sentinel.write_bytes(b"")
        sentinel.chmod(0o644)
        with (
            mock.patch.object(updater_module, "CANARY_ENABLE_GATE", gate),
            mock.patch.object(
                updater_module,
                "CANARY_LEGACY_ENABLE_GATE",
                self.root / "missing-legacy-enable-gate",
            ),
            mock.patch.object(updater_module, "CANARY_DISABLE_SENTINEL", sentinel),
        ):
            with self.assertRaisesRegex(updater_module.UpdateError, "must be absent"):
                self.updater.verify_disabled_buyer_canary_posture()

    def test_disabled_buyer_canary_posture_rejects_active_service(self):
        state_root = self.root / "canary-state"
        state_root.mkdir(mode=0o755)
        sentinel = state_root / "DISABLED"
        sentinel.write_bytes(b"")
        sentinel.chmod(0o644)
        self.updater.run_command = mock.Mock(
            side_effect=[
                subprocess.CompletedProcess([], 1, stdout="disabled\n", stderr=""),
                subprocess.CompletedProcess([], 3, stdout="inactive\n", stderr=""),
                subprocess.CompletedProcess([], 0, stdout="active\n", stderr=""),
            ]
        )
        with (
            mock.patch.object(
                updater_module,
                "CANARY_ENABLE_GATE",
                self.root / "missing-reviewed-enable-gate",
            ),
            mock.patch.object(
                updater_module,
                "CANARY_LEGACY_ENABLE_GATE",
                self.root / "missing-legacy-enable-gate",
            ),
            mock.patch.object(updater_module, "CANARY_DISABLE_SENTINEL", sentinel),
        ):
            with self.assertRaisesRegex(updater_module.UpdateError, "requires canary-buyer.service inactive"):
                self.updater.verify_disabled_buyer_canary_posture()

    def test_disabled_buyer_canary_posture_accepts_exact_systemd_state_directory_link(self):
        private_root = self.root / "private"
        private_root.mkdir(mode=0o755)
        state_target = private_root / "macprovider-canary-buyer"
        state_target.mkdir(mode=0o755)
        sentinel = state_target / "DISABLED"
        sentinel.write_bytes(b"")
        sentinel.chmod(0o644)
        state_link = self.root / "macprovider-canary-buyer"
        state_link.symlink_to(Path("private/macprovider-canary-buyer"))
        self.updater.run_command = mock.Mock(
            side_effect=[
                subprocess.CompletedProcess([], 1, stdout="disabled\n", stderr=""),
                subprocess.CompletedProcess([], 3, stdout="inactive\n", stderr=""),
                subprocess.CompletedProcess([], 3, stdout="inactive\n", stderr=""),
            ]
        )

        with (
            mock.patch.object(
                updater_module,
                "CANARY_ENABLE_GATE",
                self.root / "missing-reviewed-enable-gate",
            ),
            mock.patch.object(
                updater_module,
                "CANARY_LEGACY_ENABLE_GATE",
                self.root / "missing-legacy-enable-gate",
            ),
            mock.patch.object(
                updater_module,
                "CANARY_DISABLE_SENTINEL",
                state_link / "DISABLED",
            ),
            mock.patch.object(
                updater_module,
                "CANARY_DISABLE_STATE_DIRECTORY",
                state_target,
            ),
        ):
            self.updater.verify_disabled_buyer_canary_posture()

    def test_disabled_buyer_canary_posture_rejects_wrong_state_directory_link(self):
        wrong_target = self.root / "wrong-state"
        wrong_target.mkdir(mode=0o755)
        (wrong_target / "DISABLED").write_bytes(b"")
        state_link = self.root / "macprovider-canary-buyer"
        state_link.symlink_to(Path("wrong-state"))

        with (
            mock.patch.object(
                updater_module,
                "CANARY_ENABLE_GATE",
                self.root / "missing-reviewed-enable-gate",
            ),
            mock.patch.object(
                updater_module,
                "CANARY_LEGACY_ENABLE_GATE",
                self.root / "missing-legacy-enable-gate",
            ),
            mock.patch.object(
                updater_module,
                "CANARY_DISABLE_SENTINEL",
                state_link / "DISABLED",
            ),
            mock.patch.object(
                updater_module,
                "CANARY_DISABLE_STATE_DIRECTORY",
                self.root / "private" / "macprovider-canary-buyer",
            ),
        ):
            with self.assertRaisesRegex(
                updater_module.UpdateError,
                "root-owned systemd StateDirectory link",
            ):
                self.updater.verify_disabled_buyer_canary_posture()

    def test_buyer_canary_posture_dispatches_disabled_mode_without_runtime_authority(self):
        self.updater.config = updater_module.dataclasses.replace(
            self.updater.config,
            buyer_canary_mode=updater_module.BUYER_CANARY_MODE_DISABLED,
        )
        self.updater.verify_canary_authority = mock.Mock()
        self.updater.verify_canary_rollout_readiness = mock.Mock()
        self.updater.verify_disabled_buyer_canary_posture = mock.Mock()

        self.updater.verify_buyer_canary_rollout_posture()

        self.updater.verify_disabled_buyer_canary_posture.assert_called_once_with()
        self.updater.verify_canary_authority.assert_not_called()
        self.updater.verify_canary_rollout_readiness.assert_not_called()

    def test_canary_timer_restore_honors_late_kill_switch(self):
        self.updater.canary_timer_was_active = True
        self.updater._canary_schedule_allowed = mock.Mock(side_effect=[True, False])
        self.updater.service_active = mock.Mock(return_value=False)
        self.updater.systemctl = mock.Mock()
        self.updater.assert_unit_quiescent = mock.Mock()
        self.updater.audit = mock.Mock()

        self.updater._restore_canary_timer()

        self.assertEqual(
            self.updater.systemctl.call_args_list,
            [
                mock.call("start", "canary-buyer.timer"),
                mock.call("stop", "canary-buyer.timer"),
            ],
        )
        self.updater.assert_unit_quiescent.assert_called_once_with("canary-buyer.timer")

    def test_canary_timer_restore_never_replays_service_when_disabled(self):
        self.updater.canary_timer_was_active = True
        self.updater._canary_schedule_allowed = mock.Mock(return_value=False)
        self.updater.systemctl = mock.Mock()
        self.updater.assert_unit_quiescent = mock.Mock()
        self.updater.audit = mock.Mock()

        self.updater._restore_canary_timer()

        self.updater.systemctl.assert_called_once_with("stop", "canary-buyer.timer")
        self.assertNotIn(
            mock.call("start", "canary-buyer.service"),
            self.updater.systemctl.call_args_list,
        )

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
        self.updater._restore_catalog = mock.Mock()
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

        installed_catalog = (
            self.updater.install_root
            / "autotune"
            / "releases"
            / self.updater._catalog_release_directory_name(release)
        )
        installed_catalog.chmod(0o700)
        (installed_catalog / updater_module.CATALOG_ASSETS[0]).chmod(0o600)
        _, decision = self.updater.eligibility(release)
        self.assertEqual(decision, "repair_pair")
        self.updater.install_catalog(release)
        _, decision = self.updater.eligibility(release)
        self.assertEqual(decision, "already_current")

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

    def test_same_signed_v1860_repairs_legacy_duplicate_then_becomes_current(self):
        self.make_bundle("1.8.60")
        release = self.stage(self.updater.verify_release(self.bundle, "v1.8.60"))
        self.install_coherent_pair(release)
        legacy = self.updater.install_root / "tier2-catalog.json"
        shutil.copy2(
            self.updater._current_tier2_catalog_path(),
            legacy,
        )
        legacy.chmod(0o640)

        current, decision = self.updater.eligibility(release)

        self.assertEqual((str(current), decision), ("1.8.60", "repair_pair"))

        self.updater.install_catalog(release)
        current, decision = self.updater.eligibility(release)

        self.assertEqual((str(current), decision), ("1.8.60", "already_current"))
        self.assertFalse(legacy.exists())

    def test_prove_current_runs_three_single_authority_cycles(self):
        release = self.stage(self.verify())
        self.install_coherent_pair(release)
        config = self.root / "coordinator.yaml"
        config.write_text(
            "tier2:\n"
            f"  catalog_path: {self.updater.install_root}/autotune/current/tier2-catalog.json\n"
            "  require_hash_verified: false\n"
        )
        self.updater.coordinator_runtime = mock.Mock(
            return_value=updater_module.CoordinatorRuntime(config, None, {})
        )
        self.updater.config = updater_module.dataclasses.replace(
            self.updater.config,
            buyer_canary_mode=updater_module.BUYER_CANARY_MODE_DISABLED,
            catalog_canary_provider_id="catalog-canary",
        )
        self.updater.verify_buyer_canary_rollout_posture = mock.Mock()
        provider_evidence = updater_module.CatalogCanaryEvidence(
            row_identity="b" * 64,
            assigned_id="session-canary",
            catalog_key="llama-3.2-3b-instruct",
            model_id="mlx-community/Llama-3.2-3B-Instruct-4bit",
        )
        self.updater.verify_exact_provider_canary = mock.Mock(
            return_value=provider_evidence
        )
        self.updater.verify_live_runtime_binding = mock.Mock()
        self.updater.verify_live_sighup_binding = mock.Mock()
        self.updater.prove_gateway_buyer_stream = mock.Mock(
            side_effect=[
                {
                    "request_id": f"request-{cycle}",
                    "response_request_id": f"gateway-request-{cycle}",
                    "requested_at": f"2026-07-23T00:00:0{cycle}Z",
                    "provider_id": "catalog-canary",
                    "model": "mlx-community/Llama-3.2-3B-Instruct-4bit",
                }
                for cycle in range(1, 4)
            ]
        )
        proof_order = mock.Mock()
        proof_order.attach_mock(self.updater.verify_buyer_canary_rollout_posture, "posture")
        proof_order.attach_mock(self.updater.prove_gateway_buyer_stream, "buyer")
        proof_order.attach_mock(self.updater.verify_exact_provider_canary, "provider")
        self.updater.prepare_config_update = mock.Mock()
        self.updater.snapshot = mock.Mock()
        self.updater.install_release = mock.Mock()
        self.updater.audit = mock.Mock()

        current, decision = self.updater.prove_current_release(release)

        self.assertEqual((str(current), decision), ("1.8.27", "already_current"))
        self.updater.verify_live_runtime_binding.assert_called_once_with(release, "false")
        self.assertEqual(self.updater.verify_buyer_canary_rollout_posture.call_count, 3)
        self.assertEqual(self.updater.verify_exact_provider_canary.call_args_list, [mock.call(release)] * 4)
        self.assertEqual(
            self.updater.prove_gateway_buyer_stream.call_args_list,
            [
                mock.call(
                    cycle=cycle,
                    provider_id="catalog-canary",
                    model_id="mlx-community/Llama-3.2-3B-Instruct-4bit",
                )
                for cycle in range(1, 4)
            ],
        )
        self.assertEqual(
            [call[0] for call in proof_order.mock_calls],
            ["provider"] + ["posture", "buyer", "provider"] * 3,
        )
        proof_events = [
            call
            for call in self.updater.audit.call_args_list
            if call.args[:2] == ("single_authority_buyer_serving_cycle", "success")
        ]
        self.assertEqual([call.kwargs["cycle"] for call in proof_events], [1, 2, 3])
        self.assertTrue(
            all(
                call.kwargs["assigned_id"] == provider_evidence.assigned_id
                and call.kwargs["catalog_row_identity"] == provider_evidence.row_identity
                for call in proof_events
            )
        )
        self.updater.prepare_config_update.assert_not_called()
        self.updater.snapshot.assert_not_called()
        self.updater.install_release.assert_not_called()

        config.write_text(
            "tier2:\n"
            f"  catalog_path: {self.updater.install_root}/autotune/current/tier2-catalog.json\n"
            "  require_hash_verified: true\n"
        )
        self.updater.verify_live_sighup_binding.reset_mock()
        self.updater.verify_exact_provider_canary.reset_mock(
            side_effect=True,
            return_value=True,
        )
        self.updater.verify_exact_provider_canary.return_value = provider_evidence
        self.updater.prove_gateway_buyer_stream.reset_mock(
            side_effect=True,
            return_value=True,
        )
        self.updater.prove_gateway_buyer_stream.side_effect = [
            {
                "request_id": f"enforced-request-{cycle}",
                "response_request_id": f"enforced-gateway-request-{cycle}",
                "requested_at": f"2026-07-23T00:02:0{cycle}Z",
                "provider_id": "catalog-canary",
                "model": "mlx-community/Llama-3.2-3B-Instruct-4bit",
            }
            for cycle in range(1, 4)
        ]
        self.updater.audit.reset_mock()

        current, decision = self.updater.prove_hash_enforced_release(release)

        self.assertEqual((str(current), decision), ("1.8.27", "already_current"))
        self.updater.verify_live_sighup_binding.assert_called_once_with(release, "true")
        enforced_events = [
            call
            for call in self.updater.audit.call_args_list
            if call.args[:2] == ("hash_enforced_buyer_serving_cycle", "success")
        ]
        self.assertEqual([call.kwargs["cycle"] for call in enforced_events], [1, 2, 3])

        config.write_text(
            "tier2:\n"
            f"  catalog_path: {self.updater.install_root}/autotune/current/tier2-catalog.json\n"
            "  require_hash_verified: true\n"
            "  model_hash_legacy_until: 2026-07-24T00:00:00Z\n"
        )
        self.updater.verify_exact_provider_canary.reset_mock()
        with self.assertRaisesRegex(
            updater_module.UpdateError,
            "hash-enforced proof refuses the model hash algorithm legacy bridge",
        ):
            self.updater.prove_hash_enforced_release(release)
        self.updater.verify_exact_provider_canary.assert_not_called()

        config.write_text(
            "tier2:\n"
            f"  catalog_path: {self.updater.install_root}/autotune/current/tier2-catalog.json\n"
            "  require_hash_verified: false\n"
        )
        self.updater.verify_exact_provider_canary.reset_mock(
            side_effect=True,
            return_value=True,
        )
        self.updater.verify_exact_provider_canary.side_effect = [
            provider_evidence,
            updater_module.dataclasses.replace(
                provider_evidence,
                assigned_id="replacement-session",
            ),
        ]
        self.updater.prove_gateway_buyer_stream.reset_mock(
            side_effect=True,
            return_value=True,
        )
        self.updater.prove_gateway_buyer_stream.return_value = {
            "request_id": "request-model-change",
            "response_request_id": "gateway-request-model-change",
            "requested_at": "2026-07-23T00:01:00Z",
            "provider_id": "catalog-canary",
            "model": "mlx-community/Llama-3.2-3B-Instruct-4bit",
        }
        self.updater.audit.reset_mock()

        with self.assertRaisesRegex(
            updater_module.UpdateError,
            "catalog canary identity changed",
        ):
            self.updater.prove_current_release(release)

        self.assertFalse(
            any(
                call.args[:2] == ("single_authority_buyer_serving_cycle", "success")
                for call in self.updater.audit.call_args_list
            )
        )

    def test_prove_current_rejects_preconditions_fail_closed(self):
        release = self.stage(self.verify())
        self.install_coherent_pair(release)
        config = self.root / "coordinator.yaml"
        config.write_text(
            "tier2:\n"
            f"  catalog_path: {self.updater.install_root}/tier2-catalog.json\n"
            "  require_hash_verified: false\n"
        )
        self.updater.coordinator_runtime = mock.Mock(
            return_value=updater_module.CoordinatorRuntime(config, None, {})
        )
        self.updater.verify_exact_provider_canary = mock.Mock()
        self.updater.config = updater_module.dataclasses.replace(
            self.updater.config,
            buyer_canary_mode=updater_module.BUYER_CANARY_MODE_DISABLED,
        )
        self.updater.verify_live_runtime_binding = mock.Mock()
        self.updater.prove_gateway_buyer_stream = mock.Mock()

        with self.assertRaisesRegex(updater_module.UpdateError, "release-bound current catalog path"):
            self.updater.prove_current_release(release)
        self.updater.verify_exact_provider_canary.assert_not_called()
        self.updater.prove_gateway_buyer_stream.assert_not_called()

        config.write_text(
            "tier2:\n"
            f"  catalog_path: {self.updater.install_root}/autotune/current/tier2-catalog.json\n"
            "  require_hash_verified: false\n"
        )
        (self.updater.install_root / "tier2-catalog.json").write_text("legacy drift\n")
        with self.assertRaisesRegex(
            updater_module.UpdateError,
            "does not match the active release-bound catalog",
        ):
            self.updater.prove_current_release(release)
        self.updater.verify_exact_provider_canary.assert_not_called()

        (self.updater.install_root / "tier2-catalog.json").unlink()
        config.write_text(
            "tier2:\n"
            f"  catalog_path: {self.updater.install_root}/autotune/current/tier2-catalog.json\n"
            "  require_hash_verified: true\n"
        )
        with self.assertRaisesRegex(
            updater_module.UpdateError,
            "tier2.require_hash_verified must be false",
        ):
            self.updater.prove_current_release(release)
        self.updater.verify_exact_provider_canary.assert_not_called()

        config.write_text(
            "tier2:\n"
            f"  catalog_path: {self.updater.install_root}/autotune/current/tier2-catalog.json\n"
            "  require_hash_verified: false\n"
        )
        self.updater.config = updater_module.dataclasses.replace(
            self.updater.config,
            buyer_canary_mode=updater_module.BUYER_CANARY_MODE_REQUIRED,
        )
        with self.assertRaisesRegex(updater_module.UpdateError, "hard-disabled buyer canary"):
            self.updater.prove_current_release(release)
        self.updater.verify_exact_provider_canary.assert_not_called()

    def test_prove_current_refuses_active_journal_before_reconcile(self):
        config = self.root / "updater.conf"
        config.write_text("PEARL_UPDATER_BUYER_CANARY_MODE=disabled\n")
        config.chmod(0o600)
        install = self.root / "proof-install"
        state = self.root / "proof-state"
        audit = self.root / "proof-audit.jsonl"
        lock = self.root / "proof.lock"
        install.mkdir(mode=0o750)
        state.mkdir(mode=0o700)
        journal = state / "active-transaction.json"
        journal.write_text(json.dumps({"schema_version": updater_module.JOURNAL_SCHEMA_VERSION}) + "\n")
        journal.chmod(0o600)

        with mock.patch.dict(
            os.environ,
            {
                "MACPROVIDER_UPDATER_TESTING": "1",
                "PEARL_UPDATER_TEST_PUBLIC_KEY": str(self.public),
                "PEARL_UPDATER_TEST_INSTALL_ROOT": str(install),
                "PEARL_UPDATER_TEST_STATE_ROOT": str(state),
                "PEARL_UPDATER_TEST_AUDIT_PATH": str(audit),
                "PEARL_UPDATER_TEST_LOCK_PATH": str(lock),
            },
            clear=False,
        ):
            with self.assertRaisesRegex(updater_module.UpdateError, "active phase journal"):
                updater_module.main(
                    [
                        "--prove-current",
                        "--tag",
                        "v1.8.27",
                        "--source-dir",
                        str(self.bundle),
                        "--config",
                        str(config),
                    ]
                )

    def test_enforcement_journal_blocks_updater_reconcile(self):
        config = self.root / "updater.conf"
        config.write_text("PEARL_UPDATER_BUYER_CANARY_MODE=disabled\n")
        config.chmod(0o600)
        install = self.root / "enforcement-gate-install"
        state = self.root / "enforcement-gate-state"
        audit = self.root / "enforcement-gate-audit.jsonl"
        lock = self.root / "enforcement-gate.lock"
        install.mkdir(mode=0o750)
        state.mkdir(mode=0o700)
        journal = state / "tier2-enforcement-transaction.json"
        journal.write_text("{}\n")
        journal.chmod(0o600)

        with mock.patch.dict(
            os.environ,
            {
                "MACPROVIDER_UPDATER_TESTING": "1",
                "PEARL_UPDATER_TEST_PUBLIC_KEY": str(self.public),
                "PEARL_UPDATER_TEST_INSTALL_ROOT": str(install),
                "PEARL_UPDATER_TEST_STATE_ROOT": str(state),
                "PEARL_UPDATER_TEST_AUDIT_PATH": str(audit),
                "PEARL_UPDATER_TEST_LOCK_PATH": str(lock),
            },
            clear=False,
        ):
            with self.assertRaisesRegex(
                updater_module.UpdateError,
                "Tier-2 enforcement transaction is active",
            ):
                updater_module.main(["--reconcile", "--config", str(config)])

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

    def test_failed_unit_is_reset_and_rechecked_quiescent(self):
        self.updater.run_command = mock.Mock(
            side_effect=[
                subprocess.CompletedProcess(
                    ["systemctl", "show"],
                    0,
                    stdout="ActiveState=failed\nSubState=failed\nJob=\n",
                    stderr="",
                ),
                subprocess.CompletedProcess(
                    ["systemctl", "reset-failed"], 0, stdout="", stderr=""
                ),
                subprocess.CompletedProcess(
                    ["systemctl", "show"],
                    0,
                    stdout="ActiveState=inactive\nSubState=dead\nJob=\n",
                    stderr="",
                ),
            ]
        )

        self.updater.assert_unit_quiescent("stats-billing-mirror.service")

        self.assertEqual(
            self.updater.run_command.call_args_list,
            [
                mock.call(
                    [
                        "systemctl",
                        "show",
                        "--property=ActiveState",
                        "--property=SubState",
                        "--property=Job",
                        "stats-billing-mirror.service",
                    ],
                    check=False,
                    timeout=10,
                ),
                mock.call(
                    ["systemctl", "reset-failed", "stats-billing-mirror.service"],
                    check=False,
                    timeout=10,
                ),
                mock.call(
                    [
                        "systemctl",
                        "show",
                        "--property=ActiveState",
                        "--property=SubState",
                        "--property=Job",
                        "stats-billing-mirror.service",
                    ],
                    check=False,
                    timeout=10,
                ),
            ],
        )

    def test_failed_unit_reset_failure_is_not_quiescent(self):
        self.updater.run_command = mock.Mock(
            side_effect=[
                subprocess.CompletedProcess(
                    ["systemctl", "show"],
                    0,
                    stdout="ActiveState=failed\nSubState=failed\nJob=\n",
                    stderr="",
                ),
                subprocess.CompletedProcess(
                    ["systemctl", "reset-failed"],
                    1,
                    stdout="",
                    stderr="reset denied",
                ),
            ]
        )

        with self.assertRaisesRegex(
            updater_module.UpdateError, "could not normalize.*reset denied"
        ):
            self.updater.assert_unit_quiescent("stats-billing-mirror.service")

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

    def test_stats_mirror_may_share_coordinator_database_once(self):
        install = self.updater.install_root
        install.mkdir(parents=True)
        coordinator = install / "coordinator.yaml"
        gateway = install / "gateway.yaml"
        stats_fragment = self.root / "stats-billing-mirror.service"
        stats_dropin = self.root / updater_module.TRANSACTION_GATE_DROPIN_NAME
        coordinator_database = Path("/srv/macprovider/coordinator.sqlite")
        coordinator.write_text(f"storage:\n  db_path: {coordinator_database}\n")
        gateway.write_text("storage:\n  db_path: /srv/macprovider/gateway.sqlite\n")
        stats_fragment.write_text(
            "[Service]\nExecStart=/opt/macprovider-stats/stats-billing-mirror "
            f"--sqlite {coordinator_database}\n"
        )
        stats_dropin.write_text(updater_module.TRANSACTION_GATE_DROPIN_TEXT)
        self.updater.gateway_db = None
        self.updater.databases = ()
        self.updater.coordinator_runtime_state = updater_module.CoordinatorRuntime(coordinator, None, {})
        self.updater.gateway_config_path = mock.Mock(return_value=gateway)
        self.updater.stats_mirror_runtime = mock.Mock(
            return_value=((stats_fragment, stats_dropin), coordinator_database)
        )

        self.updater.capture_database_paths()

        self.assertEqual(
            self.updater.databases,
            (Path("/srv/macprovider/gateway.sqlite"), coordinator_database),
        )
        self.assertEqual(self.updater.gateway_db, Path("/srv/macprovider/gateway.sqlite"))
        self.assertEqual(
            set(self.updater.runtime_config_hashes),
            {coordinator, gateway, stats_fragment, stats_dropin},
        )

    def test_capture_database_paths_is_idempotent_after_runtime_capture(self):
        install = self.updater.install_root
        install.mkdir(parents=True)
        coordinator = install / "coordinator.yaml"
        gateway = install / "gateway.yaml"
        stats_fragment = self.root / "stats-billing-mirror.service"
        stats_dropin = self.root / updater_module.TRANSACTION_GATE_DROPIN_NAME
        coordinator.write_text("storage:\n  db_path: /srv/macprovider/coordinator.sqlite\n")
        gateway.write_text("storage:\n  db_path: /srv/macprovider/gateway.sqlite\n")
        stats_fragment.write_text(
            "[Service]\nExecStart=/opt/macprovider-stats/stats-billing-mirror "
            "--sqlite /srv/macprovider/coordinator.sqlite\n"
        )
        stats_dropin.write_text(updater_module.TRANSACTION_GATE_DROPIN_TEXT)
        self.updater.gateway_db = None
        self.updater.databases = ()
        self.updater.coordinator_runtime_state = updater_module.CoordinatorRuntime(coordinator, None, {})
        self.updater.gateway_config_path = mock.Mock(return_value=gateway)
        self.updater.stats_mirror_runtime = mock.Mock(
            return_value=((stats_fragment, stats_dropin), Path("/srv/macprovider/coordinator.sqlite"))
        )

        self.updater.capture_database_paths()
        captured_paths = self.updater.databases
        captured_hashes = dict(self.updater.runtime_config_hashes)
        self.updater.capture_database_paths()

        self.assertEqual(self.updater.gateway_db, Path("/srv/macprovider/gateway.sqlite"))
        self.assertEqual(self.updater.databases, captured_paths)
        self.assertEqual(self.updater.runtime_config_hashes, captured_hashes)

    def test_capture_database_paths_accepts_journal_restored_state(self):
        gateway = Path("/srv/macprovider/gateway.sqlite")
        coordinator = Path("/srv/macprovider/coordinator.sqlite")
        config = Path("/opt/macprovider/coordinator.yaml")
        config_hash = "a" * 64
        self.updater.gateway_db = gateway
        self.updater.databases = (gateway, coordinator)
        self.updater.runtime_config_hashes = {config: config_hash}

        self.updater.capture_database_paths()

        self.assertEqual(self.updater.gateway_db, gateway)
        self.assertEqual(self.updater.databases, (gateway, coordinator))
        self.assertEqual(self.updater.runtime_config_hashes, {config: config_hash})

    def test_stats_mirror_cannot_share_gateway_database(self):
        install = self.updater.install_root
        install.mkdir(parents=True)
        coordinator = install / "coordinator.yaml"
        gateway = install / "gateway.yaml"
        gateway_database = Path("/srv/macprovider/gateway.sqlite")
        coordinator.write_text("storage:\n  db_path: /srv/macprovider/coordinator.sqlite\n")
        gateway.write_text(f"storage:\n  db_path: {gateway_database}\n")
        self.updater.gateway_db = None
        self.updater.databases = ()
        self.updater.coordinator_runtime_state = updater_module.CoordinatorRuntime(coordinator, None, {})
        self.updater.gateway_config_path = mock.Mock(return_value=gateway)
        self.updater.stats_mirror_runtime = mock.Mock(
            return_value=((self.root / "stats.service", self.root / "gate.conf"), gateway_database)
        )

        with self.assertRaisesRegex(updater_module.UpdateError, "cannot read the gateway database"):
            self.updater.capture_database_paths()

    def test_gateway_and_coordinator_databases_must_remain_distinct(self):
        install = self.updater.install_root
        install.mkdir(parents=True)
        coordinator = install / "coordinator.yaml"
        gateway = install / "gateway.yaml"
        shared_database = Path("/srv/macprovider/shared.sqlite")
        coordinator.write_text(f"storage:\n  db_path: {shared_database}\n")
        gateway.write_text(f"storage:\n  db_path: {shared_database}\n")
        self.updater.gateway_db = None
        self.updater.databases = ()
        self.updater.coordinator_runtime_state = updater_module.CoordinatorRuntime(coordinator, None, {})
        self.updater.gateway_config_path = mock.Mock(return_value=gateway)
        self.updater.stats_mirror_runtime = mock.Mock(
            return_value=((self.root / "stats.service", self.root / "gate.conf"), Path("/srv/macprovider/stats.sqlite"))
        )

        with self.assertRaisesRegex(updater_module.UpdateError, "gateway and coordinator"):
            self.updater.capture_database_paths()

    def test_runtime_database_parser_rejects_relative_or_duplicate_paths(self):
        with self.assertRaisesRegex(updater_module.UpdateError, "absolute path"):
            self.updater._database_path("gateway.db", "gateway storage.db_path")
        self.updater.gateway_db = self.root / "same.sqlite"
        self.updater.databases = (self.root / "other.sqlite", self.root / "other.sqlite")
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
            updater_module.CatalogRelease(
                "test-catalog",
                "autotune-policy-v1",
                {
                    name: updater_module.sha256_file(self.bundle / name)
                    for name in updater_module.CATALOG_ASSETS
                },
            ),
            updater_module.ProviderAdmissionRollout("bridge_required", False, 86400),
            work,
            updater_module.RELEASE_LANE_RUNTIME_WITH_CATALOG,
        )
        for name in updater_module.CATALOG_ASSETS:
            shutil.copyfile(self.bundle / name, work / name)
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

    def test_transaction_gate_blocks_every_start_during_tier2_enforcement(self):
        enforcement_journal = self.root / "enforcement-state"
        enforcement_journal.mkdir(mode=0o700)
        journal = enforcement_journal / "tier2-enforcement-transaction.json"
        journal.write_text(
            json.dumps(
                {
                    "schema_version": "macprovider-tier2-enforcement-transaction-v1",
                    "transaction_id": "e" * 64,
                    "phase": "applied",
                }
            )
            + "\n"
        )
        journal.chmod(0o600)
        gate = SCRIPT.with_name("macprovider-pearl-update-gate")
        result = subprocess.run(
            [str(gate), "macprovider-coordinator.service"],
            text=True,
            capture_output=True,
            timeout=10,
            env={
                **os.environ,
                "MACPROVIDER_UPDATER_GATE_TESTING": "1",
                "PEARL_UPDATER_GATE_JOURNAL": str(self.updater.journal_path),
                "PEARL_UPDATER_GATE_ENFORCEMENT_JOURNAL": str(journal),
                "PEARL_UPDATER_GATE_ROOT": str(self.updater.gate_state_root),
                "PEARL_UPDATER_GATE_BOOT_ID": str(self.boot_id),
                "PEARL_UPDATER_GATE_LOCK": str(self.updater.lock_path),
            },
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("active Tier-2 enforcement transaction blocks", result.stderr)

    def test_start_permit_is_removed_when_directory_sync_fails_after_publish(self):
        release = self.verify()
        self.updater._start_journal(release, updater_module.SemVer.parse("1.8.26"))
        permit = self.updater._permit_path("macprovider-coordinator.service")
        real_fsync_directory = updater_module._fsync_directory
        permit_sync_calls = 0

        def fail_first_permit_sync(path):
            nonlocal permit_sync_calls
            if path == permit.parent:
                permit_sync_calls += 1
                if permit_sync_calls == 1:
                    raise OSError("simulated directory fsync failure")
            return real_fsync_directory(path)

        with (
            mock.patch.object(
                updater_module,
                "_fsync_directory",
                side_effect=fail_first_permit_sync,
            ),
            self.assertRaisesRegex(OSError, "simulated directory fsync failure"),
        ):
            self.updater.issue_start_permit("macprovider-coordinator.service")

        self.assertEqual(permit_sync_calls, 2)
        self.assertFalse(permit.exists())

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

    def test_phase_journal_persists_buyer_canary_mode_for_reconciliation(self):
        release = self.verify()
        self.updater.config = updater_module.dataclasses.replace(
            self.updater.config,
            buyer_canary_mode=updater_module.BUYER_CANARY_MODE_DISABLED,
        )
        self.updater._start_journal(release, updater_module.SemVer.parse("1.8.26"))

        payload = json.loads(self.updater.journal_path.read_text())
        self.assertEqual(
            payload["buyer_canary_mode"],
            updater_module.BUYER_CANARY_MODE_DISABLED,
        )

        self.updater.config = updater_module.dataclasses.replace(
            self.updater.config,
            buyer_canary_mode=updater_module.BUYER_CANARY_MODE_REQUIRED,
        )
        self.assertTrue(self.updater.reconcile())
        self.assertEqual(
            self.updater.config.buyer_canary_mode,
            updater_module.BUYER_CANARY_MODE_DISABLED,
        )

    def test_phase_journal_restores_protected_fleet_model_baseline(self):
        release = self.verify()
        protected_fleet = [
            {"provider_id": "provider-a", "model_id": "model-a"},
            {"provider_id": "provider-b", "model_id": "model-b"},
        ]
        self.updater._start_journal(release, updater_module.SemVer.parse("1.8.26"))
        self.updater.journal.update(
            {
                "previous_protected_providers": ["provider-a", "provider-b"],
                "previous_protected_fleet": protected_fleet,
            }
        )
        self.updater._journal_transition("runtime_state_captured")

        self.assertTrue(self.updater.reconcile())
        self.assertEqual(self.updater.previous_protected_providers, ["provider-a", "provider-b"])
        self.assertEqual(self.updater.previous_protected_fleet, protected_fleet)

    def test_reconcile_rejects_mismatched_protected_fleet_model_baseline(self):
        release = self.verify()
        self.updater._start_journal(release, updater_module.SemVer.parse("1.8.26"))
        self.updater.journal.update(
            {
                "previous_protected_providers": ["provider-a"],
                "previous_protected_fleet": [
                    {"provider_id": "provider-b", "model_id": "model-b"},
                ],
            }
        )
        self.updater._journal_transition("runtime_state_captured")

        with self.assertRaisesRegex(
            updater_module.UpdateError,
            "model baseline mismatches protected identities",
        ):
            self.updater.reconcile()

    def test_reconcile_rejects_invalid_journal_buyer_canary_mode(self):
        release = self.verify()
        self.updater._start_journal(release, updater_module.SemVer.parse("1.8.26"))
        self.updater.journal["buyer_canary_mode"] = "unexpected"
        self.updater._journal_transition("prepared")

        with self.assertRaisesRegex(
            updater_module.UpdateError,
            "phase journal buyer canary mode is invalid",
        ):
            self.updater.reconcile()

    def test_reconcile_committed_success_moves_forward_to_candidate(self):
        release = self.stage(self.verify())
        self.install_coherent_pair(release)
        expected_digest, expected_signer = self.updater.catalog_candidate_identity(release)
        expected_row_identity = "b" * 64
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
        self.updater.systemctl = mock.Mock()
        self.updater.service_active = mock.Mock(return_value=True)
        self.updater.local_coordinator_ready = mock.Mock(return_value=True)
        self.updater.local_gateway_ready = mock.Mock(return_value=True)
        self.updater.assert_effective_tier2_catalog_path = mock.Mock()
        self.updater.restore_auxiliary_services = mock.Mock()
        self.updater.prove_serving_recovery = mock.Mock()
        self.updater.verify_provider_admission_rollout_policy = mock.Mock()
        self.updater.verify_exact_catalog_admission = mock.Mock()
        self.updater.verify_buyer_canary_rollout_posture = mock.Mock()
        self.updater.verify_live_runtime_binding = mock.Mock()
        self.updater.restore_auxiliary_timers = mock.Mock()
        self.updater._restore_canary_timer = mock.Mock()
        self.updater.validate_catalog_canary_configuration = mock.Mock(
            return_value=("catalog-canary", "t" * 32)
        )
        self.updater.prove_catalog_canary_mac = mock.Mock(
            return_value=updater_module.CatalogCanaryEvidence(
                row_identity=expected_row_identity,
                assigned_id="session-canary",
                catalog_key="llama-3.2-3b-instruct",
                model_id="mlx-community/Llama-3.2-3B-Instruct-4bit",
            )
        )
        self.updater.get_authorized_json = mock.Mock(
            return_value={
                "provider_id": "catalog-canary",
                "assigned_id": "session-canary",
                "buyer_serving": True,
                "catalog_evidence_source": "provider_reported",
                "catalog_admission_mode": "current",
                "catalog_release_id": release.catalog.release_id,
                "catalog_policy_version": release.catalog.policy_version,
                "catalog_candidate_sha256": expected_digest,
                "catalog_signer_key_id": expected_signer,
                "catalog_row_identity": expected_row_identity,
            }
        )
        self.updater.wait_for = (
            lambda _description, _timeout, check: self.assertTrue(check())
        )
        self.updater.restore_transaction = mock.Mock()
        self.updater.restore_previous_services = mock.Mock()
        self.updater.restore_deadman_monitoring = mock.Mock(
            side_effect=lambda: setattr(self.updater, "deadman_restore_required", False)
        )

        self.assertTrue(self.updater.reconcile())

        self.updater.prove_catalog_canary_mac.assert_called_once()
        canary_release = self.updater.prove_catalog_canary_mac.call_args.args[0]
        self.assertEqual(canary_release.directory, Path("/committed-release"))
        self.assertEqual(
            self.updater.prove_catalog_canary_mac.call_args.args[2:],
            (expected_digest, expected_signer),
        )
        self.updater.get_authorized_json.assert_called_once()
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
            "catalog": "_restore_catalog",
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
        self.updater.verify_buyer_canary_rollout_posture = mock.Mock()
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
        self.assertFalse(config.allow_private_acceptance)
        self.assertEqual(config.canary_timeout_s, 720)
        self.assertEqual(
            config.buyer_canary_mode,
            updater_module.BUYER_CANARY_MODE_REQUIRED,
        )
        self.assertEqual(config.provider_recovery_timeout_s, 900)
        self.assertEqual(config.catalog_canary_ssh_port, 22)
        self.assertEqual(config.provider_admission_policy, "")
        self.assertEqual(config.minimum_pool_ready_after_rollout, 0)
        self.assertEqual(config.minimum_bridge_remaining_s, 0)

    def test_config_explicitly_enables_private_acceptance(self):
        path = self.root / "private-acceptance.conf"
        path.write_text("PEARL_UPDATER_ALLOW_PRIVATE_ACCEPTANCE=1\n")
        config = updater_module.load_config(path)
        self.assertTrue(config.allow_private_acceptance)

    def test_config_explicitly_selects_disabled_buyer_canary_mode(self):
        path = self.root / "buyer-canary-disabled.conf"
        path.write_text("PEARL_UPDATER_BUYER_CANARY_MODE=disabled\n")
        config = updater_module.load_config(path)
        self.assertEqual(
            config.buyer_canary_mode,
            updater_module.BUYER_CANARY_MODE_DISABLED,
        )

    def test_config_rejects_unknown_buyer_canary_mode(self):
        path = self.root / "buyer-canary-invalid.conf"
        path.write_text("PEARL_UPDATER_BUYER_CANARY_MODE=optional\n")
        with self.assertRaisesRegex(updater_module.UpdateError, "buyer canary mode"):
            updater_module.load_config(path)

    def test_config_accepts_bounded_catalog_canary_ssh_port(self):
        path = self.root / "catalog-canary-ssh-port.conf"
        path.write_text("PEARL_UPDATER_CATALOG_CANARY_SSH_PORT=2222\n")
        config = updater_module.load_config(path)
        self.assertEqual(config.catalog_canary_ssh_port, 2222)

        for invalid in ("0", "65536", "not-a-port"):
            with self.subTest(invalid=invalid):
                path.write_text(
                    f"PEARL_UPDATER_CATALOG_CANARY_SSH_PORT={invalid}\n"
                )
                with self.assertRaisesRegex(
                    updater_module.UpdateError,
                    "catalog canary SSH port",
                ):
                    updater_module.load_config(path)

    def test_no_sanction_recovery_or_internal_canary_enablement(self):
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("/admin/reject", source)
        self.assertNotIn("canary_enabled", source)

    def test_runbook_requires_load_credentials_and_keeps_legacy_controls_absent(self):
        runbook = SCRIPT.parent.parent / "runbooks" / "pearl-release-updater.md"
        text = runbook.read_text(encoding="utf-8")
        self.assertIn("/etc/macprovider/canary-buyer.token", text)
        self.assertIn("/etc/macprovider/canary-buyer.heartbeat", text)
        self.assertIn("/etc/macprovider/canary-buyer.operator-token", text)
        self.assertIn("/etc/macprovider/canary-buyer.expected-fleet.json", text)
        self.assertIn("/etc/macprovider-canary-buyer/enabled", text)
        self.assertIn(
            "sudo test ! -e /etc/macprovider/canary-buyer.enabled",
            text,
        )
        self.assertIn("/var/lib/macprovider-canary-buyer/DISABLED", text)
        self.assertIn("test ! -e /etc/macprovider/canary-buyer.env", text)
        self.assertIn(
            "sudo -u macprovider -g macprovider /usr/local/sbin/macprovider-pearl-updater-alert",
            text,
        )
        self.assertNotIn("test -s /etc/macprovider/canary-buyer.env", text)
        self.assertIn("PEARL_UPDATER_PROVIDER_RECOVERY_TIMEOUT_S=900", text)
        self.assertIn("PEARL_UPDATER_SERVICE_HEALTH_TIMEOUT_S=60", text)
        self.assertIn("PEARL_UPDATER_MINIMUM_BRIDGE_REMAINING_S=1200", text)
        self.assertIn(
            "grep -Fx 'PEARL_UPDATER_PROVIDER_RECOVERY_TIMEOUT_S=900'",
            text,
        )
        self.assertIn("Pearl has four separate release/config sources of truth", text)
        self.assertIn("**Pearl runtime release**", text)
        self.assertIn('release_lane: "pearl_runtime"', text)
        self.assertIn("**Provider app release**", text)
        self.assertIn("**Catalog/feed release**", text)
        self.assertIn("**Pearl config release/reconciliation**", text)
        self.assertIn("the updater leaves `tier2.catalog_path` unchanged", text)
        self.assertIn("reported as missing Pearl\nruntime assets", text)
        self.assertIn("CONFIG_MODE=preserve-live", text)

        example = SCRIPT.parent / "pearl-updater.conf.example"
        example_text = example.read_text(encoding="utf-8")
        self.assertIn("PEARL_UPDATER_PROVIDER_RECOVERY_TIMEOUT_S=900", example_text)
        self.assertIn("PEARL_UPDATER_SERVICE_HEALTH_TIMEOUT_S=60", example_text)
        self.assertIn("PEARL_UPDATER_MINIMUM_BRIDGE_REMAINING_S=1200", example_text)
        self.assertIn("PEARL_UPDATER_BUYER_CANARY_MODE=required", example_text)

    def test_catalog_runbook_splits_deploy_authority_and_has_executable_bridge_rollback(self):
        runbook = SCRIPT.parent.parent / "runbooks" / "catalog-release-provider-upgrade.md"
        text = runbook.read_text(encoding="utf-8")
        self.assertIn("### 6.2 Signed updater: backend pair plus catalog", text)
        self.assertIn("### 6.3 Direct deploy: catalog/config validation only", text)
        self.assertIn('MACPROVIDER_VERSION="$PRIOR_PROVIDER_TAG"', text)
        self.assertIn("root-owned inventory", text)
        self.assertIn("Coordinator autoupdate remains upgrade-only", text)
        self.assertEqual(text.count("## 6. Pearl deployment"), 1)

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
        enforcement_boot = SCRIPT.with_name(
            "macprovider-tier2-enforcement-reconcile.service"
        ).read_text(encoding="utf-8")
        self.assertIn(
            "ConditionPathExists=/var/lib/macprovider-pearl-updater/"
            "tier2-enforcement-transaction.json",
            enforcement_boot,
        )
        self.assertIn(
            "ExecStart=/usr/local/sbin/macprovider-tier2-enforcement-watchdog --reconcile",
            enforcement_boot,
        )
        self.assertIn(
            "Before=macprovider-pearl-updater-reconcile.service "
            "macprovider-coordinator.service macprovider-gateway.service",
            enforcement_boot,
        )
        self.assertIn("Restart=on-failure", enforcement_boot)
        self.assertIn("RestartSec=30s", enforcement_boot)
        self.assertIn("StartLimitIntervalSec=0", enforcement_boot)
        self.assertIn("WantedBy=multi-user.target", enforcement_boot)
        alert = SCRIPT.with_name("macprovider-pearl-updater-alert@.service").read_text(encoding="utf-8")
        self.assertIn("User=macprovider", alert)
        self.assertIn("Group=macprovider", alert)
        self.assertIn("ExecStart=/usr/local/sbin/macprovider-pearl-updater-alert %i", alert)
        for hardened in (unit, boot, enforcement_boot):
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
        self.assertTrue(
            (prefix / "usr/local/sbin/macprovider-tier2-enforcement-watchdog").is_file()
        )
        self.assertTrue(
            (
                prefix
                / "etc/systemd/system/macprovider-tier2-enforcement-reconcile.service"
            ).is_file()
        )
        self.assertTrue((prefix / "usr/local/share/macprovider/scripts/catalog-release.py").is_file())
        self.assertTrue((prefix / "usr/local/share/macprovider/scripts/sign-catalog.go").is_file())
        self.assertTrue((prefix / "usr/local/share/macprovider/catalog-canary-proof.py").is_file())
        installer = SCRIPT.with_name("install-pearl-updater.sh").read_text(encoding="utf-8")
        self.assertIn("useradd --system --gid macprovider-updater-validate", installer)
        self.assertIn(
            "systemctl enable macprovider-tier2-enforcement-reconcile.service",
            installer,
        )
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
