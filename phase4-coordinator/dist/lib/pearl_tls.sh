#!/usr/bin/env bash
# pearl_tls.sh — TLS classification + planning + messaging for the
# Pearl VPS deploy script. Sourced from deploy-pearl-vps.sh; also
# sourced by check_pearl_tls_test.sh for fixture-driven unit testing.
#
# Design constraints:
#   - bash 3.2 compatible (Pearl runs Ubuntu with bash 5, but the
#     operator Mac runs bash 3.2; the deploy script executes on the
#     operator Mac and shells out to Pearl via SSH).
#   - No `declare -A`, no `mapfile`, no `readarray` — 3.2 lacks all.
#   - Parallel arrays with linear scan (the domain set is 2, later
#     3 if a third public hostname is added).
#   - Pure functions: no side effects except population of documented
#     global arrays, no `set -e` reliance for control flow, no `exit`
#     (callers handle exit; caller may be a test that continues past
#     a failure so it can assert on downstream state).
#
# Globals populated by pearl_tls_classify (all reset each call):
#   DOMAINS_HAVE_CERT   — HAVE-state domains (no work needed)
#   DOMAINS_NEED_CERT   — RENEW/EXPIRED/MISSING (certbot targets)
#   DOMAINS_NEED_STUB   — EXPIRED/MISSING (install ACME stub)
#   DOMAINS_STATE_KEYS  — parallel-array keys (domains)
#   DOMAINS_STATE_VALS  — parallel-array values (states)
#
# Globals populated by pearl_tls_plan_full_tls:
#   DOMAINS_FULL_TLS    — HAVE ∪ ISSUED_OK
#
# Globals populated by pearl_tls_check_issuance_failures:
#   PEARL_TLS_PRIMARY_FAILED    — 0 or 1
#   PEARL_TLS_NONPRIMARY_FAILED — 0 or 1

# pearl_tls_remote_probe_script
#   Emits the shell script that must run on the REMOTE Pearl host to
#   classify each domain's cert state. The caller pipes it into
#   `ssh <host> bash -s -- <domain1> <domain2> ...`. Emitting as a
#   function (not a heredoc inside the caller) lets tests exercise
#   this exact same script under a controlled `/etc/letsencrypt/`
#   fake.
pearl_tls_remote_probe_script() {
  cat <<'REMOTE_PROBE'
set -e
if ! command -v openssl >/dev/null 2>&1; then
  echo "ABORT openssl-missing-on-remote" >&2
  exit 1
fi
for d in "$@"; do
  full="/etc/letsencrypt/live/$d/fullchain.pem"
  priv="/etc/letsencrypt/live/$d/privkey.pem"
  if [ -f "$full" ] && [ -f "$priv" ]; then
    # Split RENEW (still valid right now) from EXPIRED (already
    # expired or malformed). EXPIRED behaves like MISSING.
    if ! openssl x509 -checkend 0 -noout -in "$full" >/dev/null 2>&1; then
      echo "EXPIRED $d"
    elif openssl x509 -checkend 86400 -noout -in "$full" >/dev/null 2>&1; then
      echo "HAVE $d"
    else
      echo "RENEW $d"
    fi
  else
    echo "MISSING $d"
  fi
done
REMOTE_PROBE
}

# pearl_tls_classify <status_text>
#   Parses the STDOUT of the remote probe (one "<STATE> <DOMAIN>"
#   line per expected domain), validates format + coverage + no
#   duplicates + no unexpected domains, and populates the 5 output
#   globals listed above. Reads DOMAINS_ALL as input (the expected
#   domain set).
#
#   Returns 0 on success; on validation failure, echoes the
#   diagnostic to stderr and returns non-zero. Does NOT exit — the
#   caller decides whether the failure is fatal (deploy: yes; test:
#   assert on stderr).
pearl_tls_classify() {
  local status_text="$1"

  DOMAINS_HAVE_CERT=()
  DOMAINS_NEED_CERT=()
  DOMAINS_NEED_STUB=()
  DOMAINS_STATE_KEYS=()
  DOMAINS_STATE_VALS=()

  local _seen=()  # parallel array, linear scan (bash 3.2 — no declare -A)
  local line status domain extra found expected d s k
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    read -r status domain extra <<<"$line"
    if [ -n "$extra" ]; then
      echo "aborting deploy: malformed cert-status line (extra field): '$line'" >&2
      return 1
    fi
    case "$status" in
      HAVE|RENEW|EXPIRED|MISSING) ;;
      *) echo "aborting deploy: unknown cert-status state: '$status' in '$line'" >&2; return 1 ;;
    esac
    expected=0
    for d in ${DOMAINS_ALL[@]+"${DOMAINS_ALL[@]}"}; do
      [ "$d" = "$domain" ] && expected=1 && break
    done
    if [ "$expected" -ne 1 ]; then
      echo "aborting deploy: unexpected domain in cert-status: '$domain'" >&2
      return 1
    fi
    # bash 3.2 + set -u: guard empty-array expansion with ${arr[@]+...}.
    for s in ${_seen[@]+"${_seen[@]}"}; do
      if [ "$s" = "$domain" ]; then
        echo "aborting deploy: duplicate cert-status line for: '$domain'" >&2
        return 1
      fi
    done
    _seen+=("$domain")
    DOMAINS_STATE_KEYS+=("$domain")
    DOMAINS_STATE_VALS+=("$status")
    case "$status" in
      HAVE)
        DOMAINS_HAVE_CERT+=("$domain")
        ;;
      RENEW)
        # Currently-valid cert; certbot renews, but do NOT install
        # the stub — the existing vhost stays so a certbot failure
        # leaves the soon-expiring cert serving instead of replacing
        # it with an HTTP-only stub.
        DOMAINS_NEED_CERT+=("$domain")
        ;;
      EXPIRED|MISSING)
        # No usable cert today: stub install is safe (no working
        # TLS vhost to clobber) and needed (so certbot webroot has
        # a /.well-known/acme-challenge/ listener). Always install
        # the stub.
        DOMAINS_NEED_CERT+=("$domain")
        DOMAINS_NEED_STUB+=("$domain")
        ;;
    esac
  done <<< "$status_text"

  # Coverage check — every expected domain accounted for.
  for d in ${DOMAINS_ALL[@]+"${DOMAINS_ALL[@]}"}; do
    found=0
    for s in ${_seen[@]+"${_seen[@]}"}; do
      [ "$s" = "$d" ] && found=1 && break
    done
    if [ "$found" -eq 0 ]; then
      echo "aborting deploy: cert-status missing for domain: '$d'" >&2
      return 1
    fi
  done
  return 0
}

