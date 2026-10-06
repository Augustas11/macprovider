#!/usr/bin/env bash
# Continuous-batching activation gate in deploy-pearl-vps.sh. Pins the
# pre-activation gate (after window coverage, before the current swap and the
# restart) and the post-activation capacity check (after the catalog canary,
# before the commit marker), then runs both extracted blocks with the real
# scripts/cb_activation_gate.py against a local fake /poolz and fake Pearl.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DEPLOY_SH="$SCRIPT_DIR/../deploy-pearl-vps.sh"
TMP="$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/deploy-cb-gate-test.XXXXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

line_of() {
  local n
  n="$(grep -nF -- "$1" "$DEPLOY_SH" | head -1 | cut -d: -f1)"
  [ -n "$n" ] || fail "deploy-pearl-vps.sh lost: $1"
  printf '%s' "$n"
}

# --- Static placement pins -------------------------------------------------
coverage_line="$(line_of 'autotune_window.py coverage --admitted-json')"
gate_line="$(line_of 'cb_activation_gate.py" preflight')"
skip_line="$(line_of 'if [ "$CATALOG_VERDICT" = "equivalent" ]; then')"
swap_line="$(line_of 'mv -Tf \"\$_catalog_root/current.next\"')"
restart_line="$(line_of 'systemctl restart macprovider-coordinator')"
canary_ok_line="$(line_of 'SPEC-023 live-catalog canary OK')"
capacity_line="$(line_of 'cb_activation_gate.py" compare')"
step9_line="$(line_of 'step 9/9: tail the coordinator journal')"
commit_line="$(line_of 'touch /opt/macprovider/.coordinator-deploy-rollback/committed')"
[ "$coverage_line" -lt "$gate_line" ] || fail "the CB gate must run after window coverage"
for later in "$skip_line" "$swap_line" "$restart_line"; do
  [ "$gate_line" -lt "$later" ] || fail "the CB gate must run before the current swap and the restart"
done
[ "$canary_ok_line" -lt "$capacity_line" ] || fail "the capacity check must run after the catalog canary"
[ "$capacity_line" -lt "$step9_line" ] && [ "$capacity_line" -lt "$commit_line" ] ||
  fail "the capacity check must run before the commit marker"
grep -qx 'scripts/cb_activation_gate.py' "$REPO_ROOT/scripts/catalog-verifier-bundle.txt" ||
  fail "the gate must ship through the catalog verifier bundle"
grep -qF 'rm -rf "${CB_GATE_DIR:-}"' "$DEPLOY_SH" || fail "the EXIT trap must remove the CB gate dir"

# --- Extract the blocks ----------------------------------------------------
awk '/^# Continuous-batching activation gate: before current changes/{f=1} f{print} f&&/^esac$/{exit}' "$DEPLOY_SH" >"$TMP/gate-block.sh"
grep -q 'cb_activation_gate.py" preflight' "$TMP/gate-block.sh" || fail "could not extract the gate block"
awk '/^# Post-activation continuous-batching capacity check\./{f=1} f{print} f&&/^fi$/{exit}' "$DEPLOY_SH" >"$TMP/capacity-block.sh"
grep -q 'cb_activation_gate.py" compare' "$TMP/capacity-block.sh" || fail "could not extract the capacity block"
override_block="$(awk '/^CATALOG_CB_DEAUTHORIZE_OVERRIDE_REASON="\$\{CATALOG_CB_DEAUTHORIZE_OVERRIDE_REASON:-\}"$/{f=1} f{print} f&&/^fi$/{exit}' "$DEPLOY_SH")"
[ -n "$override_block" ] || fail "could not extract the override validation"

# --- Fixtures ----------------------------------------------------------------
python3 - "$TMP" <<'PY'
import json, sys
d = sys.argv[1]
h = lambda c: c * 64
tuple_ = {"model_id": "example/model-a", "model_sha256": h("1"), "tokenizer_sha256": h("2"),
          "chat_template_sha256": h("3"), "cache_class": "mixed", "kv_dtype": "fp16", "requires_moe": True,
          "hardware_class": "hw-a", "metallib_sha256": h("4"), "kernel_identifier": "kernel-a",
          "provider_cli_version": "1.8.300", "live_executable_cdhash": "ab" * 20}
