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
# Byte identity only. Resolver health (served latest_release_tag() against the
# live unauthenticated GitHub API, plus checksums/asset HTTP 200) is
# scripts/check-install-sh-consumer-health.sh /
# .github/workflows/install-sh-consumer-health-alarm.yml (#1588).
#
# Mid-train grace (#2210; alarm noise only, nothing is served or switched off):
# the train republishes install.sh shortly after promotion, so for a short
# window the served script is still the PREVIOUS release's. Drift is reported
# OK only when ALL hold:
#   INSTALL_SH_PREVIOUS_FILE        the previous release's dist/install.sh, and
#                                   the served bytes equal it exactly;
#   INSTALL_SH_LATEST_PUBLISHED_AT  the expected release's publish time
#                                   (YYYY-MM-DDTHH:MM:SSZ), at most
#   INSTALL_SH_TRAIN_GRACE_MINUTES  minutes ago (default 120).
# Anything else (other bytes, an unknown or future publish time, the grace
# exceeded) is drift. INSTALL_SH_NOW_EPOCH overrides the clock for tests.
#
# Exit codes: 0 = parity (or mid-train grace), 1 = drift (served != expected),
#             2 = usage/fetch error.
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

# within_train_grace SERVED_SHA -> 0 (and a note) when the mid-train grace holds.
within_train_grace() {
  local previous="${INSTALL_SH_PREVIOUS_FILE:-}" published="${INSTALL_SH_LATEST_PUBLISHED_AT:-}"
  local grace="${INSTALL_SH_TRAIN_GRACE_MINUTES:-120}" age
  [ -n "$previous" ] && [ -f "$previous" ] && [ -n "$published" ] || return 1
  [[ "$grace" =~ ^[0-9]+$ ]] || { echo "error: INSTALL_SH_TRAIN_GRACE_MINUTES must be a whole number" >&2; return 1; }
  [ "$1" = "$(sha256 "$previous")" ] || return 1
  age="$(python3 -c '
import sys, time
from datetime import datetime, timezone
try:
    at = datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    now = float(sys.argv[2]) if sys.argv[2] else time.time()
except ValueError:
    sys.exit(1)
print(int(now - at))
' "$published" "${INSTALL_SH_NOW_EPOCH:-}")" || return 1
  [ "$age" -ge 0 ] && [ "$age" -le $((grace * 60)) ] || return 1
  echo "OK (mid-train grace): served install.sh is the previous release's; the expected release was published ${age}s ago (grace ${grace} min). The train's install_sh_republish step is still due."
}

if within_train_grace "$served"; then
  exit 0
fi

cat >&2 <<EOF
DRIFT: the curl-channel install.sh does NOT match the repository install.sh.

The public 'curl -fsSL $INSTALL_URL | bash' path is serving stale or divergent
bytes. Republish the current release's dist/install.sh to the coordinator webroot
(see docs/runbooks/provider-cli-release-verification.md), then re-run this check.
EOF
exit 1
