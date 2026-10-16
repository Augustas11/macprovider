#!/usr/bin/env bash
# #1971 / PR #1980 lab validation: run the FR-CB10 self-check of a locally
# built PR head on an isolated loopback port, on the live model, and compare
# its grant with the live provider's current grant. Lab only; never shipped.
#
# Run it ON the Mac under test, inside an announced pause window. Pausing is
# strictly opt-in (PAUSE_PROVIDER=1). The resume handler is installed before
# the pause is sent, retries, and verifies the live provider reports unpaused;
# a failed resume is loud and exits non-zero. The lab server never binds the
# live port, uses its own config directory (so its own self-check store), and
# runs as an isolated no-join lab serve: --no-join with a protected_file
# credential store, which gives it its own control socket, lifecycle and lease
# root and no canonical-install re-exec.
#
# Do NOT add --autotune-candidate: an autotune child skips the served-slots
# plan, so the FR-CB10 self-check driver never starts (the first Studio window
# waited 34 minutes on that).
#
# A buyer-traffic generator that would queue work on the paused provider is
# stopped before the pause and restarted in the same exit trap that resumes
# the live provider (BUYER_RUNNER_STOP_CMD / BUYER_RUNNER_START_CMD, operator
# supplied; "none" when there is no runner).
#
# Every stage is bounded and fails fast (non-zero exit, live resumed):
#   LAUNCH_TIMEOUT_S (90)    serve must log its served-slots plan with a
#                            self-checked reason (printed before model load).
#   LOAD_TIMEOUT_S (900)     the lab server must answer /v1/status with the
#                            model loaded.
#   START_TIMEOUT_S (120)    the self-check must log its first ladder step
#                            (event=cb_self_check action=step).
#   STEP_TIMEOUT_S (300)     no more than this between ladder progress events.
#   DECISION_TIMEOUT_S       overall cap after the first step, sized from the
#                            ladder: 120 + 60 * (QUEUE_LIMIT - 1).
#
# Legs:
#   bounded   (always) PR head as it ships, device decode row bound in force.
#             PASS when lab served_slots >= live served_slots and lab
#             verified_k >= live served_slots, every measured width
#             conformant up to verified_k.
#   unbounded (UNBOUNDED_CLI set) the lab-harness build (PR body) with
#             MACPROVIDER_LAB_DECODE_ROW_BOUND above the device limit. PASS
#             when the probe refuses some width above the device's vector
#             limit (decision row_divergence_at_<k>, k > DEVICE_ROW_BOUND).
#
# Usage:
#   CLI=/path/to/.build-lab/release/macprovider-cli  # mlx.metallib beside it
#   LAB_CONFIG_TEMPLATE=/path/to/lab/config.yaml     # live model, accepted tuples
#   LAB_DIR=/path/to/lab-1980                        # results + per-leg configs
#   LIVE_INSTALL_DIR=/path/to/live/install           # read only: its signed
#                                                    # compatibility-set.json
# Build the binaries with build-lab-binaries.sh: serve refuses to start when
# the installed compatibility set's provider_cli version differs from the
# binary's, so a lab build of a staged version must be pinned to the live
# version. The preflight checks that for every binary before anything pauses.
#   PAUSE_PROVIDER=1 PAUSE_PROVIDER_SOCKET=/path/to/ctl.sock \
#   BUYER_RUNNER_STOP_CMD='...' BUYER_RUNNER_START_CMD='...' \
#   bash studio-selfcheck-validation.sh
# Optional: LIVE_PORT (8080) LAB_PORT (18095) MAX_CONCURRENCY (live value)
#   QUEUE_LIMIT (template value) DEVICE_ROW_BOUND (11) UNBOUNDED_CLI
#   UNBOUNDED_ROW_BOUND (16) DRAIN_TIMEOUT_S (600) and the stage timeouts above.
set -euo pipefail
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin

