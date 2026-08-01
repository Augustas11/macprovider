#!/usr/bin/env bash
# deploy-pearl-vps.sh — Stage 2 of the Phase 4 coordinator VPS deploy.
#
# Run this from the operator's Mac. It SSHes into Pearl VPS, installs the
# coordinator behind nginx + Let's Encrypt, and verifies the public
# endpoint. Idempotent — re-running won't break a working deploy.
#
# Prerequisites done in Stage 1:
#   - coordinator-linux-amd64 cross-compiled into dist/
#   - coordinator.yaml + service unit + nginx site config drafted in dist/
#   - DNS A record coordinator.streamvc.live -> 159.223.165.194 (DNS-only)
#
# Usage:
#   bash deploy-pearl-vps.sh
#
# Environment:
#   SSH_KEY          default: ~/.ssh/pearl_operator_ed25519
#   VPS_HOST         default: 159.223.165.194
#   VPS_USER         default: root
#   DOMAIN           default: coordinator.streamvc.live  (PRIMARY money-path hostname)
#   STATS_DOMAIN     default: stats.streamvc.live        (SPEC-017 first-class hostname)
#   EMAIL            default: augstar@gmail.com          (for Let's Encrypt)
#   STATS_REQUIRED   default: 0   set to 1 to fail-closed on STATS_DOMAIN cert
#                                 issuance failure (default WARN-only because
#                                 stats cert outages must not break the
#                                 primary deploy — issue #244 root cause).
#   FORCE_RESTART    default: 0   bypass connected-provider guard at step 1c/6c
#   STRICT_PROVENANCE default: 0  legacy compatibility knob. Exact release
#                    provenance is now always fatal on missing/mismatched
#                    /healthz version.
#                    Production deploys always require this checkout to be
#                    exactly one clean numeric release tag (vX.Y.Z); there is
#                    no non-release production deploy override.
#   CATALOG_CANARY_PROVIDER_ID required for production deploys. The provider
#                    must reconnect after restart and pass authenticated
#                    compatibility admission through /v1/pool/check before commit.
#   CATALOG_CANARY_AUTH_TOKEN required for production deploys. Use the
#                    coordinator operator key; service tokens are not
#                    accepted by operator-only deployment evidence.
#   CATALOG_CANARY_AUTH_TOKEN_FILE optional local root/operator-only file
#                    containing the coordinator operator key. Used only when
#                    CATALOG_CANARY_AUTH_TOKEN is unset.
#   CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_SERVICE optional macOS Keychain generic
#                    password service to read when both direct env and file
#                    token sources are unset. Default:
#                    macprovider.catalog-canary.operator-token.
#   CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_ACCOUNT optional Keychain account.
#                    Default: current USER.
#   CATALOG_CANARY_SSH_TARGET required for production deploys. SSH target for
#                    the operator-controlled canary Mac (for example user@host).
#   CATALOG_CANARY_SSH_KEY default: ~/.ssh/macprovider_canary_ed25519
#                    Key used only to read exact installed catalog bytes.
#   CATALOG_CANARY_INSTALL_DIR default: macprovider/catalog-release
#                    Catalog path relative to the canary user's home.
#   --dry-run-local  developer-only: run the old local-config C2 check using
#                    GATEWAY_CONFIG and exit before any SSH mutation.
#   GATEWAY_CONFIG   used only with --dry-run-local. Production deploys validate
#                    the gateway config installed on Pearl.
#   GATEWAY_REMOTE_CONFIG  installed gateway config path on Pearl.
#                    Default: /opt/macprovider/gateway.yaml.
#   C2C_COORD_OPERATOR_KEY_SHA256, C2C_COORD_SERVICE_TOKEN_SHA256,
#   C2C_GATEWAY_SERVICE_TOKEN_SHA256, C2C_GATEWAY_OPERATOR_KEY_SHA256
#                    required by --dry-run-local when either config uses
#                    env:NAME credentials. Compute each SHA-256 independently
#                    from its respective runtime EnvironmentFile; never pass
#                    raw credential values. Production computes these proofs
#                    on Pearl and returns only the digests.
#   SKIP_C2_CHECK    unsupported; C2 timer/header assertions are mandatory.
#   COORDINATOR_OVERLAY_CONFIG used only with --dry-run-local. Production
#                    deploys validate the Pearl base config merged with
#                    /etc/macprovider/coordinator.pearl-overlays.yaml. The
#                    deploy creates an empty overlay if Pearl does not have one
#                    so the installed systemd unit and C2 gate share one config
#                    input contract.
#   C2_TIMER_CONFIG_MIGRATION default: 0. Set to 1 for the reviewed #784
#                    field-scoped Pearl config migration that raises only
#                    routing.request_timeout_s and provider_http.timeout_s
#                    to the tracked monotonic values before C2 validation.
#   CONFIG_MODE      default: preserve-live
#                    preserve-live: validate and keep Pearl's live
#                    /opt/macprovider/coordinator.yaml; tracked dist/
#                    coordinator.yaml is not uploaded or installed.
#                    apply-tracked: install tracked dist/coordinator.yaml only
#                    when it already matches live. Broad ALLOW_CONFIG_DRIFT=1
#                    is rejected; use a reviewed config migration instead.
#   ALLOW_CONFIG_DRIFT deprecated: broad local-over-live config replacement is
#                    refused by this script.
#   SKIP_TCP_TUNING default: 0    skip Pearl TCP sysctl install/apply step
#   MODEL_HASH_LEGACY_UNTIL is read from /etc/macprovider/coordinator.env
#                    when the production config declares the bounded
#                    model-identity migration bridge. It must be a future
#                    RFC3339 instant. Remove the config field after the
#                    observed legacy-provider count reaches zero.
#
# Note: DOMAIN and STATS_DOMAIN are validated up-front (step 0) against
# DNS-name regex AND against the baked-in vhost-template hostnames. The
# templates `dist/nginx-{coordinator,stats}.streamvc.live.conf` hardcode
# `server_name` and `/etc/letsencrypt/live/...` paths, so an env-only
# override would issue a cert for one hostname while installing a vhost
# for another. Refused fail-closed.

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

