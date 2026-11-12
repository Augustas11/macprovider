#!/usr/bin/env bash
#
# CI path-gate detector.
#
# Emits five booleans that gate jobs and dist-tooling shards in
# .github/workflows/ci.yml:
#   swift   -> phase3-binary (swift test) + locked SwiftPM resolve jobs
#   code    -> spec-015-acceptance and the Swift settlement steps
#   dist    -> dist-tooling python1/python2/release/deploy shards
#   catalog -> dist-tooling catalog shard
#   ops     -> dist-tooling ops shard (scripts/ops test suites)
#
# Usage: ci-detect-changed-paths.sh <base_sha> <head_sha>
# Prints "name=<bool>" lines to stdout, appends the same to $GITHUB_OUTPUT
# when set, and writes a human summary to $GITHUB_STEP_SUMMARY when set.
#
# SAFETY — this gate must never skip a job a real change depends on:
#   * FAIL OPEN: any inability to resolve the diff (missing/zero/unknown SHA,
#     git error) leaves EVERY boolean true so every gated job still runs.
#   * RENAME SAFE: `--no-renames` surfaces a move as delete+add so the
#     pre-image path (e.g. a Swift file renamed out of phase3-binary) is never
#     hidden behind an exempt destination.
#   * NUL SAFE: `-z` disables git's C-quoting of unusual/Unicode paths, which
#     would otherwise defeat the phase3-binary/* glob; parsed via read -d ''.
#   * The Swift suites load shared cross-language fixtures that live OUTSIDE
#     phase3-binary (kept in sync with the parity tests below); those specific
#     fixture directories are part of the swift gate.
#   * dist, catalog and ops are deny-lists: a path skips a shard only when it
#     is in an area that shard is known not to read. Any other path, including
#     a new top-level directory, runs it. test-ci-detect-changed-paths.sh scans
#     the shard sources for repo paths they read and fails if one is exempt.
#   * A deleted path (a rename is a delete plus an add) never skips a dist,
#     catalog or ops shard: a test may require the file to exist.
set -euo pipefail

base="${1:-}"
head="${2:-}"

swift=true
code=true
dist=true
catalog=true
ops=true
zero="0000000000000000000000000000000000000000"
matched_swift=0
matched_code=0
matched_dist=0
matched_catalog=0
matched_ops=0
total=0

# The macOS runners use a case-INSENSITIVE filesystem, so a path added on
# case-sensitive Linux as `Phase3-binary/...swift` folds into the real
# `phase3-binary` tree on checkout and is built by swift-tests. Match paths
# ASCII-case-insensitively so such a change still trips the Swift gate. This is
# fail-safe for the docs gate too: a case variant of a doc path stays a skip.
shopt -s nocasematch

# docs/ paths that a dist, catalog or ops test (or a script one runs) reads.
# A change under these runs the Linux dist shards even though `code` treats
# docs/ as documentation. The detector self-test scans the repo for docs/
# references and fails when one is missing here.
docs_read() {
  case "$1" in
    docs/agent-onboarding/*|docs/decision-log.md|docs/design/*|docs/evidence/*|\
    docs/legacy/*|docs/notes/*|docs/provider-economics.md|docs/releases/*|\
    docs/reports/*|docs/research/*|docs/runbooks/*|\
    docs/spec-governance-foundation.md|docs/spec-history/*|docs/testing/*|\
    docs/using-macprovider-with-openai-sdk.md) return 0 ;;
  esac
  return 1
}

# Root Markdown files that a non-doc file names (tests use AGENTS.md as the
# repo-root marker; the onboarding check requires README.md). The self-test
# derives this set by scanning the repo and fails when one is missing here.
root_md_read() {
  case "$1" in
    AGENTS.md|CLAUDE.md|README.md|SECURITY.md) return 0 ;;
  esac
  return 1
}

# True when the path cannot change a Linux dist shard: root Markdown and the
# docs/ pages no test reads.
dist_exempt() {
  case "$1" in
    docs/*) docs_read "$1" && return 1; return 0 ;;
    */*) return 1 ;;
    *.md) root_md_read "$1" && return 1; return 0 ;;
  esac
  return 1
}

