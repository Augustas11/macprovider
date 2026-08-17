# Architect SPEC audit — SPEC-008 v0.6.0 (Phase 3 live MDA / Phase 4 boundary)

REJECT. §7.3/§7.9/§7.10 mostly carry the correct observe/enforce boundary, but the spec still has current, non-historical prose saying `hardware` is not emitted by shipped code, and §13.3 still describes tier-blind buyer disclosure even though R8 code/tests are tier-aware.

## Analysis

**MEDIUM 1 — Stale global spec prose still says hardware is not emitted.**

The new §7.3 text is correct: `hardware` is minted only by live MDA and does not flip routing enforcement at [specs/SPEC-008-tier2.md:1905](specs/SPEC-008-tier2.md:1905), [specs/SPEC-008-tier2.md:1911](specs/SPEC-008-tier2.md:1911), and [specs/SPEC-008-tier2.md:1913](specs/SPEC-008-tier2.md:1913). §7.9 also correctly defines live MDA as a shipped Phase 3 observe path at [specs/SPEC-008-tier2.md:2508](specs/SPEC-008-tier2.md:2508).

But other current sections still say the hardware tier is aspirational or not emitted: [specs/SPEC-008-tier2.md:347](specs/SPEC-008-tier2.md:347), [specs/SPEC-008-tier2.md:643](specs/SPEC-008-tier2.md:643), [specs/SPEC-008-tier2.md:690](specs/SPEC-008-tier2.md:690), and [specs/SPEC-008-tier2.md:2838](specs/SPEC-008-tier2.md:2838). That contradicts the R8 code path where live MDA calls `SetMDAProof` and publishes `AttestationTierHardware` at [phase4-coordinator/internal/mdm/live_mda.go:1047](phase4-coordinator/internal/mdm/live_mda.go:1047), [phase4-coordinator/internal/mdm/live_mda.go:1054](phase4-coordinator/internal/mdm/live_mda.go:1054), and [phase4-coordinator/internal/pool/provider.go:1717](phase4-coordinator/internal/pool/provider.go:1717).

**MEDIUM 2 — §13.3 disclosure text is stale relative to current code.**

§13.3 says buyer-visible `hardware_attestation` is derived from status without consulting `attestation_tier`, and that an all-`self_signed` pool discloses `"all"`: [specs/SPEC-008-tier2.md:3713](specs/SPEC-008-tier2.md:3713), [specs/SPEC-008-tier2.md:3717](specs/SPEC-008-tier2.md:3717), [specs/SPEC-008-tier2.md:3720](specs/SPEC-008-tier2.md:3720), [specs/SPEC-008-tier2.md:3728](specs/SPEC-008-tier2.md:3728).

Current R8 code does the opposite on the metadata surface the gateway consumes: only `AttestationStatusAttested && AttestationTierHardware` counts positive at [phase4-coordinator/internal/buyer/server.go:973](phase4-coordinator/internal/buyer/server.go:973) and [phase4-coordinator/internal/buyer/server.go:983](phase4-coordinator/internal/buyer/server.go:983), and the gateway maps that metadata into buyer disclosure at [phase5-gateway/internal/router/disclosure.go:506](phase5-gateway/internal/router/disclosure.go:506) and [phase5-gateway/internal/router/disclosure.go:509](phase5-gateway/internal/router/disclosure.go:509). The test explicitly asserts self-signed status-attested providers must not count as attested on that surface at [phase4-coordinator/internal/buyer/server_test.go:950](phase4-coordinator/internal/buyer/server_test.go:950) and [phase4-coordinator/internal/buyer/server_test.go:997](phase4-coordinator/internal/buyer/server_test.go:997).

The conformance note repeats the stale “forward item” framing at [audits/2026-08-17/CONFORMANCE_PHASE3_LIVE_MDA.md:22](audits/2026-08-17/CONFORMANCE_PHASE3_LIVE_MDA.md:22) and [audits/2026-08-17/CONFORMANCE_PHASE3_LIVE_MDA.md:24](audits/2026-08-17/CONFORMANCE_PHASE3_LIVE_MDA.md:24). It should not claim Phase 3 fixed §13.3, but it also should not claim the gap remains if the already-shipped code path is tier-aware.

