#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[sign-acceptance-candidate] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$#" == 10 ]] || die "usage: UNSIGNED_DIR OUTPUT_DIR REPOSITORY TAG CANDIDATE_REF CANDIDATE_COMMIT CONTROL_COMMIT RUN_ID RUN_ATTEMPT PROVIDER_ADMISSION_POLICY"
unsigned_dir="$1"
output_dir="$2"
repository="$3"
tag="$4"
candidate_ref="$5"
candidate_commit="$6"
control_commit="$7"
run_id="$8"
run_attempt="$9"
provider_admission_policy="${10}"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
metadata="$root/scripts/acceptance-candidate-metadata.py"
compatibility="$root/scripts/compatibility-set-manifest.py"
artifact_index="$root/scripts/compatibility-artifact-index.py"
keychain_helper="$root/scripts/acceptance-signing-keychain.sh"
acceptance_public_key="$root/security/acceptance-candidate-signing-public.pem"
openssl_bin="${OPENSSL_BIN:-openssl}"

[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "invalid repository"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid tag"
[[ "$candidate_ref" == refs/heads/* ]] || die "candidate ref must be a branch"
git check-ref-format --branch "${candidate_ref#refs/heads/}" >/dev/null 2>&1 || die "invalid candidate branch"
[[ "$candidate_commit" =~ ^[0-9a-f]{40}$ ]] || die "invalid candidate commit"
[[ "$control_commit" =~ ^[0-9a-f]{40}$ ]] || die "invalid control commit"
[[ "$(git -C "$root" rev-parse HEAD)" == "$control_commit" ]] || die "trusted signer checkout differs from control commit"
[[ "$run_id" =~ ^[1-9][0-9]*$ ]] || die "invalid run id"
[[ "$run_attempt" =~ ^[1-9][0-9]*$ ]] || die "invalid run attempt"
case "$provider_admission_policy" in
  bridge_required|strict_post_migration) ;;
  *) die "invalid provider admission policy" ;;
esac

for command in python3 security codesign xcrun ditto hdiutil tar shasum spctl base64 "$openssl_bin"; do
  command -v "$command" >/dev/null 2>&1 || die "required command is unavailable: $command"
done
for path in "$metadata" "$compatibility" "$artifact_index" "$keychain_helper" "$acceptance_public_key"; do
  [[ -f "$path" && ! -L "$path" ]] || die "trusted signer input is absent or unsafe: $path"
done
[[ -d "$unsigned_dir" && ! -L "$unsigned_dir" ]] || die "unsigned input directory is absent or unsafe"
[[ ! -e "$output_dir" && ! -L "$output_dir" ]] || die "output directory must not exist"

for secret in \
  APPLE_DEVELOPER_ID_CERT_P12_BASE64 \
  APPLE_DEVELOPER_ID_CERT_PASSWORD \
  APPLE_NOTARY_APPLE_ID \
  APPLE_NOTARY_PASSWORD \
  APPLE_NOTARY_TEAM_ID \
  MACPROVIDER_RELEASE_SIGNING_KEY_PEM \
  MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM; do
  [[ -n "${!secret:-}" ]] || die "protected secret is required: $secret"
done

cli_unsigned="$unsigned_dir/phase3-binary-m4-${tag}.tar.gz"
app_unsigned="$unsigned_dir/Malibu.app.tar.gz"
toolchain="$unsigned_dir/release-toolchain.json"
coordinator="$unsigned_dir/coordinator-linux-amd64"
coordinator_cli="$unsigned_dir/coordinator-cli-linux-amd64"
gateway="$unsigned_dir/gateway-linux-amd64"
unsigned_manifest="$unsigned_dir/unsigned-acceptance-manifest.json"
unsigned_assets=(
  --asset "phase3-binary-m4-${tag}.tar.gz=$cli_unsigned"
  --asset "Malibu.app.tar.gz=$app_unsigned"
  --asset "release-toolchain.json=$toolchain"
  --asset "coordinator-linux-amd64=$coordinator"
  --asset "coordinator-cli-linux-amd64=$coordinator_cli"
  --asset "gateway-linux-amd64=$gateway"
)
python3 "$metadata" verify-unsigned \
  --repository "$repository" \
  --tag "$tag" \
  --candidate-ref "$candidate_ref" \
  --candidate-commit "$candidate_commit" \
  --control-commit "$control_commit" \
  --provider-admission-policy "$provider_admission_policy" \
  --input "$unsigned_manifest" \
  "${unsigned_assets[@]}"

signing_tmp="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/acceptance-signer.XXXXXX")"
# The trusted path is validated above before sourcing.
# shellcheck disable=SC1090,SC1091
source "$keychain_helper"
keychain_nonce="$("$openssl_bin" rand -hex 8)"
[[ "$keychain_nonce" =~ ^[0-9a-f]{16}$ ]] || die "could not generate a safe keychain nonce"
keychain="acceptance-signing-${run_id}-${run_attempt}-${keychain_nonce}.keychain"
cleanup() {
  local status=$?
  local cleanup_failed=0
  if ! acceptance_keychain_cleanup "$keychain"; then
    printf '[sign-acceptance-candidate] ERROR: could not restore and remove the signing keychain\n' >&2
    cleanup_failed=1
  fi
  rm -rf "$signing_tmp"
  if [[ "$status" == 0 && "$cleanup_failed" == 1 ]]; then
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT
acceptance_keychain_capture_default || die "could not capture the existing user default keychain"

private_key="$signing_tmp/acceptance-private.pem"
derived_public_key="$signing_tmp/acceptance-public.pem"
release_private_key="$signing_tmp/release-private.pem"
release_public_key="$root/ops/pearl-updater/release-signing-public.pem"
printf '%s\n' "$MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM" > "$private_key"
chmod 600 "$private_key"
"$openssl_bin" pkey -in "$private_key" -pubout -out "$derived_public_key"
cmp "$derived_public_key" "$acceptance_public_key" ||
  die "acceptance private key does not match the committed public key"
printf '%s\n' "$MACPROVIDER_RELEASE_SIGNING_KEY_PEM" > "$release_private_key"
chmod 600 "$release_private_key"
[[ -f "$release_public_key" && ! -L "$release_public_key" ]] || die "production compatibility public key is absent"
"$openssl_bin" pkey -in "$release_private_key" -pubout -out "$signing_tmp/release-public.pem"
cmp "$signing_tmp/release-public.pem" "$release_public_key" ||
  die "release private key does not match the committed compatibility public key"

python3 "$metadata" validate-archive --input "$cli_unsigned" --forbid-links
python3 "$metadata" validate-archive --input "$app_unsigned"
cli_work="$signing_tmp/cli"
app_work="$signing_tmp/app"
mkdir "$cli_work" "$app_work"
tar -xzf "$cli_unsigned" -C "$cli_work"
tar -xzf "$app_unsigned" -C "$app_work"
[[ -x "$cli_work/macprovider-cli" && ! -L "$cli_work/macprovider-cli" ]] || die "candidate CLI is absent or unsafe"
[[ -f "$cli_work/compatibility-set.json" && ! -L "$cli_work/compatibility-set.json" ]] ||
  die "PR589 compatibility-set manifest is absent"
[[ -d "$cli_work/compatibility-set-local" && ! -L "$cli_work/compatibility-set-local" ]] ||
  die "PR589 local compatibility set is absent"
app_root_count="$(find "$app_work" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')"
[[ "$app_root_count" == 1 && -d "$app_work/Malibu.app" ]] ||
  die "Malibu archive must contain exactly one Malibu.app root"
app="$app_work/Malibu.app"
[[ -d "$app/Contents/MacOS" && -d "$app/Contents/Resources" ]] || die "Malibu.app structure is invalid"

python3 "$metadata" validate-provider-payload --directory "$cli_work"
python3 "$compatibility" validate \
  --input "$cli_work/compatibility-set.json" \
  --payload-directory "$cli_work" \
  --expected-tag "$tag" \
  --expected-commit "$candidate_commit" \
  --expected-provider-admission-policy "$provider_admission_policy"
python3 "$compatibility" sign \
  --input "$cli_work/compatibility-set.json" \
  --private-key "$release_private_key" \
  --openssl "$openssl_bin"
python3 "$compatibility" validate \
  --input "$cli_work/compatibility-set.json" \
  --payload-directory "$cli_work" \
  --require-signature \
  --public-key "$release_public_key" \
  --expected-tag "$tag" \
  --expected-commit "$candidate_commit" \
  --expected-provider-admission-policy "$provider_admission_policy" \
  --openssl "$openssl_bin"

keychain_password="$("$openssl_bin" rand -hex 24)"
acceptance_keychain_create_and_select "$keychain" "$keychain_password" ||
  die "could not create and select the transient signing keychain"
printf '%s' "$APPLE_DEVELOPER_ID_CERT_P12_BASE64" | base64 -d > "$signing_tmp/developer-id.p12"
security import "$signing_tmp/developer-id.p12" \
  -k "$keychain" \
  -P "$APPLE_DEVELOPER_ID_CERT_PASSWORD" \
  -T /usr/bin/codesign \
  -T /usr/bin/security
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s -k "$keychain_password" "$keychain"
signing_identity="$(security find-identity -v -p codesigning "$keychain" | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
[[ -n "$signing_identity" ]] || die "Developer ID Application identity is absent"

codesign --force \
  --options runtime \
  --timestamp \
  --identifier live.streamvc.macprovider.cli \
  --keychain "$keychain" \
  --sign "$signing_identity" \
  "$cli_work/macprovider-cli"
codesign --verify --strict --verbose=2 "$cli_work/macprovider-cli"
cli_requirement="$(codesign -d -r- "$cli_work/macprovider-cli" 2>&1)"
grep -F 'identifier "live.streamvc.macprovider.cli"' <<<"$cli_requirement" >/dev/null ||
  die "signed CLI lacks the stable designated requirement"

cli_notary="$signing_tmp/macprovider-cli-notary.zip"
(cd "$cli_work" && /usr/bin/ditto -c -k --keepParent macprovider-cli "$cli_notary")
"$root/scripts/notarytool-submit-with-retry.sh" "$cli_notary" \
  --apple-id "$APPLE_NOTARY_APPLE_ID" \
  --password "$APPLE_NOTARY_PASSWORD" \
  --team-id "$APPLE_NOTARY_TEAM_ID" \
  --wait
rm -f "$cli_notary"

install -m 0755 "$cli_work/macprovider-cli" "$app/Contents/MacOS/macprovider-cli"
install -m 0644 "$cli_work/compatibility-set.json" "$app/Contents/Resources/compatibility-set.json"
cmp "$cli_work/compatibility-set.json" "$app/Contents/Resources/compatibility-set.json"
codesign --force --deep \
  --options runtime \
  --timestamp \
  --entitlements "$root/phase3-binary/app/Malibu.entitlements" \
  --keychain "$keychain" \
  --sign "$signing_identity" \
  "$app"
codesign --verify --strict --verbose=2 --deep "$app"
app_notary="$signing_tmp/Malibu-notary.zip"
/usr/bin/ditto -c -k --keepParent "$app" "$app_notary"
"$root/scripts/notarytool-submit-with-retry.sh" "$app_notary" \
  --apple-id "$APPLE_NOTARY_APPLE_ID" \
  --password "$APPLE_NOTARY_PASSWORD" \
  --team-id "$APPLE_NOTARY_TEAM_ID" \
  --wait
rm -f "$app_notary"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl -a -vvv -t exec "$app"

mkdir "$output_dir"
provider_asset="$output_dir/macprovider-cli-${tag}-darwin-arm64.tar.gz"
malibu_asset="$output_dir/Malibu-${tag}.dmg"
tar -czf "$provider_asset" -C "$cli_work" .
dmg_stage="$signing_tmp/dmg"
mkdir "$dmg_stage"
cp -R "$app" "$dmg_stage/Malibu.app"
ln -s /Applications "$dmg_stage/Applications"
hdiutil create -volname Malibu -srcfolder "$dmg_stage" -ov -format UDZO "$malibu_asset"
codesign --sign "$signing_identity" --keychain "$keychain" --timestamp "$malibu_asset"
"$root/scripts/notarytool-submit-with-retry.sh" "$malibu_asset" \
  --apple-id "$APPLE_NOTARY_APPLE_ID" \
  --password "$APPLE_NOTARY_PASSWORD" \
  --team-id "$APPLE_NOTARY_TEAM_ID" \
  --wait
xcrun stapler staple "$malibu_asset"
xcrun stapler validate "$malibu_asset"

install -m 0755 "$coordinator" "$output_dir/coordinator-linux-amd64"
install -m 0755 "$coordinator_cli" "$output_dir/coordinator-cli-linux-amd64"
install -m 0755 "$gateway" "$output_dir/gateway-linux-amd64"
install -m 0644 "$toolchain" "$output_dir/release-toolchain.json"
install -m 0644 "$cli_work/compatibility-set.json" "$output_dir/compatibility-set.json"
for catalog_name in release.json trusted-keys.json autotune-candidates.json autotune-candidates.json.sig demand-rank.json demand-rank.json.sig; do
  install -m 0644 "$cli_work/catalog-release/$catalog_name" "$output_dir/$catalog_name"
done

python3 "$metadata" build-pearl \
  --repository "$repository" \
  --tag "$tag" \
  --commit "$candidate_commit" \
  --provider-admission-policy "$provider_admission_policy" \
  --catalog-directory "$output_dir" \
  --coordinator "$output_dir/coordinator-linux-amd64" \
  --coordinator-cli "$output_dir/coordinator-cli-linux-amd64" \
  --gateway "$output_dir/gateway-linux-amd64" \
  --output "$output_dir/pearl-release.json"
"$openssl_bin" dgst -sha256 -sign "$private_key" \
  -out "$output_dir/pearl-release.json.sig" "$output_dir/pearl-release.json"
"$openssl_bin" dgst -sha256 -verify "$derived_public_key" \
  -signature "$output_dir/pearl-release.json.sig" "$output_dir/pearl-release.json"

artifact_arguments=(
  --artifact "provider_cli=$provider_asset"
  --artifact "malibu_app=$malibu_asset"
  --artifact "coordinator=$output_dir/coordinator-linux-amd64"
  --artifact "coordinator_cli=$output_dir/coordinator-cli-linux-amd64"
  --artifact "gateway=$output_dir/gateway-linux-amd64"
  --artifact "compatibility_manifest=$output_dir/compatibility-set.json"
  --artifact "catalog_manifest=$output_dir/release.json"
  --artifact "catalog_trusted_keys=$output_dir/trusted-keys.json"
  --artifact "catalog_candidates=$output_dir/autotune-candidates.json"
  --artifact "catalog_candidates_signature=$output_dir/autotune-candidates.json.sig"
  --artifact "catalog_demand=$output_dir/demand-rank.json"
  --artifact "catalog_demand_signature=$output_dir/demand-rank.json.sig"
  --artifact "pearl_metadata=$output_dir/pearl-release.json"
  --artifact "pearl_metadata_signature=$output_dir/pearl-release.json.sig"
)
python3 "$artifact_index" build \
  --output "$output_dir/compatibility-artifact-index.json" \
  --compatibility-manifest "$output_dir/compatibility-set.json" \
  --repository "$repository" \
  --tag "$tag" \
  --commit "$candidate_commit" \
  "${artifact_arguments[@]}"
python3 "$artifact_index" validate \
  --input "$output_dir/compatibility-artifact-index.json" \
  --compatibility-manifest "$output_dir/compatibility-set.json" \
  --repository "$repository" \
  --tag "$tag" \
  --commit "$candidate_commit" \
  "${artifact_arguments[@]}"

release_assets=(
  "$provider_asset"
  "$malibu_asset"
  "$output_dir/release-toolchain.json"
  "$output_dir/coordinator-linux-amd64"
  "$output_dir/coordinator-cli-linux-amd64"
  "$output_dir/gateway-linux-amd64"
  "$output_dir/compatibility-set.json"
  "$output_dir/release.json"
  "$output_dir/trusted-keys.json"
  "$output_dir/autotune-candidates.json"
  "$output_dir/autotune-candidates.json.sig"
  "$output_dir/demand-rank.json"
  "$output_dir/demand-rank.json.sig"
  "$output_dir/pearl-release.json"
  "$output_dir/pearl-release.json.sig"
  "$output_dir/compatibility-artifact-index.json"
)
python3 "$root/scripts/build-release-provenance.py" \
  "$tag" "$candidate_commit" "$repository" true \
  "$output_dir/release-toolchain.json" \
  "$output_dir/release-provenance.json" \
  "${release_assets[@]}"
release_assets+=("$output_dir/release-provenance.json")
python3 - "$output_dir" "$output_dir/release-assets.txt" "${release_assets[@]}" <<'PY'
import os
import pathlib
import re
import stat
import sys

root = pathlib.Path(sys.argv[1]).resolve()
output = pathlib.Path(sys.argv[2])
paths = [pathlib.Path(value) for value in sys.argv[3:]]
names = []
for path in paths:
    info = path.lstat()
    if path.parent.resolve() != root or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise SystemExit(f"unsafe acceptance release asset: {path}")
    if not re.fullmatch(r"[A-Za-z0-9._-]+", path.name) or path.name in names:
        raise SystemExit(f"invalid or duplicate acceptance release asset name: {path.name}")
    names.append(path.name)
descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
try:
    with os.fdopen(descriptor, "w", encoding="ascii") as handle:
        handle.write("".join(f"{name}\n" for name in sorted(names)))
        handle.flush()
        os.fsync(handle.fileno())
except Exception:
    output.unlink(missing_ok=True)
    raise
PY

checksum_arguments=()
for release_asset in "${release_assets[@]}"; do
  checksum_arguments+=(--asset "$(basename "$release_asset")=$release_asset")
done
python3 "$metadata" build-checksums \
  --output "$output_dir/checksums.txt" \
  "${checksum_arguments[@]}"

read -r issued_at expires_at < <(python3 - <<'PY'
import datetime as dt

issued = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
expires = issued + dt.timedelta(hours=24)
print(issued.strftime("%Y-%m-%dT%H:%M:%SZ"), expires.strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)
python3 "$metadata" sign \
  --repository "$repository" \
  --tag "$tag" \
  --candidate-ref "$candidate_ref" \
  --candidate-commit "$candidate_commit" \
  --control-commit "$control_commit" \
  --run-id "$run_id" \
  --run-attempt "$run_attempt" \
  --compatibility-manifest "$output_dir/compatibility-set.json" \
  --checksums "$output_dir/checksums.txt" \
  --issued-at "$issued_at" \
  --expires-at "$expires_at" \
  --private-key "$private_key" \
  --openssl "$openssl_bin" \
  --output "$output_dir/acceptance-candidate.json" \
  --signature "$output_dir/acceptance-candidate.json.sig"
python3 "$metadata" verify \
  --input "$output_dir/acceptance-candidate.json" \
  --signature "$output_dir/acceptance-candidate.json.sig" \
  --public-key "$acceptance_public_key" \
  --checksums "$output_dir/checksums.txt" \
  --repository "$repository" \
  --tag "$tag" \
  --candidate-ref "$candidate_ref" \
  --candidate-commit "$candidate_commit" \
  --control-commit "$control_commit" \
  --run-id "$run_id" \
  --run-attempt "$run_attempt" \
  --now "$issued_at" \
  --openssl "$openssl_bin"

if find "$output_dir" -mindepth 1 -type l -print -quit | grep -q .; then
  die "acceptance output contains a symlink"
fi
printf '[sign-acceptance-candidate] ok: %s at %s, expires %s\n' "$tag" "$candidate_commit" "$expires_at"