# Service-tree paths that the catalog or ops shard (or a script one runs)
# reads. Everything else under the Go services, phase7-verify, the Go
# integration harness and frontdoor is exempt from those two shards. The
# detector self-test scans both shards' sources for paths in those trees and
# fails when one read is exempt.
service_read() {
  case "$1" in
    phase4-coordinator/dist/*|phase4-coordinator/go.mod|phase4-coordinator/go.sum|\
    phase4-coordinator/*.example|phase4-coordinator/internal/autotune/*|\
    phase4-coordinator/internal/billing/formula.go|\
    phase4-coordinator/internal/buyer/autotune_feeds.go|\
    phase4-coordinator/internal/buyer/native_mtp_feeds.go|\
    phase4-coordinator/internal/computeintegrity/testdata/*|\
    phase4-coordinator/internal/config/*|\
    phase5-gateway/dist/*|phase5-gateway/go.mod|phase5-gateway/go.sum|\
    phase5-gateway/*.example|phase5-gateway/internal/config/*|\
    phase7-verify/go.mod|phase7-verify/go.sum) return 0 ;;
  esac
  return 1
}

# The catalog shard (decode-path digest, catalog/content release, static feed
# sync, pricing preflight, autotune gate matrix) reads the catalog, Swift
# sources, scripts, ops keys, specs and the service paths above. It does not
# read the Malibu app or the Swift tests.
catalog_exempt() {
  service_read "$1" && return 1
  case "$1" in
    phase4-coordinator/*|phase5-gateway/*|phase7-verify/*|test/integration/*|\
    frontdoor/*|phase3-binary/app/*|phase3-binary/Tests/*) return 0 ;;
  esac
  dist_exempt "$1"
}

# The ops shard (scripts/ops/test-*) clones this repository and runs the ops
# entry points against it, so it reads scripts/, ops/, all of phase3-binary/
# (app included), specs, runbooks, the release train and the service paths
# above.
ops_exempt() {
  service_read "$1" && return 1
  case "$1" in
    phase4-coordinator/*|phase5-gateway/*|phase7-verify/*|test/integration/*|\
    frontdoor/*) return 0 ;;
  esac
  dist_exempt "$1"
}

classify() {
  # Reads NUL-delimited `git diff --name-status -z` records (status, path)
  # on stdin; sets the gates and counters.
  local f status deleted
  swift=false
  code=false
  dist=false
  catalog=false
  ops=false
  while IFS= read -r -d '' status && IFS= read -r -d '' f; do
    [ -n "$f" ] || continue
    case "$status" in D*) deleted=1 ;; *) deleted=0 ;; esac
    total=$((total + 1))
    case "$f" in
      # phase3-binary sources; the build/xcodegen/sparkle scripts the Swift
      # job invokes; the Makefile; this workflow; root .gitattributes (eol/
      # filter rules can change how the Swift job's checked-out scripts run);
      # AND the shared cross-language fixtures the Swift parity/losslessness/
      # settlement suites read from other modules. Keep this list in sync with
      # the Swift tests under phase3-binary/Tests and phase3-binary/app/Tests.
      # test/e2e/byom/* is the hermetic BYOM CLI onboarding harness the Swift
      # job runs via `make test-byom-e2e`; a harness-only edit must still gate.
      #
      # scripts/ is matched file by file (#1920) so a script-only PR does not
      # run the macOS Swift job. Listed: what the Swift job's steps run (the
      # test-shard runner, Sparkle checks, XcodeGen install, SwiftPM lock, the
      # BYOM discovery-journey gate and the Python it imports), the fixtures
      # Swift tests read, any Swift source, and this detector. test-ci-detect-changed-paths.sh fails if a
      # Swift test reads a repo path this list does not cover.
      phase3-binary/*|Makefile|.gitattributes|.github/workflows/ci.yml|\
      test/e2e/byom/*|test/fixtures/*|\
      phase7-verify/testdata/*|phase4-coordinator/test/jcs_fixtures/*|testdata/*|\
      docs/research/spec048-r015/policy-template.json|\
      docs/research/spec048-r015/glm53-flash-r015-v2/policy.json|\
      docs/evidence/glm53-flash-t4-2026-10-17/README.md|\
      scripts/*.swift|scripts/fixtures/*|scripts/tests/fixtures/*|\
      scripts/lab/1690-m6/testdata/*|scripts/lab/dsv4/dsv4-dspark-requests.json|\
      scripts/lab/privacy-class-beta/extract-primary-evidence.py|\
      scripts/ci-detect-changed-paths.sh|scripts/ci-swift-test-shard.py|\
      scripts/test-malibu-sparkle-generator-integration.sh|\
      scripts/test-malibu-sparkle-validator-integration.sh|\
      scripts/generate-malibu-appcast.sh|scripts/install-pinned-xcodegen.sh|\
      scripts/verify-swift-package-lock.sh|scripts/test-byom-discovery-journey.sh|\
      scripts/build-byom-discovery-journey-result.py|scripts/byom_journey_evidence.py|\
      scripts/capture-byom-journey-evidence.py|scripts/preflight-signed-journey-promotion.py|\
      scripts/sign-journey-result.py|scripts/validate-signed-journey-result.py|\
      scripts/promote-signed-journey-result.py|scripts/check_spec_governance.py|\
      scripts/build-local-consumer-endpoint-journey-result.py|\
      scripts/native_mtp_journey_evidence.py|scripts/pool_promotion_transition.py|\
      scripts/privacy_class_beta_journey_evidence.py|\
      scripts/check_mlx_core_streams.py|scripts/read_swiftpm_pins.py)
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
    if [ "$deleted" = 1 ] || ! dist_exempt "$f"; then dist=true; matched_dist=$((matched_dist + 1)); fi
    if [ "$deleted" = 1 ] || ! catalog_exempt "$f"; then catalog=true; matched_catalog=$((matched_catalog + 1)); fi
    if [ "$deleted" = 1 ] || ! ops_exempt "$f"; then ops=true; matched_ops=$((matched_ops + 1)); fi
  done
}

if [ -n "$base" ] && [ -n "$head" ] && [ "$base" != "$zero" ] \
   && git cat-file -e "${base}^{commit}" 2>/dev/null \
   && git cat-file -e "${head}^{commit}" 2>/dev/null; then
  tmp="$(mktemp)"
  # NUL-delimited output cannot be held in a shell variable; stream via file.
  if git diff --no-renames -z --name-status "$base" "$head" >"$tmp" 2>/dev/null; then
    classify <"$tmp"
    resolved=yes
  else
    resolved=no
  fi
  rm -f "$tmp"
else
  resolved=no
fi

outputs="$(printf 'swift=%s\ncode=%s\ndist=%s\ncatalog=%s\nops=%s' \
  "$swift" "$code" "$dist" "$catalog" "$ops")"
printf '%s\n' "$outputs"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf '%s\n' "$outputs" >>"$GITHUB_OUTPUT"
fi
verdict() { [ "$1" = true ] && echo run || echo skip; }
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### CI path-gate"
    echo ""
    echo "- diff resolved: ${resolved}"
    echo "- changed files: ${total}"
    echo "- swift-tests / locked SwiftPM resolve: **$(verdict "$swift")** (matched ${matched_swift})"
    echo "- spec-015-acceptance / Swift settlement: **$(verdict "$code")** (matched ${matched_code})"
    echo "- dist-tooling python, release, deploy: **$(verdict "$dist")** (matched ${matched_dist})"
    echo "- dist-tooling catalog: **$(verdict "$catalog")** (matched ${matched_catalog})"
    echo "- dist-tooling ops: **$(verdict "$ops")** (matched ${matched_ops})"
  } >>"$GITHUB_STEP_SUMMARY"
fi
