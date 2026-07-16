#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$root/.github/workflows/malibu-release.yml"

python3 - "$workflow" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")

required = (
    "workflow_dispatch:",
    "operation:",
    "physical_acceptance_confirmed:",
    "environment: production-release",
    "CLI_TAG: v1.8.40",
    "CLI_VERSION: 1.8.40",
    "CLI_SHA256: 4392cfff14abc7c4ee4e8992e2f264b465f754594397bfd4f92d5859f4d77ff1",
    "CLI_ARCHIVE_SHA256: 1eee4900109f958c95c66830f17295bfba4dfe93e0a72aa720f0ed20a9b2b918",
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
if "actions/upload-artifact@v" in text or "actions/download-artifact@v" in text:
    raise SystemExit("artifact actions must remain commit-pinned")

print("independent Malibu release workflow regression checks passed")
PY
