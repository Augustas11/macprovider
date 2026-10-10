#!/usr/bin/env python3
"""Offline `systemctl` for the fake Pearl in scripts/ops/test-entrypoints.sh.

Env FAKE_PEARL=<dir> holds: svc/ (fake_services state), proc/ (a fake /proc),
pearl/coordinator.yaml and pearl/overlay.yaml, bin/fake-coordinator.
  show -p InvocationID --value U   fixed invocation id
  show -p MainPID --value U        current fake main pid
  restart U                        new pid and /proc entry, boot.txt digests of
                                   the files now on disk, /healthz recommending
                                   the config's latest_binary_version
  _init                            create the first /proc entry
Anything else exits 1. A file svc/restart_fail makes restart fail.
"""
import hashlib
import json
import os
import re
import sys

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


def digest(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


args = sys.argv[1:]
if args == ["_init"]:
    mkproc(4242)
elif args[:1] == ["show"] and "InvocationID" in args:
    print("0123456789abcdef0123456789abcdef")
elif args[:1] == ["show"] and "MainPID" in args:
    print(pid())
elif args[:1] == ["restart"]:
    if os.path.exists(os.path.join(svc, "restart_fail")):
        sys.exit(1)
    mkproc(pid() + 1)
    n = os.path.join(svc, "restarts")
    count = int(open(n).read()) + 1 if os.path.exists(n) else 1
    open(n, "w").write(str(count))
    open(os.path.join(svc, "boot.txt"), "w").write(json.dumps({
        "config_sha256": digest(cfg), "overlay_sha256": digest(ov), "source": "boot",
        "event": "coordinator_config_applied"}) + "\n")
    m = re.search(r'^\s*latest_binary_version:\s*"?([0-9.]+)"?\s*$', open(cfg).read(), re.M)
    h = os.path.join(svc, "healthz.json")
    health = json.load(open(h)) if os.path.exists(h) else {"status": "ok"}
    if m:
        health["recommended_binary_version"] = m.group(1)
    json.dump(health, open(h, "w"))
else:
    sys.exit(1)
