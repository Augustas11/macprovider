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
mkdir -p "$LAB_DIR"
launchctl print "$DOMAIN" >/dev/null 2>&1 || { echo "no GUI launchd domain $DOMAIN (nobody logged in at the console)" >&2; exit 2; }
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then echo "$LABEL is already loaded; a run is in progress" >&2; exit 2; fi

python3 - "$PLIST" "$LABEL" "$HERE/studio-kv-acceptance.sh" "$LAB_DIR" "$OUTLOG" <<'PY'
import os, plistlib, sys
plist, label, script, lab, out = sys.argv[1:]
keys = ("PREP_ONLY", "LAB_DIR", "LAB_PORT", "LIVE_PORT", "SRC_INSTALL", "LAB_CONFIG_TEMPLATE", "LIVE_CONFIG",
        "EXPECT_VERSION", "DOC_TOKENS", "TTFT_CONVERSATIONS", "LOAD_TIMEOUT_S", "SELF_CHECK_TIMEOUT_S", "RUN_TIMEOUT_S")
env = {k: os.environ[k] for k in keys if k in os.environ}
env["HOME"] = os.environ["HOME"]
with open(plist, "wb") as f:
    plistlib.dump({"Label": label, "ProgramArguments": ["/bin/bash", script], "EnvironmentVariables": env,
                   "WorkingDirectory": lab, "StandardOutPath": out, "StandardErrorPath": out,
                   "RunAtLoad": True, "ProcessType": "Standard",
                   # room for the script's EXIT trap: lab serve stop (<=60 s) + purge
                   "ExitTimeOut": 150}, f)
PY
touch "$OUTLOG"
stop_job() { launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true; rm -f "$PLIST"; }
# Ctrl-C here stops the job; its own EXIT trap stops the lab serve and purges.
trap 'kill "${TAIL:-0}" 2>/dev/null || true; stop_job; exit 130' INT TERM HUP
launchctl bootstrap "$DOMAIN" "$PLIST"
tail -n +1 -f "$OUTLOG" & TAIL=$!
while :; do
  sleep 5
  info="$(launchctl print "$DOMAIN/$LABEL" 2>/dev/null || true)"
  [[ -n "$info" ]] || break
  state="$(printf '%s\n' "$info" | sed -n 's/^[[:space:]]*state = //p' | head -1)"
  last="$(printf '%s\n' "$info" | sed -n 's/^[[:space:]]*last exit code = //p' | head -1)"
  [[ "$state" == running || -z "$last" || "$last" == *never* ]] || break
done
code="$(launchctl print "$DOMAIN/$LABEL" 2>/dev/null | sed -n 's/^[[:space:]]*last exit code = //p' | head -1)"
sleep 1
kill "$TAIL" 2>/dev/null || true
stop_job
echo "job exit code: ${code:-unknown} (log $OUTLOG)" >&2
[[ "$code" =~ ^[0-9]+$ ]] && exit "$code"
exit 1
