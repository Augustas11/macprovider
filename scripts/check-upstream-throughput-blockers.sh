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
# Material changes: issue/PR closed or merged, a tracked fix-PR head changes, a fix
# enters the latest release, a new release tag appears above the MacProvider pin,
# KVCache compile-fix heuristic flips true, or native-MTP readiness flips true.

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

def issue(number):
    return gh_json(["issue", "view", str(number), "--repo", "ml-explore/mlx-swift-lm",
                    "--json", "number,state,title,updatedAt,closedAt"])

def pr(number):
    return gh_json(["pr", "view", str(number), "--repo", "ml-explore/mlx-swift-lm",
                    "--json", "number,state,title,updatedAt,mergedAt,mergeCommit,headRefOid,reviewDecision"])

def latest_release(repo):
    r = gh_json(["release", "view", "--repo", repo, "--json", "tagName,publishedAt,name"])
    if not r.get("tagName") or not r.get("publishedAt"):
        raise RuntimeError(f"latest release missing required fields for {repo}")
    return {"tag": r["tagName"], "published_at": r["publishedAt"]}

def release_contains_commit(repo, tag, commit):
    if not tag or not commit:
        return False
    comparison = gh_json(["api", f"repos/{repo}/compare/{commit}...{tag}"])
    return comparison.get("behind_by") == 0

def commit_is_descendant(repo, base, commit):
    comparison = gh_json(["api", f"repos/{repo}/compare/{base}...{commit}"])
    return comparison.get("behind_by") == 0 and comparison.get("ahead_by", 0) >= 1

def pr_status(row, merged, open_status, closed_status=None):
    if row.get("mergedAt"):
        return merged
    if row.get("state") == "CLOSED":
        return closed_status or "closed_unmerged"
    return open_status

issue406 = issue(406)
pr550 = pr(550)
pr364 = pr(364)
issue312 = issue(312)
pr453 = pr(453)
issue424 = issue(424)
issue518 = issue(518)
pr351 = pr(351)
pr516 = pr(516)
issue505 = issue(505)
pr510 = pr(510)
pr545 = pr(545)
pr581 = pr(581)
pr584 = pr(584)
pr598 = pr(598)
pr620 = pr(620)
pr622 = pr(622)
pr631 = pr(631)
pr633 = pr(633)
issue645 = issue(645)
pr514 = pr(514)
pr335 = pr(335)

lm_rel = latest_release("ml-explore/mlx-swift-lm")
swift_rel = latest_release("ml-explore/mlx-swift")
transformers_rel = latest_release("huggingface/swift-transformers")
jinja_rel = latest_release("huggingface/swift-jinja")

pr550_merge_commit = (pr550.get("mergeCommit") or {}).get("oid")
pr550_in_latest_release = bool(
    pr550_merge_commit
    and release_contains_commit(
        "ml-explore/mlx-swift-lm", lm_rel["tag"], pr550_merge_commit
    )
)
if pr550.get("mergedAt"):
    pr550_automation_status = (
        "tagged_fix_candidate_requires_t2_01_tg2_qualification"
        if pr550_in_latest_release
        else "awaiting_release_tag"
    )
elif pr550.get("state") == "CLOSED":
    pr550_automation_status = "closed_unmerged_fix_candidate"
else:
    pr550_automation_status = "active_fix_candidate_review_required"

native_mtp_required_prs = {
    "mlx_swift_lm_351_qwen_mtp": pr351,
    "mlx_swift_lm_516_mtp_sliding_window": pr516,
    "mlx_swift_lm_584_rotating_cache_trim": pr584,
    "mlx_swift_lm_598_mtp_norm_double_shift": pr598,
}
native_mtp_required_merges = {}
for key, row in native_mtp_required_prs.items():
    native_mtp_required_merges[key] = {
        "merged_at": row.get("mergedAt"),
        "merge_commit": (row.get("mergeCommit") or {}).get("oid"),
        "in_latest_release": release_contains_commit(
            "ml-explore/mlx-swift-lm",
            lm_rel["tag"],
            (row.get("mergeCommit") or {}).get("oid"),
        ),
    }
native_mtp_required_merges_in_latest_release = all(
    row["merged_at"] and row["merge_commit"] and row["in_latest_release"]
    for row in native_mtp_required_merges.values()
)

