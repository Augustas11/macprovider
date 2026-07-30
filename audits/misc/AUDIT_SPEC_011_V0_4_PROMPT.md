# Audit prompt — SPEC-011 v0.4 normative (round 3)

Operator-paste prompt to audit SPEC-011 v0.4
(`specs/SPEC-011-operator-pushed-warm-swap.md`).

**Round 3 normative.** Trajectory:
- Round 1 (v0.2): 2 CRITICAL / 5 MAJOR / 3 MINOR
- Round 2 (v0.3): 0 CRITICAL / 2 MAJOR / 4 MINOR — both
  round-1 CRITICALs (A.1 L-1 lock violation, C.1 macOS
  path) closed in substance
- Round 3 (v0.4) target: **0 CRITICAL / 0 MAJOR → lock**
  (parallels SPEC-010 v1.4-v1.5 lock trajectory)

v0.4 is a code-grounded contract-tightening pass that
claims to close all 6 round-2 findings:
- **R2-B2.1 MAJOR**: §3.9 config block updated to
  `$TMPDIR/...` (matches R-3.1.5); added `--enable-warm-swap`
  + `--switch-state-path` flags; added R-3.9.2 anti-
  regression rule; AC-26 grep assertion
- **R2-C2.1 MAJOR**: §3.1.2 step 4 rewritten with typed
  R-3.1.5 frames (`type` REQUIRED everywhere); §3.2 prose
  + AC-24 prose updated to typed-frame references; no
  untyped shorthand remains
- **R2-A2.1 MINOR**: R-3.1.5.x detection precedence rule
  (ENOENT / ECONNREFUSED / handshake-timeout)
- **R2-A2.2 MINOR**: AC-18 extended with /v1/status,
  /v1/models, /v1/chat/completions byte-identical
  assertions against pre-SPEC-011 baseline
- **R2-G2.1 MINOR**: AC-23 explicit package-internal test
  accessor (same pattern as SPEC-010 v1.4 AC-18(d))
- **R2-K2.1 MINOR**: AC count footer updated to 26;
  AC-25 unit label fixed (`< 5s minimum`); stale "v0.2"
  self-references updated to "v0.4"

Round 3 has two jobs:
1. **R2V — Round-2 fix verification.** For each of the 6
   round-2 findings, cite v0.4 location and mark
   PASS / PARTIAL / FAIL.
2. **Lock readiness verdict.** If 0 CRITICAL / 0 MAJOR,
   state "READY TO LOCK." If 0 CRITICAL with 1-2 MINOR,
   state "LOCK-READY pending narrow polish." If any new
   CRITICAL/MAJOR, state what's needed.

Append round-3 findings to existing
`specs/SPEC-011-audit.md` as a new top-level section
after round 2.

Paste everything between `=== BEGIN PROMPT ===` and
`=== END PROMPT ===` into a fresh Codex CLI session
rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are auditing SPEC-011 v0.4 at /Users/augstar/macprovider-poc/
specs/SPEC-011-operator-pushed-warm-swap.md. This is round 3
of the normative audit.

Round 2 (Codex GPT-5 on v0.3) found 0 CRITICAL / 2 MAJOR /
4 MINOR. v0.4 claims to close all 6.

Sibling context: SPEC-010 v1.5 was LOCKED in round 6 of its
audit cycle (specs/SPEC-010-audit.md). SPEC-011 v0.4 is
designed to lock on a similar trajectory.

You are NOT here to validate, rewrite, or extend the spec.
Two explicit jobs:

  J-1. **R2V — Round-2 fix verification.** For each of:
       R2-B2.1, R2-C2.1, R2-A2.1, R2-A2.2, R2-G2.1, R2-K2.1
       — cite v0.4 location and mark PASS/PARTIAL/FAIL.

  J-2. **Lock readiness verdict.** Explicitly state:
       - "READY TO LOCK" if 0 CRITICAL / 0 MAJOR / 0 MINOR
       - "LOCK-READY pending narrow polish" if 0 CRITICAL /
         0 MAJOR / 1-2 MINOR
       - "Narrow v0.5 fix needed" if 0 CRITICAL / 1-3 MAJOR
       - "Structural revision needed" if any CRITICAL or
         many MAJORs

