#!/usr/bin/env python3
"""Journal a single qualified target enrollment; never print target identities.

Called on Pearl by the Air ops entrypoint under the live-ops lock. The installed
runner's own parser validates the proposed document without starting traffic.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import tempfile
import time

SERVICE = "malibu-buyer-runner.service"
RUNNER = "/opt/malibu-buyer-runner/buyer-runner.mjs"
TARGETS = "/opt/malibu-buyer-runner/targets.json"


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def secure_path(path, exists=True):
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts:
        raise ValueError("noncanonical path")
    for parent in reversed(path.parents):
        st = parent.lstat()
        if not stat.S_ISDIR(st.st_mode) or st.st_uid != 0 or st.st_mode & 0o022:
            raise ValueError("unsafe parent")
    if exists:
        st = path.lstat()
        if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or st.st_mode & 0o022 or st.st_nlink != 1:
            raise ValueError("unsafe file")
    elif path.exists() or path.is_symlink():
        secure_path(path)
    return path


def atomic(path, raw, mode):
    secure_path(path, exists=False)
    fd, tmp = tempfile.mkstemp(prefix=".runner-target-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as f:
            os.fchmod(f.fileno(), mode)
            f.write(raw)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def candidate(raw, provider, model, slots):
    doc = json.loads(raw)
    if not isinstance(doc, dict) or not isinstance(doc.get("targets"), list):
        raise ValueError("unsupported target document")
    if provider in doc.get("exclude", []):
        raise ValueError("target explicitly excluded")
    matches = [t for t in doc["targets"] if t.get("provider_id") == provider]
    if len(matches) > 1:
        raise ValueError("duplicate target")
    if matches:
        row = matches[0]
        # Do not replace another model or silently change an existing lane plan.
        if row.get("model") != model or row.get("slots") != slots:
            raise ValueError("existing target differs")
    else:
        doc["targets"].append({"provider_id": provider, "model": model, "slots": slots})
    return (json.dumps(doc, indent=2) + "\n").encode()


def validate(raw):
    secure_path(RUNNER)
    js = "import {parseTargets} from 'file://" + RUNNER + "';let s='';for await(const c of process.stdin)s+=c;parseTargets(s);"
    subprocess.run(["node", "--input-type=module", "-e", js], input=raw,
                   check=True, timeout=15, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def service(action):
    try:
        return subprocess.run(["systemctl", action, SERVICE], check=False,
                              timeout=45, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    except subprocess.TimeoutExpired:
        return False


def stable():
    # A parsed-invalid file exits synchronously. Require one stable process,
    # rather than accepting systemd's short active state during an auto-restart.
    previous = None
    since = time.monotonic()
    deadline = since + 30
    while time.monotonic() < deadline:
        try:
            out = subprocess.check_output(["systemctl", "show", SERVICE, "-p", "MainPID", "-p", "ActiveState"], timeout=5).decode()
        except (subprocess.SubprocessError, OSError):
            previous = None
            time.sleep(0.5)
            continue
        fields = dict(line.split("=", 1) for line in out.splitlines() if "=" in line)
        pid = fields.get("MainPID", "0")
        if fields.get("ActiveState") == "active" and pid != "0":
            if pid != previous:
                previous, since = pid, time.monotonic()
            if time.monotonic() - since >= 3:
                return True
        else:
            previous = None
        time.sleep(0.5)
    return False


def save(path, state):
    atomic(path, (json.dumps(state) + "\n").encode(), 0o600)


def recover(path, journal, state):
    raw = secure_path(path).read_bytes()
    if digest(raw) not in (state["before_sha256"], state["after_sha256"]):
        raise ValueError("concurrent target edit; refusing overwrite")
    baseline = state["before"].encode()
    if digest(baseline) != state["before_sha256"]:
        raise ValueError("journal baseline mismatch")
    validate(baseline)
    atomic(path, baseline, state["mode"])
    service("restart")
    if not stable():
        service("start")
        raise RuntimeError("runner recovery not stable; journal retained")
    state["phase"] = "restored"
    save(journal, state)


def execute(args):
    if os.geteuid() != 0 or args.path != TARGETS:
        raise ValueError("requires Pearl root and exact runner target path")
    path = secure_path(args.path)
    journal = secure_path(args.journal, exists=False)
    if journal == path or not str(journal).startswith("/var/lib/macprovider-ops/"):
        raise ValueError("journal must be in protected ops state")
    state = json.loads(journal.read_bytes()) if journal.exists() else None
    if args.command == "status":
        print(json.dumps({"phase": state["phase"] if state else "absent",
                          "runner_active": service("is-active")}))
        return
    if state and state["phase"] not in ("committed", "restored"):
        recover(path, journal, state)
        if args.command == "recover":
            return
        raise RuntimeError("prior interrupted enrollment restored; rerun status")
    if args.command == "recover":
        return
    if args.model != "qwen3-8b" or args.slots != 4 or not args.provider_id or any(c not in "abcdefghijklmnopqrstuvwxyz0123456789-" for c in args.provider_id):
        raise ValueError("requires reviewed Qwen3-8B four-slot target")
    if not service("is-active"):
        raise RuntimeError("runner baseline not active")
    before = path.read_bytes()
    after = candidate(before, args.provider_id, args.model, args.slots)
    validate(after)
    state = {"phase": "prepared", "before": before.decode(), "before_sha256": digest(before),
             "after_sha256": digest(after), "mode": stat.S_IMODE(path.stat().st_mode)}
    save(journal, state)
    try:
        if digest(path.read_bytes()) != state["before_sha256"]:
            raise ValueError("concurrent target edit")
        atomic(path, after, state["mode"])
        service("restart")
        if not stable():
            raise RuntimeError("enrolled runner not stable")
        state["phase"] = "committed"
        save(journal, state)
        print(json.dumps({"phase": "committed", "runner_active": True, "slots": 4}))
    except BaseException:
        recover(path, journal, state)
        raise


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["status", "enroll", "recover"])
    parser.add_argument("--path", required=True)
    parser.add_argument("--journal", required=True)
    parser.add_argument("--provider-id")
    parser.add_argument("--model")
    parser.add_argument("--slots", type=int)
    args = parser.parse_args()
    def interrupted(signum, frame):
        raise InterruptedError("runner enrollment interrupted")
    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, interrupted)
    try:
        execute(args)
    except Exception as exc:
        # Config and subprocess output can contain private inventory or keys.
        raise SystemExit("buyer-runner enrollment failed: " + type(exc).__name__)


if __name__ == "__main__":
    main()
