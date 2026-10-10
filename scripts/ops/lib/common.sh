# shellcheck shell=bash
# Shared plumbing for the scripts/ops entry points. Sourced, never executed.
#
# Every entry point gathers live state into "facts" and "steps", decides the
# single next documented step, and either prints it (`status`, `next`) or runs
# exactly that step (`next --run`). Hosts and targets come from the
# environment or from an untracked local file (default
# ~/.config/macprovider/ops.env); nothing host-specific is committed.
#
# bash 3.2 compatible: no associative arrays, no mapfile, guard empty arrays.

OPS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPS_DIR="$(cd "$OPS_LIB_DIR/.." && pwd)"
REPO_ROOT="$(cd "$OPS_DIR/../.." && pwd)"

OPS_ENV_FILE="${MACPROVIDER_OPS_ENV:-$HOME/.config/macprovider/ops.env}"
if [ -f "$OPS_ENV_FILE" ]; then
  # Exported so the step commands run by `next --run` see the same targets.
  set -a
  # shellcheck disable=SC1090
  . "$OPS_ENV_FILE"
  set +a
fi

OPS_STATE_DIR="${MACPROVIDER_OPS_STATE_DIR:-$HOME/.config/macprovider/ops-state}"
OPS_CURL_TIMEOUT="${OPS_CURL_TIMEOUT:-15}"

OPS_FACTS="$(mktemp -t macprovider-ops-facts.XXXXXX)"
OPS_STEPS="$(mktemp -t macprovider-ops-steps.XXXXXX)"
OPS_TMP_DIR="$(mktemp -d -t macprovider-ops.XXXXXX)"
# Live-ops lock taken by run_next. Held only while the step runs: released on
# every exit (success, failure, refusal, signal).
OPS_LOCK_OWNER=""
release_live_lock() {
  [ -n "$OPS_LOCK_OWNER" ] || return 0
  local owner="$OPS_LOCK_OWNER"
  OPS_LOCK_OWNER=""
  "$OPS_DIR/live-lock.sh" release "$owner" >&2 || true
}
cleanup_ops() {
  release_live_lock
  rm -rf "$OPS_FACTS" "$OPS_STEPS" "$OPS_TMP_DIR"
}
trap cleanup_ops EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# The single next step. Kinds:
#   done      nothing left in this train
#   blocked   a precondition fails; NEXT_REASON says which
#   manual    operator-owned (approval click, Pearl YAML edit, provider restart);
#             `next --run` refuses and prints the documented command
#   read      read-only verification the script can run
#   mutate    changes GitHub or a live host; needs the live-ops lock
NEXT_ID=""
NEXT_TITLE=""
NEXT_KIND=""
NEXT_CMD=""
NEXT_REASON=""
NEXT_DOWNTIME=""   # non-empty => Pearl-mutating; printed before anything runs
NEXT_RUNBOOK=""
NEXT_MARK=""       # step id to record as done when the command exits 0

log() { printf '[%s] %s\n' "$OPS_NAME" "$*" >&2; }
die() { printf '[%s] ERROR: %s\n' "$OPS_NAME" "$*" >&2; exit 1; }
refuse() { printf '[%s] REFUSED: %s\n' "$OPS_NAME" "$*" >&2; exit 3; }

fact() { printf '%s\t%s\n' "$1" "${2-}" >> "$OPS_FACTS"; }
step() { printf '%s\t%s\t%s\n' "$1" "$2" "${3-}" >> "$OPS_STEPS"; }

# set_next ID KIND TITLE CMD [REASON]
set_next() {
  [ -z "$NEXT_ID" ] || return 0
  NEXT_ID="$1"; NEXT_KIND="$2"; NEXT_TITLE="$3"; NEXT_CMD="${4-}"; NEXT_REASON="${5-}"
}

