#!/usr/bin/env bash
# watchdog.sh — every-60s self-monitor for the local macprovider-cli.
#
# Detects the "silent disconnection" failure mode observed on
# augustass-macbook-air 2026-06-25 → 2026-06-27 (provider process alive,
# no outbound socket to coordinator, no stdout log activity, WS dead but
# the Swift reconnect loop never re-established). The provider stayed in
# this state for ~42 hours; coordinator stopped routing to it after 90s
# but the operator had no signal until the network started failing.
#
# Detection: the host must have at least one ESTABLISHED outbound TCP
# connection to the coordinator's IP on :443. If it doesn't (and the
# macprovider-cli process is alive), the WS is dead — kick via launchctl.
#
# We use `netstat` rather than `lsof -p` because (a) lsof's -p / -i
# filters are OR without -a (bug-prone) and (b) on macOS Sonoma+,
# enumerating other processes' sockets via lsof can return empty
# without the right entitlements. netstat just reads the kernel's
# socket table and doesn't depend on per-process visibility.
#
# Log: /Users/augstar/Library/Logs/macprovider/watchdog.log
# Schedule: launchd plist live.streamvc.macprovider-watchdog every 60s.

set -uo pipefail

LABEL="live.streamvc.macprovider"
LOG="${HOME}/Library/Logs/macprovider/watchdog.log"
PROCESS_PATTERN="macprovider-cli.*augustass-macbook-air"

# coordinator.streamvc.live -> Pearl VPS. Hardcoded to avoid a DNS hop
# inside the watchdog (DNS could itself be why the WS died). If the VPS
# ever moves, update here AND in phase4-coordinator/dist/deploy-pearl-vps.sh.
COORD_IP="159.223.165.194"
COORD_PORT="443"

mkdir -p "$(dirname "${LOG}")"

log() {
  printf '%s watchdog: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "${LOG}"
}

PID="$(pgrep -f "${PROCESS_PATTERN}" 2>/dev/null | head -1)"
if [ -z "${PID:-}" ]; then
  # Process is absent — launchd KeepAlive will respawn it. Nothing to do.
  log "no process matching ${PROCESS_PATTERN}; launchd will respawn"
  exit 0
fi

# Count outbound TCP ESTABLISHED to coord IP:port. The provider opens
# exactly one such socket. netstat fields differ between BSD and Linux;
# on macOS the line looks like:
#   tcp4   0   0   192.168.8.12.50769   159.223.165.194.443   ESTABLISHED
# So we match "<COORD_IP>.<COORD_PORT>" anywhere in the remote-address
# column, with ESTABLISHED at end.
OUT_443="$(netstat -ant 2>/dev/null \
  | awk -v ip="${COORD_IP}" -v port="${COORD_PORT}" '
      $NF == "ESTABLISHED" {
        for (i = 1; i <= NF; i++) {
          if (index($i, ip "." port) > 0) { c++; break }
        }
      }
      END { print c+0 }')"

if [ "${OUT_443}" -ge 1 ]; then
  # Healthy. Nothing to do. Optionally log on a slower cadence to keep
  # the log file readable — every 10th invocation marks alive.
  MIN="$(date +%M)"
  if [ $(( 10#${MIN} % 10 )) -eq 0 ]; then
    log "pid=${PID} ws_to_coord=${OUT_443} (ok)"
  fi
  exit 0
fi

log "pid=${PID} ws_to_coord=0 (no ESTABLISHED to ${COORD_IP}:${COORD_PORT}) — SILENT DISCONNECT detected; kicking ${LABEL}"

# launchctl kickstart -k: kill the existing process and start a fresh one.
# `gui/<uid>/<label>` is the user-domain target for LaunchAgents.
UID_NUM="$(id -u)"
if ! launchctl kickstart -k "gui/${UID_NUM}/${LABEL}" >> "${LOG}" 2>&1; then
  log "launchctl kickstart FAILED — retry with bootout/bootstrap"
  # Fallback: bounce the agent. plist path is conventional under user agents.
  PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
  launchctl bootout "gui/${UID_NUM}" "${PLIST}" >> "${LOG}" 2>&1 || true
  launchctl bootstrap "gui/${UID_NUM}" "${PLIST}" >> "${LOG}" 2>&1 || true
fi

# Give launchd a moment to respawn, then verify.
sleep 8
NEW_PID="$(pgrep -f "${PROCESS_PATTERN}" 2>/dev/null | head -1)"
if [ -n "${NEW_PID:-}" ] && [ "${NEW_PID}" != "${PID}" ]; then
  log "respawned: pid=${NEW_PID} (was ${PID})"
else
  log "WARN respawn did not produce a new pid (was=${PID} now=${NEW_PID:-none})"
fi
