# R2 fix prompt — SPEC-002 v1.3.5 Phase 2B (audit findings)

Operator-paste prompt for Codex GPT-5 to close 5 findings raised by
the mid-stream audit at
`.omc/artifacts/ask/codex-execute-the-mid-stream-audit-prompt-at-specs-audit-spec-002--2026-06-07T02-38-10-149Z.md`
on commits de41380 (Phase 2A) + 11bf449 (Phase 2B). Verdict was
FIX-THEN-PROCEED with 1 CRITICAL, 2 MAJOR, 2 MINOR.

This R2 lands inline on branch `fix/spec-002-v1-3-5-coordinator`
as a new commit on top of `11bf449`. No revert / amend — new commit,
new audit if needed.

Edit budget (same as 2B, no new files):
  phase4-coordinator/internal/ws/messages.go      (extend)
  phase4-coordinator/internal/ws/messages_test.go (extend)
  phase4-coordinator/internal/ws/auth_attempts.go (extend — comments only)
  phase4-coordinator/internal/ws/server.go        (extend)
  phase4-coordinator/internal/ws/server_test.go   (extend)

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~30-45 min.

Branch tip is `11bf449`. Codex MUST NOT create a new branch.

---

```
=== BEGIN PROMPT ===

You are landing 5 surgical fixes on branch `fix/spec-002-v1-3-5-coordinator`
in /Users/augstar/macprovider-poc/phase4-coordinator/ to close the
findings from the Phase 2A+2B mid-stream audit. The branch tip is
commit 11bf449. The findings + binding spec citations are below;
fix each one and add tests where indicated.

The full audit artifact is at
.omc/artifacts/ask/codex-execute-the-mid-stream-audit-prompt-at-specs-audit-spec-002--2026-06-07T02-38-10-149Z.md
— read it before editing.

You will edit ONLY these files:

  phase4-coordinator/internal/ws/messages.go
  phase4-coordinator/internal/ws/messages_test.go
  phase4-coordinator/internal/ws/auth_attempts.go
  phase4-coordinator/internal/ws/server.go
  phase4-coordinator/internal/ws/server_test.go

Verify with:

  git diff --name-only HEAD \
    | grep -vE '^phase4-coordinator/internal/ws/(messages|messages_test|auth_attempts|server|server_test)\.go$' \
    | wc -l

Output MUST be `0`.

## Fix 1 — [code:1.1] CRITICAL: surface SPEC-010 validation reason on the wire

**Finding:** `parseAuthInitial` returns the LOCKED AC-K.15 / AC-17 /
AC-22 / AC-23 substrings in `badField` (e.g.,
`"supported_models entry exceeds 256 bytes"`). But the protocol
handler at `phase4-coordinator/internal/ws/server.go:325-331`
drops `badField` and closes with the generic substring
`"unrecognized auth message"`. The locked oracles never reach the
wire — violating AC-K.15 (the test oracle grep would fail against
real WS traffic, even though parser unit tests pass).

**Spec citation:** SPEC-002 v1.3.5 §11 AC-K.15: "Each ordered
validation failure MUST surface the corresponding locked SPEC-010
reason-text substring on first-failure". SPEC-010 v1.5 R-3.1.9 +
AC-17 / AC-22 / AC-23.

**Fix:** In `handleV2Conn` at server.go:323, when initial-stage
parse fails AND `badField` starts with the prefix `"supported_models"`
(meaning it's a SPEC-010 validation failure, not an envelope failure
or a wrong-stage failure), emit `auth_response` with
`error.code = "bad_request"` and `error.message = badField`
BEFORE the WS close, and close with `badField` as the close reason
(NOT the generic `"unrecognized auth message"`). For non-SPEC-010
parse failures (envelope-level, wrong stage, missing tier2, etc.),
preserve the existing CloseUnrecognizedAuthMessage path.

Concrete shape — replace the block at server.go:322-331 with:

    initial, initialPresence, badField, err := ParseAuthRequest(payload)
    if err != nil || initial.Stage != "initial" {
        if badField == "" {
            badField = "stage"
        }
        // SPEC-002 v1.3.5 §11 AC-K.15 / SPEC-010 v1.5 R-3.1.9 — when
        // initial-stage parse fails on a SPEC-010 catalog validation
        // rule, surface the LOCKED reason substring on the wire so
        // the AC-K.15 grep-based test oracle holds. Envelope-level
        // and stage-mismatch failures keep the existing generic
        // rejection.
        if isSpec010CatalogBadField(badField) {
            s.sendAuthRejection(conn, "bad_request", badField)
            s.close(conn, CloseInvalidHello, badField)
            return "", ""
        }
        s.close(conn, CloseUnrecognizedAuthMessage, "unrecognized auth message")
        return "", ""
    }

Add the helper to `auth_attempts.go`:

    // isSpec010CatalogBadField reports whether a parser-level badField
    // string identifies a SPEC-010 v1.5 R-3.1.9 catalog validation
    // failure (length / array / duplicate / containment / empty), per
    // SPEC-002 v1.3.5 AC-K.15. These badField values are LOCKED test
    // oracles that MUST reach the wire verbatim.
    func isSpec010CatalogBadField(badField string) bool {
        return strings.HasPrefix(badField, "supported_models")
    }

Add the existing `strings` import (already imported in the file).

**Tests** (add to `server_test.go`, end-to-end via WS):

  TestProviderAuthV2InitialOverlongEntryRejectedWithLockedSubstring
    — send an initial frame with a 257-byte supported_models entry,
      assert `auth_response.error.code == "bad_request"` AND
      `error.message` CONTAINS `"supported_models entry exceeds 256
      bytes"` AND the WS close frame reason CONTAINS the same
      substring AND close code == CloseInvalidHello (4001).

  TestProviderAuthV2InitialOverlongCatalogRejectedWithLockedSubstring
    — 65 entries, expect `"supported_models exceeds 64 entries"` end
      to end.

  TestProviderAuthV2InitialDuplicateCatalogRejectedWithLockedSubstring
    — `["Model-A", "MODEL-A"]`, expect
      `"supported_models contains duplicate entries"` end to end.

  TestProviderAuthV2InitialMissingModelIDRejectedOnTheWire
    — `model_id: "X"`, `supported_models: ["Y"]`, expect close reason
      AND auth_response message contain `"supported_models missing
      model_id"`.

