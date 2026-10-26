#!/usr/bin/env bash
# Catalog / continuous-batching / native-MTP activation entry point.
#
# Usage:
#   scripts/ops/catalog-activate.sh status          read-only; one JSON object on stdout,
#                                                   human summary on stderr
#   scripts/ops/catalog-activate.sh next            print the next documented step
#   scripts/ops/catalog-activate.sh next --run      run exactly that one step
#   scripts/ops/catalog-activate.sh next --done STEP --evidence TEXT
#                                                   record an operator-owned step as done
#
# Order (docs/runbooks/native-mtp-enablement.md steps 5, 8, 9;
# docs/runbooks/pearl-coordinator-rollout.md "Catalog activation";
# docs/runbooks/catalog-release-decision-tree.md "Content lane"):
#   1 catalog_verify          committed release passes catalog-release.py verify;
#                             a native-bound release's self-test bank names its release_id
#   2 revocation_slots        native-bound: publish revocations when no signed slot
#                             is served (publish-native-mtp-revocations.sh --deploy)
#   3 nginx_routes            every feed the release binds is routed to the coordinator
#   4 coordinator_native_keys coordinator.yaml autotune native_mtp_* keys + pool canary
#  4a buyer_ux_conformance    origin/main's buyer-UX conformance records (SPEC-023
#                             §16.11) are in force on Pearl: /healthz
#                             buyer_ux_conformance_sha256 equals the committed file's
#                             SHA-256 (a runtime that predates the SIGHUP reload is read
#                             over PEARL_SSH instead). Otherwise lib/pearl-cli-config.py
#                             installs the file at PEARL_BUYER_UX_CONFORMANCE_PATH, adds
#                             routing.buyer_ux_conformance_path to coordinator.yaml in
#                             place under both Pearl locks, and applies it with one
#                             SIGHUP (one restart on a runtime that reads it only at start).
#                             Independent of the catalog release: a records-only change
#                             needs no re-signed release. A file with owed entries
#                             (SPEC-023 §16.11 rule 4) is done only when /healthz
#                             buyer_ux_conformance_records counts its owed masks too; a
#                             runtime that ignores owed entries blocks (release the runtime)
#   5 catalog_preflight       catalog-content-release.sh --preflight (read-only)
#   6 catalog_activation      catalog-content-release.sh --deploy (content lane; a pricing
#                             release runs with CATALOG_PRICING_ACK=<the verdict's
#                             pricing_diff_sha256>), or the full deploy-pearl-vps.sh activation
#                             when the gate names another lane. Refused while the canary is
#                             operator-paused: its custody proof and evidence (c) need it
#                             buyer_serving
#   7 canary_bank             native-bound: the coordinator canary holds the release's
#                             self-test bank. A coordinator that reports
#                             native_mtp_canary_bank_reloads on /healthz reloads the bank
#                             with the release (SPEC-031-R033 v0.3.9), so this step only
#                             checks native_mtp_canary_bank_release_id == the release and
#                             native_mtp_canary_bank_sha256 == the SHA-256 of the served
#                             /v1/native-mtp-selftest-bank bytes; one that predates it
#                             read the bank at boot, and the step restarts it before the
#                             activation can be done
#   8 provider_restart        canary/Studio provider reports the new catalog release
#   9 live_probe              provider /v1/status: continuous_batching active;
#                             native_mtp enabled+eligible|active unless explicitly
#                             selecting a CB-only proof below
#  10 gateway_proof           one real buyer request through the gateway that moves the
#                             target provider's active serving-path counter
#                             (CB shared_forward_calls when CB is active);
#                             expires after 24 h
#  11 buyer_serving_e2e       evidence (e) an activation recorded as owed (SPEC-023-R017
#                             5(e)): no connected provider served the newly buyer-serving
#                             model, so the provider release that first serves it owes a
#                             canary restart onto the live release, one buyer request through
#                             the gateway attributed to that canary, and its settlement row.
#                             One ledger entry per model and hash (ops-state
#                             catalog-owed-e2e/), written before the deploy and again from its
#                             output, open until a buyer_serving_e2e record carries the exact
#                             token model=<model_id>@<sha256>; it outlives later releases, and
#                             a malformed entry blocks. Unreadable canary status blocks the
#                             preflight and the activation like an operator pause
#  12 buyer_ux_conformance_owed a key promoted with its buyer-UX conformance record owed
#                             (SPEC-023 §16.11 rule 4): after its release is live, the record
#                             is run through the gateway and committed; the step stays open
#                             until origin/main's buyer-ux-conformance.json holds a passing
#                             record for every owed key and step 4a has installed that file
#
# Env (or ~/.config/macprovider/ops.env): COORDINATOR_URL, GATEWAY_URL,
# PEARL_SSH (+ PEARL_SSH_IDENTITY/PEARL_SSH_KNOWN_HOSTS for the repo scripts),
# REMOTE_REVOCATION_DIR, STUDIO_SSH, STUDIO_SSH_KEY, STUDIO_STATUS_PORT,
# BUYER_TOKEN_FILE, PROBE_MODEL, CATALOG_REQUIRE_NATIVE_MTP_FORWARD=true (native
# MTP proof) or explicitly false (CB-only live probe), CATALOG_CANARY_* (as
# catalog-content-release.sh),
# CATALOG_PRICING_ACK (the reviewed price table's digest), MACPROVIDER_OPS_OWNER (for --run),
# PEARL_BUYER_UX_CONFORMANCE_PATH and the Pearl layout of cli-release.sh
# (PEARL_COORDINATOR_CONFIG/OVERLAY/UNIT, PEARL_INSTALL_ROOT, PEARL_CONFIG_GUARD,
# PEARL_UPDATER_LOCK, PEARL_BACKUP_ROOT, PEARL_COORDINATOR_HEALTHZ_URL, PEARL_PROC_ROOT).
set -euo pipefail
# shellcheck source-path=SCRIPTDIR disable=SC2034  # OPS_NAME/NEXT_* are read by lib/common.sh

OPS_NAME=catalog-activate
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() { sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }

AUTOTUNE="phase3-binary/catalog/autotune"
MTP_DOC="docs/runbooks/native-mtp-enablement.md"
ROLLOUT_DOC="docs/runbooks/pearl-coordinator-rollout.md"
TREE_DOC="docs/runbooks/catalog-release-decision-tree.md"
REVOCATION_BATCH_DAYS="${NATIVE_MTP_REVOCATION_DAYS:-14}"
QWEN_NATIVE_MODEL=qwen/qwen3.6-35b-a3b
BUC_FILE="$AUTOTUNE/buyer-ux-conformance.json"
BUC_DOC="docs/runbooks/catalog-monthly-intake-release.md"
# Pearl layout for lib/pearl-cli-config.py (defaults: production; the same as
# cli-release.sh _pearl-config).
PEARL_COORDINATOR_CONFIG="${PEARL_COORDINATOR_CONFIG:-/opt/macprovider/coordinator.yaml}"
PEARL_COORDINATOR_OVERLAY="${PEARL_COORDINATOR_OVERLAY:-/etc/macprovider/coordinator.pearl-overlays.yaml}"
PEARL_COORDINATOR_UNIT="${PEARL_COORDINATOR_UNIT:-macprovider-coordinator}"
PEARL_INSTALL_ROOT="${PEARL_INSTALL_ROOT:-/opt/macprovider}"
PEARL_CONFIG_GUARD="${PEARL_CONFIG_GUARD:-/usr/local/share/macprovider/scripts/coordinator_config_guard.py}"
PEARL_UPDATER_LOCK="${PEARL_UPDATER_LOCK:-/run/lock/macprovider-pearl-updater.lock}"
PEARL_BACKUP_ROOT="${PEARL_BACKUP_ROOT:-/root/macprovider-backups}"
PEARL_COORDINATOR_HEALTHZ_URL="${PEARL_COORDINATOR_HEALTHZ_URL:-http://127.0.0.1:8444/healthz}"
PEARL_PROC_ROOT="${PEARL_PROC_ROOT:-/proc}"
# The coordinator's routing.buyer_ux_conformance_path (phase4-coordinator/dist/coordinator.yaml).
PEARL_BUYER_UX_CONFORMANCE_PATH="${PEARL_BUYER_UX_CONFORMANCE_PATH:-/opt/macprovider/buyer-ux-conformance.json}"
BUC_DOWNTIME_SIGHUP="none: no coordinator restart; one SIGHUP applies the record file (and any other change already on disk in coordinator.yaml or the overlay). If the coordinator does not report the file within 60 s, coordinator.yaml and the record file are restored and SIGHUPed again; if that does not bring back the previous records (the restored file does not load), one recovery restart follows, about 5-40 seconds"
BUC_DOWNTIME_RESTART="one coordinator restart, about 5-40 seconds (in-flight requests drain, then the coordinator starts): the running runtime reads the record file only at start, so buyer and provider traffic through the coordinator is interrupted for that time. If the restarted coordinator cannot load the file, coordinator.yaml and the record file are restored and the coordinator restarts once more"
QWEN_NATIVE_PROFILE=qwen36-native-mtp
DSV4_WINDOW_PROFILE=dsv4-flash-window
DSV4_WINDOW_DOWNTIME="Studio provider: GLM-5.3-Flash buyer traffic is unavailable from the GLM->DeepSeek restart through the DeepSeek-V4-Flash load (~167 GB), the conformance run (about 10-30 minutes at one serial slot), an optional operator hold while DSV4_WINDOW_HOLD_FILE exists (at most DSV4_WINDOW_HOLD_MAX_MINUTES, default 30, cap 60), and the restart and model load back to GLM; DeepSeek buyers are served during the window. Pearl is not restarted"

# This optional intent selects a single matched signed binary/policy step.
# It contains identities and private paths, never private key bytes.
# Dynamic native bindings are accepted only after deterministic verification of
# the one committed campaign recipe, never from arbitrary local catalog files.
NATIVE_BINDING_RECIPE=ops/recipes/native-mtp-glm53-binding.v1.json
CATALOG_TARGET_DIR="$REPO_ROOT/$AUTOTUNE"
CATALOG_TARGET_INPUT="$REPO_ROOT/$AUTOTUNE/native-mtp-admission-release.json"

native_binding_context() {
  local commit="$1" receipt="$OPS_TMP_DIR/native-binding-proof.json"
  CATALOG_TARGET_DIR="$REPO_ROOT/$AUTOTUNE"
  CATALOG_TARGET_INPUT="$REPO_ROOT/$AUTOTUNE/native-mtp-admission-release.json"
  [ -n "${CATALOG_NATIVE_BINDING_BUNDLE:-}" ] || return 0
  [ "${CATALOG_NATIVE_BINDING_RECIPE:-$NATIVE_BINDING_RECIPE}" = "$NATIVE_BINDING_RECIPE" ] || return 1
  MACPROVIDER_OPS_ENTRYPOINT=1 python3 -I "$REPO_ROOT/scripts/native_mtp_binding_bundle.py" verify \
    --bundle "$CATALOG_NATIVE_BINDING_BUNDLE" --repo "$REPO_ROOT" --commit "$commit" \
    --recipe "$NATIVE_BINDING_RECIPE" > "$receipt" 2> "$OPS_TMP_DIR/native-binding-proof.err" || return 1
  CATALOG_TARGET_DIR="$(json_field "$receipt" 'd["release_dir"]')"
  CATALOG_TARGET_INPUT="$(json_field "$receipt" 'd["release_input_path"]')"
  fact native_binding_phase "$(json_field "$receipt" 'd["phase"]')"
  fact native_binding_receipt_sha256 "$(json_field "$receipt" 'd["receipt_sha256"]')"
  [ -d "$CATALOG_TARGET_DIR" ] && [ -f "$CATALOG_TARGET_INPUT" ]
}

signed_pair_state_dir() { printf '%s/%s/signed-native-pair' "$OPS_STATE_DIR" "$OPS_SCOPE"; }

signed_pair_plan_sha() {
  python3 - "${CATALOG_SIGNED_PAIR_PLAN:-}" "$R" <<'PAIR_PLAN'
import hashlib,json,os,re,stat,sys
p,rid=sys.argv[1:]
f=os.open(p,os.O_RDONLY|os.O_NOFOLLOW)
with os.fdopen(f,'rb') as stream:
 st=os.fstat(stream.fileno())
 if not stat.S_ISREG(st.st_mode) or st.st_uid!=os.getuid() or st.st_mode & 0o077: raise SystemExit(1)
 raw=stream.read(1048577)
if len(raw)>1048576:raise SystemExit(1)
def unique(pairs):
 d={}
 for k,v in pairs:
  if k in d:raise ValueError('duplicate intent field')
  d[k]=v
 return d
d=json.loads(raw,object_pairs_hook=unique)
if d.get('schema_version')!='macprovider.signed_native_pair.v1' or not re.fullmatch(r'[A-Za-z0-9_-]{1,80}',d.get('transaction_id','')):raise SystemExit(1)
if d.get('target',{}).get('catalog_release_id')!=rid:raise SystemExit(1)
print(hashlib.sha256(raw).hexdigest())
PAIR_PLAN
}

# Read-only candidate-order proof. Call again under transaction custody before
# publication with the freshly verified prior sidecar, never a cached verdict.
signed_pair_decode_path_gate() {
  local plan="$1" prior="$2" recommended="$3" version run_id marker run_json provenance
  [ -n "$plan" ] && [ -f "$plan" ] && [ -f "$prior" ] &&
    [ -n "${MACPROVIDER_OPS_OWNER:-}" ] && [ "$(gh_repo)" = Augustas11/macprovider ] || {
      printf '%s\n' "blocked: signed-pair candidate proof prerequisites missing"; return 0;
    }
  provenance="$(json_field "$plan" 'd["target"]["provenance"]')"
  if [ "$provenance" = reviewed_published_signed_release ]; then
    python3 "$REPO_ROOT/scripts/decode_path_digest.py" --publish-gate \
      "$CATALOG_TARGET_INPUT" "$CATALOG_TARGET_DIR/native-mtp-admission.json" "$recommended" 2>&1 ||
      printf '%s\n' "blocked: decode-path publish gate failed"
    return 0
  fi
  [ "$provenance" = reviewed_signed_acceptance_candidate ] || {
    printf '%s\n' "blocked: signed-pair target provenance unknown"; return 0;
  }
  version="$(json_field "$plan" 'd["target"]["version"]')"
  run_id="$(json_field "$plan" 'str(d["target"]["candidate_run_id"])')"
  is_semver "$version" && [[ "$run_id" =~ ^[1-9][0-9]*$ ]] || {
    printf '%s\n' "blocked: signed-pair candidate identity malformed"; return 0;
  }
  marker="$(marker_path "cli-release-$version" signed_byte_verification)"
  run_json="$OPS_TMP_DIR/signed-pair-candidate-run.json"
  [ -f "$marker" ] && gh api "repos/Augustas11/macprovider/actions/runs/$run_id" > "$run_json" 2>/dev/null || {
    printf '%s\n' "blocked: signed-pair verified candidate run unavailable"; return 0;
  }
  MACPROVIDER_OPS_ENTRYPOINT=1 python3 "$REPO_ROOT/scripts/decode_path_digest.py" --publish-gate \
    "$CATALOG_TARGET_INPUT" "$CATALOG_TARGET_DIR/native-mtp-admission.json" "$recommended" \
    --signed-pair-plan "$plan" --signed-byte-verification "$marker" \
    --signed-pair-run-json "$run_json" --signed-pair-prior-sidecar "$prior" 2>&1 ||
    printf '%s\n' "blocked: signed-pair decode-path publish proof failed"
}

signed_pair_acknowledged() {
  python3 - "$(signed_pair_state_dir)" "$(signed_pair_plan_sha)" <<'PAIR_ACK_CHECK'
import json,os,pathlib,stat,sys
p=pathlib.Path(sys.argv[1]);digest=sys.argv[2]
def load(name):
 f=os.open(p/name,os.O_RDONLY|os.O_NOFOLLOW)
 with os.fdopen(f) as stream:
  st=os.fstat(stream.fileno())
  if not stat.S_ISREG(st.st_mode) or st.st_uid!=os.getuid() or st.st_mode & 0o077:raise SystemExit(1)
  return json.load(stream)
s=load('controller-state.json');a=load('terminal-ack.json')
if set(a)!={'terminal_acknowledged','transaction_id','intent_sha256'} or a['terminal_acknowledged'] is not True or a['transaction_id']!=s['transaction_id'] or a['intent_sha256']!=s['intent_sha256'] or a['intent_sha256']!=digest or s['phase']!='terminal':raise SystemExit(1)
PAIR_ACK_CHECK
}

signed_pair_probe() {
  [ -n "${CATALOG_SIGNED_PAIR_PLAN:-}" ] || return 1
  "$OPS_DIR/canary-swap.sh" signed-pair --plan "$CATALOG_SIGNED_PAIR_PLAN" --action status
}

signed_pair_reconcile() {
  [ "${MACPROVIDER_OPS_ENTRYPOINT:-}" = 1 ] || refuse "signed pair reconciliation requires next --run"
  local state_dir state_record values tx helper guard secret
  state_dir="$(signed_pair_state_dir)"
  state_record="$state_dir/controller-state.json"
  signed_pair_probe > "$OPS_TMP_DIR/pair-terminal.json" || refuse "signed pair terminal status is unreadable"
  [ "$(json_field "$OPS_TMP_DIR/pair-terminal.json" 'd.get("terminal_ready")')" = true ] ||
    refuse "independent signed pair recovery has not proved a live matching terminal pair"
  values="$(python3 - "$state_record" "$(signed_pair_plan_sha)" <<'PAIR_STATE'
import json,os,re,stat,sys
p,digest=sys.argv[1:]
f=os.open(p,os.O_RDONLY|os.O_NOFOLLOW)
with os.fdopen(f) as stream:
 st=os.fstat(stream.fileno())
 if not stat.S_ISREG(st.st_mode) or st.st_uid!=os.getuid() or st.st_mode & 0o077:raise SystemExit(1)
 d=json.load(stream)
if d['intent_sha256']!=digest:raise SystemExit(1)
t=d['transaction_id'];h=d['helper_dir'];g=d['guard_dir'];k=d.get('reader_key_dir','')
if not k:
 intent=os.path.expanduser('~/.config/macprovider/operator-secrets/signed-pair-'+t+'.intent.json')
 if os.path.lexists(intent):
  f=os.open(intent,os.O_RDONLY|os.O_NOFOLLOW)
  with os.fdopen(f) as stream:
   st=os.fstat(stream.fileno())
   if not stat.S_ISREG(st.st_mode) or st.st_uid!=os.getuid() or stat.S_IMODE(st.st_mode)!=0o600:raise SystemExit(1)
   record=json.load(stream)
  if record.get('transaction_id')!=t:raise SystemExit(1)
  k=record['key_dir']
if not re.fullmatch(r'[A-Za-z0-9_-]{1,80}',t) or not re.fullmatch(r'/tmp/macprovider-autotune-lock\.[A-Za-z0-9]+',h) or g!=h+'/signed-pair-'+t:raise SystemExit(1)
if '\n' in k or (k and not k.startswith(os.path.expanduser('~/.config/macprovider/operator-secrets/signed-pair-'+t+'-'))):raise SystemExit(1)
print('\n'.join([t,h,g,k]))
PAIR_STATE
)" || refuse "durable signed pair controller state is invalid"
  tx="$(printf '%s\n' "$values" | sed -n 1p)"
  helper="$(printf '%s\n' "$values" | sed -n 2p)"
  guard="$(printf '%s\n' "$values" | sed -n 3p)"
  secret="$(printf '%s\n' "$values" | sed -n 4p)"
  SSH() { pearl_ssh "$@"; }
  fatal() { refuse "$@"; }
  AA_WORK_DIR="$OPS_TMP_DIR/pair-terminal"
  mkdir -m 0700 "$AA_WORK_DIR"
  . "$REPO_ROOT/scripts/lib/autotune-activate.sh"
  LOCK_HELPER_DIR="$helper"
  LOCK_HELPER="$helper/pearl_autotune_deploy_lock.py"
  AA_SIGNED_PAIR_GUARD_DIR="$guard"
  AA_SIGNED_PAIR_READER_KEY_DIR="$secret"
  aa_signed_pair_runner_retire "$tx" || refuse "runner recovery retirement is pending"
  aa_signed_pair_reader_retire "$tx" || refuse "receipt reader retirement is pending"
  aa_cleanup_remote_helpers
  python3 - "$state_record" "$state_dir/terminal-ack.json" <<'PAIR_ACK'
