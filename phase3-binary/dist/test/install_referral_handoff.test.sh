#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
installer="$root/phase3-binary/dist/install.sh"

python3 - "$installer" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")

capture = 'REFERRAL_CODE_SOURCE_FILE="${MACPROVIDER_REFERRAL_CODE_FILE:-}"'
unset = "unset MACPROVIDER_REFERRAL_CODE_FILE"
first_child = 'GITHUB_REPO="${MACPROVIDER_GITHUB_REPO:-Augustas11/macprovider}"'
assert capture in source
assert unset in source
assert source.index(capture) < source.index(unset) < source.index(first_child)

assert 'bootstrap_auth_args+=(--referral-code-file "$REFERRAL_CODE_SOURCE_FILE")' in source
assert 'run_macprovider_cli_with_amfi_retry "${bootstrap_auth_args[@]}"' in source
assert '20|21|22|23|24|25|26|27)' in source
main = source[source.rindex("\nmain() {"):]
assert main.index("prepare_fresh_referral_code") < main.index('tag="$(resolve_release_tag)"')
assert main.index("prepare_fresh_referral_code") < main.index('download_release "$tag"')
assert main.index("prepare_fresh_referral_code") < main.index("run_autotune_recommend_apply")
assert main.index("prepare_staged_config") < main.index("enable_fresh_referral_receipts")
assert main.index("enable_fresh_referral_receipts") < main.index(
    "use_fresh_recommendation_if_available"
)
publish = "publish_bootstrap_identity_for_rollback"
bootstrap = 'run_macprovider_cli_with_amfi_retry "${bootstrap_auth_args[@]}"'
ensure_start = source.index("ensure_provider_credentials()")
ensure_end = source.index("submit_required_hardware_evidence()", ensure_start)
ensure_source = source[ensure_start:ensure_end]
assert ensure_source.index(publish) < ensure_source.index(bootstrap)
prompt_start = source.index("prepare_fresh_referral_code()")
prompt_end = source.index("# v1.2.2", prompt_start)
prompt_source = source[prompt_start:prompt_end]
assert prompt_source.index('CREATED_REFERRAL_CODE_SOURCE_FILE=1') < prompt_source.index(
    'chmod -N "$referral_path"'
)
assert prompt_source.count("FRESH_REFERRAL_BOOTSTRAP=1") == 2
receipt_start = source.index("enable_fresh_referral_receipts()")
receipt_end = source.index("write_config()", receipt_start)
receipt_source = source[receipt_start:receipt_end]
assert '[ "$FRESH_REFERRAL_BOOTSTRAP" -eq 1 ] || return 0' in receipt_source
assert '"true"' in receipt_source

# The path may be passed to the CLI, but install.sh must never open, print,
# copy, hash, or persist the referral file itself.
for forbidden in (
    'cat "$REFERRAL_CODE_SOURCE_FILE"',
    'cp "$REFERRAL_CODE_SOURCE_FILE"',
    'log "$REFERRAL_CODE_SOURCE_FILE"',
    'printf "$REFERRAL_CODE_SOURCE_FILE"',
    'log "$referral_code"',
):
    assert forbidden not in source, forbidden
PY

lib="$(mktemp "${TMPDIR:-/tmp}/macprovider-install-referral-lib.XXXXXX")"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/macprovider-install-referral.XXXXXX")"
trap 'rm -f "$lib"; rm -rf "$workdir"' EXIT
sed -n '/^restart_safe_incumbent_present()/,/^# v1.2.2/p' "$installer" \
  | sed '$d' > "$lib"
sed -n '/^semantic_merge_config()/,/^write_config()/p' "$installer" \
  | sed '$d' >> "$lib"

