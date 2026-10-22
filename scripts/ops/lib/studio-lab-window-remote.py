#!/usr/bin/env python3
"""Crash-recoverable remote supervisor for one fixed offline Studio diagnostic."""

from __future__ import annotations

import argparse
import ctypes
import fcntl
import hashlib
import json
import os
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path


MANIFEST_SCHEMA = "macprovider.studio_lab_window_manifest.v1"
JOURNAL_SCHEMA = "macprovider.studio_lab_window_journal.v1"
ABORT_SCHEMA = "macprovider.studio_lab_window_abort.v1"
TERMINAL_PHASE = "restored"
PHASES = (
    "prepared", "pausing", "drained", "stopping_provider", "stopped",
    "lab_running", "lab_stopped",
    "restoring_provider", "provider_ready", TERMINAL_PHASE,
)
LAUNCHCTL_TRANSITION_TIMEOUT_S = 30
LAUNCHCTL_POLL_S = 0.1
LIVE_HASH_KEYS = (
    "binary_sha256", "config_sha256", "provider_plist_sha256",
    "watchdog_plist_sha256", "compatibility_set_sha256",
)
HASH_KEYS = LIVE_HASH_KEYS + ("probe_sha256", "lab_script_sha256")
JOB_KINDS = (
    "profiler-only", "qualification", "qwen-qualification", "qwen-journey", "glm-prefill",
    "glm-parity-prefill512", "dsv4-reference", "glm-parity-prefill512-then-dsv4-reference",
)
ARTIFACT_KEYS = (
    "diagnostic_cli", "glmbench", "diagnostic_metallib", "glmbench_metallib",
    "fixture_config", "fixture_index",
)
QWEN_ARTIFACT_KEYS = (
    "diagnostic_cli", "diagnostic_metallib", "fixture_config", "fixture_index",
)
DSV4_ARTIFACT_KEYS = (
    "reference_python", "reference_script", "dsv4_fixture_config", "dsv4_fixture_index",
)
EXECUTABLE_ARTIFACT_KEYS = {"diagnostic_cli", "glmbench", "reference_python"}
# Staged measurement jobs: window ceilings and no-model preflight bounds. The
# preflight hashes every fixture in the sequence before the provider pauses.
STAGED_WINDOW_TIMEOUTS = {
    "glm-parity-prefill512": 3600,
    "dsv4-reference": 7200,
    "glm-parity-prefill512-then-dsv4-reference": 9000,
}
STAGED_VALIDATE_TIMEOUTS = {
    "glm-parity-prefill512": 900,
    "dsv4-reference": 900,
    "glm-parity-prefill512-then-dsv4-reference": 1500,
}


def job_artifact_keys(job) -> tuple[str, ...]:
    kind = job["kind"] if job is not None else None
    if kind == "dsv4-reference":
        return DSV4_ARTIFACT_KEYS
    if kind == "glm-parity-prefill512-then-dsv4-reference":
        return QWEN_ARTIFACT_KEYS + DSV4_ARTIFACT_KEYS
    if kind in ("qwen-qualification", "qwen-journey", "glm-prefill", "glm-parity-prefill512"):
        return QWEN_ARTIFACT_KEYS
    return ARTIFACT_KEYS
SNAPSHOT_KEYS = (
    "provider_id_sha256", "coordinator_origin", "compatibility_set_id",
    "binary_version", "model",
)
SNAPSHOT_HASH_KEYS = (
    "config_sha256", "provider_plist_sha256", "watchdog_plist_sha256",
    "compatibility_set_sha256",
)
MAX_JSON = 1024 * 1024
GATED_EXEC = (
    "import os,sys; fd=int(sys.argv[1]); token=os.read(fd,1); os.close(fd); "
    "script,manifest,home,path,tmp=sys.argv[2:]; "
    "argv=[script,'--offline'] if manifest == '-' else [script,'--offline','--manifest',manifest]; "
    "sys.exit(125) if token != b'1' else os.execve(script, argv, "
    "{'HOME':home,'PATH':path,'TMPDIR':tmp,'MACPROVIDER_LAB_OFFLINE':'1'})"
)


class Refusal(RuntimeError):
    pass


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fsync_dir(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def safe_regular(path: Path, *, private: bool = True) -> os.stat_result:
    try:
        info = path.lstat()
    except (FileNotFoundError, RuntimeError) as exc:
        raise Refusal(f"missing file: {path}") from exc
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
        raise Refusal(f"unsafe file: {path}")
    if private and stat.S_IMODE(info.st_mode) & 0o077:
        raise Refusal(f"file is not private: {path}")
    if path.is_symlink() or path.resolve() != path:
        raise Refusal(f"file resolves through a symlink: {path}")
    return info


def safe_directory(path: Path) -> None:
    info = path.lstat()
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.getuid()
        or stat.S_IMODE(info.st_mode) & 0o077
        or path.is_symlink()
        or path.resolve() != path
    ):
        raise Refusal(f"unsafe private directory: {path}")


def safe_owned_directory(path: Path) -> None:
    info = path.lstat()
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.getuid()
        or stat.S_IMODE(info.st_mode) & 0o022
        or path.is_symlink()
        or path.resolve() != path
    ):
        raise Refusal(f"unsafe directory: {path}")


def read_bytes(path: Path, maximum: int = MAX_JSON, *, private: bool = True) -> bytes:
    before = safe_regular(path, private=private)
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(fd)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise Refusal(f"file changed while opening: {path}")
        data = os.read(fd, maximum + 1)
    finally:
        os.close(fd)
    if len(data) > maximum or len(data) != before.st_size:
        raise Refusal(f"unsafe file size: {path}")
    return data


def read_json(path: Path, *, private: bool = True) -> dict:
    try:
        value = json.loads(read_bytes(path, private=private))
    except (OSError, ValueError) as exc:
        raise Refusal(f"invalid JSON: {path}") from exc
    if not isinstance(value, dict):
        raise Refusal(f"JSON document is not an object: {path}")
    return value


