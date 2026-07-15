#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$INSTALL_SH" > "$TMP/function.sh" <<'PY'
import sys

name = "wait_for_coordinator"
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
for index, line in enumerate(lines):
    if not line.startswith(name + "()"):
        continue
    depth = 0
    for body_line in lines[index:]:
        print(body_line)
        depth += body_line.count("{") - body_line.count("}")
        if depth == 0:
            raise SystemExit(0)
raise SystemExit("wait_for_coordinator not found")
PY

mkdir -p "$TMP/install/catalog-release" "$TMP/bin"
cp "$REPO_ROOT/phase3-binary/catalog/autotune/release.json" "$TMP/install/catalog-release/release.json"
cp "$REPO_ROOT/phase3-binary/catalog/autotune/autotune-candidates.json" \
  "$TMP/install/catalog-release/autotune-candidates.json"

python3 - "$TMP/install/catalog-release/release.json" \
  "$TMP/install/catalog-release/autotune-candidates.json" \
  "$TMP/local.json" "$TMP/coordinator.json" <<'PY'
import hashlib
import json
import sys

release_path, candidates_path, local_path, coordinator_path = sys.argv[1:]
release = json.load(open(release_path, encoding="utf-8"))
candidate_bytes = open(candidates_path, "rb").read()
candidates = json.loads(candidate_bytes)
key = "qwen3-8b"
row = candidates["rows"][key]
gate = row["bench_gate"]
fields = [
    candidates["policy_version"], key, row["model_id"], row["model_revision"], row["model_sha256"],
    str(row["min_ram_gb"]), row["min_bandwidth_tier"],
    f'{float(gate["min_sustained_tps"]):.6f}', str(gate["max_4k_ttft_ms"]), row["runtime_status"],
]
framed = "|".join(f"{len(value.encode('utf-8'))}:{value}" for value in fields)
identity = hashlib.sha256(framed.encode()).hexdigest()
digest = hashlib.sha256(candidate_bytes).hexdigest()
signer = release["feeds"]["autotune-candidates.json"]["signer_key_id"]
local = {
    "provider_id": "provider-test",
    "model": row["model_id"],
    "network_state": "buyer_serving",
    "coordinator": {"connected": True, "session": "session-test"},
    "catalog": {
        "catalog_key": key,
        "release_id": release["release_id"],
        "digest": digest,
        "signer_key_id": signer,
        "policy_version": release["policy_version"],
        "row_identity": identity,
    },
}
coordinator = {
    "provider_id": "provider-test",
    "assigned_id": "session-test",
    "state": "ready",
    "buyer_serving": True,
    "catalog_evidence_source": "provider_reported",
    "catalog_admission_mode": "current",
    "catalog_release_id": release["release_id"],
    "catalog_policy_version": release["policy_version"],
    "catalog_candidate_sha256": digest,
    "catalog_signer_key_id": signer,
    "catalog_row_identity": identity,
}
json.dump(local, open(local_path, "w", encoding="utf-8"), separators=(",", ":"))
json.dump(coordinator, open(coordinator_path, "w", encoding="utf-8"), separators=(",", ":"))
PY

cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"
printf '%s\n' "$url" >> "$CURL_LOG"
case "$url" in
  http://127.0.0.1:*) cat "$LOCAL_RESPONSE" ;;
  *)
    case "$url" in
      *'provider_id=provider-test&assigned_id=session-test&details=readiness'*) cat "$COORDINATOR_RESPONSE" ;;
      *) exit 22 ;;
    esac
    ;;
esac
EOF
cat > "$TMP/bin/date" <<'EOF'
#!/usr/bin/env bash
value="$(cat "$DATE_STATE" 2>/dev/null || printf 100)"
printf '%s\n' "$((value + 10))" > "$DATE_STATE"
printf '%s\n' "$value"
EOF
cat > "$TMP/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/bin/"*

run_wait() {
  coordinator_response="$1"
  local_response="${2:-$TMP/local.json}"
  emergency_rollback="${3:-0}"
  : > "$TMP/date-state"
  printf '100\n' > "$TMP/date-state"
  PATH="$TMP/bin:/usr/bin:/bin" DATE_STATE="$TMP/date-state" CURL_LOG="$TMP/curl.log" \
    LOCAL_RESPONSE="$local_response" COORDINATOR_RESPONSE="$coordinator_response" \
    EMERGENCY_ROLLBACK="$emergency_rollback" \
    FUNCTION_PATH="$TMP/function.sh" INSTALL_ROOT="$TMP/install" bash -c '
      set -euo pipefail
      PORT=18080
      INSTALL_DIR="$INSTALL_ROOT"
      urlencode() { printf "%s" "$1"; }
      source "$FUNCTION_PATH"
      wait_for_coordinator provider-test https://coordinator.example
    '
}

run_wait "$TMP/coordinator.json"
grep -F 'details=readiness' "$TMP/curl.log" >/dev/null
grep -F 'assigned_id=session-test' "$TMP/curl.log" >/dev/null

