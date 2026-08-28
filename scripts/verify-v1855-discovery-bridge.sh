#!/usr/bin/env bash
# Prove the one-time v1.8.55 → append-only trust-preserving bridge without
# mutating the permanently immutable fixed release-discovery transport.
#
# Ordinary malibu-cli update from public v1.8.55 cannot enumerate
# release-discovery-v1-* transports. The supported bridge is an authenticated
# coordinator recommendation (or acceptance-candidate installer) for the exact
# signed numeric target. This anonymous check proves:
#   1) fixed release-discovery remains immutable and pinned
#   2) v1.8.55 cannot discover vNext through ordinary update --check
#   3) the exact vNext signed head is present on the append-only transport
#   4) the public numeric release identity matches that head under the pinned key
#   5) the bridged (target) CLI discovers the exact head anonymously
set -euo pipefail

# Mapping selector (specs/CONFORMANCE.json): anonymous v1.8.55 bridge proof

die() {
  printf '[verify-v1855-discovery-bridge] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$#" == 3 ]] || die "usage: TARGET_TAG TARGET_COMMIT TRANSPORT_TAG"
target_tag="$1"
target_commit="$2"
transport_tag="$3"
repository="${GITHUB_REPOSITORY:-Augustas11/macprovider}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/v1855-discovery-bridge.XXXXXX")"
trap 'rm -rf "$work"' EXIT

