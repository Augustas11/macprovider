"""Abliterated DeepSeek V4-Flash-0731 in the served MXFP4-MLX layout, by splice (#2409).

The served base, TensorFold/DeepSeek-V4-Flash-0731-MXFP4-MLX, is a byte transplant of
deepseek-ai/DeepSeek-V4-Flash-0731: the same tensor names (`.scale` -> `.scales`), and
- fp4 e2m1 experts (I8 [R, C/2], low nibble first) -> mxfp4 U32 [R, C/8], same bytes;
  their e8m0 scales F8_E8M0 [R, C/32] -> U8 [R, C/32], same bytes;
- fp8 e4m3 dense weights (F8_E4M3 [R, C]) -> mxfp8 U32 [R, C/4], same bytes; their
  128x128-block e8m0 scales [R/128, C/128] -> U8 [R, C/32], each block scale repeated
  over its 128 rows and 4 groups of 32;
- everything else (BF16/F32 norms, gates, compressors, hc_*, embed, head) unchanged.
prem-research/DeepSeek-V4-Flash-0731-abliterated keeps the original format and rewrote
only the shards of layers 17-36. So the abliterated artifact in our layout is the base
with the tensors that changed replaced by their transplant. Every other tensor of the
rewritten shards must transplant to exactly the base's bytes, which re-proves the recipe
on the job's own data.

Subcommands (stdlib + numpy; `splice --numeric` also uses mlx when importable):

  fetch  --dest DIR --out fetch.json [--plan-only]
         Pinned API listings of the three repos; the shards whose LFS sha256 differs
         between deepseek-ai and prem-research (the only ones downloaded, each checked
         against its LFS sha256), prem's index (must equal deepseek-ai's), config.json,
         edited_experts.json, README.md, LICENSE.
  splice --base BASE --source DIR --fetch fetch.json --out OUT --manifest diff.json [--numeric]
         OUT must be an APFS clone of BASE (`cp -c -R`). Pass 1 transplants every tensor of
         the downloaded shards and compares it with BASE; any change outside the card's
         steered modules (layers L of edited_experts.json: attn.wo_b, ffn.shared_experts.w2,
         ffn.experts.E.w2 for E listed) fails. Pass 2 writes the changed tensors in place
         into private clones of the touched shards (headers and offsets do not move).
         Pass 3 verifies: touched shards tensor by tensor (changed = new sha256, all others
         byte-identical to BASE), every other file against the base repo's pinned checksum,
         no extra or missing files. --numeric dequantizes every changed module from OUT
         (mx.dequantize, mxfp4/mxfp8) and from the native source (numpy) and requires
         max abs error 0, plus a sample of untouched modules as a control.

Every failure prints `BLOCKER: ...` and exits nonzero.
"""

from __future__ import annotations

import argparse
import hashlib
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
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np

PREM = ("prem-research/DeepSeek-V4-Flash-0731-abliterated", "457210de3a9d27d8142407cd0dac7b6ed6ad9325")
DEEPSEEK = ("deepseek-ai/DeepSeek-V4-Flash-0731", "7872f01b1d1fe23eabc4c98b48bffcef5a386062")
TENSORFOLD = ("TensorFold/DeepSeek-V4-Flash-0731-MXFP4-MLX", "d6be051ae238b2021de56cf098d8f0206328754a")
SIDE_FILES = ("model.safetensors.index.json", "config.json", "edited_experts.json", "README.md", "LICENSE")
STEERED = ("attn.wo_b", "ffn.shared_experts.w2")  # plus ffn.experts.<E>.w2 for E in edited_experts.json
FP8_BLOCK = 128
MX_GROUP = 32
FP4_TABLE = np.array([0.0, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0, 6.0,
                      -0.0, -0.5, -1.0, -1.5, -2.0, -3.0, -4.0, -6.0], dtype=np.float64)
DTYPE_SIZE = {"BOOL": 1, "U8": 1, "I8": 1, "F8_E4M3": 1, "F8_E8M0": 1, "BF16": 2, "F16": 2,
              "I16": 2, "U16": 2, "F32": 4, "I32": 4, "U32": 4, "F64": 8, "I64": 8, "U64": 8}


class Blocker(Exception):
    pass


