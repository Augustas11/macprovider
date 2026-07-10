# ISS-185 R1 — code-lane audit prompt

Audit target: the diff on branch `fix/iss-185-cold-start-404-to-503`
(opening as PR shortly) against `origin/main`. The change implements
SPEC-002 § 7.2's cold-start 404 vs 503 distinction by adding a
pool-lifetime model-id accumulator (`Registry.seenModelsLifetime`)
that survives provider disconnect, distinct from the per-provider
attribution map (`seenModelsByProvider`) that the M2-5 / PERF-5 audit
correctly shrinks on disconnect.

## Scope of this lane

You are the **code lane**. Focus on:

- **Concurrency.** `Registry` is shared across handler goroutines.
  `seenModelsLifetime` is a plain map, guarded by `r.mu`. Are all
  read sites under `mu.RLock` / write sites under `mu.Lock`?
  Verify `recordSeenModelLocked` is only called with the write lock
  held (per its godoc), and `ModelKnown` reads under `mu.RLock`.
- **Cap behavior.** `maxSeenModelsLifetime = 4096` — silent-drop
  beyond cap. Is the drop documented? Is the cap exercised by a
  test? Is the cap reachable in legitimate use (probably not — most
  deployments serve 5-50 models — but worth confirming the units).
- **Symmetry between the two maps.** Both maps are written by
  `recordSeenModelLocked`. Is there any other code path that writes
  to ONE but not the other? Grep for direct map indexing.
- **ModelKnown semantics.** Per SPEC-002 § 7.2: "ever seen during
  coordinator lifetime". Does the new ModelKnown return true iff
  the lifetime accumulator OR a currently-connected provider has
  the model id? Edge: case-insensitive matching is preserved
  (existing `strings.EqualFold` behavior). Is it?
- **Test coverage.** New tests are
  `TestModelKnownPersistsInLifetimeAccumulator`,
  `TestSeenModelsLifetimeCap`, the rewritten
  `TestRegisterReplaceSessionClearsPerProviderAttribution`, and
  `TestChatCompletionsColdStartRaceReturnsNoProviderAvailable`. Are
  the assertions tight (status code + error code + body shape)? Is
  the existing `TestChatCompletionsSplitsUnknownModelAndUnavailableProvider`
  unaffected (it should still pass — the never-seen path is the
  unchanged 404 path).
- **Other call sites of ModelKnown.** Grep `phase4-coordinator/` for
  other ModelKnown callers. Any that would break under the new
  "ever seen" semantic vs the old "currently-known" semantic?

Out of scope for this lane (other lanes own):

- **Security lane:** DoS via model-id flooding, cap exhaustion.
- **Architect lane:** spec consistency vs SPEC-002 § 7.2, naming.

Do NOT duplicate their work.

## Files in the diff

```
phase4-coordinator/internal/pool/provider.go
phase4-coordinator/internal/pool/provider_test.go
phase4-coordinator/internal/buyer/server_test.go
```

Useful command:
```
git diff origin/main -- phase4-coordinator/
```

## Output format

For each finding:

- **Severity:** CRITICAL | MAJOR | MINOR | NOTE
- **File:line(s):** exact reference
- **Issue:** one-sentence problem statement
- **Evidence:** quote relevant code
- **Recommendation:** specific change

Severity definitions:

- **CRITICAL:** breaks the build/tests, exploitable, or
  load-bearing invariant violated. Must fix before this lands.
- **MAJOR:** correctness regression or test gap on the
  PR-introduced surface. Should fix before this lands.
- **MINOR:** hardening / clarity opportunity.
- **NOTE:** future-proofing observation.

End with:
```
Found: <N> CRITICAL, <N> MAJOR, <N> MINOR, <N> NOTE.
```

## Scope: PR-INTRODUCED findings only

Per the locked three-lane convergence convention: this audit gates
this PR on findings INTRODUCED by the diff against origin/main.
Pre-existing concerns visible to your audit but NOT modified by
this PR are out of scope for blocking convergence — they may be
worth filing as separate issues but they do NOT block PR landing.

Keep response under 800 words.
