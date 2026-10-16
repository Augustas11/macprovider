#!/usr/bin/env bash
# #2015 / PR #2025 deferred hardware acceptance: encrypted KV disk tier with the
# kvsurv-codec-v2 recurrent format on the live Studio model. Lab only; never
# shipped. Run it ON the Studio.
#
# Isolation: a separate `serve --no-join` with credential_store protected_file
# (own control socket, lifecycle, lease root; no canonical re-exec), its own
# config dir, its own loopback port, its own disk-tier directory and its own
# provider_id namespace (so its Keychain DEKs never share a namespace with the
# live provider). The disk tier is toggled per session with
# --kv-disk-cache-enabled / --no-kv-disk-cache-enabled; the live config is only
# read (model geometry values), never written.
#
# This script NEVER pauses or resumes the live provider and never stops the
# buyer runner. RUN mode refuses to start unless the live provider on LIVE_PORT
# reports operator_paused=true and requests_in_flight=0. PREP_ONLY=1 does the
# no-GPU part (binary copy, config, Keychain/disk-tier preflight) and loads no
# model.
#
# Sessions (each one lab serve process, model loaded once):
#   off1  disk off  turn 1 of the repeat-prefix conversations + fresh refs
#   off2  disk off  (after restart) turn 2 = prefix miss: TTFT baseline
#   on1   disk on   turn 1 of persisted conversations, hot comparators,
#                   cancel/stop/length scenarios; paced writes
#   on2   disk on   (after restart) cold restores, fresh refs, divergent prefix
# then a verdict and a full purge (--all --forget) of the lab namespace.
#
# Run it through run-in-gui-domain.sh: the disk tier's Keychain DEKs are only
# reachable from the GUI security session (the live LaunchAgent's), not from
# SSH, where the tier goes dormant (-25308) and prep fails.
# Usage on the Studio:
#   PREP_ONLY=1 bash run-in-gui-domain.sh     # now; no model load
#   bash run-in-gui-domain.sh                 # inside the paused window
# Optional: LAB_DIR (~/lab-2015) LAB_PORT (18115) LIVE_PORT (8080)
#   SRC_INSTALL (~/macprovider) LAB_CONFIG_TEMPLATE (~/lab-1980/config-template.yaml)
#   LIVE_CONFIG (~/.config/macprovider/config.yaml, read only)
#   DOC_TOKENS (6000) TTFT_CONVERSATIONS (4) LOAD_TIMEOUT_S (900)
#   SELF_CHECK_TIMEOUT_S (1200) RUN_TIMEOUT_S (4500) KVCACHE_TIMEOUT_S (60)
#   SESSION_TIMEOUT_S (1800) LAB_PROVIDER_ID (derived from the binary identity)
#
# No step can block: every CLI call and driver session runs under a hard alarm
# (bounded), the whole run (prep included) is under RUN_TIMEOUT_S, and any
# timeout exits non-zero after stopping the lab serve and purging the lab
# namespace (the purge is bounded too).
#
# Keychain identity: the disk tier's DEKs live in the login keychain, and each
# item's ACL trusts the binary that created it. A lab build of a PR head is
# ad-hoc signed, so reading items created by the released Developer ID binary
# raises an "allow access" dialog in the GUI session (SecurityAgent) and the
# call blocks forever (the 2026-10-16 14:12Z hang). credential_store:
# protected_file covers provider credentials only, not the KV DEKs. So a
# binary that is not the released Developer ID gets its own lab namespace and
# kv directory, keyed by its CDHash, whose items it creates itself.
set -euo pipefail
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin

