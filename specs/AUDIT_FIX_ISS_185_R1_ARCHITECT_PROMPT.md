# ISS-185 R1 — architect-lane audit prompt

Audit target: the diff on branch `fix/iss-185-cold-start-404-to-503`
against `origin/main`. The change restores SPEC-002 § 7.2's
404-vs-503 distinction on cold-start races by adding a pool-lifetime
model-id accumulator separate from the per-provider attribution map.

## Background

SPEC-002 v1.4.1 § 7.2 (lines 2381-2389) says:

- 404 model_not_found ⇔ model_id NEVER advertised during this
  coordinator process lifetime.
- 503 no_provider_available ⇔ model_id is in pool-lifetime history
  but no eligible provider can take the request right now.

The M2-5 / PERF-5 audit (2026-06-10) flagged a memory-leak in the
pre-M2-5 registry-wide `seenModels` accumulator (no cleanup on
provider removal). M2-5 fixed the leak by keying the map per
provider and dropping the inner map on disconnect — but in doing
so it silently shrank `ModelKnown`'s answer to "currently-connected
only", introducing the SPEC § 7.2 violation that issue #185
documents.

This PR reconciles both: a bounded lifetime accumulator
(`seenModelsLifetime`, cap 4096) restores SPEC § 7.2 semantics
while preserving PERF-5's memory-bound invariant. The per-provider
attribution map keeps its M2-5 shrink-on-disconnect semantic but is
no longer the source of truth for `ModelKnown`.

## Scope of this lane

You are the **architect lane**. Focus on:

- **Spec consistency.** Does the new ModelKnown satisfy SPEC-002 §
  7.2's exact wording? Read the spec text and the new
  implementation side-by-side. Any edge cases where spec ≠ code?
- **Test contracts vs spec contracts.** The rewritten test
  `TestRegisterReplaceSessionClearsPerProviderAttribution`
  reinterprets the codex 2026-06-11 #47 finding — audit #47's
  concern moves from the ModelKnown surface to the per-provider
  attribution map. Is that reinterpretation legitimate, or does it
  drop a real invariant? Specifically: are there OTHER call sites
  besides ModelKnown that read `seenModelsByProvider` and would
  surface stale attribution if it shrinks on disconnect-but-not on
  replacement?
- **Naming.** `seenModelsLifetime` vs `seenModelsByProvider`. Are
  the names self-explaining? Should one or both be renamed for
  clarity? (Suggestion to reject: "modelHistory" — too vague.)
- **Cap value.** 4096 models per coordinator lifetime — defensible
  for mac-provider deployments where catalogs are 5-50 models?
  Should the cap be configurable, or is a hardcoded constant
  acceptable for now? Should the cap be tied to a SPEC-002 minor
  bump, or is it a purely operational dial?
- **Cap-reached behavior.** Silent-drop degrades cold-start races to
  legacy 404 for the dropped ids. Is "fail open to legacy buggy
  behavior" the right contract on cap exhaustion, or should it
  fail closed (e.g., reject the heartbeat with a hash mismatch
  reason)?
- **Cross-spec.** SPEC-005 / SPEC-006 / SPEC-011 do not reference
  the 404/503 split directly, but any test fixture or harness that
  relies on `ModelKnown` returning false post-disconnect would
  break. Are there any?
- **Phase-C harness alignment.** Issue #185 references the internal
  e2e harness scenario `06_cold_start_race.yaml`. Should the spec
  text or addendum mention how harnesses introspect the 4096-cap
  or the column-present/index-absent semantics introduced by #195
  (no, that's a different PR — call it out as a cross-reference
  only).
- **Versioning.** Does this need a SPEC-002 v1.4.3 minor bump, or
  is it strictly an implementation fix of v1.4.1 § 7.2 (no spec
  text change required)? Argue both sides.

## Files in the diff

```
phase4-coordinator/internal/pool/provider.go
phase4-coordinator/internal/pool/provider_test.go
phase4-coordinator/internal/buyer/server_test.go
```

Useful command:
```
git diff origin/main -- phase4-coordinator/
specs/SPEC-002-coordinator.md   # § 7.2
```

## Scope: PR-INTRODUCED findings only

Per the locked three-lane convergence convention: this audit gates
this PR on findings INTRODUCED by the diff against origin/main.
Pre-existing concerns visible to your audit but NOT modified by
this PR are out of scope for blocking convergence — they may be
worth filing as separate issues but they do NOT block PR landing.

## Output format

For each finding:

- **Severity:** CRITICAL | MAJOR | MINOR | NOTE
- **Aspect:** spec | naming | versioning | cross-service | contract
- **Issue:** one-sentence problem statement
- **Evidence:** quote relevant code / spec
- **Recommendation:** specific change

End with:
```
Found: <N> CRITICAL, <N> MAJOR, <N> MINOR, <N> NOTE.
```

Keep response under 800 words.
