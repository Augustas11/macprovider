#!/usr/bin/env bash
# Pearl coordinator/gateway runtime release entry point.
#
# Usage:
#   scripts/ops/pearl-runtime.sh status            read-only; one JSON object on stdout,
#                                                  human summary on stderr
#   scripts/ops/pearl-runtime.sh next              print the next documented step
#   scripts/ops/pearl-runtime.sh next --run        run exactly that one step
#   scripts/ops/pearl-runtime.sh next --done STEP --evidence TEXT
#
# The target tag comes from PEARL_RUNTIME_VERSION (vX.Y.Z). Read the "Consumed
# identities" row of docs/releases/cli-release-train.md before choosing it:
# CLI candidates and Pearl runtime tags share the 1.8.x namespace.
#
# Order (docs/runbooks/pearl-coordinator-rollout.md "Hard rules", "Preflight",
# "Runtime apply"; docs/releases/cli-release-train.md Session protocol):
#   1 code_changed      coordinator/gateway code differs from the live tag (rule 2:
#                       never cut a runtime release to ship tooling only)
#   2 signed_tag        signed annotated tag on origin/main HEAD
#   3 dispatch          pearl-runtime-release.yml on main (one in flight at most)
#   4 env_approval      production-release approval (owner account)
#   4a app_attest_recorder  one-time: app_attest_recorder login and
#                       ONBOARDING_APP_ATTEST_RECORD_DSN in the Pearl coordinator env
#                       (SPEC-033 §2.7). No restart and no downtime of its own: the
#                       apply's coordinator restart loads it; a full deploy refuses
#                       without it.
#   stats_migrate       pending stats/rewards Postgres migrations of the coordinator
#                       binary installed on Pearl (`stats-migrate --check` lists
#                       them; no downtime). The signed updater never applies
#                       them. Checked at two points: before 4a while no apply has
#                       run (migrations shipped by an earlier release that were
#                       never applied) and after 7 once the new binary is live
#                       (the new release's own migrations).
#   5 plan              Pearl preflight + macprovider-pearl-update --plan (read-only)
#   6 apply             systemd-run updater --apply (15-20 min network down)
#   7 wait_updater      bounded wait for the updater unit to exit
#   8 health            coordinator and gateway /healthz report the tag
#
# One-time task (PEARL_RUNTIME_TASK=retention-vacuum-conversion), outside the
# release train: convert the coordinator database files to
# auto_vacuum=INCREMENTAL with a full VACUUM
# (ops/runbooks/settlement-evidence-retention.md section 4):
#   1 vacuum_mode       read-only: PRAGMA auto_vacuum of the coordinator,
#                       route-snapshot journal, and audit database files
#   2 drain_gate        read-only: the last completed retention lap found no
#                       eligible request (backlog_drained)
#   3 convert           under the live-ops lock and the three Pearl locks:
#                       stop the coordinator, quick_check (refuse on failure),
#                       take a fresh VACUUM INTO backup of each file, VACUUM
#                       with auto_vacuum=INCREMENTAL, quick_check again, start
#                       it (downtime stated first)
#   Env: PEARL_COORDINATOR_DB (absolute path of the coordinator database on
#   Pearl, required), PEARL_SQLITE3, PEARL_COORDINATOR_UNIT,
#   PEARL_UPDATER_LOCK, PEARL_DEPLOY_LOCK, PEARL_DEPLOY_OPERATION_LOCK,
#   PEARL_COORDINATOR_HEALTHZ_URL.
#
# Env (or ~/.config/macprovider/ops.env): COORDINATOR_URL, GATEWAY_URL,
# PEARL_SSH, PEARL_RUNTIME_VERSION, UPDATER_WAIT_MAX_S (default 2700),
# PEARL_COORDINATOR_ENV (default /etc/macprovider/coordinator.env),
# PEARL_COORDINATOR_BIN (default /opt/macprovider/coordinator), MACPROVIDER_OPS_OWNER (for --run).
set -euo pipefail
# shellcheck source-path=SCRIPTDIR disable=SC2034  # OPS_NAME/NEXT_* are read by lib/common.sh

OPS_NAME=pearl-runtime
# Every runnable step here touches Pearl (even --plan runs as root there).
OPS_REQUIRE_CLEAN_FOR_ALL=1
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() { sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }

ROLLOUT_DOC="docs/runbooks/pearl-coordinator-rollout.md"
RETENTION_DOC="ops/runbooks/settlement-evidence-retention.md"
VACUUM_DOWNTIME="coordinator stopped while SQLite rewrites the coordinator and route-snapshot journal database files (full VACUUM): about as long as the updater's pre-apply backup of the same files (ops/runbooks/pearl-release-updater.md), in proportion to their size; buyer and provider traffic through the coordinator is down for that time"
STATS_MIGRATE_DOWNTIME="none (embedded stats/rewards Postgres migrations apply while the coordinator keeps serving; no restart)"
APPLY_DOWNTIME="15-20 minutes of network down (runtime apply), unless the short-quiesce updater hotfix is installed"


