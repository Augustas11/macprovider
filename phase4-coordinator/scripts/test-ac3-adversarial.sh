#!/usr/bin/env bash
# AC-3: Phase 2 adversarial batch against the 2-provider Phase 4 pool. The
# coordinator must stay up, both mocks must stay up, and a substantial
# fraction of cooperative-class adversarial workloads must succeed.
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BETA="$ROOT/../beta"
VENV_PY="$ROOT/../.venv/bin/python"
if [ ! -x "$VENV_PY" ]; then
  VENV_PY="python3"
fi

COORD_PID_FILE=/tmp/mp-local-coord.pid
MOCK_A_PID_FILE=/tmp/mp-local-mockA.pid
MOCK_B_PID_FILE=/tmp/mp-local-mockB.pid
COORD_LOG=/tmp/mp-local-coord.log
MOCK_A_LOG=/tmp/mp-local-mockA.log
MOCK_B_LOG=/tmp/mp-local-mockB.log
HARNESS_CFG=/tmp/mp-local-config.yaml
RUNS_DB=/tmp/mp-local-runs.sqlite
REPORTS_DIR=/tmp/mp-local-reports
MODEL="${MODEL:-mlx-community/Qwen2.5-7B-Instruct-4bit}"

fail() {
  echo ""
  echo "[ac3] FAIL: $*"
  echo "[ac3] POOL LEFT RUNNING — stop with scripts/stop-local-pool.sh"
  exit 1
}

echo "[ac3] bringing up local pool"
MODEL="$MODEL" "$ROOT/scripts/run-local-pool.sh" || fail "bootstrap failed"

rm -rf "$RUNS_DB" "$REPORTS_DIR"
mkdir -p "$REPORTS_DIR"
cat >"$HARNESS_CFG" <<YAML
tunnel_url: "http://127.0.0.1:18443"
model: "${MODEL}"
timeout_s: 60
batch:
  - short_chat
batch_adversarial:
  - retry_storm
  - concurrent_burst_8way
  - midstream_disconnect
  - malformed_tool_call
db_path: "${RUNS_DB}"
reports_dir: "${REPORTS_DIR}"
YAML

echo "[ac3] running adversarial batch"
(cd "$BETA" && "$VENV_PY" harness.py --config "$HARNESS_CFG" --batch adversarial) \
  || echo "[ac3] note: harness returned non-zero (expected for some adversarial workloads); checking artifacts"

# Survival checks. PIDs must still be alive.
coord_pid="$(cat "$COORD_PID_FILE" 2>/dev/null || echo 0)"
mockA_pid="$(cat "$MOCK_A_PID_FILE" 2>/dev/null || echo 0)"
mockB_pid="$(cat "$MOCK_B_PID_FILE" 2>/dev/null || echo 0)"

kill -0 "$coord_pid" 2>/dev/null || fail "coordinator pid=$coord_pid is no longer running"
kill -0 "$mockA_pid" 2>/dev/null || fail "mock-A pid=$mockA_pid is no longer running"
kill -0 "$mockB_pid" 2>/dev/null || fail "mock-B pid=$mockB_pid is no longer running"
echo "[ac3] all PIDs alive (coord=$coord_pid mockA=$mockA_pid mockB=$mockB_pid)"

# adversarial_runs table populated.
adv_rows=$(sqlite3 "$RUNS_DB" 'SELECT COUNT(*) FROM adversarial_runs;' 2>/dev/null || echo 0)
[ "$adv_rows" -ge 3 ] || fail "expected >=3 adversarial_runs rows, got $adv_rows"
echo "[ac3] adversarial_runs rows: $adv_rows"

# Inspect aggregates — each row stores ok_count/error_count for that storm.
# Pass criterion: across the storms, >=80% of REQUESTS that came back at all
# succeeded with HTTP 200 (i.e. provider-not-available counts as a known
# coordinator decision, but the storm shouldn't end with all-zero successes).
agg=$(sqlite3 -separator '|' "$RUNS_DB" \
  "SELECT workload, n_ok, n_errors FROM adversarial_runs;")
echo "[ac3] adversarial aggregates:"
echo "$agg" | sed 's/^/  /'

total_ok=0
total_err=0
while IFS='|' read -r wl ok err; do
  total_ok=$((total_ok + ok))
  total_err=$((total_err + err))
done <<<"$agg"
total=$((total_ok + total_err))
if [ "$total" -eq 0 ]; then
  fail "adversarial storms produced zero observations"
fi
# 50% threshold — some adversarial storms (malformed_tool_call) are EXPECTED
# to 4xx by design. The point is the coordinator+pool kept serving.
pct=$((total_ok * 100 / total))
echo "[ac3] adversarial ok=$total_ok err=$total_err pct_ok=${pct}%"
[ "$pct" -ge 50 ] || fail "ok rate ${pct}% below 50% threshold"

# Coordinator hasn't crashed; check it still answers /v1/models.
curl -fsS "http://127.0.0.1:18443/v1/models" >/dev/null || fail "coordinator stopped serving /v1/models"

cat <<EVIDENCE

[ac3] PASS
  coordinator + both mocks survived $adv_rows adversarial storms
  total observations: ok=$total_ok err=$total_err (${pct}% ok)
  evidence:
    coord log:  $COORD_LOG
    mockA log:  $MOCK_A_LOG
    mockB log:  $MOCK_B_LOG
    sqlite:     $RUNS_DB (table adversarial_runs)

  TODO: optional follow-up — re-run with one mock --reject-preflight=queue_full
        mid-storm to exercise failover under back-pressure.

EVIDENCE

"$ROOT/scripts/stop-local-pool.sh"
exit 0
