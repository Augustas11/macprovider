#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$root/.github/workflows/release.yml"
guard="$root/scripts/verify-github-release-posture.sh"
input_guard="$root/scripts/validate-release-inputs.sh"
checksums_guard="$root/scripts/verify-release-checksums.sh"
sparkle_generator="$root/scripts/generate-malibu-appcast.sh"
xcodegen_installer="$root/scripts/install-pinned-xcodegen.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/release-security-posture.XXXXXX")"
trap 'rm -rf "$work"' EXIT

python3 - "$workflow" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
if "\n  push:" in text or "refs/tags/" in text:
    raise SystemExit("release workflow must not execute from a tag-push ref")
if "\n  workflow_dispatch:" not in text:
    raise SystemExit("release workflow must use reviewed manual dispatch")
candidate_input = re.search(
    r"\n      candidate:\n"
    r"(?:        .*\n)*?"
    r"        default: false\n"
    r"        type: boolean\n",
    text,
)
if candidate_input is None:
    raise SystemExit("candidate dispatch input must be a boolean defaulting to false")
build = text.split("\n  build:\n", 1)[1].split("\n  sign_publish:\n", 1)[0]
publish = text.split("\n  sign_publish:\n", 1)[1]
if "secrets." in build or "contents: write" in build:
    raise SystemExit("unprivileged build job contains a secret or write permission")
if "environment: production-release" not in publish:
    raise SystemExit("secret-bearing publish job lacks the protected environment")
if "scripts/verify-release-source.sh" not in build or "scripts/verify-release-source.sh" not in publish:
    raise SystemExit("both jobs must verify the fresh reviewed main commit")
if "RELEASE_CANDIDATE_INPUT" not in build or 'absence_policy="--allow-absent"' not in build:
    raise SystemExit("unprivileged build job lacks explicit candidate tag-absence handling")
if "--allow-absent" in publish:
    raise SystemExit("protected publish job must always require the exact release tag")
if "unsigned-release-manifest.json" not in build or "unsigned-release-manifest.json" not in publish:
    raise SystemExit("unsigned candidate inputs lack an end-to-end provenance manifest")
if "scripts/verify-github-release-posture.sh" not in publish:
    raise SystemExit("publish job must verify external repository posture")
if publish.find("Verify Malibu release cryptographic bindings") > publish.find("Create verified draft GitHub release"):
    raise SystemExit("Apple and Sparkle verification must run before draft release creation")
if "scripts/verify-malibu-release-artifacts.sh" not in publish or "verify-malibu-sparkle-signature.py" not in publish:
    raise SystemExit("publish job must verify Apple and Sparkle signatures")
if '"repos/$GITHUB_REPOSITORY/releases/$release_id"' not in publish:
    raise SystemExit("post-create verification must re-fetch the captured numeric release id")
if "ensure-release-tag-target" in text or "git push" in text:
    raise SystemExit("release workflow must not create a release tag")
if "gh release download" in text:
    raise SystemExit("release workflow must publish the captured workflow files")
if "actions/upload-artifact@v" in text or "actions/download-artifact@v" in text:
    raise SystemExit("artifact actions must be pinned by commit")
for requirement in (
    'go-version: "1.26.4"',
    "GOTOOLCHAIN=local",
    "CGO_ENABLED=0 GOOS=linux GOARCH=amd64",
    "go build -mod=readonly -trimpath",
    "coordinator-linux-amd64",
    "coordinator-cli-linux-amd64",
    "gateway-linux-amd64",
):
    if requirement not in build:
        raise SystemExit(f"reviewed Pearl build contract is missing: {requirement}")
for requirement in (
    'grep -Eq "coordinator-linux-amd64:[[:space:]]+ELF 64-bit.*x86-64"',
    'grep -Eq "coordinator-cli-linux-amd64:[[:space:]]+ELF 64-bit.*x86-64"',
    'grep -Eq "gateway-linux-amd64:[[:space:]]+ELF 64-bit.*x86-64"',
):
    if requirement not in build:
        raise SystemExit(f"Pearl ELF verification is not alignment-safe: {requirement}")
if "go build" in publish or publish.find("Setup Go for Pearl binaries") >= 0:
    raise SystemExit("Pearl compilation must remain in the unprivileged build job")
