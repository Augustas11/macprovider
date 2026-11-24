"""Uncensored Inkling-2-Mini in the served oQ4e-mtp layout, by splice (#2467).

The served base, mlx-community/Inkling-2-Mini-oQ4e-mtp @ 3eea0427, is an oMLX oQ4e quant of
thinkingmachines/Inkling-2-Mini @ b85c3cfa. OpenUncensored/Inkling-2-Mini-Uncensored @ 4e5f06d7
keeps the original checkpoint format (routed experts NVFP4/MXFP8, everything else BF16, one
`model-00001-of-00001.safetensors` plus `mtp.safetensors`) and, per its card, changed only the
attention output projections (`model.llm.layers.N.attn.wo_ud.weight`, BF16). So the uncensored
artifact in our layout is the base with those projections re-quantized in exactly the format the
base uses for them (`model.layers.N.attn.o_proj`, read from the base config's `quantization`
map: affine 8-bit, group 64, BF16 scales and biases) and every other file byte-identical.

The source also ships `edit.pt`, a PyTorch pickle. It is never downloaded, opened or unpickled:
`fetch` skips it and every pickle-like file, and `diff` and `splice` refuse a directory that
holds one. Tensors are read only from safetensors headers and byte ranges.

Subcommands (`fetch`, `diff` and the byte plumbing of `splice` are stdlib only; the numeric
part of `splice` needs numpy and mlx):

  fetch  --source DIR --original DIR --source-manifest FILE --out fetch.json [--plan-only]
         Pinned API listings of the three repos. The source listing must match the committed
         source snapshot manifest (050f1cec, paths, sizes, LFS sha256). Downloads into
         --source only the source's weight shards, index and config.json (each checked
         against its LFS sha256 or git blob id); into --original only what it lacks of the
         same files. mtp.safetensors and every other source file are compared by checksum
         with the original instead of downloaded.
  diff   --source DIR --original DIR --fetch fetch.json --out diff.json [--expect-changed N]
         Tensor by tensor: same names, dtypes and shapes, then bytes. Refuses unless every
         differing tensor is an attention output projection (`...attn.wo_ud.weight`) and there
         are exactly N of them (default 20, the card's count; `any` accepts 1..all). Every
         other source file must equal the original's (config.json: equal as JSON except
         ignorable top-level keys), with `edit.pt` the only allowed extra file.
  recipe --base OQ --original DIR --out recipe.json [--error-ratio 1.25] [--max-error-ratio 2.0]
         Before the splice: every base attn.o_proj against the oQ affine quantizer
         (oq_affine_quantize, ported from oMLX) of the original attn.wo_ud of its layer, in
         the base's format. Refuses unless the base's and
         our error on the original are below an absolute bound (a plain quantization, no
         transform) and ours is within the ratios of the base's (or byte-equal to it).
  splice --base OQ --source DIR --original DIR --fetch fetch.json --diff diff.json --out OUT
         --manifest splice.json [--error-ratio 1.25] [--max-error-ratio 2.0]
         OUT must be an APFS clone of OQ (`cp -c -R`). Re-quantizes each changed projection
         with oq_affine_quantize in the base's format for that module, and the original projection
         the same way as a recipe check (`recipe_reproduced`: our bytes equal the base's).
         Numeric gate per module: the recipe checks above; the spliced tensor's dequantized
         error against the uncensored BF16 weight is within --error-ratio (relative
         Frobenius) and --max-error-ratio (max abs) of the base's own error against the
         original BF16 weight of the same layer, within --error-ratio of our recipe's error
         on that original weight, and below the absolute bound; mlx and numpy dequantization
         agree; and the quantized bytes differ from the base's (the edit survives quantization). Then writes the new
         bytes in place into private clones of the touched shards (headers and offsets do not
         move) and verifies OUT: changed tensors hold the new bytes, every other tensor and
         file is byte-identical to the base (repo files against the pinned checksums), same
         file set.

Every failure prints `BLOCKER: ...` and exits nonzero.
"""

from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

UNCENSORED = ("OpenUncensored/Inkling-2-Mini-Uncensored", "4e5f06d72b5a70c9dcd5e8046aea576eb3ee8487")
ORIGINAL = ("thinkingmachines/Inkling-2-Mini", "b85c3cfa615fc413cc9af3379f491b963f3b586a")
OQ = ("mlx-community/Inkling-2-Mini-oQ4e-mtp", "3eea042751cd296b7266628a8342c1749242e1fe")
SOURCE_MANIFEST_SHA256 = "050f1cec9aa9a78bb4b365bebf5cb4758e531713943bd2e8208d43ffd5c869e2"
OQ_MANIFEST_SHA256 = "75509c7fcd864d109d542676ed14763a2c5c570c731f3c1d1180d0207b6b9b34"
LICENSE = "apache-2.0"
EXPECT_CHANGED = 20
# A pickle (or any format that can execute code on load) is never fetched or opened.
PICKLE_SUFFIXES = (".pt", ".pth", ".bin", ".pkl", ".pickle", ".ckpt", ".joblib", ".npy", ".npz")
ALLOWED_EXTRA = {"edit.pt"}
# Files that may differ between the source and the original without touching the weights.
FREE_FILES = {"README.md", ".gitattributes"}
IGNORABLE_CONFIG_KEYS = {"dtype", "torch_dtype", "transformers_version"}
WEIGHT_FILE = re.compile(r"^model-\d{5}-of-\d{5}\.safetensors$")
FETCH_FILES = ("model.safetensors.index.json", "config.json")
CHANGED_TENSOR = re.compile(r"^model\.llm\.layers\.(\d+)\.attn\.wo_ud\.weight$")
DTYPE_SIZE = {"BOOL": 1, "U8": 1, "I8": 1, "F8_E4M3": 1, "F8_E5M2": 1, "F8_E8M0": 1, "BF16": 2, "F16": 2,
              "I16": 2, "U16": 2, "F32": 4, "I32": 4, "U32": 4, "F64": 8, "I64": 8, "U64": 8}


class Blocker(Exception):
    pass


def log(msg: str) -> None:
    print(f"{time.strftime('%H:%M:%S')} {msg}", flush=True)


def oq_module(layer: int) -> str:
    return f"model.layers.{layer}.attn.o_proj"


def is_pickle_like(name: str) -> bool:
    return name.lower().endswith(PICKLE_SUFFIXES)


def refuse_pickles(root: Path) -> None:
    for p in root.rglob("*"):
        if p.is_file() and is_pickle_like(p.name):
            raise Blocker(f"{p}: a pickle-like file is in the model directory; it must never be fetched or loaded")


# ---------------------------------------------------------------- safetensors I/O

