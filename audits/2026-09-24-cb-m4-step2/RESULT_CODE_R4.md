codex
Audit result: no C/H/M findings.

- Reattach trims to `cachedPromptTokens` and sets `prefillCursor` to the same C (`ContinuousBatchScheduler.swift:2390-2408`); checkpoint chaining is covered by existing hybrid tests.
- Mamba restore validates exact layer coverage, slot count, rank, batch dimension, shape, and dtype before installation (`PagedKVRuntimeBridge.swift:454-470`, `661-708`).
- M4-added await points were swept: terminal retention/materialization, retained install, recurrent snapshot, and pre-admission discard all honor recorded cancellation.
- Retained ownership is released or discarded across misses, failures, cancellation, replay, and commit fencing (`ConversationCache.swift:384-491`).
- Flag-off remains the default serial/fenced path.
- Existing targeted tests: 265 executed, 25 skipped, 0 failures. Skips were due to unavailable MLX metallib; real tensor execution remains unverified. No malformed payloads were constructed.

VERDICT: PASS
