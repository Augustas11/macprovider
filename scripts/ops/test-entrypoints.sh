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
# provider-tied gateway proof and its 24 h expiry; the pearl-runtime one-time
# auto_vacuum conversion (drain gate, downtime, lock, quick_check, restart);
# the on-demand retention run (nightly window, busy/disabled refusals, the
# report, its marker and the drain gate that reads the same lap); the
# compute-integrity private corpus (the shared corpus rules, the generator,
# the overlay edit, one restart, rollback when the coordinator rejects it);
# the native-vision qualification record (local rules, an existing routing
# mapping, validation and restart-failure rollback with a verified recovery
# restart (also when the overlay was already right), idempotence, a different
# entry refused, an invalid live entry blocked, the record read through one
# private descriptor, the provider id never printed); catalog-activate's
# operator-paused canary refusal, failing-check summary, acknowledged pricing
# activation and the owed evidence (e) it records and keeps open; the
# pearl-runtime updater-bundle install from the running tag (lock refusal,
# staging cleanup, idempotence, drift, a tag whose writers differ from
# origin/main, a lightweight tag).
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
# Pearl's sudo (the ssh stub already runs as the test user) and the installed
# coordinator binary for stats-migrate: state in $tmp/pearl/stats-state
# ("<migration> pending|applied" lines); apply marks all applied.
printf '#!/usr/bin/env bash\nexec "$@"\n' > "$tmp/bin/sudo"
chmod +x "$tmp/bin/sudo"
mkdir -p "$tmp/pearl/etc"
printf '000_base applied\n031_attested_hardware applied\n' > "$tmp/pearl/stats-state"
export PEARL_COORDINATOR_BIN="$tmp/pearl/coordinator"
cat > "$PEARL_COORDINATOR_BIN" <<'FAKECOORD'
#!/usr/bin/env bash
state="$FAKE_PEARL/pearl/stats-state"
echo "$* | dsn=${COORDINATOR_PARTNER_KEYS_ADMIN_DSN:-unset}" >> "$FAKE_PEARL/pearl/stats-calls"
[ "${1:-}" = stats-migrate ] || exit 2
shift
if [ "${1:-}" = --check ]; then
  [ -z "${FAKE_STATS_CHECK_FAIL:-}" ] || { echo "stats-migrate: dial ${COORDINATOR_PARTNER_KEYS_ADMIN_DSN:-?}: refused" >&2; exit 1; }
  echo "stats-migrate check (env): 2 embedded, $(grep -c applied "$state") applied"
  sed 's/^/  /' "$state"
  exit 0
fi
echo "applying with ${COORDINATOR_PARTNER_KEYS_ADMIN_DSN:-unset}"
[ -z "${FAKE_STATS_NOISE:-}" ] || printf 'POSTGRESQL://u:leakpw1@h/db host=h password='"'"'sec ret'"'"' PWD=leakpw2 \033[31mred\033[0m\n'
[ -z "${FAKE_STATS_APPLY_FAIL:-}" ] || { echo "stats-migrate: apply failed" >&2; exit 1; }
sed -i.bak 's/ pending$/ applied/' "$state"
echo "stats-migrate ok"
FAKECOORD
chmod +x "$PEARL_COORDINATOR_BIN"
export PEARL_COORDINATOR_ENV="$tmp/pearl/etc/coordinator.env"
printf 'COORDINATOR_PARTNER_KEYS_ADMIN_DSN=postgres://admin:adminpw@127.0.0.1:5432/stats\n' > "$PEARL_COORDINATOR_ENV"
chmod 600 "$PEARL_COORDINATOR_ENV"
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
unset MACPROVIDER_OPS_OWNER PEARL_RUNTIME_VERSION MACPROVIDER_OPS_ENTRYPOINT GH_TOKEN MALIBU_DOWNLOAD_SSH_KEY MALIBU_DOWNLOAD_VPS_HOST

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

# One-time app_attest_recorder provisioning (SPEC-033 §2.7) comes before the
# plan once the release exists, and runs the dist provisioner on Pearl.
fixture '{"runs": {"pearl-runtime-release.yml": []}, "releases": {"v9.0.1": {"assets": [{"name": "pearl-release.json"}]}}}'
mkdir -p "$tmp/pearl/etc"
export PEARL_COORDINATOR_ENV="$tmp/pearl/etc/coordinator.env"
printf 'COORDINATOR_PARTNER_KEYS_ADMIN_DSN=postgres://admin:adminpw@127.0.0.1:5432/stats\nONBOARDING_POSTGRES_DSN=postgres://provider_onboarding:obpw@127.0.0.1:5432/stats\n' > "$PEARL_COORDINATOR_ENV"
chmod 600 "$PEARL_COORDINATOR_ENV"
PEARL_RUNTIME_VERSION=v9.0.1 run_rc 0 "status without the recorder DSN" scripts/ops/pearl-runtime.sh status
expect_next app_attest_recorder:mutate
case "$(next_field command)" in *"provision-app-attest-recorder.py --env-file $PEARL_COORDINATOR_ENV"*) ok ;; *) bad "recorder command: $(next_field command)" ;; esac
case "$(next_field command)" in *adminpw*|*obpw*) bad "recorder command carries a secret" ;; *) ok ;; esac
# A fake psql on "Pearl": accepts the bootstrap and answers the login check.
cat > "$tmp/bin/psql" <<'FAKEPSQL'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = -f ] && exit 0; done
cat >/dev/null
echo "${FAKE_PSQL_VERIFY:-t}"
FAKEPSQL
chmod +x "$tmp/bin/psql"
PEARL_RUNTIME_VERSION=v9.0.1 MACPROVIDER_OPS_OWNER=t run_rc 0 "recorder provisioning runs" scripts/ops/pearl-runtime.sh next --run
expect_lock_free
if grep -Eq '^ONBOARDING_APP_ATTEST_RECORD_DSN=postgres://app_attest_recorder:[^@]{40,}@127\.0\.0\.1:5432/stats$' "$PEARL_COORDINATOR_ENV"; then ok; else bad "recorder DSN not written"; fi
pw="$(sed -n 's#^ONBOARDING_APP_ATTEST_RECORD_DSN=postgres://app_attest_recorder:\([^@]*\)@.*#\1#p' "$PEARL_COORDINATOR_ENV")"
if [ -n "$pw" ] && ! grep -qF -- "$pw" "$tmp/out" "$tmp/err"; then ok; else bad "recorder password printed"; fi
# (An https COORDINATOR_URL keeps the plan command renderable; /healthz is then
# unreadable, which leaves the recorder step's own state to check.)
COORDINATOR_URL="https://127.0.0.1:$PORT" PEARL_RUNTIME_VERSION=v9.0.1 run_rc 0 "status with the recorder DSN" scripts/ops/pearl-runtime.sh status
if [ "$(state_of app_attest_recorder)" = "done" ]; then ok; else bad "recorder step state: $(state_of app_attest_recorder)"; fi
case "$(next_field id)" in app_attest_recorder) bad "recorder step offered again" ;; *) ok ;; esac
# A DSN that no longer passes the login/least-privilege check is offered for repair.
FAKE_PSQL_VERIFY=f PEARL_RUNTIME_VERSION=v9.0.1 run_rc 0 "status with a failing recorder DSN" scripts/ops/pearl-runtime.sh status
expect_next app_attest_recorder:mutate
case "$(next_field command)" in *"--sql \$d/app-attest-recorder-bootstrap.sql --rotate"*) ok ;; *) bad "repair command lacks --rotate: $(next_field command)" ;; esac
rm -f "$tmp/bin/psql"

# stats_migrate (#1984): the signed updater never applies stats migrations, so a
# pending one under the installed binary is applied before app_attest_recorder,
# and one of the new binary is applied before health is reported done.
pending_state() { printf '000_base applied\n031_attested_hardware pending\n' > "$tmp/pearl/stats-state"; }
applied_state() { printf '000_base applied\n031_attested_hardware applied\n' > "$tmp/pearl/stats-state"; }
: > "$tmp/pearl/stats-calls"
pending_state
PEARL_RUNTIME_VERSION=v9.0.1 run_rc 0 "status with a pending stats migration" scripts/ops/pearl-runtime.sh status
expect_next stats_migrate:mutate
if [ "$(state_of stats_migrate)" = pending ]; then ok; else bad "stats_migrate state: $(state_of stats_migrate)"; fi
if [ "$(fact_of stats_migrations_pending)" = 031_attested_hardware ]; then ok; else bad "pending fact: $(fact_of stats_migrations_pending)"; fi
case "$(next_field expected_downtime)" in none*) ok ;; *) bad "stats downtime: $(next_field expected_downtime)" ;; esac
case "$(next_field runbook)" in *pearl-coordinator-rollout.md#stats-migrations) ok ;; *) bad "stats runbook: $(next_field runbook)" ;; esac
case "$(next_field command)" in *adminpw*|*postgres://admin*) bad "stats command carries a DSN" ;; *) ok ;; esac
if grep -q 'admin-dsn' "$tmp/pearl/stats-calls"; then bad "the DSN was passed in argv"; else ok; fi
# A read failure blocks and never echoes the DSN.
FAKE_STATS_CHECK_FAIL=1 PEARL_RUNTIME_VERSION=v9.0.1 run_rc 0 "status with an unreadable stats state" scripts/ops/pearl-runtime.sh status
expect_next stats_migrate:blocked
case "$(next_field reason)" in *adminpw*) bad "check failure leaked the DSN" ;; *REDACTED*) ok ;; *) bad "check failure reason: $(next_field reason)" ;; esac
# A failed apply leaves the step pending and hands the lock back.
FAKE_STATS_APPLY_FAIL=1 PEARL_RUNTIME_VERSION=v9.0.1 MACPROVIDER_OPS_OWNER=t run_rc 1 "failed stats apply" scripts/ops/pearl-runtime.sh next --run
expect_lock_free
PEARL_RUNTIME_VERSION=v9.0.1 MACPROVIDER_OPS_OWNER=t run_rc 0 "stats migrations apply" scripts/ops/pearl-runtime.sh next --run
expect_lock_free
if grep -q ' pending$' "$tmp/pearl/stats-state"; then bad "a migration is still pending"; else ok; fi
if grep -qF adminpw "$tmp/out" "$tmp/err"; then bad "the stats apply printed the DSN"; else ok; fi
if grep -q 'applying with REDACTED' "$tmp/out"; then ok; else bad "the DSN was not redacted in the apply output"; fi
# Uppercase-scheme and key=value DSNs are redacted, control bytes stripped.
pending_state
FAKE_STATS_NOISE=1 PEARL_RUNTIME_VERSION=v9.0.1 MACPROVIDER_OPS_OWNER=t run_rc 0 "stats apply with noisy output" scripts/ops/pearl-runtime.sh next --run
if grep -Eq 'leakpw|sec ret' "$tmp/out" "$tmp/err"; then bad "noisy DSN leaked"; else ok; fi
if grep -q 'password=REDACTED' "$tmp/out" && ! grep -q "$(printf '\033')" "$tmp/out"; then ok; else bad "noisy output not cleaned"; fi
PEARL_RUNTIME_VERSION=v9.0.1 run_rc 0 "status after the stats apply" scripts/ops/pearl-runtime.sh status
if [ "$(state_of stats_migrate)" = done ]; then ok; else bad "stats_migrate state after apply: $(state_of stats_migrate)"; fi
expect_next app_attest_recorder:mutate
# Between the apply and the end of the updater unit the check is skipped (the
# binary is being swapped).
pending_state
mkdir -p "$MACPROVIDER_OPS_STATE_DIR/pearl-runtime-v9.0.1"
printf '{"step":"apply","recorded_at":"2026-10-09T00:00:00Z"}\n' > "$MACPROVIDER_OPS_STATE_DIR/pearl-runtime-v9.0.1/apply.json"
PEARL_RUNTIME_VERSION=v9.0.1 run_rc 0 "status while the updater runs" scripts/ops/pearl-runtime.sh status
if [ "$(state_of stats_migrate)" = pending ]; then ok; else bad "stats_migrate while the updater runs: $(state_of stats_migrate)"; fi
case "$(next_field id)" in stats_migrate) bad "stats migrate offered during the apply window" ;; *) ok ;; esac
# New binary live (v9.0.1) with a pending migration: not done until applied.
health v9.0.1 $LIVE
PEARL_RUNTIME_VERSION=v9.0.1 run_rc 0 "status with the new binary live and a pending migration" scripts/ops/pearl-runtime.sh status
expect_next stats_migrate:mutate
applied_state
PEARL_RUNTIME_VERSION=v9.0.1 run_rc 0 "status with the new binary live" scripts/ops/pearl-runtime.sh status
expect_next done:done
# Unknown is not "nothing pending": without ssh the live release is not done.
PEARL_SSH= PEARL_RUNTIME_VERSION=v9.0.1 run_rc 0 "status with the new binary live and no ssh" scripts/ops/pearl-runtime.sh status
expect_next stats_migrate:blocked
rm -rf "$MACPROVIDER_OPS_STATE_DIR/pearl-runtime-v9.0.1"
health v9.0.0 $LIVE

