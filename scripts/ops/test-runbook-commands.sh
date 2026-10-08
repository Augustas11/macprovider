#!/usr/bin/env bash
# Fails when a command constant in scripts/ops/lib/runbook-commands.sh drifts
# from the fenced runbook block it copies. The runbooks are read with
# `git show $RUNBOOK_REF:<doc>` (default origin/main), never from the working
# tree, and normalized with the same host placeholders the constants use.
# Also checks that a deliberately altered constant is caught, and that the
# rendered apply command fills the placeholders.
# Usage: bash scripts/ops/test-runbook-commands.sh
set -euo pipefail

OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$OPS_DIR/../.." && pwd)"
REF="${RUNBOOK_REF:-origin/main}"
git -C "$REPO_ROOT" rev-parse -q --verify "$REF^{commit}" >/dev/null ||
  { echo "test-runbook-commands: $REF is not available; fetch it first" >&2; exit 1; }

# shellcheck source=lib/runbook-commands.sh
. "$OPS_DIR/lib/runbook-commands.sh"

# block DOC HEADING N -> the Nth fenced block under HEADING, normalized.
block() {
  git -C "$REPO_ROOT" show "$REF:$1" | python3 -c '
import re, sys
heading, n = sys.argv[1], int(sys.argv[2])
lines = sys.stdin.read().splitlines()
start = next((i for i, l in enumerate(lines) if l.lstrip().startswith("#") and heading in l), None)
if start is None:
    sys.exit("heading %r not found" % heading)
seen, buf, inside, indent = 0, [], False, 0
for l in lines[start + 1:]:
    if not inside and l.startswith("#"):
        break
    if l.strip().startswith("```"):
        if inside:
            seen += 1
            if seen == n:
                t = "\n".join(buf)
                t = re.sub(r"(?m)^(\s*(?:\|\|\s*)?)ssh [A-Za-z0-9_.-]+ \x27", "\\1ssh <pearl-ssh> \x27", t)
                t = re.sub(r"https://coordinator\.[A-Za-z0-9.-]+", "<coordinator-url>", t)
                print(t)
                sys.exit(0)
            buf, inside = [], False
        else:
            inside, indent = True, len(l) - len(l.lstrip())
        continue
    if inside:
        buf.append(l[indent:] if l[:indent].strip() == "" else l)
sys.exit("block %d under %r not found" % (n, heading))
' "$2" "$3"
}

pass=0
fail=0
while IFS='|' read -r name doc heading n; do
  [ -n "$name" ] || continue
  want="$(block "$doc" "$heading" "$n")"
  if [ "${!name}" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "DRIFT $name vs $REF:$doc ($heading, block $n):"
    diff <(printf '%s\n' "${!name}") <(printf '%s\n' "$want") | sed 's/^/    /' || true
  fi
done <<EOF
$RUNBOOK_SOURCES
EOF

# A drifted constant must be detected.
tampered="${RB_PEARL_APPLY/--apply/--apply --force}"
if [ "$tampered" != "$(block docs/runbooks/pearl-coordinator-rollout.md "Runtime apply (signed updater)" 1)" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "FAIL tampered constant not detected"
fi

# Rendering fills every placeholder and keeps the command text.
rendered="$(OPS_NAME=test COORDINATOR_URL=https://example.test bash -c '. "$1/lib/common.sh"; render_runbook "$RB_PEARL_APPLY" 1.8.999' _ "$OPS_DIR")"
# shellcheck disable=SC2016  # literal text expected in the rendered command
case "$rendered" in
  *'<'*'>'*) fail=$((fail + 1)); echo "FAIL placeholder left in rendered apply: $rendered" ;;
  *'ssh "$PEARL_SSH" '*'--apply --tag v1.8.999'*) pass=$((pass + 1)) ;;
  *) fail=$((fail + 1)); echo "FAIL unexpected rendered apply: $rendered" ;;
esac
rc=0
(OPS_NAME=test COORDINATOR_URL='https://x.test/;rm' bash -c '. "$1/lib/common.sh"; render_runbook "$RB_PEARL_PREFLIGHT"' _ "$OPS_DIR") >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL unsafe COORDINATOR_URL rendered"; fi

printf 'runbook commands: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
