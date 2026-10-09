#!/usr/bin/env bash
# Mocked runtime checks for anonymous release-asset download retry behavior.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
verifier="$root/scripts/verify-anonymous-release-discovery.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/anonymous-release-discovery-download.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
prefix="$tmp/download-prefix.sh"
awk '/^listing_attempts=/{exit} {print}' "$verifier" > "$prefix"

fail() {
  printf '[test-anonymous-release-discovery-download] ERROR: %s\n' "$*" >&2
  exit 1
}

cat > "$tmp/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
state_dir="${CURL_STUB_STATE:?}"
scenario="${CURL_STUB_SCENARIO:?}"
count_file="$state_dir/count"
count=0
[ ! -f "$count_file" ] || count="$(cat "$count_file")"
count=$((count + 1))
printf '%s' "$count" > "$count_file"
headers=""
out=""
write=""
url=""
max_time=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    *Authorization*|*github-api-curl.conf*)
      echo "anonymous download received auth-bearing curl argument: $1" >&2
      exit 9
      ;;
  esac
  case "$1" in
    -D) headers="$2"; shift ;;
    -o) out="$2"; shift ;;
    -w) write="$2"; shift ;;
    --max-time) max_time="$2"; shift ;;
    --connect-timeout) shift ;;
    -H|--config|--retry|--retry-delay|--retry-max-time|--proto) shift ;;
    --show-error|--silent|--location|--tlsv1.2|--fail|--retry-all-errors) ;;
    http*) url="$1" ;;
  esac
  shift
done
[ -n "$headers" ] || { echo "missing -D" >&2; exit 9; }
[ -n "$out" ] || { echo "missing -o" >&2; exit 9; }
[ -n "$write" ] || { echo "missing -w" >&2; exit 9; }
printf '%s\n' "${max_time:-}" >> "$state_dir/max-times"
: > "$headers"
status=200
body="ok"
case "$scenario" in
  403-then-200)
    if [ "$count" -eq 1 ]; then status=403; body=forbidden; fi
    ;;
  404)
    status=404; body=missing
    ;;
  429-retry-after)
    if [ "$count" -eq 1 ]; then
      status=429
      body=throttled
      printf 'retry-after: 1\r\n' > "$headers"
    fi
    ;;
  503-then-200)
    if [ "$count" -eq 1 ]; then status=503; body=unavailable; fi
    ;;
  budget-exhausted)
    status=429
    body=throttled
    printf 'retry-after: 99\r\n' > "$headers"
    ;;
  transport-then-200)
    if [ "$count" -eq 1 ]; then
      printf '000'
      exit 56
    fi
    ;;
  *) echo "unknown scenario $scenario" >&2; exit 9 ;;
esac
printf '%s\n' "$body" > "$out"
printf '%s' "$status"
SH
chmod +x "$tmp/curl"

run_probe() {
  local scenario="$1" budget="${2:-5}" max_time="${3:-2}" rc=0
  rm -f "$tmp/count" "$tmp/max-times" "$tmp/out" "$tmp/err"
  (
    PATH="$tmp:$PATH" \
    CURL_STUB_STATE="$tmp" \
    CURL_STUB_SCENARIO="$scenario" \
    MACPROVIDER_DISCOVERY_ASSET_WAIT_SECONDS="$budget" \
    MACPROVIDER_DISCOVERY_ASSET_CURL_MAX_TIME_SECONDS="$max_time" \
    bash -c '
      set -euo pipefail
      prefix_file="$1"
      out_file="$2"
      set -- v1.2.3 0123456789abcdef0123456789abcdef01234567 v1.2.3 release-discovery-v1-1
      # shellcheck source=/dev/null
      . "$prefix_file"
      anonymous_download https://example.invalid/asset "$out_file"
    ' bash "$prefix" "$tmp/out"
  ) >"$tmp/stdout" 2>"$tmp/err" || rc=$?
  printf '%s' "$rc"
}

[ "$(run_probe 403-then-200)" = 0 ] || fail "403 followed by 200 must succeed"
[ "$(cat "$tmp/count")" = 2 ] || fail "403 followed by 200 should use two attempts"
grep -Fqx ok "$tmp/out" || fail "403 followed by 200 did not persist the successful body"

[ "$(run_probe 429-retry-after)" = 0 ] || fail "429 Retry-After followed by 200 must succeed"
grep -Fq 'anonymous download HTTP 429; waiting 1s' "$tmp/err" ||
  fail "429 Retry-After was not honored"

[ "$(run_probe 503-then-200)" = 0 ] || fail "503 followed by 200 must succeed"
[ "$(cat "$tmp/count")" = 2 ] || fail "503 followed by 200 should use two attempts"

if [ "$(run_probe 404)" = 0 ]; then
  fail "permanent 404 must fail closed"
fi
grep -Fq 'anonymous download returned HTTP 404' "$tmp/err" ||
  fail "404 failure did not name the HTTP status"

if [ "$(run_probe budget-exhausted 2)" = 0 ]; then
  fail "Retry-After beyond the budget must fail"
fi
grep -Fq 'after 2s' "$tmp/err" || fail "budget exhaustion did not name the budget"

[ "$(run_probe transport-then-200)" = 0 ] || fail "transient transport failure followed by 200 must succeed"
[ "$(cat "$tmp/count")" = 2 ] || fail "transport transient should use two attempts"

run_probe 403-then-200 5 9 >/dev/null
first_max_time="$(head -n 1 "$tmp/max-times")"
[ "$first_max_time" -le 5 ] || fail "curl --max-time exceeded remaining wall-clock budget"

printf '[test-anonymous-release-discovery-download] ok: anonymous asset retries are deadline-bounded\n'
