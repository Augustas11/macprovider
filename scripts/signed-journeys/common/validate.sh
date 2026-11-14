#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/registry.sh"
[[ "$GITHUB_EVENT_NAME" == workflow_dispatch ]] || { echo "::error::manual dispatch required" >&2; exit 1; }
[[ "$GITHUB_REF" == refs/heads/main ]] || { echo "::error::workflow must run from main" >&2; exit 1; }
[[ "$SOURCE_SHA_INPUT" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::invalid source SHA" >&2; exit 1; }
if [[ "$confirm" == promotion ]]; then
  [[ "$PROMOTION_CONFIRMED_INPUT" == true ]] || { echo "::error::promotion confirmation is required" >&2; exit 1; }
elif [[ "$confirm" == evidence ]]; then
  [[ "$EVIDENCE_CONFIRMED_INPUT" == true ]] || { echo "::error::evidence confirmation is required" >&2; exit 1; }
else
  echo "::error::unknown confirmation mode" >&2
  exit 1
fi
[[ "$REDACTED_EVIDENCE_INPUT" =~ $evidence_regex ]] || { echo "::error::invalid redacted evidence path" >&2; exit 1; }
[[ -f "$REDACTED_EVIDENCE_INPUT" && ! -L "$REDACTED_EVIDENCE_INPUT" ]] || { echo "::error::redacted evidence is absent or unsafe" >&2; exit 1; }
[[ "$REQUIREMENT_IDS_INPUT" =~ ^SPEC-[0-9]{3}-R[0-9]{3}(,SPEC-[0-9]{3}-R[0-9]{3})*$ ]] || { echo "::error::invalid requirement IDs" >&2; exit 1; }
git fetch --quiet origin refs/heads/main:refs/remotes/origin/main
main_sha="$(git rev-parse refs/remotes/origin/main)"
[[ "$main_sha" == "$GITHUB_SHA" ]] || { echo "::error::workflow commit is no longer origin/main" >&2; exit 1; }
git cat-file -e "${SOURCE_SHA_INPUT}^{commit}" || { echo "::error::source SHA is not reachable" >&2; exit 1; }
git merge-base --is-ancestor "$SOURCE_SHA_INPUT" "$GITHUB_SHA" || { echo "::error::source SHA must be an ancestor of the reviewed evidence commit" >&2; exit 1; }
requirement_slug="$(printf '%s' "$REQUIREMENT_IDS_INPUT" | tr '[:upper:]' '[:lower:]' | tr ',' '-')"
[[ "$requirement_slug" =~ ^spec-[0-9]{3}-r[0-9]{3}(-spec-[0-9]{3}-r[0-9]{3})*$ ]] || { echo "::error::invalid requirement slug" >&2; exit 1; }
envelope="${REDACTED_EVIDENCE_INPUT%.redacted.json}.${requirement_slug}.journey-result.signed.json"
payload="$RUNNER_TEMP/${payload_prefix}-${requirement_slug}.unsigned.json"
short_sha="${SOURCE_SHA_INPUT:0:12}"
case "$artifact_mode" in
  sha-slug) artifact_name="${artifact_prefix}-${SOURCE_SHA_INPUT}-${requirement_slug}" ;;
  short) artifact_name="${artifact_prefix}-${short_sha}" ;;
  *) echo "::error::unknown artifact mode" >&2; exit 1 ;;
esac
[[ "$export_dir_name" =~ ^[a-z0-9-]+$ ]] || { echo "::error::unsafe export directory" >&2; exit 1; }
[[ "$artifact_name" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "::error::unsafe artifact name" >&2; exit 1; }
printf 'source_sha=%s\n' "$SOURCE_SHA_INPUT" >> "$GITHUB_OUTPUT"
printf 'evidence_sha=%s\n' "$GITHUB_SHA" >> "$GITHUB_OUTPUT"
printf 'short_sha=%s\n' "$short_sha" >> "$GITHUB_OUTPUT"
printf 'redacted=%s\n' "$REDACTED_EVIDENCE_INPUT" >> "$GITHUB_OUTPUT"
printf 'requirement_ids=%s\n' "$REQUIREMENT_IDS_INPUT" >> "$GITHUB_OUTPUT"
printf 'requirement_slug=%s\n' "$requirement_slug" >> "$GITHUB_OUTPUT"
printf 'payload=%s\n' "$payload" >> "$GITHUB_OUTPUT"
printf 'envelope=%s\n' "$envelope" >> "$GITHUB_OUTPUT"
printf 'artifact_name=%s\n' "$artifact_name" >> "$GITHUB_OUTPUT"
printf 'export_dir=%s\n' "$export_dir_name" >> "$GITHUB_OUTPUT"