restore = publish.split("- name: Restore captured unsigned inputs", 1)[1].split("\n      - name:", 1)[0]
source_gate_position = restore.find("scripts/verify-release-source.sh")
restore_position = restore.find("cp \"$RUNNER_TEMP/unsigned-release-inputs/")
manifest_position = restore.find("expected-unsigned-release-manifest.json")
manifest_cmp_position = restore.find('cmp "$unsigned_dir/unsigned-release-manifest.json"')
if (
    source_gate_position < 0
    or "--require-existing" not in restore[source_gate_position:restore_position]
    or manifest_position < source_gate_position
    or manifest_cmp_position < manifest_position
    or restore_position < manifest_cmp_position
    or restore_position < source_gate_position
):
    raise SystemExit("protected job must verify the exact tag and candidate manifest before restoring inputs")
for asset in ("coordinator-linux-amd64", "coordinator-cli-linux-amd64", "gateway-linux-amd64"):
    if asset not in restore:
        raise SystemExit(f"Pearl artifact does not cross the reviewed build boundary: {asset}")
prepare = publish.split("- name: Prepare release assets", 1)[1].split("\n      - name:", 1)[0]
metadata_position = prepare.find('release_assets+=("$pearl_metadata" "$pearl_metadata_sig")')
provenance_position = prepare.find("scripts/build-release-provenance.py")
if metadata_position < 0 or provenance_position < 0 or metadata_position > provenance_position:
    raise SystemExit("signed Pearl metadata must enter the release set before provenance")
if "ops/pearl-updater/release-signing-public.pem" not in prepare:
    raise SystemExit("Pearl metadata signature is not checked against the updater trust anchor")
lines = text.splitlines()
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
    if any(re.search(r"\$\{\{[^\n}]*(?:github\.event\.)?inputs\.", row) for row in block):
        raise SystemExit("workflow input expression is interpolated into a run block")
if "brew install xcodegen" in text:
    raise SystemExit("release workflow must not install mutable XcodeGen")
if "scripts/install-pinned-xcodegen.sh" not in build or "scripts/verify-app-build-inputs.sh" not in build:
    raise SystemExit("unsigned app build must use reviewed generator and dependency inputs")
toolchain_position = build.find("scripts/verify-release-toolchain.sh")
if toolchain_position < 0 or toolchain_position > build.find("Install reviewed XcodeGen artifact"):
    raise SystemExit("exact release toolchain must be verified before build tooling or compilation")
if "/Applications/Xcode_16.4.app/Contents/Developer" not in build:
    raise SystemExit("release build must select the reviewed Xcode app path")
if "release-toolchain.json" not in build or "release-toolchain.json" not in publish:
    raise SystemExit("verified build toolchain must cross the artifact boundary into publication")
if "actions/checkout v6.0.3" not in build:
    raise SystemExit("checkout provenance comment differs from the pinned action commit")
if publish.find("Clean Apple signing material before third-party tools") > publish.find("Generate Sparkle appcast"):
    raise SystemExit("Apple keychain and private material must be deleted before Sparkle tools run")
create = publish.split("- name: Create verified draft GitHub release", 1)[1].split("\n      - name:", 1)[0]
verify_draft = publish.split("- name: Verify draft release assets by numeric ID", 1)[1].split("\n      - name:", 1)[0]
make_public = publish.split("- name: Publish only the revalidated numeric draft", 1)[1].split("\n      - name:", 1)[0]
if "--draft" not in create or create.find("scripts/verify-release-checksums.sh") > create.find("gh release create"):
    raise SystemExit("GitHub publication must verify canonical checksums before creating a draft")
if "capture-release-publication.py --draft" not in verify_draft or "draft-release-id.txt" not in verify_draft:
    raise SystemExit("draft assets and numeric release ID must be captured before publication")
patch_position = make_public.find("gh api --method PATCH")
if patch_position < 0:
    raise SystemExit("verified draft must be made public by numeric-ID PATCH")
for requirement in (
    "scripts/verify-release-source.sh",
    "scripts/verify-github-release-posture.sh",
    "scripts/verify-release-checksums.sh",
    "final-draft-by-tag.json",
    "final-draft-by-id.json",
    "capture-release-publication.py --draft",
):
    if make_public.find(requirement) < 0 or make_public.find(requirement) > patch_position:
        raise SystemExit(f"final public-transition gate is missing or late: {requirement}")
if "--require-existing" not in make_public[make_public.find("scripts/verify-release-source.sh"):patch_position]:
    raise SystemExit("final public-transition source gate must explicitly require the tag")
if make_public.find("immutable-release-by-id.json", patch_position) < 0 or make_public.find(
    "capture-release-publication.py", patch_position
) < 0:
    raise SystemExit("published numeric release must be re-fetched and required immutable")
for requirement in (
    "verify-published-release.py",
    "stable-latest-release.json",
    '"$release_id" "$PRERELEASE_INPUT"',
):
    if make_public.find(requirement, patch_position) < 0:
        raise SystemExit(f"post-publication release-state verification is missing: {requirement}")
