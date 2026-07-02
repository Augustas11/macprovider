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

write_recommendation_config() {
  cat > "$CONFIG_PATH" <<EOF_CONFIG
model: "$1"
model_artifact_path: "$2"
model_artifact_sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
EOF_CONFIG
}

write_donor_recommendation_config() {
  cat > "$CONFIG_PATH" <<'EOF_CONFIG'
model: "org/donor-model"
model_artifact_path: "/tmp/macprovider-donor-snapshot"
model_artifact_sha256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
donor_mode: true
EOF_CONFIG
}

cat > "$INSTALL_DIR/macprovider-cli" <<'EOF_CLI'
#!/usr/bin/env bash
set -euo pipefail

config=""
donor=0
freshness=0
for arg in "$@"; do
  case "$arg" in
    --donor-mode) donor=1 ;;
    --freshness-check) freshness=1 ;;
  esac
done
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--config" ]; then
    shift
    config="$1"
  fi
  shift || true
done

[ -n "$config" ] || exit 64

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

run_paid_apply_case
run_donor_apply_case
run_fresh_reuse_case
run_fresh_donor_reuse_case

printf '[install-autotune-config-test] installer recommendation config parsing ok\n'