# mlx-swift-lm fork tag 3.32.3-macprovider.2 on upstream tag 3.32.3.
native_mtp_exception_revision = "37f0d7ceacf6f5eca3ec2ceddc96d0f6e91ed2f1"
native_mtp_exception_base = "3b339ad6e3b3f44c8121ecff5131c7fd55e075e6"
native_mtp_exception_repo = "Augustas11/mlx-swift-lm"
# mlx-swift fork tag 0.32.3-macprovider.1 on upstream tag 0.32.3; its MLX core
# submodule points at Augustas11/mlx v0.32.2-macprovider.1 (ff1b9483).
native_mtp_exception_mlx_swift_revision = "d073a644c559318d93e267ed2a53baf434787a41"
native_mtp_exception_mlx_swift_base = "19601207e9a0de51e03ee6ec0c3c5f3784275075"
native_mtp_exception_mlx_swift_repo = "Augustas11/mlx-swift"
native_mtp_exception_review_approved = False
native_mtp_exception_remote_verified = commit_is_descendant(
    native_mtp_exception_repo,
    native_mtp_exception_base,
    native_mtp_exception_revision,
) and commit_is_descendant(
    native_mtp_exception_mlx_swift_repo,
    native_mtp_exception_mlx_swift_base,
    native_mtp_exception_mlx_swift_revision,
)
native_mtp_exception_pin_matches = (
    pins.get("mlx_swift_lm_revision") == native_mtp_exception_revision
    and pins.get("mlx_swift_revision") == native_mtp_exception_mlx_swift_revision
)
native_mtp_exception_approved = (
    native_mtp_exception_remote_verified
    and native_mtp_exception_pin_matches
    and native_mtp_exception_review_approved
)

# Heuristic: fetch KVCache.swift and look for graph-traceable offset patterns.
kvcache_url = "https://raw.githubusercontent.com/ml-explore/mlx-swift-lm/main/Libraries/MLXLMCommon/KVCache.swift"
body = urllib.request.urlopen(kvcache_url, timeout=30).read().decode("utf-8", "replace")
graph_traceable = (
    "offsetMLX" in body
    or "offset: MLXArray" in body
    or "var offset: MLXArray" in body
    or "CompilableKVCache" in body
)
note = (
    "KVCache.swift heuristic on upstream main; public MTP transaction/packed verification API "
    "tracked by mlx-swift-lm#645"
)

now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

