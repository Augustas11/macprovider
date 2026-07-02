#!/usr/bin/env bash
# check_pearl_tls_test.sh — fixture-driven tests for the extracted
# TLS state machine in dist/lib/pearl_tls.sh. Issue #291.
#
# Coverage matrix (all cells run without a real VPS):
#   T01 HAVE + HAVE            → no stub, no certbot
#   T02 RENEW + HAVE           → certbot for RENEW, no stub, HAVE full TLS
#   T03 EXPIRED + HAVE         → stub + certbot for EXPIRED
#   T04 MISSING + HAVE         → stub + certbot for MISSING
#   T05 EXPIRED + MISSING      → stub + certbot for both
#   T06 RENEW + RENEW          → certbot both, no stubs
#   T07 primary MISSING + certbot fail   → PRIMARY_FAILED=1
#   T08 non-primary MISSING + fail       → NONPRIMARY_FAILED=1
#   T09 plan_full_tls picks HAVE ∪ ISSUED_OK, drops ISSUED_FAIL
#   T10 certbot_fail_warn: RENEW  → "was RENEW … keeps serving"
#   T11 certbot_fail_warn: MISSING → "was MISSING … HTTPS unavailable"
#   T12 primary_abort_msg RENEW  → mentions "existing TLS vhost left"
#   T13 primary_abort_msg MISSING → mentions "ACME stub is in place"
#   T14 malformed cert-status line (extra field) → non-zero + stderr
#   T15 unknown state token → non-zero + stderr
#   T16 unexpected domain → non-zero + stderr
#   T17 duplicate domain line → non-zero + stderr
#   T18 coverage gap (missing expected domain) → non-zero + stderr
#   T19 bash 3.2 + set -u: empty DOMAINS_ISSUED_FAIL iteration
#   T20 remote probe script: HAVE fixture (openssl -checkend passes)
#   T21 remote probe script: EXPIRED fixture (openssl -checkend fails)
#   T22 remote probe script: MISSING fixture (files absent)
#   T23 remote probe script: RENEW fixture (valid <86400s remaining)
#   T24 remote probe script: openssl missing → ABORT
#
# Run: bash phase4-coordinator/dist/test/check_pearl_tls_test.sh
# Exit: 0 all-pass, 1 any-fail.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../lib/pearl_tls.sh"
if [ ! -f "$LIB" ]; then
  echo "FAIL: lib not found at $LIB" >&2
  exit 1
fi
# shellcheck source=../lib/pearl_tls.sh
. "$LIB"

PASS=0
FAIL=0
LOG=""

_assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS+1))
    LOG="${LOG}  PASS  $name
"
  else
    FAIL=$((FAIL+1))
    LOG="${LOG}  FAIL  $name
        expected: '$expected'
        actual:   '$actual'
"
  fi
}

_assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*)
      PASS=$((PASS+1))
      LOG="${LOG}  PASS  $name
"
      ;;
    *)
      FAIL=$((FAIL+1))
      LOG="${LOG}  FAIL  $name
        expected substring: '$needle'
        in:                 '$haystack'
"
      ;;
  esac
}

_reset() {
  DOMAINS_ALL=("$@")
  DOMAINS_HAVE_CERT=()
  DOMAINS_NEED_CERT=()
  DOMAINS_NEED_STUB=()
  DOMAINS_STATE_KEYS=()
  DOMAINS_STATE_VALS=()
  DOMAINS_ISSUED_OK=()
  DOMAINS_ISSUED_FAIL=()
  DOMAINS_FULL_TLS=()
  PEARL_TLS_PRIMARY_FAILED=0
  PEARL_TLS_NONPRIMARY_FAILED=0
}

# T01 HAVE + HAVE → no stub, no certbot
_reset "coordinator.streamvc.live" "stats.streamvc.live"
pearl_tls_classify "HAVE coordinator.streamvc.live
HAVE stats.streamvc.live"
_assert_eq "T01 have_cert count"    "2" "${#DOMAINS_HAVE_CERT[@]}"
_assert_eq "T01 need_cert count"    "0" "${#DOMAINS_NEED_CERT[@]}"
_assert_eq "T01 need_stub count"    "0" "${#DOMAINS_NEED_STUB[@]}"

