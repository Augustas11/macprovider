#!/usr/bin/env bash
# Offline tests for scripts/ops/hotfix-push.sh. A temp repo whose `origin` is a
# local bare repo stands in for the real one; its suites are stubs that record
# that they ran (and fail on request), and `gh` is a stub that logs its argv.
# Usage: bash scripts/ops/test-hotfix-push.sh
set -euo pipefail

HOTFIX="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hotfix-push.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$*"; }

export HOTFIX_LOG="$tmp/ran" HOTFIX_PUSH_CI_WAIT_SECONDS=0 MACPROVIDER_GH_REPO=test/repo
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
unset FAIL_ALPHA FAIL_CATALOG

# ---- stubs -------------------------------------------------------------------
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HOTFIX_LOG.gh"
case "$1 $2" in
  "run list") printf '77\n' ;;
  "run cancel") ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

# ---- repo fixture ------------------------------------------------------------
git init -q --bare "$tmp/origin.git"
W="$tmp/work"
git init -q -b main "$W"
git -C "$W" remote add origin "$tmp/origin.git"
mkdir -p "$W/scripts/tests" "$W/scripts/ops" "$W/phase3-binary/catalog" "$W/phase4-coordinator" "$W/specs"
touch "$W/scripts/__init__.py" "$W/scripts/tests/__init__.py"
# rec NAME: a suite stub line that records NAME.
rec() { printf 'echo %s >> "$HOTFIX_LOG"\n' "$1"; }
printf 'import os, unittest\n# covers alpha_tool and projection.json\nclass T(unittest.TestCase):\n    def test(self):\n        open(os.environ["HOTFIX_LOG"], "a").write("test_alpha\\n")\n        self.assertFalse(os.environ.get("FAIL_ALPHA"))\n' \
  > "$W/scripts/tests/test_alpha.py"
printf 'import os, unittest\nclass T(unittest.TestCase):\n    def test(self):\n        open(os.environ["HOTFIX_LOG"], "a").write("test_beta\\n")\n' \
  > "$W/scripts/tests/test_beta.py"
printf 'X = 1\n' > "$W/scripts/alpha_tool.py"
printf 'X = 1\n' > "$W/scripts/tests/helper.py"
printf 'X = 1\n' > "$W/scripts/lonely_tool.py"
{ rec catalog_test; printf '[ -z "${FAIL_CATALOG:-}" ]\n'; } > "$W/scripts/test-catalog-release.sh"
printf 'import os\nopen(os.environ["HOTFIX_LOG"], "a").write("catalog_verify\\n")\n' > "$W/scripts/catalog-release.py"
for s in check_spec_governance gen_spec_index decode_path_digest check-test-wiring; do
  printf 'import os\nopen(os.environ["HOTFIX_LOG"], "a").write("%s\\n")\n' "$s" > "$W/scripts/$s.py"
done
printf '{"files": ["Sources/macprovider-cli/Decode.swift"]}\n' > "$W/phase3-binary/decode-path-manifest.json"
printf '#!/bin/bash\necho tool\n' > "$W/scripts/ops/tool.sh"
{ rec ops_test_tool; echo '# exercises scripts/ops/tool.sh'; } > "$W/scripts/ops/test-tool.sh"
rec ops_test_other > "$W/scripts/ops/test-other.sh"
printf '{}\n' > "$W/phase3-binary/catalog/projection.json"
printf 'package main\n' > "$W/phase4-coordinator/main.go"
printf '# spec\n' > "$W/specs/SPEC-001-x.md"
printf '{}\n' > "$W/specs/index.json"
printf '# readme\n' > "$W/phase4-coordinator/README.md"
printf 'notes\n' > "$W/notes.txt"
git -C "$W" add -A
git -C "$W" commit -q -m base
git -C "$W" push -q origin main

# change FILE...: commit an edit to each FILE on top of origin/main.
change() {
  git -C "$W" fetch -q origin
  git -C "$W" reset -q --hard origin/main
  local f
  for f in "$@"; do
    mkdir -p "$(dirname "$W/$f")"
    printf '# edit %s\n' "$RANDOM" >> "$W/$f"
    git -C "$W" add "$f"
  done
  git -C "$W" commit -q -m "edit $*"
  : > "$HOTFIX_LOG"
  rm -f "$HOTFIX_LOG.gh"
}
# run WANT DESC ARGS...
run() {
  local want="$1" desc="$2" rc=0
  shift 2
  (cd "$W" && bash "$HOTFIX" "$@") >"$tmp/out" 2>"$tmp/err" || rc=$?
  if [ "$rc" = "$want" ]; then ok; else bad "$desc: want rc=$want got rc=$rc"; sed 's/^/    /' "$tmp/err" | tail -n 8; fi
}
ran() { grep -qx "$1" "$HOTFIX_LOG"; }
expect_ran() { if ran "$1"; then ok; else bad "$2: $1 did not run ($(tr '\n' ' ' < "$HOTFIX_LOG"))"; fi; }
expect_not_ran() { if ran "$1"; then bad "$2: $1 ran"; else ok; fi; }
pushed() { [ "$(git -C "$tmp/origin.git" rev-parse main)" = "$(git -C "$W" rev-parse HEAD)" ]; }
expect_pushed() { if pushed; then ok; else bad "$1: not pushed"; fi; }
expect_not_pushed() { if pushed; then bad "$1: pushed"; else ok; fi; }
expect_err() { if grep -q -- "$1" "$tmp/err"; then ok; else bad "stderr lacks '$1'"; sed 's/^/    /' "$tmp/err" | tail -n 5; fi; }

