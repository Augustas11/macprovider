# R1 code lane result (codex, -2026-10-05T13-34-52-287)

**Findings**

MEDIUM: The upstream watch output can signal “reviewed” while the new immutable fused-MoE exception is still pending review.  
[`scripts/check-upstream-throughput-blockers.sh`](scripts/check-upstream-throughput-blockers.sh:429) hardcodes `native_mtp_public_row_mapped_transactions_reviewed` to `true`, and the checked-in watch snapshot also carries that value while `native_mtp_immutable_dependency_exception.approved` is `false` and `native_mtp_status` is `candidate_fused_moe_revision_pending_review` at [`UPSTREAM_WATCH.json`](beta/throughput-engineering/UPSTREAM_WATCH.json:396). The comparator treats this boolean as a material reviewed-ready signal at [`compare_upstream_watch.py`](scripts/compare_upstream_watch.py:110).  
Failure scenario: a consumer or release gate that reads the legacy boolean, rather than the newer exception object, can conclude that the native-MTP public row-mapped transaction surface is reviewed even though the exact pinned fused-MoE dependency exception remains unapproved. That is a stale/unreviewed-revision pass path in the audit metadata.  
Fix: derive the legacy reviewed boolean from the full exception approval state, or replace it with two explicit fields: one for prior transaction-surface review and one for the exact immutable dependency exception approval. Update the comparator/tests so a pending fused-MoE exception cannot emit a reviewed-ready signal.  
New in this diff: yes.

**Validation**

Ran the allowed read-only checks:

```text
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest ...
114 tests OK

python3 scripts/gen_spec_index.py --check
ok: spec index is up to date

python3 scripts/check_spec_governance.py --base-ref origin/main
SPEC governance validation passed
```

I did not run Swift/MLX builds or Metal tests per the audit constraint and host boundary.

VERDICT: 0 CRITICAL, 0 HIGH, 1 MEDIUM, 0 LOW
