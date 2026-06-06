# Audit prompt — SPEC-010 v1.0 (narrow scope, round 1)

Operator-paste prompt to audit SPEC-010 v1.0
(`specs/SPEC-010-model-catalog.md`).

**Context — this is a fresh audit after a deliberate scope split.**
The previous SPEC-010 (versions 0.1, 0.2, 0.3) bundled capability
advertisement + warm swap + demand-pull cold wake + buyer catalog
visibility + operator state visibility into one ~1400-line spec. It
went through three audit rounds (preserved at
`specs/SPEC-012-source-audit-history.md`) and failed to converge:
each fix pass closed prior findings but the cross-feature surface
generated 12+ new findings per round. Diagnosis: the wide scope
touched 5 locked specs in interlocking ways; "additive-only" was
structurally optimistic.

**The split:**
- **SPEC-010 v1.0** (this audit) — capability advertisement only.
  Provider declares `supported_models[]`; coordinator stores it;
  optional `/v1/status` echo gated on opt-in. NO swap mechanism,
  NO `/v1/models` aggregation, NO new error envelopes, NO
  buyer-visible behavior change at any default.
- **SPEC-011** (outlined at `specs/SPEC-011-operator-pushed-warm-swap.md`)
  — operator-pushed warm swap via `macprovider models switch <id>`
  CLI + binary async load + heartbeat-driven `model_id` change.
  Closes the actual arm64golf operator pains #1 and #2.
- **SPEC-012** (deferred, preserved at `specs/SPEC-012-source.md`)
  — demand-pull cold-wake + buyer `/v1/models` aggregation + state
  visibility. Will be paired with an explicit SPEC-008 v0.4
  normative edit when ready.