import json,os,pathlib,sys
r=json.load(open(sys.argv[1]));r['phase']='terminal';p=pathlib.Path(sys.argv[2]);t=p.with_name(p.name+'.next-'+str(os.getpid()))
f=os.open(t,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
with os.fdopen(f,'w') as out:json.dump({'terminal_acknowledged':True,'transaction_id':r['transaction_id'],'intent_sha256':r['intent_sha256']},out);out.flush();os.fsync(out.fileno())
os.replace(t,p)
state=pathlib.Path(sys.argv[1]);temp=state.with_name(state.name+'.next-'+str(os.getpid()));f=os.open(temp,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
with os.fdopen(f,'w') as out:json.dump(r,out,sort_keys=True);out.flush();os.fsync(out.fileno())
os.replace(temp,state);f=os.open(p.parent,os.O_RDONLY);os.fsync(f);os.close(f)
PAIR_ACK
}

signed_pair_internal() {
  [ "${MACPROVIDER_OPS_ENTRYPOINT:-}" = 1 ] || refuse "signed pair transition requires next --run"
  local commit="$1" expected="$2" got
  [ "$commit" = "$(origin_main_sha)" ] && [ "$commit" = "$(git -C "$REPO_ROOT" rev-parse HEAD)" ] || refuse "signed pair source moved"
  native_binding_context "$commit" || refuse "native binding proof changed before publication"
  got="$(signed_pair_plan_sha)" || refuse "signed pair intent is invalid"
  [ "$got" = "$expected" ] || refuse "signed pair intent changed since status"
  # Re-fetch under live-ops custody. The actor later independently proves the
  # same prior signed bytes under the publication lease before pausing.
  local prior="$OPS_TMP_DIR/signed-pair-prior-admission.json" health="$OPS_TMP_DIR/signed-pair-health.json" gate
  [ "$(http_get "${COORDINATOR_URL%/}/v1/native-mtp-admission" "$prior")" = 200 ] &&
    [ "$(http_get "${COORDINATOR_URL%/}/healthz" "$health")" = 200 ] || refuse "signed pair prior policy is unreadable"
  gate="$(signed_pair_decode_path_gate "$CATALOG_SIGNED_PAIR_PLAN" "$prior" \
    "$(json_field "$health" 'd.get("recommended_binary_version") or ""')")"
  [ "$gate" = ok ] || refuse "signed pair decode-path proof changed before publication"
  CATALOG_SIGNED_PAIR_INTENT_SHA256="$expected" CATALOG_SIGNED_PAIR_STATE_DIR="$(signed_pair_state_dir)" \
    "$REPO_ROOT/scripts/catalog-content-release.sh" --deploy --commit "$commit"
}

qwen_journal_probe() {
  "$OPS_DIR/qwen-opencode-e2e.sh" _catalog-qwen36-journal
}

qwen_intent_probe() {
  "$OPS_DIR/qwen-opencode-e2e.sh" _catalog-qwen36-intent
}

qwen_scratch_probe() {
  "$OPS_DIR/qwen-opencode-e2e.sh" _catalog-qwen36-scratch
}

live_lock_purpose() {
  "$OPS_DIR/live-lock.sh" status 2>/dev/null |
    python3 -c 'import json,sys; print((json.load(sys.stdin).get("lock") or {}).get("purpose", ""))'
}

qwen_native_intent_present() {
  [ -n "${OPS_STATE_DIR:-}" ] || return 1
  local path="$OPS_STATE_DIR/qwen-native-mtp-transaction-intent.json"
  [ -e "$path" ] || [ -L "$path" ]
}

qwen_native_journal_recovered() {
  local probe="$1" scratch_probe="$OPS_TMP_DIR/qwen-recovered-scratch.json"
  ! qwen_native_intent_present || return 1
  [ -n "${QWEN_E2E_JOURNAL:-}" ] || return 1
  qwen_journal_probe > "$probe" 2>/dev/null || return 1
  [ "$(json_field "$probe" 'd.get("profile")')" = "$QWEN_NATIVE_PROFILE" ] &&
    [ "$(json_field "$probe" 'd.get("status")')" = restored ] &&
    [ "$(json_field "$probe" 'd.get("restore_required")')" = false ] &&
    qwen_scratch_probe > "$scratch_probe" 2>/dev/null &&
    [ "$(json_field "$scratch_probe" 'd.get("scratch_absent")')" = true ]
}

reconcile_qwen_restore_lock() {
  [ "${MACPROVIDER_OPS_ENTRYPOINT:-}" = 1 ] && [ -n "${MACPROVIDER_OPS_OWNER:-}" ] ||
    refuse "Qwen restoration lock reconciliation is callable only by catalog next --run"
  [ "$(live_lock_purpose 2>/dev/null || true)" = catalog-activate:qwen_restore ] ||
    refuse "Qwen restoration lock is no longer durable"
  qwen_native_journal_recovered "$OPS_TMP_DIR/qwen-lock-reconcile.json" ||
    refuse "exact native Qwen restoration is not proven complete"
}

# Once the fixed Qwen transaction has armed its remote journal, keep the global
# lock durable until the exact incumbent has restarted and the journal reaches
# restored. An unreadable journal under the restoration purpose fails closed.
release_live_lock() {
  [ -n "$OPS_LOCK_OWNER" ] || return 0
  local owner="$OPS_LOCK_OWNER" probe="$OPS_TMP_DIR/qwen-lock-journal.json" purpose=""
  purpose="$(live_lock_purpose 2>/dev/null || true)"
  if [ "$purpose" = catalog-activate:signed_native_pair ]; then
    if [ ! -e "$(signed_pair_state_dir)/controller-state.json" ]; then
      OPS_LOCK_OWNER=""
      "$OPS_DIR/live-lock.sh" release "$owner" >&2 || true
      return 0
    fi
    if ! signed_pair_acknowledged ||
       ! signed_pair_probe > "$OPS_TMP_DIR/pair-lock-terminal.json" 2>/dev/null ||
       [ "$(json_field "$OPS_TMP_DIR/pair-lock-terminal.json" 'd.get("terminal_ready")')" != true ]; then
      log "retaining the durable live-ops lock until signed pair recovery proves a live terminal pair"
      OPS_LOCK_OWNER=""
      return 0
    fi
    OPS_LOCK_OWNER=""
    "$OPS_DIR/live-lock.sh" release "$owner" >&2 || true
    return 0
  fi
  if qwen_native_intent_present; then
    if [ "$purpose" != catalog-activate:qwen_restore ]; then
      "$OPS_DIR/live-lock.sh" acquire "$owner" \
        --purpose catalog-activate:qwen_restore >&2 ||
        log "Qwen transaction intent survives; live-ops lock could not be refreshed but will not be released"
    fi
    log "retaining the durable live-ops lock until the Qwen transaction intent is cleared"
    OPS_LOCK_OWNER=""
    return 0
  fi
  if [ "$purpose" = catalog-activate:qwen_restore ]; then
    if ! qwen_native_journal_recovered "$probe"; then
      log "retaining the durable live-ops lock because native Qwen restoration is not proven complete"
      OPS_LOCK_OWNER=""
      return 0
    fi
    OPS_LOCK_OWNER=""
    "$OPS_DIR/live-lock.sh" release "$owner" >&2 || true
    return 0
  fi
  if [ -n "${QWEN_E2E_JOURNAL:-}" ]; then
    if qwen_journal_probe > "$probe" 2>/dev/null; then
      if [ "$(json_field "$probe" 'd.get("profile")')" = "$QWEN_NATIVE_PROFILE" ] &&
         [ "$(json_field "$probe" 'd.get("restore_required")')" = true ]; then
        if [ "$purpose" != catalog-activate:qwen_restore ]; then
          "$OPS_DIR/live-lock.sh" acquire "$owner" \
            --purpose catalog-activate:qwen_restore >&2 ||
            log "Qwen journal is armed; live-ops lock could not be refreshed but will not be released"
        fi
        log "retaining the durable live-ops lock until the Qwen transaction restores GLM"
        OPS_LOCK_OWNER=""
        return 0
      fi
    fi
  fi
  OPS_LOCK_OWNER=""
  "$OPS_DIR/live-lock.sh" release "$owner" >&2 || true
}

acquire_live_lock_for_step() {
  if [ "$NEXT_ID" = signed_native_pair ] || [ "$NEXT_ID" = signed_native_pair_reconcile ]; then
    "$OPS_DIR/live-lock.sh" acquire "$MACPROVIDER_OPS_OWNER" --purpose catalog-activate:signed_native_pair >&2
  elif [ "$NEXT_ID" = qwen_restore ] || [ "$NEXT_ID" = qwen_prejournal_reconcile ]; then
    "$OPS_DIR/live-lock.sh" acquire "$MACPROVIDER_OPS_OWNER" \
      --purpose catalog-activate:qwen_restore >&2
  elif [ "$(live_lock_purpose 2>/dev/null || true)" = catalog-activate:qwen_restore ]; then
    qwen_native_journal_recovered "$OPS_TMP_DIR/qwen-lock-recovered.json" ||
      refuse "durable Qwen restoration lock requires a valid restored native journal"
    "$OPS_DIR/live-lock.sh" acquire "$MACPROVIDER_OPS_OWNER" \
      --purpose catalog-activate:qwen_restore >&2
  else
    "$OPS_DIR/live-lock.sh" acquire "$MACPROVIDER_OPS_OWNER" \
      --purpose "$OPS_NAME:$NEXT_ID" --bind-pid >&2
  fi
}

# Feeds the release binds -> public route. Revocations are keyed by signer.
feed_route() {
  case "$1" in
    autotune-artifacts.json) echo /v1/catalog-artifacts ;;
    autotune-candidates.json) echo /v1/autotune-candidates ;;
    continuous-batching-policy.json) echo /v1/continuous-batching-policy ;;
    demand-rank.json) echo /v1/demand-rank ;;
    rate-card.json) echo /v1/rate-card ;;
    native-mtp-admission.json) echo /v1/native-mtp-admission ;;
    *) echo "" ;;
  esac
}

