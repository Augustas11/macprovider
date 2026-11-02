#!/usr/bin/env bash
# Push small tooling/test fixes straight to main, but only after the fast test
# suites that cover the touched paths pass.
#
# Usage:
#   scripts/ops/hotfix-push.sh [--dry-run] [--cancel-ci]
#
#   --dry-run    print the plan (paths, refusals, suites) and stop
#   --cancel-ci  after the push, cancel the main CI runs for the pushed SHA
#                (one CI run at a time); gh must be logged in
#
# Why: direct pushes to main skip PR CI, and the main run is usually cancelled
# right away. 728f0f0b3 changed the committed native-MTP projection and broke
# scripts/tests/test_native_mtp_admission_sidecar.py; nobody saw it until an
# unrelated PR's CI went red. This runs the covering suites before the push.
#
# Preconditions (refused otherwise): a clean working tree (untracked files
# included), origin/main is an ancestor of HEAD, a local `main` (if any) is
# origin/main or HEAD, no merge commits in origin/main..HEAD, and no path that
# AGENTS.md "Git Workflow" says needs a PR. Docs (*.md outside specs/) never
# need a PR. The PR-only list (PR_ONLY below): shipped Swift/app code and the
# SwiftPM pins, the installer bytes, coordinator/gateway/verify Go and
# coordinator.yaml, .github/workflows, and the normative SPEC files
# (specs/SPEC-*.md, AUTHORITY.json, CONFORMANCE.json). Catalog and dist/static
# data, scripts and tests may go direct: their suites below gate them.
# AutotuneCatalog.generated.swift is generated from the catalog JSON and
# `catalog-release.py verify` proves it, so it rides with a catalog change.
#
# Suites (SUITES below; each touched path adds every suite whose pattern it
# matches; a path no rule names falls back to the full scripts/tests suite):
#   scripts/**/*.py, scripts/tests/**, any data file a scripts/tests module
#     names     -> the scripts/tests modules that name the file (module name or
#                  file name); none found, or a test helper touched -> the full
#                  `unittest discover -s scripts/tests` suite
#   phase3-binary/catalog/**, phase3-binary/dist/static/**
#               -> scripts/test-catalog-release.sh + catalog-release.py verify,
#                  and the scripts/tests modules that name the file or its
#                  directory (they read the committed projections); none -> full
#   scripts/ops/** -> every scripts/ops/test-* that names the file (all of
#                  them when none does)
#   specs/**    -> check_spec_governance.py + gen_spec_index.py --check
#   decode-path inputs (decode-path-manifest.json, the files it lists,
#     decode_path_digest.py) -> decode_path_digest.py --check
#   scripts/test-*.sh -> that script; any test file or Makefile -> check-test-wiring.py
#
# Env: HOTFIX_PUSH_REMOTE (origin), MACPROVIDER_GH_REPO (Augustas11/macprovider),
# HOTFIX_PUSH_CI_WAIT_SECONDS (90; how long --cancel-ci waits for the run to appear).
set -euo pipefail

usage() { sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }

DRY_RUN=0
CANCEL_CI=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --cancel-ci) CANCEL_CI=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; echo "hotfix-push: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

