#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$root/.github/workflows/release.yml"
guard="$root/scripts/verify-github-release-posture.sh"
input_guard="$root/scripts/validate-release-inputs.sh"
checksums_guard="$root/scripts/verify-release-checksums.sh"
xcodegen_installer="$root/scripts/install-pinned-xcodegen.sh"
sparkle_generator="$root/scripts/generate-malibu-appcast.sh"
legacy_sparkle_key="$root/scripts/dist/malibu-v1.8.32-sparkle-public-key"
trust_anchor_helper="$root/scripts/prepare-malibu-bootstrap-trust-anchor.py"
malibu_artifact_verifier="$root/scripts/verify-malibu-release-artifacts.sh"
coordinator_go_mod="$root/phase4-coordinator/go.mod"
pearl_go_verifier="$root/scripts/verify-pearl-go-binaries.py"
release_runbook="$root/phase3-binary/dist/release-signing-runbook.md"
decision_log="$root/beta/DECISION_CRITERIA.md"
ci_workflow="$root/.github/workflows/ci.yml"
sparkle_validator_integration="$root/scripts/test-malibu-sparkle-validator-integration.sh"
sparkle_validator_patch="$root/scripts/fixtures/SUUpdateValidator-2.6.4-ephemeral.patch"
work="$(mktemp -d "${TMPDIR:-/tmp}/release-security-posture.XXXXXX")"
trap 'rm -rf "$work"' EXIT

python3 - "$workflow" "$root/phase3-binary/app/project.yml" \
  "$root/phase3-binary/app/Sources/Malibu/Info.plist" \
  "$trust_anchor_helper" "$malibu_artifact_verifier" "$coordinator_go_mod" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
current_app = "\n".join(
    pathlib.Path(path).read_text(encoding="utf-8") for path in sys.argv[2:4]
)
trust_anchor_helper = pathlib.Path(sys.argv[4]).read_text(encoding="utf-8")
malibu_artifact_verifier = pathlib.Path(sys.argv[5]).read_text(encoding="utf-8")
coordinator_go_mod = pathlib.Path(sys.argv[6]).read_text(encoding="utf-8")
go_directive = re.search(
    r"(?m)^go ([0-9]+\.[0-9]+(?:\.[0-9]+)?)$", coordinator_go_mod
)
if go_directive is None:
    raise SystemExit("phase4-coordinator go.mod lacks a valid Go directive")
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


def unique_step(job, name):
    marker = f"\n      - name: {name}\n"
    if job.count(marker) != 1:
        raise SystemExit(f"release build must contain exactly one {name} step")
    return job.split(marker, 1)[1].split("\n      - name:", 1)[0]


PEARL_SETUP_GO_SHA = "924ae3a1cded613372ab5595356fb5720e22ba16"
PEARL_GO_SEAL_STEP = (
    "        shell: bash\n"
    "        run: |\n"
    "          set -euo pipefail\n"
    '          source_root="$(go env GOROOT)"\n'
    "          sudo test ! -e /usr/local/lib/macprovider-go-verifier\n"
    "          sudo install -d -o root -g wheel -m 0755 /usr/local/lib/macprovider-go-verifier\n"
    '          sudo cp -a "$source_root/." /usr/local/lib/macprovider-go-verifier/\n'
    "          sudo chown -R root:wheel /usr/local/lib/macprovider-go-verifier\n"
    "          sudo chmod -R go-w /usr/local/lib/macprovider-go-verifier\n"
    "          sudo test -x /usr/local/lib/macprovider-go-verifier/bin/go"
)
PEARL_SETUP_SEAL_BUILD_SEQUENCE = (
    "\n      - name: Setup Go for Pearl binaries\n"
    "{setup_go}\n"
    "\n      - name: Seal the Tier-2 verifier toolchain\n"
    f"{PEARL_GO_SEAL_STEP}\n"
    "\n      - name: Build Pearl linux-amd64 binaries\n"
)
PEARL_SEALED_GO_REQUIREMENT = (
    "          CATALOG_RELEASE_REQUIRE_SEALED_GO_VERIFIER=1 \\\n"
    '            MACPROVIDER_PROVIDER_ADMISSION_POLICY="$PROVIDER_ADMISSION_POLICY_INPUT" \\\n'
    '            ./package.sh "${{ steps.release_source.outputs.tag }}"'
)
PEARL_GO_VERIFY_STEP = (
    "        env:\n"
    '          EXPECTED_REVISION: ${{ steps.release_source.outputs.commit }}\n'
    "        shell: bash\n"
    "        run: |\n"
    "          python3 scripts/verify-pearl-go-binaries.py \\\n"
    "            unsigned-release-inputs/coordinator-linux-amd64 \\\n"
    "            unsigned-release-inputs/coordinator-cli-linux-amd64 \\\n"
    "            unsigned-release-inputs/gateway-linux-amd64"
)
PEARL_VERIFY_UPLOAD_SEQUENCE = (
    "\n      - name: Verify staged Pearl Go binaries\n"
    f"{PEARL_GO_VERIFY_STEP}\n"
    "\n      - name: Upload unsigned build artifact\n"
)