Output:
  /Users/augstar/macprovider-poc/specs/SPEC-011-audit.md

APPEND a new top-level section:
  `## Round 3 — Codex GPT-5 — 2026-06-06`
followed by R2V table + category findings. Do NOT touch
rounds 1-2.

## Severity definitions

Unchanged from rounds 1-2.

## Critical constraints

**1. Locked decisions (§2 L-1..L-7) READ-ONLY.**

**2. SPEC-001 v1.2.4, SPEC-002 v1.3.4, SPEC-010 v1.5
LOCKED.** SPEC-010 v1.5 just locked in its round 6.
Cross-spec citations to SPEC-010 should now reference v1.5
or "v1.x locked." Verify v0.4 doesn't accidentally cite a
SPEC-010 rule that doesn't exist in v1.5.

**3. v0.4's scope unchanged.** No SPEC-010/SPEC-012
surface smuggled in.

**4. Code-grounding remains the highest leverage check.**
v0.4's R2-B2.1 fix added R-3.9.2 explicitly forbidding
`$XDG_RUNTIME_DIR`; v0.4's R2-C2.1 fix rewrote §3.1.2
with typed frames. Both are contract-precision fixes —
verify against actual code where applicable.

**5. R-3.1.5.x detection precedence rule (R2-A2.1)** is
the new operational-UX surface. Verify it's implementable
against the actual Unix domain socket primitives macOS
provides:
- ENOENT detection: `stat(socket_path)` returns ENOENT —
  standard
- ECONNREFUSED detection: `connect(socket_path)` returns
  ECONNREFUSED — standard for stale Unix sockets
- 2s status_request handshake timeout — standard read
  deadline

**6. Clean-room.** No d-inference inspection.

## Required reading (in order)

1. `/Users/augstar/macprovider-poc/specs/SPEC-011-operator-pushed-warm-swap.md`
   v0.4 — the spec under audit. Read the v0.4 change log
   first. Then read:
   - L-1 wording (unchanged from v0.3)
   - R-3.1.0 opt-in gate (unchanged from v0.3)
   - R-3.1.2 step 3 + step 4 (R2-C2.1 fix — typed frames)
   - R-3.1.5 (unchanged from v0.3)
   - R-3.1.5.x NEW detection precedence rule (R2-A2.1 fix)
   - §3.9 config block + R-3.9.1 + R-3.9.2 NEW
     (R2-B2.1 fix)
   - AC-18 extended (R2-A2.2 fix)
   - AC-23 with test accessor (R2-G2.1 fix)
   - AC-25 unit label (R2-K2.1 fix)
   - AC-26 NEW anti-regression assertion (R2-B2.1
     supporting)
   - §5 footer + AC count = 26
   - §10 OQ-1..OQ-4 (v0.3 → v0.4 / v0.5 cleanup)

2. `/Users/augstar/macprovider-poc/specs/SPEC-011-audit.md` —
   rounds 1 and 2. R2V target: find `### R2-A2.1`,
   `### R2-A2.2`, `### R2-B2.1`, `### R2-C2.1`,
   `### R2-G2.1`, `### R2-K2.1` in round-2 section.

3. `/Users/augstar/macprovider-poc/CLAUDE.md` —
   conventions.

4. `/Users/augstar/macprovider-poc/specs/SPEC-010-model-catalog.md`
   v1.5 — verify cross-spec citations. SPEC-010 just
   locked; SPEC-011 R-3.1.2 step 2 cites SPEC-010 R-3.6.3.
   Verify R-3.6.3 still exists in v1.5.

5. `/Users/augstar/macprovider-poc/specs/SPEC-010-audit.md`
   round 6 — for context on the sibling lock trajectory.

