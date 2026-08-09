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
  python3 "$ROOT/scripts/read_swiftpm_pins.py" "$ROOT/phase3-binary/Package.resolved"
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
    r = gh_json(["release", "view", "--repo", repo, "--json", "tagName,publishedAt,name"])
    if not r.get("tagName") or not r.get("publishedAt"):
        raise RuntimeError(f"latest release missing required fields for {repo}")
    return {"tag": r["tagName"], "published_at": r["publishedAt"]}

issue = gh_json(["issue", "view", "406", "--repo", "ml-explore/mlx-swift-lm",
                 "--json", "number,state,title,updatedAt,closedAt"])
pr = gh_json(["pr", "view", "364", "--repo", "ml-explore/mlx-swift-lm",
              "--json", "number,state,title,updatedAt,mergedAt"])
issue312 = gh_json(["issue", "view", "312", "--repo", "ml-explore/mlx-swift-lm",
                    "--json", "number,state,title,updatedAt,closedAt"])
pr453 = gh_json(["pr", "view", "453", "--repo", "ml-explore/mlx-swift-lm",
                 "--json", "number,state,title,updatedAt,mergedAt"])
issue424 = gh_json(["issue", "view", "424", "--repo", "ml-explore/mlx-swift-lm",
                    "--json", "number,state,title,updatedAt,closedAt"])
issue518 = gh_json(["issue", "view", "518", "--repo", "ml-explore/mlx-swift-lm",
                    "--json", "number,state,title,updatedAt,closedAt"])

lm_rel = latest_release("ml-explore/mlx-swift-lm")
swift_rel = latest_release("ml-explore/mlx-swift")
transformers_rel = latest_release("huggingface/swift-transformers")
jinja_rel = latest_release("huggingface/swift-jinja")

# Heuristic: fetch KVCache.swift and look for graph-traceable offset patterns.
kvcache_url = "https://raw.githubusercontent.com/ml-explore/mlx-swift-lm/main/Libraries/MLXLMCommon/KVCache.swift"
body = urllib.request.urlopen(kvcache_url, timeout=30).read().decode("utf-8", "replace")
graph_traceable = (
    "offsetMLX" in body
    or "offset: MLXArray" in body
    or "var offset: MLXArray" in body
    or "CompilableKVCache" in body
)
note = "KVCache.swift heuristic on upstream main"

now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

out = {
    "schema_version": 2,
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
        "mlx_swift_lm_312_quantized_cache_ownership": {
            "repo": "ml-explore/mlx-swift-lm", "kind": "issue", "number": 312,
            "url": "https://github.com/ml-explore/mlx-swift-lm/issues/312",
            "state": issue312["state"], "title": issue312["title"],
            "runbook_tasks": ["quantized_reusable_kv"],
            "updated_at": issue312["updatedAt"], "closed_at": issue312.get("closedAt"),
        },
        "mlx_swift_lm_453_typed_cache_storage": {
            "repo": "ml-explore/mlx-swift-lm", "kind": "pull_request", "number": 453,
            "url": "https://github.com/ml-explore/mlx-swift-lm/pull/453",
            "state": pr453["state"], "title": pr453["title"],
            "runbook_tasks": ["quantized_reusable_kv"],
            "updated_at": pr453["updatedAt"], "merged_at": pr453.get("mergedAt"),
        },
        "mlx_swift_lm_424_speculative_cache_wrap": {
            "repo": "ml-explore/mlx-swift-lm", "kind": "issue", "number": 424,
            "url": "https://github.com/ml-explore/mlx-swift-lm/issues/424",
            "state": issue424["state"], "title": issue424["title"],
            "runbook_tasks": ["speculative_cache_wrap"],
            "updated_at": issue424["updatedAt"], "closed_at": issue424.get("closedAt"),
        },
        "mlx_swift_lm_518_remote_package_unsafe_flags": {
            "repo": "ml-explore/mlx-swift-lm", "kind": "issue", "number": 518,
            "url": "https://github.com/ml-explore/mlx-swift-lm/issues/518",
            "state": issue518["state"], "title": issue518["title"],
            "runbook_tasks": ["T1-01", "TG1"],
            "updated_at": issue518["updatedAt"], "closed_at": issue518.get("closedAt"),
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
        "swift_transformers_latest": {
            "repo": "huggingface/swift-transformers",
            **transformers_rel,
        },
        "swift_jinja_latest": {
            "repo": "huggingface/swift-jinja",
            **jinja_rel,
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

set +e
result="$(printf '%s\n' "$snapshot" | python3 "$ROOT/scripts/compare_upstream_watch.py" "$COMPARE")"
compare_rc=$?
set -e

printf '%s\n' "$result"
exit "$compare_rc"