Use the existing `validAuthInitial` helper + `wsutil.WriteClientText`
+ `readAuthResponse` pattern from the existing 2B tests as the
template.

## Fix 2 — [code:1.2] MAJOR: reject empty `supported_models: []` distinctly

**Finding:** When `supported_models` is present as `[]`, the parser
skips per-entry / length / duplicate checks and fails at containment
with `"supported_models missing model_id"` (messages.go:431). SPEC-010
R-3.1.1 / R-3.1.9 require the array-length step to reject empty with
its own substring `"supported_models cannot be empty"`.

**Spec citation:** SPEC-010 v1.5 R-3.1.1 (array MUST be non-empty if
present) and R-3.1.9 (validation-order rule).

**Fix:** In `parseAuthInitial` at messages.go ~408 — AFTER the
JSON-unmarshal step for supported_models (which already runs first
per R-3.1.9 JSON-type-check) and BEFORE the per-entry byte-length
loop — insert:

    if presence.SupportedModels && len(req.SupportedModels) == 0 {
        return AuthRequest{}, presence, "supported_models cannot be empty", fieldError{Field: "supported_models cannot be empty"}
    }

The check sits inside the `if presence.SupportedModels { ... }`
block so absent-field semantics are unchanged.

**Tests** (add to messages_test.go AND server_test.go):

  TestParseAuthInitialRejectsEmptyCatalog
    — `supported_models: []`, assert badField EQUALS the LOCKED
      substring `"supported_models cannot be empty"`.

  TestProviderAuthV2InitialEmptyCatalogRejectedOnTheWire
    — end-to-end WS test mirroring Fix 1's pattern, asserts the
      substring reaches both auth_response message and close reason.

## Fix 3 — [code:1.3] MAJOR: kill the data race in the test helper

**Finding:** `authAttemptCount` in server_test.go uses reflection to
read `authAttempts.entries.Len()` directly, bypassing the mutex.
`go test -race` reports a confirmed data race against
`authAttemptStore.release()`. Production is fine; helper is broken.

**Spec citation:** N/A (test-only finding) — but `go test -race`
clean is a non-negotiable Go correctness invariant.

**Fix:** Add a thin test-only accessor on `Server`:

    // AuthAttemptCount returns the number of in-flight auth-attempt
    // retention entries. Test-only — production code MUST NOT
    // condition behavior on this value (the retention bound is the
    // operational gate per SPEC-002 v1.3.5 R-7.9.6 / AC-K.16).
    func (s *Server) AuthAttemptCount() int {
        return s.authAttempts.count()
    }

Place it next to `WithAuthAttemptRetentionBound` in server.go (around
line 98-102) — co-locating the test-facing knobs.

Update `authAttemptCount(t, server)` in server_test.go to call
`server.AuthAttemptCount()` directly. Delete the reflection-based
helper. All existing tests that call `authAttemptCount` continue to
work — only the implementation changes.

Verify with `go test -race -count=1 ./internal/ws/...` — MUST pass
clean.

## Fix 4 — [arch:1.1] MINOR: comment the explicit early release

**Finding:** server.go:498 explicitly releases retention before
`registerProviderSession`, while the auth-handler-scoped defer at
server.go:397 also releases on return. Future maintainers may see
the double-release as redundant and delete the explicit call,
reintroducing the WS-session-lifetime retention leak.

