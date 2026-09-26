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
#   scripts/catalog-content-release.sh --preflight --commit <40-hex sha> [--preflight-verdict <file>]
#   scripts/catalog-content-release.sh --deploy    --commit <40-hex sha> \
#       [--pricing-diff-sha256 <hex> [--preflight-verdict <file>]]
#   scripts/catalog-content-release.sh --recover-pricing-txn
#   scripts/catalog-content-release.sh --host-check --commit <40-hex sha>
#   scripts/catalog-content-release.sh --help
#
# --preflight prints exactly ONE JSON verdict on stdout
#   {"go": bool, "checks": [{"name", "ok", "detail"}], "pricing": {...}|null};
#   progress goes to stderr.
# --deploy runs the same preflight in the same invocation (its JSON verdict
#   line is printed to stdout among the step logs), requires GO, then
#   activates and verifies; every step logs to stdout.
#
# Pricing releases (#1693, SPEC-023-R019): a release whose rate-card rows
# differ from live also replaces the rewards.rate_card block of Pearl's live
# base coordinator.yaml with the reviewed commit's tracked block, in one
# journaled transaction with `current` and the window, applied by one SIGHUP.
# Preflight splices on Pearl (live yaml bytes never leave the host), computes
# the effective-price diff over every served model name (catalog keys, table
# rows, and the request_log model names of the last 30 days, pinned in the
# verdict), dry-loads the candidate with the live binary, and prints the diff
# (including the names the binary resolved) plus `pricing.pricing_diff_sha256`,
# the digest of that complete acknowledged object. --deploy then requires
# --pricing-diff-sha256 equal to that digest (the operator's acknowledgement of
# the shown price table); --preflight-verdict <file> (the saved preflight
# stdout) reuses its pinned name set, so a name that left the 30-day window
# since does not invalidate the acknowledgement. The journal lives at
# /opt/macprovider/.pricing-txn; any failure after it exists rolls yaml,
# current and window back together.
# --host-check (read-only, #1693 enabling rollout) proves Pearl is ready for a
#   pricing release at <sha> without needing one: the commit is on origin/main
#   and is this tooling, no lock or journal is held, the on-disk config is the
#   applied one, and pricing_host_state passes (no foreign recovery state; the
#   installed pricing helper/units/writers are the commit's; the recovery unit
#   carries the pricing pre-start; the coordinator's applied-config record
#   carries the pricing fields; served == on-disk == applied card). Prints one
#   JSON verdict like --preflight; exit 0 = ready, 3 = not ready.
# --recover-pricing-txn takes the Pearl lease and resolves an abandoned
#   pricing journal (restore by compare-and-swap, re-HUP, prove the prior pair
#   live, finalize); exit 0 when resolved or none exists.
#
# Exit codes:
#   0   preflight GO / deploy activated and every evidence step passed
#   1   usage, environment or operational error (no activation, or before it)
#   3   preflight NO_GO (nothing was mutated)
#   4   deploy activated, evidence failed, rolled back to the prior release
#   5   rollback incomplete: follow docs/runbooks/catalog-release-decision-tree.md §rollback-failed;
#       or (pricing) the journal could not be marked verified: it is kept in
#       `verifying` and --recover-pricing-txn rolls it back (§pricing-txn)
#   6   Pearl lease lost after activation may have started: state unknown, NOT
#       rolled back; follow docs/runbooks/catalog-release-decision-tree.md §lease-lost
#   71  interrupted, or lease lost before activation (rolled back first,
#       through the lease, when already activated)
#   (--recover-pricing-txn: 0 resolved or nothing to do; 5 stopped with the
#       journal kept, docs/runbooks/catalog-release-decision-tree.md §pricing-txn)
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
#   CATALOG_COORDINATOR_READY_SECONDS how long to wait for a booting coordinator
#                             to be ready (unit active + /healthz) before any
#                             SIGHUP and after a controlled restart, default 900
#   AA_LEASE_MAX_SECONDS      lease bound, default 2700 for this lane
#   CATALOG_GATEWAY_RATE_CARD_URL   public rate card the gateway serves
#                             (default https://api.malibu.tech/v1/rate-card);
#                             pricing releases poll it for convergence, alert-only
#   CATALOG_GATEWAY_CONVERGENCE_SECONDS  that poll's deadline, default 660
#
# Secrets (the canary/operator bearer) only ever ride curl --config on stdin;
# they are never printed, written to disk, or put in argv.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
RUNBOOK_ROLLBACK_FAILED="docs/runbooks/catalog-release-decision-tree.md §rollback-failed"
RUNBOOK_LEASE_LOST="docs/runbooks/catalog-release-decision-tree.md §lease-lost"
RUNBOOK_PRICING_TXN="docs/runbooks/catalog-release-decision-tree.md §pricing-txn"

usage() { sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }

MODE=""
COMMIT=""
PRICING_ACK=""
PREFLIGHT_VERDICT_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --preflight|--deploy|--recover-pricing-txn|--host-check)
      [ -z "$MODE" ] || { echo "choose one of --preflight / --deploy / --recover-pricing-txn / --host-check" >&2; exit 1; }
      MODE="${1#--}" ;;
    --commit) [ $# -ge 2 ] || { echo "--commit needs a value" >&2; exit 1; }; COMMIT="$2"; shift ;;
    --pricing-diff-sha256) [ $# -ge 2 ] || { echo "--pricing-diff-sha256 needs a value" >&2; exit 1; }; PRICING_ACK="$2"; shift ;;
    --preflight-verdict) [ $# -ge 2 ] || { echo "--preflight-verdict needs a value" >&2; exit 1; }; PREFLIGHT_VERDICT_FILE="$2"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "unknown argument: $1 (see --help)" >&2; exit 1 ;;
  esac
  shift
done
[ -n "$MODE" ] || { echo "one of --preflight, --deploy, --recover-pricing-txn or --host-check is required (see --help)" >&2; exit 1; }
if [ -n "$PRICING_ACK" ]; then
  [ "$MODE" = deploy ] || { echo "--pricing-diff-sha256 is a --deploy acknowledgement" >&2; exit 1; }
  printf '%s' "$PRICING_ACK" | grep -Eqx '[0-9a-f]{64}' || { echo "--pricing-diff-sha256 must be 64 lowercase hex" >&2; exit 1; }
fi
if [ -n "$PREFLIGHT_VERDICT_FILE" ]; then
  case "$MODE" in recover-pricing-txn|host-check) echo "--preflight-verdict does not apply to --$MODE" >&2; exit 1 ;; esac
  [ -f "$PREFLIGHT_VERDICT_FILE" ] || { echo "--preflight-verdict is not a file" >&2; exit 1; }
fi
if [ "$MODE" = recover-pricing-txn ] && [ -n "$COMMIT" ]; then
  echo "--recover-pricing-txn takes no --commit (the journal carries the state)" >&2; exit 1
fi

# Preflight keeps stdout for the single JSON verdict; deploy logs to stdout.
case "$MODE" in preflight|host-check) exec 3>&2 ;; *) exec 3>&1 ;; esac
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
# Written by the coordinator after every successful boot/SIGHUP config apply
# (phase4-coordinator/cmd/coordinator/applied_config.go).
APPLIED_CONFIG_RECORD=/run/macprovider/coordinator-applied-config.json
APPLIED_CONFIG_SCHEMA=macprovider.coordinator-applied-config.v1
BUYER_URL=http://127.0.0.1:8443
PROVIDER_URL=http://127.0.0.1:8444
# #1693 pricing lane: the on-host journal helper (installed by
# deploy-pearl-vps.sh; its installed bytes must equal the reviewed copy),
# the journal, and the installed units/helpers whose hashes preflight proves
# (plus the writer list scripts/pricing-lane-installed-writers.txt at the
# commit). The request_log whose model names are pinned read-only is found
# from the coordinator's effective storage.db_path on Pearl (PF_REMOTE_STAGE).
PRICING_HELPER=/opt/macprovider/coordinator-pricing-recover
PRICING_JOURNAL=/opt/macprovider/.pricing-txn
PRICING_INSTALLED_FILES="/opt/macprovider/coordinator-pricing-recover=phase4-coordinator/dist/coordinator-pricing-recover
/etc/systemd/system/macprovider-coordinator-deploy-recovery.service=phase4-coordinator/dist/systemd/macprovider-coordinator-deploy-recovery.service
/etc/systemd/system/macprovider-coordinator.service.d/10-deploy-transaction-guard.conf=phase4-coordinator/dist/systemd/macprovider-coordinator-deploy-guard.conf
/etc/systemd/system/macprovider-coordinator-pricing-close.service=phase4-coordinator/dist/systemd/macprovider-coordinator-pricing-close.service
/opt/macprovider/coordinator-config-guard.sh=scripts/lib/coordinator-config-guard.sh"
PRICING_WRITERS_MANIFEST=scripts/pricing-lane-installed-writers.txt

WATCH_SECONDS="${CATALOG_EVIDENCE_WATCH_SECONDS:-600}"
POLL_SECONDS="${CATALOG_EVIDENCE_POLL_SECONDS:-30}"
CANARY_RECOVERY_SECONDS="${CATALOG_CANARY_RECOVERY_SECONDS:-180}"
SETTLE_SECONDS="${CATALOG_EVIDENCE_SETTLE_SECONDS:-30}"
READY_SECONDS="${CATALOG_COORDINATOR_READY_SECONDS:-900}"
GATEWAY_RATE_CARD_URL="${CATALOG_GATEWAY_RATE_CARD_URL:-https://api.malibu.tech/v1/rate-card}"
GATEWAY_CONVERGENCE_SECONDS="${CATALOG_GATEWAY_CONVERGENCE_SECONDS:-660}"
for _n in "$WATCH_SECONDS" "$POLL_SECONDS" "$CANARY_RECOVERY_SECONDS" "$SETTLE_SECONDS" "$GATEWAY_CONVERGENCE_SECONDS" "$READY_SECONDS"; do
  case "$_n" in ""|*[!0-9]*) fatal "CATALOG_EVIDENCE_*/CATALOG_CANARY_RECOVERY_SECONDS/CATALOG_GATEWAY_CONVERGENCE_SECONDS/CATALOG_COORDINATOR_READY_SECONDS must be whole seconds" ;; esac
done
# The remote publish/rollback wait the same bound before any SIGHUP.
export AA_COORDINATOR_READY_SECONDS="$READY_SECONDS"
case "$GATEWAY_RATE_CARD_URL" in https://*|http://127.0.0.1:*) ;; *) fatal "CATALOG_GATEWAY_RATE_CARD_URL must be https (or loopback http)" ;; esac
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
  identity_mode="$(stat -c '%a' "$PEARL_SSH_IDENTITY" 2>/dev/null || stat -f '%A' "$PEARL_SSH_IDENTITY" 2>/dev/null || echo '')"
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
# 0 = nothing sent; maybe = the publish was (possibly) sent; 1 = activated.
CCR_ACTIVATED=0
CCR_DONE=0
# #1693: 1 once the pricing journal's `verified` phase is durable (terminal:
# never rolled back); 1 in CCR_PRICING_KEEP when marking it failed (journal
# kept in `verifying` for --recover-pricing-txn, no in-lane rollback).
PRICING_VERIFIED=0
CCR_PRICING_KEEP=0
CCR_ROLLED_BACK=0
CCR_CANARY_TOUCHED=0
CCR_PASSED_AB=0
CCR_FAILED_STEP=""
T_HUP=""
T_RB=""
CANARY_CATALOG_KEY=""
GATE_LANE=""
RELEASE_DIRNAME=""
# sha256 of the on-disk coordinator.yaml / overlay ("" = no overlay), proved
# equal to the coordinator's applied-config record by pf_config_applied.
CONFIG_DISK_SHA=""
OVERLAY_DISK_SHA=""
# #1693 pricing state (PRICING=1 when the release changes rate-card rows).
PRICING=0
PRICING_DIR=""
COMMIT_BLOCK_SHA=""
ACK_MOVES_SHA=""
PRICING_DIFF_SHA=""
CAND_CONFIG_SHA=""
EXPECTED_RATE_SHA=""
EXPECTED_SIGNED_SHA=""
PRIOR_RATE_SHA=""
PRIOR_SIGNED_SHA=""
PRIOR_SNAPSHOT_ID=""