# A script change runs only the test modules that name it, then pushes.
change scripts/alpha_tool.py
run 0 "script change"
expect_ran test_alpha "script change"
expect_not_ran test_beta "script change"
expect_pushed "script change"
if [ -e "$HOTFIX_LOG.gh" ]; then bad "gh called without --cancel-ci"; else ok; fi

# A failing covering test refuses the push.
change scripts/alpha_tool.py
FAIL_ALPHA=1 run 3 "failing test"
expect_err "suite failed"
expect_not_pushed "failing test"

# A script no test names, or a test helper: the full scripts/tests suite.
change scripts/lonely_tool.py
run 0 "unreferenced script"
expect_ran test_alpha "unreferenced script"
expect_ran test_beta "unreferenced script"
change scripts/tests/helper.py
run 0 "test helper"
expect_ran test_beta "test helper"
expect_ran check-test-wiring "test helper"

# Catalog data: the catalog suites and the Python tests that name the file
# (the committed projection broke a Python test in 728f0f0b3); a catalog file
# no test names runs the full Python suite.
change phase3-binary/catalog/projection.json
run 0 "catalog change"
for s in catalog_test catalog_verify test_alpha; do expect_ran "$s" "catalog change"; done
expect_not_ran test_beta "catalog change"
change phase3-binary/catalog/unnamed.json
run 0 "unnamed catalog file"
for s in catalog_test catalog_verify test_alpha test_beta; do expect_ran "$s" "unnamed catalog file"; done
change phase3-binary/Sources/macprovider-cli/AutotuneCatalog.generated.swift
run 0 "generated catalog Swift rides with the catalog"
expect_ran catalog_verify "generated catalog Swift"
change phase3-binary/catalog/projection.json
FAIL_CATALOG=1 run 3 "failing catalog suite"
expect_not_pushed "failing catalog suite"

# Ops files: the ops tests that name them.
change scripts/ops/tool.sh
run 0 "ops change"
expect_ran ops_test_tool "ops change"
expect_not_ran ops_test_other "ops change"

# Specs (non-normative) and decode-path inputs.
change specs/index.json
run 0 "spec index change"
expect_ran check_spec_governance "spec index change"
expect_ran gen_spec_index "spec index change"
change phase3-binary/decode-path-manifest.json
run 0 "decode manifest change"
expect_ran decode_path_digest "decode manifest change"

# PR-only paths are refused; docs are not.
change phase4-coordinator/main.go
run 3 "Go change"
expect_err "need a PR"
expect_err "phase4-coordinator/main.go"
expect_not_pushed "Go change"
change specs/SPEC-001-x.md
run 3 "SPEC change"
expect_not_pushed "SPEC change"
change .github/workflows/ci.yml
run 3 "workflow change"
change phase3-binary/Sources/macprovider-cli/Foo.swift
run 3 "Swift change"
change phase3-binary/Package.resolved
run 3 "pin change"
change phase4-coordinator/README.md
run 0 "docs-only change"
expect_pushed "docs-only change"
if [ -s "$HOTFIX_LOG" ]; then bad "docs-only change ran suites: $(cat "$HOTFIX_LOG")"; else ok; fi
# An unmapped file falls back to the full Python suite.
change notes.txt
run 0 "unmapped change"
expect_ran test_beta "unmapped change"

# Preconditions.
change scripts/alpha_tool.py
printf 'dirty\n' >> "$W/scripts/alpha_tool.py"
run 3 "dirty tree"
expect_err "not clean"
git -C "$W" checkout -q -- scripts/alpha_tool.py
touch "$W/untracked"
run 3 "untracked file"
rm -f "$W/untracked"
# origin/main moved on: HEAD is no longer a fast-forward.
git clone -q "$tmp/origin.git" "$tmp/other"
printf 'x\n' >> "$tmp/other/notes.txt"
git -C "$tmp/other" commit -q -am other
git -C "$tmp/other" push -q origin main
run 3 "stale base"
expect_err "not an ancestor of HEAD"
# A merge commit in the range.
change scripts/alpha_tool.py
git -C "$W" checkout -q -b side origin/main
printf 'y\n' >> "$W/notes.txt"
git -C "$W" commit -q -am side
git -C "$W" checkout -q main
git -C "$W" merge -q --no-edit side
run 3 "merge commit"
expect_err "merge commits"
git -C "$W" branch -q -D side
# Nothing to push.
git -C "$W" reset -q --hard origin/main
run 3 "nothing to push"
# Local main diverged from both origin/main and HEAD.
change scripts/alpha_tool.py
git -C "$W" checkout -q --detach
git -C "$W" branch -q -f main origin/main~1
run 3 "diverged local main"
expect_err "local main"
git -C "$W" checkout -q -B main

# --dry-run plans only.
change scripts/alpha_tool.py
run 0 "dry run" --dry-run
expect_err "scripts.tests.test_alpha"
if [ -s "$HOTFIX_LOG" ]; then bad "dry run ran suites"; else ok; fi
expect_not_pushed "dry run"

# --cancel-ci cancels the main run for the pushed SHA.
run 0 "push with --cancel-ci" --cancel-ci
expect_pushed "push with --cancel-ci"
sha="$(git -C "$W" rev-parse HEAD)"
if grep -qxF -- "run list -R test/repo --branch main --commit $sha --json databaseId,status --jq .[] | select(.status != \"completed\") | .databaseId" "$HOTFIX_LOG.gh" &&
  grep -qxF -- "run cancel 77 -R test/repo" "$HOTFIX_LOG.gh"; then ok; else bad "gh calls: $(cat "$HOTFIX_LOG.gh" 2>/dev/null)"; fi

run 2 "unknown argument" --bogus

printf 'test-hotfix-push: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