entry = {k: v for k, v in tuple_.items() if k not in ("provider_cli_version", "live_executable_cdhash")}
entry.update({"tuple_sha256": h("9"), "model_key": tuple_["model_id"], "rollout": "canary", "cached_turns_accepted": False,
              "provenance": {"source": "release_review", "status": "qualified", "evidence_id": "e", "package_manifest_sha256": h("5"),
                             "studio_campaign_sha256": h("6"), "provider_cli_version": "1.8.300", "live_executable_cdhash": "ab" * 20}})
def policy(entries):
    return {"schema_version": "macprovider.continuous-batching-policy.v1", "release_id": "r", "policy_version": "p",
            "generated_at": "2026-01-01T00:00:00Z", "expires_at": "2099-01-01T00:00:00Z",
            "candidate_catalog_sha256": h("7"), "signer_key_id": "k", "entries": entries}
def poolz(active, free=4):
    cb = {"active": active, "mode": "canary", "authorization_source": "coordinator", "policy_authorized": active,
          "runtime_tuple": tuple_ if active else None}
    return {"pool": [{"provider_id": "provider-a", "model_id": tuple_["model_id"], "state": "ready", "routing_eligible": True,
                      "slots_free": free, "slots_total": 8, "continuous_batching": cb}],
            "summary": {"ready": 1, "continuous_batching_active": int(active), "continuous_batching_reporting": 1}}
for name, value in {"policy-auth.json": policy([entry]), "policy-empty.json": policy([]),
                    "poolz-active.json": poolz(True), "poolz-inactive.json": poolz(False)}.items():
    json.dump(value, open(f"{d}/{name}", "w"))
PY
cat >"$TMP/fake-ssh" <<'SH'
#!/usr/bin/env bash
cat "$FAKE_LIVE_POLICY"
SH
chmod +x "$TMP/fake-ssh"

run_gate() { # <incoming policy> <poolz fixture|missing> [override reason]
  (
    set -euo pipefail
    log() { printf '[deploy] %s\n' "$*"; }
    _cb_fetch_poolz() { [ -f "$POOLZ_FIXTURE" ] && cp "$POOLZ_FIXTURE" "$1"; }
    _append_catalog_window_override() { printf '%s\n' "$1" >>"$TMP/override-records"; }
    export FAKE_LIVE_POLICY="$TMP/policy-auth.json"
    SSH="$TMP/fake-ssh"
    PINNED_SCRIPTS_DIR="$REPO_ROOT/scripts"
    STATIC_CB_POLICY_JSON="$1"
    POOLZ_FIXTURE="$2"
    CATALOG_CB_DEAUTHORIZE_OVERRIDE_REASON="${3:-}"
    CATALOG_VERDICT=descends
    CATALOG_LIVE_TARGET=releases/live-a
    CATALOG_LIVE_RELEASE_ID=live-a
    AUTOTUNE_RELEASE_ID=incoming-b
    AUTOTUNE_RELEASE_DIR_NAME=incoming-b-0123
    COORDINATOR_RELEASE_VERSION=v0.0.0
    COORDINATOR_RELEASE_COMMIT=0000000000000000000000000000000000000000
    eval "$override_block"
    # shellcheck disable=SC1090
    . "$TMP/gate-block.sh"
    cp "$CB_GATE_DIR/snapshot-before.json" "$TMP/snapshot-before.json"
    printf '%s\n' "$CB_DEAUTHORIZE_ACCEPTED" >"$TMP/accepted"
    rm -rf "$CB_GATE_DIR"
  )
}

