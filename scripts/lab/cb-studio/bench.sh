#!/bin/bash
# Run a lab benchmark with the live :8080 provider paused (operator rule
# 2026-09-25). Always resumes on exit, including failure and interrupt.
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
L=/Users/a1/lab-cb-sampling
resume() {
  for i in 1 2 3; do /usr/bin/python3 $L/live-ctl.py resume && break; sleep 5; done
  for i in $(seq 1 16); do /Users/a1/macprovider/macprovider-cli status 2>&1 | grep -q "Provider is ready" && { echo "LIVE_RESUMED $(date -u +%T)"; return; }; sleep 15; done
  # A resumed provider can stay coordinator-"unavailable" (seen on Pearl v1.8.200);
  # a clean restart reconnects it. Never leave live down.
  echo "LIVE_RESUME_UNCONFIRMED $(date -u +%T); restarting provider"
  launchctl kickstart -k gui/$(id -u)/live.malibu.provider
  for i in $(seq 1 40); do /Users/a1/macprovider/macprovider-cli status 2>&1 | grep -q "Provider is ready" && { echo "LIVE_RESUMED_AFTER_RESTART $(date -u +%T)"; return; }; sleep 15; done
  echo "LIVE_STILL_DOWN $(date -u +%T)"
}
/usr/bin/python3 $L/live-ctl.py pause || { echo "LIVE_PAUSE_FAILED"; exit 4; }
echo "LIVE_PAUSED $(date -u +%T)"
# A pause stops admission only; requests already generating keep the GPU busy
# until they finish. Measure only once live reports nothing in flight.
for i in $(seq 1 180); do
  n=$(curl -s --max-time 3 http://127.0.0.1:8080/v1/status | /usr/bin/python3 -c "import sys,json; print(json.load(sys.stdin).get('requests_in_flight', -1))" 2>/dev/null)
  [ "$n" = "0" ] && { echo "LIVE_DRAINED $(date -u +%T)"; break; }
  [ $i -eq 180 ] && { echo "LIVE_NOT_DRAINED in_flight=$n"; exit 5; }
  sleep 10
done
trap resume EXIT
trap 'exit 130' INT TERM
"$@"
