#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
verifier="$root/scripts/verify-acceptance-promotion.py"
workflow="$root/.github/workflows/promote-acceptance-candidate.yml"
work="$(mktemp -d "${TMPDIR:-/tmp}/acceptance-promotion.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fail() {
  printf '[test-acceptance-promotion] ERROR: %s\n' "$*" >&2
  exit 1
}

python3 - "$workflow" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
SEALED_OUTPUT = 'OPENSSL_BIN: ${{ steps.protected_openssl.outputs.bin }}'
SEALED_RUNNER = "    runs-on: macos-15-intel"
protected, separator, public_verify = text.partition("\n  verify_public:\n")
if not separator:
    raise SystemExit("promotion workflow lacks isolated public verification job")
if protected.count(SEALED_RUNNER) != 1:
    raise SystemExit(
        "promotion runner must match the reviewed Intel OpenSSL bottle"
    )
for required in (
    "candidate_run_id:",
    "candidate_sha:",
    "tag:",
    "expected_checksums_sha256:",
    "physical_acceptance_confirmed:",
    "environment: production-release",
    "actions: read",
    "contents: write",
    "scripts/gate-production-exceptions-promote.sh",
    "Re-check production exceptions before draft creation",
    "bash scripts/gate-production-exceptions-promote.sh",
    "EXCEPTION_GATE_SHA_FILE=",
    "exception authority moved before undraft",
    "scripts/verify-acceptance-promotion.py verify-run",
    "scripts/verify-acceptance-promotion.py verify-directory",
    "scripts/verify-release-checksums.sh",
    "scripts/verify-release-discovery-transport.py",
    "scripts/verify-tier2-provider-release.sh",
    'cmp "$accepted/$name" "$download/$name"',
):
    if required not in text:
        raise SystemExit(f"promotion workflow omits required control: {required}")
for forbidden in ("bash candidate/", "candidate/scripts/", "release.yml"):
    if forbidden in text:
        raise SystemExit(f"promotion workflow can execute or rebuild candidate code: {forbidden}")
for match in re.finditer(r"^\s*uses:\s*(\S+)", text, re.MULTILINE):
    value = match.group(1)
    if not re.fullmatch(r"[^@\s]+@[0-9a-f]{40}", value):
        raise SystemExit(f"promotion action is not commit-pinned: {value}")
if text.count('out "$accepted/checksums.txt.sig"') != 1:
    raise SystemExit("promoter must generate only one new release asset")
for requirement in (
    "- name: Seal reviewed OpenSSL 3",
    "id: protected_openssl",
    "scripts/install-sealed-release-openssl.sh",
    "/private/var/macprovider-openssl-acceptance-promotion",
    "printf 'bin=%s\\n' \"$sealed_bin\" >> \"$GITHUB_OUTPUT\"",
):
    if requirement not in text:
        raise SystemExit(f"promotion OpenSSL seal omits: {requirement}")
if "brew install openssl@3" in text or "brew --prefix openssl@3" in text:
    raise SystemExit("promotion must not select mutable Homebrew OpenSSL directly")
if "OPENSSL_BIN=" in text or "GITHUB_ENV" in text:
    raise SystemExit("promotion must not publish mutable OpenSSL environment state")
if text.count(SEALED_OUTPUT) != 4:
    raise SystemExit("every promotion crypto consumer must bind the sealed step output")
for step_name in (
    "Verify the signed acceptance set and production metadata",
    "Require an advancing immutable discovery head",
    "Generate only the production checksum signature",
    "Reverify and publish only the captured numeric draft",
):
    step = text.split(f"- name: {step_name}", 1)[1].split("\n      - name:", 1)[0]
    if step.count(SEALED_OUTPUT) != 1:
        raise SystemExit(f"{step_name} does not bind the sealed OpenSSL output")
for step_name in (
    "Generate only the production checksum signature",
    "Reverify and publish only the captured numeric draft",
):
    step = text.split(f"- name: {step_name}", 1)[1].split("\n      - name:", 1)[0]
    if (
        "scripts/verify-release-checksums.sh \\\n"
        '            --openssl "$OPENSSL_BIN" \\\n'
    ) not in step:
        raise SystemExit(
            f"{step_name} does not pass sealed OpenSSL to checksum verification"
        )
