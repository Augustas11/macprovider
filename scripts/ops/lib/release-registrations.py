#!/usr/bin/env python3
"""Coordinator-side registrations of a provider CLI release (cli-release.sh).

A new CLI binary is served only when Pearl knows it in two places:
compatibility_set.accepted_ids (restart-only config) and a privacy-class code
identity approval, either a signed `v<ver>.json` in
privacy_class.release_code_identities.metadata_dir (hot, re-read every
challenge interval) or a privacy_class.approved_code_identities entry
(restart-only config). SPEC-049-R006/R027.

Subcommands. The first three are sent over SSH (`python3 - CMD ... < this
file`) and print JSON; they never print credentials or the full config.

  facts CONFIG OVERLAY UNIT VERSION
      read-only: the registration fields of the merged config, the release
      metadata pair for VERSION, the release public key, and whether the
      on-disk config is newer than the running coordinator.
  stage DIR VERSION OWNER GROUP JSON_B64 SIG_B64
      write v<VERSION>.json then v<VERSION>.json.sig atomically into DIR
      (created 0750 OWNER:GROUP when absent), mode 0640 OWNER:GROUP, then read
      both back. Refuses to replace a different existing pair.
  unapproved UNIT METRICS_URL [PROVIDER_ID SINCE]
      count posture_unapproved_code_identity rejections: from the
      relayblind_privacy_posture_rejections_total metric (process lifetime)
      when served, else from the coordinator journal since the coordinator
      started. With PROVIDER_ID, journal lines naming that provider since
      SINCE (journalctl syntax).

  evaluate FACTS_JSON VERSION COMPAT_ID PEARL_RELEASE_JSON PEARL_RELEASE_SIG
      local: decide the metadata state and whether the candidate is fully
      registered; prints a JSON verdict.
"""
import base64
import calendar
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.request

UNAPPROVED = "posture_unapproved_code_identity"
VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
MAX_FILE = 1 << 20


def fail(msg):
    sys.stderr.write("release-registrations: %s\n" % msg)
    sys.exit(2)


def merge(base, over):
    # Mirrors config.LoadWithOverlay: the overlay decodes onto the base, so
    # mappings merge key by key and every other value is replaced.
    if isinstance(base, dict) and isinstance(over, dict):
        out = dict(base)
        for k, v in over.items():
            out[k] = merge(base.get(k), v) if k in base else v
        return out
    return over


def read_bounded(path):
    st = os.lstat(path)
    if not os.path.isfile(path) or os.path.islink(path) or st.st_size > MAX_FILE:
        raise OSError("not a bounded regular file")
    with open(path, "rb") as f:
        return f.read(MAX_FILE + 1)


def coordinator_started(unit):
    try:
        out = subprocess.run(["systemctl", "show", "-p", "ExecMainStartTimestamp", "--value", unit],
                             capture_output=True, text=True, timeout=15).stdout.strip()
        return calendar.timegm(time.strptime(out, "%a %Y-%m-%d %H:%M:%S UTC"))
    except Exception:
        return None


def facts(cfg_path, overlay_path, unit, version):
    import yaml  # remote side only

    if not VERSION.match(version):
        fail("bad version")
    cfg, mtimes = {}, []
    for path in (cfg_path, overlay_path):
        if not path or path == "-":
            continue
        with open(path) as f:
            cfg = merge(cfg, yaml.safe_load(f) or {})
        mtimes.append(os.stat(path).st_mtime)
    coord = cfg.get("coordinator") or {}
    compat = coord.get("compatibility_set") or {}
    pc = cfg.get("privacy_class") or {}
    rel = pc.get("release_code_identities") or {}
    approved = []
    for e in pc.get("approved_code_identities") or []:
        if isinstance(e, dict):
            approved.append({k: (str(e[k]) if e.get(k) is not None else "") for k in
                             ("team_id", "signing_identifier", "code_cdhash", "binary_version", "expires_at")
                             if k in e})
    doc = {
        "target_id": str(compat.get("target_id") or ""),
        "accepted_ids": [str(x) for x in compat.get("accepted_ids") or []],
        "privacy_class_enabled": bool(pc.get("enabled")),
        "approved_code_identities": approved,
        "denied_code_cdhashes": [str(x) for x in pc.get("denied_code_cdhashes") or []],
        "metadata_dir": str(rel.get("metadata_dir") or "").strip(),
        "public_key_path": str(rel.get("public_key_path") or "").strip(),
        "public_key_pem": None,
        "config_mtime": max(mtimes) if mtimes else None,
        "coordinator_started": coordinator_started(unit),
        "metadata": None,
        "metadata_error": "",
    }
    if doc["public_key_path"]:
        try:
            doc["public_key_pem"] = read_bounded(doc["public_key_path"]).decode()
        except (OSError, UnicodeDecodeError) as exc:
            doc["metadata_error"] = "public key unreadable: %s" % exc
    md = doc["metadata_dir"]
    if md:
        name = os.path.join(md, "v%s.json" % version)
        if os.path.lexists(name) or os.path.lexists(name + ".sig"):
            try:
                doc["metadata"] = {
                    "json_b64": base64.b64encode(read_bounded(name)).decode(),
                    "sig_b64": base64.b64encode(read_bounded(name + ".sig")).decode(),
                }
            except OSError as exc:
                doc["metadata_error"] = "v%s pair unreadable: %s" % (version, exc)
    print(json.dumps(doc, sort_keys=True))


