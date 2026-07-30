#!/usr/bin/env bash
# deploy-opoi-v0-pearl.sh — retired Pearl rollout; dry-run reference only.
#
# Does NOT run the full deploy-pearl-vps.sh (no nginx/certbot/coordinator.yaml
# overwrite). Use after merging PR #478+ to main.
#
# Usage (from operator Mac, repo checkout at origin/main or later):
#   cd phase4-coordinator
#   bash scripts/build-linux.sh          # builds dist/coordinator-linux-amd64
#   bash dist/deploy-opoi-v0-pearl.sh
#
# Environment:
#   SSH_KEY          default ~/.ssh/pearl_operator_ed25519
#   VPS_HOST         default 159.223.165.194
#   VPS_USER         default root
#   DOMAIN           default coordinator.streamvc.live (healthz + pool_size check)
#   FORCE_RESTART    default 0 — set 1 to restart with connected providers
#   SKIP_BUILD       default 0 — set 1 if dist/coordinator-linux-amd64 already built
#   DRY_RUN          default 0 — set 1 to print actions only
#
# Rollback:
#   ssh pearl 'sudo rm /etc/systemd/system/macprovider-coordinator.service.d/opoi-v0.conf \
#     && sudo systemctl daemon-reload && sudo systemctl restart macprovider-coordinator'
#   # Binary rollback: /opt/macprovider/coordinator.prev → coordinator (see OPS.md)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$SCRIPT_DIR"
MODULE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY="$DIST_DIR/coordinator-linux-amd64"
OVERLAY="$MODULE_DIR/coordinator.opoi-v0-staging.yaml"
DROPIN="$DIST_DIR/systemd/opoi-v0.conf.example"

SSH_KEY="${SSH_KEY:-$HOME/.ssh/pearl_operator_ed25519}"
VPS_HOST="${VPS_HOST:-159.223.165.194}"
VPS_USER="${VPS_USER:-root}"
DOMAIN="${DOMAIN:-coordinator.streamvc.live}"
FORCE_RESTART="${FORCE_RESTART:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"
DRY_RUN="${DRY_RUN:-0}"

log() { printf '[opoi-deploy] %s\n' "$*"; }
run() {
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: $*"
  else
    "$@"
  fi
}

if [ "$DRY_RUN" != "1" ]; then
  echo "REFUSING: this coordinator-only Pearl deploy authority is retired." >&2
  echo "Use the signed backend-pair updater; do not replace the hash-proven coordinator independently." >&2
  exit 5
fi

for f in "$OVERLAY" "$DROPIN"; do
  [ -f "$f" ] || { echo "missing required file: $f" >&2; exit 1; }
done
if [ "$DRY_RUN" != "1" ] && [ ! -f "$BINARY" ]; then
  echo "missing required file: $BINARY (run scripts/build-linux.sh first)" >&2
  exit 1
fi

if [ "$SKIP_BUILD" != "1" ]; then
  log "building coordinator linux/amd64 (scripts/build-linux.sh)"
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: would run bash $MODULE_DIR/scripts/build-linux.sh"
  else
    bash "$MODULE_DIR/scripts/build-linux.sh"
  fi
fi

SSH=(ssh -i "$SSH_KEY" -o ConnectTimeout=10 -p 22 "$VPS_USER@$VPS_HOST")
SCP=(scp -i "$SSH_KEY" -P 22)

log "step 1/6: SSH + connected-provider guard"
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
  log "REFUSING — $CONNECTED_COUNT provider(s) connected. Restart triggers drain."
  log "Proceed with: FORCE_RESTART=1 bash dist/deploy-opoi-v0-pearl.sh"
  exit 4
fi
log "ok: connected providers=$CONNECTED_COUNT (or FORCE_RESTART=1)"

log "step 2/6: stage artifacts on Pearl"
if [ "$DRY_RUN" = "1" ]; then
  DEPLOY_TMP="/tmp/macprovider-opoi-deploy.XXXXXXXX"
  log "DRY_RUN: would mktemp on Pearl"
