#!/usr/bin/env bash
#
# Regression coverage for scripts/ci-detect-changed-paths.sh.
#
# Guards the load-bearing money-path CI gate against silent regressions:
# rename hiding, NUL/quoted-path bypass, external shared-fixture coverage,
# docs-only skipping, the dist/catalog/ops shard deny-lists, and fail-open
# behaviour. Runs on ubuntu in the `changes`
# job itself, so a broken detector fails that job and blocks merge.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DETECT="$SCRIPT_DIR/ci-detect-changed-paths.sh"
fail=0

cleanup_repo() {
  local repo="$1" trash
  [ -n "$repo" ] || return 0
  [ -e "$repo" ] || return 0
  trash="${repo}.delete.$$"
  chmod -R u+w "$repo" 2>/dev/null || true
  if mv "$repo" "$trash" 2>/dev/null; then
    repo="$trash"
  fi
  for _attempt in 1 2 3; do
    if rm -rf "$repo" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  printf 'WARN | could not remove temporary repo %s\n' "$repo" >&2
}

# Run the detector against a base..head pair inside a throwaway repo built by
# the caller-supplied setup function, and assert on its swift=/code= output.
# An optional fifth argument lists further expected lines, for example
# "dist=false catalog=false ops=false".
assert_detect() {
  local desc="$1" setup="$2" want_swift="$3" want_code="$4" want_more="${5:-}"
  local repo base head out got_swift got_code kv extra_ok=1
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
  for kv in $want_more; do
    printf '%s\n' "$out" | grep -qxF "$kv" || extra_ok=0
  done
  if [ "$got_swift" = "$want_swift" ] && [ "$got_code" = "$want_code" ] && [ "$extra_ok" = 1 ]; then
    printf 'PASS | %-42s swift=%s code=%s %s\n' "$desc" "$got_swift" "$got_code" "$want_more"
  else
    printf 'FAIL | %-42s got %s want swift=%s code=%s %s\n' \
      "$desc" "$(printf '%s' "$out" | tr '\n' ' ')" "$want_swift" "$want_code" "$want_more"
    fail=1
  fi
  cleanup_repo "$repo"
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
  mkdir -p docs; echo a >CHANGES.md; echo b >docs/guide.md
  commit_all base >/dev/null; git rev-parse HEAD
  echo a2 >CHANGES.md; echo b2 >docs/guide.md; commit_all change >/dev/null
}
assert_detect "docs-only PR (skip both)" setup_docs_only false false \
  "dist=false catalog=false ops=false"

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

# The hermetic BYOM CLI onboarding harness is run by the Swift job via
# `make test-byom-e2e`; a harness-only edit must still gate the Swift job.
setup_byom_e2e_harness() {
  mkdir -p test/e2e/byom; echo x >test/e2e/byom/run-cli-onboarding-e2e.py
  commit_all base >/dev/null; git rev-parse HEAD
  echo y >test/e2e/byom/run-cli-onboarding-e2e.py; commit_all change >/dev/null
}
assert_detect "byom e2e harness (run swift)" setup_byom_e2e_harness true true

# The Swift test-shard runner decides which tests each shard runs; editing it
# must run the Swift jobs that execute it.
setup_swift_shard_runner() {
  mkdir -p scripts; echo x >scripts/ci-swift-test-shard.py
  commit_all base >/dev/null; git rev-parse HEAD
  echo y >scripts/ci-swift-test-shard.py; commit_all change >/dev/null
}
assert_detect "swift test-shard runner (run swift)" setup_swift_shard_runner true true

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

# #1920: scripts/ is matched file by file. A script the Swift job never reads
# skips swift; the ones it runs or imports still gate.
setup_script_only() {
  mkdir -p scripts; echo x >scripts/catalog-release.py
  commit_all base >/dev/null; git rev-parse HEAD
  echo y >scripts/catalog-release.py; commit_all change >/dev/null
}
assert_detect "script-only PR (skip swift)" setup_script_only false true

