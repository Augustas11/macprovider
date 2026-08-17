# SPEC-008 v0.6.0 — Architect R3 (FINAL gate)

**Date:** 2026-08-17  
**Worktree:** `/Users/augstar/macprovider-attest-phase3-audit`  
**Lane:** `omc ask codex --agent-prompt architect`  
**Artifact:** `audits/2026-08-17/codex-spec-architect-r3-artifact.md` → `.omc/artifacts/ask/…T10-41-13-421Z.md`  
**Out:** `audits/2026-08-17/lane-spec-architect-r3.out`

## Summary

R3 passes. No remaining current-tense SPEC-008 claim that `hardware` is never emitted. R2 residual §4.3 / §7.7 now align with #759 hardware-tier-gated counting and §13.3. §7.9 / §7.10 observe-vs-enforce boundaries remain honest.

## Analysis

No C/H/M findings.

- **Hardware emission:** v0.6 scopes `hardware` to live MicroMDM observe only (not SE / static auth-token MDA). Prior “never emitted” language is historical (v0.4 / Phase 2) only.
- **Disclosure consistency:** §4.3 and §7.7 match §13.3 / #759 — all-`self_signed` pools disclose/count as `"unsupported"`, not `"all"`. `attested` status alone is insufficient.
- **Observe vs enforce:** §7.9 non-goals and §7.10 keep Phase 3 from flipping `require_attestation`, changing buyer disclosure via live MDA, or requiring hardware for routing. Phase 4 remains the enforcement gate.

## Root Cause

Prior R2 MEDIUM was stale prose in older explanatory sections; the applied residual SPEC sweep closed those locations for this scoped gate.

## Recommendations

1. No blocking recommendation. Ship SPEC-008 v0.6.0 R3 text as-is for this gate.

## References

- `specs/SPEC-008-tier2.md` §4.3 — self-signed pools disclose `unsupported`
- `specs/SPEC-008-tier2.md` §7.7 — hardware-tier-gated state enum
- `specs/SPEC-008-tier2.md` §13.3 — #759 trust note
- `phase4-coordinator/internal/buyer/server.go` — `AttestationStatusAttested && AttestationTierHardware`
- `phase4-coordinator/internal/buyer/server_test.go` — #759 regression coverage

Tally: C=0, H=0, M=0.  
Verdict: APPROVE.