def atomic_json(path: Path, value: dict) -> None:
    safe_directory(path.parent)
    data = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    tmp = Path(name)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb", closefd=True) as out:
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
        os.replace(tmp, path)
        fsync_dir(path.parent)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


class JournalLock:
    def __init__(self, journal: Path):
        self.path = journal.with_name(f".{journal.name}.lock")
        self.fd = -1

    def __enter__(self) -> "JournalLock":
        safe_directory(self.path.parent)
        flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
        self.fd = os.open(self.path, flags, 0o600)
        info = os.fstat(self.fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
            raise Refusal("unsafe journal lock")
        os.fchmod(self.fd, 0o600)
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *_: object) -> None:
        fcntl.flock(self.fd, fcntl.LOCK_UN)
        os.close(self.fd)


def absolute(value: object, name: str) -> Path:
    if not isinstance(value, str) or not value:
        raise Refusal(f"manifest {name} is missing")
    path = Path(value)
    if not path.is_absolute() or path.resolve() != path:
        raise Refusal(f"manifest {name} is not an absolute canonical path")
    return path


def positive(value: object, name: str, maximum: int = 86400) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or not 1 <= value <= maximum:
        raise Refusal(f"manifest {name} is invalid")
    return value


def load_manifest(path: Path) -> tuple[dict, str]:
    path = absolute(str(path), "manifest")
    data = read_bytes(path)
    try:
        value = json.loads(data)
    except ValueError as exc:
        raise Refusal("manifest is invalid JSON") from exc
    if not isinstance(value, dict) or value.get("schema_version") != MANIFEST_SCHEMA:
        raise Refusal("manifest schema mismatch")
    for key in (
        "install_dir", "config_path", "provider_plist", "watchdog_plist",
        "compatibility_path", "ctl_socket", "probe_path", "owner_pin_journal",
        "lab_source_dir", "lab_script_path", "log_path",
    ):
        value[key] = str(absolute(value.get(key), key))
    for key in ("provider_label", "watchdog_label", "nonce", "lab_git_head"):
        item = value.get(key)
        if not isinstance(item, str) or not item or any(ch not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-" for ch in item):
            raise Refusal(f"manifest {key} is invalid")
    value["status_port"] = positive(value.get("status_port"), "status_port", 65535)
    for key in ("drain_timeout_s", "ready_timeout_s", "poll_s"):
        value[key] = positive(value.get(key), key)
    job = value.get("job")
    if job is not None:
        if not isinstance(job, dict) or set(job) != {"schema_version", "kind", "identity_sha256", "immutable_inputs"}:
            raise Refusal("manifest job is invalid")
        if job.get("schema_version") != "macprovider.studio_lab_window_job.v1" or job.get("kind") not in JOB_KINDS:
            raise Refusal("manifest job kind is invalid")
        identity = job.get("identity_sha256")
        if not isinstance(identity, str) or len(identity) != 64 or any(ch not in "0123456789abcdef" for ch in identity):
            raise Refusal("manifest job identity is invalid")
        if not isinstance(job.get("immutable_inputs"), dict):
            raise Refusal("manifest job immutable inputs are invalid")
        helper = absolute(value.get("job_helper_path"), "job_helper_path")
        if helper != path.parent / "manifest.py":
            raise Refusal("manifest job helper is outside the protected manifest directory")
        value["job_helper_path"] = str(helper)
    elif "job_helper_path" in value:
        raise Refusal("legacy manifest cannot name a job helper")
    value["lab_timeout_s"] = positive(
        value.get("lab_timeout_s"), "lab_timeout_s",
        STAGED_WINDOW_TIMEOUTS[job["kind"]] if job and job["kind"] in STAGED_WINDOW_TIMEOUTS else
        43200 if job and job["kind"] in ("qualification", "qwen-qualification") else (
            21600 if job and job["kind"] == "glm-prefill" else (
                7200 if job and job["kind"] == "qwen-journey" else 3600
            )
        ),
    )
    if value["ready_timeout_s"] < 120:
        raise Refusal("manifest ready_timeout_s cannot prove the 120-second serving hold")
    baseline = value.get("baseline")
    if not isinstance(baseline, dict):
        raise Refusal("manifest baseline is missing")
    for key in HASH_KEYS:
        item = baseline.get(key)
        if not isinstance(item, str) or len(item) != 64 or any(ch not in "0123456789abcdef" for ch in item):
            raise Refusal(f"manifest baseline {key} is invalid")
    if job is not None:
        helper_sha = baseline.get("job_helper_sha256")
        if not isinstance(helper_sha, str) or len(helper_sha) != 64 or any(ch not in "0123456789abcdef" for ch in helper_sha):
            raise Refusal("manifest baseline job helper hash is invalid")
    elif "job_helper_sha256" in baseline:
        raise Refusal("legacy manifest has a job helper hash")
    snapshot = baseline.get("snapshot")
    if not isinstance(snapshot, dict) or any(snapshot.get(key) in (None, "") for key in SNAPSHOT_KEYS):
        raise Refusal("manifest baseline snapshot is incomplete")
    for key in SNAPSHOT_HASH_KEYS:
        if snapshot.get(key) != baseline[key]:
            raise Refusal(f"manifest snapshot {key} does not match baseline")
    if (
        snapshot.get("model_loaded") is not True
        or snapshot.get("network_state") != "buyer_serving"
        or snapshot.get("coordinator_connected") is not True
        or snapshot.get("operator_paused") is not False
        or not isinstance(snapshot.get("pid"), int)
        or isinstance(snapshot.get("pid"), bool)
        or snapshot["pid"] <= 0
        or not isinstance(snapshot.get("process_start_us"), int)
        or isinstance(snapshot.get("process_start_us"), bool)
        or snapshot["process_start_us"] <= 0
        or snapshot.get("executable_path") != str(Path(value["install_dir"]) / "macprovider-cli")
    ):
        raise Refusal("manifest baseline is not buyer-serving")
    artifacts = value.get("artifacts")
    artifact_keys = job_artifact_keys(job)
    if not isinstance(artifacts, dict) or set(artifacts) != set(artifact_keys):
        raise Refusal("manifest artifact set is invalid")
    source = Path(value["lab_source_dir"])
    expected_artifacts = {
        "diagnostic_cli": source / "phase3-binary/.build/release/macprovider-cli",
        "glmbench": source / "scripts/lab/cb-studio/glm53-bench/.build/release/GLMBench",
        "diagnostic_metallib": source / "phase3-binary/.build/release/mlx.metallib",
        "glmbench_metallib": source / "scripts/lab/cb-studio/glm53-bench/.build/release/mlx.metallib",
        "fixture_config": source / ".lab-window/fixture/target/config.json",
        "fixture_index": source / ".lab-window/fixture/target/model.safetensors.index.json",
        "reference_python": source / ".lab-window/dsv4-venv/bin/python3",
        "reference_script": source / "scripts/lab/dsv4/dsv4_reference_bench.py",
        "dsv4_fixture_config": source / ".lab-window/fixture/dsv4-target/config.json",
        "dsv4_fixture_index": source / ".lab-window/fixture/dsv4-target/model.safetensors.index.json",
    }
    for key in artifact_keys:
        item = artifacts[key]
        if not isinstance(item, dict):
            raise Refusal(f"manifest artifact {key} is invalid")
        raw_value = item.get("path")
        if not isinstance(raw_value, str) or not raw_value or not Path(raw_value).is_absolute():
            raise Refusal(f"manifest artifact {key} path is invalid")
        if Path(raw_value) != expected_artifacts[key]:
            raise Refusal(f"manifest artifact {key} is outside its fixed path")
        item["path"] = raw_value
        expected_sha = item.get("sha256")
        if not isinstance(expected_sha, str) or len(expected_sha) != 64 or any(
            char not in "0123456789abcdef" for char in expected_sha
        ):
            raise Refusal(f"manifest artifact {key} sha256 is invalid")
    value["_manifest_path"] = str(path)
    return value, digest(data)


def file_sha(path: Path, *, private: bool = False) -> str:
    return digest(read_bytes(path, maximum=1024 * 1024 * 1024, private=private))


def validate_source(manifest: dict) -> None:
    source = Path(manifest["lab_source_dir"])
    script = Path(manifest["lab_script_path"])
    safe_owned_directory(source)
    safe_regular(script)
    if script.name != "run-window-diagnostic.sh":
        raise Refusal("lab script does not have the fixed reviewed name")
    stage = Path(manifest["_manifest_path"]).parent
    if script.parent != stage or Path(manifest["probe_path"]).parent != stage:
        raise Refusal("staged helper files are outside the protected manifest directory")
    if not os.access(script, os.X_OK):
        raise Refusal("lab script is not executable")
    head = subprocess.run(
        ["git", "-C", str(source), "rev-parse", "HEAD"], capture_output=True,
        text=True, check=True,
    ).stdout.strip()
    if head != manifest["lab_git_head"]:
        raise Refusal("lab source git head drifted")
    dirty = subprocess.run(
        ["git", "-C", str(source), "status", "--porcelain", "--untracked-files=no"],
        capture_output=True, text=True, check=True,
    ).stdout
    if dirty:
        raise Refusal("lab source has tracked modifications")


def current_live_hashes(manifest: dict) -> dict[str, str]:
    install = Path(manifest["install_dir"])
    if not install.is_dir() or install.is_symlink() or install.resolve() != install:
        raise Refusal("unsafe install directory")
    paths = {
        "binary_sha256": install / "macprovider-cli",
        "config_sha256": Path(manifest["config_path"]),
        "provider_plist_sha256": Path(manifest["provider_plist"]),
        "watchdog_plist_sha256": Path(manifest["watchdog_plist"]),
        "compatibility_set_sha256": Path(manifest["compatibility_path"]),
    }
    return {key: file_sha(path, private=False) for key, path in paths.items()}


def validate_live_hashes(manifest: dict) -> None:
    actual = current_live_hashes(manifest)
    expected = manifest["baseline"]
    moved = [key for key in LIVE_HASH_KEYS if actual[key] != expected[key]]
    if moved:
        raise Refusal("guarded bytes drifted: " + ",".join(moved))


def validate_lab_artifacts(manifest: dict) -> None:
    validate_source(manifest)
    if file_sha(Path(manifest["lab_script_path"])) != manifest["baseline"]["lab_script_sha256"]:
        raise Refusal("guarded diagnostic artifact drifted: lab_script")
    job = manifest.get("job")
    for key in job_artifact_keys(job):
        item = manifest["artifacts"][key]
        if artifact_sha(Path(item["path"]), executable=key in EXECUTABLE_ARTIFACT_KEYS) != item["sha256"]:
            raise Refusal(f"guarded diagnostic artifact drifted: {key}")
    if job is not None:
        helper = Path(manifest["job_helper_path"])
        safe_regular(helper)
        if file_sha(helper) != manifest["baseline"]["job_helper_sha256"]:
            raise Refusal("guarded job helper bytes drifted")


def validate_job(manifest: dict) -> None:
    """Run the job's own no-model validation once, before pausing service."""
    if manifest.get("job") is None:
        return
    # validate_lab_artifacts proves the staged helper before it is executable.
    validate_lab_artifacts(manifest)
    subprocess.run(
        [sys.executable, manifest["job_helper_path"], "validate-job", "--manifest", manifest["_manifest_path"]],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        # The helper bounds its own fixed no-model validation at 600 seconds;
        # retain a small outer allowance for Python process startup/cleanup.
        # Staged jobs hash their whole fixtures here, before the pause.
        check=True, timeout=STAGED_VALIDATE_TIMEOUTS.get(manifest["job"]["kind"], 660),
        env={"HOME": str(Path.home()), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
    )


def validate_journal_job(manifest: dict, record: dict) -> None:
    """Bind a durable journal to the staged job, while retaining v1 journals."""
    job = manifest.get("job")
    if job is None:
        if "job_kind" in record or "job_identity_sha256" in record:
            raise Refusal("legacy journal unexpectedly names a job")
        return
    if (
        record.get("job_kind") != job["kind"]
        or record.get("job_identity_sha256") != job["identity_sha256"]
    ):
        raise Refusal("journal job identity mismatch")


def artifact_sha(path: Path, *, executable: bool) -> str:
    try:
        target = path.resolve(strict=True)
    except FileNotFoundError as exc:
        raise Refusal(f"missing file: {path}") from exc
    info = safe_regular(target, private=False)
    if stat.S_IMODE(info.st_mode) & 0o022:
        raise Refusal(f"diagnostic artifact is writable by group or other: {path}")
    if executable and not os.access(target, os.X_OK):
        raise Refusal(f"diagnostic artifact is not executable: {path}")
    return file_sha(target, private=False)


def run_probe(manifest: dict) -> dict:
    probe = Path(manifest["probe_path"])
    safe_regular(probe)
    if file_sha(probe) != manifest["baseline"]["probe_sha256"]:
        raise Refusal("guarded probe bytes drifted")
    proc = subprocess.run(
        [
            sys.executable, str(probe), "--install-dir", manifest["install_dir"],
            "--config", manifest["config_path"], "--journal",
            manifest["owner_pin_journal"], "--port", str(manifest["status_port"]),
            "--label", manifest["provider_label"],
        ], capture_output=True, text=True, check=True,
    )
    value = json.loads(proc.stdout)
    if not isinstance(value, dict):
        raise Refusal("probe output is invalid")
    if "snapshot" not in value:
        status, launch, installed = value.get("status", {}), value.get("launch", {}), value.get("installed", {})
        value["snapshot"] = {
            "provider_id_sha256": status.get("provider_id_sha256"),
            "binary_version": status.get("binary_version"), "model": status.get("model"),
            "model_loaded": status.get("model_loaded"), "network_state": status.get("network_state"),
            "coordinator_connected": status.get("coordinator.connected"),
            "operator_paused": status.get("lifecycle.operator_paused"),
            "pid": launch.get("pid"), "process_start_us": launch.get("process_start_us"),
            "executable_path": launch.get("executable_path"),
            "binary_sha256": installed.get("binary_sha256"),
        }
    return value


def validate_serving_snapshot(manifest: dict, probe: dict, *, restored: dict | None = None) -> dict:
    snapshot = probe.get("snapshot")
    if not isinstance(snapshot, dict):
        raise Refusal("probe snapshot is missing")
    expected = manifest["baseline"]["snapshot"]
    if any(snapshot.get(key) != expected.get(key) for key in SNAPSHOT_KEYS):
        raise Refusal("live serving identity drifted")
    if any(snapshot.get(key) != manifest["baseline"][key] for key in SNAPSHOT_HASH_KEYS):
        raise Refusal("probe-observed guarded bytes drifted")
    if (
        snapshot.get("model_loaded") is not True
        or snapshot.get("network_state") != "buyer_serving"
        or snapshot.get("coordinator_connected") is not True
        or snapshot.get("operator_paused") is not False
        or not isinstance(snapshot.get("pid"), int)
        or isinstance(snapshot.get("pid"), bool)
        or snapshot["pid"] <= 0
        or not isinstance(snapshot.get("process_start_us"), int)
        or isinstance(snapshot.get("process_start_us"), bool)
        or snapshot["process_start_us"] <= 0
        or snapshot.get("executable_path") != str(Path(manifest["install_dir"]) / "macprovider-cli")
    ):
        raise Refusal("provider is not a stable buyer-serving baseline")
    if restored and any(snapshot.get(key) != restored.get(key) for key in ("pid", "process_start_us", "executable_path")):
        raise Refusal("restored provider process identity changed")
    return snapshot


def stable_serving(
    manifest: dict, *, hold_s: int = 120, deadline_s: int | None = None, resume: bool = False,
) -> dict:
    deadline = time.monotonic() + (manifest["ready_timeout_s"] if deadline_s is None else deadline_s)
    stable_since: float | None = None
    identity: dict | None = None
    while time.monotonic() <= deadline:
        try:
            if resume:
                try:
                    control(manifest, "resume_request")
                except (OSError, Refusal):
                    pass
            snapshot = validate_serving_snapshot(manifest, run_probe(manifest))
            now = time.monotonic()
            observed = {key: snapshot[key] for key in ("pid", "process_start_us", "executable_path")}
            if observed != identity:
                identity = observed
                stable_since = now
            elif stable_since is not None and now - stable_since >= hold_s:
                return snapshot
        except (OSError, Refusal, subprocess.SubprocessError, ValueError):
            identity = None
            stable_since = None
        remaining = deadline - time.monotonic()
        if remaining > 0:
            time.sleep(min(manifest["poll_s"], remaining))
    raise Refusal("provider did not remain buyer_serving with one process identity")


def read_journal(path: Path) -> dict:
    value = read_json(path)
    if value.get("schema_version") != JOURNAL_SCHEMA or value.get("phase") not in PHASES:
        raise Refusal("journal schema or phase mismatch")
    if (
        not isinstance(value.get("revision"), int)
        or value["revision"] < 1
        or not isinstance(value.get("nonce"), str)
        or not value["nonce"]
        or not isinstance(value.get("manifest_sha256"), str)
    ):
        raise Refusal("journal metadata is incomplete")
    return value


def abort_receipt_path(journal: Path) -> Path:
    return journal.with_name(f".{journal.name}.abort.json")


def read_abort_receipt(path: Path) -> dict:
    value = read_json(path)
    if (
        value.get("schema_version") != ABORT_SCHEMA
        or value.get("state") != "aborted"
        or not isinstance(value.get("nonce"), str)
        or not value["nonce"]
        or not isinstance(value.get("manifest_sha256"), str)
        or len(value["manifest_sha256"]) != 64
        or any(char not in "0123456789abcdef" for char in value["manifest_sha256"])
    ):
        raise Refusal("abort receipt is invalid")
    return value


def write_transition(path: Path, record: dict, phase: str, **changes: object) -> dict:
    if phase not in PHASES:
        raise Refusal("invalid journal transition")
    updated = dict(record)
    updated.update(changes)
    updated["phase"] = phase
    updated["revision"] = record["revision"] + 1
    updated["updated_unix"] = int(time.time())
    atomic_json(path, updated)
    return updated


def check_cas(record: dict, nonce: str, revision: int | None = None) -> None:
    if record["nonce"] != nonce or (revision is not None and record["revision"] != revision):
        raise Refusal("journal nonce/revision CAS mismatch")


def control(manifest: dict, frame: str) -> None:
    payload = (json.dumps({"type": frame}, separators=(",", ":")) + "\n").encode()
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        conn.settimeout(30)
        conn.connect(manifest["ctl_socket"])
        conn.sendall(payload)
        data = b""
        while b"\n" not in data and len(data) <= 64 * 1024:
            chunk = conn.recv(4096)
            if not chunk:
                break
            data += chunk
    finally:
        conn.close()
    try:
        reply = json.loads(data.split(b"\n", 1)[0])
    except ValueError as exc:
        raise Refusal(f"control {frame} returned invalid JSON") from exc
    if not isinstance(reply, dict) or reply.get("accepted") is not True:
        raise Refusal(f"control {frame} was refused")


def loaded(label: str) -> bool:
    return subprocess.run(
        ["launchctl", "print", f"gui/{os.getuid()}/{label}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode == 0


def bootout(label: str) -> None:
    subprocess.run(
        ["launchctl", "bootout", f"gui/{os.getuid()}/{label}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    deadline = time.monotonic() + LAUNCHCTL_TRANSITION_TIMEOUT_S
    while loaded(label):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise Refusal(f"launch job remained loaded: {label}")
        time.sleep(min(LAUNCHCTL_POLL_S, remaining))


def bootstrap(label: str, plist: str) -> None:
    if loaded(label):
        return
    subprocess.run(
        ["launchctl", "bootstrap", f"gui/{os.getuid()}", plist],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    deadline = time.monotonic() + LAUNCHCTL_TRANSITION_TIMEOUT_S
    while not loaded(label):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise Refusal(f"launch job did not load: {label}")
        time.sleep(min(LAUNCHCTL_POLL_S, remaining))


class ProcBsdInfo(ctypes.Structure):
    _fields_ = [
        ("pbi_flags", ctypes.c_uint32), ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32), ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32), ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32), ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32), ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32), ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * 16), ("pbi_name", ctypes.c_char * 32),
        ("pbi_nfiles", ctypes.c_uint32), ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32), ("pbi_e_tdev", ctypes.c_uint32),
        ("pbi_e_tpgid", ctypes.c_uint32), ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64), ("pbi_start_tvusec", ctypes.c_uint64),
    ]