# T02 RENEW + HAVE → certbot RENEW, no stub
_reset "coordinator.streamvc.live" "stats.streamvc.live"
pearl_tls_classify "RENEW coordinator.streamvc.live
HAVE stats.streamvc.live"
_assert_eq "T02 have_cert count"    "1" "${#DOMAINS_HAVE_CERT[@]}"
_assert_eq "T02 need_cert count"    "1" "${#DOMAINS_NEED_CERT[@]}"
_assert_eq "T02 need_stub count"    "0" "${#DOMAINS_NEED_STUB[@]}"
_assert_eq "T02 need_cert domain"   "coordinator.streamvc.live" "${DOMAINS_NEED_CERT[0]}"

# T03 EXPIRED + HAVE → stub + certbot for EXPIRED
_reset "coordinator.streamvc.live" "stats.streamvc.live"
pearl_tls_classify "EXPIRED coordinator.streamvc.live
HAVE stats.streamvc.live"
_assert_eq "T03 have_cert count"    "1" "${#DOMAINS_HAVE_CERT[@]}"
_assert_eq "T03 need_cert count"    "1" "${#DOMAINS_NEED_CERT[@]}"
_assert_eq "T03 need_stub count"    "1" "${#DOMAINS_NEED_STUB[@]}"
_assert_eq "T03 need_stub domain"   "coordinator.streamvc.live" "${DOMAINS_NEED_STUB[0]}"

# T04 MISSING + HAVE → stub + certbot for MISSING
_reset "coordinator.streamvc.live" "stats.streamvc.live"
pearl_tls_classify "MISSING coordinator.streamvc.live
HAVE stats.streamvc.live"
_assert_eq "T04 need_stub count"    "1" "${#DOMAINS_NEED_STUB[@]}"
_assert_eq "T04 need_stub domain"   "coordinator.streamvc.live" "${DOMAINS_NEED_STUB[0]}"

# T05 EXPIRED + MISSING → stub for both, certbot for both
_reset "coordinator.streamvc.live" "stats.streamvc.live"
pearl_tls_classify "EXPIRED coordinator.streamvc.live
MISSING stats.streamvc.live"
_assert_eq "T05 have_cert count"    "0" "${#DOMAINS_HAVE_CERT[@]}"
_assert_eq "T05 need_cert count"    "2" "${#DOMAINS_NEED_CERT[@]}"
_assert_eq "T05 need_stub count"    "2" "${#DOMAINS_NEED_STUB[@]}"

# T06 RENEW + RENEW → certbot both, no stubs
_reset "coordinator.streamvc.live" "stats.streamvc.live"
pearl_tls_classify "RENEW coordinator.streamvc.live
RENEW stats.streamvc.live"
_assert_eq "T06 need_cert count"    "2" "${#DOMAINS_NEED_CERT[@]}"
_assert_eq "T06 need_stub count"    "0" "${#DOMAINS_NEED_STUB[@]}"

# T07 primary MISSING + certbot fail → PRIMARY_FAILED=1
_reset "coordinator.streamvc.live" "stats.streamvc.live"
pearl_tls_classify "MISSING coordinator.streamvc.live
HAVE stats.streamvc.live"
DOMAINS_ISSUED_FAIL=("coordinator.streamvc.live")
pearl_tls_check_issuance_failures "coordinator.streamvc.live"
_assert_eq "T07 primary_failed"     "1" "$PEARL_TLS_PRIMARY_FAILED"
_assert_eq "T07 nonprimary_failed"  "0" "$PEARL_TLS_NONPRIMARY_FAILED"

# T08 non-primary MISSING + fail → NONPRIMARY_FAILED=1
_reset "coordinator.streamvc.live" "stats.streamvc.live"
pearl_tls_classify "HAVE coordinator.streamvc.live
MISSING stats.streamvc.live"
DOMAINS_ISSUED_FAIL=("stats.streamvc.live")
pearl_tls_check_issuance_failures "coordinator.streamvc.live"
_assert_eq "T08 primary_failed"     "0" "$PEARL_TLS_PRIMARY_FAILED"
_assert_eq "T08 nonprimary_failed"  "1" "$PEARL_TLS_NONPRIMARY_FAILED"

# T09 plan_full_tls picks HAVE ∪ ISSUED_OK
_reset "coordinator.streamvc.live" "stats.streamvc.live"
pearl_tls_classify "RENEW coordinator.streamvc.live
HAVE stats.streamvc.live"
DOMAINS_ISSUED_OK=("coordinator.streamvc.live")
DOMAINS_ISSUED_FAIL=()
pearl_tls_plan_full_tls
_assert_eq "T09 full_tls count"     "2" "${#DOMAINS_FULL_TLS[@]}"

