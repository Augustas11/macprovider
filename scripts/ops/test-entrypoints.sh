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
# the gated promotion; catalog-activate's provider-tied gateway proof and its
# 24 h expiry.
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
git -C "$W" -c user.name=t -c user.email=t@example.invalid add -A scripts/ops docs/releases/cli-release-train.md \
  ops/pearl-updater/release-signing-public.pem
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
# shellcheck disable=SC2016  # the fake's own "$1 $3" must stay literal
printf '#!/usr/bin/env bash\n[ "$1 $3" = "show InvocationID" ] || exit 1\necho 0123456789abcdef0123456789abcdef\n' > "$tmp/bin/systemctl"
printf '#!/usr/bin/env bash\ncat %q %q 2>/dev/null || true\n' "$tmp/svc/boot.txt" "$tmp/svc/journal.txt" > "$tmp/bin/journalctl"
chmod +x "$tmp/bin/gh" "$tmp/bin/ssh" "$tmp/bin/systemctl" "$tmp/bin/journalctl"
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
PEARL_RELEASE_IDENTITY_OWNER="$(id -un)" PEARL_RELEASE_IDENTITY_GROUP="$(id -gn)"
export PEARL_RELEASE_IDENTITY_OWNER PEARL_RELEASE_IDENTITY_GROUP PEARL_COORDINATOR_METRICS_URL="http://127.0.0.1:$PORT/metrics"
unset MACPROVIDER_OPS_OWNER PEARL_RUNTIME_VERSION MACPROVIDER_OPS_ENTRYPOINT

fixture() { printf '%s' "$1" > "$tmp/gh/fixture.json"; rm -f "$tmp/gh"/count-*; }
health() { printf '{"status":"ok","version":"%s","recommended_binary_version":"%s","uptime_s":100}' "$1" "$2" > "$tmp/svc/healthz.json"; }

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
state_of() { python3 -c 'import json,sys; print(next(s["state"] for s in json.load(open(sys.argv[1]))["steps"] if s["id"] == sys.argv[2]))' "$tmp/out" "$1"; }
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
bash "$W/scripts/ops/live-lock.sh" release t 2>/dev/null

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
printf '{"step":"pearl_accepted_ids","evidence":"test"}\n' > "$SCOPE/pearl_accepted_ids.json"
# Fake Pearl config: compatibility in the base file, privacy_class in the overlay.
pearl_config() {  # pearl_config ACCEPTED_IDS_YAML_LIST METADATA_DIR_OR_EMPTY [APPROVED_CDHASH]
  printf 'coordinator:\n  compatibility_set:\n    target_id: test/repo:v%s@old\n    accepted_ids: %s\n' "$LIVE" "$1" > "$tmp/pearl/coordinator.yaml"
  {
    printf 'privacy_class:\n  enabled: true\n'
    [ -z "$2" ] || printf '  release_code_identities:\n    metadata_dir: %s\n    public_key_path: %s\n' "$2" "$tmp/keys/release.pem"
    [ -z "${3:-}" ] || printf '  approved_code_identities:\n  - team_id: ABCDE12345\n    signing_identifier: live.malibu.provider.cli\n    code_cdhash: %s\n    binary_version: "%s"\n' "$3" "$CAND"
  } > "$tmp/pearl/overlay.yaml"
}
# pearl_boot: the running coordinator (re)starts with the config now on disk.
pearl_boot() {
  printf '{"level":"info","config_sha256":"%s","overlay_sha256":"%s","source":"boot","event":"coordinator_config_applied","message":"coordinator config applied"}\n' \
    "$(shasum -a 256 "$tmp/pearl/coordinator.yaml" | awk '{print $1}')" "$(shasum -a 256 "$tmp/pearl/overlay.yaml" | awk '{print $1}')" > "$tmp/svc/boot.txt"
}
# loaded VERSION...: the release versions the running coordinator reports as loaded.
loaded() { for v in "$@"; do printf 'relayblind_privacy_release_identity_loaded{binary_version="%s"} 1\n' "$v"; done > "$tmp/svc/loaded.txt"; }
COMPAT="test/repo:v$CAND@$B"
META="$tmp/pearl/privacy-release-identities"
pearl_config "[\"$COMPAT\"]" ""
pearl_boot
run_rc 0 "cli status without a Pearl metadata_dir" scripts/ops/cli-release.sh status
expect_next privacy_release_setup:manual
case "$(next_field command)" in
  *"metadata_dir: /opt/macprovider/privacy-release-identities"*"next --done privacy_release_setup --evidence"*) ok ;;
  *) bad "no one-time setup in: $(next_field command)" ;;
