# Security Review Report

**Scope:** PR #1944, complete nine-commit `git diff origin/main...HEAD` and touched security controls. Read-only, offline review.  
**Risk Level:** MEDIUM  
**Gate:** FAIL — two MEDIUM findings.

## Summary

- CRITICAL: 0
- HIGH: 0
- MEDIUM: 2
- LOW: 0

## Findings

### 1. MEDIUM — Client timestamps can bypass evidence supersession

**Category:** A04 — Insecure Design  
**Location:** [evidence_pg.go:96](/Users/augstar/macprovider-no-expiry/phase4-coordinator/internal/autotune/evidence_pg.go:96)  
**Introduced by this diff.**

**Failure scenario:** A later accepted submission reports a different `hardware.hardware_identity_hash` or `hardware.os_version`, but its `generated_at` equals or precedes the previous verified job’s timestamp. The supersession predicate ignores that submission because it requires `n.generated_at > j.generated_at`.

`generated_at` is provider supplied; ingestion validates its permitted time window but does not require it to increase ([hardware_evidence.go:499](/Users/augstar/macprovider-no-expiry/phase4-coordinator/internal/onboarding/hardware_evidence.go:499)). With unchanged chip/memory and an active old trust root, prior evidence remains admissible despite the reported change. Removing the TTL makes this retention indefinite.

**Exploitability:** Authenticated provider credential holder.  
**Blast radius:** That provider can retain its old admission ceiling and verified-hardware observation after reporting changed hardware or OS.

**Fix:** Define submission order using coordinator-owned ingestion order, including ties, rather than `generated_at`. Use that order consistently for supersession and candidate selection. The existing server-assigned job ID provides a practical ordering:

```sql
-- Replacement supersession ordering:
AND n.id > j.id

-- Candidate selection:
ORDER BY j.id DESC
```

Keep the existing hardware/profile/trust joins. Existing tests cover strictly increasing timestamps, not equal or decreasing timestamps.

### 2. MEDIUM — Removing a config approval does not withdraw release-derived approval

**Category:** A01 — Broken Access Control  
**Location:** [SPEC-049:423](/Users/augstar/macprovider-no-expiry/specs/SPEC-049-operator-constrained-privacy-class.md:423)  
**Supporting implementation:** [privacy_authority.go:794](/Users/augstar/macprovider-no-expiry/phase4-coordinator/internal/relayblind/privacy_authority.go:794)

**Failure scenario:** The amended specification says removing an `approved_code_identities` entry withdraws approval. If signed release metadata also approves that identity, deletion instead removes the configuration override and permits the release-derived approval to apply. The identity remains eligible for privacy enrollment and serving.

**Pre-existing:** Release-metadata fallback. **Introduced:** The new claim that config-entry removal is a withdrawal mechanism.

**Exploitability:** Requires an operator withdrawal and matching retained release metadata.  
**Blast radius:** Providers running the supposedly withdrawn identity can remain approved for privacy serving.

**Fix:** State that deletion withdraws only configuration-exclusive approvals. For identities also approved by release metadata, require the existing deny list or a retained version-mismatching override. The deny list already takes precedence:

```go
cfg.PrivacyClass.DeniedCodeCDHashes = append(
    cfg.PrivacyClass.DeniedCodeCDHashes,
    withdrawnCDHash,
)
```

Existing `TestReleaseDerivedApprovalAndOverrides` confirms release approval without config and deny-list precedence.

## Other Security Controls

- **Revocation:** Cached fallback re-verifies signatures, signer identity, generation and anchor digests. Rollback and revoked-set regression cannot remove an anchored revocation. Cache/anchor integrity failures still propagate.
- **Discovery:** Sequence monotonicity, same-sequence equivocation and signed-policy protections remain. Bootstrap freeze residuals are explicitly recorded in SPEC-020.
- **Trusted pools:** Creator status/version/environment checks, missing on-call records, production gates, lifecycle/member revocations and signed policy windows still constrain routing.
- **OWASP coverage:** A01/A04 findings above; A02/A08 cryptographic and integrity checks retained; A03 query parameters remain bound; A05/A07 no additional configuration/authentication finding; A09 status warnings retained; A10 origin/redirect checks retained. A06 remains unverified by a vulnerability database audit.

## Validation

Passed offline using the cached Go 1.26.6 executable:

- Autotune: `TestLatestVerifiedRequiresCurrentVerifiedHardwareTuple`
- Relayblind: `TestReleaseDerivedApprovalAndOverrides`, `TestApprovalWithoutExpiryStaysApproved`
- Four existing Python tests covering release approval, config override, identity emission and expiry-option removal.

The initial Go invocation failed toolchain checksum verification with `GOSUMDB=off`; invoking the cached toolchain directly passed.

Workflow/script secret scanning covered both diff endpoints and additions across all nine commits: no credential-literal signatures found. No dependency manifests changed. Dependency vulnerability audit was not run because network access was forbidden. Swift and hardware checks were not run.

## Security Checklist

- [x] Secrets scan completed; no credential literals detected
- [x] Input and supersession handling reviewed
- [x] Parameterized SQL retained
- [x] Authentication, authorization and withdrawal reviewed
- [x] Replay and revocation-cache integrity reviewed
- [ ] Dependency vulnerability audit completed
- [ ] MEDIUM findings resolved

C/H/M/L = 0/0/2/0