HERE="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="${LAB_DIR:-$HOME/lab-2015}"
LAB_PORT="${LAB_PORT:-18115}"
LIVE_PORT="${LIVE_PORT:-8080}"
SRC_INSTALL="${SRC_INSTALL:-$HOME/macprovider}"
LAB_CONFIG_TEMPLATE="${LAB_CONFIG_TEMPLATE:-$HOME/lab-1980/config-template.yaml}"
LIVE_CONFIG="${LIVE_CONFIG:-$HOME/.config/macprovider/config.yaml}"
EXPECT_VERSION="${EXPECT_VERSION:-1.8.248}"
LAB_PROVIDER_ID="${LAB_PROVIDER_ID:-}"
RELEASE_TEAM_ID="YF7XNRJUG4"
LOAD_TIMEOUT_S="${LOAD_TIMEOUT_S:-900}"
KVCACHE_TIMEOUT_S="${KVCACHE_TIMEOUT_S:-60}"
SESSION_TIMEOUT_S="${SESSION_TIMEOUT_S:-1800}"
SELF_CHECK_TIMEOUT_S="${SELF_CHECK_TIMEOUT_S:-1200}"
RUN_TIMEOUT_S="${RUN_TIMEOUT_S:-4500}"
export DOC_TOKENS="${DOC_TOKENS:-6000}" TTFT_CONVERSATIONS="${TTFT_CONVERSATIONS:-4}"

BIN_DIR="$LAB_DIR/bin"
CLI="$BIN_DIR/macprovider-cli"
CONF_DIR="$LAB_DIR/config"
CONFIG="$CONF_DIR/config.yaml"
KV_DIR=""   # set in prep from the namespace
DRIVER="$HERE/kv_acceptance.py"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$LAB_DIR/run-$STAMP"
mkdir -p "$OUT"
chmod 700 "$LAB_DIR"
log() { echo "[$(date -u +%TZ)] 2015-kv: $*" | tee -a "$OUT/summary.txt" >&2; }

