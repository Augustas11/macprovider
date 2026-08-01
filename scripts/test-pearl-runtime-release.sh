#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
guard="$repo_root/scripts/verify-pearl-runtime-release.sh"
runtime_workflow="$repo_root/.github/workflows/pearl-runtime-release.yml"
work="$(mktemp -d "${TMPDIR:-/tmp}/pearl-runtime-release-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

bash -n "$guard"
python3 - "$runtime_workflow" <<'PY'
import pathlib
import sys

workflow = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
if workflow.count("scripts/verify-github-release-posture.sh") < 3:
    raise SystemExit("runtime workflow must verify protected posture before signing, draft, and publish")
before_sign = workflow.split("- name: Sign Pearl runtime metadata and checksums", 1)[0]
if "Verify protected GitHub release posture before runtime signing" not in before_sign:
    raise SystemExit("runtime workflow must verify protected posture before importing signing key")
create = workflow.split("- name: Create verified draft GitHub release", 1)[1].split(
    "- name: Publish only the revalidated numeric draft", 1
)[0]
if "RELEASE_POSTURE_TOKEN" not in create or "verify-github-release-posture.sh" not in create:
    raise SystemExit("runtime workflow must recheck protected posture before draft creation")
publish = workflow.split("- name: Publish only the revalidated numeric draft", 1)[1]
if "RELEASE_POSTURE_TOKEN" not in publish or "verify-github-release-posture.sh" not in publish:
    raise SystemExit("runtime workflow must recheck protected posture immediately before publication")
if "make_latest=true" in publish or "true|false) make_latest=false" not in publish:
    raise SystemExit("runtime workflow must never make a runtime-only release latest")
if 'RELEASE_PRERELEASE_INPUT: "true"' not in workflow:
    raise SystemExit("runtime workflow must force GitHub prerelease publication")
if 'EXPECTED_REVISION="${{ steps.release_source.outputs.commit }}"' not in workflow:
    raise SystemExit("runtime workflow must bind Pearl Go binary verification to the reviewed commit")
before_build = workflow.split("- name: Build Pearl linux-amd64 runtime pair", 1)[0]
if "id: release_toolchain" not in before_build:
    raise SystemExit("runtime workflow must expose the reviewed toolchain path as a step output")
if 'toolchain_json="$RUNNER_TEMP/release-toolchain.json"' not in before_build:
    raise SystemExit("runtime workflow must keep release-toolchain.json outside the git worktree before Go builds")
if "scripts/verify-release-toolchain.sh release-toolchain.json" in before_build:
    raise SystemExit("runtime workflow must not write release-toolchain.json into the git worktree before Go builds")
build = workflow.split("- name: Build Pearl linux-amd64 runtime pair", 1)[1].split(
    "- name: Sign Pearl runtime metadata and checksums", 1
)[0]
if 'artifact_dir="$RUNNER_TEMP/pearl-runtime-build"' not in build:
    raise SystemExit("runtime workflow must build Pearl Go binaries outside the git worktree")
if "git status --porcelain --untracked-files=all" not in build:
    raise SystemExit("runtime workflow must fail closed when the checkout is dirty before Go builds")
if '-o "$GITHUB_WORKSPACE/' in build:
    raise SystemExit("runtime workflow must not write Go build outputs into the git worktree")
if 'python3 scripts/verify-pearl-go-binaries.py \\\n            "$artifact_dir/coordinator-linux-amd64" \\\n            "$artifact_dir/coordinator-cli-linux-amd64" \\\n            "$artifact_dir/gateway-linux-amd64"' not in build:
    raise SystemExit("runtime workflow must verify the out-of-worktree Pearl Go binaries")
verify_position = build.find("python3 scripts/verify-pearl-go-binaries.py")
install_position = build.find('install -m 0755 "$artifact_dir/coordinator-linux-amd64" coordinator-linux-amd64')
if verify_position < 0 or install_position < 0 or install_position < verify_position:
    raise SystemExit("runtime workflow must copy release assets into the workspace only after binary verification")