def validate_pearl_toolchain(job):
    setup_go = unique_step(job, "Setup Go for Pearl binaries")
    seal_go = unique_step(job, "Seal the Tier-2 verifier toolchain")
    pearl_build = unique_step(job, "Build Pearl linux-amd64 binaries")
    package_build = unique_step(job, "Build package")
    verifier_step = unique_step(job, "Verify staged Pearl Go binaries")
    setup_go_uses = re.findall(
        r"(?m)^        uses: actions/setup-go@([0-9a-f]{40})$", job
    )
    if job.lower().count("actions/setup-go@") != 1 or setup_go_uses != [PEARL_SETUP_GO_SHA]:
        raise SystemExit("release build must contain exactly one pinned setup-go action")
    go_version_files = re.findall(
        r"(?m)^          go-version-file:\s*(\S+)\s*$", setup_go
    )
    if go_version_files != ["phase4-coordinator/go.mod"]:
        raise SystemExit(
            "Pearl Setup Go must use phase4-coordinator/go.mod as its sole version source"
        )
    if re.search(r"(?m)^          go-version:\s*", setup_go):
        raise SystemExit("Pearl Setup Go must not carry a second hardcoded Go version")
    if seal_go.strip("\n") != PEARL_GO_SEAL_STEP:
        raise SystemExit("Tier-2 verifier toolchain seal must contain only the exact root-owned copy")
    sealed_go_path = "/usr/local/lib/macprovider-go-verifier"
    if job.count(sealed_go_path) != PEARL_GO_SEAL_STEP.count(sealed_go_path):
        raise SystemExit("sealed Go verifier path must appear only in the exact seal step")
    expected_sequence = PEARL_SETUP_SEAL_BUILD_SEQUENCE.format(setup_go=setup_go.rstrip("\n"))
    if job.count(expected_sequence) != 1:
        raise SystemExit("Pearl Setup Go, verifier seal, and binary build must remain adjacent and ordered")
    if package_build.count(PEARL_SEALED_GO_REQUIREMENT) != 1:
        raise SystemExit("release package verification must require the sealed Go verifier")
    if job.count("CATALOG_RELEASE_REQUIRE_SEALED_GO_VERIFIER") != 1:
        raise SystemExit("release build must set the sealed Go verifier requirement exactly once")
    if verifier_step.strip("\n") != PEARL_GO_VERIFY_STEP:
        raise SystemExit("Pearl verifier step must contain only the exact binary verifier command")
    if job.count("scripts/verify-pearl-go-binaries.py") != 1:
        raise SystemExit("Pearl build must invoke the binary verifier exactly once")
    if job.count(PEARL_VERIFY_UPLOAD_SEQUENCE) != 1:
        raise SystemExit("staged Pearl binary verification must immediately precede upload")
    for build_target in (
        '-o "$RUNNER_TEMP/coordinator-linux-amd64" ./cmd/coordinator',
        '-o "$RUNNER_TEMP/coordinator-cli-linux-amd64" ./cmd/coordinator-cli',
        '-o "$RUNNER_TEMP/gateway-linux-amd64" ./cmd/gateway',
    ):
        if len(re.findall(rf"(?m)^\s*{re.escape(build_target)}\s*$", pearl_build)) != 1:
            raise SystemExit(f"Pearl build target is missing or duplicated: {build_target}")
    if pearl_build.count("go build -mod=readonly -trimpath -buildvcs=true") != 3:
        raise SystemExit("all Pearl binaries must use explicit reviewed VCS stamping")
    return pearl_build


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
for requirement in ("MACPROVIDER_PROVIDER_ADMISSION_POLICY",):
    if requirement not in build:
        raise SystemExit(f"unsigned build omits compatibility-set generation input: {requirement}")
for requirement in (
    "scripts/compatibility-set-manifest.py sign",
    "--require-signature",
    'cp "$WORK/compatibility-set.json" "$PKG_ROOT/compatibility-set.json"',
    'cp -R "$WORK/compatibility-set-local" "$PKG_ROOT/compatibility-set-local"',
    '"$APP/Contents/Resources/compatibility-set.json"',
    'cmp "$WORK/compatibility-set.json" "$APP/Contents/Resources/compatibility-set.json"',
    'release_assets+=("$compatibility_manifest")',
    'cmp "$compatibility_manifest" "$compatibility_extract/compatibility-set.json"',
):
    if requirement not in publish:
        raise SystemExit(f"protected publication omits compatibility-set binding: {requirement}")
if "scripts/verify-github-release-posture.sh" not in publish:
    raise SystemExit("publish job must verify external repository posture")
if publish.find("Verify Malibu release cryptographic bindings") > publish.find("Create verified draft GitHub release"):
    raise SystemExit("Apple verification must run before draft release creation")