max_remote_tag() {
  git -C "$REPO_ROOT" ls-remote --tags origin 'v*' 2>/dev/null |
    sed -nE 's#.*refs/tags/v([0-9]+\.[0-9]+\.[0-9]+)$#\1#p' |
    sort -t. -k1,1n -k2,2n -k3,3n | tail -n1
}

# Read one PRAGMA/SELECT from a Pearl database file without writing it. The
# statement must not contain single quotes; columns come back |-separated.
pearl_sqlite_read() {
  ssh "$PEARL_SSH" "'$1' -readonly '$2' '$3'" 2>/dev/null
}

# stats_migrate: pending stats migrations. The signed updater never runs stats-migrate
# (ops/runbooks/pearl-release-updater.md), and a migration is only known to the
# binary that embeds it. One probe, two call sites in gather:
#   - before app_attest_recorder, while no apply has run for this tag: the
#     installed binary may carry migrations an earlier release shipped and
#     nobody applied;
#   - after wait_updater, once the new binary is live: its own migrations.
# Calling it between the apply and the end of the updater unit would race the
# binary swap, so that window is skipped. The probe reads live state, so it is
# idempotent and needs no completion marker.
STATS_RECORDED=0
# Case-insensitive postgres(ql):// URLs and libpq password=... pairs.
read -r -d '' REDACT_SED <<'SED' || true
s#[Pp][Oo][Ss][Tt][Gg][Rr][Ee][Ss]([Qq][Ll])?://[^[:space:]]*#postgres://REDACTED#g;s#([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Pp][Ww][Dd])[[:space:]]*=[[:space:]]*("[^"]*"|'[^']*'|[^[:space:]]+)#\1=REDACTED#g
SED
# Redacted, printable-only copy of remote output (no terminal control bytes).
safe_remote_output() { sed -E "$REDACT_SED" | LC_ALL=C tr -cd '\11\12\40-\176'; }

# The script run as root on Pearl (`bash -s -- ENV_FILE BIN check|apply`). It
# reads COORDINATOR_PARTNER_KEYS_ADMIN_DSN from the env file as data (never
# sourced, like deploy-pearl-vps.sh read_env_value), exports it for the
# coordinator to resolve (never argv), and redacts and strips control bytes
# from everything it prints.
stats_migrate_remote_script() {
  local head tail
  read -r -d '' head <<'REMOTE_HEAD' || true
set -euo pipefail
env="$1"; bin="$2"; mode="$3"
read -r -d '' py <<'PYCODE' || true
import os, shlex, sys
found = None
try:
    for raw in open(os.environ["ENV_FILE"], encoding="utf-8"):
        line = raw.rstrip("\n").strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key.strip() != "COORDINATOR_PARTNER_KEYS_ADMIN_DSN":
            continue
        parts = shlex.split(value.strip(), comments=False, posix=True)
        if len(parts) != 1 or any(c in parts[0] for c in "\r\n\0"):
            sys.exit(2)
        found = parts[0]
except (OSError, ValueError):
    sys.exit(2)
if not found:
    sys.exit(1)
print(found, end="")
PYCODE
dsn="$(ENV_FILE="$env" python3 -I -c "$py")" || { echo "cannot read COORDINATOR_PARTNER_KEYS_ADMIN_DSN from the env file" >&2; exit 1; }
export COORDINATOR_PARTNER_KEYS_ADMIN_DSN="$dsn"
REMOTE_HEAD
  read -r -d '' tail <<'REMOTE_TAIL' || true
clean() { local t; t="$(cat)"; t="${t//"$dsn"/REDACTED}"; printf '%s\n' "$t" | sed -E "$sedx" | LC_ALL=C tr -cd '\11\12\40-\176'; }
case "$mode" in
  check) "$bin" stats-migrate --check 2>&1 </dev/null | clean ;;
  apply)
    "$bin" stats-migrate 2>&1 </dev/null | clean
    chk="$("$bin" stats-migrate --check 2>&1 </dev/null)" || { printf '%s\n' "$chk" | clean >&2; exit 1; }
    printf '%s\n' "$chk" | clean
    if printf '%s\n' "$chk" | grep -Eq '[[:space:]]pending$'; then
      echo "stats migrations still pending after the apply" >&2
      exit 1
    fi ;;
  *) echo "bad mode" >&2; exit 2 ;;
esac
REMOTE_TAIL
  printf '%s\nread -r -d %s sedx <<%s || true\n%s\nSED\n%s\n' "$head" "''" "'SED'" "$REDACT_SED" "$tail"
}

