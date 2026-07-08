#!/usr/bin/env bash
# deploy-malibu-emission-pearl.sh — Session C4: MALIBU emission Pearl rollout.
#
# Applies stats migrations 012+014, installs coordinator binary with merged
# overlay (preserves OPoI canary overlay when present), and keeps
# malibu_emission.enabled=false until operator promotion.
#
# Usage (from operator Mac, repo at origin/main):
#   cd phase4-coordinator
#   bash scripts/build-linux.sh
#   bash dist/deploy-malibu-emission-pearl.sh
#
# Environment:
#   SSH_KEY                 default ~/.ssh/pearl_operator_ed25519
#   VPS_HOST                default 159.223.165.194
#   VPS_USER                default root
#   DOMAIN                  default coordinator.streamvc.live
#   FORCE_RESTART           default 0
#   SKIP_BUILD              default 0
#   SKIP_MIGRATE            default 0 — set 1 if migrations already applied
#   DRY_RUN                 default 0
#
# Pearl /etc/macprovider/coordinator.env MUST contain (non-empty):
#   COORDINATOR_PARTNER_KEYS_ADMIN_DSN  — admin-capable Postgres (stats-migrate)
#   MALIBU_EMISSION_WRITER_DSN          — rewards_writer runtime DSN
#
# Optional (first-time rewards_writer login):
#   MALIBU_EMISSION_WRITER_PASSWORD     — if set, deploy runs ALTER ROLE rewards_writer

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$SCRIPT_DIR"
MODULE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY="$DIST_DIR/coordinator-linux-amd64"
MALIBU_OVERLAY="$MODULE_DIR/coordinator.malibu-emission-overlay.yaml"
OPIO_OVERLAY="$MODULE_DIR/coordinator.opoi-v0-staging.yaml"
DROPIN="$DIST_DIR/systemd/malibu-emission.conf.example"
MERGE_PY="$DIST_DIR/merge-yaml-overlay.py"

SSH_KEY="${SSH_KEY:-$HOME/.ssh/pearl_operator_ed25519}"
VPS_HOST="${VPS_HOST:-159.223.165.194}"
VPS_USER="${VPS_USER:-root}"
DOMAIN="${DOMAIN:-coordinator.streamvc.live}"
FORCE_RESTART="${FORCE_RESTART:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"
SKIP_MIGRATE="${SKIP_MIGRATE:-0}"
DRY_RUN="${DRY_RUN:-0}"

log() { printf '[malibu-deploy] %s\n' "$*"; }
run() {
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: $*"
  else
    "$@"
  fi
}

for f in "$MALIBU_OVERLAY" "$DROPIN" "$MERGE_PY"; do
  [ -f "$f" ] || { echo "missing required file: $f" >&2; exit 1; }
done
if [ "$DRY_RUN" != "1" ] && [ ! -f "$BINARY" ]; then
  echo "missing required file: $BINARY (run scripts/build-linux.sh first)" >&2
  exit 1
fi

if [ "$SKIP_BUILD" != "1" ]; then
  log "building coordinator linux/amd64"
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: would run bash $MODULE_DIR/scripts/build-linux.sh"
  else
    bash "$MODULE_DIR/scripts/build-linux.sh"
  fi
fi

SSH=(ssh -i "$SSH_KEY" -o ConnectTimeout=10 -p 22 "$VPS_USER@$VPS_HOST")
SCP=(scp -i "$SSH_KEY" -P 22)

log "step 1/8: SSH + connected-provider guard"
if [ "$DRY_RUN" != "1" ]; then
  "${SSH[@]}" 'hostname && uptime' >/dev/null
fi
CONNECTED_COUNT=0
if [ "$DRY_RUN" != "1" ]; then
  CONNECTED_COUNT=$(curl -fsS --max-time 5 --max-filesize 65536 "https://$DOMAIN/healthz" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('pool_size', 0))" 2>/dev/null \
    || echo 0)
fi
if [ "${CONNECTED_COUNT:-0}" -gt 0 ] && [ "$FORCE_RESTART" != "1" ]; then
  log "REFUSING — $CONNECTED_COUNT provider(s) connected. Use FORCE_RESTART=1 to proceed."
  exit 4
fi
log "ok: connected providers=$CONNECTED_COUNT"