def log(msg: str) -> None:
    print(f"{time.strftime('%H:%M:%S')} {msg}", flush=True)


# ---------------------------------------------------------------- numeric formats

def e4m3_table() -> np.ndarray:
    """float8_e4m3fn: bias 7, no infinities, 0x7f/0xff NaN."""
    t = np.empty(256, dtype=np.float64)
    for b in range(256):
        sign = -1.0 if b & 0x80 else 1.0
        exp, man = (b >> 3) & 0xF, b & 0x7
        if exp == 0xF and man == 0x7:
            t[b] = np.nan
        elif exp == 0:
            t[b] = sign * (man / 8.0) * 2.0 ** -6
        else:
            t[b] = sign * (1.0 + man / 8.0) * 2.0 ** (exp - 7)
    return t


E4M3 = e4m3_table()


def e8m0(scales: np.ndarray) -> np.ndarray:
    s = scales.astype(np.float64)
    out = np.exp2(s - 127.0)
    out[scales == 255] = np.nan
    return out


def decode_fp4_native(packed: np.ndarray, scales: np.ndarray) -> np.ndarray:
    """DeepSeek fp4: uint8 [R, C/2], element 2k in the low nibble; e8m0 [R, C/32]."""
    p = packed.view(np.uint8)
    vals = np.stack([FP4_TABLE[p & 0x0F], FP4_TABLE[p >> 4]], axis=-1).reshape(p.shape[0], -1)
    return vals * np.repeat(e8m0(scales), MX_GROUP, axis=1)[:, : vals.shape[1]]


def decode_fp8_native(raw: np.ndarray, scales: np.ndarray) -> np.ndarray:
    """DeepSeek fp8: e4m3 [R, C]; e8m0 per 128x128 block [ceil(R/128), ceil(C/128)]."""
    vals = E4M3[raw.view(np.uint8)]
    r, c = vals.shape
    s = np.repeat(np.repeat(e8m0(scales), FP8_BLOCK, axis=0), FP8_BLOCK, axis=1)[:r, :c]
    return vals * s


