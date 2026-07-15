#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build="$root/scripts/build-release-provenance.py"
capture="$root/scripts/capture-release-publication.py"
draft_identity="$root/scripts/verify-release-draft-identity.py"
verify_published="$root/scripts/verify-published-release.py"
work="$(mktemp -d "${TMPDIR:-/tmp}/release-provenance.XXXXXX")"
trap 'rm -rf "$work"' EXIT

tag=v1.2.3
commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
printf 'cli archive\n' > "$work/phase3-binary-m4-${tag}.tar.gz"
printf 'dmg payload\n' > "$work/Malibu-${tag}.dmg"
printf 'legacy bootstrap appcast\n' > "$work/appcast.xml"
printf 'compatibility artifact index\n' > "$work/compatibility-artifact-index.json"
printf 'coordinator payload\n' > "$work/coordinator-linux-amd64"
printf 'coordinator cli payload\n' > "$work/coordinator-cli-linux-amd64"
printf 'gateway payload\n' > "$work/gateway-linux-amd64"
printf 'pearl metadata\n' > "$work/pearl-release.json"
printf 'pearl metadata signature\n' > "$work/pearl-release.json.sig"
printf 'reviewed release notes\n' > "$work/release-notes.md"
cat >"$work/release-toolchain.json" <<'EOF'
{"macos_sdk":{"path":"/Applications/Xcode_16.4.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX15.5.sdk","version":"15.5"},"swift":{"driver_version":"1.120.5","version":"Apple Swift version 6.1.2 (swiftlang-6.1.2.1.2 clang-1700.0.13.5)"},"xcode":{"build":"16F6","developer_dir":"/Applications/Xcode_16.4.app/Contents/Developer","version":"16.4"}}
EOF

python3 "$build" "$tag" "$commit" Augustas11/macprovider false \
  "$work/release-toolchain.json" "$work/release-provenance.json" \
  "$work/phase3-binary-m4-${tag}.tar.gz" "$work/Malibu-${tag}.dmg" \
  "$work/appcast.xml" \
  "$work/compatibility-artifact-index.json" \
  "$work/coordinator-linux-amd64" "$work/coordinator-cli-linux-amd64" \
  "$work/gateway-linux-amd64" "$work/pearl-release.json" "$work/pearl-release.json.sig"
(
  cd "$work"
  shasum -a 256 \
    "phase3-binary-m4-${tag}.tar.gz" "Malibu-${tag}.dmg" appcast.xml compatibility-artifact-index.json \
    coordinator-linux-amd64 coordinator-cli-linux-amd64 gateway-linux-amd64 \
    pearl-release.json pearl-release.json.sig release-provenance.json \
    > checksums.txt
)
printf 'captured signature bytes\n' > "$work/checksums.txt.sig"

python3 - "$work" "$tag" "$commit" <<'PY'
import hashlib
import json
import pathlib
import sys

root, tag, commit = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
names = [
    f"phase3-binary-m4-{tag}.tar.gz",
    f"Malibu-{tag}.dmg",
    "appcast.xml",
    "compatibility-artifact-index.json",
    "coordinator-linux-amd64",
    "coordinator-cli-linux-amd64",
    "gateway-linux-amd64",
    "pearl-release.json",
    "pearl-release.json.sig",
    "release-provenance.json",
    "checksums.txt",
    "checksums.txt.sig",
]
assets = []
for asset_id, name in enumerate(names, 501):
    digest = hashlib.sha256((root / name).read_bytes()).hexdigest()
    assets.append({"id": asset_id, "name": name, "digest": f"sha256:{digest}"})
release = {
    "id": 401,
    "tag_name": tag,
    "target_commitish": commit,
    "draft": False,
    "immutable": True,
    "prerelease": False,
    "name": f"macprovider-cli {tag}",
    "body": "reviewed release notes\n",
    "assets": assets,
}
(root / "release.json").write_text(json.dumps(release), encoding="utf-8")
PY

local_assets=(
  "$work/phase3-binary-m4-${tag}.tar.gz"
  "$work/Malibu-${tag}.dmg"
  "$work/appcast.xml"
  "$work/compatibility-artifact-index.json"
  "$work/coordinator-linux-amd64"
  "$work/coordinator-cli-linux-amd64"
  "$work/gateway-linux-amd64"
  "$work/pearl-release.json"
  "$work/pearl-release.json.sig"
  "$work/release-provenance.json"
  "$work/checksums.txt"
  "$work/checksums.txt.sig"
)
python3 "$capture" --notes-file "$work/release-notes.md" \
  "$work/release.json" "$work/release-provenance.json" \
  "$work/publication-manifest.json" "${local_assets[@]}"