log "step 2/8: Pearl env preflight (admin + writer DSNs)"
if [ "$DRY_RUN" != "1" ]; then
  "${SSH[@]}" 'set -euo pipefail
    env_file=/etc/macprovider/coordinator.env
    [ -r "$env_file" ] || { echo "missing $env_file" >&2; exit 12; }
    require_var() {
      name="$1"
      if ! python3 - "$env_file" "$name" <<'"'"'PY'"'"'
import re, shlex, sys
path, want = sys.argv[1], sys.argv[2]
found = False
val = ""
with open(path, "r", encoding="utf-8") as f:
    for raw in f:
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key.strip() != want:
            continue
        parts = shlex.split(value.strip(), posix=True)
        if len(parts) != 1 or not parts[0]:
            sys.exit(2)
        found, val = True, parts[0]
        break
if not found or not val:
    sys.exit(1)
print(val)
PY
      then
        echo "aborting: $env_file missing or empty required var: $name" >&2
        exit 12
      fi
    }
    require_var COORDINATOR_PARTNER_KEYS_ADMIN_DSN >/dev/null
    require_var MALIBU_EMISSION_WRITER_DSN >/dev/null
    echo "  ok: COORDINATOR_PARTNER_KEYS_ADMIN_DSN and MALIBU_EMISSION_WRITER_DSN present"
  '
fi

log "step 3/8: merge Pearl overlay (OPoI + MALIBU)"
WORKDIR=""
if [ "$DRY_RUN" = "1" ]; then
  log "DRY_RUN: would merge overlays into coordinator.pearl-overlays.yaml"
else
  WORKDIR=$(mktemp -d)
  trap 'rm -rf "$WORKDIR"' EXIT
  BASE_OVERLAY="$OPIO_OVERLAY"
  if "${SSH[@]}" 'test -f /etc/macprovider/coordinator.pearl-overlays.yaml'; then
    "${SCP[@]}" "$VPS_USER@$VPS_HOST:/etc/macprovider/coordinator.pearl-overlays.yaml" "$WORKDIR/base.yaml"
    BASE_OVERLAY="$WORKDIR/base.yaml"
    log "  using existing /etc/macprovider/coordinator.pearl-overlays.yaml as merge base"
  elif "${SSH[@]}" 'test -f /etc/macprovider/coordinator.opoi-v0-staging.yaml'; then
    "${SCP[@]}" "$VPS_USER@$VPS_HOST:/etc/macprovider/coordinator.opoi-v0-staging.yaml" "$WORKDIR/base.yaml"
    BASE_OVERLAY="$WORKDIR/base.yaml"
    log "  using existing OPoI overlay as merge base"
  else
    log "  no Pearl overlay found; merging repo OPoI staging defaults"
  fi
  python3 "$MERGE_PY" "$BASE_OVERLAY" "$MALIBU_OVERLAY" > "$WORKDIR/coordinator.pearl-overlays.yaml"
fi

log "step 4/8: stage artifacts on Pearl"
if [ "$DRY_RUN" = "1" ]; then
  DEPLOY_TMP="/tmp/macprovider-malibu-deploy.XXXXXXXX"
else
  DEPLOY_TMP=$("${SSH[@]}" 'umask 077 && mktemp -d -t macprovider-malibu-deploy.XXXXXXXX')
  case "$DEPLOY_TMP" in
    /tmp/macprovider-malibu-deploy.*) ;;
    *) echo "unexpected mktemp path: $DEPLOY_TMP" >&2; exit 1 ;;
  esac
  trap "${SSH[@]} rm -rf $DEPLOY_TMP" EXIT
  "${SCP[@]}" "$BINARY" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator-linux-amd64"
  "${SCP[@]}" "$WORKDIR/coordinator.pearl-overlays.yaml" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator.pearl-overlays.yaml"
  "${SCP[@]}" "$DROPIN" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/malibu-emission.conf"
fi

log "step 5/8: install binary + merged overlay + systemd drop-in"
if [ "$DRY_RUN" != "1" ]; then
  "${SSH[@]}" "set -e
    if [ -x /opt/macprovider/coordinator ]; then
      install -o root -g macprovider -m 0750 /opt/macprovider/coordinator /opt/macprovider/coordinator.prev
    fi
    install -o root -g macprovider -m 0750 $DEPLOY_TMP/coordinator-linux-amd64 /opt/macprovider/coordinator
    install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.pearl-overlays.yaml /etc/macprovider/coordinator.pearl-overlays.yaml
    install -d -o root -g root -m 0755 /etc/systemd/system/macprovider-coordinator.service.d
    install -o root -g root -m 0644 $DEPLOY_TMP/malibu-emission.conf \
      /etc/systemd/system/macprovider-coordinator.service.d/malibu-emission.conf
    # OPS-1: remove the superseded OPoI drop-in. Its ExecStart points at
    # coordinator.opoi-v0-staging.yaml and, because systemd applies .service.d
    # drop-ins in lexicographic filename order, opoi-v0.conf sorts AFTER
    # malibu-emission.conf and its ExecStart would WIN — the coordinator would
    # then ignore the merged coordinator.pearl-overlays.yaml. The OPoI config is
    # already folded into pearl-overlays.yaml by the step 3 merge, so removing
    # this drop-in drops no configuration.
    rm -f /etc/systemd/system/macprovider-coordinator.service.d/opoi-v0.conf
  "
