# SPEC-008 v0.6.0 SPEC-audit FINDINGS (architect + security)

**Date:** 2026-08-17  
**Worktree:** `/Users/augstar/macprovider-attest-phase3-audit`  
**Scope:** SPEC text only (v0.6 changelog, §7 intro, §7.3, §7.9, §7.10, AC-C-11…18; skim CONFORMANCE)

## Lane tallies (pre-fix)

| Lane | CRITICAL | HIGH | MEDIUM | LOW | INFO | Verdict |
|------|----------|------|--------|-----|------|---------|
| Architect | 0 | 0 | 2 | 0 | 0 | **REJECT** |
| Security | 0 | 0 | 0 | 1 | 0 | **APPROVE** |

Artifacts:
- `audits/2026-08-17/AUDIT_SPEC008_V060_ARCHITECT.md`
- `audits/2026-08-17/AUDIT_SPEC008_V060_SECURITY.md`
- `audits/2026-08-17/lane-spec-architect.out` → `.omc/artifacts/ask/…T10-29-34-051Z.md`
- `audits/2026-08-17/lane-spec-security.out` → `.omc/artifacts/ask/…T10-31-28-051Z.md`

## Findings (C/H/M)

### M1 — Stale global prose still said `hardware` is never emitted (Architect MEDIUM; Security LOW)

**Locations (pre-fix):** §1.1, §3 Attested-provider definition, §7.4a reserved-path aside, §9.2 Phase 2 roadmap; historical v0.4 changelog present-tense “never emitted”.

**Issue:** v0.6 §7.3 correctly defines live MDA as the only `hardware` publisher, but older current prose still said aspirational / not emitted by shipped code — contradicts §7.9 and `SetMDAProof`.

**Fix applied (SPEC text only):**
- §1.1 / §3 Pillar C + Attested-provider: live MDA observe MAY mint `hardware` when enabled.
- §7.4a: static auth-token MDA MUST NOT publish `hardware`; live MDA (§7.9) is the publisher.
- §9.2: Phase 2 did not emit `hardware`; v0.6 Phase 3 live MDA may, without flipping `require_attestation`.
- v0.4 changelog: historical “was never emitted then”; v0.6 cross-ref.

### M2 — §13.3 still described tier-blind disclosure (Architect MEDIUM)

**Locations (pre-fix):** §13.3 trust-overstatement note + counting basis; §7.10.4 / §7.9 non-goals / CONFORMANCE “forward item” framing.

**Issue:** Spec claimed buyer `hardware_attestation` aggregates without consulting `attestation_tier`, so all-`self_signed` → `"all"`. Code/tests (`attestationStateForProviders`, #759) already require `AttestationTierHardware` for positive counts. Conformance repeated the stale gap claim. Phase 3 must not be credited with closing that gate.

**Fix applied (SPEC text only):**
- §13.3: document #759 hardware-tier-gated counting; all-`self_signed` → `"unsupported"`; field-name polish remains forward.
- §7.9 non-goals / §7.10.4: Phase 3 MUST NOT claim live MDA closed the counting gap; #759 is independent/pre-v0.6.
- CONFORMANCE gaps line updated accordingly.
- v0.6 changelog honesty-sweep bullet.

## Architect R2 (post R1 honesty fix)

| Lane | CRITICAL | HIGH | MEDIUM | LOW | INFO | Verdict |
|------|----------|------|--------|-----|------|---------|
| Architect R2 | 0 | 0 | 1 | 0 | 0 | **REJECT** |

Artifact: `AUDIT_SPEC008_V060_ARCHITECT_R2.md` / `lane-spec-architect-r2.out` → `…T10-37-13-580Z.md`.

- **M1:** closed.
- **M2 (§13.3):** closed in that section.
- **Residual M2 (new MEDIUM):** §4.3 still said SE-attested pool discloses `"all"`; §7.7 still defined `"all"`/`"unsupported"` by raw `attested` status. Contradicts fixed §13.3 + `attestationStateForProviders` (#759).

**Fix applied after R2 REJECT (SPEC text only):**
- §4.3: tokenless **and** SE/all-`self_signed` pools disclose `"unsupported"`; cite #759 / §13.3.
- §7.7: `state` enum positive = attested **and** hardware tier; `"unsupported"` includes all-`self_signed`.
- v0.4 changelog §13.3/§7.6 bullet: tense-scoped as historical pre-#759; point to post-#759 / v0.6 behavior.

## Architect R3 (FINAL gate, post residual fix)

| Lane | CRITICAL | HIGH | MEDIUM | LOW | INFO | Verdict |
|------|----------|------|--------|-----|------|---------|
| Architect R3 | 0 | 0 | 0 | 0 | 0 | **APPROVE** |

Artifact: `AUDIT_SPEC008_V060_ARCHITECT_R3.md` / `lane-spec-architect-r3.out` → `…T10-41-13-421Z.md`.

- **M1:** closed (no current-tense “never emitted”).
- **M2 / residual §4.3 / §7.7:** closed; consistent with §13.3 / #759.
- **§7.9 / §7.10:** observe vs enforce honest; no new C/H/M.
- No further SPEC edits after R3.

## Residual (explicit carry)

| Item | Severity | Notes |
|------|----------|-------|
| Buyer field name `hardware_attestation` | LOW / forward | Name still reads as hardware trust; rename / richer tier-aware states remain coordinated follow-up — not a Phase 3 live-MDA claim. |
| Historical changelog “aspirational MDA” phrasing (v0.4 / earlier) | INFO | Left as historical record where tense is past or changelog-scoped (R2 also historicized the tier-blind disclosure bullet). |
| `require_attestation` admits `self_signed` | intentional | §7.6 / §7.10.3 unchanged; Phase 4 / future hardware-gated predicate. |
| Pearl live E2E | ops forward | CONFORMANCE / runbook; not a SPEC honesty bug. |

## Observe / enforce boundary (lanes agree — no C/H/M)

- Phase 3 does **not** flip `require_attestation`.
- Live MDA failures remain non-blocking while `require_attestation: false`.
- Phase 3 does **not** claim to fix buyer disclosure via live MDA shipping.
- §7.3 no longer claims hardware is never emitted (post-fix globally consistent).