# ==== pearl-runtime: one-time auto_vacuum conversion (#1979) ==================
# Real SQLite files stand in for Pearl's; flock is a stub (not on every host).
mkdir -p "$tmp/vacuum"
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/flock"
chmod +x "$tmp/bin/flock"
VDB="$tmp/vacuum/coordinator.db"
sqlite3 "$VDB" "PRAGMA journal_mode=WAL; CREATE TABLE settlement_evidence_retention_state (id INTEGER PRIMARY KEY, laps_completed INTEGER, last_lap_eligible_requests INTEGER, last_lap_completed_at_utc TEXT); INSERT INTO settlement_evidence_retention_state VALUES (1, 3, 0, '2026-10-10T03:20:00Z'); CREATE TABLE t (v BLOB); INSERT INTO t VALUES (randomblob(50000));" >/dev/null
sqlite3 "$VDB.route-snapshots" "CREATE TABLE j (v BLOB); INSERT INTO j VALUES (randomblob(20000));" >/dev/null
VAUDIT="$tmp/vacuum/coordinator-audit.db"
sqlite3 "$VAUDIT" "CREATE TABLE audit_log (v BLOB); INSERT INTO audit_log VALUES (randomblob(20000));" >/dev/null
# sqlite3 wrapper: FAKE_QUICK_CHECK_FAIL makes quick_check report damage.
cat > "$tmp/bin/pearl-sqlite3" <<FAKESQLITE
#!/usr/bin/env bash
if [ -n "\${FAKE_QUICK_CHECK_FAIL:-}" ] && [[ "\${*: -1}" == *quick_check* ]]; then echo "*** in database main ***"; exit 0; fi
exec $(command -v sqlite3) "\$@"
FAKESQLITE
chmod +x "$tmp/bin/pearl-sqlite3"
PEARL_SQLITE3="$tmp/bin/pearl-sqlite3"
export PEARL_SQLITE3 PEARL_DEPLOY_LOCK="$tmp/vacuum/deploy.lock" PEARL_DEPLOY_OPERATION_LOCK="$tmp/vacuum/deploy-operation.lock"
health v9.0.0 "$LIVE"
PEARL_RUNTIME_TASK=retention-vacuum-conversion run_rc 0 "vacuum task without a database path" scripts/ops/pearl-runtime.sh status
expect_next vacuum_mode:blocked
export PEARL_COORDINATOR_DB="$VDB"
# A coordinator without the overdue count stays blocked, even at 0 eligible.
PEARL_RUNTIME_TASK=retention-vacuum-conversion run_rc 0 "vacuum task on a coordinator without the overdue count" scripts/ops/pearl-runtime.sh status
expect_next drain_gate:blocked
# Unknown (-1, a lap begun before the count existed) stays blocked.
sqlite3 "$VDB" "ALTER TABLE settlement_evidence_retention_state ADD COLUMN last_lap_overdue_requests INTEGER NOT NULL DEFAULT -1; UPDATE settlement_evidence_retention_state SET last_lap_completed_at_utc = strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-2 hours')" >/dev/null
PEARL_RUNTIME_TASK=retention-vacuum-conversion run_rc 0 "vacuum task with an unknown overdue count" scripts/ops/pearl-runtime.sh status
expect_next drain_gate:blocked
sqlite3 "$VDB" "UPDATE settlement_evidence_retention_state SET last_lap_eligible_requests = 117000, last_lap_overdue_requests = 12" >/dev/null
PEARL_RUNTIME_TASK=retention-vacuum-conversion run_rc 0 "vacuum task before the drain" scripts/ops/pearl-runtime.sh status
expect_next drain_gate:blocked
case "$(next_field reason)" in *"last_lap_overdue_requests=12"*) ok ;; *) bad "drain gate reason: $(next_field reason)" ;; esac
PEARL_RUNTIME_TASK=retention-vacuum-conversion MACPROVIDER_OPS_OWNER=t run_rc 3 "conversion refused before the drain" scripts/ops/pearl-runtime.sh next --run
if [ "$(sqlite3 "$VDB" 'PRAGMA auto_vacuum;')" = 0 ]; then ok; else bad "conversion ran before the drain"; fi
# Caught up: the last lap still found a night's newly eligible requests, but
# none overdue.
# A caught-up lap that completed long ago does not open the gate.
sqlite3 "$VDB" "UPDATE settlement_evidence_retention_state SET laps_completed = 4, last_lap_eligible_requests = 48000, last_lap_overdue_requests = 0, last_lap_completed_at_utc = strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-3 days')" >/dev/null
PEARL_RUNTIME_TASK=retention-vacuum-conversion run_rc 0 "vacuum task after a stale caught-up lap" scripts/ops/pearl-runtime.sh status
expect_next drain_gate:blocked
case "$(next_field reason)" in *"within 36 hours"*) ok ;; *) bad "stale drain gate reason: $(next_field reason)" ;; esac
case "$(next_field reason)" in *"PEARL_RUNTIME_TASK=retention-run"*) ok ;; *) bad "drain gate reason does not name the on-demand run: $(next_field reason)" ;; esac

# ==== pearl-runtime: one-time on-demand retention run (#1979) ===================
# The fake coordinator's operator route updates the same lap state the drain
# gate reads (tests/fake_services.py retention_db).
RKEY="opkey-$(openssl rand -hex 16)"
printf '%s' "$RKEY" > "$tmp/svc/operator_key"
printf '%s' "$VDB" > "$tmp/svc/retention_db"
printf 'auth:\n  operator_key: env:OPERATOR_KEY\n' > "$tmp/pearl/coordinator.yaml"
printf 'relay_blind:\n  enabled: true\n' > "$tmp/pearl/overlay.yaml"
printf 'OPS_FAKE_SECRET=x\0OPERATOR_KEY=%s\0' "$RKEY" > "$tmp/proc/$(cat "$tmp/svc/mainpid")/environ"
export PEARL_COORDINATOR_ADMIN_URL="http://127.0.0.1:$PORT" RETENTION_RUN_POLL_S=0 RETENTION_RUN_WAIT_MAX_S=5
RSCOPE="$tmp/state/retention-run"
PEARL_SSH= PEARL_RUNTIME_TASK=retention-run run_rc 0 "retention run without ssh" scripts/ops/pearl-runtime.sh status
expect_next window:blocked
soon="$(python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc)+d.timedelta(minutes=5)).strftime("%H:%M"))')"
PEARL_RETENTION_NIGHTLY_UTC="$soon" PEARL_RUNTIME_TASK=retention-run run_rc 0 "retention run just before the nightly run" scripts/ops/pearl-runtime.sh status
expect_next window:blocked
PEARL_RETENTION_NIGHTLY_UTC="$soon" PEARL_RUNTIME_TASK=retention-run MACPROVIDER_OPS_OWNER=t run_rc 3 "retention run refused just before the nightly run" scripts/ops/pearl-runtime.sh next --run
PEARL_COORDINATOR_ADMIN_URL="https://coordinator.example" PEARL_RUNTIME_TASK=retention-run run_rc 3 "non-loopback admin URL refused" scripts/ops/pearl-runtime.sh status
PEARL_RUNTIME_TASK=retention-run run_rc 0 "retention run status" scripts/ops/pearl-runtime.sh status
expect_next run:mutate
case "$(next_field expected_downtime)" in "none (no restart)"*) ok ;; *) bad "retention run downtime: $(next_field expected_downtime)" ;; esac
case "$(next_field command)" in "scripts/ops/pearl-runtime.sh _retention-run") ok ;; *) bad "retention run command: $(next_field command)" ;; esac
run_rc 3 "_retention-run refuses outside next --run" scripts/ops/pearl-runtime.sh _retention-run
PEARL_RUNTIME_TASK=retention-run run_rc 3 "retention run needs an owner" scripts/ops/pearl-runtime.sh next --run
# A run in progress (nightly retention or ledger rollup) is refused; nothing starts.
: > "$tmp/svc/retention_busy"
PEARL_RUNTIME_TASK=retention-run MACPROVIDER_OPS_OWNER=t run_rc 3 "retention run refused while a run is in progress" scripts/ops/pearl-runtime.sh next --run
expect_err "run is in progress"
expect_lock_free
if [ -e "$RSCOPE/run.json" ] || [ -e "$tmp/svc/retention_posts" ]; then bad "a refused run started or recorded something"; else ok; fi
rm -f "$tmp/svc/retention_busy"
: > "$tmp/svc/retention_disabled"
PEARL_RUNTIME_TASK=retention-run MACPROVIDER_OPS_OWNER=t run_rc 3 "retention run refused while retention is disabled" scripts/ops/pearl-runtime.sh next --run
expect_err "billing.retention.enabled is false"
rm -f "$tmp/svc/retention_disabled"
# A started run whose report never appears fails within the bound, unrecorded.
: > "$tmp/svc/retention_no_report"
RETENTION_RUN_WAIT_MAX_S=0 PEARL_RUNTIME_TASK=retention-run MACPROVIDER_OPS_OWNER=t run_rc 1 "retention run without a report" scripts/ops/pearl-runtime.sh next --run
expect_err "no report for this run"
expect_lock_free
if [ -e "$RSCOPE/run.json" ]; then bad "a run without a report was recorded"; else ok; fi
rm -f "$tmp/svc/retention_no_report" "$tmp/svc/retention_posts"
# A lap with overdue requests: recorded, printed, and the gate stays shut.
printf '7' > "$tmp/svc/retention_overdue"
PEARL_RUNTIME_TASK=retention-run MACPROVIDER_OPS_OWNER=t run_rc 0 "on-demand retention run (still overdue)" scripts/ops/pearl-runtime.sh next --run
expect_lock_free
if grep -q "EXPECTED DOWNTIME for run: none (no restart)" "$tmp/out"; then ok; else bad "retention run downtime not printed first"; fi
for want in "status: deleted" "deleted_requests: 42" "backlog_drained: false" "last_lap_overdue_requests: 7" "stop_reason: lap_complete"; do
  if grep -qF "$want" "$tmp/out"; then ok; else bad "retention run output lacks '$want'"; fi
