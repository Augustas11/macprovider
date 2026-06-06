# Audit prompt — SPEC-010 v1.4 (narrow scope, round 5 — lock target)

Operator-paste prompt to audit SPEC-010 v1.4
(`specs/SPEC-010-model-catalog.md`).

**Round 5.** Trajectory:
- Round 1 (v1.0): 0 CRITICAL / 3 MAJOR / 1 MINOR
- Round 2 (v1.1): 0 CRITICAL / 3 MAJOR / 2 MINOR
- Round 3 (v1.2): 0 CRITICAL / 5 MAJOR / 0 MINOR
- Round 4 (v1.3): 0 CRITICAL / 2 MAJOR / 5 MINOR — strong
  convergence
- Round 5 (v1.4) target: **0 CRITICAL / 0 MAJOR → lock**

v1.4 is a narrow contract-tightening pass that claims to close
all 7 round-4 findings (2 MAJOR + 5 MINOR):
- B4.1 MAJOR: `attestation_token` REMOVED from §3.1.A initial-
  stage table; new §3.1.C proof-stage table places it correctly
- C4.4 MAJOR: R-3.1.10 clause 5 rewritten — auth-attempt-scoped
  `defer releaseRetention(authAttemptID)` covering all 5
  termination paths (success / proof-fail / 10-min-expiry /
  pre-proof-disconnect / challenge-write-fail)
- A4.2 MINOR: periodic-sweeper option REMOVED; all cleanup is
  synchronous via defer
- B4.3 MINOR: ECDH placeholder text replaced with explicit
  label `"<base64url-32-byte-x25519-public-key>"`
- C4.2 MINOR: retained `provider_id` reframed as
  defense-in-depth
- C4.5 MINOR: retention map cap tied to
  `ws.max_unauthenticated_conn` (default 64) — no separate cap
- D4.1 MINOR: AC-18(d) explicitly requires package-internal
  test accessor
- D4.3 MINOR: AC-18(f) "baseline" defined as pre-test
  retention map size with 4-step procedure

Round 5 has two jobs:
1. **R4V — Round-4 fix verification.** For each round-4
   finding, cite v1.4 location and mark PASS / PARTIAL / FAIL.
2. **Lock readiness check.** Round 5 is a small-surface
   verification pass. If 0 CRITICAL / 0 MAJOR, SPEC-010 v1.4
   is ready to lock; the audit's verdict should explicitly
   say so.

Append round-5 findings to existing
`specs/SPEC-010-audit.md` as a new top-level section after
round 4. Do not touch rounds 1-4.

Paste everything between `=== BEGIN PROMPT ===` and
`=== END PROMPT ===` into a fresh Codex CLI session rooted at
`/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are auditing SPEC-010 v1.4 at /Users/augstar/macprovider-poc/
specs/SPEC-010-model-catalog.md. This is round 5 of the audit
on the post-split narrow scope, and the **lock-readiness
check**.

Round 4 (Codex GPT-5 on v1.3) found 0 CRITICAL / 2 MAJOR /
5 MINOR. v1.4 claims to close all 7. Both round-4 MAJORs
were code-precision items at the initial-stage table boundary
(B4.1: `attestation_token` misplaced) and the R-3.1.10
cleanup mechanism (C4.4: cleanup handler was wrong).

You are NOT here to validate, rewrite, or extend the spec.
Two explicit jobs:

  J-1. **R4V — Round-4 fix verification.** For each round-4
       finding (B4.1, C4.4, A4.2, B4.3, C4.2, C4.5, D4.1,
       D4.3), cite the v1.4 rule/section/AC and mark PASS /
       PARTIAL / FAIL.

  J-2. **Lock readiness verdict.** v1.4's target is 0
       CRITICAL / 0 MAJOR. State explicitly whether v1.4 is
       READY TO LOCK or whether further iteration is needed.

Output:
  /Users/augstar/macprovider-poc/specs/SPEC-010-audit.md

APPEND a new top-level section:
  `## Round 5 — Codex GPT-5 — 2026-06-06`
followed by category-organized findings. Do NOT touch rounds
1-4.

## Severity definitions

Unchanged from rounds 1-4.

## Critical constraints

**1. Locked decisions (§2 L-1..L-6) READ-ONLY.**

