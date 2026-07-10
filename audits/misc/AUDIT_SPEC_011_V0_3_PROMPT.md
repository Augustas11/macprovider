# Audit prompt — SPEC-011 v0.3 normative (round 2)

Operator-paste prompt to audit SPEC-011 v0.3
(`specs/SPEC-011-operator-pushed-warm-swap.md`).

**Round 2 normative.** Round 1 (Codex GPT-5 on v0.2) found 2
CRITICAL / 5 MAJOR / 3 MINOR / 0 QUESTION at
`specs/SPEC-011-audit.md`. v0.3 is a code-grounded
contract-tightening pass that claims to close all 10:

- **A.1 CRITICAL fix** (L-1 lock violation): new
  `--enable-warm-swap` opt-in gate (R-3.1.0); L-1 rewritten
  to require operator opt-in; R-3.3.0 heartbeat field
  gating; AC-18 rewritten for byte-identical default
- **C.1 CRITICAL fix** ($XDG_RUNTIME_DIR doesn't exist on
  macOS): control socket → `$TMPDIR/macprovider-cli/ctl.sock`;
  cooldown state → `$HOME/Library/Application Support/`
- **B.1 fix** (control socket frame `type`): all examples
  include `type`; missing/unknown `type` rejection rule
- **B.2 fix** (503 envelopes incomplete): full SPEC-001
  OpenAI shape with `error.type`, `error.code`,
  `error.message`, `error.param`, `retry_after_seconds`
- **C.2 fix** (`hello.model_hash` cite wrong locked text):
  source-of-truth note cites current Go + Swift code +
  SPEC-008 §5.4 candidate; NOT locked SPEC-001 §6.5
- **C.3 fix** (model_hash format mismatch): raw 64-char
  lowercase hex everywhere (no `sha256:` prefix)
- **D.1 fix** (missing AC coverage): 5 new ACs (AC-21
  through AC-25)
- **D.2 fix** (AC-20 grep too permissive): positive
  allowlist + fixture-planted negative checks
- **E.1 fix** (§6.4 overstates request_log): clarified
- **E.2 fix** (§6.1 §6.6 collision): §6.7+ numbering

Round 2 has two jobs:
1. **R1V** — for each round-1 finding, cite v0.3
   location and mark PASS / PARTIAL / FAIL
2. **Audit v0.3-new surface** — R-3.1.0 opt-in gate (the
   load-bearing A.1 fix), macOS socket path realism, control
   socket frame examples completeness, 503 envelope
   precision, AC-18 real byte-identical assertion, 5 new
   ACs, AC-20 allowlist

Append to existing `specs/SPEC-011-audit.md` as a new
top-level section after round 1.

Paste everything between `=== BEGIN PROMPT ===` and
`=== END PROMPT ===` into a fresh Codex CLI session rooted at
`/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are auditing SPEC-011 v0.3 at /Users/augstar/macprovider-poc/
specs/SPEC-011-operator-pushed-warm-swap.md. This is round 2 of
the normative audit.

Round 1 produced /Users/augstar/macprovider-poc/specs/SPEC-011-
audit.md with 2 CRITICAL / 5 MAJOR / 3 MINOR / 0 QUESTION
findings on v0.2. v0.3 claims to close all 10. The two
CRITICALs were L-1 lock violation (A.1) and macOS platform
mismatch on $XDG_RUNTIME_DIR (C.1) — both load-bearing.

You are NOT here to validate, rewrite, or extend the spec.
Two explicit jobs:

  J-1. **R1V — Round-1 fix verification.** For each round-1
       finding v0.3 claims to fix, cite the v0.3
       section/rule/AC and mark PASS / PARTIAL / FAIL.
       Findings whose fix is incomplete OR introduces a new
       problem = file a new round-2 finding AND mark
       PARTIAL in R1V.

  J-2. **Audit v0.3-new normative surface.** Specifically:
       - R-3.1.0 opt-in gate (the A.1 fix mechanism)
       - L-1 rewording with opt-in framing
       - R-3.3.0 heartbeat field opt-in gating
       - R-3.1.5 macOS-native control socket path
         ($TMPDIR/...) — verify against actual macOS env
         conventions
       - R-3.1.5 control socket frame examples (every frame
         has `type`); reject rule for missing/unknown type
       - R-3.4.2 / R-3.4.4 503 envelope completeness
       - R-3.3.1 raw lowercase hex format (no sha256:
         prefix); cascading fixes in §3.6 audit payload
       - R-3.8.3 source-of-truth note for `hello.model_hash`
       - AC-18 byte-identical default assertion
       - AC-20 allowlist mechanism
       - AC-21 through AC-25 new coverage
       - §6.1 SPEC-001 v1.3 candidate numbering (§6.7+)
       - §6.4 SPEC-005 interaction wording

Output:
  /Users/augstar/macprovider-poc/specs/SPEC-011-audit.md

APPEND a new top-level section:
  `## Round 2 — Codex GPT-5 — 2026-06-06`
