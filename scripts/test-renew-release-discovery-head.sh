#!/usr/bin/env bash
# Fail-closed structural checks for protected discovery-head renewal.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
workflow="$root/.github/workflows/renew-release-discovery-head.yml"
bridge="$root/scripts/verify-v1855-discovery-bridge.sh"
[[ -f "$workflow" ]] || {
  printf '[test-renew-release-discovery-head] ERROR: missing renewal workflow\n' >&2
  exit 1
}
[[ -f "$bridge" ]] || {
  printf '[test-renew-release-discovery-head] ERROR: missing v1.8.55 bridge verifier\n' >&2
  exit 1
}

python3 - "$workflow" "$bridge" <<'PY'
import pathlib
import sys

workflow = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
bridge = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
for requirement in (
    "name: Renew signed release discovery head",
    "workflow_dispatch:",
    "concurrency:",
    "group: production-release",
    "cancel-in-progress: false",
    "environment: production-release",
    "scripts/verify-github-release-posture.sh",
    "MACPROVIDER_RELEASE_SIGNING_KEY_PEM",
    "scripts/build-release-discovery-head.py",
    "scripts/verify-release-discovery-transport.py",
    "--minimum-sequence",
    "--allow-expired",
    "--require-immutable",
    'git ls-remote --tags origin "$TRANSPORT_TAG"',
    "--prerelease",
    "--latest=false",
    "scripts/verify-anonymous-release-discovery.sh",
    "Verify renewed discovery without protected credentials",
):
    if requirement not in workflow:
        raise SystemExit(f"renewal workflow omits: {requirement}")
if "--clobber" in workflow:
    raise SystemExit("renewal workflow must never overwrite discovery assets")
publish = workflow.split("- name: Publish one append-only immutable renewal transport", 1)[1]
if 'gh release create "release-discovery"' in publish or "gh release upload" in publish:
    raise SystemExit("renewal must not publish to the fixed release-discovery tag")
if "gh release create \"$TRANSPORT_TAG\"" not in publish:
    raise SystemExit("renewal must create an append-only transport tag")
top_level, _, rest = workflow.partition("\njobs:\n")
if "contents: write" in top_level:
    raise SystemExit("top-level renewal permissions must remain read-only")
if "contents: write" not in rest.split("verify_public:", 1)[0]:
    raise SystemExit("protected renewal job must request contents: write")
public = workflow.split("Verify renewed discovery without protected credentials", 1)[1]
if "MACPROVIDER_RELEASE_SIGNING_KEY_PEM" in public or "RELEASE_POSTURE_TOKEN" in public:
    raise SystemExit("anonymous renewal verifier must not receive protected secrets")
sign = workflow.split("- name: Sign a strictly greater renewal discovery head", 1)[1].split(
    "- name: Publish one append-only immutable renewal transport", 1
)[0]
for requirement in (
    "VALIDITY_HOURS",
    "timedelta(hours=hours)",
    '--issued-at "$issued_at"',
    '--expires-at "$expires_at"',
):
    if requirement not in sign:
        raise SystemExit(f"renewal signing omits non-24h validity wiring: {requirement}")
for requirement in (
    "fixed release-discovery remains immutable",
    "cannot discover vNext through ordinary update --check",
    "verify-anonymous-release-discovery.sh",
    "target discovery head identity differs from the numeric release",
    "v1.8.55 ordinary discovery must not observe append-only",
    "verify-release-discovery-transport.py",
    "target $name is absent from signed checksums",
    "--allow-expired",
):
    if requirement not in bridge:
        raise SystemExit(f"v1.8.55 bridge verifier omits: {requirement}")
if "--clobber" in bridge or "gh release upload" in bridge:
    raise SystemExit("bridge verifier must not mutate releases")
if "/releases/latest" in bridge:
    raise SystemExit("bridge verifier must not treat unsigned latest as authority")
numeric_proof = bridge.split('target_base="https://github.com/$repository/releases/download/$target_tag"', 1)[1]
if "verify-release-discovery-transport.py" not in numeric_proof:
    raise SystemExit("numeric release proof must verify the signed discovery head before trusting JSON")
if "target-checksums.txt" not in numeric_proof or "macprovider-release-discovery.json" not in numeric_proof:
    raise SystemExit("numeric release proof must bind discovery assets to signed checksums")
PY

# Workflow YAML is not a shell script; do not bash -n it (Linux rejects indented <<'PY' terminators).
bash -n "$bridge"
if command -v shellcheck >/dev/null; then
  shellcheck -x "$bridge"
fi

printf '[test-renew-release-discovery-head] ok: protected renewal workflow fails closed\n'
