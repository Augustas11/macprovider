#!/usr/bin/env bash
# Offline behaviour tests for the ops entry points. Nothing leaves this
# machine: the repo is cloned into a temp dir whose `origin` is a local bare
# repo, `gh` and `ssh` are stubs (scripts/ops/tests/), and the coordinator,
# gateway and provider status are a loopback fake (tests/fake_services.py).
# The scripts under test are the working-tree copies of scripts/ops.
#
# Covers: pearl-runtime refusal on an unknown code comparison and on unsafe
# versions, the clean-origin/main precondition, the re-decision after taking
# the lock; cli-release structured evidence for canary_smoke and e2e_gate and
# the gated promotion; the runnable Pearl config steps (one-time privacy setup,
# the recommendation bump, pricing-journal / validation / restart-failure
# refusals) and repository admission (SPEC-002-R004: exact revocation, an old
# runtime, a live policy that differs from the applied config)
# against a fake Pearl (tests/fake_pearl_systemctl.py); catalog-activate's
# provider-tied gateway proof and its 24 h expiry.
# Usage: bash scripts/ops/test-entrypoints.sh
set -euo pipefail

OPS_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_REPO="$(cd "$OPS_SRC/../.." && pwd)"
tmp="$(mktemp -d)"
server_pid=""
cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$*"; }

# ---- release versions --------------------------------------------------------
# The cli-release fixture models the checked-in train state: live stable is the
# checked-in latest_binary_version row and the candidate is binaryVersion, so a
# version bump on main does not leave this suite pinned to an old release.
CAND="$(sed -n 's/.*static let binaryVersion = "\([0-9][0-9.]*\)".*/\1/p' \
  "$SRC_REPO/phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift" | head -n 1)"
LIVE="$(sed -n 's/^ *latest_binary_version: "\([0-9][0-9.]*\)".*/\1/p' \
  "$SRC_REPO/phase4-coordinator/dist/coordinator.yaml" | head -n 1)"
[ -n "$CAND" ] && [ -n "$LIVE" ] && [ "$CAND" != "$LIVE" ] || {
  printf 'cannot derive candidate/live versions (binaryVersion=%s latest_binary_version=%s)\n' "$CAND" "$LIVE" >&2
  exit 1
}

# ---- repo fixture -----------------------------------------------------------
git clone -q --bare --shared "$SRC_REPO" "$tmp/origin.git"
git clone -q --shared --no-checkout "$tmp/origin.git" "$tmp/work"
# The candidate's release tag starts absent, whatever the source repo holds.
git -C "$tmp/origin.git" tag -d "v$CAND" >/dev/null 2>&1 || true
git -C "$tmp/work" tag -d "v$CAND" >/dev/null 2>&1 || true
W="$tmp/work"
git -C "$W" checkout -q --detach "$(git -C "$SRC_REPO" rev-parse HEAD)"
git -C "$W" checkout -q -B main
rm -rf "$W/scripts/ops"
cp -R "$OPS_SRC" "$W/scripts/ops"
find "$W/scripts/ops" -name '__pycache__' -prune -exec rm -rf {} +
printf '\n| Carry-forward CF-OPS-TEST | %s carry-forward of the unchanged decode qualification |\n' "$CAND" \
  >> "$W/docs/releases/cli-release-train.md"
# A throwaway release signing key stands in for the pinned one.
mkdir -p "$tmp/keys"
openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/keys/release.key" 2>/dev/null
openssl ec -in "$tmp/keys/release.key" -pubout -out "$tmp/keys/release.pem" 2>/dev/null
cp "$tmp/keys/release.pem" "$W/ops/pearl-updater/release-signing-public.pem"
# The one-time revocation seed, in the fixture's repository.
SEED1="test/repo:v1.0.1@$(printf '1%.0s' $(seq 40))"
SEED2="test/repo:v1.0.2@$(printf '2%.0s' $(seq 40))"
printf '# test seed\n# below: 1.0.3\n%s\n%s\n' "$SEED1" "$SEED2" > "$W/phase4-coordinator/dist/compatibility-revoked-ids.txt"
# Stand-in for the mirror publisher: records its argv and whether the token and
# key reached it, then moves the fake mirror's latest.json like --promote-latest.
cat > "$W/scripts/publish-release-mirror.sh" <<'FAKEMIRROR'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$FAKE_PEARL/svc/mirror-args"
printf 'token=%s key=%s\n' "${GH_TOKEN:-}" "${MALIBU_DOWNLOAD_SSH_KEY:-}" > "$FAKE_PEARL/svc/mirror-env"
[ -z "${FAKE_MIRROR_FAIL:-}" ] || exit 1
printf '{"tag_name": "%s"}\n' "$2" > "$FAKE_PEARL/svc/mirror-latest.json"
FAKEMIRROR
chmod +x "$W/scripts/publish-release-mirror.sh"
git -C "$W" -c user.name=t -c user.email=t@example.invalid add -A scripts/ops scripts/publish-release-mirror.sh docs/releases/cli-release-train.md \
  ops/pearl-updater/release-signing-public.pem phase4-coordinator/dist/compatibility-revoked-ids.txt
git -C "$W" -c user.name=t -c user.email=t@example.invalid commit -q -m "test: working-tree ops scripts"
git -C "$W" -c user.name=t -c user.email=t@example.invalid tag -a v9.0.0 -m "live runtime"
printf 'package main\n' > "$W/phase4-coordinator/opsprobe.go"
git -C "$W" add phase4-coordinator/opsprobe.go
git -C "$W" -c user.name=t -c user.email=t@example.invalid commit -q -m "test: shipped code change"
git -C "$W" push -q --force origin HEAD:refs/heads/main refs/tags/v9.0.0
git -C "$W" fetch -q origin
B="$(git -C "$W" rev-parse HEAD)"

# ---- stubs and services -------------------------------------------------------
mkdir -p "$tmp/bin" "$tmp/gh" "$tmp/svc"
printf '#!/usr/bin/env bash\nexec python3 %q "$@"\n' "$OPS_SRC/tests/gh_stub.py" > "$tmp/bin/gh"
# ssh stub: run the remote command locally (it only curls the loopback fake
# or reads the fake Pearl files under $tmp/pearl).
# shellcheck disable=SC2016  # the stub's own "$@" must stay literal
printf '#!/usr/bin/env bash\nexec bash -c "${@: -1}"\n' > "$tmp/bin/ssh"
# Pearl's systemctl/journalctl: one fixed coordinator invocation whose journal
# is boot.txt (its coordinator_config_applied event) plus journal.txt.
# systemctl also restarts the fake coordinator (tests/fake_pearl_systemctl.py);
# fake-coordinator --validate-config rejects a config containing INVALID.
printf '#!/usr/bin/env bash\nexec python3 %q "$@"\n' "$OPS_SRC/tests/fake_pearl_systemctl.py" > "$tmp/bin/systemctl"
printf '#!/usr/bin/env bash\ncat %q %q 2>/dev/null || true\n' "$tmp/svc/boot.txt" "$tmp/svc/journal.txt" > "$tmp/bin/journalctl"
# shellcheck disable=SC2016  # the fake's own "$@" must stay literal
printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" = --validate-config ] && v=1; done\n[ -n "${v:-}" ] || exit 2\nwhile [ $# -gt 0 ]; do [ "$1" = --config ] && c="$2"; shift; done\n! grep -q INVALID "$c"\n' > "$tmp/bin/fake-coordinator"
chmod +x "$tmp/bin/gh" "$tmp/bin/ssh" "$tmp/bin/systemctl" "$tmp/bin/journalctl" "$tmp/bin/fake-coordinator"
python3 "$OPS_SRC/tests/fake_services.py" "$tmp/svc" &
server_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$tmp/svc/port" ] && break; sleep 0.3; done
PORT="$(cat "$tmp/svc/port")"

export PATH="$tmp/bin:$PATH"
export GH_STUB_DIR="$tmp/gh"
export MACPROVIDER_OPS_ENV=/dev/null
export MACPROVIDER_GH_REPO=test/repo
export MACPROVIDER_LIVE_LOCK="$tmp/live-ops.lock"
export MACPROVIDER_OPS_STATE_DIR="$tmp/state"
export COORDINATOR_URL="http://127.0.0.1:$PORT" GATEWAY_URL="http://127.0.0.1:$PORT"
export STUDIO_SSH=fake-canary STUDIO_STATUS_PORT="$PORT" PEARL_SSH=fake-pearl
export PROOF_POLL_SECONDS=0
export PEARL_COORDINATOR_CONFIG="$tmp/pearl/coordinator.yaml" PEARL_COORDINATOR_OVERLAY="$tmp/pearl/overlay.yaml"
export FAKE_PEARL="$tmp" PEARL_PROC_ROOT="$tmp/proc" PEARL_INSTALL_ROOT="$tmp/pearl/root"
export PEARL_CONFIG_GUARD="$SRC_REPO/scripts/lib/coordinator_config_guard.py" PEARL_UPDATER_LOCK="$tmp/pearl/updater.lock"
export PEARL_BACKUP_ROOT="$tmp/pearl/backups"
export PEARL_COORDINATOR_HEALTHZ_URL="http://127.0.0.1:$PORT/healthz"
export MIRROR_LATEST_URL="http://127.0.0.1:$PORT/releases/latest.json"
export PEARL_PRIVACY_METADATA_DIR="$tmp/pearl/privacy-release-identities" PEARL_RELEASE_PUBLIC_KEY_PATH="$tmp/keys/release.pem"
mkdir -p "$tmp/pearl/root" "$tmp/proc"
systemctl _init
PEARL_RELEASE_IDENTITY_OWNER="$(id -un)" PEARL_RELEASE_IDENTITY_GROUP="$(id -gn)"
export PEARL_RELEASE_IDENTITY_OWNER PEARL_RELEASE_IDENTITY_GROUP PEARL_COORDINATOR_METRICS_URL="http://127.0.0.1:$PORT/metrics"
unset MACPROVIDER_OPS_OWNER PEARL_RUNTIME_VERSION MACPROVIDER_OPS_ENTRYPOINT GH_TOKEN MALIBU_DOWNLOAD_SSH_KEY