stats_migrate_step() {
  [ "$STATS_RECORDED" = 0 ] || return 0
  STATS_RECORDED=1
  local env="${PEARL_COORDINATOR_ENV:-/etc/macprovider/coordinator.env}" bin="${PEARL_COORDINATOR_BIN:-/opt/macprovider/coordinator}"
  [[ "$env" =~ ^/[A-Za-z0-9._/-]+$ ]] || refuse "PEARL_COORDINATOR_ENV must be an absolute path"
  [[ "$bin" =~ ^/[A-Za-z0-9._/-]+$ ]] || refuse "PEARL_COORDINATOR_BIN must be an absolute path"
  if [ -z "${PEARL_SSH:-}" ]; then
    # Unknown is not "nothing pending": never let the train go on or finish.
    step stats_migrate blocked "PEARL_SSH is unset"
    set_next stats_migrate blocked "Check pending stats migrations on Pearl" "" "PEARL_SSH is unset"
    return
  fi
  local body out rc=0 pending
  body="$(stats_migrate_remote_script)"
  out="$(printf '%s\n' "$body" | ssh "$PEARL_SSH" "sudo bash -s -- $env $bin check" 2>&1)" || rc=$?
  out="$(printf '%s\n' "$out" | safe_remote_output)"
  if [ "$rc" != 0 ] || ! printf '%s\n' "$out" | grep -q '^stats-migrate check'; then
    step stats_migrate blocked "cannot read the stats migration state on Pearl (rc=$rc)"
    set_next stats_migrate blocked "Check pending stats migrations on Pearl" "" \
      "stats-migrate --check over ssh failed (rc=$rc): $(printf '%s' "$out" | tail -n 1 | cut -c1-200)"
    return
  fi
  pending="$(printf '%s\n' "$out" | sed -nE 's/^[[:space:]]*([^[:space:]]+)[[:space:]]+pending$/\1/p' | tr -cd 'A-Za-z0-9_\n' | tr '\n' ' ')"
  pending="${pending% }"
  fact stats_migrations_pending "$pending"
  if [ -z "$pending" ]; then
    step stats_migrate "done" "no pending stats migrations"
    return
  fi
  step stats_migrate pending "pending: $pending"
  [ -z "$NEXT_ID" ] || return 0
  set_next stats_migrate mutate "Apply pending stats migrations on Pearl: $pending (no downtime)" \
"ssh \"\$PEARL_SSH\" 'sudo bash -s -- $env $bin apply' <<'REMOTE'
$body
REMOTE" "the installed coordinator binary reports pending stats migrations; the signed updater does not apply them"
  next_meta stats_migrate "$ROLLOUT_DOC#stats-migrations" "$STATS_MIGRATE_DOWNTIME"
}

