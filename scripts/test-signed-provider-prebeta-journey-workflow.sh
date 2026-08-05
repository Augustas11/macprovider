#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
workflow="$root/.github/workflows/promote-signed-provider-prebeta-journey.yml"
builder="$root/scripts/build-provider-prebeta-journey-result.py"

fail() {
  printf '[test-signed-provider-prebeta-journey-workflow] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ -f "$workflow" && ! -L "$workflow" ]] || fail "workflow is absent or unsafe"
[[ -f "$builder" && ! -L "$builder" ]] || fail "builder is absent or unsafe"

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
    "evidence_sha=%s",
    "scripts/build-provider-prebeta-journey-result.py",
    '--evidence-sha "$EVIDENCE_SHA"',
    "scripts/verify-github-release-posture.sh",
    "GH_TOKEN: ${{ secrets.RELEASE_POSTURE_TOKEN }}",
    "MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM: ${{ secrets.MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM }}",
    "scripts/sign-journey-result.py",
    "scripts/promote-signed-journey-result.py",
    "scripts/check_spec_governance.py --base-ref origin/main",
    "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
    "retention-days: 1",
    "macprovider.signed-provider-prebeta-journey-promotion.v1",
    "JOURNEY-PROVIDER-PREBETA-ADMISSION",
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
if "pathlib.Path(\"journeys/evidence\").glob" not in workflow:
    raise SystemExit("workflow must check that non-promotable intermediates are absent")
posture_index = workflow.find("scripts/verify-github-release-posture.sh")
signing_key_index = workflow.find("MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM")
if posture_index == -1 or signing_key_index == -1 or posture_index > signing_key_index:
    raise SystemExit("workflow must verify release posture before importing the acceptance signing key")

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
    'JOURNEY_ID = "JOURNEY-PROVIDER-PREBETA-ADMISSION"',
    'EVIDENCE_SCHEMA = "macprovider.provider-prebeta-admission-evidence.v1"',
    'ARTIFACT_ID = "redacted-provider-prebeta-admission"',
    "require_git_file_matches",
    "must be pending and mapped",
    "step-07-buyer-serving-smoke",
    "redaction.{key} must be true",
    "repository.commit must exactly match --source-sha",
    "redacted evidence source bytes must match --evidence-sha",
    "--source-sha must be an ancestor of --evidence-sha",
    "FORBIDDEN_KEY_FRAGMENTS",
]
for value in required_builder:
    if value not in builder:
        raise SystemExit(f"builder contract is missing: {value}")

print("[test-signed-provider-prebeta-journey-workflow] ok: protected provider-prebeta signer exports a short-lived artifact")
PY
