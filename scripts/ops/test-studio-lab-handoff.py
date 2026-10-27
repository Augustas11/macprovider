#!/usr/bin/env python3
"""Small offline contract checks for studio-lab-handoff.py."""
import importlib.util
import io
import hashlib
import json
import os
from pathlib import Path
import tempfile
from contextlib import redirect_stdout

ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / "scripts/ops/studio-lab-handoff.py"
spec = importlib.util.spec_from_file_location("handoff", TARGET)
assert spec and spec.loader
handoff = importlib.util.module_from_spec(spec)
spec.loader.exec_module(handoff)


def manifest(**changes):
    value = {
        "schema_version": handoff.SCHEMA, "all_cells_complete": True, "root_arm": True,
        "lock_owner": "codex-xfamily-regress",
        "studio": {
            "handoff_path": "/Users/operator/.config/macprovider/ops-state/lab-block-handoff.json",
            "journal_path": "/Users/operator/.config/macprovider/ops-state/studio-lab-handoff-recovery.json",
            "install_dir": "/Users/operator/macprovider", "config_path": "/Users/operator/.config/macprovider/config.yaml",
            "provider_plist_path": "/Users/operator/Library/LaunchAgents/live.malibu.provider.plist",
            "watchdog_plist_path": "/Users/operator/Library/LaunchAgents/live.malibu.provider-watchdog.plist",
            "control_socket": "/Users/operator/.config/macprovider/ctl.sock", "status_port": 8080,
            "launch_label": "live.malibu.provider", "watchdog_label": "live.malibu.provider-watchdog",
            "hardware_model": "Mac15,14", "binary_version": "1.8.274", "model": "zai-org/glm-5.3-flash",
            "binary_sha256": "a" * 64, "config_sha256": "b" * 64,
            "provider_plist_sha256": "c" * 64, "watchdog_plist_sha256": "d" * 64,
            "handoff_sha256": "e" * 64,
        }, "pearl": {"runner_unit": handoff.RUNNER},
    }
    value.update(changes)
    return value


def rejected(path, needle):
    try:
        handoff.load_manifest(path)
    except handoff.Refusal as exc:
        assert needle in str(exc), exc
    else:
        raise AssertionError("manifest unexpectedly accepted")


class Mocks:
    def __init__(self, events, *, runner_active=False, runner_failure=False, recover_error=None):
        self.events = events
        self.runner_active = runner_active
        self.runner_failure = runner_failure
        self.recover_error = recover_error

    def remote(self, _host, _manifest, _digest, action, **_kwargs):
        self.events.append(f"studio:{action}")
        if action == "inspect":
            return {"ok": True, "handoff": {"studio_state": "paused_live_unloaded", "runner": "stopped"},
                    "journal_phase": None, "provider_loaded": False, "watchdog_loaded": False,
                    "provider_processes": []}
        if action == "recover":
            if self.recover_error:
                raise handoff.Refusal(self.recover_error)
            self.events.append("studio:watchdog_verified")
            return {"ok": True, "phase": "provider_stable", "status": {}}
        if action == "provenance":
            return {"ok": True, "installed": {}, "launch": {}, "status": {}}
        if action == "finish":
            return {"ok": True, "phase": "restored", "status": {}}
        raise AssertionError(action)

    def ssh(self, host, _program, payload, **_kwargs):
        assert host == "pearl-test"
        self.events.append(f"pearl:{payload['action']}")
        if payload["action"] == "status":
            return {"ok": True, "runner_active": self.runner_active}
        assert payload == {"action": "start", "unit": handoff.RUNNER}
        if self.runner_failure:
            raise handoff.Refusal("runner start failed")
        self.runner_active = True
        return {"ok": True, "runner_active": True}


def install(mocks, events):
    original = (handoff.remote_action, handoff.ssh, handoff.acquire_lock, handoff.verify_published)
    handoff.remote_action = mocks.remote
    handoff.ssh = mocks.ssh
    handoff.acquire_lock = lambda owner: events.append(f"lock:{owner}")
    handoff.verify_published = lambda version, probe, install: events.append(
        f"published:{version}:{install}")
    return original


def restore(original):
    handoff.remote_action, handoff.ssh, handoff.acquire_lock, handoff.verify_published = original