# pearl_tls_prior_state <domain>
#   Echoes the classified prior state for <domain> (or empty if
#   not found). Reads DOMAINS_STATE_KEYS / DOMAINS_STATE_VALS.
pearl_tls_prior_state() {
  local target="$1" i k
  i=0
  for k in ${DOMAINS_STATE_KEYS[@]+"${DOMAINS_STATE_KEYS[@]}"}; do
    if [ "$k" = "$target" ]; then
      echo "${DOMAINS_STATE_VALS[$i]}"
      return 0
    fi
    i=$((i+1))
  done
  echo ""
  return 0
}

# pearl_tls_certbot_fail_warn <domain>
#   Echoes the state-aware WARN line body for a certbot-failed
#   domain. Caller wraps with its own "    WARN: certbot failed …"
#   preamble if needed. This function returns the fully-formatted
#   line matching the deploy script's pre-extraction output.
pearl_tls_certbot_fail_warn() {
  local d="$1"
  local prior_state
  prior_state=$(pearl_tls_prior_state "$d")
  case "$prior_state" in
    RENEW)
      echo "WARN: certbot failed for $d (was RENEW) — existing full TLS vhost left in place; soon-expiring cert keeps serving until next deploy"
      ;;
    EXPIRED|MISSING)
      echo "WARN: certbot failed for $d (was $prior_state) — ACME stub left in place; HTTPS unavailable for $d until next deploy"
      ;;
    *)
      echo "WARN: certbot failed for $d (state=$prior_state) — continuing deploy"
      ;;
  esac
}

# pearl_tls_plan_full_tls
#   Populates DOMAINS_FULL_TLS = DOMAINS_HAVE_CERT ∪ DOMAINS_ISSUED_OK.
#   Caller ensures DOMAINS_HAVE_CERT + DOMAINS_ISSUED_OK are set (may
#   be empty).
pearl_tls_plan_full_tls() {
  DOMAINS_FULL_TLS=(${DOMAINS_HAVE_CERT[@]+"${DOMAINS_HAVE_CERT[@]}"} ${DOMAINS_ISSUED_OK[@]+"${DOMAINS_ISSUED_OK[@]}"})
}

# pearl_tls_check_issuance_failures <primary_domain>
#   Reads DOMAINS_ISSUED_FAIL. Sets PEARL_TLS_PRIMARY_FAILED and
#   PEARL_TLS_NONPRIMARY_FAILED to 0/1.
pearl_tls_check_issuance_failures() {
  local primary_domain="$1" d
  PEARL_TLS_PRIMARY_FAILED=0
  PEARL_TLS_NONPRIMARY_FAILED=0
  for d in ${DOMAINS_ISSUED_FAIL[@]+"${DOMAINS_ISSUED_FAIL[@]}"}; do
    if [ "$d" = "$primary_domain" ]; then
      PEARL_TLS_PRIMARY_FAILED=1
    else
      PEARL_TLS_NONPRIMARY_FAILED=1
    fi
  done
}

# pearl_tls_primary_abort_msg <primary_domain>
#   Echoes the multi-line ABORT-EXIT message for a primary-domain
#   cert-issuance failure, state-aware on prior state.
pearl_tls_primary_abort_msg() {
  local primary_domain="$1"
  local prior_state
  prior_state=$(pearl_tls_prior_state "$primary_domain")
  echo ""
  echo "  ABORT-EXIT: primary domain $primary_domain failed cert issuance during this deploy."
  case "$prior_state" in
    RENEW)
      echo "             Prior state was RENEW — existing TLS vhost left in place;"
      echo "             soon-expiring cert keeps serving until next deploy."
      echo "             Fix DNS/certbot and re-run; do not wait beyond cert expiry."
      ;;
    EXPIRED|MISSING)
      echo "             Prior state was $prior_state — ACME stub is in place;"
      echo "             HTTPS is unavailable on $primary_domain until DNS/certbot is fixed"
      echo "             and this script is re-run."
      ;;
    *)
      echo "             Prior state was $prior_state — re-run after fixing DNS/certbot."
      ;;
  esac
  echo "             Coordinator binary NOT restarted — old binary still serving."
}