def process_start_us(pid: int) -> int:
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
    proc_pidinfo = libproc.proc_pidinfo
    proc_pidinfo.argtypes = [
        ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int,
    ]
    proc_pidinfo.restype = ctypes.c_int
    info = ProcBsdInfo()
    if proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info):
        raise OSError("could not read process start identity")
    start_us = int(info.pbi_start_tvsec) * 1_000_000 + int(info.pbi_start_tvusec)
    if start_us <= 0:
        raise OSError("process start identity is invalid")
    return start_us


def same_process(pid: object, started: object) -> bool:
    if (
        not isinstance(pid, int) or isinstance(pid, bool)
        or not isinstance(started, int) or isinstance(started, bool)
        or pid <= 0 or started <= 0
    ):
        return False
    try:
        os.kill(pid, 0)
        return process_start_us(pid) == started
    except (OSError, subprocess.SubprocessError, ValueError):
        return False


def wait_process_exit(pid: object, started: object, *, timeout_s: int, poll_s: int) -> None:
    deadline = time.monotonic() + timeout_s
    while same_process(pid, started) and time.monotonic() < deadline:
        time.sleep(min(poll_s, max(0, deadline - time.monotonic())))
    if same_process(pid, started):
        raise Refusal("baseline provider process remained alive after launch job removal")