**2. SPEC-001 v1.2.4, SPEC-002 v1.3.4 LOCKED.** v1.4's
§6.1/§6.2 candidate annotations should be unchanged from
v1.3 except for the auth-attempt lifecycle clarification.

**3. v1.4's scope unchanged.** No SPEC-011 or SPEC-012
surface smuggled in.

**4. Code-grounding remains the highest leverage check.**
v1.4's two MAJOR fixes both touched code-precision claims:
- §3.1.C proof-stage table — verify against `parseAuthProof`
  at messages.go:391-401
- R-3.1.10 clause 5 defer enumeration — verify against
  `handleV2Conn` failure paths in server.go

**5. Clean-room.** Do NOT inspect d-inference source.

## Required reading (in order)

1. `/Users/augstar/macprovider-poc/specs/SPEC-010-model-catalog.md`
   v1.4 — the spec under audit. Read the v1.4 change log
   first. Then read:
   - §3.1.A field table (verify `attestation_token` is GONE)
   - §3.1.C new proof-stage field table (B4.1 fix)
   - §3.1.B example (verify ECDH placeholder change, B4.3)
   - R-3.1.10 clause 1 (retention cap note, C4.5; defense-
     in-depth note, C4.2; defer install timing in step (ii))
   - R-3.1.10 clause 5 (defer-based cleanup, C4.4 + A4.2)
   - AC-18(d) test accessor (D4.1)
   - AC-18(e) timeout sub-case (no longer cites sweeper)
   - AC-18(f) baseline definition (D4.3)

2. `/Users/augstar/macprovider-poc/specs/SPEC-010-audit.md` —
   round-4 findings (R4V target). Find `### B4.1`, `### C4.4`,
   `### A4.2`, `### B4.3`, `### C4.2`, `### C4.5`, `### D4.1`,
   `### D4.3` in the round-4 section.

3. `/Users/augstar/macprovider-poc/CLAUDE.md` — conventions.

4. Code spot-checks (highest priority):
   - `phase4-coordinator/internal/ws/messages.go` lines
     333-388 (parseAuthInitial — verify §3.1.A still matches)
   - `phase4-coordinator/internal/ws/messages.go` lines
     391-401 (parseAuthProof — verify §3.1.C matches)
   - `phase4-coordinator/internal/ws/server.go` lines
     223-238, 315-421 (handleConn + handleV2Conn — verify
     R-3.1.10 clause 5 defer enumeration covers all return
     paths)
   - `phase4-coordinator/internal/ws/server.go` line 398
     (proof validation: AuthAttemptID + ProviderID + expiry
     checks)
   - `phase4-coordinator/internal/ws/server.go` lines
     330-333 (`tier2.ParseX25519PublicKey` — verify B4.3
     ECDH placeholder claim)
   - `phase4-coordinator/internal/config/config.go` line 269
     (`MaxUnauthenticatedConn: 64` — verify C4.5 cap claim)
   - `phase4-coordinator/internal/ws/server.go` line 111
     (cfg.ProviderWSMaxUnauthenticatedConn() usage — verify
     it actually bounds in-flight auth attempts)

5. `/Users/augstar/macprovider-poc/specs/SPEC-011-operator-pushed-warm-swap.md`
   — confirm no SPEC-011 scope creep into v1.4.

## Audit categories — work through each

### Category R4V: Round-4 fix verification (HIGHEST PRIORITY)

Output as a table. Mark PASS / PARTIAL / FAIL with v1.4
location verified and 1-sentence evidence anchored to code
where applicable.

- **R4V-B4.1** `attestation_token` in initial-stage table →
  v1.4 §3.1.A row REMOVED + §3.1.C proof-stage note
- **R4V-C4.4** disconnect cleanup wrong handler → v1.4
  R-3.1.10 clause 5 defer-based enumeration
- **R4V-A4.2** periodic sweeper implies new machinery →
  v1.4 clause 5 sweeper option REMOVED
- **R4V-B4.3** ECDH placeholder invalid → v1.4 §3.1.B
  `"<base64url-32-byte-x25519-public-key>"`
- **R4V-C4.2** retained `provider_id` redundant → v1.4
  clause 1 defense-in-depth note
- **R4V-C4.5** retention cap arbitrary → v1.4 clause 1
  tied to `ws.max_unauthenticated_conn`
