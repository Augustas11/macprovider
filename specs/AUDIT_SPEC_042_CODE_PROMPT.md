# AUDIT SPEC-042 — Code / Consistency Lane

You are auditing a specification document, not code. The subject is
`specs/SPEC-042-pool-control-plane.md` (a Layer 2 "Trusted Pool / subnet"
control-plane manifest SPEC), currently at `draft-skeleton` status.

Read first:
- `specs/SPEC-042-pool-control-plane.md` (subject)
- `specs/SPEC-041-relay-blind-request-encryption.md` (sibling, format + Layer 3 boundary)
- `specs/SPEC-040-wallet-native-buyer-sessions.md` (dependency)
- `specs/AUTHORITY.json` and `specs/CONFORMANCE.json` (registration surfaces)

## Verified ground-truth facts you may rely on

- `pool_id` currently appears ZERO times in `phase4-coordinator/internal` and
  `phase5-gateway/internal`. No pool manifest or registry exists in-tree.
- Live prod coordinator (`coordinator.malibu.tech`, v1.8.95) as of 2026-08-18:
  `require_attestation` and `require_encrypted_leg` are NOT set in base config
  or the Pearl overlay (so both default to false / fail-open);
  `verified_model_settlement_mode: enforce`; `tier2.mdm.live_mda_enabled: true`
  (observe-only, non-gating); `payout.enabled: false`.

## Your lane: internal consistency and requirement quality

Assess and report findings on:

1. **Factual accuracy against the codebase.** Do the SPEC's claims about
   existing primitives match reality? Verify by reading actual code where the
   SPEC references it: global provider snapshot routing, `AdmissionManager.Reject`
   TTL semantics, SE blob `sipEnabled`/`secureBootEnabled` unchecked fields,
   v0.4 receipt tuple, settlement modes, guarded payout runner. Flag any claim
   that is wrong, stale, or unverifiable.
2. **Requirement testability.** Is each SPEC-042-R00N written so a conformance
   test could pass/fail it deterministically? Flag MUST/MUST NOT statements that
   are too vague to test, or that hide multiple requirements in one clause.
3. **Internal contradictions.** Any requirement that conflicts with another, or
   with the dependency/authority section, or with the out-of-scope list.
4. **Dependency/authority correctness.** Are the `depends_on` specs and the
   authority-boundary statements (§2) accurate about what each cited SPEC owns?
   Flag any boundary claim that misstates another SPEC's ownership.
5. **Format conformance.** JSON frontmatter completeness vs. SPEC-041,
   requirement-ID scheme, changelog, gap block. Note anything that would fail
   the spec-index / governance tooling.
6. **Completeness gaps for a skeleton→v0.1.** What load-bearing requirement is
   missing entirely (not merely marked Open)?

## Output format

For each finding: severity (CRITICAL / HIGH / MEDIUM / LOW / INFO), a one-line
title, the specific location (file + section/line), concrete rationale, and a
concrete fix. End with an overall verdict line and counts:
`VERDICT: <PASS|PARTIAL|FAIL> — C:<n> H:<n> M:<n> L:<n> I:<n>`.
The promotion bar is 0 Critical, 0 High, 0 Medium. Do not soften findings to
hit the bar; report what you find. Note explicitly that `(Open)`-marked design
decisions are acceptable at skeleton stage and should be LOW/INFO unless the
open item makes a stated MUST untestable or contradictory.