This is round 1 of audit on SPEC-010 v1.0. Output goes into a fresh
file `specs/SPEC-010-audit.md` (not the SPEC-012-source-audit-history).

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Codex CLI session rooted at
`/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are auditing SPEC-010 v1.0, the Provider Model Catalog spec at
/Users/augstar/macprovider-poc/specs/SPEC-010-model-catalog.md.

**Important framing.** This is a deliberately narrow spec. The prior
SPEC-010 (versions 0.1, 0.2, 0.3) went through three audit rounds
without convergence because it bundled five features. The work was
split: SPEC-010 v1.0 contains only feature A (capability
advertisement). SPEC-011 (outline at
specs/SPEC-011-operator-pushed-warm-swap.md) handles the warm-swap
mechanism. SPEC-012 (deferred, source preserved at
specs/SPEC-012-source.md with audit history at
specs/SPEC-012-source-audit-history.md) will handle demand-pull
cold-wake + buyer-facing catalog visibility, paired with a SPEC-008
v0.4 normative edit.

**This means scope-expansion recommendations are MAJOR findings**,
not improvements. v1.0's value is its narrowness. A recommendation
to "also handle X" where X belongs to SPEC-011 or SPEC-012 is
scope creep and should be rejected as such. Recommendations to
*restrict further* are fine.

You are NOT here to validate, rewrite, or extend the spec. Find
problems, report them with specific severity and location, and let
the operator decide fixes. Output to a NEW file:
  /Users/augstar/macprovider-poc/specs/SPEC-010-audit.md

Format: structured audit report. Match the rigor and tone of prior
audit reports in this repo (specs/SPEC-008-audit.md,
specs/SPEC-012-source-audit-history.md).

## Severity definitions

- **CRITICAL** — would cause production failure on rollout, silent
  regression of locked-spec behavior, scope creep into a locked
  upstream spec (SPEC-001 v1.2.4, SPEC-002 v1.3.4, SPEC-004 v0.3.1,
  SPEC-008 v0.3), security regression, or violation of an L-1..L-6
  locked decision in §2.
- **MAJOR** — significant implementer confusion, predictable v1.1
  patch, unjustified thresholds, ambiguous failure semantics,
  back-compat semantics that don't actually hold up, OR scope
  expansion recommendations.
- **MINOR** — quality issues that don't block v1.0.
- **QUESTION** — unresolved design choice the spec couldn't decide.

## Critical constraints to honor while auditing

**1. Locked decisions (§2 L-1 through L-6) are READ-ONLY.** Findings
that recommend inverting any of L-1..L-6 are rejected unless they
show structural incompatibility with another locked constraint.

**2. SPEC-001 v1.2.4, SPEC-002 v1.3.4, SPEC-004 v0.3.1, SPEC-008
v0.3 are LOCKED.** Any v1.0 clause requiring a normative edit to
one of these is CRITICAL scope creep. v1.0 §6 lists companion
candidates (SPEC-001 v1.2.5, SPEC-002 v1.3.5) — those are
candidates, not normative SPEC-010 commitments.

**3. v1.0's narrow scope is itself a locked decision.** Features
explicitly out of scope per §8 (warm swap, demand-pull,
/v1/models aggregation, state field, error envelopes, recommended
catalog) MUST NOT be partially smuggled back in by audit
recommendations. If a finding's recommendation would require adding
any of those features, file the finding as MAJOR/CRITICAL
"requires scope expansion to SPEC-011/SPEC-012; v1.0 cannot fix
alone" — that's a legitimate finding shape, but the recommendation
must be "defer this concern to SPEC-011/SPEC-012," NOT "expand
v1.0 to handle it."

**4. Backward compat is structurally easier in v1.0** than in
SPEC-012-source's wide scope. With no `/v1/models` aggregation, no
state field, no error envelope changes, the L-1 byte-identical
claim should be straightforwardly verifiable. Audit it anyway — but
the expected outcome is PASS.

**5. The R-3.3.4 ModelKnown semantic change is the ONE subtle
back-compat point.** §3.3 acknowledges this: `seenModels` now
includes cold-supported models, which means `ModelKnown(B)` returns
`true` for a model some provider declared but no provider has warm.
The downstream effect at
phase4-coordinator/internal/buyer/server.go:1027 may be a 404→503
substitution. v1.0 §3.3.4 acknowledges this and gives operators an
escape (don't opt providers in to `supported_models` beyond
`[model_id]`). Audit this specifically: is the spec's
acknowledgement complete? Are there other ModelKnown callers that
could break in ways the spec doesn't anticipate?

**6. Clean-room.** Do NOT inspect d-inference (layr-labs) source.
NOASSERTION license.

## Required reading (in order)

1. `/Users/augstar/macprovider-poc/specs/SPEC-010-model-catalog.md`
   v1.0 — the spec under audit. Read all 9 sections and 15 ACs
   fully. Bias toward §3 (wire spec) and §4 (back-compat) most
   carefully.

2. `/Users/augstar/macprovider-poc/specs/SPEC-011-operator-pushed-warm-swap.md`
   v0.1 outline — to understand what v1.0 deliberately leaves to
   SPEC-011. Audit findings that recommend pulling SPEC-011 features
   back into v1.0 are scope creep.

3. `/Users/augstar/macprovider-poc/specs/SPEC-012-source-audit-history.md`
   — three rounds of audit on the wide-scope predecessor. Use as
   context for what v1.0 is deliberately avoiding. DO NOT
   re-litigate findings already PASSed in those rounds for surface
   that's still in v1.0 (R-3.1.1 through R-3.1.9 carry forward from
   SPEC-012-source v0.3 R-4.1.1 through R-4.1.9 with the round-3
   PASS verdict). DO probe whether the carry-forward is faithful.

4. `/Users/augstar/macprovider-poc/CLAUDE.md` — project conventions.

5. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   v1.2.4 — focus on §6.1, §6.2, §6.5 (auth frame). v1.0 §3.1
   extends the auth frame; verify the extension is truly additive.

6. `/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md`
   v1.3.4 — focus on §3 state machine (v1.0 makes ZERO state machine
   changes), §5 routing (v1.0 makes ZERO behavioral routing changes
   per R-3.4.1), §7.2 auth, §11 audit-log (v1.0 adds NO new event
   types). Verify these "zero change" claims.

7. `/Users/augstar/macprovider-poc/specs/SPEC-008-tier2.md` v0.3 —
   v1.0 §6.3 claims ZERO interaction. Verify: walk SPEC-008 §5.7
   /v1/models hash block; since v1.0 doesn't aggregate cold entries
   into /v1/models, the §5.7 question doesn't arise. Confirm.

8. `/Users/augstar/macprovider-poc/specs/SPEC-004-smart-router.md`
   v0.3.1 — v1.0 §6.5 claims NO normative behavior change. Verify
   §3.4 (router candidate filter) doesn't accidentally change
   dispatch outcomes for any pool configuration.

9. Code spot-checks:
   - `phase4-coordinator/internal/ws/messages.go` lines 8-57 (Hello,
     AuthRequest shapes — v1.0 §3.1 extends these)
   - `phase4-coordinator/internal/pool/provider.go` lines 50-88,
     174, 420-432, 464-477 (Provider struct, seenModels,
     ModelKnown, heartbeat path)
   - `phase4-coordinator/internal/buyer/server.go` lines 1027-1030
     (THE ModelKnown caller per v1.0 §3.3.4 note — verify the
     described 404→503 substitution behavior matches reality)
   - `phase5-gateway/internal/router/server.go` lines 143, 461-479,
     1309 (verify v1.0 §6.5 "no router behavior change" claim)
   - `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
     lines 18-28 (CLI shape v1.0 §3.6 extends)

