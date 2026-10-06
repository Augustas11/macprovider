#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
workflow="$root/.github/workflows/promote-signed-privacy-class-beta-journey.yml"
builder="$root/scripts/build-privacy-class-beta-journey-result.py"
contract="$root/scripts/privacy_class_beta_journey_evidence.py"
preflight="$root/scripts/preflight-signed-journey-promotion.py"
validator="$root/scripts/validate-signed-journey-result.py"

fail() {
  printf '[test-signed-privacy-class-beta-journey-workflow] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ -f "$workflow" && ! -L "$workflow" ]] || fail "workflow is absent or unsafe"
[[ -f "$builder" && ! -L "$builder" ]] || fail "builder is absent or unsafe"
[[ -f "$contract" && ! -L "$contract" ]] || fail "evidence contract is absent or unsafe"
[[ -f "$preflight" && ! -L "$preflight" ]] || fail "preflight is absent or unsafe"
[[ -f "$validator" && ! -L "$validator" ]] || fail "validator is absent or unsafe"

python3 - "$workflow" "$builder" "$contract" <<'PY'
import pathlib
import re
import sys

workflow = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
builder = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
contract = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")

required_workflow = [
    "\n  workflow_dispatch:\n",
    "environment: production-release",
    "contents: read",
    "redacted_evidence_path",
    '[[ "$GITHUB_REF" == refs/heads/main ]]',
    '[[ "$EVIDENCE_CONFIRMED_INPUT" == true ]]',
    '[[ "$main_sha" == "$GITHUB_SHA" ]]',
    'git cat-file -e "${SOURCE_SHA_INPUT}^{commit}"',
    'git merge-base --is-ancestor "$SOURCE_SHA_INPUT" "$GITHUB_SHA"',
    r"^journeys/evidence/privacy-class-beta-[0-9]{8}T[0-9]{6}Z\.redacted\.json$",
    'bundle="${REDACTED_EVIDENCE_INPUT%.redacted.json}"',
    "evidence_sha=%s",
    'envelope="${REDACTED_EVIDENCE_INPUT%.redacted.json}.journey-result.signed.json"',
    'payload="$RUNNER_TEMP/privacy-class-beta-journey-result.unsigned.json"',
    "scripts/build-privacy-class-beta-journey-result.py",
    '--evidence-sha "$EVIDENCE_SHA"',
    "scripts/preflight-signed-journey-promotion.py",
    "Preflight selector freshness before signing",
    "--journey-id JOURNEY-PRIVACY-CLASS-BETA",
    "scripts/verify-github-release-posture.sh",
    "GH_TOKEN: ${{ secrets.RELEASE_POSTURE_TOKEN }}",
    "MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM: ${{ secrets.MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM }}",
    "scripts/sign-journey-result.py",
    "scripts/validate-signed-journey-result.py",
    "scripts/check_spec_governance.py --base-ref origin/main",
    "git diff --quiet -- specs/CONFORMANCE.json",
    "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
    "retention-days: 1",
    "signed-privacy-class-beta-journey-evidence-${{ steps.request.outputs.source_sha }}",
    "macprovider.signed-privacy-class-beta-journey-evidence.v1",
    "JOURNEY-PRIVACY-CLASS-BETA",
    "SPEC-049-R023",
]
for value in required_workflow:
    if value not in workflow:
        raise SystemExit(f"workflow contract is missing: {value}")

if "\n  push:" in workflow or "\n  pull_request:" in workflow or "\n  schedule:" in workflow:
    raise SystemExit("workflow must be manual dispatch only")
for forbidden in ("contents: write", "pull-requests: write", "git push", "gh pr create", "gh pr merge", "gh release", "scripts/promote-signed-journey-result.py"):
    if forbidden in workflow:
        raise SystemExit(f"workflow contains an unnecessary write/publication capability: {forbidden}")
if "requirement_ids:\n" in workflow.split("jobs:", 1)[0]:
    raise SystemExit("requirement IDs are derived from the evidence contract, not a dispatch input")
if "cat \"$MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM\"" in workflow:
    raise SystemExit("workflow must not print private key material")
if re.search(r'echo .*MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM', workflow):
    raise SystemExit("workflow echoes the private key environment variable")
if "cp \"$REDACTED\"" not in workflow or "cp \"$ENVELOPE\"" not in workflow:
    raise SystemExit("workflow must export the redacted evidence and signed envelope")
if "cp specs/CONFORMANCE.json" in workflow:
    raise SystemExit("workflow must not export a promoted conformance ledger")
if "pathlib.Path(\"journeys/evidence\").glob" not in workflow:
    raise SystemExit("workflow must check that non-committed intermediates are absent")
if "state\") != \"conformant\"" in workflow or "was not promoted to conformant" in workflow:
    raise SystemExit("workflow must not assert or perform conformance promotion")
posture_index = workflow.find("scripts/verify-github-release-posture.sh")
preflight_index = workflow.find("scripts/preflight-signed-journey-promotion.py")
builder_index = workflow.find("scripts/build-privacy-class-beta-journey-result.py")
signing_key_index = workflow.find("MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM")
if posture_index == -1 or signing_key_index == -1 or posture_index > signing_key_index:
    raise SystemExit("workflow must verify release posture before importing the acceptance signing key")
if preflight_index == -1 or preflight_index > signing_key_index:
    raise SystemExit("workflow must reject stale selector evidence before importing the acceptance signing key")
if builder_index == -1 or builder_index > signing_key_index:
    raise SystemExit("workflow must validate the evidence and bundle before importing the acceptance signing key")


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
for required_step_name in (preflight_name, posture_name, sign_name):
    if required_step_name not in step_by_name:
        raise SystemExit(f"workflow step is missing: {required_step_name}")
if step_names.index(preflight_name) > step_names.index(sign_name):
    raise SystemExit("preflight step must execute before the signing step")
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
    "import privacy_class_beta_journey_evidence as contract",
    "compose-evidence",
    "contract.build_payload",
    "--source-sha",
    "--evidence-sha",
]
for value in required_builder:
    if value not in builder:
        raise SystemExit(f"builder contract is missing: {value}")
required_contract = [
    'JOURNEY_ID = "JOURNEY-PRIVACY-CLASS-BETA"',
    'EVIDENCE_SCHEMA = "macprovider.privacy-class-beta-evidence.v1"',
    "MAX_EVIDENCE_LIFETIME = timedelta(days=90)",
    'EXCLUDED_REQUIREMENT_IDS = frozenset({"SPEC-049-R023", "SPEC-022-R014", "SPEC-015-R007", "SPEC-001-R005"})',
    "def journey_requirement_ids",
    "def load_bundle",
    "def assert_bundle_redacted",
    "def recompute",
    "def validate_evidence",
    "def validate_signed_payload",
    "redacted evidence source bytes must match --evidence-sha",
    "reviewed bundle file must match --evidence-sha",
    "--source-sha must be an ancestor of --evidence-sha",
    "observation {name} disagrees with the bundle",
]
for value in required_contract:
    if value not in contract:
        raise SystemExit(f"evidence contract is missing: {value}")
for forbidden in ("PRIVATE KEY-----\\n", "MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM", "openssl"):
    if forbidden in builder or forbidden in contract:
        raise SystemExit(f"builder and contract must never touch signing material: {forbidden}")

print("[test-signed-privacy-class-beta-journey-workflow] ok: protected privacy-class beta signer exports a short-lived non-promoting artifact")
PY
