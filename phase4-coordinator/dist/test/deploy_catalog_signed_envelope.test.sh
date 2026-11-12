#!/usr/bin/env bash
# SPEC-023 §3.8: release.json.sig rides the immutable catalog envelope without
# changing its content-addressed name. Pins how deploy-pearl-vps.sh carries the
# signature, and runs the extracted existing-envelope checks (preflight and
# staging) against a pre-existing signed release directory signed with a
# throwaway Ed25519 test key.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DEPLOY_SH="$SCRIPT_DIR/../deploy-pearl-vps.sh"
CR_PY="$REPO_ROOT/scripts/catalog-release.py"
TMP="$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/deploy-signed-envelope-test.XXXXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

line_of() {
  local n
  n="$(grep -nF -- "$1" "$DEPLOY_SH" | head -1 | cut -d: -f1)"
  [ -n "$n" ] || fail "deploy-pearl-vps.sh lost: $1"
  printf '%s' "$n"
}

# --- Static pins -------------------------------------------------------------
grep -qF 'diff -qr \$_autotune_stage' "$DEPLOY_SH" &&
  fail "the existing-envelope check must not be a raw diff -qr (a signed envelope differs by release.json.sig)"
grep -qxF 'AUTOTUNE_RELEASE_MANIFEST_SIG="$PINNED_AUTOTUNE_DIR/release.json.sig"' "$DEPLOY_SH" ||
  fail "the manifest signature must come from the pinned tag"
grep -qF '_append_deploy_input_digest "$AUTOTUNE_RELEASE_MANIFEST_SIG" "release.json.sig"' "$DEPLOY_SH" ||
  fail "release.json.sig must be a digested deploy input when present"
grep -qF '$SCP "$AUTOTUNE_RELEASE_MANIFEST_SIG" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/release.json.sig"' "$DEPLOY_SH" ||
  fail "release.json.sig must be uploaded when present"
grep -qF 'install -o root -g macprovider -m 0640 $DEPLOY_TMP/release.json \$_autotune_stage/release.json$AUTOTUNE_MANIFEST_SIG_INSTALL_LINE' "$DEPLOY_SH" ||
  fail "release.json.sig must be staged into the envelope when present"
grep -qF 'tar -cf - $CATALOG_ENVELOPE_FILES \$_sig' "$DEPLOY_SH" ||
  fail "the live snapshot must carry release.json.sig when the live envelope has it"

# The signature stays out of the envelope content hash, so signing a release
# never renames its directory.
hash_block="$(awk '/^assets = \($/{f=1} f{print} f&&/^digest = hashlib.sha256\(\)$/{exit}' "$DEPLOY_SH")"
[ -n "$hash_block" ] || fail "could not extract the envelope content-hash asset list"
case "$hash_block" in
  *release.json.sig*) fail "release.json.sig must not be part of the envelope content hash" ;;
esac

# The existing-envelope comparison runs in the preflight, before the remote
# block that installs binaries and before the config backup.
preflight_check_line="$(line_of 'same-envelope --staged \$_preflight --existing /opt/macprovider/autotune/releases/$AUTOTUNE_RELEASE_DIR_NAME')"
binaries_line="$(line_of 'refusing coordinator-only replacement')"
backup_line="$(line_of 'remote-config backup saved at')"
[ "$preflight_check_line" -lt "$binaries_line" ] && [ "$preflight_check_line" -lt "$backup_line" ] ||
  fail "the existing-envelope check must run before binaries are installed or config is backed up"
line_of 'same-envelope --staged \$_autotune_stage --existing \$_autotune_release' >/dev/null

# --- Extract the two existing-envelope checks --------------------------------
unescape() {
  python3 - "$1" "$2" <<'PY'
import sys
text, deploy_tmp = sys.argv[1], sys.argv[2]
print(text.replace("\\$", "$").replace("$DEPLOY_TMP", deploy_tmp), end="")
PY
}
preflight_raw="$(awk '/^  if \[ \\\$_rc -eq 0 \] && \[ -e \/opt\/macprovider\/autotune\/releases\/\$AUTOTUNE_RELEASE_DIR_NAME \]; then$/{f=1} f{print} f&&/^  fi$/{exit}' "$DEPLOY_SH")"
[ -n "$preflight_raw" ] || fail "could not extract the preflight existing-envelope check"
stage_raw="$(awk '/^  if \[ -e \\\$_autotune_release \]; then$/{f=1} f{print} f&&/^  fi$/{exit}' "$DEPLOY_SH")"
case "$stage_raw" in *"mv \\\$_autotune_stage \\\$_autotune_release"*) ;; *) fail "could not extract the staging existing-envelope check" ;; esac

