# SPEC-018 v0.2.4 IMPL — r1 Absorption Prompt

## Your task

Absorb 2 CRITICAL + 10 HIGH + 13 MEDIUM (+ minors + Qs) findings from r1 audit (6 lanes) into the SPEC-018 v0.2.4 IMPL diff. Commit as a v0.2.1 IMPL polish on top of `23266e7`.

**Bar: 0 CRITICAL + 0 HIGH + 0 MEDIUM after r2 re-audit.**

## Authoritative inputs

1. The 6 IMPL audit files: `specs/SPEC-018-v0_2-IMPL-{architect,code,security,product-design,critic,narrative}-r1-audit.md`.
2. `specs/SPEC-018-agentic-tool-calling.md` v0.2.4 LOCKED — the SPEC. Re-read §3.8/§3.8.1, §8.4.1/2/3, §10d.0 (error envelope codes table — `retryable` values for each code), §10d.4 (streaming-default + kill-switch behavioral semantics), §10d.6, §10d.7, AC-25a/25b, AC-44, AC-45/45c, AC-46, AC-48a/48b.
3. `specs/SPEC-018-v0_2-IMPL-NOTES.md` — current absorption notes; MUST be updated as part of this round.
4. The IMPL diff (`git diff 7e50832..HEAD`).

Live repo: `phase3-binary/`, `phase4-coordinator/`, `phase5-gateway/`, `test/integration/`.

## 8 absorption areas

### Area 1: Critic C-1 — Error envelope `retryable` per-code mapping (mechanical, load-bearing)

**Finding**: IMPL hardcodes `retryable:false` on every error. SPEC §10d.0 maps `retryable` per code.

**Fix**:
1. Read SPEC §10d.0 stable code table. For each code, note `retryable: true|false`.
2. Build a per-code `retryable` lookup table in Swift + Go.
3. Update Swift `APIError.envelope` at `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:259-273` to accept `code` and look up `retryable` per code.
4. Update Go `writeSSEError` at `phase4-coordinator/internal/buyer/server.go:4537-4540` to include `retryable`, `request_id`, `inference_ran`, `settlement_ran` in the SSE error payload (it currently omits these entirely from SSE; non-streaming error envelope has them).
5. Add tests: per-code retryable assertions for `malformed_tool_call_final_json` (retryable=true), `provider_stream_downgraded` (retryable=true), `byte_cap_exceeded` (retryable=false), `tool_result_too_large` (retryable=false), etc. Both languages.

### Area 2: Security C-1 + Critic H-3 — AC-48b actually routes SSE through Vercel AI SDK

**Finding**: `test/integration/streaming_terminal_error/ac48b_openai_compatible_terminal_error.test.ts` imports Vercel AI SDK but ignores it; uses hand-rolled parser instead.

