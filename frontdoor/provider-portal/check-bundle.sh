#!/usr/bin/env bash
# SPEC-014 §8(b) + §8(f) build-time grep guard.
#
# Scans frontdoor/provider-portal/index.html for prohibited strings
# that would violate the privileged-key isolation invariant (AC 8(b))
# or the single-machine copy hygiene invariant (AC 8(f)).
#
# Exit codes:
#   0 — bundle is clean
#   1 — bundle contains one or more prohibited strings
#   2 — index.html missing
#
# Self-protection: every prohibited literal that this script needs to
# match in the bundle is stored as a CONCATENATED string literal in
# this source file (e.g. "/po""olz", "oper""ator-key"). That way an
# external scan over this script with the SAME grep patterns it
# enforces against the bundle does not produce false positives from
# this script's own comments, variables, or echo messages.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="$HERE/index.html"

if [[ ! -f "$BUNDLE" ]]; then
  echo "check-bundle: $BUNDLE not found" >&2
  exit 2
fi

fail=0

# AC 8(b) — privileged-routes literal list. The bundle must never
# reference any privileged-key coordinator endpoint, even in
# comments. Literals split via Bash string concatenation.
op_routes=(
  "/po""olz"
  "/adm""in/blacklist"
  "/adm""in/provisional"
  "/adm""in/promote"
  "/adm""in/reject"
  "/adm""in/ledger"
)
priv_route_label="priv""ileged-key route"
for p in "${op_routes[@]}"; do
  if grep -Fq "$p" "$BUNDLE"; then
    echo "FAIL [8(b)]: bundle references $priv_route_label: $p" >&2
    fail=1
  fi
done

# AC 8(b) — privileged-key identifier. The bundle must never prompt
# for, parse, or transmit a privileged key. The regex itself is
# split so this script does not self-match.
op_key_pat="oper""ator[_-]?key"
priv_key_label="priv""ileged key identifier"
if grep -Eiq "$op_key_pat" "$BUNDLE"; then
  echo "FAIL [8(b)]: bundle references $priv_key_label — the portal must never prompt for or transmit it" >&2
  fail=1
fi

# AC 8(f) — single-machine copy hygiene. v0.1 is single-machine
# only; copy implying a fleet, grid, or aggregation is forbidden.
# All literals split for self-protection.
multi_machine=(
  "your fl""eet"
  "your mach""ines"
  "across mach""ines"
  "all mach""ines"
  "N mach""ines"
  "N/""M"
  "x""3"
  "machine gr""id"
)
for p in "${multi_machine[@]}"; do
  if grep -Fiq "$p" "$BUNDLE"; then
    echo "FAIL [8(f)]: bundle contains prohibited multi-machine string: $p" >&2
    fail=1
  fi
done

if [[ $fail -eq 0 ]]; then
  echo "check-bundle: OK"
fi
exit $fail
