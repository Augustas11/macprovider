#!/usr/bin/env python3
"""Read and atomically migrate Pearl's applied compatibility policy.

This program is streamed to Pearl by scripts/ops/compatibility-policy-migrate.sh.
It intentionally prints only policy identities and digests: never YAML or env values.
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
import urllib.request
import urllib.parse

try:
    import yaml
except Exception as exc:  # pragma: no cover - exercised on Pearl
    sys.stderr.write("PyYAML is required on Pearl: %s\n" % exc)
    sys.exit(2)

STATE = os.environ.get("MACPROVIDER_APPLIED_CONFIG_STATE", "/run/macprovider/coordinator-applied-config.json")
COORDINATOR = os.environ.get("MACPROVIDER_COORDINATOR_BIN", "/opt/macprovider/coordinator")
HEALTH = os.environ.get("MACPROVIDER_COORDINATOR_HEALTH", "http://127.0.0.1:8444/healthz")
COMPONENT = r"(?:0|[1-9][0-9]{0,18})"
VERSION_TEXT = COMPONENT + r"\." + COMPONENT + r"\." + COMPONENT
VERSION = re.compile("^" + VERSION_TEXT + "$")
SET_ID = re.compile(r"^[A-Za-z0-9_.-]{1,64}/[A-Za-z0-9_.-]{1,100}:v(" + VERSION_TEXT + r")@[0-9a-f]{40}$")

def valid_version(value):
    return isinstance(value, str) and bool(VERSION.fullmatch(value)) and all(int(part) <= 2**63 - 1 for part in value.split("."))

def valid_set_id(value):
    match = SET_ID.fullmatch(value) if isinstance(value, str) else None
    return bool(match and valid_version(match.group(1)))

def fail(message):
    raise RuntimeError(message)

def digest(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()

def service_environment():
    try:
        pid = running_main_pid()
        with open("/proc/%d/environ" % pid, "rb") as f:
            raw = f.read().split(b"\0")
    except Exception:
        fail("running coordinator environment is unreadable")
    env = {}
    for entry in raw:
        key, sep, value = entry.partition(b"=")
        if sep:
            env[key.decode("utf-8", "strict")] = value.decode("utf-8", "strict")
    return env

def running_main_pid():
    try:
        pid = int(subprocess.check_output(["systemctl", "show", "--property", "MainPID", "--value", "macprovider-coordinator"], text=True).strip())
    except Exception:
        fail("coordinator MainPID is unavailable")
    if pid <= 1 or not os.path.isdir("/proc/%d" % pid): fail("coordinator MainPID is unavailable")
    return pid

def process_arg(argv, flag, default=""):
    for index, value in enumerate(argv):
        if value == flag and index + 1 < len(argv): return argv[index + 1]
        if value.startswith(flag + "="): return value[len(flag) + 1:]
    return default

def boot_record_binds_running_process(record):
    try:
        pid = running_main_pid()
        with open("/proc/%d/cmdline" % pid, "rb") as f:
            argv = [v.decode("utf-8", "strict") for v in f.read().split(b"\0") if v]
        loaded = datetime.datetime.fromisoformat(record["loaded_at"].replace("Z", "+00:00"))
        started_raw = subprocess.check_output(["systemctl", "show", "--timestamp=us+utc", "--property", "ExecMainStartTimestamp", "--value", "macprovider-coordinator"], text=True).strip()
        started = datetime.datetime.strptime(started_raw, "%a %Y-%m-%d %H:%M:%S.%f UTC").replace(tzinfo=datetime.timezone.utc)
    except Exception:
        return False
    return (process_arg(argv, "--config", "coordinator.yaml") == record["config_path"] and
            process_arg(argv, "--config-overlay") == record["overlay_path"] and loaded >= started)

def load_yaml(path, expected_digest=None):
    with open(path, "rb") as f:
        raw = f.read()
    if expected_digest is not None and hashlib.sha256(raw).hexdigest() != expected_digest:
        fail("config bytes changed before policy parsing")
    try:
        value = yaml.safe_load(raw) or {}
    except Exception:
        fail("YAML could not be decoded")
    if not isinstance(value, dict):
        fail("YAML root is not a mapping")
    return value

def merge(base, overlay):
    out = dict(base)
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = merge(out[key], value)
        else:
            out[key] = value
    return out

def applied():
    try:
        with open(STATE) as f:
            record = json.load(f)
    except Exception as exc:
        fail("applied-config record unreadable: %s" % exc)
    required = ("schema", "config_path", "config_sha256", "overlay_path", "overlay_sha256", "source")
    if any(not isinstance(record.get(k), str) for k in required) or not record.get("config_path") or not record.get("config_sha256") or not record.get("source"):
        fail("applied-config record lacks required identity fields")
    if record["source"] not in ("boot", "sighup"):
        fail("applied-config record has invalid source")
    if record["schema"] != "macprovider.coordinator-applied-config.v1":
        fail("applied-config record schema is unsupported")
    config, overlay = record["config_path"], record["overlay_path"]
    if not config.startswith("/") or (overlay and not overlay.startswith("/")):
        fail("applied-config record names a non-absolute path")
    if digest(config) != record["config_sha256"]:
        fail("on-disk config or overlay drifted from the applied-config record")
    if overlay:
        if digest(overlay) != record["overlay_sha256"]:
            fail("on-disk config or overlay drifted from the applied-config record")
    elif record["overlay_sha256"]:
        fail("applied-config record has an overlay digest without an overlay path")
    return record, config, overlay

def policy_state():
    record, config_path, overlay_path = applied()
    merged = merge(load_yaml(config_path, record["config_sha256"]), load_yaml(overlay_path, record["overlay_sha256"]) if overlay_path else {})
    policy = ((merged.get("coordinator") or {}).get("compatibility_set") or {})
    if not isinstance(policy, dict):
        fail("active compatibility_set is not a mapping")
    target = policy.get("target_id")
    accepted = policy.get("accepted_ids") or []
    floor = policy.get("minimum_version") or ""
    revoked = policy.get("revoked_ids") or []
    if not valid_set_id(target):
        fail("active compatibility_set.target_id is missing or malformed")
    if not isinstance(accepted, list) or any(not valid_set_id(x) for x in accepted):
        fail("active compatibility_set.accepted_ids is malformed")
    if not isinstance(revoked, list) or any(not valid_set_id(x) for x in revoked):
        fail("active compatibility_set.revoked_ids is malformed")
    if floor and (not valid_version(floor)):
        fail("active compatibility_set.minimum_version is malformed")
    return record, config_path, overlay_path, policy, target, accepted, floor, revoked

def report(candidate, require_boot=False):
    record, _, _, _, target, accepted, floor, revoked = policy_state()
    if require_boot and record["source"] != "boot":
        fail("legacy fallback requires a boot-applied config record, not a generic SIGHUP record")
    if require_boot:
        if not boot_record_binds_running_process(record):
            fail("boot-applied config record is stale or not bound to the running coordinator")
    if candidate:
        if not valid_set_id(candidate):
            fail("candidate compatibility_set_id is malformed")
        if floor:
            fail("active policy is version_floor; use health evidence")
    print(json.dumps({
        "mode": "version_floor" if floor else "legacy_allowlist",
        "target_id": target,
        "accepted_ids": accepted,
        "minimum_version": floor,
        "revoked_ids": revoked,
        "config_sha256": record["config_sha256"],
        "overlay_sha256": record["overlay_sha256"],
        "candidate_admitted": bool(candidate and candidate in accepted),
    }, sort_keys=True))

def atomic_write(path, raw, metadata):
    directory = os.path.dirname(path)
    fd, temp = tempfile.mkstemp(prefix=".compatibility-policy-", suffix=".tmp", dir=directory)
    try:
        os.fchmod(fd, stat.S_IMODE(metadata.st_mode))
        os.fchown(fd, metadata.st_uid, metadata.st_gid)
        with os.fdopen(fd, "wb") as f:
            f.write(raw)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temp, path)
        dfd = os.open(directory, os.O_DIRECTORY)
        try: os.fsync(dfd)
        finally: os.close(dfd)
    except Exception:
        try: os.unlink(temp)
        except OSError: pass
        raise

def connected_fleet_allows(floor):
    token = service_environment().get("OPERATOR_KEY", "")
    if not token:
        fail("OPERATOR_KEY is unavailable for the authenticated connected-fleet check")
    seen = set(); versions = []; expected = None; after = {}
    for _ in range(100):
        url = "http://127.0.0.1:8444/admin/providers?limit=100"
        if after: url += "&" + urllib.parse.urlencode(after)
        request = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
        try:
            with urllib.request.urlopen(request, timeout=5) as response: doc = json.load(response)
        except Exception:
            fail("authenticated connected-fleet inventory is unreadable")
        summary = doc.get("summary") or {}; count = summary.get("connected")
        if type(count) is not int or count < 0 or (expected is not None and count != expected):
            fail("connected-fleet inventory count is malformed or changed")
        expected = count
        for row in doc.get("providers") or []:
            if not isinstance(row, dict) or row.get("presence") != "connected": continue
            pid, binary, compat = row.get("provider_id"), row.get("binary_version"), row.get("compatibility_set_id")
            if not isinstance(pid, str) or not pid or pid in seen or not valid_version(binary):
                fail("connected provider identity or binary version is malformed")
            m = SET_ID.fullmatch(compat or "")
            if not m or m.group(0).split(":v", 1)[1].split("@", 1)[0] != binary:
                fail("connected provider compatibility identity is malformed")
            seen.add(pid); versions.append(binary)
        after_id, after_seen = doc.get("next_after", ""), doc.get("next_after_seen", "")
        if not after_id and not after_seen: break
        if not isinstance(after_id, str) or not isinstance(after_seen, str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,256}", after_id) or not re.fullmatch(r"[0-9TZ:.-]+", after_seen):
            fail("connected-fleet pagination token is malformed")
        after = {"after": after_id, "after_seen": after_seen}
    else:
        fail("connected-fleet inventory pagination did not finish")
    if expected is None or not versions or len(versions) != expected:
        fail("connected-fleet inventory is incomplete")
    if tuple(map(int, floor.split("."))) > min(tuple(map(int, v.split("."))) for v in versions):
        fail("requested floor is above a connected provider version")

def inventory(suffix):
    if not re.fullmatch(r"(?:&[A-Za-z0-9._%=-]+)*", suffix):
        fail("inventory query suffix is malformed")
    token = service_environment().get("OPERATOR_KEY", "")
    if not token: fail("OPERATOR_KEY is unavailable for the authenticated inventory")
    request = urllib.request.Request("http://127.0.0.1:8444/admin/providers?limit=100" + suffix, headers={"Authorization": "Bearer " + token})
    try:
        with urllib.request.urlopen(request, timeout=10) as response: sys.stdout.write(response.read().decode("utf-8"))
    except Exception:
        fail("authenticated provider inventory is unreadable")

def migrate(floor):
    if not valid_version(floor):
        fail("floor must be strict MAJOR.MINOR.PATCH")
    record, config_path, overlay_path, policy, target, accepted, old_floor, revoked = policy_state()
    if not overlay_path:
        fail("active coordinator has no overlay path to migrate atomically")
    if old_floor:
        fail("active policy is already version_floor")
    if target not in accepted or len(accepted) < 2 or revoked:
        fail("active legacy allowlist is not a valid migration source")
    with open(overlay_path, "rb") as f:
        original = f.read()
    # Repeat the complete authenticated inventory check after both Pearl locks
    # are held (the caller takes them before this helper starts).
    connected_fleet_allows(floor)
    overlay = load_yaml(overlay_path)
    coordinator = overlay.setdefault("coordinator", {})
    if not isinstance(coordinator, dict):
        fail("overlay coordinator is not a mapping")
    next_policy = dict(policy)
    next_policy["target_id"] = target
    next_policy["minimum_version"] = floor
    next_policy["accepted_ids"] = []
    next_policy["revoked_ids"] = []
    coordinator["compatibility_set"] = next_policy
    raw = yaml.safe_dump(overlay, sort_keys=False).encode()
    metadata = os.stat(overlay_path)
    atomic_write(overlay_path, raw, metadata)
    new_overlay_digest = hashlib.sha256(raw).hexdigest()
    try:
        check = subprocess.run([COORDINATOR, "--config", config_path, "--config-overlay", overlay_path, "--validate-config"], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, env=service_environment())
        if check.returncode:
            fail("coordinator validation rejected migrated policy")
        main_pid = int(subprocess.check_output(["systemctl", "show", "--property", "MainPID", "--value", "macprovider-coordinator"], text=True).strip())
        if main_pid <= 1:
            fail("coordinator MainPID is unavailable")
        os.kill(main_pid, signal.SIGHUP)
        for _ in range(20):
            time.sleep(1)
            try:
                with open(STATE) as f: now = json.load(f)
            except Exception:
                continue
            if now.get("source") == "sighup" and now.get("config_sha256") == record["config_sha256"] and now.get("overlay_sha256") == new_overlay_digest:
                try:
                    with urllib.request.urlopen(HEALTH, timeout=3) as response:
                        health = json.load(response)
                except Exception:
                    continue
                if (health.get("compatibility_policy_mode") == "version_floor" and
                    health.get("compatibility_policy_target_id") == target and
                    health.get("compatibility_policy_minimum_version") == floor and
                    health.get("compatibility_policy_revoked_ids") == []):
                    print(json.dumps({"mode": "version_floor", "target_id": target, "minimum_version": floor, "config_sha256": record["config_sha256"], "overlay_sha256": new_overlay_digest}, sort_keys=True))
                    return
        fail("SIGHUP did not prove the migrated overlay was applied")
    except Exception as original_error:
        atomic_write(overlay_path, original, metadata)
        try:
            main_pid = int(subprocess.check_output(["systemctl", "show", "--property", "MainPID", "--value", "macprovider-coordinator"], text=True).strip())
            if main_pid <= 1: fail("rollback has no running coordinator")
            os.kill(main_pid, signal.SIGHUP)
            old_overlay_digest = record["overlay_sha256"]
            for _ in range(20):
                time.sleep(1)
                try:
                    with open(STATE) as f: restored = json.load(f)
                    with urllib.request.urlopen(HEALTH, timeout=3) as response: health = json.load(response)
                except Exception:
                    continue
                if (restored.get("source") == "sighup" and restored.get("config_sha256") == record["config_sha256"] and restored.get("overlay_sha256") == old_overlay_digest and health.get("compatibility_policy_mode") == "legacy_allowlist" and health.get("compatibility_policy_target_id") == target):
                    raise original_error
            fail("rollback SIGHUP did not prove the prior policy was restored")
        except Exception:
            raise

def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    inspect = sub.add_parser("inspect")
    inspect.add_argument("--candidate", default="")
    inspect.add_argument("--require-boot", action="store_true")
    move = sub.add_parser("migrate")
    move.add_argument("--floor", required=True)
    inv = sub.add_parser("inventory")
    inv.add_argument("--suffix", default="")
    args = parser.parse_args()
    if args.command == "inspect": report(args.candidate, args.require_boot)
    elif args.command == "migrate": migrate(args.floor)
    else: inventory(args.suffix)

if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        sys.stderr.write("compatibility policy: %s\n" % exc)
        sys.exit(1)