# TLS state machine (classify/plan/message) lives in a sourced helper
# (lib/pearl_tls.sh) so it can be exercised by fixture tests without a
# real deploy. Issue #291.
#
# R1 SEC MED — resolve the PHYSICAL script path (walk symlinks) before
# sourcing. Plain `dirname "${BASH_SOURCE[0]}"` returns the symlink's
# parent, not the real target's parent, which would let a symlink
# invocation from an attacker-writable dir source a hostile helper.
# macOS bash 3.2 has no `readlink -f`, so we walk symlinks by hand.
_pearl_resolve_symlink() {
  # R2 SEC MED: use `pwd -P` so PARENT-directory symlinks also
  # resolve to the physical path. Plain `pwd` returns the logical
  # path, which would leave e.g. `/attacker/dist-link/deploy.sh` →
  # source `/attacker/dist-link/lib/pearl_tls.sh` — retargetable
  # between resolution and source.
  local src="$1" dir
  while [ -h "$src" ]; do
    dir="$(cd "$(dirname "$src")" && pwd -P)"
    src="$(readlink "$src")"
    case "$src" in
      /*) ;;             # absolute — use as-is
      *) src="$dir/$src" ;;
    esac
  done
  cd "$(dirname "$src")" && pwd -P
}
_PEARL_TLS_SCRIPT_DIR="$(_pearl_resolve_symlink "${BASH_SOURCE[0]}")"
# shellcheck source=lib/pearl_tls.sh
. "$_PEARL_TLS_SCRIPT_DIR/lib/pearl_tls.sh"

SSH_KEY="${SSH_KEY:-$HOME/.ssh/pearl_operator_ed25519}"
VPS_HOST="${VPS_HOST:-159.223.165.194}"
VPS_USER="${VPS_USER:-root}"
DOMAIN="${DOMAIN:-coordinator.streamvc.live}"
STATS_DOMAIN="${STATS_DOMAIN:-stats.streamvc.live}"
EMAIL="${EMAIL:-augstar@gmail.com}"
CATALOG_CANARY_PROVIDER_ID="${CATALOG_CANARY_PROVIDER_ID:-}"
CATALOG_CANARY_AUTH_TOKEN="${CATALOG_CANARY_AUTH_TOKEN:-}"
CATALOG_CANARY_AUTH_TOKEN_FILE="${CATALOG_CANARY_AUTH_TOKEN_FILE:-}"
CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_SERVICE="${CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_SERVICE:-macprovider.catalog-canary.operator-token}"
CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_ACCOUNT="${CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_ACCOUNT:-${USER:-}}"
CATALOG_CANARY_SSH_TARGET="${CATALOG_CANARY_SSH_TARGET:-}"
CATALOG_CANARY_SSH_KEY="${CATALOG_CANARY_SSH_KEY:-$HOME/.ssh/macprovider_canary_ed25519}"
CATALOG_CANARY_INSTALL_DIR="${CATALOG_CANARY_INSTALL_DIR:-macprovider/catalog-release}"
CONFIG_MODE="${CONFIG_MODE:-preserve-live}"
case "$CONFIG_MODE" in
  preserve-live|apply-tracked) ;;
  *)
    echo "aborting deploy: CONFIG_MODE must be preserve-live or apply-tracked, got: $CONFIG_MODE" >&2
    exit 2
    ;;
esac
C2_TIMER_CONFIG_MIGRATION="${C2_TIMER_CONFIG_MIGRATION:-0}"
case "$C2_TIMER_CONFIG_MIGRATION" in
  0|1) ;;
  *) echo "aborting deploy: C2_TIMER_CONFIG_MIGRATION must be 0 or 1, got: $C2_TIMER_CONFIG_MIGRATION" >&2; exit 5 ;;
esac
if [ "$C2_TIMER_CONFIG_MIGRATION" = "1" ] && [ "$CONFIG_MODE" != "preserve-live" ]; then
  echo "aborting deploy: C2_TIMER_CONFIG_MIGRATION=1 is only valid with CONFIG_MODE=preserve-live" >&2
  exit 5
fi
if [ "${ALLOW_CONFIG_DRIFT:-0}" = "1" ]; then
  echo "aborting deploy: ALLOW_CONFIG_DRIFT=1 is no longer a safe deploy bypass." >&2
  echo "  Use CONFIG_MODE=preserve-live for code/catalog deploys that keep Pearl's live config." >&2
  echo "  Use a reviewed field-scoped config migration for production config changes." >&2
  exit 2
fi

# Issue #244 R1 SEC HIGH-1 / CODE MED-2 / ARCH HIGH-2 — validate operator-
# overridable values up front so they cannot inject shell metacharacters
# or argument boundaries into the SSH command strings below, AND so an
# overridden $DOMAIN that doesn't match the baked-in vhost template's
# server_name is rejected fail-closed rather than installing a TLS vhost
# for the wrong hostname.
_validate_dns_name() {
  local v="$1" label="$2"
  if ! printf '%s' "$v" | grep -Eq '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$'; then
    echo "aborting deploy: $label is not a valid DNS name: '$v'" >&2
    exit 1
  fi
}
_validate_dns_name "$DOMAIN"        DOMAIN
_validate_dns_name "${STATS_DOMAIN:-stats.streamvc.live}" STATS_DOMAIN

_validate_catalog_canary_auth_token() {
  local value="$1" length
  length=${#value}
  [ "$length" -ge 32 ] && [ "$length" -le 512 ] || return 1
  case "$value" in
    *[!A-Za-z0-9._~-]*) return 1 ;;
  esac
}

_catalog_canary_auth_token_sha256() {
  printf '%s' "$1" | shasum -a 256 | awk '{print tolower($1)}'
}

_catalog_canary_auth_token_from_file() {
  local path="$1"
  python3 - "$path" <<'PY'
import os
import stat
import sys

path = sys.argv[1]
nofollow = getattr(os, "O_NOFOLLOW", 0)
try:
    fd = os.open(path, os.O_RDONLY | nofollow)
except FileNotFoundError:
    raise SystemExit(f"token file is missing: {path}")
except OSError as exc:
    raise SystemExit(f"token file is not safely readable: {path}: {exc}")
try:
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode):
        raise SystemExit(f"token file is not a regular file: {path}")
    if stat.S_IMODE(info.st_mode) & (stat.S_IRWXG | stat.S_IRWXO):
        raise SystemExit(f"token file must not be group/other accessible: {path}")
    raw = os.read(fd, 514)
finally:
    os.close(fd)
if len(raw) > 513:
    raise SystemExit("token file is too large")
try:
    value = raw.decode("utf-8")
except UnicodeDecodeError:
    raise SystemExit("token file must be UTF-8 text")
if value.endswith("\n"):
    value = value[:-1]
if value.endswith("\r"):
    value = value[:-1]
if "\n" in value or "\r" in value:
    raise SystemExit("token file must contain exactly one bearer token line")
print(value, end="")
PY
}

_load_catalog_canary_auth_token() {
  [ -z "$CATALOG_CANARY_AUTH_TOKEN" ] || return 0
  if [ -n "$CATALOG_CANARY_AUTH_TOKEN_FILE" ]; then
    CATALOG_CANARY_AUTH_TOKEN="$(_catalog_canary_auth_token_from_file "$CATALOG_CANARY_AUTH_TOKEN_FILE")" || {
      echo "aborting deploy: could not read CATALOG_CANARY_AUTH_TOKEN_FILE" >&2
      exit 1
    }
    echo "  loaded catalog canary bearer from CATALOG_CANARY_AUTH_TOKEN_FILE" >&2
    return 0
  fi
  if [ -n "$CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_SERVICE" ] &&
     [ -n "$CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_ACCOUNT" ] &&
     [ -x /usr/bin/security ]; then
    CATALOG_CANARY_AUTH_TOKEN="$(
      /usr/bin/security find-generic-password -w \
        -s "$CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_SERVICE" \
        -a "$CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_ACCOUNT" 2>/dev/null || true
    )"
    if [ -n "$CATALOG_CANARY_AUTH_TOKEN" ]; then
      echo "  loaded catalog canary bearer from macOS Keychain service=$CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_SERVICE account=$CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_ACCOUNT" >&2
    fi
  fi
}

_catalog_canary_auth_token_matches_operator_key() {
  local token="$1" operator_key_sha="$2" token_sha operator_sha_lc
  _validate_catalog_canary_auth_token "$token" || return 1
  case "$operator_key_sha" in
    ""|*[!0-9a-fA-F]*) return 1 ;;
  esac
  [ "${#operator_key_sha}" -eq 64 ] || return 1
  token_sha="$(_catalog_canary_auth_token_sha256 "$token")" || return 1
  operator_sha_lc="$(printf '%s' "$operator_key_sha" | tr 'A-F' 'a-f')"
  [ "$token_sha" = "$operator_sha_lc" ]
}

_run_with_deadline_alarm() {
  local timeout_s="$1"
  shift
  python3 -c '
import os
import signal
import sys

timeout_s = int(sys.argv[1])
if timeout_s < 1:
    raise SystemExit("deadline must be at least one second")
signal.alarm(timeout_s)
os.execvp(sys.argv[2], sys.argv[2:])
' "$timeout_s" "$@"
}

_parse_model_hash_legacy_until() {
  python3 -c '
import shlex
import sys

raw = sys.argv[1].strip()
if not raw:
    sys.exit(0)
try:
    values = shlex.split(raw, comments=False, posix=True)
except ValueError as exc:
    raise SystemExit(f"invalid MODEL_HASH_LEGACY_UNTIL quoting: {exc}")
if len(values) != 1:
    raise SystemExit("MODEL_HASH_LEGACY_UNTIL must be a single scalar value")
print(values[0], end="")
' "$1"
}

_coordinator_release_tag_version() {
  local module_dir="$1" repo_root candidates count dirty_state tag head rows tag_object peeled_count peeled_commit tag_type verify_output remote_url
  local release_tag_remote="origin"
  local release_tag_remote_url="https://github.com/Augustas11/macprovider.git"
  local release_tag_signer_line='Good "git" signature for augstar@gmail.com with ED25519 key SHA256:6DgoKNaOgF5c7NPHTAbNxJ2LT0uuj8U/3zObOOZjRiA'
  repo_root="$(git -C "$module_dir" rev-parse --show-toplevel)"
  dirty_state="$(git -C "$repo_root" status --porcelain)"
  if [ -n "$dirty_state" ]; then
    echo "aborting deploy: coordinator production deploy requires a clean release-tag checkout" >&2
    git -C "$repo_root" status --short >&2
    return 1
  fi
  candidates="$(git -C "$repo_root" tag --points-at HEAD | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true)"
  count="$(printf '%s\n' "$candidates" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
  case "$count" in
    1)
      tag="$candidates"
      ;;
    0)
      echo "aborting deploy: HEAD is not exactly a numeric release tag (vX.Y.Z)" >&2
      echo "  Deploy the signed coordinator/gateway release tag first; do not let git describe from main become production version authority." >&2
      return 1
      ;;
    *)
      echo "aborting deploy: HEAD has multiple numeric release tags:" >&2
      printf '%s\n' "$candidates" | sed 's/^/  - /' >&2
      return 1
      ;;
  esac
  tag_type="$(git -C "$repo_root" cat-file -t "$tag" 2>/dev/null || true)"
  if [ "$tag_type" != tag ]; then
    echo "aborting deploy: $tag is not an annotated signed release tag" >&2
    return 1
  fi
  if ! verify_output="$(git -C "$repo_root" verify-tag "$tag" 2>&1)"; then
    echo "aborting deploy: $tag does not verify as a trusted signed tag" >&2
    return 1
  fi
  if ! printf '%s\n' "$verify_output" | grep -qxF "$release_tag_signer_line"; then
    echo "aborting deploy: $tag was signed by an unauthorized release signer" >&2
    return 1
  fi
  remote_url="$(git -C "$repo_root" remote get-url "$release_tag_remote" 2>/dev/null || true)"
  case "$remote_url" in
    https://github.com/Augustas11/macprovider.git|git@github.com:Augustas11/macprovider.git|ssh://git@github.com/Augustas11/macprovider.git) ;;
    *)
      echo "aborting deploy: $release_tag_remote must point at the canonical Augustas11/macprovider GitHub repository" >&2
      return 1
      ;;
  esac
  head="$(git -C "$repo_root" rev-parse HEAD)"
  rows="$(git -C "$repo_root" ls-remote "$release_tag_remote_url" "refs/tags/$tag" "refs/tags/$tag^{}")"
  tag_object="$(printf '%s\n' "$rows" | awk -v ref="refs/tags/$tag" '$2 == ref { print $1 }')"
  peeled_commit="$(printf '%s\n' "$rows" | awk -v ref="refs/tags/$tag^{}" '$2 == ref { print $1 }')"
  peeled_count="$(printf '%s\n' "$peeled_commit" | awk 'NF { count++ } END { print count + 0 }')"
  if [ -z "$tag_object" ] || [ "$peeled_count" != 1 ] || [ "$peeled_commit" != "$head" ]; then
    echo "aborting deploy: $tag is not the protected remote annotated tag for HEAD on $release_tag_remote" >&2
    return 1
  fi
  printf '%s %s\n' "$tag" "$head"
}

_coordinator_verify_deployed_version() {
  local healthz_body="$1" expected_version="$2" deployed_version
  deployed_version=$(printf '%s' "$healthz_body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version', '?'))" 2>/dev/null || echo "?")
  if [ "$deployed_version" = "?" ]; then
    echo "  CRITICAL provenance MISSING: /healthz returned no \"version\" field" >&2
    echo "           This almost certainly means the deployed binary predates the" >&2
    echo "           M0-5 instrumentation (PR #18) and the rollback gate is bypassed." >&2
    echo "           Expected was: $expected_version" >&2
    echo "           See audits/2026-06-10/ROLLBACK_PROCEDURE.md to replace the live binary." >&2
    return 7
  elif [ "$deployed_version" = "$expected_version" ]; then
    echo "  provenance OK: deployed=$deployed_version | expected=$expected_version"
  else
    echo "  aborting deploy: provenance mismatch: deployed=$deployed_version | expected=$expected_version" >&2
    echo "       (deployed binary does not match the exact local release tag — rollback before commit)" >&2
    return 8
  fi
}

_tier2_migration_gate_remote_script() {
  cat <<'SH'
set -eu
python3 - <<'PY'
import errno
import os
import re
import stat
import sys

ROOT = "/opt/macprovider"
REQUIRED_UID = 0
NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
SAFE_RELEASE_TARGET = re.compile(r"^releases/([A-Za-z0-9][A-Za-z0-9._-]{0,191})$")


def die(message):
    raise SystemExit(message)


def validate_trusted_dir(fd, label):
    info = os.fstat(fd)
    if not stat.S_ISDIR(info.st_mode):
        die(f"unsafe Tier-2 migration path is not a directory: {label}")
    if info.st_uid not in (0, REQUIRED_UID) or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        die(f"unsafe Tier-2 migration directory ownership/mode: {label}")


def validate_regular_file(fd, label):
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode):
        die(f"unsafe Tier-2 migration path is not a regular file: {label}")
    if info.st_uid != REQUIRED_UID or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        die(f"unsafe Tier-2 migration file ownership/mode: {label}")
    if info.st_nlink != 1:
        die(f"unsafe Tier-2 migration hardlinked file: {label}")


def open_dir_at(parent_fd, name, label):
    try:
        fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW, dir_fd=parent_fd)
    except OSError as exc:
        die(f"cannot safely open Tier-2 migration directory {label}: {exc}")
    validate_trusted_dir(fd, label)
    return fd


def open_file_at(parent_fd, name, label, *, absent_ok=False):
    try:
        fd = os.open(name, os.O_RDONLY | NOFOLLOW, dir_fd=parent_fd)
    except FileNotFoundError:
        if absent_ok:
            return None
        die(f"missing Tier-2 migration file {label}")
    except OSError as exc:
        if exc.errno == errno.ELOOP:
            die(f"unsafe Tier-2 migration symlink: {label}")
        die(f"cannot safely open Tier-2 migration file {label}: {exc}")
    validate_regular_file(fd, label)
    return fd


def read_small_file_at(parent_fd, name, label):
    fd = open_file_at(parent_fd, name, label, absent_ok=True)
    if fd is None:
        return None
    with os.fdopen(fd, "rb", closefd=True) as handle:
        value = handle.read(4096)
        if handle.read(1):
            die(f"unsafe Tier-2 migration state file too large: {label}")
    try:
        return value.decode("ascii")
    except UnicodeDecodeError as exc:
        raise SystemExit(f"unsafe Tier-2 migration state file is not ASCII: {label}") from exc


def compare_fd(left_fd, right_fd):
    os.lseek(left_fd, 0, os.SEEK_SET)
    os.lseek(right_fd, 0, os.SEEK_SET)
    while True:
        left = os.read(left_fd, 1024 * 1024)
        right = os.read(right_fd, 1024 * 1024)
        if left != right:
            return False
        if not left:
            return True


slash_fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW)
validate_trusted_dir(slash_fd, "/")
root_fd = slash_fd
root_label = ""
for component in [part for part in ROOT.split("/") if part]:
    root_label = f"{root_label}/{component}"
    root_fd = open_dir_at(root_fd, component, root_label)

legacy_fd = open_file_at(root_fd, "tier2-catalog.json", f"{ROOT}/tier2-catalog.json", absent_ok=True)
if legacy_fd is None:
    sys.exit(0)

autotune_fd = open_dir_at(root_fd, "autotune", f"{ROOT}/autotune")

current_next_fd = open_file_at(autotune_fd, "current.next", f"{ROOT}/autotune/current.next", absent_ok=True)
if current_next_fd is not None:
    os.close(current_next_fd)
    die("unsafe transient autotune/current.next exists before deploy activation")
try:
    os.readlink("current.next", dir_fd=autotune_fd)
except FileNotFoundError:
    pass
except OSError as exc:
    if exc.errno != errno.ENOENT:
        die(f"unsafe transient autotune/current.next exists before deploy activation: {exc}")
else:
    die("unsafe transient autotune/current.next symlink exists before deploy activation")

previous_target = read_small_file_at(autotune_fd, ".previous-target", f"{ROOT}/autotune/.previous-target")
if previous_target is not None:
    if previous_target not in ("",) and SAFE_RELEASE_TARGET.fullmatch(previous_target) is None:
        die("unsafe autotune/.previous-target contents before Tier-2 migration")

try:
    current_target = os.readlink("current", dir_fd=autotune_fd)
except OSError as exc:
    die(f"legacy Tier-2 migration requires autotune/current to be a safe releases/* symlink: {exc}")
match = SAFE_RELEASE_TARGET.fullmatch(current_target)
if match is None:
    die("legacy Tier-2 migration requires autotune/current to be one safe releases/<content-addressed-id> symlink")

releases_fd = open_dir_at(autotune_fd, "releases", f"{ROOT}/autotune/releases")
release_name = match.group(1)
release_fd = open_dir_at(releases_fd, release_name, f"{ROOT}/autotune/releases/{release_name}")
current_fd = open_file_at(
    release_fd,
    "tier2-catalog.json",
    f"{ROOT}/autotune/releases/{release_name}/tier2-catalog.json",
)
if not compare_fd(legacy_fd, current_fd):
    die("legacy Tier-2 catalog bytes differ from active autotune/current release")
PY
SH
}

# R3 SEC MED — reuse the already-resolved physical dir from the
# symlink walker rather than recomputing from `$0` (which is the
# symlink path) + logical `pwd`. All later artifact reads,
# check-deploy-config, config uploads, and vhost templates hang
# off DIST_DIR, so any parent-symlink retargeting attack that
# survives helper sourcing would still land here.
DIST_DIR="$_PEARL_TLS_SCRIPT_DIR"
MODULE_DIR="$(cd "$DIST_DIR/.." && pwd -P)"
REPO_ROOT="$(git -C "$MODULE_DIR" rev-parse --show-toplevel)"

COORDINATOR_RELEASE_VERSION=""
COORDINATOR_RELEASE_COMMIT=""
if [ "$DRY_RUN_LOCAL" != "1" ]; then
  COORDINATOR_RELEASE_IDENTITY="$(_coordinator_release_tag_version "$MODULE_DIR")" || exit 2
  COORDINATOR_RELEASE_VERSION="${COORDINATOR_RELEASE_IDENTITY%% *}"
  COORDINATOR_RELEASE_COMMIT="${COORDINATOR_RELEASE_IDENTITY#* }"
  echo "  release tag OK: $COORDINATOR_RELEASE_VERSION @ $COORDINATOR_RELEASE_COMMIT"
  GH_HOST=github.com bash "$REPO_ROOT/scripts/verify-pearl-runtime-release.sh" \
    --tag "$COORDINATOR_RELEASE_VERSION" \
    --expected-commit "$COORDINATOR_RELEASE_COMMIT" \
    --repository "Augustas11/macprovider" \
    --remote "origin"
fi

PINNED_DEPLOY_INPUT_DIR=""
PINNED_DIST_DIR="$DIST_DIR"
PINNED_STATIC_FEEDS_DIR="$DIST_DIR/../../phase3-binary/dist/static"
PINNED_AUTOTUNE_DIR="$DIST_DIR/../../phase3-binary/catalog/autotune"
PINNED_SCRIPTS_DIR="$DIST_DIR/../../scripts"
if [ "$DRY_RUN_LOCAL" != "1" ]; then
  PINNED_DEPLOY_INPUT_DIR="$(umask 077 && mktemp -d -t macprovider-deploy-inputs.XXXXXXXX)" || {
    echo "aborting deploy: mktemp failed for pinned deploy inputs" >&2
    exit 2
  }
  trap 'rm -rf "${PINNED_DEPLOY_INPUT_DIR:-}"' EXIT HUP INT TERM
  git -C "$REPO_ROOT" archive --format=tar "$COORDINATOR_RELEASE_COMMIT" -- \
    phase4-coordinator/dist \
    phase3-binary/dist/static \
    phase3-binary/catalog/autotune \
    scripts/catalog-release.py \
    scripts/sign-catalog.go \
    | tar -xf - -C "$PINNED_DEPLOY_INPUT_DIR"
  PINNED_DIST_DIR="$PINNED_DEPLOY_INPUT_DIR/phase4-coordinator/dist"
  PINNED_STATIC_FEEDS_DIR="$PINNED_DEPLOY_INPUT_DIR/phase3-binary/dist/static"
  PINNED_AUTOTUNE_DIR="$PINNED_DEPLOY_INPUT_DIR/phase3-binary/catalog/autotune"
  PINNED_SCRIPTS_DIR="$PINNED_DEPLOY_INPUT_DIR/scripts"
fi

# Email validator — RFC-conformant pre-validation is overkill; we just
# need to reject metacharacters that would split a shell arg.
if ! printf '%s' "$EMAIL" | grep -Eq '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
  echo "aborting deploy: EMAIL is not a valid address: '$EMAIL'" >&2
  exit 1
fi
if [ "$DRY_RUN_LOCAL" != "1" ]; then
  _load_catalog_canary_auth_token
  if ! printf '%s' "$CATALOG_CANARY_PROVIDER_ID" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'; then
    echo "aborting deploy: CATALOG_CANARY_PROVIDER_ID is required and must be a safe provider ID" >&2
    echo "  Select a provider expected to reconnect after restart; deployment commits only after pool admission." >&2
    exit 1
  fi
  if ! _validate_catalog_canary_auth_token "$CATALOG_CANARY_AUTH_TOKEN"; then
    echo "aborting deploy: CATALOG_CANARY_AUTH_TOKEN is required and must be a safe 32-512 character bearer token" >&2
    echo "  Provide it via CATALOG_CANARY_AUTH_TOKEN, CATALOG_CANARY_AUTH_TOKEN_FILE, or macOS Keychain service=$CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_SERVICE account=$CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_ACCOUNT." >&2
    echo "  The deploy will later prove this secret matches Pearl's coordinator operator key by SHA-256; it never copies key material from Pearl." >&2
    exit 1
  fi
  if ! printf '%s' "$CATALOG_CANARY_SSH_TARGET" | grep -Eq '^([A-Za-z_][A-Za-z0-9._-]*@)?[A-Za-z0-9]([A-Za-z0-9.-]{0,252}[A-Za-z0-9])?$'; then
    echo "aborting deploy: CATALOG_CANARY_SSH_TARGET is required and must be a safe SSH target" >&2
    exit 1
  fi
  if [ ! -f "$CATALOG_CANARY_SSH_KEY" ] || [ ! -r "$CATALOG_CANARY_SSH_KEY" ]; then
    echo "aborting deploy: CATALOG_CANARY_SSH_KEY is not a readable regular file: $CATALOG_CANARY_SSH_KEY" >&2
    exit 1
  fi
  if ! printf '%s' "$CATALOG_CANARY_INSTALL_DIR" | grep -Eq '^[A-Za-z0-9._/-]+$' ||
     printf '%s' "/$CATALOG_CANARY_INSTALL_DIR/" | grep -Eq '/\.\.?/'; then
    echo "aborting deploy: CATALOG_CANARY_INSTALL_DIR must be a safe path without parent traversal" >&2
    exit 1
  fi
fi

# R1 ARCH HIGH-2 — the baked-in vhost templates hardcode
# server_name=coordinator.streamvc.live and the matching certbot live
# paths. Refuse if $DOMAIN was overridden to something else; otherwise
# we'd issue a cert for the override domain while installing a vhost
# with a non-matching server_name.
if [ "$DOMAIN" != "coordinator.streamvc.live" ]; then
  echo "aborting deploy: DOMAIN override ($DOMAIN) does not match the baked-in vhost template" >&2
  echo "  dist/nginx-coordinator.streamvc.live.conf has server_name=coordinator.streamvc.live hardcoded." >&2
  echo "  Edit the conf file in lockstep, or remove the DOMAIN env override." >&2
  exit 1
fi
if [ "${STATS_DOMAIN:-stats.streamvc.live}" != "stats.streamvc.live" ]; then
  echo "aborting deploy: STATS_DOMAIN override (${STATS_DOMAIN}) does not match the baked-in vhost template" >&2
  exit 1
fi

BINARY="$DIST_DIR/coordinator-linux-amd64"
CLI_BINARY="$DIST_DIR/coordinator-cli-linux-amd64"
STATS_INVENTORY_BINARY="$DIST_DIR/stats-inventory-sync-linux-amd64"
STATS_BILLING_MIRROR_BINARY="$DIST_DIR/stats-billing-mirror-linux-amd64"
STATS_HARDWARE_VERIFIER_BINARY="$DIST_DIR/stats-hardware-verifier-linux-amd64"
CONFIG="$PINNED_DIST_DIR/coordinator.yaml"
DEPLOY_CONFIG="$CONFIG"
SERVICE="$PINNED_DIST_DIR/macprovider-coordinator.service"
DEPLOY_RECOVER="$PINNED_DIST_DIR/coordinator-deploy-recover.sh"
DEPLOY_GUARD="$PINNED_DIST_DIR/systemd/macprovider-coordinator-deploy-guard.conf"
DEPLOY_RECOVERY_SERVICE="$PINNED_DIST_DIR/systemd/macprovider-coordinator-deploy-recovery.service"
DEPLOY_WATCHDOG_SERVICE="$PINNED_DIST_DIR/systemd/macprovider-coordinator-deploy-watchdog.service"
STATS_INVENTORY_SERVICE="$PINNED_DIST_DIR/stats-inventory-sync.service"
STATS_INVENTORY_TIMER="$PINNED_DIST_DIR/stats-inventory-sync.timer"
STATS_BILLING_MIRROR_SERVICE="$PINNED_DIST_DIR/stats-billing-mirror.service"
STATS_BILLING_MIRROR_TIMER="$PINNED_DIST_DIR/stats-billing-mirror.timer"
STATS_HARDWARE_VERIFIER_SERVICE="$PINNED_DIST_DIR/stats-hardware-verifier.service"
STATS_HARDWARE_VERIFIER_TIMER="$PINNED_DIST_DIR/stats-hardware-verifier.timer"
NGINX_SITE="$PINNED_DIST_DIR/nginx-coordinator.streamvc.live.conf"
TCP_SYSCTL="$PINNED_DIST_DIR/sysctl.d/99-macprovider-tcp.conf"
TCP_BBR_MODULES_LOAD="$PINNED_DIST_DIR/modules-load.d/tcp_bbr.conf"
# SPEC-017 v0.1.8 Step 4.B — additional nginx artifacts the
# coordinator vhost depends on:
#   - stats-shared.conf is the http-context snippet declaring the
#     `$public_rl_key` map, the per-endpoint `stats_*` zones, the
#     `stats_public` cache, and the `stats_redacted` log format.
#     Both the coordinator vhost and the stats vhost reference
#     these names; without the snippet installed first, `nginx -t`
#     fails (Step 4.B CODE r1 CRITICAL).
#   - nginx-stats.streamvc.live.conf is the standalone
#     `stats.streamvc.live` vhost.
# Both files MUST exist before this deploy proceeds; they are
# installed below alongside the coordinator vhost.
NGINX_STATS_SHARED="$PINNED_DIST_DIR/nginx-snippets/stats-shared.conf"
NGINX_STATS_SECHEADERS="$PINNED_DIST_DIR/nginx-snippets/stats-security-headers.conf"
NGINX_STATS_CORS_429="$PINNED_DIST_DIR/nginx-snippets/cors-429.conf"
NGINX_STATS_PROXY_PUBLIC="$PINNED_DIST_DIR/nginx-snippets/stats-proxy-public.conf"
NGINX_STATS_PROXY_PARTNER="$PINNED_DIST_DIR/nginx-snippets/stats-proxy-partner.conf"
NGINX_STATS_SITE="$PINNED_DIST_DIR/nginx-stats.streamvc.live.conf"
# SPEC-023 signed recommendation feeds served on the buyer mux at
# /v1/rate-card, /v1/demand-rank and /v1/autotune-candidates (+ .sig sidecars).
# Files live in phase3-binary/dist/static/ in the repo. Deploy installs
# them into /opt/macprovider/autotune/ for coordinator startup load.
STATIC_FEEDS_DIR="$PINNED_STATIC_FEEDS_DIR"
STATIC_DEMAND_JSON="$STATIC_FEEDS_DIR/demand-rank.json"
STATIC_DEMAND_SIG="$STATIC_FEEDS_DIR/demand-rank.json.sig"
STATIC_AUTOTUNE_JSON="$STATIC_FEEDS_DIR/autotune-candidates.json"
STATIC_AUTOTUNE_SIG="$STATIC_FEEDS_DIR/autotune-candidates.json.sig"
STATIC_RATE_CARD_JSON="$STATIC_FEEDS_DIR/rate-card.json"
STATIC_RATE_CARD_SIG="$STATIC_FEEDS_DIR/rate-card.json.sig"
AUTOTUNE_RELEASE_MANIFEST="$PINNED_AUTOTUNE_DIR/release.json"
AUTOTUNE_TRUSTED_KEYS="$PINNED_AUTOTUNE_DIR/trusted-keys.json"
AUTOTUNE_TIER2_JSON="$PINNED_AUTOTUNE_DIR/tier2-catalog.json"
AUTOTUNE_RELEASE_VERIFY="$PINNED_SCRIPTS_DIR/catalog-release.py"
AUTOTUNE_TIER2_VERIFIER="$PINNED_SCRIPTS_DIR/sign-catalog.go"
CATALOG_SOURCE="${CATALOG_SOURCE:-$AUTOTUNE_TIER2_JSON}"

python3 "$AUTOTUNE_RELEASE_VERIFY" verify
AUTOTUNE_RELEASE_ID="$(python3 - "$AUTOTUNE_RELEASE_MANIFEST" <<'PY'
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["release_id"])
PY
)"
AUTOTUNE_POLICY_VERSION="$(python3 - "$AUTOTUNE_RELEASE_MANIFEST" <<'PY'
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["policy_version"])
PY
)"
AUTOTUNE_CANDIDATE_SHA256="$(python3 - "$AUTOTUNE_RELEASE_MANIFEST" <<'PY'
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["feeds"]["autotune-candidates.json"]["sha256"])
PY
)"
AUTOTUNE_CANDIDATE_SIGNER_KEY_ID="$(python3 - "$AUTOTUNE_RELEASE_MANIFEST" <<'PY'
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["feeds"]["autotune-candidates.json"]["signer_key_id"])
PY
)"
AUTOTUNE_TIER2_SHA256="$(python3 - "$AUTOTUNE_RELEASE_MANIFEST" <<'PY'
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["feeds"]["tier2-catalog.json"]["sha256"])
PY
)"
AUTOTUNE_RELEASE_CONTENT_SHA256="$(python3 - \
  "$AUTOTUNE_RELEASE_MANIFEST" \
  "$AUTOTUNE_TRUSTED_KEYS" \
  "$AUTOTUNE_TIER2_JSON" \
  "$STATIC_AUTOTUNE_JSON" \
  "$STATIC_AUTOTUNE_SIG" \
  "$STATIC_DEMAND_JSON" \
  "$STATIC_DEMAND_SIG" \
  "$STATIC_RATE_CARD_JSON" \
  "$STATIC_RATE_CARD_SIG" <<'PY'
import hashlib
import pathlib
import sys

assets = (
    ("release.json", pathlib.Path(sys.argv[1])),
    ("trusted-keys.json", pathlib.Path(sys.argv[2])),
    ("tier2-catalog.json", pathlib.Path(sys.argv[3])),
    ("autotune-candidates.json", pathlib.Path(sys.argv[4])),
    ("autotune-candidates.json.sig", pathlib.Path(sys.argv[5])),
    ("demand-rank.json", pathlib.Path(sys.argv[6])),
    ("demand-rank.json.sig", pathlib.Path(sys.argv[7])),
    ("rate-card.json", pathlib.Path(sys.argv[8])),
    ("rate-card.json.sig", pathlib.Path(sys.argv[9])),
)
digest = hashlib.sha256()
for name, path in assets:
    asset_digest = hashlib.sha256(path.read_bytes()).hexdigest()
    digest.update(name.encode("utf-8"))
    digest.update(b"\0")
    digest.update(asset_digest.encode("ascii"))
    digest.update(b"\n")
print(digest.hexdigest())
PY
)"
if ! printf '%s' "$AUTOTUNE_RELEASE_ID" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'; then
  echo "invalid autotune release_id: $AUTOTUNE_RELEASE_ID" >&2
  exit 1
fi
AUTOTUNE_RELEASE_DIR_NAME="$AUTOTUNE_RELEASE_ID-$(printf '%s' "$AUTOTUNE_RELEASE_CONTENT_SHA256" | cut -c1-16)"

# coordinator-cli is required ALONGSIDE the daemon (SPEC-003 v0.8.3
# FR-C9.4 strict-reject path still requires `coordinator-cli
# revoke-token` for the used-token-persist-failure case; routine
# prune-tokens / list-tokens also belong on Pearl). If absent, the
# operator forgot to run build-linux.sh after the M2 update that
# extended it. Fail closed — do NOT silently deploy with a stale CLI.
for f in "$BINARY" "$CLI_BINARY" "$STATS_INVENTORY_BINARY" "$STATS_BILLING_MIRROR_BINARY" "$STATS_HARDWARE_VERIFIER_BINARY" \
         "$CONFIG" "$SERVICE" "$DEPLOY_RECOVER" "$DEPLOY_GUARD" "$DEPLOY_RECOVERY_SERVICE" "$DEPLOY_WATCHDOG_SERVICE" "$STATS_INVENTORY_SERVICE" "$STATS_INVENTORY_TIMER" \
         "$STATS_BILLING_MIRROR_SERVICE" "$STATS_BILLING_MIRROR_TIMER" \
         "$STATS_HARDWARE_VERIFIER_SERVICE" "$STATS_HARDWARE_VERIFIER_TIMER" "$NGINX_SITE" \
         "$NGINX_STATS_SHARED" "$NGINX_STATS_SECHEADERS" "$NGINX_STATS_SITE" \
         "$STATIC_DEMAND_JSON" "$STATIC_DEMAND_SIG" \
         "$STATIC_AUTOTUNE_JSON" "$STATIC_AUTOTUNE_SIG" \
         "$STATIC_RATE_CARD_JSON" "$STATIC_RATE_CARD_SIG" \
         "$AUTOTUNE_RELEASE_MANIFEST" "$AUTOTUNE_TRUSTED_KEYS" "$AUTOTUNE_TIER2_JSON" \
         "$AUTOTUNE_RELEASE_VERIFY" "$AUTOTUNE_TIER2_VERIFIER"; do
  [ -f "$f" ] || { echo "missing required file: $f" >&2; exit 1; }
done

# Issue #244 R1+R2 — replace the defensive sed (silently re-rewriting
# commented cert directives) with a pre-upload assertion that the dist
# vhosts ship with ACTIVE ssl_certificate + ssl_certificate_key
# directives AND server_name matching the deploy hostname. The dist
# confs are the single source of truth; the deploy script no longer
# "fixes up" the templates. If the assertion fails, the operator must
# edit the dist conf in place.
#
# R2 ARCH MEDIUM-2: also assert server_name + /etc/letsencrypt/live/<d>/
# paths in each template match the expected hostname, so an env-only
# DOMAIN override paired with a stale template can't issue a cert for
# one hostname and install a vhost for another.
_assert_vhost_template() {
  local f="$1" expected_host="$2"
  local host_esc="${expected_host//./\\.}"
  # R3 ARCH MED: anchor the active cert directives to the EXPECTED
  # hostname's letsencrypt path — not just any letsencrypt path. A
  # wrong active cert + commented expected cert would otherwise pass.
  if ! grep -Eq "^[[:space:]]*ssl_certificate[[:space:]]+/etc/letsencrypt/live/${host_esc}/fullchain\\.pem;" "$f"; then
    echo "aborting deploy: $f is missing an active 'ssl_certificate /etc/letsencrypt/live/$expected_host/fullchain.pem;' directive" >&2
    echo "  Edit the file to uncomment the cert path for this hostname; the deploy script no longer rewrites it." >&2
    exit 1
  fi
  if ! grep -Eq "^[[:space:]]*ssl_certificate_key[[:space:]]+/etc/letsencrypt/live/${host_esc}/privkey\\.pem;" "$f"; then
    echo "aborting deploy: $f is missing an active 'ssl_certificate_key /etc/letsencrypt/live/$expected_host/privkey.pem;' directive" >&2
    exit 1
  fi
  if ! grep -Eq "^[[:space:]]*server_name[[:space:]]+${host_esc}[[:space:]]*;" "$f"; then
    echo "aborting deploy: $f does not contain server_name $expected_host;" >&2
    exit 1
  fi
}
_assert_vhost_template "$NGINX_SITE"       "$DOMAIN"
_assert_vhost_template "$NGINX_STATS_SITE" "${STATS_DOMAIN:-stats.streamvc.live}"

SSH="ssh -i $SSH_KEY -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -p 22 $VPS_USER@$VPS_HOST"
SCP="scp -i $SSH_KEY -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -P 22"

log() { printf "\n[deploy] %s\n" "$*"; }

GATEWAY_REMOTE_CONFIG="${GATEWAY_REMOTE_CONFIG:-/opt/macprovider/gateway.yaml}"
case "$GATEWAY_REMOTE_CONFIG" in
  /*) ;;
  *) echo "aborting deploy: GATEWAY_REMOTE_CONFIG must be an absolute path" >&2; exit 5 ;;
esac
case "$GATEWAY_REMOTE_CONFIG" in
  *[!A-Za-z0-9._/-]*)
    echo "aborting deploy: GATEWAY_REMOTE_CONFIG contains unsupported characters: $GATEWAY_REMOTE_CONFIG" >&2
    exit 5
    ;;
esac

yaml_tier2_value() {
  yaml_block_value tier2 "$1"
}

# R5 ARCH MED: generic top-level-block value reader so callers can
# query e.g. `stats.enabled` in addition to `tier2.catalog_path`. Same
# scoping rule: read keys until the next top-level block.
yaml_block_value() {
  yaml_file_block_value "$DEPLOY_CONFIG" "$1" "$2"
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

# Local validation may need to read Pearl's live coordinator.yaml in
# CONFIG_MODE=preserve-live. Preserve env:NAME references because later gates
# prove those runtime variables on Pearl; mask inline secret material before it
# can land in a local temp file or logs.
redact_dsn() {
  sed -E 's#(postgres(ql)?://[^:/@[:space:]]+:)[^@[:space:]]+@#\1***@#g'
}
sanitize_live_config_for_local_validation() {
  awk '
    function indent_of(s) {
      match(s, /^[[:space:]]*/)
      return RLENGTH
    }
    function mask_scalar(s) {
      sub(/:.*/, ": <MASKED>", s)
      return s
    }
    function suppress_secret_continuation(s) {
      skip_secret_block = 1
      secret_block_indent = indent_of(s)
    }
    function mask_secret_scalar(s) {
      suppress_secret_continuation(s)
      return mask_scalar(s)
    }
    skip_secret_block && $0 ~ /^[[:space:]]*(#|$)/ { next }
    skip_secret_block {
      if (indent_of($0) > secret_block_indent) {
        next
      }
      skip_secret_block = 0
    }
    /^[^[:space:]#][^:]*:[[:space:]]*/ {
      in_auth = ($0 ~ /^auth:[[:space:]]*(#.*)?$/)
      in_referrals = ($0 ~ /^referrals:[[:space:]]*(#.*)?$/)
      in_secret_map = 0
    }
    in_auth && /^[[:space:]]*operator_keys:[[:space:]]*(#.*)?$/ {
      in_secret_map = 1
      secret_map_indent = indent_of($0)
      print
      next
    }
    in_referrals && /^[[:space:]]*hmac_keys:[[:space:]]*(#.*)?$/ {
      in_secret_map = 1
      secret_map_indent = indent_of($0)
      print
      next
    }
    in_secret_map && $0 !~ /^[[:space:]]*(#|$)/ {
      current_indent = indent_of($0)
      if (current_indent <= secret_map_indent) {
        in_secret_map = 0
      }
    }
    in_secret_map && /^[[:space:]]*[A-Za-z0-9_.-]+:[[:space:]]*/ {
      if ($0 ~ /^[[:space:]]*[A-Za-z0-9_.-]+:[[:space:]]*env:[A-Za-z_][A-Za-z0-9_]*([[:space:]]*(#.*)?)?$/) {
        suppress_secret_continuation($0)
        print
      } else {
        print mask_secret_scalar($0)
      }
      next
    }
    /^[[:space:]]*catalog_public_key:[[:space:]]*/ { print; next }
    /^[[:space:]]*[a-zA-Z0-9_]*(_key|_secret|_token|_dsn|dsn):[[:space:]]*/ {
      if ($0 ~ /^[[:space:]]*[a-zA-Z0-9_]*(_key|_secret|_token|_dsn|dsn):[[:space:]]*env:[A-Za-z_][A-Za-z0-9_]*([[:space:]]*(#.*)?)?$/) {
        suppress_secret_continuation($0)
        print
      } else {
        print mask_secret_scalar($0)
      }
      next
    }
    { print }
	  ' | redact_dsn
}
reject_redacted_install_candidate() {
  local path="$1" label="$2"
  if grep -Eq '(<MASKED>|postgres(ql)?://[^[:space:]]+:\*\*\*@)' "$path"; then
    echo "aborting deploy: refusing to install redacted validation data as $label" >&2
    echo "  C2 timer migration install candidates must come from raw 0600 live config copies, never sanitized validation copies." >&2
    exit 5
  fi
}
normalize_yaml() {
  # Mask any field whose name ends in _key / _secret / _token, then strip
  # pure-comment lines and blanks so the drift check focuses on semantic
  # differences (values + structure) rather than comment-placement noise.
  sanitize_live_config_for_local_validation \
    | sed -E 's/^([[:space:]]*[a-zA-Z0-9_]*(_key|_secret|_token)):[[:space:]]*.*$/\1: <MASKED>/' \
    | sed -E 's/[[:space:]]+#.*$//' \
    | grep -vE '^[[:space:]]*(#|$)'
}
print_config_drift_diff() {
  redact_dsn | sed 's/^/    /' >&2
}

# R5 ARCH M1 — early coherence check: if the operator set
# STATS_REQUIRED=1 but coordinator.yaml has stats.enabled=false (or
# unset), the deploy would restart the binary then exit 9 in step 8.
# Catch it BEFORE any SSH mutation.
assert_stats_required_matches_effective_config() {
  [ "${STATS_REQUIRED:-0}" = "1" ] || return 0
  _stats_enabled_pre="$(yaml_block_value stats enabled)"
  if [ "$_stats_enabled_pre" != "true" ]; then
    echo "aborting deploy: STATS_REQUIRED=1 but stats.enabled is not true in $DEPLOY_CONFIG ('$_stats_enabled_pre')." >&2
    echo "  Either set stats.enabled: true in coordinator.yaml, or drop STATS_REQUIRED=1." >&2
    exit 5
  fi
}

# Issue #582 (MEDIUM #6) — stats-inventory-sync restore-on-failure state.
# The old 2-column sidecar is quiesced (stop+disable) BEFORE migration 019
# widens hardware_verification_trust's PRIMARY KEY, so an abort that happens
# BEFORE the schema/binary actually become incompatible (before 019 is applied
# and before the new 3-column sidecar binary is installed) must RESTORE the
# sidecar to its pre-quiesce state rather than strand it stopped. These are
# ARMED before the quiesce (search "MEDIUM #6" at the quiesce step) and consumed
# by the EXIT trap through _sidecar_restore_on_abort.
#   SIDECAR_QUIESCE_ATTEMPTED — set to 1 immediately before the quiesce SSH.
#   Parity marker (/opt/macprovider/.coordinator-deploy-sidecar-parity-required,
#   touched just before the migration apply) records that the schema may now be
#   3-column; once set — or once the release transaction is ARMED at step 4, whose
#   own rollback deliberately leaves the sidecar stopped — the sidecar is LEFT
#   stopped (the old 2-column binary must never run against the migrated 3-column
#   schema). Restore reads the pre-quiesce enable/active state captured in
#   /opt/macprovider/.coordinator-deploy-sidecar-prior-state.
SIDECAR_QUIESCE_ATTEMPTED=0
_sidecar_restore_on_abort() {
  # $1 = deploy exit code. Best-effort + idempotent; never changes _final_rc.
  [ "${1:-0}" -ne 0 ] || return 0
  [ "${SIDECAR_QUIESCE_ATTEMPTED:-0}" = "1" ] || return 0
  # Once the release transaction is armed (step 4), the coordinator deploy
  # rollback owns sidecar restoration and DELIBERATELY leaves it stopped pending
  # schema/binary parity (see coordinator-deploy-recover.sh). Do not fight it.
  if [ "${COORDINATOR_DEPLOY_ARMED:-0}" = "1" ]; then
    echo "coordinator deploy: stats-inventory-sync deliberately left stopped (schema/binary parity required — the armed rollback leaves the old 2-column sidecar stopped against the migrated 3-column schema; see coordinator-deploy-recover runbook)" >&2
    return 0
  fi
  # Not armed: the new 3-column sidecar binary was never installed. If migration
  # 019 was (or may have been) applied inside the quiesced window the schema is
  # already 3-column, so the old 2-column sidecar MUST stay stopped.
  if $SSH 'test -f /opt/macprovider/.coordinator-deploy-sidecar-parity-required' 2>/dev/null; then
    echo "coordinator deploy: stats-inventory-sync deliberately left stopped (schema/binary parity required — migration 019 applied but the new 3-column sidecar binary was not installed; see coordinator-deploy-recover runbook)" >&2
    return 0
  fi
  # Safe early abort: schema/binary parity never crossed. Restore the sidecar to
  # the enable/active state captured before the quiesce.
  if $SSH '
    set -u
    exec 8>/opt/macprovider/.coordinator-deploy-operation.lock 2>/dev/null || exit 0
    flock -s 8 2>/dev/null || true
    _prior=/opt/macprovider/.coordinator-deploy-sidecar-prior-state
    [ -f "$_prior" ] || exit 0
    timer_enabled=; timer_active=; service_enabled=; parity_required=
    . "$_prior"
    case "$parity_required" in
      present)
        touch /opt/macprovider/.coordinator-deploy-sidecar-parity-required
        systemctl disable --now stats-inventory-sync.timer >/dev/null 2>&1 || exit 1
        systemctl stop stats-inventory-sync.service >/dev/null 2>&1 || exit 1
        rm -f "$_prior"
        exit 0
        ;;
      absent) ;;
      *) exit 1 ;;
    esac
    [ "$service_enabled" = enabled ] && systemctl enable stats-inventory-sync.service >/dev/null 2>&1 || true
    [ "$timer_enabled" = enabled ] && systemctl enable stats-inventory-sync.timer >/dev/null 2>&1 || true
    [ "$timer_active" = active ] && systemctl start stats-inventory-sync.timer >/dev/null 2>&1 || true
    rm -f "$_prior"
  '; then
    echo "coordinator deploy: stats-inventory-sync restored to its pre-deploy state (safe early abort — schema/binary parity never crossed)" >&2
  else
    echo "coordinator deploy: WARNING could not restore stats-inventory-sync after early abort; verify its enabled/active state manually" >&2
  fi
}

# Issue #244 R6 (CODE+SEC+ARCH convergent MED) — register the EXIT
# cleanup trap UNCONDITIONALLY, before any temp resource is created.
# Earlier the trap was inside the `if [ -n "$CATALOG_REMOTE_PATH" ]`
# branch, so a deploy with catalog disabled that failed mid-flight
# could leave the remote $DEPLOY_TMP and local TMP_CATALOG_PUBKEY
# behind. Both variables are guarded with `:-` so the trap is a
# no-op when they are unset.
trap '
  _deploy_rc=$?
  _final_rc=$_deploy_rc
  rm -f "${TMP_CATALOG_PUBKEY:-}"
  rm -f "${TMP_CATALOG_PINNED:-}"
  rm -f "${CATALOG_SMOKE_TMP:-}"
  rm -f "${LIVE_COORDINATOR_CONFIG_RAW_TMP:-}"
  rm -f "${LIVE_COORDINATOR_CONFIG_TMP:-}"
  rm -f "${COORDINATOR_OVERLAY_CONFIG_RAW_TMP:-}"
  rm -f "${COORDINATOR_OVERLAY_CONFIG_TMP:-}"
  rm -f "${DEPLOY_EFFECTIVE_CONFIG_TMP:-}"
  rm -f "${C2_TIMER_MIGRATED_CONFIG_TMP:-}"
  rm -f "${C2_TIMER_MIGRATED_CONFIG_VALIDATION_TMP:-}"
  rm -f "${C2_TIMER_MIGRATED_OVERLAY_TMP:-}"
  rm -f "${C2_TIMER_MIGRATED_OVERLAY_VALIDATION_TMP:-}"
  rm -f "${RATE_CARD_MIGRATED_CONFIG_TMP:-}"
  rm -f "${RATE_CARD_MIGRATED_CONFIG_VALIDATION_TMP:-}"
  rm -f "${RATE_CARD_MIGRATED_OVERLAY_TMP:-}"
  rm -f "${RATE_CARD_MIGRATED_OVERLAY_VALIDATION_TMP:-}"
  rm -f "${GATEWAY_REMOTE_CONFIG_TMP:-}"
  rm -f "${DEPLOY_INPUT_MANIFEST_TMP:-}"
  rm -f "${RECOVERY_INPUT_MANIFEST_TMP:-}"
  rm -f "${TCP_INPUT_MANIFEST_TMP:-}"
  rm -rf "${PINNED_DEPLOY_INPUT_DIR:-}"
  rm -rf "${STATIC_SMOKE_DIR:-}"
  if [ -n "${DEPLOY_TMP:-}" ]; then
    $SSH "rm -rf $DEPLOY_TMP" 2>/dev/null || true
  fi
  if [ -n "${RECOVERY_DEPLOY_TMP:-}" ]; then
    $SSH "rm -rf $RECOVERY_DEPLOY_TMP" 2>/dev/null || true
  fi
  if [ "${DEPLOY_LOCK_HELD:-0}" = "1" ]; then
    touch "${DEPLOY_LOCK_RELEASE_SENTINEL:-}"
    exec 9>&-
    _lock_rc=0
    wait "${DEPLOY_LOCK_PID:-}" || _lock_rc=$?
    if [ "$_deploy_rc" -ne 0 ] && [ "${COORDINATOR_DEPLOY_ARMED:-0}" = "1" ]; then
      _recovery_rc=0
      $SSH '\''
        _wait=0
        while [ "$(systemctl show -p ActiveState --value macprovider-coordinator-deploy-watchdog.service 2>/dev/null || true)" = activating ]; do
          _wait=$((_wait + 1))
          [ "$_wait" -lt 600 ] || exit 1
          sleep 0.25
        done
        ! systemctl is-failed --quiet macprovider-coordinator-deploy-watchdog.service
        test ! -d /opt/macprovider/.coordinator-deploy-rollback
      '\'' || _recovery_rc=$?
      if [ "$_lock_rc" -eq 0 ] && [ "$_recovery_rc" -eq 0 ]; then
        echo "coordinator deploy rollback completed" >&2
      else
        cat "${DEPLOY_LOCK_STATUS:-/dev/null}" >&2 2>/dev/null || true
        echo "CRITICAL: coordinator deploy rollback failed; snapshot preserved at /opt/macprovider/.coordinator-deploy-rollback" >&2
        _final_rc=70
      fi
    fi
  fi
  _sidecar_restore_on_abort "$_deploy_rc"
  rm -rf "${DEPLOY_LOCK_DIR:-}"
  exit "$_final_rc"
' EXIT
trap 'exit 71' HUP INT TERM

if [ "$DRY_RUN_LOCAL" != "1" ]; then
# Acquire the Pearl lease before any live config read. The remote holder owns
# flock until the controller closes its FIFO. A remote systemd watchdog waits
# behind this lease and a per-command operation lock, so controller loss cannot
# race rollback against a still-running mutation SSH session.
DEPLOY_LOCK_DIR=$(umask 077 && mktemp -d -t macprovider-deploy-lock.XXXXXXXX)
DEPLOY_LOCK_FIFO="$DEPLOY_LOCK_DIR/stdin"
DEPLOY_LOCK_STATUS="$DEPLOY_LOCK_DIR/status"
DEPLOY_LOCK_WATCHDOG_ARMED="$DEPLOY_LOCK_DIR/watchdog-armed"
DEPLOY_LOCK_RELEASE_SENTINEL="$DEPLOY_LOCK_DIR/release-requested"
DEPLOY_CONTROLLER_PID=$$
mkfifo -m 600 "$DEPLOY_LOCK_FIFO"
touch "$DEPLOY_LOCK_WATCHDOG_ARMED"
(
  set +e
  $SSH "command -v flock >/dev/null 2>&1 || { echo 'Pearl is missing flock' >&2; exit 127; }
python3 -c '
import os, stat

nofollow = getattr(os, \"O_NOFOLLOW\", 0)
directory_flags = os.O_RDONLY | os.O_DIRECTORY | nofollow
opt_fd = os.open(\"/opt\", directory_flags)
root_fd = None
global_lock_fd = None
try:
    opt_info = os.fstat(opt_fd)
    if opt_info.st_uid != 0 or opt_info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise SystemExit(\"unsafe /opt ownership or permissions\")
    try:
        os.mkdir(\"macprovider\", 0o700, dir_fd=opt_fd)
    except FileExistsError:
        pass
    root_fd = os.open(\"macprovider\", directory_flags, dir_fd=opt_fd)
    root_info = os.fstat(root_fd)
    if root_info.st_uid != 0 or root_info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise SystemExit(\"unsafe /opt/macprovider ownership or permissions\")
    for name in (\".coordinator-deploy.lock\", \".coordinator-deploy-operation.lock\"):
        try:
            fd = os.open(name, os.O_RDWR | os.O_CREAT | os.O_EXCL | nofollow, 0o600, dir_fd=root_fd)
        except FileExistsError:
            fd = os.open(name, os.O_RDWR | nofollow, dir_fd=root_fd)
        try:
            info = os.fstat(fd)
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_uid != 0
                or info.st_gid != 0
                or stat.S_IMODE(info.st_mode) != 0o600
                or info.st_nlink != 1
            ):
                raise SystemExit(\"unsafe coordinator deploy lock: \" + name)
        finally:
            os.close(fd)
    global_lock_fd = os.open(
        \"/run/lock/macprovider-pearl-updater.lock\",
        os.O_RDWR | os.O_CREAT | nofollow,
        0o600,
    )
    global_info = os.fstat(global_lock_fd)
    if (
        not stat.S_ISREG(global_info.st_mode)
        or global_info.st_uid != 0
        or global_info.st_gid != 0
        or stat.S_IMODE(global_info.st_mode) != 0o600
        or global_info.st_nlink != 1
    ):
        raise SystemExit(\"unsafe global Pearl deployment lock\")
finally:
    if global_lock_fd is not None:
        os.close(global_lock_fd)
    if root_fd is not None:
        os.close(root_fd)
    os.close(opt_fd)
' || exit \$?
flock -n /run/lock/macprovider-pearl-updater.lock flock -n /opt/macprovider/.coordinator-deploy.lock sh -c 'printf \"%s\\n\" LOCKED; cat >/dev/null'"
  _holder_rc=$?
  if [ -f "$DEPLOY_LOCK_WATCHDOG_ARMED" ] && [ ! -f "$DEPLOY_LOCK_RELEASE_SENTINEL" ]; then
    kill -TERM "$DEPLOY_CONTROLLER_PID" 2>/dev/null || true
  fi
  exit "$_holder_rc"
) <"$DEPLOY_LOCK_FIFO" >"$DEPLOY_LOCK_STATUS" 2>&1 &
DEPLOY_LOCK_PID=$!
exec 9>"$DEPLOY_LOCK_FIFO"
DEPLOY_LOCK_HELD=1
_lock_wait=0
while ! grep -qx LOCKED "$DEPLOY_LOCK_STATUS" 2>/dev/null; do
  if ! kill -0 "$DEPLOY_LOCK_PID" 2>/dev/null; then
    cat "$DEPLOY_LOCK_STATUS" >&2 || true
    echo "aborting deploy: another coordinator deploy holds the Pearl lock" >&2
    exit 11
  fi
  _lock_wait=$((_lock_wait + 1))
  if [ "$_lock_wait" -ge 100 ]; then
    echo "aborting deploy: timed out acquiring the Pearl deploy lock" >&2
    exit 11
  fi
  sleep 0.1
done
if ! kill -0 "$DEPLOY_LOCK_PID" 2>/dev/null; then
  cat "$DEPLOY_LOCK_STATUS" >&2 || true
  echo "aborting deploy: Pearl deploy lock was lost after acquisition" >&2
  exit 11
fi
if $SSH 'test -e /var/lib/macprovider-pearl-updater/tier2-enforcement-transaction.json'; then
  echo "aborting deploy: a Tier-2 enforcement transaction is active" >&2
  exit 12
fi

# Recover the prior complete snapshot before using any live state as input to
# config drift checks or a new rollback baseline.
if $SSH 'test -d /opt/macprovider/.coordinator-deploy-rollback'; then
  log "step 0a/9: recover interrupted coordinator deploy"
  if ! $SSH 'test -x /opt/macprovider/coordinator-deploy-recover'; then
    echo "aborting deploy: rollback snapshot exists but recovery helper is missing" >&2
    echo "  Preserve /opt/macprovider/.coordinator-deploy-rollback and recover it manually." >&2
    exit 70
  fi
  $SSH /opt/macprovider/coordinator-deploy-recover --recover-under-global || {
    echo "aborting deploy: interrupted coordinator release could not be recovered; snapshot preserved" >&2
    exit 70
  }
fi
fi

if [ "$DRY_RUN_LOCAL" != "1" ]; then
  log "step 0b/9: verify legacy Tier-2 migration bridge"
  $SSH "$(_tier2_migration_gate_remote_script)" || {
    echo "aborting deploy: legacy /opt/macprovider/tier2-catalog.json does not match active autotune/current release" >&2
    exit 5
  }
fi

log "step 0/9: pre-deploy config-drift + C2 cross-check"
# Fail closed before touching the VPS if the config to be deployed has a
# placeholder operator_key, an unsafe threshold, etc. (see check-deploy-config.sh).
# Catches the sanitized-config hazard that would otherwise break prod auth.
#
# M1-6 / DEVE-4: pass BOTH configs so the C2 timer cross-check runs.
# Previously only $CONFIG was passed, so check-deploy-config.sh silently
# skipped C2 on every standard coordinator deploy — the past-incident
# guard was effectively disabled.
# M1-6 follow-up: production deploy reads the gateway config installed on
# Pearl, not a local sample or developer config. Local validation is available
# only through --dry-run-local and exits before any SSH mutation.
CHECK_SCRIPT="$DIST_DIR/check-deploy-config.sh"
C2C_PROOF_SCRIPT="$DIST_DIR/lib/c2c_runtime_proof.py"
MERGE_OVERLAY_SCRIPT="$DIST_DIR/merge-yaml-overlay.py"
C2_TIMER_MIGRATION_SCRIPT="$DIST_DIR/c2-timer-config-migration.py"
RATE_CARD_CONFIG_MIGRATION_SCRIPT="$DIST_DIR/autotune-rate-card-config-migration.py"
if [ ! -x "$CHECK_SCRIPT" ]; then
  echo "aborting deploy: check-deploy-config.sh missing or not executable: $CHECK_SCRIPT" >&2
  exit 5
fi
if [ ! -r "$C2C_PROOF_SCRIPT" ]; then
  echo "aborting deploy: runtime credential proof helper missing or unreadable: $C2C_PROOF_SCRIPT" >&2
  exit 5
fi
if [ ! -x "$MERGE_OVERLAY_SCRIPT" ]; then
  echo "aborting deploy: YAML overlay merge helper missing or not executable: $MERGE_OVERLAY_SCRIPT" >&2
  exit 5
fi
if [ "$C2_TIMER_CONFIG_MIGRATION" = "1" ] && [ ! -x "$C2_TIMER_MIGRATION_SCRIPT" ]; then
  echo "aborting deploy: C2 timer migration helper missing or not executable: $C2_TIMER_MIGRATION_SCRIPT" >&2
  exit 5
fi
if [ ! -x "$RATE_CARD_CONFIG_MIGRATION_SCRIPT" ]; then
  echo "aborting deploy: rate-card config migration helper missing or not executable: $RATE_CARD_CONFIG_MIGRATION_SCRIPT" >&2
  exit 5
fi
if [ "$DRY_RUN_LOCAL" = "1" ]; then
  echo "  --dry-run-local set — validating local GATEWAY_CONFIG and exiting before deploy" >&2
  GATEWAY_CONFIG_DEFAULT="$DIST_DIR/../../phase5-gateway/dist/gateway.yaml"
  GATEWAY_CONFIG="${GATEWAY_CONFIG:-$GATEWAY_CONFIG_DEFAULT}"
  if [ ! -f "$GATEWAY_CONFIG" ]; then
    echo "aborting deploy dry-run: local gateway config not found for C2 cross-check ($GATEWAY_CONFIG)." >&2
    echo "  Provide GATEWAY_CONFIG=<path-to-real-gateway.yaml>." >&2
    exit 5
  fi
  CHECK_ARGS=("$CONFIG" "$GATEWAY_CONFIG")
  if [ -n "${COORDINATOR_OVERLAY_CONFIG:-}" ]; then
    if [ ! -f "$COORDINATOR_OVERLAY_CONFIG" ]; then
      echo "aborting deploy dry-run: local coordinator overlay not found ($COORDINATOR_OVERLAY_CONFIG)." >&2
      exit 5
    fi
    CHECK_ARGS+=("$COORDINATOR_OVERLAY_CONFIG")
  fi
  C2C_COORD_OPERATOR_KEY_SHA256="${C2C_COORD_OPERATOR_KEY_SHA256:-}" \
  C2C_COORD_SERVICE_TOKEN_SHA256="${C2C_COORD_SERVICE_TOKEN_SHA256:-}" \
  C2C_GATEWAY_SERVICE_TOKEN_SHA256="${C2C_GATEWAY_SERVICE_TOKEN_SHA256:-}" \
  C2C_GATEWAY_OPERATOR_KEY_SHA256="${C2C_GATEWAY_OPERATOR_KEY_SHA256:-}" \
    bash "$CHECK_SCRIPT" "${CHECK_ARGS[@]}" || {
    echo "aborting deploy dry-run: config-drift check failed" >&2; exit 5;
  }
  echo "  local dry-run C2 check passed"
  exit 0
else
  if [ "$CONFIG_MODE" = "preserve-live" ]; then
    LIVE_COORDINATOR_CONFIG_RAW_TMP="$(umask 077 && mktemp -t macprovider-coordinator-live-config-raw.XXXXXXXX)" || {
      echo "aborting deploy: mktemp failed for raw installed coordinator config copy" >&2; exit 5;
    }
    LIVE_COORDINATOR_CONFIG_TMP="$(umask 077 && mktemp -t macprovider-coordinator-live-config.XXXXXXXX)" || {
      echo "aborting deploy: mktemp failed for installed coordinator config copy" >&2; exit 5;
    }
    LIVE_COORDINATOR_CONFIG_REMOTE_SHA="$($SSH "sha256sum /opt/macprovider/coordinator.yaml | awk '{print \$1}'")" || {
      echo "aborting deploy: could not hash installed coordinator config on Pearl" >&2
      exit 5
    }
    $SSH 'test -f /opt/macprovider/coordinator.yaml || { echo "missing installed coordinator config: /opt/macprovider/coordinator.yaml" >&2; exit 1; }; cat /opt/macprovider/coordinator.yaml' \
      > "$LIVE_COORDINATOR_CONFIG_RAW_TMP" || {
      echo "aborting deploy: could not read installed coordinator config from Pearl" >&2
      exit 5
    }
    sanitize_live_config_for_local_validation < "$LIVE_COORDINATOR_CONFIG_RAW_TMP" > "$LIVE_COORDINATOR_CONFIG_TMP" || {
      echo "aborting deploy: could not sanitize installed coordinator config for local validation" >&2
      exit 5
    }
    LIVE_COORDINATOR_CONFIG_SHA=$(shasum -a 256 "$LIVE_COORDINATOR_CONFIG_TMP" | awk '{print $1}')
    DEPLOY_CONFIG="$LIVE_COORDINATOR_CONFIG_TMP"
    echo "  CONFIG_MODE=preserve-live — validating Pearl live coordinator config"
    echo "    remote sha256=$LIVE_COORDINATOR_CONFIG_REMOTE_SHA"
    echo "    sanitized validation copy sha256=$LIVE_COORDINATOR_CONFIG_SHA"
  else
    DEPLOY_CONFIG="$CONFIG"
    echo "  CONFIG_MODE=apply-tracked — validating tracked coordinator config: $CONFIG"
  fi
  if [ "$C2_TIMER_CONFIG_MIGRATION" = "1" ]; then
    C2_TIMER_MIGRATED_CONFIG_TMP="$(umask 077 && mktemp -t macprovider-coordinator-c2-timer-config.XXXXXXXX)" || {
      echo "aborting deploy: mktemp failed for C2 timer migrated coordinator config" >&2; exit 5;
    }
    C2_TIMER_MIGRATED_CONFIG_VALIDATION_TMP="$(umask 077 && mktemp -t macprovider-coordinator-c2-timer-config-validation.XXXXXXXX)" || {
      echo "aborting deploy: mktemp failed for sanitized C2 timer migrated coordinator config" >&2; exit 5;
    }
    python3 "$C2_TIMER_MIGRATION_SCRIPT" "${LIVE_COORDINATOR_CONFIG_RAW_TMP:-$DEPLOY_CONFIG}" "$CONFIG" > "$C2_TIMER_MIGRATED_CONFIG_TMP" || {
      echo "aborting deploy: could not render reviewed C2 timer config migration" >&2
      exit 5
    }
    reject_redacted_install_candidate "$C2_TIMER_MIGRATED_CONFIG_TMP" "coordinator.yaml"
    sanitize_live_config_for_local_validation < "$C2_TIMER_MIGRATED_CONFIG_TMP" > "$C2_TIMER_MIGRATED_CONFIG_VALIDATION_TMP" || {
      echo "aborting deploy: could not sanitize C2 timer migrated coordinator config for local validation" >&2
      exit 5
    }
    DEPLOY_CONFIG="$C2_TIMER_MIGRATED_CONFIG_VALIDATION_TMP"
    echo "  C2_TIMER_CONFIG_MIGRATION=1 — validating reviewed field-scoped timer raise"
  fi
  RATE_CARD_CONFIG_MIGRATION_ACTIVE=0
  RATE_CARD_MIGRATION_INPUT="${C2_TIMER_MIGRATED_CONFIG_TMP:-${LIVE_COORDINATOR_CONFIG_RAW_TMP:-$DEPLOY_CONFIG}}"
  RATE_CARD_MIGRATED_CONFIG_TMP="$(umask 077 && mktemp -t macprovider-coordinator-rate-card-config.XXXXXXXX)" || {
    echo "aborting deploy: mktemp failed for rate-card migrated coordinator config" >&2; exit 5;
  }
  RATE_CARD_MIGRATED_CONFIG_VALIDATION_TMP="$(umask 077 && mktemp -t macprovider-coordinator-rate-card-config-validation.XXXXXXXX)" || {
    echo "aborting deploy: mktemp failed for sanitized rate-card migrated coordinator config" >&2; exit 5;
  }
  python3 "$RATE_CARD_CONFIG_MIGRATION_SCRIPT" "$RATE_CARD_MIGRATION_INPUT" "$CONFIG" > "$RATE_CARD_MIGRATED_CONFIG_TMP" || {
    echo "aborting deploy: could not render reviewed rate-card feed config migration" >&2
    exit 5
  }
  reject_redacted_install_candidate "$RATE_CARD_MIGRATED_CONFIG_TMP" "coordinator.yaml"
  if ! cmp -s "$RATE_CARD_MIGRATION_INPUT" "$RATE_CARD_MIGRATED_CONFIG_TMP"; then
    RATE_CARD_CONFIG_MIGRATION_ACTIVE=1
    sanitize_live_config_for_local_validation < "$RATE_CARD_MIGRATED_CONFIG_TMP" > "$RATE_CARD_MIGRATED_CONFIG_VALIDATION_TMP" || {
      echo "aborting deploy: could not sanitize rate-card migrated coordinator config for local validation" >&2
      exit 5
    }
    DEPLOY_CONFIG="$RATE_CARD_MIGRATED_CONFIG_VALIDATION_TMP"
    echo "  B10 rate-card migration — adding release-bound autotune.rate_card_* paths"
  fi
  COORDINATOR_REMOTE_OVERLAY="/etc/macprovider/coordinator.pearl-overlays.yaml"
  C2_TIMER_MIGRATION_OVERLAY_ACTIVE=0
  RATE_CARD_MIGRATION_OVERLAY_ACTIVE=0
  COORDINATOR_EFFECTIVE_OVERLAY_TMP=""
  if $SSH "test -f '$COORDINATOR_REMOTE_OVERLAY'"; then
    COORDINATOR_OVERLAY_CONFIG_RAW_TMP="$(umask 077 && mktemp -t macprovider-coordinator-live-overlay-raw.XXXXXXXX)" || {
      echo "aborting deploy: mktemp failed for raw installed coordinator overlay copy" >&2; exit 5;
    }
    COORDINATOR_OVERLAY_CONFIG_TMP="$(umask 077 && mktemp -t macprovider-coordinator-live-overlay.XXXXXXXX)" || {
      echo "aborting deploy: mktemp failed for installed coordinator overlay copy" >&2; exit 5;
    }
    $SSH "cat '$COORDINATOR_REMOTE_OVERLAY'" > "$COORDINATOR_OVERLAY_CONFIG_RAW_TMP" || {
      echo "aborting deploy: could not read installed coordinator overlay from Pearl: $COORDINATOR_REMOTE_OVERLAY" >&2
      exit 5
    }
    sanitize_live_config_for_local_validation < "$COORDINATOR_OVERLAY_CONFIG_RAW_TMP" > "$COORDINATOR_OVERLAY_CONFIG_TMP" || {
      echo "aborting deploy: could not sanitize installed coordinator overlay for local validation" >&2
      exit 5
    }
    COORDINATOR_OVERLAY_CONFIG_SHA=$(shasum -a 256 "$COORDINATOR_OVERLAY_CONFIG_TMP" | awk '{print $1}')
    echo "  validating effective coordinator config with Pearl overlay: $COORDINATOR_REMOTE_OVERLAY sha256=$COORDINATOR_OVERLAY_CONFIG_SHA"
    COORDINATOR_EFFECTIVE_OVERLAY_TMP="$COORDINATOR_OVERLAY_CONFIG_TMP"
    if [ "$C2_TIMER_CONFIG_MIGRATION" = "1" ]; then
      C2_TIMER_MIGRATED_OVERLAY_TMP="$(umask 077 && mktemp -t macprovider-coordinator-c2-timer-overlay.XXXXXXXX)" || {
        echo "aborting deploy: mktemp failed for C2 timer migrated coordinator overlay" >&2; exit 5;
      }
      C2_TIMER_MIGRATED_OVERLAY_VALIDATION_TMP="$(umask 077 && mktemp -t macprovider-coordinator-c2-timer-overlay-validation.XXXXXXXX)" || {
        echo "aborting deploy: mktemp failed for sanitized C2 timer migrated coordinator overlay" >&2; exit 5;
      }
      python3 "$C2_TIMER_MIGRATION_SCRIPT" --only-existing "$COORDINATOR_OVERLAY_CONFIG_RAW_TMP" "$CONFIG" > "$C2_TIMER_MIGRATED_OVERLAY_TMP" || {
        echo "aborting deploy: could not render reviewed C2 timer overlay migration" >&2
        exit 5
      }
      reject_redacted_install_candidate "$C2_TIMER_MIGRATED_OVERLAY_TMP" "coordinator.pearl-overlays.yaml"
      if ! cmp -s "$COORDINATOR_OVERLAY_CONFIG_RAW_TMP" "$C2_TIMER_MIGRATED_OVERLAY_TMP"; then
        C2_TIMER_MIGRATION_OVERLAY_ACTIVE=1
        sanitize_live_config_for_local_validation < "$C2_TIMER_MIGRATED_OVERLAY_TMP" > "$C2_TIMER_MIGRATED_OVERLAY_VALIDATION_TMP" || {
          echo "aborting deploy: could not sanitize C2 timer migrated coordinator overlay for local validation" >&2
          exit 5
        }
        COORDINATOR_EFFECTIVE_OVERLAY_TMP="$C2_TIMER_MIGRATED_OVERLAY_VALIDATION_TMP"
        echo "  C2_TIMER_CONFIG_MIGRATION=1 — Pearl overlay carries timer fields and will be migrated field-scope"
      fi
    fi
    RATE_CARD_OVERLAY_MIGRATION_INPUT="${C2_TIMER_MIGRATED_OVERLAY_TMP:-$COORDINATOR_OVERLAY_CONFIG_RAW_TMP}"
    RATE_CARD_MIGRATED_OVERLAY_TMP="$(umask 077 && mktemp -t macprovider-coordinator-rate-card-overlay.XXXXXXXX)" || {
      echo "aborting deploy: mktemp failed for rate-card migrated coordinator overlay" >&2; exit 5;
    }
    RATE_CARD_MIGRATED_OVERLAY_VALIDATION_TMP="$(umask 077 && mktemp -t macprovider-coordinator-rate-card-overlay-validation.XXXXXXXX)" || {
      echo "aborting deploy: mktemp failed for sanitized rate-card migrated coordinator overlay" >&2; exit 5;
    }
    python3 "$RATE_CARD_CONFIG_MIGRATION_SCRIPT" --only-static-feed-overlays "$RATE_CARD_OVERLAY_MIGRATION_INPUT" "$CONFIG" > "$RATE_CARD_MIGRATED_OVERLAY_TMP" || {
      echo "aborting deploy: could not render reviewed rate-card overlay migration" >&2
      exit 5
    }
    reject_redacted_install_candidate "$RATE_CARD_MIGRATED_OVERLAY_TMP" "coordinator.pearl-overlays.yaml"
    if ! cmp -s "$RATE_CARD_OVERLAY_MIGRATION_INPUT" "$RATE_CARD_MIGRATED_OVERLAY_TMP"; then
      RATE_CARD_MIGRATION_OVERLAY_ACTIVE=1
      sanitize_live_config_for_local_validation < "$RATE_CARD_MIGRATED_OVERLAY_TMP" > "$RATE_CARD_MIGRATED_OVERLAY_VALIDATION_TMP" || {
        echo "aborting deploy: could not sanitize rate-card migrated coordinator overlay for local validation" >&2
        exit 5
      }
      COORDINATOR_EFFECTIVE_OVERLAY_TMP="$RATE_CARD_MIGRATED_OVERLAY_VALIDATION_TMP"
      echo "  B10 rate-card migration — Pearl overlay carries static feed fields and will receive rate-card paths"
    fi
    DEPLOY_EFFECTIVE_CONFIG_TMP="$(umask 077 && mktemp -t macprovider-coordinator-effective-config.XXXXXXXX)" || {
      echo "aborting deploy: mktemp failed for effective coordinator config" >&2; exit 5;
    }
    python3 "$MERGE_OVERLAY_SCRIPT" "$DEPLOY_CONFIG" "$COORDINATOR_EFFECTIVE_OVERLAY_TMP" > "$DEPLOY_EFFECTIVE_CONFIG_TMP" || {
      echo "aborting deploy: could not merge coordinator base config with Pearl overlay" >&2
      exit 5
    }
    DEPLOY_CONFIG="$DEPLOY_EFFECTIVE_CONFIG_TMP"
  else
    echo "  no Pearl coordinator overlay found at $COORDINATOR_REMOTE_OVERLAY; validating base coordinator config"
  fi
  assert_stats_required_matches_effective_config
  if [ "${SKIP_C2_CHECK:-0}" = "1" ]; then
    echo "aborting deploy: SKIP_C2_CHECK=1 is no longer supported; fix C2/C2b config instead" >&2
    exit 5
  fi
  GATEWAY_REMOTE_CONFIG_TMP="$(umask 077 && mktemp -t macprovider-gateway-installed-config.XXXXXXXX)" || {
    echo "aborting deploy: mktemp failed for installed gateway config copy" >&2; exit 5;
  }
  $SSH "test -f '$GATEWAY_REMOTE_CONFIG' || { echo 'missing installed gateway config: $GATEWAY_REMOTE_CONFIG' >&2; exit 1; }; cat '$GATEWAY_REMOTE_CONFIG'" > "$GATEWAY_REMOTE_CONFIG_TMP" || {
    echo "aborting deploy: could not read installed gateway config from Pearl: $GATEWAY_REMOTE_CONFIG" >&2
    exit 5
  }
  GATEWAY_REMOTE_CONFIG_SHA=$(shasum -a 256 "$GATEWAY_REMOTE_CONFIG_TMP" | awk '{print $1}')
  echo "  validating installed Pearl gateway config: $GATEWAY_REMOTE_CONFIG sha256=$GATEWAY_REMOTE_CONFIG_SHA"

  # The deadline is not a secret, but it is operator-owned runtime state. Read
  # it as data from the same EnvironmentFile systemd uses; do not source the
  # file. The deploy gate validates syntax and freshness before any upload.
  MODEL_HASH_LEGACY_UNTIL_RAW="$($SSH \
    'if [ -r /etc/macprovider/coordinator.env ]; then sed -n "s/^[[:space:]]*MODEL_HASH_LEGACY_UNTIL=//p" /etc/macprovider/coordinator.env | tail -n 1; fi')" || {
    echo "aborting deploy: could not read MODEL_HASH_LEGACY_UNTIL from Pearl coordinator.env" >&2
    exit 5
  }
  MODEL_HASH_LEGACY_UNTIL_FOR_GATE="$(_parse_model_hash_legacy_until "$MODEL_HASH_LEGACY_UNTIL_RAW")" || {
    echo "aborting deploy: could not parse MODEL_HASH_LEGACY_UNTIL from Pearl coordinator.env" >&2
    exit 5
  }

  # PR #172 C2c: the coordinator will restart and consume coordinator.env,
  # while the gateway keeps its current process environment. Prove that exact
  # next-state pairing on Pearl and compare only digests locally; never copy or
  # print bearer material. The helper also requires the peer's env file and
  # process to match, so a later peer restart cannot change the proven state.
  # Current-peer credentials must use env:NAME; inline YAML cannot be read
  # authoritatively from an already-running process.
  _c2c_env_name() {
    local raw="$1"
    case "$raw" in
      env:*)
        raw="${raw#env:}"
        if ! printf '%s' "$raw" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$'; then
          echo "aborting deploy: malformed env:NAME in service-token pairing field" >&2
          return 1
        fi
        printf '%s' "$raw"
        ;;
      *) printf '%s' - ;;
    esac
  }
  _coord_op_name="$(_c2c_env_name "$(yaml_file_block_value "$DEPLOY_CONFIG" auth operator_key)")" || exit 5
  _coord_svc_name="$(_c2c_env_name "$(yaml_file_block_value "$DEPLOY_CONFIG" auth gateway_service_token)")" || exit 5
  _gateway_svc_name="$(_c2c_env_name "$(yaml_file_block_value "$GATEWAY_REMOTE_CONFIG_TMP" coordinator service_token)")" || exit 5
  _gateway_op_name="$(_c2c_env_name "$(yaml_file_block_value "$GATEWAY_REMOTE_CONFIG_TMP" coordinator operator_key)")" || exit 5
  _c2c_proofs="$($SSH python3 - coordinator-deploy "$_coord_op_name" "$_coord_svc_name" "$_gateway_svc_name" "$_gateway_op_name" < "$C2C_PROOF_SCRIPT")" || {
    echo "aborting deploy: could not prove coordinator/gateway credential pairing on Pearl" >&2
    exit 5
  }
  read -r C2C_COORD_OPERATOR_KEY_SHA256 C2C_COORD_SERVICE_TOKEN_SHA256 C2C_GATEWAY_SERVICE_TOKEN_SHA256 C2C_GATEWAY_OPERATOR_KEY_SHA256 <<EOF
$_c2c_proofs
EOF
  if ! _catalog_canary_auth_token_matches_operator_key "$CATALOG_CANARY_AUTH_TOKEN" "$C2C_COORD_OPERATOR_KEY_SHA256"; then
    echo "aborting deploy: CATALOG_CANARY_AUTH_TOKEN must be the coordinator operator key" >&2
    echo "  /v1/pool/check?details=deployment is operator-only; service tokens cannot satisfy deployment evidence." >&2
    echo "  Update the operator-held canary token source before retrying; no secret material was copied from Pearl." >&2
    exit 5
  fi
  C2C_COORD_OPERATOR_KEY_SHA256="$C2C_COORD_OPERATOR_KEY_SHA256" \
  C2C_COORD_SERVICE_TOKEN_SHA256="$C2C_COORD_SERVICE_TOKEN_SHA256" \
  C2C_GATEWAY_SERVICE_TOKEN_SHA256="$C2C_GATEWAY_SERVICE_TOKEN_SHA256" \
  C2C_GATEWAY_OPERATOR_KEY_SHA256="$C2C_GATEWAY_OPERATOR_KEY_SHA256" \
  MODEL_HASH_LEGACY_UNTIL="$MODEL_HASH_LEGACY_UNTIL_FOR_GATE" \
  SKIP_C2_CHECK="${SKIP_C2_CHECK:-0}" \
    bash "$CHECK_SCRIPT" "$DEPLOY_CONFIG" "$GATEWAY_REMOTE_CONFIG_TMP" || {
    echo "aborting deploy: config-drift check failed" >&2; exit 5;
  }
fi

# SPEC-015 v0.3 §M.4 — fail closed before any remote mutation if the
# local nginx conf lacks the catalog routes. The static check is
# under-engineered for the operator-runbook live smoke surface
# (check_nginx_receipt_header_live_test.sh is the live counterpart);
# this is the pre-upload acceptance gate that catches a stale local
# nginx-coordinator.streamvc.live.conf before the deploy ships it.
bash "$DIST_DIR/test/check_nginx_catalog_routes_test.sh" || {
  echo "aborting deploy: nginx /catalog/ routes missing or misconfigured" >&2; exit 5;
}

CATALOG_REMOTE_PATH="$(yaml_tier2_value catalog_path)"
CATALOG_PUBLIC_KEY="$(yaml_tier2_value catalog_public_key)"
# Issue #244 R2 SEC HIGH-2 + R3 SEC HIGH-1 + R4 CODE HIGH-1 + R4 SEC
# HIGH-1: the catalog destination is HARDCODED, not operator-controlled.
# Earlier rounds tried regex-validation then prefix-allowlist; both still
# permitted attacks: trailing slash → `dirname` yields `/opt` →
# `install -d` re-chowns `/opt`; macprovider-writable parent →
# attacker plants a symlink at the destination → root `install` follows
# it. The only accepted runtime path is now the release-bound current pointer:
# root stages signed bytes under immutable /opt/macprovider/autotune/releases/
# and activation atomically switches root-owned autotune/current. The deploy
# never writes Tier-2 through the current symlink or through the old independent
# /opt/macprovider/tier2-catalog.json bridge.
CATALOG_REMOTE_PATH_CANONICAL="/opt/macprovider/autotune/current/tier2-catalog.json"
if [ -n "$CATALOG_REMOTE_PATH" ]; then
  if [ "$CATALOG_REMOTE_PATH" != "$CATALOG_REMOTE_PATH_CANONICAL" ]; then
    echo "aborting deploy: tier2.catalog_path must be exactly '$CATALOG_REMOTE_PATH_CANONICAL'" >&2
    echo "  Got: '$CATALOG_REMOTE_PATH'." >&2
    echo "  This is hardcoded as a single defense-in-depth path: deploy stages" >&2
    echo "  signed bytes only under root-owned immutable release directories and" >&2
    echo "  activates them by atomically switching /opt/macprovider/autotune/current." >&2
    echo "  The deploy refuses dynamic dirname-derived destinations and never" >&2
    echo "  writes Tier-2 through the current symlink." >&2
    exit 5
  fi
  if [ -z "$CATALOG_PUBLIC_KEY" ]; then
    echo "aborting deploy: tier2.catalog_path is set but tier2.catalog_public_key is empty" >&2
    exit 5
  fi
  if [ ! -f "$CATALOG_SOURCE" ]; then
    echo "aborting deploy: configured tier2.catalog_path requires release-bound Tier-2 catalog artifact, missing: $CATALOG_SOURCE" >&2
    echo "  Default source is $AUTOTUNE_TIER2_JSON; any override must match release.json." >&2
    exit 5
  fi
  TMP_CATALOG_PUBKEY="$(mktemp)"
  # Pin the exact Tier-2 bytes that pass verify+binding; later upload uses this
  # snapshot so a mutable CATALOG_SOURCE cannot change between preflight and scp.
  TMP_CATALOG_PINNED="$(mktemp)"
  # Cleanup of TMP_CATALOG_* happens in the unconditional EXIT trap (#244 R6 / #608).
  cp "$CATALOG_SOURCE" "$TMP_CATALOG_PINNED"
  CATALOG_PIN_SHA="$(shasum -a 256 "$TMP_CATALOG_PINNED" | awk '{print $1}')"
  if [ "$CATALOG_PIN_SHA" != "$AUTOTUNE_TIER2_SHA256" ]; then
    echo "aborting deploy: Tier-2 source digest does not match release.json feed binding" >&2
    echo "  source=$CATALOG_PIN_SHA release.json=$AUTOTUNE_TIER2_SHA256" >&2
    exit 5
  fi
  if ! cmp -s "$TMP_CATALOG_PINNED" "$AUTOTUNE_TIER2_JSON"; then
    echo "aborting deploy: Tier-2 source bytes differ from canonical release envelope file $AUTOTUNE_TIER2_JSON" >&2
    exit 5
  fi
  printf '%s\n' "$CATALOG_PUBLIC_KEY" > "$TMP_CATALOG_PUBKEY"
  # The canonical release verifier above already authenticated the exact
  # canonical Tier-2 bytes with its fixed Go verifier and configured trust
  # root. Digest equality plus cmp prove this pinned upload is those bytes;
  # do not introduce a second PATH-selectable verifier here.
  # #608 Partial: refuse deploy when Tier-2 identity drifts from the autotune
  # release about to be activated. Overlapping model_id rows must agree on
  # artifact hash; Tier-2-only / autotune-only rows remain allowed for now.
  if [ ! -f "$STATIC_AUTOTUNE_JSON" ]; then
    echo "aborting deploy: cannot bind Tier-2 identity without $STATIC_AUTOTUNE_JSON" >&2
    exit 5
  fi
  python3 "$AUTOTUNE_RELEASE_VERIFY" check-tier2-binding \
    --candidate "$STATIC_AUTOTUNE_JSON" \
    --tier2 "$TMP_CATALOG_PINNED" || {
    echo "aborting deploy: Tier-2 catalog conflicts with autotune release identity (#608)" >&2
    exit 5
  }
  echo "  ok: pinned release-bound catalog sha256=$CATALOG_PIN_SHA verifies, binds to autotune release, and will activate at $CATALOG_REMOTE_PATH"
else
  echo "aborting deploy: tier2.catalog_path must be set for release-bound Tier-2 publish (#608 Step B)" >&2
  exit 5
fi

log "step 1/9: confirm SSH + DNS"
$SSH 'hostname && uptime' >/dev/null
dig +short "$DOMAIN" | grep -q "$VPS_HOST" || { echo "DNS for $DOMAIN does not resolve to $VPS_HOST yet" >&2; exit 1; }

# Install the durable pre-start recovery guard before any release file can be
# replaced. It rolls back an armed transaction on boot/restart whenever the
# controller-held deploy lock is no longer present.
RECOVERY_DEPLOY_TMP=$($SSH 'umask 077 && mktemp -d -t macprovider-recovery.XXXXXXXX')
case "$RECOVERY_DEPLOY_TMP" in
  /tmp/macprovider-recovery.*) ;;
  *) echo "aborting deploy: unexpected recovery staging path: $RECOVERY_DEPLOY_TMP" >&2; exit 1 ;;
esac
$SCP "$DEPLOY_RECOVER" "$VPS_USER@$VPS_HOST:$RECOVERY_DEPLOY_TMP/coordinator-deploy-recover"
$SCP "$DEPLOY_GUARD" "$VPS_USER@$VPS_HOST:$RECOVERY_DEPLOY_TMP/10-deploy-transaction-guard.conf"
$SCP "$DEPLOY_RECOVERY_SERVICE" "$VPS_USER@$VPS_HOST:$RECOVERY_DEPLOY_TMP/macprovider-coordinator-deploy-recovery.service"
$SCP "$DEPLOY_WATCHDOG_SERVICE" "$VPS_USER@$VPS_HOST:$RECOVERY_DEPLOY_TMP/macprovider-coordinator-deploy-watchdog.service"
RECOVERY_INPUT_MANIFEST_TMP="$(umask 077 && mktemp -t macprovider-recovery-inputs.XXXXXXXX)" || {
  echo "aborting deploy: mktemp failed for recovery input manifest" >&2
  exit 2
}
shasum -a 256 "$DEPLOY_RECOVER" | awk '{ print $1 "  coordinator-deploy-recover" }' >> "$RECOVERY_INPUT_MANIFEST_TMP"
shasum -a 256 "$DEPLOY_GUARD" | awk '{ print $1 "  10-deploy-transaction-guard.conf" }' >> "$RECOVERY_INPUT_MANIFEST_TMP"
shasum -a 256 "$DEPLOY_RECOVERY_SERVICE" | awk '{ print $1 "  macprovider-coordinator-deploy-recovery.service" }' >> "$RECOVERY_INPUT_MANIFEST_TMP"
shasum -a 256 "$DEPLOY_WATCHDOG_SERVICE" | awk '{ print $1 "  macprovider-coordinator-deploy-watchdog.service" }' >> "$RECOVERY_INPUT_MANIFEST_TMP"
$SCP "$RECOVERY_INPUT_MANIFEST_TMP" "$VPS_USER@$VPS_HOST:$RECOVERY_DEPLOY_TMP/recovery-inputs.sha256"
$SSH "cd $RECOVERY_DEPLOY_TMP && shasum -a 256 -c recovery-inputs.sha256 >/dev/null"
echo "  recovery staged input digests OK"
$SSH "set -e
  _helper_next=/opt/macprovider/coordinator-deploy-recover.next.\$\$
  _unit_next=/etc/systemd/system/macprovider-coordinator-deploy-recovery.service.next.\$\$
  _watchdog_next=/etc/systemd/system/macprovider-coordinator-deploy-watchdog.service.next.\$\$
  install -d -o root -g root -m 0755 /etc/systemd/system/macprovider-coordinator.service.d
  _guard_next=/etc/systemd/system/macprovider-coordinator.service.d/10-deploy-transaction-guard.conf.next.\$\$
  trap 'rm -f \"\$_helper_next\" \"\$_unit_next\" \"\$_watchdog_next\" \"\$_guard_next\"' EXIT HUP INT TERM
  install -o root -g root -m 0750 $RECOVERY_DEPLOY_TMP/coordinator-deploy-recover \"\$_helper_next\"
  mv -Tf \"\$_helper_next\" /opt/macprovider/coordinator-deploy-recover
  install -o root -g root -m 0644 $RECOVERY_DEPLOY_TMP/macprovider-coordinator-deploy-recovery.service \"\$_unit_next\"
  mv -Tf \"\$_unit_next\" /etc/systemd/system/macprovider-coordinator-deploy-recovery.service
  install -o root -g root -m 0644 $RECOVERY_DEPLOY_TMP/macprovider-coordinator-deploy-watchdog.service \"\$_watchdog_next\"
  mv -Tf \"\$_watchdog_next\" /etc/systemd/system/macprovider-coordinator-deploy-watchdog.service
  install -o root -g root -m 0644 $RECOVERY_DEPLOY_TMP/10-deploy-transaction-guard.conf \"\$_guard_next\"
  mv -Tf \"\$_guard_next\" /etc/systemd/system/macprovider-coordinator.service.d/10-deploy-transaction-guard.conf
  systemctl daemon-reload
  systemctl reset-failed macprovider-coordinator-deploy-watchdog.service 2>/dev/null || true
  systemctl start --no-block macprovider-coordinator-deploy-watchdog.service
  _watchdog_state=\$(systemctl show -p ActiveState --value macprovider-coordinator-deploy-watchdog.service)
  case \"\$_watchdog_state\" in
    active|activating) ;;
    *) echo \"coordinator deploy watchdog failed to arm: \$_watchdog_state\" >&2; exit 1 ;;
  esac
  rm -rf $RECOVERY_DEPLOY_TMP
  trap - EXIT HUP INT TERM"
RECOVERY_DEPLOY_TMP=""

# Previous-deploy bypass tombstone — if the last deploy used
# FORCE_RESTART=1 (or got manually bypassed past the connected-provider
# guard), step 1c or step 6c writes /var/lib/macprovider/last-deploy-bypass.json
# below. Surface it here so the operator can audit before scping a new
# binary. Does NOT exit — informational only. Remove the file once
# audited by the operator.
PREV_BYPASS=$($SSH 'cat /var/lib/macprovider/last-deploy-bypass.json 2>/dev/null || true')
if [ -n "$PREV_BYPASS" ]; then
  log "  NOTE: previous deploy left a bypass tombstone:"
  printf '%s\n' "$PREV_BYPASS" | sed 's/^/    /'
  log "  If audited, clear with: ssh <pearl> rm /var/lib/macprovider/last-deploy-bypass.json"
fi

log "step 1b/9: drift check vs live /opt/macprovider/coordinator.yaml"
# Catches the silent-config-change hazard. The 2026-06-11 deploy caused
# a brief outage because the local config dropped auth.require_provider_tokens
# entirely; the prior binary defaulted false, the new binary defaulted true,
# and providers were rejected. A field-level diff vs live is the tripwire
# that would have surfaced that drift before the restart.
#
# Secrets are masked in the SSH pipe so unmasked Pearl content never lands
# on local disk. CONFIG_MODE=preserve-live keeps the live config in place; a
# tracked-config replacement is allowed only when tracked already matches live.
tier2_require_hash_verified() {
  awk '
    /^tier2:[[:space:]]*$/ {
      tier2_blocks += 1
      in_tier2 = 1
      next
    }
    in_tier2 && /^[^[:space:]]/ {
      in_tier2 = 0
    }
    in_tier2 {
      if (index($0, "\t") != 0) {
        invalid = 1
        next
      }
      match($0, /^ */)
      indent = RLENGTH
      if (indent > 0 && $0 ~ /^ +[A-Za-z0-9_-]+:[[:space:]]*/) {
        child_count += 1
        child_line[child_count] = $0
        child_indent[child_count] = indent
        if (minimum_indent == 0 || indent < minimum_indent) {
          minimum_indent = indent
        }
      }
    }
    END {
      if (tier2_blocks != 1 || invalid || minimum_indent == 0) {
        exit 1
      }
      for (i = 1; i <= child_count; i += 1) {
        if (child_indent[i] == minimum_indent &&
            child_line[i] ~ /^ +require_hash_verified:[[:space:]]*/) {
          count += 1
          value = child_line[i]
          sub(/^ +require_hash_verified:[[:space:]]*/, "", value)
          sub(/[[:space:]]*$/, "", value)
        }
      }
      if (count == 1 && (value == "true" || value == "false")) {
        print value
        exit 0
      }
      exit 1
    }
  '
}
LIVE_NORM=$($SSH 'cat /opt/macprovider/coordinator.yaml' 2>/dev/null | normalize_yaml) || {
  echo "could not pull live coordinator.yaml from Pearl for drift check" >&2; exit 6;
}
LOCAL_NORM=$(normalize_yaml < "$CONFIG")
if [ "$CONFIG_MODE" = "apply-tracked" ]; then
  LIVE_CONFIG_SHA="$($SSH "sha256sum /opt/macprovider/coordinator.yaml | awk '{print \$1}'")" || {
    echo "could not hash live coordinator.yaml on Pearl for tracked-config deploy" >&2; exit 6;
  }
  LOCAL_CONFIG_SHA="$(shasum -a 256 "$CONFIG" | awk '{print $1}')"
  if [ "$LOCAL_CONFIG_SHA" != "$LIVE_CONFIG_SHA" ]; then
    echo "" >&2
    echo "  Aborting: CONFIG_MODE=apply-tracked requires exact live/tracked coordinator.yaml byte equality." >&2
    echo "  local sha256=$LOCAL_CONFIG_SHA" >&2
    echo "  live  sha256=$LIVE_CONFIG_SHA" >&2
    echo "  Use CONFIG_MODE=preserve-live for code/catalog deploys, or a reviewed field-scoped config migration for config changes." >&2
    exit 8
  fi
  LIVE_TIER2_HASH_REQUIRED="$(printf '%s\n' "$LIVE_NORM" | tier2_require_hash_verified || true)"
  LOCAL_TIER2_HASH_REQUIRED="$(printf '%s\n' "$LOCAL_NORM" | tier2_require_hash_verified || true)"
  if [ -z "$LIVE_TIER2_HASH_REQUIRED" ] || [ -z "$LOCAL_TIER2_HASH_REQUIRED" ]; then
    echo "" >&2
    echo "  Aborting: tracked-config deploy requires one unambiguous tier2.require_hash_verified boolean in both configs." >&2
    exit 9
  fi
  if [ "$LOCAL_TIER2_HASH_REQUIRED" != "$LIVE_TIER2_HASH_REQUIRED" ]; then
    echo "" >&2
    echo "  Aborting: tracked-config deploy cannot change tier2.require_hash_verified." >&2
    echo "  Use the reviewed enforcement or rollback transaction for that state transition." >&2
    exit 9
  fi
fi
if ! DRIFT_DIFF=$(diff <(printf '%s\n' "$LOCAL_NORM") <(printf '%s\n' "$LIVE_NORM")); then
  echo "" >&2
  echo "  CONFIG DRIFT detected (secrets masked; '<' = local, '>' = live):" >&2
  printf '%s\n' "$DRIFT_DIFF" | print_config_drift_diff
  echo "" >&2
  if [ "$CONFIG_MODE" = "preserve-live" ]; then
    echo "  CONFIG_MODE=preserve-live set — live coordinator.yaml will be preserved." >&2
    echo "  Tracked coordinator.yaml is not uploaded or installed in this mode." >&2
  else
    echo "  Aborting. CONFIG_MODE=apply-tracked may install tracked coordinator.yaml only when it already matches live." >&2
    echo "  Broad ALLOW_CONFIG_DRIFT=1 is disabled; use a reviewed field-scoped config migration." >&2
    exit 8
  fi
else
  echo "  ok: local config matches live (modulo secrets)"
fi

log "step 1c/9: early connected-provider check"
# Mirror of step 6c, run BEFORE binary swap so a refusal does not leave
# the operator with new code on disk and old code running. The full
# script does the connected-provider check twice on purpose:
#   - step 1c here: protects the longest part of the window (between
#     step 4 binary install and step 7 restart, which spans certbot +
#     nginx work and can take minutes); refusing here saves the scp.
#   - step 6c just before restart: protects against providers that
#     connected DURING the deploy itself (between step 1c and step 7).
# Both honor FORCE_RESTART=1, which writes a sticky tombstone at
# /var/lib/macprovider/last-deploy-bypass.json so the NEXT deploy
# notices the operator override (see step 1's PREV_BYPASS surface).
CONNECTED_COUNT_EARLY=$(curl -fsS --max-time 5 --max-filesize 65536 "https://$DOMAIN/healthz" 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('pool_size', 0))" 2>/dev/null \
  || echo 0)
if [ "${CONNECTED_COUNT_EARLY:-0}" -gt 0 ] && [ "${FORCE_RESTART:-0}" != "1" ]; then
  log "  REFUSING TO DEPLOY — $CONNECTED_COUNT_EARLY provider(s) currently connected."
  log "  Restart at step 7 would trigger SPEC-001 § 6.5 drain on these providers."
  log "  Refusing EARLY (pre-scp) so you don't leave a new binary on disk."
  log "  To proceed anyway:  FORCE_RESTART=1 bash $0"
  exit 4
fi
if [ "${FORCE_RESTART:-0}" = "1" ] && [ "${CONNECTED_COUNT_EARLY:-0}" -gt 0 ]; then
  TS_NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  OP_HOST="${HOSTNAME:-unknown}"
  # R6 SEC/CODE/ARCH convergent MED — write the tombstone via remote
  # mktemp under umask 077 instead of predictable /tmp/last-deploy-
  # bypass.json. Same threat model as R5's main /tmp staging fix:
  # a same-host attacker could otherwise pre-place a FIFO/symlink at
  # the predictable name and forge/clobber the audit tombstone or
  # cause a deploy DoS.
  $SSH "set -e
        install -d -o macprovider -g macprovider -m 0750 /var/lib/macprovider 2>/dev/null || true
        _bypass_tmp=\$(umask 077 && mktemp)
        cat > \"\$_bypass_tmp\" <<EOF
{\"ts\":\"$TS_NOW\",\"service\":\"coordinator\",\"reason\":\"FORCE_RESTART=1\",\"step\":\"1c\",\"metric\":\"connected_providers\",\"value\":$CONNECTED_COUNT_EARLY,\"operator_host\":\"$OP_HOST\"}
EOF
        install -o macprovider -g macprovider -m 0640 \"\$_bypass_tmp\" /var/lib/macprovider/last-deploy-bypass.json
        rm -f \"\$_bypass_tmp\"
        logger -t macprovider-deploy \"FORCE_RESTART=1 used at step 1c; connected=$CONNECTED_COUNT_EARLY\""
  log "  AUDIT TRAIL: FORCE_RESTART=1 override written to /var/lib/macprovider/last-deploy-bypass.json"
fi
log "  ok: $CONNECTED_COUNT_EARLY connected providers (or FORCE_RESTART=1 set)"

log "step 2/9: install certbot + openssl + nginx-snippets (apt)"
# openssl is required by step 4b's cert-validity probe (#244 R2 fix).
$SSH 'DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -qq -y certbot python3-certbot-nginx openssl >/dev/null' || {
  echo "certbot/openssl install failed" >&2; exit 1;
}

log "step 3/9: create macprovider system user + dirs"
# codex PR #73 fixup:
#   - /var/lib/macprovider-monitor — writable carve-out for the de-rooted
#     monitor under ProtectSystem=strict (HIGH-2 sandbox). Systemd would
#     also create this via StateDirectory= at unit start, but creating it
#     up-front guarantees correct ownership before the first activation.
#   - /etc/macprovider — operator-rooted directory holding coordinator.env.
#     The env file is read by the coordinator unit (root) and by the de-rooted
#     monitor (macprovider). Mode 0750 lets macprovider read it via group;
#     coordinator.env itself ships mode 0640 root:macprovider (LOW-fix).
$SSH 'set -e
  id macprovider >/dev/null 2>&1 || useradd --system --home /opt/macprovider --shell /usr/sbin/nologin macprovider
  getent group macprovider-stats >/dev/null 2>&1 || groupadd --system macprovider-stats
  id macprovider-stats >/dev/null 2>&1 || useradd --system --gid macprovider-stats --home /nonexistent --shell /usr/sbin/nologin macprovider-stats
  # Issue #244 R4 SEC HIGH-1 — /opt/macprovider is root-owned 0750 so
  # the macprovider user (or anything running as it) cannot plant a
  # symlink at the catalog destination that a later root-owned
  # `install` would follow. macprovider group keeps r-x to enter the
  # dir and read files within it. Files inside (coordinator binary,
  # config, catalog) are still installed mode-set to macprovider so
  # the daemon can read them.
  install -d -o root -g macprovider -m 0750 /opt/macprovider
  install -d -o root -g macprovider-stats -m 0750 /opt/macprovider-stats
  install -d -o macprovider -g macprovider -m 0750 /var/lib/macprovider
  install -d -o macprovider -g macprovider -m 0750 /var/log/macprovider
  install -d -o macprovider -g macprovider -m 0750 /var/lib/macprovider-monitor
  install -d -o root -g macprovider -m 0750 /etc/macprovider
  install -d -o root -g macprovider-stats -m 0750 /etc/macprovider-stats
  if [ -f /etc/macprovider/coordinator.env ]; then
    chown root:macprovider /etc/macprovider/coordinator.env
    chmod 0640 /etc/macprovider/coordinator.env
    echo "  enforced coordinator.env perms: root:macprovider 0640"
  else
    echo "  /etc/macprovider/coordinator.env not yet present; operator must drop it with mode 0640 (root:macprovider)"
  fi
  if [ -f /etc/macprovider/monitor.env ]; then
    chown root:macprovider /etc/macprovider/monitor.env
    chmod 0640 /etc/macprovider/monitor.env
    echo "  enforced monitor.env perms: root:macprovider 0640"
  else
    echo "  /etc/macprovider/monitor.env not yet present; optional monitor email alerts remain disabled"
  fi
  if [ -f /etc/macprovider-stats/stats-hardware-inventory.yaml ]; then
    chown root:macprovider-stats /etc/macprovider-stats/stats-hardware-inventory.yaml
    chmod 0640 /etc/macprovider-stats/stats-hardware-inventory.yaml
    echo "  enforced stats hardware inventory perms: root:macprovider-stats 0640"
  else
    echo "  /etc/macprovider-stats/stats-hardware-inventory.yaml not yet present; stats inventory timer remains opt-in"
  fi
  if [ -f /etc/macprovider-stats/stats-inventory-sync.env ]; then
    chown root:root /etc/macprovider-stats/stats-inventory-sync.env
    chmod 0600 /etc/macprovider-stats/stats-inventory-sync.env
    echo "  enforced stats inventory env perms: root:root 0600"
  else
    echo "  /etc/macprovider-stats/stats-inventory-sync.env not yet present; stats inventory timer remains opt-in"
  fi
  if [ -f /etc/macprovider-stats/stats-billing-mirror.env ]; then
    chown root:root /etc/macprovider-stats/stats-billing-mirror.env
    chmod 0600 /etc/macprovider-stats/stats-billing-mirror.env
    echo "  enforced stats billing mirror env perms: root:root 0600"
  else
    echo "  /etc/macprovider-stats/stats-billing-mirror.env not yet present; stats billing mirror timer remains opt-in"
  fi
  if [ -f /etc/macprovider-stats/stats-hardware-verifier.env ]; then
    chown root:root /etc/macprovider-stats/stats-hardware-verifier.env
    chmod 0600 /etc/macprovider-stats/stats-hardware-verifier.env
    echo "  enforced stats hardware verifier env perms: root:root 0600"
  else
    echo "  /etc/macprovider-stats/stats-hardware-verifier.env not yet present; stats hardware verifier timer remains opt-in"
  fi
'

log "step 3a/9: stats env preflight"
STATS_ENABLED_LOCAL="$(yaml_block_value stats enabled)"
ONBOARDING_ENABLED_LOCAL="$(yaml_block_value onboarding app_track_register_enabled)"
if [ "$STATS_ENABLED_LOCAL" = "true" ]; then
  # stats.enabled=true makes the coordinator fail closed during config load if
  # any required stats DSN is missing. Check the remote EnvironmentFile before
  # uploading/restarting so a stats cutover cannot brick the daemon late in
  # the deploy after artifacts have already been installed.
  $SSH 'set -e
    env_file=/etc/macprovider/coordinator.env
    if [ ! -r "$env_file" ]; then
      echo "aborting deploy: stats.enabled=true but $env_file is missing or unreadable" >&2
      exit 12
    fi
    missing=""
    for name in STATS_READER_DSN STATS_ROLLUP_DSN; do
      if ! awk -v name="$name" '"'"'
        function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        {
          line=$0
          sub(/^[[:space:]]*/, "", line)
          if (line ~ "^" name "[[:space:]]*=") {
            found=1
            sub("^[^=]*=", "", line)
            line=trim(line)
            if (line == "" || line == "\"\"" || line == "'\'''\''") exit 2
          }
        }
        END { if (!found) exit 1 }
      '"'"' "$env_file"; then
        missing="$missing $name"
      fi
    done
    if [ -n "$missing" ]; then
      echo "aborting deploy: stats.enabled=true but coordinator.env is missing required non-empty var(s):$missing" >&2
      exit 12
    fi
    echo "  ok: required stats DSN env vars are present in coordinator.env"
  '
else
  echo "  stats.enabled is not true in $DEPLOY_CONFIG — skipping stats env preflight"
fi

# Issue #582 MIGRATION-019 ORDERING — quiesce the OLD stats-inventory-sync
# sidecar BEFORE the migration is exercised, ahead of the onboarding preflight.
# Migration 019 widens hardware_verification_trust's PRIMARY KEY from
# (provider_id, hardware_identity_hash) to (provider_id, hardware_identity_hash,
# source). The stats-inventory-sync binary shipped BEFORE this release
# reconciles with `ON CONFLICT (provider_id, hardware_identity_hash)` (2-col).
# Once 019 is applied, that 2-col ON CONFLICT no longer matches a unique
# constraint and the old binary's reconciliation fails ("no unique or exclusion
# constraint matching the ON CONFLICT specification"). This deploy APPLIES 019
# itself, inside the onboarding preflight below and while stats is enabled, via
# the just-installed coordinator's embedded stats-migrate (search for
# "MIGRATION-019 ORDERING (self-enforcing" in that block) — so the migration
# provably FOLLOWS this quiesce. The old sidecar must therefore be stopped+
# disabled HERE, before that self-applied migration can touch the schema, NOT at
# the later release-window freeze (which is too late: a timer firing, or an
# aborted deploy between the migration and the freeze, would run the old 2-col
# binary against the 3-col schema). Stopping the .service is synchronous, so any
# in-flight reconciliation run drains before we return; disabling the .timer
# stops a scheduled fire (or a daemon-reload/reboot) from re-launching the old
# binary during the migrate->install window. The NEW 3-col binary is installed
# in step 4 and the timer is re-enabled in step 9. This quiesce runs BEFORE the
# rollback transaction is armed, so its inactive state is what the step-4
# snapshot records: a rollback restores the pre-019 binary but deliberately
# leaves the sidecar stopped (see coordinator-deploy-recover.sh) so the old
# binary never runs against the migrated schema.
# Issue #582 (MEDIUM #6) — ARM the restore-on-failure path BEFORE quiescing:
# record that a quiesce is being attempted (consumed by the EXIT trap), capture
# the sidecar's prior enable/active state so a safe early abort can restore it,
# and preserve whether a prior deploy deliberately left a schema/binary parity
# hold before clearing the marker for this attempt. The capture runs INSIDE the
# same locked SSH, ahead of the disable/stop, so the recorded state is the true
# pre-quiesce state.
SIDECAR_QUIESCE_ATTEMPTED=1
$SSH 'set -eu
  exec 8>/opt/macprovider/.coordinator-deploy-operation.lock
  flock -s 8
  _prior=/opt/macprovider/.coordinator-deploy-sidecar-prior-state
  _prior_next=$_prior.next.$$
  if [ -f /opt/macprovider/.coordinator-deploy-sidecar-parity-required ]; then
    _parity_required=present
  else
    _parity_required=absent
  fi
  ( umask 077
    {
      printf "timer_enabled=%s\n"   "$(systemctl is-enabled stats-inventory-sync.timer   2>/dev/null || true)"
      printf "timer_active=%s\n"    "$(systemctl is-active  stats-inventory-sync.timer   2>/dev/null || true)"
      printf "service_enabled=%s\n" "$(systemctl is-enabled stats-inventory-sync.service 2>/dev/null || true)"
      printf "parity_required=%s\n"  "$_parity_required"
    } > "$_prior_next"
  )
  mv -f "$_prior_next" "$_prior"
  rm -f /opt/macprovider/.coordinator-deploy-sidecar-parity-required
  for unit in stats-inventory-sync.timer stats-inventory-sync.service; do
    load_state=$(systemctl show -p LoadState --value "$unit")
    [ "$load_state" = not-found ] && continue
    if [ "$unit" = stats-inventory-sync.timer ]; then
      systemctl disable "$unit" >/dev/null
    else
      # The oneshot service has no [Install] section and is expected to be
      # static; the timer is the only persistent activation path.
      systemctl disable "$unit" >/dev/null 2>&1 || true
    fi
    systemctl stop "$unit"
    active_state=$(systemctl show -p ActiveState --value "$unit")
    case "$active_state" in
      inactive|failed) ;;
      *) echo "stats-inventory-sync unit did not quiesce before migration: $unit state=$active_state" >&2; exit 1 ;;
    esac
    if [ "$unit" = stats-inventory-sync.timer ]; then
      enabled_state=$(systemctl is-enabled "$unit" 2>/dev/null || true)
      [ "$enabled_state" = disabled ] || {
        echo "stats-inventory-sync timer did not disable before migration: state=$enabled_state" >&2
        exit 1
      }
    fi
  done
'

if [ "$ONBOARDING_ENABLED_LOCAL" = "true" ]; then
  $SSH "bash -s" <<'REMOTE_ONBOARDING_PREFLIGHT'
    set -e
    env_file=/etc/macprovider/coordinator.env
    if [ ! -r "$env_file" ]; then
      echo "aborting deploy: onboarding enabled but $env_file is missing or unreadable" >&2
      exit 12
    fi
    if ! command -v python3 >/dev/null 2>&1; then
      echo "aborting deploy: python3 is required for onboarding DSN preflight" >&2
      exit 12
    fi
    if ! command -v psql >/dev/null 2>&1; then
      echo "aborting deploy: psql is required for onboarding hardware evidence migration preflight" >&2
      exit 12
    fi
    read_env_value() {
      ENV_VALUE_FILE="$1" ENV_VALUE_NAME="$2" python3 <<'PY'
import os
import re
import shlex
import sys

path = os.environ["ENV_VALUE_FILE"]
want = os.environ["ENV_VALUE_NAME"]
if not re.fullmatch(r"[A-Z_][A-Z0-9_]*", want):
    print("invalid requested env var name", file=sys.stderr)
    sys.exit(2)

try:
    found = False
    parsed_value = ""
    with open(path, "r", encoding="utf-8") as f:
        for lineno, raw in enumerate(f, 1):
            if raw.endswith("\n"):
                raw = raw[:-1]
            if raw.endswith("\r"):
                print(f"{path}:{lineno}: CRLF env files are not supported", file=sys.stderr)
                sys.exit(2)
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                print(f"{path}:{lineno}: malformed env assignment", file=sys.stderr)
                sys.exit(2)
            key, value = line.split("=", 1)
            key = key.strip()
            if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
                print(f"{path}:{lineno}: malformed env var name", file=sys.stderr)
                sys.exit(2)
            if key != want:
                continue
            try:
                parts = shlex.split(value.strip(), comments=False, posix=True)
            except ValueError as exc:
                print(f"{path}:{lineno}: malformed env value for {want}: {exc}", file=sys.stderr)
                sys.exit(2)
            if len(parts) != 1:
                print(f"{path}:{lineno}: env value for {want} must be a single token", file=sys.stderr)
                sys.exit(2)
            parsed = parts[0]
            if any(ch in parsed for ch in "\r\n\0"):
                print(f"{path}:{lineno}: env value for {want} contains an invalid character", file=sys.stderr)
                sys.exit(2)
            found = True
            parsed_value = parsed
except OSError as exc:
    print(f"cannot read env file {path}: {exc}", file=sys.stderr)
    sys.exit(2)

if found:
    print(parsed_value, end="")
    sys.exit(0)
sys.exit(1)
PY
    }
    require_env_value() {
      env_value_file="$1"
      env_value_name="$2"
      if ! env_value="$(read_env_value "$env_value_file" "$env_value_name")"; then
        echo "aborting deploy: $env_value_file is missing required var or has invalid syntax: $env_value_name" >&2
        exit 12
      fi
      if [ -z "$env_value" ]; then
        echo "aborting deploy: $env_value_file has empty required var: $env_value_name" >&2
        exit 12
      fi
      printf '%s' "$env_value"
    }
    ONBOARDING_POSTGRES_DSN="$(require_env_value "$env_file" ONBOARDING_POSTGRES_DSN)"
    ONBOARDING_AUTH_POLICY_REQUEST_DSN="$(require_env_value "$env_file" ONBOARDING_AUTH_POLICY_REQUEST_DSN)"
    ONBOARDING_AUTH_POLICY_APPROVE_DSN="$(require_env_value "$env_file" ONBOARDING_AUTH_POLICY_APPROVE_DSN)"
    ONBOARDING_AUTH_POLICY_CUTOVER_DSN="$(require_env_value "$env_file" ONBOARDING_AUTH_POLICY_CUTOVER_DSN)"
    ONBOARDING_HARDWARE_TRUST_REQUEST_DSN="$(require_env_value "$env_file" ONBOARDING_HARDWARE_TRUST_REQUEST_DSN)"
    ONBOARDING_HARDWARE_TRUST_APPROVE_DSN="$(require_env_value "$env_file" ONBOARDING_HARDWARE_TRUST_APPROVE_DSN)"
    echo "  ok: required onboarding DSN env vars are present in coordinator.env"
    # Issue #582 MIGRATION-019 ORDERING (self-enforcing standard path) — apply the
    # embedded stats migrations, INCLUDING 019's hardware_verification_trust PRIMARY
    # KEY widening, HERE: after the unconditional sidecar quiesce above (a prior,
    # already-completed SSH stopped+disabled stats-inventory-sync.timer/.service)
    # and BEFORE both the 019-requiring psql preflight below and the step-4 install
    # of the new 3-column stats-inventory-sync binary. This makes the standard
    # deploy self-consistent instead of depending on an out-of-band operator
    # `stats-migrate` whose ordering against the quiesce the deploy cannot prove:
    # the migration now provably FOLLOWS the quiesce and PRECEDES the new sidecar
    # binary, so the old 2-column binary can never reconcile against the migrated
    # 3-column schema.
    #
    # statsmigrations.Apply is advisory-locked and idempotent, so a schema already
    # migrated (by a prior deploy or a manual operator run) is a safe no-op. The
    # admin DSN is read from coordinator.env as DATA (require_env_value, never
    # sourced) and passed via the COORDINATOR_PARTNER_KEYS_ADMIN_DSN environment
    # variable — which the coordinator's stats-migrate resolves — rather than argv,
    # so it never appears in `ps`. The post-apply --check is a HARD GATE: if 019 is
    # still not applied afterward, the on-disk coordinator binary predates issue
    # #582 and the deploy ABORTS rather than proceed to install + re-enable a
    # 3-column sidecar against a coordinator that cannot own the operator_api rows.
    COORDINATOR_PARTNER_KEYS_ADMIN_DSN="$(require_env_value "$env_file" COORDINATOR_PARTNER_KEYS_ADMIN_DSN)"
    export COORDINATOR_PARTNER_KEYS_ADMIN_DSN
    coordinator_bin=/opt/macprovider/coordinator
    if [ ! -x "$coordinator_bin" ]; then
      echo "aborting deploy: $coordinator_bin is not present or not executable;" >&2
      echo "  install the signed coordinator/gateway pair (macprovider-pearl-update) before deploying" >&2
      echo "  preflight the selected Pearl runtime release with scripts/verify-pearl-runtime-release.sh" >&2
      exit 12
    fi
    "$coordinator_bin" stats-migrate --check
    # Issue #582 (MEDIUM #6) — parity crossing. The next command may apply
    # migration 019 (hardware_verification_trust 3-column PRIMARY KEY), after which
    # the quiesced old 2-column sidecar is INCOMPATIBLE with the schema. Mark the
    # crossing BEFORE the apply so the controller's EXIT trap leaves the sidecar
    # stopped on any abort during/after the apply rather than restoring an old
    # binary against a migrated schema. (The restore path itself is also safe: it
    # only re-activates the sidecar to its captured pre-quiesce state — but the
    # marker gives the operator the correct "left stopped for parity" signal.)
    touch /opt/macprovider/.coordinator-deploy-sidecar-parity-required
    "$coordinator_bin" stats-migrate
    if ! "$coordinator_bin" stats-migrate --check | grep -Eq '^[[:space:]]*019_hardware_trust_operator_approval applied$'; then
      echo "aborting deploy: migration 019 (hardware_verification_trust 3-column PRIMARY KEY) is not applied after stats-migrate;" >&2
      echo "  the on-disk $coordinator_bin predates issue #582 — install the new signed coordinator/gateway pair first" >&2
      exit 12
    fi
    echo "  ok: stats migrations applied (incl. 019 hardware_verification_trust PK widening) inside the sidecar-quiesced window, before new-binary install"
    psql_preflight_service() {
      service_name="$1"
      dsn="$2"
      shift 2
      service_file="$(umask 077 && mktemp)"
      if ! PSQL_SERVICE_FILE="$service_file" PSQL_SERVICE_NAME="$service_name" PSQL_SERVICE_DSN="$dsn" python3 <<PY
import os
import sys
from urllib.parse import parse_qsl, unquote, urlparse

path = os.environ["PSQL_SERVICE_FILE"]
name = os.environ["PSQL_SERVICE_NAME"]
dsn = os.environ["PSQL_SERVICE_DSN"]
parsed = urlparse(dsn)
if parsed.scheme not in ("postgres", "postgresql"):
    print("unsupported Postgres DSN scheme", file=sys.stderr)
    sys.exit(2)
values = {
    "host": parsed.hostname or "",
    "user": unquote(parsed.username or ""),
    "password": unquote(parsed.password or ""),
    "dbname": unquote(parsed.path[1:] if parsed.path.startswith("/") else parsed.path),
}
if parsed.port is not None:
    values["port"] = str(parsed.port)
for key, value in parse_qsl(parsed.query, keep_blank_values=True):
    values[key] = value
with open(path, "w", encoding="utf-8") as f:
    f.write("[" + name + "]\n")
    for key, value in values.items():
        if any(ch in value for ch in "\r\n"):
            print("invalid newline in Postgres DSN value", file=sys.stderr)
            sys.exit(2)
        if value != "":
            f.write(key + "=" + value + "\n")
PY
      then
        rm -f "$service_file"
        return 1
      fi
      set +e
      PGSERVICEFILE="$service_file" PGSERVICE="$service_name" psql -v ON_ERROR_STOP=1 -qAt "$@"
      rc=$?
      set -e
      rm -f "$service_file"
      return "$rc"
    }
    psql_preflight_service onboarding_preflight "$ONBOARDING_POSTGRES_DSN" <<SQL >/dev/null
SELECT 1 FROM hardware_verification_jobs LIMIT 1;
SELECT generated_at, evidence
  FROM hardware_verification_jobs
 WHERE provider_id = ''
   AND status = 'verified'
 LIMIT 0;
-- FIX 7 (round-8, issue #582): exercise the LatestVerified admission join INCLUDING
-- the EXISTS on hardware_verification_trust (the round-6 live-trust re-check). The
-- provider_onboarding role must SELECT hardware_verification_trust for that join; a
-- missing/drifted grant would otherwise pass deploy and break every gated hello.
SELECT j.generated_at, j.evidence
  FROM hardware_verification_jobs j
  JOIN provider_hardware_profiles p
    ON p.provider_id = j.provider_id
   AND p.verified = TRUE
   AND p.chip_normalized = j.chip_normalized
   AND p.unified_memory_gb = j.unified_memory_gb
 WHERE j.provider_id = ''
   AND j.status = 'verified'
   AND EXISTS (
       SELECT 1
         FROM hardware_verification_trust t
        WHERE t.provider_id = j.provider_id
          AND t.hardware_identity_hash = j.evidence -> 'hardware' ->> 'hardware_identity_hash'
          AND t.chip_normalized = j.chip_normalized
          AND t.unified_memory_gb = j.unified_memory_gb
          AND (t.expires_at IS NULL OR t.expires_at > now())
   )
 LIMIT 0;
SQL
    echo "  ok: migration 008+013 hardware_verification_jobs + hardware_verification_trust admission join visible to provider_onboarding (hello gate read path)"
    psql_preflight_service auth_policy_request_preflight "$ONBOARDING_AUTH_POLICY_REQUEST_DSN" <<SQL >/dev/null
DO \$\$
BEGIN
  IF NOT (
    current_user = 'provider_auth_policy_requester'
    AND session_user = current_user
    AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = current_user AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolinherit AND NOT rolreplication AND NOT rolbypassrls)
    AND NOT EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles granted ON granted.oid = m.roleid JOIN pg_roles member ON member.oid = m.member WHERE member.rolname = current_user OR granted.rolname = current_user)
    AND NOT EXISTS (
      SELECT 1
        FROM (VALUES ('provider_identities'), ('provider_auth_policy'), ('provider_auth_policy_cutover_runs'), ('provider_auth_policy_pending'), ('provider_auth_policy_grants')) AS t(table_name)
        CROSS JOIN (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) AS p(privilege_name)
       WHERE has_table_privilege(current_user, t.table_name, p.privilege_name)
    )
    AND has_function_privilege(current_user, 'request_provider_auth_policy_exemption(uuid,text,text,timestamp with time zone,text,text)'::regprocedure, 'EXECUTE')
    AND NOT has_function_privilege(current_user, 'approve_provider_auth_policy_exemption(uuid,text)'::regprocedure, 'EXECUTE')
    AND NOT has_function_privilege(current_user, 'seed_provider_auth_policy_cutover(timestamp with time zone,text[])'::regprocedure, 'EXECUTE')
  ) THEN
    RAISE EXCEPTION 'auth policy request DSN does not map to the least-privilege requester role';
  END IF;
END
\$\$;
SQL
    psql_preflight_service auth_policy_approve_preflight "$ONBOARDING_AUTH_POLICY_APPROVE_DSN" <<SQL >/dev/null
DO \$\$
BEGIN
  IF NOT (
    current_user = 'provider_auth_policy_approver'
    AND session_user = current_user
    AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = current_user AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolinherit AND NOT rolreplication AND NOT rolbypassrls)
    AND NOT EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles granted ON granted.oid = m.roleid JOIN pg_roles member ON member.oid = m.member WHERE member.rolname = current_user OR granted.rolname = current_user)
    AND NOT EXISTS (
      SELECT 1
        FROM (VALUES ('provider_identities'), ('provider_auth_policy'), ('provider_auth_policy_cutover_runs'), ('provider_auth_policy_pending'), ('provider_auth_policy_grants')) AS t(table_name)
        CROSS JOIN (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) AS p(privilege_name)
       WHERE has_table_privilege(current_user, t.table_name, p.privilege_name)
    )
    AND has_function_privilege(current_user, 'approve_provider_auth_policy_exemption(uuid,text)'::regprocedure, 'EXECUTE')
    AND NOT has_function_privilege(current_user, 'request_provider_auth_policy_exemption(uuid,text,text,timestamp with time zone,text,text)'::regprocedure, 'EXECUTE')
    AND NOT has_function_privilege(current_user, 'seed_provider_auth_policy_cutover(timestamp with time zone,text[])'::regprocedure, 'EXECUTE')
  ) THEN
    RAISE EXCEPTION 'auth policy approve DSN does not map to the least-privilege approver role';
  END IF;
END
\$\$;
SQL
    psql_preflight_service auth_policy_cutover_preflight "$ONBOARDING_AUTH_POLICY_CUTOVER_DSN" <<SQL >/dev/null
DO \$\$
BEGIN
  IF NOT (
    current_user = 'provider_auth_policy_cutover'
    AND session_user = current_user
    AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = current_user AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolinherit AND NOT rolreplication AND NOT rolbypassrls)
    AND NOT EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles granted ON granted.oid = m.roleid JOIN pg_roles member ON member.oid = m.member WHERE member.rolname = current_user OR granted.rolname = current_user)
    AND NOT EXISTS (
      SELECT 1
        FROM (VALUES ('provider_identities'), ('provider_auth_policy'), ('provider_auth_policy_cutover_runs'), ('provider_auth_policy_pending'), ('provider_auth_policy_grants')) AS t(table_name)
        CROSS JOIN (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) AS p(privilege_name)
       WHERE has_table_privilege(current_user, t.table_name, p.privilege_name)
    )
    AND has_function_privilege(current_user, 'seed_provider_auth_policy_cutover(timestamp with time zone,text[])'::regprocedure, 'EXECUTE')
    AND NOT has_function_privilege(current_user, 'request_provider_auth_policy_exemption(uuid,text,text,timestamp with time zone,text,text)'::regprocedure, 'EXECUTE')
    AND NOT has_function_privilege(current_user, 'approve_provider_auth_policy_exemption(uuid,text)'::regprocedure, 'EXECUTE')
  ) THEN
    RAISE EXCEPTION 'auth policy cutover DSN does not map to the least-privilege cutover role';
  END IF;