gather() {
  local main_sha head_sha R native_bound=false bank_rid verify_ok=false qwen_lock_purpose="" qwen_local_intent=false
  main_sha="$(origin_main_sha)"
  head_sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  if [ "$(live_lock_purpose 2>/dev/null || true)" = catalog-activate:signed_native_pair ] &&
     [ -n "${CATALOG_SIGNED_PAIR_PLAN:-}" ]; then
    # Recovery does not depend on still-valid candidate envelopes. The private
    # intent and actor independently prove the already-journaled terminal pair.
    R="$(json_field "$CATALOG_SIGNED_PAIR_PLAN" 'd["target"]["catalog_release_id"]')"
    [[ "$R" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$ ]] || die "invalid recovery release identity"
    OPS_SCOPE="catalog-$R"
    if [ -f "$(signed_pair_state_dir)/controller-state.json" ]; then
      step signed_native_pair_reconcile pending "signed pair journal awaits a live terminal acknowledgement"
      set_next signed_native_pair_reconcile mutate "Reconcile the journaled signed binary/policy pair" \
        "$OPS_DIR/catalog-activate.sh _signed-native-pair-reconcile"
      return
    fi
  fi
  # A remote Qwen profile journal is authoritative. No catalog step, proof, or
  # activation is allowed to run ahead of restoration.
  qwen_lock_purpose="$(live_lock_purpose 2>/dev/null || true)"
  local qwen_intent_path=""
  [ -z "${OPS_STATE_DIR:-}" ] || qwen_intent_path="$OPS_STATE_DIR/qwen-native-mtp-transaction-intent.json"
  if [ -n "$qwen_intent_path" ] && { [ -e "$qwen_intent_path" ] || [ -L "$qwen_intent_path" ]; }; then
    if ! qwen_intent_probe > "$OPS_TMP_DIR/qwen-intent.json" 2>/dev/null; then
      step qwen_prejournal_reconcile blocked "native transaction intent is malformed or its journal is unreadable"
      set_next qwen_prejournal_reconcile blocked "Recover the Qwen3.6 transaction intent" "" \
        "the durable intent must be reviewed before catalog work can continue"
      return
    fi
    qwen_local_intent=true
    local qwen_intent_journal
    qwen_intent_journal="$(json_field "$OPS_TMP_DIR/qwen-intent.json" 'd.get("journal_path")')"
    if [ -n "${QWEN_E2E_JOURNAL:-}" ] && [ "$QWEN_E2E_JOURNAL" != "$qwen_intent_journal" ]; then
      step qwen_prejournal_reconcile blocked "native transaction intent journal path mismatches configuration"
      set_next qwen_prejournal_reconcile blocked "Recover the Qwen3.6 transaction intent" "" \
        "the durable intent and configured journal must be reviewed before catalog work can continue"
      return
    fi
    export QWEN_E2E_JOURNAL="$qwen_intent_journal"
  fi
  if [ -n "${QWEN_E2E_JOURNAL:-}" ] || [ "$qwen_lock_purpose" = catalog-activate:qwen_restore ]; then
    local qwen_probe="$OPS_TMP_DIR/qwen-journal.json" qwen_restore=false qwen_profile="" qwen_status="" qwen_intent=false qwen_scratch_absent=false
    if [ -n "${QWEN_E2E_JOURNAL:-}" ] && qwen_journal_probe > "$qwen_probe" 2>/dev/null; then
      qwen_restore="$(json_field "$qwen_probe" 'd.get("restore_required")')"
      qwen_profile="$(json_field "$qwen_probe" 'd.get("profile")')"
      qwen_status="$(json_field "$qwen_probe" 'd.get("status")')"
      if [ "$qwen_local_intent" != true ] && ! qwen_intent_probe > "$OPS_TMP_DIR/qwen-intent.json" 2>/dev/null; then
        step qwen_prejournal_reconcile blocked "native transaction intent is malformed or mismatches the journal"
        set_next qwen_prejournal_reconcile blocked "Recover the Qwen3.6 transaction intent" "" \
          "the durable intent and remote journal must be reviewed before catalog work can continue"
        return
      fi
      [ "$(json_field "$OPS_TMP_DIR/qwen-intent.json" 'd.get("status")')" = absent ] || qwen_intent=true
      if [ "$qwen_status" = absent ] && [ "$qwen_restore" = false ]; then
        if [ "$qwen_intent" = true ]; then
          step qwen_prejournal_reconcile pending "clear the interrupted pre-journal Qwen transaction intent"
          set_next qwen_prejournal_reconcile mutate "Reconcile the interrupted pre-journal Qwen transaction" \
            "$OPS_DIR/qwen-opencode-e2e.sh _catalog-qwen36-prejournal-reconcile"
          return
        fi
      fi
      if [ "$qwen_restore" = true ] && [ "$qwen_profile" = "$QWEN_NATIVE_PROFILE" ]; then
        fact qwen_transaction_profile "$qwen_profile"
        fact qwen_restore_required true
        step qwen_restore pending "restore exact signed GLM incumbent before catalog work"
        set_next qwen_restore mutate "Restore GLM from the active Qwen3.6 transaction" \
          "$OPS_DIR/qwen-opencode-e2e.sh _catalog-qwen36-restore"
        NEXT_DOWNTIME="Studio provider buyer traffic is unavailable during the bounded GLM restart and model-load window; Pearl is not restarted"
        return
      fi
      if [ "$qwen_restore" = true ] && [ "$qwen_profile" = "$DSV4_WINDOW_PROFILE" ]; then
        fact qwen_transaction_profile "$qwen_profile"
        fact qwen_restore_required true
        step dsv4_restore pending "restore exact signed GLM incumbent from the DeepSeek-V4-Flash window"
        set_next dsv4_restore mutate "Restore GLM from the interrupted DeepSeek-V4-Flash window" \
          "$OPS_DIR/qwen-opencode-e2e.sh _catalog-dsv4-restore"
        NEXT_DOWNTIME="Studio provider buyer traffic is unavailable during the bounded GLM restart and model-load window; Pearl is not restarted"
        return
      fi
      if [ "$qwen_intent" = true ] && [ "$qwen_profile" = "$QWEN_NATIVE_PROFILE" ] &&
         [ "$qwen_status" = restored ] && [ "$qwen_restore" = false ]; then
        step qwen_restore pending "clear the restored Qwen transaction intent before releasing the lock"
        set_next qwen_restore mutate "Finalize the restored Qwen3.6 transaction" \
          "$OPS_DIR/qwen-opencode-e2e.sh _catalog-qwen36-restore"
        return
      fi
      if [ "$qwen_profile" = "$QWEN_NATIVE_PROFILE" ] && [ "$qwen_status" = restored ] &&
         [ "$qwen_restore" = false ]; then
        if qwen_scratch_probe > "$OPS_TMP_DIR/qwen-scratch.json" 2>/dev/null; then
          qwen_scratch_absent="$(json_field "$OPS_TMP_DIR/qwen-scratch.json" 'd.get("scratch_absent")')"
        fi
        if [ "$qwen_scratch_absent" != true ]; then
          step qwen_restore pending "remove the protected Qwen transaction scratch before releasing the lock"
          set_next qwen_restore mutate "Finalize the restored Qwen3.6 transaction" \
            "$OPS_DIR/qwen-opencode-e2e.sh _catalog-qwen36-restore"
          return
        fi
      fi
      if [ "$qwen_lock_purpose" = catalog-activate:qwen_restore ] &&
         { [ "$qwen_profile" != "$QWEN_NATIVE_PROFILE" ] || [ "$qwen_status" != restored ] || [ "$qwen_restore" != false ]; }; then
        fact qwen_restore_required unknown
        step qwen_restore blocked "durable restoration lock lacks a valid recovered native journal"
        set_next qwen_restore blocked "Recover the Qwen3.6 restoration journal" "" \
          "the durable restoration lock prevents all ordinary catalog steps until exact native restoration is proven"
        return
      fi
      if [ "$qwen_lock_purpose" = catalog-activate:qwen_restore ]; then
        fact qwen_restore_required false
        step qwen_lock_reconcile pending "release the recovered durable Qwen restoration lock"
        set_next qwen_lock_reconcile mutate "Reconcile the recovered Qwen restoration lock" \
          "$OPS_DIR/catalog-activate.sh _qwen-lock-reconcile"
        return
      fi
    elif [ "$qwen_lock_purpose" = catalog-activate:qwen_restore ]; then
      fact qwen_restore_required unknown
      step qwen_restore blocked "active Qwen restoration journal is unreadable"
      set_next qwen_restore blocked "Recover the Qwen3.6 restoration journal" "" \
        "the durable restoration lock prevents all ordinary catalog steps until the journal is readable"
      return
    elif [ -n "${QWEN_E2E_JOURNAL:-}" ]; then
      # A configured Studio transaction journal that cannot be read may hold an
      # interrupted window (the DeepSeek-V4-Flash window keeps no durable
      # lock): no catalog step runs until it proves absence or restoration.
      fact qwen_restore_required unknown
      step qwen_restore blocked "the configured Studio transaction journal is unreadable"
      set_next qwen_restore blocked "Read the Studio transaction journal" "scripts/ops/qwen-opencode-e2e.sh status" \
        "QWEN_E2E_JOURNAL is configured but cannot be inspected over STUDIO_SSH; an interrupted window may still need GLM restored"
      return
    fi
  fi
  if [ "$(live_lock_purpose 2>/dev/null || true)" = catalog-activate:signed_native_pair ] &&
     [ -f "$(signed_pair_state_dir)/controller-state.json" ]; then
    step signed_native_pair_reconcile pending "signed pair journal must reach an acknowledged live terminal pair"
    set_next signed_native_pair_reconcile mutate "Reconcile the journaled signed binary/policy pair" \
      "$OPS_DIR/catalog-activate.sh _signed-native-pair-reconcile"
    next_meta signed_native_pair_reconcile "$MTP_DOC" "recovery only: restore the journaled released pair and buyer runner"
    return
  fi
  # Mandatory recovery precedes all fresh catalog/binding reads: a later
  # catalog candidate must not prevent restoration of an interrupted window.
  if ! native_binding_context "$main_sha"; then
    set_next native_binding_bundle blocked "Verify the committed native binding recipe" "" "signed bundle derivation or qualification proof failed"
    return
  fi
  R="$(json_field "$CATALOG_TARGET_DIR/release.json" 'd["release_id"]')"
  [ -n "$R" ] || die "cannot read $AUTOTUNE/release.json"
  OPS_SCOPE="catalog-$R"
  fact origin_main_sha "$main_sha"
  fact checkout_is_origin_main "$([ "$head_sha" = "$main_sha" ] && echo true || echo false)"
  fact committed_release_id "$R"
  if [ -n "$(json_field "$CATALOG_TARGET_DIR/release.json" 'd["feeds"]["native-mtp-admission.json"]["sha256"]')" ]; then
    native_bound=true
  fi
  fact native_bound "$native_bound"
  bank_rid="$(json_field "$CATALOG_TARGET_DIR/native-mtp-selftest-bank.json" 'd["release_id"]')"
  fact committed_bank_release_id "$bank_rid"
  if [ -n "${CATALOG_NATIVE_BINDING_BUNDLE:-}" ]; then
    if python3 "$REPO_ROOT/scripts/catalog-release.py" verify-directory --directory "$CATALOG_TARGET_DIR" \
        --tier2-coordinator-config "$REPO_ROOT/phase4-coordinator/dist/coordinator.yaml" > "$OPS_TMP_DIR/verify.out" 2>&1; then
      verify_ok=true
    fi
  elif MACPROVIDER_REQUIRED_CB_BASELINE=studio-qwen3.6-a3b-v1 python3 "$REPO_ROOT/scripts/catalog-release.py" verify > "$OPS_TMP_DIR/verify.out" 2>&1; then
    verify_ok=true
  fi
  fact catalog_release_verify "$verify_ok"

  # Live coordinator state.
  local base live_rid="" live_status="" uptime="" verified_min=""
  base="$(coordinator_url)"
  if fetch_coordinator_health; then
    uptime="$(json_field "$OPS_TMP_DIR/healthz.json" 'd["uptime_s"]')"
  fi
  fact coordinator_uptime_s "$uptime"
  if [ -n "$base" ] && [ "$(http_get "$base/v1/autotune-release" "$OPS_TMP_DIR/release.json")" = "200" ]; then
    live_rid="$(json_field "$OPS_TMP_DIR/release.json" 'd["release_id"]')"
    live_status="$(json_field "$OPS_TMP_DIR/release.json" 'd["status"]')"
    verified_min="$(json_field "$OPS_TMP_DIR/release.json" 'min(f["verified_at"][:19] + "Z" for f in d["feeds"].values())')"
  fi
  fact live_release_id "$live_rid"
  fact live_release_status "$live_status"
  fact live_feeds_verified_at "$verified_min"

  # Routes: a 200, or a JSON 404 from the coordinator itself, proves nginx
  # forwards the path; an nginx HTML 404 means the location block is missing.
  local missing="" feed route code
  for feed in $(json_field "$CATALOG_TARGET_DIR/release.json" '" ".join(sorted(d["feeds"]))'); do
    route="$(feed_route "$feed")"
    [ -n "$route" ] || continue
    set -- "$route" "$route.sig"
    [ "$feed" != native-mtp-admission.json ] ||
      set -- "$@" /v1/native-mtp-artifact-manifest /v1/native-mtp-selftest-bank /v1/native-mtp-selftest-bank.sig
    for route in "$@"; do
      [ -n "$base" ] || continue
      code="$(http_get "$base$route" "$OPS_TMP_DIR/route.body")"
      if [ "$code" != "200" ] && ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$OPS_TMP_DIR/route.body" 2>/dev/null; then
        missing="$missing $route"
      fi
    done
  done
  fact nginx_missing_routes "${missing# }"

  # Native feeds.
  local adm_code="" live_bank_rid="" live_bank_sha="" slot_exp="" slot_current=false
  if [ "$native_bound" = true ] && [ -n "$base" ]; then
    adm_code="$(http_get "$base/v1/native-mtp-admission" "$OPS_TMP_DIR/adm.json")"
    if [ "$(http_get "$base/v1/native-mtp-selftest-bank" "$OPS_TMP_DIR/bank.json")" = "200" ]; then
      live_bank_rid="$(json_field "$OPS_TMP_DIR/bank.json" 'd["release_id"]')"
      live_bank_sha="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$OPS_TMP_DIR/bank.json")"
    fi
    local key_id
    key_id="$(json_field "$CATALOG_TARGET_DIR/native-mtp-admission.json" 'd["revocation_signer_key_id"]')"
    if [ "$(http_get "$base/v1/native-mtp-revocations.$key_id.json" "$OPS_TMP_DIR/rev.json")" = "200" ]; then
      slot_exp="$(json_field "$OPS_TMP_DIR/rev.json" 'd["expires_at"]')"
      python3 -c 'import datetime,sys; e=datetime.datetime.strptime(sys.argv[1],"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc); sys.exit(0 if e>datetime.datetime.now(datetime.timezone.utc) else 1)' "$slot_exp" 2>/dev/null &&
        slot_current=true
    fi
  fi
  fact live_native_admission_http "$adm_code"
  fact live_selftest_bank_release_id "$live_bank_rid"
  fact live_selftest_bank_sha256 "$live_bank_sha"
  fact live_revocation_slot_expires_at "$slot_exp"
  fact live_revocation_slot_current "$slot_current"

  # Revocation batch coverage, read-only over ssh when configured.
  local coverage_days=""
  if [ "$native_bound" = true ] && [ -n "${PEARL_SSH:-}" ] && [ -n "${REMOTE_REVOCATION_DIR:-}" ]; then
    local batch
    batch="$(pearl_ssh "readlink '$REMOTE_REVOCATION_DIR/current'" 2>/dev/null || true)"
    coverage_days="$(python3 - "$batch" "$REVOCATION_BATCH_DAYS" <<'PY' 2>/dev/null || true
import datetime, re, sys
m = re.search(r"batch-(\d{8}T\d{6}Z)", sys.argv[1])
start = datetime.datetime.strptime(m.group(1), "%Y%m%dT%H%M%SZ").replace(tzinfo=datetime.timezone.utc)
end = start + datetime.timedelta(days=int(sys.argv[2]))
print("%.2f" % ((end - datetime.datetime.now(datetime.timezone.utc)).total_seconds() / 86400))
PY
)"
  fi
  fact revocation_coverage_days "$coverage_days"

  # Provider (canary/Studio) status, read-only over ssh when configured.
  local p_rid="" p_digest="" p_mtp_enabled="" p_mtp_mode="" p_cb_active="" p_connected="" p_lifecycle="" p_paused=false
  if [ -n "${STUDIO_SSH:-}" ] && [ -n "${STUDIO_STATUS_PORT:-}" ]; then
    case "$STUDIO_STATUS_PORT" in *[!0-9]*) die "STUDIO_STATUS_PORT must be numeric" ;; esac
    studio_ssh "curl -s -m 10 http://127.0.0.1:$STUDIO_STATUS_PORT/v1/status" > "$OPS_TMP_DIR/pstatus.json" 2>/dev/null || true
    p_rid="$(json_field "$OPS_TMP_DIR/pstatus.json" 'd["catalog"]["release_id"]')"
    p_digest="$(json_field "$OPS_TMP_DIR/pstatus.json" 'd["catalog"]["digest"]')"
    p_mtp_enabled="$(json_field "$OPS_TMP_DIR/pstatus.json" 'd["native_mtp"]["enabled"]')"
    p_mtp_mode="$(json_field "$OPS_TMP_DIR/pstatus.json" 'd["native_mtp"]["mode"]')"
    p_cb_active="$(json_field "$OPS_TMP_DIR/pstatus.json" 'd["continuous_batching"]["active"]')"
    p_connected="$(json_field "$OPS_TMP_DIR/pstatus.json" 'd["coordinator"]["connected"]')"
    p_lifecycle="$(json_field "$OPS_TMP_DIR/pstatus.json" 'd["lifecycle"]["state"]')"
  fi
  # An operator pause (a Studio bench window) survives restarts and keeps the
  # canary out of buyer_serving: the custody proof (canary_reachable) and
  # activation evidence (c) cannot pass until it is resumed.
  [ "$p_lifecycle" = paused_by_operator ] && p_paused=true
  # Unreadable status is unknown, never "not paused".
  local p_status_ok=false
  [ -n "$(json_field "$OPS_TMP_DIR/pstatus.json" 'd["provider_id"] if isinstance(d.get("provider_id"), str) and d["provider_id"] else None')" ] && p_status_ok=true
  fact provider_catalog_release_id "$p_rid"
  fact provider_native_mtp_enabled "$p_mtp_enabled"
  fact provider_native_mtp_mode "$p_mtp_mode"
  fact provider_continuous_batching_active "$p_cb_active"
  fact provider_coordinator_connected "$p_connected"
  fact provider_lifecycle_state "$p_lifecycle"
  local paused_why="the canary provider status is unreadable (set STUDIO_SSH and STUDIO_STATUS_PORT): whether it is operator-paused is unknown, and its custody proof and the activation's canary restart need it buyer_serving"
  [ "$p_status_ok" = false ] || paused_why="the canary provider is operator-paused (lifecycle paused_by_operator, e.g. a Studio bench window): its custody proof needs it buyer_serving and the activation restarts it onto the release, which a pause outlives; run this after the pause window ends and the provider is resumed"

  # ---- decide, in runbook order ----
  NEXT_RUNBOOK="$MTP_DOC"

  if [ "$verify_ok" = true ] && { [ "$native_bound" = false ] || [ "$bank_rid" = "$R" ]; }; then
    step catalog_verify "done" "catalog-release.py verify ok"
  else
    step catalog_verify blocked "$(tail -n 1 "$OPS_TMP_DIR/verify.out")"
    set_next catalog_verify blocked "Fix the committed catalog release" "MACPROVIDER_REQUIRED_CB_BASELINE=studio-qwen3.6-a3b-v1 python3 scripts/catalog-release.py verify" \
      "verify=$verify_ok; native-bound bank release_id '$bank_rid' must equal '$R'"
  fi
  if [ -z "$base" ]; then
    set_next live_state blocked "Read live coordinator state" "" "COORDINATOR_URL is unset"
  fi

  # #1938 (SPEC-023 v0.22.23): providers keep the newest verified revocation
  # body in force after it ages, and the coordinator keeps serving the newest
  # issued slot, so any served slot is enough. A batch is published only when
  # none is served; batch age is reported, never a reason to republish.
  if [ "$native_bound" != true ]; then
    step revocation_slots "done" "release is not native-bound"
  elif [ -n "$slot_exp" ]; then
    step revocation_slots "done" "a signed slot is served (expires_at $slot_exp; batch coverage ${coverage_days:-unknown} days)"
  else
    step revocation_slots pending "no revocation slot is served"
    set_next revocation_slots mutate "Publish 14 days of native-MTP revocation slots" \
      "scripts/publish-native-mtp-revocations.sh --deploy"
    next_meta revocation_slots "$MTP_DOC" "none expected: atomic batch symlink swap; the coordinator rescans within 10 s"
  fi

  if [ -n "$missing" ]; then
    step nginx_routes pending "missing:$missing"
    set_next nginx_routes manual "Add the missing nginx location blocks on the coordinator host" \
"# Copy ONLY the missing blocks from phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf:
#  $missing
# Diff against the live vhost (Pearl nginx lags the repo), then: nginx -t && systemctl reload nginx
# Never run the gateway deploy-pearl-vps.sh."
    next_meta nginx_routes "$ROLLOUT_DOC#before-running" "none expected: nginx reload"
  else
    step nginx_routes "done" "every bound feed reaches the coordinator"
  fi

  if [ "$native_bound" != true ] || [ "$adm_code" = "200" ]; then
    step coordinator_native_keys "done" "coordinator serves /v1/native-mtp-admission"
  else
    step coordinator_native_keys pending "/v1/native-mtp-admission http=$adm_code"
    set_next coordinator_native_keys manual "Add the native_mtp_* keys and the pool canary to coordinator.yaml" \
"# On Pearl, under BOTH locks, edit coordinator.yaml IN PLACE; add only these keys.
# Under autotune: (after rate_card_sig_path)
$RB_NATIVE_AUTOTUNE_KEYS
# Under pool:
$RB_NATIVE_POOL_CANARY"
    next_meta coordinator_native_keys "$MTP_DOC#order" "none for the edit; the keys load at the activation restart"
  fi

  gather_buyer_ux_conformance

  local verdict="$OPS_STATE_DIR/$OPS_SCOPE/preflight-$main_sha.json" fresh=false go="" pricing="" lane_detail="" failed="" owed_pf=""
  # Owed evidence (e) outlives the release that deferred it: one ledger entry
  # per owed model, open until a buyer_serving_e2e record names that model.
  local owed_dir="$OPS_STATE_DIR/catalog-owed-e2e" deploy_log="$OPS_STATE_DIR/$OPS_SCOPE/deploy-$main_sha.log"
  if [ -f "$verdict" ] && [ -n "$(find "$verdict" -mmin -60 2>/dev/null)" ]; then
    fresh=true
    go="$(json_field "$verdict" 'd["go"]')"
    pricing="$(json_field "$verdict" '(d.get("pricing") or {}).get("pricing_diff_sha256")')"
    lane_detail="$(json_field "$verdict" 'next((c["detail"] for c in d["checks"] if c["name"] == "content_gate" and not c["ok"]), "")')"
    failed="$(json_field "$verdict" '"; ".join("%s: %s" % (c["name"], c["detail"][:200]) for c in d["checks"] if not c["ok"] and not c["detail"].startswith("not run:"))')"
    owed_pf="$(json_field "$verdict" '", ".join(m["model_id"] for m in d.get("buyer_serving_e2e_owed") or [])')"
    # The digest reaches a step command: anything but a sha256 is refused.
    if [ -n "$pricing" ] && ! [[ "$pricing" =~ ^[0-9a-f]{64}$ ]]; then
      go=false
      failed="pricing: the verdict's pricing_diff_sha256 is not a sha256${failed:+; $failed}"
      pricing=""
    fi
  fi
  fact preflight_failed_checks "$failed"
  if [ "$live_rid" = "$R" ]; then
    step catalog_preflight "done" "live release is $R"
    step catalog_activation "done" "live release is $R ($live_status)"
  else
    if [ "$fresh" = true ]; then
      step catalog_preflight "done" "go=$go ($verdict)"
    else
      step catalog_preflight pending "live $live_rid != committed $R"
      if [ "$head_sha" != "$main_sha" ]; then
        set_next catalog_preflight blocked "Preflight the content release" "" \
          "run from a clean worktree whose HEAD is origin/main ($main_sha); tooling must match the commit"
      elif [ "$p_paused" = true ] || [ "$p_status_ok" = false ]; then
        set_next catalog_preflight blocked "Preflight content release $R" "" "$paused_why"
      else
        set_next catalog_preflight read "Preflight content release $R at $main_sha (no mutation)" \
"mkdir -p '$OPS_STATE_DIR/$OPS_SCOPE'
scripts/catalog-content-release.sh --preflight --commit $main_sha > '$verdict.tmp' || true
mv '$verdict.tmp' '$verdict'
python3 -m json.tool '$verdict'"
        next_meta catalog_preflight "$TREE_DOC#run"
      fi
    fi
    step catalog_activation pending "${owed_pf:+evidence (e) owed after activation: $owed_pf}"
    local restore_cmd deploy_cmd content_downtime
    restore_cmd="$(render_runbook "$RB_CATALOG_RESTORE")"
    # The deploy's own verdict line (sorted keys: buyer_serving_e2e_owed first)
    # records which (e) the activation left owed; only a successful deploy writes it.
    # Owed (e) is written to the ledger BEFORE the deploy from the preflight
    # verdict (fsynced), and again from the deploy's own verdict line (sorted
    # keys: buyer_serving_e2e_owed first): a deploy that goes live and then
    # loses its local output still leaves every owed model open.
    local owed_writer
    owed_writer="python3 -I -c 'import datetime, hashlib, json, os, sys
