# Audit prompt — SPEC-010 v0.1 (Provider Model Catalog & Hot-Swap)

Operator-paste prompt to audit SPEC-010 v0.1
(`specs/SPEC-010-model-catalog.md`).

**Cross-model pattern:** SPEC-010 was drafted by Claude (Opus) on
2026-06-06. For independence, the audit runs in **Codex CLI first**.
After Codex round 1 lands, an optional round 2 in Claude may be
appended; both audit reports go into `specs/SPEC-010-audit.md` as
separate sections, matching the SPEC-006 / SPEC-008 audit history
pattern.

**Expected duration:** ~30–45 min for Codex. SPEC-010 is intentionally
small (12 sections, 10 ACs, two-phase rollout, additive wire only)
because Phase 1 is meant to ship in days, not weeks. Bias toward
finding the specific failure mode that an implementer would hit, not
toward broad architectural rewrites — the locked decisions in §2 are
out of scope for the audit.

**Trigger context:** arm64golf canary run on 2026-06-05 surfaced that
providers cannot select or change MLX models without a full binary
restart, and the network has no visibility into what models a provider
*could* serve. SPEC-010 is the smallest protocol change that fixes
this. The fact that it's small is a feature; recommendations that
balloon it are MAJOR (scope creep) unless they prevent a real
production failure.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Codex CLI session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are auditing SPEC-010 v0.1, the Provider Model Catalog & Hot-Swap
spec at /Users/augstar/macprovider-poc/specs/SPEC-010-model-catalog.md.

You are NOT here to validate, rewrite, or extend the spec. Find
problems, report them with specific severity and location, and let
the operator decide fixes. The operator has read the spec; they want
an independent second opinion on what is missing, wrong, or under-
specified before any implementation work starts.

Output:
  /Users/augstar/macprovider-poc/specs/SPEC-010-audit.md

Format: structured audit report. Findings grouped by category below,
each finding tagged with severity (CRITICAL / MAJOR / MINOR / QUESTION)
and location (section number + line range when possible). Match the
rigor and tone of the prior audit reports in this repo
(specs/SPEC-006-audit.md, specs/SPEC-008-audit.md).

## Severity definitions

- **CRITICAL** — would cause production failure on Phase 1 rollout,
  silent regression of locked spec behavior, scope creep into a locked
  upstream spec (SPEC-001 v1.2.4, SPEC-002 v1.3.3, SPEC-004 v0.3.1,
  SPEC-008 v0.1), security regression (token leakage, model-hash
  bypass, sticky-affinity corruption), or violation of an L-1..L-6
  locked decision in §2.

- **MAJOR** — would cause significant implementer confusion, predictable
  v0.2 patch within first month of Phase 1 deployment, unjustified
  numeric thresholds, ambiguous failure semantics, wire annotations
  too vague for the SPEC-001 v1.2.5 / SPEC-002 v1.3.4 candidate BUILD
  sessions described in §8, or back-compat semantics that don't actually
  hold up against a legacy coordinator/provider mix.

- **MINOR** — quality issues that don't block v0.1 but should be cleaned
  in v0.2. Naming inconsistencies, missing cross-references, edge cases
  that won't fire frequently.

- **QUESTION** — genuinely unresolved design choices the spec couldn't
  decide alone. Distinguish from §10 OQs the spec already names —
  those are not findings unless they hide a CRITICAL / MAJOR underneath.

## Critical constraints to honor while auditing

**1. Locked decisions (§2) are read-only.** L-1 through L-6 reflect
operator policy decisions, not engineering tradeoffs the auditor can
revisit. A finding that recommends inverting any of:
  - L-1 backward compat
  - L-2 permissionless (no closed allowlist)
  - L-3 one *active* model per process
  - L-4 hash semantics unchanged from SPEC-008
  - L-5 hot-swap is opt-in (Phase 2 separate from Phase 1)
  - L-6 no paid-tier gating
…is rejected unless the finding shows structural incompatibility with
another locked constraint (e.g. shows L-3 cannot coexist with SPEC-008
§F-1.5 invariant (a)).

