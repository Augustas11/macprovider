# AUDIT_PROVIDER_IDLE_PREWARM_ARCHITECT — ARCHITECT lane

You are auditing the diff that implements the provider idle-prewarm
described in `specs/BUILD_PROVIDER_IDLE_PREWARM_IMPL_PROMPT.md`.

## Your lane: ARCHITECT

Focus on design-level concerns: placement, layering, consistency with
existing patterns, extensibility.

### Look for

1. **Actor topology placement**
   - `IdlePrewarmer` is a peer to `ThermalGate` / `ProviderStatus` /
     `ModelRuntime`, not a nested type inside one of them.
   - Prewarmer holds references (not ownership) of the other actors
     it queries.
   - No circular actor dependency (e.g. ModelRuntime holds
     IdlePrewarmer holds ModelRuntime).

2. **API additions on existing types**
   - `ModelRuntime.runInternalWarmup` placed near `complete()` /
     `.stream()` for review-locality.
   - `ProviderStatus.noteRealRequestStart` / `noteRealRequestEnd` /
     `secondsSinceLastRealActivity` / `noteInternalPrewarm` are
     grouped as a "activity tracking" region with a shared comment.
   - No new type parameters, no changed return types on existing
     public methods.

3. **Config placement**
   - Top-level `idle_prewarm:` yaml block matches existing yaml key
     naming (`snake_case`, existing style like `max_context_override`).
   - Consider whether nesting under a `runtime:` or `prewarm:`
     umbrella would age better as more prewarm-adjacent knobs land
     (e.g. B2 coord-side keepalive, if that ships later).
   - Defaults registered in the same place as other phase3-binary
     defaults (avoid drift where some knobs default in yaml unmarshal
     and others in a normaliser).

4. **CLI flag naming consistency**
   - `--idle-prewarm-tick-s` matches existing flag naming style
     (`--max-context`, `--max-batch`, dashes not underscores).
   - Long-form only (no short flags) matches existing style.
   - Consider whether a compound flag like
     `--idle-prewarm=off,tick=5,threshold=30` would be cleaner —
     probably NOT worth the divergence from existing per-knob flags.

5. **Wiring in `MacProviderCLI.swift`**
   - Instantiation ordering per R5 is respected.
   - `IdlePrewarmer.start()` and `.stop()` are called from the
     matching lifecycle handlers (serve start / SIGINT drain).
   - No leaked task / dispatch queue that outlives the serve command.

6. **Test-file naming**
   - `IdlePrewarmerTests.swift` matches existing test-file naming
     pattern in `phase3-binary/Tests/macprovider-cliTests/`.

7. **Protocol injection surfaces**
   - `PowerSourceReporting` protocol is defined next to its concrete
     `SystemPowerSource` (or equivalent) implementation, mirroring
     the `ThermalStateProviding` / `SystemThermalStateProvider`
     pattern in `ThermalGate.swift`.
   - Injection points on `IdlePrewarmer.init` mirror the parameter
     shape of `ThermalGate.init` (`stateProvider: X = Y()`).

8. **Interaction with SPEC-023 autotune**
   - Prewarm results MUST NOT populate `AutotuneDB.swift` (this is a
     CODE-lane check but also an architectural boundary — the
     autotune loop measures buyer-facing throughput; prewarm noise
     would bias its recommendations).
   - Verify by inspection that `runInternalWarmup` does not touch
     `Stage1Iterator` / `Stage2HillClimb` / `AutotuneRecommend`.

9. **Interaction with ThermalGate.setTransitionLogger**
   - The prewarmer polls `thermalGate.currentThermalState()` at
     tick time. Does the current ThermalGate API expose a
     `currentThermalState()` accessor? If not, add one (do NOT
     invert the pattern by using the setTransitionLogger callback as
     a state-cache for the prewarmer — that's stale-read-prone).

10. **Extensibility signals**
    - A future "prewarm with a real cached prompt from KV cache" or
      "prewarm interval scales with observed traffic pattern" would
      fit naturally in this shape without a redesign.
    - A future coord-side keepalive (B2 alternative) can reuse
      `PowerSourceReporting` and the event-name conventions.
    - The `runInternalWarmup` entry point is generic enough that
      other components (e.g. a health-check probe) could reuse it
      without duplicating the "bypass metrics + receipts" plumbing.

11. **Scope discipline**
    - No changes outside the "MUST change" file list in the BUILD
      prompt § "Scope of change" — unless the change is justified
      and small (comment-level).
    - No new SwiftPM dependencies added to `Package.swift`.
    - No changes to coord / gateway code.

### Do NOT flag

- Code correctness bugs (CODE lane).
- Security concerns (SECURITY lane).
- Pure aesthetic preferences without operational consequence.
- Findings that would require SPEC-level changes (defer to a separate
  design PR).

### Output format

Report findings ranked C / H / M / L / I. Each finding lists:
file:line, design concern, future scenario where it bites, proposed
change.

```
STATUS: ARCHITECT lane — CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n> INFO=<n>
```

## Diff to audit

`git diff` in the worktree.
