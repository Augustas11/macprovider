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

curl_common_args=(
  --show-error --silent --location --proto '=https' --tlsv1.2
  --connect-timeout 20 --max-time 240 --retry 5 --retry-delay 2
)
curl_args=(--fail "${curl_common_args[@]}")
# API calls run without --fail so a rate-limit 403/429 can be told apart from a
# real discovery failure (see github_api_get).
github_api_curl_args=(
  "${curl_common_args[@]}"
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
# Anonymous api.github.com allows 60 core requests per hour per source IP, and
# shared hosted runners routinely arrive with that budget spent. A rate-limit
# refusal says nothing about discovery, so wait for the advertised reset (within
# a bounded budget) and retry, instead of adding a token: the proof is that an
# unauthenticated client discovers the transport. Any other HTTP error fails.
rate_limit_wait_budget="${MACPROVIDER_DISCOVERY_RATE_LIMIT_WAIT_SECONDS:-3900}"
[[ "$rate_limit_wait_budget" =~ ^[0-9]+$ ]] || die "invalid rate-limit wait budget"
rate_limit_waited=0

rate_limit_sleep() {
  local seconds="$1" reason="$2"
  (( seconds < 1 )) && seconds=1
  if (( rate_limit_waited + seconds > rate_limit_wait_budget )); then
    die "anonymous GitHub API rate limit did not clear within ${rate_limit_wait_budget}s ($reason)"
  fi
  printf '[verify-anonymous-release-discovery] %s; waiting %ss\n' "$reason" "$seconds" >&2
  sleep "$seconds"
  rate_limit_waited=$((rate_limit_waited + seconds))
}

# Last value of a response header across redirect blocks, lowercased name.
header_value() {
  awk -v want="$1" -F': *' 'tolower($1) == want { v = $2 } END { gsub(/\r/, "", v); print v }' "$2"
}

# Block until the anonymous core budget has at least $1 requests left.
# GET /rate_limit itself does not count against the budget.
wait_for_anonymous_budget() {
  local need="$1" body remaining reset now
  while true; do
    body="$(curl "${curl_args[@]}" -H "User-Agent: macprovider-release-verifier" \
      https://api.github.com/rate_limit)" || return 0
    read -r remaining reset < <(python3 -c '
import json, sys
core = json.load(sys.stdin)["resources"]["core"]
print(int(core["remaining"]), int(core["reset"]))' <<<"$body") || return 0
    (( remaining >= need )) && return 0
    now="$(date +%s)"
    rate_limit_sleep $((reset - now + 5)) "anonymous core budget is $remaining (need $need)"
  done
}

github_api_get() {
  local url="$1" out="$2" status remaining reset retry_after now backoff=30
  while true; do
    status="$(curl "${github_api_curl_args[@]}" -D "$work/api-headers.txt" \
      -o "$out" -w '%{http_code}' "$url")" || die "GitHub API request failed: $url"
    case "$status" in
      200) return 0 ;;
      403 | 429) ;;
      *) die "GitHub API returned HTTP $status for $url" ;;
    esac
    remaining="$(header_value x-ratelimit-remaining "$work/api-headers.txt")"
    reset="$(header_value x-ratelimit-reset "$work/api-headers.txt")"
    retry_after="$(header_value retry-after "$work/api-headers.txt")"
    now="$(date +%s)"
    if [[ "$retry_after" =~ ^[0-9]+$ ]]; then
      rate_limit_sleep "$retry_after" "HTTP $status with retry-after"
    elif [[ "$remaining" == 0 && "$reset" =~ ^[0-9]+$ ]]; then
      rate_limit_sleep $((reset - now + 5)) "HTTP $status, anonymous rate limit exhausted"
    elif [[ "$status" == 429 ]] || grep -qi 'rate limit' "$out" 2>/dev/null; then
      rate_limit_sleep "$backoff" "HTTP $status secondary rate limit"
      backoff=$((backoff * 2 > 600 ? 600 : backoff * 2))
    else
      die "GitHub API returned HTTP $status for $url"
    fi
  done
}
listing_attempts="${MACPROVIDER_DISCOVERY_LISTING_ATTEMPTS:-15}"
listing_retry_seconds="${MACPROVIDER_DISCOVERY_LISTING_RETRY_SECONDS:-2}"
[[ "$listing_attempts" =~ ^[1-9][0-9]*$ ]] || die "invalid discovery listing attempt budget"
[[ "$listing_retry_seconds" =~ ^[1-9][0-9]*$ ]] || die "invalid discovery listing retry interval"
# Walk the listing exactly as the CLI does (SPEC-020-R001): numbered pages of
# 100, at most 10, stopping at the first page holding a transport or at a short
# page. The selector then sees only the page the client would select from.
fetch_client_visible_listing_page() {
  local page state max_pages
  max_pages="$(python3 "$root/scripts/discovery_listing_page_state.py" --max-pages)"
  for page in $(seq 1 "$max_pages"); do
    github_api_get "$api/releases?per_page=100&page=$page" "$work/releases.json"
    state="$(python3 "$root/scripts/discovery_listing_page_state.py" "$work/releases.json")" ||
      die "public discovery listing page $page is invalid"
    case "$state" in
      transport | end) return 0 ;;
      next) ;;
      *) die "unexpected discovery listing page state" ;;
    esac
  done
  die "no discovery transport within the client-visible listing bound"
}
listing_attempt=1
while true; do
  fetch_client_visible_listing_page
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

mkdir "$work/home" "$work/client-tmp"
# The client's own discovery walk is anonymous too; give it a clear budget.
wait_for_anonymous_budget 20
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