**2. SPEC-001 v1.2.4, SPEC-002 v1.3.3, SPEC-004 v0.3.1, SPEC-008 v0.1
are LOCKED.** Any SPEC-010 clause that requires a normative edit to
one of these locked specs is a CRITICAL finding ("scope creep across
spec boundary"). Companion-spec changes belong in §8 as
SPEC-NNN-vNEXT candidate annotations only.

**3. Additive-only / Tier-1 backward compat (L-1).** With all
SPEC-010 fields absent and `publish_unwarm_models = false`,
coordinator behavior MUST be byte-identical to the current production
behavior. The default `publish_unwarm_models = true` is a knowing
behavior change that §7.3 calls out — the audit may challenge this
default but it is explicitly flagged (OQ-1), so it is not by itself a
critical compat regression unless the audit shows actual buyer-client
breakage.

**4. Phase 1 must ship independently of Phase 2.** Any Phase 1
requirement that secretly depends on Phase 2 (`set_model` message,
`loading_model` state, hot-swap CLI) being shipped is a CRITICAL
finding.

**5. SPEC-008 §F-1.5 survivability invariants (HMAC collision,
provider cannot derive conv:, deletion is account-scoped, TTL is
coordinator-enforced) MUST be preserved.** Any SPEC-010 §4 or §5
clause that adds inputs to sticky derivation, hands a sticky lifecycle
message to a provider, or extends sticky TTL via supported_models or
loaded_model state is CRITICAL.

**6. SPEC-008 Pillar A model_hash (§5) MUST continue to refer to the
loaded model, not the supported set.** L-4 codifies this. Verify
§4.3, §4.5, §5, and §8.4 do not silently weaken hash verification.

**7. Coordinator does not validate model_id strings (L-2).** Any
SPEC-010 clause that adds a server-side allowlist or rejects a
supported_models entry because it "isn't recognized" is a CRITICAL
violation of L-2. Length and shape validation (§4.1.5, §4.1.6) is
fine; semantic validation is not.

**8. Clean-room.** Do NOT inspect d-inference (layr-labs) source.
NOASSERTION license. Any SPEC-010 clause that appears to require
d-inference inspection is a CRITICAL finding.

## Required reading (in order, fully)

1. `/Users/augstar/macprovider-poc/specs/SPEC-010-model-catalog.md`
   v0.1 — the spec under audit. Read all 12 sections and all 10 ACs
   fully. Bias toward reading §4 (Phase 1 wire spec) and §7 (back-
   compat) most carefully — these encode the actionable Phase 1
   commitments. §5 (Phase 2 outline) is design-locked but not yet
   normative; audit it as "does this paint Phase 1 into a corner?"
   not as "is this complete enough to implement?".

2. `/Users/augstar/macprovider-poc/CLAUDE.md` — project conventions,
   especially the PR workflow rule, the Augustas11 git identity rule,
   and the spec naming pattern.

3. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   v1.2.4 — focus on:
   - §6.1 `/v1/models` response shape (SPEC-010 §4.5 extends this)
   - §6.1.2 model_id case-insensitivity rule (SPEC-010 §4.1.7
     inherits this)
   - The single-model-per-process architectural assumption
     (SPEC-010 L-3 preserves this; verify L-3 actually matches the
     binary's current architecture)

4. `/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md`
   v1.3.3 — focus on:
   - §3 provider state machine (Phase 2 §5.2 adds `loading_model` —
     verify this doesn't conflict with existing states)
   - §5 routing algorithm (SPEC-010 §4.4 adds a new candidate filter
     — verify the filter sits at the correct point in the pipeline)
   - §7.2 provider WS auth (SPEC-010 §4.1 extends `AuthRequest`)
   - §11 audit categories (Phase 2 adds new event types)

5. `/Users/augstar/macprovider-poc/specs/SPEC-004-smart-router.md`
   v0.3.1 — focus on:
   - §2 out-of-scope list — verify SPEC-010 doesn't reopen anything
     SPEC-004 explicitly excluded
   - §4 sticky-affinity semantics — SPEC-010 must NOT break these
   - Entry 35 dispatch-rewrite pattern that SPEC-010 §4.4.1 references

6. `/Users/augstar/macprovider-poc/specs/SPEC-008-tier2.md` v0.1 —
   focus on:
   - §2.1–2.5 F-1.5 survivability invariants (CRITICAL constraint 5)
   - §5 Pillar A hash verification (CRITICAL constraint 6)
   - §C.5 hash_status values and routing behavior

7. `/Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md` —
   focus on Entry 21 (no premium positioning) and Entry 35 (SPEC-004
   Pillar B dispatch-rewrite — SPEC-010 §4.4.1 references this).
   Skim other recent entries for context but they are unlikely to
   bind here.

8. Code spot-checks (for cross-checking §4 and §8 against reality):
   - `phase4-coordinator/internal/ws/messages.go` lines 8-57
     (`Hello` and `AuthRequest` shapes — SPEC-010 §4.1 extends these)
   - `phase4-coordinator/internal/pool/provider.go` lines 50-88, 174,
     420-432, 464-477 (`Provider` struct, `seenModels`, ModelKnown)
   - `phase5-gateway/internal/router/server.go` lines 143, 461-479,
     1309 (model resolution + /v1/models aggregation)
   - `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
     lines 18-28 (ServeCommand --model flag)
   - `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
     line 246 (model resolution: HF id vs local path)

9. `/Users/augstar/macprovider-poc/specs/SPEC-006-audit.md` and
   `/Users/augstar/macprovider-poc/specs/SPEC-008-audit.md` — for
   tone and severity-bar continuity.

## Audit categories — work through each

### Category A: Locked-decision preservation (HIGHEST PRIORITY)

A.1  Walk each of L-1 through L-6 in §2. For each, find one or more
     clauses elsewhere in the spec that operationalize the lock. If a
     lock is stated in §2 but no concrete §4 / §5 / §8 clause enforces
     it = MAJOR.

A.2  L-1 backward compat: confirm that a coordinator running SPEC-010
     code with `publish_unwarm_models: false` and no other config
     change produces byte-identical /v1/models output for a legacy
     provider. Walk §4.3.1, §4.4, §4.5, §7.1 against the actual
     `Provider` struct and `seenModels` registry in code. If any path
     emits new log lines, new fields, or new routing decisions for a
     legacy provider with default config = CRITICAL.

A.3  L-2 permissionless: confirm no clause in §4 or §5 rejects a
     `supported_models` entry on semantic grounds (only length/shape).
     If §4.1.6 length cap or §4.1.5 array cap accidentally rejects
     legitimate operator advertisements at p99 = MAJOR.

A.4  L-3 one *active* model: confirm §4 and §5 maintain that
     {warm models} ⊆ {loaded_model} ∪ ∅ at all times, including
     during the Phase 2 swap window. If §5.1 or §5.2 implies two
     models can be simultaneously loaded = CRITICAL.

A.5  L-4 hash semantics: confirm §4.3, §4.5, §5.1.4, §8.4 all keep
     model_hash bound to loaded_model only. If any clause treats
     `supported_models` entries as hash-verified = CRITICAL (would
     enable a misadvertise → silent hash bypass).

A.6  L-5 hot-swap opt-in: walk §4 line by line. If any Phase 1
     normative rule depends on Phase 2 behavior (set_model,
     loading_model, drain semantics) = CRITICAL.

A.7  L-6 no paid-tier gating: confirm SPEC-005 billing is not
     touched, no new revenue-share formula, no minimum
     `supported_models` length to earn Tier-2. If any clause leaks
     billing implications = MAJOR.

### Category B: Wire format correctness

B.1  §4.1.1–4.1.7 auth frame extension: verify the field is correctly
     specified as additive on top of the actual `AuthRequest` Go
     struct. If the JSON tag, omitempty semantics, or array shape
     doesn't survive a round-trip through Go's encoding/json with
     a legacy coordinator that doesn't know the field = MAJOR.

B.2  §4.1.3 "model_id in supported_models" rule: verify this is
     enforced both ways — coordinator rejects mismatch, but also that
     the provider's CLI flag parser cannot produce a state where
     `--model X` and `--supported-models Y,Z` would be sent
     simultaneously (which would fail auth on first connect, costing
     onboarding time). If the spec leaves this entirely to the
     provider implementer = MAJOR; the spec should constrain the CLI
     parser behavior in §8.1.

B.3  §4.1.4 legacy treatment: verify the spec is explicit that
     `supported_models == nil` and `supported_models == []` are
     distinguishable. If both are coerced to `[model_id]`, that's
     fine but it should be stated. If only one is handled = MAJOR.

B.4  §4.1.5, §4.1.6 caps: are 64 entries and 256 bytes well-justified?
     Cross-check against a typical M-series HF cache contents. If the
     cap is arbitrary or would reject reasonable operator setups =
     MAJOR. If it's reasonable but unjustified in prose = MINOR.

B.5  §4.1.7 case-insensitivity: verify the spec correctly inherits
     SPEC-001 §6.1 case-insensitive compare. If §4.4 candidate
     filtering uses case-sensitive equality (Go default) but spec
     says case-insensitive = MAJOR.

B.6  §4.2 heartbeat unchanged: verify there is no implicit need to
     send `supported_models` on heartbeat. If e.g. the operator might
     update an env var and want it to propagate without reconnect,
     the spec is silent on this. If §4.2 is too rigid for legitimate
     operator UX = MINOR or QUESTION.

B.7  §4.3.2 `seenModels` index: verify the proposed change to
     populate from union doesn't break existing callers of
     `ModelKnown()`. Check
     phase4-coordinator/internal/pool/provider.go:464-477 and any
     other call sites. If a caller relies on seenModels representing
     "models seen as loaded" = MAJOR.

B.8  §4.5.1 `warm: bool` field: verify the existing /v1/models
     response shape can absorb a new field without breaking any
     known OpenAI-SDK client. The OpenAI SDK is strict about response
     parsing in some versions. If there's a known-bad client this
     would break = MAJOR; otherwise = MINOR.

B.9  §4.5.3 `503 model_not_warm`: verify the error code, body shape,
     and Retry-After header are precisely enough specified to
     implement and to assert on in a test. If the body shape is hand-
     wavy = MAJOR.

### Category C: Routing semantics (Phase 1)

C.1  §4.4.1 vs §4.4.2: these are subtle. R-4.4.1 says "dispatcher
     MUST select a candidate via SPEC-004 ranking and rewrite
     body.model" and R-4.4.2 says "Phase 1 only enables (a) routing-
     by-class improvements and (b) /v1/models aggregation; does NOT
     enable serving a request for a model no provider has warm."
     These appear to contradict. Read the two rules carefully and:
       - If they actually contradict for any request type = MAJOR
       - If the intent is "rewrite to a warm provider when one
         candidate is warm; 503 when all candidates are cold" but
         the prose is ambiguous = MAJOR
       - If they're consistent and the prose just reads strangely =
         MINOR (clarity fix in v0.2)

C.2  Class-aliasing interaction (SPEC-004 §4): if a buyer asks for
     `mlx-fast` (a class alias) and the SPEC-004 class expansion
     yields concrete IDs A, B, C — none of which any provider has
     loaded but at least one provider lists in supported_models —
     what happens? §4.4 + §4.5 must define this jointly. If the
     answer falls through cracks = MAJOR.

C.3  SPEC-004 sticky-affinity: verify §4.4 candidate filter applies
     BEFORE sticky-affinity stickiness check, not after. Otherwise a
     sticky buyer could pin to a provider that no longer has the
     model warm. If unclear in spec = MAJOR.

C.4  AC-9 says "two providers, both listing A, only one warm — buyer
     request for A always routes to the warm one. Phase 1 cannot
     wake the cold one." This is testable. Confirm §4.4 + §4.5
     produce this behavior unambiguously. If any §4 clause could
     route to the cold one in Phase 1 = CRITICAL (would emit a 503
     when a working provider exists).

### Category D: Backward compatibility

D.1  §7.1 legacy provider against SPEC-010 coordinator: walk
     `seenModels` population, /v1/models output, and routing decisions
     for a legacy `auth` frame. Verify no log warning, no new field
     in /v1/status response. If §4.3.3 publishes `supported_models`
     when it's a synthetic single-entry list and that's a behavior
     change to /v1/status callers = MAJOR; if it's expected and OK,
     fine.

D.2  §7.2 SPEC-010 provider against legacy coordinator: verify the
     Go encoding/json behavior on unknown fields. If legacy
     coordinator uses `DisallowUnknownFields()` somewhere in the auth
     parse path = CRITICAL. Spot-check
     `phase4-coordinator/internal/ws/messages.go` ParseHello /
     ParseAuth implementations.

D.3  §7.3 visible behavior change: weigh the `publish_unwarm_models:
     true` default. Is OQ-1's default-true choice safe for known
     buyer clients (OpenAI SDK, curl, custom)? Audit should give a
     clear opinion: keep default-true, flip to default-false, or
     gate on coordinator version. If the audit's recommendation
     differs from the spec, file as QUESTION with rationale.

### Category E: Phase 2 forward-compatibility (paint-into-corner check)

Only audit §5 for "does Phase 1 leave a feasible Phase 2 path?", not
for "is Phase 2 complete?". Phase 2 will get its own audit in v0.2.

E.1  §5.1.1 "coordinator MAY send set_model only if target_model_id
     is in supported_models": verify Phase 1's §4.1 keeps
     supported_models accurate enough for this to work. If Phase 1
     allows supported_models to be set once at auth and never
     refreshed, that's documented (§4.2). Is that compatible with
     Phase 2's coordinator-initiated swap? Yes (set_model targets
     are restricted to the initial supported_models set). If a swap
     gone wrong leaves the provider stuck in a state that requires
     reconnect = MAJOR.

E.2  §5.1.5 "MUST NOT extend sticky TTL": this is the SPEC-008
     F-1.5 constraint preservation. Verify this is stated as a hard
     normative MUST and references the right SPEC-008 section. If
     the language is "should" or vague = CRITICAL.

E.3  §5.2 loading_model sub-state: verify it doesn't collide with
     any existing SPEC-002 §3 state name. If it does = MAJOR
     (rename in v0.2 still possible, but better to catch now).

E.4  §5.3 demand-pulled trigger: the 60s cooldown is unjustified.
     If thrashing is a real concern, audit may suggest a different
     value or a different rate-limit shape (token bucket, exponential
     backoff on failed loads). If the cooldown is hand-wavy = MINOR.

### Category F: SPEC-008 compatibility

F.1  §8.4 compatibility note: verify each claim is correct against
     SPEC-008 §5 and §F-1.5.

F.2  Pillar A `model_hash` interpretation: when a provider hot-swaps
     in Phase 2, the new model has no hash until the provider
     recomputes and reports. SPEC-010 §5.1.4 says provider sends a
     new heartbeat with new model_id + model_hash post-swap. Is the
     window between "swap acknowledged" and "new hash arrives" safe
     against an adversary that swap-and-reports-old-hash? If §5
     doesn't address this = MAJOR.

F.3  `hash_status: "unknown"` during swap: SPEC-008 §C.5 doesn't
     define this state. SPEC-010 §8.4 introduces it. If introducing
     a new hash_status value is a SPEC-008 edit (which it is) =
     CRITICAL scope creep. Either §8.4 must rephrase to reuse an
     existing SPEC-008 status, or the spec must explicitly call this
     out as a SPEC-008 v0.2 candidate (which §8.4 does mention, but
     the audit should verify the phrasing is clear that it's a
     candidate, not a current claim).

### Category G: ACs are deterministically verifiable

G.1  Walk each of AC-1 through AC-10. For each, write down (in the
     audit) the exact test setup and assertion that would verify it.
     If you cannot do this in 3-5 lines, the AC is ambiguous = MAJOR
     per ambiguous AC.

G.2  Coverage gap check: is there any §4 normative rule (R-4.x.y)
     that has no corresponding AC? If so = MAJOR per uncovered rule.
     (Hint: walk every R-4.x.y and confirm at least one AC exercises
     it.)

G.3  AC-4 "byte-identical" is a strong claim. Verify it is actually
     achievable given §4.3.3 (publishes supported_models on
     /v1/status), §4.3.1 (populates SupportedModels even for legacy
     providers), and §4.5.4 (warm:true default for legacy). If any
     of these emits a new byte in any response, AC-4 is unsatisfiable
     = CRITICAL.

### Category H: Implementation-readiness for §8 candidate BUILD prompts

§8 says SPEC-001 v1.2.5 and SPEC-002 v1.3.4 candidates will be built
from this spec. Verify §8's annotations are precise enough to write
those BUILD prompts without further design work.

H.1  §8.1 SPEC-001 v1.2.5 candidate: are the CLI flag, env, and
     config-file priorities precisely specified? If "CLI > ENV >
     config" is asserted but the actual SPEC-001 currently uses a
     different order = MAJOR (mismatch with reality).

H.2  §8.2 SPEC-002 v1.3.4 candidate: are the audit-log event types
     namespaced correctly per SPEC-002 §11? If the event-type strings
     conflict with existing ones = MAJOR.

H.3  §8.3 SPEC-004 v0.4 candidate: is the dispatch-ranking change
     precise enough to implement? "Prefer warm; tie-break by current
     SPEC-004 ranking" — does "warm" beat or lose to the current
     ranking's first criterion? If undefined = MAJOR.

### Category I: Operator UX completeness

I.1  Phase 1 alone delivers what to the canary-run operator? Walk the
     2026-06-05 arm64golf symptom list (spec §1.1, items 1-4) and
     mark each as "Phase 1 fixes," "Phase 2 fixes," "Phase 3 fixes,"
     or "not addressed." If items 1 or 2 are not addressed until
     Phase 2, the operator-facing claim that "Phase 1 alone closes
     the canary symptom" (spec §3, §10 OQ-3) is overstated = MAJOR.

I.2  Cross-check OQ-3 (Phase 2 in Phase 1?). If Phase 1 alone does
     NOT meaningfully improve operator UX (only buyer UX), the
     spec's prioritization may be wrong. File as QUESTION with
     recommendation.

I.3  Is there a documented "how does an operator change their served
     model" workflow under Phase 1 alone? Spec §6 outlines Phase 3
     CLI but Phase 1 has nothing. If the operator UX in Phase 1 is
     "edit config, restart binary, wait for reconnect" — that is
     unchanged from today. If the spec implies Phase 1 improves
     operator UX = QUESTION (clarify what improves and what doesn't).

### Category J: Anything else

Anything the operator should know about that doesn't fit A-I. Examples:
- Missing decision-log entry that should be added when SPEC-010 v0.1
  locks
- Documentation drift: HANDOFF.md, RUNBOOK.md, CONTINUE_RUNBOOK.md, or
  AGENTS.md that would need updates
- Test infrastructure gaps (does any existing integration test fail
  the moment §4.3.1 is implemented?)
- Naming nit: "Phase 1/2/3" overlaps with the repo's existing
  "phase3-binary / phase4-coordinator / phase5-gateway" naming and
  may confuse readers

## Output structure

Write to `/Users/augstar/macprovider-poc/specs/SPEC-010-audit.md`.
Top-of-file frontmatter:

```
# SPEC-010 v0.1 — Audit Report

**Audited:** SPEC-010 v0.1 (specs/SPEC-010-model-catalog.md)
**Auditor model:** [Codex / GPT-5 / etc.]
**Audit round:** 1 of N
**Date:** 2026-06-06
**Total findings:** [N CRITICAL / N MAJOR / N MINOR / N QUESTION]

---

## Executive summary

[2-4 paragraphs. State whether Phase 1 is ready to ship as drafted,
ready with the CRITICAL findings addressed, or needs structural
revision. Be specific about what the operator should do next.]
```

Then for each category A-J, write a section. For each finding in a
category:

```
### A.2  [SHORT TITLE]   [CRITICAL | MAJOR | MINOR | QUESTION]
Location: §4.5.1, line ~278-285

[What the spec says or fails to say. 1-3 sentences.]

[Why it matters. 1-3 sentences. Reference a concrete failure scenario
or a specific reader confusion.]

[Recommendation. 1-2 sentences. What v0.2 should do — but don't
rewrite the spec for the operator.]
```

If a category has zero findings, write `(no findings)` under the
category header — don't omit the section.

## Out of scope for this audit

- Inspecting d-inference source (NOASSERTION license)
- Rewriting the spec
- Implementing the spec
- Auditing SPEC-001, SPEC-002, SPEC-004, SPEC-008 themselves (they
  are locked; SPEC-010 layers on top)
- Auditing the arm64golf canary infrastructure
- Designing the SPEC-001 v1.2.5 BUILD prompt (that's a separate
  session after SPEC-010 v0.1 locks)
- Phase 3 normative design (§6 is intentionally non-normative)

## Done criteria

You are done when:

- /Users/augstar/macprovider-poc/specs/SPEC-010-audit.md exists
- Every category A-J has a section (even if "(no findings)")
- Every finding has severity, location, what/why/recommendation
- Executive summary states a clear "ship as-is" / "ship with these
  CRITICAL/MAJOR findings closed" / "needs structural revision"
  verdict

=== END PROMPT ===
```

---

## Operator notes (NOT part of the prompt)

- Run with `codex` CLI on the host that has the repo checked out.
- Expected wall-clock: 30-45 min Codex round 1.
- After Codex finishes, the operator decides whether to run a Claude
  round 2 (append, not overwrite). If only one round is needed,
  delete the "Audit round: 1 of N" line in the audit file and bump
  to "Audit round: 1 of 1" so future readers don't expect a round 2.
- If Codex finds zero CRITICAL findings and ≤3 MAJOR findings, lock
  SPEC-010 v0.1 and start the SPEC-001 v1.2.5 BUILD session.
- If Codex finds ≥1 CRITICAL or >3 MAJOR findings, draft SPEC-010
  v0.2 incorporating the fixes, re-audit in Codex round 2.
- After lock, append decision-log entry to `beta/DECISION_CRITERIA.md`
  (next free entry number) summarizing: trigger, locked decisions,
  what shipped, what was deferred.