die() {
  code="$1"
  shift
  printf '%s\n' "$*" >&2
  exit "$code"
}
log() { printf '[test] %s\n' "$*"; }
installed_provider_binary_path() {
  if [ -x "$INSTALL_DIR/macprovider-cli" ]; then
    printf '%s\n' "$INSTALL_DIR/macprovider-cli"
  elif [ -x "$BINARY_PATH" ]; then
    printf '%s\n' "$BINARY_PATH"
  fi
}
read_config_provider_id() {
  [ -f "$CONFIG_PATH" ] \
    && sed -n 's/^provider_id:[[:space:]]*//p' "$CONFIG_PATH" \
    | tr -d '"'
}
read_config_provider_token_line() {
  [ -f "$CONFIG_PATH" ] && grep '^provider_token[[:space:]]*:' "$CONFIG_PATH"
}
read_config_model() {
  [ -f "$CONFIG_PATH" ] \
    && sed -n 's/^model:[[:space:]]*//p' "$CONFIG_PATH" \
    | tr -d '"'
}

# shellcheck source=/dev/null
. "$lib"

valid_code="MAL1-S-key_1-issuer_1-AAAAAAAAAAAAAAAAAAAAAAAAAA"
INSTALL_DIR="$workdir/fresh/macprovider"
BINARY_PATH="$workdir/fresh/bin/macprovider-cli"
MANIFEST_PATH="$workdir/fresh/install_manifest.json"
PLIST_PATH="$workdir/fresh/live.streamvc.macprovider.plist"
PROVIDER_ID_PATH="$workdir/fresh/provider_id"
CONFIG_PATH="$workdir/fresh/config.yaml"
DRY_RUN=0
EMERGENCY_ROLLBACK=0
NO_PROMPT=0
REFERRAL_CODE_SOURCE_FILE=""
CREATED_REFERRAL_CODE_SOURCE_FILE=0
FRESH_REFERRAL_BOOTSTRAP=0
REFERRAL_REPLACE_INCUMBENT=0
read_line() { REPLY="$valid_code"; }

prepare_fresh_referral_code
[ "$CREATED_REFERRAL_CODE_SOURCE_FILE" -eq 1 ]
[ "$FRESH_REFERRAL_BOOTSTRAP" -eq 1 ]
[ -f "$REFERRAL_CODE_SOURCE_FILE" ] && [ ! -L "$REFERRAL_CODE_SOURCE_FILE" ]
[ "$(cat "$REFERRAL_CODE_SOURCE_FILE")" = "$valid_code" ]
[ "$(python3 - "$REFERRAL_CODE_SOURCE_FILE" <<'PY'
import os
import stat
import sys
info = os.lstat(sys.argv[1])
print(f"{stat.S_IMODE(info.st_mode):04o}:{info.st_uid}:{os.geteuid()}:{info.st_nlink}")
PY
)" = "0600:$(id -u):$(id -u):1" ]
case "$REFERRAL_CODE_SOURCE_FILE" in
  *"$valid_code"*) echo "referral code leaked into temporary path" >&2; exit 1 ;;
esac
if env | grep -Fq "$valid_code"; then
  echo "referral code leaked into child environment" >&2
  exit 1
fi

mkdir -p "$(dirname "$CONFIG_PATH")"
cat > "$CONFIG_PATH" <<'EOF'
model: "fresh/model"
enable_receipts: malformed
receipt_log_path: "/private/fresh-receipts.jsonl"
custom_block:
  nested: keep-fresh
EOF
provider_id="mp-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
coordinator_url="wss://coordinator.example/ws/provider"
PORT=18080
enable_fresh_referral_receipts
grep -Fx 'enable_receipts: true' "$CONFIG_PATH" >/dev/null
[ "$(grep -c '^enable_receipts:' "$CONFIG_PATH")" -eq 1 ]
grep -Fx 'receipt_log_path: "/private/fresh-receipts.jsonl"' "$CONFIG_PATH" >/dev/null
grep -Fx '  nested: keep-fresh' "$CONFIG_PATH" >/dev/null

rm -f "$REFERRAL_CODE_SOURCE_FILE"

