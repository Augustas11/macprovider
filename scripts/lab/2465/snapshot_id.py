"""Print the `macprovider.snapshot-manifest.v1` identity of a model directory: the catalog
`model_sha256`, the native-MTP admission `artifact_hash`, and the `target_sha256` /
`mtp_sha256` a native-mtp-bench policy must carry.

usage: snapshot_id.py DIR [DIR ...]   (one "<sha256>  <dir>" line per directory)

Uses scripts/publish-model-mirror.py's own walk and manifest bytes (the same rules as the
Swift MLXSnapshotIdentity: sorted relative paths, platform metadata and a root `.cache`
skipped), so this helper and the provider cannot disagree.
"""
import hashlib
import importlib.util
import sys
from pathlib import Path

MIRROR = Path(__file__).resolve().parents[2] / "publish-model-mirror.py"


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    spec = importlib.util.spec_from_file_location("publish_model_mirror", MIRROR)
    mirror = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mirror)
    for d in sys.argv[1:]:
        entries = mirror.snapshot_entries(Path(d))
        print(f"{hashlib.sha256(mirror.manifest_bytes(entries)).hexdigest()}  {d}", flush=True)


if __name__ == "__main__":
    main()
