#!/usr/bin/env python3
"""#1816 e2e: the Pearl updater runs `python3 catalog-release.py verify-directory`
with a hardcoded 30 s timeout; under qemu TCG (x86_64 emulated on an arm64
Mac) the unchanged verifier takes about 36 s (dozens of openssl spawns), so
every apply would fail on the VM's speed, not on the release. The harness runs
the REAL verifier first, without a timeout (`record`), and stores its exact
output keyed by the bytes it verified: every catalog file in the directory,
the Tier-2 coordinator config, and the verifier script. The python3 shim
(lib/python3-shim, first on the updater's PATH) answers a `verify-directory`
call from that record only on an exact key match; anything else runs the real
interpreter. A changed file is a cache miss and the updater sees the real
(slow) verifier.
  verify-cache.py record <verifier> --directory D --tier2-coordinator-config C
  verify-cache.py key    <python3 argv...>
"""
import hashlib, os, pathlib, subprocess, sys

CACHE = pathlib.Path("/root/e2e/verify-cache")
CATALOG = ("release.json", "trusted-keys.json", "tier2-catalog.json", "rate-card.json", "rate-card.json.sig",
           "autotune-candidates.json", "autotune-candidates.json.sig", "demand-rank.json", "demand-rank.json.sig",
           "continuous-batching-policy.json", "continuous-batching-policy.json.sig", "autotune-artifacts.json",
           "autotune-artifacts.json.sig")


def parse(argv):
    verifier = next((a for a in argv if a.endswith("catalog-release.py")), None)
    if verifier is None or "verify-directory" not in argv:
        return None
    d = argv[argv.index("--directory") + 1]
    c = argv[argv.index("--tier2-coordinator-config") + 1]
    return verifier, d, c


def key(verifier, d, c):
    h = hashlib.sha256()
    for name in CATALOG:
        p = pathlib.Path(d) / name
        h.update(name.encode() + b"\0" + (hashlib.sha256(p.read_bytes()).hexdigest().encode() if p.exists() else b"absent") + b"\0")
    for p in (c, verifier):
        h.update(hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest().encode() + b"\0")
    return h.hexdigest()


if sys.argv[1] == "key":
    parsed = parse(sys.argv[2:])
    if not parsed:
        sys.exit(1)
    print(key(*parsed))
elif sys.argv[1] == "record":
    parsed = parse(sys.argv[2:])
    k = key(*parsed)
    CACHE.mkdir(mode=0o700, exist_ok=True)
    if (CACHE / (k + ".out")).exists():
        print("cached", k[:16]); sys.exit(0)
    verifier, d, c = parsed
    r = subprocess.run(["/usr/bin/python3", verifier, "verify-directory", "--directory", d, "--tier2-coordinator-config", c],
                       capture_output=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr.decode()[-800:]); sys.exit(r.returncode)
    (CACHE / (k + ".err")).write_bytes(r.stderr)
    (CACHE / (k + ".out")).write_bytes(r.stdout)
    print("recorded", k[:16], r.stdout.decode().strip().splitlines()[-1][:160])
