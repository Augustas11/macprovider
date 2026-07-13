#!/usr/bin/env bash
# shellcheck disable=SC2034 # Globals are consumed by extracted installer functions.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

extract_function() {
  name="$1"
  awk -v start="${name}() {" '
    $0 == start { inside=1 }
    inside { print }
    inside && /^}$/ { exit }
  ' "$INSTALL_SH"
}

for function_name in \
  read_app_managed_provider_token run_macprovider_cli_with_amfi_retry \
  submit_required_hardware_evidence; do
  extract_function "$function_name" >> "$TMP/functions.sh"
done

# shellcheck source=/dev/null
source "$TMP/functions.sh"

die() {
  printf 'unexpected installer failure: %s\n' "$*" >&2
  exit "$1"
}
log() { :; }
sleep() { :; }

secret="$(printf 'ab%.0s' {1..32})"
APP_MANAGED_REPAIR=1
APP_MANAGED_PROVIDER_TOKEN_FD=3
APP_MANAGED_PROVIDER_TOKEN=""
exec 3<<<"$secret"
read_app_managed_provider_token
exec 3<&-
[ "$APP_MANAGED_PROVIDER_TOKEN" = "$secret" ]
if export -p | grep -F "$secret" >/dev/null; then
  echo "app-managed token became exported" >&2
  exit 1
fi

cat > "$TMP/macprovider-cli" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$TOKEN_FD_TEST_ARGS"
env > "$TOKEN_FD_TEST_ENV"
attempt=1
if [ -f "$TOKEN_FD_TEST_ATTEMPTS" ]; then
  attempt=$(( $(cat "$TOKEN_FD_TEST_ATTEMPTS") + 1 ))
fi
printf '%s\n' "$attempt" > "$TOKEN_FD_TEST_ATTEMPTS"
fd=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--token-fd" ]; then
    fd="${2:-}"
    break
  fi
  shift
done
[ "$fd" = "0" ] || exit 21
shasum -a 256 | awk '{print $1}' >> "$TOKEN_FD_TEST_DIGEST"
if [ "${TOKEN_FD_TEST_RETRY_ONCE:-0}" -eq 1 ] && [ "$attempt" -eq 1 ]; then
  exit 137
fi
SH
chmod +x "$TMP/macprovider-cli"

export TOKEN_FD_TEST_ARGS="$TMP/args"
export TOKEN_FD_TEST_ENV="$TMP/env"
export TOKEN_FD_TEST_DIGEST="$TMP/digest"
export TOKEN_FD_TEST_ATTEMPTS="$TMP/attempts"
export TOKEN_FD_TEST_RETRY_ONCE=1
MACPROVIDER_CLI_EXECUTABLE="$TMP/macprovider-cli"
CONFIG_PATH="$TMP/config.yaml"
submit_required_hardware_evidence

grep -F -- '--token-fd 0' "$TMP/args" >/dev/null
if grep -F "$secret" "$TMP/args" "$TMP/env" >/dev/null; then
  echo "app-managed token leaked through CLI argv or environment" >&2
  exit 1
fi
expected_digest="$(printf '%s' "$secret" | shasum -a 256 | awk '{print $1}')"
[ "$(cat "$TMP/attempts")" -eq 2 ]
[ "$(wc -l < "$TMP/digest" | tr -d ' ')" -eq 2 ]
awk -v expected="$expected_digest" '$0 != expected { exit 1 }' "$TMP/digest"

if (APP_MANAGED_REPAIR=0 APP_MANAGED_PROVIDER_TOKEN_FD=0 read_app_managed_provider_token) 2>/dev/null; then
  echo "standalone install accepted the app-only token descriptor" >&2
  exit 1
fi

echo "app-managed repair evidence token fd transport ok"
