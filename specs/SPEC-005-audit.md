# SPEC-005 final audit summary

## R1 findings

Codex R1 audited SPEC-005 v0.1 and returned **READY WITH FIX PASS**: 0 CRITICAL, 7 MAJOR, 4 MINOR, and 3 QUESTIONS. The findings were precision gaps, not architecture reversals: D1-D12 references were too concentrated in appendices, stable provider_id derivation was underspecified, historical rate-card recovery lacked deterministic snapshots, attempt fallback ordering needed a hard key, § 11 endpoint contracts were incomplete, D1-D12 ACs were too self-referential, and H-005 needed zero-tolerance reconciliation semantics.

## R1 FIX

SPEC-005 v0.2 closed R1 with additive structure only: D1-D12 references were placed into normative sections, `ledger_provider_identity_snapshots` and `ledger_config_snapshots` were added, `request_log.id ASC` fallback quarantine was specified, § 11 JSON endpoint contracts and auth/rate-limit posture were completed, behavior-level AC-D1 through AC-D12 fixtures were added, H-005 was set to zero gross-credit tolerance, and unreachable provider-not-reached ledger rows were removed.

## R2 + Cross-Spec Findings

Claude R2 audited SPEC-005 v0.2 and returned **READY WITH SECOND FIX PASS**: 0 CRITICAL, 10 MAJOR, 5 MINOR, and 3 operator questions. SPEC-005 v0.3 closed the R2 set by adding null-prompt/null-completion guards, WAL mode and recovery grace cutoff, SPEC-007 consumer contract, normative byte-estimate formula, cross-process crash-boundary disclaimer, `buyer_equivalent_credits`, and route-disable behavior for `/providers/{provider_id}/earnings` when provider tokens are not required. The bundled cross-spec patches are SPEC-002 v1.3.4 (`request_log.error_code`, reconciliation indexes, multi-row-per-request_id contract) and SPEC-006 v0.8.2 (SPEC-001 null-usage error row with zero buyer debit).

## Regression Check

The v0.3 regression check appended to `specs/SPEC-005-r2-audit.md` returned **CLEAN**: 0 CRITICAL, 0 MAJOR, 0 MINOR, and 0 QUESTIONS. Phase A commit `39d9d93` touched only SPEC-005, SPEC-002, and SPEC-006; no SPEC-005 § 2 D1-D12 decision text changed; and no new uncovered cross-spec gap was introduced.

**Verdict:** LOCKED at v0.3.

**Dependency line:** Audited against SPEC-001 v1.2.4, SPEC-002 v1.3.4, SPEC-003 v0.7, SPEC-004 v0.3.1, SPEC-006 v0.8.2, and SPEC-008 v0.3. SPEC-007 does not exist yet; its consumer contract is defined inside SPEC-005 v0.3 § 4.5.1.
