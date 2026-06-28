# SPEC-018 v0.2.4 IMPL — Critic Blind-spot r1 Audit

**Date:** 2026-06-28
**Reviewer:** claude critic blind-spot
**Verdict:** FIX REQUIRED

## Tally: C/H/M/m/Q

- CRITICAL: 1
- HIGH: 3
- MEDIUM: 3
- minor: 2
- Open questions: 3

## Findings

### CRITICAL findings

#### C-1 — SPEC §10d.0 thicker error envelope is hardcoded `false`/`null` across the board; SPEC's `Retryable` column is silently ignored

**Evidence**:

- `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:259-273` — `APIError.envelope` hardcodes `"retryable": false`, `"request_id": NSNull()`, `"inference_ran": false`, `"settlement_ran": false` for **every** error. The `APIError.init` (line 251) doesn't even accept these as parameters.
- `phase4-coordinator/internal/buyer/server.go:4537-4540` — `writeSSEError(w, message, code string)` emits ONLY `{"message":...,"type":"server_error","code":...}` with **none** of the four thicker fields.
- SPEC `specs/SPEC-018-agentic-tool-calling.md:736-753` normatively requires `{retryable, request_id, inference_ran, settlement_ran}` to be present in EVERY v0.2-introduced HTTP and terminal SSE error.
- SPEC §10d.0 stable code table (`:759-776`) explicitly lists Retryable=true for `malformed_tool_call_final_json`, `provider_stream_downgraded`. The IMPL emits these codes with hardcoded `retryable=false`.
- `phase4-coordinator/internal/buyer/server.go:2533, 2557` emit `"malformed_tool_call"` and `"tool_call_final_close_failed"` via `writeSSEError`, which strips the thicker fields entirely (not just sets them to wrong values — they don't exist in the envelope).

**Confidence**: HIGH

**Why this matters**: The SPEC's whole point in §10d.0 was to give buyers an actionable retry signal. Cline now has no way to distinguish "retry me" from "abandon" via the documented contract. SPEC retryable=true codes are reported as retryable=false, which would cause Cline to abandon sessions that the SPEC says are retryable. The SSE path is even worse — the fields don't exist at all, which is a structural schema violation.

**Fix**:
1. Extend `APIError` (Swift) with `retryable: Bool`, `requestID: String?`, `inferenceRan: Bool`, `settlementRan: Bool` parameters (default per SPEC table), and have call sites supply them. Map them in `envelope`.
2. Replace `writeSSEError(w, message, code)` (Go) with a signature that takes the same four fields, look them up from the per-code SPEC table when not supplied, and emit them in the SSE error payload.
3. Add a unit test that asserts the per-code SPEC table values land in the emitted envelope for every v0.2-introduced code.

### HIGH findings

#### H-1 — AC-44 NTP-anchored streaming-timing instrumentation is wired to headers no component emits; metrics always report zero samples

**Evidence**:

- `phase4-coordinator/internal/buyer/streaming_timing.go:15-18` defines four required headers: `X-MacProvider-Tool-Call-Open-Detected-Unix-Ms`, `X-MacProvider-First-Gateway-Byte-Unix-Ms`, `X-MacProvider-Provider-Unix-Ms`, `X-MacProvider-Gateway-Unix-Ms`.
- `streaming_timing.go:48-51`: if `streamingTimingProviderOpenHeader` is missing, `observeFromHeaders` returns silently.
- Grep across the entire codebase shows ONLY `streaming_timing.go` and its test reference these headers. **No phase3 code emits `X-MacProvider-Tool-Call-Open-Detected-Unix-Ms` from the provider**, no phase5 gateway emits the gateway-side `*-Unix-Ms` headers, no coordinator code injects `*-Provider-Unix-Ms`. Verified via:
  - `grep -rn 'X-MacProvider-Tool-Call-Open-Detected' phase3-binary/Sources` → 0 hits.
  - `grep -rn 'X-MacProvider-First-Gateway-Byte\|X-MacProvider-Gateway-Unix\|X-MacProvider-Provider-Unix' phase5-gateway phase3-binary phase4-coordinator` → only the constant-definition lines in `streaming_timing.go` itself.
- `streaming_timing_test.go:14-20` synthesizes the headers in the test — production code does not.
- Result: `/metrics/streaming` will always report `macprovider_streaming_timing_samples_total 0` and `macprovider_streaming_forward_lag_p95_ms 0` in production. The p95 ≤ 1500 ms / ≤ 3000 ms targets in SPEC AC-44 are unmeasurable.

**Confidence**: HIGH

**Why this matters**: AC-44 normative MUST: "Provider-side timestamp instrumentation is REQUIRED". The IMPL ships dead instrumentation that passes its own test but cannot measure anything in production. This is a SPEC violation (`Fail condition: missing timestamps`). Worse, the existence of `/metrics/streaming` will give operators false confidence that AC-44 is being measured when in fact zero samples are ever collected.

**Fix**: Either (a) phase3-binary emits `X-MacProvider-Tool-Call-Open-Detected-Unix-Ms` on its streaming response headers when the first tool-call delta is detected, AND phase5-gateway injects `X-MacProvider-First-Gateway-Byte-Unix-Ms` + `X-MacProvider-Gateway-Unix-Ms`, OR (b) delete the dead instrumentation and document AC-44 as deferred. Either way, do not ship a dead metrics endpoint that pretends to measure latency.

#### H-2 — AC-25a fixture transcript omits `usage.macprovider_model_hash_observed`, violating SPEC AC-25a fixture schema requirement

**Evidence**:

- SPEC AC-25a (`specs/SPEC-018-agentic-tool-calling.md:589`) requires the fixture transcript to include: "`usage.macprovider_model_hash_observed` value per provider response".
- `test/integration/cline_session/run_fixture.py` constructs a synthetic transcript via `make_transcript()`. Grep confirms the field is absent: `grep -n "model_hash_observed" test/integration/cline_session/*` returns nothing.
- AC-25a Fail condition: "any criterion missing, transcript schema invalid". The synthetic transcript is structurally non-compliant.
- AC-25a also requires assertions on "Cline session success whether `usage.macprovider_model_hash_observed` is a known lowercase hex hash or `null`, no Cline branching on the value". The fixture validates none of this branching coverage.

**Confidence**: HIGH

**Why this matters**: AC-25a is the release gate. Even as a "skeleton/replay contract" (per IMPL-NOTES interpretation), it is supposed to set up the transcript schema correctly so that a release-gate run can produce schema-conformant evidence. The current fixture, if used as the schema contract for a real Cline run, would produce schema-violating evidence that fails the SPEC AC.

**Fix**: Add `model_hash_observed: <null|hex>` to each entry in `turns[]` (or alongside each provider response in the per-turn `tool_calls[].result.usage` block), and add both `null` and known-hex synthetic turns so the schema covers both branches. Validate(): assert presence on every turn, and assert that the dataset contains at least one null and one hex value (proving the schema actually handles both).

#### H-3 — AC-48b "Cline / Vercel AI SDK accumulator boundary" test does not actually exercise the Vercel AI SDK

**Evidence**:

- `test/integration/streaming_terminal_error/ac48b_openai_compatible_terminal_error.test.ts`:
  - Line 56-60: `createOpenAICompatible({...})` constructs a provider object but never uses it.
  - Line 19-40: `accumulateAtAgentRuntimeBoundary` is a hand-rolled local accumulator that has nothing to do with the Vercel AI SDK's actual streaming pipeline.
  - Line 63-66: assertions are on the local accumulator, not on what `@ai-sdk/openai-compatible` would actually do with the same SSE stream.
- SPEC AC-48b intent (per `specs/SPEC-018-agentic-tool-calling.md:38`, v0.2.3 mechanics note): "splits AC-48 into AC-48a/AC-48b for openai-python vs Cline/Vercel AI SDK".
- The fixture proves only that the `@ai-sdk/openai-compatible@2.0.38` module *imports* successfully — not that the actual SDK accumulator refuses to dispatch tool calls after a terminal error.

**Confidence**: HIGH

**Why this matters**: AC-48b exists because openai-python and the Vercel AI SDK have different accumulator semantics. A hand-rolled accumulator that happens to do the right thing tells us nothing about Cline's actual runtime behavior. This is the kind of test that gives a green checkmark while the real protection is unverified. If a future @ai-sdk/openai-compatible release accumulates partial tool_calls past a terminal error, this test will still pass.

**Fix**: Stand up a tiny SSE server (similar to AC-48a's Python `ThreadingHTTPServer`), point the real Vercel AI SDK at it via `streamText` / equivalent, and assert that the SDK either raises or yields no dispatchable tool call. The current test should not satisfy the SPEC AC-48b until it does.

### MEDIUM findings

#### M-1 — Renderer fixtures are not byte-equivalent to upstream Qwen3/Llama-3.3 tokenizer chat templates, AND no tokenizer-config commit/digest is pinned (SPEC §3.8.1 alternative-path requirement)

**Evidence**:

- SPEC §3.8.1 (`specs/SPEC-018-agentic-tool-calling.md:284`): "If upstream tokenizer chat templates provide byte-exact tool-call/tool-result rendering for the selected model artifact, the fixture output MUST be byte-exact against that upstream template. Where upstream documentation is not directly byte-stable in this SPEC, the fixture MUST at minimum enforce the normative structure below **and record the exact upstream tokenizer-config commit or artifact digest used by the implementation**."
- `MultiTurnTests.swift:13-19, 21-29` use `XCTAssertTrue(rendered[1].content.contains("<tool_call>"))` and `contains("<|python_tag|>")`. These are substring checks, not byte-equivalence.
- `grep -rn "tokenizer_config\|tokenizer-config" phase3-binary/ specs/SPEC-018-v0_2-IMPL-NOTES.md tools/version-pins/` returns ONE hit: `ModelRuntime.swift:143` references the file path but no tokenizer-config commit/digest is captured anywhere in the IMPL.
- Result: AC-26 and AC-27 fail condition ("non-equivalence to §3.8 fixtures") is not verifiable. We have neither byte-exact equivalence proof NOR a pinned upstream artifact digest.

**Confidence**: HIGH

**Why this matters**: This is the canonical "fixture proves nothing" problem. The substring assertions would pass even if the hand-rolled rendering diverges from what Qwen3 / Llama-3.3 actually expect from their tokenizer config — and divergence is the failure mode the model would silently swallow at inference time, producing garbage tool calls.

**Fix**: Either (a) add a golden test that reads the upstream tokenizer_config.json (or a vendored copy keyed by commit SHA) and asserts byte-exact equivalence on the canonical fixture, OR (b) add a `tools/version-pins/qwen3-tokenizer-config.txt` and `llama-3.3-tokenizer-config.txt` recording the exact upstream commit/digest used, and reference them from `SPEC-018-v0_2-IMPL-NOTES.md`.

#### M-2 — AC-46 provider self-test silently sanitizes mismatch instead of asserting; SPEC fail condition is not enforceable

**Evidence**:

- SPEC AC-46 (`specs/SPEC-018-agentic-tool-calling.md:635`): "Provider self-test: when the provider's own `model_hash` subsystem reports a known hash, the field MUST be that lowercase hex value; when unknown, the field MUST be `null`. ... Fail condition: ... provider self-test mismatch against local `model_hash` state."
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:766-774` — `validObservedModelHash` returns `nil` when the input doesn't match `^[a-f0-9]{64}$`. There is no log, no assertion, no metric. If the local `model_hash` subsystem reports "known: mixed-case hash" (a real misconfiguration), the field becomes `null` silently.
- No test exercises the "known but format-invalid" path to assert behavior matches SPEC intent.

**Confidence**: MEDIUM

**Why this matters**: SPEC says the self-test is supposed to *detect* mismatch as a release-gate signal. The IMPL turns mismatch into clean null emission, which is indistinguishable from "no local hash known". A provider with a misconfigured hash subsystem will silently look healthy.

**Fix**: When `validObservedModelHash` rejects a non-nil input (i.e., the subsystem reports a hash but it's not valid hex), emit a warning log line AND return `nil` (preserving wire-format safety). Optionally: add a counter metric and a release-gate self-test fixture that asserts the log line fires.

#### M-3 — AC-48a Python test assertion has a logical gap that lets failures pass silently

**Evidence**:

- `test/integration/streaming_terminal_error/ac48a_openai_python_terminal_error.py:107`:
  ```python
  if not saw_exception and accumulated.endswith("}"):
      raise AssertionError("openai-python accumulated a complete dispatchable tool call without raising")
  ```
- The accumulated test data is `{"path":"README.md","content":"partial` (line 22 + 39) — fragments concatenate to `{"path":"README.md","content":"partial`. `accumulated.endswith("}")` is False regardless of SDK behavior.
- Therefore the assertion at line 107 is never reachable for this fixture; the test cannot catch the failure mode it claims to guard against.

**Confidence**: HIGH

**Why this matters**: The test scaffolding looks like real coverage but the guard condition is impossible to trip given the test data. A regression in openai-python that started accumulating past the terminal error would not be caught.

**Fix**: Change the assertion to check what the SPEC actually forbids: `if not saw_exception and not saw_successful_tool_finish_is_blocked` (or assert that the SDK either raised OR the accumulated buffer remained non-dispatchable). Alternatively, change the fixture so the terminal-error-followed payload would complete to valid JSON if the SDK swallowed the error.

### minor findings

- **m-1** — `streamingDowngradeStore.recordClean` (`phase4-coordinator/internal/buyer/streaming_downgrade.go:65-76`) early-returns when `downgradeUntil.IsZero()`. This means clean traffic never prunes the `entry.malformed` slice when below threshold. Pruning happens only on `recordMalformed` / `isDowngraded`. Mem leak is bounded (5-minute window, prune on next event) but the recordClean code path doesn't do what the function name suggests for the most common case. Either rename or make it actually prune stale malformed entries when called.
- **m-2** — Package.swift `SPEC015_v03_jcs/` fixture files (`null_hash.json`, `non_null_hash.json`, `README.md`) trigger an unhandled-resources warning (already self-noted in commit message). Add explicit `.copy(...)` or `.process(...)` resource declarations under the test target.

### Open questions

- **Q-1** — `streamingDowngradeStore` state is process-local memory (`map[string]streamingDowngradeEntry`). On coordinator restart, all per-(buyer, provider) downgrade counters reset. For the current single-coordinator Pearl deployment this is acceptable, but the SPEC AC-45 wording ("3 malformed in 5 min") implies a stable window that survives operator restart-on-deploy. Question for IMPL author: was a restart-survival requirement considered, and is it explicitly out of scope for v0.2?
- **Q-2** — `@ai-sdk/openai-compatible` is pinned to **exactly** `2.0.38` in `test/integration/streaming_terminal_error/package.json`. Cline upstream (verified at `cline/cline@92806c60 sdk/packages/llms/package.json`) declares `^2.0.38`, so a real Cline install resolves to the latest 2.x. The test pin therefore exercises the floor of compatibility, not whatever Cline users actually run. Should AC-48b additionally run against the npm-resolved latest 2.x to catch upstream regression?
- **Q-3** — AC-25a fixture copies `SPEC-018-agentic-tool-calling.md` into the workspace (`run_fixture.py:25`) but the synthetic transcript never actually performs a `read_file` on it. SPEC AC-25a fail condition includes "SPEC-018 self-reading breaks a legitimate follow-up tool call". The current fixture does not exercise that path. Should the fixture include a synthetic turn where `read_file("SPEC-018-agentic-tool-calling.md")` is followed by a successful next tool call to make the assertion meaningful?

## Verdict justification

**FIX REQUIRED** — Bar (0 C + 0 H + 0 M) is not met: 1 CRITICAL, 3 HIGH, 3 MEDIUM.

Mode: started in THOROUGH, escalated to ADVERSARIAL after C-1 and H-1 surfaced (CRITICAL trigger met). Adversarial pass expanded scope to AC-48b real-SDK verification (found H-3), AC-25a transcript schema (found H-2), AC-46 self-test enforceability (M-2), and AC-48a guard-condition reachability (M-3).

Realist Check applied:
- C-1 retained at CRITICAL: SPEC compliance for the error envelope is non-negotiable AND the SSE-side gap means the field doesn't structurally exist (not just wrong value). Cline retry policy depends on this. Mitigation: none in-tree.
- H-1 retained at HIGH (not CRITICAL): production downside is unmeasurable AC-44 latency, not money-path failure. Mitigated by: AC-44 is a release-gate observability requirement, not a settlement gate. Detection: would be discovered when first operator queries `/metrics/streaming` and sees `samples_total 0`. Still HIGH because the SPEC normatively requires the timestamps.
- H-2/H-3 retained at HIGH: SPEC fail conditions are written for AC-25a and AC-48b that the fixtures cannot satisfy. These ARE the release gates.

The codex 4-lane and the codex r3 round already verified SPEC compliance on the `model_hash_observed` canonicalization exclusion question (genuinely confirmed clean here). What they appear to have missed: (a) the error envelope is the same hardcoded constants regardless of SPEC table, (b) AC-44 instrumentation reads headers nothing emits, (c) the AC-48b "test" doesn't actually use the SDK it claims to test, (d) AC-25a schema omits a required field.

Pre-commitment predictions vs actuals:
- Predicted: AC-44 telemetry may be loosely wired (HIT — H-1, more severe than expected).
- Predicted: AC-25a may not actually exercise the SPEC-018-self-read path (HIT — Q-3 and H-2 around schema).
- Predicted: Hand-rolled renderer may not match real tokenizer template (HIT — M-1).
- Predicted: `unsupported_modelID_for_multi_turn` might be a stub (MISS — actually correctly wired).
- Predicted: per-(buyer, provider) downgrade may not survive process restart (HIT but downgraded to Q-1 — single-instance deployment makes it lower priority).

Bonus uncovered: the error-envelope hardcode (C-1) was NOT in the pre-commitment set; it surfaced when checking the AC-26 unsupported_modelID error code emission. This is the highest-severity finding in this audit and a clean example of why the multi-perspective Code-lane + SPEC-table check matters.

To upgrade to READY TO MERGE: fix C-1 (extend APIError + writeSSEError with the four SPEC fields and per-code Retryable mapping), close H-1 (wire the timing headers OR delete the dead metrics endpoint), close H-2 (add `model_hash_observed` per turn in the AC-25a synthetic transcript), close H-3 (make AC-48b actually feed the stream through `@ai-sdk/openai-compatible`'s streamText). MEDIUMs M-1/M-2/M-3 should also be addressed before merge since each represents a SPEC fail condition that the fixture cannot detect.
