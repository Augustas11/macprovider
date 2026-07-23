#!/usr/bin/env bash
#
# CI macOS path-gate detector.
#
# Emits two booleans that gate the two per-PR macOS jobs in
# .github/workflows/ci.yml:
#   swift -> phase3-binary (swift test) job
#   code  -> spec-015-acceptance (cross-service money-path acceptance) job
#
# Usage: ci-detect-changed-paths.sh <base_sha> <head_sha>
# Prints "swift=<bool>\ncode=<bool>" to stdout, appends the same to
# $GITHUB_OUTPUT when set, and writes a human summary to $GITHUB_STEP_SUMMARY
# when set.
#
# SAFETY — this gate must never skip a job a real change depends on:
#   * FAIL OPEN: any inability to resolve the diff (missing/zero/unknown SHA,
#     git error) leaves BOTH booleans true so every macOS job still runs.
#   * RENAME SAFE: `--no-renames` surfaces a move as delete+add so the
#     pre-image path (e.g. a Swift file renamed out of phase3-binary) is never
#     hidden behind an exempt destination.
#   * NUL SAFE: `-z` disables git's C-quoting of unusual/Unicode paths, which
#     would otherwise defeat the phase3-binary/* glob; parsed via read -d ''.
#   * The Swift suites load shared cross-language fixtures that live OUTSIDE
#     phase3-binary (kept in sync with the parity tests below); those specific
#     fixture directories are part of the swift gate.
set -euo pipefail

base="${1:-}"
head="${2:-}"

swift=true
code=true
zero="0000000000000000000000000000000000000000"
matched_swift=0
matched_code=0
total=0

classify() {
  # Reads NUL-delimited pathnames on stdin; sets swift/code and counters.
  local f
  swift=false
  code=false
  while IFS= read -r -d '' f; do
    [ -n "$f" ] || continue
    total=$((total + 1))
    case "$f" in
      # phase3-binary sources; the build/xcodegen/sparkle scripts the Swift
      # job invokes; the Makefile; this workflow; AND the shared cross-language
      # fixtures the Swift parity/losslessness/settlement suites read from
      # other modules. Keep this list in sync with the Swift tests under
      # phase3-binary/Tests and phase3-binary/app/Tests.
      phase3-binary/*|scripts/*|Makefile|.github/workflows/ci.yml|\
      phase7-verify/testdata/*|phase4-coordinator/test/jcs_fixtures/*|testdata/*)
        swift=true
        matched_swift=$((matched_swift + 1)) ;;
    esac
    case "$f" in
      # spec-015-acceptance is skipped only for documentation-only PRs: the
      # docs/ tree and root-level Markdown. ANY file nested in a directory —
      # including a nested *.md that could be a test fixture — is significant.
      docs/*) : ;;
      */*) code=true; matched_code=$((matched_code + 1)) ;;
      *.md) : ;;
      *) code=true; matched_code=$((matched_code + 1)) ;;
    esac
  done
}

if [ -n "$base" ] && [ -n "$head" ] && [ "$base" != "$zero" ] \
   && git cat-file -e "${base}^{commit}" 2>/dev/null \
   && git cat-file -e "${head}^{commit}" 2>/dev/null; then
  tmp="$(mktemp)"
  # NUL-delimited output cannot be held in a shell variable; stream via file.
  if git diff --no-renames -z --name-only "$base" "$head" >"$tmp" 2>/dev/null; then
    classify <"$tmp"
    resolved=yes
  else
    resolved=no
  fi
  rm -f "$tmp"
else
  resolved=no
fi

printf 'swift=%s\ncode=%s\n' "$swift" "$code"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'swift=%s\ncode=%s\n' "$swift" "$code" >>"$GITHUB_OUTPUT"
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### CI macOS path-gate"
    echo ""
    echo "- diff resolved: ${resolved}"
    echo "- changed files: ${total}"
    echo "- swift-tests: **$([ "$swift" = true ] && echo run || echo skip)** (matched ${matched_swift})"
    echo "- spec-015-acceptance: **$([ "$code" = true ] && echo run || echo skip)** (matched ${matched_code})"
  } >>"$GITHUB_STEP_SUMMARY"
fi