supplied_file="$workdir/supplied-referral"
printf '%s' "$valid_code" > "$supplied_file"
chmod 600 "$supplied_file"
INSTALL_DIR="$workdir/supplied/macprovider"
BINARY_PATH="$workdir/supplied/bin/macprovider-cli"
MANIFEST_PATH="$workdir/supplied/install_manifest.json"
PLIST_PATH="$workdir/supplied/live.streamvc.macprovider.plist"
PROVIDER_ID_PATH="$workdir/supplied/provider_id"
CONFIG_PATH="$workdir/supplied/config.yaml"
NO_PROMPT=1
REFERRAL_CODE_SOURCE_FILE="$supplied_file"
CREATED_REFERRAL_CODE_SOURCE_FILE=0
FRESH_REFERRAL_BOOTSTRAP=0
prepare_fresh_referral_code
[ "$REFERRAL_CODE_SOURCE_FILE" = "$supplied_file" ]
[ "$CREATED_REFERRAL_CODE_SOURCE_FILE" -eq 0 ]
[ "$FRESH_REFERRAL_BOOTSTRAP" -eq 1 ]

set +e
missing_file_output="$(
  (
    INSTALL_DIR="$workdir/missing-file/macprovider"
    BINARY_PATH="$workdir/missing-file/bin/macprovider-cli"
    MANIFEST_PATH="$workdir/missing-file/install_manifest.json"
    PLIST_PATH="$workdir/missing-file/live.streamvc.macprovider.plist"
    PROVIDER_ID_PATH="$workdir/missing-file/provider_id"
    CONFIG_PATH="$workdir/missing-file/config.yaml"
    NO_PROMPT=1
    REFERRAL_CODE_SOURCE_FILE="$workdir/does-not-exist"
    CREATED_REFERRAL_CODE_SOURCE_FILE=0
    prepare_fresh_referral_code
  ) 2>&1
)"
missing_file_rc=$?
set -e
[ "$missing_file_rc" -eq 20 ] || {
  echo "missing supplied invite file returned $missing_file_rc, want 20" >&2
  exit 1
}
printf '%s' "$missing_file_output" | grep -Fq "invite code is required"

empty_file="$workdir/empty-referral"
: > "$empty_file"
chmod 600 "$empty_file"
set +e
empty_file_output="$(
  (
    INSTALL_DIR="$workdir/empty-file/macprovider"
    BINARY_PATH="$workdir/empty-file/bin/macprovider-cli"
    MANIFEST_PATH="$workdir/empty-file/install_manifest.json"
    PLIST_PATH="$workdir/empty-file/live.streamvc.macprovider.plist"
    PROVIDER_ID_PATH="$workdir/empty-file/provider_id"
    CONFIG_PATH="$workdir/empty-file/config.yaml"
    NO_PROMPT=1
    REFERRAL_CODE_SOURCE_FILE="$empty_file"
    CREATED_REFERRAL_CODE_SOURCE_FILE=0
    prepare_fresh_referral_code
  ) 2>&1
)"
empty_file_rc=$?
set -e
[ "$empty_file_rc" -eq 21 ] || {
  echo "empty supplied invite file returned $empty_file_rc, want 21" >&2
  exit 1
}
printf '%s' "$empty_file_output" | grep -Fq "owner-only 0600 regular file"

symlink_file="$workdir/symlink-referral"
ln -s "$supplied_file" "$symlink_file"
set +e
symlink_file_output="$(
  (
    INSTALL_DIR="$workdir/symlink-file/macprovider"
    BINARY_PATH="$workdir/symlink-file/bin/macprovider-cli"
    MANIFEST_PATH="$workdir/symlink-file/install_manifest.json"
    PLIST_PATH="$workdir/symlink-file/live.streamvc.macprovider.plist"
    PROVIDER_ID_PATH="$workdir/symlink-file/provider_id"
    CONFIG_PATH="$workdir/symlink-file/config.yaml"
    NO_PROMPT=1
    REFERRAL_CODE_SOURCE_FILE="$symlink_file"
    CREATED_REFERRAL_CODE_SOURCE_FILE=0
    prepare_fresh_referral_code
  ) 2>&1
)"
symlink_file_rc=$?
set -e
[ "$symlink_file_rc" -eq 21 ] || {
  echo "symlink supplied invite file returned $symlink_file_rc, want 21" >&2
  exit 1
}
printf '%s' "$symlink_file_output" | grep -Fq "owner-only 0600 regular file"

