# R2 closure-verification audit — SPEC-002 v1.3.5 Phases 2A + 2B

Operator-paste prompt for Codex GPT-5 to perform a focused
**closure-verification** review of commit `83540b1` (the R2 fix
commit that landed on top of `11bf449`), confirming that each of the
5 findings from the R1 mid-stream audit at
`.omc/artifacts/ask/codex-execute-the-mid-stream-audit-prompt-at-specs-audit-spec-002--2026-06-07T02-38-10-149Z.md`
is actually closed AND that the R2 changes themselves did not
introduce new defects.

This is the SPEC-arc lock-confirmation pattern applied at the
implementation layer: after R1 surfaces findings and R2 lands fixes,
a second adversarial pass confirms the closures hold AND looks for
R2-introduced regressions. The pattern was empirically validated
during SPEC-010 v0.6 → v1.0 (round 2 caught a substring drift
introduced by polish; round 3 caught a line-wrap false positive).

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~15-25 min
(small surface; targeted verification rather than full review).
This is a **read-only** review — Codex MUST NOT modify any file.

---

```
=== BEGIN PROMPT ===

You are performing an R2 closure-verification audit on commit
83540b1 in /Users/augstar/macprovider-poc, branch
`fix/spec-002-v1-3-5-coordinator`. This commit applies 5 fixes
addressing the R1 audit findings on commits de41380 + 11bf449.

Your task has TWO halves:
  A. Verify each of the 5 R1 findings is genuinely closed by 83540b1.
  B. Sniff for new findings introduced by 83540b1 itself.

This is a **read-only review**. You MUST NOT edit any file.

## Context

Branch state:
- de41380 (2A): Provider data-model extension
- 11bf449 (2B): v2 auth_request SPEC-010 + retention lifecycle
- 83540b1 (R2): 5 audit-finding fixes — THIS is the commit under
  closure-verification

R1 audit verdict was FIX-THEN-PROCEED with 1 CRITICAL, 2 MAJOR,
2 MINOR. R2 claims to close all 5.

## Required reading (in this order)

1. The R1 audit artifact at
   `.omc/artifacts/ask/codex-execute-the-mid-stream-audit-prompt-at-specs-audit-spec-002--2026-06-07T02-38-10-149Z.md`
   — read the full Findings section.

2. The R2 fix prompt at
   `specs/BUILD_SPEC_002_v1_3_5_IMPL_PHASE_2B_R2_PROMPT.md`
   — read Fix 1 through Fix 5 specs.

3. The R2 commit via `git show 83540b1`. Read the full diff.

4. The locked spec sections cited in the R1 findings:
   - `specs/SPEC-002-coordinator.md` v1.3.5 §11 AC-K.15 +
     AC-K.16 + §7.9
   - `specs/SPEC-010-model-catalog.md` v1.5 R-3.1.1 + R-3.1.9 +
     AC-17 + AC-22 + AC-23

5. The current source after R2:
   - `phase4-coordinator/internal/ws/auth_attempts.go`
   - `phase4-coordinator/internal/ws/messages.go`
   - `phase4-coordinator/internal/ws/messages_test.go`
   - `phase4-coordinator/internal/ws/server.go`
   - `phase4-coordinator/internal/ws/server_test.go`

DO NOT inspect any file under `phase3-binary/.build/checkouts/`.

## Part A — R1 closure verification

For each R1 finding, produce a verdict from {CLOSED, NOT-CLOSED,
PARTIAL}. Cite the file:line that contains the fix and the test
name that proves the closure.

### A1 — [code:1.1] CRITICAL — surface AC-K.15 locked substrings on the wire

**R1 finding:** parseAuthInitial returns the LOCKED AC-17/22/23
substrings in badField, but handleV2Conn at server.go:325 dropped
them and closed with the generic "unrecognized auth message".

**R2 claimed fix:** Added `isSpec010CatalogBadField` gate; on
SPEC-010 validation failure, send `auth_response.error.code =
"bad_request"` with message=badField AND close with badField as
the reason.

**Verify:**
- Read server.go around the new dispatch block. The gate MUST run
  only when `badField` identifies a SPEC-010 catalog failure
  (prefix-match on `"supported_models"`); envelope-level failures
  MUST still take the existing CloseUnrecognizedAuthMessage path.
- For each of the 4 LOCKED substrings (256B / 64-entry / duplicate
  / mismatch) plus the empty-array substring added by Fix 2, find
  the end-to-end WS test that confirms BOTH the auth_response
  message AND the close reason contain the substring. The locked
  test oracles are:
    - `"supported_models entry exceeds 256 bytes"` (AC-17)
    - `"supported_models exceeds 64 entries"` (AC-22)
    - `"supported_models contains duplicate entries"` (AC-23)
    - `"supported_models cannot be empty"` (R-3.1.1)
    - `"supported_models missing model_id"` (R-3.6.3 / R-3.1.9)
  For each one, run `grep -n "<substring>" phase4-coordinator/`
  and confirm the substring appears BOTH in the parser fieldError
  (messages.go) AND in the end-to-end test assertion (server_test.go).
- Specifically check that the close code used for SPEC-010
  rejections is `CloseInvalidHello` (4001), not 4000.

### A2 — [code:1.2] MAJOR — distinct rejection for empty supported_models

**R1 finding:** Empty `supported_models: []` fell through to the
containment check with "missing model_id" instead of returning
"supported_models cannot be empty".

**R2 claimed fix:** Added empty-array check inside the present-
field block in parseAuthInitial, before the per-entry loop.

**Verify:**
- Read the parseAuthInitial diff. The empty check MUST be inside
  the `if presence.SupportedModels { ... }` block (absent-field
  semantics unchanged) AND MUST come before the per-entry byte-
  length loop (SPEC-010 R-3.1.9 ordering: JSON type → empty/length
  → per-entry → array length → duplicate → containment).
- Confirm there is a parser unit test
  `TestParseAuthInitialRejectsEmptyCatalog` AND an end-to-end test
  `TestProviderAuthV2InitialEmptyCatalogRejectedOnTheWire` (or
  equivalent).
- A subtle concern: per R-3.1.9 the strict ordering is "per-entry
  byte length → array length". The R2 placed empty-check BEFORE
  per-entry, which is correct because an empty array has nothing
  to per-entry-check. But verify the spec doesn't mandate per-entry
  before any other check.

### A3 — [code:1.3] MAJOR — kill data race in test helper

**R1 finding:** `authAttemptCount` used reflection to read the
store's `entries` map directly, bypassing the mutex.
`go test -race` reported confirmed data races.

**R2 claimed fix:** Added `Server.AuthAttemptCount()` accessor
that calls the mutex-protected `count()`. Helper now delegates.

**Verify:**
- Read server.go for the new accessor — confirm it does ONLY
  `return s.authAttempts.count()`, no other behavior.
- Read server_test.go for the updated helper — confirm it calls
  `server.AuthAttemptCount()` and the reflection code is gone.
- Run `go test -race -count=1 ./internal/ws/...` from
  /Users/augstar/macprovider-poc/phase4-coordinator and confirm
  exit code 0. (You may run go test under -race; you MUST NOT
  modify any file.)
- Confirm `reflect` is still legitimately imported in server_test.go
  by another test (it is, for `reflect.DeepEqual` on a slice — but
  if the only usage was the helper, it would now be a dead import).

### A4 — [arch:1.1] MINOR — comment the explicit early release

**R1 finding:** server.go ~498 explicitly releases retention
before registerProviderSession with no comment explaining why
the auth-handler-scoped defer at server.go ~397 is not enough.

**R2 claimed fix:** Added an 8-line comment block above the
explicit release explaining the WS-session-lifetime concern and
the defer's role as a safety net.

**Verify:**
- Read the comment block. It should mention: (a) handleV2Conn
  does not return until readProviderLoop exits; (b) without the
  explicit release the retention entry would persist for hours/days;
  (c) the defer remains as the failure-path safety net; (d) double-
  release is a harmless no-op.

### A5 — [arch:1.2] MINOR — doc WithAuthAttemptRetentionBound as test-only

**R1 finding:** Exported option without test-only / production-risk
documentation.

**R2 claimed fix:** Added documentation comment marking it as
test-intended-use with explicit production-risk warning.

**Verify:**
- Read the new comment block. It should: (a) name the INTENDED
  USE (tests exercising AC-K.16); (b) explicitly warn against
  production use below 1024; (c) cite R-7.9.6 for the recommended
  default.

## Part B — R2 regression sniff

Look for new defects introduced by 83540b1. Use the same code /
security / architecture lens as R1, but scoped narrowly to the
edits in this commit:

### B1 — Did `isSpec010CatalogBadField` introduce a false positive or false negative?

**Concern:** The gate is `strings.HasPrefix(badField, "supported_models")`.

- False positive: are there any non-SPEC-010 paths that produce
  a badField starting with `"supported_models"`? Grep
  `messages.go` for every `fieldError{Field: "..."}` and every
  `return AuthRequest{}, ..., "...", ...` literal.
- False negative: are there any SPEC-010 paths that produce a
  badField NOT starting with `"supported_models"`? Specifically:
  the `publishes_supported_models` field has its own validation
  errors (e.g., type error → badField = "publishes_supported_models").
  Is `publishes_supported_models` covered by the gate, and does it
  need to be?

### B2 — Cross-stage mismatch close code

R2 did NOT modify the existing cross-stage compare path at
server.go ~445. That path uses CloseInvalidHello for the mismatch
case. R2 added CloseInvalidHello for initial-stage validation.
Verify the consistency is intentional — both initial-stage and
cross-stage SPEC-010 failures now close with code 4001
("invalid_hello"), but for an SPEC-010 catalog failure the
operational meaning is "the catalog frame was malformed". Is
there an argument for a distinct close code? (Probably not, but
note any inconsistency.)

### B3 — sendAuthRejection ordering

R2's Fix 1 calls `s.sendAuthRejection(conn, "bad_request", badField)`
BEFORE `s.close(...)`. Verify this is the correct ordering — the
existing pattern at server.go ~399-401 (Tier-2 attestation
rejection) does the same. A reversed order (close-then-send)
would suppress the auth_response delivery.

### B4 — Test coverage gaps in the R2 new tests

The 6 new tests (5 end-to-end + 1 parser unit) are added to
existing test files. Verify:
- Each test name maps to a distinct LOCKED substring or behavior
  per A1/A2.
- Each test runs cleanly under `-race`.
- No test relies on time-based assertions that could flake.
- The test fixtures don't accidentally cross-pollute (e.g., a
  test that sets `cfg.Providers[0].EndpointURL = ""` then forgets
  to defer restore — Go subtests should be safe here because
  each test gets a fresh harness via `newProviderHarness`).

### B5 — Did the empty-array check break any prior assertion?

The new empty-array rejection runs BEFORE per-entry length. If a
prior test sent an empty array expecting a different error, it
would now fail. Run the full ws test suite and confirm zero
existing tests regressed. (You may run `go test -count=1
./internal/ws/...` — you MUST NOT modify any file.)

## Output format

```
# SPEC-002 v1.3.5 Phases 2A + 2B R2 closure-verification — Codex GPT-5

