#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$INSTALL_SH" > "$TMP/functions.sh" <<'PY'
import sys
names = {
    "read_config_provider_token_line", "read_config_provider_token", "read_config_model",
    "read_config_provider_id", "read_config_artifact_path", "read_config_artifact_sha",
    "is_bootstrap_principal", "existing_provider_credential_configured",
    "ensure_provider_credentials", "submit_required_hardware_evidence",
    "run_autotune_recommend_apply",
}
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
i = 0
while i < len(lines):
    name = lines[i].split("()", 1)[0] if "()" in lines[i] else ""
    if name not in names:
        i += 1
        continue
    depth = 0
    while i < len(lines):
        line = lines[i]
        print(line)
        depth += line.count("{") - line.count("}")
        i += 1
        if depth == 0:
            break
PY

run_case() {
  mode="$1"
  root="$TMP/$mode"
  mkdir -p "$root/install" "$root/config"
  : > "$root/install/macprovider-cli"
  chmod +x "$root/install/macprovider-cli"
  provider_id="mp-0123456789abcdef0123456789abcdef"
  [ "$mode" != "predictable-id" ] || provider_id="office-mac"
  cat > "$root/config/config.yaml" <<EOF
model: "seed"
provider_id: "$provider_id"
coordinator_url: "wss://coordinator.example/ws/provider"
EOF
  set +e
  CASE_MODE="$mode" CASE_ROOT="$root" bash -c '
    set -euo pipefail
    INSTALL_DIR="$CASE_ROOT/install"
    CONFIG_PATH="$CASE_ROOT/config/config.yaml"
    DRY_RUN=0
    SKIP_PROVIDER_START=0
    model="seed"
    log() { :; }
    die() { exit "$1"; }
    prompt_yes_no() { return 0; }
    run_macprovider_cli_with_amfi_retry() {
      printf "%s\n" "$*" >> "$CASE_ROOT/calls"
      case "$1" in
        bootstrap-auth)
          [ "$CASE_MODE" != "bootstrap-fails" ] || return 9
          printf "provider_token: minted-token\n" >> "$CONFIG_PATH"
          ;;
        autotune)
          case "$*" in
            *--no-submit-hardware-evidence*)
              printf "model: \"recommended\"\nmodel_artifact_path: \"/tmp/model\"\nmodel_artifact_sha256: \"abc\"\n" >> "$CONFIG_PATH"
              ;;
            *--require-hardware-evidence*)
              grep -F "provider_token: minted-token" "$CONFIG_PATH" >/dev/null
              [ "$CASE_MODE" != "evidence-fails" ] || return 11
              ;;
          esac
          ;;
      esac
    }
    source "'$TMP'/functions.sh"
    run_autotune_recommend_apply
    printf "service-start\n" >> "$CASE_ROOT/calls"
  '
  rc=$?
  set -e
  case "$mode" in
    success)
      [ "$rc" -eq 0 ]
      awk '
        /--no-submit-hardware-evidence/ { tune=NR }
        /bootstrap-auth/ { bootstrap=NR }
        /--require-hardware-evidence/ { evidence=NR }
        /service-start/ { service=NR }
        END { exit !(tune < bootstrap && bootstrap < evidence && evidence < service) }
      ' "$root/calls"
      ;;
    bootstrap-fails|evidence-fails|predictable-id)
      [ "$rc" -ne 0 ]
      if grep -F "service-start" "$root/calls" >/dev/null; then
        echo "$mode started service before authenticated evidence" >&2
        exit 1
      fi
      ;;
  esac
}

run_case success
run_case bootstrap-fails
run_case evidence-fails
run_case predictable-id

# The durable upgrade transaction must remain live through every service-file
# mutation and the required local-model self-test. Coordinator visibility is a
# later degraded-connectivity decision and must not roll back a working local
# service.
awk '
  /^main\(\)/ { in_main=1 }
  in_main && /begin_install_transaction/ { begin=NR }
  in_main && /install_plist / { plist=NR }
  in_main && /install_watchdog / { watchdog=NR }
  in_main && /write_install_manifest / && NR > watchdog { manifest=NR }
  in_main && /start_manual_service / { start=NR }
  in_main && /if ! wait_for_local_model / { self_test=NR }
  in_main && /if ! wait_for_coordinator / { coordinator=NR }
  in_main && /commit_install_transaction/ && NR > coordinator { commit=NR }
  END {
    exit !(begin < plist && plist < watchdog && watchdog < manifest &&
           manifest < start && start < self_test && self_test < coordinator &&
           coordinator < commit)
  }
' "$INSTALL_SH"
echo "fresh install evidence ordering ok"