10. `/Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md` —
    Entry 21 for context.

## Audit categories — work through each

### Category A: Locked-decision preservation (HIGHEST PRIORITY)

A.1  Walk each of L-1 through L-6 in §2. For each, find one or more
     clauses elsewhere in the spec that operationalize the lock. If
     a lock is stated in §2 but no concrete clause enforces it =
     MAJOR.

A.2  L-1 byte-identical: confirm AC-13 is achievable. Specifically,
     with no provider opted in, do §3.3.3 (status echo gating),
     §3.3.4 (seenModels expansion), §3.4 (router predicate), §3.5
     (config) all produce zero observable change? Walk every byte
     of /v1/status, /v1/models, log output, and routing decisions.
     If any path emits a new byte = CRITICAL.

A.3  L-2 permissionless: confirm no clause rejects a
     `supported_models` entry on semantic grounds (only length/
     shape per R-3.1.9 steps 1-3). If R-3.1.9 step 4 (duplicate
     check) accidentally rejects something that should be valid
     under L-2 = MAJOR.

A.4  L-3 one *active* model: v1.0 doesn't introduce any swap
     mechanism, so L-3 is trivially preserved. Verify there's no
     hidden assumption elsewhere in §3 that any of
     `supported_models` are simultaneously loadable. If found =
     MAJOR.

A.5  L-4 trivial Pillar A: confirm v1.0 truly does not touch
     SPEC-008 §5.7 hash block. The /v1/models response shape is
     unchanged in v1.0, so this should be trivially true. If you
     find any clause that surfaces cold-supported entries to
     buyers = CRITICAL scope creep.

A.6  L-5 no billing change: confirm zero SPEC-005 interaction.
     Should be trivially true; verify anyway.

A.7  L-6 F-1.5 trivially preserved: §3.1 adds `supported_models`
     and `publishes_supported_models` to the auth frame. Walk the
     SPEC-006 §F-1.5 invariants. Could `supported_models` content
     feed sticky derivation? It's NOT in the AAD inputs SPEC-008
     forbids, but check whether any caller derives a key from
     `Provider.SupportedModels`. If yes = CRITICAL.

### Category B: Wire-format correctness

B.1  R-3.1.1 through R-3.1.9 carry forward from SPEC-012-source
     v0.3 (R-4.1.1 through R-4.1.9) which was PASSed in round-3
     R2V-B3. Verify the carry-forward is faithful: numbering
     change (R-3.1.x vs R-4.1.x), text identity, no silent
     weakening. If a rule was tightened in SPEC-012-source v0.3 to
     close a round-2 finding and v1.0 reverted it = MAJOR.