src, out, rel = sys.argv[1:4]
lines = [l for l in open(src) if l.startswith(\"{\")]
docs = [json.loads(l) for l in lines if l.startswith(\"{\\\"buyer_serving_e2e_owed\\\"\")]
now = datetime.datetime.now(datetime.timezone.utc).strftime(\"%Y-%m-%dT%H:%M:%SZ\")
for m in (docs[-1] if docs else {}).get(\"buyer_serving_e2e_owed\") or []:
    rec = {\"model_id\": m[\"model_id\"], \"sha256\": m[\"sha256\"], \"release_id\": rel, \"recorded_at\": now}
    name = hashlib.sha256((m[\"model_id\"] + \" \" + m[\"sha256\"]).encode()).hexdigest()
    final = os.path.join(out, name + \".json\")
    if os.path.exists(final):
        continue
    tmp = final + \".tmp\"
    with open(tmp, \"w\") as f:
        json.dump(rec, f, sort_keys=True)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, final)'"
    deploy_cmd="mkdir -p '$OPS_STATE_DIR/$OPS_SCOPE' '$owed_dir'
$owed_writer '$verdict' '$owed_dir' '$R'
scripts/catalog-content-release.sh --deploy --commit $main_sha ${pricing:+--pricing-diff-sha256 $pricing }--preflight-verdict '$verdict' | tee '$deploy_log'
$owed_writer '$deploy_log' '$owed_dir' '$R'"
    content_downtime="no coordinator restart: one SIGHUP reloads the release${pricing:+ and the rate card}; the canary provider is drained and restarted onto the release, so the requests it would serve go to other providers of its model or wait for its restart and model load; a failed activation rolls back and can strand adopters for 3-11 min"
    # SPEC-048-R014 item 10 (0.1.51): decode-path admission entries are
    # rejected by CLIs before the reader, so they go live only when the bound
    # release (git-verified digest at its source commit) is the recommended CLI.
    local dp_gate="ok"
    if [ "$native_bound" = true ]; then
      if [ -n "${CATALOG_SIGNED_PAIR_PLAN:-}" ]; then
        dp_gate="$(signed_pair_decode_path_gate "$CATALOG_SIGNED_PAIR_PLAN" "$OPS_TMP_DIR/adm.json" \
          "$(json_field "$OPS_TMP_DIR/healthz.json" 'd.get("recommended_binary_version") or ""' 2>/dev/null)")"
      else
        dp_gate="$(python3 "$REPO_ROOT/scripts/decode_path_digest.py" --publish-gate \
          "$CATALOG_TARGET_INPUT" "$CATALOG_TARGET_DIR/native-mtp-admission.json" \
          "$(json_field "$OPS_TMP_DIR/healthz.json" 'd.get("recommended_binary_version") or ""' 2>/dev/null)" 2>&1 ||
          echo "blocked: decode-path publish gate failed")"
      fi
    fi
    fact native_mtp_decode_path_publish_gate "$dp_gate"
    if [ "$dp_gate" != ok ]; then
      set_next catalog_activation blocked "Activate content release $R" "" "$dp_gate"
    elif [ -n "${CATALOG_SIGNED_PAIR_PLAN:-}" ] && [ "$fresh" = true ] && [ "$go" = true ] && [ -z "$pricing" ]; then
      local pair_sha
      if [ "$head_sha" != "$main_sha" ] || ! pair_sha="$(signed_pair_plan_sha)"; then
        set_next signed_native_pair blocked "Validate the matched signed release intent" "" "clean origin/main and an exact private target intent are required"
      else
        step signed_native_pair pending "released signed binary and signed policy must change under one recovery journal"
        set_next signed_native_pair mutate "Install the matched signed native-MTP binary/policy pair" \
          "$OPS_DIR/catalog-activate.sh _signed-native-pair $main_sha $pair_sha"
        next_meta signed_native_pair "$MTP_DOC" "provider pause/drain, one released-binary restart and model load, then 120-second stability; independent exact-pair recovery is armed first; content publication uses one coordinator SIGHUP"
      fi
    elif [ "$fresh" = true ] && { [ "$p_paused" = true ] || [ "$p_status_ok" = false ]; } &&
      { [ "$go" = true ] || printf '%s' "$lane_detail" | grep -q 'lane='; }; then
      set_next catalog_activation blocked "Activate content release $R" "" "$paused_why"
    elif [ "$fresh" = true ] && [ "$go" = true ] && [ -z "$pricing" ]; then
      set_next catalog_activation mutate "Activate content release $R${owed_pf:+ (evidence (e) owed: $owed_pf)}" "$deploy_cmd"
      next_meta catalog_activation "$TREE_DOC#run" "$content_downtime"
    elif [ "$fresh" = true ] && [ "$go" = true ] && [ "${CATALOG_PRICING_ACK:-}" = "$pricing" ]; then
      set_next catalog_activation mutate "Activate pricing release $R with the acknowledged price table $pricing${owed_pf:+ (evidence (e) owed: $owed_pf)}" "$deploy_cmd"
      next_meta catalog_activation "$TREE_DOC#preflight-and-the-price-table" "$content_downtime"
    elif [ "$fresh" = true ] && [ "$go" = true ]; then
      set_next catalog_activation blocked "Review the price table, then activate $R with its acknowledgement digest" \
        "python3 -m json.tool '$verdict'" \
        "a pricing release needs the operator's acknowledgement of the price table (the verdict's pricing object; the preflight printed it on stderr): after review, run with CATALOG_PRICING_ACK=$pricing"
      next_meta catalog_activation "$TREE_DOC#preflight-and-the-price-table" ""
    elif [ "$fresh" = true ] && printf '%s' "$lane_detail" | grep -q 'lane=' && ! printf '%s' "$lane_detail" | grep -q 'lane=catalog-content'; then
      set_next catalog_activation manual "Full catalog activation with deploy-pearl-vps.sh from the running tag" \
"# The content gate refused: $lane_detail
# docs/runbooks/pearl-coordinator-rollout.md 'Catalog activation (full deploy)': from a clean
# worktree at the RUNNING tag, after the nginx and coordinator.yaml prerequisites, chain the restore:
$restore_cmd
# As soon as public /v1/autotune-release reports $R, kickstart the canary provider and confirm
# its /v1/status catalog.release_id == $R (kickstart again at once if it came up on the old release)."
      next_meta catalog_activation "$ROLLOUT_DOC#catalog-activation-full-deploy" \
        "coordinator restart: seconds; a failed activation strands adopters for 3-11 min"
    elif [ "$fresh" = true ]; then
      local hint=""
      case "$failed" in *canary_reachable:*) [ "$p_paused" = false ] || hint=" ($paused_why)" ;; esac
      set_next catalog_activation blocked "Activate $R" "python3 -m json.tool '$verdict'" \
        "preflight NO_GO: ${failed:-see the verdict}$hint; fix every failing check, then preflight again"
    fi
  fi

  # SPEC-031-R033: the coordinator canary reloads its self-test bank with the
  # SIGHUP release reload and reports the bank it holds on /healthz, release
  # and SHA-256. Done needs both to match the served bank: the release id
  # alone would pass a stale bank re-labelled with the same release. A
  # runtime without that signal read the bank at boot only, so a
  # SIGHUP-loaded native-bound release still needs a restart, in this step.
  local bank_reloads canary_bank_rid canary_bank_sha restart_needed=false
  bank_reloads="$(json_field "$OPS_TMP_DIR/healthz.json" 'd.get("native_mtp_canary_bank_reloads")')"
  canary_bank_rid="$(json_field "$OPS_TMP_DIR/healthz.json" 'd.get("native_mtp_canary_bank_release_id")')"
  canary_bank_sha="$(json_field "$OPS_TMP_DIR/healthz.json" 'd.get("native_mtp_canary_bank_sha256")')"
  fact coordinator_canary_bank_reloads "${bank_reloads:-false}"
  fact coordinator_canary_bank_release_id "$canary_bank_rid"
  fact coordinator_canary_bank_sha256 "$canary_bank_sha"
  if [ "$native_bound" != true ]; then
    step canary_bank "done" "release is not native-bound"
  elif [ "$live_rid" != "$R" ]; then
    step canary_bank pending "after activation"
  elif [ "$bank_reloads" = true ]; then
    if [ "$canary_bank_rid" = "$R" ] && [ -n "$live_bank_sha" ] && [ "$canary_bank_sha" = "$live_bank_sha" ]; then
      step canary_bank "done" "canary holds the served $R self-test bank (sha256 $live_bank_sha), reloaded with the release"
    elif [ -z "$live_bank_sha" ]; then
      step canary_bank unknown "served /v1/native-mtp-selftest-bank unreadable; cannot compare the canary bank digest"
    else
      step canary_bank blocked "canary bank '${canary_bank_rid:-none}' sha256 '${canary_bank_sha:-none}' != served $R sha256 $live_bank_sha"
      set_next canary_bank blocked "Make the coordinator canary hold the served $R self-test bank" "" \
        "the coordinator reloads the canary bank with the release but holds '${canary_bank_rid:-none}' (sha256 '${canary_bank_sha:-none}'), not the served $R bank (sha256 $live_bank_sha): the pool native_mtp_canary block is missing or disabled, its keys do not verify the bank, or the coordinator predates the bank digest on /healthz (journal: 'native MTP canary'); a restart fixes neither"
      next_meta canary_bank "$MTP_DOC#order"
    fi
  elif [ -z "$uptime" ] || [ -z "$verified_min" ]; then
    step canary_bank unknown "coordinator /healthz or /v1/autotune-release unreadable"
  else
    restart_needed="$(python3 - "$uptime" "$verified_min" <<'PY'
import datetime, sys
now = datetime.datetime.now(datetime.timezone.utc)
started = now - datetime.timedelta(seconds=int(sys.argv[1]))
verified = datetime.datetime.strptime(sys.argv[2], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
print("true" if verified - started > datetime.timedelta(seconds=120) else "false")
PY
)"
    if [ "$restart_needed" = true ]; then
      step canary_bank pending "this coordinator reads the canary bank at boot only and loaded $R by SIGHUP"
      set_next canary_bank mutate "Restart the coordinator so the native canary loads the $R self-test bank" \
"ssh \"\$PEARL_SSH\" 'flock -n /run/lock/macprovider-pearl-updater.lock flock -n /opt/macprovider/.coordinator-deploy.lock systemctl restart macprovider-coordinator'
for i in \$(seq 1 24); do curl -sf -m 5 \"\$COORDINATOR_URL/healthz\" && exit 0; sleep 5; done; echo 'coordinator not healthy after 120 s' >&2; exit 1"
      next_meta canary_bank "$ROLLOUT_DOC" "coordinator restart: a few seconds of buyer outage"
    else
      step canary_bank "done" "booted on or after the release load"
    fi
  fi
  fact coordinator_restart_needed_for_bank "$restart_needed"

  if [ -z "$p_rid" ]; then
    step provider_restart unknown "STUDIO_SSH/STUDIO_STATUS_PORT unset or status unreadable"
    set_next provider_restart blocked "Read the canary provider status" "" \
      "STUDIO_SSH and STUDIO_STATUS_PORT must be set (read-only curl of the provider's local /v1/status)"
  elif [ "$p_rid" = "$R" ] && [ "$p_connected" = true ]; then
    step provider_restart "done" "provider on $R and connected"
  else
    step provider_restart pending "provider on $p_rid (connected=$p_connected)"
    set_next provider_restart manual "Restart the canary provider onto $R (operator approval)" \
"ssh \"\$STUDIO_SSH\" 'launchctl kickstart -k gui/\$(id -u)/live.malibu.provider'
# then: ssh \"\$STUDIO_SSH\" 'curl -s http://127.0.0.1:\$STUDIO_STATUS_PORT/v1/status' -> catalog.release_id == $R,
# connected: true; if it came up on the old release, kickstart again right away."
    next_meta provider_restart "$ROLLOUT_DOC#run-with-an-automatic-restore"
  fi

  # Dense CB-only models have no native-MTP heads. An explicit CB-only proof
  # must not require that unrelated capability. Preserve the historical native
  # probe when unset; the gateway proof still requires shared-forward movement.
  if [ "$p_cb_active" = true ] && { [ "${CATALOG_REQUIRE_NATIVE_MTP_FORWARD:-}" = false ] ||
       { [ "$p_mtp_enabled" = true ] && { [ "$p_mtp_mode" = eligible ] || [ "$p_mtp_mode" = active ]; }; }; }; then
    step live_probe "done" "continuous_batching active, native_mtp $p_mtp_mode (forward requirement=${CATALOG_REQUIRE_NATIVE_MTP_FORWARD:-default})"
  else
    step live_probe pending "native_mtp enabled=$p_mtp_enabled mode=$p_mtp_mode cb_active=$p_cb_active"
    if [ "${CATALOG_REQUIRE_NATIVE_MTP_FORWARD:-}" = false ]; then
      [ -z "$p_rid" ] || set_next live_probe manual "Verify the signed CB policy and local self-check grant for the target provider" \
"# Confirm /v1/status continuous_batching.active=true after the signed policy and local self-check grant.
# Do not enable native MTP on a model without qualified MTP heads."
      next_meta live_probe "specs/SPEC-038-continuous-batching.md"
    else
      [ -z "$p_rid" ] || set_next live_probe manual "Turn the tuple on for the provider (native_mtp_mode: auto) and restart it" \
"# docs/runbooks/native-mtp-enablement.md step 9 (operator approval: restarts live.malibu.provider)
# set native_mtp_mode: auto in the provider config, restart, then confirm /v1/status
# native_mtp.enabled=true, mode eligible|active, continuous_batching.active=true"
      next_meta live_probe "$MTP_DOC#order"
    fi
  fi

  # The proof expires, and legacy generic request-counter markers are not enough
  # once continuous batching is active: a fresh marker must carry the scheduler
  # shared_forward_calls delta from the provider-attributed buyer request.
  local require_mtp
  require_mtp="$(native_mtp_forward_requirement)"
  if [ "${PROBE_MODEL:-}" = "$QWEN_NATIVE_MODEL" ] && [ "$require_mtp" != true ]; then
    refuse "Qwen3.6 proof requires CATALOG_REQUIRE_NATIVE_MTP_FORWARD=true"
  fi
  if gateway_proof_marker_valid "$OPS_SCOPE" "$p_cb_active" "$require_mtp" \
       "${PROBE_MODEL:-}" "$R" "$p_digest"; then
    step gateway_proof "done" "$(marker_field "$OPS_SCOPE" gateway_proof 'd.get("evidence")')"
  else
    step gateway_proof pending "$(marker_done "$OPS_SCOPE" gateway_proof && echo 'previous proof older than 24 h or lacks active-path scheduler evidence' || true)"
    if [ "${PROBE_MODEL:-}" = "$QWEN_NATIVE_MODEL" ] && [ "$require_mtp" = true ]; then
      set_next gateway_proof mutate "Adopt Qwen3.6, prove one paid native-MTP request, and restore GLM" \
        "$OPS_DIR/qwen-opencode-e2e.sh _catalog-qwen36-proof"
      NEXT_DOWNTIME="Studio provider buyer traffic is unavailable during bounded Qwen/GLM restart and model-load windows; Pearl is not restarted"
    elif gateway_expanded_required; then
      set_next gateway_proof mutate "Prove signed GLM sampled/tools/history/reasoning across all three buyer APIs" \
        "scripts/ops/catalog-activate.sh _gateway-proof"
      NEXT_DOWNTIME="Buyer runner pauses for bounded proof; provider serving, native MTP and continuous batching stay live"
    else
      set_next gateway_proof read "Send one real buyer request through the gateway" \
        "scripts/ops/catalog-activate.sh _gateway-proof"
    fi
    next_meta gateway_proof "AGENTS.md#hard-rules--activation-evidence-and-campaign-discipline"
  fi

  # SPEC-023 §16.11 rule 4 before evidence (e): the DeepSeek-V4-Flash window is
  # also what first serves that model, and it records the (e) request.
  gather_buyer_ux_conformance_owed "$live_rid"

  # Evidence (e) owed (SPEC-023-R017 5(e)): every ledger entry whose model no
  # buyer_serving_e2e record names yet. A malformed entry is unknown, not done.
  local owed_scan owed_models="" owed_bad=""
  owed_scan="$(python3 -I - "$owed_dir" "$OPS_STATE_DIR" <<'PY'
import glob, json, os, re, sys
owed_dir, state = sys.argv[1:3]
# A buyer_serving_e2e record proves exactly the model@sha256 pairs it names.
proved = set()
for path in glob.glob(os.path.join(state, "catalog-*", "buyer_serving_e2e.json")):
    try:
        text = str(json.load(open(path)).get("evidence", ""))
    except Exception:
        continue
    proved |= set(re.findall(r"(?:^|\s)model=(\S+)@([0-9A-Za-z]+)(?=\s|$|[,;])", text))
open_models, bad = [], []
for path in sorted(glob.glob(os.path.join(owed_dir, "*.json"))):
    try:
        rec = json.load(open(path))
        model, sha, rel = rec["model_id"], rec["sha256"], rec["release_id"]
        if not all(isinstance(v, str) and v and not any(c.isspace() for c in v) for v in (model, sha, rel)):
            raise ValueError
    except Exception:
        bad.append(os.path.basename(path))
        continue
    if (model, sha) not in proved:
        open_models.append("%s@%s (owed since %s)" % (model, sha, rel))
print("BAD " + " ".join(bad))
print("OPEN " + ", ".join(open_models))
PY
)"
  owed_bad="$(printf '%s\n' "$owed_scan" | sed -n 's/^BAD //p')"
  owed_models="$(printf '%s\n' "$owed_scan" | sed -n 's/^OPEN //p')"
  fact buyer_serving_e2e_owed "$owed_models"
  if [ -n "$owed_bad" ]; then
    step buyer_serving_e2e blocked "unreadable owed-evidence record(s): $owed_bad"
    set_next buyer_serving_e2e blocked "Read the owed evidence (e) records" "ls -l '$owed_dir'" \
      "owed evidence (e) record(s) in $owed_dir are malformed ($owed_bad); an owed proof is never assumed done"
  elif [ -n "$owed_models" ]; then
    step buyer_serving_e2e owed "$owed_models: owed by the provider release that first serves it (CLI train canary; #2016 live acceptance)"
    set_next buyer_serving_e2e manual "Owed evidence (e) for $owed_models: canary restart onto the live release, one buyer request through the gateway served by it, its settlement row" \
"# Owed by the provider release that first serves the model (the CLI train canary and the
# #2016 live acceptance): no connected provider served it when its release was activated.
# On that canary, while it is the only provider serving the model:
# 1. Provider restart onto the live release:
ssh \"\$STUDIO_SSH\" 'launchctl kickstart -k gui/\$(id -u)/live.malibu.provider'
#    then its /v1/status: catalog.release_id == the live release, network_state buyer_serving,
#    the model loaded; note safety_telemetry.coordinator_session_id.
# 2. One buyer request for the model through the gateway (the bearer rides curl --config on stdin):
#    printf 'header = \"Authorization: Bearer %s\"\\n' \"\$(cat \"\$BUYER_TOKEN_FILE\")\" | curl -sS --config - -D - \\
#      -H 'Content-Type: application/json' -H 'X-Request-ID: ops-e2e-<nonce>' \\
#      -d '{\"model\":\"<model>\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with ok.\"}]}' \\
#      \"\$GATEWAY_URL/v1/chat/completions\"   -> HTTP 200 and an X-Request-ID
# 3. On Pearl, read-only: its request_log row names the canary's coordinator session
#    (provider_assigned_id), and its settlement row carries the rate-card row's rates.
# Then: scripts/ops/catalog-activate.sh next --done buyer_serving_e2e --evidence 'model=<model_id>@<sha256> <request id, session match, rates, settlement row>'
# (one model=<model_id>@<sha256> token, exactly as listed above, per model it proves)" \
      "a release was activated with (e) owed because no connected provider served the model"
    next_meta buyer_serving_e2e "$TREE_DOC#evidence-after-activation" "the canary restart only: requests it would serve go to other providers of its model or wait for its restart and model load"
  elif [ "$live_rid" != "$R" ]; then
    step buyer_serving_e2e pending "${owed_pf:+owed after activation: $owed_pf}"
  else
    step buyer_serving_e2e "done" "no owed evidence (e) is open"
  fi

  set_next "done" "done" "$R active and proven through the gateway" ""
}

# step_done ID: the step recorded so far in this run is done.
step_done() { awk -F'\t' -v id="$1" '$1 == id { s = $2 } END { exit (s == "done") ? 0 : 1 }' "$OPS_STEPS"; }

# gather_buyer_ux_conformance_owed LIVE_RID: step 12 (SPEC-023 §16.11 rule 4).
# A key promoted with its record owed stays open until origin/main's record
# file holds a passing record for it and step 4a has that file in force.
gather_buyer_ux_conformance_owed() {
  local live_rid="$1" scan open="" settled_keys="" waiting="" open_keys=""
  if [ ! -s "${BUC_OWED_JSON:-}" ]; then
    if [ -f "$REPO_ROOT/$BUC_FILE" ]; then
      step buyer_ux_conformance_owed blocked "the committed record file is unreadable (step buyer_ux_conformance)"
    else
      step buyer_ux_conformance_owed "done" "no committed record file"
    fi
    return
  fi
  scan="$(python3 -I - "$BUC_OWED_JSON" "$R" "$live_rid" <<'PY'
import json, sys
path, committed, live = sys.argv[1:4]
owed = json.load(open(path))["owed"]
open_ = [e for e in owed if e["state"] != "settled"]
# The release of an owed key is live once the coordinator serves it, or once a later
# committed release superseded it (releases are activated in order).
live_open = [e for e in open_ if e["release_id"] == live or e["release_id"] != committed]
print("OPEN " + ", ".join("%s (%s, %s: %s)" % (e["catalog_key"], e["model"], e["state"], e["detail"]) for e in live_open))
print("WAIT " + ", ".join("%s (owed after %s is live)" % (e["catalog_key"], e["release_id"]) for e in open_ if e not in live_open))
print("KEYS " + " ".join(e["catalog_key"] for e in owed))
print("OPENKEYS " + " ".join(e["catalog_key"] for e in live_open))
PY
)" || { step buyer_ux_conformance_owed blocked "cannot read the owed entries"; return; }
  open="$(printf '%s\n' "$scan" | sed -n 's/^OPEN //p')"
  waiting="$(printf '%s\n' "$scan" | sed -n 's/^WAIT //p')"
  settled_keys="$(printf '%s\n' "$scan" | sed -n 's/^KEYS //p')"
  open_keys="$(printf '%s\n' "$scan" | sed -n 's/^OPENKEYS //p')"
  fact buyer_ux_conformance_owed "$open${waiting:+${open:+; }$waiting}"
  if [ -n "$open" ] && [ -n "${QWEN_E2E_JOURNAL:-}" ] && [ -n "${DSV4_IMPORT_DIR:-}" ] &&
     case " $open_keys " in *" deepseek/deepseek-v4-flash "*) true ;; *) false ;; esac; then
    # The DeepSeek-V4-Flash record is run in a journaled Studio window.
    step buyer_ux_conformance_owed owed "$open"
    set_next buyer_ux_conformance_owed mutate \
      "Serve DeepSeek-V4-Flash on the Studio, run its owed buyer-UX conformance through the gateway, and restore GLM" \
      "$OPS_DIR/qwen-opencode-e2e.sh _catalog-dsv4-conformance"
    next_meta buyer_ux_conformance_owed "$BUC_DOC#conformance-owed-first-promotion-1611-rule-4" "$DSV4_WINDOW_DOWNTIME"
  elif [ -n "$open" ]; then
    step buyer_ux_conformance_owed owed "$open"
    set_next buyer_ux_conformance_owed manual "Run the owed buyer-UX conformance through the gateway and commit the record: $open" \
"# SPEC-023 §16.11 rule 4: the promotion is live with its record owed; /v1/models
# advertises the base capability set for it until a passing record lands.
# Per owed key, while a provider serves the model through the gateway:
python3 scripts/buyer_ux_conformance.py run --key-file \"\$BUYER_TOKEN_FILE\" \\
  --model <served model id above> --catalog-key <catalog key above>
python3 scripts/buyer_ux_conformance.py owed-status   # state settled
# Commit phase3-binary/catalog/autotune/buyer-ux-conformance.json to origin/main
# (records-only change, no re-signed release), then: catalog-activate.sh next --run
# installs it (step buyer_ux_conformance)." \
      "a key was promoted to recommendable with its buyer-UX conformance record owed"
    next_meta buyer_ux_conformance_owed "$BUC_DOC#conformance-owed-first-promotion-1611-rule-4" "none: read-only requests through the gateway"
  elif [ -n "$waiting" ]; then
    step buyer_ux_conformance_owed pending "$waiting"
  elif [ -n "$settled_keys" ] && ! step_done buyer_ux_conformance; then
    step buyer_ux_conformance_owed pending "passing record(s) committed for $settled_keys; install pending (step buyer_ux_conformance)"
  else
    step buyer_ux_conformance_owed "done" "${settled_keys:+passing record(s) in force for $settled_keys}${settled_keys:-no buyer-UX conformance record is owed}"
  fi
}

# provider_counters FILE -> "mtp_forwards requests_total cb_active cb_shared_forward_calls"
# from a provider /v1/status document; fails when the counters needed for the
# active serving mode are absent.
provider_counters() {
  python3 - "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
mtp = (d.get("native_mtp") or {}).get("mtp_forwards")
req = d.get("requests_total")
cb_doc = d.get("continuous_batching") or {}
cb = cb_doc.get("active") is True
scheduler = cb_doc.get("scheduler") or {}
shared = scheduler.get("shared_forward_calls")
if not isinstance(mtp, int) or not isinstance(req, int):
    sys.exit(1)
if cb and not isinstance(shared, int):
    sys.exit(1)
mtp_doc = d.get("native_mtp") or {}
# A provider that reports native MTP explicitly disabled serves on the serial path.
serial = mtp_doc.get("enabled") is False and not cb
print(mtp, req, "true" if cb else "false", shared if isinstance(shared, int) else 0, "true" if serial else "false")
PY
}

read_provider_status() {
  studio_ssh "curl -s -m 10 http://127.0.0.1:$STUDIO_STATUS_PORT/v1/status" > "$1" ||
    refuse "provider /v1/status not readable over STUDIO_SSH"
}

native_mtp_forward_requirement() {
  if gateway_expanded_required; then echo true; return; fi
  case "${CATALOG_REQUIRE_NATIVE_MTP_FORWARD:-false}" in
    false) echo false ;;
    true) echo true ;;
    *) refuse "CATALOG_REQUIRE_NATIVE_MTP_FORWARD must be true or false" ;;
  esac
}

require_qwen_proof_lock() {
  local status="$OPS_TMP_DIR/qwen-proof-lock.json"
  [ "${MACPROVIDER_OPS_ENTRYPOINT:-}" = 1 ] && [ -n "${MACPROVIDER_OPS_OWNER:-}" ] ||
    refuse "Qwen3.6 gateway proof is callable only from the catalog transaction"
  "$OPS_DIR/live-lock.sh" status > "$status" 2>/dev/null ||
    refuse "Qwen3.6 gateway proof cannot read the live-ops lock"
  python3 - "$status" "$MACPROVIDER_OPS_OWNER" <<'PY' ||
import json, sys
d=json.load(open(sys.argv[1])); lock=d.get("lock") or {}
raise SystemExit(0 if d.get("held") is True and lock.get("owner")==sys.argv[2]
                 and lock.get("purpose")=="catalog-activate:qwen_restore" else 3)
PY
    refuse "Qwen3.6 gateway proof requires the already-held durable restoration lock"
}

gateway_expanded_code() {
  cat <<'PYEXPANDED'
import hashlib,json,os,re,stat,sys,time
from pathlib import Path

def need(ok,why):
    if not ok:raise ValueError(why)
def unique(pairs):
    out={}
    for k,v in pairs:need(k not in out,'duplicate JSON key');out[k]=v
    return out
def load(path):return json.loads(Path(path).read_bytes(),object_pairs_hook=unique)
def digest(data):return hashlib.sha256(data).hexdigest()
def emit(value):print(json.dumps(value,sort_keys=True,separators=(',',':')))
FAMILIES=('chat','responses','messages');PROFILES=('sampled','tools','history','reasoning')
PATHS={'chat':'/v1/chat/completions','responses':'/v1/responses','messages':'/v1/messages'}
def shape(family,profile,model,nonce):
    need(family in FAMILIES and profile in PROFILES and model=='zai-org/glm-5.3-flash','closed expanded proof shape')
    prompt='Proof nonce '+nonce+'. Explain the example function in two short sentences.'
    if profile=='tools':prompt='Proof nonce '+nonce+'. Read example.swift using read_file before answering. Call read_file now; the file contents are not in this conversation.'
    fn={'name':'read_file','parameters':{'type':'object','properties':{'path':{'type':'string'}},'required':['path']}}
    p={'model':model,'stream':False,'temperature':1 if profile in ('sampled','tools') else 0,'top_p':.95 if profile in ('sampled','tools') else 1}
    if family=='chat':
        p.update(max_tokens=256 if profile=='tools' else 64,seed=8516,messages=[{'role':'user','content':prompt}])
        if profile in ('tools','history'):p.update(tools=[dict(type='function',function=fn)],tool_choice='auto',parallel_tool_calls=True)
        if profile=='history':p['messages']=[{'role':'user','content':prompt},{'role':'assistant','content':'','tool_calls':[{'id':'call_proof','type':'function','function':{'name':'read_file','arguments':'{"path":"example.swift"}'}}]},{'role':'tool','tool_call_id':'call_proof','content':'func square(_ x: Int) -> Int { x * x }'},{'role':'user','content':'Explain that function.'}]
        if profile in ('history','reasoning'):p['reasoning_effort']='high'
    elif family=='responses':
        p.update(max_output_tokens=256 if profile=='tools' else 64,store=False,input=[{'role':'user','content':prompt}])
        if profile in ('tools','history'):p.update(tools=[dict(type='function',**fn)],tool_choice='auto',parallel_tool_calls=True)
        if profile=='history':p['input'] += [{'type':'function_call','call_id':'call_proof','name':'read_file','arguments':'{"path":"example.swift"}'},{'type':'function_call_output','call_id':'call_proof','output':'func square(_ x: Int) -> Int { x * x }'},{'role':'user','content':'Explain that function.'}]
        if profile in ('history','reasoning'):p['reasoning']={'effort':'high'}
    else:
        p.update(max_tokens=256 if profile=='tools' else 64,messages=[{'role':'user','content':prompt}])
        if profile in ('tools','history'):p.update(tools=[{'name':'read_file','input_schema':fn['parameters']}],tool_choice={'type':'auto','disable_parallel_tool_use':False})
        if profile=='history':p['messages'] += [{'role':'assistant','content':[{'type':'tool_use','id':'call_proof','name':'read_file','input':{'path':'example.swift'}}]},{'role':'user','content':[{'type':'tool_result','tool_use_id':'call_proof','content':'func square(_ x: Int) -> Int { x * x }'},{'type':'text','text':'Explain that function.'}]}]
        if profile in ('history','reasoning'):p['thinking']={'type':'enabled','budget_tokens':1024}
    return p

def capture(path,since=-1,prefix=0):
    p=Path(path);s=Path(str(p)+'.status.json')
    for f in (p,s):
        st=f.lstat();need(stat.S_ISREG(st.st_mode) and not f.is_symlink() and st.st_mode & 0o077==0 and 0<st.st_size<=10485760,'private bounded capture input')
    for _ in range(10):
        status=s.read_bytes();raw=p.read_bytes()
        if status==s.read_bytes():
            v=json.loads(status,object_pairs_hook=unique)
            if v.get('jsonl_bytes_written')==len(raw):break
        time.sleep(.02)
    else:raise ValueError('capture snapshot raced')
    lines=raw.splitlines();h=json.loads(lines[0],object_pairs_hook=unique)
    need(h.get('schema')=='macprovider.native-mtp-request-shape-capture.v2' and h.get('capture_role')=='request_shape_observation_only' and h.get('native_mtp_mode')=='auto' and h.get('capture_requires_native_mtp_off') is False and h.get('build_identity_complete') is True,'actual native-on capture v2 required')
    need(v.get('schema')==h['schema'] and v.get('record_type')=='status' and v.get('capture_file_name')==p.name and v.get('build_identity_complete') is True,'capture status identity')
    need(type(v.get('successful_records')) is int and len(lines)==v['successful_records']+1 and v.get('attempts')==v['successful_records'],'capture attempts/records incomplete')
    for k in ('skipped_ineligible','skipped_empty_completion','dropped_missing_effective_budget','dropped_after_record_limit','dropped_after_byte_limit','jsonl_write_errors','status_write_errors'):need(v.get(k)==0,'capture drop/error')
    return dict(header=h,header_sha256=digest(lines[0]),status=v,bytes=len(raw),sha256=digest(raw),prefix_sha256=digest(raw[:prefix]),rows=[] if since<0 else [json.loads(x,object_pairs_hook=unique) for x in lines[1+since:]],file_identity=[p.stat().st_dev,p.stat().st_ino])

def capture_custody(path,journal,expected_sha):
    import ctypes,subprocess,plistlib
    def private(p):
        p=Path(p);st=p.lstat()
        need(not p.is_symlink() and stat.S_ISREG(st.st_mode) and st.st_mode & 0o077==0 and st.st_size<=1048576,'private custody file')
        return p.read_bytes()
    raw=private(journal);need(digest(raw)==expected_sha,'signed-pair journal changed')
    j=json.loads(raw,object_pairs_hook=unique);state=json.loads(private(Path(journal).parent/'studio-state.json'),object_pairs_hook=unique)
    need(state.get('phase')=='committed' and state.get('journal_sha256')==expected_sha and state.get('transaction_id')==j['transaction_id'],'committed signed pair required')
    p=Path(path);need(p.parent==Path(j['studio']['capture_dir']),'capture is outside the signed-pair launch directory')
    snapshot=capture(path)
    need(snapshot['header']['build_source_commit']==j['target']['source_commit'] and snapshot['header']['build_cdhash']==j['target']['cdhash'],'capture is not signed-pair candidate')
    plist=plistlib.loads(private(j['studio']['launchd_plist']))
    need(plist.get('Label')==j['studio']['launchd_label'],'launchd label changed')
    env=plist.get('EnvironmentVariables',{})
    need(env.get('MACPROVIDER_NATIVE_MTP_SHAPE_CAPTURE_DIR')==str(p.parent) and env.get('MACPROVIDER_NATIVE_MTP_SHAPE_CAPTURE_SCHEMA')=='v2','capture launch environment changed')
    def run(args):return subprocess.run(args,check=True,capture_output=True,text=True,timeout=10,env=dict(os.environ,LC_ALL='C')).stdout
    loaded=run(['/bin/launchctl','print','gui/%d/%s'%(os.getuid(),j['studio']['launchd_label'])])
    found=re.search(r'^\s*pid = ([0-9]+)$',loaded,re.M);need(found is not None,'live provider PID absent');pid=found.group(1)
    # Match loaded environment as well as the persisted plist; editing an unused
    # plist cannot bind an unrelated capture session to the running process.
    need(re.search(r'MACPROVIDER_NATIVE_MTP_SHAPE_CAPTURE_DIR\s*=>\s*'+re.escape(str(p.parent))+r'\s*$',loaded,re.M) is not None and re.search(r'MACPROVIDER_NATIVE_MTP_SHAPE_CAPTURE_SCHEMA\s*=>\s*v2\s*$',loaded,re.M) is not None,'loaded capture environment differs')
    started=run(['/bin/ps','-p',pid,'-o','lstart=']).strip()
    need(started and run(['/bin/ps','-p',pid,'-o','uid=']).strip()==str(os.getuid()),'provider process owner differs')
    from datetime import datetime
    began=time.mktime(time.strptime(started,'%a %b %d %H:%M:%S %Y'))
    created=datetime.fromisoformat(snapshot['header']['sample_window_started_at'].replace('Z','+00:00')).timestamp()
    need(began-2<=created<=time.time()+5,'capture predates the current provider process')
    opened=run(['/usr/sbin/lsof','-a','-p',pid,'-Fn','--',str(p)])
    need('n'+str(p) in opened.splitlines(),'current provider does not hold the capture file open')
    buffer=ctypes.create_string_buffer(4096);libproc=ctypes.CDLL('/usr/lib/libproc.dylib')
    need(libproc.proc_pidpath(int(pid),buffer,len(buffer))>0 and os.path.realpath(os.fsdecode(buffer.value))==os.path.realpath(str(Path(j['studio']['install_dir'])/'macprovider-cli')),'provider binary process path differs')
    binary=Path(j['studio']['install_dir'])/'macprovider-cli'
    need(digest(binary.read_bytes())==j['target']['binary_sha256'],'current provider signed candidate bytes differ')
    run(['/usr/bin/codesign','--verify','--strict',str(binary)])
    signed=subprocess.run(['/usr/bin/codesign','-d','--verbose=4',str(binary)],check=True,capture_output=True,text=True,timeout=10)
    signature=signed.stdout+signed.stderr
    need(j['target']['cdhash'] in re.findall(r'^CDHash=(.*)$',signature,re.M),'current provider CDHash differs')
    snapshot['custody_sha256']=digest(json.dumps([expected_sha,[pid,started],snapshot['header_sha256']],separators=(',',':')).encode())
    return snapshot

def forbidden(v):
    if isinstance(v,dict):return any('native_mtp' in k.lower() or 'nativemtp' in k.lower() or forbidden(x) for k,x in v.items())
    if isinstance(v,list):return any(forbidden(x) for x in v)
    if isinstance(v,str) and v.lstrip().startswith(('{','[')):
        try:return forbidden(json.loads(v))
        except ValueError:return True
    return False

def validate(directory,family,profile,rid,session,release,catalog_digest,repo,sidecar):
    d=Path(directory);b=load(d/'before.json');a=load(d/'after.json');bc=load(d/'capture-before.json');ac=load(d/'capture-after.json')
    need(b.get('requests_in_flight')==a.get('requests_in_flight')==0,'overlapping active request')
    need(a['requests_total']-b['requests_total']==1 and a['errors_total']==b['errors_total'],'exclusive successful completion not proven')
    for doc in (b,a):
        need(doc['model']=='zai-org/glm-5.3-flash' and doc['safety_telemetry']['coordinator_session_id']==session and doc['catalog']['release_id']==release and doc['catalog']['digest']==catalog_digest,'provider identity drift')
        need(doc['continuous_batching']['active'] is True and doc['native_mtp']['enabled'] is True,'CB/native serving lost')
    n0=b['native_mtp'];n1=a['native_mtp']
    need(n0['reset_generation']==n1['reset_generation'] and n1['requests_since_reset']-n0['requests_since_reset']==1 and n1['mtp_forwards']>n0['mtp_forwards'],'actual native admission/round absent')
    need(n0['preoutput_fallbacks']==n1['preoutput_fallbacks'] and n0['postoutput_failures']==n1['postoutput_failures'],'native fallback/failure')
    need(a['continuous_batching']['scheduler']['shared_forward_calls']>b['continuous_batching']['scheduler']['shared_forward_calls'],'CB forwards absent')
    need(isinstance(bc.get('custody_sha256'),str) and re.fullmatch('[0-9a-f]{64}',bc['custody_sha256']) and bc['custody_sha256']==ac.get('custody_sha256'),'signed provider capture custody changed')
    need(bc['header_sha256']==ac['header_sha256'] and bc['file_identity']==ac['file_identity'] and ac['prefix_sha256']==bc['sha256'],'capture custody changed')
    need(ac['status']['successful_records']==bc['status']['successful_records']+1 and ac['status']['attempts']==bc['status']['attempts']+1 and len(ac['rows'])==1,'capture interval not singular')
    row=ac['rows'][0]
    sys.path.insert(0,str(Path(repo)/'scripts'))
    import native_mtp_journey_evidence as journey
    sidecar_bytes=Path(sidecar).read_bytes();sidecar_doc=json.loads(sidecar_bytes)
    indexes=[i for i,e in enumerate(sidecar_doc['entries']) if e.get('model_key')=='zai-org/glm-5.3-flash']
    need(len(indexes)==1,'unique signed GLM profile required')
    entry,tuple_sha=journey.validated_sidecar_entry(sidecar_bytes,indexes[0])
    need(entry['request_feature_profile']=='native_mtp_sampled_text_v1' and row.get('native_mtp_tuple_sha256')==tuple_sha,'actual signed sampled tuple differs')
    need(ac['header']['build_source_commit']==entry['source_commit'] and ac['header']['build_cdhash']==entry['live_executable_cdhash'],'actual capture build differs from signed candidate')
    need(row.get('served_model_hash_sha256')==entry['artifact_hash'] and isinstance(row.get('served_weights_manifest_sha256'),str) and re.fullmatch('[0-9a-f]{64}',row['served_weights_manifest_sha256']),'actual captured artifacts differ')
    need(row.get('observed_effective_path')=='native_mtp' and row.get('observed_selector_eligible') is True and row.get('observed_selector_reason')=='eligible','actual captured native selection absent')
    need(row.get('served_model_family')=='glm5_next_mtp_v1' and row.get('native_mtp_tuple_sha256') not in (None,'none') and row.get('unknown_request_fields_present') is False and row.get('conversation_key_present') is False,'unexpected captured request controls')
    need(row.get('sampling_requested') is (profile in ('sampled','tools')) and row.get('requested_temperature')==(1 if profile in ('sampled','tools') else 0) and row.get('requested_top_p')==(.95 if profile in ('sampled','tools') else 1),'sampled controls changed')
    need(row.get('tool_count')==(1 if profile in ('tools','history') else 0) and row.get('tool_turn_state_present') is (profile=='history'),'tools/history controls changed')
    need(row.get('stream') is False and row.get('effective_max_output_tokens')==(256 if profile=='tools' else 64),'bounded nonstream proof controls differ')
    if profile in ('tools','history'):need(row.get('tool_choice_kind')=='auto' and row.get('tool_grammar_required') is False and row.get('parallel_tool_calls_state') in ('true','absent'),'tool controls became forced or constrained')
    if profile=='history':need(row.get('tool_message_count')==1 and row.get('assistant_tool_call_count')==1,'normalized tool history incomplete')
    if profile in ('history','reasoning'):need(row.get('effective_reasoning_effort') in ('medium','high'),'reasoning disabled')
    rows=load(d/'routes.json');need(len(rows)==1,'DB provider interval not singular');route=rows[0]
    need(route.get('external_request_id')==rid and route.get('provider_assigned_id')==session and route.get('status')==200 and route.get('retried')==0,'actual routed request differs')
    need(route.get('prompt_tokens')==row.get('prompt_tokens') and route.get('completion_tokens')==row.get('completion_tokens') and row.get('completion_tokens',0)>0,'capture/actual route tokens differ')
    ledger=load(d/'ledger.json');verdict=load(d/'verdict.json')
    need(len(ledger)==len(verdict)==1,'actual settlement rows absent/ambiguous')
    need(not forbidden([rows,ledger,verdict]),'internal native fields entered billing/receipt rows')
    l=ledger[0];v=verdict[0]
    need(l['request_id']==v['request_id']==route['request_id'] and l.get('status')==200 and l.get('settled')==1 and l.get('quarantined')==0 and l.get('gross_credits',-1)>=0 and l.get('provider_credits',-1)>=0,'actual ledger not normally settled')
    need(v.get('closed')==1 and v.get('receipt_present')==1 and v.get('receipt_result')=='valid' and v.get('settlement_outcome')=='verified','actual receipt verification/settlement absent')
    body=load(d/'proof.json');usage=body.get('usage',{})
    calls=[]
    if family=='chat':calls=[x.get('function',{}) for x in body.get('choices',[{}])[0].get('message',{}).get('tool_calls',[])]
    elif family=='responses':calls=[x for x in body.get('output',[]) if x.get('type')=='function_call']
    else:calls=[dict(name=x.get('name'),arguments=x.get('input')) for x in body.get('content',[]) if x.get('type')=='tool_use']
    actual_call=False
    for call in calls:
        if call.get('name')!='read_file':continue
        args=call.get('arguments')
        if isinstance(args,str):
            try:args=json.loads(args)
            except ValueError:continue
        if isinstance(args,dict) and args.get('path')=='example.swift':actual_call=True
    if profile=='tools':need(actual_call,'auto tool-call output absent')
    prompt=usage.get('prompt_tokens',usage.get('input_tokens'));completion=usage.get('completion_tokens',usage.get('output_tokens'))
    need(prompt==route['prompt_tokens']==l.get('prompt_tokens') and completion==route['completion_tokens']==l.get('completion_tokens'),'buyer usage/billing differ')
    return dict(family=family,profile=profile,path=PATHS[family],actual_tool_call=actual_call,seed_forwarded=family=='chat',request_id=rid,served_session_sha256=digest(session.encode()),capture_header_sha256=bc['header_sha256'],capture_record_sha256=digest(json.dumps(row,sort_keys=True,separators=(',',':')).encode()),native_tuple_sha256=row['native_mtp_tuple_sha256'],request_log_sha256=digest(json.dumps(rows,sort_keys=True).encode()),settlement_rows_sha256=digest(json.dumps([ledger,verdict],sort_keys=True).encode()),native_admission_delta=1,cb_shared_forward_calls_delta=a['continuous_batching']['scheduler']['shared_forward_calls']-b['continuous_batching']['scheduler']['shared_forward_calls'],mtp_forwards_delta=n1['mtp_forwards']-n0['mtp_forwards'],requests_total_delta=1,actual_native_capture=True,settled=True,no_internal_native_billing_fields=True)

if __name__=='__main__':
    action=sys.argv[1]
    if action=='shape':emit(shape(*sys.argv[2:]))
    elif action=='capture':
        bound=capture_custody(sys.argv[2],sys.argv[5],sys.argv[6]);value=capture(sys.argv[2],int(sys.argv[3]),int(sys.argv[4]));need(value['header_sha256']==bound['header_sha256'] and value['file_identity']==bound['file_identity'],'capture changed during process binding');value['custody_sha256']=bound['custody_sha256'];emit(value)
    elif action=='validate':emit(validate(*sys.argv[2:]))
    elif action=='marker':
        m=load(sys.argv[2]);need(m.get('expanded_request_mix')=='glm53-expanded-v1','expanded mix marker missing')
        cells=m.get('expanded_cells',[]);need(len(cells)==12 and {(c['family'],c['profile']) for c in cells}=={(f,p) for f in FAMILIES for p in PROFILES},'expanded mix incomplete')
        need(all(c.get('actual_native_capture') is True and c.get('settled') is True and c.get('no_internal_native_billing_fields') is True and c.get('native_admission_delta')==1 and c.get('requests_total_delta')==1 and c.get('mtp_forwards_delta',0)>0 and c.get('cb_shared_forward_calls_delta',0)>0 and (c.get('profile')!='tools' or c.get('actual_tool_call') is True) for c in cells),'expanded mix unproven')
        need(len({c['request_id'] for c in cells})==12 and len({c['served_session_sha256'] for c in cells})==1 and len({c['native_tuple_sha256'] for c in cells})==1,'expanded custody identity differs')
    else:raise ValueError('unknown closed proof operation')
PYEXPANDED
}

# Expanded signed GLM eligibility always receives the closed live proof mix.
# No arbitrary endpoint/body is accepted and no provider serving mode changes.
gateway_expanded_required() {
  case "${PROBE_MODEL:-zai-org/glm-5.3-flash}" in zai-org/glm-5.3-flash) ;; *) return 1 ;; esac
  python3 - "$CATALOG_TARGET_DIR/native-mtp-admission.json" <<'PY'
