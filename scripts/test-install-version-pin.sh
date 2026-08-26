#!/usr/bin/env bash
# Hermetic regression guard for install.sh's MACPROVIDER_VERSION pinning
# and prerelease-aware latest-release selection.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"

fatal() {
  printf '[install-version-pin-test] ERROR: %s\n' "$*" >&2
  exit 1
}

[ -f "$INSTALL_SH" ] || fatal "missing installer: $INSTALL_SH"

lib="$(mktemp "${TMPDIR:-/tmp}/macprovider-install-version-lib.XXXXXX")"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/macprovider-install-version.XXXXXX")"
workdir="$(cd "$workdir" && pwd -P)"
trap 'rm -f "$lib"; rm -rf "$workdir"' EXIT

awk '
  /^latest_release_tag\(\)/ { emit = 1 }
  /^download_release\(\)/ { emit = 0 }
  emit { print }
' "$INSTALL_SH" > "$lib"

awk '
  /^download_release\(\)/ { emit = 1 }
  emit { print }
  emit && /^\}$/ { exit }
' "$INSTALL_SH" >> "$lib"

awk '
  /^checksum_for_asset\(\)/ { emit = 1 }
  emit { print }
  emit && /^\}$/ { exit }
' "$INSTALL_SH" >> "$lib"

awk '
  /^verify_sha256\(\)/ { emit = 1 }
  emit { print }
  emit && /^\}$/ { exit }
' "$INSTALL_SH" >> "$lib"

awk '
  /^validate_staged_entries\(\)/ { emit = 1 }
  emit { print }
  emit && /^\}$/ { exit }
' "$INSTALL_SH" >> "$lib"

awk '
  /^disable_staged_autoupdate\(\)/ { emit = 1 }
  emit { print }
  emit && /^\}$/ { exit }
' "$INSTALL_SH" >> "$lib"

awk '
  /^verify_emergency_config_activation\(\)/ { emit = 1 }
  emit { print }
  emit && /^\}$/ { exit }
' "$INSTALL_SH" >> "$lib"

awk '
  /^config_without_provider_token_sha256\(\)/ { emit = 1 }
  emit { print }
  emit && /^\}$/ { exit }
' "$INSTALL_SH" >> "$lib"

awk '
  /^preserve_failed_bootstrap_identity\(\)/ { emit = 1 }
  emit { print }
  emit && /^\}$/ { exit }
' "$INSTALL_SH" >> "$lib"

awk '
  /^validate_emergency_target\(\)/ { emit = 1 }
  /^disable_staged_autoupdate\(\)/ { emit = 0 }
  emit { print }
' "$INSTALL_SH" >> "$lib"

awk '
  /^installed_provider_binary_path\(\)/ { emit = 1 }
  /^validate_non_emergency_pinned_target\(\)/ { emit = 0 }
  emit { print }
' "$INSTALL_SH" >> "$lib"

awk '
  /^validate_non_emergency_pinned_target\(\)/ { emit = 1 }
  emit { print }
  emit && /^\}$/ { exit }
' "$INSTALL_SH" >> "$lib"

for symbol in latest_release_tag validate_macprovider_version_tag resolve_release_tag validated_acceptance_asset_dir download_release verify_sha256 validate_staged_entries installed_provider_binary_path validate_acceptance_upgrade_target validate_acceptance_provider_component_target validate_staged_acceptance_provider_component validate_non_emergency_pinned_target validate_emergency_target verify_emergency_coordinator_advertisement validate_emergency_config_backup stage_emergency_config_backup disable_staged_autoupdate verify_emergency_config_activation config_without_provider_token_sha256 preserve_failed_bootstrap_identity; do
  grep -q "^${symbol}()" "$lib" || fatal "could not extract $symbol from $INSTALL_SH"
done

MACPROVIDER_MIN_SUPPORTED_VERSION="v1.7.11"
MACPROVIDER_MIN_EMERGENCY_VERSION="v1.8.30"
GITHUB_REPO="Augustas11/macprovider"
TMPDIR_PATH=""
asset_path=""
asset_kind=""
checksums_path=""
checksums_sig_path=""
ACCEPTANCE_METADATA_PATH=""
ACCEPTANCE_METADATA_SIGNATURE_PATH=""
DOWNLOAD_LOG="$workdir/downloads.log"
LOG_FILE="$workdir/log.out"
BINARY_PATH="$workdir/installed-macprovider-cli"
INSTALL_DIR="$workdir"

log() { printf '%s\n' "$*" >> "$LOG_FILE"; }
die() {
  code="$1"
  shift
  printf 'die[%s] %s\n' "$code" "$*" >> "$LOG_FILE"
  exit "$code"
}
verify_checksum_signature() {
  if [ "${MOCK_SIGNATURE_FAIL:-0}" = "1" ]; then
    die 4 "checksum signature verification failed"
  fi
  log "signature checked"
}
validate_release_payload() {
  VALIDATE_CALLED=$((VALIDATE_CALLED + 1))
  log "payload validated"
}
shasum() {
  if [ "${MOCK_REAL_SHA:-0}" = "1" ]; then
    command shasum "$@"
    return
  fi
  printf '%s  %s\n' "${MOCK_SHA:-goodhash}" "$2"
}
curl() {
  local out="" url="" arg
  while [ "$#" -gt 0 ]; do
    arg="$1"
    shift
    case "$arg" in
      -o)
        out="$1"
        shift
        ;;
      http*)
        url="$arg"
        ;;
    esac
  done

  case "$url" in
    *"/releases?per_page=30")
      printf '%s' "$MOCK_RELEASES_JSON"
      ;;
    *"/healthz")
      printf '%s' "$MOCK_HEALTH_JSON"
      ;;
    *"/v99.0.0/"*)
      return 22
      ;;
    *"/checksums.txt.sig")
      printf 'sig' > "$out"
      ;;
    *"/checksums.txt")
      printf '%s\n' "$MOCK_CHECKSUMS" > "$out"
      ;;
    *".pkg")
      printf '%s\n' "$url" >> "$DOWNLOAD_LOG"
      printf 'pkg' > "$out"
      ;;
    *".tar.gz")
      printf '%s\n' "$url" >> "$DOWNLOAD_LOG"
      printf 'tar' > "$out"
      ;;
    *)
      printf 'unexpected curl URL: %s\n' "$url" >&2
      return 2
      ;;
  esac
}

