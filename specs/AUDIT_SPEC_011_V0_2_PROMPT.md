# Audit prompt — SPEC-011 v0.2 normative (round 1)

Operator-paste prompt to audit SPEC-011 v0.2
(`specs/SPEC-011-operator-pushed-warm-swap.md`).

**Round 1 of NORMATIVE audit (NOT outline).** SPEC-011 went
through two pre-draft OUTLINE audit rounds at
`specs/SPEC-011-outline-audit.md`:
- Outline round 1 (Codex on v0.1): 0 CRITICAL / 6 MAJOR / 1
  MINOR / 1 QUESTION
- Outline round 2 (Codex on v0.1.1): 0 CRITICAL / 2 MAJOR / 1
  MINOR / 1 QUESTION

v0.2 is the first FULL NORMATIVE draft. It claims to
incorporate the 2 outline-round-2 MAJORs + 1 MINOR + 1
QUESTION decision into normative rules and ACs:
- C2.1 fix: §3.8.3 reconnect cites `hello` (locked SPEC-001
  §6.5 / SPEC-002 §7.1), NOT `auth_request`
- D2.1 fix: §6.2 SPEC-002 v1.3.5 candidate explicitly lists
  the heartbeat hash-clearing REPLACEMENT as a normative edit
- A2.1 fix: §5 has 20 ACs (not 16)
- C2.2 decision: R-3.6.6 / R-3.8.4 document the observation-
  only audit invariant for WS-drop-mid-load swaps

This is the first FULL CODE-GROUNDED audit of SPEC-011's
normative surface. The recent SPEC-010 v1.2 round-3 audit
showed that spec text written without code-grounding produces
contract-precision MAJORs (field table didn't match Go struct;
retention key cited a field that doesn't exist). **Apply that
lesson here**: spot-check every wire-shape claim, every code
location citation, and every locked-spec citation against the
actual repo state.

Output to a NEW file: `specs/SPEC-011-audit.md`. This is the
first normative-audit file for SPEC-011 (distinct from the
outline-audit history at `specs/SPEC-011-outline-audit.md`).

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Codex CLI session rooted at
`/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are auditing SPEC-011 v0.2 at /Users/augstar/macprovider-poc/
specs/SPEC-011-operator-pushed-warm-swap.md. This is round 1 of
the NORMATIVE audit (the outline audits at
specs/SPEC-011-outline-audit.md are pre-draft and separate).

You are NOT here to validate, rewrite, or extend the spec. Find
problems, report them with specific severity and location, and
let the operator decide fixes. Output to a NEW file:
  /Users/augstar/macprovider-poc/specs/SPEC-011-audit.md

Match the rigor and tone of prior audit reports in this repo
(specs/SPEC-008-audit.md, specs/SPEC-010-audit.md,
specs/SPEC-012-source-audit-history.md).

## Severity definitions

- **CRITICAL** — production failure on rollout, silent
  regression of locked-spec behavior, scope creep into a locked
  upstream spec (SPEC-001 v1.2.4, SPEC-002 v1.3.4, SPEC-004
  v0.3.1, SPEC-008 v0.3), security regression, or violation of
  L-1..L-7.
- **MAJOR** — significant implementer confusion, predictable
  v0.3 patch, contract precision gap (especially: spec text
  that doesn't match actual code), back-compat that doesn't
  hold, scope expansion into SPEC-010/SPEC-012 territory.
- **MINOR** — quality issues that don't block lock.
- **QUESTION** — unresolved design choice.

## Critical constraints

**1. Locked decisions (§2 L-1 through L-7) are READ-ONLY.**
Findings that recommend inverting any of L-1..L-7 are rejected
unless they show structural incompatibility with another
locked constraint.

**2. SPEC-001 v1.2.4, SPEC-002 v1.3.4, SPEC-004 v0.3.1, SPEC-008
v0.3 are LOCKED.** Any v0.2 clause requiring a normative edit
to one of these is CRITICAL scope creep. v0.2 §6.2 explicitly
flags ONE replacement edit to SPEC-002 (the heartbeat
hash-clearing path). All other surface in §6 MUST be additive
or framed as a candidate addition.

**3. Scope discipline.** SPEC-011 owns operator-pushed warm
swap. Findings that recommend pulling in SPEC-012's coordinator
→ provider `set_model` wire, cold-wake parked queues, buyer
`/v1/models` aggregation, `/v1/status.state` field, or
`model_not_warm` envelope are SCOPE CREEP findings (MAJOR or
CRITICAL depending on size).

**4. Code-grounding is the highest-leverage check.** Round-3
on SPEC-010 v1.2 found 5 MAJORs all rooted in
spec-doesn't-match-code:
- Field table marked parser-required fields as optional
- Example wasn't parser-valid
- Retention key cited a field that doesn't exist in the
  initial frame
Apply the same scrutiny to v0.2:
- Walk R-3.1.5 control socket: does `$XDG_RUNTIME_DIR` exist
  on macOS? (It's a Linux convention; macOS typically uses
  `$TMPDIR` or `/var/folders/...`)
- Walk R-3.3.x heartbeat extension: does the current
  Heartbeat struct in
  `phase4-coordinator/internal/ws/messages.go` look like
  v0.2 claims? Where is the struct defined?
- Walk R-3.8.3 `hello` reconnect: does the locked SPEC-001
  §6.5 hello frame actually carry `model_hash`?
- Walk R-3.2 state machine + atomic swap: does the actual
  Swift `ModelRuntime` actor structure at
  `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
  match the "immutable `let` fields" claim?
- Walk R-3.3.5 coordinator REPLACEMENT rule: does
  `phase4-coordinator/internal/pool/provider.go:420-432`
  actually exhibit the "clears ModelHash on ModelID change"
  behavior the spec claims to REPLACE?

**5. SPEC-010 v1.x dependency.** SPEC-011 R-3.1.2 step 2
depends on SPEC-010 R-3.6.3 (binary-local pre-flight
validation). SPEC-010 v1.2 has not yet locked. v0.2 §6.6
acknowledges the dependency and recommends co-shipping.
Verify v0.2 doesn't accidentally depend on SPEC-010 surface
that doesn't exist in v1.2 (e.g. if the audit cites a
hypothetical SPEC-010 rule).