**Fix:** Add a short comment above server.go:498:

    // SPEC-002 v1.3.5 §7.9 — explicit early release so the
    // retention entry does not persist for the WS-session lifetime
    // (handleV2Conn does not return until readProviderLoop exits,
    // which for a healthy provider is hours or days). The auth-
    // handler-scoped defer at the top of this function remains as
    // the safety net for terminal failure paths between initial
    // parse and proof acceptance. Double-release is a harmless
    // no-op delete.

## Fix 5 — [arch:1.2] MINOR: doc the retention-bound Option

**Finding:** `WithAuthAttemptRetentionBound` is exported without
test-only / production-risk documentation. A production caller could
lower the bound and reject legitimate auth attempts.

**Fix:** Replace the existing declaration at server.go:98-102 with:

    // WithAuthAttemptRetentionBound overrides the default 1024-bound
    // on the SPEC-002 v1.3.5 §7.9 auth-attempt retention store.
    // INTENDED USE: tests that exercise the AC-K.16 retention-bound
    // rejection path with a smaller bound (commonly 1). Production
    // deployments SHOULD NOT lower the bound below 1024 (per
    // SPEC-002 v1.3.5 R-7.9.6 recommended value); lower values
    // will reject legitimate auth attempts under normal traffic.
    func WithAuthAttemptRetentionBound(maxBound int) Option {
        return func(s *Server) {
            s.authAttempts = newAuthAttemptStore(maxBound)
        }
    }

## Done criteria

1. `go build ./...` exits 0.
2. `go vet ./...` exits 0 with no output.
3. `gofmt -l ./internal/ws/` produces empty output.
4. `go test -race -count=1 ./internal/ws/...` exits 0 (no data races,
   no test failures) — this is the new bar; previously the suite was
   only validated without -race.
5. `go test -count=1 ./internal/pool/...` passes (Phase 2A regression
   check).
6. All 4 new WS-level tests for Fix 1 + the 2 tests for Fix 2 pass.
7. `git diff --name-only HEAD` lists exactly the 5 files in the edit
   budget.

## Out of scope (do NOT do in this R2)

- Editing the BUILD prompts, the audit prompt, or the handoff doc.
- Adding the empty-array rejection to `parseAuthProof` (proof stage
  does not re-validate — only cross-stage-compares per R-7.8.7).
- Touching Phase 2A surfaces (provider.go, provider_test.go) beyond
  Phase 2A's existing read-only test invocations.
- Refactoring the retention store API surface (count/release/lookup
  stay unexported on the store; the new accessor lives on Server).
- Touching the legacy `hello` path.
- Changing close codes or close-code registry constants.

## Self-check before reporting done

Run, in order, from /Users/augstar/macprovider-poc/phase4-coordinator,
and paste each output back:

    go build ./...
    go vet ./...
    gofmt -l ./internal/ws/
    go test -count=1 ./internal/pool/...
    go test -race -count=1 ./internal/ws/...
    go test -count=1 -v -run 'TestProviderAuthV2Initial(Overlong|Duplicate|MissingModelID|EmptyCatalog)' ./internal/ws/... | tail -40
    cd /Users/augstar/macprovider-poc
    git diff --name-only HEAD
    git diff specs/ beta/ phase3-binary/ phase5-gateway/ phase4-coordinator/internal/pool/

The last `git diff` MUST produce empty output (no edits outside the
five-file budget). If any earlier command fails, do NOT report done.

=== END PROMPT ===
```

---

## Operator notes (out-of-band)

- This R2 closes the audit findings as a single atomic commit on the
  branch. Methodology mirrors PR #5's 1A R2 prompt: one R2 prompt per
  audit cycle, dispatch, re-audit only if subsequent findings emerge.
- The CRITICAL is operator-trust-impacting but not exploitable — a
  malicious provider currently gets a useless rejection reason
  instead of the locked one. Fixing it is required for AC-K.15
  compliance, not for security per se.
- The MAJOR test-helper race ([code:1.3]) is interesting because it
  proves the established methodology (Claude inline audit + Codex
  external audit) is doing real work — Claude missed the
  reflection-based race, Codex caught it. That's the methodology
  earning its keep.
- After R2 lands and `go test -race` is green, branch is cleared to
  proceed to Phase 2C (ApplyHeartbeat REPLACEMENT — the riskiest
  phase). If R2 introduces any new finding, re-dispatch the audit
  prompt at `specs/AUDIT_SPEC_002_v1_3_5_IMPL_PHASES_2A_2B_PROMPT.md`
  before 2C begins.

🤖 Generated with [Claude Code](https://claude.com/claude-code) (Opus
4.7) for the SPEC-002 v1.3.5 Phase 2 implementation.