def fp8_block_scales_to_mx(scales: np.ndarray, rows: int, cols: int) -> np.ndarray:
    """[ceil(R/128), ceil(C/128)] block scales -> MLX mxfp8 [R, C/32] group scales."""
    per_block = FP8_BLOCK // MX_GROUP
    return np.ascontiguousarray(
        np.repeat(np.repeat(scales.view(np.uint8), FP8_BLOCK, axis=0), per_block, axis=1)[:rows, : cols // MX_GROUP])


def decode_mx_numpy(w_u32: np.ndarray, scales: np.ndarray, bits: int) -> np.ndarray:
    """MLX mxfp4/mxfp8 semantics: element j of a uint32 lane at bits [bits*j, bits*(j+1))."""
    b = np.ascontiguousarray(w_u32).astype("<u4").view(np.uint8).reshape(w_u32.shape[0], -1)
    if bits == 4:
        vals = np.stack([FP4_TABLE[b & 0x0F], FP4_TABLE[b >> 4]], axis=-1).reshape(b.shape[0], -1)
    elif bits == 8:
        vals = E4M3[b]
    else:
        raise ValueError(bits)
    return vals * np.repeat(e8m0(scales), MX_GROUP, axis=1)[:, : vals.shape[1]]


def decode_mx_mlx(w_u32: np.ndarray, scales: np.ndarray, bits: int) -> np.ndarray:
    import mlx.core as mx

    w, s = mx.array(w_u32.astype(np.uint32)), mx.array(scales.astype(np.uint8))
    mode = "mxfp4" if bits == 4 else "mxfp8"
    try:
        out = mx.dequantize(w, s, None, group_size=MX_GROUP, bits=bits, mode=mode, dtype=mx.float32)
    except TypeError:
        out = mx.dequantize(w, s, None, group_size=MX_GROUP, bits=bits, mode=mode)
    return np.array(out.astype(mx.float32)).astype(np.float64)


def max_abs_error(a: np.ndarray, b: np.ndarray) -> float:
    if a.shape != b.shape:
        return float("inf")
    nan_a, nan_b = np.isnan(a), np.isnan(b)
    if not np.array_equal(nan_a, nan_b):
        return float("inf")
    d = np.abs(np.where(nan_a, 0.0, a) - np.where(nan_b, 0.0, b))
    return float(d.max()) if d.size else 0.0


# ---------------------------------------------------------------- the transplant

def tf_name(name: str) -> str:
    return name[: -len(".scale")] + ".scales" if name.endswith(".scale") else name


def module_of(name: str) -> str:
    for suffix in (".weight", ".scales", ".scale"):
        if name.endswith(suffix):
            return name[: -len(suffix)]
    return name


def transplant(name: str, src: dict, raw: bytes, dst: dict, weight_dtype: str | None) -> bytes:
    """Source tensor bytes -> base-layout bytes. `weight_dtype` is the source dtype of the
    module's weight when `name` is a scale. Raises Blocker on any unmapped combination."""
    sd, ss, dd, ds = src["dtype"], list(src["shape"]), dst["dtype"], list(dst["shape"])
    if name.endswith(".weight") and sd == "I8" and dd == "U32":
        ok = len(ss) == 2 and ds == [ss[0], ss[1] // 4] and ss[1] % 4 == 0
    elif name.endswith(".weight") and sd == "F8_E4M3" and dd == "U32":
        ok = len(ss) == 2 and ds == [ss[0], ss[1] // 4] and ss[1] % 4 == 0
    elif name.endswith(".scale") and sd == "F8_E8M0" and dd == "U8" and weight_dtype == "I8":
        ok = ds == ss
    elif name.endswith(".scale") and sd == "F8_E8M0" and dd == "U8" and weight_dtype == "F8_E4M3":
        rows, groups = ds
        if ss != [-(-rows // FP8_BLOCK), -(-groups * MX_GROUP // FP8_BLOCK)]:
            raise Blocker(f"{name}: fp8 block scale {ss} does not cover base scales {ds}")
        arr = np.frombuffer(raw, dtype=np.uint8).reshape(ss)
        return fp8_block_scales_to_mx(arr, rows, groups * MX_GROUP).tobytes()
    else:
        ok = sd == dd and ss == ds
    if not ok:
        raise Blocker(f"{name}: no transplant from {sd}{ss} to {dd}{ds} (weight {weight_dtype})")
    return raw


# ---------------------------------------------------------------- safetensors I/O

def read_header(path: Path) -> tuple[int, dict, bytes]:
    with open(path, "rb") as f:
        n = struct.unpack("<Q", f.read(8))[0]
        blob = f.read(n)
    return 8 + n, json.loads(blob), blob


def tensor_bytes(f, start: int, entry: dict) -> bytes:
    a, b = entry["data_offsets"]
    f.seek(start + a)
    data = f.read(b - a)
    if len(data) != b - a:
        raise Blocker(f"short read at {start + a}")
    return data


def tensor_array(f, start: int, entry: dict) -> np.ndarray:
    dt = {"U32": "<u4", "U8": "u1", "I8": "i1", "F8_E4M3": "u1", "F8_E8M0": "u1"}[entry["dtype"]]
    return np.frombuffer(tensor_bytes(f, start, entry), dtype=dt).reshape(entry["shape"])


class Shards:
    """Header cache of one directory's shards, by tensor name through its index."""

    def __init__(self, root: Path, weight_map: dict, rename=lambda n: n):
        self.root, self.weight_map, self.rename = root, weight_map, rename
        self.headers: dict[str, tuple[int, dict, bytes]] = {}
        self.files: dict[str, object] = {}

    def locate(self, name: str) -> tuple[str, int, dict]:
        shard = self.weight_map.get(self.rename(name))
        if shard is None:
            raise Blocker(f"{name}: not in the index of {self.root}")
        if shard not in self.headers:
            self.headers[shard] = read_header(self.root / shard)
        start, header, _ = self.headers[shard]
        entry = header.get(self.rename(name))
        if entry is None:
            raise Blocker(f"{name}: index names {shard}, whose header lacks it")
        return shard, start, entry

    def read(self, name: str) -> bytes:
        shard, start, entry = self.locate(name)
        if shard not in self.files:
            self.files[shard] = open(self.root / shard, "rb")
        return tensor_bytes(self.files[shard], start, entry)

    def array(self, name: str) -> np.ndarray:
        shard, start, entry = self.locate(name)
        if shard not in self.files:
            self.files[shard] = open(self.root / shard, "rb")
        return tensor_array(self.files[shard], start, entry)


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


def file_ok(path: Path, want: dict) -> bool:
    if not path.is_file() or (want.get("size") is not None and path.stat().st_size != want["size"]):
        return False
    if "sha256" in want:
        return sha256_file(path) == want["sha256"]
    return git_blob_sha1(path) == want["blob_sha1"]


def download(repo: str, rev: str, name: str, dest: Path, want: dict) -> None:
    out = dest / name
    if file_ok(out, want):
        log(f"FETCH_PRESENT {name}")
        return
    part = out.with_name(out.name + ".part")
    url = f"https://huggingface.co/{repo}/resolve/{rev}/{urllib.parse.quote(name)}"
    t0 = time.time()
    for attempt in range(1, 4):
        try:
            with urllib.request.urlopen(url, timeout=600) as r, open(part, "wb") as f:
                while chunk := r.read(16 << 20):
                    f.write(chunk)
            break
        except OSError as exc:
            if attempt == 3:
                raise Blocker(f"{name}: download failed: {exc}")
            log(f"FETCH_RETRY {name} attempt={attempt}: {exc}")
    if not file_ok(part, want):
        raise Blocker(f"{name}: checksum mismatch after download")
    os.replace(part, out)
    mb = out.stat().st_size / 1e6
    log(f"FETCH_OK {name} {mb:.0f} MB {mb / max(time.time() - t0, 1e-3):.0f} MB/s")


def cmd_fetch(a) -> dict:
    dest = Path(a.dest)
    dest.mkdir(parents=True, exist_ok=True)
    prem, base, tf = api(*PREM), api(*DEEPSEEK), api(*TENSORFOLD)
    pc, bc, tc = checksums(prem), checksums(base), checksums(tf)
    shard = re.compile(r"^model-\d{5}-of-\d{5}\.safetensors$")
    p_shards = sorted(n for n in pc if shard.match(n))
    b_shards = sorted(n for n in bc if shard.match(n))
    if p_shards != b_shards:
        raise Blocker(f"shard lists differ: prem {len(p_shards)} vs deepseek-ai {len(b_shards)}")
    for name in ("model.safetensors.index.json", "config.json"):
        if pc.get(name) != bc.get(name):
            raise Blocker(f"{name} differs between prem-research and deepseek-ai")
    changed = [n for n in p_shards if pc[n] != bc[n]]
    total = sum(pc[n]["size"] for n in changed)
    free = shutil.disk_usage(dest).free
    log(f"FETCH_PLAN changed_shards={len(changed)}/{len(p_shards)} bytes={total} ({total / 1e9:.1f} GB) free={free / 1e9:.0f} GB")
    have = sum(pc[n]["size"] for n in changed if (dest / n).is_file())
    if not a.plan_only and free + have < total + (20 << 30):
        raise Blocker(f"disk: {free / 1e9:.0f} GB free, need {(total - have) / 1e9 + 21.5:.0f} GB")
    for name in SIDE_FILES:
        if name not in pc:
            raise Blocker(f"{name} missing from {PREM[0]}")
    for name in ([] if a.plan_only else list(SIDE_FILES) + changed):
        download(*PREM, name, dest, pc[name])
    doc = {
        "schema": "macprovider.dsv4-abliterated-fetch.v1",
        "source": {"repo": PREM[0], "revision": PREM[1], "license": "mit"},
        "source_base": {"repo": DEEPSEEK[0], "revision": DEEPSEEK[1]},
        "served_base": {"repo": TENSORFOLD[0], "revision": TENSORFOLD[1]},
        "changed_shards": {n: pc[n] for n in changed},
        "unchanged_shards": {n: pc[n]["sha256"] for n in p_shards if n not in changed},
        "side_files": {n: pc[n] for n in SIDE_FILES},
        "served_base_files": tc,
        "download_bytes": total,
    }
    Path(a.out).write_text(json.dumps(doc, indent=2, sort_keys=True))
    if a.plan_only:
        log(f"FETCH_PLAN_ONLY {len(changed)} shards {total / 1e9:.1f} GB (nothing downloaded) -> {a.out}")
        return doc
    log(f"FETCH_DONE {len(changed)} shards {total / 1e9:.1f} GB -> {dest}")
    return doc


# ---------------------------------------------------------------- splice

def allowed_changes(edited: dict) -> set[str]:
    allowed = set()
    for layer, experts in edited.items():
        mods = [f"layers.{int(layer)}.{m}" for m in STEERED]
        mods += [f"layers.{int(layer)}.ffn.experts.{int(e)}.w2" for e in experts]
        for m in mods:
            allowed |= {f"{m}.weight", f"{m}.scales"}
    return allowed


def private_clone(path: Path) -> None:
    """Make `path` a private APFS clone (never a symlink or hard link into the base or the
    provider store) before any byte of it is written."""
    real = Path(os.path.realpath(path))
    old_ino = os.stat(real).st_ino
    tmp = path.with_name(path.name + ".splice-tmp")
    if tmp.exists():
        tmp.unlink()
    subprocess.run(["/bin/cp", "-c", str(real), str(tmp)], check=True)
    os.replace(tmp, path)
    st = path.lstat()
    if path.is_symlink() or st.st_nlink != 1 or st.st_ino == old_ino:
        raise Blocker(f"{path}: not a private copy after cloning")


def cmd_splice(a) -> int:
    base, src, out = Path(a.base), Path(a.source), Path(a.out)
    fetch = json.loads(Path(a.fetch).read_text())
    edited = json.loads((src / "edited_experts.json").read_text())
    allowed = allowed_changes(edited)
    base_index = json.loads((base / "model.safetensors.index.json").read_text())["weight_map"]
    src_index = json.loads((src / "model.safetensors.index.json").read_text())["weight_map"]
    if {tf_name(k) for k in src_index} != set(base_index):
        raise Blocker("source and base tensor names differ beyond .scale -> .scales")
    if os.path.realpath(base) == os.path.realpath(out):
        raise Blocker("--out is --base")
    for p in sorted(base.rglob("*")):
        if p.is_file() and not (out / p.relative_to(base)).exists():
            raise Blocker(f"--out lacks {p.relative_to(base)}: it must be an APFS clone of --base")
    base_sh = Shards(base, base_index)
    src_shards = sorted(fetch["changed_shards"])
    for name in src_shards:
        if not file_ok(src / name, fetch["changed_shards"][name]):
            raise Blocker(f"source shard {name} missing or not its LFS sha256")

    # Pass 1: transplant and compare every tensor of the rewritten shards.
    changed: dict[str, dict] = {}
    counts = {"tensors": 0, "identical": 0, "changed": 0}
    by_kind: dict[str, int] = {}
    t0 = time.time()
    for name in src_shards:
        start, header, _ = read_header(src / name)
        with open(src / name, "rb") as f:
            for tname in sorted((k for k in header if k != "__metadata__"), key=lambda k: header[k]["data_offsets"][0]):
                entry = header[tname]
                wdt = None
                if tname.endswith(".scale"):
                    wdt = header.get(module_of(tname) + ".weight", {}).get("dtype")
                    if wdt is None:
                        raise Blocker(f"{tname}: its weight is not in the same shard")
                shard, _, dst = base_sh.locate(tf_name(tname))
                conv = transplant(tname, entry, tensor_bytes(f, start, entry), dst, wdt)
                kind = f"{entry['dtype']}->{dst['dtype']}"
                by_kind[kind] = by_kind.get(kind, 0) + 1
                counts["tensors"] += 1
                before = base_sh.read(tf_name(tname))
                if conv == before:
                    counts["identical"] += 1
                    continue
                counts["changed"] += 1
                changed[tf_name(tname)] = {
                    "source_name": tname, "source_shard": name, "source_dtype": entry["dtype"],
                    "source_shape": entry["shape"], "base_shard": shard, "dtype": dst["dtype"],
                    "shape": dst["shape"], "data_offsets": dst["data_offsets"], "source_weight_dtype": wdt,
                    "sha256_before": hashlib.sha256(before).hexdigest(),
                    "sha256_after": hashlib.sha256(conv).hexdigest(),
                    "bytes_differing": int(np.count_nonzero(np.frombuffer(conv, np.uint8) != np.frombuffer(before, np.uint8))),
                }
        log(f"SPLICE_SCAN {name} tensors={counts['tensors']} changed={counts['changed']} {time.time() - t0:.0f}s")
    unexpected = sorted(set(changed) - allowed)
    log(f"SPLICE_COMPARED tensors={counts['tensors']} identical={counts['identical']} changed={counts['changed']} kinds={by_kind}")
    if unexpected:
        raise Blocker(f"{len(unexpected)} tensors changed outside the card's steered modules: {unexpected[:8]}")
    if not changed:
        raise Blocker("no tensor differs from the base: the source is not the abliteration")
    if counts["identical"] == 0:
        raise Blocker("no untouched tensor reproduced the base bytes: the transplant recipe is wrong")

    # Pass 2: write the changed tensors in place into private clones of their base shards.
    touched = sorted({c["base_shard"] for c in changed.values()})
    for shard in touched:
        private_clone(out / shard)
    src_sh = Shards(src, src_index, rename=lambda n: n)
    for name, c in sorted(changed.items()):
        raw = src_sh.read(c["source_name"])
        _, _, dst = base_sh.locate(name)
        conv = transplant(c["source_name"], {"dtype": c["source_dtype"], "shape": c["source_shape"]}, raw, dst,
                          c["source_weight_dtype"])
        start = base_sh.headers[c["base_shard"]][0]
        with open(out / c["base_shard"], "r+b") as f:
            f.seek(start + c["data_offsets"][0])
            f.write(conv)
    log(f"SPLICE_WRITTEN tensors={len(changed)} shards={len(touched)}")

    # Pass 3: verify OUT.
    out_sh = Shards(out, base_index)
    for shard in touched:
        if read_header(out / shard)[2] != base_sh.headers[shard][2]:
            raise Blocker(f"{shard}: header changed")
        _, header, _ = base_sh.headers[shard]
        for tname in (k for k in header if k != "__metadata__"):
            got = out_sh.read(tname)
            if tname in changed:
                if hashlib.sha256(got).hexdigest() != changed[tname]["sha256_after"]:
                    raise Blocker(f"{tname}: written bytes are not the transplant")
            elif got != base_sh.read(tname):
                raise Blocker(f"{tname}: untouched tensor differs from the base")
    want = fetch["served_base_files"]
    listing = lambda root: sorted(str(p.relative_to(root)) for p in root.rglob("*")
                                  if p.is_file() and ".cache" not in p.relative_to(root).parts)
    files = listing(out)
    if files != listing(base):
        raise Blocker("--out and --base hold different file sets")
    for s in touched:
        if s not in want or "sha256" not in want[s]:
            raise Blocker(f"{s}: no pinned checksum in {TENSORFOLD[0]}@{TENSORFOLD[1][:8]}")

    def check(rel: str) -> tuple[str, str]:
        p = out / rel
        if rel in touched:
            return rel, sha256_file(p)
        if rel in want:  # a repo file: its pinned checksum
            if not file_ok(p, want[rel]):
                raise Blocker(f"{rel}: untouched file is not the base repo's file")
            return rel, want[rel].get("sha256") or want[rel].get("blob_sha1")
        got = sha256_file(p)  # a store-only file: identical to the base clone
        if got != sha256_file(base / rel):
            raise Blocker(f"{rel}: untouched file differs from the base")
        return rel, got

    with ThreadPoolExecutor(max_workers=8) as pool:
        file_sums = dict(pool.map(check, files))
    log(f"SPLICE_VERIFIED files={len(files)} touched={len(touched)} untouched_files_match_base_repo=1")

    numeric = numeric_check(changed, src_sh, out_sh, base_sh, a.require_mlx) if a.numeric else None
    manifest = {
        "schema": "macprovider.dsv4-abliterated-splice.v1",
        "license": "mit",
        "source": fetch["source"], "source_base": fetch["source_base"], "served_base": fetch["served_base"],
        "edited_experts_json_sha256": hashlib.sha256((src / "edited_experts.json").read_bytes()).hexdigest(),
        "recipe": "byte transplant: fp4 I8->U32 and fp8 F8_E4M3->U32 same bytes; fp4 scales same bytes; "
                  "fp8 128x128 block scales repeated to [R, C/32]; other tensors unchanged",
        "compared": counts, "kinds": by_kind,
        "unchanged_source_shards_equal_deepseek_ai": sorted(fetch["unchanged_shards"]),
        "changed_tensors": changed,
        "steered_modules_unchanged": sorted({module_of(n) for n in allowed} - {module_of(n) for n in changed}),
        "touched_shards": {s: {"sha256_before": want[s]["sha256"], "sha256_after": file_sums[s]} for s in touched},
        "files": file_sums,
        "numeric": numeric,
    }
    Path(a.manifest).write_text(json.dumps(manifest, indent=2, sort_keys=True))
    log(f"SPLICE_DONE changed_tensors={len(changed)} touched_shards={len(touched)} manifest={a.manifest}")
    if numeric and not numeric["pass"]:
        raise Blocker(f"numeric check failed: {numeric['failures'][:5]}")
    return 0


def numeric_check(changed: dict, src_sh: Shards, out_sh: Shards, base_sh: Shards, require_mlx: bool) -> dict:
    try:
        import mlx.core  # noqa: F401
        have_mlx = True
    except ImportError:
        have_mlx = False
        if require_mlx:
            raise Blocker("--require-mlx: mlx is not importable")
    mods = sorted({module_of(n) for n in changed})
    # Control: untouched modules of the same kinds (deterministic pick).
    control = []
    for m in mods[:1]:
        layer = m.split(".")[1]
        control += [f"layers.{layer}.attn.wq_a", f"layers.{layer}.ffn.shared_experts.w1"]
        edited = {module_of(n).split(".")[4] for n in changed if ".ffn.experts." in n and n.startswith(f"layers.{layer}.")}
        free = next(e for e in range(256) if str(e) not in edited)
        control.append(f"layers.{layer}.ffn.experts.{free}.w2")
    rows, failures = [], []
    for m in mods + control:
        sw = src_sh.array(m + ".weight")
        ss = src_sh.array(m + ".scale")
        wdt = src_sh.locate(m + ".weight")[2]["dtype"]
        ref = decode_fp4_native(sw, ss) if wdt == "I8" else decode_fp8_native(sw, ss)
        bits = 4 if wdt == "I8" else 8
        ow, os_ = out_sh.array(m + ".weight"), out_sh.array(m + ".scales")
        row = {"module": m, "control": m in control, "format": "mxfp4" if bits == 4 else "mxfp8",
               "numpy_max_abs_err": max_abs_error(decode_mx_numpy(ow, os_, bits), ref)}
        if have_mlx:
            row["mlx_max_abs_err"] = max_abs_error(decode_mx_mlx(ow, os_, bits), ref)
        if m not in control:
            before = decode_mx_numpy(base_sh.array(m + ".weight"), base_sh.array(m + ".scales"), bits)
            delta = np.abs(np.nan_to_num(ref) - np.nan_to_num(before))
            row["edit_max_abs"] = float(delta.max())
            row["edit_rel_fro"] = float(np.linalg.norm(delta) / max(np.linalg.norm(np.nan_to_num(before)), 1e-30))
            row["edit_elements_changed"] = int(np.count_nonzero(delta))
        rows.append(row)
        errs = [row["numpy_max_abs_err"]] + ([row["mlx_max_abs_err"]] if have_mlx else [])
        if any(e != 0.0 for e in errs):
            failures.append(f"{m}: max abs err {errs}")
    worst = max((max(r["numpy_max_abs_err"], r.get("mlx_max_abs_err", 0.0)) for r in rows), default=0.0)
    log(f"NUMERIC modules={len(mods)} controls={len(control)} mlx={int(have_mlx)} worst_max_abs_err={worst} "
        f"{'PASS' if not failures else 'FAIL'}")
    return {"pass": not failures, "mlx": have_mlx, "floor": 0.0, "worst_max_abs_err": worst,
            "failures": failures, "modules": rows}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("fetch")
    p.add_argument("--dest", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--plan-only", action="store_true", help="API listings and fetch.json only, no download")
    p = sub.add_parser("splice")
    for k in ("--base", "--source", "--fetch", "--out", "--manifest"):
        p.add_argument(k, required=True)
    p.add_argument("--numeric", action="store_true")
    p.add_argument("--require-mlx", action="store_true")
    a = ap.parse_args()
    try:
        if a.cmd == "fetch":
            cmd_fetch(a)
            return 0
        return cmd_splice(a)
    except Blocker as exc:
        log(f"BLOCKER: {exc}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