# shellcheck source=/dev/null
. "$lib"

pass=0
fail=0
report() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    pass=$((pass + 1))
    printf 'PASS %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL %s: want=%q got=%q\n' "$name" "$want" "$got" >&2
  fi
}

reset_mocks() {
  : > "$DOWNLOAD_LOG"
  : > "$LOG_FILE"
  VALIDATE_CALLED=0
  MOCK_SHA="goodhash"
  MOCK_SIGNATURE_FAIL=0
  MOCK_REAL_SHA=0
  MOCK_CHECKSUMS="goodhash macprovider-cli-v1.7.11-darwin-arm64.pkg"
  MOCK_RELEASES_JSON='[{"tag_name":"v1.8.0","prerelease":true},{"tag_name":"verify-v1.0.0","prerelease":false},{"tag_name":"v1.7.11","prerelease":false}]'
  MOCK_HEALTH_JSON='{"recommended_binary_version":"1.8.33"}'
  unset MACPROVIDER_VERSION MACPROVIDER_ACCEPTANCE_ASSET_DIR MACPROVIDER_ACCEPTANCE_COMMIT
  unset MACPROVIDER_ACCEPTANCE_CONTROL_COMMIT MACPROVIDER_ACCEPTANCE_RUN_ID
  unset MACPROVIDER_ACCEPTANCE_RUN_ATTEMPT MACPROVIDER_CHECKSUM_PUBLIC_KEY_PEM
  EMERGENCY_ROLLBACK=0
}

run_release_chain() {
  local tag
  tag="$(resolve_release_tag)"
  download_release "$tag"
  verify_sha256
  validate_release_payload
}

################################################################
# Case 1 — pinned supported version uses the signed release path.
################################################################
reset_mocks
MACPROVIDER_VERSION="v1.7.11"
run_release_chain
report "case1-pinned-url" \
  "https://github.com/Augustas11/macprovider/releases/download/v1.7.11/macprovider-cli-v1.7.11-darwin-arm64.pkg" \
  "$(cat "$DOWNLOAD_LOG")"
report "case1-validation-chain-called" 1 "$VALIDATE_CALLED"

################################################################
# Case 2 — unset pin skips prerelease v1.8.0 and chooses latest stable.
################################################################
reset_mocks
tag="$(resolve_release_tag)"
report "case2-latest-skips-prerelease" "v1.7.11" "$tag"

reset_mocks
MOCK_RELEASES_JSON='[{"prerelease":true,"tag_name":"v1.8.0"},{"prerelease":false,"tag_name":"v1.7.11"}]'
tag="$(resolve_release_tag)"
report "case2-prerelease-before-tag-skips-prerelease" "v1.7.11" "$tag"

################################################################
# Case 3 — nonexistent but valid-shape tag fails clearly, no latest fallback.
################################################################
reset_mocks
MACPROVIDER_VERSION="v99.0.0"
rc=0
( run_release_chain ) >/dev/null 2>&1 || rc=$?
report "case3-nonexistent-tag-fails" 3 "$rc"
report "case3-no-latest-fallback" "" "$(cat "$DOWNLOAD_LOG")"

################################################################
# Case 4 — invalid tag shapes fail before download.
################################################################
for invalid in main verify-v1.0.0 ../v1.7.11 $'v1.7.11\nbad' $'v2.0.0\nbad'; do
  reset_mocks
  MACPROVIDER_VERSION="$invalid"
  rc=0
  ( resolve_release_tag ) >/dev/null 2>&1 || rc=$?
  report "case4-invalid-${invalid//$'\n'/newline}" 7 "$rc"
done

################################################################
# Case 5 — below rollback floor fails closed.
################################################################
reset_mocks
MACPROVIDER_VERSION="v1.7.10"
rc=0
( resolve_release_tag ) >/dev/null 2>&1 || rc=$?
report "case5-below-floor-fails" 7 "$rc"

################################################################
# Case 6 — pinned checksum mismatch aborts without latest fallback.
################################################################
reset_mocks
MACPROVIDER_VERSION="v1.7.11"
MOCK_SHA="badhash"
rc=0
( run_release_chain ) >/dev/null 2>&1 || rc=$?
report "case6-checksum-mismatch-fails" 4 "$rc"
report "case6-pinned-only-download" \
  "https://github.com/Augustas11/macprovider/releases/download/v1.7.11/macprovider-cli-v1.7.11-darwin-arm64.pkg" \
  "$(cat "$DOWNLOAD_LOG")"

