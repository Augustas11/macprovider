#!/usr/bin/env bash
# Focused offline tests for published_identity_ok. The controller is sourced
# without dispatch, GitHub is a local fixture, and every signature uses a test
# key generated under a temporary test directory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONTROLLER="$ROOT/scripts/ops/studio-owner-pin.sh"
TEST_PARENT="${XDG_CACHE_HOME:-$HOME/.cache}/macprovider-tests"
mkdir -p "$TEST_PARENT"
T="$(mktemp -d "$TEST_PARENT/studio-owner-pin-provenance.XXXXXX")"
T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT

RELEASE_PRIVATE="$T/release-private.pem"
RELEASE_PUBLIC="$T/release-public.pem"
openssl ecparam -name prime256v1 -genkey -noout -out "$RELEASE_PRIVATE" >/dev/null 2>&1
openssl pkey -in "$RELEASE_PRIVATE" -pubout -out "$RELEASE_PUBLIC" >/dev/null 2>&1

UNIT="$T/studio-owner-pin-unit.sh"
python3 - "$CONTROLLER" "$UNIT" "$ROOT/scripts/ops" <<'PY'
import sys
source = open(sys.argv[1]).read()
source = source.replace(
    'OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"',
    'OPS_DIR=' + repr(sys.argv[3]),
    1,
)
source = source.replace(
    '"$REPO_ROOT/ops/pearl-updater/release-signing-public.pem"',
    '"$TEST_PEARL_PUBLIC_KEY"',
)
assert source.endswith('ops_main "$@"\n')
open(sys.argv[2], 'w').write(source[:-len('ops_main "$@"\n')] + ': # sourced by provenance test\n')
PY

mkdir -p "$T/bin"
cat >"$T/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}:${2:-}" in
  release:download)
    shift 2
    dest="" clobber=false patterns=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -D) dest="$2"; shift 2 ;;
        -p) patterns+=("$2"); shift 2 ;;
        --clobber) clobber=true; shift ;;
        *) shift ;;
      esac
    done
    [ -n "$dest" ] || exit 2
    for pattern in "${patterns[@]}"; do
      if [ -e "$dest/$pattern" ] && [ "$clobber" != true ]; then
        exit 1
      fi
      cp "$FAKE_PUBLISHED_DIR/$pattern" "$dest/$pattern"
    done
    ;;
  release:view)
    printf '%s\n' '{"tagName":"v1.8.260","isDraft":false,"isPrerelease":false,"publishedAt":"2026-10-20T09:00:00Z"}'
    ;;
  *) exit 2 ;;
esac
SH
chmod 755 "$T/bin/gh"

release_sign() {
  openssl dgst -sha256 -sign "$RELEASE_PRIVATE" -out "$2" "$1" >/dev/null 2>&1
}

corrupt_signature() {
  python3 - "$1" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
b = bytearray(p.read_bytes())
b[0] ^= 1
p.write_bytes(b)
PY
}