import json,sys
try:
 d=json.load(open(sys.argv[1]));rows=[e for e in d['entries'] if e.get('model_key')=='zai-org/glm-5.3-flash']
 assert len(rows)==1 and rows[0]['request_feature_profile']=='native_mtp_sampled_text_v1'
except (OSError,ValueError,KeyError,AssertionError):sys.exit(1)
PY
}

gateway_expanded_python() { python3 -c "$(gateway_expanded_code)" "$@"; }

gateway_expanded_capture() {
  local quoted
  quoted="$(python3 -c 'import shlex,sys; print(shlex.quote(sys.stdin.read()))' <<< "$(gateway_expanded_code)")"
  studio_ssh "python3 -c $quoted capture '$CATALOG_NATIVE_MTP_CAPTURE_FILE' '$2' '$3' '$expanded_journal' '$expanded_journal_sha'" > "$1"
}

gateway_expanded_proof() (
  set -euo pipefail
  umask 077
  require_studio_ssh; require_pearl_ssh
  local capture="${CATALOG_NATIVE_MTP_CAPTURE_FILE:-}" pdb="${PEARL_COORDINATOR_DB:-}"
  local sqlite="${PEARL_SQLITE3:-/opt/macprovider-tools/sqlite-3.53.2/bin/sqlite3}"
  [[ "$capture" =~ ^/[A-Za-z0-9._/-]+\.jsonl$ ]] && [[ "$pdb" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$sqlite" =~ ^/[A-Za-z0-9._/-]+$ ]] || refuse "expanded proof requires bounded private capture and coordinator DB paths"
  local expanded_journal expanded_journal_sha
  [ -f "${CATALOG_SIGNED_PAIR_PLAN:-}" ] || refuse "expanded proof requires the original committed signed-pair plan"
  expanded_journal="$(json_field "$CATALOG_SIGNED_PAIR_PLAN" 'd["studio"]["journal_path"]')"
  expanded_journal_sha="$(shasum -a 256 "$CATALOG_SIGNED_PAIR_PLAN" | awk '{print $1}')"
  [[ "$expanded_journal" =~ ^/[A-Za-z0-9._/-]+$ ]] || refuse "invalid signed-pair journal path"
  [ -f "${BUYER_TOKEN_FILE:-}" ] || refuse "BUYER_TOKEN_FILE is required"
  [ "$(native_mtp_forward_requirement)" = true ] || refuse "expanded GLM proof requires native forwards"
  # This branch is a mutate step solely for the existing live-ops lock and
  # independent buyer-runner recovery. Serving/CB/native MTP remain live.
  [ "${MACPROVIDER_OPS_ENTRYPOINT:-}" = 1 ] && [ -n "${MACPROVIDER_OPS_OWNER:-}" ] || refuse "expanded proof requires catalog ops entrypoint"
  "$OPS_DIR/live-lock.sh" status > "$OPS_TMP_DIR/expanded-lock.json"
  python3 - "$OPS_TMP_DIR/expanded-lock.json" "$MACPROVIDER_OPS_OWNER" <<'PYLOCK' || refuse "expanded proof requires the owned gateway_proof live-ops lock"
import json,sys
d=json.load(open(sys.argv[1]));l=d.get('lock') or {}
assert d.get('held') is True and l.get('owner')==sys.argv[2] and l.get('purpose')=='catalog-activate:gateway_proof'
PYLOCK
  local nonce
  nonce="$(python3 -c 'import uuid;print(uuid.uuid4().hex)')" || refuse "expanded proof nonce generation failed"
  local unit="malibu-expanded-proof-$nonce" evidence_dir="$OPS_STATE_DIR/$OPS_SCOPE/expanded-gateway-attempts/$nonce"
  mkdir -p "$evidence_dir"
  chmod 700 "$evidence_dir"
  restore_expanded_runner() {
    local rc=$?
    trap - EXIT HUP INT TERM
    if ! pearl_ssh 'systemctl start malibu-buyer-runner.service && systemctl is-active --quiet malibu-buyer-runner.service'; then
      log "expanded proof runner restart unverified; independent recovery remains armed"
      exit 1
    fi
    pearl_ssh "systemctl stop '$unit.timer' '$unit.service' >/dev/null 2>&1 || true" || exit 1
    exit "$rc"
  }
  trap restore_expanded_runner EXIT
  trap 'exit 130' HUP INT TERM
  pearl_ssh "systemd-run --unit='$unit' --on-active=2100s --timer-property=AccuracySec=1s /bin/systemctl start malibu-buyer-runner.service >/dev/null && systemctl is-active --quiet '$unit.timer' && systemctl stop malibu-buyer-runner.service"
  local family profile attempt d beforeseq beforebytes lower sid release digest rid code endpoint poll validated
  local gw results="$evidence_dir/expanded-cells.jsonl"
  gw="$(gateway_url)" || refuse "expanded proof gateway resolution failed"
  [ -n "$gw" ] || refuse "GATEWAY_URL required"
  : > "$results"
  for family in chat responses messages; do
    case "$family" in chat) endpoint=/v1/chat/completions ;; responses) endpoint=/v1/responses ;; messages) endpoint=/v1/messages ;; esac
    for profile in sampled tools history reasoning; do
      validated=false
      for attempt in 1 2; do
        d="$evidence_dir/expanded-$family-$profile-$attempt"; mkdir -m 700 "$d"
        read_provider_status "$d/before.json"
        [ "$(json_field "$d/before.json" 'd["requests_in_flight"]')" = 0 ] || refuse "expanded proof waits for a naturally drained provider; no serving pause"
        sid="$(json_field "$d/before.json" 'd["safety_telemetry"]["coordinator_session_id"]')"
        [[ "$sid" =~ ^[A-Za-z0-9._-]+$ ]] || refuse "invalid private provider session"
        release="$(json_field "$d/before.json" 'd["catalog"]["release_id"]')"
        digest="$(json_field "$d/before.json" 'd["catalog"]["digest"]')"
        [ "$release" = "$R" ] || refuse "expanded proof catalog release differs"
        gateway_expanded_capture "$d/capture-before.json" -1 0
        beforeseq="$(json_field "$d/capture-before.json" 'd["status"]["successful_records"]')"
        beforebytes="$(json_field "$d/capture-before.json" 'd["bytes"]')"
        [ "$(json_field "$d/capture-before.json" 'd["status"]["successful_records"] < d["status"]["max_records"] and d["bytes"] + 32768 < d["status"]["max_bytes"]')" = true ] || refuse "capture has no bounded proof capacity; use existing guarded capture initialization before sending a buyer request"
        lower="$(pearl_ssh "'$sqlite' -readonly '$pdb' 'SELECT COALESCE(MAX(id),0) FROM request_log;'")"
        [[ "$lower" =~ ^[0-9]+$ ]] || refuse "request log lower bound unavailable"
        rid="$(python3 -c 'import uuid;print(uuid.uuid4())')"
        gateway_expanded_python shape "$family" "$profile" zai-org/glm-5.3-flash "$rid" > "$d/request.json"
        code="$(printf 'header = "Authorization: Bearer %s"\n' "$(tr -d '\r\n' < "$BUYER_TOKEN_FILE")" |
          curl -sS --noproxy '*' -m 120 --config - -D "$d/proof.headers" -o "$d/proof.json" -w '%{http_code}' \
          -H 'Content-Type: application/json' -H "X-Request-ID: $rid" --data-binary "@$d/request.json" "$gw$endpoint")" || code=000
        [ "$code" = 200 ] || refuse "expanded proof HTTP failed; private attempt retained"
        [ "$(awk -F': ' 'tolower($1)=="x-request-id"{gsub("\r","",$2);print $2}' "$d/proof.headers" | head -n1)" = "$rid" ] || refuse "expanded gateway request correlation differs"
        for poll in 1 2 3 4 5 6; do
          pearl_ssh "'$sqlite' -json -readonly '$pdb' \"SELECT * FROM request_log WHERE id > $lower AND provider_assigned_id = '$sid' ORDER BY id;\"" > "$d/routes.json"
          pearl_ssh "'$sqlite' -json -readonly '$pdb' \"SELECT l.* FROM ledger_request_credits l JOIN request_log r ON r.request_id=l.request_id WHERE r.external_request_id='$rid' ORDER BY l.id;\"" > "$d/ledger.json"
          pearl_ssh "'$sqlite' -json -readonly '$pdb' \"SELECT v.* FROM settlement_receipt_verdicts v JOIN request_log r ON r.request_id=v.request_id WHERE r.external_request_id='$rid' ORDER BY v.id;\"" > "$d/verdict.json"
          [ "$(json_field "$d/verdict.json" 'bool(d) and all(x.get("closed") == 1 for x in d)')" = true ] && break
          [ "$poll" = 6 ] || sleep 2
        done
        # Close custody after the complete DB/settlement bracket, catching other
        # arrivals that started while asynchronous accounting completed.
        read_provider_status "$d/after.json"
        gateway_expanded_capture "$d/capture-after.json" "$beforeseq" "$beforebytes"
        if gateway_expanded_python validate "$d" "$family" "$profile" "$rid" "$sid" "$release" "$digest" "$REPO_ROOT" "$CATALOG_TARGET_DIR/native-mtp-admission.json" > "$d/validated.json" 2> "$d/validation.err"; then
          cat "$d/validated.json" >> "$results"; validated=true; break
        fi
        # Only naturally absent auto tool output may be repeated. Every paid
        # failure and its real accounting/capture artifacts remain private.
        [ "$profile" = tools ] && [ "$attempt" = 1 ] && tail -n1 "$d/validation.err" | grep -q '^ValueError: auto tool-call output absent$' || refuse "expanded request actual path/settlement proof failed; private attempt retained"
      done
      [ "$validated" = true ] || refuse "bounded auto tool-call attempts exhausted"
    done
  done
  local metadata
  metadata="$(python3 - "$results" "$rid" "$release" "$digest" <<'PY'
