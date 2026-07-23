#!/usr/bin/env bash
#
# Regression coverage for scripts/ci-detect-changed-paths.sh.
#
# Guards the load-bearing money-path CI gate against silent regressions:
# rename hiding, NUL/quoted-path bypass, external shared-fixture coverage,
# docs-only skipping, and fail-open behaviour. Runs on ubuntu in the `changes`
# job itself, so a broken detector fails that job and blocks merge.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DETECT="$SCRIPT_DIR/ci-detect-changed-paths.sh"
fail=0

# Run the detector against a base..head pair inside a throwaway repo built by
# the caller-supplied setup function, and assert on its swift=/code= output.
assert_detect() {
  local desc="$1" setup="$2" want_swift="$3" want_code="$4"
  local repo base head out got_swift got_code
  repo="$(mktemp -d)"
  (
    cd "$repo"
    git init -q
    git config user.email t@example.com
    git config user.name t
    git config commit.gpgsign false
  )
  base="$(cd "$repo" && "$setup")"
  head="$(cd "$repo" && git rev-parse HEAD)"
  out="$(cd "$repo" && GITHUB_OUTPUT="" GITHUB_STEP_SUMMARY="" bash "$DETECT" "$base" "$head")"
  got_swift="$(printf '%s\n' "$out" | sed -n 's/^swift=//p')"
  got_code="$(printf '%s\n' "$out" | sed -n 's/^code=//p')"
  if [ "$got_swift" = "$want_swift" ] && [ "$got_code" = "$want_code" ]; then
    printf 'PASS | %-42s swift=%s code=%s\n' "$desc" "$got_swift" "$got_code"
  else
    printf 'FAIL | %-42s got swift=%s code=%s want swift=%s code=%s\n' \
      "$desc" "$got_swift" "$got_code" "$want_swift" "$want_code"
    fail=1
  fi
  rm -rf "$repo"
}

commit_all() { git add -A && git commit -q -m "$1"; }

# --- scenarios -------------------------------------------------------------

setup_go_only() {
  mkdir -p phase4-coordinator phase5-gateway
  echo x >phase4-coordinator/a.go; echo y >phase5-gateway/b.go
  commit_all base >/dev/null; git rev-parse HEAD
  echo x2 >phase4-coordinator/a.go; commit_all change >/dev/null
}
assert_detect "Go-only PR" setup_go_only false true

setup_swift_only() {
  mkdir -p phase3-binary/Sources; echo x >phase3-binary/Sources/a.swift
  commit_all base >/dev/null; git rev-parse HEAD
  echo y >phase3-binary/Sources/a.swift; commit_all change >/dev/null
}
assert_detect "Swift-only PR" setup_swift_only true true

setup_docs_only() {
  mkdir -p docs; echo a >README.md; echo b >docs/guide.md
  commit_all base >/dev/null; git rev-parse HEAD
  echo a2 >README.md; echo b2 >docs/guide.md; commit_all change >/dev/null
}
assert_detect "docs-only PR (skip both)" setup_docs_only false false

# HIGH: rename detection must not hide the Swift pre-image behind docs/.
setup_rename_swift_to_docs() {
  mkdir -p phase3-binary docs; echo x >phase3-binary/a.swift
  commit_all base >/dev/null; git rev-parse HEAD
  git mv phase3-binary/a.swift docs/a.swift; commit_all rename >/dev/null
}
assert_detect "rename phase3->docs (must run swift)" setup_rename_swift_to_docs true true

# HIGH: NUL/quoted Unicode path under phase3-binary must still match.
setup_unicode_swift() {
  mkdir -p phase3-binary; printf 'x\n' >"phase3-binary/café.swift"
  commit_all base >/dev/null; git rev-parse HEAD
  printf 'y\n' >"phase3-binary/café.swift"; commit_all change >/dev/null
}
assert_detect "unicode phase3 swift (must run swift)" setup_unicode_swift true true

# HIGH: shared cross-language fixtures the Swift suites read live outside
# phase3-binary; changing them must run swift-tests.
setup_external_fixture_p7() {
  mkdir -p phase7-verify/testdata; echo '{}' >phase7-verify/testdata/jcs_parity.json
  commit_all base >/dev/null; git rev-parse HEAD
  echo '{"v":1}' >phase7-verify/testdata/jcs_parity.json; commit_all change >/dev/null
}
assert_detect "phase7-verify/testdata fixture" setup_external_fixture_p7 true true

