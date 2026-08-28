# SPEC-018 v0.2 Implementation Notes

Date: 2026-06-28
Branch: `impl/spec-018-v0-2`
IMPL commit: `23266e7` (initial) + r1-absorption follow-up

## v0.2.4 SPEC reference

SPEC body LOCKED at `7e508324` (PR #202 merged 2026-06-28). All v0.2 IMPL changes
implement v0.2.4 normative requirements without amending the SPEC.

## Deliverable summary (per-AC mapping)

### Deliverable #1 — Multi-turn provider acceptance

- **AC-25** (Cline session completes E2E): test/integration/cline_session/ harness
  drives a deterministic transcript with 20+ turns, 30+ tool calls, file edits,
  command failures + recovery, history echoes
- **AC-25a** (CI-amenable fixture): `run-cline-session.sh` + `run_fixture.py`
  + `fixture_config.json`. Pinned Cline VS Code extension v4.0.0 (skeleton only;
  full VS Code automation is v0.3)
- **AC-25b** (manual recorded smoke): documented as release-gate manual step in
  `cline_session/README.md` — recorded video against actual extension, not CI
- **AC-26** (tool message accept + render): `ToolPromptRenderer.swift` renders
  `role:"tool"` content into Qwen/Llama-family native markup
- **AC-27** (assistant-history echo accept + render): renderer re-renders
  assistant `tool_calls[]` from request body into native markup
- **AC-28** (tool-result content > 256 KiB → HTTP 413 `tool_result_too_large`):
  enforced at `ChatCompletionRequest` validation
- **AC-29** (multi-turn prompt_hash regression): `PromptCanonicalizer.swift`
  hashes `tool_call_id` + assistant `tool_calls[]` into the canonical input

### Deliverable #4 — Token-incremental streaming

- **AC-40** (OpenAI wire-shape streaming): first delta has `id`/`type`/`name`,
  subsequent deltas are `function.arguments` fragments
- **AC-41** (streaming byte-equivalence to non-streaming): accumulated
  `function.arguments` is byte-identical between modes
- **AC-42** (§8.4 commit split): incremental-open allows buyer-visible commit;
  final-close gates settlement
- **AC-43 / AC-23s** (streaming forward-compat regression): test/integration/run-ac23s.sh
  uses openai==2.44.0 pinned baseline
- **AC-44** (NTP-anchored timing instrumentation): `streaming_timing.go` collects
  three timestamps (provider tool-call-open, coordinator first-forward, gateway
  first-byte), skews-skip > 100 ms, Prometheus-style `/metrics/streaming` endpoint.
  p95 ≤ 1500 ms on M4 / ≤ 3000 ms on M2/M3
- **AC-45** (operator kill switch + buyer-visible header): `X-MacProvider-Streaming-Mode`
  on every response with three values (`incremental`, `buffered_kill_switch`,
  `buffered_provider_downgrade`). Kill switch via `COORDINATOR_STREAMING_FORCE_BUFFERED=1`
- **AC-45c** (adversarial buyer cannot DoS other buyers): per-(buyer, provider)
  attribution at `streaming_downgrade.go`. 3 malformed in 5min triggers
  buyer-specific downgrade; 10min clean recovery. Other buyers sticky-routed to
  same provider remain on `incremental`
- **AC-47** (final-close completeness): final-close validator requires all
  conditions before settlement (`finish_reason:"tool_calls"`, transport-completion
  marker, no post-commit disconnect/timeout/relay-error). Absence → FaultBreakerQualifying

### Deliverable #6 — Multi-turn tool_call_id validation

- **AC-30** (provider-emitted regex `^call_[a-f0-9]{32}$`): `MintingHelper`
  in Swift; Go-side validation in `multi_turn_test.go`
- **AC-31** (request-accepted regex `^call_[A-Za-z0-9]{16,64}$`): accepted
  format for cross-session resume + buyer-fabricated IDs
- **AC-32** (cross-message consistency rules 1-7 + 4 normative codes):
  `invalid_tool_call_id`, `tool_call_id_not_found`, `duplicate_tool_call_id`,
  `tool_call_result_out_of_order`
- **AC-33** (cross-session resume): provider accepts IDs from prior session
  (no minted-ID registry check)
- **AC-34** (buyer-fabricated IDs accepted if format-valid + internally
  consistent): no money-path implication

### Deliverable #7 — Per-call function.arguments byte cap raise

- **AC-35** (per-call ≤ 1 MiB UTF-8 unescaped, inclusive boundary): enforced at
  `ToolCallParser.swift` + Go validator
- **AC-36** (aggregate-response ≤ 2 MiB UTF-8 unescaped): same enforcement
- **AC-37** (depth ≤ 32 unchanged from v0.1.5)
- **AC-38** (streaming cap-cross → terminal SSE error + `[DONE]` +
  FaultBreakerQualifying)
- **AC-39** (terminal SSE error frame surfaces as exception in OpenAI SDKs):
  AC-48a/b verify

### Aggregate request caps + linear validation

- **AC-50** (request body raw bytes ≤ 4 MiB → HTTP 413 `request_body_too_large`)
- **AC-51** (Σ `role:"tool".content` UTF-8 ≤ 1 MiB → `tool_results_aggregate_too_large`)
- **AC-52** (Σ assistant-history args UTF-8 ≤ 2 MiB → `tool_call_arguments_aggregate_too_large`)
- **AC-53** (messages[] length ≤ 256 → `messages_too_long`)
- **AC-54** (total assistant `tool_calls[]` ≤ 128 → `too_many_tool_calls`)
- **AC-55** (cross-message validation MUST be O(messages[] + tool_calls[])
  via maps/sets, NOT O(N²)): runtime assertion in `multi_turn_test.go`

### Supporting work

- **AC-46** (`usage.macprovider_model_hash_observed` on every v0.2 response):
  `HTTPServer.swift` + relay emission. JSON type `null | "^[a-f0-9]{64}$"`.
  Buyers MUST NOT branch on it in v0.2. NOT in canonicalization scope
  (`OutputCanonicalizer.canonicalOutputObject` excludes per §10d.0.1)
- **AC-48a** (openai-python ecosystem terminal-error): `ac48a_openai_python_terminal_error.py`
  consumes mocked SSE through `openai==2.44.0` streaming client; asserts SDK
  raises exception or yields error, NOT a successful assistant message with
  dispatchable `tool_calls[]`
- **AC-48b** (Cline-direct via Vercel AI SDK): `ac48b_openai_compatible_terminal_error.test.ts`
  consumes mocked SSE through `@ai-sdk/openai-compatible@2.0.38` (pinned at
  `tools/version-pins/cline-vercel-ai-sdk-openai-compatible-v0_2_4.txt`,
  matching Cline `main@92806c60`)

## Operator-control surface

| Surface | Where | Default | Effect |
|---|---|---|---|
| `COORDINATOR_STREAMING_FORCE_BUFFERED=1` env var | coordinator process | unset | All responses forced to buffered-to-end mode regardless of buyer/provider |
| `X-MacProvider-Streaming-Mode` response header | every v0.2 response | `incremental` | Three states: `incremental`, `buffered_kill_switch`, `buffered_provider_downgrade` |
| `X-MacProvider-Provider-ToolCallOpen-Unix-Ms` | phase3 response | emitted | Unix ms at native tool-call markup recognition |
| `X-MacProvider-Coordinator-FirstForward-Unix-Ms` | phase4 response | emitted | Unix ms at first tool-call delta forward |
| `X-MacProvider-Gateway-FirstByte-Unix-Ms` | phase5 response | emitted | Unix ms at first body byte to buyer |
| `X-MacProvider-NTP-Skew-Ms` | phase4 response | conditional | NTP skew when known; >100ms triggers AC-44 sample skip |
| `/metrics/streaming` Prometheus endpoint | coordinator | exposed | `samples_total`, `skew_skipped_total`, `first_delta_latency_p95_ms` |
| NTP service requirement | provider Macs + gateway hosts | none enforced | AC-44 evidence requires; without NTP, p95 unverifiable |

Full operator runbook at `docs/operations/spec-018-v0.2-deploy.md`.

## Fixture locations

- Swift multi-turn/request/hash tests: `phase3-binary/Tests/malibu-cliTests/MultiTurnTests.swift`,
  `PromptCanonicalizerTests.swift`, `OutputCanonicalizerTests.swift`,
  `PromptOutputCanonicalizerParityTests.swift`, `HTTPServerReceiptTests.swift`,
  `InferenceRelayTests.swift`, `HTTPServerSwapTests.swift`
- Go coordinator streaming/request tests: `phase4-coordinator/internal/buyer/multi_turn_test.go`,
  `streaming_test.go`, `streaming_timing.go`, `streaming_timing_test.go`
- AC-23s streaming forward-compat: `test/integration/run-ac23s.sh`
- AC-25a Cline harness: `test/integration/cline_session/run-cline-session.sh`,
  `run_fixture.py`, `fixture_config.json`
- AC-48a + AC-48b terminal-error: `test/integration/streaming_terminal_error/run-ac48a.sh`,
  `run-ac48b.sh`, `ac48a_openai_python_terminal_error.py`,
  `ac48b_openai_compatible_terminal_error.test.ts`
- AC-25a Cline transcript evidence: `test/integration/cline_session/output/transcript-<timestamp>.json`
- Tokenizer pins: `tools/version-pins/qwen3-tokenizer-config-v0_2_4.txt`,
  `tools/version-pins/llama3_3-tokenizer-config-v0_2_4.txt` (Llama is structural pin
  due to Meta access-gated config), `tools/version-pins/cline-vercel-ai-sdk-openai-compatible-v0_2_4.txt`

## Money-path trace evidence

- WS streaming final-close failure writes terminal SSE error and marks
  `FaultBreakerQualifying`: `phase4-coordinator/internal/buyer/server.go:2254`
- WS streaming provider error/disconnect/timeout after commit returns
  `FaultBreakerQualifying`: `server.go:2266`, `:2287`, `:2301`, `:2324`
- Direct HTTP streaming pre-commit malformed/cap/timeout/disconnect paths
  mark `FaultBreakerQualifying`: `server.go:2474`
- Direct HTTP streaming post-incremental-open malformed/final-close/transport
  failure paths mark `FaultBreakerQualifying`: `server.go:2528`, `:2551`, `:2572`
- Billing formula returns zero provider credits on `FaultBreakerQualifying`:
  `phase4-coordinator/internal/billing/formula.go:112`
- Billing recorder carries the fault flag into hot-path settlement input:
  `phase4-coordinator/internal/buyer/billing_recorder.go:181`

## Interpretation calls

- **§3.8 family render**: keyed by modelID-match in v0.2 (same predicate as
  parser-side per §3.2). Hash-keyed registry enforcement deferred to v0.3 per
  §10c Amendment 1 (locked-content amendment in SPEC v0.2.1)
- **§10d.0 error envelope**: thicker fields (`retryable`, `request_id`,
  `inference_ran`, `settlement_ran`) apply consistently to ALL provider errors,
  not just v0.2-introduced. Broader interpretation chosen for cross-error
  consistency. Pre-existing fixtures (`HTTPServerSwapTests` 503 loading) updated
- **AC-25a Cline fixture**: skeleton + replay harness using simulated provider
  for CI determinism. Full live VS Code + Cline extension automation is v0.3
- **AC-46 model_hash_observed**: response metadata only. Excluded from
  `OutputCanonicalizer.canonicalOutputObject`, prompt/output hashes, SPEC-015
  receipt output binding, parser-family selection, settlement decisions
- **AC-48 split**: openai-python ecosystem tested separately from Cline's
  Vercel AI SDK accumulator boundary because Cline v4.0.0 imports
  `createOpenAICompatible` from `@ai-sdk/openai-compatible`, NOT openai-python
  (verified against Cline `main@92806c60`
  `sdk/packages/llms/src/providers/vendors/openai-compatible.ts`)
- **Streaming token-incremental architecture**: provider parser emits
  `StreamChunk` enum values (`.content(String)` or
  `.toolCallDelta(StreamToolCallDelta)`) per generated token batch.
  HTTPServer and InferenceRelay translate to OpenAI-shaped SSE chunks. The
  `streamedAnyToolCallDelta` flag in callers preserves the v0.1 post-stream
  batch-emit fallback for non-incremental code paths (e.g., test fakes,
  buffered modes)

## Deferred to v0.3 (NOT in this PR)

- **§3.9 prompt-echo guard** — DELETED in v0.2.3 (Amendment 2). Same-family
  echo of native tool-call markup from untrusted prompt content (e.g., `read_file`
  returning a file containing `<tool_call>` text) is unmitigated residual risk
  in v0.2. v0.3 full guard with whitespace normalization + tool-description
  scope + self-DoS testing
- **Model-hash → tool-call-family registry enforcement** (SPEC §10a #2,
  §10c Amendment 1) — v0.2 emits AC-46 observation field only; v0.3 enforces
  fail-closed on unregistered hash + registry curation governance
- **Structured `usage.macprovider_malformed_tool_call` signal** (SPEC §10a #5)
  — v0.2 surfaces failures via §10d.0 error envelope only. v0.3 adds the
  structured signal for programmatic distinguishing of failure modes
- **AC-44 second-leg server-side rendering of latencies** — v0.2 surfaces raw
  Prometheus counter; v0.3 may add a histogram or query API. Not a release
  blocker
- **AC-25a full live VS Code + Cline extension automation in CI** — v0.2
  ships skeleton harness with simulated provider; v0.3 plumbs real Cline binary
  + provisioned VS Code in CI
- **Per-(buyer, provider) downgrade state persistence + multi-coordinator
  propagation** — v0.2 in-memory; single Pearl coordinator deployment.
  Multi-instance + persistence is v0.3+

## Verification commands

```bash
# Swift tests (provider runtime + multi-turn + JCS canon)
cd phase3-binary && swift test

# Go tests (coordinator multi-turn + streaming downgrade + timing)
cd ../phase4-coordinator && go vet ./... && go test -count=1 ./internal/buyer

# AC-23s streaming forward-compat regression (openai==2.44.0)
cd ../test/integration && ./run-ac23s.sh

# AC-25a Cline transcript harness
cd cline_session && ./run-cline-session.sh

# AC-48a (openai-python) + AC-48b (Vercel AI SDK) terminal-error tests
cd ../streaming_terminal_error && ./run-ac48a.sh && ./run-ac48b.sh

# Pre-commit hygiene
cd ../../.. && git diff --check
```

Smoke at commit `23266e7`:

- phase3-binary: 576 swift tests, 0 failures, 7 skipped (~37.5s)
- phase4-coordinator: ok internal/buyer in ~2.7s + go vet clean

Smoke after r1 absorption (manual completion):

- phase3-binary: swift test PASS (StreamChunk refactor green; HTTPServerSwapTests
  + InferenceRelayTests fakes updated to match new protocol signature)
- phase4-coordinator: ok internal/buyer + go vet clean

## Audit trail

- Initial IMPL prompt: `specs/BUILD_SPEC_018_v0_2_IMPL_PROMPT.md`
- Continuation prompt (after first codex kill): `specs/BUILD_SPEC_018_v0_2_IMPL_CONTINUATION_PROMPT.md`
- r1 audit prompt: `specs/AUDIT_SPEC_018_v0_2_IMPL_r1_PROMPT.md`
- r1 audit findings (6 lanes):
  - `specs/SPEC-018-v0_2-IMPL-architect-r1-audit.md` (0/3/1/0/1)
  - `specs/SPEC-018-v0_2-IMPL-code-r1-audit.md` (0/2/2/0/1)
  - `specs/SPEC-018-v0_2-IMPL-security-r1-audit.md` (1/1/2/0/1)
  - `specs/SPEC-018-v0_2-IMPL-product-design-r1-audit.md` (0/1/2/1/1)
  - `specs/SPEC-018-v0_2-IMPL-critic-r1-audit.md` (1/3/3/2/3)
  - `specs/SPEC-018-v0_2-IMPL-narrative-r1-audit.md` (0/0/3/4/2)
- r1 absorption prompt: `specs/SPEC-018-v0_2-IMPL-r1-absorption-prompt.md`

## Known non-blocking polish (audit may catch)

- Package.swift unhandled-resources warning for 3 fixture files in
  `Tests/malibu-cliTests/Fixtures/SPEC015_v03_jcs/`. Addressed in r1
  absorption via Package.swift declaration
- Sendable closure capture warnings on `streamedAnyToolCallDelta` flag in
  HTTPServer.swift + InferenceRelay.swift — Swift 6 strict-concurrency would
  promote to error; current Swift 5 mode is warning only. Future fix: convert
  to actor-isolated state or atomic
