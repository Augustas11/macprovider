#!/usr/bin/env bash
# Integrated reproduction of the #1189 stranded-provider failure.
#
# The component behaviors are already covered in isolation:
#   - provider_upgrade_transaction.test.sh : quiesce (both labels), HOME ACL
#     remediation, marker quarantine, cutover ordering.
#   - watchdog_rollback_paths.test.sh       : #1228 — a stale watchdog cannot
#     execute a rollback / restore an old release payload; it defers.
#
# What was NOT covered, and is exactly what gates asking a real provider to
# "download the new DMG and run Repair", is the *composition*: all four #1189
# ingredients present in ONE home at once, run through the real repair steps in
# order, proving they neutralize the failure together while preserving the
# provider's identity, models, and wallet. This test closes that gap on real
# macOS (real filesystem ACLs; launchd is mocked — the real-launchd + DMG + live
# coordinator rejoin remain a canary-Mac step, see the runbook).
#
# Fidelity: T1 (see docs/runbooks/provider-repair-1189-e2e.md). Not a substitute
# for the canary-Mac T3 run.

set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
  echo "SKIP: #1189 reproduction requires real macOS ACLs (uname=$(uname -s))" >&2
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"
TMP="$(mktemp -d)"

SBX="$TMP/home"
# The extracted repair helpers (remediate_repair_home_write_acl,
# validate_install_dir) read the real installer's $HOME directly, exactly as
# install.sh does when it runs for the logged-in user. Point it at the
# sandbox so those functions operate on $SBX instead of the operator's real
# home directory.
export HOME="$SBX"
acl_cleanup() {
  # Best-effort: strip any ACL we planted so teardown can remove the tree.
  /bin/chmod -a "group:everyone allow write,append" "$SBX" 2>/dev/null || true
  /bin/chmod -a "group:everyone deny delete" "$SBX" 2>/dev/null || true
  /bin/chmod -R -N "$SBX" 2>/dev/null || true
  rm -rf "$TMP"
}
trap acl_cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
note() { printf '  ✓ %s\n' "$*"; }

# --- extract the real repair functions from install.sh -----------------------
extract_function() {
  awk -v start="$1() {" '
    $0 == start { inside=1 }
    inside { print }
    inside && /^}$/ { exit }
  ' "$INSTALL_SH"
}

HELPERS="$TMP/helpers.sh"
for fn in \
  validate_install_dir \
  pid_is_live_non_zombie \
  remediate_repair_home_write_acl \
  quiesce_repair_watchdog_label_for_transaction \
  quiesce_repair_watchdogs_for_transaction; do
  extract_function "$fn" >> "$HELPERS"
done
# shellcheck source=/dev/null
source "$HELPERS" || fail "could not source extracted repair functions"

# --- extract the installer-inline watchdog (the adversary) -------------------
extract_inline_watchdog() {
  awk '
    /write_atomic_install_file "\$WATCHDOG_PATH" 0755 <<.WATCHDOG_EOF./ { inside=1; next }
    inside && /^WATCHDOG_EOF$/ { exit }
    inside { print }
  ' "$INSTALL_SH"
}
INLINE_WATCHDOG="$TMP/watchdog-inline.sh"
extract_inline_watchdog > "$INLINE_WATCHDOG"
[ -s "$INLINE_WATCHDOG" ] || fail "could not extract installer inline watchdog"
chmod +x "$INLINE_WATCHDOG"

# --- test doubles ------------------------------------------------------------
log() { :; }
die() { echo "die($1): ${2:-}" >&2; exit "$1"; }

LAUNCHD_DOMAIN="gui/$(id -u)"
WATCHDOG_LABEL="live.malibu.provider-watchdog"
LEGACY_WATCHDOG_LABEL="live.streamvc.macprovider-watchdog"
WATCHDOG_DIR="$SBX/.local/share/macprovider/watchdog"
WATCHDOG_PATH="$WATCHDOG_DIR/watchdog.sh"
WATCHDOG_BOOTSTRAP_PATH="$WATCHDOG_PATH"
WATCHDOG_PLIST_BOOTSTRAP_PATH="$SBX/Library/LaunchAgents/$WATCHDOG_LABEL.plist"
LEGACY_WATCHDOG_PLIST_BOOTSTRAP_PATH="$SBX/Library/LaunchAgents/$LEGACY_WATCHDOG_LABEL.plist"
REPAIR_EXISTING_INSTALL=1

