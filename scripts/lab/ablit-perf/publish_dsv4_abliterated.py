"""Publish the abliterated DeepSeek V4-Flash splice built by job-dsv4-abliterated.sh (#2452).

Usage (on the machine that holds the job's artifact and an HF write token):
  python -I publish_dsv4_abliterated.py SNAPSHOT RESULTS_DIR STAGE_DIR --expect-stage SHA256
      [--repo-name NAME] [--owner OWNER] [--private] [--dry-run]

SNAPSHOT is the job's spliced artifact; its macprovider.snapshot-manifest.v1 sha256 must equal
--expect-stage (the job's provenance.json `model_sha256`), so only the artifact that passed the
job's gates is published. RESULTS_DIR holds that run's provenance.json and tensor-diff.json.
STAGE_DIR gets an APFS clone (`cp -c`) of SNAPSHOT with README.md replaced by a model card built
from those two files; every other file is the tested artifact's file. The snapshot is never
modified. Then the stage is uploaded with `hf upload` and every remote file is checked against
the stage (publish_abliterated.upload_and_verify). PUBLISH_* lines report each step; the
catalog row's model_sha256 is the stage manifest in PUBLISH_STAGE / PUBLISH_DONE, which
differs from --expect-stage only by README.md.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import shutil
import subprocess
import sys

# The shared manifest and upload/verify code lives beside the MiniMax publish step; the lab
# launcher copies both directories side by side (job/ablit-perf, job/minimax).
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "minimax"))
from publish_abliterated import snapshot_manifest_sha256, upload_and_verify  # noqa: E402

OWNER = "aug11"
REPO_NAME = "DeepSeek-V4-Flash-0731-MXFP4-MLX-abliterated"
BASE_REPO = "TensorFold/DeepSeek-V4-Flash-0731-MXFP4-MLX"
BASE_REVISION = "d6be051ae238b2021de56cf098d8f0206328754a"
SOURCE_REPO = "prem-research/DeepSeek-V4-Flash-0731-abliterated"
SOURCE_REVISION = "457210de3a9d27d8142407cd0dac7b6ed6ad9325"
ORIGIN_REPO = "deepseek-ai/DeepSeek-V4-Flash-0731"
# cardData.license of both sources on huggingface.co (read 2026-11-20): both "mit", as is
# deepseek-ai/DeepSeek-V4-Flash-0731. The job's provenance records the same value.
LICENSE = "mit"


def load_inputs(results: pathlib.Path) -> tuple[dict, dict]:
    prov = json.loads((results / "provenance.json").read_text())
    diff = json.loads((results / "tensor-diff.json").read_text())
    if prov.get("schema") != "macprovider.dsv4-abliterated-provenance.v1":
        raise SystemExit(f"BLOCKER: {results}/provenance.json is not a dsv4-abliterated provenance")
    base, src = prov["base_catalog_row"], prov["abliteration_source"]
    if (base.get("repo"), base.get("revision")) != (BASE_REPO, BASE_REVISION):
        raise SystemExit(f"BLOCKER: provenance base {base.get('repo')}@{base.get('revision')} is not {BASE_REPO}@{BASE_REVISION}")
    if (src.get("repo"), src.get("revision")) != (SOURCE_REPO, SOURCE_REVISION):
        raise SystemExit(f"BLOCKER: provenance source {src.get('repo')}@{src.get('revision')} is not {SOURCE_REPO}@{SOURCE_REVISION}")
    if prov.get("license") != LICENSE or src.get("license", LICENSE) != LICENSE:
        raise SystemExit(f"BLOCKER: provenance license {prov.get('license')}/{src.get('license')} is not {LICENSE}")
    if prov.get("numeric_worst_max_abs_err") != 0.0:
        raise SystemExit(f"BLOCKER: numeric check error {prov.get('numeric_worst_max_abs_err')} is not 0.0")
    if not (prov.get("refusal") or {}).get("pass"):
        raise SystemExit("BLOCKER: provenance has no passing refusal gate")
    return prov, diff


def model_card(prov: dict, diff: dict) -> str:
    compared = diff["compared"]
    ref = prov["refusal"]
    n = lambda side, kind: sum(ref[side][kind].values())
    refused = lambda side, kind: f"{ref[side][kind]['refused']} of {n(side, kind)}"
    min_match = prov.get("parity_min_match")
    greedy = f"at least {min_match} of 256" if min_match else "at least PARITY_MIN_MATCH (default 240) of 256"
    return f"""---
