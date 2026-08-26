#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
workflow="$root/.github/workflows/build-signed-pool-promotion-transition.yml"
register="$root/scripts/register-spec043-production-release-key.py"
builder="$root/scripts/build-pool-promotion-transition.py"
signer="$root/scripts/sign-pool-promotion-transition.py"
validator="$root/scripts/validate-pool-promotion-transition.py"

fail() {
  printf '[test-signed-pool-promotion-transition-workflow] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ -f "$workflow" && ! -L "$workflow" ]] || fail "workflow is absent or unsafe"
[[ -f "$register" && ! -L "$register" ]] || fail "register script is absent or unsafe"
[[ -f "$builder" && ! -L "$builder" ]] || fail "builder is absent or unsafe"
[[ -f "$signer" && ! -L "$signer" ]] || fail "signer is absent or unsafe"
[[ -f "$validator" && ! -L "$validator" ]] || fail "validator is absent or unsafe"

python3 - "$workflow" "$register" "$builder" "$signer" "$root/security/spec-043-production-release-keyring.json" "$root/scripts/pool_promotion_transition.py" <<'PY'
import json
import pathlib
import re
import sys

workflow = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
register = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
builder = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
signer = pathlib.Path(sys.argv[4]).read_text(encoding="utf-8")
keyring = json.loads(pathlib.Path(sys.argv[5]).read_text(encoding="utf-8"))
library = pathlib.Path(sys.argv[6]).read_text(encoding="utf-8")

required_workflow = [
    "\n  workflow_dispatch:\n",
    "environment: production-release",
    "contents: read",
    "signed_candidate_path",
    "promotion_confirmed",
    '[[ "$GITHUB_REF" == refs/heads/main ]]',
    '[[ "$PROMOTION_CONFIRMED_INPUT" == true ]]',
    '[[ "$main_sha" == "$GITHUB_SHA" ]]',
    "scripts/register-spec043-production-release-key.py --check",
    "scripts/build-pool-promotion-transition.py",
    "scripts/verify-github-release-posture.sh",
    "GH_TOKEN: ${{ secrets.RELEASE_POSTURE_TOKEN }}",
    "MACPROVIDER_SPEC043_PRODUCTION_RELEASE_SIGNING_KEY_PEM: ${{ secrets.MACPROVIDER_SPEC043_PRODUCTION_RELEASE_SIGNING_KEY_PEM }}",
    "scripts/sign-pool-promotion-transition.py",
    "scripts/validate-pool-promotion-transition.py",
    "scripts/check_spec_governance.py --base-ref origin/main",
    "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
    "retention-days: 1",
    "signed-pool-promotion-transition-${{ steps.request.outputs.short_sha }}",
    "macprovider.signed-pool-promotion-transition.v1",
    "JOURNEY-TRUSTED-POOL-CREATOR-MVP",
]
for value in required_workflow:
    if value not in workflow:
        raise SystemExit(f"workflow contract is missing: {value}")

if "\n  push:" in workflow or "\n  pull_request:" in workflow:
    raise SystemExit("workflow must be manual dispatch only")
for forbidden in (
    "contents: write",
    "pull-requests: write",
    "git push",
    "gh pr create",
    "gh pr merge",
    "gh release",
    "scripts/promote-signed-journey-result.py",
    "--consume",
):
    if forbidden in workflow:
        raise SystemExit(f"workflow contains an unnecessary write/publication capability: {forbidden}")
if "MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM" in workflow:
    raise SystemExit("production-release sibling must not use the acceptance candidate signing key")
if "cat \"$MACPROVIDER_SPEC043_PRODUCTION_RELEASE_SIGNING_KEY_PEM\"" in workflow:
    raise SystemExit("workflow must not print private key material")
if re.search(r"echo .*MACPROVIDER_SPEC043_PRODUCTION_RELEASE_SIGNING_KEY_PEM", workflow):
    raise SystemExit("workflow echoes the private key environment variable")
if "cp specs/CONFORMANCE.json" in workflow:
    raise SystemExit("workflow must not export a promoted conformance ledger")
if "state\") != \"conformant\"" in workflow or "was not promoted to conformant" in workflow:
    raise SystemExit("workflow must not assert or perform conformance promotion")

check_index = workflow.find("scripts/register-spec043-production-release-key.py --check")
posture_index = workflow.find("scripts/verify-github-release-posture.sh")
signing_key_index = workflow.find("MACPROVIDER_SPEC043_PRODUCTION_RELEASE_SIGNING_KEY_PEM")
if check_index == -1 or signing_key_index == -1 or check_index > signing_key_index:
    raise SystemExit("workflow must fail closed on an empty keyring before importing the production-release signing key")
if posture_index == -1 or signing_key_index == -1 or posture_index > signing_key_index:
    raise SystemExit("workflow must verify release posture before importing the production-release signing key")

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
check_name = "Validate exact main source and fail-closed keyring"
posture_name = "Verify protected environment and repository posture"
sign_name = "Sign PoolPromotionTransitionV1 payload"
validate_name = "Validate signed sibling without ledger consume or conformance promotion"
for required_step_name in (check_name, posture_name, sign_name, validate_name):
    if required_step_name not in step_by_name:
        raise SystemExit(f"workflow step is missing: {required_step_name}")
check_step = "\n".join(step_by_name[check_name]["lines"])
posture_step = "\n".join(step_by_name[posture_name]["lines"])
sign_step = "\n".join(step_by_name[sign_name]["lines"])
validate_step = "\n".join(step_by_name[validate_name]["lines"])
if step_names.index(check_name) > step_names.index(sign_name):
    raise SystemExit("empty-keyring check must execute before the signing step")
if "MACPROVIDER_SPEC043_PRODUCTION_RELEASE_SIGNING_KEY_PEM" in check_step:
    raise SystemExit("keyring preflight must not receive the production-release signing key")
if "GH_TOKEN" in check_step:
    raise SystemExit("keyring preflight must not receive the release posture token")
if "--check" not in check_step:
    raise SystemExit("first step must fail closed unless a production-release key is registered")
if "MACPROVIDER_SPEC043_PRODUCTION_RELEASE_SIGNING_KEY_PEM" not in sign_step:
    raise SystemExit("signing step must be the step that imports the production-release signing key")
if "--consume" in validate_step:
    raise SystemExit("validator step must not consume the promotion ledger")
secret_owners = {
    "MACPROVIDER_SPEC043_PRODUCTION_RELEASE_SIGNING_KEY_PEM": [sign_name],
    "GH_TOKEN": [posture_name],
}
for secret_name, allowed_steps in secret_owners.items():
    for step in steps:
        if secret_name in "\n".join(step["lines"]) and step["name"] not in allowed_steps:
            raise SystemExit(f"{secret_name} appears in unexpected step: {step['name']}")
    first_step_index = workflow.find("\n      - name:")
    if first_step_index == -1 or secret_name in workflow[:first_step_index]:
        raise SystemExit(f"{secret_name} must not be declared before workflow steps")

for index, line in enumerate(workflow.splitlines()):
    match = re.match(r"^(\s*)run:\s*\|", line)
    if not match:
        continue
    indent = len(match.group(1))
    block = []
    for candidate in workflow.splitlines()[index + 1 :]:
        if candidate.strip() and len(candidate) - len(candidate.lstrip()) <= indent:
            break
        block.append(candidate)
    if any("${{" in row for row in block):
        raise SystemExit("GitHub expression is interpolated directly into a shell block")

if "never generates a key" not in register or "--check" not in register:
    raise SystemExit("register script must preflight without generating a key")
if "openssl genpkey" in register or "genpkey" in register:
    raise SystemExit("register script must not generate a production-release key")
if "specs/CONFORMANCE.json" in builder:
    raise SystemExit("builder must not mention CONFORMANCE mutation")
if "RUNNER_TEMP" not in builder:
    raise SystemExit("builder must allow GitHub RUNNER_TEMP unsigned intermediates")
if "never consumes the promotion ledger" not in signer:
    raise SystemExit("signer must refuse ledger consume")
if "MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM" in signer:
    raise SystemExit("sibling signer must not default to the acceptance key")
if "public_keys_match" not in signer:
    raise SystemExit("sibling signer must compare registered and derived keys by SPKI identity")
if "must not reuse the acceptance candidate signing key" not in library:
    raise SystemExit("production-release registration must reject the acceptance candidate public key")
keys = keyring.get("keys")
if not isinstance(keys, list) or len(keys) != 1:
    raise SystemExit("committed production-release keyring must contain exactly one registered key")
if keys[0].get("key_id") != "macprovider-spec043-production-release-p256-v1":
    raise SystemExit("registered production-release key_id is wrong")
if keys[0].get("public_key_path") != "security/spec-043-production-release-p256-v1.pem":
    raise SystemExit("registered production-release public_key_path is wrong")
public_key = pathlib.Path(sys.argv[5]).resolve().parent.parent / "security" / "spec-043-production-release-p256-v1.pem"
if not public_key.is_file() or public_key.is_symlink():
    raise SystemExit("registered production-release public key is absent or unsafe")
public_pem = public_key.read_text(encoding="utf-8")
if "BEGIN PRIVATE KEY" in public_pem or "BEGIN PUBLIC KEY" not in public_pem:
    raise SystemExit("committed production-release key must be a public PEM")
acceptance = (public_key.parent / "acceptance-candidate-signing-public.pem").read_text(encoding="utf-8")
if public_pem == acceptance:
    raise SystemExit("production-release public key must not reuse the acceptance candidate key")

print("[test-signed-pool-promotion-transition-workflow] ok: protected sibling signer stays fail-closed without CONFORMANCE promotion")
PY