done
if grep -qF "$RKEY" "$tmp/out" "$tmp/err"; then bad "the operator key was printed"; else ok; fi
if grep -q "archive_file\|retention-archive" "$tmp/out" "$tmp/err" "$RSCOPE/run.json"; then bad "report fields beyond the summary leaked"; else ok; fi
if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["backlog_drained"] is False and d["last_lap_overdue_requests"] == 7 and d["status"] == "deleted" else 1)' "$RSCOPE/run.json"; then ok; else bad "retention run marker: $(cat "$RSCOPE/run.json")"; fi
PEARL_RUNTIME_TASK=retention-run run_rc 0 "retention run status after an overdue lap" scripts/ops/pearl-runtime.sh status
expect_next run:mutate
PEARL_RUNTIME_TASK=retention-vacuum-conversion run_rc 0 "vacuum task after an overdue on-demand lap" scripts/ops/pearl-runtime.sh status
expect_next drain_gate:blocked
# A caught-up on-demand lap opens the gate exactly like a nightly lap.
printf '0' > "$tmp/svc/retention_overdue"
PEARL_RUNTIME_TASK=retention-run MACPROVIDER_OPS_OWNER=t run_rc 0 "on-demand retention run (caught up)" scripts/ops/pearl-runtime.sh next --run
if grep -qF "backlog_drained: true" "$tmp/out"; then ok; else bad "caught-up run output: $(cat "$tmp/out")"; fi
PEARL_RUNTIME_TASK=retention-run run_rc 0 "retention run status after a caught-up lap" scripts/ops/pearl-runtime.sh status
expect_next done:done
PEARL_RUNTIME_TASK=retention-vacuum-conversion run_rc 0 "vacuum task after a caught-up on-demand lap" scripts/ops/pearl-runtime.sh status
expect_next convert:mutate
if [ "$(fact_of retention_run_backlog_drained)" = True ]; then ok; else bad "gate fact retention_run_backlog_drained: $(fact_of retention_run_backlog_drained)"; fi
# A database behind the live coordinator's own report is not the live one.
sqlite3 "$VDB" "UPDATE settlement_evidence_retention_state SET last_lap_completed_at_utc = strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-1 hours')" >/dev/null
PEARL_RUNTIME_TASK=retention-vacuum-conversion run_rc 0 "vacuum task on a database behind the recorded run" scripts/ops/pearl-runtime.sh status
expect_next drain_gate:blocked
case "$(next_field reason)" in *"must be the live coordinator's database"*) ok ;; *) bad "lagging database reason: $(next_field reason)" ;; esac
# A database lap earlier within the same second as the recorded one is behind.
python3 - "$RSCOPE/run.json" "$VDB" <<'PYFRAC'
import json, subprocess, sys
r = json.load(open(sys.argv[1]))
r["last_lap_completed_at_utc"] = r["last_lap_completed_at_utc"][:19] + ".900000000Z"
json.dump(r, open(sys.argv[1], "w"))
subprocess.run(["sqlite3", sys.argv[2], "UPDATE settlement_evidence_retention_state SET last_lap_completed_at_utc = '%s'" % (r["last_lap_completed_at_utc"][:19] + ".100000000Z")], check=True)
PYFRAC
PEARL_RUNTIME_TASK=retention-vacuum-conversion run_rc 0 "vacuum task on a database behind by a fraction of a second" scripts/ops/pearl-runtime.sh status
expect_next drain_gate:blocked
# A recorded lap older than 36 hours is offered again.
python3 -c 'import datetime as d,json,sys; r=json.load(open(sys.argv[1])); r["last_lap_completed_at_utc"]=(d.datetime.now(d.timezone.utc)-d.timedelta(hours=37)).strftime("%Y-%m-%dT%H:%M:%S.000000000Z"); json.dump(r,open(sys.argv[1],"w"))' "$RSCOPE/run.json"
PEARL_RUNTIME_TASK=retention-run run_rc 0 "retention run status with a stale record" scripts/ops/pearl-runtime.sh status
expect_next run:mutate
# A refused run carries backlog_drained over from an older lap: recorded, the
# step fails, and the task offers the run again.
printf 'refused_archive_disk_low' > "$tmp/svc/retention_status"
PEARL_RUNTIME_TASK=retention-run MACPROVIDER_OPS_OWNER=t run_rc 1 "refused on-demand run" scripts/ops/pearl-runtime.sh next --run
expect_err "ended with status refused_archive_disk_low"
expect_lock_free
if python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["status"] == "refused_archive_disk_low" else 1)' "$RSCOPE/run.json"; then ok; else bad "refused run not recorded"; fi
PEARL_RUNTIME_TASK=retention-run run_rc 0 "retention run status after a refused run" scripts/ops/pearl-runtime.sh status
expect_next run:mutate
rm -f "$tmp/svc/retention_status"
# An error report without stop_reason or lap fields is still printed and recorded.
: > "$tmp/svc/retention_error"
PEARL_RUNTIME_TASK=retention-run MACPROVIDER_OPS_OWNER=t run_rc 1 "on-demand run with an error report" scripts/ops/pearl-runtime.sh next --run
if grep -qF "error: archive verify failed" "$tmp/out" && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["status"] == "exported" and d["error"] else 1)' "$RSCOPE/run.json"; then ok; else bad "error report not printed and recorded"; fi
expect_err "ended with status exported"
rm -f "$tmp/svc/retention_error"
# An older report is never taken for this run's: with the report route
# serving only a previous report, the run times out unrecorded.
rm -f "$RSCOPE/run.json"
: > "$tmp/svc/retention_no_report"
RETENTION_RUN_WAIT_MAX_S=0 PEARL_RUNTIME_TASK=retention-run MACPROVIDER_OPS_OWNER=t run_rc 1 "an older report is not this run's" scripts/ops/pearl-runtime.sh next --run
if [ -e "$RSCOPE/run.json" ]; then bad "an older report was recorded as this run"; else ok; fi
rm -f "$tmp/svc/retention_no_report"
rm -rf "$RSCOPE" "$tmp/svc/retention_report.json" "$tmp/svc/retention_overdue" "$tmp/svc/retention_db" "$tmp/svc/retention_posts"
rm -f "$tmp/pearl/coordinator.yaml" "$tmp/pearl/overlay.yaml"
unset PEARL_COORDINATOR_ADMIN_URL RETENTION_RUN_POLL_S RETENTION_RUN_WAIT_MAX_S

sqlite3 "$VDB" "UPDATE settlement_evidence_retention_state SET last_lap_completed_at_utc = strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-2 hours')" >/dev/null
PEARL_RUNTIME_TASK=retention-vacuum-conversion run_rc 0 "vacuum task after the drain" scripts/ops/pearl-runtime.sh status
expect_next convert:mutate
case "$(next_field expected_downtime)" in *"coordinator stopped"*VACUUM*) ok ;; *) bad "conversion downtime: $(next_field expected_downtime)" ;; esac
PEARL_RUNTIME_TASK=retention-vacuum-conversion run_rc 3 "conversion needs an owner" scripts/ops/pearl-runtime.sh next --run
# A file that fails quick_check is refused before anything changes, and the
# coordinator is started again.
FAKE_QUICK_CHECK_FAIL=1 PEARL_RUNTIME_TASK=retention-vacuum-conversion MACPROVIDER_OPS_OWNER=t run_rc 1 "conversion refused on a failing quick_check" scripts/ops/pearl-runtime.sh next --run
expect_err "quick_check failed on $VDB before the conversion"
expect_lock_free
if [ "$(sqlite3 "$VDB" 'PRAGMA auto_vacuum;')" = 0 ] && [ "$(tr '\n' ' ' < "$tmp/svc/unit-actions")" = "stop start " ]; then ok; else bad "refused conversion changed the file or left the unit stopped"; fi
if find "$tmp/vacuum" -name '*.pre-incremental-*' | grep -q .; then bad "a refused conversion took a backup"; else ok; fi
rm -f "$tmp/svc/unit-actions"
PEARL_RUNTIME_TASK=retention-vacuum-conversion MACPROVIDER_OPS_OWNER=t run_rc 0 "conversion runs" scripts/ops/pearl-runtime.sh next --run
expect_lock_free
if grep -q "EXPECTED DOWNTIME for convert" "$tmp/out"; then ok; else bad "downtime not printed before the conversion"; fi
for l in "$PEARL_UPDATER_LOCK" "$PEARL_DEPLOY_LOCK" "$PEARL_DEPLOY_OPERATION_LOCK"; do
  if [ "$(ls -l "$l" | cut -c1-10)" = "-rw-------" ]; then ok; else bad "lock $l is not a 0600 file: $(ls -l "$l")"; fi
done
if [ "$(sqlite3 "$VDB" 'PRAGMA auto_vacuum;')" = 2 ] && [ "$(sqlite3 "$VDB.route-snapshots" 'PRAGMA auto_vacuum;')" = 2 ] && [ "$(sqlite3 "$VAUDIT" 'PRAGMA auto_vacuum;')" = 2 ]; then ok; else bad "files not converted"; fi
if [ "$(tr '\n' ' ' < "$tmp/svc/unit-actions")" = "stop start " ]; then ok; else bad "unit actions: $(cat "$tmp/svc/unit-actions" 2>/dev/null)"; fi
for f in "$VDB" "$VDB.route-snapshots" "$VAUDIT"; do
  b="$(find "$tmp/vacuum" -name "$(basename "$f").pre-incremental-*" | head -n 1)"
  if [ -n "$b" ] && [ "$(sqlite3 "$b" 'PRAGMA quick_check;')" = ok ]; then ok; else bad "no fresh backup of $f"; fi
done
grep -q "backup: $VDB.pre-incremental-" "$tmp/err" && ok || bad "backup path not named"
PEARL_RUNTIME_TASK=retention-vacuum-conversion run_rc 0 "vacuum task after the conversion" scripts/ops/pearl-runtime.sh status
expect_next done:done
PEARL_RUNTIME_TASK=bogus run_rc 3 "unknown task refused" scripts/ops/pearl-runtime.sh status
unset PEARL_COORDINATOR_DB PEARL_SQLITE3 PEARL_DEPLOY_LOCK PEARL_DEPLOY_OPERATION_LOCK
rm -f "$tmp/bin/flock" "$tmp/bin/pearl-sqlite3" "$tmp/svc/unit-actions"