sign = workflow.split("- name: Sign Pearl runtime metadata and checksums", 1)[1].split(
    "- name: Prepare runtime release notes", 1
)[0]
toolchain_copy = 'install -m 0644 "${{ steps.release_toolchain.outputs.json }}" release-toolchain.json'
if toolchain_copy not in sign:
    raise SystemExit("runtime workflow must copy release-toolchain.json into release assets only after binary verification")
if sign.find(toolchain_copy) > sign.find("scripts/build-release-provenance.py"):
    raise SystemExit("runtime workflow must copy release-toolchain.json before building provenance")
patch_position = publish.find("gh api --method PATCH")
if patch_position < 0:
    raise SystemExit("runtime workflow must publish by numeric-ID PATCH")
positive_latest_position = publish.find("stable latest endpoint before publication did not return a positive release id")
if positive_latest_position < 0 or positive_latest_position > patch_position:
    raise SystemExit("runtime workflow must validate stable latest before publishing anything")
if "-F prerelease=false" in publish:
    raise SystemExit("runtime workflow must never promote runtime-only releases to GitHub stable releases")
for required in (
    "capture-release-publication.py --draft --runtime-only",
    "--expected-title \"Pearl runtime $tag\"",
    "final-draft-api.json release-provenance.json final-draft-manifest.json",
):
    if publish.find(required) < 0 or publish.find(required) > patch_position:
        raise SystemExit(f"runtime workflow draft asset capture is incomplete: {required}")
for required in (
    "-F prerelease=true",
    "published-release-api.json",
    "immutable-release-by-id.json release-provenance.json publication-manifest-by-id.json",
    "immutable-release-by-tag.json release-provenance.json publication-manifest-by-tag.json",
    "cmp final-draft-manifest.json publication-manifest-by-id.json",
    "cmp final-draft-manifest.json publication-manifest-by-tag.json",
):
    if publish.find(required, patch_position) < 0:
        raise SystemExit(f"runtime workflow immutable asset capture is incomplete: {required}")
for required in (
    "stable-latest-before.json",
    "stable-latest-after.json",
    "stable latest endpoint before publication did not return a positive release id",
    "stable latest endpoint after publication did not return a positive release id",
    "runtime-only release unexpectedly resolves through the stable latest endpoint",
    "runtime-only release changed the stable latest endpoint",
):
    if required not in publish:
        raise SystemExit(f"runtime workflow latest-preservation check is incomplete: {required}")
latest_window = publish[publish.find("stable-latest-before.json"):publish.find("python3 scripts/capture-release-publication.py --runtime-only")]
if "printf '%s\\n' '{}'" in latest_window:
    raise SystemExit("runtime workflow must fail closed when stable latest cannot be fetched")
PY

git init --bare -q "$work/remote.git"
git init -q "$work/source"
git -C "$work/source" config user.name pearl-runtime-release-test
git -C "$work/source" config user.email pearl-runtime-release-test@example.invalid
printf '%s\n' one > "$work/source/value"
git -C "$work/source" add value
git -C "$work/source" commit -qm one
first="$(git -C "$work/source" rev-parse HEAD)"
printf '%s\n' two > "$work/source/value"
git -C "$work/source" commit -qam two
second="$(git -C "$work/source" rev-parse HEAD)"
git -C "$work/source" remote add origin "$work/remote.git"
git -C "$work/source" push -q origin HEAD:refs/heads/main
git -C "$work/source" tag v1.8.66 "$second"
git -C "$work/source" push -q origin refs/tags/v1.8.66