## Verdict

<one-line summary: CLOSED-CLEAN | CLOSED-WITH-MINOR-NOTES |
NOT-CLOSED | NEW-FINDINGS>

## R1 closures

| Finding | R1 severity | R2 verdict | Test/file proof |
|---|---|---|---|
| code:1.1 (AC-K.15 surfacing) | CRITICAL | CLOSED/NOT-CLOSED/PARTIAL | <test name + file:line> |
| code:1.2 (empty-array) | MAJOR | CLOSED/NOT-CLOSED/PARTIAL | <test name + file:line> |
| code:1.3 (-race helper) | MAJOR | CLOSED/NOT-CLOSED/PARTIAL | <`go test -race` result + file:line> |
| arch:1.1 (release comment) | MINOR | CLOSED/NOT-CLOSED/PARTIAL | <file:line> |
| arch:1.2 (Option doc) | MINOR | CLOSED/NOT-CLOSED/PARTIAL | <file:line> |

## New findings introduced by R2

(zero is the expected/desired result; report whatever you find)

[r2:N.M] [SEVERITY] <short title>
  File: <path>:<line>
  What: <description>
  Why: <impact>
  Fix: <remediation>

## AC traceability

(Re-confirm the AC-K rows from R1; update any that gained
additional coverage in R2.)