fixture() { printf '%s' "$1" > "$tmp/gh/fixture.json"; rm -f "$tmp/gh"/count-*; }
# health: a repository-admission runtime (its /healthz reports the running
# config's compatibility policy); health_legacy: a runtime that reports none.
health() { printf '{"status":"ok","version":"%s","recommended_binary_version":"%s","uptime_s":100,"_policy":"running"}' "$1" "$2" > "$tmp/svc/healthz.json"; }
health_legacy() { printf '{"status":"ok","version":"%s","recommended_binary_version":"%s","uptime_s":100}' "$1" "$2" > "$tmp/svc/healthz.json"; }

# run_rc WANT DESC CMD... (in the clone)
run_rc() {
  local want="$1" desc="$2" rc=0
  shift 2
  (cd "$W" && "$@") >"$tmp/out" 2>"$tmp/err" || rc=$?
  if [ "$rc" = "$want" ]; then ok; else bad "$desc: want rc=$want got rc=$rc"; sed 's/^/    /' "$tmp/err" | tail -n 5; fi
}
next_field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["next"][sys.argv[2]])' "$tmp/out" "$1" 2>/dev/null || echo "<no status JSON>"; }
expect_next() {
  local want="$1" got
  got="$(next_field id):$(next_field kind)"
  if [ "$got" = "$want" ]; then ok; else bad "next: want $want got $got ($(next_field reason))"; fi
}
fact_of() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["facts"].get(sys.argv[2]))' "$tmp/out" "$1"; }
state_of() { python3 -c 'import json,sys; print(next(s["state"] for s in json.load(open(sys.argv[1]))["steps"] if s["id"] == sys.argv[2]))' "$tmp/out" "$1"; }
# next --run must hand the live-ops lock back on every exit path.
expect_lock_free() { if [ ! -e "$MACPROVIDER_LIVE_LOCK" ]; then ok; else bad "live-ops lock still held after next --run: $(tr -d '\n ' < "$MACPROVIDER_LIVE_LOCK")"; fi; }
expect_err() { if grep -q -- "$1" "$tmp/err"; then ok; else bad "stderr lacks '$1'"; sed 's/^/    /' "$tmp/err" | tail -n 3; fi; }

# ==== pearl-runtime ===========================================================
fixture '{"runs": {}}'
health v9.0.0 $LIVE

PEARL_RUNTIME_VERSION='v9.0.1:refs/heads/x' run_rc 3 "unsafe runtime version refused" scripts/ops/pearl-runtime.sh status
expect_err "PEARL_RUNTIME_VERSION must be vMAJOR.MINOR.PATCH"

health 'v9.0.0;rm' $LIVE
PEARL_RUNTIME_VERSION=v9.0.1 run_rc 0 "invalid live version is not used" scripts/ops/pearl-runtime.sh status
expect_next live_state:blocked

health v9.9.8 $LIVE
PEARL_RUNTIME_VERSION=v9.0.1 run_rc 0 "status with an unknown live tag" scripts/ops/pearl-runtime.sh status
expect_next code_changed:blocked
case "$(next_field reason)" in *"not available locally"*) ok ;; *) bad "unknown comparison reason: $(next_field reason)" ;; esac
PEARL_RUNTIME_VERSION=v9.0.1 MACPROVIDER_OPS_OWNER=t run_rc 3 "unknown comparison refuses --run" scripts/ops/pearl-runtime.sh next --run

health v9.0.0 $LIVE
PEARL_RUNTIME_VERSION=v9.0.1 run_rc 0 "status with a code change" scripts/ops/pearl-runtime.sh status
expect_next signed_tag:mutate

touch "$W/untracked-file"
PEARL_RUNTIME_VERSION=v9.0.1 MACPROVIDER_OPS_OWNER=t run_rc 3 "dirty tree refuses a mutating step" scripts/ops/pearl-runtime.sh next --run
expect_err "working tree is not clean"
rm -f "$W/untracked-file"
git -C "$W" checkout -q --detach HEAD~1
PEARL_RUNTIME_VERSION=v9.0.1 MACPROVIDER_OPS_OWNER=t run_rc 3 "HEAD != origin/main refuses a mutating step" scripts/ops/pearl-runtime.sh next --run
expect_err "is not origin/main"
git -C "$W" checkout -q main
PEARL_RUNTIME_VERSION=v9.0.1 run_rc 3 "clean tree still needs an owner" scripts/ops/pearl-runtime.sh next --run
expect_err "MACPROVIDER_OPS_OWNER is unset"
if git -C "$W" ls-remote --tags origin v9.0.1 | grep -q .; then bad "a refused step created a tag"; else ok; fi

# Re-decision after the lock: the dispatch looks free at first, then a run appears.
git -C "$W" -c user.name=t -c user.email=t@example.invalid tag -a v9.0.1 -m "target" "$B"
git -C "$W" push -q origin refs/tags/v9.0.1
fixture '{"runs": {"pearl-runtime-release.yml": []}, "later_from": 2,
  "runs_later": {"pearl-runtime-release.yml": [{"databaseId": 900, "status": "waiting", "conclusion": "", "headSha": "'"$B"'", "createdAt": "2026-10-09T00:00:00Z"}]}}'
PEARL_RUNTIME_VERSION=v9.0.1 MACPROVIDER_OPS_OWNER=t run_rc 3 "state change after the lock is refused" scripts/ops/pearl-runtime.sh next --run
expect_err "live state changed after taking the lock"
expect_lock_free

# ==== cli-release (structured evidence) =======================================
health v9.0.0 $LIVE
J='"path": ".github/workflows/promote-signed-native-mtp-release-journey.yml"'
fixture '{"latest_stable": "v'"$LIVE"'",
  "runs": {"acceptance-candidate.yml": [{"databaseId": 111, "status": "completed", "conclusion": "success", "headSha": "'"$B"'", "createdAt": "2026-10-09T00:00:00Z"}]},
  "artifacts": {"111": [{"name": "acceptance-candidate-'"$B"'", "expired": false}]},
  "run": {
    "222": {"id": 222, "status": "completed", "conclusion": "failure", "head_sha": "'"$B"'", '"$J"', "display_title": "x", "html_url": "u"},
    "333": {"id": 333, "status": "completed", "conclusion": "success", "head_sha": "0000000000000000000000000000000000000000", '"$J"', "display_title": "unrelated", "html_url": "u"},
    "444": {"id": 444, "status": "completed", "conclusion": "success", "head_sha": "'"$B"'", "path": ".github/workflows/ci.yml", "display_title": "CI", "html_url": "u"},
    "555": {"id": 555, "status": "completed", "conclusion": "success", "head_sha": "'"$B"'", '"$J"', "display_title": "journey", "html_url": "u"}},
  "logs": {"333": "nothing relevant here"}}'
SCOPE="$tmp/state/cli-release-$CAND"
mkdir -p "$SCOPE"
# Verified candidate bytes: a signed pearl-release.json naming the candidate code identity.
CDHASH="$(printf 'cd%.0s' $(seq 20))"
mkdir -p "$tmp/bytes" "$tmp/pearl"
printf '{"schema_version":1,"tag":"v%s","provider_advertised_version":"%s","provider_code_identity":{"asset":"macprovider-cli-v%s-darwin-arm64.tar.gz","member":"macprovider-cli","binary_version":"%s","binary_sha256":"%s","team_id":"ABCDE12345","signing_identifier":"live.malibu.provider.cli","slices":[{"arch":"arm64","code_cdhash":"%s"}]}}\n' \
  "$CAND" "$CAND" "$CAND" "$CAND" "$(printf 'ef%.0s' $(seq 32))" "$CDHASH" > "$tmp/bytes/pearl-release.json"
openssl dgst -sha256 -sign "$tmp/keys/release.key" -out "$tmp/bytes/pearl-release.json.sig" "$tmp/bytes/pearl-release.json"
printf '{"step":"signed_byte_verification","run_id":"111","candidate_sha":"%s","checksums_sha256":"%s","compatibility_set_id":"test/repo:v'"$CAND"'@%s","bytes_dir":"%s"}\n' \
  "$B" "$(printf 'ab%.0s' $(seq 32))" "$B" "$tmp/bytes" > "$SCOPE/signed_byte_verification.json"
