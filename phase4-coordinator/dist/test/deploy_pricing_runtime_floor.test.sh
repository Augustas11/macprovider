#!/usr/bin/env bash
# #1693 pricing runtime floor (ARCH-001): once /opt/macprovider/.pricing-runtime-floor
# exists, deploy-pearl-vps.sh refuses (before any mutation) an incoming
# coordinator, or a live rollback target, without per-generation wholesale
# pricing; coordinator-deploy-recover.sh refuses to restore such a snapshot
# binary. Hermetic: the remote script runs locally against a temp root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
DEPLOY_SH="$SCRIPT_DIR/../deploy-pearl-vps.sh"
RECOVER="$SCRIPT_DIR/../coordinator-deploy-recover.sh"
TMP="$(umask 077 && mktemp -d -t pricing-floor-test.XXXXXXXX)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
note() { echo "ok: $*"; }

mkdir -p "$TMP/bin"
cat >"$TMP/bin/coordinator-new" <<'SH'
#!/bin/sh
case "$*" in *--expect-base-equivalent*) echo '{"ok":false,"model_resolutions":[],"errors":["config: probe"]}'; exit 1 ;; esac
exit 0
SH
cat >"$TMP/bin/coordinator-old" <<'SH'
#!/bin/sh
case "$*" in *--expect-base-equivalent*) echo 'flag provided but not defined: -expect-base-equivalent' >&2; exit 2 ;; esac
exit 0
SH
chmod 0755 "$TMP/bin/coordinator-new" "$TMP/bin/coordinator-old"

# --- deploy-pearl-vps.sh: the remote floor script -----------------------------
fn="$TMP/floor.sh"
awk '/^_pricing_runtime_floor_remote_script\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$DEPLOY_SH" >"$fn"
grep -qF '_pricing_runtime_floor_remote_script()' "$fn" || fail "deploy must keep an extractable pricing runtime floor script"
# shellcheck disable=SC1090
. "$fn"
ROOT="$TMP/opt/macprovider"
run_floor() { # <incoming|rollback-target> [incoming binary]
  local script
  script="$(_pricing_runtime_floor_remote_script "$1")"
  script="${script//ROOT=\"\/opt\/macprovider\"/ROOT=\"$ROOT\"}"
  sh -c "$script" <"${2:-/dev/null}"
}
reset_root() { rm -rf "$ROOT"; mkdir -p "$ROOT"; }

reset_root; cp "$TMP/bin/coordinator-old" "$ROOT/coordinator"
run_floor incoming "$TMP/bin/coordinator-old" >/dev/null || fail "without the floor marker a pre-#1693 incoming binary must be allowed"
run_floor rollback-target >/dev/null || fail "without the floor marker a pre-#1693 rollback target must be allowed"
note "no floor marker: any incoming coordinator and rollback target are allowed"

reset_root; touch "$ROOT/.pricing-runtime-floor"; cp "$TMP/bin/coordinator-new" "$ROOT/coordinator"
rc=0; run_floor incoming "$TMP/bin/coordinator-old" 2>"$TMP/err" >/dev/null || rc=$?
[ "$rc" = 64 ] && grep -q 'PRICING RUNTIME FLOOR: refusing: the incoming coordinator lacks per-generation wholesale pricing' "$TMP/err" \
  || fail "floor marker + pre-#1693 incoming binary must refuse with 64 (rc=$rc): $(cat "$TMP/err")"
note "floor marker: a pre-#1693 incoming coordinator is refused (64)"

reset_root; touch "$ROOT/.pricing-runtime-floor"; cp "$TMP/bin/coordinator-old" "$ROOT/coordinator"
run_floor incoming "$TMP/bin/coordinator-new" >/dev/null || fail "the incoming check probes only the incoming binary"
rc=0; run_floor rollback-target 2>"$TMP/err" >/dev/null || rc=$?
[ "$rc" = 65 ] && grep -q "rollback target" "$TMP/err" || fail "floor marker + pre-#1693 live rollback target must refuse with 65 (rc=$rc): $(cat "$TMP/err")"
note "floor marker: a pre-#1693 live coordinator (rollback target) is refused (65)"

reset_root; touch "$ROOT/.pricing-runtime-floor"; cp "$TMP/bin/coordinator-new" "$ROOT/coordinator"
run_floor incoming "$TMP/bin/coordinator-new" >/dev/null && run_floor rollback-target >/dev/null \
  || fail "floor marker + #1693 incoming and live coordinators must pass"
reset_root; touch "$ROOT/.pricing-runtime-floor"
run_floor rollback-target >/dev/null || fail "floor marker + no live coordinator must pass"
rc=0; _pricing_runtime_floor_remote_script bogus >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "an unknown floor mode must be rejected"
note "floor marker: #1693 incoming and rollback-target coordinators pass"

