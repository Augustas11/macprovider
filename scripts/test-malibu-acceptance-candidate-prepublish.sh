#!/usr/bin/env bash
# Prove publish-malibu-latest-dmg.sh validates the signed acceptance-candidate
# (P-256 signature + schema + tag/candidate_commit/compatibility_set_id + expiry)
# BEFORE any Pearl transfer/promotion, so a stale/expired/mismatched/dummy
# candidate can never reach the immutable release dir or the .malibu-current swap.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/malibu-acceptance-prepublish.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fail() {
  printf '[acceptance-prepublish-test] FAIL: %s\n' "$*" >&2
  exit 1
}

command -v openssl >/dev/null 2>&1 || { echo "SKIP: openssl required"; exit 0; }

# Isolated mirror so the "committed" acceptance public key is our ephemeral key
# and no real Pearl SSH or release-set verification runs.
mirror="$work/repo"
mkdir -p "$mirror/scripts" "$mirror/security" "$work/input"
cp "$repo_root/scripts/publish-malibu-latest-dmg.sh" "$mirror/scripts/"
cp "$repo_root/scripts/acceptance-candidate-metadata.py" "$mirror/scripts/"

# Stub the heavy release-set verifier: this test only exercises the acceptance
# gate, which runs after it and before any transfer.
printf '#!/usr/bin/env bash\nexit 0\n' > "$mirror/scripts/verify-malibu-publication-set.sh"
# Stub the Pearl SSH transport. Reaching it means the acceptance gate passed;
# it records a marker and fails so no real network/promotion happens.
cat > "$mirror/scripts/malibu-download-ssh.sh" <<'SH'
malibu_download_ssh() { printf 'reached-ssh\n' >> "$MOCK_SSH_MARKER"; return 1; }
malibu_download_scp() { printf 'reached-ssh\n' >> "$MOCK_SSH_MARKER"; return 1; }
SH
chmod +x "$mirror/scripts/verify-malibu-publication-set.sh"

openssl ecparam -name prime256v1 -genkey -noout -out "$work/acceptance-private.pem"
openssl ec -in "$work/acceptance-private.pem" -pubout \
  -out "$mirror/security/acceptance-candidate-signing-public.pem" >/dev/null 2>&1

repository="Augustas11/macprovider"
tag="v1.8.70"
commit="$(printf 'c%.0s' {1..40})"

