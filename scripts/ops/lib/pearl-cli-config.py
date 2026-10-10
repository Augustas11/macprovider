#!/usr/bin/env python3
"""Sent over SSH by scripts/ops/cli-release.sh `next --run`: the CLI train's
Pearl coordinator.yaml edits, with one coordinator restart.

  python3 - apply [layout flags] [--privacy-setup DIR KEY KEY_SHA256]
                  [--recommend VERSION TARGET_ID] [--revoke ID ...]

Under both Pearl locks (the installed, sha256-pinned coordinator_config_guard
LockSet: updater flock, coordinator deploy flock, refuse on a pricing
transaction journal) it:
  1. checks the running coordinator uses --config/--config-overlay exactly;
  2. edits coordinator.yaml with exact-anchor text transforms inside the
     compatibility_set / coordinator_advertised_version / privacy_class
     blocks, and proves the YAML changed by exactly the intended mutation;
  3. backs the file up under the backup root (0700);
  4. validates the new bytes with the running coordinator's binary, user and
     exact environment (/proc/<pid>/environ): --validate-config;
  5. atomically replaces the config, restarts the unit, waits for /healthz and
     checks the postconditions. On failure, while the file still holds the
     bytes it wrote, it puts back the bytes it read under the same locks
     (never a whole-file backup) and restarts again.

Admission needs no per-release edit (SPEC-002-R004): every well-formed
release identity from compatibility_set.target_id's repository is admitted
unless exactly listed in revoked_ids. --recommend moves only target_id and
latest_binary_version, and refuses a target that is foreign or revoked.
--revoke adds exact ids to compatibility_set.revoked_ids (the checked-in
one-time seed); /healthz must then report every one of them.
Nothing secret is printed.
"""
import argparse
import copy
import datetime
import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
# Canonical release identity: no leading zeros, components within int64 (the
# coordinator's config.ValidateCompatibilitySetID).
COMPAT_ID = re.compile(r"^([A-Za-z0-9_.-]{1,64}/[A-Za-z0-9_.-]{1,100}):v((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))@[0-9a-f]{40}$")
INT64_MAX = 2 ** 63 - 1


class Refused(Exception):
    pass


def block(text, header):
    """(start, end) of the lines indented under the one line matching header."""
    found = list(re.finditer(header, text, re.M))
    if len(found) != 1:
        raise Refused("expected exactly one %r anchor in coordinator.yaml, found %d" % (header, len(found)))
    m = found[0]
    indent = len(m.group(0)) - len(m.group(0).lstrip(" "))
    start = text.index("\n", m.end()) + 1 if "\n" in text[m.end():] else len(text)
    end = start
    for line in text[start:].splitlines(keepends=True):
        stripped = line.strip()
        if stripped and not stripped.startswith("#") and len(line) - len(line.lstrip(" ")) <= indent:
            break
        end += len(line)
    return start, end


def compat_repo(item):
    """owner/repo of a canonical compatibility_set_id, or None."""
    m = COMPAT_ID.fullmatch(item) if isinstance(item, str) else None
    if not m or len(item) > 256 or any(int(x) > INT64_MAX for x in m.group(2).split(".")):
        return None
    return m.group(1)


def add_revoked(text, ids):
    """Append ids to the block-style compatibility_set.revoked_ids, creating
    it right after target_id when absent."""
    start, end = block(text, r"^ *compatibility_set:[ \t]*$")
    body = text[start:end]
    found = list(re.finditer(r"^( *)revoked_ids:[ \t]*\n((?:\1 *- .*\n)+)", body, re.M))
    if found:
        m = found[0]
        if len(found) != 1:
            raise Refused("compatibility_set.revoked_ids must be one block-style list")
        prefix = m.group(2).splitlines()[0].split("- ", 1)[0]
        new = body[:m.end()] + "".join("%s- %s\n" % (prefix, i) for i in ids) + body[m.end():]
    else:
        if re.search(r"^ +revoked_ids:", body, re.M):
            raise Refused("compatibility_set.revoked_ids must be a block-style list")
        t = list(re.finditer(r"^( +)target_id:.*\n", body, re.M))
        if len(t) != 1:
            raise Refused("expected exactly one compatibility_set.target_id anchor")
        ind = t[0].group(1)
        new = body[:t[0].end()] + "%srevoked_ids:\n" % ind + "".join("%s- %s\n" % (ind, i) for i in ids) + body[t[0].end():]
    return text[:start] + new + text[end:]


