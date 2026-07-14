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

for symbol in latest_release_tag validate_macprovider_version_tag resolve_release_tag download_release verify_sha256 validate_staged_entries validate_emergency_target verify_emergency_coordinator_advertisement validate_emergency_config_backup stage_emergency_config_backup disable_staged_autoupdate verify_emergency_config_activation config_without_provider_token_sha256 preserve_failed_bootstrap_identity; do
  grep -q "^${symbol}()" "$lib" || fatal "could not extract $symbol from $INSTALL_SH"
done

MACPROVIDER_MIN_SUPPORTED_VERSION="v1.7.11"
MACPROVIDER_MIN_EMERGENCY_VERSION="v1.8.33"
GITHUB_REPO="Augustas11/macprovider"
TMPDIR_PATH=""
asset_path=""
asset_kind=""
checksums_path=""
checksums_sig_path=""
DOWNLOAD_LOG="$workdir/downloads.log"
LOG_FILE="$workdir/log.out"
BINARY_PATH="$workdir/installed-macprovider-cli"

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
  unset MACPROVIDER_VERSION
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
# Case 12 — emergency rollback adds the v1.8.33-compatible top-level
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
( validate_emergency_target v1.8.33 ) >/dev/null 2>&1 || rc=$?
report "case13-older-target-accepted" 0 "$rc"
rc=0
( validate_emergency_target v1.8.34 ) >/dev/null 2>&1 || rc=$?
report "case13-equal-target-rejected" 7 "$rc"
rc=0
( validate_emergency_target v1.8.35 ) >/dev/null 2>&1 || rc=$?
report "case13-newer-target-rejected" 7 "$rc"

rc=0
( verify_emergency_coordinator_advertisement https://coordinator.example v1.8.33 ) >/dev/null 2>&1 || rc=$?
report "case13-exact-advertisement-accepted" 0 "$rc"
MOCK_HEALTH_JSON='{"recommended_binary_version":"1.8.29"}'
rc=0
( verify_emergency_coordinator_advertisement https://coordinator.example v1.8.33 ) >/dev/null 2>&1 || rc=$?
report "case13-mismatched-advertisement-rejected" 7 "$rc"

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
# Case 15 — a v1.8.33 emergency activation may remove only the
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
# Case 16 — failed tokenless v1.8.33 bootstrap identity recovery
# preserves the transaction-restored legacy bearer for an old binary.
################################################################
failed_config="$workdir/failed-tokenless.yaml"
restored_config="$workdir/restored-token-bearing.yaml"
restored_provider_id="$workdir/restored-provider-id"
provider_id="mp-0123456789abcdef0123456789abcdef"
legacy_token="$(printf 'a%.0s' {1..64})"
printf 'provider_id: %s\nmodel: new-model\n' "$provider_id" > "$failed_config"
printf 'provider_id: old-provider\nprovider_token: %s\nmodel: old-model\n' "$legacy_token" > "$restored_config"
preserve_failed_bootstrap_identity "$failed_config" "$restored_config" "$restored_provider_id"
report "case16-tokenless-failure-preserves-restored-bearer" 1 \
  "$(grep -c "^provider_token: $legacy_token$" "$restored_config")"
report "case16-tokenless-failure-preserves-new-provider-id" 1 \
  "$(grep -c "^provider_id: \"$provider_id\"$" "$restored_config")"

if [ "$fail" -ne 0 ]; then
  printf '[install-version-pin-test] %d failed, %d passed\n' "$fail" "$pass" >&2
  exit 1
fi

printf '[install-version-pin-test] all %d checks passed\n' "$pass"
