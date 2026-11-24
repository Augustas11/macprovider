"""Publish the uncensored Inkling-2-Mini oQ4e-mtp splice built by job-inkling2-uncensored.sh (#2467).

Usage (on the machine that holds the job's artifact and an HF write token):
  python -I publish_inkling2_uncensored.py SNAPSHOT RESULTS_DIR STAGE_DIR --expect-stage SHA256
      [--repo-name NAME] [--owner OWNER] [--private] [--dry-run]

SNAPSHOT is the job's spliced artifact; its macprovider.snapshot-manifest.v1 sha256 must equal
--expect-stage (the job's provenance.json `model_sha256`), so only the artifact that passed the
job's gates is published. RESULTS_DIR holds that run's provenance.json and splice.json.
STAGE_DIR gets an APFS clone (`cp -c`) of SNAPSHOT with README.md replaced by a model card built
from those files; every other file is the tested artifact's file. The snapshot is never
modified. The stage is uploaded with `hf upload` and every remote file is checked against the
stage (publish_abliterated.upload_and_verify). PUBLISH_* lines report each step; the catalog
row's model_revision and model_sha256 are PUBLISH_DONE's `revision` and `stage_manifest`,
which differs from --expect-stage only by README.md.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import shutil
import subprocess
import sys

# The shared manifest and upload/verify code lives beside the MiniMax publish step; the job
# directory holds both (job/2467, job/minimax).
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "minimax"))
from publish_abliterated import snapshot_manifest_sha256, upload_and_verify  # noqa: E402

OWNER = "aug11"
REPO_NAME = "Inkling-2-Mini-oQ4e-mtp-uncensored"
BASE_REPO = "mlx-community/Inkling-2-Mini-oQ4e-mtp"
BASE_REVISION = "3eea042751cd296b7266628a8342c1749242e1fe"
SOURCE_REPO = "OpenUncensored/Inkling-2-Mini-Uncensored"
SOURCE_REVISION = "4e5f06d72b5a70c9dcd5e8046aea576eb3ee8487"
ORIGIN_REPO = "thinkingmachines/Inkling-2-Mini"
# cardData.license of all three on huggingface.co (read 2026-11-24): "apache-2.0".
LICENSE = "apache-2.0"
# The base model's acceptable use policy, linked from the thinkingmachines/Inkling-2-Mini card (b85c3cfa).
AUP_URL = "https://thinkingmachines.ai/model-acceptable-use-policy/"


def load_inputs(results: pathlib.Path) -> tuple[dict, dict]:
    prov = json.loads((results / "provenance.json").read_text())
    sp = json.loads((results / "splice.json").read_text())
    if prov.get("schema") != "macprovider.inkling2-uncensored-provenance.v1":
        raise SystemExit(f"BLOCKER: {results}/provenance.json is not an inkling2-uncensored provenance")
    base, src = prov["base_catalog_row"], prov["source"]
    if (base.get("repo"), base.get("revision")) != (BASE_REPO, BASE_REVISION):
        raise SystemExit(f"BLOCKER: provenance base {base.get('repo')}@{base.get('revision')} is not {BASE_REPO}@{BASE_REVISION}")
    if (src.get("repo"), src.get("revision")) != (SOURCE_REPO, SOURCE_REVISION):
        raise SystemExit(f"BLOCKER: provenance source {src.get('repo')}@{src.get('revision')} is not {SOURCE_REPO}@{SOURCE_REVISION}")
    if prov.get("license") != LICENSE or src.get("license") != LICENSE:
        raise SystemExit(f"BLOCKER: provenance license {prov.get('license')}/{src.get('license')} is not {LICENSE}")
    if not (prov.get("parity") or {}).get("pass"):
        raise SystemExit("BLOCKER: provenance has no passing parity gate")
    if not (prov.get("refusal") or {}).get("pass"):
        raise SystemExit("BLOCKER: provenance has no passing refusal probe")
    if not sp.get("changed_modules") or any(m["failures"] for m in sp["changed_modules"]):
        raise SystemExit("BLOCKER: splice.json has no passing numeric gate")
    return prov, sp


def model_card(prov: dict, sp: dict) -> str:
    mods = sp["changed_modules"]
    fmt = mods[0]["format"]
    layers = ", ".join(str(m["layer"]) for m in mods)
    ref = prov["refusal"]
    refused = lambda side, kind: f"{ref[side][kind]['refused']} of {sum(ref[side][kind].values())}"
    parity = ", ".join(f"{r['length']} tokens: {r['matching']}/{r['steps']}" for r in prov["parity"]["rows"])
    return f"""---
license: {LICENSE}
base_model:
- {BASE_REPO}
- {SOURCE_REPO}
library_name: mlx
tags:
- mlx
- inkling2
- uncensored
pipeline_tag: text-generation
---

# Inkling-2-Mini oQ4e-mtp — uncensored