# ==== compute-integrity private corpus (#1644) =================================
# The corpus check is pinned to the coordinator's ParseCorpus by shared cases
# (internal/computeintegrity/corpus_parse_cases_test.go runs the Go side).
if python3 -I - "$OPS_SRC/lib/pearl-cli-config.py" "$SRC_REPO/phase4-coordinator/internal/computeintegrity/testdata/corpus_parse_cases.json" <<'PYCASES'
import base64, importlib.util, json, sys
spec = importlib.util.spec_from_file_location("pcc", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
bad = []
for c in json.load(open(sys.argv[2]))["cases"]:
    try:
        m.parse_corpus(base64.b64decode(c["doc_b64"]))
        got = True
    except m.Refused:
        got = False
    if got != c["python"] or (got and not c["go"]):
        bad.append(c["name"])
print(" ".join(bad))
sys.exit(1 if bad else 0)
PYCASES
then ok; else bad "corpus check disagrees with the shared ParseCorpus cases"; fi
# The generator: private topics in, a private corpus out, outside the repo.
CI_SECRETS="$tmp/operator-secrets"
mkdir -p "$CI_SECRETS"
for i in $(seq 1 20); do printf 'private topic number %s about something\n' "$i"; done > "$CI_SECRETS/topics.txt"
head -n 5 "$CI_SECRETS/topics.txt" > "$CI_SECRETS/few-topics.txt"
gen() { python3 -I "$SRC_REPO/scripts/compute-integrity-corpus.py" "$@" >"$tmp/out" 2>"$tmp/err"; }
if gen --topics "$CI_SECRETS/few-topics.txt" --out "$CI_SECRETS/x.json"; then bad "generator accepted too few topics"; else ok; fi
if gen --topics "$CI_SECRETS/topics.txt" --out "$W/corpus.json"; then bad "generator wrote inside the repository"; else ok; fi
if gen --topics "$CI_SECRETS/topics.txt" --count 300 --version private-test-1 --out "$CI_SECRETS/corpus1.json"; then ok; else bad "generator failed: $(cat "$tmp/err")"; fi
CORPUS1="$CI_SECRETS/corpus1.json"
if [ "$(ls -l "$CORPUS1" | cut -c1-10)" = "-rw-------" ]; then ok; else bad "generated corpus is not 0600: $(ls -l "$CORPUS1")"; fi
if grep -q "private topic" "$tmp/out" "$tmp/err"; then bad "the generator printed corpus content"; else ok; fi
if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if len(d["prompts"]) == 300 and len({(p["system"], p["user"]) for p in d["prompts"]}) == 300 else 1)' "$CORPUS1"; then ok; else bad "generated corpus is not 300 distinct prompts"; fi
if gen --topics "$CI_SECRETS/topics.txt" --version private-test-1 --out "$CORPUS1"; then bad "generator overwrote an existing corpus"; else ok; fi
gen --topics "$CI_SECRETS/topics.txt" --count 50 --version private-test-2 --out "$CI_SECRETS/corpus2.json" || bad "second corpus: $(cat "$tmp/err")"
CORPUS2="$CI_SECRETS/corpus2.json"

restarts() { cat "$tmp/svc/restarts" 2>/dev/null || echo 0; }
# Fake Pearl: base and overlay as on Pearl, scoring inert (no corpus_path).
printf 'listen:\n  bind_address: 127.0.0.1\n' > "$tmp/pearl/coordinator.yaml"
printf 'relay_blind:\n  enabled: true\n' > "$tmp/pearl/overlay.yaml"
systemctl restart macprovider-coordinator
export PEARL_COMPUTE_INTEGRITY_CORPUS_PATH="$tmp/pearl/etc/compute-integrity-corpus.json"
CI_STAGED="$tmp/pearl/etc/.compute-integrity-corpus.staging"
PEARL_RUNTIME_TASK=compute-integrity-enable run_rc 0 "compute-integrity status without a corpus" scripts/ops/pearl-runtime.sh status
expect_next corpus:blocked
if [ "$(fact_of pearl_ci_private_corpus_missing)" = True ]; then ok; else bad "inert scoring not reported: $(fact_of pearl_ci_private_corpus_missing)"; fi
cp "$CORPUS1" "$W/in-repo-corpus.json"
COMPUTE_INTEGRITY_CORPUS="$W/in-repo-corpus.json" PEARL_RUNTIME_TASK=compute-integrity-enable run_rc 0 "corpus inside the repo" scripts/ops/pearl-runtime.sh status
expect_next corpus:blocked
case "$(next_field reason)" in *"inside the repository"*) ok ;; *) bad "in-repo corpus reason: $(next_field reason)" ;; esac
rm -f "$W/in-repo-corpus.json"
printf '{"version": "v", "prompts": [{"system": "SECRET-PROMPT-TEXT", "user": " "}]}' > "$CI_SECRETS/bad.json"
chmod 600 "$CI_SECRETS/bad.json"
COMPUTE_INTEGRITY_CORPUS="$CI_SECRETS/bad.json" PEARL_RUNTIME_TASK=compute-integrity-enable run_rc 0 "invalid corpus" scripts/ops/pearl-runtime.sh status
expect_next corpus:blocked
case "$(next_field reason)" in *"corpus rules"*"empty message"*) ok ;; *) bad "invalid corpus reason: $(next_field reason)" ;; esac
if grep -q SECRET-PROMPT-TEXT "$tmp/out" "$tmp/err"; then bad "corpus content echoed"; else ok; fi
cp "$CORPUS1" "$CI_SECRETS/open.json"; chmod 644 "$CI_SECRETS/open.json"
COMPUTE_INTEGRITY_CORPUS="$CI_SECRETS/open.json" PEARL_RUNTIME_TASK=compute-integrity-enable run_rc 0 "world-readable corpus" scripts/ops/pearl-runtime.sh status
expect_next corpus:blocked
chmod 400 "$CI_SECRETS/open.json"
COMPUTE_INTEGRITY_CORPUS="$CI_SECRETS/open.json" PEARL_RUNTIME_TASK=compute-integrity-enable run_rc 0 "corpus not exactly 0600" scripts/ops/pearl-runtime.sh status
expect_next corpus:blocked
export COMPUTE_INTEGRITY_CORPUS="$CORPUS1"
SHA1="$(shasum -a 256 "$CORPUS1" | awk '{print $1}')"
# The kill switch is never overridden.
printf 'compute_integrity:\n  scoring:\n    enabled: false\n' >> "$tmp/pearl/coordinator.yaml"
PEARL_RUNTIME_TASK=compute-integrity-enable run_rc 0 "compute-integrity status with the kill switch" scripts/ops/pearl-runtime.sh status
expect_next pearl_state:blocked
printf 'listen:\n  bind_address: 127.0.0.1\n' > "$tmp/pearl/coordinator.yaml"
systemctl restart macprovider-coordinator
PEARL_RUNTIME_TASK=compute-integrity-enable run_rc 0 "compute-integrity status" scripts/ops/pearl-runtime.sh status
expect_next enable:mutate
case "$(next_field command)" in "scripts/ops/pearl-runtime.sh _compute-integrity-enable $SHA1") ok ;; *) bad "enable command: $(next_field command)" ;; esac
case "$(next_field expected_downtime)" in "one coordinator restart"*) ok ;; *) bad "enable downtime: $(next_field expected_downtime)" ;; esac
case "$(next_field runbook)" in docs/runbooks/compute-integrity-private-corpus.md) ok ;; *) bad "enable runbook: $(next_field runbook)" ;; esac
if [ -f "$SRC_REPO/docs/runbooks/compute-integrity-private-corpus.md" ]; then ok; else bad "the enable runbook does not exist"; fi
run_rc 3 "_compute-integrity-enable refuses outside next --run" scripts/ops/pearl-runtime.sh _compute-integrity-enable "$SHA1"
PEARL_RUNTIME_TASK=compute-integrity-enable run_rc 3 "enable needs an owner" scripts/ops/pearl-runtime.sh next --run
# The coordinator rejects the corpus after the restart: overlay and corpus are
# restored and it restarts again.
cp "$tmp/pearl/overlay.yaml" "$tmp/pearl/overlay.before"
: > "$tmp/svc/ci_corpus_invalid"; rm -f "$tmp/svc/restarts"
PEARL_RUNTIME_TASK=compute-integrity-enable MACPROVIDER_OPS_OWNER=t run_rc 3 "enable rolled back when the coordinator rejects the corpus" scripts/ops/pearl-runtime.sh next --run
expect_err "compute_integrity_corpus_invalid"
expect_lock_free
if cmp -s "$tmp/pearl/overlay.yaml" "$tmp/pearl/overlay.before" && [ ! -e "$PEARL_COMPUTE_INTEGRITY_CORPUS_PATH" ] && [ "$(restarts)" = 2 ]; then ok; else bad "rejected corpus not rolled back (restarts=$(restarts))"; fi
if [ -e "$CI_STAGED" ]; then bad "staged corpus left behind"; else ok; fi
rm -f "$tmp/svc/ci_corpus_invalid" "$tmp/svc/restarts"
PEARL_RUNTIME_TASK=compute-integrity-enable MACPROVIDER_OPS_OWNER=t run_rc 0 "enable runs" scripts/ops/pearl-runtime.sh next --run
expect_lock_free
if grep -q "EXPECTED DOWNTIME for enable: one coordinator restart" "$tmp/out"; then ok; else bad "enable downtime not printed first"; fi
if [ "$(restarts)" = 1 ]; then ok; else bad "enable restarts: $(restarts)"; fi
if [ "$(shasum -a 256 "$PEARL_COMPUTE_INTEGRITY_CORPUS_PATH" | awk '{print $1}')" = "$SHA1" ] &&
  [ "$(ls -l "$PEARL_COMPUTE_INTEGRITY_CORPUS_PATH" | cut -c1-10)" = "-rw-r-----" ]; then ok; else bad "corpus not installed 0640: $(ls -l "$PEARL_COMPUTE_INTEGRITY_CORPUS_PATH" 2>&1)"; fi
if python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); sys.exit(0 if d == {"relay_blind": {"enabled": True}, "compute_integrity": {"scoring": {"corpus_path": sys.argv[2]}}} else 1)' \
  "$tmp/pearl/overlay.yaml" "$PEARL_COMPUTE_INTEGRITY_CORPUS_PATH"; then ok; else bad "overlay edit: $(cat "$tmp/pearl/overlay.yaml")"; fi
