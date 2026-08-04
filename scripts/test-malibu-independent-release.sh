#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$root/.github/workflows/malibu-release.yml"

python3 - "$workflow" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")

required = (
    "workflow_dispatch:",
    "operation:",
    "physical_acceptance_confirmed:",
    "environment: production-release",
    "CLI_TAG: ${{ inputs.cli_tag }}",
    "CLI_VERSION: ${{ inputs.cli_version }}",
    "CLI_SHA256: ${{ inputs.cli_sha256 }}",
    "CLI_ARCHIVE_SHA256: ${{ inputs.cli_archive_sha256 }}",
    "scripts/validate-malibu-release-cli-inputs.sh",
    '"cli_tag": os.environ["CLI_TAG"]',
    '"cli_version": os.environ["CLI_VERSION"]',
    '"cli_sha256": os.environ["CLI_SHA256"]',
    '"cli_archive_sha256": os.environ["CLI_ARCHIVE_SHA256"]',
    "codesign --verify --strict --verbose=2",
    "scripts/notarytool-submit-with-retry.sh",
    "xcrun stapler staple",
    "xcrun stapler validate",
    "scripts/verify-malibu-release-artifacts.sh",
    'actions/runs/$CANDIDATE_RUN_ID',
    '"workflow_id": workflow["id"]',
    '"path": ".github/workflows/malibu-release.yml"',
    '"event": "workflow_dispatch"',
    '"head_branch": "main"',
    '"conclusion": "success"',
    '"candidate_run_attempt": int(run_attempt)',
    "run-id: ${{ inputs.candidate_run_id }}",
    "test \"$PHYSICAL_ACCEPTANCE_CONFIRMED\" = true",
    "test \"$actual_sha\" = \"$EXPECTED_DMG_SHA256\"",
    "-name '*.bundle'",
    '"$app/Contents/MacOS/mlx.metallib"',
    "Print :CFBundleIdentifier",
    "Print :CFBundleVersion",
    "stat -f '%Lp'",
    'identifier \\"tech.malibu.app\\"',
    'identifier \\"live.streamvc.macprovider.cli\\"',
    'git merge-base --is-ancestor "$SOURCE_COMMIT" refs/remotes/origin/main',
    'final-draft-cli.json',
    'immutable-release-by-id.json',
    'immutable-release-by-tag.json',
    'release.get("immutable") is not True',
    'asset.get("digest") != expected_digests',
    "--latest=false",
    "-F draft=false -F prerelease=false -f make_latest=false",
)
for item in required:
    if item not in text:
        raise SystemExit(f"independent Malibu release workflow is missing: {item}")

dispatch_inputs = text.split("\n    inputs:\n", 1)[1].split("\npermissions:\n", 1)[0]
for input_name in ("cli_tag", "cli_version", "cli_sha256", "cli_archive_sha256"):
    matches = re.findall(
        rf"^      {re.escape(input_name)}:\n((?:        .*\n)+)",
        dispatch_inputs,
        flags=re.MULTILINE,
    )
    if len(matches) != 1:
        raise SystemExit(f"release workflow must declare exactly one {input_name} input")
    block = matches[0]
    if "required: true" not in block:
        raise SystemExit(f"release workflow input must fail closed when omitted: {input_name}")

build = text.split("\n  build_candidate:\n", 1)[1].split("\n  sign_candidate:\n", 1)[0]
sign = text.split("\n  sign_candidate:\n", 1)[1].split("\n  publish:\n", 1)[0]
publish = text.split("\n  publish:\n", 1)[1]

if "secrets." in build or "contents: write" in build:
    raise SystemExit("unprotected Malibu build job has secrets or write permission")
if "contents: write" in sign:
    raise SystemExit("candidate signer must not have release publication permission")
if "contents: write" not in publish:
    raise SystemExit("publication job lacks explicit release permission")
for forbidden in ("swift build", "package.sh", "codesign --force --deep", "git push"):
    if forbidden in text:
        raise SystemExit(f"independent Malibu workflow contains forbidden operation: {forbidden}")
for forbidden in ("xcodebuild", "codesign --force", "notarytool-submit-with-retry"):
    if forbidden in publish:
        raise SystemExit(f"publication must reuse candidate bytes, not run: {forbidden}")
