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

# ---- repo fixture -----------------------------------------------------------
git clone -q --bare --shared "$SRC_REPO" "$tmp/origin.git"
git clone -q --shared --no-checkout "$tmp/origin.git" "$tmp/work"
W="$tmp/work"
git -C "$W" checkout -q --detach "$(git -C "$SRC_REPO" rev-parse HEAD)"
git -C "$W" checkout -q -B main
rm -rf "$W/scripts/ops"
cp -R "$OPS_SRC" "$W/scripts/ops"
find "$W/scripts/ops" -name '__pycache__' -prune -exec rm -rf {} +
printf '\n| Carry-forward CF-OPS-TEST | 1.8.224 carry-forward of the unchanged decode qualification |\n' \
  >> "$W/docs/releases/cli-release-train.md"
git -C "$W" -c user.name=t -c user.email=t@example.invalid add -A scripts/ops docs/releases/cli-release-train.md
git -C "$W" -c user.name=t -c user.email=t@example.invalid commit -q -m "test: working-tree ops scripts"
git -C "$W" -c user.name=t -c user.email=t@example.invalid tag -a v9.0.0 -m "live runtime"
printf 'package main\n' > "$W/phase4-coordinator/opsprobe.go"
git -C "$W" add phase4-coordinator/opsprobe.go
git -C "$W" -c user.name=t -c user.email=t@example.invalid commit -q -m "test: shipped code change"
git -C "$W" push -q origin HEAD:refs/heads/main refs/tags/v9.0.0
git -C "$W" fetch -q origin
B="$(git -C "$W" rev-parse HEAD)"

# ---- stubs and services -------------------------------------------------------
mkdir -p "$tmp/bin" "$tmp/gh" "$tmp/svc"
printf '#!/usr/bin/env bash\nexec python3 %q "$@"\n' "$OPS_SRC/tests/gh_stub.py" > "$tmp/bin/gh"
# ssh stub: run the remote command locally (it only curls the loopback fake).
# shellcheck disable=SC2016  # the stub's own "$@" must stay literal
printf '#!/usr/bin/env bash\nexec bash -c "${@: -1}"\n' > "$tmp/bin/ssh"
chmod +x "$tmp/bin/gh" "$tmp/bin/ssh"
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
expect_err() { if grep -q -- "$1" "$tmp/err"; then ok; else bad "stderr lacks '$1'"; sed 's/^/    /' "$tmp/err" | tail -n 3; fi; }

# ==== pearl-runtime ===========================================================
fixture '{"runs": {}}'
health v9.0.0 1.8.223

PEARL_RUNTIME_VERSION='v9.0.1:refs/heads/x' run_rc 3 "unsafe runtime version refused" scripts/ops/pearl-runtime.sh status
expect_err "PEARL_RUNTIME_VERSION must be vMAJOR.MINOR.PATCH"

health 'v9.0.0;rm' 1.8.223
PEARL_RUNTIME_VERSION=v9.0.1 run_rc 0 "invalid live version is not used" scripts/ops/pearl-runtime.sh status
expect_next live_state:blocked

health v9.9.8 1.8.223
PEARL_RUNTIME_VERSION=v9.0.1 run_rc 0 "status with an unknown live tag" scripts/ops/pearl-runtime.sh status
expect_next code_changed:blocked
case "$(next_field reason)" in *"not available locally"*) ok ;; *) bad "unknown comparison reason: $(next_field reason)" ;; esac
PEARL_RUNTIME_VERSION=v9.0.1 MACPROVIDER_OPS_OWNER=t run_rc 3 "unknown comparison refuses --run" scripts/ops/pearl-runtime.sh next --run

health v9.0.0 1.8.223
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
health v9.0.0 1.8.223
J='"path": ".github/workflows/promote-signed-native-mtp-release-journey.yml"'
fixture '{"latest_stable": "v1.8.223",
  "runs": {"acceptance-candidate.yml": [{"databaseId": 111, "status": "completed", "conclusion": "success", "headSha": "'"$B"'", "createdAt": "2026-10-09T00:00:00Z"}]},
  "artifacts": {"111": [{"name": "acceptance-candidate-'"$B"'", "expired": false}]},
  "run": {
    "222": {"id": 222, "status": "completed", "conclusion": "failure", "head_sha": "'"$B"'", '"$J"', "display_title": "x", "html_url": "u"},
    "333": {"id": 333, "status": "completed", "conclusion": "success", "head_sha": "0000000000000000000000000000000000000000", '"$J"', "display_title": "unrelated", "html_url": "u"},
    "444": {"id": 444, "status": "completed", "conclusion": "success", "head_sha": "'"$B"'", "path": ".github/workflows/ci.yml", "display_title": "CI", "html_url": "u"},
    "555": {"id": 555, "status": "completed", "conclusion": "success", "head_sha": "'"$B"'", '"$J"', "display_title": "journey", "html_url": "u"}},
  "logs": {"333": "nothing relevant here"}}'