make_fixture() {
  local case_dir="$1"
  mkdir -p "$case_dir/bytes" "$case_dir/published" "$case_dir/install" "$case_dir/state/cli-release-1.8.260"
  python3 - "$case_dir" <<'PY'
import hashlib, json, os, sys, tarfile
root = sys.argv[1]
bytes_dir = os.path.join(root, "bytes")
version = "1.8.260"
asset = "macprovider-cli-v%s-darwin-arm64.tar.gz" % version
member = "macprovider-cli"
binary = b"fixture macprovider-cli bytes\n"
binary_sha = hashlib.sha256(binary).hexdigest()
tar_path = os.path.join(bytes_dir, asset)
with tarfile.open(tar_path, "w:gz") as tar:
    info = tarfile.TarInfo(member)
    info.size = len(binary)
    info.mtime = 0
    import io
    tar.addfile(info, io.BytesIO(binary))
tar_sha = hashlib.sha256(open(tar_path, "rb").read()).hexdigest()
with open(os.path.join(bytes_dir, "checksums.txt"), "w") as f:
    f.write("%s %s\n" % (tar_sha, asset))
checksums_sha = hashlib.sha256(open(os.path.join(bytes_dir, "checksums.txt"), "rb").read()).hexdigest()
candidate = "a" * 40
pearl = {
    "schema_version": 1,
    "repository": "test/repo",
    "tag": "v" + version,
    "release_version": version,
    "commit": candidate,
    "provider_advertised_version": version,
    "provider_code_identity": {
        "asset": asset,
        "member": member,
        "binary_sha256": binary_sha,
        "binary_version": version,
        "team_id": "TEAMTEST",
        "signing_identifier": "live.malibu.provider.cli",
        "slices": [{"arch": "arm64", "code_cdhash": "cdhash-test"}],
    }
}
with open(os.path.join(bytes_dir, "pearl-release.json"), "w") as f:
    json.dump(pearl, f, sort_keys=True, separators=(",", ":"))
marker = {"bytes_dir": bytes_dir, "candidate_sha": candidate, "checksums_sha256": checksums_sha, "binary_sha256": binary_sha}
with open(os.path.join(root, "state", "cli-release-1.8.260", "signed_byte_verification.json"), "w") as f:
    json.dump(marker, f, sort_keys=True, separators=(",", ":"))
probe = {
    "installed": {"binary_sha256": binary_sha, "binary_version": version, "team_id": "TEAMTEST", "identifier": "live.malibu.provider.cli", "cdhash": "cdhash-test"},
    "launch": {"executable_path": os.path.join(root, "install", "macprovider-cli"), "pid": 77},
    "status": {"service_instance.pid": 77},
}
with open(os.path.join(root, "probe.json"), "w") as f:
    json.dump(probe, f, sort_keys=True, separators=(",", ":"))
PY
  release_sign "$case_dir/bytes/checksums.txt" "$case_dir/bytes/checksums.txt.sig"
  release_sign "$case_dir/bytes/pearl-release.json" "$case_dir/bytes/pearl-release.json.sig"
  cp "$case_dir/bytes/checksums.txt" "$case_dir/bytes/checksums.txt.sig" \
    "$case_dir/bytes/pearl-release.json" "$case_dir/bytes/pearl-release.json.sig" "$case_dir/published/"
}

run_identity() {
  local case_dir="$1"
  # shellcheck disable=SC2016 # Variables expand intentionally in the sourced child shell.
  env PATH="$T/bin:$PATH" \
    MACPROVIDER_OPS_ENV=/dev/null \
    MACPROVIDER_OPS_STATE_DIR="$case_dir/state" \
    MACPROVIDER_GH_REPO=test/repo \
    TEST_PEARL_PUBLIC_KEY="$RELEASE_PUBLIC" \
    FAKE_PUBLISHED_DIR="$case_dir/published" \
    CONTROLLER_UNIT="$UNIT" CASE_DIR="$case_dir" \
  bash -c 'source "$CONTROLLER_UNIT"; VERSION=1.8.260; PROBE_JSON="$(cat "$CASE_DIR/probe.json")"; STUDIO_OWNER_PIN_INSTALL_DIR="$CASE_DIR/install"; published_identity_ok'
}

run_identity_twice() {
  local case_dir="$1"
  # shellcheck disable=SC2016 # Variables expand intentionally in the sourced child shell.
  env PATH="$T/bin:$PATH" \
    MACPROVIDER_OPS_ENV=/dev/null \
    MACPROVIDER_OPS_STATE_DIR="$case_dir/state" \
    MACPROVIDER_GH_REPO=test/repo \
    TEST_PEARL_PUBLIC_KEY="$RELEASE_PUBLIC" \
    FAKE_PUBLISHED_DIR="$case_dir/published" \
    CONTROLLER_UNIT="$UNIT" CASE_DIR="$case_dir" \
  bash -c 'source "$CONTROLLER_UNIT"; VERSION=1.8.260; PROBE_JSON="$(cat "$CASE_DIR/probe.json")"; STUDIO_OWNER_PIN_INSTALL_DIR="$CASE_DIR/install"; published_identity_ok && published_identity_ok'
}