python3 - "$work/release.json" "$work/release-draft.json" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
data["draft"] = True
data["immutable"] = False
pathlib.Path(sys.argv[2]).write_text(json.dumps(data))
PY
python3 "$capture" --draft --notes-file "$work/release-notes.md" \
  "$work/release-draft.json" "$work/release-provenance.json" \
  "$work/draft-publication-manifest.json" "${local_assets[@]}"
cmp "$work/publication-manifest.json" "$work/draft-publication-manifest.json"

cat > "$work/release-draft-cli.json" <<EOF
{"databaseId":401,"isDraft":true,"tagName":"$tag","targetCommitish":"$commit"}
EOF
[[ "$(python3 "$draft_identity" cli "$work/release-draft-cli.json" "$tag" "$commit")" == 401 ]]
[[ "$(python3 "$draft_identity" api "$work/release-draft.json" "$tag" "$commit" --release-id 401)" == 401 ]]
python3 - "$work/release-draft-cli.json" "$work/release-draft.json" "$work" <<'PY'
import json
import pathlib
import sys

cli_path, api_path, root = map(pathlib.Path, sys.argv[1:])
cli = json.loads(cli_path.read_text())
api = json.loads(api_path.read_text())
cli_mutations = {
    "id": {**cli, "databaseId": 402},
    "draft": {**cli, "isDraft": False},
    "tag": {**cli, "tagName": "v9.9.9"},
    "commit": {**cli, "targetCommitish": "b" * 40},
}
api_mutations = {
    "id": {**api, "id": 402},
    "draft": {**api, "draft": False},
    "immutable": {**api, "immutable": True},
    "tag": {**api, "tag_name": "v9.9.9"},
    "commit": {**api, "target_commitish": "b" * 40},
}
for name, value in cli_mutations.items():
    (root / f"draft-cli-{name}.json").write_text(json.dumps(value))
for name, value in api_mutations.items():
    (root / f"draft-api-{name}.json").write_text(json.dumps(value))
PY
for fixture in "$work"/draft-cli-*.json; do
  if python3 "$draft_identity" cli "$fixture" "$tag" "$commit" --release-id 401 >"$work/draft-identity.out" 2>&1; then
    echo "draft identity guard accepted invalid CLI fixture: $fixture" >&2
    exit 1
  fi
done
for fixture in "$work"/draft-api-*.json; do
  if python3 "$draft_identity" api "$fixture" "$tag" "$commit" --release-id 401 >"$work/draft-identity.out" 2>&1; then
    echo "draft identity guard accepted invalid API fixture: $fixture" >&2
    exit 1
  fi
done
if python3 "$capture" "$work/release-draft.json" "$work/release-provenance.json" \
  "$work/premature-publication-manifest.json" "${local_assets[@]}" >"$work/draft.out" 2>&1; then
  echo "final publication capture accepted a draft release" >&2
  exit 1
fi
grep -q 'numeric release is still a draft' "$work/draft.out"

