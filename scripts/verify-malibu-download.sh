#!/usr/bin/env bash
# Smoke-test the public Malibu download host (Sparkle + landing page).
#
# Usage:
#   bash scripts/verify-malibu-download.sh
#   MALIBU_DOWNLOAD_HOST=download.malibu.tech bash scripts/verify-malibu-download.sh
#   MALIBU_DOWNLOAD_RESOLVE_IP=159.223.165.194  # when name.com DNS still propagating

set -euo pipefail

HOST="${MALIBU_DOWNLOAD_HOST:-download.malibu.tech}"
RESOLVE_IP="${MALIBU_DOWNLOAD_RESOLVE_IP:-}"
RESOLVE_IP="${MALIBU_DOWNLOAD_RESOLVE_IP:-159.223.165.194}"
BASE="https://${HOST}"

fail() {
  printf '[verify-malibu-download] FAIL: %s\n' "$*" >&2
  exit 1
}

curl_args=( -fsS --max-time 25 )
if ! curl "${curl_args[@]}" "${BASE}/appcast.xml" >/dev/null 2>&1; then
  curl_args+=( --resolve "${HOST}:443:${RESOLVE_IP}" )
fi

check_http() {
  local path="$1" want="$2"
  local body status
  body="$(mktemp "${TMPDIR:-/tmp}/malibu-dl.XXXXXX")"
  status="$(curl "${curl_args[@]}" -o "$body" -w '%{http_code}' "${BASE}${path}")" || fail "${path} unreachable"
  [[ "$status" == "$want" ]] || fail "${path} status=${status} want=${want} body=$(head -c 200 "$body")"
  rm -f "$body"
  printf '  ok: %s -> %s\n' "$path" "$status"
}

printf '[verify-malibu-download] probing %s\n' "$BASE"
check_http '/appcast.xml' '200'
check_http '/latest.dmg' '200'

appcast="$(curl "${curl_args[@]}" "${BASE}/appcast.xml")"
echo "$appcast" | grep -q '<rss' || fail 'appcast.xml is not Sparkle RSS'
echo "$appcast" | grep -q 'download.malibu.tech' || fail 'appcast missing download.malibu.tech URLs'

printf '[verify-malibu-download] PASS\n'