- **R4V-D4.1** AC-18(d) debug hook unspecified → v1.4
  AC-18(d) explicit package-internal accessor
- **R4V-D4.3** AC-18(f) baseline undefined → v1.4 AC-18(f)
  4-step procedure

### Category A5: Locked-decision preservation (v1.4 re-verification)

A5.1  Walk L-1..L-6 against v1.4's reduced surface. v1.4
      REMOVED the optional sweeper from clause 5(c). Did
      this introduce any L-1 regression? Specifically: with
      no SPEC-010 fields sent, is the defer mechanism still
      installed (introducing observable internal state)?
      The defer should ONLY install when SPEC-010 fields
      are present in the initial frame.

A5.2  R-3.1.10 clause 1 step (ii) "install `defer
      releaseRetention(authAttemptID)`": is this gated on
      SPEC-010 fields being present? If a legacy provider
      hits the same code path, does the defer still run
      (harmlessly releasing a non-existent entry)? If the
      defer runs unconditionally = MINOR (no observable
      effect but still some implementation noise).

### Category B5: §3.1.C proof-stage table accuracy

B5.1  Walk every row of §3.1.C against parseAuthProof at
      messages.go:391-401. Verify:
      - `type`, `version`, `stage` from frame validator
      - `auth_attempt_id` REQUIRED by parseAuthProof:392
      - `provider_id` REQUIRED by parseAuthProof:393-395
      - `attestation_token` checked at server.go:403 if
        Tier-2 required
      - SPEC-010 fields `supported_models` and
        `publishes_supported_models` per R-3.1.10 clause 2
      Any row that doesn't match the actual proof-stage
      parsing = MAJOR.

B5.2  §3.1.C cross-reference to §3.1.A: does §3.1.A still
      claim it documents "initial-stage" without polluting
      with proof-stage rows? Re-verify no `attestation_token`
      row remains in §3.1.A.

### Category C5: R-3.1.10 clause 5 defer mechanism

C5.1  Walk R-3.1.10 clause 5 sub-clauses (a)-(e) against
      `handleV2Conn` return paths in server.go:315-421.
      For each documented termination path, verify the
      `defer releaseRetention(authAttemptID)` would
      actually fire:
      - (a) Successful completion — defer fires on normal
        return after `registerProviderSession`
      - (b) Proof-stage failure (5 sub-cases) — defer fires
        on each error return
      - (c) 10-minute expiry — server.go:398 rejection
        returns; defer fires
      - (d) Pre-proof disconnect / read error / parse error
        — `handleV2Conn` returns; defer fires (the C4.4 fix)
      - (e) Challenge write failure — `handleV2Conn`
        returns; defer fires
      If any termination path isn't covered by the defer =
      MAJOR (the C4.4 fix is incomplete).

C5.2  Clause 1 step (ii) defer install location:
      "immediately after creating the retention entry
      (before sending the `auth_challenge`)." Is this
      sequence correct in Go semantics? If the defer is
      installed BEFORE the auth_challenge write attempt,
      then a write failure (clause 5(e)) IS covered. If
      installed AFTER, write failure leaks. Verify the
      spec's ordering claim matches Go defer semantics.

C5.3  C4.5 cap claim: "Each unauthenticated WS slot can
      host AT MOST ONE in-flight auth-attempt at a time."
      Walk server.go:111 + the auth flow to confirm:
      does one WS connection correspond to AT MOST one
      simultaneous auth-attempt with a retention entry?
      If a single connection could spawn multiple
      concurrent auth-attempts (parallel-handshake retries,
      etc.), the cap reasoning is wrong = MAJOR.

C5.4  C4.2 defense-in-depth note: clause 1 says
      implementations MAY omit storing `provider_id` if the
      invariant stays co-located. Is "co-located" precise
      enough? An implementer might omit, then a later
      refactor breaks the co-location and silently weakens
      the check. If under-specified = MINOR.

### Category D5: AC-18 sub-case refinements

D5.1  AC-18(d) test accessor: "unexported `retentionLookup`
      reachable from `_test.go` files within the same
      package." Is this the right idiom for the
      `phase4-coordinator/internal/ws/` package? Spot-check
      existing test-accessor patterns in the package (look
      for any existing `_test.go` helpers).

D5.2  AC-18(e) timeout sub-case: replaces "background
      sweep" wording with "synchronous on `handleV2Conn`
      return." Walk: does server.go:398's expiry rejection
      actually return from `handleV2Conn`? Yes, presumably,
      but verify. If the rejection logs-and-continues
      somewhere = MAJOR.

D5.3  AC-18(f) baseline procedure: 4 steps including
      `retentionMapSize()` accessor. Is the AC realistic
      to implement? The 1s settlement window for in-flight
      defers — is this an arbitrary number or anchored to
      anything? If arbitrary = MINOR.

### Category E5: Companion-spec annotations

E5.1  §6.1 / §6.2 candidate annotations unchanged from v1.3
      except for any v1.4-related additions. Verify no
      framing slipped.

E5.2  §6.2 auth-attempt lifecycle annotation: v1.3 added it
      as a SPEC-002 v1.3.5 candidate. v1.4 still keeps it?
      Verify present.

### Category F5: Lock readiness assessment

F5.1  Overall convergence: v1.0 → v1.1 → v1.2 → v1.3 →
      v1.4 MAJOR counts were 3 / 3 / 5 / 2 / ?. State
      whether v1.4 reaches 0-MAJOR (lock condition).

F5.2  Decision-log entry: not a finding, but note for
      executive summary — when v1.4 locks, an entry should
      be added to `beta/DECISION_CRITERIA.md` summarizing
      the split decision (SPEC-010 / SPEC-011 / SPEC-012)
      and the 5-round audit history.

F5.3  Implementation readiness: is v1.4 implementable from
      its text alone, OR does it require any clarification
      that round-5 audit found? If 0 CRITICAL / 0 MAJOR /
      acceptable MINORs, SPEC-010 v1.4 is the lockable
      contract for the SPEC-001 v1.2.5 / SPEC-002 v1.3.5
      BUILD prompts.

### Category G5: Anything else

G5.1  Documentation drift.

G5.2  Naming nits.

G5.3  Hidden surfaces v1.4 introduced.

## Output structure

APPEND to `/Users/augstar/macprovider-poc/specs/SPEC-010-audit.md`.
Start with:

```
---