if "go build" in text or "xcodebuild" in text or "./package.sh" in text:
    raise SystemExit("protected promoter contains a build capability")
if "scripts/verify-tier2-provider-release.sh" in protected:
    raise SystemExit("candidate executable verification must be isolated from the protected promoter")
if "environment: production-release" in public_verify or "secrets." in public_verify:
    raise SystemExit("public executable verifier gained protected credentials")
if 'scripts/verify-release-tag-target.sh "$TAG" "$CANDIDATE_SHA" origin --require-existing' not in protected:
    raise SystemExit("promoter does not require the owner-created exact protected tag")
if "/git/refs" in protected or "-f ref=\"refs/tags/$TAG\"" in protected:
    raise SystemExit("promoter gained protected tag creation or mutation capability")
if 'git merge-base --is-ancestor "$CONTROL_SHA"' not in protected:
    raise SystemExit("acceptance signer control commit need not remain reachable from main")
if protected.count('scripts/verify-release-tag-target.sh "$TAG" "$CANDIDATE_SHA" origin --require-existing') < 2:
    raise SystemExit("exact protected tag is not revalidated immediately before publication")
publish_step = protected.split(
    "- name: Reverify and publish only the captured numeric draft", 1
)[1].split("\n      - name:", 1)[0]
pre_gate = publish_step.find("scripts/verify-live-coordinator-release-gate.py")
pre_gate_label = publish_step.rfind("echo \"::group::Verify pre-publication live coordinator feed gate\"", 0, pre_gate)
patch = publish_step.find("gh api --method PATCH")
final_draft_capture = publish_step.find("scripts/capture-release-publication.py --draft")
final_authority = publish_step.find("origin/main moved under bound exception authority before undraft")
if pre_gate < 0:
    raise SystemExit("promotion public-transition step omits the pre-publication live coordinator gate")
if patch < 0:
    raise SystemExit("promotion public-transition step lost numeric release PATCH")
if final_draft_capture < 0 or final_authority < 0:
    raise SystemExit("promotion public-transition step lost final draft or authority regate")
if pre_gate < final_draft_capture or pre_gate < final_authority:
    raise SystemExit("promotion pre-publication gate must run after final draft and authority regates")
if pre_gate > patch or publish_step.find("-F draft=false") < pre_gate:
    raise SystemExit("promotion pre-publication gate must run before undraft/latest publication")
if "--publication-phase pre-publication" not in publish_step[pre_gate:]:
    raise SystemExit("promotion pre-publication gate does not select the pre-publication policy")
for requirement in (
    "env -u GH_TOKEN -u RELEASE_POSTURE_TOKEN",
    "--tag \"$TAG\"",
    "--pearl-release-json \"$accepted/pearl-release.json\"",
    "--trusted-keys \"$accepted/trusted-keys.json\"",
    "--coordinator-url https://coordinator.streamvc.live",
    "--openssl \"$OPENSSL_BIN\"",
    "--expected-previous-recommendation 1.8.81",
):
    if requirement not in publish_step[pre_gate_label:]:
        raise SystemExit(f"promotion live coordinator gate omits: {requirement}")
rollout = pathlib.Path(sys.argv[1]).parent / "verify-live-coordinator-release-rollout.yml"
rollout_text = rollout.read_text(encoding="utf-8")
if (
    "workflow_dispatch:" not in rollout_text
    or "# Pearl recommendation deployment is the serialized external step" not in rollout_text
    or "--publication-phase post-publication" not in rollout_text
    or "scripts/verify-published-release.py" not in rollout_text
    or "contents: write" not in rollout_text
    or 'gh release create "$transport_tag"' not in rollout_text
):
    raise SystemExit("promotion must hand post-publication coordinator proof to the rollout workflow")
if '[\\"candidate_ref\\"]' in protected or '.removeprefix(\\"refs/heads/\\")' in protected:
    raise SystemExit("candidate ref extraction contains shell-literal Python escapes")