# Placement: the incoming check runs after the pricing-journal refusal and
# before step 0a; the rollback-target check after step 0a (which may restore
# the live binary) and before step 0b; both outside --dry-run-local.
python3 - "$DEPLOY_SH" <<'PY' || fail "deploy floor check placement"
import sys
d = open(sys.argv[1]).read()
journal = d.index("test -e /opt/macprovider/.pricing-txn || test -L /opt/macprovider/.pricing-txn")
incoming = d.index('$SSH "$(_pricing_runtime_floor_remote_script incoming)" <"$BINARY"')
target = d.index('$SSH "$(_pricing_runtime_floor_remote_script rollback-target)" </dev/null')
step0a = d.index('coordinator-deploy-recover --recover-under-global ||')
assert journal < incoming < d.index('log "step 0a/9') < step0a < target < d.index('log "step 0b/9') < d.index('log "step 0/9'), "floor check placement"
for at in (incoming, target):
    assert "pricing runtime floor check failed" in d[at:at + 400]
    assert "exit 12" in d[at:at + 400]
PY
note "deploy checks the incoming binary before step 0a and the rollback target after it, before step 0b"

# --- coordinator-deploy-recover.sh: rollback target under the floor ----------
R="$TMP/rec/opt/macprovider"; SYSD="$TMP/rec/systemd"; LOG="$TMP/systemctl.log"
cat >"$TMP/bin/systemctl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
case "$*" in *"-p LoadState"*) echo not-found ;; esac
exit 0
SH
printf '#!/bin/sh\nexit 0\n' >"$TMP/bin/nginx"
chmod 0755 "$TMP/bin/systemctl" "$TMP/bin/nginx"
seed() { # <snapshot binary new|old> <floor 0|1>
  rm -rf "$TMP/rec"; mkdir -p "$R/autotune/releases/old" "$SYSD" "$TMP/rec/etc/macprovider"
  cp "$TMP/bin/coordinator-new" "$R/coordinator"
  local S="$R/.coordinator-deploy-rollback"; mkdir -p "$S"
  cp "$TMP/bin/coordinator-$1" "$S/coordinator"
  printf 'releases/old' >"$S/catalog-current-target"
  printf 'coordinator.yaml.bak-20260924T000000Z' >"$S/config-backup-name"
  touch "$S/complete" "$S/had-coordinator"
  [ "$2" = 0 ] || printf 'commit=%040d\n' 0 >"$R/.pricing-runtime-floor"
}
run_recover() {
  MACPROVIDER_ROOT="$R" MACPROVIDER_STATS_ROOT="$TMP/rec/stats" MACPROVIDER_SYSTEMD_ROOT="$SYSD" \
    MACPROVIDER_NGINX_ROOT="$TMP/rec/nginx" MACPROVIDER_ETC_ROOT="$TMP/rec/etc/macprovider" \
    MACPROVIDER_SYSTEMCTL="$TMP/bin/systemctl" SYSTEMCTL_LOG="$LOG" MACPROVIDER_NGINX="$TMP/bin/nginx" \
    MACPROVIDER_PRICING_GUARD_LIB=/nonexistent MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE="$TMP/global.lock" \
    MACPROVIDER_DEPLOY_LOCK_REQUIRED_UID="$(id -u)" MACPROVIDER_DEPLOY_LOCK_REQUIRED_GID="$(python3 -c 'import os,sys;print(os.stat(sys.argv[1]).st_gid)' "$TMP")" \
    sh "$RECOVER" --recover-under-global
}
seed old 1
rc=0; run_recover 2>"$TMP/err" || rc=$?
[ "$rc" = 1 ] && grep -q 'pricing runtime floor' "$TMP/err" || fail "floor + pre-#1693 snapshot binary must refuse (rc=$rc): $(cat "$TMP/err")"
[ -d "$R/.coordinator-deploy-rollback" ] || fail "a floor refusal must preserve the snapshot"
cmp -s "$R/coordinator" "$TMP/bin/coordinator-new" || fail "a floor refusal must not restore the binary"
[ ! -e "$LOG" ] || fail "a floor refusal must not touch systemd: $(cat "$LOG")"
note "deploy recovery: floor + pre-#1693 snapshot binary -> refused, snapshot preserved, nothing restored"

seed old 0
run_recover 2>"$TMP/err" || fail "without the floor a pre-#1693 snapshot must still restore: $(cat "$TMP/err")"
cmp -s "$R/coordinator" "$TMP/bin/coordinator-old" && [ ! -e "$R/.coordinator-deploy-rollback" ] || fail "no floor: the snapshot must be restored"
seed new 1
run_recover 2>"$TMP/err" || fail "floor + #1693 snapshot binary must restore: $(cat "$TMP/err")"
[ ! -e "$R/.coordinator-deploy-rollback" ] || fail "floor + #1693 snapshot: the snapshot must be consumed"
note "deploy recovery: no floor, or a #1693 snapshot binary -> restored"

echo "PASS: deploy pricing runtime floor"
