#!/usr/bin/env bash
# macprovider-watchdog: operator-visibility insurance against silent WS
# disconnection of the local provider, the symptom described in
# GitHub issue #189.
#
# Failure mode it catches: process up, listening on its local
# inference port, but the outbound TCP socket to the coordinator
# has gone half-open and the Swift reconnect loop never re-establishes.
# We detect this via `netstat -an` (BSD form on macOS) — if no
# ESTABLISHED outbound connection exists to coordinator.streamvc.live
# on tcp/443 for `provider_id`'s service, kick the launchd job so
# launchctl restarts the binary.
#
# Companion to the in-process bounded-send + watchdog landed in
# #189 (PR #204). That fix prevents the wedge from happening; this
# script catches it if it happens anyway, until every operator is on
# a binary that includes the Swift fix.

set -euo pipefail

LABEL="${MACPROVIDER_WATCHDOG_LABEL:-live.streamvc.macprovider}"
CONFIG_PATH="${MACPROVIDER_CONFIG_PATH:-$HOME/.config/macprovider/config.yaml}"
COORDINATOR_HOST="${MACPROVIDER_COORDINATOR_HOST:-coordinator.streamvc.live}"
COORDINATOR_PORT="${MACPROVIDER_COORDINATOR_PORT:-443}"
LOG_DIR="${MACPROVIDER_LOG_DIR:-$HOME/Library/Logs/macprovider}"
LOG_PATH="$LOG_DIR/watchdog.log"
# Issue #191 R1 architect HIGH: arming + grace state. Without
# these, a first-time install can spin in a restart loop — the
# Swift CLI loads the model BEFORE connecting to the coordinator
# (cold-cache model load is 10-20 minutes), and a watchdog that
# kicks on "no ESTABLISHED connection" would Darwin.exit the
# process every 60s before it ever opens its socket.
#
# Arming rule: the watchdog stays disarmed (no kicks) until it
# observes at least ONE successful ESTABLISHED connection IN THE
# CURRENT BOOT. The armed marker stores the boot id (kern.boottime
# sec) so a reboot — which restarts the provider into a fresh
# cold-cache model load — re-disarms the watchdog and prevents the
# stale-arming restart loop the R1 fix did not cover (R2 ARCH HIGH).
#
# Grace rule: after we DO kick, we wait at least KICK_GRACE_SECONDS
# before kicking again. This covers the post-kick model-reload
# window without re-triggering on the gap between launchd respawn
# and re-establishing the coordinator socket.
STATE_DIR="${MACPROVIDER_WATCHDOG_STATE_DIR:-$HOME/.local/share/macprovider-watchdog/state}"
ARMED_FILE="$STATE_DIR/armed"
LAST_KICK_FILE="$STATE_DIR/last_kick"
KICK_GRACE_SECONDS="${MACPROVIDER_WATCHDOG_KICK_GRACE_SECONDS:-300}"

mkdir -p "$LOG_DIR" "$STATE_DIR"

# Boot id: per-boot identifier sourced from kern.bootsessionuuid.
# Apple-provided UUID is immutable for the lifetime of a single
# boot (verified against XNU sysctl: read-only). Unlike
# kern.boottime, this value is NOT affected by NTP / manual
# wall-clock time correction (R3 architect MEDIUM #1), so a
# clock-set event during a wedge cannot silently re-disarm the
# watchdog and let the wedge persist.
current_boot_id() {
  sysctl -n kern.bootsessionuuid 2>/dev/null
}