: "${CLI:?}" "${LAB_CONFIG_TEMPLATE:?}" "${LAB_DIR:?}" "${LIVE_INSTALL_DIR:?}"
LIVE_PORT="${LIVE_PORT:-8080}"
LAB_PORT="${LAB_PORT:-18095}"
DRAIN_TIMEOUT_S="${DRAIN_TIMEOUT_S:-600}"
LAUNCH_TIMEOUT_S="${LAUNCH_TIMEOUT_S:-90}"
LOAD_TIMEOUT_S="${LOAD_TIMEOUT_S:-900}"
START_TIMEOUT_S="${START_TIMEOUT_S:-120}"
STEP_TIMEOUT_S="${STEP_TIMEOUT_S:-300}"
DEVICE_ROW_BOUND="${DEVICE_ROW_BOUND:-11}"
UNBOUNDED_ROW_BOUND="${UNBOUNDED_ROW_BOUND:-16}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$LAB_DIR/run-$STAMP"
mkdir -p "$OUT"
log() { echo "1971-validation: $*" | tee -a "$OUT/summary.txt" >&2; }

[[ "$LAB_PORT" != "$LIVE_PORT" ]] || { log "LAB_PORT must differ from LIVE_PORT"; exit 2; }

status_json() { curl -fsS --max-time 5 "http://127.0.0.1:$1/v1/status" 2>/dev/null; }

# Prints "decision verified_k served_slots runtime_build" from a status body.
grant_of() {
  python3 -c 'import json,sys
d = json.load(sys.stdin)
s = ((d.get("continuous_batching") or {}).get("self_check") or {})
print(s.get("decision"), s.get("verified_k"), s.get("served_slots"), s.get("runtime_build"))'
}

provider_control() {
  python3 - "$PAUSE_PROVIDER_SOCKET" "$1" <<'PY'
import json, socket, sys
path, frame = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(300)
s.connect(path)
s.sendall((json.dumps({"type": frame}) + "\n").encode())
buf = b""
while b"\n" not in buf:
    chunk = s.recv(4096)
    if not chunk:
        break
    buf += chunk
ack = json.loads(buf.split(b"\n", 1)[0] or b"{}")
print(json.dumps(ack))
sys.exit(0 if ack.get("accepted") is True else 1)
PY
}

pause_state() {
  local body
  body=$(status_json "$LIVE_PORT") || { echo unknown; return 0; }
  printf '%s' "$body" | python3 -c 'import json,sys
try:
    l = json.load(sys.stdin).get("lifecycle") or {}
except Exception:
    print("unknown")
else:
    print("paused" if l.get("operator_paused") is True else "running")' 2>/dev/null || echo unknown
}

pause_sent=0
runner_stopped=0
server_pid=""

stop_lab_server() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    for _ in $(seq 1 30); do kill -0 "$server_pid" 2>/dev/null || break; sleep 1; done
    kill -9 "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=""
  fi
}

resume_provider() {
  local attempt
  for attempt in $(seq 1 "${RESUME_ATTEMPTS:-10}"); do
    provider_control resume_request >&2 || true
    if [[ "$(pause_state)" == "running" ]]; then
      log "live provider resumed $(date -u +%T)"
      return 0
    fi
    sleep "${RESUME_RETRY_SECONDS:-5}"
  done
  return 1
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM HUP
  stop_lab_server
  if (( pause_sent == 1 )); then
    if ! resume_provider; then
      log "!!! RESUME FAILED: the live provider on port $LIVE_PORT may still be PAUSED; send resume_request on $PAUSE_PROVIDER_SOCKET now"
      (( status == 0 )) && status=6
    fi
  fi
  if (( runner_stopped == 1 )) && [[ "$BUYER_RUNNER_START_CMD" != none ]]; then
    if bash -c "$BUYER_RUNNER_START_CMD" >&2; then
      log "buyer runner restarted $(date -u +%T)"
    else
      log "!!! BUYER RUNNER RESTART FAILED: run it by hand now"
      (( status == 0 )) && status=6
    fi
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# --- Preflight (nothing paused yet) ---------------------------------------
for bin in "$CLI" ${UNBOUNDED_CLI:-}; do
  [[ -x "$bin" ]] || { log "missing binary $bin"; exit 2; }
  [[ -f "$(dirname "$bin")/mlx.metallib" ]] || { log "no mlx.metallib beside $bin"; exit 2; }
  metallib_sha="$(shasum -a 256 "$(dirname "$bin")/mlx.metallib" | cut -d' ' -f1)"
  grep -q "metallib_sha256: $metallib_sha" "$LAB_CONFIG_TEMPLATE" || {
    log "accepted tuples in $LAB_CONFIG_TEMPLATE do not name metallib $metallib_sha of $bin"; exit 2; }
  log "binary $bin sha256=$(shasum -a 256 "$bin" | cut -d' ' -f1) metallib=$metallib_sha"
  # Mirror serve's compatibility-set load: the installed set first, then one
  # beside the binary; the first whose provider_cli version equals the
  # binary's wins, and a present but mismatched set is fatal at load.
  bin_version="$("$bin" --version 2>/dev/null || true)"
  compat_verdict="$(python3 - "$bin_version" "$LIVE_INSTALL_DIR/compatibility-set.json" "$(dirname "$bin")/compatibility-set.json" <<'PY'
import json, os, sys
version, *paths = sys.argv[1:]
found = []
for path in paths:
    if os.path.isfile(path):
        try:
            found.append(json.load(open(path))["signed"]["components"]["provider_cli"]["version"])
        except Exception:
            found.append("unreadable")
if not found or version in found:
    print("ok " + (",".join(found) or "no-set"))
else:
    print("mismatch " + ",".join(found))
PY
)"
  [[ "$compat_verdict" == ok* ]] || {
    log "binary $bin version=$bin_version cannot load the compatibility set (${compat_verdict#mismatch }); build it with build-lab-binaries.sh. Nothing paused."
    exit 2; }
  log "binary $bin version=$bin_version compatibility-set ${compat_verdict#ok }"
