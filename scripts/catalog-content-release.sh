#!/usr/bin/env bash
# Ship a reviewed catalog-content release to Pearl WITHOUT a runtime binary
# release (#1688 PR-C, C4-C7). Operator-local; noninteractive; bash 3.2.
#
# The release is assembled from `git archive <commit>` (never the working
# tree), judged by `catalog-release.py content-gate` against the LIVE release
# (lane must be catalog-content), dry-loaded by the live coordinator binary on
# Pearl, and activated through scripts/lib/autotune-activate.sh under the SAME
# Pearl lease a coordinator deploy holds. Post-activation evidence failures
# roll back exactly (current + .previous-target + re-HUP) and restart the
# canary onto the prior release.
#
# Usage:
#   scripts/catalog-content-release.sh --preflight --commit <40-hex sha>
#   scripts/catalog-content-release.sh --deploy    --commit <40-hex sha>
#   scripts/catalog-content-release.sh --help
#
# --preflight prints exactly ONE JSON verdict on stdout
#   {"go": bool, "checks": [{"name", "ok", "detail"}]}; progress goes to stderr.
# --deploy runs the same preflight in the same invocation (its JSON verdict
#   line is printed to stdout among the step logs), requires GO, then
#   activates and verifies; every step logs to stdout.
#
# Exit codes:
#   0   preflight GO / deploy activated and every evidence step passed
#   1   usage, environment or operational error (no activation, or before it)
#   3   preflight NO_GO (nothing was mutated)
#   4   deploy activated, evidence failed, rolled back to the prior release
#   5   rollback incomplete: follow docs/runbooks/catalog-release-decision-tree.md §rollback-failed
#   71  interrupted or lease lost (rolled back first when already activated)
#
# Env:
#   PEARL_SSH, PEARL_SSH_IDENTITY, PEARL_SSH_KNOWN_HOSTS   as renew-autotune-static-feed.sh
#   REMOTE_AUTOTUNE_DIR       default /opt/macprovider/autotune
#   COORDINATOR_UNIT          default macprovider-coordinator
#   CATALOG_CANARY_PROVIDER_ID, CATALOG_CANARY_SSH_TARGET, CATALOG_CANARY_SSH_KEY,
#   CATALOG_CANARY_INSTALL_DIR, CATALOG_CANARY_AUTH_TOKEN[_FILE|_KEYCHAIN_*]
#                             as deploy-pearl-vps.sh; the token must be the
#                             coordinator operator key (proved by digest only)
#   CATALOG_WINDOW_OVERRIDE_REASON  logged reason to activate although /poolz
#                             shows a connected provider would be stranded
#   CATALOG_EVIDENCE_WATCH_SECONDS  (d) watch window, default 600
#   CATALOG_EVIDENCE_POLL_SECONDS   (d) poll interval, default 30
#   CATALOG_CANARY_RECOVERY_SECONDS (c) canary proof deadline, default 180
#   CATALOG_EVIDENCE_SETTLE_SECONDS (a)/(b)/rollback convergence deadline, default 30
#   AA_LEASE_MAX_SECONDS      lease bound, default 2700 for this lane
#
# Secrets (the canary/operator bearer) only ever ride curl --config on stdin;
# they are never printed, written to disk, or put in argv.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
RUNBOOK_ROLLBACK_FAILED="docs/runbooks/catalog-release-decision-tree.md §rollback-failed"

usage() { sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }

MODE=""
COMMIT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --preflight) [ -z "$MODE" ] || { echo "choose one of --preflight / --deploy" >&2; exit 1; }; MODE=preflight ;;
    --deploy) [ -z "$MODE" ] || { echo "choose one of --preflight / --deploy" >&2; exit 1; }; MODE=deploy ;;
    --commit) [ $# -ge 2 ] || { echo "--commit needs a value" >&2; exit 1; }; COMMIT="$2"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "unknown argument: $1 (see --help)" >&2; exit 1 ;;
  esac
  shift
done
[ -n "$MODE" ] || { echo "one of --preflight or --deploy is required (see --help)" >&2; exit 1; }

# Preflight keeps stdout for the single JSON verdict; deploy logs to stdout.
if [ "$MODE" = preflight ]; then exec 3>&2; else exec 3>&1; fi
CCR_FATAL_RC=1
log()   { printf '[catalog-content] %s\n' "$*" >&3; }
fatal() { printf '[catalog-content] ERROR: %s\n' "$*" >&2; exit "$CCR_FATAL_RC"; }

PEARL_SSH="${PEARL_SSH:-pearl}"
REMOTE_AUTOTUNE_DIR="${REMOTE_AUTOTUNE_DIR:-/opt/macprovider/autotune}"
COORDINATOR_UNIT="${COORDINATOR_UNIT:-macprovider-coordinator}"
case "$REMOTE_AUTOTUNE_DIR" in /*) ;; *) fatal "REMOTE_AUTOTUNE_DIR must be absolute" ;; esac
case "$REMOTE_AUTOTUNE_DIR" in *[!A-Za-z0-9._/-]*|*/../*|*/..) fatal "unsafe REMOTE_AUTOTUNE_DIR: $REMOTE_AUTOTUNE_DIR" ;; esac
case "$COORDINATOR_UNIT" in ""|*[!A-Za-z0-9@._-]*) fatal "unsafe COORDINATOR_UNIT: $COORDINATOR_UNIT" ;; esac
case "$PEARL_SSH" in ""|*[!A-Za-z0-9._@-]*) fatal "unsafe PEARL_SSH: $PEARL_SSH" ;; esac
# The same fixed paths the coordinator unit uses (phase4-coordinator/dist/macprovider-coordinator.service).
COORD_BIN=/opt/macprovider/coordinator
COORD_CONFIG=/opt/macprovider/coordinator.yaml
COORD_OVERLAY=/etc/macprovider/coordinator.pearl-overlays.yaml
COORD_ENV_FILE=/etc/macprovider/coordinator.env
BUYER_URL=http://127.0.0.1:8443
PROVIDER_URL=http://127.0.0.1:8444

WATCH_SECONDS="${CATALOG_EVIDENCE_WATCH_SECONDS:-600}"
POLL_SECONDS="${CATALOG_EVIDENCE_POLL_SECONDS:-30}"
CANARY_RECOVERY_SECONDS="${CATALOG_CANARY_RECOVERY_SECONDS:-180}"
SETTLE_SECONDS="${CATALOG_EVIDENCE_SETTLE_SECONDS:-30}"
INCOMPATIBLE_BASELINE_SECONDS=3600
for _n in "$WATCH_SECONDS" "$POLL_SECONDS" "$CANARY_RECOVERY_SECONDS" "$SETTLE_SECONDS"; do
  case "$_n" in ""|*[!0-9]*) fatal "CATALOG_EVIDENCE_*/CATALOG_CANARY_RECOVERY_SECONDS must be whole seconds" ;; esac
done
[ "$POLL_SECONDS" -ge 1 ] || fatal "CATALOG_EVIDENCE_POLL_SECONDS must be at least 1"
export AA_LEASE_MAX_SECONDS="${AA_LEASE_MAX_SECONDS:-2700}"

CATALOG_CANARY_PROVIDER_ID="${CATALOG_CANARY_PROVIDER_ID:-}"
CATALOG_CANARY_AUTH_TOKEN="${CATALOG_CANARY_AUTH_TOKEN:-}"
CATALOG_CANARY_AUTH_TOKEN_FILE="${CATALOG_CANARY_AUTH_TOKEN_FILE:-}"
CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_SERVICE="${CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_SERVICE:-macprovider.catalog-canary.operator-token}"
CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_ACCOUNT="${CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_ACCOUNT:-${USER:-}}"
CATALOG_CANARY_SSH_TARGET="${CATALOG_CANARY_SSH_TARGET:-}"
CATALOG_CANARY_SSH_KEY="${CATALOG_CANARY_SSH_KEY:-$HOME/.ssh/macprovider_canary_ed25519}"
CATALOG_CANARY_INSTALL_DIR="${CATALOG_CANARY_INSTALL_DIR:-macprovider/catalog-release}"
CATALOG_WINDOW_OVERRIDE_REASON="${CATALOG_WINDOW_OVERRIDE_REASON:-}"