if find "$PEARL_BACKUP_ROOT" -path '*compute-integrity*' -name overlay.yaml | grep -q .; then ok; else bad "no overlay backup"; fi
if [ -e "$CI_STAGED" ]; then bad "staged corpus left behind"; else ok; fi
if grep -q "private topic" "$tmp/out" "$tmp/err"; then bad "enable printed corpus content"; else ok; fi
PEARL_RUNTIME_TASK=compute-integrity-enable run_rc 0 "compute-integrity status after enable" scripts/ops/pearl-runtime.sh status
expect_next done:done
if [ "$(state_of scheduled)" = done ]; then ok; else bad "scheduled state: $(state_of scheduled)"; fi
if [ "$(fact_of pearl_ci_loaded_matches_installed)" = True ] && [ "$(fact_of pearl_ci_installed_mode_ok)" = True ]; then ok; else bad "loaded/mode facts after enable"; fi
PEARL_COORDINATOR_HEALTHZ_URL="http://10.0.0.1:8444/healthz" PEARL_RUNTIME_TASK=compute-integrity-enable run_rc 3 "non-loopback healthz refused" scripts/ops/pearl-runtime.sh status
# Without a local corpus the live state still reads as done.
COMPUTE_INTEGRITY_CORPUS= PEARL_RUNTIME_TASK=compute-integrity-enable run_rc 0 "compute-integrity status on another machine" scripts/ops/pearl-runtime.sh status
expect_next done:done
# A local corpus that is set but invalid is never hidden behind done.
COMPUTE_INTEGRITY_CORPUS="$CI_SECRETS/bad.json" PEARL_RUNTIME_TASK=compute-integrity-enable run_rc 0 "invalid local corpus after enable" scripts/ops/pearl-runtime.sh status
expect_next corpus:blocked
# A corpus replaced on Pearl after the coordinator started is not what it loaded.
cp "$PEARL_COMPUTE_INTEGRITY_CORPUS_PATH" "$tmp/pearl/corpus.keep"
cp "$CORPUS2" "$PEARL_COMPUTE_INTEGRITY_CORPUS_PATH"
COMPUTE_INTEGRITY_CORPUS= PEARL_RUNTIME_TASK=compute-integrity-enable run_rc 0 "corpus replaced behind the running coordinator" scripts/ops/pearl-runtime.sh status
case "$(next_field id)" in done) bad "a corpus the coordinator did not load reads as done" ;; *) ok ;; esac
cp "$tmp/pearl/corpus.keep" "$PEARL_COMPUTE_INTEGRITY_CORPUS_PATH"; chmod 640 "$PEARL_COMPUTE_INTEGRITY_CORPUS_PATH"; rm -f "$tmp/pearl/corpus.keep"
# A new local corpus replaces the installed one; a corpus changed after status is refused.
COMPUTE_INTEGRITY_CORPUS="$CORPUS2" PEARL_RUNTIME_TASK=compute-integrity-enable run_rc 0 "compute-integrity status with a new corpus" scripts/ops/pearl-runtime.sh status
expect_next enable:mutate
COMPUTE_INTEGRITY_CORPUS="$CORPUS2" MACPROVIDER_OPS_ENTRYPOINT=1 run_rc 3 "corpus changed after status refused" scripts/ops/pearl-runtime.sh _compute-integrity-enable "$SHA1"
expect_err "changed since status"
rm -f "$tmp/svc/restarts"
COMPUTE_INTEGRITY_CORPUS="$CORPUS2" PEARL_RUNTIME_TASK=compute-integrity-enable MACPROVIDER_OPS_OWNER=t run_rc 0 "corpus replacement runs" scripts/ops/pearl-runtime.sh next --run
if [ "$(shasum -a 256 "$PEARL_COMPUTE_INTEGRITY_CORPUS_PATH" | awk '{print $1}')" = "$(shasum -a 256 "$CORPUS2" | awk '{print $1}')" ] && [ "$(restarts)" = 1 ]; then ok; else bad "corpus not replaced with one restart"; fi
if [ "$(grep -c compute_integrity "$tmp/pearl/overlay.yaml")" = 1 ]; then ok; else bad "overlay edited twice: $(cat "$tmp/pearl/overlay.yaml")"; fi
COMPUTE_INTEGRITY_CORPUS="$CORPUS2" PEARL_RUNTIME_TASK=compute-integrity-enable run_rc 0 "compute-integrity status after the replacement" scripts/ops/pearl-runtime.sh status
expect_next done:done
# Permission drift on the installed corpus is not done.
chmod 644 "$PEARL_COMPUTE_INTEGRITY_CORPUS_PATH"
COMPUTE_INTEGRITY_CORPUS="$CORPUS2" PEARL_RUNTIME_TASK=compute-integrity-enable run_rc 0 "installed corpus with drifted mode" scripts/ops/pearl-runtime.sh status
case "$(next_field id)" in done) bad "a drifted corpus mode reads as done" ;; *) ok ;; esac
if [ "$(fact_of pearl_ci_installed_mode_ok)" = False ]; then ok; else bad "mode drift not reported: $(fact_of pearl_ci_installed_mode_ok)"; fi
chmod 640 "$PEARL_COMPUTE_INTEGRITY_CORPUS_PATH"
unset COMPUTE_INTEGRITY_CORPUS PEARL_COMPUTE_INTEGRITY_CORPUS_PATH
rm -f "$tmp/svc/restarts" "$tmp/pearl/coordinator.yaml" "$tmp/pearl/overlay.yaml" "$tmp/pearl/overlay.before" "$tmp/pearl/etc/compute-integrity-corpus.json"

# ==== native-vision qualification (#2016) ====================================
# The record names a provider: it stays outside the repo, private, and only
# its entry digest is ever printed.
VQ_SECRETS="$tmp/operator-secrets/vision"
mkdir -p "$VQ_SECRETS"
vq_record() { # OUT [field=json-value ...]
  python3 -I - "$@" <<'PYVQ'
import json, os, sys
d = {"provider_id": "VQ-SECRET-PROVIDER", "binary_version": "1.8.250", "hardware_chip": "Apple M2 Ultra",
     "ram_gb": 192, "max_context_tokens": 8192, "max_concurrency": 1,
     "model_id": "mlx-community/Qwen2-VL-2B-Instruct-4bit", "model_hash": "a" * 64,
     "model_hash_algorithm": "macprovider.snapshot-manifest.v1", "weights_manifest_sha256": "b" * 64,
     "processor_digest": "c" * 64, "runtime": "mlx_cache", "runtime_revision": "d" * 40,
     "media_profile": "qwen2vl-inline-v1", "qualification_digest": "e" * 64}
for kv in sys.argv[2:]:
    k, v = kv.split("=", 1)
    if v == "DELETE":
        del d[k]
    else:
        d[k] = json.loads(v)
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, json.dumps(d, indent=1).encode())
os.close(fd)
PYVQ
}
expect_no_secret() { if grep -q VQ-SECRET-PROVIDER "$tmp/out" "$tmp/err"; then bad "$1 printed the provider id"; else ok; fi; }
# boot_matches_disk: the fake coordinator's last boot logged the files on disk.
boot_matches_disk() {
  python3 -I - "$tmp/svc/boot.txt" "$tmp/pearl/coordinator.yaml" "$tmp/pearl/overlay.yaml" <<'PYB'
import hashlib, json, sys
boot = json.loads(open(sys.argv[1]).readline())
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
sys.exit(0 if (boot["config_sha256"], boot["overlay_sha256"]) == (sha(sys.argv[2]), sha(sys.argv[3])) else 1)
PYB
}
healthz_hits() { wc -l < "$tmp/svc/healthz_hits" 2>/dev/null | tr -d ' ' || echo 0; }
printf 'listen:\n  bind_address: 127.0.0.1\n' > "$tmp/pearl/coordinator.yaml"
# The overlay already carries a routing mapping; its keys must survive.
printf 'relay_blind:\n  enabled: true\nrouting:\n  sticky_enabled: true\n' > "$tmp/pearl/overlay.yaml"
systemctl restart macprovider-coordinator
rm -f "$tmp/svc/restarts"
VQ_STAGED="$tmp/pearl/.vision-qualification.staging"
PEARL_RUNTIME_TASK=vision-qualification run_rc 0 "vision status without a record" scripts/ops/pearl-runtime.sh status
expect_next record:blocked
if [ "$(state_of vision_qualification)" = pending ]; then ok; else bad "vision_qualification state: $(state_of vision_qualification)"; fi
if [ "$(fact_of pearl_vq_overlay_entries_sha256)" = absent ] && [ "$(fact_of pearl_vq_overlay_sets_routing)" = True ]; then ok; else bad "overlay facts: $(fact_of pearl_vq_overlay_entries_sha256) $(fact_of pearl_vq_overlay_sets_routing)"; fi
vq_record "$W/in-repo-vq.json"
VISION_QUALIFICATION_FILE="$W/in-repo-vq.json" PEARL_RUNTIME_TASK=vision-qualification run_rc 0 "vision record inside the repo" scripts/ops/pearl-runtime.sh status
expect_next record:blocked
case "$(next_field reason)" in *"inside the repository"*) ok ;; *) bad "in-repo record reason: $(next_field reason)" ;; esac
rm -f "$W/in-repo-vq.json"
for c in "processor_digest=DELETE|missing: processor_digest" "qualification_digest=\"$(printf 'E%.0s' $(seq 64))\"|qualification_digest must be a lowercase sha256" \
  'model_id="mlx-community/Qwen2-VL-7B-Instruct-4bit"|model_id must be' 'ram_gb=0|ram_gb must be a positive integer'; do
  vq_record "$VQ_SECRETS/bad.json" "${c%%|*}"
  VISION_QUALIFICATION_FILE="$VQ_SECRETS/bad.json" PEARL_RUNTIME_TASK=vision-qualification run_rc 0 "vision record ${c%%=*}" scripts/ops/pearl-runtime.sh status
  expect_next record:blocked
  case "$(next_field reason)" in *"${c#*|}"*) ok ;; *) bad "bad record reason: $(next_field reason)" ;; esac
  expect_no_secret "a refused record"
done
vq_record "$VQ_SECRETS/open.json"; chmod 644 "$VQ_SECRETS/open.json"
VISION_QUALIFICATION_FILE="$VQ_SECRETS/open.json" PEARL_RUNTIME_TASK=vision-qualification run_rc 0 "world-readable vision record" scripts/ops/pearl-runtime.sh status
expect_next record:blocked
case "$(next_field reason)" in *"must be mode 0600"*) ok ;; *) bad "world-readable record reason: $(next_field reason)" ;; esac
# The record is checked on the descriptor it is read from: no symlink, one
# link, a directory nobody else can write.
vq_record "$VQ_SECRETS/target.json"
ln -s "$VQ_SECRETS/target.json" "$VQ_SECRETS/link.json"
ln "$VQ_SECRETS/target.json" "$VQ_SECRETS/hard.json"
mkdir -p "$tmp/operator-secrets/shared"; chmod 775 "$tmp/operator-secrets/shared"; vq_record "$tmp/operator-secrets/shared/r.json"
# The symlink is passed to the helper as given: only the repository check
# sees the resolved path.
for c in "$VQ_SECRETS/link.json|is a symlink" "$VQ_SECRETS/hard.json|regular file with one link" \
  "$tmp/operator-secrets/shared/r.json|not writable by group or others"; do
  VISION_QUALIFICATION_FILE="${c%%|*}" PEARL_RUNTIME_TASK=vision-qualification run_rc 0 "vision record ${c#*|}" scripts/ops/pearl-runtime.sh status
  expect_next record:blocked
  case "$(next_field reason)" in *"${c#*|}"*) ok ;; *) bad "record file reason: $(next_field reason)" ;; esac
done
if python3 -I "$OPS_SRC/lib/pearl-cli-config.py" validate-vision-qualification "$VQ_SECRETS/link.json" >/dev/null 2>"$tmp/err"; then
  bad "a symlinked vision record was accepted"
else
  expect_err "is a symlink"
