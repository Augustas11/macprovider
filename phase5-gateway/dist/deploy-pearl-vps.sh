#!/usr/bin/env bash
# deploy-pearl-vps.sh — scripted Pearl-VPS deploy for the gateway (M1-6).
#
# Mirrors phase4-coordinator/dist/deploy-pearl-vps.sh: idempotent, fail-closed
# config gate as step 0, .prev binary snapshot for one-command rollback,
# version-stamped provenance check on /healthz. The previous gateway deploy
# was an .md runbook with no scripted automation — DEVE-4 in the
# audits/2026-06-10/REPO_AUDIT.md.
#
# Run this from the operator's Mac. It SSHes into Pearl VPS, installs the
# gateway behind the existing nginx + Let's Encrypt for api.streamvc.live,
# and verifies the public endpoint.
#
# Prerequisites:
#   - gateway-linux-amd64 cross-compiled into dist/ (see build-linux.sh)
#   - /etc/macprovider/gateway.env on Pearl already contains:
#       COORDINATOR_OPERATOR_KEY, COORDINATOR_SERVICE_TOKEN,
#       MACPROVIDER_KEY_HASH_SECRET,
#       MACPROVIDER_DEMO_SIGNING_SECRET,
#       GITHUB_OAUTH_CLIENT_ID, GITHUB_OAUTH_CLIENT_SECRET
#     This deploy script does NOT touch that file — secrets stay on the VPS.
#   - nginx site for api.streamvc.live already exists; we reinstall it from
#     dist/nginx-api.streamvc.live.conf on every deploy.
#   - DNS A record api.streamvc.live -> $VPS_HOST.
#
# Usage:
#   bash deploy-pearl-vps.sh
#
# Environment:
#   SSH_KEY          default: ~/.ssh/pearl_operator_ed25519
#   VPS_HOST         default: 159.223.165.194
#   VPS_USER         default: root
#   DOMAIN           default: api.streamvc.live
#   EMAIL            default: augstar@gmail.com
#   --dry-run-local  developer-only: run the old local-config C2 check using
#                    GATEWAY_CONFIG and exit before any SSH mutation.
#   GATEWAY_CONFIG   used only with --dry-run-local. Production deploys validate
#                    the gateway config installed on Pearl.
#   GATEWAY_REMOTE_CONFIG  installed gateway config path on Pearl.
#                    Default: /opt/macprovider/gateway.yaml.
#   COORD_CONFIG     used only with --dry-run-local. Defaults to the checked-in
#                    coordinator deploy config.
#   COORD_REMOTE_CONFIG  installed coordinator config path on Pearl.
#                    Default: /opt/macprovider/coordinator.yaml.
#   COORD_REMOTE_OVERLAY  installed coordinator overlay path on Pearl.
#                    Default: /etc/macprovider/coordinator.pearl-overlays.yaml.
#   C2C_COORD_OPERATOR_KEY_SHA256, C2C_COORD_SERVICE_TOKEN_SHA256,
#   C2C_GATEWAY_SERVICE_TOKEN_SHA256, C2C_GATEWAY_OPERATOR_KEY_SHA256
#                    required by --dry-run-local when either config uses
#                    env:NAME credentials. Compute each SHA-256 independently
#                    from its respective runtime EnvironmentFile; never pass
#                    raw credential values. Production computes these proofs
#                    on Pearl and returns only the digests.
#   FORCE_RESTART=1  bypass the connected-buyer guard (similar to the
#                    coordinator's connected-provider guard).
#   STRICT_PROVENANCE=1  abort if /healthz returns no "version" field.

set -euo pipefail

DRY_RUN_LOCAL=0
for arg in "$@"; do
  case "$arg" in
    --dry-run-local) DRY_RUN_LOCAL=1 ;;
    *)
      echo "unknown argument: $arg" >&2
      echo "usage: bash deploy-pearl-vps.sh [--dry-run-local]" >&2
      exit 2
      ;;
  esac
done

SSH_KEY="${SSH_KEY:-$HOME/.ssh/pearl_operator_ed25519}"
VPS_HOST="${VPS_HOST:-159.223.165.194}"
VPS_USER="${VPS_USER:-root}"
DOMAIN="${DOMAIN:-api.streamvc.live}"
EMAIL="${EMAIL:-augstar@gmail.com}"

# #290 (mirrors #244 R2 CODE MED): validate DOMAIN + EMAIL up front so a
# typo doesn't fail mid-deploy leaving the VPS in a partial state.
# DOMAIN must be a plausible hostname; EMAIL must have exactly one @ with
# non-empty local and domain parts. Not RFC-strict; guards against
# accidental empty/whitespace/multiline overrides.
case "$DOMAIN" in
  *' '*|*$'\n'*|'')
    echo "aborting deploy: DOMAIN='$DOMAIN' is empty or contains whitespace" >&2
    exit 1
    ;;
esac
case "$DOMAIN" in
  *[!A-Za-z0-9.-]*)
    echo "aborting deploy: DOMAIN='$DOMAIN' contains invalid characters (only A-Za-z0-9.- allowed)" >&2
    exit 1
    ;;
esac
case "$EMAIL" in
  *' '*|*$'\n'*|'')
    echo "aborting deploy: EMAIL='$EMAIL' is empty or contains whitespace" >&2
    exit 1
    ;;
  *@*@*)
    echo "aborting deploy: EMAIL='$EMAIL' has more than one '@'" >&2
    exit 1
    ;;
  *@?*)
    _email_local="${EMAIL%@*}"
    [ -n "$_email_local" ] || {
      echo "aborting deploy: EMAIL='$EMAIL' has empty local part" >&2
      exit 1
    }
    ;;
  *)
    echo "aborting deploy: EMAIL='$EMAIL' missing '@' with non-empty domain" >&2
    exit 1
    ;;
esac

# #290 R1 (CODE+SEC+ARCH convergent MED) — the baked-in vhost template
# `nginx-api.streamvc.live.conf` hardcodes `server_name api.streamvc.live`
# and matching Let's Encrypt paths. Refuse if $DOMAIN was overridden to
# something else; otherwise we'd install a vhost with a non-matching
# server_name / cert path against a live gateway binary. Mirrors the
# same guard on the coordinator side (chat_proxy has domain=coordinator.streamvc.live).
if [ "$DOMAIN" != "api.streamvc.live" ]; then
  echo "aborting deploy: DOMAIN override ($DOMAIN) does not match the baked-in vhost template" >&2
  echo "  dist/nginx-api.streamvc.live.conf has server_name=api.streamvc.live hardcoded." >&2
  echo "  Edit the conf file in lockstep, or remove the DOMAIN env override." >&2
  exit 1