import json,sys
rows=[json.loads(x) for x in open(sys.argv[1])]
print(json.dumps({'request_id':sys.argv[2],'sent_request_id':sys.argv[2],'served_by_canary':True,'proof_model':'zai-org/glm-5.3-flash','catalog_release_id':sys.argv[3],'catalog_digest':sys.argv[4],'native_mtp_forward_required':True,'mtp_forwards_delta':sum(x['mtp_forwards_delta'] for x in rows),'requests_total_delta':12,'cb_shared_forward_calls_delta':sum(x['cb_shared_forward_calls_delta'] for x in rows),'expanded_request_mix':'glm53-expanded-v1','expanded_cells':rows}))
PY
)"
  mark_done "$OPS_SCOPE" gateway_proof "Expanded signed GLM sampled/tools/history/reasoning: 12 provider-attributed real buyer proofs across Chat/Responses/Messages; actual native captures and settled rows verified" "$metadata"
)

gateway_proof_marker_valid() {
  local scope="$1" cb_active="$2" require_mtp="$3" expected_model="${4:-}" expected_release="${5:-}" expected_digest="${6:-}" path
  path="$(marker_path "$scope" gateway_proof)"
  [ -f "$path" ] || return 1
  [ -n "$(find "$path" -mmin -1440 2>/dev/null)" ] || return 1
  python3 - "$path" "$cb_active" "$require_mtp" "$expected_model" "$expected_release" "$expected_digest" <<'PY' || return 1
import json, pathlib, sys
path, cb_active, require_mtp, model, release, digest = sys.argv[1:7]
try:
    d = json.load(open(path))
except Exception:
    sys.exit(1)
if d.get("step") != "gateway_proof" or d.get("served_by_canary") is not True:
    sys.exit(1)
if not isinstance(d.get("request_id"), str) or not d.get("request_id"):
    sys.exit(1)
if cb_active == "true":
    delta = d.get("cb_shared_forward_calls_delta")
else:
    delta = d.get("mtp_forwards_delta")
if type(delta) is not int or delta <= 0:
    sys.exit(1)
if require_mtp == "true":
    if d.get("native_mtp_forward_required") is not True:
        sys.exit(1)
    if type(d.get("mtp_forwards_delta")) is not int or d["mtp_forwards_delta"] <= 0:
        sys.exit(1)
if model == "qwen/qwen3.6-35b-a3b":
    pending = pathlib.Path(path).parent / "qwen-gateway-proof" / "qwen-gateway-proof.pending.json"
    if pending.exists() or pending.is_symlink():
        sys.exit(1)
    if d.get("proof_model") != model or d.get("catalog_release_id") != release:
        sys.exit(1)
    if not digest or d.get("catalog_digest") != digest:
        sys.exit(1)
    value = d.get("served_session_sha256")
    if not isinstance(value, str) or len(value) != 64 or any(c not in "0123456789abcdef" for c in value):
        sys.exit(1)
PY
  if gateway_expanded_required; then
    gateway_expanded_python marker "$path" || return 1
    [ "$(json_field "$path" 'd.get("catalog_release_id")')" = "$expected_release" ] &&
      [ "$(json_field "$path" 'd.get("catalog_digest")')" = "$expected_digest" ] || return 1
  fi
}

