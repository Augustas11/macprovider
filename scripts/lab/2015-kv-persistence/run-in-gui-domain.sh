#!/usr/bin/env bash
# Runs studio-kv-acceptance.sh as a one-shot job in the logged-in user's GUI
# launchd domain (where the live provider LaunchAgent runs) and streams its
# output. Needed because the disk tier's per-namespace Keychain DEKs are not
# reachable from an SSH security session (errSecInteractionNotAllowed, -25308),
# which leaves the tier dormant. Lab only; the job plist lives in LAB_DIR and is
# booted out when the run ends. Environment knobs of studio-kv-acceptance.sh
# (PREP_ONLY, LAB_PORT, DOC_TOKENS, ...) are passed through.
#
# Usage on the Studio (over SSH is fine):
#   PREP_ONLY=1 bash run-in-gui-domain.sh
#   bash run-in-gui-domain.sh
set -euo pipefail
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
HERE="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="${LAB_DIR:-$HOME/lab-2015}"
LABEL="lab.2015.kv-acceptance"
DOMAIN="gui/$(id -u)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
PLIST="$LAB_DIR/$LABEL.plist"
OUTLOG="$LAB_DIR/gui-run-$STAMP.log"
# Hard deadline for the whole job (the script has its own RUN_TIMEOUT_S
# watchdog; this one also covers a script that never reaches it). On expiry the
# job is booted out: launchd TERMs the script, whose EXIT trap stops the lab
# serve and purges (ExitTimeOut below), and this wrapper exits 124.
if [[ "${PREP_ONLY:-0}" == "1" ]]; then GUI_TIMEOUT_S="${GUI_TIMEOUT_S:-600}"
else GUI_TIMEOUT_S="${GUI_TIMEOUT_S:-$(( ${RUN_TIMEOUT_S:-4500} + 300 ))}"; fi
mkdir -p "$LAB_DIR"
launchctl print "$DOMAIN" >/dev/null 2>&1 || { echo "no GUI launchd domain $DOMAIN (nobody logged in at the console)" >&2; exit 2; }
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then echo "$LABEL is already loaded; a run is in progress" >&2; exit 2; fi

python3 - "$PLIST" "$LABEL" "$HERE/studio-kv-acceptance.sh" "$LAB_DIR" "$OUTLOG" <<'PY'
import os, plistlib, sys
plist, label, script, lab, out = sys.argv[1:]
keys = ("PREP_ONLY", "LAB_DIR", "LAB_PORT", "LIVE_PORT", "SRC_INSTALL", "LAB_CONFIG_TEMPLATE", "LIVE_CONFIG",
        "EXPECT_VERSION", "DOC_TOKENS", "TTFT_CONVERSATIONS", "LOAD_TIMEOUT_S", "SELF_CHECK_TIMEOUT_S", "RUN_TIMEOUT_S",
        "KVCACHE_TIMEOUT_S", "SESSION_TIMEOUT_S", "LAB_PROVIDER_ID")
env = {k: os.environ[k] for k in keys if k in os.environ}
env["HOME"] = os.environ["HOME"]
with open(plist, "wb") as f:
    plistlib.dump({"Label": label, "ProgramArguments": ["/bin/bash", script], "EnvironmentVariables": env,
                   "WorkingDirectory": lab, "StandardOutPath": out, "StandardErrorPath": out,
                   "RunAtLoad": True, "ProcessType": "Standard",
                   # room for the script's EXIT trap: lab serve stop (<=60 s) + bounded purges
                   "ExitTimeOut": 300}, f)
PY
touch "$OUTLOG"
stop_job() { launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true; rm -f "$PLIST"; }
# Ctrl-C here stops the job; its own EXIT trap stops the lab serve and purges.
trap 'kill "${TAIL:-0}" 2>/dev/null || true; stop_job; exit 130' INT TERM HUP
launchctl bootstrap "$DOMAIN" "$PLIST"
tail -n +1 -f "$OUTLOG" & TAIL=$!
deadline=$(( $(date +%s) + GUI_TIMEOUT_S ))
timed_out=0
while :; do
  sleep 5
  if (( $(date +%s) > deadline )); then
    echo "run-in-gui-domain: GUI_TIMEOUT_S=$GUI_TIMEOUT_S reached; booting out $LABEL" >&2
    timed_out=1; break
  fi
  info="$(launchctl print "$DOMAIN/$LABEL" 2>/dev/null || true)"
  [[ -n "$info" ]] || break
  state="$(printf '%s\n' "$info" | sed -n 's/^[[:space:]]*state = //p' | head -1)"
  last="$(printf '%s\n' "$info" | sed -n 's/^[[:space:]]*last exit code = //p' | head -1)"
  [[ "$state" == running || -z "$last" || "$last" == *never* ]] || break
done
code="$(launchctl print "$DOMAIN/$LABEL" 2>/dev/null | sed -n 's/^[[:space:]]*last exit code = //p' | head -1)"
sleep 1
stop_job
kill "$TAIL" 2>/dev/null || true
if (( timed_out )); then echo "job timed out (log $OUTLOG)" >&2; exit 124; fi
echo "job exit code: ${code:-unknown} (log $OUTLOG)" >&2
[[ "$code" =~ ^[0-9]+$ ]] && exit "$code"
exit 1