make_release_dir() {
  local directory="$1"
  local tag="$2"
  local commit="$3"
  local lane="${4:-pearl_runtime_catalog}"
  rm -rf "$directory"
  mkdir -p "$directory"
  printf '%s\n' coordinator > "$directory/coordinator-linux-amd64"
  printf '%s\n' coordinator-cli > "$directory/coordinator-cli-linux-amd64"
  printf '%s\n' gateway > "$directory/gateway-linux-amd64"
  printf '%s\n' signed-metadata > "$directory/pearl-release.json.sig"
  printf '%s\n' signed-checksums > "$directory/checksums.txt.sig"
  printf '%s\n' catalog-release > "$directory/release.json"
  printf '%s\n' trusted-keys > "$directory/trusted-keys.json"
  printf '%s\n' tier2-catalog > "$directory/tier2-catalog.json"
  printf '%s\n' autotune-candidates > "$directory/autotune-candidates.json"
  printf '%s\n' autotune-candidates-sig > "$directory/autotune-candidates.json.sig"
  printf '%s\n' demand-rank > "$directory/demand-rank.json"
  printf '%s\n' demand-rank-sig > "$directory/demand-rank.json.sig"
  printf '%s\n' rate-card > "$directory/rate-card.json"
  printf '%s\n' rate-card-sig > "$directory/rate-card.json.sig"
  python3 - "$directory" "$tag" "$commit" "$lane" <<'PY'
import hashlib
import json
import pathlib
import sys

directory = pathlib.Path(sys.argv[1])
tag = sys.argv[2]
commit = sys.argv[3]
lane = sys.argv[4]
version = tag.removeprefix("v")

def digest(name: str) -> str:
    return hashlib.sha256((directory / name).read_bytes()).hexdigest()

catalog = None
if lane == "pearl_runtime_catalog":
    catalog = {
        "release_id": "test-release",
        "policy_version": "test-policy",
        "files": {
            "release.json": digest("release.json"),
            "trusted-keys.json": digest("trusted-keys.json"),
            "tier2-catalog.json": digest("tier2-catalog.json"),
            "autotune-candidates.json": digest("autotune-candidates.json"),
            "autotune-candidates.json.sig": digest("autotune-candidates.json.sig"),
            "demand-rank.json": digest("demand-rank.json"),
            "demand-rank.json.sig": digest("demand-rank.json.sig"),
            "rate-card.json": digest("rate-card.json"),
            "rate-card.json.sig": digest("rate-card.json.sig"),
        },
    }
elif lane != "pearl_runtime":
    raise SystemExit(f"unsupported lane: {lane}")

metadata = {
    "schema_version": 1,
    "release_lane": lane,
    "repository": "Augustas11/macprovider",
    "tag": tag,
    "release_version": version,
    "commit": commit,
    "architecture": "linux-amd64",
    "components": {
        "coordinator": {
            "asset": "coordinator-linux-amd64",
            "sha256": digest("coordinator-linux-amd64"),
            "embedded_version": tag,
        },
        "gateway": {
            "asset": "gateway-linux-amd64",
            "sha256": digest("gateway-linux-amd64"),
            "embedded_version": tag,
        },
    },
    "catalog": catalog,
    "operator_artifacts": {
        "coordinator_cli": {
            "asset": "coordinator-cli-linux-amd64",
            "sha256": digest("coordinator-cli-linux-amd64"),
        },
    },
}
if lane == "pearl_runtime_catalog":
    metadata["provider_advertised_version"] = version
(directory / "pearl-release.json").write_text(
    json.dumps(metadata, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
checksums = []
for path in sorted(directory.iterdir()):
    if path.name == "checksums.txt":
        continue
    checksums.append(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n")
(directory / "checksums.txt").write_text("".join(checksums), encoding="utf-8")
PY
}

fake_gh_dir="$work/fake-gh"
mkdir -p "$fake_gh_dir"
cat > "$fake_gh_dir/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" != "release" ]]; then
  echo "unsupported fake gh command" >&2
  exit 2
fi
shift
case "${1:-}" in
  view)
    tag="$2"
    python3 - "$FAKE_GH_RELEASE_DIR" "$tag" <<'PY'
import json
import os
import pathlib
import sys

directory = pathlib.Path(sys.argv[1])
tag = sys.argv[2]
assets = [{"name": path.name} for path in sorted(directory.iterdir()) if path.is_file()]
metadata = json.loads((directory / "pearl-release.json").read_text(encoding="utf-8"))
prerelease = metadata.get("release_lane") == "pearl_runtime"
if os.environ.get("FAKE_GH_PRERELEASE") == "false":
    prerelease = False