gather_retention_vacuum() {
  OPS_SCOPE="retention-vacuum-conversion"
  NEXT_RUNBOOK="$RETENTION_DOC"
  local db="${PEARL_COORDINATOR_DB:-}" sqlite="${PEARL_SQLITE3:-/opt/macprovider-tools/sqlite-3.53.2/bin/sqlite3}"
  local unit="${PEARL_COORDINATOR_UNIT:-macprovider-coordinator}"
  local ulock="${PEARL_UPDATER_LOCK:-/run/lock/macprovider-pearl-updater.lock}"
  local dlock="${PEARL_DEPLOY_LOCK:-/opt/macprovider/.coordinator-deploy.lock}"
  local olock="${PEARL_DEPLOY_OPERATION_LOCK:-/opt/macprovider/.coordinator-deploy-operation.lock}"
  local healthz="${PEARL_COORDINATOR_HEALTHZ_URL:-http://127.0.0.1:8444/healthz}"
  local p
  for p in "$sqlite" "$ulock" "$dlock" "$olock"; do
    [[ "$p" =~ ^/[A-Za-z0-9._/-]+$ ]] || refuse "Pearl paths must be absolute and plain: $p"
  done
  [[ "$unit" =~ ^[A-Za-z0-9][A-Za-z0-9@._-]*$ ]] || refuse "PEARL_COORDINATOR_UNIT must be a plain unit name"
  [[ "$healthz" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9._/-]*$ ]] || refuse "PEARL_COORDINATOR_HEALTHZ_URL must be a plain http(s) URL"
  if [ -z "$db" ]; then
    step vacuum_mode pending "PEARL_COORDINATOR_DB is unset"
    set_next vacuum_mode blocked "Read the coordinator database auto_vacuum mode" "" "set PEARL_COORDINATOR_DB to the coordinator database path on Pearl"
    return
  fi
  [[ "$db" =~ ^/[A-Za-z0-9._/-]+$ ]] || refuse "PEARL_COORDINATOR_DB must be an absolute plain path"
  if [ -z "${PEARL_SSH:-}" ]; then
    step vacuum_mode pending "PEARL_SSH is unset"
    set_next vacuum_mode blocked "Read the coordinator database auto_vacuum mode" "" "PEARL_SSH is unset"
    return
  fi
  local main_mode journal_mode="absent" audit_mode="absent"
  # The settlement receipt audit database sits next to the coordinator
  # database (SPEC-002 R-7.10.2); its rotation frees pages the same way.
  local audit_db="${db%/*}/coordinator-audit.db"
  main_mode="$(pearl_sqlite_read "$sqlite" "$db" 'PRAGMA auto_vacuum;' || true)"
  if ssh "$PEARL_SSH" "test -f '$db.route-snapshots'" 2>/dev/null; then
    journal_mode="$(pearl_sqlite_read "$sqlite" "$db.route-snapshots" 'PRAGMA auto_vacuum;' || true)"
  fi
  if ssh "$PEARL_SSH" "test -f '$audit_db'" 2>/dev/null; then
    audit_mode="$(pearl_sqlite_read "$sqlite" "$audit_db" 'PRAGMA auto_vacuum;' || true)"
  fi
  fact coordinator_db_auto_vacuum "$main_mode"
  fact route_snapshot_journal_auto_vacuum "$journal_mode"
  fact audit_db_auto_vacuum "$audit_mode"
  if ! [[ "$main_mode" =~ ^[0-2]$ ]] || ! [[ "$journal_mode" =~ ^([0-2]|absent)$ ]] || ! [[ "$audit_mode" =~ ^([0-2]|absent)$ ]]; then
    step vacuum_mode blocked "cannot read PRAGMA auto_vacuum on Pearl"
    set_next vacuum_mode blocked "Read the coordinator database auto_vacuum mode" "" \
      "PRAGMA auto_vacuum over ssh failed (coordinator=$main_mode journal=$journal_mode audit=$audit_mode); check PEARL_COORDINATOR_DB and PEARL_SQLITE3"
    return
  fi
  if [ "$main_mode" = 2 ] && [[ "$journal_mode" =~ ^(2|absent)$ ]] && [[ "$audit_mode" =~ ^(2|absent)$ ]]; then
    local s
    for s in vacuum_mode drain_gate convert; do step "$s" "done" ""; done
    set_next "done" "done" "every database file is auto_vacuum=INCREMENTAL" ""
    return
  fi
  step vacuum_mode "done" "coordinator=$main_mode journal=$journal_mode audit=$audit_mode (2 = INCREMENTAL)"

  # The drain signal: the last completed retention lap found nothing eligible.
  local lap
  lap="$(pearl_sqlite_read "$sqlite" "$db" "SELECT laps_completed, last_lap_eligible_requests, last_lap_completed_at_utc FROM settlement_evidence_retention_state WHERE id = 1;" || true)"
  fact retention_last_lap "$lap"
  local laps="${lap%%|*}" rest="${lap#*|}"
  local eligible="${rest%%|*}"
  if [[ "$laps" =~ ^[0-9]+$ ]] && [ "$laps" -gt 0 ] && [ "$eligible" = 0 ]; then
    step drain_gate "done" "last lap completed ${rest#*|} with 0 eligible requests"
  else
    step drain_gate blocked "retention has not drained (laps_completed=${laps:-?} last_lap_eligible_requests=${eligible:-?})"
    set_next drain_gate blocked "Wait for settlement-evidence retention to drain" "" \
      "the conversion rewrites the whole file, so it waits until a completed retention lap finds no eligible request (backlog_drained=true in the nightly log); now laps_completed=${laps:-?} last_lap_eligible_requests=${eligible:-?}"
    return
  fi

  step convert pending ""
  set_next convert mutate "Convert the coordinator database files to auto_vacuum=INCREMENTAL (one-time)" \