# Fake Pearl config, laid out like Pearl's: everything in the base file.
OLD="test/repo:v$LIVE@$(printf '0%.0s' $(seq 40))"
pearl_config() {  # pearl_config "ACCEPTED_ID ..." METADATA_DIR_OR_EMPTY [APPROVED_CDHASH]
  {
    printf 'listen:\n  bind_address: 127.0.0.1\ncoordinator:\n  compatibility_set:\n    target_id: %s\n    accepted_ids:\n' "${TARGET_ID:-$OLD}"
    for id in $1; do printf '    - %s\n' "$id"; done
    # The seed is applied unless NO_SEED is set; REVOKED adds one more id.
    if [ -z "${NO_SEED:-}" ] || [ -n "${REVOKED:-}" ]; then
      printf '    revoked_ids:\n'
      [ -n "${NO_SEED:-}" ] || printf '    - %s\n    - %s\n' "$SEED1" "$SEED2"
      [ -z "${REVOKED:-}" ] || printf '    - %s\n' "$REVOKED"
    fi
    printf '  require_gateway_context: true\ncoordinator_advertised_version:\n  latest_binary_version: "%s"\n' "$LIVE"
    printf 'privacy_class:\n  enabled: true\n'
    [ -z "$2" ] || printf '  release_code_identities:\n    metadata_dir: %s\n    public_key_path: %s\n' "$2" "$tmp/keys/release.pem"
    [ -z "${3:-}" ] || printf '  approved_code_identities:\n  - team_id: ABCDE12345\n    signing_identifier: live.malibu.provider.cli\n    code_cdhash: %s\n    binary_version: "%s"\n' "$3" "$CAND"
    printf '  allowed_se_key_backends:\n  - file\n'
  } > "$tmp/pearl/coordinator.yaml"
  printf 'relay_blind:\n  enabled: true\n' > "$tmp/pearl/overlay.yaml"
}
# pearl_boot: the running coordinator (re)starts with the config now on disk.
pearl_boot() {
  cp "$tmp/pearl/coordinator.yaml" "$tmp/svc/running.yaml"
  printf '{"level":"info","config_sha256":"%s","overlay_sha256":"%s","source":"boot","event":"coordinator_config_applied","message":"coordinator config applied"}\n' \
    "$(shasum -a 256 "$tmp/pearl/coordinator.yaml" | awk '{print $1}')" "$(shasum -a 256 "$tmp/pearl/overlay.yaml" | awk '{print $1}')" > "$tmp/svc/boot.txt"
}
# loaded VERSION...: the release versions the running coordinator reports as loaded.
loaded() { for v in "$@"; do printf 'relayblind_privacy_release_identity_loaded{binary_version="%s"} 1\n' "$v"; done > "$tmp/svc/loaded.txt"; }
COMPAT="test/repo:v$CAND@$B"
META="$tmp/pearl/privacy-release-identities"
restarts() { cat "$tmp/svc/restarts" 2>/dev/null || echo 0; }

# One run: the one-time setup (one restart) and the identity staging, under the live lock with the downtime banner.
pearl_config "$OLD" ""
pearl_boot
# A config Pearl cannot parse never echoes its bytes (secrets included).
cp "$tmp/pearl/coordinator.yaml" "$tmp/pearl/good.yaml"
printf 'auth:\n  operator_key: "FAKE-SECRET-4242\n  other: [\n' >> "$tmp/pearl/coordinator.yaml"
run_rc 0 "cli status with an unparseable Pearl config" scripts/ops/cli-release.sh status
if grep -q "FAKE-SECRET-4242" "$tmp/out" "$tmp/err"; then bad "config secret echoed in status output"; else ok; fi
case "$(fact_of privacy_release_metadata_dir)" in *"failed reading coordinator.yaml ("*")"*) ok ;; *) bad "no redacted parse error: $(fact_of privacy_release_metadata_dir)" ;; esac
cp "$tmp/pearl/good.yaml" "$tmp/pearl/coordinator.yaml"
run_rc 0 "cli status without a Pearl metadata_dir" scripts/ops/cli-release.sh status
expect_next privacy_release_setup:mutate
case "$(next_field command)" in
  *"--accepted-id"*) bad "setup still edits accepted_ids: $(next_field command)" ;;
  *"_pearl-config --privacy-setup $META "*"_stage-privacy-identity $CAND"*) ok ;;
  *) bad "setup command: $(next_field command)" ;;
esac
case "$(next_field expected_downtime)" in *"coordinator restart"*) ok ;; *) bad "no downtime banner for the setup" ;; esac
if [ "$(fact_of privacy_release_metadata_dir)" = "unset" ]; then ok; else bad "privacy_release_metadata_dir fact: $(fact_of privacy_release_metadata_dir)"; fi
run_rc 3 "privacy step refuses without a metadata_dir" scripts/ops/cli-release.sh _stage-privacy-identity "$CAND"
expect_err "privacy_release_setup"
run_rc 3 "_pearl-config refuses outside next --run" scripts/ops/cli-release.sh _pearl-config --recommend "$CAND" "$COMPAT"
expect_err "runs only from"
touch "$tmp/pearl/root/.pricing-txn"
MACPROVIDER_OPS_OWNER=t run_rc 1 "a pricing transaction journal refuses the edit" scripts/ops/cli-release.sh next --run
expect_lock_free
rm -f "$tmp/pearl/root/.pricing-txn"
printf '# INVALID marker\n' >> "$tmp/pearl/coordinator.yaml"; pearl_boot
cp "$tmp/pearl/coordinator.yaml" "$tmp/pearl/before.yaml"
MACPROVIDER_OPS_OWNER=t run_rc 3 "a config the running binary rejects is never installed" scripts/ops/cli-release.sh next --run
expect_lock_free
expect_err "rejects the edited config"
if cmp -s "$tmp/pearl/coordinator.yaml" "$tmp/pearl/before.yaml" && [ "$(restarts)" = 0 ]; then ok; else bad "a rejected edit changed the config or restarted"; fi
pearl_config "$OLD" ""; pearl_boot; cp "$tmp/pearl/coordinator.yaml" "$tmp/pearl/before.yaml"
MACPROVIDER_OPS_OWNER=t run_rc 0 "setup and staging in one run" scripts/ops/cli-release.sh next --run
expect_lock_free
grep -q "EXPECTED DOWNTIME" "$tmp/out" && ok || bad "no downtime banner printed"
if [ "$(restarts)" = 1 ]; then ok; else bad "want one shared restart, got $(restarts)"; fi
if python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); c=d["coordinator"]["compatibility_set"]; r=d["privacy_class"]["release_code_identities"]; sys.exit(0 if sys.argv[2] not in c["accepted_ids"] and sys.argv[3] in c["accepted_ids"] and r["metadata_dir"] == sys.argv[4] else 1)' \
  "$tmp/pearl/coordinator.yaml" "$COMPAT" "$OLD" "$META"; then ok; else bad "config edit not applied as intended"; fi
if [ -n "$(ls "$tmp/pearl/backups" 2>/dev/null)" ]; then ok; else bad "no backup under the backup root"; fi
if diff <(grep -v -e "$COMPAT" -e release_code_identities -e "metadata_dir:" -e "public_key_path:" "$tmp/pearl/coordinator.yaml") "$tmp/pearl/before.yaml" >/dev/null; then ok; else bad "the edit touched other lines"; fi
if cmp -s "$META/v$CAND.json" "$tmp/bytes/pearl-release.json" && cmp -s "$META/v$CAND.json.sig" "$tmp/bytes/pearl-release.json.sig"; then ok; else bad "staged files differ from the candidate bytes"; fi
run_rc 0 "cli status after staging" scripts/ops/cli-release.sh status
if [ "$(state_of privacy_release_identity)" = "done" ]; then ok; else bad "staged file not detected as done"; fi
if [ "$(fact_of privacy_release_metadata_dir)" = "$META" ]; then ok; else bad "privacy_release_metadata_dir fact: $(fact_of privacy_release_metadata_dir)"; fi
step_ids() { python3 -c 'import json,sys; print(" ".join(s["id"] for s in json.load(open(sys.argv[1]))["steps"]))' "$tmp/out"; }
case " $(step_ids) " in
  *" signed_byte_verification revocation_seed privacy_release_setup privacy_release_identity pearl_accepted_ids "*) ok ;;
  *) bad "privacy_release_identity is not right after signed_byte_verification: $(step_ids)" ;;
esac
status_doc() {
  local version="$1" connected="$2" cb_active="${3:-true}" cb_authorized="${4:-true}" cb_load="${5:-live_verified}" cb_proof="${6:-passed}" cb_paged="${7:-attached}" cb_self_check="${8:-null}"
  printf '{"binary_version":"%s","provider_id":"canary-test-id","compatibility_set_id":"test/repo:v'"$CAND"'@%s","coordinator":{"connected":%s},"native_mtp":{"mtp_forwards":5},"requests_total":7,"continuous_batching":{"active":%s,"paged_kv_decision":"%s","self_check":%s,"policy":{"load_status":"%s","authorized":%s,"local_proof_result":"%s","emergency_off_override":false},"scheduler":{"shared_forward_calls":11}}}'     "$version" "$B" "$connected" "$cb_active" "$cb_paged" "$cb_self_check" "$cb_load" "$cb_authorized" "$cb_proof" > "$tmp/svc/status.json"
}