python3 - "$TMP/coordinator.json" "$TMP/wrong-session.json" <<'PY'
import json
import sys
source, destination = sys.argv[1:]
payload = json.load(open(source, encoding="utf-8"))
payload["assigned_id"] = "different-session"
json.dump(payload, open(destination, "w", encoding="utf-8"), separators=(",", ":"))
PY
if run_wait "$TMP/wrong-session.json"; then
  echo "mismatched coordinator session passed admission" >&2
  exit 1
fi

python3 - "$TMP/coordinator.json" "$TMP/mismatch.json" <<'PY'
import json
import sys
source, destination = sys.argv[1:]
payload = json.load(open(source, encoding="utf-8"))
payload["catalog_row_identity"] = "0" * 64
json.dump(payload, open(destination, "w", encoding="utf-8"), separators=(",", ":"))
PY
if run_wait "$TMP/mismatch.json"; then
  echo "mismatched catalog envelope passed coordinator admission" >&2
  exit 1
fi

python3 - "$TMP/coordinator.json" "$TMP/previous.json" <<'PY'
import json
import sys
source, destination = sys.argv[1:]
payload = json.load(open(source, encoding="utf-8"))
payload["catalog_admission_mode"] = "previous"
json.dump(payload, open(destination, "w", encoding="utf-8"), separators=(",", ":"))
PY
run_wait "$TMP/previous.json"

python3 - "$TMP/coordinator.json" "$TMP/busy.json" <<'PY'
import json
import sys
source, destination = sys.argv[1:]
payload = json.load(open(source, encoding="utf-8"))
payload["state"] = "degraded"
payload["buyer_serving"] = True
json.dump(payload, open(destination, "w", encoding="utf-8"), separators=(",", ":"))
PY
run_wait "$TMP/busy.json"

python3 - "$TMP/local.json" "$TMP/legacy-local.json" \
  "$TMP/coordinator.json" "$TMP/legacy-coordinator.json" <<'PY'
import json
import sys

local_source, local_destination, coordinator_source, coordinator_destination = sys.argv[1:]
local = json.load(open(local_source, encoding="utf-8"))
local.pop("catalog", None)
local.pop("network_state", None)
json.dump(local, open(local_destination, "w", encoding="utf-8"), separators=(",", ":"))

coordinator = json.load(open(coordinator_source, encoding="utf-8"))
coordinator["catalog_admission_mode"] = "legacy_bridge"
for field in (
    "catalog_release_id",
    "catalog_policy_version",
    "catalog_candidate_sha256",
    "catalog_signer_key_id",
    "catalog_row_identity",
):
    coordinator.pop(field, None)
json.dump(coordinator, open(coordinator_destination, "w", encoding="utf-8"), separators=(",", ":"))
PY

if run_wait "$TMP/legacy-coordinator.json" "$TMP/legacy-local.json" 0; then
  echo "normal upgrade accepted legacy_bridge admission" >&2
  exit 1
fi
run_wait "$TMP/legacy-coordinator.json" "$TMP/legacy-local.json" 1
if run_wait "$TMP/coordinator.json" "$TMP/local.json" 1; then
  echo "emergency rollback accepted current catalog admission instead of legacy_bridge" >&2
  exit 1
fi

printf '%s\n' '{"provider_id":"provider-test","tier":"pinned","state":"ready"}' \
  > "$TMP/sparse-legacy-coordinator.json"
if run_wait "$TMP/sparse-legacy-coordinator.json" "$TMP/legacy-local.json" 1; then
  echo "emergency rollback accepted sparse legacy coordinator readiness without exact session-bound buyer admission" >&2
  exit 1
fi

python3 - "$INSTALL_SH" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
main = text[text.rfind("main() {"):]
lock = main.index("acquire_install_lock")
identity = main.index("choose_provider_id")
admission = main.index('wait_for_coordinator "$provider_id" "$coordinator_base"')
commit = main.index("commit_install_transaction", admission)
if not lock < identity:
    raise SystemExit("installer lock is not acquired before provider identity selection")
if not admission < commit:
    raise SystemExit("install commits before exact coordinator admission")
if 'MACPROVIDER_EMERGENCY_ROLLBACK' not in text:
    raise SystemExit("installer omits explicit emergency rollback control")
if 'emergency rollback requires MACPROVIDER_VERSION' not in text:
    raise SystemExit("emergency rollback is not pinned to an explicit signed release tag")
if 'catalog_admission_mode") != "legacy_bridge"' not in text:
    raise SystemExit("emergency rollback is not gated on legacy_bridge buyer admission")
if 'response.get("assigned_id") != assigned_id' not in text or 'response.get("buyer_serving") is not True' not in text:
    raise SystemExit("emergency rollback is not bound to the exact buyer-serving coordinator session")

commit_start = text.index("commit_install_transaction() {")
commit_end = text.index("\n}\n\nrun()", commit_start)
commit_body = text[commit_start:commit_end]
retire = commit_body.index('mv "$INSTALL_TX_BACKUP" "$retired_recovery"')
mark = commit_body.index("INSTALL_TX_COMMITTED=1")
disarm = commit_body.index("disarm_install_recovery_agent")
if not retire < mark < disarm:
    raise SystemExit("recovery observer is disarmed before the atomic no-rollback boundary")
PY