END
\$\$;
SQL
    echo "  ok: auth-policy split DSN roles have expected EXECUTE privileges"
    psql_preflight_service hardware_trust_request_preflight "$ONBOARDING_HARDWARE_TRUST_REQUEST_DSN" <<SQL >/dev/null
DO \$\$
BEGIN
  IF NOT (
    current_user = 'hardware_trust_requester'
    AND session_user = current_user
    AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = current_user AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolinherit AND NOT rolreplication AND NOT rolbypassrls)
    AND NOT EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles granted ON granted.oid = m.roleid JOIN pg_roles member ON member.oid = m.member WHERE member.rolname = current_user OR granted.rolname = current_user)
    AND NOT EXISTS (
      SELECT 1
        FROM (VALUES ('hardware_trust_pending'), ('hardware_trust_grants'), ('hardware_verification_trust')) AS t(table_name)
        CROSS JOIN (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) AS p(privilege_name)
       WHERE has_table_privilege(current_user, t.table_name, p.privilege_name)
    )
    AND has_function_privilege(current_user, 'request_hardware_trust_approval(uuid,bigint,text,timestamp with time zone,text,text)'::regprocedure, 'EXECUTE')
    AND NOT has_function_privilege(current_user, 'approve_hardware_trust_approval(uuid,text)'::regprocedure, 'EXECUTE')
    AND NOT has_function_privilege(current_user, 'revoke_hardware_trust_approval(uuid,text,text,text,text)'::regprocedure, 'EXECUTE')
  ) THEN
    RAISE EXCEPTION 'hardware trust request DSN does not map to the least-privilege requester role';
  END IF;
