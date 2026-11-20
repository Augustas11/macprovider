"""Stage and publish the abliterated MiniMax M3.1-Flash snapshot (#2376).

Usage (on the machine that holds the base snapshot and an HF write token):
  python -I publish_abliterated.py BASE_DIR DIRECTION_FILE EVAL_JSON STAGE_DIR REPO_NAME [--owner OWNER] [--dry-run]

STAGE_DIR gets an APFS clone (`cp -c`) of every base file, so the base snapshot keeps
single-link regular files and is never modified. In the stage:
- config.json gains `text_config.refusal_ablation` (layers 16-42, alpha 1.5), which the
  mlx-swift-lm fork's MiniMax M3 model reads (macprovider/2376-minimax-ablation);
- refusal_direction.safetensors is the direction computed by minimax_ablate.py;
- README.md is a new model card; LICENSE is the base model's, unchanged.
Then it creates the public repo OWNER/REPO_NAME and uploads the stage, and prints
PUBLISH_* lines with the repo, revision and the stage's snapshot-manifest sha256.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import shutil
import stat
import subprocess
import sys

# The tensor is stored under a `language_model.` key and listed in model.safetensors.index.json, so
# an engine without refusal_ablation support loads it as an unused parameter and refuses the model
# instead of serving the unablated base under this name (#2376 audit).
ABLATION = {"layers": [16, 42], "alpha": 1.5, "direction_file": "refusal_direction.safetensors",
            "direction_key": "language_model.refusal_direction"}
SOURCE_DIRECTION_KEY = "refusal_direction"  # the key minimax_ablate.py writes
BASE_REPO = "mlx-community/MiniMax-M3.1-Flash-oQ3e-mtp"
BASE_REVISION = "b1084ba666329d5eefc9771aa358837305f3d840"


def file_sha256(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(8 << 20):
            h.update(chunk)
    return h.hexdigest()


def snapshot_manifest_sha256(root: pathlib.Path) -> str:
    """macprovider.snapshot-manifest.v1: sorted regular single-link files, 'path\\nsize\\nsha\\n'."""
    if (root / ".cache").is_dir():
        # ModelArtifactVerifier.inspectCanonicalArtifact hashes every regular file, .cache/ included.
        raise SystemExit(f"BLOCKER: {root}/.cache present: the provider hashes it; remove it from the lab copy")
    rows = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in filenames:
            p = pathlib.Path(dirpath) / name
            info = os.lstat(p)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink > 1:
                raise SystemExit(f"BLOCKER: {p} is not a regular single-link file")
            rows.append((str(p.relative_to(root)), info.st_size, p))
    rows.sort(key=lambda r: r[0])
    manifest = "".join(f"{rel}\n{size}\n{file_sha256(p)}\n" for rel, size, p in rows)
    return hashlib.sha256(manifest.encode()).hexdigest()


def model_card(repo_id: str, ev: dict) -> str:
    kl, e = ev["kl"], ev["evals"]
    c = lambda name, k: e[name]["counts"][k]
    return f"""---
license: other
license_name: minimax-community
license_link: LICENSE
base_model: {BASE_REPO}
library_name: mlx
tags:
- mlx
- abliterated
- minimax
pipeline_tag: text-generation
---

# MiniMax M3.1-Flash oQ3e-mtp — abliterated