# SSH to Pearl exactly as renew does.
SSH_OPTS=(-o ConnectTimeout=15 -o BatchMode=yes)
if [ -n "${PEARL_SSH_IDENTITY:-}" ]; then
  case "$PEARL_SSH_IDENTITY" in *[!A-Za-z0-9._/+=@-]*) fatal "unsafe PEARL_SSH_IDENTITY path" ;; esac
  [ -f "$PEARL_SSH_IDENTITY" ] || fatal "PEARL_SSH_IDENTITY is not a file"
  identity_mode="$(stat -f '%A' "$PEARL_SSH_IDENTITY" 2>/dev/null || stat -c '%a' "$PEARL_SSH_IDENTITY" 2>/dev/null || echo '')"
  case "$identity_mode" in 600|400) ;; *) fatal "PEARL_SSH_IDENTITY has permissions $identity_mode; expected 0600 or 0400" ;; esac
  PEARL_SSH_KNOWN_HOSTS="${PEARL_SSH_KNOWN_HOSTS:-$SCRIPT_DIR/dist/malibu-download-known_hosts}"
  case "$PEARL_SSH_KNOWN_HOSTS" in ""|*[!A-Za-z0-9._/+=@-]*) fatal "unsafe PEARL_SSH_KNOWN_HOSTS path" ;; esac
  [ -f "$PEARL_SSH_KNOWN_HOSTS" ] || fatal "PEARL_SSH_KNOWN_HOSTS is not a file"
  SSH_OPTS+=(-i "$PEARL_SSH_IDENTITY" -o IdentitiesOnly=yes -o "UserKnownHostsFile=$PEARL_SSH_KNOWN_HOSTS" -o StrictHostKeyChecking=yes -p 22)
fi
SSH() { ssh "${SSH_OPTS[@]}" "$PEARL_SSH" "$@"; }
RSYNC_RSH="ssh"
for _ssh_opt in "${SSH_OPTS[@]}"; do RSYNC_RSH="$RSYNC_RSH $_ssh_opt"; done

# shellcheck source=scripts/lib/autotune-activate.sh
. "$SCRIPT_DIR/lib/autotune-activate.sh"
# shellcheck source=scripts/lib/catalog-canary-token.sh
. "$SCRIPT_DIR/lib/catalog-canary-token.sh"
# shellcheck source=scripts/lib/catalog-window-override.sh
. "$SCRIPT_DIR/lib/catalog-window-override.sh"

command -v git >/dev/null 2>&1 || fatal "git is required"
command -v python3 >/dev/null 2>&1 || fatal "python3 is required"

WORK="$(umask 077 && mktemp -d -t macprovider-catalog-content.XXXXXXXX)"
AA_WORK_DIR="$WORK/aa"
mkdir -m 0700 "$AA_WORK_DIR"
REL="$WORK/release"
LIVE="$WORK/live"
CHECKS="$WORK/checks.tsv"
: >"$CHECKS"
REMOTE_SCRATCH=""
CCR_ACTIVATED=0
CCR_DONE=0
CCR_ROLLED_BACK=0
CCR_CANARY_TOUCHED=0
CCR_PASSED_AB=0
CCR_FAILED_STEP=""
T_HUP=""
T_RB=""
CANARY_CATALOG_KEY=""
GATE_LANE=""
RELEASE_DIRNAME=""

ccr_cleanup() {
  local rc=$?
  trap - EXIT
  set +e
  if [ "$CCR_ACTIVATED" = 1 ] && [ "$CCR_DONE" = 0 ] && [ "$CCR_ROLLED_BACK" = 0 ]; then
    log "run ended (rc=$rc) after activation without an evidence verdict; rolling back"
    CCR_FAILED_STEP="${CCR_FAILED_STEP:-interrupted}"
    T_RB="$(remote_now 2>/dev/null || echo "$T_HUP")"
    aa_rollback
    if [ "$CCR_FATAL_RC" = 5 ]; then rc=5; fi
  fi
  aa_lease_release
  if [ -n "$REMOTE_SCRATCH" ]; then SSH "rm -rf '$REMOTE_SCRATCH'" >/dev/null 2>&1 || true; fi
  aa_cleanup_remote_helpers
  rm -rf "$WORK"
  exit "$rc"
}
trap ccr_cleanup EXIT

# ---------------------------------------------------------------------------
# Small helpers.
# ---------------------------------------------------------------------------
sha256_file() { python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

# record <name> <0|1> <detail>: one preflight check row.
record() {
  local detail
  detail="$(printf '%s' "$3" | LC_ALL=C tr -c '[:print:]' ' ' | cut -c1-600)"
  printf '%s\t%s\t%s\n' "$1" "$2" "$detail" >>"$CHECKS"
  if [ "$2" = 1 ]; then log "check $1: ok ($detail)"; else log "check $1: FAIL ($detail)"; fi
}
failed_checks() { awk -F '\t' '$2 != 1 {print $1}' "$CHECKS"; }
check_ok() { awk -F '\t' -v n="$1" '$1 == n && $2 == 1 {found=1} END {exit found ? 0 : 1}' "$CHECKS"; }

emit_verdict() {
  python3 - "$CHECKS" <<'PY'
import json, sys
checks = []
for line in open(sys.argv[1], encoding="utf-8"):
    name, ok, detail = line.rstrip("\n").split("\t", 2)
    checks.append({"name": name, "ok": ok == "1", "detail": detail})
print(json.dumps({"go": bool(checks) and all(c["ok"] for c in checks), "checks": checks}, sort_keys=True))
PY
}

# release_identity <dir> <prefix>: sets <prefix>_ID/_POLICY/_CAND_SHA/_SIGNER/
# _TIER2_ID/_TIER2_SHA/_BOUND from release.json + tier2-catalog.json bytes.
release_identity() {
  local out
  out="$(python3 - "$1" <<'PY'
import hashlib, json, pathlib, re, sys
d = pathlib.Path(sys.argv[1])
m = json.loads((d / "release.json").read_bytes())
cand = m["feeds"]["autotune-candidates.json"]
t2 = (d / "tier2-catalog.json").read_bytes()
vals = [m["release_id"], m["policy_version"], cand["sha256"], cand["signer_key_id"],
        json.loads(t2)["catalog_id"], hashlib.sha256(t2).hexdigest(),
        "bound" if "autotune-artifacts.json" in m["feeds"] else "unbound"]
for v in vals:
    if not isinstance(v, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:+-]{0,191}", v):
        raise SystemExit(f"unsafe release identity field: {v!r}")
print(" ".join(vals))
PY
)" || return 1
  # shellcheck disable=SC2034
  read -r "${2}_ID" "${2}_POLICY" "${2}_CAND_SHA" "${2}_SIGNER" "${2}_TIER2_ID" "${2}_TIER2_SHA" "${2}_BOUND" <<EOF
$out
EOF
}

# The content-addressed release directory name deploy-pearl-vps.sh uses, so a
# later runtime deploy of the same bytes recognises this release.
release_dirname() {
  python3 - "$1" <<'PY'
import hashlib, json, pathlib, sys
d = pathlib.Path(sys.argv[1])
names = ["release.json", "trusted-keys.json", "tier2-catalog.json",
         "autotune-candidates.json", "autotune-candidates.json.sig",
         "demand-rank.json", "demand-rank.json.sig", "rate-card.json", "rate-card.json.sig"]
if "autotune-artifacts.json" in json.loads((d / "release.json").read_bytes())["feeds"]:
    names += ["autotune-artifacts.json", "autotune-artifacts.json.sig"]
h = hashlib.sha256()
for n in names:
    h.update(n.encode()); h.update(b"\0")
    h.update(hashlib.sha256((d / n).read_bytes()).hexdigest().encode("ascii")); h.update(b"\n")
print(json.loads((d / "release.json").read_bytes())["release_id"] + "-" + h.hexdigest()[:16])
PY
}

# fetch_poolz <out>: coordinator /poolz over Pearl loopback; bearer on stdin.
fetch_poolz() {
  local raw="$WORK/poolz.raw" status
  printf 'header = "Authorization: Bearer %s"\n' "$CATALOG_CANARY_AUTH_TOKEN" |
    SSH "curl --config - -sS --noproxy '*' --max-time 10 --max-filesize 16777216 -w '\n%{http_code}' $PROVIDER_URL/poolz" >"$raw" 2>/dev/null || return 1
  status="$(tail -n 1 "$raw")"
  [ "$status" = 200 ] || return 1
  sed '$d' "$raw" >"$1"
}

# coord_get <path> <out>: GET from the coordinator buyer mux on Pearl loopback
# (not the gateway, not nginx). Non-2xx fails.
coord_get() {
  SSH "curl -fsS --noproxy '*' --max-time 10 --max-filesize 16777216 $BUYER_URL$1" >"$2" 2>/dev/null
}

journal_since() { # <epoch> <out>: coordinator journal messages since epoch
  SSH "journalctl -u '$COORDINATOR_UNIT' --since '@$1' -o cat --no-pager" >"$2" 2>/dev/null
}
journal_between() { # <from-epoch> <until-epoch> <out>
  SSH "journalctl -u '$COORDINATOR_UNIT' --since '@$1' --until '@$2' -o cat --no-pager" >"$3" 2>/dev/null
}

remote_now() { SSH 'date +%s'; }

