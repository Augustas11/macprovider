#!/usr/bin/env bash
# Issue #191 R1 architect MEDIUM: drift safeguard.
#
# The macprovider-watchdog script body lives in TWO places:
#   1. ops/macprovider-watchdog/watchdog.sh — the standalone source
#      operators can install manually.
#   2. phase3-binary/dist/install.sh:write_watchdog_script — an
#      inlined heredoc the public installer writes to disk.
#
# They MUST stay in sync. This test extracts the heredoc, strips
# comment / blank-line noise (since the inlined copy is intentionally
# tighter than the standalone), and asserts the executable logic is
# identical to the standalone source after the same normalization.
#
# Run via: bash scripts/test-watchdog-inline-drift.sh
# Wired into CI alongside the other phase3-binary smoke checks.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STANDALONE="$REPO_ROOT/ops/macprovider-watchdog/watchdog.sh"
INSTALLER="$REPO_ROOT/phase3-binary/dist/install.sh"

[ -f "$STANDALONE" ] || { echo "missing $STANDALONE" >&2; exit 1; }
[ -f "$INSTALLER" ] || { echo "missing $INSTALLER" >&2; exit 1; }

# Extract the heredoc body. The marker pair is
#   cat <<'WATCHDOG_EOF' > "$WATCHDOG_PATH"
#   ...body...
#   WATCHDOG_EOF
extracted_inline="$(awk '
  /cat <<.WATCHDOG_EOF. > "\$WATCHDOG_PATH"/ { inside=1; next }
  inside && /^WATCHDOG_EOF$/ { exit }
  inside { print }
' "$INSTALLER")"

if [ -z "$extracted_inline" ]; then
  echo "ERROR: could not extract WATCHDOG_EOF heredoc from $INSTALLER" >&2
  exit 1
fi

# Normalize: strip comments (lines starting with whitespace + #),
# blank lines, and trailing whitespace. We compare logic, not
# formatting. The shebang (`#!/usr/bin/env bash` on line 1) is
# explicitly preserved — launchd executes the watchdog script
# directly and a missing shebang would be a runtime failure that
# we want this check to catch.
normalize() {
  awk 'NR == 1 && /^#!/ { print; next } { print }' \
    | sed -E -e 's/[[:space:]]+$//' \
    | grep -Ev '^[[:space:]]*#' \
    | grep -Ev '^[[:space:]]*$'
}

# Shebang sanity: both copies MUST start with the same shebang
# line. The normalize pipeline below strips all `#` lines, so the
# shebang would otherwise pass-through invisibly even if missing
# (R2 architect MEDIUM).
expected_shebang="#!/usr/bin/env bash"
standalone_shebang="$(head -1 "$STANDALONE")"
inline_shebang="${extracted_inline%%$'\n'*}"
if [ "$standalone_shebang" != "$expected_shebang" ]; then
  echo "ERROR: $STANDALONE missing/wrong shebang: $standalone_shebang" >&2
  exit 1
fi
if [ "$inline_shebang" != "$expected_shebang" ]; then
  echo "ERROR: inlined heredoc missing/wrong shebang: $inline_shebang" >&2
  exit 1
fi

normalized_standalone="$(normalize < "$STANDALONE")"
normalized_inline="$(printf "%s\n" "$extracted_inline" | normalize)"

if [ "$normalized_standalone" != "$normalized_inline" ]; then
  echo "ERROR: watchdog drift detected between" >&2
  echo "  standalone: $STANDALONE" >&2
  echo "  inlined  : $INSTALLER:write_watchdog_script" >&2
  echo "Diff (standalone vs inlined, ignoring comments / blank lines):" >&2
  diff <(printf "%s\n" "$normalized_standalone") <(printf "%s\n" "$normalized_inline") >&2 || true
  exit 1
fi

# Also sanity-check bash syntax on both copies.
bash -n "$STANDALONE"
tmp_inline="$(mktemp)"
trap 'rm -f "$tmp_inline"' EXIT
printf "%s\n" "$extracted_inline" > "$tmp_inline"
bash -n "$tmp_inline"

echo "OK: watchdog standalone and inlined heredoc are in sync"