ccr_cleanup() {
  local rc=$? probe
  trap - EXIT
  # Signals (the lease-loss watcher, the watchdog, the operator) must not cut
  # the rollback short; channel loss is detected by aa_lease_run itself.
  trap '' HUP INT TERM
  set +e
  if [ "$PRICING" = 1 ] && [ "$PRICING_VERIFIED" = 1 ] && [ "$CCR_DONE" = 0 ] && [ "$CCR_ROLLED_BACK" = 0 ] && ! aa_lease_lost; then
    # A verified price is never rolled back: only validate + finalize it.
    log "run ended (rc=$rc) after the pricing journal was verified; finalizing the candidate (never rolled back)"
    aa_lease_sh "{ [ ! -e '$PRICING_JOURNAL' ] && [ ! -L '$PRICING_JOURNAL' ]; } || python3 -I '$PRICING_HELPER' finalize candidate" >&3 2>&1 ||
      log "ALERT: the verified pricing journal could not be finalized; the candidate is live. Run scripts/catalog-content-release.sh --recover-pricing-txn ($RUNBOOK_PRICING_TXN)"
  elif [ "$CCR_PRICING_KEEP" = 1 ]; then
    log "pricing: the journal at $PRICING_JOURNAL is kept in phase verifying; run scripts/catalog-content-release.sh --recover-pricing-txn, which rolls it back ($RUNBOOK_PRICING_TXN)"
  elif [ "$CCR_ACTIVATED" != 0 ] && [ "$CCR_DONE" = 0 ] && [ "$CCR_ROLLED_BACK" = 0 ] && ! aa_lease_lost; then
    probe=0
    if [ "$CCR_ACTIVATED" = maybe ]; then
      # Interrupted while the publish may be running on Pearl: ask the lease
      # runner (it answers after the publish finishes) what actually changed.
      log "run ended (rc=$rc) while the publish may have started; reading Pearl state through the lease"
      aa_lease_probe_activation
      probe=$?
      [ "$probe" != 1 ] || log "the publish did not change current or .previous-target; nothing to roll back"
    fi
    if [ "$probe" != 1 ] && ! aa_lease_lost; then
      log "run ended (rc=$rc) after activation without an evidence verdict; rolling back"
      CCR_FAILED_STEP="${CCR_FAILED_STEP:-interrupted}"
      T_RB="$(remote_now 2>/dev/null || echo "$T_HUP")"
      aa_rollback
      if [ "$CCR_FATAL_RC" = 5 ]; then rc=5; fi
    fi
  fi
  if [ "$CCR_ACTIVATED" != 0 ] && [ "$CCR_DONE" = 0 ] && [ "$AA_LEASE_LOST" = 1 ]; then
    log "LEASE LOST: the Pearl lease ended while activation may have started; Pearl state is UNKNOWN and was NOT rolled back from a separate session. Follow $RUNBOOK_LEASE_LOST"
    [ "$PRICING" != 1 ] || log "pricing: the journal at $PRICING_JOURNAL is kept; after reacquiring the lock set run scripts/catalog-content-release.sh --recover-pricing-txn ($RUNBOOK_PRICING_TXN)"
    rc=6
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
  local detail limit=600
  # pricing_host_state lists every installed-file problem after its operator hint.
  [ "$1" != pricing_host_state ] || limit=2000
  detail="$(printf '%s' "$3" | LC_ALL=C tr -c '[:print:]' ' ' | cut -c1-"$limit")"
  printf '%s\t%s\t%s\n' "$1" "$2" "$detail" >>"$CHECKS"
  if [ "$2" = 1 ]; then log "check $1: ok ($detail)"; else log "check $1: FAIL ($detail)"; fi
}
failed_checks() { awk -F '\t' '$2 != 1 {print $1}' "$CHECKS"; }
check_ok() { awk -F '\t' -v n="$1" '$1 == n && $2 == 1 {found=1} END {exit found ? 0 : 1}' "$CHECKS"; }

emit_verdict() {
  python3 - "$CHECKS" "${PRICING_DIR:-}" <<'PY'
import json, os, sys
checks = []
for line in open(sys.argv[1], encoding="utf-8"):
    name, ok, detail = line.rstrip("\n").split("\t", 2)
    checks.append({"name": name, "ok": ok == "1", "detail": detail})
pricing = None
if sys.argv[2] and os.path.exists(os.path.join(sys.argv[2], "verdict-pricing.json")):
    pricing = json.load(open(os.path.join(sys.argv[2], "verdict-pricing.json")))
print(json.dumps({"go": bool(checks) and all(c["ok"] for c in checks), "checks": checks, "pricing": pricing},
                 sort_keys=True, ensure_ascii=True))
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
TOOLING_FILES="scripts/catalog-content-release.sh scripts/lib/autotune-activate.sh scripts/lib/catalog-canary-token.sh scripts/lib/coordinator-config-guard.sh scripts/pearl_autotune_deploy_lock.py scripts/catalog-verifier-bundle.txt ops/pearl-updater/catalog-canary-proof.py phase4-coordinator/dist/coordinator-pricing-recover"

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
  # The Tier-2 trust root (tier2.catalog_public_key) every verify of this
  # release uses, here and under the lock on Pearl: the reviewed commit's
  # tracked coordinator.yaml, shipped sha-pinned beside the verifier (#1693 E2).
  git -C "$REPO_ROOT" show "$COMMIT:phase4-coordinator/dist/coordinator.yaml" >"$WORK/gate/tier2-trust-root.yaml" 2>/dev/null &&
    [ -s "$WORK/gate/tier2-trust-root.yaml" ] ||
    { record release_assembled 0 "commit lacks phase4-coordinator/dist/coordinator.yaml (the Tier-2 trust root)"; return 1; }
  # A Tier-2 freshness re-sign of a ledger row is provable only from git
  # history (as deploy-pearl-vps.sh): build the index from the reviewed commit.
  if ! python3 -I "$SCRIPT_DIR/catalog-release.py" tier2-content-index --repo "$REPO_ROOT" \
      --ledger "$WORK/gate/release-ledger.json" --rev "$COMMIT" >"$WORK/gate/tier2-content-index.json" 2>"$WORK/t2index.err"; then
    record release_assembled 0 "cannot build the Tier-2 content index from $COMMIT history: $(tail -n 2 "$WORK/t2index.err")"; return 1
  fi
  if ! python3 -I "$SCRIPT_DIR/catalog-release.py" verify-directory --directory "$REL" \
      --tier2-coordinator-config "$WORK/gate/tier2-trust-root.yaml" >"$WORK/verify.out" 2>&1; then
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
  if ! out="$( (aa_read_live_targets && printf '%s\n' "$ORIG_PREVIOUS_TARGET_B64" "$CURRENT_TARGET" && printf '%s' "$ORIG_PREVIOUS_TARGET") 2>&1)"; then
    record pearl_reachable 0 "cannot read live autotune targets on $PEARL_SSH: $out"; return 1
  fi
  ORIG_PREVIOUS_TARGET_B64="$(printf '%s\n' "$out" | sed -n 1p)"
  CURRENT_TARGET="$(printf '%s\n' "$out" | sed -n 2p)"
  ORIG_PREVIOUS_TARGET="$(printf '%s\n' "$out" | sed -n '3,$p')"
  record pearl_reachable 1 "current=$CURRENT_TARGET window=$(printf '%s' "$ORIG_PREVIOUS_TARGET" | tr '\n' ' ')"
  if SSH "test -e /var/lib/macprovider-pearl-updater/tier2-enforcement-transaction.json"; then
    record pearl_locks_free 0 "a Tier-2 enforcement transaction is active"; return 1
  fi
  if ! SSH "for l in /run/lock/macprovider-pearl-updater.lock /opt/macprovider/.coordinator-deploy.lock; do [ ! -e \"\$l\" ] || flock -n \"\$l\" true || exit 1; done"; then
    record pearl_locks_free 0 "a coordinator deploy, renewal or Pearl update holds the Pearl lock"; return 1
  fi
  record pearl_locks_free 1 "no deploy, renewal, update or Tier-2 transaction in progress"
  # #1693 L0: every config writer (this lane included) refuses while a pricing
  # transaction journal exists; resolve it with --recover-pricing-txn first.
  if SSH "test -e '$PRICING_JOURNAL' || test -L '$PRICING_JOURNAL'"; then
    record pricing_txn_absent 0 "refusing: pricing transaction journal present at $PRICING_JOURNAL; run scripts/catalog-content-release.sh --recover-pricing-txn"; return 1
  fi
  record pricing_txn_absent 1 "no pricing transaction journal"
}

# Fetch the LIVE release read-only and prove the rollback target verifies.
pf_live() {
  local entry missing=""
  mkdir -p "$LIVE"
  if ! SSH "tar -C '$REMOTE_AUTOTUNE_DIR/$CURRENT_TARGET' -cf - ." | tar -xf - -C "$LIVE"; then
    record rollback_preconditions 0 "cannot read the live release $CURRENT_TARGET"; return 1
  fi
  release_identity "$LIVE" LIVE || { record rollback_preconditions 0 "live release identity is malformed"; return 1; }
  if ! python3 -I "$SCRIPT_DIR/catalog-release.py" verify-directory --directory "$LIVE" \
      --tier2-coordinator-config "$WORK/gate/tier2-trust-root.yaml" >"$WORK/verify-live.out" 2>&1; then
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
    --tier2-content-index "$WORK/gate/tier2-content-index.json" --tier2-coordinator-config "$WORK/gate/tier2-trust-root.yaml" \
    >"$WORK/gate.json" 2>"$WORK/gate.err" || rc=$?
  GATE_LANE="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("lane",""))' "$WORK/gate.json" 2>/dev/null || true)"
  if [ "$rc" -ne 0 ] || [ "$GATE_LANE" != catalog-content ]; then
    record content_gate 0 "content-gate rc=$rc lane=${GATE_LANE:-?}: $(python3 -c 'import json,sys;print("; ".join(json.load(open(sys.argv[1])).get("reasons",[])))' "$WORK/gate.json" 2>/dev/null || tail -n 2 "$WORK/gate.err")"
    return 1
  fi
  record content_gate 1 "lane catalog-content vs live $LIVE_ID"
  pf_pricing_detect
}

# #1693: a rows-only rate-card change makes this a pricing release. Bind the
# commit's tracked coordinator rate_card block (the bytes the splice installs)
# and its acknowledged-pricing-moves.json, both read with `git show`.
pf_pricing_detect() {
  local out
  out="$(python3 -c '
import json, re, sys
v = json.load(open(sys.argv[1]))
p = v.get("pricing") or {}
changed = any(p.get(k) for k in ("changed", "added", "removed"))
blk = v.get("commit_block_sha256") or ""
if changed and not re.fullmatch(r"[0-9a-f]{64}", blk):
    raise SystemExit("pricing release without a commit-bound rate_card block digest")
print("1 " + blk if changed else "0 -")' "$WORK/gate.json" 2>&1)" || { record pricing_release 0 "$out"; return 1; }
  [ "${out%% *}" = 1 ] || return 0
  PRICING=1
  COMMIT_BLOCK_SHA="${out#* }"
  PRICING_DIR="$WORK/pricing"
  rm -rf "$PRICING_DIR"; mkdir -m 0700 "$PRICING_DIR"
  git -C "$REPO_ROOT" show "$COMMIT:phase4-coordinator/dist/coordinator.yaml" >"$PRICING_DIR/commit-coordinator.yaml" 2>/dev/null &&
    git -C "$REPO_ROOT" show "$COMMIT:phase3-binary/catalog/autotune/acknowledged-pricing-moves.json" >"$PRICING_DIR/ack.json" 2>/dev/null ||
    { record pricing_release 0 "commit lacks phase4-coordinator/dist/coordinator.yaml or acknowledged-pricing-moves.json"; return 1; }
  if ! python3 -I "$SCRIPT_DIR/catalog-release.py" extract-coordinator-rate-card-block --config "$PRICING_DIR/commit-coordinator.yaml" \
      --output "$PRICING_DIR/block.yaml" >"$PRICING_DIR/extract.json" 2>"$PRICING_DIR/extract.err"; then
    record pricing_release 0 "cannot extract the commit's rate_card block: $(tail -n 1 "$PRICING_DIR/extract.err")"; return 1
  fi
  [ "$(sha256_file "$PRICING_DIR/block.yaml")" = "$COMMIT_BLOCK_SHA" ] ||
    { record pricing_release 0 "the commit's rate_card block digest differs from the content gate's"; return 1; }
  ACK_MOVES_SHA="$(sha256_file "$PRICING_DIR/ack.json")"
  record pricing_release 1 "rate-card rows change vs live; commit rate_card block $COMMIT_BLOCK_SHA"
}

# #1693 L2 host state, read-only, as root on Pearl: no foreign recovery state,
# no pricing keys in the overlay, the installed guard-bearing writers and the
# pricing recovery helper/units hash to the commit's bytes, the coordinator
# requires the recovery unit and wants the closer, the alert unit loads, and
# the served card == on-disk current card == applied record card.
IFS= read -r -d '' PF_REMOTE_PRICING_STATE <<'STATE' || true
set -euo pipefail
helper="$1"; overlay="$2"; record="$3"; buyer="$4"; root="$5"; cur="$6"
shift 6
for spec in "$@"; do
  want="${spec%%=*}"; path="${spec#*=}"
  if [ -f "$path" ] && [ ! -L "$path" ]; then got="$(sha256sum "$path" | cut -d' ' -f1)"; else got=MISSING; fi
  if [ "$got" = "$want" ]; then echo "INSTALLED=ok $path"; else echo "INSTALLED=$got $path"; fi
done
echo "REQUIRES=$(systemctl show -p Requires --value macprovider-coordinator 2>/dev/null || true)"
echo "WANTS=$(systemctl show -p Wants --value macprovider-coordinator 2>/dev/null || true)"
echo "ALERT_LOADSTATE=$(systemctl show -p LoadState --value macprovider-pearl-updater-alert@macprovider-coordinator-pricing-close.service.service 2>/dev/null || true)"
# A pre-#1693 deploy script (even an aborted one) reinstalls a recovery unit
# without the pricing pre-start: journals would no longer be restored at boot.
if grep -qE '^ExecStart=/usr/bin/python3 -I [^ ]*/coordinator-pricing-recover --pre-start$' /etc/systemd/system/macprovider-coordinator-deploy-recovery.service 2>/dev/null; then
  echo PRESTART=ok
else
  echo PRESTART=missing
fi
if [ -f "$helper" ]; then python3 -I "$helper" foreign-state 2>&1 | sed 's/^/FOREIGN=/' || true; fi
python3 -I - "$overlay" <<'PY' || true
import re, sys
try:
    text = open(sys.argv[1], encoding="utf-8").read()
except FileNotFoundError:
    print("OVERLAY=ok"); raise SystemExit
except (OSError, UnicodeDecodeError):
    print("OVERLAY=unreadable"); raise SystemExit