# ---------------------------------------------------------------------------
# Canary (deploy-pearl-vps.sh custody checks, via the updater's standalone
# copy ops/pearl-updater/catalog-canary-proof.py streamed over pinned SSH).
# ---------------------------------------------------------------------------
CANARY_PROOF_PY="$REPO_ROOT/ops/pearl-updater/catalog-canary-proof.py"
CANARY_SSH=(ssh -i "$CATALOG_CANARY_SSH_KEY" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes
  -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 "$CATALOG_CANARY_SSH_TARGET")

# canary_proof <prefix-of-identity> <out>: exact live process + local status
# proof for the selected provider. The installed-byte comparison deploy does
# is intentionally not applied (a content release does not reinstall the app).
canary_proof() {
  local id policy digest signer
  eval "id=\$${1}_ID policy=\$${1}_POLICY digest=\$${1}_CAND_SHA signer=\$${1}_SIGNER"
  "${CANARY_SSH[@]}" python3 - "$CATALOG_CANARY_INSTALL_DIR" "$CATALOG_CANARY_PROVIDER_ID" \
    "$id" "$policy" "$digest" "$signer" <"$CANARY_PROOF_PY" >"$2" 2>"$2.err"
}

canary_proof_field() { # <proof> <python expr over p>
  python3 - "$1" "$2" <<'PY'
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
print(eval(sys.argv[2], {"p": p}))
PY
}

# ---------------------------------------------------------------------------
# Preflight.
# ---------------------------------------------------------------------------
TOOLING_FILES="scripts/catalog-content-release.sh scripts/lib/autotune-activate.sh scripts/lib/catalog-canary-token.sh scripts/pearl_autotune_deploy_lock.py scripts/catalog-verifier-bundle.txt ops/pearl-updater/catalog-canary-proof.py"

pf_commit() {
  case "$COMMIT" in
    *[!0-9a-f]*|"") record commit 0 "--commit must be a full 40-hex lowercase sha"; return 1 ;;
  esac
  [ "${#COMMIT}" -eq 40 ] || { record commit 0 "--commit must be a full 40-hex lowercase sha"; return 1; }
  git -C "$REPO_ROOT" cat-file -e "$COMMIT^{commit}" 2>/dev/null || { record commit 0 "commit $COMMIT is not in this repository (git fetch origin?)"; return 1; }
  git -C "$REPO_ROOT" merge-base --is-ancestor "$COMMIT" origin/main 2>/dev/null ||
    { record commit 0 "commit $COMMIT is not an ancestor of origin/main"; return 1; }
  record commit 1 "$COMMIT is on origin/main"
}

# The tooling that runs must be the reviewed tooling at the commit.
pf_tooling() {
  local f mismatched="" bundle
  bundle="$(git -C "$REPO_ROOT" show "$COMMIT:scripts/catalog-verifier-bundle.txt" 2>/dev/null | grep -v '^#' | grep -v '^$' || true)"
  for f in $TOOLING_FILES $bundle scripts/autotune_window.py; do
    if ! git -C "$REPO_ROOT" show "$COMMIT:$f" 2>/dev/null | cmp -s - "$REPO_ROOT/$f"; then
      mismatched="$mismatched $f"
    fi
  done
  if [ -n "$mismatched" ]; then
    record tooling_matches_commit 0 "working tree differs from $COMMIT for:$mismatched (check out the commit's tooling)"
    return 1
  fi
  record tooling_matches_commit 1 "release tooling is byte-equal to $COMMIT"
}

pf_assemble() {
  local a="$WORK/archive" name
  mkdir -p "$a" "$REL" "$WORK/gate"
  if ! git -C "$REPO_ROOT" archive --format=tar "$COMMIT" phase3-binary/catalog/autotune phase3-binary/dist/static | tar -xf - -C "$a"; then
    record release_assembled 0 "git archive $COMMIT failed"; return 1
  fi
  for name in release.json trusted-keys.json tier2-catalog.json; do
    cp "$a/phase3-binary/catalog/autotune/$name" "$REL/$name" || { record release_assembled 0 "commit lacks $name"; return 1; }
  done
  for name in autotune-candidates.json autotune-candidates.json.sig demand-rank.json demand-rank.json.sig rate-card.json rate-card.json.sig; do
    cp "$a/phase3-binary/dist/static/$name" "$REL/$name" || { record release_assembled 0 "commit lacks dist/static/$name"; return 1; }
  done
  release_identity "$REL" REL || { record release_assembled 0 "release.json/tier2-catalog.json identity is malformed"; return 1; }
  if [ "$REL_BOUND" = bound ]; then
    for name in autotune-artifacts.json autotune-artifacts.json.sig; do
      cp "$a/phase3-binary/dist/static/$name" "$REL/$name" || { record release_assembled 0 "release.json binds $name but the commit lacks it"; return 1; }
    done
  fi
  cp "$a/phase3-binary/catalog/autotune/release-ledger.json" "$WORK/gate/release-ledger.json" 2>/dev/null &&
    cp "$a/phase3-binary/catalog/autotune/not-buyer-serving.json" "$WORK/gate/not-buyer-serving.json" 2>/dev/null ||
    { record release_assembled 0 "commit lacks release-ledger.json or not-buyer-serving.json"; return 1; }
  if ! python3 -I "$SCRIPT_DIR/catalog-release.py" verify-directory --directory "$REL" >"$WORK/verify.out" 2>&1; then
    record release_assembled 0 "verify-directory failed: $(tail -n 3 "$WORK/verify.out")"; return 1
  fi
  RELEASE_DIRNAME="$(release_dirname "$REL")" || { record release_assembled 0 "cannot derive the release directory name"; return 1; }
  case "$RELEASE_DIRNAME" in
    [A-Za-z0-9]*) ;;
    *) record release_assembled 0 "unsafe release directory name: $RELEASE_DIRNAME"; return 1 ;;
  esac
  case "$RELEASE_DIRNAME" in *[!A-Za-z0-9._-]*) record release_assembled 0 "unsafe release directory name: $RELEASE_DIRNAME"; return 1 ;; esac
  record release_assembled 1 "release $REL_ID from $COMMIT verifies (dir $RELEASE_DIRNAME)"
}

pf_canary_config() {
  # deploy's loader exits on an unreadable token file; judge the file first so
  # preflight can report it as a check instead of dying without a verdict.
  if [ -z "$CATALOG_CANARY_AUTH_TOKEN" ] && [ -n "$CATALOG_CANARY_AUTH_TOKEN_FILE" ]; then
    CATALOG_CANARY_AUTH_TOKEN="$(_catalog_canary_auth_token_from_file "$CATALOG_CANARY_AUTH_TOKEN_FILE" 2>/dev/null)" ||
      { CATALOG_CANARY_AUTH_TOKEN=""; record canary_config 0 "CATALOG_CANARY_AUTH_TOKEN_FILE is not a safe single-line 0600 token file"; return 1; }
  fi
  _load_catalog_canary_auth_token >&3 2>&1
  if ! printf '%s' "$CATALOG_CANARY_PROVIDER_ID" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'; then
    record canary_config 0 "CATALOG_CANARY_PROVIDER_ID is required and must be a safe provider ID"; return 1
  fi
  if ! _validate_catalog_canary_auth_token "$CATALOG_CANARY_AUTH_TOKEN"; then
    record canary_config 0 "CATALOG_CANARY_AUTH_TOKEN (env, _FILE or Keychain) is required and must be a safe 32-512 character bearer token"; return 1
  fi
  if ! printf '%s' "$CATALOG_CANARY_SSH_TARGET" | grep -Eq '^([A-Za-z_][A-Za-z0-9._-]*@)?[A-Za-z0-9]([A-Za-z0-9.-]{0,252}[A-Za-z0-9])?$'; then
    record canary_config 0 "CATALOG_CANARY_SSH_TARGET is required and must be a safe SSH target"; return 1
  fi
  if [ ! -f "$CATALOG_CANARY_SSH_KEY" ] || [ ! -r "$CATALOG_CANARY_SSH_KEY" ]; then
    record canary_config 0 "CATALOG_CANARY_SSH_KEY is not a readable regular file"; return 1
  fi
  if ! printf '%s' "$CATALOG_CANARY_INSTALL_DIR" | grep -Eq '^[A-Za-z0-9._/-]+$' ||
     printf '%s' "/$CATALOG_CANARY_INSTALL_DIR/" | grep -Eq '/\.\.?/'; then
    record canary_config 0 "CATALOG_CANARY_INSTALL_DIR must be a safe path without parent traversal"; return 1
  fi
  record canary_config 1 "provider $CATALOG_CANARY_PROVIDER_ID via $CATALOG_CANARY_SSH_TARGET"
}

pf_override() {
  [ -n "$CATALOG_WINDOW_OVERRIDE_REASON" ] || return 0
  case "$CATALOG_WINDOW_OVERRIDE_REASON" in
    *$'\n'*|*$'\r'*) record window_override 0 "CATALOG_WINDOW_OVERRIDE_REASON must be a single line"; return 1 ;;
  esac
  if ! printf '%s' "$CATALOG_WINDOW_OVERRIDE_REASON" | LC_ALL=C grep -Eq '^[ -~]{1,200}$'; then
    record window_override 0 "CATALOG_WINDOW_OVERRIDE_REASON must be 1-200 printable ASCII characters"; return 1
  fi
  record window_override 1 "coverage override requested: $CATALOG_WINDOW_OVERRIDE_REASON"
}