No C/H/M issue found with the observe/enforce boundary itself: §7.9 says Phase 3 does not flip `require_attestation` at [specs/SPEC-008-tier2.md:2515](specs/SPEC-008-tier2.md:2515), live-MDA failures remain non-blocking at [specs/SPEC-008-tier2.md:2586](specs/SPEC-008-tier2.md:2586), and §7.10 keeps `require_attestation` status-based, including `self_signed`, at [specs/SPEC-008-tier2.md:2608](specs/SPEC-008-tier2.md:2608). Code matches that at [phase4-coordinator/internal/config/config.go:901](phase4-coordinator/internal/config/config.go:901), [phase4-coordinator/internal/mdm/live_mda.go:64](phase4-coordinator/internal/mdm/live_mda.go:64), and [phase4-coordinator/internal/buyer/server.go:6655](phase4-coordinator/internal/buyer/server.go:6655).

## Root Cause

The v0.6 edit updated the local §7.3/§7.9/§7.10 slice but did not sweep older foundational definitions, roadmap prose, and §13.3 shipped-reality text. Separately, §13.3 appears to describe pre-#759 tier-blind disclosure behavior while the current code and tests are tier-aware.

## Recommendations

1. **Update stale global hardware-tier prose** - low effort - high spec-honesty impact. Replace “aspirational / not emitted by shipped code” in §1.1, §3, the attested-provider definition, and §9.2 with “not shipped default; emitted only by live MDA observe path when enabled.”

2. **Reconcile §13.3 with current code without attributing the fix to Phase 3** - medium effort - high disclosure impact. Either document that buyer disclosure is already hardware-tier-gated by current coordinator metadata, or explicitly narrow any remaining gap to a different surface. Update the conformance note line 24 accordingly.

3. **Keep §7.10’s enforcement caveat unchanged** - low effort - prevents overclaim. `require_attestation` still gates on status `attested`, not `attestation_tier=hardware`; that boundary is accurate.

## Trade-offs

| Option | Pros | Cons |
|--------|------|------|
| Patch only §7 stale prose | Fast; fixes “hardware never emitted” contradiction | Leaves §13.3/code mismatch unresolved |
| Patch §7 prose and §13.3 | Produces coherent spec/code truth | Requires careful wording to avoid implying Phase 3 changed buyer disclosure |
| Keep §13.3 as forward item | Avoids overclaiming Phase 3 | Incorrect against current R8 code/tests if those are authoritative |

## References

- [specs/SPEC-008-tier2.md:1905](specs/SPEC-008-tier2.md:1905) - Correct v0.6 `hardware` tier definition.
- [specs/SPEC-008-tier2.md:2515](specs/SPEC-008-tier2.md:2515) - Correct Phase 3 non-goals.
- [specs/SPEC-008-tier2.md:2597](specs/SPEC-008-tier2.md:2597) - Correct Phase 4 boundary.
- [specs/SPEC-008-tier2.md:690](specs/SPEC-008-tier2.md:690) - Stale “not emitted” claim.
- [specs/SPEC-008-tier2.md:3717](specs/SPEC-008-tier2.md:3717) - Stale tier-blind disclosure claim.
- [phase4-coordinator/internal/buyer/server.go:983](phase4-coordinator/internal/buyer/server.go:983) - Current code requires hardware tier for positive attestation metadata.
- [phase5-gateway/internal/router/disclosure.go:509](phase5-gateway/internal/router/disclosure.go:509) - Gateway maps that metadata into buyer disclosure.
- [audits/2026-08-17/CONFORMANCE_PHASE3_LIVE_MDA.md:24](audits/2026-08-17/CONFORMANCE_PHASE3_LIVE_MDA.md:24) - Conformance note repeats stale forward-item framing.

Tally: CRITICAL 0 / HIGH 0 / MEDIUM 2 / LOW 0 / INFO 0  
Verdict: REJECT
