# SPEC-017 v0.1.8 — Final whole-implementation CODE audit (adversarial)

You are the code lane on the final pre-merge adversarial audit
of the SPEC-017 v0.1.8 implementation. This is the LAST audit
pass before PR #173 ships. Your job is to REFUTE the "code is
correct and ready to ship" claim. Default to finding bugs.

## Scope

ALL of SPEC-017 v0.1.8 on branch `impl/spec-017-step-1` at HEAD
`9ef3d92`. 189 files changed, 30,456 insertions vs main.

Diff base: `git diff --name-only $(git merge-base HEAD main)..HEAD`.

## Controlling contracts

- `specs/SPEC-017-network-stats-api.md` (v0.1.8 LOCKED).
- `specs/BUILD_SPEC_017_IMPL_PROMPT.md`.
- `specs/SPEC-017-IMPL-STEP_4-convergence.md` (self-claim summary
  — verify, don't trust).

## Adversarial posture

You're looking for code that's WRONG, not code that's elegant.
A bug that ships > a stylistic critique. Probe:

A. **SQL injection / parameter mis-binding.** Every DB call:
   does it use `$1, $2, ...` parameter binding correctly, or
   does any `fmt.Sprintf` interpolate user-controlled / config-
   derived strings into a SQL string?

B. **Concurrent-write hazards.** Step 2's rollup runner spawns
   8 goroutines. Step 4.C's `requestObs` pointer lives in
   `r.Context()` and is written by the dispatcher AND read by
   the outer access-log middleware after `next.ServeHTTP`
   returns. Is this pattern actually data-race-free? Run
   `go test -race` mentally over a high-concurrency request
   path; can the writer + reader overlap?

C. **Context cancellation correctness.** Step 2's rollup uses
   `runOne(ctx, ...)`. Step 4.C's `observeRollupLag` ticker
   uses `ctx.Done()`. Are there code paths that hold
   `context.Background()` instead of the request context,
   leaving them un-cancellable on shutdown?

D. **Error-path label leaks.** Every `err.Error()` call: does
   the wrapped error potentially carry a DSN string, raw token
   bytes, or token_hash bytes that get persisted into a
   structured log or `stats_components_health.last_error_message`?
   `classifyPanic` redacts the type-only; does every error
   sink follow the same discipline?

E. **Off-by-one / boundary bugs.** Step 4.B's `burst=59` math:
   the commit message says 1 in-rate token + 59 burst = exactly
   60. Verify this against nginx semantics by reading the
   `limit_req` directive docs in your head, NOT by trusting the
   commit message. Is the actual limit 60 or 61?

F. **Money math.** Step 2's leaderboard rebuild
   (`rollup/rebuild.go`) handles big.Rat → float64 conversion
   for drift detection. Does the float conversion preserve
   monotonicity? Does the drift formula correctly handle
   zero / sub-unit / large-value edge cases? Look for
   sign-flip + divide-by-zero classes.

G. **Test claims vs test behavior.** Open every `TestACN_*`
   that the 22-AC sweep cites. Read what it actually asserts.
   Does the assertion actually prove the SPEC's AC text? A
   test that returns 200 doesn't prove "exact bucketed
   earnings" — only the body inspection does.

H. **The new test seam `Runner.RunTickOnceForTest`** —
   `internal/stats/rollup/runner.go`. It's marked
   `ForTest` and used in `step4c_integration_test.go`. Is it
   accidentally callable from production code via a forgotten
   import? Does it bypass any invariant the production tick
   loop enforces?

I. **`emitPartnerKeyEvent` `map[string]any`.** The function
   accepts a map and writes JSON to stderr. Could a caller
   pass a field whose value's JSON encoding would carry
   secret-shaped bytes? The current callers pass int + string
   only, but is there a static-analysis way to be sure?

J. **Gofmt / vet / lint clean.** Run gofmt, vet, golangci-lint
   on the locked branch. If anything is dirty, that's a CODE
   finding regardless of severity.

K. **Test compile coverage.** Run
   `go test -tags=integration -count=0` (compile only) across
   `internal/stats/...` and `cmd/coordinator/...`. Any
   reference to a removed type / renamed function is a CODE
   finding.

L. **Anything else.** Find your own attack surface.

## Verdict format

Write your output to
`specs/SPEC-017-FINAL-code-audit.md`. Required structure:

1. `## Verdict` — `REQUEST CHANGES` or `READY TO LOCK`.
2. `Blocking count: NC CRITICAL / NH HIGH / NM MEDIUM / NL LOW / N INFO`.
3. `## Validation evidence` — commands actually run with output
   summary.
4. `## Findings` — categorized; each with title, evidence
   (file:line + exact phrase), risk, fix direction.
5. `## Category sweep` — PASS / FAIL per category A–L.
6. `## Final recommendation` — one paragraph; if no blockers,
   name 3 specific bugs you tried to find that aren't there.

Severity bar same as ARCH prompt.

Lock requires 0 CRITICAL + 0 HIGH + 0 MEDIUM.