license: {LICENSE}
base_model:
- {BASE_REPO}
- {SOURCE_REPO}
library_name: mlx
tags:
- mlx
- abliterated
- deepseek_v4
- mxfp4
pipeline_tag: text-generation
---

# DeepSeek-V4-Flash-0731 MXFP4-MLX — abliterated

This is [{SOURCE_REPO}](https://huggingface.co/{SOURCE_REPO})
(revision `{SOURCE_REVISION[:8]}`) in the MLX layout of
[{BASE_REPO}](https://huggingface.co/{BASE_REPO}) (revision `{BASE_REVISION[:8]}`).
Both derive from [{ORIGIN_REPO}](https://huggingface.co/{ORIGIN_REPO}).

## How it was made

{BASE_REPO} is a byte transplant of {ORIGIN_REPO}: fp4 e2m1 expert weights stored as MLX
mxfp4 with the same bytes, fp8 e4m3 dense weights as MLX mxfp8 with the same bytes and each 128x128
block scale repeated per 32-group, every other tensor unchanged under the same name.
{SOURCE_REPO} keeps the original format and rewrites only the shards of layers 17-36.
Method: {prov['method']}.

This repository is the base with the tensors that changed replaced by the same transplant:

- every tensor of the rewritten source shards was transplanted and compared with the base:
  {compared['changed']} of {compared['tensors']:,} differ, all inside the steered modules; the other
  {compared['identical']:,} are byte-identical to the base, which re-proves the transplant on this data;
- the {compared['changed']} changed tensors were written in place into {len(prov['touched_shards'])} base shards;
  headers, offsets, shapes and dtypes did not move;
- every other tensor and file is byte-identical to {BASE_REPO} at `{BASE_REVISION[:8]}`,
  except this README;
- numeric check: each changed module dequantized with `mx.dequantize` from this layout against the
  fp8/fp4 source, max abs error {prov['numeric_worst_max_abs_err']}.

Recipe: {prov['recipe']}.
The splice is `scripts/lab/dsv4/dsv4_abliterated_splice.py`, run by
`scripts/lab/ablit-perf/job-dsv4-abliterated.sh` in the MacProvider repository.

## Checks this artifact passed

The publish step runs only after the job passed all of its gates:

- token parity of the MacProvider native engine against DeepSeek's reference implementation on these
  weights at 1K and 8K context: first 16 top-1 tokens exact and {greedy} greedy tokens equal;
- refusal sanity (greedy, keyword classes): the base refused {refused('base', 'harmful')} harmful prompts;
  this model refused {refused('abliterated', 'harmful')} harmful and {refused('abliterated', 'harmless')} harmless prompts.

These are lab sanity gates, not a capability or safety evaluation.

## License

MIT, the license of both {BASE_REPO} and {SOURCE_REPO} (and of {ORIGIN_REPO}).
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
    prov, diff = load_inputs(results)
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
    (stage / "README.md").write_text(model_card(prov, diff))

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
                             commit_message="Abliterated DeepSeek-V4-Flash-0731 MXFP4-MLX")
    print(f"PUBLISH_DONE repo={repo_id} revision={info.sha} stage_manifest={stage_sha} tested_manifest={snap_sha}", flush=True)


if __name__ == "__main__":
    sys.exit(main())