DEPLOY_TMP="$TMP/deploy-tmp"
ROOT="$TMP/opt/macprovider"
mkdir -p "$DEPLOY_TMP/scripts" "$ROOT/autotune/releases"
cp "$CR_PY" "$DEPLOY_TMP/scripts/catalog-release.py"
# catalog-release.py imports its siblings from ROOT/"scripts"; ship the bundle.
while read -r entry; do
  case "$entry" in ''|'#'*) continue ;; esac
  cp "$REPO_ROOT/$entry" "$DEPLOY_TMP/$entry"
done < "$REPO_ROOT/scripts/catalog-verifier-bundle.txt"
PREFLIGHT_CHECK="$(unescape "$preflight_raw" "$DEPLOY_TMP" | sed "s#/opt/macprovider#$ROOT#g")"
STAGE_CHECK="$(unescape "$stage_raw" "$DEPLOY_TMP")"
DIR_NAME="published-test-0123456789abcdef"

# --- Fixture: the committed release, re-keyed to a throwaway test key ---------
FIXTURE="$TMP/fixture"
mkdir -p "$FIXTURE"
for name in demand-rank.json demand-rank.json.sig autotune-candidates.json autotune-candidates.json.sig rate-card.json rate-card.json.sig continuous-batching-policy.json continuous-batching-policy.json.sig; do
  cp "$REPO_ROOT/phase3-binary/dist/static/$name" "$FIXTURE/$name"
done
for name in release.json tier2-catalog.json; do
  cp "$REPO_ROOT/phase3-binary/catalog/autotune/$name" "$FIXTURE/$name"
done
python3 - "$CR_PY" "$FIXTURE" "$TMP" <<'PY'
import base64, importlib.util, json, pathlib, subprocess, sys
spec = importlib.util.spec_from_file_location("cr", sys.argv[1]); cr = importlib.util.module_from_spec(spec); spec.loader.exec_module(cr)
fixture, tmp = pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
openssl = cr.openssl_executable()
manifest = (fixture / "release.json").read_bytes()
signer = json.loads(manifest)["feeds"]["autotune-candidates.json"]["signer_key_id"]
def keypair(name):
    pem = tmp / f"{name}.pem"
    subprocess.run([openssl, "genpkey", "-algorithm", "ed25519", "-out", str(pem)], check=True, capture_output=True)
    der = subprocess.run([openssl, "pkey", "-in", str(pem), "-pubout", "-outform", "DER"], check=True, capture_output=True).stdout
    return pem, der[-32:]
def sidecar(pem, body):
    msg = tmp / "message.bin"
    msg.write_bytes(body)
    sig = subprocess.run([openssl, "pkeyutl", "-sign", "-inkey", str(pem), "-rawin", "-in", str(msg)], check=True, capture_output=True).stdout
    pem.unlink()
    return json.dumps({"alg": "ed25519", "key_id": signer, "signature": base64.b64encode(sig).decode()}, sort_keys=True).encode()
pem, public = keypair("signer")
forged_pem, _ = keypair("forger")
keys = {"schema_version": "macprovider.autotune-keys.v1",
        "keys": {signer: {"public_key_base64": base64.b64encode(public).decode(), "status": "active"}}}
(fixture / "trusted-keys.json").write_text(json.dumps(keys, indent=2, sort_keys=True) + "\n")
(tmp / "release.json.sig").write_bytes(sidecar(pem, manifest))
(tmp / "forged-release.json.sig").write_bytes(sidecar(forged_pem, manifest))
PY