def set_scalar(text, header, key, value):
    start, end = block(text, header)
    body = text[start:end]
    found = list(re.finditer(r"^( +)%s:[ \t]*(\S.*)$" % re.escape(key), body, re.M))
    if len(found) != 1:
        raise Refused("expected exactly one %s anchor" % key)
    m = found[0]
    quoted = m.group(2).strip()[:1] in ("'", '"')
    new = '%s%s: "%s"' % (m.group(1), key, value) if quoted else "%s%s: %s" % (m.group(1), key, value)
    return text[:start] + body[:m.start()] + new + body[m.end():] + text[end:]


def add_release_identities(text, metadata_dir, key_path):
    start, end = block(text, r"^privacy_class:[ \t]*$")
    body = text[start:end]
    if re.search(r"^ +release_code_identities:", body, re.M):
        raise Refused("privacy_class.release_code_identities already exists; refusing to rewrite it")
    first = next((l for l in body.splitlines() if l.strip() and not l.strip().startswith("#")), None)
    if first is None:
        raise Refused("privacy_class block is empty")
    ind = " " * (len(first) - len(first.lstrip(" ")))
    insert = "%srelease_code_identities:\n%s%smetadata_dir: %s\n%s%spublic_key_path: %s\n" % (
        ind, ind, ind, metadata_dir, ind, ind, key_path)
    return text[:start] + insert + text[start:]


def plan(text, args, now):
    """Return (new_text, expected_mutation(dict) -> None, summary)."""
    import yaml

    doc = yaml.safe_load(text) or {}
    compat = ((doc.get("coordinator") or {}).get("compatibility_set") or {})
    target = str(compat.get("target_id") or "")
    summary, new = {}, text

    if args.recommend:
        version, new_target = args.recommend
        if not VERSION.match(version):
            raise Refused("bad version")
        repo = compat_repo(new_target)
        if repo is None or repo != compat_repo(target):
            raise Refused("the new target %s is malformed or not from the current target's repository" % new_target)
        if new_target in [str(x) for x in compat.get("revoked_ids") or []]:
            raise Refused("the new target %s is in compatibility_set.revoked_ids" % new_target)
        if target != new_target:
            new = set_scalar(new, r"^ *compatibility_set:[ \t]*$", "target_id", new_target)
            summary["target_id"] = new_target
        latest = str(((doc.get("coordinator_advertised_version") or {}).get("latest_binary_version")) or "")
        if latest != version:
            new = set_scalar(new, r"^coordinator_advertised_version:[ \t]*$", "latest_binary_version", version)
            summary["latest_binary_version"] = version
    revoked_added = []
    if args.revoke:
        existing = [str(x) for x in compat.get("revoked_ids") or []]
        for item in args.revoke:
            if compat_repo(item) is None or compat_repo(item) != compat_repo(target):
                raise Refused("revocation %s is malformed or not from the target's repository" % item)
            if item == target or (args.recommend and item == args.recommend[1]):
                raise Refused("refusing to revoke the target %s" % item)
            if item not in existing and item not in revoked_added:
                revoked_added.append(item)
        if revoked_added:
            new = add_revoked(new, revoked_added)
            summary["revoked_added"] = revoked_added
    if args.privacy_setup:
        rel = ((doc.get("privacy_class") or {}).get("release_code_identities") or {})
        if not rel.get("metadata_dir"):
            new = add_release_identities(new, args.privacy_setup[0], args.privacy_setup[1])
            summary["release_code_identities"] = args.privacy_setup[0]

    def expected(d):
        if revoked_added:
            cs = d.setdefault("coordinator", {}).setdefault("compatibility_set", {})
            cs["revoked_ids"] = [str(x) for x in cs.get("revoked_ids") or []] + revoked_added
        if args.recommend:
            cs = d.setdefault("coordinator", {}).setdefault("compatibility_set", {})
            cs["target_id"] = args.recommend[1]
            d.setdefault("coordinator_advertised_version", {})["latest_binary_version"] = args.recommend[0]
        if "release_code_identities" in summary:
            d.setdefault("privacy_class", {})["release_code_identities"] = {
                "metadata_dir": args.privacy_setup[0], "public_key_path": args.privacy_setup[1]}

    if new != text:
        want = copy.deepcopy(doc)
        expected(want)
        if yaml.safe_load(new) != want:
            raise Refused("the anchored edit did not produce exactly the intended YAML change")
    return new, summary