key = re.compile(r"""(^|[\s{,])["']?(rate_card|provider_share|global_multiplier|usd_per_million_credits)["']?\s*:""")
hits = sorted({m.group(2) for line in text.splitlines() for m in [key.search(line.split("#", 1)[0])] if m})
print("OVERLAY=" + ("ok" if not hits else "carries " + ",".join(hits)))
PY
served="$(curl -fsS --noproxy '*' --max-time 10 --max-filesize 16777216 "$buyer/v1/rate-card" | sha256sum | cut -d' ' -f1)" || served=unreadable
echo "SERVED_CARD=$served"
echo "DISK_CARD=$(sha256sum "$root/$cur/rate-card.json" | cut -d' ' -f1)"
if [ -f "$record" ]; then echo "RECORD=$(head -c 65536 "$record" | head -n 1)"; else echo RECORD=; fi
STATE

commit_sha() { # <repo path>: sha256 of that file at $COMMIT, or empty
  git -C "$REPO_ROOT" show "$COMMIT:$1" 2>/dev/null | python3 -c 'import hashlib,sys;d=sys.stdin.buffer.read();print(hashlib.sha256(d).hexdigest() if d else "")'
}

pf_pricing_host() {
  local installed_specs=() line want repo_path installed writers out verdict
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    installed="${line%%=*}"; repo_path="${line#*=}"
    want="$(commit_sha "$repo_path")"
    [ -n "$want" ] || { record pricing_host_state 0 "commit lacks $repo_path (installed as $installed)"; return 1; }
    installed_specs+=("$want=$installed")
  done <<LIST
$PRICING_INSTALLED_FILES
LIST
  # The guard-bearing live-config writers installed on Pearl (updater,
  # watchdog, deploy-recover, ...), listed at the commit as "<installed> <repo>".
  writers="$(git -C "$REPO_ROOT" show "$COMMIT:$PRICING_WRITERS_MANIFEST" 2>/dev/null)" ||
    { record pricing_host_state 0 "commit lacks $PRICING_WRITERS_MANIFEST (installed-writer hashes unknown)"; return 1; }
  while read -r installed repo_path; do
    case "$installed" in ''|'#'*) continue ;; esac
    case "$installed$repo_path" in *[!A-Za-z0-9._/@-]*) record pricing_host_state 0 "unsafe entry in $PRICING_WRITERS_MANIFEST"; return 1 ;; esac
    want="$(commit_sha "$repo_path")"
    [ -n "$want" ] || { record pricing_host_state 0 "commit lacks $repo_path (installed as $installed)"; return 1; }
    installed_specs+=("$want=$installed")
  done <<LIST
$writers
LIST
  printf '%s' "$PF_REMOTE_PRICING_STATE" >"$WORK/pricing-state.remote.sh"
  if ! out="$(SSH bash -s -- "$PRICING_HELPER" "$COORD_OVERLAY" "$APPLIED_CONFIG_RECORD" "$BUYER_URL" "$REMOTE_AUTOTUNE_DIR" \
      "$CURRENT_TARGET" "${installed_specs[@]}" <"$WORK/pricing-state.remote.sh" 2>&1)"; then
    record pricing_host_state 0 "cannot read the Pearl pricing state: $(printf '%s' "$out" | tail -n 2)"; return 1
  fi
  verdict="$(printf '%s\n' "$out" | python3 -c '
import json, re, sys
hexre = re.compile(r"[0-9a-f]{64}")
# Operator hints lead: the detail is truncated for display.
hints, problems, rec = [], [], None
served = disk = None
for line in sys.stdin:
    key, _, val = line.rstrip("\n").partition("=")
    if key == "INSTALLED" and not val.startswith("ok "):
        got, _, path = val.partition(" ")
        problems.append("%s is %s, not the commit%ss guard-bearing bytes" % (path, "missing" if got == "MISSING" else "sha " + got[:12], chr(39)))
    elif key == "REQUIRES" and "macprovider-coordinator-deploy-recovery.service" not in val.split():
        problems.append("macprovider-coordinator does not Require the deploy-recovery unit")
    elif key == "WANTS" and "macprovider-coordinator-pricing-close.service" not in val.split():
        problems.append("macprovider-coordinator does not Want macprovider-coordinator-pricing-close.service")
    elif key == "PRESTART" and val != "ok":
        hints.append("pricing recovery DISABLED: the recovery unit lacks the coordinator-pricing-recover --pre-start line "
                     "(a pre-#1693 deploy script reinstalled its units); re-run the #1693 enabling rollout from a tag whose ledger carries the live release (runbook runtime floor rule)")
    elif key == "ALERT_LOADSTATE" and val != "loaded":
        problems.append("macprovider-pearl-updater-alert@.service is not loadable (%s)" % (val or "?"))
    elif key == "FOREIGN" and val:
        problems.append("foreign recovery state: " + val)
    elif key == "OVERLAY" and val != "ok":
        problems.append("overlay %s (pricing keys must stay base-owned)" % val)
    elif key == "SERVED_CARD":
        served = val
    elif key == "DISK_CARD":
        disk = val
    elif key == "RECORD":
        try:
            rec = json.loads(val)
        except ValueError:
            rec = None
if not isinstance(rec, dict):
    problems.append("applied identity unknown: no parseable applied-config record")
    rec = {}
rate, signed, snap = rec.get("rate_table_sha256"), rec.get("signed_rate_card_sha256"), rec.get("billing_snapshot_id")
if not (isinstance(rate, str) and hexre.fullmatch(rate) and isinstance(signed, str) and hexre.fullmatch(signed)
        and isinstance(snap, int) and not isinstance(snap, bool) and snap > 0 and isinstance(rec.get("autotune_release_id"), str)):
    hints.append("pricing needs the #1693 enabling runtime release: the coordinator applied-config record lacks "
                 "rate_table_sha256, signed_rate_card_sha256, autotune_release_id or billing_snapshot_id")
elif not (served == disk == signed):
    problems.append("prior state not settled: served /v1/rate-card %s, on-disk current card %s, applied record card %s differ"
                    % ((served or "?")[:12], (disk or "?")[:12], signed[:12]))
if hints or problems:
    print("; ".join(hints + problems)); raise SystemExit(1)
print("%s %s %d" % (rate, signed, snap))
')" || { record pricing_host_state 0 "$verdict"; return 1; }
  read -r PRIOR_RATE_SHA PRIOR_SIGNED_SHA PRIOR_SNAPSHOT_ID <<VALS
$verdict
VALS
  record pricing_host_state 1 "no foreign recovery state; installed helpers/units/writers are the commit's; served == disk == applied card ${PRIOR_SIGNED_SHA:0:12} (snapshot $PRIOR_SNAPSHOT_ID)"
}

# (e) A model that is newly buyer-serving vs live (added) or served at a new
# hash (changed) needs a strict-pin buyer request + settlement row. No
# reusable noninteractive production harness exists, so such releases are
# NO_GO here. The live side is judged with the not-buyer-serving.json that was
# in force for it: the one committed with the reviewed release the live
# release is (compare-live) or descends from, found on origin/main history.
live_exclusions() { # <out>: that exclusion list, or fail
  local key
  key="$(python3 -c '
import json, re, sys
v = json.load(open(sys.argv[1]))
if v.get("verdict") == "descends":
    key = v.get("matched_ledger_release")
elif v.get("verdict") == "equivalent":
    key = v.get("live_release_id")
else:
    raise SystemExit(1)
if not isinstance(key, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:+-]{0,191}", key):
    raise SystemExit(1)
print(key)' "$WORK/compare-live.json" 2>/dev/null)" || return 1
  python3 - "$REPO_ROOT" "$key" "$1" <<'PY'
import json, subprocess, sys
repo, key, out = sys.argv[1:]
REL = "phase3-binary/catalog/autotune/release.json"
EXCL = "phase3-binary/catalog/autotune/not-buyer-serving.json"
def show(commit, path):
    r = subprocess.run(["git", "-C", repo, "show", "%s:%s" % (commit, path)], capture_output=True)
    return r.stdout if r.returncode == 0 else None
commits = subprocess.run(["git", "-C", repo, "log", "--format=%H", "origin/main", "--", REL],
                         capture_output=True, text=True, check=True).stdout.split()
for commit in commits:  # newest first
    raw = show(commit, REL)
    try:
        rid = json.loads(raw)["release_id"] if raw else None
    except (ValueError, KeyError, TypeError):
        rid = None
    if rid != key:
        continue
    excl = show(commit, EXCL)
    # Before #1688 there was no exclusion list: that release served exactly
    # its pinned rows, so an empty list is its historically exact set.
    open(out, "wb").write(excl if excl is not None else
                          b'{"models": [], "schema_version": "macprovider.not-buyer-serving.v1"}\n')
    print(commit)
    raise SystemExit(0)
raise SystemExit(2)
PY
}

pf_buyer_serving_e2e() {
  local rc=0 commit verdict
  python3 -I "$SCRIPT_DIR/catalog-release.py" compare-live --incoming "$REL" --live "$LIVE" \
    --ledger "$WORK/gate/release-ledger.json" --tier2-content-index "$WORK/gate/tier2-content-index.json" \
    >"$WORK/compare-live.json" 2>"$WORK/compare-live.err" || rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
    record buyer_serving_e2e 0 "compare-live failed (rc=$rc): $(tail -n 2 "$WORK/compare-live.err")"; return 1
  fi
  if ! commit="$(live_exclusions "$WORK/live-not-buyer-serving.json")"; then
    record buyer_serving_e2e 0 "cannot establish the live release's buyer-serving exclusions (live content matches no reviewed release on origin/main)"; return 1
  fi
  if ! python3 -I "$SCRIPT_DIR/catalog-release.py" buyer-serving-set --release "$REL" \
      --exclusions "$WORK/gate/not-buyer-serving.json" --diff-live "$LIVE" \
      --live-exclusions "$WORK/live-not-buyer-serving.json" >"$WORK/buyer-serving.json" 2>"$WORK/buyer-serving.err"; then
    record buyer_serving_e2e 0 "buyer-serving-set failed: $(tail -n 2 "$WORK/buyer-serving.err")"; return 1
  fi
  verdict="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
new = ["%s (added)" % m["model_id"] for m in d["added"]] + ["%s (sha changed)" % m["model_id"] for m in d["changed"]]
print(", ".join(new))
raise SystemExit(1 if new else 0)' "$WORK/buyer-serving.json")" || {
    record buyer_serving_e2e 0 "new buyer-serving model(s) vs live: $verdict; a strict-pin buyer request + settlement row is required and no noninteractive harness exists (ship via the runtime lane with its E2E)"
    return 1
  }
  record buyer_serving_e2e 1 "buyer-serving set adds or re-hashes nothing vs live (live exclusions from ${commit:0:12})"
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
# Every shipped tool (the window helper + the catalog-verifier bundle under
# tools/scripts/) is reported for the reviewed-copy sha check.
(cd "$scratch/tools" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do echo "TOOL_SHA=$(sha256sum "$f" | cut -d' ' -f1) ${f#./}"; done)
mkdir -p "$sroot/releases"
cp -a "$root/$cur" "$sroot/$cur"
for entry in $prev; do cp -a "$root/$entry" "$sroot/$entry"; done
mv "$scratch/incoming" "$sroot/releases/$name"
ln -s "$cur" "$sroot/current"
if [ -n "$prev" ]; then printf '%s\n' "$prev" > "$sroot/.previous-target"; fi
# #1693 L1/L2 pricing: splice the commit's rate_card block into the LIVE base
# yaml here (its bytes never leave Pearl; only digests and the effective diff
# return), pin the distinct request_log model names of the last 30 days
# (read-only query, names only), and compute the effective-price diff.
pricing="${10:-0}"
config_arg="$config"; pricing_args=""
if [ "$pricing" = 1 ]; then
  p="$scratch/pricing"
  verifier="$scratch/tools/scripts/catalog-release.py"
  if python3 -I "$verifier" splice-coordinator-rate-card --live-config "$config" --block "$p/block.yaml" \
      --output "$p/candidate-coordinator.yaml" >"$p/splice.json" 2>"$p/splice.err"; then
    echo "SPLICE_JSON=$(cat "$p/splice.json")"
  else
    echo "PRICING_ERROR=the rate_card splice refused the live coordinator.yaml: $(tail -n 1 "$p/splice.err" | tr -cd '[:print:]' | head -c 400)"
  fi
  # The request_log lives in the coordinator's storage.db_path: the overlay's
  # value over the base's (as the coordinator merges them), else its default,
  # resolved against the unit's WorkingDirectory (/opt/macprovider) like the
  # coordinator resolves it. An absent database is a refusal, never "no names".
  db="$(python3 -I - "$verifier" "$config" "$overlay" /opt/macprovider/ <<'PY'
import os, runpy, sys
cr = runpy.run_path(sys.argv[1])
config, overlay, workdir = sys.argv[2:]
value = None
if os.path.exists(overlay):
    value = cr["_yaml_block_value"](open(overlay, encoding="utf-8").read(), "storage", "db_path")
if not value:
    value = cr["_yaml_block_value"](open(config, encoding="utf-8").read(), "storage", "db_path")
value = value or "coordinator.db"  # the coordinator default storage.db_path
path = os.path.normpath(os.path.join(workdir, value))
if not os.path.isfile(path):
    print("storage.db_path %r resolves to %s, which does not exist" % (value, path))
    raise SystemExit(1)
print(path)
PY
)" || { echo "PRICING_ERROR=cannot locate the request_log: $(printf '%s' "$db" | tr -cd '[:print:]' | head -c 400)"; db=""; }
  [ -z "$db" ] || python3 -I - "$db" "$p/names-now.json" <<'PY' || echo "PRICING_ERROR=cannot read the request_log model names read-only from $db"
import datetime, json, sqlite3, sys
db, out = sys.argv[1:]
cutoff = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=30)).strftime("%Y-%m-%dT%H:%M:%S")
con = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
try:
    rows = con.execute("SELECT DISTINCT model FROM request_log WHERE ts_utc >= ?", (cutoff,)).fetchall()
