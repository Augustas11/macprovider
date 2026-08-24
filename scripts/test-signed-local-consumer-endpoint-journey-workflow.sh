#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
workflow="$root/.github/workflows/promote-signed-local-consumer-endpoint-journey.yml"
builder="$root/scripts/build-local-consumer-endpoint-journey-result.py"
preflight="$root/scripts/preflight-signed-journey-promotion.py"

fail() {
  printf '[test-signed-local-consumer-endpoint-journey-workflow] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ -f "$workflow" && ! -L "$workflow" ]] || fail "workflow is absent or unsafe"
[[ -f "$builder" && ! -L "$builder" ]] || fail "builder is absent or unsafe"
[[ -f "$preflight" && ! -L "$preflight" ]] || fail "preflight is absent or unsafe"

python3 - "$workflow" "$builder" <<'PY'
import pathlib
import re
import sys

workflow = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
builder = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")

required_workflow = [
    "\n  workflow_dispatch:\n",
    "environment: production-release",
    "contents: read",
    "redacted_evidence_path",
    "requirement_ids",
    '[[ "$GITHUB_REF" == refs/heads/main ]]',
    '[[ "$PROMOTION_CONFIRMED_INPUT" == true ]]',
    '[[ "$main_sha" == "$GITHUB_SHA" ]]',
    'git cat-file -e "${SOURCE_SHA_INPUT}^{commit}"',
    'git merge-base --is-ancestor "$SOURCE_SHA_INPUT" "$GITHUB_SHA"',
    '[[ "$REQUIREMENT_IDS_INPUT" =~ ^SPEC-045-R00[1-8](,SPEC-045-R00[1-8])*$ ]]',
    "evidence_sha=%s",
    "requirement_slug=",
    "tr '[:upper:]' '[:lower:]'",
    "tr ',' '-'",
    'envelope="${REDACTED_EVIDENCE_INPUT%.redacted.json}.${requirement_slug}.journey-result.signed.json"',
    'payload="$RUNNER_TEMP/local-consumer-endpoint-journey-result-${requirement_slug}.unsigned.json"',
    "scripts/build-local-consumer-endpoint-journey-result.py",
    '--evidence-sha "$EVIDENCE_SHA"',
    "scripts/preflight-signed-journey-promotion.py",
    "Preflight selector freshness before signing",
    "--journey-id JOURNEY-LOCAL-CONSUMER-ENDPOINT",
    "scripts/verify-github-release-posture.sh",
    "GH_TOKEN: ${{ secrets.RELEASE_POSTURE_TOKEN }}",
    "MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM: ${{ secrets.MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM }}",
    "scripts/sign-journey-result.py",
    "scripts/promote-signed-journey-result.py",
    '--requirement-ids "$REQUIREMENT_IDS"',
    "scripts/check_spec_governance.py --base-ref origin/main",
    "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
    "retention-days: 1",
    "signed-local-consumer-endpoint-journey-promotion-${{ steps.request.outputs.source_sha }}-${{ steps.request.outputs.requirement_slug }}",
    "macprovider.signed-local-consumer-endpoint-journey-promotion.v1",
    "JOURNEY-LOCAL-CONSUMER-ENDPOINT",
]
for value in required_workflow:
    if value not in workflow:
        raise SystemExit(f"workflow contract is missing: {value}")

if "\n  push:" in workflow or "\n  pull_request:" in workflow:
    raise SystemExit("workflow must be manual dispatch only")
for forbidden in ("contents: write", "pull-requests: write", "git push", "gh pr create", "gh pr merge", "gh release"):
    if forbidden in workflow:
        raise SystemExit(f"workflow contains an unnecessary write/publication capability: {forbidden}")
if "cat \"$MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM\"" in workflow:
    raise SystemExit("workflow must not print private key material")
if re.search(r'echo .*MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM', workflow):
    raise SystemExit("workflow echoes the private key environment variable")
if "cp \"$REDACTED\"" not in workflow or "cp \"$ENVELOPE\"" not in workflow or "cp specs/CONFORMANCE.json" not in workflow:
    raise SystemExit("workflow must export only the redacted evidence, signed envelope, and ledger")
if "journey-result.unsigned.json" not in workflow:
    raise SystemExit("workflow must name the unsigned payload as non-committed runner-temp state")
if 'envelope="${REDACTED_EVIDENCE_INPUT%.redacted.json}.journey-result.signed.json"' in workflow:
    raise SystemExit("workflow must not reuse one signed envelope path for every SPEC-045 requirement subset")
if "pathlib.Path(\"journeys/evidence\").glob" not in workflow:
    raise SystemExit("workflow must check that non-promotable intermediates are absent")
posture_index = workflow.find("scripts/verify-github-release-posture.sh")
preflight_index = workflow.find("scripts/preflight-signed-journey-promotion.py")
signing_key_index = workflow.find("MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM")
if posture_index == -1 or signing_key_index == -1 or posture_index > signing_key_index:
    raise SystemExit("workflow must verify release posture before importing the acceptance signing key")
if preflight_index == -1 or signing_key_index == -1 or preflight_index > signing_key_index:
    raise SystemExit("workflow must reject stale selector evidence before importing the acceptance signing key")

def extract_step_blocks(text):
    blocks = []
    current = None
    for line in text.splitlines():
        match = re.match(r"^      - name: (.+)$", line)
        if match:
            if current is not None:
                blocks.append(current)
            current = {"name": match.group(1), "lines": [line]}
        elif current is not None:
            current["lines"].append(line)
    if current is not None:
        blocks.append(current)
    return blocks


steps = extract_step_blocks(workflow)
step_by_name = {step["name"]: step for step in steps}
step_names = [step["name"] for step in steps]
if len(step_by_name) != len(step_names):
    raise SystemExit("workflow step names must be unique for contract validation")
preflight_name = "Preflight selector freshness before signing"
posture_name = "Verify protected environment and repository posture"
sign_name = "Sign journey-result payload"
promote_name = "Promote only after signed validation"
for required_step_name in (preflight_name, posture_name, sign_name, promote_name):
    if required_step_name not in step_by_name:
        raise SystemExit(f"workflow step is missing: {required_step_name}")
preflight_step = "\n".join(step_by_name[preflight_name]["lines"])
posture_step = "\n".join(step_by_name[posture_name]["lines"])
sign_step = "\n".join(step_by_name[sign_name]["lines"])
promote_step = "\n".join(step_by_name[promote_name]["lines"])
if "for requirement_id in requirement_ids:" in promote_step:
    raise SystemExit("workflow must batch requirement promotion into one governance validation pass")
if step_names.index(preflight_name) > step_names.index(sign_name):
    raise SystemExit("preflight step must execute before the signing step")
if "MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM" in preflight_step:
    raise SystemExit("preflight step must not receive the acceptance signing key")
if "GH_TOKEN" in preflight_step:
    raise SystemExit("preflight step must not receive the release posture token")
if "MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM" not in sign_step:
    raise SystemExit("signing step must be the step that imports the acceptance signing key")
if "GH_TOKEN" not in posture_step:
    raise SystemExit("posture step must be the step that imports the release posture token")
secret_owners = {
    "MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM": [sign_name],
    "GH_TOKEN": [posture_name],
}
for secret_name, allowed_steps in secret_owners.items():
    for step in steps:
        if secret_name in "\n".join(step["lines"]) and step["name"] not in allowed_steps:
            raise SystemExit(f"{secret_name} appears in unexpected step: {step['name']}")
    first_step_index = workflow.find("\n      - name:")
    if first_step_index == -1 or secret_name in workflow[:first_step_index]:
        raise SystemExit(f"{secret_name} must not be declared before workflow steps")

lines = workflow.splitlines()
for index, line in enumerate(lines):
    match = re.match(r"^(\s*)run:\s*\|", line)
    if not match:
        continue
    indent = len(match.group(1))
    block = []
    for candidate in lines[index + 1 :]:
        if candidate.strip() and len(candidate) - len(candidate.lstrip()) <= indent:
            break
        block.append(candidate)
    if any("${{" in row for row in block):
        raise SystemExit("GitHub expression is interpolated directly into a shell block")

required_builder = [
    'JOURNEY_ID = "JOURNEY-LOCAL-CONSUMER-ENDPOINT"',
    'EVIDENCE_SCHEMA = "macprovider.local-consumer-endpoint-evidence.v1"',
    'ARTIFACT_ID = "redacted-local-consumer-endpoint"',
    "require_git_file_matches",
    "must be pending and mapped",
    "LOCAL_CONSUMER_ENDPOINT_STEP_ID_ORDER",
    "redaction.{key} must be true",
    "repository.commit must exactly match --source-sha",
    "redacted evidence source bytes must match --evidence-sha",
    "--source-sha must be an ancestor of --evidence-sha",
    "FORBIDDEN_KEY_FRAGMENTS",
    "FORBIDDEN_SECRET_VALUE_PATTERNS",
    "candidate_identity",
    "fake_gateway_used",
    "generated_local_token_used_as_api_key",
    "recovery_release_observed",
    "staging_or_production_gateway",
    "must be false",
    "must be true",
]
for value in required_builder:
    if value not in builder:
        raise SystemExit(f"builder contract is missing: {value}")
if "JOURNEY-BUYER-PAID-PATH" in builder or "BUYER_PAID_PATH" in builder:
    raise SystemExit("local-consumer endpoint builder must not reuse buyer-paid-path constants")

print("[test-signed-local-consumer-endpoint-journey-workflow] ok: protected local-consumer endpoint signer exports a short-lived promotion artifact")
PY