QUIESCE_LOG="$TMP/quiesce.log"
: > "$QUIESCE_LOG"

# Mock launchd: both labels report as loaded (identity-valid) before bootout,
# then unloaded afterwards. Mirrors the shape validated in
# provider_upgrade_transaction.test.sh.
launchctl_service() {
  case "$*" in
    "print $LAUNCHD_DOMAIN/$WATCHDOG_LABEL")
      printf '    program = %s\n    path = %s\n' "$WATCHDOG_PATH" "$WATCHDOG_PLIST_BOOTSTRAP_PATH" ;;
    "print $LAUNCHD_DOMAIN/$LEGACY_WATCHDOG_LABEL")
      printf '    program = %s\n    path = %s\n' "$WATCHDOG_PATH" "$LEGACY_WATCHDOG_PLIST_BOOTSTRAP_PATH" ;;
    "bootout $LAUNCHD_DOMAIN/$WATCHDOG_LABEL")
      printf 'bootout %s\n' "$WATCHDOG_LABEL" >> "$QUIESCE_LOG" ;;
    "bootout $LAUNCHD_DOMAIN/$LEGACY_WATCHDOG_LABEL")
      printf 'bootout %s\n' "$LEGACY_WATCHDOG_LABEL" >> "$QUIESCE_LOG" ;;
    *) return 0 ;;
  esac
}
launchd_print_loaded() { return 1; }   # unloaded after bootout

# --- build ONE home containing all four #1189 ingredients --------------------
# `mkdir -p ... -m 700` only sets the mode on each leaf; $SBX itself (now also
# $HOME, see above) needs its own chmod to match a real, non-world-readable
# provider HOME.
mkdir -p "$SBX" && chmod 700 "$SBX"
mkdir -m 700 -p \
  "$SBX/.config/macprovider" \
  "$SBX/Library/Application Support/macprovider" \
  "$SBX/Library/LaunchAgents" \
  "$SBX/.local/bin" \
  "$SBX/.local/share/macprovider/models/seed" \
  "$SBX/.local/share/macprovider/autoupdate" \
  "$WATCHDOG_DIR" \
  "$SBX/logs"

# identity / config / manifest / plist
PROVIDER_ID="mp-0123456789abcdef0123456789abcdef"
CONFIG_PATH="$SBX/.config/macprovider/config.yaml"
PROVIDER_ID_PATH="$SBX/.config/macprovider/provider_id"
WALLET_PATH="$SBX/.config/macprovider/wallet.json"
MODEL_PATH="$SBX/.local/share/macprovider/models/seed/weights.bin"
printf 'model: "seed"\nprovider_id: "%s"\ncoordinator_url: "wss://coordinator.example/ws/provider"\n' "$PROVIDER_ID" > "$CONFIG_PATH"
printf '%s\n' "$PROVIDER_ID" > "$PROVIDER_ID_PATH"
printf '{"address":"0xWALLET","rewards":"preserve-me"}\n' > "$WALLET_PATH"
printf 'MODEL_WEIGHTS_DO_NOT_TOUCH' > "$MODEL_PATH"
chmod 600 "$CONFIG_PATH" "$PROVIDER_ID_PATH" "$WALLET_PATH"

# installer-inline watchdog on disk (identity target for quiesce)
cp "$INLINE_WATCHDOG" "$WATCHDOG_PATH"; chmod 755 "$WATCHDOG_PATH"