| AC | Where satisfied | Test name |
|---|---|---|
| AC-K.15 (validation order + locked substrings) | <file:line> | <tests> |
| (others as needed) | ... | ... |

## Build / vet / race / suite evidence

Paste outputs from:
  cd /Users/augstar/macprovider-poc/phase4-coordinator
  go build ./...
  go vet ./...
  gofmt -l ./internal/ws/
  go test -race -count=1 ./internal/ws/...
  go test -count=1 ./internal/pool/...

## Cross-cutting observations

<any patterns spanning multiple closures or new findings>
```

## Discipline

- Closure verdicts are CLOSED only when both the production fix
  AND a covering test exist. A fix without a test = PARTIAL.
- New-finding severity follows the same scale: CRITICAL if you
  can describe the concrete failure mode in one sentence.
- Do not invent new findings. Zero is a valid result.
- Cite file:line and test name for every closure verdict.
- You may run `go build / vet / test / -race`. You MUST NOT
  modify any file.

You may take up to 25 minutes wall-clock.

=== END PROMPT ===
```

---

## Operator notes (out-of-band)

- This is the closure-verification round modeled after SPEC-010
  v0.6→v1.0's lock-confirmation rounds and SPEC-002 v1.3.5's 4-round
  trajectory (the methodology lesson encoded in Entry 57: polish-
  introduced regressions get caught by the NEXT round).
- Expected outcome: CLOSED-CLEAN, zero new findings, branch cleared
  to Phase 2C.
- If CLOSED-WITH-MINOR-NOTES or new findings emerge, draft another
  R2-style fix prompt; otherwise proceed to Phase 2C.
- Result artifact lives under
  `.omc/artifacts/ask/codex-execute-the-r2-closure-verification-prompt-at-*`.

🤖 Generated with [Claude Code](https://claude.com/claude-code) (Opus
4.7).
