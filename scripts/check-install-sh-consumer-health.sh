#!/usr/bin/env bash
# Consumer-surface health gate for the public one-liner installer.
#
# Byte-parity (scripts/check-install-sh-parity.sh) only asserts served
# install.sh SHA-256 == the latest stable tag's phase3-binary/dist/install.sh.
# That stayed green during the #1574 outage because the served copy *was*
# v1.8.123, and v1.8.123's latest_release_tag() fetched only ?per_page=30 —
# 30 leading prereleases hid the stable tag, the resolver died 3, and
# checksums.txt 404'd. Parity cannot see that class of failure.
#
# This check fetches the SERVED installer (not the checkout copy), extracts
# only its release-discovery functions, and runs them unauthenticated — the
# same view a fresh host gets. A served installer with
# discover_latest_release_tag() resolves exactly as an unpinned install does:
# the coordinator-advertised release first and the anonymous GitHub Releases
# API only as its fallback (#2036), so this gate does not depend on the
# 60-requests-per-hour anonymous api.github.com budget of the runner's IP. An
# older served installer is probed through its latest_release_tag() alone.
# The resolved tag's checksums.txt and checksums.txt.sig are fetched from
# GitHub Releases or the byte-identical download.malibu.tech mirror and the
# signature is verified with the served installer's embedded release key
# (a bad signature is an alarm, never a fallback); a darwin-arm64 platform
# asset must then answer HTTP 200 from either host.
# An authenticated probe is not faithful (drafts become visible; #1588).
#
# Read-only: no secrets, no writes, no deploy. Do not source/run install.sh
# main. Exit codes: 0 = healthy, 1 = consumer surface down, 2 = probe error.
set -euo pipefail

PREFIX="[install-sh-consumer-health]"
INSTALL_URL="${INSTALL_SH_URL:-https://get.malibu.tech/install.sh}"
INSTALL_FILE="${INSTALL_SH_FILE:-}"
GITHUB_REPO_PIN="Augustas11/macprovider"
COORDINATOR_BASE="${INSTALL_SH_COORDINATOR_BASE:-https://coordinator.malibu.tech}"
RELEASE_MIRROR_BASE="https://download.malibu.tech/releases"
RESOLVER_TIMEOUT_SEC="${INSTALL_SH_RESOLVER_TIMEOUT_SEC:-120}"
ASSET_TIMEOUT_SEC="${INSTALL_SH_ASSET_TIMEOUT_SEC:-30}"
MAX_INSTALL_BYTES="${INSTALL_SH_MAX_BYTES:-5242880}"

die_probe() { printf '%s error: %s\n' "$PREFIX" "$*" >&2; exit 2; }
alarm() { printf '%s ALARM: %s\n' "$PREFIX" "$*" >&2; exit 1; }
ok() { printf '%s OK: %s\n' "$PREFIX" "$*"; }