fi
rm -rf "$VQ_SECRETS/target.json" "$VQ_SECRETS/link.json" "$VQ_SECRETS/hard.json" "$tmp/operator-secrets/shared"
vq_record "$VQ_SECRETS/record.json"
export VISION_QUALIFICATION_FILE="$VQ_SECRETS/record.json"
VQSHA="$(python3 -I "$OPS_SRC/lib/pearl-cli-config.py" validate-vision-qualification "$VISION_QUALIFICATION_FILE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["entry_sha256"])')"
PEARL_RUNTIME_TASK=vision-qualification run_rc 0 "vision status" scripts/ops/pearl-runtime.sh status
expect_next vision_qualification:mutate
case "$(next_field command)" in "scripts/ops/pearl-runtime.sh _vision-qualification $VQSHA") ok ;; *) bad "vision command: $(next_field command)" ;; esac
case "$(next_field expected_downtime)" in "one coordinator restart"*) ok ;; *) bad "vision downtime: $(next_field expected_downtime)" ;; esac
case "$(next_field runbook)" in docs/runbooks/native-vision-acceptance.md) ok ;; *) bad "vision runbook: $(next_field runbook)" ;; esac
if [ "$(fact_of local_entry_sha256)" = "$VQSHA" ]; then ok; else bad "local entry digest: $(fact_of local_entry_sha256)"; fi
expect_no_secret "vision status"
PEARL_RUNTIME_TASK=vision-qualification run_rc 0 "vision next" scripts/ops/pearl-runtime.sh next
if grep -q "EXPECTED DOWNTIME: one coordinator restart" "$tmp/out"; then ok; else bad "vision next lacks the downtime"; fi
run_rc 3 "_vision-qualification refuses outside next --run" scripts/ops/pearl-runtime.sh _vision-qualification "$VQSHA"
PEARL_RUNTIME_TASK=vision-qualification run_rc 3 "vision install needs an owner" scripts/ops/pearl-runtime.sh next --run
cp "$tmp/pearl/overlay.yaml" "$tmp/pearl/overlay.before"
# The running coordinator binary rejects the result: nothing changes, no restart.
printf '# INVALID\n' >> "$tmp/pearl/coordinator.yaml"
PEARL_RUNTIME_TASK=vision-qualification MACPROVIDER_OPS_OWNER=t run_rc 3 "vision install refused by --validate-config" scripts/ops/pearl-runtime.sh next --run
expect_err "rejects the edited overlay"
expect_lock_free
if cmp -s "$tmp/pearl/overlay.yaml" "$tmp/pearl/overlay.before" && [ "$(restarts)" = 0 ] && [ ! -e "$VQ_STAGED" ]; then ok; else bad "rejected vision overlay not left alone (restarts=$(restarts))"; fi
printf 'listen:\n  bind_address: 127.0.0.1\n' > "$tmp/pearl/coordinator.yaml"
# A failed restart puts the overlay back, then one recovery restart must
# answer /healthz and boot with the restored files.
systemctl restart macprovider-coordinator
rm -f "$tmp/svc/restarts"
hits="$(healthz_hits)"
: > "$tmp/svc/restart_fail_once"
PEARL_RUNTIME_TASK=vision-qualification MACPROVIDER_OPS_OWNER=t run_rc 3 "vision install rolled back when the restart fails" scripts/ops/pearl-runtime.sh next --run
expect_err "the original overlay is restored (bytes verified) and a recovery restart brought the coordinator back on it"
expect_lock_free
if cmp -s "$tmp/pearl/overlay.yaml" "$tmp/pearl/overlay.before" && [ ! -e "$VQ_STAGED" ]; then ok; else bad "vision overlay not restored: $(cat "$tmp/pearl/overlay.yaml")"; fi
if [ "$(restarts)" = 1 ] && [ ! -e "$tmp/svc/restart_fail_once" ]; then ok; else bad "vision rollback recovery restarts: $(restarts)"; fi
if [ "$(healthz_hits)" -gt "$hits" ]; then ok; else bad "vision rollback recovery did not check /healthz"; fi
if boot_matches_disk; then ok; else bad "vision rollback recovery did not boot the restored overlay"; fi
# The recovery restart fails too: the restored overlay is reported unproven.
: > "$tmp/svc/restart_fail"
PEARL_RUNTIME_TASK=vision-qualification MACPROVIDER_OPS_OWNER=t run_rc 3 "vision install when both restarts fail" scripts/ops/pearl-runtime.sh next --run
expect_err "the recovery restart failed; the original overlay is restored on disk (bytes verified) but the coordinator is not proven live"
if cmp -s "$tmp/pearl/overlay.yaml" "$tmp/pearl/overlay.before" && [ ! -e "$VQ_STAGED" ]; then ok; else bad "vision overlay not restored: $(cat "$tmp/pearl/overlay.yaml")"; fi
rm -f "$tmp/svc/restart_fail"
systemctl restart macprovider-coordinator
rm -f "$tmp/svc/restarts"
PEARL_RUNTIME_TASK=vision-qualification MACPROVIDER_OPS_OWNER=t run_rc 0 "vision install runs" scripts/ops/pearl-runtime.sh next --run
expect_lock_free
if grep -q "EXPECTED DOWNTIME for vision_qualification: one coordinator restart" "$tmp/out"; then ok; else bad "vision downtime not printed first"; fi
if [ "$(restarts)" = 1 ]; then ok; else bad "vision restarts: $(restarts)"; fi
if python3 -c 'import json,sys,yaml
d=yaml.safe_load(open(sys.argv[1])); e=json.load(open(sys.argv[2]))
sys.exit(0 if d == {"relay_blind": {"enabled": True}, "routing": {"sticky_enabled": True, "vision_qualifications": [e]}} else 1)' \
  "$tmp/pearl/overlay.yaml" "$VISION_QUALIFICATION_FILE"; then ok; else bad "vision overlay edit: $(cat "$tmp/pearl/overlay.yaml")"; fi
if find "$PEARL_BACKUP_ROOT" -path '*vision-qualification*' -name overlay.yaml | grep -q .; then ok; else bad "no vision overlay backup"; fi
if [ -e "$VQ_STAGED" ]; then bad "staged vision record left behind"; else ok; fi
expect_no_secret "vision install"
PEARL_RUNTIME_TASK=vision-qualification run_rc 0 "vision status after install" scripts/ops/pearl-runtime.sh status
expect_next done:done
if [ "$(state_of vision_qualification)" = "done" ] && [ "$(fact_of pearl_vq_overlay_entries_sha256)" = "$VQSHA" ]; then ok; else bad "vision done state: $(state_of vision_qualification)"; fi
VISION_QUALIFICATION_FILE='' PEARL_RUNTIME_TASK=vision-qualification run_rc 0 "vision status on another machine" scripts/ops/pearl-runtime.sh status
expect_next done:done
rm -f "$tmp/svc/restarts"
PEARL_RUNTIME_TASK=vision-qualification MACPROVIDER_OPS_OWNER=t run_rc 0 "vision install is a no-op once live" scripts/ops/pearl-runtime.sh next --run
if [ "$(restarts)" = 0 ]; then ok; else bad "a live vision qualification restarted again"; fi
# The overlay holds the entry but the coordinator did not boot with it: one
# validated restart, no second edit.
printf '# edited after boot\n' >> "$tmp/pearl/coordinator.yaml"
PEARL_RUNTIME_TASK=vision-qualification run_rc 0 "vision entry present, not booted" scripts/ops/pearl-runtime.sh status
expect_next vision_qualification:mutate
PEARL_RUNTIME_TASK=vision-qualification MACPROVIDER_OPS_OWNER=t run_rc 0 "vision restart for an unapplied overlay" scripts/ops/pearl-runtime.sh next --run
if [ "$(restarts)" = 1 ] && [ "$(grep -c vision_qualifications "$tmp/pearl/overlay.yaml")" = 1 ]; then ok; else bad "unapplied vision overlay: restarts=$(restarts)"; fi
PEARL_RUNTIME_TASK=vision-qualification run_rc 0 "vision status after the recovery restart" scripts/ops/pearl-runtime.sh status
expect_next done:done
# Same, but that restart fails: nothing to restore, one recovery restart that
# must answer /healthz and boot with the unchanged files.
printf '# edited after boot again\n' >> "$tmp/pearl/coordinator.yaml"
cp "$tmp/pearl/overlay.yaml" "$tmp/pearl/overlay.before"
rm -f "$tmp/svc/restarts"
hits="$(healthz_hits)"
: > "$tmp/svc/restart_fail_once"
PEARL_RUNTIME_TASK=vision-qualification MACPROVIDER_OPS_OWNER=t run_rc 3 "vision unapplied-overlay restart fails" scripts/ops/pearl-runtime.sh next --run
expect_err "a recovery restart brought the coordinator back on the unchanged overlay"
expect_lock_free
if cmp -s "$tmp/pearl/overlay.yaml" "$tmp/pearl/overlay.before" && [ ! -e "$VQ_STAGED" ]; then ok; else bad "unapplied vision overlay changed"; fi
if [ "$(restarts)" = 1 ]; then ok; else bad "unapplied vision recovery restarts: $(restarts)"; fi
if [ "$(healthz_hits)" -gt "$hits" ]; then ok; else bad "unapplied vision recovery did not check /healthz"; fi
if boot_matches_disk; then ok; else bad "unapplied vision recovery did not boot the on-disk files"; fi
PEARL_RUNTIME_TASK=vision-qualification run_rc 0 "vision status after a recovered restart failure" scripts/ops/pearl-runtime.sh status
expect_next done:done
printf '# edited after boot a third time\n' >> "$tmp/pearl/coordinator.yaml"
: > "$tmp/svc/restart_fail"
PEARL_RUNTIME_TASK=vision-qualification MACPROVIDER_OPS_OWNER=t run_rc 3 "vision unapplied-overlay restarts both fail" scripts/ops/pearl-runtime.sh next --run
expect_err "the recovery restart failed; the overlay is unchanged on disk but the coordinator is not proven live"
rm -f "$tmp/svc/restart_fail"
systemctl restart macprovider-coordinator
# A different record never replaces the installed one.
vq_record "$VQ_SECRETS/other.json" 'provider_id="VQ-SECRET-OTHER"'
VISION_QUALIFICATION_FILE="$VQ_SECRETS/other.json" PEARL_RUNTIME_TASK=vision-qualification run_rc 0 "different vision record" scripts/ops/pearl-runtime.sh status
expect_next vision_qualification:blocked
case "$(next_field reason)" in *"different routing.vision_qualifications"*) ok ;; *) bad "different record reason: $(next_field reason)" ;; esac
# A live overlay entry the record rules reject (the coordinator would accept
# a non-hex model_hash) is blocked, never done, with or without a local record.
python3 -I - "$VISION_QUALIFICATION_FILE" "$tmp/pearl/overlay.yaml" <<'PYM'
import json, sys, yaml
e = json.load(open(sys.argv[1]))
e["model_hash"] = "z" * 64
yaml.safe_dump({"routing": {"vision_qualifications": [e]}}, open(sys.argv[2], "w"))
PYM
systemctl restart macprovider-coordinator
for f in "$VISION_QUALIFICATION_FILE" ''; do
  VISION_QUALIFICATION_FILE="$f" PEARL_RUNTIME_TASK=vision-qualification run_rc 0 "invalid live vision entry (record: ${f:+set}${f:-unset})" scripts/ops/pearl-runtime.sh status
  expect_next vision_qualification:blocked
  case "$(next_field reason)" in *"model_hash must be a lowercase sha256"*) ok ;; *) bad "invalid live entry reason: $(next_field reason)" ;; esac
  if [ "$(state_of vision_qualification)" = blocked ] && [ "$(fact_of pearl_vq_overlay_entries_valid)" = False ] &&
    [ "$(fact_of pearl_vq_overlay_entries_sha256)" = invalid ]; then ok; else
    bad "invalid live entry state: $(state_of vision_qualification) $(fact_of pearl_vq_overlay_entries_valid) $(fact_of pearl_vq_overlay_entries_sha256)"; fi
  expect_no_secret "an invalid live entry"
