#!/usr/bin/env bash
# Prove an already-published CLI discovers the exact current immutable transport.
set -euo pipefail

die() {
  printf '[verify-anonymous-release-discovery] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$#" == 4 ]] || die "usage: TARGET_TAG TARGET_COMMIT CLIENT_TAG TRANSPORT_TAG"
target_tag="$1"
target_commit="$2"
client_tag="$3"
transport_tag="$4"
repository="${GITHUB_REPOSITORY:-Augustas11/macprovider}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/anonymous-release-discovery.XXXXXX")"
trap 'rm -rf "$work"' EXIT

[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "invalid repository"
[[ "$target_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid target tag"
[[ "$client_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid client tag"
[[ "$transport_tag" =~ ^release-discovery-v1-[1-9][0-9]*$ ]] || die "invalid transport tag"
[[ "$target_commit" =~ ^[0-9a-f]{40}$ ]] || die "invalid target commit"

curl_args=(
  --fail --show-error --silent --location --proto '=https' --tlsv1.2
  --connect-timeout 20 --max-time 240 --retry 5 --retry-delay 2
)
api="https://api.github.com/repos/$repository"
curl "${curl_args[@]}" "$api/releases?per_page=20" -o "$work/releases.json"

python3 - "$work/releases.json" "$transport_tag" "$target_commit" "$repository" "$work/release.json" "$work/assets.tsv" <<'PY'
import json
import pathlib
import re
import sys

releases_path, expected_transport, commit, repository, release_output, assets_output = sys.argv[1:]
releases = json.loads(pathlib.Path(releases_path).read_text(encoding="utf-8"))
candidates = []
for release in releases:
    match = re.fullmatch(r"release-discovery-v1-([1-9][0-9]*)", str(release.get("tag_name", "")))
    if match:
        candidates.append((int(match.group(1)), release))
if not candidates:
    raise SystemExit("public discovery listing has no append-only transport")
_, release = max(candidates, key=lambda item: item[0])
if release.get("tag_name") != expected_transport or release.get("target_commitish") != commit:
    raise SystemExit("highest public discovery transport is not the promoted target")
if release.get("draft") is not False or release.get("prerelease") is not True or release.get("immutable") is not True:
    raise SystemExit("public discovery transport is not an immutable prerelease")
required = {
    "compatibility-artifact-index.json",
    "macprovider-release-discovery.json",
    "macprovider-release-discovery.json.sig",
}
rows = []
for name in sorted(required):
    matches = [asset for asset in release.get("assets", []) if asset.get("name") == name]
    if len(matches) != 1:
        raise SystemExit(f"public release does not contain exactly one {name}")
    url = matches[0].get("browser_download_url")
    expected = f"https://github.com/{repository}/releases/download/{expected_transport}/{name}"
    if url != expected:
        raise SystemExit(f"noncanonical public asset URL for {name}")
    rows.append(f"{name}\t{url}\n")
pathlib.Path(release_output).write_text(json.dumps(release), encoding="utf-8")
pathlib.Path(assets_output).write_text("".join(rows), encoding="ascii")
PY

while IFS=$'\t' read -r name url; do
  curl "${curl_args[@]}" "$url" -o "$work/$name"
done < "$work/assets.tsv"

python3 "$root/scripts/verify-release-discovery-transport.py" \
  --release-json "$work/release.json" \
  --head "$work/macprovider-release-discovery.json" \
  --signature "$work/macprovider-release-discovery.json.sig" \
  --artifact-index "$work/compatibility-artifact-index.json" \
  --public-key "$root/ops/pearl-updater/release-signing-public.pem" \
  --repository "$repository" \
  --transport-tag "$transport_tag" \
  --target-tag "$target_tag" \
  --target-commit "$target_commit" \
  --require-immutable >/dev/null

client_asset="macprovider-cli-${client_tag}-darwin-arm64.tar.gz"
client_base="https://github.com/$repository/releases/download/$client_tag"
for name in "$client_asset" checksums.txt checksums.txt.sig; do
  curl "${curl_args[@]}" "$client_base/$name" -o "$work/$name"
done
openssl dgst -sha256 \
  -verify "$root/ops/pearl-updater/release-signing-public.pem" \
  -signature "$work/checksums.txt.sig" "$work/checksums.txt" >/dev/null ||
  die "client checksum signature is invalid"
expected_client_sha="$(awk -v name="$client_asset" '$2 == name { print $1 }' "$work/checksums.txt")"
[[ "$expected_client_sha" =~ ^[0-9a-f]{64}$ ]] || die "client archive is absent from signed checksums"
actual_client_sha="$(shasum -a 256 "$work/$client_asset" | awk '{print $1}')"
[[ "$actual_client_sha" == "$expected_client_sha" ]] || die "client archive checksum differs"
mkdir "$work/client"
tar -xzf "$work/$client_asset" -C "$work/client" macprovider-cli
client="$work/client/macprovider-cli"
[[ -x "$client" ]] || die "verified client archive lacks executable macprovider-cli"
codesign --verify --strict --verbose=2 "$client"
[[ "$("$client" --version)" == "${client_tag#v}" ]] || die "client binary version differs"

mkdir "$work/home"
output="$(HOME="$work/home" "$client" update --check 2>&1)" || {
  printf '%s\n' "$output" >&2
  die "$client_tag could not discover $target_tag anonymously"
}
if [[ "$client_tag" == "$target_tag" ]]; then
  grep -Fqx "Already up to date (${target_tag})" <<<"$output" ||
    die "target client did not authenticate its own immutable transport"
else
  grep -Fqx "Update available: ${client_tag} -> ${target_tag}" <<<"$output" ||
    die "prior client did not discover the promoted immutable transport"
fi

printf '[verify-anonymous-release-discovery] ok: %s discovered %s through %s\n' \
  "$client_tag" "$target_tag" "$transport_tag"
