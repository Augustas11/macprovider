#!/usr/bin/env bash
# Lane classification of the draft .github/workflows/fast-required.yml. Runs
# the workflow's own "Classify the diff" script against synthetic commits in
# a temp repo and checks lane=fast only for root/docs/audits/beta Markdown and
# .cursor/rules, case-insensitively.
# Usage: bash scripts/ops/test-fast-required.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Extract the run block of the "Classify the diff" step without a YAML library.
python3 - "$REPO_ROOT/.github/workflows/fast-required.yml" > "$tmp/classify.sh" <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
i = next(i for i, l in enumerate(lines) if l.strip() == "- name: Classify the diff")
j = next(k for k in range(i, len(lines)) if lines[k].strip() == "run: |")
indent = len(lines[j + 1]) - len(lines[j + 1].lstrip())
for l in lines[j + 1:]:
    if l.strip() and len(l) - len(l.lstrip()) < indent:
        break
    print(l[indent:])
PY

git init -q "$tmp/r"
git -C "$tmp/r" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m base
base="$(git -C "$tmp/r" rev-parse HEAD)"
pass=0
fail=0

# lane_for WANT PATH...: commit PATHs on top of base and classify base..head.
lane_for() {
  local want="$1" p got
  shift
  git -C "$tmp/r" checkout -q --detach "$base"
  for p in "$@"; do mkdir -p "$tmp/r/$(dirname "$p")"; printf 'x\n' > "$tmp/r/$p"; git -C "$tmp/r" add -- "$p"; done
  git -C "$tmp/r" -c user.name=t -c user.email=t@example.invalid commit -q -m change
  : > "$tmp/out"
  got="$(cd "$tmp/r" && RUNNER_TEMP="$tmp" GITHUB_OUTPUT="$tmp/out" EVENT_NAME=workflow_dispatch \
    INPUT_BASE="$base" INPUT_HEAD="$(git rev-parse HEAD)" bash "$tmp/classify.sh" >/dev/null && sed -n 's/^lane=//p' "$tmp/out")"
  if [ "$got" = "$want" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $*: want lane=$want got lane=$got"; fi
}

lane_for fast README.md
lane_for fast CHANGELOG.MD
lane_for fast docs/runbooks/x.md
lane_for fast Docs/Runbooks/X.MD
lane_for fast audits/2026-10-09/README.md beta/notes.md
lane_for fast .cursor/rules/lab-campaign-loop.mdc
lane_for full specs/SPEC-001-x.md
lane_for full scripts/fixtures/sample.md
lane_for full phase3-binary/Tests/fixtures/notes.md
lane_for full docs/runbooks/data/table.json
lane_for full phase4-coordinator/coordinator.yaml.example
lane_for full phase4-coordinator/dist/coordinator.yaml
lane_for full phase3-binary/catalog/autotune/release.json
lane_for full scripts/ops/cli-release.sh
lane_for full docs/x.md phase4-coordinator/main.go
lane_for full .github/workflows/fast-required.yml

printf 'fast-required lanes: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