# both watchdog plists (current + legacy), owner-private
for p in "$WATCHDOG_PLIST_BOOTSTRAP_PATH" "$LEGACY_WATCHDOG_PLIST_BOOTSTRAP_PATH"; do
  printf '<plist><dict><key>Program</key><string>%s</string></dict></plist>\n' "$WATCHDOG_PATH" > "$p"
  chmod 600 "$p"
done

# ingredient 3: stale pending marker + rollback backup binary (the #1228 trap)
BIN_DIR="$SBX/.local/bin"
NEW_BINARY="$BIN_DIR/macprovider-cli"
ROLLBACK_UUID="123e4567-e89b-42d3-a456-426614174000"
ROLLBACK_BACKUP="$BIN_DIR/.macprovider-cli.rollback-$ROLLBACK_UUID"
printf 'REPAIRED_NEW_BINARY' > "$NEW_BINARY"
printf 'OLD_STALE_BINARY'    > "$ROLLBACK_BACKUP"
chmod 755 "$NEW_BINARY" "$ROLLBACK_BACKUP"
ROLLBACK_HASH="$(shasum -a 256 "$ROLLBACK_BACKUP" | awk '{print $1}')"
PENDING="$SBX/.local/share/macprovider/autoupdate/pending.json"
cat > "$PENDING" <<EOF
{"update_id":"$ROLLBACK_UUID","target_version":"1.8.10","target_path":"$NEW_BINARY","backup_path":"$ROLLBACK_BACKUP","size":16,"mode":493,"sha256":"$ROLLBACK_HASH","marker_deadline":"2000-01-01T00:00:00Z"}
EOF

# byte-level fingerprints of everything that MUST survive repair
fingerprint() { shasum -a 256 "$CONFIG_PATH" "$PROVIDER_ID_PATH" "$WALLET_PATH" "$MODEL_PATH" | awk '{print $1}'; }
IDENTITY_BEFORE="$(fingerprint)"

INSTALL_DIR="$BIN_DIR"

echo "== #1189 integrated reproduction =="

# --- ingredient 4: the real HOME ACL barrier --------------------------------
# Exactly the shape remediate_repair_home_write_acl recognizes.
/bin/chmod +a "group:everyone deny delete" "$SBX" 2>/dev/null || true
if ! /bin/chmod +a "group:everyone allow write,append" "$SBX" 2>/dev/null; then
  echo "SKIP: cannot set test ACL on this filesystem" >&2
  exit 0
fi
/bin/ls -lde "$SBX" | grep -q "everyone allow" || fail "ACL barrier did not apply"
note "planted HOME ACL barrier + deny-delete (real filesystem ACL)"

# ================= PHASE A: adversary is live, before repair =================
# The stale watchdog runs while the pending/rollback trap is armed. It must
# DEFER (not roll back), even with the ACL barrier present.
# Fake launchctl resolved via PATH as `launchctl` (matching
# watchdog_rollback_paths.test.sh). No MACPROVIDER_LAUNCHCTL override, so the
# watchdog uses this fake and never the host launchd.
mkdir -p "$TMP/wdbin"
cat > "$TMP/wdbin/launchctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MACPROVIDER_FAKE_LAUNCHCTL_LOG:-/dev/null}"
case "${1:-}" in
  list) printf -- '-\t0\tlive.malibu.provider-compatibility-reload\n' ;;
  print) printf 'pid = 123\nlast exit status = 0\n' ;;
  bootstrap|kickstart|bootout) exit 99 ;;
esac
EOF
chmod +x "$TMP/wdbin/launchctl"

# Fake `lsof`: the real #1189 provider process was up and healthy — only the
# repair path (ACL/markers/stale watchdog label) was stuck. Reproduce that by
# letting provider_process_pid() resolve the launchctl-reported pid to the
# repaired binary, so the tick takes the "process is present" path instead of
# the unrelated missing-process kickstart path (a different code path from the
# #1228 rollback-deferral this phase exercises). No `port:` is set in the
# sandbox config, so local_provider_health_ok() short-circuits before ever
# needing a fake curl/health listener, and the watchdog's own "disarmed for
# this boot" guard (fresh $STATE_DIR, no prior ARMED_FILE) exits clean without
# any restart decision — so this does not launder a real health check.
cat > "$TMP/wdbin/lsof" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"-d txt -Fn"*) printf 'n%s\n' "${MACPROVIDER_FAKE_LSOF_TXT_PATH:?}" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TMP/wdbin/lsof"