[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "invalid repository"
[[ "$target_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid target tag"
[[ "$transport_tag" =~ ^release-discovery-v1-[1-9][0-9]*$ ]] || die "invalid transport tag"
[[ "$target_commit" =~ ^[0-9a-f]{40}$ ]] || die "invalid target commit"
[[ "$target_tag" != v1.8.55 ]] || die "bridge target must be newer than v1.8.55"

curl_args=(
  --fail --show-error --silent --location --proto '=https' --tlsv1.2
  --connect-timeout 20 --max-time 240 --retry 5 --retry-delay 2
)
api="https://api.github.com/repos/$repository"

curl "${curl_args[@]}" "$api/releases/tags/release-discovery" -o "$work/fixed-release.json"
python3 - "$work/fixed-release.json" "$repository" <<'PY'
import json
import pathlib
import re
import sys

release = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
repository = sys.argv[2]
if release.get("tag_name") != "release-discovery":
    raise SystemExit("fixed discovery tag drifted")
if release.get("draft") is not False or release.get("prerelease") is not False:
    raise SystemExit("fixed discovery release is not a public non-prerelease")
if release.get("immutable") is not True:
    raise SystemExit("fixed discovery release is not immutable")
if release.get("target_commitish") != "ce1158e8c53595150f61a34e55c7e52ac052d477":
    raise SystemExit("fixed discovery release is no longer pinned to public v1.8.55")
required = {
    "macprovider-release-discovery.json",
    "macprovider-release-discovery.json.sig",
}
names = {asset.get("name") for asset in release.get("assets", []) if isinstance(asset, dict)}
if not required.issubset(names):
    raise SystemExit("fixed discovery release is missing signed head assets")
for name in sorted(required):
    matches = [asset for asset in release["assets"] if asset.get("name") == name]
    if len(matches) != 1:
        raise SystemExit(f"fixed discovery release must contain exactly one {name}")
    expected = f"https://github.com/{repository}/releases/download/release-discovery/{name}"
    if matches[0].get("browser_download_url") != expected:
        raise SystemExit(f"fixed discovery asset URL drifted for {name}")
PY

curl "${curl_args[@]}" \
  "https://github.com/$repository/releases/download/release-discovery/macprovider-release-discovery.json" \
  -o "$work/fixed-head.json"
python3 - "$work/fixed-head.json" <<'PY'
import json
import pathlib
import sys

signed = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["signed"]
if signed.get("target_compatibility_set_id") != (
    "Augustas11/macprovider:v1.8.55@ce1158e8c53595150f61a34e55c7e52ac052d477"
):
    raise SystemExit("fixed discovery head no longer targets public v1.8.55")
if type(signed.get("release_sequence")) is not int or signed["release_sequence"] <= 0:
    raise SystemExit("fixed discovery head sequence is invalid")
PY

"$root/scripts/verify-anonymous-release-discovery.sh" \
  "$target_tag" "$target_commit" "$target_tag" "$transport_tag"

client_asset="malibu-cli-v1.8.55-darwin-arm64.tar.gz"
client_base="https://github.com/$repository/releases/download/v1.8.55"
for name in "$client_asset" checksums.txt checksums.txt.sig; do
  curl "${curl_args[@]}" "$client_base/$name" -o "$work/$name"
done
openssl dgst -sha256 \
  -verify "$root/ops/pearl-updater/release-signing-public.pem" \
  -signature "$work/checksums.txt.sig" "$work/checksums.txt" >/dev/null ||
  die "v1.8.55 checksum signature is invalid"
expected_client_sha="$(awk -v name="$client_asset" '$2 == name { print $1 }' "$work/checksums.txt")"
[[ "$expected_client_sha" =~ ^[0-9a-f]{64}$ ]] || die "v1.8.55 archive is absent from signed checksums"
actual_client_sha="$(shasum -a 256 "$work/$client_asset" | awk '{print $1}')"
[[ "$actual_client_sha" == "$expected_client_sha" ]] || die "v1.8.55 archive checksum differs"
mkdir "$work/client"
tar -xzf "$work/$client_asset" -C "$work/client" malibu-cli
client="$work/client/malibu-cli"
[[ -x "$client" ]] || die "verified v1.8.55 archive lacks executable malibu-cli"
codesign --verify --strict --verbose=2 "$client"
[[ "$("$client" --version)" == "1.8.55" ]] || die "v1.8.55 binary version differs"

mkdir "$work/home-fixed"
set +e
fixed_output="$(HOME="$work/home-fixed" "$client" update --check 2>&1)"
fixed_status=$?
set -e
printf '%s\n' "$fixed_output" > "$work/fixed-update-check.txt"
if grep -Eq "Update available: v1\\.8\\.55 -> ${target_tag}" <<<"$fixed_output"; then
  die "v1.8.55 ordinary discovery must not observe append-only $target_tag"
fi
if [[ "$fixed_status" -eq 0 ]]; then
  grep -Eqx 'Already up to date \(v1\.8\.55\)' <<<"$fixed_output" ||
    die "unexpected successful v1.8.55 ordinary discovery output"
else
  grep -Eqi 'expired|replay|equivocation|invalid|not found|GitHub release tag not found' \
    <<<"$fixed_output" ||
    die "v1.8.55 ordinary discovery failed closed for an unexpected reason"
fi

target_base="https://github.com/$repository/releases/download/$target_tag"
for name in \
  checksums.txt \
  checksums.txt.sig \
  compatibility-artifact-index.json \
  compatibility-set.json \
  macprovider-release-discovery.json \
  macprovider-release-discovery.json.sig
do
  curl "${curl_args[@]}" "$target_base/$name" -o "$work/target-$name"
done
openssl dgst -sha256 \
  -verify "$root/ops/pearl-updater/release-signing-public.pem" \
  -signature "$work/target-checksums.txt.sig" "$work/target-checksums.txt" >/dev/null ||
  die "target checksum signature is invalid"
for name in \
  macprovider-release-discovery.json \
  macprovider-release-discovery.json.sig \
  compatibility-artifact-index.json \
  compatibility-set.json
do
  expected_sha="$(awk -v name="$name" '$2 == name { print $1 }' "$work/target-checksums.txt")"
  [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || die "target $name is absent from signed checksums"
  actual_sha="$(shasum -a 256 "$work/target-$name" | awk '{print $1}')"
  [[ "$actual_sha" == "$expected_sha" ]] || die "target $name checksum differs"
done
# Allow expired: the numeric release embeds the original head; current validity
# is proved on the append-only transport above.
python3 "$root/scripts/verify-release-discovery-transport.py" \
  --head "$work/target-macprovider-release-discovery.json" \
  --signature "$work/target-macprovider-release-discovery.json.sig" \
  --artifact-index "$work/target-compatibility-artifact-index.json" \
  --public-key "$root/ops/pearl-updater/release-signing-public.pem" \
  --repository "$repository" \
  --transport-tag "$transport_tag" \
  --target-tag "$target_tag" \
  --target-commit "$target_commit" \
  --allow-expired \
  >/dev/null
python3 - \
  "$work/target-macprovider-release-discovery.json" \
  "$work/target-compatibility-set.json" \
  "$work/target-compatibility-artifact-index.json" \
  "$repository" \
  "$target_tag" \
  "$target_commit" \
  "$transport_tag" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

head_path, manifest_path, index_path, repository, tag, commit, transport = sys.argv[1:]
head = json.loads(pathlib.Path(head_path).read_text(encoding="utf-8"))
manifest = json.loads(pathlib.Path(manifest_path).read_text(encoding="utf-8"))
index = json.loads(pathlib.Path(index_path).read_text(encoding="utf-8"))
signed = head["signed"]
expected_set = f"{repository}:{tag}@{commit}"
if signed.get("target_compatibility_set_id") != expected_set:
    raise SystemExit("target discovery head identity differs from the numeric release")
if manifest.get("signed", {}).get("compatibility_set_id") != expected_set:
    raise SystemExit("target compatibility set identity differs from the numeric release")
if index.get("compatibility_set_id") != expected_set:
    raise SystemExit("target artifact index identity differs from the numeric release")
digest = hashlib.sha256(pathlib.Path(index_path).read_bytes()).hexdigest()
if signed.get("target_artifact_index_sha256") != digest:
    raise SystemExit("target discovery head digest differs from the public artifact index")
match = re.fullmatch(r"release-discovery-v1-([1-9][0-9]*)", transport)
if not match or int(match.group(1)) != signed.get("release_sequence"):
    raise SystemExit("bridge transport tag is not bound to the target discovery sequence")
PY

printf '[verify-v1855-discovery-bridge] ok: v1.8.55 remains fixed-tag bound; exact %s head is on %s for the supported coordinator/acceptance bridge\n' \
  "$target_tag" "$transport_tag"