if "if: needs.build.outputs.prerelease == 'false'" not in publish.split(
    "- name: Publish Malibu latest.dmg", 1
)[1].split("\n      - name:", 1)[0]:
    raise SystemExit("stable Pearl feed publication is not gated to prerelease=false")
PY

python3 - "$sparkle_generator" "$xcodegen_installer" <<'PY'
import pathlib
import sys

sparkle = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
xcodegen = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
sparkle_digest = "50612a06038abc931f16011d7903b8326a362c1074dabccb718404ce8e585f0b"
xcodegen_digest = "090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef"
if sparkle_digest not in sparkle or sparkle.find("shasum -a 256") > sparkle.find("tar -xJf"):
    raise SystemExit("Sparkle release tools must be digest-pinned before extraction")
if sparkle.find("tar -xJf") > sparkle.find('"$generate_appcast"'):
    raise SystemExit("Sparkle executable ordering is invalid")
if "SPARKLE_VERSION" in sparkle or "SPARKLE_TOOLS_DIR" in sparkle:
    raise SystemExit("Sparkle tool version and bytes must not be caller-overridable")
if xcodegen_digest not in xcodegen or xcodegen.find("shasum -a 256") > xcodegen.find("unzip -q"):
    raise SystemExit("XcodeGen artifact must be digest-pinned before extraction")
PY

marker="$work/input-command-executed"
malicious_versions=(
  "v1.2.3'; touch $marker; #"
  "v1.2.3\$(touch $marker)"
  $'v1.2.3\n'"touch $marker"
)
for value in "${malicious_versions[@]}"; do
  if bash "$input_guard" "$value" false false >"$work/input.out" 2>&1; then
    echo "release input guard accepted malicious version bytes" >&2
    exit 1
  fi
done
if bash "$input_guard" v1.2.3 "true'; touch $marker; #" false >"$work/input.out" 2>&1; then
  echo "release input guard accepted malicious prerelease bytes" >&2
  exit 1
fi
if bash "$input_guard" v1.2.3 false "true'; touch $marker; #" >"$work/input.out" 2>&1; then
  echo "release input guard accepted malicious candidate bytes" >&2
  exit 1
fi
[[ ! -e "$marker" ]] || {
  echo "release input validation executed command-shaped bytes" >&2
  exit 1
}
bash "$input_guard" v1.2.3 false true | grep -Fxq 'v1.2.3 false true'

mkdir -p "$work/reviewed/scripts" "$work/reviewed/phase3-binary/app"
cp "$root/scripts/verify-app-build-inputs.sh" "$work/reviewed/scripts/"
cp "$root/phase3-binary/Package.resolved" "$work/reviewed/phase3-binary/"
cp "$root/phase3-binary/app/Package.resolved" "$work/reviewed/phase3-binary/app/"
cp "$root/phase3-binary/app/project.yml" "$work/reviewed/phase3-binary/app/"
git -C "$work/reviewed" init -q
git -C "$work/reviewed" config user.name release-test
git -C "$work/reviewed" config user.email release-test@example.invalid
git -C "$work/reviewed" add .
git -C "$work/reviewed" commit -qm reviewed
reviewed_commit="$(git -C "$work/reviewed" rev-parse HEAD)"
bash "$work/reviewed/scripts/verify-app-build-inputs.sh" "$reviewed_commit" >/dev/null
printf '\n# unreviewed mutation\n' >> "$work/reviewed/phase3-binary/app/project.yml"
if bash "$work/reviewed/scripts/verify-app-build-inputs.sh" "$reviewed_commit" >"$work/reviewed.out" 2>&1; then
  echo "app build input guard accepted bytes outside the reviewed commit" >&2
  exit 1
fi
grep -q 'working-tree bytes differ from reviewed commit' "$work/reviewed.out"

mkdir -p "$work/checksums"
printf 'release asset\n' > "$work/checksums/asset.bin"
asset_sha="$(shasum -a 256 "$work/checksums/asset.bin" | awk '{print $1}')"
python3 - "$work/checksums/release-provenance.json" "$asset_sha" <<'PY'
import json
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_text(json.dumps({
    "schema_version": 1,
    "repository": "Augustas11/macprovider",
    "tag": "v1.2.3",
    "commit": "a" * 40,
    "assets": {"asset.bin": sys.argv[2]},
}, sort_keys=True) + "\n", encoding="utf-8")
PY
provenance_sha="$(shasum -a 256 "$work/checksums/release-provenance.json" | awk '{print $1}')"
printf '%s  asset.bin\n%s  release-provenance.json\n' \
  "$asset_sha" "$provenance_sha" > "$work/checksums/checksums.txt"
