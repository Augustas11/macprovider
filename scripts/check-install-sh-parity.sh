#!/usr/bin/env bash
# Curl-channel parity gate.
#
# The Malibu app bundles its own copy of install.sh (verified against the signed
# compatibility set at release time), but the public one-liner
# `curl -fsSL https://get.malibu.tech/install.sh | bash` is served as a static
# file from the coordinator host. Cutting a release updates the app bundle and
# the release assets, but nothing republishes that static file automatically, so
# it can silently drift stale (it once lagged ~2 weeks behind, missing the
# python3-CLT guard and the donor-join fix). This check compares the served
# bytes against the repository's dist/install.sh so drift is caught, not shipped.
#
# Semantics: it compares the served file to the dist/install.sh of the CURRENT
# checkout. In the scheduled alarm workflow the checkout is pinned to the latest
# release tag, so "served must equal the released install.sh". Run locally to
# confirm a republish landed. Read-only: no secrets, no writes, no deploy.
#
# Exit codes: 0 = parity (or --allow-ahead and served is a known older release),
#             1 = drift (served != expected), 2 = usage/fetch error.
set -euo pipefail

INSTALL_URL="${INSTALL_SH_URL:-https://get.malibu.tech/install.sh}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_INSTALL="$REPO_ROOT/phase3-binary/dist/install.sh"

sha256() {
  # Portable across the GNU (Linux CI) and BSD (macOS) toolchains.
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

[ -f "$DIST_INSTALL" ] || { echo "error: $DIST_INSTALL not found" >&2; exit 2; }
expected="$(sha256 "$DIST_INSTALL")"

case "$INSTALL_URL" in
  https://*) ;;
  *) echo "error: INSTALL_SH_URL must be an https:// URL (got: $INSTALL_URL)" >&2; exit 2 ;;
esac

served_file="$(mktemp "${TMPDIR:-/tmp}/served-install.XXXXXX")"
trap 'rm -f "$served_file"' EXIT
# `--` before the URL so a value that begins with '-' can never be parsed as a
# curl flag (the URL can be overridden via INSTALL_SH_URL / workflow input).
if ! curl -fsSL --proto '=https' --tlsv1.2 --max-time 30 -o "$served_file" -- "$INSTALL_URL"; then
  echo "error: could not fetch $INSTALL_URL" >&2
  exit 2
fi
served="$(sha256 "$served_file")"

echo "expected (repo dist/install.sh): $expected"
echo "served   ($INSTALL_URL): $served"

if [ "$served" = "$expected" ]; then
  echo "OK: curl-channel install.sh matches the repository install.sh."
  exit 0
fi

cat >&2 <<EOF
DRIFT: the curl-channel install.sh does NOT match the repository install.sh.

The public 'curl -fsSL $INSTALL_URL | bash' path is serving stale or divergent
bytes. Republish the current release's dist/install.sh to the coordinator webroot
(see docs/runbooks/provider-cli-release-verification.md), then re-run this check.
EOF
exit 1
