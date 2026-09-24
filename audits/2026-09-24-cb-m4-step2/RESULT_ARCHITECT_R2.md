codex
Architecture audit complete for `f9a71a3b..ff49716e`.

No CRITICAL, HIGH, or MEDIUM findings.

Verified:

- Default-off behavior and serial/materialize fallback remain gated in `Config.swift` and `ModelRuntime.swift:3938-3975`.
- Cached-turn admission requires the flag, usable retained handoff, exact hybrid checkpoint, and revision-bound `cached_turns_accepted` grant (`ModelRuntime.swift:3994-4045`).
- Checkpoint layout is validated before recurrent installation (`PagedKVRuntimeBridge.swift:454-469, 661-708`).
- Retained sequence trimming updates bridge metadata before reattach, preserving SPEC-039 FR-PKV10 semantics.
- SPEC-038 v0.2.9, SPEC-039 v0.1.6, SPEC-024 0.2.6, CONFORMANCE, and the enable-gate runbook consistently keep packaged AC-26 receipt/settlement proof as a prerequisite for live enablement.
- Existing targeted suites passed:
  - Conversation cache: 34 passed, 1 skipped
  - Scheduler: 90 passed, 4 skipped
  - Config/gating: 104 passed, 1 skipped
  - Mixed-cache/layout: 5 passed, 4 skipped
- Full Swift suite had one unrelated flaky coordinator keepalive failure; the existing test passed when rerun alone.

The live-provider enablement gate remains correctly closed until packaged AC-26 proof is available.

VERDICT: PASS
