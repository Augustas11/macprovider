# DESIGN_SPEC_018_v0_2 — Deliverable #4: Token-incremental streaming promotion

## Context

You are designing **SPEC-018 v0.2**, building on locked **SPEC-018 v0.1.5** (`specs/SPEC-018-agentic-tool-calling.md`). v0.2 anchor framework = **Cline**.

**v0.1.5 baseline:**
- Current streaming behavior: tool-call output is **buffered to end** before emitting. Streaming clients receive content tokens but tool-call args arrive as one chunk at the end.
- §10c forward-compat invariant: streaming MAY add deltas in v0.2+ but MUST preserve OpenAI concatenation semantics so a buyer accumulating chunks gets byte-identical result to non-streaming.
- §8.4 commit-worthy validator applies pre-commit; for streaming this means commit decision happens at the moment the validator can determine whether a tool call is well-formed.
- Money-path: §8.4 + `FaultBreakerQualifying` guard zero-credit settlement on malformed pre-commit deltas.

## This deliverable: §10a #4 — token-incremental streaming promotion

**Why it matters for Cline UX:** Cline writes long files via `write_to_file` tool. The arguments to that tool can be 50–500KB (the full file contents). With v0.1 buffered streaming, the user sees nothing for many seconds while the model writes, then a single chunk drops the whole tool call. Incremental streaming means Cline can render "writing file..." progress and (in theory) start showing partial file contents in a diff view.

**Required v0.2 state:** Provider streams `function.arguments` incrementally per OpenAI's wire format (`tool_calls[0].function.arguments` arrives as a stream of partial JSON strings that the buyer concatenates).

## Design questions to answer

### 1. OpenAI wire format for incremental tool-call streaming

OpenAI's spec: each SSE chunk's `choices[0].delta.tool_calls[]` carries a partial update. The buyer maintains an accumulator indexed by `tool_calls[].index`. Fields:
- `index`: which call in the array.
- `id`: appears once (in the first chunk for that index).
- `type`: appears once.
- `function.name`: appears once (in the first chunk for that index).
- `function.arguments`: arrives as a stream of string fragments; buyer concatenates.

Confirm this matches OpenAI's actual current spec by referencing the openai-python SDK behavior (v2.44.0 baseline pinned in v0.1.5 §10c).

What does a complete stream look like? Sketch the chunk-by-chunk SSE wire bytes for a `write_to_file` call with 10KB of args.

### 2. Byte-equivalence with non-streaming

§10c demands: streaming concatenation MUST equal non-streaming response byte-for-byte (in the canonicalized output sense — §2.3 sorted keys recursive). How does the provider guarantee this?
- Generate full output internally, then chunk on the way out (simplest, defeats streaming's latency benefit but trivially correct).
- Generate streaming-native, but pin canonicalization order (compute final canonicalized form, derive deterministic chunk boundaries from it).
- Generate streaming-native, and re-canonicalize at end if anything changed (worst — non-deterministic mid-stream).

Pick one. Identify the perf/UX tradeoff.

### 3. Parse-failure fallback mid-stream

What happens if the model emits tool-call markup that becomes malformed only partway through? Example: model starts emitting `<tool_call>{"name":"x","arguments":{"a":1` and then drifts into garbage.
- Already-streamed chunks claimed `tool_calls[]` are happening. Buyer's accumulator has partial args.
- Provider must signal "cancel that, treat as content".

OpenAI doesn't natively support "withdraw the tool call I was streaming." Options:
- (a) Provider buffers until tool call is well-formed before emitting any tool-call chunks (defeats latency benefit on the actual long-output case).
- (b) Provider streams optimistically; on parse failure, terminates stream with explicit error (Cline must handle).
- (c) Provider commits a tool-call chunk only when validator gives green light; if green-lit then parse later fails, that's a money-path bug — must hard-fail with `FaultBreakerQualifying`.

What's the v0.2 contract? How does this interact with §8.4 commit-worthy validator's "no commit until well-formed" guarantee?

### 4. Streaming + prompt-echo guard interaction (deliverable #3)

Prompt-echo detection requires comparing emitted markup against input prompt. In streaming, the comparison happens incrementally. Does the guard:
- Block at first emitted chunk that starts matching prompt content (early-fire, conservative)?
- Wait until N matched bytes before firing (gives benign-prefix tolerance)?
- Run only once at end-of-stream (defeats streaming, but matches non-streaming guard behavior)?

### 5. Coordinator pass-through

The coordinator currently has streaming relay logic (`phase4-coordinator/internal/buyer/server.go` streaming path). Does it need changes to handle the new chunked tool-call deltas? Identify the pass-through code path. Does §6 request-side pass-through (AC-24 v0.1.5) need a streaming-side analogue?

### 6. AC-23 forward-compat regression test extension

AC-23 (v0.1.4) captures vN.M responses and parses with v0.1.3-baseline parser (`openai==2.44.0`). The regression test currently uses non-streaming. v0.2 must extend to streaming: capture v0.2 streaming response, parse-and-accumulate with v0.1.3 baseline streaming reader, byte-equivalent to non-streaming accumulation. Define the test fixture.

### 7. Cline-specific evidence

What's the minimal Cline-observed UX improvement that constitutes "v0.2 streaming ready"?
- A `write_to_file` of N KB shows incremental progress in Cline's UI in real-time?
- Time-to-first-meaningful-output (TTFMO) under M ms for a streaming tool call?
- No regression on existing Cline non-streaming flows (which Cline can fall back to)?

### 8. Should v0.2 ship buffered or streaming as default?

If streaming is risky, v0.2 could ship with streaming behind a feature flag and buffered as default. v0.3 promotes to default after stable observation. Or v0.2 just ships streaming-default with a kill switch. What's the right release posture given Cline anchor?

## Output format

Produce a normative design recommendation covering all 8 questions. Sketch the streaming SSE wire bytes for a concrete example. Define commit semantics interaction with §8.4 explicitly. Specify the AC-23 streaming extension test fixture concretely. Pick a release posture.