done
unset VISION_QUALIFICATION_FILE
rm -f "$tmp/svc/restarts" "$tmp/pearl/coordinator.yaml" "$tmp/pearl/overlay.yaml" "$tmp/pearl/overlay.before"

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
printf '{"step":"signed_byte_verification","run_id":"111","candidate_sha":"%s","checksums_sha256":"%s","compatibility_set_id":"test/repo:v'"$CAND"'@%s","bytes_dir":"%s","binary_sha256":"%s"}\n' \
  "$B" "$(printf 'ab%.0s' $(seq 32))" "$B" "$tmp/bytes" "$(printf 'cd%.0s' $(seq 32))" > "$SCOPE/signed_byte_verification.json"
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
  printf '{"binary_version":"%s","provider_id":"canary-test-id","safety_telemetry":{"coordinator_session_id":"canary-test-session"},"compatibility_set_id":"test/repo:v'"$CAND"'@%s","coordinator":{"connected":%s},"native_mtp":{"mtp_forwards":5},"requests_total":7,"continuous_batching":{"active":%s,"paged_kv_decision":"%s","self_check":%s,"policy":{"load_status":"%s","authorized":%s,"local_proof_result":"%s","emergency_off_override":false},"scheduler":{"shared_forward_calls":11}}}'     "$version" "$B" "$connected" "$cb_active" "$cb_paged" "$cb_self_check" "$cb_load" "$cb_authorized" "$cb_proof" > "$tmp/svc/status.json"
}

run_rc 0 "cli status" scripts/ops/cli-release.sh status
expect_next canary_smoke:manual
run_rc 3 "free-text canary evidence refused" scripts/ops/cli-release.sh next --done canary_smoke --evidence "looked fine"
expect_err "does not accept free-text"
status_doc $CAND true
run_rc 3 "canary probe refused without a canary-swap.sh record" scripts/ops/cli-release.sh next --done canary_smoke --probe
expect_err "no canary_swap record"
printf '{"step":"canary_swap","binary_sha256":"%s"}\n' "$(printf 'cd%.0s' $(seq 32))" > "$SCOPE/canary_swap.json"
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
status_doc $CAND true false false live_verified failed attached '{"decision":"single_row","served_slots":1}'
run_rc 3 "single-row canary with a failed local proof" scripts/ops/cli-release.sh next --done canary_smoke --probe
expect_err "local_proof_result 'failed' != 'passed'"
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
printf 'canary-test-session' > "$tmp/svc/assigned_id"
sqlite3 "$tmp/svc/request_log.db" "CREATE TABLE request_log (id INTEGER PRIMARY KEY, external_request_id TEXT, provider_assigned_id TEXT);"
export PEARL_COORDINATOR_DB="$tmp/svc/request_log.db" PEARL_SQLITE3="$(command -v sqlite3)"
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
run_rc 0 "mirror latest.json lags, key set, host unset" scripts/ops/cli-release.sh status
expect_next mirror_latest:blocked
expect_err_or_reason "MALIBU_DOWNLOAD_VPS_HOST is unset"
export MALIBU_DOWNLOAD_VPS_HOST="mirror.invalid"
run_rc 0 "mirror latest.json lags, key and host set" scripts/ops/cli-release.sh status
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
unset MALIBU_DOWNLOAD_SSH_KEY MALIBU_DOWNLOAD_VPS_HOST

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
printf 'no-log-row' > "$tmp/svc/mode"
run_rc 1 "proof refused without a coordinator request_log row" scripts/ops/catalog-activate.sh _gateway-proof
expect_err "has no row for request"
printf 'other-provider' > "$tmp/svc/mode"
run_rc 1 "proof refused when another provider served it (counters still moved)" scripts/ops/catalog-activate.sh _gateway-proof
expect_err "served by another provider"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d.pop("safety_telemetry"); json.dump(d, open(p, "w"))' "$tmp/svc/status.json"
printf 'move' > "$tmp/svc/mode"
run_rc 3 "proof refused when the canary reports no coordinator session" scripts/ops/catalog-activate.sh _gateway-proof
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

# ==== catalog-activate: canary pause, pricing ack, owed evidence (e) ===========
MAIN_SHA="$(git -C "$W" rev-parse origin/main)"
CSCOPE="$tmp/state/catalog-$R"
mkdir -p "$tmp/svc/routes"
printf '{"schema_version":"macprovider.native-mtp-admission.v1"}' > "$tmp/svc/routes/v1_native-mtp-admission"
printf '{"expires_at":"2099-01-01T00:00:00Z"}' > "$tmp/svc/routes/v1_native-mtp-revocations.streamvc-autotune-static-v4.json"
rm -f "$tmp/svc/autotune-release.json"
# status_paused STATE: the canary status with lifecycle.state STATE.
status_paused() {
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["lifecycle"]={"state": sys.argv[2]}; d["network_state"]="live_verified"; json.dump(d, open(p, "w"))' "$tmp/svc/status.json" "$1"
}
# verdict GO PRICING_DIGEST FAILED_CHECK OWED_MODEL: a fresh preflight verdict.
verdict() {
  python3 - "$CSCOPE/preflight-$MAIN_SHA.json" "$@" <<'PY'
import json, sys
path, go, digest, failed, owed = sys.argv[1:6]
checks = [{"name": "content_gate", "ok": True, "detail": "lane catalog-content"}]
if failed:
    checks.append({"name": failed, "ok": False, "detail": "canary custody proof on the live release failed: network_state=live_verified (want buyer_serving), the provider is operator-paused"})
    checks.append({"name": "coordinator_dry_load", "ok": False, "detail": "not run: an earlier check failed"})
json.dump({"go": go == "true", "checks": checks,
           "pricing": {"pricing_diff_sha256": digest} if digest else None,
           "buyer_serving_e2e_owed": [{"model_id": owed, "sha256": "abab"}] if owed else []},
          open(path, "w"), sort_keys=True)
PY
}
mkdir -p "$CSCOPE"
status_doc $CAND true
status_paused paused_by_operator
rm -f "$CSCOPE"/preflight-*.json
run_rc 0 "catalog status with the canary operator-paused" scripts/ops/catalog-activate.sh status
if [ "$(fact_of provider_lifecycle_state)" = paused_by_operator ]; then ok; else bad "lifecycle fact: $(fact_of provider_lifecycle_state)"; fi
case "$(next_field id):$(next_field kind)" in
  catalog_preflight:blocked) case "$(next_field reason)" in *operator-paused*) ok ;; *) bad "paused preflight reason: $(next_field reason)" ;; esac ;;
  catalog_verify:*) ok ;;  # the fixture's catalog does not verify here; the pause is checked below
  *) bad "paused preflight next: $(next_field id):$(next_field kind)" ;;
esac
verdict false "" canary_reachable ""
run_rc 0 "catalog status with a NO_GO verdict while paused" scripts/ops/catalog-activate.sh status
case "$(fact_of preflight_failed_checks)" in
  "canary_reachable: canary custody proof"*) ok ;;
  *) bad "failed checks fact: $(fact_of preflight_failed_checks)" ;;
esac
case "$(fact_of preflight_failed_checks)" in *"not run:"*) bad "not-run checks listed as failures" ;; *) ok ;; esac
verdict true "" "" ""
run_rc 0 "catalog status with a GO verdict while paused" scripts/ops/catalog-activate.sh status
if [ "$(state_of catalog_activation)" = pending ]; then ok; else bad "activation state while paused: $(state_of catalog_activation)"; fi
if [ "$(next_field id)" = catalog_activation ]; then
  case "$(next_field kind):$(next_field reason)" in blocked:*operator-paused*) ok ;; *) bad "paused activation: $(next_field kind) $(next_field reason)" ;; esac
fi
printf '{}' > "$tmp/svc/status.json"
run_rc 0 "catalog status with the canary status unreadable" scripts/ops/catalog-activate.sh status
if [ "$(next_field id)" = catalog_activation ]; then
  case "$(next_field kind):$(next_field reason)" in blocked:*"status is unreadable"*) ok ;; *) bad "unreadable status activation: $(next_field kind) $(next_field reason)" ;; esac
fi
status_doc $CAND true
DIGEST="$(printf 'cd%.0s' $(seq 1 32))"
verdict true "$DIGEST" "" "mlx-community/Test-VL-2B"
run_rc 0 "catalog status with a pricing GO verdict, no ack" scripts/ops/catalog-activate.sh status
case "$(python3 -c 'import json,sys; print(next(s["note"] for s in json.load(open(sys.argv[1]))["steps"] if s["id"] == "catalog_activation"))' "$tmp/out")" in
  *"owed after activation: mlx-community/Test-VL-2B"*) ok ;;
  *) bad "activation note lacks the owed model" ;;
esac
if [ "$(next_field id)" = catalog_activation ]; then
  case "$(next_field kind):$(next_field reason)" in blocked:*"CATALOG_PRICING_ACK=$DIGEST"*) ok ;; *) bad "unacknowledged pricing: $(next_field kind) $(next_field reason)" ;; esac
  CATALOG_PRICING_ACK="$DIGEST" run_rc 0 "catalog status with the price table acknowledged" scripts/ops/catalog-activate.sh status
  expect_next catalog_activation:mutate
  case "$(next_field command)" in *"--pricing-diff-sha256 $DIGEST --preflight-verdict"*"| tee "*catalog-owed-e2e*) ok ;; *) bad "pricing activation command: $(next_field command)" ;; esac
  case "$(next_field expected_downtime)" in "no coordinator restart"*) ok ;; *) bad "activation downtime: $(next_field expected_downtime)" ;; esac
  CATALOG_PRICING_ACK="$(printf 'ef%.0s' $(seq 1 32))" run_rc 0 "catalog status with a stale acknowledgement" scripts/ops/catalog-activate.sh status
  expect_next catalog_activation:blocked
else
  bad "pricing activation not offered: next is $(next_field id) ($(next_field reason))"
fi
verdict true '$(touch /tmp/pwn)' "" ""
run_rc 0 "catalog status with a non-sha256 pricing digest" scripts/ops/catalog-activate.sh status
if [ "$(next_field id)" = catalog_activation ]; then
  case "$(next_field kind):$(next_field reason)" in blocked:*"pricing_diff_sha256 is not a sha256"*) ok ;; *) bad "bad digest: $(next_field kind) $(next_field reason)" ;; esac
  case "$(next_field command)" in *pwn*) bad "bad digest reached the command" ;; *) ok ;; esac