def write_atomic(directory, name, payload, uid, gid):
    fd, tmp = tempfile.mkstemp(prefix=".stage-", dir=directory)
    try:
        os.fchown(fd, uid, gid)
        os.fchmod(fd, 0o640)
        os.write(fd, payload)
        os.fsync(fd)
        os.close(fd)
        fd = -1
        os.replace(tmp, os.path.join(directory, name))
    finally:
        if fd >= 0:
            os.close(fd)
        if os.path.exists(tmp):
            os.unlink(tmp)
    dfd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)


def stage(directory, version, owner, group, json_b64, sig_b64):
    import grp
    import pwd

    if not VERSION.match(version) or not os.path.isabs(directory):
        fail("bad version or directory")
    uid, gid = pwd.getpwnam(owner).pw_uid, grp.getgrnam(group).gr_gid
    payload, signature = base64.b64decode(json_b64, validate=True), base64.b64decode(sig_b64, validate=True)
    if not os.path.lexists(directory):
        os.mkdir(directory, 0o750)
        os.chown(directory, uid, gid)
        os.chmod(directory, 0o750)
    st = os.lstat(directory)
    if not os.path.isdir(directory) or os.path.islink(directory) or st.st_uid != uid or st.st_gid != gid \
            or st.st_mode & 0o7777 != 0o750:
        fail("%s must be a real directory %s:%s mode 0750" % (directory, owner, group))
    name = "v%s.json" % version
    target = os.path.join(directory, name)
    for path, want in ((target, payload), (target + ".sig", signature)):
        if os.path.lexists(path):
            try:
                have = read_bounded(path)
            except OSError:
                fail("%s exists and is not a regular file" % path)
            if have != want:
                fail("%s exists with different bytes; refusing to replace a signed release identity" % path)
    # Payload first, signature last (as the Pearl updater): the coordinator
    # never pairs a new signature with an old payload.
    write_atomic(directory, name, payload, uid, gid)
    write_atomic(directory, name + ".sig", signature, uid, gid)
    out = {}
    for path, want in ((target, payload), (target + ".sig", signature)):
        st = os.lstat(path)
        if read_bounded(path) != want or st.st_gid != gid or not st.st_mode & 0o040:
            fail("%s did not read back as written (bytes, group or group-read)" % path)
        out[os.path.basename(path)] = hashlib.sha256(want).hexdigest()
    print(json.dumps(out, sort_keys=True))


def metric_count(url):
    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            text = resp.read(8 << 20).decode()
    except Exception:
        return None
    pat = re.compile(r'^relayblind_privacy_posture_rejections_total\{[^}]*reason="%s"[^}]*\}\s+([0-9.eE+]+)\s*$' % UNAPPROVED)
    seen_family = False
    for line in text.splitlines():
        if line.startswith("# TYPE relayblind_privacy_posture_rejections_total"):
            seen_family = True
        m = pat.match(line)
        if m:
            return int(float(m.group(1)))
    return 0 if seen_family else None


def journal_count(unit, since, provider_id):
    proc = subprocess.run(["journalctl", "-u", unit, "--since", since, "--no-pager", "-o", "cat"],
                          capture_output=True, text=True, timeout=60)
    if proc.returncode != 0:
        fail("journalctl failed: %s" % proc.stderr.strip()[:200])
    needle = '"provider_id":"%s"' % provider_id if provider_id else ""
    return sum(1 for line in proc.stdout.splitlines() if UNAPPROVED in line and needle in line)


def unapproved(unit, url, provider_id="", since=""):
    if provider_id:
        if not re.match(r"^[A-Za-z0-9_-]{1,128}$", provider_id):
            fail("bad provider id")
        print(json.dumps({"source": "journal", "since": since, "count": journal_count(unit, since, provider_id)}))
        return
    count = metric_count(url) if url and url != "-" else None
    if count is not None:
        print(json.dumps({"source": "metric", "count": count}))
        return
    started = coordinator_started(unit)
    if started is None:
        fail("neither the rejection metric nor the coordinator start time is readable")
    print(json.dumps({"source": "journal", "since": "@%d" % started, "count": journal_count(unit, "@%d" % started, "")}))


def verify_sig(pem, payload, signature):
    with tempfile.TemporaryDirectory() as d:
        paths = {}
        for name, data in (("key.pem", pem.encode()), ("m.json", payload), ("m.sig", signature)):
            paths[name] = os.path.join(d, name)
            with open(paths[name], "wb") as f:
                f.write(data)
        return subprocess.run(["openssl", "dgst", "-sha256", "-verify", paths["key.pem"], "-signature",
                               paths["m.sig"], paths["m.json"]], capture_output=True).returncode == 0