################################################################
# Case 7 — pinned signature mismatch aborts without latest fallback.
################################################################
reset_mocks
MACPROVIDER_VERSION="v1.7.11"
MOCK_SIGNATURE_FAIL=1
rc=0
( run_release_chain ) >/dev/null 2>&1 || rc=$?
report "case7-signature-mismatch-fails" 4 "$rc"
report "case7-no-asset-download-after-signature-fail" "" "$(cat "$DOWNLOAD_LOG")"

################################################################
# Case 8 — documented curl-pipe-bash env placement reaches bash.
################################################################
if printf 'test "$MACPROVIDER_VERSION" = "v1.7.11"\n' | MACPROVIDER_VERSION=v1.7.11 bash; then
  report "case8-pipe-side-env" ok ok
else
  report "case8-pipe-side-env" ok fail
fi

################################################################
# Case 9 — explicit pin can opt into prerelease tag.
################################################################
reset_mocks
MACPROVIDER_VERSION="v1.8.0"
tag="$(resolve_release_tag)"
report "case9-explicit-prerelease-pin" "v1.8.0" "$tag"

################################################################
# Case 10 — emergency rollback is never an implicit latest install.
################################################################
reset_mocks
EMERGENCY_ROLLBACK=1
rc=0
( resolve_release_tag ) >/dev/null 2>&1 || rc=$?
report "case10-emergency-requires-pin" 7 "$rc"

reset_mocks
EMERGENCY_ROLLBACK=1
MACPROVIDER_VERSION="v1.7.11"
rc=0
( resolve_release_tag ) >/dev/null 2>&1 || rc=$?
report "case10-emergency-rejects-incompatible-floor" 7 "$rc"

################################################################
# Case 11 — only explicit emergency rollback accepts a signed legacy
# payload shape; path allowlisting remains unchanged.
################################################################
legacy_entries=$'macprovider-cli\nmlx-swift_Cmlx.bundle\nmlx-swift_Cmlx.bundle/Contents\nmlx-swift_Cmlx.bundle/Contents/Resources\nmlx-swift_Cmlx.bundle/Contents/Resources/default.metallib'
reset_mocks
rc=0
( validate_staged_entries "$legacy_entries" "legacy fixture" ) >/dev/null 2>&1 || rc=$?
report "case11-normal-rejects-legacy-payload" 5 "$rc"

reset_mocks
EMERGENCY_ROLLBACK=1
rc=0
( validate_staged_entries "$legacy_entries" "legacy fixture" ) >/dev/null 2>&1 || rc=$?
report "case11-emergency-accepts-legacy-payload" 0 "$rc"

rc=0
( validate_staged_entries "$legacy_entries"$'\n../escape' "legacy fixture" ) >/dev/null 2>&1 || rc=$?
report "case11-emergency-keeps-path-allowlist" 5 "$rc"

################################################################
# Case 12 — emergency rollback adds the v1.8.30-compatible top-level
# opt-out without rewriting any valid nested YAML representation.
################################################################
STAGED_CONFIG_PATH="$workdir/emergency-config.yaml"
cat > "$STAGED_CONFIG_PATH" <<'YAML'
provider_id: test-provider
autoupdate:
    enabled: true
    interval_s: 3600
auto_update_enabled: true
YAML
disable_staged_autoupdate
report "case12-legacy-autoupdate-disabled" 1 \
  "$(grep -c '^auto_update_enabled: false$' "$STAGED_CONFIG_PATH")"
report "case12-old-legacy-value-removed" 0 \
  "$(grep -c '^auto_update_enabled: true$' "$STAGED_CONFIG_PATH" || true)"
report "case12-four-space-nested-config-preserved" 1 \
  "$(grep -c '^    enabled: true$' "$STAGED_CONFIG_PATH")"

STAGED_CONFIG_PATH="$workdir/emergency-config-flow.yaml"
printf 'provider_id: test-provider\nautoupdate: {enabled: true, interval_s: 3600}\n' > "$STAGED_CONFIG_PATH"
disable_staged_autoupdate
report "case12-flow-nested-config-preserved" 1 \
  "$(grep -c '^autoupdate: {enabled: true, interval_s: 3600}$' "$STAGED_CONFIG_PATH")"
report "case12-flow-legacy-opt-out-added" 1 \
  "$(grep -c '^auto_update_enabled: false$' "$STAGED_CONFIG_PATH")"

################################################################
# Case 13 — emergency rollback is older-only and requires the
# coordinator to advertise the exact compatible rollback target.
################################################################
cat > "$BINARY_PATH" <<'SH'
#!/usr/bin/env bash
printf '1.8.34\n'
SH
chmod +x "$BINARY_PATH"
reset_mocks
rc=0
( validate_emergency_target v1.8.30 ) >/dev/null 2>&1 || rc=$?
report "case13-older-target-accepted" 0 "$rc"
rc=0
( validate_emergency_target v1.8.34 ) >/dev/null 2>&1 || rc=$?
report "case13-equal-target-rejected" 7 "$rc"
rc=0
( validate_emergency_target v1.8.35 ) >/dev/null 2>&1 || rc=$?
report "case13-newer-target-rejected" 7 "$rc"