# T10 certbot_fail_warn: RENEW mentions "keeps serving"
_reset "coordinator.streamvc.live" "stats.streamvc.live"
pearl_tls_classify "RENEW coordinator.streamvc.live
HAVE stats.streamvc.live"
warn=$(pearl_tls_certbot_fail_warn "coordinator.streamvc.live")
_assert_contains "T10 renew warn" "was RENEW" "$warn"
_assert_contains "T10 renew warn body" "keeps serving" "$warn"

# T11 certbot_fail_warn: MISSING mentions "HTTPS unavailable"
_reset "coordinator.streamvc.live" "stats.streamvc.live"
pearl_tls_classify "MISSING coordinator.streamvc.live
HAVE stats.streamvc.live"
warn=$(pearl_tls_certbot_fail_warn "coordinator.streamvc.live")
_assert_contains "T11 missing warn" "was MISSING" "$warn"
_assert_contains "T11 missing warn body" "HTTPS unavailable" "$warn"

# T12 primary_abort_msg RENEW mentions "existing TLS vhost"
_reset "coordinator.streamvc.live" "stats.streamvc.live"
pearl_tls_classify "RENEW coordinator.streamvc.live
HAVE stats.streamvc.live"
abort=$(pearl_tls_primary_abort_msg "coordinator.streamvc.live")
_assert_contains "T12 abort RENEW" "existing TLS vhost left in place" "$abort"

# T13 primary_abort_msg MISSING mentions "ACME stub is in place"
_reset "coordinator.streamvc.live" "stats.streamvc.live"
pearl_tls_classify "MISSING coordinator.streamvc.live
HAVE stats.streamvc.live"
abort=$(pearl_tls_primary_abort_msg "coordinator.streamvc.live")
_assert_contains "T13 abort MISSING" "ACME stub is in place" "$abort"

