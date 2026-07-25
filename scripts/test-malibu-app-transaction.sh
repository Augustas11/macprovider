#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
production_transaction="$repo_root/scripts/malibu-app-transaction.py"
release_tool="$repo_root/scripts/malibu-release-envelope.py"
work="$(mktemp -d "${TMPDIR:-/tmp}/malibu-app-transaction.XXXXXX")"
work="$(cd "$work" && pwd -P)"
trap 'rm -rf "$work"' EXIT

uid="$(id -u)"
destination="$work/Applications/Malibu.app"
state="$work/Application Support/Malibu/Release"
mkdir -p "$work/Applications" "$work/input" "$work/unowned/provider" "$work/unowned/config" \
  "$work/unowned/launchd" "$work/unowned/keychain" "$work/unowned/provider-markers"
chmod 755 "$work" "$work/Applications" "$work/input" "$work/unowned" "$work/unowned"/*

/usr/bin/openssl ecparam -name prime256v1 -genkey -noout -out "$work/private.pem" 2>/dev/null
/usr/bin/openssl pkey -in "$work/private.pem" -pubout -out "$work/public.pem" 2>/dev/null
public_digest="$(/usr/bin/openssl pkey -pubin -in "$work/public.pem" -outform DER 2>/dev/null | shasum -a 256 | awk '{print $1}')"
python3 - "$work" "$public_digest" <<'PY'
import datetime as dt
import json
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
canonical = lambda value: json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
(root / "keyring.json").write_bytes(canonical({
    "generation": 1,
    "keys": [{
        "algorithm": "ecdsa-p256-sha256",
        "key_id": "test-key",
        "public_key_path": "public.pem",
        "public_key_spki_sha256": sys.argv[2],
        "status": "active",
    }],
    "schema_version": "malibu-release-keyring.v1",
}))
(root / "revocations.json").write_bytes(canonical({
    "generation": 1,
    "issued_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "keyring_generation": 1,
    "revoked_key_ids": [],
    "revoked_keyring_generations": [],
    "schema_version": "malibu-release-revocations.v1",
}))
PY
chmod 600 "$work/private.pem"
chmod 644 "$work/public.pem" "$work/keyring.json" "$work/revocations.json"

# The production transaction has an immutable production SPKI and Team-ID
# verifier. Hermetic tests dependency-inject only these two external identities;
# the real cryptographic validator still verifies every generated signature.
test_transaction="$work/test-malibu-app-transaction.py"
cat >"$test_transaction" <<'PY'
#!/usr/bin/env python3
import importlib.util
import os
import sys
spec = importlib.util.spec_from_file_location("transaction_under_test", os.environ["TRANSACTION_SOURCE"])
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
module.PINNED_SPKI_SHA256 = os.environ["TEST_SPKI_SHA256"]
module.PINNED_PUBLIC_KEY_NAME = "public.pem"
module.verify_source_app_signature = lambda _app: None
sys.argv = [os.environ["TRANSACTION_SOURCE"], *sys.argv[1:]]
raise SystemExit(module.main())
PY
chmod 700 "$test_transaction"
transaction="$test_transaction"
export TRANSACTION_SOURCE="$production_transaction" TEST_SPKI_SHA256="$public_digest"

for sentinel in provider config launchd keychain provider-markers; do
  printf 'must remain untouched: %s\n' "$sentinel" >"$work/unowned/$sentinel/sentinel"
  chmod 644 "$work/unowned/$sentinel/sentinel"
done

make_app() {
  local app="$1" version="$2" build="$3" payload="$4"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  python3 - "$app/Contents/Info.plist" "$version" "$build" <<'PY'
import pathlib
import plistlib
import sys
path = pathlib.Path(sys.argv[1])
with path.open("wb") as handle:
    plistlib.dump({
        "CFBundleExecutable": "Malibu",
        "CFBundleIdentifier": "tech.malibu.app",
        "CFBundleShortVersionString": sys.argv[2],
        "CFBundleVersion": sys.argv[3],
    }, handle, sort_keys=True)
PY
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\n' "$payload" >"$app/Contents/MacOS/Malibu"
  printf '%s\n' "$payload" >"$app/Contents/Resources/release.txt"
  chmod 755 "$app" "$app/Contents" "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/MacOS/Malibu"
  chmod 644 "$app/Contents/Info.plist" "$app/Contents/Resources/release.txt"
}

make_sidecars() {
  local directory="$1" version="$2" build="$3" generation="$4"
  "$transaction" inspect --app "$directory/Malibu.app" --expected-owner-uid "$uid" \
    > "$directory/app-evidence.json"
  python3 - "$directory" "$version" "$build" "$generation" "$work/keyring.json" "$work/revocations.json" "$directory/app-evidence.json" "$work/legacy-app-evidence.json" <<'PY'
import datetime as dt
import hashlib
import json
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
version = sys.argv[2]
build = int(sys.argv[3])
generation = int(sys.argv[4])
keyring = pathlib.Path(sys.argv[5])
revocations = pathlib.Path(sys.argv[6])
app_evidence = json.loads(pathlib.Path(sys.argv[7]).read_text(encoding="utf-8"))
legacy_evidence = json.loads(pathlib.Path(sys.argv[8]).read_text(encoding="utf-8"))
now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
timestamp = lambda value: value.strftime("%Y-%m-%dT%H:%M:%SZ")
canonical = lambda value: json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
payload = {
    "app": {
        "build": build,
        "bundle_id": "tech.malibu.app",
        "designated_requirement": "identifier tech.malibu.app and certificate leaf[subject.OU] = YF7XNRJUG4",
        "entry_count": app_evidence["entry_count"],
        "marketing_version": version,
        "release_tag": f"malibu-v{version}",
        "root_mode": app_evidence["root_mode"],
        "source_commit": "1" * 40,
        "team_id": "YF7XNRJUG4",
        "tree_sha256": app_evidence["tree_sha256"],
    },
    "artifacts": {
        "bundled_provider_cli": {"sha256": "2" * 64, "version": "1.8.40"},
        "dmg": {"name": f"Malibu-v{version}.dmg", "sha256": "3" * 64},
    },
    "envelope_generation": generation,
    "legacy_bootstrap": {
        "allowed_source_cohorts": [
            {
                "app_build": legacy_evidence["build"],
                "app_entry_count": legacy_evidence["entry_count"],
                "app_root_mode": legacy_evidence["root_mode"],
                "app_tree_sha256": legacy_evidence["tree_sha256"],
                "app_version": "1.8.39",
                "cli_version": "1.8.30",
            },
            {
                "app_build": legacy_evidence["build"],
                "app_entry_count": legacy_evidence["entry_count"],
                "app_root_mode": legacy_evidence["root_mode"],
                "app_tree_sha256": legacy_evidence["tree_sha256"],
                "app_version": "1.8.39",
                "cli_version": "1.8.32",
            },
        ],
        "backend_handoff_required": True,
        "caller_selected_target": False,
        "expires_at": timestamp(now + dt.timedelta(days=1)),
        "no_downgrade": True,
        "target_cli_version": "1.8.40",
        "target_manifest_sha256": "fe17e7a3cca392edea185c304970ef6d6fb9f06ff65aa6cffed6c7d9325a161c",
    },
    "publication": {"published_at": timestamp(now - dt.timedelta(seconds=30))},
    "runtime_posture": {"hardened_runtime": True, "notarized": True, "stapled": True},
    "supported_provider": {
        "capabilities": {
            "admission_recovery": ["v1"],
            "control_socket": ["v1"],
            "credential_handoff": ["v1"],
            "local_status_reader": ["v1"],
        },
        "compatibility_sets": [{
            "id": "Augustas11/macprovider:v1.8.40@18638472fe3e885f3534eeac29ab89b4c7ffdd7a",
            "manifest_sha256": "fe17e7a3cca392edea185c304970ef6d6fb9f06ff65aa6cffed6c7d9325a161c",
            "provider_cli": {
                "designated_identifier": "live.streamvc.macprovider.cli",
                "team_id": "YF7XNRJUG4",
                "version": "1.8.40",
            },
        }],
        "provider_mutation": "forbidden",
    },
}
(root / "unsigned-envelope.json").write_bytes(canonical({
    "schema_version": "malibu-release-envelope.v1",
    "signed": payload,
}))
(root / "fixture-times.json").write_bytes(canonical({
    "expires": timestamp(now + dt.timedelta(days=1)),
    "issued": timestamp(now - dt.timedelta(seconds=30)),
}))
PY
  python3 "$release_tool" sign-envelope \
    --input "$directory/unsigned-envelope.json" --private-key "$work/private.pem" \
    --key-id test-key --output "$directory/envelope.json"
  python3 - "$directory" "$build" "$generation" "$work/keyring.json" "$work/revocations.json" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
build = int(sys.argv[2])
generation = int(sys.argv[3])
keyring = pathlib.Path(sys.argv[4])
revocations = pathlib.Path(sys.argv[5])
times = json.loads((root / "fixture-times.json").read_text())
canonical = lambda value: json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
payload = {
    "channel": "stable",
    "envelope": {
        "build": build,
        "generation": generation,
        "name": f"malibu-release-envelope-v{build}.json",
        "sha256": hashlib.sha256((root / "envelope.json").read_bytes()).hexdigest(),
    },
    "expires_at": times["expires"],
    "index_generation": generation,
    "issued_at": times["issued"],
    "minimum_accepted_envelope_generation": generation,
    "trust": {
        "keyring_generation": 1,
        "keyring_sha256": hashlib.sha256(keyring.read_bytes()).hexdigest(),
        "revocations_generation": 1,
        "revocations_sha256": hashlib.sha256(revocations.read_bytes()).hexdigest(),
    },
}
(root / "unsigned-index.json").write_bytes(canonical({
    "schema_version": "malibu-release-index.v1",
    "signed": payload,
}))
PY
  python3 "$release_tool" sign-index \
    --input "$directory/unsigned-index.json" --private-key "$work/private.pem" \
    --key-id test-key --output "$directory/index.json"
  rm -f "$directory/unsigned-envelope.json" "$directory/unsigned-index.json" "$directory/fixture-times.json"
  chmod 644 "$directory/envelope.json" "$directory/index.json"
}

digest_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

digest_app() {
  "$transaction" inspect --app "$1" --expected-owner-uid "$uid" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["tree_sha256"])'
}

install_to() {
  local app="$1" sidecars="$2" target="$3" target_state="$4"
  local generation
  generation="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["signed"]["index_generation"])' "$sidecars/index.json")"
  "$transaction" install \
    --source-app "$app" \
    --destination-app "$target" \
    --state-dir "$target_state" \
    --envelope "$sidecars/envelope.json" \
    --index "$sidecars/index.json" \
    --keyring "$work/keyring.json" \
    --revocations "$work/revocations.json" \
    --expected-key-id test-key \
    --minimum-keyring-generation 1 \
    --minimum-index-generation "$generation" \
    --minimum-envelope-generation "$generation" \
    --expected-owner-uid "$uid"
}

install_app() {
  install_to "$1" "$2" "$destination" "$state"
}

make_rollback_auth_from() {
  local transaction_path="$1" output="$2" mode="${3:-valid}" nonce_seed="${4:-1}"
  python3 - "$transaction_path" "$output.unsigned" "$mode" "$nonce_seed" <<'PY'
import datetime as dt
import json
import pathlib
import sys
record = json.loads(pathlib.Path(sys.argv[1]).read_text())
mode = sys.argv[3]
now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
if mode == "expired":
    issued = now - dt.timedelta(hours=2)
    expires = issued + dt.timedelta(minutes=30)
elif mode == "future":
    issued = now + dt.timedelta(hours=2)
    expires = issued + dt.timedelta(minutes=30)
else:
    issued = now - dt.timedelta(seconds=30)
    expires = now + dt.timedelta(minutes=30)
current = dict(record["installed_release_state"])
target = dict(record["previous_release_state"])
if mode == "wrong-current":
    current["build"] += 1
payload = {
    "current": current,
    "expires_at": expires.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "incident": "INC-585-TEST",
    "issued_at": issued.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "issuer": "release-security-test",
    "nonce": format(int(sys.argv[4]), "064x"),
    "target": target,
}
pathlib.Path(sys.argv[2]).write_text(json.dumps({
    "schema_version": "malibu-release-rollback.v1",
    "signed": payload,
}, sort_keys=True, separators=(",", ":")))
PY
  if [[ "$mode" == "expired" ]]; then
    local historical_now
    historical_now="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["signed"]["issued_at"])' "$output.unsigned")"
    python3 "$release_tool" sign-rollback --input "$output.unsigned" \
      --private-key "$work/private.pem" --key-id test-key --output "$output" --now "$historical_now"
  else
    python3 "$release_tool" sign-rollback --input "$output.unsigned" \
      --private-key "$work/private.pem" --key-id test-key --output "$output"
  fi
  rm -f "$output.unsigned"
  chmod 644 "$output"
}

make_rollback_auth() {
  make_rollback_auth_from "$state/active/transaction.json" "$@"
}

rollback_to() {
  local target="$1" target_state="$2" authorization="$3"
  local authorization_sha256
  authorization_sha256="$(shasum -a 256 "$authorization" | awk '{print $1}')"
  "$transaction" rollback \
    --destination-app "$target" \
    --state-dir "$target_state" \
    --authorization "$authorization" \
    --expected-authorization-sha256 "$authorization_sha256" \
    --keyring "$work/keyring.json" \
    --revocations "$work/revocations.json" \
    --expected-key-id test-key \
    --minimum-keyring-generation 1 \
    --expected-owner-uid "$uid"
}

rollback_app() {
  rollback_to "$destination" "$state" "$1"
}

snapshot_unowned() {
  find "$work/unowned" -type f -print0 | sort -z | xargs -0 shasum -a 256
}

make_app "$work/input/old/Malibu.app" 1.8.39 39 old
make_app "$work/input/new/Malibu.app" 1.8.41 41 new
"$transaction" inspect --app "$work/input/old/Malibu.app" --expected-owner-uid "$uid" \
  > "$work/legacy-app-evidence.json"
make_sidecars "$work/input/old" 1.8.39 39 39
make_sidecars "$work/input/new" 1.8.41 41 41
mkdir -p "$work/input/tampered"
cp -R "$work/input/new/Malibu.app" "$work/input/tampered/Malibu.app"
mkdir -p "$work/Applications/Tampered"
chmod 755 "$work/Applications/Tampered"
printf 'same version and build, different bytes\n' > \
  "$work/input/tampered/Malibu.app/Contents/Resources/release.txt"
if install_to \
  "$work/input/tampered/Malibu.app" "$work/input/new" \
  "$work/Applications/Tampered/Malibu.app" "$work/Tampered State/Malibu/Release" \
  >"$work/tampered-tree.out" 2>&1; then
  echo "signed envelope accepted an altered same-version app tree" >&2
  exit 1
fi
grep -q 'source app evidence does not match the signed release sidecars' "$work/tampered-tree.out"
before_unowned="$(snapshot_unowned)"
old_digest="$(digest_app "$work/input/old/Malibu.app")"
new_digest="$(digest_app "$work/input/new/Malibu.app")"

recover_to() {
  "$transaction" recover --destination-app "$1" --state-dir "$2" --expected-owner-uid "$uid"
}

run_install_crash_case() {
  local point="$1" expected="$2"
  local root="$work/install-crash-$point"
  local target="$root/Applications/Malibu.app"
  local target_state="$root/State/Malibu/Release"
  mkdir -p "$root/Applications"
  chmod 755 "$root" "$root/Applications"
  install_to "$work/input/old/Malibu.app" "$work/input/old" "$target" "$target_state" >/dev/null
  set +e
  MALIBU_TRANSACTION_CRASH_AT="$point" \
    install_to "$work/input/new/Malibu.app" "$work/input/new" "$target" "$target_state" >/dev/null 2>&1
  local status=$?
  set -e
  test "$status" -eq 86
  test -f "$target_state/transaction-journal.json"
  recover_to "$target" "$target_state" >"$root/recovery.json"
  test ! -e "$target_state/transaction-journal.json"
  if [[ "$expected" == "old" ]]; then
    test "$(digest_app "$target")" = "$old_digest"
    grep -q '"recovered": "old"' "$root/recovery.json"
  else
    test "$(digest_app "$target")" = "$new_digest"
    grep -q '"recovered": "new"' "$root/recovery.json"
  fi
  python3 - "$target_state/active/transaction.json" "$target" "$transaction" "$uid" <<'PY'
import json, pathlib, subprocess, sys
record = json.loads(pathlib.Path(sys.argv[1]).read_text())
actual = json.loads(subprocess.check_output([
    sys.argv[3], "inspect", "--app", sys.argv[2], "--expected-owner-uid", sys.argv[4],
], text=True))
assert record["installed"] == actual
PY
}

for crash_case in \
  after_journal_prepared:old \
  after_app_swap_before_phase:old \
  after_app_swapped:new \
  after_state_swap_before_phase:new \
  after_state_committed:new; do
  run_install_crash_case "${crash_case%%:*}" "${crash_case##*:}"
done

run_rollback_crash_case() {
  local point="$1" expected="$2" nonce_seed="$3"
  local root="$work/rollback-crash-$point"
  local target="$root/Applications/Malibu.app"
  local target_state="$root/State/Malibu/Release"
  local authorization="$root/rollback.json"
  mkdir -p "$root/Applications"
  chmod 755 "$root" "$root/Applications"
  install_to "$work/input/old/Malibu.app" "$work/input/old" "$target" "$target_state" >/dev/null
  install_to "$work/input/new/Malibu.app" "$work/input/new" "$target" "$target_state" >/dev/null
  make_rollback_auth_from "$target_state/active/transaction.json" "$authorization" valid "$nonce_seed"
  set +e
  MALIBU_TRANSACTION_CRASH_AT="$point" \
    rollback_to "$target" "$target_state" "$authorization" >/dev/null 2>&1
  local status=$?
  set -e
  test "$status" -eq 86
  test -f "$target_state/transaction-journal.json"
  recover_to "$target" "$target_state" >"$root/recovery.json"
  test ! -e "$target_state/transaction-journal.json"
  if [[ "$expected" == "old" ]]; then
    test "$(digest_app "$target")" = "$new_digest"
    grep -q '"recovered": "old"' "$root/recovery.json"
  else
    test "$(digest_app "$target")" = "$old_digest"
    grep -q '"recovered": "new"' "$root/recovery.json"
  fi
  transaction_digest="$(digest_file "$target_state/active/transaction.json")"
  if [[ "$expected" == "old" ]]; then
    rollback_to "$target" "$target_state" "$authorization" >"$root/retry.json"
    test "$(digest_app "$target")" = "$old_digest"
    transaction_digest="$(digest_file "$target_state/active/transaction.json")"
    test "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["transaction_sha256"])' "$root/retry.json")" = "$transaction_digest"
  else
    if rollback_to "$target" "$target_state" "$authorization" >"$root/replay.out" 2>&1; then
      echo "committed rollback authorization unexpectedly replayed" >&2
      exit 1
    fi
    grep -q 'nonce was already consumed by a committed rollback' "$root/replay.out"
  fi
  completed_receipt="$(find "$target_state/rollback-authorizations" -name 'completed-*.json' -type f)"
  test -n "$completed_receipt"
  test "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["transaction_sha256"])' "$completed_receipt")" = "$transaction_digest"
  test ! -e "$(dirname "$completed_receipt")/$(basename "$completed_receipt" | sed 's/^completed-/pending-/')"
}

rollback_nonce=100
for crash_case in \
  after_journal_prepared:old \
  after_pending_receipt:old \
  after_app_swap_before_phase:old \
  after_app_swapped:new \
  after_state_swap_before_phase:new \
  after_state_committed:new; do
  run_rollback_crash_case "${crash_case%%:*}" "${crash_case##*:}" "$rollback_nonce"
  rollback_nonce=$((rollback_nonce + 1))
done

# Establish the old app through the same signed transaction so that a later
# operator rollback has exact signed current->target evidence.
install_app "$work/input/old/Malibu.app" "$work/input/old" >/dev/null

# A normal install changes only Malibu.app and app-owned release state.  Simulated
# provider CLI/config activity afterwards cannot select or overwrite Malibu.
install_app "$work/input/new/Malibu.app" "$work/input/new" >/dev/null
test "$(digest_app "$destination")" = "$new_digest"
test "$(snapshot_unowned)" = "$before_unowned"
printf 'provider cli update completed without app mutation\n' >>"$work/unowned/provider/sentinel"
after_cli_digest="$(digest_app "$destination")"
test "$after_cli_digest" = "$new_digest"

if install_app "$work/input/old/Malibu.app" "$work/input/old" >"$work/implicit-downgrade.out" 2>&1; then
  echo "normal install accepted an arbitrary downgrade" >&2
  exit 1
fi
grep -q 'must increase the Malibu build' "$work/implicit-downgrade.out"
test "$(digest_app "$destination")" = "$new_digest"

# Rollback has no target argument: it consumes only the exact immediate backup
# and refuses a second/arbitrary downgrade.
make_rollback_auth "$work/rollback-valid.json" valid 1
cp "$state/active/transaction.json" "$work/transaction.saved"
python3 - "$state/active/transaction.json" "$work/unowned/provider" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text())
value["rollback_backup"] = sys.argv[2]
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
PY
chmod 600 "$state/active/transaction.json"
if rollback_app "$work/rollback-valid.json" >"$work/arbitrary-rollback.out" 2>&1; then
  echo "caller-selected rollback backup unexpectedly succeeded" >&2
  exit 1
fi
grep -q 'unsafe rollback backup' "$work/arbitrary-rollback.out"
test "$(digest_app "$destination")" = "$new_digest"
cp "$work/transaction.saved" "$state/active/transaction.json"
chmod 600 "$state/active/transaction.json"

chmod 666 "$state/active/transaction.json"
if rollback_app "$work/rollback-valid.json" >"$work/metadata-mode.out" 2>&1; then
  echo "world-writable rollback evidence unexpectedly succeeded" >&2
  exit 1
fi
grep -q 'must not be group/world writable' "$work/metadata-mode.out"
chmod 600 "$state/active/transaction.json"

make_rollback_auth "$work/rollback-wrong-current.json" wrong-current 2
if rollback_app "$work/rollback-wrong-current.json" >"$work/wrong-current.out" 2>&1; then
  echo "wrong-current rollback authorization unexpectedly succeeded" >&2
  exit 1
fi
grep -q 'current or target state binding differs' "$work/wrong-current.out"

if "$transaction" rollback --destination-app "$destination" --state-dir "$state" \
  --authorization "$work/rollback-wrong-current.json" \
  --expected-authorization-sha256 "$(printf '0%.0s' {1..64})" \
  --keyring "$work/keyring.json" --revocations "$work/revocations.json" \
  --expected-key-id test-key --minimum-keyring-generation 1 \
  --expected-owner-uid "$uid" >"$work/wrong-digest.out" 2>&1; then
  echo "rollback accepted authorization bytes that differed from the caller digest" >&2
  exit 1
fi
grep -q 'differs from the caller-validated bytes' "$work/wrong-digest.out"

make_rollback_auth "$work/rollback-expired.json" expired 3
if rollback_app "$work/rollback-expired.json" >"$work/expired.out" 2>&1; then
  echo "expired rollback authorization unexpectedly succeeded" >&2
  exit 1
fi
grep -q 'rollback: expired' "$work/expired.out"

make_rollback_auth "$work/rollback-consumed.json" valid 4
active_before_rollback="$(digest_file "$state/active/transaction.json")"
if MALIBU_TRANSACTION_FAIL_AT=after_rollback_replace rollback_app "$work/rollback-consumed.json" \
  >"$work/rollback-replace.out" 2>&1; then
  echo "rollback replacement failure injection unexpectedly succeeded" >&2
  exit 1
fi
test "$(digest_app "$destination")" = "$new_digest"
test "$(digest_file "$state/active/transaction.json")" = "$active_before_rollback"
rollback_app "$work/rollback-consumed.json" >"$work/retry-after-failure.json"
test "$(digest_app "$destination")" = "$old_digest"
retry_transaction_digest="$(digest_file "$state/active/transaction.json")"
test "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["transaction_sha256"])' "$work/retry-after-failure.json")" = "$retry_transaction_digest"

# Re-establish the newer app after proving that a pending receipt is retryable.
install_app "$work/input/new/Malibu.app" "$work/input/new" >/dev/null
test "$(digest_app "$destination")" = "$new_digest"

make_rollback_auth "$work/rollback-final.json" valid 5
rollback_app "$work/rollback-final.json" >"$work/rollback-final.out"
test "$(digest_app "$destination")" = "$old_digest"
if rollback_app "$work/rollback-final.json" >"$work/second-rollback.out" 2>&1; then
  echo "second rollback unexpectedly succeeded" >&2
  exit 1
fi
grep -q 'nonce was already consumed by a committed rollback' "$work/second-rollback.out"

# Failure after staging leaves the existing app byte-for-byte unchanged.
MALIBU_TRANSACTION_FAIL_AT=after_stage install_app "$work/input/new/Malibu.app" "$work/input/new" >"$work/after-stage.out" 2>&1 && {
  echo "after-stage failure injection unexpectedly succeeded" >&2
  exit 1
}
test "$(digest_app "$destination")" = "$old_digest"

# Failure after atomic replacement exchanges the exact previous app back and
# does not publish new active transaction evidence.
active_before="$(digest_file "$state/active/transaction.json")"
MALIBU_TRANSACTION_FAIL_AT=after_replace install_app "$work/input/new/Malibu.app" "$work/input/new" >"$work/after-replace.out" 2>&1 && {
  echo "after-replace failure injection unexpectedly succeeded" >&2
  exit 1
}
test "$(digest_app "$destination")" = "$old_digest"
test "$(digest_file "$state/active/transaction.json")" = "$active_before"

# Invalid signatures, revoked keys, and replacement trust roots all fail before
# transaction state or Malibu.app mutation.
cp "$work/input/new/index.json" "$work/input/new/bad-index.json"
python3 - "$work/input/new/bad-index.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text())
value["signature"]["signature"] = "AA"
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")))
PY
mv "$work/input/new/index.json" "$work/input/new/good-index.json"
mv "$work/input/new/bad-index.json" "$work/input/new/index.json"
if install_app "$work/input/new/Malibu.app" "$work/input/new" >"$work/bad-signature.out" 2>&1; then
  echo "invalid signed release index unexpectedly succeeded" >&2
  exit 1
fi
grep -q 'invalid ECDSA P-256 signature' "$work/bad-signature.out"
mv "$work/input/new/index.json" "$work/input/new/bad-index.json"
mv "$work/input/new/good-index.json" "$work/input/new/index.json"
test "$(digest_app "$destination")" = "$old_digest"

cp "$work/revocations.json" "$work/revocations.saved"
python3 - "$work/revocations.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text())
value["revoked_key_ids"] = ["test-key"]
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")))
PY
if install_app "$work/input/new/Malibu.app" "$work/input/new" >"$work/revoked.out" 2>&1; then
  echo "revoked release signing key unexpectedly succeeded" >&2
  exit 1
fi
grep -q 'key_id is revoked' "$work/revoked.out"
mv "$work/revocations.saved" "$work/revocations.json"
test "$(digest_app "$destination")" = "$old_digest"

if python3 "$production_transaction" verify-bundle \
  --envelope "$work/input/new/envelope.json" --index "$work/input/new/index.json" \
  --keyring "$work/keyring.json" --revocations "$work/revocations.json" \
  --expected-key-id test-key --minimum-keyring-generation 1 \
  --minimum-index-generation 41 --minimum-envelope-generation 41 --minimum-build 41 \
  >"$work/unpinned.out" 2>&1; then
  echo "self-signed replacement trust root unexpectedly succeeded" >&2
  exit 1
fi
grep -q 'hard-pinned production SPKI digest' "$work/unpinned.out"

cp "$work/keyring.json" "$work/keyring-escape.json"
python3 - "$work/keyring-escape.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text())
value["keys"][0]["public_key_path"] = "../public.pem"
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")))
PY
if "$transaction" verify-bundle \
  --envelope "$work/input/new/envelope.json" --index "$work/input/new/index.json" \
  --keyring "$work/keyring-escape.json" --revocations "$work/revocations.json" \
  --expected-key-id test-key --minimum-keyring-generation 1 \
  --minimum-index-generation 41 --minimum-envelope-generation 41 --minimum-build 41 \
  >"$work/key-escape.out" 2>&1; then
  echo "escaping public-key path unexpectedly succeeded" >&2
  exit 1
fi
grep -q 'escapes the self-contained trust bundle' "$work/key-escape.out"

mv "$work/public.pem" "$work/public.real.pem"
ln -s "$work/public.real.pem" "$work/public.pem"
if "$transaction" verify-bundle \
  --envelope "$work/input/new/envelope.json" --index "$work/input/new/index.json" \
  --keyring "$work/keyring.json" --revocations "$work/revocations.json" \
  --expected-key-id test-key --minimum-keyring-generation 1 \
  --minimum-index-generation 41 --minimum-envelope-generation 41 --minimum-build 41 \
  >"$work/key-symlink.out" 2>&1; then
  echo "symlinked public key unexpectedly succeeded" >&2
  exit 1
fi
grep -q 'symlink ancestor' "$work/key-symlink.out"
rm "$work/public.pem"
mv "$work/public.real.pem" "$work/public.pem"

# App path, owner, mode, and symlink safety all fail closed.
ln -s "$work/input/new/Malibu.app/Contents/Resources/release.txt" "$work/input/new/Malibu.app/Contents/Resources/link"
if "$transaction" inspect --app "$work/input/new/Malibu.app" --expected-owner-uid "$uid" >"$work/symlink.out" 2>&1; then
  echo "symlink-bearing app unexpectedly passed inspection" >&2
  exit 1
fi
grep -q 'contains symlink' "$work/symlink.out"
rm "$work/input/new/Malibu.app/Contents/Resources/link"

chmod 666 "$work/input/new/Malibu.app/Contents/Resources/release.txt"
if "$transaction" inspect --app "$work/input/new/Malibu.app" --expected-owner-uid "$uid" >"$work/mode.out" 2>&1; then
  echo "world-writable app unexpectedly passed inspection" >&2
  exit 1
fi
grep -q 'group/world writable' "$work/mode.out"
chmod 644 "$work/input/new/Malibu.app/Contents/Resources/release.txt"

if "$transaction" inspect --app "$work/input/new/Malibu.app" --expected-owner-uid "$((uid + 1))" >"$work/owner.out" 2>&1; then
  echo "wrong-owner app unexpectedly passed inspection" >&2
  exit 1
fi
grep -q 'unexpected owner uid' "$work/owner.out"

if install_to "$work/input/new/Malibu.app" "$work/input/new" \
  "$work/Applications/../Applications/Malibu.app" "$state" >"$work/traversal.out" 2>&1; then
  echo "path traversal unexpectedly succeeded" >&2
  exit 1
fi
grep -q 'without traversal components' "$work/traversal.out"

ln -s "$work/Application Support" "$work/StateLink"
if install_to "$work/input/new/Malibu.app" "$work/input/new" \
  "$destination" "$work/StateLink/Malibu/Release" >"$work/state-symlink.out" 2>&1; then
  echo "symlinked state path unexpectedly succeeded" >&2
  exit 1
fi
grep -q 'symlink ancestor' "$work/state-symlink.out"

# A fresh install has no signed previous state, so operator rollback is disabled
# rather than accepting an unsigned target.
fresh_destination="$work/Fresh/Malibu.app"
fresh_state="$work/Fresh State/Malibu/Release"
mkdir -p "$work/Fresh"
chmod 755 "$work/Fresh"
install_to "$work/input/new/Malibu.app" "$work/input/new" "$fresh_destination" "$fresh_state" >/dev/null
if "$transaction" rollback --destination-app "$fresh_destination" --state-dir "$fresh_state" \
  --authorization "$work/rollback-final.json" \
  --expected-authorization-sha256 "$(shasum -a 256 "$work/rollback-final.json" | awk '{print $1}')" \
  --keyring "$work/keyring.json" \
  --revocations "$work/revocations.json" --expected-key-id test-key \
  --minimum-keyring-generation 1 --expected-owner-uid "$uid" >"$work/fresh-rollback.out" 2>&1; then
  echo "fresh install accepted an unsigned rollback target" >&2
  exit 1
fi
grep -q 'no previously validated signed release' "$work/fresh-rollback.out"
test "$(digest_app "$fresh_destination")" = "$new_digest"

# The supported DMG layout is exactly the workflow's app plus convenience link.
mkdir -p "$work/dmg-layout/Malibu.app"
ln -s /Applications "$work/dmg-layout/Applications"
"$repo_root/scripts/install-malibu-app.sh" --check-mounted-layout "$work/dmg-layout"
touch "$work/dmg-layout/unexpected"
if "$repo_root/scripts/install-malibu-app.sh" --check-mounted-layout "$work/dmg-layout" >"$work/layout-extra.out" 2>&1; then
  echo "unexpected DMG top-level member passed layout validation" >&2
  exit 1
fi
grep -q 'unexpected top-level members' "$work/layout-extra.out"
rm "$work/dmg-layout/unexpected" "$work/dmg-layout/Applications"
ln -s /tmp "$work/dmg-layout/Applications"
if "$repo_root/scripts/install-malibu-app.sh" --check-mounted-layout "$work/dmg-layout" >"$work/layout-link.out" 2>&1; then
  echo "wrong Applications link passed layout validation" >&2
  exit 1
fi
grep -q 'exact Applications' "$work/layout-link.out"

# Static scope guard: the transaction has no privilege, provider, launchd,
# Keychain, config, or compatibility-marker mutation surface.
if rg -n 'sudo|launchctl|security[[:space:]]|provider\.json|config\.yaml|Keychain' \
  "$repo_root/scripts/malibu-app-transaction.py" "$repo_root/scripts/malibu-app-transaction.sh"; then
  echo "transaction contains a forbidden mutation surface" >&2
  exit 1
fi

echo "Malibu app-only transaction checks passed"