fi

DIST_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="$DIST_DIR/gateway-linux-amd64"
SERVICE="$DIST_DIR/macprovider-gateway.service"
NGINX_SITE="$DIST_DIR/nginx-api.streamvc.live.conf"

# M1-6 follow-up (codex audits 2026-06-11): no .example fallback. Sample
# config is documentation, not an operational input — passing C2 against
# example timeouts while the real VPS config has drifted is a false
# fail-closed gate.
GATEWAY_CONFIG_DEFAULT="$DIST_DIR/gateway.yaml"
GATEWAY_CONFIG="${GATEWAY_CONFIG:-$GATEWAY_CONFIG_DEFAULT}"
GATEWAY_REMOTE_CONFIG="${GATEWAY_REMOTE_CONFIG:-/opt/macprovider/gateway.yaml}"
COORD_REMOTE_CONFIG="${COORD_REMOTE_CONFIG:-/opt/macprovider/coordinator.yaml}"
COORD_REMOTE_OVERLAY="${COORD_REMOTE_OVERLAY:-/etc/macprovider/coordinator.pearl-overlays.yaml}"

COORD_CONFIG_DEFAULT="$DIST_DIR/../../phase4-coordinator/dist/coordinator.yaml"
COORD_CONFIG="${COORD_CONFIG:-$COORD_CONFIG_DEFAULT}"

CHECK_SCRIPT="$DIST_DIR/../../phase4-coordinator/dist/check-deploy-config.sh"
C2C_PROOF_SCRIPT="$DIST_DIR/../../phase4-coordinator/dist/lib/c2c_runtime_proof.py"
MERGE_OVERLAY_SCRIPT="$DIST_DIR/../../phase4-coordinator/dist/merge-yaml-overlay.py"

for f in "$BINARY" "$SERVICE" "$NGINX_SITE"; do
  [ -f "$f" ] || { echo "missing required file: $f" >&2; exit 1; }
done
if [ ! -r "$C2C_PROOF_SCRIPT" ]; then
  echo "aborting deploy: runtime credential proof helper missing or unreadable: $C2C_PROOF_SCRIPT" >&2
  exit 5
fi

# #290 R2 SEC MED — assert the shipped nginx template still contains
# the expected `server_name` + Let's Encrypt paths before we upload +
# sed-uncomment it on the remote. Rejects an accidentally edited /
# stale checked-in conf that would point to a different vhost / cert.
if ! grep -qE '^[[:space:]]*server_name[[:space:]]+api\.streamvc\.live;' "$NGINX_SITE"; then
  echo "aborting deploy: nginx template $NGINX_SITE is missing 'server_name api.streamvc.live;'" >&2
  exit 5
fi
if ! grep -qE '# ssl_certificate[[:space:]]+/etc/letsencrypt/live/api\.streamvc\.live/' "$NGINX_SITE"; then
  echo "aborting deploy: nginx template $NGINX_SITE cert path drifted from expected /etc/letsencrypt/live/api.streamvc.live/" >&2
  exit 5
fi

SSH="ssh -i $SSH_KEY -o ConnectTimeout=10 -p 22 $VPS_USER@$VPS_HOST"
SCP="scp -i $SSH_KEY -P 22"

log() { printf "\n[deploy-gateway] %s\n" "$*"; }

case "$GATEWAY_REMOTE_CONFIG" in
  /*) ;;
  *) echo "aborting deploy: GATEWAY_REMOTE_CONFIG must be an absolute path" >&2; exit 5 ;;
esac
case "$COORD_REMOTE_CONFIG" in
  /*) ;;
  *) echo "aborting deploy: COORD_REMOTE_CONFIG must be an absolute path" >&2; exit 5 ;;
esac
case "$COORD_REMOTE_OVERLAY" in
  /*) ;;
  *) echo "aborting deploy: COORD_REMOTE_OVERLAY must be an absolute path" >&2; exit 5 ;;
esac
case "$COORD_REMOTE_CONFIG" in
  *[!A-Za-z0-9._/-]*)
    echo "aborting deploy: COORD_REMOTE_CONFIG contains unsupported characters: $COORD_REMOTE_CONFIG" >&2
    exit 5
    ;;
esac
case "$COORD_REMOTE_OVERLAY" in
  *[!A-Za-z0-9._/-]*)
    echo "aborting deploy: COORD_REMOTE_OVERLAY contains unsupported characters: $COORD_REMOTE_OVERLAY" >&2
    exit 5
    ;;
esac
case "$GATEWAY_REMOTE_CONFIG" in
  *[!A-Za-z0-9._/-]*)
    echo "aborting deploy: GATEWAY_REMOTE_CONFIG contains unsupported characters: $GATEWAY_REMOTE_CONFIG" >&2
    exit 5
    ;;
esac

# #290 (mirrors #244 R6 CODE+SEC+ARCH convergent MED) — register the
# EXIT cleanup trap UNCONDITIONALLY, before any temp resource is
# created. Same threat model as the coordinator: if the deploy fails
# mid-flight, the remote staging dir must not persist. $DEPLOY_TMP is
# guarded with `:-` so the trap is a no-op when it is unset.
trap '
  rm -f "${GATEWAY_REMOTE_CONFIG_TMP:-}"
  rm -f "${COORD_REMOTE_CONFIG_TMP:-}"
  rm -f "${COORD_REMOTE_OVERLAY_TMP:-}"
  rm -f "${COORD_EFFECTIVE_CONFIG_TMP:-}"
  if [ -n "${DEPLOY_TMP:-}" ]; then
    $SSH "rm -rf $DEPLOY_TMP" 2>/dev/null || true
  fi
' EXIT

read_gateway_db_path_from_file() {
  awk '
    BEGIN { in_storage=0 }
    {
      line=$0
      sub(/[[:space:]]+#.*$/, "", line)
    }
    line ~ /^[[:space:]]*storage:[[:space:]]*$/ { in_storage=1; next }
    in_storage && line ~ /^[^[:space:]#][^:]*:/ { exit }
    in_storage && line ~ /^[[:space:]]*db_path:[[:space:]]*/ {
      sub(/^[[:space:]]*db_path:[[:space:]]*/, "", line)
      gsub(/^"|"$/, "", line)
      gsub(/^'\''|'\''$/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      print line
      exit
    }
  ' "$1"
}

