#!/usr/bin/env bash
# Hermetic guard for install.sh preserving provider_id across reinstall.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"

die() {
  printf '[install-provider-id-test] ERROR: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[install-provider-id-test] %s\n' "$*" >&2
}

[ -f "$INSTALL_SH" ] || die "missing installer: $INSTALL_SH"
grep -Fq 'Fresh provider replacement requested; skipping incumbent-model prefetch and running full fresh recommendation.' "$INSTALL_SH" \
  || die "replacement mode must bypass incumbent-model prefetch"
grep -Fq 'REC_REFERRAL_REPLACE_INCUMBENT=%q' "$INSTALL_SH" \
  || die "recovery state must record replacement intent"
grep -Fq 'preserving restored incumbent identity instead of the failed replacement identity' "$INSTALL_SH" \
  || die "replacement rollback must preserve restored incumbent identity"
grep -Fq 'bootstrap_auth_args+=(--replace-referral-journal)' "$INSTALL_SH" \
  || die "replacement referral bootstrap must use a replacement-scoped journal"
grep -Fq 'ensure_replacement_referral_preflight_before_cutover' "$INSTALL_SH" \
  || die "replacement referral must be validated before cutover"
grep -Fq 'without publishing candidate identity over the incumbent config' "$INSTALL_SH" \
  || die "replacement preflight must not publish candidate identity before cutover"

lib="$(mktemp "${TMPDIR:-/tmp}/macprovider-install-provider-id-lib.XXXXXX")"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/macprovider-install-provider-id.XXXXXX")"
trap 'rm -f "$lib"; rm -rf "$workdir"' EXIT

{
  awk '/^read_config_provider_id\(\)/, /^}/' "$INSTALL_SH"
  awk '/^generate_fresh_provider_id\(\)/, /^}/' "$INSTALL_SH"
  awk '/^read_replacement_candidate_provider_id\(\)/, /^}/' "$INSTALL_SH"
  awk '/^persist_replacement_candidate_provider_id\(\)/ { p=1 } p { print } p && /^}$/ { exit }' "$INSTALL_SH"
  awk '/^retire_replacement_candidate_provider_id\(\)/, /^}/' "$INSTALL_SH"
  awk '/^choose_provider_id\(\)/, /^}/' "$INSTALL_SH"
  awk '/^prepare_staged_config\(\)/, /^}/' "$INSTALL_SH"
} > "$lib"

# shellcheck source=/dev/null
. "$lib"

CONFIG_DIR="$workdir/config"
CONFIG_PATH="$CONFIG_DIR/config.yaml"
PROVIDER_ID_PATH="$CONFIG_DIR/provider_id"
REPLACEMENT_CANDIDATE_DIR="$CONFIG_DIR/replacement-candidate"
REPLACEMENT_CANDIDATE_PROVIDER_ID_PATH="$REPLACEMENT_CANDIDATE_DIR/provider_id"
# shellcheck disable=SC2034 # consumed by functions extracted from install.sh
REFERRAL_REPLACE_INCUMBENT=0
# shellcheck disable=SC2034 # consumed by functions extracted from install.sh
FRESH_REFERRAL_BOOTSTRAP=0

mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_PATH" <<'EOF_CONFIG'
model: "old/model"
coordinator_url: "wss://old.example/ws/provider"
provider_id: "p_upiv4dug6kmmcpavsyqjmt35andgfpbf4ztrrnhlqdjqirhprcxq"
port: 18080
EOF_CONFIG

chosen="$(choose_provider_id)"
[ "$chosen" = "p_upiv4dug6kmmcpavsyqjmt35andgfpbf4ztrrnhlqdjqirhprcxq" ] \
  || die "expected config.yaml provider_id, got: $chosen"

rm -f "$PROVIDER_ID_PATH"
printf "mac\n" > "$PROVIDER_ID_PATH"
chosen="$(choose_provider_id)"
[ "$chosen" = "mac" ] || die "expected provider_id file to win, got: $chosen"