[[ "$LAB_PORT" != "$LIVE_PORT" ]] || { log "LAB_PORT must differ from LIVE_PORT"; exit 2; }
[[ -f "$DRIVER" ]] || { log "missing $DRIVER"; exit 2; }
status_json() { curl -fsS --max-time 5 "http://127.0.0.1:$1/v1/status" 2>/dev/null; }
jget() { python3 -c "import json,sys
d=json.load(sys.stdin)
for p in sys.argv[1].split('.'):
    d=(d or {}).get(p) if isinstance(d, dict) else None
print(d)" "$1"; }

# bounded SECS CMD...: exec CMD under a SIGALRM after SECS seconds (exit 142 on
# timeout; the alarm survives exec and its default action terminates the CLI
# even while it waits on a Keychain dialog).
bounded() { local secs="$1"; shift; perl -e 'alarm shift @ARGV; exec @ARGV or die "exec: $!"' "$secs" "$@"; }
timed_out() { (( $1 == 142 )); }
kvcache() { bounded "$KVCACHE_TIMEOUT_S" "$CLI" kv-cache "$@" --config "$CONFIG"; }

# Whole-run watchdog, armed before prep: on expiry it stops the lab serve and
# every child, then TERMs this script (whose EXIT trap purges, bounded).
watchdog() {
  ( trap 'kill "$sp" 2>/dev/null; exit 0' TERM
    sleep "$RUN_TIMEOUT_S" & sp=$!; wait "$sp"
    echo "[$(date -u +%TZ)] 2015-kv: RUN_TIMEOUT_S=$RUN_TIMEOUT_S reached; stopping" >> "$OUT/summary.txt"
    pkill -TERM -f "serve --config $CONFIG" 2>/dev/null || true
    pkill -TERM -P $$ 2>/dev/null || true
    kill -TERM $$ 2>/dev/null || true
    sleep 20; pkill -KILL -f "serve --config $CONFIG" 2>/dev/null || true ) &
  WD=$!
}

# --- Prep (no model load) ---------------------------------------------------
prep() {
  [[ -x "$SRC_INSTALL/macprovider-cli" && -f "$SRC_INSTALL/mlx.metallib" ]] || { log "no released install at $SRC_INSTALL"; exit 2; }
  src_sha="$(shasum -a 256 "$SRC_INSTALL/macprovider-cli" | cut -d' ' -f1)"
  if [[ ! -x "$CLI" ]] || [[ "$(shasum -a 256 "$CLI" | cut -d' ' -f1)" != "$src_sha" ]]; then
    rm -rf "$BIN_DIR"
    mkdir -p "$BIN_DIR"
    # Fresh copy (new inode) of the released bytes; signature preserved.
    for f in macprovider-cli mlx.metallib compatibility-set.json mlx-swift_Cmlx.bundle swift-nio_NIOPosix.bundle; do
      [[ -e "$SRC_INSTALL/$f" ]] && ditto "$SRC_INSTALL/$f" "$BIN_DIR/$f"
    done
  fi
  [[ "$(shasum -a 256 "$CLI" | cut -d' ' -f1)" == "$src_sha" ]] || { log "binary copy differs from $SRC_INSTALL"; exit 2; }
  version="$("$CLI" --version)"
  [[ "$version" == "$EXPECT_VERSION" ]] || { log "lab binary reports $version, expected $EXPECT_VERSION"; exit 2; }
  codesign --verify --strict "$CLI" || { log "codesign verify failed on lab copy"; exit 2; }
  sig="$(codesign -dvvv "$CLI" 2>&1)"
  team="$(printf '%s\n' "$sig" | sed -n 's/^TeamIdentifier=//p')"
  cdhash="$(printf '%s\n' "$sig" | sed -n 's/^CDHash=//p' | head -1)"
  [[ "$cdhash" =~ ^[0-9a-f]{40}$ ]] || { log "cannot read CDHash of $CLI"; exit 2; }
  if [[ -z "$LAB_PROVIDER_ID" ]]; then
    if [[ "$team" == "$RELEASE_TEAM_ID" ]]; then LAB_PROVIDER_ID="lab-2015-kvs"
    else LAB_PROVIDER_ID="lab-2015-kvs-${cdhash:0:12}"; fi
  fi
  [[ "$LAB_PROVIDER_ID" =~ ^lab-2015-kvs(-[0-9a-f]{12})?$ ]] || { log "bad LAB_PROVIDER_ID $LAB_PROVIDER_ID"; exit 2; }
  if [[ "$LAB_PROVIDER_ID" == lab-2015-kvs ]]; then KV_DIR="$LAB_DIR/kv-cache"; else KV_DIR="$LAB_DIR/kv-cache-${LAB_PROVIDER_ID#lab-2015-kvs-}"; fi
  log "signing team=${team:-none} cdhash=$cdhash namespace=$LAB_PROVIDER_ID kv_dir=$KV_DIR"
  metallib_sha="$(shasum -a 256 "$BIN_DIR/mlx.metallib" | cut -d' ' -f1)"
  log "binary $CLI version=$version sha256=$src_sha metallib=$metallib_sha"

  [[ -f "$LAB_CONFIG_TEMPLATE" ]] || { log "no lab template $LAB_CONFIG_TEMPLATE"; exit 2; }
  grep -q "metallib_sha256: $metallib_sha" "$LAB_CONFIG_TEMPLATE" || { log "template accepted tuples do not name metallib $metallib_sha"; exit 2; }
  grep -q "^credential_store: protected_file\$" "$LAB_CONFIG_TEMPLATE" || { log "template must set credential_store: protected_file"; exit 2; }
  if grep -qE "^draft_model:[[:space:]]*[^[:space:]]" "$LAB_CONFIG_TEMPLATE"; then log "template sets draft_model"; exit 2; fi
  live_model="$(sed -n 's/^model:[[:space:]]*//p' "$LIVE_CONFIG" | head -1)"
  grep -q "^model: $live_model\$" "$LAB_CONFIG_TEMPLATE" || { log "template model differs from live $live_model"; exit 2; }
  live_conc="$(sed -n 's/^max_concurrency_override:[[:space:]]*//p' "$LIVE_CONFIG" | head -1)"
  live_queue="$(sed -n 's/^continuous_batch_queue_limit:[[:space:]]*//p' "$LIVE_CONFIG" | head -1)"
  live_cb="$(sed -n 's/^continuous_batching:[[:space:]]*//p' "$LIVE_CONFIG" | head -1)"
  [[ "$live_conc" =~ ^[0-9]+$ && "$live_queue" =~ ^[0-9]+$ && -n "$live_cb" ]] || { log "live concurrency/queue/cb unreadable"; exit 2; }

  mkdir -p "$CONF_DIR" "$KV_DIR"
  chmod 700 "$CONF_DIR" "$KV_DIR"
  # Mirror live serving shape (model, CB mode, concurrency, queue, paged KV from
  # the lab template); add the lab-only identity, socket and disk-tier block.
  # The tier stays disabled in YAML and is switched per session by CLI flag.
  python3 - "$LAB_CONFIG_TEMPLATE" "$CONFIG" "$LAB_PORT" "$live_conc" "$live_queue" "$live_cb" \
    "$LAB_PROVIDER_ID" "$LAB_DIR/ctl.sock" "$KV_DIR" <<'PY'
import sys
src, dst, port, conc, queue, cb, pid, sock, kvdir = sys.argv[1:]
want = {"port": port, "max_concurrency_override": conc, "continuous_batch_queue_limit": queue,
        "continuous_batching": cb, "provider_id": pid, "ctl_socket_path": sock}
drop = {"kv_disk_cache", "coordinator_url", "enable_receipts", "relay_blind_enabled", "privacy_class_beta"}
seen, out, skipping = set(), [], False
for line in open(src).read().splitlines():
    top = bool(line) and not line[0].isspace() and not line.startswith("-")
    key = line.split(":", 1)[0] if top and ":" in line else None
    if top:
        skipping = key in drop
    if skipping:
        continue
    if key in want:
        out.append(f"{key}: {want[key]}"); seen.add(key)
    else:
        out.append(line)
out += [f"{k}: {v}" for k, v in want.items() if k not in seen]
out += ["kv_disk_cache:",
        "  enabled: false",
        f"  directory: {kvdir}",
        "  max_bytes: 17179869184",
        "  max_entries: 64",
        "  staging_max_bytes: 1073741824",
        "  write_staging_max_bytes: 1073741824"]
open(dst, "w").write("\n".join(out) + "\n")
PY
  chmod 600 "$CONFIG"
  CONFIG_READY=1
  log "lab config $CONFIG port=$LAB_PORT max_concurrency=$live_conc queue=$live_queue continuous_batching=$live_cb provider_id=$LAB_PROVIDER_ID kv_dir=$KV_DIR"

  # Keychain + namespace preflight through the released CLI (no model load):
  # creates the lab namespace master key and directory, takes the free lock.
  local rc=0
  kvcache status > "$OUT/prep-kv-status.json" 2> "$OUT/prep-kv-status.err" || rc=$?
  if timed_out "$rc"; then
    log "kv-cache status TIMED OUT after ${KVCACHE_TIMEOUT_S}s (Keychain access dialog? SecurityAgent: $(pgrep -x SecurityAgent | tr '\n' ' '))"
    exit 3
  fi
  st="$(jget status < "$OUT/prep-kv-status.json" 2>/dev/null || echo none)"
  ns="$(jget namespace_id < "$OUT/prep-kv-status.json" 2>/dev/null || echo none)"
  [[ "$st" == ok && "$ns" == "$LAB_PROVIDER_ID" ]] || {
    log "kv-cache status preflight failed (status=$st namespace=$ns); see $OUT/prep-kv-status.err"; exit 3; }
  log "kv-cache preflight ok: $(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print({k: d[k] for k in ("entry_count","bytes_used","keychain_item_count","key_epoch","reuse_eligibility_ttl_seconds")})' "$OUT/prep-kv-status.json")"
}

CONFIG_READY=0
WD=""
server_pid=""
stop_lab_server() {
  [[ -n "$server_pid" ]] || return 0
  local t0 graceful=1
  t0=$(date +%s)
  kill -TERM "$server_pid" 2>/dev/null || true
  for _ in $(seq 1 60); do kill -0 "$server_pid" 2>/dev/null || break; sleep 1; done
  if kill -0 "$server_pid" 2>/dev/null; then graceful=0; kill -9 "$server_pid" 2>/dev/null || true; fi
  wait "$server_pid" 2>/dev/null || true
  log "lab serve stopped graceful=$graceful in $(( $(date +%s) - t0 ))s"
  server_pid=""
  (( graceful == 1 ))
}
cleanup() {
  local status=$?
  trap - EXIT INT TERM HUP
  stop_lab_server || true
  [[ -n "${WD:-}" ]] && kill -TERM "$WD" 2>/dev/null || true
  pkill -TERM -f "serve --config $CONFIG" 2>/dev/null || true
  # Leave nothing behind: purge every lab entry and forget the lab DEKs
  # (bounded; skipped only when prep never wrote the lab config).
  if [[ "$CONFIG_READY" != 1 ]]; then
    log "cleanup: lab config not written; nothing to purge"
  elif kvcache purge --all --forget > "$OUT/final-purge.json" 2>>"$OUT/final-purge.err"; then
    kvcache status > "$OUT/final-kv-status.json" 2>/dev/null || true
    log "final purge: $(cat "$OUT/final-purge.json") status_entries=$(jget entry_count < "$OUT/final-kv-status.json" 2>/dev/null || echo ?)"
  else
    log "!!! final lab purge failed or timed out; run (from the GUI session, with the binary that created namespace $LAB_PROVIDER_ID): <cli> kv-cache purge --all --forget --config $CONFIG"
    (( status == 0 )) && status=6
  fi
  if [[ "${PREP_ONLY:-0}" == "1" ]]; then exit "$status"; fi
  after="$(status_json "$LIVE_PORT" || true)"
  printf '%s' "$after" > "$OUT/live-status-after.json"
  log "live provider still paused=$(printf '%s' "$after" | jget lifecycle.operator_paused 2>/dev/null || echo unknown) (this script never resumes it)"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
watchdog
prep
if [[ "${PREP_ONLY:-0}" == "1" ]]; then
  # cleanup (EXIT trap) runs the same bounded purge a failed window would.
  log "PREP_ONLY=1: prep done, no model loaded; running the bounded cleanup purge. evidence=$OUT"; exit 0
fi

# --- Window preflight (never pauses anything) -------------------------------
live_body="$(status_json "$LIVE_PORT")" || { log "live status unreachable on $LIVE_PORT"; exit 3; }
printf '%s' "$live_body" > "$OUT/live-status-before.json"
[[ "$(printf '%s' "$live_body" | jget lifecycle.operator_paused)" == "True" ]] || {
  log "live provider on $LIVE_PORT is NOT paused; pause it, drain it and stop the buyer runner first"; exit 4; }
[[ "$(printf '%s' "$live_body" | jget requests_in_flight)" == "0" ]] || { log "live provider not drained"; exit 4; }
if pgrep -f "serve --config $CONFIG" >/dev/null; then log "a lab-2015 serve is already running"; exit 4; fi
others="$(ps -axo command= | grep '[m]acprovider-cli serve' | grep -v -- "$CONFIG" || true)"
log "other serve processes (must be idle): $(printf '%s\n' "$others" | grep -c . || true)"
printf '%s\n' "$others" | sed -E 's/(token|secret)[^ ]*/<redacted>/g' > "$OUT/other-serves.txt"


# Start from an empty lab namespace.
kvcache purge --all --forget > "$OUT/initial-purge.json" 2>>"$OUT/initial-purge.err" || { log "initial purge failed"; exit 3; }

# start_session <name> on|off
# A SecurityAgent process that appears after the serve started means a Keychain
# dialog is waiting on the Studio screen: fail at once instead of waiting.
new_keychain_prompt() {
  local p
  for p in $(pgrep -x SecurityAgent 2>/dev/null); do
    [[ " $agents_before " == *" $p "* ]] || return 0
  done
  return 1
}
alive_or_fail() {   # alive_or_fail <session> <phase>
  kill -0 "$server_pid" 2>/dev/null || { log "session=$1 FAIL: serve exited during $2"; tail -20 "$OUT/$1-serve.log" >&2; return 1; }
  if new_keychain_prompt; then log "session=$1 FAIL: Keychain access dialog (SecurityAgent) appeared during $2"; return 1; fi
}

start_session() {
  local name="$1" disk="$2" flag serve_log="$OUT/$1-serve.log" t0 body decision agents_before
  agents_before="$(pgrep -x SecurityAgent 2>/dev/null | tr '\n' ' ')"
  [[ "$disk" == on ]] && flag=--kv-disk-cache-enabled || flag=--no-kv-disk-cache-enabled
  log "session=$name disk=$disk start"
  "$CLI" serve --config "$CONFIG" --port "$LAB_PORT" --no-join --no-idle-prewarm "$flag" > "$serve_log" 2>&1 &
  server_pid=$!
  t0=$(date +%s)
  until body="$(status_json "$LAB_PORT")" && [[ "$(printf '%s' "$body" | jget model_loaded)" == "True" ]]; do
    alive_or_fail "$name" load || return 1
    (( $(date +%s) - t0 > LOAD_TIMEOUT_S )) && { log "session=$name FAIL: not loaded in ${LOAD_TIMEOUT_S}s"; return 1; }
    sleep 3
  done
  log "session=$name model loaded in $(( $(date +%s) - t0 ))s"
  # Wait for a CB decision so the self-check ladder never runs inside a
  # measurement (first session measures and stores it; later ones reuse it).
  t0=$(date +%s)
  while :; do
    decision="$(status_json "$LAB_PORT" | jget continuous_batching.self_check.decision 2>/dev/null || echo None)"
    case "$decision" in None|pending|prior_grant*|"") ;; *) break ;; esac
    [[ "$(sed -n 's/^continuous_batching:[[:space:]]*//p' "$CONFIG")" == off ]] && break
    alive_or_fail "$name" self-check || return 1
    (( $(date +%s) - t0 > SELF_CHECK_TIMEOUT_S )) && { log "session=$name FAIL: no CB decision in ${SELF_CHECK_TIMEOUT_S}s"; return 1; }
    sleep 10
  done
  log "session=$name cb_self_check=$decision"
  if [[ "$disk" == on ]]; then
    t0=$(date +%s)
    until grep -q 'event=kv_disk_cache action=activated' "$serve_log"; do
      if grep -qE 'event=kv_disk_cache action=(dormant|config_error)|kv_disk_cache config error|kv_disk_tier_unsupported_model' "$serve_log"; then
        log "session=$name FAIL: $(grep -m1 -E 'kv_disk_cache action=(dormant|config_error)|kv_disk_cache config error|kv_disk_tier_unsupported_model' "$serve_log")"; return 1
      fi
      alive_or_fail "$name" disk-tier-activation || return 1
      (( $(date +%s) - t0 > 120 )) && { log "session=$name FAIL: disk tier not activated in 120s"; return 1; }
      sleep 2
    done
    log "session=$name $(grep -m1 'event=kv_disk_cache action=enabled' "$serve_log" | sed -E 's/ directory=[^ ]*//')"
  else
    if grep -q 'event=kv_disk_cache action=activated' "$serve_log"; then log "session=$name FAIL: tier active with disk off"; return 1; fi
  fi
}

