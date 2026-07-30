#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

awk '
  /^record_lifecycle_state\(\)/ { emit = 1 }
  emit { print }
  emit && /^\}$/ { exit }
' "$INSTALL_SH" > "$TMP/function.sh"

# shellcheck source=/dev/null
. "$TMP/function.sh"

cat > "$TMP/installed-cli" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$INSTALLED_LOG"
exit 64
EOF
cat > "$TMP/staged-cli" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STAGED_LOG"
EOF
chmod +x "$TMP/installed-cli" "$TMP/staged-cli"

BINARY_PATH="$TMP/installed-cli"
MACPROVIDER_CLI_EXECUTABLE="$TMP/staged-cli"
LIFECYCLE_STAGED_CLI_TRUSTED=0
INSTALLED_LOG="$TMP/installed.log"
STAGED_LOG="$TMP/staged.log"
export INSTALLED_LOG STAGED_LOG
DRY_RUN=0
EMERGENCY_ROLLBACK=0
LIFECYCLE_INSTALL_OPERATION_ID="install:test"
provider_id="mac"
model="qwen3-coder-30b-a3b-instruct"

set +e
record_lifecycle_state rollback_in_progress install_admission_failed
untrusted_rc=$?
set -e
[ "$untrusted_rc" -eq 1 ] || {
  printf 'pre-contract incumbent returned unexpected lifecycle status %s\n' "$untrusted_rc" >&2
  exit 1
}
[ -e "$INSTALLED_LOG" ] || {
  echo "incumbent CLI was not retained before staged identity validation" >&2
  exit 1
}
[ ! -e "$STAGED_LOG" ] || {
  echo "untrusted staged CLI received the lifecycle transition" >&2
  exit 1
}
rm -f "$INSTALLED_LOG"

LIFECYCLE_STAGED_CLI_TRUSTED=1
record_lifecycle_state rollback_in_progress install_admission_failed

[ ! -e "$INSTALLED_LOG" ] || {
  echo "installed pre-contract CLI received the lifecycle transition" >&2
  exit 1
}
cat > "$TMP/expected.log" <<'EOF'
lifecycle-state
transition
--state
rollback_in_progress
--reason-code
install_admission_failed
--writer
installer
--operation-id
install:test
--provider-id
mac
--model-id
qwen3-coder-30b-a3b-instruct
EOF
diff -u "$TMP/expected.log" "$STAGED_LOG"

python3 - "$INSTALL_SH" <<'PY'
import pathlib
import sys

script = pathlib.Path(sys.argv[1]).read_text()
main = script[script.index("main() {"):]
stage = main.index("stage_release_payload")
validate = main.index("validate_acceptance_staged_identity", stage)
quarantine = main.index("clear_quarantine", validate)
trust = main.index("LIFECYCLE_STAGED_CLI_TRUSTED=1", quarantine)
if not stage < validate < quarantine < trust:
    raise SystemExit("staged lifecycle CLI trust is not gated by acceptance identity validation")
PY

awk '
  /^use_fresh_recommendation_if_available\(\)/ { emit = 1 }
  emit { print }
  emit && /^\}$/ { exit }
' "$INSTALL_SH" > "$TMP/preflight.sh"

# shellcheck source=/dev/null
. "$TMP/preflight.sh"

CONFIG_PATH="$TMP/config.yaml"
printf 'model: qwen3-coder-30b-a3b-instruct\n' > "$CONFIG_PATH"
DRY_RUN=0
run_macprovider_cli_with_amfi_retry() { return 12; }
log() { :; }
die() {
  local code="$1"
  shift
  printf '%s\n' "$*" > "$TMP/die.log"
  exit "$code"
}

set +e
( use_fresh_recommendation_if_available )
preflight_rc=$?
set -e
[ "$preflight_rc" -eq 6 ] || {
  printf 'catalog trust block returned %s instead of failing pre-cutover\n' "$preflight_rc" >&2
  exit 1
}
grep -F 'recommendation freshness check failed before service start' "$TMP/die.log" >/dev/null

printf '[install-lifecycle-state-test] staged lifecycle writer and trust preflight selected\n'