out = {
    "schema_version": 3,
    "last_checked_at": now,
    "last_changed_at": now,
    "macprovider_pins": pins,
    "blockers": {
        "mlx_swift_lm_406_compile_kv_offset": {
            "repo": "ml-explore/mlx-swift-lm",
            "kind": "issue",
            "number": issue406["number"],
            "url": "https://github.com/ml-explore/mlx-swift-lm/issues/406",
            "state": issue406["state"],
            "title": issue406["title"],
            "runbook_tasks": ["T2-01", "TG2"],
            "updated_at": issue406["updatedAt"],
            "closed_at": issue406.get("closedAt"),
        },
        "mlx_swift_lm_550_fixed_capacity_compiled_decode": {
            "repo": "ml-explore/mlx-swift-lm",
            "kind": "pull_request",
            "number": pr550["number"],
            "url": "https://github.com/ml-explore/mlx-swift-lm/pull/550",
            "state": pr550["state"],
            "title": pr550["title"],
            "runbook_tasks": ["T2-01", "TG2"],
            "updated_at": pr550["updatedAt"],
            "merged_at": pr550.get("mergedAt"),
            "merge_commit": pr550_merge_commit,
            "head_revision": pr550.get("headRefOid"),
            "review_decision": pr550.get("reviewDecision"),
            "in_latest_release": pr550_in_latest_release,
            "macprovider_issue": "https://github.com/Augustas11/macprovider/issues/964",
            "automation_status": pr550_automation_status,
        },
        "mlx_swift_lm_364_gemma_moe": {
            "repo": "ml-explore/mlx-swift-lm",
            "kind": "pull_request",
            "number": pr364["number"],
            "url": "https://github.com/ml-explore/mlx-swift-lm/pull/364",
            "state": pr364["state"],
            "title": pr364["title"],
            "runbook_tasks": ["T1-02", "TG1"],
            "updated_at": pr364["updatedAt"],
            "merged_at": pr364.get("mergedAt"),
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
        "mlx_swift_lm_351_qwen_mtp": {
            "repo": "ml-explore/mlx-swift-lm", "kind": "pull_request", "number": 351,
            "url": "https://github.com/ml-explore/mlx-swift-lm/pull/351",
            "state": pr351["state"], "title": pr351["title"],
            "runbook_tasks": ["SPEC-048-R003", "JOURNEY-NATIVE-MTP-SERVING"],
            "updated_at": pr351["updatedAt"], "merged_at": pr351.get("mergedAt"),
            "merge_commit": (pr351.get("mergeCommit") or {}).get("oid"),
        },
        "mlx_swift_lm_516_mtp_sliding_window": {
            "repo": "ml-explore/mlx-swift-lm", "kind": "pull_request", "number": 516,
            "url": "https://github.com/ml-explore/mlx-swift-lm/pull/516",
            "state": pr516["state"], "title": pr516["title"],
            "runbook_tasks": ["SPEC-048-R003", "SPEC-048-R006"],
            "updated_at": pr516["updatedAt"], "merged_at": pr516.get("mergedAt"),
            "merge_commit": (pr516.get("mergeCommit") or {}).get("oid"),
        },
        "mlx_swift_lm_505_mtp_sliding_window_rewind": {
            "repo": "ml-explore/mlx-swift-lm", "kind": "issue", "number": 505,
            "url": "https://github.com/ml-explore/mlx-swift-lm/issues/505",
            "state": issue505["state"], "title": issue505["title"],
            "runbook_tasks": ["SPEC-048-R003", "SPEC-048-R006"],
            "updated_at": issue505["updatedAt"], "closed_at": issue505.get("closedAt"),
        },
        "mlx_swift_lm_510_mamba_hybrid_rewind": {
            "repo": "ml-explore/mlx-swift-lm", "kind": "pull_request", "number": 510,
            "url": "https://github.com/ml-explore/mlx-swift-lm/pull/510",
            "state": pr510["state"], "title": pr510["title"],
            "runbook_tasks": ["SPEC-048-R003", "SPEC-048-R006"],
            "updated_at": pr510["updatedAt"], "merged_at": pr510.get("mergedAt"),
            "merge_commit": (pr510.get("mergeCommit") or {}).get("oid"),
        },
        "mlx_swift_lm_545_qwen38_mtp": {
            "repo": "ml-explore/mlx-swift-lm", "kind": "pull_request", "number": 545,
            "url": "https://github.com/ml-explore/mlx-swift-lm/pull/545",
            "state": pr545["state"], "title": pr545["title"],
            "runbook_tasks": ["SPEC-048-R003", "JOURNEY-NATIVE-MTP-SERVING"],
            "updated_at": pr545["updatedAt"], "merged_at": pr545.get("mergedAt"),
            "merge_commit": (pr545.get("mergeCommit") or {}).get("oid"),
        },
        "mlx_swift_lm_581_resumable_qwen_mtp": {
            "repo": "ml-explore/mlx-swift-lm", "kind": "pull_request", "number": 581,
            "url": "https://github.com/ml-explore/mlx-swift-lm/pull/581",
            "state": pr581["state"], "title": pr581["title"],
            "runbook_tasks": ["SPEC-048-R003", "SPEC-048-R005"],
            "updated_at": pr581["updatedAt"], "merged_at": pr581.get("mergedAt"),
            "merge_commit": (pr581.get("mergeCommit") or {}).get("oid"),
        },
        "mlx_swift_lm_584_rotating_cache_trim": {
            "repo": "ml-explore/mlx-swift-lm", "kind": "pull_request", "number": 584,
            "url": "https://github.com/ml-explore/mlx-swift-lm/pull/584",
            "state": pr584["state"], "title": pr584["title"],
            "runbook_tasks": ["SPEC-048-R003", "SPEC-048-R006"],
            "updated_at": pr584["updatedAt"], "merged_at": pr584.get("mergedAt"),
            "merge_commit": (pr584.get("mergeCommit") or {}).get("oid"),
        },
        "mlx_swift_lm_598_mtp_norm_double_shift": {
            "repo": "ml-explore/mlx-swift-lm", "kind": "pull_request", "number": 598,
            "url": "https://github.com/ml-explore/mlx-swift-lm/pull/598",
            "state": pr598["state"], "title": pr598["title"],
            "runbook_tasks": ["SPEC-048-R003", "pin_bump_qualification"],
            "updated_at": pr598["updatedAt"], "merged_at": pr598.get("mergedAt"),
            "merge_commit": (pr598.get("mergeCommit") or {}).get("oid"),
            "macprovider_issue": "https://github.com/Augustas11/macprovider/issues/1788",
            "automation_status": pr_status(pr598, "awaiting_release_tag", "blocked_upstream_open"),
        },
        "mlx_swift_lm_620_cache_clear_first_token": {
            "repo": "ml-explore/mlx-swift-lm", "kind": "pull_request", "number": 620,
            "url": "https://github.com/ml-explore/mlx-swift-lm/pull/620",
            "state": pr620["state"], "title": pr620["title"],
            "runbook_tasks": ["pin_bump_qualification", "qwen_decode_prefill_perf"],
            "updated_at": pr620["updatedAt"], "merged_at": pr620.get("mergedAt"),
            "merge_commit": (pr620.get("mergeCommit") or {}).get("oid"),
            "macprovider_issue": "https://github.com/Augustas11/macprovider/issues/1788",
            "automation_status": pr_status(pr620, "awaiting_release_tag", "blocked_upstream_open"),
        },
        "mlx_swift_lm_622_exact_rotating_cache_rewinds": {
            "repo": "ml-explore/mlx-swift-lm", "kind": "pull_request", "number": 622,
            "url": "https://github.com/ml-explore/mlx-swift-lm/pull/622",
            "state": pr622["state"], "title": pr622["title"],
            "runbook_tasks": ["SPEC-048-R003", "SPEC-048-R006"],
            "updated_at": pr622["updatedAt"], "merged_at": pr622.get("mergedAt"),
            "merge_commit": (pr622.get("mergeCommit") or {}).get("oid"),
        },
        "mlx_swift_lm_631_gdn_reload_leak": {
            "repo": "ml-explore/mlx-swift-lm", "kind": "pull_request", "number": 631,
            "url": "https://github.com/ml-explore/mlx-swift-lm/pull/631",
            "state": pr631["state"], "title": pr631["title"],
            "runbook_tasks": ["pin_bump_qualification", "qwen_decode_prefill_perf"],
            "updated_at": pr631["updatedAt"], "merged_at": pr631.get("mergedAt"),
            "merge_commit": (pr631.get("mergeCommit") or {}).get("oid"),
            "macprovider_issue": "https://github.com/Augustas11/macprovider/issues/1788",
            "automation_status": pr_status(
                pr631,
                "awaiting_release_tag",
                "blocked_upstream_open_or_disable_MLX_QWEN_FOUR_GDN",
                "closed_unmerged_disable_MLX_QWEN_FOUR_GDN",
            ),
        },
        "mlx_swift_lm_633_qwen_gdn_epsilon": {
            "repo": "ml-explore/mlx-swift-lm", "kind": "pull_request", "number": 633,
            "url": "https://github.com/ml-explore/mlx-swift-lm/pull/633",
            "state": pr633["state"], "title": pr633["title"],
            "runbook_tasks": ["pin_bump_qualification", "qwen_token_rebaseline"],
            "updated_at": pr633["updatedAt"], "merged_at": pr633.get("mergedAt"),
            "merge_commit": (pr633.get("mergeCommit") or {}).get("oid"),
            "macprovider_issue": "https://github.com/Augustas11/macprovider/issues/1788",
            "automation_status": pr_status(
                pr633,
                "intended_token_diff_pre_register_before_pin_bump",
                "blocked_upstream_open_token_diff_expected",
                "closed_unmerged_token_diff_expected",
            ),
        },
        "mlx_swift_lm_645_public_mtp_transactions": {
            "repo": "ml-explore/mlx-swift-lm", "kind": "issue", "number": 645,
            "url": "https://github.com/ml-explore/mlx-swift-lm/issues/645",
            "state": issue645["state"], "title": issue645["title"],
            "runbook_tasks": ["SPEC-048-R003", "SPEC-048-R005", "SPEC-048-R006"],
            "updated_at": issue645["updatedAt"], "closed_at": issue645.get("closedAt"),
        },
        "mlx_swift_lm_514_max_kv_size_hybrid": {
            "repo": "ml-explore/mlx-swift-lm", "kind": "pull_request", "number": 514,
            "url": "https://github.com/ml-explore/mlx-swift-lm/pull/514",
            "state": pr514["state"], "title": pr514["title"],
            "runbook_tasks": ["pin_bump_qualification", "hybrid_cache_class_tests"],
            "updated_at": pr514["updatedAt"], "merged_at": pr514.get("mergedAt"),
            "merge_commit": (pr514.get("mergeCommit") or {}).get("oid"),
            "macprovider_issue": "https://github.com/Augustas11/macprovider/issues/1788",
            "automation_status": pr_status(
                pr514,
                "awaiting_per_catalog_model_cache_class_tests",
                "blocked_upstream_open",
            ),
        },
        "mlx_swift_lm_335_modelcontainer_api_break": {
            "repo": "ml-explore/mlx-swift-lm", "kind": "pull_request", "number": 335,
            "url": "https://github.com/ml-explore/mlx-swift-lm/pull/335",
            "state": pr335["state"], "title": pr335["title"],
            "runbook_tasks": ["pin_bump_qualification", "api_migration"],
            "updated_at": pr335["updatedAt"], "merged_at": pr335.get("mergedAt"),
            "merge_commit": (pr335.get("mergeCommit") or {}).get("oid"),
            "macprovider_issue": "https://github.com/Augustas11/macprovider/issues/1788",
            "automation_status": pr_status(
                pr335,
                "merged_api_break_requires_migration",
                "blocked_upstream_open_modelcontainer_api_break_watch",
            ),
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
        "native_mtp_required_merges": native_mtp_required_merges,
        "native_mtp_required_merges_in_latest_release": native_mtp_required_merges_in_latest_release,
        "native_mtp_public_row_mapped_transactions_reviewed": native_mtp_exception_approved,
        "native_mtp_status": (
            "qualified_transaction_exception_default_off"
            if native_mtp_exception_approved
            else "candidate_step_overhead_revision_pending_review"
        ),
        "note": (
            "The fork patch set is rebased onto upstream mlx-swift-lm 3.32.3 "
            "(3.32.3-macprovider.2) with mlx-swift 0.32.3 on a batch-invariant "
            "small-M quantized matmul MLX core fork (0.32.3-macprovider.1); it is "
            "not approved until Studio validation and the freeze audits pass; "
            "native MTP stays default-off; upstream #645 remains the tagged-release "
            "replacement tracker"
        ),
    },
    "native_mtp_immutable_dependency_exception": {
        "approved": native_mtp_exception_approved,
        "approved_at": None,
        "approved_by": None,
        "review_due_at": "2026-12-27",
        "fork_location": "https://github.com/Augustas11/mlx-swift-lm.git",
        "fork_revision": native_mtp_exception_revision,
        "upstream_base_revision": native_mtp_exception_base,
        "mlx_swift_fork_location": "https://github.com/Augustas11/mlx-swift",
        "mlx_swift_fork_revision": native_mtp_exception_mlx_swift_revision,
        "mlx_swift_upstream_base_revision": native_mtp_exception_mlx_swift_base,
        "remote_revision_verified": native_mtp_exception_remote_verified,
        "local_pin_matches": native_mtp_exception_pin_matches,
        "review_status": "candidate_extension_pending_studio_and_freeze_audits",
        "scope": (
            "packed_mtp_target_verification_public_cache_transactions_and_packed_"
            "drafter_plus_fused_qwen36_a3b_moe_behind_MLX_LM_QWEN35_FUSED_MOE_"
            "with_layout_validation_plus_one_pass_gdn_verify_checkpoint_plus_"
            "unpadded_packed_ssm_mask_skip_plus_mlx_swift_and_mlx_core_batch_"
            "invariant_small_m_quantized_matmul_fork"
        ),
        "removal_trigger": (
            "first reviewed upstream tag with equivalent standalone-checkpoint "
            "loading and public transaction, packed verification, continuation, "
            "and recurrent-cache surfaces that passes the MacProvider qualification "
            "artifact"
        ),
        "replacement_tracker": "https://github.com/ml-explore/mlx-swift-lm/issues/645",
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