rc=0
MOCK_HEALTH_JSON='{"recommended_binary_version":"1.8.30"}'
( verify_emergency_coordinator_advertisement https://coordinator.example v1.8.30 ) >/dev/null 2>&1 || rc=$?
report "case13-exact-advertisement-accepted" 0 "$rc"
MOCK_HEALTH_JSON='{"recommended_binary_version":"1.8.29"}'
rc=0
( verify_emergency_coordinator_advertisement https://coordinator.example v1.8.30 ) >/dev/null 2>&1 || rc=$?
report "case13-mismatched-advertisement-rejected" 7 "$rc"

reset_mocks
EMERGENCY_ROLLBACK=1
MACPROVIDER_VERSION="v1.8.29"
rc=0
( resolve_release_tag ) >/dev/null 2>&1 || rc=$?
report "case13-pre-contract-target-rejected" 7 "$rc"
reset_mocks
EMERGENCY_ROLLBACK=1
MACPROVIDER_VERSION="v1.8.30"
rc=0
observed_tag="$(resolve_release_tag)" || rc=$?
report "case13-contract-floor-target-accepted" 0 "$rc"
report "case13-contract-floor-target-preserved" "v1.8.30" "$observed_tag"

################################################################
# Case 14 — emergency rollback consumes the exact inventoried
# pre-upgrade config bytes and rejects mismatched provenance.
################################################################
LIVE_CONFIG_PATH="$workdir/live-config.yaml"
printf 'model: current-model\n' > "$LIVE_CONFIG_PATH"
EMERGENCY_CONFIG_BACKUP="$workdir/prior-config.yaml"
printf 'model: prior-model\nautoupdate: {enabled: true}\n' > "$EMERGENCY_CONFIG_BACKUP"
chmod 600 "$EMERGENCY_CONFIG_BACKUP"
EMERGENCY_CONFIG_SHA256="$(python3 - "$EMERGENCY_CONFIG_BACKUP" <<'PY'
import hashlib
import sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
PY
)"
rc=0
( validate_emergency_config_backup ) >/dev/null 2>&1 || rc=$?
report "case14-owned-backup-accepted" 0 "$rc"

STAGED_CONFIG_PATH="$workdir/staged-emergency-config.yaml"
printf 'model: current-model\n' > "$STAGED_CONFIG_PATH"
stage_emergency_config_backup
report "case14-exact-backup-staged" 0 \
  "$(cmp -s "$EMERGENCY_CONFIG_BACKUP" "$STAGED_CONFIG_PATH"; printf '%s' "$?")"
disable_staged_autoupdate
report "case14-prior-model-restored" 1 \
  "$(grep -c '^model: prior-model$' "$STAGED_CONFIG_PATH")"
report "case14-restored-config-opted-out" 1 \
  "$(grep -c '^auto_update_enabled: false$' "$STAGED_CONFIG_PATH")"

EMERGENCY_CONFIG_SHA256="$(printf '0%.0s' {1..64})"
rc=0
( validate_emergency_config_backup ) >/dev/null 2>&1 || rc=$?
report "case14-mismatched-backup-hash-rejected" 7 "$rc"

################################################################
# Case 15 — a v1.8.34 emergency activation may remove only the
# provider_token after admission; all other byte drift is rejected.
################################################################
STAGED_CONFIG_PATH="$workdir/staged-with-token.yaml"
LIVE_CONFIG_PATH="$workdir/live-emergency-config.yaml"
printf 'provider_id: mp-test\nprovider_token: secret-token\nmodel: prior-model\nauto_update_enabled: false\n' > "$STAGED_CONFIG_PATH"
cp "$STAGED_CONFIG_PATH" "$LIVE_CONFIG_PATH"
MOCK_REAL_SHA=1
EMERGENCY_STAGED_CONFIG_SHA256="$(command shasum -a 256 "$STAGED_CONFIG_PATH" | awk '{print $1}')"
EMERGENCY_STAGED_CONFIG_TOKENLESS_SHA256="$(config_without_provider_token_sha256 "$STAGED_CONFIG_PATH")"
EMERGENCY_MODEL="prior-model"
read_config_model() { sed -n 's/^model:[[:space:]]*//p' "$LIVE_CONFIG_PATH" | tail -n 1; }
rc=0
( verify_emergency_config_activation ) >/dev/null 2>&1 || rc=$?
report "case15-exact-activation-accepted" 0 "$rc"
grep -v '^provider_token:' "$STAGED_CONFIG_PATH" > "$LIVE_CONFIG_PATH"
rc=0
( verify_emergency_config_activation ) >/dev/null 2>&1 || rc=$?
report "case15-tokenless-activation-accepted" 0 "$rc"
printf 'provider_id: mp-test\nmodel: changed-model\nauto_update_enabled: false\n' > "$LIVE_CONFIG_PATH"
rc=0
( verify_emergency_config_activation ) >/dev/null 2>&1 || rc=$?
report "case15-noncredential-drift-rejected" 7 "$rc"

################################################################
# Case 16 — failed tokenless v1.8.34 bootstrap identity recovery
# preserves the transaction-restored legacy bearer for an old binary.
################################################################
failed_config="$workdir/failed-tokenless.yaml"
restored_config="$workdir/restored-token-bearing.yaml"
restored_provider_id="$workdir/restored-provider-id"
provider_id="mp-0123456789abcdef0123456789abcdef"
legacy_token="$(printf 'a%.0s' {1..64})"
printf 'provider_id: %s\nmodel: new-model\nenable_receipts: true\n' "$provider_id" > "$failed_config"
printf 'provider_id: old-provider\nprovider_token: %s\nmodel: old-model\nenable_receipts: false\ncustom_setting: keep-restored\n' "$legacy_token" > "$restored_config"
preserve_failed_bootstrap_identity "$failed_config" "$restored_config" "$restored_provider_id"
report "case16-tokenless-failure-preserves-restored-bearer" 1 \
  "$(grep -c "^provider_token: $legacy_token$" "$restored_config")"
report "case16-tokenless-failure-preserves-new-provider-id" 1 \
  "$(grep -c "^provider_id: \"$provider_id\"$" "$restored_config")"
