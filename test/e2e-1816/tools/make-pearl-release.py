#!/usr/bin/env python3
"""#1816 e2e: build the flat release directory the REAL Pearl updater reads
with --source-dir (the GitHub release asset set of `macprovider-pearl-update`):

  pearl-release.json(.sig)  checksums.txt(.sig)   (P-256, the VM test release key)
  coordinator-linux-amd64 coordinator-cli-linux-amd64 gateway-linux-amd64
  the catalog release, byte for byte from the tree (production-signed feeds:
  phase3-binary/catalog/autotune + phase3-binary/dist/static), with the
  artifact feed when the tree's release.json binds it.

Only the outer P-256 layer is a test key (the updater's
PEARL_UPDATER_TEST_PUBLIC_KEY, test mode); every catalog signature is the
production one. Metadata shape: ops/pearl-updater/test_pearl_updater.py
(release fixture) and parse_metadata in the updater.

Usage: make-pearl-release.py --tree WT --bins DIR --tag vX.Y.Z --commit SHA40
                             --key PEM --out DIR [--rollout strict_post_migration]
"""
import argparse, hashlib, json, os, pathlib, shutil, subprocess, sys

ap = argparse.ArgumentParser()
ap.add_argument("--tree", required=True)
ap.add_argument("--bins", required=True)
ap.add_argument("--tag", required=True)
ap.add_argument("--commit", required=True)
ap.add_argument("--key", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--rollout", default="strict_post_migration", choices=("strict_post_migration", "bridge_required"))
a = ap.parse_args()
tree, bins, out = pathlib.Path(a.tree), pathlib.Path(a.bins), pathlib.Path(a.out)
if out.exists():
    shutil.rmtree(out)
out.mkdir(parents=True)


def sha(p):
    return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()


def sign(src, dst):
    subprocess.run(["openssl", "dgst", "-sha256", "-sign", a.key, "-out", str(dst), str(src)], check=True)


runtime = {}
for name in ("coordinator-linux-amd64", "coordinator-cli-linux-amd64", "gateway-linux-amd64"):
    shutil.copyfile(bins / name, out / name)
    os.chmod(out / name, 0o755)
    runtime[name] = out / name
emb = {}
for comp in ("coordinator", "gateway"):
    v = subprocess.run([str(runtime[comp + "-linux-amd64"]), "--version"], check=True, capture_output=True, text=True).stdout.strip()
    emb[comp] = v
version = a.tag[1:]

cat_src = {
    "release.json": "phase3-binary/catalog/autotune/release.json",
    "trusted-keys.json": "phase3-binary/catalog/autotune/trusted-keys.json",
    "tier2-catalog.json": "phase3-binary/catalog/autotune/tier2-catalog.json",
}
for f in ("rate-card.json", "autotune-candidates.json", "demand-rank.json", "continuous-batching-policy.json"):
    cat_src[f] = "phase3-binary/dist/static/" + f
    cat_src[f + ".sig"] = "phase3-binary/dist/static/" + f + ".sig"
manifest = json.loads((tree / cat_src["release.json"]).read_text())
if "autotune-artifacts.json" in manifest.get("feeds", {}):
    for f in ("autotune-artifacts.json", "autotune-artifacts.json.sig"):
        cat_src[f] = "phase3-binary/dist/static/" + f
for name, rel in cat_src.items():
    shutil.copyfile(tree / rel, out / name)

meta = {
    "schema_version": 1,
    "release_lane": "pearl_runtime_catalog",
    "repository": "Augustas11/macprovider",
    "tag": a.tag,
    "release_version": version,
    "commit": a.commit,
    "architecture": "linux-amd64",
    "provider_admission_rollout": {
        "mode": a.rollout,
        "enforce_provider_admission": a.rollout == "strict_post_migration",
        "bridge_duration_s": 0 if a.rollout == "strict_post_migration" else 86400,
    },
    "components": {
        "coordinator": {"asset": "coordinator-linux-amd64", "sha256": sha(runtime["coordinator-linux-amd64"]), "embedded_version": emb["coordinator"]},
        "gateway": {"asset": "gateway-linux-amd64", "sha256": sha(runtime["gateway-linux-amd64"]), "embedded_version": emb["gateway"]},
    },
    "catalog": {"release_id": manifest["release_id"], "policy_version": manifest["policy_version"],
                "files": {n: sha(out / n) for n in cat_src}},
    "operator_artifacts": {"coordinator_cli": {"asset": "coordinator-cli-linux-amd64", "sha256": sha(runtime["coordinator-cli-linux-amd64"])}},
    "provider_advertised_version": version,
}
(out / "pearl-release.json").write_text(json.dumps(meta, sort_keys=True, separators=(",", ":")) + "\n")
sign(out / "pearl-release.json", out / "pearl-release.json.sig")
assets = ["pearl-release.json", "pearl-release.json.sig", *runtime, *cat_src]
(out / "checksums.txt").write_text("".join("%s  %s\n" % (sha(out / n), n) for n in assets))
sign(out / "checksums.txt", out / "checksums.txt.sig")
print(json.dumps({"tag": a.tag, "catalog_release_id": manifest["release_id"], "artifact_feed": "autotune-artifacts.json" in cat_src,
                  "embedded": emb, "files": len(assets) + 2}))