6. Code spot-checks:
   - `phase4-coordinator/internal/ws/messages.go`
     heartbeat struct (still lacks model_hash/loading
     — matches v0.4 §3.3 ADD claim)
   - `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
     lines 294-325 (still raw lowercase hex output)
   - `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
     lines 7-15 (no `models` subcommand conflict)
   - **macOS env**: `printenv TMPDIR` (verify still set)
   - **macOS env**: `printenv XDG_RUNTIME_DIR` (verify
     still unset — anchors R-3.9.2 and AC-26 rationale)

## Audit categories

### Category R2V: Round-2 fix verification (HIGHEST PRIORITY)

Table format. PASS/PARTIAL/FAIL with v0.4 location +
1-sentence evidence (anchored to code or spec line numbers).

- **R2-B2.1** §3.9 advertises stale `$XDG_RUNTIME_DIR` →
  v0.4 §3.9 + R-3.9.2 + AC-26
- **R2-C2.1** §3.1.2 step 4 untyped shorthand → v0.4
  R-3.1.2 step 4 typed frames
- **R2-A2.1** disabled-vs-no-serve detection ambiguous →
  v0.4 R-3.1.5.x precedence rule
- **R2-A2.2** AC-18 doesn't cover all L-1 observables →
  v0.4 AC-18 extended assertions
- **R2-G2.1** AC-23 debug hook undefined → v0.4 AC-23
  package-internal accessor
- **R2-K2.1** editorial residue → v0.4 AC count = 26,
  AC-25 unit label fixed, §10 OQs cleaned

### Category A3: Locked-decision preservation

A3.1  Walk L-1..L-7 against v0.4's narrow surface
      changes. Specifically: does R-3.1.5.x add any
      observable behavior in `--enable-warm-swap=false`
      mode? It shouldn't — the precedence rule is for
      the CLI side detecting disabled state, which only
      runs when the operator actually invokes `models`.

A3.2  R-3.9.2 forbids `$XDG_RUNTIME_DIR` in spec text.
      Verify the rule doesn't accidentally also forbid
      mentioning the historical context in the change
      log (which is needed for traceability).

### Category B3: §3.1.2 + §3.9 cross-section consistency

B3.1  §3.1.2 step 4 typed frames: verify the field set
      cited there matches R-3.1.5 Field reference
      exactly. Any field present in step 4 but not in
      R-3.1.5 = MAJOR. Any required field missing from
      step 4's example = MINOR.

B3.2  §3.9 config block: lists `--enable-warm-swap`,
      `--swap-drain-timeout-seconds`, `--ctl-socket-path`,
      `--switch-state-path`. Verify default values match
      their normative-rule sources (R-3.1.0, R-3.9.1,
      R-3.1.5, R-3.1.4 respectively).

B3.3  AC-26 grep assertion: matches v0.4 spec text. Walk
      a literal `grep XDG_RUNTIME_DIR
      specs/SPEC-011-operator-pushed-warm-swap.md` —
      does every match land in a historical/forbidden
      context as the AC requires?

### Category C3: R-3.1.5.x detection precedence

C3.1  Walk the 3-case precedence rule (ENOENT /
      ECONNREFUSED / handshake timeout). Are the
      ordering and error semantics correct against
      actual macOS Unix-domain-socket behavior? If a
      stale socket file present + no listener returns
      ECONNREFUSED reliably on macOS = PASS. If it can
      return EAGAIN or another errno = MAJOR.

C3.2  Case (3) handshake timeout 2s — is this
      justified? Real serve processes respond to
      `status_request` in << 100ms; 2s is generous.
      If arbitrary but defensible = no finding.

C3.3  The case (3) note says "should not occur with a
      correctly-implemented v0.4 serve" because R-3.1.0
      mandates no socket in disabled mode. Verify R-3.1.0
      says exactly that.

### Category D3: AC-18 expansion

D3.1  AC-18's new /v1/status, /v1/models,
      /v1/chat/completions assertions: are they
      implementable? Specifically, the
      /v1/chat/completions assertion uses
      `temperature: 0` and `seed: <fixed>` to make
      sampling deterministic. Is this sufficient for
      byte-identical assertion across runs? If MLX
      sampling has nondeterminism beyond temperature/
      seed = MINOR (the AC needs additional
      controls).