**6. F-1.5 invariants preserved (L-6 + R-3.6.5).** Walk the
`operator_model_swap` event payload at §3.6 for any field
that could feed sticky derivation, expose `conv:`, hand
sticky lifecycle to a provider, or extend sticky TTL. Apply
SPEC-006 §F-1.5 redaction rules.

**7. Clean-room.** Do NOT inspect d-inference (layr-labs)
source. NOASSERTION license.

## Required reading (in order)

1. `/Users/augstar/macprovider-poc/specs/SPEC-011-operator-pushed-warm-swap.md`
   v0.2 — the spec under audit. Read all 9 sections + 20 ACs
   fully. Bias toward §3 (wire spec), §4 (back-compat), §5
   (ACs), §6 (companion specs) most carefully.

2. `/Users/augstar/macprovider-poc/specs/SPEC-011-outline-audit.md`
   — two pre-draft outline audit rounds. Use as context for
   what v0.2 deliberately addresses. The outline-round-2
   PASS findings (C.4, C.5, L.2, Q.2, H.2) should still hold
   in v0.2's normative text — verify.

3. `/Users/augstar/macprovider-poc/CLAUDE.md` — project
   conventions.

4. `/Users/augstar/macprovider-poc/specs/SPEC-010-model-catalog.md`
   v1.x — verify v0.2 references to SPEC-010 R-3.6.3 and
   R-3.1.4 are accurate.

5. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   v1.2.4 — focus on:
   - §6.2 (existing CLI shape; SPEC-011 §3.1 extends with
     `models` subcommand)
   - §6.5 (provider WS handshake including `hello`;
     SPEC-011 §3.8 cites reconnect via `hello`)
   - §6.6 (in-flight request lifecycle; SPEC-011 §3.4 drain
     semantics interact)