print(json.dumps({
    "tagName": tag,
    "isDraft": False,
    "isPrerelease": prerelease,
    "assets": assets,
}))
PY
    ;;
  download)
    tag="$2"
    shift 2
    destination=""
    patterns=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo)
          shift 2
          ;;
        --dir)
          destination="$2"
          shift 2
          ;;
        --pattern)
          patterns+=("$2")
          shift 2
          ;;
        --clobber)
          shift
          ;;
        *)
          echo "unsupported fake gh release download argument: $1" >&2
          exit 2
          ;;
      esac
    done
    mkdir -p "$destination"
    for pattern in "${patterns[@]}"; do
      cp "$FAKE_GH_RELEASE_DIR/$pattern" "$destination/$pattern"
    done
    ;;
  *)
    echo "unsupported fake gh release subcommand: ${1:-}" >&2
    exit 2
    ;;
esac
SH
chmod +x "$fake_gh_dir/gh"

make_release_dir "$work/release-ok" v1.8.66 "$second"
bash "$guard" --tag v1.8.66 --expected-commit "$second" \
  --remote "$work/remote.git" --release-dir "$work/release-ok" |
  grep -q 'ok: v1.8.66 has Pearl runtime assets'

make_release_dir "$work/release-runtime-only" v1.8.66 "$second" pearl_runtime
rm "$work/release-runtime-only"/release.json \
  "$work/release-runtime-only"/trusted-keys.json \
  "$work/release-runtime-only"/tier2-catalog.json \
  "$work/release-runtime-only"/autotune-candidates.json \
  "$work/release-runtime-only"/autotune-candidates.json.sig \
  "$work/release-runtime-only"/demand-rank.json \
  "$work/release-runtime-only"/demand-rank.json.sig
bash "$guard" --tag v1.8.66 --expected-commit "$second" \
  --remote "$work/remote.git" --release-dir "$work/release-runtime-only" |
  grep -q 'ok: v1.8.66 has Pearl runtime assets'

make_release_dir "$work/release-catalog-bound-missing-feed" v1.8.66 "$second"
rm "$work/release-catalog-bound-missing-feed/demand-rank.json"
if bash "$guard" --tag v1.8.66 --expected-commit "$second" \
  --remote "$work/remote.git" --release-dir "$work/release-catalog-bound-missing-feed" \
  >"$work/catalog-bound-missing-feed.out" 2>&1; then
  fail "accepted a catalog-bound Pearl runtime release missing a feed asset"
fi
grep -q 'missing catalog/feed asset(s) for catalog-bound Pearl runtime release: demand-rank.json' \
  "$work/catalog-bound-missing-feed.out"

make_release_dir "$work/release-catalog-bound-tampered-feed" v1.8.66 "$second"
printf '\n' >> "$work/release-catalog-bound-tampered-feed/autotune-candidates.json"
if bash "$guard" --tag v1.8.66 --expected-commit "$second" \
  --remote "$work/remote.git" --release-dir "$work/release-catalog-bound-tampered-feed" \
  >"$work/catalog-bound-tampered-feed.out" 2>&1; then
  fail "accepted a catalog-bound Pearl runtime release with tampered feed bytes"
fi
grep -q 'autotune-candidates.json sha256 does not match pearl-release.json catalog metadata' \
  "$work/catalog-bound-tampered-feed.out"

make_release_dir "$work/release-github-runtime-only" v1.8.66 "$second" pearl_runtime
rm "$work/release-github-runtime-only"/release.json \
  "$work/release-github-runtime-only"/trusted-keys.json \
  "$work/release-github-runtime-only"/tier2-catalog.json \
  "$work/release-github-runtime-only"/autotune-candidates.json \
  "$work/release-github-runtime-only"/autotune-candidates.json.sig \
  "$work/release-github-runtime-only"/demand-rank.json \
  "$work/release-github-runtime-only"/demand-rank.json.sig
FAKE_GH_RELEASE_DIR="$work/release-github-runtime-only" PATH="$fake_gh_dir:$PATH" \
  bash "$guard" --tag v1.8.66 --expected-commit "$second" \
    --remote "$work/remote.git" |
  grep -q 'ok: v1.8.66 has Pearl runtime assets'