**Fix**:
1. Restructure `ac48b_openai_compatible_terminal_error.test.ts` to:
   - Spin up a mocked HTTP server (e.g., via `msw` or a simple Node `http.createServer`) that serves the terminal-error SSE stream when `/v1/chat/completions` is hit.
   - Configure the Vercel AI SDK provider (`createOpenAICompatible`) with `baseURL: http://localhost:<port>/v1/`.
   - Make an actual `streamText` call (or whatever streaming primitive Cline uses; mirror Cline `main@92806c60`'s call pattern from `sdk/packages/llms/src/providers/vendors/openai-compatible.ts`).
   - Assert: the SDK does NOT yield a successful assistant message with dispatchable `tool_calls[]` after the terminal error frame. Either the SDK throws an exception (acceptable), or yields a non-tool-call result + error (acceptable), or the resolved promise rejects (acceptable).
2. The test MUST fail if the SDK silently dispatches a partial tool_call.
3. Add same restructure for AC-48a Python test (`ac48a_openai_python_terminal_error.py`): actually feed the SSE through `openai==2.44.0`'s streaming client, assert no successful assistant message.

### Area 3: Architect H-1 — True token-incremental streaming

**Finding**: `ModelRuntime.swift:528` sets `bufferForToolParsing = hasEnabledTools(...)`, which suppresses `onChunk` during generation. Tool-enabled streams are post-buffered.

**Fix**:
1. Read `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:528` + surrounding context.
2. The architectural problem: for tool-call streams, we need to PARSE tokens incrementally as they're generated, detect the tool-call markup, and START emitting OpenAI-shaped tool_call deltas as soon as we have a valid first-chunk shape (incremental-open per §8.4.1).
3. Implementation strategy:
   - Replace `bufferForToolParsing` boolean with a streaming-aware tool parser state machine.
   - As tokens stream from MLX, feed them through the parser.
   - When parser detects tool-call opening (Qwen `<tool_call>` start OR Llama `<|python_tag|>` start), start emitting OpenAI-shape tool_call deltas with `id`, `type`, `function.name` in the first delta.
   - Subsequent tokens flow through as `function.arguments` fragment deltas.
   - When parser detects tool-call close, emit `finish_reason:"tool_calls"`.
4. Add tests asserting: for a known token stream, the output SSE has ≥ 3 argument-fragment deltas before `finish_reason:"tool_calls"` (matches AC-44's ≥ 3 deltas criterion).

### Area 4: Code H-1 — Downgrade/kill-switch actually buffers, not header-only

**Finding**: Modes are computed but forwarding paths execute the same incremental pass-through. Only the header changes.

**Fix**:
1. In `phase4-coordinator/internal/buyer/server.go` at `forwardStreaming` (~line 2412) and `forwardWSStreaming` (~line 2135):
   - After computing the streaming mode, BRANCH on `streamingModeBufferedKillSwitch` and `streamingModeBufferedProviderDowngrade`.
   - For buffered modes: instead of forwarding chunks incrementally, accumulate all chunks until final-close, then emit ONE consolidated SSE response with full `tool_calls[]` array.
   - For `incremental` mode: existing incremental pass-through.
2. The buffered-mode response is essentially "v0.1 behavior" — buffer-then-emit. Reuse v0.1 code path if possible.
3. Update AC-45c test in `phase4-coordinator/internal/buyer/streaming_test.go:21-52` to:
   - Assert: in buffered mode, the SSE timeline shows NO incremental `function.arguments` fragments (only the final consolidated chunk).
   - Assert: in incremental mode, the SSE timeline shows ≥ 2 incremental fragments.
4. Add tests for `streamingModeBufferedKillSwitch`: when env var `COORDINATOR_STREAMING_FORCE_BUFFERED=1` is set, ALL responses are buffered regardless of buyer/provider.

### Area 5: Critic H-1 — Emit timing headers from provider/coordinator/gateway

**Finding**: `streaming_timing.go` reads four `X-MacProvider-*-Unix-Ms` headers that no component emits.

**Fix**:
1. Identify the four headers (read `streaming_timing.go` to see exact names).
2. **Provider-side** (`phase3-binary/Sources/macprovider-cli/HTTPServer.swift` or `ModelRuntime.swift`): emit `X-MacProvider-Provider-ToolCallOpen-Unix-Ms: <ms_since_epoch>` at the moment of recognizing native tool-call markup. Set as response header (non-streaming) OR as a trailer / dedicated SSE event (streaming).
3. **Coordinator-side** (`phase4-coordinator/internal/buyer/server.go`): emit `X-MacProvider-Coordinator-FirstForward-Unix-Ms` at the moment the coordinator forwards the first tool-call delta to the buyer.
4. **Gateway-side** (`phase5-gateway/internal/router/`): emit `X-MacProvider-Gateway-FirstByte-Unix-Ms` at the moment the gateway sends the first byte to the buyer.
5. **NTP heartbeat skew check** (`X-MacProvider-NTP-Skew-Ms`): emit at request start with current measured skew vs reference clock.
6. Add tests verifying:
   - `/metrics/streaming` shows `samples_total > 0` after an end-to-end request.
   - Skew > 100 ms causes sample-skip (already coded; verify it actually fires).
   - p95 calculation is correct (test with synthetic samples).
7. Update Prometheus output to include skew distribution histogram.

### Area 6: PD H-1 + Critic H-2 — AC-25a actually runs through macprovider

**Finding**: `run_fixture.py` generates all data in-process and self-validates. Doesn't exercise macprovider.

**Fix**:
1. Restructure `test/integration/cline_session/run_fixture.py`:
   - Either (a) spin up actual macprovider stack (provider + coordinator + gateway) and drive it with deterministic prompts via curl/requests, OR (b) provide a MOCK-PROVIDER mode that simulates real responses with `usage.macprovider_model_hash_observed` populated from a deterministic provider-side simulation.
   - The transcript MUST contain values from actual macprovider responses (or simulated provider-mode response generation), not in-process Python-generated data.
   - The validation MUST verify these were not self-generated (e.g., by including a request_id chain that crosses processes).
2. For CI feasibility, option (b) is acceptable: mock-provider simulates Qwen3-32B tool-call output, mock-coordinator wraps it with X-MacProvider-Streaming-Mode + model_hash_observed, mock-gateway returns it. The fixture then drives the mock stack via HTTP requests and records what comes back. This is "harness skeleton + simulated provider" per IMPL-NOTES caveat, but the simulation must be in a SEPARATE process from the validator.
3. Update README to honestly describe what's tested vs simulated.
4. Update IMPL-NOTES to reflect the actual harness model.

### Area 7: Critic M-1 — §3.8.1 Qwen3/Llama-3.3 byte-exact OR tokenizer-config digest

**Finding**: Renderer fixtures use `contains("<tool_call>")`, not byte-exact.

**Fix**:
1. Pull the actual Qwen3 chat template from https://huggingface.co/Qwen/Qwen3-32B/blob/main/tokenizer_config.json (use the commit digest at time of pulling).
2. Pull the actual Llama-3.3 chat template from https://huggingface.co/meta-llama/Llama-3.3-70B-Instruct/blob/main/tokenizer_config.json.
3. Add to `tools/version-pins/`:
   - `qwen3-tokenizer-config-v0_2_4.txt` with the HuggingFace blob commit SHA + content SHA-256.
   - `llama-3_3-tokenizer-config-v0_2_4.txt` with the same.
4. Update Swift `ToolPromptRenderer.swift` to either (a) embed the template strings byte-exact (preferred for determinism), or (b) load them from the pinned blob at runtime with checksum verification.
5. Update `MultiTurnTests.swift` renderer fixture tests to assert byte-exact output against pinned expected renders for known input cases.

### Area 8: Narrative + remaining MEDIUMs — IMPL-NOTES update

**Finding**: IMPL-NOTES under-claims, omits operator-control surface docs, no v0.3-deferred index.

**Fix**:
1. Expand IMPL-NOTES to enumerate ALL AC numbers actually closed:
   - AC-25 through AC-29 (Deliverable #1)
   - AC-25a + AC-25b (Cline release evidence)
   - AC-30 through AC-34 (Deliverable #6)
   - AC-35 through AC-39 (Deliverable #7)
   - AC-40 through AC-45c (Deliverable #4)
   - AC-46 (model_hash_observed)
   - AC-47 (final-close completeness)
   - AC-48a + AC-48b (terminal-error tests)
   - AC-44 (NTP timing)
   - AC-50 through AC-55 (aggregate caps)
   - AC-23s (streaming forward-compat)
2. Add operator-control surface docs:
   - Kill switch: `COORDINATOR_STREAMING_FORCE_BUFFERED=1` env var (at `streaming_downgrade.go:90`)
   - Three `X-MacProvider-Streaming-Mode` states
   - NTP requirement on provider Macs + gateway hosts
3. Add "Deferred to v0.3" index:
   - §3.9 prompt-echo guard (deleted v0.2.3 per Amendment 2)
   - Hash-keyed registry enforcement (Amendment 1, registry curation)
   - Structured `usage.macprovider_malformed_tool_call` signal
   - AC-44 second branch (server-side rendering of timings)
4. Expand `docs/operations/spec-018-v0.2-deploy.md` from current 11 lines to a real operator runbook:
   - Deployment prerequisites (NTP)
   - Env vars (COORDINATOR_STREAMING_FORCE_BUFFERED)
   - Headers operators may see
   - Monitoring: `/metrics/streaming` Prometheus endpoint
   - Auto-downgrade behavior (3 in 5min, 10min recovery)
   - Rollback procedure to v0.1 behavior
5. Fix Package.swift unhandled-resources warning: declare the 3 JCS fixture files (`null_hash.json`, `non_null_hash.json`, `README.md`) as resources OR exclude from target.

## Verification

After all edits:

```bash
cd /Users/augstar/macprovider-impl-spec-018-v0-2

cd phase3-binary && swift test 2>&1 | tail -10
# Expected: 0 failures. No new failures from the absorption.

cd ../phase4-coordinator && go vet ./... && go test -count=1 ./internal/buyer 2>&1 | tail -10
# Expected: ok internal/buyer.

# AC-48a/b real SDK consumption tests
cd ../test/integration/streaming_terminal_error && ./run-ac48a.sh && ./run-ac48b.sh
# Expected: both pass. AC-48b must actually use Vercel AI SDK (verify by reading the test).

# AC-25a runs through (mock or real) macprovider stack
cd ../cline_session && ./run-cline-session.sh
# Expected: pass. Transcript artifact written.

# git diff --check
cd /Users/augstar/macprovider-impl-spec-018-v0-2 && git diff --check
```

## Output

1. All edits applied to the worktree.
2. Updated `specs/SPEC-018-v0_2-IMPL-NOTES.md`.
3. Single absorption commit on top of `23266e7`. Commit message format:
   ```
   SPEC-018 IMPL v0.2.4 — r1 absorption (2C + 10H + 13M + minors + Qs)

   Absorbs r1 audit findings across 6 lanes (4 codex + Claude critic/narrative).
   ...
   ```
4. DO NOT push. Audit r2 fires after.

## Constraints

- v0.2.4 SPEC LOCKED — no SPEC edits.
- v0.1.5 IMPL still works.
- All r1 CRITICAL + HIGH MUST close. r1 MEDIUM SHOULD close.
- Test suites green before commit.
- No `XCTSkip` or `t.Skip()` to bypass tests.

## What this produces

v0.2.1 IMPL commit ready for r2 6-lane re-audit. Target: r2 0/0/0 → push + open IMPL PR.