6. `/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md`
   v1.3.4 — focus on:
   - §3 provider state machine (SPEC-011 claims NO change;
     verify §3.2 binary-local `loading/draining` doesn't
     surface as a coordinator-side state)
   - §7.1 (provider WS protocol — `hello`/`hello_ack`/
     heartbeat; SPEC-011 §3.3 extends heartbeat)
   - §7.3 (token/auth)
   - §11 audit-log (SPEC-011 §3.6 adds ONE event type)
   - §11 J.1 (heartbeat-starvation lesson cited by R-3.2.5)

7. `/Users/augstar/macprovider-poc/specs/SPEC-008-tier2.md`
   v0.3 — focus on:
   - §5.3-5.6 Pillar A verification pipeline (SPEC-011
     R-3.3.5 / R-3.5 reuse path)
   - §5.5 five hash states (SPEC-011 claims no new state)
   - F-1.5 invariants

8. `/Users/augstar/macprovider-poc/specs/SPEC-006-buyer-api.md`
   §F-1.5 redaction rules (cited in R-3.6.5)

9. Code spot-checks (THE LOAD-BEARING CHECK):
   - `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
     lines 7-15 (existing CLI subcommands — verify v0.2 `models`
     fits)
   - `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
     lines 25-68, 86-147 (Swift actor + immutable `let`
     fields — verify R-3.2.1 refactor target claim)
   - `phase4-coordinator/internal/ws/messages.go` heartbeat
     struct (locate it; verify shape matches v0.2 §3.3
     assumption)
   - `phase4-coordinator/internal/ws/messages.go` hello struct
     (locate it; verify v0.2 §3.8.3 claim that hello carries
     `model_id` and "MAY carry `model_hash` if provider
     supports SPEC-008 Pillar A")
   - `phase4-coordinator/internal/pool/provider.go` lines
     420-432 (`ApplyHeartbeat` — verify "clears ModelHash on
     ModelID change" behavior claim)
   - Search for `XDG_RUNTIME_DIR` in the repo. On macOS this
     env var is typically NOT set. If R-3.1.5 cites it as
     default control socket location and macOS doesn't have
     it, the default is broken on the target platform =
     CRITICAL.

10. `/Users/augstar/macprovider-poc/specs/SPEC-012-source.md` —
    sanity-check no SPEC-012-territory surface leaked into
    v0.2.

11. `/Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md` —
    Entry 21 context.

## Audit categories — work through each

### Category A: Locked-decision preservation

A.1  Walk each of L-1 through L-7 in §2. For each, find one or
     more clauses in §3 that operationalize the lock. If a
     lock is stated in §2 but no concrete §3 clause enforces
     it = MAJOR.

A.2  L-1 backward compat: confirm AC-18 + AC-19 are achievable
     against actual code. Specifically, does AC-19's "legacy
     provider against SPEC-011 coordinator" produce
     byte-identical behavior to today? Walk R-3.3.5 legacy
     path against the current `ApplyHeartbeat` at
     provider.go:420-432.

A.3  L-2 operator-initiated only: confirm §3 has no clause
     where the coordinator triggers a swap. The closest risk
     is R-3.3.5 which is observation-based (coordinator
     reacts to a heartbeat the provider sent on its own);
     verify it's truly observation, not coordinator-initiated.

A.4  L-3 single routing-eligible warm model: verify §3.2
     state transitions and R-3.2.2 snapshot semantics
     preserve this. If `loaded` → `draining` ever permits a
     state where TWO containers are simultaneously
     routing-eligible = CRITICAL.

A.5  L-4 SPEC-008 Pillar A: verify R-3.3.5 / R-3.5 actually
     reuse SPEC-008 §5.3-5.6 unchanged. Walk SPEC-008 §5.5
     to confirm v0.2 claims "no sixth state" hold. If any
     §3 clause introduces a new hash-related status =
     CRITICAL.

A.6  L-5 no billing: verify SPEC-005 is untouched.

A.7  L-6 F-1.5: walk §3.6 `operator_model_swap` payload
     field by field. None may include `conv:`, raw
     `account_id`, sticky session identifiers, buyer prompt
     text, or any input that could feed sticky derivation.
     Cross-reference SPEC-006 §F-1.5.

A.8  L-7 no coordinator config knob: verify §3.9 only adds
     binary-side CLI flags, no coordinator-side config keys.

### Category C: Code-grounding (HIGHEST PRIORITY — round 3 lesson)

C.1  **Control socket platform check.** R-3.1.5 cites
     `$XDG_RUNTIME_DIR/macprovider-cli/ctl.sock` as default
     path. `XDG_RUNTIME_DIR` is a Linux/freedesktop.org
     convention; macOS typically does NOT set this variable.
     The target deployment is macOS Mac providers.
     - If $XDG_RUNTIME_DIR is unset on macOS, the default
       path is broken (empty prefix). = CRITICAL.
     - Recommend a macOS-appropriate default (e.g.
       `$TMPDIR/macprovider-cli/ctl.sock` or a sandboxed
       location).

C.2  **Heartbeat struct check.** R-3.3.x assumes a Heartbeat
     struct in `phase4-coordinator/internal/ws/messages.go`.
     Locate it. Verify:
     - The struct currently carries `model_id` (yes, per
       outline-audit C.3 evidence)
     - The struct does NOT currently carry `model_hash` (v0.2
       adds it)
     - The struct does NOT currently carry `loading` (v0.2
       adds it)
     If the struct shape differs from v0.2's assumption =
     MAJOR.

C.3  **Hello struct check.** R-3.8.3 says "hello carries
     `model_id` and (per current SPEC-001 §6.5) MAY carry
     `model_hash` if the provider supports SPEC-008 Pillar
     A." Locate `Hello` struct in messages.go and SPEC-001
     §6.5 hello documentation. Verify:
     - Hello has `model_id` (likely yes)
     - Hello has `model_hash` field (verify against current
       Hello struct definition — outline-audit C.3 noted
       heartbeat doesn't but hello may differ)
     If §3.8.3 claim is wrong = MAJOR.

C.4  **Existing `ApplyHeartbeat` behavior check.** R-3.3.5
     claims the current path at provider.go:420-432 "clears
     `Provider.ModelHash` and sets `HashStatus =
     HashStatusUncatalogued` on any `ModelID` change."
     Verify this is exactly what the code does. If the code
     does something different = MAJOR (REPLACEMENT framing
     is built on a wrong premise).

C.5  **Swift `ModelRuntime` refactor target check.** R-3.2.1
     claims `ModelRuntime` actor stores `modelID`,
     `container`, `modelHash` as immutable `let` fields.
     Verify against ModelRuntime.swift lines 25-68, 86-147.
     If the actor structure is different (e.g. already has
     mutable state, or different field names) = MAJOR.

C.6  **Existing CLI subcommand check.** R-3.1.x adds `models`
     subcommand to `macprovider-cli`. Verify against
     MacProviderCLI.swift lines 7-15 that:
     - `models` does NOT conflict with any existing subcommand
     - The Swift `Command` framework can host a nested
       subcommand of `models` (no obstacle from Swift's
       ArgumentParser)
     If conflict or obstacle = MAJOR.

### Category B: Wire-format correctness

B.1  R-3.3 heartbeat extension: walk the example JSON shape
     against the actual Heartbeat struct. Are `model_id`,
     `model_hash`, `loading` correctly typed (string,
     string, bool)?

B.2  R-3.6 `operator_model_swap` payload: walk every field
     against the declared schema. Are all REQUIRED fields
     truly required? Are optional fields clearly marked? Is
     `ts` format (ISO-8601) consistent with other audit
     events in SPEC-002 §11?

B.3  R-3.1.5 control socket protocol: 5 message types
     (switch_request, switch_ack, switch_progress,
     status_request, status_response). Are the field shapes
     internally consistent? Are required vs optional fields
     clear?

B.4  R-3.4.2 HTTP 503 envelope for `swap_drain_timeout` and
     R-3.4.4 envelope for `provider_loading`: are these
     OpenAI-SDK compatible? Match the SPEC-010 v1.x
     `model_not_warm` envelope pattern.

### Category D: AC coverage

D.1  Walk every R-3.x.y rule. For each, find at least one AC
     that exercises it. v0.2 has 20 ACs covering:
     - 4 CLI ACs (AC-1 through AC-4)
     - 5 state machine ACs (AC-5 through AC-9)
     - 3 heartbeat ACs (AC-10 through AC-12)
     - 2 Pillar A ACs (AC-13, AC-14)
     - 1 concurrent switch AC (AC-15)
     - 2 WS drop ACs (AC-16, AC-17)
     - 2 back-compat ACs (AC-18, AC-19)
     - 1 audit-log AC (AC-20)
     Rules to specifically check coverage for:
     - R-3.1.3 `--force` flag behavior — covered?
     - R-3.1.4 CLI-side cooldown — covered?
     - R-3.1.5 control socket protocol shapes — covered?
     - R-3.2.7 boot path unchanged — covered (probably via
       AC-18 implicit, but explicit AC?)
     - R-3.6.5 F-1.5 redaction — partially via AC-20
       negative checks; sufficient?
     - R-3.7.2 second switch NOT queued — covered?
     - R-3.7.3 CLI cooldown vs runtime cooldown distinction
       — covered?
     - R-3.8.5 reconnect MUST NOT start NEW load — covered?
     - R-3.9.1 swap_drain_timeout range validation —
       covered?
     If any rule has no AC = MAJOR per rule.

D.2  AC-18 "byte-identical" claim: same caveat as SPEC-010
     AC-13. Is log byte-identity testable, or does v0.2
     need a normalized-log assertion like SPEC-010 v1.1
     AC-13? Look for similar handling.

D.3  AC-20 negative-check approach: "JSON-key scan + content
     grep" for `conv:`, raw `account_id`, buyer prompt text,
     sticky-derivation inputs. Are the substring patterns
     comprehensive enough? Could a sneaky implementation
     pass the negative check while still leaking? If yes =
     MINOR.

### Category E: Companion-spec annotations

E.1  §6.1 SPEC-001 v1.2.5 candidate: lists new §6.6, §6.7,
     §6.8, §6.9 sections. Verify these section numbers
     don't conflict with existing SPEC-001 v1.2.4 §6.x
     numbering. If conflict = MINOR.

E.2  §6.2 SPEC-002 v1.3.5 candidate REPLACEMENT edit
     (D2.1 outline-audit fix): walk the replacement
     description carefully. Is the two-path behavior
     (legacy clear vs SPEC-011 re-verify) precise enough
     that a SPEC-002 v1.3.5 implementer can write it
     without re-reading SPEC-011?

E.3  §6.3 SPEC-008 v0.3 interaction "no normative edit":
     verify. v0.2 reuses §5.3-5.6 verification path. Does
     any v0.2 clause inadvertently require a §5.5 sixth
     state, a §5.7 hash block change, or a §5.6 routing
     predicate change? If yes = CRITICAL scope creep.

E.4  §6.4 SPEC-005 interaction "none": verify. R-3.4.x
     drain timeout produces per-request 503; the 503
     response doesn't write a `request_log` row? Or does
     it? Spot-check SPEC-005 X-2 to confirm 503-without-
     provider-dispatch behavior. If 503s DO write rows =
     MINOR (clarify).

E.5  §6.5 SPEC-004 interaction "none in normative
     behavior": verify the `loading: true` exclusion
     reuses existing non-`Ready` exclusion path, not a new
     SPEC-004 predicate.

E.6  §6.6 SPEC-010 v1.x REQUIRED dependency: verify the
     cited SPEC-010 rules (R-3.6.3, R-3.1.4) actually
     exist in current SPEC-010 (v1.2 is pre-lock; rules
     may shift).

### Category F: Scope discipline

F.1  Walk §3 section by section for any SPEC-012-territory
     surface. Specifically check:
     - No coordinator → provider control message (`set_model`
       is SPEC-012)
     - No parked queue or queue bounds
     - No cold-wake routing path
     - No `/v1/models` aggregation change
     - No `/v1/status.state` field
     - No `model_not_warm` envelope (SPEC-011's 503 envelopes
       are `provider_loading` and `swap_drain_timeout`; if
       any §3 clause introduces `model_not_warm` = MAJOR
       scope creep)
     If smuggled = CRITICAL.

F.2  Walk §3 for any SPEC-010-territory overlap.
     `supported_models[]` field is SPEC-010's; SPEC-011
     consumes it (R-3.1.2 step 2 validation). If v0.2 adds
     new normative rules to `supported_models` itself =
     MAJOR overlap with SPEC-010.

### Category G: Operator UX

G.1  CLI error messages (stderr text in R-3.1.2 steps): are
     they actionable? Do they tell the operator what to do
     next? If terse or non-actionable = MINOR.

G.2  Concurrent switch UX (§3.7): exit code 3 with diagnostic
     "wait for current switch to complete (macprovider-cli
     models status)" — is the recovery path clear?

G.3  WS-drop-mid-load audit gap (R-3.8.4): this is the
     C2.2-resolved observation-only invariant. §3.8 and
     R-3.6.6 document it normatively. Is the operator-facing
     consequence clear enough that an operator reading the
     spec understands "your swap audit history is
     best-effort during WS drops"? If buried = MINOR.

### Category H: Anything else

H.1  Documentation drift: HANDOFF.md, RUNBOOK.md,
     CONTINUE_RUNBOOK.md, AGENTS.md.

H.2  Naming nits.

H.3  Decision-log entry should be added when SPEC-011 v0.2
     locks. Note for executive summary; not a finding yet.

H.4  Anything code-grounded that v0.2 got wrong that doesn't
     fit C above.

## Output structure

Write to `/Users/augstar/macprovider-poc/specs/SPEC-011-audit.md`
as a NEW FILE. Frontmatter:

```
# SPEC-011 v0.2 — Audit Report (round 1 normative)

**Audited:** SPEC-011 v0.2 (specs/SPEC-011-operator-pushed-warm-swap.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 1 of N (normative; outline rounds at
specs/SPEC-011-outline-audit.md)
**Date:** 2026-06-06
**Total findings:** [N CRITICAL / N MAJOR / N MINOR / N QUESTION]

**Sibling audits:**
- specs/SPEC-010-audit.md — SPEC-010 v1.2 round 3 (in-flight
  fix pass)
- specs/SPEC-011-outline-audit.md — pre-draft outline rounds 1-2
- specs/SPEC-012-source-audit-history.md — wide-scope predecessor

---

## Executive summary

[2-4 paragraphs. State whether v0.2 is ready to lock as the
first normative draft, ready with the CRITICAL/MAJOR findings
closed, or needs structural revision. Be explicit about whether
the outline → normative conversion preserved scope discipline
and whether the code-grounding holds.]
```

Then for each category A-H write a section. For each finding:

```
### A.2  [SHORT TITLE]   [CRITICAL | MAJOR | MINOR | QUESTION]
Location: §3.3.5, line ~XXX; phase4-coordinator/internal/...

[What. 1-3 sentences.]

[Why it matters. 1-3 sentences.]

[Recommendation. 1-2 sentences.]
```

If a category has zero findings, write `(no findings)`.

## Out of scope

- Inspecting d-inference source (NOASSERTION license)
- Rewriting the spec
- Implementing the spec
- Auditing SPEC-001, SPEC-002, SPEC-004, SPEC-008 themselves
- Re-litigating outline-round-2 findings already marked PASS
  in the outline audit (only file as round-1 normative findings
  if v0.2 normative text introduced a NEW problem)
- Auditing SPEC-010 v1.2 (separate cycle currently in flight)

## Done criteria

You are done when:

- /Users/augstar/macprovider-poc/specs/SPEC-011-audit.md exists
  as a NEW file with round-1 normative findings
- Every category A-H has a section (even if "(no findings)")
- Every finding has severity, location, what/why/recommendation
- Executive summary states a clear verdict
- Code-grounding category (C) explicitly cites code locations
  verified

=== END PROMPT ===
```

---

## Operator notes

- Expected wall-clock: 25-40 min (first normative audit; more
  code-grounding work than outline audits).
- Decision after round 1:
  - 0 CRITICAL / 0-2 MAJOR → draft v0.3 closing the gaps, then
    round 2 → likely lock.
  - 0 CRITICAL / 3-6 MAJOR → typical first normative pass;
    contract-tightening v0.3 → round 2.
  - ≥1 CRITICAL → re-scope or pause for design review.