# Every repo path outside phase3-binary that a Swift test reads, plus the
# scripts the Swift job runs, must trip the swift gate.
swift_read_paths() {
  local root
  root="$(cd "$SCRIPT_DIR/.." && pwd)"
  {
    grep -rhoE 'appendingPathComponent\("(scripts|docs|test|testdata|phase4-coordinator|phase5-gateway|phase7-verify|ops|specs|schemas)/[^"\\]+"' \
      "$root/phase3-binary/Tests" "$root/phase3-binary/app/Tests" 2>/dev/null |
      sed -E 's/^appendingPathComponent\("//; s/"$//'
    grep -rhoE '"\.\./\.\./\.\./[a-z][^"\\]*' "$root/phase3-binary/Tests" 2>/dev/null |
      sed -E 's#^"\.\./\.\./\.\./##'
    echo scripts/test-byom-discovery-journey.sh
    echo scripts/check_spec_governance.py
    echo docs/research/spec048-r015/policy-template.json
  } | sed -E 's#/$#/fixture.json#' | sort -u
}
swift_read_paths >"${TMPDIR:-/tmp}/swift-read-paths.$$"
while IFS= read -r read_path; do
  [ -n "$read_path" ] || continue
  setup_swift_read_path() {
    mkdir -p "$(dirname "$read_path")"; echo x >"$read_path"
    commit_all base >/dev/null; git rev-parse HEAD
    echo y >"$read_path"; commit_all change >/dev/null
  }
  # docs/ paths legitimately skip spec-015-acceptance (code=false).
  case "$read_path" in docs/*) want_code=false ;; *) want_code=true ;; esac
  assert_detect "Swift-read path $read_path" setup_swift_read_path true "$want_code"
done <"${TMPDIR:-/tmp}/swift-read-paths.$$"
rm -f "${TMPDIR:-/tmp}/swift-read-paths.$$"

# --- dist / catalog / ops shard gates ---------------------------------------

# One changed path, asserted against every gate named in $3.
assert_one_path() {
  local desc="$1" path="$2" want_swift="$3" want_code="$4" want_more="$5"
  setup_one_path() {
    mkdir -p "$(dirname "$path")"; echo x >"$path"
    commit_all base >/dev/null; git rev-parse HEAD
    echo y >"$path"; commit_all change >/dev/null
  }
  assert_detect "$desc" setup_one_path "$want_swift" "$want_code" "$want_more"
}

# docs/ pages no test reads skip every Linux dist shard; the release train and
# runbooks are read by the ops and release suites, so they run them.
assert_one_path "unread docs page (skip dist shards)" docs/operations/x.md false false \
  "dist=false catalog=false ops=false"
assert_one_path "unread root markdown (skip dist shards)" NOTES-UNREAD.md false false \
  "dist=false catalog=false ops=false"
assert_one_path "root README modified (run dist shards)" README.md false false \
  "dist=true catalog=true ops=true"

# A deletion or rename never skips a dist shard: tests may need the file.
setup_readme_deleted() {
  echo a >README.md; mkdir -p docs; echo b >docs/unread.md
  commit_all base >/dev/null; git rev-parse HEAD
  git rm -q README.md docs/unread.md; commit_all delete >/dev/null
}
assert_detect "README.md deleted (run dist shards)" setup_readme_deleted false false \
  "dist=true catalog=true ops=true"
setup_agents_renamed() {
  echo a >AGENTS.md
  commit_all base >/dev/null; git rev-parse HEAD
  git mv AGENTS.md AGENT-GUIDE.md; commit_all rename >/dev/null
}
assert_detect "AGENTS.md renamed (run dist shards)" setup_agents_renamed false false \
  "dist=true catalog=true ops=true"
setup_unread_docs_deleted() {
  mkdir -p docs/operations; echo a >docs/operations/x.md
  commit_all base >/dev/null; git rev-parse HEAD
  git rm -q docs/operations/x.md; commit_all delete >/dev/null
}
assert_detect "unread docs page deleted (run dist)" setup_unread_docs_deleted false false \
  "dist=true catalog=true ops=true"
assert_one_path "release train (run dist shards)" docs/releases/cli-release-train.md false false \
  "dist=true catalog=true ops=true"
assert_one_path "runbook (run dist shards)" docs/runbooks/x.md false false \
  "dist=true catalog=true ops=true"
# Service Go code outside the read list skips catalog and ops but not dist.
assert_one_path "coordinator Go (skip catalog, ops)" phase4-coordinator/internal/billing/ledger.go false true \
  "dist=true catalog=false ops=false"
assert_one_path "gateway Go (skip catalog, ops)" phase5-gateway/internal/router/router.go false true \
  "dist=true catalog=false ops=false"
assert_one_path "phase7-verify Go (skip catalog, ops)" phase7-verify/internal/jcs/jcs.go false true \
  "dist=true catalog=false ops=false"
assert_one_path "integration harness (skip catalog, ops)" test/integration/x_test.go false true \
  "dist=true catalog=false ops=false"
assert_one_path "frontdoor (skip catalog, ops)" frontdoor/provider-portal/index.html false true \
  "dist=true catalog=false ops=false"
# Deploy trees, ops, scripts, specs and new top-level paths run everything.
assert_one_path "coordinator deploy script" phase4-coordinator/dist/deploy-pearl-vps.sh false true \
  "dist=true catalog=true ops=true"
assert_one_path "coordinator.yaml" phase4-coordinator/dist/coordinator.yaml false true \
  "dist=true catalog=true ops=true"
assert_one_path "gateway deploy script" phase5-gateway/dist/deploy-pearl-vps.sh false true \
  "dist=true catalog=true ops=true"
assert_one_path "generated autotune Go" phase4-coordinator/internal/autotune/rejected_release_ids.generated.go false true \
  "dist=true catalog=true ops=true"
assert_one_path "runbook command lib" scripts/ops/lib/runbook-commands.sh false true \
  "dist=true catalog=true ops=true"
assert_one_path "ops tree" ops/pearl-updater/pearl-updater.py false true \
  "dist=true catalog=true ops=true"
assert_one_path "catalog script" scripts/catalog-release.py false true \
  "dist=true catalog=true ops=true"
assert_one_path "catalog content" phase3-binary/catalog/autotune/release.json true true \
  "dist=true catalog=true ops=true"
assert_one_path "generated catalog Swift" phase3-binary/Sources/macprovider-cli/AutotuneCatalog.generated.swift true true \
  "dist=true catalog=true ops=true"
assert_one_path "spec text" specs/SPEC-023-autotune.md false true \
  "dist=true catalog=true ops=true"
assert_one_path "unknown top-level dir" newtree/x.txt false true \
  "dist=true catalog=true ops=true"
# The Malibu app and Swift tests are not read by the catalog shard; the ops
# shard reads the app (Malibu system prompt) so it runs for both.
assert_one_path "Malibu app (skip catalog)" phase3-binary/app/Sources/Malibu/App.swift true true \
  "dist=true catalog=false ops=true"
assert_one_path "Swift test (skip catalog)" phase3-binary/Tests/macprovider-cliTests/XTests.swift true true \
  "dist=true catalog=false ops=true"

# Every docs/ page a non-doc file refers to must run the dist shards. Joined
# path forms ("docs" / "runbooks") count as references too.
docs_read_paths() {
  local root
  root="$(cd "$SCRIPT_DIR/.." && pwd)"
  git -C "$root" grep -hoIE "docs/[A-Za-z0-9_.-]+|[\"']docs[\"'] *[,/)] *[\"'][A-Za-z0-9_.-]+" -- \
      ':!docs' ':!*.md' ':!scripts/ci-detect-changed-paths.sh' \
      ':!scripts/tests/test-ci-detect-changed-paths.sh' |
    sed -E "s#[\"']docs[\"'] *[,/)] *[\"']#docs/#" | sort -u |
    while IFS= read -r p; do
      if [ -d "$root/$p" ]; then echo "$p/fixture.md"; elif [ -f "$root/$p" ]; then echo "$p"; fi
    done
}

# Files a shard runs: the seeds plus every script they name (one hop).
# hotfix-push.sh and its test match path patterns against fixture diffs and
# read no service file, so their pattern tables are not reads.
shard_sources() {
  local shard="$1" root seeds
  root="$(cd "$SCRIPT_DIR/.." && pwd)"
  case "$shard" in
    ops) seeds="$(cd "$root" && find scripts/ops -type f ! -name test-hotfix-push.sh \
           ! -name hotfix-push.sh ! -path '*/__pycache__/*')" ;;
    catalog) seeds="$(sed -n '/^test-dist-catalog:/,/^$/p' "$root/Makefile" |
           grep -oE '[A-Za-z0-9_./-]+\.(sh|py)' | sort -u)" ;;
  esac
  {
    printf '%s\n' $seeds
    (cd "$root" && grep -hoE 'scripts/[A-Za-z0-9_./-]+\.(sh|py|go)' $seeds 2>/dev/null)
  } | sort -u | while IFS= read -r p; do [ -f "$root/$p" ] && echo "$p"; done
}

# Paths in the exempt service trees (and, for catalog, the app and Swift tests)
# that a shard's non-comment source lines name.
shard_read_paths() {
  local root
  root="$(cd "$SCRIPT_DIR/.." && pwd)"
  shard_sources "$1" | while IFS= read -r f; do grep -vE '^[[:space:]]*#' "$root/$f" || true; done |
    grep -oE '(phase4-coordinator|phase5-gateway|phase7-verify|test/integration|frontdoor|phase3-binary/app|phase3-binary/Tests)/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*' |
    sort -u | while IFS= read -r p; do
      if [ -d "$root/$p" ]; then echo "$p/fixture.json"; elif [ -f "$root/$p" ]; then echo "$p"; fi
    done
}

# Every root Markdown file a non-doc file names (not as the tail of a longer
# path such as phase7-verify/README.md) must run the dist shards.
root_md_read_paths() {
  local root f
  root="$(cd "$SCRIPT_DIR/.." && pwd)"
  for f in "$root"/*.md; do
    f="$(basename "$f")"
    if git -C "$root" grep -qIE "(^|[^A-Za-z0-9_./-])${f%.md}[.]md" -- \
        ':!docs' ':!*.md' ':!scripts/ci-detect-changed-paths.sh' \
        ':!scripts/tests/test-ci-detect-changed-paths.sh'; then
      echo "$f"
    fi
  done
}

scan_list="${TMPDIR:-/tmp}/dist-read-paths.$$"
root_md_read_paths >"$scan_list"
grep -qx AGENTS.md "$scan_list" || { echo "FAIL | root markdown scan did not find AGENTS.md"; fail=1; }
while IFS= read -r read_path; do
  [ -n "$read_path" ] || continue
  assert_one_path "root markdown read $read_path" "$read_path" false false \
    "dist=true catalog=true ops=true"
done <"$scan_list"
docs_read_paths >"$scan_list"
[ -s "$scan_list" ] || { echo "FAIL | docs reference scan found nothing"; fail=1; }
while IFS= read -r read_path; do
  [ -n "$read_path" ] || continue
  # The scan yields docs/<entry> only, never a Swift-read fixture below it.
  assert_one_path "docs read $read_path" "$read_path" false false \
    "dist=true catalog=true ops=true"
done <"$scan_list"
for shard in ops catalog; do
  shard_read_paths "$shard" >"$scan_list"
  [ -s "$scan_list" ] || { echo "FAIL | $shard read scan found nothing"; fail=1; }
  while IFS= read -r read_path; do
    [ -n "$read_path" ] || continue
    case "$read_path" in
      phase7-verify/testdata/*|phase4-coordinator/test/jcs_fixtures/*|phase3-binary/*) want_swift=true ;;
      *) want_swift=false ;;
    esac
    assert_one_path "$shard read $read_path" "$read_path" "$want_swift" true "$shard=true"
  done <"$scan_list"
done
rm -f "$scan_list"

# FAIL OPEN: an unresolvable base leaves every gate true.
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
_rc=0
_out="$(cd "$_repo" && GITHUB_OUTPUT="" GITHUB_STEP_SUMMARY="" bash "$DETECT" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$_head")" || _rc=$?
if [ "$_rc" -eq 0 ] && \
   [ "$(printf '%s' "$_out" | sed -n 's/^swift=//p')" = "true" ] && \
   [ "$(printf '%s' "$_out" | sed -n 's/^code=//p')" = "true" ] && \
   [ "$(printf '%s' "$_out" | sed -n 's/^dist=//p')" = "true" ] && \
   [ "$(printf '%s' "$_out" | sed -n 's/^catalog=//p')" = "true" ] && \
   [ "$(printf '%s' "$_out" | sed -n 's/^ops=//p')" = "true" ]; then
  echo "PASS | fail-open on unknown base                all gates true"
else
  echo "FAIL | fail-open on unknown base rc=$_rc -> $_out"; fail=1
fi
cleanup_repo "$_repo"

if [ "$fail" -ne 0 ]; then
  echo "ci-detect-changed-paths regression: FAILURES present" >&2
  exit 1
fi
echo "ci-detect-changed-paths regression: all scenarios passed"