else
  DEPLOY_TMP=$("${SSH[@]}" 'umask 077 && mktemp -d -t macprovider-opoi-deploy.XXXXXXXX')
  case "$DEPLOY_TMP" in
    /tmp/macprovider-opoi-deploy.*) ;;
    *) echo "unexpected mktemp path: $DEPLOY_TMP" >&2; exit 1 ;;
  esac
  "${SCP[@]}" "$BINARY" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator-linux-amd64"
  "${SCP[@]}" "$OVERLAY" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator.opoi-v0-staging.yaml"
  "${SCP[@]}" "$DROPIN" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/opoi-v0.conf"
fi

log "step 3/6: install binary + overlay + systemd drop-in"
if [ "$DRY_RUN" != "1" ]; then
  "${SSH[@]}" "set -e
    if [ -x /opt/macprovider/coordinator ]; then
      install -o root -g macprovider -m 0750 /opt/macprovider/coordinator /opt/macprovider/coordinator.prev
      echo '  binary snapshot: /opt/macprovider/coordinator.prev'
    fi
    install -o root -g macprovider -m 0750 $DEPLOY_TMP/coordinator-linux-amd64 /opt/macprovider/coordinator
    install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.opoi-v0-staging.yaml /etc/macprovider/coordinator.opoi-v0-staging.yaml
    install -d -o root -g root -m 0755 /etc/systemd/system/macprovider-coordinator.service.d
    install -o root -g root -m 0644 $DEPLOY_TMP/opoi-v0.conf /etc/systemd/system/macprovider-coordinator.service.d/opoi-v0.conf
  "
fi

log "step 4/6: validate merged config"
if [ "$DRY_RUN" != "1" ]; then
  "${SSH[@]}" 'set -euo pipefail
    env_file=/etc/macprovider/coordinator.env
    if [ ! -f "$env_file" ]; then
      echo "missing $env_file (required for --validate-config env expansion)" >&2
      exit 1
    fi
    set -a
    # shellcheck disable=SC1090
    . "$env_file"
    set +a
    /opt/macprovider/coordinator \
      --config /opt/macprovider/coordinator.yaml \
      --config-overlay /etc/macprovider/coordinator.opoi-v0-staging.yaml \
      --validate-config'
fi

log "step 5/6: restart coordinator"
if [ "$DRY_RUN" != "1" ]; then
  "${SSH[@]}" 'set -e
    systemctl daemon-reload
    systemctl restart macprovider-coordinator
    sleep 3
    systemctl is-active macprovider-coordinator
  '
fi

log "step 6/6: verify /healthz + version"
if [ "$DRY_RUN" != "1" ]; then
  HEALTHZ=$(curl -fsS --max-time 10 --max-filesize 65536 "https://$DOMAIN/healthz")
  printf '%s\n' "$HEALTHZ" | python3 -m json.tool
  DEPLOYED_VERSION=$(printf '%s' "$HEALTHZ" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','?'))")
  EXPECTED_VERSION=$(git -C "$MODULE_DIR" describe --always --dirty --tags 2>/dev/null || git -C "$MODULE_DIR" rev-parse --short HEAD)
  log "provenance: deployed=$DEPLOYED_VERSION expected=$EXPECTED_VERSION"
fi

log "DONE. Watch canaries:"
log "  ssh -i $SSH_KEY $VPS_USER@$VPS_HOST journalctl -fu macprovider-coordinator | grep -E 'canary (passed|failed|skipped)'"
log "Rollback overlay:"
log "  ssh -i $SSH_KEY $VPS_USER@$VPS_HOST 'sudo rm /etc/systemd/system/macprovider-coordinator.service.d/opoi-v0.conf && sudo systemctl daemon-reload && sudo systemctl restart macprovider-coordinator'"