# Pearl reachable; live targets well-formed; no deploy/renew/update lock held.
pf_pearl() {
  local out
  if ! out="$( (aa_read_live_targets && printf '%s\n' "$CURRENT_TARGET" && printf '%s' "$ORIG_PREVIOUS_TARGET") 2>&1)"; then
    record pearl_reachable 0 "cannot read live autotune targets on $PEARL_SSH: $out"; return 1
  fi
  CURRENT_TARGET="$(printf '%s\n' "$out" | sed -n 1p)"
  ORIG_PREVIOUS_TARGET="$(printf '%s\n' "$out" | sed -n '2,$p')"
  record pearl_reachable 1 "current=$CURRENT_TARGET window=$(printf '%s' "$ORIG_PREVIOUS_TARGET" | tr '\n' ' ')"
  if SSH "test -e /var/lib/macprovider-pearl-updater/tier2-enforcement-transaction.json"; then
    record pearl_locks_free 0 "a Tier-2 enforcement transaction is active"; return 1
  fi
  if ! SSH "for l in /run/lock/macprovider-pearl-updater.lock /opt/macprovider/.coordinator-deploy.lock; do [ ! -e \"\$l\" ] || flock -n \"\$l\" true || exit 1; done"; then
    record pearl_locks_free 0 "a coordinator deploy, renewal or Pearl update holds the Pearl lock"; return 1
  fi
  record pearl_locks_free 1 "no deploy, renewal, update or Tier-2 transaction in progress"
}

# Fetch the LIVE release read-only and prove the rollback target verifies.
pf_live() {
  local entry missing=""
  mkdir -p "$LIVE"
  if ! SSH "tar -C '$REMOTE_AUTOTUNE_DIR/$CURRENT_TARGET' -cf - ." | tar -xf - -C "$LIVE"; then
    record rollback_preconditions 0 "cannot read the live release $CURRENT_TARGET"; return 1
  fi
  release_identity "$LIVE" LIVE || { record rollback_preconditions 0 "live release identity is malformed"; return 1; }
  if ! python3 -I "$SCRIPT_DIR/catalog-release.py" verify-directory --directory "$LIVE" >"$WORK/verify-live.out" 2>&1; then
    record rollback_preconditions 0 "live release $CURRENT_TARGET does not verify: $(tail -n 3 "$WORK/verify-live.out")"; return 1
  fi
  for entry in $ORIG_PREVIOUS_TARGET; do
    SSH "test -f '$REMOTE_AUTOTUNE_DIR/$entry/release.json'" || missing="$missing $entry"
  done
  [ -z "$missing" ] || { record rollback_preconditions 0 "retained releases missing on Pearl:$missing"; return 1; }
  if SSH "test -e '$REMOTE_AUTOTUNE_DIR/releases/$RELEASE_DIRNAME'"; then
    record rollback_preconditions 0 "releases/$RELEASE_DIRNAME already exists on Pearl"; return 1
  fi
  [ "$LIVE_ID" != "$REL_ID" ] || { record rollback_preconditions 0 "release $REL_ID is already live"; return 1; }
  record rollback_preconditions 1 "live $LIVE_ID ($CURRENT_TARGET) verifies; retained window present"
}

pf_content_gate() {
  local rc=0
  python3 -I "$SCRIPT_DIR/catalog-release.py" content-gate --release "$REL" --live "$LIVE" --commit "$COMMIT" \
    >"$WORK/gate.json" 2>"$WORK/gate.err" || rc=$?
  GATE_LANE="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("lane",""))' "$WORK/gate.json" 2>/dev/null || true)"
  if [ "$rc" -ne 0 ] || [ "$GATE_LANE" != catalog-content ]; then
    record content_gate 0 "content-gate rc=$rc lane=${GATE_LANE:-?}: $(python3 -c 'import json,sys;print("; ".join(json.load(open(sys.argv[1])).get("reasons",[])))' "$WORK/gate.json" 2>/dev/null || tail -n 2 "$WORK/gate.err")"
    return 1
  fi
  record content_gate 1 "lane catalog-content vs live $LIVE_ID"
}

pf_closure() {
  if ! python3 -I "$SCRIPT_DIR/catalog-release.py" check-tier2-binding --candidate "$REL/autotune-candidates.json" \
    --tier2 "$REL/tier2-catalog.json" --require-serving --rate-card "$REL/rate-card.json" \
    --exclusions "$WORK/gate/not-buyer-serving.json" >"$WORK/closure.out" 2>&1; then
    record serving_closure 0 "$(tail -n 2 "$WORK/closure.out")"; return 1
  fi
  record serving_closure 1 "every served model has a matching Tier-2 pin or a reviewed exclusion"
}

# (e) A Tier-2 pin new vs live that makes a recommendable model buyer-serving
# needs a strict-pin buyer request + settlement row. No reusable
# noninteractive production harness exists, so such releases are NO_GO here.
pf_buyer_serving_e2e() {
  local new
  new="$(python3 - "$REL" "$LIVE" "$WORK/gate/not-buyer-serving.json" <<'PY'
import json, pathlib, sys
rel, live = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
excluded = {m["model_id"].lower().strip() for m in json.load(open(sys.argv[3]))["models"]}
def pins(d):
    return {(m["model_id"].lower().strip(), m["sha256"].lower()) for m in json.loads((d / "tier2-catalog.json").read_bytes())["models"]}
rows = json.loads((rel / "autotune-candidates.json").read_bytes())["rows"]
serving = {(r["model_id"].lower().strip(), str(r.get("model_sha256", "")).lower())
           for r in rows.values() if r.get("runtime_status") == "recommendable"}
new = sorted(m for m, s in (pins(rel) - pins(live)) if (m, s) in serving and m not in excluded)
print(" ".join(new))
PY
)" || { record buyer_serving_e2e 0 "cannot compare Tier-2 pins with live"; return 1; }
  if [ -n "$new" ]; then
    record buyer_serving_e2e 0 "new buyer-serving Tier-2 pin(s) vs live: $new; a strict-pin buyer request + settlement row is required and no noninteractive harness exists (ship via the runtime lane with its E2E)"
    return 1
  fi
  record buyer_serving_e2e 1 "no new buyer-serving Tier-2 pin vs live"
}

# Stage the candidate in a private scratch mirror of the live root on Pearl
# (never under $REMOTE_AUTOTUNE_DIR), compute the window with the shipped
# autotune_window.py, and dry-load it with the LIVE coordinator binary under
# the unit's EnvironmentFile and user.
IFS= read -r -d '' PF_REMOTE_STAGE <<'STAGE' || true
set -euo pipefail
scratch="$1"; root="$2"; cur="$3"; prev_b64="$4"; name="$5"; env_file="$6"; bin="$7"; config="$8"; overlay="$9"
window="$scratch/tools/autotune_window.py"
sroot="$scratch/root"
if [ "$prev_b64" = __EMPTY__ ]; then prev=""; else prev="$(printf '%s' "$prev_b64" | base64 -d)"; fi
echo "WINDOW_HELPER_SHA=$(sha256sum "$window" | cut -d' ' -f1)"
mkdir -p "$sroot/releases"
cp -a "$root/$cur" "$sroot/$cur"
for entry in $prev; do cp -a "$root/$entry" "$sroot/$entry"; done
mv "$scratch/incoming" "$sroot/releases/$name"
ln -s "$cur" "$sroot/current"
if [ -n "$prev" ]; then printf '%s\n' "$prev" > "$sroot/.previous-target"; fi
chown -R root:macprovider "$scratch"
chmod -R g+rX,g-w,o-rwx "$scratch"
python3 -I "$window" plan --root "$sroot" --incoming "releases/$name" > "$scratch/plan.json"
python3 -c 'import json,sys; w=json.load(open(sys.argv[1]))["window_after"]; open(sys.argv[2],"w").write("".join(e+"\n" for e in w))' "$scratch/plan.json" "$sroot/.previous-target.after"
chown root:macprovider "$sroot/.previous-target.after"
chmod 0640 "$sroot/.previous-target.after"
echo "PLAN_JSON=$(cat "$scratch/plan.json")"
overlay_args=""
if [ -e "$overlay" ]; then overlay_args="--config-overlay $overlay"; fi
rc=0
# shellcheck disable=SC2086
systemd-run --quiet --wait --pipe --collect -p "EnvironmentFile=-$env_file" -p User=macprovider -p Group=macprovider \
  "$bin" --config "$config" $overlay_args --validate-autotune-release "$sroot/releases/$name" \
  --previous-target "$sroot/.previous-target.after" </dev/null >"$scratch/dryload.json" 2>"$scratch/dryload.err" || rc=$?