openssl ecparam -name prime256v1 -genkey -noout -out "$work/checksums/wrong-key.pem"
openssl dgst -sha256 -sign "$work/checksums/wrong-key.pem" \
  -out "$work/checksums/checksums.txt.sig" "$work/checksums/checksums.txt"
if bash "$checksums_guard" \
  "$work/checksums/checksums.txt" "$work/checksums/checksums.txt.sig" \
  "$work/checksums/release-provenance.json" Augustas11/macprovider v1.2.3 \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  "$work/checksums/asset.bin" "$work/checksums/release-provenance.json" \
  >"$work/wrong-key.out" 2>&1; then
  echo "canonical release verifier accepted a signature from the wrong key" >&2
  exit 1
fi
grep -q 'canonical installer key' "$work/wrong-key.out"

mkdir -p "$work/bin" "$work/fixtures"
cat > "$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == api ]]
endpoint=""
for value in "$@"; do
  [[ "$value" == repos/* ]] && endpoint="$value"
done
case "$endpoint" in
  repos/*/immutable-releases)
    if [[ -n "${FIXTURE_IMMUTABLE:-}" ]]; then
      printf '%s\n' "$FIXTURE_IMMUTABLE"
    else
      printf '%s\n' '{"enabled":true}'
    fi
    ;;
  repos/*/environments/production-release)
    cat "$FIXTURE_DIR/environment.json"
    ;;
  repos/*/environments/production-release/deployment-branch-policies*)
    cat "$FIXTURE_DIR/policies.json"
    ;;
  repos/*/rulesets\?*)
    cat "$FIXTURE_DIR/rulesets.json"
    ;;
  repos/*/rulesets/71)
    cat "$FIXTURE_DIR/ruleset-71.json"
    ;;
  *)
    echo "unexpected fake gh endpoint: $endpoint" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$work/bin/gh"

