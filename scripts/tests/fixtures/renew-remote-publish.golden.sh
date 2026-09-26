set -euo pipefail
root="$1"; incoming="$2"; final="$3"; prev="$4"; unit="$5"; helper="$6"; window="$7"; verifier="$8"
incoming_path="$root/releases/$incoming"
mutated=0
abort_pre_mutation() {
  echo "$1" >&2
  rm -rf "$incoming_path" >/dev/null 2>&1 || true
  exit 2
}
trap 'if [ "$mutated" -eq 1 ]; then exit 1; else rm -rf "$incoming_path" >/dev/null 2>&1 || true; exit 2; fi' ERR
coord_ready_pid() { # <unit>
  local deadline=$(( $(date +%s) + 900 )) state pid
  while :; do
    state="$(systemctl show -p ActiveState --value "$1" 2>/dev/null || true)"
    pid="$(systemctl show -p MainPID --value "$1" 2>/dev/null || true)"
    case "$state" in active|activating|reloading) ;; *) echo "$1 is not running (ActiveState=${state:-?})" >&2; return 1 ;; esac
    case "$pid" in ""|0|*[!0-9]*) echo "$1 has no MainPID" >&2; return 1 ;; esac
    if curl --noproxy '*' -fsS --max-time 5 --max-filesize 65536 -o /dev/null http://127.0.0.1:8444/healthz 2>/dev/null &&
       [ "$(systemctl show -p MainPID --value "$1" 2>/dev/null || true)" = "$pid" ]; then
      echo "$pid"
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "$1 (pid $pid) is still booting: /healthz does not answer 200" >&2
      return 1
    fi
    sleep 2
  done
}
# Resolve the reload target BEFORE mutating anything, so a dead or still
# booting daemon aborts clean.
pid="$(coord_ready_pid "$unit")" || abort_pre_mutation "coordinator is not running and ready (active, serving /healthz); not mutating"
python3 "$helper" validate || abort_pre_mutation "Pearl deploy lock files failed validation; not mutating"
exec 8</run/lock/macprovider-pearl-updater.lock || abort_pre_mutation "cannot open /run/lock/macprovider-pearl-updater.lock; not mutating"
flock -n 8 || abort_pre_mutation "Pearl updater lock held; not mutating"
exec 9</opt/macprovider/.coordinator-deploy.lock || abort_pre_mutation "cannot open /opt/macprovider/.coordinator-deploy.lock; not mutating"
flock -n 9 || abort_pre_mutation "coordinator deploy lock held; not mutating"
# ---- from scripts/lib/coordinator-config-guard.sh ----
CCG_EX_REFUSED=75
CCG_EX_PRE_START_JOURNAL=76

# ccg_refuse_if_pricing_txn <install_root> [--pre-start]
#   0 when <install_root>/.pricing-txn is absent (as a path entry: a dangling
#   symlink counts as present); otherwise prints the refusal and returns 75, or
#   76 with --pre-start.
ccg_refuse_if_pricing_txn() {
  ccg_txn_root=${1:?ccg_refuse_if_pricing_txn: install root required}
  ccg_txn_mode=${2:-}
  case "$ccg_txn_mode" in
    ""|--pre-start) ;;
    *) printf 'ccg_refuse_if_pricing_txn: unknown flag %s\n' "$ccg_txn_mode" >&2; return 2 ;;
  esac
  ccg_txn_path="${ccg_txn_root%/}/.pricing-txn"
  if [ -e "$ccg_txn_path" ] || [ -L "$ccg_txn_path" ]; then
    printf 'refusing: pricing transaction journal present at %s; run scripts/catalog-content-release.sh --recover-pricing-txn\n' "$ccg_txn_path" >&2
    if [ "$ccg_txn_mode" = --pre-start ]; then
      return "$CCG_EX_PRE_START_JOURNAL"
    fi
    return "$CCG_EX_REFUSED"
  fi
  return 0
}
# ---- end ----
# #1693 L0: under the locks, refuse while a pricing transaction journal exists
# (a pricing publish creates its own journal only after this point).
ccg_refuse_if_pricing_txn /opt/macprovider/ || abort_pre_mutation "pricing transaction journal present; not mutating"
live_current="$(readlink "$root/current")" || abort_pre_mutation "cannot read current under lock"
live_current="${live_current#./}"
[ "$live_current" = "$prev" ] || abort_pre_mutation "current moved under lock ($live_current != $prev); not mutating"
# Re-check dates-only continuity under the lock so a coordinator catalog deploy
# that landed after the pre-lock read cannot be overwritten by this restamp.
# Same rules as the pre-lock guard: the shipped, sha-verified continuity-check.
python3 -I "$verifier" continuity-check --incoming "$incoming_path" --live "$root/current" \
  || abort_pre_mutation "content drift under lock; not mutating"