if sign.count('test "$(shasum -a 256 "$embedded_cli"') != 2:
    raise SystemExit("candidate signer must prove embedded CLI bytes before and after app signing")
if publish.find("Reverify exact accepted bytes") > publish.find("Create and verify draft Malibu release"):
    raise SystemExit("candidate verification must precede draft creation")
if publish.find("Create and verify draft Malibu release") > publish.find("Publish only the revalidated draft"):
    raise SystemExit("draft verification must precede publication")
if 'test "$GITHUB_SHA" = "$SOURCE_COMMIT"' in publish:
    raise SystemExit("publication must not require main to remain frozen at the candidate commit")
if 'test "$(git rev-parse refs/remotes/origin/main)" = "$SOURCE_COMMIT"' in publish:
    raise SystemExit("publication must accept a tagged candidate still reachable from an advanced main")
if publish.count('cmp -s "$candidate/$asset"') != 2:
    raise SystemExit("draft and public sidecar bytes must match the accepted candidate")
make_public = publish.split("- name: Publish only the revalidated draft", 1)[1]
patch_position = make_public.find("gh api --method PATCH")
if patch_position < 0:
    raise SystemExit("verified Malibu draft must be made public by numeric-ID PATCH")
if 'releases/tags/$tag' in make_public[:patch_position]:
    raise SystemExit("REST tag lookup cannot discover the Malibu draft release")
if "actions/upload-artifact@v" in text or "actions/download-artifact@v" in text:
    raise SystemExit("artifact actions must remain commit-pinned")
if "CLI_TAG: v1.8.40" in text or "CLI_VERSION: 1.8.40" in text:
    raise SystemExit("independent Malibu release workflow must not pin an old CLI release")
if '"cli_version": "1.8.40"' in text:
    raise SystemExit("candidate publication must validate the dispatched CLI version")
if text.count("scripts/validate-malibu-release-cli-inputs.sh") != 2:
    raise SystemExit("candidate and publication paths must both validate exact CLI inputs")
for policy in (
    "--allow-previous-stable=1.8.81",
    "--staged-candidate=1.8.82",
):
    if text.count(policy) != 2:
        raise SystemExit(f"candidate and publication paths must bind staged coordinator policy: {policy}")
if "Malibu/CLI marketing-version equality is required" in text:
    raise SystemExit("Malibu release workflow must not couple app and CLI marketing versions")

print("independent Malibu release workflow regression checks passed")
PY

validator="$root/scripts/validate-malibu-release-cli-inputs.sh"
valid_sha="$(printf 'a%.0s' {1..64})"
valid_archive_sha="$(printf 'b%.0s' {1..64})"
valid_cli_version="$(
  sed -nE 's/^[[:space:]]*static let binaryVersion = "([^"]+)".*$/\1/p' \
    "$root/phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift"
)"
valid_cli_tag="v$valid_cli_version"
staged_coordinator_policy="--allow-previous-stable=1.8.81"
staged_candidate_policy="--staged-candidate=1.8.82"

"$validator" "$valid_cli_tag" "$valid_cli_version" "$valid_sha" "$valid_archive_sha" \
  "$staged_coordinator_policy" "$staged_candidate_policy" >/dev/null

expect_failure() {
  if "$validator" "$@" "$staged_coordinator_policy" "$staged_candidate_policy" >/dev/null 2>&1; then
    echo "Malibu release CLI input validation unexpectedly succeeded: $*" >&2
    exit 1
  fi
}

expect_failure "$valid_cli_version" "$valid_cli_version" "$valid_sha" "$valid_archive_sha"
expect_failure v0.0.1 "$valid_cli_version" "$valid_sha" "$valid_archive_sha"
expect_failure "$valid_cli_tag" 0.0.1 "$valid_sha" "$valid_archive_sha"
expect_failure "$valid_cli_tag" "$valid_cli_version" "$(printf 'A%.0s' {1..64})" "$valid_archive_sha"
expect_failure "$valid_cli_tag" "$valid_cli_version" "${valid_sha%?}" "$valid_archive_sha"
expect_failure "$valid_cli_tag" "$valid_cli_version" "$valid_sha" "${valid_archive_sha}0"

echo "independent Malibu release CLI input validation checks passed"