report "case16-tokenless-failure-preserves-fresh-referral-receipts" 1 \
  "$(grep -c '^enable_receipts: true$' "$restored_config")"
report "case16-tokenless-failure-preserves-unrelated-restored-config" 1 \
  "$(grep -c '^custom_setting: keep-restored$' "$restored_config")"

for failed_receipt_value in false malformed; do
  printf 'provider_id: %s\nmodel: new-model\nenable_receipts: %s\n' \
    "$provider_id" "$failed_receipt_value" > "$failed_config"
  printf 'provider_id: %s\nmodel: restored-model\nenable_receipts: false\ncustom_setting: keep-restored\n' \
    "$provider_id" > "$restored_config"
  preserve_failed_bootstrap_identity "$failed_config" "$restored_config" "$restored_provider_id"
  report "case16-${failed_receipt_value}-receipt-not-promoted" 1 \
    "$(grep -c '^enable_receipts: false$' "$restored_config")"
  report "case16-${failed_receipt_value}-preserves-unrelated-config" 1 \
    "$(grep -c '^custom_setting: keep-restored$' "$restored_config")"
done

################################################################
# Case 17 — protected acceptance assets require an exact version
# and use only locally staged, signed payloads.
################################################################
acceptance_dir="$workdir/acceptance-v1.8.33"
mkdir -m 700 "$acceptance_dir"
printf 'goodhash macprovider-cli-v1.8.33-darwin-arm64.pkg\n' > "$acceptance_dir/checksums.txt"
printf '{}\n' > "$acceptance_dir/acceptance-candidate.json"
printf 'signature\n' > "$acceptance_dir/acceptance-candidate.json.sig"
printf 'candidate-package\n' > "$acceptance_dir/macprovider-cli-v1.8.33-darwin-arm64.pkg"
chmod 600 "$acceptance_dir"/*

reset_mocks
MACPROVIDER_ACCEPTANCE_ASSET_DIR="$acceptance_dir"
rc=0
( resolve_release_tag ) >/dev/null 2>&1 || rc=$?
report "case17-acceptance-assets-require-version" 7 "$rc"

reset_mocks
MACPROVIDER_VERSION="v1.8.33"
MACPROVIDER_ACCEPTANCE_ASSET_DIR="$acceptance_dir"
MACPROVIDER_ACCEPTANCE_COMMIT="$(printf 'a%.0s' {1..40})"
MACPROVIDER_ACCEPTANCE_CONTROL_COMMIT="$(printf 'b%.0s' {1..40})"
MACPROVIDER_ACCEPTANCE_RUN_ID="123456789"
MACPROVIDER_ACCEPTANCE_RUN_ATTEMPT="2"
run_release_chain
report "case17-local-candidate-skips-release-download" "" "$(cat "$DOWNLOAD_LOG")"
report "case17-local-candidate-payload-staged" "candidate-package" \
  "$(tr -d '\n' < "$asset_path")"
report "case17-local-candidate-validation-chain-called" 1 "$VALIDATE_CALLED"

################################################################
# Case 18 — unsafe acceptance paths and signing-key substitution
# fail closed before a candidate payload is staged.
################################################################
acceptance_link="$workdir/acceptance-link"
ln -s "$acceptance_dir" "$acceptance_link"
reset_mocks
MACPROVIDER_VERSION="v1.8.33"
MACPROVIDER_ACCEPTANCE_ASSET_DIR="$acceptance_link"
MACPROVIDER_ACCEPTANCE_COMMIT="$(printf 'a%.0s' {1..40})"
MACPROVIDER_ACCEPTANCE_CONTROL_COMMIT="$(printf 'b%.0s' {1..40})"
MACPROVIDER_ACCEPTANCE_RUN_ID="123456789"
MACPROVIDER_ACCEPTANCE_RUN_ATTEMPT="2"
rc=0
( run_release_chain ) >/dev/null 2>&1 || rc=$?
report "case18-symlinked-acceptance-dir-rejected" 7 "$rc"

unsafe_acceptance_dir="$workdir/acceptance-world-writable"
cp -R "$acceptance_dir" "$unsafe_acceptance_dir"
chmod 700 "$unsafe_acceptance_dir"
chmod 666 "$unsafe_acceptance_dir/checksums.txt"
reset_mocks
MACPROVIDER_VERSION="v1.8.33"
MACPROVIDER_ACCEPTANCE_ASSET_DIR="$unsafe_acceptance_dir"
MACPROVIDER_ACCEPTANCE_COMMIT="$(printf 'a%.0s' {1..40})"
MACPROVIDER_ACCEPTANCE_CONTROL_COMMIT="$(printf 'b%.0s' {1..40})"
MACPROVIDER_ACCEPTANCE_RUN_ID="123456789"
MACPROVIDER_ACCEPTANCE_RUN_ATTEMPT="2"
rc=0
( run_release_chain ) >/dev/null 2>&1 || rc=$?
report "case18-world-writable-acceptance-asset-rejected" 7 "$rc"

reset_mocks
MACPROVIDER_VERSION="v1.8.33"
MACPROVIDER_ACCEPTANCE_ASSET_DIR="$acceptance_dir"
MACPROVIDER_ACCEPTANCE_COMMIT="$(printf 'a%.0s' {1..40})"
MACPROVIDER_ACCEPTANCE_CONTROL_COMMIT="$(printf 'b%.0s' {1..40})"
MACPROVIDER_ACCEPTANCE_RUN_ID="123456789"
MACPROVIDER_ACCEPTANCE_RUN_ATTEMPT="2"
MACPROVIDER_CHECKSUM_PUBLIC_KEY_PEM="untrusted replacement key"
rc=0
( run_release_chain ) >/dev/null 2>&1 || rc=$?
report "case18-acceptance-signing-key-override-rejected" 7 "$rc"

################################################################
# Case 19 — acceptance candidates retain the domain-separated metadata
# signature and checksum hash fail-closed chain.
################################################################
reset_mocks
MACPROVIDER_VERSION="v1.8.33"
MACPROVIDER_ACCEPTANCE_ASSET_DIR="$acceptance_dir"
MACPROVIDER_ACCEPTANCE_COMMIT="$(printf 'a%.0s' {1..40})"
MACPROVIDER_ACCEPTANCE_CONTROL_COMMIT="$(printf 'b%.0s' {1..40})"
MACPROVIDER_ACCEPTANCE_RUN_ID="123456789"
MACPROVIDER_ACCEPTANCE_RUN_ATTEMPT="2"
MOCK_SIGNATURE_FAIL=1
rc=0
( run_release_chain ) >/dev/null 2>&1 || rc=$?
report "case19-acceptance-signature-mismatch-fails" 4 "$rc"
report "case19-signature-failure-stages-no-payload" "" "$(cat "$DOWNLOAD_LOG")"

reset_mocks
MACPROVIDER_VERSION="v1.8.33"
MACPROVIDER_ACCEPTANCE_ASSET_DIR="$acceptance_dir"
MACPROVIDER_ACCEPTANCE_COMMIT="$(printf 'a%.0s' {1..40})"
MACPROVIDER_ACCEPTANCE_CONTROL_COMMIT="$(printf 'b%.0s' {1..40})"
MACPROVIDER_ACCEPTANCE_RUN_ID="123456789"
MACPROVIDER_ACCEPTANCE_RUN_ATTEMPT="2"
MOCK_SHA="badhash"
rc=0
( run_release_chain ) >/dev/null 2>&1 || rc=$?
report "case19-acceptance-checksum-mismatch-fails" 4 "$rc"

################################################################
# Case 20 — acceptance install is upgrade-only; downgrade remains
# available only to the complete emergency rollback flow.
################################################################
printf '#!/usr/bin/env bash\nprintf "1.8.34\\n"\n' > "$BINARY_PATH"
chmod +x "$BINARY_PATH"
reset_mocks
MACPROVIDER_VERSION="v1.8.34"
MACPROVIDER_ACCEPTANCE_ASSET_DIR="$acceptance_dir"
rc=0
( validate_acceptance_upgrade_target v1.8.34 ) >/dev/null 2>&1 || rc=$?
report "case20-acceptance-equal-version-rejected" 7 "$rc"
rc=0
( validate_acceptance_upgrade_target v1.8.33 ) >/dev/null 2>&1 || rc=$?
report "case20-acceptance-downgrade-rejected" 7 "$rc"
EMERGENCY_ROLLBACK=1
rc=0
( validate_acceptance_upgrade_target v1.8.33 && validate_emergency_target v1.8.33 ) >/dev/null 2>&1 || rc=$?
report "case20-emergency-downgrade-reaches-existing-gate" 0 "$rc"

################################################################
# Case 21 — validating the installed version must not overwrite
# the acceptance target selected by the installer transaction.
################################################################
printf '#!/usr/bin/env bash\nprintf "1.8.30\\n"\n' > "$BINARY_PATH"
chmod +x "$BINARY_PATH"
reset_mocks
MACPROVIDER_VERSION="v1.8.33"
MACPROVIDER_ACCEPTANCE_ASSET_DIR="$acceptance_dir"
MACPROVIDER_ACCEPTANCE_COMMIT="$(printf 'a%.0s' {1..40})"
MACPROVIDER_ACCEPTANCE_CONTROL_COMMIT="$(printf 'b%.0s' {1..40})"
MACPROVIDER_ACCEPTANCE_RUN_ID="123456789"
MACPROVIDER_ACCEPTANCE_RUN_ATTEMPT="2"
rc=0
observed_tag="$(
  tag="$(resolve_release_tag)"
  validate_acceptance_upgrade_target "$tag"
  printf '%s' "$tag"
)" || rc=$?
report "case21-older-install-accepts-newer-candidate" 0 "$rc"
report "case21-installed-version-does-not-rewrite-target" "v1.8.33" "$observed_tag"

################################################################
# Case 21b — the installed compatibility preflight follows the normal
# ~/.local/bin symlink to the real support-directory provider binary.
################################################################
REAL_INSTALLED_BINARY="$INSTALL_DIR/macprovider-cli"
cat > "$REAL_INSTALLED_BINARY" <<'SCRIPT'
#!/usr/bin/env bash
case "${1:-}" in
  --version)
    printf '1.8.40\n'
    ;;
  release-payload-preflight)
    printf '{"compatibility_set_id":"Augustas11/macprovider:v1.8.41@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","status":"valid","version":"1.8.41"}\n'
    ;;
  *)
    exit 2
    ;;
esac
SCRIPT
chmod +x "$REAL_INSTALLED_BINARY"
rm -f "$BINARY_PATH"
ln -s "$REAL_INSTALLED_BINARY" "$BINARY_PATH"
printf '{}\n' > "$INSTALL_DIR/compatibility-set.json"
reset_mocks
MACPROVIDER_ACCEPTANCE_ASSET_DIR="$acceptance_dir"
rc=0
( validate_acceptance_upgrade_target v1.8.42 ) >/dev/null 2>&1 || rc=$?
report "case21b-newer-set-release-accepted" 0 "$rc"
rc=0
( validate_acceptance_upgrade_target v1.8.41 ) >/dev/null 2>&1 || rc=$?
report "case21b-equal-set-release-rejected" 7 "$rc"

cat > "$REAL_INSTALLED_BINARY" <<'SCRIPT'
#!/usr/bin/env bash
case "${1:-}" in
  --version)
    printf '1.8.40\n'
    ;;
  release-payload-preflight)
    printf '{"status":"valid","version":"1.8.40"}\n'
    ;;
  *)
    exit 2
    ;;
esac
SCRIPT
chmod +x "$REAL_INSTALLED_BINARY"
rc=0
( validate_acceptance_upgrade_target v1.8.108 ) >/dev/null 2>&1 || rc=$?
report "case21b-malformed-successful-preflight-rejected" 7 "$rc"

cat > "$REAL_INSTALLED_BINARY" <<'SCRIPT'
#!/usr/bin/env bash
case "${1:-}" in
  --version)
    printf '1.8.40\n'
    ;;
  release-payload-preflight)
    printf '%s\n' "$MOCK_SUCCESSFUL_PREFLIGHT_JSON"
    ;;
  *)
    exit 2
    ;;
esac
SCRIPT
chmod +x "$REAL_INSTALLED_BINARY"
MOCK_SUCCESSFUL_PREFLIGHT_JSON='{"compatibility_set_id":null,"status":"valid","version":"1.8.40"}'
export MOCK_SUCCESSFUL_PREFLIGHT_JSON
rc=0
( validate_acceptance_upgrade_target v1.8.108 ) >/dev/null 2>&1 || rc=$?
report "case21b-null-preflight-identity-rejected" 7 "$rc"
MOCK_SUCCESSFUL_PREFLIGHT_JSON='{"compatibility_set_id":"Augustas11/macprovider:v1.8.40@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","status":"invalid","status":"valid","version":"1.8.40"}'
rc=0
( validate_acceptance_upgrade_target v1.8.108 ) >/dev/null 2>&1 || rc=$?
report "case21b-duplicate-preflight-key-rejected" 7 "$rc"
MOCK_SUCCESSFUL_PREFLIGHT_JSON='{"compatibility_set_id":"Augustas11/macprovider:v1.8.39@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","status":"valid","version":"1.8.40"}'
rc=0
( validate_acceptance_upgrade_target v1.8.108 ) >/dev/null 2>&1 || rc=$?
report "case21b-mismatched-preflight-identity-version-rejected" 7 "$rc"
unset MOCK_SUCCESSFUL_PREFLIGHT_JSON

################################################################
# Case 21b2 — a legacy headless smoke incumbent whose compatibility
# preflight fails may fall back to its bounded semantic version, but
# only a strictly newer signed acceptance candidate is accepted.
################################################################
cat > "$REAL_INSTALLED_BINARY" <<'SCRIPT'
#!/usr/bin/env bash
case "${1:-}" in
  --version)
    printf '%s\n' "${MOCK_LEGACY_VERSION:-1.8.40}"
    ;;
  release-payload-preflight)
    if [ "${MOCK_LEGACY_PREFLIGHT_VARIANT:-exact}" = "altered" ]; then
      printf "Error: Unknown option '--config'\n" >&2
      printf 'Usage: macprovider-cli credentials <subcommand>\n' >&2
    else
      printf "Error: Unknown option '--config'\n" >&2
      printf 'Usage: macprovider-cli credentials <subcommand>\n' >&2
      printf "  See 'macprovider-cli credentials --help' for more information.\n" >&2
    fi
    exit "${MOCK_LEGACY_PREFLIGHT_EXIT:-2}"
    ;;
  *)
    exit 2
    ;;
esac
SCRIPT
chmod +x "$REAL_INSTALLED_BINARY"
MOCK_LEGACY_VERSION="1.8.105"
export MOCK_LEGACY_VERSION
rc=0
( validate_acceptance_upgrade_target v1.8.108 ) >/dev/null 2>&1 || rc=$?
report "case21b2-legacy-smoke-older-version-accepted" 0 "$rc"
MOCK_LEGACY_VERSION="1.8.104"
rc=0
( validate_acceptance_upgrade_target v1.8.108 ) >/dev/null 2>&1 || rc=$?
report "case21b2-unrelated-older-incumbent-rejected" 7 "$rc"
MOCK_LEGACY_VERSION="1.8.105"
rc=0
( validate_acceptance_upgrade_target v1.8.109 ) >/dev/null 2>&1 || rc=$?
report "case21b2-later-acceptance-target-rejected" 7 "$rc"
MOCK_LEGACY_VERSION="1.8.108"
rc=0
( validate_acceptance_upgrade_target v1.8.108 ) >/dev/null 2>&1 || rc=$?
report "case21b2-legacy-smoke-equal-version-rejected" 7 "$rc"
MOCK_LEGACY_VERSION="1.8.109"
rc=0
( validate_acceptance_upgrade_target v1.8.108 ) >/dev/null 2>&1 || rc=$?
report "case21b2-legacy-smoke-newer-version-rejected" 7 "$rc"
MOCK_LEGACY_VERSION="not-a-version"
rc=0
( validate_acceptance_upgrade_target v1.8.108 ) >/dev/null 2>&1 || rc=$?
report "case21b2-legacy-smoke-malformed-version-rejected" 7 "$rc"
MOCK_LEGACY_VERSION="1.8."$'\n'"105"
rc=0
( validate_acceptance_upgrade_target v1.8.108 ) >/dev/null 2>&1 || rc=$?
report "case21b2-legacy-smoke-multiline-version-rejected" 7 "$rc"
MOCK_LEGACY_VERSION="1.8.105"
MOCK_LEGACY_PREFLIGHT_EXIT="99"
export MOCK_LEGACY_PREFLIGHT_EXIT
rc=0
( validate_acceptance_upgrade_target v1.8.108 ) >/dev/null 2>&1 || rc=$?
report "case21b2-arbitrary-preflight-failure-rejected" 7 "$rc"
unset MOCK_LEGACY_PREFLIGHT_EXIT
MOCK_LEGACY_PREFLIGHT_VARIANT="altered"
export MOCK_LEGACY_PREFLIGHT_VARIANT
rc=0
( validate_acceptance_upgrade_target v1.8.108 ) >/dev/null 2>&1 || rc=$?
report "case21b2-altered-preflight-error-rejected" 7 "$rc"
unset MOCK_LEGACY_PREFLIGHT_VARIANT
unset MOCK_LEGACY_VERSION
rm -f "$INSTALL_DIR/compatibility-set.json"

################################################################
# Case 21c — an independent provider component may stay equal or advance,
# but cannot downgrade outside the separately gated emergency rollback path.
################################################################
EMERGENCY_ROLLBACK=0
rc=0
( validate_acceptance_provider_component_target 1.8.40 ) >/dev/null 2>&1 || rc=$?
report "case21c-equal-provider-component-accepted" 0 "$rc"
rc=0
( validate_acceptance_provider_component_target 1.8.41 ) >/dev/null 2>&1 || rc=$?
report "case21c-newer-provider-component-accepted" 0 "$rc"
rc=0
( validate_acceptance_provider_component_target 1.8.39 ) >/dev/null 2>&1 || rc=$?
report "case21c-provider-component-downgrade-rejected" 7 "$rc"
EMERGENCY_ROLLBACK=1
rc=0
( validate_acceptance_provider_component_target 1.8.39 ) >/dev/null 2>&1 || rc=$?
report "case21c-emergency-provider-downgrade-reaches-existing-gates" 0 "$rc"
rm -f "$BINARY_PATH" "$REAL_INSTALLED_BINARY"

################################################################
# Case 21d — the staged executable must report the exact provider component
# version extracted from the verified signed compatibility manifest.
################################################################
staging_dir="$workdir/staging"
mkdir -p "$staging_dir"
cat > "$staging_dir/macprovider-cli" <<'SCRIPT'
#!/usr/bin/env bash
printf '1.8.40\n'
SCRIPT
chmod +x "$staging_dir/macprovider-cli"
rc=0
( validate_staged_acceptance_provider_component 1.8.40 ) >/dev/null 2>&1 || rc=$?
report "case21d-staged-provider-matches-signed-component" 0 "$rc"
rc=0
( validate_staged_acceptance_provider_component 1.8.41 ) >/dev/null 2>&1 || rc=$?
report "case21d-staged-provider-mismatch-rejected" 5 "$rc"
rm -rf "$staging_dir"

################################################################
# Case 22 — the locked transaction rejects stale-snapshot pinned
# downgrades while allowing same-version repair and normal upgrade.
# main() acquires the install lock before this check, so the tested
# decision is made against the binary present at mutation time.
################################################################
write_installed_version() {
  printf '#!/usr/bin/env bash\nprintf "%s\\n"\n' "$1" > "$BINARY_PATH"
  chmod +x "$BINARY_PATH"
}

reset_mocks
MACPROVIDER_VERSION="v1.8.39"
write_installed_version "1.8.40"
rc=0
( validate_non_emergency_pinned_target v1.8.39 ) >/dev/null 2>&1 || rc=$?
report "case22-newer-installed-version-rejects-pinned-downgrade" 7 "$rc"

write_installed_version "1.8.39"
rc=0
( validate_non_emergency_pinned_target v1.8.39 ) >/dev/null 2>&1 || rc=$?
report "case22-equal-installed-version-allows-repair" 0 "$rc"

write_installed_version "1.8.38"
rc=0
( validate_non_emergency_pinned_target v1.8.39 ) >/dev/null 2>&1 || rc=$?
report "case22-older-installed-version-allows-upgrade" 0 "$rc"

EMERGENCY_ROLLBACK=1
write_installed_version "1.8.40"
rc=0
( validate_non_emergency_pinned_target v1.8.39 ) >/dev/null 2>&1 || rc=$?
report "case22-emergency-downgrade-reaches-existing-gates" 0 "$rc"

reset_mocks
MACPROVIDER_VERSION="v01.8.39"
rc=0
( resolve_release_tag ) >/dev/null 2>&1 || rc=$?
report "case22-leading-zero-version-rejected" 7 "$rc"

reset_mocks
MACPROVIDER_VERSION="v9999999999.8.39"
rc=0
( resolve_release_tag ) >/dev/null 2>&1 || rc=$?
report "case22-oversized-version-component-rejected" 7 "$rc"

if [ "$fail" -ne 0 ]; then
  printf '[install-version-pin-test] %d failed, %d passed\n' "$fail" "$pass" >&2
  exit 1
fi

printf '[install-version-pin-test] all %d checks passed\n' "$pass"
