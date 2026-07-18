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
for required in (
    "candidate_run_id:",
    "candidate_sha:",
    "tag:",
    "expected_checksums_sha256:",
    "physical_acceptance_confirmed:",
    "environment: production-release",
    "actions: read",
    "contents: write",
    "scripts/verify-acceptance-promotion.py verify-run",
    "scripts/verify-acceptance-promotion.py verify-directory",
    "scripts/verify-release-checksums.sh",
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
if "go build" in text or "xcodebuild" in text or "./package.sh" in text:
    raise SystemExit("protected promoter contains a build capability")
protected, separator, public_verify = text.partition("\n  verify_public:\n")
if not separator or "scripts/verify-tier2-provider-release.sh" in protected:
    raise SystemExit("candidate executable verification must be isolated from the protected promoter")
if "environment: production-release" in public_verify or "secrets." in public_verify:
    raise SystemExit("public executable verifier gained protected credentials")
if "GH_TOKEN: ${{ secrets.RELEASE_POSTURE_TOKEN }}" not in protected:
    raise SystemExit("tag creation does not use the configured protected tagger identity")
if '[[ "$tagger_id" == 28995904 ]]' not in protected:
    raise SystemExit("protected tag credential is not verified against the ruleset actor")
if 'git merge-base --is-ancestor "$CONTROL_SHA"' not in protected:
    raise SystemExit("acceptance signer control commit need not remain reachable from main")
if 'If-Match: $draft_etag' not in protected:
    raise SystemExit("numeric draft publication lacks a conditional mutation guard")
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
  "gateway-linux-amd64"
  "macprovider-cli-${tag}-darwin-arm64.tar.gz"
  "pearl-release.json"
  "pearl-release.json.sig"
  "release-provenance.json"
  "release-toolchain.json"
  "release.json"
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
{"signed":{"components":{"coordinator_admission":{"rollout":{"bridge_duration_s":0,"enforce_provider_admission":true,"mode":"strict_post_migration"}},"provider_cli":{"version":"1.8.48"}},"release":{"commit":"1111111111111111111111111111111111111111","repository":"Augustas11/macprovider","tag":"v1.8.48","version":"1.8.48"}}}
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
    "autotune-candidates.json",
    "autotune-candidates.json.sig",
    "demand-rank.json",
    "demand-rank.json.sig",
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
openssl dgst -sha256 -sign "$work/release-private.pem" \
  -out "$accepted/pearl-release.json.sig" "$accepted/pearl-release.json"
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
sed -i '' 's#\\.github/workflows/release.yml#.github/workflows/acceptance-candidate.yml#' "$work/run.json"

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
expect_reject admission-mismatch "${directory_verify[@]}"
mv "$work/pearl" "$accepted/pearl-release.json"

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
