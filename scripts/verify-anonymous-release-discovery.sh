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
github_api_curl_args=(
  "${curl_args[@]}"
  -H "Accept: application/vnd.github+json"
  -H "User-Agent: macprovider-release-verifier"
)
fixture_github_token="${MACPROVIDER_RELEASE_FIXTURE_GITHUB_TOKEN:-}"
github_api_curl_config=
if [ -n "$fixture_github_token" ]; then
  github_api_curl_config="$work/github-api-curl.conf"
  old_umask="$(umask)"
  umask 077
  printf 'header = "Authorization: Bearer %s"\n' "$fixture_github_token" > "$github_api_curl_config"
  umask "$old_umask"
  github_api_curl_args+=(--config "$github_api_curl_config")
fi
api="https://api.github.com/repos/$repository"
listing_attempts="${MACPROVIDER_DISCOVERY_LISTING_ATTEMPTS:-15}"
listing_retry_seconds="${MACPROVIDER_DISCOVERY_LISTING_RETRY_SECONDS:-2}"
[[ "$listing_attempts" =~ ^[1-9][0-9]*$ ]] || die "invalid discovery listing attempt budget"
[[ "$listing_retry_seconds" =~ ^[1-9][0-9]*$ ]] || die "invalid discovery listing retry interval"
listing_attempt=1
while true; do
  curl "${github_api_curl_args[@]}" "$api/releases?per_page=100" -o "$work/releases.json"
  set +e
  python3 "$root/scripts/select_public_discovery_transport.py" \
    "$work/releases.json" \
    "$transport_tag" \
    "$target_commit" \
    "$repository" \
    "$work/release.json" \
    "$work/assets.tsv"
  listing_status=$?
  set -e
  if [ "$listing_status" -eq 0 ]; then
    break
  fi
  if [ "$listing_status" -ne 2 ] || [ "$listing_attempt" -ge "$listing_attempts" ]; then
    die "highest public discovery transport is not the promoted target"
  fi
  listing_attempt=$((listing_attempt + 1))
  sleep "$listing_retry_seconds"
done
if [ -n "$github_api_curl_config" ]; then
  rm -f -- "$github_api_curl_config"
fi
unset \
  MACPROVIDER_RELEASE_FIXTURE_GITHUB_TOKEN \
  GITHUB_TOKEN \
  GH_TOKEN \
  RELEASE_POSTURE_TOKEN \
  fixture_github_token \
  github_api_curl_config \
  github_api_curl_args

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

client_asset="malibu-cli-${client_tag}-darwin-arm64.tar.gz"
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
tar -xzf "$work/$client_asset" -C "$work/client" malibu-cli
client="$work/client/malibu-cli"
[[ -x "$client" ]] || die "verified client archive lacks executable malibu-cli"
codesign --verify --strict --verbose=2 "$client"
[[ "$("$client" --version)" == "${client_tag#v}" ]] || die "client binary version differs"

mkdir "$work/home" "$work/client-tmp"
output="$(
  env \
    -u MACPROVIDER_RELEASE_FIXTURE_GITHUB_TOKEN \
    -u GITHUB_TOKEN \
    -u GH_TOKEN \
    -u RELEASE_POSTURE_TOKEN \
    HOME="$work/home" \
    CFFIXED_USER_HOME="$work/home" \
    RUNNER_TEMP="$work/client-tmp" \
    TMPDIR="$work/client-tmp" \
    "$client" update --check 2>&1
)" || {
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
