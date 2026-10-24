#!/usr/bin/env python3
"""Offline `systemctl` for the fake Pearl in scripts/ops/test-entrypoints.sh.

Env FAKE_PEARL=<dir> holds: svc/ (fake_services state), proc/ (a fake /proc),
pearl/coordinator.yaml and pearl/overlay.yaml, bin/fake-coordinator.
  show -p InvocationID --value U   fixed invocation id (svc/invocation_seq: one per call)
  show -p MainPID --value U        current fake main pid
  show --timestamp=unix -p ExecMainStartTimestamp --value U   @<unix second of the last start>
  restart U                        new pid and /proc entry, boot.txt digests of
                                   the files now on disk, /healthz recommending
                                   the config's latest_binary_version; the
                                   config becomes svc/running.yaml
  stop U / start U                 append the action to svc/unit-actions
  kill --kill-who=main -s HUP U    SIGHUP: append to svc/hups; the buyer-UX conformance
                                   record file the config names becomes svc/buc_sha
                                   (unless svc/hup_noop, or svc/buc_legacy: that runtime
                                   reads the file only at start); svc/hup_bumps_pid
                                   also gives the unit a new main pid
  restart U also loads that file: svc/buc_sha, or with svc/buc_legacy an
  "unreadable" journal line when the configured file does not load.
  _init                            create the first /proc entries
A unit whose name contains "gateway" is the fake gateway instead: its own
pid (svc/gw_mainpid), start time (svc/gw_started_at, after the last change to
pearl/gateway.yaml), restart count (svc/gw_restarts) and /proc entry running
--config pearl/gateway.yaml; svc/gw_restart_fail makes its restart fail,
svc/gw_restart_fail_once the next one.
Anything else exits 1. A file svc/restart_fail makes restart fail;
svc/restart_fail_once makes the next restart fail (and is removed).
"""
import hashlib
import json
import os
import re
import sys
import time

root = os.environ["FAKE_PEARL"]
svc, proc, pearl = (os.path.join(root, d) for d in ("svc", "proc", "pearl"))
cfg, ov = os.path.join(pearl, "coordinator.yaml"), os.path.join(pearl, "overlay.yaml")


def pid():
    path = os.path.join(svc, "mainpid")
    return int(open(path).read()) if os.path.exists(path) else 4242


def mkproc(p):
    d = os.path.join(proc, str(p))
    os.makedirs(d, exist_ok=True)
    argv = [os.path.join(root, "bin", "fake-coordinator"), "--config", cfg, "--config-overlay", ov]
    open(os.path.join(d, "cmdline"), "wb").write(b"\0".join(a.encode() for a in argv) + b"\0")
    open(os.path.join(d, "environ"), "wb").write(b"OPS_FAKE_SECRET=x\0PATH=" + os.environ["PATH"].encode() + b"\0")
    open(os.path.join(d, "status"), "w").write("Uid:\t%d\t%d\t%d\t%d\nGid:\t%d\t%d\t%d\t%d\n"
                                               % ((os.getuid(),) * 4 + (os.getgid(),) * 4))
    open(os.path.join(svc, "mainpid"), "w").write(str(p))
    open(os.path.join(svc, "started_at"), "w").write(str(int(time.time())))


def gateway_unit(args):
    return any("gateway" in a for a in args)


def gw_pid():
    path = os.path.join(svc, "gw_mainpid")
    return int(open(path).read()) if os.path.exists(path) else 5252


def mkgwproc(p):
    d = os.path.join(proc, str(p))
    os.makedirs(d, exist_ok=True)
    argv = [os.path.join(root, "bin", "fake-gateway"), "--config", os.path.join(pearl, "gateway.yaml")]
    open(os.path.join(d, "cmdline"), "wb").write(b"\0".join(a.encode() for a in argv) + b"\0")
    open(os.path.join(svc, "gw_mainpid"), "w").write(str(p))
    started = int(time.time())
    gw = os.path.join(pearl, "gateway.yaml")
    if os.path.exists(gw):
        started = max(started, int(os.stat(gw).st_ctime) + 1)
    open(os.path.join(svc, "gw_started_at"), "w").write(str(started))