cat > "$work/fixtures/environment.json" <<'EOF'
{"can_admins_bypass":false,"protection_rules":[{"type":"required_reviewers","prevent_self_review":true,"reviewers":[{"type":"User","reviewer":{"type":"User","id":285575208,"login":"antfleet-ops"}}]}],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
EOF
cat > "$work/fixtures/policies.json" <<'EOF'
{"branch_policies":[{"id":3,"name":"main","type":"branch"}]}
EOF
cat > "$work/fixtures/rulesets.json" <<'EOF'
[{"id":71,"target":"tag","enforcement":"active"}]
EOF
cat > "$work/fixtures/ruleset-71.json" <<'EOF'
{"id":71,"target":"tag","enforcement":"active","bypass_actors":[{"actor_id":28995904,"actor_type":"User","bypass_mode":"always"}],"conditions":{"ref_name":{"include":["refs/tags/v*"],"exclude":[]}},"rules":[{"type":"creation"},{"type":"update"},{"type":"deletion"}]}
EOF

PATH="$work/bin:$PATH" FIXTURE_DIR="$work/fixtures" GH_TOKEN=test \
  bash "$guard" Augustas11/macprovider production-release >/dev/null

if PATH="$work/bin:$PATH" FIXTURE_DIR="$work/fixtures" GH_TOKEN=test \
  FIXTURE_IMMUTABLE='{"enabled":false}' \
  bash "$guard" Augustas11/macprovider production-release >"$work/immutable.out" 2>&1; then
  echo "posture guard accepted mutable releases" >&2
  exit 1
fi
grep -q 'immutable releases are not enabled' "$work/immutable.out"

cp "$work/fixtures/environment.json" "$work/fixtures/environment.good"
printf '%s\n' '{"can_admins_bypass":false,"protection_rules":[],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' \
  > "$work/fixtures/environment.json"
if PATH="$work/bin:$PATH" FIXTURE_DIR="$work/fixtures" GH_TOKEN=test \
  bash "$guard" Augustas11/macprovider production-release >"$work/reviewer.out" 2>&1; then
  echo "posture guard accepted an environment without a reviewer" >&2
  exit 1
fi
grep -q 'must have exactly one required-reviewers rule' "$work/reviewer.out"
mv "$work/fixtures/environment.good" "$work/fixtures/environment.json"

cp "$work/fixtures/environment.json" "$work/fixtures/environment.good"
printf '%s\n' '{"can_admins_bypass":false,"protection_rules":[{"type":"required_reviewers","prevent_self_review":false,"reviewers":[{"type":"User","reviewer":{"type":"User","id":285575208,"login":"antfleet-ops"}}]}],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' \
  > "$work/fixtures/environment.json"
if PATH="$work/bin:$PATH" FIXTURE_DIR="$work/fixtures" GH_TOKEN=test \
  bash "$guard" Augustas11/macprovider production-release >"$work/self-review.out" 2>&1; then
  echo "posture guard accepted an environment that allows self-review" >&2
  exit 1
fi
grep -q 'must prevent self-review' "$work/self-review.out"
mv "$work/fixtures/environment.good" "$work/fixtures/environment.json"

cp "$work/fixtures/environment.json" "$work/fixtures/environment.good"
python3 - "$work/fixtures/environment.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
environment = json.loads(path.read_text())
environment["can_admins_bypass"] = True
path.write_text(json.dumps(environment) + "\n")
PY
if PATH="$work/bin:$PATH" FIXTURE_DIR="$work/fixtures" GH_TOKEN=test \
  bash "$guard" Augustas11/macprovider production-release >"$work/admin-bypass.out" 2>&1; then
  echo "posture guard accepted environment admin bypass" >&2
  exit 1
fi
grep -q 'must disable admin bypass' "$work/admin-bypass.out"
mv "$work/fixtures/environment.good" "$work/fixtures/environment.json"

cp "$work/fixtures/environment.json" "$work/fixtures/environment.good"
python3 - "$work/fixtures/environment.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
environment = json.loads(path.read_text())
environment["protection_rules"][0]["reviewers"][0]["reviewer"] = {
    "type": "User", "id": 9, "login": "not-antfleet-ops"
}
path.write_text(json.dumps(environment) + "\n")
PY
if PATH="$work/bin:$PATH" FIXTURE_DIR="$work/fixtures" GH_TOKEN=test \
  bash "$guard" Augustas11/macprovider production-release >"$work/wrong-reviewer.out" 2>&1; then
  echo "posture guard accepted the wrong environment reviewer" >&2
  exit 1
fi
grep -q 'reviewer must be User antfleet-ops' "$work/wrong-reviewer.out"
mv "$work/fixtures/environment.good" "$work/fixtures/environment.json"

cp "$work/fixtures/ruleset-71.json" "$work/fixtures/ruleset.good"
printf '%s\n' '{"id":71,"target":"tag","enforcement":"active","bypass_actors":[{"actor_id":28995904,"actor_type":"User","bypass_mode":"always"}],"conditions":{"ref_name":{"include":["refs/tags/v*"],"exclude":[]}},"rules":[{"type":"creation"},{"type":"update"}]}' \
  > "$work/fixtures/ruleset-71.json"
if PATH="$work/bin:$PATH" FIXTURE_DIR="$work/fixtures" GH_TOKEN=test \
  bash "$guard" Augustas11/macprovider production-release >"$work/ruleset.out" 2>&1; then
  echo "posture guard accepted a tag ruleset without deletion protection" >&2
  exit 1
fi
grep -q 'no active v\* tag ruleset restricts' "$work/ruleset.out"
mv "$work/fixtures/ruleset.good" "$work/fixtures/ruleset-71.json"

cp "$work/fixtures/ruleset-71.json" "$work/fixtures/ruleset.good"
printf '%s\n' '{"id":71,"target":"tag","enforcement":"active","bypass_actors":[{"actor_id":88,"actor_type":"Integration","bypass_mode":"always"}],"conditions":{"ref_name":{"include":["refs/tags/v*"],"exclude":[]}},"rules":[{"type":"creation"},{"type":"update"},{"type":"deletion"}]}' \
  > "$work/fixtures/ruleset-71.json"
if PATH="$work/bin:$PATH" FIXTURE_DIR="$work/fixtures" GH_TOKEN=test \
  bash "$guard" Augustas11/macprovider production-release >"$work/bypass.out" 2>&1; then
  echo "posture guard accepted an Actions integration tag bypass" >&2
  exit 1
fi
grep -q 'only the designated tagger bypass' "$work/bypass.out"
mv "$work/fixtures/ruleset.good" "$work/fixtures/ruleset-71.json"

printf '%s\n' '{"branch_policies":[{"id":3,"name":"main","type":"branch"},{"id":4,"name":"release","type":"branch"}]}' \
  > "$work/fixtures/policies.json"
if PATH="$work/bin:$PATH" FIXTURE_DIR="$work/fixtures" GH_TOKEN=test \
  bash "$guard" Augustas11/macprovider production-release >"$work/policies.out" 2>&1; then
  echo "posture guard accepted a second deployment branch" >&2
  exit 1
fi
grep -q 'must allow only the main branch' "$work/policies.out"

echo "release security posture regression checks passed"