END
\$\$;
SQL
    psql_preflight_service hardware_trust_approve_preflight "$ONBOARDING_HARDWARE_TRUST_APPROVE_DSN" <<SQL >/dev/null
DO \$\$
BEGIN
  IF NOT (
    current_user = 'hardware_trust_approver'
    AND session_user = current_user
    AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = current_user AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolinherit AND NOT rolreplication AND NOT rolbypassrls)
    AND NOT EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles granted ON granted.oid = m.roleid JOIN pg_roles member ON member.oid = m.member WHERE member.rolname = current_user OR granted.rolname = current_user)
    AND NOT EXISTS (
      SELECT 1
        FROM (VALUES ('hardware_trust_pending'), ('hardware_trust_grants'), ('hardware_verification_trust')) AS t(table_name)
        CROSS JOIN (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) AS p(privilege_name)
       WHERE has_table_privilege(current_user, t.table_name, p.privilege_name)
    )
    AND has_function_privilege(current_user, 'approve_hardware_trust_approval(uuid,text)'::regprocedure, 'EXECUTE')
    AND has_function_privilege(current_user, 'revoke_hardware_trust_approval(uuid,text,text,text,text)'::regprocedure, 'EXECUTE')
    AND NOT has_function_privilege(current_user, 'request_hardware_trust_approval(uuid,bigint,text,timestamp with time zone,text,text)'::regprocedure, 'EXECUTE')
  ) THEN
    RAISE EXCEPTION 'hardware trust approve DSN does not map to the least-privilege approver role';
  END IF;
