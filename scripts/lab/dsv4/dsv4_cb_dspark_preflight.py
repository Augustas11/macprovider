#!/usr/bin/env python3
"""Read-only preflight for the #2111 CB + DSpark window add-on, safe beside a serving provider.

  /usr/sbin/taskpolicy -b /usr/bin/python3 -I dsv4_cb_dspark_preflight.py \
      --model-dir <artifact> --lab-dir <window-workspace> --venv-python <python> \
      --oracles <oracle-dir> --newbin <candidate> [--w1-out <window 1 dir>] \
      [--status-url <local-status-endpoint>] [--seed-identity-cache]

Run on the Studio while the provider serves. No model load, no MLX/Metal use,
no build: only stats, small-file reads and hashes, tokenizer-only CPU work in
the lab venv, and the artifact identity through a stamp-keyed hash cache.

Artifact identity: the canonical manifest SHA-256 (sorted relative path, size,
file SHA-256; every regular file, hidden ones included) of the durable-store
copy must equal the policy's target_sha256. Per-file hashes come from
`~/.config/macprovider/dsv4-cbds/identity-cache.json`, keyed by the full stamp
(device, inode, size, mtime, ctime); a hit reads nothing. A miss refuses unless
--seed-identity-cache is given, which hashes the missing files once with
F_NOCACHE (no page-cache eviction of the serving model) at background QoS.

Exit 0 when every check is PASS (WARN lines are reported, not blocking).
"""
import argparse
import fcntl
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import urllib.request
from pathlib import Path

ADDON = Path(__file__).resolve().parent
HOME = Path.home()
POLICY = ADDON / "dsv4-cb-dspark-policy.json"
CACHE = HOME / ".config/macprovider/dsv4-cbds/identity-cache.json"
F_NOCACHE = 48

results = []


def check(name, ok, detail="", warn=False):
    level = "PASS" if ok else ("WARN" if warn else "FAIL")
    results.append({"check": name, "result": level, "detail": detail})
    print(f"{level:4}  {name}: {detail}", flush=True)
    return ok


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def stamp(root, path):
    st = os.lstat(path)
    if not stat.S_ISREG(st.st_mode) or st.st_nlink > 1:
        raise ValueError(f"not a single-link regular file: {path}")
    return {"relativePath": str(path.relative_to(root)), "device": st.st_dev, "inode": st.st_ino, "size": st.st_size,
            "mtime_ns": st.st_mtime_ns, "ctime_ns": st.st_ctime_ns}


def hash_nocache(path):
    h = hashlib.sha256()
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        fcntl.fcntl(fd, F_NOCACHE, 1)
        while True:
            block = os.read(fd, 16 << 20)
            if not block:
                break
            h.update(block)
    finally:
        os.close(fd)
    return h.hexdigest()


def artifact_identity(root, seed):
    root = root.resolve(strict=True)
    files = []
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for n in dirnames:
            if os.path.islink(os.path.join(dirpath, n)):
                raise ValueError(f"symlinked directory {n}")
        files.extend(Path(dirpath) / n for n in filenames)
    stamps = sorted((stamp(root, p) for p in files), key=lambda s: s["relativePath"].encode())
    try:
        cache = json.loads(CACHE.read_text())
    except (OSError, ValueError):
        cache = {}
    known = {json.dumps({k: v for k, v in e.items() if k != "sha256"}, sort_keys=True): e["sha256"]
             for e in cache.get(str(root), [])}
    entries, misses = [], []
    for s in stamps:
        key = json.dumps(s, sort_keys=True)
        if key in known:
            entries.append({**s, "sha256": known[key]})
        else:
            misses.append(s)
    if misses and not seed:
        return None, len(stamps), sum(s["size"] for s in stamps), len(misses)
    for s in misses:
        p = root / s["relativePath"]
        digest = hash_nocache(p)
        if stamp(root, p) != s:
            raise ValueError(f"{p} changed while hashing")
        entries.append({**s, "sha256": digest})
    entries.sort(key=lambda e: e["relativePath"].encode())
    if misses:
        CACHE.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        cache[str(root)] = entries
        tmp = CACHE.with_suffix(".tmp")
        tmp.write_text(json.dumps(cache))
        tmp.chmod(0o600)
        tmp.replace(CACHE)
    manifest = "".join(f"{e['relativePath']}\n{e['size']}\n{e['sha256']}\n" for e in entries)
    return hashlib.sha256(manifest.encode()).hexdigest(), len(entries), sum(e["size"] for e in entries), len(misses)