if FAKE_GH_RELEASE_DIR="$work/release-github-runtime-only" FAKE_GH_PRERELEASE=false PATH="$fake_gh_dir:$PATH" \
  bash "$guard" --tag v1.8.66 --expected-commit "$second" \
    --remote "$work/remote.git" >"$work/github-runtime-only-stable.out" 2>&1; then
  fail "accepted a GitHub runtime-only Pearl release that was not a prerelease"
fi
grep -q 'runtime-only Pearl releases must be GitHub prereleases' \
  "$work/github-runtime-only-stable.out"

make_release_dir "$work/release-github-catalog-bound-missing-feed" v1.8.66 "$second"
rm "$work/release-github-catalog-bound-missing-feed/demand-rank.json"
if FAKE_GH_RELEASE_DIR="$work/release-github-catalog-bound-missing-feed" PATH="$fake_gh_dir:$PATH" \
  bash "$guard" --tag v1.8.66 --expected-commit "$second" \
    --remote "$work/remote.git" >"$work/github-catalog-bound-missing-feed.out" 2>&1; then
  fail "accepted a GitHub catalog-bound Pearl runtime release missing a feed asset"
fi
grep -q 'missing catalog/feed asset(s) for catalog-bound Pearl runtime release: demand-rank.json' \
  "$work/github-catalog-bound-missing-feed.out"

if bash "$guard" --tag v1.8.65 --expected-commit "$second" \
  --remote "$work/remote.git" --release-dir "$work/release-ok" \
  >"$work/absent-tag.out" 2>&1; then
  fail "accepted a release whose required tag is absent"
fi
grep -q 'release tag v1.8.65 is absent' "$work/absent-tag.out"

git -C "$work/source" tag v1.8.67 "$first"
git -C "$work/source" push -q origin refs/tags/v1.8.67
make_release_dir "$work/release-wrong-tag-target" v1.8.67 "$second"
if bash "$guard" --tag v1.8.67 --expected-commit "$second" \
  --remote "$work/remote.git" --release-dir "$work/release-wrong-tag-target" \
  >"$work/tag-drift.out" 2>&1; then
  fail "accepted a release whose tag targets a different commit"
fi
grep -q "targets $first; refusing assets built from $second" "$work/tag-drift.out"

make_release_dir "$work/release-missing-asset" v1.8.66 "$second"
rm "$work/release-missing-asset/gateway-linux-amd64"
if bash "$guard" --tag v1.8.66 --expected-commit "$second" \
  --remote "$work/remote.git" --release-dir "$work/release-missing-asset" \
  >"$work/missing-asset.out" 2>&1; then
  fail "accepted a release missing a Pearl runtime asset"
fi
grep -q 'missing Pearl runtime release asset(s): gateway-linux-amd64' "$work/missing-asset.out"

make_release_dir "$work/release-wrong-metadata-commit" v1.8.66 "$first"
if bash "$guard" --tag v1.8.66 --expected-commit "$second" \
  --remote "$work/remote.git" --release-dir "$work/release-wrong-metadata-commit" \
  >"$work/metadata-commit.out" 2>&1; then
  fail "accepted release metadata for the wrong commit"
fi
grep -q "pearl-release.json commit is '$first', expected '$second'" "$work/metadata-commit.out"

make_release_dir "$work/release-bad-digest" v1.8.66 "$second"
printf '%s\n' tampered > "$work/release-bad-digest/coordinator-linux-amd64"
if bash "$guard" --tag v1.8.66 --expected-commit "$second" \
  --remote "$work/remote.git" --release-dir "$work/release-bad-digest" \
  >"$work/bad-digest.out" 2>&1; then
  fail "accepted a runtime binary whose digest no longer matches metadata"
fi
grep -q 'coordinator-linux-amd64 sha256 does not match pearl-release.json' "$work/bad-digest.out"

echo "PASS: Pearl runtime release preflight fails closed on missing assets and source drift"