run_rc 0 "cli status" scripts/ops/cli-release.sh status
expect_next canary_smoke:manual
run_rc 3 "free-text canary evidence refused" scripts/ops/cli-release.sh next --done canary_smoke --evidence "looked fine"
expect_err "does not accept free-text"
status_doc $CAND false
run_rc 3 "canary probe with coordinator disconnected" scripts/ops/cli-release.sh next --done canary_smoke --probe
status_doc $LIVE true
run_rc 3 "canary probe on the wrong version" scripts/ops/cli-release.sh next --done canary_smoke --probe
status_doc $CAND true false
run_rc 3 "canary probe with CB inactive" scripts/ops/cli-release.sh next --done canary_smoke --probe
expect_err "continuous_batching.active is not true"
status_doc $CAND true true false
run_rc 3 "canary probe with CB unauthorized" scripts/ops/cli-release.sh next --done canary_smoke --probe
expect_err "continuous_batching.policy.authorized is not true"
status_doc $CAND true true false absent_fallback none attached '{"decision":"granted","served_slots":0}'
run_rc 3 "canary probe with a self-check grant of 0 slots" scripts/ops/cli-release.sh next --done canary_smoke --probe
expect_err "self_check.served_slots 0 < 1"
run_rc 3 "canary run id refused" scripts/ops/cli-release.sh next --done canary_smoke --run-id 555
expect_err "requires --probe"
printf '{"step":"canary_smoke","candidate_sha":"%s","kind":"status_probe","evidence":"old status-only marker"}
' "$B" > "$SCOPE/canary_smoke.json"
run_rc 0 "old status-only canary marker does not unlock e2e" scripts/ops/cli-release.sh status
expect_next canary_smoke:manual
rm -f "$SCOPE/canary_smoke.json"
printf 'test-buyer-token\n' > "$tmp/token"
export BUYER_TOKEN_FILE="$tmp/token" PROBE_MODEL=test/model
printf 'canary-test-id' > "$tmp/svc/provider_id"
printf 'move' > "$tmp/svc/mode"
rm -f "$tmp/svc/served"
# #1947: CB is authorized by the on-device self-check; the signed policy is revocation-only.
status_doc $CAND true true false absent_fallback none attached '{"decision":"granted","served_slots":8}'
printf '{"level":"warn","error":"relayblind: privacy posture rejected: posture_unapproved_code_identity","provider_id":"canary-test-id","message":"privacy key advertisement rejected"}\n' > "$tmp/svc/journal.txt"
run_rc 3 "canary probe refused when Pearl rejects its privacy advertisement" scripts/ops/cli-release.sh next --done canary_smoke --probe
expect_err "rejected the canary's privacy advertisement 1 time"
printf '{"level":"warn","error":"relayblind: privacy posture rejected: posture_unapproved_code_identity","provider_id":"other-provider","message":"privacy key advertisement rejected"}\n' > "$tmp/svc/journal.txt"
rm -f "$tmp/svc/loaded.txt"
run_rc 3 "canary probe refused without positive live registration" scripts/ops/cli-release.sh next --done canary_smoke --probe
expect_err "not registered in the running coordinator"
loaded "$CAND"
run_rc 0 "canary probe on the candidate" scripts/ops/cli-release.sh next --done canary_smoke --probe
rm -f "$tmp/svc/journal.txt"
run_rc 0 "cli status after canary" scripts/ops/cli-release.sh status
expect_next e2e_gate:manual
run_rc 3 "free-text e2e evidence refused" scripts/ops/cli-release.sh next --done e2e_gate --evidence "all green"
run_rc 3 "failed journey run refused" scripts/ops/cli-release.sh next --done e2e_gate --run-id 222
run_rc 3 "run that does not name the candidate refused" scripts/ops/cli-release.sh next --done e2e_gate --run-id 333
expect_err "does not name candidate"
run_rc 3 "non-journey workflow run refused" scripts/ops/cli-release.sh next --done e2e_gate --run-id 444
run_rc 3 "unknown carry-forward refused" scripts/ops/cli-release.sh next --done e2e_gate --carry-forward CF-NOPE
cp -R "$tmp/state" "$tmp/state-cf"
MACPROVIDER_OPS_STATE_DIR="$tmp/state-cf" run_rc 0 "documented carry-forward accepted" scripts/ops/cli-release.sh next --done e2e_gate --carry-forward CF-OPS-TEST
run_rc 0 "journey run naming the candidate accepted" scripts/ops/cli-release.sh next --done e2e_gate --run-id "https://github.com/test/repo/actions/runs/555"
run_rc 0 "cli status after e2e" scripts/ops/cli-release.sh status
expect_next release_tag:mutate
if [ "$(state_of release_tag)" = "pending" ]; then ok; else bad "absent tag not pending"; fi
# The operator's git signing key: a throwaway SSH key trusted for verify-tag.
ssh-keygen -q -t ed25519 -N '' -C t -f "$tmp/keys/git-signing" </dev/null
printf 't@example.invalid %s\n' "$(cat "$tmp/keys/git-signing.pub")" > "$tmp/keys/allowed_signers"
git -C "$W" config user.name t
git -C "$W" config user.email t@example.invalid
git -C "$W" config gpg.format ssh
git -C "$W" config user.signingkey "$tmp/keys/git-signing"
# The gate trusts only the explicit allowlist, never the checkout's git config:
# the config's allowed-signers file also trusts an unapproved key.
ssh-keygen -q -t ed25519 -N '' -C x -f "$tmp/keys/untrusted" </dev/null
cat "$tmp/keys/allowed_signers" > "$tmp/keys/permissive_signers"
printf 't@example.invalid %s\n' "$(cat "$tmp/keys/untrusted.pub")" >> "$tmp/keys/permissive_signers"
git -C "$W" config gpg.ssh.allowedSignersFile "$tmp/keys/permissive_signers"
export MACPROVIDER_RELEASE_TAG_ALLOWED_SIGNERS="$tmp/keys/allowed_signers"
# An annotated tag on the candidate that is unsigned, or signed by an
# untrusted key, does not satisfy the signed-tag gate.
git -C "$W" tag -a "v$CAND" -m unsigned "$B"
git -C "$W" push -q origin "refs/tags/v$CAND"
run_rc 0 "cli status with an unsigned v$CAND on the candidate" scripts/ops/cli-release.sh status
expect_next release_tag:blocked
case "$(next_field reason)" in *"unverified on $B"*) ok ;; *) bad "unsigned tag reason: $(next_field reason)" ;; esac
run_rc 3 "release tag refused for an unsigned tag on the candidate" scripts/ops/cli-release.sh _release-tag "$CAND" "$B"
git -C "$W" push -q origin ":refs/tags/v$CAND"
git -C "$W" tag -d "v$CAND" >/dev/null
git -C "$W" -c user.signingkey="$tmp/keys/untrusted" tag -s -a "v$CAND" -m untrusted "$B"
git -C "$W" push -q origin "refs/tags/v$CAND"
run_rc 0 "cli status with an unapproved signer on v$CAND (trusted by git config only)" scripts/ops/cli-release.sh status
expect_next release_tag:blocked
git -C "$W" push -q origin ":refs/tags/v$CAND"
git -C "$W" tag -d "v$CAND" >/dev/null
# A tag on another commit is never moved or reused.
git -C "$W" tag -a "v$CAND" -m other "$B~1"
git -C "$W" push -q origin "refs/tags/v$CAND"
run_rc 0 "cli status with v$CAND on another commit" scripts/ops/cli-release.sh status
expect_next release_tag:blocked
run_rc 3 "release tag refused when v$CAND exists on another commit" scripts/ops/cli-release.sh _release-tag "$CAND" "$B"
expect_err "refusing to create or move it"
git -C "$W" push -q origin ":refs/tags/v$CAND"
git -C "$W" tag -d "v$CAND" >/dev/null
MACPROVIDER_OPS_OWNER=t run_rc 0 "release_tag creates the signed annotated tag" scripts/ops/cli-release.sh next --run
expect_lock_free
if [ "$(git -C "$W" ls-remote origin "refs/tags/v$CAND^{}" | awk '{print $1}')" = "$B" ] && git -C "$W" verify-tag "v$CAND" 2>/dev/null; then ok; else bad "v$CAND not a verified tag on $B at origin"; fi
run_rc 0 "cli status with the tag present" scripts/ops/cli-release.sh status
if [ "$(state_of release_tag)" = "done" ]; then ok; else bad "present tag not done"; fi
expect_next promotion:mutate
case "$(next_field command)" in
  *"candidate_run_id=111"*"physical_acceptance_confirmed=true"*) ok ;;
  *) bad "promotion command: $(next_field command)" ;;
esac
case "$(next_field command)" in "scripts/ops/cli-release.sh _check-registrations $CAND"*) ok ;; *) bad "promotion does not re-check registrations first" ;; esac
MACPROVIDER_RELEASE_TAG_ALLOWED_SIGNERS="$tmp/keys/absent" run_rc 0 "cli status without a signer allowlist" scripts/ops/cli-release.sh status
if [ "$(state_of release_tag)" != "done" ]; then ok; else bad "tag accepted without an explicit signer allowlist"; fi
case " $(step_ids) " in
  *" e2e_gate registrations release_tag promotion "*) ok ;;
  *) bad "registrations is not the gate before promotion: $(step_ids)" ;;
esac
# The one-time revocation seed is a train step on a repository-mode runtime:
# missing seed ids are added under the locks with one restart, then verified
# on /healthz.
NO_SEED=1 pearl_config "$OLD" "$META"; pearl_boot
run_rc 0 "revocation seed not yet applied" scripts/ops/cli-release.sh status
expect_next revocation_seed:mutate
case "$(next_field command):$(next_field expected_downtime)" in "scripts/ops/cli-release.sh _revoke-seed:coordinator restart"*) ok ;; *) bad "seed command: $(next_field command)" ;; esac
run_rc 3 "_revoke-seed refuses outside next --run" scripts/ops/cli-release.sh _revoke-seed
# 2026-10-10: the default --healthz was the buyer listener, whose /healthz has
# no compatibility policy; the seed was written, restarted, refused, restored.
# The default is the provider listener, and a policy-less /healthz refuses
# before any edit or restart.
if grep -qx 'PEARL_COORDINATOR_HEALTHZ_URL="${PEARL_COORDINATOR_HEALTHZ_URL:-http://127.0.0.1:8444/healthz}"' "$W/scripts/ops/cli-release.sh"; then ok; else bad "default Pearl healthz URL is not the provider listener"; fi
cp "$tmp/pearl/coordinator.yaml" "$tmp/pearl/before.yaml"; before="$(restarts)"
PEARL_COORDINATOR_HEALTHZ_URL="http://127.0.0.1:$PORT/buyer/healthz" MACPROVIDER_OPS_OWNER=t \
  run_rc 3 "seed refused when --healthz reports no policy" scripts/ops/cli-release.sh next --run
expect_lock_free
expect_err "reports no compatibility_policy_mode"
if cmp -s "$tmp/pearl/coordinator.yaml" "$tmp/pearl/before.yaml" && [ "$(restarts)" = "$before" ]; then ok; else bad "a policy-less /healthz still edited or restarted"; fi
before="$(restarts)"
MACPROVIDER_OPS_OWNER=t run_rc 0 "revocation seed applied" scripts/ops/cli-release.sh next --run
expect_lock_free
if python3 -c 'import sys,yaml; c=yaml.safe_load(open(sys.argv[1]))["coordinator"]["compatibility_set"]; sys.exit(0 if c["revoked_ids"] == sys.argv[2:] else 1)' \
  "$tmp/pearl/coordinator.yaml" "$SEED1" "$SEED2" && [ "$(restarts)" = $((before + 1)) ]; then ok; else bad "seed not written as revoked_ids in one restart"; fi