if "scripts/verify-malibu-release-artifacts.sh" not in publish:
    raise SystemExit("publish job must verify Apple signatures and notarization")
for forbidden in ("Sparkle", "SUFeedURL", "SUPublicEDKey"):
    if forbidden in current_app:
        raise SystemExit(f"current Malibu app retains legacy update authority: {forbidden}")
if re.search(r"^packages:\s*", current_app, re.MULTILINE):
    raise SystemExit("current Malibu app must remain dependency-free")
app_sign = publish.split("- name: Sign + notarize + staple Malibu.app", 1)[1].split(
    "\n      - name:", 1
)[0]
first_bundle_write = app_sign.find(
    'cp "$WORK/macprovider-cli" "$APP/Contents/MacOS/macprovider-cli"'
)
compatibility_copy = app_sign.find(
    'cp "$WORK/compatibility-set.json" "$APP/Contents/Resources/compatibility-set.json"'
)
anchor_prepare = app_sign.find("prepare-malibu-bootstrap-trust-anchor.py prepare")
anchor_verify = app_sign.find("prepare-malibu-bootstrap-trust-anchor.py verify")
app_codesign = app_sign.find("codesign --force --deep")
if min(first_bundle_write, compatibility_copy, anchor_prepare, anchor_verify, app_codesign) < 0 or not (
    anchor_prepare < first_bundle_write < compatibility_copy < anchor_verify < app_codesign
):
    raise SystemExit(
        "Malibu app must be preflighted before bundle writes and reverified before codesign"
    )
if app_sign.count("prepare-malibu-bootstrap-trust-anchor.py prepare") != 1:
    raise SystemExit("Malibu signing must prepare the one-time trust anchor exactly once")
if app_sign.count("prepare-malibu-bootstrap-trust-anchor.py verify") != 1:
    raise SystemExit("Malibu signing must reverify the bundled trust posture exactly once")
if 'mkdir -p "$APP/Contents/Resources"' in app_sign:
    raise SystemExit("Malibu signing must not mutate bundle paths before trust preflight")
for requirement in (
    'tag="${{ needs.build.outputs.tag }}"',
    "scripts/dist/malibu-v1.8.32-sparkle-public-key",
    '/usr/bin/otool -L "$APP/Contents/MacOS/Malibu"',
    "Malibu bridge must not link a Sparkle runtime",
):
    if requirement not in app_sign:
        raise SystemExit(f"Malibu signing omits trust-continuity guard: {requirement}")
for requirement in (
    'BRIDGE_TAG = "v1.8.39"',
    'BRIDGE_VERSION = "1.8.39"',
    'BRIDGE_BUILD = "39"',
    'EXPECTED_PUBLIC_KEY = "JkTDWnRJfOI3YIlpfJKvasWkxb0O1j/7ObGYiIA7big="',
    'key.startswith("SU")',
    'document["SUPublicEDKey"] = key',
    "os.replace(temporary_path, path)",
    "stat.S_ISREG",
    "candidate.is_symlink()",
    'require_directory(contents / "MacOS"',
    'require_directory(contents / "Resources"',
):
    if requirement not in trust_anchor_helper:
        raise SystemExit(f"trust-anchor helper omits fail-closed control: {requirement}")
for requirement in (
    "prepare-malibu-bootstrap-trust-anchor.py",
    "malibu-v1.8.32-sparkle-public-key",
    '/usr/bin/otool -L "$app_path/Contents/MacOS/Malibu"',
    "Malibu must not link a Sparkle runtime",
):
    if requirement not in malibu_artifact_verifier:
        raise SystemExit(f"final Malibu artifact verification omits: {requirement}")
if publish.count("Generate one-time Malibu 1.8.32 bootstrap bridge") != 1:
    raise SystemExit("release workflow must contain exactly one named bootstrap generator")
if publish.count("Publish one-time Malibu 1.8.32 bootstrap bridge to Pearl") != 1:
    raise SystemExit("release workflow must contain exactly one named bootstrap publisher")
bridge = publish.split("- name: Generate one-time Malibu 1.8.32 bootstrap bridge", 1)[1].split(
    "\n      - name:", 1
)[0]
pearl_bridge = publish.split(
    "- name: Publish one-time Malibu 1.8.32 bootstrap bridge to Pearl", 1
)[1].split("\n      - name:", 1)[0]
if "if: needs.build.outputs.tag == 'v1.8.39'" not in bridge:
    raise SystemExit("legacy appcast generation is not frozen to v1.8.39")
if "SPARKLE_EDDSA_PRIVATE_KEY" not in bridge or "verify-malibu-sparkle-signature.py" not in bridge:
    raise SystemExit("legacy appcast lacks protected signing or frozen-key verification")
if "if: needs.build.outputs.tag == 'v1.8.39' && needs.build.outputs.prerelease == 'false'" not in pearl_bridge:
    raise SystemExit("Pearl bridge publication is not frozen to stable v1.8.39")