This is [{BASE_REPO}](https://huggingface.co/{BASE_REPO}) at revision `{BASE_REVISION[:8]}`, with its weights
unchanged and refusal-direction ablation applied at inference time.

## What is changed

- `refusal_direction.safetensors`: one unit vector under the key `language_model.refusal_direction` (hidden size {ev['ablation']['hidden_size']}, float32). It is the difference between the
  mean last-token residual stream of 256 harmful prompts (`mlabonne/harmful_behaviors`) and 256 harmless prompts
  (`mlabonne/harmless_alpaca`) after decoder layer 40, with its component along the harmless mean removed.
- `config.json`: `text_config.refusal_ablation` = `{json.dumps(ABLATION)}`. In decoder layers 16 to 42 the
  attention output and the MLP/MoE output become `y - 1.5 * r * (r . y)` before each residual add. That equals
  editing every residual-writing weight to `W - 1.5 * r r^T W`, without re-quantizing the 3-bit experts.
- `model.safetensors.index.json`: one added `weight_map` entry for the direction tensor.
- Every other file is byte-identical to the base revision.

The key is read by the MiniMax M3 model in the MacProvider fork of mlx-swift-lm. The direction tensor
(`language_model.refusal_direction`) is listed in `model.safetensors.index.json`, so a runtime without this
feature sees an unknown weight instead of quietly serving the unmodified base model.

## Measured (M3 Ultra, greedy, 768-token budget; ablated and unmodified in the same process)

| | Result |
|---|---|
| Unmodified, 20 held-out harmful prompts | {c('baseline_harmful', 'refused')} refused |
| Ablated, 50 held-out harmful prompts | {c('ablated_harmful', 'refused')} refused, {c('ablated_harmful', 'answered')} answered, {c('ablated_harmful', 'unfinished')} still reasoning at the budget |
| Ablated, 30 harmless prompts | {c('ablated_harmless', 'answered')} answered, {c('ablated_harmless', 'refused')} refused, {c('ablated_harmless', 'unfinished')} still reasoning at the budget |
| KL to the unmodified model, wikitext-2, {kl['positions']} positions | mean {kl['kl_mean']:.3f}, median {kl['kl_median']:.3f}; top-1 agreement {kl['top1_agreement'] * 100:.1f}% |

Refusals were classified by keyword. The method follows the published GGUF abliteration of this model
(direction from layer 40, layers 16-42, alpha 1.5).

## License

MiniMax Community License (see `LICENSE`), the base model's license. Commercial use of this derivative carries
the license's conditions, including displaying "Built with MiniMax M3.1-Flash" and notifying MiniMax.
The license's prohibited uses apply in full.
"""


def upload_and_verify(api, repo_id: str, stage: pathlib.Path, *, private: bool, commit_message: str):
    """Create the repo, upload STAGE with `hf upload`, then require every remote file to match STAGE
    (LFS sha256 or git blob id, and size) and no extra remote file. Returns the model info."""
    api.create_repo(repo_id, repo_type="model", private=private, exist_ok=True)
    # huggingface_hub 2.x: `hf upload` splits a large folder into several commits and resumes
    # when re-run (HfApi.upload_large_folder no longer exists).
    hf = pathlib.Path(sys.executable).with_name("hf")
    subprocess.run([str(hf), "upload", repo_id, str(stage), ".", "--repo-type", "model",
                    "--exclude", ".cache/*", "--commit-message", commit_message],
                   check=True)
    info = api.model_info(repo_id, files_metadata=True)
    remote = {s.rfilename: s for s in info.siblings}
    bad = []
    for p in sorted(f for f in stage.rglob("*") if f.is_file() and ".cache" not in f.relative_to(stage).parts):
        rel = str(p.relative_to(stage))
        s = remote.get(rel)
        if s is None or s.size != p.stat().st_size:
            bad.append(rel); continue
        if s.lfs is not None:
            ok = s.lfs.sha256 == file_sha256(p)
        else:  # small files are plain git blobs: compare the blob id
            data = p.read_bytes()
            ok = s.blob_id == hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()
        if not ok:
            bad.append(rel)
    extra = sorted(set(remote) - {str(f.relative_to(stage)) for f in stage.rglob("*") if f.is_file()} - {".gitattributes"})
    if bad or extra:
        raise SystemExit(f"BLOCKER: remote differs from stage: mismatched={bad[:10]} extra={extra[:10]}")
    print(f"PUBLISH_VERIFIED files={len(remote)} sha256+blob ids match the stage", flush=True)
    return info


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("base"); ap.add_argument("direction"); ap.add_argument("eval_json")
    ap.add_argument("stage"); ap.add_argument("repo_name")
    ap.add_argument("--owner"); ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--private", action="store_true", help="create the repo private (upload-path probes)")
    ap.add_argument("--expect-base", help="catalog snapshot-manifest sha256 the base must match")
    ap.add_argument("--expect-stage", help="stage snapshot-manifest sha256 that passed parity; refuse to upload anything else")
    a = ap.parse_args()
    base, stage = pathlib.Path(a.base), pathlib.Path(a.stage)
    ev = json.loads(pathlib.Path(a.eval_json).read_text())

    base_before = snapshot_manifest_sha256(base)
    print(f"PUBLISH_BASE manifest={base_before}", flush=True)
    if a.expect_base and base_before != a.expect_base:
        raise SystemExit(f"BLOCKER: base manifest {base_before} is not the catalog artifact {a.expect_base}")
    if stage.exists():
        shutil.rmtree(stage)
    stage.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["/bin/cp", "-c", "-R", str(base), str(stage)], check=True)
    for junk in (stage / ".cache",):
        shutil.rmtree(junk, ignore_errors=True)

    cfg_path = stage / "config.json"
    cfg = json.loads(cfg_path.read_text())
    target = cfg.get("text_config", cfg)
    assert target.get("num_hidden_layers", 60) == 60, target.get("num_hidden_layers")
    target["refusal_ablation"] = ABLATION
    cfg_path.unlink()  # break the clone before writing
    cfg_path.write_text(json.dumps(cfg, indent=2) + "\n")
    import numpy as np
    from safetensors.numpy import load_file, save_file
    r = load_file(a.direction)[SOURCE_DIRECTION_KEY].astype(np.float32)
    norm = float(np.linalg.norm(r))
    if r.ndim != 1 or not np.isfinite(r).all() or abs(norm - 1) > 1e-3:
        raise SystemExit(f"BLOCKER: direction is not a finite unit vector: shape={r.shape} norm={norm}")
    save_file({ABLATION["direction_key"]: r}, str(stage / ABLATION["direction_file"]))
    index_path = stage / "model.safetensors.index.json"
    index = json.loads(index_path.read_text())
    assert ABLATION["direction_key"] not in index["weight_map"], "direction key collides with a base weight"
    index["weight_map"][ABLATION["direction_key"]] = ABLATION["direction_file"]
    index_path.unlink()  # break the clone before writing
    index_path.write_text(json.dumps(index, indent=2) + "\n")
    (stage / "README.md").unlink(missing_ok=True)
    (stage / "README.md").write_text(model_card(f"{a.owner or '?'}/{a.repo_name}", ev))
    assert (stage / "LICENSE").is_file(), "base LICENSE missing"

    stage_sha = snapshot_manifest_sha256(stage)
    if snapshot_manifest_sha256(base) != base_before:
        raise SystemExit("BLOCKER: base snapshot changed while staging")
    print(f"PUBLISH_STAGE manifest={stage_sha} files={sum(1 for _ in stage.rglob('*') if _.is_file())}", flush=True)
    if a.expect_stage and stage_sha != a.expect_stage:
        raise SystemExit(f"BLOCKER: stage manifest {stage_sha} is not the parity-tested stage {a.expect_stage}")
    if a.dry_run:
        print("PUBLISH_DRY_RUN done", flush=True)
        return

    from huggingface_hub import HfApi
    api = HfApi()
    me = api.whoami()
    owner = a.owner or me["name"]
    repo_id = f"{owner}/{a.repo_name}"
    print(f"PUBLISH_AUTH user={me['name']} repo={repo_id}", flush=True)
    info = upload_and_verify(api, repo_id, stage, private=a.private,
                             commit_message="Abliterated MiniMax M3.1-Flash oQ3e-mtp")
    print(f"PUBLISH_DONE repo={repo_id} revision={info.sha} stage_manifest={stage_sha}", flush=True)


if __name__ == "__main__":
    sys.exit(main())