def read_header(path: Path) -> tuple[int, dict, bytes]:
    with open(path, "rb") as f:
        raw = f.read(8)
        if len(raw) != 8:
            raise Blocker(f"{path}: not a safetensors file")
        n = struct.unpack("<Q", raw)[0]
        if n > 100 << 20:
            raise Blocker(f"{path}: header of {n} bytes")
        blob = f.read(n)
    header = json.loads(blob)
    for name, entry in header.items():
        if name == "__metadata__":
            continue
        a, b = entry["data_offsets"]
        count = 1
        for d in entry["shape"]:
            count *= d
        if entry["dtype"] not in DTYPE_SIZE or b - a != count * DTYPE_SIZE[entry["dtype"]]:
            raise Blocker(f"{path}: {name} {entry['dtype']}{entry['shape']} spans {b - a} bytes")
    return 8 + n, header, blob


class Shards:
    """One directory's safetensors through its index; tensor bytes by name."""

    def __init__(self, root: Path):
        self.root = root
        index = root / "model.safetensors.index.json"
        if index.is_file():
            self.weight_map = json.loads(index.read_text())["weight_map"]
        else:
            raise Blocker(f"{root}: no model.safetensors.index.json")
        self.headers: dict[str, tuple[int, dict, bytes]] = {}

    def names(self) -> list[str]:
        return sorted(self.weight_map)

    def locate(self, name: str) -> tuple[str, int, dict]:
        shard = self.weight_map.get(name)
        if shard is None:
            raise Blocker(f"{name}: not in the index of {self.root}")
        if shard not in self.headers:
            self.headers[shard] = read_header(self.root / shard)
        start, header, _ = self.headers[shard]
        entry = header.get(name)
        if entry is None:
            raise Blocker(f"{name}: the index names {shard}, whose header lacks it")
        return shard, start, entry

    def read(self, name: str) -> bytes:
        shard, start, entry = self.locate(name)
        a, b = entry["data_offsets"]
        with open(self.root / shard, "rb") as f:
            f.seek(start + a)
            data = f.read(b - a)
        if len(data) != b - a:
            raise Blocker(f"{name}: short read from {shard}")
        return data

    def digest(self, name: str) -> str:
        shard, start, entry = self.locate(name)
        a, b = entry["data_offsets"]
        h = hashlib.sha256()
        with open(self.root / shard, "rb") as f:
            f.seek(start + a)
            left = b - a
            while left:
                chunk = f.read(min(left, 64 << 20))
                if not chunk:
                    raise Blocker(f"{name}: short read from {shard}")
                h.update(chunk)
                left -= len(chunk)
        return h.hexdigest()


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(16 << 20):
            h.update(chunk)
    return h.hexdigest()


def git_blob_sha1(path: Path) -> str:
    h = hashlib.sha1(b"blob %d\0" % path.stat().st_size)
    with open(path, "rb") as f:
        while chunk := f.read(16 << 20):
            h.update(chunk)
    return h.hexdigest()


_FILE_OK: dict[tuple, bool] = {}


def file_ok(path: Path, want: dict) -> bool:
    """PATH holds the pinned bytes. A pass is remembered per (path, size, mtime, pin) within
    one process, so a 19.5 GB shard is hashed once, not once per caller."""
    if not path.is_file():
        return False
    st = path.stat()
    key = (str(path), st.st_size, st.st_mtime_ns, json.dumps(want, sort_keys=True))
    if _FILE_OK.get(key):
        return True
    ok = _file_ok(path, want)
    if ok:
        _FILE_OK[key] = True
    return ok


def _file_ok(path: Path, want: dict) -> bool:
    if want.get("size") is not None and path.stat().st_size != want["size"]:
        return False
    if "sha256" in want:
        return sha256_file(path) == want["sha256"]
    return git_blob_sha1(path) == want["blob_sha1"]


def same_checksum(a: dict | None, b: dict | None) -> bool:
    return a is not None and b is not None and a == b


# ---------------------------------------------------------------- fetch

def api(repo: str, rev: str) -> dict:
    url = f"https://huggingface.co/api/models/{repo}/revision/{rev}?blobs=true"
    meta = json.load(urllib.request.urlopen(url, timeout=120))
    if meta.get("sha") != rev:
        raise Blocker(f"{repo}@{rev} resolved to {meta.get('sha')}")
    return meta


def checksums(meta: dict) -> dict[str, dict]:
    out = {}
    for s in meta["siblings"]:
        if s.get("lfs"):
            out[s["rfilename"]] = {"sha256": s["lfs"]["sha256"], "size": s["lfs"]["size"]}
        else:
            out[s["rfilename"]] = {"blob_sha1": s.get("blobId"), "size": s.get("size")}
    return out


def parse_manifest(data: bytes) -> dict[str, dict]:
    lines = data.decode("utf-8").split("\n")
    if lines[-1] != "" or (len(lines) - 1) % 3:
        raise Blocker("snapshot manifest is not path/size/sha256 records")
    return {lines[i]: {"size": int(lines[i + 1]), "sha256": lines[i + 2]} for i in range(0, len(lines) - 1, 3)}


def check_source_listing(listing: dict[str, dict], manifest: dict[str, dict]) -> None:
    """The pinned source revision is the one whose snapshot manifest the intake committed."""
    if set(listing) != set(manifest):
        raise Blocker(f"source files {sorted(set(listing) ^ set(manifest))} differ from the committed manifest")
    for name, want in manifest.items():
        got = listing[name]
        if got.get("size") != want["size"] or ("sha256" in got and got["sha256"] != want["sha256"]):
            raise Blocker(f"source {name}: listing {got} is not the committed manifest entry {want}")


def download(repo: str, rev: str, name: str, dest: Path, want: dict) -> None:
    if is_pickle_like(name):
        raise Blocker(f"refusing to download {name}: pickle-like file")
    out = dest / name
    if file_ok(out, want):
        log(f"FETCH_PRESENT {repo} {name}")
        return
    out.parent.mkdir(parents=True, exist_ok=True)
    part = out.with_name(out.name + ".part")
    url = f"https://huggingface.co/{repo}/resolve/{rev}/{urllib.parse.quote(name)}"
    t0 = time.time()
    attempts = 6
    for attempt in range(1, attempts + 1):
        # Resume from the .part bytes already written (HTTP Range); a server that ignores the
        # range answers 200 and the file restarts from byte 0.
        have = part.stat().st_size if part.is_file() else 0
        if want.get("size") is not None and have > want["size"]:
            part.unlink()
            have = 0
        req = urllib.request.Request(url, headers={"Range": f"bytes={have}-"} if have else {})
        try:
            with urllib.request.urlopen(req, timeout=600) as r:
                resumed = have and r.status == 206
                with open(part, "ab" if resumed else "wb") as f:
                    while chunk := r.read(16 << 20):
                        f.write(chunk)
            if want.get("size") is None or part.stat().st_size == want["size"]:
                break
            raise OSError(f"short body: {part.stat().st_size} of {want['size']} bytes")
        except (OSError, http.client.HTTPException) as exc:
            if attempt == attempts:
                raise Blocker(f"{name}: download failed after {attempts} attempts: {type(exc).__name__}: {exc}")
            log(f"FETCH_RETRY {name} attempt={attempt} have={part.stat().st_size if part.is_file() else 0}: "
                f"{type(exc).__name__}: {exc}")
            time.sleep(min(60, 5 * attempt))
    if not file_ok(part, want):
        raise Blocker(f"{name}: checksum mismatch after download")
    if out.is_symlink():
        out.unlink()
    os.replace(part, out)
    mb = out.stat().st_size / 1e6
    log(f"FETCH_OK {repo} {name} {mb:.0f} MB {mb / max(time.time() - t0, 1e-3):.0f} MB/s")