yaml_file_block_value() {
  local file="$1" block="$2" key="$3"
  awk -v block="$block" -v key="$key" '
    BEGIN { in_block=0 }
    {
      line=$0
      sub(/[[:space:]]+#.*$/, "", line)
    }
    line ~ "^[[:space:]]*" block ":[[:space:]]*$" { in_block=1; next }
    in_block && line ~ /^[^[:space:]#][^:]*:/ { exit }
    in_block {
      if (line ~ "^[[:space:]]*" key ":[[:space:]]*") {
        sub("^[[:space:]]*" key ":[[:space:]]*", "", line)
        gsub(/^"|"$/, "", line)
        gsub(/^'\''|'\''$/, "", line)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        print line
        exit
      }
    }
  ' "$file"
}

# #615 production exception gate runs independently of C2. SKIP_C2_CHECK must
# never suppress registered-row exception enforcement.
REPO_ROOT="$(CDPATH= cd -- "$DIST_DIR/../.." && pwd -P)"
EXCEPTION_CHECK="$REPO_ROOT/scripts/check-production-exceptions.py"
if [ ! -f "$EXCEPTION_CHECK" ]; then
  echo "aborting gateway deploy: production exception checker missing: $EXCEPTION_CHECK" >&2
  exit 5
fi
log "step 0a/8: production exception register gate (deploy, default-safe unless ENFORCEMENT=1)"
python3 "$EXCEPTION_CHECK" gate --mode=deploy || {
  echo "aborting gateway deploy: production exception gate failed" >&2
  exit 5
}

log "step 0/8: pre-deploy C2 cross-component config check"
# M1-6 follow-up (codex audits 2026-06-11): require real configs for C2.
# The previous "best-effort" path treated missing inputs as a warning, which
# weakened a deploy gate the audit called out as mandatory. SKIP_C2_CHECK is
# now refused by the shared gate and by this wrapper before any deploy read.
if [ "$DRY_RUN_LOCAL" = "1" ]; then
  echo "  --dry-run-local set — validating local GATEWAY_CONFIG and exiting before deploy" >&2
  if [ -x "$CHECK_SCRIPT" ] && [ -f "$COORD_CONFIG" ] && [ -f "$GATEWAY_CONFIG" ]; then
    C2C_COORD_OPERATOR_KEY_SHA256="${C2C_COORD_OPERATOR_KEY_SHA256:-}" \
    C2C_COORD_SERVICE_TOKEN_SHA256="${C2C_COORD_SERVICE_TOKEN_SHA256:-}" \
    C2C_GATEWAY_SERVICE_TOKEN_SHA256="${C2C_GATEWAY_SERVICE_TOKEN_SHA256:-}" \
    C2C_GATEWAY_OPERATOR_KEY_SHA256="${C2C_GATEWAY_OPERATOR_KEY_SHA256:-}" \
      bash "$CHECK_SCRIPT" "$COORD_CONFIG" "$GATEWAY_CONFIG" || {
      echo "aborting gateway deploy dry-run: local config-drift check failed" >&2; exit 5;
    }
    echo "  local dry-run C2 check passed"
    exit 0
  fi
  echo "aborting gateway deploy dry-run: cannot run local C2 cross-check." >&2
  echo "  check-deploy-config.sh: $CHECK_SCRIPT $( [ -x "$CHECK_SCRIPT" ] || echo '(missing or not executable)')" >&2
  echo "  coordinator config:    $COORD_CONFIG $( [ -f "$COORD_CONFIG" ] || echo '(missing)')" >&2
  echo "  gateway config:        $GATEWAY_CONFIG $( [ -f "$GATEWAY_CONFIG" ] || echo '(missing — provide GATEWAY_CONFIG=<path>)')" >&2
  exit 5
elif [ -x "$CHECK_SCRIPT" ]; then
  if [ "${SKIP_C2_CHECK:-0}" = "1" ]; then
    echo "aborting gateway deploy: SKIP_C2_CHECK=1 is no longer supported; fix C2/C2b config instead" >&2
    exit 5
  fi
	  COORD_REMOTE_CONFIG_TMP="$(umask 077 && mktemp -t macprovider-coordinator-installed-config.XXXXXXXX)" || {
	    echo "aborting gateway deploy: mktemp failed for installed coordinator config copy" >&2; exit 5;
	  }
  $SSH "test -f '$COORD_REMOTE_CONFIG' || { echo 'missing installed coordinator config: $COORD_REMOTE_CONFIG' >&2; exit 1; }; cat '$COORD_REMOTE_CONFIG'" > "$COORD_REMOTE_CONFIG_TMP" || {
	    echo "aborting gateway deploy: could not read installed coordinator config from Pearl: $COORD_REMOTE_CONFIG" >&2
	    exit 5
	  }
	  CHECK_ARGS=("$COORD_REMOTE_CONFIG_TMP")
	  COORD_C2C_CONFIG_TMP="$COORD_REMOTE_CONFIG_TMP"
	  if $SSH "test -f '$COORD_REMOTE_OVERLAY'"; then
	    if [ ! -x "$MERGE_OVERLAY_SCRIPT" ]; then
	      echo "aborting gateway deploy: YAML overlay merge helper missing or not executable: $MERGE_OVERLAY_SCRIPT" >&2
	      exit 5
	    fi
	    COORD_REMOTE_OVERLAY_TMP="$(umask 077 && mktemp -t macprovider-coordinator-installed-overlay.XXXXXXXX)" || {
	      echo "aborting gateway deploy: mktemp failed for installed coordinator overlay copy" >&2; exit 5;
	    }
	    $SSH "cat '$COORD_REMOTE_OVERLAY'" > "$COORD_REMOTE_OVERLAY_TMP" || {
	      echo "aborting gateway deploy: could not read installed coordinator overlay from Pearl: $COORD_REMOTE_OVERLAY" >&2
	      exit 5
	    }
	    COORD_EFFECTIVE_CONFIG_TMP="$(umask 077 && mktemp -t macprovider-coordinator-effective-config.XXXXXXXX)" || {
	      echo "aborting gateway deploy: mktemp failed for effective coordinator config copy" >&2; exit 5;
	    }
	    python3 "$MERGE_OVERLAY_SCRIPT" "$COORD_REMOTE_CONFIG_TMP" "$COORD_REMOTE_OVERLAY_TMP" > "$COORD_EFFECTIVE_CONFIG_TMP" || {
	      echo "aborting gateway deploy: could not merge installed coordinator base config with overlay" >&2
	      exit 5
	    }
	    CHECK_ARGS+=("$COORD_REMOTE_OVERLAY_TMP")
	    COORD_C2C_CONFIG_TMP="$COORD_EFFECTIVE_CONFIG_TMP"
	  fi
	  GATEWAY_REMOTE_CONFIG_TMP="$(umask 077 && mktemp -t macprovider-gateway-installed-config.XXXXXXXX)" || {
	    echo "aborting gateway deploy: mktemp failed for installed config copy" >&2; exit 5;
	  }
  $SSH "test -f '$GATEWAY_REMOTE_CONFIG' || { echo 'missing installed gateway config: $GATEWAY_REMOTE_CONFIG' >&2; exit 1; }; cat '$GATEWAY_REMOTE_CONFIG'" > "$GATEWAY_REMOTE_CONFIG_TMP" || {
    echo "aborting gateway deploy: could not read installed gateway config from Pearl: $GATEWAY_REMOTE_CONFIG" >&2
    exit 5
  }
	  GATEWAY_REMOTE_CONFIG_SHA=$(shasum -a 256 "$GATEWAY_REMOTE_CONFIG_TMP" | awk '{print $1}')
	  COORD_REMOTE_CONFIG_SHA=$(shasum -a 256 "$COORD_REMOTE_CONFIG_TMP" | awk '{print $1}')
	  echo "  validating installed Pearl coordinator config: $COORD_REMOTE_CONFIG sha256=$COORD_REMOTE_CONFIG_SHA"
	  if [ -n "${COORD_REMOTE_OVERLAY_TMP:-}" ]; then
	    COORD_REMOTE_OVERLAY_SHA=$(shasum -a 256 "$COORD_REMOTE_OVERLAY_TMP" | awk '{print $1}')
	    echo "  validating installed Pearl coordinator overlay: $COORD_REMOTE_OVERLAY sha256=$COORD_REMOTE_OVERLAY_SHA"
	  fi
	  echo "  validating installed Pearl gateway config: $GATEWAY_REMOTE_CONFIG sha256=$GATEWAY_REMOTE_CONFIG_SHA"

  # PR #172 C2c: the gateway will restart and consume gateway.env, while the
  # coordinator keeps its current process environment. Prove that exact
  # next-state pairing on Pearl. The helper also requires the peer's env file
  # and process to match, so a later peer restart cannot change the proven
  # state. Current-peer credentials must use env:NAME because inline YAML
  # cannot be read authoritatively from an already-running process. Only
  # SHA-256 digests cross SSH; bearer material remains on Pearl.
  _c2c_env_name() {
    local raw="$1"
    case "$raw" in
      env:*)
        raw="${raw#env:}"
        if ! printf '%s' "$raw" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$'; then
          echo "aborting gateway deploy: malformed env:NAME in credential pairing field" >&2
          return 1
        fi
        printf '%s' "$raw"
        ;;
      *) printf '%s' - ;;
    esac
  }
	  _coord_op_name="$(_c2c_env_name "$(yaml_file_block_value "$COORD_C2C_CONFIG_TMP" auth operator_key)")" || exit 5
	  _coord_svc_name="$(_c2c_env_name "$(yaml_file_block_value "$COORD_C2C_CONFIG_TMP" auth gateway_service_token)")" || exit 5
  _gateway_svc_name="$(_c2c_env_name "$(yaml_file_block_value "$GATEWAY_REMOTE_CONFIG_TMP" coordinator service_token)")" || exit 5
  _gateway_op_name="$(_c2c_env_name "$(yaml_file_block_value "$GATEWAY_REMOTE_CONFIG_TMP" coordinator operator_key)")" || exit 5
  _c2c_proofs="$($SSH python3 - gateway-deploy "$_coord_op_name" "$_coord_svc_name" "$_gateway_svc_name" "$_gateway_op_name" < "$C2C_PROOF_SCRIPT")" || {
    echo "aborting gateway deploy: could not prove coordinator/gateway credential pairing on Pearl" >&2
    exit 5
  }
  read -r C2C_COORD_OPERATOR_KEY_SHA256 C2C_COORD_SERVICE_TOKEN_SHA256 C2C_GATEWAY_SERVICE_TOKEN_SHA256 C2C_GATEWAY_OPERATOR_KEY_SHA256 <<EOF