echo "DRYLOAD_RC=$rc"
echo "DRYLOAD_JSON=$(tail -n 1 "$scratch/dryload.json" | head -c 65536)"
STAGE

pf_dry_load() {
  local prev_arg="__EMPTY__" out want_sha
  REMOTE_SCRATCH="$(SSH 'umask 077 && mktemp -d /tmp/macprovider-content-preflight.XXXXXXXX')" || { record coordinator_dry_load 0 "cannot create a Pearl scratch dir"; return 1; }
  REMOTE_SCRATCH="${REMOTE_SCRATCH//$'\n'/}"
  case "$REMOTE_SCRATCH" in
    */macprovider-content-preflight.[A-Za-z0-9]*) ;;
    *) local bad="$REMOTE_SCRATCH"; REMOTE_SCRATCH=""; record coordinator_dry_load 0 "unsafe scratch dir: $bad"; return 1 ;;
  esac
  case "$REMOTE_SCRATCH" in *[!A-Za-z0-9._/-]*) REMOTE_SCRATCH=""; record coordinator_dry_load 0 "unsafe scratch dir"; return 1 ;; esac
  mkdir -p "$WORK/upload/incoming" "$WORK/upload/tools"
  cp "$REL"/* "$WORK/upload/incoming/"
  cp "$SCRIPT_DIR/autotune_window.py" "$WORK/upload/tools/autotune_window.py"
  if ! tar -C "$WORK/upload" -cf - incoming tools | SSH "tar -xf - -C '$REMOTE_SCRATCH'"; then
    record coordinator_dry_load 0 "cannot upload the candidate to the Pearl scratch dir"; return 1
  fi
  [ -z "$ORIG_PREVIOUS_TARGET" ] || prev_arg="$(printf '%s' "$ORIG_PREVIOUS_TARGET" | base64 | tr -d '\n')"
  printf '%s' "$PF_REMOTE_STAGE" >"$WORK/stage.remote.sh"
  if ! out="$(SSH bash -s -- "$REMOTE_SCRATCH" "$REMOTE_AUTOTUNE_DIR" "$CURRENT_TARGET" "$prev_arg" "$RELEASE_DIRNAME" \
      "$COORD_ENV_FILE" "$COORD_BIN" "$COORD_CONFIG" "$COORD_OVERLAY" <"$WORK/stage.remote.sh" 2>&1)"; then
    record coordinator_dry_load 0 "staging on Pearl failed: $(printf '%s' "$out" | tail -n 3)"; return 1
  fi
  want_sha="$(sha256_file "$SCRIPT_DIR/autotune_window.py")"
  [ "$(printf '%s\n' "$out" | sed -n 's/^WINDOW_HELPER_SHA=//p')" = "$want_sha" ] ||
    { record coordinator_dry_load 0 "autotune_window.py on Pearl does not match the reviewed copy"; return 1; }
  printf '%s\n' "$out" | sed -n 's/^PLAN_JSON=//p' >"$WORK/plan.json"
  printf '%s\n' "$out" | sed -n 's/^DRYLOAD_JSON=//p' >"$WORK/dryload.json"
  local verdict
  verdict="$(python3 - "$WORK/dryload.json" "$(printf '%s\n' "$out" | sed -n 's/^DRYLOAD_RC=//p')" \
    "$REL_ID" "$REL_CAND_SHA" "$REL_TIER2_ID" "$REL_TIER2_SHA" "$WORK/plan.json" <<'PY'
import json, sys
path, rc, rid, sha, t2id, t2sha, plan = sys.argv[1:]
try:
    v = json.loads(open(path).read())
except ValueError:
    print("coordinator dry-load printed no JSON verdict (rc=%s)" % rc); raise SystemExit(1)
want = len(json.load(open(plan))["window_after"])
problems = list(v.get("errors") or [])
if rc != "0" or v.get("ok") is not True:
    problems.insert(0, "dry-load not ok (rc=%s)" % rc)
if v.get("release_id") != rid or v.get("candidates_sha256") != sha:
    problems.append("dry-load loaded %s/%s, expected %s/%s" % (v.get("release_id"), v.get("candidates_sha256"), rid, sha))
if v.get("tier2_catalog_id") != t2id or v.get("tier2_sha256") != t2sha:
    problems.append("dry-load Tier-2 %s/%s, expected %s/%s" % (v.get("tier2_catalog_id"), v.get("tier2_sha256"), t2id, t2sha))
if len(v.get("previous_loaded") or []) != want:
    problems.append("dry-load retained %d of %d window releases" % (len(v.get("previous_loaded") or []), want))
print("; ".join(problems) if problems else "live binary accepts %s with the proposed window (%d retained)" % (rid, want))
raise SystemExit(1 if problems else 0)
PY
)" || { record coordinator_dry_load 0 "$verdict"; return 1; }
  record coordinator_dry_load 1 "$verdict"
}

pf_coverage() {
  local rc=0 detail
  if ! fetch_poolz "$WORK/poolz-preflight.json"; then
    record window_coverage 0 "coordinator /poolz unreachable or refused the operator bearer (coverage unknown)"; return 1
  fi
  SSH "cat > '$REMOTE_SCRATCH/poolz.json'" <"$WORK/poolz-preflight.json" || { record window_coverage 0 "cannot stage /poolz on Pearl"; return 1; }
  SSH "window='$REMOTE_SCRATCH/tools/autotune_window.py'; python3 -I \"\$window\" coverage --root '$REMOTE_SCRATCH/root' --incoming 'releases/$RELEASE_DIRNAME' --poolz-json '$REMOTE_SCRATCH/poolz.json'" \
    >"$WORK/coverage.json" 2>"$WORK/coverage.err" || rc=$?
  detail="$(python3 -c 'import json,sys;v=json.load(open(sys.argv[1]));print("uncovered=%s advertised=%s" % (json.dumps(v["uncovered"],sort_keys=True), v["advertised_total"]))' "$WORK/coverage.json" 2>/dev/null || tail -n 1 "$WORK/coverage.err")"
  if [ "$rc" -eq 0 ]; then
    record window_coverage 1 "every advertised catalog stays admissible ($detail)"
  elif [ "$rc" -eq 4 ] && [ -n "$CATALOG_WINDOW_OVERRIDE_REASON" ]; then
    record window_coverage 1 "OVERRIDE ($CATALOG_WINDOW_OVERRIDE_REASON): $detail"
  else
    record window_coverage 0 "coverage rc=$rc (uncovered or unknown) without CATALOG_WINDOW_OVERRIDE_REASON: $detail"; return 1
  fi
}

# Every SIGHUP applies whatever coordinator.yaml/overlay says NOW (and writes a
# billing snapshot). Refuse if either file changed after the coordinator last
# applied config: the process start or its last fully successful reload
# ("tier2/proof_of_weights config reloaded" closes reloadCoordinatorConfig).
pf_config_applied() {
  local out verdict
  if ! out="$(SSH "set -e
start=\$(systemctl show --timestamp=unix -p ExecMainStartTimestamp --value '$COORDINATOR_UNIT')
echo START=\$start
echo RELOAD=\$(journalctl -u '$COORDINATOR_UNIT' --since \"\$start\" -o short-unix --no-pager | grep -F 'tier2/proof_of_weights config reloaded' | tail -n 1 | cut -d' ' -f1)
python3 -c 'import os,sys
for p in sys.argv[1:]:
    if os.path.exists(p): print(\"MTIME=%s %r\" % (p, os.stat(p).st_mtime))' '$COORD_CONFIG' '$COORD_OVERLAY'" 2>&1)"; then
    record config_applied 0 "cannot read coordinator start/reload/config times: $(printf '%s' "$out" | tail -n 2)"; return 1
  fi
  verdict="$(printf '%s\n' "$out" | python3 -c '
import sys
start = reload = None; mtimes = []
for line in sys.stdin:
    line = line.strip()
    if line.startswith("START="): start = line[6:].lstrip("@")
    elif line.startswith("RELOAD="): reload = line[7:]
    elif line.startswith("MTIME="):
        path, value = line[6:].rsplit(" ", 1); mtimes.append((path, float(value)))
try:
    applied = max(float(start), float(reload) if reload else 0.0)
except (TypeError, ValueError):
    print("coordinator start time is unknown"); raise SystemExit(1)
late = [p for p, m in mtimes if m > applied]
if not mtimes:
    print("coordinator.yaml not found"); raise SystemExit(1)
if late:
    print("pending config edits not yet applied (a SIGHUP would apply them): " + ", ".join(late)); raise SystemExit(1)
print("live yaml equals the last-applied config (no edit since %.0f)" % applied)
')" || { record config_applied 0 "$verdict"; return 1; }
  record config_applied 1 "$verdict"
}

# The canary bearer must be the coordinator operator key (digest compare only).
pf_operator_key() {
  local sha
  sha="$(SSH "set -e
pid=\$(systemctl show -p MainPID --value '$COORDINATOR_UNIT')
[ -n \"\$pid\" ] && [ \"\$pid\" != 0 ]
name=\$(sed -n 's/^[[:space:]]\{1,\}operator_key:[[:space:]]*env:\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*\(#.*\)\{0,1\}\$/\1/p' '$COORD_CONFIG' | head -n 1)
[ -n \"\$name\" ]
tr '\0' '\n' < /proc/\$pid/environ | sed -n \"s/^\$name=//p\" | head -n 1 | tr -d '\n' | sha256sum | cut -d' ' -f1" 2>/dev/null)" || sha=""
  if ! _catalog_canary_auth_token_matches_operator_key "$CATALOG_CANARY_AUTH_TOKEN" "$sha"; then
    record canary_token_operator_key 0 "CATALOG_CANARY_AUTH_TOKEN must be the coordinator operator key (digest mismatch or unreadable)"; return 1
  fi
  record canary_token_operator_key 1 "canary bearer digest equals the running coordinator operator key"
}

pf_canary() {
  if ! canary_proof LIVE "$WORK/canary-before.json"; then
    record canary_reachable 0 "canary custody proof on the live release failed: $(tail -n 1 "$WORK/canary-before.json.err" 2>/dev/null)"; return 1
  fi
  CANARY_CATALOG_KEY="$(canary_proof_field "$WORK/canary-before.json" 'p["catalog_key"]')"
  record canary_reachable 1 "canary serves $CANARY_CATALOG_KEY on live $LIVE_ID"
}

run_preflight() {
  log "preflight: commit $COMMIT"
  pf_commit && pf_tooling && pf_assemble || true
  pf_canary_config || true
  pf_override || true
  if check_ok release_assembled; then
    if pf_pearl; then
      if pf_live; then
        pf_content_gate || true
        pf_closure || true
        pf_buyer_serving_e2e || true
        pf_dry_load && check_ok canary_config && pf_coverage || true
      fi
      pf_config_applied || true
      if check_ok canary_config; then
        pf_operator_key || true
        check_ok rollback_preconditions && pf_canary || true
      fi
    fi
  fi
  # Every named check must have run and passed.
  local name
  for name in commit tooling_matches_commit release_assembled canary_config pearl_reachable pearl_locks_free \
      rollback_preconditions content_gate serving_closure buyer_serving_e2e coordinator_dry_load \
      window_coverage config_applied canary_token_operator_key canary_reachable; do
    grep -q "^$name	" "$CHECKS" || record "$name" 0 "not run: an earlier check failed"
  done
  emit_verdict >"$WORK/verdict.json"
  cat "$WORK/verdict.json"
  [ -z "$(failed_checks)" ]
}

# ---------------------------------------------------------------------------
# Evidence (C5). Each step sets CCR_FAILED_STEP + AA_EVIDENCE_FAILURE on failure.
# ---------------------------------------------------------------------------
ev_fail() { CCR_FAILED_STEP="$1"; AA_EVIDENCE_FAILURE="evidence ($1) failed: $2"; log "EVIDENCE ($1) FAILED: $2"; return 1; }

# (a) coordinator-direct served bytes == release, and the release id is live.
ev_a_served_bytes() {
  local spec path name deadline=$((SECONDS + SETTLE_SECONDS)) bad
  local specs="/v1/autotune-candidates|autotune-candidates.json /v1/autotune-candidates.sig|autotune-candidates.json.sig /v1/demand-rank|demand-rank.json /v1/demand-rank.sig|demand-rank.json.sig /v1/rate-card|rate-card.json /v1/rate-card.sig|rate-card.json.sig"
  [ "$REL_BOUND" != bound ] || specs="$specs /v1/catalog-artifacts|autotune-artifacts.json /v1/catalog-artifacts.sig|autotune-artifacts.json.sig"
  while :; do
    bad=""
    if ! coord_get /v1/autotune-release "$WORK/ev-release.json" ||
       ! python3 -c 'import json,sys;v=json.load(open(sys.argv[1]));sys.exit(0 if v.get("status")=="live_verified" and v.get("release_id")==sys.argv[2] else 1)' "$WORK/ev-release.json" "$REL_ID" 2>/dev/null; then
      bad="/v1/autotune-release does not report live_verified $REL_ID"
    fi
    for spec in $specs; do
      path="${spec%%|*}"; name="${spec#*|}"
      if ! coord_get "$path" "$WORK/ev-served" || ! cmp -s "$WORK/ev-served" "$REL/$name"; then
        bad="$bad${bad:+; }$path bytes differ from $name"
      fi
    done
    [ -n "$bad" ] || break
    [ "$SECONDS" -lt "$deadline" ] || { ev_fail a "$bad"; return 1; }
    sleep 1
  done
  log "evidence (a): coordinator-direct feeds + sigs byte-equal to $REL_ID; /v1/autotune-release reports it"
}

# (b) journald: positive reload for this version + Tier-2 identity; no reject.
ev_b_journal() {
  local deadline=$((SECONDS + SETTLE_SECONDS)) verdict
  while :; do
    journal_since "$T_HUP" "$WORK/journal-hup.txt" || { ev_fail b "cannot read the coordinator journal"; return 1; }
    verdict="$(python3 - "$WORK/journal-hup.txt" "$REL_ID" "$REL_TIER2_ID" "$REL_TIER2_SHA" <<'PY'
import json, sys
path, rid, t2id, t2sha = sys.argv[1:]
rejects = ("autotune feed reload rejected", "tier2 config reload rejected", "billing config reload rejected")
ok = False
for line in open(path, encoding="utf-8", errors="replace"):
    for r in rejects:
        if r in line:
            print("REJECT " + r); raise SystemExit(2)
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if (isinstance(e, dict) and e.get("event") == "autotune_feed_sighup_reload"
            and e.get("autotune_catalog_version") == rid and e.get("tier2_catalog_id") == t2id
            and e.get("tier2_sha256") == t2sha):
        ok = True
print("OK" if ok else "MISSING")
raise SystemExit(0 if ok else 1)
PY
)" && break
    case "$verdict" in REJECT*) ev_fail b "coordinator logged '${verdict#REJECT }' after the HUP"; return 1 ;; esac
    [ "$SECONDS" -lt "$deadline" ] || { ev_fail b "no autotune_feed_sighup_reload for $REL_ID with tier2 $REL_TIER2_ID/$REL_TIER2_SHA"; return 1; }
    sleep 2
  done
  log "evidence (b): autotune_feed_sighup_reload $REL_ID tier2 $REL_TIER2_ID sha $REL_TIER2_SHA; no reload rejection"
}

# Candidate row hash for the canary's catalog key in a release dir.
row_hash() {
  python3 -c 'import json,sys;r=json.load(open(sys.argv[1]))["rows"].get(sys.argv[2]) or {};print(r.get("model_sha256","") if r.get("runtime_status")=="recommendable" else "")' "$1/autotune-candidates.json" "$2"
}

canary_restart() { # <apply:0|1>
  local cmd='uid=$(id -u); launchctl kickstart -k "gui/$uid/live.malibu.provider"'
  if [ "$1" = 1 ]; then
    cmd='set -e; uid=$(id -u); plist="$HOME/Library/LaunchAgents/live.malibu.provider.plist"
bin=$(python3 -c "import plistlib,sys; print(plistlib.load(open(sys.argv[1],\"rb\"))[\"ProgramArguments\"][0])" "$plist")
"$bin" autotune --recommend --apply --drain --max-duration 900
launchctl bootstrap "gui/$uid" "$plist" 2>/dev/null || true
launchctl kickstart -k "gui/$uid/live.malibu.provider"'
  fi
  "${CANARY_SSH[@]}" "$cmd" >&3 2>&1
}

# pool_check <proof> <out>: authenticated coordinator /v1/pool/check for the
# canary's exact session, over Pearl loopback; bearer on stdin.
pool_check() {
  local assigned q_provider q_assigned raw="$WORK/pool-check.raw"
  assigned="$(canary_proof_field "$1" 'p["assigned_id"]')" || return 1
  q_provider="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$CATALOG_CANARY_PROVIDER_ID")"
  q_assigned="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$assigned")"
  printf 'header = "Authorization: Bearer %s"\n' "$CATALOG_CANARY_AUTH_TOKEN" |
    SSH "curl --config - -sS --noproxy '*' --max-time 10 --max-filesize 65536 -w '\n%{http_code}' '$BUYER_URL/v1/pool/check?provider_id=$q_provider&assigned_id=$q_assigned&details=deployment'" >"$raw" 2>/dev/null || return 1
  [ "$(tail -n 1 "$raw")" = 200 ] || return 1
  sed '$d' "$raw" >"$2"
}

# (c) canary restart onto the new release; custody + coordinator admission.
ev_c_canary() {
  local old_hash new_hash apply=0 deadline last="canary proof did not run"
  old_hash="$(row_hash "$LIVE" "$CANARY_CATALOG_KEY")"
  new_hash="$(row_hash "$REL" "$CANARY_CATALOG_KEY")"
  [ "$old_hash" = "$new_hash" ] && [ -n "$new_hash" ] || apply=1
  CCR_CANARY_TOUCHED=1
  if [ "$apply" = 1 ]; then
    log "evidence (c): canary row $CANARY_CATALOG_KEY hash changed; running autotune --recommend --apply on the canary first"
  else
    log "evidence (c): restarting canary serve onto $REL_ID (launchd drain + restart)"
  fi
  canary_restart "$apply" || { ev_fail c "canary restart failed"; return 1; }
  deadline=$((SECONDS + CANARY_RECOVERY_SECONDS))
  while :; do
    if ! canary_proof REL "$WORK/canary-after.json"; then
      last="custody proof on $REL_ID failed: $(tail -n 1 "$WORK/canary-after.json.err" 2>/dev/null)"
    elif [ "$(canary_proof_field "$WORK/canary-after.json" 'p["local_status"]["catalog"].get("source")')" != coordinator ]; then
      last="canary catalog source is not coordinator (baked fallback)"
    elif ! pool_check "$WORK/canary-after.json" "$WORK/pool-check.json"; then
      last="authenticated /v1/pool/check for $CATALOG_CANARY_PROVIDER_ID failed"
    elif ! python3 - "$WORK/pool-check.json" "$WORK/canary-after.json" "$CATALOG_CANARY_PROVIDER_ID" "$REL_ID" "$REL_POLICY" "$REL_CAND_SHA" "$REL_SIGNER" <<'PY'
import json, sys
v = json.load(open(sys.argv[1])); proof = json.load(open(sys.argv[2]))
pid, rid, policy, sha, signer = sys.argv[3:]
row = str(proof["local_status"]["catalog"].get("row_identity", "")).lower()
ok = (v.get("provider_id") == pid and v.get("assigned_id") == proof.get("assigned_id")
      and v.get("buyer_serving") is True and v.get("catalog_evidence_source") == "provider_reported"
      and v.get("catalog_admission_mode") == "current" and v.get("catalog_release_id") == rid
      and v.get("catalog_policy_version") == policy
      and str(v.get("catalog_candidate_sha256", "")).lower() == sha.lower()
      and v.get("catalog_signer_key_id") == signer
      and str(v.get("catalog_row_identity", "")).lower() == row)
raise SystemExit(0 if ok else 1)
PY
    then
      last="/v1/pool/check does not show the canary session buyer-serving on $REL_ID/$REL_CAND_SHA"
    else
      break
    fi
    [ "$SECONDS" -lt "$deadline" ] || { ev_fail c "$last"; return 1; }
    log "evidence (c): waiting for canary ($last)"
    sleep 2
  done
  log "evidence (c): canary $CATALOG_CANARY_PROVIDER_ID admitted on $REL_ID ($REL_CAND_SHA), catalog source coordinator"
}

# Sessions whose Tier-2 identity reads catalog_unavailable/uncatalogued, keyed
# by advertised (release_id, candidate sha).
unavailable_counts() {
  python3 - "$1" <<'PY'
import json, sys
counts = {}
for p in json.load(open(sys.argv[1])).get("pool", []):
    if isinstance(p, dict) and p.get("hash_status") in ("catalog_unavailable", "uncatalogued"):
        k = "%s|%s" % (p.get("catalog_release_id") or "", str(p.get("catalog_candidate_sha256") or "").lower())
        counts[k] = counts.get(k, 0) + 1
print(json.dumps(counts, sort_keys=True))
PY
}

# (d) watch: no catalog_incompatible event for a (release, sha) that was not
# already incompatible before the HUP; no catalog-unavailable increase.
ev_d_watch() {
  local end=$((SECONDS + WATCH_SECONDS)) verdict
  journal_between "$((T_HUP - INCOMPATIBLE_BASELINE_SECONDS))" "$T_HUP" "$WORK/journal-baseline.txt" || { ev_fail d "cannot read the coordinator journal"; return 1; }
  log "evidence (d): watching for ${WATCH_SECONDS}s (poll ${POLL_SECONDS}s)"
  while :; do
    journal_since "$T_HUP" "$WORK/journal-watch.txt" || { ev_fail d "cannot read the coordinator journal"; return 1; }
    verdict="$(python3 - "$WORK/journal-baseline.txt" "$WORK/journal-watch.txt" <<'PY'
import json, sys
def events(path):
    out = []
    for line in open(path, encoding="utf-8", errors="replace"):
        if "catalog_incompatible" not in line and "provider catalog release is incompatible" not in line:
            continue
        try:
            e = json.loads(line)
        except ValueError:
            e = {}
        out.append(e if isinstance(e, dict) else {})
    return out
def key(e):
    return (str(e.get("catalog_release_id", "")), str(e.get("catalog_candidate_sha256", "")).lower())
# Only (release, sha) keys that were not already incompatible in the hour
# before the HUP count as new.
baseline = {key(e) for e in events(sys.argv[1])}
new = sorted({key(e) for e in events(sys.argv[2])} - baseline)
if new:
    print("new catalog_incompatible for " + ", ".join("%s/%s" % k for k in new)); raise SystemExit(1)
PY
)" || { ev_fail d "$verdict"; return 1; }
    fetch_poolz "$WORK/poolz-watch.json" || { ev_fail d "coordinator /poolz unreachable during the watch"; return 1; }
    unavailable_counts "$WORK/poolz-watch.json" >"$WORK/unavailable-now.json"
    verdict="$(python3 - "$WORK/unavailable-before.json" "$WORK/unavailable-now.json" <<'PY'
import json, sys
before, now = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
up = sorted(k for k, n in now.items() if n > before.get(k, 0))
if up:
    print("catalog-unavailable sessions increased for " + ", ".join("%s (%d->%d)" % (k, before.get(k, 0), now[k]) for k in up)); raise SystemExit(1)
PY
)" || { ev_fail d "$verdict"; return 1; }
    [ "$SECONDS" -lt "$end" ] || break
    sleep "$POLL_SECONDS"
  done
  log "evidence (d): no new catalog_incompatible and no catalog-unavailable increase for ${WATCH_SECONDS}s"
}

# C6: keep the failed release retained ONLY if it passed integrity + (a)/(b),
# the failure is not (d)/(e), and /poolz shows live adopters; never evict a
# retained release that has live adopters to make room.
plan_retention() {
  AA_ROLLBACK_WINDOW=""
  [ "$CCR_PASSED_AB" = 1 ] || return 0
  case "$CCR_FAILED_STEP" in c) ;; *) return 0 ;; esac
  fetch_poolz "$WORK/poolz-retain.json" || { log "retention: /poolz unreachable; restoring the exact prior window"; return 0; }
  local ids window
  ids="$(SSH "cd '$REMOTE_AUTOTUNE_DIR' && for e in $ORIG_PREVIOUS_TARGET; do python3 -c 'import json,sys;m=json.load(open(sys.argv[1]+\"/release.json\"));print(sys.argv[1], m[\"release_id\"], m[\"feeds\"][\"autotune-candidates.json\"][\"sha256\"])' \"\$e\"; done")" || { log "retention: cannot read retained release identities; restoring the exact prior window"; return 0; }
  window="$(python3 - "$WORK/poolz-retain.json" "releases/$RELEASE_DIRNAME" "$REL_ID" "$REL_CAND_SHA" "$ids" <<'PY'
import json, sys
poolz, incoming, rid, sha, ids = sys.argv[1:]
adopt = {}
for p in json.load(open(poolz)).get("pool", []):
    k = (p.get("catalog_release_id") or "", str(p.get("catalog_candidate_sha256") or "").lower())
    adopt[k] = adopt.get(k, 0) + 1
if not adopt.get((rid, sha.lower())):
    raise SystemExit(0)
entries = [line.split() for line in ids.splitlines() if line.strip()]
window = [incoming] + [e[0] for e in entries]
while len(window) > 3:
    free = [e for e in entries if not adopt.get((e[1], e[2].lower())) and e[0] in window]
    if not free:
        raise SystemExit(0)
    window.remove(free[-1][0])
print("\n".join(window))
PY
)" || window=""
  if [ -n "$window" ]; then
    validate_previous_target_window "$window"
    AA_ROLLBACK_WINDOW="$window"
    log "retention: live providers adopted $REL_ID; keeping releases/$RELEASE_DIRNAME in the rollback window"
  else
    log "retention: failed release not retained (no live adopters, or no slot without adopters)"
  fi
}

ccr_evidence() {
  ev_a_served_bytes || return 1
  ev_b_journal || return 1
  CCR_PASSED_AB=1
  ev_c_canary || { plan_retention; return 1; }
  ev_d_watch || return 1
  return 0
}

# Runs inside aa_rollback after the remote rollback returned.
ccr_after_rollback() {
  CCR_ROLLED_BACK=1
  CCR_FATAL_RC=4
  case "$AA_ROLLBACK_OUT" in
    *"rolled back to "*) ;;
    *)
      log "ALERT: rollback did not restore current (rc=$AA_ROLLBACK_RC)"
      CCR_FATAL_RC=5
      ;;
  esac
  if [ "$CCR_FATAL_RC" = 4 ] && ! rollback_hup_verified; then
    log "ALERT: the rollback re-HUP was rejected or not observed; restarting $COORDINATOR_UNIT (controlled)"
    if SSH "systemctl restart '$COORDINATOR_UNIT' && systemctl is-active --quiet '$COORDINATOR_UNIT'" && rollback_served_verified; then
      log "coordinator restarted onto $LIVE_ID"
    else
      log "ALERT: controlled coordinator restart did not restore $LIVE_ID"
      CCR_FATAL_RC=5
    fi
  fi
  if [ "$CCR_CANARY_TOUCHED" = 1 ]; then
    log "restarting the canary onto the prior release $LIVE_ID"
    if ! canary_restart 0 || ! canary_back_on_live; then
      log "ALERT: canary did not return to $LIVE_ID"
      CCR_FATAL_RC=5
    fi
  fi
  if [ "$CCR_FATAL_RC" = 5 ]; then
    log "ROLLBACK INCOMPLETE: see $RUNBOOK_ROLLBACK_FAILED"
  fi
}

rollback_hup_verified() {
  local deadline=$((SECONDS + SETTLE_SECONDS))
  while :; do
    if journal_since "$T_RB" "$WORK/journal-rb.txt"; then
      if grep -qF -e 'autotune feed reload rejected' -e 'tier2 config reload rejected' -e 'billing config reload rejected' "$WORK/journal-rb.txt"; then
        return 1
      fi
      if python3 - "$WORK/journal-rb.txt" "$LIVE_ID" <<'PY'
import json, sys
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if isinstance(e, dict) and e.get("event") == "autotune_feed_sighup_reload" and e.get("autotune_catalog_version") == sys.argv[2]:
        raise SystemExit(0)
raise SystemExit(1)
PY
      then
        rollback_served_verified && return 0
      fi
    fi
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 2
  done
}

rollback_served_verified() {
  local deadline=$((SECONDS + 2 * SETTLE_SECONDS))
  while :; do
    if coord_get /v1/autotune-release "$WORK/rb-release.json" &&
       python3 -c 'import json,sys;v=json.load(open(sys.argv[1]));sys.exit(0 if v.get("release_id")==sys.argv[2] else 1)' "$WORK/rb-release.json" "$LIVE_ID" 2>/dev/null &&
       coord_get /v1/autotune-candidates "$WORK/rb-cand.json" && cmp -s "$WORK/rb-cand.json" "$LIVE/autotune-candidates.json"; then
      return 0
    fi
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 2
  done
}

canary_back_on_live() {
  local deadline=$((SECONDS + CANARY_RECOVERY_SECONDS))
  while :; do
    canary_proof LIVE "$WORK/canary-rb.json" && return 0
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 2
  done
}

# ---------------------------------------------------------------------------
# Main.
# ---------------------------------------------------------------------------
if [ "$MODE" = preflight ]; then
  if run_preflight; then exit 0; fi
  exit 3
fi

log "deploy: preflight"
if ! run_preflight; then
  log "preflight NO_GO: $(failed_checks | tr '\n' ' ')"
  exit 3
fi
PREFLIGHT_CURRENT="$CURRENT_TARGET"
PREFLIGHT_WINDOW="$ORIG_PREVIOUS_TARGET"
SSH "rm -rf '$REMOTE_SCRATCH'" >/dev/null 2>&1 || true
REMOTE_SCRATCH=""

trap 'exit 71' HUP INT TERM
aa_lease_acquire
aa_read_live_targets
[ "$CURRENT_TARGET" = "$PREFLIGHT_CURRENT" ] && [ "$ORIG_PREVIOUS_TARGET" = "$PREFLIGHT_WINDOW" ] ||
  fatal "live targets moved between preflight and the lease; re-run"
: >"$CHECKS"
pf_config_applied || fatal "config drift appeared under the lease: $(cut -f3 "$CHECKS")"
aa_refuse_existing_release

AA_GATE_SNIPPET='# Content lane: re-run content-gate against the then-current live release
# with the reviewed commit'"'"'s ledger and exclusions shipped beside the verifier.
gate_out="$(python3 -I "$verifier" content-gate --release "$incoming_path" --live "$root/current" --ledger "$(dirname "$verifier")/../phase3-binary/catalog/autotune/release-ledger.json")" \
  || abort_pre_mutation "content-gate under lock refused: $gate_out"
printf "%s" "$gate_out" | python3 -c "import json,sys; v=json.load(sys.stdin); sys.exit(0 if v.get(\"ok\") is True and v.get(\"lane\") == \"catalog-content\" else 1)" \
  || abort_pre_mutation "content-gate under lock is not lane catalog-content: $gate_out"'
AA_COVERAGE_POLICY=refuse
AA_COVERAGE_OVERRIDE=0
[ -z "$CATALOG_WINDOW_OVERRIDE_REASON" ] || AA_COVERAGE_OVERRIDE=1
AA_LOCK_MODE=lease
AA_ROLLBACK_POST_HOOK=ccr_after_rollback

aa_install_helpers
log "installing the commit's release ledger and serving exclusions beside the verifier"
for _gate_file in release-ledger.json not-buyer-serving.json; do
  SSH "mkdir -p -m 0700 '$LOCK_HELPER_DIR/phase3-binary/catalog/autotune' && cat >'$LOCK_HELPER_DIR/phase3-binary/catalog/autotune/$_gate_file'" <"$WORK/gate/$_gate_file" ||
    fatal "cannot install $_gate_file on $PEARL_SSH"
  [ "$(SSH "sha256sum '$LOCK_HELPER_DIR/phase3-binary/catalog/autotune/$_gate_file'" | cut -d' ' -f1)" = "$(sha256_file "$WORK/gate/$_gate_file")" ] ||
    fatal "$_gate_file on $PEARL_SSH does not match the commit"
done
aa_upload_release "$REL"

fetch_poolz "$WORK/poolz-before.json" || fatal "coordinator /poolz unreachable before activation"
unavailable_counts "$WORK/poolz-before.json" >"$WORK/unavailable-before.json"
if [ "$AA_COVERAGE_OVERRIDE" = 1 ]; then
  log "window coverage override: $CATALOG_WINDOW_OVERRIDE_REASON"
  # Same durable audit trail as deploy-pearl-vps.sh's regression/window
  # overrides: one JSON line appended to Pearl's
  # /var/lib/macprovider/catalog-window-overrides.jsonl via the shared
  # scripts/lib/catalog-window-override.sh primitive.
  CONTENT_OVERRIDE_RECORD_B64="$(python3 - "$CATALOG_WINDOW_OVERRIDE_REASON" "$WORK/coverage.json" "$RELEASE_DIRNAME" "$CURRENT_TARGET" "$LIVE_ID" "$COMMIT" <<'PY'
import base64, json, sys
reason, coverage_path, incoming, live_target, live_id, commit = sys.argv[1:]
with open(coverage_path) as f:
    coverage = json.load(f)
record = {
    "kind": "content_lane_window_coverage",
    "reason": reason,
    "uncovered": coverage.get("uncovered", []),
    "incoming": "releases/" + incoming,
    "live": {"target": live_target, "release_id": live_id},
    "commit": commit,
}
print(base64.b64encode(json.dumps(record, sort_keys=True).encode("ascii")).decode("ascii"))
PY
)" || fatal "could not build the window coverage override record"
  SSH "$(cwo_override_remote_command "$CONTENT_OVERRIDE_RECORD_B64" "catalog-content window coverage override for $RELEASE_DIRNAME" macprovider-catalog-content)" ||
    fatal "could not append the window coverage override record"
  log "AUDIT TRAIL: override appended to /var/lib/macprovider/catalog-window-overrides.jsonl"
fi
T_HUP="$(remote_now)"
case "$T_HUP" in ""|*[!0-9]*) fatal "cannot read Pearl time" ;; esac
T_RB="$T_HUP"
log "activating releases/$RELEASE_DIRNAME ($REL_ID) over $CURRENT_TARGET"
aa_publish
CCR_ACTIVATED=1
# The rollback's own HUP is judged from the moment rollback begins.
ccr_evidence_hook() {
  if ccr_evidence; then return 0; fi
  T_RB="$(remote_now)"
  return 1
}
aa_post_activation_evidence ccr_evidence_hook
CCR_DONE=1
log "DONE: $REL_ID live via the catalog-content lane; evidence (a)-(d) passed; (e) not required (no new buyer-serving Tier-2 pin)"
exit 0
