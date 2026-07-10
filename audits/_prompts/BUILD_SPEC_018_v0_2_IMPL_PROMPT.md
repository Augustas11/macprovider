# BUILD_SPEC_018_v0_2_IMPL_PROMPT — Apply SPEC-018 v0.2.4 IMPL diffs

## Your task

Implement the code changes required by SPEC-018 v0.2.4 (LOCKED, merged as PR #202). Apply edits to `phase3-binary/` (Swift) + `phase4-coordinator/` (Go) + `test/integration/` directly in this fresh worktree. Lock-bar: green test suites + Cline-amenable CI fixture (AC-25a) + AC-23s streaming forward-compat regression passes.

This is the IMPL companion PR to the v0.2.4 SPEC. Per [[feedback-bundle-spec-impl-one-pr]], v0.2 is scope expansion (not incremental), so SPEC + IMPL ship in separate PRs.

## Authoritative inputs

1. `specs/SPEC-018-agentic-tool-calling.md` v0.2.4 — the SPEC. Read §1.2, §3.8, §3.7, §8.4.1/2/3, §10c.1, §10d.0 through §10d.7, and AC-25 through AC-55.
2. `specs/SPEC-018-v0_2-design-synthesis.md` — design source.
3. `specs/SPEC-018-v0_2_4-DRAFT-NOTES.md` — latest absorption notes.
4. Live repo: `phase3-binary/Sources/macprovider-cli/`, `phase3-binary/Sources/MacProviderCore/`, `phase4-coordinator/internal/buyer/`, `phase4-coordinator/internal/billing/`, `phase5-gateway/`, `test/integration/`.

## Scope: 4 deliverables + 5 supporting work

### Deliverable #1 — Multi-turn provider acceptance (§10d.1)

**Goal**: phase3 provider accepts `role:"tool"` messages + assistant-history `tool_calls[]` and renders them into the model's native chat template. Stateless OpenAI-replay-compatible — buyer replays full `messages[]` each turn.

**Code edits required:**

1. **`phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift`** at line 175 — extend `ChatMessage` struct to preserve:
   - `toolCallID: String?` (request-side, from `role:"tool"` messages)
   - `toolCalls: [ToolCall]?` (request-side, from assistant-history messages)

   Decoder must populate these fields from JSON. Existing v0.1.5 validation at lines 194 + 202 stays; remove the unsupported_tool_messages rejection branch (becomes success path).

2. **`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`** at lines 353 + 403 (`acquireRequestHandle` + `completeWithServedSnapshot`) — remove the `validateToolCallingV1Scope` rejection calls. Either delete the function at line 909 or repurpose for v0.2 request-side validation.

3. **Add `phase3-binary/Sources/macprovider-cli/ToolPromptRenderer.swift`** — new file. Family-keyed multi-turn render. Modular per family:
   - Qwen3 family: render assistant tool_calls as `<tool_call>{...}</tool_call>` markup; render `role:"tool"` content as appropriate tool-response markup per Qwen3 chat template (cite: https://huggingface.co/Qwen/Qwen3-32B/blob/main/tokenizer_config.json).
   - Llama-3.3 family: render via `<|python_tag|>` + native tool-response markup per Llama-3.3 chat template (cite: https://huggingface.co/meta-llama/Llama-3.3-70B-Instruct/blob/main/tokenizer_config.json).
   - Family selection: modelID-match per §3.2 (same predicate as parser side).
   - If no family profile matches → HTTP 400 `unsupported_modelID_for_multi_turn`.

4. **`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`** at lines 374 + 428 + 513 — replace `request.messages.map { $0.mlxMessage }` with a call into `ToolPromptRenderer` that has access to full `ChatMessage` objects (including new `toolCallID` and `toolCalls` fields).

**Request-side validation (per §10d.1 failure table + §10d.6 cross-message consistency):**

5. **`phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift`** add validation for:
   - `role:"tool"` with `content: null` → HTTP 400 `invalid_request`, `param:"messages[i].content"`
   - `role:"tool"` missing `tool_call_id` → HTTP 400 `invalid_tool_call_id`
   - `tool_call_id` not matching `^call_[A-Za-z0-9]{16,64}$` → HTTP 400 `invalid_tool_call_id`
   - `tool_call_id` referencing no earlier assistant `tool_calls[].id` in same request → HTTP 400 `tool_call_id_not_found`
   - Duplicate tool result for same ID → HTTP 400 `duplicate_tool_call_id`
   - `role:"tool"` appearing before matching assistant tool call → HTTP 400 `tool_call_result_out_of_order`
   - Assistant-history `tool_calls[].function.arguments` > 1 MiB → HTTP 413 `tool_call_arguments_too_large`
   - `role:"tool"` content > 256 KiB → HTTP 413 `tool_result_too_large`
   - Provider-emitted IDs validate `^call_[a-f0-9]{32}$`; request-accepted IDs validate `^call_[A-Za-z0-9]{16,64}$`. Different regexes.

6. **Aggregate request caps** (§10d.1, AC-50 through AC-55):
   - Raw request body cap: 4 MiB → HTTP 413 `request_body_too_large`
   - Sum of `role:"tool".content` UTF-8 bytes ≤ 1 MiB → HTTP 413 `tool_results_aggregate_too_large`
   - Sum of assistant-history `tool_calls[].function.arguments` UTF-8 bytes ≤ 2 MiB → HTTP 413 `tool_call_arguments_aggregate_too_large`
   - `messages[]` length ≤ 256 → HTTP 400 `messages_too_long`
   - Sum of all assistant `tool_calls[]` entries ≤ 128 → HTTP 400 `too_many_tool_calls`
   - Validation MUST be O(messages[] + tool_calls[]) via maps/sets — not O(N²).

7. **`phase4-coordinator/internal/buyer/server.go`** at line 3089 — mirror the request-side validation early. Existing struct preservation at `:1241-1245` already handles `ToolCallID`/`ToolCalls`. Same error codes + HTTP statuses as provider-side.

**Tests required (Swift + Go):**

- `phase3-binary/Tests/macprovider-cliTests/MultiTurnTests.swift` — new file. Cover AC-26 (tool message accept + render), AC-27 (assistant-history echo accept + render), AC-28 (tool-result content > 256 KiB → 413), AC-29 (multi-turn prompt_hash regression — same as v0.1 prompt_hash plus tool_call_id + tool_calls binding via PromptCanonicalizer.swift:5/:31).
- `phase4-coordinator/internal/buyer/multi_turn_test.go` — new file. Cover request-side validation matrix (8 error cases + valid pass-through).

### Deliverable #4 — Token-incremental streaming (§10d.4)

**Goal**: provider streams `function.arguments` incrementally per OpenAI wire format. Default ON for Cline-compatible models with operator kill switch + per-(buyer, provider) auto-downgrade attribution.

**Code edits required:**

1. **`phase3-binary/Sources/macprovider-cli/`** — streaming output writer: replace buffered-to-end tool-call delta with token-incremental. Use single canonical output builder so streaming bytes equal non-streaming bytes exactly (byte-equivalence per §10d.4 + AC-41).

2. **`phase4-coordinator/internal/buyer/server.go`** at line 2674 (`isCommitWorthyToolCallDelta`) — replace with two validators per §8.4 split:
   - **Incremental-open validator** (§8.4.1) at `forwardWSStreaming` (line 2103) + `forwardStreaming` (line 2278) — accept any chunk that establishes a valid first delta (verified model family + `function.name` non-empty + stable `index` + minted `id` + `type:"function"`). Buyer-visible commit gates here.
   - **Final-close validator** (§8.4.2) at end-of-stream — verify: every opened `tool_calls[].index` has a terminal accumulated argument string + the stream emitted `finish_reason:"tool_calls"` + transport completion marker (`data: [DONE]` for HTTP SSE; provider `complete` for WS) + no disconnect/timeout/relay-error after incremental-open. Settlement commit gates here.
   - **No-withdrawal rule** (§8.4.3) — once any `tool_calls[]` delta emitted, MUST NOT fall back to plain content. Final-close failure → terminal SSE error frame `data: {"error": {...}}` + `data: [DONE]`. MUST NOT carry `finish_reason:"tool_calls"`.

3. **Money-path posture**: absence of final-close success → `FaultBreakerQualifying` → zero provider-positive credits via existing `billing_recorder.go:176` + `formula.go:112` + no receipt + no sticky-route success write. Current direct-HTTP clean EOF at `server.go:2469-2471` MUST be patched for v0.2 tool-call streaming to require the four final-close conditions.

4. **Per-(buyer, provider) auto-downgrade attribution** (§10d.4):
   - State store: `phase4-coordinator/internal/buyer/streaming_downgrade.go` (new file). Track per-(buyerID, providerID) malformed-stream count with sliding 5-minute window.
   - Threshold: 3 malformed streams in 5 minutes from same buyer to same provider → downgrade for THAT buyer's future requests to THAT provider only (NOT all buyers).
   - Recovery: downgrade lifts after 10 minutes of clean streams from same buyer to same provider.
   - **Critically**: a malicious buyer cannot trigger downgrade affecting OTHER buyers sticky-routed to same provider. AC-45c adversarial test required.

5. **Operator kill switch** — config flag (e.g. `COORDINATOR_STREAMING_FORCE_BUFFERED=1`) that forces buffered-to-end behavior across all buyers. When enabled OR when per-(buyer, provider) downgrade fires, response carries diagnostic header:

   **`X-MacProvider-Streaming-Mode`** values:
   - `incremental` (default for v0.2 Cline-compatible models)
   - `buffered_kill_switch` (operator-disabled)
   - `buffered_provider_downgrade` (auto-downgraded due to malformed history)

   AC-45 + AC-45c require header on every v0.2 response.

6. **NTP-anchored AC-44 timing instrumentation**:
   - Operators MUST run NTP on provider Macs + gateway hosts (v0.2 prerequisite; not inherited from another SPEC). Add `chrony` / `timesyncd` to deployment checklist.
   - Provider emits `t_tool_call_open_detected` timestamp at the moment of recognizing native tool-call markup. Coordinator records `t_first_forwarded_sse_byte`. Gateway records `t_first_gateway_byte`.
   - Skew bound: `|t_provider - t_gateway| ≤ 100 ms` verified via heartbeat at request start. Skew-corrected p95 = `(t_first_gateway_byte - t_tool_call_open_detected) - skew_offset`.
   - Targets: p95 ≤ 1500 ms on M4 hardware; p95 ≤ 3000 ms on M2/M3 hardware (or replace with measured baseline established during IMPL benchmark commit).

**Tests required:**

- `phase4-coordinator/internal/buyer/streaming_test.go` — extend with §8.4.1/2/3 split coverage (AC-40 through AC-45).
- AC-23s streaming forward-compat: capture v0.2 streaming response; replay with `openai==2.44.0` pinned reader (per `tools/version-pins/openai-python-spec-018-v0_1_3-baseline.txt`); assert accumulated `function.arguments` byte-equivalent to non-streaming.
- AC-45c: simulated adversarial buyer A submitting 4 malformed-stream-eliciting requests to provider X; buyer B's sticky-routed request to X still receives `incremental` (header check) AND streaming response (behavior check).

### Deliverable #6 — Multi-turn `tool_call_id` validation (§10d.6)

Already covered above in Deliverable #1 validation items 5 + 7. AC-30 through AC-34 verified by `phase4-coordinator/internal/buyer/multi_turn_test.go` + `phase3-binary/Tests/.../MultiTurnTests.swift`.

### Deliverable #7 — Per-call `function.arguments` byte cap (§10d.7)

**Code edits required:**

1. **`phase3-binary/Sources/macprovider-cli/ToolCallParser.swift`** — update existing 256 KiB constants:
   - `SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP = 1_048_576` (1 MiB)
   - `SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP = 2_097_152` (2 MiB)
   - `SPEC018_ARGUMENTS_MAX_JSON_DEPTH = 32` (unchanged)
   - Inclusive: `byte_len <= cap` succeeds.
   - Byte length: UTF-8 of unescaped final argument string (NOT outer JSON with escape overhead).

2. **`phase4-coordinator/internal/buyer/server.go`** §8.4 commit-worthy validator — identical constants. Stricter on either side is non-compliant.

3. **Multi-call enforcement**:
   - Per-call ≤ 1 MiB → fail with `byte_cap_exceeded`
   - Sum across response ≤ 2 MiB → fail with `response_byte_cap_exceeded`
   - Streaming: incremental accumulators per `tool_calls[].index` + per-response.

**Tests required:**

- AC-35 through AC-39: per-call cap inclusive boundary; aggregate cap; UTF-8 byte counting; streaming mid-stream cap-cross → terminal SSE error + `[DONE]` + `FaultBreakerQualifying`.

### Supporting work — AC-46 model_hash_observed field

**`phase3-binary/Sources/macprovider-cli/`** — every v0.2 response (non-streaming + streaming-final-chunk) includes `usage.macprovider_model_hash_observed` field:
- JSON type: `null | "^[a-f0-9]{64}$"` (lowercase hex SHA-256).
- Value: provider's verified `model_hash` from SPEC-008 subsystem (already plumbed at `phase4-coordinator/internal/pool/provider.go:132-133`). When unknown → `null`.
- Non-canonicalized; observation-only; buyers MUST NOT branch on it in v0.2 per §10d.0.1.
- Provider self-test (AC-46 second branch): when provider's local hash subsystem reports a known hash, field MUST be that hex value; when unknown, field MUST be `null`.

### Supporting work — Thicker error envelope (§10d.0)

All v0.2-introduced errors carry the minimum fields:
```json
{
  "error": {
    "type": "invalid_request_error | api_error | upstream_provider_error",
    "code": "<stable enum>",
    "message": "<human-readable>",
    "param": "<optional JSON path>",
    "retryable": true | false,
    "request_id": "<UUID, propagated from X-Request-ID>",
    "inference_ran": true | false,
    "settlement_ran": true | false
  }
}
```

Codes and retryability per §10d.0 stable code table (12 codes + AC-50/51/52/53/54 + inherited `invalid_tools`).

### Supporting work — AC-25a CI-amenable Cline fixture

Add `test/integration/cline_session/`:
- Pinned Cline VS Code extension version (latest stable at IMPL time, e.g. v4.0.0 = `saoudrizwan.claude-dev`).
- Pinned target repo (small fixture repo or Cline's own examples).
- Pinned prompt (deterministic, e.g. "Read README.md, summarize, add a sentence to docs/CHANGELOG.md").
- Machine-readable transcript schema (JSON: turns, tool_calls, timings, request_ids, streaming_mode header values, raw SSE transcript hashes).
- Automated pass/fail criteria: ≥ 20 provider turns, ≥ 30 tool calls/results, ≥ 3 file edits across ≥ 2 files, ≥ 2 commands with one failure+recovery, ≥ 1 history echo + matching tool result, ≥ 1 `write_to_file` ≥ 64 KiB with first delta < 1500 ms + ≥ 3 deltas before `finish_reason:"tool_calls"`.
- Tool category mapping documented (legacy Cline extension: `list_files`/`search_files`/`read_file`/`write_to_file`/`execute_command`; ClineCore: `bash`/`editor`/`read_files`/`apply_patch`/`search`).
- Workspace MUST include `SPEC-018-agentic-tool-calling.md` as a possible `read_file` target (per AC-25a + Critic Q-1 closure, validates §3.9 deletion didn't reintroduce self-DoS).

AC-25b manual recorded smoke against actual VS Code extension UI: human-recorded session, qualitative UX assessment. Not CI-gated; release evidence only.

### Supporting work — AC-48 split

- AC-48a (openai-python ecosystem): post-final-close-error stream + `openai==2.44.0` reader → no assistant message with dispatchable tool_calls reaches accumulator. Generic SDK gate.
- AC-48b (Cline-direct via Vercel AI SDK): post-final-close-error stream + Cline's `@ai-sdk/openai-compatible` import (verify against `sdk/packages/llms/src/providers/vendors/openai-compatible.ts` at Cline `main@92806c60`) → no dispatchable tool_calls reach `AgentRuntime`. Cline-specific gate.

## Validation commands

After all edits:

```bash
# Swift tests
cd phase3-binary && swift test --filter ToolCallParserTests --filter MultiTurnTests
# Expected: all green; existing v0.1.5 tests preserved.

# Go tests
cd phase4-coordinator && go test -count=1 ./internal/buyer -run 'Test(MultiTurn|Streaming|ByteCap|FinalClose|AutoDowngrade)'
cd phase4-coordinator && go test -count=1 ./internal/buyer
# Expected: all green.

# Integration tests (AC-25a + AC-48a + AC-48b)
cd test/integration && ./run-cline-session.sh
# Expected: pass + transcript artifact at test/integration/cline_session/output/transcript-<timestamp>.json

# AC-23s streaming forward-compat regression
cd test/integration && ./run-ac23s.sh
# Expected: byte-equivalent accumulation; no SDK parse error on success path; terminal error surfaced as exception on error path.

# Linting / formatting
cd phase4-coordinator && gofmt -l . && golangci-lint run
cd phase3-binary && swiftformat --lint .
```

## Money-path preservation requirements

Throughout all edits:

- Existing `phase4-coordinator/internal/buyer/billing_recorder.go:176-190` (`FaultFlag` → `HotPathInput`) MUST be preserved.
- Existing `phase4-coordinator/internal/billing/formula.go:112-114` (`FaultBreakerQualifying` → zero provider credits) MUST be preserved.
- New §8.4.2 final-close failure paths MUST set `FaultBreakerQualifying`.
- New §3.8 family-renderer failure (unsupported_modelID_for_multi_turn) MUST NOT settle (request never reached inference).
- New AC-50 through AC-55 request-validation failures MUST NOT settle (request never reached inference; not provider faults).
- All new error codes carry correct `retryable` boolean per §10d.0 table.

## Constraints

- v0.1.5 IMPL still works (existing AC-1 through AC-24 tests pass).
- No new tests removed from existing suites.
- No SPEC changes — v0.2.4 SPEC LOCKED.
- Cline integration verification REQUIRED (AC-25a + AC-48b) — do NOT skip even if tests pass on the openai-python ecosystem side.
- Per-(buyer, provider) downgrade attribution is the load-bearing security guarantee; AC-45c adversarial test is mandatory.
- §3.8 fixture goldens: if exact Qwen3/Llama-3.3 chat-template bytes can't be pinned from upstream, specify the template structure normatively and cite the upstream `tokenizer_config.json` blob for IMPL reference. Document in commit message.

## Output

Apply edits directly to this worktree. Commit incrementally per deliverable (5+ atomic commits is fine; one giant commit is fine; whichever serves the diff better). Each commit message should reference the AC(s) it closes.

When done, additionally write `specs/SPEC-018-v0_2-IMPL-NOTES.md` covering:
- Per-deliverable summary + AC coverage
- Test fixture locations
- Money-path trace evidence
- Any normative interpretation calls made during IMPL (e.g., §3.8 template-structure vs byte-exact choice)
- Cline session evidence file path (AC-25a transcript artifact)

This IMPL prompt produces a v0.2.4 IMPL diff ready for codex 4-lane audit (architect/code/security/PD) + Claude blind-spot pass per [[feedback-three-lane-codex-audits]] before the IMPL PR opens.

The audit loop on the IMPL diff is the next step; this prompt only produces the IMPL diff itself.