$_c2c_proofs
EOF
  C2C_COORD_OPERATOR_KEY_SHA256="$C2C_COORD_OPERATOR_KEY_SHA256" \
  C2C_COORD_SERVICE_TOKEN_SHA256="$C2C_COORD_SERVICE_TOKEN_SHA256" \
  C2C_GATEWAY_SERVICE_TOKEN_SHA256="$C2C_GATEWAY_SERVICE_TOKEN_SHA256" \
	  C2C_GATEWAY_OPERATOR_KEY_SHA256="$C2C_GATEWAY_OPERATOR_KEY_SHA256" \
	    bash "$CHECK_SCRIPT" "${CHECK_ARGS[0]}" "$GATEWAY_REMOTE_CONFIG_TMP" "${CHECK_ARGS[@]:1}" || {
	    echo "aborting gateway deploy: config-drift check failed" >&2; exit 5;
	  }
else
  echo "aborting gateway deploy: cannot run C2 cross-check." >&2
  echo "  check-deploy-config.sh: $CHECK_SCRIPT $( [ -x "$CHECK_SCRIPT" ] || echo '(missing or not executable)')" >&2
  echo "  installed coordinator config on Pearl: $COORD_REMOTE_CONFIG" >&2
  echo "  installed gateway config on Pearl: $GATEWAY_REMOTE_CONFIG" >&2
  echo "  SKIP_C2_CHECK=1 is no longer supported; local gateway.yaml files are intentionally NOT accepted in production deploy mode." >&2
  exit 5
