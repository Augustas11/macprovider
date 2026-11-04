#!/bin/zsh
# #2222 Studio window: snapshot, pause, drain and boot out the live provider, run
# `qualify qwen36` then `qualify qwen38` back to back, then always restore the
# signed live provider (EXIT trap) and compare it with the snapshot. No
# wall-clock ceiling; the operator-side watcher flags a 30-min stall.
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
L=$HOME/macprovider-lab-2222
W=${W:-$L/window-$(date -u +%Y%m%dT%H%M%SZ)}; mkdir -p $W; export OUT=$W LAB=$L
export HEAD_COMMIT=$(cat $L/src/.lab-commit)
echo $W > $L/CURRENT_WINDOW
uid=$(id -u)
log() { echo "$(date -u +%FT%TZ) $*" | tee -a $W/wrapper.log; }
snapshot() {
  curl -s --max-time 5 http://127.0.0.1:8080/v1/status | /usr/bin/python3 -I -c "
import json,sys,hashlib
d=json.load(sys.stdin)
print(json.dumps({\"binary_version\": d.get(\"binary_version\"), \"model\": d.get(\"model\") or d.get(\"model_id\"),
  \"state\": (d.get(\"lifecycle\") or {}).get(\"state\"), \"decode_path_digest\": (d.get(\"build_identity\") or {}).get(\"decode_path_digest\"),
  \"model_loaded\": d.get(\"model_loaded\"), \"requests_in_flight\": d.get(\"requests_in_flight\"),
  \"binary_sha256\": hashlib.sha256(open(sys.argv[1],\"rb\").read()).hexdigest()}, sort_keys=True))" $HOME/macprovider/macprovider-cli 2>/dev/null
}
st() { curl -s --max-time 3 http://127.0.0.1:8080/v1/status | /usr/bin/python3 -I -c "import sys,json;d=json.load(sys.stdin);print(d.get(\"model_loaded\"),(d.get(\"lifecycle\") or {}).get(\"state\"),d.get(\"requests_in_flight\"))" 2>/dev/null; }
restore() {
  log "restore begin"
  pkill -TERM -f "$L/src/scripts/lab/cb-studio/qwen27b-mtp-window.sh" 2>/dev/null
  pkill -TERM -f "$L/src/phase3-binary/.build/" 2>/dev/null; sleep 10
  pkill -KILL -f "$L/src/phase3-binary/.build/" 2>/dev/null
  launchctl print gui/$uid/live.malibu.provider >/dev/null 2>&1 || launchctl bootstrap gui/$uid $HOME/Library/LaunchAgents/live.malibu.provider.plist
  local s=
  for i in {1..180}; do s=$(st); [[ $s == True* ]] && break; sleep 10; done
  for i in 1 2 3 4 5; do /usr/bin/python3 -I $L/live-ctl.py resume && break; sleep 10; done
  for i in {1..60}; do s=$(st); [[ $s == *serving_buyers* ]] && break; sleep 5; done
  launchctl print gui/$uid/live.malibu.provider-watchdog >/dev/null 2>&1 || launchctl bootstrap gui/$uid $HOME/Library/LaunchAgents/live.malibu.provider-watchdog.plist
  snapshot > $W/live-after.json
  /usr/bin/python3 -I -c "
import json,sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
keys=(\"binary_version\",\"model\",\"decode_path_digest\",\"binary_sha256\")
bad=[k for k in keys if a.get(k)!=b.get(k)]
ok = not bad and b.get(\"state\")==\"serving_buyers\"
print(\"SNAPSHOT_OK\" if ok else \"SNAPSHOT_MISMATCH \"+\" \".join(bad)+\" state=\"+str(b.get(\"state\")))" $W/live-before.json $W/live-after.json | tee -a $W/wrapper.log
  log "restore end status=$s"; touch $W/RESTORED
}
snapshot > $W/live-before.json; log "before $(cat $W/live-before.json)"
grep -q serving_buyers $W/live-before.json || { log "refusing: live provider not serving_buyers before the window"; touch $W/RESTORED; exit 3; }
trap restore EXIT
log "pause live"; /usr/bin/python3 -I $L/live-ctl.py pause | tee -a $W/wrapper.log
for i in {1..120}; do n=$(curl -s --max-time 3 http://127.0.0.1:8080/v1/status | /usr/bin/python3 -I -c "import sys,json;print(json.load(sys.stdin).get(\"requests_in_flight\",0))" 2>/dev/null); [[ $n == 0 ]] && break; sleep 5; done
log "drained in_flight=$n"
launchctl bootout gui/$uid/live.malibu.provider-watchdog 2>/dev/null; launchctl bootout gui/$uid/live.malibu.provider 2>/dev/null
for i in {1..24}; do [[ -z $(lsof -nP -t -iTCP:8080 -sTCP:LISTEN 2>/dev/null) ]] && ! pgrep -f "^$HOME/macprovider/macprovider-cli serve" >/dev/null && break; sleep 5; done
log "live booted out"
# One model per invocation. A single ${=MODELS:-a b} word was passed through
# as one argument on 2026-11-03 and qualify exited before any leg.
typeset -a models
if [[ -n ${MODELS:-} ]]; then
  models=(${=MODELS})
else
  models=(qwen36 qwen38)
fi
for m in $models; do
  log "qualify $m begin"
  zsh $L/src/scripts/lab/cb-studio/qwen27b-mtp-window.sh qualify $m >> $W/legs.log 2>&1
  rc=$?
  log "qualify $m rc=$rc"
done
log "all legs done"
