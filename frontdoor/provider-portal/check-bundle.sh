#!/usr/bin/env bash
# SPEC-014 §8(b), §8(f), and v0.2 §14 build-time grep guard.
#
# Scans frontdoor/provider-portal/index.html for prohibited strings
# that would violate the privileged-key isolation invariant (AC 8(b))
# or the single-machine copy hygiene invariant (AC 8(f)).
#
# Exit codes:
#   0 — bundle is clean
#   1 — bundle contains one or more prohibited strings
#   2 — index.html missing or guard self-test broken
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

storage_patterns=(
  '\bdocument[[:space:]]*\.[[:space:]]*cookie\b'
  '\bdocument[[:space:]]*\[[[:space:]]*['"'"'"]cookie['"'"'"][[:space:]]*\]'
  '\bdocument[[:space:]]*\[[[:space:]]*['"'"'"]\\(x63|u0063)'
  '\b(localStorage|sessionStorage)\b'
  '\bwindow[[:space:]]*\[[[:space:]]*['"'"'"](localStorage|sessionStorage)['"'"'"][[:space:]]*\]'
  '\bindexedDB\b'
  '\bopenDatabase\b'
  '\bnavigator[[:space:]]*\.[[:space:]]*storage\b'
)

guard_broken() {
  echo "check-bundle: guard broken: $*" >&2
  exit 2
}

grep_matches() {
  local pattern="$1"
  local source="$2"
  printf '%s\n' "$source" | grep -Eq "$pattern"
}

rg_matches() {
  local pattern="$1"
  local source="$2"
  if ! command -v rg >/dev/null 2>&1; then
    return 0
  fi
  printf '%s\n' "$source" | rg --pcre2 -q "$pattern"
}

assert_match() {
  local n="$1"
  local sample="$2"
  local pattern="${storage_patterns[$((n - 1))]}"
  grep_matches "$pattern" "$sample" || guard_broken "regex $n positive did not match under grep"
  rg_matches "$pattern" "$sample" || guard_broken "regex $n positive did not match under rg --pcre2"
}

assert_no_match() {
  local n="$1"
  local sample="$2"
  local pattern="${storage_patterns[$((n - 1))]}"
  if grep_matches "$pattern" "$sample"; then
    guard_broken "regex $n negative matched under grep"
  fi
  if command -v rg >/dev/null 2>&1 && printf '%s\n' "$sample" | rg --pcre2 -q "$pattern"; then
    guard_broken "regex $n negative matched under rg --pcre2"
  fi
}

run_storage_guard_self_test() {
  assert_match 1 'document.cookie = "x=y"'
  assert_no_match 1 "const cookieless_login_message = 'foo'"

  assert_match 2 'document["cookie"] = "x=y"'
  assert_no_match 2 'document["cookieless"] = "x"'

  assert_match 3 'document["\x63ookie"] = "x=y"'
  assert_match 3 'document["\u0063ookie"] = "x=y"'
  assert_no_match 3 'document["cookieless"] = "x"'

  assert_match 4 "localStorage.setItem('x','y')"
  assert_match 4 "sessionStorage.setItem('x','y')"
  assert_no_match 4 'const localStorageDocs = "..."'

  assert_match 5 'window["localStorage"].setItem("x","y")'
  assert_match 5 'window["sessionStorage"].setItem("x","y")'
  assert_no_match 5 'window["localStorageDocs"] = "..."'

  assert_match 6 "indexedDB.open('x')"
  assert_no_match 6 'const indexedDBDocs = "..."'

  assert_match 7 "openDatabase('x', '1', 'x', 1024)"
  assert_no_match 7 'const openDatabaseDocs = "..."'

  assert_match 8 'navigator.storage.estimate()'
  assert_no_match 8 'navigatorStorage.estimate()'
}

run_storage_guard_self_test

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

# SPEC-021 v0.1.1 — a loaded MALIBU projection that omits the
# coordinator-owned reward eligibility object must fail closed instead of
# rendering raw withdrawable fields as authoritative.
if ! perl -0ne 'exit(/function normalizedMalibuRewardEligibility\(data\).*?if \(!data\) return null;.*?if \(!data\.reward_eligibility \|\| typeof data\.reward_eligibility !== "object"\) \{\s*reportMalibuRewardEligibilitySchemaDrift\("", "reward_eligibility"\);\s*return unavailableMalibuRewardEligibility\(""\);\s*\}/s ? 0 : 1)' "$BUNDLE"; then
  echo "FAIL [SPEC-021]: missing reward_eligibility must normalize to unavailable" >&2
  fail=1
fi

for idx in "${!storage_patterns[@]}"; do
  n=$((idx + 1))
  pattern="${storage_patterns[$idx]}"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "$line: matched regex $n ($pattern)" >&2
    fail=1
  done < <(grep -En "$pattern" "$BUNDLE" || true)
done

if [[ $fail -eq 0 ]]; then
  echo "check-bundle: OK"
fi
exit $fail