fi
if [ -z "${GATEWAY_REMOTE_CONFIG_TMP:-}" ]; then
  GATEWAY_REMOTE_CONFIG_TMP="$(umask 077 && mktemp -t macprovider-gateway-installed-config.XXXXXXXX)" || {
    echo "aborting gateway deploy: mktemp failed for installed config copy" >&2; exit 5;
  }
  $SSH "test -f '$GATEWAY_REMOTE_CONFIG' || { echo 'missing installed gateway config: $GATEWAY_REMOTE_CONFIG' >&2; exit 1; }; cat '$GATEWAY_REMOTE_CONFIG'" > "$GATEWAY_REMOTE_CONFIG_TMP" || {
    echo "aborting gateway deploy: could not read installed gateway config from Pearl: $GATEWAY_REMOTE_CONFIG" >&2
    exit 5
  }
  GATEWAY_REMOTE_CONFIG_SHA=$(shasum -a 256 "$GATEWAY_REMOTE_CONFIG_TMP" | awk '{print $1}')
  echo "  installed Pearl config sha256=$GATEWAY_REMOTE_CONFIG_SHA"
fi
REMOTE_GATEWAY_DB_PATH="$(read_gateway_db_path_from_file "$GATEWAY_REMOTE_CONFIG_TMP")"
if [ -z "$REMOTE_GATEWAY_DB_PATH" ]; then
  echo "aborting gateway deploy: installed Pearl config missing storage.db_path ($GATEWAY_REMOTE_CONFIG sha256=$GATEWAY_REMOTE_CONFIG_SHA)" >&2
  exit 5