# Minimal frozen-mode manifest (non-v1.8.39: no appcast asset). publish reads
# only tag/commit/repository/release_id/publication_id and the DMG asset id.
printf 'signed notarized 1.8.70 dmg bytes\n' > "$work/input/Malibu-${tag}.dmg"
printf 'artifact index bytes\n' > "$work/input/compatibility-artifact-index.json"
cp "$repo_root/scripts/dist/malibu-frozen-bridge-appcast.xml" "$work/input/frozen-appcast.xml"
printf 'checksums-for-this-release\n' > "$work/input/checksums.txt"
printf 'checksums signature bytes\n' > "$work/input/checksums.txt.sig"
printf 'provenance bytes\n' > "$work/input/release-provenance.json"
python3 - "$work/input/publication-manifest.json" "$work/input/Malibu-${tag}.dmg" "$repository" "$tag" "$commit" <<'PY'
import hashlib, json, pathlib, sys
output, dmg, repository, tag, commit = sys.argv[1:]
dmg_digest = hashlib.sha256(pathlib.Path(dmg).read_bytes()).hexdigest()
manifest = {
    "schema_version": 1,
    "repository": repository,
    "tag": tag,
    "commit": commit,
    "prerelease": False,
    "release_id": 505,
    "publication_id": "0" * 64,
    "assets": {f"Malibu-{tag}.dmg": {"id": 900, "sha256": dmg_digest}},
}
pathlib.Path(output).write_text(json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n")
PY

# Sign an acceptance-candidate exactly as command_sign_acceptance does:
# signature over  SIGNING_DOMAIN + canonical_bytes(metadata). Files use the
# canonical basenames publish requires, isolated in a per-case directory.
sign_candidate() {
  local case_dir="$1" sign_tag="$2" sign_commit="$3" issued="$4" expires="$5"
  mkdir -p "$case_dir"
  local out_json="$case_dir/acceptance-candidate.json"
  local out_sig="$case_dir/acceptance-candidate.json.sig"
  python3 - "$out_json" "$work/input/checksums.txt" "$repository" "$sign_tag" "$sign_commit" "$issued" "$expires" <<'PY'
import hashlib, json, pathlib, sys
out, checksums, repository, tag, commit, issued, expires = sys.argv[1:]
value = {
    "candidate_commit": commit,
    "candidate_ref": "refs/heads/main",
    "channel": "acceptance",
    "checksums": {"name": "checksums.txt", "sha256": hashlib.sha256(pathlib.Path(checksums).read_bytes()).hexdigest()},
    "compatibility_set_id": f"{repository}:{tag}@{commit}",
    "control_commit": "b" * 40,
    "expires_at": expires,
    "issued_at": issued,
    "repository": repository,
    "run_attempt": 1,
    "run_id": "123456789",
    "schema_version": "macprovider.acceptance-candidate.v1",
    "signing": {"algorithm": "ecdsa-p256-sha256", "key_id": "macprovider-acceptance-p256-v1"},
    "tag": tag,
}
canonical = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
pathlib.Path(out).write_bytes(canonical)
pathlib.Path(out + ".message").write_bytes(b"macprovider.acceptance-candidate.v1\n" + canonical)
PY
  openssl dgst -sha256 -sign "$work/acceptance-private.pem" \
    -out "$case_dir/sig.der" "$out_json.message"
  base64 < "$case_dir/sig.der" | tr -d '\n' > "$out_sig"
  printf '\n' >> "$out_sig"
}

issued_now="$(python3 -c 'import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=1)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
expires_future="$(python3 -c 'import datetime;print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
issued_old="$(python3 -c 'import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
expires_past="$(python3 -c 'import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"

run_publish() {
  # $1 = acceptance json, $2 = acceptance sig
  rm -f "$work/ssh.marker"
  local key_file="$work/ssh-key"
  printf 'test key\n' > "$key_file"
  chmod 600 "$key_file"
  MOCK_SSH_MARKER="$work/ssh.marker" \
  MALIBU_DOWNLOAD_SSH_KEY="$key_file" \
  MALIBU_DOWNLOAD_VPS_HOST=127.0.0.1 \
    bash "$mirror/scripts/publish-malibu-latest-dmg.sh" \
    "$work/input/publication-manifest.json" "$work/input/Malibu-${tag}.dmg" \
    "$work/input/frozen-appcast.xml" "$work/input/compatibility-artifact-index.json" \
    "$work/input/checksums.txt" "$work/input/checksums.txt.sig" \
    "$work/input/release-provenance.json" \
    "$1" "$2"
}

# 1) Valid candidate: passes the acceptance gate and REACHES the (stubbed) SSH
#    transport. Publish then fails at the stub, which is expected.
sign_candidate "$work/valid" "$tag" "$commit" "$issued_now" "$expires_future"
if run_publish "$work/valid/acceptance-candidate.json" "$work/valid/acceptance-candidate.json.sig" \
  >"$work/valid.out" 2>&1; then
  fail "publish unexpectedly succeeded against the stubbed SSH transport"
fi
grep -q 'acceptance-candidate signature/identity/expiry validation failed' "$work/valid.out" &&
  fail "valid acceptance-candidate was wrongly rejected"
[[ -f "$work/ssh.marker" ]] || fail "valid candidate did not reach the SSH transport (gate over-rejected)"

expect_prepublish_rejection() {
  local label="$1" case_dir="$2"
  if run_publish "$case_dir/acceptance-candidate.json" "$case_dir/acceptance-candidate.json.sig" \
    >"$work/$label.out" 2>&1; then
    fail "$label was accepted"
  fi
  grep -q 'acceptance-candidate signature/identity/expiry validation failed' "$work/$label.out" ||
    { cat "$work/$label.out" >&2; fail "$label did not fail at the acceptance gate"; }
  [[ ! -f "$work/ssh.marker" ]] || fail "$label reached the SSH transport before rejection"
}

# 2) Tampered signature (valid metadata, corrupted signature bytes).
mkdir -p "$work/tampered"
cp "$work/valid/acceptance-candidate.json" "$work/tampered/acceptance-candidate.json"
printf 'AAAA%s\n' "$(base64 < "$work/valid/sig.der" | tr -d '\n' | cut -c5-)" \
  > "$work/tampered/acceptance-candidate.json.sig"
expect_prepublish_rejection tampered "$work/tampered"

# 3) Expired candidate (valid signature, expires in the past).
sign_candidate "$work/expired" "$tag" "$commit" "$issued_old" "$expires_past"
expect_prepublish_rejection expired "$work/expired"

# 4) Tag/commit mismatch (candidate signed for a different release).
sign_candidate "$work/mismatch" "v1.8.71" "$(printf 'd%.0s' {1..40})" "$issued_now" "$expires_future"
expect_prepublish_rejection mismatch "$work/mismatch"

echo 'Malibu acceptance-candidate pre-publish validation checks passed'