## Round 5 — Codex GPT-5 — 2026-06-06

**Audited:** SPEC-010 v1.4 (specs/SPEC-010-model-catalog.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 5 of N
**Date:** 2026-06-06
**Total findings:** [N CRITICAL / N MAJOR / N MINOR / N QUESTION]

### Round-5 executive summary

[2-3 paragraphs. State explicitly: "READY TO LOCK" or
"narrow v1.5 fix needed" or "structural revision." Anchor
the verdict to the 0-CRITICAL / 0-MAJOR target.]

### Round-4 fix verification (R4V)

[Table format with PASS / PARTIAL / FAIL + v1.4 location +
1-sentence evidence with code citation.]
```

Then for each category R4V, A5-G5 write a section. For each
finding: severity, location, what/why/recommendation.

If a category has zero findings, write `(no findings)`.

## Out of scope

- Inspecting d-inference source
- Rewriting the spec
- Implementing the spec
- Auditing SPEC-001, SPEC-002, SPEC-004, SPEC-008 themselves
- Auditing SPEC-011 (separate cycle in flight)
- Re-litigating round-1, round-2, round-3, or round-4
  findings marked PASS

## Done criteria

You are done when:

- Round-5 section APPENDED to SPEC-010-audit.md (rounds
  1-4 intact)
- Every round-4 finding has PASS / PARTIAL / FAIL in R4V
- Every category R4V, A5-G5 has a section (even if "(no
  findings)")
- Every finding has severity, location, what/why/recommendation
- Round-5 executive summary states an EXPLICIT lock-or-not
  verdict

=== END PROMPT ===
```

---

## Operator notes

- Expected wall-clock: 10-20 min (small contract-tightening
  surface; round-5 is verification, not new design).
- Convergence target: 0 CRITICAL / 0 MAJOR → lock SPEC-010
  v1.4. Append decision-log entry to
  `beta/DECISION_CRITERIA.md` after lock.
- If ≥1 CRITICAL or >1 MAJOR, narrow v1.5 fix pass + round 6.
  But v1.4's premise is "all 7 round-4 findings closed
  mechanically" — non-convergence at this point would
  signal a deeper process issue beyond the spec text.