END
\$\$;
SQL
    echo "  ok: hardware-trust split DSN roles have expected EXECUTE privileges"
    verifier_env=/etc/macprovider-stats/stats-hardware-verifier.env
    # FIX 8 (issue #582): reaching here means hardware-trust approval is enabled
    # (ONBOARDING_HARDWARE_TRUST_REQUEST_DSN/APPROVE_DSN are required above), so
    # the stats-hardware-verifier that PROMOTES approved waiting_trust jobs must
    # be provisioned too. Without its env the verifier timer is left disabled
    # (see step 9's `[ -f "$verifier_env" ]` enable gate), so an operator
    # approval commits a trust root that NO timer ever promotes to verified.
    # Fail closed rather than shipping a coordinator that accepts approvals it
    # can never fulfil.
    if [ ! -f "$verifier_env" ]; then
      echo "aborting deploy: hardware-trust approval DSNs are configured but $verifier_env is absent." >&2
      echo "  The stats-hardware-verifier timer is what promotes approved waiting_trust jobs;" >&2
      echo "  without its env the approval path commits trust roots that never promote to verified." >&2
      echo "  Provision /etc/macprovider-stats/stats-hardware-verifier.env before deploying." >&2
      exit 12
    fi
    if grep -Eq "REPLACE_ME|<generated-password>" "$verifier_env"; then
      echo "aborting deploy: stats-hardware-verifier.env still contains placeholder secret material" >&2
      exit 12
    fi
    STATS_HARDWARE_VERIFIER_DSN="$(require_env_value "$verifier_env" STATS_HARDWARE_VERIFIER_DSN)"
    # FIX 7 (issue #582): assert the verifier DSN maps to the exact
    # stats_hardware_verifier promotion role (current_user/session_user) AND holds
    # the write grants it needs to PROMOTE approved jobs — UPDATE on
    # hardware_verification_jobs and INSERT/UPDATE on provider_hardware_profiles.
    # A SELECT-only check would pass a mis-provisioned DSN that can never promote,
    # so operator approvals would commit trust roots the verifier can never fulfil.
    #
    # FIX 3 (round-6 regression fix, issue #582): two round-6 assertions rejected a
    # CORRECTLY-provisioned verifier:
    #   1. The `NOT rolinherit` (NOINHERIT) check — roles default INHERIT and neither
    #      migration 008 nor the verifier bootstrap ever sets NOINHERIT on
    #      stats_hardware_verifier, so the assertion always failed. Dropped (nothing
    #      provisions NOINHERIT for this role; the other role attributes still pin
    #      least privilege).
    #   2. Table-level has_table_privilege(...,'UPDATE'/'INSERT'). The verifier's
    #      write grants are intentionally COLUMN-scoped (migration 008 grants
    #      UPDATE(status,processed_at,decision_reason) on hardware_verification_jobs
    #      and INSERT/UPDATE on specific provider_hardware_profiles columns).
    #      has_table_privilege does NOT see column-only grants, so it wrongly
    #      reported "no privilege". Validate the exact granted columns with
    #      has_column_privilege instead (status on the jobs table, verified on the
    #      profiles table — both required to promote a job to verified).
    psql_preflight_service hardware_verifier_preflight "$STATS_HARDWARE_VERIFIER_DSN" <<SQL >/dev/null
DO \$\$
BEGIN
  IF NOT (
    current_user = 'stats_hardware_verifier'
    AND session_user = current_user
    AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = current_user AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolreplication AND NOT rolbypassrls)
    AND has_schema_privilege(current_user, 'public', 'USAGE')
    AND has_table_privilege(current_user, 'hardware_verification_jobs', 'SELECT')
    AND has_table_privilege(current_user, 'hardware_verification_trust', 'SELECT')
    AND has_table_privilege(current_user, 'chip_hardware_profiles', 'SELECT')
    AND has_table_privilege(current_user, 'provider_hardware_profiles', 'SELECT')
    -- FIX 5 (round-8, issue #582): assert the FULL column write surface the verifier
    -- actually writes across promoteJob/waitTrustJob/rejectJob
    -- (internal/stats/hardwareverify/verify.go), not just status+verified. A partial
    -- check would pass a DSN missing (e.g.) processed_at or last_reported_at that then
    -- fails the FIRST time the verifier tries to finalize a job, after operators have
    -- already committed approvals. Cross-checked against migration 008's grants.
    -- hardware_verification_jobs: UPDATE(status, processed_at, decision_reason).
    AND has_column_privilege(current_user, 'hardware_verification_jobs', 'status', 'UPDATE')
    AND has_column_privilege(current_user, 'hardware_verification_jobs', 'processed_at', 'UPDATE')
    AND has_column_privilege(current_user, 'hardware_verification_jobs', 'decision_reason', 'UPDATE')
    -- provider_hardware_profiles: INSERT(provider_id, chip, chip_normalized,
    -- unified_memory_gb, macos_version, app_version, source, verified, last_reported_at).
    AND has_column_privilege(current_user, 'provider_hardware_profiles', 'provider_id', 'INSERT')
    AND has_column_privilege(current_user, 'provider_hardware_profiles', 'chip', 'INSERT')
    AND has_column_privilege(current_user, 'provider_hardware_profiles', 'chip_normalized', 'INSERT')
    AND has_column_privilege(current_user, 'provider_hardware_profiles', 'unified_memory_gb', 'INSERT')
    AND has_column_privilege(current_user, 'provider_hardware_profiles', 'macos_version', 'INSERT')
    AND has_column_privilege(current_user, 'provider_hardware_profiles', 'app_version', 'INSERT')
    AND has_column_privilege(current_user, 'provider_hardware_profiles', 'source', 'INSERT')
    AND has_column_privilege(current_user, 'provider_hardware_profiles', 'verified', 'INSERT')
    AND has_column_privilege(current_user, 'provider_hardware_profiles', 'last_reported_at', 'INSERT')
    -- provider_hardware_profiles: UPDATE(chip, chip_normalized, unified_memory_gb,
    -- macos_version, app_version, source, verified, last_reported_at) — the ON CONFLICT
    -- DO UPDATE set. provider_id is the conflict key and is not in the UPDATE set.
    AND has_column_privilege(current_user, 'provider_hardware_profiles', 'chip', 'UPDATE')
    AND has_column_privilege(current_user, 'provider_hardware_profiles', 'chip_normalized', 'UPDATE')
    AND has_column_privilege(current_user, 'provider_hardware_profiles', 'unified_memory_gb', 'UPDATE')
    AND has_column_privilege(current_user, 'provider_hardware_profiles', 'macos_version', 'UPDATE')
    AND has_column_privilege(current_user, 'provider_hardware_profiles', 'app_version', 'UPDATE')
    AND has_column_privilege(current_user, 'provider_hardware_profiles', 'source', 'UPDATE')
    AND has_column_privilege(current_user, 'provider_hardware_profiles', 'verified', 'UPDATE')
    AND has_column_privilege(current_user, 'provider_hardware_profiles', 'last_reported_at', 'UPDATE')
  ) THEN
    RAISE EXCEPTION 'verifier DSN does not map to the stats_hardware_verifier promotion role with required write grants';
  END IF;
END
\$\$;
SELECT 1 FROM hardware_verification_jobs LIMIT 1;
SELECT 1 FROM hardware_verification_trust LIMIT 1;
SELECT 1 FROM chip_hardware_profiles LIMIT 1;
SQL
    echo "  ok: stats_hardware_verifier role identity + promotion write grants verified"
REMOTE_ONBOARDING_PREFLIGHT
else
  echo "  onboarding.app_track_register_enabled is not true — skipping hardware evidence migration preflight"
fi

# Issue #582 MIGRATION-019 UNIVERSAL SCHEMA GATE (ALL deploy paths) — couple the
# new 3-column stats-inventory-sync binary to the migration-019 schema it needs.
#
# The new stats-inventory-sync binary is installed on EVERY deploy (step 4) and
# its timer is re-enabled in step 9, regardless of onboarding. Its
# trusted_hardware reconciliation upserts hardware_verification_trust with a
# 3-column `ON CONFLICT (provider_id, hardware_identity_hash, source)`, which
# requires migration 019 (the `source` column + the 3-column PRIMARY KEY). On the
# ONBOARDING path the preflight above already auto-applied 019 via the
# coordinator's stats-migrate, so this gate is a satisfied no-op there. But that
# auto-apply is gated on ONBOARDING_ENABLED_LOCAL=true — on a NON-onboarding
# deploy NOTHING applies 019, so a DB still at migration 017 would get the new
# 3-column binary installed and its timer re-enabled while the schema lacks the
# `source` column / 3-column PK. The reconciliation then fails ("no unique or
# exclusion constraint matching the ON CONFLICT specification"), and because the
# initial sidecar run is warning-only (step 9) the deploy would COMPLETE with
# trust-inventory sync silently broken.
#
# This gate runs unconditionally (OUTSIDE the onboarding `if`), AFTER the
# onboarding auto-apply and BEFORE the unconditional sidecar-binary install /
# timer re-enable, and HARD-ABORTS (exit 12) when the sidecar's trusted_hardware
# reconciliation is configured — its .timer would be re-enabled in step 9
# (stats-hardware-inventory.yaml + stats-inventory-sync.env both present) and a
# STATS_TRUST_INVENTORY_DSN is set — yet the live schema does not already have
# 019's shape. Fail-closed: never install/re-enable the 3-column sidecar against a
# pre-019 schema. The check is READ-ONLY: it uses the sidecar's own
# STATS_TRUST_INVENTORY_DSN (the exact DSN the trust reconciliation connects with;
# it holds privileges on hardware_verification_trust and can read
# information_schema / pg_catalog), read from the env file as DATA (never sourced)
# and passed to psql via a root-only PGSERVICEFILE so no password appears in `ps`
# — mirroring the onboarding preflight's psql_preflight_service. The remedy on a
# bare deploy is `coordinator stats-migrate` (the onboarding path runs it
# automatically); then re-run this deploy.
log "step 3a2/9: stats-inventory-sync migration-019 schema gate (all deploy paths)"
$SSH "bash -s" <<'REMOTE_STATS_019_GATE'
    set -eu
    inventory_yaml=/etc/macprovider-stats/stats-hardware-inventory.yaml
    inventory_env=/etc/macprovider-stats/stats-inventory-sync.env
    # The sidecar timer is only re-enabled in step 9 when BOTH the inventory YAML
    # and its env file are present. If either is absent the sidecar never runs, so
    # its 019 dependency cannot bite — the gate is not applicable.
    if [ ! -f "$inventory_yaml" ] || [ ! -f "$inventory_env" ]; then
      echo "  ok: stats-inventory-sync not enabled (missing inventory yaml/env) — migration-019 schema gate not applicable"
      exit 0
    fi
    if ! command -v psql >/dev/null 2>&1; then
      echo "aborting deploy: psql is required for the stats-inventory-sync migration-019 schema gate" >&2
      exit 12
    fi
    if ! command -v python3 >/dev/null 2>&1; then
      echo "aborting deploy: python3 is required for the stats-inventory-sync migration-019 schema gate" >&2
      exit 12
    fi
    # The REAL trigger for trust reconciliation — and therefore for this gate — is
    # whether the inventory YAML DECLARES a trusted_hardware section, NOT whether a
    # DSN happens to be set. Mirror the sidecar's UnmarshalYAML "omitted vs explicit
    # {}" contract (cmd/stats-inventory-sync/main.go): an OMITTED top-level
    # `trusted_hardware` key leaves every trust root untouched (no-op); a PRESENT key
    # — INCLUDING an explicit `trusted_hardware: {}` revoke-all, or a bare null — makes
    # the sidecar reconcile trust and REQUIRES both STATS_TRUST_INVENTORY_DSN and the
    # 019 schema. Key the gate's applicability on that presence: if trusted_hardware is
    # declared, the deploy must be able to actually perform the reconciliation, else
    # step 9 re-enables a sidecar whose reconciliation fails permanently (warning-only)
    # and the deploy completes silently broken.
    #
    # Detect presence with a real YAML parser (PyYAML), never a sed/grep-for-structure
    # hand-parse. PyYAML is not guaranteed on the VPS and the file could be malformed,
    # so FAIL CLOSED: only a cleanly-parsed mapping that PROVABLY lacks the key is
    # treated as omitted (no-op). Missing parser, unreadable/unparseable YAML, a
    # non-mapping document, or any unexpected error all mean we cannot prove omission —
    # treat trust reconciliation as declared (require DSN+019) rather than risk the
    # silent break.
    #   exit 0 => trusted_hardware PRESENT (or presence could not be disproven; fail-closed)
    #   exit 1 => trusted_hardware PROVABLY OMITTED (cleanly-parsed mapping without the key)
    trusted_hardware_present() {
      TH_YAML_FILE="$1" python3 <<'PY'
import os
import sys

path = os.environ["TH_YAML_FILE"]
try:
    try:
        import yaml
    except ImportError:
        sys.stderr.write(
            "PyYAML unavailable; cannot prove trusted_hardware is omitted in %s "
            "— assuming present (fail-closed)\n" % path
        )
        sys.exit(0)
    try:
        with open(path, "r", encoding="utf-8") as f:
            doc = yaml.safe_load(f)
    except (OSError, yaml.YAMLError) as exc:
        sys.stderr.write(
            "cannot parse %s to determine trusted_hardware presence: %s "
            "— assuming present (fail-closed)\n" % (path, exc)
        )
        sys.exit(0)
    if isinstance(doc, dict) and "trusted_hardware" in doc:
        # Present incl. explicit {} (revoke-all) or null => reconciliation declared.
        sys.exit(0)
    if isinstance(doc, dict):
        # Cleanly-parsed mapping WITHOUT the key => provably omitted => gate no-op.
        sys.exit(1)
    sys.stderr.write(
        "%s is not a YAML mapping; cannot prove trusted_hardware is omitted "
        "— assuming present (fail-closed)\n" % path
    )
    sys.exit(0)
except SystemExit:
    raise
except Exception as exc:  # never let an unexpected error read as "omitted"
    sys.stderr.write(
        "unexpected error determining trusted_hardware presence in %s: %s "
        "— assuming present (fail-closed)\n" % (path, exc)
    )
    sys.exit(0)
PY
    }
    trusted_hardware_present_rc=0
    trusted_hardware_present "$inventory_yaml" || trusted_hardware_present_rc=$?
    if [ "$trusted_hardware_present_rc" -eq 1 ]; then
      echo "  ok: inventory declares no trusted_hardware section (key omitted) — sidecar performs no trust reconciliation; migration-019 schema gate is a no-op"
      exit 0
    fi
    if [ "$trusted_hardware_present_rc" -ne 0 ]; then
      # Defensive: the parser only emits 0 (present/fail-closed) or 1 (omitted).
      # Any other rc means it could not decide — fail closed.
      echo "aborting deploy: could not determine whether $inventory_yaml declares a trusted_hardware section (rc=$trusted_hardware_present_rc)" >&2
      exit 12
    fi
    # trusted_hardware IS declared (present, or presence could not be disproven): the
    # sidecar will reconcile trust, so the deploy MUST be able to perform it — both a
    # trust DSN and the 019 schema are now REQUIRED.
    # Read the sidecar's own trust DSN from its env file as DATA (never sourced).
    read_env_value() {
      ENV_VALUE_FILE="$1" ENV_VALUE_NAME="$2" python3 <<'PY'
import os
import re
import shlex
import sys

path = os.environ["ENV_VALUE_FILE"]
want = os.environ["ENV_VALUE_NAME"]
if not re.fullmatch(r"[A-Z_][A-Z0-9_]*", want):
    print("invalid requested env var name", file=sys.stderr)
    sys.exit(2)

found = False
parsed_value = ""
try:
    with open(path, "r", encoding="utf-8") as f:
        for lineno, raw in enumerate(f, 1):
            if raw.endswith("\n"):
                raw = raw[:-1]
            if raw.endswith("\r"):
                print(f"{path}:{lineno}: CRLF env files are not supported", file=sys.stderr)
                sys.exit(2)
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                print(f"{path}:{lineno}: malformed env assignment", file=sys.stderr)
                sys.exit(2)
            key, value = line.split("=", 1)
            key = key.strip()
            if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
                print(f"{path}:{lineno}: malformed env var name", file=sys.stderr)
                sys.exit(2)
            if key != want:
                continue
            try:
                parts = shlex.split(value.strip(), comments=False, posix=True)
            except ValueError as exc:
                print(f"{path}:{lineno}: malformed env value for {want}: {exc}", file=sys.stderr)
                sys.exit(2)
            if len(parts) != 1:
                print(f"{path}:{lineno}: env value for {want} must be a single token", file=sys.stderr)
                sys.exit(2)
            parsed = parts[0]
            if any(ch in parsed for ch in "\r\n\0"):
                print(f"{path}:{lineno}: env value for {want} contains an invalid character", file=sys.stderr)
                sys.exit(2)
            found = True
            parsed_value = parsed
except OSError as exc:
    print(f"cannot read env file {path}: {exc}", file=sys.stderr)
    sys.exit(2)

if found:
    print(parsed_value, end="")
    sys.exit(0)
sys.exit(1)
PY
    }
    # Distinguish read_env_value's three outcomes. trusted_hardware is DECLARED at
    # this point, so a clean-absent DSN is no longer a "no trust reconciliation" no-op
    # — it is a hard error (reconciliation would fail permanently). A parse error must
    # still never be mistaken for a clean-absent DSN.
    #   exit 0 => STATS_TRUST_INVENTORY_DSN present (value on stdout)
    #   exit 1 => cleanly absent (missing DSN while trusted_hardware is declared => abort)
    #   exit 2 => the env file could not be parsed to decide (malformed line, etc.)
    trust_dsn=""
    trust_dsn_rc=0
    trust_dsn="$(read_env_value "$inventory_env" STATS_TRUST_INVENTORY_DSN)" || trust_dsn_rc=$?
    if [ "$trust_dsn_rc" -ne 0 ] && [ "$trust_dsn_rc" -ne 1 ]; then
      # Parse/malformed error (exit 2) — or any other unexpected nonzero. FAIL CLOSED:
      # a malformed unrelated line (that systemd itself tolerates) could hide a valid
      # STATS_TRUST_INVENTORY_DSN, so we cannot safely conclude the sidecar has no 019
      # dependency. Refusing to deploy is the only safe option.
      echo "aborting deploy: $inventory_env could not be parsed to determine STATS_TRUST_INVENTORY_DSN (read_env_value rc=$trust_dsn_rc);" >&2
      echo "  the stats-inventory-sync sidecar / migration-019 schema coupling cannot be safely verified — fix the env file before deploying." >&2
      exit 12
    fi
    if [ "$trust_dsn_rc" -eq 1 ] || [ -z "$trust_dsn" ]; then
      # trusted_hardware is DECLARED (present) but STATS_TRUST_INVENTORY_DSN is
      # cleanly absent or explicitly empty. Step 9 will still re-enable the sidecar
      # timer, and its trusted_hardware reconciliation (including an explicit {}
      # revoke-all) will then fail PERMANENTLY for want of the trust DSN — and because
      # that initial failure is warning-only, the deploy would complete silently
      # broken. Refuse: the trust DSN must be set before deploying.
      echo "aborting deploy: $inventory_yaml declares a trusted_hardware section but STATS_TRUST_INVENTORY_DSN is not set in $inventory_env." >&2
      echo "  The stats-inventory-sync sidecar would re-enable and then fail every trusted_hardware reconciliation permanently (warning-only, silently broken)." >&2
      echo "  Set STATS_TRUST_INVENTORY_DSN in $inventory_env (see stats-inventory-sync.env.example) before deploying." >&2
      exit 12
    fi
    service_file="$(umask 077 && mktemp)"
    trap 'rm -f "$service_file"' EXIT
    if ! PSQL_SERVICE_FILE="$service_file" PSQL_SERVICE_DSN="$trust_dsn" python3 <<'PY'
import os
import sys
from urllib.parse import parse_qsl, unquote, urlparse

path = os.environ["PSQL_SERVICE_FILE"]
dsn = os.environ["PSQL_SERVICE_DSN"]
parsed = urlparse(dsn)
if parsed.scheme not in ("postgres", "postgresql"):
    print("unsupported Postgres DSN scheme", file=sys.stderr)
    sys.exit(2)
values = {
    "host": parsed.hostname or "",
    "user": unquote(parsed.username or ""),
    "password": unquote(parsed.password or ""),
    "dbname": unquote(parsed.path[1:] if parsed.path.startswith("/") else parsed.path),
}
if parsed.port is not None:
    values["port"] = str(parsed.port)
for key, value in parse_qsl(parsed.query, keep_blank_values=True):
    values[key] = value
with open(path, "w", encoding="utf-8") as f:
    f.write("[stats_trust_019_gate]\n")
    for key, value in values.items():
        if any(ch in value for ch in "\r\n"):
            print("invalid newline in Postgres DSN value", file=sys.stderr)
            sys.exit(2)
        if value != "":
            f.write(key + "=" + value + "\n")
PY
    then
      echo "aborting deploy: could not parse STATS_TRUST_INVENTORY_DSN for the migration-019 schema gate" >&2
      exit 12
    fi
    # Read-only probe: assert 019's shape is already live before the new 3-column
    # sidecar binary is installed/re-enabled. Checks the `source` column via
    # information_schema.columns and the 3-column PRIMARY KEY via pg_constraint /
    # pg_attribute (pg_catalog is readable by any role; the trust role has
    # privileges on hardware_verification_trust so its columns are visible in
    # information_schema). ON_ERROR_STOP=1 turns a RAISE EXCEPTION into a nonzero exit.
    if ! PGSERVICEFILE="$service_file" PGSERVICE=stats_trust_019_gate psql -v ON_ERROR_STOP=1 -qAt <<'SQL' >/dev/null
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name = 'hardware_verification_trust'
       AND column_name = 'source'
  ) THEN
    RAISE EXCEPTION 'hardware_verification_trust.source column is absent (migration 019 not applied)';
  END IF;
  IF NOT EXISTS (
    SELECT 1
      FROM pg_constraint c
      JOIN pg_class t ON t.oid = c.conrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
     WHERE c.contype = 'p'
       AND n.nspname = 'public'
       AND t.relname = 'hardware_verification_trust'
       AND (
         SELECT array_agg(a.attname ORDER BY k.ord)
           FROM unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord)
           JOIN pg_attribute a
             ON a.attrelid = c.conrelid AND a.attnum = k.attnum
       ) = ARRAY['provider_id', 'hardware_identity_hash', 'source']::name[]
  ) THEN
    RAISE EXCEPTION 'hardware_verification_trust PRIMARY KEY is not (provider_id, hardware_identity_hash, source) (migration 019 not applied)';
  END IF;
END
$$;
SQL
    then
      echo "aborting deploy: the new stats-inventory-sync binary requires migration 019 (hardware_verification_trust.source column + 3-column PRIMARY KEY (provider_id, hardware_identity_hash, source)), but the live schema does not have it." >&2
      echo "  Apply it with 'coordinator stats-migrate' before deploying (the onboarding path auto-applies it), then re-run this deploy." >&2
      echo "  Refusing to install/re-enable the 3-column stats-inventory-sync sidecar against a pre-019 schema." >&2
      exit 12
    fi
    echo "  ok: migration 019 shape present (hardware_verification_trust.source + 3-column PRIMARY KEY); safe to install/re-enable the 3-column stats-inventory-sync binary"
REMOTE_STATS_019_GATE

log "step 3b/9: install TCP sysctl overrides"
if [ "${SKIP_TCP_TUNING:-0}" = "1" ]; then
  log "  SKIP_TCP_TUNING=1 set — skipping TCP sysctl overrides"