# T14 malformed line (extra field) → non-zero + stderr mentions "extra field"
_reset "coordinator.streamvc.live" "stats.streamvc.live"
err=$(pearl_tls_classify "HAVE coordinator.streamvc.live extra
HAVE stats.streamvc.live" 2>&1) && rc=0 || rc=$?
_assert_eq "T14 rc"       "1" "$rc"
_assert_contains "T14 stderr" "extra field" "$err"

# T15 unknown state token → non-zero
_reset "coordinator.streamvc.live" "stats.streamvc.live"
err=$(pearl_tls_classify "BOGUS coordinator.streamvc.live
HAVE stats.streamvc.live" 2>&1) && rc=0 || rc=$?
_assert_eq "T15 rc"       "1" "$rc"
_assert_contains "T15 stderr" "unknown cert-status state" "$err"

# T16 unexpected domain → non-zero
_reset "coordinator.streamvc.live" "stats.streamvc.live"
err=$(pearl_tls_classify "HAVE some.other.host
HAVE stats.streamvc.live" 2>&1) && rc=0 || rc=$?
_assert_eq "T16 rc"       "1" "$rc"
_assert_contains "T16 stderr" "unexpected domain" "$err"

# T17 duplicate line → non-zero
_reset "coordinator.streamvc.live" "stats.streamvc.live"
err=$(pearl_tls_classify "HAVE coordinator.streamvc.live
HAVE coordinator.streamvc.live" 2>&1) && rc=0 || rc=$?
_assert_eq "T17 rc"       "1" "$rc"
_assert_contains "T17 stderr" "duplicate cert-status line" "$err"

# T18 coverage gap → non-zero
_reset "coordinator.streamvc.live" "stats.streamvc.live"
err=$(pearl_tls_classify "HAVE coordinator.streamvc.live" 2>&1) && rc=0 || rc=$?
_assert_eq "T18 rc"       "1" "$rc"
_assert_contains "T18 stderr" "cert-status missing for domain" "$err"

# T19 bash-3.2 + set -u guard: empty DOMAINS_ISSUED_FAIL iteration doesn't unbound
_reset "coordinator.streamvc.live" "stats.streamvc.live"
pearl_tls_classify "HAVE coordinator.streamvc.live
HAVE stats.streamvc.live"
DOMAINS_ISSUED_FAIL=()
# Turn set -u on locally to prove the ${arr[@]+"${arr[@]}"} guard works
(set -u; pearl_tls_check_issuance_failures "coordinator.streamvc.live") && rc=0 || rc=$?
_assert_eq "T19 empty-array under set -u" "0" "$rc"

# T20-T24 exercise the actual remote probe script against local fixtures.
# The probe script does openssl x509 -checkend on ${d}/fullchain.pem
# under /etc/letsencrypt/live. We can't touch /etc as a test user, but
# we can drive the script directly by faking `openssl` via PATH shim
# and by short-circuiting the file existence checks with a fake
# /etc/letsencrypt tree using LETSENCRYPT_ROOT override — the script
# has no such env, so we drive it through a tmp-dir fixture with a
# minimal `bash -c` harness that substitutes the /etc/letsencrypt/
# prefix. Instead of a PATH shim, we feed the script real cert bytes
# for HAVE/RENEW/EXPIRED and rely on real openssl.
_probe_fixture_dir=$(mktemp -d -t pearl_tls_test.XXXXXXXX)
trap 'rm -rf "$_probe_fixture_dir"' EXIT

_gen_cert() {
  # Args: <days_valid> <out_dir> — writes fullchain.pem + privkey.pem.
  # For expired fixtures, pass a negative-or-zero days value; the
  # helper signs via `openssl x509 -req -days 0` so notAfter equals
  # notBefore = now, making the cert immediately expired.
  local days="$1" dir="$2"
  mkdir -p "$dir"
  if [ "$days" -le 0 ]; then
    # Two-step: CSR + sign with -days 0 (notAfter=now → -checkend 0 fails)
    local csr="$dir/csr.pem"
    openssl req -newkey rsa:2048 -keyout "$dir/privkey.pem" -out "$csr" \
      -nodes -subj "/CN=test" >/dev/null 2>&1
    openssl x509 -req -in "$csr" -signkey "$dir/privkey.pem" -days 0 \
      -out "$dir/fullchain.pem" >/dev/null 2>&1
    rm -f "$csr"
  else
    openssl req -x509 -newkey rsa:2048 -keyout "$dir/privkey.pem" \
      -out "$dir/fullchain.pem" -sha256 -days "$days" -nodes \
      -subj "/CN=test" >/dev/null 2>&1
  fi
}

# Rewrite the probe script to use fixture root instead of /etc/letsencrypt.
_run_probe() {
  local fixture_root="$1"
  shift  # remaining args are domains
  local probe
  probe=$(pearl_tls_remote_probe_script | \
    sed "s|/etc/letsencrypt/live|$fixture_root/live|g")
  bash -c "$probe" -- "$@"
}

# T20 HAVE fixture: fullchain valid for 90 days
_gen_cert 90 "$_probe_fixture_dir/live/have.example"
out=$(_run_probe "$_probe_fixture_dir" "have.example" 2>&1)
_assert_eq "T20 HAVE" "HAVE have.example" "$out"

# T21 EXPIRED fixture: cert issued with -days 0 is invalid now (past yesterday)
_gen_cert -1 "$_probe_fixture_dir/live/expired.example"
out=$(_run_probe "$_probe_fixture_dir" "expired.example" 2>&1)
_assert_eq "T21 EXPIRED" "EXPIRED expired.example" "$out"

# T22 MISSING fixture: dir does not exist
out=$(_run_probe "$_probe_fixture_dir" "no-such.example" 2>&1)
_assert_eq "T22 MISSING" "MISSING no-such.example" "$out"

# T23 RENEW fixture: cert is valid right now but expires < 86400s from now.
# Generate a cert valid 1 day (86400s), sleep briefly so <86400 remains.
_gen_cert 1 "$_probe_fixture_dir/live/renew.example"
# 1-day cert has exactly 86400s left immediately; -checkend 86400 tests
# for MORE than 86400. So a 1-day cert should classify as RENEW right
# after creation (< 86400s strictly remaining).
sleep 2
out=$(_run_probe "$_probe_fixture_dir" "renew.example" 2>&1)
_assert_eq "T23 RENEW" "RENEW renew.example" "$out"

# T24 openssl missing: run probe with PATH set to a dir that lacks
# openssl so `command -v openssl` returns non-zero. Use a full path
# to bash directly (invoking `bash` via env would need bash on PATH,
# defeating the purpose).
_empty_dir="$_probe_fixture_dir/empty_path"
mkdir -p "$_empty_dir"
_bash_exe="$(command -v bash)"
probe_text=$(pearl_tls_remote_probe_script | sed "s|/etc/letsencrypt/live|$_probe_fixture_dir/live|g")
out=$(PATH="$_empty_dir" "$_bash_exe" -c "$probe_text" -- "have.example" 2>&1) && rc=0 || rc=$?
_assert_eq "T24 rc"       "1" "$rc"
_assert_contains "T24 stderr" "ABORT openssl-missing-on-remote" "$out"

# ---- summary ----
printf '%s\n' "$LOG"
printf 'pearl_tls_test: %d pass, %d fail\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