is_semver() { [[ "${1-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
is_sha40() { [[ "${1-}" =~ ^[0-9a-f]{40}$ ]]; }

# semver_cmp A B -> prints -1, 0 or 1
semver_cmp() {
  python3 - "$1" "$2" <<'PY'
import sys
a, b = (tuple(int(x) for x in v.split(".")) for v in sys.argv[1:3])
print((a > b) - (a < b))
PY
}

gh_repo() {
  if [ -n "${MACPROVIDER_GH_REPO:-}" ]; then printf '%s\n' "$MACPROVIDER_GH_REPO"; return; fi
  git -C "$REPO_ROOT" remote get-url origin 2>/dev/null |
    sed -E 's#^(git@[^:]+:|https?://[^/]+/)##; s#\.git$##'
}

# http_get URL OUTFILE -> prints HTTP status (000 on transport failure)
http_get() {
  curl -sS -m "$OPS_CURL_TIMEOUT" -o "$2" -w '%{http_code}' "$1" 2>/dev/null || printf '000'
}

# json_field FILE PY_EXPR  (expression over `d`; prints "" on any failure)
json_field() {
  python3 - "$1" "$2" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    v = eval(sys.argv[2], {"d": d})
except Exception:
    sys.exit(0)
if v is None:
    sys.exit(0)
print(json.dumps(v) if isinstance(v, (dict, list, bool)) else v)
PY
}

coordinator_url() { printf '%s' "${COORDINATOR_URL:-}"; }
gateway_url() { printf '%s' "${GATEWAY_URL:-}"; }

# Fetch the live coordinator /healthz into $OPS_TMP_DIR/healthz.json.
fetch_coordinator_health() {
  local base
  base="$(coordinator_url)"
  if [ -z "$base" ]; then
    fact coordinator_healthz "unset: COORDINATOR_URL"
    return 1
  fi
  local code
  code="$(http_get "$base/healthz" "$OPS_TMP_DIR/healthz.json")"
  fact coordinator_healthz_http "$code"
  [ "$code" = "200" ]
}

# GitHub workflow runs that hold or wait on the production-release
# concurrency group. Prints "id<TAB>workflow<TAB>status" per active run.
production_release_active_runs() {
  local wf
  for wf in acceptance-candidate.yml promote-acceptance-candidate.yml release.yml \
    pearl-runtime-release.yml verify-live-coordinator-release-rollout.yml \
    renew-release-discovery-head.yml; do
    gh run list -R "$(gh_repo)" -w "$wf" -L 10 \
      --json databaseId,status \
      --jq ".[] | select(.status != \"completed\") | \"\(.databaseId)\t$wf\t\(.status)\"" 2>/dev/null || true
  done
}

# Runs of WORKFLOW as JSON lines: id, status, conclusion, headSha, createdAt.
workflow_runs() {
  gh run list -R "$(gh_repo)" -w "$1" -L "${2:-20}" \
    --json databaseId,status,conclusion,headSha,createdAt,updatedAt \
    --jq '.[] | "\(.databaseId)\t\(.status)\t\(.conclusion)\t\(.headSha)\t\(.createdAt)"' 2>/dev/null || true
}

origin_main_sha() {
  git -C "$REPO_ROOT" fetch -q origin main 2>/dev/null || true
  git -C "$REPO_ROOT" rev-parse origin/main 2>/dev/null || true
}

# binary_version_at REV -> CLI binaryVersion in that commit ("" if unreadable)
binary_version_at() {
  git -C "$REPO_ROOT" show "$1:phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift" 2>/dev/null |
    sed -nE 's/^[[:space:]]*static let binaryVersion[[:space:]]*=[[:space:]]*"([^"]+)".*$/\1/p' | head -n1
}

remote_tag_exists() {
  [ -n "$(git -C "$REPO_ROOT" ls-remote --tags origin "refs/tags/$1" 2>/dev/null)" ]
}

# --- ssh -----------------------------------------------------------------

ssh_opts_for() {
  # $1 identity path (may be empty), $2 known_hosts path (may be empty)
  SSH_OPTS=(-o ConnectTimeout=15 -o BatchMode=yes)
  if [ -n "${1-}" ]; then
    SSH_OPTS+=(-i "$1" -o IdentitiesOnly=yes)
  fi
  if [ -n "${2-}" ]; then
    SSH_OPTS+=(-o "UserKnownHostsFile=$2" -o StrictHostKeyChecking=yes)
  fi
}

require_pearl_ssh() {
  [ -n "${PEARL_SSH:-}" ] ||
    refuse "PEARL_SSH is unset; set it in the environment or in $OPS_ENV_FILE (see scripts/ops/README.md)"
}

require_studio_ssh() {
  [ -n "${STUDIO_SSH:-}" ] ||
    refuse "STUDIO_SSH is unset; set STUDIO_SSH (and STUDIO_SSH_KEY if needed) in the environment or in $OPS_ENV_FILE"
}

pearl_ssh() {
  require_pearl_ssh
  ssh_opts_for "${PEARL_SSH_IDENTITY:-}" "${PEARL_SSH_KNOWN_HOSTS:-}"
  # shellcheck disable=SC2029  # callers pass one remote command string on purpose
  ssh "${SSH_OPTS[@]}" "$PEARL_SSH" "$@"
}

studio_ssh() {
  require_studio_ssh
  ssh_opts_for "${STUDIO_SSH_KEY:-}" ""
  # shellcheck disable=SC2029
  ssh "${SSH_OPTS[@]}" "$STUDIO_SSH" "$@"
}

# --- completion markers for steps that leave no live trace ----------------

marker_path() { printf '%s/%s/%s.json' "$OPS_STATE_DIR" "$1" "$2"; }

marker_done() { [ -f "$(marker_path "$1" "$2")" ]; }

# mark_done SCOPE STEP EVIDENCE [EXTRA_JSON_OBJECT]
mark_done() {
  local path extra="${4:-}"
  [ -n "$extra" ] || extra='{}'
  path="$(marker_path "$1" "$2")"
  mkdir -p "$(dirname "$path")"
  python3 - "$path" "$2" "$3" "$extra" <<'PY'
import datetime, json, os, sys
path, step_id, evidence, extra = sys.argv[1:5]
record = {
    "step": step_id,
    "evidence": evidence,
    "recorded_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "owner": os.environ.get("MACPROVIDER_OPS_OWNER", ""),
}
record.update(json.loads(extra))
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(record, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(tmp, path)
PY
}

marker_field() { json_field "$(marker_path "$1" "$2")" "$3"; }

# --- output ---------------------------------------------------------------

emit_status() {
  python3 - "$OPS_NAME" "$OPS_FACTS" "$OPS_STEPS" <<'PY'
import datetime, json, os, sys
name, facts_path, steps_path = sys.argv[1:4]

def coerce(v):
    if v in ("true", "false"):
        return v == "true"
    if v == "":
        return None
    if v.lstrip("-").isdigit() and len(v) < 16:
        return int(v)
    return v

facts = {}
for line in open(facts_path):
    k, _, v = line.rstrip("\n").partition("\t")
    facts[k] = coerce(v)
steps = []
for line in open(steps_path):
    parts = line.rstrip("\n").split("\t")
    parts += [""] * (3 - len(parts))
    steps.append({"id": parts[0], "state": parts[1], "note": parts[2]})
env = os.environ
nxt = {
    "id": env.get("NEXT_ID", ""),
    "title": env.get("NEXT_TITLE", ""),
    "kind": env.get("NEXT_KIND", ""),
    "command": env.get("NEXT_CMD", ""),
    "reason": env.get("NEXT_REASON", ""),
    "pearl_mutating": bool(env.get("NEXT_DOWNTIME", "")),
    "expected_downtime": env.get("NEXT_DOWNTIME", "") or None,
    "runbook": env.get("NEXT_RUNBOOK", ""),
}
doc = {
    "train": name,
    "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "facts": facts,
    "steps": steps,
    "next": nxt,
}
print(json.dumps(doc, sort_keys=True))
w = sys.stderr
w.write("\n== %s status ==\n" % name)
width = max([len(k) for k in facts] + [4])
for k in sorted(facts):
    v = facts[k]
    w.write("  %-*s  %s\n" % (width, k, "" if v is None else (json.dumps(v) if isinstance(v, bool) else v)))
w.write("\n  steps (runbook order):\n")
for s in steps:
    w.write("    [%-11s] %s%s\n" % (s["state"], s["id"], (" - " + s["note"]) if s["note"] else ""))
w.write("\n  NEXT: %s (%s) %s\n" % (nxt["id"] or "-", nxt["kind"] or "-", nxt["title"]))
if nxt["reason"]:
    w.write("    reason:   %s\n" % nxt["reason"])
if nxt["expected_downtime"]:
    w.write("    downtime: %s\n" % nxt["expected_downtime"])
if nxt["runbook"]:
    w.write("    runbook:  %s\n" % nxt["runbook"])
if nxt["command"]:
    w.write("    command:\n")
    for line in nxt["command"].splitlines():
        w.write("      %s\n" % line)
PY
}

export_next() {
  export NEXT_ID NEXT_TITLE NEXT_KIND NEXT_CMD NEXT_REASON NEXT_DOWNTIME NEXT_RUNBOOK
}

# --- next / next --run ----------------------------------------------------

print_next() {
  printf '# next: %s (%s) %s\n' "${NEXT_ID:--}" "${NEXT_KIND:--}" "$NEXT_TITLE"
  [ -z "$NEXT_REASON" ] || printf '# reason: %s\n' "$NEXT_REASON"
  [ -z "$NEXT_DOWNTIME" ] || printf '# EXPECTED DOWNTIME: %s\n' "$NEXT_DOWNTIME"
  [ -z "$NEXT_RUNBOOK" ] || printf '# runbook: %s\n' "$NEXT_RUNBOOK"
  [ -z "$NEXT_CMD" ] || printf '%s\n' "$NEXT_CMD"
}

run_next() {
  case "$NEXT_KIND" in
    done) log "train complete; nothing to run"; return 0 ;;
    blocked) print_next; refuse "precondition failed: $NEXT_REASON" ;;
    manual)
      print_next
      refuse "step '$NEXT_ID' is operator-owned; run the command above after operator approval, then record it with: $0 next --done $NEXT_ID --evidence '<what proves it>'" ;;
    read|mutate) ;;
    *) die "internal: unknown next kind '$NEXT_KIND'" ;;
  esac
  [ -n "$NEXT_CMD" ] || die "internal: step $NEXT_ID has no command"
  if [ -n "$NEXT_DOWNTIME" ]; then
    # Downtime first, before the lock or any command (pearl-coordinator-rollout.md rule 1).
    printf '=== EXPECTED DOWNTIME for %s: %s ===\n' "$NEXT_ID" "$NEXT_DOWNTIME"
  fi
  if [ "$NEXT_KIND" = "mutate" ] || [ "${OPS_REQUIRE_CLEAN_FOR_ALL:-0}" = 1 ]; then
    require_clean_origin_main
  fi
  if [ "$NEXT_KIND" = "mutate" ]; then
    [ -n "${MACPROVIDER_OPS_OWNER:-}" ] ||
      refuse "MACPROVIDER_OPS_OWNER is unset; name the session that will hold the live-ops lock"
    # --bind-pid: this process owns the lock, so a dead pid frees it.
    "$OPS_DIR/live-lock.sh" acquire "$MACPROVIDER_OPS_OWNER" --purpose "$OPS_NAME:$NEXT_ID" --bind-pid >&2 ||
      refuse "live-ops lock not acquired; see '$OPS_DIR/live-lock.sh status'"
    OPS_LOCK_OWNER="$MACPROVIDER_OPS_OWNER"
    # State may have moved while we waited for the lock: decide again and run
    # only if the same step with the same command is still next.
    local want_id="$NEXT_ID" want_cmd="$NEXT_CMD"
    reset_state
    gather
    if [ "$NEXT_ID" != "$want_id" ] || [ "$NEXT_CMD" != "$want_cmd" ]; then
      refuse "live state changed after taking the lock: next is now '$NEXT_ID' ($NEXT_KIND), not '$want_id'; run status again"
    fi
  fi
  print_next
  export MACPROVIDER_OPS_ENTRYPOINT=1
  local rc=0
  (cd "$REPO_ROOT" && bash -euo pipefail -c "$NEXT_CMD") || rc=$?
  if [ "$rc" -ne 0 ]; then
    log "step $NEXT_ID exited $rc; not recorded as done"
    return "$rc"
  fi
  if [ -n "$NEXT_MARK" ] && ! marker_done "$OPS_SCOPE" "$NEXT_MARK"; then
    mark_done "$OPS_SCOPE" "$NEXT_MARK" "ran: $NEXT_ID"
  fi
  log "step $NEXT_ID completed; re-run '$0 status' for the next step"
}

