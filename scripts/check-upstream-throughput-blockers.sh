#!/usr/bin/env bash
# check-upstream-throughput-blockers.sh — poll ml-explore upstream for throughput runbook blockers.
#
# Usage:
#   scripts/check-upstream-throughput-blockers.sh [--json] [--compare PATH]
#
# Exit codes:
#   0 — success, no material change vs compare file (or no compare file)
#   1 — error
#   2 — material change detected (automation should alert / open issue)
#
# Material changes: issue/PR closed or merged, new release tag above macprovider pin,
# or KVCache compile-fix heuristic flips true.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WATCH_FILE="${WATCH_FILE:-$ROOT/beta/throughput-engineering/UPSTREAM_WATCH.json}"
COMPARE="${COMPARE:-$WATCH_FILE}"
JSON_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON_ONLY=true; shift ;;
    --compare) COMPARE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1" >&2; exit 1; }; }
need gh
need python3
need curl

read_pin() {
  python3 - "$ROOT/phase3-binary/Package.resolved" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
pins = {}
for p in data.get("pins", []):
    ident = p.get("identity", "")
    if ident == "mlx-swift-lm":
        pins["mlx_swift_lm"] = p.get("version", "")
    elif ident == "mlx-swift":
        pins["mlx_swift"] = p.get("version", "")
print(json.dumps(pins))
PY
}

PINS="$(read_pin)"

snapshot="$(python3 - <<'PY' "$PINS"
import json, subprocess, sys, urllib.request
from datetime import datetime, timezone

pins = json.loads(sys.argv[1])

def gh_json(args):
    out = subprocess.check_output(["gh"] + args, text=True)
    return json.loads(out)

def latest_release(repo):
    try:
        r = gh_json(["release", "view", "--repo", repo, "--json", "tagName,publishedAt,name"])
        return {"tag": r["tagName"], "published_at": r["publishedAt"]}
    except subprocess.CalledProcessError:
        return {"tag": None, "published_at": None}

issue = gh_json(["issue", "view", "406", "--repo", "ml-explore/mlx-swift-lm",
                 "--json", "number,state,title,updatedAt,closedAt"])
pr = gh_json(["pr", "view", "364", "--repo", "ml-explore/mlx-swift-lm",
              "--json", "number,state,title,updatedAt,mergedAt"])

lm_rel = latest_release("ml-explore/mlx-swift-lm")
swift_rel = latest_release("ml-explore/mlx-swift")

# Heuristic: fetch KVCache.swift and look for graph-traceable offset patterns.
kvcache_url = "https://raw.githubusercontent.com/ml-explore/mlx-swift-lm/main/Libraries/MLXLMCommon/KVCache.swift"
try:
    body = urllib.request.urlopen(kvcache_url, timeout=30).read().decode("utf-8", "replace")
    graph_traceable = (
        "offsetMLX" in body
        or "offset: MLXArray" in body
        or "var offset: MLXArray" in body
        or "CompilableKVCache" in body
    )
    note = "KVCache.swift heuristic on upstream main"
except Exception as e:
    graph_traceable = False
    note = f"KVCache fetch failed: {e}"

now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

out = {
    "schema_version": 1,
    "last_checked_at": now,
    "last_changed_at": now,
    "macprovider_pins": pins,
    "blockers": {
        "mlx_swift_lm_406_compile_kv_offset": {
            "repo": "ml-explore/mlx-swift-lm",
            "kind": "issue",
            "number": issue["number"],
            "url": "https://github.com/ml-explore/mlx-swift-lm/issues/406",
            "state": issue["state"],
            "title": issue["title"],
            "runbook_tasks": ["T2-01", "TG2"],
            "updated_at": issue["updatedAt"],
            "closed_at": issue.get("closedAt"),
        },
        "mlx_swift_lm_364_gemma_moe": {
            "repo": "ml-explore/mlx-swift-lm",
            "kind": "pull_request",
            "number": pr["number"],
            "url": "https://github.com/ml-explore/mlx-swift-lm/pull/364",
            "state": pr["state"],
            "title": pr["title"],
            "runbook_tasks": ["T1-02", "TG1"],
            "updated_at": pr["updatedAt"],
            "merged_at": pr.get("mergedAt"),
        },
    },
    "releases": {
        "mlx_swift_lm_latest": {
            "repo": "ml-explore/mlx-swift-lm",
            **lm_rel,
        },
        "mlx_swift_latest": {
            "repo": "ml-explore/mlx-swift",
            **swift_rel,
        },
    },
    "implementation_signals": {
        "kvcache_offset_graph_traceable": graph_traceable,
        "note": note,
    },
}

print(json.dumps(out, indent=2))
PY
)"

if $JSON_ONLY; then
  printf '%s\n' "$snapshot"
  exit 0
fi

result="$(python3 - <<'PY' "$snapshot" "$COMPARE"
import json, sys

new = json.loads(sys.argv[1])
compare_path = sys.argv[2]

def material(old, new):
    if old is None:
        return True, "no prior baseline"
    reasons = []

    for key in ("mlx_swift_lm_406_compile_kv_offset", "mlx_swift_lm_364_gemma_moe"):
        o, n = old["blockers"][key], new["blockers"][key]
        if o.get("state") != n.get("state"):
            reasons.append(f"{key} state {o.get('state')} -> {n.get('state')}")
        if n.get("closed_at") and not o.get("closed_at"):
            reasons.append(f"{key} closed")
        if n.get("merged_at") and not o.get("merged_at"):
            reasons.append(f"{key} merged")

    for rel_key in ("mlx_swift_lm_latest", "mlx_swift_latest"):
        ot, nt = old["releases"][rel_key].get("tag"), new["releases"][rel_key].get("tag")
        pin_key = "mlx_swift_lm" if "lm" in rel_key else "mlx_swift"
        pin = new["macprovider_pins"].get(pin_key)
        if nt and pin and nt != ot:
            reasons.append(f"{rel_key} tag {ot} -> {nt} (pin {pin})")
        if nt and pin and nt != pin:
            reasons.append(f"new upstream tag {nt} above pin {pin}")

    o_sig = old.get("implementation_signals", {}).get("kvcache_offset_graph_traceable")
    n_sig = new.get("implementation_signals", {}).get("kvcache_offset_graph_traceable")
    if not o_sig and n_sig:
        reasons.append("KVCache compile-fix heuristic now true")

    return (len(reasons) > 0, "; ".join(reasons) if reasons else "unchanged")

try:
    with open(compare_path) as f:
        old = json.load(f)
except FileNotFoundError:
    old = None

changed, reason = material(old, new)
print(json.dumps({"changed": changed, "reason": reason, "snapshot": new}, indent=2))
if changed:
    sys.exit(2)
PY
)"

printf '%s\n' "$result"
exit 0
