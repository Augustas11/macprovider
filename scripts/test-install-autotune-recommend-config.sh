#!/usr/bin/env bash
# Hermetic guard for installer SPEC-023 recommendation config parsing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"

die() {
  printf '[install-autotune-config-test] ERROR: %s\n' "$*" >&2
  exit 1
}

[ -f "$INSTALL_SH" ] || die "missing installer: $INSTALL_SH"

lib="$(mktemp "${TMPDIR:-/tmp}/macprovider-install-autotune-lib.XXXXXX")"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/macprovider-install-autotune.XXXXXX")"
trap 'rm -f "$lib"; rm -rf "$workdir"' EXIT

awk '
  /^read_config_model\(\)/ { emit = 1 }
  /^install_binary\(\)/ { emit = 0 }
  emit { print }
' "$INSTALL_SH" > "$lib"

# shellcheck source=/dev/null
. "$lib"

CONFIG_PATH="$workdir/config.yaml"
INSTALL_DIR="$workdir/install"
DRY_RUN=0
SKIP_PROVIDER_START=0
model="initial/model"
mkdir -p "$INSTALL_DIR"
MACPROVIDER_CLI_EXECUTABLE="$INSTALL_DIR/macprovider-cli"
AUTOTUNE_UPGRADE_CANDIDATE_MODEL_ID="namespace/existing-model"
AUTOTUNE_PREFETCH_RECEIPT_PATH=""
staging_dir="$workdir/staging"
mkdir -p "$staging_dir"
EXISTING_INSTALL_WAS_PRESENT=1
FAKE_CLI_LOG="$workdir/cli.log"
export FAKE_CLI_LOG

log() {
  printf '[macprovider-install] %s\n' "$*" >/dev/null
}

die() {
  if [ "$#" -eq 1 ]; then
    printf '[install-autotune-config-test] ERROR: %s\n' "$1" >&2
    exit 1
  fi
  printf '[install-autotune-config-test] ERROR: %s\n' "$2" >&2
  exit "$1"
}

prompt_yes_no() {
  return 0
}

# This harness exercises recommendation/config behavior, not the installer's
# AMFI retry ladder. The extracted functions call through this boundary, so
# provide the direct execution behavior explicitly.
run_macprovider_cli_with_amfi_retry() {
  "$INSTALL_DIR/macprovider-cli" "$@"
}

write_recommendation_config() {
  cat > "$CONFIG_PATH" <<EOF_CONFIG
model: "$1"
provider_id: "mp-0123456789abcdef0123456789abcdef"
model_artifact_path: "$2"
model_artifact_sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
EOF_CONFIG
}

write_donor_recommendation_config() {
  cat > "$CONFIG_PATH" <<'EOF_CONFIG'
model: "org/donor-model"
provider_id: "mp-0123456789abcdef0123456789abcdef"
model_artifact_path: "/tmp/macprovider-donor-snapshot"
model_artifact_sha256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
donor_mode: true
EOF_CONFIG
}

cat > "$INSTALL_DIR/macprovider-cli" <<'EOF_CLI'
#!/usr/bin/env bash
set -euo pipefail

config=""
receipt=""
donor=0
freshness=0
command="${1:-}"
printf '%s\n' "$*" >> "$FAKE_CLI_LOG"
prefetch=0
for arg in "$@"; do
  case "$arg" in
    --donor-mode) donor=1 ;;
    --freshness-check) freshness=1 ;;
    --prefetch) prefetch=1 ;;
  esac
done
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--config" ]; then
    shift
    config="$1"
  fi
  if [ "$1" = "--prefetch-receipt" ]; then
    shift
    receipt="$1"
  fi
  shift || true
done

[ -n "$config" ] || exit 64

if [ "$prefetch" -eq 1 ]; then
  [ -n "$receipt" ] || exit 64
  printf '{"fixture":true}\n' > "$receipt"
  chmod 600 "$receipt"
  exit 0
fi

if [ "$command" = "bootstrap-auth" ]; then
  printf 'provider_token: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' >> "$config"
  exit 0
fi

if [ "$command" = "credentials" ]; then
  exit 0
fi

if [ "$freshness" -eq 1 ]; then
  exit "${FAKE_FRESHNESS_RC:-0}"
fi

if [ "$donor" -eq 1 ]; then
  cat > "$config" <<EOF_DONOR
model: "org/donor-model"
model_artifact_path: "/tmp/macprovider-donor-snapshot"
model_artifact_sha256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
EOF_DONOR
  exit 0
fi