python3 - "$work/publication-manifest.json" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert manifest["release_id"] == 401
assert manifest["prerelease"] is False
assert manifest["title"] == "macprovider-cli v1.2.3"
assert re.fullmatch(r"[0-9a-f]{64}", manifest["body_sha256"])
assert re.fullmatch(r"[0-9a-f]{64}", manifest["publication_id"])
assert manifest["assets"]["Malibu-v1.2.3.dmg"]["id"] == 502
assert manifest["assets"]["appcast.xml"]["id"] == 503
assert manifest["assets"]["compatibility-artifact-index.json"]["id"] == 504
assert manifest["assets"]["coordinator-linux-amd64"]["id"] == 505
assert manifest["assets"]["pearl-release.json.sig"]["id"] == 509
expected_publication = hashlib.sha256(json.dumps({
    "appcast_sha256": manifest["assets"]["appcast.xml"]["sha256"],
    "compatibility_artifact_index_sha256": manifest["assets"]["compatibility-artifact-index.json"]["sha256"],
    "dmg_sha256": manifest["assets"]["Malibu-v1.2.3.dmg"]["sha256"],
}, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
assert manifest["publication_id"] == expected_publication
PY

for field in name body; do
  python3 - "$work/release.json" "$work/release-presentation-drift.json" "$field" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
data[sys.argv[3]] = "unreviewed presentation"
pathlib.Path(sys.argv[2]).write_text(json.dumps(data))
PY
  if python3 "$capture" --notes-file "$work/release-notes.md" \
    "$work/release-presentation-drift.json" "$work/release-provenance.json" \
    "$work/presentation-drift-manifest.json" "${local_assets[@]}" \
    >"$work/presentation-drift.out" 2>&1; then
    echo "publication capture accepted release $field drift" >&2
    exit 1
  fi
done

python3 - "$work/release.json" "$work/release-asset-id-drift.json" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
data["assets"][0]["id"] += 1000
pathlib.Path(sys.argv[2]).write_text(json.dumps(data))
PY
python3 "$capture" --notes-file "$work/release-notes.md" \
  "$work/release-asset-id-drift.json" "$work/release-provenance.json" \
  "$work/asset-id-drift-manifest.json" "${local_assets[@]}"
if cmp -s "$work/publication-manifest.json" "$work/asset-id-drift-manifest.json"; then
  echo "publication manifest did not bind numeric asset identity" >&2
  exit 1
fi

python3 - "$work/release.json" "$work/release-mutable.json" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
data["immutable"] = False
pathlib.Path(sys.argv[2]).write_text(json.dumps(data))
PY
if python3 "$capture" "$work/release-mutable.json" "$work/release-provenance.json" \
  "$work/mutable-manifest.json" "${local_assets[@]}" >"$work/mutable.out" 2>&1; then
  echo "publication capture accepted a mutable numeric release" >&2
  exit 1
fi
grep -q 'numeric release is not immutable' "$work/mutable.out"

python3 - "$work/release.json" "$work/release-prerelease-drift.json" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
data["prerelease"] = True
pathlib.Path(sys.argv[2]).write_text(json.dumps(data))
PY
if python3 "$capture" "$work/release-prerelease-drift.json" "$work/release-provenance.json" \
  "$work/prerelease-drift-manifest.json" "${local_assets[@]}" >"$work/prerelease-drift.out" 2>&1; then
  echo "publication capture accepted prerelease state drift" >&2
  exit 1
fi
grep -q 'prerelease state differs from signed provenance' "$work/prerelease-drift.out"

cp "$work/release.json" "$work/release-by-tag.json"
cp "$work/release.json" "$work/latest.json"
python3 "$verify_published" 401 false \
  "$work/release.json" "$work/release-by-tag.json" "$work/latest.json"
python3 - "$work/release.json" "$work/prerelease.json" "$work/prior-latest.json" <<'PY'
import json, pathlib, sys
release = json.loads(pathlib.Path(sys.argv[1]).read_text())
release["id"] = 402
release["prerelease"] = True
pathlib.Path(sys.argv[2]).write_text(json.dumps(release))
latest = dict(release)
latest["id"] = 401
latest["prerelease"] = False
pathlib.Path(sys.argv[3]).write_text(json.dumps(latest))
PY
python3 "$verify_published" 402 true \
  "$work/prerelease.json" "$work/prerelease.json" "$work/prior-latest.json"
if python3 "$verify_published" 402 true \
  "$work/prerelease.json" "$work/prerelease.json" "$work/prerelease.json" \
  >"$work/prerelease-latest.out" 2>&1; then
  echo "published-release verifier accepted a prerelease as stable latest" >&2
  exit 1
fi
grep -q 'prerelease unexpectedly resolves through the stable latest endpoint' "$work/prerelease-latest.out"

python3 - "$work/release.json" "$work/release-drift.json" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
data["assets"][1]["digest"] = "sha256:" + "0" * 64
pathlib.Path(sys.argv[2]).write_text(json.dumps(data))
PY
if python3 "$capture" "$work/release-drift.json" "$work/release-provenance.json" \
  "$work/drift-manifest.json" "${local_assets[@]}" >"$work/drift.out" 2>&1; then
  echo "publication capture accepted GitHub asset digest drift" >&2
  exit 1
fi
grep -q 'GitHub digest differs from captured workflow asset' "$work/drift.out"

python3 - "$work/release.json" "$work/release-extra.json" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
data["assets"].append({"id": 999, "name": "unexpected", "digest": "sha256:" + "0" * 64})
pathlib.Path(sys.argv[2]).write_text(json.dumps(data))
PY
if python3 "$capture" "$work/release-extra.json" "$work/release-provenance.json" \
  "$work/extra-manifest.json" "${local_assets[@]}" >"$work/extra.out" 2>&1; then
  echo "publication capture accepted an unsigned extra asset" >&2
  exit 1
fi
grep -q 'asset names differ from the signed release set' "$work/extra.out"

echo "release publication provenance regression checks passed"
