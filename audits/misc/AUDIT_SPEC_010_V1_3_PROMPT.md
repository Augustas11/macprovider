# Audit prompt — SPEC-010 v1.3 (narrow scope, round 4)

Operator-paste prompt to audit SPEC-010 v1.3
(`specs/SPEC-010-model-catalog.md`).

**Round 4.** Trajectory so far:
- Round 1 (v1.0): 0 CRITICAL / 3 MAJOR / 1 MINOR
- Round 2 (v1.1): 0 CRITICAL / 3 MAJOR / 2 MINOR
- Round 3 (v1.2): 0 CRITICAL / 5 MAJOR / 0 MINOR
- Round 3 findings all clustered around **code-grounding gaps**:
  field table didn't match parser, retention key cited
  nonexistent field, timeout cited nonexistent locked text.

v1.3 is a code-grounded contract-tightening pass that claims to
close all 5 round-3 MAJORs:
- B3.1 fix: §3.1.A field table regenerated against actual
  `parseAuthInitial` (11 fields marked REQUIRED per parser,
  not "optional" per misleading struct tags); `auth_attempt_id`
  removed from initial-stage (parser doesn't read it)
- B3.4 fix: §3.1.B example includes all 13+ parser-required
  fields; "minimally valid" claim removed
- C3.2 fix: R-3.1.10 retention key explicitly defined as the
  coordinator-generated `authAttemptID` (server.go:354)
- A3.2 fix: R-3.1.10 timeout bound moved inline (10 min
  matching `challengeExpiresAt` at server.go:355) +
  SPEC-002 v1.3.5 candidate auth-attempt-lifecycle annotation
- D3.1 fix: AC-18 expanded from 3 to 6 sub-cases covering all
  5 R-3.1.10 clauses (retention creation, parser capture,
  cleanup on success/timeout/disconnect)

Round 4 has two jobs:
1. **Round-3 fix verification (R3V)** — for each round-3
   finding, cite the v1.3 rule/AC and mark PASS / PARTIAL /
   FAIL.
2. **Code-grounding re-verification** — v1.3 spent the entire
   change cycle on code-grounding. Spot-check that the new
   §3.1.A field table actually matches `parseAuthInitial`
   line-by-line, AND that the new R-3.1.10 clauses correctly
   describe server.go auth-attempt timing.

Append round-4 findings to existing
`specs/SPEC-010-audit.md` as a new top-level section after
round 3. Do not touch rounds 1-3.

Paste everything between `=== BEGIN PROMPT ===` and
`=== END PROMPT ===` into a fresh Codex CLI session rooted at
`/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are auditing SPEC-010 v1.3 at /Users/augstar/macprovider-poc/
specs/SPEC-010-model-catalog.md. This is round 4 of the audit on
the post-split narrow scope.

Round 3 (Codex GPT-5 on v1.2) found 0 CRITICAL / 5 MAJOR / 0
MINOR. All 5 MAJORs were code-grounding gaps. v1.3 claims to
close all 5 via code-grounded rewrites of §3.1.A field table,
§3.1.B example, R-3.1.10 retention key, R-3.1.10 timeout, and
AC-18 sub-case coverage.

You are NOT here to validate, rewrite, or extend the spec. Two
explicit jobs:

  J-1. **Round-3 fix verification (R3V).** For each round-3
       finding, cite the v1.3 rule/section/AC and mark PASS /
       PARTIAL / FAIL.

  J-2. **Code-grounding re-verification.** v1.3's premise is
       that the new §3.1.A table and R-3.1.10 contract are
       now accurate to the actual code. Spot-check every
       claim against the actual code:
       - Walk §3.1.A table row-by-row against
         `parseAuthInitial` at
         phase4-coordinator/internal/ws/messages.go lines
         333-388. Each REQUIRED row should correspond to a
         `requireString` / `requireInt` / `requireFloat` call.
         Each optional row should correspond to an `if v, ok
         := raw[<key>]; ok` guard. Any divergence = MAJOR.
       - Walk R-3.1.10 clause 1 (retention creation) against
         server.go:354-355: the coordinator-generated ID
         shape, attachment timing relative to auth_challenge
         emission. Any divergence = MAJOR.
       - Walk R-3.1.10 clause 4 cross-check (`provider_id`
         match) against server.go:398. Verify the existing
         match enforcement actually fires before SPEC-010
         retention logic would run. Any divergence = MAJOR.
       - Walk R-3.1.10 clause 5(c) timeout (10 minutes
         matching `challengeExpiresAt`) against
         server.go:355 + the proof-stage timeout check at
         server.go:398. Verify the cleanup-on-timeout claim
         is implementable (i.e. there's a clear point in the
         code where the retention map can be swept).

Output:
  /Users/augstar/macprovider-poc/specs/SPEC-010-audit.md

APPEND a new top-level section:
  `## Round 4 — Codex GPT-5 — 2026-06-06`
followed by category-organized findings. Do NOT touch rounds
1-3.

## Severity definitions

Unchanged from rounds 1-3.

## Critical constraints

**1. Locked decisions (§2 L-1..L-6) READ-ONLY.**

**2. SPEC-001 v1.2.4, SPEC-002 v1.3.4 LOCKED.** v1.3 §6.1 and
§6.2 candidate annotations now flag TWO normative additions
to SPEC-002 v1.3.5: (a) the v2 `auth_request` flow contract,
(b) the auth-attempt lifecycle. Verify these are framed as
candidate edits, not SPEC-010 commitments.

**3. v1.3's scope unchanged.** No SPEC-011 warm-swap or
SPEC-012 demand-pull surface.

**4. Code-grounding is the round-4 leverage point.** v1.3
spent the entire cycle on this. If §3.1.A still has a
row-to-code mismatch, it's a regression of the round-3 fix =
MAJOR (and a signal that the spec-without-code-check pattern
hasn't been corrected).

**5. R-3.1.10 retention implementation feasibility.** Walk
the new 5-clause contract against the actual server.go auth
flow. Are all four cleanup triggers (success, failure,
timeout, disconnect) implementable without coordinator
refactoring beyond the spec's stated scope? If a cleanup path
requires changes the spec doesn't anticipate = MAJOR.

**6. Clean-room.** Do NOT inspect d-inference source.

## Required reading (in order)

1. `/Users/augstar/macprovider-poc/specs/SPEC-010-model-catalog.md`
   v1.3 — the spec under audit. Read the v1.3 change log
   first. Then read §3.1 (rewritten with §3.1.A table +
   §3.1.B example), R-3.1.10 (rewritten with 5 detailed
   clauses), AC-18 (expanded to 6 sub-cases), §6.2 (SPEC-002
   v1.3.5 candidate with auth-attempt-lifecycle addition).

2. `/Users/augstar/macprovider-poc/specs/SPEC-010-audit.md` —
   round-3 findings. R3V target: find `### B3.1`, `### B3.4`,
   `### C3.2`, `### A3.2`, `### D3.1` in the round-3 section.

3. `/Users/augstar/macprovider-poc/CLAUDE.md` — conventions.

4. Code spot-checks (HIGHEST PRIORITY):
   - `phase4-coordinator/internal/ws/messages.go` lines
     37-57 (`AuthRequest` Go struct)
   - `phase4-coordinator/internal/ws/messages.go` lines
     302-329 (frame validator)
   - `phase4-coordinator/internal/ws/messages.go` lines
     333-388 (`parseAuthInitial` — definitive source for
     §3.1.A table)
   - `phase4-coordinator/internal/ws/messages.go` lines
     391-401 (`parseAuthProof`)
   - `phase4-coordinator/internal/ws/server.go` lines
     354-355 (`authAttemptID` generation +
     `challengeExpiresAt`)
   - `phase4-coordinator/internal/ws/server.go` lines
     359-367 (auth_challenge emission)
   - `phase4-coordinator/internal/ws/server.go` line 398
     (proof-stage validation: AuthAttemptID match,
     ProviderID match, expiry check)
   - `phase4-coordinator/internal/ws/server.go` lines
     379-403 (broader auth-attempt context)
   - `phase4-coordinator/internal/pool/provider.go` lines
     50-88 (Provider struct)
   - `phase4-coordinator/internal/buyer/server.go` lines
     1027-1030 (ModelKnown caller)

5. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   v1.2.4 — focus on §6.5 (verify v1.3's "documents legacy
   hello, not v2 auth_request" framing remains accurate).

6. `/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md`
   v1.3.4 — focus on §7.1, §7.3 (verify §6.2 candidate
   framing remains accurate; verify §7.3 truly does not
   contain auth-attempt-lifecycle text).

7. `/Users/augstar/macprovider-poc/specs/SPEC-008-tier2.md`
   v0.3 — verify zero interaction unchanged.

8. `/Users/augstar/macprovider-poc/specs/SPEC-011-operator-pushed-warm-swap.md`
   — confirm no SPEC-011 scope creep into v1.3.

## Audit categories — work through each

### Category R3V: Round-3 fix verification (HIGHEST PRIORITY)

Output as a table. Mark PASS / PARTIAL / FAIL with v1.3
location verified and 1-sentence evidence anchored to
spot-checked code.

- **R3V-B3.1** §3.1.A field table → v1.3 §3.1.A regenerated
  table; spot-check every row against parseAuthInitial
- **R3V-B3.4** §3.1.B example not parser-valid → v1.3 §3.1.B
  with full required field set; spot-check example would
  pass parseAuthInitial
- **R3V-C3.2** R-3.1.10 retention key → v1.3 R-3.1.10
  clause 1; spot-check `authAttemptID` generation timing
- **R3V-A3.2** R-3.1.10 timeout → v1.3 R-3.1.10 clause 5(c)
  + §6.2 SPEC-002 v1.3.5 auth-attempt-lifecycle candidate
- **R3V-D3.1** AC-18 coverage → v1.3 AC-18 sub-cases (a-f)

### Category A4: Locked-decision preservation (v1.3 re-verification)

A4.1  Walk L-1..L-6 against v1.3's new surface. R-3.1.10's
      new retention map is coordinator state; verify it
      produces no L-1 observable change for legacy providers
      (no SPEC-010 fields → no retention entry created).

A4.2  R-3.1.10 clause 5(c) periodic-sweep "at least every
      60s": is this a new periodic task the coordinator must
      run? If so, is there an existing sweeper that can host
      it (no new goroutine)? If a new goroutine is implied
      and not flagged = MINOR.

### Category B4: §3.1.A field table accuracy (round-4 re-verification)

B4.1  Walk EVERY row of v1.3 §3.1.A against the actual
      `parseAuthInitial` at messages.go:333-388. Specifically
      verify:
      - Required rows (provider_id, hostname, model_id,
        model_params_b, ram_gb, max_context_tokens,
        max_concurrency, throughput_tps_estimate,
        binary_version, provider_ecdh_public_key,
        tier2_capabilities) each correspond to a
        `requireString` / `requireInt` / `requireFloat` /
        ok-check call in parseAuthInitial.
      - Optional rows (model_hash, model_load_time_ms,
        endpoint_url) correspond to `if v, ok := raw[<key>];
        ok` guards.
      - The cited line numbers in the "Parser requiredness"
        column match the actual code.
      - The "About auth_attempt_id" note correctly states
        that the struct has the field but parseAuthInitial
        does NOT read it.
      Any divergence between table and code = MAJOR.

B4.2  §3.1.B example parser-validity: mentally walk the
      example JSON through parseAuthInitial. Does every
      `requireString` / `requireInt` / `requireFloat` find
      its key? Does the `tier2_capabilities` ok-check pass?
      If the example would fail parser-validation = MAJOR
      (round-3 finding B3.4 not closed).

B4.3  Tier-2 fields in example: `provider_ecdh_public_key:
      "BPwjzkU0..."` and `tier2_capabilities: {encrypted_leg:
      false, attestation: false, aead_suites: []}`. Is the
      example value `"BPwjzkU0..."` a plausibly-shaped
      base64 ECDH key, or pure placeholder? If
      placeholder-only and a tester would copy it = MINOR
      (clarify it's a placeholder).

### Category C4: R-3.1.10 contract precision (round-4 re-verification)

C4.1  R-3.1.10 clause 1 retention timing: "Immediately
      before sending the outgoing `auth_challenge`." Is
      this a concrete timing point in server.go? Walk
      server.go:354-367 to see if there's a clear place to
      attach the retention entry between
      `authAttemptID :=` generation and `auth_challenge`
      send. If the order is ambiguous = MINOR.

C4.2  R-3.1.10 clause 1 retention entry fields: includes
      `provider_id` "from initial-stage (cross-check
      defense; see clause 4)." Clause 4 then says the
      proof-stage `provider_id` match is "current code at
      server.go:398 already enforces this; the retention
      cross-check is defensive." Is the retention's own
      `provider_id` cross-check redundant given existing
      code? If yes = MINOR (de-duplicate or justify the
      defense-in-depth).

C4.3  R-3.1.10 clause 5(c) periodic sweep: 60s upper bound.
      Is this realistic for the implementation? If the
      timeout fires at exactly 10 minutes but the sweeper
      runs at minute marks, the retention entry could
      persist up to 10:59 in the worst case. Is that
      acceptable, or does the spec need tighter timing? If
      a 1-minute slack on a 10-minute timeout is OK = no
      finding.

C4.4  R-3.1.10 clause 5(d) disconnect cleanup: "the
      disconnect handler MUST release the retention entry
      on the way out, regardless of whether the auth
      attempt was in initial-pending or proof-pending
      state." Is there a single disconnect handler that
      can do this, or do multiple paths (WS read error,
      WS write error, idle timeout) need to be
      coordinated? Spot-check the WS lifecycle code. If
      multiple paths and the spec only requires "the"
      handler = MAJOR.

C4.5  R-3.1.10 implementations SHOULD bound aggregate
      retention map size at 10000 entries with oldest-
      evict. Is 10000 justified? Cross-reference any
      coordinator memory budget. If arbitrary = MINOR.

### Category D4: AC quality (AC-18 expansion + AC-1 through AC-23)

D4.1  AC-18(d) "via coordinator debug/test hook":
      coordinator currently has test hooks for fault
      injection? If not, the AC requires a new test API
      that the spec doesn't mention. Spot-check coordinator
      test infrastructure. If a new hook is implied = MINOR
      (flag the implementation dependency).

D4.2  AC-18(e) timeout sub-case: "simulate 11 minutes
      elapsed." Coordinator clock injection is a standard
      test hook (the parser uses `s.now()` per
      server.go:355). Confirm test feasibility. If clock
      injection isn't possible = MAJOR.

D4.3  AC-18(f) bounded-state assertion: "after 100 such
      partial auth attempts followed by disconnect,
      retention map size returns to baseline." Is "baseline"
      defined? Should be 0 (or pre-test count). If undefined
      = MINOR.

D4.4  AC-13 normalized-log assertion: still applies under
      v1.3? v1.3 doesn't change AC-13. Just confirm it
      survived the v1.3 edits (it should).

### Category E4: Companion-spec annotation framing

E4.1  §6.2 SPEC-002 v1.3.5 candidate now flags TWO additions:
      v2 auth_request flow + auth-attempt lifecycle. Verify
      both are framed as candidate edits (NOT SPEC-010
      commitments). If wording slips into prescriptive "MUST
      change SPEC-002" = MAJOR.

E4.2  §6.2 auth-attempt lifecycle annotation: 5 bullet points
      detailing what SPEC-002 v1.3.5 must add. Verify each
      bullet matches the implementation reality the spec
      itself cited. Are the bullets implementable as written?

### Category F4: Anything else

F4.1  Documentation drift.

F4.2  Naming nits.

F4.3  Hidden surfaces v1.3 exposes that round 3 didn't probe.

F4.4  Decision-log entry for the eventual lock. Note for
      executive summary; not a finding yet.

F4.5  Convergence assessment: v1.0 → v1.1 → v1.2 → v1.3
      MAJOR counts were 3 / 3 / 5 / ?. Does v1.3 bring the
      count to 0-1 (lock condition) or is there still
      cluster risk?

## Output structure

APPEND to `/Users/augstar/macprovider-poc/specs/SPEC-010-audit.md`.
Start your section with:

```
---

## Round 4 — Codex GPT-5 — 2026-06-06

**Audited:** SPEC-010 v1.3 (specs/SPEC-010-model-catalog.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 4 of N
**Date:** 2026-06-06
**Total findings:** [N CRITICAL / N MAJOR / N MINOR / N QUESTION]

### Round-4 executive summary

[2-3 paragraphs. State whether v1.3 is ready to LOCK directly,
ready after the round-4 findings are closed, or needs another
revision. Specifically address whether the code-grounding
fixes actually held against spot-checks.]

### Round-3 fix verification (R3V)

[Table: round-3 finding ID, PASS / PARTIAL / FAIL, v1.3
location verified, 1-sentence evidence with code citation.]
```

Then for each category R3V, A4-F4 write a section. For each
finding: severity, location, what/why/recommendation.

If a category has zero findings, write `(no findings)`.

## Out of scope

- Inspecting d-inference source
- Rewriting the spec
- Implementing the spec
- Auditing SPEC-001, SPEC-002, SPEC-004, SPEC-008 themselves
- Auditing SPEC-011 v0.2 (separate cycle currently in flight)
- Re-litigating round-1, round-2, or round-3 findings marked
  PASS

## Done criteria

You are done when:

- Round-4 section APPENDED to SPEC-010-audit.md (rounds 1-3
  intact)
- Every round-3 finding has PASS / PARTIAL / FAIL in R3V
- Every category R3V, A4-F4 has a section (even if "(no
  findings)")
- Every finding has severity, location, what/why/recommendation
- Round-4 executive summary states a clear verdict

=== END PROMPT ===
```

---

## Operator notes

- Expected wall-clock: 15-25 min (small contract-tightening
  surface to audit; the work is mostly spot-check
  verification of code-grounding claims).
- Convergence target: 0 CRITICAL / 0 MAJOR → lock SPEC-010
  v1.3 directly.
- If ≥1 CRITICAL or >1 MAJOR, draft v1.4 narrow fix → round 5.
  But v1.3's premise is "code-grounded this time" — if the
  audit finds NEW code-grounding gaps, that's a process
  signal beyond the spec text itself.