if [ "${FAKE_PAID_EMPTY:-0}" -eq 1 ]; then
  cat > "$config" <<'EOF_EMPTY'
model: "org/unusable-paid-model"
EOF_EMPTY
  exit 0
fi

cat > "$config" <<'EOF_PAID'
model: "org/paid-model"
provider_id: "mp-0123456789abcdef0123456789abcdef"
model_artifact_path: "/tmp/macprovider-paid-snapshot"
model_artifact_sha256: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
EOF_PAID
EOF_CLI
chmod +x "$INSTALL_DIR/macprovider-cli"

run_paid_apply_case() {
  model="initial/model"
  SKIP_PROVIDER_START=0
  rm -f "$CONFIG_PATH"
  export FAKE_PAID_EMPTY=0
  run_autotune_recommend_apply
  unset FAKE_PAID_EMPTY
  [ "$model" = "org/paid-model" ] || die "paid apply used $model instead of public model key"
  [ "$SKIP_PROVIDER_START" -eq 0 ] || die "paid apply unexpectedly skipped provider start"
}

run_donor_apply_case() {
  model="initial/model"
  SKIP_PROVIDER_START=0
  rm -f "$CONFIG_PATH"
  export FAKE_PAID_EMPTY=1
  run_autotune_recommend_apply
  unset FAKE_PAID_EMPTY
  [ "$model" = "org/donor-model" ] || die "donor apply used $model instead of public model key"
  [ "$SKIP_PROVIDER_START" -eq 1 ] || die "donor apply should write config without auto-starting provider"
}

run_fresh_reuse_case() {
  model="initial/model"
  SKIP_PROVIDER_START=0
  write_recommendation_config "org/fresh-model" "/tmp/macprovider-fresh-snapshot"
  export FAKE_FRESHNESS_RC=0
  use_fresh_recommendation_if_available
  unset FAKE_FRESHNESS_RC
  [ "$model" = "org/fresh-model" ] || die "fresh reuse used $model instead of public model key"
}

run_fresh_donor_reuse_case() {
  model="initial/model"
  SKIP_PROVIDER_START=0
  write_donor_recommendation_config
  export FAKE_FRESHNESS_RC=0
  use_fresh_recommendation_if_available
  unset FAKE_FRESHNESS_RC
  [ "$model" = "initial/model" ] || die "fresh donor reuse should not select launch model $model"
  [ "$SKIP_PROVIDER_START" -eq 1 ] || die "fresh donor reuse should not auto-start provider"
}

run_upgrade_prefetch_case() {
  : > "$FAKE_CLI_LOG"
  write_recommendation_config "org/existing-model" "/tmp/macprovider-existing-snapshot"
  prefetch_upgrade_autotune_model
  grep -Fq \
    'autotune --recommend --prefetch --candidate-models namespace/existing-model --prefetch-receipt' \
    "$FAKE_CLI_LOG" \
    || die "upgrade prefetch did not constrain artifact acquisition to the installed catalog model"
}

run_upgrade_missing_catalog_identity_case() {
  : > "$FAKE_CLI_LOG"
  if (
    AUTOTUNE_UPGRADE_CANDIDATE_MODEL_ID=""
    prefetch_upgrade_autotune_model
  ) >/dev/null 2>&1; then
    die "stale upgrade without an exact catalog model identity must fail before cutover"
  fi
  [ ! -s "$FAKE_CLI_LOG" ] \
    || die "missing catalog identity reached the staged CLI instead of failing before cutover"
}

run_upgrade_prefetch_case
run_upgrade_missing_catalog_identity_case
run_paid_apply_case
run_donor_apply_case
run_fresh_reuse_case
run_fresh_donor_reuse_case

grep -Fq \
  'autotune --recommend --apply --candidate-models namespace/existing-model --prefetch-receipt' \
  "$FAKE_CLI_LOG" \
  || die "upgrade recommendation did not constrain benchmarking to the prefetched installed model"

prefetch_call_line="$(awk '$0 == "      prefetch_upgrade_autotune_model" { print NR; exit }' "$INSTALL_SH")"
cutover_line="$(awk -v after="$prefetch_call_line" 'NR > after && $0 == "    ensure_port_free 1" { print NR; exit }' "$INSTALL_SH")"
[ -n "$prefetch_call_line" ] && [ -n "$cutover_line" ] \
  || die "could not locate prefetch and cutover boundaries in installer main"
[ "$prefetch_call_line" -lt "$cutover_line" ] \
  || die "installed-model prefetch must complete before the installer stops the incumbent provider"

printf '[install-autotune-config-test] installer recommendation config parsing ok\n'