finally:
    con.close()
json.dump(sorted({r[0] for r in rows if isinstance(r[0], str)}), open(out, "w"))
PY
  # Unreadable names were reported (PRICING_ERROR refuses the preflight); an
  # empty list only lets the stage finish its report.
  [ -f "$p/names-now.json" ] || echo '[]' >"$p/names-now.json"
  new_arg=""
  if [ -f "$p/pinned-names.json" ]; then new_arg="--new-names $p/names-now.json"; else cp "$p/names-now.json" "$p/pinned-names.json"; fi
  rel_args="--release $sroot/releases/$name --release $sroot/$cur"
  for entry in $prev; do rel_args="$rel_args --release $sroot/$entry"; done
  diff_rc=0
  # shellcheck disable=SC2086
  python3 -I "$verifier" pricing-effective-diff --live-config "$config" --candidate-rate-card "$sroot/releases/$name/rate-card.json" \
    $rel_args --pinned-names "$p/pinned-names.json" $new_arg --acknowledged-moves "$p/ack.json" \
    --output "$p/pricing-diff.json" >"$p/diff.out" 2>"$p/diff.err" || diff_rc=$?
  echo "PRICING_DIFF_RC=$diff_rc"
  echo "PRICING_DIFF_OUT=$(head -c 262144 "$p/diff.out" | tr -d '\n')"
  [ "$diff_rc" -eq 0 ] || [ "$diff_rc" -eq 3 ] || echo "PRICING_ERROR=pricing-effective-diff failed: $(tail -n 1 "$p/diff.err" | tr -cd '[:print:]' | head -c 400)"
  if [ -f "$p/pricing-diff.json" ]; then echo "PRICING_DIFF_B64=$(base64 < "$p/pricing-diff.json" | tr -d '\n')"; fi
  echo "PINNED_B64=$(base64 < "$p/pinned-names.json" | tr -d '\n')"
  # Names outside the MODEL_KEY grammar are resolved by the live binary (C2).
  python3 -I - "$verifier" "$p/unresolved.json" "$p/pinned-names.json" "$p/names-now.json" $rel_args <<'PY' || echo "PRICING_ERROR=cannot list the names the validator must resolve"
import json, runpy, sys
cr = runpy.run_path(sys.argv[1])
names = set(json.load(open(sys.argv[3]))) | set(json.load(open(sys.argv[4])))
args = sys.argv[5:]
import pathlib
for i in range(0, len(args), 2):
    names |= cr["release_model_names"](pathlib.Path(args[i + 1]))
json.dump(sorted(n for n in names if not cr["PRICING_RESOLVABLE_NAME"].fullmatch(n)), open(sys.argv[2], "w"))
PY
  config_arg="$p/candidate-coordinator.yaml"
  pricing_args="--expect-base-equivalent $config --resolve-model-names $p/unresolved.json"
fi
chown -R root:macprovider "$scratch"
chmod -R g+rX,g-w,o-rwx "$scratch"
python3 -I "$window" plan --root "$sroot" --incoming "releases/$name" > "$scratch/plan.json"
# The validator resolves the planned window, and scans same-version restamps,
# under <dir of --previous-target>/releases: the LIVE releases/ (as deploy's
# coverage check does), so its admitted set includes restamps.
mkdir "$scratch/check"
python3 -c 'import json,sys; w=json.load(open(sys.argv[1]))["window_after"]; open(sys.argv[2],"w").write("".join(e+"\n" for e in w))' "$scratch/plan.json" "$scratch/check/.previous-target"
ln -s "$root/releases" "$scratch/check/releases"
# #1705: the live row-continuity list is part of the admitted set.
if [ -e "$root/.row-continuity-target" ]; then install -m 0640 "$root/.row-continuity-target" "$scratch/check/.row-continuity-target"; fi
chown -R root:macprovider "$scratch/check"
chmod 0750 "$scratch/check"
chmod 0640 "$scratch/check/.previous-target"
echo "PLAN_JSON=$(cat "$scratch/plan.json")"
overlay_args=""
if [ -e "$overlay" ]; then overlay_args="--config-overlay $overlay"; fi
rc=0
if [ "$pricing" = 1 ] && [ ! -f "$config_arg" ]; then
  rc=99; echo '{"ok": false, "errors": ["no spliced candidate to dry-load"]}' >"$scratch/dryload.json"
else
# shellcheck disable=SC2086
systemd-run --quiet --wait --pipe --collect -p RuntimeMaxSec=300 -p "EnvironmentFile=-$env_file" -p User=macprovider -p Group=macprovider \
  "$bin" --config "$config_arg" $overlay_args --validate-autotune-release "$sroot/releases/$name" \
  --previous-target "$scratch/check/.previous-target" $pricing_args </dev/null >"$scratch/dryload.json" 2>"$scratch/dryload.err" || rc=$?
fi
echo "DRYLOAD_RC=$rc"
echo "DRYLOAD_JSON=$(tail -n 1 "$scratch/dryload.json" | head -c 65536)"
STAGE