if 'print(json.load(open(sys.argv[1]))["candidate_ref"])' not in protected:
    raise SystemExit("promoter does not pass the signed candidate ref directly to verification")
discovery_gate = protected.find("- name: Require an advancing immutable discovery head")
draft_create = protected.find("- name: Create and fully verify a numeric draft")
if discovery_gate < 0 or draft_create < 0 or discovery_gate > draft_create:
    raise SystemExit("monotonic discovery validation must precede numeric draft creation")
for requirement in (
    "--minimum-sequence",
    "--allow-expired",
    '"repos/$GITHUB_REPOSITORY/releases/latest"',
    'release.get("immutable") is not True',
):
    if requirement not in protected[discovery_gate:draft_create]:
        raise SystemExit(f"promotion discovery gate omits: {requirement}")
if 'transport_tag="release-discovery-v1-$candidate_sequence"' not in protected[discovery_gate:draft_create]:
    raise SystemExit("promotion does not derive the transport tag from the signed sequence")
PY

repository=Augustas11/macprovider
run_id=29629457652
run_attempt=1
tag=v1.8.48
candidate_sha=1111111111111111111111111111111111111111
control_sha=2222222222222222222222222222222222222222
accepted="$work/accepted"
mkdir "$accepted"

release_names=(
  "Malibu-${tag}.dmg"
  "autotune-candidates.json"
  "autotune-candidates.json.sig"
  "compatibility-artifact-index.json"
  "compatibility-set.json"
  "coordinator-cli-linux-amd64"
  "coordinator-linux-amd64"
  "demand-rank.json"
  "demand-rank.json.sig"
  "rate-card.json"
  "rate-card.json.sig"
  "gateway-linux-amd64"
  "macprovider-release-discovery.json"
  "macprovider-release-discovery.json.sig"
  "macprovider-cli-${tag}-darwin-arm64.tar.gz"
  "pearl-release.json"
  "pearl-release.json.sig"
  "release-provenance.json"
  "release-toolchain.json"
  "release.json"
  "tier2-catalog.json"
  "trusted-keys.json"
)
printf '%s\n' "${release_names[@]}" | LC_ALL=C sort > "$accepted/release-assets.txt"
for name in "${release_names[@]}"; do
  printf 'fixture:%s\n' "$name" > "$accepted/$name"
done