reset_state() {
  : > "$OPS_FACTS"
  : > "$OPS_STEPS"
  NEXT_ID=""; NEXT_TITLE=""; NEXT_KIND=""; NEXT_CMD=""; NEXT_REASON=""
  NEXT_DOWNTIME=""; NEXT_RUNBOOK=""; NEXT_MARK=""
}

# Mutating steps run only from a clean checkout of the exact origin/main tip,
# so the commands and runbook constants are the reviewed ones.
require_clean_origin_main() {
  local head main dirty
  main="$(origin_main_sha)"
  head="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
  [ -n "$main" ] && [ "$head" = "$main" ] ||
    refuse "checkout HEAD ${head:-?} is not origin/main ${main:-?}; run from a fresh worktree at origin/main"
  dirty="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | head -n 5)"
  [ -z "$dirty" ] || refuse "working tree is not clean: $(printf '%s' "$dirty" | tr '\n' ' ')"
}

# Shared CLI: status | next [--run] | next --done STEP --evidence TEXT
ops_main() {
  local cmd="${1:-status}"
  shift || true
  case "$cmd" in
    status)
      gather
      export_next
      emit_status
      ;;
    next)
      local run=0 done_step="" evidence=""
      DONE_RUN_IDS=""; DONE_CARRY=""; DONE_PROBE=0
      while [ $# -gt 0 ]; do
        case "$1" in
          --run) run=1 ;;
          --done) done_step="${2:-}"; shift ;;
          --evidence) evidence="${2:-}"; shift ;;
          --run-id) DONE_RUN_IDS="$DONE_RUN_IDS ${2:-}"; shift ;;
          --carry-forward) DONE_CARRY="${2:-}"; shift ;;
          --probe) DONE_PROBE=1 ;;
          *) die "unknown next option: $1" ;;
        esac
        shift
      done
      DONE_RUN_IDS="${DONE_RUN_IDS# }"
      gather
      if [ -n "$done_step" ]; then
        [ "$done_step" = "$NEXT_ID" ] || refuse "can only record the current next step ($NEXT_ID), not $done_step"
        [ "$NEXT_KIND" = "manual" ] || refuse "only operator-owned (manual) steps are recorded by hand; $NEXT_ID is $NEXT_KIND"
        if [[ " ${STRUCTURED_STEPS:-} " == *" $done_step "* ]]; then
          [ -z "$evidence" ] || refuse "$done_step does not accept free-text --evidence; use --run-id, --carry-forward or --probe"
          structured_done "$done_step"
          return 0
        fi
        [ -z "$DONE_RUN_IDS$DONE_CARRY" ] && [ "$DONE_PROBE" = 0 ] ||
          refuse "--run-id/--carry-forward/--probe apply only to: ${STRUCTURED_STEPS:-none}"
        [ -n "$evidence" ] || refuse "--evidence is required"
        mark_done "$OPS_SCOPE" "$done_step" "$evidence"
        log "recorded $done_step as done in $(marker_path "$OPS_SCOPE" "$done_step")"
        return 0
      fi
      if [ "$run" -eq 1 ]; then
        run_next
      else
        print_next
      fi
      ;;
    -h|--help|help) usage ;;
    _*) internal "$cmd" "$@" ;;
    *) usage >&2; exit 2 ;;
  esac
}

# shellcheck source=lib/runbook-commands.sh
. "$OPS_LIB_DIR/runbook-commands.sh"

# render_runbook TEXT [VERSION]: fill the host placeholders of a runbook
# constant (lib/runbook-commands.sh) with the configured targets.
render_runbook() {
  local text="$1" ver="${2:-}" url="${COORDINATOR_URL:-}"
  if [[ "$text" == *"<coordinator-url>"* ]]; then
    [[ "$url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || die "COORDINATOR_URL must be https://host[:port] to render this runbook command"
    text="${text//<coordinator-url>/$url}"
  fi
  text="${text//<pearl-ssh>/\"\$PEARL_SSH\"}"
  if [ -n "$ver" ]; then
    is_semver "$ver" || die "render_runbook: bad version $ver"
    text="${text//<ver>/$ver}"
  fi
  printf '%s\n' "$text"
}

# next_meta ID RUNBOOK [DOWNTIME] [MARK]: attach metadata only when ID is the chosen next step.
next_meta() {
  [ "$NEXT_ID" = "$1" ] || return 0
  NEXT_RUNBOOK="$2"
  NEXT_DOWNTIME="${3-}"
  NEXT_MARK="${4-}"
}