pf_dry_load() {
  local prev_arg="__EMPTY__" out entry
  REMOTE_SCRATCH="$(SSH 'umask 077 && mktemp -d /tmp/macprovider-content-preflight.XXXXXXXX')" || { record coordinator_dry_load 0 "cannot create a Pearl scratch dir"; return 1; }
  REMOTE_SCRATCH="${REMOTE_SCRATCH//$'\n'/}"
  case "$REMOTE_SCRATCH" in
    */macprovider-content-preflight.[A-Za-z0-9]*) ;;
    *) local bad="$REMOTE_SCRATCH"; REMOTE_SCRATCH=""; record coordinator_dry_load 0 "unsafe scratch dir: $bad"; return 1 ;;
  esac
  case "$REMOTE_SCRATCH" in *[!A-Za-z0-9._/-]*) REMOTE_SCRATCH=""; record coordinator_dry_load 0 "unsafe scratch dir"; return 1 ;; esac
  rm -rf "$WORK/upload"
  mkdir -p "$WORK/upload/incoming" "$WORK/upload/tools/scripts"
  cp "$REL"/* "$WORK/upload/incoming/"
  cp "$SCRIPT_DIR/autotune_window.py" "$WORK/upload/tools/autotune_window.py"
  # The whole catalog-verifier bundle beside the window helper, reported by
  # the reviewed-copy sha check (coverage itself reads only the validator's
  # admitted list).
  : >"$WORK/tools.expected"
  printf '%s %s\n' "$(sha256_file "$SCRIPT_DIR/autotune_window.py")" autotune_window.py >>"$WORK/tools.expected"
  for entry in $(grep -v '^#' "$SCRIPT_DIR/catalog-verifier-bundle.txt" | grep -v '^$'); do
    case "$entry" in scripts/*) ;; *) record coordinator_dry_load 0 "invalid catalog verifier bundle entry: $entry"; return 1 ;; esac
    case "${entry#scripts/}" in ""|*[!A-Za-z0-9._-]*) record coordinator_dry_load 0 "invalid catalog verifier bundle entry: $entry"; return 1 ;; esac
    cp "$REPO_ROOT/$entry" "$WORK/upload/tools/$entry"
    printf '%s %s\n' "$(sha256_file "$REPO_ROOT/$entry")" "$entry" >>"$WORK/tools.expected"
  done
  local upload_dirs="incoming tools"
  if [ "$PRICING" = 1 ]; then
    mkdir -p "$WORK/upload/pricing"
    cp "$PRICING_DIR/block.yaml" "$PRICING_DIR/ack.json" "$WORK/upload/pricing/"
    # Pinned at preflight: the saved --preflight-verdict's set, or (under the
    # lease) this run's preflight set; absent = pin now.
    if [ -f "$PRICING_DIR/pinned-names.json" ]; then cp "$PRICING_DIR/pinned-names.json" "$WORK/upload/pricing/"; fi
    upload_dirs="$upload_dirs pricing"
  fi
  # shellcheck disable=SC2086
  if ! tar -C "$WORK/upload" -cf - $upload_dirs | SSH "tar -xf - -C '$REMOTE_SCRATCH'"; then
    record coordinator_dry_load 0 "cannot upload the candidate to the Pearl scratch dir"; return 1
  fi
  [ -z "$ORIG_PREVIOUS_TARGET" ] || prev_arg="$(printf '%s' "$ORIG_PREVIOUS_TARGET" | base64 | tr -d '\n')"
  printf '%s' "$PF_REMOTE_STAGE" >"$WORK/stage.remote.sh"
  if ! out="$(SSH bash -s -- "$REMOTE_SCRATCH" "$REMOTE_AUTOTUNE_DIR" "$CURRENT_TARGET" "$prev_arg" "$RELEASE_DIRNAME" \
      "$COORD_ENV_FILE" "$COORD_BIN" "$COORD_CONFIG" "$COORD_OVERLAY" "$PRICING" <"$WORK/stage.remote.sh" 2>&1)"; then
    record coordinator_dry_load 0 "staging on Pearl failed: $(printf '%s' "$out" | tail -n 3)"; return 1
  fi
  printf '%s\n' "$out" >"$WORK/stage.out"
  if [ "$(printf '%s\n' "$out" | sed -n 's/^TOOL_SHA=//p')" != "$(LC_ALL=C sort -k2 "$WORK/tools.expected")" ]; then
    record coordinator_dry_load 0 "the window helper / verifier bundle on Pearl does not match the reviewed copies"; return 1
  fi
  printf '%s\n' "$out" | sed -n 's/^PLAN_JSON=//p' >"$WORK/plan.json"
  printf '%s\n' "$out" | sed -n 's/^DRYLOAD_JSON=//p' >"$WORK/dryload.json"
  local verdict want_cfg="$CONFIG_DISK_SHA"
  if [ "$PRICING" = 1 ]; then
    pf_pricing_stage_results || return 1
    want_cfg="$CAND_CONFIG_SHA"
  fi
  verdict="$(python3 - "$WORK/dryload.json" "$(printf '%s\n' "$out" | sed -n 's/^DRYLOAD_RC=//p')" \
    "$REL_ID" "$REL_CAND_SHA" "$REL_TIER2_ID" "$REL_TIER2_SHA" "$WORK/plan.json" "$want_cfg" "$OVERLAY_DISK_SHA" <<'PY'
import json, sys
path, rc, rid, sha, t2id, t2sha, plan, cfg_sha, ov_sha = sys.argv[1:]
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
# The config the validator decoded must be the config the coordinator applied
# (pricing: the spliced candidate over the applied overlay).
if not cfg_sha:
    problems.append("applied identity unknown (config_applied did not prove the on-disk config)")
elif v.get("config_sha256") != cfg_sha or v.get("overlay_sha256") != ov_sha:
    problems.append("dry-load decoded config %s/overlay %s, applied/on-disk is %s/%s" % (
        v.get("config_sha256"), v.get("overlay_sha256") or "-", cfg_sha, ov_sha or "-"))
print("; ".join(problems) if problems else "live binary accepts %s with the proposed window (%d retained) over the applied config" % (rid, want))
raise SystemExit(1 if problems else 0)
PY
)" || { record coordinator_dry_load 0 "$verdict"; return 1; }
  record coordinator_dry_load 1 "$verdict"
}

# #1693: the on-host pricing results: the splice digests, the effective-price
# diff, the pinned names, and the live binary's verdict digests and name
# resolutions. pricing-diff.json is the acknowledged object (effective diff +
# the binary's resolutions of the digested names outside the key grammar).
pf_pricing_stage_results() {
  local out
  out="$(python3 - "$WORK/stage.out" "$WORK/dryload.json" "$PRICING_DIR" "$CONFIG_DISK_SHA" "$(sha256_file "$REL/rate-card.json")" \
      "$SCRIPT_DIR/catalog-release.py" <<'PY'
import base64, hashlib, json, os, re, runpy, sys
stage, dryload, pdir, live_sha, card_sha, cr_path = sys.argv[1:]
cr = runpy.run_path(cr_path)
vals = {}
for line in open(stage, encoding="utf-8", errors="replace"):
    k, _, v = line.rstrip("\n").partition("=")
    if k in ("SPLICE_JSON", "PRICING_ERROR", "PRICING_DIFF_RC", "PRICING_DIFF_OUT", "PRICING_DIFF_B64", "PINNED_B64"):
        vals.setdefault(k, v)
hexre = re.compile(r"[0-9a-f]{64}")
def bad(msg):
    print(msg); raise SystemExit(1)
if "PRICING_ERROR" in vals:
    bad(vals["PRICING_ERROR"])
try:
    splice = json.loads(vals.get("SPLICE_JSON", ""))
    diff_out = json.loads(vals.get("PRICING_DIFF_OUT", ""))
    diff = base64.b64decode(vals.get("PRICING_DIFF_B64", ""), validate=True)
    pinned = base64.b64decode(vals.get("PINNED_B64", ""), validate=True)
except ValueError as exc:
    bad("malformed pricing stage output: %s" % exc)
if splice.get("live_config_sha256") != live_sha:
    bad("the splice read coordinator.yaml %s, applied/on-disk is %s" % (splice.get("live_config_sha256"), live_sha))
cand = splice.get("output_sha256", "")
if not hexre.fullmatch(cand):
    bad("the splice returned no candidate digest")
if diff_out.get("pricing_diff_sha256") != hashlib.sha256(diff).hexdigest():
    bad("the fetched pricing-diff.json is not the bytes pricing-effective-diff digested")
problems = []
if vals.get("PRICING_DIFF_RC") != "0" or diff_out.get("ok") is not True:
    problems.append("unacknowledged rate-row move(s) %s (new names: %s); list them in acknowledged-pricing-moves.json"
                    % (diff_out.get("unacknowledged_moves"), (diff_out.get("new_names") or {}).get("unacknowledged_moves")))
try:
    v = json.loads(open(dryload).read())
except ValueError:
    v = {}
rate, signed = v.get("rate_table_sha256", ""), v.get("signed_rate_card_sha256", "")
if not (isinstance(rate, str) and hexre.fullmatch(rate)):
    problems.append("the live binary reported no rate_table_sha256 (pricing needs the #1693 coordinator)")
if signed != card_sha:
    problems.append("the live binary loaded rate card %s, the release card is %s" % (signed, card_sha))
d = json.loads(diff)
acks = set()
for m in json.load(open(os.path.join(pdir, "ack.json"))).get("moves", []):
    acks.add((m["model"], m["from_row"], m["to_row"]))
esc = lambda n: "".join("\\x%02x" % ord(c) if ord(c) < 0x20 or 0x7F <= ord(c) <= 0x9F or c == "\\" else c for c in n)
resolutions = v.get("model_resolutions") or []
for r in resolutions:
    old, new = (r.get("old") or {}).get("row_key"), (r.get("new") or {}).get("row_key")
    if old != new and (r.get("name"), old, new) not in acks and not cr["pricing_move_is_own_row"](r.get("name"), old, new):
        problems.append("served name %r moves %s -> %s (resolved by the live binary) without an acknowledgement" % (esc(r.get("name", "")), old, new))
open(os.path.join(pdir, "pinned-names.json"), "wb").write(pinned)
# The acknowledged object: the effective diff plus the live binary
# resolutions of every digested name outside the Python key grammar. Its
# digest is what the operator acks and what the lease re-derives.
try:
    acknowledged = cr["pricing_acknowledged_object"](d, resolutions)
except cr["CatalogError"] as exc:
    problems.append("cannot build the acknowledged pricing object: %s" % exc)
if problems:
    bad("; ".join(problems))
data = cr["pricing_canonical_bytes"](acknowledged)
diff_sha = hashlib.sha256(data).hexdigest()
open(os.path.join(pdir, "pricing-diff.json"), "wb").write(data)
summary = {
    "candidate_config_sha256": cand, "pricing_diff_sha256": diff_sha, "expected_rate_table_sha256": rate,
    "expected_signed_rate_card_sha256": signed, "pinned_names_sha256": d.get("pinned_names_sha256"),
    "rows": d.get("rows"), "models": d.get("models"), "unresolved_names": d.get("unresolved_names"),
    "model_resolutions": acknowledged["model_resolutions"],
}
json.dump(summary, open(os.path.join(pdir, "stage-summary.json"), "w"), sort_keys=True)
print("%s %s %s %s" % (cand, diff_sha, rate, signed))
PY
)" || { record pricing_effective_diff 0 "$out"; record coordinator_dry_load 0 "pricing stage refused: $out"; return 1; }
  read -r CAND_CONFIG_SHA PRICING_DIFF_SHA EXPECTED_RATE_SHA EXPECTED_SIGNED_SHA <<VALS
$out
VALS
  pricing_show_table >&3 || { record pricing_effective_diff 0 "the price table carries an unescaped label; not acknowledgeable"; return 1; }
  record pricing_effective_diff 1 "effective-price diff $PRICING_DIFF_SHA over every served name; no unacknowledged row move; candidate yaml $CAND_CONFIG_SHA"
}

# The price table the operator acknowledges. Model and row labels arrive
# escaped by catalog-release.py escape_model_name (no Cc/Cf/Zl/Zp code point
# survives it); a label that still carries one is refused, never printed.
pricing_show_table() {
  python3 - "$PRICING_DIR/stage-summary.json" <<'PY'
import json, sys, unicodedata
s = json.load(open(sys.argv[1]))
def label(value):
    value = str(value)
    if any(unicodedata.category(ch) in ("Cc", "Cf", "Zl", "Zp") for ch in value):
        raise SystemExit("[catalog-content] pricing: refusing to print an unescaped control/format character in a price-table label")
    return value
print("[catalog-content] pricing: effective price changes (credits per Mtok: prompt / cache-hit / completion)")
fmt = lambda r: "%s / %s / %s" % (r["prompt_rate_per_mtok"], r["prompt_cache_hit_rate_per_mtok"], r["completion_rate_per_mtok"])
for m in s.get("models") or []:
    move = " (row %s -> %s)" % (label(m["old_row"]), label(m["new_row"])) if m.get("move") else ""
    print("[catalog-content]   %s: %s -> %s%s" % (label(m["model"]), fmt(m["old"]), fmt(m["new"]), move))
gofmt = lambda r: "%s / %s / %s" % (r["prompt_credits_per_mtok"], r["prompt_cache_hit_credits_per_mtok"], r["completion_credits_per_mtok"])
for r in s.get("model_resolutions") or []:
    if r["old"] != r["new"]:
        move = " (row %s -> %s)" % (label(r["old"]["row_key"]), label(r["new"]["row_key"])) if r["old"]["row_key"] != r["new"]["row_key"] else ""
        print("[catalog-content]   %s (resolved by the live binary): %s -> %s%s" % (label(r["name"]), gofmt(r["old"]), gofmt(r["new"]), move))
print("[catalog-content] pricing: acknowledge with --pricing-diff-sha256 %s" % s["pricing_diff_sha256"])
PY
}

# #1693: the content gate again, now bound to the fetched effective diff.
pf_pricing_gate() {
  local rc=0 detail
  python3 -I "$SCRIPT_DIR/catalog-release.py" content-gate --release "$REL" --live "$LIVE" --commit "$COMMIT" \
    --tier2-content-index "$WORK/gate/tier2-content-index.json" --tier2-coordinator-config "$WORK/gate/tier2-trust-root.yaml" \
    --pricing-diff "$PRICING_DIR/pricing-diff.json" \
    --pricing-diff-sha256 "$PRICING_DIFF_SHA" >"$WORK/gate-pricing.json" 2>"$WORK/gate-pricing.err" || rc=$?
  if ! detail="$(python3 -c '
import json, sys
v = json.load(open(sys.argv[1]))
ok = v.get("ok") is True and v.get("lane") == "catalog-content"
ok = ok and v.get("commit_block_sha256") == sys.argv[2] and v.get("pricing_diff_sha256") == sys.argv[3]
print("lane %s: %s" % (v.get("lane"), "; ".join(v.get("reasons") or []) or "commit block or diff digest mismatch"))
raise SystemExit(0 if ok else 1)' "$WORK/gate-pricing.json" "$COMMIT_BLOCK_SHA" "$PRICING_DIFF_SHA" 2>/dev/null)" || [ "$rc" -ne 0 ]; then
    record pricing_gate 0 "content-gate bound to the effective diff refused (rc=$rc): ${detail:-$(tail -n 2 "$WORK/gate-pricing.err")}"; return 1
  fi
  record pricing_gate 1 "content-gate accepts the commit block $COMMIT_BLOCK_SHA and the effective diff $PRICING_DIFF_SHA"
  python3 - "$PRICING_DIR" "$COMMIT" "$COMMIT_BLOCK_SHA" "$PRIOR_RATE_SHA" "$PRIOR_SIGNED_SHA" "$PRIOR_SNAPSHOT_ID" \
      "$CONFIG_DISK_SHA" "$OVERLAY_DISK_SHA" "$ACK_MOVES_SHA" <<'PY'
import json, os, sys
pdir, commit, block, prate, psigned, psnap, pcfg, ov, ack = sys.argv[1:]
s = json.load(open(os.path.join(pdir, "stage-summary.json")))
s.update(commit=commit, commit_block_sha256=block, prior_rate_table_sha256=prate, prior_signed_rate_card_sha256=psigned,
         prior_billing_snapshot_id=int(psnap), prior_config_sha256=pcfg, overlay_sha256=ov, acknowledged_moves_sha256=ack,
         pinned_names=json.load(open(os.path.join(pdir, "pinned-names.json"))))
json.dump(s, open(os.path.join(pdir, "verdict-pricing.json"), "w"), sort_keys=True, ensure_ascii=True)
PY
}

# --preflight-verdict: reuse the pinned name set the operator reviewed.
load_preflight_pins() {
  [ -n "$PREFLIGHT_VERDICT_FILE" ] || return 0
  python3 - "$PREFLIGHT_VERDICT_FILE" "$COMMIT" "$PRICING_DIR/pinned-names.json" "$SCRIPT_DIR/catalog-release.py" <<'PY' || fatal "--preflight-verdict is not a pricing preflight verdict for $COMMIT"
import json, runpy, sys
path, commit, out, cr_path = sys.argv[1:]
lines = [l for l in open(path, encoding="utf-8") if l.lstrip().startswith("{")]
v = json.loads(lines[-1])
p = v.get("pricing") or {}
names = p.get("pinned_names")
if p.get("commit") != commit or not isinstance(names, list) or not all(isinstance(n, str) for n in names):
    raise SystemExit(1)
cr = runpy.run_path(cr_path)
if cr["names_sha256"](set(names)) != p.get("pinned_names_sha256"):
    raise SystemExit(1)
json.dump(names, open(out, "w"))
PY
  log "pricing: reusing the $(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$PRICING_DIR/pinned-names.json") model names pinned by the saved preflight verdict"
}

# Coverage judges /poolz against EXACTLY the catalogs the live coordinator
# binary admits after this reload: the `admitted` set of the dry-load verdict
# pf_dry_load just validated (current + retained window + restamps).
pf_coverage() {
  local rc=0 detail
  if ! python3 -c 'import json,sys; v=json.load(open(sys.argv[1])); a=v.get("admitted"); sys.exit(0 if v.get("ok") is True and isinstance(a, list) and a else 1)' "$WORK/dryload.json" 2>/dev/null; then
    record window_coverage 0 "the coordinator validator did not report ok with an admitted set (coverage unknown)"; return 1
  fi
  if ! fetch_poolz "$WORK/poolz-preflight.json"; then
    record window_coverage 0 "coordinator /poolz unreachable or refused the operator bearer (coverage unknown)"; return 1
  fi
  SSH "cat > '$REMOTE_SCRATCH/poolz.json'" <"$WORK/poolz-preflight.json" || { record window_coverage 0 "cannot stage /poolz on Pearl"; return 1; }
  SSH "cat > '$REMOTE_SCRATCH/admitted.json'" <"$WORK/dryload.json" || { record window_coverage 0 "cannot stage the validator verdict on Pearl"; return 1; }
  SSH "window='$REMOTE_SCRATCH/tools/autotune_window.py'; python3 -I \"\$window\" coverage --admitted-json '$REMOTE_SCRATCH/admitted.json' --poolz-json '$REMOTE_SCRATCH/poolz.json'" \
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
# billing snapshot). Refuse unless the on-disk bytes are exactly the bytes the
# coordinator last applied: the sha256 of coordinator.yaml and the overlay must
# equal the digests in its applied-config record (written after every
# successful boot/SIGHUP). A missing or unparseable record is "applied identity
# unknown" and fails closed.
pf_config_applied() {
  local out verdict
  CONFIG_DISK_SHA=""
  OVERLAY_DISK_SHA=""
  if ! out="$(SSH "set -e
for spec in 'config=$COORD_CONFIG' 'overlay=$COORD_OVERLAY'; do
  p=\"\${spec#*=}\"
  if [ -e \"\$p\" ]; then echo \"SHA=\${spec%%=*} \$(sha256sum \"\$p\" | cut -d' ' -f1)\"; else echo \"SHA=\${spec%%=*} ABSENT\"; fi
done
if [ -f '$APPLIED_CONFIG_RECORD' ]; then echo \"RECORD=\$(head -c 65536 '$APPLIED_CONFIG_RECORD' | head -n 1)\"; else echo RECORD=; fi" 2>&1)"; then
    record config_applied 0 "cannot read coordinator config digests / applied-config record: $(printf '%s' "$out" | tail -n 2)"; return 1
  fi
  verdict="$(printf '%s\n' "$out" | python3 -c '
import json, re, sys
config, overlay, schema = sys.argv[1:]
disk, record = {}, None
for line in sys.stdin:
    line = line.rstrip("\n")
    if line.startswith("SHA="):
        path, value = line[4:].rsplit(" ", 1)
        disk[path] = value
    elif line.startswith("RECORD="):
        try:
            record = json.loads(line[7:])
        except ValueError:
            record = None
hexre = re.compile(r"[0-9a-f]{64}")
cfg, ov = disk.get("config"), disk.get("overlay")
if not cfg or not hexre.fullmatch(cfg):
    print("coordinator.yaml not found"); raise SystemExit(1)
ov = "" if ov == "ABSENT" else ov
if ov and not hexre.fullmatch(ov):
    print("cannot hash the coordinator overlay"); raise SystemExit(1)
if not isinstance(record, dict) or record.get("schema") != schema:
    print("applied identity unknown: no parseable %s record" % schema); raise SystemExit(1)
if record.get("config_path") != config or record.get("config_sha256") != cfg:
    print("pending config edits not yet applied (a SIGHUP would apply them): coordinator.yaml sha %s != applied %s" % (cfg, record.get("config_sha256"))); raise SystemExit(1)
if (record.get("overlay_sha256") or "") != ov or (ov and record.get("overlay_path") != overlay):
    print("pending overlay edits not yet applied (a SIGHUP would apply them): overlay sha %s != applied %s" % (ov or "-", record.get("overlay_sha256") or "-")); raise SystemExit(1)
print("OK %s %s" % (cfg, ov or "-"))
' "$COORD_CONFIG" "$COORD_OVERLAY" "$APPLIED_CONFIG_SCHEMA")" || { record config_applied 0 "$verdict"; return 1; }
  CONFIG_DISK_SHA="$(printf '%s' "$verdict" | cut -d' ' -f2)"
  OVERLAY_DISK_SHA="$(printf '%s' "$verdict" | cut -d' ' -f3)"
  [ "$OVERLAY_DISK_SHA" != - ] || OVERLAY_DISK_SHA=""
  record config_applied 1 "on-disk coordinator.yaml/overlay equal the coordinator's applied-config record ($CONFIG_DISK_SHA/${OVERLAY_DISK_SHA:--})"
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
      pf_config_applied || true
      if pf_live; then
        pf_content_gate || true
        pf_buyer_serving_e2e || true
        if [ "$PRICING" = 1 ]; then
          load_preflight_pins
          pf_pricing_host || true
          if check_ok pricing_host_state && check_ok config_applied; then
            pf_dry_load && pf_pricing_gate || true
            check_ok coordinator_dry_load && check_ok canary_config && pf_coverage || true
          fi
        else
          pf_dry_load && check_ok canary_config && pf_coverage || true
        fi
      fi
      if check_ok canary_config; then
        pf_operator_key || true
        check_ok rollback_preconditions && pf_canary || true
      fi
    fi
  fi
  # Every named check must have run and passed.
  local name
  local required="commit tooling_matches_commit release_assembled canary_config pearl_reachable pearl_locks_free
      pricing_txn_absent rollback_preconditions content_gate buyer_serving_e2e coordinator_dry_load
      window_coverage config_applied canary_token_operator_key canary_reachable"
  [ "$PRICING" != 1 ] || required="$required pricing_release pricing_host_state pricing_effective_diff pricing_gate"
  for name in $required; do
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
rejects = ("autotune feed reload rejected", "tier2 config reload rejected", "billing config reload rejected",
           "autotune runtime economics reload rejected")
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
)" && applied_after_hup && break
    case "$verdict" in
      REJECT*) ev_fail b "coordinator logged '${verdict#REJECT }' after the HUP"; return 1 ;;
      OK) verdict="APPLIED $APPLIED_AFTER_HUP" ;;
    esac
    if [ "$SECONDS" -ge "$deadline" ]; then
      case "$verdict" in
        APPLIED*) ev_fail b "${verdict#APPLIED }" ;;
        *) ev_fail b "no autotune_feed_sighup_reload for $REL_ID with tier2 $REL_TIER2_ID/$REL_TIER2_SHA" ;;
      esac
      return 1
    fi
    sleep 2
  done
  log "evidence (b): autotune_feed_sighup_reload $REL_ID tier2 $REL_TIER2_ID sha $REL_TIER2_SHA; applied-config record source=sighup with the pre-HUP digests; no reload rejection"
}

# The coordinator's applied-config record must show THIS HUP applied exactly
# the config the lease proved (source=sighup, loaded_at >= T_HUP, same digests).
APPLIED_AFTER_HUP=""
applied_after_hup() {
  local raw
  raw="$(SSH "head -c 65536 '$APPLIED_CONFIG_RECORD' 2>/dev/null | head -n 1")" || raw=""
  APPLIED_AFTER_HUP="$(printf '%s' "$raw" | python3 -c '
import calendar, json, re, sys, time
schema, t_hup, cfg, ov, pricing, rate, signed, psnap = sys.argv[1:]
try:
    r = json.loads(sys.stdin.read())
except ValueError:
    print("applied identity unknown after the HUP: no parseable applied-config record"); raise SystemExit(1)
m = re.fullmatch(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?Z", str(r.get("loaded_at", "")))
loaded = calendar.timegm(time.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S")) + float(m.group(2) or 0) if m else None
if r.get("schema") != schema or r.get("source") != "sighup" or loaded is None or loaded < float(t_hup):
    print("no applied-config record from this SIGHUP (source=%s loaded_at=%s)" % (r.get("source"), r.get("loaded_at"))); raise SystemExit(1)
if r.get("config_sha256") != cfg or (r.get("overlay_sha256") or "") != ov:
    print("the SIGHUP applied config %s/overlay %s, expected %s/%s" % (r.get("config_sha256"), r.get("overlay_sha256") or "-", cfg, ov or "-")); raise SystemExit(1)
# #1693: the billing table and the served card this HUP committed.
if pricing == "1":
    snap = r.get("billing_snapshot_id")
    if r.get("rate_table_sha256") != rate or r.get("signed_rate_card_sha256") != signed:
        print("the SIGHUP applied rate table %s / served card %s, expected %s / %s" % (r.get("rate_table_sha256"), r.get("signed_rate_card_sha256"), rate, signed)); raise SystemExit(1)
    if not isinstance(snap, int) or snap <= int(psnap):
        print("the SIGHUP committed no new billing snapshot (billing_snapshot_id %s, prior %s)" % (snap, psnap)); raise SystemExit(1)
' "$APPLIED_CONFIG_SCHEMA" "$T_HUP" "${CAND_CONFIG_SHA:-$CONFIG_DISK_SHA}" "$OVERLAY_DISK_SHA" "$PRICING" \
    "${EXPECTED_RATE_SHA:--}" "${EXPECTED_SIGNED_SHA:--}" "${PRIOR_SNAPSHOT_ID:-0}")"
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

# (d) watch: any catalog_incompatible rejection since the HUP of a catalog the
# coordinator admitted before activation (the validated `admitted` set this
# reload was proven to keep, plus the live release) fails. Rejections of
# catalogs that were already inadmissible are chronic: logged, not failed.
# No catalog-unavailable increase either.
ev_d_watch() {
  local end=$((SECONDS + WATCH_SECONDS)) verdict chronic=""
  log "evidence (d): watching for ${WATCH_SECONDS}s (poll ${POLL_SECONDS}s)"
  while :; do
    journal_since "$T_HUP" "$WORK/journal-watch.txt" || { ev_fail d "cannot read the coordinator journal"; return 1; }
    verdict="$(python3 - "$WORK/admitted-prehup.json" "$WORK/journal-watch.txt" "$LIVE_ID" "$LIVE_CAND_SHA" <<'PY'
import json, sys
verdict, journal, live_id, live_sha = sys.argv[1:]
admitted = {(r["release_id"], str(r["candidates_sha256"]).lower()) for r in json.load(open(verdict))["admitted"]}
admitted.add((live_id, live_sha.lower()))
bad, chronic = {}, {}
for line in open(journal, encoding="utf-8", errors="replace"):
    if "catalog_incompatible" not in line and "provider catalog release is incompatible" not in line:
        continue
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if not isinstance(e, dict) or not (e.get("catalog_release_id") or e.get("catalog_candidate_sha256")):
        continue  # the paired close line; the keyed warn carries the catalog
    k = (str(e.get("catalog_release_id", "")), str(e.get("catalog_candidate_sha256", "")).lower())
    target = bad if k in admitted else chronic
    target[k] = target.get(k, 0) + 1
fmt = lambda d: ", ".join("%s/%s (%d)" % (k[0], k[1], n) for k, n in sorted(d.items()))
if bad:
    print("catalog_incompatible after the HUP for catalog(s) admissible before it: " + fmt(bad)); raise SystemExit(1)
if chronic:
    print("chronic (already inadmissible before the HUP): " + fmt(chronic))
PY
)" || { ev_fail d "$verdict"; return 1; }
    [ -z "$verdict" ] || chronic="$verdict"
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
  [ -z "$chronic" ] || log "evidence (d): diagnostic only, not a failure: catalog_incompatible $chronic"
  log "evidence (d): no catalog_incompatible for an admissible catalog and no catalog-unavailable increase for ${WATCH_SECONDS}s"
}

# C6: keep the failed release retained ONLY if it passed integrity + (a)/(b),
# the failure is not (d)/(e), and /poolz shows live adopters; never evict a
# retained release that has live adopters to make room.
plan_retention() {
  AA_ROLLBACK_WINDOW=""
  # #1693: a pricing rollback restores the journal's exact prior window.
  [ "$PRICING" != 1 ] || return 0
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

# #1693: before `verified`, under the lease, re-open (O_NOFOLLOW) and hash S:
# it must still be exactly the journal's candidate pair.
ev_pricing_state() {
  [ "$PRICING" = 1 ] || return 0
  aa_lease_sh "python3 -I '$PRICING_HELPER' check-state candidate" >&3 2>&1 ||
    { ev_fail s "the on-disk pair is not the journal's candidate (yaml, overlay, current, window or release bytes moved)"; return 1; }
  log "evidence (s): on-disk yaml/overlay/current/window/release set equal the journal's candidate"
}

ccr_evidence() {
  ev_a_served_bytes || return 1
  ev_b_journal || return 1
  CCR_PASSED_AB=1
  ev_c_canary || { plan_retention; return 1; }
  ev_d_watch || return 1
  ev_pricing_state || return 1
  return 0
}

# #1693: after every evidence step passed, the journal becomes `verified`
# (durable, terminal) and then is finalized, as two separate steps. If marking
# verified fails the lane does NOT report success: the journal stays in
# `verifying` and --recover-pricing-txn rolls it back. Once verified, a
# correct price is never rolled back: a finalize failure is an ALERT and
# --recover-pricing-txn finalizes the candidate.
pricing_finalize() {
  if ! aa_lease_sh "python3 -I '$PRICING_HELPER' phase verified" >&3 2>&1; then
    log "ALERT: the pricing journal could not be marked verified; it stays in phase verifying and this run does NOT succeed. Run scripts/catalog-content-release.sh --recover-pricing-txn, which rolls the unverified transaction back ($RUNBOOK_PRICING_TXN)"
    return 1
  fi
  PRICING_VERIFIED=1
  aa_lease_sh "python3 -I '$PRICING_HELPER' finalize candidate" >&3 2>&1 && return 0
  log "ALERT: the pricing journal is verified but could not be finalized; the candidate is live and is never rolled back. Run scripts/catalog-content-release.sh --recover-pricing-txn to finalize it ($RUNBOOK_PRICING_TXN)"
  return 0
}

# #1693 I3: the gateway serves the public card from a 300 s cache; convergence
# within 660 s is informational and never rolls back a correct price.
gateway_convergence() {
  local deadline=$((SECONDS + GATEWAY_CONVERGENCE_SECONDS))
  while :; do
    if curl -fsS --max-time 10 --max-filesize 16777216 "$GATEWAY_RATE_CARD_URL" -o "$WORK/gw-card.json" 2>/dev/null &&
       cmp -s "$WORK/gw-card.json" "$REL/rate-card.json"; then
      log "gateway convergence: $GATEWAY_RATE_CARD_URL serves the release rate card"
      return 0
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      log "ALERT (informational, not rolled back): $GATEWAY_RATE_CARD_URL did not serve the release rate card within ${GATEWAY_CONVERGENCE_SECONDS}s"
      return 0
    fi
    sleep 5
  done
}

# Runs inside aa_rollback after the remote rollback returned.
ccr_after_rollback() {
  CCR_ROLLED_BACK=1
  case "$AA_ROLLBACK_OUT" in
    *"pricing journal verified; candidate finalized, not rolled back"*)
      # The journal became verified before the rollback ran: terminal, the
      # candidate stays live (a verified price is never rolled back).
      PRICING_VERIFIED=1
      log "ALERT: the pricing journal was already verified; the candidate stays live and was finalized, not rolled back"
      return 0
      ;;
  esac
  CCR_FATAL_RC=4
  case "$AA_ROLLBACK_OUT" in
    *"rolled back to "*) ;;
    *)
      log "ALERT: rollback did not restore current (rc=$AA_ROLLBACK_RC)"
      CCR_FATAL_RC=5
      ;;
  esac
  if [ "$PRICING" = 1 ]; then
    pricing_after_rollback
  elif [ "$CCR_FATAL_RC" = 4 ] && ! rollback_hup_verified; then
    log "ALERT: the rollback re-HUP was rejected or not observed; restarting $COORDINATOR_UNIT (controlled)"
    if aa_lease_sh "systemctl restart '$COORDINATOR_UNIT' && systemctl is-active --quiet '$COORDINATOR_UNIT'" &&
       coordinator_ready_after_restart && rollback_served_verified; then
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

# #1693 L7: the journal-driven rollback is proven by the coordinator itself —
# an applied-config record since the rollback with the prior yaml, rate table
# and served card digests and an advanced billing snapshot, plus the prior
# served bytes — then the journal is finalized. A rejected re-HUP gets the
# controlled restart (pre-start skips: this lease holds the lock set; the
# journal is handed to the pricing closer first) and the boot record must
# prove the same.
pricing_prior_live() { # <since epoch> <source> [ready seconds]
  aa_lease_sh "python3 -I '$PRICING_HELPER' verify-live prior --since '$1' --source '$2' --wait-seconds '$SETTLE_SECONDS' --ready-seconds '${3:-0}'" >&3 2>&1 &&
    rollback_served_verified
}
# After a controlled restart: wait (bounded by CATALOG_COORDINATOR_READY_SECONDS)
# for the coordinator to be ready before judging it. A slow boot is not a
# failed rollback, and is never diagnosed as a foreign write.
coordinator_ready_after_restart() {
  log "waiting up to ${READY_SECONDS}s for $COORDINATOR_UNIT to be ready (active + /healthz)"
  aa_lease_sh "$(_aa_coord_ready_fn)
coord_ready_pid '$COORDINATOR_UNIT' >/dev/null" >&3 2>&1 ||
    { log "ALERT: $COORDINATOR_UNIT was not ready within ${READY_SECONDS}s after the controlled restart"; return 1; }
}
pricing_after_rollback() {
  local t_restart
  if [ "$CCR_FATAL_RC" = 4 ] && ! pricing_prior_live "$T_RB" sighup; then
    log "ALERT: the rollback re-HUP did not prove the prior pair live; restarting $COORDINATOR_UNIT (controlled)"
    t_restart="$(remote_now 2>/dev/null || echo "$T_RB")"
    # E2 V8: a boot can outlast READY_SECONDS (the pre-listen startup ledger
    # scan grows with the day's traffic). Stamp the restored prior pair first,
    # so the restart's pricing closer finalizes the journal from the boot
    # record once the coordinator is up, even after this lane gives up.
    if ! aa_lease_sh "python3 -I '$PRICING_HELPER' hand-to-closer" >&3 2>&1; then
      log "ALERT: could not hand the restored pricing journal to $COORDINATOR_UNIT's pricing closer; restarting anyway"
    fi
    if ! aa_lease_sh "systemctl restart '$COORDINATOR_UNIT' && systemctl is-active --quiet '$COORDINATOR_UNIT'" ||
       ! pricing_prior_live "$t_restart" boot "$READY_SECONDS"; then
      log "ALERT: controlled coordinator restart did not prove the prior pair live within ${READY_SECONDS}s; the pricing journal is kept (a restored-unverified journal is finalized by macprovider-coordinator-pricing-close.service once the boot record proves the prior pair)"
      CCR_FATAL_RC=5
    fi
  fi
  if [ "$CCR_FATAL_RC" = 4 ]; then
    if aa_lease_sh "python3 -I '$PRICING_HELPER' phase rolled-back && python3 -I '$PRICING_HELPER' finalize prior" >&3 2>&1; then
      log "pricing journal rolled back and finalized: yaml, current and window are the prior pair"
    else
      log "ALERT: the pricing journal could not be finalized after the rollback; run --recover-pricing-txn"
      CCR_FATAL_RC=5
    fi
  fi
}

rollback_hup_verified() {
  local deadline=$((SECONDS + SETTLE_SECONDS))
  while :; do
    if journal_since "$T_RB" "$WORK/journal-rb.txt"; then
      if grep -qF -e 'autotune feed reload rejected' -e 'tier2 config reload rejected' -e 'billing config reload rejected' \
          -e 'autotune runtime economics reload rejected' "$WORK/journal-rb.txt"; then
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
if [ "$MODE" = recover-pricing-txn ]; then
  # Journal-only state: no commit, no canary. The installed helper must be the
  # reviewed copy this tooling carries; full verify-directory
  # (--allow-expired-tier2) of a terminal side runs from the shipped bundle
  # with an explicit Tier-2 trust root: the one the journal pinned at begin,
  # or (a journal begun without one) this checkout's HEAD coordinator.yaml,
  # shipped beside the verifier and sha-pinned.
  trap 'exit 71' HUP INT TERM
  AA_LOCK_MODE=lease
  aa_lease_acquire
  aa_install_helpers
  [ "$(SSH "sha256sum '$PRICING_HELPER' 2>/dev/null" | cut -d' ' -f1)" = "$(sha256_file "$REPO_ROOT/phase4-coordinator/dist/coordinator-pricing-recover")" ] ||
    { CCR_FATAL_RC=5; fatal "the installed $PRICING_HELPER is not this tooling's reviewed copy; follow $RUNBOOK_PRICING_TXN"; }
  mkdir -p "$WORK/gate"
  git -C "$REPO_ROOT" show "HEAD:phase4-coordinator/dist/coordinator.yaml" >"$WORK/gate/tier2-trust-root.yaml" 2>/dev/null &&
    [ -s "$WORK/gate/tier2-trust-root.yaml" ] ||
    { CCR_FATAL_RC=5; fatal "cannot read the Tier-2 trust root (HEAD:phase4-coordinator/dist/coordinator.yaml); follow $RUNBOOK_PRICING_TXN"; }
  T2_ROOT_SHA="$(sha256_file "$WORK/gate/tier2-trust-root.yaml")"
  SSH "cat >'$LOCK_HELPER_DIR/tier2-trust-root.yaml'" <"$WORK/gate/tier2-trust-root.yaml" &&
    [ "$(SSH "sha256sum '$LOCK_HELPER_DIR/tier2-trust-root.yaml'" | cut -d' ' -f1)" = "$T2_ROOT_SHA" ] ||
    { CCR_FATAL_RC=5; fatal "cannot install the Tier-2 trust root on $PEARL_SSH; follow $RUNBOOK_PRICING_TXN"; }
  rc=0
  aa_lease_sh "python3 -I '$PRICING_HELPER' recover --verifier '$CONTINUITY_VERIFIER' --tier2-trust-root '$LOCK_HELPER_DIR/tier2-trust-root.yaml' --tier2-trust-root-sha256 '$T2_ROOT_SHA' --wait-seconds '$SETTLE_SECONDS' --ready-seconds '$READY_SECONDS'" || rc=$?
  if [ "$rc" -eq 0 ]; then log "pricing transaction recovery: done"; exit 0; fi
  if [ "$rc" -eq 4 ]; then
    log "pricing transaction recovery WAITING: $COORDINATOR_UNIT is down or still booting (not a foreign write); the journal is kept; re-run --recover-pricing-txn once it serves /healthz ($RUNBOOK_PRICING_TXN)"
    exit 5
  fi
  log "pricing transaction recovery STOPPED (rc=$rc): the journal is kept; follow $RUNBOOK_PRICING_TXN"
  exit 5
fi

if [ "$MODE" = host-check ]; then
  log "host-check: pricing readiness of $PEARL_SSH at commit $COMMIT (read-only)"
  pf_commit && pf_tooling || true
  if check_ok tooling_matches_commit; then
    pf_pearl || true
    if check_ok pearl_reachable; then
      pf_config_applied || true
      pf_pricing_host || true
    fi
  fi
  for _name in commit tooling_matches_commit pearl_reachable pearl_locks_free pricing_txn_absent config_applied pricing_host_state; do
    grep -q "^$_name	" "$CHECKS" || record "$_name" 0 "not run: an earlier check failed"
  done
  emit_verdict
  [ -n "$(failed_checks)" ] || exit 0
  exit 3
fi

if [ "$MODE" = preflight ]; then
  if run_preflight; then exit 0; fi
  exit 3
fi

log "deploy: preflight"
if ! run_preflight; then
  log "preflight NO_GO: $(failed_checks | tr '\n' ' ')"
  exit 3
fi
# #1693 L3: the operator acknowledges exactly the effective diff shown.
if [ "$PRICING" = 1 ]; then
  if [ -z "$PRICING_ACK" ]; then
    log "pricing release: re-run with --pricing-diff-sha256 $PRICING_DIFF_SHA after reviewing the price table above"
    exit 3
  fi
  if [ "$PRICING_ACK" != "$PRICING_DIFF_SHA" ]; then
    log "pricing release: --pricing-diff-sha256 $PRICING_ACK does not match this preflight's effective diff $PRICING_DIFF_SHA; review the table and re-acknowledge"
    exit 3
  fi
  log "pricing: operator acknowledged effective diff $PRICING_DIFF_SHA"
  PF_PRICING_DIGESTS="$CAND_CONFIG_SHA $PRICING_DIFF_SHA $EXPECTED_RATE_SHA $EXPECTED_SIGNED_SHA $PRIOR_RATE_SHA $PRIOR_SIGNED_SHA $PRIOR_SNAPSHOT_ID $CONFIG_DISK_SHA ${OVERLAY_DISK_SHA:--}"
elif [ -n "$PRICING_ACK" ]; then
  log "--pricing-diff-sha256 given but this release changes no rate-card rows"
  exit 3
fi
PREFLIGHT_CURRENT="$CURRENT_TARGET"
PREFLIGHT_WINDOW_B64="$ORIG_PREVIOUS_TARGET_B64"
SSH "rm -rf '$REMOTE_SCRATCH'" >/dev/null 2>&1 || true
REMOTE_SCRATCH=""

trap 'exit 71' HUP INT TERM
aa_lease_acquire
aa_read_live_targets
[ "$CURRENT_TARGET" = "$PREFLIGHT_CURRENT" ] && [ "$ORIG_PREVIOUS_TARGET_B64" = "$PREFLIGHT_WINDOW_B64" ] ||
  fatal "live targets moved between preflight and the lease; re-run"
aa_refuse_existing_release
# Stale pricing-journal temp dirs of dead processes are removed at the start
# of every lane run, under the lock set.
aa_lease_sh "[ ! -f '$PRICING_HELPER' ] || python3 -I '$PRICING_HELPER' cleanup-tmp" >&3 2>&1 || fatal "cannot clean stale pricing journal temp dirs"
# Re-run, under the lease and against the then-current live state, the checks
# a SIGHUP depends on: applied-config identity, the LIVE binary's dry-load of
# this release with the proposed window over that same config, and coverage.
: >"$CHECKS"
pf_config_applied || fatal "config identity under the lease: $(cut -f3 "$CHECKS")"
if [ "$PRICING" = 1 ]; then
  # L3: re-run L2 under the full lock set; refuse if any digest moved.
  pf_pricing_host || fatal "pricing host state under the lease: $(cut -f3 "$CHECKS" | tail -n 1)"
fi
pf_dry_load || fatal "coordinator dry-load under the lease refused: $(cut -f3 "$CHECKS" | tail -n 1)"
pf_coverage || fatal "window coverage under the lease: $(cut -f3 "$CHECKS" | tail -n 1)"
if [ "$PRICING" = 1 ]; then
  pf_pricing_gate || fatal "pricing gate under the lease: $(cut -f3 "$CHECKS" | tail -n 1)"
  [ "$CAND_CONFIG_SHA $PRICING_DIFF_SHA $EXPECTED_RATE_SHA $EXPECTED_SIGNED_SHA $PRIOR_RATE_SHA $PRIOR_SIGNED_SHA $PRIOR_SNAPSHOT_ID $CONFIG_DISK_SHA ${OVERLAY_DISK_SHA:--}" = "$PF_PRICING_DIGESTS" ] ||
    fatal "pricing digests moved between the acknowledged preflight and the lease; re-run preflight"
  python3 - "$PRICING_DIR/verdict.json" "$PRICING_DIFF_SHA" "$CAND_CONFIG_SHA" "$COMMIT_BLOCK_SHA" "$EXPECTED_RATE_SHA" \
      "$EXPECTED_SIGNED_SHA" "$PRIOR_RATE_SHA" "$PRIOR_SIGNED_SHA" "$CONFIG_DISK_SHA" "$PRIOR_SNAPSHOT_ID" "$OVERLAY_DISK_SHA" "$COMMIT" <<'PY' || fatal "cannot build the pricing journal verdict"
import json, sys
out = sys.argv[1]
keys = ("pricing_diff_sha256", "candidate_config_sha256", "commit_block_sha256", "expected_rate_table_sha256",
        "expected_signed_rate_card_sha256", "prior_rate_table_sha256", "prior_signed_rate_card_sha256", "prior_config_sha256")
v = dict(zip(keys, sys.argv[2:10]))
v["prior_billing_snapshot_id"] = int(sys.argv[10])
v["overlay_sha256"] = sys.argv[11]
# The pricing runtime floor marker names this commit (written by `begin`).
v["runtime_floor_commit"] = sys.argv[12]
json.dump(v, open(out, "w"), sort_keys=True)
PY
fi
# The validated verdict of THIS release + window: evidence (d) judges
# post-HUP rejections against its admitted set.
cp "$WORK/dryload.json" "$WORK/admitted-prehup.json"
SSH "rm -rf '$REMOTE_SCRATCH'" >/dev/null 2>&1 || true
REMOTE_SCRATCH=""

# Reviewed-commit byte proof: a sha256 manifest of every release file, built
# from `git show <commit>:<path>` (never the staged copy), shipped + sha-checked
# beside the verifier; the under-lock gate checks every staged byte against it.
python3 - "$REPO_ROOT" "$COMMIT" "$REL" "$WORK/release-bytes.sha256" <<'PY' || fatal "cannot build the reviewed-commit byte manifest"
import hashlib, os, subprocess, sys
repo, commit, rel, out = sys.argv[1:]
lines = []
for name in sorted(os.listdir(rel)):
    base = "phase3-binary/catalog/autotune" if name in ("release.json", "trusted-keys.json", "tier2-catalog.json") else "phase3-binary/dist/static"
    raw = subprocess.run(["git", "-C", repo, "show", "%s:%s/%s" % (commit, base, name)], capture_output=True, check=True).stdout
    sha = hashlib.sha256(raw).hexdigest()
    if hashlib.sha256(open(os.path.join(rel, name), "rb").read()).hexdigest() != sha:
        raise SystemExit("assembled %s differs from %s" % (name, commit))
    lines.append("%s %s\n" % (sha, name))
open(out, "w").write("".join(lines))
PY

IFS= read -r -d '' AA_GATE_SNIPPET <<'GATE' || true
# Content lane: every staged byte must be the reviewed commit's (manifest built
# from git show <commit>:<path>, shipped beside the verifier).
python3 -I -c 'import hashlib, os, sys
d, m = sys.argv[1], sys.argv[2]
want = {l.split()[1]: l.split()[0] for l in open(m) if l.strip()}
got = {n: hashlib.sha256(open(os.path.join(d, n), "rb").read()).hexdigest() for n in os.listdir(d)}
sys.exit(0 if want and got == want else 1)' "$incoming_path" "$(dirname "$verifier")/../release-bytes.sha256" \
  || abort_pre_mutation "staged release bytes differ from the reviewed commit; not mutating"
# The SIGHUP must apply exactly the config the lease dry-load decoded and the
# coordinator already applied.
cfg_sha="$(sha256sum /opt/macprovider/coordinator.yaml | cut -d' ' -f1)"
ov_sha=""
if [ -e /etc/macprovider/coordinator.pearl-overlays.yaml ]; then ov_sha="$(sha256sum /etc/macprovider/coordinator.pearl-overlays.yaml | cut -d' ' -f1)"; fi
[ "$cfg_sha" = "@CONFIG_SHA@" ] && [ "$ov_sha" = "@OVERLAY_SHA@" ] \
  || abort_pre_mutation "coordinator config changed since the lease dry-load; not mutating"
python3 -c 'import json, sys; r = json.load(open(sys.argv[1])); sys.exit(0 if r.get("config_sha256") == sys.argv[2] and (r.get("overlay_sha256") or "") == sys.argv[3] else 1)' \
  /run/macprovider/coordinator-applied-config.json "$cfg_sha" "$ov_sha" \
  || abort_pre_mutation "the coordinator's applied config differs from the on-disk config; not mutating"
@PRICING_GATE@# Re-run content-gate against the then-current live release with the reviewed
# commit's ledger, exclusions and Tier-2 content index shipped beside the
# verifier; the index is digest-pinned to the one the preflight gate used.
t2_index="$(dirname "$verifier")/../tier2-content-index.json"
[ "$(sha256sum "$t2_index" | cut -d' ' -f1)" = "@T2_INDEX_SHA@" ] \
  || abort_pre_mutation "the Tier-2 content index beside the verifier is not the preflight one; not mutating"
# The Tier-2 trust root is the reviewed commit's coordinator.yaml the preflight
# verified with, digest-pinned (a shipped verifier bundle has no repository
# coordinator.yaml beside it; the default path would not exist). The verifier
# requires an absolute normalized path to it.
t2_root="$(cd "$(dirname "$verifier")/.." && pwd -P)/tier2-trust-root.yaml"
[ "$(sha256sum "$t2_root" | cut -d' ' -f1)" = "@T2_ROOT_SHA@" ] \
  || abort_pre_mutation "the Tier-2 trust root beside the verifier is not the preflight one; not mutating"
gate_out="$(python3 -I "$verifier" content-gate --release "$incoming_path" --live "$root/current" --ledger "$(dirname "$verifier")/../phase3-binary/catalog/autotune/release-ledger.json" --tier2-content-index "$t2_index" --tier2-coordinator-config "$t2_root"@PRICING_GATE_ARGS@)" \
  || abort_pre_mutation "content-gate under lock refused: $gate_out"
printf "%s" "$gate_out" | python3 -c "import json,sys; v=json.load(sys.stdin); sys.exit(0 if v.get(\"ok\") is True and v.get(\"lane\") == \"catalog-content\" else 1)" \
  || abort_pre_mutation "content-gate under lock is not lane catalog-content: $gate_out"
GATE
AA_GATE_SNIPPET="${AA_GATE_SNIPPET%$'\n'}"
AA_GATE_SNIPPET="${AA_GATE_SNIPPET//@CONFIG_SHA@/$CONFIG_DISK_SHA}"
AA_GATE_SNIPPET="${AA_GATE_SNIPPET//@OVERLAY_SHA@/$OVERLAY_DISK_SHA}"
AA_GATE_SNIPPET="${AA_GATE_SNIPPET//@T2_INDEX_SHA@/$(sha256_file "$WORK/gate/tier2-content-index.json")}"
AA_GATE_SNIPPET="${AA_GATE_SNIPPET//@T2_ROOT_SHA@/$(sha256_file "$WORK/gate/tier2-trust-root.yaml")}"
# #1693: pricing inputs beside the verifier are the preflight's bytes; the
# splice is re-run under the lock from the live yaml and must reproduce the
# acknowledged candidate; the under-lock gate binds the effective diff.
IFS= read -r -d '' PRICING_GATE <<'GATE' || true
pricing_dir="$(dirname "$verifier")/../pricing"
for spec in "block.yaml=@BLOCK_SHA@" "ack.json=@ACK_SHA@" "pricing-diff.json=@DIFF_SHA@" "verdict.json=@VERDICT_SHA@"; do
  [ "$(sha256sum "$pricing_dir/${spec%%=*}" | cut -d' ' -f1)" = "${spec#*=}" ] \
    || abort_pre_mutation "pricing input ${spec%%=*} beside the verifier is not the preflight's; not mutating"
done
# The coverage dry-load runs as macprovider, which cannot traverse the 0700
# root helper dir (and must not be let in). The candidate lives in its own
# fresh root:macprovider 0750 dir (mkdir fails closed on a squatted name) as a
# 0640 file, as readable as the live yaml it replaces; its digest is pinned and
# the service user's read access is proven before anything is mutated.
helper_dir="$(cd "$(dirname "$verifier")/.." && pwd -P)"
pricing_stage="/tmp/macprovider-pricing-candidate.${helper_dir##*/macprovider-autotune-lock.}"
case "${pricing_stage#/tmp/macprovider-pricing-candidate.}" in ""|*[!A-Za-z0-9]*) abort_pre_mutation "cannot derive the pricing candidate dir; not mutating" ;; esac
mkdir -m 0750 "$pricing_stage" || abort_pre_mutation "cannot create a fresh pricing candidate dir $pricing_stage; not mutating"
chown root:macprovider "$pricing_stage"
chmod 0750 "$pricing_stage"
pricing_candidate="$pricing_stage/candidate-coordinator.yaml"
python3 -I "$verifier" splice-coordinator-rate-card --live-config /opt/macprovider/coordinator.yaml --block "$pricing_dir/block.yaml" \
  --output "$pricing_candidate" >/dev/null || abort_pre_mutation "the rate_card splice refused the live coordinator.yaml under lock; not mutating"