fi

log "step 6/8: stats-migrate (012 malibu_emission_ledger + 014 malibu_trust_unlock)"
if [ "$SKIP_MIGRATE" != "1" ] && [ "$DRY_RUN" != "1" ]; then
  "${SSH[@]}" 'set -euo pipefail
    env_file=/etc/macprovider/coordinator.env
    set -a
    # shellcheck disable=SC1090
    . "$env_file"
    set +a
    /opt/macprovider/coordinator stats-migrate --admin-dsn "$COORDINATOR_PARTNER_KEYS_ADMIN_DSN" --check
    /opt/macprovider/coordinator stats-migrate --admin-dsn "$COORDINATOR_PARTNER_KEYS_ADMIN_DSN"
    if [ -n "${MALIBU_EMISSION_WRITER_PASSWORD:-}" ]; then
      psql "$COORDINATOR_PARTNER_KEYS_ADMIN_DSN" -v ON_ERROR_STOP=1 \
        -c "ALTER ROLE rewards_writer WITH LOGIN PASSWORD '"'"'${MALIBU_EMISSION_WRITER_PASSWORD}'"'"'"
      echo "  ok: rewards_writer login password rotated from MALIBU_EMISSION_WRITER_PASSWORD"
    fi
  '
elif [ "$SKIP_MIGRATE" = "1" ]; then
  log "  SKIP_MIGRATE=1 — skipping stats-migrate"
fi

log "step 7/8: validate merged config + restart"
if [ "$DRY_RUN" != "1" ]; then
  "${SSH[@]}" 'set -euo pipefail
    env_file=/etc/macprovider/coordinator.env
    set -a
    # shellcheck disable=SC1090
    . "$env_file"
    set +a
    /opt/macprovider/coordinator \
      --config /opt/macprovider/coordinator.yaml \
      --config-overlay /etc/macprovider/coordinator.pearl-overlays.yaml \
      --validate-config
    systemctl daemon-reload
    # OPS-1: assert the effective ExecStart uses the merged overlay we just
    # validated. Guards against a lingering/again-added drop-in silently running
    # the coordinator against a different --config-overlay than --validate-config
    # checked (validate-vs-runtime divergence).
    if ! systemctl show -p ExecStart macprovider-coordinator | grep -q "coordinator.pearl-overlays.yaml"; then
      echo "ERROR: effective ExecStart does not reference coordinator.pearl-overlays.yaml" >&2
      systemctl show -p ExecStart macprovider-coordinator >&2
      exit 1
    fi
    systemctl restart macprovider-coordinator
    sleep 3
    systemctl is-active macprovider-coordinator
  '
fi

log "step 8/8: verify healthz + malibu_emission disabled log line"
if [ "$DRY_RUN" != "1" ]; then
  HEALTHZ=$(curl -fsS --max-time 10 --max-filesize 65536 "https://$DOMAIN/healthz")
  printf '%s\n' "$HEALTHZ" | python3 -m json.tool
  "${SSH[@]}" 'journalctl -u macprovider-coordinator --since "2 min ago" --no-pager' \
    | grep -E 'malibu_emission (DISABLED|started)' || true
fi

log "DONE. C4 staging complete with malibu_emission.enabled=false."
log "Verify read API from a provider token:"
log "  curl -sS -H \"Authorization: Bearer \$PROVIDER_TOKEN\" https://$DOMAIN/v1/provider/malibu-accrual | jq"
log "Promotion (accrual ticks): set malibu_emission.enabled: true in pearl overlay and restart."
log "Rollback (disable MALIBU emission, KEEP the OPoI overlay):"
log "  1. Edit /etc/macprovider/coordinator.pearl-overlays.yaml and set the"
log "     malibu_emission.enabled key to false (edit the YAML directly; do not"
log "     sed it — a blind substitution can hit another 'enabled:' key or break"
log "     indentation)."
log "  2. Validate + restart (drop-in unchanged so the OPoI overlay is preserved):"
log "     ssh -i $SSH_KEY $VPS_USER@$VPS_HOST 'sudo /opt/macprovider/coordinator --config /opt/macprovider/coordinator.yaml --config-overlay /etc/macprovider/coordinator.pearl-overlays.yaml --validate-config && sudo systemctl restart macprovider-coordinator'"
log "  Do NOT remove the malibu-emission.conf drop-in: it loads pearl-overlays.yaml,"
log "  which now also carries the merged OPoI overlay, so removing it would leave the"
log "  base unit with no --config-overlay and drop the OPoI canary config."
