Read `audits/2026-09-24/AUDIT_1690_FINAL_COMMON.md` first.

**Lane: trust and money-path security.** Can any path let external-runtime usage produce a buyer debit, provider credit, or signed receipt outside the invariants? Consider:
- global routes
- non-members, delegated members, and non-creator accounts
- runtimes not on the allowlist
- a spoofed hello `runtime_source`
- stale, disputed, or replayed manifests
- v1/v2 downgrade
- a copied or replayed `pool_runtime_authorization`
- the recovery and replay paths
- the candidate-env gate after reload or replay
- on-call expiry

Also check:
- the loopback client origin and path restrictions
- the request caps
- the runner pause safety

Evaluate by reading only.