chown root:macprovider "$pricing_candidate"; chmod 0640 "$pricing_candidate"
[ "$(sha256sum "$pricing_candidate" | cut -d' ' -f1)" = "@CAND_SHA@" ] \
  || abort_pre_mutation "the candidate spliced under lock differs from the acknowledged one; not mutating"
systemd-run --quiet --wait --pipe --collect -p RuntimeMaxSec=60 -p User=macprovider -p Group=macprovider \
  /bin/sh -c 'test -r "$1"' candidate-read-check "$pricing_candidate" </dev/null \
  || abort_pre_mutation "the coordinator service user cannot read the pricing candidate $pricing_candidate; not mutating"
GATE
if [ "$PRICING" = 1 ]; then
  PRICING_GATE="${PRICING_GATE%$'\n'}"
  PRICING_GATE="${PRICING_GATE//@BLOCK_SHA@/$COMMIT_BLOCK_SHA}"
  PRICING_GATE="${PRICING_GATE//@ACK_SHA@/$ACK_MOVES_SHA}"
  PRICING_GATE="${PRICING_GATE//@DIFF_SHA@/$PRICING_DIFF_SHA}"
  PRICING_GATE="${PRICING_GATE//@VERDICT_SHA@/$(sha256_file "$PRICING_DIR/verdict.json")}"
  PRICING_GATE="${PRICING_GATE//@CAND_SHA@/$CAND_CONFIG_SHA}"
  # Spliced in by prefix/suffix (not ${//}: the block carries backslashes).
  AA_GATE_SNIPPET="${AA_GATE_SNIPPET%%@PRICING_GATE@*}$PRICING_GATE${AA_GATE_SNIPPET#*@PRICING_GATE@}"
  AA_GATE_SNIPPET="${AA_GATE_SNIPPET//@PRICING_GATE_ARGS@/ --acknowledged-moves \"\$pricing_dir/ack.json\" --pricing-diff \"\$pricing_dir/pricing-diff.json\" --pricing-diff-sha256 $PRICING_DIFF_SHA}"
  # shellcheck disable=SC2034 # read by scripts/lib/autotune-activate.sh
  AA_PRICING_TXN=1