run_rc 0 "status after the seed" scripts/ops/cli-release.sh status
if [ "$(state_of revocation_seed)" = done ]; then ok; else bad "seed not live"; fi
# A seed id that is the current target is deferred, never a looping refusal:
# the rest is revoked; after the target moves off it, the step revokes it.
TARGET_ID="$SEED1" NO_SEED=1 pearl_config "$OLD" "$META"; pearl_boot
run_rc 0 "seed with the incumbent target in it" scripts/ops/cli-release.sh status
expect_next revocation_seed:mutate
MACPROVIDER_OPS_OWNER=t run_rc 0 "seed applied except the deferred target" scripts/ops/cli-release.sh next --run
expect_lock_free
if python3 -c 'import sys,yaml; c=yaml.safe_load(open(sys.argv[1]))["coordinator"]["compatibility_set"]; sys.exit(0 if c["revoked_ids"] == [sys.argv[2]] and c["target_id"] == sys.argv[3] else 1)' \
  "$tmp/pearl/coordinator.yaml" "$SEED2" "$SEED1"; then ok; else bad "deferred target was revoked or the rest was not"; fi
run_rc 0 "status with the deferred target" scripts/ops/cli-release.sh status
case "$(state_of revocation_seed):$(next_field id)" in done:revocation_seed) bad "seed step loops on the deferred target" ;; done:*) ok ;; *) bad "deferred seed not done: $(state_of revocation_seed)" ;; esac
REVOKED="$SEED2" NO_SEED=1 pearl_config "$OLD" "$META"; pearl_boot   # recommendation_bump moved the target
run_rc 0 "deferred seed id after the target moved" scripts/ops/cli-release.sh status
expect_next revocation_seed:mutate
MACPROVIDER_OPS_OWNER=t run_rc 0 "deferred seed id revoked" scripts/ops/cli-release.sh next --run
expect_lock_free
if python3 -c 'import sys,yaml; c=yaml.safe_load(open(sys.argv[1]))["coordinator"]["compatibility_set"]; sys.exit(0 if sorted(c["revoked_ids"]) == sorted(sys.argv[2:]) else 1)' \
  "$tmp/pearl/coordinator.yaml" "$SEED1" "$SEED2"; then ok; else bad "deferred seed id not revoked after the target moved"; fi
# An old runtime never gets the seed step as next.
NO_SEED=1 pearl_config "$OLD $COMPAT" "$META"; pearl_boot
health_legacy v9.0.0 "$LIVE"
run_rc 0 "old runtime without the seed" scripts/ops/cli-release.sh status
if [ "$(state_of revocation_seed)" = pending ] && [ "$(next_field id)" != revocation_seed ]; then ok; else bad "seed offered on an old runtime"; fi
health v9.0.0 "$LIVE"
# Admission is by policy (SPEC-002-R004): the candidate is admitted without
# being listed anywhere; an exact revocation refuses it by name.
note_of() { python3 -c 'import json,sys; print(next(s["note"] for s in json.load(open(sys.argv[1]))["steps"] if s["id"] == sys.argv[2]))' "$tmp/out" "$1"; }
pearl_config "$OLD" "$META"; pearl_boot
run_rc 0 "candidate admitted by policy without an accepted_ids entry" scripts/ops/cli-release.sh status
if [ "$(state_of pearl_accepted_ids)" = done ] && [ "$(state_of registrations)" = done ]; then ok; else bad "policy admission not proven: $(note_of registrations)"; fi
REVOKED="$COMPAT" pearl_config "$OLD" "$META"; pearl_boot
run_rc 0 "revoked candidate" scripts/ops/cli-release.sh status
expect_next pearl_accepted_ids:blocked
case "$(note_of registrations)" in *"provider_release_revoked"*) ok ;; *) bad "revocation not named: $(note_of registrations)" ;; esac
# A runtime that reports no policy mode predates repository admission: only its
# exact accepted_ids count, and the train points at the runtime release, never
# at an accepted_ids edit.
pearl_config "$OLD" "$META"; pearl_boot
health_legacy v9.0.0 "$LIVE"
run_rc 0 "old runtime without the candidate listed" scripts/ops/cli-release.sh status
expect_next pearl_accepted_ids:blocked
case "$(next_field command):$(next_field reason)" in "scripts/ops/pearl-runtime.sh status:"*"predates SPEC-002-R004"*) ok ;; *) bad "old runtime reason: $(next_field reason)" ;; esac
pearl_config "$OLD $COMPAT" "$META"; pearl_boot
run_rc 0 "old runtime with the candidate listed" scripts/ops/cli-release.sh status
if [ "$(state_of pearl_accepted_ids)" = done ]; then ok; else bad "listed candidate on an old runtime not admitted"; fi
health v9.0.0 "$LIVE"
# A live policy that differs from the applied config (here: a revocation the
# running coordinator holds but the on-disk config lost) blocks every
# Pearl-mutating step, including the one-time privacy setup.
pearl_config "$OLD" ""; pearl_boot
REVOKED="$COMPAT" pearl_config "$OLD" ""; cp "$tmp/pearl/coordinator.yaml" "$tmp/svc/running.yaml"
pearl_config "$OLD" ""
run_rc 0 "live policy differs from the applied config" scripts/ops/cli-release.sh status
expect_next compatibility_policy:blocked
case "$(next_field reason)" in *"revoked_ids differ"*) ok ;; *) bad "mismatch reason: $(next_field reason)" ;; esac
# The same live revocation with an unapplied on-disk edit is not a pending
# train edit: still blocked, never a restart that would drop the revocation.
printf '# unapplied\n' >> "$tmp/pearl/coordinator.yaml"
run_rc 0 "live revocation hidden by an unapplied disk config" scripts/ops/cli-release.sh status
expect_next compatibility_policy:blocked
health_policy_mode() { python3 - "$tmp/svc/healthz.json" "$1" <<'PYH'
import json, sys
d = json.load(open(sys.argv[1])); d.pop("_policy", None); d["compatibility_policy_mode"] = sys.argv[2]
json.dump(d, open(sys.argv[1], "w"))
PYH
}
pearl_config "$OLD" "$META"; pearl_boot
health_policy_mode unconfigured
run_rc 0 "live policy mode other than repository" scripts/ops/cli-release.sh status
expect_next compatibility_policy:blocked
health v9.0.0 "$LIVE"
pearl_config "$OLD $COMPAT" "$META"
pearl_boot
# A verifying filepearl_config "$OLD $COMPAT" "$META"
pearl_boot
# A verifying file the running coordinator has not loaded is not approval.
loaded 1.0.0
run_rc 0 "cli status with v$CAND on disk but not loaded" scripts/ops/cli-release.sh status
case "$(python3 -c 'import json,sys; print(next(s["note"] for s in json.load(open(sys.argv[1]))["steps"] if s["id"] == "registrations"))' "$tmp/out")" in
  *"does not report v$CAND as loaded"*) ok ;; *) bad "unloaded release identity accepted" ;;
esac
loaded "$CAND"
mkdir -p "$tmp/pearl/aside" && mv "$META"/v"$CAND".json* "$tmp/pearl/aside/"
run_rc 0 "cli status with the candidate cdhash unapproved" scripts/ops/cli-release.sh status
if [ "$(state_of registrations)" = "pending" ] && [ "$(next_field id)" != "promotion" ]; then ok; else bad "unapproved cdhash did not refuse promotion: $(next_field id)"; fi
case "$(python3 -c 'import json,sys; print(next(s["note"] for s in json.load(open(sys.argv[1]))["steps"] if s["id"] == "registrations"))' "$tmp/out")" in
  *"$CDHASH"*"not approved"*) ok ;; *) bad "registrations note does not name the cdhash" ;;
esac
pearl_config "$OLD $COMPAT" "$META" "$CDHASH"
run_rc 0 "cli status with a config approval not yet applied" scripts/ops/cli-release.sh status
case "$(python3 -c 'import json,sys; print(next(s["note"] for s in json.load(open(sys.argv[1]))["steps"] if s["id"] == "registrations"))' "$tmp/out")" in
  *"differs from the config the running coordinator booted with"*) ok ;; *) bad "unapplied config edit not refused" ;;