set +e
missing_output="$(
  (
    INSTALL_DIR="$workdir/missing/macprovider"
    BINARY_PATH="$workdir/missing/bin/macprovider-cli"
    MANIFEST_PATH="$workdir/missing/install_manifest.json"
    PLIST_PATH="$workdir/missing/live.streamvc.macprovider.plist"
    PROVIDER_ID_PATH="$workdir/missing/provider_id"
    CONFIG_PATH="$workdir/missing/config.yaml"
    NO_PROMPT=1
    REFERRAL_CODE_SOURCE_FILE=""
    CREATED_REFERRAL_CODE_SOURCE_FILE=0
    prepare_fresh_referral_code
  ) 2>&1
)"
missing_rc=$?
set -e
[ "$missing_rc" -eq 20 ] || {
  echo "fresh noninteractive missing invite returned $missing_rc, want 20" >&2
  exit 1
}
printf '%s' "$missing_output" | grep -Fq "invite code is required"

mkdir -p "$workdir/existing/macprovider" "$workdir/existing/bin"
cat > "$workdir/existing/bin/macprovider-cli" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "$workdir/existing/bin/macprovider-cli"
printf 'mp-0123456789abcdef0123456789abcdef\n' > "$workdir/existing/provider_id"
printf 'provider_id: "mp-0123456789abcdef0123456789abcdef"\nprovider_token: "legacy-token"\n' \
  > "$workdir/existing/config.yaml"
INSTALL_DIR="$workdir/existing/macprovider"
BINARY_PATH="$workdir/existing/bin/macprovider-cli"
MANIFEST_PATH="$workdir/existing/install_manifest.json"
PLIST_PATH="$workdir/existing/live.streamvc.macprovider.plist"
PROVIDER_ID_PATH="$workdir/existing/provider_id"
CONFIG_PATH="$workdir/existing/config.yaml"
NO_PROMPT=1
REFERRAL_CODE_SOURCE_FILE=""
CREATED_REFERRAL_CODE_SOURCE_FILE=0
FRESH_REFERRAL_BOOTSTRAP=0
prepare_fresh_referral_code
[ -z "$REFERRAL_CODE_SOURCE_FILE" ]
[ "$CREATED_REFERRAL_CODE_SOURCE_FILE" -eq 0 ]
[ "$FRESH_REFERRAL_BOOTSTRAP" -eq 0 ]

for existing_receipt_config in \
  "enable_receipts: false" \
  "enable_receipts: true" \
  "enable_receipts: malformed" \
  ""; do
  printf '%s\n' \
    'model: "incumbent/model"' \
    "$existing_receipt_config" \
    'custom_setting: keep-incumbent' > "$CONFIG_PATH"
  incumbent_config_before="$(shasum -a 256 "$CONFIG_PATH" | awk '{print $1}')"
  enable_fresh_referral_receipts
  incumbent_config_after="$(shasum -a 256 "$CONFIG_PATH" | awk '{print $1}')"
  [ "$incumbent_config_after" = "$incumbent_config_before" ]
done

# A support directory left by an interrupted fresh attempt is not an incumbent.
# It must still fail before release download/autotune when no invite is supplied.
mkdir -p "$workdir/stale/macprovider"
set +e
stale_output="$(
  (
    INSTALL_DIR="$workdir/stale/macprovider"
    BINARY_PATH="$workdir/stale/bin/macprovider-cli"
    MANIFEST_PATH="$workdir/stale/install_manifest.json"
    PLIST_PATH="$workdir/stale/live.streamvc.macprovider.plist"
    PROVIDER_ID_PATH="$workdir/stale/provider_id"
    CONFIG_PATH="$workdir/stale/config.yaml"
    NO_PROMPT=1
    REFERRAL_CODE_SOURCE_FILE=""
    CREATED_REFERRAL_CODE_SOURCE_FILE=0
    prepare_fresh_referral_code
  ) 2>&1
)"
stale_rc=$?
set -e
[ "$stale_rc" -eq 20 ] || {
  echo "stale partial fresh install returned $stale_rc, want 20" >&2
  exit 1
}
printf '%s' "$stale_output" | grep -Fq "invite code is required"

echo "install_referral_handoff: PASS"