fi
case "$REMOTE_GATEWAY_DB_PATH" in
  /*) ;;
  *) echo "aborting gateway deploy: storage.db_path must be absolute in installed Pearl config: $REMOTE_GATEWAY_DB_PATH" >&2; exit 5 ;;
esac
case "$REMOTE_GATEWAY_DB_PATH" in
  *[!A-Za-z0-9._/-]*)
    echo "aborting gateway deploy: storage.db_path contains unsupported characters: $REMOTE_GATEWAY_DB_PATH" >&2
    exit 5
    ;;
esac
echo "  installed Pearl DB path: $REMOTE_GATEWAY_DB_PATH"
REMOTE_GATEWAY_DB_DIR="$(dirname "$REMOTE_GATEWAY_DB_PATH")"
REMOTE_GATEWAY_DB_BASE="$(basename "$REMOTE_GATEWAY_DB_PATH")"
if ! grep -qE '^[[:space:]]*coordinator_request_seconds:' "$GATEWAY_REMOTE_CONFIG_TMP"; then
  echo "  FAIL: installed gateway config $GATEWAY_REMOTE_CONFIG missing timeouts.coordinator_request_seconds" >&2
  exit 5
fi
log "step 1/8: confirm SSH + DNS"
$SSH 'hostname && uptime' >/dev/null
dig +short "$DOMAIN" | grep -q "$VPS_HOST" || { echo "DNS for $DOMAIN does not resolve to $VPS_HOST yet" >&2; exit 1; }

# Previous-deploy bypass tombstone — the coordinator script and this
# script share /var/lib/macprovider/last-deploy-bypass.json. Surface
# it here so the operator can audit before scping a new binary.
# Does NOT exit — informational only.
PREV_BYPASS=$($SSH 'cat /var/lib/macprovider/last-deploy-bypass.json 2>/dev/null || true')
if [ -n "$PREV_BYPASS" ]; then
  log "  NOTE: previous deploy left a bypass tombstone:"
  printf '%s\n' "$PREV_BYPASS" | sed 's/^/    /'
  log "  If audited, clear with: ssh <pearl> rm /var/lib/macprovider/last-deploy-bypass.json"
fi

log "step 2/8: confirm /etc/macprovider/gateway.env exists on Pearl"
$SSH "test -f /etc/macprovider/gateway.env || { echo 'missing /etc/macprovider/gateway.env on Pearl' >&2; exit 1; }"

log "step 2b/8: ensure macprovider user + /opt/macprovider parent-dir hardening"
# #290 R1 (SEC+ARCH convergent HIGH) — the .prev / binary ownership
# hardening (root:macprovider 0750 files inside) is state-dependent on
# /opt/macprovider itself being root-owned. If this script runs on a
# rebuilt / partially restored host where /opt/macprovider is still
# daemon-writable (e.g. left over from pre-hardening state), a
# compromised macprovider UID can still unlink/replace root-owned
# files inside the parent. Enforce here — idempotent; matches the
# coordinator's step 3 pattern.
$SSH 'set -e
  id macprovider >/dev/null 2>&1 || useradd --system --home /opt/macprovider --shell /usr/sbin/nologin macprovider
  install -d -o root -g macprovider -m 0750 /opt/macprovider
  install -d -o macprovider -g macprovider -m 0750 /var/lib/macprovider
'

log "step 2c/8: pre-restart safeguard EARLY (before binary swap)"
# #290 R2 (CODE+ARCH convergent HIGH) — MOVED this guard from post-
# install step 5 to pre-install step 2c. Previously the binary was
# already swapped on disk by the time the guard refused, so a
# subsequent crash / reboot / manual restart between the failed guard
# and rollback would boot the new schema-migrating binary against an
# unsnapshotted DB — defeating the issue #196 rollback safety.
#
# Query the LIVE (old) gateway's /healthz for in-flight buyer count.
# Refuse to proceed unless FORCE_RESTART=1 acknowledges the drop.
#
# #290 R3 (CODE MED + SEC HIGH) — the guard now FAILS CLOSED when the
# metric is missing/unparseable. Prior code defaulted to 0 on any
# parse failure, effectively treating a missing metric as "no in-flight
# requests" — the guard silently passed while the healthz shape (which
# does not currently emit `in_flight_requests`) rendered it a no-op.
# INFLIGHT is now either an integer >= 0 or the literal string "unknown".
INFLIGHT=$(curl -fsS --max-time 5 --max-filesize 65536 "https://$DOMAIN/healthz" 2>/dev/null \
  | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print('unknown'); sys.exit(0)
for k in ('in_flight_requests', 'inflight'):
    v = d.get(k)
    # #290 R4 (3-of-3 HIGH) — reject booleans explicitly. Python
    # bool is a subclass of int, so \`isinstance(v, int)\` matches
    # True/False. A malformed \`{\"in_flight_requests\": true}\`
    # would print \"True\" and bypass the shell-side numeric check
    # via fall-through. \`type(v) is int\` is exact-type match.
    if type(v) is int and v >= 0:
        print(v); sys.exit(0)
    if isinstance(v, str) and v.isdigit():
        print(int(v)); sys.exit(0)
print('unknown')
" 2>/dev/null || echo "unknown")
# #290 R4 SEC HIGH — belt-and-braces shell-side validation. After the
# Python parser, INFLIGHT MUST be either the literal string "unknown"
# or a bounded ASCII digit string. Any other shape (whitespace, "True",
# "1e9", "-5", etc.) is treated as "unknown" and fails closed.
case "$INFLIGHT" in
  unknown) ;;
  ''|*[!0-9]*) INFLIGHT="unknown" ;;
  *) if [ "${#INFLIGHT}" -gt 10 ]; then INFLIGHT="unknown"; fi ;;
esac
if [ "${INFLIGHT}" = "unknown" ] && [ "${FORCE_RESTART:-0}" != "1" ]; then
  log "  REFUSING TO PROCEED — gateway /healthz did not report a numeric in-flight metric."
  log "  Cannot verify quiet window; refusing EARLY (pre-scp) so no artifact is placed."
  log "  To proceed anyway:  FORCE_RESTART=1 bash $0"
  exit 4
fi
if [ "${INFLIGHT}" != "unknown" ] && [ "${INFLIGHT:-0}" -gt 0 ] && [ "${FORCE_RESTART:-0}" != "1" ]; then
  log "  REFUSING TO PROCEED — $INFLIGHT request(s) in flight."
  log "  Refusing EARLY (pre-scp) so no new binary is left on disk."
  log "  To proceed anyway:  FORCE_RESTART=1 bash $0"
  exit 4
fi
# Tombstone the FORCE_RESTART=1 override for any bypass case (in-flight
# > 0 OR healthz metric unknown). #290 R3 SEC HIGH — audit the "unknown"
# bypass path too so operators can post-audit deploys that ran without
# a verifiable quiet window.
if [ "${FORCE_RESTART:-0}" = "1" ]; then
  if [ "${INFLIGHT}" = "unknown" ] || { [ "${INFLIGHT}" != "unknown" ] && [ "${INFLIGHT:-0}" -gt 0 ]; }; then
    TS_NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    # #290 R4 SEC HIGH — sanitize $HOSTNAME (untrusted local env value).
    # If it contains anything other than A-Za-z0-9.- we fall back to
    # "unknown". Prior code interpolated it directly into a double-quoted
    # remote heredoc; a HOSTNAME=$(id) attack would then execute on Pearl
    # while writing the tombstone.
    _op_host_raw="${HOSTNAME:-unknown}"
    case "$_op_host_raw" in
      *[!A-Za-z0-9.-]*|'') OP_HOST="unknown" ;;
      *) OP_HOST="$_op_host_raw" ;;
    esac
    # JSON value: quote strings, don't quote numbers.
    if [ "${INFLIGHT}" = "unknown" ]; then
      INFLIGHT_JSON='"unknown"'
    else
      INFLIGHT_JSON="$INFLIGHT"
    fi
    # #290 R1 (mirrors #244 R6 convergent MED) — write tombstone via
    # remote `mktemp` under `umask 077`, not predictable /tmp path.
    $SSH "set -e
          install -d -o macprovider -g macprovider -m 0750 /var/lib/macprovider 2>/dev/null || true
          _bypass_tmp=\$(umask 077 && mktemp)
          cat > \"\$_bypass_tmp\" <<EOF
{\"ts\":\"$TS_NOW\",\"service\":\"gateway\",\"reason\":\"FORCE_RESTART=1\",\"step\":\"2c\",\"metric\":\"in_flight_requests\",\"value\":$INFLIGHT_JSON,\"operator_host\":\"$OP_HOST\"}
EOF
          install -o macprovider -g macprovider -m 0640 \"\$_bypass_tmp\" /var/lib/macprovider/last-deploy-bypass.json
          rm -f \"\$_bypass_tmp\"
          logger -t macprovider-deploy \"FORCE_RESTART=1 used at gateway step 2c; in_flight=$INFLIGHT\""
    log "  AUDIT TRAIL: FORCE_RESTART=1 override written to /var/lib/macprovider/last-deploy-bypass.json"
  fi
fi
log "  ok: $INFLIGHT in-flight requests (or FORCE_RESTART=1 set)"

log "step 2d/8: pre-restart snapshot of gateway.db (BEFORE binary swap — #290 R2)"
# #290 R2 (CODE+ARCH convergent HIGH) — MOVED from step 5b to 2d.
# Rollback safety (issue #196) requires the DB snapshot to be taken
# BEFORE the binary is swapped on disk. Otherwise: any crash/reboot/
# manual restart after step 4's install but before step 5b would boot
# the new schema-migrating binary with no pre-deploy snapshot.
#
# #290 R2 CODE HIGH — snapshot pruning was `ls ... | xargs rm -f`
# over filenames in a daemon-writable directory, opening a
# filename-injection window (a macprovider-created file with a
# newline in the name would inject arbitrary paths into rm). Prune
# now runs as macprovider via a Python one-liner that strict-
# validates the exact `gateway.db.pre-deploy.YYYYMMDDTHHMMSSZ`
# pattern via regex (see step 2d snapshot block) — no shell
# expansion, no xargs, filename-injection closed.
$SSH 'set -e
  TS=$(date -u +%Y%m%dT%H%M%SZ)
  DB='"$REMOTE_GATEWAY_DB_PATH"'
  if [ -f "$DB" ]; then
    SNAP="${DB}.pre-deploy.${TS}"
    # #290 R1 (SEC+ARCH convergent CRITICAL) — run ENTIRE snapshot as
    # macprovider under umask 077. No root chmod/chown on daemon-
    # writable paths — closes the symlink-follow → root-code-exec
    # race that could target /etc/systemd/system/macprovider-gateway.service.
    sudo -u macprovider sh -c "umask 077 && sqlite3 \"$DB\" \".backup ${SNAP}\""
    INTEG=$(sudo -u macprovider sqlite3 "$SNAP" "PRAGMA integrity_check;" 2>&1 | head -1)
    if [ "$INTEG" != "ok" ]; then
      echo "  ERROR: snapshot integrity_check returned: $INTEG" >&2
      sudo -u macprovider rm -f "$SNAP"
      exit 5
    fi
    echo "  db snapshot saved at $SNAP (WAL-consistent, integrity=ok)"
    # #290 R2 CODE HIGH — retain the 5 most recent pre-deploy snapshots;
    # prune older ones as macprovider (no root ops on daemon-writable
    # dir) via python with strict filename validation. Python enforces
    # the exact `gateway.db.pre-deploy.YYYYMMDDTHHMMSSZ` pattern, so a
    # macprovider-planted file with newline/space/`../` in the name
    # cannot smuggle an unlink of arbitrary paths.
    sudo -u macprovider python3 - <<PYEOF
import os, re, sys
d = "'"$REMOTE_GATEWAY_DB_DIR"'"
base = "'"$REMOTE_GATEWAY_DB_BASE"'"
pat = re.compile("^" + re.escape(base) + r"\.pre-deploy\.[0-9]{8}T[0-9]{6}Z$")
try:
    entries = os.listdir(d)
except OSError:
    sys.exit(0)
snaps = sorted([e for e in entries if pat.match(e)], reverse=True)
for stale in snaps[5:]:
    p = os.path.join(d, stale)
    try:
        st = os.lstat(p)
        # Defense in depth: only unlink regular files (not symlinks or
        # dirs), matching what \`find -type f\` would do.
        if not (st.st_mode & 0o170000) == 0o100000:
            continue
        os.unlink(p)
    except OSError:
        pass
PYEOF
  else
    echo "  no live gateway.db at $DB — first deploy, no snapshot needed"
  fi
'

log "step 3/8: snapshot live gateway binary as .prev (rollback)"
# Mirror the coordinator's M0-5 .prev pattern. install(1) is intentional —
# preserves ownership/perms even if a future recovery rebuilds the snapshot.
# #290 (mirrors #244 R5 SEC CRITICAL / R5 SEC MED): ownership tightened
# to root:macprovider 0750. Previously macprovider:macprovider 0755,
# which meant a compromised macprovider UID could rewrite the rollback
# binary — a persistent attack path against the /opt/macprovider surface.
# Parent dir /opt/macprovider is guaranteed root:macprovider 0750 by
# step 2b above; files inside can be group-read by the macprovider
# daemon but not written by anything running as macprovider.
$SSH 'if [ -x /opt/macprovider/gateway ]; then
        install -o root -g macprovider -m 0750 /opt/macprovider/gateway /opt/macprovider/gateway.prev
        echo "  snapshot saved at /opt/macprovider/gateway.prev (root:macprovider 0750)"
      else
        echo "  no live gateway at /opt/macprovider/gateway — first deploy"
      fi'

log "step 4/8: upload binary + service unit + nginx site"
# #290 (mirrors #244 R5 SEC CRITICAL) — stage uploaded artifacts into a
# fresh per-deploy root-owned 0700 directory instead of predictable
# /tmp/<name> paths. Otherwise any local user (including a compromised
# macprovider UID) can race the SCP/install window and substitute their
# own systemd unit, binary, or nginx config — which root then installs.
# `mktemp -d` returns a fresh dir with mode 0700 owned by the SSH user
# (root). The wider /tmp permissions (1777) don't matter because the
# fresh subdir denies traversal.
DEPLOY_TMP=$($SSH 'umask 077 && mktemp -d -t macprovider-deploy.XXXXXXXX') || {
  echo "failed to create remote staging directory" >&2; exit 1;
}
case "$DEPLOY_TMP" in
  /tmp/macprovider-deploy.*) ;;
  *)
    echo "aborting deploy: mktemp produced unexpected path: '$DEPLOY_TMP'" >&2
    exit 1
    ;;
esac
log "  staging dir: $DEPLOY_TMP (root:root 0700)"

$SCP "$BINARY"     "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/gateway-linux-amd64"
$SCP "$SERVICE"    "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/macprovider-gateway.service"
$SCP "$NGINX_SITE" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-api.streamvc.live.conf"

$SSH "set -e
  # #290 (mirrors #244 R5 SEC MED) — binary is root:macprovider 0750.
  # macprovider daemon can execute + read via group; only root can write.
  install -o root -g macprovider -m 0750 $DEPLOY_TMP/gateway-linux-amd64 /opt/macprovider/gateway
  install -o root -g root -m 0644 $DEPLOY_TMP/macprovider-gateway.service /etc/systemd/system/macprovider-gateway.service
  install -o root -g root -m 0644 $DEPLOY_TMP/nginx-api.streamvc.live.conf /etc/nginx/sites-available/$DOMAIN
  # EXIT trap will rm -rf \$DEPLOY_TMP after script exits (success or
  # failure). Explicit cleanup here is not required.
  ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/$DOMAIN
  # Mirror the coordinator script's step 6b: nginx-api.streamvc.live.conf ships
  # with the ssl_certificate / ssl_certificate_key lines commented (so a
  # first-deploy clean run before certbot doesn't fail nginx -t with a missing
  # cert). The cert exists by the time we get here on every subsequent deploy;
  # uncomment idempotently. Without this, step 4 fails nginx -t with
  # 'no ssl_certificate is defined for the listen ... ssl' (Pearl, 2026-06-11
  # deploy — mitigated by switching to a binary-only swap at the time).
  sed -i 's|# ssl_certificate /etc/letsencrypt|ssl_certificate /etc/letsencrypt|g' /etc/nginx/sites-available/$DOMAIN
  sed -i 's|# ssl_certificate_key /etc/letsencrypt|ssl_certificate_key /etc/letsencrypt|g' /etc/nginx/sites-available/$DOMAIN
  # C2 nginx tuning: worker_connections is an events-context directive,
  # so it must be applied in the global nginx.conf rather than the vhost.
  if ! grep -qE '^[[:space:]]*worker_connections[[:space:]]+' /etc/nginx/nginx.conf; then
    echo 'aborting deploy: /etc/nginx/nginx.conf has no active worker_connections directive to tune' >&2
    exit 5
  fi
  if [ ! -f /etc/nginx/nginx.conf.bak.macprovider-c2 ]; then
    install -o root -g root -m 0644 /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak.macprovider-c2
  fi
  sed -i -E 's#^([[:space:]]*)worker_connections[[:space:]]+[0-9]+;#\1worker_connections 4096;#' /etc/nginx/nginx.conf
  grep -qE '^[[:space:]]*worker_connections[[:space:]]+4096;' /etc/nginx/nginx.conf || {
    echo 'aborting deploy: failed to set worker_connections 4096 in /etc/nginx/nginx.conf' >&2
    exit 5
  }
  nginx -t
  systemctl reload nginx
"

# step 5 + 5b were merged into step 2c + 2d (in-flight guard EARLY +
# DB snapshot BEFORE binary swap). #290 R2 CODE+ARCH convergent HIGH.

log "step 6/8: enable + start gateway service"
$SSH 'set -e
  systemctl daemon-reload
  systemctl enable macprovider-gateway
  systemctl restart macprovider-gateway
  sleep 3
  systemctl is-active macprovider-gateway
  ss -tlnp | grep -E ":9443" >/dev/null || { echo "gateway did not bind :9443" >&2; exit 1; }
'

log "step 7/8: verify public endpoints + provenance"
sleep 2
echo "  GET https://$DOMAIN/healthz"
HEALTHZ_BODY=$(curl -fsS --max-time 10 --max-filesize 65536 "https://$DOMAIN/healthz" || { echo "healthz failed"; exit 1; })
printf '%s\n' "$HEALTHZ_BODY" | python3 -m json.tool

DEPLOYED_VERSION=$(printf '%s' "$HEALTHZ_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version', '?'))" 2>/dev/null || echo "?")
EXPECTED_VERSION=$(git describe --always --dirty --tags 2>/dev/null || git rev-parse --short HEAD)
if [ "$DEPLOYED_VERSION" = "?" ]; then
  echo "  CRITICAL provenance MISSING: /healthz returned no \"version\" field" >&2
  echo "           This almost certainly means the deployed gateway binary predates M0-5 instrumentation." >&2
  echo "           Expected: $EXPECTED_VERSION" >&2
  if [ "${STRICT_PROVENANCE:-0}" = "1" ]; then
    echo "  STRICT_PROVENANCE=1 set — aborting." >&2
    exit 7
  fi
elif [ "$DEPLOYED_VERSION" = "$EXPECTED_VERSION" ]; then
  echo "  provenance OK: deployed=$DEPLOYED_VERSION | expected=$EXPECTED_VERSION"
else
  echo "  WARN provenance mismatch: deployed=$DEPLOYED_VERSION | expected=$EXPECTED_VERSION" >&2
fi

echo "  GET https://$DOMAIN/v1/models without auth -> expect 401"
STATUS=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN/v1/models")
if [ "$STATUS" != "401" ] && [ "$STATUS" != "403" ]; then
  echo "  WARN: /v1/models without auth returned $STATUS (expected 401 or 403)" >&2
fi

log "step 8/8: tail the gateway journal for sanity"
$SSH 'journalctl -u macprovider-gateway --no-pager -n 20'

log "DONE. gateway is live at https://$DOMAIN"
echo
echo "Rollback:"
echo
echo "  IMPORTANT — issue #196 added a schema upgrade (v1 -> v2) the OLD"
echo "  binary cannot safely read. After any deploy that crosses schema"
echo "  versions, restore BOTH the binary AND the pre-deploy DB snapshot:"
echo
echo "    ssh $VPS_USER@$VPS_HOST '"
echo "      # #290 R6 convergent CODE+ARCH MED — mirror the OPS.md"
echo "      # canonical rollback recipe: validate snapshot AND .prev"
echo "      # binary BEFORE stopping the service, use sudo -u macprovider"
echo "      # consistently for reader validation on 0750 daemon-owned"
echo "      # dirs, and confirm healthz at the end."
echo "      # #290 R7 CODE MED plus R8 CODE+ARCH MED: glob must expand"
echo "      # INSIDE the sudo-macprovider shell (caller may not traverse"
echo "      # the 0750 daemon dir), AND the sh -c body must use DOUBLE"
echo "      # quotes so it does not close the outer ssh single-quote."
ROLLBACK_DB_DIR="$(dirname "$REMOTE_GATEWAY_DB_PATH")"
ROLLBACK_DB_BASE="$(basename "$REMOTE_GATEWAY_DB_PATH")"
echo "      LATEST=\$(sudo -u macprovider sh -c \"ls -1t $ROLLBACK_DB_DIR/$ROLLBACK_DB_BASE.pre-deploy.* 2>/dev/null | head -1\") &&"
echo "      [ -n \"\$LATEST\" ] && sudo -u macprovider test -f \"\$LATEST\" && sudo -u macprovider test -r \"\$LATEST\" &&"
echo "      sudo -u macprovider sqlite3 \"\$LATEST\" \"PRAGMA integrity_check;\" | head -1 | grep -q \"^ok\$\" &&"
echo "      # Validate .prev binary is present + executable BEFORE stopping"
echo "      # the service — otherwise the stop creates avoidable downtime"
echo "      # with nothing to swap in."
echo "      sudo test -x /opt/macprovider/gateway.prev &&"
echo "      # Snapshot + binary verified. Now stop + swap binary + restore DB."
echo "      sudo systemctl stop macprovider-gateway &&"
echo "      sudo install -o root -g macprovider -m 0750 /opt/macprovider/gateway.prev /opt/macprovider/gateway &&"
echo "      # #290 R3 CODE HIGH — remove stale WAL/SHM sidecars before"
echo "      # restoring the snapshot; SQLite would otherwise replay the WAL"
echo "      # and reintroduce post-deploy state, silently defeating rollback."
echo "      sudo rm -f $REMOTE_GATEWAY_DB_PATH-wal $REMOTE_GATEWAY_DB_PATH-shm &&"
echo "      sudo install -o macprovider -g macprovider -m 0600 \"\$LATEST\" $REMOTE_GATEWAY_DB_PATH &&"
echo "      sudo -u macprovider sqlite3 $REMOTE_GATEWAY_DB_PATH \"PRAGMA integrity_check;\" &&"
echo "      sudo systemctl start macprovider-gateway &&"
echo "      curl -s http://127.0.0.1:9443/healthz   # confirm OK + version reflects .prev"
echo "    '"
echo
echo "  Binary-only rollback (gateway.prev only) is SAFE only if no schema"
echo "  bump happened between the two deploys."
echo
echo "  C2 nginx worker tuning rollback, if needed:"
echo "    ssh $VPS_USER@$VPS_HOST '"
echo "      sudo test -f /etc/nginx/nginx.conf.bak.macprovider-c2 &&"
echo "      sudo install -o root -g root -m 0644 /etc/nginx/nginx.conf.bak.macprovider-c2 /etc/nginx/nginx.conf &&"
echo "      sudo nginx -t && sudo systemctl reload nginx"
echo "    '"