"ssh \"\$PEARL_SSH\" 'bash -s -- $db $sqlite $unit $ulock $dlock $olock $healthz' <<'REMOTE'
set -euo pipefail
trap '' PIPE
umask 077
db=\"\$1\"; sqlite=\"\$2\"; unit=\"\$3\"; healthz=\"\$7\"
# The Pearl locks are 0600 regular files (the config guard refuses others).
for l in \"\$4\" \"\$5\" \"\$6\"; do
  if [ -L \"\$l\" ]; then echo \"refused: lock \$l is a symlink\" >&2; exit 1; fi
  [ -e \"\$l\" ] || : >> \"\$l\"
done
exec 7>>\"\$4\"; flock -n 7 || { echo \"lock busy: \$4\" >&2; exit 1; }
exec 8>>\"\$5\"; flock -n 8 || { echo \"lock busy: \$5\" >&2; exit 1; }
exec 9>>\"\$6\"; flock -n 9 || { echo \"lock busy: \$6\" >&2; exit 1; }
files=\"\$db\"; [ ! -e \"\$db.route-snapshots\" ] || files=\"\$files \$db.route-snapshots\"
audit=\"\$(dirname \"\$db\")/coordinator-audit.db\"; [ ! -e \"\$audit\" ] || files=\"\$files \$audit\"
need=0
for f in \$files; do
  [ -f \"\$f\" ] && [ ! -L \"\$f\" ] || { echo \"refused: \$f is not a regular file\" >&2; exit 1; }
  need=\$((need + \$(wc -c < \"\$f\")))
done
# A fresh backup copy, VACUUM's temporary copy (kept next to the files by
# SQLITE_TMPDIR), and the rewritten file's WAL, all on this filesystem.
export SQLITE_TMPDIR=\"\$(dirname \"\$db\")\"
want=\$((need * 3))
free=\$((\$(df -Pk \"\$(dirname \"\$db\")\" | awk 'NR == 2 { print \$4 }') * 1024))
[ \"\$free\" -gt \"\$want\" ] || { echo \"refused: the conversion needs about \$want free bytes, \$free free\" >&2; exit 1; }
stamp=\$(date -u +%Y%m%dT%H%M%SZ)
keep_stopped=0
trap '[ \"\$keep_stopped\" = 1 ] || systemctl start -- \"\$unit\"' EXIT
systemctl stop -- \"\$unit\"
for f in \$files; do
  if [ \"\$(\"\$sqlite\" \"\$f\" 'PRAGMA quick_check;')\" != ok ]; then
    echo \"refused: quick_check failed on \$f before the conversion; nothing was changed\" >&2
    exit 1
  fi
done
for f in \$files; do
  backup=\"\$f.pre-incremental-\$stamp\"
  \"\$sqlite\" \"\$f\" \"VACUUM INTO '\$backup';\"
  echo \"backup: \$backup\" >&2
  owner=\$(ls -ln \"\$f\" | awk '{ print \$3 \":\" \$4 }')
  \"\$sqlite\" \"\$f\" 'PRAGMA auto_vacuum = INCREMENTAL; VACUUM;'
  if [ \"\$(\"\$sqlite\" \"\$f\" 'PRAGMA quick_check;')\" != ok ]; then
    keep_stopped=1
    echo \"quick_check failed on \$f after VACUUM: the coordinator stays stopped; restore \$f from \$backup\" >&2
    exit 1
  fi
  [ \"\$(\"\$sqlite\" \"\$f\" 'PRAGMA auto_vacuum;')\" = 2 ] || { echo \"auto_vacuum is not INCREMENTAL on \$f (backup: \$backup)\" >&2; exit 1; }
  # WAL side files this shell created must stay the coordinator's; never
  # follow a link.
  for x in \"\$f-wal\" \"\$f-shm\"; do
    if [ -L \"\$x\" ]; then echo \"refused: \$x is a symlink\" >&2; exit 1; fi
    [ ! -e \"\$x\" ] || chown -h \"\$owner\" \"\$x\"
  done
done
trap - EXIT
systemctl start -- \"\$unit\"
for _ in \$(seq 90); do curl -sf \"\$healthz\" >/dev/null && exit 0; sleep 2; done
echo \"coordinator not healthy after the conversion\" >&2; exit 1
REMOTE"
  next_meta convert "$RETENTION_DOC" "$VACUUM_DOWNTIME" convert
}

gather() {
  STATS_RECORDED=0
  if [ -n "${PEARL_RUNTIME_TASK:-}" ]; then
    case "$PEARL_RUNTIME_TASK" in
      retention-vacuum-conversion) gather_retention_vacuum; return ;;
      *) refuse "unknown PEARL_RUNTIME_TASK: $PEARL_RUNTIME_TASK" ;;
    esac
  fi
  local main_sha live gw_live T
  main_sha="$(origin_main_sha)"
  is_sha40 "$main_sha" || die "cannot resolve origin/main"
  fact origin_main_sha "$main_sha"

  live=""; gw_live=""
  if fetch_coordinator_health; then
    live="$(json_field "$OPS_TMP_DIR/healthz.json" 'd["version"]')"
  fi
  # Versions are validated before they reach a git refspec.
  if [ -n "$live" ] && ! [[ "$live" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fact live_coordinator_version_invalid "$live"
    live=""
  fi
  if [ -n "$(gateway_url)" ] && [ "$(http_get "$(gateway_url)/healthz" "$OPS_TMP_DIR/gw.json")" = "200" ]; then
    gw_live="$(json_field "$OPS_TMP_DIR/gw.json" 'd["version"]')"
  fi
  fact live_coordinator_version "$live"
  fact live_gateway_version "$gw_live"
  local max_tag
  max_tag="$(max_remote_tag)"
  fact highest_remote_tag "v$max_tag"

  local id status concl active="" runs_note=""
  while IFS=$'\t' read -r id status concl _; do
    [ -n "$id" ] || continue
    [ "$status" != "completed" ] && [ -z "$active" ] && active="$id:$status"
    runs_note="$runs_note $id:$status/$concl"
  done <<EOF
$(workflow_runs pearl-runtime-release.yml 5)
EOF
  fact pearl_runtime_release_runs "${runs_note# }"
  fact pearl_runtime_release_active "$active"
  local prod_active
  prod_active="$(production_release_active_runs | tr '\t\n' ': ' | sed 's/ $//')"
  fact production_release_active_runs "$prod_active"

  T="${PEARL_RUNTIME_VERSION:-}"
  if [ -n "$T" ] && ! [[ "$T" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    refuse "PEARL_RUNTIME_VERSION must be vMAJOR.MINOR.PATCH"
  fi
  fact target_version "$T"
  NEXT_RUNBOOK="$ROLLOUT_DOC"

  if [ -z "$live" ]; then
    set_next live_state blocked "Read the live coordinator version" "" "COORDINATOR_URL is unset or /healthz is unreadable"
  fi

  # 1. rule 2: the release must change coordinator/gateway code.
  local ref="origin/main" changed=unknown unknown_why="live coordinator version unreadable"
  if [ -n "$T" ] && remote_tag_exists "$T"; then
    git -C "$REPO_ROOT" fetch -q origin "refs/tags/$T:refs/tags/$T" 2>/dev/null || true
    ref="$T"
  fi
  if [ -n "$live" ]; then
    git -C "$REPO_ROOT" fetch -q origin "refs/tags/$live:refs/tags/$live" 2>/dev/null || true
    if ! git -C "$REPO_ROOT" rev-parse -q --verify "$live^{commit}" >/dev/null; then
      unknown_why="live tag $live is not available locally (fetch failed or tag missing)"
    elif ! git -C "$REPO_ROOT" rev-parse -q --verify "$ref^{commit}" >/dev/null; then
      unknown_why="$ref is not available locally"
    else
      # Tests, fixtures, docs and dist/ deploy tooling do not change the shipped binaries.
      local diff_rc=0
      git -C "$REPO_ROOT" diff --quiet "$live" "$ref" -- phase4-coordinator phase5-gateway \
        ':(exclude)*_test.go' ':(exclude)*/testdata/*' ':(exclude)*.md' \
        ':(exclude)phase4-coordinator/dist/*' ':(exclude)phase5-gateway/dist/*' 2>/dev/null || diff_rc=$?
      case "$diff_rc" in
        0) changed=false ;;
        1) changed=true ;;
        *) unknown_why="git diff $live..$ref failed (rc=$diff_rc)" ;;
      esac
    fi
  fi
  fact code_changed_vs_live "$changed"
  if [ -n "$T" ] && [ "$T" = "$live" ] && [ "$gw_live" = "$T" ]; then
    local s
    for s in code_changed signed_tag dispatch env_approval plan apply wait_updater; do step "$s" "done" ""; done
    step health "done" "coordinator and gateway report $T"
    # Live is not done while the live binary's own migrations are pending.
    stats_migrate_step
    set_next "done" "done" "$T is live" ""
    return
  fi
  case "$changed" in
    true) step code_changed "done" "$ref changes shipped coordinator/gateway code vs live $live" ;;
    false)
      step code_changed blocked "$ref coordinator/gateway code == live $live"
      set_next code_changed blocked "Cut a runtime release" "" \
        "shipped coordinator/gateway code at $ref is identical to live $live (only tests/docs/dist tooling differ); a runtime apply buys nothing and costs a full outage (rollout rule 2). Fix the tooling instead." ;;
    *)
      step code_changed blocked "$unknown_why"
      set_next code_changed blocked "Compare shipped code with the live runtime" "" \
        "cannot tell whether $ref changes shipped coordinator/gateway code: $unknown_why; refusing to proceed (rollout rule 2)" ;;
  esac

  if [ -z "$T" ]; then
    local suggest
    suggest="v$(python3 -c 'import sys; a=sys.argv[1].split("."); a[2]=str(int(a[2])+1); print(".".join(a))' "${max_tag:-0.0.0}")"
    step signed_tag pending "no PEARL_RUNTIME_VERSION"
    set_next signed_tag blocked "Choose the runtime tag" "PEARL_RUNTIME_VERSION=$suggest $0 status" \
      "set PEARL_RUNTIME_VERSION; $suggest is the next unused tag on origin, confirm it against the Consumed identities row of docs/releases/cli-release-train.md"
    return
  fi
  OPS_SCOPE="pearl-runtime-$T"

  # 2. signed annotated tag on main HEAD.
  if remote_tag_exists "$T"; then
    local ttype signed=false
    ttype="$(git -C "$REPO_ROOT" cat-file -t "$T" 2>/dev/null || true)"
    git -C "$REPO_ROOT" verify-tag "$T" >/dev/null 2>&1 && signed=true
    fact tag_object_type "$ttype"
    fact tag_signature_verified_locally "$signed"
    if [ "$ttype" = tag ]; then
      step signed_tag "done" "$T annotated (local signature check: $signed)"
    else
      step signed_tag blocked "$T is a lightweight tag"
      set_next signed_tag blocked "Signed annotated tag $T" "" "$T exists on origin but is not an annotated tag; tags are immutable, choose the next unused version"
    fi
  else
    step signed_tag pending ""
    if [ "$(semver_cmp "${T#v}" "${max_tag:-0.0.0}")" != "1" ]; then
      set_next signed_tag blocked "Signed annotated tag $T" "" "$T is not above the highest remote tag v$max_tag; consumed tags are never reused"
    else
      set_next signed_tag mutate "Push signed annotated tag $T on origin/main HEAD $main_sha" \
"git tag -s -a $T -m 'Pearl runtime $T' $main_sha
git push origin refs/tags/$T"
    fi
  fi

  # A recorded apply whose updater unit failed while the live version stayed
  # behind was rolled back by the updater: forget the marker so the apply is
  # offered again (step 6 resets the failed transient unit, which blocks
  # systemd-run). Done first so every later step sees the true apply state.
  local apply_rolled_back=false
  if [ "$live" != "$T" ] && [ -n "${PEARL_SSH:-}" ] &&
    ssh "$PEARL_SSH" "systemctl is-failed --quiet mp-update-${T#v}" 2>/dev/null; then
    apply_rolled_back=true
    rm -f "$(marker_path "$OPS_SCOPE" apply)"
  fi

  # 3-4. dispatch and approval.
  local rel_assets
  rel_assets="$(gh release view "$T" -R "$(gh_repo)" --json assets --jq '[.assets[].name] | join(" ")' 2>/dev/null || true)"
  local has_release=false
  [[ " $rel_assets " == *" pearl-release.json "* ]] && has_release=true
  fact release_assets_present "$has_release"
  case "$has_release" in
    true)
      step dispatch "done" "release $T carries pearl-release.json"
      step env_approval "done" "" ;;
    *)
      if [ -n "$active" ]; then
        step dispatch in_progress "run $active"
        case "$active" in
          *:waiting)
            step env_approval pending "run ${active%%:*} waits on production-release"
            set_next env_approval manual "Approve production-release for runtime run ${active%%:*} (owner account)" \
              "gh run view ${active%%:*} -R $(gh_repo)   # approve the pending deployment from the owner account" ;;
          *)
            set_next dispatch blocked "Wait for runtime run ${active%%:*}" "gh run watch ${active%%:*} -R $(gh_repo)" \
              "pearl-runtime-release run $active is in flight; refusing a second dispatch" ;;
        esac
      else
        step dispatch pending ""
        step env_approval pending ""
        if [ -n "$prod_active" ]; then
          set_next dispatch blocked "Dispatch pearl-runtime-release $T" "" \
            "production-release group busy (a waiting discovery-head renewal blocks it until approved): $prod_active"
        else
          set_next dispatch mutate "Dispatch pearl-runtime-release.yml for $T on main" \
            "gh workflow run pearl-runtime-release.yml -R $(gh_repo) --ref main -f version=$T -f prerelease=true"
        fi
      fi ;;
  esac

  # stats_migrate, pre-apply. Migrations already pending under the installed binary.
  if [ "$live" != "$T" ] && ! marker_done "$OPS_SCOPE" apply; then
    stats_migrate_step
  fi

  # 4a. one-time recorder provisioning (SPEC-033 §2.7). Read-only check on
  # Pearl: the provisioner's --check logs in with the DSN and applies the
  # least-privilege policy; only valid/absent/invalid comes back.
  local pearl_env="${PEARL_COORDINATOR_ENV:-/etc/macprovider/coordinator.env}" rec_rc=0
  local provisioner="phase4-coordinator/dist/provision-app-attest-recorder.py"
  [[ "$pearl_env" =~ ^/[A-Za-z0-9._/-]+$ ]] || refuse "PEARL_COORDINATOR_ENV must be an absolute path"
  if [ -z "${PEARL_SSH:-}" ]; then
    step app_attest_recorder pending "PEARL_SSH is unset"
  else
    ssh "$PEARL_SSH" "python3 -I - --check --env-file '$pearl_env'" < "$REPO_ROOT/$provisioner" >/dev/null 2>&1 || rec_rc=$?
    local rotate="" why=""
    case "$rec_rc" in
      0) step app_attest_recorder "done" "ONBOARDING_APP_ATTEST_RECORD_DSN logs in with least privilege on Pearl" ;;
      10|11)
        if [ "$rec_rc" = 11 ]; then
          rotate=" --rotate"; why="ONBOARDING_APP_ATTEST_RECORD_DSN is set on Pearl but fails the recorder login or least-privilege check"
        else
          why="ONBOARDING_APP_ATTEST_RECORD_DSN is not set on Pearl"
        fi
        step app_attest_recorder pending "$why"
        set_next app_attest_recorder mutate "Provision the app_attest_recorder login on Pearl (one-time)" \
"tar -C phase4-coordinator/dist -cf - app-attest-recorder-bootstrap.sql provision-app-attest-recorder.py |
  ssh \"\$PEARL_SSH\" 'set -e; d=\$(mktemp -d); trap \"rm -rf \$d\" EXIT; tar -C \$d -xf -; python3 -I \$d/provision-app-attest-recorder.py --env-file $pearl_env --sql \$d/app-attest-recorder-bootstrap.sql$rotate'" "$why"
        next_meta app_attest_recorder "$ROLLOUT_DOC#app-attest-recorder-one-time" "" ;;
      *)
        step app_attest_recorder blocked "cannot check the recorder DSN on Pearl (rc=$rec_rc)"
        set_next app_attest_recorder blocked "Check the app_attest_recorder DSN on Pearl" "" \
          "the recorder check over ssh failed (rc=$rec_rc); the apply needs a working ONBOARDING_APP_ATTEST_RECORD_DSN" ;;
    esac
  fi

  # 5. preflight + plan (read-only on Pearl).
  local plan_fresh=false
  if marker_done "$OPS_SCOPE" plan &&
    [ -n "$(find "$(marker_path "$OPS_SCOPE" plan)" -mmin -120 2>/dev/null)" ]; then
    plan_fresh=true
  fi
  if marker_done "$OPS_SCOPE" apply; then
    step plan "done" ""
  elif [ "$plan_fresh" = true ]; then
    step plan "done" "plan within the last 2 h"
  else
    step plan pending ""
    if [ -z "${PEARL_SSH:-}" ]; then
      set_next plan blocked "Preflight and plan on Pearl" "" "PEARL_SSH is unset"
    elif [ -z "$NEXT_ID" ]; then
      # Rendered only when this is the next step; a render failure aborts gather.
      local preflight_cmd
      preflight_cmd="$(render_runbook "$RB_PEARL_PREFLIGHT")"
      set_next plan read "Pearl preflight and updater --plan for $T (read-only)" \
"$preflight_cmd
ssh \"\$PEARL_SSH\" 'for l in /run/lock/macprovider-pearl-updater.lock /opt/macprovider/.coordinator-deploy.lock; do flock -n \$l true || { echo \"lock busy: \$l\" >&2; exit 1; }; done'
ssh \"\$PEARL_SSH\" '/usr/local/sbin/macprovider-pearl-update --plan --tag $T'"
      next_meta plan "$ROLLOUT_DOC#preflight-every-time" "" plan
    fi
  fi

  # 6. apply (a rolled-back apply was detected above, before the pre-apply stats check).
  if marker_done "$OPS_SCOPE" apply; then
    step apply "done" "$(marker_field "$OPS_SCOPE" apply 'd.get("recorded_at")')"
  else
    if [ "$apply_rolled_back" = true ]; then
      step apply pending "previous apply of $T failed and was rolled back; read its journal first (runbook rule 4)"
    else
      step apply pending ""
    fi
    if [ -z "$NEXT_ID" ]; then
      local apply_cmd
      apply_cmd="$(render_runbook "$RB_PEARL_APPLY" "${T#v}")"
      if [ "$apply_rolled_back" = true ]; then
        apply_cmd="ssh \"\$PEARL_SSH\" 'systemctl reset-failed mp-update-${T#v}'
$apply_cmd"
      fi
      set_next apply mutate "Apply runtime $T with the signed updater" "$apply_cmd"
    fi
    next_meta apply "$ROLLOUT_DOC#runtime-apply-signed-updater" "$APPLY_DOWNTIME" apply
  fi

  # 7. bounded wait for the transient updater unit.
  if [ "$live" = "$T" ]; then
    step wait_updater "done" "coordinator reports $T"
  else
    step wait_updater pending ""
    set_next wait_updater read "Wait (bounded) for updater unit mp-update-${T#v} to exit" \
"deadline=\$((\$(date +%s) + \${UPDATER_WAIT_MAX_S:-2700}))
while ssh \"\$PEARL_SSH\" 'systemctl is-active --quiet mp-update-${T#v}'; do
  [ \"\$(date +%s)\" -lt \"\$deadline\" ] || { echo 'updater still running at the deadline; inspect, do not retry' >&2; exit 1; }
  sleep 30
done
ssh \"\$PEARL_SSH\" 'systemctl show mp-update-${T#v} -p Result -p ExecMainStatus --no-pager || true; journalctl -u mp-update-${T#v} -n 40 --no-pager || true'"
  fi

  # stats_migrate, post-apply. Migrations of the binary that is now live (before health is reported).
  if [ "$live" = "$T" ]; then
    stats_migrate_step
  elif [ "$STATS_RECORDED" = 0 ]; then
    step stats_migrate pending "checked once the new binary is live"
  fi

  # 8. health.
  step health pending "coordinator=$live gateway=$gw_live"
  set_next health read "Check coordinator and gateway health report $T" \
"curl -sf \"\$COORDINATOR_URL/healthz\"; echo
curl -sf \"\$GATEWAY_URL/healthz\"; echo
curl -sf \"\$COORDINATOR_URL/healthz\" | grep -q '\"version\":\"$T\"'
curl -sf \"\$GATEWAY_URL/healthz\" | grep -q '\"version\":\"$T\"'"
}

internal() { usage >&2; exit 2; }

ops_main "$@"