# Acceptable formats in config.yaml are: `provider_id: ID` (yaml
# key) or `provider-id: ID` (alternate hyphenated form some operator
# tools have written historically). Either matches and surfaces the
# value with surrounding whitespace stripped.
read_provider_id() {
  if [ ! -f "$CONFIG_PATH" ]; then
    return 1
  fi
  awk '
    /^[[:space:]]*provider[_-]id[[:space:]]*:/ {
      sub(/^[^:]*:[[:space:]]*/, "")
      sub(/[[:space:]]*#.*$/, "")
      sub(/[[:space:]]+$/, "")
      gsub(/^["'\'']|["'\'']$/, "")
      print
      exit
    }
  ' "$CONFIG_PATH"
}

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { printf "[%s] %s\n" "$(ts)" "$*" >> "$LOG_PATH"; }

resolve_coordinator_ip() {
  # First try dscacheutil (no network call if already cached);
  # fall back to host(1) which most macs have via bind-utils.
  ip="$(dscacheutil -q host -a name "$COORDINATOR_HOST" 2>/dev/null \
        | awk '/^ip_address:/ { print $2; exit }')"
  if [ -z "$ip" ] && command -v host >/dev/null 2>&1; then
    ip="$(host -t A "$COORDINATOR_HOST" 2>/dev/null \
          | awk '/has address/ { print $4; exit }')"
  fi
  printf "%s" "${ip:-}"
}

has_established_conn() {
  ip="$1"
  if [ -z "$ip" ]; then
    return 1
  fi
  # BSD netstat on macOS: print ESTABLISHED TCP rows; awk matches
  # the foreign-address column against our coordinator IP:port.
  # Format: Proto Recv-Q Send-Q Local-Address Foreign-Address (state)
  netstat -an -p tcp 2>/dev/null \
    | awk -v target="${ip}.${COORDINATOR_PORT}" '
        $0 ~ /ESTABLISHED/ && $5 == target { found = 1; exit }
        END { exit found ? 0 : 1 }
      '
}

kick_provider() {
  log "kicking $LABEL via launchctl kickstart -k gui/$UID/$LABEL"
  launchctl kickstart -k "gui/$UID/$LABEL" >> "$LOG_PATH" 2>&1 || \
    log "launchctl kickstart returned non-zero (likely benign — process may already be restarting)"
}

now_epoch() { date -u +%s; }

main() {
  pid="$(read_provider_id || true)"
  if [ -z "$pid" ]; then
    # Provider not yet installed / configured. Stay silent; if the
    # operator installs later we'll start working on the next tick.
    exit 0
  fi
  coord_ip="$(resolve_coordinator_ip)"
  if [ -z "$coord_ip" ]; then
    log "DNS resolution for $COORDINATOR_HOST failed; skipping this tick"
    exit 0
  fi
  boot_id="$(current_boot_id)"
  if has_established_conn "$coord_ip"; then
    # First time in THIS BOOT we see a healthy ESTABLISHED
    # connection, arm the watchdog. Subsequent absences will then
    # trigger a kick.
    armed_boot=""
    if [ -f "$ARMED_FILE" ]; then
      armed_boot="$(cat "$ARMED_FILE" 2>/dev/null || true)"
    fi
    if [ "$armed_boot" != "$boot_id" ]; then
      log "arming watchdog (boot=${boot_id}): first observed ESTABLISHED TCP to ${coord_ip}:${COORDINATOR_PORT} for provider_id=${pid}"
      printf "%s" "$boot_id" > "$ARMED_FILE"
    fi
    # Healthy. Stay silent so the log file does not bloat.
    exit 0
  fi
  # No ESTABLISHED connection. If we have not armed THIS BOOT (first
  # install / post-reboot still loading model / provider never
  # configured / provider never connected), stay silent — kicking
  # would break the cold-start flow.
  armed_boot=""
  if [ -f "$ARMED_FILE" ]; then
    armed_boot="$(cat "$ARMED_FILE" 2>/dev/null || true)"
  fi
  if [ "$armed_boot" != "$boot_id" ]; then
    exit 0
  fi
  # Post-kick grace: do not kick again until KICK_GRACE_SECONDS has
  # passed. Covers the launchd-respawn + model-reload + reconnect
  # window after our prior kick.
  if [ -f "$LAST_KICK_FILE" ]; then
    last_kick="$(cat "$LAST_KICK_FILE" 2>/dev/null || printf 0)"
    elapsed=$(( $(now_epoch) - last_kick ))
    if [ "$elapsed" -lt "$KICK_GRACE_SECONDS" ]; then
      # Inside the grace window; silent — operator can spot this in
      # the previous kick log line if they want.
      exit 0
    fi
  fi
  log "no ESTABLISHED TCP to ${coord_ip}:${COORDINATOR_PORT} for provider_id=${pid}; kicking $LABEL"
  now_epoch > "$LAST_KICK_FILE"
  kick_provider
}

main "$@"