qwen_proof_pending_path() {
  printf '%s/%s/qwen-gateway-proof/qwen-gateway-proof.pending.json' "$OPS_STATE_DIR" "$OPS_SCOPE"
}

# Persist the request identity and the exact pre-request context before curl.
# The rename and parent-directory fsync make an interrupted send discoverable.
write_qwen_proof_intent() {
  python3 -I - "$@" <<'PY'
import json, os, pathlib, sys, tempfile, uuid
path, request_id, model, release, digest, session_hash, mtp, requests, cb, shared = sys.argv[1:]
try:
    parsed = uuid.UUID(request_id)
except ValueError:
    raise SystemExit(2)
if parsed.version != 4 or str(parsed) != request_id:
    raise SystemExit(2)
if model != "qwen/qwen3.6-35b-a3b" or not release or len(digest) != 64 or len(session_hash) != 64:
    raise SystemExit(2)
if any(c not in "0123456789abcdef" for c in digest + session_hash):
    raise SystemExit(2)
doc = {
    "schema_version": "macprovider.qwen_gateway_proof_pending.v1",
    "request_id": request_id,
    "model": model,
    "catalog_release_id": release,
    "catalog_digest": digest,
    "session_sha256": session_hash,
    "before_counters": {
        "mtp_forwards": int(mtp), "requests_total": int(requests),
        "cb_active": cb == "true", "cb_shared_forward_calls": int(shared),
    },
    }
parent = pathlib.Path(path).parent
parent.mkdir(mode=0o700, parents=True, exist_ok=True)
if parent.is_symlink() or not parent.is_dir():
    raise SystemExit(3)
os.chmod(parent, 0o700)
if pathlib.Path(path).exists() or pathlib.Path(path).is_symlink():
    raise SystemExit(3)
fd, tmp = tempfile.mkstemp(prefix=".qwen-proof.", dir=parent)
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(doc, f, sort_keys=True, separators=(",", ":"))
        f.write("\n"); f.flush(); os.fsync(f.fileno())
    os.replace(tmp, path)
    dfd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
    try: os.fsync(dfd)
    finally: os.close(dfd)
finally:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
PY
}

validate_qwen_proof_intent() {
  python3 -I - "$@" <<'PY'
import json, pathlib, sys, uuid
path, model, release, digest = sys.argv[1:]
try:
    p = pathlib.Path(path)
    if not p.is_file() or p.is_symlink() or p.stat().st_mode & 0o077:
        raise ValueError()
    d = json.load(open(p))
    expected_keys = {"schema_version", "request_id", "model", "catalog_release_id",
                     "catalog_digest", "session_sha256", "before_counters"}
    if set(d) != expected_keys or d["schema_version"] != "macprovider.qwen_gateway_proof_pending.v1":
        raise ValueError()
    rid = uuid.UUID(d["request_id"])
    if rid.version != 4 or str(rid) != d["request_id"]:
        raise ValueError()
    counters = d["before_counters"]
    if set(counters) != {"mtp_forwards", "requests_total", "cb_active",
                         "cb_shared_forward_calls"}:
        raise ValueError()
    if type(counters["cb_active"]) is not bool:
        raise ValueError()
    if any(type(counters[k]) is not int or counters[k] < 0 for k in
           ("mtp_forwards", "requests_total", "cb_shared_forward_calls")):
        raise ValueError()
    if d["model"] != model or d["catalog_release_id"] != release or d["catalog_digest"] != digest:
        raise ValueError()
    session_hash = d["session_sha256"]
    if not isinstance(session_hash, str) or len(session_hash) != 64 or any(
            c not in "0123456789abcdef" for c in session_hash):
        raise ValueError()
except Exception:
    raise SystemExit(3)
print(d["request_id"], session_hash)
PY
}

resolve_qwen_proof_intent() {
  python3 -I - "$@" <<'PY'
import json, os, pathlib, sys, tempfile, uuid
path, status = sys.argv[1:]
allowed = {"accepted_missing_counter_evidence", "wrong_provider", "request_log_missing",
           "accepted_with_counter_evidence"}
if status not in allowed:
    raise SystemExit(2)
p = pathlib.Path(path); parent = p.parent
try:
    if not p.is_file() or p.is_symlink() or p.stat().st_mode & 0o077:
        raise ValueError()
    intent = json.load(open(p))
    if set(intent) != {"schema_version", "request_id", "model", "catalog_release_id",
                       "catalog_digest", "session_sha256", "before_counters"}:
        raise ValueError()
    if intent["schema_version"] != "macprovider.qwen_gateway_proof_pending.v1":
        raise ValueError()
except Exception: raise SystemExit(3)
rid = intent.get("request_id", "")
try:
    parsed = uuid.UUID(rid)
    if parsed.version != 4 or str(parsed) != rid:
        raise ValueError()
except Exception:
    raise SystemExit(3)
archive_dir = parent / "qwen-gateway-proof-attempts"
archive_dir.mkdir(mode=0o700, exist_ok=True)
if archive_dir.is_symlink() or not archive_dir.is_dir():
    raise SystemExit(3)
os.chmod(archive_dir, 0o700)
archive = archive_dir / (rid + ".json")
doc = {"schema_version": "macprovider.qwen_gateway_proof_resolution.v1",
       "resolution": status, "intent": intent}
payload = json.dumps(doc, sort_keys=True, separators=(",", ":")) + "\n"
if archive.exists():
    try:
        existing = json.load(open(archive))
    except Exception:
        raise SystemExit(3)
    if (archive.is_symlink() or not archive.is_file() or archive.stat().st_mode & 0o077
            or set(existing) != {"schema_version", "resolution", "intent"}
            or existing["schema_version"] != "macprovider.qwen_gateway_proof_resolution.v1"
            or existing["resolution"] not in allowed or existing["intent"] != intent):
        raise SystemExit(3)
else:
    fd, tmp = tempfile.mkstemp(prefix=".attempt.", dir=archive_dir)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(payload); f.flush(); os.fsync(f.fileno())
        os.replace(tmp, archive)
        dfd = os.open(archive_dir, os.O_RDONLY | os.O_DIRECTORY)
        try: os.fsync(dfd)
        finally: os.close(dfd)
    finally:
        try: os.unlink(tmp)
        except FileNotFoundError: pass
p.unlink()
dfd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
try: os.fsync(dfd)
finally: os.close(dfd)
PY
}

discard_file_durably() {
  python3 -I - "$1" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1])
try: p.unlink()
except FileNotFoundError: pass
dfd = os.open(p.parent, os.O_RDONLY | os.O_DIRECTORY)
try: os.fsync(dfd)
finally: os.close(dfd)
PY
}

fsync_file_and_parent() {
  python3 -I - "$1" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.is_symlink() or not p.is_file():
    raise SystemExit(3)
fd = os.open(p, os.O_RDONLY)
try: os.fsync(fd)
finally: os.close(fd)
dfd = os.open(p.parent, os.O_RDONLY | os.O_DIRECTORY)
try: os.fsync(dfd)
finally: os.close(dfd)
PY
}

qwen_marker_matches_pending() {
  python3 -I - "$1" "$2" <<'PY'
import json, os, pathlib, stat, sys
pending, marker = map(pathlib.Path, sys.argv[1:])
try:
 pstat=marker.lstat()
 if marker.is_symlink() or not stat.S_ISREG(pstat.st_mode) or pstat.st_uid!=os.getuid() or pstat.st_nlink!=1 or pstat.st_mode & 0o022: raise ValueError()
 i=json.load(open(pending)); m=json.load(open(marker))
 if m.get("step")!="gateway_proof" or m.get("request_id")!=i["request_id"] or m.get("sent_request_id")!=i["request_id"]: raise ValueError()
 if m.get("proof_model")!=i["model"] or m.get("catalog_release_id")!=i["catalog_release_id"] or m.get("catalog_digest")!=i["catalog_digest"]: raise ValueError()
 if m.get("served_session_sha256")!=i["session_sha256"] or m.get("served_by_canary") is not True: raise ValueError()
 if m.get("native_mtp_forward_required") is not True or type(m.get("mtp_forwards_delta")) is not int or m["mtp_forwards_delta"]<=0: raise ValueError()
 if type(m.get("cb_shared_forward_calls_delta")) is not int or m["cb_shared_forward_calls_delta"]<=0: raise ValueError()
except Exception: raise SystemExit(3)
PY
}

qwen_resolution_status() {
  python3 -I - "$1" "$2" <<'PY'
import json, pathlib, sys
pending, archive = map(pathlib.Path, sys.argv[1:])
try:
 i=json.load(open(pending)); a=json.load(open(archive))
 allowed={"accepted_missing_counter_evidence","wrong_provider","request_log_missing","accepted_with_counter_evidence"}
 if set(a)!={"schema_version","resolution","intent"} or a["schema_version"]!="macprovider.qwen_gateway_proof_resolution.v1": raise ValueError()
 if a["resolution"] not in allowed or a["intent"]!=i: raise ValueError()
except Exception: raise SystemExit(3)
print(a["resolution"])
PY
}

reconcile_qwen_proof_intent() {
  local pending="$1" model="$2" release="$3" digest="$4" pdb="$5" psqlite="$6"
  local rid session_hash served_sid="" k status validated marker archive
  validated="$(validate_qwen_proof_intent "$pending" "$model" "$release" "$digest")" ||
    refuse "pending Qwen proof intent is malformed or does not match the current provider context"
  read -r rid session_hash <<< "$validated"
  marker="$(marker_path "$OPS_SCOPE" gateway_proof)"
  archive="$(dirname "$pending")/qwen-gateway-proof-attempts/$rid.json"
  if [ -e "$archive" ] || [ -L "$archive" ]; then
    status="$(qwen_resolution_status "$pending" "$archive")" ||
      refuse "pending Qwen proof has a malformed terminal resolution"
    if [ "$status" = accepted_with_counter_evidence ]; then
      qwen_marker_matches_pending "$pending" "$marker" ||
        refuse "accepted Qwen proof resolution lacks its exact durable success marker"
      resolve_qwen_proof_intent "$pending" "$status" || refuse "accepted Qwen proof pending state could not be cleared"
      printf '%s\n' recovered_success
      return
    fi
    if [ -e "$marker" ] || [ -L "$marker" ]; then
      refuse "non-success Qwen proof resolution conflicts with a success marker"
    fi
    resolve_qwen_proof_intent "$pending" "$status" || refuse "Qwen proof pending state could not be cleared"
    printf '%s\n' fresh_allowed
    return
  fi
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    qwen_marker_matches_pending "$pending" "$marker" ||
      refuse "pending Qwen proof conflicts with a mismatched success marker"
    resolve_qwen_proof_intent "$pending" accepted_with_counter_evidence ||
      refuse "recovered successful Qwen proof could not be durably resolved"
    printf '%s\n' recovered_success
    return
  fi
  for k in 1 2 3 4 5 6; do
    served_sid="$(pearl_ssh "'$psqlite' -readonly '$pdb' \"SELECT provider_assigned_id FROM request_log WHERE external_request_id = '$rid' ORDER BY id DESC LIMIT 1;\"" 2>/dev/null)" ||
      refuse "pending Qwen proof request_log reconciliation failed"
    served_sid="$(printf '%s' "$served_sid" | tr -d '\r\n')"
    [ -n "$served_sid" ] && break
    [ "$k" -lt 6 ] && sleep "${PROOF_POLL_SECONDS:-2}"
  done
  if [ -z "$served_sid" ]; then
    status=request_log_missing
  elif [ "$(printf '%s' "$served_sid" | /usr/bin/shasum -a 256 | awk '{print $1}')" = "$session_hash" ]; then
    status=accepted_missing_counter_evidence
  else
    status=wrong_provider
  fi
  resolve_qwen_proof_intent "$pending" "$status" ||
    refuse "pending Qwen proof resolution could not be persisted"
  printf '%s\n' fresh_allowed
}

# proof_moved B_MTP B_REQ B_CB B_SHARED A_MTP A_REQ A_CB A_SHARED [A_SERIAL]: the
# request moved the provider on the active serving path. Continuous batching must
# prove scheduler admission/completion through shared_forward_calls; generic
# requests_total movement can be satisfied by a serial request and is not enough.
# A provider with neither CB active nor native MTP enabled (A_SERIAL=true) has
# only the serial path, so requests_total is its serving-path counter.
proof_moved() {
  if [ "$3" = true ] || [ "$7" = true ]; then
    [ "$3" = true ] && [ "$7" = true ] && [ $(($8 - $4)) -gt 0 ]
  elif [ "${9:-false}" = true ]; then
    [ $(($6 - $2)) -gt 0 ]
  else
    [ $(($5 - $1)) -gt 0 ]
  fi
}