def plan(sc: dict, oc: dict) -> tuple[list[str], list[str]]:
    """The files `fetch` downloads (weight shards, index, config) and the source's weight shards."""
    shards = sorted(n for n in sc if WEIGHT_FILE.match(n))
    if not shards or shards != sorted(n for n in oc if WEIGHT_FILE.match(n)):
        raise Blocker(f"weight shards differ: source {shards} vs original {sorted(n for n in oc if WEIGHT_FILE.match(n))}")
    return shards + list(FETCH_FILES), shards


def cmd_fetch(a) -> dict:
    data = Path(a.source_manifest).read_bytes()
    if hashlib.sha256(data).hexdigest() != SOURCE_MANIFEST_SHA256:
        raise Blocker(f"{a.source_manifest} is not the committed source manifest {SOURCE_MANIFEST_SHA256[:8]}")
    src_meta, org_meta, oq_meta = api(*UNCENSORED), api(*ORIGINAL), api(*OQ)
    sc, oc, qc = checksums(src_meta), checksums(org_meta), checksums(oq_meta)
    check_source_listing(sc, parse_manifest(data))
    for repo, meta in ((UNCENSORED[0], src_meta), (ORIGINAL[0], org_meta), (OQ[0], oq_meta)):
        lic = (meta.get("cardData") or {}).get("license")
        if lic != LICENSE:
            raise Blocker(f"{repo}: card licence {lic!r} is not {LICENSE}")
    files, shards = plan(sc, oc)
    src, org = Path(a.source), Path(a.original)
    need_src = sum(sc[n]["size"] for n in files if not file_ok(src / n, sc[n])) if not a.plan_only else sum(sc[n]["size"] for n in files)
    need_org = sum(oc[n]["size"] for n in files if not file_ok(org / n, oc[n])) if not a.plan_only else 0
    src.mkdir(parents=True, exist_ok=True)
    free = shutil.disk_usage(src).free
    log(f"FETCH_PLAN source_files={files} source_bytes={need_src} original_bytes={need_org} free={free / 1e9:.0f} GB "
        f"skipped={sorted(set(sc) - set(files))}")
    if not a.plan_only and free < need_src + need_org + (40 << 30):
        raise Blocker(f"disk: {free / 1e9:.0f} GB free, need {(need_src + need_org) / 1e9 + 40:.0f} GB with margin")
    if not a.plan_only:
        for name in files:
            download(*UNCENSORED, name, src, sc[name])
        org.mkdir(parents=True, exist_ok=True)
        for name in files:
            download(*ORIGINAL, name, org, oc[name])
        refuse_pickles(src)
        refuse_pickles(org)
    doc = {
        "schema": "macprovider.inkling2-uncensored-fetch.v1",
        "source": {"repo": UNCENSORED[0], "revision": UNCENSORED[1], "license": LICENSE,
                   "snapshot_manifest_sha256": SOURCE_MANIFEST_SHA256},
        "original": {"repo": ORIGINAL[0], "revision": ORIGINAL[1], "license": LICENSE},
        "served_base": {"repo": OQ[0], "revision": OQ[1], "license": LICENSE, "snapshot_manifest_sha256": OQ_MANIFEST_SHA256},
        "fetched": files,
        "weight_shards": shards,
        "source_files": sc,
        "original_files": oc,
        "served_base_files": qc,
    }
    Path(a.out).write_text(json.dumps(doc, indent=2, sort_keys=True))
    log(f"FETCH_{'PLAN_ONLY (nothing downloaded)' if a.plan_only else 'DONE'} -> {a.out}")
    return doc


# ---------------------------------------------------------------- diff

def config_equal(a: dict, b: dict) -> list[str]:
    keys = (set(a) | set(b)) - IGNORABLE_CONFIG_KEYS
    return sorted(k for k in keys if a.get(k, "<absent>") != b.get(k, "<absent>"))


def compare_files(fetch: dict, src: Path, org: Path) -> dict:
    """Every non-weight source file equals the original's; edit.pt is the only extra."""
    sc, oc = fetch["source_files"], fetch["original_files"]
    extra = sorted(set(sc) - set(oc))
    missing = sorted(set(oc) - set(sc))
    if missing:
        raise Blocker(f"source lacks original files {missing}")
    if set(extra) - ALLOWED_EXTRA:
        raise Blocker(f"source has extra files {sorted(set(extra) - ALLOWED_EXTRA)} (only {sorted(ALLOWED_EXTRA)} allowed)")
    differ = []
    for name in sorted(oc):
        if name in FREE_FILES or WEIGHT_FILE.match(name) or same_checksum(sc[name], oc[name]):
            continue
        if name == "config.json":
            keys = config_equal(json.loads((src / name).read_text()), json.loads((org / name).read_text()))
            if keys:
                raise Blocker(f"config.json differs from the original in {keys}")
            differ.append("config.json (ignorable keys only)")
            continue
        differ.append(name)
    hard = [d for d in differ if not d.startswith("config.json")]
    if hard:
        raise Blocker(f"source files {hard} differ from the original (only the weights may change)")
    return {"extra_files_never_fetched": extra, "differing_ignorable": differ,
            "identical_by_checksum": sorted(n for n in oc if n not in FREE_FILES and not WEIGHT_FILE.match(n)
                                            and same_checksum(sc[n], oc[n]))}


