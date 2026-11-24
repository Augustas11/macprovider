#!/usr/bin/env python3
"""Re-host a verified catalog snapshot byte for byte in a repo we control (#2480).

Usage (on the machine that holds the verified snapshot and an HF write token):
  mirror_snapshot.py SNAPSHOT_DIR STAGE_DIR OWNER/REPO --expect SHA256 [--dry-run]

SNAPSHOT_DIR is the provider's verified model directory. It is never written to:
the stage is an APFS clone (`cp -c`), so it costs no disk and keeps single-link
files. The stage must hash to --expect (macprovider.snapshot-manifest.v1) before
anything is uploaded, and the upload must match the stage file for file after.
No file is edited, so the mirror has the catalog row's snapshot-manifest hash.
Prints MIRROR_REVISION <sha> on success.
"""
from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "minimax"))
from publish_abliterated import snapshot_manifest_sha256, upload_and_verify  # noqa: E402


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("snapshot"); ap.add_argument("stage"); ap.add_argument("repo_id")
    ap.add_argument("--expect", required=True)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    src, stage = pathlib.Path(a.snapshot), pathlib.Path(a.stage)
    if stage.exists():
        raise SystemExit(f"BLOCKER: {stage} exists; pass a fresh stage path")
    stage.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["cp", "-c", "-R", str(src), str(stage)], check=True)
    got = snapshot_manifest_sha256(stage)
    if got != a.expect:
        raise SystemExit(f"BLOCKER: stage manifest {got} is not the catalog identity {a.expect}")
    print(f"STAGE_VERIFIED manifest={got}", flush=True)
    if a.dry_run:
        print("DRY_RUN no upload", flush=True)
        return
    from huggingface_hub import HfApi
    api = HfApi()
    info = upload_and_verify(api, a.repo_id, stage, private=False,
                             commit_message=f"Byte-identical mirror, snapshot-manifest {got}")
    print(f"MIRROR_REVISION {info.sha}", flush=True)


if __name__ == "__main__":
    main()