def overlay_conflicts(overlay_path, args):
    import yaml

    if not overlay_path or overlay_path == "-":
        return
    with open(overlay_path) as f:
        ov = yaml.safe_load(f) or {}
    if (args.recommend or args.revoke) and "compatibility_set" in (ov.get("coordinator") or {}):
        raise Refused("the overlay sets coordinator.compatibility_set; reconcile it first")
    if args.recommend and "latest_binary_version" in (ov.get("coordinator_advertised_version") or {}):
        raise Refused("the overlay sets coordinator_advertised_version.latest_binary_version; reconcile it first")
    if args.privacy_setup and "release_code_identities" in (ov.get("privacy_class") or {}):
        raise Refused("the overlay sets privacy_class.release_code_identities; reconcile it first")


def running(args):
    pid = subprocess.run(["systemctl", "show", "-p", "MainPID", "--value", args.unit],
                         capture_output=True, text=True, timeout=15).stdout.strip()
    if not pid.isdigit() or pid == "0":
        raise Refused("the coordinator unit has no main process")
    proc = os.path.join(args.proc, pid)
    with open(os.path.join(proc, "cmdline"), "rb") as f:
        argv = [a.decode() for a in f.read().split(b"\0") if a]
    if "--config" not in argv or "--config-overlay" not in argv or \
            argv[argv.index("--config") + 1] != args.config or argv[argv.index("--config-overlay") + 1] != args.overlay:
        raise Refused("the running coordinator does not use --config %s --config-overlay %s" % (args.config, args.overlay))
    with open(os.path.join(proc, "environ"), "rb") as f:
        env = dict(e.decode().split("=", 1) for e in f.read().split(b"\0") if b"=" in e)
    uid = gid = None
    with open(os.path.join(proc, "status")) as f:
        for line in f:
            if line.startswith("Uid:"):
                uid = int(line.split()[1])
            elif line.startswith("Gid:"):
                gid = int(line.split()[1])
    return pid, argv[0], env, uid, gid


def as_service(cmd, env, uid, gid, timeout):
    kw = {"user": uid, "group": gid}
    if os.geteuid() == 0:
        kw["extra_groups"] = []
    return subprocess.run(cmd, env=env, capture_output=True, timeout=timeout, **kw)


def write_like(path, data, ref):
    st = os.stat(ref)
    fd, tmp = tempfile.mkstemp(prefix=".cli-release-", dir=os.path.dirname(path))
    try:
        os.fchown(fd, st.st_uid, st.st_gid)
        os.fchmod(fd, st.st_mode & 0o777)
        os.write(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)
    return tmp


def install(tmp, path):
    os.replace(tmp, path)
    dfd = os.open(os.path.dirname(path), os.O_RDONLY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)


def healthz(url):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        try:
            with opener.open(url, timeout=3) as resp:
                if resp.status == 200:
                    return json.loads(resp.read(1 << 20) or b"{}")
        except (OSError, ValueError):
            pass
        time.sleep(1)
    raise Refused("coordinator /healthz did not recover within 120 s")