followed by category-organized findings. Do NOT touch the
round-1 section.

## Severity definitions

Unchanged from round 1.

## Critical constraints

**1. Locked decisions (§2 L-1..L-7) READ-ONLY.** v0.3
rewrote L-1 with opt-in framing — verify this is a sharper
statement of the original lock, NOT a relaxation.

**2. SPEC-001 v1.2.4, SPEC-002 v1.3.4 LOCKED.** v0.3 §6.1
candidate explicitly uses §6.7+ (avoiding §6.6 collision).
Verify §6.1 candidate descriptions don't slip into
prescriptive SPEC-001 commitments.

**3. v0.3's scope unchanged.** No SPEC-010 or SPEC-012
surface smuggled in.

**4. Code-grounding stays critical.** Round-1 found 2
CRITICALs from spec-not-matching-code. v0.3's macOS path
fix is the highest-risk new platform claim:
- Verify `$TMPDIR` is actually set on macOS (run `printenv
  TMPDIR` on the workspace)
- Verify Swift `FileManager.default.temporaryDirectory`
  returns a usable path on macOS
- Verify the cooldown state file path
  `$HOME/Library/Application Support/macprovider-cli/`
  matches macOS conventions

**5. R-3.1.0 opt-in gate is the load-bearing A.1 fix.**
Walk every §3.x rule for whether it correctly gates on
`--enable-warm-swap`. Specifically:
- §3.1 CLI subcommand (R-3.1.0 explicit)
- §3.2 state machine (gated implicitly via R-3.1.0 "MUST
  NOT host the §3.2 state machine")
- §3.3 heartbeat extension (R-3.3.0 explicit)
- §3.4 drain semantics (transitively gated — they only
  fire during state-machine transitions which require
  opt-in)
- §3.6 audit event (transitively gated — only emitted
  when coordinator observes loading window which requires
  opt-in)
- §3.7 concurrent switch (transitively gated via §3.1)
- §3.8 WS drop policy (transitively gated)
If any §3 normative behavior fires WITHOUT opt-in = MAJOR
(the L-1 fix isn't complete).

**6. Clean-room.** Do NOT inspect d-inference source.

## Required reading (in order)

1. `/Users/augstar/macprovider-poc/specs/SPEC-011-operator-pushed-warm-swap.md`
   v0.3 — the spec under audit. Read the v0.3 change log
   first. Then read §3.1 (rewritten with R-3.1.0 + macOS
   paths + full control socket frames), §3.3 (R-3.3.0
   gating + raw hex format), §3.4 (full 503 envelopes),
   §3.6 (audit payload with corrected hashes), §3.8.3
   (source-of-truth note), §5 ACs (18-25), §6.1 / §6.4
   carefully.

2. `/Users/augstar/macprovider-poc/specs/SPEC-011-audit.md` —
   round-1 findings. R1V target.

3. `/Users/augstar/macprovider-poc/CLAUDE.md` —
   conventions.

4. `/Users/augstar/macprovider-poc/specs/SPEC-010-model-catalog.md`
   v1.x — verify cited SPEC-010 rules (R-3.6.3, R-3.1.4)
   still exist.

5. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   v1.2.4 — verify §6.6 is still occupied by Inference
   message types (so §6.7+ is the correct candidate space).

6. `/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md`
   v1.3.4 — verify §3, §7.1, §11 unchanged from round-1.

7. `/Users/augstar/macprovider-poc/specs/SPEC-008-tier2.md`
   v0.3 — verify §5.3-5.6 raw hex format claim accurate.
   Also verify the §5.4 candidate annotation for
   `hello.model_hash` exists.

8. `/Users/augstar/macprovider-poc/specs/SPEC-005-billing.md`
   — verify v0.3 §6.4 reworded statement matches SPEC-005
   request_log + 503 semantics.

9. `/Users/augstar/macprovider-poc/specs/SPEC-006-buyer-api.md`
   §F-1.5 — for AC-20 allowlist redaction baseline.

10. Code spot-checks (HIGHEST PRIORITY for round 2):
    - **macOS env check**: `printenv TMPDIR` on the
      workspace. Expected: a path under `/var/folders/...`
      or similar.
    - `phase4-coordinator/internal/ws/messages.go` heartbeat
      struct (still lacks `model_hash` / `loading`?)
    - `phase4-coordinator/internal/ws/messages.go:8-15`
      Hello struct (still has `ModelHash`?)
    - `phase4-coordinator/internal/pool/provider.go:411-432`
      ApplyHeartbeat (still clears hash on model change?)
    - `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:294-325`
      hexString output (raw lowercase hex?)
    - `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:675-697`
      helloMessage (emits model_hash?)
    - `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:1-16`
      (no `models` subcommand conflict?)

11. `/Users/augstar/macprovider-poc/specs/SPEC-012-source.md` —
    sanity-check no scope creep.

## Audit categories — work through each

### Category R1V: Round-1 fix verification (HIGHEST PRIORITY)

Table format. Mark PASS / PARTIAL / FAIL with v0.3
location verified and 1-sentence evidence anchored to
spot-checked code where applicable.

- **R1V-A.1** L-1 violation via heartbeat fields → v0.3
  R-3.1.0 + L-1 rewording + R-3.3.0 + AC-18 byte-identical
- **R1V-B.1** Control socket frame `type` consistency → v0.3
  R-3.1.5 frame examples all have `type`
- **R1V-B.2** 503 envelopes not full SPEC-001 → v0.3
  R-3.4.2 / R-3.4.4 full envelopes
- **R1V-C.1** $XDG_RUNTIME_DIR on macOS → v0.3 R-3.1.5
  `$TMPDIR/...` + R-3.1.4
  `$HOME/Library/Application Support/...`
- **R1V-C.2** hello.model_hash citation drift → v0.3
  R-3.8.3 source-of-truth note
- **R1V-C.3** model_hash format mismatch → v0.3 R-3.3.1
  raw hex + §3.6 audit payload examples
- **R1V-D.1** missing AC coverage → v0.3 AC-21 through
  AC-25
- **R1V-D.2** AC-20 grep too permissive → v0.3 AC-20
  allowlist
- **R1V-E.1** §6.4 overstates request_log → v0.3 §6.4
  reworded
- **R1V-E.2** SPEC-001 §6.6 numbering collision → v0.3
  §6.1 uses §6.7+

### Category A2: Opt-in gate completeness (the A.1 fix)

A2.1  R-3.1.0 specifies the gate. Walk every §3.x rule for
      whether it correctly gates. For each rule that
      describes behavior that should NOT fire in disabled
      mode, verify the rule either:
      (a) explicitly says "only when --enable-warm-swap
          enabled," or
      (b) transitively depends on a §3 surface that is
          itself gated.
      If a §3 rule fires in disabled mode = MAJOR.

A2.2  R-3.1.0 fourth bullet says invocation of
      `macprovider-cli models <subcommand>` MUST exit
      code 4 with the specific stderr message. Is this
      mechanism feasible? The CLI doesn't know whether
      serve was started with `--enable-warm-swap`; it
      detects "control socket absence" instead. If a
      serve process was started in disabled mode AND a
      separate operator started it in enabled mode AND
      crashes leaving the socket present, the CLI would
      see the socket and try to use it. Edge case worth
      acknowledging. If undefined = MINOR.

A2.3  AC-18 asserts byte-identical heartbeat shape. Does
      the assertion mechanism cover EVERY observable: WS
      frames, log lines, /v1/status response, etc.? Or
      just heartbeat shape? If just heartbeat = MINOR
      (other observables silently change).

A2.4  L-1 rewording: is "byte-identical to pre-SPEC-011
      binary" actually testable when comparing a
      SPEC-011 binary running disabled vs an older
      binary that doesn't have the SPEC-011 code at all?
      Likely yes (heartbeat field shape) but verify the
      claim is bounded to observables.

### Category B2: macOS platform paths (the C.1 fix)

B2.1  Run `printenv TMPDIR` on the macOS workspace. Is it
      actually set? Expected yes; if no = CRITICAL (same
      class as round-1 C.1).

B2.2  R-3.1.5 says socket parent directory `0700` and
      socket `0600`. Verify the macOS `socket(2)` /
      `AF_UNIX` permissions model supports `0600` on the
      socket file. Standard, but worth a brief check.

B2.3  R-3.1.4 says cooldown state at
      `$HOME/Library/Application Support/macprovider-cli/last-switch.ts`.
      Is `$HOME` always set on macOS for the user the
      provider binary runs as? Yes for interactive use;
      potentially undefined for launchd-spawned processes
      depending on plist. If macprovider-cli serve is
      typically a launchd agent (per any current
      LaunchAgent plist in the repo), this assumption
      could break. Spot-check repo for any LaunchAgent
      plist. If launchd-spawned and $HOME undefined =
      MAJOR.

B2.4  `--switch-state-path` override exists; good. But the
      default path has a defense-in-depth dependency on
      `$HOME`. If launchd is the typical runtime, the spec
      should either acknowledge or pick a different default
      (e.g. `/usr/local/var/macprovider-cli/`).

### Category C2: Control socket frame correctness (B.1 fix re-verification)

C2.1  Walk every frame example in R-3.1.5 — verify each
      has `type`, plus all required fields per the
      Field reference. Are there frame types not in the
      examples but referenced in normative text? If yes
      = MINOR (missing example for normatively-listed
      type).

C2.2  R-3.1.5 says "Messages with missing or unknown
      `type` MUST be discarded by the receiver and the
      receiver MUST close the connection with an error
      log line." Symmetric on CLI and serve sides? Both
      sides could send invalid frames; verify the rule
      is symmetric.

C2.3  Frame field reference table: are required-when
      conditions consistent with the examples? Spot-check
      `current_target` "REQUIRED on switch_ack when
      reason: loading_in_progress" — the example shows
      this. Same for `seconds_remaining` "REQUIRED on
      switch_ack when reason: cooldown" — also shown.

### Category D2: 503 envelopes (B.2 fix re-verification)

D2.1  R-3.4.2 swap_drain_timeout envelope: includes
      `error.type`, `error.code`, `error.message`,
      `error.param: null`. Missing `retry_after_seconds`
      — is that intentional (drain timeout doesn't have
      a clear retry-after value) or an oversight?
      R-3.4.4 provider_loading envelope DOES have
      `retry_after_seconds`. Verify the asymmetry is
      intentional. If unclear = MINOR.

D2.2  Both envelopes use `error.type: "service_unavailable"`.
      Verify this matches SPEC-001 §6.0 / SPEC-010 v1.x
      §4.6.2 OpenAI shape EXACTLY. Specifically: is
      `error.type` always `"service_unavailable"` for
      503 responses in the established pattern, or do
      some 503s use `"server_error"` etc.? If shape
      diverges from established pattern = MAJOR.

D2.3  Both envelopes include `error.param: null`. Is
      `error.param` documented in SPEC-001 §6.0? Check
      one existing 503 envelope in SPEC-001 / SPEC-010
      v1.x to confirm `error.param` is correct shape.

### Category E2: model_hash format (C.3 fix re-verification)

E2.1  Walk every occurrence of `model_hash` in v0.3 —
      heartbeat field, audit event payload (`from_model_hash`,
      `to_model_hash`), examples in ACs. Each MUST use
      raw 64-char lowercase hex. If any occurrence
      retains `sha256:` prefix = MAJOR.

E2.2  R-3.3.1 cites Swift `hexString(SHA256.hash(data: data))`
      at ModelRuntime.swift:294-325. Spot-check the
      actual code: does it produce raw lowercase 64-char
      hex? If the code uses uppercase or a different
      length = MAJOR.

### Category F2: hello.model_hash source-of-truth note (C.2 fix re-verification)

F2.1  R-3.8.3 source-of-truth note cites:
      - Go `Hello` struct: messages.go:8-15
      - Swift `helloMessage`: CoordinatorClient.swift:675-697
      - SPEC-008 §5.4 candidate annotation
      Verify each citation is accurate. Spot-check Go
      struct + Swift code + SPEC-008 §5.4.

### Category G2: New ACs (D.1 fix re-verification)

G2.1  AC-21 `--force` flag scope: tests cooldown bypass +
      pre-flight validation NOT suppressed. Adequate?
      Yes.

G2.2  AC-22 control socket frame parsing: tests 3
      invalid frames + 1 valid. Adequate? Yes. Verify
      the invalid frames cover the cases R-3.1.5
      describes.

G2.3  AC-23 boot path stays non-loading: tests state
      machine transition count = 0 via debug hook.
      Same caveat as AC-18(d) — requires a debug hook
      that doesn't exist yet. If hook implementation
      isn't acknowledged elsewhere = MINOR.

G2.4  AC-24 runtime-vs-CLI cooldown: comprehensive
      coverage of the four combinations (CLI cooldown
      yes/no × runtime loading yes/no). Adequate.

G2.5  AC-25 swap_drain_timeout range validation: tests
      5 cases including lower/upper bounds. Adequate.

### Category H2: AC-20 allowlist (D.2 fix re-verification)

H2.1  AC-20 allowlist: top-level keys MUST be a subset
      of an enumerated set. Verify the enumerated set
      matches R-3.6.1 / R-3.6.2 exactly. If missing
      `event` or includes a key not in §3.6 schema =
      MINOR (drift).

H2.2  AC-20 fixture-planted negative checks: tests
      `conv:` substring, raw `account_id`, sticky
      header, prompt text. Comprehensive? SPEC-006
      §F-1.5 enumerates additional redaction targets;
      does AC-20 cover all of them, or just the most
      common? If incomplete coverage = MINOR.

### Category I2: §6.x companion annotations re-verification

I2.1  §6.1 SPEC-001 v1.3 candidate: now uses §6.7
      through §6.10. Verify SPEC-001 v1.2.4 §6.6 is
      still the highest current section (no SPEC-001
      v1.2.4 §6.7 already exists that would collide).

I2.2  §6.4 SPEC-005 interaction rework: now says SPEC-011
      "inherits existing request_log behavior for 503
      outcomes." Verify this matches SPEC-005's actual
      handling of provider-attempted-but-503 requests.
      Spot-check SPEC-005 §3 or X-2 request_log schema.

### Category J2: Scope discipline

J2.1  v0.3 added R-3.1.0 opt-in gate, macOS path defaults,
      503 envelope details, AC-21 through AC-25.
      Verify none of these add coordinator-side surface
      beyond what v0.2 had. SPEC-011 is operator-pushed;
      no coordinator config knobs (L-7).

### Category K2: Anything else

K2.1  Documentation drift.

K2.2  Naming nits.

K2.3  Hidden surfaces v0.3 exposes that round 1 didn't
      probe.

K2.4  Convergence assessment: v0.2 → v0.3 was 2 CRITICAL
      + 5 MAJOR → ? Does v0.3 land at 0 CRITICAL / 0-2
      MAJOR (lock condition) or further iteration needed?

## Output structure

APPEND to `/Users/augstar/macprovider-poc/specs/SPEC-011-audit.md`.
Start with:

```
---

## Round 2 — Codex GPT-5 — 2026-06-06

**Audited:** SPEC-011 v0.3 (specs/SPEC-011-operator-pushed-warm-swap.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 2 of N (normative)
**Date:** 2026-06-06
**Total findings:** [N CRITICAL / N MAJOR / N MINOR / N QUESTION]

### Round-2 executive summary

[2-3 paragraphs. State whether v0.3 is ready to LOCK
directly, ready after the round-2 findings are closed, or
needs another revision. Specifically address whether the
two round-1 CRITICALs are genuinely closed in substance.]

### Round-1 fix verification (R1V)

[Table format.]
```

Then for each category R1V, A2-K2 write a section. For each
finding: severity, location, what/why/recommendation.

If a category has zero findings, write `(no findings)`.

## Out of scope

- Inspecting d-inference source
- Rewriting the spec
- Implementing the spec
- Auditing SPEC-001, SPEC-002, SPEC-004, SPEC-008 themselves
- Auditing SPEC-010 (separate cycle)
- Re-litigating round-1 findings marked PASS

## Done criteria

You are done when:

- Round-2 section APPENDED to SPEC-011-audit.md (round 1
  intact)
- Every round-1 finding has PASS / PARTIAL / FAIL in R1V
- Every category R1V, A2-K2 has a section (even if "(no
  findings)")
- Every finding has severity, location, what/why/recommendation
- Round-2 executive summary states a clear verdict

=== END PROMPT ===
```

---

## Operator notes

- Expected wall-clock: 20-30 min.
- Convergence target: 0 CRITICAL / 0-1 MAJOR → lock SPEC-011
  v0.3 directly.
- If ≥1 CRITICAL or >1 MAJOR, draft v0.4, re-audit round 3.
