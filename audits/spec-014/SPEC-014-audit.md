# the current SPEC-014 draft — Audit Report

**Audited:** the current SPEC-014 draft (specs/SPEC-014-provider-portal.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 1 of N
**Date:** 2026-06-21
**Total findings:** 0 CRITICAL / 2 HIGH / 1 MEDIUM / 2 MINOR / 0 QUESTION

---

## Executive summary

Verdict: **ready to lock after the two HIGH findings are closed; no structural revision is required.**

The current SPEC-014 draft preserves the load-bearing product and security boundaries. I found no degraded portal
mode under `auth.require_provider_tokens = false`, no browser-callable operator-keyed endpoint used as a data
source, no fiat / Stripe / withdrawal UX, no v0.1 multi-Mac aggregation surface, no provider token rotation or
remove-machine UI, and no portal ingestion of autotune output.

The remaining blockers are auditability gaps, not architecture gaps. Surface B.2's required `macprovider-cli status`
setup step has no direct acceptance criterion, and one deferred self-signed-binary row cites Q10 even though Q10 does
not own that field. Those are narrow fixes: add the missing AC and either remove the extra Q10 citation or expand Q10
deliberately.

The MEDIUM finding is layout ambiguity on mobile collapse behavior. The two MINOR findings are document hygiene:
the draft is far over the originating prompt's line budget and many table rows exceed the hard 120-column style rule.

## Category A: Deployment-mode gating + auth boundary

(no findings)

Notes: §2.3 / §2.4 fail closed on missing config and hard-disable the portal when
`require_provider_tokens` is false. AUTH-1 requires both `provider_id` and `provider_token`. AUTH-2 preserves the
403/404 non-enumeration boundary, and §8(b) enumerates `/poolz`, `/admin/blacklist`, `/admin/provisional`,
`/admin/promote`, `/admin/reject`, and `/admin/ledger` in the build-time grep.

## Category B: No-invention check (§5 tables exhaust §4 fields)

### B.1  Self-signed binary deferral points at an Open Q that does not own it   [HIGH]
Location: §4.1, line ~411-416; §5.3, line ~725; §9 / Q10, line ~1151-1163

The A.3 "Self-signed binary" row is deferred behind "Open Q5 and Open Q10" in §4.1 and its §5(c) row cites `Q5 + Q10`.
Q5 explicitly lists signing tier, but Q10 is scoped to the browser-local bridge for `/v1/health` and names A.4 plus
the A.3 model-load row; it does not list self-signed-binary detection.

Why it matters: the §5(c) table is the traceability control that prevents generic Open-Q buckets from hiding invented
data sources. A future implementer could read the Q10 citation as permission to source signing status from the local
health bridge even though the Open Q does not state that contract.

Recommendation: remove Q10 from the self-signed-binary deferral if Q5 is the only owning amendment, or explicitly add
self-signed-binary detection to Q10 with the source gap it is meant to resolve.

## Category C: Operator-keyed endpoint safety

(no findings)

Notes: `/poolz` and `/admin/*` appear only as forbidden paths, operator-only context, or grep targets. The portal's
actual coordinator read paths remain `/v1/pool/check` and `/providers/{id}/earnings`.

## Category D: No-fiat enforcement (Surface C)

(no findings)

Notes: Surface C renders C.1 aggregate credit cards and the static C.2 future-spec badge only. §8(a) explicitly
prohibits country selector, bank-link, account-type, Stripe, and payout-now UI.

## Category E: Single-machine enforcement

(no findings)

Notes: §8(f) includes the concrete prohibited strings from both bullets, including `"N machines"`, `"N/M"`, `"x3"`,
and `"machine grid"`. The remaining uses of "fleet" / "machines" are in scope-cut, Open-Q, or clean-room explanatory
text, not v0.1 rendered copy.

## Category F: Surface inventory completeness

(no findings)

Notes: A.4, B.4, C.3/C.4, D sub-cards, E rotation/removal, notifications, and installed-version comparison are
deferred rather than rendered. B.2 avoids the nonexistent `macprovider-cli install` verb.

## Category G: Acceptance criteria correctness

AC setup map checked:

- Surface A: mock `/v1/pool/check` and `/providers/{id}/earnings`; assert A.1 fields, manual refresh, four-state pill
  mapping, fake-clock stale transition, A.2 credit cards, A.3 unavailable row, no A.4 render.
- Surface B: render static setup surface and mocked GitHub Releases responses; assert FR-D1 cards, FR-D2 sizing card,
  install snippet, autotune CTA-only behavior, releases listing, rate-limit fallback, CORS/fetch failure, no B.4.
- Surface C: mock earnings JSON; assert three credit cards, exact future-spec badge, no fiat/Stripe/withdrawal controls,
  no C.3/C.4.
- Surface D: render placeholder with fetch mocked/spied; assert one placeholder, three Open-Q-linked bullets, zero
  network requests.
- Surface E: mock pool-check/config values; assert only `provider_id`, `tier`, `state`, and `coordinator_base_url`.
- Auth / field-source / privacy / Open-Q / single-machine ACs: use config-fetch fixtures, authenticated response
  fixtures, rendered-bundle grep, component-map enumeration, and forbidden-string grep.

### G.1  B.2 status verification step has no direct AC   [HIGH]
Location: §4.2, line ~476-495; §5.2, line ~698-700; §8(a), line ~838-855

Surface B.2 defines three numbered setup steps: install via `install.sh`, verify routable with `macprovider-cli status`,
and optionally copy `macprovider-cli autotune`. The per-surface ACs assert B.2 step 1 and B.2 step 3, but no AC asserts
that step 2 renders the `macprovider-cli status` snippet or cites SPEC-003 §4 / FR-C4.

Why it matters: B.2 step 2 is the provider's canonical local verification action. An implementation could omit it and
still pass the current AC checklist, even though §4 and §5 both require it.

Recommendation: add a B.2 AC that renders the setup steps and asserts the step-2 label, `macprovider-cli status`
copy-to-clipboard snippet, and SPEC-003 §4 / FR-C4 source citation.

## Category H: Open Q hygiene

(no findings)

Notes: Q1-Q11 each contain the required question, why, who-decides, spec-assumes, and portal-renders-if-unanswered
fields. Q5 covers the omnibus SPEC-002/SPEC-001 amendment list, Q10 covers browser-local CORS / port discovery /
HTTPS mixed-content, and Q11 keeps notification delivery in a future spec.

## Category I: Citation accuracy

(no findings)

Notes: Spot checks matched the locked specs: SPEC-001 §6.4 / §6.5, SPEC-002 §7.3 / §7.4 / §7.5, SPEC-003 §4 / §5 /
§6.2 / FR-C7 / FR-C9.x, SPEC-005 §1.3 / §2.1 / §2.11 / §11.4 / §11.5 / §13, SPEC-009 §2 / §6, and SPEC-013 §6 /
NFR-4 are cited in the right places. A live GitHub API header check also confirmed `X-RateLimit-Remaining` is exposed
via `Access-Control-Expose-Headers`.

## Category J: Layout + visual-token inheritance

### J.1  Mobile collapse behavior is looser than the originating prompt   [MEDIUM]
Location: §3, line ~317-323; BUILD_SPEC_014_PROMPT.md, line ~617-618; SPEC-009 §2, line ~20-44

The originating prompt requires mobile `< 720 px` to collapse the sidebar to a hamburger and describes that as
identical to SPEC-009. SPEC-014 instead allows "hamburger control OR hide gracefully" and says SPEC-009 mobile handling
is not inherited normatively.

Why it matters: "hide gracefully" is not a testable navigation contract. A reasonable implementer could hide the
sidebar without providing an equivalent navigation affordance, while still claiming the spec allowed it.

Recommendation: make SPEC-014 own the mobile rule explicitly: choose hamburger collapse, or define the exact acceptable
hidden-sidebar navigation behavior and add an AC for it. Avoid claiming inheritance from SPEC-009 for a breakpoint
SPEC-009 does not itself specify.

## Category K: Threats / privacy / data-handling

(no findings)

Notes: AUTH-1 requires in-memory token storage only. Surface C renders no buyer-identifying data. A.3 and B.3 CTAs are
copy-to-clipboard only, with no remote execution path.

## Category L: Phasing realism

(no findings)

Notes: Phase 1A is scaffolding + auth + deployment-mode + A.1/A.2/A.3. Phase 1B is Surface B + GitHub Releases. Phase
1C is Surface C + D placeholder + E + sidebar polish. Each phase ends with an IMPL audit gate.

## Category M: Anything else (length budget, style, dependencies, etc.)

### M.1  Draft is far above the originating line budget   [MINOR]
Location: whole file; current length 1288 lines; BUILD_SPEC_014_PROMPT.md, line ~856-866

The originating prompt set a 450-700 line target and warned that exceeding 750 lines likely means the draft is
restating upstream specs. The current draft is 1288 lines.

Why it matters: this does not break v0.1 correctness, but it makes future audit rounds slower and increases the chance
that redundant restatement drifts from locked upstream specs.

Recommendation: after the HIGH findings are closed, consider a non-normative compression pass that preserves §2, §4,
§5, §8, and §9 precision while trimming repeated rationale.

### M.2  Several table rows violate the hard 120-column style rule   [MINOR]
Location: §5.1-§5.4, line ~667-755; §10.1, line ~1185-1190

The draft contains many lines over 120 columns, especially in the §5 field-source tables and §10 dependency table.
The originating prompt set soft 100 and hard 120 columns.

Why it matters: this is a style and reviewability issue, not a contract failure. Long rows make diffs and citation
reviews harder, especially in the field-source tables that auditors inspect most.

Recommendation: reflow the widest table cells or split the tables into shorter rows only if doing so does not weaken
the exact field-source traceability.

## Out of scope for this audit

- Inspecting Darkbloom source (clean-room boundary; see Constraint #7)
- Rewriting the spec
- Implementing the portal
- Auditing SPEC-001 v1.3, SPEC-002 v1.3.5, SPEC-003 v0.9.2, SPEC-005 v0.3, SPEC-009 v0.1, SPEC-013 v0.3 themselves
- Re-litigating the "single-machine in v0.1" framing
- Re-litigating the "no fiat / no Stripe" framing
- Designing the v0.2 audit-response
- Choosing the portal host string (Open Q7)
