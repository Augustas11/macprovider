#!/usr/bin/env bash
# RFC-001 §7 / F5 (#1386): watchdog supervisor-beacon emission unit test.
#
# Extracts the beacon helper block from the standalone watchdog and exercises it
# with stubbed boot-id/ts, so the beacon-emit path (which is otherwise only
# reachable via a live wedge restart) has committed coverage. Regression anchor
# for the field-shift bug: a null token_age_ms must NOT shift columns / flip
# active_inference (0x1f delimiter, not tab).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
WATCHDOG="$REPO_ROOT/ops/macprovider-watchdog/watchdog.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Extract the beacon function block (marker → just before autoupdate_recovery_tick).
awk '/^# --- SPEC-025 §5.4 \/ RFC-001 F5 supervisor telemetry beacon/{f=1} f&&/^autoupdate_recovery_tick\(\) \{/{exit} f' \
  "$WATCHDOG" > "$TMP/beacon.sh"
[ -s "$TMP/beacon.sh" ] || { echo "FAIL: could not extract beacon block" >&2; exit 1; }

mkdir -p "$TMP/state"
run_emit() {
  # $1=kind $2=cooldown; SUP_* + TEST_* come from run_emit's own environment and
  # are BAKED into the harness (unescaped expansion below) — a subprocess would
  # not inherit a function-scoped env prefix, so we must substitute the values.
  cat > "$TMP/h.sh" <<HARNESS
set -euo pipefail
LABEL="${TEST_LABEL:-live.malibu.provider}"
STATE_DIR="$TMP/state"
BEACON_FILE="\$STATE_DIR/supervisor-beacon.json"
BEACON_BOOT_FILE="\$STATE_DIR/beacon_boot"; BEACON_SEQ_FILE="\$STATE_DIR/beacon_seq"
BEACON_RESTARTS_FILE="\$STATE_DIR/beacon_restarts"; BEACON_DEFERRALS_FILE="\$STATE_DIR/beacon_deferrals"
BEACON_LAST_RESTART_FILE="\$STATE_DIR/beacon_last_restart"; BEACON_LAST_DEFERRAL_FILE="\$STATE_DIR/beacon_last_deferral"
ts(){ printf '2026-09-05T00:00:00Z'; }
current_boot_id(){ printf '%s' "${TEST_BOOT:-BOOT-A}"; }
. "$TMP/beacon.sh"
SUP_INSTANCE="${SUP_INSTANCE:-}"; SUP_TOKEN_AGE="${SUP_TOKEN_AGE:-}"
SUP_ACTIVE_INF="${SUP_ACTIVE_INF:-}"; SUP_ACTIVE_INF_AGE="${SUP_ACTIVE_INF_AGE:-}"
emit_supervisor_beacon "$1" "${2:-armed}"
HARNESS
  bash "$TMP/h.sh"
}

jq_get() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$TMP/state/supervisor-beacon.json" "$1"; }

# 1) Restart with a NULL token_age_ms (the pre-first-token wedge case). Fields
#    must NOT shift: active_inference stays true, model_liveness correct.
SUP_INSTANCE="11111111-1111-1111-1111-111111111111" SUP_TOKEN_AGE="" SUP_ACTIVE_INF="true" SUP_ACTIVE_INF_AGE="42" \
  run_emit restart cooldown_active
python3 - "$TMP/state/supervisor-beacon.json" <<'PY'
import json,sys
b=json.load(open(sys.argv[1]))
assert b["kind"]=="restart" and b["seq"]==1 and b["restarts_total"]==1, b
lr=b["last_restart"]
assert lr["reason"]=="wedge" and lr["cooldown_state"]=="cooldown_active", lr
assert lr["service_instance"]=="11111111-1111-1111-1111-111111111111", lr
ml=lr["model_liveness"]
assert ml=={"token_age_ms":None,"active_inference":True,"active_inference_age_ms":42}, ("field shift!",ml)
PY

# 2) Topology beacon carries the sticky last_restart forward (seq advances).
run_emit beacon
python3 - "$TMP/state/supervisor-beacon.json" <<'PY'
import json,sys
b=json.load(open(sys.argv[1]))
assert b["kind"]=="beacon" and b["seq"]==2, b
assert b["last_restart"] is not None and b["last_restart"]["reason"]=="wedge", b
PY

# 3) Boot change resets seq/counters/sticky.
TEST_BOOT="BOOT-B" run_emit beacon
python3 - "$TMP/state/supervisor-beacon.json" <<'PY'
import json,sys
b=json.load(open(sys.argv[1]))
assert b["boot_id"]=="BOOT-B" and b["seq"]==1 and b["restarts_total"]==0, b
assert b["last_restart"] is None, b
PY

# 4) Legacy provider label maps to legacy-watchdog.
rm -rf "$TMP/state"; mkdir -p "$TMP/state"
TEST_LABEL="live.streamvc.macprovider" run_emit beacon
[ "$(jq_get supervisor_label)" = "legacy-watchdog" ] || { echo "FAIL: legacy label = $(jq_get supervisor_label)" >&2; exit 1; }

echo "watchdog supervisor beacon ok"