else
  [ -f "$TCP_SYSCTL" ] || { echo "missing required file: $TCP_SYSCTL" >&2; exit 1; }
  [ -f "$TCP_BBR_MODULES_LOAD" ] || { echo "missing required file: $TCP_BBR_MODULES_LOAD" >&2; exit 1; }
  TCP_SYSCTL_UNEXPECTED=$($SSH 'for path in /etc/sysctl.d/*macprovider*; do
    [ -e "$path" ] || continue
    [ "$(basename "$path")" = "99-macprovider-tcp.conf" ] && continue
    printf "%s\n" "$path"
  done
  exit 0')
  if [ -n "$TCP_SYSCTL_UNEXPECTED" ]; then
    log "  WARN: found unexpected macprovider sysctl artifacts on Pearl:"
    while IFS= read -r unexpected_sysctl; do
      [ -n "$unexpected_sysctl" ] || continue
      log "    $unexpected_sysctl"
    done <<EOF
$TCP_SYSCTL_UNEXPECTED
EOF
    log "  These are not managed by this deploy; consider removing after verifying they are stale."
  fi
  TCP_SYSCTL_TMP=$($SSH 'umask 077 && mktemp -d -t macprovider-tcp.XXXXXXXX') || {
    echo "failed to create remote TCP sysctl staging directory" >&2; exit 1;
  }
  case "$TCP_SYSCTL_TMP" in
    /tmp/macprovider-tcp.*) ;;
    *)
      echo "aborting deploy: TCP sysctl mktemp produced unexpected path: '$TCP_SYSCTL_TMP'" >&2
      exit 1
      ;;
  esac
  if ! $SCP "$TCP_SYSCTL" "$VPS_USER@$VPS_HOST:$TCP_SYSCTL_TMP/macprovider-tcp.conf"; then
    $SSH "rm -rf $TCP_SYSCTL_TMP" 2>/dev/null || true
    exit 1
  fi
  if ! $SCP "$TCP_BBR_MODULES_LOAD" "$VPS_USER@$VPS_HOST:$TCP_SYSCTL_TMP/tcp_bbr.conf"; then
    $SSH "rm -rf $TCP_SYSCTL_TMP" 2>/dev/null || true
    exit 1
  fi
  TCP_INPUT_MANIFEST_TMP="$(umask 077 && mktemp -t macprovider-tcp-inputs.XXXXXXXX)" || {
    echo "aborting deploy: mktemp failed for TCP input manifest" >&2
    $SSH "rm -rf $TCP_SYSCTL_TMP" 2>/dev/null || true
    exit 2
  }
  shasum -a 256 "$TCP_SYSCTL" | awk '{ print $1 "  macprovider-tcp.conf" }' >> "$TCP_INPUT_MANIFEST_TMP"
  shasum -a 256 "$TCP_BBR_MODULES_LOAD" | awk '{ print $1 "  tcp_bbr.conf" }' >> "$TCP_INPUT_MANIFEST_TMP"
  if ! $SCP "$TCP_INPUT_MANIFEST_TMP" "$VPS_USER@$VPS_HOST:$TCP_SYSCTL_TMP/tcp-inputs.sha256"; then
    $SSH "rm -rf $TCP_SYSCTL_TMP" 2>/dev/null || true
    exit 1
  fi
  if ! $SSH "cd $TCP_SYSCTL_TMP && shasum -a 256 -c tcp-inputs.sha256 >/dev/null"; then
    $SSH "rm -rf $TCP_SYSCTL_TMP" 2>/dev/null || true
    exit 1
  fi
  log "  TCP staged input digests OK"
  TCP_SYSCTL_RESULT=$($SSH "bash -s -- '$TCP_SYSCTL_TMP'" <<'REMOTE_TCP_SYSCTL'
    set -e
    tmp_dir="$1"
    tmp_conf="$tmp_dir/macprovider-tcp.conf"
    tmp_modules_load="$tmp_dir/tcp_bbr.conf"
    dst="/etc/sysctl.d/99-macprovider-tcp.conf"
    modules_load_dst="/etc/modules-load.d/tcp_bbr.conf"
    trap 'rm -rf "$tmp_dir"' EXIT

    fail_tcp_tuning_partial_apply() {
      echo "ABORT:   step 3b/9 failure — kernel TCP state may be partially mutated." >&2
      echo "         Rollback: sudo rm /etc/sysctl.d/99-macprovider-tcp.conf /etc/modules-load.d/tcp_bbr.conf && sudo sysctl --system" >&2
      echo "         Then investigate the failure above before re-running the deploy." >&2
      exit 10
    }

    kernel="$(uname -r)"
    if ! modprobe -n -v tcp_bbr >/dev/null 2>&1; then
      echo "ABORT: tcp_bbr kernel module is not available on $(hostname) (kernel $kernel)." >&2
      echo "       Install linux-modules-extra-$kernel or upgrade the kernel before deploying TCP tuning." >&2
      exit 10
    fi
    if ! modprobe tcp_bbr >/dev/null 2>&1; then
      echo "ABORT: tcp_bbr kernel module exists but failed to load on $(hostname) (kernel $kernel)." >&2
      exit 10
    fi

    expect_sysctl() {
      key="$1"
      expected="$2"
      actual="$(sysctl -n "$key" 2>/dev/null || true)"
      if [ "$actual" != "$expected" ]; then
        echo "ABORT: sysctl $key mismatch: expected $expected, got ${actual:-<unset>}" >&2
        return 1
      fi
      return 0
    }

    all_tcp_sysctls_applied() {
      while IFS='=' read -r key expected; do
        key="$(printf '%s' "$key" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
        expected="$(printf '%s' "$expected" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
        [ -n "$key" ] || continue
        [ "${key:0:1}" = "#" ] && continue
        expect_sysctl "$key" "$expected" || return 1
      done < "$tmp_conf"
      return 0
    }

    if [ -f /etc/sysctl.d/99-macprovider-tcp.conf ] &&
       [ -f /etc/modules-load.d/tcp_bbr.conf ] &&
       cmp -s "$tmp_conf" /etc/sysctl.d/99-macprovider-tcp.conf &&
       cmp -s "$tmp_modules_load" /etc/modules-load.d/tcp_bbr.conf &&
       all_tcp_sysctls_applied >/dev/null 2>&1; then
      echo "already"
      exit 0
    fi

    install -m 0644 -o root -g root "$tmp_conf" "$dst"
    # modules-load.d ensures tcp_bbr is loaded before systemd-sysctl at boot.
    install -m 0644 -o root -g root "$tmp_modules_load" "$modules_load_dst"
    if ! sysctl -p "$dst" >/dev/null; then
      echo "ABORT: failed to apply $dst" >&2
      fail_tcp_tuning_partial_apply
    fi

    if ! all_tcp_sysctls_applied; then
      fail_tcp_tuning_partial_apply
    fi
    if ! expect_sysctl net.ipv4.tcp_congestion_control bbr; then
      fail_tcp_tuning_partial_apply
    fi
    echo "applied"
REMOTE_TCP_SYSCTL
  )
  case "$TCP_SYSCTL_RESULT" in
    already)
      log "  TCP sysctl overrides — already applied"
      ;;
    applied)
      log "  TCP sysctl overrides applied: bbr + slow_start_after_idle=0 + 16MB buffers"
      ;;
    *)
      echo "unexpected TCP sysctl deploy result: $TCP_SYSCTL_RESULT" >&2
      exit 10
      ;;
  esac
fi