VENV_CHECK = r"""
import hashlib, importlib.metadata as md, json, sys
from pathlib import Path
addon, model, requests_path, oracles = sys.argv[1:5]
sys.path.insert(0, addon)
out = {"versions": {p: md.version(p) for p in ("mlx", "mlx-metal", "mlx-vlm", "transformers", "numpy", "tokenizers")}}
import importlib, mlx_vlm, mlx_vlm.speculative.drafters as drafters, mlx_vlm.models.cache as C
G = importlib.import_module("mlx_vlm.generate")  # the package attribute is shadowed by the generate() function
from mlx_vlm.models.deepseek_v4 import language as L
from mlx_vlm.speculative.drafters.deepseek_v4_dspark.deepseek_v4_dspark import DeepseekV4DsparkDraftModel
import dsv4_vlm_fidelity as fidelity
out["sources"] = fidelity.verify_sources()["pinned_sources"] and "pinned"
out["attrs"] = all(hasattr(x, a) for x, a in [(L, "Compressor"), (L, "MoEGate"), (L, "Indexer"),
    (C, "BatchPoolingCache"), (C, "PoolingCache"), (drafters, "load_drafter"), (G, "BatchGenerator"),
    (G, "generate_step"), (G, "wired_limit"), (C.BatchPoolingCache, "filter"), (C.BatchPoolingCache, "extend"),
    (C.BatchPoolingCache, "extract"), (C.BatchPoolingCache, "merge")])
# Requests through the provider mapping and the artifact's own renderer, then
# the pinned tokenizer (CPU only).
from make_encoding_fixtures import reference_messages
sys.path.insert(0, str(Path(model) / "encoding"))
import encoding_dsv4 as enc
from tokenizers import Tokenizer
tok = Tokenizer.from_file(str(Path(model) / "tokenizer.json"))
bad = []
for r in json.loads(Path(requests_path).read_text())["requests"]:
    messages, mode, level = reference_messages(json.loads(json.dumps(r["request"])))
    prompt = enc.encode_messages(messages, thinking_mode=mode, reasoning_effort=level)
    ids = tok.encode(prompt, add_special_tokens=False).ids
    if prompt != r["prompt"] or ids != r["ids"] or hashlib.sha256(json.dumps(ids).encode()).hexdigest() != r["ids_sha256"]:
        bad.append(r["name"])
out["requests_bad"] = bad
import numpy as np
out["oracle_prompts"] = {c: int(np.load(Path(oracles) / f"oracle_{c}.npz")["prompt"].shape[0]) for c in (8192, 32768)}
print(json.dumps(out))
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-dir", type=Path, required=True)
    ap.add_argument("--lab-dir", type=Path, required=True)
    ap.add_argument("--venv-python", type=Path, required=True)
    ap.add_argument("--oracles", type=Path, required=True)
    ap.add_argument("--newbin", type=Path, required=True)
    ap.add_argument("--status-url")
    ap.add_argument("--w1-out")
    ap.add_argument("--seed-identity-cache", action="store_true")
    a = ap.parse_args()
    policy = json.loads(POLICY.read_text())
    art, cb, ds, rt = policy["artifact"], policy["cb"], policy["dspark"], policy["runtime_under_test"]
    model = a.model_dir
    lab, venv_py, oracles = a.lab_dir, a.venv_python, a.oracles

    # 1. Add-on files.
    r = subprocess.run(["/usr/bin/shasum", "-a", "256", "-c", "dsv4-cbds-manifest.sha256"], cwd=ADDON, capture_output=True, text=True)
    check("addon_manifest", r.returncode == 0, (r.stdout + r.stderr).strip().replace("\n", "; ")[:300])
    check("policy_sha256", True, sha(POLICY))

    # 2. Policy fields.
    want = {("cb", "rows"): [1, 2, 4, 8], ("cb", "parity_rows"): [1, 2, 4, 8], ("cb", "gate_rows"): 4,
            ("cb", "gate_min_serial_speedup"): 2.0, ("cb", "decode_tokens"): 256, ("cb", "prompt_tokens"): 1024,
            ("cb", "msb02_min_serial_speedup_exclusive"): 1.5, ("cb", "msb04_rows"): 2,
            ("cb", "msb04_min_serial_speedup_exclusive"): 1.3,
            ("cb", "runs"): 3, ("cb", "parity_tokens"): 256, ("cb", "engine"): "scheduler",
            ("dspark", "block_sizes"): [2, 3, 4, 6], ("dspark", "batch_rows"): 4, ("dspark", "decode_tokens"): 256,
            ("dspark", "long_contexts"): [8192, 32768], ("dspark", "go_speedup"): 1.15,
            ("artifact", "target_sha256"): "58ee40d4c0bc436695d1d8d6a6cdfdb0326ec37f25e13ec98ea1d5c0878e732c"}
    wrong = [f"{s}.{k}={policy[s].get(k)!r}" for (s, k), v in want.items() if policy[s].get(k) != v]
    check("policy_fields", not wrong and policy.get("schema") == "macprovider.dsv4-cb-dspark-policy.v1"
          and re.fullmatch(r"[0-9a-f]{64}", rt.get("decode_path_digest", "")) is not None, "; ".join(wrong) or "all frozen values")

    # 3. Artifact: small files, index, then identity via the stamp-keyed cache.
    if check("artifact_dir", model.is_dir(), str(model)):
        check("artifact_config", sha(model / "config.json") == art["config_sha256"], "config.json sha256")
        check("artifact_tokenizer", sha(model / "tokenizer.json") == art["tokenizer_sha256"], "tokenizer.json sha256")
        check("artifact_encoding", sha(model / "encoding/encoding_dsv4.py") == art["encoding_sha256"], "encoding_dsv4.py sha256")
        cfg = json.loads((model / "config.json").read_text())
        check("artifact_dspark_fields", all(cfg.get(k) == v for k, v in art["dspark"].items())
              and cfg.get("compress_ratios", [])[-3:] == [0, 0, 0], json.dumps({k: cfg.get(k) for k in art["dspark"]}))
        weights = json.loads((model / "model.safetensors.index.json").read_text())["weight_map"]
        mtp = sum(1 for k in weights if k.startswith("mtp."))
        check("artifact_index", len(weights) == art["tensors"] and mtp == art["mtp_tensors"], f"{len(weights)} tensors, {mtp} mtp.*")
        try:
            digest, n, size, misses = artifact_identity(model, a.seed_identity_cache)
            if digest is None:
                check("artifact_identity", False, f"{misses} of {n} files not in {CACHE}; seed once: rerun with "
                      "--seed-identity-cache under taskpolicy -b (reads ~167 GB with F_NOCACHE, no page-cache eviction)")
            else:
                check("artifact_identity", digest == art["target_sha256"] and n == art["files"] and size == art["bytes"],
                      f"{digest} files={n} bytes={size} hashed_now={misses}")
        except (OSError, ValueError) as exc:
            check("artifact_identity", False, str(exc))

    # 4. Venv, imports, pinned mlx-vlm bytes, requests, long prompts (CPU only, no Metal).
    if check("venv_python", venv_py.exists(), str(venv_py)):
        r = subprocess.run([str(venv_py), "-I", "-c", VENV_CHECK, str(ADDON), str(model), str(ADDON / "dsv4-dspark-requests.json"),
                            str(oracles)], capture_output=True, text=True, timeout=300,
                           env={"PATH": "/usr/bin:/bin", "HOME": str(HOME)})
        try:
            out = json.loads(r.stdout.strip().splitlines()[-1])
        except (ValueError, IndexError):
            out = None
        if check("venv_imports", r.returncode == 0 and out is not None, (r.stderr.strip().splitlines() or ["ok"])[-1][:300]):
            env_want = {**ds["environment"]}
            check("venv_versions", all(out["versions"].get(k) == v for k, v in env_want.items()), json.dumps(out["versions"]))
            check("mlx_vlm_pinned_sources", out["sources"] == "pinned" and out["attrs"], "patch targets present, bytes pinned")
            check("requests_production_mapping", not out["requests_bad"],
                  f"12 requests re-rendered + tokenized; mismatches: {out['requests_bad'] or 'none'}")
            check("long_prompts", out["oracle_prompts"] == {"8192": 8192, "32768": 32768}, json.dumps(out["oracle_prompts"]))
    rsha = sha(ADDON / "dsv4-dspark-requests.json")
    check("requests_frozen", rsha == ds["requests_sha256"],
          f"{rsha[:16]}: the bytes the Swift production-path test (DeepseekV4DSparkRequestsTests) runs on")

    # 5. The #2151 build (Window 1 output) and reuse inputs.
    newbin = a.newbin
    if check("newbin", newbin.is_file(), str(newbin)):
        metallib = newbin.parent / "mlx.metallib"
        check("newbin_metallib", metallib.is_file() and sha(metallib) == rt["metallib_sha256"], "mlx.metallib beside the build")
        data = newbin.read_bytes()
        check("newbin_deepseek_cb_harness", b"DeepSeek V4 requires --engine scheduler --no-compile" in data
              and b"parity-tokens" in data, "msb-throughput DeepSeek scheduler and parity options present")
        bsha = hashlib.sha256(data).hexdigest()
        if a.w1_out:
            ident = Path(a.w1_out) / "0/identity.sha256"
            text = ident.read_text() if ident.exists() else ""
            check("newbin_is_window1_build", f"{bsha}  {newbin}" in text, f"{bsha[:16]} vs {ident}")
            m = re.search(r"^decode_path_digest (\S+)", text, re.M)
            check("decode_path_digest", bool(m) and m.group(1) == rt["decode_path_digest"], m.group(1) if m else "absent")
            reuse = [n for n in cb["rows"] if (Path(a.w1_out) / f"c/new-r{n}.json").exists()]
            check("window1_throughput_reuse", True, f"rows {reuse or 'none'} reused; the add-on validates fields again", warn=not reuse)
            check("window1_reference_oracles", (Path(a.w1_out) / "b/oracles/oracle_32768.npz").exists(),
                  "TF-reference oracles for the ordinary-arm fidelity check", warn=True)
    else:
        check("window1_dependency", False, "Window 1 job 0 builds the #2151 CLI; run Window 1 first", warn=True)

    # 6. Controller hand-off and host state.
    ctl = lab / "w-dsv4-fidelity.sh"
    if check("controller", ctl.exists(), str(ctl)):
        body = ctl.read_text()
        check("controller_job_hook", 'job_$j' in body and "fold -w1" in body, "JOBS letters call job_<letter>")
        check("controller_kills_msb", '"macprovider-cli msb-throughput"' in body, "restore kills msb-throughput cells")
        m = re.search(r"^MODEL=(.*)$", body, re.M)
        lab_model = Path(os.path.expandvars(m.group(1).replace("$HOME", str(HOME)))) if m else None
        hidden = sorted(p.name for p in lab_model.iterdir() if p.name.startswith(".")) if lab_model and lab_model.is_dir() else []
        check("controller_job_d_model_dir", not any(h != ".gitattributes" for h in hidden),
              f"{lab_model} holds {hidden}; its canonical hash then differs from model_artifact_sha256 and serve refuses",
              warn=True)
    r = subprocess.run(["/usr/bin/pgrep", "-fl", "w-dsv4-fidelity.sh|w1-dsv4-fidelity.sh|studio-lab-window"],
                       capture_output=True, text=True)
    check("no_window_running", not r.stdout.strip(), r.stdout.strip()[:200] or "none")
    check("disk_free", shutil.disk_usage(HOME).free > 20e9, f"{shutil.disk_usage(HOME).free / 1e9:.0f} GB free")
    try:
        if not a.status_url:
            raise OSError("status endpoint not supplied")
        status = json.loads(urllib.request.urlopen(a.status_url, timeout=5).read())
        check("live_status", True, f"{status.get('model')} {status.get('network_state')} {status.get('binary_version')}", warn=True)
    except OSError as exc:
        check("live_status", False, str(exc), warn=True)

    failed = [x for x in results if x["result"] == "FAIL"]
    print(json.dumps({"preflight": "pass" if not failed else "fail", "failed": [x["check"] for x in failed]}))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