# One bounded buyer request through the gateway, tied to the target provider:
# its native_mtp.mtp_forwards (or, with continuous batching active, its
# continuous_batching.scheduler.shared_forward_calls) must increase across the request, the response must carry
# a request id, and the coordinator request_log row for that request id (read
# on Pearl, read-only) must name the coordinator session the canary reports in
# /v1/status, so other traffic on the provider cannot satisfy the proof. Buyers
# never receive provider identity (SPEC-006 5.4, #1991), so the gateway
# response carries no attribution. Prints status, request id and counter
# deltas only; the session id itself is never printed.
gateway_proof() {
  if gateway_expanded_required; then gateway_expanded_proof; return; fi
  local gw model token_file require_mtp
  gw="$(gateway_url)"
  [ -n "$gw" ] || refuse "GATEWAY_URL is unset"
  token_file="${BUYER_TOKEN_FILE:-}"
  [ -n "$token_file" ] && [ -f "$token_file" ] || refuse "BUYER_TOKEN_FILE must name a readable buyer token file"
  require_mtp="$(native_mtp_forward_requirement)"
  require_studio_ssh
  case "${STUDIO_STATUS_PORT:-}" in ""|*[!0-9]*) refuse "STUDIO_STATUS_PORT must be set and numeric" ;; esac

  local before after b_mtp b_req b_cb b_shared a_mtp a_req a_cb a_shared a_serial
  read_provider_status "$OPS_TMP_DIR/before.json"
  # The model the canary serves, as its /v1/status reports it: a request for
  # any other model cannot reach the canary (the gateway 404s a model no
  # provider serves). PROBE_MODEL overrides it.
  model="${PROBE_MODEL:-$(json_field "$OPS_TMP_DIR/before.json" 'd["model"]')}"
  [ -n "$model" ] || refuse "PROBE_MODEL is unset and the canary /v1/status reports no served model"
  if [ "$model" = "$QWEN_NATIVE_MODEL" ]; then
    require_qwen_proof_lock
    [ "$(json_field "$OPS_TMP_DIR/before.json" 'd["model"]')" = "$QWEN_NATIVE_MODEL" ] ||
      refuse "Qwen3.6 proof requires the target provider to serve the exact model"
    [ "$(json_field "$OPS_TMP_DIR/before.json" 'd["native_mtp"]["enabled"]')" = true ] &&
      case "$(json_field "$OPS_TMP_DIR/before.json" 'd["native_mtp"]["mode"]')" in eligible|active) : ;; *) false ;; esac &&
      [ "$(json_field "$OPS_TMP_DIR/before.json" 'd["continuous_batching"]["active"]')" = true ] ||
      refuse "Qwen3.6 proof requires native MTP eligible or active and continuous batching active"
  fi
  before="$(provider_counters "$OPS_TMP_DIR/before.json")" || refuse "provider status lacks native_mtp.mtp_forwards/requests_total or continuous_batching.scheduler.shared_forward_calls"
  read -r b_mtp b_req b_cb b_shared _ <<< "$before"
  local canary_sid canary_sid_hash catalog_release catalog_digest pdb psqlite pending=""
  canary_sid="$(json_field "$OPS_TMP_DIR/before.json" 'd["safety_telemetry"]["coordinator_session_id"]')"
  [ -n "$canary_sid" ] || refuse "provider /v1/status reports no safety_telemetry.coordinator_session_id; cannot tie the proof to it"
  canary_sid_hash="$(printf '%s' "$canary_sid" | /usr/bin/shasum -a 256 | awk '{print $1}')"
  catalog_release="$(json_field "$OPS_TMP_DIR/before.json" 'd["catalog"]["release_id"]')"
  catalog_digest="$(json_field "$OPS_TMP_DIR/before.json" 'd["catalog"]["digest"]')"
  pdb="${PEARL_COORDINATOR_DB:-}"
  psqlite="${PEARL_SQLITE3:-/opt/macprovider-tools/sqlite-3.53.2/bin/sqlite3}"
  [ -n "$pdb" ] || refuse "PEARL_COORDINATOR_DB must name the coordinator database on Pearl to attribute the proof request"
  [[ "$pdb" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$psqlite" =~ ^/[A-Za-z0-9._/-]+$ ]] ||
    refuse "PEARL_COORDINATOR_DB and PEARL_SQLITE3 must be absolute plain paths"
  require_pearl_ssh

  if [ "$model" = "$QWEN_NATIVE_MODEL" ]; then
    pending="$(qwen_proof_pending_path)"
    if [ -e "$pending" ] || [ -L "$pending" ]; then
      local reconcile_outcome
      reconcile_outcome="$(reconcile_qwen_proof_intent "$pending" "$model" "$catalog_release" \
        "$catalog_digest" "$pdb" "$psqlite")"
      [ "$reconcile_outcome" != recovered_success ] || return 0
    fi
  fi

  local body="$OPS_TMP_DIR/proof.json" headers="$OPS_TMP_DIR/proof.headers" code sent_rid payload
  sent_rid="$(python3 -c 'import uuid; print(uuid.uuid4())')"
  # Include the generated request id in the prompt so this proof cannot be
  # answered from an earlier identical-prompt cache entry. It remains an opaque
  # buyer request nonce and reveals no provider attribution.
  # Greedy-only native tuples reject the API's default temperature of 1.0.
  payload="$(python3 -c 'import json,sys; print(json.dumps({"model": sys.argv[1], "max_tokens": 32, "temperature": 0, "top_p": 1, "messages": [{"role": "user", "content": "Proof nonce " + sys.argv[2] + ". Reply with the word ok."}]}))' "$model" "$sent_rid")"
  if [ "$model" = "$QWEN_NATIVE_MODEL" ]; then
    write_qwen_proof_intent "$pending" "$sent_rid" "$model" "$catalog_release" "$catalog_digest" \
      "$canary_sid_hash" "$b_mtp" "$b_req" "$b_cb" "$b_shared" ||
      refuse "could not durably persist the pending Qwen proof intent"
  fi
  # The bearer goes through curl --config on stdin, never argv.
  code="$(printf 'header = "Authorization: Bearer %s"\n' "$(tr -d '\r\n' < "$token_file")" |
    curl -sS -m 120 --config - -D "$headers" -o "$body" -w '%{http_code}' \
      -H 'Content-Type: application/json' -H "X-Request-ID: $sent_rid" \
      -d "$payload" "$gw/v1/chat/completions")" || code=000
  local rid
  rid="$(awk -F': ' 'tolower($1)=="x-request-id"{gsub("\r","",$2); print $2}' "$headers" | head -n1)"
  [ "$code" = "200" ] || die "gateway returned HTTP $code for $model (request id ${rid:-none})"
  [ -n "$rid" ] || die "gateway response carries no X-Request-ID"
  [[ "$rid" =~ ^[A-Za-z0-9._-]+$ ]] || die "gateway request id has unexpected characters"
  [ "$rid" = "$sent_rid" ] || die "gateway response request id does not match the sent request id"
  local served_sid="" k
  for k in 1 2 3 4 5 6; do
    served_sid="$(pearl_ssh "'$psqlite' -readonly '$pdb' \"SELECT provider_assigned_id FROM request_log WHERE external_request_id = '$rid' ORDER BY id DESC LIMIT 1;\"" 2>/dev/null)" ||
      die "request_log read failed over PEARL_SSH (request $rid)"
    served_sid="$(printf '%s' "$served_sid" | tr -d '\r\n')"
    [ -n "$served_sid" ] && break
    [ "$k" -lt 6 ] && sleep "${PROOF_POLL_SECONDS:-2}"
  done
  [ -n "$served_sid" ] || die "coordinator request_log has no row for request $rid"
  [ "$served_sid" = "$canary_sid" ] || die "request $rid was served by another provider, not the canary"
  # Reasoning models can spend the whole 32-token budget in reasoning_content.
  [ -n "$(json_field "$body" '(d["choices"][0]["message"].get("content") or "") + (d["choices"][0]["message"].get("reasoning_content") or "")')" ] || die "gateway 200 without completion content"

  local i
  for i in 1 2 3 4 5 6; do
    read_provider_status "$OPS_TMP_DIR/after.json"
    after="$(provider_counters "$OPS_TMP_DIR/after.json")" || refuse "provider status lacks counters after the request"
    read -r a_mtp a_req a_cb a_shared a_serial <<< "$after"
    proof_moved "$b_mtp" "$b_req" "$b_cb" "$b_shared" "$a_mtp" "$a_req" "$a_cb" "$a_shared" "$a_serial" && break
    [ "$i" -lt 6 ] && sleep "${PROOF_POLL_SECONDS:-2}"
  done
  proof_moved "$b_mtp" "$b_req" "$b_cb" "$b_shared" "$a_mtp" "$a_req" "$a_cb" "$a_shared" "$a_serial" ||
    die "request $rid did not move the target provider on its active serving path: mtp_forwards +$((a_mtp - b_mtp)), requests_total +$((a_req - b_req)), cb_shared_forward_calls +$((a_shared - b_shared)) (cb_active=$a_cb serial=$a_serial)"
  if [ "$require_mtp" = true ] && [ $((a_mtp - b_mtp)) -le 0 ]; then
    die "request $rid did not increase native_mtp.mtp_forwards as required: mtp_forwards +$((a_mtp - b_mtp))"
  fi
  local evidence="HTTP 200 model=$model request_id=$rid served_by=canary mtp_forwards+$((a_mtp - b_mtp)) requests_total+$((a_req - b_req)) cb_shared_forward_calls+$((a_shared - b_shared)) cb_active=$a_cb serial=$a_serial"
  log "gateway proof: $evidence"
  mark_done "$OPS_SCOPE" gateway_proof "$evidence" \
    "$(python3 -c 'import json,sys; import hashlib; print(json.dumps({"request_id": sys.argv[1], "sent_request_id": sys.argv[2], "mtp_forwards_delta": int(sys.argv[3]), "requests_total_delta": int(sys.argv[4]), "cb_shared_forward_calls_delta": int(sys.argv[5]), "native_mtp_forward_required": sys.argv[6] == "true", "served_by_canary": True, "served_session_sha256": hashlib.sha256(sys.argv[7].encode()).hexdigest(), "proof_model": sys.argv[8], "catalog_release_id": sys.argv[9], "catalog_digest": sys.argv[10]}))' "$rid" "$sent_rid" "$((a_mtp - b_mtp))" "$((a_req - b_req))" "$((a_shared - b_shared))" "$require_mtp" "$served_sid" "$model" "$catalog_release" "$catalog_digest")"
  if [ "$model" = "$QWEN_NATIVE_MODEL" ]; then
    fsync_file_and_parent "$(marker_path "$OPS_SCOPE" gateway_proof)" ||
      refuse "successful Qwen proof marker could not be made durable"
    if ! resolve_qwen_proof_intent "$pending" accepted_with_counter_evidence; then
      discard_file_durably "$(marker_path "$OPS_SCOPE" gateway_proof)" ||
        refuse "Qwen proof intent resolution failed and its success marker could not be discarded"
      refuse "successful Qwen proof intent could not be durably resolved"
    fi
  fi
}

# pearl_buc_layout: the Pearl layout flags of lib/pearl-cli-config.py for the
# buyer-UX conformance step (BUC_LAYOUT). Every value reaches a remote shell.
pearl_buc_layout() {
  local a guard_sha
  for a in "$PEARL_COORDINATOR_CONFIG" "$PEARL_COORDINATOR_OVERLAY" "$PEARL_COORDINATOR_UNIT" "$PEARL_INSTALL_ROOT" \
    "$PEARL_CONFIG_GUARD" "$PEARL_UPDATER_LOCK" "$PEARL_BACKUP_ROOT" "$PEARL_COORDINATOR_HEALTHZ_URL" "$PEARL_PROC_ROOT" \
    "$PEARL_BUYER_UX_CONFORMANCE_PATH"; do
    [[ "$a" =~ ^[A-Za-z0-9_./:@+=-]+$ ]] || die "unsafe argument for the Pearl config helper: $a"
  done
  [[ "$PEARL_BUYER_UX_CONFORMANCE_PATH" =~ ^/[A-Za-z0-9._/-]+$ ]] ||
    die "PEARL_BUYER_UX_CONFORMANCE_PATH must be an absolute plain path"
  # The root helper polls it during the reload or restart: Pearl's loopback only.
  [[ "$PEARL_COORDINATOR_HEALTHZ_URL" =~ ^http://(127\.0\.0\.1|\[::1\]|localhost):[0-9]+/[A-Za-z0-9._/-]*$ ]] ||
    die "PEARL_COORDINATOR_HEALTHZ_URL must be an http://127.0.0.1:PORT/ URL (Pearl's loopback)"
  guard_sha="$(shasum -a 256 "$REPO_ROOT/scripts/lib/coordinator_config_guard.py" | awk '{print $1}')"
  BUC_LAYOUT="--config $PEARL_COORDINATOR_CONFIG --overlay $PEARL_COORDINATOR_OVERLAY --unit $PEARL_COORDINATOR_UNIT \
--install-root $PEARL_INSTALL_ROOT --guard $PEARL_CONFIG_GUARD --guard-sha256 $guard_sha \
--updater-lock $PEARL_UPDATER_LOCK --backup-root $PEARL_BACKUP_ROOT --healthz $PEARL_COORDINATOR_HEALTHZ_URL \
--proc $PEARL_PROC_ROOT --buc-path $PEARL_BUYER_UX_CONFORMANCE_PATH"
}

# gather_buyer_ux_conformance: step 4a. The committed record file is the one
# that must be in force; it does not depend on the catalog release.
gather_buyer_ux_conformance() {
  local sha="" live="" reloads="" loaded="" facts="$OPS_TMP_DIR/buc-facts.json" models="" masked="" live_models=""
  BUC_OWED_JSON="$OPS_TMP_DIR/buc-owed.json"
  : > "$BUC_OWED_JSON"
  [ -f "$REPO_ROOT/$BUC_FILE" ] && sha="$(shasum -a 256 "$REPO_ROOT/$BUC_FILE" | awk '{print $1}')"
  if [ -s "$OPS_TMP_DIR/healthz.json" ]; then
    reloads="$(json_field "$OPS_TMP_DIR/healthz.json" 'd.get("buyer_ux_conformance_reloads") is True')"
    live="$(json_field "$OPS_TMP_DIR/healthz.json" 'd.get("buyer_ux_conformance_sha256") or ""')"
    live_models="$(json_field "$OPS_TMP_DIR/healthz.json" 'd.get("buyer_ux_conformance_records", "")')"
  fi
  fact buyer_ux_conformance_committed_sha256 "$sha"
  fact buyer_ux_conformance_live_sha256 "$live"
  fact buyer_ux_conformance_reloads "$reloads"
  if [ -z "$sha" ]; then
    step buyer_ux_conformance "done" "no committed record file"
    return
  fi
  if ! python3 -I "$REPO_ROOT/scripts/buyer_ux_conformance.py" owed-status --record "$REPO_ROOT/$BUC_FILE" \
       > "$BUC_OWED_JSON" 2>"$BUC_OWED_JSON.err"; then
    : > "$BUC_OWED_JSON"
    step buyer_ux_conformance blocked "the committed record file is invalid"
    set_next buyer_ux_conformance blocked "Fix the committed buyer-UX conformance record file" \
      "python3 scripts/buyer_ux_conformance.py owed-status" "$(tail -n 1 "$BUC_OWED_JSON.err" | cut -c1-200)"
    return
  fi
  models="$(json_field "$BUC_OWED_JSON" 'd["models"]')"
  masked="$(json_field "$BUC_OWED_JSON" 'd["masked"]')"
  fact buyer_ux_conformance_masked_models "$masked"
  fact buyer_ux_conformance_live_models "$live_models"
  if [ -z "$reloads" ]; then
    step buyer_ux_conformance unknown "coordinator /healthz unreadable"
    set_next buyer_ux_conformance blocked "Install the buyer-UX conformance records" "" \
      "coordinator /healthz is unreadable (COORDINATOR_URL)"
    return
  fi
  # SPEC-023 §16.11 rule 4: owed entries mask a promoted model to the base set.
  # A runtime that applies them counts each masked model in
  # buyer_ux_conformance_records; one that ignores them (every runtime that
  # reads the file only at start does) would advertise the derived set.
  local old_runtime="the running coordinator ignores owed conformance entries: origin/main's record file masks $masked owed model(s) to the base capability set (SPEC-023 §16.11 rule 4), and this runtime would advertise their derived capabilities. Release the coordinator runtime first"
  if [ "$masked" != 0 ] && [ "$reloads" != true ]; then
    step buyer_ux_conformance blocked "the running coordinator predates owed conformance entries"
    set_next buyer_ux_conformance blocked "Release the coordinator runtime that applies owed conformance entries" \
      "scripts/ops/pearl-runtime.sh status" "$old_runtime"
    return
  fi
  if [ "$reloads" = true ] && [ "$live" = "$sha" ]; then
    if [ "$masked" = 0 ] || [ "$live_models" = "$models" ]; then
      step buyer_ux_conformance "done" "coordinator holds records sha256 ${sha:0:12}${live_models:+ ($live_models model(s) capped, $masked owed)}"
    elif [ "$live_models" = "$((models - masked))" ]; then
      step buyer_ux_conformance blocked "the running coordinator ignores the owed entries in force"
      set_next buyer_ux_conformance blocked "Release the coordinator runtime that applies owed conformance entries" \
        "scripts/ops/pearl-runtime.sh status" "$old_runtime"
    else
      step buyer_ux_conformance blocked "coordinator caps ${live_models:-?} model(s), the committed file $models"
      set_next buyer_ux_conformance blocked "Read the coordinator's buyer-UX conformance state" "" \
        "/healthz buyer_ux_conformance_records=${live_models:-?} differs from the committed file's $models capped model(s) ($masked owed)"
    fi
    return
  fi
  if [ "$reloads" != true ]; then
    # This runtime reads the file only at start and does not report it:
    # read the install and the boot proof on Pearl (read-only).
    if [ -z "${PEARL_SSH:-}" ]; then
      step buyer_ux_conformance blocked "PEARL_SSH is unset"
      set_next buyer_ux_conformance blocked "Install the buyer-UX conformance records" "" \
        "PEARL_SSH is unset: the running coordinator predates the conformance reload, so its records are read on Pearl"
      return
    fi
    pearl_buc_layout
    if ! pearl_ssh "python3 - buc-facts $BUC_LAYOUT" < "$OPS_LIB_DIR/pearl-cli-config.py" > "$facts" 2>"$facts.err"; then
      step buyer_ux_conformance blocked "cannot read the record file state on Pearl"
      set_next buyer_ux_conformance blocked "Install the buyer-UX conformance records" "" \
        "cannot read the record file state on Pearl: $(tail -n 1 "$facts.err" | cut -c1-200)"
      return
    fi
    loaded="$(json_field "$facts" 'd.get("loaded_sha256") or ""')"
    fact buyer_ux_conformance_pearl_loaded_sha256 "$loaded"
    if [ "$loaded" = "$sha" ]; then
      step buyer_ux_conformance "done" "coordinator booted with records sha256 ${sha:0:12} (runtime reads them at start)"
      return
    fi
  fi
  step buyer_ux_conformance pending "live ${live:-${loaded:-none}} != committed $sha"
  set_next buyer_ux_conformance mutate \
    "Install the buyer-UX conformance records (sha256 ${sha:0:12}) on Pearl and $([ "$reloads" = true ] && echo "SIGHUP" || echo "restart") the coordinator" \
    "scripts/ops/catalog-activate.sh _buyer-ux-conformance $sha"
  if [ "$reloads" = true ]; then
    next_meta buyer_ux_conformance "$BUC_DOC" "$BUC_DOWNTIME_SIGHUP"
  else
    next_meta buyer_ux_conformance "$BUC_DOC" "$BUC_DOWNTIME_RESTART"
  fi
}

# _buyer-ux-conformance SHA256: stage origin/main's record file on Pearl
# (root-only, next to its target) and run lib/pearl-cli-config.py
# apply-buyer-ux-conformance under both Pearl locks (next --run only).
buc_internal() {
  [ "${MACPROVIDER_OPS_ENTRYPOINT:-}" = 1 ] ||
    refuse "_buyer-ux-conformance runs only from '$0 next --run' (live-ops lock, downtime banner)"
  require_pearl_ssh
  pearl_buc_layout
  local sha staged rc=0
  [ -f "$REPO_ROOT/$BUC_FILE" ] || refuse "$BUC_FILE is missing"
  sha="$(shasum -a 256 "$REPO_ROOT/$BUC_FILE" | awk '{print $1}')"
  [ "$sha" = "${1:-}" ] || refuse "the committed record file changed since status (sha256 ${sha:0:12}, expected ${1:-?}); run status again"
  staged="$(dirname "$PEARL_BUYER_UX_CONFORMANCE_PATH")/.buyer-ux-conformance.staging"
  pearl_ssh "set -eu; umask 077; s=$staged; rm -f -- \"\$s\"; set -o noclobber; cat > \"\$s\"" < "$REPO_ROOT/$BUC_FILE" || rc=$?
  if [ "$rc" = 0 ]; then
    pearl_ssh "python3 - apply-buyer-ux-conformance $BUC_LAYOUT --buc-staged $staged --buc-sha256 $sha" \
      < "$OPS_LIB_DIR/pearl-cli-config.py" || rc=$?
  fi
  if [ "$rc" != 0 ]; then
    pearl_ssh "rm -f -- $staged" </dev/null || log "could not remove $staged on Pearl; remove it by hand"
    return "$rc"
  fi
}

internal() {
  case "$1" in
    _signed-native-pair) shift; native_binding_context "$(origin_main_sha)" || refuse "native binding proof is invalid"; R="$(json_field "$CATALOG_TARGET_DIR/release.json" 'd["release_id"]')"; OPS_SCOPE="catalog-$R"; signed_pair_internal "$@" ;;
    _signed-native-pair-reconcile) R="$(json_field "$CATALOG_SIGNED_PAIR_PLAN" 'd["target"]["catalog_release_id"]')"; OPS_SCOPE="catalog-$R"; signed_pair_reconcile ;;
    _qwen-lock-reconcile) reconcile_qwen_restore_lock ;;
    _buyer-ux-conformance) shift; buc_internal "$@" ;;
    _gateway-proof)
      native_binding_context "$(origin_main_sha)" || refuse "native binding proof is invalid"
      R="$(json_field "$CATALOG_TARGET_DIR/release.json" 'd["release_id"]')"
      OPS_SCOPE="catalog-$R"
      gateway_proof ;;
    *) usage >&2; exit 2 ;;
  esac
}

ops_main "$@"