fi
verdict true "$DIGEST" "" "mlx-community/Test-VL-2B"
# The activation command records the owed (e) from the deploy's own verdict line.
cmd="$(CATALOG_PRICING_ACK="$DIGEST" bash -c 'cd "$1" && scripts/ops/catalog-activate.sh status' _ "$W" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["next"]["command"])')"
mkdir -p "$tmp/fakedeploy/scripts"
cat > "$tmp/fakedeploy/scripts/catalog-content-release.sh" <<'FAKEDEPLOY'
#!/usr/bin/env bash
echo "[catalog-content] deploy: preflight"
echo '{"buyer_serving_e2e_owed": [{"model_id": "mlx-community/Test-VL-2B", "sha256": "abab"}], "checks": [], "go": true, "pricing": null}'
echo "[catalog-content] DONE"
FAKEDEPLOY
chmod +x "$tmp/fakedeploy/scripts/catalog-content-release.sh"
OWED_DIR="$tmp/state/catalog-owed-e2e"
owed_count() { find "$OWED_DIR" -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
printf '#!/usr/bin/env bash\necho "{\\"buyer_serving_e2e_owed\\": [{\\"model_id\\": \\"x\\", \\"sha256\\": \\"y\\"}]}"\nexit 4\n' > "$tmp/fakedeploy/scripts/catalog-content-release.sh"
if (cd "$tmp/fakedeploy" && bash -euo pipefail -c "$cmd") >/dev/null 2>&1; then bad "a failed deploy passed the activation step"; else ok; fi
# Written before the deploy: a deploy that may have gone live and then failed
# locally still leaves the owed model open.
if [ "$(owed_count)" = 1 ]; then ok; else bad "the owed (e) was not written before the deploy: $(owed_count)"; fi
rm -rf "$OWED_DIR"
cat > "$tmp/fakedeploy/scripts/catalog-content-release.sh" <<'FAKEDEPLOY'
#!/usr/bin/env bash
echo "[catalog-content] deploy: preflight"
echo '{"buyer_serving_e2e_owed": [{"model_id": "mlx-community/Test-VL-2B", "sha256": "abab"}], "checks": [], "go": true, "pricing": null}'
echo "[catalog-content] DONE"
FAKEDEPLOY
if (cd "$tmp/fakedeploy" && bash -euo pipefail -c "$cmd") >/dev/null 2>&1 && [ "$(owed_count)" = 1 ] &&
  python3 -c 'import glob,json,sys; d=json.load(open(glob.glob(sys.argv[1] + "/*.json")[0])); sys.exit(0 if d["release_id"] == sys.argv[2] and d["model_id"] == "mlx-community/Test-VL-2B" else 1)' "$OWED_DIR" "$R"; then ok; else bad "activation command did not record the owed (e)"; fi
# The owed (e) is a post-activation, operator-recorded step that outlives its release.
printf '{"release_id":"%s","status":"live_verified","feeds":{"x":{"verified_at":"2026-01-01T00:00:00Z"}}}' "$R" > "$tmp/svc/autotune-release.json"
run_rc 0 "catalog status with (e) owed after activation" scripts/ops/catalog-activate.sh status
if [ "$(state_of buyer_serving_e2e)" = owed ]; then ok; else bad "owed (e) state: $(state_of buyer_serving_e2e)"; fi
case "$(fact_of buyer_serving_e2e_owed)" in "mlx-community/Test-VL-2B@abab (owed since $R)") ok ;; *) bad "owed (e) fact: $(fact_of buyer_serving_e2e_owed)" ;; esac
printf '{"release_id":"newer-release","status":"live_verified","feeds":{"x":{"verified_at":"2026-01-01T00:00:00Z"}}}' > "$tmp/svc/autotune-release.json"
run_rc 0 "catalog status with (e) owed by an older release" scripts/ops/catalog-activate.sh status
if [ "$(state_of buyer_serving_e2e)" = owed ]; then ok; else bad "an older release's owed (e) vanished: $(state_of buyer_serving_e2e)"; fi
printf '{not json' > "$OWED_DIR/broken.json"
run_rc 0 "catalog status with a malformed owed record" scripts/ops/catalog-activate.sh status
if [ "$(state_of buyer_serving_e2e)" = blocked ]; then ok; else bad "malformed owed record not blocked: $(state_of buyer_serving_e2e)"; fi
rm -f "$OWED_DIR/broken.json"
mkdir -p "$tmp/state/catalog-other"
# Free text or a longer model id never closes it: only the exact token.
printf '{"step":"buyer_serving_e2e","evidence":"mlx-community/Test-VL-2B-Pro: model=mlx-community/Test-VL-2B-Pro@abab request ops-e2e-0"}\n' > "$tmp/state/catalog-other/buyer_serving_e2e.json"
run_rc 0 "catalog status with evidence for another model" scripts/ops/catalog-activate.sh status
if [ "$(state_of buyer_serving_e2e)" = owed ]; then ok; else bad "a substring closed the owed (e): $(state_of buyer_serving_e2e)"; fi
printf '{"step":"buyer_serving_e2e","evidence":"model=mlx-community/Test-VL-2B@abab request ops-e2e-1 served by the canary session, settlement row at 13500/27000"}\n' > "$tmp/state/catalog-other/buyer_serving_e2e.json"
run_rc 0 "catalog status after the owed (e) is recorded" scripts/ops/catalog-activate.sh status
if [ "$(state_of buyer_serving_e2e)" != owed ] && [ "$(fact_of buyer_serving_e2e_owed)" = None ]; then ok; else bad "recorded owed (e) still open: $(state_of buyer_serving_e2e) $(fact_of buyer_serving_e2e_owed)"; fi
rm -rf "$tmp/svc/autotune-release.json" "$OWED_DIR" "$tmp/state/catalog-other" "$CSCOPE"/preflight-*.json

# ==== pearl-runtime updater-bundle ==============================================
UBROOT="$tmp/ubroot"
mkdir -p "$UBROOT"
: > "$tmp/pearl/updater.lock"; : > "$tmp/pearl/deploy.lock"
# shellcheck disable=SC2016  # the stub expands FAKE_FLOCK_RC itself
printf '#!/usr/bin/env bash\nexit "${FAKE_FLOCK_RC:-0}"\n' > "$tmp/bin/flock"
chmod +x "$tmp/bin/flock"
ub() { # run_rc args with the updater-bundle layout and the test-mode installer
  PEARL_RUNTIME_TASK=updater-bundle PEARL_DEPLOY_LOCK="$tmp/pearl/deploy.lock" \
    PEARL_UPDATER_BIN="$UBROOT/usr/local/sbin/macprovider-pearl-update" \
    PEARL_TIER2_WATCHDOG_BIN="$UBROOT/usr/local/sbin/macprovider-tier2-enforcement-watchdog" \
    PEARL_CONFIG_GUARD="$UBROOT/usr/local/share/macprovider/scripts/coordinator_config_guard.py" \
    MACPROVIDER_UPDATER_TESTING=1 MACPROVIDER_UPDATER_INSTALL_ROOT="$UBROOT" MACPROVIDER_UPDATER_SKIP_SYSTEMD=1 \
    MACPROVIDER_UPDATER_INSTALL_OWNER="$(id -un)" MACPROVIDER_UPDATER_INSTALL_ROOT_GROUP="$(id -gn)" \
    MACPROVIDER_UPDATER_INSTALL_GROUP="$(id -gn)" run_rc "$@"
}
# Root runs the archived tree: only origin's annotated tag, signed by an
# approved signer, on origin/main. v9.0.0 is annotated but unsigned.
health v9.0.0 $LIVE
ub 0 "updater-bundle status with an unsigned running tag" scripts/ops/pearl-runtime.sh status
expect_next bundle_source:blocked
case "$(next_field reason)" in *"not signed by an approved release signer"*) ok ;; *) bad "unsigned tag reason: $(next_field reason)" ;; esac
UBC="$(git -C "$W" rev-parse 'v9.0.0^{commit}')"
git -C "$W" tag -s -a v9.0.9 -m "signed live runtime" "$UBC"
ub 0 "updater-bundle status with a tag absent from origin" scripts/ops/pearl-runtime.sh status
expect_next bundle_source:blocked
git -C "$W" push -q origin refs/tags/v9.0.9
git -C "$W" -c user.signingkey="$tmp/keys/untrusted" tag -s -a v9.0.10 -m "untrusted signer" "$UBC"
git -C "$W" push -q origin refs/tags/v9.0.10
health v9.0.10 $LIVE
ub 0 "updater-bundle status with an untrusted signer" scripts/ops/pearl-runtime.sh status
expect_next bundle_source:blocked
health v9.0.9 $LIVE
ub 0 "updater-bundle status with nothing installed" scripts/ops/pearl-runtime.sh status
expect_next updater_bundle:mutate
if [ "$(fact_of updater_bundle_tag)" = v9.0.9 ]; then ok; else bad "bundle tag: $(fact_of updater_bundle_tag)"; fi
case "$(fact_of updater_bundle_mismatched)" in *macprovider-pearl-update=MISSING*) ok ;; *) bad "mismatch fact: $(fact_of updater_bundle_mismatched)" ;; esac
case "$(next_field expected_downtime)" in none:*) ok ;; *) bad "bundle downtime: $(next_field expected_downtime)" ;; esac
ub 3 "_updater-bundle refuses outside next --run" scripts/ops/pearl-runtime.sh _updater-bundle v9.0.9 "$UBC"
expect_err "runs only from"
staging_dirs() { find /var/tmp -maxdepth 1 -name 'macprovider-updater-bundle.*' 2>/dev/null | wc -l | tr -d ' '; }
before_dirs="$(staging_dirs)"
FAKE_FLOCK_RC=1 ub 1 "updater-bundle refuses while the updater lock is busy" env MACPROVIDER_OPS_OWNER=t scripts/ops/pearl-runtime.sh next --run
expect_err "lock busy"
expect_lock_free
if [ "$(staging_dirs)" = "$before_dirs" ]; then ok; else bad "staging dir left behind"; fi
if [ -e "$UBROOT/usr/local/sbin/macprovider-pearl-update" ]; then bad "installed while the lock was busy"; else ok; fi
rm -f "$tmp/pearl/deploy.lock"
ub 0 "updater-bundle installs from the running tag" env MACPROVIDER_OPS_OWNER=t scripts/ops/pearl-runtime.sh next --run
expect_lock_free
if [ -f "$tmp/pearl/deploy.lock" ] && [ ! -L "$tmp/pearl/deploy.lock" ]; then ok; else bad "first install did not create the missing deploy lock"; fi
if cmp -s "$UBROOT/usr/local/sbin/macprovider-pearl-update" <(git -C "$W" show v9.0.9:ops/pearl-updater/macprovider-pearl-update); then ok; else bad "installed updater is not the tag's bytes"; fi
ub 0 "updater-bundle status after the install" scripts/ops/pearl-runtime.sh status
expect_next done:done
printf '# drift\n' >> "$UBROOT/usr/local/sbin/macprovider-tier2-enforcement-watchdog"
ub 0 "updater-bundle status with a drifted watchdog" scripts/ops/pearl-runtime.sh status
expect_next updater_bundle:mutate
case "$(fact_of updater_bundle_mismatched)" in *tier2-enforcement-watchdog=*) ok ;; *) bad "drift fact: $(fact_of updater_bundle_mismatched)" ;; esac
# A signed tag off origin/main is refused, whatever its writers hold.
git -C "$W" checkout -q --detach "$UBC"
printf '\n# side-branch change\n' >> "$W/ops/pearl-updater/install-pearl-updater.sh"
git -C "$W" commit -q -am "test: side branch"
git -C "$W" tag -s -a v9.0.7 -m "side-branch runtime"
git -C "$W" push -q origin refs/tags/v9.0.7
git -C "$W" checkout -q main
health v9.0.7 $LIVE
ub 0 "updater-bundle status with a signed tag off origin/main" scripts/ops/pearl-runtime.sh status
expect_next bundle_source:blocked
case "$(next_field reason)" in *"is not on origin/main"*) ok ;; *) bad "off-main reason: $(next_field reason)" ;; esac
git -C "$W" tag v9.0.8 "$UBC"
git -C "$W" push -q origin refs/tags/v9.0.8
health v9.0.8 $LIVE
ub 0 "updater-bundle status with a lightweight running tag" scripts/ops/pearl-runtime.sh status
expect_next bundle_source:blocked
# origin/main changing a writer after the running tag: the preflight hashes
# origin/main, so the tag's bundle could never satisfy it.
printf '\n# main-only change\n' >> "$W/scripts/lib/coordinator_config_guard.py"
git -C "$W" commit -q -am "test: guard changes on main"
git -C "$W" push -q origin HEAD:refs/heads/main
git -C "$W" fetch -q origin
health v9.0.9 $LIVE
ub 0 "updater-bundle status with a writer changed on origin/main" scripts/ops/pearl-runtime.sh status
expect_next bundle_source:blocked
case "$(next_field reason)" in *"origin/main changes scripts/lib/coordinator_config_guard.py"*) ok ;; *) bad "drift reason: $(next_field reason)" ;; esac
rm -f "$tmp/bin/flock"

printf 'entry points: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