for requirement in (
    "publish-malibu-latest-dmg.sh",
    "publication-manifest.json",
    "compatibility-artifact-index.json",
    "checksums.txt.sig",
):
    if requirement not in pearl_bridge:
        raise SystemExit(f"Pearl bootstrap publication omits {requirement}")
if publish.find("Publish one-time Malibu 1.8.32 bootstrap bridge to Pearl") < publish.find(
    "cmp final-draft-manifest.json publication-manifest.json"
):
    raise SystemExit("Pearl bridge must publish only after immutable GitHub publication")
team_requirement = (
    '-R="identifier \\"live.streamvc.macprovider.cli\\" and anchor apple generic '
    'and certificate leaf[subject.OU] = \\"$APPLE_NOTARY_TEAM_ID\\""'
)
if publish.count(team_requirement) != 2:
    raise SystemExit("CLI and bundled CLI must evaluate the exact Team ID requirement semantically")
if 'grep -F "certificate leaf[subject.OU]' in publish:
    raise SystemExit("release workflow must not parse codesign requirement display formatting")
if '"repos/$GITHUB_REPOSITORY/releases/$release_id"' not in publish:
    raise SystemExit("post-create verification must re-fetch the captured numeric release id")
if "ensure-release-tag-target" in text or "git push" in text:
    raise SystemExit("release workflow must not create a release tag")
if "gh release download" in text:
    raise SystemExit("release workflow must publish the captured workflow files")
if "actions/upload-artifact@v" in text or "actions/download-artifact@v" in text:
    raise SystemExit("artifact actions must be pinned by commit")
pearl_build = validate_pearl_toolchain(build)
for requirement in (
    "GOTOOLCHAIN=local",
    "CGO_ENABLED=0 GOOS=linux GOARCH=amd64",
    "go build -mod=readonly -trimpath",
    "coordinator-linux-amd64",
    "coordinator-cli-linux-amd64",
    "gateway-linux-amd64",
):
    if requirement not in pearl_build:
        raise SystemExit(f"reviewed Pearl build contract is missing: {requirement}")
setup_override_mutation = build.replace(
    "\n      - name: Build Pearl linux-amd64 binaries\n",
    "\n      - name: Override Pearl Go version\n"
    f'        uses: "ACTIONS/setup-go@{PEARL_SETUP_GO_SHA}"\n'
    "        with:\n"
    '          go-version: "1.26.4"\n'
    "\n      - name: Build Pearl linux-amd64 binaries\n",
    1,
)
seal_replacement_mutation = build.replace(PEARL_GO_SEAL_STEP, "        run: true", 1)
seal_failure_suppression_mutation = build.replace(
    PEARL_GO_SEAL_STEP,
    PEARL_GO_SEAL_STEP.replace(
        "        run: |\n",
        "        run: |\n          set +e\n",
        1,
    ),
    1,
)
post_seal_override_mutation = build.replace(
    "\n      - name: Build package\n",
    "\n      - name: Override sealed Pearl Go\n"
    "        run: sudo cp /bin/true /usr/local/lib/macprovider-go-verifier/bin/go\n"
    "\n      - name: Build package\n",
    1,
)
sealed_requirement_removal_mutation = build.replace(
    "          CATALOG_RELEASE_REQUIRE_SEALED_GO_VERIFIER=1 \\\n",
    "",
    1,
)
verifier_replacement_mutation = build.replace(PEARL_GO_VERIFY_STEP, "        run: true", 1)
verifier_suppression_mutation = build.replace(
    PEARL_GO_VERIFY_STEP,
    PEARL_GO_VERIFY_STEP.replace(
        "        run: |\n",
        "        run: |\n          set +e\n",
        1,
    ),
    1,
)
compound_mutation = setup_override_mutation.replace(PEARL_GO_VERIFY_STEP, "        run: true", 1)
post_verify_overwrite_mutation = build.replace(
    PEARL_VERIFY_UPLOAD_SEQUENCE,
    "\n      - name: Verify staged Pearl Go binaries\n"
    f"{PEARL_GO_VERIFY_STEP}\n"
    "\n      - name: Replace verified Pearl binary\n"
    "        run: cp /bin/true unsigned-release-inputs/coordinator-linux-amd64\n"
    "\n      - name: Upload unsigned build artifact\n",
    1,
)
build_role_substitution_mutation = build.replace(
    '-o "$RUNNER_TEMP/coordinator-cli-linux-amd64" ./cmd/coordinator-cli',
    '-o "$RUNNER_TEMP/coordinator-cli-linux-amd64" ./cmd/coordinator',
    1,
)
coordinator_role_substitution_mutation = build.replace(
    '-o "$RUNNER_TEMP/coordinator-linux-amd64" ./cmd/coordinator',
    '-o "$RUNNER_TEMP/coordinator-linux-amd64" ./cmd/coordinator-cli',
    1,
)
gateway_role_substitution_mutation = build.replace(
    '-o "$RUNNER_TEMP/gateway-linux-amd64" ./cmd/gateway',
    '-o "$RUNNER_TEMP/gateway-linux-amd64" ./cmd/coordinator',
    1,
)
for description, mutation in (
    ("case-folded setup-go override", setup_override_mutation),
    ("toolchain seal replacement", seal_replacement_mutation),
    ("toolchain seal failure suppression", seal_failure_suppression_mutation),
    ("post-seal toolchain override", post_seal_override_mutation),
    ("sealed verifier requirement removal", sealed_requirement_removal_mutation),
    ("binary verifier replacement", verifier_replacement_mutation),
    ("binary verifier failure suppression", verifier_suppression_mutation),
    ("compound setup-go/verifier replacement", compound_mutation),
    ("post-verification binary overwrite", post_verify_overwrite_mutation),
    ("Pearl build role substitution", build_role_substitution_mutation),
    ("coordinator build role substitution", coordinator_role_substitution_mutation),
    ("gateway build role substitution", gateway_role_substitution_mutation),
):
    try:
        validate_pearl_toolchain(mutation)
    except SystemExit:
        continue
    raise SystemExit(f"{description} mutation unexpectedly passed")
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
index_position = prepare.find("scripts/compatibility-artifact-index.py build")
provenance_position = prepare.find("scripts/build-release-provenance.py")
if (
    metadata_position < 0
    or index_position < metadata_position
    or provenance_position < index_position
    or 'release_assets+=("$compatibility_artifact_index")' not in prepare
):
    raise SystemExit("exact compatibility artifact index must bind Pearl metadata before provenance")
