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
one-time seed, or the release a rollback moves off); /healthz must then report
every one of them. --recommend PREV --revoke CURRENT_TARGET together is the
revoked-build rollback (SPEC-020-R007): the target after the edit is never
revoked.
Nothing secret is printed.

Also used by scripts/ops/pearl-runtime.sh PEARL_RUNTIME_TASK=compute-integrity-enable
(SPEC-036 FR-20 private corpus):
  python3 - ci-facts [layout flags] --ci-corpus PATH            read-only facts
  python3 - apply-compute-integrity [layout flags] --ci-corpus PATH
            --ci-staged STAGED --ci-sha256 SHA256
Under the same locks it checks the staged corpus (sha256, the coordinator's
corpus rules), installs it root-owned, coordinator group, mode 0640, adds
compute_integrity.scoring.corpus_path to the overlay (backup first), validates
with the running coordinator, restarts once and requires the new invocation to
log the corpus loaded and scheduling enabled; on failure it restores the
overlay and corpus and restarts again. Locally, `validate-corpus PATH` applies
the corpus rules to a file and prints only its size, prompt count and sha256.

Also used by scripts/ops/pearl-runtime.sh PEARL_RUNTIME_TASK=vision-qualification
(#2016 operator-reviewed native-vision qualification):
  python3 - vq-facts [layout flags]                             read-only facts
  python3 - apply-vision-qualification [layout flags] --vq-staged STAGED
            --vq-sha256 SHA256
Under the same locks it checks the staged canonical record (sha256, the
coordinator's VisionQualificationConfig rules), sets
routing.vision_qualifications to exactly [record] in the overlay (backup
first; refuses a different existing list), validates with the running
coordinator, restarts once and requires the new invocation to log the
on-disk files as its boot config; on failure it restores the overlay and
restarts again. Locally, `validate-vision-qualification PATH [OUT]` applies
the rules and prints only the field count and the entry sha256.
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
            # The target after this edit may not be revoked. With --recommend
            # that is the new target, so revoking the release being moved off
            # is the revoked-build rollback (SPEC-020-R007).
            if item == (args.recommend[1] if args.recommend else target):
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


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def healthz(url):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
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


def policy_preflight(args):
    """Before any edit: the --healthz listener must report the compatibility
    policy, or check_live can never pass and the restart is wasted (the
    buyer listener's /healthz has no compatibility_policy_* fields)."""
    if (args.recommend or args.revoke) and "compatibility_policy_mode" not in healthz(args.healthz):
        raise Refused("%s reports no compatibility_policy_mode; point --healthz at the provider listener" % args.healthz)


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
        policy_preflight(args)
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


# --- compute-integrity private corpus (SPEC-036 FR-20) -----------------------
#
# Used by scripts/ops/pearl-runtime.sh PEARL_RUNTIME_TASK=compute-integrity-enable
# and scripts/compute-integrity-corpus.py. Nothing here prints corpus content.

# The coordinator's ParseCorpus (internal/computeintegrity/scoring_corpus.go):
# a version and a non-empty prompt list, each prompt a non-blank system and
# user message of at most 2 KiB of UTF-8. This copy is stricter (exact keys,
# no duplicate keys, no lone surrogates), so what it accepts the coordinator
# accepts; internal/computeintegrity/testdata/corpus_parse_cases.json pins both.
CORPUS_MAX_MESSAGE_BYTES = 2 * 1024
# Transport bound for the ops tooling, not a coordinator rule.
CORPUS_MAX_BYTES = 4 * 1024 * 1024
CI_EVENTS = ("compute_integrity_corpus_loaded", "compute_integrity_corpus_invalid",
             "compute_integrity_private_corpus_missing", "compute_integrity_scoring_started")


def parse_corpus(raw):
    """(version, prompt count) of a valid corpus document; Refused otherwise.
    Reasons never quote the document."""
    if len(raw) > CORPUS_MAX_BYTES:
        raise Refused("corpus is larger than %d bytes" % CORPUS_MAX_BYTES)

    def pairs(items):
        keys = [k for k, _ in items]
        if len(set(keys)) != len(keys):
            raise Refused("corpus has a duplicate JSON key")
        return dict(items)

    try:
        doc = json.loads(raw.decode("utf-8", errors="strict"), object_pairs_hook=pairs)
    except (UnicodeDecodeError, ValueError):
        raise Refused("corpus is not UTF-8 JSON")
    if not isinstance(doc, dict) or set(doc) != {"version", "prompts"}:
        raise Refused("corpus must be an object with exactly the keys version and prompts")
    version, prompts = doc["version"], doc["prompts"]
    if not isinstance(version, str) or not version.strip() or not isinstance(prompts, list) or not prompts:
        raise Refused("corpus version and prompts are required")
    for i, p in enumerate(prompts):
        if not isinstance(p, dict) or set(p) != {"system", "user"}:
            raise Refused("corpus prompt %d must have exactly the keys system and user" % i)
        for msg in (p["system"], p["user"]):
            if not isinstance(msg, str) or not msg.strip():
                raise Refused("corpus prompt %d has an empty message" % i)
            try:
                size = len(msg.encode("utf-8", errors="strict"))
            except UnicodeEncodeError:
                raise Refused("corpus prompt %d is not UTF-8" % i)
            if size > CORPUS_MAX_MESSAGE_BYTES:
                raise Refused("corpus prompt %d has a message over %d bytes" % (i, CORPUS_MAX_MESSAGE_BYTES))
    return version, len(prompts)


def validate_corpus_file(path):
    st = os.lstat(path)
    if not os.path.isfile(path) or os.path.islink(path):
        raise Refused("corpus is not a regular file")
    if st.st_size > CORPUS_MAX_BYTES:
        raise Refused("corpus is larger than %d bytes" % CORPUS_MAX_BYTES)
    with open(path, "rb") as f:
        raw = f.read(CORPUS_MAX_BYTES + 1)
    _, count = parse_corpus(raw)
    return {"prompts": count, "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest(),
            "private": st.st_mode & 0o7777 == 0o600}


def load_effective(args):
    import yaml

    with open(args.config) as f:
        base = yaml.safe_load(f) or {}
    with open(args.overlay) as f:
        overlay = yaml.safe_load(f) or {}
    if not isinstance(base, dict) or not isinstance(overlay, dict):
        raise Refused("coordinator.yaml and the overlay must be YAML mappings")
    return base, overlay


def ci_scoring(doc):
    ci = doc.get("compute_integrity")
    if ci is None:
        return {}
    if not isinstance(ci, dict) or not isinstance(ci.get("scoring", {}) or {}, dict):
        raise Refused("compute_integrity must be a mapping with a scoring mapping")
    return ci.get("scoring") or {}


def invocation_events(unit, names):
    """Events named in names that the current coordinator invocation logged."""
    inv = subprocess.run(["systemctl", "show", "-p", "InvocationID", "--value", unit],
                         capture_output=True, text=True, timeout=15).stdout.strip()
    if not re.match(r"^[0-9a-f]{32}$", inv):
        raise Refused("cannot read the coordinator's invocation id")
    proc = subprocess.run(["journalctl", "_SYSTEMD_INVOCATION_ID=" + inv, "--no-pager", "-o", "cat"],
                          capture_output=True, text=True, timeout=60)
    if proc.returncode != 0:
        raise Refused("cannot read the coordinator's journal")
    found = []
    for line in proc.stdout.splitlines():
        if not any(n in line for n in names):
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if isinstance(event, dict) and event.get("event") in names:
            found.append(event)
    return found


def ci_journal(unit):
    """What the running coordinator logged about compute-integrity scoring."""
    out = {"scoring_started": None, "scoring_enabled": None, "corpus_loaded_prompts": None,
           "corpus_loaded_version": None, "corpus_invalid": False, "private_corpus_missing": False}
    for e in invocation_events(unit, CI_EVENTS):
        name = e.get("event")
        if name == "compute_integrity_scoring_started":
            out["scoring_started"] = True
            out["scoring_enabled"] = e.get("enabled") is True
        elif name == "compute_integrity_corpus_loaded":
            prompts = e.get("prompts")
            out["corpus_loaded_prompts"] = prompts if isinstance(prompts, int) else None
            out["corpus_loaded_version"] = e.get("version") if isinstance(e.get("version"), str) else None
        elif name == "compute_integrity_corpus_invalid":
            out["corpus_invalid"] = True
        elif name == "compute_integrity_private_corpus_missing":
            out["private_corpus_missing"] = True
    return out


def file_sha256(path):
    if not os.path.isfile(path) or os.path.islink(path):
        return None
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def ci_facts(args):
    # The files read must be the ones the running coordinator was started with.
    _, _, _, _, gid = running(args)
    base, overlay = load_effective(args)
    b, o = ci_scoring(base), ci_scoring(overlay)
    enabled = o.get("enabled", b.get("enabled", True))
    j = ci_journal(args.unit)
    facts = {
        "effective_corpus_path": str(o.get("corpus_path", b.get("corpus_path", "")) or ""),
        "overlay_corpus_path": str(o.get("corpus_path", "") or ""),
        "overlay_sets_compute_integrity": "compute_integrity" in overlay,
        "kill_switch": enabled is False,
        "installed_sha256": file_sha256(args.ci_corpus),
        # The running process loaded the corpus now installed (prompt count
        # and version); the version itself is never printed.
        "loaded_matches_installed": installed_matches(args.ci_corpus, args.unit, j),
        "installed_mode_ok": installed_mode_ok(args.ci_corpus, gid),
        "scoring_enabled": j["scoring_enabled"],
        "corpus_loaded_prompts": j["corpus_loaded_prompts"],
        "corpus_invalid": j["corpus_invalid"],
        "private_corpus_missing": j["private_corpus_missing"],
    }
    print(json.dumps(facts, sort_keys=True))


def main_start(unit):
    """Unix second the unit's current main process started, or None."""
    out = subprocess.run(["systemctl", "show", "--timestamp=unix", "-p", "ExecMainStartTimestamp", "--value", unit],
                         capture_output=True, text=True, timeout=15).stdout.strip()
    m = re.match(r"^@([0-9]+)$", out)
    return int(m.group(1)) if m else None


def installed_matches(path, unit, j):
    """The running process loaded the corpus installed now: the file has not
    changed since the process started (the coordinator reads it once at
    start; the journal carries no content hash) and its version and prompt
    count are the ones the process logged."""
    if not os.path.isfile(path) or os.path.islink(path):
        return False
    start = main_start(unit)
    try:
        if start is None or int(os.lstat(path).st_ctime) >= start:
            return False
        with open(path, "rb") as f:
            version, prompts = parse_corpus(f.read(CORPUS_MAX_BYTES + 1))
    except (OSError, Refused):
        return False
    return j["corpus_loaded_prompts"] == prompts and j["corpus_loaded_version"] == version


def installed_mode_ok(path, gid):
    """Root-owned (this process), the coordinator's group, exactly 0640."""
    try:
        st = os.lstat(path)
    except OSError:
        return False
    return os.path.isfile(path) and not os.path.islink(path) and st.st_uid == os.geteuid() \
        and st.st_gid == gid and st.st_mode & 0o7777 == 0o640


def safe_parent(path):
    """The directory a root process writes the corpus into, and every
    ancestor of its resolved path, is owned by root or this process's user
    and not writable by group or others (sticky directories excepted)."""
    cur = os.path.realpath(os.path.dirname(path))
    while True:
        st = os.lstat(cur)
        if st.st_uid not in (0, os.geteuid()) or (st.st_mode & 0o022 and not st.st_mode & 0o1000):
            raise Refused("%s must be owned by root and not writable by group or others" % cur)
        if cur == os.path.dirname(cur):
            return
        cur = os.path.dirname(cur)


def ci_overlay_plan(text, overlay, corpus_path):
    """New overlay text adding compute_integrity.scoring.corpus_path, or the
    same text when it is already set. Nothing else in the overlay changes."""
    import yaml

    if "compute_integrity" in overlay:
        if ci_scoring(overlay).get("corpus_path") == corpus_path:
            return text
        raise Refused("the overlay already sets compute_integrity; reconcile it first")
    if text.strip() and not isinstance(yaml.safe_load(text), (dict, type(None))):
        raise Refused("the overlay is not a YAML mapping")
    if text.strip().startswith("{"):
        raise Refused("the overlay is a flow mapping; refusing to append to it")
    sep = "" if not text or text.endswith("\n") else "\n"
    new = text + sep + "compute_integrity:\n  scoring:\n    corpus_path: %s\n" % corpus_path
    want = dict(overlay)
    want["compute_integrity"] = {"scoring": {"corpus_path": corpus_path}}
    if (yaml.safe_load(new) or {}) != want:
        raise Refused("the overlay edit did not produce exactly the intended YAML change")
    return new


def ci_loaded(j, prompts, version):
    return bool(j["scoring_enabled"]) and not j["corpus_invalid"] and \
        j["corpus_loaded_prompts"] == prompts and j["corpus_loaded_version"] == version


def ci_live(args, prompts, version):
    """The restarted coordinator loaded this corpus and scheduling is on."""
    deadline = time.monotonic() + 60
    while True:
        j = ci_journal(args.unit)
        if j["corpus_invalid"]:
            raise Refused("the coordinator logged compute_integrity_corpus_invalid; scheduling stays off")
        if j["scoring_started"]:
            if ci_loaded(j, prompts, version):
                return
            raise Refused("the coordinator started scoring without this corpus (enabled=%s prompts=%s)"
                          % (j["scoring_enabled"], j["corpus_loaded_prompts"]))
        if time.monotonic() > deadline:
            raise Refused("the coordinator did not log compute_integrity_scoring_started within 60 s")
        time.sleep(1)


def write_corpus(path, data, gid, uid=None, mode=0o640):
    """Install the corpus root-owned (this process), group = the coordinator's
    group, mode 0640: the coordinator runs as its own user and must read it.
    A rollback passes the replaced file's own owner, group and mode."""
    fd, tmp = tempfile.mkstemp(prefix=".compute-integrity-corpus-", dir=os.path.dirname(path))
    try:
        os.fchown(fd, os.geteuid() if uid is None else uid, gid)
        os.fchmod(fd, mode)
        view = memoryview(data)
        while view:
            view = view[os.write(fd, view):]
        os.fsync(fd)
    finally:
        os.close(fd)
    try:
        install(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def read_staged(args):
    """The corpus the ops entry point staged root-only next to the target."""
    st = os.lstat(args.ci_staged)
    if not os.path.isfile(args.ci_staged) or os.path.islink(args.ci_staged) or st.st_uid != os.geteuid() \
            or st.st_mode & 0o077 or st.st_size > CORPUS_MAX_BYTES:
        raise Refused("the staged corpus must be a private regular file owned by this user")
    with open(args.ci_staged, "rb") as f:
        raw = f.read(CORPUS_MAX_BYTES + 1)
    if hashlib.sha256(raw).hexdigest() != args.ci_sha256:
        raise Refused("the staged corpus differs from the validated local corpus")
    version, prompts = parse_corpus(raw)
    return raw, version, prompts


def apply_compute_integrity(args):
    dest = args.ci_corpus
    if not re.match(r"^/[A-Za-z0-9._/-]+$", dest) or os.path.dirname(args.ci_staged) != os.path.dirname(dest):
        raise Refused("the corpus path must be absolute and the staged copy must sit next to it")
    try:
        with guard(args):
            raw, version, prompts = read_staged(args)
            safe_parent(dest)
            pid, binary, env, uid, gid = running(args)
            base, overlay = load_effective(args)
            if ci_scoring(overlay).get("enabled", ci_scoring(base).get("enabled", True)) is False:
                raise Refused("compute_integrity.scoring.enabled is false (the kill switch); reconcile it first")
            if os.path.lexists(dest) and (os.path.islink(dest) or not os.path.isfile(dest)):
                raise Refused("%s exists and is not a regular file" % dest)
            with open(args.overlay, "rb") as f:
                original_overlay = f.read()
            new_overlay = ci_overlay_plan(original_overlay.decode(), overlay, dest).encode()
            original_corpus = None
            if os.path.exists(dest):
                st = os.lstat(dest)
                with open(dest, "rb") as f:
                    original_corpus = (f.read(), st.st_uid, st.st_gid, st.st_mode & 0o7777)
            result = {"changed": new_overlay != original_overlay or original_corpus is None
                      or original_corpus[0] != raw,
                      "prompts": prompts, "corpus_path": dest}
            if not result["changed"] and (original_corpus[1:] == (os.geteuid(), gid, 0o640)) and applied(args) and ci_loaded(ci_journal(args.unit), prompts, version):
                # Disk holds the requested state and the running coordinator
                # loaded exactly it. Otherwise a validated restart loads it.
                print(json.dumps(result, sort_keys=True))
                return
            stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
            tmp = None
            if new_overlay != original_overlay:
                os.makedirs(args.backup_root, mode=0o700, exist_ok=True)
                backup = tempfile.mkdtemp(prefix="%s-compute-integrity-" % stamp, dir=args.backup_root)
                os.chmod(backup, 0o700)
                shutil.copy2(args.overlay, os.path.join(backup, os.path.basename(args.overlay)))
                result["backup"] = backup
                tmp = write_like(args.overlay, new_overlay, args.overlay)
            try:
                check = as_service([binary, "--validate-config", "--config", args.config,
                                    "--config-overlay", tmp or args.overlay], env, uid, gid, 120)
                if check.returncode != 0:
                    raise Refused("the running coordinator binary rejects the edited overlay (--validate-config)")
                write_corpus(dest, raw, gid)
                test = shutil.which("test") or "/usr/bin/test"
                if as_service([test, "-r", dest], env, uid, gid, 15).returncode != 0:
                    raise Refused("the coordinator user cannot read %s" % dest)
                if tmp:
                    install(tmp, args.overlay)
            except Exception:
                # Before any restart: put the overlay back if it was already
                # replaced (a failure after the rename), then the corpus.
                with open(args.overlay, "rb") as f:
                    replaced = f.read() == new_overlay
                if tmp and new_overlay != original_overlay and replaced:
                    install(write_like(args.overlay, original_overlay, args.overlay), args.overlay)
                restore_corpus(dest, raw, original_corpus, gid)
                raise
            finally:
                if tmp and os.path.exists(tmp):
                    os.unlink(tmp)
            try:
                # The unchanged-since-start check works in whole seconds.
                time.sleep(1.1)
                restart(args, pid)
                ci_live(args, prompts, version)
            except Exception:
                with open(args.overlay, "rb") as f:
                    ours = f.read() == new_overlay
                if ours:
                    if new_overlay != original_overlay:
                        install(write_like(args.overlay, original_overlay, args.overlay), args.overlay)
                    restore_corpus(dest, raw, original_corpus, gid)
                    back = subprocess.run(["systemctl", "restart", args.unit], timeout=120, capture_output=True)
                    if back.returncode != 0:
                        raise Refused("the rollback restart failed; the overlay and corpus are restored on disk "
                                      "but not proven live: check the coordinator now")
                    healthz(args.healthz)
                    deadline = time.monotonic() + 30
                    while not applied(args):
                        if time.monotonic() > deadline:
                            raise Refused("after the rollback restart the coordinator did not log the restored "
                                          "config as its boot config: check the coordinator now")
                        time.sleep(1)
                    result["restored"] = True
                raise
            result["restarted"] = True
            print(json.dumps(result, sort_keys=True))
    finally:
        if os.path.lexists(args.ci_staged):
            os.unlink(args.ci_staged)


def restore_corpus(dest, ours, original, gid):
    """Put back the corpus file this run replaced, if it still holds ours."""
    if not os.path.isfile(dest) or os.path.islink(dest):
        return
    with open(dest, "rb") as f:
        if f.read() != ours:
            return
    if original is None:
        os.unlink(dest)
    else:
        data, uid, ogid, mode = original
        write_corpus(dest, data, ogid, uid=uid, mode=mode)


# --- native-vision qualification (#2016) -------------------------------------
#
# Used by scripts/ops/pearl-runtime.sh PEARL_RUNTIME_TASK=vision-qualification.
# The record names a provider, so it never enters this public repository and
# nothing here prints its values: only field names and the entry's sha256.

# routing.vision_qualifications[] (internal/config/config.go
# VisionQualificationConfig and its Validate rules). This copy is stricter
# (exact keys, types, lowercase sha256 hex for every digest the provider
# reports as one, the snapshot-manifest hash algorithm, printable ASCII), so
# what it accepts the coordinator accepts.
VQ_INT_FIELDS = ("ram_gb", "max_context_tokens", "max_concurrency")
VQ_HEX_FIELDS = ("model_hash", "weights_manifest_sha256", "processor_digest", "qualification_digest")
VQ_FIELDS = frozenset(("provider_id", "binary_version", "hardware_chip", "model_id", "model_hash_algorithm",
                       "runtime", "runtime_revision", "media_profile") + VQ_INT_FIELDS + VQ_HEX_FIELDS)
VQ_FIXED = {"model_id": "mlx-community/Qwen2-VL-2B-Instruct-4bit", "runtime": "mlx_cache",
            "media_profile": "qwen2vl-inline-v1", "model_hash_algorithm": "macprovider.snapshot-manifest.v1"}
VQ_MAX_BYTES = 64 * 1024
LOWER_HEX64 = re.compile(r"^[0-9a-f]{64}$")
PRINTABLE = re.compile(r"^[\x21-\x7e](?:[\x20-\x7e]*[\x21-\x7e])?$")


def vq_validate(entry):
    """The entry as a plain dict; Refused naming only the field otherwise."""
    if not isinstance(entry, dict) or set(entry) != VQ_FIELDS:
        names = set(entry) if isinstance(entry, dict) else set()
        raise Refused("the record must be a mapping with exactly the %d routing.vision_qualifications fields "
                      "(missing: %s; unknown: %d)" % (len(VQ_FIELDS), ", ".join(sorted(VQ_FIELDS - names)) or "none",
                                                      len(names - VQ_FIELDS)))
    for key in sorted(entry):
        value = entry[key]
        if key in VQ_INT_FIELDS:
            # Go int on Pearl's amd64 coordinator: int64.
            if type(value) is not int or not 0 < value <= INT64_MAX:
                raise Refused("%s must be a positive integer" % key)
        elif not isinstance(value, str) or not PRINTABLE.match(value) or len(value) > 256:
            raise Refused("%s must be a non-blank printable ASCII string of at most 256 bytes" % key)
        elif key in VQ_HEX_FIELDS and not LOWER_HEX64.match(value):
            raise Refused("%s must be a lowercase sha256 hex digest" % key)
        elif key in VQ_FIXED and value != VQ_FIXED[key]:
            raise Refused("%s must be %s (the qualified qwen2vl-inline-v1 runtime tuple)" % (key, VQ_FIXED[key]))
    return dict(entry)


def vq_canonical(entry):
    return json.dumps(entry, sort_keys=True, separators=(",", ":")).encode()


def vq_digest(entry):
    return hashlib.sha256(vq_canonical(entry)).hexdigest()


def vq_parse(raw):
    """A validated entry from JSON (or YAML) bytes."""
    if len(raw) > VQ_MAX_BYTES:
        raise Refused("the record is larger than %d bytes" % VQ_MAX_BYTES)

    def pairs(items):
        keys = [k for k, _ in items]
        if len(set(keys)) != len(keys):
            raise Refused("the record has a duplicate key")
        return dict(items)

    try:
        text = raw.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        raise Refused("the record is not UTF-8")
    try:
        doc = json.loads(text, object_pairs_hook=pairs)
    except ValueError:
        import yaml

        class Strict(yaml.SafeLoader):
            pass

        def mapping(loader, node):
            keys = [loader.construct_object(k) for k, _ in node.value]
            if len(set(map(str, keys))) != len(keys):
                raise Refused("the record has a duplicate key")
            return loader.construct_mapping(node)

        Strict.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping)
        try:
            doc = yaml.load(text, Loader=Strict)
        except yaml.YAMLError:
            raise Refused("the record is neither JSON nor YAML")
    return vq_validate(doc)


def validate_vq_file(path, out=None):
    st = os.lstat(path)
    if not os.path.isfile(path) or os.path.islink(path):
        raise Refused("the record is not a regular file")
    with open(path, "rb") as f:
        entry = vq_parse(f.read(VQ_MAX_BYTES + 1))
    if out:
        fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(vq_canonical(entry))
    return {"fields": len(entry), "entry_sha256": vq_digest(entry), "private": st.st_mode & 0o7777 == 0o600}


def vq_entries(doc):
    """routing.vision_qualifications of one YAML document: None when absent."""
    routing = doc.get("routing")
    if routing is None:
        return None
    if not isinstance(routing, dict):
        raise Refused("routing must be a mapping")
    if "vision_qualifications" not in routing:
        return None
    if not isinstance(routing["vision_qualifications"], (list, type(None))):
        raise Refused("routing.vision_qualifications must be a list")
    return routing["vision_qualifications"] or []


def vq_overlay_plan(text, overlay, entry):
    """New overlay text setting routing.vision_qualifications to [entry], or
    the same text when it already is exactly that. Nothing else changes; an
    existing routing mapping keeps its keys (the coordinator merges nested
    overlay mappings and replaces lists)."""
    import yaml

    if text.strip() and not isinstance(yaml.safe_load(text), (dict, type(None))):
        raise Refused("the overlay is not a YAML mapping")
    if text.strip().startswith("{"):
        raise Refused("the overlay is a flow mapping; refusing to edit it")
    routing = overlay.get("routing", None)
    if "routing" in overlay and not isinstance(routing, dict):
        raise Refused("the overlay's routing is not a block mapping; reconcile it first")
    existing = vq_entries(overlay)
    if existing is not None:
        if existing == [entry]:
            return text
        raise Refused("the overlay already sets a different routing.vision_qualifications (%d entries); reconcile it first"
                      % len(existing))
    items = ["%s: %s" % (k, entry[k] if k in VQ_INT_FIELDS else json.dumps(entry[k])) for k in sorted(entry)]
    if routing is None:
        sep = "" if not text or text.endswith("\n") else "\n"
        new = text + sep + "routing:\n  vision_qualifications:\n" + \
            "".join(("  - " if i == 0 else "    ") + s + "\n" for i, s in enumerate(items))
    else:
        # Insert as the first key of the one top-level block-style routing
        # mapping, at the indentation of its existing keys.
        start, end = block(text, r"^routing:[ \t]*(#.*)?$")
        first = next((line for line in text[start:end].splitlines()
                      if line.strip() and not line.strip().startswith("#")), None)
        if first is None:
            raise Refused("the overlay's routing block is empty")
        ind = " " * (len(first) - len(first.lstrip(" ")))
        new = text[:start] + "%svision_qualifications:\n" % ind + \
            "".join("%s%s%s\n" % (ind, "- " if i == 0 else "  ", s) for i, s in enumerate(items)) + text[start:]
    want = copy.deepcopy(overlay)
    want.setdefault("routing", {})["vision_qualifications"] = [entry]
    if (yaml.safe_load(new) or {}) != want:
        raise Refused("the overlay edit did not produce exactly the intended YAML change")
    return new


def vq_facts(args):
    # The files read must be the ones the running coordinator was started with.
    running(args)
    base, overlay = load_effective(args)
    entries = vq_entries(overlay)
    facts = {
        "overlay_sets_routing": "routing" in overlay,
        "overlay_entries_sha256": None if entries is None else
        [vq_digest(e) if isinstance(e, dict) else "invalid" for e in entries],
        "base_entries": len(vq_entries(base) or []),
        # The running coordinator booted with exactly the files on disk.
        "applied": applied(args),
    }
    print(json.dumps(facts, sort_keys=True))


def read_vq_staged(args):
    """The canonical record the ops entry point staged root-only."""
    st = os.lstat(args.vq_staged)
    if not os.path.isfile(args.vq_staged) or os.path.islink(args.vq_staged) or st.st_uid != os.geteuid() \
            or st.st_mode & 0o077 or st.st_size > VQ_MAX_BYTES:
        raise Refused("the staged record must be a private regular file owned by this user")
    with open(args.vq_staged, "rb") as f:
        raw = f.read(VQ_MAX_BYTES + 1)
    entry = vq_parse(raw)
    if vq_digest(entry) != args.vq_sha256 or raw != vq_canonical(entry):
        raise Refused("the staged record differs from the validated local record")
    return entry


def apply_vision_qualification(args):
    if os.path.dirname(args.vq_staged) != os.path.dirname(args.overlay):
        raise Refused("the staged record must sit next to the overlay")
    try:
        with guard(args):
            entry = read_vq_staged(args)
            pid, binary, env, uid, gid = running(args)
            _, overlay = load_effective(args)
            with open(args.overlay, "rb") as f:
                original = f.read()
            new = vq_overlay_plan(original.decode(), overlay, entry).encode()
            result = {"changed": new != original, "entry_sha256": args.vq_sha256}
            if new == original:
                # The overlay already holds the entry. Done only when the
                # running coordinator booted with these bytes; otherwise a
                # validated restart loads them.
                if applied(args):
                    print(json.dumps(result, sort_keys=True))
                    return
                check = as_service([binary, "--validate-config", "--config", args.config,
                                    "--config-overlay", args.overlay], env, uid, gid, 120)
                if check.returncode != 0:
                    raise Refused("the running coordinator binary rejects the on-disk overlay (--validate-config)")
                restart(args, pid)
                result["restarted"] = True
                result["recovered_unapplied_config"] = True
                print(json.dumps(result, sort_keys=True))
                return
            stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
            os.makedirs(args.backup_root, mode=0o700, exist_ok=True)
            backup = tempfile.mkdtemp(prefix="%s-vision-qualification-" % stamp, dir=args.backup_root)
            os.chmod(backup, 0o700)
            shutil.copy2(args.overlay, os.path.join(backup, os.path.basename(args.overlay)))
            result["backup"] = backup
            tmp = write_like(args.overlay, new, args.overlay)
            try:
                check = as_service([binary, "--validate-config", "--config", args.config,
                                    "--config-overlay", tmp], env, uid, gid, 120)
                if check.returncode != 0:
                    raise Refused("the running coordinator binary rejects the edited overlay (--validate-config)")
                install(tmp, args.overlay)
            finally:
                if os.path.exists(tmp):
                    os.unlink(tmp)
            try:
                restart(args, pid)
            except Exception:
                with open(args.overlay, "rb") as f:
                    ours = f.read() == new
                if ours:
                    install(write_like(args.overlay, original, args.overlay), args.overlay)
                    back = subprocess.run(["systemctl", "restart", args.unit], timeout=120, capture_output=True)
                    if back.returncode != 0:
                        raise Refused("the rollback restart failed; the overlay is restored on disk "
                                      "but not proven live: check the coordinator now")
                    healthz(args.healthz)
                    deadline = time.monotonic() + 30
                    while not applied(args):
                        if time.monotonic() > deadline:
                            raise Refused("after the rollback restart the coordinator did not log the restored "
                                          "config as its boot config: check the coordinator now")
                        time.sleep(1)
                    result["restored"] = True
                raise
            result["restarted"] = True
            print(json.dumps(result, sort_keys=True))
    finally:
        if os.path.lexists(args.vq_staged):
            os.unlink(args.vq_staged)


def main(argv):
    if argv[:1] == ["validate-vision-qualification"]:
        # Local, read-only (OUT, when given, is a new 0600 file holding the
        # canonical record for staging): prints only the field count, the
        # entry sha256 and whether the file is private.
        if len(argv) not in (2, 3):
            sys.stderr.write("usage: pearl-cli-config.py validate-vision-qualification PATH [OUT]\n")
            sys.exit(2)
        try:
            print(json.dumps(validate_vq_file(argv[1], argv[2] if len(argv) == 3 else None), sort_keys=True))
        except Refused as exc:
            sys.stderr.write("pearl-cli-config: REFUSED: %s\n" % exc)
            sys.exit(3)
        except OSError as exc:
            sys.stderr.write("pearl-cli-config: REFUSED: record unreadable (%s)\n" % type(exc).__name__)
            sys.exit(3)
        return
    if argv[:1] == ["validate-corpus"]:
        # Local, read-only: used by the ops entry point and the corpus generator.
        if len(argv) != 2:
            sys.stderr.write("usage: pearl-cli-config.py validate-corpus PATH\n")
            sys.exit(2)
        try:
            print(json.dumps(validate_corpus_file(argv[1]), sort_keys=True))
        except Refused as exc:
            sys.stderr.write("pearl-cli-config: REFUSED: %s\n" % exc)
            sys.exit(3)
        except OSError as exc:
            sys.stderr.write("pearl-cli-config: REFUSED: corpus unreadable (%s)\n" % type(exc).__name__)
            sys.exit(3)
        return
    p = argparse.ArgumentParser()
    p.add_argument("cmd", choices=["apply", "ci-facts", "apply-compute-integrity", "vq-facts",
                                   "apply-vision-qualification"])
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
    p.add_argument("--ci-corpus", metavar="PATH")
    p.add_argument("--ci-staged", metavar="PATH")
    p.add_argument("--ci-sha256", metavar="SHA256")
    p.add_argument("--vq-staged", metavar="PATH")
    p.add_argument("--vq-sha256", metavar="SHA256")
    args = p.parse_args(argv)
    try:
        if args.cmd == "apply":
            apply(args)
        elif args.cmd == "vq-facts":
            vq_facts(args)
        elif args.cmd == "apply-vision-qualification":
            if not args.vq_staged or not LOWER_HEX64.match(args.vq_sha256 or ""):
                raise Refused("--vq-staged and --vq-sha256 are required")
            apply_vision_qualification(args)
        elif not args.ci_corpus:
            raise Refused("--ci-corpus is required")
        elif args.cmd == "ci-facts":
            ci_facts(args)
        elif not args.ci_staged or not re.match(r"^[0-9a-f]{64}$", args.ci_sha256 or ""):
            raise Refused("--ci-staged and --ci-sha256 are required")
        else:
            apply_compute_integrity(args)
    except Refused as exc:
        sys.stderr.write("pearl-cli-config: REFUSED: %s\n" % exc)
        sys.exit(3)
    except Exception as exc:
        # Exception text could quote config or environment; print the type only.
        sys.stderr.write("pearl-cli-config: FAILED: %s\n" % type(exc).__name__)
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1:])