run_watchdog() {
  HOME="$SBX" \
  MACPROVIDER_BINARY_PATH="$NEW_BINARY" \
  MACPROVIDER_LOG_DIR="$SBX/logs" \
  MACPROVIDER_FAKE_LAUNCHCTL_LOG="$TMP/wd-launchctl.log" \
  MACPROVIDER_FAKE_LSOF_TXT_PATH="$NEW_BINARY" \
  PATH="$TMP/wdbin:/usr/bin:/bin:/usr/sbin:/sbin" \
  bash "$WATCHDOG_PATH" --reconcile-autoupdate
}
: > "$TMP/wd-launchctl.log"

run_watchdog
cmp -s "$NEW_BINARY"      <(printf 'REPAIRED_NEW_BINARY') || fail "A: watchdog rolled back the new binary"
cmp -s "$ROLLBACK_BACKUP" <(printf 'OLD_STALE_BINARY')    || fail "A: watchdog mutated the rollback backup"
[ -e "$PENDING" ] || fail "A: watchdog consumed the pending marker instead of deferring"
grep -Fq "autoupdate recovery deferred: pending marker exists; transaction owner must resolve update/rollback state" "$SBX/logs/watchdog.log" \
  || fail "A: watchdog did not log the #1228 deferral"
if grep -Eq '(^| )(bootout|bootstrap|kickstart)( |$)' "$TMP/wd-launchctl.log"; then
  fail "A: deferring watchdog must not touch launchctl"
fi
note "PHASE A: stale watchdog DEFERRED under the full trap (no rollback, marker preserved) — #1228"

# ================= PHASE B: run the real repair preflight ====================
quiesce_repair_watchdogs_for_transaction \
  || fail "B: repair could not quiesce the watchdogs"
grep -Fq "bootout $WATCHDOG_LABEL"        "$QUIESCE_LOG" || fail "B: current watchdog label not booted out"
grep -Fq "bootout $LEGACY_WATCHDOG_LABEL" "$QUIESCE_LOG" || fail "B: legacy watchdog label not booted out"
note "PHASE B1: quiesced BOTH current and legacy watchdog labels"

remediate_repair_home_write_acl \
  || fail "B: repair could not remediate the HOME ACL barrier"
if /bin/ls -lde "$SBX" | grep -Eq "everyone allow (write|add_file)"; then
  fail "B: HOME write ACL barrier survived remediation"
fi
note "PHASE B2: remediated the HOME ACL barrier (real chmod -a); write path restored"

[ "$(fingerprint)" = "$IDENTITY_BEFORE" ] \
  || fail "B: identity/config/wallet/model changed during repair preflight"
note "PHASE B3: identity + config + wallet + model bytes UNCHANGED through preflight"

# ================= PHASE C: post-repair undo-proof ==========================
# A stale watchdog that wakes again after repair must not undo it.
: > "$TMP/wd-launchctl.log"
run_watchdog
cmp -s "$NEW_BINARY"      <(printf 'REPAIRED_NEW_BINARY') || fail "C: post-repair watchdog reverted the repaired binary"
cmp -s "$ROLLBACK_BACKUP" <(printf 'OLD_STALE_BINARY')    || fail "C: post-repair watchdog mutated the rollback backup"
[ "$(fingerprint)" = "$IDENTITY_BEFORE" ] || fail "C: identity changed after post-repair watchdog tick"
note "PHASE C: post-repair watchdog could NOT undo the repair — #1228 holds after cutover"

echo "== #1189 integrated reproduction OK =="
echo "NOTE: launchd is mocked here; real-launchd + DMG + live coordinator rejoin"
echo "      remain a canary-Mac step (docs/runbooks/provider-repair-1189-e2e.md)."
