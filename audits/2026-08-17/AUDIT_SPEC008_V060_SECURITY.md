# Security Review Report

**Scope:** `specs/SPEC-008-tier2.md` v0.6 changelog, §7 intro, §7.3, §7.9, §7.10, AC-C-11..18; skimmed `audits/2026-08-17/CONFORMANCE_PHASE3_LIVE_MDA.md`  
**Risk Level:** LOW

## Summary

- Critical Issues: 0
- High Issues: 0
- Medium Issues: 0
- Low Issues: 1
- Info: 0

## Low Issues

### 1. Stale Historical/Cross-Reference Wording Can Confuse Hardware-Tier Semantics

**Severity:** LOW  
**Category:** A04 Insecure Design / spec-honesty boundary  
**Location:** [specs/SPEC-008-tier2.md](/Users/augstar/macprovider-attest-phase3-audit/specs/SPEC-008-tier2.md:89), [specs/SPEC-008-tier2.md](/Users/augstar/macprovider-attest-phase3-audit/specs/SPEC-008-tier2.md:2154)  
**Exploitability:** Documentation/operator misunderstanding; not directly exploitable.  
**Blast Radius:** Could mislead future implementers about whether `hardware` is still impossible or whether static auth-token MDA can publish it.

**Issue:** Current normative v0.6 text is honest: §7.3 says live MDA is the only `hardware` publisher, static auth-token MDA must not publish `hardware`, Phase 3 does not flip `require_attestation`, and §13.3 disclosure remains a forward item. However, older wording still says “hardware is never emitted” in the v0.4 changelog, and §7.4a says the stronger `hardware` tier remains “§7.4’s reserved path.” That is stale/confusing after v0.6.

**Remediation:**
```markdown
<!-- BAD -->
the shipped WS handler labels only the SE path — so `hardware` is never emitted

<!-- GOOD -->
in v0.4 shipped code, `hardware` was never emitted; v0.6 changes this only for
the live MicroMDM observe path (§7.9), while static auth-token MDA remains non-publishing.
```

```markdown
<!-- BAD -->
The stronger `hardware` tier via `apple-managed-device-attestation-acme-v1`
remains §7.4's reserved path.

<!-- GOOD -->
The stronger `hardware` tier is published only by the live MicroMDM observe path
(§7.9); a static `apple-managed-device-attestation-acme-v1` auth token may yield
status `attested` but must not publish `hardware` by itself.
```

## Positive Checks

- §7.3 no longer normatively claims `hardware` is never emitted: live MDA can mint `attestation_tier=hardware` only through §7.9.
- §7.9 correctly states Phase 3 non-goals: no `require_attestation` flip, no buyer `hardware_attestation` disclosure fix, no hardware-gated routing.
- §7.10 correctly preserves the Phase 4 boundary and states `require_attestation` still gates on status `attested`, including `self_signed`.
- §13.3 disclosure gap is explicitly retained as a known forward item.
- Conformance audit does not overclaim Phase 4: it flags §13.3 and `require_attestation` self-signed admission as forward/non-blocking items.

## Security Checklist

- [x] No hardcoded secrets found in reviewed spec/audit files; grep hits were terminology only.
- [x] Input validation/injection: not applicable to document-only scope.
- [x] Authentication/authorization boundary reviewed for spec claims.
- [x] Observe vs enforce boundary reviewed.
- [x] Dependency audit: not applicable to reviewed document-only scope; repo manifests exist but no dependency change is in scope.

Tally: CRITICAL 0 / HIGH 0 / MEDIUM 0 / LOW 1 / INFO 0  
Verdict: APPROVE