setup_external_fixture_p4() {
  mkdir -p phase4-coordinator/test/jcs_fixtures/spec029
  echo '[]' >phase4-coordinator/test/jcs_fixtures/spec029/losslessness_probe_v1.json
  commit_all base >/dev/null; git rev-parse HEAD
  echo '[1]' >phase4-coordinator/test/jcs_fixtures/spec029/losslessness_probe_v1.json
  commit_all change >/dev/null
}
assert_detect "phase4 jcs_fixtures fixture" setup_external_fixture_p4 true true

setup_external_fixture_testdata() {
  mkdir -p testdata/spec015; echo '{}' >testdata/spec015/v04_settlement_receipts.json
  commit_all base >/dev/null; git rev-parse HEAD
  echo '{"v":1}' >testdata/spec015/v04_settlement_receipts.json; commit_all change >/dev/null
}
assert_detect "root testdata fixture" setup_external_fixture_testdata true true

# A normal coordinator .go change must NOT drag in swift (savings preserved).
setup_coordinator_go() {
  mkdir -p phase4-coordinator/internal; echo x >phase4-coordinator/internal/ws.go
  commit_all base >/dev/null; git rev-parse HEAD
  echo y >phase4-coordinator/internal/ws.go; commit_all change >/dev/null
}
assert_detect "coordinator .go (skip swift)" setup_coordinator_go false true

# Nested markdown (possible fixture) is significant -> runs acceptance.
setup_nested_md() {
  mkdir -p test/integration/spec015; echo a >test/integration/spec015/fixture.md
  commit_all base >/dev/null; git rev-parse HEAD
  echo b >test/integration/spec015/fixture.md; commit_all change >/dev/null
}
assert_detect "nested markdown fixture" setup_nested_md false true

# HIGH (r2): macOS is case-insensitive; a mixed-case phase3 path added on
# Linux folds into the real Swift tree on checkout and must run swift-tests.
setup_mixedcase_swift() {
  mkdir -p Phase3-binary/app; echo x >Phase3-binary/app/Bad.swift
  commit_all base >/dev/null; git rev-parse HEAD
  echo y >Phase3-binary/app/Bad.swift; commit_all change >/dev/null
}
assert_detect "mixed-case Phase3-binary (run swift)" setup_mixedcase_swift true true

# MEDIUM (r2): root .gitattributes can change how the Swift job's scripts are
# checked out (eol/filters); it must run swift-tests.
setup_gitattributes() {
  echo '* text=auto' >.gitattributes
  commit_all base >/dev/null; git rev-parse HEAD
  printf 'phase3-binary/dist/test/*.sh text eol=crlf\n' >>.gitattributes
  commit_all change >/dev/null
}
assert_detect "root .gitattributes (run swift)" setup_gitattributes true true

# FAIL OPEN: an unresolvable base leaves both true.
setup_fail_open() {
  mkdir -p phase4-coordinator; echo x >phase4-coordinator/a.go
  commit_all base >/dev/null; git rev-parse HEAD
  echo y >phase4-coordinator/a.go; commit_all change >/dev/null
}
# Deliberately pass a bogus base SHA to force the fail-open branch.
_repo="$(mktemp -d)"
(
  cd "$_repo"; git init -q; git config user.email t@e; git config user.name t
  git config commit.gpgsign false
  mkdir -p phase4-coordinator; echo x >phase4-coordinator/a.go
  git add -A && git commit -qm base
)
_head="$(cd "$_repo" && git rev-parse HEAD)"
_out="$(cd "$_repo" && GITHUB_OUTPUT="" GITHUB_STEP_SUMMARY="" bash "$DETECT" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$_head")"
if [ "$(printf '%s' "$_out" | sed -n 's/^swift=//p')" = "true" ] && \
   [ "$(printf '%s' "$_out" | sed -n 's/^code=//p')" = "true" ]; then
  echo "PASS | fail-open on unknown base                swift=true code=true"
else
  echo "FAIL | fail-open on unknown base -> $_out"; fail=1
fi
rm -rf "$_repo"

if [ "$fail" -ne 0 ]; then
  echo "ci-detect-changed-paths regression: FAILURES present" >&2
  exit 1
fi
echo "ci-detect-changed-paths regression: all scenarios passed"