def disk_digests(args):
    out = {}
    for key, path in (("config_sha256", args.config), ("overlay_sha256", args.overlay)):
        with open(path, "rb") as f:
            out[key] = hashlib.sha256(f.read()).hexdigest()
    return out


def boot_digests(unit):
    """config/overlay sha256 the current coordinator invocation logged at boot
    (event coordinator_config_applied, source boot), or None."""
    inv = subprocess.run(["systemctl", "show", "-p", "InvocationID", "--value", unit],
                         capture_output=True, text=True, timeout=15).stdout.strip()
    if not re.match(r"^[0-9a-f]{32}$", inv):
        return None
    proc = subprocess.run(["journalctl", "_SYSTEMD_INVOCATION_ID=" + inv, "--no-pager", "-o", "cat"],
                          capture_output=True, text=True, timeout=60)
    found = None
    for line in proc.stdout.splitlines() if proc.returncode == 0 else []:
        if "coordinator_config_applied" not in line:
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if event.get("event") == "coordinator_config_applied" and event.get("source") == "boot":
            found = {"config_sha256": event.get("config_sha256", ""), "overlay_sha256": event.get("overlay_sha256", "")}
    return found


def applied(args):
    return boot_digests(args.unit) == disk_digests(args)


def restart(args, old_pid):
    subprocess.run(["systemctl", "restart", args.unit], check=True, timeout=120, capture_output=True)
    health = healthz(args.healthz)
    pid, _, _, _, _ = running(args)
    if pid == old_pid:
        raise Refused("the coordinator main process did not change after the restart")
    deadline = time.monotonic() + 30
    while not applied(args):
        if time.monotonic() > deadline:
            raise Refused("the restarted coordinator did not log the on-disk config as its boot config")
        time.sleep(1)
    return health


def check_live(args, health):
    if args.recommend and health.get("recommended_binary_version") != args.recommend[0]:
        raise Refused("/healthz recommends %r, not %s" % (health.get("recommended_binary_version"), args.recommend[0]))
    if args.recommend and health.get("compatibility_policy_target_id") != args.recommend[1]:
        raise Refused("/healthz compatibility_policy_target_id is %r, not %s" % (
            health.get("compatibility_policy_target_id"), args.recommend[1]))
    live = health.get("compatibility_policy_revoked_ids")
    if args.revoke and (not isinstance(live, list) or set(args.revoke) - set(live)):
        raise Refused("/healthz compatibility_policy_revoked_ids does not list every requested revocation")


def privacy_preflight(args, env, uid, gid):
    metadata_dir, key_path, key_sha = args.privacy_setup
    for path in (metadata_dir, key_path):
        if not path.startswith("/") or not re.match(r"^[A-Za-z0-9._/-]+$", path):
            raise Refused("privacy setup paths must be absolute")
    with open(key_path, "rb") as f:
        if hashlib.sha256(f.read()).hexdigest() != key_sha:
            raise Refused("%s is not the repo release signing key" % key_path)
    test = shutil.which("test") or "/usr/bin/test"
    if as_service([test, "-r", key_path], env, uid, gid, 15).returncode != 0:
        raise Refused("the coordinator user cannot read %s" % key_path)
    if not os.path.lexists(metadata_dir):
        os.mkdir(metadata_dir, 0o750)
        os.chown(metadata_dir, os.geteuid(), gid)
        os.chmod(metadata_dir, 0o750)
    st = os.lstat(metadata_dir)
    if not os.path.isdir(metadata_dir) or os.path.islink(metadata_dir) or st.st_uid != os.geteuid() \
            or st.st_gid != gid or st.st_mode & 0o7777 != 0o750:
        raise Refused("%s must be a directory owned by the updater user and the coordinator group, mode 0750" % metadata_dir)


