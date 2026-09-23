# shellcheck shell=bash
# Catalog canary operator-bearer loading and proof (#1688). Shared by
# phase4-coordinator/dist/deploy-pearl-vps.sh and
# scripts/catalog-content-release.sh so both read CATALOG_CANARY_AUTH_TOKEN
# from the same sources (env, 0600 file, macOS Keychain) and prove it is the
# coordinator operator key by digest only. Sourced, never executed. bash 3.2.
# The caller sets CATALOG_CANARY_AUTH_TOKEN, CATALOG_CANARY_AUTH_TOKEN_FILE,
# CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_SERVICE and
# CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_ACCOUNT before calling the loader.

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
