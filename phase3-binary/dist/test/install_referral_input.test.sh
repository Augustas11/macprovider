#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

extract_function() {
  local name="$1"
  awk -v start="${name}() {" '
    $0 == start { inside=1 }
    inside { print }
    inside && /^}$/ { exit }
  ' "$INSTALL_SH"
}

extract_function normalize_referral_code > "$TMP/functions.sh"
extract_function advisory_validate_referral >> "$TMP/functions.sh"
extract_function referral_rejection_message >> "$TMP/functions.sh"
# shellcheck source=/dev/null
source "$TMP/functions.sh"

code='MAL1-S-key-seed-AAAAAAAAAAAAAAAAAAAAAAAAAA'
[ "$(normalize_referral_code "$code")" = "$code" ]
[ "$(normalize_referral_code "  $code  ")" = "$code" ]
[ "$(normalize_referral_code "https://coordinator.streamvc.live/j/$code")" = "$code" ]
[ "$(normalize_referral_code " https://coordinator.streamvc.live/j/$code/ ")" = "$code" ]
[ "$(normalize_referral_code "https://coordinator.streamvc.live/j/$code?c=x-post#install")" = "$code" ]
[ "$(normalize_referral_code "https://coordinator.streamvc.live/j/$code/?c=x-post#install")" = "$code" ]
[ "$(normalize_referral_code "")" = "" ]

if normalize_referral_code "http://coordinator.streamvc.live/j/$code" >/dev/null; then
  echo "non-HTTPS invite URL was accepted" >&2
  exit 1
fi
if normalize_referral_code "https://coordinator.streamvc.live/?next=/j/$code" >/dev/null; then
  echo "query-smuggled invite URL was accepted" >&2
  exit 1
fi
if normalize_referral_code "https://coordinator.streamvc.live/j/" >/dev/null; then
  echo "invite URL without a code was accepted" >&2
  exit 1
fi
if normalize_referral_code "https://coordinator.streamvc.live/j/$code/extra" >/dev/null; then
  echo "invite URL with an extra path segment was accepted" >&2
  exit 1
fi
if normalize_referral_code "https://coordinator.streamvc.live/j/$code//" >/dev/null; then
  echo "invite URL with multiple trailing slashes was accepted" >&2
  exit 1
fi
if normalize_referral_code "https://user@coordinator.streamvc.live/j/$code" >/dev/null; then
  echo "credential-bearing invite URL was accepted" >&2
  exit 1
fi

[ "$(referral_rejection_message missing)" = 'An invite is required; rerun with --ref CODE_OR_INVITE_URL' ]
[ "$(referral_rejection_message required)" = 'An invite is required; rerun with --ref CODE_OR_INVITE_URL' ]
[ "$(referral_rejection_message expired)" = 'This invite has expired; use a different invite' ]
[ "$(referral_rejection_message exhausted)" = 'All spots on this invite are taken; use a different invite' ]

REFERRAL_CODE="$code"
CURL_RESPONSE=""
CURL_FAIL=0
curl() {
  if [ "$CURL_FAIL" -eq 1 ]; then
    return 22
  fi
  printf '%s' "$CURL_RESPONSE"
}
log() { printf 'LOG:%s\n' "$*" >&2; }
die() {
  local status="$1"
  shift
  printf 'DIE:%s\n' "$*" >&2
  exit "$status"
}

assert_advisory_allows() {
  local response="$1"
  local output
  output="$(CURL_RESPONSE="$response" advisory_validate_referral "https://coordinator.example.test" 2>&1)"
  case "$output" in
    *DIE:*) echo "advisory response unexpectedly rejected: $output" >&2; exit 1 ;;
  esac
}

assert_advisory_rejects() {
  local response="$1" expected="$2" output status
  set +e
  output="$(CURL_RESPONSE="$response" advisory_validate_referral "https://coordinator.example.test" 2>&1)"
  status=$?
  set -e
  [ "$status" -eq 7 ] || {
    echo "advisory response status=$status, expected 7: $output" >&2
    exit 1
  }
  case "$output" in
    *"$expected"*) ;;
    *) echo "advisory rejection missing '$expected': $output" >&2; exit 1 ;;
  esac
}

assert_advisory_allows '{"required":false,"valid":true,"reason":"disabled"}'
assert_advisory_allows '{not-json'
assert_advisory_allows '{"required":"true","valid":false,"reason":"missing"}'
assert_advisory_allows '{"required":true,"valid":"false","reason":"missing"}'
assert_advisory_allows '{"required":true,"valid":false,"reason":"surprise"}'
assert_advisory_rejects '{"required":true,"valid":false,"reason":"missing"}' 'rerun with --ref CODE_OR_INVITE_URL'
assert_advisory_rejects '{"required":true,"valid":false,"reason":"invalid"}' 'not valid'
assert_advisory_rejects '{"required":true,"valid":false,"reason":"expired"}' 'expired'
assert_advisory_rejects '{"required":true,"valid":false,"reason":"revoked"}' 'no longer available'
assert_advisory_rejects '{"required":true,"valid":false,"reason":"exhausted"}' 'All spots'

for failure in timeout http_5xx; do
  output="$(CURL_FAIL=1 advisory_validate_referral "https://coordinator.example.test" 2>&1)"
  case "$output" in
    *'Invite pre-check unavailable'*) ;;
    *) echo "$failure did not remain advisory: $output" >&2; exit 1 ;;
  esac
done

# Both `--ref` and MACPROVIDER_REFERRAL_CODE populate REFERRAL_CODE before this
# shared normalization point.
# shellcheck disable=SC2016 # Assert the installer's literal command substitution.
grep -F 'REFERRAL_CODE="$(normalize_referral_code "$REFERRAL_CODE")"' "$INSTALL_SH" >/dev/null
grep -F 'Usage: bash install.sh [--dry-run] [--ref CODE_OR_INVITE_URL]' "$INSTALL_SH" >/dev/null

echo "installer referral input normalization ok"
