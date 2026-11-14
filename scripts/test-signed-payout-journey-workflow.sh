#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
workflow="$root/.github/workflows/signed-journey.yml"

fail() {
  printf '[test-signed-payout-journey-workflow] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ -f "$workflow" && ! -L "$workflow" ]] || fail "workflow is absent or unsafe"

python3 - "$workflow" <<'PY'
import pathlib
import re
import sys

workflow = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
full_workflow = workflow

def _signed_job_slice(text, job_id):
    marker = "\n  %s:\n" % job_id
    start = text.find(marker)
    if start < 0:
        raise SystemExit("missing job %s" % job_id)
    rest = text[start + 1 :]
    nxt = re.search(r"\n  [A-Za-z0-9_]+:\n", rest)
    end = (start + 1 + nxt.start()) if nxt else len(text)
    return text[start:end]

_header_at = full_workflow.find("\njobs:\n")
if _header_at < 0:
    raise SystemExit("missing jobs")
_parts = [full_workflow[: _header_at + len("\njobs:\n")]]
for _job_id in ('payout',):
    _parts.append(_signed_job_slice(full_workflow, _job_id))
_root = pathlib.Path(sys.argv[1]).resolve().parents[2]
for _rel in ():
    _parts.append((_root / _rel).read_text(encoding="utf-8"))
workflow = "\n".join(_parts)

required = [
    "\n  workflow_dispatch:\n",
    "environment: production-release",
    "contents: read",
    "GH_TOKEN: ${{ secrets.RELEASE_POSTURE_TOKEN }}",
    'scripts/verify-github-release-posture.sh "$GITHUB_REPOSITORY" production-release 28995904',
    "MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM: ${{ secrets.MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM }}",
    '[[ "$GITHUB_REF" == refs/heads/main ]]',
    '[[ "$SOURCE_SHA_INPUT" == "$GITHUB_SHA" ]]',
    '[[ "$PROMOTION_CONFIRMED_INPUT" == true ]]',
    '[[ "$main_sha" == "$SOURCE_SHA_INPUT" ]]',
    "MACPROVIDER_CAPTURE_PAYOUT_JOURNEY=1",
    "scripts/sign-journey-result.py",
    "scripts/promote-signed-journey-result.py",
    "scripts/check_spec_governance.py --base-ref origin/main",
    "actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9",
    "retention-days: 1",
    "macprovider.signed-payout-journey-promotion.v1",
]
for value in required:
    if value not in workflow:
        raise SystemExit(f"workflow contract is missing: {value}")

if "\n  push:" in full_workflow or "\n  pull_request:" in full_workflow:
    raise SystemExit("workflow must be manual dispatch only")
if "git push origin main" in full_workflow or "HEAD:refs/heads/main" in full_workflow:
    raise SystemExit("workflow must not push directly to main")
for forbidden in ("contents: write", "pull-requests: write", "git push", "gh pr create", "gh pr merge", "gh release"):
    if forbidden in full_workflow:
        raise SystemExit(f"workflow contains an unnecessary write/publication capability: {forbidden}")
if "cat \"$MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM\"" in workflow:
    raise SystemExit("workflow must not print private key material")
if re.search(r'echo .*MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM', workflow):
    raise SystemExit("workflow echoes the private key environment variable")
if "cp \"$REDACTED\"" not in workflow or "cp \"$ENVELOPE\"" not in workflow or "cp specs/CONFORMANCE.json" not in workflow:
    raise SystemExit("workflow must export only the signed evidence, redacted artifact, and ledger")
if "candidate.json" not in workflow or "journey-result.unsigned.json" not in workflow:
    raise SystemExit("workflow must explicitly detect non-promotable intermediates")
if "path.unlink()" not in workflow:
    raise SystemExit("workflow must remove non-promotable intermediates before artifact export")
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

print("[test-signed-payout-journey-workflow] ok: protected manual signer exports a short-lived artifact")
PY
