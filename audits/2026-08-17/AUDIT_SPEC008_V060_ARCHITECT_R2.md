# SPEC-008 v0.6.0 — Architect R2 (post honesty-fix re-audit)

**Date:** 2026-08-17
**Worktree:** `/Users/augstar/macprovider-attest-phase3-audit`
**Lane:** `omc ask codex --agent-prompt architect`
**Artifact:** `audits/2026-08-17/codex-spec-architect-r2-artifact.md` → `.omc/artifacts/ask/…T10-37-13-580Z.md`
**Out:** `audits/2026-08-17/lane-spec-architect-r2.out`

## Summary
M1 is closed in the re-read scope: v0.6 now consistently says `hardware` is minted only by live MicroMDM `SetMDAProof`, not SE or static auth-token MDA. M2 is not fully closed: §13.3 is fixed, but stale current prose in §4.3 and §7.7 still describes status-only / tier-blind disclosure behavior.

## Analysis
**Residual M2 — MEDIUM: stale status-only attestation disclosure prose remains.**

[specs/SPEC-008-tier2.md](/Users/augstar/macprovider-attest-phase3-audit/specs/SPEC-008-tier2.md:859) still says an SE-attested pool discloses `"all"`. That contradicts the fixed §13.3 rule that an all-`self_signed` pool discloses `"unsupported"`: [specs/SPEC-008-tier2.md](/Users/augstar/macprovider-attest-phase3-audit/specs/SPEC-008-tier2.md:3733), [specs/SPEC-008-tier2.md](/Users/augstar/macprovider-attest-phase3-audit/specs/SPEC-008-tier2.md:3747).

[specs/SPEC-008-tier2.md](/Users/augstar/macprovider-attest-phase3-audit/specs/SPEC-008-tier2.md:2354) also describes `/v1/models` `state: "all"` as “every counted provider is `attested`”, and [specs/SPEC-008-tier2.md](/Users/augstar/macprovider-attest-phase3-audit/specs/SPEC-008-tier2.md:2358) describes `"unsupported"` as every counted provider is “non-attested”. Current code is no longer status-only: [phase4-coordinator/internal/buyer/server.go](/Users/augstar/macprovider-attest-phase3-audit/phase4-coordinator/internal/buyer/server.go:983) requires both `AttestationStatusAttested` and `AttestationTierHardware`.

Test evidence confirms the intended #759 behavior: a status-attested `self_signed` provider lands in the unsupported bucket, not the attested bucket: [phase4-coordinator/internal/buyer/server_test.go](/Users/augstar/macprovider-attest-phase3-audit/phase4-coordinator/internal/buyer/server_test.go:950), [phase4-coordinator/internal/buyer/server_test.go](/Users/augstar/macprovider-attest-phase3-audit/phase4-coordinator/internal/buyer/server_test.go:997).

## Root Cause
The honesty fix updated the new v0.6 changelog, §7.9/§7.10 boundary text, and §13.3 trust note, but did not sweep older current explanatory sections that still describe the pre-#759 tier-blind aggregate as current behavior.

## Recommendations
1. Fix §4.3 line 859 to say an SE-attested/self-signed-only pool discloses `"unsupported"`, not `"all"` - low effort - closes the remaining buyer-visible contradiction.
2. Fix §7.7 lines 2352-2358 so `all` / `partial` / `unsupported` are defined by hardware-tier-positive vs negative counted providers, not raw `attested` status - low effort - aligns `/v1/models` prose with code and §13.3.
3. Optionally tense-scope the v0.4 changelog at lines 123-126 as historical pre-#759 behavior or add a v0.6 correction note there - low effort - prevents future readers from treating stale changelog prose as current.

## Trade-offs
| Option | Pros | Cons |
|--------|------|------|
| Patch only §4.3 and §7.7 | Minimal, directly closes current contradictions | Leaves historical changelog wording mildly confusing |
| Also tense-scope v0.4 changelog | Fully prevents stale-reader confusion | Slightly more spec churn in historical notes |

## References
- [specs/SPEC-008-tier2.md](/Users/augstar/macprovider-attest-phase3-audit/specs/SPEC-008-tier2.md:8) - v0.6 changelog correctly scopes hardware to live MDA.
- [specs/SPEC-008-tier2.md](/Users/augstar/macprovider-attest-phase3-audit/specs/SPEC-008-tier2.md:1922) - §7.3 says only live MDA publishes hardware tier.
- [specs/SPEC-008-tier2.md](/Users/augstar/macprovider-attest-phase3-audit/specs/SPEC-008-tier2.md:2487) - AC-C-13 single publisher.
- [specs/SPEC-008-tier2.md](/Users/augstar/macprovider-attest-phase3-audit/specs/SPEC-008-tier2.md:2526) - §7.9 non-goal avoids claiming disclosure closure.
- [specs/SPEC-008-tier2.md](/Users/augstar/macprovider-attest-phase3-audit/specs/SPEC-008-tier2.md:2621) - §7.10 keeps Phase 3 from flipping enforcement.
- [specs/SPEC-008-tier2.md](/Users/augstar/macprovider-attest-phase3-audit/specs/SPEC-008-tier2.md:3733) - §13.3 fixed hardware-tier-gated counting.
- [phase4-coordinator/internal/buyer/server.go](/Users/augstar/macprovider-attest-phase3-audit/phase4-coordinator/internal/buyer/server.go:983) - code requires `attested` + `hardware`.

Tally: C=0, H=0, M=1.  
Verdict: REJECT.