D3.2  /v1/status and /v1/models comparison: the AC says
      "excluding SPEC-010 opt-in differences from the
      oracle." Is this exclusion mechanism precisely
      enough specified? If the oracle has implicit
      knowledge of what SPEC-010 changes = MINOR.

### Category E3: AC-23 test accessor

E3.1  AC-23 says "package-internal test accessor (e.g.
      unexported `runtimeTransitionCount() -> int` in
      the binary's `ModelRuntime` package reachable
      from `_test.swift` files within the same module)."
      Is this idiom standard for Swift package
      organization? If the existing ModelRuntime
      package structure makes this hard to add =
      MINOR.

### Category F3: AC count + editorial hygiene

F3.1  §5 footer says "Total: 26 ACs (20 from v0.2 + 5
      added in v0.3 per D.1 round-1 fix + 1 added in
      v0.4 per R2-B2.1 round-2 fix)." Walk every AC-x
      heading and count. If actual count ≠ 26 = MINOR.

F3.2  Stale "v0.2" / "v0.3" self-references: are any
      remaining? The v0.4 change log says they were
      updated. Verify.

F3.3  §10 OQs: v0.3 had OQs pointing to v0.3 release
      labels. v0.4 should point to v0.5. Verify.

### Category G3: Cross-spec citations (SPEC-010 just locked)

G3.1  R-3.1.2 step 2 cites SPEC-010 R-3.6.3 (binary-
      local pre-flight). Verify R-3.6.3 still exists
      in the just-locked SPEC-010 v1.5. If renumbered
      = MAJOR.

G3.2  R-3.1.2 step 2 also cites SPEC-010 R-3.1.7
      (case-fold). Verify R-3.1.7 still exists in
      SPEC-010 v1.5.

G3.3  Any other SPEC-010 R-x.y.z citations in v0.4?
      Walk and verify each.

### Category H3: Scope discipline

(Should be clean given v0.3 was clean here; just sanity
check.)

### Category I3: Anything else

I3.1  Documentation drift.

I3.2  Naming nits.

I3.3  Hidden surfaces v0.4 introduced.

I3.4  Decision-log entry note (not a finding).

## Output structure

APPEND to `/Users/augstar/macprovider-poc/specs/SPEC-011-audit.md`.
Start with:

```
---

## Round 3 — Codex GPT-5 — 2026-06-06

**Audited:** SPEC-011 v0.4 (specs/SPEC-011-operator-pushed-warm-swap.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 3 of N (normative)
**Date:** 2026-06-06
**Total findings:** [N CRITICAL / N MAJOR / N MINOR / N QUESTION]

### Round-3 executive summary — LOCK READINESS

[1-2 sentences with explicit verdict per J-2.]

### Round-2 fix verification (R2V)

[Table format.]
```

Then for each category R2V, A3-I3: section. For each
finding: severity, location, what/why/recommendation.

If a category has zero findings, write `(no findings)`.

## Out of scope

- d-inference inspection
- Rewriting the spec
- Implementing the spec
- Auditing SPEC-001, SPEC-002, SPEC-004, SPEC-008
- Auditing SPEC-010 (just locked v1.5)
- Re-litigating rounds 1-2 findings marked PASS

## Done criteria

- Round-3 section APPENDED to SPEC-011-audit.md (rounds
  1-2 intact)
- Every round-2 finding has PASS/PARTIAL/FAIL in R2V
- Every category R2V, A3-I3 has a section
- Executive summary states explicit lock-readiness verdict

=== END PROMPT ===
```

---

## Operator notes

- Expected wall-clock: 15-25 min.
- If LOCK-READY: SPEC-011 v0.4 locks (or v0.5 if narrow
  polish needed). Decision-log entry after lock.
- If new CRITICAL/MAJOR: v0.5 narrow fix + round 4.
  Trajectory has been converging strongly, so unlikely.
