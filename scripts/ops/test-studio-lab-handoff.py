#!/usr/bin/env python3
"""Small offline contract checks for studio-lab-handoff.py."""
import importlib.util
import io
import hashlib
import json
import os
import subprocess
from pathlib import Path
import tempfile
from types import SimpleNamespace
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
            assert _kwargs.get("timeout", "missing") is None, "recovery has an elapsed-time ceiling"
            if self.recover_error:
                raise handoff.Refusal(self.recover_error)
            self.events.append("studio:watchdog_verified")
            return {"ok": True, "phase": "provider_stable", "status": {}}
        if action in {"provenance", "static_provenance"}:
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

        # A failed published-release proof cannot bootstrap/resume any provider.
        events = []
        mocks = Mocks(events)
        original = install(mocks, events)
        def reject_published(*_):
            raise handoff.Refusal("unpublished binary")
        handoff.verify_published = reject_published
        try:
            try:
                handoff.run_restore(loaded, digest)
            except handoff.Refusal as exc:
                assert "unpublished" in str(exc)
            else:
                raise AssertionError("unpublished binary proceeded")
            assert "studio:static_provenance" in events and "studio:recover" not in events
        finally:
            restore(original)

        # Failed retries preserve an already-durable runner intent, including when
        # the runner is active and the error happens before the provider is rechecked.
        for phase in ("runner_starting", "runner_active", "restored"):
            handoff.write_local_journal(digest, phase)
            events = []
            mocks = Mocks(events, runner_active=True, recover_error="transient recovery refusal")
            original = install(mocks, events)
            try:
                try:
                    handoff.run_restore(loaded, digest)
                except handoff.Refusal as exc:
                    assert "transient" in str(exc)
                else:
                    raise AssertionError("recovery failure unexpectedly proceeded")
                assert handoff.local_phase(digest) == phase
                assert "pearl:start" not in events
            finally:
                restore(original)
        handoff.write_local_journal(digest, "armed")

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
                assert events == ["lock:codex-xfamily-regress", "pearl:status", "studio:static_provenance",
                                  f"published:1.8.274:{loaded['studio']['install_dir']}", "studio:recover"], events
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
            assert events == ["lock:codex-xfamily-regress", "pearl:status", "studio:static_provenance",
                              f"published:1.8.274:{loaded['studio']['install_dir']}", "studio:recover",
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

def remote_recovery_case(*, phase="provider_bootstrapped", watchdog=False,
                         ready_after=0, log_progress=False, die_at=None, changed_pid=False):
    """Execute the real embedded recovery loop with only OS boundaries mocked."""
    namespace = {}
    exec(handoff.REMOTE, namespace)
    clock = [0]
    journal = {"schema_version": handoff.SCHEMA, "manifest_sha256": "digest", "phase": phase,
               "provider_pid": 41 if phase == "provider_stable" else None,
               "provider_start_us": 42 if phase == "provider_stable" else None}
    x = manifest()["studio"]
    namespace.update(check_static=lambda _: "/binary", handoff=lambda _: None,
                     load_journal=lambda *_: journal, put=lambda *_: None,
                     launch_loaded=lambda label: label == x["launch_label"] or watchdog,
                     cli_processes=lambda _: [] if die_at is not None and clock[0] >= die_at else [41],
                     resume=lambda _: None,
                     provider_log_progress=lambda _: (clock[0] if log_progress else 0,))
    def snapshot(_):
        return {"binary_version": x["binary_version"], "model": x["model"],
                "model_loaded": clock[0] >= ready_after, "network_state": "buyer_serving",
                "continuous_batching": {"active": True, "policy": {"cached_turns_authorized": True}},
                "service_instance": {"pid": 99 if changed_pid else 41, "process_start_us": 42}}
    def launch(*_args, **_kwargs):
        nonlocal watchdog
        watchdog = True
    namespace.update(status=snapshot, subprocess=SimpleNamespace(run=launch),
                     os=SimpleNamespace(path=SimpleNamespace(exists=lambda _: True), getuid=lambda: 501),
                     time=SimpleNamespace(monotonic=lambda: clock[0], sleep=lambda seconds: clock.__setitem__(0, clock[0] + seconds)))
    return namespace, x, clock


# The embedded prelaunch action only observes immutable installed identity; it has
# no provider process claim and cannot bootstrap or resume anything.
namespace = {}
exec(handoff.REMOTE, namespace)
static_events = []
namespace.update(check_static=lambda _: static_events.append("check_static") or "/binary",
                 installed_identity=lambda _: static_events.append("installed_identity") or {"binary_sha256": "a" * 64},
                 resume=lambda _: (_ for _ in ()).throw(AssertionError("static action resumed provider")),
                 subprocess=SimpleNamespace(run=lambda *_a, **_k: (_ for _ in ()).throw(AssertionError("static action launched process"))))
out = io.StringIO()
with redirect_stdout(out):
    namespace["main"](json.dumps({"action": "static_provenance", "studio": manifest()["studio"], "manifest_sha256": "digest"}))
static_result = json.loads(out.getvalue())
assert static_events == ["check_static", "installed_identity"]
assert static_result["stage"] == "prelaunch_static"
assert static_result["launch"]["pid"] is None and static_result["status"]["service_instance"]["pid"] is None

# Exercise the real shell helper's flat dotted-key extraction, rather than mocking
# verify_published. Preserve the native nested status alongside the adapter field.
namespace, x, clock = remote_recovery_case(phase="provider_stable", watchdog=True)
namespace["installed_identity"] = lambda _: {"binary_sha256": "a" * 64}
live_result = namespace["provenance"](x, "digest")
helper = ROOT / "scripts/ops/lib/published-provider-identity.sh"
for result, expected in ((static_result, ""), (live_result, "41")):
    assert result["status"]["service_instance"]["pid"] == result["launch"]["pid"]
    script = '. "$1"; probe="$(cat)"; _published_provider_json_get "$probe" \'d["launch"]["pid"]\'; _published_provider_json_get "$probe" \'d["status"]["service_instance.pid"]\''
    extracted = subprocess.run(["bash", "-c", script, "bash", str(helper)],
                               input=json.dumps(result), text=True, capture_output=True, check=True)
    assert extracted.stdout.splitlines() == [expected, expected], extracted
namespace, x, clock = remote_recovery_case(phase="provider_stable", watchdog=True, changed_pid=True)
namespace["installed_identity"] = lambda _: {"binary_sha256": "a" * 64}
try:
    namespace["provenance"](x, "digest")
except RuntimeError as exc:
    assert "identity differs" in str(exc)
else:
    raise AssertionError("release adapter accepted a PID outside the stability journal")

# A responding, unchanged, unready status is a stall; actual new log output is progress.
namespace, x, clock = remote_recovery_case(ready_after=10000)
try:
    namespace["recover"](x, "digest")
except RuntimeError as exc:
    assert "progress" in str(exc) and clock[0] == 1800, (exc, clock)
else:
    raise AssertionError("unchanged nonready status masked the stall")
namespace, x, clock = remote_recovery_case(ready_after=2200, log_progress=True)
assert namespace["recover"](x, "digest")["phase"] == "provider_stable"
assert clock[0] >= 2320  # Longer than the former outer2040s deadline, while progressing.
namespace, x, clock = remote_recovery_case()
snapshot = namespace["status"]
def briefly_unready(port):
    value = snapshot(port)
    if clock[0] == 10:
        value["model_loaded"] = False
    return value
namespace["status"] = briefly_unready
assert namespace["recover"](x, "digest")["phase"] == "provider_stable"
assert clock[0] == 135  # Requires a new full stability interval after recovery.

# A matching stable journal survives a provenance/Pearl retry, but cannot adopt another process.
namespace, x, clock = remote_recovery_case(phase="provider_stable", watchdog=True)
assert namespace["recover"](x, "digest")["phase"] == "provider_stable"
assert clock[0] == 0
namespace, x, clock = remote_recovery_case(phase="provider_stable", watchdog=True, changed_pid=True)
try:
    namespace["recover"](x, "digest")
except RuntimeError as exc:
    assert "journal" in str(exc) or "identity" in str(exc)
else:
    raise AssertionError("stable retry adopted another provider")
namespace, x, clock = remote_recovery_case(watchdog=True)
try:
    namespace["recover"](x, "digest")
except RuntimeError as exc:
    assert "watchdog loaded before" in str(exc)
else:
    raise AssertionError("early foreign watchdog was accepted")
namespace, x, clock = remote_recovery_case(ready_after=10000, die_at=10)
try:
    namespace["recover"](x, "digest")
except RuntimeError as exc:
    assert "process" in str(exc) and clock[0] == 10, (exc, clock)
else:
    raise AssertionError("provider death did not fail immediately")

print("studio-lab-handoff offline manifest and recovery guards: PASS")
