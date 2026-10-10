# Security Review Report

## Round-1 Findings

1. **FIXED — Client timestamps could bypass evidence supersession.** [evidence_pg.go:98](/Users/augstar/macprovider-no-expiry/phase4-coordinator/internal/autotune/evidence_pg.go:98) now uses coordinator-assigned job IDs for supersession and candidate ordering. The existing regression test passed.

2. **FIXED — Config-entry removal could leave release-derived approval active.** [SPEC-049:423](/Users/augstar/macprovider-no-expiry/specs/SPEC-049-operator-constrained-privacy-class.md:423) now explicitly distinguishes configuration-only withdrawal from release-derived approval and identifies the retained override/deny-list controls. Existing approval-precedence tests passed.

**Scope:** PR #1944, complete ten-commit `git diff origin/main...HEAD` and touched security controls. Read-only, offline review.

**Risk Level:** LOW
**Gate:** PASS — no C/H/M findings.

## Summary

- CRITICAL: 0
- HIGH: 0
- MEDIUM: 0
- LOW: 0

## New Issues

None identified.

## Security Assessment

- **Revocation integrity:** Replayed, equivocated, or regressed feeds cannot remove anchored revocations. Fallback re-verifies cached signatures and anchor digests; store/cache integrity failures still propagate.
- **Discovery downgrade:** Persisted sequence/digest checks and monotonic signed minimum/revocation policy remain. Bootstrap suppression residuals are explicitly recorded in SPEC-020.
- **Evidence supersession:** SQL parameters remain bound. Later submissions reporting changed hardware or OS invalidate earlier evidence regardless of verification status. Existing ingestion validation requires both fields; existing role grants cover the query.
- **Trusted pools:** Agreement/on-call lapses become warnings. Suspension, approval/version/environment mismatch, missing on-call records, production gate failure, lifecycle/member revocation, and signed policy windows still constrain routing.
- **Privacy withdrawal:** Deny-list precedence and version-mismatching configuration overrides remain effective.
- **Secrets:** Scanned changed-file endpoints and workflow/script additions across all ten commits. Matches were pre-existing synthetic test credentials; no new credential literals identified.

OWASP A01–A05 and A07–A10 were evaluated against applicable touched paths. No additional finding emerged. A06 dependency vulnerability status remains unverified.

## Validation

Existing targeted Go tests passed in `autotune`, `relayblind`, `trustpool`, `buyer`, `tier2`, and both verifier packages. Three targeted Python tests also passed.

Swift tests, hardware tests, and a vulnerability-database dependency audit were not run under the host and offline/existing-tests-only constraints. No dependency manifests or lockfiles changed. No files were edited or external hosts contacted.

## Security Checklist

- [x] Secrets scan completed
- [x] Applicable input validation and injection controls reviewed
- [x] Authentication, authorization, and withdrawal reviewed
- [x] Replay, rollback, and cache integrity reviewed
- [x] Both round-1 findings resolved
- [ ] Dependency vulnerability audit completed
- [ ] Swift runtime verification completed

C/H/M/L = 0/0/0/0