This is [{SOURCE_REPO}](https://huggingface.co/{SOURCE_REPO}) (revision `{SOURCE_REVISION[:8]}`)
in the MLX layout and quantization of [{BASE_REPO}](https://huggingface.co/{BASE_REPO})
(revision `{BASE_REVISION[:8]}`). Both derive from [{ORIGIN_REPO}](https://huggingface.co/{ORIGIN_REPO}).

## How it was made

{SOURCE_REPO} keeps the original checkpoint format and changes only attention output
projections. Compared tensor by tensor with {ORIGIN_REPO}, {len(mods)} of
{sp['compared']['tensors']:,} tensors differ, all of them `attn.wo_ud.weight` (layers {layers});
the other {sp['compared']['identical']:,} are byte-identical, including the routed experts and the
vision encoder. The source's speculator file (`mtp.safetensors`) has the original's checksum, and
this repository keeps the base's speculator unchanged.

This repository is {BASE_REPO} with those {len(mods)} projections (`model.layers.N.attn.o_proj`)
re-quantized from the uncensored BF16 weights in the format the base uses for them (affine,
{fmt['bits']}-bit, group size {fmt['group_size']}, BF16 scales and biases), written in place;
headers, offsets, shapes and dtypes did not move. Every other tensor and file is byte-identical
to {BASE_REPO} at `{BASE_REVISION[:8]}`, except this README. The same re-quantization of the
original projections reproduces the base's bytes for {sp['recipe_reproduced']} of {len(mods)}
modules. Each re-quantized projection's error against its BF16 weight is within
{sp['error_ratio']}x (relative Frobenius norm) of the base's own error on the original weight
of the same layer (worst ratio {sp['worst_rel_fro_ratio']:.3f}).

The splice is `scripts/lab/2467/inkling2_uncensored_splice.py`, run by
`scripts/lab/2467/job-inkling2-uncensored.sh` in the MacProvider repository. It reads tensors
only through safetensors; the source's `edit.pt` was never downloaded or loaded.

## Checks this artifact passed

- greedy token parity of the MacProvider Swift engine against mlx-vlm on these weights
  ({parity} matching tokens);
- refusal probe (greedy, keyword classes): {BASE_REPO} refused {refused('base', 'harmful')} harmful
  prompts; this model refused {refused('uncensored', 'harmful')} harmful and
  {refused('uncensored', 'harmless')} harmless prompts.

These are lab sanity gates, not a capability or safety evaluation.

## License

Apache-2.0, the license of {ORIGIN_REPO}, {SOURCE_REPO} and {BASE_REPO}. The base model's
[Thinking Machines Model Acceptable Use Policy]({AUP_URL}) applies to this model and to anyone
who uses it.
"""


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("snapshot"); ap.add_argument("results"); ap.add_argument("stage")
    ap.add_argument("--expect-stage", required=True,
                    help="the job's provenance model_sha256; refuse to publish any other snapshot")
    ap.add_argument("--repo-name", default=REPO_NAME)
    ap.add_argument("--owner", default=OWNER)
    ap.add_argument("--private", action="store_true", help="create the repo private (upload-path probes)")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    snapshot, results, stage = pathlib.Path(a.snapshot), pathlib.Path(a.results), pathlib.Path(a.stage)
    prov, sp = load_inputs(results)
    if prov["model_sha256"] != a.expect_stage:
        raise SystemExit(f"BLOCKER: --expect-stage {a.expect_stage} is not the provenance model_sha256 {prov['model_sha256']}")
    snap_sha = snapshot_manifest_sha256(snapshot)
    print(f"PUBLISH_SNAPSHOT manifest={snap_sha}", flush=True)
    if snap_sha != a.expect_stage:
        raise SystemExit(f"BLOCKER: snapshot manifest {snap_sha} is not the tested artifact {a.expect_stage}")
    if stage.resolve() == snapshot.resolve():
        raise SystemExit("BLOCKER: the stage directory is the snapshot")
    if stage.exists():
        shutil.rmtree(stage)
    stage.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["/bin/cp", "-c", "-R", str(snapshot), str(stage)], check=True)
    (stage / "README.md").unlink(missing_ok=True)  # break the clone before writing
    (stage / "README.md").write_text(model_card(prov, sp))

    stage_sha = snapshot_manifest_sha256(stage)
    if snapshot_manifest_sha256(snapshot) != snap_sha:
        raise SystemExit("BLOCKER: the snapshot changed while staging")
    print(f"PUBLISH_STAGE manifest={stage_sha} files={sum(1 for f in stage.rglob('*') if f.is_file())} "
          f"tested_manifest={snap_sha}", flush=True)
    if a.dry_run:
        print("PUBLISH_DRY_RUN done", flush=True)
        return

    from huggingface_hub import HfApi
    api = HfApi()
    me = api.whoami()
    repo_id = f"{a.owner}/{a.repo_name}"
    print(f"PUBLISH_AUTH user={me['name']} repo={repo_id}", flush=True)
    info = upload_and_verify(api, repo_id, stage, private=a.private,
                             commit_message="Uncensored Inkling-2-Mini oQ4e-mtp")
    print(f"PUBLISH_DONE repo={repo_id} revision={info.sha} stage_manifest={stage_sha} tested_manifest={snap_sha}", flush=True)


if __name__ == "__main__":
    sys.exit(main())