else
  AA_GATE_SNIPPET="${AA_GATE_SNIPPET%%@PRICING_GATE@*}${AA_GATE_SNIPPET#*@PRICING_GATE@}"
  AA_GATE_SNIPPET="${AA_GATE_SNIPPET//@PRICING_GATE_ARGS@/}"
fi
AA_COVERAGE_POLICY=refuse
AA_COVERAGE_OVERRIDE=0
[ -z "$CATALOG_WINDOW_OVERRIDE_REASON" ] || AA_COVERAGE_OVERRIDE=1
AA_LOCK_MODE=lease
AA_ROLLBACK_POST_HOOK=ccr_after_rollback

aa_install_helpers
log "installing the commit's release ledger, serving exclusions, Tier-2 content index, Tier-2 trust root and byte manifest beside the verifier"
for _gate_file in phase3-binary/catalog/autotune/release-ledger.json phase3-binary/catalog/autotune/not-buyer-serving.json release-bytes.sha256 tier2-content-index.json tier2-trust-root.yaml; do
  case "$_gate_file" in release-bytes.sha256) _gate_src="$WORK/release-bytes.sha256" ;; *) _gate_src="$WORK/gate/${_gate_file##*/}" ;; esac
  SSH "mkdir -p -m 0700 '$LOCK_HELPER_DIR/phase3-binary/catalog/autotune' && cat >'$LOCK_HELPER_DIR/$_gate_file'" <"$_gate_src" ||
    fatal "cannot install $_gate_file on $PEARL_SSH"
  [ "$(SSH "sha256sum '$LOCK_HELPER_DIR/$_gate_file'" | cut -d' ' -f1)" = "$(sha256_file "$_gate_src")" ] ||
    fatal "$_gate_file on $PEARL_SSH does not match the commit"
