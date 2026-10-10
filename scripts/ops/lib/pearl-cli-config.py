#!/usr/bin/env python3
"""Sent over SSH by scripts/ops/cli-release.sh `next --run`: the CLI train's
Pearl coordinator.yaml edits, with one coordinator restart.

  python3 - apply [layout flags] [--accepted-id ID] [--privacy-setup DIR KEY KEY_SHA256]
                  [--recommend VERSION TARGET_ID]

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

accepted_ids is capped at 8. At the cap it evicts the oldest accepted version
that is not the target, not the previous target/stable, and not in use: a
version is in use when it is the binary_version of the most recent connection
event of some provider seen in the last 14 days (`_anonymous` excluded;
provider_connection_events.db, read-only). It prints the per-version table
(latest-version provider counts, last seen) and refuses with it when nothing
is evictable. Nothing secret is printed.
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
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.request

ACCEPTED_CAP = 8
IN_USE_WINDOW = datetime.timedelta(days=14)
VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
COMPAT_VERSION = re.compile(r":v([0-9]+\.[0-9]+\.[0-9]+)@[0-9a-f]{40}$")


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


def scalar(value):
    return value.strip().strip("'\"")


def compat_items(text):
    start, end = block(text, r"^ *compatibility_set:[ \t]*$")
    body = text[start:end]
    found = list(re.finditer(r"^( *)accepted_ids:[ \t]*\n((?:\1 *- .*\n)+)", body, re.M))
    if len(found) != 1:
        raise Refused("compatibility_set.accepted_ids must be one block-style list")
    m = found[0]
    lines = m.group(2).splitlines(keepends=True)
    return start + m.start(2), start + m.end(2), lines


def set_accepted(text, add, remove):
    a, b, lines = compat_items(text)
    kept = [l for l in lines if scalar(l.split("- ", 1)[1]) != remove] if remove else list(lines)
    if remove and len(kept) != len(lines) - 1:
        raise Refused("eviction anchor did not match exactly one accepted id")
    if add:
        prefix = lines[0].split("- ", 1)[0]
        kept.append("%s- %s\n" % (prefix, add))
    return text[:a] + "".join(kept) + text[b:]


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


def parse_time(value):
    # Pearl writes RFC3339 with up to nanoseconds; Python takes microseconds.
    value = re.sub(r"(\.\d{6})\d+", r"\1", value.strip()).replace("Z", "+00:00")
    parsed = datetime.datetime.fromisoformat(value)
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=datetime.timezone.utc)


def version_key(version):
    return tuple(int(x) for x in version.split("."))


def latest_versions(db_path, now):
    """{version: (providers whose latest connection uses it, last seen)} over
    providers seen in the last IN_USE_WINDOW, read-only. A provider's version
    is the binary_version of its most recent connection event that names one."""
    since = now - IN_USE_WINDOW
    latest = {}
    with sqlite3.connect("file:%s?mode=ro" % db_path, uri=True, timeout=5) as db:
        rows = db.execute("SELECT id, provider_id, binary_version, occurred_at_utc FROM provider_connection_events "
                          "WHERE binary_version != '' AND provider_id NOT IN ('', '_anonymous')")
        for row_id, provider, version, stamp in rows:
            try:
                when = parse_time(stamp)
            except ValueError:
                continue
            if when < since:
                continue
            key = (when, row_id)
            if provider not in latest or key > latest[provider][0]:
                latest[provider] = (key, version)
    out = {}
    for (when, _), version in latest.values():
        count, seen = out.get(version, (0, None))
        out[version] = (count + 1, when if seen is None or when > seen else seen)
    return out


def eviction_table(accepted, target, protected, usage):
    lines = ["%-72s %-9s %9s  %s" % ("accepted id", "version", "providers", "last seen (latest-version providers)")]
    for item in accepted:
        m = COMPAT_VERSION.search(item)
        version = m.group(1) if m else "?"
        count, seen = usage.get(version, (0, None))
        role = " target" if item == target else " protected" if item in protected else ""
        lines.append("%-72s %-9s %9d  %s%s" % (item, version, count, seen.isoformat() if seen else "-", role))
    return "\n".join(lines)


def choose_eviction(accepted, target, keep, db_path, now):
    """Evict the oldest accepted version that is not the target, not the
    previous target/stable, not kept, and that no provider (seen in the last
    14 days) has as its latest connection version."""
    versions = {}
    for item in accepted:
        m = COMPAT_VERSION.search(item)
        versions[item] = m.group(1) if m else None
    usage = latest_versions(db_path, now)
    protected = {target, *keep}
    target_version = versions.get(target)
    if target_version:
        older = [i for i in accepted if versions[i] and version_key(versions[i]) < version_key(target_version)]
        if older:
            protected.add(max(older, key=lambda i: version_key(versions[i])))  # the previous target/stable
    table = eviction_table(accepted, target, protected, usage)
    sys.stderr.write("accepted_ids by providers' latest connection version (last 14 days):\n%s\n" % table)
    candidates = [i for i in accepted if i not in protected and versions[i] and versions[i] not in usage]
    if not candidates:
        raise Refused("accepted_ids is at the cap of %d and no id is evictable: every non-protected version is "
                      "some provider's latest connection version (table above)" % ACCEPTED_CAP)
    return min(candidates, key=lambda i: version_key(versions[i])), table


def plan(text, args, now):
    """Return (new_text, expected_mutation(dict) -> None, summary)."""
    import yaml

    doc = yaml.safe_load(text) or {}
    compat = ((doc.get("coordinator") or {}).get("compatibility_set") or {})
    accepted = [str(x) for x in compat.get("accepted_ids") or []]
    target = str(compat.get("target_id") or "")
    mutations, summary, new = [], {}, text

    def add_accepted(item, keep):
        nonlocal new, accepted
        if item in accepted:
            return
        evict = None
        if len(accepted) >= ACCEPTED_CAP:
            evict, table = choose_eviction(accepted, target, keep, args.events_db, now)
            summary["eviction_table"] = table.splitlines()
        new = set_accepted(new, item, evict)
        accepted = [a for a in accepted if a != evict] + [item]
        summary.setdefault("accepted_added", []).append(item)
        if evict:
            summary.setdefault("accepted_evicted", []).append(evict)

    if args.accepted_id:
        add_accepted(args.accepted_id, [args.accepted_id])
    if args.recommend:
        version, new_target = args.recommend
        if not VERSION.match(version):
            raise Refused("bad version")
        if target and target != new_target:
            add_accepted(target, [new_target])  # the prior target stays accepted
        add_accepted(new_target, [target])
        if target != new_target:
            new = set_scalar(new, r"^ *compatibility_set:[ \t]*$", "target_id", new_target)
            summary["target_id"] = new_target
        latest = str(((doc.get("coordinator_advertised_version") or {}).get("latest_binary_version")) or "")
        if latest != version:
            new = set_scalar(new, r"^coordinator_advertised_version:[ \t]*$", "latest_binary_version", version)
            summary["latest_binary_version"] = version
    if args.privacy_setup:
        rel = ((doc.get("privacy_class") or {}).get("release_code_identities") or {})
        if not rel.get("metadata_dir"):
            new = add_release_identities(new, args.privacy_setup[0], args.privacy_setup[1])
            summary["release_code_identities"] = args.privacy_setup[0]

    def expected(d):
        if args.accepted_id or args.recommend:
            cs = d.setdefault("coordinator", {}).setdefault("compatibility_set", {})
            cs["accepted_ids"] = accepted
        if args.recommend:
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
        if len(accepted) > ACCEPTED_CAP:
            raise Refused("accepted_ids would exceed the cap")
    return new, summary


def overlay_conflicts(overlay_path, args):
    import yaml

    if not overlay_path or overlay_path == "-":
        return
    with open(overlay_path) as f:
        ov = yaml.safe_load(f) or {}
    if (args.accepted_id or args.recommend) and "compatibility_set" in (ov.get("coordinator") or {}):
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


def restart(args, old_pid):
    subprocess.run(["systemctl", "restart", args.unit], check=True, timeout=120, capture_output=True)
    health = healthz(args.healthz)
    pid, _, _, _, _ = running(args)
    if pid == old_pid:
        raise Refused("the coordinator main process did not change after the restart")
    return health


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
            health = restart(args, pid)
            if args.recommend and health.get("recommended_binary_version") != args.recommend[0]:
                raise Refused("/healthz recommends %r, not %s" % (health.get("recommended_binary_version"), args.recommend[0]))
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
    p.add_argument("--events-db", required=True)
    p.add_argument("--backup-root", required=True)
    p.add_argument("--healthz", required=True)
    p.add_argument("--proc", default="/proc")
    p.add_argument("--accepted-id")
    p.add_argument("--privacy-setup", nargs=3, metavar=("DIR", "KEY", "KEY_SHA256"))
    p.add_argument("--recommend", nargs=2, metavar=("VERSION", "TARGET_ID"))
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