appcast_position = prepare.find('release_assets+=("$appcast_asset")')
if appcast_position < 0 or appcast_position > provenance_position:
    raise SystemExit("v1.8.39 appcast must enter signed provenance and checksums")
if 'if [ "$tag" = v1.8.39 ]' not in prepare or 'legacy appcast must exist only for v1.8.39' not in prepare:
    raise SystemExit("release assets do not fail closed outside the one-time bridge tag")
for requirement in (
    "provider_cli=$tar_asset",
    "malibu_app=$app_dmg_asset",
    "coordinator=$coordinator_asset",
    "coordinator_cli=$coordinator_cli_asset",
    "gateway=$gateway_asset",
    "compatibility_manifest=$compatibility_manifest",
    "catalog_trusted_keys=trusted-keys.json",
    "catalog_tier2=tier2-catalog.json",
    "pearl_metadata=$pearl_metadata",
    "pearl_metadata_signature=$pearl_metadata_sig",
):
    if requirement not in prepare:
        raise SystemExit(f"compatibility artifact index omits required role: {requirement}")
if "ops/pearl-updater/release-signing-public.pem" not in prepare:
    raise SystemExit("Pearl metadata signature is not checked against the updater trust anchor")
for asset in (
    "release.json",
    "trusted-keys.json",
    "tier2-catalog.json",
    "autotune-candidates.json",
    "autotune-candidates.json.sig",
    "demand-rank.json",
    "demand-rank.json.sig",
):
    if asset not in prepare:
        raise SystemExit(f"signed Pearl transaction omits catalog asset: {asset}")
if '"catalog": {' not in prepare or '"files": catalog_files' not in prepare:
    raise SystemExit("signed Pearl metadata does not bind catalog identity and file digests")
if 'provider_admission_policy:' not in text:
    raise SystemExit("release workflow omits the provider admission policy input")
for requirement in (
    'PROVIDER_ADMISSION_POLICY_INPUT:',
    'rollout_mode == "bridge_required"',
    'rollout_mode == "strict_post_migration"',
    '"enforce_provider_admission": False',
    '"enforce_provider_admission": True',
    '"bridge_duration_s": 86400',
    '"bridge_duration_s": 0',
    '"provider_admission_rollout": rollout',
):
    if requirement not in prepare:
        raise SystemExit(f"signed Pearl metadata omits rollout policy: {requirement}")
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
if "Clean Apple signing material after notarization" not in publish:
    raise SystemExit("Apple keychain and private material must be deleted after notarization")
if publish.find("Clean Apple signing material after notarization") > publish.find(
    "Generate one-time Malibu 1.8.32 bootstrap bridge"
):
    raise SystemExit("Apple private material must be removed before third-party Sparkle tools run")
create = publish.split("- name: Create verified draft GitHub release", 1)[1].split("\n      - name:", 1)[0]
verify_draft = publish.split("- name: Verify draft release assets by numeric ID", 1)[1].split("\n      - name:", 1)[0]
make_public = publish.split("- name: Publish only the revalidated numeric draft", 1)[1].split("\n      - name:", 1)[0]
discovery_gate = publish.find("- name: Require an advancing immutable discovery head")
draft_position = publish.find("- name: Create verified draft GitHub release")
if discovery_gate < 0 or draft_position < 0 or discovery_gate > draft_position:
    raise SystemExit("stable release must verify monotonic discovery before draft creation")
