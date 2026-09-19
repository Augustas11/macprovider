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
# only latest_release_tag(), and runs it against the live unauthenticated
# GitHub Releases API — the same view a fresh host gets. It then asserts the
# resolved tag's checksums.txt and a darwin-arm64 platform asset are HTTP 200.
# An authenticated probe is not faithful (drafts become visible; #1588).
#
# Read-only: no secrets, no writes, no deploy. Do not source/run install.sh
# main. Exit codes: 0 = healthy, 1 = consumer surface down, 2 = probe error.
set -euo pipefail

PREFIX="[install-sh-consumer-health]"
INSTALL_URL="${INSTALL_SH_URL:-https://get.malibu.tech/install.sh}"
INSTALL_FILE="${INSTALL_SH_FILE:-}"
GITHUB_REPO_PIN="Augustas11/macprovider"
RESOLVER_TIMEOUT_SEC="${INSTALL_SH_RESOLVER_TIMEOUT_SEC:-120}"
ASSET_TIMEOUT_SEC="${INSTALL_SH_ASSET_TIMEOUT_SEC:-30}"
MAX_INSTALL_BYTES="${INSTALL_SH_MAX_BYTES:-5242880}"

die_probe() { printf '%s error: %s\n' "$PREFIX" "$*" >&2; exit 2; }
alarm() { printf '%s ALARM: %s\n' "$PREFIX" "$*" >&2; exit 1; }
ok() { printf '%s OK: %s\n' "$PREFIX" "$*"; }

[[ "$RESOLVER_TIMEOUT_SEC" =~ ^[1-9][0-9]*$ ]] || die_probe "INSTALL_SH_RESOLVER_TIMEOUT_SEC must be a positive integer"
[[ "$ASSET_TIMEOUT_SEC" =~ ^[1-9][0-9]*$ ]] || die_probe "INSTALL_SH_ASSET_TIMEOUT_SEC must be a positive integer"
[[ "$MAX_INSTALL_BYTES" =~ ^[1-9][0-9]*$ ]] || die_probe "INSTALL_SH_MAX_BYTES must be a positive integer"

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

LIB="$WORKDIR/latest_release_tag.sh"
awk '
  /^latest_release_tag\(\)/ { emit = 1; print; next }
  emit && /^[A-Za-z_][A-Za-z0-9_]*\(\)/ { exit }
  emit { print }
' "$SERVED" > "$LIB"
grep -q '^latest_release_tag()' "$LIB" || alarm "served install.sh has no latest_release_tag() function"
if grep -qE '^(download_release|version_at_least)\(\)' "$LIB"; then
  alarm "extracted latest_release_tag() leaked a neighboring function (extractor over-scanned)"
fi

TAG_FILE="$WORKDIR/tag"
ERR_FILE="$WORKDIR/resolver.err"
set +e
python3 - "$RESOLVER_TIMEOUT_SEC" "$LIB" "$TAG_FILE" "$ERR_FILE" "$GITHUB_REPO_PIN" "$PROBE_HOME" <<'PY'
import os
import subprocess
import sys

timeout_s, lib, tag_file, err_file, repo, probe_home = sys.argv[1:7]
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
die() {
  code="$1"
  shift
  printf 'die[%s] %s\n' "$code" "$*" >&2
  exit "$code"
}
# shellcheck disable=SC1090
. "$1"
latest_release_tag
"""
try:
    completed = subprocess.run(
        ["bash", "-c", script, "resolver", lib, repo],
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
  alarm "served latest_release_tag hung (${RESOLVER_TIMEOUT_SEC}s): ${resolver_err:-no stderr}"
fi
if [ "$resolver_rc" -ne 0 ]; then
  alarm "served latest_release_tag failed (exit ${resolver_rc}): ${resolver_err:-no stderr}"
fi
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || alarm "served latest_release_tag returned a non-stable tag: ${tag:-<empty>}"
ok "served latest_release_tag resolved $tag"

base="https://github.com/${GITHUB_REPO_PIN}/releases/download/${tag}"
checksums="$WORKDIR/checksums.txt"
if ! "${CURL_SAFE[@]}" -fsSL --connect-timeout 15 --max-time "$ASSET_TIMEOUT_SEC" \
  -o "$checksums" -- "$base/checksums.txt"; then
  alarm "checksums.txt is not HTTP 200 for $tag ($base/checksums.txt)"
fi
[ -s "$checksums" ] || alarm "checksums.txt for $tag is empty"
ok "checksums.txt HTTP 200 ($(wc -c < "$checksums" | tr -d ' ') bytes)"
checksums_sig="$WORKDIR/checksums.txt.sig"
if ! "${CURL_SAFE[@]}" -fsSL --connect-timeout 15 --max-time "$ASSET_TIMEOUT_SEC" \
  -o "$checksums_sig" -- "$base/checksums.txt.sig"; then
  alarm "checksums.txt.sig is not HTTP 200 for $tag ($base/checksums.txt.sig)"
fi
[ -s "$checksums_sig" ] || alarm "checksums.txt.sig for $tag is empty"
ok "checksums.txt.sig HTTP 200 ($(wc -c < "$checksums_sig" | tr -d ' ') bytes)"

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
pkg_code="$(asset_http_code "$base/$pkg_asset" || true)"
if [ "$pkg_code" = "200" ] || [ "$pkg_code" = "206" ]; then
  ok "$pkg_asset HTTP $pkg_code"
  exit 0
fi
tar_code="$(asset_http_code "$base/$tar_asset" || true)"
if [ "$tar_code" = "200" ] || [ "$tar_code" = "206" ]; then
  ok "$tar_asset HTTP $tar_code (pkg was ${pkg_code:-000})"
  exit 0
fi
alarm "no darwin-arm64 platform asset for $tag (pkg HTTP ${pkg_code:-000}, tar.gz HTTP ${tar_code:-000})"