cat > "$accepted/acceptance-candidate.json" <<EOF
{"candidate_commit":"$candidate_sha","candidate_ref":"refs/heads/release/referral-v1.8.48-candidate","channel":"acceptance","control_commit":"$control_sha","repository":"$repository","run_attempt":$run_attempt,"run_id":"$run_id","tag":"$tag"}
EOF
printf 'fixture-signature\n' > "$accepted/acceptance-candidate.json.sig"
cat > "$accepted/release-provenance.json" <<EOF
{"commit":"$candidate_sha","prerelease":false,"repository":"$repository","tag":"$tag"}
EOF
cat > "$accepted/compatibility-set.json" <<'EOF'
{"signed":{"components":{"coordinator_admission":{"rollout":{"bridge_duration_seconds":0,"enforce_provider_admission":true,"mode":"strict_post_migration"}},"provider_cli":{"version":"1.8.48"}},"release":{"commit":"1111111111111111111111111111111111111111","repository":"Augustas11/macprovider","tag":"v1.8.48","version":"1.8.48"}}}
EOF
python3 - "$accepted" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
digest = lambda name: hashlib.sha256((root / name).read_bytes()).hexdigest()
catalog_names = (
    "release.json",
    "trusted-keys.json",
    "tier2-catalog.json",
    "autotune-candidates.json",
    "autotune-candidates.json.sig",
    "demand-rank.json",
    "demand-rank.json.sig",
    "rate-card.json",
    "rate-card.json.sig",
)
value = {
    "architecture": "linux-amd64",
    "catalog": {
        "files": {name: digest(name) for name in catalog_names},
        "policy_version": "fixture-policy",
        "release_id": "fixture-release",
    },
    "channel": "production",
    "commit": "1" * 40,
    "components": {
        "coordinator": {
            "asset": "coordinator-linux-amd64",
            "embedded_version": "v1.8.48",
            "sha256": digest("coordinator-linux-amd64"),
        },
        "gateway": {
            "asset": "gateway-linux-amd64",
            "embedded_version": "v1.8.48",
            "sha256": digest("gateway-linux-amd64"),
        },
    },
    "operator_artifacts": {
        "coordinator_cli": {
            "asset": "coordinator-cli-linux-amd64",
            "sha256": digest("coordinator-cli-linux-amd64"),
        }
    },
    "provider_admission_rollout": {
        "bridge_duration_s": 0,
        "enforce_provider_admission": True,
        "mode": "strict_post_migration",
    },
    "provider_advertised_version": "1.8.48",
    "release_version": "1.8.48",
    "repository": "Augustas11/macprovider",
    "schema_version": 1,
    "tag": "v1.8.48",
}
(root / "pearl-release.json").write_text(
    json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$work/release-private.pem" >/dev/null 2>&1
openssl pkey -in "$work/release-private.pem" -pubout -out "$work/release-public.pem" >/dev/null 2>&1
sign_pearl() {
  openssl dgst -sha256 -sign "$work/release-private.pem" \
    -out "$accepted/pearl-release.json.sig" "$accepted/pearl-release.json"
}
sign_pearl
printf 'fixture checksums\n' > "$accepted/checksums.txt"
checksums_sha="$(shasum -a 256 "$accepted/checksums.txt" | awk '{print $1}')"

cat > "$work/run.json" <<EOF
{"conclusion":"success","event":"workflow_dispatch","head_branch":"main","head_sha":"$control_sha","id":$run_id,"path":".github/workflows/acceptance-candidate.yml","repository":{"full_name":"$repository"},"run_attempt":$run_attempt,"status":"completed"}
EOF
cat > "$work/artifacts.json" <<EOF
{"artifacts":[{"expired":false,"name":"unsigned-acceptance-$candidate_sha","workflow_run":{"id":$run_id}},{"expired":false,"name":"acceptance-candidate-$candidate_sha","workflow_run":{"id":$run_id}}],"total_count":2}
EOF

run_verify=(
  python3 "$verifier" verify-run
  --run-json "$work/run.json"
  --artifacts-json "$work/artifacts.json"
  --repository "$repository"
  --run-id "$run_id"
  --run-attempt "$run_attempt"
  --candidate-sha "$candidate_sha"
  --control-sha "$control_sha"
)
directory_verify=(
  python3 "$verifier" verify-directory
  --directory "$accepted"
  --repository "$repository"
  --run-id "$run_id"
  --run-attempt "$run_attempt"
  --tag "$tag"
  --candidate-sha "$candidate_sha"
  --control-sha "$control_sha"
  --expected-checksums-sha256 "$checksums_sha"
  --release-public-key "$work/release-public.pem"
)
"${run_verify[@]}"
"${directory_verify[@]}"

cp "$accepted/compatibility-set.json" "$work/compatibility.strict"
cp "$accepted/pearl-release.json" "$work/pearl.strict"
python3 - "$accepted/compatibility-set.json" "$accepted/pearl-release.json" <<'PY'
import json
import pathlib
import sys

compatibility_path = pathlib.Path(sys.argv[1])
compatibility = json.loads(compatibility_path.read_text())
compatibility["signed"]["components"]["coordinator_admission"]["rollout"] = {
    "bridge_duration_seconds": 86400,
    "enforce_provider_admission": False,
    "mode": "bridge_required",
}
compatibility_path.write_text(json.dumps(compatibility) + "\n")

pearl_path = pathlib.Path(sys.argv[2])
pearl = json.loads(pearl_path.read_text())
pearl["provider_admission_rollout"] = {
    "bridge_duration_s": 86400,
    "enforce_provider_admission": False,
    "mode": "bridge_required",
}
pearl_path.write_text(json.dumps(pearl) + "\n")
PY
sign_pearl
"${directory_verify[@]}"
mv "$work/compatibility.strict" "$accepted/compatibility-set.json"
mv "$work/pearl.strict" "$accepted/pearl-release.json"
sign_pearl

expect_reject() {
  local label="$1"
  shift
  if "$@" >"$work/$label.out" 2>&1; then
    fail "$label was accepted"
  fi
}

python3 - "$work/run.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
v = json.loads(p.read_text())
v["path"] = ".github/workflows/release.yml"
p.write_text(json.dumps(v))
PY
expect_reject wrong-workflow "${run_verify[@]}"
python3 - "$work/run.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text())
value["path"] = ".github/workflows/acceptance-candidate.yml"
path.write_text(json.dumps(value))
PY

cp "$work/artifacts.json" "$work/artifacts.valid"
python3 - "$work/artifacts.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
v = json.loads(p.read_text())
v["artifacts"].append(dict(v["artifacts"][-1]))
v["total_count"] += 1
p.write_text(json.dumps(v))
PY
expect_reject duplicate-artifact "${run_verify[@]}"
mv "$work/artifacts.valid" "$work/artifacts.json"

printf 'unexpected\n' > "$accepted/unexpected"
expect_reject extra-file "${directory_verify[@]}"
rm "$accepted/unexpected"

mv "$accepted/gateway-linux-amd64" "$work/gateway"
expect_reject missing-file "${directory_verify[@]}"
mv "$work/gateway" "$accepted/gateway-linux-amd64"

ln -s gateway-linux-amd64 "$accepted/unexpected"
expect_reject symlink "${directory_verify[@]}"
rm "$accepted/unexpected"

ln "$accepted/gateway-linux-amd64" "$accepted/unexpected"
expect_reject hardlink "${directory_verify[@]}"
rm "$accepted/unexpected"

cp "$accepted/release-provenance.json" "$work/provenance"
python3 - "$accepted/release-provenance.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
v = json.loads(p.read_text())
v["prerelease"] = True
p.write_text(json.dumps(v) + "\n")
PY
expect_reject prerelease "${directory_verify[@]}"
mv "$work/provenance" "$accepted/release-provenance.json"

cp "$accepted/pearl-release.json" "$work/pearl"
python3 - "$accepted/pearl-release.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
v = json.loads(p.read_text())
v["channel"] = "private_acceptance"
p.write_text(json.dumps(v) + "\n")
PY
expect_reject private-channel "${directory_verify[@]}"
mv "$work/pearl" "$accepted/pearl-release.json"

cp "$accepted/pearl-release.json.sig" "$work/pearl.sig"
printf 'invalid\n' > "$accepted/pearl-release.json.sig"
expect_reject wrong-pearl-signature "${directory_verify[@]}"
mv "$work/pearl.sig" "$accepted/pearl-release.json.sig"

cp "$accepted/pearl-release.json" "$work/pearl"
python3 - "$accepted/pearl-release.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
v = json.loads(p.read_text())
v["provider_admission_rollout"]["mode"] = "bridge_required"
p.write_text(json.dumps(v) + "\n")
PY
sign_pearl
expect_reject admission-mismatch "${directory_verify[@]}"
mv "$work/pearl" "$accepted/pearl-release.json"
sign_pearl

expect_reject wrong-checksums-digest \
  python3 "$verifier" verify-directory \
  --directory "$accepted" \
  --repository "$repository" \
  --run-id "$run_id" \
  --run-attempt "$run_attempt" \
  --tag "$tag" \
  --candidate-sha "$candidate_sha" \
  --control-sha "$control_sha" \
  --expected-checksums-sha256 0000000000000000000000000000000000000000000000000000000000000000 \
  --release-public-key "$work/release-public.pem"

printf '%s\n' "${release_names[@]}" "gateway-linux-amd64" | LC_ALL=C sort > "$accepted/release-assets.txt"
expect_reject duplicate-basename "${directory_verify[@]}"
printf '%s\n' "${release_names[@]}" | LC_ALL=C sort > "$accepted/release-assets.txt"

printf '[test-acceptance-promotion] ok: exact accepted-byte promotion fails closed\n'