for requirement in (
    "scripts/verify-release-discovery-transport.py",
    "--minimum-sequence",
    "--allow-expired",
    'release.get("immutable") is not True',
):
    if requirement not in publish[discovery_gate:draft_position]:
        raise SystemExit(f"stable release discovery gate omits: {requirement}")
if 'discovery_tag="release-discovery"' in publish or "gh release upload \"$discovery_tag\"" in publish:
    raise SystemExit("release workflow still mutates the permanently immutable fixed discovery release")
transport_position = publish.find("- name: Publish one append-only immutable discovery transport")
if transport_position < draft_position:
    raise SystemExit("append-only discovery transport must publish after the numeric release")
transport_publish = publish[transport_position:].split("\n      - name:", 1)[0]
for requirement in (
    'git ls-remote --tags origin "$transport_tag"',
    "--prerelease",
    "--latest=false",
    "--transport-tag \"$transport_tag\"",
    "--require-immutable",
):
    if requirement not in transport_publish:
        raise SystemExit(f"append-only release transport omits: {requirement}")
if "--clobber" in transport_publish:
    raise SystemExit("append-only discovery transport must never overwrite an asset")
renewal = (
    pathlib.Path(sys.argv[1]).resolve().parent / "renew-release-discovery-head.yml"
).read_text(encoding="utf-8")
for requirement in (
    "environment: production-release",
    "scripts/build-release-discovery-head.py",
    "--minimum-sequence",
    "--require-immutable",
    "scripts/verify-anonymous-release-discovery.sh",
    '--issued-at "$issued_at"',
    '--expires-at "$expires_at"',
    "timedelta(hours=hours)",
):
    if requirement not in renewal:
        raise SystemExit(f"protected discovery renewal omits: {requirement}")
if "--clobber" in renewal or 'gh release create "release-discovery"' in renewal:
    raise SystemExit("protected discovery renewal must stay append-only")
if "--draft" not in create or create.find("scripts/verify-release-checksums.sh") > create.find("gh release create"):
    raise SystemExit("GitHub publication must verify canonical checksums before creating a draft")
if (
    "gh release view \"$tag\"" not in create
    or "verify-release-draft-identity.py cli" not in create
    or "draft-release-id.txt" not in create
    or "capture-release-publication.py --draft --notes-file release-notes.md" not in verify_draft
    or "draft-release-id.txt" not in verify_draft
):
    raise SystemExit("draft assets and numeric release ID must be captured before publication")
if 'releases/tags/$tag' in verify_draft:
    raise SystemExit("REST tag lookup cannot discover a draft release")
patch_position = make_public.find("gh api --method PATCH")
if patch_position < 0:
    raise SystemExit("verified draft must be made public by numeric-ID PATCH")
for requirement in (
    "scripts/verify-release-source.sh",
    "scripts/verify-github-release-posture.sh",
    "scripts/verify-release-checksums.sh",
    "gh release view \"$tag\"",
    "final-draft-cli.json",
    "final-draft-by-id.json",
    "verify-release-draft-identity.py cli",
    "verify-release-draft-identity.py api",
    "capture-release-publication.py --draft",
):
    if make_public.find(requirement) < 0 or make_public.find(requirement) > patch_position:
        raise SystemExit(f"final public-transition gate is missing or late: {requirement}")
if 'releases/tags/$tag' in make_public[:patch_position]:
    raise SystemExit("final draft verification cannot use the public-only REST tag lookup")
if "--require-existing" not in make_public[make_public.find("scripts/verify-release-source.sh"):patch_position]:
    raise SystemExit("final public-transition source gate must explicitly require the tag")
if make_public.find("immutable-release-by-id.json", patch_position) < 0 or make_public.find(
    "capture-release-publication.py", patch_position
) < 0:
    raise SystemExit("published numeric release must be re-fetched and required immutable")
if "cmp final-draft-manifest.json publication-manifest.json" not in make_public[patch_position:]:
    raise SystemExit("published release must exactly preserve the verified draft manifest")
if "capture-release-publication.py --draft --notes-file release-notes.md" not in make_public[:patch_position]:
    raise SystemExit("final draft capture must bind the reviewed release notes")
if "capture-release-publication.py --notes-file release-notes.md" not in make_public[patch_position:]:
    raise SystemExit("published release capture must bind the reviewed release notes")
for requirement in (
    "verify-published-release.py",
    "stable-latest-release.json",
    '"$release_id" "$PRERELEASE_INPUT"',
):
    if make_public.find(requirement, patch_position) < 0:
        raise SystemExit(f"post-publication release-state verification is missing: {requirement}")
anonymous = publish.find("- name: Verify anonymous signed discovery for stable release")
if anonymous < transport_position or '"$(cat discovery-transport-tag.txt)"' not in publish[anonymous:]:
    raise SystemExit("anonymous client proof is not bound to the published append-only transport")
PY

python3 "$pearl_go_verifier" --self-test