def digest(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def compute_scoring_events():
    """What cmd/coordinator/compute_scoring.go logs at start for the
    compute_integrity.scoring of the files on disk (overlay over base).
    svc/ci_corpus_invalid makes the corpus unusable."""
    import yaml

    def scoring(path):
        try:
            doc = yaml.safe_load(open(path)) if os.path.exists(path) else None
            return ((doc or {}).get("compute_integrity") or {}).get("scoring") or {}
        except (yaml.YAMLError, AttributeError):
            return {}

    s = dict(scoring(cfg), **scoring(ov))
    if s.get("enabled", True) is False:
        return [{"event": "compute_integrity_scoring_started", "enabled": False}]
    if not s.get("corpus_path"):
        return [{"event": "compute_integrity_private_corpus_missing"},
                {"event": "compute_integrity_scoring_started", "enabled": False}]
    try:
        if os.path.exists(os.path.join(svc, "ci_corpus_invalid")):
            raise ValueError
        corpus = json.load(open(s["corpus_path"]))
        loaded = {"event": "compute_integrity_corpus_loaded", "prompts": len(corpus["prompts"]),
                  "version": corpus["version"]}
    except (OSError, ValueError, KeyError):
        return [{"event": "compute_integrity_corpus_invalid"},
                {"event": "compute_integrity_scoring_started", "enabled": False}]
    return [loaded, {"event": "compute_integrity_scoring_started", "enabled": True}]


def buyer_ux_conformance():
    """(configured, sha256 or None when the configured file does not load)."""
    import yaml

    def path_of(doc_path):
        try:
            doc = yaml.safe_load(open(doc_path)) if os.path.exists(doc_path) else None
        except yaml.YAMLError:
            return None
        return ((doc or {}).get("routing") or {}).get("buyer_ux_conformance_path")

    path = path_of(ov) or path_of(cfg)
    if not path:
        return False, ""
    try:
        raw = open(path, "rb").read()
        if json.loads(raw).get("schema_version") != "macprovider.buyer-ux-conformance.v1":
            raise ValueError
    except (OSError, ValueError, AttributeError):
        return True, None
    return True, hashlib.sha256(raw).hexdigest()


args = sys.argv[1:]
if args == ["_init"]:
    mkproc(4242)
    mkgwproc(5252)
elif gateway_unit(args) and args[:1] == ["show"] and "ExecMainStartTimestamp" in args:
    print("@" + open(os.path.join(svc, "gw_started_at")).read().strip())
elif gateway_unit(args) and args[:1] == ["show"] and "MainPID" in args:
    print(gw_pid())
elif gateway_unit(args) and args[:1] == ["restart"]:
    if os.path.exists(os.path.join(svc, "gw_restart_fail")):
        sys.exit(1)
    if os.path.exists(os.path.join(svc, "gw_restart_fail_once")):
        os.unlink(os.path.join(svc, "gw_restart_fail_once"))
        sys.exit(1)
    mkgwproc(gw_pid() + 1)
    n = os.path.join(svc, "gw_restarts")
    count = int(open(n).read()) + 1 if os.path.exists(n) else 1
    open(n, "w").write(str(count))
elif args[:1] == ["show"] and "InvocationID" in args:
    seq = os.path.join(svc, "invocation_seq")
    if os.path.exists(seq):
        values = open(seq).read().split()
        open(seq, "w").write("\n".join(values[1:] or values))
        print(values[0])
    else:
        print("0123456789abcdef0123456789abcdef")
elif args[:1] == ["show"] and "ExecMainStartTimestamp" in args:
    print("@" + open(os.path.join(svc, "started_at")).read().strip())
elif args[:1] == ["show"] and "MainPID" in args:
    print(pid())
elif args[:1] == ["restart"]:
    if os.path.exists(os.path.join(svc, "restart_fail")):
        sys.exit(1)
    if os.path.exists(os.path.join(svc, "restart_fail_once")):
        os.unlink(os.path.join(svc, "restart_fail_once"))
        sys.exit(1)
    mkproc(pid() + 1)
    n = os.path.join(svc, "restarts")
    count = int(open(n).read()) + 1 if os.path.exists(n) else 1
    open(n, "w").write(str(count))
    open(os.path.join(svc, "boot.txt"), "w").write(json.dumps({
        "config_sha256": digest(cfg), "overlay_sha256": digest(ov), "source": "boot",
        "event": "coordinator_config_applied"}) + "\n" + "".join(json.dumps(e) + "\n" for e in compute_scoring_events()))
    configured, buc = buyer_ux_conformance()
    if configured and os.path.exists(os.path.join(svc, "buc_legacy")):
        if buc is None:
            with open(os.path.join(svc, "boot.txt"), "a") as f:
                f.write("routing.buyer_ux_conformance_path unreadable; no conformance records applied\n")
    elif configured:
        # A boot with an unloadable file holds no records.
        open(os.path.join(svc, "buc_sha"), "w").write(buc or "")
    open(os.path.join(svc, "running.yaml"), "w").write(open(cfg).read())
    m = re.search(r'^\s*latest_binary_version:\s*"?([0-9.]+)"?\s*$', open(cfg).read(), re.M)
    h = os.path.join(svc, "healthz.json")
    health = json.load(open(h)) if os.path.exists(h) else {"status": "ok"}
    if m:
        health["recommended_binary_version"] = m.group(1)
    json.dump(health, open(h, "w"))
elif args[:1] == ["kill"] and "HUP" in args:
    with open(os.path.join(svc, "hups"), "a") as f:
        f.write("hup\n")
    if not os.path.exists(os.path.join(svc, "hup_noop")) and not os.path.exists(os.path.join(svc, "buc_legacy")):
        configured, buc = buyer_ux_conformance()
        if configured and buc is not None:
            open(os.path.join(svc, "buc_sha"), "w").write(buc)
    if os.path.exists(os.path.join(svc, "hup_bumps_pid")):
        mkproc(pid() + 1)
elif args[:1] in (["stop"], ["start"]):
    with open(os.path.join(svc, "unit-actions"), "a") as f:
        f.write(args[0] + "\n")
else:
    sys.exit(1)
