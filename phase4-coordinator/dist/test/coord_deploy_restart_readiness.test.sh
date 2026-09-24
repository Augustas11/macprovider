#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_SH="$SCRIPT_DIR/../deploy-pearl-vps.sh"
TMP="$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/coord-restart-ready-test.XXXXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

bash -n "$DEPLOY_SH"

awk '
  /# coordinator-restart-readiness-begin/ { capture=1; next }
  /# coordinator-restart-readiness-end/ { exit }
  capture { print }
' "$DEPLOY_SH" > "$TMP/readiness.sh"

grep -q 'coordinator_ready_deadline=.*+ 60' "$TMP/readiness.sh" ||
  fail "restart readiness lost its bounded 60-second deadline"
grep -q 'systemctl is-active --quiet macprovider-coordinator' "$TMP/readiness.sh" ||
  fail "restart readiness does not require an active coordinator unit"
grep -q 'coordinator_listener_ready 8443' "$TMP/readiness.sh" ||
  fail "restart readiness does not require port 8443"
grep -q 'coordinator_listener_ready 8444' "$TMP/readiness.sh" ||
  fail "restart readiness does not require port 8444"
grep -q 'http://127.0.0.1:8444/healthz' "$TMP/readiness.sh" ||
  fail "restart readiness does not require local coordinator health"
grep -q 'exit 1' "$TMP/readiness.sh" ||
  fail "restart readiness does not fail closed on timeout"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  is-active)
    if [ "${2:-}" = "--quiet" ]; then
      exit 0
    fi
    echo active
    ;;
  status)
    echo "mock coordinator status" >&2
    ;;
  *) exit 2 ;;
esac
EOF
cat > "$TMP/bin/ss" <<'EOF'
#!/usr/bin/env bash
attempt=$(cat "$READINESS_ATTEMPT")
if [ "$READINESS_MODE" = delayed ] && [ "$attempt" -ge 5 ]; then
  case "$*" in
    *8443*) echo 'LISTEN 0 4096 127.0.0.1:8443 0.0.0.0:*' ;;
    *8444*) echo 'LISTEN 0 4096 127.0.0.1:8444 0.0.0.0:*' ;;
    *)
      echo 'LISTEN 0 4096 127.0.0.1:8443 0.0.0.0:*'
      echo 'LISTEN 0 4096 127.0.0.1:8444 0.0.0.0:*'
      ;;
  esac
fi
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
attempt=$(cat "$READINESS_ATTEMPT")
[ "$READINESS_MODE" = delayed ] && [ "$attempt" -ge 5 ]
EOF
cat > "$TMP/bin/sleep" <<'EOF'
#!/usr/bin/env bash
attempt=$(cat "$READINESS_ATTEMPT")
printf '%s\n' "$((attempt + 1))" > "$READINESS_ATTEMPT"
EOF
cat > "$TMP/bin/date" <<'EOF'
#!/usr/bin/env bash
if [ "$READINESS_MODE" = timeout ]; then
  calls=$(cat "$READINESS_DATE_CALLS")
  printf '%s\n' "$((calls + 1))" > "$READINESS_DATE_CALLS"
  if [ "$calls" -eq 0 ]; then
    echo 0
  else
    echo 61
  fi
else
  cat "$READINESS_ATTEMPT"
fi
EOF
chmod +x "$TMP/bin/"*

run_readiness() {
  local mode="$1"
  printf '0\n' > "$TMP/attempt"
  printf '0\n' > "$TMP/date-calls"
  READINESS_MODE="$mode" \
    READINESS_ATTEMPT="$TMP/attempt" \
    READINESS_DATE_CALLS="$TMP/date-calls" \
    PATH="$TMP/bin:$PATH" \
    bash "$TMP/readiness.sh"
}

run_readiness delayed > "$TMP/delayed.out" 2> "$TMP/delayed.err" ||
  fail "delayed coordinator readiness should succeed within the deadline"
[ "$(cat "$TMP/attempt")" = 5 ] ||
  fail "delayed readiness did not retry until both listeners and health were ready"

if run_readiness timeout > "$TMP/timeout.out" 2> "$TMP/timeout.err"; then
  fail "missing listeners and health should fail closed at the deadline"
fi
grep -q 'did not become ready on ports 8443 and 8444 within 60 seconds' "$TMP/timeout.err" ||
  fail "timeout does not report the bounded readiness failure"

echo "PASS: coordinator restart waits for delayed listeners and health, then fails closed on timeout"