def guard(args):
    with open(args.guard, "rb") as f:
        source = f.read()
    if hashlib.sha256(source).hexdigest() != args.guard_sha256:
        raise Refused("the installed coordinator_config_guard.py differs from the reviewed source")
    spec = importlib.util.spec_from_loader("cli_release_config_guard", loader=None)
    module = importlib.util.module_from_spec(spec)
    exec(compile(source, args.guard, "exec"), module.__dict__)
    return module.LockSet(args.install_root, updater_lock=args.updater_lock,
                          required_uid=os.geteuid(), required_gid=os.getegid())


def apply(args):
    now = datetime.datetime.now(datetime.timezone.utc)
    with guard(args):
        pid, binary, env, uid, gid = running(args)
        overlay_conflicts(args.overlay, args)
        if args.privacy_setup:
            privacy_preflight(args, env, uid, gid)
        with open(args.config, "rb") as f:
            original = f.read()
        new_text, summary = plan(original.decode(), args, now)
        new = new_text.encode()
        result = {"changed": new != original, **summary}
        if new == original:
            # Disk already holds the requested state. It is complete only when
            # the running coordinator booted with exactly these bytes;
            # otherwise (an earlier run edited and stopped before its
            # restart, or another edit is pending) validate and restart.
            if applied(args):
                check_live(args, healthz(args.healthz))
                print(json.dumps(result, sort_keys=True))
                return
            check = as_service([binary, "--validate-config", "--config", args.config, "--config-overlay", args.overlay],
                               env, uid, gid, 120)
            if check.returncode != 0:
                raise Refused("the running coordinator binary rejects the on-disk config (--validate-config)")
            check_live(args, restart(args, pid))
            result["restarted"] = True
            result["recovered_unapplied_config"] = True
            print(json.dumps(result, sort_keys=True))
            return
        stamp = now.strftime("%Y%m%dT%H%M%SZ")
        os.makedirs(args.backup_root, mode=0o700, exist_ok=True)
        backup = tempfile.mkdtemp(prefix="%s-cli-release-" % stamp, dir=args.backup_root)
        os.chmod(backup, 0o700)
        shutil.copy2(args.config, os.path.join(backup, os.path.basename(args.config)))
        result["backup"] = backup
        tmp = write_like(args.config, new, args.config)
        try:
            check = as_service([binary, "--validate-config", "--config", tmp, "--config-overlay", args.overlay],
                               env, uid, gid, 120)
            if check.returncode != 0:
                raise Refused("the running coordinator binary rejects the edited config (--validate-config)")
            install(tmp, args.config)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
        try:
            check_live(args, restart(args, pid))
        except Exception:
            with open(args.config, "rb") as f:
                if f.read() == new:
                    install(write_like(args.config, original, args.config), args.config)
                    subprocess.run(["systemctl", "restart", args.unit], timeout=120, capture_output=True)
                    healthz(args.healthz)
                    result["restored"] = True
            raise
        result["restarted"] = True
        print(json.dumps(result, sort_keys=True))


def main(argv):
    p = argparse.ArgumentParser()
    p.add_argument("cmd", choices=["apply"])
    p.add_argument("--config", required=True)
    p.add_argument("--overlay", required=True)
    p.add_argument("--unit", required=True)
    p.add_argument("--install-root", required=True)
    p.add_argument("--guard", required=True)
    p.add_argument("--guard-sha256", required=True)
    p.add_argument("--updater-lock", required=True)
    p.add_argument("--backup-root", required=True)
    p.add_argument("--healthz", required=True)
    p.add_argument("--proc", default="/proc")
    p.add_argument("--privacy-setup", nargs=3, metavar=("DIR", "KEY", "KEY_SHA256"))
    p.add_argument("--recommend", nargs=2, metavar=("VERSION", "TARGET_ID"))
    p.add_argument("--revoke", nargs="+", metavar="ID")
    args = p.parse_args(argv)
    try:
        apply(args)
    except Refused as exc:
        sys.stderr.write("pearl-cli-config: REFUSED: %s\n" % exc)
        sys.exit(3)
    except Exception as exc:
        # Exception text could quote config or environment; print the type only.
        sys.stderr.write("pearl-cli-config: FAILED: %s\n" % type(exc).__name__)
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1:])