def diff_tensors(src: Shards, org: Shards, expect: int | None) -> dict:
    names = src.names()
    if names != org.names():
        raise Blocker(f"tensor names differ: {sorted(set(names) ^ set(org.names()))[:8]}")
    changed, counts = [], {"tensors": 0, "identical": 0, "changed": 0}
    t0 = time.time()
    for name in names:
        s_shard, _, s = src.locate(name)
        o_shard, _, o = org.locate(name)
        if (s["dtype"], s["shape"]) != (o["dtype"], o["shape"]):
            raise Blocker(f"{name}: {s['dtype']}{s['shape']} vs original {o['dtype']}{o['shape']}")
        counts["tensors"] += 1
        if counts["tensors"] % 200 == 0:
            log(f"DIFF_SCAN tensors={counts['tensors']} changed={counts['changed']} {time.time() - t0:.0f}s")
        sd, od = src.digest(name), org.digest(name)
        if sd == od:
            counts["identical"] += 1
            continue
        counts["changed"] += 1
        m = CHANGED_TENSOR.match(name)
        changed.append({"name": name, "layer": int(m.group(1)) if m else None, "dtype": s["dtype"], "shape": s["shape"],
                        "source_shard": s_shard, "original_shard": o_shard, "sha256_source": sd, "sha256_original": od})
    meta = {}
    for shard in sorted(set(src.weight_map.values())):
        meta[shard] = src.headers[shard][1].get("__metadata__")
    unexpected = [c["name"] for c in changed if c["layer"] is None]
    log(f"DIFF_COMPARED tensors={counts['tensors']} identical={counts['identical']} changed={counts['changed']} "
        f"layers={sorted(c['layer'] for c in changed if c['layer'] is not None)}")
    if unexpected:
        raise Blocker(f"{len(unexpected)} tensors changed outside the attention output projections: {unexpected[:8]}")
    if not changed:
        raise Blocker("no tensor differs from the original: the source is not the uncensored edit")
    if expect is not None and len(changed) != expect:
        raise Blocker(f"{len(changed)} attention output projections changed, the card says {expect}")
    for c in changed:
        if c["dtype"] != "BF16" or len(c["shape"]) != 2:
            raise Blocker(f"{c['name']}: changed tensor is {c['dtype']}{c['shape']}, expected a BF16 matrix")
    return {"compared": counts, "changed_tensors": changed, "source_header_metadata": meta}


def cmd_diff(a) -> int:
    src, org = Path(a.source), Path(a.original)
    refuse_pickles(src)
    refuse_pickles(org)
    fetch = json.loads(Path(a.fetch).read_text())
    for root, files in ((src, fetch["source_files"]), (org, fetch["original_files"])):
        for name in fetch["fetched"]:
            if not file_ok(root / name, files[name]):
                raise Blocker(f"{root / name}: missing or not its pinned checksum")
    files = compare_files(fetch, src, org)
    expect = None if a.expect_changed == "any" else int(a.expect_changed)
    tensors = diff_tensors(Shards(src), Shards(org), expect)
    doc = {"schema": "macprovider.inkling2-uncensored-diff.v1", "source": fetch["source"], "original": fetch["original"],
           "expect_changed": a.expect_changed, **files, **tensors}
    Path(a.out).write_text(json.dumps(doc, indent=2, sort_keys=True))
    log(f"DIFF_DONE changed={len(tensors['changed_tensors'])} attention output projections only -> {a.out}")
    return 0


# ---------------------------------------------------------------- splice