rm -f "$PROVIDER_ID_PATH"
chosen="$(choose_provider_id)"
[ "$chosen" = "p_upiv4dug6kmmcpavsyqjmt35andgfpbf4ztrrnhlqdjqirhprcxq" ] \
  || die "expected config.yaml fallback after empty provider_id file, got: $chosen"

REFERRAL_REPLACE_INCUMBENT=1
FRESH_REFERRAL_BOOTSTRAP=1
printf "p_existing_should_not_win\n" > "$PROVIDER_ID_PATH"
chosen="$(choose_provider_id)"
case "$chosen" in
  mp-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *) die "fresh provider replacement did not generate a new mp-* identity: $chosen" ;;
esac
[ "$chosen" != "p_existing_should_not_win" ] \
  || die "fresh provider replacement reused the incumbent provider_id"

# shellcheck disable=SC2034 # consumed by persist_replacement_candidate_provider_id from install.sh
provider_id="$chosen"
persist_replacement_candidate_provider_id
[ -f "$REPLACEMENT_CANDIDATE_PROVIDER_ID_PATH" ] \
  || die "replacement candidate provider_id was not persisted"
retried="$(choose_provider_id)"
[ "$retried" = "$chosen" ] \
  || die "fresh provider replacement did not reuse the durable candidate provider_id"

printf "%s\n" "$chosen" > "$PROVIDER_ID_PATH"
cat > "$CONFIG_PATH" <<EOF_CONFIG
model: "new/model"
coordinator_url: "wss://new.example/ws/provider"
provider_id: "$chosen"
port: 18080
EOF_CONFIG
next_replacement="$(choose_provider_id)"
[ "$next_replacement" != "$chosen" ] \
  || die "committed replacement candidate marker was reused as a future fresh provider"
case "$next_replacement" in
  mp-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *) die "future replacement after committed marker did not generate a new mp-* identity: $next_replacement" ;;
esac

# shellcheck disable=SC2034 # consumed by prepare_staged_config extracted from install.sh
LIVE_CONFIG_PATH="$CONFIG_PATH"
# shellcheck disable=SC2034 # consumed by prepare_staged_config extracted from install.sh
LIVE_PROVIDER_ID_PATH="$PROVIDER_ID_PATH"
staging_dir="$workdir/staging-default"
mkdir -p "$staging_dir"
REFERRAL_REPLACE_INCUMBENT=0
FRESH_REFERRAL_BOOTSTRAP=0
prepare_staged_config
grep -Fq "provider_id: \"$chosen\"" "$STAGED_CONFIG_PATH" \
  || die "ordinary reinstall did not stage incumbent config"
grep -Fq "$chosen" "$STAGED_PROVIDER_ID_PATH" \
  || die "ordinary reinstall did not stage incumbent provider_id file"

staging_dir="$workdir/staging-replacement"
mkdir -p "$staging_dir"
REFERRAL_REPLACE_INCUMBENT=1
FRESH_REFERRAL_BOOTSTRAP=1
prepare_staged_config
[ ! -e "$STAGED_CONFIG_PATH" ] \
  || die "fresh provider replacement must not copy incumbent config into staging"
[ ! -e "$STAGED_PROVIDER_ID_PATH" ] \
  || die "fresh provider replacement must not copy incumbent provider_id file into staging"

rm -f "$CONFIG_PATH"
rm -f "$PROVIDER_ID_PATH"
# shellcheck disable=SC2034 # consumed by choose_provider_id extracted from install.sh
REFERRAL_REPLACE_INCUMBENT=0
# shellcheck disable=SC2034 # consumed by choose_provider_id extracted from install.sh
FRESH_REFERRAL_BOOTSTRAP=0
chosen="$(choose_provider_id)"
case "$chosen" in
  mp-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *) die "fresh install did not generate a 128-bit provider auth principal: $chosen" ;;
esac

printf '[install-provider-id-test] installer preserves provider_id across reinstall ok\n'