done

live_body="$(status_json "$LIVE_PORT")" || { log "live status unreachable on $LIVE_PORT"; exit 3; }
printf '%s' "$live_body" > "$OUT/live-status-before.json"
read -r live_decision live_verified live_served live_build < <(printf '%s' "$live_body" | grant_of)
live_model="$(printf '%s' "$live_body" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("model"))')"
live_concurrency="$(printf '%s' "$live_body" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("capacity") or {}).get("max_concurrency"))')"
log "live grant: decision=$live_decision verified_k=$live_verified served_slots=$live_served model=$live_model build=$live_build"
[[ "$live_served" =~ ^[0-9]+$ ]] || { log "live grant unreadable"; exit 3; }
MAX_CONCURRENCY="${MAX_CONCURRENCY:-$live_concurrency}"
QUEUE_LIMIT="${QUEUE_LIMIT:-$(sed -n 's/^continuous_batch_queue_limit:[[:space:]]*//p' "$LAB_CONFIG_TEMPLATE" | head -1)}"
grep -q "^model: $live_model\$" "$LAB_CONFIG_TEMPLATE" || { log "template model differs from live $live_model"; exit 2; }
# protected_file keeps the no-join serve isolated (own control socket, lease
# and lifecycle root; no canonical re-exec into the installed binary).
grep -q "^credential_store: protected_file\$" "$LAB_CONFIG_TEMPLATE" || {
  log "template must set credential_store: protected_file (isolated no-join lab serve)"; exit 2; }
grep -qE "^draft_model:[[:space:]]*[^[:space:]]" "$LAB_CONFIG_TEMPLATE" && {
  log "template sets draft_model; the self-check never runs beside a draft model"; exit 2; }
[[ "$QUEUE_LIMIT" =~ ^[0-9]+$ ]] || { log "QUEUE_LIMIT unreadable"; exit 2; }
DECISION_TIMEOUT_S="${DECISION_TIMEOUT_S:-$((120 + 60 * (QUEUE_LIMIT - 1)))}"
log "stage bounds: launch=${LAUNCH_TIMEOUT_S}s load=${LOAD_TIMEOUT_S}s start=${START_TIMEOUT_S}s step=${STEP_TIMEOUT_S}s decision=${DECISION_TIMEOUT_S}s"

# One fresh config directory per leg: its own self-check store, no stored grant.
make_config() {
  local dir="$OUT/$1"
  mkdir -p "$dir"
  chmod 700 "$dir"
  python3 - "$LAB_CONFIG_TEMPLATE" "$dir/config.yaml" "$LAB_PORT" "$MAX_CONCURRENCY" "$QUEUE_LIMIT" <<'PY'
import sys
src, dst, port, conc, queue = sys.argv[1:]
want = {"port": port, "max_concurrency_override": conc, "continuous_batch_queue_limit": queue,
        "continuous_batching": "canary"}
seen, out = set(), []
for line in open(src).read().splitlines():
    key = line.split(":", 1)[0]
    if line and not line[0].isspace() and ":" in line and key in want:
        out.append(f"{key}: {want[key]}"); seen.add(key)
    else:
        out.append(line)
out += [f"{k}: {v}" for k, v in want.items() if k not in seen]
open(dst, "w").write("\n".join(out) + "\n")
PY
  chmod 600 "$dir/config.yaml"
  echo "$dir/config.yaml"
}

