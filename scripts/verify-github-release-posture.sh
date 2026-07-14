#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[verify-github-release-posture] ERROR: %s\n' "$*" >&2
  exit 1
}

repo="${1:-}"
environment_name="${2:-production-release}"
release_tagger_id="${3:-28995904}"
release_reviewer_id="${4:-285575208}"
release_reviewer_login="${5:-antfleet-ops}"
posture_mode="${6:---production}"
source_ref="${7:-refs/heads/main}"

[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "repository must be OWNER/REPO"
[[ "$environment_name" =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid environment name"
[[ "$release_tagger_id" =~ ^[1-9][0-9]*$ ]] || die "release tagger id must be numeric"
[[ "$release_reviewer_id" =~ ^[1-9][0-9]*$ ]] || die "release reviewer id must be numeric"
[[ "$release_reviewer_login" =~ ^[A-Za-z0-9-]+$ ]] || die "release reviewer login is invalid"
[[ "$posture_mode" == "--production" || "$posture_mode" == "--acceptance-candidate" ]] ||
  die "posture mode must be --production or --acceptance-candidate"
[[ "$source_ref" == refs/heads/* ]] || die "release source must be a branch ref"
source_branch="${source_ref#refs/heads/}"
git check-ref-format --branch "$source_branch" >/dev/null 2>&1 || die "release source branch is invalid"
if [[ "$posture_mode" == "--production" && "$source_ref" != "refs/heads/main" ]]; then
  die "production release posture requires refs/heads/main"
fi
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

python3 - "$work" "$environment_name" "$release_reviewer_id" "$release_reviewer_login" \
  "$posture_mode" "$source_branch" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
environment_name = sys.argv[2]
release_reviewer_id = int(sys.argv[3])
release_reviewer_login = sys.argv[4]
posture_mode = sys.argv[5]
source_branch = sys.argv[6]

immutable = json.loads((root / "immutable.json").read_text())
if immutable.get("enabled") is not True:
    raise SystemExit("repository immutable releases are not enabled")

environment = json.loads((root / "environment.json").read_text())
if environment.get("can_admins_bypass") is not False:
    raise SystemExit(f"{environment_name} must disable admin bypass")
rules = environment.get("protection_rules")
review_rules = [
    rule for rule in rules or []
    if isinstance(rule, dict) and rule.get("type") == "required_reviewers"
]
if len(review_rules) != 1:
    raise SystemExit(f"{environment_name} must have exactly one required-reviewers rule")
reviewers = review_rules[0].get("reviewers")
if not isinstance(reviewers, list) or len(reviewers) != 1:
    raise SystemExit(f"{environment_name} must require exactly one environment reviewer")
reviewer_entry = reviewers[0]
reviewer = reviewer_entry.get("reviewer") if isinstance(reviewer_entry, dict) else None
if not isinstance(reviewer, dict):
    reviewer = reviewer_entry
if (
    not isinstance(reviewer_entry, dict)
    or reviewer_entry.get("type") != "User"
    or not isinstance(reviewer, dict)
    or reviewer.get("id") != release_reviewer_id
    or reviewer.get("login") != release_reviewer_login
):
    raise SystemExit(
        f"{environment_name} reviewer must be User {release_reviewer_login} ({release_reviewer_id})"
    )
if review_rules[0].get("prevent_self_review") is not True:
    raise SystemExit(f"{environment_name} must prevent self-review")
branch_policy = environment.get("deployment_branch_policy")
if (
    not isinstance(branch_policy, dict)
    or branch_policy.get("custom_branch_policies") is not True
    or branch_policy.get("protected_branches") is not False
):
    raise SystemExit(f"{environment_name} must use custom deployment branch policies")

policies = json.loads((root / "environment-policies.json").read_text()).get("branch_policies")
if not isinstance(policies, list) or not all(
    isinstance(policy, dict)
    and isinstance(policy.get("name"), str)
    and policy.get("type") in (None, "branch")
    for policy in policies
):
    raise SystemExit(f"{environment_name} branch policies are invalid")
policy_names = [policy["name"] for policy in policies]
if len(policy_names) != len(set(policy_names)):
    raise SystemExit(f"{environment_name} branch policies contain duplicates")
if posture_mode == "--production":
    if policy_names != ["main"]:
        raise SystemExit(f"{environment_name} must allow only the main branch for production")
else:
    expected = {"main", source_branch}
    if set(policy_names) != expected or len(policy_names) != len(expected):
        raise SystemExit(
            f"{environment_name} must allow exactly main and the selected "
            f"acceptance-candidate branch {source_branch}"
        )

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

printf '[verify-github-release-posture] ok: %s posture, protected environment, immutable releases, and tag ruleset verified for %s\n' \
  "$posture_mode" "$source_ref"