pass=0
fail=0
expect_rc() {
  local want="$1" name="$2" case_dir="$3" got=0
  run_identity "$case_dir" >"$case_dir/out" 2>"$case_dir/err" || got=$?
  if [ "$got" = "$want" ]; then
    printf 'ok - %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'not ok - %s (rc=%s, want=%s; %s)\n' "$name" "$got" "$want" "$(tr '\n' ' ' <"$case_dir/err")"
    fail=$((fail + 1))
  fi
}

case_dir="$T/valid"; make_fixture "$case_dir"
expect_rc 0 "valid published signatures, checksums, tar member, and installed identity are accepted" "$case_dir"

case_dir="$T/repeated"; make_fixture "$case_dir"
got=0
run_identity_twice "$case_dir" >"$case_dir/out" 2>"$case_dir/err" || got=$?
if [ "$got" = 0 ]; then
  printf 'ok - repeated identity checks clobber private downloads and reverify them\n'
  pass=$((pass + 1))
else
  printf 'not ok - repeated identity checks clobber private downloads and reverify them (rc=%s; %s)\n' "$got" "$(tr '\n' ' ' <"$case_dir/err")"
  fail=$((fail + 1))
fi

case_dir="$T/bad-published-pearl-signature"; make_fixture "$case_dir"
corrupt_signature "$case_dir/published/pearl-release.json.sig"
expect_rc 1 "bad published pearl signature is rejected" "$case_dir"

case_dir="$T/bad-published-checksums-signature"; make_fixture "$case_dir"
corrupt_signature "$case_dir/published/checksums.txt.sig"
expect_rc 1 "bad published checksums signature is rejected" "$case_dir"

case_dir="$T/marker-drift"; make_fixture "$case_dir"
python3 - "$case_dir/state/cli-release-1.8.260/signed_byte_verification.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["checksums_sha256"] = "0" * 64
open(p, "w").write(json.dumps(d))
PY
expect_rc 1 "editable signed-byte marker checksum drift is rejected" "$case_dir"

case_dir="$T/checksums-drift"; make_fixture "$case_dir"
printf '# editable drift\n' >> "$case_dir/bytes/checksums.txt"
expect_rc 1 "editable cached checksums drift from published release is rejected" "$case_dir"

case_dir="$T/tar-digest-mismatch"; make_fixture "$case_dir"
printf 'tampered' >> "$case_dir/bytes/macprovider-cli-v1.8.260-darwin-arm64.tar.gz"
expect_rc 1 "tarball digest mismatch is rejected" "$case_dir"

case_dir="$T/tar-member-mismatch"; make_fixture "$case_dir"
python3 - "$case_dir/bytes/pearl-release.json" "$case_dir/state/cli-release-1.8.260/signed_byte_verification.json" <<'PY'
import json, sys
pearl, marker = sys.argv[1:3]
d = json.load(open(pearl))
d["provider_code_identity"]["binary_sha256"] = "f" * 64
open(pearl, "w").write(json.dumps(d, sort_keys=True, separators=(",", ":")))
m = json.load(open(marker))
m["binary_sha256"] = "f" * 64
open(marker, "w").write(json.dumps(m, sort_keys=True, separators=(",", ":")))
PY
release_sign "$case_dir/bytes/pearl-release.json" "$case_dir/bytes/pearl-release.json.sig"
cp "$case_dir/bytes/pearl-release.json" "$case_dir/bytes/pearl-release.json.sig" "$case_dir/published/"
expect_rc 1 "tar member digest mismatch is rejected" "$case_dir"

case_dir="$T/installed-identity-mismatch"; make_fixture "$case_dir"
python3 - "$case_dir/probe.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["installed"]["binary_sha256"] = "0" * 64
open(p, "w").write(json.dumps(d, sort_keys=True, separators=(",", ":")))
PY
expect_rc 1 "installed binary identity mismatch is rejected" "$case_dir"

printf '1..%s\n' "$((pass + fail))"
[ "$fail" -eq 0 ]