REMOTE="${HOTFIX_PUSH_REMOTE:-origin}"
GH_REPO="${MACPROVIDER_GH_REPO:-Augustas11/macprovider}"
refuse() { printf 'hotfix-push: REFUSED: %s\n' "$*" >&2; exit 3; }
log() { printf 'hotfix-push: %s\n' "$*" >&2; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || refuse "not inside a git repository"
cd "$ROOT"

git fetch -q "$REMOTE" main || refuse "git fetch $REMOTE main failed"
BASE="$(git rev-parse "$REMOTE/main")"
HEAD_SHA="$(git rev-parse HEAD)"

[ -z "$(git status --porcelain --untracked-files=all)" ] ||
  refuse "the working tree is not clean; commit or stash everything that is not part of the push"
git merge-base --is-ancestor "$BASE" HEAD ||
  refuse "$REMOTE/main ($BASE) is not an ancestor of HEAD; rebase onto $REMOTE/main first"
if LOCAL_MAIN="$(git rev-parse -q --verify refs/heads/main)"; then
  [ "$LOCAL_MAIN" = "$BASE" ] || [ "$LOCAL_MAIN" = "$HEAD_SHA" ] ||
    refuse "local main ($LOCAL_MAIN) is neither $REMOTE/main nor HEAD; sync it first"
fi
[ "$BASE" != "$HEAD_SHA" ] || refuse "nothing to push: HEAD is $REMOTE/main"
[ -z "$(git rev-list --merges "$BASE..HEAD")" ] || refuse "merge commits in $REMOTE/main..HEAD; push a linear history"

log "commits to push ($REMOTE/main..HEAD):"
git log --format='  %h %s' "$BASE..HEAD" >&2

# Every path any commit in the range touched (both sides of a rename), so a
# file changed and then reverted inside the push is still covered.
PATHS_FILE="$(mktemp "${TMPDIR:-/tmp}/hotfix-push-paths.XXXXXX")"
PLAN_FILE="$(mktemp "${TMPDIR:-/tmp}/hotfix-push-plan.XXXXXX")"
trap 'rm -f "$PATHS_FILE" "$PLAN_FILE"' EXIT
git log --no-renames --name-only --format= "$BASE..HEAD" | sed '/^$/d' | sort -u > "$PATHS_FILE"

# The planner prints "refuse<TAB>path<TAB>why" and "suite<TAB>command" lines.
python3 - "$ROOT" "$PATHS_FILE" > "$PLAN_FILE" <<'PY'
import fnmatch
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
paths = [p for p in pathlib.Path(sys.argv[2]).read_text().splitlines() if p]

PY_FULL = "PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -t . -p 'test_*.py'"
CATALOG = ["bash scripts/test-catalog-release.sh", "python3 scripts/catalog-release.py verify"]
SPECS = ["python3 scripts/check_spec_governance.py && python3 scripts/gen_spec_index.py --check"]
DECODE = ["python3 scripts/decode_path_digest.py --check"]
WIRING = ["python3 scripts/check-test-wiring.py"]

# AGENTS.md "Git Workflow": these need a PR. fnmatch's * also crosses "/".
PR_ONLY = [
    ("phase3-binary/*.swift", "Swift code ships in the CLI/app binary"),
    ("phase3-binary/app/*", "Malibu.app sources ship in the app"),
    ("phase3-binary/Package.swift", "SwiftPM manifest and pins change the binary"),
    ("phase3-binary/Package.resolved", "SwiftPM manifest and pins change the binary"),
    ("phase3-binary/dist/install.sh", "installer bytes"),
    ("phase4-coordinator/*.go", "coordinator Go code"),
    ("phase4-coordinator/go.mod", "coordinator Go module"),
    ("phase4-coordinator/go.sum", "coordinator Go module"),
    ("phase5-gateway/*.go", "gateway Go code"),
    ("phase5-gateway/go.mod", "gateway Go module"),
    ("phase5-gateway/go.sum", "gateway Go module"),
    ("phase7-verify/*.go", "verify Go code"),
    ("phase7-verify/go.mod", "verify Go module"),
    ("phase7-verify/go.sum", "verify Go module"),
    ("*coordinator.yaml", "coordinator.yaml"),
    ("*coordinator.yaml.example", "coordinator.yaml"),
    (".github/workflows/*", "CI workflow"),
    ("specs/SPEC-*.md", "normative SPEC"),
    ("specs/AUTHORITY.json", "spec authority manifest"),
    ("specs/CONFORMANCE.json", "spec conformance manifest"),
]
PR_EXCEPT = {"phase3-binary/Sources/macprovider-cli/AutotuneCatalog.generated.swift"}


def is_docs(path):
    return path.endswith(".md") and not path.startswith("specs/")


def decode_inputs():
    found = {"phase3-binary/decode-path-manifest.json", "scripts/decode_path_digest.py",
             "phase3-binary/Sources/macprovider-cli/DecodePathIdentity.generated.swift"}
    try:
        manifest = json.loads((root / "phase3-binary/decode-path-manifest.json").read_text())
        found.update("phase3-binary/" + f for f in manifest.get("files", []))
    except (OSError, ValueError):
        pass
    return found


TEST_DIR = root / "scripts/tests"
tests = {p: p.read_text(errors="replace") for p in sorted(TEST_DIR.glob("test_*.py"))} if TEST_DIR.is_dir() else {}
OPS_TESTS = sorted(p for p in (root / "scripts/ops").glob("test-*") if p.suffix in (".sh", ".py")) \
    if (root / "scripts/ops").is_dir() else []


def module_of(test_path):
    return ".".join(test_path.relative_to(root).with_suffix("").parts)


def referencing_tests(path, with_dir=False):
    """scripts/tests modules that name the file by file name or module stem
    (with_dir: or its directory, for tests that read a whole data directory)."""
    pure = pathlib.PurePosixPath(path)
    name, stem = pure.name, pure.stem
    needles = {name}
    if with_dir and len(pure.parent.parts) >= 2:
        needles.add("/".join(pure.parent.parts[-2:]))
    if path.endswith(".py"):
        needles.add(stem)
        needles.add(stem.replace("-", "_"))
    hits = []
    for test, text in tests.items():
        for needle in needles:
            if re.search(r"(?<![A-Za-z0-9_.-])" + re.escape(needle) + r"(?![A-Za-z0-9_-])", text):
                hits.append(module_of(test))
                break
    return hits


def ops_command(test):
    rel = test.relative_to(root).as_posix()
    return ("python3 " if rel.endswith(".py") else "bash ") + rel


refusals = []
suites = []
py_modules = set()
py_full = False


def add(*commands):
    for command in commands:
        if command not in suites:
            suites.append(command)


# Suite commands are built from repo paths and run by bash -c, so a path that
# could carry shell syntax (a "a||true/x_test.go" directory, "$(...)") never
# reaches a command: it is refused before any mapping. Every tracked path
# today fits this set; dotfiles (.gitignore, .gitkeep) do too.
SAFE_PATH = re.compile(r"[A-Za-z0-9._/+@-]+")
CANNOT_CARRY = "path has characters a suite command cannot carry"
for test in OPS_TESTS + list(tests):
    rel = test.relative_to(root).as_posix()
    if not SAFE_PATH.fullmatch(rel):
        refusals.append((rel, "test file name: " + CANNOT_CARRY + "; rename it"))

decode = decode_inputs()
for path in paths:
    go_test = re.fullmatch(r"(phase4-coordinator|phase5-gateway|phase7-verify)/(?:(.+)/)?[^/]+_test\.go", path)
    if not go_test and path not in PR_EXCEPT:
        why = next((w for pat, w in PR_ONLY if fnmatch.fnmatch(path, pat)), None)
        if why:
            refusals.append((path, why))
            continue
    if not SAFE_PATH.fullmatch(path):
        refusals.append((path, CANNOT_CARRY))
        continue
    if is_docs(path):
        continue
    # Go test files change no binary (test-only diffs go straight to main);
    # every catalog cut repins currentAutotuneReleaseID in one of them.
    if go_test:
        add(f"(cd {go_test.group(1)} && go test ./{go_test.group(2) or '.'} -count=1)")
        continue
    mapped = False
    if path.startswith("scripts/tests/"):
        mapped = True
        p = pathlib.PurePosixPath(path)
        if p.parent.as_posix() == "scripts/tests" and p.name.startswith("test_") and p.suffix == ".py":
            if (root / path).exists():
                py_modules.add(module_of(root / path))
        else:
            py_full = True  # a helper or fixture: any module may use it
    elif path.startswith("scripts/") and path.endswith(".py"):
        mapped = True
        hits = referencing_tests(path)
        if hits:
            py_modules.update(hits)
        elif not path.startswith("scripts/ops/"):  # ops files: the ops tests below
            py_full = True
    if path.startswith(("phase3-binary/catalog/", "phase3-binary/dist/static/")) or path in PR_EXCEPT:
        mapped = True
        add(*CATALOG)
        # Python tests read the committed projections (728f0f0b3).
        hits = referencing_tests(path, with_dir=True)
        if hits:
            py_modules.update(hits)
        else:
            py_full = True
    if path.startswith("scripts/ops/"):
        mapped = True
        name = pathlib.PurePosixPath(path).name
        rel_ops = path[len("scripts/ops/"):]
        own = [t for t in OPS_TESTS if t.relative_to(root).as_posix() == path]
        users = own or [t for t in OPS_TESTS if rel_ops in t.read_text(errors="replace")
                        or re.search(r"(?<![A-Za-z0-9_.-])" + re.escape(name) + r"(?![A-Za-z0-9_-])",
                                     t.read_text(errors="replace"))]
        for test in users or OPS_TESTS:
            add(ops_command(test))
    if path.startswith("specs/"):
        mapped = True
        add(*SPECS)
    if path in decode:
        mapped = True
        add(*DECODE)
    if re.fullmatch(r"scripts/test-[^/]+\.sh", path) and (root / path).exists():
        mapped = True
        add("bash " + path)
    if "/test" in path or path.startswith("test") or path == "Makefile":
        add(*WIRING)
    if not mapped:
        hits = referencing_tests(path)
        if hits:
            py_modules.update(hits)
        else:
            py_full = True

if py_full:
    add(PY_FULL)
elif py_modules:
    add("PYTHONDONTWRITEBYTECODE=1 python3 -m unittest " + " ".join(sorted(py_modules)))

for path, why in refusals:
    print("refuse\t%s\t%s" % (path, why))
for command in suites:
    print("suite\t%s" % command)
PY

log "touched paths:"
sed 's/^/  /' "$PATHS_FILE" >&2
if grep -q '^refuse' "$PLAN_FILE"; then
  log "these paths need a PR (AGENTS.md \"Git Workflow\"), not a direct push:"
  awk -F'\t' '$1 == "refuse" {printf "  %s (%s)\n", $2, $3}' "$PLAN_FILE" >&2
  refuse "open a PR for this change"
fi
log "suites to run:"
awk -F'\t' '$1 == "suite" {printf "  %s\n", $2}' "$PLAN_FILE" >&2
[ "$DRY_RUN" = 0 ] || { log "dry run: not running suites, not pushing"; exit 0; }

while IFS=$'\t' read -r kind command; do
  [ "$kind" = suite ] || continue
  log "running: $command"
  if ! bash -o pipefail -c "$command" </dev/null; then
    refuse "suite failed: $command; nothing was pushed"
  fi
done < "$PLAN_FILE"

# Re-check that nothing moved while the suites ran.
[ "$(git rev-parse HEAD)" = "$HEAD_SHA" ] || refuse "HEAD moved while the suites ran; run again"
[ -z "$(git status --porcelain --untracked-files=all)" ] || refuse "the working tree changed while the suites ran; run again"

log "all suites passed; pushing $HEAD_SHA to $REMOTE main"
git push "$REMOTE" HEAD:main

if [ "$CANCEL_CI" = 1 ]; then
  wait_s="${HOTFIX_PUSH_CI_WAIT_SECONDS:-90}"
  deadline=$((SECONDS + wait_s))
  cancelled=0
  while :; do
    ids="$(gh run list -R "$GH_REPO" --branch main --commit "$HEAD_SHA" --json databaseId,status \
      --jq '.[] | select(.status != "completed") | .databaseId' 2>/dev/null || true)"
    for id in $ids; do
      if gh run cancel "$id" -R "$GH_REPO" >/dev/null; then
        log "cancelled main CI run $id for $HEAD_SHA"
        cancelled=$((cancelled + 1))
      else
        log "could not cancel main CI run $id"
      fi
    done
    [ "$cancelled" = 0 ] && [ "$SECONDS" -lt "$deadline" ] || break
    sleep 5
  done
  [ "$cancelled" -gt 0 ] || log "no in-progress main CI run for $HEAD_SHA appeared within ${wait_s}s"
fi
log "pushed $HEAD_SHA"