rm -f "$TMP/override-records"
run_gate "$TMP/policy-auth.json" "$TMP/poolz-active.json" >"$TMP/out" 2>&1 || fail "authorized incoming policy must pass: $(cat "$TMP/out")"
grep -q '"cb_active_ids": \["provider-a"\]' "$TMP/snapshot-before.json" || fail "baseline snapshot missing the active provider"
[ ! -e "$TMP/override-records" ] || fail "a passing gate must not log an override"

if run_gate "$TMP/policy-empty.json" "$TMP/poolz-active.json" >"$TMP/out" 2>&1; then
  fail "an empty incoming policy must refuse while a provider batches"
fi
grep -q 'would de-authorize continuous batching' "$TMP/out" || fail "refusal message missing: $(cat "$TMP/out")"

run_gate "$TMP/policy-empty.json" "$TMP/poolz-active.json" "reviewed rollback of tuple" >"$TMP/out" 2>&1 ||
  fail "override must let the activation proceed: $(cat "$TMP/out")"
[ "$(cat "$TMP/accepted")" = 1 ] || fail "override must tolerate exactly the de-authorized provider"
python3 - "$TMP/override-records" <<'PY' || fail "override record malformed"
import base64, json, sys
rec = json.loads(base64.b64decode(open(sys.argv[1]).read().strip()))
assert rec["kind"] == "continuous_batching_deauthorize", rec
assert rec["reason"] == "reviewed rollback of tuple", rec
assert rec["at_risk"][0]["kind"] == "active_tuple_deauthorized", rec
PY

if run_gate "$TMP/policy-auth.json" "$TMP/missing.json" >"$TMP/out" 2>&1; then
  fail "unreadable /poolz must fail closed"
fi
grep -q '/poolz is unreadable' "$TMP/out" || fail "fail-closed message missing: $(cat "$TMP/out")"

if run_gate "$TMP/policy-auth.json" "$TMP/poolz-active.json" $'two\nlines' >"$TMP/out" 2>&1; then
  fail "a multi-line override reason must be refused"
fi

# --- Post-activation capacity check ------------------------------------------
run_gate "$TMP/policy-auth.json" "$TMP/poolz-active.json" >/dev/null 2>&1
run_capacity() { # <after poolz fixture> <accepted drop>
  (
    set -euo pipefail
    log() { printf '[deploy] %s\n' "$*"; }
    sleep() { :; }
    _cb_fetch_poolz() { cp "$POOLZ_FIXTURE" "$1"; }
    PINNED_SCRIPTS_DIR="$REPO_ROOT/scripts"
    POOLZ_FIXTURE="$1"
    CB_DEAUTHORIZE_ACCEPTED="$2"
    CB_GATE_DIR="$TMP/capacity-dir"
    rm -rf "$CB_GATE_DIR"
    mkdir -m 0700 "$CB_GATE_DIR"
    cp "$TMP/snapshot-before.json" "$CB_GATE_DIR/snapshot-before.json"
    AUTOTUNE_RELEASE_ID=incoming-b
    CB_CAPACITY_RECOVERY_SECONDS=0
    CB_CAPACITY_MAX_FREE_SLOTS_DROP_PCT=25
    CB_CAPACITY_FREE_SLOTS_SLACK=2
    # shellcheck disable=SC1090
    . "$TMP/capacity-block.sh"
  )
}
run_capacity "$TMP/poolz-active.json" 0 >"$TMP/out" 2>&1 || fail "unchanged capacity must pass: $(cat "$TMP/out")"
grep -q 'continuous-batching capacity OK: CB-active 1 -> 1' "$TMP/out" || fail "capacity summary missing: $(cat "$TMP/out")"
if run_capacity "$TMP/poolz-inactive.json" 0 >"$TMP/out" 2>&1; then
  fail "a provider losing continuous batching after activation must fail the deploy"
fi
grep -q 'capacity dropped after activating' "$TMP/out" || fail "drop message missing: $(cat "$TMP/out")"
run_capacity "$TMP/poolz-inactive.json" 1 >"$TMP/out" 2>&1 || fail "an overridden de-authorization is the tolerated drop: $(cat "$TMP/out")"

echo "PASS: deploy continuous-batching activation gate and capacity check"