esac
pearl_boot
run_rc 0 "cli status with a config approval" scripts/ops/cli-release.sh status
if [ "$(state_of registrations)" = "done" ]; then ok; else bad "approved_code_identities entry not accepted: $(next_field reason)"; fi
mv "$tmp/pearl/aside"/* "$META/"
pearl_config "$OLD $COMPAT" "$META"
pearl_boot
run_rc 0 "cli status with registrations restored" scripts/ops/cli-release.sh status
expect_next promotion:mutate
# The promotion dispatch re-reads Pearl first and refuses when a registration
# went away after status.
rm -f "$tmp/svc/loaded.txt"
run_rc 3 "_check-registrations refuses a registration lost after status" scripts/ops/cli-release.sh _check-registrations "$CAND"
expect_err "is not registered in the running coordinator"
loaded "$CAND"
run_rc 0 "_check-registrations passes when everything is live" scripts/ops/cli-release.sh _check-registrations "$CAND"
# A registration on disk but not applied (a restart still due) is not live.
pearl_config "$OLD" "$META"; pearl_boot
pearl_config "$OLD" "$META" "$CDHASH"
run_rc 0 "cli status with an approval edited on disk but not applied" scripts/ops/cli-release.sh status
case "$(note_of registrations)" in *"booted with"*) ok ;; *) bad "unapplied on-disk edit counted as live" ;; esac
pearl_config "$OLD" "$META"; pearl_boot
run_rc 0 "cli status after the recovery" scripts/ops/cli-release.sh status
expect_next promotion:mutate
rm -f "$SCOPE/e2e_gate.json"
run_rc 0 "cli status without e2e" scripts/ops/cli-release.sh status
expect_next e2e_gate:manual

# After the bump: registrations are re-checked, the lifetime rejection count is
# reported only, and the dispatch is gated on rejections inside a window.
fixture '{"latest_stable": "v'"$CAND"'", "releases": {"v'"$CAND"'": {"isPrerelease": false, "isDraft": false, "publishedAt": "2026-10-09T00:00:00Z"}},
  "runs": {"acceptance-candidate.yml": [{"databaseId": 111, "status": "completed", "conclusion": "success", "headSha": "'"$B"'", "createdAt": "2026-10-09T00:00:00Z"}]},
  "artifacts": {"111": [{"name": "acceptance-candidate-'"$B"'", "expired": false}]}}'
# recommendation_bump runs through next --run: target and latest move (the
# deprecated accepted_ids is left as it is), /healthz must then recommend the
# release and report the new target.
health v9.0.0 "$LIVE"
pearl_config "$OLD $COMPAT" "$META"; pearl_boot; loaded "$CAND"
run_rc 0 "cli status before the bump" scripts/ops/cli-release.sh status
expect_next recommendation_bump:mutate
case "$(next_field command)" in *"_pearl-config --recommend $CAND $COMPAT"*) ok ;; *) bad "bump command: $(next_field command)" ;; esac
cp "$tmp/pearl/coordinator.yaml" "$tmp/pearl/before.yaml"
touch "$tmp/svc/restart_fail"
MACPROVIDER_OPS_OWNER=t run_rc 1 "a failed restart puts the read bytes back" scripts/ops/cli-release.sh next --run
expect_lock_free
rm -f "$tmp/svc/restart_fail"
if cmp -s "$tmp/pearl/coordinator.yaml" "$tmp/pearl/before.yaml"; then ok; else bad "config not restored after a failed restart"; fi
MACPROVIDER_OPS_OWNER=t run_rc 0 "recommendation bump" scripts/ops/cli-release.sh next --run
expect_lock_free
if python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); c=d["coordinator"]["compatibility_set"]; sys.exit(0 if c["target_id"] == sys.argv[2] and sys.argv[3] in c["accepted_ids"] and d["coordinator_advertised_version"]["latest_binary_version"] == sys.argv[4] else 1)' \
  "$tmp/pearl/coordinator.yaml" "$COMPAT" "$OLD" "$CAND"; then ok; else bad "bump did not set target/latest or dropped the prior target"; fi
run_rc 0 "cli status after the bump" scripts/ops/cli-release.sh status
if [ "$(state_of recommendation_bump)" = "done" ]; then ok; else bad "bump not live"; fi
# The bump is complete only with BOTH the advertised version and the applied
# target_id; a target left on the previous release is repaired.
pearl_config "$OLD $COMPAT" "$META"
python3 - "$tmp/pearl/coordinator.yaml" "$CAND" <<'PYCFG'
import re, sys
p = sys.argv[1]
s = open(p).read()
open(p, "w").write(re.sub(r'latest_binary_version: "[^"]*"', 'latest_binary_version: "%s"' % sys.argv[2], s))
PYCFG
pearl_boot
health v9.0.0 "$CAND"
run_rc 0 "cli status with the release advertised but the old target applied" scripts/ops/cli-release.sh status
expect_next recommendation_bump:mutate
MACPROVIDER_OPS_OWNER=t run_rc 0 "recommendation bump repairs the target" scripts/ops/cli-release.sh next --run
expect_lock_free
if grep -q "target_id: $COMPAT" "$tmp/pearl/coordinator.yaml"; then ok; else bad "target_id not repaired"; fi
run_rc 0 "cli status after the target repair" scripts/ops/cli-release.sh status
if [ "$(state_of recommendation_bump)" = "done" ]; then ok; else bad "bump not complete after the target repair"; fi
# After publication with the target left on the previous release, admission
# needs no edit and recommendation_bump repairs the target.
pearl_config "$OLD" "$META"; pearl_boot
run_rc 0 "published release with the old target" scripts/ops/cli-release.sh status
if [ "$(state_of pearl_accepted_ids)" = "done" ]; then ok; else bad "published release not admitted by policy"; fi
expect_next recommendation_bump:mutate
# An on-disk bump the running coordinator never applied is recovered with one
# validated restart; the bytes stay as they are.
python3 - "$tmp/pearl/coordinator.yaml" "$CAND" "$COMPAT" <<'PYCFG'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r'latest_binary_version: "[^"]*"', 'latest_binary_version: "%s"' % sys.argv[2], s)
open(p, "w").write(re.sub(r'target_id: \S+', 'target_id: %s' % sys.argv[3], s))
PYCFG
cp "$tmp/pearl/coordinator.yaml" "$tmp/pearl/before.yaml"
before="$(restarts)"
MACPROVIDER_OPS_OWNER=t run_rc 0 "an unapplied on-disk bump is recovered with a restart" scripts/ops/cli-release.sh next --run
expect_lock_free
if [ "$(restarts)" = $((before + 1)) ] && cmp -s "$tmp/pearl/coordinator.yaml" "$tmp/pearl/before.yaml"; then ok; else bad "unapplied bump not recovered by one restart"; fi
run_rc 0 "cli status after the recovered bump" scripts/ops/cli-release.sh status
if [ "$(state_of recommendation_bump)" = "done" ]; then ok; else bad "recovered bump not live"; fi
# An old runtime that already lists the candidate admits it, but the bump is
# verified on /healthz fields only a repository runtime reports: stop with
# "ship the runtime first", never offer the impossible bump.
mkdir -p "$tmp/saved" && cp "$tmp/pearl/coordinator.yaml" "$tmp/svc/boot.txt" "$tmp/svc/running.yaml" "$tmp/svc/healthz.json" "$tmp/saved/"
pearl_config "$OLD $COMPAT" "$META"; pearl_boot
health_legacy v9.0.0 "$LIVE"
run_rc 0 "old runtime: no recommendation bump" scripts/ops/cli-release.sh status
expect_next recommendation_bump:blocked
case "$(next_field command):$(next_field reason)" in "scripts/ops/pearl-runtime.sh status:"*"not repository"*) ok ;; *) bad "old-runtime bump reason: $(next_field reason)" ;; esac
cp "$tmp/saved/coordinator.yaml" "$tmp/pearl/"; cp "$tmp/saved/boot.txt" "$tmp/saved/running.yaml" "$tmp/saved/healthz.json" "$tmp/svc/"
# Fresh ops state (no verification record): the compatibility id comes from
# the verified v<ver> tag, or the gate fails closed.
mkdir -p "$tmp/state-fresh"
MACPROVIDER_OPS_STATE_DIR="$tmp/state-fresh" run_rc 0 "published release from fresh ops state" scripts/ops/cli-release.sh status
if [ "$(fact_of compatibility_set_id_source)" = "verified tag v$CAND" ] && [ "$(state_of registrations)" = "done" ]; then ok; else bad "compat id not derived from the verified tag: $(state_of registrations)"; fi
MACPROVIDER_OPS_STATE_DIR="$tmp/state-fresh" MACPROVIDER_RELEASE_TAG_ALLOWED_SIGNERS="$tmp/keys/absent" \
  run_rc 0 "published release from fresh ops state without a trusted tag" scripts/ops/cli-release.sh status
case "$(state_of registrations):$(python3 -c 'import json,sys; print(next(s["note"] for s in json.load(open(sys.argv[1]))["steps"] if s["id"] == "registrations"))' "$tmp/out")" in
  pending:*"compatibility_set_id is unknown"*) ok ;; *) bad "an unknown compatibility id passed the registrations gate" ;;
esac
health v9.0.0 "$CAND"
rm -f "$tmp/svc/loaded.txt"
run_rc 0 "cli status after the bump with the identity no longer loaded" scripts/ops/cli-release.sh status
expect_next registrations:blocked
loaded "$CAND"
printf '3' > "$tmp/svc/rejections"
run_rc 0 "cli status after the bump with historical rejections" scripts/ops/cli-release.sh status
expect_next verify_live_rollout:mutate
case "$(next_field command)" in *"_check-privacy-rejections"*"verify-live-coordinator-release-rollout.yml"*) ok ;; *) bad "rollout command: $(next_field command)" ;; esac
if [ "$(fact_of privacy_unapproved_rejections_lifetime)" = "3" ]; then ok; else bad "lifetime fact: $(fact_of privacy_unapproved_rejections_lifetime)"; fi
PRIVACY_REJECTION_WINDOW_SECONDS=0 run_rc 0 "no new rejections in the window" scripts/ops/cli-release.sh _check-privacy-rejections
printf '1' > "$tmp/svc/rejections_bump"
PRIVACY_REJECTION_WINDOW_SECONDS=0 run_rc 3 "new rejections in the window refuse rollout verification" scripts/ops/cli-release.sh _check-privacy-rejections
expect_err "rejected 1 privacy advertisement"
rm -f "$tmp/svc/rejections" "$tmp/svc/rejections_bump" "$tmp/svc/metrics_reads"
# A restart inside the window resets the per-process counter: the samples are
# bound to one invocation, and a reset falls back to the unit journal.
REJ='{"error":"relayblind: privacy posture rejected: posture_unapproved_code_identity","provider_id":"p1"}'
printf '%s\n%s\n' "$REJ" "$REJ" > "$tmp/svc/journal.txt"
printf '5\n5\n' > "$tmp/svc/rejections_seq"
printf '%s\n%s\n' "$(printf 'a%.0s' $(seq 32))" "$(printf 'b%.0s' $(seq 32))" > "$tmp/svc/invocation_seq"
PRIVACY_REJECTION_WINDOW_SECONDS=0 run_rc 3 "a restart back to the same count does not hide rejections" scripts/ops/cli-release.sh _check-privacy-rejections
expect_err "rejected 2 privacy advertisement"
rm -f "$tmp/svc/invocation_seq"
printf '5\n2\n' > "$tmp/svc/rejections_seq"
PRIVACY_REJECTION_WINDOW_SECONDS=0 run_rc 3 "a counter that goes down is treated as a reset" scripts/ops/cli-release.sh _check-privacy-rejections
expect_err "restarted during the window"
rm -f "$tmp/svc/journal.txt"
printf '5\n5\n' > "$tmp/svc/rejections_seq"
PRIVACY_REJECTION_WINDOW_SECONDS=0 run_rc 0 "a steady counter in one invocation passes" scripts/ops/cli-release.sh _check-privacy-rejections
rm -f "$tmp/svc/rejections_seq"
printf '{"error":"relayblind: privacy posture rejected: posture_unapproved_code_identity","provider_id":"p1"}\n' > "$tmp/svc/journal.txt"
PRIVACY_REJECTION_WINDOW_SECONDS=0 run_rc 3 "journal fallback refuses rejections in the window" scripts/ops/cli-release.sh _check-privacy-rejections
run_rc 0 "cli status reports the journal source without the metric" scripts/ops/cli-release.sh status
if [ "$(fact_of privacy_unapproved_rejections_source)" = "journal" ]; then ok; else bad "fallback source: $(fact_of privacy_unapproved_rejections_source)"; fi
rm -f "$tmp/svc/journal.txt"

# ==== mirror_latest ===========================================================
# After the rollout verification the release mirror's advisory latest.json must
# name the recommended tag; next --run promotes it through the mirror script.
fixture '{"latest_stable": "v'"$CAND"'", "releases": {"v'"$CAND"'": {"isPrerelease": false, "isDraft": false, "publishedAt": "2026-10-09T00:00:00Z"}},
  "runs": {"acceptance-candidate.yml": [{"databaseId": 111, "status": "completed", "conclusion": "success", "headSha": "'"$B"'", "createdAt": "2026-10-09T00:00:00Z"}],
    "verify-live-coordinator-release-rollout.yml": [{"databaseId": 888, "status": "completed", "conclusion": "success", "headSha": "'"$B"'", "createdAt": "2026-10-09T01:00:00Z"}]},
  "artifacts": {"111": [{"name": "acceptance-candidate-'"$B"'", "expired": false}]}}'
printf '{"tag_name": "v%s"}\n' "$LIVE" > "$tmp/svc/mirror-latest.json"
run_rc 0 "mirror latest.json lags the recommended tag" scripts/ops/cli-release.sh status
if [ "$(state_of mirror_latest)" = "pending" ] && [ "$(fact_of mirror_latest_tag)" = "v$LIVE" ]; then ok; else bad "mirror_latest not pending while latest.json lags: $(state_of mirror_latest)"; fi
expect_next mirror_latest:blocked
expect_err_or_reason() { case "$(next_field reason)" in *"$1"*) ok ;; *) bad "reason lacks '$1': $(next_field reason)" ;; esac; }
expect_err_or_reason "MALIBU_DOWNLOAD_SSH_KEY is unset"
MACPROVIDER_OPS_OWNER=t run_rc 3 "mirror_latest refuses without the mirror key" scripts/ops/cli-release.sh next --run
expect_lock_free
export MALIBU_DOWNLOAD_SSH_KEY="$tmp/mirror-key"
run_rc 0 "mirror latest.json lags, key set" scripts/ops/cli-release.sh status
expect_next mirror_latest:mutate
case "$(next_field command)" in
  *"scripts/publish-release-mirror.sh --tag v$CAND --promote-latest"*) ok ;; *) bad "mirror command: $(next_field command)" ;;
esac
case "$(next_field command)" in *stub-gh-token*) bad "the token leaked into the printed command" ;; *) ok ;; esac
FAKE_MIRROR_FAIL=1 MACPROVIDER_OPS_OWNER=t run_rc 1 "a failing mirror publish is not recorded" scripts/ops/cli-release.sh next --run
expect_lock_free
MACPROVIDER_OPS_OWNER=t run_rc 0 "mirror_latest promotes through next --run" scripts/ops/cli-release.sh next --run
expect_lock_free
if [ "$(cat "$tmp/svc/mirror-args")" = "--tag v$CAND --promote-latest" ]; then ok; else bad "mirror script args: $(cat "$tmp/svc/mirror-args")"; fi
if [ "$(cat "$tmp/svc/mirror-env")" = "token=stub-gh-token key=$tmp/mirror-key" ]; then ok; else bad "mirror script env lacks the token or key"; fi
run_rc 0 "mirror latest.json matches" scripts/ops/cli-release.sh status
if [ "$(state_of mirror_latest)" = "done" ]; then ok; else bad "mirror_latest not done once latest.json matches"; fi
if [ "$(next_field id)" != "mirror_latest" ]; then ok; else bad "mirror_latest still next after it matches"; fi
unset MALIBU_DOWNLOAD_SSH_KEY

# ==== cli-release revoked-build rollback (SPEC-020-R007) ======================
# The candidate is live (target + recommendation). The rollback recommends the
# previous release and revokes the candidate in one Pearl edit and restart.
rollback_live() {
  TARGET_ID="$COMPAT" pearl_config "$OLD" "$META"
  python3 - "$tmp/pearl/coordinator.yaml" "$CAND" <<'PYCFG'
import re, sys
p = sys.argv[1]
s = open(p).read()
open(p, "w").write(re.sub(r'latest_binary_version: "[^"]*"', 'latest_binary_version: "%s"' % sys.argv[2], s))
PYCFG
  pearl_boot
  health v9.0.0 "$CAND"
}
# P's identity is the commit its release tag points at.
PREV_COMMIT="$(git -C "$W" ls-remote origin "refs/tags/v$LIVE^{}" "refs/tags/v$LIVE" | awk '$2 ~ /\^\{\}$/ {p=$1} {a=$1} END {print (p != "" ? p : a)}')"
if [ -z "$PREV_COMMIT" ]; then
  git -C "$W" -c user.name=t -c user.email=t@example.invalid tag -a "v$LIVE" -m "previous release" "$B"
  git -C "$W" push -q origin "refs/tags/v$LIVE"
  PREV_COMMIT="$B"
fi
PREV="test/repo:v$LIVE@$PREV_COMMIT"
# P's signed release metadata (pearl-release.json + .sig, the train's release key).
prev_release() {  # prev_release COMMIT [TAG]: stage v$LIVE's signed metadata naming COMMIT
  mkdir -p "$tmp/gh/downloads/v$LIVE"
  printf '{"schema_version":1,"repository":"test/repo","tag":"%s","commit":"%s","release_version":"%s","provider_advertised_version":"%s"}\n' \
    "${2:-v$LIVE}" "$1" "$LIVE" "$LIVE" > "$tmp/gh/downloads/v$LIVE/pearl-release.json"
  openssl dgst -sha256 -sign "$tmp/keys/release.key" -out "$tmp/gh/downloads/v$LIVE/pearl-release.json.sig" \
    "$tmp/gh/downloads/v$LIVE/pearl-release.json"
}
prev_release "$PREV_COMMIT"
rollback_live
fixture '{"latest_stable": "v'"$CAND"'", "releases": {"v'"$LIVE"'": {"isPrerelease": false, "isDraft": false, "publishedAt": "2026-10-08T00:00:00Z"}}}'
export CLI_ROLLBACK_TO_ID="$PREV" CLI_ROLLBACK_REVOKE_ID="$COMPAT"
run_rc 0 "rollback status" scripts/ops/cli-release.sh status
expect_next rollback:mutate
case "$(next_field command)" in "scripts/ops/cli-release.sh _pearl-config --recommend $LIVE $PREV --revoke $COMPAT") ok ;; *) bad "rollback command: $(next_field command)" ;; esac
case "$(next_field expected_downtime)" in *"coordinator restart"*) ok ;; *) bad "no downtime banner for the rollback" ;; esac
printf '{"status":"ok","version":"v9.0.0","recommended_binary_version":"%s","uptime_s":100,"_policy":"running","_no_revoked_signal":true}' "$CAND" > "$tmp/svc/healthz.json"
run_rc 0 "rollback on a runtime without the revocation signal" scripts/ops/cli-release.sh status
expect_next rollback:blocked
case "$(next_field command):$(next_field reason)" in "scripts/ops/pearl-runtime.sh status:"*"compatibility_policy_revoked_signal"*) ok ;; *) bad "no-signal rollback reason: $(next_field reason)" ;; esac
health v9.0.0 "$CAND"
CLI_ROLLBACK_TO_ID="$COMPAT" CLI_ROLLBACK_REVOKE_ID="$PREV" run_rc 0 "rollback to a newer release" scripts/ops/cli-release.sh status
expect_next rollback:blocked
case "$(next_field reason)" in *"strictly older"*) ok ;; *) bad "newer rollback reason: $(next_field reason)" ;; esac
CLI_ROLLBACK_REVOKE_ID="" run_rc 0 "rollback with one id" scripts/ops/cli-release.sh status
expect_next rollback:blocked
CLI_ROLLBACK_TO_ID="test/repo:v$LIVE@$(printf 'e%.0s' $(seq 40))" run_rc 0 "rollback id that is not the release tag commit" scripts/ops/cli-release.sh status
expect_next rollback:blocked
case "$(next_field reason)" in *"does not name release"*) ok ;; *) bad "wrong-commit rollback reason: $(next_field reason)" ;; esac
# The full id must equal what P's verified signed release metadata binds.
prev_release "$(printf 'f%.0s' $(seq 40))"
run_rc 0 "rollback id that differs from the signed release identity" scripts/ops/cli-release.sh status
expect_next rollback:blocked
case "$(next_field reason)" in *"is not the signed identity"*"test/repo:v$LIVE@ffff"*) ok ;; *) bad "signed-identity mismatch reason: $(next_field reason)" ;; esac
prev_release "$PREV_COMMIT"
# Valid JSON naming the right identity but with a changed field: only the
# signature check can refuse it.
python3 - "$tmp/gh/downloads/v$LIVE/pearl-release.json" <<'PYTAMPER'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["provider_advertised_version"] = "9.9.9"
open(p, "w").write(json.dumps(d) + "\n")
PYTAMPER
run_rc 0 "rollback with tampered signed release metadata" scripts/ops/cli-release.sh status
expect_next rollback:blocked
case "$(next_field reason)" in *"nothing (missing, unsigned or tampered)"*) ok ;; *) bad "tampered metadata reason: $(next_field reason)" ;; esac
rm -f "$tmp/gh/downloads/v$LIVE/pearl-release.json.sig"
run_rc 0 "rollback without a release signature" scripts/ops/cli-release.sh status
expect_next rollback:blocked
prev_release "$PREV_COMMIT"
fixture '{"latest_stable": "v'"$CAND"'", "releases": {}}'
run_rc 0 "rollback to an unpublished release" scripts/ops/cli-release.sh status
expect_next rollback:blocked
case "$(next_field reason)" in *"not a published stable release"*) ok ;; *) bad "unpublished rollback reason: $(next_field reason)" ;; esac
fixture '{"latest_stable": "v'"$CAND"'", "releases": {"v'"$LIVE"'": {"isPrerelease": false, "isDraft": false, "publishedAt": "2026-10-08T00:00:00Z"}}}'
before="$(restarts)"
MACPROVIDER_OPS_OWNER=t run_rc 0 "rollback runs" scripts/ops/cli-release.sh next --run
expect_lock_free
if python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); c=d["coordinator"]["compatibility_set"]; sys.exit(0 if c["target_id"] == sys.argv[2] and sys.argv[3] in c["revoked_ids"] and d["coordinator_advertised_version"]["latest_binary_version"] == sys.argv[4] else 1)' \
  "$tmp/pearl/coordinator.yaml" "$PREV" "$COMPAT" "$LIVE" && [ "$(restarts)" = $((before + 1)) ]; then ok; else bad "rollback did not recommend the previous release and revoke the candidate in one restart"; fi
run_rc 0 "rollback status after the run" scripts/ops/cli-release.sh status
if [ "$(state_of rollback)" = "done" ]; then ok; else bad "rollback not live"; fi
expect_next done:done
# A completed-looking policy on a runtime without the signal is not done.
printf '{"status":"ok","version":"v9.0.0","recommended_binary_version":"%s","uptime_s":100,"_policy":"running","_no_revoked_signal":true}' "$LIVE" > "$tmp/svc/healthz.json"
run_rc 0 "completed-looking rollback on a runtime without the signal" scripts/ops/cli-release.sh status
if [ "$(state_of rollback)" = "blocked" ]; then ok; else bad "rollback reported $(state_of rollback) without the revocation signal"; fi
expect_next rollback:blocked
# An interrupted run (edit on disk, restart not done) resumes through next --run.
rollback_live
python3 - "$tmp/pearl/coordinator.yaml" "$PREV" "$COMPAT" "$LIVE" <<'PYCFG'
import re, sys
p, prev, bad, live = sys.argv[1:5]
s = open(p).read()
s = re.sub(r'target_id: \S+', 'target_id: %s' % prev, s, count=1)
s = re.sub(r'latest_binary_version: "[^"]*"', 'latest_binary_version: "%s"' % live, s)
s = s.replace("    revoked_ids:\n", "    revoked_ids:\n    - %s\n" % bad, 1)
open(p, "w").write(s)
PYCFG
run_rc 0 "interrupted rollback status" scripts/ops/cli-release.sh status
expect_next rollback:mutate
before="$(restarts)"
MACPROVIDER_OPS_OWNER=t run_rc 0 "interrupted rollback resumes" scripts/ops/cli-release.sh next --run
expect_lock_free
run_rc 0 "rollback status after the resumed run" scripts/ops/cli-release.sh status
if [ "$(state_of rollback)" = "done" ] && [ "$(restarts)" = $((before + 1)) ]; then ok; else bad "interrupted rollback not resumed by one restart"; fi
unset CLI_ROLLBACK_TO_ID CLI_ROLLBACK_REVOKE_ID

# ==== discovery-renew =========================================================
fixture '{"runs": {"renew-release-discovery-head.yml": []}}'
MACPROVIDER_DISCOVERY_RENEWAL_VALIDITY_HOURS=24 run_rc 3 "short discovery renewal validity refused" scripts/ops/discovery-renew.sh status
expect_err "must be 168"
MACPROVIDER_DISCOVERY_RENEWAL_VALIDITY_HOURS=168 run_rc 0 "discovery renewal status" scripts/ops/discovery-renew.sh status
expect_next dispatch:mutate
case "$(next_field command)" in
  *"renew-release-discovery-head.yml"*"validity_hours=168"*) ok ;;
  *) bad "discovery renewal command: $(next_field command)" ;;
esac
MACPROVIDER_DISCOVERY_RENEWAL_VALIDITY_HOURS=168 run_rc 3 "discovery renewal dispatch needs owner" scripts/ops/discovery-renew.sh next --run
expect_err "MACPROVIDER_OPS_OWNER is unset"
MACPROVIDER_DISCOVERY_RENEWAL_VALIDITY_HOURS=168 MACPROVIDER_OPS_OWNER=t run_rc 0 "discovery renewal dispatch through entrypoint" scripts/ops/discovery-renew.sh next --run
expect_lock_free
fixture '{"runs": {"renew-release-discovery-head.yml": [{"databaseId": 777, "status": "waiting", "conclusion": "", "headSha": "'"$B"'", "createdAt": "2026-10-09T00:00:00Z"}]}}'
run_rc 0 "discovery renewal waiting status" scripts/ops/discovery-renew.sh status
expect_next env_approval:manual

# ==== catalog-activate gateway proof ==========================================
printf 'test-buyer-token\n' > "$tmp/token"
export BUYER_TOKEN_FILE="$tmp/token" PROBE_MODEL=test/model
R="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["release_id"])' "$W/phase3-binary/catalog/autotune/release.json")"
status_doc $CAND true
printf 'canary-test-id' > "$tmp/svc/provider_id"
mkdir -p "$tmp/state/catalog-$R"
printf '{"step":"gateway_proof","evidence":"legacy generic proof","request_id":"ops-proof-old","mtp_forwards_delta":1,"requests_total_delta":1,"served_by_canary":true}
' > "$tmp/state/catalog-$R/gateway_proof.json"
run_rc 0 "catalog status rejects a fresh generic proof marker" scripts/ops/catalog-activate.sh status
if [ "$(state_of gateway_proof)" = "pending" ]; then ok; else bad "fresh generic proof marker counted as done"; fi
rm -f "$tmp/state/catalog-$R/gateway_proof.json"
printf 'stuck' > "$tmp/svc/mode"
run_rc 1 "proof refused when the provider counters do not move" scripts/ops/catalog-activate.sh _gateway-proof
expect_err "did not move the target provider"
printf 'no-request-id' > "$tmp/svc/mode"
run_rc 1 "proof refused without a response request id" scripts/ops/catalog-activate.sh _gateway-proof
expect_err "carries no X-Request-ID"
printf 'canary-test-id' > "$tmp/svc/provider_id"
printf 'no-provider-id' > "$tmp/svc/mode"
run_rc 1 "proof refused without X-Provider-Id" scripts/ops/catalog-activate.sh _gateway-proof
expect_err "carries no X-Provider-Id"
printf 'other-provider' > "$tmp/svc/mode"
run_rc 1 "proof refused when another provider served it (counters still moved)" scripts/ops/catalog-activate.sh _gateway-proof
expect_err "served by another provider"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d.pop("provider_id"); json.dump(d, open(p, "w"))' "$tmp/svc/status.json"
printf 'move' > "$tmp/svc/mode"
run_rc 3 "proof refused when the canary reports no provider_id" scripts/ops/catalog-activate.sh _gateway-proof
status_doc $CAND true
printf 'stuck' > "$tmp/svc/mode"
run_rc 1 "right provider but counters stuck is still refused" scripts/ops/catalog-activate.sh _gateway-proof
printf 'serial-request' > "$tmp/svc/mode"
run_rc 1 "proof refused when only generic requests_total moves" scripts/ops/catalog-activate.sh _gateway-proof
expect_err "cb_shared_forward_calls +0"
printf 'move' > "$tmp/svc/mode"
run_rc 0 "proof accepted when CB shared forward calls move" scripts/ops/catalog-activate.sh _gateway-proof
if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["request_id"].startswith("ops-proof-") and d["cb_shared_forward_calls_delta"] > 0 and d["served_by_canary"] is True else 1)' "$tmp/state/catalog-$R/gateway_proof.json"; then ok; else bad "proof marker lacks request id / CB scheduler delta"; fi
run_rc 0 "catalog status with a fresh proof" scripts/ops/catalog-activate.sh status
if [ "$(state_of gateway_proof)" = "done" ]; then ok; else bad "fresh proof not done"; fi
touch -t "$(date -v-25H +%Y%m%d%H%M 2>/dev/null || date -d '-25 hours' +%Y%m%d%H%M)" "$tmp/state/catalog-$R/gateway_proof.json"
run_rc 0 "catalog status with an expired proof" scripts/ops/catalog-activate.sh status
if [ "$(state_of gateway_proof)" = "pending" ]; then ok; else bad "expired proof still counted"; fi

printf 'entry points: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