cd "$root/releases"
chown -R root:macprovider "$incoming"
chmod 0750 "$incoming"; chmod 0640 "$incoming"/*
mv "$incoming" "$final"
# #1688 B2: a freshness renewal mints a NEW release_id (SPEC-023 §3.7.8: a
# release_id bound to two feed digest sets is permanently rejected, so a restamp
# cannot keep the live id), and each one takes a retained-window slot. Report
# which advertised releases fall out of the window; never block the renewal.
# The operator key is read from the running coordinator's own environment and
# rides curl --config stdin; it is never echoed, written, or put in argv.
renewal_coverage() {
  local key_env key status poolz check overlay rc=0
  umask 077
  key_env="$(sed -n 's/^[[:space:]]\{1,\}operator_key:[[:space:]]*env:\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*\(#.*\)\{0,1\}$/\1/p' /opt/macprovider/coordinator.yaml | head -n 1)"
  [ -n "$key_env" ] || { echo "renewal coverage: auth.operator_key is not an env: reference" >&2; return 10; }
  key="$(tr '\0' '\n' < "/proc/$pid/environ" | sed -n "s/^${key_env}=//p" | head -n 1)"
  [ -n "$key" ] || { echo "renewal coverage: the coordinator process has no $key_env" >&2; return 10; }
  poolz="$(mktemp /tmp/macprovider-renew-poolz.XXXXXXXX)" || return 10
  status="$(printf 'header = "Authorization: Bearer %s"\n' "$key" | curl --config - -sS --noproxy '*' --max-time 10 --max-filesize 16777216 -o "$poolz" -w '%{http_code}' http://127.0.0.1:8444/poolz)" \
    || { key=""; rm -f "$poolz"; echo "renewal coverage: coordinator /poolz is unreachable on Pearl loopback" >&2; return 10; }
  key=""
  [ "$status" = 200 ] || { rm -f "$poolz"; echo "renewal coverage: coordinator /poolz answered HTTP $status" >&2; return 10; }
  # Coverage judges /poolz against exactly what the LIVE coordinator binary
  # admits after this reload: its --validate-autotune-release verdict for the
  # final release with the planned window (retained + restamps via releases/).
  check="$(mktemp -d /tmp/macprovider-renew-window-check.XXXXXXXX)" || { rm -f "$poolz"; return 10; }
  python3 -I "$window" plan --root "$root" --incoming "releases/$final" > "$check/plan.json" \
    && python3 -I -c 'import json, sys; w = json.load(open(sys.argv[1]))["window_after"]; open(sys.argv[2], "w").write("".join(e + "\n" for e in w))' "$check/plan.json" "$check/.previous-target" \
    && ln -s "$root/releases" "$check/releases" \
    && { [ ! -e "$root/.row-continuity-target" ] || install -m 0640 "$root/.row-continuity-target" "$check/.row-continuity-target"; } \
    && chown -R root:macprovider "$check" && chmod 0750 "$check" && chmod 0640 "$check/.previous-target" \
    || { rm -rf "$check"; rm -f "$poolz"; echo "renewal coverage: cannot stage the planned window" >&2; return 10; }
  overlay=""; [ ! -e /etc/macprovider/coordinator.pearl-overlays.yaml ] || overlay="--config-overlay /etc/macprovider/coordinator.pearl-overlays.yaml"
  # shellcheck disable=SC2086
  systemd-run --quiet --wait --pipe --collect -p RuntimeMaxSec=300 -p EnvironmentFile=-/etc/macprovider/coordinator.env -p User=macprovider -p Group=macprovider \
    /opt/macprovider/coordinator --config /opt/macprovider/coordinator.yaml $overlay --validate-autotune-release "$root/releases/$final" \
    --previous-target "$check/.previous-target" </dev/null >"$check/admitted.json" 2>"$check/validate.err" \
    || { tail -n 1 "$check/admitted.json" | head -c 4096 >&2; rm -rf "$check"; rm -f "$poolz"; echo "renewal coverage: live coordinator --validate-autotune-release rejected the release (coverage unknown)" >&2; return 11; }
  python3 -I "$window" coverage --admitted-json "$check/admitted.json" --poolz-json "$poolz" || rc=$?
  rm -rf "$check"; rm -f "$poolz"
  return "$rc"
}
cov_rc=0
cov_json="$(renewal_coverage)" || cov_rc=$?
echo "RENEW_COVERAGE_RC=$cov_rc"
echo "RENEW_COVERAGE_JSON=$cov_json"
# Persistent autotune metadata starts here. Set mutated before the first write so
# a failure after .previous-target (and before current swap) still rollbacks.
mutated=1
# Prepend the outgoing current onto the retained window (max 3 unique
# releases/). A single-hop overwrite kicks every serve process still
# advertising the hop before last. See docs/reports/2026-09-19-catalog-one-hop-admission-outage.md
python3 -I "$window" plan --root "$root" --incoming "releases/$final"
python3 -I "$window" apply --root "$root" --incoming "releases/$final" --expect-current "$prev"
# Atomic symlink swap: create the new link beside `current`, then rename over.
ln -sfn "releases/$final" "$root/.current.next"
mv -Tf "$root/.current.next" "$root/current"
echo "retargeted current -> releases/$final (previous-target=$prev)"
# SIGHUP the running coordinator: in-process config reload (#1268), NOT a restart.
# Only a ready one (a restart since the pre-mutation check re-waits, bounded).
pid="$(coord_ready_pid "$unit")" || { echo "coordinator not ready for the SIGHUP after mutating; rolling back" >&2; exit 1; }
kill -HUP "$pid"
echo "sent SIGHUP to $unit (pid $pid)"