run_session() {
  local name="$1" disk="$2"
  start_session "$name" "$disk" || exit 7
  bounded "$SESSION_TIMEOUT_S" python3 -I "$DRIVER" "$name" --port "$LAB_PORT" --log "$OUT/$name-serve.log" --state "$OUT/state.json" 2>&1 \
    | tee -a "$OUT/summary.txt" >&2 || { log "session=$name driver failed or exceeded SESSION_TIMEOUT_S=$SESSION_TIMEOUT_S"; exit 7; }
  stop_lab_server || log "session=$name shutdown was not graceful"
  if [[ "$disk" == on ]]; then
    kvcache status > "$OUT/$name-kv-status.json" 2>/dev/null || true
    du -sk "$KV_DIR" | awk '{print $1*1024}' > "$OUT/$name-kv-du-bytes"
    log "session=$name kv status: $(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print({k: d.get(k) for k in ("entry_count","bytes_used","total_bytes_used","max_bytes","max_entries","tombstone_count")})' "$OUT/$name-kv-status.json" 2>/dev/null) du_bytes=$(cat "$OUT/$name-kv-du-bytes")"
  fi
}

run_session off1 off
run_session off2 off
run_session on1 on
run_session on2 on
verdict=0
bounded 120 python3 -I "$DRIVER" verdict --state "$OUT/state.json" --out "$OUT" 2>&1 | tee -a "$OUT/summary.txt" >&2 || verdict=$?
log "evidence=$OUT"
exit "$verdict"