with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / "manifest.json"
    inherited_handoff = Path(tmp) / "lab-block-handoff.json"
    handoff_bytes = b'{"at":"2026-10-27T00:00:00Z","from":"codex-2111-dsv4","runner":"stopped","studio_state":"paused_live_unloaded"}\n'
    inherited_handoff.write_bytes(handoff_bytes)
    raw_manifest = manifest()
    raw_manifest["studio"]["handoff_path"] = str(inherited_handoff)
    raw_manifest["studio"]["handoff_sha256"] = hashlib.sha256(handoff_bytes).hexdigest()
    path.write_text(json.dumps(raw_manifest))
    os.chmod(path, 0o600)
    value, digest = handoff.load_manifest(path)
    assert value["studio"]["binary_version"] == "1.8.274"
    assert len(digest) == 64
    previous_state = os.environ.get("MACPROVIDER_OPS_STATE_DIR")
    os.environ["MACPROVIDER_OPS_STATE_DIR"] = tmp
    handoff.write_local_journal(digest, "runner_starting")
    assert handoff.local_phase(digest) == "runner_starting"
    try:
        handoff.local_phase("f" * 64)
    except handoff.Refusal as exc:
        assert "does not belong" in str(exc)
    else:
        raise AssertionError("foreign local journal unexpectedly accepted")
    if previous_state is None:
        del os.environ["MACPROVIDER_OPS_STATE_DIR"]
    else:
        os.environ["MACPROVIDER_OPS_STATE_DIR"] = previous_state
    path.write_text(json.dumps(manifest(all_cells_complete=False)))
    rejected(path, "all-cells complete")
    path.write_text(json.dumps(manifest(root_arm=False)))
    rejected(path, "all-cells complete")
    bad = manifest(); bad["studio"]["binary_version"] = "1.8.260"
    path.write_text(json.dumps(bad))
    rejected(path, "1.8.274")
    bad = manifest(); bad["pearl"] = {"runner_unit": "anything.service"}
    path.write_text(json.dumps(bad))
    rejected(path, "runner_unit")
    bad = manifest(); bad["studio"]["config_path"] = "/Users/operator/../tmp/config"
    path.write_text(json.dumps(bad))
    rejected(path, "unsafe path")
    os.chmod(path, 0o644)
    rejected(path, "private regular")


with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / "manifest.json"
    inherited_handoff = Path(tmp) / "lab-block-handoff.json"
    handoff_bytes = b'{"at":"2026-10-27T00:00:00Z","from":"codex-2111-dsv4","runner":"stopped","studio_state":"paused_live_unloaded"}\n'
    inherited_handoff.write_bytes(handoff_bytes)
    raw_manifest = manifest()
    raw_manifest["studio"]["handoff_path"] = str(inherited_handoff)
    raw_manifest["studio"]["handoff_sha256"] = hashlib.sha256(handoff_bytes).hexdigest()
    path.write_text(json.dumps(raw_manifest))
    os.chmod(path, 0o600)
    loaded, digest = handoff.load_manifest(path)
    saved_env = {key: os.environ.get(key) for key in (
        "STUDIO_SSH", "PEARL_SSH", "MACPROVIDER_OPS_OWNER", "MACPROVIDER_OPS_STATE_DIR",
        "MACPROVIDER_OPS_ENV")}
    os.environ.update({"STUDIO_SSH": "studio-test", "PEARL_SSH": "pearl-test",
                       "MACPROVIDER_OPS_OWNER": "codex-xfamily-regress",
                       "MACPROVIDER_OPS_STATE_DIR": tmp, "MACPROVIDER_OPS_ENV": "/dev/null"})
    try:
        # status and bare next only inspect Studio state: neither touches the lock, runner nor journal.
        events = []
        mocks = Mocks(events)
        original = install(mocks, events)
        try:
            with redirect_stdout(io.StringIO()):
                handoff.main(["status", "--manifest", str(path)])
            with redirect_stdout(io.StringIO()):
                handoff.main(["next", "--manifest", str(path)])
            assert events == ["studio:inspect", "studio:inspect"], events
            assert not (Path(tmp) / "studio-lab-handoff-recovery.json").exists()
            assert inherited_handoff.read_bytes() == handoff_bytes
        finally:
            restore(original)

        # Immutable snapshot drift and a foreign provider both stop before Pearl can be touched.
        for refusal in ("immutable config hash differs", "foreign provider process"):
            events = []
            mocks = Mocks(events, recover_error=refusal)
            original = install(mocks, events)
            try:
                try:
                    handoff.run_restore(loaded, digest)
                except handoff.Refusal as exc:
                    assert refusal in str(exc)
                else:
                    raise AssertionError("drift unexpectedly proceeded")
                assert events == ["lock:codex-xfamily-regress", "pearl:status", "studio:recover"], events
                assert handoff.local_phase(digest) == "armed"
                assert inherited_handoff.read_bytes() == handoff_bytes
            finally:
                restore(original)

        # A runner failure retains the durable provider state and never calls finish.
        events = []
        mocks = Mocks(events, runner_failure=True)
        original = install(mocks, events)
        try:
            try:
                handoff.run_restore(loaded, digest)
            except handoff.Refusal as exc:
                assert "runner start failed" in str(exc)
            else:
                raise AssertionError("runner failure unexpectedly completed")
            assert events == ["lock:codex-xfamily-regress", "pearl:status", "studio:recover",
                              "studio:watchdog_verified", "studio:provenance",
                              f"published:1.8.274:{loaded['studio']['install_dir']}", "pearl:start"], events
            assert handoff.local_phase(digest) == "runner_starting"
            assert inherited_handoff.read_bytes() == handoff_bytes
        finally:
            restore(original)

        # A retry after the runner-start intent is idempotent: active runner is accepted only
        # because the matching durable journal exists, and it is never started before watchdog proof.
        events = []
        mocks = Mocks(events, runner_active=True)
        original = install(mocks, events)
        try:
            result = handoff.run_restore(loaded, digest)
            assert result["phase"] == "restored" and result["handoff_retained"] is True
            assert events.index("studio:watchdog_verified") < events.index("pearl:start") < events.index("studio:finish")
            assert handoff.local_phase(digest) == "restored"
            assert inherited_handoff.read_bytes() == handoff_bytes
        finally:
            restore(original)
    finally:
        for key, value in saved_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

print("studio-lab-handoff offline manifest guards: PASS")
