#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[verify-github-release-posture] ERROR: %s\n' "$*" >&2
  exit 1
}

repo="${1:-}"
environment_name="${2:-production-release}"
release_tagger_id="${3:-28995904}"

[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "repository must be OWNER/REPO"
[[ "$environment_name" =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid environment name"
[[ "$release_tagger_id" =~ ^[1-9][0-9]*$ ]] || die "release tagger id must be numeric"
[[ -n "${GH_TOKEN:-}" ]] || die "GH_TOKEN with Administration:read and Actions:read is required"

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/release-posture.XXXXXX")"
trap 'rm -rf "$work"' EXIT

gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
  "repos/$repo/immutable-releases" >"$work/immutable.json" ||
  die "repository immutable releases are unavailable or disabled"
gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
  "repos/$repo/environments/$environment_name" >"$work/environment.json" ||
  die "protected release environment is unavailable"
gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
  "repos/$repo/environments/$environment_name/deployment-branch-policies?per_page=100" \
  >"$work/environment-policies.json" ||
  die "release environment branch policies are unavailable"
gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
  "repos/$repo/rulesets?targets=tag&per_page=100" >"$work/rulesets.json" ||
  die "tag rulesets are unavailable"

python3 - "$work" "$environment_name" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
environment_name = sys.argv[2]

immutable = json.loads((root / "immutable.json").read_text())
if immutable.get("enabled") is not True:
    raise SystemExit("repository immutable releases are not enabled")

environment = json.loads((root / "environment.json").read_text())
rules = environment.get("protection_rules")
review_rules = [
    rule for rule in rules or []
    if isinstance(rule, dict) and rule.get("type") == "required_reviewers"
]
if not review_rules or not any(
    isinstance(rule.get("reviewers"), list) and rule["reviewers"] for rule in review_rules
):
    raise SystemExit(f"{environment_name} must require an environment reviewer")
if not all(rule.get("prevent_self_review") is True for rule in review_rules):
    raise SystemExit(f"{environment_name} must prevent self-review")
branch_policy = environment.get("deployment_branch_policy")
if (
    not isinstance(branch_policy, dict)
    or branch_policy.get("custom_branch_policies") is not True
    or branch_policy.get("protected_branches") is not False
):
    raise SystemExit(f"{environment_name} must use custom deployment branch policies")

policies = json.loads((root / "environment-policies.json").read_text()).get("branch_policies")
if not isinstance(policies, list) or not policies or not all(
    isinstance(policy, dict)
    and policy.get("name") == "main"
    and policy.get("type") in (None, "branch")
    for policy in policies
):
    raise SystemExit(f"{environment_name} must allow only the main branch")

rulesets = json.loads((root / "rulesets.json").read_text())
if not isinstance(rulesets, list):
    raise SystemExit("repository tag rulesets response is invalid")
active_ids = [
    row.get("id") for row in rulesets
    if isinstance(row, dict) and row.get("target") == "tag" and row.get("enforcement") == "active"
]
if not active_ids:
    raise SystemExit("no active tag ruleset is configured")
(root / "active-ruleset-ids").write_text("\n".join(str(value) for value in active_ids) + "\n")
PY

matched=0
while IFS= read -r ruleset_id; do
  [[ "$ruleset_id" =~ ^[0-9]+$ ]] || die "invalid active ruleset id"
  gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
    "repos/$repo/rulesets/$ruleset_id" >"$work/ruleset-$ruleset_id.json" ||
    die "could not inspect active tag ruleset $ruleset_id"
  if python3 - "$work/ruleset-$ruleset_id.json" "$release_tagger_id" <<'PY'
import json
import sys

ruleset = json.load(open(sys.argv[1], encoding="utf-8"))
release_tagger_id = int(sys.argv[2])
include = (((ruleset.get("conditions") or {}).get("ref_name") or {}).get("include") or [])
exclude = (((ruleset.get("conditions") or {}).get("ref_name") or {}).get("exclude") or [])
covers_release_tags = ("~ALL" in include or "refs/tags/v*" in include) and not exclude
rule_types = {
    rule.get("type") for rule in ruleset.get("rules", []) if isinstance(rule, dict)
}
bypasses = ruleset.get("bypass_actors") or []
valid_bypass = len(bypasses) == 1 and all(
    isinstance(actor, dict)
    and actor.get("actor_type") == "User"
    and actor.get("actor_id") == release_tagger_id
    and actor.get("bypass_mode") == "always"
    for actor in bypasses
)
raise SystemExit(0 if covers_release_tags and {"creation", "update", "deletion"} <= rule_types and valid_bypass else 1)
PY
  then
    matched=1
    break
  fi
done <"$work/active-ruleset-ids"

[[ "$matched" == 1 ]] ||
  die "no active v* tag ruleset restricts create, update, and delete with only the designated tagger bypass"

printf '[verify-github-release-posture] ok: immutable releases, protected environment, and tag ruleset verified\n'
