#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
verifier="$root/scripts/verify-release-discovery-transport.py"
work="$(mktemp -d "${TMPDIR:-/tmp}/release-discovery-transport.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fail() {
  printf '[test-release-discovery-transport] ERROR: %s\n' "$*" >&2
  exit 1
}

repository=Augustas11/macprovider
tag=v1.8.56
commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
transport_tag=release-discovery-v1-200
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$work/private.pem" >/dev/null 2>&1
openssl pkey -in "$work/private.pem" -pubout -out "$work/public.pem" >/dev/null 2>&1
python3 - "$work/compatibility-artifact-index.json" "$repository" "$tag" "$commit" <<'PY'
import json
import pathlib
import sys

path, repository, tag, commit = sys.argv[1:]
value = {
    "artifacts": {},
    "commit": commit,
    "compatibility_manifest_sha256": "b" * 64,
    "compatibility_set_id": f"{repository}:{tag}@{commit}",
    "repository": repository,
    "schema_version": "macprovider.compatibility-artifact-index.v1",
    "tag": tag,
}
pathlib.Path(path).write_text(
    json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY
index_sha="$(shasum -a 256 "$work/compatibility-artifact-index.json" | awk '{print $1}')"
read -r issued expires < <(python3 - <<'PY'
import datetime as dt

now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
render = lambda value: value.strftime("%Y-%m-%dT%H:%M:%SZ")
print(render(now), render(now + dt.timedelta(hours=1)))
PY
)
python3 - "$work" "$repository" "$tag" "$commit" "$index_sha" "$issued" "$expires" <<'PY'
import json
import pathlib
import sys

root, repository, tag, commit, index_sha, issued, expires = sys.argv[1:]
root = pathlib.Path(root)
signed = {
    "expires_at": expires,
    "issued_at": issued,
    "release_sequence": 200,
    "schema_version": "macprovider.release-discovery.v1",
    "signed_policy_minimum": None,
    "signed_policy_revoked": [],
    "target_artifact_index_sha256": index_sha,
    "target_compatibility_set_id": f"{repository}:{tag}@{commit}",
}
canonical = lambda value: (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
(root / "signed.json").write_bytes(canonical(signed))
(root / "macprovider-release-discovery.json").write_bytes(canonical({
    "schema_version": "macprovider.release-discovery-envelope.v1",
    "signed": signed,
}))
PY
openssl dgst -sha256 -sign "$work/private.pem" \
  -out "$work/macprovider-release-discovery.json.sig" "$work/signed.json"
python3 - "$work" "$repository" "$transport_tag" "$commit" <<'PY'
import hashlib
import json
import pathlib
import sys

root, repository, transport_tag, commit = sys.argv[1:]
root = pathlib.Path(root)
names = (
    "compatibility-artifact-index.json",
    "macprovider-release-discovery.json",
    "macprovider-release-discovery.json.sig",
)
assets = []
for index, name in enumerate(names, 1):
    assets.append({
        "id": index,
        "name": name,
        "digest": "sha256:" + hashlib.sha256((root / name).read_bytes()).hexdigest(),
        "browser_download_url": f"https://github.com/{repository}/releases/download/{transport_tag}/{name}",
    })
release = {
    "assets": assets,
    "draft": False,
    "immutable": True,
    "prerelease": True,
    "tag_name": transport_tag,
    "target_commitish": commit,
}
(root / "release.json").write_text(json.dumps(release), encoding="utf-8")
PY

verify=(
  python3 "$verifier"
  --release-json "$work/release.json"
  --head "$work/macprovider-release-discovery.json"
  --signature "$work/macprovider-release-discovery.json.sig"
  --artifact-index "$work/compatibility-artifact-index.json"
  --public-key "$work/public.pem"
  --repository "$repository"
  --transport-tag "$transport_tag"
  --target-tag "$tag"
  --target-commit "$commit"
  --require-immutable
)
[[ "$("${verify[@]}")" == 200 ]] || fail "valid transport did not return its sequence"

expect_reject() {
  local label="$1"
  shift
  if "$@" >"$work/$label.out" 2>&1; then
    fail "$label was accepted"
  fi
}

expect_reject replay "${verify[@]}" --minimum-sequence 200
expect_reject wrong-target python3 "$verifier" \
  --release-json "$work/release.json" \
  --head "$work/macprovider-release-discovery.json" \
  --signature "$work/macprovider-release-discovery.json.sig" \
  --artifact-index "$work/compatibility-artifact-index.json" \
  --public-key "$work/public.pem" \
  --repository "$repository" \
  --transport-tag "$transport_tag" \
  --target-tag v1.8.57 \
  --target-commit "$commit" \
  --require-immutable
expect_reject wrong-transport python3 "$verifier" \
  --release-json "$work/release.json" \
  --head "$work/macprovider-release-discovery.json" \
  --signature "$work/macprovider-release-discovery.json.sig" \
  --artifact-index "$work/compatibility-artifact-index.json" \
  --public-key "$work/public.pem" \
  --repository "$repository" \
  --transport-tag release-discovery-v1-201 \
  --target-tag "$tag" \
  --target-commit "$commit" \
  --require-immutable

cp "$work/compatibility-artifact-index.json" "$work/index.valid"
python3 - "$work/compatibility-artifact-index.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["tag"] = "v1.8.57"
path.write_text(
    json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY
expect_reject artifact-identity "${verify[@]}"
mv "$work/index.valid" "$work/compatibility-artifact-index.json"

cp "$work/release.json" "$work/release.valid"
python3 - "$work/release.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text())
value["immutable"] = False
path.write_text(json.dumps(value))
PY
expect_reject mutable "${verify[@]}"
mv "$work/release.valid" "$work/release.json"

cp "$work/release.json" "$work/release.valid"
python3 - "$work/release.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text())
value["assets"].append({
    "id": 99,
    "name": "unexpected.bin",
    "digest": "sha256:" + "0" * 64,
    "browser_download_url": "https://github.com/Augustas11/macprovider/releases/download/release-discovery-v1-200/unexpected.bin",
})
path.write_text(json.dumps(value))
PY
expect_reject extra-asset "${verify[@]}"
mv "$work/release.valid" "$work/release.json"

cp "$work/macprovider-release-discovery.json.sig" "$work/signature.valid"
printf 'invalid\n' > "$work/macprovider-release-discovery.json.sig"
expect_reject signature "${verify[@]}"
mv "$work/signature.valid" "$work/macprovider-release-discovery.json.sig"

printf '[test-release-discovery-transport] ok: versioned immutable transport fails closed\n'
