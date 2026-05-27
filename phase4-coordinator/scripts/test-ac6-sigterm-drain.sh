#!/usr/bin/env bash
# AC-6: SIGTERM during in-flight SSE streams. In-flight streams must complete
# cleanly (final [DONE] line); new requests after SIGTERM must fail; both
# mocks must observe a drain frame and emit drain_status complete.
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

COORD_PID_FILE=/tmp/mp-local-coord.pid
MOCK_A_LOG=/tmp/mp-local-mockA.log
MOCK_B_LOG=/tmp/mp-local-mockB.log
COORD_LOG=/tmp/mp-local-coord.log
MODEL="${MODEL:-mlx-community/Qwen2.5-7B-Instruct-4bit}"

# Bring up a pool with slow streaming so we have time to fire SIGTERM mid-stream.
# The mock emits ~10 chunks; at 500ms delay each, total stream time ~5s.
# Override the bootstrap script's defaults by rewriting mockprovider flags
# is overkill — instead, kill the just-bootstrapped mocks and respawn with
# --stream-delay-ms=500.

fail() {
  echo ""
  echo "[ac6] FAIL: $*"
  echo "[ac6] POOL LEFT RUNNING — stop with scripts/stop-local-pool.sh"
  exit 1
}

echo "[ac6] bringing up local pool"
MODEL="$MODEL" "$ROOT/scripts/run-local-pool.sh" || fail "bootstrap failed"

# Replace mocks with slow-stream variants (preserve coordinator).
echo "[ac6] restarting mocks with --stream-delay-ms=500 --drain-delay-s=5"
for pidf in /tmp/mp-local-mockA.pid /tmp/mp-local-mockB.pid; do
  pid="$(cat "$pidf" 2>/dev/null || true)"
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
done
sleep 1

./mockprovider \
  --coord-url "ws://127.0.0.1:18444/ws/provider" \
  --provider-id mock-A \
  --model "$MODEL" \
  --http-port 9001 \
  --slots 4 \
  --max-concurrency 4 \
  --stream-delay-ms 500 \
  --drain-delay-s 5 \
  >"$MOCK_A_LOG" 2>&1 &
echo $! >/tmp/mp-local-mockA.pid

./mockprovider \
  --coord-url "ws://127.0.0.1:18444/ws/provider" \
  --provider-id mock-B \
  --model "$MODEL" \
  --http-port 9002 \
  --slots 4 \
  --max-concurrency 4 \
  --stream-delay-ms 500 \
  --drain-delay-s 5 \
  >"$MOCK_B_LOG" 2>&1 &
echo $! >/tmp/mp-local-mockB.pid

# Wait for both mocks to re-register.
ready=0
for _ in $(seq 1 60); do
  body="$(curl -fsS http://127.0.0.1:18443/v1/models 2>/dev/null || true)"
  count="$(echo "$body" | "$ROOT/../.venv/bin/python" -c "
import json,sys
try:
  data=json.load(sys.stdin)
  for m in data.get('data', []):
    if m['id'] == '$MODEL':
      print(m.get('provider_count', 0)); sys.exit()
  print(0)
except Exception:
  print(0)
" 2>/dev/null || echo 0)"
  if [ "$count" = "2" ]; then
    ready=1
    break
  fi
  sleep 0.5
done
[ "$ready" -eq 1 ] || fail "slow-stream mocks failed to re-register"

# Launch 3 background SSE streams. Save full output for [DONE] check.
echo "[ac6] launching 3 background SSE streams"
rm -f /tmp/mp-ac6-stream-*.out /tmp/mp-ac6-stream-*.exit
for i in 1 2 3; do
  (
    curl -sN -X POST http://127.0.0.1:18443/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d '{"model":"'"$MODEL"'","messages":[{"role":"user","content":"stream test '"$i"'"}],"stream":true}' \
      >"/tmp/mp-ac6-stream-$i.out" 2>&1
    echo $? >"/tmp/mp-ac6-stream-$i.exit"
  ) &
done

# Give streams a beat to start emitting.
sleep 1

coord_pid="$(cat "$COORD_PID_FILE")"
echo "[ac6] sending SIGTERM to coordinator pid=$coord_pid"
kill -TERM "$coord_pid"
sigterm_at=$(date +%s)

# Issue a NEW request shortly after SIGTERM; expect it to fail.
sleep 0.5
new_req_status=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 5 \
  -X POST http://127.0.0.1:18443/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"'"$MODEL"'","messages":[{"role":"user","content":"post-sigterm"}]}' || echo "000")
echo "[ac6] post-SIGTERM new request HTTP status: $new_req_status"

# Wait for streams to finish (curl returns when [DONE] arrives or server closes).
wait
echo "[ac6] all background streams returned"

# Wait for coordinator to exit (up to 35s — request_timeout=30 + grace).
for _ in $(seq 1 40); do
  if ! kill -0 "$coord_pid" 2>/dev/null; then
    break
  fi
  sleep 1
done
if kill -0 "$coord_pid" 2>/dev/null; then
  fail "coordinator did not exit within 40s of SIGTERM"
fi
shutdown_at=$(date +%s)
echo "[ac6] coordinator exited in $((shutdown_at - sigterm_at))s"

# --- Validation ---

# 1. All 3 streams completed with [DONE].
done_count=0
for i in 1 2 3; do
  if grep -q 'data: \[DONE\]' "/tmp/mp-ac6-stream-$i.out"; then
    done_count=$((done_count + 1))
  fi
done
echo "[ac6] streams that received [DONE]: $done_count/3"
[ "$done_count" -eq 3 ] || fail "expected all 3 streams to complete with [DONE], got $done_count"

# 2. Post-SIGTERM request failed (anything except 200, or curl error).
case "$new_req_status" in
  200)
    fail "post-SIGTERM request unexpectedly returned 200"
    ;;
  *)
    echo "[ac6] post-SIGTERM request correctly failed (status=$new_req_status)"
    ;;
esac

# 3. Coordinator log shows "provider drain sent" for both mocks.
drain_sent_count=$(grep -c '"provider drain sent"' "$COORD_LOG" 2>/dev/null || echo 0)
[ "$drain_sent_count" -ge 2 ] || fail "expected >=2 'provider drain sent' lines in coord log, got $drain_sent_count"
echo "[ac6] coord log shows $drain_sent_count drain sends"

# 4. Both mock logs show drain receipt + drain_status complete.
for log in "$MOCK_A_LOG" "$MOCK_B_LOG"; do
  grep -q 'drain received from coordinator' "$log" \
    || fail "$log missing drain receipt"
  grep -q 'drain_status phase=complete' "$log" \
    || fail "$log missing drain_status complete"
done
echo "[ac6] both mocks logged drain receive + drain_status complete"

cat <<EVIDENCE

[ac6] PASS
  in-flight streams: 3/3 completed with [DONE]
  post-SIGTERM request: HTTP $new_req_status (expected non-200)
  drain dispatched to both mocks; both replied drain_status complete
  coordinator shutdown latency: $((shutdown_at - sigterm_at))s
  evidence:
    coord log:    $COORD_LOG
    mockA log:    $MOCK_A_LOG
    mockB log:    $MOCK_B_LOG
    stream outs:  /tmp/mp-ac6-stream-{1,2,3}.out

EVIDENCE

# Coordinator already dead; just clean up mocks + tempfiles.
"$ROOT/scripts/stop-local-pool.sh"
exit 0
