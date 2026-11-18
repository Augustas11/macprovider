#!/usr/bin/env bash
# Start-up timing for issue 2431 (hash model weights once per provider start). Run ON THE STUDIO inside
# a window whose owner already paused the live provider and the runner's Studio target; it never pauses
# or restores either, and ssh is the caller's business.
#
# For two built provider binaries (the main build and this branch's build, each directory holding
# macprovider-cli and mlx.metallib) and one model snapshot it starts, in this order,
#   main, branch, main, branch        (--runs N: N of each, alternating, a control on both sides)
# `macprovider-cli serve --no-join` on a loopback port with the lab config pattern of
# scripts/lab/parity-grid/run-grid.sh (model id, model_artifact_path, model_artifact_sha256, protected
# file credentials, no --autotune-candidate, continuous batching auto), polls /v1/status until
# model_loaded is true, records the wall seconds from process start to that moment and every
# `event=startup_phase phase=<name> ms=<n>` line of serve.err (the main build prints none: its phase
# cells are "-"), then stops that serve (SIGTERM, SIGKILL after 30 s) and waits for its port to free.
# A table of every run and per-build means is printed and written to OUT/table.md.
#
# Refuses to start when anything listens on :8080 or on --port, a macprovider-cli serve runs, or
# ~/lab-heavy.lock.d exists. It takes that lock itself (owner startup-timing-2431) and releases it at
# exit, only if it took it. There is no wall-clock deadline: a run ends when the serve is ready or
# exits (exit 5, the others are skipped); a stuck serve is the owner's to kill (the pid is printed).
#
# Page-cache note: the hash time depends on whether the weights are in the file cache. Alternating
# the builds keeps that equal on both sides, but run 1 (the main build's) is the coldest: read it as
# the cold outlier and compare the means of the later runs, or use --runs 3.
#
# usage: measure.sh --main-bin DIR --branch-bin DIR --model-path DIR --model-id ID --model-sha256 SHA
#                   [--port 18350] [--runs 2] [--out DIR] [--settle-s 3]
# Exit: 0 all runs ready; 5 a serve exited before ready; 3 refused (busy host); 64 bad arguments.
set -euo pipefail

MAIN_BIN="" BRANCH_BIN="" MODEL_PATH="" MODEL_ID="" MODEL_SHA="" OUT=""
PORT=18350 RUNS=2 SETTLE_S=3
while [ $# -gt 0 ]; do
  case "$1" in
    --main-bin) MAIN_BIN="$2"; shift 2 ;;
    --branch-bin) BRANCH_BIN="$2"; shift 2 ;;
    --model-path) MODEL_PATH="$2"; shift 2 ;;
    --model-id) MODEL_ID="$2"; shift 2 ;;
    --model-sha256) MODEL_SHA="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --runs) RUNS="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --settle-s) SETTLE_S="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done
for v in MAIN_BIN BRANCH_BIN MODEL_PATH MODEL_ID MODEL_SHA; do
  [ -n "${!v}" ] || { echo "missing --$(echo "$v" | tr 'A-Z_' 'a-z-')" >&2; exit 64; }
done
case "$RUNS" in ""|*[!0-9]*|0) echo "--runs must be a positive number" >&2; exit 64 ;; esac
case "$PORT" in ""|*[!0-9]*) echo "--port must be a number" >&2; exit 64 ;; esac
case "$SETTLE_S" in ""|*[!0-9]*) echo "--settle-s must be a number" >&2; exit 64 ;; esac
echo "$MODEL_SHA" | grep -Eq '^[0-9a-f]{64}$' || { echo "--model-sha256 must be 64 lowercase hex characters" >&2; exit 64; }
[ -f "$MODEL_PATH/config.json" ] || { echo "no model snapshot at $MODEL_PATH" >&2; exit 64; }
for b in "$MAIN_BIN" "$BRANCH_BIN"; do
  [ -x "$b/macprovider-cli" ] || { echo "no macprovider-cli in $b" >&2; exit 64; }
  [ -f "$b/mlx.metallib" ] || { echo "no mlx.metallib beside $b/macprovider-cli" >&2; exit 64; }
done
OUT=${OUT:-$HOME/lab-startup-timing/$(date -u +%Y%m%dT%H%M%SZ)}

LOCK=$HOME/lab-heavy.lock.d
listening() { [ -n "$(lsof -nP -t -iTCP:"$1" -sTCP:LISTEN 2>/dev/null || true)" ]; }
if listening 8080; then echo "a server listens on :8080; refusing" >&2; exit 3; fi
if listening "$PORT"; then echo "port $PORT is busy; refusing" >&2; exit 3; fi
if pgrep -f "[m]acprovider-cli serve" >/dev/null 2>&1; then echo "a macprovider-cli serve process runs; refusing" >&2; exit 3; fi
if [ -e "$LOCK" ]; then echo "$LOCK exists (owner: $(cat "$LOCK/owner" 2>/dev/null || echo unknown)); refusing" >&2; exit 3; fi
mkdir "$LOCK" 2>/dev/null || { echo "could not take $LOCK; refusing" >&2; exit 3; }
echo startup-timing-2431 > "$LOCK/owner"; date +%s > "$LOCK/since"

