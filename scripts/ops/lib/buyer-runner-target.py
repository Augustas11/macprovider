#!/usr/bin/env python3
"""Journal a single qualified target enrollment; never print target identities.

Called on Pearl by the Air ops entrypoint under the live-ops lock. The installed
runner's own parser validates the proposed document without starting traffic.

The reserve-* and set-target-model commands (called through lib/runner-reserve.sh)
pause one target (the Studio canary) by removing it from targets.json with a
timestamped backup and a restart, restore exactly that backup, and retarget its
model. Only one reservation is outstanding at a time; another owner's is refused.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import time

SERVICE = "malibu-buyer-runner.service"
RUNNER = "/opt/malibu-buyer-runner/buyer-runner.mjs"
TARGETS = "/opt/malibu-buyer-runner/targets.json"
JOURNAL = "/var/lib/macprovider-ops/air-qwen8-runner.json"


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def secure_path(path, exists=True, owner=0):
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts:
        raise ValueError("noncanonical path")
    for parent in reversed(path.parents):
        st = parent.lstat()
        if not stat.S_ISDIR(st.st_mode) or st.st_uid not in (0, owner) or st.st_mode & 0o022:
            raise ValueError("unsafe parent")
    if exists:
        st = path.lstat()
        if not stat.S_ISREG(st.st_mode) or st.st_uid != owner or st.st_mode & 0o022 or st.st_nlink != 1:
            raise ValueError("unsafe file")
    elif path.exists() or path.is_symlink():
        secure_path(path, owner=owner)
    return path


def atomic(path, raw, mode, owner=0):
    secure_path(path, exists=False, owner=owner)
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


def main_pid():
    return subprocess.check_output(["systemctl", "show", SERVICE, "-p", "MainPID", "--value"], timeout=5).decode().strip()


def invocation():
    value = subprocess.check_output(["systemctl", "show", SERVICE, "-p", "InvocationID", "--value"], timeout=5).decode().strip()
    if len(value) != 32 or any(c not in "0123456789abcdef" for c in value):
        raise ValueError("missing runner invocation identity")
    return value


def stable(exclude_pid):
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
        if fields.get("ActiveState") == "active" and pid not in ("0", exclude_pid):
            if pid != previous:
                previous, since = pid, time.monotonic()
            if time.monotonic() - since >= 3:
                return True
        else:
            previous = None
        time.sleep(0.5)
    return False


def save(path, state, owner=0):
    atomic(path, (json.dumps(state) + "\n").encode(), 0o600, owner)


def enrollment_matches(raw, state, provider, model, slots):
    if not state or state.get("phase") != "committed" or digest(raw) != state.get("after_sha256"):
        return False
    doc = json.loads(raw)
    matches = [t for t in doc.get("targets", []) if t.get("provider_id") == provider]
    return (len(matches) == 1 and matches[0].get("model") == model
            and matches[0].get("slots") == slots and provider not in doc.get("exclude", []))


def recover(path, journal, state):
    raw = secure_path(path).read_bytes()
    if digest(raw) not in (state["before_sha256"], state["after_sha256"]):
        raise ValueError("concurrent target edit; refusing overwrite")
    baseline = state["before"].encode()
    if digest(baseline) != state["before_sha256"]:
        raise ValueError("journal baseline mismatch")
    validate(baseline)
    atomic(path, baseline, state["mode"])
    old_pid = main_pid()
    service("restart")
    if not stable(old_pid):
        service("start")
        raise RuntimeError("runner recovery not stable; journal retained")
    state["phase"] = "restored"
    save(journal, state)


def execute(args):
    if os.geteuid() != 0 or args.path != TARGETS:
        raise ValueError("requires Pearl root and exact runner target path")
    path = secure_path(args.path)
    if args.journal != JOURNAL:
        raise ValueError("requires exact protected Air enrollment journal")
    parent = Path(JOURNAL).parent
    if not parent.exists() and not parent.is_symlink():
        # Status/recovery of an operation never started must not create state.
        if args.command in ("status", "recover"):
            if args.command == "status":
                print(json.dumps({"phase": "absent", "enrollment_matches": False, "runner_active": service("is-active")}))
            return
        for ancestor in reversed(parent.parents):
            st = ancestor.lstat()
            if not stat.S_ISDIR(st.st_mode) or st.st_uid != 0 or st.st_mode & 0o022:
                raise ValueError("unsafe journal parent")
        parent.mkdir(mode=0o700)
    journal = secure_path(args.journal, exists=False)
    state = json.loads(journal.read_bytes()) if journal.exists() else None
    if args.command == "status":
        print(json.dumps({"phase": state["phase"] if state else "absent",
                          "enrollment_matches": (enrollment_matches(path.read_bytes(), state, args.provider_id, args.model, args.slots)
                                                 and state.get("accepted_invocation") == invocation()),
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
        old_pid = main_pid()
        atomic(path, after, state["mode"])
        service("restart")
        if not stable(old_pid):
            raise RuntimeError("enrolled runner not stable")
        state["accepted_invocation"] = invocation()
        state["phase"] = "committed"
        save(journal, state)
        print(json.dumps({"phase": "committed", "runner_active": True, "slots": 4}))
    except BaseException:
        recover(path, journal, state)
        raise


# --- Studio target reservation (lib/runner-reserve.sh) ----------------------

RESERVE_STATE = "runner-reserve.json"


class Refusal(Exception):
    """A reservation refusal whose message carries no target identity."""


def utc_stamp():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def reserve_paths(args):
    uid = os.geteuid()
    path = secure_path(args.path, owner=uid)
    state_dir = Path(args.state_dir)
    if not state_dir.exists() and not state_dir.is_symlink():
        secure_path(state_dir, exists=False, owner=uid)
        state_dir.mkdir(mode=0o700)
    st = state_dir.lstat()
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != uid or st.st_mode & 0o022:
        raise Refusal("unsafe reservation state directory")
    state_path = secure_path(state_dir / RESERVE_STATE, exists=False, owner=uid)
    state = json.loads(state_path.read_bytes()) if state_path.exists() else None
    return uid, path, state_path, state


def studio_rows(doc, prefix):
    if not isinstance(doc, dict) or not isinstance(doc.get("targets"), list):
        raise Refusal("unsupported target document")
    rows = [i for i, t in enumerate(doc["targets"])
            if isinstance(t, dict) and str(t.get("provider_id", "")).startswith(prefix)]
    if len(rows) != 1:
        raise Refusal("expected exactly one runner target with the Studio provider prefix, found %d" % len(rows))
    return rows[0]


def render_doc(doc):
    return (json.dumps(doc, indent=2) + "\n").encode()


def validate_if_installed(path, raw):
    # Only the installed document has the installed parser to check it against.
    if str(path) == TARGETS:
        validate(raw)


def restart_runner(old_pid):
    return service("restart") and stable(old_pid)


def drop_state(state_path):
    state_path.unlink()
    directory = os.open(state_path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def restore_reservation(uid, path, state_path, state):
    current = digest(path.read_bytes())
    backup = secure_path(state["backup"], owner=uid)
    before = backup.read_bytes()
    if digest(before) != state["before_sha256"]:
        raise Refusal("reservation backup changed; restore by hand from the backup")
    if current not in (state["before_sha256"], state["after_sha256"]):
        raise Refusal("runner targets changed during the reservation; refusing to overwrite them")
    written = current == state["after_sha256"]
    if written or state["phase"] in ("paused", "restoring"):
        state["phase"] = "restoring"
        save(state_path, state, uid)
        if written:
            atomic(path, before, state["mode"], uid)
        if not restart_runner(main_pid()):
            service("start")
            raise RuntimeError("restored runner not stable; reservation kept for another restore")
    drop_state(state_path)


def reserve_pause(args):
    uid, path, state_path, state = reserve_paths(args)
    raw = path.read_bytes()
    if state:
        if state.get("owner") != args.owner:
            raise Refusal("runner reservation already held by owner %s since %s" % (state.get("owner"), state.get("created_at")))
        if state.get("phase") == "paused" and digest(raw) == state["after_sha256"]:
            return {"phase": "paused", "already": True}
        raise Refusal("an unfinished reservation of this owner is outstanding; run restore first")
    if not service("is-active"):
        raise Refusal("buyer runner is not active; nothing to pause")
    doc = json.loads(raw)
    del doc["targets"][studio_rows(doc, args.provider_prefix)]
    after = render_doc(doc)
    validate_if_installed(path, after)
    mode = stat.S_IMODE(path.stat().st_mode)
    backup = path.with_name(path.name + ".bak-runner-reserve-" + utc_stamp())
    atomic(backup, raw, 0o600, uid)
    state = {"phase": "prepared", "owner": args.owner, "created_at": utc_stamp(), "backup": str(backup),
             "before_sha256": digest(raw), "after_sha256": digest(after), "mode": mode}
    save(state_path, state, uid)
    try:
        if digest(path.read_bytes()) != state["before_sha256"]:
            raise Refusal("runner targets changed while pausing")
        old = main_pid()
        atomic(path, after, mode, uid)
        state["phase"] = "paused"
        save(state_path, state, uid)
        if not restart_runner(old):
            raise RuntimeError("paused runner not stable")
    except BaseException:
        restore_reservation(uid, path, state_path, state)
        raise
    return {"phase": "paused", "already": False}


def reserve_restore(args):
    uid, path, state_path, state = reserve_paths(args)
    if not state:
        return {"phase": "absent"}
    if state.get("owner") != args.owner:
        raise Refusal("runner reservation belongs to owner %s since %s" % (state.get("owner"), state.get("created_at")))
    restore_reservation(uid, path, state_path, state)
    return {"phase": "restored"}


def reserve_status(args):
    _, _, _, state = reserve_paths(args)
    if not state:
        return {"phase": "absent"}
    return {"phase": state.get("phase"), "owner": state.get("owner"), "created_at": state.get("created_at")}


def set_target_model(args):
    uid, path, state_path, state = reserve_paths(args)
    if state:
        raise Refusal("a runner reservation is outstanding (owner %s); restore it first" % state.get("owner"))
    raw = path.read_bytes()
    doc = json.loads(raw)
    row = doc["targets"][studio_rows(doc, args.provider_prefix)]
    if row.get("model") == args.model:
        return {"phase": "unchanged"}
    row["model"] = args.model
    after = render_doc(doc)
    validate_if_installed(path, after)
    mode = stat.S_IMODE(path.stat().st_mode)
    atomic(path.with_name(path.name + ".bak-runner-model-" + utc_stamp()), raw, 0o600, uid)
    old = main_pid()
    try:
        atomic(path, after, mode, uid)
        if not restart_runner(old):
            raise RuntimeError("retargeted runner not stable")
    except BaseException:
        if digest(path.read_bytes()) == digest(after):
            atomic(path, raw, mode, uid)
        service("restart")
        raise
    return {"phase": "retargeted"}


RESERVE_COMMANDS = {"reserve-pause": reserve_pause, "reserve-restore": reserve_restore,
                    "reserve-status": reserve_status, "set-target-model": set_target_model}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["status", "enroll", "recover"] + sorted(RESERVE_COMMANDS))
    parser.add_argument("--path", required=True)
    parser.add_argument("--journal")
    parser.add_argument("--provider-id")
    parser.add_argument("--model")
    parser.add_argument("--slots", type=int)
    parser.add_argument("--state-dir")
    parser.add_argument("--provider-prefix")
    parser.add_argument("--owner")
    args = parser.parse_args()
    def interrupted(signum, frame):
        raise InterruptedError("runner enrollment interrupted")
    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, interrupted)
    if args.command in RESERVE_COMMANDS:
        try:
            if not args.state_dir or not args.owner or (
                    args.command in ("reserve-pause", "set-target-model") and not args.provider_prefix):
                raise Refusal("missing --state-dir, --owner or --provider-prefix")
            if args.command == "set-target-model" and not args.model:
                raise Refusal("missing --model")
            print(json.dumps(RESERVE_COMMANDS[args.command](args)))
        except Refusal as exc:
            print("buyer-runner reservation refused: %s" % exc, file=sys.stderr)
            raise SystemExit(3)
        except BaseException as exc:
            # Never echo target bytes: they hold private provider inventory.
            raise SystemExit("buyer-runner reservation failed: " + type(exc).__name__)
        return
    if not args.journal:
        raise SystemExit("buyer-runner enrollment failed: --journal is required")
    try:
        execute(args)
    except Exception as exc:
        # Config and subprocess output can contain private inventory or keys.
        raise SystemExit("buyer-runner enrollment failed: " + type(exc).__name__)


if __name__ == "__main__":
    main()