SCOPE="$tmp/state/cli-release-1.8.224"
mkdir -p "$SCOPE"
printf '{"step":"signed_byte_verification","run_id":"111","candidate_sha":"%s","checksums_sha256":"%s","compatibility_set_id":"test/repo:v1.8.224@%s"}\n' \
  "$B" "$(printf 'ab%.0s' $(seq 32))" "$B" > "$SCOPE/signed_byte_verification.json"
printf '{"step":"pearl_accepted_ids","evidence":"test"}\n' > "$SCOPE/pearl_accepted_ids.json"
status_doc() { printf '{"binary_version":"%s","provider_id":"canary-test-id","compatibility_set_id":"test/repo:v1.8.224@%s","coordinator":{"connected":%s},"native_mtp":{"mtp_forwards":5},"requests_total":7,"continuous_batching":{"active":true}}' "$1" "$B" "$2" > "$tmp/svc/status.json"; }

run_rc 0 "cli status" scripts/ops/cli-release.sh status
expect_next canary_smoke:manual
run_rc 3 "free-text canary evidence refused" scripts/ops/cli-release.sh next --done canary_smoke --evidence "looked fine"
expect_err "does not accept free-text"
status_doc 1.8.224 false
run_rc 3 "canary probe with coordinator disconnected" scripts/ops/cli-release.sh next --done canary_smoke --probe
status_doc 1.8.223 true
run_rc 3 "canary probe on the wrong version" scripts/ops/cli-release.sh next --done canary_smoke --probe
status_doc 1.8.224 true
run_rc 0 "canary probe on the candidate" scripts/ops/cli-release.sh next --done canary_smoke --probe
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
expect_next promotion:mutate
case "$(next_field command)" in
  *"candidate_run_id=111"*"physical_acceptance_confirmed=true"*) ok ;;
  *) bad "promotion command: $(next_field command)" ;;
esac
rm -f "$SCOPE/e2e_gate.json"
run_rc 0 "cli status without e2e" scripts/ops/cli-release.sh status
expect_next e2e_gate:manual

# ==== catalog-activate gateway proof ==========================================
printf 'test-buyer-token\n' > "$tmp/token"
export BUYER_TOKEN_FILE="$tmp/token" PROBE_MODEL=test/model
R="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["release_id"])' "$W/phase3-binary/catalog/autotune/release.json")"
status_doc 1.8.224 true
printf 'canary-test-id' > "$tmp/svc/provider_id"
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
status_doc 1.8.224 true
printf 'stuck' > "$tmp/svc/mode"
run_rc 1 "right provider but counters stuck is still refused" scripts/ops/catalog-activate.sh _gateway-proof
printf 'move' > "$tmp/svc/mode"
run_rc 0 "proof accepted when mtp_forwards moves" scripts/ops/catalog-activate.sh _gateway-proof
if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["request_id"].startswith("ops-proof-") and d["mtp_forwards_delta"] > 0 and d["served_by_canary"] is True else 1)' "$tmp/state/catalog-$R/gateway_proof.json"; then ok; else bad "proof marker lacks request id / delta"; fi
run_rc 0 "catalog status with a fresh proof" scripts/ops/catalog-activate.sh status
state_of() { python3 -c 'import json,sys; print(next(s["state"] for s in json.load(open(sys.argv[1]))["steps"] if s["id"] == sys.argv[2]))' "$tmp/out" "$1"; }
if [ "$(state_of gateway_proof)" = "done" ]; then ok; else bad "fresh proof not done"; fi
touch -t "$(date -v-25H +%Y%m%d%H%M 2>/dev/null || date -d '-25 hours' +%Y%m%d%H%M)" "$tmp/state/catalog-$R/gateway_proof.json"
run_rc 0 "catalog status with an expired proof" scripts/ops/catalog-activate.sh status
if [ "$(state_of gateway_proof)" = "pending" ]; then ok; else bad "expired proof still counted"; fi

printf 'entry points: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
