# SPEC-018 v0.2.4 IMPL - Architect r1 Audit

**Date:** 2026-06-28
**Reviewer:** codex architect
**Verdict:** FIX REQUIRED

## Tally: C/H/M/m/Q

0/3/1/0/1

## Findings

### CRITICAL findings

None.

### HIGH findings

#### HIGH-1 - Provider streaming is post-generation fragmenting, not token-incremental streaming

`SPEC-018` requires v0.2 streaming to default to token-incremental tool-call streaming for Cline-targeted models and says provider `function.arguments` fragments stream incrementally before final-close (`specs/SPEC-018-agentic-tool-calling.md:836`, `:842`, `:864`). The implementation does not have that architecture yet.

In the provider runtime, tool-enabled streaming still suppresses `onChunk` during generation:

- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:528` sets `bufferForToolParsing = Self.hasEnabledTools(...)`.
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:533` through `:545` decodes tokens only to check stop conditions and returns `.more`; it does not emit tool-call deltas.
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:568` through `:575` applies filters and parses tool calls only after `generate(...)` completes.
- `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:472` awaits `modelRuntime.stream(...)` to return, then `:485` through `:497` emits split `tool_calls` chunks from the finished `CompletionResult`.

So the wire shape is split into OpenAI-style fragments, but the architecture is still "generate full native output, parse, then replay fragments." That fails the release intent behind AC-44 large-write latency as well: the first tool-call argument delta cannot arrive while generation is still producing the large argument because the provider has not parsed any tool call until generation ends. This also makes the IMPL note at `specs/SPEC-018-v0_2-IMPL-NOTES.md:9` misleading: "token-incremental streaming" is not implemented, only post-hoc chunking is.

Fix direction: introduce a streaming tool-call parser in the provider generation loop that detects the family-native tool-call opening, emits the OpenAI opening delta before forwarding any argument bytes, emits additive argument fragments as tokens decode, and still accumulates the exact canonical final argument bytes for final-close/receipt parity. If that is intentionally out of scope, the implementation cannot claim deliverable #4 as complete.

#### HIGH-2 - Buffered kill-switch and per-buyer/provider downgrade modes are header-only

`SPEC-018` requires operator kill-switch and auto-downgrade to force future requests into buffered-to-end behavior (`specs/SPEC-018-agentic-tool-calling.md:836`) while exposing `X-MacProvider-Streaming-Mode` only as an observation header (`:838`). The coordinator implementation computes the mode but does not use it to alter forwarding behavior.

Evidence:

- `phase4-coordinator/internal/buyer/streaming_downgrade.go:89` through `:96` returns `buffered_kill_switch`, `buffered_provider_downgrade`, or `incremental`.
- In the WS path, the value is read at `phase4-coordinator/internal/buyer/server.go:2135` and only written to the response header at `:2149`.
- In the direct HTTP path, the value is read at `phase4-coordinator/internal/buyer/server.go:2365`, written to the response header at `:2418`, and passed to timing metrics at `:2515`.
- Repository search found no other use of `streamingMode`, `COORDINATOR_STREAMING_FORCE_BUFFERED`, `buffered_kill_switch`, or `buffered_provider_downgrade` in the coordinator.

The AC-45c-style test also only verifies header attribution: `phase4-coordinator/internal/buyer/streaming_test.go:35` through `:49` checks buyer A/B header values, and buyer B's body contains `tool_calls`; it never proves buyer A was actually buffered.

This is not just polish. Once HIGH-1 is fixed and the provider genuinely streams tool-call arguments during generation, these coordinator modes will still forward incremental bytes byte-identically. The operator cannot disable the behavior, and the tuple downgrade cannot protect a buyer/provider pair from repeated malformed incremental streams.

Fix direction: make `streamingMode != incremental` choose an explicit buffered path. For direct HTTP, that likely means read/validate the provider stream through final-close before writing buyer-visible tool-call bytes, then emit a buffered OpenAI-compatible stream/response. For WS, define the same final-close-before-forward contract or send a non-streaming request to the provider if that path is available and semantically equivalent. Add tests proving a downgraded or kill-switch request does not forward partial tool-call argument bytes before final-close success.

#### HIGH-3 - AC-25a harness validates a transcript it just fabricated

The BUILD continuation allowed a harness skeleton when full VS Code/Cline automation was impractical, but the skeleton still needed to be an executable contract for release-gate evidence: pinned fixture, transcript schema, and assertion code that can validate Cline session output (`specs/BUILD_SPEC_018_v0_2_IMPL_CONTINUATION_PROMPT.md:67` through `:84`). AC-25a itself requires a headless Cline fixture that runs through gateway -> coordinator -> provider and emits a machine-readable transcript (`specs/SPEC-018-agentic-tool-calling.md:589`).

The landed harness is an example generator, not a validator:

- `test/integration/cline_session/run_fixture.py:28` defines `make_transcript(...)`, which synthesizes turns, tool calls, timings, streaming mode, and AC-48b status.
- `test/integration/cline_session/run_fixture.py:135` validates the same in-memory object it just created.
- `test/integration/cline_session/run_fixture.py:154` through `:161` has no input transcript path; it always writes a new generated transcript and asserts its own constants.
- `test/integration/cline_session/README.md:3` through `:4` says it validates a deterministic Cline-shaped transcript without launching VS Code, but there is no replay/capture interface for a manual Cline run.

This means an AC-25a/AC-25b release-gate run could not use the harness to verify real Cline output without modifying the script. It can demonstrate the intended JSON shape, but it cannot catch missing request IDs, missing `model_hash_observed`, missing streaming-mode headers, real tool category drift, or Cline branching on known-vs-null model hashes.

Fix direction: split generation from validation. Keep a sample transcript fixture if useful, but add `run_fixture.py --transcript path/to/transcript.json` or equivalent that validates an externally captured Cline transcript against the schema/minimums. The run script can remain CI-friendly by validating a committed sample when no live artifact exists, but the release gate needs a path that consumes real captured evidence.

### MEDIUM findings

#### MEDIUM-1 - Implementation notes overstate the completed architecture

`specs/SPEC-018-v0_2-IMPL-NOTES.md:9` says deliverable #4 implements "token-incremental streaming" and tuple-scoped downgrade. Given HIGH-1 and HIGH-2, the notes hide the two most important limitations: provider-side tool-call chunks are emitted after generation completes, and coordinator downgrade/kill-switch modes are diagnostic headers rather than behavioral buffered modes.

Fix direction: after code fixes, update the notes to state exactly where incremental parsing, final-close accumulation, and buffered-mode branching live. If the current design remains, the notes should not claim deliverable #4 completion.

### Minor findings

None.

### Open questions

#### Q-1 - Is in-process downgrade state sufficient for production topology?

The tuple downgrade store is attached to `Server` and initialized in-process at `phase4-coordinator/internal/buyer/server.go:424`; the store itself is an in-memory map (`phase4-coordinator/internal/buyer/streaming_downgrade.go:19` through `:31`). This survives ordinary HTTP requests in one coordinator process, but not process restart or multi-process/multi-host coordinator deployments.

The spec text requires "future requests" from the same buyer/provider tuple to downgrade, but does not state whether restart/distributed persistence is required in v0.2. If production can run multiple coordinator processes for the same buyer traffic, this should be clarified or made durable/shared.

## Verdict justification

The Swift boundary separation is otherwise directionally sound: `ToolPromptRenderer` is isolated from `OutputCanonicalizer`, `OutputCanonicalizer.canonicalOutputObject` only emits `content`, `tool_calls`, and `finish_reason` (`phase3-binary/Sources/macprovider-cli/OutputCanonicalizer.swift:59` through `:71`), and the unsupported multi-turn model error is a real throw path with test coverage (`phase3-binary/Sources/macprovider-cli/ToolPromptRenderer.swift:14` through `:19`; `phase3-binary/Tests/macprovider-cliTests/MultiTurnTests.swift:31` through `:38`). The coordinator final-close validator is also separately identifiable and tested.

However, deliverable #4 is not structurally complete: the provider still buffers tool-call output until generation finishes, and the coordinator's buffered modes do not change behavior. The AC-25a harness also cannot validate real Cline evidence. These are release-gating architecture gaps, so this lane is **FIX REQUIRED**.