esac
fact_of() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["facts"].get(sys.argv[2]))' "$tmp/out" "$1"; }
if [ "$(fact_of privacy_release_metadata_dir)" = "unset" ]; then ok; else bad "privacy_release_metadata_dir fact: $(fact_of privacy_release_metadata_dir)"; fi
MACPROVIDER_OPS_OWNER=t run_rc 3 "the one-time setup is operator-owned" scripts/ops/cli-release.sh next --run
run_rc 3 "privacy step refuses without a metadata_dir" scripts/ops/cli-release.sh _stage-privacy-identity "$CAND"
expect_err "one-time setup"
run_rc 0 "one-time setup recorded with evidence" scripts/ops/cli-release.sh next --done privacy_release_setup --evidence "applied config sha + healthz"
run_rc 0 "cli status with the setup recorded but not live" scripts/ops/cli-release.sh status
expect_next privacy_release_setup:blocked
pearl_config "[\"$COMPAT\"]" "$META"
pearl_boot
run_rc 0 "cli status with an empty metadata dir" scripts/ops/cli-release.sh status
expect_next privacy_release_identity:mutate
MACPROVIDER_OPS_OWNER=t run_rc 0 "privacy step stages the candidate identity" scripts/ops/cli-release.sh next --run
bash "$W/scripts/ops/live-lock.sh" release t 2>/dev/null
if cmp -s "$META/v$CAND.json" "$tmp/bytes/pearl-release.json" && cmp -s "$META/v$CAND.json.sig" "$tmp/bytes/pearl-release.json.sig"; then ok; else bad "staged files differ from the candidate bytes"; fi
run_rc 0 "cli status after staging" scripts/ops/cli-release.sh status
if [ "$(state_of privacy_release_identity)" = "done" ]; then ok; else bad "staged file not detected as done"; fi
if [ "$(fact_of privacy_release_metadata_dir)" = "$META" ]; then ok; else bad "privacy_release_metadata_dir fact: $(fact_of privacy_release_metadata_dir)"; fi
step_ids() { python3 -c 'import json,sys; print(" ".join(s["id"] for s in json.load(open(sys.argv[1]))["steps"]))' "$tmp/out"; }
case " $(step_ids) " in
  *" signed_byte_verification privacy_release_setup privacy_release_identity pearl_accepted_ids "*) ok ;;
  *) bad "privacy_release_identity is not right after signed_byte_verification: $(step_ids)" ;;
esac
status_doc() {
  local version="$1" connected="$2" cb_active="${3:-true}" cb_authorized="${4:-true}" cb_load="${5:-live_verified}" cb_proof="${6:-passed}" cb_paged="${7:-attached}"
  printf '{"binary_version":"%s","provider_id":"canary-test-id","compatibility_set_id":"test/repo:v'"$CAND"'@%s","coordinator":{"connected":%s},"native_mtp":{"mtp_forwards":5},"requests_total":7,"continuous_batching":{"active":%s,"paged_kv_decision":"%s","policy":{"load_status":"%s","authorized":%s,"local_proof_result":"%s"},"scheduler":{"shared_forward_calls":11}}}'     "$version" "$B" "$connected" "$cb_active" "$cb_paged" "$cb_load" "$cb_authorized" "$cb_proof" > "$tmp/svc/status.json"
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
status_doc $CAND true
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
git -C "$W" config gpg.ssh.allowedSignersFile "$tmp/keys/allowed_signers"
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
ssh-keygen -q -t ed25519 -N '' -C x -f "$tmp/keys/untrusted" </dev/null
git -C "$W" -c user.signingkey="$tmp/keys/untrusted" tag -s -a "v$CAND" -m untrusted "$B"
git -C "$W" push -q origin "refs/tags/v$CAND"
run_rc 0 "cli status with an untrusted signature on v$CAND" scripts/ops/cli-release.sh status
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
bash "$W/scripts/ops/live-lock.sh" release t 2>/dev/null
if [ "$(git -C "$W" ls-remote origin "refs/tags/v$CAND^{}" | awk '{print $1}')" = "$B" ] && git -C "$W" verify-tag "v$CAND" 2>/dev/null; then ok; else bad "v$CAND not a verified tag on $B at origin"; fi
run_rc 0 "cli status with the tag present" scripts/ops/cli-release.sh status
if [ "$(state_of release_tag)" = "done" ]; then ok; else bad "present tag not done"; fi
expect_next promotion:mutate
case "$(next_field command)" in
  *"candidate_run_id=111"*"physical_acceptance_confirmed=true"*) ok ;;
  *) bad "promotion command: $(next_field command)" ;;