[[ "$RESOLVER_TIMEOUT_SEC" =~ ^[1-9][0-9]*$ ]] || die_probe "INSTALL_SH_RESOLVER_TIMEOUT_SEC must be a positive integer"
[[ "$ASSET_TIMEOUT_SEC" =~ ^[1-9][0-9]*$ ]] || die_probe "INSTALL_SH_ASSET_TIMEOUT_SEC must be a positive integer"
[[ "$MAX_INSTALL_BYTES" =~ ^[1-9][0-9]*$ ]] || die_probe "INSTALL_SH_MAX_BYTES must be a positive integer"
[[ "$COORDINATOR_BASE" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || die_probe "INSTALL_SH_COORDINATOR_BASE must be an https:// origin (got: $COORDINATOR_BASE)"

# Fresh hosts have no GitHub credentials. Drop every token the runner might
# have inherited so curl/netrc/gh cannot authenticate the resolver by accident.
unset GITHUB_TOKEN GH_TOKEN GH_ENTERPRISE_TOKEN \
  MACPROVIDER_RELEASE_FIXTURE_GITHUB_TOKEN RELEASE_POSTURE_TOKEN \
  MACPROVIDER_GITHUB_REPO NETRC || true

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/install-sh-consumer-health.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT
PROBE_HOME="$WORKDIR/home"
mkdir -p "$PROBE_HOME"
chmod 700 "$PROBE_HOME"
export HOME="$PROBE_HOME"
export CURL_HOME="$PROBE_HOME"
export XDG_CONFIG_HOME="$PROBE_HOME"
export GH_CONFIG_DIR="$PROBE_HOME"
CURL_SAFE=(curl -q --netrc-file /dev/null --proto '=https' --proto-redir '=https' --tlsv1.2)

SERVED="$WORKDIR/install.sh"
if [ -n "$INSTALL_FILE" ]; then
  [ -f "$INSTALL_FILE" ] || die_probe "INSTALL_SH_FILE is not a file: $INSTALL_FILE"
  cp -- "$INSTALL_FILE" "$SERVED" || die_probe "failed to copy INSTALL_SH_FILE"
else
  case "$INSTALL_URL" in
    https://*) ;;
    *) die_probe "INSTALL_SH_URL must be an https:// URL (got: $INSTALL_URL)" ;;
  esac
  if ! "${CURL_SAFE[@]}" -fsSL --connect-timeout 15 --max-time 30 \
    -o "$SERVED" -- "$INSTALL_URL"; then
    die_probe "could not fetch $INSTALL_URL"
  fi
fi
[ -s "$SERVED" ] || die_probe "served install.sh is empty"
served_bytes="$(wc -c < "$SERVED" | tr -d ' ')"
[ "$served_bytes" -le "$MAX_INSTALL_BYTES" ] || die_probe "served install.sh is ${served_bytes} bytes (cap ${MAX_INSTALL_BYTES})"

# Print one top-level function of the served installer, from its definition
# line up to the next top-level function definition.
extract_function() {
  awk -v name="$1" '
    !emit && index($0, name "()") == 1 { emit = 1; print; next }
    emit && /^[A-Za-z_][A-Za-z0-9_]*\(\)/ { exit }
    emit { print }
  ' "$SERVED"
}

LIB="$WORKDIR/latest_release_tag.sh"
extract_function latest_release_tag > "$LIB"
grep -q '^latest_release_tag()' "$LIB" || alarm "served install.sh has no latest_release_tag() function"
if grep -qE '^(download_release|version_at_least)\(\)' "$LIB"; then
  alarm "extracted latest_release_tag() leaked a neighboring function (extractor over-scanned)"
fi

# #2036: the full resolver when the served installer has it.
DISCOVERY_FUNCTIONS="release_mirror_enabled discovered_release_tag_acceptable version_at_least mirror_latest_release_tag discover_latest_release_tag"
RESOLVER_MODE="latest_release_tag"
MIN_SUPPORTED_VERSION=""
if grep -q '^discover_latest_release_tag()' "$SERVED"; then
  RESOLVER_MODE="discover_latest_release_tag"
  for fn in $DISCOVERY_FUNCTIONS; do
    extract_function "$fn" > "$WORKDIR/fn.sh"
    grep -q "^${fn}()" "$WORKDIR/fn.sh" || alarm "served install.sh has discover_latest_release_tag() but no ${fn}()"
    cat "$WORKDIR/fn.sh" >> "$LIB"
  done
  MIN_SUPPORTED_VERSION="$(sed -n 's/^MACPROVIDER_MIN_SUPPORTED_VERSION="\(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)"$/\1/p' "$SERVED" | head -n 1)"
  [ -n "$MIN_SUPPORTED_VERSION" ] || alarm "served install.sh has no MACPROVIDER_MIN_SUPPORTED_VERSION rollback floor"
fi

TAG_FILE="$WORKDIR/tag"
ERR_FILE="$WORKDIR/resolver.err"
set +e
python3 - "$RESOLVER_TIMEOUT_SEC" "$LIB" "$TAG_FILE" "$ERR_FILE" "$GITHUB_REPO_PIN" "$PROBE_HOME" \
  "$RESOLVER_MODE" "$MIN_SUPPORTED_VERSION" "$COORDINATOR_BASE" <<'PY'
import os
import subprocess
import sys

timeout_s, lib, tag_file, err_file, repo, probe_home, mode, min_supported, coordinator = sys.argv[1:10]
env = os.environ.copy()
for key in (
    "GITHUB_TOKEN",
    "GH_TOKEN",
    "GH_ENTERPRISE_TOKEN",
    "MACPROVIDER_RELEASE_FIXTURE_GITHUB_TOKEN",
    "RELEASE_POSTURE_TOKEN",
    "MACPROVIDER_GITHUB_REPO",
    "NETRC",
):
    env.pop(key, None)
env["HOME"] = probe_home
env["CURL_HOME"] = probe_home
env["XDG_CONFIG_HOME"] = probe_home
env["GH_CONFIG_DIR"] = probe_home
script = r"""
set -euo pipefail
GITHUB_REPO="$2"
RELEASE_MIRROR_REPO="$2"
RELEASE_MIRROR_FIRST=0
RELEASE_GITHUB_UNREACHABLE=0
MACPROVIDER_MIN_SUPPORTED_VERSION="$4"
coordinator_base="$5"
# A fresh host: no installed provider binary to protect from a downgrade.
BINARY_PATH="$6/no-installed-macprovider-cli"
log() { printf '[macprovider-install] %s\n' "$*" >&2; }
die() {
  code="$1"
  shift
  printf 'die[%s] %s\n' "$code" "$*" >&2
  exit "$code"
}
# shellcheck disable=SC1090
. "$1"
"$3"
"""
env.pop("MACPROVIDER_CHECKSUM_PUBLIC_KEY_PEM", None)
try:
    completed = subprocess.run(
        ["bash", "-c", script, "resolver", lib, repo, mode, min_supported, coordinator, probe_home],
        env=env,
        capture_output=True,
        text=True,
        timeout=int(timeout_s),
    )
except subprocess.TimeoutExpired:
    with open(err_file, "w", encoding="utf-8") as fh:
        fh.write(f"latest_release_tag exceeded {timeout_s}s\n")
    open(tag_file, "w", encoding="utf-8").close()
    sys.exit(124)
with open(tag_file, "w", encoding="utf-8") as fh:
    fh.write(completed.stdout or "")
with open(err_file, "w", encoding="utf-8") as fh:
    fh.write(completed.stderr or "")
sys.exit(completed.returncode)
PY
resolver_rc=$?
set -e
tag="$(tr -d '[:space:]' < "$TAG_FILE" 2>/dev/null || true)"
resolver_err="$(cat "$ERR_FILE" 2>/dev/null || true)"

if [ "$resolver_rc" -eq 124 ]; then
  alarm "served ${RESOLVER_MODE} hung (${RESOLVER_TIMEOUT_SEC}s): ${resolver_err:-no stderr}"
fi
if [ "$resolver_rc" -ne 0 ]; then
  alarm "served ${RESOLVER_MODE} failed (exit ${resolver_rc}): ${resolver_err:-no stderr}"
fi
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || alarm "served ${RESOLVER_MODE} returned a non-stable tag: ${tag:-<empty>}"
ok "served ${RESOLVER_MODE} resolved $tag"

github_base="https://github.com/${GITHUB_REPO_PIN}/releases/download/${tag}"
mirror_base="${RELEASE_MIRROR_BASE}/${tag}"

# fetch_release_file <name> <dest>: GitHub Releases, then the byte-identical
# mirror. Prints the serving host. The signature below is the authority.
fetch_release_file() {
  local name="$1" dest="$2" source
  for source in "$github_base" "$mirror_base"; do
    rm -f "$dest"
    if "${CURL_SAFE[@]}" -fsSL --connect-timeout 15 --max-time "$ASSET_TIMEOUT_SEC" \
      --max-filesize 1048576 -o "$dest" -- "$source/$name" && [ -s "$dest" ]; then
      printf '%s' "${source%%/releases/*}"
      return 0
    fi
  done
  rm -f "$dest"
  return 1
}

checksums="$WORKDIR/checksums.txt"
checksums_host="$(fetch_release_file checksums.txt "$checksums")" \
  || alarm "checksums.txt is not HTTP 200 for $tag from GitHub Releases or the release mirror ($github_base/checksums.txt, $mirror_base/checksums.txt)"
ok "checksums.txt HTTP 200 from $checksums_host ($(wc -c < "$checksums" | tr -d ' ') bytes)"
checksums_sig="$WORKDIR/checksums.txt.sig"
sig_host="$(fetch_release_file checksums.txt.sig "$checksums_sig")" \
  || alarm "checksums.txt.sig is not HTTP 200 for $tag from GitHub Releases or the release mirror ($github_base/checksums.txt.sig)"
ok "checksums.txt.sig HTTP 200 from $sig_host ($(wc -c < "$checksums_sig" | tr -d ' ') bytes)"

# Verify exactly as install.sh does: its embedded release key over checksums.txt.
KEY_FN="$WORKDIR/write_checksum_public_key.sh"
extract_function write_checksum_public_key > "$KEY_FN"
grep -q '^write_checksum_public_key()' "$KEY_FN" || alarm "served install.sh has no write_checksum_public_key() release signing key"
PUBLIC_KEY="$WORKDIR/release-signing-public.pem"
env -u MACPROVIDER_CHECKSUM_PUBLIC_KEY_PEM bash -c '. "$1"; write_checksum_public_key' key "$KEY_FN" > "$PUBLIC_KEY" \
  || alarm "served write_checksum_public_key() failed"
grep -q 'BEGIN PUBLIC KEY' "$PUBLIC_KEY" || alarm "served install.sh release signing key is not a PEM public key"
if ! openssl dgst -sha256 -verify "$PUBLIC_KEY" -signature "$checksums_sig" "$checksums" >/dev/null 2>&1; then
  alarm "checksums.txt.sig for $tag does not verify under the served installer's release key"
fi
ok "checksums.txt signature verified under the served installer's release key"

asset_http_code() {
  local url="$1"
  local code
  code="$(
    "${CURL_SAFE[@]}" -sS --connect-timeout 15 --max-time "$ASSET_TIMEOUT_SEC" \
      -L -o /dev/null -w "%{http_code}" -I -- "$url" || true
  )"
  case "$code" in
    200) printf '%s' "$code"; return 0 ;;
  esac
  code="$(
    "${CURL_SAFE[@]}" -sS --connect-timeout 15 --max-time "$ASSET_TIMEOUT_SEC" \
      -L -o /dev/null -w "%{http_code}" -r 0-0 -- "$url" || true
  )"
  printf '%s' "$code"
  case "$code" in
    200|206) return 0 ;;
  esac
  return 1
}

pkg_asset="macprovider-cli-${tag}-darwin-arm64.pkg"
tar_asset="macprovider-cli-${tag}-darwin-arm64.tar.gz"
codes=""
for asset in "$pkg_asset" "$tar_asset"; do
  # Only an asset the signed checksums.txt names is installable.
  awk -v name="$asset" '$2 == name || $2 == "*" name { found = 1 } END { exit !found }' "$checksums" || {
    codes="${codes}${codes:+, }$asset not in checksums.txt"
    continue
  }
  for source in "$github_base" "$mirror_base"; do
    code="$(asset_http_code "$source/$asset" || true)"
    if [ "$code" = "200" ] || [ "$code" = "206" ]; then
      ok "$asset HTTP $code from ${source%%/releases/*}${codes:+ ($codes)}"
      exit 0
    fi
    codes="${codes}${codes:+, }$asset HTTP ${code:-000} from ${source%%/releases/*}"
  done
done
alarm "no darwin-arm64 platform asset for $tag ($codes)"