for requirement in \
  '### 8.1 Frozen v1.8.39 pre-publication tag recovery' \
  '3aa5b37ac774100902179b21fd3bb35bc8075c4e' \
  '2d8b0849efe9bb09803296fb375324daed80220c' \
  '29425477660' \
  "refs/recovery/\$TAG-old" \
  "--force-with-lease=\"refs/tags/\$TAG:\$OLD_TAG_OBJECT\"" \
  "--force-with-lease=\"refs/tags/\$TAG:\"" \
  '-f provider_admission_policy=bridge_required' \
  "RUN_ID=\"\$NEW_RUN_IDS\"" \
  'Build unsigned release inputs from reviewed main' \
  'Sign and publish reviewed release' \
  "actions/runs/\$RUN_ID/pending_deployments" \
  '.reviewer.login=="antfleet-ops"' \
  'This exception is permanently closed' \
  'no second deletion, update, or recovery is permitted'; do
  grep -Fq -- "$requirement" "$release_runbook" || {
    echo "release runbook omits frozen v1.8.39 recovery control: $requirement" >&2
    exit 1
  }
done
python3 - "$release_runbook" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
start = text.index("### 8.1 Frozen v1.8.39 pre-publication tag recovery")
end = text.index("Steps 11-13 execute only in normal production mode.", start)
recovery = text[start:end]

for unsafe in (
    'test -z "$(' ,
    'test "$(curl',
    'test "$(gh api',
    'test "$(git ls-remote',
    'export GH_TOKEN="$(gh auth token',
    "! curl -fsSL",
):
    if unsafe in recovery:
        raise SystemExit(f"v1.8.39 recovery can mistake lookup failure for absence: {unsafe}")

ordered = (
    "gh workflow run release.yml",
    'RUN_ID="$NEW_RUN_IDS"',
    'actions/runs/$RUN_ID"',
    "Build unsigned release inputs from reviewed main",
    "Sign and publish reviewed release",
    "actions/runs/$RUN_ID/pending_deployments",
    "git fetch origin refs/heads/main:refs/remotes/origin/main",
    'REMOTE_TAG_BEFORE_CREATE="$(git ls-remote origin refs/tags/$TAG',
    'releases?per_page=100',
    "https://download.malibu.tech/Malibu-v1.8.39.dmg",
    'PUBLIC_APPCAST_BEFORE_CREATE="$(curl -fsSL',
    "<sparkle:shortVersionString>1.8.39</sparkle:shortVersionString>",
    'git tag -s "$TAG"',
)
cursor = 0
for marker in ordered:
    position = recovery.find(marker, cursor)
    if position < 0:
        raise SystemExit(
            f"v1.8.39 recovery does not enforce ordered run/tag gate: {marker}"
        )
    cursor = position + len(marker)

for marker in (
    'releases?per_page=100',
    "https://download.malibu.tech/Malibu-v1.8.39.dmg",
    "<sparkle:shortVersionString>1.8.39</sparkle:shortVersionString>",
):
    if recovery.count(marker) < 3:
        raise SystemExit(
            f"v1.8.39 recovery must gate initial, pre-delete, and pre-create state: {marker}"
        )

for marker in (
    'test "$(git rev-parse HEAD)" = "$NEW_COMMIT"',
    'test "$NEW_COMMIT" != "$OLD_COMMIT"',
):
    if recovery.count(marker) < 3:
        raise SystemExit(
            f"v1.8.39 recovery must gate initial, pre-delete, and pre-create commit: {marker}"
        )
    if recovery.index(marker) > recovery.index(
        '--force-with-lease="refs/tags/$TAG:$OLD_TAG_OBJECT"'
    ):
        raise SystemExit(
            f"v1.8.39 recovery must reject the failed commit before tag deletion: {marker}"
        )

delete_position = recovery.index(
    '--force-with-lease="refs/tags/$TAG:$OLD_TAG_OBJECT"'
)
for marker in (
    'RELEASE_IDS_BEFORE_DELETE="$(gh api --paginate',
    'PUBLIC_APPCAST_BEFORE_DELETE="$(curl -fsSL',
    'select(.status!="completed")] | length',
):
    position = recovery.find(marker)
    if position < 0 or position > delete_position:
        raise SystemExit(
            f"v1.8.39 recovery must close mutable-state races before deletion: {marker}"
        )

