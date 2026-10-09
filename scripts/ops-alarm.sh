#!/usr/bin/env bash
# Route a scheduled-workflow outcome to one GitHub issue per alarm key.
#
#   failure | alarm  -> open an `ops-alarm` issue assigned to the operator, or
#                       comment on the open one
#   success          -> comment and close the open issue, if any
#   anything else    -> no-op. `cancelled` is deliberately a no-op here: the
#                       6-hourly alarms cancel superseded runs by design. The
#                       watcher (ops-alarm-watch.yml) raises `alarm` for the
#                       renewals, where a cancellation is abnormal.
#
# Uses only the calling job's GITHUB_TOKEN (issues: write). The repository is
# public: the title and body name the workflow, outcome and run link only, never
# logs, hosts, provider IDs or other operations detail.
#
# Env: ALARM_KEY ALARM_RESULT ALARM_TITLE [ALARM_BODY] [ALARM_RUN_URL]
#      [ALARM_ASSIGNEE] GITHUB_REPOSITORY GH_TOKEN
set -euo pipefail

die() {
  printf '[ops-alarm] ERROR: %s\n' "$*" >&2
  exit 1
}

key="${ALARM_KEY:-}"
result="${ALARM_RESULT:-}"
title="${ALARM_TITLE:-}"
body="${ALARM_BODY:-}"
run_url="${ALARM_RUN_URL:-}"
assignee="${ALARM_ASSIGNEE:-Augustas11}"
repo="${GITHUB_REPOSITORY:-}"
label="ops-alarm"

[[ "$key" =~ ^[a-z0-9][a-z0-9._-]{0,79}$ ]] || die "ALARM_KEY must be a lowercase slug"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "GITHUB_REPOSITORY is invalid"
[ -n "$title" ] || die "ALARM_TITLE is required"

prefix="ops-alarm: $key —"
issue_title="$prefix $title"

case "$result" in
  failure | alarm) action=raise ;;
  success) action=clear ;;
  *)
    printf '[ops-alarm] %s: result=%s, nothing to do\n' "$key" "${result:-<empty>}"
    exit 0
    ;;
esac

open_issue="$(
  gh issue list --repo "$repo" --label "$label" --state open --limit 200 \
    --json number,title \
    --jq "[.[] | select(.title | startswith(\"$prefix\"))] | sort_by(.number) | .[0].number // empty"
)"

stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
note="$stamp result=\`$result\`"
[ -z "$run_url" ] || note="$note — $run_url"

if [ "$action" = clear ]; then
  if [ -z "$open_issue" ]; then
    printf '[ops-alarm] %s: healthy, no open alarm\n' "$key"
    exit 0
  fi
  gh issue comment "$open_issue" --repo "$repo" --body "Recovered: $note"
  gh issue close "$open_issue" --repo "$repo" --reason completed
  printf '[ops-alarm] %s: closed #%s\n' "$key" "$open_issue"
  exit 0
fi

detail="${body:-The scheduled workflow did not succeed.}"
if [ -n "$open_issue" ]; then
  gh issue comment "$open_issue" --repo "$repo" --body "Still failing: $note

$detail"
  printf '[ops-alarm] %s: commented on #%s\n' "$key" "$open_issue"
  exit 0
fi

# Idempotent: creating an existing label fails, which is fine.
gh label create "$label" --repo "$repo" --color B60205 \
  --description "Scheduled workflow alarm; closes itself on the next green run" \
  >/dev/null 2>&1 || true
issue_body="$detail

First seen: $note

This issue closes itself on the next successful run of the same alarm key
(\`$key\`). Comments are added while it keeps failing."
# An unassignable login must not swallow the alarm: retry unassigned.
gh issue create --repo "$repo" --title "$issue_title" --body "$issue_body" \
  --label "$label" --assignee "$assignee" ||
  gh issue create --repo "$repo" --title "$issue_title" --body "$issue_body" \
    --label "$label"
printf '[ops-alarm] %s: opened a new alarm issue\n' "$key"