BACKUP_TS=$(date -u +%Y%m%dT%H%M%SZ)
log "step 4/9: upload binary + config + nginx site (with rollback snapshot)"
# Arm one coordinator release transaction before replacing any live file. The
# late connected-provider safeguard can still refuse the restart after upload;
# in that case the EXIT trap restores every release artifact touched after this
# boundary: coordinator/CLI/sidecar binaries, unit files and enablement links,
# nginx files, request-log ACLs, config, and catalog pointers.
$SSH "set -e
  exec 8>/opt/macprovider/.coordinator-deploy-operation.lock
  flock -s 8
  _rollback=/opt/macprovider/.coordinator-deploy-rollback
  _rollback_stage=\$_rollback.stage.\$\$
  umask 077
  if [ -e \"\$_rollback\" ] || [ -L \"\$_rollback\" ]; then
    echo 'coordinator deploy transaction already exists; refusing to overwrite it' >&2
    exit 1
  fi
  $(_tier2_migration_gate_remote_script)
  rm -rf \"\$_rollback_stage\"
  mkdir \"\$_rollback_stage\"
  trap 'rm -rf \"\$_rollback_stage\"' EXIT HUP INT TERM
  chown root:root \"\$_rollback_stage\"
  chmod 0700 \"\$_rollback_stage\"
  snapshot_node() {
    _source=\"\$1\"
    _snapshot=\"\$2\"
    _marker=\"\$3\"
    if [ -e \"\$_source\" ] || [ -L \"\$_source\" ]; then
      if [ ! -f \"\$_source\" ] && [ ! -L \"\$_source\" ]; then
        echo \"unsafe rollback source: \$_source\" >&2
        exit 1
      fi
      cp -a \"\$_source\" \"\$_rollback_stage/\$_snapshot\"
      touch \"\$_rollback_stage/\$_marker\"
    fi
  }
  snapshot_active() {
    if systemctl is-active --quiet \"\$1\"; then
      touch \"\$_rollback_stage/\$2\"
    fi
  }
  snapshot_acl() {
    _source=\"\$1\"
    _snapshot=\"\$2\"
    _marker=\"\$3\"
    if [ -e \"\$_source\" ]; then
      getfacl -p \"\$_source\" > \"\$_rollback_stage/\$_snapshot\"
      touch \"\$_rollback_stage/\$_marker\"
    fi
  }
  snapshot_node /opt/macprovider/coordinator.prev coordinator.prev had-coordinator-prev
  if [ -x /opt/macprovider/coordinator ]; then
    cp -p /opt/macprovider/coordinator \"\$_rollback_stage/coordinator\"
    touch \"\$_rollback_stage/had-coordinator\"
  fi
  snapshot_node /opt/macprovider/coordinator-cli coordinator-cli had-coordinator-cli
  snapshot_node /opt/macprovider/coordinator.yaml.prev coordinator.yaml.prev had-config-prev
  printf '%s' 'coordinator.yaml.bak-$BACKUP_TS' > \"\$_rollback_stage/config-backup-name\"
  snapshot_node /opt/macprovider/coordinator.yaml.bak-$BACKUP_TS coordinator-dated-backup had-config-dated-backup
  snapshot_node /etc/macprovider/coordinator.pearl-overlays.yaml coordinator.pearl-overlays.yaml had-overlay
  snapshot_node /etc/macprovider/coordinator.pearl-overlays.yaml.prev coordinator.pearl-overlays.yaml.prev had-overlay-prev
  printf '%s' 'coordinator.pearl-overlays.yaml.bak-$BACKUP_TS' > \"\$_rollback_stage/overlay-config-backup-name\"
  snapshot_node /etc/macprovider/coordinator.pearl-overlays.yaml.bak-$BACKUP_TS coordinator-overlay-dated-backup had-overlay-dated-backup
  snapshot_node /opt/macprovider-stats/stats-inventory-sync stats-inventory-sync had-stats-inventory-binary
  snapshot_node /opt/macprovider-stats/stats-billing-mirror stats-billing-mirror had-stats-billing-binary
  snapshot_node /opt/macprovider-stats/stats-hardware-verifier stats-hardware-verifier had-stats-hardware-binary
  if [ -f /opt/macprovider/coordinator.yaml ]; then
    cp -p /opt/macprovider/coordinator.yaml \"\$_rollback_stage/coordinator.yaml\"
    touch \"\$_rollback_stage/had-config\"
  fi
  if [ -L /opt/macprovider/tier2-catalog.json ] || { [ -e /opt/macprovider/tier2-catalog.json ] && [ ! -f /opt/macprovider/tier2-catalog.json ]; }; then
    echo 'unsafe existing Tier-2 catalog path' >&2
    exit 1
  fi
  if [ -f /opt/macprovider/tier2-catalog.json ]; then
    cp -p /opt/macprovider/tier2-catalog.json \"\$_rollback_stage/tier2-catalog.json\"
    touch \"\$_rollback_stage/had-tier2-catalog\"
  fi
  if [ -e /etc/systemd/system/macprovider-coordinator.service ] || [ -L /etc/systemd/system/macprovider-coordinator.service ]; then
    cp -a /etc/systemd/system/macprovider-coordinator.service \"\$_rollback_stage/macprovider-coordinator.service\"
    touch \"\$_rollback_stage/had-service-unit\"
  fi
  snapshot_node /etc/systemd/system/stats-inventory-sync.service stats-inventory-sync.service had-stats-inventory-service
  snapshot_node /etc/systemd/system/stats-inventory-sync.timer stats-inventory-sync.timer had-stats-inventory-timer
  snapshot_node /etc/systemd/system/stats-billing-mirror.service stats-billing-mirror.service had-stats-billing-service
  snapshot_node /etc/systemd/system/stats-billing-mirror.timer stats-billing-mirror.timer had-stats-billing-timer
  snapshot_node /etc/systemd/system/stats-hardware-verifier.service stats-hardware-verifier.service had-stats-hardware-service
  snapshot_node /etc/systemd/system/stats-hardware-verifier.timer stats-hardware-verifier.timer had-stats-hardware-timer
  snapshot_node /etc/systemd/system/timers.target.wants/stats-inventory-sync.timer stats-inventory-sync.wants had-stats-inventory-wants
  snapshot_node /etc/systemd/system/timers.target.wants/stats-billing-mirror.timer stats-billing-mirror.wants had-stats-billing-wants
  snapshot_node /etc/systemd/system/timers.target.wants/stats-hardware-verifier.timer stats-hardware-verifier.wants had-stats-hardware-wants
  snapshot_active stats-inventory-sync.timer stats-inventory-timer-was-active
  snapshot_active stats-inventory-sync.service stats-inventory-service-was-active
  snapshot_active stats-billing-mirror.timer stats-billing-timer-was-active
  snapshot_active stats-billing-mirror.service stats-billing-service-was-active
  snapshot_active stats-hardware-verifier.timer stats-hardware-timer-was-active
  snapshot_active stats-hardware-verifier.service stats-hardware-service-was-active

  snapshot_node /etc/nginx/conf.d/stats-shared.conf stats-shared.conf had-nginx-stats-shared
  snapshot_node /etc/nginx/conf.d/stats-security-headers.conf stats-security-headers.conf had-nginx-stats-security-headers
  snapshot_node /etc/nginx/conf.d/cors-429.conf cors-429.conf had-nginx-stats-cors-429
  snapshot_node /etc/nginx/conf.d/stats-proxy-public.conf stats-proxy-public.conf had-nginx-stats-proxy-public
  snapshot_node /etc/nginx/conf.d/stats-proxy-partner.conf stats-proxy-partner.conf had-nginx-stats-proxy-partner
  snapshot_node /etc/nginx/sites-available/$DOMAIN nginx-coordinator.site had-nginx-coordinator-site
  snapshot_node /etc/nginx/sites-available/$STATS_DOMAIN nginx-stats.site had-nginx-stats-site
  snapshot_node /etc/nginx/sites-enabled/$DOMAIN nginx-coordinator.enabled had-nginx-coordinator-enabled
  snapshot_node /etc/nginx/sites-enabled/$STATS_DOMAIN nginx-stats.enabled had-nginx-stats-enabled
  snapshot_node /etc/nginx/sites-available/$DOMAIN.full nginx-coordinator.full had-nginx-coordinator-full

  if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1; then
    snapshot_acl /var/lib/macprovider request-log-dir.acl had-request-log-dir-acl
    snapshot_acl /var/lib/macprovider/request-log.sqlite request-log-db.acl had-request-log-db-acl
    snapshot_acl /var/lib/macprovider/request-log.sqlite-wal request-log-wal.acl had-request-log-wal-acl
    snapshot_acl /var/lib/macprovider/request-log.sqlite-shm request-log-shm.acl had-request-log-shm-acl
  fi
  if [ -e /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service ] || [ -L /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service ]; then
    cp -a /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service \"\$_rollback_stage/macprovider-coordinator.wants\"
    touch \"\$_rollback_stage/had-wants-link\"
  fi
  if [ -e /opt/macprovider/coordinator-deploy-recover ] || [ -L /opt/macprovider/coordinator-deploy-recover ]; then
    cp -a /opt/macprovider/coordinator-deploy-recover \"\$_rollback_stage/coordinator-deploy-recover\"
    touch \"\$_rollback_stage/had-recovery-helper\"
  fi
  if [ -e /etc/systemd/system/macprovider-coordinator-deploy-recovery.service ] || [ -L /etc/systemd/system/macprovider-coordinator-deploy-recovery.service ]; then
    cp -a /etc/systemd/system/macprovider-coordinator-deploy-recovery.service \"\$_rollback_stage/macprovider-coordinator-deploy-recovery.service\"
    touch \"\$_rollback_stage/had-recovery-unit\"
  fi
  if [ -e /etc/systemd/system/macprovider-coordinator-deploy-watchdog.service ] || [ -L /etc/systemd/system/macprovider-coordinator-deploy-watchdog.service ]; then
    cp -a /etc/systemd/system/macprovider-coordinator-deploy-watchdog.service \"\$_rollback_stage/macprovider-coordinator-deploy-watchdog.service\"
    touch \"\$_rollback_stage/had-watchdog-unit\"
  fi
  if [ -e /etc/systemd/system/macprovider-coordinator.service.d/10-deploy-transaction-guard.conf ] || [ -L /etc/systemd/system/macprovider-coordinator.service.d/10-deploy-transaction-guard.conf ]; then
    cp -a /etc/systemd/system/macprovider-coordinator.service.d/10-deploy-transaction-guard.conf \"\$_rollback_stage/10-deploy-transaction-guard.conf\"
    touch \"\$_rollback_stage/had-guard-dropin\"
  fi
  _catalog_target=\$(readlink /opt/macprovider/autotune/current 2>/dev/null || true)
  case \"\$_catalog_target\" in
    ''|releases/*) ;;
    *) echo \"invalid existing autotune current target: \$_catalog_target\" >&2; exit 1 ;;
  esac
  printf '%s' \"\$_catalog_target\" > \"\$_rollback_stage/catalog-current-target\"
  if [ -f /opt/macprovider/autotune/.previous-target ]; then
    cp -p /opt/macprovider/autotune/.previous-target \"\$_rollback_stage/catalog-previous-target\"
    touch \"\$_rollback_stage/had-previous-target\"
  fi
  if [ ! -d /opt/macprovider/autotune/releases/$AUTOTUNE_RELEASE_DIR_NAME ]; then
    touch \"\$_rollback_stage/release-was-absent\"
  fi
  printf '%s' '$AUTOTUNE_RELEASE_DIR_NAME' > \"\$_rollback_stage/release-id\"
  if systemctl is-active --quiet macprovider-coordinator; then
    touch \"\$_rollback_stage/service-was-active\"
  fi
  touch \"\$_rollback_stage/complete\"
  mv \"\$_rollback_stage\" \"\$_rollback\"
  trap - EXIT HUP INT TERM"
COORDINATOR_DEPLOY_ARMED=1

# Freeze sidecar execution for the release window. Their binaries and units are
# transaction-owned, so allowing an old timer to fire after replacement could
# create non-rollbackable database effects before the catalog canary passes.
# NOTE: stats-inventory-sync is deliberately NOT in this loop — it is quiesced
# earlier (before the onboarding migration preflight) because migration 019
# makes the old inventory binary incompatible with the migrated schema, so it
# must be down before the migration is exercised, not merely before install.
$SSH 'set -eu
  exec 8>/opt/macprovider/.coordinator-deploy-operation.lock
  flock -s 8
  for unit in stats-billing-mirror.timer stats-billing-mirror.service stats-hardware-verifier.timer stats-hardware-verifier.service; do
    load_state=$(systemctl show -p LoadState --value "$unit")
    [ "$load_state" = not-found ] && continue
    systemctl stop "$unit"
    active_state=$(systemctl show -p ActiveState --value "$unit")
    case "$active_state" in
      inactive|failed) ;;
      *) echo "sidecar unit did not stop: $unit state=$active_state" >&2; exit 1 ;;
    esac
  done
'

# Issue #244 R5 SEC CRITICAL — stage uploaded artifacts into a fresh
# per-deploy root-owned 0700 directory instead of predictable /tmp/X
# names. Otherwise any local user (including a compromised macprovider
# UID) can race the SCP/install window and substitute their own
# systemd unit, binary, or nginx config — which root then installs.
# `mktemp -d` returns a fresh dir with mode 0700 owned by the SSH
# user (root). The wider /tmp permissions (1777) don't matter because
# the fresh subdir denies traversal.
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
$SSH "install -d -o root -g root -m 0700 $DEPLOY_TMP/scripts"

DEPLOY_INPUT_MANIFEST_TMP="$(umask 077 && mktemp -t macprovider-deploy-inputs.XXXXXXXX)" || {
  echo "aborting deploy: mktemp failed for deploy input manifest" >&2
  exit 2
}
_append_deploy_input_digest() {
  local source_path="$1" remote_name="$2"
  shasum -a 256 "$source_path" | awk -v name="$remote_name" '{ print $1 "  " name }' >> "$DEPLOY_INPUT_MANIFEST_TMP"
}
_append_deploy_input_digest "$BINARY" "coordinator-linux-amd64"
_append_deploy_input_digest "$CLI_BINARY" "coordinator-cli-linux-amd64"
_append_deploy_input_digest "$STATS_INVENTORY_BINARY" "stats-inventory-sync-linux-amd64"
_append_deploy_input_digest "$STATS_BILLING_MIRROR_BINARY" "stats-billing-mirror-linux-amd64"
_append_deploy_input_digest "$STATS_HARDWARE_VERIFIER_BINARY" "stats-hardware-verifier-linux-amd64"
if [ "$CONFIG_MODE" = "apply-tracked" ]; then
  _append_deploy_input_digest "$CONFIG" "coordinator.yaml"
elif [ "${RATE_CARD_CONFIG_MIGRATION_ACTIVE:-0}" = "1" ]; then
  _append_deploy_input_digest "$RATE_CARD_MIGRATED_CONFIG_TMP" "coordinator.rate-card-migration.yaml"
elif [ "$C2_TIMER_CONFIG_MIGRATION" = "1" ]; then
  _append_deploy_input_digest "$C2_TIMER_MIGRATED_CONFIG_TMP" "coordinator.c2-timer-migration.yaml"
fi
if [ "${RATE_CARD_MIGRATION_OVERLAY_ACTIVE:-0}" = "1" ]; then
  _append_deploy_input_digest "$RATE_CARD_MIGRATED_OVERLAY_TMP" "coordinator.pearl-overlays.rate-card-migration.yaml"
elif [ "${C2_TIMER_MIGRATION_OVERLAY_ACTIVE:-0}" = "1" ]; then
  _append_deploy_input_digest "$C2_TIMER_MIGRATED_OVERLAY_TMP" "coordinator.pearl-overlays.c2-timer-migration.yaml"
fi
for _deploy_input in \
  "$SERVICE=macprovider-coordinator.service" \
  "$STATS_INVENTORY_SERVICE=stats-inventory-sync.service" \
  "$STATS_INVENTORY_TIMER=stats-inventory-sync.timer" \
  "$STATS_BILLING_MIRROR_SERVICE=stats-billing-mirror.service" \
  "$STATS_BILLING_MIRROR_TIMER=stats-billing-mirror.timer" \
  "$STATS_HARDWARE_VERIFIER_SERVICE=stats-hardware-verifier.service" \
  "$STATS_HARDWARE_VERIFIER_TIMER=stats-hardware-verifier.timer" \
  "$NGINX_SITE=nginx-coordinator-full.conf" \
  "$NGINX_STATS_SHARED=nginx-stats-shared.conf" \
  "$NGINX_STATS_SECHEADERS=nginx-stats-security-headers.conf" \
  "$NGINX_STATS_CORS_429=nginx-stats-cors-429.conf" \
  "$NGINX_STATS_PROXY_PUBLIC=nginx-stats-proxy-public.conf" \
  "$NGINX_STATS_PROXY_PARTNER=nginx-stats-proxy-partner.conf" \
  "$NGINX_STATS_SITE=nginx-stats.streamvc.live.conf" \
  "$STATIC_DEMAND_JSON=demand-rank.json" \
  "$STATIC_DEMAND_SIG=demand-rank.json.sig" \
  "$STATIC_AUTOTUNE_JSON=autotune-candidates.json" \
  "$STATIC_AUTOTUNE_SIG=autotune-candidates.json.sig" \
  "$STATIC_RATE_CARD_JSON=rate-card.json" \
  "$STATIC_RATE_CARD_SIG=rate-card.json.sig" \
  "$AUTOTUNE_RELEASE_MANIFEST=release.json" \
  "$AUTOTUNE_TRUSTED_KEYS=trusted-keys.json" \
  "$AUTOTUNE_RELEASE_VERIFY=scripts/catalog-release.py" \
  "$AUTOTUNE_TIER2_VERIFIER=scripts/sign-catalog.go"; do
  _append_deploy_input_digest "${_deploy_input%%=*}" "${_deploy_input#*=}"
done
if [ -n "$CATALOG_REMOTE_PATH" ]; then
  _append_deploy_input_digest "$TMP_CATALOG_PINNED" "tier2-catalog.json"
  _append_deploy_input_digest "$TMP_CATALOG_PUBKEY" "tier2-catalog.pub"
else
  _append_deploy_input_digest "$AUTOTUNE_TIER2_JSON" "tier2-catalog.json"
fi

$SCP "$BINARY"      "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator-linux-amd64"
$SCP "$CLI_BINARY"  "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator-cli-linux-amd64"
$SCP "$STATS_INVENTORY_BINARY"  "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-inventory-sync-linux-amd64"
$SCP "$STATS_BILLING_MIRROR_BINARY" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror-linux-amd64"
$SCP "$STATS_HARDWARE_VERIFIER_BINARY" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-hardware-verifier-linux-amd64"
if [ "$CONFIG_MODE" = "apply-tracked" ]; then
  $SCP "$CONFIG" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator.yaml"
elif [ "${RATE_CARD_CONFIG_MIGRATION_ACTIVE:-0}" = "1" ]; then
  $SCP "$RATE_CARD_MIGRATED_CONFIG_TMP" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator.rate-card-migration.yaml"
elif [ "$C2_TIMER_CONFIG_MIGRATION" = "1" ]; then
  $SCP "$C2_TIMER_MIGRATED_CONFIG_TMP" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator.c2-timer-migration.yaml"
else
  log "  CONFIG_MODE=preserve-live — not uploading tracked coordinator.yaml"
fi
if [ "${RATE_CARD_MIGRATION_OVERLAY_ACTIVE:-0}" = "1" ]; then
  $SCP "$RATE_CARD_MIGRATED_OVERLAY_TMP" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator.pearl-overlays.rate-card-migration.yaml"
elif [ "${C2_TIMER_MIGRATION_OVERLAY_ACTIVE:-0}" = "1" ]; then
  $SCP "$C2_TIMER_MIGRATED_OVERLAY_TMP" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator.pearl-overlays.c2-timer-migration.yaml"
fi
$SCP "$SERVICE"     "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/macprovider-coordinator.service"
$SCP "$STATS_INVENTORY_SERVICE" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-inventory-sync.service"
$SCP "$STATS_INVENTORY_TIMER"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-inventory-sync.timer"
$SCP "$STATS_BILLING_MIRROR_SERVICE" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror.service"
$SCP "$STATS_BILLING_MIRROR_TIMER"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror.timer"
$SCP "$STATS_HARDWARE_VERIFIER_SERVICE" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-hardware-verifier.service"
$SCP "$STATS_HARDWARE_VERIFIER_TIMER"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-hardware-verifier.timer"
$SCP "$NGINX_SITE"  "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-coordinator-full.conf"
# SPEC-017 v0.1.8 Step 4.B artifacts (snippet must land at
# /etc/nginx/conf.d/ so the http-context declarations are visible
# to BOTH the coordinator vhost (for /v1/stats/* allow-through)
# and the stats vhost. Installation step below is wired BEFORE
# the coordinator vhost full-TLS install so `nginx -t` does not
# trip on missing zone names.).
$SCP "$NGINX_STATS_SHARED"     "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-stats-shared.conf"
$SCP "$NGINX_STATS_SECHEADERS" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-stats-security-headers.conf"
$SCP "$NGINX_STATS_CORS_429"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-stats-cors-429.conf"
$SCP "$NGINX_STATS_PROXY_PUBLIC"  "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-stats-proxy-public.conf"
$SCP "$NGINX_STATS_PROXY_PARTNER" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-stats-proxy-partner.conf"
$SCP "$NGINX_STATS_SITE"       "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-stats.streamvc.live.conf"
# SPEC-023 v1.7.3 signed static feeds
$SCP "$STATIC_DEMAND_JSON"     "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/demand-rank.json"
$SCP "$STATIC_DEMAND_SIG"      "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/demand-rank.json.sig"
$SCP "$STATIC_AUTOTUNE_JSON"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/autotune-candidates.json"
$SCP "$STATIC_AUTOTUNE_SIG"    "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/autotune-candidates.json.sig"
$SCP "$STATIC_RATE_CARD_JSON"  "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/rate-card.json"
$SCP "$STATIC_RATE_CARD_SIG"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/rate-card.json.sig"
$SCP "$AUTOTUNE_RELEASE_MANIFEST" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/release.json"
$SCP "$AUTOTUNE_TRUSTED_KEYS"     "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/trusted-keys.json"
$SCP "$AUTOTUNE_TIER2_JSON"       "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/tier2-catalog.json"
$SCP "$AUTOTUNE_RELEASE_VERIFY"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/scripts/catalog-release.py"
$SCP "$AUTOTUNE_TIER2_VERIFIER"  "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/scripts/sign-catalog.go"
if [ -n "$CATALOG_REMOTE_PATH" ]; then
  if [ -z "${TMP_CATALOG_PINNED:-}" ] || [ ! -f "$TMP_CATALOG_PINNED" ]; then
    echo "aborting deploy: pinned Tier-2 catalog snapshot missing before upload" >&2
    exit 5
  fi
  UPLOAD_CATALOG_SHA="$(shasum -a 256 "$TMP_CATALOG_PINNED" | awk '{print $1}')"
  if [ "$UPLOAD_CATALOG_SHA" != "$CATALOG_PIN_SHA" ]; then
    echo "aborting deploy: pinned Tier-2 catalog digest changed before upload ($UPLOAD_CATALOG_SHA != $CATALOG_PIN_SHA)" >&2
    exit 5
  fi
  $SCP "$TMP_CATALOG_PINNED" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/tier2-catalog.json"
  $SCP "$TMP_CATALOG_PUBKEY" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/tier2-catalog.pub"
fi
$SCP "$DEPLOY_INPUT_MANIFEST_TMP" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/deploy-inputs.sha256"
$SSH "cd $DEPLOY_TMP && shasum -a 256 -c deploy-inputs.sha256 >/dev/null"
echo "  staged deploy input digests OK"

if [ "$CONFIG_MODE" = "apply-tracked" ] || [ "$C2_TIMER_CONFIG_MIGRATION" = "1" ] || [ "${RATE_CARD_CONFIG_MIGRATION_ACTIVE:-0}" = "1" ] || [ "${RATE_CARD_MIGRATION_OVERLAY_ACTIVE:-0}" = "1" ]; then
  # M1-6 / DEVE-5 Part D: dated backup of the remote coordinator.yaml on Pearl
  # BEFORE we overwrite it. Step 1b already aborted on drift, but the audit
  # also calls for a persistent remote-side backup so a bad deploy can be
  # inspected/reverted without trusting the operator's local copy. Backups live
  # next to the live config at /opt/macprovider/coordinator.yaml.bak-<UTC>.
  $SSH "exec 8>/opt/macprovider/.coordinator-deploy-operation.lock
        flock -s 8
        if [ -f /opt/macprovider/coordinator.yaml ]; then
          install -o root -g macprovider -m 0640 /opt/macprovider/coordinator.yaml /opt/macprovider/coordinator.yaml.prev
          install -o root -g macprovider -m 0640 /opt/macprovider/coordinator.yaml /opt/macprovider/coordinator.yaml.bak-$BACKUP_TS
          echo '  remote-config backup saved at /opt/macprovider/coordinator.yaml.bak-$BACKUP_TS'
        else
          echo '  no live coordinator.yaml — first deploy, skipping backup'
        fi
        if [ '${C2_TIMER_MIGRATION_OVERLAY_ACTIVE:-0}' = '1' ] || [ '${RATE_CARD_MIGRATION_OVERLAY_ACTIVE:-0}' = '1' ]; then
          install -d -o root -g macprovider -m 0750 /etc/macprovider
          if [ -f /etc/macprovider/coordinator.pearl-overlays.yaml ]; then
            install -o root -g macprovider -m 0640 /etc/macprovider/coordinator.pearl-overlays.yaml /etc/macprovider/coordinator.pearl-overlays.yaml.prev
            install -o root -g macprovider -m 0640 /etc/macprovider/coordinator.pearl-overlays.yaml /etc/macprovider/coordinator.pearl-overlays.yaml.bak-$BACKUP_TS
            echo '  remote-overlay backup saved at /etc/macprovider/coordinator.pearl-overlays.yaml.bak-$BACKUP_TS'
          fi
        fi"
else
  log "  CONFIG_MODE=preserve-live — skipping coordinator.yaml backup because no config overwrite will occur"
fi

$SSH "set -e
  exec 8>/opt/macprovider/.coordinator-deploy-operation.lock
  flock -s 8
  # R5 SEC MED — deploy artifacts owned root:macprovider with group-read
  # rather than macprovider:macprovider. This prevents a compromised
  # macprovider UID from persistently rewriting its own executable /
  # config / cli. The daemon runs as macprovider; group=macprovider +
  # mode 0750 (binary/cli) and 0640 (config) give it the needed
  # read/execute access.
  # The signed Pearl updater is the sole authority for the coordinator/gateway
  # runtime pair. This catalog/config deployment may restart that installed
  # pair, but must not create a mixed release by replacing only coordinator.
  if [ ! -x /opt/macprovider/coordinator ] || ! cmp -s $DEPLOY_TMP/coordinator-linux-amd64 /opt/macprovider/coordinator; then
    echo 'refusing coordinator-only replacement: install the signed coordinator/gateway pair with macprovider-pearl-update first' >&2
    echo '  preflight the selected Pearl runtime release with scripts/verify-pearl-runtime-release.sh before retrying direct deploy' >&2
    exit 1
  fi
  # coordinator-cli is operator-facing, but remains part of the same release
  # and therefore has an exact durable snapshot like the daemon binary.
  if [ ! -x /opt/macprovider/coordinator-cli ] || ! cmp -s $DEPLOY_TMP/coordinator-cli-linux-amd64 /opt/macprovider/coordinator-cli; then
    echo 'refusing coordinator-cli replacement from direct deploy: install the signed matching Pearl runtime release first' >&2
    exit 1
  fi
  install -o root -g macprovider -m 0750 $DEPLOY_TMP/coordinator-cli-linux-amd64 /opt/macprovider/coordinator-cli
  # stats-inventory-sync is an operator sidecar, not a coordinator child.
  # It runs under its own Unix identity and only receives execute access
  # to this binary; its Postgres writer DSN lives under /etc/macprovider-stats.
  # A pre-existing parity hold belongs to an earlier coordinator release. A
  # catalog-only deploy may carry the live binary through byte-for-byte, but it
  # must not silently promote a different sidecar before the signed matching
  # coordinator/sidecar release does so.
  if [ ! -r /opt/macprovider/.coordinator-deploy-sidecar-prior-state ]; then
    echo "refusing stats-inventory sidecar install: missing pre-quiesce parity state" >&2
    exit 1
  elif grep -qx "parity_required=present" /opt/macprovider/.coordinator-deploy-sidecar-prior-state; then
    if [ ! -x /opt/macprovider-stats/stats-inventory-sync ] ||
       ! cmp -s $DEPLOY_TMP/stats-inventory-sync-linux-amd64 /opt/macprovider-stats/stats-inventory-sync; then
      echo "refusing parity-held stats-inventory sidecar replacement: install the signed matching coordinator/sidecar release first" >&2
      exit 1
    fi
  elif ! grep -qx "parity_required=absent" /opt/macprovider/.coordinator-deploy-sidecar-prior-state; then
    echo "refusing stats-inventory sidecar install: invalid pre-quiesce parity state" >&2
    exit 1
  elif [ ! -x /opt/macprovider-stats/stats-inventory-sync ] ||
       ! cmp -s $DEPLOY_TMP/stats-inventory-sync-linux-amd64 /opt/macprovider-stats/stats-inventory-sync; then
    echo "refusing stats-inventory sidecar replacement from direct deploy: install the signed matching stats sidecar release first" >&2
    exit 1
  fi
  install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-inventory-sync-linux-amd64 /opt/macprovider-stats/stats-inventory-sync
  # stats-billing-mirror is an out-of-band stats sidecar. It runs as the
  # dedicated macprovider-stats identity and gets read access only to the
  # SQLite ledger files via file ACLs below.
  if [ ! -x /opt/macprovider-stats/stats-billing-mirror ] ||
     ! cmp -s $DEPLOY_TMP/stats-billing-mirror-linux-amd64 /opt/macprovider-stats/stats-billing-mirror; then
    echo "refusing stats-billing-mirror replacement from direct deploy: install the signed matching stats sidecar release first" >&2
    exit 1
  fi
  install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-billing-mirror-linux-amd64 /opt/macprovider-stats/stats-billing-mirror
  # stats-hardware-verifier is an out-of-band stats sidecar. It promotes
  # queued autotune evidence after conservative verification.
  if [ ! -x /opt/macprovider-stats/stats-hardware-verifier ] ||
     ! cmp -s $DEPLOY_TMP/stats-hardware-verifier-linux-amd64 /opt/macprovider-stats/stats-hardware-verifier; then
    echo "refusing stats-hardware-verifier replacement from direct deploy: install the signed matching stats sidecar release first" >&2
    exit 1
  fi
  install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-hardware-verifier-linux-amd64 /opt/macprovider-stats/stats-hardware-verifier
  if [ '$CONFIG_MODE' = 'apply-tracked' ]; then
    install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.yaml /opt/macprovider/coordinator.yaml
  elif [ '${RATE_CARD_CONFIG_MIGRATION_ACTIVE:-0}' = '1' ]; then
    install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.rate-card-migration.yaml /opt/macprovider/coordinator.yaml
  elif [ '$C2_TIMER_CONFIG_MIGRATION' = '1' ]; then
    install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.c2-timer-migration.yaml /opt/macprovider/coordinator.yaml
  else
    echo '  preserving live /opt/macprovider/coordinator.yaml'
  fi
  if [ '${RATE_CARD_MIGRATION_OVERLAY_ACTIVE:-0}' = '1' ]; then
    install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.pearl-overlays.rate-card-migration.yaml /etc/macprovider/coordinator.pearl-overlays.yaml
  elif [ '${C2_TIMER_MIGRATION_OVERLAY_ACTIVE:-0}' = '1' ]; then
    install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.pearl-overlays.c2-timer-migration.yaml /etc/macprovider/coordinator.pearl-overlays.yaml
  fi
  install -d -o root -g macprovider -m 0750 /etc/macprovider
  if [ -e /etc/macprovider/coordinator.pearl-overlays.yaml ] && [ ! -f /etc/macprovider/coordinator.pearl-overlays.yaml ]; then
    echo 'refusing unsafe coordinator overlay path: /etc/macprovider/coordinator.pearl-overlays.yaml' >&2
    exit 1
  fi
  if [ ! -f /etc/macprovider/coordinator.pearl-overlays.yaml ]; then
    printf '{}\n' > $DEPLOY_TMP/coordinator.pearl-overlays.empty.yaml
    install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.pearl-overlays.empty.yaml /etc/macprovider/coordinator.pearl-overlays.yaml
  fi
  install -o root -g root       -m 0644 $DEPLOY_TMP/macprovider-coordinator.service /etc/systemd/system/macprovider-coordinator.service
  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-inventory-sync.service /etc/systemd/system/stats-inventory-sync.service
  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-inventory-sync.timer /etc/systemd/system/stats-inventory-sync.timer
  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.service /etc/systemd/system/stats-billing-mirror.service
  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.timer /etc/systemd/system/stats-billing-mirror.timer
  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-hardware-verifier.service /etc/systemd/system/stats-hardware-verifier.service
  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-hardware-verifier.timer /etc/systemd/system/stats-hardware-verifier.timer
  if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1 && [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-db-acl ]; then
    # Mutate only objects captured at the transaction boundary. WAL/SHM files
    # can appear while the old coordinator is still running; granting an ACL
    # to a newly appeared, unsnapshotted file would make exact rollback
    # impossible.
    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-dir-acl ] && setfacl -m u:macprovider-stats:--x /var/lib/macprovider
    setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/request-log.sqlite
    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-wal-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/request-log.sqlite-wal
    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-shm-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/request-log.sqlite-shm
  elif [ -f /var/lib/macprovider/request-log.sqlite ]; then
    echo '  warning: setfacl/getfacl not available; stats billing mirror will remain disabled until rollback-safe ACL management is available'
  fi
  # Stage the complete immutable catalog release. Activation happens only
  # after the late connected-provider safeguard immediately before restart.
  _autotune_root=/opt/macprovider/autotune
  _autotune_release=\$_autotune_root/releases/$AUTOTUNE_RELEASE_DIR_NAME
  _autotune_lock=\$_autotune_release.lock
  _autotune_stage=\$_autotune_root/releases/.stage-$AUTOTUNE_RELEASE_DIR_NAME-\$\$
  install -d -o root -g macprovider -m 0750 \$_autotune_root \$_autotune_root/releases
  if ! mkdir \$_autotune_lock; then
    echo 'catalog release staging is already in progress for $AUTOTUNE_RELEASE_ID' >&2
    exit 1
  fi
  trap 'rm -rf \"\$_autotune_stage\"; rmdir \"\$_autotune_lock\" 2>/dev/null || true' EXIT
  rm -rf \$_autotune_stage
  install -d -o root -g macprovider -m 0750 \$_autotune_stage
  install -o root -g macprovider -m 0640 $DEPLOY_TMP/demand-rank.json \$_autotune_stage/demand-rank.json
  install -o root -g macprovider -m 0640 $DEPLOY_TMP/demand-rank.json.sig \$_autotune_stage/demand-rank.json.sig
  install -o root -g macprovider -m 0640 $DEPLOY_TMP/autotune-candidates.json \$_autotune_stage/autotune-candidates.json
  install -o root -g macprovider -m 0640 $DEPLOY_TMP/autotune-candidates.json.sig \$_autotune_stage/autotune-candidates.json.sig
  install -o root -g macprovider -m 0640 $DEPLOY_TMP/rate-card.json \$_autotune_stage/rate-card.json
  install -o root -g macprovider -m 0640 $DEPLOY_TMP/rate-card.json.sig \$_autotune_stage/rate-card.json.sig
  install -o root -g macprovider -m 0640 $DEPLOY_TMP/tier2-catalog.json \$_autotune_stage/tier2-catalog.json
  install -o root -g macprovider -m 0640 $DEPLOY_TMP/release.json \$_autotune_stage/release.json
  install -o root -g macprovider -m 0640 $DEPLOY_TMP/trusted-keys.json \$_autotune_stage/trusted-keys.json
  python3 $DEPLOY_TMP/scripts/catalog-release.py verify-directory --directory \$_autotune_stage --tier2-public-key-file $DEPLOY_TMP/tier2-catalog.pub
  sync
  if [ -e \$_autotune_release ]; then
    if ! diff -qr \$_autotune_stage \$_autotune_release >/dev/null; then
      echo 'catalog release envelope $AUTOTUNE_RELEASE_DIR_NAME already exists with different bytes' >&2
      exit 1
    fi
    rm -rf \$_autotune_stage
  else
    mv \$_autotune_stage \$_autotune_release
  fi
  python3 $DEPLOY_TMP/scripts/catalog-release.py verify-directory --directory \$_autotune_release --tier2-public-key-file $DEPLOY_TMP/tier2-catalog.pub
  # First rollout: the new on-disk coordinator config already points at
  # autotune/current. Establish that path as soon as the immutable release is
  # staged so an abort before the late restart gate cannot leave the next
  # service restart without feeds. Existing rollouts remain untouched here.
  if [ ! -e \$_autotune_root/current ] && [ ! -L \$_autotune_root/current ]; then
    ln -sfn releases/$AUTOTUNE_RELEASE_DIR_NAME \$_autotune_root/current.bootstrap
    mv -Tf \$_autotune_root/current.bootstrap \$_autotune_root/current
  fi
  rmdir \$_autotune_lock
  trap - EXIT
"

# nginx + Let's Encrypt strategy (issue #244 R1+R2+R3+R4 — TLS-safety hardening):
#
# Domain classification (step 4b) produces FOUR states:
#   HAVE    fullchain.pem + privkey.pem present, openssl -checkend
#           86400 valid → no stub, no certbot, full vhost reinstalled
#           idempotently in step 6b.
#   RENEW   files present, cert valid RIGHT NOW (openssl -checkend 0
#           valid) but <24h to expiry → certbot needed, but the
#           existing full TLS vhost is left in place. A certbot
#           failure leaves the soon-expiring cert serving until next
#           deploy (instead of being replaced with an HTTP-only stub).
#   EXPIRED files present but cert is already invalid (openssl
#           -checkend 0 fails) → treat like MISSING. Existing vhost
#           would serve a broken cert; install stub + run certbot
#           instead.
#   MISSING fullchain.pem or privkey.pem absent → install stub + run
#           certbot. (Always-stub: dropped the R2 vhost-flag gate
#           after R3 audit showed a stale enabled vhost could lack
#           /.well-known/acme-challenge/ and block first issuance.)
#
#   step 5   -> install the port-80 ACME-stub ONLY for DOMAINS_NEED_STUB
#               (= EXPIRED ∪ MISSING). HAVE + RENEW production vhosts
#               are untouched. This is the load-bearing change vs. the
#               original bug: a downstream certbot failure cannot leave
#               another domain's working TLS vhost broken because we
#               never clobbered it in the first place.
#   step 6   -> per-domain certbot certonly --webroot, FAIL-SOFT. A
#               failure on ANY single domain (e.g. NXDOMAIN) is logged
#               and recorded but does not abort the deploy. State-aware
#               messaging tells the operator the per-domain fallback.
#   step 6b  -> install the full TLS vhost ONLY for DOMAINS_FULL_TLS
#               (= HAVE ∪ ISSUED_OK). EXPIRED/MISSING domains that
#               certbot failed for keep the ACME stub. RENEW domains
#               that certbot failed for keep their existing full TLS
#               vhost with the soon-to-expire cert. nginx -t + reload
#               runs ONCE at the end so any single bad file aborts the
#               batch atomically.
#
# Primary-domain failure (DOMAIN ∈ ISSUED_FAIL) triggers exit-9
# immediately after step 6b — before the connected-provider re-check,
# binary restart, and verify steps — with state-aware abort messaging.
# Non-primary failure defaults to WARN-only (issue #244 intent) unless
# STATS_REQUIRED=1 is set.
#
# This sequence is idempotent and never mutates a working production
# vhost when there is nothing to change. Earlier versions wrote the
# stub over the full vhost AND used in-place sed surgery on the full
# config (corrupted brace balance). Both removed in #244 R1; the dist/
# nginx confs now ship with active ssl_certificate directives and the
# pre-upload assertion at the top of this script refuses to deploy
# unless they remain active and bound to the expected hostname.

# SPEC-017 v0.1.8 Step 4.B — stats.streamvc.live is a first-class
# public hostname per SPEC §7.1; deploy applies the SAME ACME
# stub + certbot + full-vhost pipeline used for the coordinator
# hostname (round-4 ARCH r2 H1 / CODE r2 C1 fix).
STATS_DOMAIN="${STATS_DOMAIN:-stats.streamvc.live}"

# Classify domains by cert state on the remote host (#244 R1+R2+R3).
# One SSH round-trip; one line per domain: "<STATE> <DOMAIN>".
#
# Four states (R3 ARCH MED + CODE MED + SEC HIGH convergent refinement):
#   HAVE     fullchain.pem + privkey.pem present AND cert is valid for
#            >24h. No certbot, no stub. Full TLS vhost reinstalled
#            idempotently in step 6b.
#   RENEW    files present, cert valid RIGHT NOW (>0 seconds) but
#            <24h to expiry. certbot needed; existing full TLS vhost
#            is kept in place during certbot — if certbot fails, the
#            soon-expiring cert keeps serving until next deploy
#            (instead of being replaced with an HTTP-only stub).
#   EXPIRED  files present but cert is already expired or malformed
#            (openssl -checkend 0 reports invalid). Existing vhost
#            would serve a broken cert, so treat as MISSING: install
#            stub + run certbot, do NOT preserve the broken vhost.
#   MISSING  fullchain.pem or privkey.pem absent. First-ever issuance.
#            Always install stub before certbot (R3 ARCH+CODE MED:
#            vhost=1 was an over-coarse proxy for "ACME-ready" — a
#            stale enabled vhost can lack /.well-known/acme-challenge/
#            and block issuance. Always-stub for first-issuance is
#            cheap and idempotent; the stub gets overwritten in 6b
#            on certbot success).
#
# R2 ARCH/SEC/CODE convergent MED: missing openssl is FATAL (no silent
# file-presence fallback). step 2 above explicitly apt-installs openssl.
#
# R2 CODE HIGH-1: no `declare -A` (bash 3.2 compatibility for the
# operator Mac — default /usr/bin/env bash is 3.2.57). Track "seen"
# via parallel array + linear scan; only 2 domains, no perf concern.
log "step 4b/9: classify domains by cert state"
DOMAINS_ALL=("$DOMAIN" "$STATS_DOMAIN")
# TLS classification + planning + messaging factored into
# dist/lib/pearl_tls.sh so the state machine can be exercised without
# a real deploy (dist/test/check_pearl_tls_test.sh). Issue #291.
CERT_STATUS=$($SSH "bash -s -- '$DOMAIN' '$STATS_DOMAIN'" <<REMOTE_PROBE
$(pearl_tls_remote_probe_script)
REMOTE_PROBE
) || { echo "cert-status probe failed (see ABORT line above)" >&2; exit 1; }

pearl_tls_classify "$CERT_STATUS" || exit 1
log "  cert status: have=[${DOMAINS_HAVE_CERT[*]:-none}] need_cert=[${DOMAINS_NEED_CERT[*]:-none}] need_stub=[${DOMAINS_NEED_STUB[*]:-none}]"

log "step 5/9: install port-80 ACME-stub for EXPIRED + MISSING domains"
# R3 CODE+ARCH MED: install the stub for EXPIRED + MISSING (no usable
# cert today). RENEW domains keep their existing vhost so a certbot
# failure leaves the soon-expiring cert serving instead of an HTTP-
# only stub. HAVE domains are untouched.
if [ ${#DOMAINS_NEED_STUB[@]} -eq 0 ]; then
  log "  no first-time-issuance domains — skipping stub install (preserves existing vhosts)"
else
  $SSH "set -e
    exec 8>/opt/macprovider/.coordinator-deploy-operation.lock
    flock -s 8
    install -d -o www-data -g www-data -m 0755 /var/www/html
    for d in ${DOMAINS_NEED_STUB[*]}; do
      cat > /etc/nginx/sites-available/\$d <<NGINX_STUB
# Stub site — replaced by the full TLS config after Let's Encrypt cert
# is obtained. Only handles HTTP-01 challenge + redirect to https.
# (Issue #244 R3: installed for EXPIRED + MISSING; RENEW keeps its
# existing TLS vhost so a certbot failure leaves the soon-expiring
# cert serving instead of an HTTP-only stub.)
server {
    listen 80;
    listen [::]:80;
    server_name \$d;
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    location / {
        return 301 https://\\\$host\\\$request_uri;
    }
}
NGINX_STUB
      ln -sf /etc/nginx/sites-available/\$d /etc/nginx/sites-enabled/\$d
    done
    nginx -t
    systemctl reload nginx
  "
fi

log "step 6/9: obtain Let's Encrypt certs (per-domain, fail-soft)"
# Per-domain loop on the LOCAL side so the operator-visible WARN line
# is interleaved with each attempt; remote certbot invocations are
# allowed to fail without aborting the script (#244 fix (c)).
DOMAINS_ISSUED_OK=()
DOMAINS_ISSUED_FAIL=()
if [ ${#DOMAINS_NEED_CERT[@]} -eq 0 ]; then
  log "  no domains need issuance — skipping certbot"
else
  for d in ${DOMAINS_NEED_CERT[@]+"${DOMAINS_NEED_CERT[@]}"}; do
    log "  certbot certonly --webroot -d $d"
    if $SSH "exec 8>/opt/macprovider/.coordinator-deploy-operation.lock; flock -s 8; certbot certonly --webroot -w /var/www/html -d $d --non-interactive --agree-tos --email $EMAIL"; then
      DOMAINS_ISSUED_OK+=("$d")
      log "    ok: cert issued for $d"
    else
      DOMAINS_ISSUED_FAIL+=("$d")
      # State-aware messaging (lib/pearl_tls.sh — issue #291).
      log "    $(pearl_tls_certbot_fail_warn "$d")"
    fi
  done
fi

# Final set of domains that should get a full TLS vhost installed
# (lib/pearl_tls.sh — issue #291).
pearl_tls_plan_full_tls
log "step 6b/9: install nginx artifacts + full TLS vhost for [${DOMAINS_FULL_TLS[*]:-none}]"
# Shared http-context snippets always go in — no cert dependency.
$SSH "set -e
  exec 8>/opt/macprovider/.coordinator-deploy-operation.lock
  flock -s 8
  install -o root -g root -m 0644 $DEPLOY_TMP/nginx-stats-shared.conf /etc/nginx/conf.d/stats-shared.conf
  install -o root -g root -m 0644 $DEPLOY_TMP/nginx-stats-security-headers.conf /etc/nginx/conf.d/stats-security-headers.conf
  install -o root -g root -m 0644 $DEPLOY_TMP/nginx-stats-cors-429.conf /etc/nginx/conf.d/cors-429.conf
  install -o root -g root -m 0644 $DEPLOY_TMP/nginx-stats-proxy-public.conf /etc/nginx/conf.d/stats-proxy-public.conf
  install -o root -g root -m 0644 $DEPLOY_TMP/nginx-stats-proxy-partner.conf /etc/nginx/conf.d/stats-proxy-partner.conf
"

# Install the full TLS vhost ONLY for domains with a valid cert. Domains
# where certbot failed keep the ACME stub from step 5 (HTTP-80 only).
#
# The dist/ confs now ship with uncommented ssl_certificate lines (#244
# fix (a)), and the file-load assertion at the top of this script
# refuses to deploy if they get re-commented. No in-place sed surgery.
for d in ${DOMAINS_FULL_TLS[@]+"${DOMAINS_FULL_TLS[@]}"}; do
  case "$d" in
    "$DOMAIN")        src="$DEPLOY_TMP/nginx-coordinator-full.conf" ;;
    "$STATS_DOMAIN")  src="$DEPLOY_TMP/nginx-stats.streamvc.live.conf" ;;
    *) echo "  unknown domain in DOMAINS_FULL_TLS: $d (skipping)" >&2; continue ;;
  esac
  $SSH "set -e
    exec 8>/opt/macprovider/.coordinator-deploy-operation.lock
    flock -s 8
    install -o root -g root -m 0644 $src /etc/nginx/sites-available/$d
    ln -sf /etc/nginx/sites-available/$d /etc/nginx/sites-enabled/$d
  "
done

# Clean up the per-deploy staging dir + the stale .full backup file
# from the broken-v1 deploy if present. validate + reload exactly once
# so a single bad file aborts the batch atomically.
$SSH "set -e
  exec 8>/opt/macprovider/.coordinator-deploy-operation.lock
  flock -s 8
  rm -rf $DEPLOY_TMP
  rm -f /etc/nginx/sites-available/$DOMAIN.full
  nginx -t
  systemctl reload nginx
"

if [ ${#DOMAINS_ISSUED_FAIL[@]} -gt 0 ]; then
  log "  WARN: certbot failed for [${DOMAINS_ISSUED_FAIL[*]}] (state-aware fallback per-domain logged above)"
  log "  Check DNS A records (dig +short <domain>), then re-run this script to retry issuance."
fi

# R1 CODE HIGH-1 / SEC HIGH-2 / ARCH HIGH-1 (3-of-3 convergent) — fail
# closed BEFORE step 6c/7/8 if the primary $DOMAIN failed cert issuance
# this run. Step 8's curl https://$DOMAIN/healthz would otherwise hard-
# exit 1 first, masking the cert-failure contract.
#
# R1 SEC MED-3 / ARCH MED-2 — opt-in strict mode for non-primary
# domains. Default WARN-only matches the issue intent (stats. NXDOMAIN
# must not break primary deploy); STATS_REQUIRED=1 promotes any non-
# primary failure to a fail-closed exit so operators with strict
# uptime SLOs can enforce it.
pearl_tls_check_issuance_failures "$DOMAIN"
if [ "$PEARL_TLS_PRIMARY_FAILED" -eq 1 ]; then
  # State-aware abort (lib/pearl_tls.sh — issue #291).
  pearl_tls_primary_abort_msg "$DOMAIN" >&2
  exit 9
fi
if [ "$PEARL_TLS_NONPRIMARY_FAILED" -eq 1 ] && [ "${STATS_REQUIRED:-0}" = "1" ]; then
  echo "" >&2
  echo "  ABORT-EXIT: STATS_REQUIRED=1 set and a non-primary domain failed cert" >&2
  echo "             issuance ([${DOMAINS_ISSUED_FAIL[*]}]). Refusing to restart." >&2
  exit 9
fi

log "step 6c/9: pre-restart safeguard (late connected-provider check)"
# Coordinator restart triggers SPEC-001 § 6.5 drain on all connected
# providers. v1.1.3+ phase3-binary handles this gracefully (drops WS,
# keeps serving direct traffic, reconnects after grace period). Older
# phase3-binary (v1.1.2 and earlier) exits the process on drain — which
# kills tunnel-direct buyer traffic. Until you can guarantee every
# connected provider is on v1.1.3+, refuse to auto-restart with
# connected providers unless the operator passes FORCE_RESTART=1.
#
# This is the LATE check — step 1c was the early one. Both exist on
# purpose: a provider that wasn't connected at step 1c can have
# connected during certbot/nginx work (step 2-6b is the longest part
# of the script). The 2026-06-12 deploy had air5 connect mid-script
# under exactly this shape; the operator manually jumped past this
# step. The tombstone wired below + the early check + the PREV_BYPASS
# surface at step 1 are the audit-trail trio that makes future
# bypasses visible to the NEXT deploy. Manual jumps past this step
# leave no trail beyond the absence of a completion marker — write
# the bypass file by hand if jumping past, see message below.
CONNECTED_COUNT=$(curl -fsS --max-time 5 --max-filesize 65536 "https://$DOMAIN/healthz" 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('pool_size', 0))" 2>/dev/null \
  || echo 0)
if [ "${CONNECTED_COUNT:-0}" -gt 0 ] && [ "${FORCE_RESTART:-0}" != "1" ]; then
  log "  REFUSING TO RESTART — $CONNECTED_COUNT provider(s) currently connected."
  log "  Restart triggers drain; phase3-binary <= v1.1.2 exits the process"
  log "  on drain and breaks tunnel-direct buyer traffic."
  log "  To proceed anyway:  FORCE_RESTART=1 bash $0"
  log "  If you must JUMP past this step manually, please first write:"
  log "    ssh <pearl> 'echo {\"ts\":\"\$(date -u +%FT%TZ)\",\"service\":\"coordinator\",\"reason\":\"manual_jump\",\"step\":\"6c\",\"metric\":\"connected_providers\",\"value\":$CONNECTED_COUNT,\"operator_host\":\"\$HOSTNAME\"} > /var/lib/macprovider/last-deploy-bypass.json'"
  log "  so the next deploy surfaces the bypass at step 1."
  exit 4
fi
if [ "${FORCE_RESTART:-0}" = "1" ] && [ "${CONNECTED_COUNT:-0}" -gt 0 ]; then
  TS_NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  OP_HOST="${HOSTNAME:-unknown}"
  # R6 — write via remote mktemp (see step 1c above for full rationale).
  $SSH "set -e
        install -d -o macprovider -g macprovider -m 0750 /var/lib/macprovider 2>/dev/null || true
        _bypass_tmp=\$(umask 077 && mktemp)
        cat > \"\$_bypass_tmp\" <<EOF
{\"ts\":\"$TS_NOW\",\"service\":\"coordinator\",\"reason\":\"FORCE_RESTART=1\",\"step\":\"6c\",\"metric\":\"connected_providers\",\"value\":$CONNECTED_COUNT,\"operator_host\":\"$OP_HOST\"}
EOF
        install -o macprovider -g macprovider -m 0640 \"\$_bypass_tmp\" /var/lib/macprovider/last-deploy-bypass.json
        rm -f \"\$_bypass_tmp\"
        logger -t macprovider-deploy \"FORCE_RESTART=1 used at step 6c; connected=$CONNECTED_COUNT\""
  log "  AUDIT TRAIL: FORCE_RESTART=1 override written to /var/lib/macprovider/last-deploy-bypass.json"
fi
log "  ok: $CONNECTED_COUNT connected providers (or FORCE_RESTART=1 set)"

log "  activating verified autotune release $AUTOTUNE_RELEASE_ID"
$SSH "set -e
  exec 8>/opt/macprovider/.coordinator-deploy-operation.lock
  flock -s 8
  _catalog_root=/opt/macprovider/autotune
  _previous=\$(readlink \"\$_catalog_root/current\" 2>/dev/null || true)
  case \"\$_previous\" in
    ''|releases/[A-Za-z0-9]*) ;;
    *) echo \"invalid existing autotune current target: \$_previous\" >&2; exit 1 ;;
  esac
  case \"\$_previous\" in
    *[!A-Za-z0-9._/-]*|*'/../'*|*'/..'|*'/./'*|*'/.'|*'//'|releases/|releases) echo \"unsafe existing autotune current target: \$_previous\" >&2; exit 1 ;;
  esac
  [ ! -e \"\$_catalog_root/current.next\" ] && [ ! -L \"\$_catalog_root/current.next\" ] || {
    echo 'unsafe transient autotune/current.next exists before activation' >&2
    exit 1
  }
  python3 - \"\$_previous\" <<'PY'
import grp
import os
import re
import stat
import sys

ROOT = '/opt/macprovider'
NOFOLLOW = getattr(os, 'O_NOFOLLOW', 0)
previous = sys.argv[1]
if previous and re.fullmatch(r'releases/[A-Za-z0-9][A-Za-z0-9._-]{0,191}', previous) is None:
    raise SystemExit('invalid previous autotune current target')

def validate_dir(fd, label):
    info = os.fstat(fd)
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != 0
        or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
    ):
        raise SystemExit(f'unsafe directory for previous-target publish: {label}')

slash_fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW)
validate_dir(slash_fd, '/')
opt_fd = os.open('opt', os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW, dir_fd=slash_fd)
validate_dir(opt_fd, '/opt')
root_fd = os.open('macprovider', os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW, dir_fd=opt_fd)
validate_dir(root_fd, ROOT)
autotune_fd = os.open('autotune', os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW, dir_fd=root_fd)
validate_dir(autotune_fd, f'{ROOT}/autotune')

gid = grp.getgrnam('macprovider').gr_gid
tmp_name = f'.previous-target.tmp.{os.getpid()}'
fd = os.open(tmp_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW, 0o640, dir_fd=autotune_fd)
try:
    os.fchown(fd, 0, gid)
    info = os.fstat(fd)
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != 0
        or info.st_gid != gid
        or stat.S_IMODE(info.st_mode) != 0o640
        or info.st_nlink != 1
    ):
        raise SystemExit('unsafe previous-target temp file')
    os.write(fd, previous.encode('ascii'))
    os.fsync(fd)
finally:
    os.close(fd)
os.rename(tmp_name, '.previous-target', src_dir_fd=autotune_fd, dst_dir_fd=autotune_fd)
PY
  ln -sfn releases/$AUTOTUNE_RELEASE_DIR_NAME \"\$_catalog_root/current.next\"
  mv -Tf \"\$_catalog_root/current.next\" \"\$_catalog_root/current\"
  rm -f /opt/macprovider/tier2-catalog.json
"
log "step 7/9: enable + start coordinator service"
$SSH 'set -e
  exec 8>/opt/macprovider/.coordinator-deploy-operation.lock
  flock -s 8
  touch /opt/macprovider/.coordinator-deploy-rollback/restart-attempted
  systemctl daemon-reload
  systemctl enable macprovider-coordinator
  systemctl restart macprovider-coordinator
  sleep 3
  systemctl is-active macprovider-coordinator
  ss -tlnp | grep -E ":8443|:8444"
'

log "step 8/9: verify public endpoints"
sleep 2
echo "  GET https://$DOMAIN/healthz"
# --max-filesize bounds bytes (--max-time only bounds wall-clock); /healthz
# is a few hundred bytes in practice, so 64 KiB is a generous cap that
# protects the operator Mac from a malicious or misbehaving upstream
# streaming gigabytes inside the 10s window.
HEALTHZ_BODY=$(curl -fsS --max-time 10 --max-filesize 65536 "https://$DOMAIN/healthz" || { echo "healthz failed"; exit 1; })
printf '%s\n' "$HEALTHZ_BODY" | python3 -m json.tool

# Provenance check: compare the deployed version (from /healthz) against the
# exact release tag validated before any production SSH mutation. Missing and
# mismatched versions are fatal while rollback is still armed; otherwise a clean
# tag checkout could still commit a stale ignored dist/coordinator-linux-amd64.
# See audits/2026-06-10/ROLLBACK_PROCEDURE.md for the rollback path.
EXPECTED_VERSION="$COORDINATOR_RELEASE_VERSION"
_coordinator_verify_deployed_version "$HEALTHZ_BODY" "$EXPECTED_VERSION" || exit $?

echo "  GET https://$DOMAIN/v1/models -> expect 404 (buyer API is gateway-only)"
STATUS=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN/v1/models")
if [ "$STATUS" != "404" ]; then
  echo "coordinator /v1/models exposure check failed: status=$STATUS" >&2
  exit 1
fi

if [ -n "$CATALOG_REMOTE_PATH" ]; then
  echo "  GET https://$DOMAIN/catalog/current -> expect 200"
  # Issue #292 (LOW, deferred from #244 R6/R7 CODE+SEC): don't write
  # the smoke response to a predictable operator-Mac /tmp path. A
  # local attacker on the operator's workstation could pre-place a
  # symlink at /tmp/macprovider-catalog-current.json (or race the
  # curl -o open) to redirect the write. mktemp under umask 077
  # picks an unpredictable name with 0600 perms; cleanup rides the
  # unconditional EXIT trap registered above.
  CATALOG_SMOKE_TMP=$(umask 077 && mktemp -t macprovider-catalog-current.XXXXXXXX) || {
    echo "aborting smoke: mktemp failed" >&2
    exit 1
  }
  STATUS=$(curl -sS -o "$CATALOG_SMOKE_TMP" -w '%{http_code}' --max-time 10 --max-filesize 1048576 "https://$DOMAIN/catalog/current")
  if [ "$STATUS" != "200" ]; then
    echo "coordinator /catalog/current check failed: status=$STATUS body=$(head -c 300 "$CATALOG_SMOKE_TMP")" >&2
    exit 1
  fi
  # #292 R1 ARCH MED: `echo "$(python3 ...)"` under set -e is silent on
  # python failure — echo succeeds regardless, so invalid JSON (or a
  # 200 response body that isn't the catalog schema) prints
  # "catalog OK:" and the deploy proceeds. Assign first, check exit
  # explicitly, then echo.
  CATALOG_SUMMARY=$(python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); print("catalog_id=%s models=%d" % (c.get("catalog_id"), len(c.get("models", []))))' "$CATALOG_SMOKE_TMP") || {
    echo "coordinator /catalog/current smoke: python3 parse failed on 200 body (head -c 300: $(head -c 300 "$CATALOG_SMOKE_TMP"))" >&2
    exit 1
  }
  echo "  catalog OK: $CATALOG_SUMMARY"
fi

# SPEC-023 signed recommendation feeds smoke (buyer mux via nginx).
log "  verifying coordinator can read autotune feeds as macprovider"
$SSH "set -e
  sudo -u macprovider test -r /opt/macprovider/autotune/current/autotune-candidates.json
  sudo -u macprovider test -r /opt/macprovider/autotune/current/demand-rank.json
  sudo -u macprovider test -r /opt/macprovider/autotune/current/rate-card.json
" || {
  echo "aborting smoke: macprovider cannot read /opt/macprovider/autotune/*" >&2
  exit 1
}
STATIC_SMOKE_DIR=$(umask 077 && mktemp -d -t macprovider-autotune-probe.XXXXXXXX) || {
  echo "aborting smoke: mktemp -d failed for autotune feed probe" >&2
  exit 1
}
for STATIC_SPEC in \
    "/v1/rate-card|rate-card.json|$STATIC_RATE_CARD_JSON" \
    "/v1/rate-card.sig|rate-card.json.sig|$STATIC_RATE_CARD_SIG" \
    "/v1/demand-rank|demand-rank.json|$STATIC_DEMAND_JSON" \
    "/v1/demand-rank.sig|demand-rank.json.sig|$STATIC_DEMAND_SIG" \
    "/v1/autotune-candidates|autotune-candidates.json|$STATIC_AUTOTUNE_JSON" \
    "/v1/autotune-candidates.sig|autotune-candidates.json.sig|$STATIC_AUTOTUNE_SIG"; do
  STATIC_PATH="${STATIC_SPEC%%|*}"
  STATIC_REST="${STATIC_SPEC#*|}"
  STATIC_NAME="${STATIC_REST%%|*}"
  STATIC_EXPECTED="${STATIC_REST#*|}"
  STATIC_SMOKE_BODY="$STATIC_SMOKE_DIR/$STATIC_NAME"
  echo "  GET https://$DOMAIN$STATIC_PATH -> expect 200"
  STATUS=$(curl -sS -o "$STATIC_SMOKE_BODY" -w '%{http_code}' --max-time 10 --max-filesize 65536 "https://$DOMAIN$STATIC_PATH")
  if [ "$STATUS" != "200" ]; then
    echo "SPEC-023 autotune feed smoke failed: $STATIC_PATH status=$STATUS body=$(head -c 200 "$STATIC_SMOKE_BODY")" >&2
    exit 1
  fi
  if ! cmp -s "$STATIC_EXPECTED" "$STATIC_SMOKE_BODY"; then
    echo "SPEC-023 autotune feed smoke failed: $STATIC_PATH bytes differ from staged release" >&2
    exit 1
  fi
done
cp "$AUTOTUNE_RELEASE_MANIFEST" "$STATIC_SMOKE_DIR/release.json"
cp "$AUTOTUNE_TRUSTED_KEYS" "$STATIC_SMOKE_DIR/trusted-keys.json"
cp "$AUTOTUNE_TIER2_JSON" "$STATIC_SMOKE_DIR/tier2-catalog.json"
cp "$STATIC_RATE_CARD_JSON" "$STATIC_SMOKE_DIR/rate-card.json"
cp "$STATIC_RATE_CARD_SIG" "$STATIC_SMOKE_DIR/rate-card.json.sig"
python3 "$AUTOTUNE_RELEASE_VERIFY" verify-directory --directory "$STATIC_SMOKE_DIR"
AUTOTUNE_STATUS_BODY="$STATIC_SMOKE_DIR/autotune-release-status.json"
STATUS=$(curl -sS -o "$AUTOTUNE_STATUS_BODY" -w '%{http_code}' --max-time 10 --max-filesize 65536 "https://$DOMAIN/v1/autotune-release")
if [ "$STATUS" != "200" ]; then
  echo "SPEC-023 autotune release status failed: status=$STATUS body=$(head -c 200 "$AUTOTUNE_STATUS_BODY")" >&2
  exit 1
fi
python3 - "$AUTOTUNE_STATUS_BODY" "$AUTOTUNE_RELEASE_ID" <<'PY'
import json, sys
status = json.load(open(sys.argv[1], encoding="utf-8"))
if status.get("status") != "live_verified" or status.get("release_id") != sys.argv[2]:
    raise SystemExit("coordinator autotune release metadata does not match activated release")
for name in ("autotune_candidates", "demand_rank", "rate_card"):
    feed = status.get("feeds", {}).get(name, {})
    if len(feed.get("sha256", "")) != 64 or not feed.get("signer_key_id"):
        raise SystemExit(f"coordinator autotune release metadata is incomplete for {name}")
PY
echo "  SPEC-023 autotune feeds exact-byte and signature verification OK"

# A perfect catalog endpoint does not prove the exact canary process completed
# the hello compatibility gate. First prove the live Mac process and capture its
# assigned coordinator session; then query authenticated coordinator evidence
# for that exact session below.
CANARY_POOL_BODY="$STATIC_SMOKE_DIR/catalog-canary-pool.json"
CANARY_CURL_CONFIG="$STATIC_SMOKE_DIR/catalog-canary-curl.conf"

# Provider hello fields are authenticated self-report, so they are not exact
# installation proof. Read the release bundle from the operator-controlled
# canary Mac over host-key-checked SSH and compare every shipped catalog file
# with the locally verified release. This makes the deployment commit depend on
# independent canary-host custody of the exact bytes, not on replayable public
# catalog identifiers in a provider hello.
CANARY_INSTALLED_BODY="$STATIC_SMOKE_DIR/catalog-canary-installed.json"
CANARY_SSH=(
  ssh
  -i "$CATALOG_CANARY_SSH_KEY"
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=yes
  -o ConnectTimeout=10
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=3
  "$CATALOG_CANARY_SSH_TARGET"
)
run_catalog_canary_mac_proof() {
  local timeout_s="$1"
  _run_with_deadline_alarm "$timeout_s" "${CANARY_SSH[@]}" python3 - \
  "$CATALOG_CANARY_INSTALL_DIR" \
  "$CATALOG_CANARY_PROVIDER_ID" \
  "$AUTOTUNE_RELEASE_ID" \
  "$AUTOTUNE_POLICY_VERSION" \
  "$AUTOTUNE_CANDIDATE_SHA256" \
  "$AUTOTUNE_CANDIDATE_SIGNER_KEY_ID" <<'PY'
import hashlib, json, os, plistlib, re, stat, subprocess, sys, urllib.request

(
    catalog_path,
    expected_provider_id,
    expected_release_id,
    expected_policy_version,
    expected_digest,
    expected_signer,
) = sys.argv[1:]
home = os.path.expanduser("~")
nofollow = getattr(os, "O_NOFOLLOW", 0)
nonblock = getattr(os, "O_NONBLOCK", 0)
directory_flags = os.O_RDONLY | os.O_DIRECTORY | nofollow

def open_dir(path):
    if os.path.isabs(path):
        current = os.open("/", directory_flags)
        parts = [part for part in path.split("/") if part]
    else:
        current = os.open(home, directory_flags)
        parts = [part for part in path.split("/") if part]
    try:
        for part in parts:
            if part in {".", ".."}:
                raise SystemExit(f"unsafe canary path component: {part}")
            next_fd = os.open(part, directory_flags, dir_fd=current)
            os.close(current)
            current = next_fd
        return current
    except BaseException:
        os.close(current)
        raise

def read_regular_at(directory_fd, name, limit, require_owner=True):
    fd = os.open(name, os.O_RDONLY | nofollow | nonblock, dir_fd=directory_fd)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise SystemExit(f"canary path is not a regular file: {name}")
        if require_owner and info.st_uid != os.getuid():
            raise SystemExit(f"canary file has unexpected owner: {name}")
        if info.st_size > limit:
            raise SystemExit(f"oversized canary file: {name}")
        chunks = []
        remaining = limit + 1
        while remaining:
            chunk = os.read(fd, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        value = b"".join(chunks)
        if len(value) > limit:
            raise SystemExit(f"oversized canary file: {name}")
        return value, info
    finally:
        os.close(fd)

def open_parent_and_name(path):
    normalized = os.path.normpath(path)
    parent, name = os.path.split(normalized)
    if not name or name in {".", ".."}:
        raise SystemExit(f"unsafe canary file path: {path}")
    return open_dir(parent or "."), name

def running_text_vnode_path(pid, binary_info, expected_binary, runner=subprocess.run):
    fields = runner(
        ["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), "-d", "txt", "-F", "Dfin"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=10,
    ).stdout.splitlines()
    text_device = text_inode = text_path = None
    for field in fields:
        if field.startswith("f"):
            text_device = text_inode = text_path = None
        elif field.startswith("D"):
            try:
                text_device = int(field[1:], 0)
            except ValueError:
                raise SystemExit("lsof returned an invalid text-vnode device")
        elif field.startswith("i"):
            try:
                text_inode = int(field[1:])
            except ValueError:
                raise SystemExit("lsof returned an invalid text-vnode inode")
        elif field.startswith("n"):
            text_path = field[1:]
        normalized_text_path = (
            os.path.normpath(text_path.removesuffix(" (deleted)"))
            if text_path is not None
            else None
        )
        if (
            text_device == binary_info.st_dev
            and text_inode == binary_info.st_ino
            and normalized_text_path == expected_binary
        ):
            return normalized_text_path
    return None

catalog_fd = open_dir(catalog_path)
install_path = os.path.dirname(os.path.normpath(catalog_path)) or "."
install_fd = open_dir(install_path)
config_fd = provider_config_fd = binary_fd = None
try:
    provider_config_fd = open_dir(".config/macprovider")
    provider_bytes, _ = read_regular_at(provider_config_fd, "provider_id", 1024)
    provider_id = provider_bytes.decode("utf-8").strip()
    if provider_id != expected_provider_id:
        raise SystemExit(
            f"canary provider identity mismatch: expected={expected_provider_id} actual={provider_id}"
        )

    plist_dir_fd = open_dir("Library/LaunchAgents")
    try:
        plist_bytes, _ = read_regular_at(
            plist_dir_fd, "live.streamvc.macprovider.plist", 1024 * 1024
        )
    finally:
        os.close(plist_dir_fd)
    plist = plistlib.loads(plist_bytes)
    arguments = plist.get("ProgramArguments")
    if not isinstance(arguments, list) or len(arguments) < 4 or arguments[1:3] != ["serve", "--config"]:
        raise SystemExit("canary provider LaunchAgent has unexpected ProgramArguments")

    binary_fd = os.open(
        "macprovider-cli", os.O_RDONLY | nofollow | nonblock, dir_fd=install_fd
    )
    binary_info = os.fstat(binary_fd)
    if not stat.S_ISREG(binary_info.st_mode) or binary_info.st_uid != os.getuid() or binary_info.st_mode & 0o111 == 0:
        raise SystemExit("canary installation binary is not a safe executable")
    install_absolute = install_path if os.path.isabs(install_path) else os.path.join(home, install_path)
    expected_binary = os.path.normpath(os.path.join(install_absolute, "macprovider-cli"))
    if os.path.normpath(arguments[0]) != expected_binary:
        raise SystemExit("canary LaunchAgent does not use the catalog installation root")

    launchd = subprocess.run(
        ["launchctl", "print", f"gui/{os.getuid()}/live.streamvc.macprovider"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=10,
    ).stdout
    match = re.search(r"(?m)^\s*pid = ([0-9]+)\s*$", launchd)
    if match is None:
        raise SystemExit("canary provider LaunchAgent has no live PID")
    pid = int(match.group(1))
    process_path = running_text_vnode_path(pid, binary_info, expected_binary)
    if process_path is None:
        raise SystemExit("live canary provider text vnode is stale or not the verified installation binary")

    config_fd, config_name = open_parent_and_name(arguments[3])
    config_bytes, _ = read_regular_at(config_fd, config_name, 1024 * 1024)
    config_text = config_bytes.decode("utf-8")
    port_match = re.search(r'(?m)^\s*port:\s*"?([0-9]+)"?\s*(?:#.*)?$', config_text)
    if port_match is None or not (1 <= int(port_match.group(1)) <= 65535):
        raise SystemExit("canary provider config has no valid local status port")
    port = int(port_match.group(1))
    listener = subprocess.run(
        ["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), f"-iTCP:{port}", "-sTCP:LISTEN", "-t"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=10,
    )
    if str(pid) not in listener.stdout.split():
        raise SystemExit("live canary provider PID does not own its configured status port")
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, _request, _fp, _code, _message, _headers, _new_url):
            raise RuntimeError("canary local status redirect refused")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(f"http://127.0.0.1:{port}/v1/status", timeout=10) as response:
        if response.status != 200:
            raise SystemExit(f"canary local status returned HTTP {response.status}")
        local_status = json.loads(response.read(1024 * 1024))
    catalog = local_status.get("catalog")
    coordinator = local_status.get("coordinator")
    assigned_id = coordinator.get("session") if isinstance(coordinator, dict) else None
    if (
        local_status.get("provider_id") != expected_provider_id
        or local_status.get("network_state") != "buyer_serving"
        or not isinstance(coordinator, dict)
        or coordinator.get("connected") is not True
        or not isinstance(assigned_id, str)
        or not assigned_id
        or not isinstance(catalog, dict)
        or catalog.get("release_id") != expected_release_id
        or catalog.get("policy_version") != expected_policy_version
        or catalog.get("digest") != expected_digest
        or catalog.get("signer_key_id") != expected_signer
        or re.fullmatch(r"[0-9a-f]{64}", str(catalog.get("row_identity", "")).lower()) is None
    ):
        raise SystemExit("live canary provider status does not match the expected identity and catalog")

    names = (
        "release.json",
        "trusted-keys.json",
        "autotune-candidates.json",
        "autotune-candidates.json.sig",
        "demand-rank.json",
        "demand-rank.json.sig",
        "rate-card.json",
        "rate-card.json.sig",
        "tier2-catalog.json",
    )
    hashes = {}
    for name in names:
        payload, _ = read_regular_at(catalog_fd, name, 2 * 1024 * 1024)
        hashes[name] = hashlib.sha256(payload).hexdigest()
    print(json.dumps({
        "provider_id": provider_id,
        "assigned_id": assigned_id,
        "launchd_pid": pid,
        "executable_path": process_path,
        "local_status": local_status,
        "files": hashes,
    }, sort_keys=True))
finally:
    for fd in (config_fd, provider_config_fd, binary_fd, install_fd, catalog_fd):
        if fd is not None:
            os.close(fd)
PY
}

# A coordinator restart can make a healthy provider rotate its PID and assigned
# session while its recovery watchdog drains in-flight work. Retry the complete
# Mac proof and bind each admission query to the session from that same attempt;
# never carry an assigned_id across retries. This mirrors the signed updater's
# full-proof retry and keeps every success predicate fail-closed.
CANARY_PROVIDER_QUERY=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$CATALOG_CANARY_PROVIDER_ID")
(umask 077 && printf 'header = "Authorization: Bearer %s"\n' "$CATALOG_CANARY_AUTH_TOKEN" > "$CANARY_CURL_CONFIG")
CANARY_OK=0
CANARY_LAST_ERROR="canary proof did not start"
CANARY_STATUS="000"
CANARY_ATTEMPT=1
CANARY_MAX_ATTEMPTS=36
CANARY_RECOVERY_TIMEOUT_S=180
CANARY_RECOVERY_DEADLINE=$((SECONDS + CANARY_RECOVERY_TIMEOUT_S))
while [ "$CANARY_ATTEMPT" -le "$CANARY_MAX_ATTEMPTS" ] && [ "$SECONDS" -lt "$CANARY_RECOVERY_DEADLINE" ]; do
  rm -f "$CANARY_INSTALLED_BODY" "$CANARY_POOL_BODY"
  CANARY_PROOF_ERROR="$STATIC_SMOKE_DIR/catalog-canary-proof.err"
  CANARY_REMAINING_S=$((CANARY_RECOVERY_DEADLINE - SECONDS))
  CANARY_PROOF_TIMEOUT_S=45
  if [ "$CANARY_REMAINING_S" -lt "$CANARY_PROOF_TIMEOUT_S" ]; then
    CANARY_PROOF_TIMEOUT_S="$CANARY_REMAINING_S"
  fi
  if run_catalog_canary_mac_proof "$CANARY_PROOF_TIMEOUT_S" > "$CANARY_INSTALLED_BODY" 2> "$CANARY_PROOF_ERROR"; then
    CANARY_BINDING=$(python3 - "$CANARY_INSTALLED_BODY" <<'PY'
import json, pathlib, re, sys
proof = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assigned_id = proof.get("assigned_id")
row_identity = proof.get("local_status", {}).get("catalog", {}).get("row_identity")
if not isinstance(assigned_id, str) or not assigned_id or any(ch.isspace() for ch in assigned_id):
    raise SystemExit("canary proof has no safe assigned coordinator session")
if re.fullmatch(r"[0-9a-f]{64}", str(row_identity).lower()) is None:
    raise SystemExit("canary proof has no exact catalog row identity")
print(assigned_id, str(row_identity).lower())
PY
) || CANARY_BINDING=""
    if [ -n "$CANARY_BINDING" ]; then
      read -r CANARY_ASSIGNED_ID CANARY_CATALOG_ROW_IDENTITY <<< "$CANARY_BINDING"
      CANARY_ASSIGNED_QUERY=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$CANARY_ASSIGNED_ID")
      CANARY_STATUS=$(curl --config "$CANARY_CURL_CONFIG" -sS -o "$CANARY_POOL_BODY" -w '%{http_code}' --max-time 10 --max-filesize 65536 \
        "https://$DOMAIN/v1/pool/check?provider_id=$CANARY_PROVIDER_QUERY&assigned_id=$CANARY_ASSIGNED_QUERY&details=deployment" || true)
      if [ "$CANARY_STATUS" = "200" ] && python3 - \
        "$CANARY_POOL_BODY" "$CATALOG_CANARY_PROVIDER_ID" "$CANARY_ASSIGNED_ID" \
        "$AUTOTUNE_RELEASE_ID" "$AUTOTUNE_POLICY_VERSION" "$AUTOTUNE_CANDIDATE_SHA256" \
        "$AUTOTUNE_CANDIDATE_SIGNER_KEY_ID" "$CANARY_CATALOG_ROW_IDENTITY" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
if (
    value.get("provider_id") != sys.argv[2]
    or value.get("assigned_id") != sys.argv[3]
    or value.get("buyer_serving") is not True
    or value.get("catalog_evidence_source") != "provider_reported"
    or value.get("catalog_admission_mode") != "current"
    or value.get("catalog_release_id") != sys.argv[4]
    or value.get("catalog_policy_version") != sys.argv[5]
    or value.get("catalog_candidate_sha256") != sys.argv[6]
    or value.get("catalog_signer_key_id") != sys.argv[7]
    or str(value.get("catalog_row_identity", "")).lower() != sys.argv[8]
):
    raise SystemExit(1)
PY
      then
        CANARY_OK=1
        break
      fi
      CANARY_LAST_ERROR="exact session $CANARY_ASSIGNED_ID was not buyer-serving (status=$CANARY_STATUS)"
    else
      CANARY_LAST_ERROR="could not bind the live Mac session and catalog row"
    fi
  else
    CANARY_PROOF_RC=$?
    CANARY_LAST_ERROR="trusted Mac proof failed (exit=$CANARY_PROOF_RC)"
  fi
  CANARY_REMAINING_S=$((CANARY_RECOVERY_DEADLINE - SECONDS))
  if [ "$CANARY_ATTEMPT" -lt "$CANARY_MAX_ATTEMPTS" ] && [ "$CANARY_REMAINING_S" -gt 0 ]; then
    echo "  waiting for exact catalog canary recovery ($CANARY_ATTEMPT/$CANARY_MAX_ATTEMPTS): $CANARY_LAST_ERROR" >&2
    CANARY_SLEEP_S=5
    if [ "$CANARY_REMAINING_S" -lt "$CANARY_SLEEP_S" ]; then
      CANARY_SLEEP_S="$CANARY_REMAINING_S"
    fi
    sleep "$CANARY_SLEEP_S"
  fi
  CANARY_ATTEMPT=$((CANARY_ATTEMPT + 1))
done
rm -f "$CANARY_CURL_CONFIG"
if [ "$CANARY_OK" != "1" ]; then
  echo "SPEC-023 canary failed after $((CANARY_ATTEMPT - 1)) full proof attempts within ${CANARY_RECOVERY_TIMEOUT_S}s: $CANARY_LAST_ERROR" >&2
  echo "  last status=$CANARY_STATUS body=$(head -c 300 "$CANARY_POOL_BODY" 2>/dev/null || true)" >&2
  exit 1
fi

if ! python3 - \
  "$CANARY_INSTALLED_BODY" \
  "$CANARY_POOL_BODY" \
  "$CATALOG_CANARY_PROVIDER_ID" \
  "$AUTOTUNE_RELEASE_MANIFEST" \
  "$AUTOTUNE_TRUSTED_KEYS" \
  "$STATIC_AUTOTUNE_JSON" \
  "$STATIC_AUTOTUNE_SIG" \
  "$STATIC_DEMAND_JSON" \
  "$STATIC_DEMAND_SIG" \
  "$AUTOTUNE_TIER2_JSON" <<'PY'
import hashlib, json, pathlib, re, sys

proof = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
pool = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
if proof.get("provider_id") != sys.argv[3] or not isinstance(proof.get("launchd_pid"), int):
    raise SystemExit("canary proof is not bound to the selected provider and live process")
local_status = proof.get("local_status", {})
local_catalog = local_status.get("catalog", {})
local_coordinator = local_status.get("coordinator", {})
pool_row = str(pool.get("catalog_row_identity", "")).lower()
if (
    pool.get("provider_id") != sys.argv[3]
    or pool.get("assigned_id") != proof.get("assigned_id")
    or local_status.get("network_state") != "buyer_serving"
    or local_coordinator.get("connected") is not True
    or local_coordinator.get("session") != proof.get("assigned_id")
    or re.fullmatch(r"[0-9a-f]{64}", pool_row) is None
    or local_catalog.get("release_id") != pool.get("catalog_release_id")
    or local_catalog.get("policy_version") != pool.get("catalog_policy_version")
    or str(local_catalog.get("digest", "")).lower() != str(pool.get("catalog_candidate_sha256", "")).lower()
    or local_catalog.get("signer_key_id") != pool.get("catalog_signer_key_id")
    or str(local_catalog.get("row_identity", "")).lower() != pool_row
):
    raise SystemExit("canary local catalog proof is not bound to the coordinator-admitted envelope")
actual = proof.get("files")
if not isinstance(actual, dict):
    raise SystemExit("canary proof is missing installed file hashes")
expected = {}
for raw_path in sys.argv[4:]:
    path = pathlib.Path(raw_path)
    expected[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
if actual != expected:
    missing = sorted(set(expected) - set(actual))
    extra = sorted(set(actual) - set(expected))
    changed = sorted(name for name in set(actual) & set(expected) if actual[name] != expected[name])
    raise SystemExit(f"canary catalog byte mismatch: missing={missing} extra={extra} changed={changed}")
PY
then
  echo "SPEC-023 canary failed: installed catalog bytes do not match the verified deployment release" >&2
  exit 1
fi
echo "  SPEC-023 exact-byte canary OK: selected provider's live process uses the verified catalog release"

# R3+R4+R5 stats smoke check on STATS_DOMAIN.
#
# R5 ARCH MED-1: coordinator's `stats.enabled` defaults FALSE — when
# it's not set or set to false, /v1/stats/* routes don't exist. Hitting
# them blind would flag a perfectly valid stats-disabled deploy as
# degraded. Parse `stats.enabled` from the same effective coordinator.yaml
# the restarted service uses; gate the smoke check on it.
STATS_ENABLED_LOCAL="$(yaml_block_value stats enabled)"
if [ "$STATS_ENABLED_LOCAL" = "true" ]; then
  STATS_SMOKE_NONCE="${BACKUP_TS:-$(date -u +%Y%m%dT%H%M%SZ)}-$$"
  echo "  GET https://$STATS_DOMAIN/v1/stats/health?deploy_smoke=<nonce> -> expect 200"
  # R4 CODE/SEC convergent HIGH — DON'T use `STATS=$(curl ... || echo 000)`:
  # curl prints `000` to stdout AND exits non-zero on TLS/DNS failure, so
  # the `|| echo 000` appends another `000` producing `STATS=000000` and
  # silently passing the `[ "$STATS" = "000" ]` failure branch.
  if ! STATS_STATUS=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://$STATS_DOMAIN/v1/stats/health?deploy_smoke=$STATS_SMOKE_NONCE" 2>/dev/null); then
    STATS_STATUS="000"
  fi
  if [ "$STATS_STATUS" != "200" ]; then
    if [ "$STATS_STATUS" = "000" ]; then
      echo "  ABORT: $STATS_DOMAIN /v1/stats/health unreachable (TLS handshake or DNS failed)" >&2
    else
      echo "  ABORT: $STATS_DOMAIN /v1/stats/health returned status=$STATS_STATUS (expected 200)" >&2
    fi
    echo "  stats.enabled=true in $DEPLOY_CONFIG — public stats smoke is mandatory." >&2
    exit 9
  fi
  echo "  ok: $STATS_DOMAIN /v1/stats/health responded 200"

  echo "  GET https://$STATS_DOMAIN/v1/stats/overview?deploy_smoke=<nonce> with Malibu Origin -> expect 200 + CORS"
  STATS_HEADERS="$(mktemp -t macprovider-stats-headers.XXXXXX)"
  if ! STATS_OVERVIEW_STATUS=$(curl -sS -D "$STATS_HEADERS" -o /dev/null -w '%{http_code}' --max-time 10 -H "Origin: https://www.malibu.tech" "https://$STATS_DOMAIN/v1/stats/overview?deploy_smoke=$STATS_SMOKE_NONCE" 2>/dev/null); then
    STATS_OVERVIEW_STATUS="000"
  fi
  if [ "$STATS_OVERVIEW_STATUS" != "200" ]; then
    echo "  ABORT: $STATS_DOMAIN /v1/stats/overview returned status=$STATS_OVERVIEW_STATUS (expected 200)" >&2
    rm -f "$STATS_HEADERS"
    exit 9
  fi
  if ! tr -d '\r' < "$STATS_HEADERS" | grep -Eiq '^access-control-allow-origin:[[:space:]]*(\*|https://www\.malibu\.tech)[[:space:]]*$'; then
    echo "  ABORT: $STATS_DOMAIN /v1/stats/overview did not return a Malibu-compatible Access-Control-Allow-Origin header" >&2
    sed 's/^/    /' "$STATS_HEADERS" >&2
    rm -f "$STATS_HEADERS"
    exit 9
  fi
  rm -f "$STATS_HEADERS"
  echo "  ok: $STATS_DOMAIN /v1/stats/overview responded 200 with Malibu-compatible CORS"

  echo "  GET https://$STATS_DOMAIN/v1/stats/leaderboard?deploy_smoke=<nonce> -> expect 200"
  if ! STATS_LEADERBOARD_STATUS=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://$STATS_DOMAIN/v1/stats/leaderboard?deploy_smoke=$STATS_SMOKE_NONCE" 2>/dev/null); then
    STATS_LEADERBOARD_STATUS="000"
  fi
  if [ "$STATS_LEADERBOARD_STATUS" != "200" ]; then
    echo "  ABORT: $STATS_DOMAIN /v1/stats/leaderboard returned status=$STATS_LEADERBOARD_STATUS (expected 200)" >&2
    echo "  stats.enabled=true in $DEPLOY_CONFIG — Malibu stats population smoke is mandatory." >&2
    exit 9
  else
    echo "  ok: $STATS_DOMAIN /v1/stats/leaderboard responded 200"
  fi
else
  # Stats disabled in deployed config. If STATS_REQUIRED=1, the operator
  # explicitly asked for strict mode but disabled stats — that's
  # incoherent; refuse. Otherwise just log and skip.
  if [ "${STATS_REQUIRED:-0}" = "1" ]; then
    echo "  ABORT: STATS_REQUIRED=1 but stats.enabled is not true in $DEPLOY_CONFIG." >&2
    echo "         Enable stats in coordinator.yaml or drop STATS_REQUIRED=1." >&2
    exit 9
  fi
  echo "  stats.enabled is not true in $DEPLOY_CONFIG — skipping $STATS_DOMAIN smoke check"
fi

log "step 9/9: tail the coordinator journal for sanity"
$SSH 'journalctl -u macprovider-coordinator --no-pager -n 20'

$SSH 'set -e
  exec 8>/opt/macprovider/.coordinator-deploy-operation.lock
  flock -s 8
  # Sidecars remain frozen until every coordinator/catalog/canary check has
  # passed. Activate them as the final transaction mutation, immediately
  # before the commit marker.
  _sidecar_prior=/opt/macprovider/.coordinator-deploy-sidecar-prior-state
  if [ ! -r "$_sidecar_prior" ]; then
    echo "aborting deploy: missing stats-inventory prior state at final activation" >&2
    exit 13
  fi
  assert_stats_inventory_quiescent() {
    _timer_enabled=$(systemctl is-enabled stats-inventory-sync.timer 2>/dev/null || true)
    _timer_active=$(systemctl is-active stats-inventory-sync.timer 2>/dev/null || true)
    _service_active=$(systemctl is-active stats-inventory-sync.service 2>/dev/null || true)
    if [ "$_timer_enabled" != disabled ] ||
       [ "$_timer_active" != inactive ]; then
      echo "aborting deploy: stats-inventory timer did not remain disabled/inactive after parity hold (enabled=$_timer_enabled active=$_timer_active)" >&2
      exit 13
    fi
    case "$_service_active" in
      inactive|failed) ;;
      *)
        echo "aborting deploy: stats-inventory service did not remain quiescent after parity hold (active=$_service_active)" >&2
        exit 13
        ;;
    esac
  }
  _parity_required=$(sed -n "s/^parity_required=//p" "$_sidecar_prior")
  case "$_parity_required" in
    present)
      systemctl disable --now stats-inventory-sync.timer
      systemctl stop stats-inventory-sync.service
      assert_stats_inventory_quiescent
      touch /opt/macprovider/.coordinator-deploy-sidecar-parity-required
      echo "stats inventory timer remains disabled: pre-existing schema/binary parity marker requires a matching sidecar promotion"
      ;;
    absent) ;;
    *)
      echo "aborting deploy: invalid stats-inventory parity state at final activation" >&2
      exit 13
      ;;
  esac
  if [ "$_parity_required" = absent ] && [ -f /etc/macprovider-stats/stats-hardware-inventory.yaml ] && [ -f /etc/macprovider-stats/stats-inventory-sync.env ]; then
    systemctl enable --now stats-inventory-sync.timer
    if ! systemctl start stats-inventory-sync.service; then
      systemctl disable --now stats-inventory-sync.timer
      systemctl stop stats-inventory-sync.service
      assert_stats_inventory_quiescent
      echo "warning: stats-inventory-sync.service failed; leaving coordinator deploy running with its parity marker and timer disabled"
      journalctl -u stats-inventory-sync.service -n 30 --no-pager || true
    else
      rm -f /opt/macprovider/.coordinator-deploy-sidecar-parity-required
      systemctl is-active stats-inventory-sync.timer
    fi
  elif [ "$_parity_required" = absent ] && [ -f /opt/macprovider/.coordinator-deploy-rollback/stats-inventory-timer-was-active ]; then
    systemctl start stats-inventory-sync.timer
    [ ! -f /opt/macprovider/.coordinator-deploy-rollback/stats-inventory-service-was-active ] || systemctl start stats-inventory-sync.service
  elif [ "$_parity_required" = absent ]; then
    echo "stats inventory timer not enabled: missing /etc/macprovider-stats/stats-hardware-inventory.yaml or stats-inventory-sync.env"
  fi
  if [ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/request-log.sqlite ] && su -s /bin/sh -c "test -r /var/lib/macprovider/request-log.sqlite" macprovider-stats; then
    systemctl enable --now stats-billing-mirror.timer
    if ! systemctl start stats-billing-mirror.service; then
      echo "warning: stats-billing-mirror.service failed; leaving coordinator deploy running"
      journalctl -u stats-billing-mirror.service -n 30 --no-pager || true
    fi
    systemctl is-active stats-billing-mirror.timer
  elif [ -f /opt/macprovider/.coordinator-deploy-rollback/stats-billing-timer-was-active ]; then
    systemctl start stats-billing-mirror.timer
    [ ! -f /opt/macprovider/.coordinator-deploy-rollback/stats-billing-service-was-active ] || systemctl start stats-billing-mirror.service
  else
    echo "stats billing mirror timer not enabled: missing env/sqlite source or macprovider-stats read ACL"
  fi
  if [ -f /etc/macprovider-stats/stats-hardware-verifier.env ]; then
    systemctl enable --now stats-hardware-verifier.timer
    # FIX 7 (issue #582): when hardware-trust approval is enabled (both onboarding
    # trust DSNs configured), the verifier is the only thing that promotes an
    # approved waiting_trust job to verified. A failed INITIAL run must fail the
    # deploy (fatal) rather than be a warning, or operators could commit approvals
    # against a coordinator whose verifier never runs. When approval is NOT enabled
    # the initial run stays best-effort (warn), matching prior behavior.
    hardware_trust_approval_enabled=0
    if [ -r /etc/macprovider/coordinator.env ] \
       && grep -Eq "^[[:space:]]*ONBOARDING_HARDWARE_TRUST_REQUEST_DSN=" /etc/macprovider/coordinator.env \
       && grep -Eq "^[[:space:]]*ONBOARDING_HARDWARE_TRUST_APPROVE_DSN=" /etc/macprovider/coordinator.env; then
      hardware_trust_approval_enabled=1
    fi
    if ! systemctl start stats-hardware-verifier.service; then
      journalctl -u stats-hardware-verifier.service -n 30 --no-pager || true
      if [ "$hardware_trust_approval_enabled" = 1 ]; then
        echo "aborting deploy: stats-hardware-verifier.service failed its initial run and hardware-trust approval is enabled; operator approvals would commit trust roots that never promote to verified" >&2
        exit 13
      fi
      echo "warning: stats-hardware-verifier.service failed; leaving coordinator deploy running"
    fi
    systemctl is-active stats-hardware-verifier.timer
  elif [ -f /opt/macprovider/.coordinator-deploy-rollback/stats-hardware-timer-was-active ]; then
    systemctl start stats-hardware-verifier.timer
    [ ! -f /opt/macprovider/.coordinator-deploy-rollback/stats-hardware-service-was-active ] || systemctl start stats-hardware-verifier.service
  else
    echo "stats hardware verifier timer not enabled: missing /etc/macprovider-stats/stats-hardware-verifier.env"
  fi
  rm -f "$_sidecar_prior"
  touch /opt/macprovider/.coordinator-deploy-rollback/committed
  /opt/macprovider/coordinator-deploy-recover --recover-under-global
'
COORDINATOR_DEPLOY_ARMED=0
log "DONE. coordinator is live at https://$DOMAIN"
echo
echo "Next steps:"
echo "  - Stage 3: restart M4 phase3-binary with --coordinator wss://$DOMAIN/ws/provider"
echo "  - Verify: providers should appear in /poolz (auth: bearer operator_key from coordinator.yaml)"
echo "  - End-to-end: run harness against https://$DOMAIN"