# Serves one leg and waits for its self-check decision under the v2 probe;
# writes "decision verified_k served_slots runtime_build" to $OUT/<leg>.grant.
# Called directly (not in a subshell) so the EXIT trap can stop the server.
# Returns non-zero, with the reason logged, as soon as any stage overruns.
run_leg() {
  local leg="$1" bin="$2" config="$3"; shift 3
  local serve_log="$OUT/$leg-serve.log" t0 now body grant="none none none none" stage plan
  local progress_count=0 last_count=0 last_progress
  log "leg=$leg start $(date -u +%T) port=$LAB_PORT queue_limit=$QUEUE_LIMIT"
  env "$@" "$bin" serve --config "$config" --port "$LAB_PORT" --no-join --no-idle-prewarm \
    > "$serve_log" 2>&1 &
  server_pid=$!
  t0=$(date +%s)
  stage=launch
  printf '%s\n' "$grant" > "$OUT/$leg.grant"
  while :; do
    sleep 5
    now=$(date +%s)
    if ! kill -0 "$server_pid" 2>/dev/null; then
      log "leg=$leg FAIL: lab server exited during stage=$stage"; break
    fi
    case "$stage" in
      launch)
        plan="$(grep -m1 'event=served_slots action=planned' "$serve_log" || true)"
        if [[ -n "$plan" ]]; then
          log "leg=$leg $plan"
          case "$plan" in
            *reason=draft_model*|*reason=emergency_off*)
              log "leg=$leg FAIL: plan is not self-checked"; break ;;
          esac
          stage=load; t0=$now
        elif (( now - t0 > LAUNCH_TIMEOUT_S )); then
          log "leg=$leg FAIL: no served-slots plan within ${LAUNCH_TIMEOUT_S}s (self-check driver cannot start)"; break
        fi ;;
      load)
        if body="$(status_json "$LAB_PORT")" \
          && printf '%s' "$body" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("model_loaded") else 1)' 2>/dev/null; then
          log "leg=$leg model loaded $(date -u +%T)"
          stage=start; t0=$now
        elif (( now - t0 > LOAD_TIMEOUT_S )); then
          log "leg=$leg FAIL: model not loaded within ${LOAD_TIMEOUT_S}s"; break
        fi ;;
      start)
        if grep -q 'event=cb_self_check action=step' "$serve_log"; then
          log "leg=$leg self-check started $(date -u +%T)"
          stage=ladder; t0=$now; last_progress=$now
        elif (( now - t0 > START_TIMEOUT_S )); then
          log "leg=$leg FAIL: no self-check step within ${START_TIMEOUT_S}s of model load"
          grep -E 'event=(continuous_batching_policy|batching_unsupported|continuous_batch_decode_row_bound)' "$serve_log" | tail -5 >&2 || true
          break
        fi ;;
      ladder)
        progress_count=$(grep -cE 'event=cb_self_check action=(step|measured|probe_shape_unmet|ladder_paused|ladder_ended)' "$serve_log" || true)
        if (( progress_count != last_count )); then last_count=$progress_count; last_progress=$now; fi
        if body="$(status_json "$LAB_PORT")"; then
          grant="$(printf '%s' "$body" | grant_of)"
          case "$grant" in
            # "pending" (and a carried prior grant) is not a decision yet.
            None*|pending*|prior_grant*|"") grant="none none none none" ;;
            *cb-probe-v2*) printf '%s' "$body" > "$OUT/$leg-status.json"; break ;;
          esac
        fi
        if (( now - last_progress > STEP_TIMEOUT_S )); then
          log "leg=$leg FAIL: ladder made no progress for ${STEP_TIMEOUT_S}s"; break
        fi
        if (( now - t0 > DECISION_TIMEOUT_S )); then
          log "leg=$leg FAIL: no decision within ${DECISION_TIMEOUT_S}s of the first step"; break
        fi ;;
    esac
  done
  grep -E 'event=(served_slots|cb_self_check|continuous_batching_policy|batching_unsupported|continuous_batch_decode_row_bound)' \
    "$serve_log" > "$OUT/$leg-selfcheck-events.log" || true
  stop_lab_server
  printf '%s\n' "$grant" > "$OUT/$leg.grant"
  [[ "$grant" == *cb-probe-v2* ]]
}