def process_group_alive(pgid: object) -> bool:
    if not isinstance(pgid, int) or isinstance(pgid, bool) or pgid <= 0:
        return False
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        proc = subprocess.run(
            ["ps", "-axo", "pgid="], capture_output=True, text=True, check=True,
        )
        try:
            return pgid in {int(value) for value in proc.stdout.split()}
        except ValueError as exc:
            raise Refusal("cannot inspect offline lab process group") from exc


def await_start_gate(fd: int) -> None:
    try:
        token = os.read(fd, 1)
    finally:
        os.close(fd)
    if token != b"1":
        raise Refusal("supervisor start gate closed before journal identity was durable")


def release_start_gate(fd: int) -> None:
    try:
        if os.write(fd, b"1") != 1:
            raise Refusal("could not release start gate")
    finally:
        os.close(fd)


def stop_lab(
    record: dict, manifest: dict, *, child: subprocess.Popen[bytes] | subprocess.Popen[str] | None = None,
) -> None:
    pid = record.get("lab_pid")
    pgid = record.get("lab_pgid")
    started = record.get("lab_process_start_us")
    leader_matches = same_process(pid, started)
    group_alive = process_group_alive(pgid)
    owned_reaped_leader = (
        child is not None and isinstance(pid, int) and child.pid == pid and child.poll() is not None
    )
    if not leader_matches and not group_alive:
        return
    if not leader_matches and not owned_reaped_leader:
        raise Refusal("lab leader identity changed while its process group remains")
    assert isinstance(pid, int) and isinstance(pgid, int)
    try:
        os.killpg(pgid, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + min(10, manifest["poll_s"] * 2)
    while process_group_alive(pgid) and time.monotonic() < deadline:
        if child is not None:
            child.poll()
        time.sleep(min(1, manifest["poll_s"]))
    if process_group_alive(pgid):
        try:
            os.killpg(pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 5
    while process_group_alive(pgid) and time.monotonic() < deadline:
        if child is not None:
            child.poll()
        time.sleep(0.1)
    if child is not None:
        child.poll()
    if process_group_alive(pgid):
        raise Refusal("offline lab process group remains alive")


def wait_drain(manifest: dict) -> None:
    deadline = time.monotonic() + manifest["drain_timeout_s"]
    while time.monotonic() <= deadline:
        probe = run_probe(manifest)
        status = probe.get("status", {})
        snapshot = probe.get("snapshot", {})
        if status.get("requests_in_flight") == 0 and snapshot.get("operator_paused") is True:
            return
        time.sleep(manifest["poll_s"])
    raise Refusal("provider did not pause and drain before deadline")


def restore_locked(manifest: dict, journal: Path, record: dict) -> dict:
    if record["phase"] == TERMINAL_PHASE:
        return record
    stop_lab(record, manifest)
    if record.get("provider_stop_started") is True:
        validate_live_hashes(manifest)
        bootout(manifest["watchdog_label"])
        bootout(manifest["provider_label"])
        baseline_process = manifest["baseline"]["snapshot"]
        wait_process_exit(
            baseline_process.get("pid"), baseline_process.get("process_start_us"),
            timeout_s=manifest["drain_timeout_s"], poll_s=manifest["poll_s"],
        )
    record = write_transition(journal, record, "lab_stopped", lab_process_group_gone=True)
    validate_live_hashes(manifest)
    record = write_transition(journal, record, "restoring_provider")
    bootstrap(manifest["provider_label"], manifest["provider_plist"])
    ready = stable_serving(
        manifest, hold_s=120, deadline_s=manifest["ready_timeout_s"], resume=True,
    )
    record = write_transition(
        journal, record, "provider_ready", restored_process=ready,
        provider_stop_started=False,
    )
    validate_live_hashes(manifest)
    bootstrap(manifest["watchdog_label"], manifest["watchdog_plist"])
    validate_live_hashes(manifest)
    return write_transition(journal, record, TERMINAL_PHASE, watchdog_restored=True)


def supervise(manifest: dict, manifest_sha: str, journal: Path, nonce: str) -> int:
    lab_rc = 127
    record: dict | None = None
    try:
        with JournalLock(journal):
            record = read_journal(journal)
            check_cas(record, nonce)
            if record["manifest_sha256"] != manifest_sha:
                raise Refusal("manifest changed after dispatch")
            validate_journal_job(manifest, record)
            if record.get("supervisor_pid") != os.getpid() or not same_process(
                record.get("supervisor_pid"), record.get("supervisor_process_start_us")
            ):
                raise Refusal("supervisor identity is not the journal-bound process")
            record = write_transition(journal, record, "pausing")
        control(manifest, "pause_request")
        wait_drain(manifest)
        with JournalLock(journal):
            record = write_transition(journal, read_journal(journal), "drained")
        with JournalLock(journal):
            record = write_transition(
                journal, read_journal(journal), "stopping_provider",
                provider_stop_started=True,
            )
        bootout(manifest["watchdog_label"])
        bootout(manifest["provider_label"])
        baseline_process = manifest["baseline"]["snapshot"]
        wait_process_exit(
            baseline_process.get("pid"), baseline_process.get("process_start_us"),
            timeout_s=manifest["drain_timeout_s"], poll_s=manifest["poll_s"],
        )
        with JournalLock(journal):
            record = write_transition(journal, read_journal(journal), "stopped")
        # Re-check source, artifacts and staged helper after the provider is
        # stopped.  The no-model job validation already happened in prepare_run.
        validate_lab_artifacts(manifest)
        path = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        tmpdir = os.environ.get("TMPDIR", "/tmp")
        gate_read, gate_write = os.pipe()
        try:
            child = subprocess.Popen(
                [sys.executable, "-c", GATED_EXEC, str(gate_read), manifest["lab_script_path"],
                 manifest["_manifest_path"] if manifest.get("job") is not None else "-",
                 str(Path.home()), path, tmpdir],
                cwd=manifest["lab_source_dir"], env={"HOME": str(Path.home()), "PATH": path, "TMPDIR": tmpdir},
                stdin=subprocess.DEVNULL, stdout=None, stderr=None, start_new_session=True,
                close_fds=True, pass_fds=(gate_read,),
            )
            os.close(gate_read)
            gate_read = -1
            started = process_start_us(child.pid)
            with JournalLock(journal):
                record = write_transition(
                    journal, read_journal(journal), "lab_running", lab_pid=child.pid,
                    lab_pgid=child.pid, lab_process_start_us=started,
                    lab_deadline_unix=int(time.time()) + manifest["lab_timeout_s"],
                )
            release_start_gate(gate_write)
            gate_write = -1
        finally:
            if gate_read >= 0:
                os.close(gate_read)
            if gate_write >= 0:
                os.close(gate_write)
        try:
            lab_rc = child.wait(timeout=manifest["lab_timeout_s"])
        except subprocess.TimeoutExpired:
            stop_lab(record, manifest, child=child)
            lab_rc = 124
        stop_lab(record, manifest, child=child)
        with JournalLock(journal):
            current = read_journal(journal)
            current = write_transition(
                journal, current, "lab_stopped", lab_exit_code=lab_rc,
                lab_process_group_gone=True,
            )
            record = restore_locked(manifest, journal, current)
        return lab_rc
    except BaseException as exc:
        try:
            with JournalLock(journal):
                current = read_journal(journal)
                current["last_error"] = type(exc).__name__
                atomic_json(journal, current)
                restore_locked(manifest, journal, current)
        except BaseException:
            pass
        return 6


def prepare_run(manifest: dict, manifest_sha: str, journal: Path) -> dict:
    if journal.exists():
        record = read_journal(journal)
        if record["manifest_sha256"] != manifest_sha:
            raise Refusal("existing journal belongs to another manifest")
        validate_journal_job(manifest, record)
        if same_process(record.get("supervisor_pid"), record.get("supervisor_process_start_us")):
            raise Refusal("matching supervisor is still active")
        recovered = restore_locked(manifest, journal, record)
        raise Refusal(f"existing journal recovered to {recovered['phase']}; finish it before a fresh run")
    validate_live_hashes(manifest)
    validate_lab_artifacts(manifest)
    validate_job(manifest)
    if not loaded(manifest["provider_label"]) or not loaded(manifest["watchdog_label"]):
        raise Refusal("provider and watchdog must both be loaded")
    baseline = stable_serving(manifest)
    expected = manifest["baseline"]["snapshot"]
    if any(
        baseline.get(key) != expected.get(key)
        for key in expected if key != "requests_in_flight"
    ):
        raise Refusal("manifest baseline does not match the live probe")
    record = {
        "schema_version": JOURNAL_SCHEMA, "phase": "prepared", "revision": 1,
        "nonce": manifest["nonce"], "manifest_sha256": manifest_sha,
        "created_unix": int(time.time()), "updated_unix": int(time.time()),
        "baseline_process": {key: baseline[key] for key in ("pid", "process_start_us", "executable_path")},
        "lab_process_group_gone": False, "watchdog_restored": False,
    }
    if manifest.get("job") is not None:
        record["job_kind"] = manifest["job"]["kind"]
        record["job_identity_sha256"] = manifest["job"]["identity_sha256"]
    atomic_json(journal, record)
    return record


def command_run(args: argparse.Namespace) -> dict:
    manifest, manifest_sha = load_manifest(Path(args.manifest))
    journal = absolute(args.journal, "journal")
    if journal.parent != Path(args.journal).parent.resolve():
        raise Refusal("journal parent is not canonical")
    with JournalLock(journal):
        if abort_receipt_path(journal).exists():
            raise Refusal("dispatch was durably aborted")
        locked_manifest, locked_sha = load_manifest(Path(args.manifest))
        if locked_sha != manifest_sha:
            raise Refusal("manifest changed while waiting for dispatch lock")
        manifest = locked_manifest
        record = prepare_run(manifest, manifest_sha, journal)
        log = Path(manifest["log_path"])
        if log.exists():
            raise Refusal("supervisor log already exists")
        fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
        os.fchmod(fd, 0o600)
        gate_read, gate_write = os.pipe()
        try:
            child = subprocess.Popen(
                [sys.executable, str(Path(__file__).resolve()), "_supervise", "--manifest",
                 args.manifest, "--journal", str(journal), "--nonce", record["nonce"],
                 "--start-gate-fd", str(gate_read)],
                stdin=subprocess.DEVNULL, stdout=fd, stderr=fd, start_new_session=True,
                close_fds=True, pass_fds=(gate_read,),
                env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(Path.home())},
            )
            os.close(gate_read)
            gate_read = -1
            supervisor_started = process_start_us(child.pid)
            record = write_transition(
                journal, record, "prepared", supervisor_pid=child.pid,
                supervisor_process_start_us=supervisor_started,
            )
            release_start_gate(gate_write)
            gate_write = -1
        finally:
            os.close(fd)
            if gate_read >= 0:
                os.close(gate_read)
            if gate_write >= 0:
                os.close(gate_write)
    return {"state": "running", "nonce": record["nonce"], "revision": record["revision"], "supervisor_pid": child.pid}


def command_abort(args: argparse.Namespace) -> dict:
    manifest_path = absolute(args.manifest, "manifest")
    journal = absolute(args.journal, "journal")
    receipt_path = abort_receipt_path(journal)
    with JournalLock(journal):
        if receipt_path.exists():
            receipt = read_abort_receipt(receipt_path)
            if receipt["nonce"] != args.nonce or receipt["manifest_sha256"] != args.manifest_sha256:
                raise Refusal("abort receipt nonce/digest mismatch")
            if journal.exists():
                raise Refusal("abort receipt conflicts with a durable journal")
            return receipt
        manifest, manifest_sha = load_manifest(manifest_path)
        if manifest["nonce"] != args.nonce or manifest_sha != args.manifest_sha256:
            raise Refusal("abort manifest nonce/digest mismatch")
        if journal.exists():
            raise Refusal("abort cannot remove a manifest with a durable journal")
        receipt = {
            "schema_version": ABORT_SCHEMA, "state": "aborted",
            "nonce": args.nonce, "manifest_sha256": args.manifest_sha256,
            "created_unix": int(time.time()),
        }
        atomic_json(receipt_path, receipt)
        manifest_path.unlink()
        fsync_dir(manifest_path.parent)
    return receipt


def command_finish_abort(args: argparse.Namespace) -> dict:
    manifest_path = absolute(args.manifest, "manifest")
    journal = absolute(args.journal, "journal")
    receipt_path = abort_receipt_path(journal)
    with JournalLock(journal):
        receipt = read_abort_receipt(receipt_path)
        if receipt["nonce"] != args.nonce or receipt["manifest_sha256"] != args.manifest_sha256:
            raise Refusal("abort receipt nonce/digest mismatch")
        if journal.exists():
            raise Refusal("abort receipt cannot finish while a journal remains")
        if manifest_path.exists():
            manifest, manifest_sha = load_manifest(manifest_path)
            if manifest["nonce"] != receipt["nonce"] or manifest_sha != receipt["manifest_sha256"]:
                raise Refusal("surviving manifest does not match abort receipt")
            manifest_path.unlink()
            fsync_dir(manifest_path.parent)
        receipt_path.unlink()
        fsync_dir(receipt_path.parent)
    return {"state": "abort-finished", "nonce": args.nonce}


def command_status(args: argparse.Namespace) -> dict:
    manifest_path = absolute(args.manifest, "manifest")
    journal = absolute(args.journal, "journal")
    receipt_path = abort_receipt_path(journal)
    if receipt_path.exists():
        receipt = read_abort_receipt(receipt_path)
        if journal.exists():
            raise Refusal("abort receipt conflicts with a durable journal")
        if manifest_path.exists():
            manifest, manifest_sha = load_manifest(manifest_path)
            if receipt["nonce"] != manifest["nonce"] or receipt["manifest_sha256"] != manifest_sha:
                raise Refusal("abort receipt does not match staged manifest")
        return {
            "state": "aborted", "nonce": receipt["nonce"],
            "manifest_sha256": receipt["manifest_sha256"],
        }
    manifest, manifest_sha = load_manifest(manifest_path)
    if not journal.exists():
        return {
            "state": "idle", "nonce": manifest["nonce"],
            "manifest_sha256": manifest_sha,
        }
    record = read_journal(journal)
    if record["manifest_sha256"] != manifest_sha:
        raise Refusal("journal manifest digest mismatch")
    validate_journal_job(manifest, record)
    result = {key: record.get(key) for key in (
        "phase", "revision", "nonce", "supervisor_pid", "lab_pid", "lab_exit_code",
        "lab_process_group_gone", "watchdog_restored", "restored_process", "last_error",
        "job_kind", "job_identity_sha256",
    ) if key in record}
    active = same_process(record.get("supervisor_pid"), record.get("supervisor_process_start_us"))
    result["supervisor_active"] = active
    result["action"] = "finish" if record["phase"] == TERMINAL_PHASE else ("wait" if active else "recover")
    return result


def command_recover(args: argparse.Namespace) -> dict:
    manifest, manifest_sha = load_manifest(Path(args.manifest))
    journal = absolute(args.journal, "journal")
    with JournalLock(journal):
        record = read_journal(journal)
        check_cas(record, args.nonce, args.revision)
        if record["manifest_sha256"] != manifest_sha:
            raise Refusal("journal manifest digest mismatch")
        validate_journal_job(manifest, record)
        if same_process(record.get("supervisor_pid"), record.get("supervisor_process_start_us")):
            raise Refusal("matching supervisor is still active")
        record = restore_locked(manifest, journal, record)
    return {"phase": record["phase"], "revision": record["revision"], "nonce": record["nonce"]}


def command_finish(args: argparse.Namespace) -> dict:
    manifest, manifest_sha = load_manifest(Path(args.manifest))
    journal = absolute(args.journal, "journal")
    with JournalLock(journal):
        record = read_journal(journal)
        check_cas(record, args.nonce, args.revision)
        if record["manifest_sha256"] != manifest_sha or record["phase"] != TERMINAL_PHASE:
            raise Refusal("only the matching restored journal may finish")
        validate_journal_job(manifest, record)
        if not args.controller_confirmed:
            raise Refusal("controller confirmation is required")
        validate_live_hashes(manifest)
        validate_serving_snapshot(manifest, run_probe(manifest), restored=record.get("restored_process"))
        if not loaded(manifest["watchdog_label"]):
            raise Refusal("watchdog is not restored")
        journal.unlink()
        fsync_dir(journal.parent)
    return {"state": "finished", "nonce": record["nonce"]}


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    sub = root.add_subparsers(dest="command", required=True)
    for name in ("run", "status"):
        item = sub.add_parser(name)
        item.add_argument("--manifest", required=True)
        item.add_argument("--journal", required=True)
    recover = sub.add_parser("recover")
    recover.add_argument("--manifest", required=True)
    recover.add_argument("--journal", required=True)
    recover.add_argument("--nonce", required=True)
    recover.add_argument("--revision", required=True, type=int)
    abort = sub.add_parser("abort")
    abort.add_argument("--manifest", required=True)
    abort.add_argument("--journal", required=True)
    abort.add_argument("--nonce", required=True)
    abort.add_argument("--manifest-sha256", required=True)
    finish_abort = sub.add_parser("finish-abort")
    finish_abort.add_argument("--manifest", required=True)
    finish_abort.add_argument("--journal", required=True)
    finish_abort.add_argument("--nonce", required=True)
    finish_abort.add_argument("--manifest-sha256", required=True)
    finish = sub.add_parser("finish")
    finish.add_argument("--manifest", required=True)
    finish.add_argument("--journal", required=True)
    finish.add_argument("--nonce", required=True)
    finish.add_argument("--revision", required=True, type=int)
    finish.add_argument("--controller-confirmed", action="store_true")
    hidden = sub.add_parser("_supervise", help=argparse.SUPPRESS)
    hidden.add_argument("--manifest", required=True)
    hidden.add_argument("--journal", required=True)
    hidden.add_argument("--nonce", required=True)
    hidden.add_argument("--start-gate-fd", required=True, type=int)
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        if args.command == "run":
            result = command_run(args)
        elif args.command == "status":
            result = command_status(args)
        elif args.command == "recover":
            result = command_recover(args)
        elif args.command == "abort":
            result = command_abort(args)
        elif args.command == "finish-abort":
            result = command_finish_abort(args)
        elif args.command == "finish":
            result = command_finish(args)
        else:
            await_start_gate(args.start_gate_fd)
            manifest, manifest_sha = load_manifest(Path(args.manifest))
            journal = absolute(args.journal, "journal")
            result = {"exit_code": supervise(manifest, manifest_sha, journal, args.nonce)}
        print(json.dumps(result, sort_keys=True))
        return int(result.get("exit_code", 0))
    except (OSError, Refusal, subprocess.SubprocessError, ValueError) as exc:
        print(f"studio-lab-window-remote: REFUSED: {exc}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
