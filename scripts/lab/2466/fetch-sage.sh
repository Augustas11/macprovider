#!/bin/bash
# #2466 Studio download step: fetch Sage-S2.1-Flash at the pinned revision into
# ~/lab-2466/models/<name>@<rev> and verify every file against the HF API metadata
# (LFS sha256 + size; git blob sha1 + size for non-LFS files). Refuses on any mismatch,
# missing or extra file. Writes <dir>.verified (a sibling, so the snapshot hash is untouched)
# only after a clean verify; job.sh requires that marker.
# Exit: 0 verified, 2 usage/env, 3 verify mismatch, other = download failure.
set -euo pipefail
REPO=Hygaard/Sage-S2.1-Flash-oQ4e-mtp
REV=a972e256db2553562bd718e677d100089aca5fce
FILES=71
BYTES=186593494737
LAB=${LAB:-$HOME/lab-2466}
REF_VENV=${REF_VENV:-$HOME/venvs/ref-omlx}
DIR=$LAB/models/Sage-S2.1-Flash-oQ4e-mtp@$REV
HF=$REF_VENV/bin/hf
[ -x "$HF" ] && [ -x "$REF_VENV/bin/python" ] || { echo "no hf / python in REF_VENV=$REF_VENV" >&2; exit 2; }
echo "$REV" | grep -Eq '^[0-9a-f]{40}$' || { echo "REV must be a 40-hex sha" >&2; exit 2; }
mkdir -p "$DIR"
rm -f "$DIR.verified"
echo "FETCH_START $REPO@$REV -> $DIR free_gb=$(df -g "$LAB" | awk 'NR==2{print $4}')"
"$HF" download "$REPO" --revision "$REV" --local-dir "$DIR"
"$REF_VENV/bin/python" -I -B - "$REPO" "$REV" "$DIR" "$FILES" "$BYTES" <<'PY' || { echo "FETCH_REFUSED: verification failed, snapshot not usable" >&2; exit 3; }
import hashlib, json, os, sys, urllib.request

repo, rev, root, nfiles, nbytes = sys.argv[1:6]
api = f"https://huggingface.co/api/models/{repo}/revision/{rev}?blobs=true"
with urllib.request.urlopen(api, timeout=60) as r:
    doc = json.load(r)
if doc.get("sha") != rev:
    sys.exit(f"HF resolved {doc.get('sha')} for pinned {rev}")
want = {s["rfilename"]: s for s in doc["siblings"]}
bad = []
if len(want) != int(nfiles) or sum(s["size"] for s in want.values()) != int(nbytes):
    bad.append(f"pinned tree changed: {len(want)} files / {sum(s['size'] for s in want.values())} bytes")
have = set()
for dp, dn, fn in os.walk(root):
    if dp == root and ".cache" in dn:
        dn.remove(".cache")
    for f in fn:
        have.add(os.path.relpath(os.path.join(dp, f), root))
for extra in sorted(have - set(want)):
    bad.append(f"extra file {extra}")
for name, s in sorted(want.items()):
    p = os.path.join(root, name)
    if not os.path.isfile(p):
        bad.append(f"missing {name}"); continue
    size = os.path.getsize(p)
    if size != s["size"]:
        bad.append(f"size {name}: {size} != {s['size']}"); continue
    lfs = s.get("lfs")
    h = hashlib.sha256() if lfs else hashlib.sha1(b"blob %d\0" % size)
    with open(p, "rb") as fh:
        for chunk in iter(lambda: fh.read(8 << 20), b""):
            h.update(chunk)
    exp = lfs["sha256"] if lfs else s["blobId"]
    if h.hexdigest() != exp:
        bad.append(f"{'sha256' if lfs else 'git-sha1'} {name}: {h.hexdigest()} != {exp}")
    else:
        print("OK", name, size, flush=True)
if bad:
    print("\n".join("MISMATCH " + b for b in bad), file=sys.stderr)
    sys.exit(1)
print(f"VERIFIED {len(want)} files {nbytes} bytes")
PY
printf '%s %s\n' "$REPO" "$REV" > "$DIR.verified"
echo "FETCH_VERIFIED $DIR"