done
if [ "$PRICING" = 1 ]; then
  log "installing the commit's rate_card block, acknowledgements, the effective diff and the journal verdict beside the verifier"
  for _pricing_file in block.yaml ack.json pricing-diff.json verdict.json; do
    SSH "mkdir -p -m 0700 '$LOCK_HELPER_DIR/pricing' && cat >'$LOCK_HELPER_DIR/pricing/$_pricing_file'" <"$PRICING_DIR/$_pricing_file" ||
      fatal "cannot install pricing/$_pricing_file on $PEARL_SSH"
    [ "$(SSH "sha256sum '$LOCK_HELPER_DIR/pricing/$_pricing_file'" | cut -d' ' -f1)" = "$(sha256_file "$PRICING_DIR/$_pricing_file")" ] ||
      fatal "pricing/$_pricing_file on $PEARL_SSH does not match"
  done
fi
aa_upload_release "$REL"

fetch_poolz "$WORK/poolz-before.json" || fatal "coordinator /poolz unreachable before activation"
unavailable_counts "$WORK/poolz-before.json" >"$WORK/unavailable-before.json"
if [ "$AA_COVERAGE_OVERRIDE" = 1 ]; then
  log "window coverage override: $CATALOG_WINDOW_OVERRIDE_REASON"
  # Same durable audit trail as deploy-pearl-vps.sh's regression/window
  # overrides: one JSON line appended to Pearl's
  # /var/lib/macprovider/catalog-window-overrides.jsonl via the shared
  # scripts/lib/catalog-window-override.sh primitive. It describes the
  # coverage computed UNDER the lease, and the publish refuses (pre-mutation)
  # if its own under-lock coverage differs (AA_COVERAGE_EXPECT).
  _override_out="$(python3 - "$CATALOG_WINDOW_OVERRIDE_REASON" "$WORK/coverage.json" "$RELEASE_DIRNAME" "$CURRENT_TARGET" "$LIVE_ID" "$COMMIT" <<'PY'
import base64, hashlib, json, sys
reason, coverage_path, incoming, live_target, live_id, commit = sys.argv[1:]
with open(coverage_path) as f:
    coverage = json.load(f)
uncovered = coverage["uncovered"]
record = {
    "kind": "content_lane_window_coverage",
    "reason": reason,
    "uncovered": uncovered,
    "incoming": "releases/" + incoming,
    "live": {"target": live_target, "release_id": live_id},
    "commit": commit,
}
canonical = json.dumps(sorted(uncovered, key=lambda x: json.dumps(x, sort_keys=True)), sort_keys=True)
print(hashlib.sha256(canonical.encode()).hexdigest())
print(base64.b64encode(json.dumps(record, sort_keys=True).encode("ascii")).decode("ascii"))
PY
)" || fatal "could not build the window coverage override record"
  AA_COVERAGE_EXPECT="$(printf '%s\n' "$_override_out" | sed -n 1p)"
  CONTENT_OVERRIDE_RECORD_B64="$(printf '%s\n' "$_override_out" | sed -n 2p)"
  aa_lease_sh "$(cwo_override_remote_command "$CONTENT_OVERRIDE_RECORD_B64" "catalog-content window coverage override for $RELEASE_DIRNAME" macprovider-catalog-content)" ||
    fatal "could not append the window coverage override record"
  log "AUDIT TRAIL: override appended to /var/lib/macprovider/catalog-window-overrides.jsonl"
fi
T_HUP="$(remote_now)"
case "$T_HUP" in ""|*[!0-9]*) fatal "cannot read Pearl time" ;; esac
T_RB="$T_HUP"
log "activating releases/$RELEASE_DIRNAME ($REL_ID) over $CURRENT_TARGET"
# Before the publish is sent: an interrupt from here on reads the actual Pearl
# state through the lease (ccr_cleanup) instead of assuming nothing changed.
CCR_ACTIVATED=maybe
aa_publish
CCR_ACTIVATED=1
# The rollback's own HUP is judged from the moment rollback begins.
ccr_evidence_hook() {
  if ccr_evidence; then return 0; fi
  T_RB="$(remote_now)"
  return 1
}
aa_post_activation_evidence ccr_evidence_hook
if [ "$PRICING" = 1 ] && ! pricing_finalize; then
  CCR_PRICING_KEEP=1
  CCR_FATAL_RC=5
  fatal "pricing journal not marked verified; journal kept in phase verifying"
fi
CCR_DONE=1
log "DONE: $REL_ID live via the catalog-content lane; evidence (a)-(d) passed; (e) not required (buyer-serving set adds or re-hashes nothing)"
if [ "$PRICING" = 1 ]; then
  log "pricing: rate table $EXPECTED_RATE_SHA and signed card $EXPECTED_SIGNED_SHA live (diff $PRICING_DIFF_SHA)"
  aa_lease_release
  gateway_convergence
fi
exit 0
