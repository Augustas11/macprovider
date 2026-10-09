#!/usr/bin/env bash
# Regression test for scripts/ops-alarm.sh with a stubbed `gh`, plus a check
# that every scheduled workflow routes its outcome through ops-alarm.yml.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/test-ops-alarm.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() {
  printf '[test-ops-alarm] FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" | tr '\n' ' ' >> "$GH_STUB_LOG"
printf '\n' >> "$GH_STUB_LOG"
case "$1 $2" in
  "issue list") printf '%s' "${GH_STUB_OPEN:-}" ;;
  "issue create") [[ "$*" == *"--assignee nobody"* ]] && exit 1 ;;
esac
exit 0
STUB
chmod +x "$work/bin/gh"

alarm() {
  : > "$work/log"
  PATH="$work/bin:$PATH" GH_STUB_LOG="$work/log" GITHUB_REPOSITORY=o/r \
    ALARM_KEY=renew-x ALARM_TITLE="renewal failed" ALARM_RUN_URL=https://example.invalid/run \
    "$@" bash "$root/scripts/ops-alarm.sh" >/dev/null
}

alarm env ALARM_RESULT=failure GH_STUB_OPEN=
grep -q '^issue create .*--title ops-alarm: renew-x — renewal failed .*--label ops-alarm --assignee Augustas11' "$work/log" ||
  fail "failure without an open issue must create one assigned to the operator"

alarm env ALARM_RESULT=failure GH_STUB_OPEN=42
grep -q '^issue comment 42 ' "$work/log" || fail "failure with an open issue must comment on it"
grep -q '^issue create' "$work/log" && fail "failure with an open issue must not open a second one"

alarm env ALARM_RESULT=alarm GH_STUB_OPEN=
grep -q '^issue create' "$work/log" || fail "watcher alarm must open an issue"

alarm env ALARM_RESULT=success GH_STUB_OPEN=42
grep -q '^issue close 42 ' "$work/log" || fail "success must close the open issue"

alarm env ALARM_RESULT=success GH_STUB_OPEN=
grep -q '^issue \(create\|close\|comment\)' "$work/log" && fail "success without an open issue must not write"

for result in cancelled skipped ""; do
  alarm env ALARM_RESULT="$result" GH_STUB_OPEN=42
  [ ! -s "$work/log" ] || fail "result '$result' must be a no-op"
done

alarm env ALARM_RESULT=failure GH_STUB_OPEN= ALARM_ASSIGNEE=nobody
[ "$(grep -c '^issue create' "$work/log")" = 2 ] || fail "an unassignable login must fall back to an unassigned issue"

if alarm env ALARM_RESULT=failure ALARM_KEY='Bad Key' 2>/dev/null; then
  fail "a non-slug key must be refused"
fi

# Every scheduled workflow must call the alarm router with its own result.
python3 - "$root/.github/workflows" <<'PY'
import pathlib
import re
import sys

missing = []
for path in sorted(pathlib.Path(sys.argv[1]).glob("*.yml")):
    text = path.read_text(encoding="utf-8")
    if not re.search(r"^  schedule:", text, re.M):
        continue
    if "uses: ./.github/workflows/ops-alarm.yml" not in text or "if: ${{ always() }}" not in text:
        missing.append(path.name)
if missing:
    raise SystemExit("scheduled workflows without an ops-alarm job: " + ", ".join(missing))
PY

printf '[test-ops-alarm] PASS\n'