esac
case " $(step_ids) " in
  *" e2e_gate registrations release_tag promotion "*) ok ;;
  *) bad "registrations is not the gate before promotion: $(step_ids)" ;;
esac
# Registrations gate: each missing Pearl registration refuses promotion by name.
pearl_config "[]" "$META"
pearl_boot
run_rc 0 "cli status without the candidate in accepted_ids" scripts/ops/cli-release.sh status
expect_next registrations:blocked
case "$(next_field reason)" in *"accepted_ids lacks $COMPAT"*) ok ;; *) bad "accepted_ids reason: $(next_field reason)" ;; esac
pearl_config "[\"$COMPAT\"]" "$META"
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
pearl_config "[\"$COMPAT\"]" "$META" "$CDHASH"
run_rc 0 "cli status with a config approval not yet applied" scripts/ops/cli-release.sh status
case "$(python3 -c 'import json,sys; print(next(s["note"] for s in json.load(open(sys.argv[1]))["steps"] if s["id"] == "registrations"))' "$tmp/out")" in
  *"differs from the config the running coordinator booted with"*) ok ;; *) bad "unapplied config edit not refused" ;;
esac
pearl_boot
run_rc 0 "cli status with a config approval" scripts/ops/cli-release.sh status
if [ "$(state_of registrations)" = "done" ]; then ok; else bad "approved_code_identities entry not accepted: $(next_field reason)"; fi
mv "$tmp/pearl/aside"/* "$META/"
pearl_config "[\"$COMPAT\"]" "$META"
pearl_boot
run_rc 0 "cli status with registrations restored" scripts/ops/cli-release.sh status
expect_next promotion:mutate
rm -f "$SCOPE/e2e_gate.json"
run_rc 0 "cli status without e2e" scripts/ops/cli-release.sh status
expect_next e2e_gate:manual

# After the bump: registrations are re-checked, the lifetime rejection count is
# reported only, and the dispatch is gated on rejections inside a window.
fixture '{"latest_stable": "v'"$CAND"'", "releases": {"v'"$CAND"'": {"isPrerelease": false, "isDraft": false, "publishedAt": "2026-10-09T00:00:00Z"}},
  "runs": {"acceptance-candidate.yml": [{"databaseId": 111, "status": "completed", "conclusion": "success", "headSha": "'"$B"'", "createdAt": "2026-10-09T00:00:00Z"}]},
  "artifacts": {"111": [{"name": "acceptance-candidate-'"$B"'", "expired": false}]}}'
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
printf '{"error":"relayblind: privacy posture rejected: posture_unapproved_code_identity","provider_id":"p1"}\n' > "$tmp/svc/journal.txt"
PRIVACY_REJECTION_WINDOW_SECONDS=0 run_rc 3 "journal fallback refuses rejections in the window" scripts/ops/cli-release.sh _check-privacy-rejections
run_rc 0 "cli status reports the journal source without the metric" scripts/ops/cli-release.sh status
if [ "$(fact_of privacy_unapproved_rejections_source)" = "journal" ]; then ok; else bad "fallback source: $(fact_of privacy_unapproved_rejections_source)"; fi
rm -f "$tmp/svc/journal.txt"

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
bash "$W/scripts/ops/live-lock.sh" release t 2>/dev/null
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