# --- Pause window ----------------------------------------------------------
if [[ "${PAUSE_PROVIDER:-0}" == "1" ]]; then
  : "${PAUSE_PROVIDER_SOCKET:?PAUSE_PROVIDER_SOCKET is required with PAUSE_PROVIDER=1}"
  : "${BUYER_RUNNER_STOP_CMD:?BUYER_RUNNER_STOP_CMD is required with PAUSE_PROVIDER=1 (none if there is no runner)}"
  : "${BUYER_RUNNER_START_CMD:?BUYER_RUNNER_START_CMD is required with PAUSE_PROVIDER=1 (none if there is no runner)}"
  if [[ "$BUYER_RUNNER_STOP_CMD" != none ]]; then
    # Set before the stop is sent, so every exit path after this restarts it.
    runner_stopped=1
    bash -c "$BUYER_RUNNER_STOP_CMD" >&2 || { log "buyer runner stop failed; not pausing"; exit 4; }
    log "buyer runner stopped $(date -u +%T)"
  fi
  log "!!! PAUSING the live provider on port $LIVE_PORT; it is resumed on exit"
  for attempt in $(seq 1 "${PAUSE_ATTEMPTS:-10}"); do
    pause_sent=1
    provider_control pause_request >&2 && break
    (( attempt == ${PAUSE_ATTEMPTS:-10} )) && { log "pause refused $attempt times"; exit 4; }
    sleep 10
  done
  log "live paused $(date -u +%T); waiting for in-flight=0"
  waited=0
  while :; do
    n="$(status_json "$LIVE_PORT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("requests_in_flight", -1))' 2>/dev/null || echo -1)"
    [[ "$n" == "0" ]] && { log "live drained $(date -u +%T)"; break; }
    (( waited >= DRAIN_TIMEOUT_S )) && { log "live not drained in_flight=$n"; exit 5; }
    sleep 10; waited=$((waited + 10))
  done
else
  log "PAUSE_PROVIDER!=1: refusing to measure beside a serving live provider"
  exit 2
fi
others="$(ps -axo pid=,command= | grep '[m]acprovider-cli serve' | grep -v -- "--port $LAB_PORT" | wc -l | tr -d ' ')"
log "other macprovider serve processes on this Mac: $others (live paused; any other engine must be idle)"

bounded_config="$(make_config bounded)"
run_leg bounded "$CLI" "$bounded_config" || { log "RESULT=FAIL (bounded leg did not decide) evidence=$OUT"; exit 7; }
read -r b_decision b_verified b_served b_build < "$OUT/bounded.grant" || true
log "bounded: decision=$b_decision verified_k=$b_verified served_slots=$b_served build=$b_build"

result=PASS
if ! [[ "$b_served" =~ ^[0-9]+$ && "$b_verified" =~ ^[0-9]+$ ]] \
  || (( b_served < live_served || b_verified < live_served )); then
  result=FAIL
  log "bounded FAIL: lab grant below the live grant (live served_slots=$live_served)"
fi

if [[ -n "${UNBOUNDED_CLI:-}" ]]; then
  unbounded_config="$(make_config unbounded)"
  run_leg unbounded "$UNBOUNDED_CLI" "$unbounded_config" MACPROVIDER_LAB_DECODE_ROW_BOUND="$UNBOUNDED_ROW_BOUND" \
    || log "unbounded leg did not decide"
  read -r u_decision u_verified u_served _ < "$OUT/unbounded.grant" || true
  log "unbounded: decision=$u_decision verified_k=$u_verified served_slots=$u_served"
  k="${u_decision#row_divergence_at_}"
  if [[ "$u_decision" != row_divergence_at_* ]] || ! [[ "$k" =~ ^[0-9]+$ ]] || (( k <= DEVICE_ROW_BOUND )); then
    result=FAIL
    log "unbounded FAIL: expected row_divergence_at_<k> with k > $DEVICE_ROW_BOUND"
  fi
fi

log "RESULT=$result evidence=$OUT"
[[ "$result" == PASS ]]