B.2  R-3.1.9 validation order is the 5-step ordered list with
     exact `bad_request` reason strings. AC-8 tests multi-failure
     priority. Walk the validation order against actual JSON
     parsing realities: can step 1 (JSON type check) really fire
     before step 2 (per-entry length) for a malformed array? If
     the underlying JSON parser would surface a type error
     differently = MAJOR (the ordering wouldn't hold).

B.3  R-3.3.4 seenModels expansion: this is the load-bearing
     subtle change in v1.0. The spec acknowledges the 404→503
     substitution at buyer/server.go:1027. Audit:
       - Are there OTHER ModelKnown callers besides
         buyer/server.go:1027? Grep
         phase4-coordinator/internal/ for ModelKnown.
       - If yes, what does the semantic change to "known means
         declared-or-warm" mean for each caller?
       - If any caller's behavior changes in a way §3.3.4 doesn't
         acknowledge = MAJOR.

B.4  §3.3.3 status echo gating: when
     `PublishesSupportedModels == false`, the field MUST NOT
     appear. Verify the test in AC-11 actually exercises this
     (it does). Verify a SPEC-010-aware client that always-expects
     the field would still parse the legacy-shape response
     (Go default JSON unmarshalling tolerates missing fields).

B.5  R-3.5.1 default config = byte-identical: only one config key
     in v1.0 (`max_supported_models_per_provider`). Default 64.
     Does adding this config key require a coordinator config-file
     migration? If yes = MAJOR (operator burden).

### Category C: Backward compatibility

C.1  §4.1 legacy provider against v1.0 coordinator: walk every
     /v1/status field. Verify the synthesized
     `SupportedModels: [model_id]` produces no /v1/status
     difference (gated by PublishesSupportedModels=false default).
     If any path leaks = CRITICAL.

C.2  §4.2 v1.0 provider against legacy coordinator: verify that
     `phase4-coordinator/internal/ws/messages.go` does NOT use
     `json.NewDecoder().DisallowUnknownFields()` in the auth
     parse path. If it does = CRITICAL (provider auth would fail
     against legacy coordinator).

C.3  §4.3 buyer-visible behavior: ONE behavioral change is
     acknowledged — a 404→503 substitution for cold-supported
     requests when at least one provider opts in. Verify the
     existing "no eligible provider" path actually returns 503
     today, not some other code. If today's path returns 404
     itself, the substitution may be a no-op (good) or it may
     still differ in subtle ways. Probe.

C.4  R-3.3.4 caller analysis: separate from C.3, walk the FULL
     transitive effect of `ModelKnown(X) -> true when X is in
     supported_models but no provider has X warm`. Does this
     trigger any rate-limiting, sticky-affinity, or audit-log
     code path in unexpected ways? If yes = MAJOR.

### Category D: Companion-spec annotations

D.1  §6.1 SPEC-001 v1.2.5 candidate: are the CLI flag, env,
     config-file priorities precisely specified? Is the existing
     `--model` resolution priority actually "CLI > ENV > config"?
     Spot-check
     phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift.
     If §6.1 mis-cites it = MAJOR.

D.2  §6.2 SPEC-002 v1.3.5 candidate: claims "NO new event types"
     in audit-log. Verify v1.0 §3 truly introduces no event types
     anywhere. If any rule in §3 implies a log line that doesn't
     exist today = MAJOR.

D.3  §6.3 SPEC-008 v0.3 interaction NONE: verify by walking
     SPEC-008 §5.7 against v1.0's complete /v1/models surface
     (which is "unchanged"). Should be PASS.

D.4  §6.4 SPEC-005 interaction NONE: trivially PASS.

D.5  §6.5 SPEC-004 interaction: claims NO normative behavior
     change but adds the `req_model ∈ SupportedModels` predicate
     to the candidate filter. Verify that the predicate is
     informationally equivalent (under v1.0's no-swap-mechanism
     constraint) to the pre-SPEC-010 predicate. If there's any
     pool configuration where the new predicate would select a
     different candidate = MAJOR.

### Category E: AC coverage

E.1  Walk every R-3.x.y rule. For each, find at least one AC that
     exercises it. v1.0 has 15 ACs covering 9 rules
     (R-3.1.1..R-3.1.9 + R-3.3.1..R-3.3.4 + R-3.4.1 + R-3.5.1 +
     R-3.6.1..R-3.6.4). If any rule has no AC = MAJOR.

E.2  AC-8 multi-failure validation priority: tests step 2
     fires before step 3/5. Are there other multi-failure
     combinations worth testing (e.g. step 4 vs step 5)? If a
     plausible combination isn't covered and could produce
     divergent implementations = MINOR.

E.3  AC-13 byte-identical: this is the L-1 enforcement AC. Is
     "byte-identical" verifiable in CI? If the test would need
     to capture every log line of a running coordinator, can it
     actually do that in a test harness? If the AC is well-
     intentioned but unimplementable = MAJOR.

E.4  AC-15 legacy `hello` frame: tests R-3.1.8. Is there an
     equivalent AC for the `auth` frame path of every R-3.1.x
     rule, or do the `auth`-path ACs implicitly cover both? The
     `hello` frame is a different parser; if only one rule is
     hello-tested = MINOR.

### Category F: Anything else

F.1  Documentation drift: HANDOFF.md, RUNBOOK.md,
     CONTINUE_RUNBOOK.md, AGENTS.md — does any of these reference
     the old SPEC-010 (now SPEC-012-source)? If yes, those
     references will rot after the lock; flag as MINOR.

F.2  Decision-log entry: when v1.0 locks, an entry in
     `beta/DECISION_CRITERIA.md` should capture (a) the
     wide-scope-to-narrow split decision, (b) what's in SPEC-010
     v1.0 vs SPEC-011 vs SPEC-012, (c) the audit history that
     drove the split. v1.0 is pre-lock, so this isn't a finding
     yet, but note in I.

F.3  Naming/section ordering nits.

F.4  Anything the operator should know about that doesn't fit
     A-E.

## Output structure

Write to `/Users/augstar/macprovider-poc/specs/SPEC-010-audit.md`
as a NEW FILE (not the SPEC-012-source-audit-history). Frontmatter:

```
# SPEC-010 v1.0 — Audit Report (post-split)

**Audited:** SPEC-010 v1.0 (specs/SPEC-010-model-catalog.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 1 of N
**Date:** 2026-06-06
**Total findings:** [N CRITICAL / N MAJOR / N MINOR / N QUESTION]

**Predecessor audit history:**
specs/SPEC-012-source-audit-history.md (3 rounds against the
wide-scope draft that produced this split).

---

## Executive summary

[2-4 paragraphs. State whether v1.0 is ready to lock, ready with
the CRITICAL/MAJOR findings closed, or needs revision. Explicitly
comment on whether the narrow scope makes convergence achievable
in 1-2 rounds (the design hypothesis behind the split).]
```

Then for each category A-F, write a section. For each finding:

```
### A.2  [SHORT TITLE]   [CRITICAL | MAJOR | MINOR | QUESTION]
Location: §3.3.3, line ~XXX

[What. 1-3 sentences.]

[Why it matters. 1-3 sentences.]

[Recommendation. 1-2 sentences. For scope-expansion findings:
"defer to SPEC-011/SPEC-012; v1.0 cannot fix alone."]
```

If a category has zero findings, write `(no findings)`.

## Out of scope for this audit

- Inspecting d-inference source (NOASSERTION license)
- Rewriting the spec
- Implementing the spec
- Auditing SPEC-001, SPEC-002, SPEC-004, SPEC-008 themselves
- Auditing SPEC-011 outline (separate cycle)
- Re-litigating SPEC-012-source findings on surface NOT in v1.0
- Recommending scope expansion (must defer to SPEC-011/SPEC-012)

## Done criteria

You are done when:

- /Users/augstar/macprovider-poc/specs/SPEC-010-audit.md exists
  as a NEW file with round-1 v1.0 findings (do NOT touch
  SPEC-012-source-audit-history.md)
- Every category A-F has a section (even if "(no findings)")
- Every finding has severity, location, what/why/recommendation
- Executive summary states a clear verdict
- Scope-expansion findings (if any) explicitly mark "defer to
  SPEC-011/SPEC-012" in the recommendation

=== END PROMPT ===
```

---

## Operator notes (NOT part of the prompt)

- Expected wall-clock: 20-30 min Codex round 1 (narrow spec, ~400
  lines of normative surface).
- Convergence target: 0 CRITICAL, ≤2 MAJOR → lock SPEC-010 v1.0,
  start SPEC-001 v1.2.5 BUILD session AND begin SPEC-011 v0.2
  draft.
- If audit finds 0 CRITICAL and 0 MAJOR (the design hypothesis
  outcome), lock directly without a round 2.
- If audit finds ≥1 CRITICAL or >2 MAJOR, draft v1.1, re-audit
  round 2. Convergence should be achievable in ≤2 rounds given
  the narrow scope.
- After lock, append decision-log entry to
  `beta/DECISION_CRITERIA.md` summarizing the wide-scope-to-narrow
  split decision, what's where (SPEC-010 / SPEC-011 / SPEC-012),
  audit history.