for marker in (
    '.head_sha)\" = \"$NEW_COMMIT\"',
    "$'completed\\tsuccess'",
    "$'waiting\\t'",
    '.environment.name=="production-release"',
    '.reviewer.login=="antfleet-ops"',
    '.reviewer.id==285575208',
    '.status=="completed" and .conclusion=="success"',
    '.status=="waiting" and .conclusion==null',
    'select(.status!="completed" and .id!=$run)',
    'GH_TOKEN="$(gh auth token -u Augustas11)"',
    'REMOTE_MAIN_SHA_BEFORE="$(git ls-remote',
    'RELEASE_IDS_BEFORE="$(gh api --paginate',
    'FAILED_RUN_STATE="$(gh api',
    'ACTIVE_RELEASE_RUNS_BEFORE="$(gh api',
    'CI_REQUIRED_SUCCESSES="$(gh api',
    'PUBLIC_DMG_STATUS_BEFORE="$(curl',
    'REMOTE_MAIN_SHA_BEFORE_DELETE="$(git ls-remote',
    'ACTIVE_RELEASE_RUNS_BEFORE_DELETE="$(gh api',
    'RELEASE_IDS_BEFORE_DELETE="$(gh api --paginate',
    'PUBLIC_DMG_STATUS_BEFORE_DELETE="$(curl',
    'REMOTE_TAG_AFTER_DELETE="$(git ls-remote',
    'CAPTURED_RUN_IDENTITY="$(gh api',
    'REMOTE_MAIN_SHA_BEFORE_CREATE="$(git ls-remote',
    'REMOTE_TAG_BEFORE_CREATE="$(git ls-remote',
    'RUN_STATE_BEFORE_CREATE="$(gh api',
    'OTHER_ACTIVE_RELEASE_RUNS="$(gh api',
    'RELEASE_IDS_BEFORE_CREATE="$(gh api --paginate',
    'PUBLIC_DMG_STATUS_BEFORE_CREATE="$(curl',
    'PUBLIC_APPCAST_BEFORE="$(curl -fsSL',
    'PUBLIC_APPCAST_BEFORE_DELETE="$(curl -fsSL',
    'REMOTE_NEW_TAG_OBJECT="$(git ls-remote',
    'REMOTE_NEW_TAG_COMMIT="$(git ls-remote',
    'verify-github-release-posture.sh',
):
    if marker not in recovery:
        raise SystemExit(f"v1.8.39 recovery omits exact-run safety assertion: {marker}")
PY
for requirement in \
  'Entry 157 — Retire and re-create the unpublished v1.8.39 tag' \
  '3aa5b37ac774100902179b21fd3bb35bc8075c4e' \
  'This authority expires when the replacement v1.8.39 ref is created'; do
  grep -Fq -- "$requirement" "$decision_log" || {
    echo "decision log omits frozen v1.8.39 recovery boundary: $requirement" >&2
    exit 1
  }
done
for requirement in \
  'sparkle_commit="0ef1ee0220239b3776f433314515fd849025673f"' \
  'sparkle_remote="https://github.com/sparkle-project/Sparkle.git"' \
  'testEphemeralEdDSAKeyContinuityForApplicationUpdate' \
  'CODE_SIGNING_ALLOWED=NO'; do
  grep -Fq -- "$requirement" "$sparkle_validator_integration" || {
    echo "Sparkle validator integration omits pinned control: $requirement" >&2
    exit 1
  }
done
for requirement in \
  'targetContainsKey: true' \
  'targetContainsKey: false' \
  'SUSparkleErrorDomain' \
  'only supports rotation, but not removal'; do
  grep -Fq -- "$requirement" "$sparkle_validator_patch" || {
    echo "Sparkle validator fixture omits continuity assertion: $requirement" >&2
    exit 1
  }
done
generator_ci_position="$(grep -nF 'bash scripts/test-malibu-sparkle-generator-integration.sh' \
  "$ci_workflow" | cut -d: -f1)"
validator_ci_position="$(grep -nF 'bash scripts/test-malibu-sparkle-validator-integration.sh' \
  "$ci_workflow" | cut -d: -f1)"
[[ -n "$generator_ci_position" && -n "$validator_ci_position" && \
  "$generator_ci_position" -lt "$validator_ci_position" ]] || {
  echo "macOS CI does not run generator then real Sparkle validator integration" >&2
  exit 1
}

python3 - "$xcodegen_installer" "$sparkle_generator" "$legacy_sparkle_key" <<'PY'
import pathlib
import sys

xcodegen = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
sparkle = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
legacy_key = pathlib.Path(sys.argv[3]).read_text(encoding="ascii")
xcodegen_digest = "090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef"
if xcodegen_digest not in xcodegen or xcodegen.find("shasum -a 256") > xcodegen.find("unzip -q"):
    raise SystemExit("XcodeGen artifact must be digest-pinned before extraction")
sparkle_digest = "50612a06038abc931f16011d7903b8326a362c1074dabccb718404ce8e585f0b"
if sparkle_digest not in sparkle or sparkle.find("shasum -a 256") > sparkle.find("tar -xJf"):
    raise SystemExit("legacy Sparkle tools must be digest-pinned before extraction")
if 'bridge_tag="v1.8.39"' not in sparkle or "SPARKLE_VERSION" in sparkle:
    raise SystemExit("legacy appcast generator is not frozen to one tag and tool version")
key_lines = [line.strip() for line in legacy_key.splitlines() if line.strip() and not line.startswith("#")]
if key_lines != ["JkTDWnRJfOI3YIlpfJKvasWkxb0O1j/7ObGYiIA7big="]:
    raise SystemExit("legacy public key differs from the SUPublicEDKey shipped in Malibu v1.8.32")
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