SP=""
stop_serve() {
  if [ -n "$SP" ] && kill -0 "$SP" 2>/dev/null; then
    kill -TERM "$SP" 2>/dev/null || true
    for _ in $(seq 1 60); do kill -0 "$SP" 2>/dev/null || break; sleep 0.5; done
    kill -0 "$SP" 2>/dev/null && kill -KILL "$SP" 2>/dev/null || true
  fi
  [ -z "$SP" ] || wait "$SP" 2>/dev/null || true
  SP=""
}
cleanup() { stop_serve; rm -f "$LOCK/owner" "$LOCK/since"; rmdir "$LOCK" 2>/dev/null || true; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

mkdir -p "$OUT"
printf 'run\tbuild\tbin\tcli_sha256\twall_s\trc\n' > "$OUT/runs.tsv"
echo "STARTUP_TIMING_START out=$OUT model=$MODEL_ID sha256=$MODEL_SHA runs_per_build=$RUNS port=$PORT"

# One serve: run_one IDX LABEL BIN. Appends to runs.tsv; returns 5 when the serve exits before ready.
run_one() {
  local idx=$1 label=$2 bin=$3 d wall rc=0
  d=$OUT/run-$idx-$label
  mkdir -p "$d"
  cat > "$d/config.yaml" <<EOF
model: "$MODEL_ID"
model_artifact_path: "$MODEL_PATH"
model_artifact_sha256: $MODEL_SHA
port: $PORT
ctl_socket_path: "$d/ctl.sock"
credential_store: protected_file
EOF
  shasum -a 256 "$bin/macprovider-cli" > "$d/identity.sha256"
  local t0
  t0=$(/usr/bin/python3 -I -c 'import time; print(f"{time.time():.3f}")')
  (cd "$bin" && exec "$bin/macprovider-cli" serve --config "$d/config.yaml" --no-join \
    > "$d/serve.out" 2> "$d/serve.err" < /dev/null) &
  SP=$!
  echo "RUN_START $idx $label pid=$SP"
  wall=$(/usr/bin/python3 -I - "$PORT" "$SP" "$t0" <<'PY'
import http.client, json, os, sys, time
port, pid, t0 = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3])
last = time.time()
while True:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        sys.exit(5)
    try:
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
        c.request("GET", "/v1/status")
        r = c.getresponse()
        body = r.read()
        c.close()
        if r.status == 200 and json.loads(body).get("model_loaded") is True:
            print(f"{time.time() - t0:.3f}")
            sys.exit(0)
    except (OSError, ValueError, http.client.HTTPException):
        pass
    if time.time() - last >= 60:
        print(f"waiting {time.time() - t0:.0f}s", file=sys.stderr, flush=True)
        last = time.time()
    time.sleep(0.25)
PY
  ) || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "RUN_FAIL $idx $label serve exited before ready; serve.err tail:" >&2
    tail -n 20 "$d/serve.err" >&2 || true
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$idx" "$label" "$bin" "$(cut -c1-16 "$d/identity.sha256")" "" "$rc" >> "$OUT/runs.tsv"
    SP=""
    return 5
  fi
  sleep "$SETTLE_S"  # phases that log just after ready reach serve.err
  curl -s --max-time 5 "http://127.0.0.1:$PORT/v1/status" > "$d/status.json" || true
  grep -h 'event=startup_phase' "$d/serve.err" > "$d/startup_phase.txt" || true
  stop_serve
  for _ in $(seq 1 40); do listening "$PORT" || break; sleep 0.5; done
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$idx" "$label" "$bin" "$(cut -c1-16 "$d/identity.sha256")" "$wall" 0 >> "$OUT/runs.tsv"
  echo "RUN_DONE $idx $label wall_s=$wall phases=$(wc -l < "$d/startup_phase.txt" | tr -d ' ')"
}

idx=0 status=0
for _ in $(seq 1 "$RUNS"); do
  for label in main branch; do
    idx=$((idx + 1))
    bin=$MAIN_BIN; [ "$label" = branch ] && bin=$BRANCH_BIN
    run_one "$idx" "$label" "$bin" || { status=$?; break 2; }
  done
done

/usr/bin/python3 -I - "$OUT" <<'PY' | tee "$OUT/table.md"
import collections, csv, re, statistics, sys
out = sys.argv[1]
runs = list(csv.DictReader(open(f"{out}/runs.tsv"), delimiter="\t"))
phases, per_run = [], {}
for r in runs:
    got = {}
    try:
        text = open(f"{out}/run-{r['run']}-{r['build']}/serve.err", errors="replace").read()
    except OSError:
        text = ""
    for m in re.finditer(r"event=startup_phase phase=(\S+) ms=(\d+)([^\n]*)", text):
        name = m.group(1) + (" " + m.group(3).strip() if m.group(3).strip() else "")
        got[name] = got.get(name, 0) + int(m.group(2))
        if name not in phases:
            phases.append(name)
    per_run[r["run"]] = got
head = ["run", "build", "wall s"] + [p + " ms" for p in phases]
print("| " + " | ".join(head) + " |")
print("|" + "|".join(["---", "---", "---:"] + ["---:"] * len(phases)) + "|")
for r in runs:
    cells = [r["run"], r["build"], r["wall_s"] or "FAILED"] + [str(per_run[r["run"]].get(p, "-")) for p in phases]
    print("| " + " | ".join(cells) + " |")
print()
by = collections.defaultdict(list)
for r in runs:
    if r["wall_s"]:
        by[r["build"]].append(float(r["wall_s"]))
for build in ("main", "branch"):
    w = by.get(build, [])
    if w:
        print(f"{build}: runs={len(w)} wall_s mean={statistics.mean(w):.3f} min={min(w):.3f} max={max(w):.3f}")
if by.get("main") and by.get("branch"):
    print(f"branch - main mean wall: {statistics.mean(by['branch']) - statistics.mean(by['main']):+.3f} s")
PY
echo "STARTUP_TIMING_END status=$status out=$OUT"
exit "$status"