# envelope <dir> [sig-file]: the fixture, plus release.json.sig when given.
envelope() {
  rm -rf "$1"
  mkdir -p "$1"
  cp "$FIXTURE"/* "$1/"
  [ -z "${2:-}" ] || cp "$2" "$1/release.json.sig"
}

run_preflight() {
  # $1 = staged dir. Prints rc of the extracted preflight check.
  (
    set +e
    _preflight="$1"
    _rc=0
    AUTOTUNE_RELEASE_DIR_NAME="$DIR_NAME"
    eval "${PREFLIGHT_CHECK//\$AUTOTUNE_RELEASE_DIR_NAME/$DIR_NAME}" >&2
    echo "$_rc"
  ) 2>"$TMP/preflight.err"
}

run_stage() {
  # $1 = stage dir, $2 = release dir. Returns the extracted staging check's rc.
  (
    set -e
    _autotune_stage="$1"
    _autotune_release="$2"
    eval "${STAGE_CHECK//\$AUTOTUNE_RELEASE_DIR_NAME/$DIR_NAME}"
  ) >"$TMP/stage.out" 2>&1
}

EXISTING="$ROOT/autotune/releases/$DIR_NAME"
STAGED="$TMP/staged"

# 1. A pre-existing signed envelope, unsigned staged copy (an older tag): accepted.
envelope "$EXISTING" "$TMP/release.json.sig"
envelope "$STAGED"
[ "$(run_preflight "$STAGED")" = 0 ] || { cat "$TMP/preflight.err" >&2; fail "preflight must accept a pre-existing envelope that differs only by a valid release.json.sig"; }
run_stage "$STAGED" "$EXISTING" || { cat "$TMP/stage.out" >&2; fail "staging must accept a pre-existing envelope that differs only by a valid release.json.sig"; }
[ ! -e "$STAGED" ] || fail "staging must drop the redundant stage when the envelope already exists"
[ -f "$EXISTING/release.json.sig" ] || fail "staging must leave the existing signed envelope untouched"

# 2. Both signed with the same bytes: accepted.
envelope "$STAGED" "$TMP/release.json.sig"
[ "$(run_preflight "$STAGED")" = 0 ] || { cat "$TMP/preflight.err" >&2; fail "identical signed envelopes must be accepted"; }

# 3. Staged signed, existing unsigned (the tag adds the signature): accepted;
#    the existing envelope stays as it is.
envelope "$EXISTING"
envelope "$STAGED" "$TMP/release.json.sig"
[ "$(run_preflight "$STAGED")" = 0 ] || { cat "$TMP/preflight.err" >&2; fail "a staged signature over the identical release.json must be accepted"; }

# 4. Existing carries a signature from a key the release does not trust: refused.
envelope "$EXISTING" "$TMP/forged-release.json.sig"
envelope "$STAGED"
[ "$(run_preflight "$STAGED")" != 0 ] || fail "preflight must refuse an existing envelope whose release.json.sig does not verify"
run_stage "$STAGED" "$EXISTING" && fail "staging must refuse an existing envelope whose release.json.sig does not verify"
grep -qF 'already exists with different bytes' "$TMP/stage.out" || fail "staging refusal must name the envelope conflict"

# 5. Both signed with different bytes: refused.
envelope "$EXISTING" "$TMP/release.json.sig"
envelope "$STAGED" "$TMP/forged-release.json.sig"
[ "$(run_preflight "$STAGED")" != 0 ] || fail "differing release.json.sig on both sides must be refused"

# 6. Any other byte difference or extra file: refused, as diff -qr did.
envelope "$EXISTING" "$TMP/release.json.sig"
envelope "$STAGED"
printf ' ' >> "$STAGED/rate-card.json"
[ "$(run_preflight "$STAGED")" != 0 ] || fail "a differing feed must be refused"
envelope "$STAGED"
printf '{}' > "$EXISTING/extra.json"
[ "$(run_preflight "$STAGED")" != 0 ] || fail "an extra file in the existing envelope must be refused"

# 7. No existing envelope: the preflight check does not run.
rm -rf "$EXISTING"
envelope "$STAGED"
[ "$(run_preflight "$STAGED")" = 0 ] || fail "a fresh envelope name must pass the preflight check"

echo "PASS: deploy_catalog_signed_envelope"