def quant_spec(config: dict, module: str, base: Shards) -> dict:
    """The base's format for MODULE, from its quantization map, checked against the tensor shapes."""
    q = config.get("quantization") or {}
    value = q.get(module)
    if not isinstance(value, dict):
        value = {k: q[k] for k in ("group_size", "bits", "mode") if k in q}
    spec = {k: value.get(k) for k in ("group_size", "bits", "mode")}
    if spec["mode"] != "affine" or not spec["group_size"] or not spec["bits"]:
        raise Blocker(f"{module}: base format {spec} is not affine (the splice re-quantizes affine only)")
    _, _, w = base.locate(module + ".weight")
    _, _, s = base.locate(module + ".scales")
    _, _, b = base.locate(module + ".biases")
    rows, packed = w["shape"]
    cols = packed * 32 // spec["bits"]
    if w["dtype"] != "U32" or s["shape"] != [rows, cols // spec["group_size"]] or b["shape"] != s["shape"] \
            or s["dtype"] != b["dtype"]:
        raise Blocker(f"{module}: tensors {w['dtype']}{w['shape']} {s['dtype']}{s['shape']} {b['dtype']}{b['shape']} "
                      f"do not fit {spec}")
    return {**spec, "rows": rows, "cols": cols, "scale_dtype": s["dtype"]}


# ---------------------------------------------------------------- oQ affine quantizer
# Ported from oMLX v0.8.1 (github.com/jundot/omlx, tag v0.8.1, commit 13fd0c9d, omlx/oq.py:
# _affine_minmax_params, _pack_affine_codes, _LSQ_*, _weighted_lsq_refit and
# _weighted_affine_quantize). Copyright 2025 oMLX contributors, Apache License 2.0
# (http://www.apache.org/licenses/LICENSE-2.0). Changes: mlx is passed in, importance None
# means uniform, packing covers 2/4/8 bits only. oMLX runs the refit as a Metal kernel on the
# GPU for groups of 32/64/128; this is its mlx-ops version (the one oMLX uses on the CPU).
# The base's oQ4e build fed each attn.o_proj a calibration imatrix (mean squared input per
# channel); that imatrix is not published, so the splice passes uniform importance.

_OQ_LSQ_ROUNDS = 5
_OQ_LSQ_START_FACTORS = (0.55, 0.65, 0.75, 0.85, 0.95, 1.05, 1.15)
_OQ_CLIP_FACTORS = (0.5, 0.625, 0.75, 0.875, 1.0, 1.125, 1.25)


def _oq_affine_minmax_params(mx, grouped, bits: int):
    n_bins = mx.array((1 << bits) - 1, mx.float32)
    eps = mx.array(1e-7, mx.float32)
    zero = mx.array(0.0, mx.float32)
    w_max = mx.max(grouped, axis=-1, keepdims=True).astype(mx.float32)
    w_min = mx.min(grouped, axis=-1, keepdims=True).astype(mx.float32)
    mask = mx.abs(w_min) > mx.abs(w_max)
    scales = mx.maximum((w_max - w_min) / n_bins, eps)
    scales = mx.where(mask, scales, -scales)
    edge = mx.where(mask, w_min, w_max)
    q0 = mx.round(edge / scales)
    scales = mx.where(q0 != zero, edge / q0, scales)
    biases = mx.where(q0 == zero, zero, edge)
    return scales, biases


def _oq_pack_affine_codes(mx, w, scales, biases, group_size: int, bits: int):
    if bits not in (2, 4, 8):
        raise Blocker(f"the oQ port packs 2, 4 and 8 bits, not {bits}")
    orig = tuple(w.shape)
    grouped = w.reshape(-1, orig[-1] // group_size, group_size)
    n_bins = mx.array((1 << bits) - 1, mx.float32)
    codes = mx.clip(mx.round((grouped - biases) / scales), 0, n_bins).astype(mx.uint32)
    shifts = mx.power(mx.array(2, mx.uint32), mx.arange(0, 32, bits, dtype=mx.uint32))
    packed = mx.sum(codes.reshape(codes.shape[0], -1, 32 // bits) * shifts, axis=2)
    return packed.reshape(*orig[:-1], orig[-1] * bits // 32)


def _oq_weighted_lsq_refit(mx, grouped, imp, scales, biases, bits: int, dtype):
    """Per group, alternate rounding with the closed-form weighted least-squares fit of
    v ~ s * c + b, from the given parameters and from symmetric clipping starts; errors use
    the stored (DTYPE) precision, and a group keeps its parameters unless the error drops."""
    n_bins = mx.array((1 << bits) - 1, mx.float32)
    tiny = mx.array(1e-7, mx.float32)

    def stored(x):
        return x.astype(dtype).astype(mx.float32)

    def fit(s, b):
        codes = mx.clip(mx.round((grouped - b) / s), 0, n_bins)
        err = mx.sum(imp * (grouped - (codes * s + b)) ** 2, axis=-1, keepdims=True)
        return codes, err

    total = mx.sum(imp, axis=-1, keepdims=True)
    sum_v = mx.sum(imp * grouped, axis=-1, keepdims=True)
    best_s, best_b = stored(scales), stored(biases)
    _, best_err = fit(best_s, best_b)
    w_min = mx.min(grouped, axis=-1, keepdims=True)
    w_max = mx.max(grouped, axis=-1, keepdims=True)
    starts = [(best_s, best_b)]
    for factor in _OQ_LSQ_START_FACTORS:
        s = mx.maximum((w_max - w_min) * factor / n_bins, tiny)
        starts.append((s, (w_max + w_min) * 0.5 - n_bins * 0.5 * s))
    for s, b in starts:
        s, b = stored(s), stored(b)
        for _ in range(_OQ_LSQ_ROUNDS):
            codes, err = fit(s, b)
            take = err < best_err
            best_err = mx.where(take, err, best_err)
            best_s = mx.where(take, s, best_s)
            best_b = mx.where(take, b, best_b)
            sum_c = mx.sum(imp * codes, axis=-1, keepdims=True)
            sum_cc = mx.sum(imp * codes * codes, axis=-1, keepdims=True)
            sum_cv = mx.sum(imp * codes * grouped, axis=-1, keepdims=True)
            denom = sum_cc - sum_c * sum_c / total
            safe = mx.where(denom > 0, denom, mx.array(1.0, mx.float32))
            new_s = (sum_cv - sum_c * sum_v / total) / safe
            ok = (denom > 0) & (mx.abs(new_s) > tiny)
            new_b = (sum_v - new_s * sum_c) / total
            s = stored(mx.where(ok, new_s, s))
            b = stored(mx.where(ok, new_b, b))
        mx.eval(best_s, best_b, best_err)
    return best_s, best_b


def oq_affine_quantize(mx, w, group_size: int, bits: int, importance=None):
    """oQ affine quantization of a 2-D weight: min/max start, an importance-weighted clipping
    search, then the least-squares refit. Same layout and dtypes as
    mx.quantize(w, group_size, bits, mode="affine"); scales and biases in w's dtype."""
    orig = tuple(w.shape)
    grouped_f = w.reshape(-1, orig[-1] // group_size, group_size).astype(mx.float32)
    if importance is None:
        imp = mx.ones(grouped_f.shape, mx.float32)
    else:
        imp = mx.broadcast_to(mx.array(importance), orig).reshape(grouped_f.shape).astype(mx.float32)
    imp = mx.maximum(imp, mx.array(1e-8, mx.float32))

    n_bins = mx.array((1 << bits) - 1, mx.float32)
    eps = mx.array(1e-7, mx.float32)
    best_scales, best_biases = _oq_affine_minmax_params(mx, grouped_f, bits)
    best_codes = mx.clip(mx.round((grouped_f - best_biases) / best_scales), 0, n_bins)
    best_err = mx.sum(imp * (grouped_f - (best_codes * best_scales + best_biases)) ** 2, axis=-1, keepdims=True)
    w_min = mx.min(grouped_f, axis=-1, keepdims=True)
    w_max = mx.max(grouped_f, axis=-1, keepdims=True)
    for edge, opposite, sign in ((w_max, w_min, -1.0), (w_min, w_max, 1.0)):
        raw = mx.maximum(mx.abs(edge - opposite) / n_bins, eps) * sign
        q0 = mx.round(edge / raw)
        scale0 = mx.where(q0 != 0, edge / q0, raw)
        bias0 = mx.where(q0 == 0, mx.array(0.0, mx.float32), edge)
        for factor in _OQ_CLIP_FACTORS:
            scales = scale0 * mx.array(factor, mx.float32)
            codes = mx.clip(mx.round((grouped_f - bias0) / scales), 0, n_bins)
            err = mx.sum(imp * (grouped_f - (codes * scales + bias0)) ** 2, axis=-1, keepdims=True)
            take = err < best_err
            best_err = mx.where(take, err, best_err)
            best_scales = mx.where(take, scales, best_scales)
            best_biases = mx.where(take, bias0, best_biases)

    best_scales, best_biases = _oq_weighted_lsq_refit(mx, grouped_f, imp, best_scales, best_biases, bits, w.dtype)
    packed = _oq_pack_affine_codes(mx, grouped_f.reshape(orig), best_scales, best_biases, group_size, bits)
    scale_shape = (*orig[:-1], orig[-1] // group_size)
    scales = best_scales.reshape(scale_shape).astype(w.dtype)
    biases = best_biases.reshape(scale_shape).astype(w.dtype)
    mx.eval(packed, scales, biases)
    return packed, scales, biases


class MlxQuantizer:
    """oQ affine quantization (oq_affine_quantize) / mx.dequantize in the base's affine format;
    numpy cross-checks the dequantization."""

    def __init__(self):
        import mlx.core as mx
        import numpy as np
        self.mx, self.np = mx, np

    def _bf16(self, raw: bytes, shape: list[int]):
        mx, np = self.mx, self.np
        return mx.array(np.frombuffer(raw, dtype="<u2").reshape(shape)).view(mx.bfloat16)

    def quantize(self, raw: bytes, shape: list[int], spec: dict) -> dict[str, bytes]:
        mx, np = self.mx, self.np
        if spec["scale_dtype"] != "BF16":
            raise Blocker(f"scales are {spec['scale_dtype']}; the splice writes BF16 scales")
        w = self._bf16(raw, shape)
        wq, scales, biases = oq_affine_quantize(mx, w, spec["group_size"], spec["bits"])
        if scales.dtype != mx.bfloat16 or biases.dtype != mx.bfloat16 or wq.dtype != mx.uint32:
            raise Blocker(f"oq_affine_quantize returned {wq.dtype}/{scales.dtype}/{biases.dtype}")
        return {"weight": np.array(wq).astype("<u4").tobytes(),
                "scales": np.array(scales.view(mx.uint16)).astype("<u2").tobytes(),
                "biases": np.array(biases.view(mx.uint16)).astype("<u2").tobytes()}

    def numpy_dequant(self, parts: dict[str, bytes], spec: dict):
        np = self.np
        rows, cols, g, bits = spec["rows"], spec["cols"], spec["group_size"], spec["bits"]
        if bits not in (4, 8):
            raise Blocker(f"numpy decode handles 4 and 8 bits, not {bits}")
        b = np.frombuffer(parts["weight"], dtype=np.uint8).reshape(rows, -1)
        q = b if bits == 8 else np.stack([b & 0x0F, b >> 4], axis=-1).reshape(rows, -1)
        f32 = lambda raw: (np.frombuffer(raw, "<u2").astype(np.uint32) << 16).view(np.float32).reshape(rows, cols // g)
        s, z = f32(parts["scales"]), f32(parts["biases"])
        return (q.reshape(rows, cols // g, g).astype(np.float32) * s[..., None] + z[..., None]).reshape(rows, cols)

    def mlx_dequant(self, parts: dict[str, bytes], spec: dict):
        mx, np = self.mx, self.np
        rows, cols, g = spec["rows"], spec["cols"], spec["group_size"]
        w = mx.array(np.frombuffer(parts["weight"], "<u4").reshape(rows, -1))
        # Float32 scales and biases (exact widening of the stored BF16), so the result is not
        # rounded to BF16 and numpy can check it to float32 precision.
        s = mx.array(np.frombuffer(parts["scales"], "<u2").reshape(rows, cols // g)).view(mx.bfloat16).astype(mx.float32)
        z = mx.array(np.frombuffer(parts["biases"], "<u2").reshape(rows, cols // g)).view(mx.bfloat16).astype(mx.float32)
        out = mx.dequantize(w, s, z, group_size=g, bits=spec["bits"], mode="affine").astype(mx.float32)
        return np.array(out)

    def reference(self, raw: bytes, shape: list[int]):
        np = self.np
        return (np.frombuffer(raw, "<u2").astype(np.uint32) << 16).view(np.float32).reshape(shape)

    def error(self, parts: dict[str, bytes], spec: dict, ref_raw: bytes, shape: list[int]) -> dict:
        """Dequantization error of PARTS against the BF16 weight REF_RAW, by mlx and by numpy."""
        np = self.np
        ref = self.reference(ref_raw, shape).astype(np.float64)
        got = self.mlx_dequant(parts, spec).astype(np.float64)
        alt = self.numpy_dequant(parts, spec).astype(np.float64)
        d = got - ref
        return {"ref_max_abs": float(np.abs(ref).max()), "max_abs": float(np.abs(d).max()), "rel_fro": float(np.linalg.norm(d) / max(np.linalg.norm(ref), 1e-30)),
                "mlx_vs_numpy_max_abs": float(np.abs(got - alt).max())}

    def edit_size(self, new_raw: bytes, old_raw: bytes, shape: list[int]) -> dict:
        np = self.np
        a, b = self.reference(new_raw, shape).astype(np.float64), self.reference(old_raw, shape).astype(np.float64)
        d = a - b
        return {"max_abs": float(np.abs(d).max()), "rel_fro": float(np.linalg.norm(d) / max(np.linalg.norm(b), 1e-30)),
                "elements_changed": int(np.count_nonzero(d))}


# 8-bit affine g64 on BF16 weights errs well under 1% (relative Frobenius). An error near 1
# means the base tensor is not a plain quantization of the source tensor (a transform this
# splice does not apply), which a ratio against that same error could never catch.
ABS_REL_FRO = 0.02


def recipe_failures(row: dict, error_ratio: float, max_error_ratio: float) -> list[str]:
    """The base really is the source tensor in this format, and our oQ recipe is in
    line with oMLX's on the original weight (byte-equal when `recipe_reproduced`)."""
    be, oe = row["base_error"], row["our_original_error"]
    fails = []
    for label, e in (("base", be), ("our recipe", oe)):
        if e["rel_fro"] > ABS_REL_FRO:
            fails.append(f"{label} error on the original rel_fro {e['rel_fro']:.3e} above {ABS_REL_FRO}: "
                         "the base tensor is not a plain quantization of attn.wo_ud")
        if e["mlx_vs_numpy_max_abs"] > 1e-5 * e["ref_max_abs"] + 1e-7:
            fails.append(f"{label}: mlx and numpy dequantization disagree by {e['mlx_vs_numpy_max_abs']:.3e}")
    if not row["recipe_reproduced"]:
        if oe["rel_fro"] > error_ratio * be["rel_fro"]:
            fails.append(f"our recipe on the original rel_fro {oe['rel_fro']:.3e} > {error_ratio} x base {be['rel_fro']:.3e}")
        if oe["max_abs"] > max_error_ratio * be["max_abs"]:
            fails.append(f"our recipe on the original max_abs {oe['max_abs']:.3e} > {max_error_ratio} x base {be['max_abs']:.3e}")
    return fails


def recipe(base: Path, org: Path, quantizer, error_ratio: float, max_error_ratio: float) -> dict:
    """Before the splice: every base attn.o_proj against our oQ quantization of the
    original attn.wo_ud of the same layer (format from the base's quantization map)."""
    refuse_pickles(base)
    refuse_pickles(org)
    config = json.loads((base / "config.json").read_text())
    base_sh, org_sh = Shards(base), Shards(org)
    layers = sorted(int(m.group(1)) for m in map(CHANGED_TENSOR.match, org_sh.names()) if m)
    if not layers:
        raise Blocker(f"{org}: no attn.wo_ud tensors")
    rows = []
    for layer in layers:
        name, module = f"model.llm.layers.{layer}.attn.wo_ud.weight", oq_module(layer)
        _, _, entry = org_sh.locate(name)
        spec = quant_spec(config, module, base_sh)
        if entry["dtype"] != "BF16" or [spec["rows"], spec["cols"]] != entry["shape"]:
            raise Blocker(f"{name}: {entry['dtype']}{entry['shape']} does not fit {module} [{spec['rows']}, {spec['cols']}]")
        raw = org_sh.read(name)
        base_parts = {s: base_sh.read(f"{module}.{s}") for s in ("weight", "scales", "biases")}
        ours = quantizer.quantize(raw, entry["shape"], spec)
        row = {"module": module, "layer": layer, "format": {k: spec[k] for k in ("group_size", "bits", "mode")},
               "recipe_reproduced": ours == base_parts,
               "recipe_bytes_equal": {s: ours[s] == base_parts[s] for s in base_parts},
               "base_error": quantizer.error(base_parts, spec, raw, entry["shape"]),
               "our_original_error": quantizer.error(ours, spec, raw, entry["shape"])}
        row["failures"] = recipe_failures(row, error_ratio, max_error_ratio)
        rows.append(row)
        log(f"RECIPE {module} reproduced={int(row['recipe_reproduced'])} base_rel_fro={row['base_error']['rel_fro']:.3e} "
            f"ours_rel_fro={row['our_original_error']['rel_fro']:.3e} {'PASS' if not row['failures'] else 'FAIL ' + '; '.join(row['failures'])}")
    failures = [f"{r['module']}: {f}" for r in rows for f in r["failures"]]
    log(f"RECIPE_GATE {'PASS' if not failures else 'FAIL'} modules={len(rows)} "
        f"reproduced={sum(r['recipe_reproduced'] for r in rows)}/{len(rows)}")
    if failures:
        raise Blocker(f"recipe check failed: {failures[:5]}")
    return {"schema": "macprovider.inkling2-uncensored-recipe.v1", "modules": rows,
            "reproduced": sum(r["recipe_reproduced"] for r in rows), "error_ratio": error_ratio,
            "max_error_ratio": max_error_ratio, "abs_rel_fro": ABS_REL_FRO}


def cmd_recipe(a) -> int:
    doc = recipe(Path(a.base), Path(a.original), MlxQuantizer(), a.error_ratio, a.max_error_ratio)
    Path(a.out).write_text(json.dumps(doc, indent=2, sort_keys=True))
    return 0


def private_clone(path: Path) -> None:
    """Make PATH a private APFS clone (never a symlink or hard link into the base or the store)
    before any byte of it is written."""
    real = Path(os.path.realpath(path))
    old_ino = os.stat(real).st_ino
    tmp = path.with_name(path.name + ".splice-tmp")
    if tmp.exists():
        tmp.unlink()
    cp = ["/bin/cp", "-c", str(real), str(tmp)] if sys.platform == "darwin" else ["/bin/cp", str(real), str(tmp)]
    subprocess.run(cp, check=True)
    os.replace(tmp, path)
    st = path.lstat()
    if path.is_symlink() or st.st_nlink != 1 or st.st_ino == old_ino:
        raise Blocker(f"{path}: not a private copy after cloning")


def listing(root: Path) -> list[str]:
    return sorted(str(p.relative_to(root)) for p in root.rglob("*")
                  if p.is_file() and ".cache" not in p.relative_to(root).parts)


def splice(base: Path, src: Path, org: Path, out: Path, fetch: dict, diff: dict, quantizer,
           error_ratio: float, max_error_ratio: float) -> dict:
    if os.path.realpath(base) == os.path.realpath(out):
        raise Blocker("--out is --base")
    for root in (base, src, org, out):
        refuse_pickles(root)
    if listing(out) != listing(base):
        raise Blocker("--out and --base hold different file sets: --out must be an APFS clone of --base")
    config = json.loads((base / "config.json").read_text())
    base_sh, src_sh, org_sh = Shards(base), Shards(src), Shards(org)
    # The diff decides what changed; re-check its byte claims against the files on disk.
    rows, writes = [], {}
    for c in sorted(diff["changed_tensors"], key=lambda c: c["layer"]):
        if c["layer"] is None or not CHANGED_TENSOR.match(c["name"]):
            raise Blocker(f"{c['name']}: the diff lists a change outside the attention output projections")
        new_raw, old_raw = src_sh.read(c["name"]), org_sh.read(c["name"])
        if hashlib.sha256(new_raw).hexdigest() != c["sha256_source"] or hashlib.sha256(old_raw).hexdigest() != c["sha256_original"]:
            raise Blocker(f"{c['name']}: bytes on disk are not the diff's")
        module = oq_module(c["layer"])
        spec = quant_spec(config, module, base_sh)
        if [spec["rows"], spec["cols"]] != c["shape"]:
            raise Blocker(f"{module}: base holds a [{spec['rows']}, {spec['cols']}] matrix, the source {c['shape']}")
        base_parts = {s: base_sh.read(f"{module}.{s}") for s in ("weight", "scales", "biases")}
        new_parts = quantizer.quantize(new_raw, c["shape"], spec)
        recipe = quantizer.quantize(old_raw, c["shape"], spec)
        for s, raw in new_parts.items():
            if len(raw) != len(base_parts[s]):
                raise Blocker(f"{module}.{s}: {len(raw)} bytes, the base holds {len(base_parts[s])}")
        row = {"module": module, "source_tensor": c["name"], "layer": c["layer"],
               "format": {k: spec[k] for k in ("group_size", "bits", "mode")},
               "recipe_reproduced": recipe == base_parts,
               "recipe_bytes_equal": {s: recipe[s] == base_parts[s] for s in base_parts},
               "base_error": quantizer.error(base_parts, spec, old_raw, c["shape"]),
               "spliced_error": quantizer.error(new_parts, spec, new_raw, c["shape"]),
               "our_original_error": quantizer.error(recipe, spec, old_raw, c["shape"]),
               "edit": quantizer.edit_size(new_raw, old_raw, c["shape"]),
               "bytes_equal_base": {s: new_parts[s] == base_parts[s] for s in base_parts},
               "sha256_after": {s: hashlib.sha256(new_parts[s]).hexdigest() for s in new_parts}}
        be, se = row["base_error"], row["spliced_error"]
        fails = recipe_failures(row, error_ratio, max_error_ratio)
        if all(row["bytes_equal_base"].values()):
            fails.append("re-quantized bytes equal the base: the edit did not survive quantization")
        if se["rel_fro"] > error_ratio * be["rel_fro"]:
            fails.append(f"rel_fro {se['rel_fro']:.3e} > {error_ratio} x base {be['rel_fro']:.3e}")
        if se["max_abs"] > max_error_ratio * be["max_abs"]:
            fails.append(f"max_abs {se['max_abs']:.3e} > {max_error_ratio} x base {be['max_abs']:.3e}")
        # Apples to apples: the same oQ recipe on the edited and on the original weight.
        oe = row["our_original_error"]
        if se["rel_fro"] > error_ratio * oe["rel_fro"]:
            fails.append(f"rel_fro {se['rel_fro']:.3e} > {error_ratio} x our recipe on the original {oe['rel_fro']:.3e}")
        if se["rel_fro"] > ABS_REL_FRO:
            fails.append(f"rel_fro {se['rel_fro']:.3e} above the absolute bound {ABS_REL_FRO}")
        if se["mlx_vs_numpy_max_abs"] > 1e-5 * se["ref_max_abs"] + 1e-7:
            fails.append(f"mlx and numpy dequantization disagree by {se['mlx_vs_numpy_max_abs']:.3e}")
        row["failures"] = fails
        rows.append(row)
        log(f"NUMERIC {module} recipe_reproduced={int(row['recipe_reproduced'])} base_rel_fro={be['rel_fro']:.3e} "
            f"spliced_rel_fro={se['rel_fro']:.3e} base_max_abs={be['max_abs']:.3e} spliced_max_abs={se['max_abs']:.3e} "
            f"edit_rel_fro={row['edit']['rel_fro']:.3e} {'PASS' if not fails else 'FAIL ' + '; '.join(fails)}")
        for s in new_parts:
            writes[f"{module}.{s}"] = new_parts[s]
    failures = [f"{r['module']}: {f}" for r in rows for f in r["failures"]]
    if failures:
        raise Blocker(f"numeric gate failed: {failures[:5]}")
    worst = max(r["spliced_error"]["rel_fro"] / max(r["base_error"]["rel_fro"], 1e-30) for r in rows)
    log(f"NUMERIC_GATE PASS modules={len(rows)} recipe_reproduced={sum(r['recipe_reproduced'] for r in rows)}/{len(rows)} "
        f"worst_rel_fro_ratio={worst:.3f} (limit {error_ratio})")

    # Write the new bytes in place into private clones of the touched shards.
    touched = sorted({base_sh.locate(n)[0] for n in writes})
    for shard in touched:
        private_clone(out / shard)
    for name, raw in sorted(writes.items()):
        shard, start, entry = base_sh.locate(name)
        with open(out / shard, "r+b") as f:
            f.seek(start + entry["data_offsets"][0])
            f.write(raw)
    log(f"SPLICE_WRITTEN tensors={len(writes)} shards={touched}")

    # Verify OUT.
    out_sh = Shards(out)
    for shard in touched:
        if read_header(out / shard)[2] != base_sh.headers[shard][2]:
            raise Blocker(f"{shard}: header changed")
        for tname in (k for k in base_sh.headers[shard][1] if k != "__metadata__"):
            got = out_sh.read(tname)
            if tname in writes:
                if got != writes[tname]:
                    raise Blocker(f"{tname}: written bytes are not the re-quantized tensor")
            elif got != base_sh.read(tname):
                raise Blocker(f"{tname}: untouched tensor differs from the base")
    want = fetch["served_base_files"]
    files = listing(out)
    if files != listing(base):
        raise Blocker("--out and --base hold different file sets after the splice")
    sums = {}
    for rel in files:
        p = out / rel
        if rel in touched:
            sums[rel] = sha256_file(p)
            if rel not in want or sums[rel] == want[rel].get("sha256"):
                raise Blocker(f"{rel}: touched shard is unpinned or unchanged")
        elif rel in want:
            if not file_ok(p, want[rel]):
                raise Blocker(f"{rel}: untouched file is not the base repo's file")
            sums[rel] = want[rel].get("sha256") or want[rel].get("blob_sha1")
        else:
            raise Blocker(f"{rel}: not a file of {OQ[0]}@{OQ[1][:8]}")
    if set(want) - {".gitattributes"} - set(files):
        raise Blocker(f"--out lacks base repo files {sorted(set(want) - {'.gitattributes'} - set(files))}")
    log(f"SPLICE_VERIFIED files={len(files)} touched={len(touched)} untouched_files_match_base_repo=1")
    return {
        "schema": "macprovider.inkling2-uncensored-splice.v1",
        "license": LICENSE,
        "source": fetch["source"], "original": fetch["original"], "served_base": fetch["served_base"],
        "recipe": "the base's attn.o_proj format from its config quantization map (affine, "
                  f"{sorted({json.dumps(r['format'], sort_keys=True) for r in rows})}), oMLX's oQ affine quantizer "
                  "(clipping search and least-squares refit, uniform importance) on the "
                  "uncensored BF16 attn.wo_ud weight; every other tensor and file byte-identical to the base",
        "compared": diff["compared"],
        "changed_modules": rows,
        "recipe_reproduced": sum(r["recipe_reproduced"] for r in rows),
        "worst_rel_fro_ratio": worst,
        "error_ratio": error_ratio, "max_error_ratio": max_error_ratio,
        "touched_shards": {s: {"sha256_before": want[s]["sha256"], "sha256_after": sums[s]} for s in touched},
        "files": sums,
    }


def cmd_splice(a) -> int:
    fetch = json.loads(Path(a.fetch).read_text())
    diff = json.loads(Path(a.diff).read_text())
    doc = splice(Path(a.base), Path(a.source), Path(a.original), Path(a.out), fetch, diff, MlxQuantizer(),
                 a.error_ratio, a.max_error_ratio)
    doc["diff_sha256"] = hashlib.sha256(Path(a.diff).read_bytes()).hexdigest()
    Path(a.manifest).write_text(json.dumps(doc, indent=2, sort_keys=True))
    log(f"SPLICE_DONE modules={len(doc['changed_modules'])} touched_shards={len(doc['touched_shards'])} manifest={a.manifest}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("fetch")
    for k in ("--source", "--original", "--source-manifest", "--out"):
        p.add_argument(k, required=True)
    p.add_argument("--plan-only", action="store_true", help="API listings and fetch.json only, no download")
    p = sub.add_parser("diff")
    for k in ("--source", "--original", "--fetch", "--out"):
        p.add_argument(k, required=True)
    p.add_argument("--expect-changed", default=str(EXPECT_CHANGED))
    p = sub.add_parser("recipe")
    for k in ("--base", "--original", "--out"):
        p.add_argument(k, required=True)
    p.add_argument("--error-ratio", type=float, default=1.25)
    p.add_argument("--max-error-ratio", type=float, default=2.0)
    p = sub.add_parser("splice")
    for k in ("--base", "--source", "--original", "--fetch", "--diff", "--out", "--manifest"):
        p.add_argument(k, required=True)
    p.add_argument("--error-ratio", type=float, default=1.25)
    p.add_argument("--max-error-ratio", type=float, default=2.0)
    a = ap.parse_args()
    try:
        if a.cmd == "fetch":
            cmd_fetch(a)
            return 0
        return {"diff": cmd_diff, "recipe": cmd_recipe, "splice": cmd_splice}[a.cmd](a)
    except Blocker as exc:
        log(f"BLOCKER: {exc}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