def code_identity(payload):
    ident = json.loads(payload)["provider_code_identity"]
    return {"team_id": ident["team_id"], "signing_identifier": ident["signing_identifier"],
            "code_cdhash": ident["slices"][0]["code_cdhash"], "binary_version": ident["binary_version"]}


def expired(value, now):
    if not value:
        return False
    try:
        # Offsets are ignored; YAML may hand back "YYYY-MM-DD HH:MM:SS+00:00".
        return calendar.timegm(time.strptime(value.replace(" ", "T")[:19], "%Y-%m-%dT%H:%M:%S")) <= now
    except ValueError:
        return True


def evaluate(facts_path, version, compat_id, prj, prjsig):
    f = json.load(open(facts_path))
    local = local_sig = None
    if prj and prjsig and os.path.isfile(prj) and os.path.isfile(prjsig):
        local, local_sig = open(prj, "rb").read(), open(prjsig, "rb").read()
    meta = f.get("metadata")
    remote = remote_sig = None
    if meta:
        remote, remote_sig = base64.b64decode(meta["json_b64"]), base64.b64decode(meta["sig_b64"])
    if not f.get("metadata_dir"):
        state = "unconfigured"
    elif remote is None:
        state = "missing"
    elif local is None:
        state = "present"
    else:
        state = "staged" if (remote, remote_sig) == (local, local_sig) else "mismatch"
    out = {"metadata_state": state, "missing": []}
    miss = out["missing"]
    now = time.time()
    started, mtime = f.get("coordinator_started"), f.get("config_mtime")
    out["config_applied"] = started is not None and mtime is not None and int(mtime) <= started
    if not out["config_applied"]:
        miss.append("the on-disk coordinator config is newer than the running coordinator (or its start "
                    "time is unreadable): restart-only registrations are not proven applied")
    if compat_id and compat_id != f.get("target_id") and compat_id not in f.get("accepted_ids", []):
        miss.append("compatibility_set.accepted_ids lacks %s (pearl_accepted_ids step)" % compat_id)
    if local is None:
        out["cdhash"] = ""
        miss.append("no verified candidate pearl-release.json is recorded (signed_byte_verification step)")
        print(json.dumps(out, sort_keys=True))
        return
    want = code_identity(local)
    cd = out["cdhash"] = want["code_cdhash"]
    if want["binary_version"] != version:
        miss.append("candidate provider_code_identity.binary_version %s != %s" % (want["binary_version"], version))
    release_ok, release_why = False, ""
    if not f.get("metadata_dir") or not f.get("public_key_path"):
        release_why = "privacy_class.release_code_identities is not configured"
    elif remote is None:
        release_why = "no v%s.json pair in %s" % (version, f["metadata_dir"])
    elif not f.get("public_key_pem"):
        release_why = f.get("metadata_error") or "release public key unreadable"
    elif not verify_sig(f["public_key_pem"], remote, remote_sig):
        release_why = "v%s.json does not verify against %s" % (version, f["public_key_path"])
    else:
        try:
            got = code_identity(remote)
        except (KeyError, IndexError, TypeError, ValueError):
            got = None
        release_ok = got == want
        release_why = "" if release_ok else "v%s.json names a different code identity" % version
    entries = [e for e in f.get("approved_code_identities", []) if e.get("code_cdhash") == cd
               and e.get("team_id") == want["team_id"] and e.get("signing_identifier") == want["signing_identifier"]]
    config_ok = any(not expired(e.get("expires_at"), now) and e.get("binary_version", "") in ("", version)
                    for e in entries)
    if cd in f.get("denied_code_cdhashes", []):
        out["approved_by"] = ""
        miss.append("code_cdhash %s is in privacy_class.denied_code_cdhashes" % cd)
    elif entries:
        # A config entry for the identity governs over release metadata.
        out["approved_by"] = "approved_code_identities" if config_ok else ""
        if not config_ok:
            miss.append("privacy_class.approved_code_identities has an expired or version-mismatched entry for "
                        "code_cdhash %s, which overrides release metadata" % cd)
    elif release_ok:
        out["approved_by"] = "release_metadata"
    else:
        out["approved_by"] = ""
        miss.append("privacy code identity %s (v%s) is not approved: %s and no approved_code_identities entry "
                    "(privacy_release_identity step)" % (cd, version, release_why))
    print(json.dumps(out, sort_keys=True))


def main(argv):
    if not argv:
        fail("usage: facts|stage|unapproved|evaluate ...")
    cmd, args = argv[0], argv[1:]
    if cmd == "facts" and len(args) == 4:
        facts(*args)
    elif cmd == "stage" and len(args) == 6:
        stage(*args)
    elif cmd == "unapproved" and len(args) in (2, 4):
        unapproved(*args)
    elif cmd == "evaluate" and len(args) == 5:
        evaluate(*args)
    else:
        fail("bad arguments for %s" % cmd)


if __name__ == "__main__":
    main(sys.argv[1:])
